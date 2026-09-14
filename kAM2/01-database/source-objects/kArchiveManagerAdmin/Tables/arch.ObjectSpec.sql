USE [kArchiveManagerAdmin]
GO

/****** Object:  Table [arch].[ObjectSpec]    Script Date: 08.04.2026 17:16:10 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [arch].[ObjectSpec](
	[ObjectSpecId] [int] IDENTITY(1,1) NOT NULL,
	[ProcessId] [int] NOT NULL,
	[SourceSchema] [sysname] NOT NULL,
	[SourceTable] [sysname] NOT NULL,
	[DeleteOrder] [int] NOT NULL,
	[DeleteMode] [tinyint] NOT NULL,
	[TimestampExpr] [nvarchar](4000) NULL,
	[JoinToAnchorPredicateSql] [nvarchar](4000) NULL,
	[AdditionalWhereSql] [nvarchar](4000) NULL,
	[ArchiveSchema] [sysname] NOT NULL,
	[ArchiveTable] [sysname] NULL,
	[RequireArchiveForDelete] [bit] NOT NULL,
	[NaturalKeyLabel] [nvarchar](50) NULL,
 CONSTRAINT [PK_ObjectSpec] PRIMARY KEY CLUSTERED 
(
	[ObjectSpecId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
ALTER TABLE [arch].[ObjectSpec] ADD  CONSTRAINT [DF_ObjectSpec_ArchSchema]  DEFAULT (N'dbo') FOR [ArchiveSchema]
GO

ALTER TABLE [arch].[ObjectSpec] ADD  CONSTRAINT [DF_ObjectSpec_ReqArch]  DEFAULT ((1)) FOR [RequireArchiveForDelete]
GO

ALTER TABLE [arch].[ObjectSpec]  WITH CHECK ADD  CONSTRAINT [FK_ObjectSpec_Process] FOREIGN KEY([ProcessId])
REFERENCES [arch].[Process] ([ProcessId])
GO

ALTER TABLE [arch].[ObjectSpec] CHECK CONSTRAINT [FK_ObjectSpec_Process]
GO

ALTER TABLE [arch].[ObjectSpec]  WITH CHECK ADD  CONSTRAINT [CK_ObjectSpec_DeleteMode] CHECK  (([DeleteMode]=(1) OR [DeleteMode]=(0)))
GO

ALTER TABLE [arch].[ObjectSpec] CHECK CONSTRAINT [CK_ObjectSpec_DeleteMode]
GO

CREATE NONCLUSTERED INDEX [IX_ObjectSpec_Process_DeleteOrder]
ON [arch].[ObjectSpec] ([ProcessId], [DeleteOrder], [ObjectSpecId])
INCLUDE ([SourceSchema], [SourceTable], [DeleteMode], [TimestampExpr], [JoinToAnchorPredicateSql], [AdditionalWhereSql], [ArchiveSchema], [ArchiveTable], [RequireArchiveForDelete])
GO
