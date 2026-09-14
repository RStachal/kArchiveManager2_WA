-- ============================================================================
-- 56 - THE FIVE SQL AGENT JOBS, AS DEPLOYED
-- ============================================================================
-- Creates every kArchiveManager Agent job in one place, with the ownership,
-- schedules and step logic this deployment was tested with.
--
-- WHY THIS SCRIPT EXISTS
--
-- The jobs were assembled across several add-ons (028 replaces the legacy jobs,
-- 036 installs the stale-run recovery, 048 installs the backups, 054 re-owns the
-- runner job) and nowhere were all five written down together. That is fine
-- until you have to rebuild an instance, at which point "which add-ons made
-- which job, and in what order" is guesswork. This reproduces the end state
-- directly. Run the add-ons OR run this; do not interleave them.
--
-- IT ALSO FIXES A DEFECT THE ADD-ONS LEAVE BEHIND
--
-- Both PREP and RUN carry the same step 1, which calls
-- arch.usp_VerifyRunnerPrivileges. That gate exists to refuse a sysadmin runner,
-- and it evaluates whoever OWNS the job. 054 re-owns only RUN (its @JobNameLike
-- default is that exact name), so PREP keeps the login that deployed it and
-- fails on every single start with Error 51001. Here BOTH jobs are owned by the
-- runner from the outset. See 55_fix_prep_job_owner.sql for the diagnosis if you
-- are repairing an existing instance rather than building a new one.
--
-- WHAT EACH JOB IS FOR
--
--   PREP CONFIGURED        Front-loads the candidate scan (@Phase = PREP) so the
--                          RUN window is spent deleting, not selecting. Optional:
--                          RUN prepares its own batches if PREP never runs.
--   RUN CONFIGURED         The archive run itself (@Phase defaults to BOTH).
--   RECOVER STALE RUNS     Closes Run/WorkBatch rows orphaned by a worker that
--                          died mid-batch. Marks them FAILED, never "succeeded" -
--                          success is never inferred from matching counts.
--   BACKUP ... (FULL)      kArchiveManagerBackups is the ONLY copy of a row once
--   BACKUP ... (LOG)       the source delete commits. These are not optional.
--
-- PREP and RUN are created DISABLED, deliberately. Disabled stops the SCHEDULE,
-- not the job: sp_start_job runs a disabled job, and that is the intended
-- on-demand path until an operator commits to the schedule.
--
-- Idempotent: an existing job of the same name is dropped and rebuilt.
-- Requires sysadmin (sp_add_job with an explicit @owner_login_name does).
-- ============================================================================
SET NOCOUNT ON;

DECLARE @RuntimeLogin  sysname       = N'karch_runtime_svc';            -- created by 053
DECLARE @AdminDb       sysname       = N'kArchiveManagerAdmin';
DECLARE @ArchiveDb     sysname       = N'kArchiveManagerBackups';
DECLARE @RunProfile    sysname       = N'JOB_DEFAULT';
DECLARE @BackupRoot    nvarchar(500) = NULL;    -- NULL = instance default backup path + \<ArchiveDb>
DECLARE @KeepFullDays  int           = 35;
DECLARE @KeepLogDays   int           = 8;
DECLARE @StaleMinutes  int           = 30;      -- age at which a RUNNING row is considered abandoned
DECLARE @Apply         bit           = 0;       -- set 1 to create the jobs

------------------------------------------------------------------------------
-- Guards. Every one of these has cost someone an afternoon.
------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @RuntimeLogin)
BEGIN
    RAISERROR('Runner login %s does not exist. Run 053_runtime_least_privilege_principal.sql first.', 16, 1, @RuntimeLogin);
    RETURN;
END;

-- SUSER_SID resolves a Windows principal even with no SQL login, so test
-- sys.server_principals, never SUSER_SID, when checking that a login exists.

IF IS_SRVROLEMEMBER('sysadmin', @RuntimeLogin) = 1
BEGIN
    RAISERROR('Login %s is a sysadmin. Step 1 of PREP and RUN will refuse it (Error 51001). Fix 053 first.', 16, 1, @RuntimeLogin);
    RETURN;
END;

