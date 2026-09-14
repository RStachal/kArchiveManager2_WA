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
