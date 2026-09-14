USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveObjectSpec]
    @ObjectSpecId int = NULL OUTPUT,
    @ProcessCode sysname,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @SourceSchema sysname,
    @SourceTable sysname,
    @DeleteOrder int,
    @DeleteMode tinyint,
    @TimestampExpr nvarchar(4000) = NULL,
    @JoinToAnchorPredicateSql nvarchar(4000) = NULL,
    @AdditionalWhereSql nvarchar(4000) = NULL,
    @ArchiveSchema sysname = N'dbo',
    @ArchiveTable sysname = NULL,
    @RequireArchiveForDelete bit = 1,
    @NaturalKeyLabel nvarchar(50) = NULL,
    @CandidateSelectExpr nvarchar(4000) = NULL,
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
    SET @SourceSchema = NULLIF(LTRIM(RTRIM(@SourceSchema)), N'');
    SET @SourceTable = NULLIF(LTRIM(RTRIM(@SourceTable)), N'');
    SET @TimestampExpr = NULLIF(LTRIM(RTRIM(@TimestampExpr)), N'');
    SET @JoinToAnchorPredicateSql = NULLIF(LTRIM(RTRIM(@JoinToAnchorPredicateSql)), N'');
    SET @AdditionalWhereSql = NULLIF(LTRIM(RTRIM(@AdditionalWhereSql)), N'');
    SET @ArchiveSchema = COALESCE(NULLIF(LTRIM(RTRIM(@ArchiveSchema)), N''), N'dbo');
    SET @ArchiveTable = NULLIF(LTRIM(RTRIM(@ArchiveTable)), N'');
    SET @NaturalKeyLabel = NULLIF(LTRIM(RTRIM(@NaturalKeyLabel)), N'');
    SET @CandidateSelectExpr = NULLIF(LTRIM(RTRIM(@CandidateSelectExpr)), N'');

    IF @ProcessCode IS NULL
        THROW 56700, 'ProcessCode is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56701, 'RequestedBy is required.', 1;

    IF @SourceSchema IS NULL
        THROW 56702, 'SourceSchema is required.', 1;

    IF @SourceTable IS NULL
        THROW 56703, 'SourceTable is required.', 1;

    IF @DeleteOrder IS NULL
        THROW 56704, 'DeleteOrder is required.', 1;

    IF @DeleteMode IS NULL OR @DeleteMode NOT IN (0, 1)
        THROW 56705, 'DeleteMode must be 0 or 1.', 1;

    IF @RequireArchiveForDelete IS NULL
        THROW 56706, 'RequireArchiveForDelete is required.', 1;

    -- T-05: reject unsafe SQL in the advanced free-text fields before persisting — they are later
    -- concatenated into the runner's dynamic DELETE against production source databases.
    EXEC arch.usp_AssertSafeSqlExpression @TimestampExpr, N'TimestampExpr';
    EXEC arch.usp_AssertSafeSqlExpression @JoinToAnchorPredicateSql, N'JoinToAnchorPredicateSql';
    EXEC arch.usp_AssertSafeSqlExpression @AdditionalWhereSql, N'AdditionalWhereSql';
    EXEC arch.usp_AssertSafeSqlExpression @CandidateSelectExpr, N'CandidateSelectExpr';

    DECLARE
        @ProcessId int,
        @Operation nvarchar(20),
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldSourceSchema sysname,
        @OldSourceTable sysname,
        @OldDeleteOrder int,
        @OldDeleteMode tinyint,
        @OldTimestampExpr nvarchar(4000),
        @OldJoinToAnchorPredicateSql nvarchar(4000),
        @OldAdditionalWhereSql nvarchar(4000),
        @OldArchiveSchema sysname,
        @OldArchiveTable sysname,
        @OldRequireArchiveForDelete bit,
        @OldNaturalKeyLabel nvarchar(50),
        @OldCandidateSelectExpr nvarchar(4000);

    DECLARE @Audit table
    (
        FieldName sysname NOT NULL,
        OldValue nvarchar(max) NULL,
        NewValue nvarchar(max) NULL,
        IsAdvancedField bit NOT NULL
    );

    BEGIN TRAN;

    SELECT @ProcessId = ProcessId
    FROM arch.Process
    WHERE ProcessCode = @ProcessCode;

    IF @ProcessId IS NULL
        THROW 56707, 'ProcessCode does not exist.', 1;

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
        THROW 56708, 'ConfigChangeSetId does not exist.', 1;

    IF @ObjectSpecId IS NULL
    BEGIN
        SELECT TOP (1) @ObjectSpecId = ObjectSpecId
        FROM arch.ObjectSpec
        WHERE ProcessId = @ProcessId
          AND SourceSchema = @SourceSchema
          AND SourceTable = @SourceTable
        ORDER BY ObjectSpecId;
    END;

    IF @ObjectSpecId IS NOT NULL
    BEGIN
        SELECT
            @OldSourceSchema = SourceSchema,
            @OldSourceTable = SourceTable,
            @OldDeleteOrder = DeleteOrder,
            @OldDeleteMode = DeleteMode,
            @OldTimestampExpr = TimestampExpr,
            @OldJoinToAnchorPredicateSql = JoinToAnchorPredicateSql,
            @OldAdditionalWhereSql = AdditionalWhereSql,
            @OldArchiveSchema = ArchiveSchema,
            @OldArchiveTable = ArchiveTable,
            @OldRequireArchiveForDelete = RequireArchiveForDelete,
            @OldNaturalKeyLabel = NaturalKeyLabel,
            @OldCandidateSelectExpr = CandidateSelectExpr
        FROM arch.ObjectSpec
        WHERE ObjectSpecId = @ObjectSpecId
          AND ProcessId = @ProcessId;

        IF @@ROWCOUNT = 0
            THROW 56709, 'ObjectSpecId does not exist for the selected process.', 1;
    END;

    SET @Operation = CASE WHEN @ObjectSpecId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + @SourceSchema + N'.' + @SourceTable;

    IF @ObjectSpecId IS NULL
    BEGIN
        INSERT INTO arch.ObjectSpec
        (
            ProcessId,
            SourceSchema,
            SourceTable,
            DeleteOrder,
            DeleteMode,
            TimestampExpr,
            JoinToAnchorPredicateSql,
            AdditionalWhereSql,
            ArchiveSchema,
            ArchiveTable,
            RequireArchiveForDelete,
            NaturalKeyLabel,
            CandidateSelectExpr
        )
        VALUES
        (
            @ProcessId,
            @SourceSchema,
            @SourceTable,
            @DeleteOrder,
            @DeleteMode,
            @TimestampExpr,
            @JoinToAnchorPredicateSql,
            @AdditionalWhereSql,
            @ArchiveSchema,
            @ArchiveTable,
            @RequireArchiveForDelete,
            @NaturalKeyLabel,
            @CandidateSelectExpr
        );

        SET @ObjectSpecId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.ObjectSpec
        SET
            SourceSchema = @SourceSchema,
            SourceTable = @SourceTable,
            DeleteOrder = @DeleteOrder,
            DeleteMode = @DeleteMode,
            TimestampExpr = @TimestampExpr,
            JoinToAnchorPredicateSql = @JoinToAnchorPredicateSql,
            AdditionalWhereSql = @AdditionalWhereSql,
            ArchiveSchema = @ArchiveSchema,
            ArchiveTable = @ArchiveTable,
            RequireArchiveForDelete = @RequireArchiveForDelete,
            NaturalKeyLabel = @NaturalKeyLabel,
            CandidateSelectExpr = @CandidateSelectExpr
        WHERE ObjectSpecId = @ObjectSpecId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessCode', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ProcessCode END, @ProcessCode, 0),
        (N'SourceSchema', @OldSourceSchema, @SourceSchema, 0),
        (N'SourceTable', @OldSourceTable, @SourceTable, 0),
        (N'DeleteOrder', CONVERT(nvarchar(30), @OldDeleteOrder), CONVERT(nvarchar(30), @DeleteOrder), 0),
        (N'DeleteMode', CONVERT(nvarchar(30), @OldDeleteMode), CONVERT(nvarchar(30), @DeleteMode), 0),
        (N'TimestampExpr', @OldTimestampExpr, @TimestampExpr, 1),
        (N'JoinToAnchorPredicateSql', @OldJoinToAnchorPredicateSql, @JoinToAnchorPredicateSql, 1),
        (N'AdditionalWhereSql', @OldAdditionalWhereSql, @AdditionalWhereSql, 1),
        (N'ArchiveSchema', @OldArchiveSchema, @ArchiveSchema, 0),
        (N'ArchiveTable', @OldArchiveTable, @ArchiveTable, 0),
        (N'RequireArchiveForDelete', CONVERT(nvarchar(30), @OldRequireArchiveForDelete), CONVERT(nvarchar(30), @RequireArchiveForDelete), 0),
        (N'NaturalKeyLabel', @OldNaturalKeyLabel, @NaturalKeyLabel, 0),
        (N'CandidateSelectExpr', @OldCandidateSelectExpr, @CandidateSelectExpr, 1);

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
            N'ObjectSpec',
            @EntityKey,
            @Operation,
            @ObjectSpecId,
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
        ValidationSummary = N'Object specification saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        os.ObjectSpecId,
        p.ProcessCode,
        os.SourceSchema,
        os.SourceTable,
        os.DeleteOrder,
        os.DeleteMode,
        os.TimestampExpr,
        os.JoinToAnchorPredicateSql,
        os.AdditionalWhereSql,
        os.ArchiveSchema,
        os.ArchiveTable,
        os.RequireArchiveForDelete,
        os.NaturalKeyLabel,
        os.CandidateSelectExpr
    FROM arch.ObjectSpec os
    JOIN arch.Process p
      ON p.ProcessId = os.ProcessId
    WHERE os.ObjectSpecId = @ObjectSpecId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveObjectSpecOverride]
    @ObjectSpecDatabaseOverrideId int = NULL OUTPUT,
    @ProcessDatabaseId int,
    @ObjectSpecId int,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @IsEnabled bit = 1,
    @SourceSchemaOverride sysname = NULL,
    @SourceTableOverride sysname = NULL,
    @TimestampExprOverride nvarchar(4000) = NULL,
    @JoinToAnchorPredicateSqlOverride nvarchar(4000) = NULL,
    @AdditionalWhereSqlOverride nvarchar(4000) = NULL,
    @ArchiveSchemaOverride sysname = NULL,
    @ArchiveTableOverride sysname = NULL,
    @RequireArchiveForDeleteOverride bit = NULL,
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
    SET @SourceSchemaOverride = NULLIF(LTRIM(RTRIM(@SourceSchemaOverride)), N'');
    SET @SourceTableOverride = NULLIF(LTRIM(RTRIM(@SourceTableOverride)), N'');
    SET @TimestampExprOverride = NULLIF(LTRIM(RTRIM(@TimestampExprOverride)), N'');
    SET @JoinToAnchorPredicateSqlOverride = NULLIF(LTRIM(RTRIM(@JoinToAnchorPredicateSqlOverride)), N'');
    SET @AdditionalWhereSqlOverride = NULLIF(LTRIM(RTRIM(@AdditionalWhereSqlOverride)), N'');
    SET @ArchiveSchemaOverride = NULLIF(LTRIM(RTRIM(@ArchiveSchemaOverride)), N'');
    SET @ArchiveTableOverride = NULLIF(LTRIM(RTRIM(@ArchiveTableOverride)), N'');

    IF @ProcessDatabaseId IS NULL
        THROW 56720, 'ProcessDatabaseId is required.', 1;

    IF @ObjectSpecId IS NULL
        THROW 56721, 'ObjectSpecId is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56722, 'RequestedBy is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56723, 'IsEnabled is required.', 1;

    -- T-05: validate the advanced free-text override expressions before persisting — they feed the
    -- runner's dynamic DELETE against production source databases.
    EXEC arch.usp_AssertSafeSqlExpression @TimestampExprOverride, N'TimestampExprOverride';
    EXEC arch.usp_AssertSafeSqlExpression @JoinToAnchorPredicateSqlOverride, N'JoinToAnchorPredicateSqlOverride';
    EXEC arch.usp_AssertSafeSqlExpression @AdditionalWhereSqlOverride, N'AdditionalWhereSqlOverride';

    DECLARE
        @ProcessId int,
        @ObjectProcessId int,
        @ProcessCode sysname,
        @SourceDb sysname,
        @ArchiveDb sysname,
        @BaseSourceSchema sysname,
        @BaseSourceTable sysname,
        @Operation nvarchar(20),
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldIsEnabled bit,
        @OldSourceSchemaOverride sysname,
        @OldSourceTableOverride sysname,
        @OldTimestampExprOverride nvarchar(4000),
        @OldJoinToAnchorPredicateSqlOverride nvarchar(4000),
        @OldAdditionalWhereSqlOverride nvarchar(4000),
        @OldArchiveSchemaOverride sysname,
        @OldArchiveTableOverride sysname,
        @OldRequireArchiveForDeleteOverride bit;

    DECLARE @Audit table
    (
        FieldName sysname NOT NULL,
        OldValue nvarchar(max) NULL,
        NewValue nvarchar(max) NULL,
        IsAdvancedField bit NOT NULL
    );

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
        THROW 56724, 'ProcessDatabaseId does not exist.', 1;

    SELECT
        @ObjectProcessId = ProcessId,
        @BaseSourceSchema = SourceSchema,
        @BaseSourceTable = SourceTable
    FROM arch.ObjectSpec
    WHERE ObjectSpecId = @ObjectSpecId;

    IF @ObjectProcessId IS NULL
        THROW 56725, 'ObjectSpecId does not exist.', 1;

    IF @ObjectProcessId <> @ProcessId
        THROW 56726, 'ObjectSpecId does not belong to the same process as ProcessDatabaseId.', 1;

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
        THROW 56727, 'ConfigChangeSetId does not exist.', 1;

    IF @ObjectSpecDatabaseOverrideId IS NULL
    BEGIN
        SELECT @ObjectSpecDatabaseOverrideId = ObjectSpecDatabaseOverrideId
        FROM arch.ObjectSpecDatabaseOverride
        WHERE ProcessDatabaseId = @ProcessDatabaseId
          AND ObjectSpecId = @ObjectSpecId;
    END;

    IF @ObjectSpecDatabaseOverrideId IS NOT NULL
    BEGIN
        SELECT
            @OldIsEnabled = IsEnabled,
            @OldSourceSchemaOverride = SourceSchemaOverride,
            @OldSourceTableOverride = SourceTableOverride,
            @OldTimestampExprOverride = TimestampExprOverride,
            @OldJoinToAnchorPredicateSqlOverride = JoinToAnchorPredicateSqlOverride,
            @OldAdditionalWhereSqlOverride = AdditionalWhereSqlOverride,
            @OldArchiveSchemaOverride = ArchiveSchemaOverride,
            @OldArchiveTableOverride = ArchiveTableOverride,
            @OldRequireArchiveForDeleteOverride = RequireArchiveForDeleteOverride
        FROM arch.ObjectSpecDatabaseOverride
        WHERE ObjectSpecDatabaseOverrideId = @ObjectSpecDatabaseOverrideId
          AND ProcessDatabaseId = @ProcessDatabaseId
          AND ObjectSpecId = @ObjectSpecId;

        IF @@ROWCOUNT = 0
            THROW 56728, 'ObjectSpecDatabaseOverrideId does not match the selected mapping and object.', 1;
    END;

    SET @Operation = CASE WHEN @ObjectSpecDatabaseOverrideId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + @SourceDb + N'|' + @ArchiveDb + N'|' + @BaseSourceSchema + N'.' + @BaseSourceTable;

    IF @ObjectSpecDatabaseOverrideId IS NULL
    BEGIN
        INSERT INTO arch.ObjectSpecDatabaseOverride
        (
            ProcessDatabaseId,
            ObjectSpecId,
            IsEnabled,
            SourceSchemaOverride,
            SourceTableOverride,
            TimestampExprOverride,
            JoinToAnchorPredicateSqlOverride,
            AdditionalWhereSqlOverride,
            ArchiveSchemaOverride,
            ArchiveTableOverride,
            RequireArchiveForDeleteOverride,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @ProcessDatabaseId,
            @ObjectSpecId,
            @IsEnabled,
            @SourceSchemaOverride,
            @SourceTableOverride,
            @TimestampExprOverride,
            @JoinToAnchorPredicateSqlOverride,
            @AdditionalWhereSqlOverride,
            @ArchiveSchemaOverride,
            @ArchiveTableOverride,
            @RequireArchiveForDeleteOverride,
            @Now,
            @Now
        );

        SET @ObjectSpecDatabaseOverrideId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.ObjectSpecDatabaseOverride
        SET
            IsEnabled = @IsEnabled,
            SourceSchemaOverride = @SourceSchemaOverride,
            SourceTableOverride = @SourceTableOverride,
            TimestampExprOverride = @TimestampExprOverride,
            JoinToAnchorPredicateSqlOverride = @JoinToAnchorPredicateSqlOverride,
            AdditionalWhereSqlOverride = @AdditionalWhereSqlOverride,
            ArchiveSchemaOverride = @ArchiveSchemaOverride,
            ArchiveTableOverride = @ArchiveTableOverride,
            RequireArchiveForDeleteOverride = @RequireArchiveForDeleteOverride,
            ModifiedAt = @Now
        WHERE ObjectSpecDatabaseOverrideId = @ObjectSpecDatabaseOverrideId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessDatabaseId', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE CONVERT(nvarchar(30), @ProcessDatabaseId) END, CONVERT(nvarchar(30), @ProcessDatabaseId), 0),
        (N'ObjectSpecId', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE CONVERT(nvarchar(30), @ObjectSpecId) END, CONVERT(nvarchar(30), @ObjectSpecId), 0),
        (N'IsEnabled', CONVERT(nvarchar(30), @OldIsEnabled), CONVERT(nvarchar(30), @IsEnabled), 0),
        (N'SourceSchemaOverride', @OldSourceSchemaOverride, @SourceSchemaOverride, 0),
        (N'SourceTableOverride', @OldSourceTableOverride, @SourceTableOverride, 0),
        (N'TimestampExprOverride', @OldTimestampExprOverride, @TimestampExprOverride, 1),
        (N'JoinToAnchorPredicateSqlOverride', @OldJoinToAnchorPredicateSqlOverride, @JoinToAnchorPredicateSqlOverride, 1),
        (N'AdditionalWhereSqlOverride', @OldAdditionalWhereSqlOverride, @AdditionalWhereSqlOverride, 1),
        (N'ArchiveSchemaOverride', @OldArchiveSchemaOverride, @ArchiveSchemaOverride, 0),
        (N'ArchiveTableOverride', @OldArchiveTableOverride, @ArchiveTableOverride, 0),
        (N'RequireArchiveForDeleteOverride', CONVERT(nvarchar(30), @OldRequireArchiveForDeleteOverride), CONVERT(nvarchar(30), @RequireArchiveForDeleteOverride), 0);

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
            N'ObjectSpecDatabaseOverride',
            @EntityKey,
            @Operation,
            @ObjectSpecDatabaseOverrideId,
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
        ValidationSummary = N'Object database override saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        osdo.ObjectSpecDatabaseOverrideId,
        osdo.ProcessDatabaseId,
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        osdo.ObjectSpecId,
        BaseObjectName = QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        osdo.IsEnabled,
        osdo.SourceSchemaOverride,
        osdo.SourceTableOverride,
        osdo.TimestampExprOverride,
        osdo.JoinToAnchorPredicateSqlOverride,
        osdo.AdditionalWhereSqlOverride,
        osdo.ArchiveSchemaOverride,
        osdo.ArchiveTableOverride,
        osdo.RequireArchiveForDeleteOverride,
        osdo.ModifiedAt
    FROM arch.ObjectSpecDatabaseOverride osdo
    JOIN arch.ProcessDatabase pd
      ON pd.ProcessDatabaseId = osdo.ProcessDatabaseId
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    JOIN arch.ObjectSpec os
      ON os.ObjectSpecId = osdo.ObjectSpecId
    WHERE osdo.ObjectSpecDatabaseOverrideId = @ObjectSpecDatabaseOverrideId;
END
GO
