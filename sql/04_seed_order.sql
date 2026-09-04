-- ============================================================================
-- kArchiveManager 2.0 - configuration seed: OUTBOUND ORDER DOCUMENT (ANCHOR)
-- Koerber Warehouse Advantage: dbo.t_order + lines, comments, pack, picks, tran log
-- ============================================================================
-- Document anchor = dbo.t_order, business key = (order_number, wh_id).
--
-- WHY THE KEY IS COMPOSITE: order_number alone is NOT unique in t_order. The
-- uniqueness is enforced on the PAIR by uk_order UNIQUE (wh_id, order_number)
-- (and again, redundantly, by ui_order_ordnum UNIQUE (order_number, wh_id)).
-- Configuring order_number as a single-column anchor would eventually archive or
-- delete rows belonging to another warehouse. 09_preflight_data.sql section I
-- reports whether that risk is live on your data.
--   Key1 = a.order_number   -> children join  t.<col> = k.Key1
--   Key2 = a.wh_id          -> children join  t.wh_id = k.Key2
--
-- WHY THE CUTOFF EXPRESSION LOOKS LIKE THAT: most nullable datetime columns on
-- t_order DEFAULT to '01/01/1900' instead of NULL (date_picked, actual_delivery_date,
-- arrive_date, promised_date, earliest/latest_ship_date, ...). A naive
-- "<cutoff" predicate would therefore match every never-picked / never-delivered
-- order and archive LIVE documents. actual_ship_date is the ONLY date column on
-- t_order with no default constraint, i.e. genuinely NULL until the order ships;
-- order_date is the only NOT NULL datetime (DEFAULT getdate()) and is the fallback.
-- NULLIF(...,'19000101') defuses the sentinel if a row carries it.
-- There is NO closed_date on t_order - that column exists only on the inbound
-- side (t_po_master / t_asn_master), so any spec that mentions it is wrong.
--
-- WHY THE GATES: t_lookup (source='t_order', lookup_type='STATUS') defines
--   N=New, D=Done, S=Shipped, LOADING=Loading, U=Unassigned, R=Ready To Ship.
-- Only S and D are terminal. There is NO check constraint on the column, so the
-- host interface can write anything - hence a positive whitelist, never a
-- negative NOT IN. lock_flag is undocumented in the schema, so any non-NULL value
-- is treated as do-not-archive. A non-NULL consolidated_order_number means the
-- document was merged into another order; archiving it alone would split one
-- logical document across live and archive.
--
-- t_pack IS IN THE SET DELIBERATELY: fk_pack_order_number carries ON DELETE
-- CASCADE, so deleting a header destroys its t_pack rows whether they are
-- archived or not. Leaving it out would mean permanent loss with no copy.
-- (Verified empirically: one header DELETE cascades three levels deep, also
--  removing t_order_detail, t_order_comment and t_order_detail_comment.)
--
-- NOT IN THIS PROCESS - both are real product limitations, not oversights:
--   * t_work_q - reachable only as t_order -> t_pick_detail(work_q_id) -> t_work_q,
--     a two-hop join. The keyset is built from the anchor table alone and
--     arch.usp_AssertSafeSqlExpression forbids SELECT (THROW 50400), so the second
--     hop cannot be expressed. It is also shared many-to-one across orders.
--     Handled by its own TIMESTAMP process - see 05_seed_workq.sql.
--   * t_tran_log_reason / t_tran_log_sn - ENFORCED FKs to t_tran_log.tran_log_id,
--     which is not derivable from the order key, so they cannot be deleted before
--     their parent inside this process. 09_preflight_data.sql section E counts
--     whether any exist on your eligible transactions; if it reports STOP, resolve
--     that before enabling t_tran_log here.
-- ============================================================================
:setvar AdminDb   "kArchiveManagerAdmin"
:setvar SourceDb  "AAD"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar SourceTimezone "Central European Standard Time"
:setvar RetentionDays "90"
:setvar ProcessCode "AAD_ORDER_ARCH"
:setvar AuditLevel "ROW"

:on error exit

