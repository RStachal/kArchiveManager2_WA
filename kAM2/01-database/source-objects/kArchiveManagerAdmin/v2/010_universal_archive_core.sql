USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF COL_LENGTH(N'arch.Process', N'SelectionStrategy') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [SelectionStrategy] [nvarchar](30) NOT NULL
        CONSTRAINT [DF_Process_SelectionStrategy] DEFAULT (N'ANCHOR');
END
GO

IF COL_LENGTH(N'arch.Process', N'AuditLevel') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [AuditLevel] [nvarchar](20) NOT NULL
        CONSTRAINT [DF_Process_AuditLevel] DEFAULT (N'BATCH');
END
GO

IF COL_LENGTH(N'arch.Process', N'RequireSupportingIndex') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [RequireSupportingIndex] [bit] NOT NULL
        CONSTRAINT [DF_Process_RequireSupportingIndex] DEFAULT ((1));
END
GO

IF COL_LENGTH(N'arch.Process', N'MaxRowsPerTransaction') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [MaxRowsPerTransaction] [int] NULL;
END
GO

IF COL_LENGTH(N'arch.Process', N'CandidateWhereSql') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [CandidateWhereSql] [nvarchar](4000) NULL;
END
GO

IF COL_LENGTH(N'arch.Process', N'CandidateOrderSql') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [CandidateOrderSql] [nvarchar](4000) NULL;
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key3') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key3] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key3] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key4') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key4] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key4] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key5') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key5] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key5] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key6') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key6] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key6] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key7') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key7] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key7] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key8') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key8] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key8] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'CandidateHash') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [CandidateHash] [varbinary](32) NULL;
END
GO

IF COL_LENGTH(N'arch.RowCountSnapshot', N'ProcessCode') IS NOT NULL
   AND COL_LENGTH(N'arch.RowCountSnapshot', N'ProcessCode') < 100
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'arch.RowCountSnapshot')
          AND name = N'IX_RowCountSnapshot_Time_Process'
    )
    BEGIN
        DROP INDEX [IX_RowCountSnapshot_Time_Process] ON [arch].[RowCountSnapshot];
    END;

    ALTER TABLE [arch].[RowCountSnapshot]
    ALTER COLUMN [ProcessCode] [nvarchar](50) NOT NULL;
END
GO

IF OBJECT_ID(N'arch.SelectionStrategy', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[SelectionStrategy](
        [StrategyCode] [nvarchar](30) NOT NULL,
        [Description] [nvarchar](400) NOT NULL,
        [RequiresAnchor] [bit] NOT NULL,
        [RequiresTimestamp] [bit] NOT NULL,
        [RequiresRange] [bit] NOT NULL,
        [RequiresExternalKeyset] [bit] NOT NULL,
        [IsEnabled] [bit] NOT NULL,
        CONSTRAINT [PK_SelectionStrategy] PRIMARY KEY CLUSTERED ([StrategyCode] ASC)
    );
END
GO

MERGE [arch].[SelectionStrategy] AS tgt
USING (VALUES
    (N'ANCHOR',       N'Parent/anchor row selection followed by configured child-table joins.', 1, 0, 0, 0, 1),
    (N'KEYSET',       N'Externally supplied or staged keyset processed through configured joins.', 0, 0, 0, 1, 1),
    (N'RANGE',        N'Bounded monotonic key range, usually identity or sequence based.', 0, 0, 1, 0, 1),
    (N'TIMESTAMP',    N'Indexed timestamp cutoff selection.', 0, 1, 0, 0, 1),
    (N'PARTITION',    N'Partition-level archive/delete where schema supports switching.', 0, 0, 0, 0, 1),
    (N'CUSTOM_QUERY', N'Reviewed custom candidate query emitting the standard key shape.', 0, 0, 0, 0, 1),
    (N'ORPHAN',       N'Child rows without matching parent rows, using indexed anti-join.', 0, 0, 0, 0, 1),
    (N'SOFT_DELETE',  N'Status/flag-based cleanup with optional cutoff.', 0, 0, 0, 0, 1)
) AS src(StrategyCode, Description, RequiresAnchor, RequiresTimestamp, RequiresRange, RequiresExternalKeyset, IsEnabled)
ON tgt.StrategyCode = src.StrategyCode
WHEN MATCHED THEN UPDATE SET
    Description = src.Description,
    RequiresAnchor = src.RequiresAnchor,
    RequiresTimestamp = src.RequiresTimestamp,
    RequiresRange = src.RequiresRange,
    RequiresExternalKeyset = src.RequiresExternalKeyset,
    IsEnabled = src.IsEnabled
WHEN NOT MATCHED THEN INSERT
(
    StrategyCode, Description, RequiresAnchor, RequiresTimestamp, RequiresRange, RequiresExternalKeyset, IsEnabled
)
VALUES
(
    src.StrategyCode, src.Description, src.RequiresAnchor, src.RequiresTimestamp, src.RequiresRange, src.RequiresExternalKeyset, src.IsEnabled
);
GO

IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ProcessKeySpec](
        [ProcessKeySpecId] [int] IDENTITY(1,1) NOT NULL,
        [ProcessId] [int] NOT NULL,
        [KeyOrdinal] [tinyint] NOT NULL,
        [KeyName] [sysname] NOT NULL,
        [SourceExpressionSql] [nvarchar](4000) NOT NULL,
        [SqlType] [nvarchar](128) NOT NULL,
        [IsRequired] [bit] NOT NULL,
        [CreatedAt] [datetime2](0) NOT NULL,
        [ModifiedAt] [datetime2](0) NOT NULL,
        CONSTRAINT [PK_ProcessKeySpec] PRIMARY KEY CLUSTERED ([ProcessKeySpecId] ASC),
        CONSTRAINT [UQ_ProcessKeySpec_Process_Ordinal] UNIQUE NONCLUSTERED ([ProcessId] ASC, [KeyOrdinal] ASC),
        CONSTRAINT [FK_ProcessKeySpec_Process] FOREIGN KEY([ProcessId]) REFERENCES [arch].[Process] ([ProcessId]),
        CONSTRAINT [CK_ProcessKeySpec_KeyOrdinal] CHECK ([KeyOrdinal] BETWEEN 1 AND 8)
    );

    ALTER TABLE [arch].[ProcessKeySpec] ADD CONSTRAINT [DF_ProcessKeySpec_IsRequired] DEFAULT ((1)) FOR [IsRequired];
    ALTER TABLE [arch].[ProcessKeySpec] ADD CONSTRAINT [DF_ProcessKeySpec_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt];
    ALTER TABLE [arch].[ProcessKeySpec] ADD CONSTRAINT [DF_ProcessKeySpec_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt];
