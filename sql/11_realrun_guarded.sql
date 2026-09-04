-- ============================================================================
-- 11 - REAL ARCHIVE + DELETE RUN (guarded)
-- ============================================================================
-- THIS SCRIPT DELETES SOURCE DATA. The rows are copied to the archive database
-- first (Mode = 1) and can be put back with 13_restore.sql, but on live data
-- treat it as a one-way operation and go through the checklist below.
--
-- BEFORE RUNNING, ALL OF THESE MUST BE TRUE
--   [ ] 09_preflight_data.sql reports NO 'STOP' verdicts
--   [ ] 10_dryrun.sql selected the documents you expected, and only those
--   [ ] 07_validate.sql reports 0 ERROR
--   [ ] the archive database has a recent FULL backup (it becomes the only copy)
--   [ ] you are inside an agreed maintenance window
--
-- HOW IT IS GUARDED
--   1. IConfirm must be set to YES. It defaults to NO and the script stops.
--   2. MaxDocuments caps the FIRST run deliberately small (default 10 documents),
--      so a mistake is small and reversible. Raise it once you have verified the
--      outcome with 12_verify.sql.
--   3. A row-count baseline is captured into dbo.KamDeployBaseline BEFORE the run,
--      so 12_verify.sql can prove source + archive == the original volume.
--   4. Only the two processes named below run, on the named source database.
--      The scheduled JOB_DEFAULT profile is untouched and stays disabled.
-- ============================================================================
:setvar AdminDb "kArchiveManagerAdmin"
:setvar SourceDb "AAD"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar OrderProcessCode "AAD_ORDER_ARCH"
:setvar WorkQProcessCode "AAD_WORKQ_ARCH"
:setvar IConfirm "NO"
:setvar MaxDocuments "10"
:setvar RunOrderProcess "1"
:setvar RunWorkQProcess "1"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF UPPER(N'$(IConfirm)') <> N'YES'
BEGIN
    PRINT '';
    PRINT '*** BLOCKED - this script deletes source data. ***';
    PRINT 'Set  :setvar IConfirm "YES"  once the checklist in the header is satisfied.';
    PRINT 'Nothing was changed.';
    ;THROW 60300, 'Real run not confirmed (IConfirm is not YES).', 1;
END;
GO

-------------------------------------------------------------------------------
-- 1) Baseline: row counts per configured table, BEFORE the run.
-------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.KamDeployBaseline', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.KamDeployBaseline
    (
        BaselineId   int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        CapturedAtUtc datetime2(0) NOT NULL CONSTRAINT DF_KamDeployBaseline_At DEFAULT (SYSUTCDATETIME()),
        ProcessCode  sysname NOT NULL,
        SourceDb     sysname NOT NULL,
        SourceSchema sysname NOT NULL,
        SourceTable  sysname NOT NULL,
        SourceRows   bigint  NOT NULL,
        ArchiveRows  bigint  NOT NULL
    );
END;
GO

DECLARE @sql nvarchar(max) = N'';
DECLARE @SourceDb sysname = N'$(SourceDb)';
DECLARE @ArchiveDb sysname = N'$(ArchiveDb)';

-- Build one UNION ALL per configured ObjectSpec. Counting rows per table is
-- deliberately done with COUNT_BIG(*) rather than sys.partitions: partition row
-- counts are only approximate and this baseline is the basis of a correctness
-- proof, not a size estimate.
SELECT @sql = @sql +
    CASE WHEN @sql = N'' THEN N'' ELSE N' UNION ALL ' END +
    N'SELECT ' + QUOTENAME(p.ProcessCode, '''') + N', ' + QUOTENAME(@SourceDb, '''') + N', '
      + QUOTENAME(os.SourceSchema, '''') + N', ' + QUOTENAME(os.SourceTable, '''') + N', '
      + N'(SELECT COUNT_BIG(*) FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable) + N'), '
      + N'ISNULL((SELECT COUNT_BIG(*) FROM ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(os.SourceTable) + N'), 0)'
FROM
(
    SELECT DISTINCT p2.ProcessCode, os2.SourceSchema, os2.SourceTable
    FROM arch.ObjectSpec os2
    JOIN arch.Process p2 ON p2.ProcessId = os2.ProcessId
    WHERE p2.ProcessCode IN (N'$(OrderProcessCode)', N'$(WorkQProcessCode)')
) AS x
JOIN arch.Process p ON p.ProcessCode = x.ProcessCode
JOIN arch.ObjectSpec os ON os.ProcessId = p.ProcessId AND os.SourceSchema = x.SourceSchema AND os.SourceTable = x.SourceTable
GROUP BY p.ProcessCode, os.SourceSchema, os.SourceTable;

SET @sql = N'INSERT dbo.KamDeployBaseline(ProcessCode, SourceDb, SourceSchema, SourceTable, SourceRows, ArchiveRows) ' + @sql + N';';
EXEC sys.sp_executesql @sql;

PRINT 'Baseline captured:';
SELECT ProcessCode, SourceTable, SourceRows, ArchiveRows
FROM dbo.KamDeployBaseline
WHERE CapturedAtUtc >= DATEADD(MINUTE, -2, SYSUTCDATETIME())
ORDER BY ProcessCode, SourceTable;
GO

