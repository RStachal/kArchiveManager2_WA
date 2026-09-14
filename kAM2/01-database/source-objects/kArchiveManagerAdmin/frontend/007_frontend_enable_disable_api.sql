USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SetProcessEnabled]
    @ProcessCode sysname,
    @IsEnabled bit,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ProcessCode = NULLIF(LTRIM(RTRIM(@ProcessCode)), N'');
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;

    IF @ProcessCode IS NULL
        THROW 56900, 'ProcessCode is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56901, 'IsEnabled is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56902, 'RequestedBy is required.', 1;

    DECLARE
        @ProcessId int,
        @OldIsEnabled bit,
        @WasChanged bit;

    BEGIN TRAN;

    SELECT
        @ProcessId = ProcessId,
        @OldIsEnabled = IsEnabled
    FROM arch.Process
    WHERE ProcessCode = @ProcessCode;

    IF @ProcessId IS NULL
        THROW 56903, 'ProcessCode does not exist.', 1;

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
            SYSUTCDATETIME(),
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56904, 'ConfigChangeSetId does not exist.', 1;

    SET @WasChanged = CONVERT(bit, CASE WHEN @OldIsEnabled <> @IsEnabled THEN 1 ELSE 0 END);

    IF @WasChanged = 1
    BEGIN
        UPDATE arch.Process
        SET
            IsEnabled = @IsEnabled,
            ModifiedAt = SYSUTCDATETIME()
        WHERE ProcessId = @ProcessId;
    END;

    IF @WasChanged = 1
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
            N'Process',
            @ProcessCode,
            N'UPDATE',
            @ProcessId,
            SYSUTCDATETIME()
        );

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        VALUES
        (
            CONVERT(bigint, SCOPE_IDENTITY()),
            N'IsEnabled',
            CONVERT(nvarchar(30), @OldIsEnabled),
            CONVERT(nvarchar(30), @IsEnabled),
            0
        );
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Process enabled state updated by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = SYSUTCDATETIME()
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        EntityType = N'Process',
        EntityId = @ProcessId,
        EntityKey = @ProcessCode,
        IsEnabled = @IsEnabled,
        WasChanged = @WasChanged;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SetProcessDatabaseEnabled]
    @ProcessDatabaseId int = NULL,
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @IsEnabled bit,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ProcessCode = NULLIF(LTRIM(RTRIM(@ProcessCode)), N'');
    SET @SourceDb = NULLIF(LTRIM(RTRIM(@SourceDb)), N'');
    SET @ArchiveDb = NULLIF(LTRIM(RTRIM(@ArchiveDb)), N'');
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;

    IF @ProcessDatabaseId IS NULL
       AND (@ProcessCode IS NULL OR @SourceDb IS NULL OR @ArchiveDb IS NULL)
        THROW 56920, 'ProcessDatabaseId or ProcessCode + SourceDb + ArchiveDb is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56921, 'IsEnabled is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56922, 'RequestedBy is required.', 1;

    DECLARE
        @ResolvedProcessDatabaseId int,
        @ResolvedProcessCode sysname,
        @ResolvedSourceDb sysname,
        @ResolvedArchiveDb sysname,
        @OldIsEnabled bit,
        @EntityKey nvarchar(400),
        @WasChanged bit;

    BEGIN TRAN;

    SELECT
        @ResolvedProcessDatabaseId = pd.ProcessDatabaseId,
        @ResolvedProcessCode = p.ProcessCode,
        @ResolvedSourceDb = pd.SourceDb,
        @ResolvedArchiveDb = pd.ArchiveDb,
        @OldIsEnabled = pd.IsEnabled
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    WHERE (@ProcessDatabaseId IS NOT NULL AND pd.ProcessDatabaseId = @ProcessDatabaseId)
       OR (@ProcessDatabaseId IS NULL AND p.ProcessCode = @ProcessCode AND pd.SourceDb = @SourceDb AND pd.ArchiveDb = @ArchiveDb);

    IF @ResolvedProcessDatabaseId IS NULL
        THROW 56923, 'Process database mapping does not exist.', 1;

    SET @EntityKey = @ResolvedProcessCode + N'|' + @ResolvedSourceDb + N'|' + @ResolvedArchiveDb;

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
            SYSUTCDATETIME(),
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56924, 'ConfigChangeSetId does not exist.', 1;

    SET @WasChanged = CONVERT(bit, CASE WHEN @OldIsEnabled <> @IsEnabled THEN 1 ELSE 0 END);

    IF @WasChanged = 1
    BEGIN
        UPDATE arch.ProcessDatabase
        SET
            IsEnabled = @IsEnabled,
            ModifiedAt = SYSUTCDATETIME()
        WHERE ProcessDatabaseId = @ResolvedProcessDatabaseId;
    END;

    IF @WasChanged = 1
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
            N'ProcessDatabase',
            @EntityKey,
            N'UPDATE',
            @ResolvedProcessDatabaseId,
            SYSUTCDATETIME()
        );

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        VALUES
        (
            CONVERT(bigint, SCOPE_IDENTITY()),
            N'IsEnabled',
            CONVERT(nvarchar(30), @OldIsEnabled),
            CONVERT(nvarchar(30), @IsEnabled),
            0
        );
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Process database enabled state updated by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = SYSUTCDATETIME()
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        EntityType = N'ProcessDatabase',
        EntityId = @ResolvedProcessDatabaseId,
        EntityKey = @EntityKey,
        ProcessCode = @ResolvedProcessCode,
        SourceDb = @ResolvedSourceDb,
        ArchiveDb = @ResolvedArchiveDb,
        IsEnabled = @IsEnabled,
        WasChanged = @WasChanged;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SetObjectOverrideEnabled]
    @ProcessDatabaseId int,
    @ObjectSpecId int,
    @IsEnabled bit,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;

    IF @ProcessDatabaseId IS NULL
        THROW 56940, 'ProcessDatabaseId is required.', 1;

    IF @ObjectSpecId IS NULL
        THROW 56941, 'ObjectSpecId is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56942, 'IsEnabled is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56943, 'RequestedBy is required.', 1;

    DECLARE
        @ProcessId int,
        @ObjectProcessId int,
        @ProcessCode sysname,
        @SourceDb sysname,
        @ArchiveDb sysname,
        @SourceSchema sysname,
        @SourceTable sysname,
        @ObjectSpecDatabaseOverrideId int,
        @OldIsEnabled bit,
        @Operation nvarchar(20),
        @EntityKey nvarchar(400),
        @WasChanged bit,
        @Now datetime2(0) = SYSUTCDATETIME();

    BEGIN TRAN;

    SELECT
        @ProcessId = pd.ProcessId,
        @ProcessCode = p.ProcessCode,
        @SourceDb = pd.SourceDb,
        @ArchiveDb = pd.ArchiveDb
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    WHERE pd.ProcessDatabaseId = @ProcessDatabaseId;

    IF @ProcessId IS NULL
        THROW 56944, 'ProcessDatabaseId does not exist.', 1;

    SELECT
        @ObjectProcessId = ProcessId,
        @SourceSchema = SourceSchema,
        @SourceTable = SourceTable
    FROM arch.ObjectSpec
    WHERE ObjectSpecId = @ObjectSpecId;

    IF @ObjectProcessId IS NULL
        THROW 56945, 'ObjectSpecId does not exist.', 1;

    IF @ObjectProcessId <> @ProcessId
        THROW 56946, 'ObjectSpecId does not belong to the same process as ProcessDatabaseId.', 1;

    SELECT
        @ObjectSpecDatabaseOverrideId = ObjectSpecDatabaseOverrideId,
        @OldIsEnabled = IsEnabled
    FROM arch.ObjectSpecDatabaseOverride
    WHERE ProcessDatabaseId = @ProcessDatabaseId
      AND ObjectSpecId = @ObjectSpecId;

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
            SYSUTCDATETIME(),
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56947, 'ConfigChangeSetId does not exist.', 1;

    SET @Operation = CASE WHEN @ObjectSpecDatabaseOverrideId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + @SourceDb + N'|' + @ArchiveDb + N'|' + @SourceSchema + N'.' + @SourceTable;
    SET @WasChanged = CONVERT(bit, CASE WHEN @OldIsEnabled IS NULL OR @OldIsEnabled <> @IsEnabled THEN 1 ELSE 0 END);

    IF @ObjectSpecDatabaseOverrideId IS NULL
    BEGIN
        INSERT INTO arch.ObjectSpecDatabaseOverride
        (
            ProcessDatabaseId,
            ObjectSpecId,
            IsEnabled,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @ProcessDatabaseId,
            @ObjectSpecId,
            @IsEnabled,
            @Now,
            @Now
        );

        SET @ObjectSpecDatabaseOverrideId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE IF @WasChanged = 1
    BEGIN
        UPDATE arch.ObjectSpecDatabaseOverride
        SET
            IsEnabled = @IsEnabled,
            ModifiedAt = @Now
        WHERE ObjectSpecDatabaseOverrideId = @ObjectSpecDatabaseOverrideId;
    END;

    IF @WasChanged = 1
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
            N'ObjectSpecDatabaseOverride',
            @EntityKey,
            @Operation,
            @ObjectSpecDatabaseOverrideId,
            SYSUTCDATETIME()
        );

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        VALUES
        (
            CONVERT(bigint, SCOPE_IDENTITY()),
            N'IsEnabled',
            CONVERT(nvarchar(30), @OldIsEnabled),
            CONVERT(nvarchar(30), @IsEnabled),
            0
        );
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Object override enabled state updated by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = SYSUTCDATETIME()
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        EntityType = N'ObjectSpecDatabaseOverride',
        EntityId = @ObjectSpecDatabaseOverrideId,
        EntityKey = @EntityKey,
        ProcessDatabaseId = @ProcessDatabaseId,
        ObjectSpecId = @ObjectSpecId,
        IsEnabled = @IsEnabled,
        WasChanged = @WasChanged;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SetRunProfileEnabled]
    @RunProfileCode sysname,
    @IsEnabled bit,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
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

    IF @RunProfileCode IS NULL
        THROW 56960, 'RunProfileCode is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56961, 'IsEnabled is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56962, 'RequestedBy is required.', 1;

    DECLARE
        @RunProfileId int,
        @OldIsEnabled bit,
        @WasChanged bit;

    BEGIN TRAN;

    SELECT
        @RunProfileId = RunProfileId,
        @OldIsEnabled = IsEnabled
    FROM arch.RunProfile
    WHERE RunProfileCode = @RunProfileCode;

    IF @RunProfileId IS NULL
        THROW 56963, 'RunProfileCode does not exist.', 1;

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
            SYSUTCDATETIME(),
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56964, 'ConfigChangeSetId does not exist.', 1;

    SET @WasChanged = CONVERT(bit, CASE WHEN @OldIsEnabled <> @IsEnabled THEN 1 ELSE 0 END);

    IF @WasChanged = 1
    BEGIN
        UPDATE arch.RunProfile
        SET
            IsEnabled = @IsEnabled,
            ModifiedAt = SYSUTCDATETIME()
        WHERE RunProfileId = @RunProfileId;
    END;

    IF @WasChanged = 1
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
            @RunProfileCode,
            N'UPDATE',
            @RunProfileId,
            SYSUTCDATETIME()
        );

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        VALUES
        (
            CONVERT(bigint, SCOPE_IDENTITY()),
            N'IsEnabled',
            CONVERT(nvarchar(30), @OldIsEnabled),
            CONVERT(nvarchar(30), @IsEnabled),
            0
        );
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Run profile enabled state updated by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = SYSUTCDATETIME()
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        EntityType = N'RunProfile',
        EntityId = @RunProfileId,
        EntityKey = @RunProfileCode,
        IsEnabled = @IsEnabled,
        WasChanged = @WasChanged;
END
GO
