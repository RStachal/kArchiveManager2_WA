USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
/* ============================================================================
   057 — Mode=2: COPY-ONLY (idempotent backup, no delete)
   ----------------------------------------------------------------------------
   Adds a third processing mode alongside Mode=1 (archive+delete) and Mode=0 (delete-only):

     Mode=2 COPY-ONLY — copy the candidate rows into the archive but NEVER delete from the source,
     inserting only rows that are not already in the archive ("backup if not exists"). It is
     non-destructive and idempotent: a re-run copies only newly-eligible rows. Dedup is by the
     SOURCE PRIMARY KEY (the archive is a column-copy, so the PK columns are present there); a
     non-clustered dedup index is ensured on the archive so the NOT EXISTS stays fast on large sets.

   This script:
     1. widens the Mode CHECK on arch.Process and arch.ProcessDatabase to admit 2 (idempotent);
     2. adds arch.usp_GetCopyDedupInfo — derives the PK NOT-EXISTS predicate for the copy and ensures
        the archive dedup index. Used by the runners (015 / 027) for Mode=2.

   The runners (014/015/027), usp_ValidateConfiguration and usp_GetOutputColumns are updated separately
   to honor Mode=2. A source table WITHOUT a primary key cannot be copied idempotently -> THROW 50220.

   SEMANTICS & LIMITATIONS (Mode=2):
     - RowsArchived (RunItem/RunItemObject) = rows ACTUALLY copied this run; it is the authoritative
       "what was processed" count. DocsDone = candidates considered, and RunDocAudit (ROW audit only)
       records Archived=1 for each candidate confirmed in the archive. On an idempotent re-run the
       NOT EXISTS copies 0 rows (RowsArchived=0) while DocsDone reflects the rescanned candidates — so
       read RowsArchived, not DocsDone, to see how much was newly backed up.
     - The dedup index is NON-unique on purpose: an archive shared with Mode=1 history can legitimately
       hold more than one row per source PK (a key deleted, recreated, deleted again). Dedup is enforced
       by the per-statement NOT EXISTS; same-object copy runs are already serialized (TIMESTAMP applock /
       single open ANCHOR WorkBatch), so concurrent duplicate inserts do not occur in normal operation.
     - Collation: the archive PK columns must share the source collation for the a.[pk]=t.[pk] dedup.
       That holds for archives provisioned by usp_EnsureArchiveTableLikeSource (it copies source collation),
       which Mode=2 always runs first.
   ============================================================================ */

/* ---- 1) widen the Mode domain to {0,1,2} ---------------------------------- */
IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Process_Mode' AND parent_object_id = OBJECT_ID(N'arch.Process'))
        ALTER TABLE [arch].[Process] DROP CONSTRAINT [CK_Process_Mode];
    ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_Mode] CHECK ([Mode] IN (0, 1, 2));  -- 0 delete-only, 1 archive+delete, 2 copy-only
END
GO
IF OBJECT_ID(N'arch.ProcessDatabase', N'U') IS NOT NULL
BEGIN
    -- The Mode domain on arch.ProcessDatabase is NOT a standalone constraint — it is ONE clause inside the
    -- composite CK_ProcessDatabase_OverrideLimits. Drop it BY EXACT NAME and recreate it IN FULL with every
    -- other override validation preserved verbatim and only the Mode clause widened to {0,1,2}.
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ProcessDatabase_OverrideLimits' AND parent_object_id = OBJECT_ID(N'arch.ProcessDatabase'))
        ALTER TABLE [arch].[ProcessDatabase] DROP CONSTRAINT [CK_ProcessDatabase_OverrideLimits];
    ALTER TABLE [arch].[ProcessDatabase] WITH CHECK ADD CONSTRAINT [CK_ProcessDatabase_OverrideLimits] CHECK
    (
        ([Mode] IS NULL OR [Mode] IN (0, 1, 2))
        AND ([RetentionDays] IS NULL OR [RetentionDays] >= 0)
        AND ([CutoffSafetyLagMinutes] IS NULL OR [CutoffSafetyLagMinutes] >= 0)
        AND ([CutoffMode] IS NULL OR [CutoffMode] IN (0, 1))
        AND ([BatchDocCount] IS NULL OR [BatchDocCount] > 0)
        AND ([BatchRowCount] IS NULL OR [BatchRowCount] > 0)
        AND ([MaxBatchesPerRun] IS NULL OR [MaxBatchesPerRun] > 0)
        AND ([DelayMsBetweenBatches] IS NULL OR [DelayMsBetweenBatches] >= 0)
        AND ([LockTimeoutMs] IS NULL OR [LockTimeoutMs] >= 0)
        AND ([DeadlockPriority] IS NULL OR [DeadlockPriority] IN (N'LOW', N'NORMAL', N'HIGH'))
        AND ([AuditLevel] IS NULL OR [AuditLevel] IN (N'NONE', N'BATCH', N'OBJECT', N'ROW'))
        AND ([MaxRowsPerTransaction] IS NULL OR [MaxRowsPerTransaction] > 0)
    );
END
GO

