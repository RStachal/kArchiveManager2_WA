USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF SCHEMA_ID(N'arch') IS NULL
    EXEC(N'CREATE SCHEMA [arch]');
GO

IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
   AND COL_LENGTH(N'arch.Process', N'AnchorDocKey2Expr') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [AnchorDocKey2Expr] [nvarchar](4000) NULL;
END
GO

IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.Process') AND name = N'CK_Process_Mode')
BEGIN
    ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_Mode] CHECK (([Mode]=(1) OR [Mode]=(0)));
    ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_Mode];
END
GO

IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.Process') AND name = N'CK_Process_NonNegativeLimits')
BEGIN
    ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_NonNegativeLimits] CHECK
    (
        [RetentionDays] >= 0
        AND [CutoffSafetyLagMinutes] >= 0
        AND ([BatchDocCount] IS NULL OR [BatchDocCount] > 0)
        AND ([BatchRowCount] IS NULL OR [BatchRowCount] > 0)
        AND [MaxBatchesPerRun] > 0
        AND [DelayMsBetweenBatches] >= 0
        AND [LockTimeoutMs] >= 0
    );
    ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_NonNegativeLimits];
END
GO

IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.Process') AND name = N'CK_Process_DeadlockPriority')
BEGIN
    ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_DeadlockPriority] CHECK
    (
        [DeadlockPriority] IN (N'LOW', N'NORMAL', N'HIGH')
    );
    ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_DeadlockPriority];
END
GO

