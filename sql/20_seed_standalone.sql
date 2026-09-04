-- ============================================================================
-- 20 - CONFIGURATION: standalone table retention (no document anchor)
-- ============================================================================
-- Archives four tables by their OWN age, independently of any order document:
--
--   AAD.dbo.t_tran_log      -> process <p>_TRANLOG_ARCH     (ANCHOR, self-anchored)
--   AAD.dbo.t_pick_detail   -> process <p>_PICKDETAIL_ARCH  (ANCHOR, self-anchored)
--   AAD.dbo.t_work_q        -> process <p>_WORKQ_ARCH       (TIMESTAMP; see 05_seed_workq.sql)
--   ADV.dbo.t_log_message   -> process ADV_LOGMSG_ARCH      (TIMESTAMP)
--
-- ---------------------------------------------------------------------------
-- WHY TWO DIFFERENT STRATEGIES FOR WHAT LOOKS LIKE THE SAME JOB
-- ---------------------------------------------------------------------------
-- "Archive this table when its rows get old" sounds like the TIMESTAMP strategy,
-- and for t_work_q and t_log_message it is. But TIMESTAMP has a structural
-- constraint that makes it WRONG for t_tran_log:
--
--   * TIMESTAMP picks its candidate-driving table as TOP(1) ORDER BY DeleteOrder
--     (014_usp_PrepareCandidates lines 113-121), so the driving table must have
--     the LOWEST DeleteOrder - i.e. it is deleted FIRST.
--   * t_tran_log has two children with ENFORCED foreign keys pointing at it:
--       t_tran_log_reason.tran_log_id -> fk_tran_log_id      (NO_ACTION)
--       t_tran_log_sn.tran_log_id     -> fk_tran_log_id_sn   (NO_ACTION)
--     NO_ACTION means the engine BLOCKS deleting a parent that still has children.
--
--   Those two requirements are irreconcilable: TIMESTAMP wants the parent first,
--   the FK wants it last. A TIMESTAMP process on t_tran_log would fail with a
--   foreign-key violation as soon as any reason/serial-number row exists.
--
--   ANCHOR resolves it. The anchor table is deleted LAST (highest DeleteOrder),
--   which is exactly the order the FK needs. Nothing says an ANCHOR must be a
--   "document" - here the table anchors ITSELF: AnchorTable = t_tran_log,
--   Key1 = tran_log_id, and the children join 't.tran_log_id = k.Key1'.
--
--   t_pick_detail uses ANCHOR for the same shape of reason: it lets t_allocation
--   (which carries pick_id) be archived BEFORE its parent. t_pick_detail has no
--   FK pointing at it, so TIMESTAMP would also work - but then t_allocation rows
--   would be left as orphans, which is worse.
--
-- ---------------------------------------------------------------------------
-- CONFLICT WITH THE DOCUMENT-ANCHORED PROCESS - READ THIS
-- ---------------------------------------------------------------------------
-- If <p>_ORDER_ARCH (ANCHOR on t_order) is deployed, it ALREADY lists t_tran_log
-- and t_pick_detail among its ObjectSpecs, joined by the ORDER key. Enabling
-- both models at once means the same physical row can be selected by two
-- processes with two different notions of "old":
--     order-anchored : delete this transaction because its ORDER aged out
--     standalone     : delete this transaction because IT aged out
-- They reach different row sets, too - the order-anchored process only ever sees
-- transactions that carry an outbound_order_number, so inventory adjustments,
-- receipts and cycle counts are invisible to it and would accumulate forever.
--
-- This script therefore DISABLES <p>_ORDER_ARCH (IsEnabled = 0) rather than
-- silently leaving two overlapping models running. Nothing is deleted: the
-- configuration and its archived rows stay, so it can be re-enabled with
--     UPDATE arch.Process SET IsEnabled = 1 WHERE ProcessCode = N'<p>_ORDER_ARCH';
-- Decide which model you want; do not run both.
-- ============================================================================
:setvar AdminDb   "kArchiveManagerAdmin"
:setvar WmsDb     "AAD"
:setvar AdvDb     "ADV"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar SourceTimezone "Central European Standard Time"
:setvar RetentionDays "90"
:setvar OrderProcessToDisable "AAD_ORDER_ARCH"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'arch.usp_Api_SaveProcess', N'P') IS NULL
    THROW 60500, 'kArchiveManager 2.0 is not deployed in this database.', 1;