-------------------------------------------------------------------------------
-- 2) Clear any open batch, then run - capped at MaxDocuments.
-------------------------------------------------------------------------------
PRINT '';
PRINT '--- Clearing leftover dry-run batches ---';
EXEC arch.usp_CloseDryRunWorkBatches @StaleMinutes = 0, @ApplyChanges = 1, @OnlyProcessCode = N'$(OrderProcessCode)', @IncludeRunning = 0;
EXEC arch.usp_CloseDryRunWorkBatches @StaleMinutes = 0, @ApplyChanges = 1, @OnlyProcessCode = N'$(WorkQProcessCode)', @IncludeRunning = 0;
GO

-- Temporary run profiles carrying the document cap. Using a profile (rather than
-- calling the runner directly) keeps this on the officially supported execution
-- path - the legacy per-process procedures are deliberately blocked with
-- THROW 50004/50005/50006.
DECLARE @RpId int = NULL, @CsId bigint = NULL;

IF $(RunOrderProcess) = 1
BEGIN
    SET @RpId = NULL;
    EXEC arch.usp_Api_SaveRunProfile
        @RunProfileId      = @RpId OUTPUT,
        @RunProfileCode    = N'GUARDED_ORDER_RUN',
        @RequestedBy       = N'kam-deploy',
        @ChangeReason      = N'Guarded first real run, capped document count.',
        @Description       = N'Guarded real run - order process, capped.',
        @IsEnabled         = 1,
        @RunOnSchedule     = 0,
        @RunOrder          = 900,
        @ProcessCodeFilter = N'$(OrderProcessCode)',
        @SourceDbFilter    = N'$(SourceDb)',
        @RunWindowMinutes  = 30,
        @DryRun            = 0,
        @MaxCandidates     = $(MaxDocuments),
        @ConfigChangeSetId = @CsId OUTPUT;
END;

IF $(RunWorkQProcess) = 1
BEGIN
    SET @RpId = NULL;
    EXEC arch.usp_Api_SaveRunProfile
        @RunProfileId      = @RpId OUTPUT,
        @RunProfileCode    = N'GUARDED_WORKQ_RUN',
        @RequestedBy       = N'kam-deploy',
        @ChangeReason      = N'Guarded first real run, capped document count.',
        @Description       = N'Guarded real run - work queue process, capped.',
        @IsEnabled         = 1,
        @RunOnSchedule     = 0,
        @RunOrder          = 910,
        @ProcessCodeFilter = N'$(WorkQProcessCode)',
        @SourceDbFilter    = N'$(SourceDb)',
        @RunWindowMinutes  = 30,
        @DryRun            = 0,
        @MaxCandidates     = $(MaxDocuments),
        @ConfigChangeSetId = @CsId OUTPUT;
END;
GO

IF $(RunOrderProcess) = 1
BEGIN
    PRINT '';
    PRINT '=== REAL RUN: $(OrderProcessCode) (max $(MaxDocuments) documents) ===';
    EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'GUARDED_ORDER_RUN';
END;
GO

IF $(RunWorkQProcess) = 1
BEGIN
    PRINT '';
    PRINT '=== REAL RUN: $(WorkQProcessCode) (max $(MaxDocuments) documents) ===';
    EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'GUARDED_WORKQ_RUN';
END;
GO

-------------------------------------------------------------------------------
-- 3) Immediate outcome
-------------------------------------------------------------------------------
PRINT '';
PRINT '=== Run outcome ===';
GO
SELECT
    r.RunId,
    RunStatus = r.Status,
    p.ProcessCode,
    ri.CutoffUtc,
    ri.BatchesDone,
    Documents = ri.DocsDone,
    ri.RowsArchived,
    ri.RowsDeleted,
    Divergence = ri.RowsArchived - ri.RowsDeleted,
    ItemStatus = ri.Status,
    ri.ErrorMessage
FROM arch.Run r
JOIN arch.RunItem ri ON ri.RunId = r.RunId
LEFT JOIN arch.Process p ON p.ProcessId = ri.ProcessId
WHERE r.StartedAt >= DATEADD(MINUTE, -30, SYSUTCDATETIME())
  AND r.Status <> N'DRYRUN'
ORDER BY r.RunId DESC;

SELECT
    Section = 'PER_TABLE',
    p.ProcessCode,
    rio.SourceTable,
    rio.RowsArchived,
    rio.RowsDeleted,
    Divergence = rio.RowsArchived - rio.RowsDeleted
FROM arch.RunItemObject rio
JOIN arch.RunItem ri ON ri.RunItemId = rio.RunItemId
JOIN arch.Run r ON r.RunId = ri.RunId
LEFT JOIN arch.Process p ON p.ProcessId = ri.ProcessId
WHERE r.StartedAt >= DATEADD(MINUTE, -30, SYSUTCDATETIME())
  AND r.Status <> N'DRYRUN'
ORDER BY p.ProcessCode, rio.SourceTable;
GO

PRINT '';
PRINT '11_realrun_guarded: done. RUN 12_verify.sql NOW to prove source + archive == baseline.';
PRINT 'Any non-zero Divergence above means archived and deleted counts disagree - investigate before running again.';
GO
