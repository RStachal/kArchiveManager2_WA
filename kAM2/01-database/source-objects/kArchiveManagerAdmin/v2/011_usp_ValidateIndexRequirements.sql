USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_ValidateIndexRequirements]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Findings
    (
        Severity varchar(10) NOT NULL,
        ProcessCode sysname NOT NULL,
        SourceDb sysname NULL,
        ObjectName nvarchar(300) NOT NULL,
        RequirementType nvarchar(20) NOT NULL,
        KeyColumnsCsv nvarchar(1000) NOT NULL,
        Finding nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL   -- concrete remediation DDL the operator can copy/run
    );

    IF OBJECT_ID(N'arch.IndexRequirement', N'U') IS NULL
    BEGIN
        INSERT #Findings(Severity, ProcessCode, ObjectName, RequirementType, KeyColumnsCsv, Finding)
        VALUES
        (
            'ERROR',
            COALESCE(@ProcessCode, N'*'),
            N'arch.IndexRequirement',
            N'METADATA',
            N'',
            N'arch.IndexRequirement does not exist. Run v2/010_universal_archive_core.sql first.'
        );

        SELECT Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding
        FROM #Findings;

        RETURN 1;
    END;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding)
    SELECT
        CASE WHEN ir.IsMandatory = 1 THEN 'ERROR' ELSE 'WARN' END,
        p.ProcessCode,
        e.SourceDb,
        QUOTENAME(COALESCE(os.SourceSchema, ir.SourceSchema)) + N'.' + QUOTENAME(COALESCE(os.SourceTable, ir.SourceTable)),
        ir.RequirementType,
        ir.KeyColumnsCsv,
        N'Index requirement has an empty KeyColumnsCsv.'
    FROM arch.IndexRequirement ir
    JOIN arch.Process p
      ON p.ProcessId = ir.ProcessId
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessId = p.ProcessId
    LEFT JOIN arch.v_ObjectSpecDatabaseEffective os
      ON os.ProcessDatabaseId = e.ProcessDatabaseId
     AND os.ObjectSpecId = ir.ObjectSpecId
     AND os.ObjectIsEnabled = 1
    WHERE (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND e.IsEnabled = 1
      AND (ir.ObjectSpecId IS NULL OR os.ObjectSpecId IS NOT NULL)
      AND NULLIF(LTRIM(RTRIM(ir.KeyColumnsCsv)), N'') IS NULL;

    DECLARE
        @p sysname,
        @src sysname,
        @schema sysname,
        @table sysname,
        @rtype nvarchar(20),
        @keys nvarchar(1000),
        @mandatory bit,
        @sql nvarchar(max);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT
            p.ProcessCode,
            e.SourceDb,
            COALESCE(os.SourceSchema, ir.SourceSchema) AS SourceSchema,
            COALESCE(os.SourceTable, ir.SourceTable) AS SourceTable,
            ir.RequirementType,
            ir.KeyColumnsCsv,
            ir.IsMandatory
        FROM arch.IndexRequirement ir
        JOIN arch.Process p
          ON p.ProcessId = ir.ProcessId
        JOIN arch.v_ProcessDatabaseEffective e
          ON e.ProcessId = p.ProcessId
        LEFT JOIN arch.v_ObjectSpecDatabaseEffective os
          ON os.ProcessDatabaseId = e.ProcessDatabaseId
         AND os.ObjectSpecId = ir.ObjectSpecId
         AND os.ObjectIsEnabled = 1
        WHERE e.IsEnabled = 1
          AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
          AND DB_ID(e.SourceDb) IS NOT NULL
          AND (ir.ObjectSpecId IS NULL OR os.ObjectSpecId IS NOT NULL)
          AND NULLIF(LTRIM(RTRIM(ir.KeyColumnsCsv)), N'') IS NOT NULL;

    OPEN c;
    FETCH NEXT FROM c INTO @p, @src, @schema, @table, @rtype, @keys, @mandatory;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        CREATE TABLE #RequiredColumns
        (
            ColumnName sysname NOT NULL PRIMARY KEY
        );

        DECLARE @xml xml = TRY_CAST(N'<x><v>' + REPLACE(REPLACE(REPLACE(@keys, N'&', N'&amp;'), N'<', N'&lt;'), N',', N'</v><v>') + N'</v></x>' AS xml);

        IF @xml IS NOT NULL
        BEGIN
            INSERT #RequiredColumns(ColumnName)
            SELECT DISTINCT
                CONVERT(sysname, REPLACE(REPLACE(LTRIM(RTRIM(T.C.value(N'.', N'nvarchar(256)'))), N'[', N''), N']', N''))
            FROM @xml.nodes(N'/x/v') AS T(C)
            WHERE NULLIF(LTRIM(RTRIM(T.C.value(N'.', N'nvarchar(256)'))), N'') IS NOT NULL;
        END;

        IF NOT EXISTS (SELECT 1 FROM #RequiredColumns)
        BEGIN
            INSERT #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding)
            VALUES
            (
                CASE WHEN @mandatory = 1 THEN 'ERROR' ELSE 'WARN' END,
                @p,
                @src,
                QUOTENAME(@schema) + N'.' + QUOTENAME(@table),
                @rtype,
                @keys,
                N'Index requirement did not parse into any required columns.'
            );

            DROP TABLE #RequiredColumns;

            FETCH NEXT FROM c INTO @p, @src, @schema, @table, @rtype, @keys, @mandatory;
            CONTINUE;
        END;

        SET @sql = N'
IF NOT EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(@src) + N'.sys.tables t
    JOIN ' + QUOTENAME(@src) + N'.sys.schemas s
      ON s.schema_id = t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @pSchema COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @pTable COLLATE DATABASE_DEFAULT
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding)
    VALUES
    (
        CASE WHEN @pMandatory = 1 THEN ''ERROR'' ELSE ''WARN'' END,
        @pProcessCode,
        @pSourceDb,
        QUOTENAME(@pSchema) + N''.'' + QUOTENAME(@pTable),
        @pRequirementType,
        @pKeyColumnsCsv,
        N''Source table for index requirement does not exist.''
    );
END
ELSE IF EXISTS
(
    SELECT rc.ColumnName
    FROM #RequiredColumns rc
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM ' + QUOTENAME(@src) + N'.sys.columns c
        JOIN ' + QUOTENAME(@src) + N'.sys.tables t
          ON t.object_id = c.object_id
        JOIN ' + QUOTENAME(@src) + N'.sys.schemas s
          ON s.schema_id = t.schema_id
        WHERE s.name COLLATE DATABASE_DEFAULT = @pSchema COLLATE DATABASE_DEFAULT
          AND t.name COLLATE DATABASE_DEFAULT = @pTable COLLATE DATABASE_DEFAULT
          AND c.name COLLATE DATABASE_DEFAULT = rc.ColumnName COLLATE DATABASE_DEFAULT
    )
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding)
    VALUES
    (
        CASE WHEN @pMandatory = 1 THEN ''ERROR'' ELSE ''WARN'' END,
        @pProcessCode,
        @pSourceDb,
        QUOTENAME(@pSchema) + N''.'' + QUOTENAME(@pTable),
        @pRequirementType,
        @pKeyColumnsCsv,
        N''At least one required index column does not exist on the source table.''
    );
