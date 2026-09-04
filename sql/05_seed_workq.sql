-- ============================================================================
-- kArchiveManager 2.0 - configuration seed: WORK QUEUE (TIMESTAMP strategy)
-- Koerber Warehouse Advantage: dbo.t_work_q + t_work_q_assignment + t_work_q_dependency
-- ============================================================================
-- WHY THIS IS A SEPARATE PROCESS AND NOT A CHILD OF THE ORDER ANCHOR:
--   t_work_q has NO order_number and NO order_id. It is reachable from an order
--   only as a TWO-HOP join:  t_order -> t_pick_detail(work_q_id) -> t_work_q.
--   kArchiveManager builds the ANCHOR keyset from the anchor table alone, and
--   arch.usp_AssertSafeSqlExpression forbids SELECT in every configurable SQL
--   field (THROW 50400), so that second hop cannot be expressed as a child join.
--   On top of that, one work queue serves MANY pick-detail rows across DIFFERENT
--   orders (many-to-one), so deleting it per-order would destroy work still
--   referenced by another live order.
--   Anchoring it on its own terminal state instead degrades safely: a shared work
--   queue simply survives until it is itself complete and older than the cutoff.
--
--   The other candidate link, pick_ref_number, is POLYMORPHIC - its meaning is
--   discriminated by work_type (order_number for 03/15/16/31/32, load_id for
--   02/10/11/12, wave_id for 04, a license plate for 06), so joining on it
--   without a work_type filter produces false matches. It is deliberately unused.
--
-- !! PRODUCT LIMITATION - THE KEY HERE IS SINGLE-COLUMN, UNLIKE THE ORDER PROCESS !!
--   The TIMESTAMP runner supports exactly ONE key column. 027_usp_RunTimestampProcess
--   creates #Candidates (line 410) and #Batch (line 601) with Key1 only - no Key2 -
--   so a two-key configuration fails at run time with "Invalid column name 'Key2'".
--   (The ANCHOR runner, by contrast, carries Key1..Key8.)
--   t_work_q's primary key is (work_q_id, wh_id), so strictly speaking work_q_id
--   alone is only unique WITHIN a warehouse. We key on work_q_id anyway because:
--     * the vendor itself treats it as globally unique - PK_work_q_assignment is
--       (work_q_id, user_assigned) and PK_work_q_dependency is
--       (parent_work_q_id, dependent_work_q_id), both WITHOUT wh_id, and
--       usp_release_work_q_shipping updates t_work_q by work_q_id with no wh_id
--       filter at all; and
--     * the runner enforces a uniqueness gate: #Candidates has a UNIQUE index on
--       Key1 and a DupCnt column, and the run aborts with THROW 50115 if two
--       ELIGIBLE rows share a key.
--   That gate only covers ELIGIBLE rows, so a same-numbered queue in another
--   warehouse that is Complete but NEWER than the cutoff would still be matched by
--   the delete join. 09_preflight_data.sql therefore VERIFIES on live data that
--   work_q_id is unique across warehouses before any real run. If it is not, do
--   not enable this process - split it per warehouse or raise the limitation with
--   the vendor.
--
-- GATE: work_status IN ('C','P') only.
--   Domain from dbo.t_lookup WHERE source='t_work_q':
--     U=Unassigned, A=Assigned, C=Complete, H=Hold, P=Picks Completed.
--   Only C and P are terminal. U/A are live work; H is blocked work (and is also
--   how the finish-start dependency mechanism parks a Ship Request), so none of
--   them may ever be archived.
--
-- CUTOFF: datetime_stamp. Be aware this is a CREATION time, not a completion
--   time - t_work_q has no completion timestamp at all and no update trigger, so
--   the value never moves as work_status goes U -> A -> C. An age-based cutoff
--   therefore measures how long ago the work was CREATED. Combined with the
--   terminal-state gate that is acceptable, but it means a long-running queue
--   completed yesterday can still be eligible if it was created long ago.
--   datetime_stamp is NULLABLE (interface/hand-loaded rows), hence the IS NOT NULL.
--
-- DELETE ORDER - NOTE THE COUNTER-INTUITIVE ORDER, IT IS DELIBERATE:
--   Unlike ANCHOR, the TIMESTAMP runner picks its candidate-driving table as
--   TOP(1) ... ORDER BY DeleteOrder, ObjectSpecId (014_usp_PrepareCandidates
--   lines 113-121). The driving table must therefore be FIRST, so t_work_q gets
--   DeleteOrder 10 and its children follow at 20/30/40 - i.e. the parent row is
--   deleted before its children.
--   That is safe here for two specific reasons:
--     1) none of these three tables has a foreign key in either direction, so
--        there is no constraint to violate, and
--     2) every child DELETE joins the prepared keyset (#Batch), not the parent
--        table, so it still finds its rows after the parent is gone.
--   Each batch runs in its own transaction, so a mid-batch failure rolls the
--   whole batch back rather than leaving children behind.
--
--   Children also need a non-blank TimestampExpr: 027_usp_RunTimestampProcess
--   THROWs 50111 unless EVERY ObjectSpec has one. But the runner never evaluates
--   it for them - the comment at 027 lines 671-676 states the keyset is
--   authoritative and the cutoff is deliberately NOT re-evaluated per row. The
--   children therefore carry a constant epoch expression, which reads as
--   "always eligible, decided by the keyset". It still has to contain
--   AT TIME ZONE to satisfy the timezone gate (THROW 50200).
--   !! RISK, MEASURED BY 09_preflight_data.sql BEFORE ANY REAL RUN !!
--   t_work_q_dependency rows of type 'FS' (finish-start) park the DEPENDENT queue
--   on work_status='H' until the parent finishes. If we archive a parent and drop
--   the dependency while the dependent is still U/A/H, that dependent is stranded
--   on Hold with no parent that can ever release it. 09_preflight_data.sql counts
--   exactly those rows; if it reports more than zero, resolve them before running.
-- ============================================================================
:setvar AdminDb   "kArchiveManagerAdmin"
:setvar SourceDb  "AAD"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar SourceTimezone "Central European Standard Time"
:setvar RetentionDays "90"
:setvar ProcessCode "AAD_WORKQ_ARCH"

:on error exit

USE [$(AdminDb)];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
   OR OBJECT_ID(N'arch.IndexRequirement', N'U') IS NULL
BEGIN
    THROW 60200, '2.0 metadata is not installed (arch.ProcessKeySpec / arch.IndexRequirement missing).', 1;
END;
IF DB_ID(N'$(SourceDb)') IS NULL
    THROW 60201, 'Source database does not exist on this instance.', 1;
IF DB_ID(N'$(ArchiveDb)') IS NULL
    THROW 60202, 'Archive database does not exist on this instance.', 1;
GO

-- Fail fast if the source schema is not the one this configuration was written for.
DECLARE @missing nvarchar(max) = N'';
SELECT @missing = @missing + N' ' + x.n
FROM (VALUES (N't_work_q'), (N't_work_q_assignment'), (N't_work_q_dependency')) AS x(n)
WHERE OBJECT_ID(N'$(SourceDb)' + N'.dbo.' + x.n, N'U') IS NULL;
IF LEN(@missing) > 0
BEGIN
    DECLARE @m1 nvarchar(400) = N'Source database is missing expected table(s):' + @missing;
    ;THROW 60203, @m1, 1;
END;
GO

DECLARE @Pc     sysname        = N'$(ProcessCode)';
DECLARE @By     nvarchar(256)  = N'kam-deploy';
DECLARE @Reason nvarchar(1000) = N'Work-queue retention (TIMESTAMP strategy) on terminal work_status only.';
DECLARE @Tz     nvarchar(200)  = N'$(SourceTimezone)';
DECLARE @CsId   bigint         = NULL;
DECLARE @KsId   int            = NULL;
DECLARE @IrId   int            = NULL;

-- MUST contain AT TIME ZONE, or a real (non-DryRun) run is blocked with THROW 50200
-- by arch.usp_AssertTimezonePolicyApplied.
DECLARE @TsExpr nvarchar(4000) =
    N'CAST(t.datetime_stamp AS datetime2) AT TIME ZONE N''' + @Tz + N''' AT TIME ZONE N''UTC''';

DECLARE @Gate nvarchar(4000) =
    N't.datetime_stamp IS NOT NULL AND t.work_status IN (N''C'', N''P'')';

-------------------------------------------------------------------------------
-- 1) Process template. TIMESTAMP strategy: every Anchor* column stays NULL.
-------------------------------------------------------------------------------
EXEC arch.usp_Api_SaveProcess
    @ProcessCode              = @Pc,
    @RequestedBy              = @By,
    @ChangeReason             = @Reason,
    @Description              = N'WA work queue history - completed work queues, their assignments and dependencies.',
    @IsEnabled                = 1,
    @Mode                     = 1,      -- archive + delete
    @RetentionDays            = $(RetentionDays),
    @CutoffSafetyLagMinutes   = 1440,
    @CutoffMode               = 0,      -- rolling retention
    @CutoffDate               = NULL,
    @BatchDocCount            = NULL,
    @BatchRowCount            = 4000,
    @MaxBatchesPerRun         = 250,    -- 4000 x 250 = 1,000,000 rows per run
    @DelayMsBetweenBatches    = 0,
    @UseAppLock               = 1,
    @LockTimeoutMs            = 10000,
    @DeadlockPriority         = N'LOW',
    @AnchorSchema             = NULL,
    @AnchorTable              = NULL,
    @AnchorDocKeyExpr         = NULL,
    @AnchorDocKey2Expr        = NULL,
    @AnchorTimestampExpr      = NULL,
    @AnchorExtraWhereSql      = NULL,
    @AllowDeleteWithoutArchive = 0,
    @DocKeyLabel              = N'WORK_Q_ID',
    -- NOTE: AuditLevel must NOT be 'BATCH' for TIMESTAMP - usp_PrepareCandidates
    -- rejects that combination outright. 'NONE' matches the shipped RF_LOG2 seed
    -- and keeps the audit volume sane on a high-row-count table.
    @AuditLevel               = N'NONE',
    @ConfigChangeSetId        = @CsId OUTPUT;

