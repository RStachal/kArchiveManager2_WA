/* ============================================================================
   058_agent_job_control.sql — PREP/RUN two-phase Agent job + Console job-control API.
   ----------------------------------------------------------------------------
   1) Creates the PREP job 'kArchiveManager - PREP CONFIGURED' (front-loads ANCHOR candidate
      preparation via run profile JOB_DEFAULT with @Phase='PREP'). Ships DISABLED, like the RUN job.
      The existing 'kArchiveManager - RUN CONFIGURED' job stays @Phase=BOTH (the safety net: it runs
      prepared batches AND prepares anything the PREP job didn't get to + runs TIMESTAMP processes).
   2) Installs the Console job-control API (arch.usp_Api_GetAgentJobs / usp_Api_SetAgentJobEnabled /
      usp_Api_SetAgentJobSchedule), WHITELISTED to the two kAM jobs only. These run in the CALLER
      context, so the connecting Admin Console login must have msdb SQLAgentUserRole + own the jobs
      (deploy/v2/059_console_job_control_grants.sql). THROW 50118 = job not in the kAM whitelist.
   Idempotent. SQL Agent required for the job half (the proc half installs regardless).
   ============================================================================ */
USE [msdb];
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'msdb' AND state_desc = 'ONLINE')
   AND OBJECT_ID(N'msdb.dbo.sp_add_job', N'P') IS NOT NULL
BEGIN
    DECLARE @jobId uniqueidentifier, @stepId int,
            @validateCommand nvarchar(max), @prepCommand nvarchar(max);

    SET @validateCommand = N'
DECLARE @rc int;
EXEC @rc = arch.usp_ValidateConfiguration;
IF @rc <> 0
    THROW 51000, ''kArchiveManager validation failed. See result set from arch.usp_ValidateConfiguration.'', 1;
IF OBJECT_ID(N''arch.usp_VerifyRunnerPrivileges'', N''P'') IS NOT NULL
BEGIN
    DECLARE @rp int;
    EXEC @rp = arch.usp_VerifyRunnerPrivileges;
    IF @rp <> 0
        THROW 51001, ''kArchiveManager runner privilege gate failed. See arch.usp_VerifyRunnerPrivileges.'', 1;
END;';

    -- PREP phase only: build ANCHOR WorkBatches; TIMESTAMP is single-phase and is a no-op here.
    SET @prepCommand = N'
EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N''JOB_DEFAULT'', @Phase = N''PREP'';';

    SELECT @jobId = job_id FROM msdb.dbo.sysjobs WHERE name = N'kArchiveManager - PREP CONFIGURED';

    IF @jobId IS NULL
        EXEC msdb.dbo.sp_add_job
            @job_name = N'kArchiveManager - PREP CONFIGURED',
            @enabled = 0,
            @description = N'Prepares kArchiveManager ANCHOR candidates (run profile JOB_DEFAULT, @Phase=PREP). Front-loads the candidate scan so the RUN job only deletes.',
            @category_name = N'Database Maintenance',
            @job_id = @jobId OUTPUT;
    ELSE
        EXEC msdb.dbo.sp_update_job @job_id = @jobId,
            @description = N'Prepares kArchiveManager ANCHOR candidates (run profile JOB_DEFAULT, @Phase=PREP). Front-loads the candidate scan so the RUN job only deletes.';

    SELECT @stepId = step_id FROM msdb.dbo.sysjobsteps WHERE job_id = @jobId AND step_name = N'VALIDATE CONFIGURATION';
    IF @stepId IS NULL
        EXEC msdb.dbo.sp_add_jobstep @job_id = @jobId, @step_name = N'VALIDATE CONFIGURATION',
            @subsystem = N'TSQL', @database_name = N'kArchiveManagerAdmin',
            @command = @validateCommand, @on_success_action = 3, @on_fail_action = 2;
    ELSE
        EXEC msdb.dbo.sp_update_jobstep @job_id = @jobId, @step_id = @stepId,
            @subsystem = N'TSQL', @database_name = N'kArchiveManagerAdmin',
            @command = @validateCommand, @on_success_action = 3, @on_fail_action = 2;

    SET @stepId = NULL;
    SELECT @stepId = step_id FROM msdb.dbo.sysjobsteps WHERE job_id = @jobId AND step_name = N'PREPARE CONFIGURED PROCESSES';
    IF @stepId IS NULL
        EXEC msdb.dbo.sp_add_jobstep @job_id = @jobId, @step_name = N'PREPARE CONFIGURED PROCESSES',
            @subsystem = N'TSQL', @database_name = N'kArchiveManagerAdmin',
            @command = @prepCommand, @on_success_action = 1, @on_fail_action = 2;
    ELSE
        EXEC msdb.dbo.sp_update_jobstep @job_id = @jobId, @step_id = @stepId,
            @subsystem = N'TSQL', @database_name = N'kArchiveManagerAdmin',
            @command = @prepCommand, @on_success_action = 1, @on_fail_action = 2;

    -- Disabled daily template (operator enables + reschedules from the Console).
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id
                   WHERE js.job_id = @jobId)
        EXEC msdb.dbo.sp_add_jobschedule @job_id = @jobId, @name = N'kArchiveManager - PREP daily (disabled template)',
            @enabled = 0, @freq_type = 4, @freq_interval = 1, @freq_subday_type = 1, @active_start_time = 003000;

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobservers WHERE job_id = @jobId)
        EXEC msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(LOCAL)';

    PRINT 'PREP CONFIGURED job ensured (disabled).';
