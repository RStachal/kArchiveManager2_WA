USE [kArchiveManagerAdmin]
GO

SET NOCOUNT ON;
GO

IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
   OR OBJECT_ID(N'arch.IndexRequirement', N'U') IS NULL
BEGIN
    RAISERROR(N'2.0 metadata is not installed. Run v2/010_universal_archive_core.sql first.', 16, 1);
    RETURN;
END
GO

MERGE arch.Process AS tgt
USING (VALUES
(
    N'RF_LOG2',
    N'KArchiveManager - System log history',
    CONVERT(bit, 1),          -- IsEnabled
    CONVERT(tinyint, 1),      -- Mode: archive + delete
    540,                      -- RetentionDays
    1440,                     -- CutoffSafetyLagMinutes
    NULL,                     -- BatchDocCount
    4000,                     -- BatchRowCount (<=4000: keep per-batch DELETE under the ~5000 lock-escalation threshold on the production source)
    250,                      -- MaxBatchesPerRun: 4000 x 250 = 1,000,000 rows per configured run (throughput preserved with a safe batch size)
    0,                        -- DelayMsBetweenBatches
    CONVERT(bit, 1),          -- UseAppLock
    NULL,
    10000,
    N'LOW',
    NULL, NULL, NULL, NULL, NULL, NULL,
    CONVERT(bit, 0),          -- AllowDeleteWithoutArchive
    CONVERT(tinyint, 0),      -- CutoffMode: retention based
    CONVERT(datetime2(0), '2024-01-01T00:00:00'),
    N'ROWID',
    N'TIMESTAMP',
    N'NONE',
    CONVERT(bit, 1),
    4000,                     -- MaxRowsPerTransaction (<=4000: per-batch DELETE stays under the source lock-escalation threshold)
    NULL,
    N'DocCreatedAt, Key1'
)
) AS src
(
    ProcessCode, Description, IsEnabled, Mode, RetentionDays, CutoffSafetyLagMinutes,
    BatchDocCount, BatchRowCount, MaxBatchesPerRun, DelayMsBetweenBatches, UseAppLock,
    AppLockResource, LockTimeoutMs, DeadlockPriority, AnchorSchema, AnchorTable,
    AnchorDocKeyExpr, AnchorDocKey2Expr, AnchorTimestampExpr, AnchorExtraWhereSql,
    AllowDeleteWithoutArchive, CutoffMode, CutoffDate, DocKeyLabel,
    SelectionStrategy, AuditLevel, RequireSupportingIndex, MaxRowsPerTransaction,
    CandidateWhereSql, CandidateOrderSql
)
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
    CutoffMode = src.CutoffMode,
    CutoffDate = src.CutoffDate,
    DocKeyLabel = src.DocKeyLabel,
    SelectionStrategy = src.SelectionStrategy,
    AuditLevel = src.AuditLevel,
    RequireSupportingIndex = src.RequireSupportingIndex,
    MaxRowsPerTransaction = src.MaxRowsPerTransaction,
    CandidateWhereSql = src.CandidateWhereSql,
    CandidateOrderSql = src.CandidateOrderSql,
    ModifiedAt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
(
    ProcessCode, Description, IsEnabled, Mode, RetentionDays, CutoffSafetyLagMinutes,
    BatchDocCount, BatchRowCount, MaxBatchesPerRun, DelayMsBetweenBatches, UseAppLock,
    AppLockResource, LockTimeoutMs, DeadlockPriority, AnchorSchema, AnchorTable,
    AnchorDocKeyExpr, AnchorDocKey2Expr, AnchorTimestampExpr, AnchorExtraWhereSql,
    AllowDeleteWithoutArchive, CreatedAt, ModifiedAt, CutoffMode, CutoffDate, DocKeyLabel,
    SelectionStrategy, AuditLevel, RequireSupportingIndex, MaxRowsPerTransaction,
    CandidateWhereSql, CandidateOrderSql
)
VALUES
(
    src.ProcessCode, src.Description, src.IsEnabled, src.Mode, src.RetentionDays, src.CutoffSafetyLagMinutes,
    src.BatchDocCount, src.BatchRowCount, src.MaxBatchesPerRun, src.DelayMsBetweenBatches, src.UseAppLock,
    src.AppLockResource, src.LockTimeoutMs, src.DeadlockPriority, src.AnchorSchema, src.AnchorTable,
    src.AnchorDocKeyExpr, src.AnchorDocKey2Expr, src.AnchorTimestampExpr, src.AnchorExtraWhereSql,
    src.AllowDeleteWithoutArchive, SYSUTCDATETIME(), SYSUTCDATETIME(), src.CutoffMode, src.CutoffDate, src.DocKeyLabel,
    src.SelectionStrategy, src.AuditLevel, src.RequireSupportingIndex, src.MaxRowsPerTransaction,
    src.CandidateWhereSql, src.CandidateOrderSql
);
GO

