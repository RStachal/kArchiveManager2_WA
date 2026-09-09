-- ============================================================================
-- 27 - INBOUND DOCUMENT SET: PURCHASE ORDERS (AAD_PO_ARCH)
-- ============================================================================
-- The five sets shipped before this one cover the OUTBOUND side (orders, picks)
-- and the logs. The inbound side has no retention at all. This adds the purchase
-- order document, which is the direct mirror image of AAD_ORDER_ARCH: the same
-- header > detail > comment shape, the same composite natural key, the same
-- ANCHOR strategy for the same reason.
--
-- WHY IT IS NEEDED - the WMS does not clean these up
--   usp_util_close_inbound_order sets t_po_master.status = N'C' and
--   closed_date = CONVERT(DATE, GETDATE()) - and contains no DELETE at all. So a
--   closed purchase order stays for the life of the database.
--   The only code that removes real PO rows is usp_al_import_inbound_order, and
--   only when the HOST explicitly sends processing_code = 'Delete'; that is
--   host-driven maintenance, not retention.
--   AAD has no SQL Agent housekeeping job whatsoever - the only purge job on the
--   instance is ADV's own 'Log Maintenance'. Nothing else will ever remove these.
--
--   Note for anyone repeating the analysis: a pattern search for
--   '%DELETE%t_po_detail%' also lists usp_por_create_inv and usp_shr_create_inv,
--   which made it look as though receiving deletes POs. It does not - every
--   DELETE in those two procedures targets #tmp_po_detail and
--   #tmp_serial_number_scanned, i.e. temp tables. The pattern matched because a
--   DELETE appears earlier in the body than the table name. Read the procedure,
--   do not trust the grep.
--
-- ANCHOR, NOT TIMESTAMP - the same reason as t_tran_log
--   t_po_detail, t_po_comment and t_rcpt_ship_po all hold NO_ACTION foreign keys
--   to t_po_master, so the header cannot be deleted while they exist. TIMESTAMP
--   deletes its driving table FIRST and would fail on the constraint. ANCHOR
--   deletes the anchor LAST, so the header anchors itself.
--
-- THE KEY IS THE CLUSTERED PRIMARY KEY
--   pk_po_master is (po_number, wh_id), so the natural composite is unique by
--   definition - no repeat of the t_order lesson where order_number alone was
--   not unique. There is also a po_id surrogate with a unique index, but the
--   children all join on (po_number, wh_id), so that is what the keys carry.
--
-- THE CUTOFF IS closed_date ALONE, WITH NO FALLBACK - AND THAT IS DELIBERATE
--   AAD_ORDER_ARCH needs COALESCE(NULLIF(actual_ship_date,'19000101'), order_date)
--   because most nullable datetimes in t_order default to the 1900 sentinel.
--   t_po_master.closed_date has NO default and is NULL until the order is closed
--   (verified: 0 rows carry the sentinel), and it is written by the same statement
--   that sets status = 'C'. So a closed PO always has a real closed_date, and an
--   open one has NULL - which the cutoff comparison excludes on its own.
--   Falling back to create_date would archive OPEN purchase orders. Do not add it.
--
-- t_rcpt_ship_po IS A JUNCTION BETWEEN TWO DOCUMENTS - READ THIS BEFORE ENABLING
--   It links a PO to an inbound shipment (t_rcpt_ship) and has a NO_ACTION FK to
--   t_po_master plus a CASCADE FK from t_rcpt_ship. Consequences:
--     * it MUST be in this set. Leaving it out would make the header delete fail
--       with Msg 547 for every PO that was ever received against a shipment.
--     * archiving a PO therefore removes that shipment's link to it. This is
--       inherent to archiving the PO at all - keeping the junction while deleting
--       the PO would leave it pointing at nothing, and the FK forbids it anyway.
--     * the rows are preserved in the archive database alongside the PO, so the
--       fact is recoverable; it is only the live shipment view that loses it.
--   The ideal gate - "only archive a PO whose linked shipments are also closed" -
--   CANNOT be expressed in configuration: arch.usp_AssertSafeSqlExpression
--   refuses any subquery (probed directly, THROW 50400 on NOT EXISTS), and
--   t_po_master carries no "received" flag to test instead. Section D below
--   therefore reports the exposure as a number, so it is a decision taken with
--   evidence rather than a surprise.
-- ============================================================================
:setvar AdminDb   "kArchiveManagerAdmin"
:setvar WmsDb     "AAD"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar RetentionDays "90"
:setvar SourceTimezone "Central European Standard Time"
:setvar ProcessCode "AAD_PO_ARCH"
-- RunOrder 60: after the five existing sets (10..50). Inbound has no dependency
-- on outbound, so it simply goes last.
:setvar RunOrder "60"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---------------------------------------------------------------------------
   A) Refuse to configure a set whose tables are not all present.
   --------------------------------------------------------------------------- */
