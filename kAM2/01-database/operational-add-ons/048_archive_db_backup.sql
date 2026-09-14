/* ============================================================================
   048 — Archive database backup (audit task T-16)
   ============================================================================
   PROBLEM: kArchiveManagerBackups IS the backup-of-record — Mode=1 archive+DELETE moves rows there
   and the source rows are gone irreversibly. It is in FULL recovery (verified) yet the runbook only
   schedules SOURCE-db backups; if the archive DB is lost/corrupted between runs, every previously
   deleted row is unrecoverable and usp_RestoreFromArchive has nothing to restore from. A FULL-recovery
   DB with no LOG backups also grows its log without bound.

   FIX (this script): turnkey FULL (daily) + LOG (hourly) backup jobs for the archive DB, with
   RESTORE VERIFYONLY + CHECKSUM and a retention cleanup. PREFER integrating the archive DB into the
   customer's existing maintenance solution (e.g. Ola Hallengren / maintenance plans) if one exists —
   this is a self-contained fallback so the archive is never left unprotected.

   ENVIRONMENT-SPECIFIC — fill in @BackupRoot + retention before running. Idempotent. Operates in msdb.
   ============================================================================ */
USE [msdb];
SET NOCOUNT ON;

-- ============================ FILL THESE IN ============================
DECLARE @ArchiveDb        sysname       = N'kArchiveManagerBackups';
DECLARE @BackupRoot       nvarchar(512) = N'CHANGE-ME:\Backups\kArchiveManagerBackups';  -- <<< existing folder, Agent service account must have write
DECLARE @RetentionDaysFull int          = 35;     -- keep FULL backups N days
DECLARE @RetentionDaysLog  int          = 8;      -- keep LOG backups N days
DECLARE @FullDailyTime     int          = 13000;  -- HHMMSS, e.g. 013000 = 01:30
DECLARE @LogEveryMinutes   int          = 60;
-- ======================================================================

IF @BackupRoot LIKE N'CHANGE-ME%'
BEGIN
    RAISERROR('048 BLOCKED: set @BackupRoot to a real folder (Agent service account needs write access) before running.', 16, 1);
    RETURN;
END;

DECLARE @rootLit nvarchar(512) = REPLACE(@BackupRoot, N'''', N'''''');
DECLARE @db      nvarchar(256) = REPLACE(@ArchiveDb,  N'''', N'''''');

/* ---- FULL backup job (daily) ---- */
DECLARE @fullJob sysname = N'kArchiveManager - BACKUP ARCHIVE DB (FULL)';
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @fullJob)
    EXEC msdb.dbo.sp_delete_job @job_name = @fullJob, @delete_unused_schedule = 1;

DECLARE @fullCmd nvarchar(max) = N'
SET NOCOUNT ON; SET XACT_ABORT ON;
DECLARE @f nvarchar(700) = N''' + @rootLit + N'\' + @db + N'_FULL_'' + FORMAT(SYSDATETIME(), ''yyyyMMdd_HHmmss'') + N''.bak'';
BACKUP DATABASE [' + @db + N'] TO DISK = @f WITH COMPRESSION, CHECKSUM, INIT, STATS = 10;
RESTORE VERIFYONLY FROM DISK = @f WITH CHECKSUM;
DECLARE @cut datetime = DATEADD(DAY, -' + CONVERT(nvarchar(10), @RetentionDaysFull) + N', GETDATE());
EXEC master.dbo.xp_delete_file 0, N''' + @rootLit + N''', N''bak'', @cut, 0;';

EXEC msdb.dbo.sp_add_job @job_name = @fullJob, @enabled = 1,
    @description = N'FULL backup of the kArchiveManager archive database (system-of-record for deleted rows) with verify + retention.';
EXEC msdb.dbo.sp_add_jobstep @job_name = @fullJob, @step_name = N'FULL BACKUP',
    @subsystem = N'TSQL', @database_name = N'master', @command = @fullCmd, @on_fail_action = 2;
EXEC msdb.dbo.sp_add_jobschedule @job_name = @fullJob, @name = N'Daily',
    @freq_type = 4, @freq_interval = 1, @active_start_time = @FullDailyTime;
EXEC msdb.dbo.sp_add_jobserver @job_name = @fullJob;

/* ---- LOG backup job (hourly; required because the archive DB is in FULL recovery) ---- */
DECLARE @logJob sysname = N'kArchiveManager - BACKUP ARCHIVE DB (LOG)';
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @logJob)
    EXEC msdb.dbo.sp_delete_job @job_name = @logJob, @delete_unused_schedule = 1;

DECLARE @logCmd nvarchar(max) = N'
SET NOCOUNT ON; SET XACT_ABORT ON;
IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N''' + @db + N''') = N''FULL''
BEGIN
    DECLARE @f nvarchar(700) = N''' + @rootLit + N'\' + @db + N'_LOG_'' + FORMAT(SYSDATETIME(), ''yyyyMMdd_HHmmss'') + N''.trn'';
    BACKUP LOG [' + @db + N'] TO DISK = @f WITH COMPRESSION, CHECKSUM;
    DECLARE @cut datetime = DATEADD(DAY, -' + CONVERT(nvarchar(10), @RetentionDaysLog) + N', GETDATE());
    EXEC master.dbo.xp_delete_file 0, N''' + @rootLit + N''', N''trn'', @cut, 0;
END;';

EXEC msdb.dbo.sp_add_job @job_name = @logJob, @enabled = 1,
    @description = N'Transaction-log backup of the kArchiveManager archive database (FULL recovery) with retention.';
EXEC msdb.dbo.sp_add_jobstep @job_name = @logJob, @step_name = N'LOG BACKUP',
    @subsystem = N'TSQL', @database_name = N'master', @command = @logCmd, @on_fail_action = 2;
EXEC msdb.dbo.sp_add_jobschedule @job_name = @logJob, @name = N'Hourly',
    @freq_type = 4, @freq_interval = 1, @freq_subday_type = 4, @freq_subday_interval = @LogEveryMinutes, @active_start_time = 0;
EXEC msdb.dbo.sp_add_jobserver @job_name = @logJob;

PRINT '048_archive_db_backup deployed (FULL daily + LOG hourly jobs for the archive DB). Run a RESTORE rehearsal before go-live.';
