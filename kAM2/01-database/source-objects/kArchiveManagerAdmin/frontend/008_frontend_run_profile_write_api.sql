USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveRunProfile]
    @RunProfileId int = NULL OUTPUT,
    @RunProfileCode sysname,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @Description nvarchar(400) = NULL,
    @IsEnabled bit = 1,
    @RunOnSchedule bit = 0,
    @RunOrder int = 100,
    @ProcessCodeFilter sysname = NULL,
    @SourceDbFilter sysname = NULL,
    @ArchiveDbFilter sysname = NULL,
    @RunWindowMinutes int = 55,
    @DryRun bit = 0,
    @MaxCandidates int = NULL,
    @PausedCooldownSeconds int = 60,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @RunProfileCode = NULLIF(LTRIM(RTRIM(@RunProfileCode)), N'');
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @ProcessCodeFilter = NULLIF(LTRIM(RTRIM(@ProcessCodeFilter)), N'');
    SET @SourceDbFilter = NULLIF(LTRIM(RTRIM(@SourceDbFilter)), N'');
    SET @ArchiveDbFilter = NULLIF(LTRIM(RTRIM(@ArchiveDbFilter)), N'');

    IF @RunProfileCode IS NULL
        THROW 57100, 'RunProfileCode is required.', 1;

    IF @RequestedBy IS NULL
        THROW 57101, 'RequestedBy is required.', 1;

    IF @IsEnabled IS NULL
        THROW 57102, 'IsEnabled is required.', 1;

    IF @RunOnSchedule IS NULL
        THROW 57103, 'RunOnSchedule is required.', 1;

    IF @RunOrder IS NULL
        THROW 57104, 'RunOrder is required.', 1;

    IF @RunWindowMinutes IS NULL OR @RunWindowMinutes <= 0
        THROW 57105, 'RunWindowMinutes must be greater than 0.', 1;

    IF @DryRun IS NULL
        THROW 57106, 'DryRun is required.', 1;

    IF (@MaxCandidates IS NOT NULL AND @MaxCandidates <= 0)
       OR @PausedCooldownSeconds IS NULL
       OR @PausedCooldownSeconds < 0
        THROW 57107, 'Run profile numeric limits are invalid.', 1;

    IF @ProcessCodeFilter IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM arch.Process WHERE ProcessCode = @ProcessCodeFilter)
        THROW 57108, 'ProcessCodeFilter does not exist in arch.Process.', 1;

    IF (@SourceDbFilter IS NOT NULL OR @ArchiveDbFilter IS NOT NULL)
       AND NOT EXISTS
       (
           SELECT 1
           FROM arch.ProcessDatabase pd
           JOIN arch.Process p
             ON p.ProcessId = pd.ProcessId
           WHERE (@ProcessCodeFilter IS NULL OR p.ProcessCode = @ProcessCodeFilter)
             AND (@SourceDbFilter IS NULL OR pd.SourceDb = @SourceDbFilter)
             AND (@ArchiveDbFilter IS NULL OR pd.ArchiveDb = @ArchiveDbFilter)
       )
        THROW 57109, 'SourceDbFilter and ArchiveDbFilter do not match any configured process database mapping.', 1;

    DECLARE
        @Operation nvarchar(20),
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldRunProfileCode sysname,
        @OldDescription nvarchar(400),
        @OldIsEnabled bit,
        @OldRunOnSchedule bit,
        @OldRunOrder int,
        @OldProcessCodeFilter sysname,
        @OldSourceDbFilter sysname,
        @OldArchiveDbFilter sysname,
        @OldRunWindowMinutes int,
        @OldDryRun bit,
        @OldMaxCandidates int,
        @OldPausedCooldownSeconds int;

    DECLARE @Audit table
    (
        FieldName sysname NOT NULL,
        OldValue nvarchar(max) NULL,
        NewValue nvarchar(max) NULL,
        IsAdvancedField bit NOT NULL
    );

    BEGIN TRAN;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            @Now,
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 57110, 'ConfigChangeSetId does not exist.', 1;

    IF @RunProfileId IS NULL
    BEGIN
        SELECT @RunProfileId = RunProfileId
        FROM arch.RunProfile
        WHERE RunProfileCode = @RunProfileCode;
    END;

    IF @RunProfileId IS NOT NULL
    BEGIN
        SELECT
            @OldRunProfileCode = RunProfileCode,
            @OldDescription = Description,
            @OldIsEnabled = IsEnabled,
            @OldRunOnSchedule = RunOnSchedule,
            @OldRunOrder = RunOrder,
            @OldProcessCodeFilter = ProcessCodeFilter,
            @OldSourceDbFilter = SourceDbFilter,
            @OldArchiveDbFilter = ArchiveDbFilter,
            @OldRunWindowMinutes = RunWindowMinutes,
            @OldDryRun = DryRun,
            @OldMaxCandidates = MaxCandidates,
            @OldPausedCooldownSeconds = PausedCooldownSeconds
        FROM arch.RunProfile
        WHERE RunProfileId = @RunProfileId;

        IF @@ROWCOUNT = 0
            THROW 57111, 'RunProfileId does not exist.', 1;

        IF @OldRunProfileCode <> @RunProfileCode
           AND EXISTS (SELECT 1 FROM arch.RunProfile WHERE RunProfileCode = @RunProfileCode AND RunProfileId <> @RunProfileId)
            THROW 57112, 'RunProfileCode already exists.', 1;
    END;

    SET @Operation = CASE WHEN @RunProfileId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @RunProfileCode;

    IF @RunProfileId IS NULL
    BEGIN
        INSERT INTO arch.RunProfile
        (
            RunProfileCode,
            Description,
            IsEnabled,
            RunOnSchedule,
            RunOrder,
            ProcessCodeFilter,
            SourceDbFilter,
            ArchiveDbFilter,
            RunWindowMinutes,
            DryRun,
            MaxCandidates,
            PausedCooldownSeconds,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @RunProfileCode,
            @Description,
            @IsEnabled,
            @RunOnSchedule,
            @RunOrder,
            @ProcessCodeFilter,
            @SourceDbFilter,
            @ArchiveDbFilter,
            @RunWindowMinutes,
            @DryRun,
            @MaxCandidates,
            @PausedCooldownSeconds,
            @Now,
            @Now
        );

        SET @RunProfileId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.RunProfile
        SET
            RunProfileCode = @RunProfileCode,
            Description = @Description,
            IsEnabled = @IsEnabled,
            RunOnSchedule = @RunOnSchedule,
            RunOrder = @RunOrder,
            ProcessCodeFilter = @ProcessCodeFilter,
            SourceDbFilter = @SourceDbFilter,
            ArchiveDbFilter = @ArchiveDbFilter,
            RunWindowMinutes = @RunWindowMinutes,
            DryRun = @DryRun,
            MaxCandidates = @MaxCandidates,
            PausedCooldownSeconds = @PausedCooldownSeconds,
            ModifiedAt = @Now
        WHERE RunProfileId = @RunProfileId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'RunProfileCode', @OldRunProfileCode, @RunProfileCode, 0),
        (N'Description', @OldDescription, @Description, 0),
        (N'IsEnabled', CONVERT(nvarchar(30), @OldIsEnabled), CONVERT(nvarchar(30), @IsEnabled), 0),
        (N'RunOnSchedule', CONVERT(nvarchar(30), @OldRunOnSchedule), CONVERT(nvarchar(30), @RunOnSchedule), 0),
        (N'RunOrder', CONVERT(nvarchar(30), @OldRunOrder), CONVERT(nvarchar(30), @RunOrder), 0),
        (N'ProcessCodeFilter', @OldProcessCodeFilter, @ProcessCodeFilter, 0),
        (N'SourceDbFilter', @OldSourceDbFilter, @SourceDbFilter, 0),
        (N'ArchiveDbFilter', @OldArchiveDbFilter, @ArchiveDbFilter, 0),
        (N'RunWindowMinutes', CONVERT(nvarchar(30), @OldRunWindowMinutes), CONVERT(nvarchar(30), @RunWindowMinutes), 0),
        (N'DryRun', CONVERT(nvarchar(30), @OldDryRun), CONVERT(nvarchar(30), @DryRun), 0),
        (N'MaxCandidates', CONVERT(nvarchar(30), @OldMaxCandidates), CONVERT(nvarchar(30), @MaxCandidates), 0),
        (N'PausedCooldownSeconds', CONVERT(nvarchar(30), @OldPausedCooldownSeconds), CONVERT(nvarchar(30), @PausedCooldownSeconds), 0);

    DELETE FROM @Audit
    WHERE (OldValue = NewValue) OR (OldValue IS NULL AND NewValue IS NULL);

    IF EXISTS (SELECT 1 FROM @Audit)
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'RunProfile',
            @EntityKey,
            @Operation,
            @RunProfileId,
            @Now
        );

        SET @ConfigChangeItemId = CONVERT(bigint, SCOPE_IDENTITY());

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        SELECT
            @ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        FROM @Audit
        ORDER BY FieldName;
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Run profile saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        rp.RunProfileId,
        rp.RunProfileCode,
        rp.Description,
        rp.IsEnabled,
        rp.RunOnSchedule,
        rp.RunOrder,
        rp.ProcessCodeFilter,
        rp.SourceDbFilter,
        rp.ArchiveDbFilter,
        rp.RunWindowMinutes,
        rp.DryRun,
        rp.MaxCandidates,
        rp.PausedCooldownSeconds,
        rp.ModifiedAt
    FROM arch.RunProfile rp
    WHERE rp.RunProfileId = @RunProfileId;
END
GO
