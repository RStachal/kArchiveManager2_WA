-- ============================================================================
-- 33 - VERIFY THE BULK RUN: WERE ONLY THE CONFIGURED ROWS PROCESSED?
-- ============================================================================
-- Run after 40_perf_seed.sql and one or more real runs. It answers three
-- questions, and section C is the one that actually matters.
--
--   A  RECONCILIATION - does source + archive still equal what was seeded? A row
--      that is in neither was deleted without being copied, which is the one
--      failure this product must never have.
--   B  COMPLETENESS   - is anything eligible left? Not a failure on its own: the
--      order and PO sets cap at BatchDocCount x MaxBatchesPerRun = 50 x 200 =
--      10 000 documents per run, and the seed creates 20 000 eligible, so those
--      two legitimately need a second run. The section says which.
--   C  THE GATES      - does the ARCHIVE contain any row that the configuration
--      was supposed to hold back? This is the direct test of "only the configured
--      records were processed", and it is asked of the archive rather than of the
--      source, because a source count cannot distinguish "correctly kept" from
--      "wrongly never selected". Every count here must be 0.
--   D  ORPHANS        - did any child outlive its archived parent?
--   E  HEALTH         - the product's own operational view.
--
-- WHY C IS ASKED THIS WAY. The gated rows were seeded with the exact attribute
-- each set's gate tests - a non-terminal status, or a date inside the retention
-- window. So if a gated row reached the archive, the predicate matched something
-- it should not have. There is no interpretation needed: non-zero is a defect.
-- ============================================================================
:setvar WmsDb "AAD"
:setvar AdvDb "ADV"
:setvar AdminDb "kArchiveManagerAdmin"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar RetentionDays "90"
:setvar SourceTimezone "Central European Standard Time"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

DECLARE @Cut datetime2(0) = DATEADD(MINUTE, -1440, DATEADD(DAY, -$(RetentionDays), CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz nvarchar(200) = N'$(SourceTimezone)';
PRINT '=== Bulk verification. AAD cutoff (UTC): ' + CONVERT(varchar(30), @Cut, 126) + ' ===';
GO

/* ===========================================================================
   A) RECONCILIATION - source + archive must still equal the seeded total
   =========================================================================== */
PRINT '';
PRINT '=== A) Reconciliation: nothing may be deleted without being archived ===';
GO
DECLARE @recon nvarchar(max) = N'
SELECT Section=''A_RECON'', TableName, Src, Arc, Total = Src + Arc
FROM (
    SELECT TableName=''t_tran_log'',
           Src=(SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log WHERE generic_text1=N''KAMTEST''),
           Arc=(SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_tran_log WHERE generic_text1=N''KAMTEST'')
    UNION ALL SELECT ''t_pick_detail'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_pick_detail WHERE lot_number=N''KAMTEST''),
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_pick_detail WHERE lot_number=N''KAMTEST'')
    UNION ALL SELECT ''t_pick_task_uom'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_pick_task_uom WHERE lot_number=N''KAMTEST''),
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_pick_task_uom WHERE lot_number=N''KAMTEST'')
    UNION ALL SELECT ''t_work_q'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_work_q WHERE work_q_id LIKE N''KAMTQ%''),
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_work_q WHERE work_q_id LIKE N''KAMTQ%'')
    UNION ALL SELECT ''t_order'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_order WHERE order_number LIKE N''KAMT-OF%''),
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_order WHERE order_number LIKE N''KAMT-OF%'')
    UNION ALL SELECT ''t_order_detail'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_order_detail WHERE order_number LIKE N''KAMT-OF%''),
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_order_detail WHERE order_number LIKE N''KAMT-OF%'')
    UNION ALL SELECT ''t_pick_container'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_pick_container WHERE container_id LIKE N''KAMTC-B%''),
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_pick_container WHERE container_id LIKE N''KAMTC-B%'')
    UNION ALL SELECT ''t_po_master'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_po_master WHERE po_number LIKE N''KAMPO-B%''),
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_po_master WHERE po_number LIKE N''KAMPO-B%'')
    UNION ALL SELECT ''t_po_detail'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_po_detail WHERE po_number LIKE N''KAMPO-B%''),
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_po_detail WHERE po_number LIKE N''KAMPO-B%'')
    UNION ALL SELECT ''t_po_detail_comment'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_po_detail_comment WHERE po_number LIKE N''KAMPO-B%''),
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_po_detail_comment WHERE po_number LIKE N''KAMPO-B%'')
    UNION ALL SELECT ''t_rcpt_ship_po'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_rcpt_ship_po WHERE po_number LIKE N''KAMPO-B%''),
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_rcpt_ship_po WHERE po_number LIKE N''KAMPO-B%'')
    UNION ALL SELECT ''ADV.t_log_message'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(AdvDb)') + N'.dbo.t_log_message WHERE machine_id=N''KAMTEST''),
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(AdvDb)') + N'.t_log_message WHERE machine_id=N''KAMTEST'')
) x ORDER BY TableName;';
EXEC sys.sp_executesql @recon;

