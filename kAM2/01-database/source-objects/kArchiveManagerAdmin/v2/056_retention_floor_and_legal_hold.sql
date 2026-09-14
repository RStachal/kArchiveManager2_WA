USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
/* ============================================================================
   056 — T-21: retention floor (minimum-retention policy) + legal-hold
   ----------------------------------------------------------------------------
   PROBLEM: the cutoff is DATEADD(DAY, -RetentionDays, now) with no lower bound, and there is no
   per-key exclusion. A single mis-set RetentionDays / CutoffDate (auto-published, T-06) could delete
   data inside a mandatory retention window, and there is no way to pin specific documents (e.g. under
   audit / litigation) so they are never archived+deleted. (T-21, completeness HIGH.)

   FIX — two complementary controls, both enforced at REAL deletes (DryRun exempt), like the TZ gate:
     (1) RETENTION FLOOR — arch.RetentionPolicy.MinRetentionDays. arch.usp_AssertRetentionFloor THROWs
         50210 when the effective cutoff is MORE RECENT than (now - MinRetentionDays), i.e. the run
         would delete rows younger than the floor. Covers BOTH RetentionDays- and CutoffDate-derived
         cutoffs (it checks the final cutoff value). Floor 0 = disabled (default; the customer sets it).
         Called by both runners (027 with @CutoffUtc, 015 with WorkBatch.RangeToUtc) at @DryRun=0.
     (2) LEGAL-HOLD — arch.LegalHold rows (ProcessCode [+ optional SourceDb] + HoldKey = the process's
         primary candidate key, i.e. Key1). Active holds are EXCLUDED from the candidate set at build
         time in both runners, so held keys are never archived+deleted. Add/release is a karch_approver
         (compliance) action and is auditable; holds take effect at the next candidate build.

   This script ships in the clean bundle (Phase 13c, after the karch_* roles). Idempotent.
   ============================================================================ */

