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

UPDATE arch.Process
SET SelectionStrategy = N'ANCHOR',
    AuditLevel = N'BATCH',
    RequireSupportingIndex = 1,
    MaxRowsPerTransaction = NULL,
    ModifiedAt = SYSUTCDATETIME()
WHERE ProcessCode IN (N'RECEIVING', N'SHIPPING');
GO

MERGE arch.ProcessKeySpec AS tgt
USING
(
    SELECT
        p.ProcessId,
        KeyOrdinal = CONVERT(tinyint, 1),
        KeyName = CONVERT(sysname,
            CASE p.ProcessCode
                WHEN N'RECEIVING' THEN N'PO_NUM'
                WHEN N'SHIPPING' THEN N'PACKSLIP'
            END),
        SourceExpressionSql =
            CASE p.ProcessCode
                WHEN N'RECEIVING' THEN N'CONVERT(nvarchar(256), a.PO_NUM)'
                WHEN N'SHIPPING' THEN N'CONVERT(nvarchar(256), a.PACKSLIP)'
            END,
        SqlType = N'nvarchar(256)',
        IsRequired = CONVERT(bit, 1)
    FROM arch.Process p
    WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING')
) AS src
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
    src.ProcessId, src.KeyOrdinal, src.KeyName, src.SourceExpressionSql, src.SqlType, src.IsRequired, SYSUTCDATETIME(), SYSUTCDATETIME()
);
GO

DELETE ir
FROM arch.IndexRequirement ir
JOIN arch.Process p
  ON p.ProcessId = ir.ProcessId
WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING');
GO

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
    NULL,
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
    (N'RECEIVING', N'SELECTION', N'dbo', N'BACKRH',    N'DATE_CREAT,PO_NUM', NULL, NULL, CONVERT(bit, 1), N'Anchor selection should seek by retention cutoff and return PO_NUM in deterministic order.'),
    (N'RECEIVING', N'JOIN',      N'dbo', N'BACKRD',    N'PO_NUM',           NULL, NULL, CONVERT(bit, 1), N'Child table join to prepared candidate keyset.'),
    (N'RECEIVING', N'JOIN',      N'dbo', N'BACKRH',    N'PO_NUM',           NULL, NULL, CONVERT(bit, 1), N'Header delete/archive join to prepared candidate keyset.'),
    (N'SHIPPING',  N'SELECTION', N'dbo', N'SHIPHIST',  N'DATE_UPLD,PACKSLIP', NULL, NULL, CONVERT(bit, 1), N'Current timestamp expression uses COALESCE; prefer persisted computed cutoff column or reviewed native timestamp index.'),
    (N'SHIPPING',  N'JOIN',      N'dbo', N'SHIPDETL',  N'PACKSLIP',         NULL, NULL, CONVERT(bit, 1), N'Child table join to prepared candidate keyset.'),
    (N'SHIPPING',  N'JOIN',      N'dbo', N'SHIPDETL2', N'PACKSLIP',         NULL, NULL, CONVERT(bit, 1), N'Child table join to prepared candidate keyset.'),
    (N'SHIPPING',  N'JOIN',      N'dbo', N'SHIPMSTR',  N'PACKSLIP',         NULL, NULL, CONVERT(bit, 1), N'Child table join to prepared candidate keyset.'),
    (N'SHIPPING',  N'JOIN',      N'dbo', N'SHIPLINE',  N'PACKSLIP',         NULL, NULL, CONVERT(bit, 1), N'Child table join to prepared candidate keyset.'),
    (N'SHIPPING',  N'JOIN',      N'dbo', N'SHIPLINE2', N'PACKSLIP',         NULL, NULL, CONVERT(bit, 1), N'Child table join to prepared candidate keyset.'),
    (N'SHIPPING',  N'JOIN',      N'dbo', N'SHIPHIST',  N'PACKSLIP',         NULL, NULL, CONVERT(bit, 1), N'Header delete/archive join to prepared candidate keyset.')
) AS req(ProcessCode, RequirementType, SourceSchema, SourceTable, KeyColumnsCsv, IncludeColumnsCsv, FilterSql, IsMandatory, Notes)
WHERE p.ProcessCode = req.ProcessCode;
GO

SELECT
    p.ProcessCode,
    p.SelectionStrategy,
    p.AuditLevel,
    p.RequireSupportingIndex,
    pks.KeyOrdinal,
    pks.KeyName,
    pks.SourceExpressionSql
FROM arch.Process p
LEFT JOIN arch.ProcessKeySpec pks
  ON pks.ProcessId = p.ProcessId
WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING')
ORDER BY p.ProcessCode, pks.KeyOrdinal;
GO

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
WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING')
ORDER BY p.ProcessCode, ir.RequirementType, ir.SourceSchema, ir.SourceTable;
GO
