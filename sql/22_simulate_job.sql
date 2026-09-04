-- ============================================================================
-- 22 - SIMULATE THE SQL AGENT JOB  'kArchiveManager - RUN CONFIGURED'
-- ============================================================================
-- Replays exactly what the Agent job does, in the same order, with the same
-- failure semantics - but from a session you can watch, so you see each step's
-- result instead of only a job-history line.
--
-- The job as installed in msdb has two T-SQL steps, both in kArchiveManagerAdmin:
--
--   Step 1  VALIDATE CONFIGURATION      on_success = go to step 2, on_fail = quit with failure
--             DECLARE @rc int;
--             EXEC @rc = arch.usp_ValidateConfiguration;
--             IF @rc <> 0 THROW 51000, '...', 1;
--             IF OBJECT_ID(N'arch.usp_VerifyRunnerPrivileges', N'P') IS NOT NULL
--             BEGIN
--                 DECLARE @rp int;
--                 EXEC @rp = arch.usp_VerifyRunnerPrivileges;
--                 IF @rp <> 0 THROW 51001, '...', 1;
--             END;
--
--   Step 2  RUN CONFIGURED PROCESSES    on_success = quit with success, on_fail = quit with failure
--             EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'JOB_DEFAULT';
--
-- The important behaviour this reproduces: if step 1 fails, step 2 NEVER RUNS.
-- That is the product's safety gate - a broken configuration or an
-- under-privileged runner blocks the deletes rather than deleting the wrong rows.
--
-- WHAT JOB_DEFAULT COVERS: it is a run profile with no ProcessCodeFilter and no
-- SourceDbFilter, so it enumerates EVERY enabled process x enabled mapping,
-- ordered by ProcessDatabase.RunOrder - the five document sets:
--     10  AAD_PICKDETAIL_ARCH  on AAD   picks + allocations
--     20  AAD_TRANLOG_ARCH     on AAD   transaction log + reason + serial numbers
--     30  AAD_ORDER_ARCH       on AAD   order header + lines + comments + pack
--     40  AAD_WORKQ_ARCH       on AAD   work queues + assignments + dependencies
--     50  ADV_LOGMSG_ARCH      on ADV   application log
-- and it runs with DryRun = 0, i.e. it really deletes.
--
-- SET DryRunFirst = 1 (default) to do a harmless dry pass over the same
-- processes before the real one, so you can see the candidate counts first.
-- ============================================================================
-- ---------------------------------------------------------------------------
-- RUN IT AS THE JOB OWNER, NOT AS YOURSELF
-- ---------------------------------------------------------------------------
-- Step 1 calls arch.usp_VerifyRunnerPrivileges, which checks the CALLER's
-- effective rights and FAILS if the caller is a sysadmin - because an unattended
-- archive runner must not be one. After deploy/v2/054 the Agent job is owned by
-- the dedicated runner login, so inside the job that check passes.
--
-- Running this script as yourself (a sysadmin) therefore reproduces a FAILURE
-- that the real job would not have. That is not a false alarm - it is the gate
-- doing its job - but it tells you nothing about the configuration. So each step
-- below impersonates RunnerLogin with EXECUTE AS, which is what makes this a
-- faithful simulation rather than a different experiment.
--
-- Set RunnerLogin to '' to run as yourself (useful only to see the gate fire).
-- ---------------------------------------------------------------------------
:setvar AdminDb "kArchiveManagerAdmin"
:setvar RunnerLogin "karch_runtime_svc"
:setvar JobProfile "JOB_DEFAULT"
:setvar DryRunProfile "ALL_DRYRUN"
:setvar DryRunFirst "1"
:setvar RunForReal "0"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

PRINT '================================================================';
PRINT ' SIMULATING JOB: kArchiveManager - RUN CONFIGURED';
PRINT '================================================================';
PRINT '';
GO

-------------------------------------------------------------------------------
-- What the job is about to operate on
-------------------------------------------------------------------------------
PRINT '--- Enabled process x mapping set that JOB_DEFAULT will enumerate ---';
GO
SELECT
    e.RunOrder,
    e.ProcessCode,
    e.SelectionStrategy,
    e.SourceDb,
    e.ArchiveDb,
    e.Mode,
    e.RetentionDays,
    ComputedCutoffUtc = CASE WHEN e.CutoffMode = 1 AND e.CutoffDate IS NOT NULL THEN e.CutoffDate
                             ELSE DATEADD(MINUTE, -ISNULL(e.CutoffSafetyLagMinutes, 0),
                                          DATEADD(DAY, -ISNULL(e.RetentionDays, 0), CONVERT(datetime2(0), SYSUTCDATETIME()))) END
FROM arch.v_ProcessDatabaseEffective e
WHERE e.IsEnabled = 1
ORDER BY e.RunOrder, e.ProcessCode;
GO

