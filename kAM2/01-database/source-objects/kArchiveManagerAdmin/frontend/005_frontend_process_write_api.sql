USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveProcess]
    @ProcessCode nvarchar(50),
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @Description nvarchar(200) = NULL,
    @IsEnabled bit = 1,
    @Mode tinyint = 1,
    @RetentionDays int = 540,
    @CutoffSafetyLagMinutes int = 1440,
    @BatchDocCount int = NULL,
    @BatchRowCount int = NULL,
    @MaxBatchesPerRun int = 50,
    @DelayMsBetweenBatches int = 0,
    @UseAppLock bit = 1,
    @AppLockResource nvarchar(200) = NULL,
    @LockTimeoutMs int = 10000,
    @DeadlockPriority nvarchar(10) = N'LOW',
    @AnchorSchema sysname = NULL,
    @AnchorTable sysname = NULL,
    @AnchorDocKeyExpr nvarchar(4000) = NULL,
    @AnchorDocKey2Expr nvarchar(4000) = NULL,
    @AnchorTimestampExpr nvarchar(4000) = NULL,
    @AnchorExtraWhereSql nvarchar(4000) = NULL,
    @AllowDeleteWithoutArchive bit = 0,
    @CutoffMode tinyint = 0,
    @CutoffDate datetime2(0) = NULL,
    @DocKeyLabel nvarchar(50) = N'DOCKEY',
    @AuditLevel nvarchar(20) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ProcessCode = NULLIF(LTRIM(RTRIM(@ProcessCode)), N'');
    SET @AuditLevel = UPPER(NULLIF(LTRIM(RTRIM(@AuditLevel)), N''));   -- T-08: base process audit level

    IF @AuditLevel IS NOT NULL AND @AuditLevel NOT IN (N'NONE', N'BATCH', N'OBJECT', N'ROW')
        THROW 56508, 'AuditLevel must be NONE, BATCH, OBJECT, or ROW.', 1;
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;
    SET @DeadlockPriority = COALESCE(UPPER(NULLIF(LTRIM(RTRIM(@DeadlockPriority)), N'')), N'LOW');
    SET @DocKeyLabel = COALESCE(NULLIF(LTRIM(RTRIM(@DocKeyLabel)), N''), N'DOCKEY');

    IF @ProcessCode IS NULL
        THROW 56500, 'ProcessCode is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56501, 'RequestedBy is required.', 1;

    IF @IsEnabled IS NULL
       OR @Mode IS NULL
       OR @RetentionDays IS NULL
       OR @CutoffSafetyLagMinutes IS NULL
       OR @MaxBatchesPerRun IS NULL
       OR @DelayMsBetweenBatches IS NULL
       OR @UseAppLock IS NULL
       OR @LockTimeoutMs IS NULL
       OR @AllowDeleteWithoutArchive IS NULL
       OR @CutoffMode IS NULL
        THROW 56507, 'Required process values must not be NULL.', 1;

    IF @Mode NOT IN (0, 1, 2)
        THROW 56502, 'Mode must be 0 (delete-only), 1 (archive+delete) or 2 (copy-only).', 1;

    IF @CutoffMode NOT IN (0, 1)
        THROW 56503, 'CutoffMode must be 0 or 1.', 1;

    IF @RetentionDays < 0
       OR @CutoffSafetyLagMinutes < 0
       OR (@BatchDocCount IS NOT NULL AND @BatchDocCount <= 0)
       OR (@BatchRowCount IS NOT NULL AND @BatchRowCount <= 0)
       OR @MaxBatchesPerRun <= 0
       OR @DelayMsBetweenBatches < 0
       OR @LockTimeoutMs < 0
        THROW 56504, 'Process numeric limits are invalid.', 1;

    IF @DeadlockPriority NOT IN (N'LOW', N'NORMAL', N'HIGH')
        THROW 56505, 'DeadlockPriority must be LOW, NORMAL, or HIGH.', 1;

    -- T-05: validate the advanced free-text expressions before persisting — they are concatenated
    -- into the runner's dynamic candidate/DELETE SQL against production source databases.
    EXEC arch.usp_AssertSafeSqlExpression @AnchorDocKeyExpr, N'AnchorDocKeyExpr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorDocKey2Expr, N'AnchorDocKey2Expr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorTimestampExpr, N'AnchorTimestampExpr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorExtraWhereSql, N'AnchorExtraWhereSql';

    DECLARE
        @Operation nvarchar(20),
        @ProcessId int,
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldDescription nvarchar(200),
        @OldIsEnabled bit,
        @OldMode tinyint,
        @OldRetentionDays int,
        @OldCutoffSafetyLagMinutes int,
        @OldBatchDocCount int,
        @OldBatchRowCount int,
        @OldMaxBatchesPerRun int,
        @OldDelayMsBetweenBatches int,
        @OldUseAppLock bit,
        @OldAppLockResource nvarchar(200),
        @OldLockTimeoutMs int,
        @OldDeadlockPriority nvarchar(10),
        @OldAnchorSchema sysname,
        @OldAnchorTable sysname,
        @OldAnchorDocKeyExpr nvarchar(4000),
        @OldAnchorDocKey2Expr nvarchar(4000),
        @OldAnchorTimestampExpr nvarchar(4000),
        @OldAnchorExtraWhereSql nvarchar(4000),
        @OldAllowDeleteWithoutArchive bit,
        @OldCutoffMode tinyint,
        @OldCutoffDate datetime2(0),
        @OldDocKeyLabel nvarchar(50),
        @OldAuditLevel nvarchar(20);

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
        THROW 56506, 'ConfigChangeSetId does not exist.', 1;

    SELECT
        @ProcessId = ProcessId,
        @OldDescription = Description,
        @OldIsEnabled = IsEnabled,
        @OldMode = Mode,
        @OldRetentionDays = RetentionDays,
        @OldCutoffSafetyLagMinutes = CutoffSafetyLagMinutes,
        @OldBatchDocCount = BatchDocCount,
        @OldBatchRowCount = BatchRowCount,
        @OldMaxBatchesPerRun = MaxBatchesPerRun,
        @OldDelayMsBetweenBatches = DelayMsBetweenBatches,
        @OldUseAppLock = UseAppLock,
        @OldAppLockResource = AppLockResource,
        @OldLockTimeoutMs = LockTimeoutMs,
        @OldDeadlockPriority = DeadlockPriority,
        @OldAnchorSchema = AnchorSchema,
        @OldAnchorTable = AnchorTable,
        @OldAnchorDocKeyExpr = AnchorDocKeyExpr,
        @OldAnchorDocKey2Expr = AnchorDocKey2Expr,
        @OldAnchorTimestampExpr = AnchorTimestampExpr,
        @OldAnchorExtraWhereSql = AnchorExtraWhereSql,
        @OldAllowDeleteWithoutArchive = AllowDeleteWithoutArchive,
        @OldCutoffMode = CutoffMode,
        @OldCutoffDate = CutoffDate,
        @OldDocKeyLabel = DocKeyLabel,
        @OldAuditLevel = AuditLevel
    FROM arch.Process
    WHERE ProcessCode = @ProcessCode;

    SET @Operation = CASE WHEN @ProcessId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode;

    IF @ProcessId IS NULL
    BEGIN
        INSERT INTO arch.Process
        (
            ProcessCode,
            Description,
            IsEnabled,
            Mode,
            RetentionDays,
            CutoffSafetyLagMinutes,
            BatchDocCount,
            BatchRowCount,
            MaxBatchesPerRun,
            DelayMsBetweenBatches,
            UseAppLock,
            AppLockResource,
            LockTimeoutMs,
            DeadlockPriority,
            AnchorSchema,
            AnchorTable,
            AnchorDocKeyExpr,
            AnchorDocKey2Expr,
            AnchorTimestampExpr,
            AnchorExtraWhereSql,
            AllowDeleteWithoutArchive,
            CreatedAt,
            ModifiedAt,
            CutoffMode,
            CutoffDate,
            DocKeyLabel,
            AuditLevel
        )
        VALUES
        (
            @ProcessCode,
            @Description,
            @IsEnabled,
            @Mode,
            @RetentionDays,
            @CutoffSafetyLagMinutes,
            @BatchDocCount,
            @BatchRowCount,
            @MaxBatchesPerRun,
            @DelayMsBetweenBatches,
            @UseAppLock,
            @AppLockResource,
            @LockTimeoutMs,
            @DeadlockPriority,
            @AnchorSchema,
            @AnchorTable,
            @AnchorDocKeyExpr,
            @AnchorDocKey2Expr,
            @AnchorTimestampExpr,
            @AnchorExtraWhereSql,
            @AllowDeleteWithoutArchive,
            @Now,
            @Now,
            @CutoffMode,
            @CutoffDate,
            @DocKeyLabel,
            @AuditLevel
        );

        SET @ProcessId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.Process
        SET
            Description = @Description,
            IsEnabled = @IsEnabled,
            Mode = @Mode,
            RetentionDays = @RetentionDays,
            CutoffSafetyLagMinutes = @CutoffSafetyLagMinutes,
            BatchDocCount = @BatchDocCount,
            BatchRowCount = @BatchRowCount,
            MaxBatchesPerRun = @MaxBatchesPerRun,
            DelayMsBetweenBatches = @DelayMsBetweenBatches,
            UseAppLock = @UseAppLock,
            AppLockResource = @AppLockResource,
            LockTimeoutMs = @LockTimeoutMs,
            DeadlockPriority = @DeadlockPriority,
            AnchorSchema = @AnchorSchema,
            AnchorTable = @AnchorTable,
            AnchorDocKeyExpr = @AnchorDocKeyExpr,
            AnchorDocKey2Expr = @AnchorDocKey2Expr,
            AnchorTimestampExpr = @AnchorTimestampExpr,
            AnchorExtraWhereSql = @AnchorExtraWhereSql,
            AllowDeleteWithoutArchive = @AllowDeleteWithoutArchive,
            ModifiedAt = @Now,
            CutoffMode = @CutoffMode,
            CutoffDate = @CutoffDate,
            DocKeyLabel = @DocKeyLabel,
            AuditLevel = @AuditLevel
        WHERE ProcessId = @ProcessId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessCode', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ProcessCode END, @ProcessCode, 0),
        (N'Description', @OldDescription, @Description, 0),
        (N'IsEnabled', CONVERT(nvarchar(30), @OldIsEnabled), CONVERT(nvarchar(30), @IsEnabled), 0),
        (N'Mode', CONVERT(nvarchar(30), @OldMode), CONVERT(nvarchar(30), @Mode), 0),
        (N'RetentionDays', CONVERT(nvarchar(30), @OldRetentionDays), CONVERT(nvarchar(30), @RetentionDays), 0),
        (N'CutoffSafetyLagMinutes', CONVERT(nvarchar(30), @OldCutoffSafetyLagMinutes), CONVERT(nvarchar(30), @CutoffSafetyLagMinutes), 0),
        (N'BatchDocCount', CONVERT(nvarchar(30), @OldBatchDocCount), CONVERT(nvarchar(30), @BatchDocCount), 0),
        (N'BatchRowCount', CONVERT(nvarchar(30), @OldBatchRowCount), CONVERT(nvarchar(30), @BatchRowCount), 0),
        (N'MaxBatchesPerRun', CONVERT(nvarchar(30), @OldMaxBatchesPerRun), CONVERT(nvarchar(30), @MaxBatchesPerRun), 0),
        (N'DelayMsBetweenBatches', CONVERT(nvarchar(30), @OldDelayMsBetweenBatches), CONVERT(nvarchar(30), @DelayMsBetweenBatches), 0),
        (N'UseAppLock', CONVERT(nvarchar(30), @OldUseAppLock), CONVERT(nvarchar(30), @UseAppLock), 1),
        (N'AppLockResource', @OldAppLockResource, @AppLockResource, 1),
        (N'LockTimeoutMs', CONVERT(nvarchar(30), @OldLockTimeoutMs), CONVERT(nvarchar(30), @LockTimeoutMs), 1),
        (N'DeadlockPriority', @OldDeadlockPriority, @DeadlockPriority, 1),
        (N'AnchorSchema', @OldAnchorSchema, @AnchorSchema, 1),
        (N'AnchorTable', @OldAnchorTable, @AnchorTable, 1),
        (N'AnchorDocKeyExpr', @OldAnchorDocKeyExpr, @AnchorDocKeyExpr, 1),
        (N'AnchorDocKey2Expr', @OldAnchorDocKey2Expr, @AnchorDocKey2Expr, 1),
        (N'AnchorTimestampExpr', @OldAnchorTimestampExpr, @AnchorTimestampExpr, 1),
        (N'AnchorExtraWhereSql', @OldAnchorExtraWhereSql, @AnchorExtraWhereSql, 1),
        (N'AllowDeleteWithoutArchive', CONVERT(nvarchar(30), @OldAllowDeleteWithoutArchive), CONVERT(nvarchar(30), @AllowDeleteWithoutArchive), 1),
        (N'CutoffMode', CONVERT(nvarchar(30), @OldCutoffMode), CONVERT(nvarchar(30), @CutoffMode), 0),
        (N'CutoffDate', CONVERT(nvarchar(30), @OldCutoffDate, 126), CONVERT(nvarchar(30), @CutoffDate, 126), 0),
        (N'DocKeyLabel', @OldDocKeyLabel, @DocKeyLabel, 0),
        (N'AuditLevel', @OldAuditLevel, @AuditLevel, 0);

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
            N'Process',
            @EntityKey,
            @Operation,
            @ProcessId,
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
        ValidationSummary = N'Process configuration saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        p.ProcessId,
        p.ProcessCode,
        p.Description,
        p.IsEnabled,
        p.Mode,
        p.RetentionDays,
        p.CutoffSafetyLagMinutes,
        p.BatchDocCount,
        p.BatchRowCount,
        p.MaxBatchesPerRun,
        p.DelayMsBetweenBatches,
        p.UseAppLock,
        p.AppLockResource,
        p.LockTimeoutMs,
        p.DeadlockPriority,
        p.AnchorSchema,
        p.AnchorTable,
        p.AnchorDocKeyExpr,
        p.AnchorDocKey2Expr,
        p.AnchorTimestampExpr,
        p.AnchorExtraWhereSql,
        p.AllowDeleteWithoutArchive,
        p.CutoffMode,
        p.CutoffDate,
        p.DocKeyLabel,
        p.ModifiedAt
    FROM arch.Process p
    WHERE p.ProcessId = @ProcessId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveProcessDatabase]
    @ProcessCode nvarchar(50),
    @SourceDb sysname,
    @ArchiveDb sysname,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @IsEnabled bit = 1,
    @RunOrder int = 100,
    @Mode tinyint = NULL,
    @RetentionDays int = NULL,
    @CutoffSafetyLagMinutes int = NULL,
    @CutoffMode tinyint = NULL,
    @CutoffDate datetime2(0) = NULL,
    @BatchDocCount int = NULL,
    @BatchRowCount int = NULL,
    @MaxBatchesPerRun int = NULL,
    @DelayMsBetweenBatches int = NULL,
    @UseAppLock bit = NULL,
    @AppLockResource nvarchar(200) = NULL,
    @LockTimeoutMs int = NULL,
    @DeadlockPriority nvarchar(10) = NULL,
    @AnchorSchema sysname = NULL,
    @AnchorTable sysname = NULL,
    @AnchorDocKeyExpr nvarchar(4000) = NULL,
    @AnchorDocKey2Expr nvarchar(4000) = NULL,
    @AnchorTimestampExpr nvarchar(4000) = NULL,
    @AnchorExtraWhereSql nvarchar(4000) = NULL,
    @AllowDeleteWithoutArchive bit = NULL,
    @DocKeyLabel nvarchar(50) = NULL,
    @AuditLevel nvarchar(20) = NULL,
    @RequireSupportingIndex bit = NULL,
    @MaxRowsPerTransaction int = NULL,
    @CandidateWhereSql nvarchar(4000) = NULL,
    @CandidateOrderSql nvarchar(4000) = NULL,
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
    SET @DeadlockPriority = UPPER(NULLIF(LTRIM(RTRIM(@DeadlockPriority)), N''));
    SET @AuditLevel = UPPER(NULLIF(LTRIM(RTRIM(@AuditLevel)), N''));
    SET @DocKeyLabel = NULLIF(LTRIM(RTRIM(@DocKeyLabel)), N'');

    IF @ProcessCode IS NULL
        THROW 56520, 'ProcessCode is required.', 1;

    IF @SourceDb IS NULL
        THROW 56521, 'SourceDb is required.', 1;

    IF @ArchiveDb IS NULL
        THROW 56522, 'ArchiveDb is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56523, 'RequestedBy is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56530, 'IsEnabled is required.', 1;

    IF @RunOrder IS NULL
        THROW 56524, 'RunOrder is required.', 1;

    IF (@Mode IS NOT NULL AND @Mode NOT IN (0, 1, 2))
       OR (@CutoffMode IS NOT NULL AND @CutoffMode NOT IN (0, 1))
       OR (@RetentionDays IS NOT NULL AND @RetentionDays < 0)
       OR (@CutoffSafetyLagMinutes IS NOT NULL AND @CutoffSafetyLagMinutes < 0)
       OR (@BatchDocCount IS NOT NULL AND @BatchDocCount <= 0)
       OR (@BatchRowCount IS NOT NULL AND @BatchRowCount <= 0)
       OR (@MaxBatchesPerRun IS NOT NULL AND @MaxBatchesPerRun <= 0)
       OR (@DelayMsBetweenBatches IS NOT NULL AND @DelayMsBetweenBatches < 0)
       OR (@LockTimeoutMs IS NOT NULL AND @LockTimeoutMs < 0)
       OR (@MaxRowsPerTransaction IS NOT NULL AND @MaxRowsPerTransaction <= 0)
        THROW 56525, 'ProcessDatabase override limits are invalid.', 1;

    IF @DeadlockPriority IS NOT NULL AND @DeadlockPriority NOT IN (N'LOW', N'NORMAL', N'HIGH')
        THROW 56526, 'DeadlockPriority must be LOW, NORMAL, or HIGH.', 1;

    IF @AuditLevel IS NOT NULL AND @AuditLevel NOT IN (N'NONE', N'BATCH', N'OBJECT', N'ROW')
        THROW 56527, 'AuditLevel must be NONE, BATCH, OBJECT, or ROW.', 1;

    -- T-05: validate the advanced free-text override expressions before persisting — they feed the
    -- runner's dynamic candidate/DELETE SQL against production source databases.
    EXEC arch.usp_AssertSafeSqlExpression @AnchorDocKeyExpr, N'AnchorDocKeyExpr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorDocKey2Expr, N'AnchorDocKey2Expr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorTimestampExpr, N'AnchorTimestampExpr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorExtraWhereSql, N'AnchorExtraWhereSql';
    EXEC arch.usp_AssertSafeSqlExpression @CandidateWhereSql, N'CandidateWhereSql';
    EXEC arch.usp_AssertSafeSqlExpression @CandidateOrderSql, N'CandidateOrderSql';

    DECLARE
        @Operation nvarchar(20),
        @ProcessId int,
        @ProcessDatabaseId int,
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldIsEnabled bit,
        @OldRunOrder int,
        @OldMode tinyint,
        @OldRetentionDays int,
        @OldCutoffSafetyLagMinutes int,
        @OldCutoffMode tinyint,
        @OldCutoffDate datetime2(0),
        @OldBatchDocCount int,
        @OldBatchRowCount int,
        @OldMaxBatchesPerRun int,
        @OldDelayMsBetweenBatches int,
        @OldUseAppLock bit,
        @OldAppLockResource nvarchar(200),
        @OldLockTimeoutMs int,
        @OldDeadlockPriority nvarchar(10),
        @OldAnchorSchema sysname,
        @OldAnchorTable sysname,
        @OldAnchorDocKeyExpr nvarchar(4000),
        @OldAnchorDocKey2Expr nvarchar(4000),
        @OldAnchorTimestampExpr nvarchar(4000),
        @OldAnchorExtraWhereSql nvarchar(4000),
        @OldAllowDeleteWithoutArchive bit,
        @OldDocKeyLabel nvarchar(50),
        @OldAuditLevel nvarchar(20),
        @OldRequireSupportingIndex bit,
        @OldMaxRowsPerTransaction int,
        @OldCandidateWhereSql nvarchar(4000),
        @OldCandidateOrderSql nvarchar(4000);

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
        THROW 56528, 'ProcessCode does not exist.', 1;

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
        THROW 56529, 'ConfigChangeSetId does not exist.', 1;

    SELECT
        @ProcessDatabaseId = ProcessDatabaseId,
        @OldIsEnabled = IsEnabled,
        @OldRunOrder = RunOrder,
        @OldMode = Mode,
        @OldRetentionDays = RetentionDays,
        @OldCutoffSafetyLagMinutes = CutoffSafetyLagMinutes,
        @OldCutoffMode = CutoffMode,
        @OldCutoffDate = CutoffDate,
        @OldBatchDocCount = BatchDocCount,
        @OldBatchRowCount = BatchRowCount,
        @OldMaxBatchesPerRun = MaxBatchesPerRun,
        @OldDelayMsBetweenBatches = DelayMsBetweenBatches,
        @OldUseAppLock = UseAppLock,
        @OldAppLockResource = AppLockResource,
        @OldLockTimeoutMs = LockTimeoutMs,
        @OldDeadlockPriority = DeadlockPriority,
        @OldAnchorSchema = AnchorSchema,
        @OldAnchorTable = AnchorTable,
        @OldAnchorDocKeyExpr = AnchorDocKeyExpr,
        @OldAnchorDocKey2Expr = AnchorDocKey2Expr,
        @OldAnchorTimestampExpr = AnchorTimestampExpr,
        @OldAnchorExtraWhereSql = AnchorExtraWhereSql,
        @OldAllowDeleteWithoutArchive = AllowDeleteWithoutArchive,
        @OldDocKeyLabel = DocKeyLabel,
        @OldAuditLevel = AuditLevel,
        @OldRequireSupportingIndex = RequireSupportingIndex,
        @OldMaxRowsPerTransaction = MaxRowsPerTransaction,
        @OldCandidateWhereSql = CandidateWhereSql,
        @OldCandidateOrderSql = CandidateOrderSql
    FROM arch.ProcessDatabase
    WHERE ProcessId = @ProcessId
      AND SourceDb = @SourceDb
      AND ArchiveDb = @ArchiveDb;

    SET @Operation = CASE WHEN @ProcessDatabaseId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + @SourceDb + N'|' + @ArchiveDb;

    IF @ProcessDatabaseId IS NULL
    BEGIN
        INSERT INTO arch.ProcessDatabase
        (
            ProcessId,
            SourceDb,
            ArchiveDb,
            IsEnabled,
            RunOrder,
            Mode,
            RetentionDays,
            CutoffSafetyLagMinutes,
            CutoffMode,
            CutoffDate,
            BatchDocCount,
            BatchRowCount,
            MaxBatchesPerRun,
            DelayMsBetweenBatches,
            UseAppLock,
            AppLockResource,
            LockTimeoutMs,
            DeadlockPriority,
            AnchorSchema,
            AnchorTable,
            AnchorDocKeyExpr,
            AnchorDocKey2Expr,
            AnchorTimestampExpr,
            AnchorExtraWhereSql,
            AllowDeleteWithoutArchive,
            DocKeyLabel,
            AuditLevel,
            RequireSupportingIndex,
            MaxRowsPerTransaction,
            CandidateWhereSql,
            CandidateOrderSql,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @ProcessId,
            @SourceDb,
            @ArchiveDb,
            @IsEnabled,
            @RunOrder,
            @Mode,
            @RetentionDays,
            @CutoffSafetyLagMinutes,
            @CutoffMode,
            @CutoffDate,
            @BatchDocCount,
            @BatchRowCount,
            @MaxBatchesPerRun,
            @DelayMsBetweenBatches,
            @UseAppLock,
            @AppLockResource,
            @LockTimeoutMs,
            @DeadlockPriority,
            @AnchorSchema,
            @AnchorTable,
            @AnchorDocKeyExpr,
            @AnchorDocKey2Expr,
            @AnchorTimestampExpr,
            @AnchorExtraWhereSql,
            @AllowDeleteWithoutArchive,
            @DocKeyLabel,
            @AuditLevel,
            @RequireSupportingIndex,
            @MaxRowsPerTransaction,
            @CandidateWhereSql,
            @CandidateOrderSql,
            @Now,
            @Now
        );

        SET @ProcessDatabaseId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.ProcessDatabase
        SET
            IsEnabled = @IsEnabled,
            RunOrder = @RunOrder,
            Mode = @Mode,
            RetentionDays = @RetentionDays,
            CutoffSafetyLagMinutes = @CutoffSafetyLagMinutes,
            CutoffMode = @CutoffMode,
            CutoffDate = @CutoffDate,
            BatchDocCount = @BatchDocCount,
            BatchRowCount = @BatchRowCount,
            MaxBatchesPerRun = @MaxBatchesPerRun,
            DelayMsBetweenBatches = @DelayMsBetweenBatches,
            UseAppLock = @UseAppLock,
            AppLockResource = @AppLockResource,
            LockTimeoutMs = @LockTimeoutMs,
            DeadlockPriority = @DeadlockPriority,
            AnchorSchema = @AnchorSchema,
            AnchorTable = @AnchorTable,
            AnchorDocKeyExpr = @AnchorDocKeyExpr,
            AnchorDocKey2Expr = @AnchorDocKey2Expr,
            AnchorTimestampExpr = @AnchorTimestampExpr,
            AnchorExtraWhereSql = @AnchorExtraWhereSql,
            AllowDeleteWithoutArchive = @AllowDeleteWithoutArchive,
            DocKeyLabel = @DocKeyLabel,
            AuditLevel = @AuditLevel,
            RequireSupportingIndex = @RequireSupportingIndex,
            MaxRowsPerTransaction = @MaxRowsPerTransaction,
            CandidateWhereSql = @CandidateWhereSql,
            CandidateOrderSql = @CandidateOrderSql,
            ModifiedAt = @Now
        WHERE ProcessDatabaseId = @ProcessDatabaseId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessCode', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ProcessCode END, @ProcessCode, 0),
        (N'SourceDb', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @SourceDb END, @SourceDb, 0),
        (N'ArchiveDb', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ArchiveDb END, @ArchiveDb, 0),
        (N'IsEnabled', CONVERT(nvarchar(30), @OldIsEnabled), CONVERT(nvarchar(30), @IsEnabled), 0),
        (N'RunOrder', CONVERT(nvarchar(30), @OldRunOrder), CONVERT(nvarchar(30), @RunOrder), 0),
        (N'Mode', CONVERT(nvarchar(30), @OldMode), CONVERT(nvarchar(30), @Mode), 0),
        (N'RetentionDays', CONVERT(nvarchar(30), @OldRetentionDays), CONVERT(nvarchar(30), @RetentionDays), 0),
        (N'CutoffSafetyLagMinutes', CONVERT(nvarchar(30), @OldCutoffSafetyLagMinutes), CONVERT(nvarchar(30), @CutoffSafetyLagMinutes), 0),
        (N'CutoffMode', CONVERT(nvarchar(30), @OldCutoffMode), CONVERT(nvarchar(30), @CutoffMode), 0),
        (N'CutoffDate', CONVERT(nvarchar(30), @OldCutoffDate, 126), CONVERT(nvarchar(30), @CutoffDate, 126), 0),
        (N'BatchDocCount', CONVERT(nvarchar(30), @OldBatchDocCount), CONVERT(nvarchar(30), @BatchDocCount), 0),
        (N'BatchRowCount', CONVERT(nvarchar(30), @OldBatchRowCount), CONVERT(nvarchar(30), @BatchRowCount), 0),
        (N'MaxBatchesPerRun', CONVERT(nvarchar(30), @OldMaxBatchesPerRun), CONVERT(nvarchar(30), @MaxBatchesPerRun), 0),
        (N'DelayMsBetweenBatches', CONVERT(nvarchar(30), @OldDelayMsBetweenBatches), CONVERT(nvarchar(30), @DelayMsBetweenBatches), 0),
        (N'UseAppLock', CONVERT(nvarchar(30), @OldUseAppLock), CONVERT(nvarchar(30), @UseAppLock), 1),
        (N'AppLockResource', @OldAppLockResource, @AppLockResource, 1),
        (N'LockTimeoutMs', CONVERT(nvarchar(30), @OldLockTimeoutMs), CONVERT(nvarchar(30), @LockTimeoutMs), 1),
        (N'DeadlockPriority', @OldDeadlockPriority, @DeadlockPriority, 1),
        (N'AnchorSchema', @OldAnchorSchema, @AnchorSchema, 1),
        (N'AnchorTable', @OldAnchorTable, @AnchorTable, 1),
        (N'AnchorDocKeyExpr', @OldAnchorDocKeyExpr, @AnchorDocKeyExpr, 1),
        (N'AnchorDocKey2Expr', @OldAnchorDocKey2Expr, @AnchorDocKey2Expr, 1),
        (N'AnchorTimestampExpr', @OldAnchorTimestampExpr, @AnchorTimestampExpr, 1),
        (N'AnchorExtraWhereSql', @OldAnchorExtraWhereSql, @AnchorExtraWhereSql, 1),
        (N'AllowDeleteWithoutArchive', CONVERT(nvarchar(30), @OldAllowDeleteWithoutArchive), CONVERT(nvarchar(30), @AllowDeleteWithoutArchive), 1),
        (N'DocKeyLabel', @OldDocKeyLabel, @DocKeyLabel, 0),
        (N'AuditLevel', @OldAuditLevel, @AuditLevel, 1),
        (N'RequireSupportingIndex', CONVERT(nvarchar(30), @OldRequireSupportingIndex), CONVERT(nvarchar(30), @RequireSupportingIndex), 1),
        (N'MaxRowsPerTransaction', CONVERT(nvarchar(30), @OldMaxRowsPerTransaction), CONVERT(nvarchar(30), @MaxRowsPerTransaction), 1),
        (N'CandidateWhereSql', @OldCandidateWhereSql, @CandidateWhereSql, 1),
        (N'CandidateOrderSql', @OldCandidateOrderSql, @CandidateOrderSql, 1);

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
            N'ProcessDatabase',
            @EntityKey,
            @Operation,
            @ProcessDatabaseId,
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
        ValidationSummary = N'Process database mapping saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        pd.ProcessDatabaseId,
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        pd.IsEnabled,
        pd.RunOrder,
        pd.Mode,
        pd.RetentionDays,
        pd.CutoffSafetyLagMinutes,
        pd.CutoffMode,
        pd.CutoffDate,
        pd.BatchDocCount,
        pd.BatchRowCount,
        pd.MaxBatchesPerRun,
        pd.DelayMsBetweenBatches,
        pd.UseAppLock,
        pd.AppLockResource,
        pd.LockTimeoutMs,
        pd.DeadlockPriority,
        pd.AnchorSchema,
        pd.AnchorTable,
        pd.AnchorDocKeyExpr,
        pd.AnchorDocKey2Expr,
        pd.AnchorTimestampExpr,
        pd.AnchorExtraWhereSql,
        pd.AllowDeleteWithoutArchive,
        pd.DocKeyLabel,
        pd.AuditLevel,
        pd.RequireSupportingIndex,
        pd.MaxRowsPerTransaction,
        pd.CandidateWhereSql,
        pd.CandidateOrderSql,
        pd.ModifiedAt
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    WHERE pd.ProcessDatabaseId = @ProcessDatabaseId;
END
GO
