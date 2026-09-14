USE [kArchiveManagerAdmin]
GO

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
 CONSTRAINT [PK_ObjectSpecDatabaseOverride] PRIMARY KEY CLUSTERED
(
    [ObjectSpecDatabaseOverrideId] ASC
) ON [PRIMARY],
 CONSTRAINT [UQ_ObjectSpecDatabaseOverride] UNIQUE NONCLUSTERED
(
    [ProcessDatabaseId] ASC,
    [ObjectSpecId] ASC
) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_IsEnabled] DEFAULT ((1)) FOR [IsEnabled]
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt]
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt]
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] WITH CHECK ADD CONSTRAINT [FK_ObjectSpecDatabaseOverride_ProcessDatabase] FOREIGN KEY([ProcessDatabaseId])
REFERENCES [arch].[ProcessDatabase] ([ProcessDatabaseId])
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] CHECK CONSTRAINT [FK_ObjectSpecDatabaseOverride_ProcessDatabase]
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] WITH CHECK ADD CONSTRAINT [FK_ObjectSpecDatabaseOverride_ObjectSpec] FOREIGN KEY([ObjectSpecId])
REFERENCES [arch].[ObjectSpec] ([ObjectSpecId])
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] CHECK CONSTRAINT [FK_ObjectSpecDatabaseOverride_ObjectSpec]
GO
