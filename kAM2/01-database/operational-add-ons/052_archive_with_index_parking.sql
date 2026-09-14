USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
/* ============================================================================
   052 — High-volume TIMESTAMP archive with SOURCE INDEX PARKING (perf, backlog drains)
   ----------------------------------------------------------------------------
   WHY: per the 10M RF_LOG2 measurement, ~98% of the runtime is per-row physical work; the source
   DELETE maintains the clustered PK + EVERY nonclustered index on the table (RF_LOG2 has ~16) — that
   is ~17 logged index-maintenance ops per deleted row. The runner needs only TWO of them: the
   candidate-selection index (leading column = the timestamp) and the clustered PK (used by the
   delete join on the key). Parking (DISABLE) the rest for the run, then REBUILD, removes the
   maintenance of the parked indexes from every delete. It is especially strong for BACKLOG DRAINS:
   you delete most rows, so the post-run REBUILD only has to (re)build over the few survivors.

   SAFETY: never disables clustered / primary-key / unique-constraint indexes. The candidate index
   you pass in @KeepIndexesCsv stays enabled (required — refuses to run without it, so it can never
   disable the index the run depends on). Indexes are rebuilt in a CATCH-protected finally, so they
   are ALWAYS restored even if the archive fails. Run in a MAINTENANCE WINDOW — parked nonclustered
   indexes degrade concurrent queries on the source table until rebuilt.

   This is a DBA/maintenance helper: the caller needs ALTER on the source table (sysadmin / db_owner
   on the source DB), beyond the karch_* runtime roles.
   ============================================================================ */
CREATE OR ALTER PROCEDURE [arch].[usp_RunTimestampProcessParked]
    @ProcessCode    sysname,
    @SourceDb       sysname,
    @ArchiveDb      sysname,
    @KeepIndexesCsv nvarchar(max),                 -- REQUIRED: nonclustered index(es) to KEEP enabled (the candidate-selection index)
    @MaxRows        int = NULL,
    @BatchRowCount  int = NULL,
    @StopAtUtc      datetime2(0) = NULL,
    @DryRun         bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@KeepIndexesCsv)), N'') IS NULL
        THROW 50700, '@KeepIndexesCsv is required (the candidate-selection index to keep enabled). Refusing to run so the index the candidate scan needs is never parked.', 1;
    IF DB_ID(@SourceDb) IS NULL  THROW 50703, 'Source database does not exist.', 1;

    /* candidate source table = first enabled ObjectSpec by DeleteOrder (what the runner builds its keyset from) */
    DECLARE @schema sysname, @table sysname;
    SELECT TOP (1) @schema = os.SourceSchema, @table = os.SourceTable
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE e.ProcessCode = @ProcessCode AND e.SourceDb = @SourceDb AND e.ArchiveDb = @ArchiveDb
      AND os.ObjectIsEnabled = 1
    ORDER BY os.DeleteOrder, os.ObjectSpecId;
    IF @table IS NULL THROW 50701, 'No enabled candidate ObjectSpec for the process/source/archive mapping.', 1;

    DECLARE @srcFq nvarchar(512) = QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table);

    /* park-able indexes: nonclustered, NOT pk / unique-constraint, currently enabled, not in the keep-list */
    CREATE TABLE #idx (name sysname NOT NULL);
    DECLARE @collect nvarchar(max) = N'
INSERT #idx(name)
SELECT i.name
FROM ' + QUOTENAME(@SourceDb) + N'.sys.indexes i
WHERE i.object_id = OBJECT_ID(@fq)
  AND i.type = 2 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND i.is_disabled = 0
  AND i.name IS NOT NULL
  AND i.name COLLATE DATABASE_DEFAULT NOT IN (SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@keep, N'',''));';
    EXEC sys.sp_executesql @collect, N'@fq nvarchar(512), @keep nvarchar(max)', @fq = @srcFq, @keep = @KeepIndexesCsv;

    DECLARE @parked int = (SELECT COUNT(*) FROM #idx);
    DECLARE @disable nvarchar(max) = N'', @rebuild nvarchar(max) = N'';
    SELECT @disable = @disable + N'ALTER INDEX ' + QUOTENAME(name) + N' ON ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table) + N' DISABLE;' + CHAR(10),
           @rebuild = @rebuild + N'ALTER INDEX ' + QUOTENAME(name) + N' ON ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table) + N' REBUILD;' + CHAR(10)
    FROM #idx;

    DECLARE @t0 datetime2(3), @parkSec int = 0, @archiveSec int = 0, @rebuildSec int = 0, @err nvarchar(max) = NULL;

    /* 1) PARK (disable) the non-essential nonclustered indexes (cross-DB via USE in the dynamic batch) */
    SET @t0 = SYSUTCDATETIME();
    IF @DryRun = 0 AND @disable <> N''
    BEGIN
        DECLARE @parkSql nvarchar(max) = N'USE ' + QUOTENAME(@SourceDb) + N'; ' + @disable;
        EXEC (@parkSql);   -- EXEC cannot concatenate function calls; build the string first
    END;
    SET @parkSec = DATEDIFF(SECOND, @t0, SYSUTCDATETIME());

    /* 2) ARCHIVE — protected so the indexes are ALWAYS rebuilt afterwards */
    SET @t0 = SYSUTCDATETIME();
    BEGIN TRY
        EXEC arch.usp_RunTimestampProcess
             @ProcessCode = @ProcessCode, @SourceDb = @SourceDb, @ArchiveDb = @ArchiveDb,
             @MaxRows = @MaxRows, @BatchRowCount = @BatchRowCount, @StopAtUtc = @StopAtUtc, @DryRun = @DryRun;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_MESSAGE();
    END CATCH
    SET @archiveSec = DATEDIFF(SECOND, @t0, SYSUTCDATETIME());

    /* 3) REBUILD (re-enable) the parked indexes — ALWAYS, even if the archive failed */
    SET @t0 = SYSUTCDATETIME();
    IF @DryRun = 0 AND @rebuild <> N''
    BEGIN
        DECLARE @rebuildSql nvarchar(max) = N'USE ' + QUOTENAME(@SourceDb) + N'; ' + @rebuild;
        EXEC (@rebuildSql);
    END;
    SET @rebuildSec = DATEDIFF(SECOND, @t0, SYSUTCDATETIME());

    SELECT SourceObject = @srcFq,
           IndexesParked = @parked,
           ParkSeconds = @parkSec,
           ArchiveSeconds = @archiveSec,
           RebuildSeconds = @rebuildSec,
           TotalSeconds = @parkSec + @archiveSec + @rebuildSec,
           ArchiveError = @err;

    IF @err IS NOT NULL
        THROW 50702, 'Archive phase failed (the parked indexes were rebuilt); see the ArchiveError column.', 1;
END
GO
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_RunTimestampProcessParked] TO [karch_advanced_admin];
GO
PRINT '052_archive_with_index_parking deployed (arch.usp_RunTimestampProcessParked).';
GO