PRINT 'Compare Total against the seed log. A Total BELOW the seeded count means';
PRINT 'rows were deleted without being archived - that is a hard failure.';
PRINT 'ADV is the documented exception: the vendor purge may remove rows from the';
PRINT 'source independently, so its Total can legitimately fall. 41_perf_test.sql';
PRINT 'PURGE_INTERFERENCE says whether that happened.';
GO

/* ===========================================================================
   B) COMPLETENESS - what is still eligible, and is that expected?
   =========================================================================== */
PRINT '';
PRINT '=== B) Still eligible (a per-run document cap is not a failure) ===';
GO
DECLARE @Cut datetime2(0) = DATEADD(MINUTE, -1440, DATEADD(DAY, -$(RetentionDays), CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz nvarchar(200) = N'$(SourceTimezone)';

DECLARE @elig nvarchar(max) = N'
SELECT Section=''B_ELIGIBLE'', ProcessCode=''AAD_ORDER_ARCH'', StillEligible=COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_order o
WHERE o.order_number LIKE N''KAMT-OF%'' AND o.status IN (N''S'',N''D'')
  AND o.lock_flag IS NULL AND o.consolidated_order_number IS NULL
  AND CAST(CAST(COALESCE(NULLIF(o.actual_ship_date,''19000101''), o.order_date) AS datetime2)
      AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''B_ELIGIBLE'', ''AAD_PICKDETAIL_ARCH'', COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_pick_detail p
WHERE p.lot_number=N''KAMTEST'' AND p.status=N''SHIPPED''
  AND CAST(TRY_CONVERT(datetime2, p.create_date) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''B_ELIGIBLE'', ''AAD_TRANLOG_ARCH'', COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log l
WHERE l.generic_text1=N''KAMTEST'' AND l.start_tran_date > ''19000102''
  AND CAST(TRY_CONVERT(datetime2, l.start_tran_date) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''B_ELIGIBLE'', ''AAD_WORKQ_ARCH'', COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_work_q q
WHERE q.work_q_id LIKE N''KAMTQ%'' AND q.datetime_stamp IS NOT NULL AND q.work_status IN (N''C'',N''P'')
  AND CAST(TRY_CONVERT(datetime2, q.datetime_stamp) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''B_ELIGIBLE'', ''AAD_PO_ARCH'', COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_po_master m
WHERE m.po_number LIKE N''KAMPO-B%'' AND m.status=N''C'' AND m.closed_date IS NOT NULL
  AND CAST(CAST(m.closed_date AS datetime2) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut;';
EXEC sys.sp_executesql @elig, N'@Cut datetime2(0), @Tz nvarchar(200)', @Cut=@Cut, @Tz=@Tz;

PRINT 'ORDER and PO cap at 10 000 documents per run (BatchDocCount 50 x';
PRINT 'MaxBatchesPerRun 200), so with 20 000 eligible each they need two runs.';
PRINT 'A remainder there is expected. A remainder anywhere else is not.';
GO

/* ===========================================================================
   C) THE GATES - the archive must contain NOTHING that should have been held
   =========================================================================== */
PRINT '';
PRINT '=== C) Gate violations in the ARCHIVE. Every count must be 0. ===';
PRINT 'RUN THIS ONLY WHEN NOTHING IS IN FLIGHT. arch.WorkBatch must hold no';
PRINT 'Running and no Paused row, and no RUN job may be executing. The two';
PRINT 'child checks below ("container only for an archived order",';
PRINT '"task_uom only for an archived pick") ask whether an archived CHILD';
PRINT 'still has its parent in the source. ANCHOR deletes the anchor LAST, so';
PRINT 'mid-batch that is the NORMAL state, not a violation - the children are';
PRINT 'already archived and the parent has not been reached yet. Measured on';
PRINT 'the reference instance while an ORDER batch was interrupted: 15 012,';
PRINT 'then 11 097, then 0 as the batches completed. Nothing was wrong.';
PRINT 'Section B says a remainder across runs is expected; this is the same';
PRINT 'fact seen from the archive side. Let the run finish, or resume the';
PRINT 'paused batches, before believing a non-zero count here.';
GO
DECLARE @Cut datetime2(0) = DATEADD(MINUTE, -1440, DATEADD(DAY, -$(RetentionDays), CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz nvarchar(200) = N'$(SourceTimezone)';

-- No dynamic SQL here, deliberately. sqlcmd substitutes $(ArchiveDb) and $(WmsDb)
-- BEFORE the batch is parsed, so plain three-part names work and stay readable.
-- Building this as a string needed three levels of quote doubling and produced
-- two syntax errors (Msg 102) before that was obvious. Dynamic SQL is only
-- necessary where an object may not exist at compile time or where sys.columns
-- has to be read cross-database - neither applies to a plain table reference.
SELECT Section = 'C_GATE', ProcessCode, Gate, Violations,
       Verdict = CASE WHEN Violations = 0 THEN 'ok'
                      ELSE '*** VIOLATION - the archive holds rows the gate should have kept ***' END
FROM (
    SELECT ProcessCode = 'AAD_ORDER_ARCH', Gate = 'status IN (S,D)',
           Violations = (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].[$(WmsDb)].t_order
                         WHERE order_number LIKE N'KAMT-OF%' AND status NOT IN (N'S', N'D'))
    UNION ALL
    SELECT 'AAD_ORDER_ARCH', 'order date older than cutoff',
           (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].[$(WmsDb)].t_order
            WHERE order_number LIKE N'KAMT-OF%'
              AND CAST(CAST(COALESCE(NULLIF(actual_ship_date,'19000101'), order_date) AS datetime2)
                  AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) >= @Cut)
    UNION ALL
    SELECT 'AAD_PICKDETAIL_ARCH', 'status = SHIPPED',
           (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].[$(WmsDb)].t_pick_detail
            WHERE lot_number = N'KAMTEST' AND status <> N'SHIPPED')
    UNION ALL
    SELECT 'AAD_PICKDETAIL_ARCH', 'create_date older than cutoff',
           (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].[$(WmsDb)].t_pick_detail
            WHERE lot_number = N'KAMTEST'
              AND CAST(TRY_CONVERT(datetime2, create_date) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) >= @Cut)
    UNION ALL
    SELECT 'AAD_TRANLOG_ARCH', 'start_tran_date older than cutoff',
           (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].[$(WmsDb)].t_tran_log
            WHERE generic_text1 = N'KAMTEST'
              AND CAST(TRY_CONVERT(datetime2, start_tran_date) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) >= @Cut)
    UNION ALL
    SELECT 'AAD_WORKQ_ARCH', 'work_status IN (C,P)',
           (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].[$(WmsDb)].t_work_q
            WHERE work_q_id LIKE N'KAMTQ%' AND work_status NOT IN (N'C', N'P'))
    UNION ALL
    SELECT 'AAD_WORKQ_ARCH', 'datetime_stamp older than cutoff',
           (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].[$(WmsDb)].t_work_q
            WHERE work_q_id LIKE N'KAMTQ%'
              AND CAST(TRY_CONVERT(datetime2, datetime_stamp) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) >= @Cut)
    UNION ALL
    SELECT 'AAD_PO_ARCH', 'status = C',
           (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].[$(WmsDb)].t_po_master
            WHERE po_number LIKE N'KAMPO-B%' AND status <> N'C')
    UNION ALL
    SELECT 'AAD_PO_ARCH', 'closed_date set and older than cutoff',
           (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].[$(WmsDb)].t_po_master
            WHERE po_number LIKE N'KAMPO-B%'
              AND (closed_date IS NULL
                   OR CAST(CAST(closed_date AS datetime2) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) >= @Cut))
    UNION ALL
    -- The two children added by 26 must never appear for a document that was
    -- itself held back: a container whose order is still in the source, or a
    -- task_uom row whose pick is still in the source, means over-matching.
    SELECT 'AAD_ORDER_ARCH', 'container only for an archived order',
           (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].[$(WmsDb)].t_pick_container c
            WHERE c.container_id LIKE N'KAMTC-B%'
              AND EXISTS (SELECT 1 FROM [$(WmsDb)].dbo.t_order o
                          WHERE o.order_number = c.order_number AND o.wh_id = c.wh_id))
    UNION ALL
    SELECT 'AAD_PICKDETAIL_ARCH', 'task_uom only for an archived pick',
           (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].[$(WmsDb)].t_pick_task_uom u
            WHERE u.lot_number = N'KAMTEST'
              AND EXISTS (SELECT 1 FROM [$(WmsDb)].dbo.t_pick_detail p WHERE p.pick_id = u.pick_id))
    UNION ALL
    -- t_rcpt_ship is in NO set, so the archive must not even hold a table for it.
    SELECT '(none)', 't_rcpt_ship is in no set - archive must have no such table',
           (SELECT COUNT_BIG(*) FROM [$(ArchiveDb)].sys.tables t
            JOIN [$(ArchiveDb)].sys.schemas s ON s.schema_id = t.schema_id
            WHERE t.name = N't_rcpt_ship' AND s.name = N'$(WmsDb)')
) g
ORDER BY ProcessCode, Gate;
GO

