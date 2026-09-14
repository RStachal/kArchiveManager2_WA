USE [kArchiveManagerAdmin]
GO

CREATE TABLE [arch].[ProcessDatabase](
    [ProcessDatabaseId] [int] IDENTITY(1,1) NOT NULL,
    [ProcessId] [int] NOT NULL,
    [SourceDb] [sysname] NOT NULL,
    [ArchiveDb] [sysname] NOT NULL,
    [IsEnabled] [bit] NOT NULL,
    [RunOrder] [int] NOT NULL,
    [Mode] [tinyint] NULL,
    [RetentionDays] [int] NULL,
    [CutoffSafetyLagMinutes] [int] NULL,
    [CutoffMode] [tinyint] NULL,
    [CutoffDate] [datetime2](0) NULL,
    [BatchDocCount] [int] NULL,
    [BatchRowCount] [int] NULL,
    [MaxBatchesPerRun] [int] NULL,
    [DelayMsBetweenBatches] [int] NULL,
    [UseAppLock] [bit] NULL,
    [AppLockResource] [nvarchar](200) NULL,
    [LockTimeoutMs] [int] NULL,
    [DeadlockPriority] [nvarchar](10) NULL,
    [AnchorSchema] [sysname] NULL,
    [AnchorTable] [sysname] NULL,
    [AnchorDocKeyExpr] [nvarchar](4000) NULL,
    [AnchorDocKey2Expr] [nvarchar](4000) NULL,
    [AnchorTimestampExpr] [nvarchar](4000) NULL,
    [AnchorExtraWhereSql] [nvarchar](4000) NULL,
    [AllowDeleteWithoutArchive] [bit] NULL,
    [DocKeyLabel] [nvarchar](50) NULL,
    [AuditLevel] [nvarchar](20) NULL,
    [RequireSupportingIndex] [bit] NULL,
    [MaxRowsPerTransaction] [int] NULL,
    [CandidateWhereSql] [nvarchar](4000) NULL,
    [CandidateOrderSql] [nvarchar](4000) NULL,
    [CreatedAt] [datetime2](0) NOT NULL,
    [ModifiedAt] [datetime2](0) NOT NULL,
 CONSTRAINT [PK_ProcessDatabase] PRIMARY KEY CLUSTERED
(
    [ProcessDatabaseId] ASC
) ON [PRIMARY],
 CONSTRAINT [UQ_ProcessDatabase_Process_Source_Archive] UNIQUE NONCLUSTERED
(
    [ProcessId] ASC,
    [SourceDb] ASC,
    [ArchiveDb] ASC
) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_IsEnabled] DEFAULT ((1)) FOR [IsEnabled]
GO

ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_RunOrder] DEFAULT ((100)) FOR [RunOrder]
GO

ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt]
GO

ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt]
GO

ALTER TABLE [arch].[ProcessDatabase] WITH CHECK ADD CONSTRAINT [FK_ProcessDatabase_Process] FOREIGN KEY([ProcessId])
REFERENCES [arch].[Process] ([ProcessId])
GO

ALTER TABLE [arch].[ProcessDatabase] CHECK CONSTRAINT [FK_ProcessDatabase_Process]
GO

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
)
GO

ALTER TABLE [arch].[ProcessDatabase] CHECK CONSTRAINT [CK_ProcessDatabase_OverrideLimits]
GO

CREATE NONCLUSTERED INDEX [IX_ProcessDatabase_Enabled_RunOrder]
ON [arch].[ProcessDatabase] ([IsEnabled], [RunOrder], [ProcessId])
INCLUDE ([SourceDb], [ArchiveDb])
GO