IF DB_ID(@AdminDb) IS NULL   BEGIN RAISERROR('Database %s not found.', 16, 1, @AdminDb);   RETURN; END;
IF DB_ID(@ArchiveDb) IS NULL BEGIN RAISERROR('Database %s not found.', 16, 1, @ArchiveDb); RETURN; END;

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @AdminDb)
   OR NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(QUOTENAME(@AdminDb) + N'.arch.RunProfile'))
BEGIN
    PRINT 'NOTE: cannot see arch.RunProfile from here; run profile ' + @RunProfile + ' is not verified.';
END;

-- InstanceDefaultBackupPath does NOT come back with a trailing separator on every
-- build, so add one explicitly rather than concatenating and hoping. Getting this
-- wrong produces "...\BackupkArchiveManagerBackups" and a backup job that writes
-- to a folder nobody looks in.
IF @BackupRoot IS NULL
BEGIN
    SET @BackupRoot = CONVERT(nvarchar(400), SERVERPROPERTY('InstanceDefaultBackupPath'));
    SET @BackupRoot = CASE WHEN RIGHT(@BackupRoot, 1) = N'\' THEN @BackupRoot ELSE @BackupRoot + N'\' END
                    + @ArchiveDb;
END;
SET @BackupRoot = CASE WHEN RIGHT(@BackupRoot, 1) = N'\' THEN LEFT(@BackupRoot, LEN(@BackupRoot) - 1) ELSE @BackupRoot END;

------------------------------------------------------------------------------
-- A) What exists now
------------------------------------------------------------------------------
SELECT Section = 'A_EXISTING',
       JobName = j.name,
       Owner   = SUSER_SNAME(j.owner_sid),
       OwnerIsSysadmin = CASE WHEN IS_SRVROLEMEMBER('sysadmin', SUSER_SNAME(j.owner_sid)) = 1 THEN 'YES' ELSE 'no' END,
       j.enabled
FROM msdb.dbo.sysjobs j
WHERE j.name LIKE N'kArchiveManager%'
ORDER BY j.name;

SELECT Section = 'A_SETTINGS', RunnerLogin = @RuntimeLogin, AdminDb = @AdminDb,
       ArchiveDb = @ArchiveDb, RunProfile = @RunProfile, BackupRoot = @BackupRoot,
       KeepFullDays = @KeepFullDays, KeepLogDays = @KeepLogDays, StaleMinutes = @StaleMinutes;

IF @Apply = 0
BEGIN
    PRINT '';
    PRINT '56: PLAN ONLY. Set @Apply = 1 to (re)create all five jobs.';
    PRINT '    Existing jobs with these names WILL BE DROPPED and rebuilt.';
    PRINT '    Backup folder used: ' + @BackupRoot;
    RETURN;
END;

------------------------------------------------------------------------------
-- B) Backup folder. BACKUP DATABASE will not create it.
------------------------------------------------------------------------------
DECLARE @dirOk int;
EXEC master.dbo.xp_create_subdir @BackupRoot;
PRINT 'Backup folder ensured: ' + @BackupRoot;

------------------------------------------------------------------------------
-- C) Drop any existing jobs of these names
------------------------------------------------------------------------------
DECLARE @names TABLE (name sysname);
INSERT @names (name) VALUES
    (N'kArchiveManager - PREP CONFIGURED'),
    (N'kArchiveManager - RUN CONFIGURED'),
    (N'kArchiveManager - RECOVER STALE RUNS'),
    (N'kArchiveManager - BACKUP ARCHIVE DB (FULL)'),
    (N'kArchiveManager - BACKUP ARCHIVE DB (LOG)');

DECLARE @n sysname;
DECLARE cDrop CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @names;
OPEN cDrop; FETCH NEXT FROM cDrop INTO @n;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @n)
    BEGIN
        EXEC msdb.dbo.sp_delete_job @job_name = @n, @delete_unused_schedule = 1;
        PRINT '  dropped: ' + @n;
    END
    FETCH NEXT FROM cDrop INTO @n;
END
CLOSE cDrop; DEALLOCATE cDrop;

DECLARE @cat sysname = N'[Uncategorized (Local)]';

------------------------------------------------------------------------------
-- D) PREP CONFIGURED
--    Owned by the runner. That is the fix - see the header.
------------------------------------------------------------------------------
DECLARE @validateStep nvarchar(max) = N'
DECLARE @rc int;
EXEC @rc = arch.usp_ValidateConfiguration;
IF @rc <> 0
    THROW 51000, ''kArchiveManager validation failed. See result set from arch.usp_ValidateConfiguration.'', 1;