-- Make sure the dry-pass profile exists. 99_cleanup_test.sql removes it (only
-- JOB_DEFAULT is protected), so this script provisions it idempotently rather
-- than depending on a previous script having run.
IF $(DryRunFirst) = 1
BEGIN
    DECLARE @rp int = NULL, @cs bigint = NULL;
    EXEC arch.usp_Api_SaveRunProfile
        @RunProfileId      = @rp OUTPUT,
        @RunProfileCode    = N'$(DryRunProfile)',
        @RequestedBy       = N'kam-deploy',
        @ChangeReason      = N'Dry pass over every enabled process, used by the job simulation.',
        @Description       = N'Dry pass - all enabled processes, deletes nothing.',
        @IsEnabled         = 1,
        @RunOnSchedule     = 0,
        @RunOrder          = 300,
        @ProcessCodeFilter = NULL,
        @SourceDbFilter    = NULL,
        @RunWindowMinutes  = 30,
        @DryRun            = 1,
        @MaxCandidates     = NULL,
        @ConfigChangeSetId = @cs OUTPUT;
END;
GO

-- Clear anything left open, or the runner refuses with "an open WorkBatch already exists".
PRINT '';
PRINT '--- Clearing leftover dry-run batches ---';
GO
DECLARE @pc sysname;
DECLARE cp CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT ProcessCode FROM arch.Process;
OPEN cp;
FETCH NEXT FROM cp INTO @pc;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC arch.usp_CloseDryRunWorkBatches @StaleMinutes = 0, @ApplyChanges = 1, @OnlyProcessCode = @pc, @IncludeRunning = 0;
    FETCH NEXT FROM cp INTO @pc;
END;
CLOSE cp; DEALLOCATE cp;
GO

-------------------------------------------------------------------------------
-- STEP 1 - verbatim copy of the job's first step
-------------------------------------------------------------------------------
PRINT '';
PRINT '================ STEP 1: VALIDATE CONFIGURATION ================';
GO
DECLARE @step1Failed bit = 0;
DECLARE @step1Error nvarchar(2000) = NULL;
DECLARE @runner sysname = NULLIF(N'$(RunnerLogin)', N'');

IF @runner IS NOT NULL
    PRINT 'Impersonating [' + @runner + '] - the job owner.';
ELSE
    PRINT 'Running as ' + SUSER_SNAME() + ' (no impersonation). Expect the privilege gate to fail if this is a sysadmin.';

BEGIN TRY
    -- EXECUTE AS must be written STATICALLY (sqlcmd substitutes $(RunnerLogin)
    -- before the batch is parsed). Wrapping it in EXEC('...') would not work:
    -- the impersonation would be scoped to that nested batch and would end the
    -- moment EXEC returned, so the checks below would run as the caller again.
    IF @runner IS NOT NULL
        EXECUTE AS LOGIN = '$(RunnerLogin)';

    DECLARE @rc int;
    EXEC @rc = arch.usp_ValidateConfiguration;
    IF @rc <> 0
        THROW 51000, 'kArchiveManager validation failed. See result set from arch.usp_ValidateConfiguration.', 1;

    IF OBJECT_ID(N'arch.usp_VerifyRunnerPrivileges', N'P') IS NOT NULL
    BEGIN
        DECLARE @rp int;
        EXEC @rp = arch.usp_VerifyRunnerPrivileges;
        IF @rp <> 0
            THROW 51001, 'kArchiveManager runner privilege gate failed.', 1;
    END;

    IF @runner IS NOT NULL AND SUSER_SNAME() = @runner
        REVERT;

    PRINT 'STEP 1 RESULT: SUCCEEDED  (job would advance to step 2)';
END TRY
BEGIN CATCH
    -- REVERT inside CATCH: the impersonation may still be in effect.
    IF @runner IS NOT NULL AND SUSER_SNAME() = @runner
        REVERT;
    SET @step1Failed = 1;
    SET @step1Error = ERROR_MESSAGE();
    PRINT 'STEP 1 RESULT: FAILED  (job would QUIT WITH FAILURE and step 2 would NOT run)';
    PRINT '  Error ' + CAST(ERROR_NUMBER() AS varchar(10)) + ': ' + @step1Error;
END CATCH;

-- Hand the outcome to the next batch through a temp table (variables do not
-- survive a GO, and the steps must stay separate to mirror the job).
DROP TABLE IF EXISTS #JobState;
CREATE TABLE #JobState (Step1Failed bit NOT NULL, Step1Error nvarchar(2000) NULL);
INSERT #JobState VALUES (@step1Failed, @step1Error);
GO

