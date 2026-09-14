USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_MarkStaleRunsFailed]
    @StaleMinutes int = 60,
    @ApplyChanges bit = 0,
    @OnlySourceDb sysname = NULL,
    @OnlyArchiveDb sysname = NULL,
    @OnlyProcessCode sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @StaleMinutes IS NULL OR @StaleMinutes < 1
        THROW 59000, '@StaleMinutes must be >= 1.', 1;

    DECLARE
        @NowUtc datetime2(0) = CONVERT(datetime2(0), SYSUTCDATETIME()),
        @StaleBeforeUtc datetime2(0);

    SET @StaleBeforeUtc = DATEADD(MINUTE, -@StaleMinutes, @NowUtc);

    CREATE TABLE #StaleRunItems
    (
        RunId bigint NOT NULL,
        RunItemId bigint NOT NULL PRIMARY KEY,
        ProcessCode sysname NOT NULL,
        SourceDb sysname NULL,
        ArchiveDb sysname NULL,
        StartedAt datetime2(0) NOT NULL,
        EndedAt datetime2(0) NULL,
        DocsDone int NOT NULL,
        RowsDeleted bigint NOT NULL,
        RowsArchived bigint NOT NULL,
        ErrorMessage nvarchar(max) NULL
    );

    INSERT INTO #StaleRunItems
    (
        RunId,
        RunItemId,
        ProcessCode,
        SourceDb,
        ArchiveDb,
        StartedAt,
        EndedAt,
        DocsDone,
        RowsDeleted,
        RowsArchived,
        ErrorMessage
    )
    SELECT
        r.RunId,
        ri.RunItemId,
        p.ProcessCode,
        r.SourceDb,
        r.ArchiveDb,
        ri.StartedAt,
        ri.EndedAt,
        ri.DocsDone,
        ri.RowsDeleted,
        ri.RowsArchived,
        ri.ErrorMessage
    FROM arch.RunItem ri
    JOIN arch.Run r
      ON r.RunId = ri.RunId
    JOIN arch.Process p
      ON p.ProcessId = ri.ProcessId
    WHERE ri.Status = N'RUNNING'
      AND ri.StartedAt < @StaleBeforeUtc
      AND (@OnlySourceDb IS NULL OR r.SourceDb = @OnlySourceDb)
      AND (@OnlyArchiveDb IS NULL OR r.ArchiveDb = @OnlyArchiveDb)
      AND (@OnlyProcessCode IS NULL OR p.ProcessCode = @OnlyProcessCode);

    SELECT
        Step = N'01_STALE_RUNITEM_CANDIDATES',
        ApplyChanges = @ApplyChanges,
        NowUtc = @NowUtc,
        StaleBeforeUtc = @StaleBeforeUtc,
        *
    FROM #StaleRunItems
    ORDER BY StartedAt, RunItemId;

    IF @ApplyChanges = 1
    BEGIN
        UPDATE ri
        SET Status = N'FAILED',
            EndedAt = @NowUtc,
            ErrorMessage = CONCAT(
                COALESCE(CONVERT(nvarchar(max), ri.ErrorMessage), N''),
                CASE WHEN ri.ErrorMessage IS NULL THEN N'' ELSE N' | ' END,
                N'Marked FAILED by arch.usp_MarkStaleRunsFailed at ',
                CONVERT(nvarchar(30), @NowUtc, 126),
                N' UTC after ',
                CONVERT(nvarchar(20), @StaleMinutes),
                N' stale minutes.'
            )
        FROM arch.RunItem ri
        JOIN #StaleRunItems s
          ON s.RunItemId = ri.RunItemId
        WHERE ri.Status = N'RUNNING';

        UPDATE r
        SET Status = N'FAILED',
            EndedAt = @NowUtc,
            ErrorMessage = CONCAT(
                COALESCE(CONVERT(nvarchar(max), r.ErrorMessage), N''),
                CASE WHEN r.ErrorMessage IS NULL THEN N'' ELSE N' | ' END,
                N'Marked FAILED by arch.usp_MarkStaleRunsFailed at ',
                CONVERT(nvarchar(30), @NowUtc, 126),
                N' UTC after stale RunItem recovery.'
            )
        FROM arch.Run r
        WHERE r.Status = N'RUNNING'
          AND r.StartedAt < @StaleBeforeUtc
          AND (@OnlySourceDb IS NULL OR r.SourceDb = @OnlySourceDb)
          AND (@OnlyArchiveDb IS NULL OR r.ArchiveDb = @OnlyArchiveDb)
          AND EXISTS
          (
              SELECT 1
              FROM #StaleRunItems s
              WHERE s.RunId = r.RunId
          )
          AND NOT EXISTS
          (
              SELECT 1
              FROM arch.RunItem ri
              WHERE ri.RunId = r.RunId
                AND ri.Status = N'RUNNING'
          );
    END;

    SELECT
        Step = N'99_SUMMARY',
        ApplyChanges = @ApplyChanges,
        StaleRunItemsFound = COUNT_BIG(*),
        Message =
            CASE
                WHEN @ApplyChanges = 1 THEN N'Stale RUNNING RunItems were marked FAILED.'
                ELSE N'Preview only. Re-run with @ApplyChanges = 1 to mark these RunItems FAILED.'
            END
    FROM #StaleRunItems;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_CloseDryRunWorkBatches]
    @StaleMinutes int = 0,
    @ApplyChanges bit = 0,
    @OnlySourceDb sysname = NULL,
    @OnlyArchiveDb sysname = NULL,
    @OnlyProcessCode sysname = NULL,
    @IncludeRunning bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @StaleMinutes IS NULL OR @StaleMinutes < 0
        THROW 59010, '@StaleMinutes must be >= 0.', 1;

    DECLARE
        @NowUtc datetime2(0) = CONVERT(datetime2(0), SYSUTCDATETIME()),
        @StaleBeforeUtc datetime2(0);

    SET @StaleBeforeUtc = DATEADD(MINUTE, -@StaleMinutes, @NowUtc);

    CREATE TABLE #DryRunWorkBatches
    (
        WorkBatchId bigint NOT NULL PRIMARY KEY,
        ProcessCode sysname NOT NULL,
        SourceDb sysname NOT NULL,
        ArchiveDb sysname NOT NULL,
        Status varchar(20) NOT NULL,
        PreparedAtUtc datetime2(0) NULL,
        StartedAtUtc datetime2(0) NULL,
        LastProgressAtUtc datetime2(0) NULL,
        CompletedAtUtc datetime2(0) NULL,
        Notes nvarchar(4000) NULL
    );

    INSERT INTO #DryRunWorkBatches
    (
        WorkBatchId,
        ProcessCode,
        SourceDb,
        ArchiveDb,
        Status,
        PreparedAtUtc,
        StartedAtUtc,
        LastProgressAtUtc,
        CompletedAtUtc,
        Notes
    )
    SELECT
        wb.WorkBatchId,
        p.ProcessCode,
        wb.SourceDb,
        wb.ArchiveDb,
        wb.Status,
        wb.PreparedAtUtc,
        wb.StartedAtUtc,
        wb.LastProgressAtUtc,
        wb.CompletedAtUtc,
        wb.Notes
    FROM arch.WorkBatch wb
    JOIN arch.Process p
      ON p.ProcessId = wb.ProcessId
    WHERE wb.Status IN ('Prepared', 'Paused')
      AND wb.Notes = N'DryRun preview only'
      AND COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc) <= @StaleBeforeUtc
      AND (@OnlySourceDb IS NULL OR wb.SourceDb = @OnlySourceDb)
      AND (@OnlyArchiveDb IS NULL OR wb.ArchiveDb = @OnlyArchiveDb)
      AND (@OnlyProcessCode IS NULL OR p.ProcessCode = @OnlyProcessCode)
    UNION ALL
    SELECT
        wb.WorkBatchId,
        p.ProcessCode,
        wb.SourceDb,
        wb.ArchiveDb,
        wb.Status,
        wb.PreparedAtUtc,
        wb.StartedAtUtc,
        wb.LastProgressAtUtc,
        wb.CompletedAtUtc,
        wb.Notes
    FROM arch.WorkBatch wb
    JOIN arch.Process p
      ON p.ProcessId = wb.ProcessId
    WHERE @IncludeRunning = 1
      AND wb.Status = 'Running'
      AND wb.Notes = N'DryRun preview only'
      AND COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc) <= @StaleBeforeUtc
      AND (@OnlySourceDb IS NULL OR wb.SourceDb = @OnlySourceDb)
      AND (@OnlyArchiveDb IS NULL OR wb.ArchiveDb = @OnlyArchiveDb)
      AND (@OnlyProcessCode IS NULL OR p.ProcessCode = @OnlyProcessCode);

    SELECT
        Step = N'01_DRYRUN_WORKBATCH_CANDIDATES',
        ApplyChanges = @ApplyChanges,
        NowUtc = @NowUtc,
        StaleBeforeUtc = @StaleBeforeUtc,
        *
    FROM #DryRunWorkBatches
    ORDER BY PreparedAtUtc, WorkBatchId;

    IF @ApplyChanges = 1
    BEGIN
        UPDATE wb
        SET Status = 'Failed',
            CompletedAtUtc = @NowUtc,
            LastProgressAtUtc = @NowUtc,
            Notes = CONCAT(
                COALESCE(CONVERT(nvarchar(max), wb.Notes), N''),
                N' | Closed by arch.usp_CloseDryRunWorkBatches at ',
                CONVERT(nvarchar(30), @NowUtc, 126),
                N' UTC. No source data was changed by dry-run preview.'
            )
        FROM arch.WorkBatch wb
        JOIN #DryRunWorkBatches d
          ON d.WorkBatchId = wb.WorkBatchId
        WHERE wb.Status IN ('Prepared', 'Paused', 'Running');
    END;

    SELECT
        Step = N'99_SUMMARY',
        ApplyChanges = @ApplyChanges,
        DryRunWorkBatchesFound = COUNT_BIG(*),
        Message =
            CASE
                WHEN @ApplyChanges = 1 THEN N'Dry-run WorkBatches were closed as Failed.'
                ELSE N'Preview only. Re-run with @ApplyChanges = 1 to close these dry-run WorkBatches.'
            END
    FROM #DryRunWorkBatches;
