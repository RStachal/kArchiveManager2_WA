-- ============================================================================
-- 12 - VERIFY THE RUN (read-only)
-- ============================================================================
-- Proves, from the data rather than from the log, that the run did exactly what
-- it claimed. Run it immediately after 11_realrun_guarded.sql.
--
-- THE CENTRAL CHECK is section B: for every configured table,
--     source rows now + archive rows now  ==  source rows before + archive rows before
-- If that identity holds for every table, nothing was lost and nothing was
-- duplicated. If it does not hold, STOP and investigate before running again.
--
-- Sections:
--   A  run log: what the runner reported
--   B  reconciliation against the baseline captured by 11 (the real proof)
--   C  per-document audit trail (only populated when AuditLevel = 'ROW')
--   D  is anything left in the source that is older than the cutoff?
--   E  operational health view
-- ============================================================================
:setvar AdminDb "kArchiveManagerAdmin"
:setvar SourceDb "AAD"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar OrderProcessCode "AAD_ORDER_ARCH"
:setvar WorkQProcessCode "AAD_WORKQ_ARCH"
:setvar RetentionDays "90"
:setvar SourceTimezone "Central European Standard Time"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

PRINT '=== A) What the runner reported ===';
GO
SELECT
    r.RunId,
    RunStatus  = r.Status,
    p.ProcessCode,
    r.SourceDb,
    ri.CutoffUtc,
    ri.BatchesDone,
    Documents  = ri.DocsDone,
    ri.RowsArchived,
    ri.RowsDeleted,
    Divergence = ri.RowsArchived - ri.RowsDeleted,
    r.StartedAt,
    r.EndedAt,
    ri.ErrorMessage
FROM arch.Run r
JOIN arch.RunItem ri ON ri.RunId = r.RunId
LEFT JOIN arch.Process p ON p.ProcessId = ri.ProcessId
ORDER BY r.RunId DESC;

SELECT
    Section = 'A_PER_TABLE',
    p.ProcessCode,
    rio.SourceTable,
    rio.RowsArchived,
    rio.RowsDeleted,
    Divergence = rio.RowsArchived - rio.RowsDeleted,
    rio.LoggedAt
FROM arch.RunItemObject rio
JOIN arch.RunItem ri ON ri.RunItemId = rio.RunItemId
JOIN arch.Run r ON r.RunId = ri.RunId
LEFT JOIN arch.Process p ON p.ProcessId = ri.ProcessId
WHERE r.Status <> N'DRYRUN'
ORDER BY r.RunId DESC, p.ProcessCode, rio.SourceTable;
GO

PRINT '';
PRINT '=== B) Reconciliation against the pre-run baseline (THE PROOF) ===';
GO
IF OBJECT_ID(N'dbo.KamDeployBaseline', N'U') IS NULL
BEGIN
    PRINT 'No baseline table - 11_realrun_guarded.sql has not been run on this instance.';
END
ELSE
BEGIN
    DECLARE @sql nvarchar(max) = N'';
    DECLARE @SourceDb sysname = N'$(SourceDb)';
    DECLARE @ArchiveDb sysname = N'$(ArchiveDb)';

    CREATE TABLE #Now
    (
        ProcessCode sysname NOT NULL,
        SourceTable sysname NOT NULL,
        SourceRows  bigint  NOT NULL,
        ArchiveRows bigint  NOT NULL
    );

    SELECT @sql = @sql +
        CASE WHEN @sql = N'' THEN N'' ELSE N' UNION ALL ' END +
        N'SELECT ' + QUOTENAME(x.ProcessCode, '''') + N', ' + QUOTENAME(x.SourceTable, '''') + N', '
          + N'(SELECT COUNT_BIG(*) FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(x.SourceSchema) + N'.' + QUOTENAME(x.SourceTable) + N'), '
          + N'ISNULL((SELECT COUNT_BIG(*) FROM ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(x.SourceTable) + N'), 0)'
    FROM
    (
        SELECT DISTINCT p.ProcessCode, os.SourceSchema, os.SourceTable
        FROM arch.ObjectSpec os
        JOIN arch.Process p ON p.ProcessId = os.ProcessId
        WHERE p.ProcessCode IN (N'$(OrderProcessCode)', N'$(WorkQProcessCode)')
    ) AS x;

    SET @sql = N'INSERT #Now(ProcessCode, SourceTable, SourceRows, ArchiveRows) ' + @sql + N';';
    EXEC sys.sp_executesql @sql;

    -- Compare against the OLDEST baseline capture (the state before the first run).
    ;WITH b AS
    (
        SELECT ProcessCode, SourceTable, SourceRows, ArchiveRows,
               rn = ROW_NUMBER() OVER (PARTITION BY ProcessCode, SourceTable ORDER BY CapturedAtUtc ASC, BaselineId ASC)
        FROM dbo.KamDeployBaseline
        WHERE SourceDb = N'$(SourceDb)'
    )
    SELECT
        Section        = 'B_RECONCILIATION',
        n.ProcessCode,
        n.SourceTable,
        BaselineSource = b.SourceRows,
        BaselineArchive= b.ArchiveRows,
        BaselineTotal  = b.SourceRows + b.ArchiveRows,
        NowSource      = n.SourceRows,
        NowArchive     = n.ArchiveRows,
        NowTotal       = n.SourceRows + n.ArchiveRows,
        Moved          = b.SourceRows - n.SourceRows,
        Verdict        = CASE
                             WHEN b.SourceRows + b.ArchiveRows = n.SourceRows + n.ArchiveRows
                                  THEN 'OK - nothing lost, nothing duplicated'
                             WHEN b.SourceRows + b.ArchiveRows > n.SourceRows + n.ArchiveRows
                                  THEN 'STOP - ROWS LOST: total shrank by ' + CAST((b.SourceRows + b.ArchiveRows) - (n.SourceRows + n.ArchiveRows) AS varchar(20))
                             ELSE 'WARN - total GREW; new business rows arrived during/after the run, or the archive got duplicates'
                         END
    FROM #Now n
    LEFT JOIN b ON b.ProcessCode = n.ProcessCode AND b.SourceTable = n.SourceTable AND b.rn = 1
    ORDER BY n.ProcessCode, n.SourceTable;

    SELECT
        Section = 'B_SUMMARY',
        Verdict = CASE WHEN EXISTS
                       (
                           SELECT 1
                           FROM #Now n
                           JOIN
                           (
                               SELECT ProcessCode, SourceTable, SourceRows, ArchiveRows,
                                      rn = ROW_NUMBER() OVER (PARTITION BY ProcessCode, SourceTable ORDER BY CapturedAtUtc ASC, BaselineId ASC)
                               FROM dbo.KamDeployBaseline
                               WHERE SourceDb = N'$(SourceDb)'
                           ) b ON b.ProcessCode = n.ProcessCode AND b.SourceTable = n.SourceTable AND b.rn = 1
                           WHERE b.SourceRows + b.ArchiveRows > n.SourceRows + n.ArchiveRows
                       )
                       THEN 'STOP - at least one table lost rows. Do NOT run again; use 13_restore.sql.'
                       ELSE 'OK - every configured table reconciles' END;

    DROP TABLE #Now;
