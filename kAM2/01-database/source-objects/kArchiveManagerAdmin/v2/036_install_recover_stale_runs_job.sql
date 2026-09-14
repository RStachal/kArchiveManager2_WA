USE [msdb]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/**
 * ============================================================================
 * 036_install_recover_stale_runs_job.sql
 * ============================================================================
 *
 * Purpose:
 *   Install (and ENABLE) a SQL Agent job that runs arch.usp_RecoverStaleRuns
 *   every 15 minutes. The procedure (v2/030) detects Run/RunItem/WorkBatch
 *   records stuck in RUNNING after a disconnect/restart and recovers them
 *   (infer OK when archived=deleted, otherwise mark FAILED / pause for resume).
 *
 * Why this matters:
 *   The recovery procedure has been deployed since 2026-05-28 but nothing was
 *   scheduling it — so it provided no protection. Once real deletes are enabled
 *   (after the P0.5 timezone gate), an interrupted run would otherwise sit in
 *   RUNNING limbo indefinitely. This job closes that gap.
 *
 * Behavior:
 *   - Idempotent: creates the job/step/schedule if missing, updates them if present.
 *   - Job is created ENABLED with an enabled 15-minute schedule (a disabled
 *     recovery job protects nothing). Disable via SSMS or
 *     EXEC msdb.dbo.sp_update_job @job_name = N'kArchiveManager - RECOVER STALE RUNS', @enabled = 0;
 *   - Step runs EXEC arch.usp_RecoverStaleRuns @DryRun = 0 (applies recovery).
 *
 * Scope:
 *   Environment-specific operational script (like 028/031/033/034). NOT part of
 *   the regenerated deploy bundle — SQL Agent jobs are server-local.
 *
 * Created: 2026-05-29
 * Related: v2/030_usp_RecoverStaleRuns.sql, v2/028_replace_legacy_jobs.sql
 * ============================================================================
 */

DECLARE
    @jobId uniqueidentifier,
    @stepId int,
    @recoverCommand nvarchar(max);

SET @recoverCommand = N'
EXEC arch.usp_RecoverStaleRuns
     @StaleAfterMinutes = 30,
     @DryRun = 0,
     @VerboseOutput = 0;';

SELECT @jobId = job_id
FROM msdb.dbo.sysjobs
WHERE name = N'kArchiveManager - RECOVER STALE RUNS';

IF @jobId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name = N'kArchiveManager - RECOVER STALE RUNS',
        @enabled = 1,
        @description = N'Recovers Run/RunItem/WorkBatch records stuck in RUNNING (arch.usp_RecoverStaleRuns). Runs every 15 minutes.',
        @category_name = N'Database Maintenance',
        @job_id = @jobId OUTPUT;
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_job
        @job_id = @jobId,
        @enabled = 1,
        @description = N'Recovers Run/RunItem/WorkBatch records stuck in RUNNING (arch.usp_RecoverStaleRuns). Runs every 15 minutes.';
END;

-- Step: run the recovery procedure
SELECT @stepId = step_id
FROM msdb.dbo.sysjobsteps
WHERE job_id = @jobId
  AND step_name = N'RECOVER STALE RUNS';

IF @stepId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @jobId,
        @step_name = N'RECOVER STALE RUNS',
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @recoverCommand,
        @on_success_action = 1,   -- quit reporting success
        @on_fail_action = 2;      -- quit reporting failure
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_jobstep
        @job_id = @jobId,
        @step_id = @stepId,
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @recoverCommand,
        @on_success_action = 1,
        @on_fail_action = 2;
END;

-- Schedule: every 15 minutes, all day, every day
IF NOT EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobschedules js
    JOIN msdb.dbo.sysschedules s
      ON s.schedule_id = js.schedule_id
    WHERE js.job_id = @jobId
      AND s.name = N'Every 15 minutes'
)
BEGIN
    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @jobId,
        @name = N'Every 15 minutes',
        @enabled = 1,
        @freq_type = 4,              -- daily
        @freq_interval = 1,          -- every 1 day
        @freq_subday_type = 4,       -- minutes
        @freq_subday_interval = 15,  -- every 15 minutes
        @active_start_time = 000000; -- from midnight
END;

IF NOT EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobservers
    WHERE job_id = @jobId
)
BEGIN
    EXEC msdb.dbo.sp_add_jobserver
        @job_id = @jobId,
        @server_name = N'(LOCAL)';
END;

PRINT N'kArchiveManager - RECOVER STALE RUNS job installed and enabled (every 15 minutes).';
GO
