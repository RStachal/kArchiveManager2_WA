/* ============================================================================
   kArchiveManager 2.0 — example AD-HOC process calls (run by hand in SSMS)
   ----------------------------------------------------------------------------
   These are the exact procedures the self-test / acceptance tests exercise.
   Replace <PROCESS> / <SOURCE_DB> with YOUR configured mapping; the archive DB is
   normally kArchiveManagerBackups.

   GOLDEN RULE for production: ALWAYS dry-run (@DryRun=1) and review the candidate
   counts + cutoff BEFORE a real run (@DryRun=0). Real runs archive+delete real rows.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO

/* ---------------------------------------------------------------------------
   0) WHAT IS CONFIGURED + IS IT SAFE TO RUN?  (read-only)
   --------------------------------------------------------------------------- */
EXEC arch.usp_ValidateConfiguration;                       -- config consistency
EXEC arch.usp_ValidateIndexRequirements;                   -- required source indexes exist?
EXEC arch.usp_ExplainProcessPlan @ProcessCode = N'<PROCESS>';

SELECT ProcessCode, SourceDb, ArchiveDb, IsEnabled, Mode, SelectionStrategy,
       AuditLevel, AuditLevelSource, RetentionDays, CutoffMode, CutoffDate
FROM arch.v_ProcessDatabaseEffective
WHERE IsEnabled = 1
ORDER BY ProcessCode, SourceDb;

EXEC arch.usp_Frontend_GoLiveReadiness;                    -- go-live gate (resolve all FAIL first)
EXEC arch.usp_Frontend_TimestampRetentionGaps;             -- T-20: rows unreachable by retention (NULL/unparseable ts)
GO

/* ---------------------------------------------------------------------------
   1) PROVISION archive tables for a process (before the first real run)
   --------------------------------------------------------------------------- */
EXEC arch.usp_ProvisionArchiveTablesForProcess
     @ProcessCode = N'<PROCESS>',
     @SourceDb    = N'<SOURCE_DB>',
     @ArchiveDb   = N'kArchiveManagerBackups';
GO

/* ---------------------------------------------------------------------------
   2) DRY-RUN a single configured process — PREVIEW ONLY (nothing deleted/archived)
      Reports candidate counts + cutoff. @StopAtUtc and @MaxCandidates are optional.
   --------------------------------------------------------------------------- */
DECLARE @StopAtUtc datetime2(0) = DATEADD(MINUTE, 20, SYSUTCDATETIME());
EXEC arch.usp_RunConfiguredProcesses_Prepared
     @ProcessCode   = N'<PROCESS>',
     @SourceDb      = N'<SOURCE_DB>',
     @ArchiveDb     = N'kArchiveManagerBackups',
     @StopAtUtc     = @StopAtUtc,
     @DryRun        = 1,
     @MaxCandidates = 1000;
GO

/* ---------------------------------------------------------------------------
   3) REAL run (archive+delete) — ONLY after reviewing the dry-run.
      A real run on a Mode=1 cutoff WITHOUT 'AT TIME ZONE' is blocked (THROW 50200).
   --------------------------------------------------------------------------- */
DECLARE @StopAtUtc datetime2(0) = DATEADD(MINUTE, 20, SYSUTCDATETIME());
EXEC arch.usp_RunConfiguredProcesses_Prepared
     @ProcessCode   = N'<PROCESS>',
     @SourceDb      = N'<SOURCE_DB>',
     @ArchiveDb     = N'kArchiveManagerBackups',
     @StopAtUtc     = @StopAtUtc,
     @DryRun        = 0,
     @MaxCandidates = 1000;
GO

/* ---------------------------------------------------------------------------
   3b) TIMESTAMP processes (e.g. RF_LOG2 / integration logs) — internal worker,
       can be called directly. Dry-run first.
   --------------------------------------------------------------------------- */
EXEC arch.usp_RunTimestampProcess
     @ProcessCode = N'<TS_PROCESS>',
     @SourceDb    = N'<SOURCE_DB>',
     @ArchiveDb   = N'kArchiveManagerBackups',
     @DryRun      = 1;          -- set 0 for a real run
GO

/* ---------------------------------------------------------------------------
   4) Run a whole RUN PROFILE (exactly what the SQL Agent 'RUN CONFIGURED' job calls)
   --------------------------------------------------------------------------- */
EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'<RUN_PROFILE>';
GO

/* ---------------------------------------------------------------------------
   5) CHECK RESULTS / HEALTH after a run
   --------------------------------------------------------------------------- */
SELECT TOP (50) * FROM arch.v_RunItemsRecent ORDER BY RunItemId DESC;
SELECT TOP (100) * FROM arch.v_OperationalHealth ORDER BY LastActivityAtUtc DESC;  -- 0 ERROR rows = OK
-- per-document trail (only for AuditLevel=ROW mappings):
SELECT TOP (100) * FROM arch.RunDocAudit ORDER BY RunDocAuditId DESC;
GO

/* ---------------------------------------------------------------------------
   6) STOP a running run (cooperative — ends after the current batch commits)
   --------------------------------------------------------------------------- */
-- find the running RunId first:
SELECT RunId, Status, StartedAt, SourceDb, ArchiveDb FROM arch.Run WHERE Status = N'RUNNING' ORDER BY RunId DESC;
EXEC arch.usp_Api_RequestRunStop @RunId = 0 /* <-- real RunId */, @RequestedBy = N'<you>';
GO

/* ---------------------------------------------------------------------------
   7) RECOVER stale / orphaned runs (preview first)
   --------------------------------------------------------------------------- */
EXEC arch.usp_RecoverStaleRuns @StaleAfterMinutes = 60, @DryRun = 1;   -- preview
-- EXEC arch.usp_RecoverStaleRuns @StaleAfterMinutes = 60, @DryRun = 0; -- apply
GO

/* ---------------------------------------------------------------------------
   8) RESTORE (un-archive) rows back to the source — DRY-RUN first.
      @PurgeArchive=1 (delete the archive copy) is DBA-only: requires karch_approver
      membership AND AuditLevel=ROW on the mapping (THROW 50404/50405 otherwise); the
      Admin Console never forwards a purge flag.
   --------------------------------------------------------------------------- */
EXEC arch.usp_RestoreFromArchive
     @ProcessCode  = N'<PROCESS>',
     @SourceDb     = N'<SOURCE_DB>',
     @ArchiveDb    = N'kArchiveManagerBackups',
     @DryRun       = 1,          -- set 0 to actually restore
     @PurgeArchive = 0,
     @RequestedBy  = N'<you>';
GO
