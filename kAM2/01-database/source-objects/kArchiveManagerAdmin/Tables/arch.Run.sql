USE [kArchiveManagerAdmin]
GO

/****** Object:  Table [arch].[Run]    Script Date: 08.04.2026 17:16:10 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [arch].[Run](
	[RunId] [bigint] IDENTITY(1,1) NOT NULL,
	[StartedAt] [datetime2](0) NOT NULL,
	[EndedAt] [datetime2](0) NULL,
	[Status] [nvarchar](20) NOT NULL,
	[SourceDb] [sysname] NULL,
	[ArchiveDb] [sysname] NULL,
	[HostName] [nvarchar](128) NULL,
	[AppName] [nvarchar](128) NULL,
	[InitiatedBy] [nvarchar](128) NULL,
	[ErrorMessage] [nvarchar](max) NULL,
 CONSTRAINT [PK_Run] PRIMARY KEY CLUSTERED 
(
	[RunId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
ALTER TABLE [arch].[Run] ADD  CONSTRAINT [DF_Run_Started]  DEFAULT (sysutcdatetime()) FOR [StartedAt]
GO

ALTER TABLE [arch].[Run] ADD  CONSTRAINT [DF_Run_Status]  DEFAULT (N'RUNNING') FOR [Status]
GO

ALTER TABLE [arch].[Run] WITH CHECK ADD CONSTRAINT [CK_Run_Status] CHECK
(
    [Status] IN (N'RUNNING', N'OK', N'FAILED', N'DRYRUN')
)
GO

ALTER TABLE [arch].[Run] CHECK CONSTRAINT [CK_Run_Status]
GO

CREATE NONCLUSTERED INDEX [IX_Run_Source_Status]
ON [arch].[Run] ([SourceDb], [Status], [RunId] DESC)
INCLUDE ([ArchiveDb], [StartedAt], [EndedAt])
GO