USE [$(AdminDb)];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'arch.usp_Api_SaveProcess', N'P') IS NULL
    THROW 60100, 'kArchiveManager 2.0 is not deployed in this database (arch.usp_Api_SaveProcess missing).', 1;
IF DB_ID(N'$(SourceDb)') IS NULL
    THROW 60101, 'Source database does not exist on this instance.', 1;
IF DB_ID(N'$(ArchiveDb)') IS NULL
    THROW 60102, 'Archive database does not exist on this instance.', 1;
GO

-- Fail fast if the source schema is not the one this configuration expects.
DECLARE @missing nvarchar(max) = N'';
SELECT @missing = @missing + N' ' + x.n
FROM (VALUES
    (N't_order'), (N't_order_detail'), (N't_order_comment'),
    (N't_order_detail_comment'), (N't_pack'), (N't_pick_detail'), (N't_tran_log')
) AS x(n)
WHERE OBJECT_ID(N'$(SourceDb)' + N'.dbo.' + x.n, N'U') IS NULL;
IF LEN(@missing) > 0
BEGIN
    DECLARE @m1 nvarchar(400) = N'Source database is missing expected table(s):' + @missing;
    ;THROW 60103, @m1, 1;
END;
GO

-- Fail fast on the columns the expressions below depend on.
-- NOTE: this must go through dynamic SQL. We are running in the ADMIN database,
-- so the local sys.columns does not contain the source database's objects -
-- OBJECT_ID() resolves a three-part name cross-database, but sys.columns does not.
CREATE TABLE #WantCol (t sysname NOT NULL, c sysname NOT NULL, PRIMARY KEY (t, c));
INSERT #WantCol(t, c) VALUES
    (N't_order', N'order_number'), (N't_order', N'wh_id'), (N't_order', N'status'),
    (N't_order', N'order_date'), (N't_order', N'actual_ship_date'),
    (N't_order', N'lock_flag'), (N't_order', N'consolidated_order_number'),
    (N't_tran_log', N'outbound_order_number'), (N't_tran_log', N'wh_id');

DECLARE @missCol nvarchar(max) = N'';
DECLARE @chk nvarchar(max) = N'
SELECT @out = @out + N'' '' + w.t + N''.'' + w.c
FROM #WantCol w
WHERE NOT EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(N'$(SourceDb)') + N'.sys.columns sc
    JOIN ' + QUOTENAME(N'$(SourceDb)') + N'.sys.objects so ON so.object_id = sc.object_id
    JOIN ' + QUOTENAME(N'$(SourceDb)') + N'.sys.schemas ss ON ss.schema_id = so.schema_id
    WHERE ss.name COLLATE DATABASE_DEFAULT = N''dbo''
      AND so.name COLLATE DATABASE_DEFAULT = w.t COLLATE DATABASE_DEFAULT
      AND sc.name COLLATE DATABASE_DEFAULT = w.c COLLATE DATABASE_DEFAULT
);';
EXEC sys.sp_executesql @chk, N'@out nvarchar(max) OUTPUT', @out = @missCol OUTPUT;

IF LEN(ISNULL(@missCol, N'')) > 0
BEGIN
    DECLARE @m2 nvarchar(400) = N'Source database is missing expected column(s):' + @missCol;
    ;THROW 60104, @m2, 1;
END;

DROP TABLE #WantCol;
GO

DECLARE @Pc     sysname        = N'$(ProcessCode)';
DECLARE @By     nvarchar(256)  = N'kam-deploy';
DECLARE @Reason nvarchar(1000) = N'Outbound order document retention, anchored on (order_number, wh_id).';
DECLARE @Tz     nvarchar(200)  = N'$(SourceTimezone)';
DECLARE @CsId   bigint         = NULL;
DECLARE @KsId   int            = NULL;

-- MUST contain AT TIME ZONE or a real (non-DryRun) run is blocked with THROW 50200
-- by arch.usp_AssertTimezonePolicyApplied.
DECLARE @AnchorTs nvarchar(4000) =
    N'CAST(COALESCE(NULLIF(a.actual_ship_date, ''19000101''), a.order_date) AS datetime2)'
  + N' AT TIME ZONE N''' + @Tz + N''' AT TIME ZONE N''UTC''';