END
GO

CREATE OR ALTER VIEW [arch].[v_OperationalHealth]
AS
WITH run_item_base AS
(
    SELECT
        p.ProcessCode,
        r.SourceDb,
        r.ArchiveDb,
        r.RunId,
        ri.RunItemId,
        WorkBatchId = CONVERT(bigint, NULL),
        Status = ri.Status,
        StartedAtUtc = ri.StartedAt,
        EndedAtUtc = ri.EndedAt,
        LastActivityAtUtc = COALESCE(ri.EndedAt, ri.StartedAt),
        ri.DocsDone,
        ri.RowsDeleted,
        ri.RowsArchived,
        ri.ErrorMessage
    FROM arch.RunItem ri
    JOIN arch.Run r
      ON r.RunId = ri.RunId
    JOIN arch.Process p
      ON p.ProcessId = ri.ProcessId
),
audit_by_runitem AS
(
    SELECT
        RunItemId,
        AuditRows = COUNT_BIG(*)
    FROM arch.RunDocAudit
    GROUP BY RunItemId
)
SELECT
    HealthArea = CONVERT(nvarchar(80), N'RUNNING_NO_RECENT_ACTIVITY'),
    Severity = CONVERT(nvarchar(10), N'WARN'),
    b.ProcessCode,
    b.SourceDb,
    b.ArchiveDb,
    b.RunId,
    b.RunItemId,
    b.WorkBatchId,
    b.Status,
    b.StartedAtUtc,
    b.EndedAtUtc,
    b.LastActivityAtUtc,
    b.DocsDone,
    b.RowsDeleted,
    b.RowsArchived,
    AuditRows = CONVERT(bigint, NULL),
    Details = CONVERT(nvarchar(1000), N'RunItem is RUNNING and older than 30 minutes. Review and use arch.usp_MarkStaleRunsFailed if the worker is no longer active.')
