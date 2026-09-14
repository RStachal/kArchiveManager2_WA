USE [kArchiveManagerAdmin]
GO

/****** Object:  Table [arch].[WorkBatch]    Script Date: 08.04.2026 17:16:10 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [arch].[WorkBatch](
	[WorkBatchId] [bigint] IDENTITY(1,1) NOT NULL,
	[ProcessId] [int] NOT NULL,
	[SourceDb] [sysname] NOT NULL,
	[ArchiveDb] [sysname] NOT NULL,
	[RangeFromUtc] [datetime2](0) NOT NULL,
	[RangeToUtc] [datetime2](0) NOT NULL,
	[ModeSnapshot] [tinyint] NOT NULL,
	[Status] [varchar](20) NOT NULL,
	[PreparedAtUtc] [datetime2](0) NULL,
	[StartedAtUtc] [datetime2](0) NULL,
	[LastProgressAtUtc] [datetime2](0) NULL,
	[CompletedAtUtc] [datetime2](0) NULL,
	[LastKey1] [nvarchar](256) NULL,
	[LastKey2] [nvarchar](256) NULL,
	[Notes] [nvarchar](4000) NULL,
 CONSTRAINT [PK_WorkBatch] PRIMARY KEY CLUSTERED 
(
	[WorkBatchId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [arch].[WorkBatch] ADD  CONSTRAINT [DF_WorkBatch_Status]  DEFAULT ('Prepared') FOR [Status]
GO

ALTER TABLE [arch].[WorkBatch] ADD  CONSTRAINT [DF_WorkBatch_Prepared]  DEFAULT (sysutcdatetime()) FOR [PreparedAtUtc]
GO

ALTER TABLE [arch].[WorkBatch]  WITH CHECK ADD  CONSTRAINT [CK_WorkBatch_Status] CHECK
(
    [Status] IN ('Prepared', 'Running', 'Paused', 'Completed', 'Failed')
)
GO

ALTER TABLE [arch].[WorkBatch] CHECK CONSTRAINT [CK_WorkBatch_Status]
GO

CREATE NONCLUSTERED INDEX [IX_WorkBatch_Process_Status]
ON [arch].[WorkBatch] ([ProcessId], [Status], [PreparedAtUtc], [WorkBatchId])
INCLUDE ([SourceDb], [ArchiveDb], [LastProgressAtUtc])
GO
