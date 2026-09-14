USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID(N'arch.ProcessDatabase', N'U') IS NULL
BEGIN
    RAISERROR(N'arch.ProcessDatabase does not exist. Run v2 core scripts first.', 16, 1);
    RETURN;
END
GO

IF COL_LENGTH(N'arch.ProcessDatabase', N'Mode') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [Mode] [tinyint] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'RetentionDays') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [RetentionDays] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'CutoffSafetyLagMinutes') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [CutoffSafetyLagMinutes] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'CutoffMode') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [CutoffMode] [tinyint] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'CutoffDate') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [CutoffDate] [datetime2](0) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'BatchDocCount') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [BatchDocCount] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'BatchRowCount') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [BatchRowCount] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'MaxBatchesPerRun') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [MaxBatchesPerRun] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'DelayMsBetweenBatches') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [DelayMsBetweenBatches] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'UseAppLock') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [UseAppLock] [bit] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AppLockResource') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AppLockResource] [nvarchar](200) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'LockTimeoutMs') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [LockTimeoutMs] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'DeadlockPriority') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [DeadlockPriority] [nvarchar](10) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorSchema') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorSchema] [sysname] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorTable') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorTable] [sysname] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorDocKeyExpr') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorDocKeyExpr] [nvarchar](4000) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorDocKey2Expr') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorDocKey2Expr] [nvarchar](4000) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorTimestampExpr') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorTimestampExpr] [nvarchar](4000) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorExtraWhereSql') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorExtraWhereSql] [nvarchar](4000) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AllowDeleteWithoutArchive') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AllowDeleteWithoutArchive] [bit] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'DocKeyLabel') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [DocKeyLabel] [nvarchar](50) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AuditLevel') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AuditLevel] [nvarchar](20) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'RequireSupportingIndex') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [RequireSupportingIndex] [bit] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'MaxRowsPerTransaction') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [MaxRowsPerTransaction] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'CandidateWhereSql') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [CandidateWhereSql] [nvarchar](4000) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'CandidateOrderSql') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [CandidateOrderSql] [nvarchar](4000) NULL;
GO

IF OBJECT_ID(N'arch.ObjectSpecDatabaseOverride', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ObjectSpecDatabaseOverride](
        [ObjectSpecDatabaseOverrideId] [int] IDENTITY(1,1) NOT NULL,
        [ProcessDatabaseId] [int] NOT NULL,
        [ObjectSpecId] [int] NOT NULL,
        [IsEnabled] [bit] NOT NULL,
        [SourceSchemaOverride] [sysname] NULL,
        [SourceTableOverride] [sysname] NULL,
        [TimestampExprOverride] [nvarchar](4000) NULL,
        [JoinToAnchorPredicateSqlOverride] [nvarchar](4000) NULL,
        [AdditionalWhereSqlOverride] [nvarchar](4000) NULL,
        [ArchiveSchemaOverride] [sysname] NULL,
        [ArchiveTableOverride] [sysname] NULL,
        [RequireArchiveForDeleteOverride] [bit] NULL,
        [CreatedAt] [datetime2](0) NOT NULL,
        [ModifiedAt] [datetime2](0) NOT NULL,
        CONSTRAINT [PK_ObjectSpecDatabaseOverride] PRIMARY KEY CLUSTERED ([ObjectSpecDatabaseOverrideId] ASC),
        CONSTRAINT [UQ_ObjectSpecDatabaseOverride] UNIQUE NONCLUSTERED ([ProcessDatabaseId] ASC, [ObjectSpecId] ASC),
        CONSTRAINT [FK_ObjectSpecDatabaseOverride_ProcessDatabase] FOREIGN KEY([ProcessDatabaseId]) REFERENCES [arch].[ProcessDatabase] ([ProcessDatabaseId]),
        CONSTRAINT [FK_ObjectSpecDatabaseOverride_ObjectSpec] FOREIGN KEY([ObjectSpecId]) REFERENCES [arch].[ObjectSpec] ([ObjectSpecId])
    );

    ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_IsEnabled] DEFAULT ((1)) FOR [IsEnabled];
    ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt];
    ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt];
