USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveProcessKeySpec]
    @ProcessKeySpecId int = NULL OUTPUT,
    @ProcessCode sysname,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @KeyOrdinal tinyint,
    @KeyName sysname,
    @SourceExpressionSql nvarchar(4000),
    @SqlType nvarchar(128),
    @IsRequired bit = 1,
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
    SET @KeyName = NULLIF(LTRIM(RTRIM(@KeyName)), N'');
    SET @SourceExpressionSql = NULLIF(LTRIM(RTRIM(@SourceExpressionSql)), N'');
    SET @SqlType = NULLIF(LTRIM(RTRIM(@SqlType)), N'');

    IF @ProcessCode IS NULL
        THROW 57300, 'ProcessCode is required.', 1;

    IF @RequestedBy IS NULL
        THROW 57301, 'RequestedBy is required.', 1;

    IF @KeyOrdinal IS NULL OR @KeyOrdinal NOT BETWEEN 1 AND 8
        THROW 57302, 'KeyOrdinal must be between 1 and 8.', 1;

    IF @KeyName IS NULL
        THROW 57303, 'KeyName is required.', 1;

    IF @SourceExpressionSql IS NULL
        THROW 57304, 'SourceExpressionSql is required.', 1;

    IF @SqlType IS NULL
        THROW 57305, 'SqlType is required.', 1;

    IF @IsRequired IS NULL
        THROW 57306, 'IsRequired is required.', 1;

    -- T-05: the key expression is concatenated into the runner's candidate SELECT/WHERE against the
    -- production source DB — reject unsafe SQL before persisting.
    EXEC arch.usp_AssertSafeSqlExpression @SourceExpressionSql, N'SourceExpressionSql';

    DECLARE
        @ProcessId int,
        @Operation nvarchar(20),
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldKeyOrdinal tinyint,
        @OldKeyName sysname,
        @OldSourceExpressionSql nvarchar(4000),
        @OldSqlType nvarchar(128),
        @OldIsRequired bit;

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
        THROW 57307, 'ProcessCode does not exist.', 1;

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
        THROW 57308, 'ConfigChangeSetId does not exist.', 1;

    IF @ProcessKeySpecId IS NULL
    BEGIN
        SELECT @ProcessKeySpecId = ProcessKeySpecId
        FROM arch.ProcessKeySpec
        WHERE ProcessId = @ProcessId
          AND KeyOrdinal = @KeyOrdinal;
    END;

    IF @ProcessKeySpecId IS NOT NULL
    BEGIN
        SELECT
            @OldKeyOrdinal = KeyOrdinal,
            @OldKeyName = KeyName,
            @OldSourceExpressionSql = SourceExpressionSql,
            @OldSqlType = SqlType,
            @OldIsRequired = IsRequired
        FROM arch.ProcessKeySpec
        WHERE ProcessKeySpecId = @ProcessKeySpecId
          AND ProcessId = @ProcessId;

        IF @@ROWCOUNT = 0
            THROW 57309, 'ProcessKeySpecId does not exist for the selected process.', 1;

        IF @OldKeyOrdinal <> @KeyOrdinal
           AND EXISTS
           (
               SELECT 1
               FROM arch.ProcessKeySpec
               WHERE ProcessId = @ProcessId
                 AND KeyOrdinal = @KeyOrdinal
                 AND ProcessKeySpecId <> @ProcessKeySpecId
           )
            THROW 57310, 'KeyOrdinal already exists for the selected process.', 1;
    END;

    SET @Operation = CASE WHEN @ProcessKeySpecId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + CONVERT(nvarchar(10), @KeyOrdinal);

    IF @ProcessKeySpecId IS NULL
    BEGIN
        INSERT INTO arch.ProcessKeySpec
        (
            ProcessId,
            KeyOrdinal,
            KeyName,
            SourceExpressionSql,
            SqlType,
            IsRequired,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @ProcessId,
            @KeyOrdinal,
            @KeyName,
            @SourceExpressionSql,
            @SqlType,
            @IsRequired,
            @Now,
            @Now
        );

        SET @ProcessKeySpecId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.ProcessKeySpec
        SET
            KeyOrdinal = @KeyOrdinal,
            KeyName = @KeyName,
            SourceExpressionSql = @SourceExpressionSql,
            SqlType = @SqlType,
            IsRequired = @IsRequired,
            ModifiedAt = @Now
        WHERE ProcessKeySpecId = @ProcessKeySpecId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessCode', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ProcessCode END, @ProcessCode, 0),
        (N'KeyOrdinal', CONVERT(nvarchar(30), @OldKeyOrdinal), CONVERT(nvarchar(30), @KeyOrdinal), 0),
        (N'KeyName', @OldKeyName, @KeyName, 0),
        (N'SourceExpressionSql', @OldSourceExpressionSql, @SourceExpressionSql, 1),
        (N'SqlType', @OldSqlType, @SqlType, 1),
        (N'IsRequired', CONVERT(nvarchar(30), @OldIsRequired), CONVERT(nvarchar(30), @IsRequired), 0);

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
            N'ProcessKeySpec',
            @EntityKey,
            @Operation,
            @ProcessKeySpecId,
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
        ValidationSummary = N'Process key specification saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        pks.ProcessKeySpecId,
        p.ProcessCode,
        pks.KeyOrdinal,
        pks.KeyName,
        pks.SourceExpressionSql,
        pks.SqlType,
        pks.IsRequired,
        pks.ModifiedAt
    FROM arch.ProcessKeySpec pks
    JOIN arch.Process p
      ON p.ProcessId = pks.ProcessId
    WHERE pks.ProcessKeySpecId = @ProcessKeySpecId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveIndexRequirement]
    @IndexRequirementId int = NULL OUTPUT,
    @ProcessCode sysname,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @ObjectSpecId int = NULL,
    @RequirementType nvarchar(20),
    @SourceSchema sysname,
    @SourceTable sysname,
    @KeyColumnsCsv nvarchar(1000),
    @IncludeColumnsCsv nvarchar(1000) = NULL,
    @FilterSql nvarchar(1000) = NULL,
    @IsMandatory bit = 1,
    @Notes nvarchar(1000) = NULL,
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
    SET @RequirementType = UPPER(NULLIF(LTRIM(RTRIM(@RequirementType)), N''));
    SET @SourceSchema = NULLIF(LTRIM(RTRIM(@SourceSchema)), N'');
    SET @SourceTable = NULLIF(LTRIM(RTRIM(@SourceTable)), N'');
    SET @KeyColumnsCsv = NULLIF(LTRIM(RTRIM(@KeyColumnsCsv)), N'');
    SET @IncludeColumnsCsv = NULLIF(LTRIM(RTRIM(@IncludeColumnsCsv)), N'');
    SET @FilterSql = NULLIF(LTRIM(RTRIM(@FilterSql)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    IF @ProcessCode IS NULL
        THROW 57330, 'ProcessCode is required.', 1;

    IF @RequestedBy IS NULL
        THROW 57331, 'RequestedBy is required.', 1;

    IF @RequirementType IS NULL OR @RequirementType NOT IN (N'SELECTION', N'JOIN', N'DELETE', N'ORDER', N'PARTITION')
        THROW 57332, 'RequirementType is invalid.', 1;

    IF @SourceSchema IS NULL
        THROW 57333, 'SourceSchema is required.', 1;

    IF @SourceTable IS NULL
        THROW 57334, 'SourceTable is required.', 1;

    IF @KeyColumnsCsv IS NULL
        THROW 57335, 'KeyColumnsCsv is required.', 1;

    IF @IsMandatory IS NULL
        THROW 57336, 'IsMandatory is required.', 1;

    -- Safe-expression gate (T-05): FilterSql is advisory free-text SQL today (display-only, no runtime
    -- exec sink), but gate it like every other advanced SQL field so it can never be persisted as
    -- unvalidated SQL — forward-proofing should a future feature ever concatenate it into a probe/DDL.
    IF @FilterSql IS NOT NULL
        EXEC arch.usp_AssertSafeSqlExpression @FilterSql, N'IndexRequirement.FilterSql';

    DECLARE
        @ProcessId int,
        @ObjectProcessId int,
        @Operation nvarchar(20),
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldObjectSpecId int,
        @OldRequirementType nvarchar(20),
        @OldSourceSchema sysname,
        @OldSourceTable sysname,
        @OldKeyColumnsCsv nvarchar(1000),
        @OldIncludeColumnsCsv nvarchar(1000),
        @OldFilterSql nvarchar(1000),
        @OldIsMandatory bit,
        @OldNotes nvarchar(1000);

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
        THROW 57337, 'ProcessCode does not exist.', 1;

    IF @ObjectSpecId IS NOT NULL
    BEGIN
        SELECT @ObjectProcessId = ProcessId
        FROM arch.ObjectSpec
        WHERE ObjectSpecId = @ObjectSpecId;

        IF @ObjectProcessId IS NULL
            THROW 57338, 'ObjectSpecId does not exist.', 1;

        IF @ObjectProcessId <> @ProcessId
            THROW 57339, 'ObjectSpecId does not belong to the selected process.', 1;
    END;

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
        THROW 57340, 'ConfigChangeSetId does not exist.', 1;

    IF @IndexRequirementId IS NULL
    BEGIN
        SELECT TOP (1) @IndexRequirementId = IndexRequirementId
        FROM arch.IndexRequirement
        WHERE ProcessId = @ProcessId
          AND ((ObjectSpecId = @ObjectSpecId) OR (ObjectSpecId IS NULL AND @ObjectSpecId IS NULL))
          AND RequirementType = @RequirementType
          AND SourceSchema = @SourceSchema
          AND SourceTable = @SourceTable
          AND KeyColumnsCsv = @KeyColumnsCsv
        ORDER BY IndexRequirementId;
    END;

    IF @IndexRequirementId IS NOT NULL
    BEGIN
        SELECT
            @OldObjectSpecId = ObjectSpecId,
            @OldRequirementType = RequirementType,
            @OldSourceSchema = SourceSchema,
            @OldSourceTable = SourceTable,
            @OldKeyColumnsCsv = KeyColumnsCsv,
            @OldIncludeColumnsCsv = IncludeColumnsCsv,
            @OldFilterSql = FilterSql,
            @OldIsMandatory = IsMandatory,
            @OldNotes = Notes
        FROM arch.IndexRequirement
        WHERE IndexRequirementId = @IndexRequirementId
          AND ProcessId = @ProcessId;

        IF @@ROWCOUNT = 0
            THROW 57341, 'IndexRequirementId does not exist for the selected process.', 1;
    END;

    SET @Operation = CASE WHEN @IndexRequirementId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + @RequirementType + N'|' + @SourceSchema + N'.' + @SourceTable + N'|' + @KeyColumnsCsv;

    IF @IndexRequirementId IS NULL
    BEGIN
        INSERT INTO arch.IndexRequirement
        (
            ProcessId,
            ObjectSpecId,
            RequirementType,
            SourceSchema,
            SourceTable,
            KeyColumnsCsv,
            IncludeColumnsCsv,
            FilterSql,
            IsMandatory,
            Notes,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @ProcessId,
            @ObjectSpecId,
            @RequirementType,
            @SourceSchema,
            @SourceTable,
            @KeyColumnsCsv,
            @IncludeColumnsCsv,
            @FilterSql,
            @IsMandatory,
            @Notes,
            @Now,
            @Now
        );

        SET @IndexRequirementId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.IndexRequirement
        SET
            ObjectSpecId = @ObjectSpecId,
            RequirementType = @RequirementType,
            SourceSchema = @SourceSchema,
            SourceTable = @SourceTable,
            KeyColumnsCsv = @KeyColumnsCsv,
            IncludeColumnsCsv = @IncludeColumnsCsv,
            FilterSql = @FilterSql,
            IsMandatory = @IsMandatory,
            Notes = @Notes,
            ModifiedAt = @Now
        WHERE IndexRequirementId = @IndexRequirementId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessCode', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ProcessCode END, @ProcessCode, 0),
        (N'ObjectSpecId', CONVERT(nvarchar(30), @OldObjectSpecId), CONVERT(nvarchar(30), @ObjectSpecId), 0),
        (N'RequirementType', @OldRequirementType, @RequirementType, 0),
        (N'SourceSchema', @OldSourceSchema, @SourceSchema, 0),
        (N'SourceTable', @OldSourceTable, @SourceTable, 0),
        (N'KeyColumnsCsv', @OldKeyColumnsCsv, @KeyColumnsCsv, 1),
        (N'IncludeColumnsCsv', @OldIncludeColumnsCsv, @IncludeColumnsCsv, 1),
        (N'FilterSql', @OldFilterSql, @FilterSql, 1),
        (N'IsMandatory', CONVERT(nvarchar(30), @OldIsMandatory), CONVERT(nvarchar(30), @IsMandatory), 0),
        (N'Notes', @OldNotes, @Notes, 0);

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
            N'IndexRequirement',
            @EntityKey,
            @Operation,
            @IndexRequirementId,
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
        ValidationSummary = N'Index requirement saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        ir.IndexRequirementId,
        p.ProcessCode,
        ir.ObjectSpecId,
        ir.RequirementType,
        ir.SourceSchema,
        ir.SourceTable,
        ir.KeyColumnsCsv,
        ir.IncludeColumnsCsv,
        ir.FilterSql,
        ir.IsMandatory,
        ir.Notes,
        ir.ModifiedAt
    FROM arch.IndexRequirement ir
    JOIN arch.Process p
      ON p.ProcessId = ir.ProcessId
    WHERE ir.IndexRequirementId = @IndexRequirementId;
END
GO
