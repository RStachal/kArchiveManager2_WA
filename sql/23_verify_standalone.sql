-- ============================================================================
-- 23 - VERIFY the standalone table processes (read-only)
-- ============================================================================
-- Run after 22_simulate_job.sql.
--
-- Section B is the proof that matters: for every configured table,
--     source rows now + archive rows now  ==  source rows before + archive rows before
-- Note it compares against the FULL baseline (source AND archive). Comparing
-- against the source count alone gives a false mismatch whenever the archive
-- already held rows from an earlier run - which it usually does.
-- ============================================================================
:setvar AdminDb   "kArchiveManagerAdmin"
:setvar WmsDb     "AAD"
:setvar AdvDb     "ADV"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar RetentionDays "90"
:setvar SourceTimezone "Central European Standard Time"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

PRINT '=== A) Run log ===';
GO
SELECT
    r.RunId,
    RunStatus  = r.Status,
    p.ProcessCode,
    p.SelectionStrategy,
    r.SourceDb,
    ri.CutoffUtc,
    Documents  = ri.DocsDone,
    ri.RowsArchived,
    ri.RowsDeleted,
    Divergence = ri.RowsArchived - ri.RowsDeleted,
    ItemStatus = ri.Status,
    r.StartedAt,
    ri.ErrorMessage
FROM arch.Run r
JOIN arch.RunItem ri ON ri.RunId = r.RunId
JOIN arch.Process p ON p.ProcessId = ri.ProcessId
WHERE p.ProcessCode IN (N'AAD_ORDER_ARCH', N'AAD_TRANLOG_ARCH', N'AAD_PICKDETAIL_ARCH', N'AAD_WORKQ_ARCH', N'ADV_LOGMSG_ARCH')
ORDER BY r.RunId DESC;

SELECT
    Section = 'A_PER_TABLE',
    p.ProcessCode,
    rio.SourceTable,
    rio.RowsArchived,
    rio.RowsDeleted,
    Divergence = rio.RowsArchived - rio.RowsDeleted,
    Verdict = CASE WHEN rio.RowsArchived = rio.RowsDeleted THEN 'OK'
                   ELSE 'STOP - archived and deleted counts disagree' END
FROM arch.RunItemObject rio
JOIN arch.RunItem ri ON ri.RunItemId = rio.RunItemId
JOIN arch.Run r ON r.RunId = ri.RunId
JOIN arch.Process p ON p.ProcessId = ri.ProcessId
WHERE r.Status <> N'DRYRUN'
  AND p.ProcessCode IN (N'AAD_ORDER_ARCH', N'AAD_TRANLOG_ARCH', N'AAD_PICKDETAIL_ARCH', N'AAD_WORKQ_ARCH', N'ADV_LOGMSG_ARCH')
ORDER BY r.RunId DESC, p.ProcessCode, rio.SourceTable;
GO

PRINT '';
PRINT '=== B) Source + archive totals per configured table ===';
GO
-- Built dynamically from the configuration, so it follows the ObjectSpec set
-- rather than a hardcoded table list. DISTINCT matters: t_work_q_dependency has
-- two ObjectSpecs (parent side and dependent side) and must be counted once.
DECLARE @sql nvarchar(max) = N'';