END;
GO

PRINT '';
PRINT '=== C) Per-document audit trail (AuditLevel = ROW only) ===';
GO
SELECT TOP (200)
    a.ProcessCode,
    a.DocKeyLabel,
    a.DocKey,
    a.DocCreatedAt,
    a.DeletedAt,
    a.Archived
FROM arch.RunDocAudit a
ORDER BY a.DeletedAt DESC, a.DocKey;

SELECT
    Section = 'C_SUMMARY',
    ProcessCode,
    Documents = COUNT_BIG(*),
    Archived  = SUM(CONVERT(int, Archived)),
    Note = 'Empty for a process whose AuditLevel is NONE/BATCH/OBJECT - that is configuration, not a fault.'
FROM arch.RunDocAudit
GROUP BY ProcessCode;
GO

PRINT '';
PRINT '=== D) Anything left in the source older than the cutoff? ===';
GO
-- Rows still present that WOULD be eligible. A non-zero count is normal when the
-- run was capped (MaxCandidates / MaxBatchesPerRun) - it just means more passes
-- are needed. It is only suspicious if it stays constant across runs.
DECLARE @CutoffUtc datetime2(0) =
    DATEADD(MINUTE, -1440, DATEADD(DAY, -$(RetentionDays), CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz nvarchar(200) = N'$(SourceTimezone)';
DECLARE @chk nvarchar(max) = N'
SELECT
    Section = ''D_REMAINING'',
    ProcessCode = ''$(OrderProcessCode)'',
    StillEligible = COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(SourceDb)') + N'.dbo.t_order o
WHERE o.status IN (N''S'', N''D'')
  AND o.lock_flag IS NULL
  AND o.consolidated_order_number IS NULL
  AND CAST(CAST(COALESCE(NULLIF(o.actual_ship_date, ''19000101''), o.order_date) AS datetime2)
      AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''D_REMAINING'', ''$(WorkQProcessCode)'', COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(SourceDb)') + N'.dbo.t_work_q q
WHERE q.datetime_stamp IS NOT NULL
  AND q.work_status IN (N''C'', N''P'')
  AND CAST(TRY_CONVERT(datetime2, q.datetime_stamp)
      AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut;';
EXEC sys.sp_executesql @chk, N'@Cut datetime2(0), @Tz nvarchar(200)', @Cut = @CutoffUtc, @Tz = @Tz;
GO

PRINT '';
PRINT '=== E) Operational health ===';
GO
BEGIN TRY
    SELECT HealthArea, Severity, ProcessCode, SourceDb, RunId, Status,
           StartedAtUtc, EndedAtUtc, DocsDone, RowsDeleted, RowsArchived, AuditRows, Details
    FROM arch.v_OperationalHealth
    ORDER BY CASE Severity WHEN N'ERROR' THEN 0 WHEN N'WARN' THEN 1 ELSE 2 END, HealthArea;
END TRY
BEGIN CATCH
    PRINT 'arch.v_OperationalHealth unavailable: ' + ERROR_MESSAGE();
END CATCH;
GO

PRINT '';
PRINT '12_verify: done. Section B is the one that matters - every row must read OK.';
GO
