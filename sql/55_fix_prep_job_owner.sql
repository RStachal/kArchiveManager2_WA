-- ============================================================================
-- 55 - RE-OWN THE PREP JOB TO THE RUNNER LOGIN
-- ============================================================================
-- Fixes a defect in the shipped add-on 054_runner_job_least_privilege.sql that
-- makes "kArchiveManager - PREP CONFIGURED" fail every time it is started.
--
-- THE DEFECT
--
-- Both jobs carry the same step 1:
--
--     EXEC @rc = arch.usp_ValidateConfiguration;   IF @rc <> 0 THROW 51000 ...
--     IF OBJECT_ID(N'arch.usp_VerifyRunnerPrivileges', N'P') IS NOT NULL
--     BEGIN
--         EXEC @rp = arch.usp_VerifyRunnerPrivileges;
--         IF @rp <> 0 THROW 51001, 'kArchiveManager runner privilege gate failed...'
--     END;
--
-- The comment in the RUN job's copy states the design intent outright:
--
--     "This step runs in the JOB OWNER context (the dedicated non-sysadmin
--      runner login after deploy/v2/054), so usp_VerifyRunnerPrivileges'
--      HAS_PERMS_BY_NAME / IS_SRVROLEMEMBER checks evaluate the RUNNER's own
--      effective rights."
--
-- But 054 re-owns only ONE job. Its parameter is:
--
--     @JobNameLike nvarchar(256) = N'kArchiveManager - RUN CONFIGURED'
--         -- EXACT canonical runner job (avoids re-owning legacy 'RUN 00:05',
--         --  backup/alerting)
--
-- so PREP keeps whatever login deployed it - in practice a sysadmin. The gate
-- then evaluates THAT principal, finds it is a sysadmin, and refuses:
--
--     ERROR  SERVER  Runner principal [<sysadmin>] is a member of the sysadmin
--            server role. The unattended archive runner must run under a
--            dedicated NON-sysadmin login (see deploy/v2/053). Re-own the SQL
--            Agent job to the least-privilege login (deploy/v2/054).
--
-- Observed on the reference instance, 2026-09-14: the job died 1 second after
-- sp_start_job, step 1, Error 51001, "The job failed."
--
-- The gate is right and the job is wrong. PREP is a runner job - it writes
-- arch.WorkBatch / arch.WorkBatchKey and reads every mapped source table, which
-- is exactly what karch_runtime grants. It must run as the runner, like RUN.
--
-- WHY NOT JUST RUN 054 WITH @JobNameLike SET TO PREP
--
-- You can, and it does the same thing. This script exists because that is not
-- obvious from 054 - its default hides the problem, and a deployment that runs
-- the add-ons in order ends up with a PREP job that has never once succeeded.
-- Run this after 054, or pass PREP to 054 explicitly. Either is fine.
--
-- Idempotent. Requires sysadmin (sp_update_job @owner_login_name does).
-- ============================================================================
SET NOCOUNT ON;

DECLARE @RuntimeLogin sysname = N'karch_runtime_svc';   -- the login created by 053
DECLARE @JobName      sysname = N'kArchiveManager - PREP CONFIGURED';
DECLARE @Apply        bit     = 0;                      -- set 1 to apply

------------------------------------------------------------------------------
-- Guards
------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @RuntimeLogin)
BEGIN
    RAISERROR('Runner login %s does not exist. Run 053_runtime_least_privilege_principal.sql first.', 16, 1, @RuntimeLogin);
    RETURN;
END;

IF IS_SRVROLEMEMBER('sysadmin', @RuntimeLogin) = 1
BEGIN
    RAISERROR('Login %s is a sysadmin. The runner must NOT be - the privilege gate will refuse it. Fix 053 first.', 16, 1, @RuntimeLogin);
    RETURN;
END;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
BEGIN
    RAISERROR('Job %s does not exist on this instance.', 16, 1, @JobName);
    RETURN;
END;

------------------------------------------------------------------------------
-- A) Before
------------------------------------------------------------------------------
SELECT Section    = 'A_BEFORE',
       JobName    = j.name,
       Owner      = SUSER_SNAME(j.owner_sid),
       OwnerIsSysadmin = CASE WHEN IS_SRVROLEMEMBER('sysadmin', SUSER_SNAME(j.owner_sid)) = 1
                              THEN 'YES - the runner gate WILL refuse this job' ELSE 'no' END,
       Enabled    = j.enabled
FROM msdb.dbo.sysjobs j
WHERE j.name IN (@JobName, N'kArchiveManager - RUN CONFIGURED')
ORDER BY j.name;

------------------------------------------------------------------------------
-- B) The gate, evaluated as the runner - this is what step 1 will see
------------------------------------------------------------------------------
IF OBJECT_ID(N'arch.usp_VerifyRunnerPrivileges', N'P') IS NOT NULL
BEGIN
    DECLARE @sql nvarchar(max) = N'
        DECLARE @rp int;
        EXEC @rp = arch.usp_VerifyRunnerPrivileges;
        SELECT Section = ''B_GATE_AS_RUNNER'', GateReturnCode = @rp,
               Verdict = CASE WHEN @rp = 0 THEN ''PASS - PREP will get past step 1''
                              ELSE ''FAIL - fix the ERROR rows above before re-owning'' END;';
    EXECUTE AS LOGIN = @RuntimeLogin;
    EXEC sys.sp_executesql @sql;
    REVERT;
END;

------------------------------------------------------------------------------
-- C) Apply
------------------------------------------------------------------------------
IF @Apply = 0
BEGIN
    PRINT '';
    PRINT '55: PLAN ONLY. Set @Apply = 1 to re-own ' + @JobName + ' to ' + @RuntimeLogin + '.';
    PRINT '    Read section B first - if the gate does not return 0 as the runner,';
    PRINT '    re-owning the job only moves the failure, it does not fix it.';
    RETURN;
END;

EXEC msdb.dbo.sp_update_job @job_name = @JobName, @owner_login_name = @RuntimeLogin;
PRINT '55: ' + @JobName + ' re-owned to ' + @RuntimeLogin + '.';

------------------------------------------------------------------------------
-- D) After
------------------------------------------------------------------------------
SELECT Section = 'D_AFTER',
       JobName = j.name,
       Owner   = SUSER_SNAME(j.owner_sid),
       Enabled = j.enabled
FROM msdb.dbo.sysjobs j
WHERE j.name IN (@JobName, N'kArchiveManager - RUN CONFIGURED')
ORDER BY j.name;

PRINT '';
PRINT 'Now prove it: EXEC msdb.dbo.sp_start_job @job_name = N''' + @JobName + ''';';
PRINT 'then read the outcome - step 1 must SUCCEED, not fail with 51001:';
PRINT '  SELECT TOP 4 step_id, step_name, run_status, message';
PRINT '  FROM msdb.dbo.sysjobhistory';
PRINT '  WHERE job_id = (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = N''' + @JobName + ''')';
PRINT '  ORDER BY instance_id DESC;';