END
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'arch.ProcessDatabase')
      AND name = N'CK_ProcessDatabase_OverrideLimits'
)
BEGIN
    ALTER TABLE [arch].[ProcessDatabase] WITH CHECK ADD CONSTRAINT [CK_ProcessDatabase_OverrideLimits] CHECK
    (
        ([Mode] IS NULL OR [Mode] IN (0, 1, 2))   -- 0 delete-only, 1 archive+delete, 2 copy-only
        AND ([RetentionDays] IS NULL OR [RetentionDays] >= 0)
        AND ([CutoffSafetyLagMinutes] IS NULL OR [CutoffSafetyLagMinutes] >= 0)
        AND ([CutoffMode] IS NULL OR [CutoffMode] IN (0, 1))
        AND ([BatchDocCount] IS NULL OR [BatchDocCount] > 0)
        AND ([BatchRowCount] IS NULL OR [BatchRowCount] > 0)
        AND ([MaxBatchesPerRun] IS NULL OR [MaxBatchesPerRun] > 0)
        AND ([DelayMsBetweenBatches] IS NULL OR [DelayMsBetweenBatches] >= 0)
        AND ([LockTimeoutMs] IS NULL OR [LockTimeoutMs] >= 0)
        AND ([DeadlockPriority] IS NULL OR [DeadlockPriority] IN (N'LOW', N'NORMAL', N'HIGH'))
        AND ([AuditLevel] IS NULL OR [AuditLevel] IN (N'NONE', N'BATCH', N'OBJECT', N'ROW'))
        AND ([MaxRowsPerTransaction] IS NULL OR [MaxRowsPerTransaction] > 0)
    );
    ALTER TABLE [arch].[ProcessDatabase] CHECK CONSTRAINT [CK_ProcessDatabase_OverrideLimits];
END
GO

