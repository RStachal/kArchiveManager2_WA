USE [kArchiveManagerAdmin]
GO

/****** Object:  Table [arch].[RunDocAudit]    Script Date: 08.04.2026 17:16:10 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [arch].[RunDocAudit](
	[RunDocAuditId] [bigint] IDENTITY(1,1) NOT NULL,
	[RunItemId] [bigint] NOT NULL,
	[ProcessCode] [nvarchar](50) NOT NULL,
	[DocKeyLabel] [nvarchar](50) NOT NULL,
	[DocKey] [nvarchar](256) NOT NULL,
	[DocCreatedAt] [datetime2](0) NULL,
	[DeletedAt] [datetime2](0) NOT NULL,
	[Archived] [bit] NOT NULL,
 CONSTRAINT [PK_RunDocAudit] PRIMARY KEY CLUSTERED 
(
	[RunDocAuditId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
ALTER TABLE [arch].[RunDocAudit] ADD  CONSTRAINT [DF_RunDocAudit_Deleted]  DEFAULT (sysutcdatetime()) FOR [DeletedAt]
GO

ALTER TABLE [arch].[RunDocAudit]  WITH CHECK ADD  CONSTRAINT [FK_RunDocAudit_RunItem] FOREIGN KEY([RunItemId])
REFERENCES [arch].[RunItem] ([RunItemId])
GO

ALTER TABLE [arch].[RunDocAudit] CHECK CONSTRAINT [FK_RunDocAudit_RunItem]
GO

CREATE NONCLUSTERED INDEX [IX_RunDocAudit_RunItem]
ON [arch].[RunDocAudit] ([RunItemId])
INCLUDE ([DocKey], [DocCreatedAt], [Archived])
GO
