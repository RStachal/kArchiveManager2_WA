USE [master]
GO

IF DB_ID(N'kArchiveManagerAdmin') IS NULL
    CREATE DATABASE [kArchiveManagerAdmin];
GO

-- STRING_SPLIT (used by the config/validation/least-privilege scripts) requires DB compat >= 130.
-- A fresh DB inherits model's level; on an instance upgraded from <2016 model may still be 120-.
-- Pin a safe floor (150 = SQL 2019; valid on SQL 2019/2022). Idempotent.
IF (SELECT compatibility_level FROM sys.databases WHERE name = N'kArchiveManagerAdmin') < 150
    ALTER DATABASE [kArchiveManagerAdmin] SET COMPATIBILITY_LEVEL = 150;
GO