CREATE OR ALTER VIEW [arch].[v_ProcessDatabaseEffective]
AS
SELECT
    pd.ProcessDatabaseId,
    p.ProcessId,
    p.ProcessCode,
    p.Description,
    SourceDb = pd.SourceDb,
    ArchiveDb = pd.ArchiveDb,
    ProcessIsEnabled = p.IsEnabled,
    MappingIsEnabled = pd.IsEnabled,
    IsEnabled = CONVERT(bit, CASE WHEN p.IsEnabled = 1 AND pd.IsEnabled = 1 THEN 1 ELSE 0 END),
    pd.RunOrder,
    Mode = COALESCE(pd.Mode, p.Mode),
    ModeSource = CONVERT(varchar(20), CASE WHEN pd.Mode IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    RetentionDays = COALESCE(pd.RetentionDays, p.RetentionDays),
    RetentionDaysSource = CONVERT(varchar(20), CASE WHEN pd.RetentionDays IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    CutoffSafetyLagMinutes = COALESCE(pd.CutoffSafetyLagMinutes, p.CutoffSafetyLagMinutes),
    CutoffSafetyLagMinutesSource = CONVERT(varchar(20), CASE WHEN pd.CutoffSafetyLagMinutes IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    CutoffMode = COALESCE(pd.CutoffMode, p.CutoffMode),
    CutoffModeSource = CONVERT(varchar(20), CASE WHEN pd.CutoffMode IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    CutoffDate = COALESCE(pd.CutoffDate, p.CutoffDate),
    CutoffDateSource = CONVERT(varchar(20), CASE WHEN pd.CutoffDate IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    BatchDocCount = COALESCE(pd.BatchDocCount, p.BatchDocCount),
    BatchDocCountSource = CONVERT(varchar(20), CASE WHEN pd.BatchDocCount IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    BatchRowCount = COALESCE(pd.BatchRowCount, p.BatchRowCount),
    BatchRowCountSource = CONVERT(varchar(20), CASE WHEN pd.BatchRowCount IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    MaxBatchesPerRun = COALESCE(pd.MaxBatchesPerRun, p.MaxBatchesPerRun),
    MaxBatchesPerRunSource = CONVERT(varchar(20), CASE WHEN pd.MaxBatchesPerRun IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    DelayMsBetweenBatches = COALESCE(pd.DelayMsBetweenBatches, p.DelayMsBetweenBatches),
    DelayMsBetweenBatchesSource = CONVERT(varchar(20), CASE WHEN pd.DelayMsBetweenBatches IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    UseAppLock = COALESCE(pd.UseAppLock, p.UseAppLock),
    UseAppLockSource = CONVERT(varchar(20), CASE WHEN pd.UseAppLock IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AppLockResource = COALESCE(NULLIF(LTRIM(RTRIM(pd.AppLockResource)), N''), NULLIF(LTRIM(RTRIM(p.AppLockResource)), N'')),
    AppLockResourceSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AppLockResource)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    LockTimeoutMs = COALESCE(pd.LockTimeoutMs, p.LockTimeoutMs),
    LockTimeoutMsSource = CONVERT(varchar(20), CASE WHEN pd.LockTimeoutMs IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    DeadlockPriority = COALESCE(NULLIF(LTRIM(RTRIM(pd.DeadlockPriority)), N''), p.DeadlockPriority),
    DeadlockPrioritySource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.DeadlockPriority)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorSchema = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorSchema)), N''), p.AnchorSchema),
    AnchorSchemaSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorSchema)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorTable = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorTable)), N''), p.AnchorTable),
    AnchorTableSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorTable)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorDocKeyExpr = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorDocKeyExpr)), N''), p.AnchorDocKeyExpr),
    AnchorDocKeyExprSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorDocKeyExpr)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorDocKey2Expr = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorDocKey2Expr)), N''), p.AnchorDocKey2Expr),
    AnchorDocKey2ExprSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorDocKey2Expr)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorTimestampExpr = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorTimestampExpr)), N''), p.AnchorTimestampExpr),
    AnchorTimestampExprSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorTimestampExpr)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorExtraWhereSql = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorExtraWhereSql)), N''), p.AnchorExtraWhereSql),
    AnchorExtraWhereSqlSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorExtraWhereSql)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AllowDeleteWithoutArchive = COALESCE(pd.AllowDeleteWithoutArchive, p.AllowDeleteWithoutArchive),
    AllowDeleteWithoutArchiveSource = CONVERT(varchar(20), CASE WHEN pd.AllowDeleteWithoutArchive IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    DocKeyLabel = COALESCE(NULLIF(LTRIM(RTRIM(pd.DocKeyLabel)), N''), p.DocKeyLabel),
    DocKeyLabelSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.DocKeyLabel)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    SelectionStrategy = COALESCE(p.SelectionStrategy, N'ANCHOR'),
    AuditLevel = COALESCE(NULLIF(LTRIM(RTRIM(pd.AuditLevel)), N''), p.AuditLevel),
    AuditLevelSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AuditLevel)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    RequireSupportingIndex = COALESCE(pd.RequireSupportingIndex, p.RequireSupportingIndex),
    RequireSupportingIndexSource = CONVERT(varchar(20), CASE WHEN pd.RequireSupportingIndex IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    MaxRowsPerTransaction = COALESCE(pd.MaxRowsPerTransaction, p.MaxRowsPerTransaction),
    MaxRowsPerTransactionSource = CONVERT(varchar(20), CASE WHEN pd.MaxRowsPerTransaction IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    CandidateWhereSql = COALESCE(NULLIF(LTRIM(RTRIM(pd.CandidateWhereSql)), N''), p.CandidateWhereSql),
    CandidateWhereSqlSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.CandidateWhereSql)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    CandidateOrderSql = COALESCE(NULLIF(LTRIM(RTRIM(pd.CandidateOrderSql)), N''), p.CandidateOrderSql),
    CandidateOrderSqlSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.CandidateOrderSql)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    ProcessCreatedAt = p.CreatedAt,
    ProcessModifiedAt = p.ModifiedAt,
    MappingCreatedAt = pd.CreatedAt,
    MappingModifiedAt = pd.ModifiedAt
FROM arch.ProcessDatabase AS pd
JOIN arch.Process AS p
  ON p.ProcessId = pd.ProcessId;
GO

-- Perf (high-volume TIMESTAMP, 100M-row sources): optional CHEAP candidate-selection expression. When set,
-- the TIMESTAMP runner (027) selects candidates using THIS expression (e.g. a plain local datetime CONVERT,
-- NO per-row AT TIME ZONE) for the projected timestamp, and takes the cutoff sargably from CandidateWhereSql,
-- so the candidate scan is an index-ordered read with no per-row timezone conversion. TimestampExpr stays the
-- exact AT TIME ZONE expression so the timezone gate (50200) still passes; the retention floor (50210) still
-- guards @CutoffUtc. NULL = classic behavior (TimestampExpr used for both filter and projection).
IF COL_LENGTH(N'arch.ObjectSpec', N'CandidateSelectExpr') IS NULL
    ALTER TABLE arch.ObjectSpec ADD [CandidateSelectExpr] [nvarchar](4000) NULL;
GO