DECLARE @ProcessId int =
(
    SELECT ProcessId
    FROM arch.Process
    WHERE ProcessCode = N'RF_LOG2'
);

MERGE arch.ProcessKeySpec AS tgt
USING (VALUES
(
    @ProcessId,
    CONVERT(tinyint, 1),
    CONVERT(sysname, N'ROWID'),
    N't.ROWID',
    N'nvarchar(256)',
    CONVERT(bit, 1)
)
) AS src(ProcessId, KeyOrdinal, KeyName, SourceExpressionSql, SqlType, IsRequired)
ON tgt.ProcessId = src.ProcessId
AND tgt.KeyOrdinal = src.KeyOrdinal
WHEN MATCHED THEN UPDATE SET
    KeyName = src.KeyName,
    SourceExpressionSql = src.SourceExpressionSql,
    SqlType = src.SqlType,
    IsRequired = src.IsRequired,
    ModifiedAt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
(
    ProcessId, KeyOrdinal, KeyName, SourceExpressionSql, SqlType, IsRequired, CreatedAt, ModifiedAt
)
VALUES
(
    src.ProcessId, src.KeyOrdinal, src.KeyName, src.SourceExpressionSql, src.SqlType, src.IsRequired,
    SYSUTCDATETIME(), SYSUTCDATETIME()
);

DELETE ir
FROM arch.IndexRequirement ir
WHERE ir.ProcessId = @ProcessId;

DELETE FROM arch.ObjectSpec
WHERE ProcessId = @ProcessId
  AND SourceSchema = N'dbo'
  AND SourceTable = N'RF_LOG2';

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
    NaturalKeyLabel
)
VALUES
(
    @ProcessId,
    N'dbo',
    N'RF_LOG2',
    10,
    1,
    N'TRY_CONVERT(datetime2, t.DATE_TIME)',
    N't.ROWID = k.Key1',
    N't.DATE_TIME IS NOT NULL',
    N'{SourceDb}',
    NULL,
    1,
    N'ROWID'
);

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
SELECT
    @ProcessId,
    os.ObjectSpecId,
    req.RequirementType,
    req.SourceSchema,
    req.SourceTable,
    req.KeyColumnsCsv,
    req.IncludeColumnsCsv,
    req.FilterSql,
    req.IsMandatory,
    req.Notes,
    SYSUTCDATETIME(),
    SYSUTCDATETIME()
FROM arch.ObjectSpec os
CROSS APPLY
(
    VALUES
    (N'SELECTION', N'dbo', N'RF_LOG2', N'DATE_TIME,ROWID', NULL, N'DATE_TIME IS NOT NULL', CONVERT(bit, 1), N'RF_LOG2 timestamp keyset selection uses DATE_TIME and must be backed by an index.'),
    (N'JOIN',      N'dbo', N'RF_LOG2', N'ROWID',           NULL, NULL,                    CONVERT(bit, 1), N'Timestamp keyset deletes join back by ROWID.')
) AS req(RequirementType, SourceSchema, SourceTable, KeyColumnsCsv, IncludeColumnsCsv, FilterSql, IsMandatory, Notes)
WHERE os.ProcessId = @ProcessId
  AND os.SourceSchema = N'dbo'
  AND os.SourceTable = N'RF_LOG2';
GO

SELECT
    p.ProcessCode,
    p.SelectionStrategy,
    p.AuditLevel,
    p.BatchRowCount,
    p.MaxBatchesPerRun,
    p.MaxRowsPerTransaction,
    p.CandidateOrderSql
FROM arch.Process p
WHERE p.ProcessCode = N'RF_LOG2';

SELECT
    p.ProcessCode,
    pks.KeyOrdinal,
    pks.KeyName,
    pks.SourceExpressionSql,
    pks.SqlType
FROM arch.Process p
JOIN arch.ProcessKeySpec pks
  ON pks.ProcessId = p.ProcessId
WHERE p.ProcessCode = N'RF_LOG2'
ORDER BY pks.KeyOrdinal;

SELECT
    p.ProcessCode,
    ir.RequirementType,
    ObjectName = QUOTENAME(ir.SourceSchema) + N'.' + QUOTENAME(ir.SourceTable),
    ir.KeyColumnsCsv,
    ir.FilterSql,
    ir.IsMandatory,
    ir.Notes
FROM arch.IndexRequirement ir
JOIN arch.Process p
  ON p.ProcessId = ir.ProcessId
WHERE p.ProcessCode = N'RF_LOG2'
ORDER BY ir.RequirementType;
GO