IF DB_ID(N'$(WmsDb)') IS NULL THROW 60501, 'WMS source database does not exist.', 1;
IF DB_ID(N'$(AdvDb)') IS NULL THROW 60502, 'ADV source database does not exist.', 1;
IF DB_ID(N'$(ArchiveDb)') IS NULL THROW 60503, 'Archive database does not exist.', 1;
GO

-------------------------------------------------------------------------------
-- 0) Stand down the overlapping document-anchored process (see header).
-------------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM arch.Process WHERE ProcessCode = N'$(OrderProcessToDisable)' AND IsEnabled = 1)
BEGIN
    UPDATE arch.Process
    SET IsEnabled = 0, ModifiedAt = SYSUTCDATETIME()
    WHERE ProcessCode = N'$(OrderProcessToDisable)';
    PRINT 'DISABLED $(OrderProcessToDisable) - it overlaps t_tran_log and t_pick_detail with this configuration.';
END
ELSE
    PRINT '$(OrderProcessToDisable) is absent or already disabled - nothing to do.';
GO

-------------------------------------------------------------------------------
-- 1) t_tran_log - ANCHOR, self-anchored, children first
-------------------------------------------------------------------------------
DECLARE @Pc     sysname        = N'AAD_TRANLOG_ARCH';
DECLARE @By     nvarchar(256)  = N'kam-deploy';
DECLARE @Reason nvarchar(1000) = N'Transaction log retention, self-anchored on tran_log_id so the enforced child FKs can be honoured.';
DECLARE @Tz     nvarchar(200)  = N'$(SourceTimezone)';
DECLARE @CsId   bigint         = NULL;
DECLARE @KsId   int            = NULL;
DECLARE @OsId   int            = NULL;

-- start_tran_date is NOT NULL, date-only (the time of day lives in the separate
-- start_tran_time column, which carries a 1900-01-01 date part) and it is the
-- LEADING key of index i_tran_log (start_tran_date, tran_type) - so a plain
-- comparison on it is a clean index range seek. Deliberately NOT combined with
-- start_tran_time: that would make the expression non-sargable and turn every
-- run into a full scan of what is the largest table in a production WA database.
-- Losing sub-day precision is irrelevant against a 90+ day retention.
--
-- The 1900-sentinel guard matters: start_tran_date has DEFAULT '01/01/1900', so a
-- row written without a date would look ancient and be archived immediately.
DECLARE @AnchorTs nvarchar(4000) =
    N'TRY_CONVERT(datetime2, a.start_tran_date) AT TIME ZONE N''' + @Tz + N''' AT TIME ZONE N''UTC''';
DECLARE @AnchorWhere nvarchar(4000) =
    N'a.start_tran_date > ''19000102''';

EXEC arch.usp_Api_SaveProcess
    @ProcessCode               = @Pc,
    @RequestedBy               = @By,
    @ChangeReason              = @Reason,
    @Description               = N'WMS transaction log history - immutable event rows plus their reason and serial-number children.',
    @IsEnabled                 = 1,
    @Mode                      = 1,
    @RetentionDays             = $(RetentionDays),
    @CutoffSafetyLagMinutes    = 1440,
    @CutoffMode                = 0,
    @BatchDocCount             = 2000,   -- ANCHOR batches by key; here one key == one log row
    @MaxBatchesPerRun          = 250,
    @UseAppLock                = 1,
    @LockTimeoutMs             = 10000,
    @DeadlockPriority          = N'LOW',
    @AnchorSchema              = N'dbo',
    @AnchorTable               = N't_tran_log',
    @AnchorDocKeyExpr          = N'tran_log_id',
    @AnchorTimestampExpr       = @AnchorTs,
    @AnchorExtraWhereSql       = @AnchorWhere,
    @AllowDeleteWithoutArchive = 0,
    @DocKeyLabel               = N'TRAN_LOG_ID',
    @AuditLevel                = N'NONE',   -- high row count; per-row audit would dwarf the data
    @ConfigChangeSetId         = @CsId OUTPUT;

