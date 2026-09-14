USE [kArchiveManagerAdmin]
GO

/****** Object:  Table [arch].[WorkBatchKey]    Script Date: 08.04.2026 17:16:10 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [arch].[WorkBatchKey](
	[WorkBatchId] [bigint] NOT NULL,
	[Key1] [nvarchar](256) NOT NULL,
	[Key2] [nvarchar](256) NOT NULL,
	[AnchorRowId] [bigint] NULL,
	[DocCreatedAt] [datetime2](0) NULL,
	[Status] [tinyint] NOT NULL,
	[Attempts] [int] NOT NULL,
	[ClaimedAtUtc] [datetime2](0) NULL,
	[ClaimedBy] [sysname] NULL,
	[DoneAtUtc] [datetime2](0) NULL,
	[ErrorMessage] [nvarchar](4000) NULL,
	[AnchorRowGuid] [uniqueidentifier] NULL,
 CONSTRAINT [PK_WorkBatchKey] PRIMARY KEY CLUSTERED 
(
	[WorkBatchId] ASC,
	[Key1] ASC,
	[Key2] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
ALTER TABLE [arch].[WorkBatchKey] ADD  CONSTRAINT [DF_WBK_Key2]  DEFAULT (N'') FOR [Key2]
GO

ALTER TABLE [arch].[WorkBatchKey] ADD  CONSTRAINT [DF_WBK_Status]  DEFAULT ((0)) FOR [Status]
GO

ALTER TABLE [arch].[WorkBatchKey] ADD  CONSTRAINT [DF_WBK_Attempts]  DEFAULT ((0)) FOR [Attempts]
GO

ALTER TABLE [arch].[WorkBatchKey]  WITH CHECK ADD  CONSTRAINT [FK_WorkBatchKey_WorkBatch] FOREIGN KEY([WorkBatchId])
REFERENCES [arch].[WorkBatch] ([WorkBatchId])
GO

ALTER TABLE [arch].[WorkBatchKey] CHECK CONSTRAINT [FK_WorkBatchKey_WorkBatch]
GO

-- Status: 0 unclaimed, 1 claimed, 2 done, 3 error, 5 legal-hold-parked (T-21).
-- v2/056 widens this same constraint to 0-5 at runtime; the table source matches it directly.
ALTER TABLE [arch].[WorkBatchKey]  WITH CHECK ADD  CONSTRAINT [CK_WorkBatchKey_Status] CHECK  (([Status]>=(0) AND [Status]<=(5)))
GO

ALTER TABLE [arch].[WorkBatchKey] CHECK CONSTRAINT [CK_WorkBatchKey_Status]
GO

CREATE NONCLUSTERED INDEX [IX_WorkBatchKey_Claim]
ON [arch].[WorkBatchKey] ([WorkBatchId], [Status], [DocCreatedAt], [Key1], [Key2])
INCLUDE ([Attempts], [AnchorRowId], [AnchorRowGuid], [ClaimedAtUtc])
GO
