USE [master];
GO
SET NOCOUNT ON;
/* ============================================================================
   051 — Admin Console READ-ONLY access to the SOURCE + ARCHIVE databases
   ----------------------------------------------------------------------------
   The dashboard's movement-summary procedures (arch.usp_Frontend_GetProcessMovementSummary,
   GetTableMovementCounts, …) count rows in the configured SOURCE databases and the ARCHIVE
   database via CROSS-DATABASE queries. The Admin Console app-pool login is a member of the
   karch_* roles in kArchiveManagerAdmin only, so without a read-only user in those other DBs
   the API returns 503 "Database call failed" — a masked Msg 916 ("server principal is not able
   to access the database …").

   This grants db_datareader (READ-ONLY) to the app-pool login in each listed DB. It does NOT
   grant delete/write: the real archive+delete runs under the SQL Agent job identity, not the
   app pool. (Tightening the runner identity itself is tracked separately as T-33.)

   PARAMETERIZED — fill in @ConsoleLogin and @DbsCsv, then run (classic SSMS, no SQLCMD mode).
   Idempotent + re-runnable. Skips DBs that don't exist.
   ============================================================================ */
DECLARE @ConsoleLogin sysname     = N'IIS APPPOOL\kAM Admin Console';   -- CHANGE-ME if the app pool name differs
DECLARE @DbsCsv       nvarchar(4000) = N'CHANGE-ME_SourceDb1,CHANGE-ME_SourceDb2,kArchiveManagerBackups';
                                       -- ^ comma-separated: every enabled SOURCE database + the archive database

IF SUSER_SID(@ConsoleLogin) IS NULL
BEGIN
    RAISERROR(N'Login %s does not exist on this server — create the IIS app-pool login first.', 16, 1, @ConsoleLogin);
    RETURN;
END;
IF @DbsCsv LIKE N'%CHANGE-ME%'
BEGIN
    RAISERROR(N'Set @DbsCsv to your real source databases (+ archive DB) before running 051.', 16, 1);
    RETURN;
END;

DECLARE @db sysname, @sql nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DbsCsv, N',') WHERE LTRIM(RTRIM(value)) <> N'';
OPEN c; FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF DB_ID(@db) IS NULL
        PRINT N'SKIP (database not found): ' + @db;
    ELSE
    BEGIN
        SET @sql = N'USE ' + QUOTENAME(@db) + N';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE sid = SUSER_SID(@l))
    CREATE USER ' + QUOTENAME(@ConsoleLogin) + N' FOR LOGIN ' + QUOTENAME(@ConsoleLogin) + N';
ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@ConsoleLogin) + N';';
        EXEC sys.sp_executesql @sql, N'@l sysname', @l = @ConsoleLogin;
        PRINT N'granted db_datareader to ' + @ConsoleLogin + N' in ' + @db;
    END;
    FETCH NEXT FROM c INTO @db;
END;
CLOSE c; DEALLOCATE c;
GO
PRINT N'051_grant_console_read_source_dbs complete.';
GO