UPDATE arch.Process
SET SelectionStrategy = N'ANCHOR', RequireSupportingIndex = 1,
    MaxRowsPerTransaction = 2000, ModifiedAt = SYSUTCDATETIME()
WHERE ProcessCode = @Pc;

SET @KsId = NULL;
EXEC arch.usp_Api_SaveProcessKeySpec
    @ProcessKeySpecId = @KsId OUTPUT, @ProcessCode = @Pc, @RequestedBy = @By, @ChangeReason = @Reason,
    @KeyOrdinal = 1, @KeyName = N'tran_log_id', @SourceExpressionSql = N'a.tran_log_id',
    @SqlType = N'nvarchar(256)', @IsRequired = 1, @ConfigChangeSetId = @CsId OUTPUT;

DELETE ks FROM arch.ProcessKeySpec ks JOIN arch.Process p ON p.ProcessId = ks.ProcessId
WHERE p.ProcessCode = @Pc AND ks.KeyOrdinal > 1;

EXEC arch.usp_Api_SaveProcessDatabase
    @ProcessCode = @Pc, @SourceDb = N'$(WmsDb)', @ArchiveDb = N'$(ArchiveDb)',
    @RequestedBy = @By, @ChangeReason = @Reason, @IsEnabled = 1, @RunOrder = 30,
    @ConfigChangeSetId = @CsId OUTPUT;

-- Children BEFORE the anchor: their FKs are NO_ACTION, so the engine would block
-- the parent delete otherwise. This ordering is the whole reason for ANCHOR here.
DECLARE @tlObjects table (DeleteOrder int PRIMARY KEY, SourceTable sysname, JoinSql nvarchar(4000));
INSERT @tlObjects VALUES
    (10, N't_tran_log_reason', N't.tran_log_id = k.Key1'),
    (20, N't_tran_log_sn',     N't.tran_log_id = k.Key1'),
    (30, N't_tran_log',        N't.tran_log_id = k.Key1');   -- anchor, last

DECLARE @do int, @st sysname, @js nvarchar(4000);
DECLARE c1 CURSOR LOCAL FAST_FORWARD FOR SELECT DeleteOrder, SourceTable, JoinSql FROM @tlObjects ORDER BY DeleteOrder;
OPEN c1; FETCH NEXT FROM c1 INTO @do, @st, @js;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @OsId = NULL;
    EXEC arch.usp_Api_SaveObjectSpec
        @ObjectSpecId = @OsId OUTPUT, @ProcessCode = @Pc, @RequestedBy = @By, @ChangeReason = @Reason,
        @SourceSchema = N'dbo', @SourceTable = @st, @DeleteOrder = @do, @DeleteMode = 1,
        @TimestampExpr = NULL, @JoinToAnchorPredicateSql = @js, @AdditionalWhereSql = NULL,
        @ArchiveSchema = N'{SourceDb}', @ArchiveTable = NULL, @RequireArchiveForDelete = 1,
        @NaturalKeyLabel = N'TRAN_LOG_ID', @ConfigChangeSetId = @CsId OUTPUT;
    FETCH NEXT FROM c1 INTO @do, @st, @js;
END;
CLOSE c1; DEALLOCATE c1;

DECLARE @IrId int = NULL;
EXEC arch.usp_Api_SaveIndexRequirement
    @IndexRequirementId = @IrId OUTPUT, @ProcessCode = @Pc, @RequestedBy = @By, @ChangeReason = @Reason,
    @RequirementType = N'SELECTION', @SourceSchema = N'dbo', @SourceTable = N't_tran_log',
    @KeyColumnsCsv = N'start_tran_date,tran_type', @IsMandatory = 0,
    @Notes = N'Satisfied by the existing i_tran_log. The cutoff is deliberately a bare column comparison so this index can be seeked.',
    @ConfigChangeSetId = @CsId OUTPUT;

