-- ============================================================================
-- 10 - DRY RUN (no deletes, no archive writes)
-- ============================================================================
-- Runs the real candidate-selection pipeline with @DryRun = 1. It proves that
--   * the anchor / timestamp expressions compile against the real source schema,
--   * every configured child join compiles and resolves, and
--   * the cutoff selects the documents you expect,
-- without touching a single source row.
--
-- WHAT A DRY RUN DOES NOT TELL YOU: for the ANCHOR process it reports DOCUMENTS
-- (DocsDone), not rows. Use 09_preflight_data.sql section A for the row fan-out,
-- or arch.usp_Api_EstimateNextRunImpact below for a size estimate.
--
-- AFTERWARDS the dry-run WorkBatch is left open (status Paused) and would block
-- the next run with "an open WorkBatch already exists". This script closes it at
-- the end. Note the shipped procedure marks closed dry-run batches as 'Failed' -
-- that is its normal bookkeeping for a discarded batch, not an error.
-- ============================================================================
:setvar AdminDb "kArchiveManagerAdmin"
:setvar SourceDb "AAD"
:setvar OrderProcessCode "AAD_ORDER_ARCH"
:setvar WorkQProcessCode "AAD_WORKQ_ARCH"
:setvar OrderDryRunProfile "ORDER_DRYRUN"
:setvar WorkQDryRunProfile "WORKQ_DRYRUN"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

-- Clear any leftover open batch first, so a previous aborted attempt does not
-- block this one.
PRINT '--- Clearing leftover dry-run batches ---';
EXEC arch.usp_CloseDryRunWorkBatches @StaleMinutes = 0, @ApplyChanges = 1, @OnlyProcessCode = N'$(OrderProcessCode)', @IncludeRunning = 0;
EXEC arch.usp_CloseDryRunWorkBatches @StaleMinutes = 0, @ApplyChanges = 1, @OnlyProcessCode = N'$(WorkQProcessCode)', @IncludeRunning = 0;
GO

PRINT '';
PRINT '=== Impact estimate (read-only, before running anything) ===';
GO
-- Sizes the next run in rows and MB per table, so you know what a real run moves.
BEGIN TRY
    EXEC arch.usp_Api_EstimateNextRunImpact @ProcessCode = N'$(OrderProcessCode)', @SourceDb = N'$(SourceDb)';
END TRY
BEGIN CATCH
    PRINT 'Estimate unavailable: ' + ERROR_MESSAGE();
END CATCH;
GO

BEGIN TRY
    EXEC arch.usp_Api_EstimateNextRunImpact @ProcessCode = N'$(WorkQProcessCode)', @SourceDb = N'$(SourceDb)';
END TRY
BEGIN CATCH
    PRINT 'Estimate unavailable: ' + ERROR_MESSAGE();
END CATCH;
GO

PRINT '';
PRINT '=== Execution plan explanation (read-only) ===';
GO
BEGIN TRY
    EXEC arch.usp_ExplainProcessPlan @ProcessCode = N'$(OrderProcessCode)', @SourceDb = N'$(SourceDb)';
END TRY
BEGIN CATCH
    PRINT 'Explain unavailable: ' + ERROR_MESSAGE();
END CATCH;
GO

PRINT '';
PRINT '=== DRY RUN: $(OrderProcessCode) ===';
GO
EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'$(OrderDryRunProfile)';
GO

PRINT '';
PRINT '=== DRY RUN: $(WorkQProcessCode) ===';
GO
EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'$(WorkQDryRunProfile)';
GO

PRINT '';
PRINT '=== Dry-run outcome ===';
GO
SELECT
    r.RunId,
    r.Status,
    r.SourceDb,
    p.ProcessCode,
    ri.CutoffUtc,
    ri.BatchesDone,
    DocumentsSelected = ri.DocsDone,
    ri.RowsArchived,
    ri.RowsDeleted,
    ri.Status,
    ri.ErrorMessage
FROM arch.Run r
JOIN arch.RunItem ri ON ri.RunId = r.RunId
LEFT JOIN arch.Process p ON p.ProcessId = ri.ProcessId
WHERE r.Status = N'DRYRUN'
  AND r.StartedAt >= DATEADD(HOUR, -1, SYSUTCDATETIME())
ORDER BY r.RunId DESC;

-- The candidate keys chosen, so they can be eyeballed against expectations.
SELECT TOP (50)
    p.ProcessCode,
    wb.WorkBatchId,
    wbk.Key1,
    wbk.Key2,
    wbk.DocCreatedAt
FROM arch.WorkBatchKey wbk
JOIN arch.WorkBatch wb ON wb.WorkBatchId = wbk.WorkBatchId
JOIN arch.Process p ON p.ProcessId = wb.ProcessId
WHERE wb.PreparedAtUtc >= DATEADD(HOUR, -1, SYSUTCDATETIME())
ORDER BY p.ProcessCode, wbk.DocCreatedAt, wbk.Key1;
GO

PRINT '';
PRINT '--- Closing the dry-run batches (they would block the real run) ---';
GO
EXEC arch.usp_CloseDryRunWorkBatches @StaleMinutes = 0, @ApplyChanges = 1, @OnlyProcessCode = N'$(OrderProcessCode)', @IncludeRunning = 0;
EXEC arch.usp_CloseDryRunWorkBatches @StaleMinutes = 0, @ApplyChanges = 1, @OnlyProcessCode = N'$(WorkQProcessCode)', @IncludeRunning = 0;
GO

SELECT Section = 'OPEN_BATCHES_REMAINING', wb.WorkBatchId, p.ProcessCode, wb.SourceDb, wb.Status
FROM arch.WorkBatch wb
JOIN arch.Process p ON p.ProcessId = wb.ProcessId
WHERE wb.Status IN (N'Prepared', N'Running', N'Paused');
GO

PRINT '10_dryrun: done. If the selected documents match expectations, proceed to 11_realrun_guarded.sql.';
GO