DECLARE @AnchorWhere nvarchar(4000) =
    N'a.status IN (N''S'', N''D'') AND a.lock_flag IS NULL AND a.consolidated_order_number IS NULL';

DECLARE @JoinByOrder nvarchar(4000) = N't.order_number = k.Key1 AND t.wh_id = k.Key2';
-- t_tran_log has no plain order_number. The vendor's own compatibility view
-- v_tran_log maps outbound_order_number to the order for every outbound tran_type
-- (174, 250-264, 300-315, 320/322, 340/341, 391/392, 550, 855/885), while
-- inbound_order_number is the PURCHASE ORDER (t_po_master.po_number) and must
-- never be joined to t_order.
DECLARE @JoinTranLog nvarchar(4000) = N't.outbound_order_number = k.Key1 AND t.wh_id = k.Key2';

-------------------------------------------------------------------------------
-- 1) Process template
-------------------------------------------------------------------------------
EXEC arch.usp_Api_SaveProcess
    @ProcessCode               = @Pc,
    @RequestedBy               = @By,
    @ChangeReason              = @Reason,
    @Description               = N'WA outbound order document - header, lines, comments, pack, picks and transaction log.',
    @IsEnabled                 = 1,
    @Mode                      = 1,      -- archive + delete
    @RetentionDays             = $(RetentionDays),
    @CutoffSafetyLagMinutes    = 1440,
    @CutoffMode                = 0,      -- rolling retention
    @CutoffDate                = NULL,
    @BatchDocCount             = 50,     -- ANCHOR batches by DOCUMENT, not by row
    @BatchRowCount             = NULL,
    @MaxBatchesPerRun          = 200,
    @DelayMsBetweenBatches     = 0,
    @UseAppLock                = 1,
    @LockTimeoutMs             = 10000,
    @DeadlockPriority          = N'LOW',
    @AnchorSchema              = N'dbo',
    @AnchorTable               = N't_order',
    @AnchorDocKeyExpr          = N'order_number',  -- 1.0-era field; the validator ERRORs if blank
    @AnchorDocKey2Expr         = N'wh_id',
    @AnchorTimestampExpr       = @AnchorTs,
    @AnchorExtraWhereSql       = @AnchorWhere,
    @AllowDeleteWithoutArchive = 0,
    @DocKeyLabel               = N'ORDER_NUMBER',
    @AuditLevel                = N'$(AuditLevel)',
    @ConfigChangeSetId         = @CsId OUTPUT;

-- Columns the Save API does not expose.
-- MaxRowsPerTransaction MUST stay <= 4000: usp_ValidateConfiguration raises an
-- ERROR above that (a single DELETE of ~5000 rows escalates to a TABLE X lock on
-- the production source and blocks OLTP for the batch duration), and the runner
-- hard-caps it at 4000 anyway. Raise MaxBatchesPerRun for throughput instead.
UPDATE arch.Process
SET SelectionStrategy      = N'ANCHOR',
    RequireSupportingIndex = 1,
    MaxRowsPerTransaction  = 2000,
    ModifiedAt             = SYSUTCDATETIME()
WHERE ProcessCode = @Pc;

-------------------------------------------------------------------------------
-- 2) Anchor key. Expressions are written against the ANCHOR alias 'a'.
--    (The TIMESTAMP strategy uses 't' instead - see 05_seed_workq.sql.)
-------------------------------------------------------------------------------
SET @KsId = NULL;
EXEC arch.usp_Api_SaveProcessKeySpec
    @ProcessKeySpecId    = @KsId OUTPUT,
    @ProcessCode         = @Pc,
    @RequestedBy         = @By,
    @ChangeReason        = @Reason,
    @KeyOrdinal          = 1,
    @KeyName             = N'order_number',
    @SourceExpressionSql = N'a.order_number',
    @SqlType             = N'nvarchar(256)',
    @IsRequired          = 1,
    @ConfigChangeSetId   = @CsId OUTPUT;

