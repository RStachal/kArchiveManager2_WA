USE [kArchiveManagerAdmin]
GO
/****** Object:  StoredProcedure [arch].[usp_GetOutputColumns]    Script Date: 27.04.2026 15:00:55 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE OR ALTER PROCEDURE [arch].[usp_GetOutputColumns]
    @SourceDb     sysname,
    @SourceSchema sysname,
    @SourceTable  sysname,
    @IncludeComputed bit = 0,
    @ExcludeRowversion bit = 0,   -- restore path sets this: a rowversion/timestamp column cannot be INSERTed explicitly
    @DeletedSelectList nvarchar(max) OUTPUT,
    @TargetColumnList  nvarchar(max) OUTPUT,
    @SourceAlias       sysname = N't',          -- T-? copy-only: alias used by @SourceSelectList
    @SourceSelectList  nvarchar(max) = NULL OUTPUT   -- e.g. 't.[col1],t.[col2]' for INSERT ... SELECT (copy, no OUTPUT)
AS
BEGIN
    SET NOCOUNT ON;

    SET @DeletedSelectList = N'';
    SET @TargetColumnList  = N'';
    SET @SourceSelectList  = N'';

    DECLARE @aliasPrefix nvarchar(140) = QUOTENAME(@SourceAlias) + N'.';

    DECLARE @sql nvarchar(max) = N'
;WITH c AS
(
    SELECT c.column_id, c.name, c.is_computed
    FROM ' + QUOTENAME(@SourceDb) + N'.sys.columns c
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.objects o ON o.object_id = c.object_id
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.schemas s ON s.schema_id = o.schema_id
    JOIN ' + QUOTENAME(@SourceDb) + N'.sys.types t ON t.user_type_id = c.user_type_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @sch COLLATE DATABASE_DEFAULT
      AND o.name COLLATE DATABASE_DEFAULT = @tbl COLLATE DATABASE_DEFAULT
      AND o.type = ''U''
      AND (@IncludeComputed = 1 OR c.is_computed = 0)
      AND (@ExcludeRowversion = 0 OR t.name <> N''timestamp'')   -- rowversion''s system type name is ''timestamp''
)
SELECT
    @Deleted =
        STUFF((
            SELECT N'','' + N''DELETED.'' + QUOTENAME(name)
            FROM c
            ORDER BY column_id
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 1, N''''),
    @Target =
        STUFF((
            SELECT N'','' + QUOTENAME(name)
            FROM c
            ORDER BY column_id
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 1, N''''),
    @Source =
        STUFF((
            SELECT N'','' + @prefix + QUOTENAME(name)
            FROM c
            ORDER BY column_id
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''nvarchar(max)''), 1, 1, N'''');
';

    EXEC sys.sp_executesql
        @sql,
        N'@sch sysname, @tbl sysname, @IncludeComputed bit, @ExcludeRowversion bit, @prefix nvarchar(140), @Deleted nvarchar(max) OUTPUT, @Target nvarchar(max) OUTPUT, @Source nvarchar(max) OUTPUT',
        @sch=@SourceSchema, @tbl=@SourceTable, @IncludeComputed=@IncludeComputed, @ExcludeRowversion=@ExcludeRowversion, @prefix=@aliasPrefix,
        @Deleted=@DeletedSelectList OUTPUT, @Target=@TargetColumnList OUTPUT, @Source=@SourceSelectList OUTPUT;

    IF NULLIF(@DeletedSelectList, N'') IS NULL
       OR NULLIF(@TargetColumnList, N'') IS NULL
    BEGIN
        RAISERROR(N'No output columns found for source table: %s.%s.%s', 16, 1, @SourceDb, @SourceSchema, @SourceTable);
        RETURN;
    END
END
