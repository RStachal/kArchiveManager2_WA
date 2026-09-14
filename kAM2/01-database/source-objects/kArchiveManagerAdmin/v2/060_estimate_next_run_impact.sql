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
