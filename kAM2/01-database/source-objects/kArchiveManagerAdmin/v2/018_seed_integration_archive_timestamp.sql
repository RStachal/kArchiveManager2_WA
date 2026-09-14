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

DECLARE
    @ProcessMode tinyint = 1,             -- archive + delete
    @RetentionDays int = 540,
    @CutoffSafetyLagMinutes int = 1440,
    @BatchRowCount int = 50000,
    @MaxBatchesPerRun int = 20;

DECLARE @TimstmpExpr nvarchar(4000) =
    N'TRY_CONVERT(datetime2(3), STUFF(STUFF(STUFF(REPLACE(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(25), t.TIMESTMP))), N''''), N''/'', N''.''), 9, 0, N''T''), 7, 0, N''-''), 5, 0, N''-''), 126)';

DECLARE @DnloadTimestampExpr nvarchar(4000) =
    N'COALESCE(CONVERT(datetime2(3), t.date_archived), ' + @TimstmpExpr + N')';

DECLARE @UploadTimestampExpr nvarchar(4000) = @TimstmpExpr;

DECLARE @DnloadWhereSql nvarchar(4000) =
    N'(t.date_archived IS NOT NULL OR ' + @TimstmpExpr + N' IS NOT NULL)';

DECLARE @UploadWhereSql nvarchar(4000) =
    N'(t.TIMESTMP IS NOT NULL AND ' + @TimstmpExpr + N' IS NOT NULL)';

MERGE arch.Process AS tgt
USING (VALUES
(
    N'INTEGRACE_DNLOAD',
    N'KArchiveManager - Integrace ERP to WMS download archive',
    CONVERT(bit, 1),
    @ProcessMode,
    @RetentionDays,
    @CutoffSafetyLagMinutes,
    NULL,
    @BatchRowCount,
    @MaxBatchesPerRun,
    0,
    CONVERT(bit, 1),
    NULL,
    10000,
    N'LOW',
    NULL, NULL, NULL, NULL, NULL, NULL,
    CONVERT(bit, 0),
    CONVERT(tinyint, 0),
    CONVERT(datetime2(0), '2024-01-01T00:00:00'),
    N'ROWID',
    N'TIMESTAMP',
    N'BATCH',
    CONVERT(bit, 1),
    @BatchRowCount,
    NULL,
    N'DocCreatedAt, Key1'
),
(
    N'INTEGRACE_UPLOAD',
    N'KArchiveManager - Integrace WMS to ERP upload archive',
    CONVERT(bit, 1),
    @ProcessMode,
    @RetentionDays,
    @CutoffSafetyLagMinutes,
    NULL,
    @BatchRowCount,
    @MaxBatchesPerRun,
    0,
    CONVERT(bit, 1),
    NULL,
    10000,
    N'LOW',
    NULL, NULL, NULL, NULL, NULL, NULL,
    CONVERT(bit, 0),
    CONVERT(tinyint, 0),
    CONVERT(datetime2(0), '2024-01-01T00:00:00'),
    N'ROWID',
    N'TIMESTAMP',
    N'BATCH',
    CONVERT(bit, 1),
    @BatchRowCount,
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

DECLARE @DnloadProcessId int =
(
    SELECT ProcessId
    FROM arch.Process
    WHERE ProcessCode = N'INTEGRACE_DNLOAD'
);

DECLARE @UploadProcessId int =
(
    SELECT ProcessId
    FROM arch.Process
    WHERE ProcessCode = N'INTEGRACE_UPLOAD'
);

MERGE arch.ProcessKeySpec AS tgt
USING (VALUES
(
    @DnloadProcessId,
    CONVERT(tinyint, 1),
    CONVERT(sysname, N'ROWID'),
    N't.ROWID',
    N'uniqueidentifier',
    CONVERT(bit, 1)
),
(
    @UploadProcessId,
    CONVERT(tinyint, 1),
    CONVERT(sysname, N'ROWID'),
    N't.ROWID',
    N'uniqueidentifier',
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
WHERE ir.ProcessId IN (@DnloadProcessId, @UploadProcessId);

DELETE FROM arch.ObjectSpec
WHERE ProcessId IN (@DnloadProcessId, @UploadProcessId);

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
    @DnloadProcessId,
    N'dbo',
    N'DNLOAD_ARCHIVE',
    10,
    1,
    @DnloadTimestampExpr,
    N't.ROWID = CONVERT(uniqueidentifier, k.Key1)',
    @DnloadWhereSql,
    N'{SourceDb}',
    NULL,
    1,
    N'ROWID'
),
(
    @UploadProcessId,
    N'dbo',
    N'UPLOADARCHIVE',
    10,
    1,
    @UploadTimestampExpr,
    N't.ROWID = CONVERT(uniqueidentifier, k.Key1)',
    @UploadWhereSql,
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
    p.ProcessId,
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
FROM arch.Process p
CROSS APPLY
(
    VALUES
    (N'INTEGRACE_DNLOAD', N'SELECTION', N'dbo', N'DNLOAD_ARCHIVE', N'date_archived,ROWID', NULL, NULL, CONVERT(bit, 0), N'DNLOAD primary cutoff uses date_archived; TIMESTMP parsing is the fallback for NULL date_archived values.'),
    (N'INTEGRACE_DNLOAD', N'JOIN',      N'dbo', N'DNLOAD_ARCHIVE', N'ROWID',               NULL, NULL, CONVERT(bit, 1), N'DNLOAD timestamp keyset deletes join back by ROWID.'),
    (N'INTEGRACE_UPLOAD', N'SELECTION', N'dbo', N'UPLOADARCHIVE',  N'TIMESTMP,ROWID',     NULL, NULL, CONVERT(bit, 0), N'UPLOAD cutoff parses TIMESTMP; for production prefer a persisted computed datetime column and an index over it plus ROWID.'),
    (N'INTEGRACE_UPLOAD', N'JOIN',      N'dbo', N'UPLOADARCHIVE',  N'ROWID',              NULL, NULL, CONVERT(bit, 1), N'UPLOAD timestamp keyset deletes join back by ROWID.')
) AS req(ProcessCode, RequirementType, SourceSchema, SourceTable, KeyColumnsCsv, IncludeColumnsCsv, FilterSql, IsMandatory, Notes)
JOIN arch.ObjectSpec os
  ON os.ProcessId = p.ProcessId
 AND os.SourceSchema = req.SourceSchema
 AND os.SourceTable = req.SourceTable
WHERE p.ProcessCode = req.ProcessCode;

SELECT
    p.ProcessCode,
    p.Description,
    p.IsEnabled,
    p.Mode,
    p.SelectionStrategy,
    p.AuditLevel,
    p.RetentionDays,
    p.BatchRowCount,
    p.MaxBatchesPerRun,
    p.CandidateOrderSql
FROM arch.Process p
WHERE p.ProcessCode IN (N'INTEGRACE_DNLOAD', N'INTEGRACE_UPLOAD')
ORDER BY p.ProcessCode;

SELECT
    p.ProcessCode,
    pks.KeyOrdinal,
    pks.KeyName,
    pks.SourceExpressionSql,
    pks.SqlType
FROM arch.Process p
JOIN arch.ProcessKeySpec pks
  ON pks.ProcessId = p.ProcessId
WHERE p.ProcessCode IN (N'INTEGRACE_DNLOAD', N'INTEGRACE_UPLOAD')
ORDER BY p.ProcessCode, pks.KeyOrdinal;

SELECT
    p.ProcessCode,
    os.SourceSchema,
    os.SourceTable,
    os.DeleteOrder,
    os.DeleteMode,
    os.TimestampExpr,
    os.JoinToAnchorPredicateSql,
    os.AdditionalWhereSql,
    os.ArchiveSchema,
    ArchiveTable = COALESCE(os.ArchiveTable, os.SourceTable),
    os.RequireArchiveForDelete,
    os.NaturalKeyLabel
FROM arch.ObjectSpec os
JOIN arch.Process p
  ON p.ProcessId = os.ProcessId
WHERE p.ProcessCode IN (N'INTEGRACE_DNLOAD', N'INTEGRACE_UPLOAD')
ORDER BY p.ProcessCode, os.DeleteOrder;

SELECT
    p.ProcessCode,
    ir.RequirementType,
    ObjectName = QUOTENAME(ir.SourceSchema) + N'.' + QUOTENAME(ir.SourceTable),
    ir.KeyColumnsCsv,
    ir.IsMandatory,
    ir.Notes
FROM arch.IndexRequirement ir
JOIN arch.Process p
  ON p.ProcessId = ir.ProcessId
WHERE p.ProcessCode IN (N'INTEGRACE_DNLOAD', N'INTEGRACE_UPLOAD')
ORDER BY p.ProcessCode, ir.RequirementType, ir.SourceSchema, ir.SourceTable;
GO