/* ===========================================================================
   D) ORPHANS - no child may outlive its archived parent
   =========================================================================== */
PRINT '';
PRINT '=== D) Orphan check. Every count must be 0. ===';
GO
DECLARE @orph nvarchar(max) = N'
SELECT Section=''D_ORPHAN'', Relationship, Orphans,
       Verdict = CASE WHEN Orphans = 0 THEN ''ok'' ELSE ''*** ORPHANED - parent archived, child left behind ***'' END
FROM (
    SELECT Relationship=''t_allocation -> t_pick_detail'',
           Orphans=(SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_allocation a
                    WHERE EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_pick_detail ap WHERE ap.pick_id = a.pick_id)
                      AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_pick_detail p WHERE p.pick_id = a.pick_id))
    UNION ALL
    SELECT ''t_pick_task_uom -> t_pick_detail'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_pick_task_uom u
            WHERE u.lot_number = N''KAMTEST''
              AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_pick_detail p WHERE p.pick_id = u.pick_id))
    UNION ALL
    SELECT ''t_tran_log_reason -> t_tran_log'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log_reason r
            WHERE r.reason_id = N''KAMT''
              AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log l WHERE l.tran_log_id = r.tran_log_id))
    UNION ALL
    SELECT ''t_tran_log_sn -> t_tran_log'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log_sn sn
            WHERE sn.serial_number LIKE N''KAMTSN%''
              AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log l WHERE l.tran_log_id = sn.tran_log_id))
    UNION ALL
    SELECT ''t_order_detail -> t_order'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_order_detail d
            WHERE d.order_number LIKE N''KAMT-OF%''
              AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_order o WHERE o.order_number = d.order_number AND o.wh_id = d.wh_id))
    UNION ALL
    SELECT ''t_pick_container -> t_order'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_pick_container c
            WHERE c.container_id LIKE N''KAMTC-B%''
              AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_order o WHERE o.order_number = c.order_number AND o.wh_id = c.wh_id))
    UNION ALL
    SELECT ''t_po_detail -> t_po_master'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_po_detail d
            WHERE d.po_number LIKE N''KAMPO-B%''
              AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_po_master m WHERE m.po_number = d.po_number AND m.wh_id = d.wh_id))
    UNION ALL
    SELECT ''t_po_detail_comment -> t_po_master'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_po_detail_comment dc
            WHERE dc.po_number LIKE N''KAMPO-B%''
              AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_po_master m WHERE m.po_number = dc.po_number AND m.wh_id = dc.wh_id))
    UNION ALL
    SELECT ''t_rcpt_ship_po -> t_po_master'',
           (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_rcpt_ship_po rsp
            WHERE rsp.po_number LIKE N''KAMPO-B%''
              AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_po_master m WHERE m.po_number = rsp.po_number AND m.wh_id = rsp.wh_id))
) o ORDER BY Relationship;';
EXEC sys.sp_executesql @orph;
GO