SET @IrId = NULL;
EXEC arch.usp_Api_SaveIndexRequirement
    @IndexRequirementId = @IrId OUTPUT, @ProcessCode = @Pc, @RequestedBy = @By, @ChangeReason = @Reason,
    @RequirementType = N'JOIN', @SourceSchema = N'dbo', @SourceTable = N't_tran_log_reason',
    @KeyColumnsCsv = N'tran_log_id', @IsMandatory = 0,
    @Notes = N'Satisfied by i_tran_log_id.', @ConfigChangeSetId = @CsId OUTPUT;

SET @IrId = NULL;
EXEC arch.usp_Api_SaveIndexRequirement
    @IndexRequirementId = @IrId OUTPUT, @ProcessCode = @Pc, @RequestedBy = @By, @ChangeReason = @Reason,
    @RequirementType = N'JOIN', @SourceSchema = N'dbo', @SourceTable = N't_tran_log_sn',
    @KeyColumnsCsv = N'tran_log_id', @IsMandatory = 0,
    @Notes = N'Satisfied by i_tran_log_sn_id.', @ConfigChangeSetId = @CsId OUTPUT;

PRINT 'AAD_TRANLOG_ARCH configured (ANCHOR, self-anchored on tran_log_id).';
GO

-------------------------------------------------------------------------------
-- 2) t_pick_detail - ANCHOR, self-anchored, t_allocation first
-------------------------------------------------------------------------------
DECLARE @Pc2     sysname        = N'AAD_PICKDETAIL_ARCH';
DECLARE @By2     nvarchar(256)  = N'kam-deploy';
DECLARE @Reason2 nvarchar(1000) = N'Pick detail retention, self-anchored on pick_id so t_allocation can be archived with it.';
DECLARE @Tz2     nvarchar(200)  = N'$(SourceTimezone)';
DECLARE @CsId2   bigint         = NULL;
DECLARE @KsId2   int            = NULL;
DECLARE @OsId2   int            = NULL;

-- create_date is the ONLY timestamp on the table, it is NOT NULL with
-- DEFAULT getdate(), and it is a CREATION time that is never updated. So it
-- measures how long ago the pick was CREATED, not how long ago it finished -
-- which makes the terminal-state gate essential rather than optional.
--
-- Status domain (dbo.t_lookup, source='t_pick_detail'):
--   UNPLANNED, NEW, PRERLSE, CREATED, CARTONIZE, RELEASED, PICKED, STAGED,
--   LOADED, SHIPPED
-- Only SHIPPED is unambiguously finished: the goods have left. LOADED is on a
-- truck but not dispatched, and everything earlier is live work. The gate is a
-- positive whitelist of SHIPPED alone - deliberately conservative, because an
-- old-but-unshipped pick is exactly the kind of row that must NOT disappear.
DECLARE @AnchorTs2 nvarchar(4000) =
    N'TRY_CONVERT(datetime2, a.create_date) AT TIME ZONE N''' + @Tz2 + N''' AT TIME ZONE N''UTC''';
DECLARE @AnchorWhere2 nvarchar(4000) =
    N'a.status = N''SHIPPED''';

