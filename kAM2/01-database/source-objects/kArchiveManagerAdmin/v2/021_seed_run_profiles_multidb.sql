USE [kArchiveManagerAdmin]
GO

SET NOCOUNT ON;
GO

IF OBJECT_ID(N'arch.RunProfile', N'U') IS NULL
BEGIN
    RAISERROR(N'arch.RunProfile does not exist. Run v2/010_universal_archive_core.sql first.', 16, 1);
    RETURN;
END
GO

MERGE arch.RunProfile AS tgt
USING
(
    SELECT *
    FROM (VALUES
        (N'JOB_DEFAULT',      N'Default scheduled run for all enabled ProcessDatabase mappings.', CONVERT(bit, 1), CONVERT(bit, 1),  10, CONVERT(nvarchar(128), NULL),        CONVERT(nvarchar(128), NULL),        CONVERT(nvarchar(128), NULL), 55, CONVERT(bit, 0), CONVERT(int, NULL), 60),
        (N'EDGE_ALL_20M',     N'Manual/concurrent run: all enabled processes for Edge.',         CONVERT(bit, 1), CONVERT(bit, 0), 100, CONVERT(nvarchar(128), NULL),        CONVERT(nvarchar(128), N'Edge'),      CONVERT(nvarchar(128), NULL), 20, CONVERT(bit, 0), CONVERT(int, NULL), 60),
        (N'KMWEBV_ALL_20M',   N'Manual/concurrent run: all enabled processes for KMWEBV.',       CONVERT(bit, 1), CONVERT(bit, 0), 110, CONVERT(nvarchar(128), NULL),        CONVERT(nvarchar(128), N'KMWEBV'),    CONVERT(nvarchar(128), NULL), 20, CONVERT(bit, 0), CONVERT(int, NULL), 60),
        (N'KMWE_TEST_ALL_20M',N'Manual/concurrent run: all enabled processes for KMWE_Test.',    CONVERT(bit, 1), CONVERT(bit, 0), 120, CONVERT(nvarchar(128), NULL),        CONVERT(nvarchar(128), N'KMWE_Test'), CONVERT(nvarchar(128), NULL), 20, CONVERT(bit, 0), CONVERT(int, NULL), 60),
        (N'RECEIVING_ALL_20M',N'Manual run: RECEIVING process across all enabled source DBs.',    CONVERT(bit, 1), CONVERT(bit, 0), 200, CONVERT(nvarchar(128), N'RECEIVING'), CONVERT(nvarchar(128), NULL),        CONVERT(nvarchar(128), NULL), 20, CONVERT(bit, 0), CONVERT(int, NULL), 60)
    ) AS v(RunProfileCode, Description, IsEnabled, RunOnSchedule, RunOrder, ProcessCodeFilter, SourceDbFilter, ArchiveDbFilter, RunWindowMinutes, DryRun, MaxCandidates, PausedCooldownSeconds)
) AS src
ON tgt.RunProfileCode = src.RunProfileCode
WHEN MATCHED THEN UPDATE SET
    Description = src.Description,
    IsEnabled = src.IsEnabled,
    RunOnSchedule = src.RunOnSchedule,
    RunOrder = src.RunOrder,
    ProcessCodeFilter = src.ProcessCodeFilter,
    SourceDbFilter = src.SourceDbFilter,
    ArchiveDbFilter = src.ArchiveDbFilter,
    RunWindowMinutes = src.RunWindowMinutes,
    DryRun = src.DryRun,
    MaxCandidates = src.MaxCandidates,
    PausedCooldownSeconds = src.PausedCooldownSeconds,
    ModifiedAt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
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
    src.RunProfileCode,
    src.Description,
    src.IsEnabled,
    src.RunOnSchedule,
    src.RunOrder,
    src.ProcessCodeFilter,
    src.SourceDbFilter,
    src.ArchiveDbFilter,
    src.RunWindowMinutes,
    src.DryRun,
    src.MaxCandidates,
    src.PausedCooldownSeconds,
    SYSUTCDATETIME(),
    SYSUTCDATETIME()
);

SELECT
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
    PausedCooldownSeconds
FROM arch.RunProfile
WHERE RunProfileCode IN
(
    N'JOB_DEFAULT',
    N'EDGE_ALL_20M',
    N'KMWEBV_ALL_20M',
    N'KMWE_TEST_ALL_20M',
    N'RECEIVING_ALL_20M'
)
ORDER BY RunOrder, RunProfileCode;
GO
