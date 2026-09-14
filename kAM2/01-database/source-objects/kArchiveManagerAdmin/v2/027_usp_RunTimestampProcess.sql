USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_RunTimestampProcess]
    @ProcessCode   sysname,
    @SourceDb      sysname,
    @ArchiveDb     sysname,
    @AsOfUtc       datetime2(0) = NULL,
    @StopAtUtc     datetime2(0) = NULL,
    @BatchRowCount int = NULL,
    @MaxRows       int = NULL,
    @DryRun        bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- T-04: make the archive write fail-safe. With ANSI_WARNINGS ON a string truncation or numeric
    -- overflow during DELETE ... OUTPUT INTO <archive> raises a hard error (caught below -> rollback)
    -- instead of silently storing a narrowed/corrupted copy while the source row is deleted forever.
    SET ANSI_WARNINGS ON;

    IF NULLIF(LTRIM(RTRIM(@ProcessCode)), N'') IS NULL
        THROW 50100, 'Parametr @ProcessCode je povinny.', 1;

    IF NULLIF(LTRIM(RTRIM(@SourceDb)), N'') IS NULL
        THROW 50101, 'Parametr @SourceDb je povinny.', 1;

    IF NULLIF(LTRIM(RTRIM(@ArchiveDb)), N'') IS NULL
        THROW 50102, 'Parametr @ArchiveDb je povinny.', 1;

    IF DB_ID(@SourceDb) IS NULL
        THROW 50103, 'Zdrojova databaze neexistuje.', 1;

    IF DB_ID(@ArchiveDb) IS NULL
        THROW 50104, 'Archivni databaze neexistuje.', 1;

    SET @AsOfUtc = COALESCE(@AsOfUtc, CONVERT(datetime2(0), SYSUTCDATETIME()));

    DECLARE
        @ProcessId int,
        @ProcessDatabaseId int,
        @Mode tinyint,
        @SelectionStrategy nvarchar(30),
        @RetentionDays int,
        @LagMin int,
        @ConfiguredBatchRowCount int,
        @MaxBatches int,
        @DelayMs int,
        @UseAppLock bit,
        @AppLockResource nvarchar(200),
        @LockTimeoutMs int,
        @DeadlockPriority nvarchar(10),
        @AllowDelNoArch bit,
        @DocKeyLabel nvarchar(50),
        @AuditLevel nvarchar(20),
        @CutoffMode tinyint,
        @CutoffDate datetime2(0),
        @CandidateWhereSql nvarchar(4000),
        @CandidateOrderSql nvarchar(4000),
        @CutoffUtc datetime2(0),
        @RunId bigint = NULL,
        @RunItemId bigint = NULL,
        @AppLockTaken bit = 0,
        @ReleaseAppLockResult int = NULL;

    SELECT
        @ProcessDatabaseId = e.ProcessDatabaseId,
        @ProcessId = e.ProcessId,
        @Mode = e.Mode,
        @SelectionStrategy = COALESCE(e.SelectionStrategy, N'ANCHOR'),
        @RetentionDays = e.RetentionDays,
        @LagMin = e.CutoffSafetyLagMinutes,
        @ConfiguredBatchRowCount = e.BatchRowCount,
        @MaxBatches = e.MaxBatchesPerRun,
        @DelayMs = e.DelayMsBetweenBatches,
        @UseAppLock = e.UseAppLock,
        @AppLockResource = COALESCE(NULLIF(e.AppLockResource, N''), N'KARCHIVE_MANAGER:' + e.ProcessCode + N':' + @SourceDb),
        @LockTimeoutMs = e.LockTimeoutMs,
        @DeadlockPriority = e.DeadlockPriority,
        @AllowDelNoArch = e.AllowDeleteWithoutArchive,
        @DocKeyLabel = COALESCE(NULLIF(LTRIM(RTRIM(e.DocKeyLabel)), N''), N'Key1'),
        @AuditLevel = COALESCE(NULLIF(LTRIM(RTRIM(e.AuditLevel)), N''), N'BATCH'),
        @CutoffMode = e.CutoffMode,
        @CutoffDate = e.CutoffDate,
        @CandidateWhereSql = e.CandidateWhereSql,
        @CandidateOrderSql = e.CandidateOrderSql
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessCode = @ProcessCode
      AND e.SourceDb = @SourceDb
      AND e.ArchiveDb = @ArchiveDb
      AND e.IsEnabled = 1;

    IF @ProcessId IS NULL
        THROW 50105, 'Proces nebyl nalezen nebo neni enabled.', 1;

    IF @SelectionStrategy <> N'TIMESTAMP'
        THROW 50106, 'arch.usp_RunTimestampProcess supports only SelectionStrategy=TIMESTAMP.', 1;

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
        THROW 50107, '2.0 metadata arch.ProcessKeySpec neni nainstalovana.', 1;

    -- P0.5 Risk K1 gate: block real deletes when ObjectSpec.TimestampExpr is not
    -- UTC-normalized (AT TIME ZONE). Dry-runs (@DryRun=1) are exempt. THROW 50200.
    IF @DryRun = 0
        EXEC arch.usp_AssertTimezonePolicyApplied
             @ProcessId = @ProcessId,
             @SourceDb  = @SourceDb,
             @ArchiveDb = @ArchiveDb;

    -- Per-transaction delete size default. Kept below SQL Server's ~5000 lock-escalation threshold:
    -- a single DELETE of >~5000 rows escalates its row locks to a TABLE X lock on the PRODUCTION source
    -- and blocks OLTP for the batch duration (proven live: 50000-row batch -> table X lock + blocked
    -- readers; 4000 -> row locks only, no block). Throughput is preserved by MaxBatchesPerRun, not by a
    -- huge batch. Explicit configs above the safe limit are blocked by usp_ValidateConfiguration (go-live gate).
    SET @BatchRowCount = COALESCE(@BatchRowCount, @ConfiguredBatchRowCount, 4000);
    SET @MaxBatches = COALESCE(@MaxBatches, 100);
    SET @DelayMs = COALESCE(@DelayMs, 0);
    SET @LagMin = COALESCE(@LagMin, 0);
    SET @LockTimeoutMs = COALESCE(@LockTimeoutMs, 10000);
    SET @AllowDelNoArch = COALESCE(@AllowDelNoArch, 0);

    IF @BatchRowCount <= 0
        THROW 50108, 'BatchRowCount musi byt vetsi nez 0.', 1;

    -- SAFETY (source lock-escalation guard, runtime backstop for the TIMESTAMP path): hard-cap the
    -- per-batch DELETE at 4000 rows regardless of the configured/passed value, so a single DELETE can
    -- never acquire >~5000 row locks and escalate to a TABLE X lock on the PRODUCTION source (proven
    -- live: 50000 -> table X + blocked readers; 4000 -> row locks only). Larger volumes still process
    -- fully via more batches (MaxBatchesPerRun). usp_ValidateConfiguration also flags oversized configs.
    IF @BatchRowCount > 4000
        SET @BatchRowCount = 4000;

    IF @MaxRows IS NULL
    BEGIN
        DECLARE @DefaultCandidateBatches int = CASE WHEN @MaxBatches > 100 THEN 100 ELSE @MaxBatches END;
        DECLARE @DefaultMaxRowsBigint bigint = CONVERT(bigint, @BatchRowCount) * CONVERT(bigint, @DefaultCandidateBatches);

        SET @MaxRows =
            CASE
                WHEN @DefaultMaxRowsBigint > 2147483647 THEN 2147483647
                ELSE CONVERT(int, @DefaultMaxRowsBigint)
            END;
    END;

    IF @MaxRows <= 0
        THROW 50109, 'MaxRows musi byt vetsi nez 0.', 1;

    IF @CutoffMode = 1 AND @CutoffDate IS NOT NULL
        SET @CutoffUtc = CONVERT(datetime2(0), @CutoffDate);
    ELSE
        SET @CutoffUtc = DATEADD(MINUTE, -@LagMin, DATEADD(DAY, -COALESCE(@RetentionDays, 0), @AsOfUtc));

    -- T-21 retention floor: block real deletes whose effective cutoff is inside the policy floor (DryRun exempt). THROW 50210.
    -- OBJECT_ID-guarded so a runner deployed WITHOUT 056 (older/hotfix path) degrades gracefully instead of erroring.
    IF @DryRun = 0 AND OBJECT_ID(N'arch.usp_AssertRetentionFloor', N'P') IS NOT NULL
        EXEC arch.usp_AssertRetentionFloor @ProcessId = @ProcessId, @SourceDb = @SourceDb, @ArchiveDb = @ArchiveDb, @CutoffUtc = @CutoffUtc;

    CREATE TABLE #Obj
    (
        RowNo int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        SourceSchema sysname NOT NULL,
        SourceTable sysname NOT NULL,
        DeleteOrder int NOT NULL,
        DeleteMode tinyint NOT NULL,
        TimestampExpr nvarchar(4000) NULL,
        JoinToAnchorPredicateSql nvarchar(4000) NULL,
        AdditionalWhereSql nvarchar(4000) NULL,
        ArchiveSchema sysname NOT NULL,
        ArchiveTable sysname NOT NULL,
        RequireArchiveForDelete bit NOT NULL,
        DelCols nvarchar(max) NULL,
        TgtCols nvarchar(max) NULL,
        SrcCols nvarchar(max) NULL,        -- Mode=2 copy: 't.[col1],t.[col2]' for INSERT ... SELECT
        PkPredicate nvarchar(max) NULL,    -- Mode=2 copy: 'a.[pk] = t.[pk] AND ...' dedup (a=archive, t=source)
        CandidateSelectExpr nvarchar(4000) NULL  -- perf: cheap local timestamp expr for candidate selection (no per-row AT TIME ZONE)
    );

    INSERT INTO #Obj
    (
        SourceSchema, SourceTable, DeleteOrder, DeleteMode,
        TimestampExpr, JoinToAnchorPredicateSql, AdditionalWhereSql,
        ArchiveSchema, ArchiveTable, RequireArchiveForDelete, CandidateSelectExpr
    )
    SELECT
        os.SourceSchema,
        os.SourceTable,
        os.DeleteOrder,
        os.DeleteMode,
        os.TimestampExpr,
        os.JoinToAnchorPredicateSql,
        os.AdditionalWhereSql,
        CONVERT(nvarchar(128), REPLACE(
            CASE
                WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo' THEN N'{SourceDb}'
                ELSE LTRIM(RTRIM(os.ArchiveSchema))
            END,
            N'{SourceDb}', @SourceDb)),
        COALESCE(os.ArchiveTable, os.SourceTable),
        COALESCE(os.RequireArchiveForDelete, 0),
        os.CandidateSelectExpr
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessDatabaseId = @ProcessDatabaseId
      AND os.ObjectIsEnabled = 1
    ORDER BY os.DeleteOrder, os.ObjectSpecId;

    IF NOT EXISTS (SELECT 1 FROM #Obj)
        THROW 50110, 'Proces nema zadny ObjectSpec.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM #Obj
        WHERE DeleteMode <> 1
           OR NULLIF(LTRIM(RTRIM(TimestampExpr)), N'') IS NULL
           OR NULLIF(LTRIM(RTRIM(JoinToAnchorPredicateSql)), N'') IS NULL
    )
        THROW 50111, 'TIMESTAMP keyset process requires DeleteMode=1, TimestampExpr and JoinToAnchorPredicateSql on every ObjectSpec.', 1;

    IF @Mode = 0
       AND @AllowDelNoArch = 0
       AND EXISTS (SELECT 1 FROM #Obj WHERE RequireArchiveForDelete = 1)
        THROW 50112, 'Delete-only je blokovan, protoze nektery ObjectSpec ma RequireArchiveForDelete=1.', 1;

    DECLARE
        @CandidateSchema sysname,
        @CandidateTable sysname,
        @TimestampExpr nvarchar(4000),
        @CandidateAdditionalWhereSql nvarchar(4000),
        @CandidateSelectExpr nvarchar(4000),
        @KeyExpr nvarchar(4000),
        @OrderSql nvarchar(4000);

    SELECT TOP (1)
        @CandidateSchema = SourceSchema,
        @CandidateTable = SourceTable,
        @TimestampExpr = TimestampExpr,
        @CandidateAdditionalWhereSql = AdditionalWhereSql,
        @CandidateSelectExpr = NULLIF(LTRIM(RTRIM(CandidateSelectExpr)), N'')
    FROM #Obj
    ORDER BY DeleteOrder, RowNo;

    SELECT @KeyExpr = pks.SourceExpressionSql
    FROM arch.ProcessKeySpec pks
    WHERE pks.ProcessId = @ProcessId
      AND pks.KeyOrdinal = 1;

    IF NULLIF(LTRIM(RTRIM(@KeyExpr)), N'') IS NULL
        THROW 50113, 'TIMESTAMP keyset process requires ProcessKeySpec KeyOrdinal=1.', 1;

    SET @OrderSql = COALESCE(NULLIF(LTRIM(RTRIM(@CandidateOrderSql)), N''), N'DocCreatedAt, Key1');

    -- T-05 runtime re-assert (audit hardening): the Save* API procs validate these fragments at SAVE
    -- time, but a direct DBA write to arch.Process/ObjectSpec bypasses the API. Re-assert every
    -- config-sourced fragment here before it is concatenated into dynamic SQL (DryRun included — the
    -- candidate scan executes them too). OBJECT_ID-guarded for graceful degradation. THROW 50400.
    IF OBJECT_ID(N'arch.usp_AssertSafeSqlExpression', N'P') IS NOT NULL
    BEGIN
        EXEC arch.usp_AssertSafeSqlExpression @KeyExpr, N'ProcessKeySpec.SourceExpressionSql';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateWhereSql, N'CandidateWhereSql';
        EXEC arch.usp_AssertSafeSqlExpression @OrderSql, N'CandidateOrderSql';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateSelectExpr, N'ObjectSpec.CandidateSelectExpr';

        DECLARE @vExpr nvarchar(4000), @vField nvarchar(128);
        DECLARE cVal CURSOR LOCAL FAST_FORWARD FOR
            SELECT TimestampExpr, N'ObjectSpec.TimestampExpr' FROM #Obj
            UNION ALL SELECT JoinToAnchorPredicateSql, N'ObjectSpec.JoinToAnchorPredicateSql' FROM #Obj
            UNION ALL SELECT AdditionalWhereSql, N'ObjectSpec.AdditionalWhereSql' FROM #Obj;
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

    DECLARE
        @RowNo int,
        @sSchema sysname,
        @sTable sysname,
        @aSchema sysname,
        @aTable sysname,
        @delCols nvarchar(max),
        @tgtCols nvarchar(max),
        @srcCols nvarchar(max),
        @pkPred nvarchar(max);

    DECLARE cPrep CURSOR LOCAL FAST_FORWARD FOR
    SELECT RowNo, SourceSchema, SourceTable, ArchiveSchema, ArchiveTable
    FROM #Obj
    ORDER BY DeleteOrder, RowNo;

    OPEN cPrep;
    FETCH NEXT FROM cPrep INTO @RowNo, @sSchema, @sTable, @aSchema, @aTable;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Mode 1 (archive+delete) and Mode 2 (copy-only) both write to the archive -> provision it.
        IF @Mode IN (1, 2)
        BEGIN
            EXEC arch.usp_EnsureArchiveTableLikeSource
                @SourceDb = @SourceDb,
                @ArchiveDb = @ArchiveDb,
                @SourceSchema = @sSchema,
                @SourceTable = @sTable,
                @ArchiveSchema = @aSchema,
                @ArchiveTable = @aTable,
                @MakeAllNullable = 1,
                @IncludeComputed = 0;
        END;

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

        UPDATE #Obj
        SET DelCols = @delCols,
            TgtCols = @tgtCols,
            SrcCols = @srcCols,
            PkPredicate = @pkPred
        WHERE RowNo = @RowNo;

        FETCH NEXT FROM cPrep INTO @RowNo, @sSchema, @sTable, @aSchema, @aTable;
    END;

    CLOSE cPrep;
    DEALLOCATE cPrep;

    DECLARE @DelayStr varchar(20) = NULL;
    IF @DelayMs > 0
    BEGIN
        DECLARE @h int = @DelayMs / 3600000;
        DECLARE @m int = (@DelayMs % 3600000) / 60000;
        DECLARE @s int = (@DelayMs % 60000) / 1000;
        DECLARE @ms int = @DelayMs % 1000;

        SET @DelayStr =
            RIGHT('00'  + CONVERT(varchar(2), @h), 2) + ':' +
            RIGHT('00'  + CONVERT(varchar(2), @m), 2) + ':' +
            RIGHT('00'  + CONVERT(varchar(2), @s), 2) + '.' +
            RIGHT('000' + CONVERT(varchar(3), @ms), 3);
    END;

    BEGIN TRY
        -- T-03: stamp the worker's session identity so usp_RecoverStaleRuns can tell a live run from a
        -- dead one and never recover a run whose worker session is still executing.
        INSERT INTO arch.Run(SourceDb, ArchiveDb, HostName, AppName, InitiatedBy, WorkerSessionId, WorkerSessionLoginTimeUtc)
        VALUES (@SourceDb, @ArchiveDb, HOST_NAME(), APP_NAME(), SUSER_SNAME(),
                @@SPID, (SELECT login_time FROM sys.dm_exec_sessions WHERE session_id = @@SPID));
        SET @RunId = SCOPE_IDENTITY();

        INSERT INTO arch.RunItem(RunId, ProcessId, AsOfUtc, CutoffUtc, Mode)
        VALUES (@RunId, @ProcessId, @AsOfUtc, @CutoffUtc, @Mode);
        SET @RunItemId = SCOPE_IDENTITY();

        IF COALESCE(@UseAppLock, 1) = 1
        BEGIN
            DECLARE @lres int;
            EXEC @lres = sys.sp_getapplock
                @Resource = @AppLockResource,
                @LockMode = 'Exclusive',
                @LockOwner = 'Session',
                @LockTimeout = @LockTimeoutMs;

            IF @lres < 0
                THROW 50114, 'TIMESTAMP keyset RUN failed to acquire applock.', 1;

            SET @AppLockTaken = 1;
        END;

        IF @DeadlockPriority = N'LOW' SET DEADLOCK_PRIORITY LOW;
        ELSE IF @DeadlockPriority = N'HIGH' SET DEADLOCK_PRIORITY HIGH;
        ELSE SET DEADLOCK_PRIORITY NORMAL;

        DECLARE @LockTimeoutStmt nvarchar(80) =
            N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(20), @LockTimeoutMs) + N';';
        EXEC (@LockTimeoutStmt);

        -- T-22: coerce the candidate/batch key to the SOURCE DB collation. A TIMESTAMP process joins
        -- #Batch.Key1 back to the source key column in the cross-DB DELETE; if the source DB collation
        -- differs from the Admin DB collation, that join throws Msg 468 (collation conflict) on EVERY
        -- real delete. Mirror the ANCHOR runner (015_usp_RunPreparedBatch #Keys): build the key column,
        -- re-collate it to the source collation, then add the uniqueness/lookup index.
        DECLARE @SourceCollation sysname = CONVERT(sysname, DATABASEPROPERTYEX(@SourceDb, N'Collation'));

        CREATE TABLE #Candidates
        (
            CandId bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
            Key1 nvarchar(256) NOT NULL,
            DocCreatedAt datetime2(0) NULL,
            DupCnt int NOT NULL DEFAULT(1)   -- how many ELIGIBLE source rows share this key (uniqueness gate)
        );
        IF @SourceCollation IS NOT NULL
            EXEC(N'ALTER TABLE #Candidates ALTER COLUMN Key1 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
        CREATE UNIQUE INDEX UX_Candidates_Key1 ON #Candidates(Key1);

        -- SCALABILITY (100M-row sources): the oldest @MaxRows candidates are read via TOP + ORDER BY
        -- pushed INTO the raw scan, so the read is bounded by the BATCH size, not the table size. To make
        -- that read an index-ordered SEEK (not a full scan + sort), the operator sets, on the source''s
        -- existing timestamp index (no new index needed):
        --   * CandidateWhereSql  = a SARGABLE bound on the raw indexed column referencing @CutoffUtc
        --                          (e.g. RF_LOG2: N''[DATE_TIME] < CONVERT(char(8), DATEADD(DAY,2,@CutoffUtc), 112)''),
        --   * CandidateOrderSql  = that same raw indexed column (e.g. N''[DATE_TIME]'') so ORDER BY matches
        --                          the index order and the TOP short-circuits after @MaxRows rows.
        -- The precise (TimestampExpr < @CutoffUtc) predicate still refines, so a loose sargable bound only
        -- over-reads a little (the exact residual filters it), never deletes the wrong rows. When the source
        -- lacks a usable timestamp index the read falls back to a scan/sort (fine for smaller tables).
        --
        -- CHEAP MODE (CandidateSelectExpr + CandidateWhereSql both set): the candidate scan does NO per-row
        -- AT TIME ZONE. CandidateSelectExpr (a cheap LOCAL datetime expr, e.g. CONVERT(datetime2(0),t.DATE_TIME))
        -- supplies the projected/ordered timestamp, and CandidateWhereSql (which converts @CutoffUtc to local
        -- ONCE and compares the raw indexed column) is the authoritative cutoff. The exact AT TIME ZONE
        -- TimestampExpr cutoff is then SKIPPED (it cost ~17x on RF_LOG2). Safe: CandidateWhereSql bounds the
        -- cutoff to ~second precision and the retention floor (50210) still guards @CutoffUtc absolutely.
        DECLARE @cheapMode bit =
            CASE WHEN @CandidateSelectExpr IS NOT NULL
                  AND @CandidateWhereSql IS NOT NULL AND LTRIM(RTRIM(@CandidateWhereSql)) <> N''
                 THEN 1 ELSE 0 END;
        DECLARE @DocExpr nvarchar(4000) = CASE WHEN @cheapMode = 1 THEN @CandidateSelectExpr ELSE @TimestampExpr END;

        -- TEMPDB SAVER: skip the ROW_NUMBER/COUNT dedup WINDOW (a sort that dominates tempdb on big runs)
        -- when the key is PROVABLY row-unique. The dedup keeps one row per key AND feeds the 50115 uniqueness
        -- gate; both are vacuous when each key already maps to exactly one row. We only skip when @KeyExpr is a
        -- clean single-column reference (t.COL) AND that column is the sole key of a UNIQUE/PK index on the
        -- source (verified from source metadata - no data scan). Otherwise we KEEP the dedup + 50115 gate, so a
        -- non-unique key can never silently over-delete. Conservative by construction.
        DECLARE @keyUnique bit = 0;
        DECLARE @keyColRaw nvarchar(256) = LTRIM(RTRIM(@KeyExpr));
        IF @keyColRaw LIKE N't.%'
           AND @keyColRaw NOT LIKE N'%(%' AND @keyColRaw NOT LIKE N'% %'
           AND @keyColRaw NOT LIKE N'%+%' AND @keyColRaw NOT LIKE N'%,%' AND @keyColRaw NOT LIKE N'%*%'
        BEGIN
            DECLARE @keyCol sysname = REPLACE(REPLACE(REPLACE(SUBSTRING(@keyColRaw, 3, 256), N'[', N''), N']', N''), N' ', N'');
            IF LEN(@keyCol) > 0 AND @keyCol NOT LIKE N'%.%'
            BEGIN
                DECLARE @tname nvarchar(512) = QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@CandidateSchema) + N'.' + QUOTENAME(@CandidateTable);
                DECLARE @uqSql nvarchar(max) = N'SELECT @u = CASE WHEN EXISTS (
                    SELECT 1 FROM ' + QUOTENAME(@SourceDb) + N'.sys.indexes i
                    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                    WHERE i.object_id = OBJECT_ID(@t) AND (i.is_unique = 1 OR i.is_primary_key = 1)
                    GROUP BY i.index_id HAVING COUNT(*) = 1 AND MAX(c.name) = @kc) THEN 1 ELSE 0 END;';
                EXEC sys.sp_executesql @uqSql, N'@t nvarchar(512), @kc sysname, @u bit OUTPUT', @t = @tname, @kc = @keyCol, @u = @keyUnique OUTPUT;
            END
        END

        DECLARE @loadSql nvarchar(max) = N'