EXEC arch.usp_Api_SaveProcess
    @ProcessCode               = @Pc2,
    @RequestedBy               = @By2,
    @ChangeReason              = @Reason2,
    @Description               = N'WMS pick detail history - shipped picks and their allocations.',
    @IsEnabled                 = 1,
    @Mode                      = 1,
    @RetentionDays             = $(RetentionDays),
    @CutoffSafetyLagMinutes    = 1440,
    @CutoffMode                = 0,
    @BatchDocCount             = 2000,
    @MaxBatchesPerRun          = 250,
    @UseAppLock                = 1,
    @LockTimeoutMs             = 10000,
    @DeadlockPriority          = N'LOW',
    @AnchorSchema              = N'dbo',
    @AnchorTable               = N't_pick_detail',
    @AnchorDocKeyExpr          = N'pick_id',
    @AnchorTimestampExpr       = @AnchorTs2,
    @AnchorExtraWhereSql       = @AnchorWhere2,
    @AllowDeleteWithoutArchive = 0,
    @DocKeyLabel               = N'PICK_ID',
    @AuditLevel                = N'NONE',
    @ConfigChangeSetId         = @CsId2 OUTPUT;

UPDATE arch.Process
SET SelectionStrategy = N'ANCHOR', RequireSupportingIndex = 1,
    MaxRowsPerTransaction = 2000, ModifiedAt = SYSUTCDATETIME()
WHERE ProcessCode = @Pc2;

SET @KsId2 = NULL;
EXEC arch.usp_Api_SaveProcessKeySpec
    @ProcessKeySpecId = @KsId2 OUTPUT, @ProcessCode = @Pc2, @RequestedBy = @By2, @ChangeReason = @Reason2,
    @KeyOrdinal = 1, @KeyName = N'pick_id', @SourceExpressionSql = N'a.pick_id',
    @SqlType = N'nvarchar(256)', @IsRequired = 1, @ConfigChangeSetId = @CsId2 OUTPUT;

DELETE ks FROM arch.ProcessKeySpec ks JOIN arch.Process p ON p.ProcessId = ks.ProcessId
WHERE p.ProcessCode = @Pc2 AND ks.KeyOrdinal > 1;

EXEC arch.usp_Api_SaveProcessDatabase
    @ProcessCode = @Pc2, @SourceDb = N'$(WmsDb)', @ArchiveDb = N'$(ArchiveDb)',
    @RequestedBy = @By2, @ChangeReason = @Reason2, @IsEnabled = 1, @RunOrder = 40,
    @ConfigChangeSetId = @CsId2 OUTPUT;

-- t_allocation carries pick_id, so it can be archived with its parent instead of
-- being orphaned. It is included only if the table actually exists on this
-- instance. t_label and t_pick_container do NOT have pick_id (verified) and are
-- reachable only indirectly, so they are deliberately out of scope - if they hold
-- rows for archived picks they will be left behind. Raise that with Koerber
-- rather than guessing a join.
DECLARE @pdObjects table (DeleteOrder int PRIMARY KEY, SourceTable sysname, JoinSql nvarchar(4000));
INSERT @pdObjects VALUES (20, N't_pick_detail', N't.pick_id = k.Key1');   -- anchor, last
IF OBJECT_ID(N'$(WmsDb)' + N'.dbo.t_allocation', N'U') IS NOT NULL
    INSERT @pdObjects VALUES (10, N't_allocation', N't.pick_id = k.Key1');

DECLARE @do2 int, @st2 sysname, @js2 nvarchar(4000);
DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR SELECT DeleteOrder, SourceTable, JoinSql FROM @pdObjects ORDER BY DeleteOrder;
OPEN c2; FETCH NEXT FROM c2 INTO @do2, @st2, @js2;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @OsId2 = NULL;
    EXEC arch.usp_Api_SaveObjectSpec
        @ObjectSpecId = @OsId2 OUTPUT, @ProcessCode = @Pc2, @RequestedBy = @By2, @ChangeReason = @Reason2,
        @SourceSchema = N'dbo', @SourceTable = @st2, @DeleteOrder = @do2, @DeleteMode = 1,
        @TimestampExpr = NULL, @JoinToAnchorPredicateSql = @js2, @AdditionalWhereSql = NULL,
        @ArchiveSchema = N'{SourceDb}', @ArchiveTable = NULL, @RequireArchiveForDelete = 1,
        @NaturalKeyLabel = N'PICK_ID', @ConfigChangeSetId = @CsId2 OUTPUT;
    FETCH NEXT FROM c2 INTO @do2, @st2, @js2;