/* ---- 1) retention policy (single row) -------------------------------------- */
IF OBJECT_ID(N'arch.RetentionPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[RetentionPolicy]
    (
        PolicyId        tinyint NOT NULL CONSTRAINT [PK_RetentionPolicy] PRIMARY KEY
                                         CONSTRAINT [CK_RetentionPolicy_Singleton] CHECK (PolicyId = 1),
        MinRetentionDays int NOT NULL CONSTRAINT [DF_RetentionPolicy_Min] DEFAULT (0),  -- 0 = floor disabled
        ModifiedAtUtc   datetime2(0) NOT NULL CONSTRAINT [DF_RetentionPolicy_At] DEFAULT (SYSUTCDATETIME()),
        ModifiedBy      sysname NULL,
        CONSTRAINT [CK_RetentionPolicy_NonNeg] CHECK (MinRetentionDays >= 0)
    );
END
GO
IF NOT EXISTS (SELECT 1 FROM arch.RetentionPolicy WHERE PolicyId = 1)
    INSERT arch.RetentionPolicy(PolicyId, MinRetentionDays, ModifiedBy) VALUES (1, 0, SUSER_SNAME());
GO

/* ---- 2) legal-hold register ------------------------------------------------ */
IF OBJECT_ID(N'arch.LegalHold', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[LegalHold]
    (
        LegalHoldId   bigint IDENTITY(1,1) NOT NULL CONSTRAINT [PK_LegalHold] PRIMARY KEY,
        ProcessCode   sysname NOT NULL,
        SourceDb      sysname NULL,                 -- NULL = applies to every source DB for the process
        HoldKey       nvarchar(256) NOT NULL,       -- the process's primary candidate key (Key1) value
        Reason        nvarchar(400) NOT NULL,
        CreatedBy     sysname NOT NULL CONSTRAINT [DF_LegalHold_By] DEFAULT (SUSER_SNAME()),
        CreatedAtUtc  datetime2(0) NOT NULL CONSTRAINT [DF_LegalHold_At] DEFAULT (SYSUTCDATETIME()),
        ReleasedAtUtc datetime2(0) NULL,
        ReleasedBy    sysname NULL
    );
    -- fast active-hold lookup used by the candidate-exclusion in the runners
    CREATE NONCLUSTERED INDEX [IX_LegalHold_Active]
        ON [arch].[LegalHold] (ProcessCode, SourceDb, HoldKey) INCLUDE (ReleasedAtUtc)
        WHERE ReleasedAtUtc IS NULL;
END
GO

/* widen the WorkBatchKey status domain to admit Status=5 = 'parked: under legal hold' (015 sets it when
   a hold is added AFTER prepare, so the key is neither deleted nor re-claimed nor marked done). Idempotent. */
IF OBJECT_ID(N'arch.WorkBatchKey', N'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = N'CK_WorkBatchKey_Status' AND parent_object_id = OBJECT_ID(N'arch.WorkBatchKey'))
        ALTER TABLE [arch].[WorkBatchKey] DROP CONSTRAINT [CK_WorkBatchKey_Status];
    ALTER TABLE [arch].[WorkBatchKey] WITH NOCHECK
        ADD CONSTRAINT [CK_WorkBatchKey_Status] CHECK ([Status] >= 0 AND [Status] <= 5);  -- 0 unclaimed,1 claimed,2 done,3 error,5 legal-hold
END
GO

/* ---- 3) retention-floor gate (called by the runners at real deletes) ------- */
CREATE OR ALTER PROCEDURE [arch].[usp_AssertRetentionFloor]
    @ProcessId  int = NULL,         -- context only (the floor is global)
    @SourceDb   sysname = NULL,
    @ArchiveDb  sysname = NULL,
    @CutoffUtc  datetime2(0)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @floor int = COALESCE((SELECT TOP (1) MinRetentionDays FROM arch.RetentionPolicy WHERE PolicyId = 1), 0);
    IF @floor <= 0 RETURN;   -- no floor configured -> no-op (backward compatible)

    -- fail closed: a NULL cutoff must never silently pass the floor (UNKNOWN comparison)
    IF @CutoffUtc IS NULL
        THROW 50211, 'usp_AssertRetentionFloor called with NULL @CutoffUtc (cannot evaluate the retention floor).', 1;

    DECLARE @earliest datetime2(0) = DATEADD(DAY, -@floor, CONVERT(datetime2(0), SYSUTCDATETIME()));
    IF @CutoffUtc > @earliest
    BEGIN
        DECLARE @m nvarchar(400) =
            N'Retention floor violation: effective cutoff ' + CONVERT(nvarchar(30), @CutoffUtc)
          + N' is more recent than the policy floor (now - ' + CONVERT(nvarchar(12), @floor) + N' days = '
          + CONVERT(nvarchar(30), @earliest) + N'). Real deletes blocked. Raise RetentionDays/CutoffDate, '
          + N'or lower arch.RetentionPolicy.MinRetentionDays if the floor is wrong.';
        ;THROW 50210, @m, 1;
    END;
END
GO

/* ---- 4) management API (compliance actions; audited via CreatedBy/ReleasedBy) --- */
CREATE OR ALTER PROCEDURE [arch].[usp_Api_SetRetentionFloor]
    @MinRetentionDays int,
    @RequestedBy      nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @MinRetentionDays < 0 THROW 50212, 'MinRetentionDays must be >= 0.', 1;
    UPDATE arch.RetentionPolicy
    SET MinRetentionDays = @MinRetentionDays,
        ModifiedAtUtc = SYSUTCDATETIME(),
        ModifiedBy = COALESCE(@RequestedBy, SUSER_SNAME())
    WHERE PolicyId = 1;
    IF @@ROWCOUNT = 0
        INSERT arch.RetentionPolicy(PolicyId, MinRetentionDays, ModifiedBy)
        VALUES (1, @MinRetentionDays, COALESCE(@RequestedBy, SUSER_SNAME()));
    SELECT MinRetentionDays, ModifiedAtUtc, ModifiedBy FROM arch.RetentionPolicy WHERE PolicyId = 1;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_AddLegalHold]
    @ProcessCode sysname,
    @HoldKey     nvarchar(256),
    @Reason      nvarchar(400),
    @SourceDb    sysname = NULL,
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(RTRIM(@ProcessCode)), N'') IS NULL THROW 50213, '@ProcessCode is required.', 1;
    IF NULLIF(LTRIM(RTRIM(@HoldKey)), N'') IS NULL     THROW 50214, '@HoldKey is required.', 1;
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL OR LEN(LTRIM(RTRIM(@Reason))) < 6
        THROW 50215, '@Reason is required (>= 6 chars) for the audit trail.', 1;

    IF EXISTS (SELECT 1 FROM arch.LegalHold
               WHERE ProcessCode = @ProcessCode AND HoldKey = @HoldKey
                 AND ISNULL(SourceDb, N'') = ISNULL(@SourceDb, N'') AND ReleasedAtUtc IS NULL)
    BEGIN
        SELECT LegalHoldId, ProcessCode, SourceDb, HoldKey, Reason, CreatedBy, CreatedAtUtc, Note = N'already active'
        FROM arch.LegalHold
        WHERE ProcessCode = @ProcessCode AND HoldKey = @HoldKey
          AND ISNULL(SourceDb, N'') = ISNULL(@SourceDb, N'') AND ReleasedAtUtc IS NULL;
        RETURN;
    END;

    INSERT arch.LegalHold(ProcessCode, SourceDb, HoldKey, Reason, CreatedBy)
    VALUES (@ProcessCode, @SourceDb, @HoldKey, LTRIM(RTRIM(@Reason)), COALESCE(@RequestedBy, SUSER_SNAME()));

    -- A hold is keyed on Key1 (the primary candidate key). For composite-key processes (ProcessKeySpec
    -- KeyOrdinal>1, e.g. Key1+Key2) the hold drops EVERY candidate sharing this Key1 — safe (never
    -- under-excludes) but over-inclusive. Surface that so the operator understands the granularity.
    DECLARE @note nvarchar(200) = N'';
    IF EXISTS (SELECT 1 FROM arch.ProcessKeySpec pks JOIN arch.Process p ON p.ProcessId = pks.ProcessId
               WHERE p.ProcessCode = @ProcessCode AND pks.KeyOrdinal > 1)
        SET @note = N'NOTE: composite-key process — this hold applies to ALL rows sharing Key1 (Key2.. is not distinguished).';

    SELECT LegalHoldId, ProcessCode, SourceDb, HoldKey, Reason, CreatedBy, CreatedAtUtc, Note = @note
    FROM arch.LegalHold WHERE LegalHoldId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_ReleaseLegalHold]
    @LegalHoldId bigint,
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE arch.LegalHold
    SET ReleasedAtUtc = SYSUTCDATETIME(), ReleasedBy = COALESCE(@RequestedBy, SUSER_SNAME())
    WHERE LegalHoldId = @LegalHoldId AND ReleasedAtUtc IS NULL;
    IF @@ROWCOUNT = 0 THROW 50216, 'Legal hold not found or already released.', 1;
    SELECT LegalHoldId, ProcessCode, SourceDb, HoldKey, ReleasedAtUtc, ReleasedBy
    FROM arch.LegalHold WHERE LegalHoldId = @LegalHoldId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetLegalHolds]
    @ProcessCode sysname = NULL,
    @ActiveOnly  bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT LegalHoldId, ProcessCode, SourceDb, HoldKey, Reason, CreatedBy, CreatedAtUtc, ReleasedAtUtc, ReleasedBy
    FROM arch.LegalHold
    WHERE (@ProcessCode IS NULL OR ProcessCode = @ProcessCode)
      AND (@ActiveOnly = 0 OR ReleasedAtUtc IS NULL)
    ORDER BY CASE WHEN ReleasedAtUtc IS NULL THEN 0 ELSE 1 END, ProcessCode, SourceDb, HoldKey;
END
GO

/* ---- 5) grants ------------------------------------------------------------- */
IF DATABASE_PRINCIPAL_ID(N'karch_runtime') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_AssertRetentionFloor] TO [karch_runtime];
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_AssertRetentionFloor] TO [karch_advanced_admin];  -- out-of-band what-if checks
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GetLegalHolds] TO [karch_viewer];
IF DATABASE_PRINCIPAL_ID(N'karch_operator') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GetLegalHolds] TO [karch_operator];
IF DATABASE_PRINCIPAL_ID(N'karch_approver') IS NOT NULL
BEGIN
    GRANT EXECUTE ON [arch].[usp_Api_SetRetentionFloor] TO [karch_approver];
    GRANT EXECUTE ON [arch].[usp_Api_AddLegalHold]     TO [karch_approver];
    GRANT EXECUTE ON [arch].[usp_Api_ReleaseLegalHold] TO [karch_approver];
    GRANT EXECUTE ON [arch].[usp_Frontend_GetLegalHolds] TO [karch_approver];
END
GO
PRINT '056_retention_floor_and_legal_hold deployed (arch.RetentionPolicy, arch.LegalHold, usp_AssertRetentionFloor + management API).';
GO
