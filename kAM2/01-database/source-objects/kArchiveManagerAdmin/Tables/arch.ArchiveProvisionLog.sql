USE [kArchiveManagerAdmin]
GO

/****** Object:  Table [arch].[ArchiveProvisionLog]    Script Date: 08.04.2026 17:16:10 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [arch].[ArchiveProvisionLog](
	[ProvisionId] [bigint] IDENTITY(1,1) NOT NULL,
	[LoggedAt] [datetime2](0) NOT NULL,
	[SourceDb] [sysname] NOT NULL,
	[ArchiveDb] [sysname] NOT NULL,
	[SourceSchema] [sysname] NOT NULL,
	[SourceTable] [sysname] NOT NULL,
	[Action] [nvarchar](50) NOT NULL,
	[Details] [nvarchar](max) NULL,
CONSTRAINT [PK_ArchiveProvisionLog] PRIMARY KEY CLUSTERED 
(
	[ProvisionId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
ALTER TABLE [arch].[ArchiveProvisionLog] ADD CONSTRAINT [DF_ArchiveProvisionLog_LoggedAt] DEFAULT (sysutcdatetime()) FOR [LoggedAt]
GO

CREATE NONCLUSTERED INDEX [IX_ArchiveProvisionLog_Source]
ON [arch].[ArchiveProvisionLog] ([SourceDb], [ArchiveDb], [SourceSchema], [SourceTable], [LoggedAt] DESC)
INCLUDE ([Action])
GO
