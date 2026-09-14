USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_RunPreparedBatch]
    @WorkBatchId bigint,
    @StopAtUtc   datetime2(0),
    @DryRun      bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
    BEGIN
        RAISERROR(N'2.0 metadata is not installed. Run v2/010_universal_archive_core.sql first.', 16, 1);
        RETURN;
    END;

    DECLARE
        @ProcessId int,
        @ProcessDatabaseId int,
        @ProcessCode sysname,
        @SourceDb sysname,
        @ArchiveDb sysname,
        @Mode tinyint,
        @SelectionStrategy nvarchar(30),
        @AuditLevel nvarchar(20),
        @BatchDocCount int,
        @BatchRowCount int,
        @MaxRowsPerTransaction int,
        @BatchUnitCount int,
        @LockTimeoutMs int,
        @DeadlockPriority nvarchar(10),
        @DocKeyLabel nvarchar(50),
        @AllowDelNoArch bit,
        @RangeToUtc datetime2(0),
        @RunId bigint = NULL,
        @RunItemId bigint = NULL;

    SELECT
        @ProcessId = wb.ProcessId,
        @SourceDb = wb.SourceDb,
        @ArchiveDb = wb.ArchiveDb,
        @Mode = wb.ModeSnapshot,
        @RangeToUtc = wb.RangeToUtc
    FROM arch.WorkBatch wb
    WHERE wb.WorkBatchId = @WorkBatchId;

    IF @ProcessId IS NULL
    BEGIN
        RAISERROR(N'WorkBatchId not found: %I64d', 16, 1, @WorkBatchId);
        RETURN;
    END;

    SELECT
        @ProcessDatabaseId = e.ProcessDatabaseId,
        @ProcessCode = e.ProcessCode,
        @SelectionStrategy = COALESCE(e.SelectionStrategy, N'ANCHOR'),
        @AuditLevel = COALESCE(e.AuditLevel, N'BATCH'),
        @BatchDocCount = e.BatchDocCount,
        @BatchRowCount = e.BatchRowCount,
        @MaxRowsPerTransaction = e.MaxRowsPerTransaction,
        @LockTimeoutMs = COALESCE(e.LockTimeoutMs, 10000),
        @DeadlockPriority = COALESCE(e.DeadlockPriority, N'LOW'),
        @DocKeyLabel = COALESCE(NULLIF(e.DocKeyLabel, N''), N'DOCKEY'),
        @AllowDelNoArch = COALESCE(e.AllowDeleteWithoutArchive, 0)
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessId = @ProcessId
      AND e.SourceDb = @SourceDb
      AND e.ArchiveDb = @ArchiveDb
      AND e.IsEnabled = 1;

    IF @ProcessCode IS NULL
    BEGIN
        RAISERROR(N'ProcessId not found in arch.Process: %d', 16, 1, @ProcessId);
        RETURN;
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM arch.v_ObjectSpecDatabaseEffective
        WHERE ProcessDatabaseId = @ProcessDatabaseId
          AND ObjectIsEnabled = 1
    )
    BEGIN
        RAISERROR(N'No ObjectSpec rows found for process: %s', 16, 1, @ProcessCode);
        RETURN;
    END;

    -- P0.5 Risk K1 gate: block real deletes when the cutoff expression is not
    -- UTC-normalized (AT TIME ZONE). Dry-runs (@DryRun=1) are exempt so candidate
    -- previews keep working before the timezone policy is applied. THROW 50200.
    IF @DryRun = 0
        EXEC arch.usp_AssertTimezonePolicyApplied
             @ProcessId = @ProcessId,
             @SourceDb  = @SourceDb,
             @ArchiveDb = @ArchiveDb;

    -- T-21 retention floor (ANCHOR cutoff snapshot = WorkBatch.RangeToUtc); DryRun exempt. THROW 50210.
    -- (Primary enforcement is at PREPARE time in 014; this is defense if the floor was raised after prep.)
    -- OBJECT_ID-guarded for graceful degradation when 056 is not deployed.
    IF @DryRun = 0 AND OBJECT_ID(N'arch.usp_AssertRetentionFloor', N'P') IS NOT NULL
        EXEC arch.usp_AssertRetentionFloor
             @ProcessId = @ProcessId,
             @SourceDb  = @SourceDb,
             @ArchiveDb = @ArchiveDb,
             @CutoffUtc = @RangeToUtc;

    -- T-05 runtime re-assert (audit hardening): the Save* API procs validate these fragments at SAVE
    -- time, but a direct DBA write to arch.ObjectSpec(+overrides) bypasses the API. Re-assert every
    -- config-sourced fragment once up front (not per batch) before it is concatenated into the dynamic
    -- DELETE/COPY. OBJECT_ID-guarded for graceful degradation. THROW 50400.
    IF OBJECT_ID(N'arch.usp_AssertSafeSqlExpression', N'P') IS NOT NULL
    BEGIN
        DECLARE @vExpr nvarchar(4000), @vField nvarchar(128);
        DECLARE cVal CURSOR LOCAL FAST_FORWARD FOR
            SELECT os.JoinToAnchorPredicateSql, N'ObjectSpec.JoinToAnchorPredicateSql'
            FROM arch.v_ObjectSpecDatabaseEffective os
            WHERE os.ProcessDatabaseId = @ProcessDatabaseId AND os.ObjectIsEnabled = 1
            UNION ALL
            SELECT os.AdditionalWhereSql, N'ObjectSpec.AdditionalWhereSql'
            FROM arch.v_ObjectSpecDatabaseEffective os
            WHERE os.ProcessDatabaseId = @ProcessDatabaseId AND os.ObjectIsEnabled = 1
            UNION ALL
            SELECT os.TimestampExpr, N'ObjectSpec.TimestampExpr'
            FROM arch.v_ObjectSpecDatabaseEffective os
            WHERE os.ProcessDatabaseId = @ProcessDatabaseId AND os.ObjectIsEnabled = 1;
        OPEN cVal;
        FETCH NEXT FROM cVal INTO @vExpr, @vField;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC arch.usp_AssertSafeSqlExpression @vExpr, @vField;
            FETCH NEXT FROM cVal INTO @vExpr, @vField;
        END;
        CLOSE cVal;
        DEALLOCATE cVal;
    END;

    SET @BatchUnitCount =
        CASE
            WHEN @SelectionStrategy = N'TIMESTAMP' THEN COALESCE(@BatchRowCount, @BatchDocCount, 4000)
            ELSE COALESCE(@BatchDocCount, @BatchRowCount, 25)
        END;

    IF @MaxRowsPerTransaction IS NOT NULL
       AND @MaxRowsPerTransaction > 0
       AND @MaxRowsPerTransaction < @BatchUnitCount
        SET @BatchUnitCount = @MaxRowsPerTransaction;

    -- SAFETY (source lock-escalation guard): a single per-batch DELETE of more than ~5000 rows escalates
    -- its row locks to a TABLE X lock on the PRODUCTION source, blocking OLTP for the batch duration
    -- (proven live). Hard-cap the per-transaction unit for EVERY strategy (this proc runs the ANCHOR
    -- prepared-batch path, where @BatchUnitCount is documents; capping it bounds the claim size — note that
    -- a document with many detail rows can still delete >cap ROWS per object table, so ANCHOR processes
    -- must also keep BatchDocCount conservative). Larger volumes still process fully via more batches.
    IF @BatchUnitCount > 4000
        SET @BatchUnitCount = 4000;

    IF @BatchUnitCount <= 0
    BEGIN
        RAISERROR(N'Effective prepared-batch size must be greater than zero for process: %s', 16, 1, @ProcessCode);
        RETURN;
    END;

    IF @DeadlockPriority = N'LOW' SET DEADLOCK_PRIORITY LOW;
    ELSE IF @DeadlockPriority = N'HIGH' SET DEADLOCK_PRIORITY HIGH;
    ELSE SET DEADLOCK_PRIORITY NORMAL;

    DECLARE @LockTimeoutStmt nvarchar(80) = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(20), @LockTimeoutMs) + N';';
    EXEC(@LockTimeoutStmt);

    UPDATE arch.WorkBatch
    SET Status = CASE WHEN Status IN ('Prepared','Paused') THEN 'Running' ELSE Status END,
        StartedAtUtc = COALESCE(StartedAtUtc, SYSUTCDATETIME())
    WHERE WorkBatchId = @WorkBatchId;

    UPDATE arch.WorkBatchKey
    SET Status = 0, ClaimedAtUtc = NULL, ClaimedBy = NULL
    WHERE WorkBatchId = @WorkBatchId
      AND Status = 1
      AND ClaimedAtUtc < DATEADD(HOUR, -2, SYSUTCDATETIME());

    CREATE TABLE #Claimed
    (
        Key1 nvarchar(256) NOT NULL,
        Key2 nvarchar(256) NOT NULL,
        Key3 nvarchar(256) NOT NULL,
        Key4 nvarchar(256) NOT NULL,
        Key5 nvarchar(256) NOT NULL,
        Key6 nvarchar(256) NOT NULL,
        Key7 nvarchar(256) NOT NULL,
        Key8 nvarchar(256) NOT NULL,
        AnchorRowGuid uniqueidentifier NULL,
        DocCreatedAt datetime2(0) NULL,
        CandidateHash varbinary(32) NULL
    );

    -- T-03: stamp the worker's session identity so usp_RecoverStaleRuns can tell a live run from a
    -- dead one and never recover a run whose worker session is still executing.
    INSERT INTO arch.Run(SourceDb, ArchiveDb, HostName, AppName, InitiatedBy, WorkerSessionId, WorkerSessionLoginTimeUtc)
    VALUES (@SourceDb, @ArchiveDb, HOST_NAME(), APP_NAME(), SUSER_SNAME(),
            @@SPID, (SELECT login_time FROM sys.dm_exec_sessions WHERE session_id = @@SPID));
    SET @RunId = SCOPE_IDENTITY();

    INSERT INTO arch.RunItem(RunId, ProcessId, AsOfUtc, CutoffUtc, Mode)
    VALUES (@RunId, @ProcessId, SYSUTCDATETIME(), @RangeToUtc, @Mode);
    SET @RunItemId = SCOPE_IDENTITY();

    BEGIN TRY
        -- Perf: resolve the per-object effective config ONCE up front, not per batch. The per-object cursor
        -- below previously re-queried arch.v_ObjectSpecDatabaseEffective (Process+ProcessDatabase+ObjectSpec
        -- +override COALESCE join) on EVERY batch iteration; that config is static for the run, so cache it
        -- into #Obj and iterate the temp table. Mirrors the #Obj pattern already used by 027. Reduces both
        -- complexity (no repeated view join) and cost (~10-15% on multi-object, high-batch-count runs).
        CREATE TABLE #Obj
        (
            Seq int IDENTITY(1,1) NOT NULL PRIMARY KEY,
            SourceSchema sysname NOT NULL,
            SourceTable sysname NOT NULL,
            DeleteMode tinyint NOT NULL,
            JoinSql nvarchar(4000) NULL,
            AddWhere nvarchar(4000) NULL,
            ArchiveSchema nvarchar(128) NOT NULL,
            ArchiveTable sysname NOT NULL,
            RequireArchiveForDelete bit NULL
        );
        INSERT INTO #Obj (SourceSchema, SourceTable, DeleteMode, JoinSql, AddWhere, ArchiveSchema, ArchiveTable, RequireArchiveForDelete)
        SELECT
            os.SourceSchema,
            os.SourceTable,
            os.DeleteMode,
            os.JoinToAnchorPredicateSql,
            os.AdditionalWhereSql,
            CONVERT(nvarchar(128), REPLACE(
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo' THEN N'{SourceDb}'
                    ELSE LTRIM(RTRIM(os.ArchiveSchema))
                END,
                N'{SourceDb}', @SourceDb)),
            COALESCE(os.ArchiveTable, os.SourceTable),
            os.RequireArchiveForDelete
        FROM arch.v_ObjectSpecDatabaseEffective os
        WHERE os.ProcessDatabaseId = @ProcessDatabaseId
          AND os.ObjectIsEnabled = 1
        ORDER BY os.DeleteOrder;

        WHILE SYSUTCDATETIME() < @StopAtUtc
        BEGIN
            -- Cooperative cancel (040): operator requested a stop. The previous batch is
            -- committed and remaining WorkBatchKeys stay claimable, so the WorkBatch is left
            -- 'Paused' below and can resume later. The run ends with Status='STOPPED'.
            IF EXISTS (SELECT 1 FROM arch.Run WHERE RunId = @RunId AND CancelRequestedAtUtc IS NOT NULL)
                BREAK;

            DELETE FROM #Claimed;

            ;WITH cte AS
            (
                SELECT TOP (@BatchUnitCount) *
                FROM arch.WorkBatchKey WITH (UPDLOCK, READPAST, ROWLOCK)
                WHERE WorkBatchId = @WorkBatchId
                  AND Status = 0
                ORDER BY DocCreatedAt, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8
            )
            UPDATE cte
            SET Status = 1,
                Attempts = Attempts + 1,
                ClaimedAtUtc = SYSUTCDATETIME(),
                ClaimedBy = SUSER_SNAME(),
                ErrorMessage = NULL
            OUTPUT
                inserted.Key1,
                inserted.Key2,
                inserted.Key3,
                inserted.Key4,
                inserted.Key5,
                inserted.Key6,
                inserted.Key7,
                inserted.Key8,
                inserted.AnchorRowGuid,
                inserted.DocCreatedAt,
                inserted.CandidateHash
            INTO #Claimed
            (
                Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8,
                AnchorRowGuid, DocCreatedAt, CandidateHash
            );

            IF NOT EXISTS (SELECT 1 FROM #Claimed)
                BREAK;

            IF @DryRun = 1
            BEGIN
                SELECT TOP (100)
                    Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, DocCreatedAt, CandidateHash
                FROM #Claimed
                ORDER BY DocCreatedAt, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8;

                UPDATE k
                SET Status = 0, ClaimedAtUtc = NULL, ClaimedBy = NULL
                FROM arch.WorkBatchKey k
                JOIN #Claimed c
                  ON c.Key1 = k.Key1
                 AND c.Key2 = k.Key2
                 AND ISNULL(c.CandidateHash, 0x) = ISNULL(k.CandidateHash, 0x)
                WHERE k.WorkBatchId = @WorkBatchId;

                UPDATE arch.RunItem
                SET BatchesDone = BatchesDone + 1,
                    DocsDone = DocsDone + (SELECT COUNT(*) FROM #Claimed),
                    Status = N'DRYRUN',
                    EndedAt = SYSUTCDATETIME()
                WHERE RunItemId = @RunItemId;

                UPDATE arch.Run
                SET Status = N'DRYRUN',
                    EndedAt = SYSUTCDATETIME()
                WHERE RunId = @RunId;

                UPDATE arch.WorkBatch
                SET Status = 'Paused',
                    LastProgressAtUtc = SYSUTCDATETIME(),
                    Notes = N'DryRun preview only'
                WHERE WorkBatchId = @WorkBatchId;

                RETURN;
            END;

            CREATE TABLE #Keys
            (
                KeyId bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
                DocKey nvarchar(256) NOT NULL,
                DocKey2 nvarchar(256) NOT NULL,
                Key1 nvarchar(256) NOT NULL,
                Key2 nvarchar(256) NOT NULL,
                Key3 nvarchar(256) NOT NULL,
                Key4 nvarchar(256) NOT NULL,
                Key5 nvarchar(256) NOT NULL,
                Key6 nvarchar(256) NOT NULL,
                Key7 nvarchar(256) NOT NULL,
                Key8 nvarchar(256) NOT NULL,
                AnchorRowGuid uniqueidentifier NULL,
                DocCreatedAt datetime2(0) NULL,
                CandidateHash varbinary(32) NULL
            );

            DECLARE @SourceCollation sysname = CONVERT(sysname, DATABASEPROPERTYEX(@SourceDb, N'Collation'));
            IF @SourceCollation IS NOT NULL
            BEGIN
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN DocKey nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN DocKey2 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key1 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key2 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key3 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key4 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key5 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key6 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key7 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
                EXEC(N'ALTER TABLE #Keys ALTER COLUMN Key8 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
            END;

            INSERT INTO #Keys
            (
                DocKey, DocKey2, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8,
                AnchorRowGuid, DocCreatedAt, CandidateHash
            )
            SELECT
                Key1, Key2, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8,
                AnchorRowGuid, DocCreatedAt, CandidateHash
            FROM #Claimed;

            -- T-21 legal-hold (defense for a hold added AFTER this WorkBatch was prepared): a claimed key
            -- now under an active hold must NOT be deleted. Park it (WorkBatchKey Status=5) so it is neither
            -- deleted/archived, marked done, nor re-claimed, then drop it from this batch (#Keys/#Claimed).
            -- It returns as a fresh candidate at the next prepare once the hold is released. Guarded so a
            -- runner deployed without 056 degrades gracefully. (014 already excludes holds at prepare time.)
            IF OBJECT_ID(N'arch.LegalHold', N'U') IS NOT NULL
               AND EXISTS (SELECT 1 FROM arch.LegalHold lh
                           WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                             AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb))
            BEGIN
                UPDATE k
                SET Status = 5, ClaimedAtUtc = NULL, ClaimedBy = NULL,
                    ErrorMessage = N'LEGAL HOLD: excluded from deletion (hold added after prepare).'
                FROM arch.WorkBatchKey k
                JOIN #Claimed c
                  ON c.Key1 = k.Key1 AND c.Key2 = k.Key2 AND ISNULL(c.CandidateHash, 0x) = ISNULL(k.CandidateHash, 0x)
                WHERE k.WorkBatchId = @WorkBatchId
                  AND EXISTS (SELECT 1 FROM arch.LegalHold lh
                              WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                                AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb)
                                AND lh.HoldKey = k.Key1 COLLATE DATABASE_DEFAULT);

                DELETE kk FROM #Keys kk
                WHERE EXISTS (SELECT 1 FROM arch.LegalHold lh
                              WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                                AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb)
                                AND lh.HoldKey = kk.Key1 COLLATE DATABASE_DEFAULT);

                DELETE c FROM #Claimed c
                WHERE EXISTS (SELECT 1 FROM arch.LegalHold lh
                              WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                                AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb)
                                AND lh.HoldKey = c.Key1 COLLATE DATABASE_DEFAULT);
            END;

            BEGIN TRAN;

            DECLARE
                @RowsDeletedBatch bigint = 0,
                @RowsArchivedBatch bigint = 0;

            -- Iterate the once-resolved effective object config (see #Obj at the top of this TRY) instead of
            -- re-joining arch.v_ObjectSpecDatabaseEffective on every batch.
            DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT
                SourceSchema, SourceTable, DeleteMode, JoinSql, AddWhere,
                ArchiveSchema, ArchiveTable, RequireArchiveForDelete
            FROM #Obj
            ORDER BY Seq;

            DECLARE
                @sSchema sysname,
                @sTable sysname,
                @delMode tinyint,
                @join nvarchar(4000),
                @addWhere nvarchar(4000),
                @aSchema sysname,
                @aTable sysname,
                @reqArch bit,
                @delCols nvarchar(max),
                @tgtCols nvarchar(max),
                @srcCols nvarchar(max),
                @pkPred nvarchar(max),
                @stmt nvarchar(max),
                @rc bigint;

            OPEN c;
            FETCH NEXT FROM c INTO @sSchema, @sTable, @delMode, @join, @addWhere, @aSchema, @aTable, @reqArch;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @delMode <> 1
                    RAISERROR(N'ObjectSpec.DeleteMode must be 1 for prepared-batch process (%s.%s).', 16, 1, @sSchema, @sTable);

                IF @join IS NULL OR LTRIM(RTRIM(@join)) = N''
                    RAISERROR(N'Missing JoinToAnchorPredicateSql for %s.%s.', 16, 1, @sSchema, @sTable);

                IF @Mode = 0 AND @reqArch = 1 AND @AllowDelNoArch = 0
                    RAISERROR(N'Delete-only blocked for %s.%s (RequireArchiveForDelete=1).', 16, 1, @sSchema, @sTable);

                -- Mode 1 (archive+delete) and Mode 2 (copy-only) both write to the archive -> provision it.
                IF @Mode IN (1, 2)
                    EXEC arch.usp_EnsureArchiveTableLikeSource
                         @SourceDb = @SourceDb,
                         @ArchiveDb = @ArchiveDb,
                         @SourceSchema = @sSchema,
                         @SourceTable = @sTable,
                         @ArchiveSchema = @aSchema,
                         @ArchiveTable = @aTable,
                         @MakeAllNullable = 1,
                         @IncludeComputed = 0;

                SET @srcCols = NULL; SET @pkPred = NULL;
                EXEC arch.usp_GetOutputColumns
                     @SourceDb = @SourceDb,
                     @SourceSchema = @sSchema,
                     @SourceTable = @sTable,
                     @IncludeComputed = 0,
                     @DeletedSelectList = @delCols OUTPUT,
                     @TargetColumnList = @tgtCols OUTPUT,
                     @SourceAlias = N't',
                     @SourceSelectList = @srcCols OUTPUT;

                -- Mode=2 copy-only: derive the source-PK dedup predicate + ensure the archive dedup index.
                IF @Mode = 2
                    EXEC arch.usp_GetCopyDedupInfo
                         @SourceDb = @SourceDb, @SourceSchema = @sSchema, @SourceTable = @sTable,
                         @ArchiveDb = @ArchiveDb, @ArchiveSchema = @aSchema, @ArchiveTable = @aTable,
                         @SourceAlias = N't', @ArchiveAlias = N'a', @EnsureIndex = 1,
                         @PkPredicate = @pkPred OUTPUT;

                IF @Mode = 1
                BEGIN
                    SET @stmt =
                    N'DELETE t
                      OUTPUT ' + @delCols + N'
                      INTO ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@aSchema) + N'.' + QUOTENAME(@aTable) + N' (' + @tgtCols + N')
                      FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@sSchema) + N'.' + QUOTENAME(@sTable) + N' t
                      INNER JOIN #Keys k ON ' + @join +
                      CASE
                          WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                              THEN N' WHERE (' + @addWhere + N')'
                          ELSE N''
                      END + N';';
                END
                ELSE IF @Mode = 2
                BEGIN
                    -- COPY-ONLY: insert candidate rows into the archive, NEVER delete the source, only rows
                    -- not already in the archive (dedup by source PK via @pkPred = 'a.[pk]=t.[pk]...').
                    IF NULLIF(LTRIM(RTRIM(@pkPred)), N'') IS NULL
                        THROW 50223, 'Copy-only (Mode=2) requires a PRIMARY KEY on the source table for dedup (predicate missing).', 1;
                    SET @stmt =
                    N'INSERT INTO ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@aSchema) + N'.' + QUOTENAME(@aTable) + N' (' + @tgtCols + N')
                      SELECT ' + @srcCols + N'
                      FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@sSchema) + N'.' + QUOTENAME(@sTable) + N' t WITH (NOLOCK)  /* copy-only read of the production source must take NO locks */
                      INNER JOIN #Keys k ON ' + @join + N'
                      WHERE ' +
                      CASE
                          WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                              THEN N'(' + @addWhere + N') AND '
                          ELSE N''
                      END +
                      N'NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@aSchema) + N'.' + QUOTENAME(@aTable) + N' a WHERE ' + @pkPred + N');';
                END
                ELSE
                BEGIN
                    SET @stmt =
                    N'DELETE t
                      FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@sSchema) + N'.' + QUOTENAME(@sTable) + N' t
                      INNER JOIN #Keys k ON ' + @join +
                      CASE
                          WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                              THEN N' WHERE (' + @addWhere + N')'
                          ELSE N''
                      END + N';';
                END;

                EXEC(@stmt);
                SET @rc = @@ROWCOUNT;

                -- Mode=2 copies (archives) without deleting: deleted=0, archived=@rc. Mode=1: both=@rc. Mode=0: deleted=@rc, archived=0.
                INSERT INTO arch.RunItemObject(RunItemId, SourceSchema, SourceTable, RowsDeleted, RowsArchived)
                VALUES (@RunItemId, @sSchema, @sTable, CASE WHEN @Mode = 2 THEN 0 ELSE @rc END, CASE WHEN @Mode IN (1, 2) THEN @rc ELSE 0 END);

                SET @RowsDeletedBatch = @RowsDeletedBatch + CASE WHEN @Mode = 2 THEN 0 ELSE @rc END;
                SET @RowsArchivedBatch = @RowsArchivedBatch + CASE WHEN @Mode IN (1, 2) THEN @rc ELSE 0 END;

                FETCH NEXT FROM c INTO @sSchema, @sTable, @delMode, @join, @addWhere, @aSchema, @aTable, @reqArch;
            END;

            CLOSE c;
            DEALLOCATE c;

            IF @Mode = 1
            BEGIN
                IF EXISTS
                (
                    SELECT 1
                    FROM arch.RunItemObject rio
                    WHERE rio.RunItemId = @RunItemId
                      AND ISNULL(rio.RowsDeleted,0) > 0
                      AND ISNULL(rio.RowsArchived,0) <> ISNULL(rio.RowsDeleted,0)
                )
                BEGIN
                    DECLARE @bad nvarchar(4000);

                    SELECT @bad =
                        STUFF((
                            SELECT TOP (50)
                                N'; ' + rio.SourceTable
                                + N' del=' + CONVERT(nvarchar(20), ISNULL(rio.RowsDeleted,0))
                                + N' arc=' + CONVERT(nvarchar(20), ISNULL(rio.RowsArchived,0))
                            FROM arch.RunItemObject rio
                            WHERE rio.RunItemId = @RunItemId
                              AND ISNULL(rio.RowsDeleted,0) > 0
                              AND ISNULL(rio.RowsArchived,0) <> ISNULL(rio.RowsDeleted,0)
                            FOR XML PATH(''), TYPE
                        ).value('.','nvarchar(max)'), 1, 2, N'');

                    RAISERROR(N'Archive/Delete mismatch (Mode=1). %s', 16, 1, @bad);
                END;
            END;

            IF @AuditLevel = N'ROW'
            BEGIN
                INSERT INTO arch.RunDocAudit(RunItemId, ProcessCode, DocKeyLabel, DocKey, DocCreatedAt, Archived)
                SELECT
                    @RunItemId,
                    @ProcessCode,
                    @DocKeyLabel,
                    CASE
                        WHEN NULLIF(k.DocKey2, N'') IS NULL THEN k.DocKey
                        ELSE k.DocKey + N'|' + k.DocKey2
                    END,
                    k.DocCreatedAt,
                    CASE WHEN @Mode IN (1, 2) THEN 1 ELSE 0 END   -- Mode=2 copy also archives the doc
                FROM #Keys k;
            END;

            UPDATE arch.RunItem
            SET BatchesDone = BatchesDone + 1,
                DocsDone = DocsDone + (SELECT COUNT(*) FROM #Keys),
                RowsDeleted = RowsDeleted + @RowsDeletedBatch,
                RowsArchived = RowsArchived + @RowsArchivedBatch
            WHERE RunItemId = @RunItemId;

            -- T-17: flip the claimed keys to Done (and stamp WorkBatch progress) INSIDE the same
            -- transaction as the delete/archive, so claim->delete->done is ATOMIC. Previously these ran
            -- after COMMIT; a crash/restart/deadlock in that window left keys claimed (Status=1) while their
            -- rows were already deleted+archived -> stale-reclaim -> RE-PROCESSING (duplicate RunDocAudit,
            -- inflated DocsDone, Mode=0 / AdditionalWhere-drift hazards). Idempotency is now derived from the
            -- key's persisted Status, not from source-row existence. Scope AND k.Status=1 so a key parked
            -- under legal hold (Status=5, T-21) or already done (2) is never resurrected to Done.
            UPDATE k
            SET Status = 2,
                DoneAtUtc = SYSUTCDATETIME()
            FROM arch.WorkBatchKey k
            JOIN #Claimed c
              ON c.Key1 = k.Key1
             AND c.Key2 = k.Key2
             AND ISNULL(c.CandidateHash, 0x) = ISNULL(k.CandidateHash, 0x)
            WHERE k.WorkBatchId = @WorkBatchId
              AND k.Status = 1;

            UPDATE arch.WorkBatch
            SET LastProgressAtUtc = SYSUTCDATETIME(),
                LastKey1 = (SELECT TOP(1) Key1 FROM #Claimed ORDER BY DocCreatedAt DESC, Key1 DESC),
                LastKey2 = (SELECT TOP(1) Key2 FROM #Claimed ORDER BY DocCreatedAt DESC, Key1 DESC, Key2 DESC)
            WHERE WorkBatchId = @WorkBatchId;

            COMMIT;

            DROP TABLE #Keys;
        END;

        DECLARE @FinalStatus nvarchar(20) =
            CASE WHEN EXISTS (SELECT 1 FROM arch.Run WHERE RunId = @RunId AND CancelRequestedAtUtc IS NOT NULL)
                 THEN N'STOPPED' ELSE N'OK' END;

        UPDATE arch.RunItem
        SET Status = @FinalStatus,
            EndedAt = SYSUTCDATETIME()
        WHERE RunItemId = @RunItemId;

        UPDATE arch.Run
        SET Status = @FinalStatus,
            EndedAt = SYSUTCDATETIME()
        WHERE RunId = @RunId;

        IF NOT EXISTS (SELECT 1 FROM arch.WorkBatchKey WHERE WorkBatchId = @WorkBatchId AND Status IN (0,1))
        BEGIN
            UPDATE arch.WorkBatch
            SET Status = 'Completed',
                CompletedAtUtc = SYSUTCDATETIME()
            WHERE WorkBatchId = @WorkBatchId;
        END
        ELSE
        BEGIN
            UPDATE arch.WorkBatch
            SET Status = 'Paused',
                LastProgressAtUtc = SYSUTCDATETIME()
            WHERE WorkBatchId = @WorkBatchId;
        END;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;

        DECLARE @errnum int = ERROR_NUMBER();
        DECLARE @errmsg nvarchar(4000) = ERROR_MESSAGE();
        DECLARE @retryable bit =
            CASE WHEN @errnum IN (1205, 1222) OR @errmsg LIKE N'%collation conflict%' THEN 1 ELSE 0 END;

        UPDATE k
        SET Status =
            CASE WHEN @retryable = 1 THEN 0 ELSE 3 END,
            ClaimedAtUtc = CASE WHEN @retryable = 1 THEN NULL ELSE k.ClaimedAtUtc END,
            ClaimedBy = CASE WHEN @retryable = 1 THEN NULL ELSE k.ClaimedBy END,
            ErrorMessage = LEFT(@errmsg, 4000)
        FROM arch.WorkBatchKey k
        JOIN #Claimed c
          ON c.Key1 = k.Key1
         AND c.Key2 = k.Key2
         AND ISNULL(c.CandidateHash, 0x) = ISNULL(k.CandidateHash, 0x)
        WHERE k.WorkBatchId = @WorkBatchId
          AND k.Status = 1;   -- T-17: only reset still-claimed keys; never resurrect a done (2) or legal-hold-parked (5) key

        UPDATE arch.WorkBatch
        SET Status = 'Paused',
            LastProgressAtUtc = SYSUTCDATETIME(),
            Notes = LEFT(@errmsg, 4000)
        WHERE WorkBatchId = @WorkBatchId;

        IF @RunItemId IS NOT NULL
        BEGIN
            UPDATE arch.RunItem
            SET Status = N'FAILED',
                EndedAt = SYSUTCDATETIME(),
                ErrorMessage = @errmsg
            WHERE RunItemId = @RunItemId;
        END;

        IF @RunId IS NOT NULL
        BEGIN
            UPDATE arch.Run
            SET Status = N'FAILED',
                EndedAt = SYSUTCDATETIME(),
                ErrorMessage = @errmsg
            WHERE RunId = @RunId;
        END;

        RAISERROR(N'arch.usp_RunPreparedBatch failed: %s', 16, 1, @errmsg);
        RETURN;
    END CATCH
END
GO