-------------------------------------------------------------------------------
-- Optional harmless dry pass, before anything is deleted
-------------------------------------------------------------------------------
IF (SELECT Step1Failed FROM #JobState) = 0 AND $(DryRunFirst) = 1
BEGIN
    PRINT '';
    PRINT '================ DRY PASS (not part of the job) ================';
    PRINT 'Profile $(DryRunProfile), DryRun = 1 - selects candidates, deletes nothing.';

    DECLARE @r1 sysname = NULLIF(N'$(RunnerLogin)', N'');
    IF @r1 IS NOT NULL
        EXECUTE AS LOGIN = '$(RunnerLogin)';

    EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'$(DryRunProfile)';

    IF @r1 IS NOT NULL AND SUSER_SNAME() = @r1
        REVERT;
END;
GO

IF (SELECT Step1Failed FROM #JobState) = 0 AND $(DryRunFirst) = 1
BEGIN
    PRINT '';
    PRINT '--- Candidates selected by the dry pass ---';
    SELECT
        p.ProcessCode,
        ri.CutoffUtc,
        DocumentsSelected = ri.DocsDone,
        ri.Status
    FROM arch.RunItem ri
    JOIN arch.Run r ON r.RunId = ri.RunId
    JOIN arch.Process p ON p.ProcessId = ri.ProcessId
    WHERE r.Status = N'DRYRUN'
      AND r.StartedAt >= DATEADD(MINUTE, -10, SYSUTCDATETIME())
    ORDER BY p.ProcessCode;

    -- Close them again so the real step 2 is not blocked.
    DECLARE @pc2 sysname;
    DECLARE cp2 CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ProcessCode FROM arch.Process;
    OPEN cp2;
    FETCH NEXT FROM cp2 INTO @pc2;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC arch.usp_CloseDryRunWorkBatches @StaleMinutes = 0, @ApplyChanges = 1, @OnlyProcessCode = @pc2, @IncludeRunning = 0;
        FETCH NEXT FROM cp2 INTO @pc2;
    END;
    CLOSE cp2; DEALLOCATE cp2;
END;
GO

-------------------------------------------------------------------------------
-- STEP 2 - verbatim copy of the job's second step
-------------------------------------------------------------------------------
PRINT '';
PRINT '================ STEP 2: RUN CONFIGURED PROCESSES ================';
GO
IF (SELECT Step1Failed FROM #JobState) = 1
BEGIN
    PRINT 'SKIPPED - step 1 failed, so the Agent job would have quit already.';
    PRINT 'This is the safety gate working: a bad configuration blocks the deletes.';
END
ELSE IF $(RunForReal) <> 1
BEGIN
    PRINT 'NOT EXECUTED - RunForReal is 0.';
    PRINT 'Step 2 runs profile $(JobProfile) with DryRun = 0, i.e. it DELETES.';
    PRINT 'Set  :setvar RunForReal "1"  to execute it.';
END
ELSE
BEGIN
    PRINT 'Executing: EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N''$(JobProfile)'';';
    DECLARE @r2 sysname = NULLIF(N'$(RunnerLogin)', N'');
    BEGIN TRY
        IF @r2 IS NOT NULL
            EXECUTE AS LOGIN = '$(RunnerLogin)';

        EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'$(JobProfile)';

        IF @r2 IS NOT NULL AND SUSER_SNAME() = @r2
            REVERT;
        PRINT 'STEP 2 RESULT: SUCCEEDED  (job would QUIT WITH SUCCESS)';
    END TRY
    BEGIN CATCH
        IF @r2 IS NOT NULL AND SUSER_SNAME() = @r2
            REVERT;
        PRINT 'STEP 2 RESULT: FAILED  (job would QUIT WITH FAILURE)';
        PRINT '  Error ' + CAST(ERROR_NUMBER() AS varchar(10)) + ': ' + ERROR_MESSAGE();
    END CATCH;
END;
GO

-------------------------------------------------------------------------------
-- Outcome, the way you would read it off the job history plus the run tables
-------------------------------------------------------------------------------
PRINT '';
PRINT '================ SIMULATED JOB OUTCOME ================';
GO
SELECT
    r.RunId,
    RunStatus = r.Status,
    p.ProcessCode,
    r.SourceDb,
    ri.CutoffUtc,
    ri.BatchesDone,
    Documents = ri.DocsDone,
    ri.RowsArchived,
    ri.RowsDeleted,
    Divergence = ri.RowsArchived - ri.RowsDeleted,
    ItemStatus = ri.Status,
    r.StartedAt,
    r.EndedAt,
    ri.ErrorMessage
FROM arch.Run r
JOIN arch.RunItem ri ON ri.RunId = r.RunId
LEFT JOIN arch.Process p ON p.ProcessId = ri.ProcessId
WHERE r.StartedAt >= DATEADD(MINUTE, -15, SYSUTCDATETIME())
ORDER BY r.RunId, p.ProcessCode;

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
WHERE r.StartedAt >= DATEADD(MINUTE, -15, SYSUTCDATETIME())
  AND r.Status <> N'DRYRUN'
ORDER BY p.ProcessCode, rio.SourceTable;

SELECT
    Section = 'OPEN_BATCHES_LEFT',
    wb.WorkBatchId, p.ProcessCode, wb.SourceDb, wb.Status
FROM arch.WorkBatch wb
JOIN arch.Process p ON p.ProcessId = wb.ProcessId
WHERE wb.Status IN (N'Prepared', N'Running', N'Paused');
GO

DROP TABLE IF EXISTS #JobState;
GO

PRINT '';
PRINT '22_simulate_job: done. Run 23_verify_standalone.sql to check the data.';
GO