END;
CLOSE c2; DEALLOCATE c2;

DECLARE @IrId2 int = NULL;
EXEC arch.usp_Api_SaveIndexRequirement
    @IndexRequirementId = @IrId2 OUTPUT, @ProcessCode = @Pc2, @RequestedBy = @By2, @ChangeReason = @Reason2,
    @RequirementType = N'SELECTION', @SourceSchema = N'dbo', @SourceTable = N't_pick_detail',
    @KeyColumnsCsv = N'status,create_date', @IncludeColumnsCsv = N'pick_id',
    @IsMandatory = 0,
    @Notes = N'MISSING in the stock schema: create_date is unindexed and i_status leads on status alone. Without it the candidate scan reads the whole table.',
    @ConfigChangeSetId = @CsId2 OUTPUT;

SET @IrId2 = NULL;
EXEC arch.usp_Api_SaveIndexRequirement
    @IndexRequirementId = @IrId2 OUTPUT, @ProcessCode = @Pc2, @RequestedBy = @By2, @ChangeReason = @Reason2,
    @RequirementType = N'JOIN', @SourceSchema = N'dbo', @SourceTable = N't_pick_detail',
    @KeyColumnsCsv = N'pick_id', @IsMandatory = 0,
    @Notes = N'Satisfied by PK_Pick_Detail (clustered).', @ConfigChangeSetId = @CsId2 OUTPUT;

PRINT 'AAD_PICKDETAIL_ARCH configured (ANCHOR, self-anchored on pick_id).';
GO

-------------------------------------------------------------------------------
-- 3) ADV.t_log_message - TIMESTAMP
--    Enabled ONLY if the surrogate key from 19_add_logmessage_key.sql exists.
--    t_log_message has no natural key at all (no PK, no unique index, and even
--    a 7-column combination has duplicate groups - there are 2 pairs of fully
--    identical rows), so without kam_row_id the runner would abort with
--    THROW 50115 on the first duplicate key among eligible rows.
-------------------------------------------------------------------------------
DECLARE @HasKey bit =
    CASE WHEN EXISTS
    (
        SELECT 1 FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'$(AdvDb)' + N'.dbo.t_log_message')
          AND c.name = N'kam_row_id'
    ) THEN 1 ELSE 0 END;

DECLARE @Pc3     sysname        = N'ADV_LOGMSG_ARCH';
DECLARE @By3     nvarchar(256)  = N'kam-deploy';
DECLARE @Reason3 nvarchar(1000) = N'Application log retention on ADV.t_log_message, keyed on the kam_row_id surrogate.';
DECLARE @CsId3   bigint         = NULL;
DECLARE @KsId3   int            = NULL;
DECLARE @OsId3   int            = NULL;

-- logged_on_utc is datetime NOT NULL and is ALREADY UTC (the table carries a
-- separate logged_on_local for local time). So the wrapper must NOT shift the
-- value - it is 'UTC' -> 'UTC', which is a no-op that exists purely to satisfy
-- the timezone gate (arch.usp_AssertTimezonePolicyApplied, THROW 50200, requires
-- the literal text AT TIME ZONE in the expression). Using the CET wrapper here
-- would silently move the cutoff by one or two hours.
DECLARE @TsExpr3 nvarchar(4000) =
    N'TRY_CONVERT(datetime2, t.logged_on_utc) AT TIME ZONE N''UTC'' AT TIME ZONE N''UTC''';

EXEC arch.usp_Api_SaveProcess
    @ProcessCode               = @Pc3,
    @RequestedBy               = @By3,
    @ChangeReason              = @Reason3,
    @Description               = N'ADV application log history (t_log_message).',
    @IsEnabled                 = @HasKey,   -- stays disabled until the key exists
    @Mode                      = 1,
    @RetentionDays             = $(RetentionDays),
    @CutoffSafetyLagMinutes    = 1440,
    @CutoffMode                = 0,
    @BatchRowCount             = 4000,
    @MaxBatchesPerRun          = 250,
    @UseAppLock                = 1,
    @LockTimeoutMs             = 10000,
    @DeadlockPriority          = N'LOW',
    @AnchorSchema              = NULL,
    @AnchorTable               = NULL,
    @AnchorDocKeyExpr          = NULL,
    @AnchorTimestampExpr       = NULL,
    @AnchorExtraWhereSql       = NULL,
    @AllowDeleteWithoutArchive = 0,
    @DocKeyLabel               = N'KAM_ROW_ID',
    @AuditLevel                = N'NONE',
    @ConfigChangeSetId         = @CsId3 OUTPUT;

