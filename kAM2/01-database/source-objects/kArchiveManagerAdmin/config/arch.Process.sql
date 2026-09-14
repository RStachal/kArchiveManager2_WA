USE [kArchiveManagerAdmin]
GO
SET NOCOUNT ON;
GO

MERGE arch.Process AS tgt
USING (VALUES
    (N'RECEIVING', N'KArchiveManager - Purchase Order History', 1, 1, 730, 1440, 500, NULL, 100, 0, 1, NULL, 10000, N'LOW', N'dbo', N'BACKRH', N'PO_NUM',   NULL, N'DATE_CREAT', NULL, 0, 1, CONVERT(datetime2(0),'2024-01-01T00:00:00'), N'PO_NUM'),
    (N'SHIPPING',  N'KArchiveManager - Sales Order History',    1, 1, 730, 1440, 1000, NULL, 500, 0, 1, NULL, 10000, N'LOW', N'dbo', N'SHIPHIST', N'PACKSLIP', NULL, N'COALESCE(DATE_SHIP, DATE_CREAT, DATE_UPLD)', NULL, 0, 1, CONVERT(datetime2(0),'2024-01-01T00:00:00'), N'PACKSLIP'),
    (N'RF_LOG2',   N'KArchiveManager - System log history',      1, 1, 540, 1440, NULL, 50000, 20, 0, 1, NULL, 10000, N'LOW', N'dbo', N'RF_LOG2', N'ROWID', NULL, N'DATE_TIME', N'DATE_TIME IS NOT NULL', 0, 0, CONVERT(datetime2(0),'2024-01-01T00:00:00'), N'ROWID')
) AS src(ProcessCode, Description, IsEnabled, Mode, RetentionDays, CutoffSafetyLagMinutes, BatchDocCount, BatchRowCount, MaxBatchesPerRun, DelayMsBetweenBatches, UseAppLock, AppLockResource, LockTimeoutMs, DeadlockPriority, AnchorSchema, AnchorTable, AnchorDocKeyExpr, AnchorDocKey2Expr, AnchorTimestampExpr, AnchorExtraWhereSql, AllowDeleteWithoutArchive, CutoffMode, CutoffDate, DocKeyLabel)
ON tgt.ProcessCode = src.ProcessCode
WHEN MATCHED THEN UPDATE SET
    Description = src.Description,
    IsEnabled = src.IsEnabled,
    Mode = src.Mode,
    RetentionDays = src.RetentionDays,
    CutoffSafetyLagMinutes = src.CutoffSafetyLagMinutes,
    BatchDocCount = src.BatchDocCount,
    BatchRowCount = src.BatchRowCount,
    MaxBatchesPerRun = src.MaxBatchesPerRun,
    DelayMsBetweenBatches = src.DelayMsBetweenBatches,
    UseAppLock = src.UseAppLock,
    AppLockResource = src.AppLockResource,
    LockTimeoutMs = src.LockTimeoutMs,
    DeadlockPriority = src.DeadlockPriority,
    AnchorSchema = src.AnchorSchema,
    AnchorTable = src.AnchorTable,
    AnchorDocKeyExpr = src.AnchorDocKeyExpr,
    AnchorDocKey2Expr = src.AnchorDocKey2Expr,
    AnchorTimestampExpr = src.AnchorTimestampExpr,
    AnchorExtraWhereSql = src.AnchorExtraWhereSql,
    AllowDeleteWithoutArchive = src.AllowDeleteWithoutArchive,
    ModifiedAt = SYSUTCDATETIME(),
    CutoffMode = src.CutoffMode,
    CutoffDate = src.CutoffDate,
    DocKeyLabel = src.DocKeyLabel
WHEN NOT MATCHED THEN INSERT
(
    ProcessCode, Description, IsEnabled, Mode, RetentionDays, CutoffSafetyLagMinutes,
    BatchDocCount, BatchRowCount, MaxBatchesPerRun, DelayMsBetweenBatches, UseAppLock,
    AppLockResource, LockTimeoutMs, DeadlockPriority, AnchorSchema, AnchorTable,
    AnchorDocKeyExpr, AnchorDocKey2Expr, AnchorTimestampExpr, AnchorExtraWhereSql, AllowDeleteWithoutArchive,
    CreatedAt, ModifiedAt, CutoffMode, CutoffDate, DocKeyLabel
)
VALUES
(
    src.ProcessCode, src.Description, src.IsEnabled, src.Mode, src.RetentionDays, src.CutoffSafetyLagMinutes,
    src.BatchDocCount, src.BatchRowCount, src.MaxBatchesPerRun, src.DelayMsBetweenBatches, src.UseAppLock,
    src.AppLockResource, src.LockTimeoutMs, src.DeadlockPriority, src.AnchorSchema, src.AnchorTable,
    src.AnchorDocKeyExpr, src.AnchorDocKey2Expr, src.AnchorTimestampExpr, src.AnchorExtraWhereSql, src.AllowDeleteWithoutArchive,
    SYSUTCDATETIME(), SYSUTCDATETIME(), src.CutoffMode, src.CutoffDate, src.DocKeyLabel
);
GO