FROM run_item_base b
WHERE b.Status = N'RUNNING'
  AND b.StartedAtUtc < DATEADD(MINUTE, -30, CONVERT(datetime2(0), SYSUTCDATETIME()))

UNION ALL

SELECT
    HealthArea = CONVERT(nvarchar(80), N'FAILED_RECENT'),
    Severity = CONVERT(nvarchar(10), N'WARN'),
    b.ProcessCode,
    b.SourceDb,
    b.ArchiveDb,
    b.RunId,
    b.RunItemId,
    b.WorkBatchId,
    b.Status,
    b.StartedAtUtc,
    b.EndedAtUtc,
    b.LastActivityAtUtc,
    b.DocsDone,
    b.RowsDeleted,
    b.RowsArchived,
    AuditRows = CONVERT(bigint, NULL),
    Details = CONVERT(nvarchar(1000), LEFT(COALESCE(b.ErrorMessage, N'RunItem failed without ErrorMessage.'), 1000))
FROM run_item_base b
WHERE b.Status = N'FAILED'
  AND b.StartedAtUtc >= DATEADD(DAY, -7, CONVERT(datetime2(0), SYSUTCDATETIME()))

UNION ALL

SELECT
    HealthArea = CONVERT(nvarchar(80), N'ROW_COUNT_MISMATCH'),
    Severity = CONVERT(nvarchar(10), N'ERROR'),
    b.ProcessCode,
    b.SourceDb,
    b.ArchiveDb,
    b.RunId,
    b.RunItemId,
    b.WorkBatchId,
    b.Status,
    b.StartedAtUtc,
    b.EndedAtUtc,
    b.LastActivityAtUtc,
    b.DocsDone,
    b.RowsDeleted,
    b.RowsArchived,
    AuditRows = CONVERT(bigint, NULL),
    Details = CONVERT(nvarchar(1000), N'RowsDeleted differs from RowsArchived. Review RunItemObject and target Mode before trusting this run.')