END
ELSE
    PRINT 'SQL Agent / msdb not available — skipped PREP job creation (proc half still installs).';
GO

USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- The kAM jobs the Console may control. Any other job name is rejected (50118).
-- A scalar helper keeps the whitelist in one place.
CREATE OR ALTER FUNCTION arch.fn_IsControllableAgentJob(@JobName sysname)
RETURNS bit
AS
BEGIN
    RETURN CASE WHEN @JobName IN (N'kArchiveManager - PREP CONFIGURED', N'kArchiveManager - RUN CONFIGURED')
                THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END;
END
GO

/* Read the state of the two controllable kAM jobs (enabled + schedule + last/next run). Caller needs
   msdb access to its own jobs (SQLAgentUserRole). Returns one row per job (or none if Agent absent). */
CREATE OR ALTER PROCEDURE arch.usp_Api_GetAgentJobs
AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID(N'msdb.dbo.sysjobs', N'V') IS NULL AND OBJECT_ID(N'msdb.dbo.sysjobs', N'U') IS NULL
    BEGIN
        SELECT TOP (0) JobName = CONVERT(sysname, NULL); RETURN;
    END;

    SELECT
        JobName          = j.name,
        Phase            = CASE WHEN j.name LIKE N'%PREP%' THEN N'PREP' ELSE N'RUN' END,
        JobEnabled       = CONVERT(bit, j.enabled),
        Description      = j.description,
        ScheduleName     = sch.name,
        ScheduleEnabled  = CONVERT(bit, ISNULL(sch.enabled, 0)),
        FreqType         = sch.freq_type,            -- 1=once 4=daily 8=weekly 16=monthly
        FreqInterval     = sch.freq_interval,
        FreqSubdayType   = sch.freq_subday_type,     -- 1=at time 4=minutes 8=hours
        FreqSubdayInterval = sch.freq_subday_interval,
        ActiveStartTime  = sch.active_start_time,    -- HHMMSS int
        ActiveStartDate  = sch.active_start_date,    -- YYYYMMDD int
        NextRunDate      = act.next_scheduled_run_date,
        LastRunOutcome   = CASE h.run_status WHEN 0 THEN N'Failed' WHEN 1 THEN N'Succeeded'
                              WHEN 2 THEN N'Retry' WHEN 3 THEN N'Canceled' WHEN 4 THEN N'In progress' ELSE NULL END,
        LastRunDate      = h.run_date,
        LastRunTime      = h.run_time
    FROM msdb.dbo.sysjobs j
    LEFT JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
    LEFT JOIN msdb.dbo.sysschedules sch    ON sch.schedule_id = js.schedule_id
    OUTER APPLY (SELECT TOP (1) a.next_scheduled_run_date FROM msdb.dbo.sysjobactivity a
                 WHERE a.job_id = j.job_id ORDER BY a.session_id DESC) act
    OUTER APPLY (SELECT TOP (1) hh.run_status, hh.run_date, hh.run_time FROM msdb.dbo.sysjobhistory hh
                 WHERE hh.job_id = j.job_id AND hh.step_id = 0 ORDER BY hh.instance_id DESC) h
    WHERE arch.fn_IsControllableAgentJob(j.name) = 1
    ORDER BY j.name;
END
GO

/* Enable/disable a kAM job. Whitelisted; @RequestedBy captured for the caller's audit/log context. */
CREATE OR ALTER PROCEDURE arch.usp_Api_SetAgentJobEnabled
    @JobName sysname,
    @Enabled bit,
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF arch.fn_IsControllableAgentJob(@JobName) = 0
        THROW 50118, 'Job is not a controllable kArchiveManager job.', 1;

    EXEC msdb.dbo.sp_update_job @job_name = @JobName, @enabled = @Enabled;
    EXEC arch.usp_Api_GetAgentJobs;
