USE [kArchiveManagerAdmin]
GO
SET NOCOUNT ON;
GO

DECLARE @DefaultSourceDb sysname = N'KMWEBV';
DECLARE @DefaultArchiveDb sysname = N'kArchiveManagerBackups';

MERGE arch.ProcessDatabase AS tgt
USING
(
    SELECT
        p.ProcessId,
        @DefaultSourceDb AS SourceDb,
        @DefaultArchiveDb AS ArchiveDb,
        CAST(1 AS bit) AS IsEnabled,
        CASE p.ProcessCode
            WHEN N'RECEIVING' THEN 10
            WHEN N'SHIPPING' THEN 20
            WHEN N'RF_LOG2' THEN 30
            ELSE 100
        END AS RunOrder
    FROM arch.Process p
    WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING', N'RF_LOG2')
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
GO

SELECT
    p.ProcessCode,
    pd.SourceDb,
    pd.ArchiveDb,
    pd.IsEnabled,
    pd.RunOrder
FROM arch.ProcessDatabase pd
JOIN arch.Process p
  ON p.ProcessId = pd.ProcessId
ORDER BY pd.RunOrder, p.ProcessCode, pd.SourceDb;
GO