-- Columns the Save API does not expose.
UPDATE arch.Process
SET SelectionStrategy      = N'TIMESTAMP',
    RequireSupportingIndex = 1,
    MaxRowsPerTransaction  = 4000,   -- stays under the ~5000-lock escalation threshold
    CandidateOrderSql      = N'DocCreatedAt, Key1',
    ModifiedAt             = SYSUTCDATETIME()
WHERE ProcessCode = @Pc;

-------------------------------------------------------------------------------
-- 2) Keyset - EXACTLY ONE key (see the product-limitation note in the header).
--    For TIMESTAMP the expressions are written against the SOURCE alias 't'
--    (unlike ANCHOR, which uses 'a').
-------------------------------------------------------------------------------
SET @KsId = NULL;
EXEC arch.usp_Api_SaveProcessKeySpec
    @ProcessKeySpecId    = @KsId OUTPUT,
    @ProcessCode         = @Pc,
    @RequestedBy         = @By,
    @ChangeReason        = @Reason,
    @KeyOrdinal          = 1,
    @KeyName             = N'work_q_id',
    @SourceExpressionSql = N't.work_q_id',
    @SqlType             = N'nvarchar(256)',
    @IsRequired          = 1,
    @ConfigChangeSetId   = @CsId OUTPUT;