IF OBJECT_ID(N'arch.ObjectSpec', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.ObjectSpec') AND name = N'CK_ObjectSpec_DeleteMode')
BEGIN
    ALTER TABLE [arch].[ObjectSpec] WITH CHECK ADD CONSTRAINT [CK_ObjectSpec_DeleteMode] CHECK (([DeleteMode]=(1) OR [DeleteMode]=(0)));
    ALTER TABLE [arch].[ObjectSpec] CHECK CONSTRAINT [CK_ObjectSpec_DeleteMode];
END
GO

IF OBJECT_ID(N'arch.ObjectSpec', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.ObjectSpec') AND name = N'IX_ObjectSpec_Process_DeleteOrder')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_ObjectSpec_Process_DeleteOrder]
    ON [arch].[ObjectSpec] ([ProcessId], [DeleteOrder], [ObjectSpecId])
    INCLUDE ([SourceSchema], [SourceTable], [DeleteMode], [TimestampExpr], [JoinToAnchorPredicateSql], [AdditionalWhereSql], [ArchiveSchema], [ArchiveTable], [RequireArchiveForDelete]);
END
GO

IF OBJECT_ID(N'arch.WorkBatch', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.WorkBatch') AND name = N'CK_WorkBatch_Status')
BEGIN
    ALTER TABLE [arch].[WorkBatch] WITH CHECK ADD CONSTRAINT [CK_WorkBatch_Status] CHECK
    (
        [Status] IN ('Prepared', 'Running', 'Paused', 'Completed', 'Failed')
    );
    ALTER TABLE [arch].[WorkBatch] CHECK CONSTRAINT [CK_WorkBatch_Status];
END
GO

IF OBJECT_ID(N'arch.WorkBatch', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.WorkBatch') AND name = N'IX_WorkBatch_Process_Status')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_WorkBatch_Process_Status]
    ON [arch].[WorkBatch] ([ProcessId], [Status], [PreparedAtUtc], [WorkBatchId])
    INCLUDE ([SourceDb], [ArchiveDb], [LastProgressAtUtc]);
END
GO

IF OBJECT_ID(N'arch.WorkBatchKey', N'U') IS NOT NULL
   AND COL_LENGTH(N'arch.WorkBatchKey', N'AnchorRowGuid') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [AnchorRowGuid] [uniqueidentifier] NULL;
END
GO

IF OBJECT_ID(N'arch.WorkBatchKey', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.WorkBatchKey') AND name = N'CK_WorkBatchKey_Status')
BEGIN
    ALTER TABLE [arch].[WorkBatchKey] WITH CHECK ADD CONSTRAINT [CK_WorkBatchKey_Status] CHECK (([Status]>=(0) AND [Status]<=(3)));
    ALTER TABLE [arch].[WorkBatchKey] CHECK CONSTRAINT [CK_WorkBatchKey_Status];
END
GO

IF OBJECT_ID(N'arch.WorkBatchKey', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.WorkBatchKey') AND name = N'IX_WorkBatchKey_Claim')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_WorkBatchKey_Claim]
    ON [arch].[WorkBatchKey] ([WorkBatchId], [Status], [DocCreatedAt], [Key1], [Key2])
    INCLUDE ([Attempts], [AnchorRowId], [AnchorRowGuid], [ClaimedAtUtc]);
END
GO

IF OBJECT_ID(N'arch.ProcessDatabase', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ProcessDatabase](
        [ProcessDatabaseId] [int] IDENTITY(1,1) NOT NULL,
        [ProcessId] [int] NOT NULL,
        [SourceDb] [sysname] NOT NULL,
        [ArchiveDb] [sysname] NOT NULL,
        [IsEnabled] [bit] NOT NULL,
        [RunOrder] [int] NOT NULL,
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
    ) ON [PRIMARY];

    ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_IsEnabled] DEFAULT ((1)) FOR [IsEnabled];
    ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_RunOrder] DEFAULT ((100)) FOR [RunOrder];
    ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt];
    ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt];
    ALTER TABLE [arch].[ProcessDatabase] WITH CHECK ADD CONSTRAINT [FK_ProcessDatabase_Process] FOREIGN KEY([ProcessId]) REFERENCES [arch].[Process] ([ProcessId]);
    ALTER TABLE [arch].[ProcessDatabase] CHECK CONSTRAINT [FK_ProcessDatabase_Process];
END
GO

IF OBJECT_ID(N'arch.ProcessDatabase', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.ProcessDatabase') AND name = N'IX_ProcessDatabase_Enabled_RunOrder')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_ProcessDatabase_Enabled_RunOrder]
    ON [arch].[ProcessDatabase] ([IsEnabled], [RunOrder], [ProcessId])
    INCLUDE ([SourceDb], [ArchiveDb]);
END
GO

IF OBJECT_ID(N'arch.RowCountSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[RowCountSnapshot](
        [SnapshotId] [bigint] IDENTITY(1,1) NOT NULL,
        [SnapshotAtUtc] [datetime2](0) NOT NULL,
        [SourceDb] [sysname] NOT NULL,
        [ArchiveDb] [sysname] NOT NULL,
        [ProcessCode] [nvarchar](50) NOT NULL,
        [SourceSchema] [sysname] NOT NULL,
        [SourceTable] [sysname] NOT NULL,
        [ArchiveSchema] [sysname] NOT NULL,
        [ArchiveTable] [sysname] NOT NULL,
        [SourceRows] [bigint] NOT NULL,
        [ArchivedRows] [bigint] NOT NULL,
     CONSTRAINT [PK_RowCountSnapshot] PRIMARY KEY CLUSTERED
    (
        [SnapshotId] ASC
    ) ON [PRIMARY]
    ) ON [PRIMARY];

    ALTER TABLE [arch].[RowCountSnapshot] ADD CONSTRAINT [DF_RowCountSnapshot_SnapshotAt] DEFAULT (sysutcdatetime()) FOR [SnapshotAtUtc];
    ALTER TABLE [arch].[RowCountSnapshot] WITH CHECK ADD CONSTRAINT [CK_RowCountSnapshot_NonNegativeRows] CHECK
    (
        [SourceRows] >= 0
        AND [ArchivedRows] >= 0
    );
    ALTER TABLE [arch].[RowCountSnapshot] CHECK CONSTRAINT [CK_RowCountSnapshot_NonNegativeRows];
END
GO

IF OBJECT_ID(N'arch.RowCountSnapshot', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.RowCountSnapshot') AND name = N'IX_RowCountSnapshot_Time_Process')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RowCountSnapshot_Time_Process]
    ON [arch].[RowCountSnapshot] ([SnapshotAtUtc] DESC, [ProcessCode], [SourceDb])
    INCLUDE ([ArchiveDb], [SourceSchema], [SourceTable], [ArchiveSchema], [ArchiveTable], [SourceRows], [ArchivedRows]);
END
GO

IF OBJECT_ID(N'arch.Run', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.Run') AND name = N'CK_Run_Status')
BEGIN
    ALTER TABLE [arch].[Run] WITH CHECK ADD CONSTRAINT [CK_Run_Status] CHECK
    (
        [Status] IN (N'RUNNING', N'OK', N'FAILED', N'DRYRUN')
    );
    ALTER TABLE [arch].[Run] CHECK CONSTRAINT [CK_Run_Status];
END
GO

IF OBJECT_ID(N'arch.ArchiveProvisionLog', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.ArchiveProvisionLog') AND name = N'IX_ArchiveProvisionLog_Source')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_ArchiveProvisionLog_Source]
    ON [arch].[ArchiveProvisionLog] ([SourceDb], [ArchiveDb], [SourceSchema], [SourceTable], [LoggedAt] DESC)
    INCLUDE ([Action]);
END
GO

IF OBJECT_ID(N'arch.Run', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.Run') AND name = N'IX_Run_Source_Status')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_Run_Source_Status]
    ON [arch].[Run] ([SourceDb], [Status], [RunId] DESC)
    INCLUDE ([ArchiveDb], [StartedAt], [EndedAt]);
END
GO

IF OBJECT_ID(N'arch.RunItem', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.RunItem') AND name = N'CK_RunItem_Status')
BEGIN
    ALTER TABLE [arch].[RunItem] WITH CHECK ADD CONSTRAINT [CK_RunItem_Status] CHECK
    (
        [Status] IN (N'RUNNING', N'OK', N'FAILED', N'DRYRUN')
    );
    ALTER TABLE [arch].[RunItem] CHECK CONSTRAINT [CK_RunItem_Status];
END
GO

IF OBJECT_ID(N'arch.RunItem', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.RunItem') AND name = N'CK_RunItem_NonNegativeTotals')
BEGIN
    ALTER TABLE [arch].[RunItem] WITH CHECK ADD CONSTRAINT [CK_RunItem_NonNegativeTotals] CHECK
    (
        [BatchesDone] >= 0
        AND [DocsDone] >= 0
        AND [RowsDeleted] >= 0
        AND [RowsArchived] >= 0
    );
    ALTER TABLE [arch].[RunItem] CHECK CONSTRAINT [CK_RunItem_NonNegativeTotals];
END
GO

IF OBJECT_ID(N'arch.RunItem', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.RunItem') AND name = N'IX_RunItem_Process_Status')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RunItem_Process_Status]
    ON [arch].[RunItem] ([ProcessId], [Status], [RunId] DESC, [RunItemId] DESC)
    INCLUDE ([Mode], [AsOfUtc], [CutoffUtc], [RowsDeleted], [RowsArchived]);
END
GO

IF OBJECT_ID(N'arch.RunDocAudit', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.RunDocAudit') AND name = N'IX_RunDocAudit_RunItem')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RunDocAudit_RunItem]
    ON [arch].[RunDocAudit] ([RunItemId])
    INCLUDE ([DocKey], [DocCreatedAt], [Archived]);
END
GO

IF OBJECT_ID(N'arch.RunItemObject', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.RunItemObject') AND name = N'CK_RunItemObject_NonNegativeRows')
BEGIN
    ALTER TABLE [arch].[RunItemObject] WITH CHECK ADD CONSTRAINT [CK_RunItemObject_NonNegativeRows] CHECK
    (
        [RowsDeleted] >= 0
        AND [RowsArchived] >= 0
    );
    ALTER TABLE [arch].[RunItemObject] CHECK CONSTRAINT [CK_RunItemObject_NonNegativeRows];
END
GO

IF OBJECT_ID(N'arch.RunItemObject', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.RunItemObject') AND name = N'IX_RunItemObject_RunItem')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RunItemObject_RunItem]
    ON [arch].[RunItemObject] ([RunItemId], [SourceSchema], [SourceTable])
    INCLUDE ([RowsDeleted], [RowsArchived]);
END
GO