-- Runtime least-privilege gate. This step runs in the JOB OWNER context, so
-- usp_VerifyRunnerPrivileges evaluates the RUNNER''s own effective rights.
-- RETURN 1 => THROW => blocked before any delete. Guarded so older installs
-- without the procedure still validate.
IF OBJECT_ID(N''arch.usp_VerifyRunnerPrivileges'', N''P'') IS NOT NULL
BEGIN
    DECLARE @rp int;
    EXEC @rp = arch.usp_VerifyRunnerPrivileges;
    IF @rp <> 0
        THROW 51001, ''kArchiveManager runner privilege gate failed. See result set from arch.usp_VerifyRunnerPrivileges; fix each ERROR row, then retry.'', 1;
END;';

EXEC msdb.dbo.sp_add_job
     @job_name = N'kArchiveManager - PREP CONFIGURED',
     @enabled = 0,
     @description = N'Prepares kArchiveManager ANCHOR candidates (run profile JOB_DEFAULT, @Phase=PREP). Front-loads the candidate scan so the RUN job only deletes.',
     @category_name = @cat,
     @owner_login_name = @RuntimeLogin,
     @notify_level_eventlog = 2;

EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'kArchiveManager - PREP CONFIGURED',
     @step_id = 1, @step_name = N'VALIDATE CONFIGURATION',
     @subsystem = N'TSQL', @database_name = @AdminDb,
     @command = @validateStep,
     @on_success_action = 3,   -- go to next step
     @on_fail_action = 2;      -- quit with failure

DECLARE @prepCmd nvarchar(max) = N'EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N''' + REPLACE(@RunProfile, N'''', N'''''') + N''', @Phase = N''PREP'';';
EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'kArchiveManager - PREP CONFIGURED',
     @step_id = 2, @step_name = N'PREPARE CONFIGURED PROCESSES',
     @subsystem = N'TSQL', @database_name = @AdminDb,
     @command = @prepCmd,
     @on_success_action = 1, @on_fail_action = 2;

EXEC msdb.dbo.sp_add_jobschedule
     @job_name = N'kArchiveManager - PREP CONFIGURED',
     @name = N'kArchiveManager - PREP daily (disabled template)',
     @enabled = 0, @freq_type = 4, @freq_interval = 1,
     @freq_subday_type = 1, @active_start_time = 003000;    -- 00:30

EXEC msdb.dbo.sp_add_jobserver @job_name = N'kArchiveManager - PREP CONFIGURED';
PRINT '  created: kArchiveManager - PREP CONFIGURED (disabled, owner ' + @RuntimeLogin + ')';

------------------------------------------------------------------------------
-- E) RUN CONFIGURED
------------------------------------------------------------------------------
EXEC msdb.dbo.sp_add_job
     @job_name = N'kArchiveManager - RUN CONFIGURED',
     @enabled = 0,
     @description = N'Runs kArchiveManager using Admin DB run profile JOB_DEFAULT.',
     @category_name = @cat,
     @owner_login_name = @RuntimeLogin,
     @notify_level_eventlog = 2;

EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'kArchiveManager - RUN CONFIGURED',
     @step_id = 1, @step_name = N'VALIDATE CONFIGURATION',
     @subsystem = N'TSQL', @database_name = @AdminDb,
     @command = @validateStep,
     @on_success_action = 3, @on_fail_action = 2;

DECLARE @runCmd nvarchar(max) = N'EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N''' + REPLACE(@RunProfile, N'''', N'''''') + N''';';
EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'kArchiveManager - RUN CONFIGURED',
     @step_id = 2, @step_name = N'RUN CONFIGURED PROCESSES',
     @subsystem = N'TSQL', @database_name = @AdminDb,
     @command = @runCmd,
     @on_success_action = 1, @on_fail_action = 2;

EXEC msdb.dbo.sp_add_jobschedule
     @job_name = N'kArchiveManager - RUN CONFIGURED',
     @name = N'Hourly disabled template',
     @enabled = 0, @freq_type = 4, @freq_interval = 1,
     @freq_subday_type = 8, @freq_subday_interval = 1,     -- every 1 hour
     @active_start_time = 010000;

EXEC msdb.dbo.sp_add_jobserver @job_name = N'kArchiveManager - RUN CONFIGURED';
PRINT '  created: kArchiveManager - RUN CONFIGURED (disabled, owner ' + @RuntimeLogin + ')';

------------------------------------------------------------------------------
-- F) RECOVER STALE RUNS - enabled, every 15 minutes
--
--    The schedule interval and the staleness threshold are different numbers on
--    purpose: it looks every 15 minutes for runs that have been silent for 30.
------------------------------------------------------------------------------
DECLARE @recoverCmd nvarchar(max) = N'EXEC arch.usp_RecoverStaleRuns
     @StaleAfterMinutes = ' + CONVERT(nvarchar(10), @StaleMinutes) + N',
     @DryRun = 0,
     @VerboseOutput = 0;';

