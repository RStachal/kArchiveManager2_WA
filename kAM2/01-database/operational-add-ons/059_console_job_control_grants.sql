/* ============================================================================
   059_console_job_control_grants.sql  (PARAMETERIZED operational add-on)
   ----------------------------------------------------------------------------
   Lets the Admin Console enable/disable + reschedule the kAM PREP/RUN jobs from Console >
   Configuration, using the LEAST-privilege model chosen for this deployment:
     - the console SQL login is granted msdb SQLAgentUserRole (can manage ONLY jobs it owns),
     - it is granted SELECT on the msdb job + alerting metadata tables (so the Console job-control
       panel and Go-live readiness can READ job/operator/alert state — SQLAgentUserRole alone does
       NOT grant this), and
     - it is made the OWNER of both kAM jobs.
   Because a SQL Agent job runs in its OWNER's security context, the console login is also granted
   the kArchiveManagerAdmin runtime role (karch_runtime) so the owned jobs can execute the runner
   chain. This consolidates the console + runner identity into one login — simpler than a separate
   runner (a deliberate trade-off vs. T-33's separation; acceptable on a single trusted app host).

   Fill @AppLogin, set @Apply = 1. Idempotent. Run as sysadmin (alters job ownership + msdb roles).
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @AppLogin sysname = N'CHANGE_ME\AppPoolOrServiceLogin';   -- e.g. DOMAIN\WEBHOST$ or DOMAIN\svc_kam_console
DECLARE @Apply bit = 0;                                          -- set 1 to apply (0 = print plan only)

IF @AppLogin LIKE N'CHANGE\_ME%' ESCAPE N'\'
BEGIN
    RAISERROR('Set @AppLogin to the Admin Console SQL login before running 059.', 16, 1);
    RETURN;
END;

IF SUSER_ID(@AppLogin) IS NULL
BEGIN
    RAISERROR('Login %s does not exist on this instance.', 16, 1, @AppLogin);
    RETURN;
END;

PRINT CONCAT('059 console job-control grants for login: ', @AppLogin, CASE WHEN @Apply = 1 THEN ' (APPLY)' ELSE ' (PLAN ONLY — set @Apply=1)' END);

IF @Apply = 0
BEGIN
    PRINT '  Would: add to msdb.SQLAgentUserRole; GRANT SELECT on msdb job/alerting tables; set owner of PREP/RUN jobs; add to kArchiveManagerAdmin.karch_runtime.';
    RETURN;
END;

-- 1) msdb SQLAgentUserRole (manage own jobs).
USE [msdb];
DECLARE @cuMsdb nvarchar(400) = N'CREATE USER ' + QUOTENAME(@AppLogin) + N' FOR LOGIN ' + QUOTENAME(@AppLogin) + N';';
IF DATABASE_PRINCIPAL_ID(@AppLogin) IS NULL
    EXEC sys.sp_executesql @cuMsdb;
EXEC msdb.dbo.sp_addrolemember @rolename = N'SQLAgentUserRole', @membername = @AppLogin;
PRINT '  msdb SQLAgentUserRole: granted.';

-- 1b) Read access to SQL Agent job + alerting metadata.
--     The Console job-control panel (arch.usp_Api_GetAgentJobs) and Go-live readiness
--     (arch.usp_Frontend_GoLiveReadiness) read msdb.dbo.sysjobs / sysoperators / sysalerts /...
--     DIRECTLY. SQLAgentUserRole only lets a principal MANAGE the jobs it owns via the sp_help_job
--     procedures; it does NOT grant SELECT on the underlying job tables (only TargetServersRole has
--     that). Without these grants a non-sysadmin console identity gets
--     "The SELECT permission was denied on the object 'sysjobs'..." and both panels break.
--     Read-only, scoped to the console login. (Verified live 2026-06-25 on RSTSQLDEV2022.)
DECLARE @grantee nvarchar(300) = QUOTENAME(@AppLogin);
DECLARE @msdbRead nvarchar(max) = N'';
SELECT @msdbRead = @msdbRead + N'GRANT SELECT ON dbo.' + QUOTENAME(t) + N' TO ' + @grantee + N';' + NCHAR(10)
FROM (VALUES
    (N'sysjobs'), (N'sysjobsteps'), (N'sysjobschedules'), (N'sysschedules'), (N'sysjobservers'),
    (N'sysjobactivity'), (N'sysjobhistory'),
    (N'sysoperators'), (N'sysalerts'), (N'sysnotifications'), (N'syscategories')
) v(t);
EXEC sys.sp_executesql @msdbRead;
PRINT '  msdb job/alerting read (SELECT): granted (Console job-control + Go-live readiness panels).';

-- 2) Own the two kAM jobs (owner context runs the job).
DECLARE @j sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM msdb.dbo.sysjobs
    WHERE name IN (N'kArchiveManager - PREP CONFIGURED', N'kArchiveManager - RUN CONFIGURED');
OPEN c; FETCH NEXT FROM c INTO @j;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.dbo.sp_update_job @job_name = @j, @owner_login_name = @AppLogin;
    PRINT CONCAT('  job owner set: ', @j);
    FETCH NEXT FROM c INTO @j;
END
CLOSE c; DEALLOCATE c;

-- 3) Runtime role in the control DB so the owned jobs can execute the runner chain.
USE [kArchiveManagerAdmin];
IF DATABASE_PRINCIPAL_ID(N'karch_runtime') IS NOT NULL
BEGIN
    DECLARE @cuAdmin nvarchar(400) = N'CREATE USER ' + QUOTENAME(@AppLogin) + N' FOR LOGIN ' + QUOTENAME(@AppLogin) + N';';
    IF DATABASE_PRINCIPAL_ID(@AppLogin) IS NULL
        EXEC sys.sp_executesql @cuAdmin;
    EXEC sp_addrolemember @rolename = N'karch_runtime', @membername = @AppLogin;
    PRINT '  kArchiveManagerAdmin karch_runtime: granted.';
END
ELSE
    PRINT '  karch_runtime role not found — run v2/055 first if the owned jobs need the runtime chain.';

PRINT '059 complete.';
GO
