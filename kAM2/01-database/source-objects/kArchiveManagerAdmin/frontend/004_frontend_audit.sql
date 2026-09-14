USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID(N'arch.ConfigChangeSet', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ConfigChangeSet](
        [ConfigChangeSetId] [bigint] IDENTITY(1,1) NOT NULL,
        [ChangeStatus] [nvarchar](20) NOT NULL,
        [RequestedBy] [nvarchar](256) NOT NULL,
        [RequestedAtUtc] [datetime2](0) NOT NULL,
        [ApprovedBy] [nvarchar](256) NULL,
        [ApprovedAtUtc] [datetime2](0) NULL,
        [PublishedBy] [nvarchar](256) NULL,
        [PublishedAtUtc] [datetime2](0) NULL,
        [ChangeReason] [nvarchar](1000) NULL,
        [ValidationStatus] [nvarchar](20) NULL,
        [ValidationSummary] [nvarchar](4000) NULL,
        CONSTRAINT [PK_ConfigChangeSet] PRIMARY KEY CLUSTERED ([ConfigChangeSetId] ASC),
        CONSTRAINT [CK_ConfigChangeSet_Status] CHECK ([ChangeStatus] IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED', N'PUBLISHED', N'REJECTED', N'CANCELLED')),
        CONSTRAINT [CK_ConfigChangeSet_ValidationStatus] CHECK ([ValidationStatus] IS NULL OR [ValidationStatus] IN (N'NOT_RUN', N'OK', N'WARN', N'ERROR'))
    );

    ALTER TABLE [arch].[ConfigChangeSet]
    ADD CONSTRAINT [DF_ConfigChangeSet_Status] DEFAULT (N'DRAFT') FOR [ChangeStatus];

    ALTER TABLE [arch].[ConfigChangeSet]
    ADD CONSTRAINT [DF_ConfigChangeSet_RequestedAt] DEFAULT (SYSUTCDATETIME()) FOR [RequestedAtUtc];

    ALTER TABLE [arch].[ConfigChangeSet]
    ADD CONSTRAINT [DF_ConfigChangeSet_ValidationStatus] DEFAULT (N'NOT_RUN') FOR [ValidationStatus];
END
GO

IF OBJECT_ID(N'arch.ConfigChangeItem', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ConfigChangeItem](
        [ConfigChangeItemId] [bigint] IDENTITY(1,1) NOT NULL,
        [ConfigChangeSetId] [bigint] NOT NULL,
        [EntityType] [nvarchar](80) NOT NULL,
        [EntityKey] [nvarchar](400) NOT NULL,
        [Operation] [nvarchar](20) NOT NULL,
        [ObjectId] [int] NULL,
        [CreatedAtUtc] [datetime2](0) NOT NULL,
        CONSTRAINT [PK_ConfigChangeItem] PRIMARY KEY CLUSTERED ([ConfigChangeItemId] ASC),
        CONSTRAINT [FK_ConfigChangeItem_ChangeSet] FOREIGN KEY ([ConfigChangeSetId]) REFERENCES [arch].[ConfigChangeSet]([ConfigChangeSetId]),
        CONSTRAINT [CK_ConfigChangeItem_Operation] CHECK ([Operation] IN (N'INSERT', N'UPDATE', N'DELETE'))
    );

    ALTER TABLE [arch].[ConfigChangeItem]
    ADD CONSTRAINT [DF_ConfigChangeItem_CreatedAt] DEFAULT (SYSUTCDATETIME()) FOR [CreatedAtUtc];

    CREATE NONCLUSTERED INDEX [IX_ConfigChangeItem_ChangeSet]
    ON [arch].[ConfigChangeItem] ([ConfigChangeSetId], [EntityType], [EntityKey])
    INCLUDE ([Operation], [ObjectId], [CreatedAtUtc]);
END
GO

IF OBJECT_ID(N'arch.ConfigChangeField', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ConfigChangeField](
        [ConfigChangeFieldId] [bigint] IDENTITY(1,1) NOT NULL,
        [ConfigChangeItemId] [bigint] NOT NULL,
        [FieldName] [sysname] NOT NULL,
        [OldValue] [nvarchar](max) NULL,
        [NewValue] [nvarchar](max) NULL,
        [IsAdvancedField] [bit] NOT NULL,
        CONSTRAINT [PK_ConfigChangeField] PRIMARY KEY CLUSTERED ([ConfigChangeFieldId] ASC),
        CONSTRAINT [FK_ConfigChangeField_Item] FOREIGN KEY ([ConfigChangeItemId]) REFERENCES [arch].[ConfigChangeItem]([ConfigChangeItemId])
    );

    ALTER TABLE [arch].[ConfigChangeField]
    ADD CONSTRAINT [DF_ConfigChangeField_IsAdvanced] DEFAULT ((0)) FOR [IsAdvancedField];

    CREATE NONCLUSTERED INDEX [IX_ConfigChangeField_Item]
    ON [arch].[ConfigChangeField] ([ConfigChangeItemId], [FieldName])
    INCLUDE ([IsAdvancedField]);
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_CreateConfigChangeSet]
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @ConfigChangeSetId bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@RequestedBy)), N'') IS NULL
        THROW 56300, 'RequestedBy is required.', 1;

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
        NULLIF(LTRIM(RTRIM(@ChangeReason)), N''),
        N'NOT_RUN'
    );

    SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        ChangeStatus = N'DRAFT',
        RequestedBy = @RequestedBy,
        ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_RecordConfigFieldChange]
    @ConfigChangeSetId bigint,
    @EntityType nvarchar(80),
    @EntityKey nvarchar(400),
    @Operation nvarchar(20),
    @ObjectId int = NULL,
    @FieldName sysname,
    @OldValue nvarchar(max) = NULL,
    @NewValue nvarchar(max) = NULL,
    @IsAdvancedField bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56301, 'ConfigChangeSetId does not exist.', 1;

    IF NULLIF(LTRIM(RTRIM(@EntityType)), N'') IS NULL
        THROW 56302, 'EntityType is required.', 1;

    IF NULLIF(LTRIM(RTRIM(@EntityKey)), N'') IS NULL
        THROW 56303, 'EntityKey is required.', 1;

    IF @Operation NOT IN (N'INSERT', N'UPDATE', N'DELETE')
        THROW 56304, 'Operation must be INSERT, UPDATE, or DELETE.', 1;

    IF NULLIF(LTRIM(RTRIM(@FieldName)), N'') IS NULL
        THROW 56305, 'FieldName is required.', 1;

    IF (@OldValue = @NewValue) OR (@OldValue IS NULL AND @NewValue IS NULL)
    BEGIN
        SELECT
            ConfigChangeItemId = CONVERT(bigint, NULL),
            ConfigChangeFieldId = CONVERT(bigint, NULL),
            Recorded = CONVERT(bit, 0),
            Message = N'Field was unchanged; no audit row recorded.';
        RETURN;
    END;

    DECLARE @ConfigChangeItemId bigint;

    SELECT TOP (1)
        @ConfigChangeItemId = ConfigChangeItemId
    FROM arch.ConfigChangeItem
    WHERE ConfigChangeSetId = @ConfigChangeSetId
      AND EntityType = @EntityType
      AND EntityKey = @EntityKey
      AND Operation = @Operation
      AND
      (
          ObjectId = @ObjectId
          OR (ObjectId IS NULL AND @ObjectId IS NULL)
      )
    ORDER BY ConfigChangeItemId;

    IF @ConfigChangeItemId IS NULL
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
            @EntityType,
            @EntityKey,
            @Operation,
            @ObjectId,
            SYSUTCDATETIME()
        );

        SET @ConfigChangeItemId = CONVERT(bigint, SCOPE_IDENTITY());
    END;

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
        @ConfigChangeItemId,
        @FieldName,
        @OldValue,
        @NewValue,
        COALESCE(@IsAdvancedField, CONVERT(bit, 0))
    );

    SELECT
        ConfigChangeItemId = @ConfigChangeItemId,
        ConfigChangeFieldId = CONVERT(bigint, SCOPE_IDENTITY()),
        Recorded = CONVERT(bit, 1),
        Message = N'Field change recorded.';
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_FinalizeConfigChangeSet]
    @ConfigChangeSetId bigint,
    @ChangeStatus nvarchar(20),
    @ValidationStatus nvarchar(20),
    @ValidationSummary nvarchar(4000) = NULL,
    @Actor nvarchar(256)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ChangeStatus NOT IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED', N'PUBLISHED', N'REJECTED', N'CANCELLED')
        THROW 56306, 'Invalid ChangeStatus.', 1;

    IF @ValidationStatus NOT IN (N'NOT_RUN', N'OK', N'WARN', N'ERROR')
        THROW 56307, 'Invalid ValidationStatus.', 1;

    IF NULLIF(LTRIM(RTRIM(@Actor)), N'') IS NULL
        THROW 56308, 'Actor is required.', 1;

    -- T-06: segregation of duties on the approval/publication transitions. Load the current state +
    -- requester so we can enforce four-eyes. (The web API does not call this proc — config Save*
    -- auto-publishes today — so this gate protects the explicit/approval-workflow path and any future
    -- mandatory-approval flow without affecting the current save path.)
    DECLARE @currentStatus nvarchar(20), @requestedBy nvarchar(256);
    SELECT @currentStatus = ChangeStatus, @requestedBy = RequestedBy
    FROM arch.ConfigChangeSet
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    IF @currentStatus IS NULL
        THROW 56309, 'ConfigChangeSetId does not exist.', 1;

    IF @ChangeStatus IN (N'APPROVED', N'PUBLISHED')
    BEGIN
        -- (a) no self-approval: approver/publisher must differ from the requester.
        IF LOWER(LTRIM(RTRIM(@Actor))) = LOWER(LTRIM(RTRIM(@requestedBy)))
            THROW 56310, 'Segregation of duties: the approver/publisher must differ from the requester (RequestedBy).', 1;
        -- (b) only members of karch_approver may approve/publish (sysadmin bypasses, as it does all checks).
        IF COALESCE(IS_MEMBER('karch_approver'), 0) = 0 AND IS_SRVROLEMEMBER('sysadmin') = 0
            THROW 56311, 'Only members of karch_approver may approve or publish a configuration change set.', 1;
    END;

    -- (c) enforce the state machine: no skipping straight to PUBLISHED.
    IF @ChangeStatus = N'PUBLISHED' AND @currentStatus <> N'APPROVED'
        THROW 56312, 'A change set must be APPROVED before it can be PUBLISHED.', 1;
    IF @ChangeStatus = N'APPROVED' AND @currentStatus NOT IN (N'PENDING_APPROVAL', N'APPROVED')
        THROW 56313, 'Only a PENDING_APPROVAL change set can be APPROVED.', 1;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = @ChangeStatus,
        ValidationStatus = @ValidationStatus,
        ValidationSummary = @ValidationSummary,
        PublishedBy = CASE WHEN @ChangeStatus = N'PUBLISHED' THEN @Actor ELSE PublishedBy END,
        PublishedAtUtc = CASE WHEN @ChangeStatus = N'PUBLISHED' THEN SYSUTCDATETIME() ELSE PublishedAtUtc END,
        ApprovedBy = CASE WHEN @ChangeStatus = N'APPROVED' THEN @Actor ELSE ApprovedBy END,
        ApprovedAtUtc = CASE WHEN @ChangeStatus = N'APPROVED' THEN SYSUTCDATETIME() ELSE ApprovedAtUtc END
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    IF @@ROWCOUNT = 0
        THROW 56309, 'ConfigChangeSetId does not exist.', 1;

    SELECT
        ConfigChangeSetId,
        ChangeStatus,
        RequestedBy,
        RequestedAtUtc,
        ApprovedBy,
        ApprovedAtUtc,
        PublishedBy,
        PublishedAtUtc,
        ChangeReason,
        ValidationStatus,
        ValidationSummary
    FROM arch.ConfigChangeSet
    WHERE ConfigChangeSetId = @ConfigChangeSetId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetConfigChangeHistory]
    @ConfigChangeSetId bigint = NULL,
    @DateFromUtc datetime2(0) = NULL,
    @DateToUtc datetime2(0) = NULL,
    @RequestedBy nvarchar(256) = NULL,
    @EntityType nvarchar(80) = NULL,
    @EntityKey nvarchar(400) = NULL,
    @ChangeStatus nvarchar(20) = NULL,
    @Top int = 500