END
GO

/* Update a kAM job's (single) schedule: frequency, time, start date, enabled. Whitelisted.
   Friendly contract for the Console:
     @FreqType        4=daily (default), 8=weekly, 16=monthly
     @FreqInterval    daily: every N days; weekly: bitmask of days (1=Sun..64=Sat); monthly: day-of-month
     @FreqSubdayType  1=once at @ActiveStartTime (default), 4=every N minutes, 8=every N hours
     @FreqSubdayInterval  N for subday types 4/8
     @ActiveStartTime HHMMSS (e.g. 010000 = 01:00); @ActiveStartDate YYYYMMDD (NULL = today/keep) */
CREATE OR ALTER PROCEDURE arch.usp_Api_SetAgentJobSchedule
    @JobName sysname,
    @FreqType int = 4,
    @FreqInterval int = 1,
    @FreqSubdayType int = 1,
    @FreqSubdayInterval int = 0,
    @ActiveStartTime int = 010000,
    @ActiveStartDate int = NULL,
    @ScheduleEnabled bit = 1,
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF arch.fn_IsControllableAgentJob(@JobName) = 0
        THROW 50118, 'Job is not a controllable kArchiveManager job.', 1;

    IF @FreqType NOT IN (4, 8, 16)
        THROW 50119, 'Unsupported @FreqType (expected 4=daily, 8=weekly, 16=monthly).', 1;
    IF @FreqSubdayType NOT IN (1, 4, 8)
        THROW 50119, 'Unsupported @FreqSubdayType (expected 1=once, 4=minutes, 8=hours).', 1;
    IF @ActiveStartTime < 0 OR @ActiveStartTime > 235959
        THROW 50119, 'Invalid @ActiveStartTime (expected HHMMSS 0..235959).', 1;

    DECLARE @jobId uniqueidentifier, @schedName sysname, @schedId int;
    SELECT @jobId = job_id FROM msdb.dbo.sysjobs WHERE name = @JobName;
    IF @jobId IS NULL
        THROW 50120, 'Job not found.', 1;

    SELECT TOP (1) @schedId = sch.schedule_id, @schedName = sch.name
    FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules sch ON sch.schedule_id = js.schedule_id
    WHERE js.job_id = @jobId
    ORDER BY sch.schedule_id;

    IF @schedName IS NULL
    BEGIN
        -- No schedule yet — create one.
        EXEC msdb.dbo.sp_add_jobschedule @job_id = @jobId, @name = N'kArchiveManager schedule',
            @enabled = @ScheduleEnabled, @freq_type = @FreqType, @freq_interval = @FreqInterval,
            @freq_subday_type = @FreqSubdayType, @freq_subday_interval = @FreqSubdayInterval,
            @active_start_time = @ActiveStartTime,
            @active_start_date = @ActiveStartDate;
    END
    ELSE
    BEGIN
        EXEC msdb.dbo.sp_update_schedule @name = @schedName, @enabled = @ScheduleEnabled,
            @freq_type = @FreqType, @freq_interval = @FreqInterval,
            @freq_subday_type = @FreqSubdayType, @freq_subday_interval = @FreqSubdayInterval,
            @active_start_time = @ActiveStartTime,
            @active_start_date = @ActiveStartDate;
    END;

    EXEC arch.usp_Api_GetAgentJobs;
END
GO

-- Grants: config_admin + advanced_admin may read/operate the job controls (guarded).
IF DATABASE_PRINCIPAL_ID(N'karch_config_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON arch.usp_Api_GetAgentJobs TO karch_config_admin;
    GRANT EXECUTE ON arch.usp_Api_SetAgentJobEnabled TO karch_config_admin;
    GRANT EXECUTE ON arch.usp_Api_SetAgentJobSchedule TO karch_config_admin;
END;
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON arch.usp_Api_GetAgentJobs TO karch_advanced_admin;
    GRANT EXECUTE ON arch.usp_Api_SetAgentJobEnabled TO karch_advanced_admin;
    GRANT EXECUTE ON arch.usp_Api_SetAgentJobSchedule TO karch_advanced_admin;
END;
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON arch.usp_Api_GetAgentJobs TO karch_viewer;  -- read state is viewer-tier
GO

PRINT 'Agent job-control API installed (usp_Api_GetAgentJobs / SetAgentJobEnabled / SetAgentJobSchedule).';
GO
