/* ============================================================================
   kArchiveManager 2.0 — AD-HOC calls with CONCRETE names (RADIM-STACHAL\RSTSQL2022)
   ----------------------------------------------------------------------------
   Filled-in version of example-process-calls.sql for the seeded test processes
   (RECEIVING / SHIPPING / RF_LOG2 / INTEGRACE_* / WA_AAD_*_OSTRY_SMOKE) over the
   test source DBs AAD / Edge / KMWEBV / KMWE_Test. Archive DB = kArchiveManagerBackups.

   GOLDEN RULE: dry-run (@DryRun=1) and review counts BEFORE any real run (@DryRun=0).
   Real runs archive+delete real rows. The lines that delete are marked  >>> REAL <<<.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO

/* ---- 0) What is configured + safe to run? (read-only) ---- */
EXEC arch.usp_ValidateConfiguration;
EXEC arch.usp_ValidateIndexRequirements;
EXEC arch.usp_ExplainProcessPlan @ProcessCode = N'RECEIVING';

SELECT ProcessCode, SourceDb, ArchiveDb, IsEnabled, Mode, SelectionStrategy,
       AuditLevel, RetentionDays, CutoffMode
FROM arch.v_ProcessDatabaseEffective
WHERE IsEnabled = 1
ORDER BY ProcessCode, SourceDb;

EXEC arch.usp_Frontend_TimestampRetentionGaps;   -- NULL/unparseable-timestamp rows (T-20)
-- EXEC arch.usp_Frontend_GoLiveReadiness;       -- needs 049 + msdb read on this DB
GO

/* ---- 1) Provision archive tables (run once per mapping before first real run) ---- */
EXEC arch.usp_ProvisionArchiveTablesForProcess @ProcessCode=N'RECEIVING', @SourceDb=N'KMWEBV', @ArchiveDb=N'kArchiveManagerBackups';
EXEC arch.usp_ProvisionArchiveTablesForProcess @ProcessCode=N'RF_LOG2',   @SourceDb=N'Edge',   @ArchiveDb=N'kArchiveManagerBackups';
GO

/* ---- 2) DRY-RUN (preview only — nothing deleted/archived) ---- */
DECLARE @StopAtUtc datetime2(0) = DATEADD(MINUTE, 20, SYSUTCDATETIME());

-- ANCHOR (documents):
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=N'RECEIVING', @SourceDb=N'KMWEBV', @ArchiveDb=N'kArchiveManagerBackups', @StopAtUtc=@StopAtUtc, @DryRun=1, @MaxCandidates=1000;
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=N'SHIPPING',  @SourceDb=N'KMWEBV', @ArchiveDb=N'kArchiveManagerBackups', @StopAtUtc=@StopAtUtc, @DryRun=1, @MaxCandidates=1000;

-- TIMESTAMP (logs / integration) — internal worker, dry-run:
EXEC arch.usp_RunTimestampProcess @ProcessCode=N'RF_LOG2',          @SourceDb=N'Edge', @ArchiveDb=N'kArchiveManagerBackups', @DryRun=1;
EXEC arch.usp_RunTimestampProcess @ProcessCode=N'INTEGRACE_UPLOAD', @SourceDb=N'Edge', @ArchiveDb=N'kArchiveManagerBackups', @DryRun=1;

-- Smoke fixture (tiny, RetentionDays=1):
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=N'WA_AAD_PRIJEM_OSTRY_SMOKE', @SourceDb=N'AAD', @ArchiveDb=N'kArchiveManagerBackups', @DryRun=1, @MaxCandidates=100;
GO

/* ---- 3) >>> REAL <<< archive+delete (ONLY after reviewing the dry-run above) ----
   (Cutoff without AT TIME ZONE is blocked: THROW 50200.) Uncomment to run for real. */
-- DECLARE @StopAtUtc datetime2(0) = DATEADD(MINUTE, 20, SYSUTCDATETIME());
-- EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=N'RECEIVING', @SourceDb=N'KMWEBV', @ArchiveDb=N'kArchiveManagerBackups', @StopAtUtc=@StopAtUtc, @DryRun=0, @MaxCandidates=1000;
-- EXEC arch.usp_RunTimestampProcess @ProcessCode=N'RF_LOG2', @SourceDb=N'Edge', @ArchiveDb=N'kArchiveManagerBackups', @DryRun=0;
GO

/* ---- 4) Run a whole RUN PROFILE (what the SQL Agent job calls) ---- */
EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'RECEIVING_KMWEBV';   -- single process+DB, 120-min window
-- EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'RF_LOG2_EDGE';
-- EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'JOB_DEFAULT';      -- all scheduled, 55-min window
GO

/* ---- 5) Results / health after a run ---- */
SELECT TOP (50) * FROM arch.v_RunItemsRecent ORDER BY RunItemId DESC;
SELECT TOP (100) * FROM arch.v_OperationalHealth ORDER BY LastActivityAtUtc DESC;  -- 0 ERROR = OK
SELECT TOP (100) * FROM arch.RunDocAudit ORDER BY RunDocAuditId DESC;              -- only for AuditLevel=ROW
GO

/* ---- 6) Stop a running run (find RunId first) ---- */
SELECT RunId, Status, StartedAt, SourceDb, ArchiveDb FROM arch.Run WHERE Status=N'RUNNING' ORDER BY RunId DESC;
-- EXEC arch.usp_Api_RequestRunStop @RunId = 0 /* real RunId */, @RequestedBy = N'radim';
GO

/* ---- 7) Recover stale/orphaned runs (preview) ---- */
EXEC arch.usp_RecoverStaleRuns @StaleAfterMinutes = 60, @DryRun = 1;
GO

/* ---- 8) Restore (un-archive) — DRY-RUN first ----
   @PurgeArchive=1 is DBA-only (karch_approver + AuditLevel=ROW; THROW 50404/50405). */
EXEC arch.usp_RestoreFromArchive @ProcessCode=N'RECEIVING', @SourceDb=N'KMWEBV', @ArchiveDb=N'kArchiveManagerBackups', @DryRun=1, @PurgeArchive=0, @RequestedBy=N'radim';
GO