UPDATE arch.Process
SET SelectionStrategy = N'TIMESTAMP', RequireSupportingIndex = 1,
    MaxRowsPerTransaction = 4000, CandidateOrderSql = N'DocCreatedAt, Key1',
    ModifiedAt = SYSUTCDATETIME()
WHERE ProcessCode = @Pc3;

SET @KsId3 = NULL;
EXEC arch.usp_Api_SaveProcessKeySpec
    @ProcessKeySpecId = @KsId3 OUTPUT, @ProcessCode = @Pc3, @RequestedBy = @By3, @ChangeReason = @Reason3,
    @KeyOrdinal = 1, @KeyName = N'kam_row_id', @SourceExpressionSql = N't.kam_row_id',
    @SqlType = N'nvarchar(256)', @IsRequired = 1, @ConfigChangeSetId = @CsId3 OUTPUT;

DELETE ks FROM arch.ProcessKeySpec ks JOIN arch.Process p ON p.ProcessId = ks.ProcessId
WHERE p.ProcessCode = @Pc3 AND ks.KeyOrdinal > 1;

-- Second source database. ArchiveSchema '{SourceDb}' puts these rows in
-- <ArchiveDb>.ADV.*, kept separate from the AAD schema in the same archive DB.
EXEC arch.usp_Api_SaveProcessDatabase
    @ProcessCode = @Pc3, @SourceDb = N'$(AdvDb)', @ArchiveDb = N'$(ArchiveDb)',
    @RequestedBy = @By3, @ChangeReason = @Reason3, @IsEnabled = @HasKey, @RunOrder = 50,
    @ConfigChangeSetId = @CsId3 OUTPUT;

SET @OsId3 = NULL;
EXEC arch.usp_Api_SaveObjectSpec
    @ObjectSpecId = @OsId3 OUTPUT, @ProcessCode = @Pc3, @RequestedBy = @By3, @ChangeReason = @Reason3,
    @SourceSchema = N'dbo', @SourceTable = N't_log_message', @DeleteOrder = 10, @DeleteMode = 1,
    @TimestampExpr = @TsExpr3, @JoinToAnchorPredicateSql = N't.kam_row_id = k.Key1',
    @AdditionalWhereSql = NULL,
    @ArchiveSchema = N'{SourceDb}', @ArchiveTable = NULL, @RequireArchiveForDelete = 1,
    @NaturalKeyLabel = N'KAM_ROW_ID', @ConfigChangeSetId = @CsId3 OUTPUT;

DECLARE @IrId3 int = NULL;
EXEC arch.usp_Api_SaveIndexRequirement
    @IndexRequirementId = @IrId3 OUTPUT, @ProcessCode = @Pc3, @RequestedBy = @By3, @ChangeReason = @Reason3,
    @RequirementType = N'SELECTION', @SourceSchema = N'dbo', @SourceTable = N't_log_message',
    @KeyColumnsCsv = N'logged_on_utc', @IsMandatory = 0,
    @Notes = N'Satisfied by the existing clustered i_log_message, which leads on logged_on_utc - the retention scan is a clustered range seek.',
    @ConfigChangeSetId = @CsId3 OUTPUT;

