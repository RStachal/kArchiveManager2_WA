USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Validated version (P1.3): fail fast with THROW 50001/50002/50003 when the
-- prepared infrastructure is missing or the profile is invalid. Mirrors the
-- canonical definition deployed by v2/025_p1_3_block_legacy_procedures.sql.
CREATE OR ALTER PROCEDURE [arch].[usp_RunProfile_Prepared]
    @RunProfileCode sysname,
    -- BOTH (default/back-compat) | PREP (prepare ANCHOR candidates only) | RUN (run prepared + TIMESTAMP).
    -- Lets the separate PREP and RUN Agent jobs share one run profile.
    @Phase varchar(4) = 'BOTH'
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
        @PausedCooldownSeconds = @PausedCooldownSeconds,
        @Phase = @Phase;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_RunScheduledProfiles_Prepared]
    @RunProfileCode sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'arch.RunProfile', N'U') IS NULL
    BEGIN
        RAISERROR(N'arch.RunProfile does not exist. Run v2/010_universal_archive_core.sql first.', 16, 1);
        RETURN;
    END;

    DECLARE @profile sysname;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT RunProfileCode
    FROM arch.RunProfile
    WHERE IsEnabled = 1
      AND RunOnSchedule = 1
      AND (@RunProfileCode IS NULL OR RunProfileCode = @RunProfileCode)
    ORDER BY RunOrder, RunProfileCode;

    OPEN c;
    FETCH NEXT FROM c INTO @profile;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC arch.usp_RunProfile_Prepared @RunProfileCode = @profile;
        FETCH NEXT FROM c INTO @profile;
    END;

    CLOSE c;
    DEALLOCATE c;
END
GO
