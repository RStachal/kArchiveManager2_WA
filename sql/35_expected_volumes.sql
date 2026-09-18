-- ============================================================================
-- 35 - WHAT WILL THE NEXT RUN ACTUALLY MOVE, TABLE BY TABLE
-- ============================================================================
-- Answers the question the Admin Console does not: how many rows will leave each
-- source table on the next run.
--
-- THE CONSOLE'S "ANALYSIS & ESTIMATES" SCREEN DOES NOT ANSWER THIS.
-- arch.usp_Api_EstimateNextRunImpact reports the FOOTPRINT of the configured
-- tables - row counts, MB, index size, the per-run control limits and how much
-- space the archive and the log will need. Its SourceRows column is the WHOLE
-- table. For AAD_ORDER_ARCH it says t_order has 843 rows; 334 of them are
-- eligible. Both numbers are useful and they answer different questions: the
-- console sizes the operation, this script scopes it.
--
-- TWO MODES, CHOSEN AUTOMATICALLY
--
--   EXACT      candidates are already prepared (PREP has run). Counts are taken
--              by joining the real arch.WorkBatchKey rows to the source through
--              each object's own configured predicate. This is not an estimate -
--              it is the set of rows the run will touch.
--
--   DERIVED    nothing is prepared yet. The gate and cutoff of each process are
--              re-applied to the source to work out what PREP would select. Very
--              close, but it is a second implementation of the same rule, and the
--              source can move underneath it.
--
-- DOES PREP HAVE TO RUN FIRST? No - DERIVED mode works on a clean instance. But
-- PREP writes nothing to the WMS and deletes nothing anywhere; it only reads the
-- source and records the keys. Running it first and then using EXACT mode is both
-- more accurate and a better story: "nothing has been deleted, and we already
-- know exactly what will be."
--
-- Read-only. Nothing is written in either mode.
-- ============================================================================
:setvar AdminDb "kArchiveManagerAdmin"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;   -- never block the WMS to count
GO

DECLARE @ProcessFilter sysname = NULL;   -- NULL = every enabled process

IF OBJECT_ID('tempdb..#Vol') IS NOT NULL DROP TABLE #Vol;
CREATE TABLE #Vol (
    ProcessCode  sysname      NOT NULL,
    Strategy     varchar(20)  NOT NULL,
    Mode         varchar(10)  NOT NULL,
    DeleteOrder  int          NOT NULL,
    SourceDb     sysname      NOT NULL,
    SourceTable  sysname      NOT NULL,
    JoinOn       nvarchar(400) NULL,
    ExpectedRows bigint       NULL,
    Note         nvarchar(200) NULL
);

IF OBJECT_ID('tempdb..#Doc') IS NOT NULL DROP TABLE #Doc;
CREATE TABLE #Doc (
    ProcessCode sysname     NOT NULL,
    Strategy    varchar(20) NOT NULL,
    Mode        varchar(10) NOT NULL,
    CutoffUtc   datetime2(0) NULL,
    Documents   bigint      NULL
);

------------------------------------------------------------------------------
-- Walk every enabled process
------------------------------------------------------------------------------
DECLARE @pid int, @code sysname, @strategy varchar(20), @srcDb sysname,
        @retention int, @lag int, @anchorSchema sysname, @anchorTable sysname,
        @anchorTs nvarchar(max), @anchorWhere nvarchar(max),
        @cut datetime2(0), @mode varchar(10), @keySelect nvarchar(max),
        @keyQuery nvarchar(max), @docs bigint, @sql nvarchar(max);

DECLARE cP CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.ProcessId, p.ProcessCode, p.SelectionStrategy, pd.SourceDb,
           p.RetentionDays, p.CutoffSafetyLagMinutes,
           p.AnchorSchema, p.AnchorTable, p.AnchorTimestampExpr, p.AnchorExtraWhereSql
    FROM arch.Process p
    JOIN arch.ProcessDatabase pd ON pd.ProcessId = p.ProcessId AND pd.IsEnabled = 1
    WHERE p.IsEnabled = 1
      AND (@ProcessFilter IS NULL OR p.ProcessCode = @ProcessFilter)
    ORDER BY p.ProcessCode;