END
GO

IF OBJECT_ID(N'arch.IndexRequirement', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[IndexRequirement](
        [IndexRequirementId] [int] IDENTITY(1,1) NOT NULL,
        [ProcessId] [int] NOT NULL,
        [ObjectSpecId] [int] NULL,
        [RequirementType] [nvarchar](20) NOT NULL,
        [SourceSchema] [sysname] NOT NULL,
        [SourceTable] [sysname] NOT NULL,
        [KeyColumnsCsv] [nvarchar](1000) NOT NULL,
        [IncludeColumnsCsv] [nvarchar](1000) NULL,
        [FilterSql] [nvarchar](1000) NULL,
        [IsMandatory] [bit] NOT NULL,
        [Notes] [nvarchar](1000) NULL,
        [CreatedAt] [datetime2](0) NOT NULL,
        [ModifiedAt] [datetime2](0) NOT NULL,
        CONSTRAINT [PK_IndexRequirement] PRIMARY KEY CLUSTERED ([IndexRequirementId] ASC),
        CONSTRAINT [FK_IndexRequirement_Process] FOREIGN KEY([ProcessId]) REFERENCES [arch].[Process] ([ProcessId]),
        CONSTRAINT [FK_IndexRequirement_ObjectSpec] FOREIGN KEY([ObjectSpecId]) REFERENCES [arch].[ObjectSpec] ([ObjectSpecId]),
        CONSTRAINT [CK_IndexRequirement_Type] CHECK ([RequirementType] IN (N'SELECTION', N'JOIN', N'DELETE', N'ORDER', N'PARTITION'))
    );

    ALTER TABLE [arch].[IndexRequirement] ADD CONSTRAINT [DF_IndexRequirement_IsMandatory] DEFAULT ((1)) FOR [IsMandatory];
    ALTER TABLE [arch].[IndexRequirement] ADD CONSTRAINT [DF_IndexRequirement_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt];
    ALTER TABLE [arch].[IndexRequirement] ADD CONSTRAINT [DF_IndexRequirement_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt];
END
GO

IF OBJECT_ID(N'arch.RunProfile', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[RunProfile](
        [RunProfileId] [int] IDENTITY(1,1) NOT NULL,
        [RunProfileCode] [sysname] NOT NULL,
        [Description] [nvarchar](400) NULL,
        [IsEnabled] [bit] NOT NULL,
        [RunOnSchedule] [bit] NOT NULL,
        [RunOrder] [int] NOT NULL,
        [ProcessCodeFilter] [sysname] NULL,
        [SourceDbFilter] [sysname] NULL,
        [ArchiveDbFilter] [sysname] NULL,
        [RunWindowMinutes] [int] NOT NULL,
        [DryRun] [bit] NOT NULL,
        [MaxCandidates] [int] NULL,
        [PausedCooldownSeconds] [int] NOT NULL,
        [CreatedAt] [datetime2](0) NOT NULL,
        [ModifiedAt] [datetime2](0) NOT NULL,
        CONSTRAINT [PK_RunProfile] PRIMARY KEY CLUSTERED ([RunProfileId] ASC),
        CONSTRAINT [UQ_RunProfile_Code] UNIQUE NONCLUSTERED ([RunProfileCode] ASC)
    );

    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_IsEnabled] DEFAULT ((1)) FOR [IsEnabled];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_RunOnSchedule] DEFAULT ((0)) FOR [RunOnSchedule];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_RunOrder] DEFAULT ((100)) FOR [RunOrder];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_RunWindowMinutes] DEFAULT ((55)) FOR [RunWindowMinutes];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_DryRun] DEFAULT ((0)) FOR [DryRun];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_PausedCooldownSeconds] DEFAULT ((60)) FOR [PausedCooldownSeconds];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt];
    ALTER TABLE [arch].[RunProfile] WITH CHECK ADD CONSTRAINT [CK_RunProfile_Limits] CHECK
    (
        [RunWindowMinutes] > 0
        AND ([MaxCandidates] IS NULL OR [MaxCandidates] > 0)
        AND [PausedCooldownSeconds] >= 0
    );
    ALTER TABLE [arch].[RunProfile] CHECK CONSTRAINT [CK_RunProfile_Limits];
