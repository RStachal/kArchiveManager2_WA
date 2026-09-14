/**
 * kArchiveManager 2.0 - P1.3 Runtime Path Standardization
 * Block legacy v1.0 procedures to prevent accidental operator use
 * Date: 2026-05-28
 */

USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- STEP 1: Update arch.usp_RunProfile_Prepared to validate infrastructure
CREATE OR ALTER PROCEDURE [arch].[usp_RunProfile_Prepared]
    @RunProfileCode sysname
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'arch.RunProfile', N'U') IS NULL
    BEGIN
        THROW 50001, 'arch.RunProfile table does not exist', 1;
    END;

    IF OBJECT_ID(N'arch.usp_RunConfiguredProcesses_Prepared', N'P') IS NULL
    BEGIN
        THROW 50001, 'arch.usp_RunConfiguredProcesses_Prepared procedure not found', 1;
    END;

    DECLARE @ProcessCode sysname,
            @SourceDb sysname,
            @ArchiveDb sysname,
            @RunWindowMinutes int,
            @DryRun bit,
            @MaxCandidates int,
            @PausedCooldownSeconds int,
            @StopAtUtc datetime2(0);

    SELECT @ProcessCode = NULLIF(LTRIM(RTRIM(ProcessCodeFilter)), N''),
           @SourceDb = NULLIF(LTRIM(RTRIM(SourceDbFilter)), N''),
           @ArchiveDb = NULLIF(LTRIM(RTRIM(ArchiveDbFilter)), N''),
           @RunWindowMinutes = RunWindowMinutes,
           @DryRun = DryRun,
           @MaxCandidates = MaxCandidates,
           @PausedCooldownSeconds = PausedCooldownSeconds
    FROM arch.RunProfile
    WHERE RunProfileCode = @RunProfileCode
      AND IsEnabled = 1;

    IF @RunWindowMinutes IS NULL
    BEGIN
        THROW 50002, 'Run profile not found or disabled', 1;
    END;

    IF @RunWindowMinutes <= 0 OR @PausedCooldownSeconds < 0 OR (@MaxCandidates IS NOT NULL AND @MaxCandidates <= 0)
    BEGIN
        THROW 50003, 'Run profile has invalid runtime limits', 1;
    END;

    SET @StopAtUtc = DATEADD(MINUTE, @RunWindowMinutes, CONVERT(datetime2(0), SYSUTCDATETIME()));

    EXEC arch.usp_RunConfiguredProcesses_Prepared
        @ProcessCode = @ProcessCode,
        @SourceDb = @SourceDb,
        @ArchiveDb = @ArchiveDb,
        @StopAtUtc = @StopAtUtc,
        @DryRun = @DryRun,
        @MaxCandidates = @MaxCandidates,
        @PausedCooldownSeconds = @PausedCooldownSeconds;
END
GO

-- STEP 2: Block arch.usp_RunProcess (v1.0 legacy)
CREATE OR ALTER PROCEDURE [arch].[usp_RunProcess]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @AsOfUtc datetime2(0) = NULL,
    @StopAtUtc datetime2(0) = NULL,
    @DryRun bit = NULL
AS
BEGIN
    THROW 50004, 'LEGACY BLOCKED: arch.usp_RunProcess is v1.0 only. Use arch.usp_RunProfile_Prepared', 1;
END
GO

-- STEP 3: Block arch.usp_RunProcess_TimestampKeyset (v1.0 legacy variant)
CREATE OR ALTER PROCEDURE [arch].[usp_RunProcess_TimestampKeyset]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @AsOfUtc datetime2(0) = NULL,
    @StopAtUtc datetime2(0) = NULL,
    @DryRun bit = NULL
AS
BEGIN
    THROW 50005, 'LEGACY BLOCKED: arch.usp_RunProcess_TimestampKeyset is v1.0 only. Use arch.usp_RunProfile_Prepared', 1;
END
GO

-- STEP 4: Block arch.usp_RunProcess_RF_LOG2 (v1.0 legacy variant)
CREATE OR ALTER PROCEDURE [arch].[usp_RunProcess_RF_LOG2]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @AsOfUtc datetime2(0) = NULL,
    @StopAtUtc datetime2(0) = NULL,
    @DryRun bit = NULL
AS
BEGIN
    THROW 50006, 'LEGACY BLOCKED: arch.usp_RunProcess_RF_LOG2 is v1.0 only. Use arch.usp_RunProfile_Prepared', 1;
END
GO

PRINT 'P1.3 script completed. Legacy procedures now return errors 50004-50006'
