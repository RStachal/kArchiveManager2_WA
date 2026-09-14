USE [kArchiveManagerAdmin]
GO

IF SCHEMA_ID(N'arch') IS NULL
    EXEC(N'CREATE SCHEMA [arch] AUTHORIZATION [dbo]');
GO