;WITH raw AS
(
    SELECT TOP (@MaxRows)
        Key1 = CONVERT(nvarchar(256), ' + @KeyExpr + N'),
        DocCreatedAt = CONVERT(datetime2(0), ' + @DocExpr + N')
    FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@CandidateSchema) + N'.' + QUOTENAME(@CandidateTable) + N' t WITH (NOLOCK)  /* production source: candidate selection must take NO locks (rows are past the retention cutoff; the DELETE below is the authoritative, in-window mutation) */
    WHERE CONVERT(nvarchar(256), ' + @KeyExpr + N') IS NOT NULL
      AND LTRIM(RTRIM(CONVERT(nvarchar(256), ' + @KeyExpr + N'))) <> N'''' ' +
CASE
    WHEN @cheapMode = 0
        THEN N'
      AND (' + @TimestampExpr + N') < @CutoffUtc'
    ELSE N''
END +
CASE
    WHEN @CandidateAdditionalWhereSql IS NOT NULL AND LTRIM(RTRIM(@CandidateAdditionalWhereSql)) <> N''
        THEN N'
      AND (' + @CandidateAdditionalWhereSql + N')'
    ELSE N''
END +
CASE
    WHEN @CandidateWhereSql IS NOT NULL AND LTRIM(RTRIM(@CandidateWhereSql)) <> N''
        THEN N'
      AND (' + @CandidateWhereSql + N')'
    ELSE N''
END + N'
    ORDER BY ' + @OrderSql + N'
)'
+ CASE WHEN @keyUnique = 1 THEN
    -- row-unique key: no duplicates possible -> skip the window (NO sort), DupCnt is always 1
    N'
INSERT INTO #Candidates(Key1, DocCreatedAt, DupCnt)
SELECT Key1, DocCreatedAt, 1 FROM raw
OPTION (RECOMPILE);'
  ELSE
    N',
dedupe AS
(
    SELECT
        raw.*,
        rn  = ROW_NUMBER() OVER (PARTITION BY raw.Key1 ORDER BY raw.DocCreatedAt, raw.Key1),
        cnt = COUNT(*)     OVER (PARTITION BY raw.Key1)
    FROM raw
)
INSERT INTO #Candidates(Key1, DocCreatedAt, DupCnt)
SELECT
    Key1,
    DocCreatedAt,
    cnt
FROM dedupe
WHERE rn = 1
OPTION (RECOMPILE);'
  END;

        EXEC sys.sp_executesql
            @loadSql,
            N'@CutoffUtc datetime2(0), @MaxRows int',
            @CutoffUtc = @CutoffUtc,
            @MaxRows = @MaxRows;

        -- Runtime uniqueness gate (audit hardening): a TIMESTAMP candidate IS one source row, so the key
        -- must identify exactly ONE eligible row. If any key matches MULTIPLE eligible rows, the per-batch
        -- DELETE-by-key would act on rows that were never individually counted as candidates (a wider range
        -- than configured). Index validation (011) only WARNs; this blocks the real run. Empirical check on
        -- the actual data — no metadata parsing. DryRun stays a preview. THROW 50115.
        IF @DryRun = 0 AND EXISTS (SELECT 1 FROM #Candidates WHERE DupCnt > 1)
        BEGIN
            DECLARE @dupKey nvarchar(256), @dupCnt int;
            SELECT TOP (1) @dupKey = Key1, @dupCnt = DupCnt FROM #Candidates WHERE DupCnt > 1 ORDER BY DupCnt DESC;
            DECLARE @msg115 nvarchar(1000) =
                N'TIMESTAMP key is not unique among eligible rows: key ''' + @dupKey + N''' matches '
              + CONVERT(nvarchar(12), @dupCnt) + N' source rows. The keyset DELETE would touch rows that were '
              + N'never evaluated as candidates. Fix the key (ProcessKeySpec ordinal 1 must be row-unique, '
              + N'e.g. a PK/unique-indexed column) before real runs.';
            THROW 50115, @msg115, 1;
        END;

        CREATE NONCLUSTERED INDEX IX_Candidates_DocCreatedAt
        ON #Candidates(DocCreatedAt, Key1);

        -- T-21 legal-hold: drop held keys so they are never archived+deleted (reflected in the dry-run preview too).
        -- OBJECT_ID-guarded for graceful degradation when 056 is not deployed.
        IF OBJECT_ID(N'arch.LegalHold', N'U') IS NOT NULL
            DELETE c FROM #Candidates c
            WHERE EXISTS (SELECT 1 FROM arch.LegalHold lh
                          WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                            AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb)
                            AND lh.HoldKey = c.Key1 COLLATE DATABASE_DEFAULT);

        IF @DryRun = 1
        BEGIN
            SELECT
                ProcessCode = @ProcessCode,
                PreviewOnly = CONVERT(bit, 1),
                CutoffUtc = @CutoffUtc,
                CandidateRows = COUNT_BIG(*),
                MinCandidateUtc = MIN(DocCreatedAt),
                MaxCandidateUtc = MAX(DocCreatedAt)
            FROM #Candidates;

            SELECT TOP (100)
                Key1,
                DocCreatedAt
            FROM #Candidates
            ORDER BY DocCreatedAt, Key1;

            UPDATE arch.RunItem
            SET Status = N'DRYRUN',
                EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME())
            WHERE RunItemId = @RunItemId;

            UPDATE arch.Run
            SET Status = N'DRYRUN',
                EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME())
            WHERE RunId = @RunId;

            IF @AppLockTaken = 1
            BEGIN
                EXEC @ReleaseAppLockResult = sys.sp_releaseapplock
                    @Resource = @AppLockResource,
                    @LockOwner = 'Session';
                IF @ReleaseAppLockResult < 0
                    THROW 50115, 'TIMESTAMP keyset RUN failed to release applock.', 1;
                SET @AppLockTaken = 0;
            END;

            RETURN;
        END;

        CREATE TABLE #Batch
        (
            BatchId bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
            Key1 nvarchar(256) NOT NULL,
            DocCreatedAt datetime2(0) NULL
        );
        -- T-22: #Batch.Key1 is the column joined to the source key in the cross-DB DELETE — it MUST carry
        -- the source collation (see #Candidates above).
        IF @SourceCollation IS NOT NULL
            EXEC(N'ALTER TABLE #Batch ALTER COLUMN Key1 nvarchar(256) COLLATE ' + @SourceCollation + N' NOT NULL;');
        CREATE UNIQUE INDEX UX_Batch_Key1 ON #Batch(Key1);

        WHILE EXISTS (SELECT 1 FROM #Candidates)
        BEGIN
            IF @StopAtUtc IS NOT NULL
               AND CONVERT(datetime2(0), SYSUTCDATETIME()) >= @StopAtUtc
                BREAK;

            -- Cooperative cancel (040): operator requested a stop from the console.
            -- The previous batch is already committed; end gracefully (Status='STOPPED').
            IF EXISTS (SELECT 1 FROM arch.Run WHERE RunId = @RunId AND CancelRequestedAtUtc IS NOT NULL)
                BREAK;

            DELETE FROM #Batch;

            INSERT INTO #Batch(Key1, DocCreatedAt)
            SELECT TOP (@BatchRowCount) Key1, DocCreatedAt
            FROM #Candidates
            ORDER BY DocCreatedAt, Key1;

            IF NOT EXISTS (SELECT 1 FROM #Batch)
                BREAK;

            BEGIN TRAN;

            DECLARE
                @RowsDeletedBatch bigint = 0,
                @RowsArchivedBatch bigint = 0,
                @DocsBatch int = (SELECT COUNT(*) FROM #Batch),
                @stmt nvarchar(max),
                @rc bigint,
                @join nvarchar(4000),
                @addWhere nvarchar(4000),
                @rDelCols nvarchar(max),
                @rTgtCols nvarchar(max),
                @rSrcCols nvarchar(max),
                @rPkPredicate nvarchar(max),
                @raSchema sysname,
                @raTable sysname,
                @rsSchema sysname,
                @rsTable sysname;

            DECLARE cRun CURSOR LOCAL FAST_FORWARD FOR
            SELECT
                SourceSchema,
                SourceTable,
                JoinToAnchorPredicateSql,
                AdditionalWhereSql,
                ArchiveSchema,
                ArchiveTable,
                DelCols,
                TgtCols,
                SrcCols,
                PkPredicate
            FROM #Obj
            ORDER BY DeleteOrder, RowNo;

            OPEN cRun;
            FETCH NEXT FROM cRun
                INTO @rsSchema, @rsTable, @join, @addWhere, @raSchema, @raTable, @rDelCols, @rTgtCols, @rSrcCols, @rPkPredicate;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- Keyset is authoritative: candidates were selected as eligible (TimestampExpr < cutoff enforced
                -- at candidate-selection time) and materialized into #Candidates/#Batch; the DELETE/COPY acts
                -- strictly on those keys. The cutoff is deliberately NOT re-evaluated per row here -- doing so
                -- re-runs the (often expensive, e.g. AT TIME ZONE) timestamp expression on every deleted row,
                -- which on a high-volume log (RF_LOG2) regressed throughput ~2.8x for no correctness gain on
                -- append-only sources (selection and delete run in the SAME run, seconds apart).
                IF @Mode = 1
                BEGIN
                    SET @stmt =
                        N'DELETE t
                          OUTPUT ' + @rDelCols + N'
                          INTO ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@raSchema) + N'.' + QUOTENAME(@raTable) + N' (' + @rTgtCols + N')
                          FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@rsSchema) + N'.' + QUOTENAME(@rsTable) + N' t
                          INNER JOIN #Batch k ON ' + @join +
                          CASE
                              WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                                  THEN N' WHERE (' + @addWhere + N')'
                              ELSE N''
                          END + N'
                          OPTION (RECOMPILE);';
                END;
                ELSE IF @Mode = 2
                BEGIN
                    -- COPY-ONLY: insert candidate rows into the archive, NEVER delete from the source, and
                    -- only rows not already in the archive (dedup by source PK). @rPkPredicate is 'a.[pk]=t.[pk]...'.
                    IF NULLIF(LTRIM(RTRIM(@rPkPredicate)), N'') IS NULL
                        THROW 50222, 'Copy-only (Mode=2) is missing the source-PK dedup predicate (no PRIMARY KEY?).', 1;
                    SET @stmt =
                        N'INSERT INTO ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@raSchema) + N'.' + QUOTENAME(@raTable) + N' (' + @rTgtCols + N')
                          SELECT ' + @rSrcCols + N'
                          FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@rsSchema) + N'.' + QUOTENAME(@rsTable) + N' t
                          INNER JOIN #Batch k ON ' + @join + N'
                          WHERE ' +
                          CASE
                              WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                                  THEN N'(' + @addWhere + N') AND '
                              ELSE N''
                          END +
                          N'NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@raSchema) + N'.' + QUOTENAME(@raTable) + N' a WHERE ' + @rPkPredicate + N')
                          OPTION (RECOMPILE);';
                END;
                ELSE
                BEGIN
                    SET @stmt =
                        N'DELETE t
                          FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@rsSchema) + N'.' + QUOTENAME(@rsTable) + N' t
                          INNER JOIN #Batch k ON ' + @join +
                          CASE
                              WHEN @addWhere IS NOT NULL AND LTRIM(RTRIM(@addWhere)) <> N''
                                  THEN N' WHERE (' + @addWhere + N')'
                              ELSE N''
                          END + N'
                          OPTION (RECOMPILE);';
                END;

                EXEC (@stmt);
                SET @rc = @@ROWCOUNT;

                -- Concurrency guard (audit #4): on the KEYED candidate table, the 50115 gate proved Key1 is
                -- row-unique among eligible rows at selection time, so its per-batch DELETE must touch at most
                -- one row per batch key (i.e. @rc <= @DocsBatch). If it deleted MORE, a row sharing a batch
                -- key was inserted into the source AFTER selection — the keyset join would delete+archive it
                -- without it ever being evaluated as a candidate (a wider range than configured). Abort: the
                -- BEGIN TRAN above is rolled back by XACT_ABORT, the run is marked FAILED, and a re-run picks
                -- up a fresh, consistent candidate set. Free (a comparison, no extra scan) and only meaningful
                -- for non-row-unique keys — ROWID/PK-keyed processes never trip it. Skip Mode=2 (it INSERTs,
                -- not DELETEs, and is deduped by source PK). THROW 50116.
                IF @Mode <> 2
                   AND @rsSchema = @CandidateSchema AND @rsTable = @CandidateTable
                   AND @rc > @DocsBatch
                    THROW 50116, 'Concurrent source mutation detected: the keyed table gained rows sharing a candidate key after selection (DELETE matched more rows than candidates). Batch aborted and rolled back; re-run to reselect.', 1;

                IF EXISTS
                (
                    SELECT 1
                    FROM arch.RunItemObject rio
                    WHERE rio.RunItemId = @RunItemId
                      AND rio.SourceSchema = @rsSchema
                      AND rio.SourceTable = @rsTable
                )
                BEGIN
                    UPDATE arch.RunItemObject
                    SET RowsDeleted = RowsDeleted + CASE WHEN @Mode = 2 THEN 0 ELSE @rc END,
                        RowsArchived = RowsArchived + CASE WHEN @Mode IN (1, 2) THEN @rc ELSE 0 END
                    WHERE RunItemId = @RunItemId
                      AND SourceSchema = @rsSchema
                      AND SourceTable = @rsTable;
                END;
                ELSE
                BEGIN
                    INSERT INTO arch.RunItemObject(RunItemId, SourceSchema, SourceTable, RowsDeleted, RowsArchived)
                    VALUES (@RunItemId, @rsSchema, @rsTable, CASE WHEN @Mode = 2 THEN 0 ELSE @rc END, CASE WHEN @Mode IN (1, 2) THEN @rc ELSE 0 END);
                END;

                -- Mode=2 copies (archives) without deleting: deleted=0, archived=@rc. Mode=1: both=@rc. Mode=0: deleted=@rc, archived=0.
                SET @RowsDeletedBatch = @RowsDeletedBatch + CASE WHEN @Mode = 2 THEN 0 ELSE @rc END;
                SET @RowsArchivedBatch = @RowsArchivedBatch + CASE WHEN @Mode IN (1, 2) THEN @rc ELSE 0 END;

                FETCH NEXT FROM cRun
                    INTO @rsSchema, @rsTable, @join, @addWhere, @raSchema, @raTable, @rDelCols, @rTgtCols, @rSrcCols, @rPkPredicate;
            END;

            CLOSE cRun;
            DEALLOCATE cRun;

            IF @AuditLevel = N'ROW'
            BEGIN
                INSERT INTO arch.RunDocAudit(RunItemId, ProcessCode, DocKeyLabel, DocKey, DocCreatedAt, Archived)
                SELECT
                    @RunItemId,
                    @ProcessCode,
                    @DocKeyLabel,
                    b.Key1,
                    b.DocCreatedAt,
                    CASE WHEN @Mode IN (1, 2) THEN 1 ELSE 0 END   -- Mode=2 copy also archives the doc
                FROM #Batch b;
            END;

            UPDATE arch.RunItem
            SET BatchesDone = BatchesDone + 1,
                DocsDone = DocsDone + @DocsBatch,
                RowsDeleted = RowsDeleted + @RowsDeletedBatch,
                RowsArchived = RowsArchived + @RowsArchivedBatch
            WHERE RunItemId = @RunItemId;

            DELETE c
            FROM #Candidates c
            INNER JOIN #Batch b
              ON b.Key1 = c.Key1;

            -- T-04: enforce the Mode=1 invariant (RowsArchived == RowsDeleted) before COMMIT, mirroring
            -- the ANCHOR runner (015_usp_RunPreparedBatch). DELETE ... OUTPUT INTO is atomic so the per-
            -- object counts match by construction today; this is defense-in-depth that fails the batch
            -- (XACT_ABORT -> rollback) if a future change, a mis-set Mode, or a partial multi-object
            -- failure ever leaves a Mode=1 object with deleted-without-archived rows. (Independent
            -- archive read-back verification is the stronger guarantee and is tracked separately as T-19.)
            IF @Mode = 1
            BEGIN
                IF EXISTS
                (
                    SELECT 1
                    FROM arch.RunItemObject rio
                    WHERE rio.RunItemId = @RunItemId
                      AND ISNULL(rio.RowsDeleted, 0) > 0
                      AND ISNULL(rio.RowsArchived, 0) <> ISNULL(rio.RowsDeleted, 0)
                )
                BEGIN
                    DECLARE @divg nvarchar(4000);
                    SELECT @divg =
                        STUFF((
                            SELECT TOP (50)
                                N'; ' + rio.SourceTable
                                + N' del=' + CONVERT(nvarchar(20), ISNULL(rio.RowsDeleted, 0))
                                + N' arc=' + CONVERT(nvarchar(20), ISNULL(rio.RowsArchived, 0))
                            FROM arch.RunItemObject rio
                            WHERE rio.RunItemId = @RunItemId
                              AND ISNULL(rio.RowsDeleted, 0) > 0
                              AND ISNULL(rio.RowsArchived, 0) <> ISNULL(rio.RowsDeleted, 0)
                            FOR XML PATH(''), TYPE
                        ).value('.', 'nvarchar(max)'), 1, 2, N'');

                    RAISERROR(N'Archive/Delete mismatch (Mode=1). %s', 16, 1, @divg);
                END;
            END;

            COMMIT;

            IF @DelayStr IS NOT NULL
               AND (@StopAtUtc IS NULL OR CONVERT(datetime2(0), SYSUTCDATETIME()) < @StopAtUtc)
                WAITFOR DELAY @DelayStr;
        END;

        DECLARE @FinalStatus nvarchar(20) =
            CASE WHEN EXISTS (SELECT 1 FROM arch.Run WHERE RunId = @RunId AND CancelRequestedAtUtc IS NOT NULL)
                 THEN N'STOPPED' ELSE N'OK' END;

        UPDATE arch.RunItem
        SET Status = @FinalStatus,
            EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME())
        WHERE RunItemId = @RunItemId;

        UPDATE arch.Run
        SET Status = @FinalStatus,
            EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME())
        WHERE RunId = @RunId;

        IF @AppLockTaken = 1
        BEGIN
            EXEC @ReleaseAppLockResult = sys.sp_releaseapplock
                @Resource = @AppLockResource,
                @LockOwner = 'Session';
            IF @ReleaseAppLockResult < 0
                THROW 50320, 'TIMESTAMP keyset RUN failed to RELEASE applock (Session lock may remain held).', 1;
            SET @AppLockTaken = 0;
        END;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK;

        DECLARE @err nvarchar(max) = ERROR_MESSAGE();

        IF @RunItemId IS NOT NULL
        BEGIN
            UPDATE arch.RunItem
            SET Status = N'FAILED',
                EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME()),
                ErrorMessage = @err
            WHERE RunItemId = @RunItemId;
        END;

        IF @RunId IS NOT NULL
        BEGIN
            UPDATE arch.Run
            SET Status = N'FAILED',
                EndedAt = CONVERT(datetime2(0), SYSUTCDATETIME()),
                ErrorMessage = @err
            WHERE RunId = @RunId;
        END;

        IF @AppLockTaken = 1
        BEGIN
            EXEC @ReleaseAppLockResult = sys.sp_releaseapplock
                @Resource = @AppLockResource,
                @LockOwner = 'Session';
            SET @AppLockTaken = 0;
            -- Surface a release failure WITHOUT masking the original error (fold into the message).
            IF @ReleaseAppLockResult < 0
                SET @err = @err + N' [applock release also failed — Session lock may remain held]';
        END;

        RAISERROR(N'arch.usp_RunTimestampProcess failed: %s', 16, 1, @err);
        RETURN;
    END CATCH;
END
GO

PRINT 'Step 1: arch.usp_RunTimestampProcess created (internal worker for TIMESTAMP strategy)'