AS
BEGIN
    SET NOCOUNT ON;

    IF @Top IS NULL OR @Top <= 0
        SET @Top = 500;

    SELECT TOP (@Top)
        cs.ConfigChangeSetId,
        cs.ChangeStatus,
        cs.RequestedBy,
        cs.RequestedAtUtc,
        cs.ApprovedBy,
        cs.ApprovedAtUtc,
        cs.PublishedBy,
        cs.PublishedAtUtc,
        cs.ChangeReason,
        cs.ValidationStatus,
        cs.ValidationSummary,
        ItemCount = COUNT(DISTINCT ci.ConfigChangeItemId),
        FieldCount = COUNT(cf.ConfigChangeFieldId),
        AdvancedFieldCount = SUM(CONVERT(int, CASE WHEN cf.IsAdvancedField = 1 THEN 1 ELSE 0 END))
    FROM arch.ConfigChangeSet cs
    LEFT JOIN arch.ConfigChangeItem ci
      ON ci.ConfigChangeSetId = cs.ConfigChangeSetId
    LEFT JOIN arch.ConfigChangeField cf
      ON cf.ConfigChangeItemId = ci.ConfigChangeItemId
    WHERE (@ConfigChangeSetId IS NULL OR cs.ConfigChangeSetId = @ConfigChangeSetId)
      AND (@DateFromUtc IS NULL OR cs.RequestedAtUtc >= @DateFromUtc)
      AND (@DateToUtc IS NULL OR cs.RequestedAtUtc < @DateToUtc)
      AND (@RequestedBy IS NULL OR cs.RequestedBy = @RequestedBy)
      AND (@EntityType IS NULL OR ci.EntityType = @EntityType)
      AND (@EntityKey IS NULL OR ci.EntityKey = @EntityKey)
      AND (@ChangeStatus IS NULL OR cs.ChangeStatus = @ChangeStatus)
    GROUP BY
        cs.ConfigChangeSetId,
        cs.ChangeStatus,
        cs.RequestedBy,
        cs.RequestedAtUtc,
        cs.ApprovedBy,
        cs.ApprovedAtUtc,
        cs.PublishedBy,
        cs.PublishedAtUtc,
        cs.ChangeReason,
        cs.ValidationStatus,
        cs.ValidationSummary
    ORDER BY
        cs.RequestedAtUtc DESC,
        cs.ConfigChangeSetId DESC;

    IF @ConfigChangeSetId IS NOT NULL
    BEGIN
        SELECT
            ci.ConfigChangeItemId,
            ci.ConfigChangeSetId,
            ci.EntityType,
            ci.EntityKey,
            ci.Operation,
            ci.ObjectId,
            ci.CreatedAtUtc,
            cf.ConfigChangeFieldId,
            cf.FieldName,
            cf.OldValue,
            cf.NewValue,
            cf.IsAdvancedField
        FROM arch.ConfigChangeItem ci
        LEFT JOIN arch.ConfigChangeField cf
          ON cf.ConfigChangeItemId = ci.ConfigChangeItemId
        WHERE ci.ConfigChangeSetId = @ConfigChangeSetId
        ORDER BY
            ci.ConfigChangeItemId,
            cf.ConfigChangeFieldId;
    END;
END
GO

