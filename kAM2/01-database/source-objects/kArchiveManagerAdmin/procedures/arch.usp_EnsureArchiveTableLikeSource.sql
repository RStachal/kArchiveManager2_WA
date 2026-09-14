USE [kArchiveManagerAdmin]
GO
/****** Object:  StoredProcedure [arch].[usp_EnsureArchiveTableLikeSource]    Script Date: 27.04.2026 14:59:31 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE OR ALTER PROCEDURE [arch].[usp_EnsureArchiveTableLikeSource]
    @SourceDb       sysname,
    @ArchiveDb      sysname,
    @SourceSchema   sysname,
    @SourceTable    sysname,
    @ArchiveSchema  sysname = N'dbo',
    @ArchiveTable   sysname = NULL,
    @MakeAllNullable bit = 1,
    @IncludeComputed bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ArchiveSchema = COALESCE(NULLIF(LTRIM(RTRIM(@ArchiveSchema)), N''), N'{SourceDb}');
    IF @ArchiveSchema = N'dbo'
        SET @ArchiveSchema = N'{SourceDb}';
    SET @ArchiveSchema = CONVERT(nvarchar(128), REPLACE(@ArchiveSchema, N'{SourceDb}', @SourceDb));

    IF @ArchiveTable IS NULL SET @ArchiveTable = @SourceTable;

    DECLARE @dstObj nvarchar(600) =
        QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@ArchiveSchema) + N'.' + QUOTENAME(@ArchiveTable);

    /* 1) ensure schema exists in archive db */
    DECLARE @schemaExists bit;
    DECLARE @chkSchema nvarchar(max) = N'