FROM run_item_base b
WHERE b.RowsDeleted <> b.RowsArchived

UNION ALL

SELECT
    HealthArea = CONVERT(nvarchar(80), N'ROW_AUDIT_MISSING'),
    Severity = CONVERT(nvarchar(10), N'ERROR'),
    b.ProcessCode,
    b.SourceDb,
    b.ArchiveDb,
    b.RunId,
    b.RunItemId,
    b.WorkBatchId,
    b.Status,
    b.StartedAtUtc,
    b.EndedAtUtc,
    b.LastActivityAtUtc,
    b.DocsDone,
    b.RowsDeleted,
    b.RowsArchived,
    AuditRows = COALESCE(a.AuditRows, 0),
    Details = CONVERT(nvarchar(1000), N'Effective AuditLevel is ROW, RunItem archived/deleted documents, but RunDocAudit has fewer rows than DocsDone.')
FROM run_item_base b
JOIN arch.v_ProcessDatabaseEffective e
  ON e.ProcessCode = b.ProcessCode
 AND e.SourceDb = b.SourceDb
 AND e.ArchiveDb = b.ArchiveDb
LEFT JOIN audit_by_runitem a
  ON a.RunItemId = b.RunItemId
WHERE b.Status = N'OK'
  AND e.AuditLevel = N'ROW'
  AND b.DocsDone > 0
  AND b.StartedAtUtc >= DATEADD(DAY, -7, CONVERT(datetime2(0), SYSUTCDATETIME()))
  AND COALESCE(a.AuditRows, 0) < b.DocsDone

UNION ALL

SELECT
    HealthArea = CONVERT(nvarchar(80), N'OPEN_WORKBATCH'),
    Severity = CONVERT(nvarchar(10), N'WARN'),
    p.ProcessCode,
    wb.SourceDb,
    wb.ArchiveDb,
    RunId = CONVERT(bigint, NULL),
    RunItemId = CONVERT(bigint, NULL),
    wb.WorkBatchId,
    Status = CONVERT(nvarchar(20), wb.Status),
    StartedAtUtc = COALESCE(wb.StartedAtUtc, wb.PreparedAtUtc),
    EndedAtUtc = wb.CompletedAtUtc,
    LastActivityAtUtc = COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc),
    DocsDone = CONVERT(int, NULL),
    RowsDeleted = CONVERT(bigint, NULL),
    RowsArchived = CONVERT(bigint, NULL),
    AuditRows = CONVERT(bigint, NULL),
    Details = CONVERT(nvarchar(1000), COALESCE(wb.Notes, N'Open WorkBatch can block ANCHOR candidate preparation.'))
FROM arch.WorkBatch wb
JOIN arch.Process p
  ON p.ProcessId = wb.ProcessId
WHERE wb.Status IN ('Prepared', 'Running', 'Paused');
GO