END
ELSE IF NOT EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(@src) + N'.sys.indexes i
    JOIN ' + QUOTENAME(@src) + N'.sys.tables t
      ON t.object_id = i.object_id
    JOIN ' + QUOTENAME(@src) + N'.sys.schemas s
      ON s.schema_id = t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @pSchema COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @pTable COLLATE DATABASE_DEFAULT
      AND i.is_disabled = 0
      AND NOT EXISTS
      (
          SELECT 1
          FROM #RequiredColumns rc
          WHERE NOT EXISTS
          (
              SELECT 1
              FROM ' + QUOTENAME(@src) + N'.sys.index_columns ic
              JOIN ' + QUOTENAME(@src) + N'.sys.columns c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.is_included_column = 0
                AND c.name COLLATE DATABASE_DEFAULT = rc.ColumnName COLLATE DATABASE_DEFAULT
          )
      )
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding)
    VALUES
    (
        ''WARN'',   /* A missing supporting index must NEVER block processing - always WARN, never ERROR.
                       The operator can create it from Admin Console -> Validation -> Indexes (Suggested SQL). */
        @pProcessCode,
        @pSourceDb,
        QUOTENAME(@pSchema) + N''.'' + QUOTENAME(@pTable),
        @pRequirementType,
        @pKeyColumnsCsv,
        N''No enabled source index contains all required key columns as key columns. Processing is NOT blocked; create the index from the Suggested SQL for seek quality.''
    );
END;';

        EXEC sys.sp_executesql
            @sql,
            N'@pProcessCode sysname,
              @pSourceDb sysname,
              @pSchema sysname,
              @pTable sysname,
              @pRequirementType nvarchar(20),
              @pKeyColumnsCsv nvarchar(1000),
              @pMandatory bit',
            @pProcessCode = @p,
            @pSourceDb = @src,
            @pSchema = @schema,
            @pTable = @table,
            @pRequirementType = @rtype,
            @pKeyColumnsCsv = @keys,
            @pMandatory = @mandatory;

        DROP TABLE #RequiredColumns;

        FETCH NEXT FROM c INTO @p, @src, @schema, @table, @rtype, @keys, @mandatory;
    END

    CLOSE c;
    DEALLOCATE c;

    /* Concrete remediation SQL. Missing supporting index -> the exact CREATE INDEX (key columns in the
       declared order, bracketed). Note: column-order/seek quality still warrants a manual review; this is
       a ready-to-run starting point. KeyColumnsCsv order is preserved by string-splitting (no STRING_SPLIT
       ordinal, so it stays portable to SQL 2019). */
    UPDATE #Findings
    SET SuggestedSql =
        N'USE ' + QUOTENAME(SourceDb) + N'; CREATE NONCLUSTERED INDEX '
      + QUOTENAME(LEFT(N'IX_kAM_' + RequirementType + N'_' + REPLACE(REPLACE(REPLACE(ObjectName, N'[', N''), N']', N''), N'.', N'_'), 116))
      + N' ON ' + ObjectName + N' ([' + REPLACE(REPLACE(KeyColumnsCsv, N' ', N''), N',', N'],[') + N']);'
    WHERE Finding LIKE N'No enabled source index%'
      AND SourceDb IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(KeyColumnsCsv)), N'') IS NOT NULL;

    UPDATE #Findings
    SET SuggestedSql = N'-- ' + Finding + N' (fix the source schema or correct arch.IndexRequirement for ' + ObjectName + N')'
    WHERE SuggestedSql IS NULL
      AND (Finding LIKE N'Source table%' OR Finding LIKE N'At least one required index column%');

    SELECT Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding, SuggestedSql
    FROM #Findings
    ORDER BY CASE Severity WHEN 'ERROR' THEN 0 ELSE 1 END, ProcessCode, SourceDb, ObjectName, RequirementType;

    IF EXISTS (SELECT 1 FROM #Findings WHERE Severity = 'ERROR')
        RETURN 1;

    RETURN 0;
END
GO
