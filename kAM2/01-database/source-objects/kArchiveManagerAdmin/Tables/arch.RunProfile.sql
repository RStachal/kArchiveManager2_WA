USE [kArchiveManagerAdmin]
GO

CREATE TABLE [arch].[RunProfile](
    [RunProfileId] [int] IDENTITY(1,1) NOT NULL,
    [RunProfileCode] [sysname] NOT NULL,
    [Description] [nvarchar](400) NULL,
    [IsEnabled] [bit] NOT NULL,
    [RunOnSchedule] [bit] NOT NULL,
    [RunOrder] [int] NOT NULL,
    [ProcessCodeFilter] [sysname] NULL,
    [SourceDbFilter] [sysname] NULL,
    [ArchiveDbFilter] [sysname] NULL,
    [RunWindowMinutes] [int] NOT NULL,
    [DryRun] [bit] NOT NULL,
    [MaxCandidates] [int] NULL,
    [PausedCooldownSeconds] [int] NOT NULL,
    [CreatedAt] [datetime2](0) NOT NULL,
    [ModifiedAt] [datetime2](0) NOT NULL,
 CONSTRAINT [PK_RunProfile] PRIMARY KEY CLUSTERED
(
    [RunProfileId] ASC
) ON [PRIMARY],
 CONSTRAINT [UQ_RunProfile_Code] UNIQUE NONCLUSTERED
(
    [RunProfileCode] ASC
) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_IsEnabled] DEFAULT ((1)) FOR [IsEnabled]
GO

ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_RunOnSchedule] DEFAULT ((0)) FOR [RunOnSchedule]
GO

ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_RunOrder] DEFAULT ((100)) FOR [RunOrder]
GO

ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_RunWindowMinutes] DEFAULT ((55)) FOR [RunWindowMinutes]
GO

ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_DryRun] DEFAULT ((0)) FOR [DryRun]
GO

ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_PausedCooldownSeconds] DEFAULT ((60)) FOR [PausedCooldownSeconds]
GO

ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt]
GO

ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt]
GO

ALTER TABLE [arch].[RunProfile] WITH CHECK ADD CONSTRAINT [CK_RunProfile_Limits] CHECK
(
    [RunWindowMinutes] > 0
    AND ([MaxCandidates] IS NULL OR [MaxCandidates] > 0)
    AND [PausedCooldownSeconds] >= 0
)
GO

ALTER TABLE [arch].[RunProfile] CHECK CONSTRAINT [CK_RunProfile_Limits]
GO

CREATE NONCLUSTERED INDEX [IX_RunProfile_Schedule]
ON [arch].[RunProfile] ([RunOnSchedule], [IsEnabled], [RunOrder], [RunProfileCode])
INCLUDE ([ProcessCodeFilter], [SourceDbFilter], [ArchiveDbFilter], [RunWindowMinutes], [DryRun], [MaxCandidates], [PausedCooldownSeconds])
GO
