USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_PrepareCandidates]
    @ProcessCode sysname,
    @SourceDb sysname,
    @ArchiveDb sysname,
    @FromUtc datetime2(0) = NULL,
    @ToUtc datetime2(0) = NULL,
    @MaxCandidates int = NULL,
    @WorkBatchId bigint OUTPUT
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
        @Mode tinyint,
        @SelectionStrategy nvarchar(30),
        @AuditLevel nvarchar(20),
        @RetentionDays int,
        @LagMin int,
        @BatchDocCount int,
        @BatchRowCount int,
        @MaxBatches int,
        @UseAppLock bit,
        @AppLockResource nvarchar(200),
        @LockTimeoutMs int,
        @CutoffMode tinyint,
        @CutoffDate datetime2(0),
        @AnchorSchema sysname,
        @AnchorTable sysname,
        @AnchorTimestampExpr nvarchar(4000),
        @AnchorExtraWhereSql nvarchar(4000),
        @CandidateSourceSchema sysname,
        @CandidateSourceTable sysname,
        @CandidateTimestampExpr nvarchar(4000),
        @CandidateAdditionalWhereSql nvarchar(4000),
        @CandidateWhereSql nvarchar(4000),
        @CandidateOrderSql nvarchar(4000);

    SET @WorkBatchId = NULL;

    SELECT
        @ProcessDatabaseId = e.ProcessDatabaseId,
        @ProcessId = e.ProcessId,
        @Mode = e.Mode,
        @SelectionStrategy = COALESCE(e.SelectionStrategy, N'ANCHOR'),
        @AuditLevel = COALESCE(e.AuditLevel, N'BATCH'),
        @RetentionDays = e.RetentionDays,
        @LagMin = e.CutoffSafetyLagMinutes,
        @BatchDocCount = e.BatchDocCount,
        @BatchRowCount = e.BatchRowCount,
        @MaxBatches = e.MaxBatchesPerRun,
        @UseAppLock = e.UseAppLock,
        @AppLockResource = COALESCE(NULLIF(e.AppLockResource, N''), N'KARCHIVE_MANAGER:' + e.ProcessCode + N':' + @SourceDb),
        @LockTimeoutMs = COALESCE(e.LockTimeoutMs, 10000),
        @CutoffMode = e.CutoffMode,
        @CutoffDate = e.CutoffDate,
        @AnchorSchema = e.AnchorSchema,
        @AnchorTable = e.AnchorTable,
        @AnchorTimestampExpr = e.AnchorTimestampExpr,
        @AnchorExtraWhereSql = e.AnchorExtraWhereSql,
        @CandidateWhereSql = e.CandidateWhereSql,
        @CandidateOrderSql = e.CandidateOrderSql
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessCode = @ProcessCode
      AND e.SourceDb = @SourceDb
      AND e.ArchiveDb = @ArchiveDb
      AND e.IsEnabled = 1;

    IF @ProcessId IS NULL
    BEGIN
        RAISERROR(N'Process not found or disabled: %s', 16, 1, @ProcessCode);
        RETURN;
    END;

    IF @SelectionStrategy NOT IN (N'ANCHOR', N'TIMESTAMP')
    BEGIN
        RAISERROR(N'arch.usp_PrepareCandidates currently implements ANCHOR and TIMESTAMP only. Process %s uses %s.', 16, 1, @ProcessCode, @SelectionStrategy);
        RETURN;
    END;

    IF @SelectionStrategy = N'TIMESTAMP'
       AND @AuditLevel = N'BATCH'
    BEGIN
        RAISERROR(N'TIMESTAMP/BATCH process %s runs through arch.usp_RunProcess_TimestampKeyset and does not prepare detailed WorkBatchKey rows.', 16, 1, @ProcessCode);
        RETURN;
    END;

    IF @SelectionStrategy = N'ANCHOR'
       AND (@AnchorSchema IS NULL OR @AnchorTable IS NULL OR NULLIF(LTRIM(RTRIM(@AnchorTimestampExpr)), N'') IS NULL)
    BEGIN
        RAISERROR(N'ANCHOR process has incomplete anchor configuration: %s', 16, 1, @ProcessCode);
        RETURN;
    END;

    IF @SelectionStrategy = N'TIMESTAMP'
    BEGIN
        SELECT TOP (1)
            @CandidateSourceSchema = os.SourceSchema,
            @CandidateSourceTable = os.SourceTable,
            @CandidateTimestampExpr = os.TimestampExpr,
            @CandidateAdditionalWhereSql = os.AdditionalWhereSql
        FROM arch.v_ObjectSpecDatabaseEffective os
        WHERE os.ProcessDatabaseId = @ProcessDatabaseId
          AND os.ObjectIsEnabled = 1
        ORDER BY os.DeleteOrder, os.ObjectSpecId;

        IF @CandidateSourceSchema IS NULL
           OR @CandidateSourceTable IS NULL
           OR NULLIF(LTRIM(RTRIM(@CandidateTimestampExpr)), N'') IS NULL
        BEGIN
            RAISERROR(N'TIMESTAMP process has incomplete ObjectSpec timestamp configuration: %s', 16, 1, @ProcessCode);
            RETURN;
        END;
    END;

    IF DB_ID(@SourceDb) IS NULL
    BEGIN
        RAISERROR(N'Source database does not exist: %s', 16, 1, @SourceDb);
        RETURN;
    END;

    IF DB_ID(@ArchiveDb) IS NULL
    BEGIN
        RAISERROR(N'Archive database does not exist: %s', 16, 1, @ArchiveDb);
        RETURN;
    END;

    SET @BatchDocCount = COALESCE(@BatchDocCount, 25);
    SET @BatchRowCount = COALESCE(@BatchRowCount, @BatchDocCount);
    SET @MaxBatches = COALESCE(@MaxBatches, 50);
    SET @MaxCandidates = COALESCE(
        @MaxCandidates,
        CASE
            WHEN @SelectionStrategy = N'TIMESTAMP' THEN @BatchRowCount * @MaxBatches
            ELSE @BatchDocCount * @MaxBatches
        END
    );
    SET @LagMin = COALESCE(@LagMin, 0);

    IF @MaxCandidates IS NULL OR @MaxCandidates <= 0
    BEGIN
        RAISERROR(N'@MaxCandidates must be greater than zero.', 16, 1);
        RETURN;
    END;

    SET @FromUtc = COALESCE(@FromUtc, CONVERT(datetime2(0), '19000101'));

    IF @ToUtc IS NULL
    BEGIN
        IF @CutoffMode = 1 AND @CutoffDate IS NOT NULL
            SET @ToUtc = @CutoffDate;
        ELSE
            SET @ToUtc = DATEADD(MINUTE, -@LagMin, DATEADD(DAY, -COALESCE(@RetentionDays, 0), CONVERT(datetime2(0), SYSUTCDATETIME())));
    END;

    IF @ToUtc <= @FromUtc
    BEGIN
        RAISERROR(N'Invalid candidate range: @FromUtc must be lower than @ToUtc.', 16, 1);
        RETURN;
    END;

    -- T-21 retention floor: refuse to PREPARE when the cutoff is inside the policy floor, so ANCHOR never
    -- builds a WorkBatch that 015 would only refuse (which would wedge re-prepare). A floor-violating config
    -- is refused here (fix the cutoff/floor first). Guarded for graceful degradation when 056 is absent. THROW 50210.
    IF OBJECT_ID(N'arch.usp_AssertRetentionFloor', N'P') IS NOT NULL
        EXEC arch.usp_AssertRetentionFloor @ProcessId = @ProcessId, @SourceDb = @SourceDb, @ArchiveDb = @ArchiveDb, @CutoffUtc = @ToUtc;

    DECLARE @OpenBatchId bigint;

    SELECT TOP (1) @OpenBatchId = wb.WorkBatchId
    FROM arch.WorkBatch wb
    WHERE wb.ProcessId = @ProcessId
      AND wb.SourceDb = @SourceDb
      AND wb.ArchiveDb = @ArchiveDb
      AND wb.Status IN ('Prepared','Running','Paused')
    ORDER BY wb.WorkBatchId;

    IF @OpenBatchId IS NOT NULL
    BEGIN
        RAISERROR(N'Candidate preparation blocked: open WorkBatch already exists (WorkBatchId=%I64d).', 16, 1, @OpenBatchId);
        RETURN;
    END;

    DECLARE @KeyExpr table
    (
        KeyOrdinal tinyint NOT NULL PRIMARY KEY,
        SourceExpressionSql nvarchar(4000) NOT NULL
    );

    INSERT @KeyExpr(KeyOrdinal, SourceExpressionSql)
    SELECT KeyOrdinal, SourceExpressionSql
    FROM arch.ProcessKeySpec
    WHERE ProcessId = @ProcessId
    ORDER BY KeyOrdinal;

    IF NOT EXISTS (SELECT 1 FROM @KeyExpr WHERE KeyOrdinal = 1)
    BEGIN
        RAISERROR(N'ANCHOR process requires at least ProcessKeySpec KeyOrdinal=1.', 16, 1);
        RETURN;
    END;

    DECLARE
        @SelectKeys nvarchar(max) = N'',
        @InsertColumns nvarchar(max) = N'',
        @OutputKeys nvarchar(max) = N'',
        @PartitionKeys nvarchar(max) = N'',
        @OrderKeys nvarchar(max) = N'',
        @HashInput nvarchar(max) = N'',
        @i int = 1,
        @expr nvarchar(4000);

    WHILE @i <= 8
    BEGIN
        SELECT @expr = SourceExpressionSql
        FROM @KeyExpr
        WHERE KeyOrdinal = @i;

        SET @SelectKeys = @SelectKeys
            + CASE WHEN @SelectKeys = N'' THEN N'' ELSE N',' + CHAR(10) END
            + N'            Key' + CONVERT(nvarchar(10), @i) + N' = '
            + CASE
                  WHEN @expr IS NULL THEN N'N'''''
                  ELSE N'CONVERT(nvarchar(256), ' + @expr + N')'
              END;

        SET @InsertColumns = @InsertColumns
            + CASE WHEN @InsertColumns = N'' THEN N'' ELSE N', ' END
            + N'Key' + CONVERT(nvarchar(10), @i);

        SET @OutputKeys = @OutputKeys
            + CASE WHEN @OutputKeys = N'' THEN N'' ELSE N', ' END
            + N'Key' + CONVERT(nvarchar(10), @i);

        SET @PartitionKeys = @PartitionKeys
            + CASE WHEN @PartitionKeys = N'' THEN N'' ELSE N', ' END
            + N'Key' + CONVERT(nvarchar(10), @i);

        SET @OrderKeys = @OrderKeys
            + CASE WHEN @OrderKeys = N'' THEN N'' ELSE N', ' END
            + N'Key' + CONVERT(nvarchar(10), @i);

        SET @HashInput = @HashInput
            + CASE WHEN @HashInput = N'' THEN N'' ELSE N', N''|'', ' END
            + N'ISNULL(Key' + CONVERT(nvarchar(10), @i) + N', N'''')';

        SET @i = @i + 1;
        SET @expr = NULL;
    END;

    IF NULLIF(LTRIM(RTRIM(@CandidateOrderSql)), N'') IS NOT NULL
        SET @OrderKeys = @CandidateOrderSql;
    ELSE
        SET @OrderKeys = N'DocCreatedAt, ' + @OrderKeys;

    DECLARE @Key1Expr nvarchar(4000);

    SELECT @Key1Expr = SourceExpressionSql
    FROM @KeyExpr
    WHERE KeyOrdinal = 1;

    -- T-05 runtime re-assert (audit hardening): the Save* API procs validate these fragments at SAVE
    -- time, but a direct DBA write to arch.Process/ProcessKeySpec/ObjectSpec bypasses the API. Re-assert
    -- every config-sourced fragment here before it is concatenated into the candidate-scan dynamic SQL.
    -- OBJECT_ID-guarded for graceful degradation. THROW 50400.
    IF OBJECT_ID(N'arch.usp_AssertSafeSqlExpression', N'P') IS NOT NULL
    BEGIN
        EXEC arch.usp_AssertSafeSqlExpression @AnchorTimestampExpr, N'AnchorTimestampExpr';
        EXEC arch.usp_AssertSafeSqlExpression @AnchorExtraWhereSql, N'AnchorExtraWhereSql';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateTimestampExpr, N'ObjectSpec.TimestampExpr';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateAdditionalWhereSql, N'ObjectSpec.AdditionalWhereSql';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateWhereSql, N'CandidateWhereSql';
        EXEC arch.usp_AssertSafeSqlExpression @CandidateOrderSql, N'CandidateOrderSql';

        DECLARE @vKeyExpr nvarchar(4000), @vKeyOrd int;
        DECLARE cValKeys CURSOR LOCAL FAST_FORWARD FOR
            SELECT KeyOrdinal, SourceExpressionSql FROM @KeyExpr;
        OPEN cValKeys;
        FETCH NEXT FROM cValKeys INTO @vKeyOrd, @vKeyExpr;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @vKeyField nvarchar(128) = N'ProcessKeySpec.SourceExpressionSql (KeyOrdinal=' + CONVERT(nvarchar(10), @vKeyOrd) + N')';
            EXEC arch.usp_AssertSafeSqlExpression @vKeyExpr, @vKeyField;
            FETCH NEXT FROM cValKeys INTO @vKeyOrd, @vKeyExpr;
        END;
        CLOSE cValKeys;
        DEALLOCATE cValKeys;
    END;

    CREATE TABLE #Candidates
    (
        Key1 nvarchar(256) NOT NULL,
        Key2 nvarchar(256) NOT NULL,
        Key3 nvarchar(256) NOT NULL,
        Key4 nvarchar(256) NOT NULL,
        Key5 nvarchar(256) NOT NULL,
        Key6 nvarchar(256) NOT NULL,
        Key7 nvarchar(256) NOT NULL,
        Key8 nvarchar(256) NOT NULL,
        DocCreatedAt datetime2(0) NULL,
        CandidateHash varbinary(32) NULL
    );

    DECLARE @lres int;
    DECLARE @AppLockTaken bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lres = sys.sp_getapplock
            @Resource = @AppLockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Session',
            @LockTimeout = @LockTimeoutMs;

        IF @lres < 0
        BEGIN
            RAISERROR(N'Candidate preparation failed to acquire applock: %s', 16, 1, @AppLockResource);
            RETURN;
        END;

        SET @AppLockTaken = 1;
    END;

    BEGIN TRY
        DECLARE
            @SourceSchema sysname,
            @SourceTable sysname,
            @TimestampExpr nvarchar(4000),
            @StrategyWhereSql nvarchar(max);

        IF @SelectionStrategy = N'ANCHOR'
        BEGIN
            SET @SourceSchema = @AnchorSchema;
            SET @SourceTable = @AnchorTable;
            SET @TimestampExpr = @AnchorTimestampExpr;
            SET @StrategyWhereSql =
                N'                AND CONVERT(nvarchar(256), ' + @Key1Expr + N') IS NOT NULL
                AND LTRIM(RTRIM(CONVERT(nvarchar(256), ' + @Key1Expr + N'))) <> N''''';

            IF NULLIF(LTRIM(RTRIM(@AnchorExtraWhereSql)), N'') IS NOT NULL
                SET @StrategyWhereSql = @StrategyWhereSql + N'
                AND (' + @AnchorExtraWhereSql + N')';
        END
        ELSE
        BEGIN
            SET @SourceSchema = @CandidateSourceSchema;
            SET @SourceTable = @CandidateSourceTable;
            SET @TimestampExpr = @CandidateTimestampExpr;
            SET @StrategyWhereSql =
                N'                AND CONVERT(nvarchar(256), ' + @Key1Expr + N') IS NOT NULL
                AND LTRIM(RTRIM(CONVERT(nvarchar(256), ' + @Key1Expr + N'))) <> N''''';

            IF NULLIF(LTRIM(RTRIM(@CandidateAdditionalWhereSql)), N'') IS NOT NULL
                SET @StrategyWhereSql = @StrategyWhereSql + N'
                AND (' + @CandidateAdditionalWhereSql + N')';
        END;

        IF NULLIF(LTRIM(RTRIM(@CandidateWhereSql)), N'') IS NOT NULL
            SET @StrategyWhereSql = @StrategyWhereSql + N'
                AND (' + @CandidateWhereSql + N')';

        DECLARE @sql nvarchar(max) =
        N';WITH raw AS
          (
              SELECT
' + @SelectKeys + N',
                  DocCreatedAt = CONVERT(datetime2(0), ' + @TimestampExpr + N')
              FROM ' + QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@SourceSchema) + N'.' + QUOTENAME(@SourceTable) + N' ' + CASE WHEN @SelectionStrategy = N'ANCHOR' THEN N'a' ELSE N't' END + N' WITH (NOLOCK)  /* production source: candidate selection must take NO locks (rows are past the retention cutoff; dedup + key-based DELETE are authoritative) */
              WHERE ' + @TimestampExpr + N' >= @FromUtc
                AND ' + @TimestampExpr + N' <  @ToUtc
' + @StrategyWhereSql + N'
          ),
          dedupe AS
          (
              SELECT
                  raw.*,
                  rn = ROW_NUMBER() OVER
                  (
                      PARTITION BY ' + @PartitionKeys + N'
                      ORDER BY ' + @OrderKeys + N'
                  )
              FROM raw
          )
          INSERT INTO #Candidates(' + @InsertColumns + N', DocCreatedAt, CandidateHash)
          SELECT TOP (@TopN)
                 ' + @OutputKeys + N',
                 DocCreatedAt,
                 HASHBYTES(''SHA2_256'', CONVERT(varbinary(max), CONCAT(' + @HashInput + N')))
          FROM dedupe
          WHERE rn = 1
          ORDER BY ' + @OrderKeys + N';';

        -- @CutoffUtc is exposed as an alias of @ToUtc (the candidate upper bound) so an operator can add a
        -- SARGABLE pre-filter on the raw indexed column to CandidateWhereSql/AdditionalWhereSql referencing
        -- @CutoffUtc — uniform with the TIMESTAMP runner (027). See "sargable cutoff" in the perf doc (C3):
        -- e.g. CandidateWhereSql = N'[DATE_TIME] < DATEADD(HOUR, 26, @CutoffUtc)' turns the candidate scan
        -- into an index seek; the precise (TimestampExpr < cutoff) predicate still refines, so a too-tight
        -- bound only under-includes (delays archival), never deletes the wrong rows.
        EXEC sys.sp_executesql
            @sql,
            N'@FromUtc datetime2(0), @ToUtc datetime2(0), @CutoffUtc datetime2(0), @TopN int',
            @FromUtc = @FromUtc,
            @ToUtc = @ToUtc,
            @CutoffUtc = @ToUtc,
            @TopN = @MaxCandidates;

        -- T-21 legal-hold: drop held keys so they never enter the WorkBatch (never archived+deleted).
        -- OBJECT_ID-guarded for graceful degradation when 056 is not deployed.
        IF OBJECT_ID(N'arch.LegalHold', N'U') IS NOT NULL
            DELETE c FROM #Candidates c
            WHERE EXISTS (SELECT 1 FROM arch.LegalHold lh
                          WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                            AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb)
                            AND lh.HoldKey = c.Key1 COLLATE DATABASE_DEFAULT);

        IF NOT EXISTS (SELECT 1 FROM #Candidates)
        BEGIN
            IF @AppLockTaken = 1
                EXEC sys.sp_releaseapplock @Resource = @AppLockResource, @LockOwner = 'Session';

            RETURN;
        END;

        BEGIN TRAN;

        INSERT INTO arch.WorkBatch
        (
            ProcessId, SourceDb, ArchiveDb, RangeFromUtc, RangeToUtc, ModeSnapshot, Status, PreparedAtUtc
        )
        VALUES
        (
            @ProcessId, @SourceDb, @ArchiveDb, @FromUtc, @ToUtc, @Mode, 'Prepared', SYSUTCDATETIME()
        );

        SET @WorkBatchId = SCOPE_IDENTITY();

        INSERT INTO arch.WorkBatchKey
        (
            WorkBatchId, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, DocCreatedAt, CandidateHash
        )
        SELECT
            @WorkBatchId, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, DocCreatedAt, CandidateHash
        FROM #Candidates
        ORDER BY DocCreatedAt, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8;

        COMMIT;

        IF @AppLockTaken = 1
        BEGIN
            EXEC sys.sp_releaseapplock @Resource = @AppLockResource, @LockOwner = 'Session';
            SET @AppLockTaken = 0;
        END;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK;

        IF @AppLockTaken = 1
            EXEC sys.sp_releaseapplock @Resource = @AppLockResource, @LockOwner = 'Session';

        DECLARE @err nvarchar(4000) = ERROR_MESSAGE();
        RAISERROR(N'arch.usp_PrepareCandidates failed: %s', 16, 1, @err);
        RETURN;
    END CATCH
END
GO