DECLARE @missing nvarchar(max);
DECLARE @chk nvarchar(max) = N'
SELECT @out = STUFF((SELECT N'', '' + t.n
                     FROM (VALUES (N''t_po_master''), (N''t_po_detail''), (N''t_po_comment''),
                                  (N''t_po_detail_comment''), (N''t_rcpt_ship_po'')) AS t(n)
                     WHERE NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.sys.tables st
                                       WHERE st.name = t.n COLLATE DATABASE_DEFAULT)
                     FOR XML PATH('''')), 1, 2, '''');';
EXEC sys.sp_executesql @chk, N'@out nvarchar(max) OUTPUT', @out = @missing OUTPUT;

IF @missing IS NOT NULL AND @missing <> N''
BEGIN
    PRINT 'Missing in $(WmsDb): ' + @missing;
    THROW 60710, 'A table this set needs does not exist. Nothing was changed.', 1;
END
ELSE
    PRINT 'A) All five PO tables are present in $(WmsDb).';
GO

/* ---------------------------------------------------------------------------
   B) The process itself.
   --------------------------------------------------------------------------- */
DECLARE @Pc     sysname        = N'$(ProcessCode)';
DECLARE @By     nvarchar(256)  = N'kam-deploy';
DECLARE @Reason nvarchar(1000) = N'Inbound purchase order retention. The WMS closes these documents but never removes them, and AAD has no housekeeping job.';
DECLARE @CsId   bigint = NULL;

-- The timezone gate (arch.usp_AssertTimezonePolicyApplied, THROW 50200) requires
-- the literal text AT TIME ZONE in the cutoff expression. closed_date is written
-- as a local DATE by usp_util_close_inbound_order, so the conversion is real here,
-- not the no-op used for ADV's already-UTC column.
DECLARE @AnchorTs nvarchar(4000) =
    N'CAST(a.closed_date AS datetime2) AT TIME ZONE N''$(SourceTimezone)'' AT TIME ZONE N''UTC''';

-- Gate: only a CLOSED purchase order is a finished document. closed_date IS NOT
-- NULL is redundant given status = 'C' is set in the same statement, but it is
-- stated anyway - it costs nothing and it makes the intent explicit to whoever
-- reads the configuration next.
DECLARE @Extra nvarchar(4000) = N'a.status = N''C'' AND a.closed_date IS NOT NULL';

EXEC arch.usp_Api_SaveProcess
    @ProcessCode               = @Pc,
    @RequestedBy               = @By,
    @ChangeReason              = @Reason,
    @Description               = N'Purchase order documents (t_po_master) with their detail, comments and shipment links.',
    @IsEnabled                 = 1,
    @Mode                      = 1,
    @RetentionDays             = $(RetentionDays),
    @CutoffSafetyLagMinutes    = 1440,
    @CutoffMode                = 0,
    @BatchDocCount             = 50,     -- five tables deep, same as the ORDER set
    @MaxBatchesPerRun          = 200,
    @DelayMsBetweenBatches     = 0,
    @UseAppLock                = 1,
    @LockTimeoutMs             = 10000,
    @DeadlockPriority          = N'LOW',
    @AnchorSchema              = N'dbo',
    @AnchorTable               = N't_po_master',
    @AnchorDocKeyExpr          = N'po_number',
    @AnchorDocKey2Expr         = N'wh_id',
    @AnchorTimestampExpr       = @AnchorTs,
    @AnchorExtraWhereSql       = @Extra,
    @AllowDeleteWithoutArchive = 0,
    @DocKeyLabel               = N'PO_NUMBER',
    @AuditLevel                = N'ROW',
    @ConfigChangeSetId         = @CsId OUTPUT;

UPDATE arch.Process
SET SelectionStrategy      = N'ANCHOR',
    RequireSupportingIndex = 1,
    MaxRowsPerTransaction  = 2000,   -- >4000 escalates to a TABLE X lock; validator ERRORs
    ModifiedAt             = SYSUTCDATETIME()
WHERE ProcessCode = @Pc;

PRINT 'B) Process saved.';
GO

/* ---------------------------------------------------------------------------
   C) Keys, database mapping and the five object specs.
   --------------------------------------------------------------------------- */
DECLARE @Pc     sysname        = N'$(ProcessCode)';
DECLARE @By     nvarchar(256)  = N'kam-deploy';
DECLARE @Reason nvarchar(1000) = N'Inbound purchase order retention.';
DECLARE @CsId   bigint = NULL;
DECLARE @KsId   int    = NULL;
DECLARE @OsId   int    = NULL;

-- Two keys only. arch.WorkBatchKey's primary key is (WorkBatchId, Key1, Key2), so
-- uniqueness must live in Key1+Key2 - and here it does, because that pair IS the
-- clustered primary key of the anchor table.
EXEC arch.usp_Api_SaveProcessKeySpec
    @ProcessKeySpecId = @KsId OUTPUT, @ProcessCode = @Pc, @RequestedBy = @By, @ChangeReason = @Reason,
    @KeyOrdinal = 1, @KeyName = N'po_number', @SourceExpressionSql = N'a.po_number',
    @SqlType = N'nvarchar(256)', @IsRequired = 1, @ConfigChangeSetId = @CsId OUTPUT;

SET @KsId = NULL;
EXEC arch.usp_Api_SaveProcessKeySpec
    @ProcessKeySpecId = @KsId OUTPUT, @ProcessCode = @Pc, @RequestedBy = @By, @ChangeReason = @Reason,
    @KeyOrdinal = 2, @KeyName = N'wh_id', @SourceExpressionSql = N'a.wh_id',
    @SqlType = N'nvarchar(256)', @IsRequired = 1, @ConfigChangeSetId = @CsId OUTPUT;

-- usp_Api_SaveProcessDatabase has NO @ProcessDatabaseId parameter - the row is
-- identified by (ProcessCode, SourceDb, ArchiveDb). Every other Save API in this
-- schema takes an id OUTPUT, so this one reads as an inconsistency and cost a
-- failed run to discover. All the per-database override parameters are left at
-- their defaults on purpose: the process-level values configured above are the
-- ones that should apply, and an override here would silently shadow them.
EXEC arch.usp_Api_SaveProcessDatabase
    @ProcessCode = @Pc, @SourceDb = N'$(WmsDb)', @ArchiveDb = N'$(ArchiveDb)',
    @RequestedBy = @By, @ChangeReason = @Reason, @IsEnabled = 1,
    @RunOrder = $(RunOrder), @ConfigChangeSetId = @CsId OUTPUT;

/* The delete order mirrors what the application itself does on a host 'Delete':
   usp_al_import_inbound_order removes t_po_comment, then t_po_detail_comment,
   then t_po_detail, then t_po_master. Two constraints force it independently:
     - t_po_detail_comment has a CASCADE FK from t_po_detail, so it must be
       ARCHIVED before t_po_detail is deleted or the cascade destroys rows that
       were never copied. Same shape as t_order_detail_comment in the ORDER set.
     - everything else holds a NO_ACTION FK to the anchor, so the anchor is last. */
DECLARE @specs table (Ord int, Tbl sysname, Joins nvarchar(1000));
INSERT @specs VALUES
 (10, N't_po_detail_comment', N't.po_number = k.Key1 AND t.wh_id = k.Key2'),
 (20, N't_po_comment',        N't.po_number = k.Key1 AND t.wh_id = k.Key2'),
 (30, N't_po_detail',         N't.po_number = k.Key1 AND t.wh_id = k.Key2'),
 (40, N't_rcpt_ship_po',      N't.po_number = k.Key1 AND t.wh_id = k.Key2'),
 (50, N't_po_master',         N't.po_number = k.Key1 AND t.wh_id = k.Key2');

DECLARE @o int, @t sysname, @j nvarchar(1000);
DECLARE cs CURSOR LOCAL FAST_FORWARD FOR SELECT Ord, Tbl, Joins FROM @specs ORDER BY Ord;
OPEN cs; FETCH NEXT FROM cs INTO @o, @t, @j;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @OsId = NULL;
    EXEC arch.usp_Api_SaveObjectSpec
        @ObjectSpecId = @OsId OUTPUT, @ProcessCode = @Pc, @RequestedBy = @By, @ChangeReason = @Reason,
        @SourceSchema = N'dbo', @SourceTable = @t, @DeleteOrder = @o, @DeleteMode = 1,
        @TimestampExpr = NULL, @JoinToAnchorPredicateSql = @j, @AdditionalWhereSql = NULL,
        @ArchiveSchema = N'{SourceDb}', @ArchiveTable = NULL, @RequireArchiveForDelete = 1,
        @NaturalKeyLabel = N'PO_NUMBER', @ConfigChangeSetId = @CsId OUTPUT;
    FETCH NEXT FROM cs INTO @o, @t, @j;
END;
CLOSE cs; DEALLOCATE cs;

/* Index requirements. Recorded truthfully: three are genuinely satisfied, one is
   not, and the one that is not is the SELECTION scan on the anchor - which is the
   expensive one. Never created by this package (house rule, 08_source_indexes.sql). */
DECLARE @reqs table (Ord int, Typ nvarchar(20), Tbl sysname, Cols nvarchar(400), Note nvarchar(1000));
INSERT @reqs VALUES
 (1, N'SELECTION', N't_po_master', N'status,closed_date',
     N'MISSING - t_po_master has pk_po_master (po_number, wh_id) plus indexes on wh_id, type_id, vendor_code and display_po_number, but NOTHING on status or closed_date, so the retention scan reads the whole table each pass. Suggested for the schema owner: CREATE NONCLUSTERED INDEX IX_t_po_master_status_closed ON dbo.t_po_master (status, closed_date).'),
 (2, N'JOIN', N't_po_detail', N'po_number,wh_id',
     N'Satisfied by the existing i_po_detail_po_number_wh_id (po_number, wh_id) - the join seeks.'),
 (3, N'JOIN', N't_po_comment', N'po_number,wh_id',
     N'Satisfied by the existing i_po_comment_key_1 (po_number, wh_id) - the join seeks.'),
 (4, N'JOIN', N't_rcpt_ship_po', N'po_number,wh_id',
     N'Satisfied by the existing i_rcpt_ship_po_po_number_wh_id (po_number, wh_id) - the join seeks. The table is a heap, but pk_rcpt_ship_po is a nonclustered unique key so rows are addressable.'),
 (5, N'JOIN', N't_po_detail_comment', N'po_number,wh_id',
     N'Partially satisfied: i_po_detail_comment_po_number_ leads on po_number, and uk_po_detail_comment leads on (wh_id, po_number). Either can seek on part of the predicate. NOTE that arch.usp_ValidateIndexRequirements only tests whether the required columns APPEAR as key columns, not whether they LEAD - so a trailing-column match reports as satisfied while still scanning. Judge seek quality from the index definition, not from the validation verdict.');

DECLARE @ro int, @rt nvarchar(20), @rtb sysname, @rc nvarchar(400), @rn nvarchar(1000);
DECLARE @IrId int;
DECLARE cr CURSOR LOCAL FAST_FORWARD FOR SELECT Ord, Typ, Tbl, Cols, Note FROM @reqs ORDER BY Ord;
OPEN cr; FETCH NEXT FROM cr INTO @ro, @rt, @rtb, @rc, @rn;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @IrId = NULL;
    EXEC arch.usp_Api_SaveIndexRequirement
        @IndexRequirementId = @IrId OUTPUT, @ProcessCode = @Pc, @RequestedBy = @By, @ChangeReason = @Reason,
        @RequirementType = @rt, @SourceSchema = N'dbo', @SourceTable = @rtb,
        @KeyColumnsCsv = @rc, @IsMandatory = 0, @Notes = @rn,
        @ConfigChangeSetId = @CsId OUTPUT;
    FETCH NEXT FROM cr INTO @ro, @rt, @rtb, @rc, @rn;
END;
CLOSE cr; DEALLOCATE cr;

PRINT 'C) Keys, database mapping, five object specs and five index requirements saved.';
GO

/* ---------------------------------------------------------------------------
   D) THE SHIPMENT-LINK EXPOSURE, AS A NUMBER

   The gate we cannot configure, measured instead. A script may use subqueries
   even though a configuration field may not, so the exposure is quantified here
   and must be reviewed before the set is enabled for real deletes.
   --------------------------------------------------------------------------- */
DECLARE @Ret int = $(RetentionDays), @Lag int = 1440;
DECLARE @Cut datetime2(0) = DATEADD(MINUTE, -@Lag, DATEADD(DAY, -@Ret, CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz nvarchar(200) = N'$(SourceTimezone)';

DECLARE @rep nvarchar(max) = N'
;WITH elig AS
(
    SELECT a.po_number, a.wh_id
    FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_po_master a
    WHERE a.status = N''C'' AND a.closed_date IS NOT NULL
      AND CAST(CAST(a.closed_date AS datetime2) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
)
SELECT Section = ''D_EXPOSURE'',
       EligiblePOs        = (SELECT COUNT_BIG(*) FROM elig),
       WithShipmentLink   = (SELECT COUNT_BIG(DISTINCT e.po_number)
                             FROM elig e
                             JOIN ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_rcpt_ship_po rsp
                               ON rsp.po_number = e.po_number AND rsp.wh_id = e.wh_id),
       LinkedShipmentOpen = (SELECT COUNT_BIG(DISTINCT e.po_number)
                             FROM elig e
                             JOIN ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_rcpt_ship_po rsp
                               ON rsp.po_number = e.po_number AND rsp.wh_id = e.wh_id
                             JOIN ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_rcpt_ship rs
                               ON rs.wh_id = rsp.wh_id AND rs.shipment_number = rsp.shipment_number
                             WHERE ISNULL(rs.status, N'''') <> N''C''),
       Verdict = CASE WHEN (SELECT COUNT_BIG(DISTINCT e.po_number)
                            FROM elig e
                            JOIN ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_rcpt_ship_po rsp
                              ON rsp.po_number = e.po_number AND rsp.wh_id = e.wh_id
                            JOIN ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_rcpt_ship rs
                              ON rs.wh_id = rsp.wh_id AND rs.shipment_number = rsp.shipment_number
                            WHERE ISNULL(rs.status, N'''') <> N''C'') = 0
                      THEN ''OK - no eligible PO is linked to a shipment that is still open''
                      ELSE ''REVIEW - some eligible POs are linked to OPEN shipments; archiving them removes that link from the live shipment (the rows are kept in the archive)''
                 END;';
EXEC sys.sp_executesql @rep, N'@Cut datetime2(0), @Tz nvarchar(200)', @Cut = @Cut, @Tz = @Tz;

PRINT '';
PRINT 'D) Cutoff (UTC): ' + CONVERT(varchar(30), @Cut, 126);
PRINT '    EligiblePOs        - closed purchase orders past retention';
PRINT '    WithShipmentLink   - of those, how many have t_rcpt_ship_po rows';
PRINT '    LinkedShipmentOpen - of those, how many link to a shipment NOT closed';
PRINT '    Only the last number is a decision. Zero means there is nothing to weigh.';
GO

/* ---------------------------------------------------------------------------
   E) Verification
   --------------------------------------------------------------------------- */
PRINT '';
PRINT '27_seed_po_set: configuration applied.';
GO

SELECT Section = 'PROCESS', p.ProcessCode, p.SelectionStrategy, p.Mode, p.RetentionDays,
       p.CutoffSafetyLagMinutes, p.BatchDocCount, p.MaxRowsPerTransaction,
       p.DocKeyLabel, p.AnchorTable, p.IsEnabled
FROM arch.Process p WHERE p.ProcessCode = N'$(ProcessCode)';

SELECT Section = 'KEYS', ks.KeyOrdinal, ks.KeyName, ks.SourceExpressionSql
FROM arch.ProcessKeySpec ks JOIN arch.Process p ON p.ProcessId = ks.ProcessId
WHERE p.ProcessCode = N'$(ProcessCode)' ORDER BY ks.KeyOrdinal;

SELECT Section = 'SPECS', os.DeleteOrder, os.SourceTable, os.JoinToAnchorPredicateSql
FROM arch.ObjectSpec os JOIN arch.Process p ON p.ProcessId = os.ProcessId
WHERE p.ProcessCode = N'$(ProcessCode)' ORDER BY os.DeleteOrder;

-- The anchor must be last, or the header goes before its children.
SELECT Section = 'ANCHOR_IS_LAST', p.ProcessCode, p.AnchorTable, AnchorOrder = a.DeleteOrder,
       MaxOrder = (SELECT MAX(os2.DeleteOrder) FROM arch.ObjectSpec os2 WHERE os2.ProcessId = p.ProcessId),
       Verdict = CASE WHEN a.DeleteOrder = (SELECT MAX(os2.DeleteOrder) FROM arch.ObjectSpec os2 WHERE os2.ProcessId = p.ProcessId)
                      THEN 'ok' ELSE '*** ANCHOR IS NOT LAST ***' END
FROM arch.Process p
JOIN arch.ObjectSpec a ON a.ProcessId = p.ProcessId AND a.SourceTable = p.AnchorTable
WHERE p.ProcessCode = N'$(ProcessCode)';

-- No table in two sets. Adding an inbound set is exactly when this could happen.
SELECT Section = 'OVERLAP_CHECK', os.SourceTable, Sets = COUNT(DISTINCT os.ProcessId),
       Which = STUFF((SELECT N', ' + p2.ProcessCode
                      FROM arch.ObjectSpec os2 JOIN arch.Process p2 ON p2.ProcessId = os2.ProcessId
                      WHERE os2.SourceTable = os.SourceTable
                      ORDER BY p2.ProcessCode FOR XML PATH('')), 1, 2, '')
FROM arch.ObjectSpec os
GROUP BY os.SourceTable
HAVING COUNT(DISTINCT os.ProcessId) > 1;

SELECT Section = 'RUNORDER', p.ProcessCode, pd.SourceDb, pd.ArchiveDb, pd.RunOrder, pd.IsEnabled
FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId = pd.ProcessId
ORDER BY pd.RunOrder;
GO

PRINT '';
PRINT 'NEXT, IN THIS ORDER - none of it is optional:';
PRINT '  1) 06_provision.sql (or usp_ProvisionArchiveTablesForProcess for AAD_PO_ARCH)';
PRINT '     - the archive tables do not exist yet.';
PRINT '  2) 053 - the runner has NO grant on the five PO tables until it is re-run.';
PRINT '  3) 07_validate.sql - expect one SELECTION index WARN on t_po_master.';
PRINT '  4) Review section D above BEFORE enabling this set for real deletes.';
GO