/* ===========================================================================
   E) The product's own health view, and the run log for this cycle
   =========================================================================== */
PRINT '';
PRINT '=== E) Runs in this cycle, and operational health ===';
GO
SELECT Section='E_RUNS', ri.RunId, p.ProcessCode, ri.Status, ri.BatchesDone, ri.DocsDone,
       ri.RowsArchived, ri.RowsDeleted, Divergence = ri.RowsArchived - ri.RowsDeleted,
       ElapsedSec = CONVERT(decimal(10,1), DATEDIFF(MILLISECOND, ri.StartedAt, ri.EndedAt) / 1000.0)
FROM arch.RunItem ri
JOIN arch.Process p ON p.ProcessId = ri.ProcessId
WHERE ri.StartedAt >= DATEADD(hour, -4, SYSUTCDATETIME()) AND ri.Status <> N'DRYRUN'
ORDER BY ri.RunItemId;

SELECT Section='E_DIVERGENCE_TOTAL',
       Archived = SUM(ri.RowsArchived), Deleted = SUM(ri.RowsDeleted),
       Divergence = SUM(ri.RowsArchived) - SUM(ri.RowsDeleted),
       Verdict = CASE WHEN SUM(ri.RowsArchived) - SUM(ri.RowsDeleted) = 0 THEN 'ok - every deleted row was archived'
                      ELSE '*** DIVERGENT ***' END
FROM arch.RunItem ri
WHERE ri.StartedAt >= DATEADD(hour, -4, SYSUTCDATETIME()) AND ri.Status <> N'DRYRUN';

SELECT Section='E_HEALTH', HealthArea, Severity,
       Detail = LEFT(ISNULL(CONVERT(nvarchar(max), Details), N'-'), 160)
FROM arch.v_OperationalHealth WHERE Severity <> N'OK' ORDER BY Severity, HealthArea;

IF NOT EXISTS (SELECT 1 FROM arch.v_OperationalHealth WHERE Severity <> N'OK')
    PRINT 'E_HEALTH: no non-OK rows.';
GO

PRINT '';
PRINT '33_verify_bulk: done. Read section C first - it is the "only the';
PRINT 'configured rows" test, and every count in it must be 0 - but only once';
PRINT 'the run has finished. See the note printed above section C.';
GO