EXEC msdb.dbo.sp_add_job
     @job_name = N'kArchiveManager - RECOVER STALE RUNS',
     @enabled = 1,
     @description = N'Recovers Run/RunItem/WorkBatch records stuck in RUNNING (arch.usp_RecoverStaleRuns). Runs every 15 minutes.',
     @category_name = @cat,
     @owner_login_name = @RuntimeLogin,
     @notify_level_eventlog = 2;

EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'kArchiveManager - RECOVER STALE RUNS',
     @step_id = 1, @step_name = N'RECOVER STALE RUNS',
     @subsystem = N'TSQL', @database_name = @AdminDb,
     @command = @recoverCmd,
     @on_success_action = 1, @on_fail_action = 2;

EXEC msdb.dbo.sp_add_jobschedule
     @job_name = N'kArchiveManager - RECOVER STALE RUNS',
     @name = N'Every 15 minutes',
     @enabled = 1, @freq_type = 4, @freq_interval = 1,
     @freq_subday_type = 4, @freq_subday_interval = 15;

EXEC msdb.dbo.sp_add_jobserver @job_name = N'kArchiveManager - RECOVER STALE RUNS';
PRINT '  created: kArchiveManager - RECOVER STALE RUNS (enabled)';

------------------------------------------------------------------------------
-- G) BACKUP ARCHIVE DB (FULL) - daily 01:30
--
--    Owned by a sysadmin, NOT the runner: BACKUP DATABASE and xp_delete_file
--    are not, and must not be, in the runner's least-privilege footprint.
------------------------------------------------------------------------------
DECLARE @bkOwner sysname = SUSER_SNAME();   -- whoever is running this script

