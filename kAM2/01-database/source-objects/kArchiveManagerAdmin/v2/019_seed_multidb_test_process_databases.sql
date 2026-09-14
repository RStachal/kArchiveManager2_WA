USE [kArchiveManagerAdmin]
GO

SET NOCOUNT ON;
GO

IF OBJECT_ID(N'arch.ProcessDatabase', N'U') IS NULL
BEGIN
    RAISERROR(N'arch.ProcessDatabase does not exist. Run the base table scripts first.', 16, 1);
    RETURN;
END
GO

IF COL_LENGTH(N'arch.Process', N'SelectionStrategy') IS NULL
BEGIN
    RAISERROR(N'2.0 metadata is not installed. Run v2/010_universal_archive_core.sql first.', 16, 1);
    RETURN;
END
GO

DECLARE @DatabaseMap table
(
    SourceDb sysname NOT NULL PRIMARY KEY,
    ArchiveDb sysname NOT NULL,
    DbRunOrder int NOT NULL
);

INSERT INTO @DatabaseMap(SourceDb, ArchiveDb, DbRunOrder)
VALUES
    (N'Edge',      N'kArchiveManagerBackups', 1000),
    (N'KMWEBV',    N'kArchiveManagerBackups', 2000),
    (N'KMWE_Test', N'kArchiveManagerBackups', 3000);

DECLARE @ProcessMap table
(
    ProcessCode sysname NOT NULL PRIMARY KEY,
    ProcessRunOrder int NOT NULL
);

INSERT INTO @ProcessMap(ProcessCode, ProcessRunOrder)
VALUES
    (N'RECEIVING',         10),
    (N'SHIPPING',          20),
    (N'RF_LOG2',           30),
    (N'INTEGRACE_DNLOAD',  40),
    (N'INTEGRACE_UPLOAD',  50);

IF EXISTS
(
    SELECT 1
    FROM @DatabaseMap dm
    WHERE DB_ID(dm.SourceDb) IS NULL
)
BEGIN
    SELECT dm.SourceDb
    FROM @DatabaseMap dm
    WHERE DB_ID(dm.SourceDb) IS NULL
    ORDER BY dm.SourceDb;

    RAISERROR(N'At least one configured source database does not exist on this SQL instance.', 16, 1);
    RETURN;
END;

IF EXISTS
(
    SELECT 1
    FROM @DatabaseMap dm
    WHERE DB_ID(dm.ArchiveDb) IS NULL
)
BEGIN
    SELECT DISTINCT dm.ArchiveDb
    FROM @DatabaseMap dm
    WHERE DB_ID(dm.ArchiveDb) IS NULL
    ORDER BY dm.ArchiveDb;

    RAISERROR(N'At least one configured archive database does not exist on this SQL instance.', 16, 1);
    RETURN;
END;

IF EXISTS
(
    SELECT 1
    FROM @ProcessMap pm
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM arch.Process p
        WHERE p.ProcessCode = pm.ProcessCode
    )
)
BEGIN
    SELECT pm.ProcessCode
    FROM @ProcessMap pm
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM arch.Process p
        WHERE p.ProcessCode = pm.ProcessCode
    )
    ORDER BY pm.ProcessCode;

    RAISERROR(N'At least one configured process is missing. Run the process seed scripts first.', 16, 1);
    RETURN;
END;

UPDATE p
SET IsEnabled = 1,
    ModifiedAt = SYSUTCDATETIME()
FROM arch.Process p
JOIN @ProcessMap pm
  ON pm.ProcessCode = p.ProcessCode;

MERGE arch.ProcessDatabase AS tgt
USING
(
    SELECT
        p.ProcessId,
        dm.SourceDb,
        dm.ArchiveDb,
        IsEnabled = CONVERT(bit, 1),
        RunOrder = dm.DbRunOrder + pm.ProcessRunOrder
    FROM @DatabaseMap dm
    CROSS JOIN @ProcessMap pm
    JOIN arch.Process p
      ON p.ProcessCode = pm.ProcessCode
) AS src
ON tgt.ProcessId = src.ProcessId
AND tgt.SourceDb = src.SourceDb
AND tgt.ArchiveDb = src.ArchiveDb
WHEN MATCHED THEN UPDATE SET
    IsEnabled = src.IsEnabled,
    RunOrder = src.RunOrder,
    ModifiedAt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
(
    ProcessId,
    SourceDb,
    ArchiveDb,
    IsEnabled,
    RunOrder,
    CreatedAt,
    ModifiedAt
)
VALUES
(
    src.ProcessId,
    src.SourceDb,
    src.ArchiveDb,
    src.IsEnabled,
    src.RunOrder,
    SYSUTCDATETIME(),
    SYSUTCDATETIME()
);

SELECT
    p.ProcessCode,
    p.IsEnabled AS ProcessEnabled,
    p.SelectionStrategy,
    pd.SourceDb,
    pd.ArchiveDb,
    pd.IsEnabled AS MappingEnabled,
    pd.RunOrder
FROM arch.ProcessDatabase pd
JOIN arch.Process p
  ON p.ProcessId = pd.ProcessId
WHERE p.ProcessCode IN
(
    N'RECEIVING',
    N'SHIPPING',
    N'RF_LOG2',
    N'INTEGRACE_DNLOAD',
    N'INTEGRACE_UPLOAD'
)
  AND pd.SourceDb IN (N'Edge', N'KMWEBV', N'KMWE_Test')
ORDER BY pd.RunOrder, p.ProcessCode, pd.SourceDb;
GO