SELECT @e = CASE WHEN EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(@ArchiveDb) + N'.sys.schemas
    WHERE name COLLATE DATABASE_DEFAULT = @sch COLLATE DATABASE_DEFAULT
) THEN 1 ELSE 0 END;';
    EXEC sys.sp_executesql
        @chkSchema,
        N'@sch sysname, @e bit OUTPUT',
        @sch=@ArchiveSchema, @e=@schemaExists OUTPUT;

    IF @schemaExists = 0
    BEGIN
        DECLARE @createSchema nvarchar(max) =
            N'USE ' + QUOTENAME(@ArchiveDb) + N'; EXEC(N''CREATE SCHEMA ' +
            REPLACE(QUOTENAME(@ArchiveSchema), N'''', N'''''') + N' AUTHORIZATION dbo'');';
        EXEC (@createSchema);
    END

    /* 2) check if table exists */
    DECLARE @exists bit;
    DECLARE @chk nvarchar(max) = N'
SELECT @e = CASE WHEN EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(@ArchiveDb) + N'.sys.tables t
    JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.schemas s ON s.schema_id=t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @sch COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @tbl COLLATE DATABASE_DEFAULT
) THEN 1 ELSE 0 END;';
    EXEC sys.sp_executesql
        @chk,
        N'@sch sysname, @tbl sysname, @e bit OUTPUT',
        @sch=@ArchiveSchema, @tbl=@ArchiveTable, @e=@exists OUTPUT;

    /* 3) load source columns */
    CREATE TABLE #cols
    (
        column_id   int NOT NULL,
        colname     sysname NOT NULL,
        type_sql    nvarchar(4000) NOT NULL,
        is_nullable bit NOT NULL,
        sys_type    sysname NULL,   -- T-19: raw metadata for source-vs-archive drift reconciliation
        max_length  int NULL,
        [precision] int NULL,
        scale       int NULL
    );

    DECLARE @loadCols nvarchar(max) = N'
;WITH c AS
(
    SELECT
        c.column_id,
        c.name AS colname,
        c.is_nullable,
        c.is_computed,
        st.name AS system_type_name,
        c.max_length,
        c.precision,
        c.scale,
        c.collation_name
    FROM ' + QUOTENAME(@SourceDb) + N'.sys.columns c
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.objects o ON o.object_id=c.object_id
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.schemas s ON s.schema_id=o.schema_id
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.types ut ON ut.user_type_id=c.user_type_id
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.types st ON st.user_type_id=ut.system_type_id AND st.is_user_defined=0
    WHERE s.name COLLATE DATABASE_DEFAULT = @srcSchema COLLATE DATABASE_DEFAULT
      AND o.name COLLATE DATABASE_DEFAULT = @srcTable COLLATE DATABASE_DEFAULT
      AND o.type=''U''
      AND (@IncludeComputed=1 OR c.is_computed=0)
)
INSERT #cols(column_id, colname, type_sql, is_nullable, sys_type, max_length, [precision], scale)
SELECT
    column_id,
    colname,
    CASE
        WHEN system_type_name IN (N''timestamp'', N''rowversion'') THEN N''binary(8)''
        WHEN system_type_name IN (N''varchar'', N''char'', N''varbinary'', N''binary'')
            THEN system_type_name + N''('' + CASE WHEN max_length=-1 THEN N''max'' ELSE CAST(max_length AS nvarchar(10)) END + N'')''
        WHEN system_type_name IN (N''nvarchar'', N''nchar'')
            THEN system_type_name + N''('' + CASE WHEN max_length=-1 THEN N''max'' ELSE CAST(max_length/2 AS nvarchar(10)) END + N'')''
        WHEN system_type_name IN (N''decimal'', N''numeric'')
            THEN system_type_name + N''('' + CAST(precision AS nvarchar(10)) + N'','' + CAST(scale AS nvarchar(10)) + N'')''
        WHEN system_type_name IN (N''datetime2'', N''datetimeoffset'', N''time'')
            THEN system_type_name + N''('' + CAST(scale AS nvarchar(10)) + N'')''
        ELSE system_type_name
    END
    /* fix COLLATE: do NOT bracket collation name */
    + CASE
        WHEN system_type_name IN (N''varchar'',N''char'',N''nvarchar'',N''nchar'')
             AND collation_name IS NOT NULL
             THEN N'' COLLATE '' + collation_name
        ELSE N''''
      END AS type_sql,
    CASE WHEN @MakeAllNullable=1 THEN 1 ELSE is_nullable END,
    /* T-19 fix: a source timestamp/rowversion column is archived as binary(8) (see type_sql above),
       so record its drift-comparison sys_type as ''binary'' too — otherwise the reconcile guard
       compares raw ''timestamp'' vs the archive''s ''binary'' and falsely BLOCKs (THROW 50410). */
    CASE WHEN system_type_name IN (N''timestamp'', N''rowversion'') THEN N''binary'' ELSE system_type_name END,
    max_length, precision, scale
FROM c
ORDER BY column_id;
';
    EXEC sys.sp_executesql
        @loadCols,
        N'@srcSchema sysname, @srcTable sysname, @MakeAllNullable bit, @IncludeComputed bit',
        @srcSchema=@SourceSchema, @srcTable=@SourceTable,
        @MakeAllNullable=@MakeAllNullable, @IncludeComputed=@IncludeComputed;

    IF NOT EXISTS (SELECT 1 FROM #cols)
    BEGIN
        DROP TABLE #cols;
        RAISERROR(N'Source table has no archivable columns or does not exist: %s.%s.%s', 16, 1, @SourceDb, @SourceSchema, @SourceTable);
        RETURN;
    END

    /* 4) CREATE TABLE if missing */
    IF @exists = 0
    BEGIN
        DECLARE @colDef nvarchar(max) = N'';
        SELECT @colDef = @colDef +
            CASE WHEN @colDef = N'' THEN N'' ELSE N',' + CHAR(10) END +
            N'    ' + QUOTENAME(colname) + N' ' + type_sql + N' ' + CASE WHEN is_nullable=1 THEN N'NULL' ELSE N'NOT NULL' END
        FROM #cols
        ORDER BY column_id;

        DECLARE @create nvarchar(max) = N'CREATE TABLE ' + @dstObj + N'(' + CHAR(10) + @colDef + CHAR(10) + N');';
        EXEC (@create);

        INSERT arch.ArchiveProvisionLog(SourceDb,ArchiveDb,SourceSchema,SourceTable,Action,Details)
        VALUES (@SourceDb,@ArchiveDb,@SourceSchema,@SourceTable,N'CREATE_TABLE',@create);
    END
    ELSE
    BEGIN
        /* 5) add missing columns */
        CREATE TABLE #archCols(colname sysname NOT NULL PRIMARY KEY);

        DECLARE @loadArch nvarchar(max) = N'
INSERT #archCols(colname)
SELECT c.name
FROM ' + QUOTENAME(@ArchiveDb) + N'.sys.columns c
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.objects o ON o.object_id=c.object_id
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.schemas s ON s.schema_id=o.schema_id
WHERE s.name COLLATE DATABASE_DEFAULT = @sch COLLATE DATABASE_DEFAULT
  AND o.name COLLATE DATABASE_DEFAULT = @tbl COLLATE DATABASE_DEFAULT
  AND o.type=''U'';';
        EXEC sys.sp_executesql @loadArch, N'@sch sysname,@tbl sysname', @sch=@ArchiveSchema, @tbl=@ArchiveTable;

        DECLARE @alter nvarchar(max) = N'';
        SELECT @alter = @alter +
            N'ALTER TABLE ' + @dstObj + N' ADD ' + QUOTENAME(c.colname) + N' ' + c.type_sql + N' NULL;' + CHAR(10)
        FROM #cols c
        LEFT JOIN #archCols a ON a.colname=c.colname
        WHERE a.colname IS NULL;

        IF @alter <> N''
        BEGIN
            EXEC (@alter);
            INSERT arch.ArchiveProvisionLog(SourceDb,ArchiveDb,SourceSchema,SourceTable,Action,Details)
            VALUES (@SourceDb,@ArchiveDb,@SourceSchema,@SourceTable,N'ADD_COLUMNS',@alter);
        END

        /* 6) T-19: reconcile EXISTING columns. The archive is the ONLY copy of deleted rows, so a
              source column that grew (varchar(50)->(100), int->bigger, more decimal precision, deeper
              datetime2 scale) must NOT be allowed to silently truncate/overflow on the next
              DELETE...OUTPUT INTO. Same-type growth is auto-WIDENED (never narrowed); any incompatible
              type change BLOCKS the run (THROW 50410) until an operator reconciles it. */
        CREATE TABLE #archMeta
        (
            colname    sysname NOT NULL PRIMARY KEY,
            sys_type   sysname NULL,
            max_length int NULL,
            [precision] int NULL,
            scale      int NULL
        );

        DECLARE @loadArchMeta nvarchar(max) = N'
INSERT #archMeta(colname, sys_type, max_length, [precision], scale)
SELECT c.name, st.name, c.max_length, c.precision, c.scale
FROM ' + QUOTENAME(@ArchiveDb) + N'.sys.columns c
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.objects o ON o.object_id=c.object_id
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.schemas s ON s.schema_id=o.schema_id
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.types ut ON ut.user_type_id=c.user_type_id
JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.types st ON st.user_type_id=ut.system_type_id AND st.is_user_defined=0
WHERE s.name COLLATE DATABASE_DEFAULT=@sch COLLATE DATABASE_DEFAULT
  AND o.name COLLATE DATABASE_DEFAULT=@tbl COLLATE DATABASE_DEFAULT
  AND o.type=''U'';';
        EXEC sys.sp_executesql @loadArchMeta, N'@sch sysname,@tbl sysname', @sch=@ArchiveSchema, @tbl=@ArchiveTable;

        ;WITH cmp AS
        (
            SELECT c.colname, c.type_sql,
                   src_type=c.sys_type, arc_type=a.sys_type,
                   src_len=c.max_length, arc_len=a.max_length,
                   src_p=c.[precision], arc_p=a.[precision],
                   src_s=c.scale, arc_s=a.scale,
                   src_eff=CASE WHEN c.max_length=-1 THEN 2147483647 ELSE c.max_length END,
                   arc_eff=CASE WHEN a.max_length=-1 THEN 2147483647 ELSE a.max_length END
            FROM #cols c
            JOIN #archMeta a ON a.colname=c.colname
            WHERE c.sys_type<>a.sys_type OR c.max_length<>a.max_length
               OR c.[precision]<>a.[precision] OR c.scale<>a.scale
        )
        SELECT cmp.*,
            action = CASE
                WHEN src_type=arc_type
                     AND src_type IN (N'varchar',N'nvarchar',N'char',N'nchar',N'varbinary',N'binary')
                     AND src_eff>arc_eff THEN N'WIDEN'
                WHEN src_type=arc_type AND src_type IN (N'decimal',N'numeric')
                     AND src_p>=arc_p AND src_s>=arc_s AND (src_p>arc_p OR src_s>arc_s) THEN N'WIDEN'
                WHEN src_type=arc_type AND src_type IN (N'datetime2',N'datetimeoffset',N'time')
                     AND src_s>arc_s THEN N'WIDEN'
                WHEN src_type=arc_type
                     AND ( (src_type IN (N'varchar',N'nvarchar',N'char',N'nchar',N'varbinary',N'binary') AND src_eff<=arc_eff)
                        OR (src_type IN (N'decimal',N'numeric') AND src_p<=arc_p AND src_s<=arc_s)
                        OR (src_type IN (N'datetime2',N'datetimeoffset',N'time') AND src_s<=arc_s) ) THEN N'OK'
                ELSE N'BLOCK'
            END
        INTO #drift
        FROM cmp;

        IF EXISTS (SELECT 1 FROM #drift WHERE action=N'BLOCK')
        BEGIN
            DECLARE @blk nvarchar(max);
            SELECT @blk = STRING_AGG(
                colname + N' (src ' + src_type + N'(' + CONVERT(nvarchar(12),src_len) + N'/' + CONVERT(nvarchar(6),src_p) + N',' + CONVERT(nvarchar(6),src_s)
                + N') -> arc ' + arc_type + N'(' + CONVERT(nvarchar(12),arc_len) + N'/' + CONVERT(nvarchar(6),arc_p) + N',' + CONVERT(nvarchar(6),arc_s) + N'))', N'; ')
            FROM #drift WHERE action=N'BLOCK';

            DECLARE @blkMsg nvarchar(2048) =
                N'Schema drift would corrupt the only copy of deleted data on archive ' + @dstObj
              + N' (incompatible source column type change). Reconcile the archive manually before running. Columns: ' + @blk;
            ;THROW 50410, @blkMsg, 1;
        END;

        DECLARE @widen nvarchar(max) = N'';
        SELECT @widen = @widen +
            N'ALTER TABLE ' + @dstObj + N' ALTER COLUMN ' + QUOTENAME(colname) + N' ' + type_sql + N' NULL;' + CHAR(10)
        FROM #drift WHERE action=N'WIDEN';

        IF @widen <> N''
        BEGIN
            EXEC (@widen);
            INSERT arch.ArchiveProvisionLog(SourceDb,ArchiveDb,SourceSchema,SourceTable,Action,Details)
            VALUES (@SourceDb,@ArchiveDb,@SourceSchema,@SourceTable,N'WIDEN_COLUMNS',@widen);
        END;

        DROP TABLE #archMeta;
        DROP TABLE #drift;
    END

    DROP TABLE #cols;
END
