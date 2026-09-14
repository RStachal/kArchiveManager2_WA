/* ============================================================================
   054 — T-33 (deploy part): run the archive Agent job(s) under the least-privilege runner identity
   ----------------------------------------------------------------------------
   Companion to deploy/v2/053 (creates login [karch_runtime_svc] + grants). This re-owns the
   kArchiveManager SQL Agent runner job(s) to that least-privilege login.

   WHY job OWNER and not a PROXY:  a SQL Server Agent **T-SQL subsystem** job step ignores
   @proxy_name entirely. Its execution context is decided by the job OWNER:
       • owner IS sysadmin   -> the step runs in the SQL Agent service account context (full rights)  <-- the T-33 problem
       • owner is NOT sysadmin-> Agent impersonates the owner (EXECUTE AS LOGIN) for the step          <-- what we want
   So the correct way to make the T-SQL runner run least-privilege is to OWN the job with the
   dedicated non-sysadmin login from 053. (If you prefer a Windows-credential proxy, convert the step
   to the CmdExec/PowerShell subsystem driving `sqlcmd -E -Q "EXEC arch.usp_RunProfile_Prepared..."`
   and bind @proxy_name to a credential for a Windows account that holds the same karch_runtime grants
   — see the commented template at the bottom.)

   PARAMETERIZED + IDEMPOTENT. Fill CHANGE-ME, run in classic SSMS (no SQLCMD mode) as sysadmin
   (sp_update_job @owner_login_name requires sysadmin). Re-running is safe.
   ============================================================================ */
USE [msdb];
GO
SET NOCOUNT ON;
GO

/* =========================== CHANGE-ME ===================================== */
DECLARE
    @RuntimeLogin sysname      = N'karch_runtime_svc',                 -- must match deploy/v2/053
    @JobNameLike  nvarchar(256)= N'kArchiveManager - RUN CONFIGURED',  -- EXACT canonical runner job (avoids re-owning legacy 'RUN 00:05', backup/alerting)
    @AlsoRecover  bit          = 0,                                    -- LEAVE 0: see note below
    @Apply        bit          = 0;                                    -- 0 = preview; 1 = apply
/* ========================================================================== */
/* WHY @AlsoRecover defaults to 0:  'kArchiveManager - RECOVER STALE RUNS' calls usp_RecoverStaleRuns,
   whose liveness test reads OTHER sessions in sys.dm_exec_sessions. A non-sysadmin login WITHOUT
   VIEW SERVER STATE sees only its OWN session, so the NOT EXISTS is always true and it would mark
   genuinely-live runs FAILED (the exact T-03 race the WorkerSessionId tracking prevents). Recovery is a
   privileged operation distinct from the delete-runner — keep it owned by the Agent service account /
   sysadmin. Only set @AlsoRecover=1 if you ALSO grant the runner VIEW SERVER STATE (see deploy/v2/053). */

IF SUSER_ID(@RuntimeLogin) IS NULL
BEGIN
    RAISERROR('Login [%s] does not exist. Run deploy/v2/053 first.', 16, 1, @RuntimeLogin);
    RETURN;
END

IF IS_SRVROLEMEMBER(N'sysadmin', @RuntimeLogin) = 1
BEGIN
    RAISERROR('Login [%s] is a member of sysadmin — owning the job with it would NOT reduce privilege (T-SQL steps of a sysadmin-owned job run as the Agent service account). Remove it from sysadmin first.', 16, 1, @RuntimeLogin);
    RETURN;
END

/* matched jobs */
DECLARE @jobs TABLE (job_id uniqueidentifier PRIMARY KEY, name sysname, owner_sid varbinary(85));
INSERT @jobs(job_id, name, owner_sid)
SELECT j.job_id, j.name, j.owner_sid
FROM msdb.dbo.sysjobs j
WHERE j.name LIKE @JobNameLike
   OR (@AlsoRecover = 1 AND j.name = N'kArchiveManager - RECOVER STALE RUNS');

IF NOT EXISTS (SELECT 1 FROM @jobs)
BEGIN
    PRINT 'No matching jobs found for pattern ''' + @JobNameLike + '''. Nothing to do.';
    RETURN;
END

PRINT '--- Jobs matched (current owner -> target owner [' + @RuntimeLogin + ']) ---';
SELECT j.name AS JobName,
       CurrentOwner = SUSER_SNAME(j.owner_sid),
       TargetOwner  = @RuntimeLogin
FROM @jobs j
ORDER BY j.name;

IF @Apply = 0
BEGIN
    PRINT 'PREVIEW ONLY (@Apply=0). Review the list, set @Apply=1, then re-run.';
    RETURN;
END

DECLARE @name sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @jobs ORDER BY name;
OPEN c;
FETCH NEXT FROM c INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.dbo.sp_update_job @job_name = @name, @owner_login_name = @RuntimeLogin;
    PRINT 'Re-owned [' + @name + '] -> [' + @RuntimeLogin + '].';
    FETCH NEXT FROM c INTO @name;
END
CLOSE c;
DEALLOCATE c;

PRINT 'Done. The runner job(s) T-SQL steps now execute under [' + @RuntimeLogin + '] (non-sysadmin = least privilege).';
PRINT 'Verify the gate: the job''s VALIDATE step should EXEC arch.usp_VerifyRunnerPrivileges (RETURN 1 => THROW => job fails). See the job template in deploy/v2/09_install_disabled_sql_agent_job.sql.';
GO

/* ----------------------------------------------------------------------------
   OPTIONAL ALTERNATIVE — Windows-credential proxy (only if you must use a proxy):
   convert the run step to CmdExec and bind a proxy. The Windows account behind the credential
   needs the same [karch_runtime] grants (run deploy/v2/053 with @LoginType='WINDOWS' for it).

   USE [master];
   CREATE CREDENTIAL [kAM Runner Cred] WITH IDENTITY = N'DOMAIN\svc-karchive', SECRET = N'<pwd>';
   USE [msdb];
   EXEC msdb.dbo.sp_add_proxy  @proxy_name = N'kAM Runner Proxy', @credential_name = N'kAM Runner Cred', @enabled = 1;
   EXEC msdb.dbo.sp_grant_proxy_to_subsystem @proxy_name = N'kAM Runner Proxy', @subsystem_id = 3;  -- 3 = CmdExec
   -- then sp_update_jobstep ... @subsystem = N'CMDEXEC',
   --      @command = N'sqlcmd -S (local) -d kArchiveManagerAdmin -E -b -Q "EXEC arch.usp_RunProfile_Prepared @RunProfileCode=N''JOB_DEFAULT'';"',
   --      @proxy_name = N'kAM Runner Proxy';
   ---------------------------------------------------------------------------- */