OPEN cP;
FETCH NEXT FROM cP INTO @pid, @code, @strategy, @srcDb, @retention, @lag,
                        @anchorSchema, @anchorTable, @anchorTs, @anchorWhere;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @cut = DATEADD(MINUTE, -@lag, DATEADD(DAY, -@retention, CONVERT(datetime2(0), SYSUTCDATETIME())));

    ------------------------------------------------------------------------
    -- SAFETY GATE - run BEFORE anything is concatenated into dynamic SQL.
    --
    -- This script composes its queries from configuration TEXT: join predicates,
    -- gates, timestamp expressions, key expressions. That is the same thing the
    -- runtime does, so it inherits the same exposure, and it gets the same
    -- defence: arch.usp_AssertSafeSqlExpression, the product's own gate. It
    -- refuses statements, comments, DDL/DML keywords, procedure calls and
    -- subqueries, and THROWs 50400 rather than returning a verdict.
    --
    -- Without this a row edited straight into arch.ObjectSpec - past the API,
    -- which is how five specs appeared here on 2026-09-15 - could put anything it
    -- liked into a query this script then executes. A counting script must not be
    -- the weakest door in the building.
    ------------------------------------------------------------------------
    DECLARE @frag nvarchar(max), @fragName nvarchar(200);
    DECLARE cV CURSOR LOCAL FAST_FORWARD FOR
        SELECT N'Process.AnchorTimestampExpr',   p.AnchorTimestampExpr   FROM arch.Process p WHERE p.ProcessId = @pid AND NULLIF(LTRIM(RTRIM(p.AnchorTimestampExpr)), N'')   IS NOT NULL
        UNION ALL
        SELECT N'Process.AnchorExtraWhereSql',   p.AnchorExtraWhereSql   FROM arch.Process p WHERE p.ProcessId = @pid AND NULLIF(LTRIM(RTRIM(p.AnchorExtraWhereSql)), N'')   IS NOT NULL
        UNION ALL
        SELECT N'ProcessKeySpec.SourceExpressionSql', ks.SourceExpressionSql FROM arch.ProcessKeySpec ks WHERE ks.ProcessId = @pid
        UNION ALL
        SELECT N'ObjectSpec.JoinToAnchorPredicateSql', o.JoinToAnchorPredicateSql FROM arch.ObjectSpec o WHERE o.ProcessId = @pid AND NULLIF(LTRIM(RTRIM(o.JoinToAnchorPredicateSql)), N'') IS NOT NULL
        UNION ALL
        SELECT N'ObjectSpec.AdditionalWhereSql', o.AdditionalWhereSql FROM arch.ObjectSpec o WHERE o.ProcessId = @pid AND NULLIF(LTRIM(RTRIM(o.AdditionalWhereSql)), N'') IS NOT NULL
        UNION ALL
        SELECT N'ObjectSpec.TimestampExpr', o.TimestampExpr FROM arch.ObjectSpec o WHERE o.ProcessId = @pid AND NULLIF(LTRIM(RTRIM(o.TimestampExpr)), N'') IS NOT NULL;
    OPEN cV; FETCH NEXT FROM cV INTO @fragName, @frag;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC arch.usp_AssertSafeSqlExpression @Expression = @frag, @FieldName = @fragName;
        FETCH NEXT FROM cV INTO @fragName, @frag;
    END;
    CLOSE cV; DEALLOCATE cV;

    -- EXACT when this process has keys that are still to be processed.
    -- Status 0 = prepared, 1 = claimed. 2 = done and 5 = parked by a legal hold,
    -- and neither will move, so neither is counted.
    SET @mode = CASE WHEN EXISTS (
                        SELECT 1 FROM arch.WorkBatch wb
                        JOIN arch.WorkBatchKey k ON k.WorkBatchId = wb.WorkBatchId
                        WHERE wb.ProcessId = @pid AND k.Status IN (0, 1))
                     THEN 'EXACT' ELSE 'DERIVED' END;

    ------------------------------------------------------------------------
    -- Build the key source: either the real prepared keys, or the same
    -- selection PREP would make.
    ------------------------------------------------------------------------
    IF @mode = 'EXACT'
    BEGIN
        SET @keyQuery = N'(SELECT k.Key1, k.Key2, k.Key3, k.Key4, k.Key5, k.Key6, k.Key7, k.Key8
                           FROM arch.WorkBatch wb
                           JOIN arch.WorkBatchKey k ON k.WorkBatchId = wb.WorkBatchId
                           WHERE wb.ProcessId = ' + CONVERT(nvarchar(12), @pid) + N'
                             AND k.Status IN (0,1))';
    END
    ELSE
    BEGIN
        -- Every declared key, projected under its own name, so a join predicate
        -- that reaches for Key3..Key6 (the ADV log set does) still resolves.
        SET @keySelect = NULL;
        SELECT @keySelect = COALESCE(@keySelect + N', ', N'') + ks.SourceExpressionSql + N' AS Key' + CONVERT(nvarchar(2), ks.KeyOrdinal)
        FROM arch.ProcessKeySpec ks WHERE ks.ProcessId = @pid ORDER BY ks.KeyOrdinal;

        IF @strategy = 'ANCHOR'
        BEGIN
            -- Key expressions are written against the anchor as "a".
            SET @keyQuery = N'(SELECT ' + @keySelect + N'
                               FROM ' + QUOTENAME(@srcDb) + N'.' + QUOTENAME(@anchorSchema) + N'.' + QUOTENAME(@anchorTable) + N' a WITH (NOLOCK)
                               WHERE ' + CASE WHEN NULLIF(LTRIM(RTRIM(@anchorWhere)), N'') IS NULL THEN N'1=1'
                                              ELSE N'(' + @anchorWhere + N')' END + N'
                                 AND ' + @anchorTs + N' < @cut)';
        END
        ELSE
        BEGIN
            -- TIMESTAMP: the DRIVING object is the lowest DeleteOrder. It carries
            -- the real timestamp and the gate; the rest ride its keys. Their
            -- TimestampExpr is a 1900 sentinel and must not be used here.
            DECLARE @drvSchema sysname, @drvTable sysname, @drvTs nvarchar(max), @drvWhere nvarchar(max);
            SELECT TOP 1 @drvSchema = o.SourceSchema, @drvTable = o.SourceTable,
                         @drvTs = o.TimestampExpr, @drvWhere = o.AdditionalWhereSql
            FROM arch.ObjectSpec o WHERE o.ProcessId = @pid ORDER BY o.DeleteOrder;

            -- Key expressions for a TIMESTAMP process are written against "t".
            SET @keyQuery = N'(SELECT ' + @keySelect + N'
                               FROM ' + QUOTENAME(@srcDb) + N'.' + QUOTENAME(@drvSchema) + N'.' + QUOTENAME(@drvTable) + N' t WITH (NOLOCK)
                               WHERE ' + CASE WHEN NULLIF(LTRIM(RTRIM(@drvWhere)), N'') IS NULL THEN N'1=1'
                                              ELSE N'(' + @drvWhere + N')' END + N'
                                 AND ' + @drvTs + N' < @cut)';
        END;
    END;

    ------------------------------------------------------------------------
    -- How many documents
    ------------------------------------------------------------------------
    SET @docs = NULL;
    BEGIN TRY
        SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @keyQuery + N' AS k;';
        EXEC sys.sp_executesql @sql, N'@cut datetime2(0), @n bigint OUTPUT', @cut = @cut, @n = @docs OUTPUT;
    END TRY
    BEGIN CATCH
        SET @docs = NULL;
    END CATCH;

    INSERT #Doc (ProcessCode, Strategy, Mode, CutoffUtc, Documents)
    VALUES (@code, @strategy, @mode, @cut, @docs);

    ------------------------------------------------------------------------
    -- How many rows per table - the answer being looked for
    ------------------------------------------------------------------------
    DECLARE @oSchema sysname, @oTable sysname, @oJoin nvarchar(max), @oWhere nvarchar(max), @oOrder int, @rows bigint;
    DECLARE cO CURSOR LOCAL FAST_FORWARD FOR
        SELECT o.DeleteOrder, o.SourceSchema, o.SourceTable, o.JoinToAnchorPredicateSql, o.AdditionalWhereSql
        FROM arch.ObjectSpec o WHERE o.ProcessId = @pid ORDER BY o.DeleteOrder;
    OPEN cO;
    FETCH NEXT FROM cO INTO @oOrder, @oSchema, @oTable, @oJoin, @oWhere;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @rows = NULL;
        BEGIN TRY
            SET @sql = N'SELECT @n = COUNT_BIG(*)
                         FROM ' + QUOTENAME(@srcDb) + N'.' + QUOTENAME(@oSchema) + N'.' + QUOTENAME(@oTable) + N' t WITH (NOLOCK)
                         INNER JOIN ' + @keyQuery + N' AS k ON ' + @oJoin
                       + CASE WHEN NULLIF(LTRIM(RTRIM(@oWhere)), N'') IS NULL THEN N''
                              ELSE N' WHERE (' + @oWhere + N')' END + N';';
            EXEC sys.sp_executesql @sql, N'@cut datetime2(0), @n bigint OUTPUT', @cut = @cut, @n = @rows OUTPUT;
        END TRY
        BEGIN CATCH
            SET @rows = NULL;
        END CATCH;

        INSERT #Vol (ProcessCode, Strategy, Mode, DeleteOrder, SourceDb, SourceTable, JoinOn, ExpectedRows, Note)
        VALUES (@code, @strategy, @mode, @oOrder, @srcDb, @oTable, LEFT(@oJoin, 400), @rows,
                CASE WHEN @rows IS NULL THEN N'could not be counted - see the join predicate' ELSE NULL END);

        FETCH NEXT FROM cO INTO @oOrder, @oSchema, @oTable, @oJoin, @oWhere;
    END;
    CLOSE cO; DEALLOCATE cO;

    FETCH NEXT FROM cP INTO @pid, @code, @strategy, @srcDb, @retention, @lag,
                            @anchorSchema, @anchorTable, @anchorTs, @anchorWhere;
