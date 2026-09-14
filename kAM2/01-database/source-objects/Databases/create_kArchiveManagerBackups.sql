USE [master]
GO

IF DB_ID(N'kArchiveManagerBackups') IS NULL
    CREATE DATABASE [kArchiveManagerBackups];
GO

-- The archive DB is the system-of-record for irreversibly deleted rows, so it MUST be in
-- FULL recovery for the hourly LOG-backup job (deploy/v2/048_archive_db_backup.sql) to be
-- effective — that job silently no-ops under SIMPLE. Set it explicitly instead of inheriting
-- whatever recovery model the server's [model] database happens to have.
IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N'kArchiveManagerBackups') <> N'FULL'
    ALTER DATABASE [kArchiveManagerBackups] SET RECOVERY FULL;
GO
