-- ============================================================================
-- kArchiveManager 2.0 - CLEAN customer deploy (SSMS single-file, FLATTENED).
-- Auto-generated from deploy_clean_v2_full.sql (all :r includes inlined) so it runs in plain SSMS
-- WITHOUT SQLCMD Mode. Carries the same object set + all current fixes. Run on a FRESH kArchiveManagerAdmin.
-- Prefer deploy_clean_v2_full.sql (SQLCMD Mode) when you can; regenerate this file if sources change.
-- ============================================================================

-- ============================================================================
-- kArchiveManager 2.0 — CLEAN customer deploy (full v2, audit-hardened)
-- ============================================================================
-- Builds EXACTLY the production v2 object set on a fresh server. Pure v2:
--   * NO legacy_v1 schema, NO v1 procedures, NO v1 THROW-stub tombstones
--   * NO relic tables (RowCountSnapshot, *_Backup_*)
--   * NO smoke/test seed (WA_AAD_*_OSTRY_SMOKE)
--   * DB-specific process/mapping SEED is DEFERRED (customer DB names unknown) — see the separate
--     customer-seed step; this bundle only creates objects + the role model + the SelectionStrategy enum.
-- Includes all audit fixes (T-01..T-19, T-08, restore rowversion). SSMS: enable Query -> SQLCMD Mode.
-- Set Root to the ArchiveManager1.0 folder. Run verify_clean_deploy.sql afterwards (expects PASS).
--
-- ✅ VALIDATED end-to-end on a FRESH empty database (SQL Server 2019 LocalDB, 2026-06-04): deploys
--    Phases 0-13 with zero errors and verify_clean_deploy.sql returns PASS (all expected objects,
--    no v1/relics/smoke). Phase 14 jobs require SQL Agent (not present on LocalDB) — validate on a
--    real Agent-enabled instance.
-- NOTE: intended for a FRESH/empty kArchiveManagerAdmin. The Tables\ scripts use plain CREATE TABLE
--    (not IF-guarded), so RE-running on an already-populated DB errors on existing tables; for an
--    existing environment use the per-object update scripts instead of this whole-DB bundle.
-- ============================================================================
PRINT 'kArchiveManager 2.0 CLEAN deploy started. Root=<flattened>';
GO

-- ---- Phase 0: databases (control DB + archive DB shell) ----
-- >>> inlined: Databases\create_kArchiveManagerAdmin.sql
USE [master]
GO

IF DB_ID(N'kArchiveManagerAdmin') IS NULL
    CREATE DATABASE [kArchiveManagerAdmin];
GO

-- STRING_SPLIT (used by the config/validation/least-privilege scripts) requires DB compat >= 130.
-- A fresh DB inherits model's level; on an instance upgraded from <2016 model may still be 120-.
-- Pin a safe floor (150 = SQL 2019; valid on SQL 2019/2022). Idempotent.
IF (SELECT compatibility_level FROM sys.databases WHERE name = N'kArchiveManagerAdmin') < 150
    ALTER DATABASE [kArchiveManagerAdmin] SET COMPATIBILITY_LEVEL = 150;
GO
-- <<< end: Databases\create_kArchiveManagerAdmin.sql
GO
GO
-- >>> inlined: Databases\create_kArchiveManagerBackups.sql
USE [master]
GO

IF DB_ID(N'kArchiveManagerBackups') IS NULL
    CREATE DATABASE [kArchiveManagerBackups];
GO

-- The archive DB is the system-of-record for irreversibly deleted rows, so it MUST be in
-- FULL recovery for the hourly LOG-backup job (deploy/v2/048_archive_db_backup.sql) to be
-- effective — that job silently no-ops under SIMPLE. Set it explicitly instead of inheriting
-- whatever recovery model the server's [model] database happens to have.
IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N'kArchiveManagerBackups') <> N'FULL'
    ALTER DATABASE [kArchiveManagerBackups] SET RECOVERY FULL;
GO
-- <<< end: Databases\create_kArchiveManagerBackups.sql
GO
GO

-- ---- Phase 1: schema ----
-- >>> inlined: kArchiveManagerAdmin\schemas\arch.sql
USE [kArchiveManagerAdmin]
GO

IF SCHEMA_ID(N'arch') IS NULL
    EXEC(N'CREATE SCHEMA [arch] AUTHORIZATION [dbo]');
GO
-- <<< end: kArchiveManagerAdmin\schemas\arch.sql
GO
GO

-- ---- Phase 2: base tables (RowCountSnapshot relic intentionally OMITTED) ----
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.Process.sql
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
-- <<< end: kArchiveManagerAdmin\Tables\arch.Process.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.ObjectSpec.sql
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
-- <<< end: kArchiveManagerAdmin\Tables\arch.ObjectSpec.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.ProcessDatabase.sql
USE [kArchiveManagerAdmin]
GO

CREATE TABLE [arch].[ProcessDatabase](
    [ProcessDatabaseId] [int] IDENTITY(1,1) NOT NULL,
    [ProcessId] [int] NOT NULL,
    [SourceDb] [sysname] NOT NULL,
    [ArchiveDb] [sysname] NOT NULL,
    [IsEnabled] [bit] NOT NULL,
    [RunOrder] [int] NOT NULL,
    [Mode] [tinyint] NULL,
    [RetentionDays] [int] NULL,
    [CutoffSafetyLagMinutes] [int] NULL,
    [CutoffMode] [tinyint] NULL,
    [CutoffDate] [datetime2](0) NULL,
    [BatchDocCount] [int] NULL,
    [BatchRowCount] [int] NULL,
    [MaxBatchesPerRun] [int] NULL,
    [DelayMsBetweenBatches] [int] NULL,
    [UseAppLock] [bit] NULL,
    [AppLockResource] [nvarchar](200) NULL,
    [LockTimeoutMs] [int] NULL,
    [DeadlockPriority] [nvarchar](10) NULL,
    [AnchorSchema] [sysname] NULL,
    [AnchorTable] [sysname] NULL,
    [AnchorDocKeyExpr] [nvarchar](4000) NULL,
    [AnchorDocKey2Expr] [nvarchar](4000) NULL,
    [AnchorTimestampExpr] [nvarchar](4000) NULL,
    [AnchorExtraWhereSql] [nvarchar](4000) NULL,
    [AllowDeleteWithoutArchive] [bit] NULL,
    [DocKeyLabel] [nvarchar](50) NULL,
    [AuditLevel] [nvarchar](20) NULL,
    [RequireSupportingIndex] [bit] NULL,
    [MaxRowsPerTransaction] [int] NULL,
    [CandidateWhereSql] [nvarchar](4000) NULL,
    [CandidateOrderSql] [nvarchar](4000) NULL,
    [CreatedAt] [datetime2](0) NOT NULL,
    [ModifiedAt] [datetime2](0) NOT NULL,
 CONSTRAINT [PK_ProcessDatabase] PRIMARY KEY CLUSTERED
(
    [ProcessDatabaseId] ASC
) ON [PRIMARY],
 CONSTRAINT [UQ_ProcessDatabase_Process_Source_Archive] UNIQUE NONCLUSTERED
(
    [ProcessId] ASC,
    [SourceDb] ASC,
    [ArchiveDb] ASC
) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_IsEnabled] DEFAULT ((1)) FOR [IsEnabled]
GO

ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_RunOrder] DEFAULT ((100)) FOR [RunOrder]
GO

ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt]
GO

ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt]
GO

ALTER TABLE [arch].[ProcessDatabase] WITH CHECK ADD CONSTRAINT [FK_ProcessDatabase_Process] FOREIGN KEY([ProcessId])
REFERENCES [arch].[Process] ([ProcessId])
GO

ALTER TABLE [arch].[ProcessDatabase] CHECK CONSTRAINT [FK_ProcessDatabase_Process]
GO

ALTER TABLE [arch].[ProcessDatabase] WITH CHECK ADD CONSTRAINT [CK_ProcessDatabase_OverrideLimits] CHECK
(
    ([Mode] IS NULL OR [Mode] IN (0, 1, 2))   -- 0 delete-only, 1 archive+delete, 2 copy-only
    AND ([RetentionDays] IS NULL OR [RetentionDays] >= 0)
    AND ([CutoffSafetyLagMinutes] IS NULL OR [CutoffSafetyLagMinutes] >= 0)
    AND ([CutoffMode] IS NULL OR [CutoffMode] IN (0, 1))
    AND ([BatchDocCount] IS NULL OR [BatchDocCount] > 0)
    AND ([BatchRowCount] IS NULL OR [BatchRowCount] > 0)
    AND ([MaxBatchesPerRun] IS NULL OR [MaxBatchesPerRun] > 0)
    AND ([DelayMsBetweenBatches] IS NULL OR [DelayMsBetweenBatches] >= 0)
    AND ([LockTimeoutMs] IS NULL OR [LockTimeoutMs] >= 0)
    AND ([DeadlockPriority] IS NULL OR [DeadlockPriority] IN (N'LOW', N'NORMAL', N'HIGH'))
    AND ([AuditLevel] IS NULL OR [AuditLevel] IN (N'NONE', N'BATCH', N'OBJECT', N'ROW'))
    AND ([MaxRowsPerTransaction] IS NULL OR [MaxRowsPerTransaction] > 0)
)
GO

ALTER TABLE [arch].[ProcessDatabase] CHECK CONSTRAINT [CK_ProcessDatabase_OverrideLimits]
GO

CREATE NONCLUSTERED INDEX [IX_ProcessDatabase_Enabled_RunOrder]
ON [arch].[ProcessDatabase] ([IsEnabled], [RunOrder], [ProcessId])
INCLUDE ([SourceDb], [ArchiveDb])
GO
-- <<< end: kArchiveManagerAdmin\Tables\arch.ProcessDatabase.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.ObjectSpecDatabaseOverride.sql
USE [kArchiveManagerAdmin]
GO

CREATE TABLE [arch].[ObjectSpecDatabaseOverride](
    [ObjectSpecDatabaseOverrideId] [int] IDENTITY(1,1) NOT NULL,
    [ProcessDatabaseId] [int] NOT NULL,
    [ObjectSpecId] [int] NOT NULL,
    [IsEnabled] [bit] NOT NULL,
    [SourceSchemaOverride] [sysname] NULL,
    [SourceTableOverride] [sysname] NULL,
    [TimestampExprOverride] [nvarchar](4000) NULL,
    [JoinToAnchorPredicateSqlOverride] [nvarchar](4000) NULL,
    [AdditionalWhereSqlOverride] [nvarchar](4000) NULL,
    [ArchiveSchemaOverride] [sysname] NULL,
    [ArchiveTableOverride] [sysname] NULL,
    [RequireArchiveForDeleteOverride] [bit] NULL,
    [CreatedAt] [datetime2](0) NOT NULL,
    [ModifiedAt] [datetime2](0) NOT NULL,
 CONSTRAINT [PK_ObjectSpecDatabaseOverride] PRIMARY KEY CLUSTERED
(
    [ObjectSpecDatabaseOverrideId] ASC
) ON [PRIMARY],
 CONSTRAINT [UQ_ObjectSpecDatabaseOverride] UNIQUE NONCLUSTERED
(
    [ProcessDatabaseId] ASC,
    [ObjectSpecId] ASC
) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_IsEnabled] DEFAULT ((1)) FOR [IsEnabled]
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt]
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt]
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] WITH CHECK ADD CONSTRAINT [FK_ObjectSpecDatabaseOverride_ProcessDatabase] FOREIGN KEY([ProcessDatabaseId])
REFERENCES [arch].[ProcessDatabase] ([ProcessDatabaseId])
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] CHECK CONSTRAINT [FK_ObjectSpecDatabaseOverride_ProcessDatabase]
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] WITH CHECK ADD CONSTRAINT [FK_ObjectSpecDatabaseOverride_ObjectSpec] FOREIGN KEY([ObjectSpecId])
REFERENCES [arch].[ObjectSpec] ([ObjectSpecId])
GO

ALTER TABLE [arch].[ObjectSpecDatabaseOverride] CHECK CONSTRAINT [FK_ObjectSpecDatabaseOverride_ObjectSpec]
GO
-- <<< end: kArchiveManagerAdmin\Tables\arch.ObjectSpecDatabaseOverride.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.RunProfile.sql
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
-- <<< end: kArchiveManagerAdmin\Tables\arch.RunProfile.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.WorkBatch.sql
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
-- <<< end: kArchiveManagerAdmin\Tables\arch.WorkBatch.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.WorkBatchKey.sql
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
-- <<< end: kArchiveManagerAdmin\Tables\arch.WorkBatchKey.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.Run.sql
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
-- <<< end: kArchiveManagerAdmin\Tables\arch.Run.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.RunItem.sql
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
-- <<< end: kArchiveManagerAdmin\Tables\arch.RunItem.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.RunItemObject.sql
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
-- <<< end: kArchiveManagerAdmin\Tables\arch.RunItemObject.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.RunDocAudit.sql
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
-- <<< end: kArchiveManagerAdmin\Tables\arch.RunDocAudit.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\Tables\arch.ArchiveProvisionLog.sql
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
-- <<< end: kArchiveManagerAdmin\Tables\arch.ArchiveProvisionLog.sql
GO
GO

-- ---- Phase 3: v2 upgrade shims + core (creates ProcessKeySpec/IndexRequirement/SelectionStrategy
--               + seeds the SelectionStrategy enum) ----
-- >>> inlined: kArchiveManagerAdmin\v2\001_upgrade_to_2_0.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF SCHEMA_ID(N'arch') IS NULL
    EXEC(N'CREATE SCHEMA [arch]');
GO

IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
   AND COL_LENGTH(N'arch.Process', N'AnchorDocKey2Expr') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [AnchorDocKey2Expr] [nvarchar](4000) NULL;
END
GO

IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.Process') AND name = N'CK_Process_Mode')
BEGIN
    ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_Mode] CHECK (([Mode]=(1) OR [Mode]=(0)));
    ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_Mode];
END
GO

IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.Process') AND name = N'CK_Process_NonNegativeLimits')
BEGIN
    ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_NonNegativeLimits] CHECK
    (
        [RetentionDays] >= 0
        AND [CutoffSafetyLagMinutes] >= 0
        AND ([BatchDocCount] IS NULL OR [BatchDocCount] > 0)
        AND ([BatchRowCount] IS NULL OR [BatchRowCount] > 0)
        AND [MaxBatchesPerRun] > 0
        AND [DelayMsBetweenBatches] >= 0
        AND [LockTimeoutMs] >= 0
    );
    ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_NonNegativeLimits];
END
GO

IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.Process') AND name = N'CK_Process_DeadlockPriority')
BEGIN
    ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_DeadlockPriority] CHECK
    (
        [DeadlockPriority] IN (N'LOW', N'NORMAL', N'HIGH')
    );
    ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_DeadlockPriority];
END
GO

IF OBJECT_ID(N'arch.ObjectSpec', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.ObjectSpec') AND name = N'CK_ObjectSpec_DeleteMode')
BEGIN
    ALTER TABLE [arch].[ObjectSpec] WITH CHECK ADD CONSTRAINT [CK_ObjectSpec_DeleteMode] CHECK (([DeleteMode]=(1) OR [DeleteMode]=(0)));
    ALTER TABLE [arch].[ObjectSpec] CHECK CONSTRAINT [CK_ObjectSpec_DeleteMode];
END
GO

IF OBJECT_ID(N'arch.ObjectSpec', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.ObjectSpec') AND name = N'IX_ObjectSpec_Process_DeleteOrder')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_ObjectSpec_Process_DeleteOrder]
    ON [arch].[ObjectSpec] ([ProcessId], [DeleteOrder], [ObjectSpecId])
    INCLUDE ([SourceSchema], [SourceTable], [DeleteMode], [TimestampExpr], [JoinToAnchorPredicateSql], [AdditionalWhereSql], [ArchiveSchema], [ArchiveTable], [RequireArchiveForDelete]);
END
GO

IF OBJECT_ID(N'arch.WorkBatch', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.WorkBatch') AND name = N'CK_WorkBatch_Status')
BEGIN
    ALTER TABLE [arch].[WorkBatch] WITH CHECK ADD CONSTRAINT [CK_WorkBatch_Status] CHECK
    (
        [Status] IN ('Prepared', 'Running', 'Paused', 'Completed', 'Failed')
    );
    ALTER TABLE [arch].[WorkBatch] CHECK CONSTRAINT [CK_WorkBatch_Status];
END
GO

IF OBJECT_ID(N'arch.WorkBatch', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.WorkBatch') AND name = N'IX_WorkBatch_Process_Status')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_WorkBatch_Process_Status]
    ON [arch].[WorkBatch] ([ProcessId], [Status], [PreparedAtUtc], [WorkBatchId])
    INCLUDE ([SourceDb], [ArchiveDb], [LastProgressAtUtc]);
END
GO

IF OBJECT_ID(N'arch.WorkBatchKey', N'U') IS NOT NULL
   AND COL_LENGTH(N'arch.WorkBatchKey', N'AnchorRowGuid') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [AnchorRowGuid] [uniqueidentifier] NULL;
END
GO

IF OBJECT_ID(N'arch.WorkBatchKey', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.WorkBatchKey') AND name = N'CK_WorkBatchKey_Status')
BEGIN
    ALTER TABLE [arch].[WorkBatchKey] WITH CHECK ADD CONSTRAINT [CK_WorkBatchKey_Status] CHECK (([Status]>=(0) AND [Status]<=(3)));
    ALTER TABLE [arch].[WorkBatchKey] CHECK CONSTRAINT [CK_WorkBatchKey_Status];
END
GO

IF OBJECT_ID(N'arch.WorkBatchKey', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.WorkBatchKey') AND name = N'IX_WorkBatchKey_Claim')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_WorkBatchKey_Claim]
    ON [arch].[WorkBatchKey] ([WorkBatchId], [Status], [DocCreatedAt], [Key1], [Key2])
    INCLUDE ([Attempts], [AnchorRowId], [AnchorRowGuid], [ClaimedAtUtc]);
END
GO

IF OBJECT_ID(N'arch.ProcessDatabase', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ProcessDatabase](
        [ProcessDatabaseId] [int] IDENTITY(1,1) NOT NULL,
        [ProcessId] [int] NOT NULL,
        [SourceDb] [sysname] NOT NULL,
        [ArchiveDb] [sysname] NOT NULL,
        [IsEnabled] [bit] NOT NULL,
        [RunOrder] [int] NOT NULL,
        [CreatedAt] [datetime2](0) NOT NULL,
        [ModifiedAt] [datetime2](0) NOT NULL,
     CONSTRAINT [PK_ProcessDatabase] PRIMARY KEY CLUSTERED
    (
        [ProcessDatabaseId] ASC
    ) ON [PRIMARY],
     CONSTRAINT [UQ_ProcessDatabase_Process_Source_Archive] UNIQUE NONCLUSTERED
    (
        [ProcessId] ASC,
        [SourceDb] ASC,
        [ArchiveDb] ASC
    ) ON [PRIMARY]
    ) ON [PRIMARY];

    ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_IsEnabled] DEFAULT ((1)) FOR [IsEnabled];
    ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_RunOrder] DEFAULT ((100)) FOR [RunOrder];
    ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt];
    ALTER TABLE [arch].[ProcessDatabase] ADD CONSTRAINT [DF_ProcessDatabase_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt];
    ALTER TABLE [arch].[ProcessDatabase] WITH CHECK ADD CONSTRAINT [FK_ProcessDatabase_Process] FOREIGN KEY([ProcessId]) REFERENCES [arch].[Process] ([ProcessId]);
    ALTER TABLE [arch].[ProcessDatabase] CHECK CONSTRAINT [FK_ProcessDatabase_Process];
END
GO

IF OBJECT_ID(N'arch.ProcessDatabase', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.ProcessDatabase') AND name = N'IX_ProcessDatabase_Enabled_RunOrder')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_ProcessDatabase_Enabled_RunOrder]
    ON [arch].[ProcessDatabase] ([IsEnabled], [RunOrder], [ProcessId])
    INCLUDE ([SourceDb], [ArchiveDb]);
END
GO

IF OBJECT_ID(N'arch.RowCountSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[RowCountSnapshot](
        [SnapshotId] [bigint] IDENTITY(1,1) NOT NULL,
        [SnapshotAtUtc] [datetime2](0) NOT NULL,
        [SourceDb] [sysname] NOT NULL,
        [ArchiveDb] [sysname] NOT NULL,
        [ProcessCode] [nvarchar](50) NOT NULL,
        [SourceSchema] [sysname] NOT NULL,
        [SourceTable] [sysname] NOT NULL,
        [ArchiveSchema] [sysname] NOT NULL,
        [ArchiveTable] [sysname] NOT NULL,
        [SourceRows] [bigint] NOT NULL,
        [ArchivedRows] [bigint] NOT NULL,
     CONSTRAINT [PK_RowCountSnapshot] PRIMARY KEY CLUSTERED
    (
        [SnapshotId] ASC
    ) ON [PRIMARY]
    ) ON [PRIMARY];

    ALTER TABLE [arch].[RowCountSnapshot] ADD CONSTRAINT [DF_RowCountSnapshot_SnapshotAt] DEFAULT (sysutcdatetime()) FOR [SnapshotAtUtc];
    ALTER TABLE [arch].[RowCountSnapshot] WITH CHECK ADD CONSTRAINT [CK_RowCountSnapshot_NonNegativeRows] CHECK
    (
        [SourceRows] >= 0
        AND [ArchivedRows] >= 0
    );
    ALTER TABLE [arch].[RowCountSnapshot] CHECK CONSTRAINT [CK_RowCountSnapshot_NonNegativeRows];
END
GO

IF OBJECT_ID(N'arch.RowCountSnapshot', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.RowCountSnapshot') AND name = N'IX_RowCountSnapshot_Time_Process')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RowCountSnapshot_Time_Process]
    ON [arch].[RowCountSnapshot] ([SnapshotAtUtc] DESC, [ProcessCode], [SourceDb])
    INCLUDE ([ArchiveDb], [SourceSchema], [SourceTable], [ArchiveSchema], [ArchiveTable], [SourceRows], [ArchivedRows]);
END
GO

IF OBJECT_ID(N'arch.Run', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.Run') AND name = N'CK_Run_Status')
BEGIN
    ALTER TABLE [arch].[Run] WITH CHECK ADD CONSTRAINT [CK_Run_Status] CHECK
    (
        [Status] IN (N'RUNNING', N'OK', N'FAILED', N'DRYRUN')
    );
    ALTER TABLE [arch].[Run] CHECK CONSTRAINT [CK_Run_Status];
END
GO

IF OBJECT_ID(N'arch.ArchiveProvisionLog', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.ArchiveProvisionLog') AND name = N'IX_ArchiveProvisionLog_Source')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_ArchiveProvisionLog_Source]
    ON [arch].[ArchiveProvisionLog] ([SourceDb], [ArchiveDb], [SourceSchema], [SourceTable], [LoggedAt] DESC)
    INCLUDE ([Action]);
END
GO

IF OBJECT_ID(N'arch.Run', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.Run') AND name = N'IX_Run_Source_Status')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_Run_Source_Status]
    ON [arch].[Run] ([SourceDb], [Status], [RunId] DESC)
    INCLUDE ([ArchiveDb], [StartedAt], [EndedAt]);
END
GO

IF OBJECT_ID(N'arch.RunItem', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.RunItem') AND name = N'CK_RunItem_Status')
BEGIN
    ALTER TABLE [arch].[RunItem] WITH CHECK ADD CONSTRAINT [CK_RunItem_Status] CHECK
    (
        [Status] IN (N'RUNNING', N'OK', N'FAILED', N'DRYRUN')
    );
    ALTER TABLE [arch].[RunItem] CHECK CONSTRAINT [CK_RunItem_Status];
END
GO

IF OBJECT_ID(N'arch.RunItem', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.RunItem') AND name = N'CK_RunItem_NonNegativeTotals')
BEGIN
    ALTER TABLE [arch].[RunItem] WITH CHECK ADD CONSTRAINT [CK_RunItem_NonNegativeTotals] CHECK
    (
        [BatchesDone] >= 0
        AND [DocsDone] >= 0
        AND [RowsDeleted] >= 0
        AND [RowsArchived] >= 0
    );
    ALTER TABLE [arch].[RunItem] CHECK CONSTRAINT [CK_RunItem_NonNegativeTotals];
END
GO

IF OBJECT_ID(N'arch.RunItem', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.RunItem') AND name = N'IX_RunItem_Process_Status')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RunItem_Process_Status]
    ON [arch].[RunItem] ([ProcessId], [Status], [RunId] DESC, [RunItemId] DESC)
    INCLUDE ([Mode], [AsOfUtc], [CutoffUtc], [RowsDeleted], [RowsArchived]);
END
GO

IF OBJECT_ID(N'arch.RunDocAudit', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.RunDocAudit') AND name = N'IX_RunDocAudit_RunItem')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RunDocAudit_RunItem]
    ON [arch].[RunDocAudit] ([RunItemId])
    INCLUDE ([DocKey], [DocCreatedAt], [Archived]);
END
GO

IF OBJECT_ID(N'arch.RunItemObject', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'arch.RunItemObject') AND name = N'CK_RunItemObject_NonNegativeRows')
BEGIN
    ALTER TABLE [arch].[RunItemObject] WITH CHECK ADD CONSTRAINT [CK_RunItemObject_NonNegativeRows] CHECK
    (
        [RowsDeleted] >= 0
        AND [RowsArchived] >= 0
    );
    ALTER TABLE [arch].[RunItemObject] CHECK CONSTRAINT [CK_RunItemObject_NonNegativeRows];
END
GO

IF OBJECT_ID(N'arch.RunItemObject', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.RunItemObject') AND name = N'IX_RunItemObject_RunItem')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RunItemObject_RunItem]
    ON [arch].[RunItemObject] ([RunItemId], [SourceSchema], [SourceTable])
    INCLUDE ([RowsDeleted], [RowsArchived]);
END
GO
-- <<< end: kArchiveManagerAdmin\v2\001_upgrade_to_2_0.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\010_universal_archive_core.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF COL_LENGTH(N'arch.Process', N'SelectionStrategy') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [SelectionStrategy] [nvarchar](30) NOT NULL
        CONSTRAINT [DF_Process_SelectionStrategy] DEFAULT (N'ANCHOR');
END
GO

IF COL_LENGTH(N'arch.Process', N'AuditLevel') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [AuditLevel] [nvarchar](20) NOT NULL
        CONSTRAINT [DF_Process_AuditLevel] DEFAULT (N'BATCH');
END
GO

IF COL_LENGTH(N'arch.Process', N'RequireSupportingIndex') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [RequireSupportingIndex] [bit] NOT NULL
        CONSTRAINT [DF_Process_RequireSupportingIndex] DEFAULT ((1));
END
GO

IF COL_LENGTH(N'arch.Process', N'MaxRowsPerTransaction') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [MaxRowsPerTransaction] [int] NULL;
END
GO

IF COL_LENGTH(N'arch.Process', N'CandidateWhereSql') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [CandidateWhereSql] [nvarchar](4000) NULL;
END
GO

IF COL_LENGTH(N'arch.Process', N'CandidateOrderSql') IS NULL
BEGIN
    ALTER TABLE [arch].[Process]
    ADD [CandidateOrderSql] [nvarchar](4000) NULL;
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key3') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key3] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key3] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key4') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key4] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key4] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key5') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key5] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key5] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key6') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key6] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key6] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key7') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key7] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key7] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'Key8') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [Key8] [nvarchar](256) NOT NULL CONSTRAINT [DF_WBK_Key8] DEFAULT (N'');
END
GO

IF COL_LENGTH(N'arch.WorkBatchKey', N'CandidateHash') IS NULL
BEGIN
    ALTER TABLE [arch].[WorkBatchKey]
    ADD [CandidateHash] [varbinary](32) NULL;
END
GO

IF COL_LENGTH(N'arch.RowCountSnapshot', N'ProcessCode') IS NOT NULL
   AND COL_LENGTH(N'arch.RowCountSnapshot', N'ProcessCode') < 100
BEGIN
    IF EXISTS
    (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'arch.RowCountSnapshot')
          AND name = N'IX_RowCountSnapshot_Time_Process'
    )
    BEGIN
        DROP INDEX [IX_RowCountSnapshot_Time_Process] ON [arch].[RowCountSnapshot];
    END;

    ALTER TABLE [arch].[RowCountSnapshot]
    ALTER COLUMN [ProcessCode] [nvarchar](50) NOT NULL;
END
GO

IF OBJECT_ID(N'arch.SelectionStrategy', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[SelectionStrategy](
        [StrategyCode] [nvarchar](30) NOT NULL,
        [Description] [nvarchar](400) NOT NULL,
        [RequiresAnchor] [bit] NOT NULL,
        [RequiresTimestamp] [bit] NOT NULL,
        [RequiresRange] [bit] NOT NULL,
        [RequiresExternalKeyset] [bit] NOT NULL,
        [IsEnabled] [bit] NOT NULL,
        CONSTRAINT [PK_SelectionStrategy] PRIMARY KEY CLUSTERED ([StrategyCode] ASC)
    );
END
GO

MERGE [arch].[SelectionStrategy] AS tgt
USING (VALUES
    (N'ANCHOR',       N'Parent/anchor row selection followed by configured child-table joins.', 1, 0, 0, 0, 1),
    (N'KEYSET',       N'Externally supplied or staged keyset processed through configured joins.', 0, 0, 0, 1, 1),
    (N'RANGE',        N'Bounded monotonic key range, usually identity or sequence based.', 0, 0, 1, 0, 1),
    (N'TIMESTAMP',    N'Indexed timestamp cutoff selection.', 0, 1, 0, 0, 1),
    (N'PARTITION',    N'Partition-level archive/delete where schema supports switching.', 0, 0, 0, 0, 1),
    (N'CUSTOM_QUERY', N'Reviewed custom candidate query emitting the standard key shape.', 0, 0, 0, 0, 1),
    (N'ORPHAN',       N'Child rows without matching parent rows, using indexed anti-join.', 0, 0, 0, 0, 1),
    (N'SOFT_DELETE',  N'Status/flag-based cleanup with optional cutoff.', 0, 0, 0, 0, 1)
) AS src(StrategyCode, Description, RequiresAnchor, RequiresTimestamp, RequiresRange, RequiresExternalKeyset, IsEnabled)
ON tgt.StrategyCode = src.StrategyCode
WHEN MATCHED THEN UPDATE SET
    Description = src.Description,
    RequiresAnchor = src.RequiresAnchor,
    RequiresTimestamp = src.RequiresTimestamp,
    RequiresRange = src.RequiresRange,
    RequiresExternalKeyset = src.RequiresExternalKeyset,
    IsEnabled = src.IsEnabled
WHEN NOT MATCHED THEN INSERT
(
    StrategyCode, Description, RequiresAnchor, RequiresTimestamp, RequiresRange, RequiresExternalKeyset, IsEnabled
)
VALUES
(
    src.StrategyCode, src.Description, src.RequiresAnchor, src.RequiresTimestamp, src.RequiresRange, src.RequiresExternalKeyset, src.IsEnabled
);
GO

IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ProcessKeySpec](
        [ProcessKeySpecId] [int] IDENTITY(1,1) NOT NULL,
        [ProcessId] [int] NOT NULL,
        [KeyOrdinal] [tinyint] NOT NULL,
        [KeyName] [sysname] NOT NULL,
        [SourceExpressionSql] [nvarchar](4000) NOT NULL,
        [SqlType] [nvarchar](128) NOT NULL,
        [IsRequired] [bit] NOT NULL,
        [CreatedAt] [datetime2](0) NOT NULL,
        [ModifiedAt] [datetime2](0) NOT NULL,
        CONSTRAINT [PK_ProcessKeySpec] PRIMARY KEY CLUSTERED ([ProcessKeySpecId] ASC),
        CONSTRAINT [UQ_ProcessKeySpec_Process_Ordinal] UNIQUE NONCLUSTERED ([ProcessId] ASC, [KeyOrdinal] ASC),
        CONSTRAINT [FK_ProcessKeySpec_Process] FOREIGN KEY([ProcessId]) REFERENCES [arch].[Process] ([ProcessId]),
        CONSTRAINT [CK_ProcessKeySpec_KeyOrdinal] CHECK ([KeyOrdinal] BETWEEN 1 AND 8)
    );

    ALTER TABLE [arch].[ProcessKeySpec] ADD CONSTRAINT [DF_ProcessKeySpec_IsRequired] DEFAULT ((1)) FOR [IsRequired];
    ALTER TABLE [arch].[ProcessKeySpec] ADD CONSTRAINT [DF_ProcessKeySpec_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt];
    ALTER TABLE [arch].[ProcessKeySpec] ADD CONSTRAINT [DF_ProcessKeySpec_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt];
END
GO

IF OBJECT_ID(N'arch.IndexRequirement', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[IndexRequirement](
        [IndexRequirementId] [int] IDENTITY(1,1) NOT NULL,
        [ProcessId] [int] NOT NULL,
        [ObjectSpecId] [int] NULL,
        [RequirementType] [nvarchar](20) NOT NULL,
        [SourceSchema] [sysname] NOT NULL,
        [SourceTable] [sysname] NOT NULL,
        [KeyColumnsCsv] [nvarchar](1000) NOT NULL,
        [IncludeColumnsCsv] [nvarchar](1000) NULL,
        [FilterSql] [nvarchar](1000) NULL,
        [IsMandatory] [bit] NOT NULL,
        [Notes] [nvarchar](1000) NULL,
        [CreatedAt] [datetime2](0) NOT NULL,
        [ModifiedAt] [datetime2](0) NOT NULL,
        CONSTRAINT [PK_IndexRequirement] PRIMARY KEY CLUSTERED ([IndexRequirementId] ASC),
        CONSTRAINT [FK_IndexRequirement_Process] FOREIGN KEY([ProcessId]) REFERENCES [arch].[Process] ([ProcessId]),
        CONSTRAINT [FK_IndexRequirement_ObjectSpec] FOREIGN KEY([ObjectSpecId]) REFERENCES [arch].[ObjectSpec] ([ObjectSpecId]),
        CONSTRAINT [CK_IndexRequirement_Type] CHECK ([RequirementType] IN (N'SELECTION', N'JOIN', N'DELETE', N'ORDER', N'PARTITION'))
    );

    ALTER TABLE [arch].[IndexRequirement] ADD CONSTRAINT [DF_IndexRequirement_IsMandatory] DEFAULT ((1)) FOR [IsMandatory];
    ALTER TABLE [arch].[IndexRequirement] ADD CONSTRAINT [DF_IndexRequirement_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt];
    ALTER TABLE [arch].[IndexRequirement] ADD CONSTRAINT [DF_IndexRequirement_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt];
END
GO

IF OBJECT_ID(N'arch.RunProfile', N'U') IS NULL
BEGIN
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
        CONSTRAINT [PK_RunProfile] PRIMARY KEY CLUSTERED ([RunProfileId] ASC),
        CONSTRAINT [UQ_RunProfile_Code] UNIQUE NONCLUSTERED ([RunProfileCode] ASC)
    );

    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_IsEnabled] DEFAULT ((1)) FOR [IsEnabled];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_RunOnSchedule] DEFAULT ((0)) FOR [RunOnSchedule];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_RunOrder] DEFAULT ((100)) FOR [RunOrder];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_RunWindowMinutes] DEFAULT ((55)) FOR [RunWindowMinutes];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_DryRun] DEFAULT ((0)) FOR [DryRun];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_PausedCooldownSeconds] DEFAULT ((60)) FOR [PausedCooldownSeconds];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt];
    ALTER TABLE [arch].[RunProfile] ADD CONSTRAINT [DF_RunProfile_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt];
    ALTER TABLE [arch].[RunProfile] WITH CHECK ADD CONSTRAINT [CK_RunProfile_Limits] CHECK
    (
        [RunWindowMinutes] > 0
        AND ([MaxCandidates] IS NULL OR [MaxCandidates] > 0)
        AND [PausedCooldownSeconds] >= 0
    );
    ALTER TABLE [arch].[RunProfile] CHECK CONSTRAINT [CK_RunProfile_Limits];
END
GO

IF OBJECT_ID(N'arch.RunProfile', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'arch.RunProfile') AND name = N'IX_RunProfile_Schedule')
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RunProfile_Schedule]
    ON [arch].[RunProfile] ([RunOnSchedule], [IsEnabled], [RunOrder], [RunProfileCode])
    INCLUDE ([ProcessCodeFilter], [SourceDbFilter], [ArchiveDbFilter], [RunWindowMinutes], [DryRun], [MaxCandidates], [PausedCooldownSeconds]);
END
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.IndexRequirement')
      AND name = N'IX_IndexRequirement_Process_Object'
)
BEGIN
    CREATE NONCLUSTERED INDEX [IX_IndexRequirement_Process_Object]
    ON [arch].[IndexRequirement] ([ProcessId], [ObjectSpecId], [RequirementType])
    INCLUDE ([SourceSchema], [SourceTable], [KeyColumnsCsv], [IsMandatory]);
END
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.WorkBatchKey')
      AND name = N'IX_WorkBatchKey_CandidateHash'
)
BEGIN
    CREATE NONCLUSTERED INDEX [IX_WorkBatchKey_CandidateHash]
    ON [arch].[WorkBatchKey] ([WorkBatchId], [CandidateHash])
    INCLUDE ([Key1], [Key2], [Key3], [Key4], [Key5], [Key6], [Key7], [Key8], [Status])
    WHERE [CandidateHash] IS NOT NULL;
END
GO

IF OBJECT_ID(N'arch.RowCountSnapshot', N'U') IS NOT NULL
   AND NOT EXISTS
   (
       SELECT 1
       FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'arch.RowCountSnapshot')
         AND name = N'IX_RowCountSnapshot_Time_Process'
   )
BEGIN
    CREATE NONCLUSTERED INDEX [IX_RowCountSnapshot_Time_Process]
    ON [arch].[RowCountSnapshot] ([SnapshotAtUtc] DESC, [ProcessCode], [SourceDb])
    INCLUDE ([ArchiveDb], [SourceSchema], [SourceTable], [ArchiveSchema], [ArchiveTable], [SourceRows], [ArchivedRows]);
END
GO

IF EXISTS
(
    SELECT 1
    FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'arch.Process')
      AND name = N'CK_Process_SelectionStrategy'
)
BEGIN
    ALTER TABLE [arch].[Process] DROP CONSTRAINT [CK_Process_SelectionStrategy];
END
GO

ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_SelectionStrategy] CHECK
(
    [SelectionStrategy] IN
    (
        N'ANCHOR',
        N'KEYSET',
        N'RANGE',
        N'TIMESTAMP',
        N'PARTITION',
        N'CUSTOM_QUERY',
        N'ORPHAN',
        N'SOFT_DELETE'
    )
);
GO

ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_SelectionStrategy];
GO

IF EXISTS
(
    SELECT 1
    FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'arch.Process')
      AND name = N'CK_Process_AuditLevel'
)
BEGIN
    ALTER TABLE [arch].[Process] DROP CONSTRAINT [CK_Process_AuditLevel];
END
GO

ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_AuditLevel] CHECK
(
    [AuditLevel] IN (N'NONE', N'BATCH', N'OBJECT', N'ROW')
);
GO

ALTER TABLE [arch].[Process] CHECK CONSTRAINT [CK_Process_AuditLevel];
GO
-- <<< end: kArchiveManagerAdmin\v2\010_universal_archive_core.sql
GO
GO
-- 001 creates the v1-era arch.RowCountSnapshot metrics table (only the quarantined v1
-- usp_CaptureRowCountSnapshot used it); 010's references to it are all OBJECT_ID-guarded no-ops.
-- Drop it so the clean install carries no relic table.
USE [kArchiveManagerAdmin];
GO
DROP TABLE IF EXISTS [arch].[RowCountSnapshot];
GO

-- ---- Phase 4: change-set / audit tables + changeset procs (frontend/004 creates ConfigChange*) ----
-- >>> inlined: kArchiveManagerAdmin\frontend\004_frontend_audit.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID(N'arch.ConfigChangeSet', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ConfigChangeSet](
        [ConfigChangeSetId] [bigint] IDENTITY(1,1) NOT NULL,
        [ChangeStatus] [nvarchar](20) NOT NULL,
        [RequestedBy] [nvarchar](256) NOT NULL,
        [RequestedAtUtc] [datetime2](0) NOT NULL,
        [ApprovedBy] [nvarchar](256) NULL,
        [ApprovedAtUtc] [datetime2](0) NULL,
        [PublishedBy] [nvarchar](256) NULL,
        [PublishedAtUtc] [datetime2](0) NULL,
        [ChangeReason] [nvarchar](1000) NULL,
        [ValidationStatus] [nvarchar](20) NULL,
        [ValidationSummary] [nvarchar](4000) NULL,
        CONSTRAINT [PK_ConfigChangeSet] PRIMARY KEY CLUSTERED ([ConfigChangeSetId] ASC),
        CONSTRAINT [CK_ConfigChangeSet_Status] CHECK ([ChangeStatus] IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED', N'PUBLISHED', N'REJECTED', N'CANCELLED')),
        CONSTRAINT [CK_ConfigChangeSet_ValidationStatus] CHECK ([ValidationStatus] IS NULL OR [ValidationStatus] IN (N'NOT_RUN', N'OK', N'WARN', N'ERROR'))
    );

    ALTER TABLE [arch].[ConfigChangeSet]
    ADD CONSTRAINT [DF_ConfigChangeSet_Status] DEFAULT (N'DRAFT') FOR [ChangeStatus];

    ALTER TABLE [arch].[ConfigChangeSet]
    ADD CONSTRAINT [DF_ConfigChangeSet_RequestedAt] DEFAULT (SYSUTCDATETIME()) FOR [RequestedAtUtc];

    ALTER TABLE [arch].[ConfigChangeSet]
    ADD CONSTRAINT [DF_ConfigChangeSet_ValidationStatus] DEFAULT (N'NOT_RUN') FOR [ValidationStatus];
END
GO

IF OBJECT_ID(N'arch.ConfigChangeItem', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ConfigChangeItem](
        [ConfigChangeItemId] [bigint] IDENTITY(1,1) NOT NULL,
        [ConfigChangeSetId] [bigint] NOT NULL,
        [EntityType] [nvarchar](80) NOT NULL,
        [EntityKey] [nvarchar](400) NOT NULL,
        [Operation] [nvarchar](20) NOT NULL,
        [ObjectId] [int] NULL,
        [CreatedAtUtc] [datetime2](0) NOT NULL,
        CONSTRAINT [PK_ConfigChangeItem] PRIMARY KEY CLUSTERED ([ConfigChangeItemId] ASC),
        CONSTRAINT [FK_ConfigChangeItem_ChangeSet] FOREIGN KEY ([ConfigChangeSetId]) REFERENCES [arch].[ConfigChangeSet]([ConfigChangeSetId]),
        CONSTRAINT [CK_ConfigChangeItem_Operation] CHECK ([Operation] IN (N'INSERT', N'UPDATE', N'DELETE'))
    );

    ALTER TABLE [arch].[ConfigChangeItem]
    ADD CONSTRAINT [DF_ConfigChangeItem_CreatedAt] DEFAULT (SYSUTCDATETIME()) FOR [CreatedAtUtc];

    CREATE NONCLUSTERED INDEX [IX_ConfigChangeItem_ChangeSet]
    ON [arch].[ConfigChangeItem] ([ConfigChangeSetId], [EntityType], [EntityKey])
    INCLUDE ([Operation], [ObjectId], [CreatedAtUtc]);
END
GO

IF OBJECT_ID(N'arch.ConfigChangeField', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ConfigChangeField](
        [ConfigChangeFieldId] [bigint] IDENTITY(1,1) NOT NULL,
        [ConfigChangeItemId] [bigint] NOT NULL,
        [FieldName] [sysname] NOT NULL,
        [OldValue] [nvarchar](max) NULL,
        [NewValue] [nvarchar](max) NULL,
        [IsAdvancedField] [bit] NOT NULL,
        CONSTRAINT [PK_ConfigChangeField] PRIMARY KEY CLUSTERED ([ConfigChangeFieldId] ASC),
        CONSTRAINT [FK_ConfigChangeField_Item] FOREIGN KEY ([ConfigChangeItemId]) REFERENCES [arch].[ConfigChangeItem]([ConfigChangeItemId])
    );

    ALTER TABLE [arch].[ConfigChangeField]
    ADD CONSTRAINT [DF_ConfigChangeField_IsAdvanced] DEFAULT ((0)) FOR [IsAdvancedField];

    CREATE NONCLUSTERED INDEX [IX_ConfigChangeField_Item]
    ON [arch].[ConfigChangeField] ([ConfigChangeItemId], [FieldName])
    INCLUDE ([IsAdvancedField]);
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_CreateConfigChangeSet]
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @ConfigChangeSetId bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@RequestedBy)), N'') IS NULL
        THROW 56300, 'RequestedBy is required.', 1;

    INSERT INTO arch.ConfigChangeSet
    (
        ChangeStatus,
        RequestedBy,
        RequestedAtUtc,
        ChangeReason,
        ValidationStatus
    )
    VALUES
    (
        N'DRAFT',
        @RequestedBy,
        SYSUTCDATETIME(),
        NULLIF(LTRIM(RTRIM(@ChangeReason)), N''),
        N'NOT_RUN'
    );

    SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        ChangeStatus = N'DRAFT',
        RequestedBy = @RequestedBy,
        ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_RecordConfigFieldChange]
    @ConfigChangeSetId bigint,
    @EntityType nvarchar(80),
    @EntityKey nvarchar(400),
    @Operation nvarchar(20),
    @ObjectId int = NULL,
    @FieldName sysname,
    @OldValue nvarchar(max) = NULL,
    @NewValue nvarchar(max) = NULL,
    @IsAdvancedField bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56301, 'ConfigChangeSetId does not exist.', 1;

    IF NULLIF(LTRIM(RTRIM(@EntityType)), N'') IS NULL
        THROW 56302, 'EntityType is required.', 1;

    IF NULLIF(LTRIM(RTRIM(@EntityKey)), N'') IS NULL
        THROW 56303, 'EntityKey is required.', 1;

    IF @Operation NOT IN (N'INSERT', N'UPDATE', N'DELETE')
        THROW 56304, 'Operation must be INSERT, UPDATE, or DELETE.', 1;

    IF NULLIF(LTRIM(RTRIM(@FieldName)), N'') IS NULL
        THROW 56305, 'FieldName is required.', 1;

    IF (@OldValue = @NewValue) OR (@OldValue IS NULL AND @NewValue IS NULL)
    BEGIN
        SELECT
            ConfigChangeItemId = CONVERT(bigint, NULL),
            ConfigChangeFieldId = CONVERT(bigint, NULL),
            Recorded = CONVERT(bit, 0),
            Message = N'Field was unchanged; no audit row recorded.';
        RETURN;
    END;

    DECLARE @ConfigChangeItemId bigint;

    SELECT TOP (1)
        @ConfigChangeItemId = ConfigChangeItemId
    FROM arch.ConfigChangeItem
    WHERE ConfigChangeSetId = @ConfigChangeSetId
      AND EntityType = @EntityType
      AND EntityKey = @EntityKey
      AND Operation = @Operation
      AND
      (
          ObjectId = @ObjectId
          OR (ObjectId IS NULL AND @ObjectId IS NULL)
      )
    ORDER BY ConfigChangeItemId;

    IF @ConfigChangeItemId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            @EntityType,
            @EntityKey,
            @Operation,
            @ObjectId,
            SYSUTCDATETIME()
        );

        SET @ConfigChangeItemId = CONVERT(bigint, SCOPE_IDENTITY());
    END;

    INSERT INTO arch.ConfigChangeField
    (
        ConfigChangeItemId,
        FieldName,
        OldValue,
        NewValue,
        IsAdvancedField
    )
    VALUES
    (
        @ConfigChangeItemId,
        @FieldName,
        @OldValue,
        @NewValue,
        COALESCE(@IsAdvancedField, CONVERT(bit, 0))
    );

    SELECT
        ConfigChangeItemId = @ConfigChangeItemId,
        ConfigChangeFieldId = CONVERT(bigint, SCOPE_IDENTITY()),
        Recorded = CONVERT(bit, 1),
        Message = N'Field change recorded.';
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_FinalizeConfigChangeSet]
    @ConfigChangeSetId bigint,
    @ChangeStatus nvarchar(20),
    @ValidationStatus nvarchar(20),
    @ValidationSummary nvarchar(4000) = NULL,
    @Actor nvarchar(256)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ChangeStatus NOT IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED', N'PUBLISHED', N'REJECTED', N'CANCELLED')
        THROW 56306, 'Invalid ChangeStatus.', 1;

    IF @ValidationStatus NOT IN (N'NOT_RUN', N'OK', N'WARN', N'ERROR')
        THROW 56307, 'Invalid ValidationStatus.', 1;

    IF NULLIF(LTRIM(RTRIM(@Actor)), N'') IS NULL
        THROW 56308, 'Actor is required.', 1;

    -- T-06: segregation of duties on the approval/publication transitions. Load the current state +
    -- requester so we can enforce four-eyes. (The web API does not call this proc — config Save*
    -- auto-publishes today — so this gate protects the explicit/approval-workflow path and any future
    -- mandatory-approval flow without affecting the current save path.)
    DECLARE @currentStatus nvarchar(20), @requestedBy nvarchar(256);
    SELECT @currentStatus = ChangeStatus, @requestedBy = RequestedBy
    FROM arch.ConfigChangeSet
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    IF @currentStatus IS NULL
        THROW 56309, 'ConfigChangeSetId does not exist.', 1;

    IF @ChangeStatus IN (N'APPROVED', N'PUBLISHED')
    BEGIN
        -- (a) no self-approval: approver/publisher must differ from the requester.
        IF LOWER(LTRIM(RTRIM(@Actor))) = LOWER(LTRIM(RTRIM(@requestedBy)))
            THROW 56310, 'Segregation of duties: the approver/publisher must differ from the requester (RequestedBy).', 1;
        -- (b) only members of karch_approver may approve/publish (sysadmin bypasses, as it does all checks).
        IF COALESCE(IS_MEMBER('karch_approver'), 0) = 0 AND IS_SRVROLEMEMBER('sysadmin') = 0
            THROW 56311, 'Only members of karch_approver may approve or publish a configuration change set.', 1;
    END;

    -- (c) enforce the state machine: no skipping straight to PUBLISHED.
    IF @ChangeStatus = N'PUBLISHED' AND @currentStatus <> N'APPROVED'
        THROW 56312, 'A change set must be APPROVED before it can be PUBLISHED.', 1;
    IF @ChangeStatus = N'APPROVED' AND @currentStatus NOT IN (N'PENDING_APPROVAL', N'APPROVED')
        THROW 56313, 'Only a PENDING_APPROVAL change set can be APPROVED.', 1;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = @ChangeStatus,
        ValidationStatus = @ValidationStatus,
        ValidationSummary = @ValidationSummary,
        PublishedBy = CASE WHEN @ChangeStatus = N'PUBLISHED' THEN @Actor ELSE PublishedBy END,
        PublishedAtUtc = CASE WHEN @ChangeStatus = N'PUBLISHED' THEN SYSUTCDATETIME() ELSE PublishedAtUtc END,
        ApprovedBy = CASE WHEN @ChangeStatus = N'APPROVED' THEN @Actor ELSE ApprovedBy END,
        ApprovedAtUtc = CASE WHEN @ChangeStatus = N'APPROVED' THEN SYSUTCDATETIME() ELSE ApprovedAtUtc END
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    IF @@ROWCOUNT = 0
        THROW 56309, 'ConfigChangeSetId does not exist.', 1;

    SELECT
        ConfigChangeSetId,
        ChangeStatus,
        RequestedBy,
        RequestedAtUtc,
        ApprovedBy,
        ApprovedAtUtc,
        PublishedBy,
        PublishedAtUtc,
        ChangeReason,
        ValidationStatus,
        ValidationSummary
    FROM arch.ConfigChangeSet
    WHERE ConfigChangeSetId = @ConfigChangeSetId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetConfigChangeHistory]
    @ConfigChangeSetId bigint = NULL,
    @DateFromUtc datetime2(0) = NULL,
    @DateToUtc datetime2(0) = NULL,
    @RequestedBy nvarchar(256) = NULL,
    @EntityType nvarchar(80) = NULL,
    @EntityKey nvarchar(400) = NULL,
    @ChangeStatus nvarchar(20) = NULL,
    @Top int = 500
AS
BEGIN
    SET NOCOUNT ON;

    IF @Top IS NULL OR @Top <= 0
        SET @Top = 500;

    SELECT TOP (@Top)
        cs.ConfigChangeSetId,
        cs.ChangeStatus,
        cs.RequestedBy,
        cs.RequestedAtUtc,
        cs.ApprovedBy,
        cs.ApprovedAtUtc,
        cs.PublishedBy,
        cs.PublishedAtUtc,
        cs.ChangeReason,
        cs.ValidationStatus,
        cs.ValidationSummary,
        ItemCount = COUNT(DISTINCT ci.ConfigChangeItemId),
        FieldCount = COUNT(cf.ConfigChangeFieldId),
        AdvancedFieldCount = SUM(CONVERT(int, CASE WHEN cf.IsAdvancedField = 1 THEN 1 ELSE 0 END))
    FROM arch.ConfigChangeSet cs
    LEFT JOIN arch.ConfigChangeItem ci
      ON ci.ConfigChangeSetId = cs.ConfigChangeSetId
    LEFT JOIN arch.ConfigChangeField cf
      ON cf.ConfigChangeItemId = ci.ConfigChangeItemId
    WHERE (@ConfigChangeSetId IS NULL OR cs.ConfigChangeSetId = @ConfigChangeSetId)
      AND (@DateFromUtc IS NULL OR cs.RequestedAtUtc >= @DateFromUtc)
      AND (@DateToUtc IS NULL OR cs.RequestedAtUtc < @DateToUtc)
      AND (@RequestedBy IS NULL OR cs.RequestedBy = @RequestedBy)
      AND (@EntityType IS NULL OR ci.EntityType = @EntityType)
      AND (@EntityKey IS NULL OR ci.EntityKey = @EntityKey)
      AND (@ChangeStatus IS NULL OR cs.ChangeStatus = @ChangeStatus)
    GROUP BY
        cs.ConfigChangeSetId,
        cs.ChangeStatus,
        cs.RequestedBy,
        cs.RequestedAtUtc,
        cs.ApprovedBy,
        cs.ApprovedAtUtc,
        cs.PublishedBy,
        cs.PublishedAtUtc,
        cs.ChangeReason,
        cs.ValidationStatus,
        cs.ValidationSummary
    ORDER BY
        cs.RequestedAtUtc DESC,
        cs.ConfigChangeSetId DESC;

    IF @ConfigChangeSetId IS NOT NULL
    BEGIN
        SELECT
            ci.ConfigChangeItemId,
            ci.ConfigChangeSetId,
            ci.EntityType,
            ci.EntityKey,
            ci.Operation,
            ci.ObjectId,
            ci.CreatedAtUtc,
            cf.ConfigChangeFieldId,
            cf.FieldName,
            cf.OldValue,
            cf.NewValue,
            cf.IsAdvancedField
        FROM arch.ConfigChangeItem ci
        LEFT JOIN arch.ConfigChangeField cf
          ON cf.ConfigChangeItemId = ci.ConfigChangeItemId
        WHERE ci.ConfigChangeSetId = @ConfigChangeSetId
        ORDER BY
            ci.ConfigChangeItemId,
            cf.ConfigChangeFieldId;
    END;
END
GO

-- <<< end: kArchiveManagerAdmin\frontend\004_frontend_audit.sql
GO
GO

-- ---- Phase 5: Run column extensions REQUIRED by the runner procs below ----
--   040 adds Run.CancelRequestedAtUtc + 'STOPPED' CK + usp_Api_RequestRunStop (its role grant is
--   guarded and re-applied in Phase 13 once roles exist); 044 adds Run.WorkerSessionId/LoginTime.
-- >>> inlined: kArchiveManagerAdmin\v2\040_run_cancel_support.sql
USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* ============================================================================
 * 040 — Cooperative run cancellation
 * ============================================================================
 * Lets an operator stop a long-running RUN gracefully from the Admin Console.
 * A stop request just stamps arch.Run.CancelRequestedAtUtc; the batch workers
 * (027 usp_RunTimestampProcess, 015 usp_RunPreparedBatch) check it at the top of
 * their batch loop and BREAK after finishing the in-flight batch (which is already
 * committed) — no rollback of completed work, no KILL privilege required. The run
 * ends with Status='STOPPED'. ANCHOR work batches are left 'Paused' so they can resume.
 *
 * Deploy order: this script, then re-deploy 015 and 027 (cancel-aware workers).
 * ============================================================================ */

IF COL_LENGTH('arch.Run', 'CancelRequestedAtUtc') IS NULL
BEGIN
    ALTER TABLE arch.Run ADD CancelRequestedAtUtc datetime2(0) NULL;
    PRINT 'arch.Run.CancelRequestedAtUtc added.';
END
ELSE
    PRINT 'arch.Run.CancelRequestedAtUtc already present.';
GO

-- T-10: persist WHO requested the stop and WHY. The Admin Console API already resolves the AUTHENTICATED
-- actor (never client-supplied) and passes it as @RequestedBy, but usp_Api_RequestRunStop previously only
-- returned it in the result and never stored it -> a stop of an irreversible delete run was unattributable
-- after the HTTP response. (Restore/purge attribution is already covered by arch.RestoreAudit, T-27.)
-- Columns are added in their own batches before the CREATE OR ALTER below so the proc compiles against them.
IF COL_LENGTH('arch.Run', 'CancelRequestedBy') IS NULL
BEGIN
    ALTER TABLE arch.Run ADD CancelRequestedBy nvarchar(256) NULL;
    PRINT 'arch.Run.CancelRequestedBy added.';
END
ELSE
    PRINT 'arch.Run.CancelRequestedBy already present.';
GO
IF COL_LENGTH('arch.Run', 'CancelReason') IS NULL
BEGIN
    ALTER TABLE arch.Run ADD CancelReason nvarchar(400) NULL;
    PRINT 'arch.Run.CancelReason added.';
END
ELSE
    PRINT 'arch.Run.CancelReason already present.';
GO

-- A cooperatively cancelled run ends with Status='STOPPED'; the existing CK constraints only
-- allow DRYRUN/FAILED/OK/RUNNING, so extend them. (Without this the worker's STOPPED update
-- fails the CHECK and the run is wrongly marked FAILED.)
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RunItem_Status' AND parent_object_id = OBJECT_ID(N'arch.RunItem'))
    ALTER TABLE arch.RunItem DROP CONSTRAINT CK_RunItem_Status;
ALTER TABLE arch.RunItem WITH CHECK ADD CONSTRAINT CK_RunItem_Status
    CHECK (Status IN (N'DRYRUN', N'FAILED', N'OK', N'RUNNING', N'STOPPED'));

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Run_Status' AND parent_object_id = OBJECT_ID(N'arch.Run'))
    ALTER TABLE arch.Run DROP CONSTRAINT CK_Run_Status;
ALTER TABLE arch.Run WITH CHECK ADD CONSTRAINT CK_Run_Status
    CHECK (Status IN (N'DRYRUN', N'FAILED', N'OK', N'RUNNING', N'STOPPED'));
PRINT 'CK_RunItem_Status / CK_Run_Status now allow STOPPED.';
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_RequestRunStop]
    @RunId       bigint,
    @RequestedBy nvarchar(256) = NULL,
    @Reason      nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
        THROW 50300, '@RunId is required.', 1;

    DECLARE @status nvarchar(20) = (SELECT Status FROM arch.Run WHERE RunId = @RunId);

    IF @status IS NULL
        THROW 50301, 'Run not found.', 1;

    -- Only an in-flight run can be stopped; terminal runs are reported back unchanged.
    -- T-10: persist the (authenticated) requester + reason alongside the timestamp, first-writer-wins
    -- (COALESCE) so a repeat stop request never overwrites the original attribution.
    UPDATE arch.Run
    SET CancelRequestedAtUtc = COALESCE(CancelRequestedAtUtc, SYSUTCDATETIME()),
        CancelRequestedBy    = COALESCE(CancelRequestedBy, @RequestedBy),
        CancelReason         = COALESCE(CancelReason, NULLIF(LTRIM(RTRIM(@Reason)), N''))
    WHERE RunId = @RunId
      AND Status = N'RUNNING';

    DECLARE @accepted bit = CASE WHEN @@ROWCOUNT > 0 THEN 1 ELSE 0 END;

    SELECT
        RunId                = @RunId,
        Accepted             = @accepted,
        CurrentStatus        = (SELECT Status FROM arch.Run WHERE RunId = @RunId),
        CancelRequestedAtUtc = (SELECT CancelRequestedAtUtc FROM arch.Run WHERE RunId = @RunId),
        CancelRequestedBy    = (SELECT CancelRequestedBy FROM arch.Run WHERE RunId = @RunId),
        CancelReason         = (SELECT CancelReason FROM arch.Run WHERE RunId = @RunId),
        RequestedBy          = @RequestedBy,
        Message              = CASE WHEN @accepted = 1
                                    THEN N'Stop requested; the run will end after the current batch.'
                                    ELSE N'Run is not running (already ' + (SELECT Status FROM arch.Run WHERE RunId = @RunId) + N'); nothing to stop.' END;
END
GO

-- T-02: the cooperative-stop endpoint must be executable by the production app-pool identity
-- (member of karch_operator). Without this grant the emergency Stop button fails permission-denied
-- (mapped to a generic 503) — the operator cannot stop a runaway delete run. Idempotent.
IF DATABASE_PRINCIPAL_ID(N'karch_operator') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Api_RequestRunStop] TO [karch_operator];
GO

PRINT '040_run_cancel_support deployed (column + arch.usp_Api_RequestRunStop + karch_operator grant).';
GO
-- <<< end: kArchiveManagerAdmin\v2\040_run_cancel_support.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\044_run_liveness_tracking.sql
/* ============================================================================
   044 — Run liveness tracking (audit task T-03)
   ============================================================================
   PROBLEM: the unattended "RECOVER STALE RUNS" job (usp_RecoverStaleRuns, every 15 min,
   @StaleAfterMinutes=30, @DryRun=0) decides a run is stale purely from wall-clock age
   (arch.Run.StartedAt, which is never refreshed). A LEGITIMATE run may execute up to
   RunProfile.RunWindowMinutes (JOB_DEFAULT = 55) — so any normal run past minute 30 is wrongly
   flagged stale and either marked FAILED mid-delete or (worse) inferred OK while still deleting.

   FIX (this script + 030/015/027 changes): record the worker's SPID + session login time on the
   run, so recovery can SKIP any run whose worker session is provably still alive. A run is only
   recoverable when its worker session is gone (or it predates this migration).

   Idempotent. Safe to run anytime (pure ADD COLUMN, NULLable, no data change).
   DEPLOY ORDER: run THIS first, then (re)deploy 030_usp_RecoverStaleRuns, 015_usp_RunPreparedBatch,
   027_usp_RunTimestampProcess. The runner re-deploys must happen when no run is active.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET NOCOUNT ON;
GO

IF COL_LENGTH('arch.Run', 'WorkerSessionId') IS NULL
    ALTER TABLE arch.Run ADD WorkerSessionId int NULL;
GO

IF COL_LENGTH('arch.Run', 'WorkerSessionLoginTimeUtc') IS NULL
    ALTER TABLE arch.Run ADD WorkerSessionLoginTimeUtc datetime2(3) NULL;
GO

PRINT '044_run_liveness_tracking deployed (arch.Run.WorkerSessionId + WorkerSessionLoginTimeUtc).';
GO
-- <<< end: kArchiveManagerAdmin\v2\044_run_liveness_tracking.sql
GO
GO

-- ---- Phase 6: indexes ----
-- >>> inlined: kArchiveManagerAdmin\indexes\Indexes.sql
USE kArchiveManagerAdmin;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.RunDocAudit')
      AND name = N'IX_RunDocAudit_DocKey_DeletedAt'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_RunDocAudit_DocKey_DeletedAt
    ON arch.RunDocAudit
    (
        DocKey,
        DeletedAt DESC,
        RunDocAuditId DESC
    )
    INCLUDE
    (
        RunItemId,
        ProcessCode,
        DocKeyLabel,
        DocCreatedAt,
        Archived
    );
END;
GO

USE kArchiveManagerAdmin;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.RunDocAudit')
      AND name = N'IX_RunDocAudit_RunItem_DocKey'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_RunDocAudit_RunItem_DocKey
    ON arch.RunDocAudit
    (
        RunItemId,
        DocKey
    )
    INCLUDE
    (
        ProcessCode,
        DocKeyLabel,
        DocCreatedAt,
        DeletedAt,
        Archived
    );
END;
GO


USE kArchiveManagerAdmin;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.RunItemObject')
      AND name = N'IX_RunItemObject_RunItem_SourceTable'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_RunItemObject_RunItem_SourceTable
    ON arch.RunItemObject
    (
        RunItemId,
        SourceTable
    )
    INCLUDE
    (
        RowsDeleted,
        RowsArchived
    );
END;
GO

USE kArchiveManagerAdmin;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.RunItem')
      AND name = N'IX_RunItem_Run_Status_Process'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_RunItem_Run_Status_Process
    ON arch.RunItem
    (
        RunId,
        Status,
        ProcessId,
        RunItemId
    )
    INCLUDE
    (
        Mode,
        CutoffUtc,
        StartedAt,
        EndedAt
    );
END;
GO

USE kArchiveManagerAdmin;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.Run')
      AND name = N'IX_Run_Report_OK_SourceArchive'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_Run_Report_OK_SourceArchive
    ON arch.Run
    (
        SourceDb,
        ArchiveDb,
        RunId
    )
    INCLUDE
    (
        StartedAt,
        EndedAt,
        Status
    )
    WHERE Status = N'OK';
END;
GO

USE kArchiveManagerAdmin;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.Process')
      AND name = N'UX_Process_ProcessCode'
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UX_Process_ProcessCode
    ON arch.Process
    (
        ProcessCode
    )
    INCLUDE
    (
        ProcessId,
        IsEnabled,
        Mode,
        RetentionDays,
        CutoffSafetyLagMinutes,
        BatchDocCount,
        BatchRowCount,
        MaxBatchesPerRun,
        DelayMsBetweenBatches,
        LockTimeoutMs
    );
END;
GO

USE kArchiveManagerAdmin;
GO

IF OBJECT_ID(N'arch.WorkBatchKey') IS NOT NULL
AND NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.WorkBatchKey')
      AND name = N'IX_WorkBatchKey_WorkBatchId'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_WorkBatchKey_WorkBatchId
    ON arch.WorkBatchKey
    (
        WorkBatchId
    )
    INCLUDE
    (
        Key1,
        Key2,
        Status,
        DocCreatedAt,
        AnchorRowGuid
    );
END;
GO

USE kArchiveManagerAdmin;
GO

IF OBJECT_ID(N'arch.WorkBatch') IS NOT NULL
AND NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'arch.WorkBatch')
      AND name = N'IX_WorkBatch_Status_WorkBatchId'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_WorkBatch_Status_WorkBatchId
    ON arch.WorkBatch
    (
        Status,
        WorkBatchId DESC
    )
    INCLUDE
    (
        ProcessId,
        SourceDb,
        ArchiveDb,
        RangeFromUtc,
        RangeToUtc,
        ModeSnapshot,
        PreparedAtUtc,
        LastProgressAtUtc
    );
END;
GO

USE kArchiveManagerAdmin;
GO

DECLARE @SourceDb sysname = N'KMWEBV';

IF DB_ID(@SourceDb) IS NOT NULL
BEGIN
    DECLARE @sql nvarchar(max) = N'
USE ' + QUOTENAME(@SourceDb) + N';

IF OBJECT_ID(N''dbo.SHIPHIST'', N''U'') IS NOT NULL
AND NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N''dbo.SHIPHIST'')
      AND name = N''IX_SHIPHIST_AM_DATE_UPLD''
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_SHIPHIST_AM_DATE_UPLD
    ON dbo.SHIPHIST (DATE_UPLD);
END;

IF OBJECT_ID(N''dbo.SHIPHIST'', N''U'') IS NOT NULL
AND NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N''dbo.SHIPHIST'')
      AND name = N''IX_SHIPHIST_AM_DATE_UPLD_PACKSLIP''
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_SHIPHIST_AM_DATE_UPLD_PACKSLIP
    ON dbo.SHIPHIST (DATE_UPLD, PACKSLIP);
END;';

    EXEC sys.sp_executesql @sql;
END
ELSE
BEGIN
    RAISERROR(N'Source database KMWEBV was not found; optional SHIPHIST source index was skipped.', 10, 1);
END;
GO
-- <<< end: kArchiveManagerAdmin\indexes\Indexes.sql
GO
GO

-- ---- Phase 7: views (effective config, monitoring, operational health) ----
-- >>> inlined: kArchiveManagerAdmin\v2\022_effective_database_overrides.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID(N'arch.ProcessDatabase', N'U') IS NULL
BEGIN
    RAISERROR(N'arch.ProcessDatabase does not exist. Run v2 core scripts first.', 16, 1);
    RETURN;
END
GO

IF COL_LENGTH(N'arch.ProcessDatabase', N'Mode') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [Mode] [tinyint] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'RetentionDays') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [RetentionDays] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'CutoffSafetyLagMinutes') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [CutoffSafetyLagMinutes] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'CutoffMode') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [CutoffMode] [tinyint] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'CutoffDate') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [CutoffDate] [datetime2](0) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'BatchDocCount') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [BatchDocCount] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'BatchRowCount') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [BatchRowCount] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'MaxBatchesPerRun') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [MaxBatchesPerRun] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'DelayMsBetweenBatches') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [DelayMsBetweenBatches] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'UseAppLock') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [UseAppLock] [bit] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AppLockResource') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AppLockResource] [nvarchar](200) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'LockTimeoutMs') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [LockTimeoutMs] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'DeadlockPriority') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [DeadlockPriority] [nvarchar](10) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorSchema') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorSchema] [sysname] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorTable') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorTable] [sysname] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorDocKeyExpr') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorDocKeyExpr] [nvarchar](4000) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorDocKey2Expr') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorDocKey2Expr] [nvarchar](4000) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorTimestampExpr') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorTimestampExpr] [nvarchar](4000) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AnchorExtraWhereSql') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AnchorExtraWhereSql] [nvarchar](4000) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AllowDeleteWithoutArchive') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AllowDeleteWithoutArchive] [bit] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'DocKeyLabel') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [DocKeyLabel] [nvarchar](50) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'AuditLevel') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [AuditLevel] [nvarchar](20) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'RequireSupportingIndex') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [RequireSupportingIndex] [bit] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'MaxRowsPerTransaction') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [MaxRowsPerTransaction] [int] NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'CandidateWhereSql') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [CandidateWhereSql] [nvarchar](4000) NULL;
GO
IF COL_LENGTH(N'arch.ProcessDatabase', N'CandidateOrderSql') IS NULL
    ALTER TABLE arch.ProcessDatabase ADD [CandidateOrderSql] [nvarchar](4000) NULL;
GO

IF OBJECT_ID(N'arch.ObjectSpecDatabaseOverride', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[ObjectSpecDatabaseOverride](
        [ObjectSpecDatabaseOverrideId] [int] IDENTITY(1,1) NOT NULL,
        [ProcessDatabaseId] [int] NOT NULL,
        [ObjectSpecId] [int] NOT NULL,
        [IsEnabled] [bit] NOT NULL,
        [SourceSchemaOverride] [sysname] NULL,
        [SourceTableOverride] [sysname] NULL,
        [TimestampExprOverride] [nvarchar](4000) NULL,
        [JoinToAnchorPredicateSqlOverride] [nvarchar](4000) NULL,
        [AdditionalWhereSqlOverride] [nvarchar](4000) NULL,
        [ArchiveSchemaOverride] [sysname] NULL,
        [ArchiveTableOverride] [sysname] NULL,
        [RequireArchiveForDeleteOverride] [bit] NULL,
        [CreatedAt] [datetime2](0) NOT NULL,
        [ModifiedAt] [datetime2](0) NOT NULL,
        CONSTRAINT [PK_ObjectSpecDatabaseOverride] PRIMARY KEY CLUSTERED ([ObjectSpecDatabaseOverrideId] ASC),
        CONSTRAINT [UQ_ObjectSpecDatabaseOverride] UNIQUE NONCLUSTERED ([ProcessDatabaseId] ASC, [ObjectSpecId] ASC),
        CONSTRAINT [FK_ObjectSpecDatabaseOverride_ProcessDatabase] FOREIGN KEY([ProcessDatabaseId]) REFERENCES [arch].[ProcessDatabase] ([ProcessDatabaseId]),
        CONSTRAINT [FK_ObjectSpecDatabaseOverride_ObjectSpec] FOREIGN KEY([ObjectSpecId]) REFERENCES [arch].[ObjectSpec] ([ObjectSpecId])
    );

    ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_IsEnabled] DEFAULT ((1)) FOR [IsEnabled];
    ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_CreatedAt] DEFAULT (sysutcdatetime()) FOR [CreatedAt];
    ALTER TABLE [arch].[ObjectSpecDatabaseOverride] ADD CONSTRAINT [DF_ObjectSpecDatabaseOverride_ModifiedAt] DEFAULT (sysutcdatetime()) FOR [ModifiedAt];
END
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'arch.ProcessDatabase')
      AND name = N'CK_ProcessDatabase_OverrideLimits'
)
BEGIN
    ALTER TABLE [arch].[ProcessDatabase] WITH CHECK ADD CONSTRAINT [CK_ProcessDatabase_OverrideLimits] CHECK
    (
        ([Mode] IS NULL OR [Mode] IN (0, 1, 2))   -- 0 delete-only, 1 archive+delete, 2 copy-only
        AND ([RetentionDays] IS NULL OR [RetentionDays] >= 0)
        AND ([CutoffSafetyLagMinutes] IS NULL OR [CutoffSafetyLagMinutes] >= 0)
        AND ([CutoffMode] IS NULL OR [CutoffMode] IN (0, 1))
        AND ([BatchDocCount] IS NULL OR [BatchDocCount] > 0)
        AND ([BatchRowCount] IS NULL OR [BatchRowCount] > 0)
        AND ([MaxBatchesPerRun] IS NULL OR [MaxBatchesPerRun] > 0)
        AND ([DelayMsBetweenBatches] IS NULL OR [DelayMsBetweenBatches] >= 0)
        AND ([LockTimeoutMs] IS NULL OR [LockTimeoutMs] >= 0)
        AND ([DeadlockPriority] IS NULL OR [DeadlockPriority] IN (N'LOW', N'NORMAL', N'HIGH'))
        AND ([AuditLevel] IS NULL OR [AuditLevel] IN (N'NONE', N'BATCH', N'OBJECT', N'ROW'))
        AND ([MaxRowsPerTransaction] IS NULL OR [MaxRowsPerTransaction] > 0)
    );
    ALTER TABLE [arch].[ProcessDatabase] CHECK CONSTRAINT [CK_ProcessDatabase_OverrideLimits];
END
GO

CREATE OR ALTER VIEW [arch].[v_ProcessDatabaseEffective]
AS
SELECT
    pd.ProcessDatabaseId,
    p.ProcessId,
    p.ProcessCode,
    p.Description,
    SourceDb = pd.SourceDb,
    ArchiveDb = pd.ArchiveDb,
    ProcessIsEnabled = p.IsEnabled,
    MappingIsEnabled = pd.IsEnabled,
    IsEnabled = CONVERT(bit, CASE WHEN p.IsEnabled = 1 AND pd.IsEnabled = 1 THEN 1 ELSE 0 END),
    pd.RunOrder,
    Mode = COALESCE(pd.Mode, p.Mode),
    ModeSource = CONVERT(varchar(20), CASE WHEN pd.Mode IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    RetentionDays = COALESCE(pd.RetentionDays, p.RetentionDays),
    RetentionDaysSource = CONVERT(varchar(20), CASE WHEN pd.RetentionDays IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    CutoffSafetyLagMinutes = COALESCE(pd.CutoffSafetyLagMinutes, p.CutoffSafetyLagMinutes),
    CutoffSafetyLagMinutesSource = CONVERT(varchar(20), CASE WHEN pd.CutoffSafetyLagMinutes IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    CutoffMode = COALESCE(pd.CutoffMode, p.CutoffMode),
    CutoffModeSource = CONVERT(varchar(20), CASE WHEN pd.CutoffMode IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    CutoffDate = COALESCE(pd.CutoffDate, p.CutoffDate),
    CutoffDateSource = CONVERT(varchar(20), CASE WHEN pd.CutoffDate IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    BatchDocCount = COALESCE(pd.BatchDocCount, p.BatchDocCount),
    BatchDocCountSource = CONVERT(varchar(20), CASE WHEN pd.BatchDocCount IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    BatchRowCount = COALESCE(pd.BatchRowCount, p.BatchRowCount),
    BatchRowCountSource = CONVERT(varchar(20), CASE WHEN pd.BatchRowCount IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    MaxBatchesPerRun = COALESCE(pd.MaxBatchesPerRun, p.MaxBatchesPerRun),
    MaxBatchesPerRunSource = CONVERT(varchar(20), CASE WHEN pd.MaxBatchesPerRun IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    DelayMsBetweenBatches = COALESCE(pd.DelayMsBetweenBatches, p.DelayMsBetweenBatches),
    DelayMsBetweenBatchesSource = CONVERT(varchar(20), CASE WHEN pd.DelayMsBetweenBatches IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    UseAppLock = COALESCE(pd.UseAppLock, p.UseAppLock),
    UseAppLockSource = CONVERT(varchar(20), CASE WHEN pd.UseAppLock IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AppLockResource = COALESCE(NULLIF(LTRIM(RTRIM(pd.AppLockResource)), N''), NULLIF(LTRIM(RTRIM(p.AppLockResource)), N'')),
    AppLockResourceSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AppLockResource)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    LockTimeoutMs = COALESCE(pd.LockTimeoutMs, p.LockTimeoutMs),
    LockTimeoutMsSource = CONVERT(varchar(20), CASE WHEN pd.LockTimeoutMs IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    DeadlockPriority = COALESCE(NULLIF(LTRIM(RTRIM(pd.DeadlockPriority)), N''), p.DeadlockPriority),
    DeadlockPrioritySource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.DeadlockPriority)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorSchema = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorSchema)), N''), p.AnchorSchema),
    AnchorSchemaSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorSchema)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorTable = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorTable)), N''), p.AnchorTable),
    AnchorTableSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorTable)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorDocKeyExpr = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorDocKeyExpr)), N''), p.AnchorDocKeyExpr),
    AnchorDocKeyExprSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorDocKeyExpr)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorDocKey2Expr = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorDocKey2Expr)), N''), p.AnchorDocKey2Expr),
    AnchorDocKey2ExprSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorDocKey2Expr)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorTimestampExpr = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorTimestampExpr)), N''), p.AnchorTimestampExpr),
    AnchorTimestampExprSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorTimestampExpr)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AnchorExtraWhereSql = COALESCE(NULLIF(LTRIM(RTRIM(pd.AnchorExtraWhereSql)), N''), p.AnchorExtraWhereSql),
    AnchorExtraWhereSqlSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorExtraWhereSql)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    AllowDeleteWithoutArchive = COALESCE(pd.AllowDeleteWithoutArchive, p.AllowDeleteWithoutArchive),
    AllowDeleteWithoutArchiveSource = CONVERT(varchar(20), CASE WHEN pd.AllowDeleteWithoutArchive IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    DocKeyLabel = COALESCE(NULLIF(LTRIM(RTRIM(pd.DocKeyLabel)), N''), p.DocKeyLabel),
    DocKeyLabelSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.DocKeyLabel)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    SelectionStrategy = COALESCE(p.SelectionStrategy, N'ANCHOR'),
    AuditLevel = COALESCE(NULLIF(LTRIM(RTRIM(pd.AuditLevel)), N''), p.AuditLevel),
    AuditLevelSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.AuditLevel)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    RequireSupportingIndex = COALESCE(pd.RequireSupportingIndex, p.RequireSupportingIndex),
    RequireSupportingIndexSource = CONVERT(varchar(20), CASE WHEN pd.RequireSupportingIndex IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    MaxRowsPerTransaction = COALESCE(pd.MaxRowsPerTransaction, p.MaxRowsPerTransaction),
    MaxRowsPerTransactionSource = CONVERT(varchar(20), CASE WHEN pd.MaxRowsPerTransaction IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    CandidateWhereSql = COALESCE(NULLIF(LTRIM(RTRIM(pd.CandidateWhereSql)), N''), p.CandidateWhereSql),
    CandidateWhereSqlSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.CandidateWhereSql)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    CandidateOrderSql = COALESCE(NULLIF(LTRIM(RTRIM(pd.CandidateOrderSql)), N''), p.CandidateOrderSql),
    CandidateOrderSqlSource = CONVERT(varchar(20), CASE WHEN NULLIF(LTRIM(RTRIM(pd.CandidateOrderSql)), N'') IS NULL THEN 'Process' ELSE 'ProcessDatabase' END),
    ProcessCreatedAt = p.CreatedAt,
    ProcessModifiedAt = p.ModifiedAt,
    MappingCreatedAt = pd.CreatedAt,
    MappingModifiedAt = pd.ModifiedAt
FROM arch.ProcessDatabase AS pd
JOIN arch.Process AS p
  ON p.ProcessId = pd.ProcessId;
GO

-- Perf (high-volume TIMESTAMP, 100M-row sources): optional CHEAP candidate-selection expression. When set,
-- the TIMESTAMP runner (027) selects candidates using THIS expression (e.g. a plain local datetime CONVERT,
-- NO per-row AT TIME ZONE) for the projected timestamp, and takes the cutoff sargably from CandidateWhereSql,
-- so the candidate scan is an index-ordered read with no per-row timezone conversion. TimestampExpr stays the
-- exact AT TIME ZONE expression so the timezone gate (50200) still passes; the retention floor (50210) still
-- guards @CutoffUtc. NULL = classic behavior (TimestampExpr used for both filter and projection).
IF COL_LENGTH(N'arch.ObjectSpec', N'CandidateSelectExpr') IS NULL
    ALTER TABLE arch.ObjectSpec ADD [CandidateSelectExpr] [nvarchar](4000) NULL;
GO

-- Optimistic-concurrency metadata for ObjectSpec edits (console 4-eyes / conflict detection).
-- These columns + the ModifiedAt trigger live HERE so v_ObjectSpecDatabaseEffective below can
-- project them: this view is the SINGLE source of truth. deploy/v2/33 installs only the matching
-- usp_Api_CheckConfigConcurrency proc and MUST NOT re-create this view (doing so once dropped the
-- cheap-mode column and broke the TIMESTAMP runner — keep the view defined here only).
IF COL_LENGTH(N'arch.ObjectSpec', N'CreatedAt') IS NULL
    ALTER TABLE [arch].[ObjectSpec] ADD [CreatedAt] datetime2(0) NOT NULL
        CONSTRAINT [DF_ObjectSpec_CreatedAt] DEFAULT (sysutcdatetime()) WITH VALUES;
GO
IF COL_LENGTH(N'arch.ObjectSpec', N'ModifiedAt') IS NULL
    ALTER TABLE [arch].[ObjectSpec] ADD [ModifiedAt] datetime2(0) NOT NULL
        CONSTRAINT [DF_ObjectSpec_ModifiedAt] DEFAULT (sysutcdatetime()) WITH VALUES;
GO

CREATE OR ALTER TRIGGER [arch].[tr_ObjectSpec_SetModifiedAt]
ON [arch].[ObjectSpec]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF TRIGGER_NESTLEVEL() > 1
        RETURN;
    UPDATE os
    SET ModifiedAt = CONVERT(datetime2(0), sysutcdatetime())
    FROM [arch].[ObjectSpec] AS os
    JOIN inserted AS i
      ON i.ObjectSpecId = os.ObjectSpecId;
END
GO

CREATE OR ALTER VIEW [arch].[v_ObjectSpecDatabaseEffective]
AS
SELECT
    e.ProcessDatabaseId,
    e.ProcessId,
    e.ProcessCode,
    e.SourceDb,
    e.ArchiveDb,
    e.IsEnabled AS ProcessDatabaseIsEnabled,
    os.ObjectSpecId,
    ObjectSpecOverrideId = osdo.ObjectSpecDatabaseOverrideId,
    ObjectIsEnabled = CONVERT(bit, CASE WHEN osdo.ObjectSpecDatabaseOverrideId IS NULL OR osdo.IsEnabled = 1 THEN 1 ELSE 0 END),
    SourceSchema = COALESCE(NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N''), os.SourceSchema),
    SourceSchemaSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    SourceTable = COALESCE(NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N''), os.SourceTable),
    SourceTableSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    os.DeleteOrder,
    os.DeleteMode,
    TimestampExpr = COALESCE(NULLIF(LTRIM(RTRIM(osdo.TimestampExprOverride)), N''), os.TimestampExpr),
    TimestampExprSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.TimestampExprOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    JoinToAnchorPredicateSql = COALESCE(NULLIF(LTRIM(RTRIM(osdo.JoinToAnchorPredicateSqlOverride)), N''), os.JoinToAnchorPredicateSql),
    JoinToAnchorPredicateSqlSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.JoinToAnchorPredicateSqlOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    AdditionalWhereSql = COALESCE(NULLIF(LTRIM(RTRIM(osdo.AdditionalWhereSqlOverride)), N''), os.AdditionalWhereSql),
    AdditionalWhereSqlSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.AdditionalWhereSqlOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    ArchiveSchema = COALESCE(NULLIF(LTRIM(RTRIM(osdo.ArchiveSchemaOverride)), N''), os.ArchiveSchema),
    ArchiveSchemaSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.ArchiveSchemaOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    ArchiveTable = COALESCE(NULLIF(LTRIM(RTRIM(osdo.ArchiveTableOverride)), N''), os.ArchiveTable),
    ArchiveTableSource = CONVERT(varchar(30), CASE WHEN NULLIF(LTRIM(RTRIM(osdo.ArchiveTableOverride)), N'') IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    RequireArchiveForDelete = COALESCE(osdo.RequireArchiveForDeleteOverride, os.RequireArchiveForDelete),
    RequireArchiveForDeleteSource = CONVERT(varchar(30), CASE WHEN osdo.RequireArchiveForDeleteOverride IS NULL THEN 'ObjectSpec' ELSE 'ObjectSpecDatabaseOverride' END),
    os.NaturalKeyLabel,
    os.CandidateSelectExpr,
    ObjectSpecCreatedAt = os.CreatedAt,
    ObjectSpecModifiedAt = os.ModifiedAt,
    ObjectSpecOverrideCreatedAt = osdo.CreatedAt,
    ObjectSpecOverrideModifiedAt = osdo.ModifiedAt
FROM arch.v_ProcessDatabaseEffective AS e
JOIN arch.ObjectSpec AS os
  ON os.ProcessId = e.ProcessId
LEFT JOIN arch.ObjectSpecDatabaseOverride AS osdo
  ON osdo.ProcessDatabaseId = e.ProcessDatabaseId
 AND osdo.ObjectSpecId = os.ObjectSpecId;
GO
-- <<< end: kArchiveManagerAdmin\v2\022_effective_database_overrides.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\023_monitoring_views.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER VIEW [arch].[v_LastRunPerProcess]
AS
WITH x AS
(
    SELECT
        p.ProcessCode,
        p.Description,
        r.SourceDb,
        r.ArchiveDb,
        ri.RunItemId,
        r.RunId,
        ri.StartedAt,
        ri.EndedAt,
        ri.Status,
        ri.RowsDeleted,
        ri.RowsArchived,
        ri.DocsDone,
        ROW_NUMBER() OVER
        (
            PARTITION BY p.ProcessCode, r.SourceDb, r.ArchiveDb
            ORDER BY ri.StartedAt DESC, ri.RunItemId DESC
        ) AS rn
    FROM arch.Process p
    JOIN arch.RunItem ri
      ON ri.ProcessId = p.ProcessId
    JOIN arch.Run r
      ON r.RunId = ri.RunId
)
SELECT
    ProcessCode,
    Description,
    SourceDb,
    ArchiveDb,
    RunId,
    RunItemId,
    StartedAt,
    EndedAt,
    Status,
    DocsDone,
    RowsDeleted,
    RowsArchived
FROM x
WHERE rn = 1;
GO

CREATE OR ALTER VIEW [arch].[v_RunItemsRecent]
AS
SELECT TOP (5000)
    r.RunId,
    p.ProcessCode,
    r.SourceDb,
    r.ArchiveDb,
    ri.RunItemId,
    ri.AsOfUtc,
    ri.CutoffUtc,
    ri.Mode,
    ri.Status,
    ri.StartedAt,
    ri.EndedAt,
    ri.BatchesDone,
    ri.DocsDone,
    ri.RowsDeleted,
    ri.RowsArchived,
    ri.ErrorMessage
FROM arch.RunItem ri
JOIN arch.Run r
  ON r.RunId = ri.RunId
JOIN arch.Process p
  ON p.ProcessId = ri.ProcessId
ORDER BY ri.StartedAt DESC, ri.RunItemId DESC;
GO

CREATE OR ALTER VIEW [arch].[v_RunDocAuditDetailed]
AS
SELECT
    a.RunDocAuditId,
    a.RunItemId,
    ri.RunId,
    ri.ProcessId,
    ProcessCode = a.ProcessCode,
    ConfigProcessCode = p.ProcessCode,
    r.SourceDb,
    r.ArchiveDb,
    a.DocKeyLabel,
    a.DocKey,
    a.DocCreatedAt,
    a.DeletedAt,
    a.Archived,
    ri.AsOfUtc,
    ri.CutoffUtc,
    ri.Mode,
    RunStatus = r.Status,
    RunStartedAt = r.StartedAt,
    RunEndedAt = r.EndedAt,
    RunItemStatus = ri.Status,
    RunItemStartedAt = ri.StartedAt,
    RunItemEndedAt = ri.EndedAt,
    ri.BatchesDone,
    ri.DocsDone,
    ri.RowsDeleted,
    ri.RowsArchived,
    r.HostName,
    r.AppName,
    r.InitiatedBy,
    RunErrorMessage = r.ErrorMessage,
    RunItemErrorMessage = ri.ErrorMessage
FROM arch.RunDocAudit a
JOIN arch.RunItem ri
  ON ri.RunItemId = a.RunItemId
JOIN arch.Run r
  ON r.RunId = ri.RunId
JOIN arch.Process p
  ON p.ProcessId = ri.ProcessId;
GO
-- <<< end: kArchiveManagerAdmin\v2\023_monitoring_views.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\024_operational_maintenance.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_MarkStaleRunsFailed]
    @StaleMinutes int = 60,
    @ApplyChanges bit = 0,
    @OnlySourceDb sysname = NULL,
    @OnlyArchiveDb sysname = NULL,
    @OnlyProcessCode sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @StaleMinutes IS NULL OR @StaleMinutes < 1
        THROW 59000, '@StaleMinutes must be >= 1.', 1;

    DECLARE
        @NowUtc datetime2(0) = CONVERT(datetime2(0), SYSUTCDATETIME()),
        @StaleBeforeUtc datetime2(0);

    SET @StaleBeforeUtc = DATEADD(MINUTE, -@StaleMinutes, @NowUtc);

    CREATE TABLE #StaleRunItems
    (
        RunId bigint NOT NULL,
        RunItemId bigint NOT NULL PRIMARY KEY,
        ProcessCode sysname NOT NULL,
        SourceDb sysname NULL,
        ArchiveDb sysname NULL,
        StartedAt datetime2(0) NOT NULL,
        EndedAt datetime2(0) NULL,
        DocsDone int NOT NULL,
        RowsDeleted bigint NOT NULL,
        RowsArchived bigint NOT NULL,
        ErrorMessage nvarchar(max) NULL
    );

    INSERT INTO #StaleRunItems
    (
        RunId,
        RunItemId,
        ProcessCode,
        SourceDb,
        ArchiveDb,
        StartedAt,
        EndedAt,
        DocsDone,
        RowsDeleted,
        RowsArchived,
        ErrorMessage
    )
    SELECT
        r.RunId,
        ri.RunItemId,
        p.ProcessCode,
        r.SourceDb,
        r.ArchiveDb,
        ri.StartedAt,
        ri.EndedAt,
        ri.DocsDone,
        ri.RowsDeleted,
        ri.RowsArchived,
        ri.ErrorMessage
    FROM arch.RunItem ri
    JOIN arch.Run r
      ON r.RunId = ri.RunId
    JOIN arch.Process p
      ON p.ProcessId = ri.ProcessId
    WHERE ri.Status = N'RUNNING'
      AND ri.StartedAt < @StaleBeforeUtc
      AND (@OnlySourceDb IS NULL OR r.SourceDb = @OnlySourceDb)
      AND (@OnlyArchiveDb IS NULL OR r.ArchiveDb = @OnlyArchiveDb)
      AND (@OnlyProcessCode IS NULL OR p.ProcessCode = @OnlyProcessCode);

    SELECT
        Step = N'01_STALE_RUNITEM_CANDIDATES',
        ApplyChanges = @ApplyChanges,
        NowUtc = @NowUtc,
        StaleBeforeUtc = @StaleBeforeUtc,
        *
    FROM #StaleRunItems
    ORDER BY StartedAt, RunItemId;

    IF @ApplyChanges = 1
    BEGIN
        UPDATE ri
        SET Status = N'FAILED',
            EndedAt = @NowUtc,
            ErrorMessage = CONCAT(
                COALESCE(CONVERT(nvarchar(max), ri.ErrorMessage), N''),
                CASE WHEN ri.ErrorMessage IS NULL THEN N'' ELSE N' | ' END,
                N'Marked FAILED by arch.usp_MarkStaleRunsFailed at ',
                CONVERT(nvarchar(30), @NowUtc, 126),
                N' UTC after ',
                CONVERT(nvarchar(20), @StaleMinutes),
                N' stale minutes.'
            )
        FROM arch.RunItem ri
        JOIN #StaleRunItems s
          ON s.RunItemId = ri.RunItemId
        WHERE ri.Status = N'RUNNING';

        UPDATE r
        SET Status = N'FAILED',
            EndedAt = @NowUtc,
            ErrorMessage = CONCAT(
                COALESCE(CONVERT(nvarchar(max), r.ErrorMessage), N''),
                CASE WHEN r.ErrorMessage IS NULL THEN N'' ELSE N' | ' END,
                N'Marked FAILED by arch.usp_MarkStaleRunsFailed at ',
                CONVERT(nvarchar(30), @NowUtc, 126),
                N' UTC after stale RunItem recovery.'
            )
        FROM arch.Run r
        WHERE r.Status = N'RUNNING'
          AND r.StartedAt < @StaleBeforeUtc
          AND (@OnlySourceDb IS NULL OR r.SourceDb = @OnlySourceDb)
          AND (@OnlyArchiveDb IS NULL OR r.ArchiveDb = @OnlyArchiveDb)
          AND EXISTS
          (
              SELECT 1
              FROM #StaleRunItems s
              WHERE s.RunId = r.RunId
          )
          AND NOT EXISTS
          (
              SELECT 1
              FROM arch.RunItem ri
              WHERE ri.RunId = r.RunId
                AND ri.Status = N'RUNNING'
          );
    END;

    SELECT
        Step = N'99_SUMMARY',
        ApplyChanges = @ApplyChanges,
        StaleRunItemsFound = COUNT_BIG(*),
        Message =
            CASE
                WHEN @ApplyChanges = 1 THEN N'Stale RUNNING RunItems were marked FAILED.'
                ELSE N'Preview only. Re-run with @ApplyChanges = 1 to mark these RunItems FAILED.'
            END
    FROM #StaleRunItems;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_CloseDryRunWorkBatches]
    @StaleMinutes int = 0,
    @ApplyChanges bit = 0,
    @OnlySourceDb sysname = NULL,
    @OnlyArchiveDb sysname = NULL,
    @OnlyProcessCode sysname = NULL,
    @IncludeRunning bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @StaleMinutes IS NULL OR @StaleMinutes < 0
        THROW 59010, '@StaleMinutes must be >= 0.', 1;

    DECLARE
        @NowUtc datetime2(0) = CONVERT(datetime2(0), SYSUTCDATETIME()),
        @StaleBeforeUtc datetime2(0);

    SET @StaleBeforeUtc = DATEADD(MINUTE, -@StaleMinutes, @NowUtc);

    CREATE TABLE #DryRunWorkBatches
    (
        WorkBatchId bigint NOT NULL PRIMARY KEY,
        ProcessCode sysname NOT NULL,
        SourceDb sysname NOT NULL,
        ArchiveDb sysname NOT NULL,
        Status varchar(20) NOT NULL,
        PreparedAtUtc datetime2(0) NULL,
        StartedAtUtc datetime2(0) NULL,
        LastProgressAtUtc datetime2(0) NULL,
        CompletedAtUtc datetime2(0) NULL,
        Notes nvarchar(4000) NULL
    );

    INSERT INTO #DryRunWorkBatches
    (
        WorkBatchId,
        ProcessCode,
        SourceDb,
        ArchiveDb,
        Status,
        PreparedAtUtc,
        StartedAtUtc,
        LastProgressAtUtc,
        CompletedAtUtc,
        Notes
    )
    SELECT
        wb.WorkBatchId,
        p.ProcessCode,
        wb.SourceDb,
        wb.ArchiveDb,
        wb.Status,
        wb.PreparedAtUtc,
        wb.StartedAtUtc,
        wb.LastProgressAtUtc,
        wb.CompletedAtUtc,
        wb.Notes
    FROM arch.WorkBatch wb
    JOIN arch.Process p
      ON p.ProcessId = wb.ProcessId
    WHERE wb.Status IN ('Prepared', 'Paused')
      AND wb.Notes = N'DryRun preview only'
      AND COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc) <= @StaleBeforeUtc
      AND (@OnlySourceDb IS NULL OR wb.SourceDb = @OnlySourceDb)
      AND (@OnlyArchiveDb IS NULL OR wb.ArchiveDb = @OnlyArchiveDb)
      AND (@OnlyProcessCode IS NULL OR p.ProcessCode = @OnlyProcessCode)
    UNION ALL
    SELECT
        wb.WorkBatchId,
        p.ProcessCode,
        wb.SourceDb,
        wb.ArchiveDb,
        wb.Status,
        wb.PreparedAtUtc,
        wb.StartedAtUtc,
        wb.LastProgressAtUtc,
        wb.CompletedAtUtc,
        wb.Notes
    FROM arch.WorkBatch wb
    JOIN arch.Process p
      ON p.ProcessId = wb.ProcessId
    WHERE @IncludeRunning = 1
      AND wb.Status = 'Running'
      AND wb.Notes = N'DryRun preview only'
      AND COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc) <= @StaleBeforeUtc
      AND (@OnlySourceDb IS NULL OR wb.SourceDb = @OnlySourceDb)
      AND (@OnlyArchiveDb IS NULL OR wb.ArchiveDb = @OnlyArchiveDb)
      AND (@OnlyProcessCode IS NULL OR p.ProcessCode = @OnlyProcessCode);

    SELECT
        Step = N'01_DRYRUN_WORKBATCH_CANDIDATES',
        ApplyChanges = @ApplyChanges,
        NowUtc = @NowUtc,
        StaleBeforeUtc = @StaleBeforeUtc,
        *
    FROM #DryRunWorkBatches
    ORDER BY PreparedAtUtc, WorkBatchId;

    IF @ApplyChanges = 1
    BEGIN
        UPDATE wb
        SET Status = 'Failed',
            CompletedAtUtc = @NowUtc,
            LastProgressAtUtc = @NowUtc,
            Notes = CONCAT(
                COALESCE(CONVERT(nvarchar(max), wb.Notes), N''),
                N' | Closed by arch.usp_CloseDryRunWorkBatches at ',
                CONVERT(nvarchar(30), @NowUtc, 126),
                N' UTC. No source data was changed by dry-run preview.'
            )
        FROM arch.WorkBatch wb
        JOIN #DryRunWorkBatches d
          ON d.WorkBatchId = wb.WorkBatchId
        WHERE wb.Status IN ('Prepared', 'Paused', 'Running');
    END;

    SELECT
        Step = N'99_SUMMARY',
        ApplyChanges = @ApplyChanges,
        DryRunWorkBatchesFound = COUNT_BIG(*),
        Message =
            CASE
                WHEN @ApplyChanges = 1 THEN N'Dry-run WorkBatches were closed as Failed.'
                ELSE N'Preview only. Re-run with @ApplyChanges = 1 to close these dry-run WorkBatches.'
            END
    FROM #DryRunWorkBatches;
END
GO

CREATE OR ALTER VIEW [arch].[v_OperationalHealth]
AS
WITH run_item_base AS
(
    SELECT
        p.ProcessCode,
        r.SourceDb,
        r.ArchiveDb,
        r.RunId,
        ri.RunItemId,
        WorkBatchId = CONVERT(bigint, NULL),
        Status = ri.Status,
        StartedAtUtc = ri.StartedAt,
        EndedAtUtc = ri.EndedAt,
        LastActivityAtUtc = COALESCE(ri.EndedAt, ri.StartedAt),
        ri.DocsDone,
        ri.RowsDeleted,
        ri.RowsArchived,
        ri.ErrorMessage
    FROM arch.RunItem ri
    JOIN arch.Run r
      ON r.RunId = ri.RunId
    JOIN arch.Process p
      ON p.ProcessId = ri.ProcessId
),
audit_by_runitem AS
(
    SELECT
        RunItemId,
        AuditRows = COUNT_BIG(*)
    FROM arch.RunDocAudit
    GROUP BY RunItemId
)
SELECT
    HealthArea = CONVERT(nvarchar(80), N'RUNNING_NO_RECENT_ACTIVITY'),
    Severity = CONVERT(nvarchar(10), N'WARN'),
    b.ProcessCode,
    b.SourceDb,
    b.ArchiveDb,
    b.RunId,
    b.RunItemId,
    b.WorkBatchId,
    b.Status,
    b.StartedAtUtc,
    b.EndedAtUtc,
    b.LastActivityAtUtc,
    b.DocsDone,
    b.RowsDeleted,
    b.RowsArchived,
    AuditRows = CONVERT(bigint, NULL),
    Details = CONVERT(nvarchar(1000), N'RunItem is RUNNING and older than 30 minutes. Review and use arch.usp_MarkStaleRunsFailed if the worker is no longer active.')
FROM run_item_base b
WHERE b.Status = N'RUNNING'
  AND b.StartedAtUtc < DATEADD(MINUTE, -30, CONVERT(datetime2(0), SYSUTCDATETIME()))

UNION ALL

SELECT
    HealthArea = CONVERT(nvarchar(80), N'FAILED_RECENT'),
    Severity = CONVERT(nvarchar(10), N'WARN'),
    b.ProcessCode,
    b.SourceDb,
    b.ArchiveDb,
    b.RunId,
    b.RunItemId,
    b.WorkBatchId,
    b.Status,
    b.StartedAtUtc,
    b.EndedAtUtc,
    b.LastActivityAtUtc,
    b.DocsDone,
    b.RowsDeleted,
    b.RowsArchived,
    AuditRows = CONVERT(bigint, NULL),
    Details = CONVERT(nvarchar(1000), LEFT(COALESCE(b.ErrorMessage, N'RunItem failed without ErrorMessage.'), 1000))
FROM run_item_base b
WHERE b.Status = N'FAILED'
  AND b.StartedAtUtc >= DATEADD(DAY, -7, CONVERT(datetime2(0), SYSUTCDATETIME()))

UNION ALL

SELECT
    HealthArea = CONVERT(nvarchar(80), N'ROW_COUNT_MISMATCH'),
    Severity = CONVERT(nvarchar(10), N'ERROR'),
    b.ProcessCode,
    b.SourceDb,
    b.ArchiveDb,
    b.RunId,
    b.RunItemId,
    b.WorkBatchId,
    b.Status,
    b.StartedAtUtc,
    b.EndedAtUtc,
    b.LastActivityAtUtc,
    b.DocsDone,
    b.RowsDeleted,
    b.RowsArchived,
    AuditRows = CONVERT(bigint, NULL),
    Details = CONVERT(nvarchar(1000), N'RowsDeleted differs from RowsArchived. Review RunItemObject and target Mode before trusting this run.')
FROM run_item_base b
WHERE b.RowsDeleted <> b.RowsArchived

UNION ALL

SELECT
    HealthArea = CONVERT(nvarchar(80), N'ROW_AUDIT_MISSING'),
    Severity = CONVERT(nvarchar(10), N'ERROR'),
    b.ProcessCode,
    b.SourceDb,
    b.ArchiveDb,
    b.RunId,
    b.RunItemId,
    b.WorkBatchId,
    b.Status,
    b.StartedAtUtc,
    b.EndedAtUtc,
    b.LastActivityAtUtc,
    b.DocsDone,
    b.RowsDeleted,
    b.RowsArchived,
    AuditRows = COALESCE(a.AuditRows, 0),
    Details = CONVERT(nvarchar(1000), N'Effective AuditLevel is ROW, RunItem archived/deleted documents, but RunDocAudit has fewer rows than DocsDone.')
FROM run_item_base b
JOIN arch.v_ProcessDatabaseEffective e
  ON e.ProcessCode = b.ProcessCode
 AND e.SourceDb = b.SourceDb
 AND e.ArchiveDb = b.ArchiveDb
LEFT JOIN audit_by_runitem a
  ON a.RunItemId = b.RunItemId
WHERE b.Status = N'OK'
  AND e.AuditLevel = N'ROW'
  AND b.DocsDone > 0
  AND b.StartedAtUtc >= DATEADD(DAY, -7, CONVERT(datetime2(0), SYSUTCDATETIME()))
  AND COALESCE(a.AuditRows, 0) < b.DocsDone

UNION ALL

SELECT
    HealthArea = CONVERT(nvarchar(80), N'OPEN_WORKBATCH'),
    Severity = CONVERT(nvarchar(10), N'WARN'),
    p.ProcessCode,
    wb.SourceDb,
    wb.ArchiveDb,
    RunId = CONVERT(bigint, NULL),
    RunItemId = CONVERT(bigint, NULL),
    wb.WorkBatchId,
    Status = CONVERT(nvarchar(20), wb.Status),
    StartedAtUtc = COALESCE(wb.StartedAtUtc, wb.PreparedAtUtc),
    EndedAtUtc = wb.CompletedAtUtc,
    LastActivityAtUtc = COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc),
    DocsDone = CONVERT(int, NULL),
    RowsDeleted = CONVERT(bigint, NULL),
    RowsArchived = CONVERT(bigint, NULL),
    AuditRows = CONVERT(bigint, NULL),
    Details = CONVERT(nvarchar(1000), COALESCE(wb.Notes, N'Open WorkBatch can block ANCHOR candidate preparation.'))
FROM arch.WorkBatch wb
JOIN arch.Process p
  ON p.ProcessId = wb.ProcessId
WHERE wb.Status IN ('Prepared', 'Running', 'Paused');
GO
-- <<< end: kArchiveManagerAdmin\v2\024_operational_maintenance.sql
GO
GO

-- ---- Phase 8: provisioning + validation helper procs (GetOutputColumns BEFORE 042 restore) ----
-- >>> inlined: kArchiveManagerAdmin\procedures\arch.usp_GetOutputColumns.sql
USE [kArchiveManagerAdmin]
GO
/****** Object:  StoredProcedure [arch].[usp_GetOutputColumns]    Script Date: 27.04.2026 15:00:55 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE OR ALTER PROCEDURE [arch].[usp_GetOutputColumns]
    @SourceDb     sysname,
    @SourceSchema sysname,
    @SourceTable  sysname,
    @IncludeComputed bit = 0,
    @ExcludeRowversion bit = 0,   -- restore path sets this: a rowversion/timestamp column cannot be INSERTed explicitly
    @DeletedSelectList nvarchar(max) OUTPUT,
    @TargetColumnList  nvarchar(max) OUTPUT,
    @SourceAlias       sysname = N't',          -- T-? copy-only: alias used by @SourceSelectList
    @SourceSelectList  nvarchar(max) = NULL OUTPUT   -- e.g. 't.[col1],t.[col2]' for INSERT ... SELECT (copy, no OUTPUT)
AS
BEGIN
    SET NOCOUNT ON;

    SET @DeletedSelectList = N'';
    SET @TargetColumnList  = N'';
    SET @SourceSelectList  = N'';

    DECLARE @aliasPrefix nvarchar(140) = QUOTENAME(@SourceAlias) + N'.';

    DECLARE @sql nvarchar(max) = N'
;WITH c AS
(
    SELECT c.column_id, c.name, c.is_computed
    FROM ' + QUOTENAME(@SourceDb) + N'.sys.columns c
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.objects o ON o.object_id = c.object_id
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.schemas s ON s.schema_id = o.schema_id
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.types t ON t.user_type_id = c.user_type_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @sch COLLATE DATABASE_DEFAULT
      AND o.name COLLATE DATABASE_DEFAULT = @tbl COLLATE DATABASE_DEFAULT
      AND o.type = ''U''
      AND (@IncludeComputed = 1 OR c.is_computed = 0)
      AND (@ExcludeRowversion = 0 OR t.name <> N''timestamp'')   -- rowversion''s system type name is ''timestamp''
)
SELECT
    @Deleted =
        STUFF((
            SELECT N'','' + N''DELETED.'' + QUOTENAME(name)
            FROM c
            ORDER BY column_id
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 1, N''''),
    @Target =
        STUFF((
            SELECT N'','' + QUOTENAME(name)
            FROM c
            ORDER BY column_id
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 1, N''''),
    @Source =
        STUFF((
            SELECT N'','' + @prefix + QUOTENAME(name)
            FROM c
            ORDER BY column_id
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 1, N'''');
';

    EXEC sys.sp_executesql
        @sql,
        N'@sch sysname, @tbl sysname, @IncludeComputed bit, @ExcludeRowversion bit, @prefix nvarchar(140), @Deleted nvarchar(max) OUTPUT, @Target nvarchar(max) OUTPUT, @Source nvarchar(max) OUTPUT',
        @sch=@SourceSchema, @tbl=@SourceTable, @IncludeComputed=@IncludeComputed, @ExcludeRowversion=@ExcludeRowversion, @prefix=@aliasPrefix,
        @Deleted=@DeletedSelectList OUTPUT, @Target=@TargetColumnList OUTPUT, @Source=@SourceSelectList OUTPUT;

    IF NULLIF(@DeletedSelectList, N'') IS NULL
       OR NULLIF(@TargetColumnList, N'') IS NULL
    BEGIN
        RAISERROR(N'No output columns found for source table: %s.%s.%s', 16, 1, @SourceDb, @SourceSchema, @SourceTable);
        RETURN;
    END
END
-- <<< end: kArchiveManagerAdmin\procedures\arch.usp_GetOutputColumns.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\procedures\arch.usp_EnsureArchiveTableLikeSource.sql
USE [kArchiveManagerAdmin]
GO
/****** Object:  StoredProcedure [arch].[usp_EnsureArchiveTableLikeSource]    Script Date: 27.04.2026 14:59:31 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE OR ALTER PROCEDURE [arch].[usp_EnsureArchiveTableLikeSource]
    @SourceDb       sysname,
    @ArchiveDb      sysname,
    @SourceSchema   sysname,
    @SourceTable    sysname,
    @ArchiveSchema  sysname = N'dbo',
    @ArchiveTable   sysname = NULL,
    @MakeAllNullable bit = 1,
    @IncludeComputed bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ArchiveSchema = COALESCE(NULLIF(LTRIM(RTRIM(@ArchiveSchema)), N''), N'{SourceDb}');
    IF @ArchiveSchema = N'dbo'
        SET @ArchiveSchema = N'{SourceDb}';
    SET @ArchiveSchema = CONVERT(nvarchar(128), REPLACE(@ArchiveSchema, N'{SourceDb}', @SourceDb));

    IF @ArchiveTable IS NULL SET @ArchiveTable = @SourceTable;

    DECLARE @dstObj nvarchar(600) =
        QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@ArchiveSchema) + N'.' + QUOTENAME(@ArchiveTable);

    /* 1) ensure schema exists in archive db */
    DECLARE @schemaExists bit;
    DECLARE @chkSchema nvarchar(max) = N'
SELECT @e = CASE WHEN EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(@ArchiveDb) + N'.sys.schemas
    WHERE name COLLATE DATABASE_DEFAULT = @sch COLLATE DATABASE_DEFAULT
) THEN 1 ELSE 0 END;';
    EXEC sys.sp_executesql
        @chkSchema,
        N'@sch sysname, @e bit OUTPUT',
        @sch=@ArchiveSchema, @e=@schemaExists OUTPUT;

    IF @schemaExists = 0
    BEGIN
        DECLARE @createSchema nvarchar(max) =
            N'USE ' + QUOTENAME(@ArchiveDb) + N'; EXEC(N''CREATE SCHEMA ' +
            REPLACE(QUOTENAME(@ArchiveSchema), N'''', N'''''') + N' AUTHORIZATION dbo'');';
        EXEC (@createSchema);
    END

    /* 2) check if table exists */
    DECLARE @exists bit;
    DECLARE @chk nvarchar(max) = N'
SELECT @e = CASE WHEN EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(@ArchiveDb) + N'.sys.tables t
    JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.schemas s ON s.schema_id=t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @sch COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @tbl COLLATE DATABASE_DEFAULT
) THEN 1 ELSE 0 END;';
    EXEC sys.sp_executesql
        @chk,
        N'@sch sysname, @tbl sysname, @e bit OUTPUT',
        @sch=@ArchiveSchema, @tbl=@ArchiveTable, @e=@exists OUTPUT;

    /* 3) load source columns */
    CREATE TABLE #cols
    (
        column_id   int NOT NULL,
        colname     sysname NOT NULL,
        type_sql    nvarchar(4000) NOT NULL,
        is_nullable bit NOT NULL,
        sys_type    sysname NULL,   -- T-19: raw metadata for source-vs-archive drift reconciliation
        max_length  int NULL,
        [precision] int NULL,
        scale       int NULL
    );

    DECLARE @loadCols nvarchar(max) = N'
;WITH c AS
(
    SELECT
        c.column_id,
        c.name AS colname,
        c.is_nullable,
        c.is_computed,
        st.name AS system_type_name,
        c.max_length,
        c.precision,
        c.scale,
        c.collation_name
    FROM ' + QUOTENAME(@SourceDb) + N'.sys.columns c
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.objects o ON o.object_id=c.object_id
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.schemas s ON s.schema_id=o.schema_id
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.types ut ON ut.user_type_id=c.user_type_id
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.types st ON st.user_type_id=ut.system_type_id AND st.is_user_defined=0
    WHERE s.name COLLATE DATABASE_DEFAULT = @srcSchema COLLATE DATABASE_DEFAULT
      AND o.name COLLATE DATABASE_DEFAULT = @srcTable COLLATE DATABASE_DEFAULT
      AND o.type=''U''
      AND (@IncludeComputed=1 OR c.is_computed=0)
)
INSERT #cols(column_id, colname, type_sql, is_nullable, sys_type, max_length, [precision], scale)
SELECT
    column_id,
    colname,
    CASE
        WHEN system_type_name IN (N''timestamp'', N''rowversion'') THEN N''binary(8)''
        WHEN system_type_name IN (N''varchar'', N''char'', N''varbinary'', N''binary'')
            THEN system_type_name + N''('' + CASE WHEN max_length=-1 THEN N''max'' ELSE CAST(max_length AS nvarchar(10)) END + N'')''
        WHEN system_type_name IN (N''nvarchar'', N''nchar'')
            THEN system_type_name + N''('' + CASE WHEN max_length=-1 THEN N''max'' ELSE CAST(max_length/2 AS nvarchar(10)) END + N'')''
        WHEN system_type_name IN (N''decimal'', N''numeric'')
            THEN system_type_name + N''('' + CAST(precision AS nvarchar(10)) + N'','' + CAST(scale AS nvarchar(10)) + N'')''
        WHEN system_type_name IN (N''datetime2'', N''datetimeoffset'', N''time'')
            THEN system_type_name + N''('' + CAST(scale AS nvarchar(10)) + N'')''
        ELSE system_type_name
    END
    /* fix COLLATE: do NOT bracket collation name */
    + CASE
        WHEN system_type_name IN (N''varchar'',N''char'',N''nvarchar'',N''nchar'')
             AND collation_name IS NOT NULL
             THEN N'' COLLATE '' + collation_name
        ELSE N''''
      END AS type_sql,
    CASE WHEN @MakeAllNullable=1 THEN 1 ELSE is_nullable END,
    /* T-19 fix: a source timestamp/rowversion column is archived as binary(8) (see type_sql above),
       so record its drift-comparison sys_type as ''binary'' too — otherwise the reconcile guard
       compares raw ''timestamp'' vs the archive''s ''binary'' and falsely BLOCKs (THROW 50410). */
    CASE WHEN system_type_name IN (N''timestamp'', N''rowversion'') THEN N''binary'' ELSE system_type_name END,
    max_length, precision, scale
FROM c
ORDER BY column_id;
';
    EXEC sys.sp_executesql
        @loadCols,
        N'@srcSchema sysname, @srcTable sysname, @MakeAllNullable bit, @IncludeComputed bit',
        @srcSchema=@SourceSchema, @srcTable=@SourceTable,
        @MakeAllNullable=@MakeAllNullable, @IncludeComputed=@IncludeComputed;

    IF NOT EXISTS (SELECT 1 FROM #cols)
    BEGIN
        DROP TABLE #cols;
        RAISERROR(N'Source table has no archivable columns or does not exist: %s.%s.%s', 16, 1, @SourceDb, @SourceSchema, @SourceTable);
        RETURN;
    END

    /* 4) CREATE TABLE if missing */
    IF @exists = 0
    BEGIN
        DECLARE @colDef nvarchar(max) = N'';
        SELECT @colDef = @colDef +
            CASE WHEN @colDef = N'' THEN N'' ELSE N',' + CHAR(10) END +
            N'    ' + QUOTENAME(colname) + N' ' + type_sql + N' ' + CASE WHEN is_nullable=1 THEN N'NULL' ELSE N'NOT NULL' END
        FROM #cols
        ORDER BY column_id;

        DECLARE @create nvarchar(max) = N'CREATE TABLE ' + @dstObj + N'(' + CHAR(10) + @colDef + CHAR(10) + N');';
        EXEC (@create);

        INSERT arch.ArchiveProvisionLog(SourceDb,ArchiveDb,SourceSchema,SourceTable,Action,Details)
        VALUES (@SourceDb,@ArchiveDb,@SourceSchema,@SourceTable,N'CREATE_TABLE',@create);
    END
    ELSE
    BEGIN
        /* 5) add missing columns */
        CREATE TABLE #archCols(colname sysname NOT NULL PRIMARY KEY);

        DECLARE @loadArch nvarchar(max) = N'
INSERT #archCols(colname)
SELECT c.name
FROM ' + QUOTENAME(@ArchiveDb) + N'.sys.columns c
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.objects o ON o.object_id=c.object_id
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.schemas s ON s.schema_id=o.schema_id
WHERE s.name COLLATE DATABASE_DEFAULT = @sch COLLATE DATABASE_DEFAULT
  AND o.name COLLATE DATABASE_DEFAULT = @tbl COLLATE DATABASE_DEFAULT
  AND o.type=''U'';';
        EXEC sys.sp_executesql @loadArch, N'@sch sysname,@tbl sysname', @sch=@ArchiveSchema, @tbl=@ArchiveTable;

        DECLARE @alter nvarchar(max) = N'';
        SELECT @alter = @alter +
            N'ALTER TABLE ' + @dstObj + N' ADD ' + QUOTENAME(c.colname) + N' ' + c.type_sql + N' NULL;' + CHAR(10)
        FROM #cols c
        LEFT JOIN #archCols a ON a.colname=c.colname
        WHERE a.colname IS NULL;

        IF @alter <> N''
        BEGIN
            EXEC (@alter);
            INSERT arch.ArchiveProvisionLog(SourceDb,ArchiveDb,SourceSchema,SourceTable,Action,Details)
            VALUES (@SourceDb,@ArchiveDb,@SourceSchema,@SourceTable,N'ADD_COLUMNS',@alter);
        END

        /* 6) T-19: reconcile EXISTING columns. The archive is the ONLY copy of deleted rows, so a
              source column that grew (varchar(50)->(100), int->bigger, more decimal precision, deeper
              datetime2 scale) must NOT be allowed to silently truncate/overflow on the next
              DELETE...OUTPUT INTO. Same-type growth is auto-WIDENED (never narrowed); any incompatible
              type change BLOCKS the run (THROW 50410) until an operator reconciles it. */
        CREATE TABLE #archMeta
        (
            colname    sysname NOT NULL PRIMARY KEY,
            sys_type   sysname NULL,
            max_length int NULL,
            [precision] int NULL,
            scale      int NULL
        );

        DECLARE @loadArchMeta nvarchar(max) = N'
INSERT #archMeta(colname, sys_type, max_length, [precision], scale)
SELECT c.name, st.name, c.max_length, c.precision, c.scale
FROM ' + QUOTENAME(@ArchiveDb) + N'.sys.columns c
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.objects o ON o.object_id=c.object_id
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.schemas s ON s.schema_id=o.schema_id
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.types ut ON ut.user_type_id=c.user_type_id
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.types st ON st.user_type_id=ut.system_type_id AND st.is_user_defined=0
WHERE s.name COLLATE DATABASE_DEFAULT=@sch COLLATE DATABASE_DEFAULT
  AND o.name COLLATE DATABASE_DEFAULT=@tbl COLLATE DATABASE_DEFAULT
  AND o.type=''U'';';
        EXEC sys.sp_executesql @loadArchMeta, N'@sch sysname,@tbl sysname', @sch=@ArchiveSchema, @tbl=@ArchiveTable;

        ;WITH cmp AS
        (
            SELECT c.colname, c.type_sql,
                   src_type=c.sys_type, arc_type=a.sys_type,
                   src_len=c.max_length, arc_len=a.max_length,
                   src_p=c.[precision], arc_p=a.[precision],
                   src_s=c.scale, arc_s=a.scale,
                   src_eff=CASE WHEN c.max_length=-1 THEN 2147483647 ELSE c.max_length END,
                   arc_eff=CASE WHEN a.max_length=-1 THEN 2147483647 ELSE a.max_length END
            FROM #cols c
            JOIN #archMeta a ON a.colname=c.colname
            WHERE c.sys_type<>a.sys_type OR c.max_length<>a.max_length
               OR c.[precision]<>a.[precision] OR c.scale<>a.scale
        )
        SELECT cmp.*,
            action = CASE
                WHEN src_type=arc_type
                     AND src_type IN (N'varchar',N'nvarchar',N'char',N'nchar',N'varbinary',N'binary')
                     AND src_eff>arc_eff THEN N'WIDEN'
                WHEN src_type=arc_type AND src_type IN (N'decimal',N'numeric')
                     AND src_p>=arc_p AND src_s>=arc_s AND (src_p>arc_p OR src_s>arc_s) THEN N'WIDEN'
                WHEN src_type=arc_type AND src_type IN (N'datetime2',N'datetimeoffset',N'time')
                     AND src_s>arc_s THEN N'WIDEN'
                WHEN src_type=arc_type
                     AND ( (src_type IN (N'varchar',N'nvarchar',N'char',N'nchar',N'varbinary',N'binary') AND src_eff<=arc_eff)
                        OR (src_type IN (N'decimal',N'numeric') AND src_p<=arc_p AND src_s<=arc_s)
                        OR (src_type IN (N'datetime2',N'datetimeoffset',N'time') AND src_s<=arc_s) ) THEN N'OK'
                ELSE N'BLOCK'
            END
        INTO #drift
        FROM cmp;

        IF EXISTS (SELECT 1 FROM #drift WHERE action=N'BLOCK')
        BEGIN
            DECLARE @blk nvarchar(max);
            SELECT @blk = STRING_AGG(
                colname + N' (src ' + src_type + N'(' + CONVERT(nvarchar(12),src_len) + N'/' + CONVERT(nvarchar(6),src_p) + N',' + CONVERT(nvarchar(6),src_s)
                + N') -> arc ' + arc_type + N'(' + CONVERT(nvarchar(12),arc_len) + N'/' + CONVERT(nvarchar(6),arc_p) + N',' + CONVERT(nvarchar(6),arc_s) + N'))', N'; ')
            FROM #drift WHERE action=N'BLOCK';

            DECLARE @blkMsg nvarchar(2048) =
                N'Schema drift would corrupt the only copy of deleted data on archive ' + @dstObj
              + N' (incompatible source column type change). Reconcile the archive manually before running. Columns: ' + @blk;
            ;THROW 50410, @blkMsg, 1;
        END;

        DECLARE @widen nvarchar(max) = N'';
        SELECT @widen = @widen +
            N'ALTER TABLE ' + @dstObj + N' ALTER COLUMN ' + QUOTENAME(colname) + N' ' + type_sql + N' NULL;' + CHAR(10)
        FROM #drift WHERE action=N'WIDEN';

        IF @widen <> N''
        BEGIN
            EXEC (@widen);
            INSERT arch.ArchiveProvisionLog(SourceDb,ArchiveDb,SourceSchema,SourceTable,Action,Details)
            VALUES (@SourceDb,@ArchiveDb,@SourceSchema,@SourceTable,N'WIDEN_COLUMNS',@widen);
        END;

        DROP TABLE #archMeta;
        DROP TABLE #drift;
    END

    DROP TABLE #cols;
END
-- <<< end: kArchiveManagerAdmin\procedures\arch.usp_EnsureArchiveTableLikeSource.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\procedures\arch.usp_ProvisionArchiveTablesForProcess.sql
USE [kArchiveManagerAdmin]
GO
/****** Object:  StoredProcedure [arch].[usp_ProvisionArchiveTablesForProcess]    Script Date: 27.04.2026 15:01:56 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


/* 5) Provisioning helpers */
CREATE OR ALTER PROCEDURE [arch].[usp_ProvisionArchiveTablesForProcess]
    @ProcessCode sysname,
    @SourceDb    sysname,
    @ArchiveDb   sysname,
    @MakeAllNullable bit = 1,
    @IncludeComputed bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ProcessDatabaseId int =
    (
        SELECT ProcessDatabaseId
        FROM arch.v_ProcessDatabaseEffective
        WHERE ProcessCode = @ProcessCode
          AND SourceDb = @SourceDb
          AND ArchiveDb = @ArchiveDb
          AND IsEnabled = 1
    );

    IF @ProcessDatabaseId IS NULL
        THROW 50000, 'Unknown ProcessCode.', 1;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT
        os.SourceSchema,
        os.SourceTable,
        CONVERT(nvarchar(128), REPLACE(
            CASE
                WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo' THEN N'{SourceDb}'
                ELSE LTRIM(RTRIM(os.ArchiveSchema))
            END,
            N'{SourceDb}', @SourceDb)) AS ArchiveSchema,
        COALESCE(os.ArchiveTable, os.SourceTable) AS ArchiveTable
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessDatabaseId = @ProcessDatabaseId
      AND os.ObjectIsEnabled = 1
    ORDER BY os.DeleteOrder;

    DECLARE @ss sysname, @st sysname, @as sysname, @at sysname;

    OPEN c;
    FETCH NEXT FROM c INTO @ss,@st,@as,@at;

    WHILE @@FETCH_STATUS=0
    BEGIN
        EXEC arch.usp_EnsureArchiveTableLikeSource
            @SourceDb=@SourceDb,
            @ArchiveDb=@ArchiveDb,
            @SourceSchema=@ss,
            @SourceTable=@st,
            @ArchiveSchema=@as,
            @ArchiveTable=@at,
            @MakeAllNullable=@MakeAllNullable,
            @IncludeComputed=@IncludeComputed;

        FETCH NEXT FROM c INTO @ss,@st,@as,@at;
    END

    CLOSE c;
    DEALLOCATE c;
END
-- <<< end: kArchiveManagerAdmin\procedures\arch.usp_ProvisionArchiveTablesForProcess.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\procedures\arch.usp_ValidateConfiguration.sql
USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_ValidateConfiguration]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Findings
    (
        Severity varchar(10) NOT NULL,
        ProcessCode sysname NULL,
        SourceDb sysname NULL,
        ArchiveDb sysname NULL,
        ObjectName nvarchar(300) NULL,
        Finding nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL,   -- concrete remediation SQL the operator can copy/run
        ActionKey nvarchar(60) NULL        -- when set, a safe one-click remediation exists (Console "Apply"); dispatched by arch.usp_Api_ApplyConfigFix
    );

    INSERT #Findings(Severity, ProcessCode, Finding)
    SELECT 'ERROR', p.ProcessCode, N'Process is enabled but has no ObjectSpec rows.'
    FROM arch.Process p
    WHERE p.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND NOT EXISTS (SELECT 1 FROM arch.ObjectSpec os WHERE os.ProcessId = p.ProcessId);

    INSERT #Findings(Severity, ProcessCode, Finding)
    SELECT 'ERROR', p.ProcessCode, N'Process is enabled but has no enabled ProcessDatabase mapping.'
    FROM arch.Process p
    WHERE p.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND NOT EXISTS
      (
          SELECT 1
          FROM arch.ProcessDatabase pd
          WHERE pd.ProcessId = p.ProcessId
            AND pd.IsEnabled = 1
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'WARN',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        N'Redundant database override in arch.ProcessDatabase: ' + v.ConfigName
        + N' equals the arch.Process default. Keep this ProcessDatabase column NULL unless the database intentionally differs.'
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    CROSS APPLY
    (
        VALUES
            (N'Mode', CASE WHEN pd.Mode IS NOT NULL AND pd.Mode = p.Mode THEN 1 ELSE 0 END),
            (N'RetentionDays', CASE WHEN pd.RetentionDays IS NOT NULL AND pd.RetentionDays = p.RetentionDays THEN 1 ELSE 0 END),
            (N'CutoffSafetyLagMinutes', CASE WHEN pd.CutoffSafetyLagMinutes IS NOT NULL AND pd.CutoffSafetyLagMinutes = p.CutoffSafetyLagMinutes THEN 1 ELSE 0 END),
            (N'CutoffMode', CASE WHEN pd.CutoffMode IS NOT NULL AND pd.CutoffMode = p.CutoffMode THEN 1 ELSE 0 END),
            (N'CutoffDate', CASE WHEN pd.CutoffDate IS NOT NULL AND pd.CutoffDate = p.CutoffDate THEN 1 ELSE 0 END),
            (N'BatchDocCount', CASE WHEN pd.BatchDocCount IS NOT NULL AND pd.BatchDocCount = p.BatchDocCount THEN 1 ELSE 0 END),
            (N'BatchRowCount', CASE WHEN pd.BatchRowCount IS NOT NULL AND pd.BatchRowCount = p.BatchRowCount THEN 1 ELSE 0 END),
            (N'MaxBatchesPerRun', CASE WHEN pd.MaxBatchesPerRun IS NOT NULL AND pd.MaxBatchesPerRun = p.MaxBatchesPerRun THEN 1 ELSE 0 END),
            (N'DelayMsBetweenBatches', CASE WHEN pd.DelayMsBetweenBatches IS NOT NULL AND pd.DelayMsBetweenBatches = p.DelayMsBetweenBatches THEN 1 ELSE 0 END),
            (N'UseAppLock', CASE WHEN pd.UseAppLock IS NOT NULL AND pd.UseAppLock = p.UseAppLock THEN 1 ELSE 0 END),
            (N'AppLockResource', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AppLockResource)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AppLockResource)), N'') = NULLIF(LTRIM(RTRIM(p.AppLockResource)), N'') THEN 1 ELSE 0 END),
            (N'LockTimeoutMs', CASE WHEN pd.LockTimeoutMs IS NOT NULL AND pd.LockTimeoutMs = p.LockTimeoutMs THEN 1 ELSE 0 END),
            (N'DeadlockPriority', CASE WHEN NULLIF(LTRIM(RTRIM(pd.DeadlockPriority)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.DeadlockPriority)), N'') = NULLIF(LTRIM(RTRIM(p.DeadlockPriority)), N'') THEN 1 ELSE 0 END),
            (N'AnchorSchema', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorSchema)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorSchema)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorSchema)), N'') THEN 1 ELSE 0 END),
            (N'AnchorTable', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorTable)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorTable)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorTable)), N'') THEN 1 ELSE 0 END),
            (N'AnchorDocKeyExpr', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorDocKeyExpr)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorDocKeyExpr)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorDocKeyExpr)), N'') THEN 1 ELSE 0 END),
            (N'AnchorDocKey2Expr', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorDocKey2Expr)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorDocKey2Expr)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorDocKey2Expr)), N'') THEN 1 ELSE 0 END),
            (N'AnchorTimestampExpr', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorTimestampExpr)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorTimestampExpr)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorTimestampExpr)), N'') THEN 1 ELSE 0 END),
            (N'AnchorExtraWhereSql', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorExtraWhereSql)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorExtraWhereSql)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorExtraWhereSql)), N'') THEN 1 ELSE 0 END),
            (N'AllowDeleteWithoutArchive', CASE WHEN pd.AllowDeleteWithoutArchive IS NOT NULL AND pd.AllowDeleteWithoutArchive = p.AllowDeleteWithoutArchive THEN 1 ELSE 0 END),
            (N'DocKeyLabel', CASE WHEN NULLIF(LTRIM(RTRIM(pd.DocKeyLabel)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.DocKeyLabel)), N'') = NULLIF(LTRIM(RTRIM(p.DocKeyLabel)), N'') THEN 1 ELSE 0 END),
            (N'AuditLevel', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AuditLevel)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AuditLevel)), N'') = NULLIF(LTRIM(RTRIM(p.AuditLevel)), N'') THEN 1 ELSE 0 END),
            (N'RequireSupportingIndex', CASE WHEN pd.RequireSupportingIndex IS NOT NULL AND pd.RequireSupportingIndex = p.RequireSupportingIndex THEN 1 ELSE 0 END),
            (N'MaxRowsPerTransaction', CASE WHEN pd.MaxRowsPerTransaction IS NOT NULL AND pd.MaxRowsPerTransaction = p.MaxRowsPerTransaction THEN 1 ELSE 0 END),
            (N'CandidateWhereSql', CASE WHEN NULLIF(LTRIM(RTRIM(pd.CandidateWhereSql)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.CandidateWhereSql)), N'') = NULLIF(LTRIM(RTRIM(p.CandidateWhereSql)), N'') THEN 1 ELSE 0 END),
            (N'CandidateOrderSql', CASE WHEN NULLIF(LTRIM(RTRIM(pd.CandidateOrderSql)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.CandidateOrderSql)), N'') = NULLIF(LTRIM(RTRIM(p.CandidateOrderSql)), N'') THEN 1 ELSE 0 END)
    ) AS v(ConfigName, IsRedundant)
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND v.IsRedundant = 1;

    -- CRITICAL SAFETY: oversized per-transaction delete batch -> lock escalation on the PRODUCTION source.
    -- SQL Server escalates a statement's row locks to a TABLE X lock at ~5000 locks; a per-batch DELETE of
    -- more than that many source rows therefore takes an exclusive lock on the whole source table and BLOCKS
    -- OLTP for the batch duration (proven live: 50000-row batch -> OBJECT X lock + blocked readers; 4000 -> safe).
    -- Block go-live for any enabled mapping whose effective per-transaction ROW cap exceeds the safe limit.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        N'Per-transaction delete batch is too large ('
          + CONVERT(nvarchar(20), (SELECT MAX(v) FROM (VALUES
                (COALESCE(pd.BatchRowCount, p.BatchRowCount)),
                (COALESCE(pd.BatchDocCount, p.BatchDocCount)),
                (COALESCE(pd.MaxRowsPerTransaction, p.MaxRowsPerTransaction))) AS x(v)))
          + N' rows). A single DELETE of that many rows can escalate to a TABLE X lock on the production source '
          + N'and block OLTP for the batch duration. Keep BatchRowCount, BatchDocCount and MaxRowsPerTransaction <= 4000 '
          + N'and raise MaxBatchesPerRun to keep throughput (e.g. 4000 x 250 = 1,000,000 rows per run). '
          + N'(The runner also hard-caps the per-transaction delete at 4000 as a backstop.)'
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND (   COALESCE(pd.BatchRowCount, p.BatchRowCount, 0) > 4000
           OR COALESCE(pd.BatchDocCount, p.BatchDocCount, 0) > 4000
           OR COALESCE(pd.MaxRowsPerTransaction, p.MaxRowsPerTransaction, 0) > 4000);

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'WARN',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        N'Global arch.Process CutoffDate is active for a process with multiple enabled database mappings. Prefer setting CutoffMode/CutoffDate in arch.ProcessDatabase when cutoffs are database-specific.'
    FROM arch.Process p
    JOIN arch.ProcessDatabase pd
      ON pd.ProcessId = p.ProcessId
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND p.CutoffMode = 1
      AND p.CutoffDate IS NOT NULL
      AND pd.CutoffMode IS NULL
      AND pd.CutoffDate IS NULL
      AND 1 <
      (
          SELECT COUNT_BIG(*)
          FROM arch.ProcessDatabase pd2
          WHERE pd2.ProcessId = p.ProcessId
            AND pd2.IsEnabled = 1
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'WARN',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        QUOTENAME(COALESCE(NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N''), os.SourceSchema))
        + N'.' + QUOTENAME(COALESCE(NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N''), os.SourceTable)),
        N'Redundant object override in arch.ObjectSpecDatabaseOverride: ' + v.ConfigName
        + N' equals the arch.ObjectSpec default. Keep this override column NULL unless the database/table intentionally differs.'
    FROM arch.ObjectSpecDatabaseOverride osdo
    JOIN arch.ProcessDatabase pd
      ON pd.ProcessDatabaseId = osdo.ProcessDatabaseId
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    JOIN arch.ObjectSpec os
      ON os.ObjectSpecId = osdo.ObjectSpecId
     AND os.ProcessId = p.ProcessId
    CROSS APPLY
    (
        VALUES
            (N'SourceSchemaOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N'') = NULLIF(LTRIM(RTRIM(os.SourceSchema)), N'') THEN 1 ELSE 0 END),
            (N'SourceTableOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N'') = NULLIF(LTRIM(RTRIM(os.SourceTable)), N'') THEN 1 ELSE 0 END),
            (N'TimestampExprOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.TimestampExprOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.TimestampExprOverride)), N'') = NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') THEN 1 ELSE 0 END),
            (N'JoinToAnchorPredicateSqlOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.JoinToAnchorPredicateSqlOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.JoinToAnchorPredicateSqlOverride)), N'') = NULLIF(LTRIM(RTRIM(os.JoinToAnchorPredicateSql)), N'') THEN 1 ELSE 0 END),
            (N'AdditionalWhereSqlOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.AdditionalWhereSqlOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.AdditionalWhereSqlOverride)), N'') = NULLIF(LTRIM(RTRIM(os.AdditionalWhereSql)), N'') THEN 1 ELSE 0 END),
            (N'ArchiveSchemaOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.ArchiveSchemaOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.ArchiveSchemaOverride)), N'') = NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') THEN 1 ELSE 0 END),
            (N'ArchiveTableOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.ArchiveTableOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.ArchiveTableOverride)), N'') = NULLIF(LTRIM(RTRIM(os.ArchiveTable)), N'') THEN 1 ELSE 0 END),
            (N'RequireArchiveForDeleteOverride', CASE WHEN osdo.RequireArchiveForDeleteOverride IS NOT NULL AND osdo.RequireArchiveForDeleteOverride = os.RequireArchiveForDelete THEN 1 ELSE 0 END)
    ) AS v(ConfigName, IsRedundant)
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND osdo.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND v.IsRedundant = 1;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'ObjectSpecDatabaseOverride points to an ObjectSpec from a different process than its ProcessDatabase mapping.'
    FROM arch.ObjectSpecDatabaseOverride osdo
    JOIN arch.ProcessDatabase pd
      ON pd.ProcessDatabaseId = osdo.ProcessDatabaseId
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    JOIN arch.ObjectSpec os
      ON os.ObjectSpecId = osdo.ObjectSpecId
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND os.ProcessId <> pd.ProcessId;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Anchor-driven process has incomplete anchor configuration.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
      AND
      (
          e.AnchorSchema IS NULL
          OR e.AnchorTable IS NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorDocKeyExpr)), N'') IS NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorTimestampExpr)), N'') IS NULL
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'WARN',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Non-anchor process has anchor fields populated even though SelectionStrategy is not ANCHOR.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'ANCHOR'
      AND
      (
          e.AnchorSchema IS NOT NULL
          OR e.AnchorTable IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorDocKeyExpr)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorDocKey2Expr)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorTimestampExpr)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorExtraWhereSql)), N'') IS NOT NULL
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Anchor-driven ObjectSpec requires JoinToAnchorPredicateSql.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND EXISTS
      (
          SELECT 1
          FROM arch.v_ProcessDatabaseEffective e
          WHERE e.ProcessDatabaseId = os.ProcessDatabaseId
            AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
      )
      AND os.DeleteMode = 1
      AND NULLIF(LTRIM(RTRIM(os.JoinToAnchorPredicateSql)), N'') IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Row-driven ObjectSpec requires TimestampExpr.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'TIMESTAMP'
      AND e.AnchorTable IS NULL
      AND os.DeleteMode = 0
      AND NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'TIMESTAMP process requires ObjectSpec.DeleteMode = 1.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND os.DeleteMode <> 1;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'TIMESTAMP process requires TimestampExpr and JoinToAnchorPredicateSql on every ObjectSpec.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND
      (
          NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NULL
          OR NULLIF(LTRIM(RTRIM(os.JoinToAnchorPredicateSql)), N'') IS NULL
      );

    -- Cheap-mode misconfiguration (WARN): a CandidateSelectExpr (cheap local-time projection) only takes
    -- effect when the mapping ALSO has a sargable CandidateWhereSql cutoff (027 @cheapMode needs BOTH). Set
    -- alone it is silently ignored and the runner falls back to the slower per-row AT TIME ZONE candidate
    -- selection -> surface it so the operator either completes or removes the cheap-mode setup.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'WARN',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'ObjectSpec.CandidateSelectExpr is set but the mapping has no CandidateWhereSql cutoff, so cheap-mode candidate selection will NOT activate (the runner uses the slower per-row AT TIME ZONE path). Set a sargable CandidateWhereSql on arch.ProcessDatabase (raw indexed column vs @CutoffUtc) to enable it, or clear CandidateSelectExpr.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.CandidateSelectExpr)), N'') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(e.CandidateWhereSql)), N'') IS NULL;

    -- Cheap-mode active (INFO): the sargable string cutoff is only correct when the source time column is
    -- lexicographically chronological (ISO yyyymmdd...). A mixed/non-ISO format makes it under-select rows
    -- SILENTLY (it never deletes the wrong rows, but may process 0 -> KMWE_Test.RF_LOG2 lesson). Remind the
    -- operator to verify the column format before trusting cheap-mode on this source.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'INFO',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Cheap-mode candidate selection is active (CandidateSelectExpr + CandidateWhereSql both set). Verify the source time column is lexicographically chronological (ISO yyyymmdd...): a mixed/non-ISO string format makes the sargable cutoff under-select rows silently (never wrong rows, but possibly 0). Use classic mode (clear CandidateWhereSql) for mixed-format columns.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.CandidateSelectExpr)), N'') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(e.CandidateWhereSql)), N'') IS NOT NULL;

    -- Cheap-mode AVAILABLE (INFO, performance opportunity + one-click remediation): a TIMESTAMP process whose
    -- TimestampExpr applies per-row AT TIME ZONE for candidate selection, but cheap-mode is NOT enabled
    -- (no CandidateWhereSql cutoff). Enabling cheap-mode removes the per-row AT TIME ZONE from the candidate
    -- scan (the dominant scan cost on large sources; measured ~17x on RF_LOG2). The derived config is
    -- CORRECTNESS-EQUIVALENT: it compares the SAME local timestamp (TimestampExpr with the AT TIME ZONE tail
    -- stripped) to the SAME cutoff (@CutoffUtc converted to the source's local zone ONCE), and the retention
    -- floor (50210) + safe-expr gate (50400) still apply unchanged. Offered ONLY when the mapping has exactly
    -- ONE enabled TIMESTAMP ObjectSpec (single timestamp table) so the per-ProcessDatabase CandidateWhereSql is
    -- unambiguous, and only when the local-time core + zone can be parsed from the expression. ActionKey lets
    -- the Console show an "Apply" button -> arch.usp_Api_ApplyConfigFix derives + validates + sets it server-side.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql, ActionKey)
    SELECT
        'INFO',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Performance: this TIMESTAMP process uses per-row AT TIME ZONE for candidate selection and cheap-mode is not enabled. Enabling cheap-mode removes the per-row AT TIME ZONE from the candidate scan (the dominant cost on large sources) and is correctness-equivalent (same local timestamp vs the same cutoff; retention floor and safe-expr gate still apply).',
        N'Enable cheap-mode (one-click, ActionKey=ENABLE_CHEAP_MODE) -> sets ObjectSpec.CandidateSelectExpr = '
          + d.localCore
          + N'   and   arch.ProcessDatabase.CandidateWhereSql = (' + d.localCore
          + N') < CONVERT(datetime2(0), @CutoffUtc AT TIME ZONE N''UTC'' AT TIME ZONE N''' + d.zone + N''').'
          + N' Or run: EXEC arch.usp_Api_ApplyConfigFix @ActionKey=N''ENABLE_CHEAP_MODE'', @ProcessCode=N'''
          + REPLACE(os.ProcessCode, N'''', N'''''') + N''', @SourceDb=N''' + REPLACE(os.SourceDb, N'''', N'''''') + N'''.',
        N'ENABLE_CHEAP_MODE'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    CROSS APPLY (SELECT atzPos = CHARINDEX(N' AT TIME ZONE ', os.TimestampExpr)) p1
    CROSS APPLY (SELECT localCore = LTRIM(RTRIM(LEFT(os.TimestampExpr, NULLIF(p1.atzPos, 0) - 1)))) p2
    CROSS APPLY (SELECT zTail = SUBSTRING(os.TimestampExpr, CHARINDEX(N'AT TIME ZONE N''', os.TimestampExpr) + 15, 200)) p3
    CROSS APPLY (SELECT zone = LEFT(p3.zTail, NULLIF(CHARINDEX(N'''', p3.zTail), 0) - 1)) p4
    CROSS APPLY (SELECT localCore = p2.localCore, zone = p4.zone) d
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NOT NULL
      AND os.TimestampExpr LIKE N'% AT TIME ZONE N''%'
      AND NULLIF(LTRIM(RTRIM(e.CandidateWhereSql)), N'') IS NULL          -- cheap-mode currently OFF
      AND NULLIF(d.localCore, N'') IS NOT NULL
      AND NULLIF(d.zone, N'') IS NOT NULL
      AND
      (
          SELECT COUNT_BIG(*)
          FROM arch.v_ObjectSpecDatabaseEffective os2
          WHERE os2.ProcessDatabaseId = os.ProcessDatabaseId
            AND os2.ObjectIsEnabled = 1
      ) = 1;

    -- T-23 (timezone validity): a zone name in AT TIME ZONE must resolve in sys.time_zone_info, otherwise
    -- AT TIME ZONE THROWs at run time and the scheduled run wedges. Surface a typo'd source zone at
    -- config-validation time (fail-fast) by extracting the FIRST AT TIME ZONE N'...' literal from each
    -- enabled timestamp expression and checking it. (The deeper, SILENT hazard — text-date CONVERT being
    -- SET LANGUAGE / DATEFORMAT-sensitive — is a documented config guideline: use ISO/lexically-chronological
    -- source date columns; the runner intentionally does not pin SET LANGUAGE. See the operational docs.)
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT DISTINCT
        'WARN', src.ProcessCode, src.SourceDb, src.ArchiveDb, src.ObjectName,
        N'Timestamp expression references time zone ''' + z.Zone
        + N''' which is not in sys.time_zone_info on this instance — AT TIME ZONE will THROW at run time. Fix the zone name (see SELECT name FROM sys.time_zone_info) before enabling real runs.'
    FROM
    (
        SELECT e2.ProcessCode, e2.SourceDb, e2.ArchiveDb, ObjectName = CONVERT(nvarchar(300), NULL), Expr = e2.AnchorTimestampExpr
        FROM arch.v_ProcessDatabaseEffective e2
        WHERE e2.IsEnabled = 1
          AND COALESCE(e2.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
          AND e2.AnchorTimestampExpr LIKE N'%AT TIME ZONE N''%'
          AND (@ProcessCode IS NULL OR e2.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e2.SourceDb = @SourceDb)
        UNION ALL
        SELECT os.ProcessCode, os.SourceDb, os.ArchiveDb, QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable), os.TimestampExpr
        FROM arch.v_ObjectSpecDatabaseEffective os
        WHERE os.ProcessDatabaseIsEnabled = 1 AND os.ObjectIsEnabled = 1
          AND os.TimestampExpr LIKE N'%AT TIME ZONE N''%'
          AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
    ) src
    CROSS APPLY
    (
        SELECT Zone = LEFT(
                 SUBSTRING(src.Expr, CHARINDEX(N'AT TIME ZONE N''', src.Expr) + 15, 200),
                 NULLIF(CHARINDEX(N'''', SUBSTRING(src.Expr, CHARINDEX(N'AT TIME ZONE N''', src.Expr) + 15, 200)), 0) - 1)
    ) z
    WHERE z.Zone IS NOT NULL AND z.Zone <> N''
      AND NOT EXISTS (SELECT 1 FROM sys.time_zone_info t WHERE t.name = z.Zone);

    -- Mixed-format / language hazard (WARN): a TIMESTAMP-strategy source whose TimestampExpr applies a HARD
    -- CAST/CONVERT (no TRY_) to a text date column THROWs under a non-us_english session for English month-name
    -- values (e.g. 'Apr 9 2025') and can fail the scheduled run; under us_english the same value parses, so it
    -- is an environment-dependent latent failure (the runner intentionally does not pin SET LANGUAGE). A
    -- defensive TRY_CONVERT (+ optional TRY_PARSE ... USING 'en-US') yields NULL instead of throwing, so any
    -- unparseable rows are safely skipped (never archived/deleted, divergence unaffected) and are then counted
    -- by arch.usp_Frontend_TimestampRetentionGaps. This is a METADATA check (no source-row IO): it flags the
    -- non-defensive expression and emits a SuggestedSql fix. (If cheap-mode is used, make CandidateSelectExpr
    -- defensive too.) Excludes expressions already using TRY_CONVERT/TRY_PARSE/TRY_CAST.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql)
    SELECT
        'WARN', os.ProcessCode, os.SourceDb, os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'TimestampExpr uses a hard CAST/CONVERT (no TRY_) on a TIMESTAMP source. If the source date column is text, English month-name values (e.g. ''Apr 9 2025'') THROW under a non-us_english session and can fail the run; under us_english they parse, so this is an environment-dependent latent failure. Recommended defensive expression (replace <col> with the source column): COALESCE(TRY_CONVERT(datetime2, t.<col>), TRY_PARSE(t.<col> AS datetime2 USING ''en-US'')) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''. Unparseable rows then yield NULL (safely skipped) and are counted by arch.usp_Frontend_TimestampRetentionGaps. If cheap-mode is active, make CandidateSelectExpr defensive too. Ignore if the source column is already a real datetime/UTC type.',
        N'UPDATE os SET TimestampExpr = N''<DOSADTE_DEFENZIVNI_VYRAZ_Z_FINDING>'' FROM arch.ObjectSpec os JOIN arch.Process p ON p.ProcessId = os.ProcessId WHERE p.ProcessCode = N'''
          + REPLACE(os.ProcessCode, N'''', N'''''') + N''' AND os.SourceSchema = N'''
          + REPLACE(os.SourceSchema, N'''', N'''''') + N''' AND os.SourceTable = N'''
          + REPLACE(os.SourceTable, N'''', N'''''') + N''';'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NOT NULL
      AND (os.TimestampExpr LIKE N'%CAST(%' OR os.TimestampExpr LIKE N'%CONVERT(%')
      AND os.TimestampExpr NOT LIKE N'%TRY_CAST%'
      AND os.TimestampExpr NOT LIKE N'%TRY_CONVERT%'
      AND os.TimestampExpr NOT LIKE N'%TRY_PARSE%';

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NOT NULL
    BEGIN
        INSERT #Findings(Severity, ProcessCode, Finding)
        SELECT
            'ERROR',
            p.ProcessCode,
            N'TIMESTAMP process requires arch.ProcessKeySpec KeyOrdinal=1.'
        FROM arch.Process p
        WHERE p.IsEnabled = 1
          AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
          AND COALESCE(p.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
          AND NOT EXISTS
          (
              SELECT 1
              FROM arch.ProcessKeySpec pks
              WHERE pks.ProcessId = p.ProcessId
                AND pks.KeyOrdinal = 1
                AND NULLIF(LTRIM(RTRIM(pks.SourceExpressionSql)), N'') IS NOT NULL
          );

        INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
        SELECT DISTINCT
            'WARN',
            e.ProcessCode,
            e.SourceDb,
            e.ArchiveDb,
            N'Process defines ProcessKeySpec keys beyond Key2, but arch.WorkBatchKey primary key is currently (WorkBatchId, Key1, Key2). Ensure Key1/Key2 are unique for prepared batches or migrate the WorkBatchKey key design before using multi-column keys.'
        FROM arch.v_ProcessDatabaseEffective e
        JOIN arch.ProcessKeySpec pks
          ON pks.ProcessId = e.ProcessId
        WHERE e.IsEnabled = 1
          AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
          AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'TIMESTAMP'
          AND pks.KeyOrdinal > 2;
    END;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Source database does not exist on this SQL instance.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND DB_ID(e.SourceDb) IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Archive database does not exist on this SQL instance.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND DB_ID(e.ArchiveDb) IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'SourceDb and ArchiveDb are identical for an archive+delete or copy-only process.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND e.Mode IN (1, 2)
      AND e.SourceDb = e.ArchiveDb
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb);

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Anchor-driven process requires ObjectSpec.DeleteMode = 1.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
      AND os.DeleteMode <> 1;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Row-driven process requires ObjectSpec.DeleteMode = 0.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'TIMESTAMP'
      AND e.AnchorTable IS NULL
      AND os.DeleteMode <> 0;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Delete-only mode is blocked because RequireArchiveForDelete=1 and AllowDeleteWithoutArchive=0.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND e.Mode = 0
      AND COALESCE(os.RequireArchiveForDelete, 1) = 1
      AND COALESCE(e.AllowDeleteWithoutArchive, 0) = 0;

    DECLARE
        @vProcessCode sysname,
        @vSourceDb sysname,
        @vArchiveDb sysname,
        @vMode tinyint,
        @vSourceSchema sysname,
        @vSourceTable sysname,
        @vArchiveSchema sysname,
        @vArchiveTable sysname,
        @sql nvarchar(max);

    DECLARE object_check CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            os.ProcessCode,
            os.SourceDb,
            os.ArchiveDb,
            e.Mode,
            os.SourceSchema,
            os.SourceTable,
            CONVERT(nvarchar(128), REPLACE(
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo' THEN N'{SourceDb}'
                    ELSE LTRIM(RTRIM(os.ArchiveSchema))
                END,
                N'{SourceDb}', os.SourceDb)) AS ArchiveSchema,
            COALESCE(NULLIF(os.ArchiveTable, N''), os.SourceTable)
        FROM arch.v_ObjectSpecDatabaseEffective os
        JOIN arch.v_ProcessDatabaseEffective e
          ON e.ProcessDatabaseId = os.ProcessDatabaseId
        WHERE os.ProcessDatabaseIsEnabled = 1
          AND os.ObjectIsEnabled = 1
          AND DB_ID(os.SourceDb) IS NOT NULL
          AND DB_ID(os.ArchiveDb) IS NOT NULL
          AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb);

    OPEN object_check;
    FETCH NEXT FROM object_check INTO @vProcessCode, @vSourceDb, @vArchiveDb, @vMode, @vSourceSchema, @vSourceTable, @vArchiveSchema, @vArchiveTable;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
IF NOT EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(@vSourceDb) + N'.sys.tables t
    INNER JOIN ' + QUOTENAME(@vSourceDb) + N'.sys.schemas s
        ON s.schema_id = t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @pSourceSchema COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @pSourceTable COLLATE DATABASE_DEFAULT
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    VALUES
    (
        ''ERROR'',
        @pProcessCode,
        @pSourceDb,
        @pArchiveDb,
        QUOTENAME(@pSourceSchema) + N''.'' + QUOTENAME(@pSourceTable),
        N''Configured source table does not exist.''
    );
	END;';

        IF @vMode IN (1, 2)   -- archive+delete (1) and copy-only (2) both require the archive table
        BEGIN
            SET @sql = @sql + N'

	IF NOT EXISTS
	(
	    SELECT 1
	    FROM ' + QUOTENAME(@vArchiveDb) + N'.sys.tables t
    INNER JOIN ' + QUOTENAME(@vArchiveDb) + N'.sys.schemas s
        ON s.schema_id = t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @pArchiveSchema COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @pArchiveTable COLLATE DATABASE_DEFAULT
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    VALUES
    (
        ''WARN'',
        @pProcessCode,
        @pSourceDb,
        @pArchiveDb,
        QUOTENAME(@pArchiveSchema) + N''.'' + QUOTENAME(@pArchiveTable),
	        N''Archive table does not exist yet; provision it before delete/archive runs or allow the provisioning procedure to create it.''
	    );
	END;';
        END;

        EXEC sys.sp_executesql
            @sql,
            N'@pProcessCode sysname,
              @pSourceDb sysname,
              @pArchiveDb sysname,
              @pSourceSchema sysname,
              @pSourceTable sysname,
              @pArchiveSchema sysname,
              @pArchiveTable sysname',
            @pProcessCode = @vProcessCode,
            @pSourceDb = @vSourceDb,
            @pArchiveDb = @vArchiveDb,
            @pSourceSchema = @vSourceSchema,
            @pSourceTable = @vSourceTable,
            @pArchiveSchema = @vArchiveSchema,
            @pArchiveTable = @vArchiveTable;

        FETCH NEXT FROM object_check INTO @vProcessCode, @vSourceDb, @vArchiveDb, @vMode, @vSourceSchema, @vSourceTable, @vArchiveSchema, @vArchiveTable;
    END

    CLOSE object_check;
    DEALLOCATE object_check;

    /* Concrete remediation SQL for the deterministically-fixable findings. */
    -- archive table not yet provisioned -> the exact provisioning call
    UPDATE #Findings
    SET SuggestedSql =
        N'EXEC arch.usp_ProvisionArchiveTablesForProcess @ProcessCode=N''' + REPLACE(ProcessCode, N'''', N'''''')
      + N''', @SourceDb=N''' + REPLACE(SourceDb, N'''', N'''''')
      + N''', @ArchiveDb=N''' + REPLACE(ArchiveDb, N'''', N'''''') + N''';'
    WHERE Finding LIKE N'Archive table does not exist%'
      AND ProcessCode IS NOT NULL AND SourceDb IS NOT NULL AND ArchiveDb IS NOT NULL;

    -- redundant ProcessDatabase override -> NULL out the redundant column (keeps the arch.Process default)
    UPDATE #Findings
    SET SuggestedSql =
        N'UPDATE pd SET ' + QUOTENAME(LTRIM(RTRIM(SUBSTRING(Finding,
              CHARINDEX(N'arch.ProcessDatabase: ', Finding) + 22,
              CHARINDEX(N' equals', Finding) - (CHARINDEX(N'arch.ProcessDatabase: ', Finding) + 22)))))
      + N' = NULL FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId = pd.ProcessId'
      + N' WHERE p.ProcessCode=N''' + REPLACE(ProcessCode, N'''', N'''''')
      + N''' AND pd.SourceDb=N''' + REPLACE(SourceDb, N'''', N'''''')
      + N''' AND pd.ArchiveDb=N''' + REPLACE(ArchiveDb, N'''', N'''''') + N''';'
    WHERE Finding LIKE N'Redundant database override in arch.ProcessDatabase:%'
      AND CHARINDEX(N' equals', Finding) > CHARINDEX(N'arch.ProcessDatabase: ', Finding) + 22
      AND ProcessCode IS NOT NULL AND SourceDb IS NOT NULL AND ArchiveDb IS NOT NULL;

    SELECT Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql, ActionKey
    FROM #Findings
    ORDER BY CASE Severity WHEN 'ERROR' THEN 0 ELSE 1 END, ProcessCode, SourceDb, ObjectName;

    IF EXISTS (SELECT 1 FROM #Findings WHERE Severity = 'ERROR')
        RETURN 1;

    RETURN 0;
END
GO
-- <<< end: kArchiveManagerAdmin\procedures\arch.usp_ValidateConfiguration.sql
GO
GO

-- ---- Phase 9: safe-expression validator (BEFORE the frontend save procs that call it) ----
-- >>> inlined: kArchiveManagerAdmin\v2\046_safe_expression_validator.sql
/* ============================================================================
   046 — Safe SQL-expression validator (audit task T-05)
   ============================================================================
   PROBLEM: the advanced configuration fields (AnchorTimestampExpr, AnchorExtraWhereSql,
   TimestampExpr, JoinToAnchorPredicateSql, AdditionalWhereSql, CandidateWhereSql, CandidateOrderSql,
   ProcessKeySpec.SourceExpressionSql + their *Override siblings) are concatenated verbatim into the
   dynamic DELETE/SELECT the runner executes against PRODUCTION source databases. They are gated only
   by an app role — a config author is effectively an unconstrained T-SQL author (stored second-order
   SQL injection: e.g. JoinToAnchorPredicateSql = '1=1) ; DELETE FROM ...; --').

   FIX: a reusable assertion the Save* procs call synchronously BEFORE persisting each free-text field.
   It rejects anything that is not a single scalar/boolean expression: statement terminators, comments,
   DDL/DML/exec keywords (whole-word), xp_/sp_ procedure references, and unbalanced parentheses.
   Calibrated against the live config (2026-06-03): every existing legitimate value passes
   (CAST/CONVERT/COALESCE/TRY_CONVERT/ISNULL/STUFF/REPLACE/AT TIME ZONE/... with balanced parens).

   This is defense-in-depth, not a full parser; the trust boundary remains "only advanced_admin may
   edit these", but it blocks the catastrophic vectors. THROW 50400 on rejection.
   Idempotent (CREATE OR ALTER). No data change.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE arch.usp_AssertSafeSqlExpression
    @Expression nvarchar(4000),
    @FieldName  nvarchar(128)
AS
BEGIN
    SET NOCOUNT ON;

    -- Empty/NULL is allowed here; required-ness is enforced by the calling Save proc.
    IF NULLIF(LTRIM(RTRIM(@Expression)), N'') IS NULL
        RETURN;

    DECLARE @raw nvarchar(4000) = @Expression;
    DECLARE @why nvarchar(200) = NULL;

    -- 1) Statement terminators / comment injection (raw substring checks).
    IF @raw LIKE N'%;%'                               SET @why = N'contains a statement terminator '';''';
    ELSE IF @raw LIKE N'%--%'                          SET @why = N'contains a line comment ''--''';
    ELSE IF @raw LIKE N'%/*%' OR @raw LIKE N'%*/%'     SET @why = N'contains a block comment ''/* */''';

    -- 2) Parenthesis STRUCTURE: scan left-to-right; depth must never go negative (which would mean a
    --    ')' closes the runner's wrapping "(<expr>)" early, e.g. "1=1) OR (1=1" -> always-true =
    --    over-delete) and must end at zero. (Note: parentheses inside string literals are not common
    --    in these fields and are treated literally; rewrite such a value if it trips this check.)
    IF @why IS NULL
    BEGIN
        DECLARE @i int = 1, @depth int = 0, @len int = LEN(@raw), @ch nchar(1);
        WHILE @i <= @len
        BEGIN
            SET @ch = SUBSTRING(@raw, @i, 1);
            IF @ch = N'(' SET @depth += 1;
            ELSE IF @ch = N')' SET @depth -= 1;
            IF @depth < 0 BREAK;
            SET @i += 1;
        END;
        IF @depth <> 0
            SET @why = N'has unbalanced or mis-nested parentheses';
    END;

    -- 3) Disallowed keywords (whole-word, case-insensitive) + xp_/sp_ procedure references.
    --    Punctuation is translated to spaces so keywords are matched on word boundaries; a column such
    --    as DATE_CREATE / disp_qty therefore does NOT trip CREATE / sp_.
    IF @why IS NULL
    BEGIN
        DECLARE @punct nvarchar(64) = N'()[]{}<>,.+-*/=!%&|~^@?:;`''"' + NCHAR(9) + NCHAR(10) + NCHAR(13);
        DECLARE @norm  nvarchar(max) =
            N' ' + TRANSLATE(UPPER(@raw), @punct, REPLICATE(N' ', LEN(@punct + N'.') - 1)) + N' ';

        IF     @norm LIKE N'% SELECT %'        OR @norm LIKE N'% INSERT %'
            OR @norm LIKE N'% UPDATE %'        OR @norm LIKE N'% DELETE %'
            OR @norm LIKE N'% MERGE %'         OR @norm LIKE N'% DROP %'
            OR @norm LIKE N'% CREATE %'        OR @norm LIKE N'% ALTER %'
            OR @norm LIKE N'% TRUNCATE %'      OR @norm LIKE N'% EXEC %'
            OR @norm LIKE N'% EXECUTE %'       OR @norm LIKE N'% GRANT %'
            OR @norm LIKE N'% REVOKE %'        OR @norm LIKE N'% DENY %'
            OR @norm LIKE N'% SHUTDOWN %'      OR @norm LIKE N'% WAITFOR %'
            OR @norm LIKE N'% RECONFIGURE %'   OR @norm LIKE N'% BACKUP %'
            OR @norm LIKE N'% RESTORE %'       OR @norm LIKE N'% BULK %'
            OR @norm LIKE N'% OPENROWSET %'    OR @norm LIKE N'% OPENQUERY %'
            OR @norm LIKE N'% OPENDATASOURCE %' OR @norm LIKE N'% OPENXML %'
            OR @norm LIKE N'% XP[_]%'          OR @norm LIKE N'% SP[_]%'
            SET @why = N'contains a disallowed SQL keyword or procedure reference';
    END;

    IF @why IS NOT NULL
    BEGIN
        DECLARE @msg nvarchar(1000) =
            N'Unsafe SQL in advanced configuration field [' + @FieldName + N']: ' + @why
          + N'. It must be a single scalar/boolean expression — no statements, comments, DDL/DML keywords, or procedure calls.';
        ;THROW 50400, @msg, 1;
    END;
END;
GO

PRINT '046_safe_expression_validator deployed (arch.usp_AssertSafeSqlExpression).';
GO
-- <<< end: kArchiveManagerAdmin\v2\046_safe_expression_validator.sql
GO
GO

-- ---- Phase 10: runner chain + gates (035 TZ gate BEFORE 015/027 which call it) ----
-- >>> inlined: kArchiveManagerAdmin\v2\035_usp_AssertTimezonePolicyApplied.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/**
 * ============================================================================
 * 035_usp_AssertTimezonePolicyApplied.sql
 * ============================================================================
 *
 * Purpose:
 *   Defense-in-depth runtime gate for P0.5 Risk K1 (timezone cutoff).
 *   Blocks real DELETE operations when the cutoff timestamp expression that
 *   governs candidate selection is NOT UTC-normalized via AT TIME ZONE.
 *
 * Where it is called:
 *   - arch.usp_RunPreparedBatch  (ANCHOR delete path)    -> checks AnchorTimestampExpr
 *   - arch.usp_RunTimestampProcess (TIMESTAMP delete path) -> checks ObjectSpec.TimestampExpr
 *   Both call this only on the REAL run (@DryRun = 0), so dry-run / candidate
 *   preview keep working even before the timezone policy is applied.
 *
 * Convention:
 *   Even genuinely-UTC sources must wrap their expression with
 *   AT TIME ZONE 'UTC' to explicitly signal that timezone has been addressed.
 *   This keeps the gate a simple, low-false-positive presence check while
 *   forcing a conscious decision per source.
 *
 * Error code:
 *   THROW 50200 — distinct from P1.3's 50001-50006 (RunProfile validation /
 *   legacy blocks) and usp_RunTimestampProcess's 50100-50109, so operators get
 *   an unambiguous signal. (The original policy sketch said 50001, which was
 *   already taken by P1.3.)
 *
 * Created: 2026-05-29
 * Related: v2/031 (ObjectSpec.TimestampExpr), v2/034 (AnchorTimestampExpr),
 *          docs/production-timezone-cutoff-policy.md
 * ============================================================================
 */
CREATE OR ALTER PROCEDURE [arch].[usp_AssertTimezonePolicyApplied]
    @ProcessId int,
    @SourceDb  sysname,
    @ArchiveDb sysname
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @SelectionStrategy nvarchar(30),
        @AnchorTimestampExpr nvarchar(4000),
        @ProcessCode sysname,
        @offenders nvarchar(max),
        @msg nvarchar(2048);

    SELECT TOP (1)
        @SelectionStrategy = COALESCE(e.SelectionStrategy, N'ANCHOR'),
        @AnchorTimestampExpr = e.AnchorTimestampExpr,
        @ProcessCode = e.ProcessCode
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessId = @ProcessId
      AND e.SourceDb = @SourceDb
      AND e.ArchiveDb = @ArchiveDb
      AND e.IsEnabled = 1;

    -- Nothing enabled to guard; upstream procedures already validate existence.
    IF @ProcessCode IS NULL
        RETURN;

    IF @SelectionStrategy = N'ANCHOR'
    BEGIN
        IF @AnchorTimestampExpr IS NOT NULL
           AND @AnchorTimestampExpr NOT LIKE N'%AT TIME ZONE%'
        BEGIN
            SET @msg =
                N'Timezone policy not applied (P0.5 Risk K1): AnchorTimestampExpr for process '''
                + @ProcessCode + N''' on source ''' + @SourceDb
                + N''' is not UTC-normalized: ''' + LEFT(@AnchorTimestampExpr, 180)
                + N'''. Wrap it with AT TIME ZONE before running real deletes. Delete blocked.';
            THROW 50200, @msg, 1;
        END;
    END
    ELSE IF @SelectionStrategy = N'TIMESTAMP'
    BEGIN
        SELECT @offenders =
            STRING_AGG(CONVERT(nvarchar(max), e.SourceSchema + N'.' + e.SourceTable), N', ')
        FROM arch.v_ObjectSpecDatabaseEffective e
        WHERE e.ProcessId = @ProcessId
          AND e.SourceDb = @SourceDb
          AND e.ArchiveDb = @ArchiveDb
          AND e.ObjectIsEnabled = 1
          AND e.TimestampExpr IS NOT NULL
          AND e.TimestampExpr NOT LIKE N'%AT TIME ZONE%';

        IF @offenders IS NOT NULL
        BEGIN
            SET @msg =
                N'Timezone policy not applied (P0.5 Risk K1): TimestampExpr for process '''
                + @ProcessCode + N''' on source ''' + @SourceDb
                + N''' is not UTC-normalized on: ' + @offenders
                + N'. Wrap each with AT TIME ZONE before running real deletes. Delete blocked.';
            THROW 50200, @msg, 1;
        END;
    END;
END
GO
-- <<< end: kArchiveManagerAdmin\v2\035_usp_AssertTimezonePolicyApplied.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\011_usp_ValidateIndexRequirements.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_ValidateIndexRequirements]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Findings
    (
        Severity varchar(10) NOT NULL,
        ProcessCode sysname NOT NULL,
        SourceDb sysname NULL,
        ObjectName nvarchar(300) NOT NULL,
        RequirementType nvarchar(20) NOT NULL,
        KeyColumnsCsv nvarchar(1000) NOT NULL,
        Finding nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL   -- concrete remediation DDL the operator can copy/run
    );

    IF OBJECT_ID(N'arch.IndexRequirement', N'U') IS NULL
    BEGIN
        INSERT #Findings(Severity, ProcessCode, ObjectName, RequirementType, KeyColumnsCsv, Finding)
        VALUES
        (
            'ERROR',
            COALESCE(@ProcessCode, N'*'),
            N'arch.IndexRequirement',
            N'METADATA',
            N'',
            N'arch.IndexRequirement does not exist. Run v2/010_universal_archive_core.sql first.'
        );

        SELECT Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding
        FROM #Findings;

        RETURN 1;
    END;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding)
    SELECT
        CASE WHEN ir.IsMandatory = 1 THEN 'ERROR' ELSE 'WARN' END,
        p.ProcessCode,
        e.SourceDb,
        QUOTENAME(COALESCE(os.SourceSchema, ir.SourceSchema)) + N'.' + QUOTENAME(COALESCE(os.SourceTable, ir.SourceTable)),
        ir.RequirementType,
        ir.KeyColumnsCsv,
        N'Index requirement has an empty KeyColumnsCsv.'
    FROM arch.IndexRequirement ir
    JOIN arch.Process p
      ON p.ProcessId = ir.ProcessId
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessId = p.ProcessId
    LEFT JOIN arch.v_ObjectSpecDatabaseEffective os
      ON os.ProcessDatabaseId = e.ProcessDatabaseId
     AND os.ObjectSpecId = ir.ObjectSpecId
     AND os.ObjectIsEnabled = 1
    WHERE (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND e.IsEnabled = 1
      AND (ir.ObjectSpecId IS NULL OR os.ObjectSpecId IS NOT NULL)
      AND NULLIF(LTRIM(RTRIM(ir.KeyColumnsCsv)), N'') IS NULL;

    DECLARE
        @p sysname,
        @src sysname,
        @schema sysname,
        @table sysname,
        @rtype nvarchar(20),
        @keys nvarchar(1000),
        @mandatory bit,
        @sql nvarchar(max);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT
            p.ProcessCode,
            e.SourceDb,
            COALESCE(os.SourceSchema, ir.SourceSchema) AS SourceSchema,
            COALESCE(os.SourceTable, ir.SourceTable) AS SourceTable,
            ir.RequirementType,
            ir.KeyColumnsCsv,
            ir.IsMandatory
        FROM arch.IndexRequirement ir
        JOIN arch.Process p
          ON p.ProcessId = ir.ProcessId
        JOIN arch.v_ProcessDatabaseEffective e
          ON e.ProcessId = p.ProcessId
        LEFT JOIN arch.v_ObjectSpecDatabaseEffective os
          ON os.ProcessDatabaseId = e.ProcessDatabaseId
         AND os.ObjectSpecId = ir.ObjectSpecId
         AND os.ObjectIsEnabled = 1
        WHERE e.IsEnabled = 1
          AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
          AND DB_ID(e.SourceDb) IS NOT NULL
          AND (ir.ObjectSpecId IS NULL OR os.ObjectSpecId IS NOT NULL)
          AND NULLIF(LTRIM(RTRIM(ir.KeyColumnsCsv)), N'') IS NOT NULL;

    OPEN c;
    FETCH NEXT FROM c INTO @p, @src, @schema, @table, @rtype, @keys, @mandatory;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        CREATE TABLE #RequiredColumns
        (
            ColumnName sysname NOT NULL PRIMARY KEY
        );

        DECLARE @xml xml = TRY_CAST(N'<x><v>' + REPLACE(REPLACE(REPLACE(@keys, N'&', N'&amp;'), N'<', N'&lt;'), N',', N'</v><v>') + N'</v></x>' AS xml);

        IF @xml IS NOT NULL
        BEGIN
            INSERT #RequiredColumns(ColumnName)
            SELECT DISTINCT
                CONVERT(sysname, REPLACE(REPLACE(LTRIM(RTRIM(T.C.value(N'.', N'nvarchar(256)'))), N'[', N''), N']', N''))
            FROM @xml.nodes(N'/x/v') AS T(C)
            WHERE NULLIF(LTRIM(RTRIM(T.C.value(N'.', N'nvarchar(256)'))), N'') IS NOT NULL;
        END;

        IF NOT EXISTS (SELECT 1 FROM #RequiredColumns)
        BEGIN
            INSERT #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding)
            VALUES
            (
                CASE WHEN @mandatory = 1 THEN 'ERROR' ELSE 'WARN' END,
                @p,
                @src,
                QUOTENAME(@schema) + N'.' + QUOTENAME(@table),
                @rtype,
                @keys,
                N'Index requirement did not parse into any required columns.'
            );

            DROP TABLE #RequiredColumns;

            FETCH NEXT FROM c INTO @p, @src, @schema, @table, @rtype, @keys, @mandatory;
            CONTINUE;
        END;

        SET @sql = N'
IF NOT EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(@src) + N'.sys.tables t
    JOIN ' + QUOTENAME(@src) + N'.sys.schemas s
      ON s.schema_id = t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @pSchema COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @pTable COLLATE DATABASE_DEFAULT
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding)
    VALUES
    (
        CASE WHEN @pMandatory = 1 THEN ''ERROR'' ELSE ''WARN'' END,
        @pProcessCode,
        @pSourceDb,
        QUOTENAME(@pSchema) + N''.'' + QUOTENAME(@pTable),
        @pRequirementType,
        @pKeyColumnsCsv,
        N''Source table for index requirement does not exist.''
    );
END
ELSE IF EXISTS
(
    SELECT rc.ColumnName
    FROM #RequiredColumns rc
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM ' + QUOTENAME(@src) + N'.sys.columns c
        JOIN ' + QUOTENAME(@src) + N'.sys.tables t
          ON t.object_id = c.object_id
        JOIN ' + QUOTENAME(@src) + N'.sys.schemas s
          ON s.schema_id = t.schema_id
        WHERE s.name COLLATE DATABASE_DEFAULT = @pSchema COLLATE DATABASE_DEFAULT
          AND t.name COLLATE DATABASE_DEFAULT = @pTable COLLATE DATABASE_DEFAULT
          AND c.name COLLATE DATABASE_DEFAULT = rc.ColumnName COLLATE DATABASE_DEFAULT
    )
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding)
    VALUES
    (
        CASE WHEN @pMandatory = 1 THEN ''ERROR'' ELSE ''WARN'' END,
        @pProcessCode,
        @pSourceDb,
        QUOTENAME(@pSchema) + N''.'' + QUOTENAME(@pTable),
        @pRequirementType,
        @pKeyColumnsCsv,
        N''At least one required index column does not exist on the source table.''
    );
END
ELSE IF NOT EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(@src) + N'.sys.indexes i
    JOIN ' + QUOTENAME(@src) + N'.sys.tables t
      ON t.object_id = i.object_id
    JOIN ' + QUOTENAME(@src) + N'.sys.schemas s
      ON s.schema_id = t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @pSchema COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @pTable COLLATE DATABASE_DEFAULT
      AND i.is_disabled = 0
      AND NOT EXISTS
      (
          SELECT 1
          FROM #RequiredColumns rc
          WHERE NOT EXISTS
          (
              SELECT 1
              FROM ' + QUOTENAME(@src) + N'.sys.index_columns ic
              JOIN ' + QUOTENAME(@src) + N'.sys.columns c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.is_included_column = 0
                AND c.name COLLATE DATABASE_DEFAULT = rc.ColumnName COLLATE DATABASE_DEFAULT
          )
      )
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding)
    VALUES
    (
        ''WARN'',   /* A missing supporting index must NEVER block processing - always WARN, never ERROR.
                       The operator can create it from Admin Console -> Validation -> Indexes (Suggested SQL). */
        @pProcessCode,
        @pSourceDb,
        QUOTENAME(@pSchema) + N''.'' + QUOTENAME(@pTable),
        @pRequirementType,
        @pKeyColumnsCsv,
        N''No enabled source index contains all required key columns as key columns. Processing is NOT blocked; create the index from the Suggested SQL for seek quality.''
    );
END;';

        EXEC sys.sp_executesql
            @sql,
            N'@pProcessCode sysname,
              @pSourceDb sysname,
              @pSchema sysname,
              @pTable sysname,
              @pRequirementType nvarchar(20),
              @pKeyColumnsCsv nvarchar(1000),
              @pMandatory bit',
            @pProcessCode = @p,
            @pSourceDb = @src,
            @pSchema = @schema,
            @pTable = @table,
            @pRequirementType = @rtype,
            @pKeyColumnsCsv = @keys,
            @pMandatory = @mandatory;

        DROP TABLE #RequiredColumns;

        FETCH NEXT FROM c INTO @p, @src, @schema, @table, @rtype, @keys, @mandatory;
    END

    CLOSE c;
    DEALLOCATE c;

    /* Concrete remediation SQL. Missing supporting index -> the exact CREATE INDEX (key columns in the
       declared order, bracketed). Note: column-order/seek quality still warrants a manual review; this is
       a ready-to-run starting point. KeyColumnsCsv order is preserved by string-splitting (no STRING_SPLIT
       ordinal, so it stays portable to SQL 2019). */
    UPDATE #Findings
    SET SuggestedSql =
        N'USE ' + QUOTENAME(SourceDb) + N'; CREATE NONCLUSTERED INDEX '
      + QUOTENAME(LEFT(N'IX_kAM_' + RequirementType + N'_' + REPLACE(REPLACE(REPLACE(ObjectName, N'[', N''), N']', N''), N'.', N'_'), 116))
      + N' ON ' + ObjectName + N' ([' + REPLACE(REPLACE(KeyColumnsCsv, N' ', N''), N',', N'],[') + N']);'
    WHERE Finding LIKE N'No enabled source index%'
      AND SourceDb IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(KeyColumnsCsv)), N'') IS NOT NULL;

    UPDATE #Findings
    SET SuggestedSql = N'-- ' + Finding + N' (fix the source schema or correct arch.IndexRequirement for ' + ObjectName + N')'
    WHERE SuggestedSql IS NULL
      AND (Finding LIKE N'Source table%' OR Finding LIKE N'At least one required index column%');

    SELECT Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding, SuggestedSql
    FROM #Findings
    ORDER BY CASE Severity WHEN 'ERROR' THEN 0 ELSE 1 END, ProcessCode, SourceDb, ObjectName, RequirementType;

    IF EXISTS (SELECT 1 FROM #Findings WHERE Severity = 'ERROR')
        RETURN 1;

    RETURN 0;
END
GO
-- <<< end: kArchiveManagerAdmin\v2\011_usp_ValidateIndexRequirements.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\012_usp_ExplainProcessPlan.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_ExplainProcessPlan]
    @ProcessCode sysname,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID(N'arch.IndexRequirement', N'U') IS NULL
    BEGIN
        RAISERROR(N'2.0 metadata is not installed. Run v2/010_universal_archive_core.sql first.', 16, 1);
        RETURN;
    END;

    SELECT
        p.ProcessCode,
        p.Description,
        p.IsEnabled,
        p.Mode,
        ModeName = CASE p.Mode WHEN 1 THEN N'ARCHIVE_DELETE' ELSE N'DELETE_ONLY' END,
        SelectionStrategy = COALESCE(p.SelectionStrategy, N'ANCHOR'),
        p.RetentionDays,
        p.CutoffSafetyLagMinutes,
        p.BatchDocCount,
        p.BatchRowCount,
        p.MaxBatchesPerRun,
        p.MaxRowsPerTransaction,
        p.AuditLevel,
        p.RequireSupportingIndex,
        p.AnchorSchema,
        p.AnchorTable,
        p.AnchorDocKeyExpr,
        p.AnchorDocKey2Expr,
        p.AnchorTimestampExpr,
        p.CandidateWhereSql,
        p.CandidateOrderSql
    FROM arch.Process p
    WHERE p.ProcessCode = @ProcessCode;

    SELECT
        e.ProcessDatabaseId,
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        e.IsEnabled,
        e.RunOrder,
        e.Mode,
        e.ModeSource,
        e.RetentionDays,
        e.RetentionDaysSource,
        e.CutoffSafetyLagMinutes,
        e.CutoffSafetyLagMinutesSource,
        e.CutoffMode,
        e.CutoffModeSource,
        e.CutoffDate,
        e.CutoffDateSource,
        e.BatchDocCount,
        e.BatchDocCountSource,
        e.BatchRowCount,
        e.BatchRowCountSource,
        e.MaxBatchesPerRun,
        e.MaxBatchesPerRunSource,
        e.MaxRowsPerTransaction,
        e.MaxRowsPerTransactionSource,
        e.AuditLevel,
        e.AuditLevelSource,
        e.AnchorSchema,
        e.AnchorSchemaSource,
        e.AnchorTable,
        e.AnchorTableSource,
        e.AnchorTimestampExpr,
        e.AnchorTimestampExprSource,
        e.CandidateWhereSql,
        e.CandidateWhereSqlSource,
        e.CandidateOrderSql,
        e.CandidateOrderSqlSource
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessCode = @ProcessCode
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
    ORDER BY e.RunOrder, e.SourceDb, e.ArchiveDb;

    SELECT
        os.ProcessCode,
        os.ObjectSpecId,
        ObjectName = QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        os.DeleteOrder,
        os.DeleteMode,
        os.TimestampExpr,
        os.TimestampExprSource,
        os.JoinToAnchorPredicateSql,
        os.JoinToAnchorPredicateSqlSource,
        os.AdditionalWhereSql,
        os.AdditionalWhereSqlSource,
        ArchiveObjectName =
            QUOTENAME(CONVERT(nvarchar(128), REPLACE(
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo' THEN N'{SourceDb}'
                    ELSE LTRIM(RTRIM(os.ArchiveSchema))
                END,
                N'{SourceDb}', COALESCE(@SourceDb, N'{SourceDb}'))))
            + N'.' + QUOTENAME(COALESCE(os.ArchiveTable, os.SourceTable)),
        os.ArchiveSchemaSource,
        os.ArchiveTableSource,
        os.RequireArchiveForDelete,
        os.RequireArchiveForDeleteSource,
        os.NaturalKeyLabel,
        os.CandidateSelectExpr
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessCode = @ProcessCode
      AND os.ObjectIsEnabled = 1
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
    ORDER BY os.SourceDb, os.DeleteOrder, os.ObjectSpecId;

    SELECT
        p.ProcessCode,
        pks.KeyOrdinal,
        pks.KeyName,
        pks.SourceExpressionSql,
        pks.SqlType,
        pks.IsRequired
    FROM arch.ProcessKeySpec pks
    JOIN arch.Process p
      ON p.ProcessId = pks.ProcessId
    WHERE p.ProcessCode = @ProcessCode
    ORDER BY pks.KeyOrdinal;

    SELECT
        p.ProcessCode,
        ir.RequirementType,
        ObjectName = QUOTENAME(ir.SourceSchema) + N'.' + QUOTENAME(ir.SourceTable),
        ir.KeyColumnsCsv,
        ir.IncludeColumnsCsv,
        ir.FilterSql,
        ir.IsMandatory,
        ir.Notes
    FROM arch.IndexRequirement ir
    JOIN arch.Process p
      ON p.ProcessId = ir.ProcessId
    WHERE p.ProcessCode = @ProcessCode
    ORDER BY ir.RequirementType, ir.SourceSchema, ir.SourceTable, ir.IndexRequirementId;

    SELECT
        FindingType = N'NEXT_STEP',
        Finding = N'Run EXEC arch.usp_ValidateConfiguration @ProcessCode = @ProcessCode, @SourceDb = @SourceDb before dry-run.'
    UNION ALL
    SELECT
        N'NEXT_STEP',
        N'Run EXEC arch.usp_ValidateIndexRequirements @ProcessCode = @ProcessCode, @SourceDb = @SourceDb before delete/archive mode.'
    UNION ALL
    SELECT
        N'PERFORMANCE',
        N'Review actual execution plans for candidate selection and source deletes on customer data volume.';
END
GO
-- <<< end: kArchiveManagerAdmin\v2\012_usp_ExplainProcessPlan.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\014_usp_PrepareCandidates.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_PrepareCandidates]
    @ProcessCode sysname,
    @SourceDb sysname,
    @ArchiveDb sysname,
    @FromUtc datetime2(0) = NULL,
    @ToUtc datetime2(0) = NULL,
    @MaxCandidates int = NULL,
    @WorkBatchId bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
    BEGIN
        RAISERROR(N'2.0 metadata is not installed. Run v2/010_universal_archive_core.sql first.', 16, 1);
        RETURN;
    END;

    DECLARE
        @ProcessId int,
        @ProcessDatabaseId int,
        @Mode tinyint,
        @SelectionStrategy nvarchar(30),
        @AuditLevel nvarchar(20),
        @RetentionDays int,
        @LagMin int,
        @BatchDocCount int,
        @BatchRowCount int,
        @MaxBatches int,
        @UseAppLock bit,
        @AppLockResource nvarchar(200),
        @LockTimeoutMs int,
        @CutoffMode tinyint,
        @CutoffDate datetime2(0),
        @AnchorSchema sysname,
        @AnchorTable sysname,
        @AnchorTimestampExpr nvarchar(4000),
        @AnchorExtraWhereSql nvarchar(4000),
        @CandidateSourceSchema sysname,
        @CandidateSourceTable sysname,
        @CandidateTimestampExpr nvarchar(4000),
        @CandidateAdditionalWhereSql nvarchar(4000),
        @CandidateWhereSql nvarchar(4000),
        @CandidateOrderSql nvarchar(4000);

    SET @WorkBatchId = NULL;

    SELECT
        @ProcessDatabaseId = e.ProcessDatabaseId,
        @ProcessId = e.ProcessId,
        @Mode = e.Mode,
        @SelectionStrategy = COALESCE(e.SelectionStrategy, N'ANCHOR'),
        @AuditLevel = COALESCE(e.AuditLevel, N'BATCH'),
        @RetentionDays = e.RetentionDays,
        @LagMin = e.CutoffSafetyLagMinutes,
        @BatchDocCount = e.BatchDocCount,
        @BatchRowCount = e.BatchRowCount,
        @MaxBatches = e.MaxBatchesPerRun,
        @UseAppLock = e.UseAppLock,
        @AppLockResource = COALESCE(NULLIF(e.AppLockResource, N''), N'KARCHIVE_MANAGER:' + e.ProcessCode + N':' + @SourceDb),
        @LockTimeoutMs = COALESCE(e.LockTimeoutMs, 10000),
        @CutoffMode = e.CutoffMode,
        @CutoffDate = e.CutoffDate,
        @AnchorSchema = e.AnchorSchema,
        @AnchorTable = e.AnchorTable,
        @AnchorTimestampExpr = e.AnchorTimestampExpr,
        @AnchorExtraWhereSql = e.AnchorExtraWhereSql,
        @CandidateWhereSql = e.CandidateWhereSql,
        @CandidateOrderSql = e.CandidateOrderSql
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessCode = @ProcessCode
      AND e.SourceDb = @SourceDb
      AND e.ArchiveDb = @ArchiveDb
      AND e.IsEnabled = 1;

    IF @ProcessId IS NULL
    BEGIN
        RAISERROR(N'Process not found or disabled: %s', 16, 1, @ProcessCode);
        RETURN;
    END;

    IF @SelectionStrategy NOT IN (N'ANCHOR', N'TIMESTAMP')
    BEGIN
        RAISERROR(N'arch.usp_PrepareCandidates currently implements ANCHOR and TIMESTAMP only. Process %s uses %s.', 16, 1, @ProcessCode, @SelectionStrategy);
        RETURN;
    END;

    IF @SelectionStrategy = N'TIMESTAMP'
       AND @AuditLevel = N'BATCH'
    BEGIN
        RAISERROR(N'TIMESTAMP/BATCH process %s runs through arch.usp_RunProcess_TimestampKeyset and does not prepare detailed WorkBatchKey rows.', 16, 1, @ProcessCode);
        RETURN;
    END;

    IF @SelectionStrategy = N'ANCHOR'
       AND (@AnchorSchema IS NULL OR @AnchorTable IS NULL OR NULLIF(LTRIM(RTRIM(@AnchorTimestampExpr)), N'') IS NULL)
    BEGIN
        RAISERROR(N'ANCHOR process has incomplete anchor configuration: %s', 16, 1, @ProcessCode);
        RETURN;
    END;

    IF @SelectionStrategy = N'TIMESTAMP'
    BEGIN
        SELECT TOP (1)
            @CandidateSourceSchema = os.SourceSchema,
            @CandidateSourceTable = os.SourceTable,
            @CandidateTimestampExpr = os.TimestampExpr,
            @CandidateAdditionalWhereSql = os.AdditionalWhereSql
        FROM arch.v_ObjectSpecDatabaseEffective os
        WHERE os.ProcessDatabaseId = @ProcessDatabaseId
          AND os.ObjectIsEnabled = 1
        ORDER BY os.DeleteOrder, os.ObjectSpecId;

        IF @CandidateSourceSchema IS NULL
           OR @CandidateSourceTable IS NULL
           OR NULLIF(LTRIM(RTRIM(@CandidateTimestampExpr)), N'') IS NULL
        BEGIN
            RAISERROR(N'TIMESTAMP process has incomplete ObjectSpec timestamp configuration: %s', 16, 1, @ProcessCode);
            RETURN;
        END;
    END;

    IF DB_ID(@SourceDb) IS NULL
    BEGIN
        RAISERROR(N'Source database does not exist: %s', 16, 1, @SourceDb);
        RETURN;
    END;

    IF DB_ID(@ArchiveDb) IS NULL
    BEGIN
        RAISERROR(N'Archive database does not exist: %s', 16, 1, @ArchiveDb);
        RETURN;
    END;

    SET @BatchDocCount = COALESCE(@BatchDocCount, 25);
    SET @BatchRowCount = COALESCE(@BatchRowCount, @BatchDocCount);
    SET @MaxBatches = COALESCE(@MaxBatches, 50);
    SET @MaxCandidates = COALESCE(
        @MaxCandidates,
        CASE
            WHEN @SelectionStrategy = N'TIMESTAMP' THEN @BatchRowCount * @MaxBatches
            ELSE @BatchDocCount * @MaxBatches
        END
    );
    SET @LagMin = COALESCE(@LagMin, 0);

    IF @MaxCandidates IS NULL OR @MaxCandidates <= 0
    BEGIN
        RAISERROR(N'@MaxCandidates must be greater than zero.', 16, 1);
        RETURN;
    END;

    SET @FromUtc = COALESCE(@FromUtc, CONVERT(datetime2(0), '19000101'));

    IF @ToUtc IS NULL
    BEGIN
        IF @CutoffMode = 1 AND @CutoffDate IS NOT NULL
            SET @ToUtc = @CutoffDate;
        ELSE
            SET @ToUtc = DATEADD(MINUTE, -@LagMin, DATEADD(DAY, -COALESCE(@RetentionDays, 0), CONVERT(datetime2(0), SYSUTCDATETIME())));
    END;

    IF @ToUtc <= @FromUtc
    BEGIN
        RAISERROR(N'Invalid candidate range: @FromUtc must be lower than @ToUtc.', 16, 1);
        RETURN;
    END;

    -- T-21 retention floor: refuse to PREPARE when the cutoff is inside the policy floor, so ANCHOR never
    -- builds a WorkBatch that 015 would only refuse (which would wedge re-prepare). A floor-violating config
    -- is refused here (fix the cutoff/floor first). Guarded for graceful degradation when 056 is absent. THROW 50210.
    IF OBJECT_ID(N'arch.usp_AssertRetentionFloor', N'P') IS NOT NULL
        EXEC arch.usp_AssertRetentionFloor @ProcessId = @ProcessId, @SourceDb = @SourceDb, @ArchiveDb = @ArchiveDb, @CutoffUtc = @ToUtc;

    DECLARE @OpenBatchId bigint;

    SELECT TOP (1) @OpenBatchId = wb.WorkBatchId
    FROM arch.WorkBatch wb
    WHERE wb.ProcessId = @ProcessId
      AND wb.SourceDb = @SourceDb
      AND wb.ArchiveDb = @ArchiveDb
      AND wb.Status IN ('Prepared','Running','Paused')
    ORDER BY wb.WorkBatchId;

    IF @OpenBatchId IS NOT NULL
    BEGIN
        RAISERROR(N'Candidate preparation blocked: open WorkBatch already exists (WorkBatchId=%I64d).', 16, 1, @OpenBatchId);
        RETURN;
    END;

    DECLARE @KeyExpr table
    (
        KeyOrdinal tinyint NOT NULL PRIMARY KEY,
        SourceExpressionSql nvarchar(4000) NOT NULL
    );

    INSERT @KeyExpr(KeyOrdinal, SourceExpressionSql)
    SELECT KeyOrdinal, SourceExpressionSql
    FROM arch.ProcessKeySpec
    WHERE ProcessId = @ProcessId
    ORDER BY KeyOrdinal;

    IF NOT EXISTS (SELECT 1 FROM @KeyExpr WHERE KeyOrdinal = 1)
    BEGIN
        RAISERROR(N'ANCHOR process requires at least ProcessKeySpec KeyOrdinal=1.', 16, 1);
        RETURN;
    END;

    DECLARE
        @SelectKeys nvarchar(max) = N'',
        @InsertColumns nvarchar(max) = N'',
        @OutputKeys nvarchar(max) = N'',
        @PartitionKeys nvarchar(max) = N'',
        @OrderKeys nvarchar(max) = N'',
        @HashInput nvarchar(max) = N'',
        @i int = 1,
        @expr nvarchar(4000);

    WHILE @i <= 8
    BEGIN
        SELECT @expr = SourceExpressionSql
        FROM @KeyExpr
        WHERE KeyOrdinal = @i;

        SET @SelectKeys = @SelectKeys
            + CASE WHEN @SelectKeys = N'' THEN N'' ELSE N',' + CHAR(10) END
            + N'            Key' + CONVERT(nvarchar(10), @i) + N' = '
            + CASE
                  WHEN @expr IS NULL THEN N'N'''''
                  ELSE N'CONVERT(nvarchar(256), ' + @expr + N')'
              END;

        SET @InsertColumns = @InsertColumns
            + CASE WHEN @InsertColumns = N'' THEN N'' ELSE N', ' END
            + N'Key' + CONVERT(nvarchar(10), @i);

        SET @OutputKeys = @OutputKeys
            + CASE WHEN @OutputKeys = N'' THEN N'' ELSE N', ' END
            + N'Key' + CONVERT(nvarchar(10), @i);

        SET @PartitionKeys = @PartitionKeys
            + CASE WHEN @PartitionKeys = N'' THEN N'' ELSE N', ' END
            + N'Key' + CONVERT(nvarchar(10), @i);

        SET @OrderKeys = @OrderKeys
            + CASE WHEN @OrderKeys = N'' THEN N'' ELSE N', ' END
            + N'Key' + CONVERT(nvarchar(10), @i);

        SET @HashInput = @HashInput
            + CASE WHEN @HashInput = N'' THEN N'' ELSE N', N''|'', ' END
            + N'ISNULL(Key' + CONVERT(nvarchar(10), @i) + N', N'''')';

        SET @i = @i + 1;
        SET @expr = NULL;
    END;

    IF NULLIF(LTRIM(RTRIM(@CandidateOrderSql)), N'') IS NOT NULL
        SET @OrderKeys = @CandidateOrderSql;
    ELSE
        SET @OrderKeys = N'DocCreatedAt, ' + @OrderKeys;

    DECLARE @Key1Expr nvarchar(4000);

    SELECT @Key1Expr = SourceExpressionSql
    FROM @KeyExpr
    WHERE KeyOrdinal = 1;

    -- T-05 runtime re-assert (audit hardening): the Save* API procs validate these fragments at SAVE
    -- time, but a direct DBA write to arch.Process/ProcessKeySpec/ObjectSpec bypasses the API. Re-assert
    -- every config-sourced fragment here before it is concatenated into the candidate-scan dynamic SQL.
    -- OBJECT_ID-guarded for graceful degradation. THROW 50400.
    IF OBJECT_ID(N'arch.usp_AssertSafeSqlExpression', N'P') IS NOT NULL
    BEGIN
        EXEC arch.usp_AssertSafeSqlExpression @AnchorTimestampExpr, N'AnchorTimestampExpr';
        EXEC arch.usp_AssertSafeSqlExpression @AnchorExtraWhereSql, N'AnchorExtraWhereSql';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateTimestampExpr, N'ObjectSpec.TimestampExpr';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateAdditionalWhereSql, N'ObjectSpec.AdditionalWhereSql';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateWhereSql, N'CandidateWhereSql';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateOrderSql, N'CandidateOrderSql';

        DECLARE @vKeyExpr nvarchar(4000), @vKeyOrd int;
        DECLARE cValKeys CURSOR LOCAL FAST_FORWARD FOR
            SELECT KeyOrdinal, SourceExpressionSql FROM @KeyExpr;
        OPEN cValKeys;
        FETCH NEXT FROM cValKeys INTO @vKeyOrd, @vKeyExpr;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @vKeyField nvarchar(128) = N'ProcessKeySpec.SourceExpressionSql (KeyOrdinal=' + CONVERT(nvarchar(10), @vKeyOrd) + N')';
            EXEC arch.usp_AssertSafeSqlExpression @vKeyExpr, @vKeyField;
            FETCH NEXT FROM cValKeys INTO @vKeyOrd, @vKeyExpr;
        END;
        CLOSE cValKeys;
        DEALLOCATE cValKeys;
    END;

    CREATE TABLE #Candidates
    (
        Key1 nvarchar(256) NOT NULL,
        Key2 nvarchar(256) NOT NULL,
        Key3 nvarchar(256) NOT NULL,
        Key4 nvarchar(256) NOT NULL,
        Key5 nvarchar(256) NOT NULL,
        Key6 nvarchar(256) NOT NULL,
        Key7 nvarchar(256) NOT NULL,
        Key8 nvarchar(256) NOT NULL,
        DocCreatedAt datetime2(0) NULL,
        CandidateHash varbinary(32) NULL
    );

    DECLARE @lres int;
    DECLARE @AppLockTaken bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lres = sys.sp_getapplock
            @Resource = @AppLockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Session',
            @LockTimeout = @LockTimeoutMs;

        IF @lres < 0
        BEGIN
            RAISERROR(N'Candidate preparation failed to acquire applock: %s', 16, 1, @AppLockResource);
            RETURN;
        END;

        SET @AppLockTaken = 1;
    END;

    BEGIN TRY
        DECLARE
            @SourceSchema sysname,
            @SourceTable sysname,
            @TimestampExpr nvarchar(4000),
            @StrategyWhereSql nvarchar(max);

        IF @SelectionStrategy = N'ANCHOR'
        BEGIN
            SET @SourceSchema = @AnchorSchema;
            SET @SourceTable = @AnchorTable;
            SET @TimestampExpr = @AnchorTimestampExpr;
            SET @StrategyWhereSql =
                N'                AND CONVERT(nvarchar(256), ' + @Key1Expr + N') IS NOT NULL
                AND LTRIM(RTRIM(CONVERT(nvarchar(256), ' + @Key1Expr + N'))) <> N''''';

            IF NULLIF(LTRIM(RTRIM(@AnchorExtraWhereSql)), N'') IS NOT NULL
                SET @StrategyWhereSql = @StrategyWhereSql + N'
                AND (' + @AnchorExtraWhereSql + N')';
        END
        ELSE
        BEGIN
            SET @SourceSchema = @CandidateSourceSchema;
            SET @SourceTable = @CandidateSourceTable;
            SET @TimestampExpr = @CandidateTimestampExpr;
            SET @StrategyWhereSql =
                N'                AND CONVERT(nvarchar(256), ' + @Key1Expr + N') IS NOT NULL
                AND LTRIM(RTRIM(CONVERT(nvarchar(256), ' + @Key1Expr + N'))) <> N''''';

            IF NULLIF(LTRIM(RTRIM(@CandidateAdditionalWhereSql)), N'') IS NOT NULL
                SET @StrategyWhereSql = @StrategyWhereSql + N'
                AND (' + @CandidateAdditionalWhereSql + N')';
        END;

        IF NULLIF(LTRIM(RTRIM(@CandidateWhereSql)), N'') IS NOT NULL
            SET @StrategyWhereSql = @StrategyWhereSql + N'
                AND (' + @CandidateWhereSql + N')';

        DECLARE @sql nvarchar(max) =
        N';WITH raw AS
          (
              SELECT
' + @SelectKeys + N',
                  DocCreatedAt = CONVERT(datetime2(0), ' + @TimestampExpr + N')
              FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@SourceSchema) + N'.' + QUOTENAME(@SourceTable) + N' ' + CASE WHEN @SelectionStrategy = N'ANCHOR' THEN N'a' ELSE N't' END + N' WITH (NOLOCK)  /* production source: candidate selection must take NO locks (rows are past the retention cutoff; dedup + key-based DELETE are authoritative) */
              WHERE ' + @TimestampExpr + N' >= @FromUtc
                AND ' + @TimestampExpr + N' <  @ToUtc
' + @StrategyWhereSql + N'
          ),
          dedupe AS
          (
              SELECT
                  raw.*,
                  rn = ROW_NUMBER() OVER
                  (
                      PARTITION BY ' + @PartitionKeys + N'
                      ORDER BY ' + @OrderKeys + N'
                  )
              FROM raw
          )
          INSERT INTO #Candidates(' + @InsertColumns + N', DocCreatedAt, CandidateHash)
          SELECT TOP (@TopN)
                 ' + @OutputKeys + N',
                 DocCreatedAt,
                 HASHBYTES(''SHA2_256'', CONVERT(varbinary(max), CONCAT(' + @HashInput + N')))
          FROM dedupe
          WHERE rn = 1
          ORDER BY ' + @OrderKeys + N';';

        -- @CutoffUtc is exposed as an alias of @ToUtc (the candidate upper bound) so an operator can add a
        -- SARGABLE pre-filter on the raw indexed column to CandidateWhereSql/AdditionalWhereSql referencing
        -- @CutoffUtc — uniform with the TIMESTAMP runner (027). See "sargable cutoff" in the perf doc (C3):
        -- e.g. CandidateWhereSql = N'[DATE_TIME] < DATEADD(HOUR, 26, @CutoffUtc)' turns the candidate scan
        -- into an index seek; the precise (TimestampExpr < cutoff) predicate still refines, so a too-tight
        -- bound only under-includes (delays archival), never deletes the wrong rows.
        EXEC sys.sp_executesql
            @sql,
            N'@FromUtc datetime2(0), @ToUtc datetime2(0), @CutoffUtc datetime2(0), @TopN int',
            @FromUtc = @FromUtc,
            @ToUtc = @ToUtc,
            @CutoffUtc = @ToUtc,
            @TopN = @MaxCandidates;

        -- T-21 legal-hold: drop held keys so they never enter the WorkBatch (never archived+deleted).
        -- OBJECT_ID-guarded for graceful degradation when 056 is not deployed.
        IF OBJECT_ID(N'arch.LegalHold', N'U') IS NOT NULL
            DELETE c FROM #Candidates c
            WHERE EXISTS (SELECT 1 FROM arch.LegalHold lh
                          WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                            AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb)
                            AND lh.HoldKey = c.Key1 COLLATE DATABASE_DEFAULT);

        IF NOT EXISTS (SELECT 1 FROM #Candidates)
        BEGIN
            IF @AppLockTaken = 1
                EXEC sys.sp_releaseapplock @Resource = @AppLockResource, @LockOwner = 'Session';

            RETURN;
        END;

        BEGIN TRAN;

        INSERT INTO arch.WorkBatch
        (
            ProcessId, SourceDb, ArchiveDb, RangeFromUtc, RangeToUtc, ModeSnapshot, Status, PreparedAtUtc
        )
        VALUES
        (
            @ProcessId, @SourceDb, @ArchiveDb, @FromUtc, @ToUtc, @Mode, 'Prepared', SYSUTCDATETIME()
        );

        SET @WorkBatchId = SCOPE_IDENTITY();

        INSERT INTO arch.WorkBatchKey
        (
            WorkBatchId, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, DocCreatedAt, CandidateHash
        )
        SELECT
            @WorkBatchId, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, DocCreatedAt, CandidateHash
        FROM #Candidates
        ORDER BY DocCreatedAt, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8;

        COMMIT;

        IF @AppLockTaken = 1
        BEGIN
            EXEC sys.sp_releaseapplock @Resource = @AppLockResource, @LockOwner = 'Session';
            SET @AppLockTaken = 0;
        END;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK;

        IF @AppLockTaken = 1
            EXEC sys.sp_releaseapplock @Resource = @AppLockResource, @LockOwner = 'Session';

        DECLARE @err nvarchar(4000) = ERROR_MESSAGE();
        RAISERROR(N'arch.usp_PrepareCandidates failed: %s', 16, 1, @err);
        RETURN;
    END CATCH
END
GO
-- <<< end: kArchiveManagerAdmin\v2\014_usp_PrepareCandidates.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\015_usp_RunPreparedBatch.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_RunPreparedBatch]
    @WorkBatchId bigint,
    @StopAtUtc   datetime2(0),
    @DryRun      bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
    BEGIN
        RAISERROR(N'2.0 metadata is not installed. Run v2/010_universal_archive_core.sql first.', 16, 1);
        RETURN;
    END;

    DECLARE
        @ProcessId int,
        @ProcessDatabaseId int,
        @ProcessCode sysname,
        @SourceDb sysname,
        @ArchiveDb sysname,
        @Mode tinyint,
        @SelectionStrategy nvarchar(30),
        @AuditLevel nvarchar(20),
        @BatchDocCount int,
        @BatchRowCount int,
        @MaxRowsPerTransaction int,
        @BatchUnitCount int,
        @LockTimeoutMs int,
        @DeadlockPriority nvarchar(10),
        @DocKeyLabel nvarchar(50),
        @AllowDelNoArch bit,
        @RangeToUtc datetime2(0),
        @RunId bigint = NULL,
        @RunItemId bigint = NULL;

    SELECT
        @ProcessId = wb.ProcessId,
        @SourceDb = wb.SourceDb,
        @ArchiveDb = wb.ArchiveDb,
        @Mode = wb.ModeSnapshot,
        @RangeToUtc = wb.RangeToUtc
    FROM arch.WorkBatch wb
    WHERE wb.WorkBatchId = @WorkBatchId;

    IF @ProcessId IS NULL
    BEGIN
        RAISERROR(N'WorkBatchId not found: %I64d', 16, 1, @WorkBatchId);
        RETURN;
    END;

    SELECT
        @ProcessDatabaseId = e.ProcessDatabaseId,
        @ProcessCode = e.ProcessCode,
        @SelectionStrategy = COALESCE(e.SelectionStrategy, N'ANCHOR'),
        @AuditLevel = COALESCE(e.AuditLevel, N'BATCH'),
        @BatchDocCount = e.BatchDocCount,
        @BatchRowCount = e.BatchRowCount,
        @MaxRowsPerTransaction = e.MaxRowsPerTransaction,
        @LockTimeoutMs = COALESCE(e.LockTimeoutMs, 10000),
        @DeadlockPriority = COALESCE(e.DeadlockPriority, N'LOW'),
        @DocKeyLabel = COALESCE(NULLIF(e.DocKeyLabel, N''), N'DOCKEY'),
        @AllowDelNoArch = COALESCE(e.AllowDeleteWithoutArchive, 0)
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessId = @ProcessId
      AND e.SourceDb = @SourceDb
      AND e.ArchiveDb = @ArchiveDb
      AND e.IsEnabled = 1;

    IF @ProcessCode IS NULL
    BEGIN
        RAISERROR(N'ProcessId not found in arch.Process: %d', 16, 1, @ProcessId);
        RETURN;
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM arch.v_ObjectSpecDatabaseEffective
        WHERE ProcessDatabaseId = @ProcessDatabaseId
          AND ObjectIsEnabled = 1
    )
    BEGIN
        RAISERROR(N'No ObjectSpec rows found for process: %s', 16, 1, @ProcessCode);
        RETURN;
    END;

    -- P0.5 Risk K1 gate: block real deletes when the cutoff expression is not
    -- UTC-normalized (AT TIME ZONE). Dry-runs (@DryRun=1) are exempt so candidate
    -- previews keep working before the timezone policy is applied. THROW 50200.
    IF @DryRun = 0
        EXEC arch.usp_AssertTimezonePolicyApplied
             @ProcessId = @ProcessId,
             @SourceDb  = @SourceDb,
             @ArchiveDb = @ArchiveDb;

    -- T-21 retention floor (ANCHOR cutoff snapshot = WorkBatch.RangeToUtc); DryRun exempt. THROW 50210.
    -- (Primary enforcement is at PREPARE time in 014; this is defense if the floor was raised after prep.)
    -- OBJECT_ID-guarded for graceful degradation when 056 is not deployed.
    IF @DryRun = 0 AND OBJECT_ID(N'arch.usp_AssertRetentionFloor', N'P') IS NOT NULL
        EXEC arch.usp_AssertRetentionFloor
             @ProcessId = @ProcessId,
             @SourceDb  = @SourceDb,
             @ArchiveDb = @ArchiveDb,
             @CutoffUtc = @RangeToUtc;

    -- T-05 runtime re-assert (audit hardening): the Save* API procs validate these fragments at SAVE
    -- time, but a direct DBA write to arch.ObjectSpec(+overrides) bypasses the API. Re-assert every
    -- config-sourced fragment once up front (not per batch) before it is concatenated into the dynamic
    -- DELETE/COPY. OBJECT_ID-guarded for graceful degradation. THROW 50400.
    IF OBJECT_ID(N'arch.usp_AssertSafeSqlExpression', N'P') IS NOT NULL
    BEGIN
        DECLARE @vExpr nvarchar(4000), @vField nvarchar(128);
        DECLARE cVal CURSOR LOCAL FAST_FORWARD FOR
            SELECT os.JoinToAnchorPredicateSql, N'ObjectSpec.JoinToAnchorPredicateSql'
            FROM arch.v_ObjectSpecDatabaseEffective os
            WHERE os.ProcessDatabaseId = @ProcessDatabaseId AND os.ObjectIsEnabled = 1
            UNION ALL
            SELECT os.AdditionalWhereSql, N'ObjectSpec.AdditionalWhereSql'
            FROM arch.v_ObjectSpecDatabaseEffective os
            WHERE os.ProcessDatabaseId = @ProcessDatabaseId AND os.ObjectIsEnabled = 1
            UNION ALL
            SELECT os.TimestampExpr, N'ObjectSpec.TimestampExpr'
            FROM arch.v_ObjectSpecDatabaseEffective os
            WHERE os.ProcessDatabaseId = @ProcessDatabaseId AND os.ObjectIsEnabled = 1;
        OPEN cVal;
        FETCH NEXT FROM cVal INTO @vExpr, @vField;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC arch.usp_AssertSafeSqlExpression @vExpr, @vField;
            FETCH NEXT FROM cVal INTO @vExpr, @vField;
        END;
        CLOSE cVal;
        DEALLOCATE cVal;
    END;

    SET @BatchUnitCount =
        CASE
            WHEN @SelectionStrategy = N'TIMESTAMP' THEN COALESCE(@BatchRowCount, @BatchDocCount, 4000)
            ELSE COALESCE(@BatchDocCount, @BatchRowCount, 25)
        END;

    IF @MaxRowsPerTransaction IS NOT NULL
       AND @MaxRowsPerTransaction > 0
       AND @MaxRowsPerTransaction < @BatchUnitCount
        SET @BatchUnitCount = @MaxRowsPerTransaction;

    -- SAFETY (source lock-escalation guard): a single per-batch DELETE of more than ~5000 rows escalates
    -- its row locks to a TABLE X lock on the PRODUCTION source, blocking OLTP for the batch duration
    -- (proven live). Hard-cap the per-transaction unit for EVERY strategy (this proc runs the ANCHOR
    -- prepared-batch path, where @BatchUnitCount is documents; capping it bounds the claim size — note that
    -- a document with many detail rows can still delete >cap ROWS per object table, so ANCHOR processes
    -- must also keep BatchDocCount conservative). Larger volumes still process fully via more batches.
    IF @BatchUnitCount > 4000
        SET @BatchUnitCount = 4000;

    IF @BatchUnitCount <= 0
    BEGIN
        RAISERROR(N'Effective prepared-batch size must be greater than zero for process: %s', 16, 1, @ProcessCode);
        RETURN;
    END;

    IF @DeadlockPriority = N'LOW' SET DEADLOCK_PRIORITY LOW;
    ELSE IF @DeadlockPriority = N'HIGH' SET DEADLOCK_PRIORITY HIGH;
    ELSE SET DEADLOCK_PRIORITY NORMAL;

    DECLARE @LockTimeoutStmt nvarchar(80) = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(20), @LockTimeoutMs) + N';';
    EXEC(@LockTimeoutStmt);

    UPDATE arch.WorkBatch
    SET Status = CASE WHEN Status IN ('Prepared','Paused') THEN 'Running' ELSE Status END,
        StartedAtUtc = COALESCE(StartedAtUtc, SYSUTCDATETIME())
    WHERE WorkBatchId = @WorkBatchId;

    UPDATE arch.WorkBatchKey
    SET Status = 0, ClaimedAtUtc = NULL, ClaimedBy = NULL
    WHERE WorkBatchId = @WorkBatchId
      AND Status = 1
      AND ClaimedAtUtc < DATEADD(HOUR, -2, SYSUTCDATETIME());

    CREATE TABLE #Claimed
    (
        Key1 nvarchar(256) NOT NULL,
        Key2 nvarchar(256) NOT NULL,
        Key3 nvarchar(256) NOT NULL,
        Key4 nvarchar(256) NOT NULL,
        Key5 nvarchar(256) NOT NULL,
        Key6 nvarchar(256) NOT NULL,
        Key7 nvarchar(256) NOT NULL,
        Key8 nvarchar(256) NOT NULL,
        AnchorRowGuid uniqueidentifier NULL,
        DocCreatedAt datetime2(0) NULL,
        CandidateHash varbinary(32) NULL
    );

    -- T-03: stamp the worker's session identity so usp_RecoverStaleRuns can tell a live run from a
    -- dead one and never recover a run whose worker session is still executing.
    INSERT INTO arch.Run(SourceDb, ArchiveDb, HostName, AppName, InitiatedBy, WorkerSessionId, WorkerSessionLoginTimeUtc)
    VALUES (@SourceDb, @ArchiveDb, HOST_NAME(), APP_NAME(), SUSER_SNAME(),
            @@SPID, (SELECT login_time FROM sys.dm_exec_sessions WHERE session_id = @@SPID));
    SET @RunId = SCOPE_IDENTITY();

    INSERT INTO arch.RunItem(RunId, ProcessId, AsOfUtc, CutoffUtc, Mode)
    VALUES (@RunId, @ProcessId, SYSUTCDATETIME(), @RangeToUtc, @Mode);
    SET @RunItemId = SCOPE_IDENTITY();

    BEGIN TRY
        -- Perf: resolve the per-object effective config ONCE up front, not per batch. The per-object cursor
        -- below previously re-queried arch.v_ObjectSpecDatabaseEffective (Process+ProcessDatabase+ObjectSpec
        -- +override COALESCE join) on EVERY batch iteration; that config is static for the run, so cache it
        -- into #Obj and iterate the temp table. Mirrors the #Obj pattern already used by 027. Reduces both
        -- complexity (no repeated view join) and cost (~10-15% on multi-object, high-batch-count runs).
        CREATE TABLE #Obj
        (
            Seq int IDENTITY(1,1) NOT NULL PRIMARY KEY,
            SourceSchema sysname NOT NULL,
            SourceTable sysname NOT NULL,
            DeleteMode tinyint NOT NULL,
            JoinSql nvarchar(4000) NULL,
            AddWhere nvarchar(4000) NULL,
            ArchiveSchema nvarchar(128) NOT NULL,
            ArchiveTable sysname NOT NULL,
            RequireArchiveForDelete bit NULL
        );
        INSERT INTO #Obj (SourceSchema, SourceTable, DeleteMode, JoinSql, AddWhere, ArchiveSchema, ArchiveTable, RequireArchiveForDelete)
        SELECT
            os.SourceSchema,
            os.SourceTable,
            os.DeleteMode,
            os.JoinToAnchorPredicateSql,
            os.AdditionalWhereSql,
            CONVERT(nvarchar(128), REPLACE(
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo' THEN N'{SourceDb}'
                    ELSE LTRIM(RTRIM(os.ArchiveSchema))
                END,
                N'{SourceDb}', @SourceDb)),
            COALESCE(os.ArchiveTable, os.SourceTable),
            os.RequireArchiveForDelete
        FROM arch.v_ObjectSpecDatabaseEffective os
        WHERE os.ProcessDatabaseId = @ProcessDatabaseId
          AND os.ObjectIsEnabled = 1
        ORDER BY os.DeleteOrder;

        WHILE SYSUTCDATETIME() < @StopAtUtc
        BEGIN
            -- Cooperative cancel (040): operator requested a stop. The previous batch is
            -- committed and remaining WorkBatchKeys stay claimable, so the WorkBatch is left
            -- 'Paused' below and can resume later. The run ends with Status='STOPPED'.
            IF EXISTS (SELECT 1 FROM arch.Run WHERE RunId = @RunId AND CancelRequestedAtUtc IS NOT NULL)
                BREAK;

            DELETE FROM #Claimed;

            ;WITH cte AS
            (
                SELECT TOP (@BatchUnitCount) *
                FROM arch.WorkBatchKey WITH (UPDLOCK, READPAST, ROWLOCK)
                WHERE WorkBatchId = @WorkBatchId
                  AND Status = 0
                ORDER BY DocCreatedAt, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8
            )
            UPDATE cte
            SET Status = 1,
                Attempts = Attempts + 1,
                ClaimedAtUtc = SYSUTCDATETIME(),
                ClaimedBy = SUSER_SNAME(),
                ErrorMessage = NULL
            OUTPUT
                inserted.Key1,
                inserted.Key2,
                inserted.Key3,
                inserted.Key4,
                inserted.Key5,
                inserted.Key6,
                inserted.Key7,
                inserted.Key8,
                inserted.AnchorRowGuid,
                inserted.DocCreatedAt,
                inserted.CandidateHash
            INTO #Claimed
            (
                Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8,
                AnchorRowGuid, DocCreatedAt, CandidateHash
            );

            IF NOT EXISTS (SELECT 1 FROM #Claimed)
                BREAK;

            IF @DryRun = 1
            BEGIN
                SELECT TOP (100)
                    Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, DocCreatedAt, CandidateHash
                FROM #Claimed
                ORDER BY DocCreatedAt, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8;

                UPDATE k
                SET Status = 0, ClaimedAtUtc = NULL, ClaimedBy = NULL
                FROM arch.WorkBatchKey k
                JOIN #Claimed c
                  ON c.Key1 = k.Key1
                 AND c.Key2 = k.Key2
                 AND ISNULL(c.CandidateHash, 0x) = ISNULL(k.CandidateHash, 0x)
                WHERE k.WorkBatchId = @WorkBatchId;

                UPDATE arch.RunItem
                SET BatchesDone = BatchesDone + 1,
                    DocsDone = DocsDone + (SELECT COUNT(*) FROM #Claimed),
                    Status = N'DRYRUN',
                    EndedAt = SYSUTCDATETIME()
                WHERE RunItemId = @RunItemId;

                UPDATE arch.Run
                SET Status = N'DRYRUN',
                    EndedAt = SYSUTCDATETIME()
                WHERE RunId = @RunId;

                UPDATE arch.WorkBatch
                SET Status = 'Paused',
                    LastProgressAtUtc = SYSUTCDATETIME(),
                    Notes = N'DryRun preview only'
                WHERE WorkBatchId = @WorkBatchId;

                RETURN;
            END;

            CREATE TABLE #Keys
            (
                KeyId bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
                DocKey nvarchar(256) NOT NULL,
                DocKey2 nvarchar(256) NOT NULL,
                Key1 nvarchar(256) NOT NULL,
                Key2 nvarchar(256) NOT NULL,
                Key3 nvarchar(256) NOT NULL,
                Key4 nvarchar(256) NOT NULL,
                Key5 nvarchar(256) NOT NULL,
                Key6 nvarchar(256) NOT NULL,
                Key7 nvarchar(256) NOT NULL,
                Key8 nvarchar(256) NOT NULL,
                AnchorRowGuid uniqueidentifier NULL,
                DocCreatedAt datetime2(0) NULL,
                CandidateHash varbinary(32) NULL
            );

            DECLARE @SourceCollation sysname = CONVERT(sysname, DATABASEPROPERTYEX(@SourceDb, N'Collation'));
            IF @SourceCollation IS NOT NULL
            BEGIN
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN DocKey nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN DocKey2 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key1 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key2 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key3 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key4 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key5 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key6 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key7 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key8 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
            END;

            INSERT INTO #Keys
            (
                DocKey, DocKey2, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8,
                AnchorRowGuid, DocCreatedAt, CandidateHash
            )
            SELECT
                Key1, Key2, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8,
                AnchorRowGuid, DocCreatedAt, CandidateHash
            FROM #Claimed;

            -- T-21 legal-hold (defense for a hold added AFTER this WorkBatch was prepared): a claimed key
            -- now under an active hold must NOT be deleted. Park it (WorkBatchKey Status=5) so it is neither
            -- deleted/archived, marked done, nor re-claimed, then drop it from this batch (#Keys/#Claimed).
            -- It returns as a fresh candidate at the next prepare once the hold is released. Guarded so a
            -- runner deployed without 056 degrades gracefully. (014 already excludes holds at prepare time.)
            IF OBJECT_ID(N'arch.LegalHold', N'U') IS NOT NULL
               AND EXISTS (SELECT 1 FROM arch.LegalHold lh
                           WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                             AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb))
            BEGIN
                UPDATE k
                SET Status = 5, ClaimedAtUtc = NULL, ClaimedBy = NULL,
                    ErrorMessage = N'LEGAL HOLD: excluded from deletion (hold added after prepare).'
                FROM arch.WorkBatchKey k
                JOIN #Claimed c
                  ON c.Key1 = k.Key1 AND c.Key2 = k.Key2 AND ISNULL(c.CandidateHash, 0x) = ISNULL(k.CandidateHash, 0x)
                WHERE k.WorkBatchId = @WorkBatchId
                  AND EXISTS (SELECT 1 FROM arch.LegalHold lh
                              WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                                AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb)
                                AND lh.HoldKey = k.Key1 COLLATE DATABASE_DEFAULT);

                DELETE kk FROM #Keys kk
                WHERE EXISTS (SELECT 1 FROM arch.LegalHold lh
                              WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                                AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb)
                                AND lh.HoldKey = kk.Key1 COLLATE DATABASE_DEFAULT);

                DELETE c FROM #Claimed c
                WHERE EXISTS (SELECT 1 FROM arch.LegalHold lh
                              WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                                AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb)
                                AND lh.HoldKey = c.Key1 COLLATE DATABASE_DEFAULT);
            END;

            BEGIN TRAN;

            DECLARE
                @RowsDeletedBatch bigint = 0,
                @RowsArchivedBatch bigint = 0;

            -- Iterate the once-resolved effective object config (see #Obj at the top of this TRY) instead of
            -- re-joining arch.v_ObjectSpecDatabaseEffective on every batch.
            DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT
                SourceSchema, SourceTable, DeleteMode, JoinSql, AddWhere,
                ArchiveSchema, ArchiveTable, RequireArchiveForDelete
            FROM #Obj
            ORDER BY Seq;

            DECLARE
                @sSchema sysname,
                @sTable sysname,
                @delMode tinyint,
                @join nvarchar(4000),
                @addWhere nvarchar(4000),
                @aSchema sysname,
                @aTable sysname,
                @reqArch bit,
                @delCols nvarchar(max),
                @tgtCols nvarchar(max),
                @srcCols nvarchar(max),
                @pkPred nvarchar(max),
                @stmt nvarchar(max),
                @rc bigint;

            OPEN c;
            FETCH NEXT FROM c INTO @sSchema, @sTable, @delMode, @join, @addWhere, @aSchema, @aTable, @reqArch;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @delMode <> 1
                    RAISERROR(N'ObjectSpec.DeleteMode must be 1 for prepared-batch process (%s.%s).', 16, 1, @sSchema, @sTable);

                IF @join IS NULL OR LTRIM(RTRIM(@join)) = N''
                    RAISERROR(N'Missing JoinToAnchorPredicateSql for %s.%s.', 16, 1, @sSchema, @sTable);

                IF @Mode = 0 AND @reqArch = 1 AND @AllowDelNoArch = 0
                    RAISERROR(N'Delete-only blocked for %s.%s (RequireArchiveForDelete=1).', 16, 1, @sSchema, @sTable);

                -- Mode 1 (archive+delete) and Mode 2 (copy-only) both write to the archive -> provision it.
                IF @Mode IN (1, 2)
                    EXEC arch.usp_EnsureArchiveTableLikeSource
                         @SourceDb = @SourceDb,
                         @ArchiveDb = @ArchiveDb,
                         @SourceSchema = @sSchema,
                         @SourceTable = @sTable,
                         @ArchiveSchema = @aSchema,
                         @ArchiveTable = @aTable,
                         @MakeAllNullable = 1,
                         @IncludeComputed = 0;

                SET @srcCols = NULL; SET @pkPred = NULL;
                EXEC arch.usp_GetOutputColumns
                     @SourceDb = @SourceDb,
                     @SourceSchema = @sSchema,
                     @SourceTable = @sTable,
                     @IncludeComputed = 0,
                     @DeletedSelectList = @delCols OUTPUT,
                     @TargetColumnList = @tgtCols OUTPUT,
                     @SourceAlias = N't',
                     @SourceSelectList = @srcCols OUTPUT;

                -- Mode=2 copy-only: derive the source-PK dedup predicate + ensure the archive dedup index.
                IF @Mode = 2
                    EXEC arch.usp_GetCopyDedupInfo
                         @SourceDb = @SourceDb, @SourceSchema = @sSchema, @SourceTable = @sTable,
                         @ArchiveDb = @ArchiveDb, @ArchiveSchema = @aSchema, @ArchiveTable = @aTable,
                         @SourceAlias = N't', @ArchiveAlias = N'a', @EnsureIndex = 1,
                         @PkPredicate = @pkPred OUTPUT;

                IF @Mode = 1
                BEGIN
                    SET @stmt =
                    N'DELETE t
                      OUTPUT ' + @delCols + N'
                      INTO ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@aSchema) + N'.' + QUOTENAME(@aTable) + N' (' + @tgtCols + N')
                      FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@sSchema) + N'.' + QUOTENAME(@sTable) + N' t
                      INNER JOIN #Keys k ON ' + @join +
                      CASE
                          WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                              THEN N' WHERE (' + @addWhere + N')'
                          ELSE N''
                      END + N';';
                END
                ELSE IF @Mode = 2
                BEGIN
                    -- COPY-ONLY: insert candidate rows into the archive, NEVER delete the source, only rows
                    -- not already in the archive (dedup by source PK via @pkPred = 'a.[pk]=t.[pk]...').
                    IF NULLIF(LTRIM(RTRIM(@pkPred)), N'') IS NULL
                        THROW 50223, 'Copy-only (Mode=2) requires a PRIMARY KEY on the source table for dedup (predicate missing).', 1;
                    SET @stmt =
                    N'INSERT INTO ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@aSchema) + N'.' + QUOTENAME(@aTable) + N' (' + @tgtCols + N')
                      SELECT ' + @srcCols + N'
                      FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@sSchema) + N'.' + QUOTENAME(@sTable) + N' t WITH (NOLOCK)  /* copy-only read of the production source must take NO locks */
                      INNER JOIN #Keys k ON ' + @join + N'
                      WHERE ' +
                      CASE
                          WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                              THEN N'(' + @addWhere + N') AND '
                          ELSE N''
                      END +
                      N'NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@aSchema) + N'.' + QUOTENAME(@aTable) + N' a WHERE ' + @pkPred + N');';
                END
                ELSE
                BEGIN
                    SET @stmt =
                    N'DELETE t
                      FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@sSchema) + N'.' + QUOTENAME(@sTable) + N' t
                      INNER JOIN #Keys k ON ' + @join +
                      CASE
                          WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                              THEN N' WHERE (' + @addWhere + N')'
                          ELSE N''
                      END + N';';
                END;

                EXEC(@stmt);
                SET @rc = @@ROWCOUNT;

                -- Mode=2 copies (archives) without deleting: deleted=0, archived=@rc. Mode=1: both=@rc. Mode=0: deleted=@rc, archived=0.
                INSERT INTO arch.RunItemObject(RunItemId, SourceSchema, SourceTable, RowsDeleted, RowsArchived)
                VALUES (@RunItemId, @sSchema, @sTable, CASE WHEN @Mode = 2 THEN 0 ELSE @rc END, CASE WHEN @Mode IN (1, 2) THEN @rc ELSE 0 END);

                SET @RowsDeletedBatch = @RowsDeletedBatch + CASE WHEN @Mode = 2 THEN 0 ELSE @rc END;
                SET @RowsArchivedBatch = @RowsArchivedBatch + CASE WHEN @Mode IN (1, 2) THEN @rc ELSE 0 END;

                FETCH NEXT FROM c INTO @sSchema, @sTable, @delMode, @join, @addWhere, @aSchema, @aTable, @reqArch;
            END;

            CLOSE c;
            DEALLOCATE c;

            IF @Mode = 1
            BEGIN
                IF EXISTS
                (
                    SELECT 1
                    FROM arch.RunItemObject rio
                    WHERE rio.RunItemId = @RunItemId
                      AND ISNULL(rio.RowsDeleted,0) > 0
                      AND ISNULL(rio.RowsArchived,0) <> ISNULL(rio.RowsDeleted,0)
                )
                BEGIN
                    DECLARE @bad nvarchar(4000);

                    SELECT @bad =
                        STUFF((
                            SELECT TOP (50)
                                N'; ' + rio.SourceTable
                                + N' del=' + CONVERT(nvarchar(20), ISNULL(rio.RowsDeleted,0))
                                + N' arc=' + CONVERT(nvarchar(20), ISNULL(rio.RowsArchived,0))
                            FROM arch.RunItemObject rio
                            WHERE rio.RunItemId = @RunItemId
                              AND ISNULL(rio.RowsDeleted,0) > 0
                              AND ISNULL(rio.RowsArchived,0) <> ISNULL(rio.RowsDeleted,0)
                            FOR XML PATH(''), TYPE
                        ).value('.','nvarchar(max)'), 1, 2, N'');

                    RAISERROR(N'Archive/Delete mismatch (Mode=1). %s', 16, 1, @bad);
                END;
            END;

            IF @AuditLevel = N'ROW'
            BEGIN
                INSERT INTO arch.RunDocAudit(RunItemId, ProcessCode, DocKeyLabel, DocKey, DocCreatedAt, Archived)
                SELECT
                    @RunItemId,
                    @ProcessCode,
                    @DocKeyLabel,
                    CASE
                        WHEN NULLIF(k.DocKey2, N'') IS NULL THEN k.DocKey
                        ELSE k.DocKey + N'|' + k.DocKey2
                    END,
                    k.DocCreatedAt,
                    CASE WHEN @Mode IN (1, 2) THEN 1 ELSE 0 END   -- Mode=2 copy also archives the doc
                FROM #Keys k;
            END;

            UPDATE arch.RunItem
            SET BatchesDone = BatchesDone + 1,
                DocsDone = DocsDone + (SELECT COUNT(*) FROM #Keys),
                RowsDeleted = RowsDeleted + @RowsDeletedBatch,
                RowsArchived = RowsArchived + @RowsArchivedBatch
            WHERE RunItemId = @RunItemId;

            -- T-17: flip the claimed keys to Done (and stamp WorkBatch progress) INSIDE the same
            -- transaction as the delete/archive, so claim->delete->done is ATOMIC. Previously these ran
            -- after COMMIT; a crash/restart/deadlock in that window left keys claimed (Status=1) while their
            -- rows were already deleted+archived -> stale-reclaim -> RE-PROCESSING (duplicate RunDocAudit,
            -- inflated DocsDone, Mode=0 / AdditionalWhere-drift hazards). Idempotency is now derived from the
            -- key's persisted Status, not from source-row existence. Scope AND k.Status=1 so a key parked
            -- under legal hold (Status=5, T-21) or already done (2) is never resurrected to Done.
            UPDATE k
            SET Status = 2,
                DoneAtUtc = SYSUTCDATETIME()
            FROM arch.WorkBatchKey k
            JOIN #Claimed c
              ON c.Key1 = k.Key1
             AND c.Key2 = k.Key2
             AND ISNULL(c.CandidateHash, 0x) = ISNULL(k.CandidateHash, 0x)
            WHERE k.WorkBatchId = @WorkBatchId
              AND k.Status = 1;

            UPDATE arch.WorkBatch
            SET LastProgressAtUtc = SYSUTCDATETIME(),
                LastKey1 = (SELECT TOP(1) Key1 FROM #Claimed ORDER BY DocCreatedAt DESC, Key1 DESC),
                LastKey2 = (SELECT TOP(1) Key2 FROM #Claimed ORDER BY DocCreatedAt DESC, Key1 DESC, Key2 DESC)
            WHERE WorkBatchId = @WorkBatchId;

            COMMIT;

            DROP TABLE #Keys;
        END;

        DECLARE @FinalStatus nvarchar(20) =
            CASE WHEN EXISTS (SELECT 1 FROM arch.Run WHERE RunId = @RunId AND CancelRequestedAtUtc IS NOT NULL)
                 THEN N'STOPPED' ELSE N'OK' END;

        UPDATE arch.RunItem
        SET Status = @FinalStatus,
            EndedAt = SYSUTCDATETIME()
        WHERE RunItemId = @RunItemId;

        UPDATE arch.Run
        SET Status = @FinalStatus,
            EndedAt = SYSUTCDATETIME()
        WHERE RunId = @RunId;

        IF NOT EXISTS (SELECT 1 FROM arch.WorkBatchKey WHERE WorkBatchId = @WorkBatchId AND Status IN (0,1))
        BEGIN
            UPDATE arch.WorkBatch
            SET Status = 'Completed',
                CompletedAtUtc = SYSUTCDATETIME()
            WHERE WorkBatchId = @WorkBatchId;
        END
        ELSE
        BEGIN
            UPDATE arch.WorkBatch
            SET Status = 'Paused',
                LastProgressAtUtc = SYSUTCDATETIME()
            WHERE WorkBatchId = @WorkBatchId;
        END;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;

        DECLARE @errnum int = ERROR_NUMBER();
        DECLARE @errmsg nvarchar(4000) = ERROR_MESSAGE();
        DECLARE @retryable bit =
            CASE WHEN @errnum IN (1205, 1222) OR @errmsg LIKE N'%collation conflict%' THEN 1 ELSE 0 END;

        UPDATE k
        SET Status =
            CASE WHEN @retryable = 1 THEN 0 ELSE 3 END,
            ClaimedAtUtc = CASE WHEN @retryable = 1 THEN NULL ELSE k.ClaimedAtUtc END,
            ClaimedBy = CASE WHEN @retryable = 1 THEN NULL ELSE k.ClaimedBy END,
            ErrorMessage = LEFT(@errmsg, 4000)
        FROM arch.WorkBatchKey k
        JOIN #Claimed c
          ON c.Key1 = k.Key1
         AND c.Key2 = k.Key2
         AND ISNULL(c.CandidateHash, 0x) = ISNULL(k.CandidateHash, 0x)
        WHERE k.WorkBatchId = @WorkBatchId
          AND k.Status = 1;   -- T-17: only reset still-claimed keys; never resurrect a done (2) or legal-hold-parked (5) key

        UPDATE arch.WorkBatch
        SET Status = 'Paused',
            LastProgressAtUtc = SYSUTCDATETIME(),
            Notes = LEFT(@errmsg, 4000)
        WHERE WorkBatchId = @WorkBatchId;

        IF @RunItemId IS NOT NULL
        BEGIN
            UPDATE arch.RunItem
            SET Status = N'FAILED',
                EndedAt = SYSUTCDATETIME(),
                ErrorMessage = @errmsg
            WHERE RunItemId = @RunItemId;
        END;

        IF @RunId IS NOT NULL
        BEGIN
            UPDATE arch.Run
            SET Status = N'FAILED',
                EndedAt = SYSUTCDATETIME(),
                ErrorMessage = @errmsg
            WHERE RunId = @RunId;
        END;

        RAISERROR(N'arch.usp_RunPreparedBatch failed: %s', 16, 1, @errmsg);
        RETURN;
    END CATCH
END
GO
-- <<< end: kArchiveManagerAdmin\v2\015_usp_RunPreparedBatch.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\027_usp_RunTimestampProcess.sql
USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_RunTimestampProcess]
    @ProcessCode   sysname,
    @SourceDb      sysname,
    @ArchiveDb     sysname,
    @AsOfUtc       datetime2(0) = NULL,
    @StopAtUtc     datetime2(0) = NULL,
    @BatchRowCount int = NULL,
    @MaxRows       int = NULL,
    @DryRun        bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- T-04: make the archive write fail-safe. With ANSI_WARNINGS ON a string truncation or numeric
    -- overflow during DELETE ... OUTPUT INTO <archive> raises a hard error (caught below -> rollback)
    -- instead of silently storing a narrowed/corrupted copy while the source row is deleted forever.
    SET ANSI_WARNINGS ON;

    IF NULLIF(LTRIM(RTRIM(@ProcessCode)), N'') IS NULL
        THROW 50100, 'Parametr @ProcessCode je povinny.', 1;

    IF NULLIF(LTRIM(RTRIM(@SourceDb)), N'') IS NULL
        THROW 50101, 'Parametr @SourceDb je povinny.', 1;

    IF NULLIF(LTRIM(RTRIM(@ArchiveDb)), N'') IS NULL
        THROW 50102, 'Parametr @ArchiveDb je povinny.', 1;

    IF DB_ID(@SourceDb) IS NULL
        THROW 50103, 'Zdrojova databaze neexistuje.', 1;

    IF DB_ID(@ArchiveDb) IS NULL
        THROW 50104, 'Archivni databaze neexistuje.', 1;

    SET @AsOfUtc = COALESCE(@AsOfUtc, CONVERT(datetime2(0), SYSUTCDATETIME()));

    DECLARE
        @ProcessId int,
        @ProcessDatabaseId int,
        @Mode tinyint,
        @SelectionStrategy nvarchar(30),
        @RetentionDays int,
        @LagMin int,
        @ConfiguredBatchRowCount int,
        @MaxBatches int,
        @DelayMs int,
        @UseAppLock bit,
        @AppLockResource nvarchar(200),
        @LockTimeoutMs int,
        @DeadlockPriority nvarchar(10),
        @AllowDelNoArch bit,
        @DocKeyLabel nvarchar(50),
        @AuditLevel nvarchar(20),
        @CutoffMode tinyint,
        @CutoffDate datetime2(0),
        @CandidateWhereSql nvarchar(4000),
        @CandidateOrderSql nvarchar(4000),
        @CutoffUtc datetime2(0),
        @RunId bigint = NULL,
        @RunItemId bigint = NULL,
        @AppLockTaken bit = 0,
        @ReleaseAppLockResult int = NULL;

    SELECT
        @ProcessDatabaseId = e.ProcessDatabaseId,
        @ProcessId = e.ProcessId,
        @Mode = e.Mode,
        @SelectionStrategy = COALESCE(e.SelectionStrategy, N'ANCHOR'),
        @RetentionDays = e.RetentionDays,
        @LagMin = e.CutoffSafetyLagMinutes,
        @ConfiguredBatchRowCount = e.BatchRowCount,
        @MaxBatches = e.MaxBatchesPerRun,
        @DelayMs = e.DelayMsBetweenBatches,
        @UseAppLock = e.UseAppLock,
        @AppLockResource = COALESCE(NULLIF(e.AppLockResource, N''), N'KARCHIVE_MANAGER:' + e.ProcessCode + N':' + @SourceDb),
        @LockTimeoutMs = e.LockTimeoutMs,
        @DeadlockPriority = e.DeadlockPriority,
        @AllowDelNoArch = e.AllowDeleteWithoutArchive,
        @DocKeyLabel = COALESCE(NULLIF(LTRIM(RTRIM(e.DocKeyLabel)), N''), N'Key1'),
        @AuditLevel = COALESCE(NULLIF(LTRIM(RTRIM(e.AuditLevel)), N''), N'BATCH'),
        @CutoffMode = e.CutoffMode,
        @CutoffDate = e.CutoffDate,
        @CandidateWhereSql = e.CandidateWhereSql,
        @CandidateOrderSql = e.CandidateOrderSql
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessCode = @ProcessCode
      AND e.SourceDb = @SourceDb
      AND e.ArchiveDb = @ArchiveDb
      AND e.IsEnabled = 1;

    IF @ProcessId IS NULL
        THROW 50105, 'Proces nebyl nalezen nebo neni enabled.', 1;

    IF @SelectionStrategy <> N'TIMESTAMP'
        THROW 50106, 'arch.usp_RunTimestampProcess supports only SelectionStrategy=TIMESTAMP.', 1;

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
        THROW 50107, '2.0 metadata arch.ProcessKeySpec neni nainstalovana.', 1;

    -- P0.5 Risk K1 gate: block real deletes when ObjectSpec.TimestampExpr is not
    -- UTC-normalized (AT TIME ZONE). Dry-runs (@DryRun=1) are exempt. THROW 50200.
    IF @DryRun = 0
        EXEC arch.usp_AssertTimezonePolicyApplied
             @ProcessId = @ProcessId,
             @SourceDb  = @SourceDb,
             @ArchiveDb = @ArchiveDb;

    -- Per-transaction delete size default. Kept below SQL Server's ~5000 lock-escalation threshold:
    -- a single DELETE of >~5000 rows escalates its row locks to a TABLE X lock on the PRODUCTION source
    -- and blocks OLTP for the batch duration (proven live: 50000-row batch -> table X lock + blocked
    -- readers; 4000 -> row locks only, no block). Throughput is preserved by MaxBatchesPerRun, not by a
    -- huge batch. Explicit configs above the safe limit are blocked by usp_ValidateConfiguration (go-live gate).
    SET @BatchRowCount = COALESCE(@BatchRowCount, @ConfiguredBatchRowCount, 4000);
    SET @MaxBatches = COALESCE(@MaxBatches, 100);
    SET @DelayMs = COALESCE(@DelayMs, 0);
    SET @LagMin = COALESCE(@LagMin, 0);
    SET @LockTimeoutMs = COALESCE(@LockTimeoutMs, 10000);
    SET @AllowDelNoArch = COALESCE(@AllowDelNoArch, 0);

    IF @BatchRowCount <= 0
        THROW 50108, 'BatchRowCount musi byt vetsi nez 0.', 1;

    -- SAFETY (source lock-escalation guard, runtime backstop for the TIMESTAMP path): hard-cap the
    -- per-batch DELETE at 4000 rows regardless of the configured/passed value, so a single DELETE can
    -- never acquire >~5000 row locks and escalate to a TABLE X lock on the PRODUCTION source (proven
    -- live: 50000 -> table X + blocked readers; 4000 -> row locks only). Larger volumes still process
    -- fully via more batches (MaxBatchesPerRun). usp_ValidateConfiguration also flags oversized configs.
    IF @BatchRowCount > 4000
        SET @BatchRowCount = 4000;

    IF @MaxRows IS NULL
    BEGIN
        DECLARE @DefaultCandidateBatches int = CASE WHEN @MaxBatches > 100 THEN 100 ELSE @MaxBatches END;
        DECLARE @DefaultMaxRowsBigint bigint = CONVERT(bigint, @BatchRowCount) * CONVERT(bigint, @DefaultCandidateBatches);

        SET @MaxRows =
            CASE
                WHEN @DefaultMaxRowsBigint > 2147483647 THEN 2147483647
                ELSE CONVERT(int, @DefaultMaxRowsBigint)
            END;
    END;

    IF @MaxRows <= 0
        THROW 50109, 'MaxRows musi byt vetsi nez 0.', 1;

    IF @CutoffMode = 1 AND @CutoffDate IS NOT NULL
        SET @CutoffUtc = CONVERT(datetime2(0), @CutoffDate);
    ELSE
        SET @CutoffUtc = DATEADD(MINUTE, -@LagMin, DATEADD(DAY, -COALESCE(@RetentionDays, 0), @AsOfUtc));

    -- T-21 retention floor: block real deletes whose effective cutoff is inside the policy floor (DryRun exempt). THROW 50210.
    -- OBJECT_ID-guarded so a runner deployed WITHOUT 056 (older/hotfix path) degrades gracefully instead of erroring.
    IF @DryRun = 0 AND OBJECT_ID(N'arch.usp_AssertRetentionFloor', N'P') IS NOT NULL
        EXEC arch.usp_AssertRetentionFloor @ProcessId = @ProcessId, @SourceDb = @SourceDb, @ArchiveDb = @ArchiveDb, @CutoffUtc = @CutoffUtc;

    CREATE TABLE #Obj
    (
        RowNo int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        SourceSchema sysname NOT NULL,
        SourceTable sysname NOT NULL,
        DeleteOrder int NOT NULL,
        DeleteMode tinyint NOT NULL,
        TimestampExpr nvarchar(4000) NULL,
        JoinToAnchorPredicateSql nvarchar(4000) NULL,
        AdditionalWhereSql nvarchar(4000) NULL,
        ArchiveSchema sysname NOT NULL,
        ArchiveTable sysname NOT NULL,
        RequireArchiveForDelete bit NOT NULL,
        DelCols nvarchar(max) NULL,
        TgtCols nvarchar(max) NULL,
        SrcCols nvarchar(max) NULL,        -- Mode=2 copy: 't.[col1],t.[col2]' for INSERT ... SELECT
        PkPredicate nvarchar(max) NULL,    -- Mode=2 copy: 'a.[pk] = t.[pk] AND ...' dedup (a=archive, t=source)
        CandidateSelectExpr nvarchar(4000) NULL  -- perf: cheap local timestamp expr for candidate selection (no per-row AT TIME ZONE)
    );

    INSERT INTO #Obj
    (
        SourceSchema, SourceTable, DeleteOrder, DeleteMode,
        TimestampExpr, JoinToAnchorPredicateSql, AdditionalWhereSql,
        ArchiveSchema, ArchiveTable, RequireArchiveForDelete, CandidateSelectExpr
    )
    SELECT
        os.SourceSchema,
        os.SourceTable,
        os.DeleteOrder,
        os.DeleteMode,
        os.TimestampExpr,
        os.JoinToAnchorPredicateSql,
        os.AdditionalWhereSql,
        CONVERT(nvarchar(128), REPLACE(
            CASE
                WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo' THEN N'{SourceDb}'
                ELSE LTRIM(RTRIM(os.ArchiveSchema))
            END,
            N'{SourceDb}', @SourceDb)),
        COALESCE(os.ArchiveTable, os.SourceTable),
        COALESCE(os.RequireArchiveForDelete, 0),
        os.CandidateSelectExpr
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessDatabaseId = @ProcessDatabaseId
      AND os.ObjectIsEnabled = 1
    ORDER BY os.DeleteOrder, os.ObjectSpecId;

    IF NOT EXISTS (SELECT 1 FROM #Obj)
        THROW 50110, 'Proces nema zadny ObjectSpec.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM #Obj
        WHERE DeleteMode <> 1
           OR NULLIF(LTRIM(RTRIM(TimestampExpr)), N'') IS NULL
           OR NULLIF(LTRIM(RTRIM(JoinToAnchorPredicateSql)), N'') IS NULL
    )
        THROW 50111, 'TIMESTAMP keyset process requires DeleteMode=1, TimestampExpr and JoinToAnchorPredicateSql on every ObjectSpec.', 1;

    IF @Mode = 0
       AND @AllowDelNoArch = 0
       AND EXISTS (SELECT 1 FROM #Obj WHERE RequireArchiveForDelete = 1)
        THROW 50112, 'Delete-only je blokovan, protoze nektery ObjectSpec ma RequireArchiveForDelete=1.', 1;

    DECLARE
        @CandidateSchema sysname,
        @CandidateTable sysname,
        @TimestampExpr nvarchar(4000),
        @CandidateAdditionalWhereSql nvarchar(4000),
        @CandidateSelectExpr nvarchar(4000),
        @KeyExpr nvarchar(4000),
        @OrderSql nvarchar(4000);

    SELECT TOP (1)
        @CandidateSchema = SourceSchema,
        @CandidateTable = SourceTable,
        @TimestampExpr = TimestampExpr,
        @CandidateAdditionalWhereSql = AdditionalWhereSql,
        @CandidateSelectExpr = NULLIF(LTRIM(RTRIM(CandidateSelectExpr)), N'')
    FROM #Obj
    ORDER BY DeleteOrder, RowNo;

    SELECT @KeyExpr = pks.SourceExpressionSql
    FROM arch.ProcessKeySpec pks
    WHERE pks.ProcessId = @ProcessId
      AND pks.KeyOrdinal = 1;

    IF NULLIF(LTRIM(RTRIM(@KeyExpr)), N'') IS NULL
        THROW 50113, 'TIMESTAMP keyset process requires ProcessKeySpec KeyOrdinal=1.', 1;

    SET @OrderSql = COALESCE(NULLIF(LTRIM(RTRIM(@CandidateOrderSql)), N''), N'DocCreatedAt, Key1');

    -- T-05 runtime re-assert (audit hardening): the Save* API procs validate these fragments at SAVE
    -- time, but a direct DBA write to arch.Process/ObjectSpec bypasses the API. Re-assert every
    -- config-sourced fragment here before it is concatenated into dynamic SQL (DryRun included — the
    -- candidate scan executes them too). OBJECT_ID-guarded for graceful degradation. THROW 50400.
    IF OBJECT_ID(N'arch.usp_AssertSafeSqlExpression', N'P') IS NOT NULL
    BEGIN
        EXEC arch.usp_AssertSafeSqlExpression @KeyExpr, N'ProcessKeySpec.SourceExpressionSql';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateWhereSql, N'CandidateWhereSql';
        EXEC arch.usp_AssertSafeSqlExpression @OrderSql, N'CandidateOrderSql';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateSelectExpr, N'ObjectSpec.CandidateSelectExpr';

        DECLARE @vExpr nvarchar(4000), @vField nvarchar(128);
        DECLARE cVal CURSOR LOCAL FAST_FORWARD FOR
            SELECT TimestampExpr, N'ObjectSpec.TimestampExpr' FROM #Obj
            UNION ALL SELECT JoinToAnchorPredicateSql, N'ObjectSpec.JoinToAnchorPredicateSql' FROM #Obj
            UNION ALL SELECT AdditionalWhereSql, N'ObjectSpec.AdditionalWhereSql' FROM #Obj;
        OPEN cVal;
        FETCH NEXT FROM cVal INTO @vExpr, @vField;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC arch.usp_AssertSafeSqlExpression @vExpr, @vField;
            FETCH NEXT FROM cVal INTO @vExpr, @vField;
        END;
        CLOSE cVal;
        DEALLOCATE cVal;
    END;

    DECLARE
        @RowNo int,
        @sSchema sysname,
        @sTable sysname,
        @aSchema sysname,
        @aTable sysname,
        @delCols nvarchar(max),
        @tgtCols nvarchar(max),
        @srcCols nvarchar(max),
        @pkPred nvarchar(max);

    DECLARE cPrep CURSOR LOCAL FAST_FORWARD FOR
    SELECT RowNo, SourceSchema, SourceTable, ArchiveSchema, ArchiveTable
    FROM #Obj
    ORDER BY DeleteOrder, RowNo;

    OPEN cPrep;
    FETCH NEXT FROM cPrep INTO @RowNo, @sSchema, @sTable, @aSchema, @aTable;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Mode 1 (archive+delete) and Mode 2 (copy-only) both write to the archive -> provision it.
        IF @Mode IN (1, 2)
        BEGIN
            EXEC arch.usp_EnsureArchiveTableLikeSource
                @SourceDb = @SourceDb,
                @ArchiveDb = @ArchiveDb,
                @SourceSchema = @sSchema,
                @SourceTable = @sTable,
                @ArchiveSchema = @aSchema,
                @ArchiveTable = @aTable,
                @MakeAllNullable = 1,
                @IncludeComputed = 0;
        END;

        SET @srcCols = NULL; SET @pkPred = NULL;
        EXEC arch.usp_GetOutputColumns
            @SourceDb = @SourceDb,
            @SourceSchema = @sSchema,
            @SourceTable = @sTable,
            @IncludeComputed = 0,
            @DeletedSelectList = @delCols OUTPUT,
            @TargetColumnList = @tgtCols OUTPUT,
            @SourceAlias = N't',
            @SourceSelectList = @srcCols OUTPUT;

        -- Mode=2 copy-only: derive the source-PK dedup predicate + ensure the archive dedup index.
        IF @Mode = 2
            EXEC arch.usp_GetCopyDedupInfo
                @SourceDb = @SourceDb, @SourceSchema = @sSchema, @SourceTable = @sTable,
                @ArchiveDb = @ArchiveDb, @ArchiveSchema = @aSchema, @ArchiveTable = @aTable,
                @SourceAlias = N't', @ArchiveAlias = N'a', @EnsureIndex = 1,
                @PkPredicate = @pkPred OUTPUT;

        UPDATE #Obj
        SET DelCols = @delCols,
            TgtCols = @tgtCols,
            SrcCols = @srcCols,
            PkPredicate = @pkPred
        WHERE RowNo = @RowNo;

        FETCH NEXT FROM cPrep INTO @RowNo, @sSchema, @sTable, @aSchema, @aTable;
    END;

    CLOSE cPrep;
    DEALLOCATE cPrep;

    DECLARE @DelayStr varchar(20) = NULL;
    IF @DelayMs > 0
    BEGIN
        DECLARE @h int = @DelayMs / 3600000;
        DECLARE @m int = (@DelayMs % 3600000) / 60000;
        DECLARE @s int = (@DelayMs % 60000) / 1000;
        DECLARE @ms int = @DelayMs % 1000;

        SET @DelayStr =
            RIGHT('00'  + CONVERT(varchar(2), @h), 2) + ':' +
            RIGHT('00'  + CONVERT(varchar(2), @m), 2) + ':' +
            RIGHT('00'  + CONVERT(varchar(2), @s), 2) + '.' +
            RIGHT('000' + CONVERT(varchar(3), @ms), 3);
    END;

    BEGIN TRY
        -- T-03: stamp the worker's session identity so usp_RecoverStaleRuns can tell a live run from a
        -- dead one and never recover a run whose worker session is still executing.
        INSERT INTO arch.Run(SourceDb, ArchiveDb, HostName, AppName, InitiatedBy, WorkerSessionId, WorkerSessionLoginTimeUtc)
        VALUES (@SourceDb, @ArchiveDb, HOST_NAME(), APP_NAME(), SUSER_SNAME(),
                @@SPID, (SELECT login_time FROM sys.dm_exec_sessions WHERE session_id = @@SPID));
        SET @RunId = SCOPE_IDENTITY();

        INSERT INTO arch.RunItem(RunId, ProcessId, AsOfUtc, CutoffUtc, Mode)
        VALUES (@RunId, @ProcessId, @AsOfUtc, @CutoffUtc, @Mode);
        SET @RunItemId = SCOPE_IDENTITY();

        IF COALESCE(@UseAppLock, 1) = 1
        BEGIN
            DECLARE @lres int;
            EXEC @lres = sys.sp_getapplock
                @Resource = @AppLockResource,
                @LockMode = 'Exclusive',
                @LockOwner = 'Session',
                @LockTimeout = @LockTimeoutMs;

            IF @lres < 0
                THROW 50114, 'TIMESTAMP keyset RUN failed to acquire applock.', 1;

            SET @AppLockTaken = 1;
        END;

        IF @DeadlockPriority = N'LOW' SET DEADLOCK_PRIORITY LOW;
        ELSE IF @DeadlockPriority = N'HIGH' SET DEADLOCK_PRIORITY HIGH;
        ELSE SET DEADLOCK_PRIORITY NORMAL;

        DECLARE @LockTimeoutStmt nvarchar(80) =
            N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(20), @LockTimeoutMs) + N';';
        EXEC (@LockTimeoutStmt);

        -- T-22: coerce the candidate/batch key to the SOURCE DB collation. A TIMESTAMP process joins
        -- #Batch.Key1 back to the source key column in the cross-DB DELETE; if the source DB collation
        -- differs from the Admin DB collation, that join throws Msg 468 (collation conflict) on EVERY
        -- real delete. Mirror the ANCHOR runner (015_usp_RunPreparedBatch #Keys): build the key column,
        -- re-collate it to the source collation, then add the uniqueness/lookup index.
        DECLARE @SourceCollation sysname = CONVERT(sysname, DATABASEPROPERTYEX(@SourceDb, N'Collation'));

        CREATE TABLE #Candidates
        (
            CandId bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
            Key1 nvarchar(256) NOT NULL,
            DocCreatedAt datetime2(0) NULL,
            DupCnt int NOT NULL DEFAULT(1)   -- how many ELIGIBLE source rows share this key (uniqueness gate)
        );
        IF @SourceCollation IS NOT NULL
            EXEC(N'ALTER TABLE #Candidates ALTER COLUMN Key1 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
        CREATE UNIQUE INDEX UX_Candidates_Key1 ON #Candidates(Key1);

        -- SCALABILITY (100M-row sources): the oldest @MaxRows candidates are read via TOP + ORDER BY
        -- pushed INTO the raw scan, so the read is bounded by the BATCH size, not the table size. To make
        -- that read an index-ordered SEEK (not a full scan + sort), the operator sets, on the source''s
        -- existing timestamp index (no new index needed):
        --   * CandidateWhereSql  = a SARGABLE bound on the raw indexed column referencing @CutoffUtc
        --                          (e.g. RF_LOG2: N''[DATE_TIME] < CONVERT(char(8), DATEADD(DAY,2,@CutoffUtc), 112)''),
        --   * CandidateOrderSql  = that same raw indexed column (e.g. N''[DATE_TIME]'') so ORDER BY matches
        --                          the index order and the TOP short-circuits after @MaxRows rows.
        -- The precise (TimestampExpr < @CutoffUtc) predicate still refines, so a loose sargable bound only
        -- over-reads a little (the exact residual filters it), never deletes the wrong rows. When the source
        -- lacks a usable timestamp index the read falls back to a scan/sort (fine for smaller tables).
        --
        -- CHEAP MODE (CandidateSelectExpr + CandidateWhereSql both set): the candidate scan does NO per-row
        -- AT TIME ZONE. CandidateSelectExpr (a cheap LOCAL datetime expr, e.g. CONVERT(datetime2(0),t.DATE_TIME))
        -- supplies the projected/ordered timestamp, and CandidateWhereSql (which converts @CutoffUtc to local
        -- ONCE and compares the raw indexed column) is the authoritative cutoff. The exact AT TIME ZONE
        -- TimestampExpr cutoff is then SKIPPED (it cost ~17x on RF_LOG2). Safe: CandidateWhereSql bounds the
        -- cutoff to ~second precision and the retention floor (50210) still guards @CutoffUtc absolutely.
        DECLARE @cheapMode bit =
            CASE WHEN @CandidateSelectExpr IS NOT NULL
                  AND @CandidateWhereSql IS NOT NULL AND LTRIM(RTRIM(@CandidateWhereSql)) <> N''
                 THEN 1 ELSE 0 END;
        DECLARE @DocExpr nvarchar(4000) = CASE WHEN @cheapMode = 1 THEN @CandidateSelectExpr ELSE @TimestampExpr END;

        -- TEMPDB SAVER: skip the ROW_NUMBER/COUNT dedup WINDOW (a sort that dominates tempdb on big runs)
        -- when the key is PROVABLY row-unique. The dedup keeps one row per key AND feeds the 50115 uniqueness
        -- gate; both are vacuous when each key already maps to exactly one row. We only skip when @KeyExpr is a
        -- clean single-column reference (t.COL) AND that column is the sole key of a UNIQUE/PK index on the
        -- source (verified from source metadata - no data scan). Otherwise we KEEP the dedup + 50115 gate, so a
        -- non-unique key can never silently over-delete. Conservative by construction.
        DECLARE @keyUnique bit = 0;
        DECLARE @keyColRaw nvarchar(256) = LTRIM(RTRIM(@KeyExpr));
        IF @keyColRaw LIKE N't.%'
           AND @keyColRaw NOT LIKE N'%(%' AND @keyColRaw NOT LIKE N'% %'
           AND @keyColRaw NOT LIKE N'%+%' AND @keyColRaw NOT LIKE N'%,%' AND @keyColRaw NOT LIKE N'%*%'
        BEGIN
            DECLARE @keyCol sysname = REPLACE(REPLACE(REPLACE(SUBSTRING(@keyColRaw, 3, 256), N'[', N''), N']', N''), N' ', N'');
            IF LEN(@keyCol) > 0 AND @keyCol NOT LIKE N'%.%'
            BEGIN
                DECLARE @tname nvarchar(512) = QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@CandidateSchema) + N'.' + QUOTENAME(@CandidateTable);
                DECLARE @uqSql nvarchar(max) = N'SELECT @u = CASE WHEN EXISTS (
                    SELECT 1 FROM ' + QUOTENAME(@SourceDb) + N'.sys.indexes i
                    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                    WHERE i.object_id = OBJECT_ID(@t) AND (i.is_unique = 1 OR i.is_primary_key = 1)
                    GROUP BY i.index_id HAVING COUNT(*) = 1 AND MAX(c.name) = @kc) THEN 1 ELSE 0 END;';
                EXEC sys.sp_executesql @uqSql, N'@t nvarchar(512), @kc sysname, @u bit OUTPUT', @t = @tname, @kc = @keyCol, @u = @keyUnique OUTPUT;
            END
        END

        DECLARE @loadSql nvarchar(max) = N'
;WITH raw AS
(
    SELECT TOP (@MaxRows)
        Key1 = CONVERT(nvarchar(256), ' + @KeyExpr + N'),
        DocCreatedAt = CONVERT(datetime2(0), ' + @DocExpr + N')
    FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@CandidateSchema) + N'.' + QUOTENAME(@CandidateTable) + N' t WITH (NOLOCK)  /* production source: candidate selection must take NO locks (rows are past the retention cutoff; the DELETE below is the authoritative, in-window mutation) */
    WHERE CONVERT(nvarchar(256), ' + @KeyExpr + N') IS NOT NULL
      AND LTRIM(RTRIM(CONVERT(nvarchar(256), ' + @KeyExpr + N'))) <> N'''' ' +
CASE
    WHEN @cheapMode = 0
        THEN N'
      AND (' + @TimestampExpr + N') < @CutoffUtc'
    ELSE N''
END +
CASE
    WHEN @CandidateAdditionalWhereSql IS NOT NULL AND LTRIM(RTRIM(@CandidateAdditionalWhereSql)) <> N''
        THEN N'
      AND (' + @CandidateAdditionalWhereSql + N')'
    ELSE N''
END +
CASE
    WHEN @CandidateWhereSql IS NOT NULL AND LTRIM(RTRIM(@CandidateWhereSql)) <> N''
        THEN N'
      AND (' + @CandidateWhereSql + N')'
    ELSE N''
END + N'
    ORDER BY ' + @OrderSql + N'
)'
+ CASE WHEN @keyUnique = 1 THEN
    -- row-unique key: no duplicates possible -> skip the window (NO sort), DupCnt is always 1
    N'
INSERT INTO #Candidates(Key1, DocCreatedAt, DupCnt)
SELECT Key1, DocCreatedAt, 1 FROM raw
OPTION (RECOMPILE);'
  ELSE
    N',
dedupe AS
(
    SELECT
        raw.*,
        rn  = ROW_NUMBER() OVER (PARTITION BY raw.Key1 ORDER BY raw.DocCreatedAt, raw.Key1),
        cnt = COUNT(*)     OVER (PARTITION BY raw.Key1)
    FROM raw
)
INSERT INTO #Candidates(Key1, DocCreatedAt, DupCnt)
SELECT
    Key1,
    DocCreatedAt,
    cnt
FROM dedupe
WHERE rn = 1
OPTION (RECOMPILE);'
  END;

        EXEC sys.sp_executesql
            @loadSql,
            N'@CutoffUtc datetime2(0), @MaxRows int',
            @CutoffUtc = @CutoffUtc,
            @MaxRows = @MaxRows;

        -- Runtime uniqueness gate (audit hardening): a TIMESTAMP candidate IS one source row, so the key
        -- must identify exactly ONE eligible row. If any key matches MULTIPLE eligible rows, the per-batch
        -- DELETE-by-key would act on rows that were never individually counted as candidates (a wider range
        -- than configured). Index validation (011) only WARNs; this blocks the real run. Empirical check on
        -- the actual data — no metadata parsing. DryRun stays a preview. THROW 50115.
        IF @DryRun = 0 AND EXISTS (SELECT 1 FROM #Candidates WHERE DupCnt > 1)
        BEGIN
            DECLARE @dupKey nvarchar(256), @dupCnt int;
            SELECT TOP (1) @dupKey = Key1, @dupCnt = DupCnt FROM #Candidates WHERE DupCnt > 1 ORDER BY DupCnt DESC;
            DECLARE @msg115 nvarchar(1000) =
                N'TIMESTAMP key is not unique among eligible rows: key ''' + @dupKey + N''' matches '
              + CONVERT(nvarchar(12), @dupCnt) + N' source rows. The keyset DELETE would touch rows that were '
              + N'never evaluated as candidates. Fix the key (ProcessKeySpec ordinal 1 must be row-unique, '
              + N'e.g. a PK/unique-indexed column) before real runs.';
            THROW 50115, @msg115, 1;
        END;

        CREATE NONCLUSTERED INDEX IX_Candidates_DocCreatedAt
        ON #Candidates(DocCreatedAt, Key1);

        -- T-21 legal-hold: drop held keys so they are never archived+deleted (reflected in the dry-run preview too).
        -- OBJECT_ID-guarded for graceful degradation when 056 is not deployed.
        IF OBJECT_ID(N'arch.LegalHold', N'U') IS NOT NULL
            DELETE c FROM #Candidates c
            WHERE EXISTS (SELECT 1 FROM arch.LegalHold lh
                          WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                            AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb)
                            AND lh.HoldKey = c.Key1 COLLATE DATABASE_DEFAULT);

        IF @DryRun = 1
        BEGIN
            SELECT
                ProcessCode = @ProcessCode,
                PreviewOnly = CONVERT(bit, 1),
                CutoffUtc = @CutoffUtc,
                CandidateRows = COUNT_BIG(*),
                MinCandidateUtc = MIN(DocCreatedAt),
                MaxCandidateUtc = MAX(DocCreatedAt)
            FROM #Candidates;

            SELECT TOP (100)
                Key1,
                DocCreatedAt
            FROM #Candidates
            ORDER BY DocCreatedAt, Key1;

            UPDATE arch.RunItem
            SET Status = N'DRYRUN',
                EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME())
            WHERE RunItemId = @RunItemId;

            UPDATE arch.Run
            SET Status = N'DRYRUN',
                EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME())
            WHERE RunId = @RunId;

            IF @AppLockTaken = 1
            BEGIN
                EXEC @ReleaseAppLockResult = sys.sp_releaseapplock
                    @Resource = @AppLockResource,
                    @LockOwner = 'Session';
                IF @ReleaseAppLockResult < 0
                    THROW 50115, 'TIMESTAMP keyset RUN failed to release applock.', 1;
                SET @AppLockTaken = 0;
            END;

            RETURN;
        END;

        CREATE TABLE #Batch
        (
            BatchId bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
            Key1 nvarchar(256) NOT NULL,
            DocCreatedAt datetime2(0) NULL
        );
        -- T-22: #Batch.Key1 is the column joined to the source key in the cross-DB DELETE — it MUST carry
        -- the source collation (see #Candidates above).
        IF @SourceCollation IS NOT NULL
            EXEC(N'ALTER TABLE #Batch ALTER COLUMN Key1 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
        CREATE UNIQUE INDEX UX_Batch_Key1 ON #Batch(Key1);

        WHILE EXISTS (SELECT 1 FROM #Candidates)
        BEGIN
            IF @StopAtUtc IS NOT NULL
               AND CONVERT(datetime2(0), SYSUTCDATETIME()) >= @StopAtUtc
                BREAK;

            -- Cooperative cancel (040): operator requested a stop from the console.
            -- The previous batch is already committed; end gracefully (Status='STOPPED').
            IF EXISTS (SELECT 1 FROM arch.Run WHERE RunId = @RunId AND CancelRequestedAtUtc IS NOT NULL)
                BREAK;

            DELETE FROM #Batch;

            INSERT INTO #Batch(Key1, DocCreatedAt)
            SELECT TOP (@BatchRowCount) Key1, DocCreatedAt
            FROM #Candidates
            ORDER BY DocCreatedAt, Key1;

            IF NOT EXISTS (SELECT 1 FROM #Batch)
                BREAK;

            BEGIN TRAN;

            DECLARE
                @RowsDeletedBatch bigint = 0,
                @RowsArchivedBatch bigint = 0,
                @DocsBatch int = (SELECT COUNT(*) FROM #Batch),
                @stmt nvarchar(max),
                @rc bigint,
                @join nvarchar(4000),
                @addWhere nvarchar(4000),
                @rDelCols nvarchar(max),
                @rTgtCols nvarchar(max),
                @rSrcCols nvarchar(max),
                @rPkPredicate nvarchar(max),
                @raSchema sysname,
                @raTable sysname,
                @rsSchema sysname,
                @rsTable sysname;

            DECLARE cRun CURSOR LOCAL FAST_FORWARD FOR
            SELECT
                SourceSchema,
                SourceTable,
                JoinToAnchorPredicateSql,
                AdditionalWhereSql,
                ArchiveSchema,
                ArchiveTable,
                DelCols,
                TgtCols,
                SrcCols,
                PkPredicate
            FROM #Obj
            ORDER BY DeleteOrder, RowNo;

            OPEN cRun;
            FETCH NEXT FROM cRun
                INTO @rsSchema, @rsTable, @join, @addWhere, @raSchema, @raTable, @rDelCols, @rTgtCols, @rSrcCols, @rPkPredicate;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- Keyset is authoritative: candidates were selected as eligible (TimestampExpr < cutoff enforced
                -- at candidate-selection time) and materialized into #Candidates/#Batch; the DELETE/COPY acts
                -- strictly on those keys. The cutoff is deliberately NOT re-evaluated per row here -- doing so
                -- re-runs the (often expensive, e.g. AT TIME ZONE) timestamp expression on every deleted row,
                -- which on a high-volume log (RF_LOG2) regressed throughput ~2.8x for no correctness gain on
                -- append-only sources (selection and delete run in the SAME run, seconds apart).
                IF @Mode = 1
                BEGIN
                    SET @stmt =
                        N'DELETE t
                          OUTPUT ' + @rDelCols + N'
                          INTO ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@raSchema) + N'.' + QUOTENAME(@raTable) + N' (' + @rTgtCols + N')
                          FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@rsSchema) + N'.' + QUOTENAME(@rsTable) + N' t
                          INNER JOIN #Batch k ON ' + @join +
                          CASE
                              WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                                  THEN N' WHERE (' + @addWhere + N')'
                              ELSE N''
                          END + N'
                          OPTION (RECOMPILE);';
                END;
                ELSE IF @Mode = 2
                BEGIN
                    -- COPY-ONLY: insert candidate rows into the archive, NEVER delete from the source, and
                    -- only rows not already in the archive (dedup by source PK). @rPkPredicate is 'a.[pk]=t.[pk]...'.
                    IF NULLIF(LTRIM(RTRIM(@rPkPredicate)), N'') IS NULL
                        THROW 50222, 'Copy-only (Mode=2) is missing the source-PK dedup predicate (no PRIMARY KEY?).', 1;
                    SET @stmt =
                        N'INSERT INTO ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@raSchema) + N'.' + QUOTENAME(@raTable) + N' (' + @rTgtCols + N')
                          SELECT ' + @rSrcCols + N'
                          FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@rsSchema) + N'.' + QUOTENAME(@rsTable) + N' t
                          INNER JOIN #Batch k ON ' + @join + N'
                          WHERE ' +
                          CASE
                              WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                                  THEN N'(' + @addWhere + N') AND '
                              ELSE N''
                          END +
                          N'NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@raSchema) + N'.' + QUOTENAME(@raTable) + N' a WHERE ' + @rPkPredicate + N')
                          OPTION (RECOMPILE);';
                END;
                ELSE
                BEGIN
                    SET @stmt =
                        N'DELETE t
                          FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@rsSchema) + N'.' + QUOTENAME(@rsTable) + N' t
                          INNER JOIN #Batch k ON ' + @join +
                          CASE
                              WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                                  THEN N' WHERE (' + @addWhere + N')'
                              ELSE N''
                          END + N'
                          OPTION (RECOMPILE);';
                END;

                EXEC (@stmt);
                SET @rc = @@ROWCOUNT;

                -- Concurrency guard (audit #4): on the KEYED candidate table, the 50115 gate proved Key1 is
                -- row-unique among eligible rows at selection time, so its per-batch DELETE must touch at most
                -- one row per batch key (i.e. @rc <= @DocsBatch). If it deleted MORE, a row sharing a batch
                -- key was inserted into the source AFTER selection — the keyset join would delete+archive it
                -- without it ever being evaluated as a candidate (a wider range than configured). Abort: the
                -- BEGIN TRAN above is rolled back by XACT_ABORT, the run is marked FAILED, and a re-run picks
                -- up a fresh, consistent candidate set. Free (a comparison, no extra scan) and only meaningful
                -- for non-row-unique keys — ROWID/PK-keyed processes never trip it. Skip Mode=2 (it INSERTs,
                -- not DELETEs, and is deduped by source PK). THROW 50116.
                IF @Mode <> 2
                   AND @rsSchema = @CandidateSchema AND @rsTable = @CandidateTable
                   AND @rc > @DocsBatch
                    THROW 50116, 'Concurrent source mutation detected: the keyed table gained rows sharing a candidate key after selection (DELETE matched more rows than candidates). Batch aborted and rolled back; re-run to reselect.', 1;

                IF EXISTS
                (
                    SELECT 1
                    FROM arch.RunItemObject rio
                    WHERE rio.RunItemId = @RunItemId
                      AND rio.SourceSchema = @rsSchema
                      AND rio.SourceTable = @rsTable
                )
                BEGIN
                    UPDATE arch.RunItemObject
                    SET RowsDeleted = RowsDeleted + CASE WHEN @Mode = 2 THEN 0 ELSE @rc END,
                        RowsArchived = RowsArchived + CASE WHEN @Mode IN (1, 2) THEN @rc ELSE 0 END
                    WHERE RunItemId = @RunItemId
                      AND SourceSchema = @rsSchema
                      AND SourceTable = @rsTable;
                END;
                ELSE
                BEGIN
                    INSERT INTO arch.RunItemObject(RunItemId, SourceSchema, SourceTable, RowsDeleted, RowsArchived)
                    VALUES (@RunItemId, @rsSchema, @rsTable, CASE WHEN @Mode = 2 THEN 0 ELSE @rc END, CASE WHEN @Mode IN (1, 2) THEN @rc ELSE 0 END);
                END;

                -- Mode=2 copies (archives) without deleting: deleted=0, archived=@rc. Mode=1: both=@rc. Mode=0: deleted=@rc, archived=0.
                SET @RowsDeletedBatch = @RowsDeletedBatch + CASE WHEN @Mode = 2 THEN 0 ELSE @rc END;
                SET @RowsArchivedBatch = @RowsArchivedBatch + CASE WHEN @Mode IN (1, 2) THEN @rc ELSE 0 END;

                FETCH NEXT FROM cRun
                    INTO @rsSchema, @rsTable, @join, @addWhere, @raSchema, @raTable, @rDelCols, @rTgtCols, @rSrcCols, @rPkPredicate;
            END;

            CLOSE cRun;
            DEALLOCATE cRun;

            IF @AuditLevel = N'ROW'
            BEGIN
                INSERT INTO arch.RunDocAudit(RunItemId, ProcessCode, DocKeyLabel, DocKey, DocCreatedAt, Archived)
                SELECT
                    @RunItemId,
                    @ProcessCode,
                    @DocKeyLabel,
                    b.Key1,
                    b.DocCreatedAt,
                    CASE WHEN @Mode IN (1, 2) THEN 1 ELSE 0 END   -- Mode=2 copy also archives the doc
                FROM #Batch b;
            END;

            UPDATE arch.RunItem
            SET BatchesDone = BatchesDone + 1,
                DocsDone = DocsDone + @DocsBatch,
                RowsDeleted = RowsDeleted + @RowsDeletedBatch,
                RowsArchived = RowsArchived + @RowsArchivedBatch
            WHERE RunItemId = @RunItemId;

            DELETE c
            FROM #Candidates c
            INNER JOIN #Batch b
              ON b.Key1 = c.Key1;

            -- T-04: enforce the Mode=1 invariant (RowsArchived == RowsDeleted) before COMMIT, mirroring
            -- the ANCHOR runner (015_usp_RunPreparedBatch). DELETE ... OUTPUT INTO is atomic so the per-
            -- object counts match by construction today; this is defense-in-depth that fails the batch
            -- (XACT_ABORT -> rollback) if a future change, a mis-set Mode, or a partial multi-object
            -- failure ever leaves a Mode=1 object with deleted-without-archived rows. (Independent
            -- archive read-back verification is the stronger guarantee and is tracked separately as T-19.)
            IF @Mode = 1
            BEGIN
                IF EXISTS
                (
                    SELECT 1
                    FROM arch.RunItemObject rio
                    WHERE rio.RunItemId = @RunItemId
                      AND ISNULL(rio.RowsDeleted, 0) > 0
                      AND ISNULL(rio.RowsArchived, 0) <> ISNULL(rio.RowsDeleted, 0)
                )
                BEGIN
                    DECLARE @divg nvarchar(4000);
                    SELECT @divg =
                        STUFF((
                            SELECT TOP (50)
                                N'; ' + rio.SourceTable
                                + N' del=' + CONVERT(nvarchar(20), ISNULL(rio.RowsDeleted, 0))
                                + N' arc=' + CONVERT(nvarchar(20), ISNULL(rio.RowsArchived, 0))
                            FROM arch.RunItemObject rio
                            WHERE rio.RunItemId = @RunItemId
                              AND ISNULL(rio.RowsDeleted, 0) > 0
                              AND ISNULL(rio.RowsArchived, 0) <> ISNULL(rio.RowsDeleted, 0)
                            FOR XML PATH(''), TYPE
                        ).value('.', 'nvarchar(max)'), 1, 2, N'');

                    RAISERROR(N'Archive/Delete mismatch (Mode=1). %s', 16, 1, @divg);
                END;
            END;

            COMMIT;

            IF @DelayStr IS NOT NULL
               AND (@StopAtUtc IS NULL OR CONVERT(datetime2(0), SYSUTCDATETIME()) < @StopAtUtc)
                WAITFOR DELAY @DelayStr;
        END;

        DECLARE @FinalStatus nvarchar(20) =
            CASE WHEN EXISTS (SELECT 1 FROM arch.Run WHERE RunId = @RunId AND CancelRequestedAtUtc IS NOT NULL)
                 THEN N'STOPPED' ELSE N'OK' END;

        UPDATE arch.RunItem
        SET Status = @FinalStatus,
            EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME())
        WHERE RunItemId = @RunItemId;

        UPDATE arch.Run
        SET Status = @FinalStatus,
            EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME())
        WHERE RunId = @RunId;

        IF @AppLockTaken = 1
        BEGIN
            EXEC @ReleaseAppLockResult = sys.sp_releaseapplock
                @Resource = @AppLockResource,
                @LockOwner = 'Session';
            IF @ReleaseAppLockResult < 0
                THROW 50320, 'TIMESTAMP keyset RUN failed to RELEASE applock (Session lock may remain held).', 1;
            SET @AppLockTaken = 0;
        END;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK;

        DECLARE @err nvarchar(max) = ERROR_MESSAGE();

        IF @RunItemId IS NOT NULL
        BEGIN
            UPDATE arch.RunItem
            SET Status = N'FAILED',
                EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME()),
                ErrorMessage = @err
            WHERE RunItemId = @RunItemId;
        END;

        IF @RunId IS NOT NULL
        BEGIN
            UPDATE arch.Run
            SET Status = N'FAILED',
                EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME()),
                ErrorMessage = @err
            WHERE RunId = @RunId;
        END;

        IF @AppLockTaken = 1
        BEGIN
            EXEC @ReleaseAppLockResult = sys.sp_releaseapplock
                @Resource = @AppLockResource,
                @LockOwner = 'Session';
            SET @AppLockTaken = 0;
            -- Surface a release failure WITHOUT masking the original error (fold into the message).
            IF @ReleaseAppLockResult < 0
                SET @err = @err + N' [applock release also failed — Session lock may remain held]';
        END;

        RAISERROR(N'arch.usp_RunTimestampProcess failed: %s', 16, 1, @err);
        RETURN;
    END CATCH;
END
GO

PRINT 'Step 1: arch.usp_RunTimestampProcess created (internal worker for TIMESTAMP strategy)'
-- <<< end: kArchiveManagerAdmin\v2\027_usp_RunTimestampProcess.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\016_usp_RunPreparedBatches.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_RunPreparedBatches_InWindow]
    @ProcessCode sysname,
    @SourceDb sysname = NULL,
    @StopAtUtc datetime2(0),
    @DryRun bit = 0,
    @PausedCooldownSeconds int = 60
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
    BEGIN
        RAISERROR(N'2.0 metadata is not installed. Run v2/010_universal_archive_core.sql first.', 16, 1);
        RETURN;
    END;

    DECLARE
        @ProcessId int,
        @MaxBatches int,
        @DelayMs int,
        @UseAppLock bit,
        @AppLockResource nvarchar(200),
        @LockTimeoutMs int,
        @i int = 0,
        @wb bigint = NULL,
        @lres int,
        @DelayStr varchar(20) = NULL,
        @AppLockTaken bit = 0,
        @AppLockOverride nvarchar(200),
        @AppLockParent nvarchar(200) = N'KARCHIVE_MANAGER:' + @ProcessCode,
        @ParentLockTaken bit = 0;

    SELECT TOP (1)
        @ProcessId = e.ProcessId,
        @MaxBatches = COALESCE(e.MaxBatchesPerRun, 100000),
        @DelayMs = COALESCE(e.DelayMsBetweenBatches, 0),
        @UseAppLock = e.UseAppLock,
        @AppLockOverride = NULLIF(e.AppLockResource, N''),
        @AppLockResource = COALESCE(NULLIF(e.AppLockResource, N''), N'KARCHIVE_MANAGER:' + e.ProcessCode + COALESCE(N':' + @SourceDb, N'')),
        @LockTimeoutMs = COALESCE(e.LockTimeoutMs, 10000)
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessCode = @ProcessCode
      AND e.IsEnabled = 1
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
    ORDER BY CASE WHEN e.SourceDb = @SourceDb THEN 0 ELSE 1 END, e.RunOrder, e.ProcessDatabaseId;

    IF @ProcessId IS NULL
    BEGIN
        RAISERROR(N'Process not found or disabled: %s', 16, 1, @ProcessCode);
        RETURN;
    END;

    IF @DelayMs > 0
    BEGIN
        DECLARE @h int = @DelayMs / 3600000;
        DECLARE @m int = (@DelayMs % 3600000) / 60000;
        DECLARE @s int = (@DelayMs % 60000) / 1000;
        DECLARE @ms int = @DelayMs % 1000;

        SET @DelayStr =
            RIGHT('00' + CONVERT(varchar(2), @h), 2) + ':' +
            RIGHT('00' + CONVERT(varchar(2), @m), 2) + ':' +
            RIGHT('00' + CONVERT(varchar(2), @s), 2) + '.' +
            RIGHT('000' + CONVERT(varchar(3), @ms), 3);
    END;

    IF @UseAppLock = 1
    BEGIN
        -- Lock hierarchy (audit hardening): a process-wide invocation (@SourceDb IS NULL) takes the parent
        -- resource 'KARCHIVE_MANAGER:<PC>' EXCLUSIVE, while a per-DB invocation takes that parent SHARED
        -- (intent) + its own child '...:<PC>:<src>' EXCLUSIVE. Previously the two grains were different
        -- resource strings that did NOT mutually exclude, so a NULL-scope run could race a per-DB run on
        -- the same process+DB. Parent is always acquired FIRST (deadlock-safe ordering); two different
        -- source DBs still run concurrently (Shared+Shared). An explicit AppLockResource override keeps
        -- the single-resource behavior (the operator took control of the grain).
        IF @AppLockOverride IS NULL AND @SourceDb IS NOT NULL
        BEGIN
            EXEC @lres = sys.sp_getapplock
                @Resource = @AppLockParent,
                @LockMode = 'Shared',
                @LockOwner = 'Session',
                @LockTimeout = @LockTimeoutMs;

            IF @lres < 0
            BEGIN
                RAISERROR(N'arch.usp_RunPreparedBatches_InWindow failed to acquire parent applock: %s', 16, 1, @AppLockParent);
                RETURN;
            END;

            SET @ParentLockTaken = 1;
        END;

        EXEC @lres = sys.sp_getapplock
            @Resource = @AppLockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Session',
            @LockTimeout = @LockTimeoutMs;

        IF @lres < 0
        BEGIN
            IF @ParentLockTaken = 1
                EXEC sys.sp_releaseapplock @Resource = @AppLockParent, @LockOwner = 'Session';
            RAISERROR(N'arch.usp_RunPreparedBatches_InWindow failed to acquire applock: %s', 16, 1, @AppLockResource);
            RETURN;
        END;

        SET @AppLockTaken = 1;
    END;

    BEGIN TRY
        WHILE SYSUTCDATETIME() < @StopAtUtc AND @i < @MaxBatches
        BEGIN
            SET @i += 1;
            SET @wb = NULL;

            ;WITH candidates AS
            (
                SELECT
                    wb.WorkBatchId,
                    wb.Status,
                    wb.PreparedAtUtc,
                    wb.LastProgressAtUtc,
                    sort1 = CASE WHEN wb.Status = 'Prepared' THEN 0 ELSE 1 END
                FROM arch.WorkBatch wb
                WHERE wb.ProcessId = @ProcessId
                  AND (@SourceDb IS NULL OR wb.SourceDb = @SourceDb)
                  AND wb.Status IN ('Prepared','Paused')
                  AND (
                        wb.Status = 'Prepared'
                        OR wb.LastProgressAtUtc IS NULL
                        OR wb.LastProgressAtUtc < DATEADD(SECOND, -@PausedCooldownSeconds, CONVERT(datetime2(0), SYSUTCDATETIME()))
                      )
            )
            SELECT TOP (1) @wb = c.WorkBatchId
            FROM candidates c
            ORDER BY c.sort1, c.PreparedAtUtc, c.WorkBatchId;

            IF @wb IS NULL
                BREAK;

            EXEC arch.usp_RunPreparedBatch
                @WorkBatchId = @wb,
                @StopAtUtc = @StopAtUtc,
                @DryRun = @DryRun;

            IF @DelayStr IS NOT NULL
                WAITFOR DELAY @DelayStr;
        END;

        IF @AppLockTaken = 1
        BEGIN
            EXEC @lres = sys.sp_releaseapplock @Resource = @AppLockResource, @LockOwner = 'Session';
            SET @AppLockTaken = 0;
            -- A silent release failure would leave the Session-scoped lock held for the rest of the session,
            -- blocking every subsequent process+DB run in this orchestrator pass. Fail loudly instead.
            IF @lres < 0
                RAISERROR(N'arch.usp_RunPreparedBatches_InWindow failed to RELEASE applock (result %d); the Session lock may remain held: %s', 16, 1, @lres, @AppLockResource);
        END;
        IF @ParentLockTaken = 1
        BEGIN
            EXEC @lres = sys.sp_releaseapplock @Resource = @AppLockParent, @LockOwner = 'Session';
            SET @ParentLockTaken = 0;
            IF @lres < 0
                RAISERROR(N'arch.usp_RunPreparedBatches_InWindow failed to RELEASE parent applock (result %d); the Session lock may remain held: %s', 16, 1, @lres, @AppLockParent);
        END;
    END TRY
    BEGIN CATCH
        -- Surface a release failure WITHOUT masking the original error: fold it into the message.
        DECLARE @relNote nvarchar(200) = N'';
        IF @AppLockTaken = 1
        BEGIN
            EXEC @lres = sys.sp_releaseapplock @Resource = @AppLockResource, @LockOwner = 'Session';
            IF @lres < 0 SET @relNote = @relNote + N' [applock release failed]';
        END;
        IF @ParentLockTaken = 1
        BEGIN
            EXEC @lres = sys.sp_releaseapplock @Resource = @AppLockParent, @LockOwner = 'Session';
            IF @lres < 0 SET @relNote = @relNote + N' [parent applock release failed]';
        END;

        DECLARE @err nvarchar(4000) = ERROR_MESSAGE();
        RAISERROR(N'arch.usp_RunPreparedBatches_InWindow failed: %s%s', 16, 1, @err, @relNote);
        RETURN;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_RunConfiguredProcesses_Prepared]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @StopAtUtc datetime2(0) = NULL,
    @DryRun bit = 0,
    @MaxCandidates int = NULL,
    @PausedCooldownSeconds int = 60,
    -- Two-phase split for the PREP/RUN Agent jobs. BOTH = prepare+run (default, back-compat);
    -- PREP = ANCHOR candidate preparation only (TIMESTAMP is single-phase -> no-op in PREP);
    -- RUN = run prepared ANCHOR batches + run TIMESTAMP processes (no preparation).
    @Phase varchar(4) = 'BOTH'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
    BEGIN
        RAISERROR(N'2.0 metadata is not installed. Run v2/010_universal_archive_core.sql first.', 16, 1);
        RETURN;
    END;

    SET @Phase = UPPER(NULLIF(LTRIM(RTRIM(@Phase)), N''));
    IF @Phase IS NULL SET @Phase = N'BOTH';
    IF @Phase NOT IN (N'BOTH', N'PREP', N'RUN')
        THROW 50117, 'Invalid @Phase (expected BOTH, PREP or RUN).', 1;

    IF @StopAtUtc IS NULL
        SET @StopAtUtc = DATEADD(MINUTE, 55, CONVERT(datetime2(0), SYSUTCDATETIME()));

    DECLARE
        @p sysname,
        @src sysname,
        @arc sysname,
        @pid int,
        @strategy nvarchar(30),
        @wb bigint,
        @openWb bigint,
        @failCount int = 0,
        @firstErr nvarchar(2000) = NULL;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        e.ProcessId,
        COALESCE(e.SelectionStrategy, N'ANCHOR') AS SelectionStrategy
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR e.ArchiveDb = @ArchiveDb)
    ORDER BY e.RunOrder, e.ProcessCode, e.SourceDb, e.ProcessDatabaseId;

    OPEN c;
    FETCH NEXT FROM c INTO @p, @src, @arc, @pid, @strategy;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF CONVERT(datetime2(0), SYSUTCDATETIME()) >= @StopAtUtc
            BREAK;

        -- Failure isolation: each (process, source DB) runs inside its own TRY/CATCH so one failure
        -- does NOT abort the rest of the nightly queue. The inner proc already records its FAILED run;
        -- here we tally and continue, then surface an aggregate error after the loop (so the Agent job
        -- step reports failure and alerting fires) without having skipped later processes.
        BEGIN TRY
            IF @strategy = N'TIMESTAMP'
            BEGIN
                -- TIMESTAMP is single-phase (keyset) — no separate prepare. Runs in BOTH/RUN; no-op in PREP.
                IF @Phase IN (N'BOTH', N'RUN')
                BEGIN
                    IF OBJECT_ID(N'arch.usp_RunTimestampProcess', N'P') IS NULL
                        THROW 50130, 'TIMESTAMP process requires arch.usp_RunTimestampProcess (run v2/027_usp_RunTimestampProcess.sql first).', 1;

                    EXEC arch.usp_RunTimestampProcess
                        @ProcessCode = @p,
                        @SourceDb = @src,
                        @ArchiveDb = @arc,
                        @AsOfUtc = NULL,
                        @StopAtUtc = @StopAtUtc,
                        @BatchRowCount = NULL,
                        @MaxRows = @MaxCandidates,
                        @DryRun = @DryRun;
                END
            END
            ELSE
            BEGIN
                SET @wb = NULL;
                SET @openWb = NULL;

                SELECT TOP (1) @openWb = wb.WorkBatchId
                FROM arch.WorkBatch wb
                WHERE wb.ProcessId = @pid
                  AND wb.SourceDb = @src
                  AND wb.ArchiveDb = @arc
                  AND wb.Status IN ('Prepared','Running','Paused')
                ORDER BY wb.WorkBatchId;

                -- PREP phase: build the WorkBatch (only if none is already open). Skipped in RUN phase.
                IF @Phase IN (N'BOTH', N'PREP') AND @openWb IS NULL
                BEGIN
                    EXEC arch.usp_PrepareCandidates
                        @ProcessCode = @p,
                        @SourceDb = @src,
                        @ArchiveDb = @arc,
                        @MaxCandidates = @MaxCandidates,
                        @WorkBatchId = @wb OUTPUT;
                END;

                -- RUN phase: process prepared batches in the window. Skipped in PREP phase.
                IF @Phase IN (N'BOTH', N'RUN')
                    EXEC arch.usp_RunPreparedBatches_InWindow
                        @ProcessCode = @p,
                        @SourceDb = @src,
                        @StopAtUtc = @StopAtUtc,
                        @DryRun = @DryRun,
                        @PausedCooldownSeconds = @PausedCooldownSeconds;
            END
        END TRY
        BEGIN CATCH
            -- A doomed transaction from the failed process must not bleed into the next iteration.
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            SET @failCount += 1;
            IF @firstErr IS NULL
                SET @firstErr = LEFT(CONCAT(@p, N'/', @src, N': ', ERROR_MESSAGE()), 2000);
        END CATCH

        FETCH NEXT FROM c INTO @p, @src, @arc, @pid, @strategy;
    END

    CLOSE c;
    DEALLOCATE c;

    IF @failCount > 0
        RAISERROR(N'usp_RunConfiguredProcesses_Prepared: %d process(es) failed; first failure: %s', 16, 1, @failCount, @firstErr);
END
GO
-- <<< end: kArchiveManagerAdmin\v2\016_usp_RunPreparedBatches.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\020_usp_RunProfile_Prepared.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Validated version (P1.3): fail fast with THROW 50001/50002/50003 when the
-- prepared infrastructure is missing or the profile is invalid. Mirrors the
-- canonical definition deployed by v2/025_p1_3_block_legacy_procedures.sql.
CREATE OR ALTER PROCEDURE [arch].[usp_RunProfile_Prepared]
    @RunProfileCode sysname,
    -- BOTH (default/back-compat) | PREP (prepare ANCHOR candidates only) | RUN (run prepared + TIMESTAMP).
    -- Lets the separate PREP and RUN Agent jobs share one run profile.
    @Phase varchar(4) = 'BOTH'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'arch.RunProfile', N'U') IS NULL
    BEGIN
        THROW 50001, 'arch.RunProfile table does not exist', 1;
    END;

    IF OBJECT_ID(N'arch.usp_RunConfiguredProcesses_Prepared', N'P') IS NULL
    BEGIN
        THROW 50001, 'arch.usp_RunConfiguredProcesses_Prepared procedure not found', 1;
    END;

    DECLARE @ProcessCode sysname,
            @SourceDb sysname,
            @ArchiveDb sysname,
            @RunWindowMinutes int,
            @DryRun bit,
            @MaxCandidates int,
            @PausedCooldownSeconds int,
            @StopAtUtc datetime2(0);

    SELECT @ProcessCode = NULLIF(LTRIM(RTRIM(ProcessCodeFilter)), N''),
           @SourceDb = NULLIF(LTRIM(RTRIM(SourceDbFilter)), N''),
           @ArchiveDb = NULLIF(LTRIM(RTRIM(ArchiveDbFilter)), N''),
           @RunWindowMinutes = RunWindowMinutes,
           @DryRun = DryRun,
           @MaxCandidates = MaxCandidates,
           @PausedCooldownSeconds = PausedCooldownSeconds
    FROM arch.RunProfile
    WHERE RunProfileCode = @RunProfileCode
      AND IsEnabled = 1;

    IF @RunWindowMinutes IS NULL
    BEGIN
        THROW 50002, 'Run profile not found or disabled', 1;
    END;

    IF @RunWindowMinutes <= 0 OR @PausedCooldownSeconds < 0 OR (@MaxCandidates IS NOT NULL AND @MaxCandidates <= 0)
    BEGIN
        THROW 50003, 'Run profile has invalid runtime limits', 1;
    END;

    SET @StopAtUtc = DATEADD(MINUTE, @RunWindowMinutes, CONVERT(datetime2(0), SYSUTCDATETIME()));

    EXEC arch.usp_RunConfiguredProcesses_Prepared
        @ProcessCode = @ProcessCode,
        @SourceDb = @SourceDb,
        @ArchiveDb = @ArchiveDb,
        @StopAtUtc = @StopAtUtc,
        @DryRun = @DryRun,
        @MaxCandidates = @MaxCandidates,
        @PausedCooldownSeconds = @PausedCooldownSeconds,
        @Phase = @Phase;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_RunScheduledProfiles_Prepared]
    @RunProfileCode sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'arch.RunProfile', N'U') IS NULL
    BEGIN
        RAISERROR(N'arch.RunProfile does not exist. Run v2/010_universal_archive_core.sql first.', 16, 1);
        RETURN;
    END;

    DECLARE @profile sysname;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT RunProfileCode
    FROM arch.RunProfile
    WHERE IsEnabled = 1
      AND RunOnSchedule = 1
      AND (@RunProfileCode IS NULL OR RunProfileCode = @RunProfileCode)
    ORDER BY RunOrder, RunProfileCode;

    OPEN c;
    FETCH NEXT FROM c INTO @profile;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC arch.usp_RunProfile_Prepared @RunProfileCode = @profile;
        FETCH NEXT FROM c INTO @profile;
    END;

    CLOSE c;
    DEALLOCATE c;
END
GO
-- <<< end: kArchiveManagerAdmin\v2\020_usp_RunProfile_Prepared.sql
GO
GO
-- 020 also creates usp_RunScheduledProfiles_Prepared, a superseded scheduler with NO callers
-- (the RUN CONFIGURED job calls usp_RunProfile_Prepared directly). Drop it so the clean install
-- carries nothing extra.
USE [kArchiveManagerAdmin];
GO
DROP PROCEDURE IF EXISTS [arch].[usp_RunScheduledProfiles_Prepared];
GO
-- >>> inlined: kArchiveManagerAdmin\v2\030_usp_RecoverStaleRuns.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/**
 * ============================================================================
 * arch.usp_RecoverStaleRuns
 * ============================================================================
 *
 * Purpose:
 *   Detect and recover stale Run/RunItem/WorkBatch records that did not
 *   complete their lifecycle (e.g., session terminated, server restart,
 *   client disconnect during execution).
 *
 * Recovery logic:
 *   1. Stale Run: Status='RUNNING' and StartedAt < (now - @StaleAfterMinutes)
 *      → Check related RunItem status:
 *        - If RunItem='OK': fix Run.Status='OK', EndedAt = max(RunItem.EndedAt)
 *        - If RunItem='RUNNING': mark as FAILED with reason
 *        - If RunItem='FAILED': fix Run.Status='FAILED', EndedAt = max(RunItem.EndedAt)
 *
 *   2. Stale WorkBatch: Status='Running' and LastProgressAtUtc < (now - @StaleAfterMinutes)
 *      → If WorkBatchKey has no Status=0 or 1 (all done): Status='Completed'
 *      → Otherwise: Status='Paused' (can resume on next run)
 *
 * Parameters:
 *   @StaleAfterMinutes - timeout threshold (default: 30 min)
 *   @DryRun - 1 = preview only, 0 = apply changes
 *   @MaxRecoveries - safety limit (default: 100)
 *
 * Output:
 *   Result set with recovered records
 *
 * Schedule: Recommended to run as SQL Agent job every 15 minutes
 *
 * Created: 2026-05-28
 * Version: 1.0
 * ============================================================================
 */

CREATE OR ALTER PROCEDURE arch.usp_RecoverStaleRuns
    @StaleAfterMinutes int = 30,
    @DryRun bit = 0,
    @MaxRecoveries int = 100,
    @VerboseOutput bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now datetime2(0) = SYSUTCDATETIME();
    DECLARE @StaleThreshold datetime2(0) = DATEADD(MINUTE, -@StaleAfterMinutes, @Now);
    DECLARE @StaleReason nvarchar(200);
    SET @StaleReason = N'Recovered by usp_RecoverStaleRuns after ' + CAST(@StaleAfterMinutes AS varchar(10)) + N' minutes of inactivity';

    -- =========================================================================
    -- COLLECT: Stale runs
    -- =========================================================================
    DECLARE @StaleRuns TABLE (
        RunId bigint NOT NULL PRIMARY KEY,
        ProcessCode sysname NULL,
        SourceDb sysname NULL,
        StartedAt datetime2 NULL,
        MinutesRunning int NULL,
        RunItemStatus nvarchar(40) NULL,
        RunItemEndedAt datetime2 NULL,
        RowsArchived bigint NULL,
        RowsDeleted bigint NULL,
        Action nvarchar(20) NULL,
        Reason nvarchar(200) NULL
    );

    INSERT INTO @StaleRuns (RunId, ProcessCode, SourceDb, StartedAt, MinutesRunning, RunItemStatus, RunItemEndedAt, RowsArchived, RowsDeleted)
    SELECT TOP (@MaxRecoveries)
        r.RunId,
        p.ProcessCode,
        r.SourceDb,
        r.StartedAt,
        DATEDIFF(MINUTE, r.StartedAt, @Now),
        ri.Status,
        ri.EndedAt,
        ri.RowsArchived,
        ri.RowsDeleted
    FROM arch.Run r
    LEFT JOIN arch.RunItem ri ON r.RunId = ri.RunId
    LEFT JOIN arch.Process p ON ri.ProcessId = p.ProcessId
    WHERE r.Status = N'RUNNING'
      AND (r.EndedAt IS NULL)
      AND r.StartedAt < @StaleThreshold
      -- T-03: never recover a run whose worker session is still alive — this eliminates the
      -- recovery-vs-live-run race (a legitimate run can run up to RunWindowMinutes, well past the
      -- stale threshold). A run is recoverable only if it predates session tracking (WorkerSessionId
      -- NULL = older than the 044 deploy, worker definitely gone) OR no live session matches its SPID.
      AND (r.WorkerSessionId IS NULL
           OR NOT EXISTS (SELECT 1 FROM sys.dm_exec_sessions s
                          WHERE s.session_id = r.WorkerSessionId
                            AND s.login_time = r.WorkerSessionLoginTimeUtc))
    ORDER BY r.RunId;

    -- Decide action per Run (smart detection of likely outcome)
    UPDATE @StaleRuns
    SET Action = CASE
            -- RunItem explicitly closed:
            WHEN RunItemStatus = N'OK' THEN N'CLOSE_OK'
            WHEN RunItemStatus = N'FAILED' THEN N'CLOSE_FAILED'
            WHEN RunItemStatus = N'DRYRUN' THEN N'CLOSE_DRYRUN'
            -- RunItem stuck in RUNNING with a dead worker session (we only reach here once the
            -- worker is provably gone). T-03: NEVER infer success from transient equal counters — a
            -- run killed mid-way shows archived==deleted for the batches it finished while candidates
            -- remain. Always mark FAILED so the next run idempotently re-processes the remainder.
            WHEN RunItemStatus = N'RUNNING' THEN N'MARK_FAILED'
            WHEN RunItemStatus IS NULL THEN N'MARK_FAILED'
            ELSE N'INVESTIGATE'
        END,
        Reason = CASE
            WHEN RunItemStatus = N'OK' THEN N'RunItem completed OK but Run was not closed (orphaned by session disconnect)'
            WHEN RunItemStatus = N'FAILED' THEN N'RunItem failed but Run was not closed'
            WHEN RunItemStatus = N'DRYRUN' THEN N'DryRun completed but Run was not closed'
            WHEN RunItemStatus = N'RUNNING'
                THEN N'Worker session ended while run was RUNNING (archived='
                     + CAST(ISNULL(RowsArchived, 0) AS varchar(20))
                     + N' deleted=' + CAST(ISNULL(RowsDeleted, 0) AS varchar(20))
                     + N'); marked FAILED for safe re-processing — success is never inferred.'
            WHEN RunItemStatus IS NULL THEN N'Run has no RunItem (incomplete initialization)'
            ELSE N'Unknown state - manual investigation required'
        END;

    -- =========================================================================
    -- COLLECT: Stale workbatches
    -- =========================================================================
    DECLARE @StaleBatches TABLE (
        WorkBatchId bigint NOT NULL PRIMARY KEY,
        ProcessCode sysname NULL,
        SourceDb sysname NULL,
        LastProgressAtUtc datetime2 NULL,
        MinutesSinceProgress int NULL,
        OpenKeys int NULL,
        Action nvarchar(20) NULL,
        Reason nvarchar(200) NULL
    );

    INSERT INTO @StaleBatches (WorkBatchId, ProcessCode, SourceDb, LastProgressAtUtc, MinutesSinceProgress, OpenKeys)
    SELECT TOP (@MaxRecoveries)
        wb.WorkBatchId,
        p.ProcessCode,
        wb.SourceDb,
        wb.LastProgressAtUtc,
        DATEDIFF(MINUTE, COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc), @Now),
        (SELECT COUNT(*) FROM arch.WorkBatchKey wbk WHERE wbk.WorkBatchId = wb.WorkBatchId AND wbk.Status IN (0, 1))
    FROM arch.WorkBatch wb
    LEFT JOIN arch.Process p ON wb.ProcessId = p.ProcessId
    WHERE wb.Status = N'Running'
      AND COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc) < @StaleThreshold
    ORDER BY wb.WorkBatchId;

    UPDATE @StaleBatches
    SET Action = CASE
            WHEN OpenKeys = 0 THEN N'CLOSE_COMPLETE'
            ELSE N'PAUSE_FOR_RETRY'
        END,
        Reason = CASE
            WHEN OpenKeys = 0 THEN N'All keys processed but batch was not marked Completed'
            ELSE N'No progress for ' + CAST(MinutesSinceProgress AS varchar(10)) + N' min, ' + CAST(OpenKeys AS varchar(10)) + N' keys still pending'
        END;

    -- =========================================================================
    -- APPLY RECOVERIES (if not DryRun)
    -- =========================================================================
    IF @DryRun = 0
    BEGIN
        BEGIN TRANSACTION;

        -- Close OK runs (RunItem was already OK)
        UPDATE r
        SET r.Status = N'OK',
            r.EndedAt = COALESCE(sr.RunItemEndedAt, @Now)
        FROM arch.Run r
        INNER JOIN @StaleRuns sr ON r.RunId = sr.RunId
        WHERE sr.Action = N'CLOSE_OK';

        -- T-03: CLOSE_OK_INFERRED removed — recovery never marks a still-RUNNING run OK. Such runs
        -- now take the MARK_FAILED path below (safe re-processing on the next run).

        -- Close FAILED runs
        UPDATE r
        SET r.Status = N'FAILED',
            r.EndedAt = COALESCE(sr.RunItemEndedAt, @Now),
            r.ErrorMessage = COALESCE(r.ErrorMessage, sr.Reason)
        FROM arch.Run r
        INNER JOIN @StaleRuns sr ON r.RunId = sr.RunId
        WHERE sr.Action = N'CLOSE_FAILED';

        -- Close DRYRUN runs
        UPDATE r
        SET r.Status = N'DRYRUN',
            r.EndedAt = COALESCE(sr.RunItemEndedAt, @Now)
        FROM arch.Run r
        INNER JOIN @StaleRuns sr ON r.RunId = sr.RunId
        WHERE sr.Action = N'CLOSE_DRYRUN';

        -- Mark stuck (still RUNNING) as FAILED
        UPDATE ri
        SET ri.Status = N'FAILED',
            ri.EndedAt = @Now,
            ri.ErrorMessage = sr.Reason
        FROM arch.RunItem ri
        INNER JOIN @StaleRuns sr ON ri.RunId = sr.RunId
        WHERE sr.Action = N'MARK_FAILED';

        UPDATE r
        SET r.Status = N'FAILED',
            r.EndedAt = @Now,
            r.ErrorMessage = sr.Reason
        FROM arch.Run r
        INNER JOIN @StaleRuns sr ON r.RunId = sr.RunId
        WHERE sr.Action = N'MARK_FAILED';

        -- Close stale workbatches
        UPDATE wb
        SET wb.Status = N'Completed',
            wb.CompletedAtUtc = @Now
        FROM arch.WorkBatch wb
        INNER JOIN @StaleBatches sb ON wb.WorkBatchId = sb.WorkBatchId
        WHERE sb.Action = N'CLOSE_COMPLETE';

        UPDATE wb
        SET wb.Status = N'Paused',
            wb.Notes = sb.Reason
        FROM arch.WorkBatch wb
        INNER JOIN @StaleBatches sb ON wb.WorkBatchId = sb.WorkBatchId
        WHERE sb.Action = N'PAUSE_FOR_RETRY';

        -- Reset claimed keys (so they can be retried)
        UPDATE wbk
        SET wbk.Status = 0,
            wbk.ClaimedAtUtc = NULL,
            wbk.ClaimedBy = NULL
        FROM arch.WorkBatchKey wbk
        INNER JOIN @StaleBatches sb ON wbk.WorkBatchId = sb.WorkBatchId
        WHERE sb.Action = N'PAUSE_FOR_RETRY'
          AND wbk.Status = 1;

        COMMIT TRANSACTION;
    END;

    -- =========================================================================
    -- OUTPUT: Report
    -- =========================================================================
    IF @VerboseOutput = 1
    BEGIN
        PRINT N'============================================================================';
        PRINT N'arch.usp_RecoverStaleRuns - Recovery Report';
        PRINT N'============================================================================';
        PRINT N'Mode: ' + CASE WHEN @DryRun = 1 THEN N'DRY RUN (preview only)' ELSE N'APPLIED' END;
        PRINT N'Stale threshold: ' + CAST(@StaleAfterMinutes AS varchar(10)) + N' minutes';
        PRINT N'Current UTC time: ' + CONVERT(varchar(30), @Now, 121);
        PRINT N'';

        DECLARE @RunRecCount int = (SELECT COUNT(*) FROM @StaleRuns);
        DECLARE @BatchRecCount int = (SELECT COUNT(*) FROM @StaleBatches);

        PRINT N'Stale Runs found: ' + CAST(@RunRecCount AS varchar(10));
        PRINT N'Stale WorkBatches found: ' + CAST(@BatchRecCount AS varchar(10));
        PRINT N'';
    END;

    -- Result set 1: Stale runs
    SELECT
        [Result] = N'RUN',
        RunId,
        ProcessCode,
        SourceDb,
        StartedAt,
        MinutesRunning,
        RunItemStatus,
        RowsArchived,
        RowsDeleted,
        Action,
        Reason
    FROM @StaleRuns
    ORDER BY RunId;

    -- Result set 2: Stale workbatches
    SELECT
        [Result] = N'WORKBATCH',
        WorkBatchId,
        ProcessCode,
        SourceDb,
        LastProgressAtUtc,
        MinutesSinceProgress,
        OpenKeys,
        Action,
        Reason
    FROM @StaleBatches
    ORDER BY WorkBatchId;

END;
GO

PRINT N'✅ arch.usp_RecoverStaleRuns created/updated';
PRINT N'';
PRINT N'Usage examples:';
PRINT N'  EXEC arch.usp_RecoverStaleRuns @DryRun = 1;                  -- Preview';
PRINT N'  EXEC arch.usp_RecoverStaleRuns @DryRun = 0;                  -- Apply (default 30 min)';
PRINT N'  EXEC arch.usp_RecoverStaleRuns @StaleAfterMinutes = 60;      -- Apply with 60-min threshold';
GO
-- <<< end: kArchiveManagerAdmin\v2\030_usp_RecoverStaleRuns.sql
GO
GO

-- ---- Phase 11: restore (after GetOutputColumns) + audit immutability DENY ----
-- >>> inlined: kArchiveManagerAdmin\v2\042_usp_RestoreFromArchive.sql
USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- T-27: append-only audit of every real restore (and archive purge). Created here so it travels with 042.
IF OBJECT_ID(N'arch.RestoreAudit', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[RestoreAudit]
    (
        RestoreAuditId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_RestoreAudit PRIMARY KEY,
        OccurredAtUtc  datetime2(3) NOT NULL CONSTRAINT DF_RestoreAudit_OccurredAtUtc DEFAULT (SYSUTCDATETIME()),
        RequestedBy    nvarchar(256) NULL,
        ActorLogin     sysname NOT NULL CONSTRAINT DF_RestoreAudit_ActorLogin DEFAULT (SUSER_SNAME()),
        ProcessCode    sysname NOT NULL,
        SourceDb       sysname NOT NULL,
        ArchiveDb      sysname NOT NULL,
        PurgeArchive   bit NOT NULL,
        RowsRestored   bigint NOT NULL,
        ObjectsTouched int NOT NULL
    );
END;
GO
-- Tamper-resistance (mirrors 045_audit_immutability): the restore log is append-only.
DENY UPDATE, DELETE ON [arch].[RestoreAudit] TO public;
GO

/* ============================================================================
 * 042 — Restore / un-archive (C1)
 * ============================================================================
 * Copies archived rows back from the archive DB into the source tables for a
 * process, reversing an over-eager archive. Design:
 *   - Per enabled ObjectSpec, in REVERSE DeleteOrder (parents/masters before
 *     children) so FK order is satisfied on insert.
 *   - Idempotent: only rows missing from the source are inserted (NOT EXISTS on
 *     the source PRIMARY KEY). Re-running restores nothing extra.
 *   - IDENTITY-safe: SET IDENTITY_INSERT around tables that have an identity.
 *   - Atomic: the whole restore runs in one transaction.
 *   - @DryRun = 1 (default) only reports how many rows WOULD be restored.
 *   - Archive copies are LEFT intact by default (copy semantics). @PurgeArchive=1
 *     removes the restored rows from the archive afterwards (move semantics).
 *
 * NOTE: after restoring, rows older than the cutoff would be re-archived on the
 * next run — adjust retention/cutoff (or disable the mapping) if the restore is
 * meant to be permanent.
 * ============================================================================ */
CREATE OR ALTER PROCEDURE [arch].[usp_RestoreFromArchive]
    @ProcessCode   sysname,
    @SourceDb      sysname,
    @ArchiveDb     sysname,
    @DryRun        bit = 1,
    @MaxRows       int = NULL,          -- optional cap per table
    @PurgeArchive  bit = 0,
    @RequestedBy   nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF DB_ID(@SourceDb) IS NULL  THROW 50400, 'Source database does not exist.', 1;
    IF DB_ID(@ArchiveDb) IS NULL THROW 50401, 'Archive database does not exist.', 1;

    DECLARE @ProcessId int, @ProcessDatabaseId int;
    SELECT TOP (1) @ProcessId = e.ProcessId, @ProcessDatabaseId = e.ProcessDatabaseId
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessCode = @ProcessCode AND e.SourceDb = @SourceDb AND e.ArchiveDb = @ArchiveDb;

    IF @ProcessId IS NULL
        THROW 50402, 'Process/source/archive mapping not found.', 1;

    -- T-27: @PurgeArchive=1 DELETEs the archive copy = the only surviving copy of those rows (and, for
    -- BATCH/NONE mappings, the only per-row trace). Gate it server-side regardless of caller:
    --   (a) only a member of karch_approver (sysadmin bypasses) may purge;
    --   (b) refuse purge when the mapping's effective AuditLevel < ROW (no per-row trail exists).
    -- The Admin Console API additionally never forwards a client-supplied purge flag (it always sends 0).
    IF @PurgeArchive = 1
    BEGIN
        IF COALESCE(IS_MEMBER('karch_approver'), 0) = 0 AND IS_SRVROLEMEMBER('sysadmin') = 0
            THROW 50404, 'Purging the archive requires membership in karch_approver.', 1;

        DECLARE @PurgeAuditLevel nvarchar(20);
        SELECT TOP (1) @PurgeAuditLevel = COALESCE(NULLIF(LTRIM(RTRIM(e.AuditLevel)), N''), N'BATCH')
        FROM arch.v_ProcessDatabaseEffective e
        WHERE e.ProcessId = @ProcessId AND e.SourceDb = @SourceDb AND e.ArchiveDb = @ArchiveDb;

        IF @PurgeAuditLevel <> N'ROW'
            THROW 50405, 'Purging the archive is blocked for mappings with AuditLevel < ROW (the archive is the only per-row trace of the deleted rows).', 1;
    END;

    -- Enabled objects, parents first (reverse of delete order).
    DECLARE @Obj TABLE
    (
        Seq int IDENTITY(1,1) PRIMARY KEY,
        SourceSchema sysname, SourceTable sysname,
        ArchiveSchema sysname, ArchiveTable sysname
    );
    INSERT @Obj (SourceSchema, SourceTable, ArchiveSchema, ArchiveTable)
    SELECT
        os.SourceSchema, os.SourceTable,
        CONVERT(sysname, REPLACE(
            CASE WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo'
                 THEN N'{SourceDb}' ELSE LTRIM(RTRIM(os.ArchiveSchema)) END, N'{SourceDb}', @SourceDb)),
        COALESCE(os.ArchiveTable, os.SourceTable)
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessDatabaseId = @ProcessDatabaseId AND os.ObjectIsEnabled = 1
    ORDER BY os.DeleteOrder DESC, os.ObjectSpecId DESC;

    IF NOT EXISTS (SELECT 1 FROM @Obj)
        THROW 50403, 'Process has no enabled ObjectSpec to restore.', 1;

    DECLARE @Result TABLE
    (
        SourceObject nvarchar(400), ArchiveObject nvarchar(400),
        ArchiveRows bigint NULL, RestorableRows bigint NULL, RestoredRows bigint NULL, Note nvarchar(200) NULL
    );

    DECLARE @Seq int, @ss sysname, @st sysname, @as2 sysname, @at sysname,
            @srcFq nvarchar(512), @arcFq nvarchar(512),
            @cols nvarchar(max), @dummy nvarchar(max),
            @pkJoin nvarchar(max), @pkCols nvarchar(max), @hasId bit, @arcCount bigint, @restorable bigint, @n bigint,
            @sql nvarchar(max);

    DECLARE @started bit = 0;
    BEGIN TRY
        IF @DryRun = 0
        BEGIN
            BEGIN TRAN;
            SET @started = 1;
        END;

        DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Seq, SourceSchema, SourceTable, ArchiveSchema, ArchiveTable FROM @Obj ORDER BY Seq;
        OPEN c; FETCH NEXT FROM c INTO @Seq, @ss, @st, @as2, @at;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @srcFq = QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@ss) + N'.' + QUOTENAME(@st);
            SET @arcFq = QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@as2) + N'.' + QUOTENAME(@at);
            SET @cols = NULL; SET @pkJoin = NULL; SET @pkCols = NULL; SET @hasId = 0; SET @arcCount = NULL; SET @restorable = NULL;

            IF OBJECT_ID(@arcFq, N'U') IS NULL OR OBJECT_ID(@srcFq, N'U') IS NULL
            BEGIN
                INSERT @Result VALUES (@srcFq, @arcFq, NULL, NULL, NULL, N'SKIP: source or archive table missing');
                FETCH NEXT FROM c INTO @Seq, @ss, @st, @as2, @at; CONTINUE;
            END;

            -- column list (non-computed) shared by source + archive. @ExcludeRowversion=1: a
            -- rowversion/timestamp column cannot be INSERTed explicitly on restore (it auto-generates),
            -- so it is omitted from both the INSERT target list and the SELECT from the archive.
            EXEC arch.usp_GetOutputColumns @SourceDb=@SourceDb, @SourceSchema=@ss, @SourceTable=@st,
                 @IncludeComputed=0, @ExcludeRowversion=1, @DeletedSelectList=@dummy OUTPUT, @TargetColumnList=@cols OUTPUT;

            -- source PK join (required for safe dedup)
            SET @sql = N'SELECT @j = STRING_AGG(CONVERT(nvarchar(max), N''s.'' + QUOTENAME(c.name) + N'' = arc.'' + QUOTENAME(c.name)), N'' AND '') WITHIN GROUP (ORDER BY ic.key_ordinal)
                         FROM ' + QUOTENAME(@SourceDb) + N'.sys.indexes i
                         JOIN ' + QUOTENAME(@SourceDb) + N'.sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                         JOIN ' + QUOTENAME(@SourceDb) + N'.sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                         WHERE i.is_primary_key = 1 AND i.object_id = OBJECT_ID(@fq);';
            EXEC sys.sp_executesql @sql, N'@fq nvarchar(512), @j nvarchar(max) OUTPUT', @fq=@srcFq, @j=@pkJoin OUTPUT;

            -- source PK column list (bare) for de-duplicating the archive side (see the INSERT below).
            SET @sql = N'SELECT @pc = STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(c.name)), N'', '') WITHIN GROUP (ORDER BY ic.key_ordinal)
                         FROM ' + QUOTENAME(@SourceDb) + N'.sys.indexes i
                         JOIN ' + QUOTENAME(@SourceDb) + N'.sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                         JOIN ' + QUOTENAME(@SourceDb) + N'.sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                         WHERE i.is_primary_key = 1 AND i.object_id = OBJECT_ID(@fq);';
            EXEC sys.sp_executesql @sql, N'@fq nvarchar(512), @pc nvarchar(max) OUTPUT', @fq=@srcFq, @pc=@pkCols OUTPUT;

            -- does the source table have an identity column?
            SET @sql = N'SELECT @hi = CASE WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@SourceDb) + N'.sys.columns WHERE object_id = OBJECT_ID(@fq) AND is_identity = 1) THEN 1 ELSE 0 END;';
            EXEC sys.sp_executesql @sql, N'@fq nvarchar(512), @hi bit OUTPUT', @fq=@srcFq, @hi=@hasId OUTPUT;

            IF @pkJoin IS NULL
            BEGIN
                INSERT @Result VALUES (@srcFq, @arcFq, NULL, NULL, NULL, N'SKIP: source table has no PRIMARY KEY (cannot dedup safely)');
                FETCH NEXT FROM c INTO @Seq, @ss, @st, @as2, @at; CONTINUE;
            END;

            -- counts
            -- @restorable counts DISTINCT primary keys missing from source (not raw archive rows) so the
            -- preview matches what the de-duplicated INSERT will actually restore when the archive holds
            -- duplicate keys (e.g. after repeated copy-only runs).
            SET @sql = N'SELECT @ac = COUNT_BIG(*) FROM ' + @arcFq + N';
                         SELECT @rc = COUNT_BIG(*) FROM (SELECT DISTINCT ' + @pkCols + N' FROM ' + @arcFq + N' arc WHERE NOT EXISTS (SELECT 1 FROM ' + @srcFq + N' s WHERE ' + @pkJoin + N')) _d;';
            EXEC sys.sp_executesql @sql, N'@ac bigint OUTPUT, @rc bigint OUTPUT', @ac=@arcCount OUTPUT, @rc=@restorable OUTPUT;

            IF @DryRun = 1
            BEGIN
                INSERT @Result VALUES (@srcFq, @arcFq, @arcCount, @restorable, NULL, N'DRYRUN');
            END
            ELSE
            BEGIN
                -- De-duplicate the archive side to ONE row per primary key (ROW_NUMBER PARTITION BY PK):
                -- the archive may legitimately hold duplicate keys (repeated copy-only runs / prior
                -- restore-then-rearchive cycles). Inserting them raw would raise a PK violation on the
                -- source and abort the whole restore. The NOT EXISTS still skips keys already in source.
                SET @sql =
                    CASE WHEN @hasId = 1 THEN N'SET IDENTITY_INSERT ' + @srcFq + N' ON;' + CHAR(10) ELSE N'' END +
                    N'INSERT INTO ' + @srcFq + N' (' + @cols + N')' + CHAR(10) +
                    N'SELECT ' + CASE WHEN @MaxRows IS NOT NULL THEN N'TOP (' + CONVERT(nvarchar(20), @MaxRows) + N') ' ELSE N'' END +
                    @cols + N' FROM (' + CHAR(10) +
                    N'    SELECT ' + @cols + N', ROW_NUMBER() OVER (PARTITION BY ' + @pkCols + N' ORDER BY (SELECT NULL)) AS _rn' + CHAR(10) +
                    N'    FROM ' + @arcFq + N' arc' + CHAR(10) +
                    N'    WHERE NOT EXISTS (SELECT 1 FROM ' + @srcFq + N' s WHERE ' + @pkJoin + N')' + CHAR(10) +
                    N') _d WHERE _rn = 1;' + CHAR(10) +
                    CASE WHEN @hasId = 1 THEN N'SET IDENTITY_INSERT ' + @srcFq + N' OFF;' ELSE N'' END;
                EXEC (@sql);
                SET @n = @@ROWCOUNT;

                IF @PurgeArchive = 1 AND @n > 0
                BEGIN
                    SET @sql = N'DELETE arc FROM ' + @arcFq + N' arc WHERE EXISTS (SELECT 1 FROM ' + @srcFq + N' s WHERE ' + @pkJoin + N');';
                    EXEC (@sql);
                END;

                INSERT @Result VALUES (@srcFq, @arcFq, @arcCount, @restorable, @n, CASE WHEN @PurgeArchive=1 THEN N'RESTORED + purged archive' ELSE N'RESTORED (archive kept)' END);
            END;

            FETCH NEXT FROM c INTO @Seq, @ss, @st, @as2, @at;
        END;
        CLOSE c; DEALLOCATE c;

        -- T-27: append-only log of the real restore (atomic with it). Records the authenticated actor,
        -- the purge flag, and the totals so an irreversible restore/purge is reconstructable afterwards.
        IF @DryRun = 0
            INSERT [arch].[RestoreAudit](RequestedBy, ProcessCode, SourceDb, ArchiveDb, PurgeArchive, RowsRestored, ObjectsTouched)
            SELECT @RequestedBy, @ProcessCode, @SourceDb, @ArchiveDb, @PurgeArchive,
                   ISNULL(SUM(RestoredRows), 0), COUNT(CASE WHEN RestoredRows IS NOT NULL THEN 1 END)
            FROM @Result;

        IF @started = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF @started = 1 AND XACT_STATE() <> 0 ROLLBACK;
        DECLARE @err nvarchar(4000) = ERROR_MESSAGE();
        RAISERROR(N'arch.usp_RestoreFromArchive failed: %s', 16, 1, @err);
        RETURN;
    END CATCH;

    SELECT
        ProcessCode = @ProcessCode, SourceDb = @SourceDb, ArchiveDb = @ArchiveDb,
        Mode = CASE WHEN @DryRun = 1 THEN N'DRYRUN' ELSE N'RESTORE' END,
        RequestedBy = @RequestedBy,
        SourceObject, ArchiveObject, ArchiveRows, RestorableRows, RestoredRows, Note
    FROM @Result
    ORDER BY SourceObject;
END
GO

-- T-02: restore writes back to the PRODUCTION source DB and (with @PurgeArchive=1) deletes the
-- archive copy. Grant EXECUTE only to karch_advanced_admin (the highest config role the app pool
-- holds) so the endpoint works WITHOUT relying on the over-privileged orphan login [IIS APPPOOL\Console].
-- Deliberately NOT granted to karch_operator / karch_config_admin.
-- Follow-up (T-06/T-27): gate restore + @PurgeArchive behind a distinct approver/runtime credential.
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_RestoreFromArchive] TO [karch_advanced_admin];
GO

PRINT '042_usp_RestoreFromArchive deployed (+ karch_advanced_admin grant).';
GO
-- <<< end: kArchiveManagerAdmin\v2\042_usp_RestoreFromArchive.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\045_audit_immutability.sql
/* ============================================================================
   045 — Audit immutability hardening (audit task T-09)
   ============================================================================
   PROBLEM: the forensic trail of every deletion (arch.RunDocAudit) and the config-change records
   are fully mutable — no triggers, no temporal/ledger, no DENY. Any principal with direct DML
   (e.g. the over-privileged orphan [IIS APPPOOL\Console] which holds db_datawriter, or a future
   db_datawriter grant) can UPDATE/DELETE the audit after the fact, voiding the "reconstructable"
   guarantee for irreversible deletes.

   FIX (access control): DENY UPDATE/DELETE to public on the append-only audit/forensic tables.
     - Procedures keep working: the runners only INSERT into these tables, and INSERT is not denied;
       proc-mediated DML also runs under ownership chaining (proc owner = table owner = dbo), which
       is not affected by table DENY.
     - dbo / sysadmin are NOT affected (they bypass all permission checks), so controlled
       maintenance (retention purge T-21, test reset) still works under an elevated identity.
     - The orphan / any db_datawriter principal IS blocked from ad-hoc tampering (DENY overrides GRANT).

   SCOPE (only truly append-only objects are locked; tables that the runner legitimately UPDATEs are
   left writable, only their DELETE is denied since the app never deletes them in normal operation):
     RunDocAudit, ConfigChangeField, ConfigChangeItem  -> DENY UPDATE, DELETE (written once)
     ConfigChangeSet                                    -> DENY DELETE      (status is updated DRAFT->PUBLISHED)
     Run, RunItem, RunItemObject                        -> DENY DELETE      (status/counters are updated)

   NOTE: this is access-control hardening, not cryptographic tamper-EVIDENCE. For a tamper-evident
   trail on SQL Server 2022, convert RunDocAudit (and the ConfigChange* tables) to updatable LEDGER
   tables — tracked as a larger follow-up. Combine with task T-01 (remove the orphan logins).

   Idempotent (DENY is repeatable). Safe to run anytime; no data change.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET NOCOUNT ON;
GO

-- Append-only forensic / change-detail tables: never updated or deleted in normal operation.
IF OBJECT_ID(N'arch.RunDocAudit', N'U') IS NOT NULL      DENY UPDATE, DELETE ON arch.RunDocAudit      TO public;
IF OBJECT_ID(N'arch.ConfigChangeField', N'U') IS NOT NULL DENY UPDATE, DELETE ON arch.ConfigChangeField TO public;
IF OBJECT_ID(N'arch.ConfigChangeItem', N'U') IS NOT NULL  DENY UPDATE, DELETE ON arch.ConfigChangeItem  TO public;
GO

-- Tables whose rows are legitimately UPDATEd (status/counters/lifecycle) but never DELETEd by the app.
IF OBJECT_ID(N'arch.ConfigChangeSet', N'U') IS NOT NULL DENY DELETE ON arch.ConfigChangeSet TO public;
IF OBJECT_ID(N'arch.Run', N'U') IS NOT NULL            DENY DELETE ON arch.Run            TO public;
IF OBJECT_ID(N'arch.RunItem', N'U') IS NOT NULL        DENY DELETE ON arch.RunItem        TO public;
IF OBJECT_ID(N'arch.RunItemObject', N'U') IS NOT NULL  DENY DELETE ON arch.RunItemObject  TO public;
GO

PRINT '045_audit_immutability deployed (DENY UPDATE/DELETE on append-only audit tables; DENY DELETE on lifecycle tables).';
GO
-- <<< end: kArchiveManagerAdmin\v2\045_audit_immutability.sql
GO
GO

-- ---- Phase 12: Admin Console API procs (Api_* / Frontend_*) ----
-- >>> inlined: kArchiveManagerAdmin\frontend\001_frontend_read_api.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetProcessConfigSummary]
    @ProcessCode sysname = NULL,
    @IncludeDisabled bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.ProcessId,
        p.ProcessCode,
        p.Description,
        p.IsEnabled,
        p.Mode,
        ModeName = CONVERT(nvarchar(30), CASE p.Mode WHEN 1 THEN N'ARCHIVE_DELETE' WHEN 2 THEN N'COPY_ONLY' ELSE N'DELETE_ONLY' END),
        p.SelectionStrategy,
        p.RetentionDays,
        p.CutoffSafetyLagMinutes,
        p.CutoffMode,
        p.CutoffDate,
        p.BatchDocCount,
        p.BatchRowCount,
        p.MaxBatchesPerRun,
        p.DelayMsBetweenBatches,
        p.UseAppLock,
        p.AppLockResource,
        p.LockTimeoutMs,
        p.DeadlockPriority,
        p.AllowDeleteWithoutArchive,
        p.DocKeyLabel,
        p.AuditLevel,
        p.RequireSupportingIndex,
        p.MaxRowsPerTransaction,
        p.AnchorSchema,
        p.AnchorTable,
        p.AnchorDocKeyExpr,
        p.AnchorDocKey2Expr,
        p.AnchorTimestampExpr,
        p.AnchorExtraWhereSql,
        p.CandidateWhereSql,
        p.CandidateOrderSql,
        p.CreatedAt,
        p.ModifiedAt,
        DatabaseMappingCount = COALESCE(pdCounts.DatabaseMappingCount, CONVERT(bigint, 0)),
        EnabledDatabaseMappingCount = COALESCE(pdCounts.EnabledDatabaseMappingCount, CONVERT(bigint, 0)),
        ObjectSpecCount = COALESCE(osCounts.ObjectSpecCount, CONVERT(bigint, 0))
    FROM arch.Process p
    OUTER APPLY
    (
        SELECT
            DatabaseMappingCount = COUNT_BIG(*),
            EnabledDatabaseMappingCount = SUM(CONVERT(bigint, CASE WHEN pd.IsEnabled = 1 THEN 1 ELSE 0 END))
        FROM arch.ProcessDatabase pd
        WHERE pd.ProcessId = p.ProcessId
    ) pdCounts
    OUTER APPLY
    (
        SELECT ObjectSpecCount = COUNT_BIG(*)
        FROM arch.ObjectSpec os
        WHERE os.ProcessId = p.ProcessId
    ) osCounts
    WHERE (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@IncludeDisabled = 1 OR p.IsEnabled = 1)
    ORDER BY p.ProcessCode;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetEffectiveProcessDatabases]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @OnlyEnabled bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        e.*
    FROM arch.v_ProcessDatabaseEffective e
    WHERE (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR e.ArchiveDb = @ArchiveDb)
      AND (@OnlyEnabled = 0 OR e.IsEnabled = 1)
    ORDER BY
        e.RunOrder,
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetEffectiveObjects]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @OnlyEnabled bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        os.*
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR os.ArchiveDb = @ArchiveDb)
      AND (@OnlyEnabled = 0 OR (os.ProcessDatabaseIsEnabled = 1 AND os.ObjectIsEnabled = 1))
    ORDER BY
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        os.DeleteOrder,
        os.ObjectSpecId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetTableMovementCounts]
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @ProcessCode sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #EffectiveObjects
    (
        ProcessCode sysname NOT NULL,
        SourceDb sysname NOT NULL,
        ArchiveDb sysname NOT NULL,
        SourceSchema sysname NOT NULL,
        SourceTable sysname NOT NULL,
        ArchiveSchema sysname NOT NULL,
        ArchiveTable sysname NOT NULL,
        BusinessDateExpression nvarchar(4000) NULL,
        ObjectIsEnabled bit NOT NULL
    );

    INSERT INTO #EffectiveObjects
    (
        ProcessCode,
        SourceDb,
        ArchiveDb,
        SourceSchema,
        SourceTable,
        ArchiveSchema,
        ArchiveTable,
        BusinessDateExpression,
        ObjectIsEnabled
    )
    SELECT
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        os.SourceSchema,
        os.SourceTable,
        ArchiveSchema = CONVERT(sysname, REPLACE(
            CASE
                WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL
                  OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo'
                    THEN N'{SourceDb}'
                ELSE LTRIM(RTRIM(os.ArchiveSchema))
            END,
            N'{SourceDb}', os.SourceDb)),
        ArchiveTable = COALESCE(NULLIF(LTRIM(RTRIM(os.ArchiveTable)), N''), os.SourceTable),
        BusinessDateExpression = os.TimestampExpr,
        os.ObjectIsEnabled
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR os.ArchiveDb = @ArchiveDb)
      AND os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1;

    CREATE TABLE #SourceMeta
    (
        SourceDb sysname NOT NULL,
        SourceSchema sysname NOT NULL,
        SourceTable sysname NOT NULL,
        SourceRows bigint NOT NULL,
        SourceObjectExists bit NOT NULL
    );

    CREATE TABLE #ArchiveMeta
    (
        ArchiveDb sysname NOT NULL,
        ArchiveSchema sysname NOT NULL,
        ArchiveTable sysname NOT NULL,
        ArchivedRows bigint NOT NULL,
        ArchiveObjectExists bit NOT NULL
    );

    DECLARE
        @CurrentSourceDb sysname,
        @CurrentArchiveDb sysname,
        @Sql nvarchar(max);

    DECLARE source_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT SourceDb
    FROM #EffectiveObjects
    WHERE DB_ID(SourceDb) IS NOT NULL;

    OPEN source_cursor;
    FETCH NEXT FROM source_cursor INTO @CurrentSourceDb;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'
            INSERT INTO #SourceMeta(SourceDb, SourceSchema, SourceTable, SourceRows, SourceObjectExists)
            SELECT
                @DbName,
                s.name,
                t.name,
                SUM(CONVERT(bigint, p.rows)),
                CONVERT(bit, 1)
            FROM ' + QUOTENAME(@CurrentSourceDb) + N'.sys.tables t
            JOIN ' + QUOTENAME(@CurrentSourceDb) + N'.sys.schemas s
              ON s.schema_id = t.schema_id
            JOIN ' + QUOTENAME(@CurrentSourceDb) + N'.sys.partitions p
              ON p.object_id = t.object_id
             AND p.index_id IN (0, 1)
            WHERE EXISTS
            (
                SELECT 1
                FROM #EffectiveObjects eo
                WHERE eo.SourceDb COLLATE DATABASE_DEFAULT = @DbName COLLATE DATABASE_DEFAULT
                  AND eo.SourceSchema COLLATE DATABASE_DEFAULT = s.name COLLATE DATABASE_DEFAULT
                  AND eo.SourceTable COLLATE DATABASE_DEFAULT = t.name COLLATE DATABASE_DEFAULT
            )
            GROUP BY s.name, t.name;';

        EXEC sys.sp_executesql
            @Sql,
            N'@DbName sysname',
            @DbName = @CurrentSourceDb;

        FETCH NEXT FROM source_cursor INTO @CurrentSourceDb;
    END;

    CLOSE source_cursor;
    DEALLOCATE source_cursor;

    DECLARE archive_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT ArchiveDb
    FROM #EffectiveObjects
    WHERE DB_ID(ArchiveDb) IS NOT NULL;

    OPEN archive_cursor;
    FETCH NEXT FROM archive_cursor INTO @CurrentArchiveDb;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'
            INSERT INTO #ArchiveMeta(ArchiveDb, ArchiveSchema, ArchiveTable, ArchivedRows, ArchiveObjectExists)
            SELECT
                @DbName,
                s.name,
                t.name,
                SUM(CONVERT(bigint, p.rows)),
                CONVERT(bit, 1)
            FROM ' + QUOTENAME(@CurrentArchiveDb) + N'.sys.tables t
            JOIN ' + QUOTENAME(@CurrentArchiveDb) + N'.sys.schemas s
              ON s.schema_id = t.schema_id
            JOIN ' + QUOTENAME(@CurrentArchiveDb) + N'.sys.partitions p
              ON p.object_id = t.object_id
             AND p.index_id IN (0, 1)
            WHERE EXISTS
            (
                SELECT 1
                FROM #EffectiveObjects eo
                WHERE eo.ArchiveDb COLLATE DATABASE_DEFAULT = @DbName COLLATE DATABASE_DEFAULT
                  AND eo.ArchiveSchema COLLATE DATABASE_DEFAULT = s.name COLLATE DATABASE_DEFAULT
                  AND eo.ArchiveTable COLLATE DATABASE_DEFAULT = t.name COLLATE DATABASE_DEFAULT
            )
            GROUP BY s.name, t.name;';

        EXEC sys.sp_executesql
            @Sql,
            N'@DbName sysname',
            @DbName = @CurrentArchiveDb;

        FETCH NEXT FROM archive_cursor INTO @CurrentArchiveDb;
    END;

    CLOSE archive_cursor;
    DEALLOCATE archive_cursor;

    SELECT
        eo.ProcessCode,
        eo.SourceDb,
        eo.ArchiveDb,
        eo.SourceSchema,
        eo.SourceTable,
        eo.ArchiveSchema,
        eo.ArchiveTable,
        SourceRows = COALESCE(sm.SourceRows, CONVERT(bigint, 0)),
        ArchivedRows = COALESCE(am.ArchivedRows, CONVERT(bigint, 0)),
        DifferenceCount = COALESCE(sm.SourceRows, CONVERT(bigint, 0)) - COALESCE(am.ArchivedRows, CONVERT(bigint, 0)),
        BusinessDateExpression = eo.BusinessDateExpression,
        eo.ObjectIsEnabled,
        SourceObjectExists = COALESCE(sm.SourceObjectExists, CONVERT(bit, 0)),
        ArchiveObjectExists = COALESCE(am.ArchiveObjectExists, CONVERT(bit, 0))
    FROM #EffectiveObjects eo
    LEFT JOIN #SourceMeta sm
      ON sm.SourceDb = eo.SourceDb
     AND sm.SourceSchema = eo.SourceSchema
     AND sm.SourceTable = eo.SourceTable
    LEFT JOIN #ArchiveMeta am
      ON am.ArchiveDb = eo.ArchiveDb
     AND am.ArchiveSchema = eo.ArchiveSchema
     AND am.ArchiveTable = eo.ArchiveTable
    ORDER BY
        eo.ProcessCode,
        eo.SourceDb,
        eo.ArchiveDb,
        eo.SourceSchema,
        eo.SourceTable;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetProcessMovementSummary]
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @ProcessCode sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Counts
    (
        ProcessCode sysname NOT NULL,
        SourceDb sysname NOT NULL,
        ArchiveDb sysname NOT NULL,
        SourceSchema sysname NOT NULL,
        SourceTable sysname NOT NULL,
        ArchiveSchema sysname NOT NULL,
        ArchiveTable sysname NOT NULL,
        SourceRows bigint NOT NULL,
        ArchivedRows bigint NOT NULL,
        DifferenceCount bigint NOT NULL,
        BusinessDateExpression nvarchar(4000) NULL,
        ObjectIsEnabled bit NOT NULL,
        SourceObjectExists bit NOT NULL,
        ArchiveObjectExists bit NOT NULL
    );

    INSERT INTO #Counts
    EXEC arch.usp_Frontend_GetTableMovementCounts
        @SourceDb = @SourceDb,
        @ArchiveDb = @ArchiveDb,
        @ProcessCode = @ProcessCode;

    SELECT
        ProcessCode,
        SourceDb,
        ArchiveDb,
        SourceRows = SUM(SourceRows),
        ArchivedRows = SUM(ArchivedRows),
        DifferenceCount = SUM(DifferenceCount),
        ObjectCount = COUNT_BIG(*),
        MissingSourceObjectCount = SUM(CONVERT(bigint, CASE WHEN SourceObjectExists = 0 THEN 1 ELSE 0 END)),
        MissingArchiveObjectCount = SUM(CONVERT(bigint, CASE WHEN ArchiveObjectExists = 0 THEN 1 ELSE 0 END))
    FROM #Counts
    GROUP BY
        ProcessCode,
        SourceDb,
        ArchiveDb
    ORDER BY
        ProcessCode,
        SourceDb,
        ArchiveDb;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetProcessedHistory]
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @ProcessCode sysname = NULL,
    @DateFromUtc datetime2(0) = NULL,
    @DateToUtc datetime2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        RunDate = CONVERT(date, ri.StartedAt),
        r.RunId,
        ri.RunItemId,
        p.ProcessCode,
        r.SourceDb,
        r.ArchiveDb,
        rio.SourceSchema,
        rio.SourceTable,
        ri.CutoffUtc,
        ri.Mode,
        ri.Status,
        ProcessedRows =
            CASE
                WHEN ri.Mode = 0 THEN COALESCE(rio.RowsDeleted, CONVERT(bigint, 0))
                ELSE COALESCE(rio.RowsArchived, CONVERT(bigint, 0))
            END,
        RowsArchived = COALESCE(rio.RowsArchived, CONVERT(bigint, 0)),
        RowsDeleted = COALESCE(rio.RowsDeleted, CONVERT(bigint, 0)),
        ri.DocsDone,
        ri.StartedAt,
        ri.EndedAt
    FROM arch.RunItem ri
    JOIN arch.Run r
      ON r.RunId = ri.RunId
    JOIN arch.Process p
      ON p.ProcessId = ri.ProcessId
    LEFT JOIN arch.RunItemObject rio
      ON rio.RunItemId = ri.RunItemId
    WHERE (@SourceDb IS NULL OR r.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR r.ArchiveDb = @ArchiveDb)
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@DateFromUtc IS NULL OR ri.StartedAt >= @DateFromUtc)
      AND (@DateToUtc IS NULL OR ri.StartedAt < @DateToUtc)
    ORDER BY
        ri.StartedAt DESC,
        r.RunId DESC,
        ri.RunItemId DESC,
        rio.SourceSchema,
        rio.SourceTable;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetWorkBatchActivity]
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @ProcessCode sysname = NULL,
    @DateFromUtc datetime2(0) = NULL,
    @DateToUtc datetime2(0) = NULL,
    @OpenOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        wb.WorkBatchId,
        p.ProcessCode,
        wb.SourceDb,
        wb.ArchiveDb,
        wb.Status,
        wb.PreparedAtUtc,
        wb.StartedAtUtc,
        wb.CompletedAtUtc,
        wb.LastProgressAtUtc,
        CandidateRows = COUNT_BIG(wbk.WorkBatchId),
        MinCandidateUtc = MIN(wbk.DocCreatedAt),
        MaxCandidateUtc = MAX(wbk.DocCreatedAt),
        wb.RangeFromUtc,
        wb.RangeToUtc,
        wb.ModeSnapshot,
        wb.LastKey1,
        wb.LastKey2,
        wb.Notes
    FROM arch.WorkBatch wb
    JOIN arch.Process p
      ON p.ProcessId = wb.ProcessId
    LEFT JOIN arch.WorkBatchKey wbk
      ON wbk.WorkBatchId = wb.WorkBatchId
    WHERE (@SourceDb IS NULL OR wb.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR wb.ArchiveDb = @ArchiveDb)
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@DateFromUtc IS NULL OR COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc) >= @DateFromUtc)
      AND (@DateToUtc IS NULL OR COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc) < @DateToUtc)
      AND (@OpenOnly = 0 OR wb.Status IN ('Prepared', 'Running', 'Paused'))
    GROUP BY
        wb.WorkBatchId,
        p.ProcessCode,
        wb.SourceDb,
        wb.ArchiveDb,
        wb.Status,
        wb.PreparedAtUtc,
        wb.StartedAtUtc,
        wb.CompletedAtUtc,
        wb.LastProgressAtUtc,
        wb.RangeFromUtc,
        wb.RangeToUtc,
        wb.ModeSnapshot,
        wb.LastKey1,
        wb.LastKey2,
        wb.Notes
    ORDER BY
        COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc) DESC,
        wb.WorkBatchId DESC;
END
GO
-- <<< end: kArchiveManagerAdmin\frontend\001_frontend_read_api.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\frontend\002_frontend_lookup_validation_api.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetRecentRuns]
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @ProcessCode sysname = NULL,
    @DateFromUtc datetime2(0) = NULL,
    @DateToUtc datetime2(0) = NULL,
    @Top int = 500
AS
BEGIN
    SET NOCOUNT ON;

    IF @Top IS NULL OR @Top <= 0
        SET @Top = 500;

    SELECT TOP (@Top)
        v.RunId,
        v.RunItemId,
        v.ProcessCode,
        v.SourceDb,
        v.ArchiveDb,
        v.AsOfUtc,
        v.CutoffUtc,
        v.Mode,
        ModeName = CONVERT(nvarchar(30), CASE v.Mode WHEN 1 THEN N'ARCHIVE_DELETE' WHEN 2 THEN N'COPY_ONLY' ELSE N'DELETE_ONLY' END),
        v.Status,
        v.StartedAt,
        v.EndedAt,
        v.BatchesDone,
        v.DocsDone,
        v.RowsDeleted,
        v.RowsArchived,
        ProcessedRows = CASE WHEN v.Mode = 0 THEN v.RowsDeleted ELSE v.RowsArchived END,
        v.ErrorMessage
    FROM arch.v_RunItemsRecent v
    WHERE (@SourceDb IS NULL OR v.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR v.ArchiveDb = @ArchiveDb)
      AND (@ProcessCode IS NULL OR v.ProcessCode = @ProcessCode)
      AND (@DateFromUtc IS NULL OR v.StartedAt >= @DateFromUtc)
      AND (@DateToUtc IS NULL OR v.StartedAt < @DateToUtc)
    ORDER BY
        v.StartedAt DESC,
        v.RunItemId DESC;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetRunDetail]
    @RunId bigint = NULL,
    @RunItemId bigint = NULL,
    @Top int = 500
AS
BEGIN
    SET NOCOUNT ON;

    IF @Top IS NULL OR @Top <= 0
        SET @Top = 500;

    IF @RunId IS NULL AND @RunItemId IS NOT NULL
    BEGIN
        SELECT @RunId = RunId
        FROM arch.RunItem
        WHERE RunItemId = @RunItemId;
    END;

    DECLARE @SelectedItems table
    (
        RunItemId bigint NOT NULL PRIMARY KEY,
        RunId bigint NOT NULL,
        ProcessId int NOT NULL,
        ProcessCode sysname NOT NULL,
        AsOfUtc datetime2(0) NOT NULL,
        CutoffUtc datetime2(0) NOT NULL,
        Mode tinyint NOT NULL,
        BatchesDone int NOT NULL,
        DocsDone int NOT NULL,
        RowsDeleted bigint NOT NULL,
        RowsArchived bigint NOT NULL,
        StartedAt datetime2(0) NOT NULL,
        EndedAt datetime2(0) NULL,
        Status nvarchar(20) NOT NULL,
        ErrorMessage nvarchar(max) NULL
    );

    INSERT INTO @SelectedItems
    (
        RunItemId,
        RunId,
        ProcessId,
        ProcessCode,
        AsOfUtc,
        CutoffUtc,
        Mode,
        BatchesDone,
        DocsDone,
        RowsDeleted,
        RowsArchived,
        StartedAt,
        EndedAt,
        Status,
        ErrorMessage
    )
    SELECT
        ri.RunItemId,
        ri.RunId,
        ri.ProcessId,
        p.ProcessCode,
        ri.AsOfUtc,
        ri.CutoffUtc,
        ri.Mode,
        ri.BatchesDone,
        ri.DocsDone,
        ri.RowsDeleted,
        ri.RowsArchived,
        ri.StartedAt,
        ri.EndedAt,
        ri.Status,
        ri.ErrorMessage
    FROM arch.RunItem ri
    JOIN arch.Process p
      ON p.ProcessId = ri.ProcessId
    WHERE (@RunId IS NOT NULL AND ri.RunId = @RunId)
      AND (@RunItemId IS NULL OR ri.RunItemId = @RunItemId);

    SELECT
        r.RunId,
        r.Status,
        r.SourceDb,
        r.ArchiveDb,
        r.StartedAt,
        r.EndedAt,
        r.HostName,
        r.AppName,
        r.InitiatedBy,
        r.CancelRequestedAtUtc,
        r.CancelRequestedBy,
        r.CancelReason,
        ItemCount = COUNT(si.RunItemId),
        BatchesDone = COALESCE(SUM(si.BatchesDone), 0),
        DocsDone = COALESCE(SUM(si.DocsDone), 0),
        RowsDeleted = COALESCE(SUM(si.RowsDeleted), 0),
        RowsArchived = COALESCE(SUM(si.RowsArchived), 0),
        ErrorMessage = COALESCE(
            NULLIF(r.ErrorMessage, N''),
            MAX(NULLIF(si.ErrorMessage, N'')))
    FROM arch.Run r
    LEFT JOIN @SelectedItems si
      ON si.RunId = r.RunId
    WHERE @RunId IS NOT NULL
      AND r.RunId = @RunId
    GROUP BY
        r.RunId,
        r.Status,
        r.SourceDb,
        r.ArchiveDb,
        r.StartedAt,
        r.EndedAt,
        r.HostName,
        r.AppName,
        r.InitiatedBy,
        r.CancelRequestedAtUtc,
        r.CancelRequestedBy,
        r.CancelReason,
        r.ErrorMessage;

    SELECT TOP (@Top)
        si.RunId,
        si.RunItemId,
        si.ProcessCode,
        si.AsOfUtc,
        si.CutoffUtc,
        si.Mode,
        ModeName = CONVERT(nvarchar(30), CASE si.Mode WHEN 1 THEN N'ARCHIVE_DELETE' WHEN 2 THEN N'COPY_ONLY' ELSE N'DELETE_ONLY' END),
        si.Status,
        si.StartedAt,
        si.EndedAt,
        si.BatchesDone,
        si.DocsDone,
        si.RowsDeleted,
        si.RowsArchived,
        ProcessedRows = CASE WHEN si.Mode = 0 THEN si.RowsDeleted ELSE si.RowsArchived END,
        si.ErrorMessage
    FROM @SelectedItems si
    ORDER BY
        si.StartedAt DESC,
        si.RunItemId DESC;

    SELECT TOP (@Top)
        rio.RunItemObjectId,
        rio.RunItemId,
        si.RunId,
        si.ProcessCode,
        rio.SourceSchema,
        rio.SourceTable,
        rio.RowsDeleted,
        rio.RowsArchived,
        rio.LoggedAt
    FROM arch.RunItemObject rio
    JOIN @SelectedItems si
      ON si.RunItemId = rio.RunItemId
    ORDER BY
        rio.LoggedAt DESC,
        rio.RunItemObjectId DESC;

    SELECT TOP (@Top)
        a.RunDocAuditId,
        a.RunItemId,
        si.RunId,
        a.ProcessCode,
        a.DocKeyLabel,
        a.DocKey,
        a.DocCreatedAt,
        a.DeletedAt,
        a.Archived
    FROM arch.RunDocAudit a
    JOIN @SelectedItems si
      ON si.RunItemId = a.RunItemId
    ORDER BY
        a.DeletedAt DESC,
        a.RunDocAuditId DESC;

    SELECT TOP (@Top)
        wb.WorkBatchId,
        ProcessCode = p.ProcessCode,
        wb.SourceDb,
        wb.ArchiveDb,
        wb.RangeFromUtc,
        wb.RangeToUtc,
        wb.ModeSnapshot,
        ModeName = CONVERT(nvarchar(30), CASE wb.ModeSnapshot WHEN 1 THEN N'ARCHIVE_DELETE' WHEN 2 THEN N'COPY_ONLY' ELSE N'DELETE_ONLY' END),
        wb.Status,
        wb.PreparedAtUtc,
        wb.StartedAtUtc,
        wb.LastProgressAtUtc,
        wb.CompletedAtUtc,
        wb.LastKey1,
        wb.LastKey2,
        wb.Notes
    FROM arch.WorkBatch wb
    JOIN arch.Process p
      ON p.ProcessId = wb.ProcessId
    WHERE EXISTS
    (
        SELECT 1
        FROM @SelectedItems si
        JOIN arch.Run r
          ON r.RunId = si.RunId
        WHERE si.ProcessId = wb.ProcessId
          AND r.SourceDb = wb.SourceDb
          AND r.ArchiveDb = wb.ArchiveDb
          AND wb.PreparedAtUtc >= DATEADD(DAY, -1, r.StartedAt)
          AND wb.PreparedAtUtc < COALESCE(DATEADD(DAY, 1, r.EndedAt), SYSUTCDATETIME())
    )
    ORDER BY
        wb.PreparedAtUtc DESC,
        wb.WorkBatchId DESC;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_SearchDocumentAuditSummary]
    @DocKey nvarchar(256),
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Search nvarchar(256) = NULLIF(LTRIM(RTRIM(@DocKey)), N'');

    ;WITH Matches AS
    (
        SELECT
            a.RunDocAuditId,
            a.RunItemId,
            ri.RunId,
            ProcessCode = a.ProcessCode,
            ConfigProcessCode = p.ProcessCode,
            r.SourceDb,
            r.ArchiveDb,
            a.DocKeyLabel,
            a.DocKey,
            a.DocCreatedAt,
            a.DeletedAt,
            a.Archived
        FROM arch.RunDocAudit a
        JOIN arch.RunItem ri
          ON ri.RunItemId = a.RunItemId
        JOIN arch.Run r
          ON r.RunId = ri.RunId
        JOIN arch.Process p
          ON p.ProcessId = ri.ProcessId
        WHERE @Search IS NOT NULL
          AND a.DocKey = @Search
          AND (@ProcessCode IS NULL OR a.ProcessCode = @ProcessCode OR p.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR r.SourceDb = @SourceDb)
          AND (@ArchiveDb IS NULL OR r.ArchiveDb = @ArchiveDb)
    )
    SELECT
        ResultText = CONVERT(nvarchar(4000),
            CASE
                WHEN @Search IS NULL THEN N'Zadejte doklad pro vyhledani.'
                WHEN NOT EXISTS (SELECT 1 FROM Matches) THEN N'Doklad nebyl nalezen v audit logu.'
                ELSE N'Doklad nalezen v audit logu.'
            END),
        DocKey = @Search,
        ProcessCodes =
            STUFF((
                SELECT DISTINCT N', ' + m2.ProcessCode
                FROM Matches m2
                ORDER BY N', ' + m2.ProcessCode
                FOR XML PATH(''), TYPE
            ).value(N'.', N'nvarchar(max)'), 1, 2, N''),
        ArchivedText = CONVERT(nvarchar(10),
            CASE
                WHEN EXISTS (SELECT 1 FROM Matches WHERE Archived = 1) THEN N'ANO'
                WHEN EXISTS (SELECT 1 FROM Matches) THEN N'NE'
                ELSE NULL
            END),
        LatestDeletedAt = (SELECT MAX(DeletedAt) FROM Matches),
        LatestRunId =
            (
                SELECT TOP (1) RunId
                FROM Matches
                ORDER BY DeletedAt DESC, RunDocAuditId DESC
            ),
        LatestRunItemId =
            (
                SELECT TOP (1) RunItemId
                FROM Matches
                ORDER BY DeletedAt DESC, RunDocAuditId DESC
            ),
        SourceDb =
            (
                SELECT TOP (1) SourceDb
                FROM Matches
                ORDER BY DeletedAt DESC, RunDocAuditId DESC
            ),
        ArchiveDb =
            (
                SELECT TOP (1) ArchiveDb
                FROM Matches
                ORDER BY DeletedAt DESC, RunDocAuditId DESC
            );
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_SearchDocumentAuditDetails]
    @DocKey nvarchar(256),
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @Top int = 200
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Search nvarchar(256) = NULLIF(LTRIM(RTRIM(@DocKey)), N'');

    IF @Top IS NULL OR @Top <= 0
        SET @Top = 200;

    SELECT TOP (@Top)
        a.RunDocAuditId,
        a.RunItemId,
        ri.RunId,
        ProcessCode = a.ProcessCode,
        ConfigProcessCode = p.ProcessCode,
        r.SourceDb,
        r.ArchiveDb,
        a.DocKeyLabel,
        a.DocKey,
        a.DocCreatedAt,
        a.DeletedAt,
        a.Archived,
        ArchivedText = CONVERT(nvarchar(10), CASE a.Archived WHEN 1 THEN N'ANO' ELSE N'NE' END),
        ri.Mode,
        ModeText = CONVERT(nvarchar(30), CASE ri.Mode WHEN 1 THEN N'Archive + delete' ELSE N'Delete only' END),
        ri.CutoffUtc,
        StartedAt = ri.StartedAt,
        EndedAt = ri.EndedAt,
        RunStatus = r.Status,
        RunItemStatus = ri.Status,
        ri.BatchesDone,
        ri.DocsDone,
        ri.RowsDeleted,
        ri.RowsArchived,
        r.HostName,
        r.AppName,
        r.InitiatedBy,
        RunErrorMessage = r.ErrorMessage,
        RunItemErrorMessage = ri.ErrorMessage
    FROM arch.RunDocAudit a
    JOIN arch.RunItem ri
      ON ri.RunItemId = a.RunItemId
    JOIN arch.Run r
      ON r.RunId = ri.RunId
    JOIN arch.Process p
      ON p.ProcessId = ri.ProcessId
    WHERE @Search IS NOT NULL
      AND a.DocKey = @Search
      AND (@ProcessCode IS NULL OR a.ProcessCode = @ProcessCode OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR r.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR r.ArchiveDb = @ArchiveDb)
    ORDER BY
        a.DeletedAt DESC,
        a.RunDocAuditId DESC;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_ValidateConfiguration]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Findings
    (
        Severity varchar(10) NOT NULL,
        ProcessCode sysname NULL,
        SourceDb sysname NULL,
        ArchiveDb sysname NULL,
        ObjectName nvarchar(300) NULL,
        Finding nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL
    );

    INSERT INTO #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql)
    EXEC arch.usp_ValidateConfiguration
        @ProcessCode = @ProcessCode,
        @SourceDb = @SourceDb;

    DECLARE @ReturnCode int =
        CASE WHEN EXISTS (SELECT 1 FROM #Findings WHERE Severity = 'ERROR') THEN 1 ELSE 0 END;

    SELECT
        ReturnCode = @ReturnCode,
        Severity,
        ProcessCode,
        SourceDb,
        ArchiveDb,
        ObjectName,
        Finding,
        SuggestedSql
    FROM #Findings
    ORDER BY
        CASE Severity WHEN 'ERROR' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END,
        ProcessCode,
        SourceDb,
        ObjectName;

    RETURN COALESCE(@ReturnCode, 0);
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_ValidateIndexRequirements]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Findings
    (
        Severity varchar(10) NOT NULL,
        ProcessCode sysname NOT NULL,
        SourceDb sysname NULL,
        ObjectName nvarchar(300) NOT NULL,
        RequirementType nvarchar(20) NOT NULL,
        KeyColumnsCsv nvarchar(1000) NOT NULL,
        Finding nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL
    );

    INSERT INTO #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding, SuggestedSql)
    EXEC arch.usp_ValidateIndexRequirements
        @ProcessCode = @ProcessCode,
        @SourceDb = @SourceDb;

    DECLARE @ReturnCode int =
        CASE WHEN EXISTS (SELECT 1 FROM #Findings WHERE Severity = 'ERROR') THEN 1 ELSE 0 END;

    SELECT
        ReturnCode = @ReturnCode,
        Severity,
        ProcessCode,
        SourceDb,
        ArchiveDb = CONVERT(sysname, NULL),
        ObjectName,
        RequirementType,
        KeyColumnsCsv,
        Finding,
        SuggestedSql
    FROM #Findings
    ORDER BY
        CASE Severity WHEN 'ERROR' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END,
        ProcessCode,
        SourceDb,
        ObjectName,
        RequirementType;

    RETURN COALESCE(@ReturnCode, 0);
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_ExplainProcessPlan]
    @ProcessCode sysname,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    EXEC arch.usp_ExplainProcessPlan
        @ProcessCode = @ProcessCode,
        @SourceDb = @SourceDb;
END
GO
-- <<< end: kArchiveManagerAdmin\frontend\002_frontend_lookup_validation_api.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\frontend\003_frontend_config_lookup_api.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetProcessKeySpecs]
    @ProcessCode sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pks.ProcessKeySpecId,
        p.ProcessId,
        p.ProcessCode,
        pks.KeyOrdinal,
        pks.KeyName,
        pks.SourceExpressionSql,
        pks.SqlType,
        pks.IsRequired,
        pks.CreatedAt,
        pks.ModifiedAt
    FROM arch.ProcessKeySpec pks
    JOIN arch.Process p
      ON p.ProcessId = pks.ProcessId
    WHERE (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
    ORDER BY
        p.ProcessCode,
        pks.KeyOrdinal;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetIndexRequirements]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @RequirementType nvarchar(20) = NULL,
    @MandatoryOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ir.IndexRequirementId,
        ir.ProcessId,
        p.ProcessCode,
        ir.ObjectSpecId,
        ObjectName =
            CASE
                WHEN os.ObjectSpecId IS NULL THEN NULL
                ELSE QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable)
            END,
        ir.RequirementType,
        ir.SourceSchema,
        ir.SourceTable,
        ir.KeyColumnsCsv,
        ir.IncludeColumnsCsv,
        ir.FilterSql,
        ir.IsMandatory,
        ir.Notes,
        ir.CreatedAt,
        ir.ModifiedAt,
        EnabledMappingCount = COALESCE(mapCounts.EnabledMappingCount, CONVERT(bigint, 0))
    FROM arch.IndexRequirement ir
    JOIN arch.Process p
      ON p.ProcessId = ir.ProcessId
    LEFT JOIN arch.ObjectSpec os
      ON os.ObjectSpecId = ir.ObjectSpecId
    OUTER APPLY
    (
        SELECT EnabledMappingCount = COUNT_BIG(*)
        FROM arch.v_ProcessDatabaseEffective e
        WHERE e.ProcessId = p.ProcessId
          AND e.IsEnabled = 1
          AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
    ) mapCounts
    WHERE (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@RequirementType IS NULL OR ir.RequirementType = @RequirementType)
      AND (@MandatoryOnly = 0 OR ir.IsMandatory = 1)
      AND (@SourceDb IS NULL OR mapCounts.EnabledMappingCount > 0)
    ORDER BY
        p.ProcessCode,
        ir.RequirementType,
        ir.SourceSchema,
        ir.SourceTable,
        ir.IndexRequirementId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetRunProfiles]
    @RunProfileCode sysname = NULL,
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @IncludeDisabled bit = 1,
    @ScheduledOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        rp.RunProfileId,
        rp.RunProfileCode,
        rp.Description,
        rp.IsEnabled,
        rp.RunOnSchedule,
        rp.RunOrder,
        rp.ProcessCodeFilter,
        rp.SourceDbFilter,
        rp.ArchiveDbFilter,
        rp.RunWindowMinutes,
        rp.DryRun,
        rp.MaxCandidates,
        rp.PausedCooldownSeconds,
        rp.CreatedAt,
        rp.ModifiedAt,
        MatchingEnabledTargetCount = COALESCE(targetCounts.MatchingEnabledTargetCount, CONVERT(bigint, 0))
    FROM arch.RunProfile rp
    OUTER APPLY
    (
        SELECT MatchingEnabledTargetCount = COUNT_BIG(*)
        FROM arch.v_ProcessDatabaseEffective e
        WHERE e.IsEnabled = 1
          AND (rp.ProcessCodeFilter IS NULL OR e.ProcessCode = rp.ProcessCodeFilter)
          AND (rp.SourceDbFilter IS NULL OR e.SourceDb = rp.SourceDbFilter)
          AND (rp.ArchiveDbFilter IS NULL OR e.ArchiveDb = rp.ArchiveDbFilter)
          AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
          AND (@ArchiveDb IS NULL OR e.ArchiveDb = @ArchiveDb)
    ) targetCounts
    WHERE (@RunProfileCode IS NULL OR rp.RunProfileCode = @RunProfileCode)
      AND (@IncludeDisabled = 1 OR rp.IsEnabled = 1)
      AND (@ScheduledOnly = 0 OR rp.RunOnSchedule = 1)
      AND (@ProcessCode IS NULL OR rp.ProcessCodeFilter IS NULL OR rp.ProcessCodeFilter = @ProcessCode)
      AND (@SourceDb IS NULL OR rp.SourceDbFilter IS NULL OR rp.SourceDbFilter = @SourceDb)
      AND (@ArchiveDb IS NULL OR rp.ArchiveDbFilter IS NULL OR rp.ArchiveDbFilter = @ArchiveDb)
    ORDER BY
        rp.RunOrder,
        rp.RunProfileCode;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetSelectionStrategies]
    @IncludeDisabled bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        StrategyCode,
        Description,
        RequiresAnchor,
        RequiresTimestamp,
        RequiresRange,
        RequiresExternalKeyset,
        IsEnabled
    FROM arch.SelectionStrategy
    WHERE (@IncludeDisabled = 1 OR IsEnabled = 1)
    ORDER BY StrategyCode;
END
GO

-- <<< end: kArchiveManagerAdmin\frontend\003_frontend_config_lookup_api.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\frontend\005_frontend_process_write_api.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveProcess]
    @ProcessCode nvarchar(50),
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @Description nvarchar(200) = NULL,
    @IsEnabled bit = 1,
    @Mode tinyint = 1,
    @RetentionDays int = 540,
    @CutoffSafetyLagMinutes int = 1440,
    @BatchDocCount int = NULL,
    @BatchRowCount int = NULL,
    @MaxBatchesPerRun int = 50,
    @DelayMsBetweenBatches int = 0,
    @UseAppLock bit = 1,
    @AppLockResource nvarchar(200) = NULL,
    @LockTimeoutMs int = 10000,
    @DeadlockPriority nvarchar(10) = N'LOW',
    @AnchorSchema sysname = NULL,
    @AnchorTable sysname = NULL,
    @AnchorDocKeyExpr nvarchar(4000) = NULL,
    @AnchorDocKey2Expr nvarchar(4000) = NULL,
    @AnchorTimestampExpr nvarchar(4000) = NULL,
    @AnchorExtraWhereSql nvarchar(4000) = NULL,
    @AllowDeleteWithoutArchive bit = 0,
    @CutoffMode tinyint = 0,
    @CutoffDate datetime2(0) = NULL,
    @DocKeyLabel nvarchar(50) = N'DOCKEY',
    @AuditLevel nvarchar(20) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ProcessCode = NULLIF(LTRIM(RTRIM(@ProcessCode)), N'');
    SET @AuditLevel = UPPER(NULLIF(LTRIM(RTRIM(@AuditLevel)), N''));   -- T-08: base process audit level

    IF @AuditLevel IS NOT NULL AND @AuditLevel NOT IN (N'NONE', N'BATCH', N'OBJECT', N'ROW')
        THROW 56508, 'AuditLevel must be NONE, BATCH, OBJECT, or ROW.', 1;
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;
    SET @DeadlockPriority = COALESCE(UPPER(NULLIF(LTRIM(RTRIM(@DeadlockPriority)), N'')), N'LOW');
    SET @DocKeyLabel = COALESCE(NULLIF(LTRIM(RTRIM(@DocKeyLabel)), N''), N'DOCKEY');

    IF @ProcessCode IS NULL
        THROW 56500, 'ProcessCode is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56501, 'RequestedBy is required.', 1;

    IF @IsEnabled IS NULL
       OR @Mode IS NULL
       OR @RetentionDays IS NULL
       OR @CutoffSafetyLagMinutes IS NULL
       OR @MaxBatchesPerRun IS NULL
       OR @DelayMsBetweenBatches IS NULL
       OR @UseAppLock IS NULL
       OR @LockTimeoutMs IS NULL
       OR @AllowDeleteWithoutArchive IS NULL
       OR @CutoffMode IS NULL
        THROW 56507, 'Required process values must not be NULL.', 1;

    IF @Mode NOT IN (0, 1, 2)
        THROW 56502, 'Mode must be 0 (delete-only), 1 (archive+delete) or 2 (copy-only).', 1;

    IF @CutoffMode NOT IN (0, 1)
        THROW 56503, 'CutoffMode must be 0 or 1.', 1;

    IF @RetentionDays < 0
       OR @CutoffSafetyLagMinutes < 0
       OR (@BatchDocCount IS NOT NULL AND @BatchDocCount <= 0)
       OR (@BatchRowCount IS NOT NULL AND @BatchRowCount <= 0)
       OR @MaxBatchesPerRun <= 0
       OR @DelayMsBetweenBatches < 0
       OR @LockTimeoutMs < 0
        THROW 56504, 'Process numeric limits are invalid.', 1;

    IF @DeadlockPriority NOT IN (N'LOW', N'NORMAL', N'HIGH')
        THROW 56505, 'DeadlockPriority must be LOW, NORMAL, or HIGH.', 1;

    -- T-05: validate the advanced free-text expressions before persisting — they are concatenated
    -- into the runner's dynamic candidate/DELETE SQL against production source databases.
    EXEC arch.usp_AssertSafeSqlExpression @AnchorDocKeyExpr, N'AnchorDocKeyExpr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorDocKey2Expr, N'AnchorDocKey2Expr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorTimestampExpr, N'AnchorTimestampExpr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorExtraWhereSql, N'AnchorExtraWhereSql';

    DECLARE
        @Operation nvarchar(20),
        @ProcessId int,
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldDescription nvarchar(200),
        @OldIsEnabled bit,
        @OldMode tinyint,
        @OldRetentionDays int,
        @OldCutoffSafetyLagMinutes int,
        @OldBatchDocCount int,
        @OldBatchRowCount int,
        @OldMaxBatchesPerRun int,
        @OldDelayMsBetweenBatches int,
        @OldUseAppLock bit,
        @OldAppLockResource nvarchar(200),
        @OldLockTimeoutMs int,
        @OldDeadlockPriority nvarchar(10),
        @OldAnchorSchema sysname,
        @OldAnchorTable sysname,
        @OldAnchorDocKeyExpr nvarchar(4000),
        @OldAnchorDocKey2Expr nvarchar(4000),
        @OldAnchorTimestampExpr nvarchar(4000),
        @OldAnchorExtraWhereSql nvarchar(4000),
        @OldAllowDeleteWithoutArchive bit,
        @OldCutoffMode tinyint,
        @OldCutoffDate datetime2(0),
        @OldDocKeyLabel nvarchar(50),
        @OldAuditLevel nvarchar(20);

    DECLARE @Audit table
    (
        FieldName sysname NOT NULL,
        OldValue nvarchar(max) NULL,
        NewValue nvarchar(max) NULL,
        IsAdvancedField bit NOT NULL
    );

    BEGIN TRAN;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            @Now,
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56506, 'ConfigChangeSetId does not exist.', 1;

    SELECT
        @ProcessId = ProcessId,
        @OldDescription = Description,
        @OldIsEnabled = IsEnabled,
        @OldMode = Mode,
        @OldRetentionDays = RetentionDays,
        @OldCutoffSafetyLagMinutes = CutoffSafetyLagMinutes,
        @OldBatchDocCount = BatchDocCount,
        @OldBatchRowCount = BatchRowCount,
        @OldMaxBatchesPerRun = MaxBatchesPerRun,
        @OldDelayMsBetweenBatches = DelayMsBetweenBatches,
        @OldUseAppLock = UseAppLock,
        @OldAppLockResource = AppLockResource,
        @OldLockTimeoutMs = LockTimeoutMs,
        @OldDeadlockPriority = DeadlockPriority,
        @OldAnchorSchema = AnchorSchema,
        @OldAnchorTable = AnchorTable,
        @OldAnchorDocKeyExpr = AnchorDocKeyExpr,
        @OldAnchorDocKey2Expr = AnchorDocKey2Expr,
        @OldAnchorTimestampExpr = AnchorTimestampExpr,
        @OldAnchorExtraWhereSql = AnchorExtraWhereSql,
        @OldAllowDeleteWithoutArchive = AllowDeleteWithoutArchive,
        @OldCutoffMode = CutoffMode,
        @OldCutoffDate = CutoffDate,
        @OldDocKeyLabel = DocKeyLabel,
        @OldAuditLevel = AuditLevel
    FROM arch.Process
    WHERE ProcessCode = @ProcessCode;

    SET @Operation = CASE WHEN @ProcessId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode;

    IF @ProcessId IS NULL
    BEGIN
        INSERT INTO arch.Process
        (
            ProcessCode,
            Description,
            IsEnabled,
            Mode,
            RetentionDays,
            CutoffSafetyLagMinutes,
            BatchDocCount,
            BatchRowCount,
            MaxBatchesPerRun,
            DelayMsBetweenBatches,
            UseAppLock,
            AppLockResource,
            LockTimeoutMs,
            DeadlockPriority,
            AnchorSchema,
            AnchorTable,
            AnchorDocKeyExpr,
            AnchorDocKey2Expr,
            AnchorTimestampExpr,
            AnchorExtraWhereSql,
            AllowDeleteWithoutArchive,
            CreatedAt,
            ModifiedAt,
            CutoffMode,
            CutoffDate,
            DocKeyLabel,
            AuditLevel
        )
        VALUES
        (
            @ProcessCode,
            @Description,
            @IsEnabled,
            @Mode,
            @RetentionDays,
            @CutoffSafetyLagMinutes,
            @BatchDocCount,
            @BatchRowCount,
            @MaxBatchesPerRun,
            @DelayMsBetweenBatches,
            @UseAppLock,
            @AppLockResource,
            @LockTimeoutMs,
            @DeadlockPriority,
            @AnchorSchema,
            @AnchorTable,
            @AnchorDocKeyExpr,
            @AnchorDocKey2Expr,
            @AnchorTimestampExpr,
            @AnchorExtraWhereSql,
            @AllowDeleteWithoutArchive,
            @Now,
            @Now,
            @CutoffMode,
            @CutoffDate,
            @DocKeyLabel,
            @AuditLevel
        );

        SET @ProcessId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.Process
        SET
            Description = @Description,
            IsEnabled = @IsEnabled,
            Mode = @Mode,
            RetentionDays = @RetentionDays,
            CutoffSafetyLagMinutes = @CutoffSafetyLagMinutes,
            BatchDocCount = @BatchDocCount,
            BatchRowCount = @BatchRowCount,
            MaxBatchesPerRun = @MaxBatchesPerRun,
            DelayMsBetweenBatches = @DelayMsBetweenBatches,
            UseAppLock = @UseAppLock,
            AppLockResource = @AppLockResource,
            LockTimeoutMs = @LockTimeoutMs,
            DeadlockPriority = @DeadlockPriority,
            AnchorSchema = @AnchorSchema,
            AnchorTable = @AnchorTable,
            AnchorDocKeyExpr = @AnchorDocKeyExpr,
            AnchorDocKey2Expr = @AnchorDocKey2Expr,
            AnchorTimestampExpr = @AnchorTimestampExpr,
            AnchorExtraWhereSql = @AnchorExtraWhereSql,
            AllowDeleteWithoutArchive = @AllowDeleteWithoutArchive,
            ModifiedAt = @Now,
            CutoffMode = @CutoffMode,
            CutoffDate = @CutoffDate,
            DocKeyLabel = @DocKeyLabel,
            AuditLevel = @AuditLevel
        WHERE ProcessId = @ProcessId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessCode', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ProcessCode END, @ProcessCode, 0),
        (N'Description', @OldDescription, @Description, 0),
        (N'IsEnabled', CONVERT(nvarchar(30), @OldIsEnabled), CONVERT(nvarchar(30), @IsEnabled), 0),
        (N'Mode', CONVERT(nvarchar(30), @OldMode), CONVERT(nvarchar(30), @Mode), 0),
        (N'RetentionDays', CONVERT(nvarchar(30), @OldRetentionDays), CONVERT(nvarchar(30), @RetentionDays), 0),
        (N'CutoffSafetyLagMinutes', CONVERT(nvarchar(30), @OldCutoffSafetyLagMinutes), CONVERT(nvarchar(30), @CutoffSafetyLagMinutes), 0),
        (N'BatchDocCount', CONVERT(nvarchar(30), @OldBatchDocCount), CONVERT(nvarchar(30), @BatchDocCount), 0),
        (N'BatchRowCount', CONVERT(nvarchar(30), @OldBatchRowCount), CONVERT(nvarchar(30), @BatchRowCount), 0),
        (N'MaxBatchesPerRun', CONVERT(nvarchar(30), @OldMaxBatchesPerRun), CONVERT(nvarchar(30), @MaxBatchesPerRun), 0),
        (N'DelayMsBetweenBatches', CONVERT(nvarchar(30), @OldDelayMsBetweenBatches), CONVERT(nvarchar(30), @DelayMsBetweenBatches), 0),
        (N'UseAppLock', CONVERT(nvarchar(30), @OldUseAppLock), CONVERT(nvarchar(30), @UseAppLock), 1),
        (N'AppLockResource', @OldAppLockResource, @AppLockResource, 1),
        (N'LockTimeoutMs', CONVERT(nvarchar(30), @OldLockTimeoutMs), CONVERT(nvarchar(30), @LockTimeoutMs), 1),
        (N'DeadlockPriority', @OldDeadlockPriority, @DeadlockPriority, 1),
        (N'AnchorSchema', @OldAnchorSchema, @AnchorSchema, 1),
        (N'AnchorTable', @OldAnchorTable, @AnchorTable, 1),
        (N'AnchorDocKeyExpr', @OldAnchorDocKeyExpr, @AnchorDocKeyExpr, 1),
        (N'AnchorDocKey2Expr', @OldAnchorDocKey2Expr, @AnchorDocKey2Expr, 1),
        (N'AnchorTimestampExpr', @OldAnchorTimestampExpr, @AnchorTimestampExpr, 1),
        (N'AnchorExtraWhereSql', @OldAnchorExtraWhereSql, @AnchorExtraWhereSql, 1),
        (N'AllowDeleteWithoutArchive', CONVERT(nvarchar(30), @OldAllowDeleteWithoutArchive), CONVERT(nvarchar(30), @AllowDeleteWithoutArchive), 1),
        (N'CutoffMode', CONVERT(nvarchar(30), @OldCutoffMode), CONVERT(nvarchar(30), @CutoffMode), 0),
        (N'CutoffDate', CONVERT(nvarchar(30), @OldCutoffDate, 126), CONVERT(nvarchar(30), @CutoffDate, 126), 0),
        (N'DocKeyLabel', @OldDocKeyLabel, @DocKeyLabel, 0),
        (N'AuditLevel', @OldAuditLevel, @AuditLevel, 0);

    DELETE FROM @Audit
    WHERE (OldValue = NewValue) OR (OldValue IS NULL AND NewValue IS NULL);

    IF EXISTS (SELECT 1 FROM @Audit)
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'Process',
            @EntityKey,
            @Operation,
            @ProcessId,
            @Now
        );

        SET @ConfigChangeItemId = CONVERT(bigint, SCOPE_IDENTITY());

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        SELECT
            @ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        FROM @Audit
        ORDER BY FieldName;
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Process configuration saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        p.ProcessId,
        p.ProcessCode,
        p.Description,
        p.IsEnabled,
        p.Mode,
        p.RetentionDays,
        p.CutoffSafetyLagMinutes,
        p.BatchDocCount,
        p.BatchRowCount,
        p.MaxBatchesPerRun,
        p.DelayMsBetweenBatches,
        p.UseAppLock,
        p.AppLockResource,
        p.LockTimeoutMs,
        p.DeadlockPriority,
        p.AnchorSchema,
        p.AnchorTable,
        p.AnchorDocKeyExpr,
        p.AnchorDocKey2Expr,
        p.AnchorTimestampExpr,
        p.AnchorExtraWhereSql,
        p.AllowDeleteWithoutArchive,
        p.CutoffMode,
        p.CutoffDate,
        p.DocKeyLabel,
        p.ModifiedAt
    FROM arch.Process p
    WHERE p.ProcessId = @ProcessId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveProcessDatabase]
    @ProcessCode nvarchar(50),
    @SourceDb sysname,
    @ArchiveDb sysname,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @IsEnabled bit = 1,
    @RunOrder int = 100,
    @Mode tinyint = NULL,
    @RetentionDays int = NULL,
    @CutoffSafetyLagMinutes int = NULL,
    @CutoffMode tinyint = NULL,
    @CutoffDate datetime2(0) = NULL,
    @BatchDocCount int = NULL,
    @BatchRowCount int = NULL,
    @MaxBatchesPerRun int = NULL,
    @DelayMsBetweenBatches int = NULL,
    @UseAppLock bit = NULL,
    @AppLockResource nvarchar(200) = NULL,
    @LockTimeoutMs int = NULL,
    @DeadlockPriority nvarchar(10) = NULL,
    @AnchorSchema sysname = NULL,
    @AnchorTable sysname = NULL,
    @AnchorDocKeyExpr nvarchar(4000) = NULL,
    @AnchorDocKey2Expr nvarchar(4000) = NULL,
    @AnchorTimestampExpr nvarchar(4000) = NULL,
    @AnchorExtraWhereSql nvarchar(4000) = NULL,
    @AllowDeleteWithoutArchive bit = NULL,
    @DocKeyLabel nvarchar(50) = NULL,
    @AuditLevel nvarchar(20) = NULL,
    @RequireSupportingIndex bit = NULL,
    @MaxRowsPerTransaction int = NULL,
    @CandidateWhereSql nvarchar(4000) = NULL,
    @CandidateOrderSql nvarchar(4000) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ProcessCode = NULLIF(LTRIM(RTRIM(@ProcessCode)), N'');
    SET @SourceDb = NULLIF(LTRIM(RTRIM(@SourceDb)), N'');
    SET @ArchiveDb = NULLIF(LTRIM(RTRIM(@ArchiveDb)), N'');
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;
    SET @DeadlockPriority = UPPER(NULLIF(LTRIM(RTRIM(@DeadlockPriority)), N''));
    SET @AuditLevel = UPPER(NULLIF(LTRIM(RTRIM(@AuditLevel)), N''));
    SET @DocKeyLabel = NULLIF(LTRIM(RTRIM(@DocKeyLabel)), N'');

    IF @ProcessCode IS NULL
        THROW 56520, 'ProcessCode is required.', 1;

    IF @SourceDb IS NULL
        THROW 56521, 'SourceDb is required.', 1;

    IF @ArchiveDb IS NULL
        THROW 56522, 'ArchiveDb is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56523, 'RequestedBy is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56530, 'IsEnabled is required.', 1;

    IF @RunOrder IS NULL
        THROW 56524, 'RunOrder is required.', 1;

    IF (@Mode IS NOT NULL AND @Mode NOT IN (0, 1, 2))
       OR (@CutoffMode IS NOT NULL AND @CutoffMode NOT IN (0, 1))
       OR (@RetentionDays IS NOT NULL AND @RetentionDays < 0)
       OR (@CutoffSafetyLagMinutes IS NOT NULL AND @CutoffSafetyLagMinutes < 0)
       OR (@BatchDocCount IS NOT NULL AND @BatchDocCount <= 0)
       OR (@BatchRowCount IS NOT NULL AND @BatchRowCount <= 0)
       OR (@MaxBatchesPerRun IS NOT NULL AND @MaxBatchesPerRun <= 0)
       OR (@DelayMsBetweenBatches IS NOT NULL AND @DelayMsBetweenBatches < 0)
       OR (@LockTimeoutMs IS NOT NULL AND @LockTimeoutMs < 0)
       OR (@MaxRowsPerTransaction IS NOT NULL AND @MaxRowsPerTransaction <= 0)
        THROW 56525, 'ProcessDatabase override limits are invalid.', 1;

    IF @DeadlockPriority IS NOT NULL AND @DeadlockPriority NOT IN (N'LOW', N'NORMAL', N'HIGH')
        THROW 56526, 'DeadlockPriority must be LOW, NORMAL, or HIGH.', 1;

    IF @AuditLevel IS NOT NULL AND @AuditLevel NOT IN (N'NONE', N'BATCH', N'OBJECT', N'ROW')
        THROW 56527, 'AuditLevel must be NONE, BATCH, OBJECT, or ROW.', 1;

    -- T-05: validate the advanced free-text override expressions before persisting — they feed the
    -- runner's dynamic candidate/DELETE SQL against production source databases.
    EXEC arch.usp_AssertSafeSqlExpression @AnchorDocKeyExpr, N'AnchorDocKeyExpr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorDocKey2Expr, N'AnchorDocKey2Expr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorTimestampExpr, N'AnchorTimestampExpr';
    EXEC arch.usp_AssertSafeSqlExpression @AnchorExtraWhereSql, N'AnchorExtraWhereSql';
    EXEC arch.usp_AssertSafeSqlExpression @CandidateWhereSql, N'CandidateWhereSql';
    EXEC arch.usp_AssertSafeSqlExpression @CandidateOrderSql, N'CandidateOrderSql';

    DECLARE
        @Operation nvarchar(20),
        @ProcessId int,
        @ProcessDatabaseId int,
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldIsEnabled bit,
        @OldRunOrder int,
        @OldMode tinyint,
        @OldRetentionDays int,
        @OldCutoffSafetyLagMinutes int,
        @OldCutoffMode tinyint,
        @OldCutoffDate datetime2(0),
        @OldBatchDocCount int,
        @OldBatchRowCount int,
        @OldMaxBatchesPerRun int,
        @OldDelayMsBetweenBatches int,
        @OldUseAppLock bit,
        @OldAppLockResource nvarchar(200),
        @OldLockTimeoutMs int,
        @OldDeadlockPriority nvarchar(10),
        @OldAnchorSchema sysname,
        @OldAnchorTable sysname,
        @OldAnchorDocKeyExpr nvarchar(4000),
        @OldAnchorDocKey2Expr nvarchar(4000),
        @OldAnchorTimestampExpr nvarchar(4000),
        @OldAnchorExtraWhereSql nvarchar(4000),
        @OldAllowDeleteWithoutArchive bit,
        @OldDocKeyLabel nvarchar(50),
        @OldAuditLevel nvarchar(20),
        @OldRequireSupportingIndex bit,
        @OldMaxRowsPerTransaction int,
        @OldCandidateWhereSql nvarchar(4000),
        @OldCandidateOrderSql nvarchar(4000);

    DECLARE @Audit table
    (
        FieldName sysname NOT NULL,
        OldValue nvarchar(max) NULL,
        NewValue nvarchar(max) NULL,
        IsAdvancedField bit NOT NULL
    );

    BEGIN TRAN;

    SELECT @ProcessId = ProcessId
    FROM arch.Process
    WHERE ProcessCode = @ProcessCode;

    IF @ProcessId IS NULL
        THROW 56528, 'ProcessCode does not exist.', 1;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            @Now,
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56529, 'ConfigChangeSetId does not exist.', 1;

    SELECT
        @ProcessDatabaseId = ProcessDatabaseId,
        @OldIsEnabled = IsEnabled,
        @OldRunOrder = RunOrder,
        @OldMode = Mode,
        @OldRetentionDays = RetentionDays,
        @OldCutoffSafetyLagMinutes = CutoffSafetyLagMinutes,
        @OldCutoffMode = CutoffMode,
        @OldCutoffDate = CutoffDate,
        @OldBatchDocCount = BatchDocCount,
        @OldBatchRowCount = BatchRowCount,
        @OldMaxBatchesPerRun = MaxBatchesPerRun,
        @OldDelayMsBetweenBatches = DelayMsBetweenBatches,
        @OldUseAppLock = UseAppLock,
        @OldAppLockResource = AppLockResource,
        @OldLockTimeoutMs = LockTimeoutMs,
        @OldDeadlockPriority = DeadlockPriority,
        @OldAnchorSchema = AnchorSchema,
        @OldAnchorTable = AnchorTable,
        @OldAnchorDocKeyExpr = AnchorDocKeyExpr,
        @OldAnchorDocKey2Expr = AnchorDocKey2Expr,
        @OldAnchorTimestampExpr = AnchorTimestampExpr,
        @OldAnchorExtraWhereSql = AnchorExtraWhereSql,
        @OldAllowDeleteWithoutArchive = AllowDeleteWithoutArchive,
        @OldDocKeyLabel = DocKeyLabel,
        @OldAuditLevel = AuditLevel,
        @OldRequireSupportingIndex = RequireSupportingIndex,
        @OldMaxRowsPerTransaction = MaxRowsPerTransaction,
        @OldCandidateWhereSql = CandidateWhereSql,
        @OldCandidateOrderSql = CandidateOrderSql
    FROM arch.ProcessDatabase
    WHERE ProcessId = @ProcessId
      AND SourceDb = @SourceDb
      AND ArchiveDb = @ArchiveDb;

    SET @Operation = CASE WHEN @ProcessDatabaseId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + @SourceDb + N'|' + @ArchiveDb;

    IF @ProcessDatabaseId IS NULL
    BEGIN
        INSERT INTO arch.ProcessDatabase
        (
            ProcessId,
            SourceDb,
            ArchiveDb,
            IsEnabled,
            RunOrder,
            Mode,
            RetentionDays,
            CutoffSafetyLagMinutes,
            CutoffMode,
            CutoffDate,
            BatchDocCount,
            BatchRowCount,
            MaxBatchesPerRun,
            DelayMsBetweenBatches,
            UseAppLock,
            AppLockResource,
            LockTimeoutMs,
            DeadlockPriority,
            AnchorSchema,
            AnchorTable,
            AnchorDocKeyExpr,
            AnchorDocKey2Expr,
            AnchorTimestampExpr,
            AnchorExtraWhereSql,
            AllowDeleteWithoutArchive,
            DocKeyLabel,
            AuditLevel,
            RequireSupportingIndex,
            MaxRowsPerTransaction,
            CandidateWhereSql,
            CandidateOrderSql,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @ProcessId,
            @SourceDb,
            @ArchiveDb,
            @IsEnabled,
            @RunOrder,
            @Mode,
            @RetentionDays,
            @CutoffSafetyLagMinutes,
            @CutoffMode,
            @CutoffDate,
            @BatchDocCount,
            @BatchRowCount,
            @MaxBatchesPerRun,
            @DelayMsBetweenBatches,
            @UseAppLock,
            @AppLockResource,
            @LockTimeoutMs,
            @DeadlockPriority,
            @AnchorSchema,
            @AnchorTable,
            @AnchorDocKeyExpr,
            @AnchorDocKey2Expr,
            @AnchorTimestampExpr,
            @AnchorExtraWhereSql,
            @AllowDeleteWithoutArchive,
            @DocKeyLabel,
            @AuditLevel,
            @RequireSupportingIndex,
            @MaxRowsPerTransaction,
            @CandidateWhereSql,
            @CandidateOrderSql,
            @Now,
            @Now
        );

        SET @ProcessDatabaseId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.ProcessDatabase
        SET
            IsEnabled = @IsEnabled,
            RunOrder = @RunOrder,
            Mode = @Mode,
            RetentionDays = @RetentionDays,
            CutoffSafetyLagMinutes = @CutoffSafetyLagMinutes,
            CutoffMode = @CutoffMode,
            CutoffDate = @CutoffDate,
            BatchDocCount = @BatchDocCount,
            BatchRowCount = @BatchRowCount,
            MaxBatchesPerRun = @MaxBatchesPerRun,
            DelayMsBetweenBatches = @DelayMsBetweenBatches,
            UseAppLock = @UseAppLock,
            AppLockResource = @AppLockResource,
            LockTimeoutMs = @LockTimeoutMs,
            DeadlockPriority = @DeadlockPriority,
            AnchorSchema = @AnchorSchema,
            AnchorTable = @AnchorTable,
            AnchorDocKeyExpr = @AnchorDocKeyExpr,
            AnchorDocKey2Expr = @AnchorDocKey2Expr,
            AnchorTimestampExpr = @AnchorTimestampExpr,
            AnchorExtraWhereSql = @AnchorExtraWhereSql,
            AllowDeleteWithoutArchive = @AllowDeleteWithoutArchive,
            DocKeyLabel = @DocKeyLabel,
            AuditLevel = @AuditLevel,
            RequireSupportingIndex = @RequireSupportingIndex,
            MaxRowsPerTransaction = @MaxRowsPerTransaction,
            CandidateWhereSql = @CandidateWhereSql,
            CandidateOrderSql = @CandidateOrderSql,
            ModifiedAt = @Now
        WHERE ProcessDatabaseId = @ProcessDatabaseId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessCode', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ProcessCode END, @ProcessCode, 0),
        (N'SourceDb', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @SourceDb END, @SourceDb, 0),
        (N'ArchiveDb', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ArchiveDb END, @ArchiveDb, 0),
        (N'IsEnabled', CONVERT(nvarchar(30), @OldIsEnabled), CONVERT(nvarchar(30), @IsEnabled), 0),
        (N'RunOrder', CONVERT(nvarchar(30), @OldRunOrder), CONVERT(nvarchar(30), @RunOrder), 0),
        (N'Mode', CONVERT(nvarchar(30), @OldMode), CONVERT(nvarchar(30), @Mode), 0),
        (N'RetentionDays', CONVERT(nvarchar(30), @OldRetentionDays), CONVERT(nvarchar(30), @RetentionDays), 0),
        (N'CutoffSafetyLagMinutes', CONVERT(nvarchar(30), @OldCutoffSafetyLagMinutes), CONVERT(nvarchar(30), @CutoffSafetyLagMinutes), 0),
        (N'CutoffMode', CONVERT(nvarchar(30), @OldCutoffMode), CONVERT(nvarchar(30), @CutoffMode), 0),
        (N'CutoffDate', CONVERT(nvarchar(30), @OldCutoffDate, 126), CONVERT(nvarchar(30), @CutoffDate, 126), 0),
        (N'BatchDocCount', CONVERT(nvarchar(30), @OldBatchDocCount), CONVERT(nvarchar(30), @BatchDocCount), 0),
        (N'BatchRowCount', CONVERT(nvarchar(30), @OldBatchRowCount), CONVERT(nvarchar(30), @BatchRowCount), 0),
        (N'MaxBatchesPerRun', CONVERT(nvarchar(30), @OldMaxBatchesPerRun), CONVERT(nvarchar(30), @MaxBatchesPerRun), 0),
        (N'DelayMsBetweenBatches', CONVERT(nvarchar(30), @OldDelayMsBetweenBatches), CONVERT(nvarchar(30), @DelayMsBetweenBatches), 0),
        (N'UseAppLock', CONVERT(nvarchar(30), @OldUseAppLock), CONVERT(nvarchar(30), @UseAppLock), 1),
        (N'AppLockResource', @OldAppLockResource, @AppLockResource, 1),
        (N'LockTimeoutMs', CONVERT(nvarchar(30), @OldLockTimeoutMs), CONVERT(nvarchar(30), @LockTimeoutMs), 1),
        (N'DeadlockPriority', @OldDeadlockPriority, @DeadlockPriority, 1),
        (N'AnchorSchema', @OldAnchorSchema, @AnchorSchema, 1),
        (N'AnchorTable', @OldAnchorTable, @AnchorTable, 1),
        (N'AnchorDocKeyExpr', @OldAnchorDocKeyExpr, @AnchorDocKeyExpr, 1),
        (N'AnchorDocKey2Expr', @OldAnchorDocKey2Expr, @AnchorDocKey2Expr, 1),
        (N'AnchorTimestampExpr', @OldAnchorTimestampExpr, @AnchorTimestampExpr, 1),
        (N'AnchorExtraWhereSql', @OldAnchorExtraWhereSql, @AnchorExtraWhereSql, 1),
        (N'AllowDeleteWithoutArchive', CONVERT(nvarchar(30), @OldAllowDeleteWithoutArchive), CONVERT(nvarchar(30), @AllowDeleteWithoutArchive), 1),
        (N'DocKeyLabel', @OldDocKeyLabel, @DocKeyLabel, 0),
        (N'AuditLevel', @OldAuditLevel, @AuditLevel, 1),
        (N'RequireSupportingIndex', CONVERT(nvarchar(30), @OldRequireSupportingIndex), CONVERT(nvarchar(30), @RequireSupportingIndex), 1),
        (N'MaxRowsPerTransaction', CONVERT(nvarchar(30), @OldMaxRowsPerTransaction), CONVERT(nvarchar(30), @MaxRowsPerTransaction), 1),
        (N'CandidateWhereSql', @OldCandidateWhereSql, @CandidateWhereSql, 1),
        (N'CandidateOrderSql', @OldCandidateOrderSql, @CandidateOrderSql, 1);

    DELETE FROM @Audit
    WHERE (OldValue = NewValue) OR (OldValue IS NULL AND NewValue IS NULL);

    IF EXISTS (SELECT 1 FROM @Audit)
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'ProcessDatabase',
            @EntityKey,
            @Operation,
            @ProcessDatabaseId,
            @Now
        );

        SET @ConfigChangeItemId = CONVERT(bigint, SCOPE_IDENTITY());

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        SELECT
            @ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        FROM @Audit
        ORDER BY FieldName;
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Process database mapping saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        pd.ProcessDatabaseId,
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        pd.IsEnabled,
        pd.RunOrder,
        pd.Mode,
        pd.RetentionDays,
        pd.CutoffSafetyLagMinutes,
        pd.CutoffMode,
        pd.CutoffDate,
        pd.BatchDocCount,
        pd.BatchRowCount,
        pd.MaxBatchesPerRun,
        pd.DelayMsBetweenBatches,
        pd.UseAppLock,
        pd.AppLockResource,
        pd.LockTimeoutMs,
        pd.DeadlockPriority,
        pd.AnchorSchema,
        pd.AnchorTable,
        pd.AnchorDocKeyExpr,
        pd.AnchorDocKey2Expr,
        pd.AnchorTimestampExpr,
        pd.AnchorExtraWhereSql,
        pd.AllowDeleteWithoutArchive,
        pd.DocKeyLabel,
        pd.AuditLevel,
        pd.RequireSupportingIndex,
        pd.MaxRowsPerTransaction,
        pd.CandidateWhereSql,
        pd.CandidateOrderSql,
        pd.ModifiedAt
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    WHERE pd.ProcessDatabaseId = @ProcessDatabaseId;
END
GO
-- <<< end: kArchiveManagerAdmin\frontend\005_frontend_process_write_api.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\frontend\006_frontend_object_write_api.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveObjectSpec]
    @ObjectSpecId int = NULL OUTPUT,
    @ProcessCode sysname,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @SourceSchema sysname,
    @SourceTable sysname,
    @DeleteOrder int,
    @DeleteMode tinyint,
    @TimestampExpr nvarchar(4000) = NULL,
    @JoinToAnchorPredicateSql nvarchar(4000) = NULL,
    @AdditionalWhereSql nvarchar(4000) = NULL,
    @ArchiveSchema sysname = N'dbo',
    @ArchiveTable sysname = NULL,
    @RequireArchiveForDelete bit = 1,
    @NaturalKeyLabel nvarchar(50) = NULL,
    @CandidateSelectExpr nvarchar(4000) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ProcessCode = NULLIF(LTRIM(RTRIM(@ProcessCode)), N'');
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;
    SET @SourceSchema = NULLIF(LTRIM(RTRIM(@SourceSchema)), N'');
    SET @SourceTable = NULLIF(LTRIM(RTRIM(@SourceTable)), N'');
    SET @TimestampExpr = NULLIF(LTRIM(RTRIM(@TimestampExpr)), N'');
    SET @JoinToAnchorPredicateSql = NULLIF(LTRIM(RTRIM(@JoinToAnchorPredicateSql)), N'');
    SET @AdditionalWhereSql = NULLIF(LTRIM(RTRIM(@AdditionalWhereSql)), N'');
    SET @ArchiveSchema = COALESCE(NULLIF(LTRIM(RTRIM(@ArchiveSchema)), N''), N'dbo');
    SET @ArchiveTable = NULLIF(LTRIM(RTRIM(@ArchiveTable)), N'');
    SET @NaturalKeyLabel = NULLIF(LTRIM(RTRIM(@NaturalKeyLabel)), N'');
    SET @CandidateSelectExpr = NULLIF(LTRIM(RTRIM(@CandidateSelectExpr)), N'');

    IF @ProcessCode IS NULL
        THROW 56700, 'ProcessCode is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56701, 'RequestedBy is required.', 1;

    IF @SourceSchema IS NULL
        THROW 56702, 'SourceSchema is required.', 1;

    IF @SourceTable IS NULL
        THROW 56703, 'SourceTable is required.', 1;

    IF @DeleteOrder IS NULL
        THROW 56704, 'DeleteOrder is required.', 1;

    IF @DeleteMode IS NULL OR @DeleteMode NOT IN (0, 1)
        THROW 56705, 'DeleteMode must be 0 or 1.', 1;

    IF @RequireArchiveForDelete IS NULL
        THROW 56706, 'RequireArchiveForDelete is required.', 1;

    -- T-05: reject unsafe SQL in the advanced free-text fields before persisting — they are later
    -- concatenated into the runner's dynamic DELETE against production source databases.
    EXEC arch.usp_AssertSafeSqlExpression @TimestampExpr, N'TimestampExpr';
    EXEC arch.usp_AssertSafeSqlExpression @JoinToAnchorPredicateSql, N'JoinToAnchorPredicateSql';
    EXEC arch.usp_AssertSafeSqlExpression @AdditionalWhereSql, N'AdditionalWhereSql';
    EXEC arch.usp_AssertSafeSqlExpression @CandidateSelectExpr, N'CandidateSelectExpr';

    DECLARE
        @ProcessId int,
        @Operation nvarchar(20),
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldSourceSchema sysname,
        @OldSourceTable sysname,
        @OldDeleteOrder int,
        @OldDeleteMode tinyint,
        @OldTimestampExpr nvarchar(4000),
        @OldJoinToAnchorPredicateSql nvarchar(4000),
        @OldAdditionalWhereSql nvarchar(4000),
        @OldArchiveSchema sysname,
        @OldArchiveTable sysname,
        @OldRequireArchiveForDelete bit,
        @OldNaturalKeyLabel nvarchar(50),
        @OldCandidateSelectExpr nvarchar(4000);

    DECLARE @Audit table
    (
        FieldName sysname NOT NULL,
        OldValue nvarchar(max) NULL,
        NewValue nvarchar(max) NULL,
        IsAdvancedField bit NOT NULL
    );

    BEGIN TRAN;

    SELECT @ProcessId = ProcessId
    FROM arch.Process
    WHERE ProcessCode = @ProcessCode;

    IF @ProcessId IS NULL
        THROW 56707, 'ProcessCode does not exist.', 1;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            @Now,
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56708, 'ConfigChangeSetId does not exist.', 1;

    IF @ObjectSpecId IS NULL
    BEGIN
        SELECT TOP (1) @ObjectSpecId = ObjectSpecId
        FROM arch.ObjectSpec
        WHERE ProcessId = @ProcessId
          AND SourceSchema = @SourceSchema
          AND SourceTable = @SourceTable
        ORDER BY ObjectSpecId;
    END;

    IF @ObjectSpecId IS NOT NULL
    BEGIN
        SELECT
            @OldSourceSchema = SourceSchema,
            @OldSourceTable = SourceTable,
            @OldDeleteOrder = DeleteOrder,
            @OldDeleteMode = DeleteMode,
            @OldTimestampExpr = TimestampExpr,
            @OldJoinToAnchorPredicateSql = JoinToAnchorPredicateSql,
            @OldAdditionalWhereSql = AdditionalWhereSql,
            @OldArchiveSchema = ArchiveSchema,
            @OldArchiveTable = ArchiveTable,
            @OldRequireArchiveForDelete = RequireArchiveForDelete,
            @OldNaturalKeyLabel = NaturalKeyLabel,
            @OldCandidateSelectExpr = CandidateSelectExpr
        FROM arch.ObjectSpec
        WHERE ObjectSpecId = @ObjectSpecId
          AND ProcessId = @ProcessId;

        IF @@ROWCOUNT = 0
            THROW 56709, 'ObjectSpecId does not exist for the selected process.', 1;
    END;

    SET @Operation = CASE WHEN @ObjectSpecId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + @SourceSchema + N'.' + @SourceTable;

    IF @ObjectSpecId IS NULL
    BEGIN
        INSERT INTO arch.ObjectSpec
        (
            ProcessId,
            SourceSchema,
            SourceTable,
            DeleteOrder,
            DeleteMode,
            TimestampExpr,
            JoinToAnchorPredicateSql,
            AdditionalWhereSql,
            ArchiveSchema,
            ArchiveTable,
            RequireArchiveForDelete,
            NaturalKeyLabel,
            CandidateSelectExpr
        )
        VALUES
        (
            @ProcessId,
            @SourceSchema,
            @SourceTable,
            @DeleteOrder,
            @DeleteMode,
            @TimestampExpr,
            @JoinToAnchorPredicateSql,
            @AdditionalWhereSql,
            @ArchiveSchema,
            @ArchiveTable,
            @RequireArchiveForDelete,
            @NaturalKeyLabel,
            @CandidateSelectExpr
        );

        SET @ObjectSpecId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.ObjectSpec
        SET
            SourceSchema = @SourceSchema,
            SourceTable = @SourceTable,
            DeleteOrder = @DeleteOrder,
            DeleteMode = @DeleteMode,
            TimestampExpr = @TimestampExpr,
            JoinToAnchorPredicateSql = @JoinToAnchorPredicateSql,
            AdditionalWhereSql = @AdditionalWhereSql,
            ArchiveSchema = @ArchiveSchema,
            ArchiveTable = @ArchiveTable,
            RequireArchiveForDelete = @RequireArchiveForDelete,
            NaturalKeyLabel = @NaturalKeyLabel,
            CandidateSelectExpr = @CandidateSelectExpr
        WHERE ObjectSpecId = @ObjectSpecId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessCode', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ProcessCode END, @ProcessCode, 0),
        (N'SourceSchema', @OldSourceSchema, @SourceSchema, 0),
        (N'SourceTable', @OldSourceTable, @SourceTable, 0),
        (N'DeleteOrder', CONVERT(nvarchar(30), @OldDeleteOrder), CONVERT(nvarchar(30), @DeleteOrder), 0),
        (N'DeleteMode', CONVERT(nvarchar(30), @OldDeleteMode), CONVERT(nvarchar(30), @DeleteMode), 0),
        (N'TimestampExpr', @OldTimestampExpr, @TimestampExpr, 1),
        (N'JoinToAnchorPredicateSql', @OldJoinToAnchorPredicateSql, @JoinToAnchorPredicateSql, 1),
        (N'AdditionalWhereSql', @OldAdditionalWhereSql, @AdditionalWhereSql, 1),
        (N'ArchiveSchema', @OldArchiveSchema, @ArchiveSchema, 0),
        (N'ArchiveTable', @OldArchiveTable, @ArchiveTable, 0),
        (N'RequireArchiveForDelete', CONVERT(nvarchar(30), @OldRequireArchiveForDelete), CONVERT(nvarchar(30), @RequireArchiveForDelete), 0),
        (N'NaturalKeyLabel', @OldNaturalKeyLabel, @NaturalKeyLabel, 0),
        (N'CandidateSelectExpr', @OldCandidateSelectExpr, @CandidateSelectExpr, 1);

    DELETE FROM @Audit
    WHERE (OldValue = NewValue) OR (OldValue IS NULL AND NewValue IS NULL);

    IF EXISTS (SELECT 1 FROM @Audit)
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'ObjectSpec',
            @EntityKey,
            @Operation,
            @ObjectSpecId,
            @Now
        );

        SET @ConfigChangeItemId = CONVERT(bigint, SCOPE_IDENTITY());

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        SELECT
            @ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        FROM @Audit
        ORDER BY FieldName;
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Object specification saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        os.ObjectSpecId,
        p.ProcessCode,
        os.SourceSchema,
        os.SourceTable,
        os.DeleteOrder,
        os.DeleteMode,
        os.TimestampExpr,
        os.JoinToAnchorPredicateSql,
        os.AdditionalWhereSql,
        os.ArchiveSchema,
        os.ArchiveTable,
        os.RequireArchiveForDelete,
        os.NaturalKeyLabel,
        os.CandidateSelectExpr
    FROM arch.ObjectSpec os
    JOIN arch.Process p
      ON p.ProcessId = os.ProcessId
    WHERE os.ObjectSpecId = @ObjectSpecId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveObjectSpecOverride]
    @ObjectSpecDatabaseOverrideId int = NULL OUTPUT,
    @ProcessDatabaseId int,
    @ObjectSpecId int,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @IsEnabled bit = 1,
    @SourceSchemaOverride sysname = NULL,
    @SourceTableOverride sysname = NULL,
    @TimestampExprOverride nvarchar(4000) = NULL,
    @JoinToAnchorPredicateSqlOverride nvarchar(4000) = NULL,
    @AdditionalWhereSqlOverride nvarchar(4000) = NULL,
    @ArchiveSchemaOverride sysname = NULL,
    @ArchiveTableOverride sysname = NULL,
    @RequireArchiveForDeleteOverride bit = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;
    SET @SourceSchemaOverride = NULLIF(LTRIM(RTRIM(@SourceSchemaOverride)), N'');
    SET @SourceTableOverride = NULLIF(LTRIM(RTRIM(@SourceTableOverride)), N'');
    SET @TimestampExprOverride = NULLIF(LTRIM(RTRIM(@TimestampExprOverride)), N'');
    SET @JoinToAnchorPredicateSqlOverride = NULLIF(LTRIM(RTRIM(@JoinToAnchorPredicateSqlOverride)), N'');
    SET @AdditionalWhereSqlOverride = NULLIF(LTRIM(RTRIM(@AdditionalWhereSqlOverride)), N'');
    SET @ArchiveSchemaOverride = NULLIF(LTRIM(RTRIM(@ArchiveSchemaOverride)), N'');
    SET @ArchiveTableOverride = NULLIF(LTRIM(RTRIM(@ArchiveTableOverride)), N'');

    IF @ProcessDatabaseId IS NULL
        THROW 56720, 'ProcessDatabaseId is required.', 1;

    IF @ObjectSpecId IS NULL
        THROW 56721, 'ObjectSpecId is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56722, 'RequestedBy is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56723, 'IsEnabled is required.', 1;

    -- T-05: validate the advanced free-text override expressions before persisting — they feed the
    -- runner's dynamic DELETE against production source databases.
    EXEC arch.usp_AssertSafeSqlExpression @TimestampExprOverride, N'TimestampExprOverride';
    EXEC arch.usp_AssertSafeSqlExpression @JoinToAnchorPredicateSqlOverride, N'JoinToAnchorPredicateSqlOverride';
    EXEC arch.usp_AssertSafeSqlExpression @AdditionalWhereSqlOverride, N'AdditionalWhereSqlOverride';

    DECLARE
        @ProcessId int,
        @ObjectProcessId int,
        @ProcessCode sysname,
        @SourceDb sysname,
        @ArchiveDb sysname,
        @BaseSourceSchema sysname,
        @BaseSourceTable sysname,
        @Operation nvarchar(20),
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldIsEnabled bit,
        @OldSourceSchemaOverride sysname,
        @OldSourceTableOverride sysname,
        @OldTimestampExprOverride nvarchar(4000),
        @OldJoinToAnchorPredicateSqlOverride nvarchar(4000),
        @OldAdditionalWhereSqlOverride nvarchar(4000),
        @OldArchiveSchemaOverride sysname,
        @OldArchiveTableOverride sysname,
        @OldRequireArchiveForDeleteOverride bit;

    DECLARE @Audit table
    (
        FieldName sysname NOT NULL,
        OldValue nvarchar(max) NULL,
        NewValue nvarchar(max) NULL,
        IsAdvancedField bit NOT NULL
    );

    BEGIN TRAN;

    SELECT
        @ProcessId = pd.ProcessId,
        @ProcessCode = p.ProcessCode,
        @SourceDb = pd.SourceDb,
        @ArchiveDb = pd.ArchiveDb
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    WHERE pd.ProcessDatabaseId = @ProcessDatabaseId;

    IF @ProcessId IS NULL
        THROW 56724, 'ProcessDatabaseId does not exist.', 1;

    SELECT
        @ObjectProcessId = ProcessId,
        @BaseSourceSchema = SourceSchema,
        @BaseSourceTable = SourceTable
    FROM arch.ObjectSpec
    WHERE ObjectSpecId = @ObjectSpecId;

    IF @ObjectProcessId IS NULL
        THROW 56725, 'ObjectSpecId does not exist.', 1;

    IF @ObjectProcessId <> @ProcessId
        THROW 56726, 'ObjectSpecId does not belong to the same process as ProcessDatabaseId.', 1;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            @Now,
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56727, 'ConfigChangeSetId does not exist.', 1;

    IF @ObjectSpecDatabaseOverrideId IS NULL
    BEGIN
        SELECT @ObjectSpecDatabaseOverrideId = ObjectSpecDatabaseOverrideId
        FROM arch.ObjectSpecDatabaseOverride
        WHERE ProcessDatabaseId = @ProcessDatabaseId
          AND ObjectSpecId = @ObjectSpecId;
    END;

    IF @ObjectSpecDatabaseOverrideId IS NOT NULL
    BEGIN
        SELECT
            @OldIsEnabled = IsEnabled,
            @OldSourceSchemaOverride = SourceSchemaOverride,
            @OldSourceTableOverride = SourceTableOverride,
            @OldTimestampExprOverride = TimestampExprOverride,
            @OldJoinToAnchorPredicateSqlOverride = JoinToAnchorPredicateSqlOverride,
            @OldAdditionalWhereSqlOverride = AdditionalWhereSqlOverride,
            @OldArchiveSchemaOverride = ArchiveSchemaOverride,
            @OldArchiveTableOverride = ArchiveTableOverride,
            @OldRequireArchiveForDeleteOverride = RequireArchiveForDeleteOverride
        FROM arch.ObjectSpecDatabaseOverride
        WHERE ObjectSpecDatabaseOverrideId = @ObjectSpecDatabaseOverrideId
          AND ProcessDatabaseId = @ProcessDatabaseId
          AND ObjectSpecId = @ObjectSpecId;

        IF @@ROWCOUNT = 0
            THROW 56728, 'ObjectSpecDatabaseOverrideId does not match the selected mapping and object.', 1;
    END;

    SET @Operation = CASE WHEN @ObjectSpecDatabaseOverrideId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + @SourceDb + N'|' + @ArchiveDb + N'|' + @BaseSourceSchema + N'.' + @BaseSourceTable;

    IF @ObjectSpecDatabaseOverrideId IS NULL
    BEGIN
        INSERT INTO arch.ObjectSpecDatabaseOverride
        (
            ProcessDatabaseId,
            ObjectSpecId,
            IsEnabled,
            SourceSchemaOverride,
            SourceTableOverride,
            TimestampExprOverride,
            JoinToAnchorPredicateSqlOverride,
            AdditionalWhereSqlOverride,
            ArchiveSchemaOverride,
            ArchiveTableOverride,
            RequireArchiveForDeleteOverride,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @ProcessDatabaseId,
            @ObjectSpecId,
            @IsEnabled,
            @SourceSchemaOverride,
            @SourceTableOverride,
            @TimestampExprOverride,
            @JoinToAnchorPredicateSqlOverride,
            @AdditionalWhereSqlOverride,
            @ArchiveSchemaOverride,
            @ArchiveTableOverride,
            @RequireArchiveForDeleteOverride,
            @Now,
            @Now
        );

        SET @ObjectSpecDatabaseOverrideId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.ObjectSpecDatabaseOverride
        SET
            IsEnabled = @IsEnabled,
            SourceSchemaOverride = @SourceSchemaOverride,
            SourceTableOverride = @SourceTableOverride,
            TimestampExprOverride = @TimestampExprOverride,
            JoinToAnchorPredicateSqlOverride = @JoinToAnchorPredicateSqlOverride,
            AdditionalWhereSqlOverride = @AdditionalWhereSqlOverride,
            ArchiveSchemaOverride = @ArchiveSchemaOverride,
            ArchiveTableOverride = @ArchiveTableOverride,
            RequireArchiveForDeleteOverride = @RequireArchiveForDeleteOverride,
            ModifiedAt = @Now
        WHERE ObjectSpecDatabaseOverrideId = @ObjectSpecDatabaseOverrideId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessDatabaseId', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE CONVERT(nvarchar(30), @ProcessDatabaseId) END, CONVERT(nvarchar(30), @ProcessDatabaseId), 0),
        (N'ObjectSpecId', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE CONVERT(nvarchar(30), @ObjectSpecId) END, CONVERT(nvarchar(30), @ObjectSpecId), 0),
        (N'IsEnabled', CONVERT(nvarchar(30), @OldIsEnabled), CONVERT(nvarchar(30), @IsEnabled), 0),
        (N'SourceSchemaOverride', @OldSourceSchemaOverride, @SourceSchemaOverride, 0),
        (N'SourceTableOverride', @OldSourceTableOverride, @SourceTableOverride, 0),
        (N'TimestampExprOverride', @OldTimestampExprOverride, @TimestampExprOverride, 1),
        (N'JoinToAnchorPredicateSqlOverride', @OldJoinToAnchorPredicateSqlOverride, @JoinToAnchorPredicateSqlOverride, 1),
        (N'AdditionalWhereSqlOverride', @OldAdditionalWhereSqlOverride, @AdditionalWhereSqlOverride, 1),
        (N'ArchiveSchemaOverride', @OldArchiveSchemaOverride, @ArchiveSchemaOverride, 0),
        (N'ArchiveTableOverride', @OldArchiveTableOverride, @ArchiveTableOverride, 0),
        (N'RequireArchiveForDeleteOverride', CONVERT(nvarchar(30), @OldRequireArchiveForDeleteOverride), CONVERT(nvarchar(30), @RequireArchiveForDeleteOverride), 0);

    DELETE FROM @Audit
    WHERE (OldValue = NewValue) OR (OldValue IS NULL AND NewValue IS NULL);

    IF EXISTS (SELECT 1 FROM @Audit)
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'ObjectSpecDatabaseOverride',
            @EntityKey,
            @Operation,
            @ObjectSpecDatabaseOverrideId,
            @Now
        );

        SET @ConfigChangeItemId = CONVERT(bigint, SCOPE_IDENTITY());

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        SELECT
            @ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        FROM @Audit
        ORDER BY FieldName;
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Object database override saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        osdo.ObjectSpecDatabaseOverrideId,
        osdo.ProcessDatabaseId,
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        osdo.ObjectSpecId,
        BaseObjectName = QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        osdo.IsEnabled,
        osdo.SourceSchemaOverride,
        osdo.SourceTableOverride,
        osdo.TimestampExprOverride,
        osdo.JoinToAnchorPredicateSqlOverride,
        osdo.AdditionalWhereSqlOverride,
        osdo.ArchiveSchemaOverride,
        osdo.ArchiveTableOverride,
        osdo.RequireArchiveForDeleteOverride,
        osdo.ModifiedAt
    FROM arch.ObjectSpecDatabaseOverride osdo
    JOIN arch.ProcessDatabase pd
      ON pd.ProcessDatabaseId = osdo.ProcessDatabaseId
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    JOIN arch.ObjectSpec os
      ON os.ObjectSpecId = osdo.ObjectSpecId
    WHERE osdo.ObjectSpecDatabaseOverrideId = @ObjectSpecDatabaseOverrideId;
END
GO
-- <<< end: kArchiveManagerAdmin\frontend\006_frontend_object_write_api.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\frontend\007_frontend_enable_disable_api.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SetProcessEnabled]
    @ProcessCode sysname,
    @IsEnabled bit,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ProcessCode = NULLIF(LTRIM(RTRIM(@ProcessCode)), N'');
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;

    IF @ProcessCode IS NULL
        THROW 56900, 'ProcessCode is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56901, 'IsEnabled is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56902, 'RequestedBy is required.', 1;

    DECLARE
        @ProcessId int,
        @OldIsEnabled bit,
        @WasChanged bit;

    BEGIN TRAN;

    SELECT
        @ProcessId = ProcessId,
        @OldIsEnabled = IsEnabled
    FROM arch.Process
    WHERE ProcessCode = @ProcessCode;

    IF @ProcessId IS NULL
        THROW 56903, 'ProcessCode does not exist.', 1;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            SYSUTCDATETIME(),
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56904, 'ConfigChangeSetId does not exist.', 1;

    SET @WasChanged = CONVERT(bit, CASE WHEN @OldIsEnabled <> @IsEnabled THEN 1 ELSE 0 END);

    IF @WasChanged = 1
    BEGIN
        UPDATE arch.Process
        SET
            IsEnabled = @IsEnabled,
            ModifiedAt = SYSUTCDATETIME()
        WHERE ProcessId = @ProcessId;
    END;

    IF @WasChanged = 1
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'Process',
            @ProcessCode,
            N'UPDATE',
            @ProcessId,
            SYSUTCDATETIME()
        );

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        VALUES
        (
            CONVERT(bigint, SCOPE_IDENTITY()),
            N'IsEnabled',
            CONVERT(nvarchar(30), @OldIsEnabled),
            CONVERT(nvarchar(30), @IsEnabled),
            0
        );
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Process enabled state updated by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = SYSUTCDATETIME()
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        EntityType = N'Process',
        EntityId = @ProcessId,
        EntityKey = @ProcessCode,
        IsEnabled = @IsEnabled,
        WasChanged = @WasChanged;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SetProcessDatabaseEnabled]
    @ProcessDatabaseId int = NULL,
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @IsEnabled bit,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ProcessCode = NULLIF(LTRIM(RTRIM(@ProcessCode)), N'');
    SET @SourceDb = NULLIF(LTRIM(RTRIM(@SourceDb)), N'');
    SET @ArchiveDb = NULLIF(LTRIM(RTRIM(@ArchiveDb)), N'');
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;

    IF @ProcessDatabaseId IS NULL
       AND (@ProcessCode IS NULL OR @SourceDb IS NULL OR @ArchiveDb IS NULL)
        THROW 56920, 'ProcessDatabaseId or ProcessCode + SourceDb + ArchiveDb is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56921, 'IsEnabled is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56922, 'RequestedBy is required.', 1;

    DECLARE
        @ResolvedProcessDatabaseId int,
        @ResolvedProcessCode sysname,
        @ResolvedSourceDb sysname,
        @ResolvedArchiveDb sysname,
        @OldIsEnabled bit,
        @EntityKey nvarchar(400),
        @WasChanged bit;

    BEGIN TRAN;

    SELECT
        @ResolvedProcessDatabaseId = pd.ProcessDatabaseId,
        @ResolvedProcessCode = p.ProcessCode,
        @ResolvedSourceDb = pd.SourceDb,
        @ResolvedArchiveDb = pd.ArchiveDb,
        @OldIsEnabled = pd.IsEnabled
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    WHERE (@ProcessDatabaseId IS NOT NULL AND pd.ProcessDatabaseId = @ProcessDatabaseId)
       OR (@ProcessDatabaseId IS NULL AND p.ProcessCode = @ProcessCode AND pd.SourceDb = @SourceDb AND pd.ArchiveDb = @ArchiveDb);

    IF @ResolvedProcessDatabaseId IS NULL
        THROW 56923, 'Process database mapping does not exist.', 1;

    SET @EntityKey = @ResolvedProcessCode + N'|' + @ResolvedSourceDb + N'|' + @ResolvedArchiveDb;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            SYSUTCDATETIME(),
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56924, 'ConfigChangeSetId does not exist.', 1;

    SET @WasChanged = CONVERT(bit, CASE WHEN @OldIsEnabled <> @IsEnabled THEN 1 ELSE 0 END);

    IF @WasChanged = 1
    BEGIN
        UPDATE arch.ProcessDatabase
        SET
            IsEnabled = @IsEnabled,
            ModifiedAt = SYSUTCDATETIME()
        WHERE ProcessDatabaseId = @ResolvedProcessDatabaseId;
    END;

    IF @WasChanged = 1
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'ProcessDatabase',
            @EntityKey,
            N'UPDATE',
            @ResolvedProcessDatabaseId,
            SYSUTCDATETIME()
        );

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        VALUES
        (
            CONVERT(bigint, SCOPE_IDENTITY()),
            N'IsEnabled',
            CONVERT(nvarchar(30), @OldIsEnabled),
            CONVERT(nvarchar(30), @IsEnabled),
            0
        );
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Process database enabled state updated by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = SYSUTCDATETIME()
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        EntityType = N'ProcessDatabase',
        EntityId = @ResolvedProcessDatabaseId,
        EntityKey = @EntityKey,
        ProcessCode = @ResolvedProcessCode,
        SourceDb = @ResolvedSourceDb,
        ArchiveDb = @ResolvedArchiveDb,
        IsEnabled = @IsEnabled,
        WasChanged = @WasChanged;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SetObjectOverrideEnabled]
    @ProcessDatabaseId int,
    @ObjectSpecId int,
    @IsEnabled bit,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;

    IF @ProcessDatabaseId IS NULL
        THROW 56940, 'ProcessDatabaseId is required.', 1;

    IF @ObjectSpecId IS NULL
        THROW 56941, 'ObjectSpecId is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56942, 'IsEnabled is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56943, 'RequestedBy is required.', 1;

    DECLARE
        @ProcessId int,
        @ObjectProcessId int,
        @ProcessCode sysname,
        @SourceDb sysname,
        @ArchiveDb sysname,
        @SourceSchema sysname,
        @SourceTable sysname,
        @ObjectSpecDatabaseOverrideId int,
        @OldIsEnabled bit,
        @Operation nvarchar(20),
        @EntityKey nvarchar(400),
        @WasChanged bit,
        @Now datetime2(0) = SYSUTCDATETIME();

    BEGIN TRAN;

    SELECT
        @ProcessId = pd.ProcessId,
        @ProcessCode = p.ProcessCode,
        @SourceDb = pd.SourceDb,
        @ArchiveDb = pd.ArchiveDb
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    WHERE pd.ProcessDatabaseId = @ProcessDatabaseId;

    IF @ProcessId IS NULL
        THROW 56944, 'ProcessDatabaseId does not exist.', 1;

    SELECT
        @ObjectProcessId = ProcessId,
        @SourceSchema = SourceSchema,
        @SourceTable = SourceTable
    FROM arch.ObjectSpec
    WHERE ObjectSpecId = @ObjectSpecId;

    IF @ObjectProcessId IS NULL
        THROW 56945, 'ObjectSpecId does not exist.', 1;

    IF @ObjectProcessId <> @ProcessId
        THROW 56946, 'ObjectSpecId does not belong to the same process as ProcessDatabaseId.', 1;

    SELECT
        @ObjectSpecDatabaseOverrideId = ObjectSpecDatabaseOverrideId,
        @OldIsEnabled = IsEnabled
    FROM arch.ObjectSpecDatabaseOverride
    WHERE ProcessDatabaseId = @ProcessDatabaseId
      AND ObjectSpecId = @ObjectSpecId;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            SYSUTCDATETIME(),
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56947, 'ConfigChangeSetId does not exist.', 1;

    SET @Operation = CASE WHEN @ObjectSpecDatabaseOverrideId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + @SourceDb + N'|' + @ArchiveDb + N'|' + @SourceSchema + N'.' + @SourceTable;
    SET @WasChanged = CONVERT(bit, CASE WHEN @OldIsEnabled IS NULL OR @OldIsEnabled <> @IsEnabled THEN 1 ELSE 0 END);

    IF @ObjectSpecDatabaseOverrideId IS NULL
    BEGIN
        INSERT INTO arch.ObjectSpecDatabaseOverride
        (
            ProcessDatabaseId,
            ObjectSpecId,
            IsEnabled,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @ProcessDatabaseId,
            @ObjectSpecId,
            @IsEnabled,
            @Now,
            @Now
        );

        SET @ObjectSpecDatabaseOverrideId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE IF @WasChanged = 1
    BEGIN
        UPDATE arch.ObjectSpecDatabaseOverride
        SET
            IsEnabled = @IsEnabled,
            ModifiedAt = @Now
        WHERE ObjectSpecDatabaseOverrideId = @ObjectSpecDatabaseOverrideId;
    END;

    IF @WasChanged = 1
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'ObjectSpecDatabaseOverride',
            @EntityKey,
            @Operation,
            @ObjectSpecDatabaseOverrideId,
            SYSUTCDATETIME()
        );

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        VALUES
        (
            CONVERT(bigint, SCOPE_IDENTITY()),
            N'IsEnabled',
            CONVERT(nvarchar(30), @OldIsEnabled),
            CONVERT(nvarchar(30), @IsEnabled),
            0
        );
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Object override enabled state updated by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = SYSUTCDATETIME()
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        EntityType = N'ObjectSpecDatabaseOverride',
        EntityId = @ObjectSpecDatabaseOverrideId,
        EntityKey = @EntityKey,
        ProcessDatabaseId = @ProcessDatabaseId,
        ObjectSpecId = @ObjectSpecId,
        IsEnabled = @IsEnabled,
        WasChanged = @WasChanged;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SetRunProfileEnabled]
    @RunProfileCode sysname,
    @IsEnabled bit,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @RunProfileCode = NULLIF(LTRIM(RTRIM(@RunProfileCode)), N'');
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;

    IF @RunProfileCode IS NULL
        THROW 56960, 'RunProfileCode is required.', 1;

    IF @IsEnabled IS NULL
        THROW 56961, 'IsEnabled is required.', 1;

    IF @RequestedBy IS NULL
        THROW 56962, 'RequestedBy is required.', 1;

    DECLARE
        @RunProfileId int,
        @OldIsEnabled bit,
        @WasChanged bit;

    BEGIN TRAN;

    SELECT
        @RunProfileId = RunProfileId,
        @OldIsEnabled = IsEnabled
    FROM arch.RunProfile
    WHERE RunProfileCode = @RunProfileCode;

    IF @RunProfileId IS NULL
        THROW 56963, 'RunProfileCode does not exist.', 1;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            SYSUTCDATETIME(),
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 56964, 'ConfigChangeSetId does not exist.', 1;

    SET @WasChanged = CONVERT(bit, CASE WHEN @OldIsEnabled <> @IsEnabled THEN 1 ELSE 0 END);

    IF @WasChanged = 1
    BEGIN
        UPDATE arch.RunProfile
        SET
            IsEnabled = @IsEnabled,
            ModifiedAt = SYSUTCDATETIME()
        WHERE RunProfileId = @RunProfileId;
    END;

    IF @WasChanged = 1
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'RunProfile',
            @RunProfileCode,
            N'UPDATE',
            @RunProfileId,
            SYSUTCDATETIME()
        );

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        VALUES
        (
            CONVERT(bigint, SCOPE_IDENTITY()),
            N'IsEnabled',
            CONVERT(nvarchar(30), @OldIsEnabled),
            CONVERT(nvarchar(30), @IsEnabled),
            0
        );
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Run profile enabled state updated by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = SYSUTCDATETIME()
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        EntityType = N'RunProfile',
        EntityId = @RunProfileId,
        EntityKey = @RunProfileCode,
        IsEnabled = @IsEnabled,
        WasChanged = @WasChanged;
END
GO
-- <<< end: kArchiveManagerAdmin\frontend\007_frontend_enable_disable_api.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\frontend\008_frontend_run_profile_write_api.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveRunProfile]
    @RunProfileId int = NULL OUTPUT,
    @RunProfileCode sysname,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @Description nvarchar(400) = NULL,
    @IsEnabled bit = 1,
    @RunOnSchedule bit = 0,
    @RunOrder int = 100,
    @ProcessCodeFilter sysname = NULL,
    @SourceDbFilter sysname = NULL,
    @ArchiveDbFilter sysname = NULL,
    @RunWindowMinutes int = 55,
    @DryRun bit = 0,
    @MaxCandidates int = NULL,
    @PausedCooldownSeconds int = 60,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @RunProfileCode = NULLIF(LTRIM(RTRIM(@RunProfileCode)), N'');
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @ProcessCodeFilter = NULLIF(LTRIM(RTRIM(@ProcessCodeFilter)), N'');
    SET @SourceDbFilter = NULLIF(LTRIM(RTRIM(@SourceDbFilter)), N'');
    SET @ArchiveDbFilter = NULLIF(LTRIM(RTRIM(@ArchiveDbFilter)), N'');

    IF @RunProfileCode IS NULL
        THROW 57100, 'RunProfileCode is required.', 1;

    IF @RequestedBy IS NULL
        THROW 57101, 'RequestedBy is required.', 1;

    IF @IsEnabled IS NULL
        THROW 57102, 'IsEnabled is required.', 1;

    IF @RunOnSchedule IS NULL
        THROW 57103, 'RunOnSchedule is required.', 1;

    IF @RunOrder IS NULL
        THROW 57104, 'RunOrder is required.', 1;

    IF @RunWindowMinutes IS NULL OR @RunWindowMinutes <= 0
        THROW 57105, 'RunWindowMinutes must be greater than 0.', 1;

    IF @DryRun IS NULL
        THROW 57106, 'DryRun is required.', 1;

    IF (@MaxCandidates IS NOT NULL AND @MaxCandidates <= 0)
       OR @PausedCooldownSeconds IS NULL
       OR @PausedCooldownSeconds < 0
        THROW 57107, 'Run profile numeric limits are invalid.', 1;

    IF @ProcessCodeFilter IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM arch.Process WHERE ProcessCode = @ProcessCodeFilter)
        THROW 57108, 'ProcessCodeFilter does not exist in arch.Process.', 1;

    IF (@SourceDbFilter IS NOT NULL OR @ArchiveDbFilter IS NOT NULL)
       AND NOT EXISTS
       (
           SELECT 1
           FROM arch.ProcessDatabase pd
           JOIN arch.Process p
             ON p.ProcessId = pd.ProcessId
           WHERE (@ProcessCodeFilter IS NULL OR p.ProcessCode = @ProcessCodeFilter)
             AND (@SourceDbFilter IS NULL OR pd.SourceDb = @SourceDbFilter)
             AND (@ArchiveDbFilter IS NULL OR pd.ArchiveDb = @ArchiveDbFilter)
       )
        THROW 57109, 'SourceDbFilter and ArchiveDbFilter do not match any configured process database mapping.', 1;

    DECLARE
        @Operation nvarchar(20),
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldRunProfileCode sysname,
        @OldDescription nvarchar(400),
        @OldIsEnabled bit,
        @OldRunOnSchedule bit,
        @OldRunOrder int,
        @OldProcessCodeFilter sysname,
        @OldSourceDbFilter sysname,
        @OldArchiveDbFilter sysname,
        @OldRunWindowMinutes int,
        @OldDryRun bit,
        @OldMaxCandidates int,
        @OldPausedCooldownSeconds int;

    DECLARE @Audit table
    (
        FieldName sysname NOT NULL,
        OldValue nvarchar(max) NULL,
        NewValue nvarchar(max) NULL,
        IsAdvancedField bit NOT NULL
    );

    BEGIN TRAN;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            @Now,
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 57110, 'ConfigChangeSetId does not exist.', 1;

    IF @RunProfileId IS NULL
    BEGIN
        SELECT @RunProfileId = RunProfileId
        FROM arch.RunProfile
        WHERE RunProfileCode = @RunProfileCode;
    END;

    IF @RunProfileId IS NOT NULL
    BEGIN
        SELECT
            @OldRunProfileCode = RunProfileCode,
            @OldDescription = Description,
            @OldIsEnabled = IsEnabled,
            @OldRunOnSchedule = RunOnSchedule,
            @OldRunOrder = RunOrder,
            @OldProcessCodeFilter = ProcessCodeFilter,
            @OldSourceDbFilter = SourceDbFilter,
            @OldArchiveDbFilter = ArchiveDbFilter,
            @OldRunWindowMinutes = RunWindowMinutes,
            @OldDryRun = DryRun,
            @OldMaxCandidates = MaxCandidates,
            @OldPausedCooldownSeconds = PausedCooldownSeconds
        FROM arch.RunProfile
        WHERE RunProfileId = @RunProfileId;

        IF @@ROWCOUNT = 0
            THROW 57111, 'RunProfileId does not exist.', 1;

        IF @OldRunProfileCode <> @RunProfileCode
           AND EXISTS (SELECT 1 FROM arch.RunProfile WHERE RunProfileCode = @RunProfileCode AND RunProfileId <> @RunProfileId)
            THROW 57112, 'RunProfileCode already exists.', 1;
    END;

    SET @Operation = CASE WHEN @RunProfileId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @RunProfileCode;

    IF @RunProfileId IS NULL
    BEGIN
        INSERT INTO arch.RunProfile
        (
            RunProfileCode,
            Description,
            IsEnabled,
            RunOnSchedule,
            RunOrder,
            ProcessCodeFilter,
            SourceDbFilter,
            ArchiveDbFilter,
            RunWindowMinutes,
            DryRun,
            MaxCandidates,
            PausedCooldownSeconds,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @RunProfileCode,
            @Description,
            @IsEnabled,
            @RunOnSchedule,
            @RunOrder,
            @ProcessCodeFilter,
            @SourceDbFilter,
            @ArchiveDbFilter,
            @RunWindowMinutes,
            @DryRun,
            @MaxCandidates,
            @PausedCooldownSeconds,
            @Now,
            @Now
        );

        SET @RunProfileId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.RunProfile
        SET
            RunProfileCode = @RunProfileCode,
            Description = @Description,
            IsEnabled = @IsEnabled,
            RunOnSchedule = @RunOnSchedule,
            RunOrder = @RunOrder,
            ProcessCodeFilter = @ProcessCodeFilter,
            SourceDbFilter = @SourceDbFilter,
            ArchiveDbFilter = @ArchiveDbFilter,
            RunWindowMinutes = @RunWindowMinutes,
            DryRun = @DryRun,
            MaxCandidates = @MaxCandidates,
            PausedCooldownSeconds = @PausedCooldownSeconds,
            ModifiedAt = @Now
        WHERE RunProfileId = @RunProfileId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'RunProfileCode', @OldRunProfileCode, @RunProfileCode, 0),
        (N'Description', @OldDescription, @Description, 0),
        (N'IsEnabled', CONVERT(nvarchar(30), @OldIsEnabled), CONVERT(nvarchar(30), @IsEnabled), 0),
        (N'RunOnSchedule', CONVERT(nvarchar(30), @OldRunOnSchedule), CONVERT(nvarchar(30), @RunOnSchedule), 0),
        (N'RunOrder', CONVERT(nvarchar(30), @OldRunOrder), CONVERT(nvarchar(30), @RunOrder), 0),
        (N'ProcessCodeFilter', @OldProcessCodeFilter, @ProcessCodeFilter, 0),
        (N'SourceDbFilter', @OldSourceDbFilter, @SourceDbFilter, 0),
        (N'ArchiveDbFilter', @OldArchiveDbFilter, @ArchiveDbFilter, 0),
        (N'RunWindowMinutes', CONVERT(nvarchar(30), @OldRunWindowMinutes), CONVERT(nvarchar(30), @RunWindowMinutes), 0),
        (N'DryRun', CONVERT(nvarchar(30), @OldDryRun), CONVERT(nvarchar(30), @DryRun), 0),
        (N'MaxCandidates', CONVERT(nvarchar(30), @OldMaxCandidates), CONVERT(nvarchar(30), @MaxCandidates), 0),
        (N'PausedCooldownSeconds', CONVERT(nvarchar(30), @OldPausedCooldownSeconds), CONVERT(nvarchar(30), @PausedCooldownSeconds), 0);

    DELETE FROM @Audit
    WHERE (OldValue = NewValue) OR (OldValue IS NULL AND NewValue IS NULL);

    IF EXISTS (SELECT 1 FROM @Audit)
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'RunProfile',
            @EntityKey,
            @Operation,
            @RunProfileId,
            @Now
        );

        SET @ConfigChangeItemId = CONVERT(bigint, SCOPE_IDENTITY());

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        SELECT
            @ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        FROM @Audit
        ORDER BY FieldName;
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Run profile saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        rp.RunProfileId,
        rp.RunProfileCode,
        rp.Description,
        rp.IsEnabled,
        rp.RunOnSchedule,
        rp.RunOrder,
        rp.ProcessCodeFilter,
        rp.SourceDbFilter,
        rp.ArchiveDbFilter,
        rp.RunWindowMinutes,
        rp.DryRun,
        rp.MaxCandidates,
        rp.PausedCooldownSeconds,
        rp.ModifiedAt
    FROM arch.RunProfile rp
    WHERE rp.RunProfileId = @RunProfileId;
END
GO
-- <<< end: kArchiveManagerAdmin\frontend\008_frontend_run_profile_write_api.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\frontend\009_frontend_advanced_config_write_api.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveProcessKeySpec]
    @ProcessKeySpecId int = NULL OUTPUT,
    @ProcessCode sysname,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @KeyOrdinal tinyint,
    @KeyName sysname,
    @SourceExpressionSql nvarchar(4000),
    @SqlType nvarchar(128),
    @IsRequired bit = 1,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ProcessCode = NULLIF(LTRIM(RTRIM(@ProcessCode)), N'');
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;
    SET @KeyName = NULLIF(LTRIM(RTRIM(@KeyName)), N'');
    SET @SourceExpressionSql = NULLIF(LTRIM(RTRIM(@SourceExpressionSql)), N'');
    SET @SqlType = NULLIF(LTRIM(RTRIM(@SqlType)), N'');

    IF @ProcessCode IS NULL
        THROW 57300, 'ProcessCode is required.', 1;

    IF @RequestedBy IS NULL
        THROW 57301, 'RequestedBy is required.', 1;

    IF @KeyOrdinal IS NULL OR @KeyOrdinal NOT BETWEEN 1 AND 8
        THROW 57302, 'KeyOrdinal must be between 1 and 8.', 1;

    IF @KeyName IS NULL
        THROW 57303, 'KeyName is required.', 1;

    IF @SourceExpressionSql IS NULL
        THROW 57304, 'SourceExpressionSql is required.', 1;

    IF @SqlType IS NULL
        THROW 57305, 'SqlType is required.', 1;

    IF @IsRequired IS NULL
        THROW 57306, 'IsRequired is required.', 1;

    -- T-05: the key expression is concatenated into the runner's candidate SELECT/WHERE against the
    -- production source DB — reject unsafe SQL before persisting.
    EXEC arch.usp_AssertSafeSqlExpression @SourceExpressionSql, N'SourceExpressionSql';

    DECLARE
        @ProcessId int,
        @Operation nvarchar(20),
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldKeyOrdinal tinyint,
        @OldKeyName sysname,
        @OldSourceExpressionSql nvarchar(4000),
        @OldSqlType nvarchar(128),
        @OldIsRequired bit;

    DECLARE @Audit table
    (
        FieldName sysname NOT NULL,
        OldValue nvarchar(max) NULL,
        NewValue nvarchar(max) NULL,
        IsAdvancedField bit NOT NULL
    );

    BEGIN TRAN;

    SELECT @ProcessId = ProcessId
    FROM arch.Process
    WHERE ProcessCode = @ProcessCode;

    IF @ProcessId IS NULL
        THROW 57307, 'ProcessCode does not exist.', 1;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            @Now,
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 57308, 'ConfigChangeSetId does not exist.', 1;

    IF @ProcessKeySpecId IS NULL
    BEGIN
        SELECT @ProcessKeySpecId = ProcessKeySpecId
        FROM arch.ProcessKeySpec
        WHERE ProcessId = @ProcessId
          AND KeyOrdinal = @KeyOrdinal;
    END;

    IF @ProcessKeySpecId IS NOT NULL
    BEGIN
        SELECT
            @OldKeyOrdinal = KeyOrdinal,
            @OldKeyName = KeyName,
            @OldSourceExpressionSql = SourceExpressionSql,
            @OldSqlType = SqlType,
            @OldIsRequired = IsRequired
        FROM arch.ProcessKeySpec
        WHERE ProcessKeySpecId = @ProcessKeySpecId
          AND ProcessId = @ProcessId;

        IF @@ROWCOUNT = 0
            THROW 57309, 'ProcessKeySpecId does not exist for the selected process.', 1;

        IF @OldKeyOrdinal <> @KeyOrdinal
           AND EXISTS
           (
               SELECT 1
               FROM arch.ProcessKeySpec
               WHERE ProcessId = @ProcessId
                 AND KeyOrdinal = @KeyOrdinal
                 AND ProcessKeySpecId <> @ProcessKeySpecId
           )
            THROW 57310, 'KeyOrdinal already exists for the selected process.', 1;
    END;

    SET @Operation = CASE WHEN @ProcessKeySpecId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + CONVERT(nvarchar(10), @KeyOrdinal);

    IF @ProcessKeySpecId IS NULL
    BEGIN
        INSERT INTO arch.ProcessKeySpec
        (
            ProcessId,
            KeyOrdinal,
            KeyName,
            SourceExpressionSql,
            SqlType,
            IsRequired,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @ProcessId,
            @KeyOrdinal,
            @KeyName,
            @SourceExpressionSql,
            @SqlType,
            @IsRequired,
            @Now,
            @Now
        );

        SET @ProcessKeySpecId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.ProcessKeySpec
        SET
            KeyOrdinal = @KeyOrdinal,
            KeyName = @KeyName,
            SourceExpressionSql = @SourceExpressionSql,
            SqlType = @SqlType,
            IsRequired = @IsRequired,
            ModifiedAt = @Now
        WHERE ProcessKeySpecId = @ProcessKeySpecId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessCode', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ProcessCode END, @ProcessCode, 0),
        (N'KeyOrdinal', CONVERT(nvarchar(30), @OldKeyOrdinal), CONVERT(nvarchar(30), @KeyOrdinal), 0),
        (N'KeyName', @OldKeyName, @KeyName, 0),
        (N'SourceExpressionSql', @OldSourceExpressionSql, @SourceExpressionSql, 1),
        (N'SqlType', @OldSqlType, @SqlType, 1),
        (N'IsRequired', CONVERT(nvarchar(30), @OldIsRequired), CONVERT(nvarchar(30), @IsRequired), 0);

    DELETE FROM @Audit
    WHERE (OldValue = NewValue) OR (OldValue IS NULL AND NewValue IS NULL);

    IF EXISTS (SELECT 1 FROM @Audit)
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'ProcessKeySpec',
            @EntityKey,
            @Operation,
            @ProcessKeySpecId,
            @Now
        );

        SET @ConfigChangeItemId = CONVERT(bigint, SCOPE_IDENTITY());

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        SELECT
            @ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        FROM @Audit
        ORDER BY FieldName;
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Process key specification saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        pks.ProcessKeySpecId,
        p.ProcessCode,
        pks.KeyOrdinal,
        pks.KeyName,
        pks.SourceExpressionSql,
        pks.SqlType,
        pks.IsRequired,
        pks.ModifiedAt
    FROM arch.ProcessKeySpec pks
    JOIN arch.Process p
      ON p.ProcessId = pks.ProcessId
    WHERE pks.ProcessKeySpecId = @ProcessKeySpecId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_SaveIndexRequirement]
    @IndexRequirementId int = NULL OUTPUT,
    @ProcessCode sysname,
    @RequestedBy nvarchar(256),
    @ChangeReason nvarchar(1000) = NULL,
    @ObjectSpecId int = NULL,
    @RequirementType nvarchar(20),
    @SourceSchema sysname,
    @SourceTable sysname,
    @KeyColumnsCsv nvarchar(1000),
    @IncludeColumnsCsv nvarchar(1000) = NULL,
    @FilterSql nvarchar(1000) = NULL,
    @IsMandatory bit = 1,
    @Notes nvarchar(1000) = NULL,
    @ConfigChangeSetId bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ProcessCode = NULLIF(LTRIM(RTRIM(@ProcessCode)), N'');
    SET @RequestedBy = NULLIF(LTRIM(RTRIM(@RequestedBy)), N'');
    SET @ChangeReason = NULLIF(LTRIM(RTRIM(@ChangeReason)), N'');

    -- Governance: a change reason (>=6 chars) is mandatory when this call creates a NEW change set
    -- (server-side enforcement so a direct API call cannot bypass the FE requirement). Reusing an
    -- existing @ConfigChangeSetId is exempt (the reason was recorded when the set was created).
    IF @ConfigChangeSetId IS NULL AND (@ChangeReason IS NULL OR LEN(@ChangeReason) < 6)
        THROW 56350, 'A change reason of at least 6 characters is required (audited immediate-publish governance).', 1;
    SET @RequirementType = UPPER(NULLIF(LTRIM(RTRIM(@RequirementType)), N''));
    SET @SourceSchema = NULLIF(LTRIM(RTRIM(@SourceSchema)), N'');
    SET @SourceTable = NULLIF(LTRIM(RTRIM(@SourceTable)), N'');
    SET @KeyColumnsCsv = NULLIF(LTRIM(RTRIM(@KeyColumnsCsv)), N'');
    SET @IncludeColumnsCsv = NULLIF(LTRIM(RTRIM(@IncludeColumnsCsv)), N'');
    SET @FilterSql = NULLIF(LTRIM(RTRIM(@FilterSql)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    IF @ProcessCode IS NULL
        THROW 57330, 'ProcessCode is required.', 1;

    IF @RequestedBy IS NULL
        THROW 57331, 'RequestedBy is required.', 1;

    IF @RequirementType IS NULL OR @RequirementType NOT IN (N'SELECTION', N'JOIN', N'DELETE', N'ORDER', N'PARTITION')
        THROW 57332, 'RequirementType is invalid.', 1;

    IF @SourceSchema IS NULL
        THROW 57333, 'SourceSchema is required.', 1;

    IF @SourceTable IS NULL
        THROW 57334, 'SourceTable is required.', 1;

    IF @KeyColumnsCsv IS NULL
        THROW 57335, 'KeyColumnsCsv is required.', 1;

    IF @IsMandatory IS NULL
        THROW 57336, 'IsMandatory is required.', 1;

    -- Safe-expression gate (T-05): FilterSql is advisory free-text SQL today (display-only, no runtime
    -- exec sink), but gate it like every other advanced SQL field so it can never be persisted as
    -- unvalidated SQL — forward-proofing should a future feature ever concatenate it into a probe/DDL.
    IF @FilterSql IS NOT NULL
        EXEC arch.usp_AssertSafeSqlExpression @FilterSql, N'IndexRequirement.FilterSql';

    DECLARE
        @ProcessId int,
        @ObjectProcessId int,
        @Operation nvarchar(20),
        @Now datetime2(0) = SYSUTCDATETIME(),
        @ConfigChangeItemId bigint,
        @EntityKey nvarchar(400);

    DECLARE
        @OldObjectSpecId int,
        @OldRequirementType nvarchar(20),
        @OldSourceSchema sysname,
        @OldSourceTable sysname,
        @OldKeyColumnsCsv nvarchar(1000),
        @OldIncludeColumnsCsv nvarchar(1000),
        @OldFilterSql nvarchar(1000),
        @OldIsMandatory bit,
        @OldNotes nvarchar(1000);

    DECLARE @Audit table
    (
        FieldName sysname NOT NULL,
        OldValue nvarchar(max) NULL,
        NewValue nvarchar(max) NULL,
        IsAdvancedField bit NOT NULL
    );

    BEGIN TRAN;

    SELECT @ProcessId = ProcessId
    FROM arch.Process
    WHERE ProcessCode = @ProcessCode;

    IF @ProcessId IS NULL
        THROW 57337, 'ProcessCode does not exist.', 1;

    IF @ObjectSpecId IS NOT NULL
    BEGIN
        SELECT @ObjectProcessId = ProcessId
        FROM arch.ObjectSpec
        WHERE ObjectSpecId = @ObjectSpecId;

        IF @ObjectProcessId IS NULL
            THROW 57338, 'ObjectSpecId does not exist.', 1;

        IF @ObjectProcessId <> @ProcessId
            THROW 57339, 'ObjectSpecId does not belong to the selected process.', 1;
    END;

    IF @ConfigChangeSetId IS NULL
    BEGIN
        INSERT INTO arch.ConfigChangeSet
        (
            ChangeStatus,
            RequestedBy,
            RequestedAtUtc,
            ChangeReason,
            ValidationStatus
        )
        VALUES
        (
            N'DRAFT',
            @RequestedBy,
            @Now,
            @ChangeReason,
            N'NOT_RUN'
        );

        SET @ConfigChangeSetId = CONVERT(bigint, SCOPE_IDENTITY());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM arch.ConfigChangeSet WHERE ConfigChangeSetId = @ConfigChangeSetId)
        THROW 57340, 'ConfigChangeSetId does not exist.', 1;

    IF @IndexRequirementId IS NULL
    BEGIN
        SELECT TOP (1) @IndexRequirementId = IndexRequirementId
        FROM arch.IndexRequirement
        WHERE ProcessId = @ProcessId
          AND ((ObjectSpecId = @ObjectSpecId) OR (ObjectSpecId IS NULL AND @ObjectSpecId IS NULL))
          AND RequirementType = @RequirementType
          AND SourceSchema = @SourceSchema
          AND SourceTable = @SourceTable
          AND KeyColumnsCsv = @KeyColumnsCsv
        ORDER BY IndexRequirementId;
    END;

    IF @IndexRequirementId IS NOT NULL
    BEGIN
        SELECT
            @OldObjectSpecId = ObjectSpecId,
            @OldRequirementType = RequirementType,
            @OldSourceSchema = SourceSchema,
            @OldSourceTable = SourceTable,
            @OldKeyColumnsCsv = KeyColumnsCsv,
            @OldIncludeColumnsCsv = IncludeColumnsCsv,
            @OldFilterSql = FilterSql,
            @OldIsMandatory = IsMandatory,
            @OldNotes = Notes
        FROM arch.IndexRequirement
        WHERE IndexRequirementId = @IndexRequirementId
          AND ProcessId = @ProcessId;

        IF @@ROWCOUNT = 0
            THROW 57341, 'IndexRequirementId does not exist for the selected process.', 1;
    END;

    SET @Operation = CASE WHEN @IndexRequirementId IS NULL THEN N'INSERT' ELSE N'UPDATE' END;
    SET @EntityKey = @ProcessCode + N'|' + @RequirementType + N'|' + @SourceSchema + N'.' + @SourceTable + N'|' + @KeyColumnsCsv;

    IF @IndexRequirementId IS NULL
    BEGIN
        INSERT INTO arch.IndexRequirement
        (
            ProcessId,
            ObjectSpecId,
            RequirementType,
            SourceSchema,
            SourceTable,
            KeyColumnsCsv,
            IncludeColumnsCsv,
            FilterSql,
            IsMandatory,
            Notes,
            CreatedAt,
            ModifiedAt
        )
        VALUES
        (
            @ProcessId,
            @ObjectSpecId,
            @RequirementType,
            @SourceSchema,
            @SourceTable,
            @KeyColumnsCsv,
            @IncludeColumnsCsv,
            @FilterSql,
            @IsMandatory,
            @Notes,
            @Now,
            @Now
        );

        SET @IndexRequirementId = CONVERT(int, SCOPE_IDENTITY());
    END
    ELSE
    BEGIN
        UPDATE arch.IndexRequirement
        SET
            ObjectSpecId = @ObjectSpecId,
            RequirementType = @RequirementType,
            SourceSchema = @SourceSchema,
            SourceTable = @SourceTable,
            KeyColumnsCsv = @KeyColumnsCsv,
            IncludeColumnsCsv = @IncludeColumnsCsv,
            FilterSql = @FilterSql,
            IsMandatory = @IsMandatory,
            Notes = @Notes,
            ModifiedAt = @Now
        WHERE IndexRequirementId = @IndexRequirementId;
    END;

    INSERT INTO @Audit(FieldName, OldValue, NewValue, IsAdvancedField)
    VALUES
        (N'ProcessCode', CASE WHEN @Operation = N'INSERT' THEN NULL ELSE @ProcessCode END, @ProcessCode, 0),
        (N'ObjectSpecId', CONVERT(nvarchar(30), @OldObjectSpecId), CONVERT(nvarchar(30), @ObjectSpecId), 0),
        (N'RequirementType', @OldRequirementType, @RequirementType, 0),
        (N'SourceSchema', @OldSourceSchema, @SourceSchema, 0),
        (N'SourceTable', @OldSourceTable, @SourceTable, 0),
        (N'KeyColumnsCsv', @OldKeyColumnsCsv, @KeyColumnsCsv, 1),
        (N'IncludeColumnsCsv', @OldIncludeColumnsCsv, @IncludeColumnsCsv, 1),
        (N'FilterSql', @OldFilterSql, @FilterSql, 1),
        (N'IsMandatory', CONVERT(nvarchar(30), @OldIsMandatory), CONVERT(nvarchar(30), @IsMandatory), 0),
        (N'Notes', @OldNotes, @Notes, 0);

    DELETE FROM @Audit
    WHERE (OldValue = NewValue) OR (OldValue IS NULL AND NewValue IS NULL);

    IF EXISTS (SELECT 1 FROM @Audit)
    BEGIN
        INSERT INTO arch.ConfigChangeItem
        (
            ConfigChangeSetId,
            EntityType,
            EntityKey,
            Operation,
            ObjectId,
            CreatedAtUtc
        )
        VALUES
        (
            @ConfigChangeSetId,
            N'IndexRequirement',
            @EntityKey,
            @Operation,
            @IndexRequirementId,
            @Now
        );

        SET @ConfigChangeItemId = CONVERT(bigint, SCOPE_IDENTITY());

        INSERT INTO arch.ConfigChangeField
        (
            ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        )
        SELECT
            @ConfigChangeItemId,
            FieldName,
            OldValue,
            NewValue,
            IsAdvancedField
        FROM @Audit
        ORDER BY FieldName;
    END;

    UPDATE arch.ConfigChangeSet
    SET
        ChangeStatus = N'PUBLISHED',
        ValidationStatus = N'OK',
        ValidationSummary = N'Index requirement saved by frontend API.',
        PublishedBy = @RequestedBy,
        PublishedAtUtc = @Now
    WHERE ConfigChangeSetId = @ConfigChangeSetId;

    COMMIT TRAN;

    SELECT
        ConfigChangeSetId = @ConfigChangeSetId,
        Operation = @Operation,
        ir.IndexRequirementId,
        p.ProcessCode,
        ir.ObjectSpecId,
        ir.RequirementType,
        ir.SourceSchema,
        ir.SourceTable,
        ir.KeyColumnsCsv,
        ir.IncludeColumnsCsv,
        ir.FilterSql,
        ir.IsMandatory,
        ir.Notes,
        ir.ModifiedAt
    FROM arch.IndexRequirement ir
    JOIN arch.Process p
      ON p.ProcessId = ir.ProcessId
    WHERE ir.IndexRequirementId = @IndexRequirementId;
END
GO
-- <<< end: kArchiveManagerAdmin\frontend\009_frontend_advanced_config_write_api.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\049_golive_readiness.sql
USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/* ============================================================================
   arch.usp_Frontend_GoLiveReadiness — operationalizes the production audit as a LIVE go-live gate.
   READ-ONLY. Returns one row per check: Category, CheckName, Severity (OK/INFO/WARN/FAIL), Detail,
   Recommendation. FAIL = go-live blocker. Surfaced by the Admin Console "Go-live readiness" panel.
   ============================================================================ */
CREATE OR ALTER PROCEDURE arch.usp_Frontend_GoLiveReadiness
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @r TABLE (Ord int IDENTITY(1,1), Category sysname, CheckName nvarchar(200),
                      Severity varchar(6), Detail nvarchar(1000), Recommendation nvarchar(500));

    /* ---------- A. PRIVILEGES ---------- */
    DECLARE @overpriv nvarchar(1000) = (
        SELECT STRING_AGG(name, N', ') FROM (
            SELECT DISTINCT pr.name
            FROM sys.database_permissions pm JOIN sys.database_principals pr ON pr.principal_id=pm.grantee_principal_id
            WHERE pm.permission_name='EXECUTE' AND pm.class_desc='DATABASE' AND pm.state_desc='GRANT' AND pr.name<>'dbo'
            UNION
            SELECT mp.name FROM sys.database_role_members drm
            JOIN sys.database_principals rp ON rp.principal_id=drm.role_principal_id AND rp.name='db_datawriter'
            JOIN sys.database_principals mp ON mp.principal_id=drm.member_principal_id AND mp.name<>'dbo'
        ) x);
    INSERT @r SELECT N'Privileges', N'No over-privileged principals',
        CASE WHEN @overpriv IS NULL THEN 'OK' ELSE 'FAIL' END,
        CASE WHEN @overpriv IS NULL THEN N'No non-dbo principal holds DB-wide EXECUTE or db_datawriter.' ELSE N'Over-privileged: '+@overpriv END,
        N'DROP / least-privilege these logins; the API pool should hold only karch_* roles. (T-01)';

    INSERT @r SELECT N'Privileges', N'Destructive procs granted to a role', sev, det, N'GRANT EXECUTE on stop/restore to karch_operator / karch_advanced_admin. (T-02)'
    FROM (SELECT
        sev = CASE WHEN stop_ok=1 AND restore_ok=1 THEN 'OK' ELSE 'FAIL' END,
        det = N'usp_Api_RequestRunStop granted='+CONVERT(varchar,stop_ok)+N', usp_RestoreFromArchive granted='+CONVERT(varchar,restore_ok)
      FROM (SELECT
        stop_ok = CASE WHEN EXISTS(SELECT 1 FROM sys.database_permissions pm JOIN sys.database_principals pr ON pr.principal_id=pm.grantee_principal_id WHERE pm.major_id=OBJECT_ID('arch.usp_Api_RequestRunStop') AND pm.permission_name='EXECUTE' AND pm.state_desc='GRANT' AND pr.type='R') THEN 1 ELSE 0 END,
        restore_ok = CASE WHEN EXISTS(SELECT 1 FROM sys.database_permissions pm JOIN sys.database_principals pr ON pr.principal_id=pm.grantee_principal_id WHERE pm.major_id=OBJECT_ID('arch.usp_RestoreFromArchive') AND pm.permission_name='EXECUTE' AND pm.state_desc='GRANT' AND pr.type='R') THEN 1 ELSE 0 END) a) b;

    /* ---------- B. LEGACY / RELICS ---------- */
    INSERT @r SELECT N'Cleanliness', N'No legacy_v1 / v1 procedures',
        CASE WHEN c=0 THEN 'OK' ELSE 'WARN' END, N'legacy_v1 + v1-stub objects: '+CONVERT(varchar,c),
        N'A fresh customer install should have none; on an upgraded env they are quarantined. (T-11/T-13)'
    FROM (SELECT c=(SELECT COUNT(*) FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id WHERE s.name='legacy_v1')
                 + (SELECT COUNT(*) FROM sys.objects WHERE type='P' AND SCHEMA_NAME(schema_id)='arch' AND name IN(N'usp_RunProcess',N'usp_RunProcess_RF_LOG2',N'usp_RunProcess_TimestampKeyset'))) z;

    INSERT @r SELECT N'Cleanliness', N'No relic tables',
        CASE WHEN c=0 THEN 'OK' ELSE 'WARN' END, N'relic tables: '+CONVERT(varchar,c),
        N'Drop arch.RowCountSnapshot and *_Backup_* once TZ-rollback window is closed.'
    FROM (SELECT c=(SELECT COUNT(*) FROM sys.tables WHERE SCHEMA_NAME(schema_id)='arch' AND (name='RowCountSnapshot' OR name LIKE '%[_]Backup[_]%'))) z;

    /* ---------- C. AUDIT GOVERNANCE ---------- */
    INSERT @r SELECT N'Audit', N'Per-document audit coverage (Mode=1)',
        CASE WHEN tot=0 OR below>0 THEN 'INFO' ELSE 'OK' END,
        CASE WHEN tot=0 THEN N'No enabled Mode=1 mappings configured yet.'
             ELSE CONVERT(varchar,below)+N' of '+CONVERT(varchar,tot)+N' enabled Mode=1 mappings have AuditLevel < ROW (no per-row trail)' END,
        N'Operator-controlled choice; set AuditLevel=ROW where a per-document deletion trail is required. (T-08)'
    FROM (SELECT tot=COUNT(*), below=ISNULL(SUM(CASE WHEN AuditLevel<>N'ROW' THEN 1 ELSE 0 END),0)
          FROM arch.v_ProcessDatabaseEffective WHERE IsEnabled=1 AND Mode=1) z;

    INSERT @r SELECT N'Audit', N'Audit trail is tamper-resistant (DENY on RunDocAudit)',
        CASE WHEN EXISTS(SELECT 1 FROM sys.database_permissions WHERE major_id=OBJECT_ID('arch.RunDocAudit') AND permission_name IN('UPDATE','DELETE') AND state_desc='DENY') THEN 'OK' ELSE 'WARN' END,
        N'', N'Deploy 045_audit_immutability (DENY UPDATE/DELETE) + remove db_datawriter logins. (T-09)';

    /* ---------- D. CONFIG / TIMEZONE GATE ---------- */
    INSERT @r SELECT N'Config', N'Timezone gate coverage (enabled Mode=1 cutoffs UTC-normalized)',
        CASE WHEN raw=0 THEN 'OK' ELSE 'FAIL' END,
        CONVERT(varchar,raw)+N' enabled Mode=1 mappings have a cutoff expression without AT TIME ZONE (real runs blocked by THROW 50200)',
        N'Wrap the cutoff in CAST(...) AT TIME ZONE ... AT TIME ZONE UTC, or these processes cannot run. (Risk K1)'
    FROM (SELECT raw=COUNT(*) FROM arch.v_ProcessDatabaseEffective e WHERE e.IsEnabled=1 AND e.Mode=1
            AND ( (COALESCE(e.SelectionStrategy,N'ANCHOR')=N'ANCHOR' AND ISNULL(e.AnchorTimestampExpr,N'') NOT LIKE N'%AT TIME ZONE%')
               OR (COALESCE(e.SelectionStrategy,N'ANCHOR')=N'TIMESTAMP' AND NOT EXISTS (
                     SELECT 1 FROM arch.v_ObjectSpecDatabaseEffective os WHERE os.ProcessDatabaseId=e.ProcessDatabaseId AND os.ObjectIsEnabled=1
                       AND ISNULL(os.TimestampExpr,N'') LIKE N'%AT TIME ZONE%') ) )) z;

    /* ---------- E. OPERATIONS ---------- */
    INSERT @r SELECT N'Operations', N'No operational-health errors',
        CASE WHEN c=0 THEN 'OK' ELSE 'FAIL' END, CONVERT(varchar,c)+N' ERROR rows in arch.v_OperationalHealth',
        N'Investigate FAILED runs / ROW_COUNT_MISMATCH / ROW_AUDIT_MISSING before go-live.'
    FROM (SELECT c=(SELECT COUNT(*) FROM arch.v_OperationalHealth WHERE Severity=N'ERROR')) z;

    INSERT @r SELECT N'Operations', N'Failure alerting configured',
        CASE WHEN mail=1 AND op=1 AND notify>0 THEN 'OK' ELSE 'WARN' END,
        N'DatabaseMail='+CONVERT(varchar,mail)+N', operator='+CONVERT(varchar,op)+N', jobs emailing on failure='+CONVERT(varchar,notify),
        N'Run 047_operational_alerting (Database Mail + operator + job notify + HEALTH ALERT job). (T-14)'
    FROM (SELECT
        mail=(SELECT CONVERT(int,ISNULL((SELECT CONVERT(int,value_in_use) FROM sys.configurations WHERE name='Database Mail XPs'),0))),
        op=(SELECT CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysoperators WHERE enabled=1) THEN 1 ELSE 0 END),
        notify=(SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE 'kArchiveManager%' AND notify_level_email=2)) z;

    INSERT @r SELECT N'Operations', N'Archive DB recent backup',
        CASE WHEN last_full IS NULL THEN 'WARN' WHEN last_full < DATEADD(DAY,-2,GETDATE()) THEN 'WARN' ELSE 'OK' END,
        N'kArchiveManagerBackups last FULL backup: '+ISNULL(CONVERT(varchar(30),last_full,120),N'NONE'),
        N'kArchiveManagerBackups is the system-of-record for deleted rows - schedule FULL+LOG backups + restore drill. (T-16)'
    FROM (SELECT last_full=(SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset WHERE database_name='kArchiveManagerBackups' AND type='D')) z;

    INSERT @r SELECT N'Operations', N'Stale-run recovery job enabled',
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name='kArchiveManager - RECOVER STALE RUNS' AND enabled=1) THEN 'OK' ELSE 'WARN' END,
        N'', N'Enable the RECOVER STALE RUNS job so orphaned runs self-heal.';

    /* ---------- Summary verdict ---------- */
    INSERT @r SELECT N'Summary', N'Go-live verdict',
        CASE WHEN EXISTS(SELECT 1 FROM @r WHERE Severity='FAIL') THEN 'FAIL'
             WHEN EXISTS(SELECT 1 FROM @r WHERE Severity='WARN') THEN 'WARN' ELSE 'OK' END,
        CONVERT(varchar,(SELECT COUNT(*) FROM @r WHERE Severity='FAIL'))+N' blocker(s), '
        +CONVERT(varchar,(SELECT COUNT(*) FROM @r WHERE Severity='WARN'))+N' warning(s)',
        N'Resolve all FAIL items before enabling the RUN CONFIGURED job for real deletes.';

    SELECT Category, CheckName, Severity, Detail, Recommendation
    FROM @r ORDER BY CASE WHEN Category='Summary' THEN 0 ELSE 1 END,
                     CASE Severity WHEN 'FAIL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'INFO' THEN 2 ELSE 3 END, Ord;
END
GO
-- Read-only readiness proc: grant to the viewer role so the Admin Console (app-pool identity) can call it.
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GoLiveReadiness] TO [karch_viewer];
GO
PRINT '049_golive_readiness deployed (arch.usp_Frontend_GoLiveReadiness + karch_viewer grant).';
GO
-- <<< end: kArchiveManagerAdmin\v2\049_golive_readiness.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\050_timestamp_retention_gaps.sql
USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/* ============================================================================
   050 — T-20 retention-gap VISIBILITY (read-only, no behavior change)
   ----------------------------------------------------------------------------
   The TIMESTAMP runner selects candidates with `TimestampExpr < cutoff`. A row whose
   TimestampExpr is NULL (or whose raw value does not parse) evaluates to UNKNOWN and is
   therefore PERMANENTLY excluded from deletion — retention / GDPR erasure never reaches it,
   silently. arch.usp_Frontend_TimestampRetentionGaps surfaces, per enabled TIMESTAMP mapping,
   how many such unreachable rows exist on the candidate table.

   This is VISIBILITY ONLY. It does not change what gets deleted. Whether NULL/unparseable
   rows should become eligible for deletion (and after how long) is a business/compliance
   decision, deliberately left to an explicit opt-in rather than changing delete behavior here.
   ============================================================================ */
CREATE OR ALTER PROCEDURE arch.usp_Frontend_TimestampRetentionGaps
    @ProcessCode sysname = NULL,
    @SourceDb    sysname = NULL,
    @ArchiveDb   sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- read-only monitoring: a per-mapping count that errors (e.g. a raw CONVERT on bad data) is CAUGHT and
    -- reported, not fatal — so XACT_ABORT must be OFF or the catch would doom an INSERT...EXEC caller.
    SET XACT_ABORT OFF;

    DECLARE @out TABLE
    (
        ProcessCode sysname, SourceDb sysname, ArchiveDb sysname,
        CandidateSchema sysname NULL, CandidateTable sysname NULL,
        TimestampExpr nvarchar(4000) NULL,
        TotalRows bigint NULL,
        NullOrUnparseableRows bigint NULL,
        Note nvarchar(400) NULL
    );

    DECLARE @pc sysname, @sd sysname, @ad sysname, @pdid int,
            @cs sysname, @ct sysname, @texpr nvarchar(4000),
            @srcFq nvarchar(512), @sql nvarchar(max),
            @total bigint, @nullcnt bigint, @err nvarchar(400);

    DECLARE m CURSOR LOCAL FAST_FORWARD FOR
    SELECT e.ProcessCode, e.SourceDb, e.ArchiveDb, e.ProcessDatabaseId
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb   IS NULL OR e.SourceDb   = @SourceDb)
      AND (@ArchiveDb  IS NULL OR e.ArchiveDb  = @ArchiveDb);

    OPEN m;
    FETCH NEXT FROM m INTO @pc, @sd, @ad, @pdid;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @cs = NULL; SET @ct = NULL; SET @texpr = NULL;

        -- candidate object = first by DeleteOrder (same one the runner builds its keyset from)
        SELECT TOP (1)
            @cs = os.SourceSchema, @ct = os.SourceTable, @texpr = os.TimestampExpr
        FROM arch.v_ObjectSpecDatabaseEffective os
        WHERE os.ProcessDatabaseId = @pdid AND os.ObjectIsEnabled = 1
        ORDER BY os.DeleteOrder, os.ObjectSpecId;

        IF @cs IS NULL OR NULLIF(LTRIM(RTRIM(@texpr)), N'') IS NULL
        BEGIN
            INSERT @out VALUES (@pc, @sd, @ad, @cs, @ct, @texpr, NULL, NULL, N'SKIP: no enabled candidate object / TimestampExpr');
            FETCH NEXT FROM m INTO @pc, @sd, @ad, @pdid; CONTINUE;
        END;

        SET @srcFq = QUOTENAME(@sd) + N'.' + QUOTENAME(@cs) + N'.' + QUOTENAME(@ct);
        IF DB_ID(@sd) IS NULL OR OBJECT_ID(@srcFq, N'U') IS NULL
        BEGIN
            INSERT @out VALUES (@pc, @sd, @ad, @cs, @ct, @texpr, NULL, NULL, N'SKIP: source database/table not found');
            FETCH NEXT FROM m INTO @pc, @sd, @ad, @pdid; CONTINUE;
        END;

        SET @total = NULL; SET @nullcnt = NULL; SET @err = NULL;
        BEGIN TRY
            -- alias 't' matches the runner so a bare-column TimestampExpr resolves identically.
            SET @sql = N'SELECT @t = COUNT_BIG(*),
                                @n = COUNT_BIG(CASE WHEN (' + @texpr + N') IS NULL THEN 1 END)
                         FROM ' + @srcFq + N' t WITH (NOLOCK);';
            EXEC sys.sp_executesql @sql, N'@t bigint OUTPUT, @n bigint OUTPUT', @t = @total OUTPUT, @n = @nullcnt OUTPUT;
        END TRY
        BEGIN CATCH
            -- a raw (non-TRY) CONVERT in TimestampExpr that throws on bad data is itself a retention gap
            SET @err = N'EXPR ERROR (likely unparseable values present): ' + LEFT(ERROR_MESSAGE(), 320);
        END CATCH;

        INSERT @out VALUES (@pc, @sd, @ad, @cs, @ct, @texpr, @total, @nullcnt,
            COALESCE(@err,
                     CASE WHEN ISNULL(@nullcnt, 0) > 0
                          THEN N'WARN: rows with NULL timestamp are never reached by retention'
                          ELSE N'OK' END));

        FETCH NEXT FROM m INTO @pc, @sd, @ad, @pdid;
    END;
    CLOSE m; DEALLOCATE m;

    SELECT ProcessCode, SourceDb, ArchiveDb, CandidateSchema, CandidateTable,
           TimestampExpr, TotalRows, NullOrUnparseableRows, Note
    FROM @out
    ORDER BY CASE WHEN ISNULL(NullOrUnparseableRows, 0) > 0 OR Note LIKE N'EXPR ERROR%' THEN 0 ELSE 1 END,
             ProcessCode, SourceDb;
END
GO
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_TimestampRetentionGaps] TO [karch_viewer];
GO
PRINT '050_timestamp_retention_gaps deployed (arch.usp_Frontend_TimestampRetentionGaps + karch_viewer grant).';
GO
-- <<< end: kArchiveManagerAdmin\v2\050_timestamp_retention_gaps.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\060_estimate_next_run_impact.sql
/* ============================================================================
   060_estimate_next_run_impact.sql — arch.usp_Api_EstimateNextRunImpact
   ----------------------------------------------------------------------------
   Read-only sizing estimate for the NEXT run, per (process, source DB): how much the next batch
   would move (rows + MB), projected archive growth, log pressure and a planning figure with a
   safety factor, plus a per-table detail. Mapping-aware: it reads the EFFECTIVE config
   (v_ProcessDatabaseEffective + v_ObjectSpecDatabaseEffective), so it estimates exactly the tables
   each process is actually mapped to in each source DB — not every table against one DB.

   @SourceDb NULL/'' = ALL enabled source DBs (the "Any source" view); otherwise that DB only.
   Source-table sizes come from <SourceDb>.sys.dm_db_partition_stats (cross-DB). Read-tier
   (granted to karch_viewer). Returns: (1) per-process/source-DB summary, (2) per-table detail.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE arch.usp_Api_EstimateNextRunImpact
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @ProcessCode nvarchar(50) = NULL,
    @IncludeDisabled bit = 0,
    @ArchiveGrowthFactor decimal(10,2) = 1.20,
    @LogMultiplier decimal(10,2) = 3.00,
    @SafetyFactor decimal(10,2) = 1.30
AS
BEGIN
    SET NOCOUNT ON;

    SET @SourceDb    = NULLIF(LTRIM(RTRIM(@SourceDb)), N'');     -- NULL => all source DBs
    SET @ArchiveDb   = NULLIF(LTRIM(RTRIM(@ArchiveDb)), N'');
    SET @ProcessCode = NULLIF(LTRIM(RTRIM(@ProcessCode)), N'');

    IF OBJECT_ID(N'arch.v_ObjectSpecDatabaseEffective', N'V') IS NULL
       OR OBJECT_ID(N'arch.v_ProcessDatabaseEffective', N'V') IS NULL
        THROW 50500, 'Effective config views not installed (run v2/022).', 1;

    DROP TABLE IF EXISTS #ObjectConfig;
    DROP TABLE IF EXISTS #SourceTableSize;
    DROP TABLE IF EXISTS #Detail;

    /* Enabled (or all, if @IncludeDisabled) mappings, with effective mode + batch sizing. */
    SELECT
        o.ProcessCode,
        o.SourceDb,
        o.ArchiveDb,
        Mode                  = pd.Mode,
        BatchDocCount         = pd.BatchDocCount,
        BatchRowCount         = pd.BatchRowCount,
        MaxBatchesPerRun      = COALESCE(NULLIF(pd.MaxBatchesPerRun, 0), 1),
        MaxRowsPerTransaction = pd.MaxRowsPerTransaction,
        o.ObjectSpecId,
        DeleteOrder           = COALESCE(o.DeleteOrder, 1000),
        SourceSchema          = o.SourceSchema,
        SourceTable           = o.SourceTable,
        ArchiveSchema         = o.ArchiveSchema,
        ArchiveTable          = o.ArchiveTable
    INTO #ObjectConfig
    FROM arch.v_ObjectSpecDatabaseEffective AS o
    JOIN arch.v_ProcessDatabaseEffective AS pd
      ON pd.ProcessDatabaseId = o.ProcessDatabaseId
    WHERE (@IncludeDisabled = 1 OR (o.ProcessDatabaseIsEnabled = 1 AND o.ObjectIsEnabled = 1))
      AND (@SourceDb IS NULL OR o.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR o.ArchiveDb = @ArchiveDb)
      AND (@ProcessCode IS NULL OR o.ProcessCode = @ProcessCode)
      AND NULLIF(LTRIM(RTRIM(o.SourceSchema)), N'') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(o.SourceTable)), N'') IS NOT NULL;

    CREATE TABLE #SourceTableSize
    (
        SourceDb sysname NOT NULL, SourceSchema sysname NOT NULL, SourceTable sysname NOT NULL,
        TableExists bit NOT NULL, SourceRows bigint NULL, ReservedMB decimal(19,2) NULL, UsedMB decimal(19,2) NULL,
        DataMB decimal(19,2) NULL, IndexMB decimal(19,2) NULL, AvgUsedKBPerRow decimal(19,4) NULL, ErrorMessage nvarchar(4000) NULL,
        PRIMARY KEY (SourceDb, SourceSchema, SourceTable)
    );

    DECLARE @CurDb sysname, @CurSchema sysname, @CurTable sysname, @ObjectName nvarchar(776), @SizeSql nvarchar(max);
    DECLARE cur_size CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT SourceDb, SourceSchema, SourceTable FROM #ObjectConfig ORDER BY SourceDb, SourceSchema, SourceTable;
    OPEN cur_size; FETCH NEXT FROM cur_size INTO @CurDb, @CurSchema, @CurTable;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF DB_ID(@CurDb) IS NULL
        BEGIN
            INSERT #SourceTableSize (SourceDb, SourceSchema, SourceTable, TableExists, ErrorMessage)
            VALUES (@CurDb, @CurSchema, @CurTable, 0, N'Source database does not exist.');
        END
        ELSE
        BEGIN
            SET @ObjectName = QUOTENAME(@CurDb) + N'.' + QUOTENAME(@CurSchema) + N'.' + QUOTENAME(@CurTable);
            SET @SizeSql = N'
IF OBJECT_ID(@ObjectNameParam, N''U'') IS NULL
    INSERT INTO #SourceTableSize (SourceDb, SourceSchema, SourceTable, TableExists, ErrorMessage)
    VALUES (@DbParam, @SchemaParam, @TableParam, 0, N''Source table does not exist.'');
ELSE
    INSERT INTO #SourceTableSize (SourceDb, SourceSchema, SourceTable, TableExists, SourceRows, ReservedMB, UsedMB, DataMB, IndexMB, AvgUsedKBPerRow, ErrorMessage)
    SELECT @DbParam, @SchemaParam, @TableParam, CONVERT(bit,1),
        SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END),
        CONVERT(decimal(19,2), SUM(ps.reserved_page_count) * 8.0 / 1024.0),
        CONVERT(decimal(19,2), SUM(ps.used_page_count) * 8.0 / 1024.0),
        CONVERT(decimal(19,2), SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.in_row_data_page_count + ps.lob_used_page_count + ps.row_overflow_used_page_count ELSE 0 END) * 8.0 / 1024.0),
        CONVERT(decimal(19,2), (SUM(ps.used_page_count) - SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.in_row_data_page_count + ps.lob_used_page_count + ps.row_overflow_used_page_count ELSE 0 END)) * 8.0 / 1024.0),
        CONVERT(decimal(19,4), CASE WHEN SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END)=0 THEN 0
            ELSE SUM(ps.used_page_count) * 8.0 / NULLIF(SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END),0) END),
        NULL
    FROM ' + QUOTENAME(@CurDb) + N'.sys.dm_db_partition_stats AS ps
    JOIN ' + QUOTENAME(@CurDb) + N'.sys.tables AS t ON t.object_id = ps.object_id
    JOIN ' + QUOTENAME(@CurDb) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE s.name = @SchemaParam AND t.name = @TableParam;';
            BEGIN TRY
                EXEC sys.sp_executesql @SizeSql,
                    N'@DbParam sysname, @SchemaParam sysname, @TableParam sysname, @ObjectNameParam nvarchar(776)',
                    @DbParam = @CurDb, @SchemaParam = @CurSchema, @TableParam = @CurTable, @ObjectNameParam = @ObjectName;
            END TRY
            BEGIN CATCH
                INSERT #SourceTableSize (SourceDb, SourceSchema, SourceTable, TableExists, ErrorMessage)
                VALUES (@CurDb, @CurSchema, @CurTable, 0, LEFT(N'Could not size: ' + ERROR_MESSAGE(), 4000));
            END CATCH
        END
        FETCH NEXT FROM cur_size INTO @CurDb, @CurSchema, @CurTable;
    END
    CLOSE cur_size; DEALLOCATE cur_size;

    SELECT
        oc.ProcessCode, oc.SourceDb, oc.ArchiveDb, oc.Mode,
        ModeName = CASE oc.Mode WHEN 1 THEN N'ARCHIVE_DELETE' WHEN 0 THEN N'DELETE_ONLY' WHEN 2 THEN N'COPY_ONLY' ELSE N'UNKNOWN' END,
        oc.ObjectSpecId, oc.DeleteOrder, oc.SourceSchema, oc.SourceTable, oc.ArchiveSchema, oc.ArchiveTable,
        ss.SourceRows, ss.UsedMB, ss.DataMB, ss.IndexMB, ss.AvgUsedKBPerRow,
        oc.BatchDocCount, oc.BatchRowCount, oc.MaxBatchesPerRun, oc.MaxRowsPerTransaction,
        NextRunControlLimit = CONVERT(bigint, COALESCE(NULLIF(oc.BatchRowCount,0), NULLIF(oc.BatchDocCount,0), NULLIF(oc.MaxRowsPerTransaction,0), 1000) * oc.MaxBatchesPerRun),
        OneToOneEstimatedRows = CASE WHEN ss.TableExists = 0 OR ss.SourceRows IS NULL THEN NULL
            ELSE (SELECT MIN(v) FROM (VALUES (ss.SourceRows), (CONVERT(bigint, COALESCE(NULLIF(oc.BatchRowCount,0), NULLIF(oc.BatchDocCount,0), NULLIF(oc.MaxRowsPerTransaction,0), 1000) * oc.MaxBatchesPerRun))) AS x(v)) END,
        OneToOnePayloadMB = CONVERT(decimal(19,2),
            (CASE WHEN ss.TableExists = 0 OR ss.SourceRows IS NULL THEN 0
                  ELSE (SELECT MIN(v) FROM (VALUES (ss.SourceRows), (CONVERT(bigint, COALESCE(NULLIF(oc.BatchRowCount,0), NULLIF(oc.BatchDocCount,0), NULLIF(oc.MaxRowsPerTransaction,0), 1000) * oc.MaxBatchesPerRun))) AS x(v)) END)
            * COALESCE(ss.AvgUsedKBPerRow, 0) / 1024.0),
        FullTableUsedMB = ss.UsedMB,
        Status = CASE WHEN ss.TableExists = 0 THEN N'ERROR' ELSE N'OK' END,
        ErrorMessage = ss.ErrorMessage
    INTO #Detail
    FROM #ObjectConfig AS oc
    LEFT JOIN #SourceTableSize AS ss ON ss.SourceDb = oc.SourceDb AND ss.SourceSchema = oc.SourceSchema AND ss.SourceTable = oc.SourceTable;

    /* (1) per process + source DB summary */
    ;WITH DistinctTable AS (
        SELECT ProcessCode, SourceDb, ArchiveDb, Mode, ModeName, SourceSchema, SourceTable,
            SourceRows = MAX(SourceRows), UsedMB = MAX(UsedMB), DataMB = MAX(DataMB), IndexMB = MAX(IndexMB),
            OneToOnePayloadMB = MAX(OneToOnePayloadMB), Status = MAX(Status)
        FROM #Detail GROUP BY ProcessCode, SourceDb, ArchiveDb, Mode, ModeName, SourceSchema, SourceTable
    ),
    ProcessLimit AS (
        SELECT ProcessCode, SourceDb, ArchiveDb, Mode, ModeName,
            BatchDocCount = MAX(BatchDocCount), BatchRowCount = MAX(BatchRowCount), MaxBatchesPerRun = MAX(MaxBatchesPerRun),
            MaxRowsPerTransaction = MAX(MaxRowsPerTransaction), NextRunControlLimit = MAX(NextRunControlLimit)
        FROM #Detail GROUP BY ProcessCode, SourceDb, ArchiveDb, Mode, ModeName
    )
    SELECT pl.ProcessCode, pl.SourceDb, pl.ArchiveDb, pl.Mode, pl.ModeName,
        pl.BatchDocCount, pl.BatchRowCount, pl.MaxBatchesPerRun, pl.MaxRowsPerTransaction, pl.NextRunControlLimit,
        ConfiguredTableCount = COUNT_BIG(*),
        MissingTableCount = SUM(CASE WHEN dt.Status <> N'OK' THEN 1 ELSE 0 END),
        SourceRowsTotalAcrossConfiguredTables = SUM(COALESCE(dt.SourceRows, 0)),
        ConfiguredSourceUsedMB = CONVERT(decimal(19,2), SUM(COALESCE(dt.UsedMB, 0))),
        ConfiguredSourceDataMB = CONVERT(decimal(19,2), SUM(COALESCE(dt.DataMB, 0))),
        ConfiguredSourceIndexMB = CONVERT(decimal(19,2), SUM(COALESCE(dt.IndexMB, 0))),
        OneToOnePayloadMB = CONVERT(decimal(19,2), SUM(COALESCE(dt.OneToOnePayloadMB, 0))),
        RoughArchiveGrowthMB = CONVERT(decimal(19,2), CASE WHEN pl.Mode = 1 THEN SUM(COALESCE(dt.OneToOnePayloadMB, 0)) * @ArchiveGrowthFactor ELSE 0 END),
        RoughLogPressureMB = CONVERT(decimal(19,2), SUM(COALESCE(dt.OneToOnePayloadMB, 0)) * @LogMultiplier),
        PlanningMB_WithSafety = CONVERT(decimal(19,2),
            ((CASE WHEN pl.Mode = 1 THEN SUM(COALESCE(dt.OneToOnePayloadMB, 0)) * @ArchiveGrowthFactor ELSE 0 END)
             + SUM(COALESCE(dt.OneToOnePayloadMB, 0)) * @LogMultiplier) * @SafetyFactor),
        AbsoluteConfiguredTableFootprintMB = CONVERT(decimal(19,2), SUM(COALESCE(dt.UsedMB, 0)))
    FROM DistinctTable AS dt
    JOIN ProcessLimit AS pl ON pl.ProcessCode = dt.ProcessCode AND pl.SourceDb = dt.SourceDb AND ISNULL(pl.ArchiveDb,N'') = ISNULL(dt.ArchiveDb,N'')
    GROUP BY pl.ProcessCode, pl.SourceDb, pl.ArchiveDb, pl.Mode, pl.ModeName, pl.BatchDocCount, pl.BatchRowCount, pl.MaxBatchesPerRun, pl.MaxRowsPerTransaction, pl.NextRunControlLimit
    ORDER BY PlanningMB_WithSafety DESC, ConfiguredSourceUsedMB DESC, pl.SourceDb, pl.ProcessCode;

    /* (2) per-table detail */
    SELECT ProcessCode, SourceDb, ArchiveDb, ModeName, ObjectSpecId, DeleteOrder, SourceSchema, SourceTable, ArchiveSchema, ArchiveTable,
        SourceRows, UsedMB, DataMB, IndexMB, AvgUsedKBPerRow, NextRunControlLimit, OneToOneEstimatedRows, OneToOnePayloadMB, FullTableUsedMB, Status, ErrorMessage
    FROM #Detail
    ORDER BY SourceDb, ProcessCode, DeleteOrder, ObjectSpecId, UsedMB DESC;
END
GO

IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON arch.usp_Api_EstimateNextRunImpact TO karch_viewer;
IF DATABASE_PRINCIPAL_ID(N'karch_config_admin') IS NOT NULL
    GRANT EXECUTE ON arch.usp_Api_EstimateNextRunImpact TO karch_config_admin;
GO
PRINT 'arch.usp_Api_EstimateNextRunImpact (mapping-aware, all-DB) installed.';
GO
-- <<< end: kArchiveManagerAdmin\v2\060_estimate_next_run_impact.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\061_console_operators.sql
/* ============================================================================
   061_console_operators.sql — DB-managed Admin Console operators (arch.ConsoleOperator).
   ----------------------------------------------------------------------------
   Moves Admin Console operator credentials from appsettings into the control DB so they can be
   managed from the Console (add/edit/disable, set password) without an app-pool recycle. The API
   verifies the submitted password against the stored PBKDF2 hash SERVER-SIDE; the hash is returned
   only to the API auth path (usp_Api_GetConsoleOperatorForAuth, granted to the config/advanced admin
   roles the app login holds). appsettings Operators + the shared EditPasswordSha256 remain as a
   bootstrap/fallback (used first, and the only way in if the DB is unreachable).
   Idempotent. Error codes use the free 50510+ band. Read/manage granted to karch_config_admin.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'arch.ConsoleOperator', N'U') IS NULL
BEGIN
    CREATE TABLE arch.ConsoleOperator
    (
        OperatorId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ConsoleOperator PRIMARY KEY,
        Username       nvarchar(128)     NOT NULL CONSTRAINT UQ_ConsoleOperator_Username UNIQUE,
        DisplayName    nvarchar(200)     NULL,
        PasswordSha256 nvarchar(400)     NOT NULL,   -- PBKDF2-SHA256$iters$salt$hash (or legacy 64-hex)
        IsEnabled      bit               NOT NULL CONSTRAINT DF_ConsoleOperator_IsEnabled DEFAULT(1),
        IsElevated     bit               NOT NULL CONSTRAINT DF_ConsoleOperator_IsElevated DEFAULT(0),
        CreatedAt      datetime2(0)      NOT NULL CONSTRAINT DF_ConsoleOperator_CreatedAt DEFAULT(sysutcdatetime()),
        ModifiedAt     datetime2(0)      NOT NULL CONSTRAINT DF_ConsoleOperator_ModifiedAt DEFAULT(sysutcdatetime())
    );
    PRINT 'arch.ConsoleOperator created.';
END
GO

-- AUTH path: returns the stored hash + flags for ONE enabled operator. Sensitive (returns the hash) —
-- granted only to the config/advanced admin roles the app login holds, never to viewer.
CREATE OR ALTER PROCEDURE arch.usp_Api_GetConsoleOperatorForAuth
    @Username nvarchar(128)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) Username, DisplayName, PasswordSha256, IsEnabled, IsElevated
    FROM arch.ConsoleOperator
    WHERE Username = @Username AND IsEnabled = 1;
END
GO

-- Management LIST: never returns password hashes.
CREATE OR ALTER PROCEDURE arch.usp_Api_ListConsoleOperators
AS
BEGIN
    SET NOCOUNT ON;
    SELECT OperatorId, Username, DisplayName, IsEnabled, IsElevated, CreatedAt, ModifiedAt
    FROM arch.ConsoleOperator
    ORDER BY Username;
END
GO

-- Upsert an operator. @PasswordSha256 is the PBKDF2 hash the API computed from the typed password;
-- NULL on update keeps the current password (so you can edit flags without resetting the password).
CREATE OR ALTER PROCEDURE arch.usp_Api_SaveConsoleOperator
    @Username nvarchar(128),
    @DisplayName nvarchar(200) = NULL,
    @PasswordSha256 nvarchar(400) = NULL,
    @IsEnabled bit = 1,
    @IsElevated bit = 0,
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Username = NULLIF(LTRIM(RTRIM(@Username)), N'');
    SET @DisplayName = NULLIF(LTRIM(RTRIM(@DisplayName)), N'');
    SET @PasswordSha256 = NULLIF(LTRIM(RTRIM(@PasswordSha256)), N'');

    IF @Username IS NULL
        THROW 50510, 'Username is required.', 1;

    IF EXISTS (SELECT 1 FROM arch.ConsoleOperator WHERE Username = @Username)
    BEGIN
        UPDATE arch.ConsoleOperator
        SET DisplayName = @DisplayName,
            PasswordSha256 = COALESCE(@PasswordSha256, PasswordSha256),
            IsEnabled = @IsEnabled,
            IsElevated = @IsElevated,
            ModifiedAt = sysutcdatetime()
        WHERE Username = @Username;
    END
    ELSE
    BEGIN
        IF @PasswordSha256 IS NULL
            THROW 50511, 'A password is required when creating a new operator.', 1;
        INSERT arch.ConsoleOperator (Username, DisplayName, PasswordSha256, IsEnabled, IsElevated)
        VALUES (@Username, @DisplayName, @PasswordSha256, @IsEnabled, @IsElevated);
    END

    EXEC arch.usp_Api_ListConsoleOperators;
END
GO

CREATE OR ALTER PROCEDURE arch.usp_Api_DeleteConsoleOperator
    @Username nvarchar(128),
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM arch.ConsoleOperator WHERE Username = @Username;
    EXEC arch.usp_Api_ListConsoleOperators;
END
GO

IF DATABASE_PRINCIPAL_ID(N'karch_config_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON arch.usp_Api_GetConsoleOperatorForAuth TO karch_config_admin;
    GRANT EXECUTE ON arch.usp_Api_ListConsoleOperators TO karch_config_admin;
    GRANT EXECUTE ON arch.usp_Api_SaveConsoleOperator TO karch_config_admin;
    GRANT EXECUTE ON arch.usp_Api_DeleteConsoleOperator TO karch_config_admin;
END;
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON arch.usp_Api_GetConsoleOperatorForAuth TO karch_advanced_admin;
    GRANT EXECUTE ON arch.usp_Api_ListConsoleOperators TO karch_advanced_admin;
    GRANT EXECUTE ON arch.usp_Api_SaveConsoleOperator TO karch_advanced_admin;
    GRANT EXECUTE ON arch.usp_Api_DeleteConsoleOperator TO karch_advanced_admin;
END;
GO
PRINT 'arch.ConsoleOperator API installed (GetForAuth / List / Save / Delete).';
GO
-- <<< end: kArchiveManagerAdmin\v2\061_console_operators.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\062_console_login_audit.sql
/* ============================================================================
 * 062 — Console login audit
 * ----------------------------------------------------------------------------
 * Records Admin Console edit-unlock logins (success + failure) so the Config
 * view can show "who logged in and when". Purely additive: no existing auth
 * path changes, and recording is best-effort at the API layer (a DB outage
 * never blocks login). Mirrors the role-grant pattern of 061 (console operators).
 * ============================================================================ */
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
USE [kArchiveManagerAdmin];
GO

IF OBJECT_ID(N'arch.ConsoleLoginAudit', N'U') IS NULL
BEGIN
    CREATE TABLE arch.ConsoleLoginAudit
    (
        LoginId         bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ConsoleLoginAudit PRIMARY KEY,
        Username        nvarchar(256)  NULL,           -- resolved operator / "(shared password)"
        WindowsIdentity nvarchar(256)  NULL,           -- HttpContext.User identity, if present
        Source          nvarchar(20)   NOT NULL,       -- shared | operator | windows
        Success         bit            NOT NULL,
        FailureReason   nvarchar(200)  NULL,
        Ip              nvarchar(45)   NULL,
        LoginAtUtc      datetime2(0)   NOT NULL
            CONSTRAINT DF_ConsoleLoginAudit_At DEFAULT (SYSUTCDATETIME())
    );
    CREATE NONCLUSTERED INDEX IX_ConsoleLoginAudit_At   ON arch.ConsoleLoginAudit (LoginAtUtc DESC);
    CREATE NONCLUSTERED INDEX IX_ConsoleLoginAudit_User ON arch.ConsoleLoginAudit (Username, LoginAtUtc DESC);
END
GO

/* Record one login attempt. Called best-effort from the unlock endpoint. */
CREATE OR ALTER PROCEDURE arch.usp_Api_RecordConsoleLogin
    @Username        nvarchar(256) = NULL,
    @WindowsIdentity nvarchar(256) = NULL,
    @Source          nvarchar(20),
    @Success         bit,
    @FailureReason   nvarchar(200) = NULL,
    @Ip              nvarchar(45)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT arch.ConsoleLoginAudit (Username, WindowsIdentity, Source, Success, FailureReason, Ip)
    VALUES (NULLIF(LTRIM(RTRIM(@Username)), N''), NULLIF(LTRIM(RTRIM(@WindowsIdentity)), N''),
            @Source, @Success, NULLIF(LTRIM(RTRIM(@FailureReason)), N''), NULLIF(LTRIM(RTRIM(@Ip)), N''));
END
GO

/* Most recent login attempts, newest first (top of the list = last login). */
CREATE OR ALTER PROCEDURE arch.usp_Api_GetConsoleLastLogins
    @Top int = 20
AS
BEGIN
    SET NOCOUNT ON;
    SET @Top = CASE WHEN @Top IS NULL OR @Top < 1 THEN 20 WHEN @Top > 200 THEN 200 ELSE @Top END;
    SELECT TOP (@Top)
        Username = ISNULL(Username, N'(shared password)'),
        WindowsIdentity,
        Source,
        Success,
        FailureReason,
        Ip,
        LoginAtUtc
    FROM arch.ConsoleLoginAudit
    ORDER BY LoginAtUtc DESC, LoginId DESC;
END
GO

/* Grants — the Admin Console app login holds these roles (same as 061). */
BEGIN TRY
    IF DATABASE_PRINCIPAL_ID('karch_config_admin') IS NOT NULL
    BEGIN
        GRANT EXECUTE ON arch.usp_Api_RecordConsoleLogin   TO karch_config_admin;
        GRANT EXECUTE ON arch.usp_Api_GetConsoleLastLogins TO karch_config_admin;
    END
    IF DATABASE_PRINCIPAL_ID('karch_advanced_admin') IS NOT NULL
    BEGIN
        GRANT EXECUTE ON arch.usp_Api_RecordConsoleLogin   TO karch_advanced_admin;
        GRANT EXECUTE ON arch.usp_Api_GetConsoleLastLogins TO karch_advanced_admin;
    END
END TRY BEGIN CATCH END CATCH;
GO

PRINT '062 console login audit installed (arch.ConsoleLoginAudit + record/get procs).';
GO
-- <<< end: kArchiveManagerAdmin\v2\062_console_login_audit.sql
GO
GO

-- ---- Phase 12b: frontend concurrency proc (optimistic-concurrency for ObjectSpec edits) ----
-- Creates arch.usp_Api_CheckConfigConcurrency (required by ReadinessService) + idempotent
-- ObjectSpec CreatedAt/ModifiedAt columns + ModifiedAt trigger. The v_ObjectSpecDatabaseEffective
-- VIEW that projects these columns is owned solely by v2/022 (single source of truth); this script
-- does NOT re-create it. Runs AFTER 022 (view) and BEFORE frontend/010 (so 010's grant finds the proc).
-- >>> inlined: deploy\v2\33_update_frontend_concurrency_metadata.sql
/*
Frontend concurrency metadata update.

Installs the optimistic-concurrency support the Admin Console uses to protect ObjectSpec edits:
the ObjectSpec CreatedAt/ModifiedAt columns + ModifiedAt trigger (idempotent), and the
arch.usp_Api_CheckConfigConcurrency procedure.

The v_ObjectSpecDatabaseEffective VIEW that projects these columns is owned SOLELY by
kArchiveManagerAdmin\v2\022_effective_database_overrides.sql. This script intentionally does NOT
re-create that view: doing so once shipped an older column list that dropped the cheap-mode
CandidateSelectExpr column and broke the TIMESTAMP runner. On an existing environment, (re-)run
022 to refresh the view with the ModifiedAt columns.
*/

PRINT 'kArchiveManager frontend concurrency metadata update started.';
GO

USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF COL_LENGTH(N'arch.ObjectSpec', N'CreatedAt') IS NULL
BEGIN
    ALTER TABLE [arch].[ObjectSpec]
    ADD [CreatedAt] datetime2(0) NOT NULL
        CONSTRAINT [DF_ObjectSpec_CreatedAt] DEFAULT (sysutcdatetime()) WITH VALUES;
END
GO

IF COL_LENGTH(N'arch.ObjectSpec', N'ModifiedAt') IS NULL
BEGIN
    ALTER TABLE [arch].[ObjectSpec]
    ADD [ModifiedAt] datetime2(0) NOT NULL
        CONSTRAINT [DF_ObjectSpec_ModifiedAt] DEFAULT (sysutcdatetime()) WITH VALUES;
END
GO

CREATE OR ALTER TRIGGER [arch].[tr_ObjectSpec_SetModifiedAt]
ON [arch].[ObjectSpec]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF TRIGGER_NESTLEVEL() > 1
        RETURN;

    UPDATE os
    SET ModifiedAt = CONVERT(datetime2(0), sysutcdatetime())
    FROM [arch].[ObjectSpec] AS os
    JOIN inserted AS i
      ON i.ObjectSpecId = os.ObjectSpecId;
END
GO

-- NOTE: v_ObjectSpecDatabaseEffective is created by v2/022 (single source of truth) and projects the
-- ObjectSpec ModifiedAt columns added above. This script does NOT re-create the view — see header.

CREATE OR ALTER PROCEDURE [arch].[usp_Api_CheckConfigConcurrency]
    @EntityType nvarchar(80),
    @ExpectedModifiedAt datetime2(0),
    @ProcessCode sysname = NULL,
    @ProcessDatabaseId int = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @ObjectSpecId int = NULL,
    @ObjectSpecDatabaseOverrideId int = NULL,
    @RunProfileId int = NULL,
    @ProcessKeySpecId int = NULL,
    @IndexRequirementId int = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentModifiedAt datetime2(0);

    IF @ExpectedModifiedAt IS NULL
    BEGIN
        SELECT State = 0, CurrentModifiedAt = CONVERT(datetime2(0), NULL);
        RETURN;
    END;

    IF @EntityType = N'Process'
    BEGIN
        SELECT @CurrentModifiedAt = ModifiedAt
        FROM arch.Process
        WHERE ProcessCode = @ProcessCode;
    END
    ELSE IF @EntityType = N'ProcessDatabase'
    BEGIN
        SELECT TOP (1) @CurrentModifiedAt = pd.ModifiedAt
        FROM arch.ProcessDatabase pd
        JOIN arch.Process p
          ON p.ProcessId = pd.ProcessId
        WHERE (@ProcessDatabaseId IS NOT NULL AND pd.ProcessDatabaseId = @ProcessDatabaseId)
           OR (@ProcessDatabaseId IS NULL AND p.ProcessCode = @ProcessCode AND pd.SourceDb = @SourceDb AND pd.ArchiveDb = @ArchiveDb);
    END
    ELSE IF @EntityType = N'ObjectSpec'
    BEGIN
        SELECT @CurrentModifiedAt = ModifiedAt
        FROM arch.ObjectSpec
        WHERE ObjectSpecId = @ObjectSpecId;
    END
    ELSE IF @EntityType = N'ObjectSpecDatabaseOverride'
    BEGIN
        IF @ObjectSpecDatabaseOverrideId IS NULL
            SET @CurrentModifiedAt = @ExpectedModifiedAt;
        ELSE
            SELECT @CurrentModifiedAt = ModifiedAt
            FROM arch.ObjectSpecDatabaseOverride
            WHERE ObjectSpecDatabaseOverrideId = @ObjectSpecDatabaseOverrideId;
    END
    ELSE IF @EntityType = N'RunProfile'
    BEGIN
        SELECT @CurrentModifiedAt = ModifiedAt
        FROM arch.RunProfile
        WHERE RunProfileId = @RunProfileId;
    END
    ELSE IF @EntityType = N'ProcessKeySpec'
    BEGIN
        SELECT @CurrentModifiedAt = ModifiedAt
        FROM arch.ProcessKeySpec
        WHERE ProcessKeySpecId = @ProcessKeySpecId;
    END
    ELSE IF @EntityType = N'IndexRequirement'
    BEGIN
        SELECT @CurrentModifiedAt = ModifiedAt
        FROM arch.IndexRequirement
        WHERE IndexRequirementId = @IndexRequirementId;
    END
    ELSE
        THROW 57600, 'Unsupported concurrency entity type.', 1;

    SELECT
        State = CASE
            WHEN @CurrentModifiedAt IS NULL THEN 404
            WHEN CONVERT(datetime2(0), @CurrentModifiedAt) = CONVERT(datetime2(0), @ExpectedModifiedAt) THEN 0
            ELSE 409
        END,
        CurrentModifiedAt = @CurrentModifiedAt;
END
GO

IF DATABASE_PRINCIPAL_ID(N'karch_config_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Api_CheckConfigConcurrency] TO [karch_config_admin];
GO

IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Api_CheckConfigConcurrency] TO [karch_advanced_admin];
GO

SELECT
    ViewName = N'arch.v_ObjectSpecDatabaseEffective',
    HasObjectSpecModifiedAt =
        CONVERT(bit, CASE WHEN COL_LENGTH(N'arch.v_ObjectSpecDatabaseEffective', N'ObjectSpecModifiedAt') IS NULL THEN 0 ELSE 1 END),
    HasObjectSpecOverrideModifiedAt =
        CONVERT(bit, CASE WHEN COL_LENGTH(N'arch.v_ObjectSpecDatabaseEffective', N'ObjectSpecOverrideModifiedAt') IS NULL THEN 0 ELSE 1 END),
    ObjectSpecModifiedAtTriggerId = OBJECT_ID(N'arch.tr_ObjectSpec_SetModifiedAt', N'TR'),
    CheckProcedureId = OBJECT_ID(N'arch.usp_Api_CheckConfigConcurrency', N'P');
GO

PRINT 'kArchiveManager frontend concurrency metadata update completed.';
GO
-- <<< end: deploy\v2\33_update_frontend_concurrency_metadata.sql
GO
GO

-- ---- Phase 13: role model + EXECUTE grants (AFTER all procs exist) ----
-- >>> inlined: kArchiveManagerAdmin\frontend\010_frontend_security_roles.sql
USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NULL
    CREATE ROLE [karch_viewer];
GO

IF DATABASE_PRINCIPAL_ID(N'karch_operator') IS NULL
    CREATE ROLE [karch_operator];
GO

IF DATABASE_PRINCIPAL_ID(N'karch_config_admin') IS NULL
    CREATE ROLE [karch_config_admin];
GO

IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NULL
    CREATE ROLE [karch_advanced_admin];
GO

IF DATABASE_PRINCIPAL_ID(N'karch_approver') IS NULL
    CREATE ROLE [karch_approver];
GO

DECLARE @Grants table
(
    RoleName sysname NOT NULL,
    SchemaName sysname NOT NULL,
    ObjectName sysname NOT NULL,
    Required bit NOT NULL
);

INSERT INTO @Grants(RoleName, SchemaName, ObjectName, Required)
VALUES
    (N'karch_viewer', N'arch', N'usp_Frontend_GetProcessConfigSummary', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetEffectiveProcessDatabases', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetEffectiveObjects', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetTableMovementCounts', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetProcessMovementSummary', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetProcessedHistory', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetWorkBatchActivity', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetRecentRuns', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetRunDetail', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_SearchDocumentAuditSummary', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_SearchDocumentAuditDetails', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetConfigChangeHistory', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetProcessKeySpecs', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetIndexRequirements', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetRunProfiles', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetSelectionStrategies', 1),

    (N'karch_operator', N'arch', N'usp_Api_ValidateConfiguration', 1),
    (N'karch_operator', N'arch', N'usp_Api_ValidateIndexRequirements', 1),
    (N'karch_operator', N'arch', N'usp_Api_ExplainProcessPlan', 1),

    (N'karch_config_admin', N'arch', N'usp_Api_SaveProcess', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SaveProcessDatabase', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SaveObjectSpec', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SaveObjectSpecOverride', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SaveRunProfile', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_CheckConfigConcurrency', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SetProcessEnabled', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SetProcessDatabaseEnabled', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SetObjectOverrideEnabled', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SetRunProfileEnabled', 1),

    (N'karch_advanced_admin', N'arch', N'usp_Api_SaveProcessKeySpec', 1),
    (N'karch_advanced_admin', N'arch', N'usp_Api_SaveIndexRequirement', 1),
    (N'karch_advanced_admin', N'arch', N'usp_Api_CheckConfigConcurrency', 1),

    (N'karch_approver', N'arch', N'usp_Api_CreateConfigChangeSet', 1),
    (N'karch_approver', N'arch', N'usp_Api_RecordConfigFieldChange', 1),
    (N'karch_approver', N'arch', N'usp_Api_FinalizeConfigChangeSet', 1);

DECLARE
    @RoleName sysname,
    @SchemaName sysname,
    @ObjectName sysname,
    @Sql nvarchar(max);

DECLARE grant_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    RoleName,
    SchemaName,
    ObjectName
FROM @Grants
WHERE OBJECT_ID(QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName), N'P') IS NOT NULL
ORDER BY
    RoleName,
    ObjectName;

OPEN grant_cursor;
FETCH NEXT FROM grant_cursor INTO @RoleName, @SchemaName, @ObjectName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql =
        N'GRANT EXECUTE ON OBJECT::' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ObjectName) +
        N' TO ' + QUOTENAME(@RoleName) + N';';

    EXEC sys.sp_executesql @Sql;

    FETCH NEXT FROM grant_cursor INTO @RoleName, @SchemaName, @ObjectName;
END;

CLOSE grant_cursor;
DEALLOCATE grant_cursor;

IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
    GRANT SELECT ON OBJECT::[arch].[Process] TO [karch_viewer];

IF OBJECT_ID(N'arch.ProcessDatabase', N'U') IS NOT NULL
    GRANT SELECT ON OBJECT::[arch].[ProcessDatabase] TO [karch_viewer];

GRANT VIEW DEFINITION ON SCHEMA::[arch] TO [karch_viewer];

SELECT
    RoleName,
    SchemaName,
    ObjectName,
    GrantStatus =
        CASE
            WHEN OBJECT_ID(QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName), N'P') IS NULL THEN N'SKIPPED_MISSING_OBJECT'
            WHEN HAS_PERMS_BY_NAME(QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName), N'OBJECT', N'EXECUTE') = 1 THEN N'GRANTED_OR_OWNED_BY_CALLER'
            ELSE N'CHECK_ROLE_PERMISSION'
        END
FROM @Grants
ORDER BY
    RoleName,
    ObjectName;
GO
-- <<< end: kArchiveManagerAdmin\frontend\010_frontend_security_roles.sql
GO
GO

-- ---- Phase 13b: re-apply the guarded stop/restore grants now that the roles exist ----
USE [kArchiveManagerAdmin];
GO
IF DATABASE_PRINCIPAL_ID(N'karch_operator') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Api_RequestRunStop] TO [karch_operator];
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_RestoreFromArchive] TO [karch_advanced_admin];
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GoLiveReadiness] TO [karch_viewer];
GO

-- ---- Phase 13c: T-33 runtime least-privilege role + runner-privilege verify/inventory ----
-- (after the karch_* roles exist; the customer runner login + cross-DB grants are applied by the
--  parameterized add-on deploy\v2\053_runtime_least_privilege_principal.sql, then deploy\v2\054.)
-- >>> inlined: kArchiveManagerAdmin\v2\055_runtime_runner_role_and_verify.sql
USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
/* ============================================================================
   055 — T-33 (bundle part): least-privilege RUNTIME role + runner-privilege verify/inventory
   ----------------------------------------------------------------------------
   WHY: the archive runner performs the most dangerous operation in the system — an irreversible
   cross-DB DELETE of production rows. Today the "RUN CONFIGURED" SQL Agent job runs a T-SQL step
   with no proxy, so it executes under the SQL Agent service account (de-facto sysadmin for T-SQL):
   the runner's identity in the source DBs is unconstrained (T-33). This script installs the
   customer-AGNOSTIC half of the fix that belongs in the clean bundle:

     1. role [karch_runtime] — granted EXECUTE on the runner proc chain ONLY. The runner's writes to
        the Admin control tables (arch.Run/RunItem/RunItemObject/RunDocAudit/WorkBatch/WorkBatchKey/
        ArchiveProvisionLog) are STATIC SQL inside those procs, so they reach the tables through
        OWNERSHIP CHAINING (proc and tables share owner dbo) — the runtime principal therefore needs
        NO direct table DML in the Admin DB, only EXECUTE.  The cross-DB DELETE/OUTPUT-INTO is DYNAMIC
        SQL (chaining broken) and needs EXPLICIT source/archive grants — those are applied per-customer
        by deploy/v2/053_runtime_least_privilege_principal.sql.

     2. arch.usp_VerifyRunnerPrivileges — asserts the CURRENT principal (i.e. the runtime login, when
        run by the job's VALIDATE step) is NOT sysadmin / db_owner / db_ddladmin / db_securityadmin /
        db_datawriter, and HAS SELECT+DELETE on every enabled mapped source table and INSERT on every
        archive table.  RETURN 1 (and an ERROR result row) on any violation so the job's VALIDATE step
        can THROW and block the run.  (Honors T-33's "assert runner has DELETE on every mapped table
        and does not hold db_owner/sysadmin" without destabilising the heavily-used
        usp_ValidateConfiguration — the job step calls BOTH.)

     3. arch.RunnerPrivilegeInventory + arch.usp_CaptureRunnerPrivilegeInventory — capture the runtime
        principal's effective source/archive-DB role memberships + explicit object permissions into an
        audit inventory (T-33 "zachytit source-DB granty do audit inventáře").

   The privilege checks are evaluated for the CURRENT principal (HAS_PERMS_BY_NAME / IS_ROLEMEMBER are
   current-context). Run usp_VerifyRunnerPrivileges AS the runtime login — the job's VALIDATE step does
   this automatically; for an out-of-band DBA audit wrap it:
       EXECUTE AS LOGIN = N'<runtime login>'; EXEC arch.usp_VerifyRunnerPrivileges; REVERT;
   ============================================================================ */

/* ---- 1) role: karch_runtime ------------------------------------------------ */
IF DATABASE_PRINCIPAL_ID(N'karch_runtime') IS NULL
    CREATE ROLE [karch_runtime];
GO

DECLARE @procs TABLE (name sysname PRIMARY KEY);
INSERT @procs(name) VALUES
    (N'usp_RunProfile_Prepared'),
    (N'usp_RunScheduledProfiles_Prepared'),
    (N'usp_RunConfiguredProcesses_Prepared'),
    (N'usp_RunPreparedBatch'),
    (N'usp_RunPreparedBatches_InWindow'),
    (N'usp_PrepareCandidates'),
    (N'usp_RunTimestampProcess'),
    (N'usp_EnsureArchiveTableLikeSource'),
    (N'usp_GetOutputColumns'),
    (N'usp_AssertTimezonePolicyApplied'),
    (N'usp_ValidateConfiguration'),
    (N'usp_RecoverStaleRuns');
    -- NB: usp_VerifyRunnerPrivileges is created LATER in this script, so it cannot be granted by this
    --     existence-guarded cursor; it is granted to karch_runtime explicitly at the end of the file.

DECLARE @n sysname, @g nvarchar(max);
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM @procs WHERE OBJECT_ID(N'arch.' + name, N'P') IS NOT NULL;
OPEN pc;
FETCH NEXT FROM pc INTO @n;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @g = N'GRANT EXECUTE ON OBJECT::arch.' + QUOTENAME(@n) + N' TO [karch_runtime];';
    EXEC sys.sp_executesql @g;
    FETCH NEXT FROM pc INTO @n;
END
CLOSE pc;
DEALLOCATE pc;
GO

-- Metadata visibility: the runner procs guard with OBJECT_ID()/COL_LENGTH() on arch.* control tables.
-- Those metadata functions follow the CALLER's visibility and are NOT covered by ownership chaining
-- (chaining covers DATA access only), so without this the guards see NULL under the least-priv runner
-- and falsely THROW (e.g. 50107 'arch.ProcessKeySpec neni nainstalovana'). VIEW DEFINITION grants
-- metadata visibility only — no data SELECT (data access still flows through the procs via chaining).
IF DATABASE_PRINCIPAL_ID(N'karch_runtime') IS NOT NULL
    GRANT VIEW DEFINITION ON SCHEMA::[arch] TO [karch_runtime];
GO

/* ---- 2) runner-privilege inventory table ----------------------------------- */
IF OBJECT_ID(N'arch.RunnerPrivilegeInventory', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[RunnerPrivilegeInventory]
    (
        InventoryId   bigint IDENTITY(1,1) NOT NULL CONSTRAINT [PK_RunnerPrivilegeInventory] PRIMARY KEY,
        CapturedAtUtc datetime2(0) NOT NULL CONSTRAINT [DF_RunnerPrivInv_At] DEFAULT (SYSUTCDATETIME()),
        CapturedBy    sysname NULL,
        RunnerLogin   sysname NOT NULL,
        DbName        sysname NOT NULL,
        PrincipalName sysname NULL,
        GrantKind     nvarchar(20) NOT NULL,     -- 'ROLE' | 'PERMISSION'
        Detail        nvarchar(400) NOT NULL
    );
    CREATE NONCLUSTERED INDEX [IX_RunnerPrivInv_At]
        ON [arch].[RunnerPrivilegeInventory] (CapturedAtUtc DESC, RunnerLogin, DbName);
END
GO

/* ---- 3) verify the current principal is a correct least-priv runner -------- */
CREATE OR ALTER PROCEDURE [arch].[usp_VerifyRunnerPrivileges]
    @ProcessCode sysname = NULL,        -- optional scope
    @SourceDb    sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @me sysname = SUSER_SNAME();

    CREATE TABLE #VF
    (
        Severity   varchar(10)   NOT NULL,
        Scope      nvarchar(20)  NOT NULL,    -- 'SERVER' | 'SOURCE' | 'ARCHIVE'
        DbName     sysname       NULL,
        ObjectName nvarchar(300) NULL,
        Finding    nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL
    );

    /* (a) the runner must NOT be sysadmin — sysadmin would bypass every per-table check below */
    IF IS_SRVROLEMEMBER(N'sysadmin') = 1
        INSERT #VF(Severity, Scope, Finding)
        VALUES ('ERROR', N'SERVER',
                N'Runner principal [' + @me + N'] is a member of the sysadmin server role. The unattended '
              + N'archive runner must run under a dedicated NON-sysadmin login (see deploy/v2/053). '
              + N'Re-own the SQL Agent job to the least-privilege login (deploy/v2/054).');

    /* (b)/(c) per enabled mapping: archive-side INSERT and source-side SELECT+DELETE + not db_owner */
    DECLARE @db sysname, @sch sysname, @tbl sysname, @asch sysname, @atbl sysname, @mode tinyint,
            @obj nvarchar(512), @aobj nvarchar(512), @sql nvarchar(max),
            @selOk int, @delOk int, @insOk int, @powner int, @evaluated bit, @schemaExists int;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT
            os.SourceDb, os.SourceSchema, os.SourceTable,
            CONVERT(sysname, REPLACE(
                CASE WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo'
                     THEN N'{SourceDb}' ELSE LTRIM(RTRIM(os.ArchiveSchema)) END, N'{SourceDb}', os.SourceDb)),
            COALESCE(NULLIF(os.ArchiveTable, N''), os.SourceTable),
            e.Mode, os.ArchiveDb
        FROM arch.v_ObjectSpecDatabaseEffective os
        JOIN arch.v_ProcessDatabaseEffective e ON e.ProcessDatabaseId = os.ProcessDatabaseId
        WHERE os.ProcessDatabaseIsEnabled = 1
          AND os.ObjectIsEnabled = 1
          AND DB_ID(os.SourceDb) IS NOT NULL
          AND DB_ID(os.ArchiveDb) IS NOT NULL
          AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb);

    DECLARE @archDb sysname;
    OPEN c;
    FETCH NEXT FROM c INTO @db, @sch, @tbl, @asch, @atbl, @mode, @archDb;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        /* source: SELECT + DELETE on the mapped table, and the runner must not be a high-priv db role */
        SET @obj = QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl);
        SET @selOk = NULL; SET @delOk = NULL; SET @powner = NULL; SET @evaluated = 1;
        SET @sql = N'USE ' + QUOTENAME(@db) + N';
            SELECT @selOk = CONVERT(int, HAS_PERMS_BY_NAME(@o, ''OBJECT'', ''SELECT'')),
                   @delOk = CONVERT(int, HAS_PERMS_BY_NAME(@o, ''OBJECT'', ''DELETE'')),
                   @po = COALESCE(IS_ROLEMEMBER(''db_owner''),0)
                       + COALESCE(IS_ROLEMEMBER(''db_ddladmin''),0)
                       + COALESCE(IS_ROLEMEMBER(''db_securityadmin''),0)
                       + COALESCE(IS_ROLEMEMBER(''db_datawriter''),0);';
        BEGIN TRY
            EXEC sys.sp_executesql @sql,
                 N'@o nvarchar(512), @selOk int OUTPUT, @delOk int OUTPUT, @po int OUTPUT',
                 @o = @obj, @selOk = @selOk OUTPUT, @delOk = @delOk OUTPUT, @po = @powner OUTPUT;
        END TRY
        BEGIN CATCH
            SET @evaluated = 0;   -- could not connect/USE this DB; report once as WARN, no spurious ERROR
            INSERT #VF(Severity, Scope, DbName, ObjectName, Finding)
            VALUES ('WARN', N'SOURCE', @db, @obj,
                    N'Could not evaluate source-table permissions (' + ERROR_MESSAGE() + N').');
        END CATCH

        IF @evaluated = 1
        BEGIN
            IF COALESCE(@delOk, 0) < 1
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding, SuggestedSql)
                VALUES ('ERROR', N'SOURCE', @db, @obj,
                        N'Runner [' + @me + N'] lacks DELETE on the mapped source table (or the table is not visible to it).',
                        N'USE ' + QUOTENAME(@db) + N'; GRANT SELECT, DELETE ON OBJECT::' + @obj + N' TO [karch_runtime];');
            ELSE IF COALESCE(@selOk, 0) < 1
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding, SuggestedSql)
                VALUES ('ERROR', N'SOURCE', @db, @obj,
                        N'Runner [' + @me + N'] lacks SELECT on the mapped source table.',
                        N'USE ' + QUOTENAME(@db) + N'; GRANT SELECT, DELETE ON OBJECT::' + @obj + N' TO [karch_runtime];');

            IF COALESCE(@powner, 0) > 0
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding)
                VALUES ('ERROR', N'SOURCE', @db, @obj,
                        N'Runner [' + @me + N'] is a member of a high-privilege database role (db_owner / db_ddladmin / '
                      + N'db_securityadmin / db_datawriter) in source DB [' + @db + N']. The runner must hold only '
                      + N'SELECT+DELETE on the mapped tables via [karch_runtime]. Remove the broad role membership.');
        END;

        /* archive: the schema must exist (a non-dbo runner cannot CREATE SCHEMA at run time) and the
           runner needs INSERT on the archive table (DELETE/OUTPUT INTO target). COALESCE NULL Mode->1
           so an unset Mode is treated as archive+delete (the safe default). */
        IF COALESCE(@mode, 1) = 1
        BEGIN
            SET @aobj = QUOTENAME(@asch) + N'.' + QUOTENAME(@atbl);
            SET @insOk = NULL; SET @schemaExists = NULL;
            SET @sql = N'USE ' + QUOTENAME(@archDb) + N';
                SELECT @schemaExists = CASE WHEN SCHEMA_ID(@sch) IS NULL THEN 0 ELSE 1 END,
                       @insOk = CONVERT(int, HAS_PERMS_BY_NAME(@o, ''OBJECT'', ''INSERT''));';
            BEGIN TRY
                EXEC sys.sp_executesql @sql, N'@sch sysname, @o nvarchar(512), @schemaExists int OUTPUT, @insOk int OUTPUT',
                     @sch = @asch, @o = @aobj, @schemaExists = @schemaExists OUTPUT, @insOk = @insOk OUTPUT;
            END TRY
            BEGIN CATCH
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding)
                VALUES ('WARN', N'ARCHIVE', @archDb, @aobj,
                        N'Could not evaluate archive INSERT/schema (' + ERROR_MESSAGE() + N').');
            END CATCH

            IF COALESCE(@schemaExists, 1) = 0
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding, SuggestedSql)
                VALUES ('ERROR', N'ARCHIVE', @archDb, @asch,
                        N'Archive schema [' + @asch + N'] does not exist in [' + @archDb + N']. The non-sysadmin runner '
                      + N'cannot CREATE SCHEMA at run time — re-run deploy/v2/053 (it pre-creates archive schemas as the DBA).',
                        N'USE ' + QUOTENAME(@archDb) + N'; IF SCHEMA_ID(N''' + REPLACE(@asch, N'''', N'''''') + N''') IS NULL EXEC(N''CREATE SCHEMA ' + QUOTENAME(@asch) + N' AUTHORIZATION dbo'');');

            IF COALESCE(@insOk, 0) < 1
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding, SuggestedSql)
                VALUES ('WARN', N'ARCHIVE', @archDb, @aobj,
                        N'Runner [' + @me + N'] lacks INSERT on the archive table (or it is not provisioned yet — '
                      + N'deploy/v2/053 grants INSERT on the whole archive schema, which covers tables created later).',
                        N'USE ' + QUOTENAME(@archDb) + N'; GRANT INSERT ON OBJECT::' + @aobj + N' TO [karch_runtime];');
        END;

        FETCH NEXT FROM c INTO @db, @sch, @tbl, @asch, @atbl, @mode, @archDb;
    END
    CLOSE c;
    DEALLOCATE c;

    /* ANCHOR candidate (header) table: the ANCHOR candidate scan reads FROM AnchorSchema.AnchorTable
       (v_ProcessDatabaseEffective), which may have NO ObjectSpec row, so it is invisible to the loop
       above. It needs SELECT only (it is never deleted directly). */
    DECLARE @adb sysname, @ansch sysname, @antbl sysname, @aobj2 nvarchar(512), @anSel int, @anEval bit;
    DECLARE ac CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT e.SourceDb, e.AnchorSchema, e.AnchorTable
        FROM arch.v_ProcessDatabaseEffective e
        WHERE e.IsEnabled = 1
          AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
          AND DB_ID(e.SourceDb) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(e.AnchorTable)), N'') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(e.AnchorSchema)), N'') IS NOT NULL
          AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb);
    OPEN ac;
    FETCH NEXT FROM ac INTO @adb, @ansch, @antbl;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @aobj2 = QUOTENAME(@ansch) + N'.' + QUOTENAME(@antbl);
        SET @anSel = NULL; SET @anEval = 1;
        SET @sql = N'USE ' + QUOTENAME(@adb) + N'; SELECT @s = CONVERT(int, HAS_PERMS_BY_NAME(@o, ''OBJECT'', ''SELECT''));';
        BEGIN TRY
            EXEC sys.sp_executesql @sql, N'@o nvarchar(512), @s int OUTPUT', @o = @aobj2, @s = @anSel OUTPUT;
        END TRY
        BEGIN CATCH SET @anEval = 0; END CATCH

        IF @anEval = 1 AND COALESCE(@anSel, 0) < 1
            INSERT #VF(Severity, Scope, DbName, ObjectName, Finding, SuggestedSql)
            VALUES ('ERROR', N'SOURCE', @adb, @aobj2,
                    N'Runner [' + @me + N'] lacks SELECT on the ANCHOR candidate (header) table — the ANCHOR candidate '
                  + N'scan reads from it. (It is a Process/ProcessDatabase anchor, not necessarily an ObjectSpec row.)',
                    N'USE ' + QUOTENAME(@adb) + N'; GRANT SELECT ON OBJECT::' + @aobj2 + N' TO [karch_runtime];');

        FETCH NEXT FROM ac INTO @adb, @ansch, @antbl;
    END
    CLOSE ac;
    DEALLOCATE ac;

    IF NOT EXISTS (SELECT 1 FROM #VF)
        INSERT #VF(Severity, Scope, Finding)
        VALUES ('OK', N'SERVER', N'Runner principal [' + @me + N'] holds a correct least-privilege footprint for all enabled mappings.');

    SELECT Severity, Scope, DbName, ObjectName, Finding, SuggestedSql
    FROM #VF
    ORDER BY CASE Severity WHEN 'ERROR' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, Scope, DbName, ObjectName;

    IF EXISTS (SELECT 1 FROM #VF WHERE Severity = 'ERROR')
        RETURN 1;
    RETURN 0;
END
GO

/* ---- 4) capture the runtime principal's effective grants into the inventory --- */
CREATE OR ALTER PROCEDURE [arch].[usp_CaptureRunnerPrivilegeInventory]
    @RunnerLogin  sysname,
    @DbsCsv       nvarchar(max),        -- source + archive DBs to inventory, comma-separated
    @CapturedBy   sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @CapturedBy = COALESCE(@CapturedBy, SUSER_SNAME());

    DECLARE @db sysname, @sql nvarchar(max);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DbsCsv, N',')
        WHERE NULLIF(LTRIM(RTRIM(value)), N'') IS NOT NULL;
    OPEN c;
    FETCH NEXT FROM c INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF DB_ID(@db) IS NULL
        BEGIN
            FETCH NEXT FROM c INTO @db; CONTINUE;
        END;

        SET @sql = N'USE ' + QUOTENAME(@db) + N';
            -- resolve by SID (not name) so a DB user created with a name <> its login is still found.
            -- NOTE: this proc writes cross-DB into the Admin inventory table, so it must run with INSERT
            -- there (i.e. as the DBA at deploy time) — never under the runner / EXECUTE AS.
            DECLARE @uid int = (SELECT principal_id FROM sys.database_principals WHERE sid = SUSER_SID(@login));
            IF @uid IS NOT NULL
            BEGIN
                INSERT [kArchiveManagerAdmin].arch.RunnerPrivilegeInventory(CapturedBy, RunnerLogin, DbName, PrincipalName, GrantKind, Detail)
                SELECT @by, @login, @dbn, dp.name, N''ROLE'', rp.name
                FROM sys.database_role_members drm
                JOIN sys.database_principals rp ON rp.principal_id = drm.role_principal_id
                JOIN sys.database_principals dp ON dp.principal_id = drm.member_principal_id
                WHERE drm.member_principal_id = @uid;

                INSERT [kArchiveManagerAdmin].arch.RunnerPrivilegeInventory(CapturedBy, RunnerLogin, DbName, PrincipalName, GrantKind, Detail)
                SELECT @by, @login, @dbn, pr.name, N''PERMISSION'',
                       perm.state_desc + N'' '' + perm.permission_name + N'' ON '' + perm.class_desc
                     + COALESCE(N'' ['' + OBJECT_SCHEMA_NAME(perm.major_id) + N''.'' + OBJECT_NAME(perm.major_id) + N'']'', N'''')
                FROM sys.database_permissions perm
                JOIN sys.database_principals pr ON pr.principal_id = perm.grantee_principal_id
                WHERE perm.grantee_principal_id = @uid;
            END;';
        EXEC sys.sp_executesql @sql,
             N'@login sysname, @dbn sysname, @by sysname',
             @login = @RunnerLogin, @dbn = @db, @by = @CapturedBy;

        FETCH NEXT FROM c INTO @db;
    END
    CLOSE c;
    DEALLOCATE c;

    SELECT CapturedAtUtc, RunnerLogin, DbName, PrincipalName, GrantKind, Detail
    FROM arch.RunnerPrivilegeInventory
    WHERE RunnerLogin = @RunnerLogin
      AND CapturedAtUtc >= DATEADD(MINUTE, -1, SYSUTCDATETIME())
    ORDER BY DbName, GrantKind, Detail;
END
GO

-- The runner itself must EXECUTE the verify proc: the RUN CONFIGURED job's VALIDATE step calls it under
-- the runner identity. It is created AFTER the role-grant cursor above, so grant it here. (Capture stays
-- DBA-only — it writes cross-DB into the Admin inventory table and must run as the deploying sysadmin.)
IF DATABASE_PRINCIPAL_ID(N'karch_runtime') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_VerifyRunnerPrivileges] TO [karch_runtime];
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON [arch].[usp_VerifyRunnerPrivileges] TO [karch_advanced_admin];
    GRANT EXECUTE ON [arch].[usp_CaptureRunnerPrivilegeInventory] TO [karch_advanced_admin];
END
GO
PRINT '055_runtime_runner_role_and_verify deployed (role karch_runtime, arch.usp_VerifyRunnerPrivileges, arch.usp_CaptureRunnerPrivilegeInventory, arch.RunnerPrivilegeInventory).';
GO
-- <<< end: kArchiveManagerAdmin\v2\055_runtime_runner_role_and_verify.sql
GO
GO
-- T-21: retention floor + legal-hold (gate proc + register; runners 014/015/027 enforce it).
-- >>> inlined: kArchiveManagerAdmin\v2\056_retention_floor_and_legal_hold.sql
USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
/* ============================================================================
   056 — T-21: retention floor (minimum-retention policy) + legal-hold
   ----------------------------------------------------------------------------
   PROBLEM: the cutoff is DATEADD(DAY, -RetentionDays, now) with no lower bound, and there is no
   per-key exclusion. A single mis-set RetentionDays / CutoffDate (auto-published, T-06) could delete
   data inside a mandatory retention window, and there is no way to pin specific documents (e.g. under
   audit / litigation) so they are never archived+deleted. (T-21, completeness HIGH.)

   FIX — two complementary controls, both enforced at REAL deletes (DryRun exempt), like the TZ gate:
     (1) RETENTION FLOOR — arch.RetentionPolicy.MinRetentionDays. arch.usp_AssertRetentionFloor THROWs
         50210 when the effective cutoff is MORE RECENT than (now - MinRetentionDays), i.e. the run
         would delete rows younger than the floor. Covers BOTH RetentionDays- and CutoffDate-derived
         cutoffs (it checks the final cutoff value). Floor 0 = disabled (default; the customer sets it).
         Called by both runners (027 with @CutoffUtc, 015 with WorkBatch.RangeToUtc) at @DryRun=0.
     (2) LEGAL-HOLD — arch.LegalHold rows (ProcessCode [+ optional SourceDb] + HoldKey = the process's
         primary candidate key, i.e. Key1). Active holds are EXCLUDED from the candidate set at build
         time in both runners, so held keys are never archived+deleted. Add/release is a karch_approver
         (compliance) action and is auditable; holds take effect at the next candidate build.

   This script ships in the clean bundle (Phase 13c, after the karch_* roles). Idempotent.
   ============================================================================ */

/* ---- 1) retention policy (single row) -------------------------------------- */
IF OBJECT_ID(N'arch.RetentionPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[RetentionPolicy]
    (
        PolicyId        tinyint NOT NULL CONSTRAINT [PK_RetentionPolicy] PRIMARY KEY
                                         CONSTRAINT [CK_RetentionPolicy_Singleton] CHECK (PolicyId = 1),
        MinRetentionDays int NOT NULL CONSTRAINT [DF_RetentionPolicy_Min] DEFAULT (0),  -- 0 = floor disabled
        ModifiedAtUtc   datetime2(0) NOT NULL CONSTRAINT [DF_RetentionPolicy_At] DEFAULT (SYSUTCDATETIME()),
        ModifiedBy      sysname NULL,
        CONSTRAINT [CK_RetentionPolicy_NonNeg] CHECK (MinRetentionDays >= 0)
    );
END
GO
IF NOT EXISTS (SELECT 1 FROM arch.RetentionPolicy WHERE PolicyId = 1)
    INSERT arch.RetentionPolicy(PolicyId, MinRetentionDays, ModifiedBy) VALUES (1, 0, SUSER_SNAME());
GO

/* ---- 2) legal-hold register ------------------------------------------------ */
IF OBJECT_ID(N'arch.LegalHold', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[LegalHold]
    (
        LegalHoldId   bigint IDENTITY(1,1) NOT NULL CONSTRAINT [PK_LegalHold] PRIMARY KEY,
        ProcessCode   sysname NOT NULL,
        SourceDb      sysname NULL,                 -- NULL = applies to every source DB for the process
        HoldKey       nvarchar(256) NOT NULL,       -- the process's primary candidate key (Key1) value
        Reason        nvarchar(400) NOT NULL,
        CreatedBy     sysname NOT NULL CONSTRAINT [DF_LegalHold_By] DEFAULT (SUSER_SNAME()),
        CreatedAtUtc  datetime2(0) NOT NULL CONSTRAINT [DF_LegalHold_At] DEFAULT (SYSUTCDATETIME()),
        ReleasedAtUtc datetime2(0) NULL,
        ReleasedBy    sysname NULL
    );
    -- fast active-hold lookup used by the candidate-exclusion in the runners
    CREATE NONCLUSTERED INDEX [IX_LegalHold_Active]
        ON [arch].[LegalHold] (ProcessCode, SourceDb, HoldKey) INCLUDE (ReleasedAtUtc)
        WHERE ReleasedAtUtc IS NULL;
END
GO

/* widen the WorkBatchKey status domain to admit Status=5 = 'parked: under legal hold' (015 sets it when
   a hold is added AFTER prepare, so the key is neither deleted nor re-claimed nor marked done). Idempotent. */
IF OBJECT_ID(N'arch.WorkBatchKey', N'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = N'CK_WorkBatchKey_Status' AND parent_object_id = OBJECT_ID(N'arch.WorkBatchKey'))
        ALTER TABLE [arch].[WorkBatchKey] DROP CONSTRAINT [CK_WorkBatchKey_Status];
    ALTER TABLE [arch].[WorkBatchKey] WITH NOCHECK
        ADD CONSTRAINT [CK_WorkBatchKey_Status] CHECK ([Status] >= 0 AND [Status] <= 5);  -- 0 unclaimed,1 claimed,2 done,3 error,5 legal-hold
END
GO

/* ---- 3) retention-floor gate (called by the runners at real deletes) ------- */
CREATE OR ALTER PROCEDURE [arch].[usp_AssertRetentionFloor]
    @ProcessId  int = NULL,         -- context only (the floor is global)
    @SourceDb   sysname = NULL,
    @ArchiveDb  sysname = NULL,
    @CutoffUtc  datetime2(0)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @floor int = COALESCE((SELECT TOP (1) MinRetentionDays FROM arch.RetentionPolicy WHERE PolicyId = 1), 0);
    IF @floor <= 0 RETURN;   -- no floor configured -> no-op (backward compatible)

    -- fail closed: a NULL cutoff must never silently pass the floor (UNKNOWN comparison)
    IF @CutoffUtc IS NULL
        THROW 50211, 'usp_AssertRetentionFloor called with NULL @CutoffUtc (cannot evaluate the retention floor).', 1;

    DECLARE @earliest datetime2(0) = DATEADD(DAY, -@floor, CONVERT(datetime2(0), SYSUTCDATETIME()));
    IF @CutoffUtc > @earliest
    BEGIN
        DECLARE @m nvarchar(400) =
            N'Retention floor violation: effective cutoff ' + CONVERT(nvarchar(30), @CutoffUtc)
          + N' is more recent than the policy floor (now - ' + CONVERT(nvarchar(12), @floor) + N' days = '
          + CONVERT(nvarchar(30), @earliest) + N'). Real deletes blocked. Raise RetentionDays/CutoffDate, '
          + N'or lower arch.RetentionPolicy.MinRetentionDays if the floor is wrong.';
        ;THROW 50210, @m, 1;
    END;
END
GO

/* ---- 4) management API (compliance actions; audited via CreatedBy/ReleasedBy) --- */
CREATE OR ALTER PROCEDURE [arch].[usp_Api_SetRetentionFloor]
    @MinRetentionDays int,
    @RequestedBy      nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @MinRetentionDays < 0 THROW 50212, 'MinRetentionDays must be >= 0.', 1;
    UPDATE arch.RetentionPolicy
    SET MinRetentionDays = @MinRetentionDays,
        ModifiedAtUtc = SYSUTCDATETIME(),
        ModifiedBy = COALESCE(@RequestedBy, SUSER_SNAME())
    WHERE PolicyId = 1;
    IF @@ROWCOUNT = 0
        INSERT arch.RetentionPolicy(PolicyId, MinRetentionDays, ModifiedBy)
        VALUES (1, @MinRetentionDays, COALESCE(@RequestedBy, SUSER_SNAME()));
    SELECT MinRetentionDays, ModifiedAtUtc, ModifiedBy FROM arch.RetentionPolicy WHERE PolicyId = 1;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_AddLegalHold]
    @ProcessCode sysname,
    @HoldKey     nvarchar(256),
    @Reason      nvarchar(400),
    @SourceDb    sysname = NULL,
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(RTRIM(@ProcessCode)), N'') IS NULL THROW 50213, '@ProcessCode is required.', 1;
    IF NULLIF(LTRIM(RTRIM(@HoldKey)), N'') IS NULL     THROW 50214, '@HoldKey is required.', 1;
    IF NULLIF(LTRIM(RTRIM(@Reason)), N'') IS NULL OR LEN(LTRIM(RTRIM(@Reason))) < 6
        THROW 50215, '@Reason is required (>= 6 chars) for the audit trail.', 1;

    IF EXISTS (SELECT 1 FROM arch.LegalHold
               WHERE ProcessCode = @ProcessCode AND HoldKey = @HoldKey
                 AND ISNULL(SourceDb, N'') = ISNULL(@SourceDb, N'') AND ReleasedAtUtc IS NULL)
    BEGIN
        SELECT LegalHoldId, ProcessCode, SourceDb, HoldKey, Reason, CreatedBy, CreatedAtUtc, Note = N'already active'
        FROM arch.LegalHold
        WHERE ProcessCode = @ProcessCode AND HoldKey = @HoldKey
          AND ISNULL(SourceDb, N'') = ISNULL(@SourceDb, N'') AND ReleasedAtUtc IS NULL;
        RETURN;
    END;

    INSERT arch.LegalHold(ProcessCode, SourceDb, HoldKey, Reason, CreatedBy)
    VALUES (@ProcessCode, @SourceDb, @HoldKey, LTRIM(RTRIM(@Reason)), COALESCE(@RequestedBy, SUSER_SNAME()));

    -- A hold is keyed on Key1 (the primary candidate key). For composite-key processes (ProcessKeySpec
    -- KeyOrdinal>1, e.g. Key1+Key2) the hold drops EVERY candidate sharing this Key1 — safe (never
    -- under-excludes) but over-inclusive. Surface that so the operator understands the granularity.
    DECLARE @note nvarchar(200) = N'';
    IF EXISTS (SELECT 1 FROM arch.ProcessKeySpec pks JOIN arch.Process p ON p.ProcessId = pks.ProcessId
               WHERE p.ProcessCode = @ProcessCode AND pks.KeyOrdinal > 1)
        SET @note = N'NOTE: composite-key process — this hold applies to ALL rows sharing Key1 (Key2.. is not distinguished).';

    SELECT LegalHoldId, ProcessCode, SourceDb, HoldKey, Reason, CreatedBy, CreatedAtUtc, Note = @note
    FROM arch.LegalHold WHERE LegalHoldId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_ReleaseLegalHold]
    @LegalHoldId bigint,
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE arch.LegalHold
    SET ReleasedAtUtc = SYSUTCDATETIME(), ReleasedBy = COALESCE(@RequestedBy, SUSER_SNAME())
    WHERE LegalHoldId = @LegalHoldId AND ReleasedAtUtc IS NULL;
    IF @@ROWCOUNT = 0 THROW 50216, 'Legal hold not found or already released.', 1;
    SELECT LegalHoldId, ProcessCode, SourceDb, HoldKey, ReleasedAtUtc, ReleasedBy
    FROM arch.LegalHold WHERE LegalHoldId = @LegalHoldId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetLegalHolds]
    @ProcessCode sysname = NULL,
    @ActiveOnly  bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT LegalHoldId, ProcessCode, SourceDb, HoldKey, Reason, CreatedBy, CreatedAtUtc, ReleasedAtUtc, ReleasedBy
    FROM arch.LegalHold
    WHERE (@ProcessCode IS NULL OR ProcessCode = @ProcessCode)
      AND (@ActiveOnly = 0 OR ReleasedAtUtc IS NULL)
    ORDER BY CASE WHEN ReleasedAtUtc IS NULL THEN 0 ELSE 1 END, ProcessCode, SourceDb, HoldKey;
END
GO

/* ---- 5) grants ------------------------------------------------------------- */
IF DATABASE_PRINCIPAL_ID(N'karch_runtime') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_AssertRetentionFloor] TO [karch_runtime];
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_AssertRetentionFloor] TO [karch_advanced_admin];  -- out-of-band what-if checks
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GetLegalHolds] TO [karch_viewer];
IF DATABASE_PRINCIPAL_ID(N'karch_operator') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GetLegalHolds] TO [karch_operator];
IF DATABASE_PRINCIPAL_ID(N'karch_approver') IS NOT NULL
BEGIN
    GRANT EXECUTE ON [arch].[usp_Api_SetRetentionFloor] TO [karch_approver];
    GRANT EXECUTE ON [arch].[usp_Api_AddLegalHold]     TO [karch_approver];
    GRANT EXECUTE ON [arch].[usp_Api_ReleaseLegalHold] TO [karch_approver];
    GRANT EXECUTE ON [arch].[usp_Frontend_GetLegalHolds] TO [karch_approver];
END
GO
PRINT '056_retention_floor_and_legal_hold deployed (arch.RetentionPolicy, arch.LegalHold, usp_AssertRetentionFloor + management API).';
GO
-- <<< end: kArchiveManagerAdmin\v2\056_retention_floor_and_legal_hold.sql
GO
GO
-- Mode=2 copy-only (idempotent backup, no delete): Mode CHECK widen + dedup helper (runners 015/027 honor it).
-- >>> inlined: kArchiveManagerAdmin\v2\057_copy_only_mode.sql
USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
/* ============================================================================
   057 — Mode=2: COPY-ONLY (idempotent backup, no delete)
   ----------------------------------------------------------------------------
   Adds a third processing mode alongside Mode=1 (archive+delete) and Mode=0 (delete-only):

     Mode=2 COPY-ONLY — copy the candidate rows into the archive but NEVER delete from the source,
     inserting only rows that are not already in the archive ("backup if not exists"). It is
     non-destructive and idempotent: a re-run copies only newly-eligible rows. Dedup is by the
     SOURCE PRIMARY KEY (the archive is a column-copy, so the PK columns are present there); a
     non-clustered dedup index is ensured on the archive so the NOT EXISTS stays fast on large sets.

   This script:
     1. widens the Mode CHECK on arch.Process and arch.ProcessDatabase to admit 2 (idempotent);
     2. adds arch.usp_GetCopyDedupInfo — derives the PK NOT-EXISTS predicate for the copy and ensures
        the archive dedup index. Used by the runners (015 / 027) for Mode=2.

   The runners (014/015/027), usp_ValidateConfiguration and usp_GetOutputColumns are updated separately
   to honor Mode=2. A source table WITHOUT a primary key cannot be copied idempotently -> THROW 50220.

   SEMANTICS & LIMITATIONS (Mode=2):
     - RowsArchived (RunItem/RunItemObject) = rows ACTUALLY copied this run; it is the authoritative
       "what was processed" count. DocsDone = candidates considered, and RunDocAudit (ROW audit only)
       records Archived=1 for each candidate confirmed in the archive. On an idempotent re-run the
       NOT EXISTS copies 0 rows (RowsArchived=0) while DocsDone reflects the rescanned candidates — so
       read RowsArchived, not DocsDone, to see how much was newly backed up.
     - The dedup index is NON-unique on purpose: an archive shared with Mode=1 history can legitimately
       hold more than one row per source PK (a key deleted, recreated, deleted again). Dedup is enforced
       by the per-statement NOT EXISTS; same-object copy runs are already serialized (TIMESTAMP applock /
       single open ANCHOR WorkBatch), so concurrent duplicate inserts do not occur in normal operation.
     - Collation: the archive PK columns must share the source collation for the a.[pk]=t.[pk] dedup.
       That holds for archives provisioned by usp_EnsureArchiveTableLikeSource (it copies source collation),
       which Mode=2 always runs first.
   ============================================================================ */

/* ---- 1) widen the Mode domain to {0,1,2} ---------------------------------- */
IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Process_Mode' AND parent_object_id = OBJECT_ID(N'arch.Process'))
        ALTER TABLE [arch].[Process] DROP CONSTRAINT [CK_Process_Mode];
    ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_Mode] CHECK ([Mode] IN (0, 1, 2));  -- 0 delete-only, 1 archive+delete, 2 copy-only
END
GO
IF OBJECT_ID(N'arch.ProcessDatabase', N'U') IS NOT NULL
BEGIN
    -- The Mode domain on arch.ProcessDatabase is NOT a standalone constraint — it is ONE clause inside the
    -- composite CK_ProcessDatabase_OverrideLimits. Drop it BY EXACT NAME and recreate it IN FULL with every
    -- other override validation preserved verbatim and only the Mode clause widened to {0,1,2}.
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ProcessDatabase_OverrideLimits' AND parent_object_id = OBJECT_ID(N'arch.ProcessDatabase'))
        ALTER TABLE [arch].[ProcessDatabase] DROP CONSTRAINT [CK_ProcessDatabase_OverrideLimits];
    ALTER TABLE [arch].[ProcessDatabase] WITH CHECK ADD CONSTRAINT [CK_ProcessDatabase_OverrideLimits] CHECK
    (
        ([Mode] IS NULL OR [Mode] IN (0, 1, 2))
        AND ([RetentionDays] IS NULL OR [RetentionDays] >= 0)
        AND ([CutoffSafetyLagMinutes] IS NULL OR [CutoffSafetyLagMinutes] >= 0)
        AND ([CutoffMode] IS NULL OR [CutoffMode] IN (0, 1))
        AND ([BatchDocCount] IS NULL OR [BatchDocCount] > 0)
        AND ([BatchRowCount] IS NULL OR [BatchRowCount] > 0)
        AND ([MaxBatchesPerRun] IS NULL OR [MaxBatchesPerRun] > 0)
        AND ([DelayMsBetweenBatches] IS NULL OR [DelayMsBetweenBatches] >= 0)
        AND ([LockTimeoutMs] IS NULL OR [LockTimeoutMs] >= 0)
        AND ([DeadlockPriority] IS NULL OR [DeadlockPriority] IN (N'LOW', N'NORMAL', N'HIGH'))
        AND ([AuditLevel] IS NULL OR [AuditLevel] IN (N'NONE', N'BATCH', N'OBJECT', N'ROW'))
        AND ([MaxRowsPerTransaction] IS NULL OR [MaxRowsPerTransaction] > 0)
    );
END
GO

/* ---- 2) copy-only dedup helper -------------------------------------------- */
CREATE OR ALTER PROCEDURE [arch].[usp_GetCopyDedupInfo]
    @SourceDb      sysname,
    @SourceSchema  sysname,
    @SourceTable   sysname,
    @ArchiveDb     sysname,
    @ArchiveSchema sysname,
    @ArchiveTable  sysname,
    @SourceAlias   sysname = N't',
    @ArchiveAlias  sysname = N'a',
    @EnsureIndex   bit = 1,
    @PkPredicate   nvarchar(max) OUTPUT     -- 'a.[c1] = t.[c1] AND a.[c2] = t.[c2]' (archiveAlias.col = sourceAlias.col)
AS
BEGIN
    SET NOCOUNT ON;
    SET @PkPredicate = NULL;

    DECLARE @srcFq nvarchar(512) = QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@SourceSchema) + N'.' + QUOTENAME(@SourceTable);
    DECLARE @pkCsv nvarchar(max) = NULL, @pred nvarchar(max) = NULL;

    -- source PRIMARY KEY columns: the dedup identity (present in the archive, which is a column-copy)
    DECLARE @q nvarchar(max) = N'
        SELECT @cols = STUFF((SELECT N'','' + QUOTENAME(c.name)
                              FROM ' + QUOTENAME(@SourceDb) + N'.sys.index_columns ic
                              JOIN ' + QUOTENAME(@SourceDb) + N'.sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                              WHERE ic.object_id = OBJECT_ID(@fq) AND ic.index_id = @pkid
                              ORDER BY ic.key_ordinal FOR XML PATH(''''), TYPE).value(''.'',''nvarchar(max)''), 1, 1, N''''),
               @pp   = STUFF((SELECT N'' AND '' + @aa + N''.'' + QUOTENAME(c.name) + N'' = '' + @sla + N''.'' + QUOTENAME(c.name)
                              FROM ' + QUOTENAME(@SourceDb) + N'.sys.index_columns ic
                              JOIN ' + QUOTENAME(@SourceDb) + N'.sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                              WHERE ic.object_id = OBJECT_ID(@fq) AND ic.index_id = @pkid
                              ORDER BY ic.key_ordinal FOR XML PATH(''''), TYPE).value(''.'',''nvarchar(max)''), 1, 5, N'''')
        FROM (SELECT 1 x) z;';

    -- find the PK index_id first (separate so the OBJECT_ID/index lookup is in the source DB)
    DECLARE @pkid int;
    DECLARE @qid nvarchar(max) = N'SELECT @id = index_id FROM ' + QUOTENAME(@SourceDb) + N'.sys.indexes WHERE object_id = OBJECT_ID(@fq) AND is_primary_key = 1;';
    EXEC sys.sp_executesql @qid, N'@fq nvarchar(512), @id int OUTPUT', @fq = @srcFq, @id = @pkid OUTPUT;

    IF @pkid IS NULL
        THROW 50220, 'Copy-only (Mode=2) requires a PRIMARY KEY on the source table for idempotent dedup; none was found.', 1;

    EXEC sys.sp_executesql @q,
         N'@fq nvarchar(512), @pkid int, @aa sysname, @sla sysname, @cols nvarchar(max) OUTPUT, @pp nvarchar(max) OUTPUT',
         @fq = @srcFq, @pkid = @pkid, @aa = @ArchiveAlias, @sla = @SourceAlias, @cols = @pkCsv OUTPUT, @pp = @pred OUTPUT;

    IF NULLIF(@pred, N'') IS NULL
        THROW 50221, 'Copy-only (Mode=2): could not derive the source primary-key dedup predicate.', 1;

    SET @PkPredicate = @pred;

    -- ensure a dedup index on the archive (same PK columns) so the per-batch NOT EXISTS stays fast
    IF @EnsureIndex = 1 AND NULLIF(@pkCsv, N'') IS NOT NULL
    BEGIN
        DECLARE @ixName sysname = N'IX_kAMCopyDedup';
        DECLARE @aSchObj nvarchar(512) = QUOTENAME(@ArchiveSchema) + N'.' + QUOTENAME(@ArchiveTable);
        DECLARE @ix nvarchar(max) = N'USE ' + QUOTENAME(@ArchiveDb) + N';
            IF OBJECT_ID(@aobj) IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = @ixn AND object_id = OBJECT_ID(@aobj))
                CREATE NONCLUSTERED INDEX ' + QUOTENAME(@ixName) + N' ON ' + @aSchObj + N' (' + @pkCsv + N');';
        BEGIN TRY
            EXEC sys.sp_executesql @ix, N'@aobj nvarchar(512), @ixn sysname', @aobj = @aSchObj, @ixn = @ixName;
        END TRY
        BEGIN CATCH
            -- non-fatal: the copy still works without the index (just slower); surface as info, do not block.
            PRINT 'usp_GetCopyDedupInfo: could not ensure archive dedup index on ' + @aSchObj + ' (' + ERROR_MESSAGE() + ').';
        END CATCH
    END
END
GO
IF DATABASE_PRINCIPAL_ID(N'karch_runtime') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_GetCopyDedupInfo] TO [karch_runtime];
GO
PRINT '057_copy_only_mode deployed (Mode IN {0,1,2}; arch.usp_GetCopyDedupInfo).';
GO
-- <<< end: kArchiveManagerAdmin\v2\057_copy_only_mode.sql
GO
GO

-- ---- Phase 14: SQL Agent jobs (RUN CONFIGURED ships DISABLED; RECOVER STALE RUNS enabled) ----
-- >>> inlined: kArchiveManagerAdmin\v2\036_install_recover_stale_runs_job.sql
USE [msdb]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/**
 * ============================================================================
 * 036_install_recover_stale_runs_job.sql
 * ============================================================================
 *
 * Purpose:
 *   Install (and ENABLE) a SQL Agent job that runs arch.usp_RecoverStaleRuns
 *   every 15 minutes. The procedure (v2/030) detects Run/RunItem/WorkBatch
 *   records stuck in RUNNING after a disconnect/restart and recovers them
 *   (infer OK when archived=deleted, otherwise mark FAILED / pause for resume).
 *
 * Why this matters:
 *   The recovery procedure has been deployed since 2026-05-28 but nothing was
 *   scheduling it — so it provided no protection. Once real deletes are enabled
 *   (after the P0.5 timezone gate), an interrupted run would otherwise sit in
 *   RUNNING limbo indefinitely. This job closes that gap.
 *
 * Behavior:
 *   - Idempotent: creates the job/step/schedule if missing, updates them if present.
 *   - Job is created ENABLED with an enabled 15-minute schedule (a disabled
 *     recovery job protects nothing). Disable via SSMS or
 *     EXEC msdb.dbo.sp_update_job @job_name = N'kArchiveManager - RECOVER STALE RUNS', @enabled = 0;
 *   - Step runs EXEC arch.usp_RecoverStaleRuns @DryRun = 0 (applies recovery).
 *
 * Scope:
 *   Environment-specific operational script (like 028/031/033/034). NOT part of
 *   the regenerated deploy bundle — SQL Agent jobs are server-local.
 *
 * Created: 2026-05-29
 * Related: v2/030_usp_RecoverStaleRuns.sql, v2/028_replace_legacy_jobs.sql
 * ============================================================================
 */

DECLARE
    @jobId uniqueidentifier,
    @stepId int,
    @recoverCommand nvarchar(max);

SET @recoverCommand = N'
EXEC arch.usp_RecoverStaleRuns
     @StaleAfterMinutes = 30,
     @DryRun = 0,
     @VerboseOutput = 0;';

SELECT @jobId = job_id
FROM msdb.dbo.sysjobs
WHERE name = N'kArchiveManager - RECOVER STALE RUNS';

IF @jobId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name = N'kArchiveManager - RECOVER STALE RUNS',
        @enabled = 1,
        @description = N'Recovers Run/RunItem/WorkBatch records stuck in RUNNING (arch.usp_RecoverStaleRuns). Runs every 15 minutes.',
        @category_name = N'Database Maintenance',
        @job_id = @jobId OUTPUT;
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_job
        @job_id = @jobId,
        @enabled = 1,
        @description = N'Recovers Run/RunItem/WorkBatch records stuck in RUNNING (arch.usp_RecoverStaleRuns). Runs every 15 minutes.';
END;

-- Step: run the recovery procedure
SELECT @stepId = step_id
FROM msdb.dbo.sysjobsteps
WHERE job_id = @jobId
  AND step_name = N'RECOVER STALE RUNS';

IF @stepId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @jobId,
        @step_name = N'RECOVER STALE RUNS',
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @recoverCommand,
        @on_success_action = 1,   -- quit reporting success
        @on_fail_action = 2;      -- quit reporting failure
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_jobstep
        @job_id = @jobId,
        @step_id = @stepId,
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @recoverCommand,
        @on_success_action = 1,
        @on_fail_action = 2;
END;

-- Schedule: every 15 minutes, all day, every day
IF NOT EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobschedules js
    JOIN msdb.dbo.sysschedules s
      ON s.schedule_id = js.schedule_id
    WHERE js.job_id = @jobId
      AND s.name = N'Every 15 minutes'
)
BEGIN
    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @jobId,
        @name = N'Every 15 minutes',
        @enabled = 1,
        @freq_type = 4,              -- daily
        @freq_interval = 1,          -- every 1 day
        @freq_subday_type = 4,       -- minutes
        @freq_subday_interval = 15,  -- every 15 minutes
        @active_start_time = 000000; -- from midnight
END;

IF NOT EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobservers
    WHERE job_id = @jobId
)
BEGIN
    EXEC msdb.dbo.sp_add_jobserver
        @job_id = @jobId,
        @server_name = N'(LOCAL)';
END;

PRINT N'kArchiveManager - RECOVER STALE RUNS job installed and enabled (every 15 minutes).';
GO
-- <<< end: kArchiveManagerAdmin\v2\036_install_recover_stale_runs_job.sql
GO
GO
-- >>> inlined: kArchiveManagerAdmin\v2\SQL job - RUN CONFIGURED.sql
USE [msdb]
GO

DECLARE
    @jobId uniqueidentifier,
    @stepId int,
    @validateCommand nvarchar(max),
    @runCommand nvarchar(max);

SET @validateCommand = N'
DECLARE @rc int;
EXEC @rc = arch.usp_ValidateConfiguration;
IF @rc <> 0
    THROW 51000, ''kArchiveManager validation failed. See result set from arch.usp_ValidateConfiguration.'', 1;

-- T-33 runtime least-privilege gate. This step runs in the JOB OWNER context (the dedicated
-- non-sysadmin runner login after deploy/v2/054), so usp_VerifyRunnerPrivileges'' HAS_PERMS_BY_NAME /
-- IS_SRVROLEMEMBER checks evaluate the RUNNER''s own effective rights. RETURN 1 => THROW => the run is
-- blocked before any delete. Guarded so older installs without the proc still validate.
IF OBJECT_ID(N''arch.usp_VerifyRunnerPrivileges'', N''P'') IS NOT NULL
BEGIN
    DECLARE @rp int;
    EXEC @rp = arch.usp_VerifyRunnerPrivileges;
    IF @rp <> 0
        THROW 51001, ''kArchiveManager runner privilege gate failed. See result set from arch.usp_VerifyRunnerPrivileges; fix each ERROR row''''s SuggestedSql (or re-run deploy/v2/053), then retry.'', 1;
END;';

SET @runCommand = N'
EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N''JOB_DEFAULT'';';

SELECT @jobId = job_id
FROM msdb.dbo.sysjobs
WHERE name = N'kArchiveManager - RUN CONFIGURED';

IF @jobId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name = N'kArchiveManager - RUN CONFIGURED',
        @enabled = 0,
        @description = N'Runs kArchiveManager using Admin DB run profile JOB_DEFAULT.',
        @category_name = N'Database Maintenance',
        @job_id = @jobId OUTPUT;
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_job
        @job_id = @jobId,
        @description = N'Runs kArchiveManager using Admin DB run profile JOB_DEFAULT.';
END;

SELECT @stepId = step_id
FROM msdb.dbo.sysjobsteps
WHERE job_id = @jobId
  AND step_name = N'VALIDATE CONFIGURATION';

IF @stepId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @jobId,
        @step_name = N'VALIDATE CONFIGURATION',
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @validateCommand,
        @on_success_action = 3,
        @on_fail_action = 2;
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_jobstep
        @job_id = @jobId,
        @step_id = @stepId,
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @validateCommand,
        @on_success_action = 3,
        @on_fail_action = 2;
END;

SET @stepId = NULL;

SELECT @stepId = step_id
FROM msdb.dbo.sysjobsteps
WHERE job_id = @jobId
  AND step_name = N'RUN CONFIGURED PROCESSES';

IF @stepId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @jobId,
        @step_name = N'RUN CONFIGURED PROCESSES',
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @runCommand,
        @on_success_action = 1,
        @on_fail_action = 2;
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_update_jobstep
        @job_id = @jobId,
        @step_id = @stepId,
        @subsystem = N'TSQL',
        @database_name = N'kArchiveManagerAdmin',
        @command = @runCommand,
        @on_success_action = 1,
        @on_fail_action = 2;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobschedules js
    JOIN msdb.dbo.sysschedules s
      ON s.schedule_id = js.schedule_id
    WHERE js.job_id = @jobId
      AND s.name = N'Hourly disabled template'
)
BEGIN
    EXEC msdb.dbo.sp_add_jobschedule
        @job_id = @jobId,
        @name = N'Hourly disabled template',
        @enabled = 0,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 8,
        @freq_subday_interval = 1,
        @active_start_time = 010000;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobservers
    WHERE job_id = @jobId
)
BEGIN
    EXEC msdb.dbo.sp_add_jobserver
        @job_id = @jobId,
        @server_name = N'(LOCAL)';
END;
GO
-- <<< end: kArchiveManagerAdmin\v2\SQL job - RUN CONFIGURED.sql
GO
GO
-- PREP job (two-phase front-load, ships DISABLED) + Console job-control API (usp_Api_*AgentJob*).
-- The msdb privilege grant for the console login is the parameterized add-on deploy\v2\059.
-- >>> inlined: kArchiveManagerAdmin\v2\058_agent_job_control.sql
/* ============================================================================
   058_agent_job_control.sql — PREP/RUN two-phase Agent job + Console job-control API.
   ----------------------------------------------------------------------------
   1) Creates the PREP job 'kArchiveManager - PREP CONFIGURED' (front-loads ANCHOR candidate
      preparation via run profile JOB_DEFAULT with @Phase='PREP'). Ships DISABLED, like the RUN job.
      The existing 'kArchiveManager - RUN CONFIGURED' job stays @Phase=BOTH (the safety net: it runs
      prepared batches AND prepares anything the PREP job didn't get to + runs TIMESTAMP processes).
   2) Installs the Console job-control API (arch.usp_Api_GetAgentJobs / usp_Api_SetAgentJobEnabled /
      usp_Api_SetAgentJobSchedule), WHITELISTED to the two kAM jobs only. These run in the CALLER
      context, so the connecting Admin Console login must have msdb SQLAgentUserRole + own the jobs
      (deploy/v2/059_console_job_control_grants.sql). THROW 50118 = job not in the kAM whitelist.
   Idempotent. SQL Agent required for the job half (the proc half installs regardless).
   ============================================================================ */
USE [msdb];
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'msdb' AND state_desc = 'ONLINE')
   AND OBJECT_ID(N'msdb.dbo.sp_add_job', N'P') IS NOT NULL
BEGIN
    DECLARE @jobId uniqueidentifier, @stepId int,
            @validateCommand nvarchar(max), @prepCommand nvarchar(max);

    SET @validateCommand = N'
DECLARE @rc int;
EXEC @rc = arch.usp_ValidateConfiguration;
IF @rc <> 0
    THROW 51000, ''kArchiveManager validation failed. See result set from arch.usp_ValidateConfiguration.'', 1;
IF OBJECT_ID(N''arch.usp_VerifyRunnerPrivileges'', N''P'') IS NOT NULL
BEGIN
    DECLARE @rp int;
    EXEC @rp = arch.usp_VerifyRunnerPrivileges;
    IF @rp <> 0
        THROW 51001, ''kArchiveManager runner privilege gate failed. See arch.usp_VerifyRunnerPrivileges.'', 1;
END;';

    -- PREP phase only: build ANCHOR WorkBatches; TIMESTAMP is single-phase and is a no-op here.
    SET @prepCommand = N'
EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N''JOB_DEFAULT'', @Phase = N''PREP'';';

    SELECT @jobId = job_id FROM msdb.dbo.sysjobs WHERE name = N'kArchiveManager - PREP CONFIGURED';

    IF @jobId IS NULL
        EXEC msdb.dbo.sp_add_job
            @job_name = N'kArchiveManager - PREP CONFIGURED',
            @enabled = 0,
            @description = N'Prepares kArchiveManager ANCHOR candidates (run profile JOB_DEFAULT, @Phase=PREP). Front-loads the candidate scan so the RUN job only deletes.',
            @category_name = N'Database Maintenance',
            @job_id = @jobId OUTPUT;
    ELSE
        EXEC msdb.dbo.sp_update_job @job_id = @jobId,
            @description = N'Prepares kArchiveManager ANCHOR candidates (run profile JOB_DEFAULT, @Phase=PREP). Front-loads the candidate scan so the RUN job only deletes.';

    SELECT @stepId = step_id FROM msdb.dbo.sysjobsteps WHERE job_id = @jobId AND step_name = N'VALIDATE CONFIGURATION';
    IF @stepId IS NULL
        EXEC msdb.dbo.sp_add_jobstep @job_id = @jobId, @step_name = N'VALIDATE CONFIGURATION',
            @subsystem = N'TSQL', @database_name = N'kArchiveManagerAdmin',
            @command = @validateCommand, @on_success_action = 3, @on_fail_action = 2;
    ELSE
        EXEC msdb.dbo.sp_update_jobstep @job_id = @jobId, @step_id = @stepId,
            @subsystem = N'TSQL', @database_name = N'kArchiveManagerAdmin',
            @command = @validateCommand, @on_success_action = 3, @on_fail_action = 2;

    SET @stepId = NULL;
    SELECT @stepId = step_id FROM msdb.dbo.sysjobsteps WHERE job_id = @jobId AND step_name = N'PREPARE CONFIGURED PROCESSES';
    IF @stepId IS NULL
        EXEC msdb.dbo.sp_add_jobstep @job_id = @jobId, @step_name = N'PREPARE CONFIGURED PROCESSES',
            @subsystem = N'TSQL', @database_name = N'kArchiveManagerAdmin',
            @command = @prepCommand, @on_success_action = 1, @on_fail_action = 2;
    ELSE
        EXEC msdb.dbo.sp_update_jobstep @job_id = @jobId, @step_id = @stepId,
            @subsystem = N'TSQL', @database_name = N'kArchiveManagerAdmin',
            @command = @prepCommand, @on_success_action = 1, @on_fail_action = 2;

    -- Disabled daily template (operator enables + reschedules from the Console).
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id
                   WHERE js.job_id = @jobId)
        EXEC msdb.dbo.sp_add_jobschedule @job_id = @jobId, @name = N'kArchiveManager - PREP daily (disabled template)',
            @enabled = 0, @freq_type = 4, @freq_interval = 1, @freq_subday_type = 1, @active_start_time = 003000;

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobservers WHERE job_id = @jobId)
        EXEC msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(LOCAL)';

    PRINT 'PREP CONFIGURED job ensured (disabled).';
END
ELSE
    PRINT 'SQL Agent / msdb not available — skipped PREP job creation (proc half still installs).';
GO

USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- The kAM jobs the Console may control. Any other job name is rejected (50118).
-- A scalar helper keeps the whitelist in one place.
CREATE OR ALTER FUNCTION arch.fn_IsControllableAgentJob(@JobName sysname)
RETURNS bit
AS
BEGIN
    RETURN CASE WHEN @JobName IN (N'kArchiveManager - PREP CONFIGURED', N'kArchiveManager - RUN CONFIGURED')
                THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END;
END
GO

/* Read the state of the two controllable kAM jobs (enabled + schedule + last/next run). Caller needs
   msdb access to its own jobs (SQLAgentUserRole). Returns one row per job (or none if Agent absent). */
CREATE OR ALTER PROCEDURE arch.usp_Api_GetAgentJobs
AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID(N'msdb.dbo.sysjobs', N'V') IS NULL AND OBJECT_ID(N'msdb.dbo.sysjobs', N'U') IS NULL
    BEGIN
        SELECT TOP (0) JobName = CONVERT(sysname, NULL); RETURN;
    END;

    SELECT
        JobName          = j.name,
        Phase            = CASE WHEN j.name LIKE N'%PREP%' THEN N'PREP' ELSE N'RUN' END,
        JobEnabled       = CONVERT(bit, j.enabled),
        Description      = j.description,
        ScheduleName     = sch.name,
        ScheduleEnabled  = CONVERT(bit, ISNULL(sch.enabled, 0)),
        FreqType         = sch.freq_type,            -- 1=once 4=daily 8=weekly 16=monthly
        FreqInterval     = sch.freq_interval,
        FreqSubdayType   = sch.freq_subday_type,     -- 1=at time 4=minutes 8=hours
        FreqSubdayInterval = sch.freq_subday_interval,
        ActiveStartTime  = sch.active_start_time,    -- HHMMSS int
        ActiveStartDate  = sch.active_start_date,    -- YYYYMMDD int
        NextRunDate      = act.next_scheduled_run_date,
        LastRunOutcome   = CASE h.run_status WHEN 0 THEN N'Failed' WHEN 1 THEN N'Succeeded'
                              WHEN 2 THEN N'Retry' WHEN 3 THEN N'Canceled' WHEN 4 THEN N'In progress' ELSE NULL END,
        LastRunDate      = h.run_date,
        LastRunTime      = h.run_time
    FROM msdb.dbo.sysjobs j
    LEFT JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
    LEFT JOIN msdb.dbo.sysschedules sch    ON sch.schedule_id = js.schedule_id
    OUTER APPLY (SELECT TOP (1) a.next_scheduled_run_date FROM msdb.dbo.sysjobactivity a
                 WHERE a.job_id = j.job_id ORDER BY a.session_id DESC) act
    OUTER APPLY (SELECT TOP (1) hh.run_status, hh.run_date, hh.run_time FROM msdb.dbo.sysjobhistory hh
                 WHERE hh.job_id = j.job_id AND hh.step_id = 0 ORDER BY hh.instance_id DESC) h
    WHERE arch.fn_IsControllableAgentJob(j.name) = 1
    ORDER BY j.name;
END
GO

/* Enable/disable a kAM job. Whitelisted; @RequestedBy captured for the caller's audit/log context. */
CREATE OR ALTER PROCEDURE arch.usp_Api_SetAgentJobEnabled
    @JobName sysname,
    @Enabled bit,
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF arch.fn_IsControllableAgentJob(@JobName) = 0
        THROW 50118, 'Job is not a controllable kArchiveManager job.', 1;

    EXEC msdb.dbo.sp_update_job @job_name = @JobName, @enabled = @Enabled;
    EXEC arch.usp_Api_GetAgentJobs;
END
GO

/* Update a kAM job's (single) schedule: frequency, time, start date, enabled. Whitelisted.
   Friendly contract for the Console:
     @FreqType        4=daily (default), 8=weekly, 16=monthly
     @FreqInterval    daily: every N days; weekly: bitmask of days (1=Sun..64=Sat); monthly: day-of-month
     @FreqSubdayType  1=once at @ActiveStartTime (default), 4=every N minutes, 8=every N hours
     @FreqSubdayInterval  N for subday types 4/8
     @ActiveStartTime HHMMSS (e.g. 010000 = 01:00); @ActiveStartDate YYYYMMDD (NULL = today/keep) */
CREATE OR ALTER PROCEDURE arch.usp_Api_SetAgentJobSchedule
    @JobName sysname,
    @FreqType int = 4,
    @FreqInterval int = 1,
    @FreqSubdayType int = 1,
    @FreqSubdayInterval int = 0,
    @ActiveStartTime int = 010000,
    @ActiveStartDate int = NULL,
    @ScheduleEnabled bit = 1,
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF arch.fn_IsControllableAgentJob(@JobName) = 0
        THROW 50118, 'Job is not a controllable kArchiveManager job.', 1;

    IF @FreqType NOT IN (4, 8, 16)
        THROW 50119, 'Unsupported @FreqType (expected 4=daily, 8=weekly, 16=monthly).', 1;
    IF @FreqSubdayType NOT IN (1, 4, 8)
        THROW 50119, 'Unsupported @FreqSubdayType (expected 1=once, 4=minutes, 8=hours).', 1;
    IF @ActiveStartTime < 0 OR @ActiveStartTime > 235959
        THROW 50119, 'Invalid @ActiveStartTime (expected HHMMSS 0..235959).', 1;

    DECLARE @jobId uniqueidentifier, @schedName sysname, @schedId int;
    SELECT @jobId = job_id FROM msdb.dbo.sysjobs WHERE name = @JobName;
    IF @jobId IS NULL
        THROW 50120, 'Job not found.', 1;

    SELECT TOP (1) @schedId = sch.schedule_id, @schedName = sch.name
    FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules sch ON sch.schedule_id = js.schedule_id
    WHERE js.job_id = @jobId
    ORDER BY sch.schedule_id;

    IF @schedName IS NULL
    BEGIN
        -- No schedule yet — create one.
        EXEC msdb.dbo.sp_add_jobschedule @job_id = @jobId, @name = N'kArchiveManager schedule',
            @enabled = @ScheduleEnabled, @freq_type = @FreqType, @freq_interval = @FreqInterval,
            @freq_subday_type = @FreqSubdayType, @freq_subday_interval = @FreqSubdayInterval,
            @active_start_time = @ActiveStartTime,
            @active_start_date = @ActiveStartDate;
    END
    ELSE
    BEGIN
        EXEC msdb.dbo.sp_update_schedule @name = @schedName, @enabled = @ScheduleEnabled,
            @freq_type = @FreqType, @freq_interval = @FreqInterval,
            @freq_subday_type = @FreqSubdayType, @freq_subday_interval = @FreqSubdayInterval,
            @active_start_time = @ActiveStartTime,
            @active_start_date = @ActiveStartDate;
    END;

    EXEC arch.usp_Api_GetAgentJobs;
END
GO

-- Grants: config_admin + advanced_admin may read/operate the job controls (guarded).
IF DATABASE_PRINCIPAL_ID(N'karch_config_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON arch.usp_Api_GetAgentJobs TO karch_config_admin;
    GRANT EXECUTE ON arch.usp_Api_SetAgentJobEnabled TO karch_config_admin;
    GRANT EXECUTE ON arch.usp_Api_SetAgentJobSchedule TO karch_config_admin;
END;
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON arch.usp_Api_GetAgentJobs TO karch_advanced_admin;
    GRANT EXECUTE ON arch.usp_Api_SetAgentJobEnabled TO karch_advanced_admin;
    GRANT EXECUTE ON arch.usp_Api_SetAgentJobSchedule TO karch_advanced_admin;
END;
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON arch.usp_Api_GetAgentJobs TO karch_viewer;  -- read state is viewer-tier
GO

PRINT 'Agent job-control API installed (usp_Api_GetAgentJobs / SetAgentJobEnabled / SetAgentJobSchedule).';
GO
-- <<< end: kArchiveManagerAdmin\v2\058_agent_job_control.sql
GO
GO
-- ---- Phase 14b: Console "Apply fix" (self-contained: usp_ValidateConfiguration w/ ActionKey findings +
--       usp_Api_ValidateConfiguration wrapper passthrough + usp_Api_ApplyConfigFix + grants). Placed after
--       the Phase-13 role model so its guarded EXECUTE grants resolve; without this the Validation
--       screen's one-click "Apply fix" backend proc (usp_Api_ApplyConfigFix) would be absent. ----
-- >>> inlined: kArchiveManagerAdmin\v2\063_console_apply_config_fix.sql
/* ============================================================================
   063_console_apply_config_fix.sql
   Console "Apply fix" for validation findings: a SAFE, named, parameterized
   remediation dispatched by ActionKey (NO arbitrary-SQL execution from the API).

   Ships:
     * arch.usp_Api_ApplyConfigFix  - dispatch proc; first ActionKey = ENABLE_CHEAP_MODE
         (derives the cheap-mode config server-side from the existing TimestampExpr,
          validates it through the safe-expr gate, applies CandidateSelectExpr +
          CandidateWhereSql). Correctness-equivalent to the per-row AT TIME ZONE path.
     * arch.usp_Api_ValidateConfiguration - wrapper updated to carry the new ActionKey
          column from arch.usp_ValidateConfiguration through to the Console.
     * EXECUTE grants for the config-admin / advanced-admin roles.

   PREREQUISITE: deploy the updated arch.usp_ValidateConfiguration (procedures\
   arch.usp_ValidateConfiguration.sql) first - it now emits the ActionKey column and
   the "cheap-mode available" INFO finding that drives the Console Apply button.
   ============================================================================ */
-- ----------------------------------------------------------------------------
-- Updated arch.usp_ValidateConfiguration: emits the ActionKey column + the
-- 'cheap-mode available' INFO finding that drives the Console Apply button.
-- (Full proc inlined so this migration is self-contained as an add-on deploy.)
-- ----------------------------------------------------------------------------

USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_ValidateConfiguration]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Findings
    (
        Severity varchar(10) NOT NULL,
        ProcessCode sysname NULL,
        SourceDb sysname NULL,
        ArchiveDb sysname NULL,
        ObjectName nvarchar(300) NULL,
        Finding nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL,   -- concrete remediation SQL the operator can copy/run
        ActionKey nvarchar(60) NULL        -- when set, a safe one-click remediation exists (Console "Apply"); dispatched by arch.usp_Api_ApplyConfigFix
    );

    INSERT #Findings(Severity, ProcessCode, Finding)
    SELECT 'ERROR', p.ProcessCode, N'Process is enabled but has no ObjectSpec rows.'
    FROM arch.Process p
    WHERE p.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND NOT EXISTS (SELECT 1 FROM arch.ObjectSpec os WHERE os.ProcessId = p.ProcessId);

    INSERT #Findings(Severity, ProcessCode, Finding)
    SELECT 'ERROR', p.ProcessCode, N'Process is enabled but has no enabled ProcessDatabase mapping.'
    FROM arch.Process p
    WHERE p.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND NOT EXISTS
      (
          SELECT 1
          FROM arch.ProcessDatabase pd
          WHERE pd.ProcessId = p.ProcessId
            AND pd.IsEnabled = 1
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'WARN',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        N'Redundant database override in arch.ProcessDatabase: ' + v.ConfigName
        + N' equals the arch.Process default. Keep this ProcessDatabase column NULL unless the database intentionally differs.'
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    CROSS APPLY
    (
        VALUES
            (N'Mode', CASE WHEN pd.Mode IS NOT NULL AND pd.Mode = p.Mode THEN 1 ELSE 0 END),
            (N'RetentionDays', CASE WHEN pd.RetentionDays IS NOT NULL AND pd.RetentionDays = p.RetentionDays THEN 1 ELSE 0 END),
            (N'CutoffSafetyLagMinutes', CASE WHEN pd.CutoffSafetyLagMinutes IS NOT NULL AND pd.CutoffSafetyLagMinutes = p.CutoffSafetyLagMinutes THEN 1 ELSE 0 END),
            (N'CutoffMode', CASE WHEN pd.CutoffMode IS NOT NULL AND pd.CutoffMode = p.CutoffMode THEN 1 ELSE 0 END),
            (N'CutoffDate', CASE WHEN pd.CutoffDate IS NOT NULL AND pd.CutoffDate = p.CutoffDate THEN 1 ELSE 0 END),
            (N'BatchDocCount', CASE WHEN pd.BatchDocCount IS NOT NULL AND pd.BatchDocCount = p.BatchDocCount THEN 1 ELSE 0 END),
            (N'BatchRowCount', CASE WHEN pd.BatchRowCount IS NOT NULL AND pd.BatchRowCount = p.BatchRowCount THEN 1 ELSE 0 END),
            (N'MaxBatchesPerRun', CASE WHEN pd.MaxBatchesPerRun IS NOT NULL AND pd.MaxBatchesPerRun = p.MaxBatchesPerRun THEN 1 ELSE 0 END),
            (N'DelayMsBetweenBatches', CASE WHEN pd.DelayMsBetweenBatches IS NOT NULL AND pd.DelayMsBetweenBatches = p.DelayMsBetweenBatches THEN 1 ELSE 0 END),
            (N'UseAppLock', CASE WHEN pd.UseAppLock IS NOT NULL AND pd.UseAppLock = p.UseAppLock THEN 1 ELSE 0 END),
            (N'AppLockResource', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AppLockResource)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AppLockResource)), N'') = NULLIF(LTRIM(RTRIM(p.AppLockResource)), N'') THEN 1 ELSE 0 END),
            (N'LockTimeoutMs', CASE WHEN pd.LockTimeoutMs IS NOT NULL AND pd.LockTimeoutMs = p.LockTimeoutMs THEN 1 ELSE 0 END),
            (N'DeadlockPriority', CASE WHEN NULLIF(LTRIM(RTRIM(pd.DeadlockPriority)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.DeadlockPriority)), N'') = NULLIF(LTRIM(RTRIM(p.DeadlockPriority)), N'') THEN 1 ELSE 0 END),
            (N'AnchorSchema', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorSchema)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorSchema)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorSchema)), N'') THEN 1 ELSE 0 END),
            (N'AnchorTable', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorTable)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorTable)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorTable)), N'') THEN 1 ELSE 0 END),
            (N'AnchorDocKeyExpr', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorDocKeyExpr)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorDocKeyExpr)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorDocKeyExpr)), N'') THEN 1 ELSE 0 END),
            (N'AnchorDocKey2Expr', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorDocKey2Expr)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorDocKey2Expr)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorDocKey2Expr)), N'') THEN 1 ELSE 0 END),
            (N'AnchorTimestampExpr', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorTimestampExpr)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorTimestampExpr)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorTimestampExpr)), N'') THEN 1 ELSE 0 END),
            (N'AnchorExtraWhereSql', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorExtraWhereSql)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorExtraWhereSql)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorExtraWhereSql)), N'') THEN 1 ELSE 0 END),
            (N'AllowDeleteWithoutArchive', CASE WHEN pd.AllowDeleteWithoutArchive IS NOT NULL AND pd.AllowDeleteWithoutArchive = p.AllowDeleteWithoutArchive THEN 1 ELSE 0 END),
            (N'DocKeyLabel', CASE WHEN NULLIF(LTRIM(RTRIM(pd.DocKeyLabel)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.DocKeyLabel)), N'') = NULLIF(LTRIM(RTRIM(p.DocKeyLabel)), N'') THEN 1 ELSE 0 END),
            (N'AuditLevel', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AuditLevel)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AuditLevel)), N'') = NULLIF(LTRIM(RTRIM(p.AuditLevel)), N'') THEN 1 ELSE 0 END),
            (N'RequireSupportingIndex', CASE WHEN pd.RequireSupportingIndex IS NOT NULL AND pd.RequireSupportingIndex = p.RequireSupportingIndex THEN 1 ELSE 0 END),
            (N'MaxRowsPerTransaction', CASE WHEN pd.MaxRowsPerTransaction IS NOT NULL AND pd.MaxRowsPerTransaction = p.MaxRowsPerTransaction THEN 1 ELSE 0 END),
            (N'CandidateWhereSql', CASE WHEN NULLIF(LTRIM(RTRIM(pd.CandidateWhereSql)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.CandidateWhereSql)), N'') = NULLIF(LTRIM(RTRIM(p.CandidateWhereSql)), N'') THEN 1 ELSE 0 END),
            (N'CandidateOrderSql', CASE WHEN NULLIF(LTRIM(RTRIM(pd.CandidateOrderSql)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.CandidateOrderSql)), N'') = NULLIF(LTRIM(RTRIM(p.CandidateOrderSql)), N'') THEN 1 ELSE 0 END)
    ) AS v(ConfigName, IsRedundant)
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND v.IsRedundant = 1;

    -- CRITICAL SAFETY: oversized per-transaction delete batch -> lock escalation on the PRODUCTION source.
    -- SQL Server escalates a statement's row locks to a TABLE X lock at ~5000 locks; a per-batch DELETE of
    -- more than that many source rows therefore takes an exclusive lock on the whole source table and BLOCKS
    -- OLTP for the batch duration (proven live: 50000-row batch -> OBJECT X lock + blocked readers; 4000 -> safe).
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        N'Per-transaction delete batch is too large ('
          + CONVERT(nvarchar(20), (SELECT MAX(v) FROM (VALUES
                (COALESCE(pd.BatchRowCount, p.BatchRowCount)),
                (COALESCE(pd.BatchDocCount, p.BatchDocCount)),
                (COALESCE(pd.MaxRowsPerTransaction, p.MaxRowsPerTransaction))) AS x(v)))
          + N' rows). A single DELETE of that many rows can escalate to a TABLE X lock on the production source '
          + N'and block OLTP for the batch duration. Keep BatchRowCount, BatchDocCount and MaxRowsPerTransaction <= 4000 '
          + N'and raise MaxBatchesPerRun to keep throughput (e.g. 4000 x 250 = 1,000,000 rows per run). '
          + N'(The runner also hard-caps the per-transaction delete at 4000 as a backstop.)'
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND (   COALESCE(pd.BatchRowCount, p.BatchRowCount, 0) > 4000
           OR COALESCE(pd.BatchDocCount, p.BatchDocCount, 0) > 4000
           OR COALESCE(pd.MaxRowsPerTransaction, p.MaxRowsPerTransaction, 0) > 4000);

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'WARN',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        N'Global arch.Process CutoffDate is active for a process with multiple enabled database mappings. Prefer setting CutoffMode/CutoffDate in arch.ProcessDatabase when cutoffs are database-specific.'
    FROM arch.Process p
    JOIN arch.ProcessDatabase pd
      ON pd.ProcessId = p.ProcessId
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND p.CutoffMode = 1
      AND p.CutoffDate IS NOT NULL
      AND pd.CutoffMode IS NULL
      AND pd.CutoffDate IS NULL
      AND 1 <
      (
          SELECT COUNT_BIG(*)
          FROM arch.ProcessDatabase pd2
          WHERE pd2.ProcessId = p.ProcessId
            AND pd2.IsEnabled = 1
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'WARN',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        QUOTENAME(COALESCE(NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N''), os.SourceSchema))
        + N'.' + QUOTENAME(COALESCE(NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N''), os.SourceTable)),
        N'Redundant object override in arch.ObjectSpecDatabaseOverride: ' + v.ConfigName
        + N' equals the arch.ObjectSpec default. Keep this override column NULL unless the database/table intentionally differs.'
    FROM arch.ObjectSpecDatabaseOverride osdo
    JOIN arch.ProcessDatabase pd
      ON pd.ProcessDatabaseId = osdo.ProcessDatabaseId
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    JOIN arch.ObjectSpec os
      ON os.ObjectSpecId = osdo.ObjectSpecId
     AND os.ProcessId = p.ProcessId
    CROSS APPLY
    (
        VALUES
            (N'SourceSchemaOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N'') = NULLIF(LTRIM(RTRIM(os.SourceSchema)), N'') THEN 1 ELSE 0 END),
            (N'SourceTableOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N'') = NULLIF(LTRIM(RTRIM(os.SourceTable)), N'') THEN 1 ELSE 0 END),
            (N'TimestampExprOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.TimestampExprOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.TimestampExprOverride)), N'') = NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') THEN 1 ELSE 0 END),
            (N'JoinToAnchorPredicateSqlOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.JoinToAnchorPredicateSqlOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.JoinToAnchorPredicateSqlOverride)), N'') = NULLIF(LTRIM(RTRIM(os.JoinToAnchorPredicateSql)), N'') THEN 1 ELSE 0 END),
            (N'AdditionalWhereSqlOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.AdditionalWhereSqlOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.AdditionalWhereSqlOverride)), N'') = NULLIF(LTRIM(RTRIM(os.AdditionalWhereSql)), N'') THEN 1 ELSE 0 END),
            (N'ArchiveSchemaOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.ArchiveSchemaOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.ArchiveSchemaOverride)), N'') = NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') THEN 1 ELSE 0 END),
            (N'ArchiveTableOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.ArchiveTableOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.ArchiveTableOverride)), N'') = NULLIF(LTRIM(RTRIM(os.ArchiveTable)), N'') THEN 1 ELSE 0 END),
            (N'RequireArchiveForDeleteOverride', CASE WHEN osdo.RequireArchiveForDeleteOverride IS NOT NULL AND osdo.RequireArchiveForDeleteOverride = os.RequireArchiveForDelete THEN 1 ELSE 0 END)
    ) AS v(ConfigName, IsRedundant)
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND osdo.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND v.IsRedundant = 1;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'ObjectSpecDatabaseOverride points to an ObjectSpec from a different process than its ProcessDatabase mapping.'
    FROM arch.ObjectSpecDatabaseOverride osdo
    JOIN arch.ProcessDatabase pd
      ON pd.ProcessDatabaseId = osdo.ProcessDatabaseId
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    JOIN arch.ObjectSpec os
      ON os.ObjectSpecId = osdo.ObjectSpecId
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND os.ProcessId <> pd.ProcessId;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Anchor-driven process has incomplete anchor configuration.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
      AND
      (
          e.AnchorSchema IS NULL
          OR e.AnchorTable IS NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorDocKeyExpr)), N'') IS NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorTimestampExpr)), N'') IS NULL
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'WARN',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Non-anchor process has anchor fields populated even though SelectionStrategy is not ANCHOR.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'ANCHOR'
      AND
      (
          e.AnchorSchema IS NOT NULL
          OR e.AnchorTable IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorDocKeyExpr)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorDocKey2Expr)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorTimestampExpr)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorExtraWhereSql)), N'') IS NOT NULL
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Anchor-driven ObjectSpec requires JoinToAnchorPredicateSql.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND EXISTS
      (
          SELECT 1
          FROM arch.v_ProcessDatabaseEffective e
          WHERE e.ProcessDatabaseId = os.ProcessDatabaseId
            AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
      )
      AND os.DeleteMode = 1
      AND NULLIF(LTRIM(RTRIM(os.JoinToAnchorPredicateSql)), N'') IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Row-driven ObjectSpec requires TimestampExpr.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'TIMESTAMP'
      AND e.AnchorTable IS NULL
      AND os.DeleteMode = 0
      AND NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'TIMESTAMP process requires ObjectSpec.DeleteMode = 1.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND os.DeleteMode <> 1;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'TIMESTAMP process requires TimestampExpr and JoinToAnchorPredicateSql on every ObjectSpec.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND
      (
          NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NULL
          OR NULLIF(LTRIM(RTRIM(os.JoinToAnchorPredicateSql)), N'') IS NULL
      );

    -- Cheap-mode misconfiguration (WARN): a CandidateSelectExpr (cheap local-time projection) only takes
    -- effect when the mapping ALSO has a sargable CandidateWhereSql cutoff (027 @cheapMode needs BOTH). Set
    -- alone it is silently ignored and the runner falls back to the slower per-row AT TIME ZONE candidate
    -- selection -> surface it so the operator either completes or removes the cheap-mode setup.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'WARN',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'ObjectSpec.CandidateSelectExpr is set but the mapping has no CandidateWhereSql cutoff, so cheap-mode candidate selection will NOT activate (the runner uses the slower per-row AT TIME ZONE path). Set a sargable CandidateWhereSql on arch.ProcessDatabase (raw indexed column vs @CutoffUtc) to enable it, or clear CandidateSelectExpr.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.CandidateSelectExpr)), N'') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(e.CandidateWhereSql)), N'') IS NULL;

    -- Cheap-mode active (INFO): the sargable string cutoff is only correct when the source time column is
    -- lexicographically chronological (ISO yyyymmdd...). A mixed/non-ISO format makes it under-select rows
    -- SILENTLY (it never deletes the wrong rows, but may process 0 -> KMWE_Test.RF_LOG2 lesson). Remind the
    -- operator to verify the column format before trusting cheap-mode on this source.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'INFO',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Cheap-mode candidate selection is active (CandidateSelectExpr + CandidateWhereSql both set). Verify the source time column is lexicographically chronological (ISO yyyymmdd...): a mixed/non-ISO string format makes the sargable cutoff under-select rows silently (never wrong rows, but possibly 0). Use classic mode (clear CandidateWhereSql) for mixed-format columns.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.CandidateSelectExpr)), N'') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(e.CandidateWhereSql)), N'') IS NOT NULL;

    -- Cheap-mode AVAILABLE (INFO, performance opportunity + one-click remediation): a TIMESTAMP process whose
    -- TimestampExpr applies per-row AT TIME ZONE for candidate selection, but cheap-mode is NOT enabled
    -- (no CandidateWhereSql cutoff). Enabling cheap-mode removes the per-row AT TIME ZONE from the candidate
    -- scan (the dominant scan cost on large sources; measured ~17x on RF_LOG2). The derived config is
    -- CORRECTNESS-EQUIVALENT: it compares the SAME local timestamp (TimestampExpr with the AT TIME ZONE tail
    -- stripped) to the SAME cutoff (@CutoffUtc converted to the source's local zone ONCE), and the retention
    -- floor (50210) + safe-expr gate (50400) still apply unchanged. Offered ONLY when the mapping has exactly
    -- ONE enabled TIMESTAMP ObjectSpec (single timestamp table) so the per-ProcessDatabase CandidateWhereSql is
    -- unambiguous, and only when the local-time core + zone can be parsed from the expression. ActionKey lets
    -- the Console show an "Apply" button -> arch.usp_Api_ApplyConfigFix derives + validates + sets it server-side.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql, ActionKey)
    SELECT
        'INFO',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Performance: this TIMESTAMP process uses per-row AT TIME ZONE for candidate selection and cheap-mode is not enabled. Enabling cheap-mode removes the per-row AT TIME ZONE from the candidate scan (the dominant cost on large sources) and is correctness-equivalent (same local timestamp vs the same cutoff; retention floor and safe-expr gate still apply).',
        N'Enable cheap-mode (one-click, ActionKey=ENABLE_CHEAP_MODE) -> sets ObjectSpec.CandidateSelectExpr = '
          + d.localCore
          + N'   and   arch.ProcessDatabase.CandidateWhereSql = (' + d.localCore
          + N') < CONVERT(datetime2(0), @CutoffUtc AT TIME ZONE N''UTC'' AT TIME ZONE N''' + d.zone + N''').'
          + N' Or run: EXEC arch.usp_Api_ApplyConfigFix @ActionKey=N''ENABLE_CHEAP_MODE'', @ProcessCode=N'''
          + REPLACE(os.ProcessCode, N'''', N'''''') + N''', @SourceDb=N''' + REPLACE(os.SourceDb, N'''', N'''''') + N'''.',
        N'ENABLE_CHEAP_MODE'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    CROSS APPLY (SELECT atzPos = CHARINDEX(N' AT TIME ZONE ', os.TimestampExpr)) p1
    CROSS APPLY (SELECT localCore = LTRIM(RTRIM(LEFT(os.TimestampExpr, NULLIF(p1.atzPos, 0) - 1)))) p2
    CROSS APPLY (SELECT zTail = SUBSTRING(os.TimestampExpr, CHARINDEX(N'AT TIME ZONE N''', os.TimestampExpr) + 15, 200)) p3
    CROSS APPLY (SELECT zone = LEFT(p3.zTail, NULLIF(CHARINDEX(N'''', p3.zTail), 0) - 1)) p4
    CROSS APPLY (SELECT localCore = p2.localCore, zone = p4.zone) d
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NOT NULL
      AND os.TimestampExpr LIKE N'% AT TIME ZONE N''%'
      AND NULLIF(LTRIM(RTRIM(e.CandidateWhereSql)), N'') IS NULL          -- cheap-mode currently OFF
      AND NULLIF(d.localCore, N'') IS NOT NULL
      AND NULLIF(d.zone, N'') IS NOT NULL
      AND
      (
          SELECT COUNT_BIG(*)
          FROM arch.v_ObjectSpecDatabaseEffective os2
          WHERE os2.ProcessDatabaseId = os.ProcessDatabaseId
            AND os2.ObjectIsEnabled = 1
      ) = 1;

    -- T-23 (timezone validity): a zone name in AT TIME ZONE must resolve in sys.time_zone_info, otherwise
    -- AT TIME ZONE THROWs at run time and the scheduled run wedges. Surface a typo'd source zone at
    -- config-validation time (fail-fast) by extracting the FIRST AT TIME ZONE N'...' literal from each
    -- enabled timestamp expression and checking it. (The deeper, SILENT hazard — text-date CONVERT being
    -- SET LANGUAGE / DATEFORMAT-sensitive — is a documented config guideline: use ISO/lexically-chronological
    -- source date columns; the runner intentionally does not pin SET LANGUAGE. See the operational docs.)
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT DISTINCT
        'WARN', src.ProcessCode, src.SourceDb, src.ArchiveDb, src.ObjectName,
        N'Timestamp expression references time zone ''' + z.Zone
        + N''' which is not in sys.time_zone_info on this instance — AT TIME ZONE will THROW at run time. Fix the zone name (see SELECT name FROM sys.time_zone_info) before enabling real runs.'
    FROM
    (
        SELECT e2.ProcessCode, e2.SourceDb, e2.ArchiveDb, ObjectName = CONVERT(nvarchar(300), NULL), Expr = e2.AnchorTimestampExpr
        FROM arch.v_ProcessDatabaseEffective e2
        WHERE e2.IsEnabled = 1
          AND COALESCE(e2.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
          AND e2.AnchorTimestampExpr LIKE N'%AT TIME ZONE N''%'
          AND (@ProcessCode IS NULL OR e2.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e2.SourceDb = @SourceDb)
        UNION ALL
        SELECT os.ProcessCode, os.SourceDb, os.ArchiveDb, QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable), os.TimestampExpr
        FROM arch.v_ObjectSpecDatabaseEffective os
        WHERE os.ProcessDatabaseIsEnabled = 1 AND os.ObjectIsEnabled = 1
          AND os.TimestampExpr LIKE N'%AT TIME ZONE N''%'
          AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
    ) src
    CROSS APPLY
    (
        SELECT Zone = LEFT(
                 SUBSTRING(src.Expr, CHARINDEX(N'AT TIME ZONE N''', src.Expr) + 15, 200),
                 NULLIF(CHARINDEX(N'''', SUBSTRING(src.Expr, CHARINDEX(N'AT TIME ZONE N''', src.Expr) + 15, 200)), 0) - 1)
    ) z
    WHERE z.Zone IS NOT NULL AND z.Zone <> N''
      AND NOT EXISTS (SELECT 1 FROM sys.time_zone_info t WHERE t.name = z.Zone);

    -- Mixed-format / language hazard (WARN): a TIMESTAMP-strategy source whose TimestampExpr applies a HARD
    -- CAST/CONVERT (no TRY_) to a text date column THROWs under a non-us_english session for English month-name
    -- values (e.g. 'Apr 9 2025') and can fail the scheduled run; under us_english the same value parses, so it
    -- is an environment-dependent latent failure (the runner intentionally does not pin SET LANGUAGE). A
    -- defensive TRY_CONVERT (+ optional TRY_PARSE ... USING 'en-US') yields NULL instead of throwing, so any
    -- unparseable rows are safely skipped (never archived/deleted, divergence unaffected) and are then counted
    -- by arch.usp_Frontend_TimestampRetentionGaps. This is a METADATA check (no source-row IO): it flags the
    -- non-defensive expression and emits a SuggestedSql fix. (If cheap-mode is used, make CandidateSelectExpr
    -- defensive too.) Excludes expressions already using TRY_CONVERT/TRY_PARSE/TRY_CAST.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql)
    SELECT
        'WARN', os.ProcessCode, os.SourceDb, os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'TimestampExpr uses a hard CAST/CONVERT (no TRY_) on a TIMESTAMP source. If the source date column is text, English month-name values (e.g. ''Apr 9 2025'') THROW under a non-us_english session and can fail the run; under us_english they parse, so this is an environment-dependent latent failure. Recommended defensive expression (replace <col> with the source column): COALESCE(TRY_CONVERT(datetime2, t.<col>), TRY_PARSE(t.<col> AS datetime2 USING ''en-US'')) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''. Unparseable rows then yield NULL (safely skipped) and are counted by arch.usp_Frontend_TimestampRetentionGaps. If cheap-mode is active, make CandidateSelectExpr defensive too. Ignore if the source column is already a real datetime/UTC type.',
        N'UPDATE os SET TimestampExpr = N''<DOSADTE_DEFENZIVNI_VYRAZ_Z_FINDING>'' FROM arch.ObjectSpec os JOIN arch.Process p ON p.ProcessId = os.ProcessId WHERE p.ProcessCode = N'''
          + REPLACE(os.ProcessCode, N'''', N'''''') + N''' AND os.SourceSchema = N'''
          + REPLACE(os.SourceSchema, N'''', N'''''') + N''' AND os.SourceTable = N'''
          + REPLACE(os.SourceTable, N'''', N'''''') + N''';'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NOT NULL
      AND (os.TimestampExpr LIKE N'%CAST(%' OR os.TimestampExpr LIKE N'%CONVERT(%')
      AND os.TimestampExpr NOT LIKE N'%TRY_CAST%'
      AND os.TimestampExpr NOT LIKE N'%TRY_CONVERT%'
      AND os.TimestampExpr NOT LIKE N'%TRY_PARSE%';

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NOT NULL
    BEGIN
        INSERT #Findings(Severity, ProcessCode, Finding)
        SELECT
            'ERROR',
            p.ProcessCode,
            N'TIMESTAMP process requires arch.ProcessKeySpec KeyOrdinal=1.'
        FROM arch.Process p
        WHERE p.IsEnabled = 1
          AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
          AND COALESCE(p.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
          AND NOT EXISTS
          (
              SELECT 1
              FROM arch.ProcessKeySpec pks
              WHERE pks.ProcessId = p.ProcessId
                AND pks.KeyOrdinal = 1
                AND NULLIF(LTRIM(RTRIM(pks.SourceExpressionSql)), N'') IS NOT NULL
          );

        INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
        SELECT DISTINCT
            'WARN',
            e.ProcessCode,
            e.SourceDb,
            e.ArchiveDb,
            N'Process defines ProcessKeySpec keys beyond Key2, but arch.WorkBatchKey primary key is currently (WorkBatchId, Key1, Key2). Ensure Key1/Key2 are unique for prepared batches or migrate the WorkBatchKey key design before using multi-column keys.'
        FROM arch.v_ProcessDatabaseEffective e
        JOIN arch.ProcessKeySpec pks
          ON pks.ProcessId = e.ProcessId
        WHERE e.IsEnabled = 1
          AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
          AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'TIMESTAMP'
          AND pks.KeyOrdinal > 2;
    END;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Source database does not exist on this SQL instance.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND DB_ID(e.SourceDb) IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Archive database does not exist on this SQL instance.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND DB_ID(e.ArchiveDb) IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'SourceDb and ArchiveDb are identical for an archive+delete or copy-only process.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND e.Mode IN (1, 2)
      AND e.SourceDb = e.ArchiveDb
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb);

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Anchor-driven process requires ObjectSpec.DeleteMode = 1.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
      AND os.DeleteMode <> 1;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Row-driven process requires ObjectSpec.DeleteMode = 0.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'TIMESTAMP'
      AND e.AnchorTable IS NULL
      AND os.DeleteMode <> 0;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Delete-only mode is blocked because RequireArchiveForDelete=1 and AllowDeleteWithoutArchive=0.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND e.Mode = 0
      AND COALESCE(os.RequireArchiveForDelete, 1) = 1
      AND COALESCE(e.AllowDeleteWithoutArchive, 0) = 0;

    DECLARE
        @vProcessCode sysname,
        @vSourceDb sysname,
        @vArchiveDb sysname,
        @vMode tinyint,
        @vSourceSchema sysname,
        @vSourceTable sysname,
        @vArchiveSchema sysname,
        @vArchiveTable sysname,
        @sql nvarchar(max);

    DECLARE object_check CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            os.ProcessCode,
            os.SourceDb,
            os.ArchiveDb,
            e.Mode,
            os.SourceSchema,
            os.SourceTable,
            CONVERT(nvarchar(128), REPLACE(
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo' THEN N'{SourceDb}'
                    ELSE LTRIM(RTRIM(os.ArchiveSchema))
                END,
                N'{SourceDb}', os.SourceDb)) AS ArchiveSchema,
            COALESCE(NULLIF(os.ArchiveTable, N''), os.SourceTable)
        FROM arch.v_ObjectSpecDatabaseEffective os
        JOIN arch.v_ProcessDatabaseEffective e
          ON e.ProcessDatabaseId = os.ProcessDatabaseId
        WHERE os.ProcessDatabaseIsEnabled = 1
          AND os.ObjectIsEnabled = 1
          AND DB_ID(os.SourceDb) IS NOT NULL
          AND DB_ID(os.ArchiveDb) IS NOT NULL
          AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb);

    OPEN object_check;
    FETCH NEXT FROM object_check INTO @vProcessCode, @vSourceDb, @vArchiveDb, @vMode, @vSourceSchema, @vSourceTable, @vArchiveSchema, @vArchiveTable;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
IF NOT EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(@vSourceDb) + N'.sys.tables t
    INNER JOIN ' + QUOTENAME(@vSourceDb) + N'.sys.schemas s
        ON s.schema_id = t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @pSourceSchema COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @pSourceTable COLLATE DATABASE_DEFAULT
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    VALUES
    (
        ''ERROR'',
        @pProcessCode,
        @pSourceDb,
        @pArchiveDb,
        QUOTENAME(@pSourceSchema) + N''.'' + QUOTENAME(@pSourceTable),
        N''Configured source table does not exist.''
    );
	END;';

        IF @vMode IN (1, 2)   -- archive+delete (1) and copy-only (2) both require the archive table
        BEGIN
            SET @sql = @sql + N'

	IF NOT EXISTS
	(
	    SELECT 1
	    FROM ' + QUOTENAME(@vArchiveDb) + N'.sys.tables t
    INNER JOIN ' + QUOTENAME(@vArchiveDb) + N'.sys.schemas s
        ON s.schema_id = t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @pArchiveSchema COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @pArchiveTable COLLATE DATABASE_DEFAULT
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    VALUES
    (
        ''WARN'',
        @pProcessCode,
        @pSourceDb,
        @pArchiveDb,
        QUOTENAME(@pArchiveSchema) + N''.'' + QUOTENAME(@pArchiveTable),
	        N''Archive table does not exist yet; provision it before delete/archive runs or allow the provisioning procedure to create it.''
	    );
	END;';
        END;

        EXEC sys.sp_executesql
            @sql,
            N'@pProcessCode sysname,
              @pSourceDb sysname,
              @pArchiveDb sysname,
              @pSourceSchema sysname,
              @pSourceTable sysname,
              @pArchiveSchema sysname,
              @pArchiveTable sysname',
            @pProcessCode = @vProcessCode,
            @pSourceDb = @vSourceDb,
            @pArchiveDb = @vArchiveDb,
            @pSourceSchema = @vSourceSchema,
            @pSourceTable = @vSourceTable,
            @pArchiveSchema = @vArchiveSchema,
            @pArchiveTable = @vArchiveTable;

        FETCH NEXT FROM object_check INTO @vProcessCode, @vSourceDb, @vArchiveDb, @vMode, @vSourceSchema, @vSourceTable, @vArchiveSchema, @vArchiveTable;
    END

    CLOSE object_check;
    DEALLOCATE object_check;

    /* Concrete remediation SQL for the deterministically-fixable findings. */
    -- archive table not yet provisioned -> the exact provisioning call
    UPDATE #Findings
    SET SuggestedSql =
        N'EXEC arch.usp_ProvisionArchiveTablesForProcess @ProcessCode=N''' + REPLACE(ProcessCode, N'''', N'''''')
      + N''', @SourceDb=N''' + REPLACE(SourceDb, N'''', N'''''')
      + N''', @ArchiveDb=N''' + REPLACE(ArchiveDb, N'''', N'''''') + N''';'
    WHERE Finding LIKE N'Archive table does not exist%'
      AND ProcessCode IS NOT NULL AND SourceDb IS NOT NULL AND ArchiveDb IS NOT NULL;

    -- redundant ProcessDatabase override -> NULL out the redundant column (keeps the arch.Process default)
    UPDATE #Findings
    SET SuggestedSql =
        N'UPDATE pd SET ' + QUOTENAME(LTRIM(RTRIM(SUBSTRING(Finding,
              CHARINDEX(N'arch.ProcessDatabase: ', Finding) + 22,
              CHARINDEX(N' equals', Finding) - (CHARINDEX(N'arch.ProcessDatabase: ', Finding) + 22)))))
      + N' = NULL FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId = pd.ProcessId'
      + N' WHERE p.ProcessCode=N''' + REPLACE(ProcessCode, N'''', N'''''')
      + N''' AND pd.SourceDb=N''' + REPLACE(SourceDb, N'''', N'''''')
      + N''' AND pd.ArchiveDb=N''' + REPLACE(ArchiveDb, N'''', N'''''') + N''';'
    WHERE Finding LIKE N'Redundant database override in arch.ProcessDatabase:%'
      AND CHARINDEX(N' equals', Finding) > CHARINDEX(N'arch.ProcessDatabase: ', Finding) + 22
      AND ProcessCode IS NOT NULL AND SourceDb IS NOT NULL AND ArchiveDb IS NOT NULL;

    SELECT Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql, ActionKey
    FROM #Findings
    ORDER BY CASE Severity WHEN 'ERROR' THEN 0 ELSE 1 END, ProcessCode, SourceDb, ObjectName;

    IF EXISTS (SELECT 1 FROM #Findings WHERE Severity = 'ERROR')
        RETURN 1;

    RETURN 0;
END
GO

USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ----------------------------------------------------------------------------
-- API wrapper: pass the new ActionKey column through to the Console.
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE [arch].[usp_Api_ValidateConfiguration]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Findings
    (
        Severity varchar(10) NOT NULL,
        ProcessCode sysname NULL,
        SourceDb sysname NULL,
        ArchiveDb sysname NULL,
        ObjectName nvarchar(300) NULL,
        Finding nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL,
        ActionKey nvarchar(60) NULL
    );

    INSERT INTO #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql, ActionKey)
    EXEC arch.usp_ValidateConfiguration
        @ProcessCode = @ProcessCode,
        @SourceDb = @SourceDb;

    DECLARE @ReturnCode int =
        CASE WHEN EXISTS (SELECT 1 FROM #Findings WHERE Severity = 'ERROR') THEN 1 ELSE 0 END;

    SELECT
        ReturnCode = @ReturnCode,
        Severity,
        ProcessCode,
        SourceDb,
        ArchiveDb,
        ObjectName,
        Finding,
        SuggestedSql,
        ActionKey
    FROM #Findings
    ORDER BY
        CASE Severity WHEN 'ERROR' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END,
        ProcessCode,
        SourceDb,
        ObjectName;

    RETURN COALESCE(@ReturnCode, 0);
END
GO

-- ----------------------------------------------------------------------------
-- Dispatch proc for one-click remediation. Parameterized + named only; it NEVER
-- executes operator-supplied SQL. Each ActionKey maps to one deterministic, safe fix.
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE [arch].[usp_Api_ApplyConfigFix]
    @ActionKey   nvarchar(60),
    @ProcessCode sysname,
    @SourceDb    sysname
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@ActionKey)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@ProcessCode)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@SourceDb)), N'') IS NULL
        THROW 50450, 'ActionKey, ProcessCode and SourceDb are required.', 1;

    IF @ActionKey = N'ENABLE_CHEAP_MODE'
    BEGIN
        DECLARE @pid int = (SELECT ProcessId FROM arch.Process WHERE ProcessCode = @ProcessCode);
        IF @pid IS NULL
            THROW 50452, 'Process not found.', 1;

        -- Must be a TIMESTAMP mapping for this source DB.
        IF NOT EXISTS
        (
            SELECT 1 FROM arch.v_ProcessDatabaseEffective e
            WHERE e.ProcessCode = @ProcessCode
              AND e.SourceDb = @SourceDb
              AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
        )
            THROW 50456, 'ENABLE_CHEAP_MODE applies only to a TIMESTAMP process/source.', 1;

        -- Single-ObjectSpec guard: a per-ProcessDatabase CandidateWhereSql must be unambiguous.
        IF (SELECT COUNT_BIG(*) FROM arch.ObjectSpec WHERE ProcessId = @pid) <> 1
            THROW 50453, 'ENABLE_CHEAP_MODE supports a single-ObjectSpec TIMESTAMP process only; configure cheap-mode by hand for multi-table processes.', 1;

        -- Effective TimestampExpr for this (process, source) - honours any per-DB override.
        DECLARE @tsExpr nvarchar(4000);
        SELECT @tsExpr = COALESCE(NULLIF(LTRIM(RTRIM(ovr.TimestampExprOverride)), N''), os.TimestampExpr)
        FROM arch.ObjectSpec os
        LEFT JOIN arch.ProcessDatabase pd ON pd.ProcessId = os.ProcessId AND pd.SourceDb = @SourceDb
        LEFT JOIN arch.ObjectSpecDatabaseOverride ovr ON ovr.ObjectSpecId = os.ObjectSpecId AND ovr.ProcessDatabaseId = pd.ProcessDatabaseId
        WHERE os.ProcessId = @pid;

        IF NULLIF(LTRIM(RTRIM(@tsExpr)), N'') IS NULL
            THROW 50457, 'TimestampExpr is empty; cannot derive cheap-mode config.', 1;

        -- Derive the cheap LOCAL-time core (TimestampExpr with the AT TIME ZONE tail stripped) and the source zone.
        DECLARE @atz int = CHARINDEX(N' AT TIME ZONE ', @tsExpr);
        IF @atz <= 0
            THROW 50454, 'TimestampExpr does not use AT TIME ZONE; cheap-mode auto-enable is not applicable (configure CandidateSelectExpr/CandidateWhereSql by hand).', 1;

        DECLARE @localCore nvarchar(4000) = LTRIM(RTRIM(LEFT(@tsExpr, @atz - 1)));
        DECLARE @zTail nvarchar(400) = SUBSTRING(@tsExpr, CHARINDEX(N'AT TIME ZONE N''', @tsExpr) + 15, 200);
        DECLARE @zone nvarchar(200) = LEFT(@zTail, NULLIF(CHARINDEX(N'''', @zTail), 0) - 1);

        IF NULLIF(@localCore, N'') IS NULL OR NULLIF(@zone, N'') IS NULL
            THROW 50455, 'Could not parse the local-time core or the time zone from TimestampExpr.', 1;

        -- The cutoff is converted to the source local zone ONCE (constant), then compared to the local core.
        -- Correctness-equivalent to (localCore AT TIME ZONE zone AT TIME ZONE UTC) < @CutoffUtc; removes the
        -- per-row AT TIME ZONE. @CutoffUtc here is a LITERAL token the runner binds as a real parameter.
        DECLARE @whereSql nvarchar(4000) =
            N'(' + @localCore + N') < CONVERT(datetime2(0), @CutoffUtc AT TIME ZONE N''UTC'' AT TIME ZONE N''' + @zone + N''')';

        -- Defense in depth: both expressions must clear the safe-expr gate (THROW 50400 if not).
        EXEC arch.usp_AssertSafeSqlExpression @Expression = @localCore, @FieldName = N'ObjectSpec.CandidateSelectExpr';
        EXEC arch.usp_AssertSafeSqlExpression @Expression = @whereSql,  @FieldName = N'CandidateWhereSql';

        -- Governance note: this is an immediate, single-purpose, safe remediation (not wrapped in a
        -- ConfigChangeSet like the multi-field Save APIs). It DOES refresh the optimistic-concurrency stamp
        -- (ModifiedAt) on both rows so a subsequent Console edit cannot silently clobber the cheap-mode change:
        --   * arch.ObjectSpec.ModifiedAt is bumped automatically by trigger tr_ObjectSpec_SetModifiedAt.
        --   * arch.ProcessDatabase has no such trigger, so we set ModifiedAt explicitly here (matches usp_Api_SaveProcessDatabase).
        BEGIN TRAN;
            UPDATE arch.ObjectSpec
            SET CandidateSelectExpr = @localCore
            WHERE ProcessId = @pid;   -- single ObjectSpec (guarded above); ModifiedAt bumped by trigger

            UPDATE pd
            SET pd.CandidateWhereSql = @whereSql,
                pd.ModifiedAt = SYSUTCDATETIME()
            FROM arch.ProcessDatabase pd
            WHERE pd.ProcessId = @pid
              AND pd.SourceDb = @SourceDb;
        COMMIT;

        SELECT
            Applied = CONVERT(bit, 1),
            ActionKey = @ActionKey,
            ProcessCode = @ProcessCode,
            SourceDb = @SourceDb,
            CandidateSelectExpr = @localCore,
            CandidateWhereSql = @whereSql,
            Message = N'Cheap-mode enabled. Re-run validation to confirm.';
        RETURN 0;
    END;

    THROW 50451, 'Unknown or unsupported ActionKey.', 1;
END
GO

-- ----------------------------------------------------------------------------
-- Grants: config-write roles may apply config remediations (same tier as usp_Api_SaveObjectSpec).
-- ----------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'karch_config_admin' AND type = N'R')
    GRANT EXECUTE ON [arch].[usp_Api_ApplyConfigFix] TO [karch_config_admin];
GO
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'karch_advanced_admin' AND type = N'R')
    GRANT EXECUTE ON [arch].[usp_Api_ApplyConfigFix] TO [karch_advanced_admin];
GO

-- Read-tier hardening: the Analysis "next-run estimate" proc is part of the open read tier, but a
-- deploy-ordering gap can leave EXECUTE granted to NO ONE, so the Analysis "Odhady" tile returns 500
-- ("EXECUTE permission was denied"). Re-assert the read-role grants here (idempotent; guarded on the
-- proc + roles existing) so the estimate endpoint works for viewers.
IF OBJECT_ID(N'arch.usp_Api_EstimateNextRunImpact') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'karch_viewer' AND type = N'R')
    GRANT EXECUTE ON [arch].[usp_Api_EstimateNextRunImpact] TO [karch_viewer];
GO
IF OBJECT_ID(N'arch.usp_Api_EstimateNextRunImpact') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'karch_config_admin' AND type = N'R')
    GRANT EXECUTE ON [arch].[usp_Api_EstimateNextRunImpact] TO [karch_config_admin];
GO
-- <<< end: kArchiveManagerAdmin\v2\063_console_apply_config_fix.sql
GO
GO
-- ---- Phase 14c: legal-hold + retention-floor console surface (getter + grants to the elevated console
--       role so L2 operators can place/release holds and set the floor from the console). After roles. ----
-- >>> inlined: kArchiveManagerAdmin\v2\066_legal_hold_console.sql
/* ============================================================================
   066_legal_hold_console.sql — expose legal-hold + retention-floor management to the Admin Console.
   ----------------------------------------------------------------------------
   056 built the compliance API (usp_Api_AddLegalHold / usp_Api_ReleaseLegalHold / usp_Frontend_GetLegalHolds
   / usp_Api_SetRetentionFloor) but granted the mutating procs only to karch_approver — so the Admin
   Console (whose app login is in karch_config_admin/karch_advanced_admin, NOT karch_approver) could not
   drive them, and there was no console surface. This migration:
     * adds a read-only getter for the retention floor (usp_Frontend_GetRetentionFloor), and
     * grants the legal-hold / retention-floor procs to the ELEVATED console role (karch_advanced_admin)
       so L2 operators can place/release holds and set the floor from the console (the endpoints are
       IsElevated-gated). Read getters are also granted to the viewer/operator roles.
   karch_approver keeps its grants (unchanged). Idempotent.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetRetentionFloor]
AS
BEGIN
    SET NOCOUNT ON;
    SELECT MinRetentionDays, ModifiedAtUtc, ModifiedBy
    FROM arch.RetentionPolicy WHERE PolicyId = 1;
END
GO

/* Grants: elevated console role drives the compliance actions; viewer/operator can read. */
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON [arch].[usp_Api_SetRetentionFloor]      TO [karch_advanced_admin];
    GRANT EXECUTE ON [arch].[usp_Api_AddLegalHold]           TO [karch_advanced_admin];
    GRANT EXECUTE ON [arch].[usp_Api_ReleaseLegalHold]       TO [karch_advanced_admin];
    GRANT EXECUTE ON [arch].[usp_Frontend_GetLegalHolds]     TO [karch_advanced_admin];
    GRANT EXECUTE ON [arch].[usp_Frontend_GetRetentionFloor] TO [karch_advanced_admin];
END;
IF DATABASE_PRINCIPAL_ID(N'karch_config_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON [arch].[usp_Frontend_GetLegalHolds]     TO [karch_config_admin];
    GRANT EXECUTE ON [arch].[usp_Frontend_GetRetentionFloor] TO [karch_config_admin];
END;
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GetRetentionFloor] TO [karch_viewer];
IF DATABASE_PRINCIPAL_ID(N'karch_operator') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GetRetentionFloor] TO [karch_operator];
GO
PRINT 'Legal-hold + retention-floor console API installed (getter + elevated-console grants).';
GO
-- <<< end: kArchiveManagerAdmin\v2\066_legal_hold_console.sql
GO
GO
-- Operational add-ons are PARAMETERIZED (fill CHANGE-ME) and OPTIONAL — run separately after config:
--   deploy\v2\047_operational_alerting.sql   (Database Mail + failure alerting, T-14)
--   deploy\v2\048_archive_db_backup.sql       (archive DB FULL+LOG backup jobs, T-16)
-- REQUIRED post-deploy (parameterized): seed the default Admin Console operator so someone can log in —
--   kArchiveManagerAdmin\v2\064_console_default_operator.sql
--     1) run: KArchiveManager.AdminConsole.Api.exe hash-password "<password>"
--     2) paste the PBKDF2 value into 064 (replacing CHANGE-ME), then run it. Creates the 'admin'
--        default (sa-like, disable after creating real operators). The console starts but nobody can
--        edit Configuration/Validation/Go-live until at least one enabled operator exists.

-- ---- DEFERRED (run when customer DB names are known) ----
--   Real-process SEED: Process templates + ObjectSpec + ProcessKeySpec + ProcessDatabase mappings +
--   RunProfile + IndexRequirement + AT-TIME-ZONE cutoff exprs (v2/013,017,018,019,021,031,033,034 and/or
--   Admin Console). EXCLUDED here so the bundle creates objects only, no DB-specific test data.
--   Source-DB performance indexes (deploy\v2\37_create_recommended_source_indexes_current.sql) — per source DB.

PRINT 'kArchiveManager 2.0 CLEAN deploy completed.';
PRINT 'Post-deploy checks: 1) verify_clean_deploy.sql (object-set assert), 2) selftest_acceptance.sql';
PRINT '  (turnkey behavioral smoke: synthetic archive+DELETE+restore+audit+TZ-gate on a throwaway';
PRINT '   schema, then self-cleanup — proves the pipeline works here without touching real data).';
GO