END;
CLOSE cP; DEALLOCATE cP;

------------------------------------------------------------------------------
-- A) Per set: how many documents, under which cutoff, and how we know
------------------------------------------------------------------------------
PRINT '';
PRINT '=== A) Documents the next run will take, per set ===';
SELECT Section = 'A_DOCUMENTS', ProcessCode, Strategy, Basis = Mode,
       CutoffUtc, Documents
FROM #Doc ORDER BY Documents DESC;

------------------------------------------------------------------------------
-- B) Per table: the rows that will be archived and then deleted
------------------------------------------------------------------------------
PRINT '';
PRINT '=== B) Rows per table (archived, then deleted from the source) ===';
SELECT Section = 'B_PER_TABLE', ProcessCode, DeleteOrder,
       SourceTable = SourceDb + '.' + SourceTable,
       ExpectedRows, Basis = Mode, Note
FROM #Vol ORDER BY ProcessCode, DeleteOrder;

PRINT '';
PRINT '=== B2) Same thing, biggest first - the one to show ===';
SELECT Section = 'B2_TOP', SourceTable = SourceDb + '.' + SourceTable,
       ProcessCode, ExpectedRows
FROM #Vol WHERE ISNULL(ExpectedRows, 0) > 0 ORDER BY ExpectedRows DESC;