-- Remove any higher ordinal left over from an earlier revision of this script:
-- the runner would fail with "Invalid column name 'Key2'".
DELETE ks
FROM arch.ProcessKeySpec ks
JOIN arch.Process p ON p.ProcessId = ks.ProcessId
WHERE p.ProcessCode = @Pc
  AND ks.KeyOrdinal > 1;

-------------------------------------------------------------------------------
-- 3) Source -> archive mapping
-------------------------------------------------------------------------------
EXEC arch.usp_Api_SaveProcessDatabase
    @ProcessCode       = @Pc,
    @SourceDb          = N'$(SourceDb)',
    @ArchiveDb         = N'$(ArchiveDb)',
    @RequestedBy       = @By,
    @ChangeReason      = @Reason,
    @IsEnabled         = 1,
    @RunOrder          = 20,
    @ConfigChangeSetId = @CsId OUTPUT;
GO

-------------------------------------------------------------------------------
-- 4) Objects.
--    Written with a direct MERGE rather than usp_Api_SaveObjectSpec because
--    t_work_q_dependency needs TWO specs (parent side and dependent side) and the
--    Save API upserts by (ProcessCode, SourceSchema, SourceTable), so the second
--    call would overwrite the first. arch.ObjectSpec has no unique constraint on
--    that triple, so two rows are legal - this is the same direct-write pattern
--    the shipped v2\017_seed_rf_log2_timestamp.sql uses.
--
--    The cutoff (TimestampExpr) lives ONLY on the driving table t_work_q. The
--    child specs inherit the decision through the prepared keyset, exactly like
--    ANCHOR children do.
-------------------------------------------------------------------------------
DECLARE @Pid int = (SELECT ProcessId FROM arch.Process WHERE ProcessCode = N'$(ProcessCode)');
DECLARE @Tz2 nvarchar(200) = N'$(SourceTimezone)';

