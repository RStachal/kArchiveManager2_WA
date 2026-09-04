-- ============================================================================
-- 06 - PROVISION THE ARCHIVE TABLES
-- ============================================================================
-- Creates one archive table per configured ObjectSpec inside the archive
-- database. Without them a Mode=1 (archive+delete) run cannot archive, and
-- because every ObjectSpec has RequireArchiveForDelete = 1 it cannot delete
-- either - usp_ValidateConfiguration reports each one as a WARN until this runs.
--
-- ArchiveSchema is '{SourceDb}' in both configurations, so the tables land in
-- <ArchiveDb>.<SourceDb>.<same table name> - one schema per source database
-- rather than everything in dbo. The placeholder is substituted at run time
-- (015 line 231-237) and is CASE-SENSITIVE, so it must be written exactly
-- '{SourceDb}'.
--
-- @MakeAllNullable = 1 is deliberate: an archive is a historical copy, not a
-- constraint-enforcing replica, and NOT NULL columns would reject rows that were
-- legal in the source at the time.
--
-- Column collation is copied per column FROM THE SOURCE
-- (usp_EnsureArchiveTableLikeSource emits an explicit "COLLATE <source
-- collation>"), so the archive matches the source even if the archive database
-- itself has a different collation. Nothing to configure.
--
-- Re-runnable: existing tables are left alone; only missing tables/columns are
-- added. A type/length DRIFT between source and archive is refused with
-- THROW 50410 so an operator can reconcile it instead of silently losing data.
-- ============================================================================
:setvar AdminDb   "kArchiveManagerAdmin"
:setvar SourceDb  "AAD"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar OrderProcessCode "AAD_ORDER_ARCH"
:setvar WorkQProcessCode "AAD_WORKQ_ARCH"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

PRINT '--- Provisioning archive tables for $(OrderProcessCode) ---';
EXEC arch.usp_ProvisionArchiveTablesForProcess
    @ProcessCode      = N'$(OrderProcessCode)',
    @SourceDb         = N'$(SourceDb)',
    @ArchiveDb        = N'$(ArchiveDb)',
    @MakeAllNullable  = 1,
    @IncludeComputed  = 0;
GO

PRINT '--- Provisioning archive tables for $(WorkQProcessCode) ---';
EXEC arch.usp_ProvisionArchiveTablesForProcess
    @ProcessCode      = N'$(WorkQProcessCode)',
    @SourceDb         = N'$(SourceDb)',
    @ArchiveDb        = N'$(ArchiveDb)',
    @MakeAllNullable  = 1,
    @IncludeComputed  = 0;
GO

-- What now exists on the archive side, and does the row shape match the source?
DECLARE @sql nvarchar(max) = N'
SELECT
    ArchiveSchema = s.name,
    ArchiveTable  = t.name,
    ArchiveCols   = (SELECT COUNT(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.sys.columns c WHERE c.object_id = t.object_id),
    SourceCols    = (
        SELECT COUNT(*)
        FROM ' + QUOTENAME(N'$(SourceDb)') + N'.sys.columns sc
        JOIN ' + QUOTENAME(N'$(SourceDb)') + N'.sys.objects so ON so.object_id = sc.object_id
        JOIN ' + QUOTENAME(N'$(SourceDb)') + N'.sys.schemas ss ON ss.schema_id = so.schema_id
        WHERE ss.name COLLATE DATABASE_DEFAULT = N''dbo''
          AND so.name COLLATE DATABASE_DEFAULT = t.name COLLATE DATABASE_DEFAULT
    ),
    Rows_ = ISNULL((SELECT SUM(p.rows) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0,1)), 0)
FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.sys.tables t
JOIN ' + QUOTENAME(N'$(ArchiveDb)') + N'.sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name COLLATE DATABASE_DEFAULT = N''$(SourceDb)'' COLLATE DATABASE_DEFAULT
ORDER BY t.name;';
EXEC sys.sp_executesql @sql;
GO

PRINT '06_provision: done. Re-run 07_validate.sql - the "archive table does not exist" WARNs should be gone.';
GO
