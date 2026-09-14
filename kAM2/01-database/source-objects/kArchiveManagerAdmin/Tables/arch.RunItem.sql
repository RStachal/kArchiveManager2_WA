USE [kArchiveManagerAdmin]
GO

/****** Object:  Table [arch].[RunItem]    Script Date: 08.04.2026 17:16:10 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [arch].[RunItem](
	[RunItemId] [bigint] IDENTITY(1,1) NOT NULL,
	[RunId] [bigint] NOT NULL,
	[ProcessId] [int] NOT NULL,
	[AsOfUtc] [datetime2](0) NOT NULL,
	[CutoffUtc] [datetime2](0) NOT NULL,
	[Mode] [tinyint] NOT NULL,
	[BatchesDone] [int] NOT NULL,
	[DocsDone] [int] NOT NULL,
	[RowsDeleted] [bigint] NOT NULL,
	[RowsArchived] [bigint] NOT NULL,
	[StartedAt] [datetime2](0) NOT NULL,
	[EndedAt] [datetime2](0) NULL,
	[Status] [nvarchar](20) NOT NULL,
	[ErrorMessage] [nvarchar](max) NULL,
 CONSTRAINT [PK_RunItem] PRIMARY KEY CLUSTERED 
(
	[RunItemId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
ALTER TABLE [arch].[RunItem] ADD  CONSTRAINT [DF_RunItem_Batches]  DEFAULT ((0)) FOR [BatchesDone]
GO

ALTER TABLE [arch].[RunItem] ADD  CONSTRAINT [DF_RunItem_Docs]  DEFAULT ((0)) FOR [DocsDone]
GO

ALTER TABLE [arch].[RunItem] ADD  CONSTRAINT [DF_RunItem_RowsDel]  DEFAULT ((0)) FOR [RowsDeleted]
GO

ALTER TABLE [arch].[RunItem] ADD  CONSTRAINT [DF_RunItem_RowsArch]  DEFAULT ((0)) FOR [RowsArchived]
GO

ALTER TABLE [arch].[RunItem] ADD  CONSTRAINT [DF_RunItem_Started]  DEFAULT (sysutcdatetime()) FOR [StartedAt]
GO

ALTER TABLE [arch].[RunItem] ADD  CONSTRAINT [DF_RunItem_Status]  DEFAULT (N'RUNNING') FOR [Status]
GO

ALTER TABLE [arch].[RunItem]  WITH CHECK ADD  CONSTRAINT [FK_RunItem_Process] FOREIGN KEY([ProcessId])
REFERENCES [arch].[Process] ([ProcessId])
GO

ALTER TABLE [arch].[RunItem] CHECK CONSTRAINT [FK_RunItem_Process]
GO

ALTER TABLE [arch].[RunItem]  WITH CHECK ADD  CONSTRAINT [FK_RunItem_Run] FOREIGN KEY([RunId])
REFERENCES [arch].[Run] ([RunId])
GO

ALTER TABLE [arch].[RunItem] CHECK CONSTRAINT [FK_RunItem_Run]
GO

ALTER TABLE [arch].[RunItem] WITH CHECK ADD CONSTRAINT [CK_RunItem_Status] CHECK
(
    [Status] IN (N'RUNNING', N'OK', N'FAILED', N'DRYRUN')
)
GO

ALTER TABLE [arch].[RunItem] CHECK CONSTRAINT [CK_RunItem_Status]
GO

ALTER TABLE [arch].[RunItem] WITH CHECK ADD CONSTRAINT [CK_RunItem_NonNegativeTotals] CHECK
(
    [BatchesDone] >= 0
    AND [DocsDone] >= 0
    AND [RowsDeleted] >= 0
    AND [RowsArchived] >= 0
)
GO

ALTER TABLE [arch].[RunItem] CHECK CONSTRAINT [CK_RunItem_NonNegativeTotals]
GO

CREATE NONCLUSTERED INDEX [IX_RunItem_Process_Status]
ON [arch].[RunItem] ([ProcessId], [Status], [RunId] DESC, [RunItemId] DESC)
INCLUDE ([Mode], [AsOfUtc], [CutoffUtc], [RowsDeleted], [RowsArchived])
GO