-- Optimistic-concurrency metadata for ObjectSpec edits (console 4-eyes / conflict detection).
-- These columns + the ModifiedAt trigger live HERE so v_ObjectSpecDatabaseEffective below can
-- project them: this view is the SINGLE source of truth. deploy/v2/33 installs only the matching
-- usp_Api_CheckConfigConcurrency proc and MUST NOT re-create this view (doing so once dropped the
-- cheap-mode column and broke the TIMESTAMP runner — keep the view defined here only).
IF COL_LENGTH(N'arch.ObjectSpec', N'CreatedAt') IS NULL
    ALTER TABLE [arch].[ObjectSpec] ADD [CreatedAt] datetime2(0) NOT NULL
        CONSTRAINT [DF_ObjectSpec_CreatedAt] DEFAULT (sysutcdatetime()) WITH VALUES;
GO
IF COL_LENGTH(N'arch.ObjectSpec', N'ModifiedAt') IS NULL
    ALTER TABLE [arch].[ObjectSpec] ADD [ModifiedAt] datetime2(0) NOT NULL
        CONSTRAINT [DF_ObjectSpec_ModifiedAt] DEFAULT (sysutcdatetime()) WITH VALUES;
GO

CREATE OR ALTER TRIGGER [arch].[tr_ObjectSpec_SetModifiedAt]
ON [arch].[ObjectSpec]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF TRIGGER_NESTLEVEL() > 1
        RETURN;
    UPDATE os
    SET ModifiedAt = CONVERT(datetime2(0), sysutcdatetime())
    FROM [arch].[ObjectSpec] AS os
    JOIN inserted AS i
      ON i.ObjectSpecId = os.ObjectSpecId;
END
GO

CREATE OR ALTER VIEW [arch].[v_ObjectSpecDatabaseEffective]
AS
SELECT
    e.ProcessDatabaseId,
    e.ProcessId,
    e.ProcessCode,
    e.SourceDb,
    e.ArchiveDb,
    e.IsEnabled AS ProcessDatabaseIsEnabled,
    os.ObjectSpecId,
    ObjectSpecOverrideId = osdo.ObjectSpecDatabaseOverrideId,
    ObjectIsEnabled = CONVERT(bit, CASE WHEN osdo.ObjectSpecDatabaseOverrideId IS NULL OR osdo.IsEnabled = 1 THEN 1 ELSE 0 END),
    SourceSchema = COALESCE(NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N''), os.SourceSchema),
    SourceSchemaSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    SourceTable = COALESCE(NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N''), os.SourceTable),
    SourceTableSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    os.DeleteOrder,
    os.DeleteMode,
    TimestampExpr = COALESCE(NULLIF(LTRIM(RTRIM(osdo.TimestampExprOverride)), N''), os.TimestampExpr),
    TimestampExprSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.TimestampExprOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    JoinToAnchorPredicateSql = COALESCE(NULLIF(LTRIM(RTRIM(osdo.JoinToAnchorPredicateSqlOverride)), N''), os.JoinToAnchorPredicateSql),
    JoinToAnchorPredicateSqlSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.JoinToAnchorPredicateSqlOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    AdditionalWhereSql = COALESCE(NULLIF(LTRIM(RTRIM(osdo.AdditionalWhereSqlOverride)), N''), os.AdditionalWhereSql),
    AdditionalWhereSqlSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.AdditionalWhereSqlOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    ArchiveSchema = COALESCE(NULLIF(LTRIM(RTRIM(osdo.ArchiveSchemaOverride)), N''), os.ArchiveSchema),
    ArchiveSchemaSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.ArchiveSchemaOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    ArchiveTable = COALESCE(NULLIF(LTRIM(RTRIM(osdo.ArchiveTableOverride)), N''), os.ArchiveTable),
    ArchiveTableSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.ArchiveTableOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    RequireArchiveForDelete = COALESCE(osdo.RequireArchiveForDeleteOverride, os.RequireArchiveForDelete),
    RequireArchiveForDeleteSource = CONVERT(varchar(30), CASE WHEN osdo.RequireArchiveForDeleteOverride IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    os.NaturalKeyLabel,
    os.CandidateSelectExpr,
    ObjectSpecCreatedAt = os.CreatedAt,
    ObjectSpecModifiedAt = os.ModifiedAt,
    ObjectSpecOverrideCreatedAt = osdo.CreatedAt,
    ObjectSpecOverrideModifiedAt = osdo.ModifiedAt
FROM arch.v_ProcessDatabaseEffective AS e
JOIN arch.ObjectSpec AS os
  ON os.ProcessId = e.ProcessId
LEFT JOIN arch.ObjectSpecDatabaseOverride AS osdo
  ON osdo.ProcessDatabaseId = e.ProcessDatabaseId
 AND osdo.ObjectSpecId = os.ObjectSpecId;
GO
