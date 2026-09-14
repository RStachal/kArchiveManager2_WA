USE [kArchiveManagerAdmin]
GO

/****** Object:  Table [arch].[RunItemObject]    Script Date: 08.04.2026 17:16:10 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [arch].[RunItemObject](
	[RunItemObjectId] [bigint] IDENTITY(1,1) NOT NULL,
	[RunItemId] [bigint] NOT NULL,
	[SourceSchema] [sysname] NOT NULL,
	[SourceTable] [sysname] NOT NULL,
	[RowsDeleted] [bigint] NOT NULL,
	[RowsArchived] [bigint] NOT NULL,
	[LoggedAt] [datetime2](0) NOT NULL,
 CONSTRAINT [PK_RunItemObject] PRIMARY KEY CLUSTERED 
(
	[RunItemObjectId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
ALTER TABLE [arch].[RunItemObject] ADD  CONSTRAINT [DF_RunItemObject_Logged]  DEFAULT (sysutcdatetime()) FOR [LoggedAt]
GO

ALTER TABLE [arch].[RunItemObject]  WITH CHECK ADD  CONSTRAINT [FK_RunItemObject_RunItem] FOREIGN KEY([RunItemId])
REFERENCES [arch].[RunItem] ([RunItemId])
GO

ALTER TABLE [arch].[RunItemObject] CHECK CONSTRAINT [FK_RunItemObject_RunItem]
GO

ALTER TABLE [arch].[RunItemObject] WITH CHECK ADD CONSTRAINT [CK_RunItemObject_NonNegativeRows] CHECK
(
    [RowsDeleted] >= 0
    AND [RowsArchived] >= 0
)
GO

ALTER TABLE [arch].[RunItemObject] CHECK CONSTRAINT [CK_RunItemObject_NonNegativeRows]
GO

CREATE NONCLUSTERED INDEX [IX_RunItemObject_RunItem]
ON [arch].[RunItemObject] ([RunItemId], [SourceSchema], [SourceTable])
INCLUDE ([RowsDeleted], [RowsArchived])
GO