SET @IrId3 = NULL;
EXEC arch.usp_Api_SaveIndexRequirement
    @IndexRequirementId = @IrId3 OUTPUT, @ProcessCode = @Pc3, @RequestedBy = @By3, @ChangeReason = @Reason3,
    @RequirementType = N'JOIN', @SourceSchema = N'dbo', @SourceTable = N't_log_message',
    @KeyColumnsCsv = N'kam_row_id', @IsMandatory = 0,
    @Notes = N'Requires UX_KAM_t_log_message_kam_row_id from 19_add_logmessage_key.sql.',
    @ConfigChangeSetId = @CsId3 OUTPUT;

IF @HasKey = 1
    PRINT 'ADV_LOGMSG_ARCH configured and ENABLED (kam_row_id present).';
ELSE
BEGIN
    PRINT 'ADV_LOGMSG_ARCH configured but left DISABLED: ADV.dbo.t_log_message has no kam_row_id.';
    PRINT 'Run 19_add_logmessage_key.sql with Apply=1, then re-run this script to enable it.';
END;
GO

-------------------------------------------------------------------------------
-- 4) Run profiles for the standalone set
-------------------------------------------------------------------------------
DECLARE @RpId int = NULL, @CsId4 bigint = NULL;

EXEC arch.usp_Api_SaveRunProfile
    @RunProfileId = @RpId OUTPUT, @RunProfileCode = N'STANDALONE_DRYRUN',
    @RequestedBy = N'kam-deploy', @ChangeReason = N'Dry run over every enabled standalone table process.',
    @Description = N'Standalone table retention - DryRun (all enabled processes).',
    @IsEnabled = 1, @RunOnSchedule = 0, @RunOrder = 300,
    @ProcessCodeFilter = NULL, @SourceDbFilter = NULL,
    @RunWindowMinutes = 30, @DryRun = 1, @MaxCandidates = 5000,
    @ConfigChangeSetId = @CsId4 OUTPUT;

SET @RpId = NULL;
EXEC arch.usp_Api_SaveRunProfile
    @RunProfileId = @RpId OUTPUT, @RunProfileCode = N'STANDALONE_RUN',
    @RequestedBy = N'kam-deploy', @ChangeReason = N'Real run over every enabled standalone table process.',
    @Description = N'Standalone table retention - real archive+delete (all enabled processes).',
    @IsEnabled = 1, @RunOnSchedule = 0, @RunOrder = 310,
    @ProcessCodeFilter = NULL, @SourceDbFilter = NULL,
    @RunWindowMinutes = 30, @DryRun = 0, @MaxCandidates = 5000,
    @ConfigChangeSetId = @CsId4 OUTPUT;
GO

PRINT '';
PRINT '20_seed_standalone: done.';
GO

-- Verification
SELECT
    p.ProcessCode, p.SelectionStrategy, p.Mode, p.RetentionDays, p.AuditLevel,
    p.DocKeyLabel, ISNULL(p.AnchorTable, N'(timestamp - no anchor)') AS AnchorTable,
    p.MaxRowsPerTransaction, p.IsEnabled
FROM arch.Process p
ORDER BY p.IsEnabled DESC, p.ProcessCode;

SELECT
    p.ProcessCode, os.DeleteOrder, os.SourceTable, os.JoinToAnchorPredicateSql,
    Role_ = CASE WHEN os.SourceTable = p.AnchorTable THEN 'ANCHOR (deleted last)'
                 WHEN p.SelectionStrategy = N'TIMESTAMP' AND os.DeleteOrder = 10 THEN 'DRIVING (selects candidates)'
                 ELSE 'child' END
FROM arch.ObjectSpec os
JOIN arch.Process p ON p.ProcessId = os.ProcessId
WHERE p.ProcessCode IN (N'AAD_TRANLOG_ARCH', N'AAD_PICKDETAIL_ARCH', N'ADV_LOGMSG_ARCH')
ORDER BY p.ProcessCode, os.DeleteOrder;

SELECT pd.SourceDb, pd.ArchiveDb, p.ProcessCode, pd.IsEnabled, pd.RunOrder
FROM arch.ProcessDatabase pd
JOIN arch.Process p ON p.ProcessId = pd.ProcessId
ORDER BY pd.RunOrder;
GO
