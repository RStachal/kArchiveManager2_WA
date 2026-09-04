-- ============================================================================
-- 02 - CREATE THE CONTROL AND ARCHIVE DATABASES (explicitly sized)
-- ============================================================================
-- The shipped Databases\create_kArchiveManager*.sql are bare
--   IF DB_ID(...) IS NULL CREATE DATABASE [...];
-- with no FILENAME, no SIZE, no FILEGROWTH and no COLLATE, so both databases
-- inherit the instance defaults and start at model's size (typically 8 MB with
-- 64 MB autogrowth) in the default data directory. For a database that is the
-- ONLY surviving copy of irreversibly deleted WMS rows that is worth deciding
-- deliberately, so this script pre-creates them.
--
-- Both shipped scripts are IF-guarded, so running them afterwards (the clean
-- bundle does, in its Phase 0) becomes a no-op except for the compatibility-level
-- pin and the FULL-recovery ALTER - which is exactly what we want.
--
-- COLLATION: no COLLATE clause here either, on purpose - both databases inherit
-- the instance collation. Do NOT force a different one:
--   * archive TABLES get their collation per column from the SOURCE columns
--     (arch.usp_EnsureArchiveTableLikeSource emits an explicit
--      "COLLATE <source column collation>"), so archive data always matches the
--     source regardless of the archive database's own collation, and
--   * the runner re-collates its #Keys temp table to the source collation before
--     joining (015 line 344), so a source/admin mismatch is already handled.
--   Verified end-to-end on a Czech_CS_AS instance.
--
-- EDIT THE PATHS AND SIZES BELOW before running on a real server.
-- ============================================================================
:setvar AdminDb   "kArchiveManagerAdmin"
:setvar ArchiveDb "kArchiveManagerBackups"
-- Leave DataPath/LogPath empty to use the instance defaults.
:setvar DataPath ""
:setvar LogPath  ""
:setvar AdminDataMB   "512"
:setvar AdminLogMB    "256"
:setvar ArchiveDataMB "4096"
:setvar ArchiveLogMB  "2048"

:on error exit

USE [master];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @DataPath nvarchar(260) = NULLIF(N'$(DataPath)', N'');
DECLARE @LogPath  nvarchar(260) = NULLIF(N'$(LogPath)',  N'');

IF @DataPath IS NULL SET @DataPath = CONVERT(nvarchar(260), SERVERPROPERTY('InstanceDefaultDataPath'));
IF @LogPath  IS NULL SET @LogPath  = CONVERT(nvarchar(260), SERVERPROPERTY('InstanceDefaultLogPath'));
IF RIGHT(@DataPath, 1) <> N'\' SET @DataPath = @DataPath + N'\';
IF RIGHT(@LogPath,  1) <> N'\' SET @LogPath  = @LogPath  + N'\';

PRINT 'Data path: ' + @DataPath;
PRINT 'Log path : ' + @LogPath;

DECLARE @sql nvarchar(max);

-------------------------------------------------------------------------------
-- Control database
-------------------------------------------------------------------------------
IF DB_ID(N'$(AdminDb)') IS NULL
BEGIN
    SET @sql = N'CREATE DATABASE ' + QUOTENAME(N'$(AdminDb)') + N'
        ON PRIMARY
        (
            NAME = ' + QUOTENAME(N'$(AdminDb)', N'''') + N',
            FILENAME = N''' + @DataPath + N'$(AdminDb).mdf'',
            SIZE = $(AdminDataMB)MB,
            FILEGROWTH = 256MB
        )
        LOG ON
        (
            NAME = ' + QUOTENAME(N'$(AdminDb)_log', N'''') + N',
            FILENAME = N''' + @LogPath + N'$(AdminDb)_log.ldf'',
            SIZE = $(AdminLogMB)MB,
            FILEGROWTH = 128MB
        );';
    PRINT 'Creating $(AdminDb) ...';
    EXEC sys.sp_executesql @sql;
END
ELSE
    PRINT '$(AdminDb) already exists - left as is.';

-- STRING_SPLIT (used by the config/validation/least-privilege scripts) needs
-- compat >= 130; pin a safe floor. A fresh DB on 2019/2022 already exceeds it.
IF (SELECT compatibility_level FROM sys.databases WHERE name = N'$(AdminDb)') < 150
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(N'$(AdminDb)') + N' SET COMPATIBILITY_LEVEL = 150;';
    EXEC sys.sp_executesql @sql;
END;

-- The control database holds configuration and run history, not the archive of
-- record, so SIMPLE recovery is enough and keeps its log from growing unattended.
IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N'$(AdminDb)') <> N'SIMPLE'
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(N'$(AdminDb)') + N' SET RECOVERY SIMPLE;';
    EXEC sys.sp_executesql @sql;
END;

-------------------------------------------------------------------------------
-- Archive database
-------------------------------------------------------------------------------
IF DB_ID(N'$(ArchiveDb)') IS NULL
BEGIN
    SET @sql = N'CREATE DATABASE ' + QUOTENAME(N'$(ArchiveDb)') + N'
        ON PRIMARY
        (
            NAME = ' + QUOTENAME(N'$(ArchiveDb)', N'''') + N',
            FILENAME = N''' + @DataPath + N'$(ArchiveDb).mdf'',
            SIZE = $(ArchiveDataMB)MB,
            FILEGROWTH = 1024MB
        )
        LOG ON
        (
            NAME = ' + QUOTENAME(N'$(ArchiveDb)_log', N'''') + N',
            FILENAME = N''' + @LogPath + N'$(ArchiveDb)_log.ldf'',
            SIZE = $(ArchiveLogMB)MB,
            FILEGROWTH = 512MB
        );';
    PRINT 'Creating $(ArchiveDb) ...';
    EXEC sys.sp_executesql @sql;
END
ELSE
    PRINT '$(ArchiveDb) already exists - left as is.';

-- MUST be FULL: this database is the system of record for rows deleted
-- irreversibly from the source, and the hourly LOG-backup job silently no-ops
-- under SIMPLE.
IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N'$(ArchiveDb)') <> N'FULL'
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(N'$(ArchiveDb)') + N' SET RECOVERY FULL;';
    EXEC sys.sp_executesql @sql;
END;
GO

SELECT
    d.name,
    d.state_desc,
    d.collation_name,
    d.compatibility_level,
    d.recovery_model_desc,
    DataFileMB = (SELECT CONVERT(decimal(18,0), SUM(mf.size) * 8.0 / 1024) FROM sys.master_files mf WHERE mf.database_id = d.database_id AND mf.type_desc = N'ROWS'),
    LogFileMB  = (SELECT CONVERT(decimal(18,0), SUM(mf.size) * 8.0 / 1024) FROM sys.master_files mf WHERE mf.database_id = d.database_id AND mf.type_desc = N'LOG')
FROM sys.databases d
WHERE d.name IN (N'$(AdminDb)', N'$(ArchiveDb)')
ORDER BY d.name;
GO

PRINT '02_databases: done. Next: run the core deploy bundle (see README step 3).';
GO
