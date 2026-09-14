/* ============================================================================
   047 — Operational failure alerting (audit task T-14)
   ============================================================================
   PROBLEM: both v2 Agent jobs run @notify_level_email=0 with no operator and Database Mail is not
   configured, so a FAILED scheduled run, a recovery-job failure, or a Divergence>0 /
   ROW_COUNT_MISMATCH surfaced by arch.v_OperationalHealth (Severity='ERROR') pages NOBODY. For an
   irreversible-delete platform a silently failed/partial run is a data-trust hole.

   FIX (this script): wire failure email on both jobs to a SQL Agent operator, and add a scheduled
   "HEALTH ALERT" job that emails when arch.v_OperationalHealth reports any ERROR row.

   ENVIRONMENT-SPECIFIC — fill in the variables below before running. Database Mail needs the
   customer SMTP relay. If @SmtpServer is left as the placeholder the mail account/profile is skipped
   (operator + job wiring + alert job are still installed; mail will start working once the profile
   exists). Idempotent: safe to re-run.
   Run on the SQL Server hosting the kArchiveManager Agent jobs (operates in msdb).
   ============================================================================ */
USE [msdb];
SET NOCOUNT ON;

-- ============================ FILL THESE IN ============================
DECLARE @OperatorName  sysname        = N'kArchiveManager Ops';
DECLARE @OperatorEmail nvarchar(200)  = N'CHANGE-ME-ops@customer.example';     -- <<< recipient(s), ; separated
DECLARE @MailProfile   sysname        = N'kArchiveManager';
DECLARE @SmtpServer    sysname        = N'CHANGE-ME-smtp.customer.example';     -- <<< leave as CHANGE-ME to skip mail setup
DECLARE @SmtpPort      int            = 25;
DECLARE @MailFrom      nvarchar(200)  = N'noreply@customer.example';           -- <<< sender address
DECLARE @AlertEveryMin int            = 15;                                     -- health-alert cadence
-- ======================================================================

DECLARE @placeholder bit = CASE WHEN @SmtpServer LIKE N'CHANGE-ME%' OR @OperatorEmail LIKE N'CHANGE-ME%' THEN 1 ELSE 0 END;

/* 1) Enable Database Mail XPs (idempotent, server-level). */
IF (SELECT CONVERT(int, value_in_use) FROM sys.configurations WHERE name = 'Database Mail XPs') <> 1
BEGIN
    EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
    EXEC sp_configure 'Database Mail XPs', 1;      RECONFIGURE;
    PRINT '047: enabled Database Mail XPs.';
END;

/* 2) Mail account + profile (skipped while SMTP is a placeholder). */
IF @placeholder = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = @MailProfile)
        EXEC msdb.dbo.sysmail_add_account_sp
            @account_name = @MailProfile, @email_address = @MailFrom,
            @display_name = N'kArchiveManager', @mailserver_name = @SmtpServer, @port = @SmtpPort;

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @MailProfile)
        EXEC msdb.dbo.sysmail_add_profile_sp @profile_name = @MailProfile, @description = N'kArchiveManager alerts';

    IF NOT EXISTS (
        SELECT 1 FROM msdb.dbo.sysmail_profileaccount pa
        JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pa.profile_id AND p.name = @MailProfile)
        EXEC msdb.dbo.sysmail_add_profileaccount_sp @profile_name = @MailProfile, @account_name = @MailProfile, @sequence_number = 1;
    PRINT '047: Database Mail account/profile ensured.';
END
ELSE
    PRINT '047: SMTP placeholder still set — mail account/profile SKIPPED. Fill @SmtpServer/@OperatorEmail and re-run for delivery.';

/* 3) Operator. */
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
    EXEC msdb.dbo.sp_add_operator @name = @OperatorName, @enabled = 1, @email_address = @OperatorEmail;
ELSE
    EXEC msdb.dbo.sp_update_operator @name = @OperatorName, @enabled = 1, @email_address = @OperatorEmail;

/* 4) Wire failure email on the two delete-platform jobs (email on failure = notify_level 2). */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'kArchiveManager - RUN CONFIGURED')
    EXEC msdb.dbo.sp_update_job @job_name = N'kArchiveManager - RUN CONFIGURED',
        @notify_level_email = 2, @notify_email_operator_name = @OperatorName;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'kArchiveManager - RECOVER STALE RUNS')
    EXEC msdb.dbo.sp_update_job @job_name = N'kArchiveManager - RECOVER STALE RUNS',
        @notify_level_email = 2, @notify_email_operator_name = @OperatorName;

/* 5) HEALTH ALERT job — emails when arch.v_OperationalHealth has any Severity='ERROR' row. */
DECLARE @alertJob sysname = N'kArchiveManager - HEALTH ALERT';
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @alertJob)
    EXEC msdb.dbo.sp_delete_job @job_name = @alertJob, @delete_unused_schedule = 1;

DECLARE @stepCmd nvarchar(max) = N'
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM kArchiveManagerAdmin.arch.v_OperationalHealth WHERE Severity = N''ERROR'')
BEGIN
    DECLARE @body nvarchar(max) =
        N''kArchiveManager health check found ERROR rows on '' + @@SERVERNAME + N'' ('' + CONVERT(varchar(30), SYSUTCDATETIME(), 121) + N'' UTC):'' + CHAR(13)+CHAR(10);
    SELECT @body = @body + CHAR(13)+CHAR(10)
        + ISNULL(HealthArea,N''?'') + N'' | '' + ISNULL(ProcessCode,N''-'') + N''/'' + ISNULL(SourceDb,N''-'')
        + N'' | Run '' + ISNULL(CONVERT(varchar(20),RunId),N''-'') + N'' | '' + ISNULL(Details,N'''')
    FROM kArchiveManagerAdmin.arch.v_OperationalHealth WHERE Severity = N''ERROR'';
    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = N''' + REPLACE(@MailProfile, N'''', N'''''') + N''',
        @recipients   = N''' + REPLACE(@OperatorEmail, N'''', N'''''') + N''',
        @subject      = N''kArchiveManager: operational health ERROR'',
        @body         = @body;
END;';

EXEC msdb.dbo.sp_add_job @job_name = @alertJob, @enabled = 1,
    @description = N'Emails when arch.v_OperationalHealth reports Severity=ERROR (FAILED runs, ROW_COUNT_MISMATCH, ROW_AUDIT_MISSING).';
EXEC msdb.dbo.sp_add_jobstep @job_name = @alertJob, @step_name = N'CHECK HEALTH',
    @subsystem = N'TSQL', @database_name = N'msdb', @command = @stepCmd, @on_success_action = 1, @on_fail_action = 2;
EXEC msdb.dbo.sp_add_jobschedule @job_name = @alertJob, @name = N'Every N minutes',
    @freq_type = 4, @freq_interval = 1, @freq_subday_type = 4, @freq_subday_interval = @AlertEveryMin, @active_start_time = 0;
EXEC msdb.dbo.sp_add_jobserver @job_name = @alertJob;

PRINT '047_operational_alerting deployed (operator + job failure-email + HEALTH ALERT job). Mail delivery requires a valid SMTP profile.';
