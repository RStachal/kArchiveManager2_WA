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