-- The archive-side count must be emitted as a literal 0 when the archive table
-- does not exist yet (an un-provisioned or disabled process). A guard INSIDE the
-- generated SQL would not help: an unresolvable object name is a COMPILE-time
-- error, so the whole batch fails regardless of any IF around it. The existence
-- check therefore happens HERE, while the SQL is being built.
SELECT @sql = @sql +
    CASE WHEN @sql = N'' THEN N'' ELSE N' UNION ALL ' END +
    N'SELECT ' + QUOTENAME(x.ProcessCode, '''') + N', ' + QUOTENAME(x.SourceDb, '''') + N', '
      + QUOTENAME(x.SourceTable, '''') + N', '
      + N'(SELECT COUNT_BIG(*) FROM ' + QUOTENAME(x.SourceDb) + N'.' + QUOTENAME(x.SourceSchema) + N'.' + QUOTENAME(x.SourceTable) + N'), '
      + CASE
            WHEN OBJECT_ID(QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(x.SourceDb) + N'.' + QUOTENAME(x.SourceTable), N'U') IS NULL
                THEN N'CONVERT(bigint, 0)'
            ELSE N'(SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(x.SourceDb) + N'.' + QUOTENAME(x.SourceTable) + N')'
        END
FROM
(
    SELECT DISTINCT p.ProcessCode, pd.SourceDb, os.SourceSchema, os.SourceTable
    FROM arch.ObjectSpec os
    JOIN arch.Process p ON p.ProcessId = os.ProcessId
    JOIN arch.ProcessDatabase pd ON pd.ProcessId = p.ProcessId
    WHERE p.ProcessCode IN (N'AAD_ORDER_ARCH', N'AAD_TRANLOG_ARCH', N'AAD_PICKDETAIL_ARCH', N'AAD_WORKQ_ARCH', N'ADV_LOGMSG_ARCH')
      AND OBJECT_ID(QUOTENAME(pd.SourceDb) + N'.' + QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable), N'U') IS NOT NULL
) AS x;

IF @sql = N''
    PRINT 'No configured objects found for these processes.';
ELSE
BEGIN
    CREATE TABLE #Now (ProcessCode sysname, SourceDb sysname, SourceTable sysname, SourceRows bigint, ArchiveRows bigint);
    SET @sql = N'INSERT #Now(ProcessCode, SourceDb, SourceTable, SourceRows, ArchiveRows) ' + @sql + N';';
    EXEC sys.sp_executesql @sql;

    SELECT
        Section     = 'B_TOTALS',
        n.ProcessCode,
        n.SourceDb,
        n.SourceTable,
        SourceRows  = n.SourceRows,
        ArchiveRows = n.ArchiveRows,
        Total_      = n.SourceRows + n.ArchiveRows
    FROM #Now n
    ORDER BY n.ProcessCode, n.SourceTable;

    -- If 11_realrun_guarded.sql captured a baseline, reconcile against it.
    -- Dynamic SQL again, for the same compile-time reason: dbo.KamDeployBaseline
    -- only exists once that script has run, and a static reference to a missing
    -- table fails the whole batch even inside an IF that is never taken.
    IF OBJECT_ID(N'dbo.KamDeployBaseline', N'U') IS NOT NULL
    BEGIN
        DECLARE @rec nvarchar(max) = N'
        IF EXISTS (SELECT 1 FROM dbo.KamDeployBaseline)
        BEGIN
            WITH b AS
            (
                SELECT ProcessCode, SourceTable, SourceRows, ArchiveRows,
                       rn = ROW_NUMBER() OVER (PARTITION BY ProcessCode, SourceTable ORDER BY CapturedAtUtc ASC, BaselineId ASC)
                FROM dbo.KamDeployBaseline
            )
            SELECT
                Section       = ''B_RECONCILIATION'',
                n.ProcessCode,
                n.SourceTable,
                BaselineTotal = b.SourceRows + b.ArchiveRows,
                NowTotal      = n.SourceRows + n.ArchiveRows,
                Moved         = b.SourceRows - n.SourceRows,
                Verdict       = CASE
                                    WHEN b.SourceRows + b.ArchiveRows = n.SourceRows + n.ArchiveRows
                                         THEN ''OK - nothing lost, nothing duplicated''
                                    WHEN b.SourceRows + b.ArchiveRows > n.SourceRows + n.ArchiveRows
                                         THEN ''STOP - ROWS LOST''
                                    ELSE ''WARN - total grew (new business rows arrived, or archive duplicates)''
                                END
            FROM #Now n
            JOIN b ON b.ProcessCode = n.ProcessCode AND b.SourceTable = n.SourceTable AND b.rn = 1
            ORDER BY n.ProcessCode, n.SourceTable;
        END
        ELSE
            PRINT ''Baseline table exists but is empty - section B shows current totals only.'';';
        EXEC sys.sp_executesql @rec;
    END
    ELSE
        PRINT 'No baseline captured (11_realrun_guarded.sql not used) - section B shows current totals only.';

    DROP TABLE #Now;
END;
GO

PRINT '';
PRINT '=== C) Enforced-FK children actually reached the archive ===';
GO
-- This is the specific thing the ANCHOR-with-self design exists for. If these
-- come back empty while their parents were archived, the child rows were lost.
DECLARE @fk nvarchar(max) = N'
SELECT Section = ''C_FK_CHILDREN'', TableName = ''t_tran_log_reason'',
       SourceRows  = (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log_reason),
       ArchiveRows = (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_tran_log_reason)
UNION ALL
SELECT ''C_FK_CHILDREN'', ''t_tran_log_sn'',
       (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log_sn),
       (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_tran_log_sn)
UNION ALL
SELECT ''C_FK_CHILDREN'', ''t_allocation'',
       (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_allocation),
       ISNULL((SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_allocation), 0);';
EXEC sys.sp_executesql @fk;
GO

-- No archived parent may be left without its children having gone too.
DECLARE @orph nvarchar(max) = N'
SELECT
    Section = ''C_ORPHAN_CHECK'',
    OrphanReasonRows = (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log_reason r
                        WHERE NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log l WHERE l.tran_log_id = r.tran_log_id)),
    OrphanSnRows     = (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log_sn s
                        WHERE NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log l WHERE l.tran_log_id = s.tran_log_id)),
    OrphanAllocRows  = (SELECT COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_allocation a
                        WHERE a.pick_id IS NOT NULL
                          AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_pick_detail p WHERE p.pick_id = a.pick_id)),
    Verdict = ''All three must be 0. A non-zero value means a parent was archived while its child stayed behind.'';';
EXEC sys.sp_executesql @orph;
GO

PRINT '';
PRINT '=== D) Still eligible in the source (capped runs leave a remainder) ===';
GO
DECLARE @CutoffUtc datetime2(0) =
    DATEADD(MINUTE, -1440, DATEADD(DAY, -$(RetentionDays), CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz nvarchar(200) = N'$(SourceTimezone)';

DECLARE @rem nvarchar(max) = N'
SELECT Section = ''D_REMAINING'', ProcessCode = ''AAD_TRANLOG_ARCH'', StillEligible = COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log l
WHERE l.start_tran_date > ''19000102''
  AND CAST(TRY_CONVERT(datetime2, l.start_tran_date) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''D_REMAINING'', ''AAD_PICKDETAIL_ARCH'', COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_pick_detail p
WHERE p.status = N''SHIPPED''
  AND CAST(TRY_CONVERT(datetime2, p.create_date) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''D_REMAINING'', ''AAD_WORKQ_ARCH'', COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_work_q q
WHERE q.datetime_stamp IS NOT NULL AND q.work_status IN (N''C'', N''P'')
  AND CAST(TRY_CONVERT(datetime2, q.datetime_stamp) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut;';
EXEC sys.sp_executesql @rem, N'@Cut datetime2(0), @Tz nvarchar(200)', @Cut = @CutoffUtc, @Tz = @Tz;

-- ADV. No column precondition here: the process anchors on the table's natural
-- composite identity (24_seed_logmessage_anchor.sql), so it needs no added
-- column. An earlier revision gated this on kam_row_id, which no longer exists.
IF OBJECT_ID(N'$(AdvDb)' + N'.dbo.t_log_message', N'U') IS NOT NULL
BEGIN
    DECLARE @rem2 nvarchar(max) = N'
    SELECT Section = ''D_REMAINING'', ProcessCode = ''ADV_LOGMSG_ARCH'', StillEligible = COUNT_BIG(*)
    FROM ' + QUOTENAME(N'$(AdvDb)') + N'.dbo.t_log_message m
    WHERE CAST(TRY_CONVERT(datetime2, m.logged_on_utc) AT TIME ZONE N''UTC'' AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut;';
    EXEC sys.sp_executesql @rem2, N'@Cut datetime2(0)', @Cut = @CutoffUtc;
END
ELSE
    PRINT 'ADV_LOGMSG_ARCH not evaluated: ADV.dbo.t_log_message does not exist.';
GO

PRINT '';
PRINT '=== E) Operational health ===';
GO
BEGIN TRY
    SELECT HealthArea, Severity, ProcessCode, SourceDb, RunId, Status, DocsDone, RowsDeleted, RowsArchived, Details
    FROM arch.v_OperationalHealth
    ORDER BY CASE Severity WHEN N'ERROR' THEN 0 WHEN N'WARN' THEN 1 ELSE 2 END, HealthArea;
END TRY
BEGIN CATCH
    PRINT 'arch.v_OperationalHealth unavailable: ' + ERROR_MESSAGE();
END CATCH;
GO

PRINT '';
PRINT '23_verify_standalone: done.';
GO