SELECT Section = 'B3_TOTAL',
       Tables      = COUNT(*),
       TablesMoving= SUM(CASE WHEN ISNULL(ExpectedRows,0) > 0 THEN 1 ELSE 0 END),
       TotalRows   = SUM(ISNULL(ExpectedRows, 0)),
       Uncounted   = SUM(CASE WHEN ExpectedRows IS NULL THEN 1 ELSE 0 END)
FROM #Vol;

------------------------------------------------------------------------------
-- C) What STAYS - the other half of the story, and the better one
--
--    A number for what leaves proves throughput. A number for what stays proves
--    selectivity, and that is the question an audience is actually asking.
------------------------------------------------------------------------------
PRINT '';
PRINT '=== C) What stays in the source, and why ===';

DECLARE @stay TABLE (ProcessCode sysname, AnchorTable sysname, TotalRows bigint, Eligible bigint, Staying bigint);
DECLARE @aSchema2 sysname, @aTable2 sysname, @total bigint, @elig bigint;

DECLARE cS CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.ProcessCode, pd.SourceDb,
           COALESCE(p.AnchorSchema, (SELECT TOP 1 o.SourceSchema FROM arch.ObjectSpec o WHERE o.ProcessId = p.ProcessId ORDER BY o.DeleteOrder)),
           COALESCE(p.AnchorTable,  (SELECT TOP 1 o.SourceTable  FROM arch.ObjectSpec o WHERE o.ProcessId = p.ProcessId ORDER BY o.DeleteOrder))
    FROM arch.Process p
    JOIN arch.ProcessDatabase pd ON pd.ProcessId = p.ProcessId AND pd.IsEnabled = 1
    WHERE p.IsEnabled = 1 AND (@ProcessFilter IS NULL OR p.ProcessCode = @ProcessFilter)
    ORDER BY p.ProcessCode;
OPEN cS;
FETCH NEXT FROM cS INTO @code, @srcDb, @aSchema2, @aTable2;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @total = NULL;
    SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + QUOTENAME(@srcDb) + N'.' + QUOTENAME(@aSchema2) + N'.' + QUOTENAME(@aTable2) + N' WITH (NOLOCK);';
    BEGIN TRY EXEC sys.sp_executesql @sql, N'@n bigint OUTPUT', @n = @total OUTPUT; END TRY BEGIN CATCH SET @total = NULL; END CATCH;

    SELECT @elig = ExpectedRows FROM #Vol
    WHERE ProcessCode = @code AND SourceTable = @aTable2;

    INSERT @stay VALUES (@code, @aTable2, @total, @elig, @total - ISNULL(@elig, 0));
    FETCH NEXT FROM cS INTO @code, @srcDb, @aSchema2, @aTable2;
END;
CLOSE cS; DEALLOCATE cS;

SELECT Section = 'C_STAYS', ProcessCode, AnchorTable, TotalRows, Leaving = Eligible, Staying,
       Comment = N'rows held back by the gate or still inside the retention window'
FROM @stay ORDER BY ProcessCode;

PRINT '';
PRINT 'Basis = EXACT  : counted from the prepared keys. This IS what the run will move.';
PRINT 'Basis = DERIVED: the gate and cutoff re-applied to the source. Run PREP and';
PRINT '                 repeat for an exact figure - PREP deletes nothing.';
PRINT '';
PRINT 'The console''s Analysis & Estimates screen answers a different question -';
PRINT 'how BIG the configured tables are and how much room the run needs. Show both:';
PRINT 'that screen for capacity, this script for scope.';