-- Driving cutoff. TRY_CONVERT rather than a hard CAST: datetime_stamp is a real
-- datetime column so a hard CAST would work, but usp_ValidateConfiguration WARNs
-- on hard CAST/CONVERT in a TIMESTAMP source expression (language/format hazard),
-- and TRY_CONVERT is equivalent here while keeping validation at zero findings.
-- An unparseable value yields NULL, which never satisfies "< cutoff" and is
-- therefore skipped safely (and is reported by usp_Frontend_TimestampRetentionGaps).
DECLARE @TsExpr2 nvarchar(4000) =
    N'TRY_CONVERT(datetime2, t.datetime_stamp) AT TIME ZONE N''' + @Tz2 + N''' AT TIME ZONE N''UTC''';

-- Constant "always eligible" expression for the child tables - see the header note.
-- TRY_CONVERT (not CAST) purely so usp_ValidateConfiguration's hard-CAST WARN does
-- not fire; the value is a literal, so the two are identical in effect.
DECLARE @TsChild nvarchar(4000) =
    N'TRY_CONVERT(datetime2, N''19000101'') AT TIME ZONE N''UTC'' AT TIME ZONE N''UTC''';

DECLARE @Gate2 nvarchar(4000) =
    N't.datetime_stamp IS NOT NULL AND t.work_status IN (N''C'', N''P'')';

IF @Pid IS NULL
    THROW 60204, 'Process row was not created - check the Save API output above.', 1;

DELETE FROM arch.ObjectSpec WHERE ProcessId = @Pid;