SET @KsId = NULL;
EXEC arch.usp_Api_SaveProcessKeySpec
    @ProcessKeySpecId    = @KsId OUTPUT,
    @ProcessCode         = @Pc,
    @RequestedBy         = @By,
    @ChangeReason        = @Reason,
    @KeyOrdinal          = 2,
    @KeyName             = N'wh_id',
    @SourceExpressionSql = N'a.wh_id',
    @SqlType             = N'nvarchar(256)',
    @IsRequired          = 1,
    @ConfigChangeSetId   = @CsId OUTPUT;

-------------------------------------------------------------------------------
-- 3) Source -> archive mapping. Overrides left NULL so the template applies.
-------------------------------------------------------------------------------
EXEC arch.usp_Api_SaveProcessDatabase
    @ProcessCode       = @Pc,
    @SourceDb          = N'$(SourceDb)',
    @ArchiveDb         = N'$(ArchiveDb)',
    @RequestedBy       = @By,
    @ChangeReason      = @Reason,
    @IsEnabled         = 1,
    @RunOrder          = 10,
    @ConfigChangeSetId = @CsId OUTPUT;
GO

-------------------------------------------------------------------------------
-- 4) Objects: deepest child first, ANCHOR TABLE LAST.
--    The anchor table needs its own ObjectSpec with the highest DeleteOrder, or
--    its rows are never deleted and get re-selected on every run.
--    (Note this is the opposite of the TIMESTAMP strategy, where the driving
--     table must come FIRST - see the note in 05_seed_workq.sql.)
--    ArchiveSchema '{SourceDb}' -> archive lands in <ArchiveDb>.<SourceDb>.*
-------------------------------------------------------------------------------
DECLARE @Pc2     sysname        = N'$(ProcessCode)';
DECLARE @By2     nvarchar(256)  = N'kam-deploy';
DECLARE @Reason2 nvarchar(1000) = N'Outbound order document object set.';
DECLARE @CsId2   bigint         = NULL;
DECLARE @OsId    int            = NULL;
DECLARE @JoinOrd nvarchar(4000) = N't.order_number = k.Key1 AND t.wh_id = k.Key2';
DECLARE @JoinTl  nvarchar(4000) = N't.outbound_order_number = k.Key1 AND t.wh_id = k.Key2';

DECLARE @Objects table
(
    DeleteOrder int NOT NULL PRIMARY KEY,
    SourceTable sysname NOT NULL,
    JoinSql     nvarchar(4000) NOT NULL
);

INSERT @Objects(DeleteOrder, SourceTable, JoinSql)
VALUES
    (10, N't_order_detail_comment', @JoinOrd),  -- deepest cascade level
    (20, N't_order_comment',        @JoinOrd),
    (30, N't_order_detail',         @JoinOrd),
    (40, N't_pack',                 @JoinOrd),  -- cascade victim: archive or lose it
    (50, N't_pick_detail',          @JoinOrd),  -- no FK, orphan by convention
    (60, N't_tran_log',             @JoinTl),   -- outbound transactions only
    (70, N't_order',                @JoinOrd);  -- ANCHOR - deleted last

DECLARE @do int, @st sysname, @js nvarchar(4000);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DeleteOrder, SourceTable, JoinSql FROM @Objects ORDER BY DeleteOrder;
OPEN cur;
FETCH NEXT FROM cur INTO @do, @st, @js;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @OsId = NULL;
    EXEC arch.usp_Api_SaveObjectSpec
        @ObjectSpecId             = @OsId OUTPUT,
        @ProcessCode              = @Pc2,
        @RequestedBy              = @By2,
        @ChangeReason             = @Reason2,
        @SourceSchema             = N'dbo',
        @SourceTable              = @st,
        @DeleteOrder              = @do,
        @DeleteMode               = 1,     -- prepared keyset (mandatory for ANCHOR)
        @TimestampExpr            = NULL,  -- children inherit the cutoff via the keyset
        @JoinToAnchorPredicateSql = @js,
        @AdditionalWhereSql       = NULL,
        @ArchiveSchema            = N'{SourceDb}',
        @ArchiveTable             = NULL,  -- defaults to the source table name
        @RequireArchiveForDelete  = 1,
        @NaturalKeyLabel          = N'ORDER_NUMBER',
        @ConfigChangeSetId        = @CsId2 OUTPUT;

    FETCH NEXT FROM cur INTO @do, @st, @js;