/* ---- 2) copy-only dedup helper -------------------------------------------- */
CREATE OR ALTER PROCEDURE [arch].[usp_GetCopyDedupInfo]
    @SourceDb      sysname,
    @SourceSchema  sysname,
    @SourceTable   sysname,
    @ArchiveDb     sysname,
    @ArchiveSchema sysname,
    @ArchiveTable  sysname,
    @SourceAlias   sysname = N't',
    @ArchiveAlias  sysname = N'a',
    @EnsureIndex   bit = 1,
    @PkPredicate   nvarchar(max) OUTPUT     -- 'a.[c1] = t.[c1] AND a.[c2] = t.[c2]' (archiveAlias.col = sourceAlias.col)
AS
BEGIN
    SET NOCOUNT ON;
    SET @PkPredicate = NULL;

    DECLARE @srcFq nvarchar(512) = QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@SourceSchema) + N'.' + QUOTENAME(@SourceTable);
    DECLARE @pkCsv nvarchar(max) = NULL, @pred nvarchar(max) = NULL;

    -- source PRIMARY KEY columns: the dedup identity (present in the archive, which is a column-copy)
    DECLARE @q nvarchar(max) = N'
        SELECT @cols = STUFF((SELECT N'','' + QUOTENAME(c.name)
                              FROM ' + QUOTENAME(@SourceDb) + N'.sys.index_columns ic
                              JOIN ' + QUOTENAME(@SourceDb) + N'.sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                              WHERE ic.object_id = OBJECT_ID(@fq) AND ic.index_id = @pkid
                              ORDER BY ic.key_ordinal FOR XML PATH(''''), TYPE).value(''.'',''nvarchar(max)''), 1, 1, N''''),
               @pp   = STUFF((SELECT N'' AND '' + @aa + N''.'' + QUOTENAME(c.name) + N'' = '' + @sla + N''.'' + QUOTENAME(c.name)
                              FROM ' + QUOTENAME(@SourceDb) + N'.sys.index_columns ic
                              JOIN ' + QUOTENAME(@SourceDb) + N'.sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                              WHERE ic.object_id = OBJECT_ID(@fq) AND ic.index_id = @pkid
                              ORDER BY ic.key_ordinal FOR XML PATH(''''), TYPE).value(''.'',''nvarchar(max)''), 1, 5, N'''')
        FROM (SELECT 1 x) z;';

    -- find the PK index_id first (separate so the OBJECT_ID/index lookup is in the source DB)
    DECLARE @pkid int;
    DECLARE @qid nvarchar(max) = N'SELECT @id = index_id FROM ' + QUOTENAME(@SourceDb) + N'.sys.indexes WHERE object_id = OBJECT_ID(@fq) AND is_primary_key = 1;';
    EXEC sys.sp_executesql @qid, N'@fq nvarchar(512), @id int OUTPUT', @fq = @srcFq, @id = @pkid OUTPUT;

    IF @pkid IS NULL
        THROW 50220, 'Copy-only (Mode=2) requires a PRIMARY KEY on the source table for idempotent dedup; none was found.', 1;

    EXEC sys.sp_executesql @q,
         N'@fq nvarchar(512), @pkid int, @aa sysname, @sla sysname, @cols nvarchar(max) OUTPUT, @pp nvarchar(max) OUTPUT',
         @fq = @srcFq, @pkid = @pkid, @aa = @ArchiveAlias, @sla = @SourceAlias, @cols = @pkCsv OUTPUT, @pp = @pred OUTPUT;

    IF NULLIF(@pred, N'') IS NULL
        THROW 50221, 'Copy-only (Mode=2): could not derive the source primary-key dedup predicate.', 1;

    SET @PkPredicate = @pred;

    -- ensure a dedup index on the archive (same PK columns) so the per-batch NOT EXISTS stays fast
    IF @EnsureIndex = 1 AND NULLIF(@pkCsv, N'') IS NOT NULL
    BEGIN
        DECLARE @ixName sysname = N'IX_kAMCopyDedup';
        DECLARE @aSchObj nvarchar(512) = QUOTENAME(@ArchiveSchema) + N'.' + QUOTENAME(@ArchiveTable);
        DECLARE @ix nvarchar(max) = N'USE ' + QUOTENAME(@ArchiveDb) + N';
            IF OBJECT_ID(@aobj) IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = @ixn AND object_id = OBJECT_ID(@aobj))
                CREATE NONCLUSTERED INDEX ' + QUOTENAME(@ixName) + N' ON ' + @aSchObj + N' (' + @pkCsv + N');';
        BEGIN TRY
            EXEC sys.sp_executesql @ix, N'@aobj nvarchar(512), @ixn sysname', @aobj = @aSchObj, @ixn = @ixName;
        END TRY
        BEGIN CATCH
            -- non-fatal: the copy still works without the index (just slower); surface as info, do not block.
            PRINT 'usp_GetCopyDedupInfo: could not ensure archive dedup index on ' + @aSchObj + ' (' + ERROR_MESSAGE() + ').';
        END CATCH
    END
END
GO
IF DATABASE_PRINCIPAL_ID(N'karch_runtime') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_GetCopyDedupInfo] TO [karch_runtime];
GO
PRINT '057_copy_only_mode deployed (Mode IN {0,1,2}; arch.usp_GetCopyDedupInfo).';
GO