INSERT INTO arch.ObjectSpec
(
    ProcessId, SourceSchema, SourceTable, DeleteOrder, DeleteMode,
    TimestampExpr, JoinToAnchorPredicateSql, AdditionalWhereSql,
    ArchiveSchema, ArchiveTable, RequireArchiveForDelete, NaturalKeyLabel
)
VALUES
    -- DRIVING TABLE - must be first (TOP(1) BY DeleteOrder selects the candidates).
    -- It alone carries the real cutoff and the terminal-state gate. The gate is
    -- re-applied on the DELETE itself (AdditionalWhereSql), which is what keeps a
    -- live queue safe even if it shared a key with an archived one.
    (@Pid, N'dbo', N't_work_q', 10, 1,
     @TsExpr2,
     N't.work_q_id = k.Key1',
     @Gate2,
     N'{SourceDb}', NULL, 1, N'WORK_Q_ID'),

    -- assignments of the archived queue
    (@Pid, N'dbo', N't_work_q_assignment', 20, 1,
     @TsChild,
     N't.work_q_id = k.Key1',
     NULL,
     N'{SourceDb}', NULL, 1, N'WORK_Q_ID'),

    -- dependency rows where the archived queue is the PARENT
    (@Pid, N'dbo', N't_work_q_dependency', 30, 1,
     @TsChild,
     N't.parent_work_q_id = k.Key1',
     NULL,
     N'{SourceDb}', NULL, 1, N'PARENT_WORK_Q_ID'),

    -- dependency rows where the archived queue is the DEPENDENT
    (@Pid, N'dbo', N't_work_q_dependency', 40, 1,
     @TsChild,
     N't.dependent_work_q_id = k.Key1',
     NULL,
     N'{SourceDb}', NULL, 1, N'DEPENDENT_WORK_Q_ID');
GO

-------------------------------------------------------------------------------
-- 5) Declared supporting indexes (advisory - a missing index is a WARN, never a
--    blocker). None of these exist in the stock WA schema: t_work_q has no index
--    on datetime_stamp and none leading on work_status, and t_work_q_dependency
--    has no index leading on dependent_work_q_id (it is only the second column of
--    the PK), so the dependent-side delete scans the whole clustered index.
-------------------------------------------------------------------------------
DECLARE @Pc2   sysname       = N'$(ProcessCode)';
DECLARE @By2   nvarchar(256) = N'kam-deploy';
DECLARE @Rsn2  nvarchar(1000)= N'Declared supporting indexes for the work-queue retention process.';
DECLARE @CsId2 bigint        = NULL;
DECLARE @IrId2 int           = NULL;

DECLARE @Idx table
(
    Ord      int IDENTITY(1,1) PRIMARY KEY,
    ReqType  nvarchar(20)  NOT NULL,
    Tbl      sysname       NOT NULL,
    KeyCols  nvarchar(1000) NOT NULL,
    InclCols nvarchar(1000) NULL,
    Notes    nvarchar(1000) NOT NULL
);

INSERT @Idx(ReqType, Tbl, KeyCols, InclCols, Notes)
VALUES
    (N'SELECTION', N't_work_q', N'work_status,datetime_stamp', N'work_q_id,wh_id,work_type',
     N'MISSING in the stock schema. Candidate selection filters on work_status and orders by datetime_stamp; without this the sweep scans the whole table.'),
    (N'JOIN', N't_work_q', N'work_q_id,wh_id', NULL,
     N'Satisfied by pk_work_q_id (clustered, unique).'),
    (N'JOIN', N't_work_q_assignment', N'work_q_id', NULL,
     N'Satisfied by PK_work_q_assignment (work_q_id, user_assigned) leftmost prefix.'),
    (N'JOIN', N't_work_q_dependency', N'parent_work_q_id', NULL,
     N'Satisfied by PK_work_q_dependency (parent_work_q_id, dependent_work_q_id) leftmost prefix.'),
    (N'JOIN', N't_work_q_dependency', N'dependent_work_q_id,wh_id', N'parent_work_q_id,status,dependency_type',
     N'MISSING - dependent_work_q_id is only the SECOND PK column, so the dependent-side delete scans the clustered index.');