END
GO

IF OBJECT_ID(N'arch.RunProfile', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.RunProfile') AND name = N'IX_RunProfile_Schedule')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RunProfile_Schedule]
    ON [arch].[RunProfile] ([RunOnSchedule], [IsEnabled], [RunOrder], [RunProfileCode])
    INCLUDE ([ProcessCodeFilter], [SourceDbFilter], [ArchiveDbFilter], [RunWindowMinutes], [DryRun], [MaxCandidates], [PausedCooldownSeconds]);
END
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.IndexRequirement')
      AND name = N'IX_IndexRequirement_Process_Object'
)
BEGIN
    CREATE NONCLUSTERED INDEX [IX_IndexRequirement_Process_Object]
    ON [arch].[IndexRequirement] ([ProcessId], [ObjectSpecId], [RequirementType])
    INCLUDE ([SourceSchema], [SourceTable], [KeyColumnsCsv], [IsMandatory]);
END
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.WorkBatchKey')
      AND name = N'IX_WorkBatchKey_CandidateHash'
)
BEGIN
    CREATE NONCLUSTERED INDEX [IX_WorkBatchKey_CandidateHash]
    ON [arch].[WorkBatchKey] ([WorkBatchId], [CandidateHash])
    INCLUDE ([Key1], [Key2], [Key3], [Key4], [Key5], [Key6], [Key7], [Key8], [Status])
    WHERE [CandidateHash] IS NOT NULL;
END
GO

IF OBJECT_ID(N'arch.RowCountSnapshot', N'U') IS NOT NULL
   AND NOT EXISTS
   (
       SELECT 1
       FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'arch.RowCountSnapshot')
         AND name = N'IX_RowCountSnapshot_Time_Process'
   )
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RowCountSnapshot_Time_Process]
    ON [arch].[RowCountSnapshot] ([SnapshotAtUtc] DESC, [ProcessCode], [SourceDb])
    INCLUDE ([ArchiveDb], [SourceSchema], [SourceTable], [ArchiveSchema], [ArchiveTable], [SourceRows], [ArchivedRows]);
END
GO

IF EXISTS
(
    SELECT 1
    FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'arch.Process')
      AND name = N'CK_Process_SelectionStrategy'
)
BEGIN
    ALTER TABLE [arch].[Process] DROP CONSTRAINT [CK_Process_SelectionStrategy];
END
GO

ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_SelectionStrategy] CHECK
(
    [SelectionStrategy] IN
    (
        N'ANCHOR',
        N'KEYSET',
        N'RANGE',
        N'TIMESTAMP',
        N'PARTITION',
        N'CUSTOM_QUERY',
        N'ORPHAN',
        N'SOFT_DELETE'
    )
);
GO

ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_SelectionStrategy];
GO

IF EXISTS
(
    SELECT 1
    FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'arch.Process')
      AND name = N'CK_Process_AuditLevel'
)
BEGIN
    ALTER TABLE [arch].[Process] DROP CONSTRAINT [CK_Process_AuditLevel];
END
GO

ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_AuditLevel] CHECK
(
    [AuditLevel] IN (N'NONE', N'BATCH', N'OBJECT', N'ROW')
);
GO

ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_AuditLevel];
GO
