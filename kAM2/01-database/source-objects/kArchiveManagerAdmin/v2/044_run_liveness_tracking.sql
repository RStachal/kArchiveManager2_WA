/* ============================================================================
   044 — Run liveness tracking (audit task T-03)
   ============================================================================
   PROBLEM: the unattended "RECOVER STALE RUNS" job (usp_RecoverStaleRuns, every 15 min,
   @StaleAfterMinutes=30, @DryRun=0) decides a run is stale purely from wall-clock age
   (arch.Run.StartedAt, which is never refreshed). A LEGITIMATE run may execute up to
   RunProfile.RunWindowMinutes (JOB_DEFAULT = 55) — so any normal run past minute 30 is wrongly
   flagged stale and either marked FAILED mid-delete or (worse) inferred OK while still deleting.

   FIX (this script + 030/015/027 changes): record the worker's SPID + session login time on the
   run, so recovery can SKIP any run whose worker session is provably still alive. A run is only
   recoverable when its worker session is gone (or it predates this migration).

   Idempotent. Safe to run anytime (pure ADD COLUMN, NULLable, no data change).
   DEPLOY ORDER: run THIS first, then (re)deploy 030_usp_RecoverStaleRuns, 015_usp_RunPreparedBatch,
   027_usp_RunTimestampProcess. The runner re-deploys must happen when no run is active.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET NOCOUNT ON;
GO

IF COL_LENGTH('arch.Run', 'WorkerSessionId') IS NULL
    ALTER TABLE arch.Run ADD WorkerSessionId int NULL;
GO

IF COL_LENGTH('arch.Run', 'WorkerSessionLoginTimeUtc') IS NULL
    ALTER TABLE arch.Run ADD WorkerSessionLoginTimeUtc datetime2(3) NULL;
GO

PRINT '044_run_liveness_tracking deployed (arch.Run.WorkerSessionId + WorkerSessionLoginTimeUtc).';
GO
