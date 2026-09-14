USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

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
) ON [PRIMARY]
GO

ALTER TABLE [arch].[RowCountSnapshot] ADD CONSTRAINT [DF_RowCountSnapshot_SnapshotAt] DEFAULT (sysutcdatetime()) FOR [SnapshotAtUtc]
GO

ALTER TABLE [arch].[RowCountSnapshot] WITH CHECK ADD CONSTRAINT [CK_RowCountSnapshot_NonNegativeRows] CHECK
(
    [SourceRows] >= 0
    AND [ArchivedRows] >= 0
)
GO

ALTER TABLE [arch].[RowCountSnapshot] CHECK CONSTRAINT [CK_RowCountSnapshot_NonNegativeRows]
GO

CREATE NONCLUSTERED INDEX [IX_RowCountSnapshot_Time_Process]
ON [arch].[RowCountSnapshot] ([SnapshotAtUtc] DESC, [ProcessCode], [SourceDb])
INCLUDE ([ArchiveDb], [SourceSchema], [SourceTable], [ArchiveSchema], [ArchiveTable], [SourceRows], [ArchivedRows])
GO
