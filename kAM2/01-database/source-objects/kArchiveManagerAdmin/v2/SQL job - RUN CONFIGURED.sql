USE [msdb]
GO

DECLARE
    @jobId uniqueidentifier,
    @stepId int,
    @validateCommand nvarchar(max),
    @runCommand nvarchar(max);

SET @validateCommand = N'
DECLARE @rc int;
EXEC @rc = arch.usp_ValidateConfiguration;
IF @rc <> 0
    THROW 51000, ''kArchiveManager validation failed. See result set from arch.usp_ValidateConfiguration.'', 1;

-- T-33 runtime least-privilege gate. This step runs in the JOB OWNER context (the dedicated
-- non-sysadmin runner login after deploy/v2/054), so usp_VerifyRunnerPrivileges'' HAS_PERMS_BY_NAME /
-- IS_SRVROLEMEMBER checks evaluate the RUNNER''s own effective rights. RETURN 1 => THROW => the run is
-- blocked before any delete. Guarded so older installs without the proc still validate.
IF OBJECT_ID(N''arch.usp_VerifyRunnerPrivileges'', N''P'') IS NOT NULL
BEGIN
    DECLARE @rp int;
    EXEC @rp = arch.usp_VerifyRunnerPrivileges;
    IF @rp <> 0
        THROW 51001, ''kArchiveManager runner privilege gate failed. See result set from arch.usp_VerifyRunnerPrivileges; fix each ERROR row''''s SuggestedSql (or re-run deploy/v2/053), then retry.'', 1;
END;';

SET @runCommand = N'
EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N''JOB_DEFAULT'';';

SELECT @jobId = job_id
FROM msdb.dbo.sysjobs
WHERE name = N'kArchiveManager - RUN CONFIGURED';

IF @jobId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name = N'kArchiveManager - RUN CONFIGURED',
        @enabled = 0,
        @description = N'Runs kArchiveManager using Admin DB run profile JOB_DEFAULT.',
        @category_name = N'Database Maintenance',
        @job_id = @jobId OUTPUT;
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_job
        @job_id = @jobId,
        @description = N'Runs kArchiveManager using Admin DB run profile JOB_DEFAULT.';
END;

SELECT @stepId = step_id
FROM msdb.dbo.sysjobsteps
WHERE job_id = @jobId
  AND step_name = N'VALIDATE CONFIGURATION';

IF @stepId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @jobId,
        @step_name = N'VALIDATE CONFIGURATION',
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @validateCommand,
        @on_success_action = 3,
        @on_fail_action = 2;
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_jobstep
        @job_id = @jobId,
        @step_id = @stepId,
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @validateCommand,
        @on_success_action = 3,
        @on_fail_action = 2;
END;

SET @stepId = NULL;

SELECT @stepId = step_id
FROM msdb.dbo.sysjobsteps
WHERE job_id = @jobId
  AND step_name = N'RUN CONFIGURED PROCESSES';

IF @stepId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @jobId,
        @step_name = N'RUN CONFIGURED PROCESSES',
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @runCommand,
        @on_success_action = 1,
        @on_fail_action = 2;
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_jobstep
        @job_id = @jobId,
        @step_id = @stepId,
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @runCommand,
        @on_success_action = 1,
        @on_fail_action = 2;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobschedules js
    JOIN msdb.dbo.sysschedules s
      ON s.schedule_id = js.schedule_id
    WHERE js.job_id = @jobId
      AND s.name = N'Hourly disabled template'
)
BEGIN
    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @jobId,
        @name = N'Hourly disabled template',
        @enabled = 0,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 8,
        @freq_subday_interval = 1,
        @active_start_time = 010000;
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
GO