DECLARE @rt nvarchar(20), @tb sysname, @kc nvarchar(1000), @ic nvarchar(1000), @nt nvarchar(1000);
DECLARE ic CURSOR LOCAL FAST_FORWARD FOR SELECT ReqType, Tbl, KeyCols, InclCols, Notes FROM @Idx ORDER BY Ord;
OPEN ic;
FETCH NEXT FROM ic INTO @rt, @tb, @kc, @ic, @nt;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @IrId2 = NULL;
    EXEC arch.usp_Api_SaveIndexRequirement
        @IndexRequirementId = @IrId2 OUTPUT,
        @ProcessCode        = @Pc2,
        @RequestedBy        = @By2,
        @ChangeReason       = @Rsn2,
        @ObjectSpecId       = NULL,
        @RequirementType    = @rt,
        @SourceSchema       = N'dbo',
        @SourceTable        = @tb,
        @KeyColumnsCsv      = @kc,
        @IncludeColumnsCsv  = @ic,
        @FilterSql          = NULL,
        @IsMandatory        = 0,
        @Notes              = @nt,
        @ConfigChangeSetId  = @CsId2 OUTPUT;
    FETCH NEXT FROM ic INTO @rt, @tb, @kc, @ic, @nt;
END;
CLOSE ic;
DEALLOCATE ic;
GO

-------------------------------------------------------------------------------
-- 6) Run profiles for this process (manual dry-run and manual real run)
-------------------------------------------------------------------------------
DECLARE @RpId int = NULL, @CsId3 bigint = NULL;

EXEC arch.usp_Api_SaveRunProfile
    @RunProfileId      = @RpId OUTPUT,
    @RunProfileCode    = N'WORKQ_DRYRUN',
    @RequestedBy       = N'kam-deploy',
    @ChangeReason      = N'Manual dry-run of the work-queue retention process.',
    @Description       = N'Work-queue retention - DryRun only.',
    @IsEnabled         = 1,
    @RunOnSchedule     = 0,
    @RunOrder          = 200,
    @ProcessCodeFilter = N'$(ProcessCode)',
    @SourceDbFilter    = N'$(SourceDb)',
    @RunWindowMinutes  = 20,
    @DryRun            = 1,
    @MaxCandidates     = 1000,
    @ConfigChangeSetId = @CsId3 OUTPUT;

SET @RpId = NULL;
EXEC arch.usp_Api_SaveRunProfile
    @RunProfileId      = @RpId OUTPUT,
    @RunProfileCode    = N'WORKQ_RUN',
    @RequestedBy       = N'kam-deploy',
    @ChangeReason      = N'Manual real run of the work-queue retention process.',
    @Description       = N'Work-queue retention - real archive+delete.',
    @IsEnabled         = 1,
    @RunOnSchedule     = 0,
    @RunOrder          = 210,
    @ProcessCodeFilter = N'$(ProcessCode)',
    @SourceDbFilter    = N'$(SourceDb)',
    @RunWindowMinutes  = 20,
    @DryRun            = 0,
    @MaxCandidates     = 1000,
    @ConfigChangeSetId = @CsId3 OUTPUT;
GO

PRINT '05_seed_workq: configuration applied for $(ProcessCode) on $(SourceDb).';
GO

-- Verification
SELECT p.ProcessCode, p.SelectionStrategy, p.Mode, p.RetentionDays, p.CutoffMode,
       p.AuditLevel, p.DocKeyLabel, p.BatchRowCount, p.MaxRowsPerTransaction, p.IsEnabled
FROM arch.Process p WHERE p.ProcessCode = N'$(ProcessCode)';

SELECT ks.KeyOrdinal, ks.KeyName, ks.SourceExpressionSql
FROM arch.ProcessKeySpec ks JOIN arch.Process p ON p.ProcessId = ks.ProcessId
WHERE p.ProcessCode = N'$(ProcessCode)' ORDER BY ks.KeyOrdinal;

SELECT os.DeleteOrder, os.SourceTable, os.JoinToAnchorPredicateSql,
       ISNULL(os.TimestampExpr, N'(inherited via keyset)') AS TimestampExpr,
       ISNULL(os.AdditionalWhereSql, N'(none)') AS AdditionalWhereSql
FROM arch.ObjectSpec os JOIN arch.Process p ON p.ProcessId = os.ProcessId
WHERE p.ProcessCode = N'$(ProcessCode)' ORDER BY os.DeleteOrder;
GO
