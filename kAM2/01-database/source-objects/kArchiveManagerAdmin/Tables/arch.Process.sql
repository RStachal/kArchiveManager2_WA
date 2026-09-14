USE [kArchiveManagerAdmin]
GO

/****** Object:  Table [arch].[Process]    Script Date: 08.04.2026 17:16:10 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [arch].[Process](
	[ProcessId] [int] IDENTITY(1,1) NOT NULL,
	[ProcessCode] [nvarchar](50) NOT NULL,
	[Description] [nvarchar](200) NULL,
	[IsEnabled] [bit] NOT NULL,
	[Mode] [tinyint] NOT NULL,
	[RetentionDays] [int] NOT NULL,
	[CutoffSafetyLagMinutes] [int] NOT NULL,
	[BatchDocCount] [int] NULL,
	[BatchRowCount] [int] NULL,
	[MaxBatchesPerRun] [int] NOT NULL,
	[DelayMsBetweenBatches] [int] NOT NULL,
	[UseAppLock] [bit] NOT NULL,
	[AppLockResource] [nvarchar](200) NULL,
	[LockTimeoutMs] [int] NOT NULL,
	[DeadlockPriority] [nvarchar](10) NOT NULL,
	[AnchorSchema] [sysname] NULL,
	[AnchorTable] [sysname] NULL,
	[AnchorDocKeyExpr] [nvarchar](4000) NULL,
	[AnchorDocKey2Expr] [nvarchar](4000) NULL,
	[AnchorTimestampExpr] [nvarchar](4000) NULL,
	[AnchorExtraWhereSql] [nvarchar](4000) NULL,
	[AllowDeleteWithoutArchive] [bit] NOT NULL,
	[CreatedAt] [datetime2](0) NOT NULL,
	[ModifiedAt] [datetime2](0) NOT NULL,
	[CutoffMode] [tinyint] NOT NULL,
	[CutoffDate] [datetime2](0) NULL,
	[DocKeyLabel] [nvarchar](50) NOT NULL,
 CONSTRAINT [PK_Process] PRIMARY KEY CLUSTERED 
(
	[ProcessId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY],
 CONSTRAINT [UQ_ProcessCode] UNIQUE NONCLUSTERED 
(
	[ProcessCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_IsEnabled]  DEFAULT ((1)) FOR [IsEnabled]
GO

ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_Lag]  DEFAULT ((60)) FOR [CutoffSafetyLagMinutes]
GO

ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_MaxBatches]  DEFAULT ((50)) FOR [MaxBatchesPerRun]
GO

ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_Delay]  DEFAULT ((0)) FOR [DelayMsBetweenBatches]
GO

ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_UseAppLock]  DEFAULT ((1)) FOR [UseAppLock]
GO

ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_LockTimeout]  DEFAULT ((10000)) FOR [LockTimeoutMs]
GO

ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_DLP]  DEFAULT (N'LOW') FOR [DeadlockPriority]
GO

ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_AllowDelNoArch]  DEFAULT ((0)) FOR [AllowDeleteWithoutArchive]
GO

ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_CreatedAt]  DEFAULT (sysutcdatetime()) FOR [CreatedAt]
GO

ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_ModifiedAt]  DEFAULT (sysutcdatetime()) FOR [ModifiedAt]
GO

ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_CutoffMode]  DEFAULT ((0)) FOR [CutoffMode]
GO

ALTER TABLE [arch].[Process] ADD  CONSTRAINT [DF_Process_DocKeyLabel]  DEFAULT (N'DOCKEY') FOR [DocKeyLabel]
GO

ALTER TABLE [arch].[Process]  WITH CHECK ADD  CONSTRAINT [CK_Process_CutoffMode] CHECK  (([CutoffMode]=(1) OR [CutoffMode]=(0)))
GO

ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_CutoffMode]
GO

ALTER TABLE [arch].[Process]  WITH CHECK ADD  CONSTRAINT [CK_Process_Mode] CHECK  (([Mode]=(1) OR [Mode]=(0) OR [Mode]=(2)))
GO

ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_Mode]
GO

ALTER TABLE [arch].[Process]  WITH CHECK ADD  CONSTRAINT [CK_Process_NonNegativeLimits] CHECK
(
    [RetentionDays] >= 0
    AND [CutoffSafetyLagMinutes] >= 0
    AND ([BatchDocCount] IS NULL OR [BatchDocCount] > 0)
    AND ([BatchRowCount] IS NULL OR [BatchRowCount] > 0)
    AND [MaxBatchesPerRun] > 0
    AND [DelayMsBetweenBatches] >= 0
    AND [LockTimeoutMs] >= 0
)
GO

ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_NonNegativeLimits]
GO

ALTER TABLE [arch].[Process]  WITH CHECK ADD  CONSTRAINT [CK_Process_DeadlockPriority] CHECK
(
    [DeadlockPriority] IN (N'LOW', N'NORMAL', N'HIGH')
)
GO

ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_DeadlockPriority]
GO