DECLARE @fullCmd nvarchar(max) = N'
SET NOCOUNT ON; SET XACT_ABORT ON;
DECLARE @f nvarchar(700) = N''' + REPLACE(@BackupRoot, N'''', N'''''') + N'\' + @ArchiveDb + N'_FULL_'' + FORMAT(SYSDATETIME(), ''yyyyMMdd_HHmmss'') + N''.bak'';
BACKUP DATABASE ' + QUOTENAME(@ArchiveDb) + N' TO DISK = @f WITH COMPRESSION, CHECKSUM, INIT, STATS = 10;
RESTORE VERIFYONLY FROM DISK = @f WITH CHECKSUM;
DECLARE @cut datetime = DATEADD(DAY, -' + CONVERT(nvarchar(10), @KeepFullDays) + N', GETDATE());
EXEC master.dbo.xp_delete_file 0, N''' + REPLACE(@BackupRoot, N'''', N'''''') + N''', N''bak'', @cut, 0;';

EXEC msdb.dbo.sp_add_job
     @job_name = N'kArchiveManager - BACKUP ARCHIVE DB (FULL)',
     @enabled = 1,
     @description = N'FULL backup of the kArchiveManager archive database (system-of-record for deleted rows) with verify + retention.',
     @category_name = @cat,
     @owner_login_name = @bkOwner,
     @notify_level_eventlog = 2;

EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'kArchiveManager - BACKUP ARCHIVE DB (FULL)',
     @step_id = 1, @step_name = N'FULL BACKUP',
     @subsystem = N'TSQL', @database_name = N'master',
     @command = @fullCmd,
     @on_success_action = 1, @on_fail_action = 2;

EXEC msdb.dbo.sp_add_jobschedule
     @job_name = N'kArchiveManager - BACKUP ARCHIVE DB (FULL)',
     @name = N'Daily', @enabled = 1,
     @freq_type = 4, @freq_interval = 1,
     @freq_subday_type = 1, @active_start_time = 013000;   -- 01:30

EXEC msdb.dbo.sp_add_jobserver @job_name = N'kArchiveManager - BACKUP ARCHIVE DB (FULL)';
PRINT '  created: kArchiveManager - BACKUP ARCHIVE DB (FULL) (enabled, daily 01:30)';

------------------------------------------------------------------------------
-- H) BACKUP ARCHIVE DB (LOG) - hourly
--
--    Guarded on the recovery model: in SIMPLE, BACKUP LOG fails, so the step
--    checks first and does nothing rather than failing the job every hour.
------------------------------------------------------------------------------
DECLARE @logCmd nvarchar(max) = N'
SET NOCOUNT ON; SET XACT_ABORT ON;
IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N''' + @ArchiveDb + N''') = N''FULL''
BEGIN
    DECLARE @f nvarchar(700) = N''' + REPLACE(@BackupRoot, N'''', N'''''') + N'\' + @ArchiveDb + N'_LOG_'' + FORMAT(SYSDATETIME(), ''yyyyMMdd_HHmmss'') + N''.trn'';
    BACKUP LOG ' + QUOTENAME(@ArchiveDb) + N' TO DISK = @f WITH COMPRESSION, CHECKSUM;
    DECLARE @cut datetime = DATEADD(DAY, -' + CONVERT(nvarchar(10), @KeepLogDays) + N', GETDATE());
    EXEC master.dbo.xp_delete_file 0, N''' + REPLACE(@BackupRoot, N'''', N'''''') + N''', N''trn'', @cut, 0;
END;';

EXEC msdb.dbo.sp_add_job
     @job_name = N'kArchiveManager - BACKUP ARCHIVE DB (LOG)',
     @enabled = 1,
     @description = N'Transaction-log backup of the kArchiveManager archive database (FULL recovery) with retention.',
     @category_name = @cat,
     @owner_login_name = @bkOwner,
     @notify_level_eventlog = 2;

EXEC msdb.dbo.sp_add_jobstep
     @job_name = N'kArchiveManager - BACKUP ARCHIVE DB (LOG)',
     @step_id = 1, @step_name = N'LOG BACKUP',
     @subsystem = N'TSQL', @database_name = N'master',
     @command = @logCmd,
     @on_success_action = 1, @on_fail_action = 2;

EXEC msdb.dbo.sp_add_jobschedule
     @job_name = N'kArchiveManager - BACKUP ARCHIVE DB (LOG)',
     @name = N'Hourly', @enabled = 1,
     @freq_type = 4, @freq_interval = 1,
     @freq_subday_type = 4, @freq_subday_interval = 60;

EXEC msdb.dbo.sp_add_jobserver @job_name = N'kArchiveManager - BACKUP ARCHIVE DB (LOG)';
PRINT '  created: kArchiveManager - BACKUP ARCHIVE DB (LOG) (enabled, hourly)';

------------------------------------------------------------------------------
-- I) Result
------------------------------------------------------------------------------
PRINT '';
SELECT Section = 'I_RESULT',
       JobName = j.name,
       Owner   = SUSER_SNAME(j.owner_sid),
       j.enabled,
       Steps     = (SELECT COUNT(*) FROM msdb.dbo.sysjobsteps s WHERE s.job_id = j.job_id),
       Schedules = (SELECT COUNT(*) FROM msdb.dbo.sysjobschedules js WHERE js.job_id = j.job_id)
FROM msdb.dbo.sysjobs j
WHERE j.name LIKE N'kArchiveManager%'
ORDER BY j.name;

PRINT '';
PRINT 'Next: prove the two runner jobs get past step 1 - that is the step that has';
PRINT 'historically failed, and it fails in one second, so it is cheap to test:';
PRINT '  EXEC msdb.dbo.sp_start_job @job_name = N''kArchiveManager - PREP CONFIGURED'';';
PRINT '  EXEC msdb.dbo.sp_start_job @job_name = N''kArchiveManager - RUN CONFIGURED'';';
PRINT 'then read msdb.dbo.sysjobhistory for each - step 1 must SUCCEED, not 51001.';
PRINT '';
PRINT 'PREP and RUN stay DISABLED until an operator commits to the schedule.';
PRINT 'Disabled stops the schedule only; sp_start_job runs them on demand.';