END;
CLOSE cur;
DEALLOCATE cur;
GO

-------------------------------------------------------------------------------
-- 5) Declared supporting indexes (advisory: IsMandatory = 0, so a missing index
--    is a WARN, never a blocker). None of the two MISSING ones below exist in the
--    stock WA schema. Creating them touches the Koerber vendor schema, so it is a
--    separate opt-in step - see 08_source_indexes.sql.
-------------------------------------------------------------------------------
DECLARE @Pc3   sysname        = N'$(ProcessCode)';
DECLARE @By3   nvarchar(256)  = N'kam-deploy';
DECLARE @Rsn3  nvarchar(1000) = N'Declared supporting indexes for the outbound order process.';
DECLARE @CsId3 bigint         = NULL;
DECLARE @IrId  int            = NULL;

DECLARE @Idx table
(
    Ord      int IDENTITY(1,1) PRIMARY KEY,
    ReqType  nvarchar(20)   NOT NULL,
    Tbl      sysname        NOT NULL,
    KeyCols  nvarchar(1000) NOT NULL,
    InclCols nvarchar(1000) NULL,
    Notes    nvarchar(1000) NOT NULL
);

INSERT @Idx(ReqType, Tbl, KeyCols, InclCols, Notes)
VALUES
    (N'SELECTION', N't_order', N'order_date,wh_id,order_number',
     N'actual_ship_date,lock_flag,status,consolidated_order_number',
     N'MISSING in the stock schema - t_order has no index on any date column, so the candidate scan reads the whole table.'),
    (N'JOIN', N't_order_detail',         N'wh_id,order_number', NULL, N'Satisfied by uk_order_detail (wh_id, order_number, line_number) leftmost prefix.'),
    (N'JOIN', N't_order_comment',        N'wh_id,order_number', NULL, N'Satisfied by uk_order_comment leftmost prefix.'),
    (N'JOIN', N't_order_detail_comment', N'wh_id,order_number', NULL, N'Satisfied by i_order_detail_comment_wh_id_o.'),
    (N'JOIN', N't_pack',                 N'wh_id,order_number', NULL, N'MISSING - t_pack has only pk_pack (id, wh_id); both the archive join and the FK cascade scan the table.'),
    (N'JOIN', N't_pick_detail',          N'order_number,wh_id', NULL, N'Satisfied by i_order_number (order_number, wh_id).'),
    (N'JOIN', N't_tran_log',             N'outbound_order_number,wh_id', N'start_tran_date,tran_type',
     N'MISSING - no index on t_tran_log contains outbound_order_number. This is the largest table in a production WA database; create it before the first real run.'),
    (N'JOIN', N't_order',                N'wh_id,order_number', NULL, N'Anchor delete join - satisfied by uk_order.');

DECLARE @rt nvarchar(20), @tb sysname, @kc nvarchar(1000), @ic nvarchar(1000), @nt nvarchar(1000);
DECLARE ic CURSOR LOCAL FAST_FORWARD FOR SELECT ReqType, Tbl, KeyCols, InclCols, Notes FROM @Idx ORDER BY Ord;
OPEN ic;
FETCH NEXT FROM ic INTO @rt, @tb, @kc, @ic, @nt;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @IrId = NULL;
    EXEC arch.usp_Api_SaveIndexRequirement
        @IndexRequirementId = @IrId OUTPUT,
        @ProcessCode        = @Pc3,
        @RequestedBy        = @By3,
        @ChangeReason       = @Rsn3,
        @ObjectSpecId       = NULL,
        @RequirementType    = @rt,
        @SourceSchema       = N'dbo',
        @SourceTable        = @tb,
        @KeyColumnsCsv      = @kc,
        @IncludeColumnsCsv  = @ic,
        @FilterSql          = NULL,
        @IsMandatory        = 0,
        @Notes              = @nt,
        @ConfigChangeSetId  = @CsId3 OUTPUT;
    FETCH NEXT FROM ic INTO @rt, @tb, @kc, @ic, @nt;
END;
CLOSE ic;
DEALLOCATE ic;
GO

-------------------------------------------------------------------------------
-- 6) Run profiles.
--    JOB_DEFAULT is REQUIRED even if you never enable the scheduled job: the
--    'kArchiveManager - RUN CONFIGURED' Agent job hardcodes
--    EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'JOB_DEFAULT', and the
--    clean deploy bundle seeds no run profiles at all.
-------------------------------------------------------------------------------
DECLARE @RpId int = NULL, @CsId4 bigint = NULL;

EXEC arch.usp_Api_SaveRunProfile
    @RunProfileId      = @RpId OUTPUT,
    @RunProfileCode    = N'JOB_DEFAULT',
    @RequestedBy       = N'kam-deploy',
    @ChangeReason      = N'Scheduled nightly run over every enabled process and mapping.',
    @Description       = N'Scheduled nightly run (all enabled processes).',
    @IsEnabled         = 1,
    @RunOnSchedule     = 1,
    @RunOrder          = 10,
    @ProcessCodeFilter = NULL,
    @SourceDbFilter    = NULL,
    @RunWindowMinutes  = 55,
    @DryRun            = 0,
    @MaxCandidates     = NULL,
    @ConfigChangeSetId = @CsId4 OUTPUT;

SET @RpId = NULL;
EXEC arch.usp_Api_SaveRunProfile
    @RunProfileId      = @RpId OUTPUT,
    @RunProfileCode    = N'ORDER_DRYRUN',
    @RequestedBy       = N'kam-deploy',
    @ChangeReason      = N'Manual dry-run of the outbound order process only.',
    @Description       = N'Outbound order retention - DryRun only.',
    @IsEnabled         = 1,
    @RunOnSchedule     = 0,
    @RunOrder          = 100,
    @ProcessCodeFilter = N'$(ProcessCode)',
    @SourceDbFilter    = N'$(SourceDb)',
    @RunWindowMinutes  = 20,
    @DryRun            = 1,
    @MaxCandidates     = 1000,
    @ConfigChangeSetId = @CsId4 OUTPUT;

SET @RpId = NULL;
EXEC arch.usp_Api_SaveRunProfile
    @RunProfileId      = @RpId OUTPUT,
    @RunProfileCode    = N'ORDER_RUN',
    @RequestedBy       = N'kam-deploy',
    @ChangeReason      = N'Manual real archive+delete run of the outbound order process.',
    @Description       = N'Outbound order retention - real archive+delete.',
    @IsEnabled         = 1,
    @RunOnSchedule     = 0,
    @RunOrder          = 110,
    @ProcessCodeFilter = N'$(ProcessCode)',
    @SourceDbFilter    = N'$(SourceDb)',
    @RunWindowMinutes  = 20,
    @DryRun            = 0,
    @MaxCandidates     = 1000,
    @ConfigChangeSetId = @CsId4 OUTPUT;
GO

PRINT '04_seed_order: configuration applied for $(ProcessCode) on $(SourceDb).';
GO

-- Verification
SELECT p.ProcessCode, p.SelectionStrategy, p.Mode, p.RetentionDays, p.CutoffMode,
       p.AuditLevel, p.DocKeyLabel, p.AnchorTable, p.BatchDocCount,
       p.MaxRowsPerTransaction, p.IsEnabled
FROM arch.Process p WHERE p.ProcessCode = N'$(ProcessCode)';

SELECT ks.KeyOrdinal, ks.KeyName, ks.SourceExpressionSql
FROM arch.ProcessKeySpec ks JOIN arch.Process p ON p.ProcessId = ks.ProcessId
WHERE p.ProcessCode = N'$(ProcessCode)' ORDER BY ks.KeyOrdinal;

SELECT os.DeleteOrder, os.SourceTable, os.DeleteMode, os.ArchiveSchema,
       os.JoinToAnchorPredicateSql
FROM arch.ObjectSpec os JOIN arch.Process p ON p.ProcessId = os.ProcessId
WHERE p.ProcessCode = N'$(ProcessCode)' ORDER BY os.DeleteOrder;
GO
