-- ============================================================================
-- 01 - INSTANCE PRE-CHECK (read-only)
-- ============================================================================
-- Verifies that the target instance can host kArchiveManager 2.0 at all.
-- Changes nothing. Every row carries a verdict: OK / WARN / STOP.
-- ============================================================================
:setvar SourceDb  "AAD"
:setvar AdminDb   "kArchiveManagerAdmin"
:setvar ArchiveDb "kArchiveManagerBackups"

:on error exit

USE [master];
GO
SET NOCOUNT ON;
GO

PRINT '=== kArchiveManager 2.0 instance pre-check ===';
GO

DECLARE @res table
(
    Ord     int IDENTITY(1,1) PRIMARY KEY,
    Item    nvarchar(60)  NOT NULL,
    Value_  nvarchar(300) NULL,
    Verdict nvarchar(200) NOT NULL
);

-- Engine version. The platform relies on AT TIME ZONE (2016+), STRING_SPLIT and
-- datetime2 semantics, so 2016 is the hard floor and 2019+ is what it is tested on.
INSERT @res(Item, Value_, Verdict)
SELECT N'SQL Server version',
       CONVERT(nvarchar(200), SERVERPROPERTY('ProductVersion')) + N' / ' + CONVERT(nvarchar(100), SERVERPROPERTY('Edition')),
       CASE WHEN CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) >= 15 THEN N'OK'
            WHEN CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) >= 13 THEN N'WARN - 2016/2017: supported floor, but the product is tested on 2019+'
            ELSE N'STOP - AT TIME ZONE / STRING_SPLIT require SQL Server 2016 or newer' END;

-- Permissions. The deploy creates databases, schemas, roles and Agent jobs.
INSERT @res(Item, Value_, Verdict)
SELECT N'Current login is sysadmin',
       SUSER_SNAME(),
       CASE WHEN IS_SRVROLEMEMBER('sysadmin') = 1 THEN N'OK'
            ELSE N'STOP - the clean deploy creates databases, roles and Agent jobs; it needs sysadmin' END;

-- SQL Agent. Phase 14 of the bundle installs jobs; with the SQLCMD master and
-- ":on error exit" a missing Agent ABORTS the deploy and you silently lose the
-- later phases (including the ActionKey validator from script 063).
INSERT @res(Item, Value_, Verdict)
SELECT N'SQL Server Agent running',
       ISNULL((SELECT TOP (1) CONVERT(nvarchar(50), status_desc) FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%'), N'(unknown)'),
       CASE WHEN EXISTS (SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%' AND status_desc = N'Running')
            THEN N'OK'
            ELSE N'STOP - start SQL Agent first, or the deploy aborts in Phase 14 and skips Phases 14b/14c' END;

-- Source database presence and compatibility level.
INSERT @res(Item, Value_, Verdict)
SELECT N'Source database $(SourceDb)',
       ISNULL((SELECT CONVERT(nvarchar(100), d.state_desc) + N', compat ' + CONVERT(nvarchar(10), d.compatibility_level)
               FROM sys.databases d WHERE d.name = N'$(SourceDb)'), N'(missing)'),
       CASE
           WHEN NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$(SourceDb)') THEN N'STOP - source database does not exist'
           WHEN (SELECT state_desc FROM sys.databases WHERE name = N'$(SourceDb)') <> N'ONLINE' THEN N'STOP - source database is not ONLINE'
           WHEN (SELECT compatibility_level FROM sys.databases WHERE name = N'$(SourceDb)') < 130
                THEN N'STOP - compat level < 130: the cross-database dynamic SQL uses AT TIME ZONE and will fail'
           ELSE N'OK' END;

-- Collation. The runner copes with a source/admin collation mismatch (it re-collates
-- the #Keys temp table to the source collation), but a case-sensitive database makes
-- every identifier and literal comparison case-exact, which is worth knowing up front.
INSERT @res(Item, Value_, Verdict)
SELECT N'Collation (server / source)',
       CONVERT(nvarchar(100), SERVERPROPERTY('Collation')) + N' / ' +
       ISNULL((SELECT CONVERT(nvarchar(100), collation_name) FROM sys.databases WHERE name = N'$(SourceDb)'), N'(n/a)'),
       CASE
           WHEN (SELECT collation_name FROM sys.databases WHERE name = N'$(SourceDb)') LIKE N'%[_]CS[_]%'
                THEN N'WARN - case-sensitive source: order numbers, process codes and SourceDb names are all case-exact. Verified working on Czech_CS_AS.'
           ELSE N'OK' END;

-- Archive-side databases: report whether this is a fresh install or a re-run.
INSERT @res(Item, Value_, Verdict)
SELECT N'Admin database $(AdminDb)',
       ISNULL((SELECT CONVERT(nvarchar(100), state_desc) FROM sys.databases WHERE name = N'$(AdminDb)'), N'(missing)'),
       CASE
           WHEN NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$(AdminDb)')
                THEN N'OK - will be created by 02_databases.sql'
           WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$(AdminDb)')
                AND OBJECT_ID(N'$(AdminDb)' + N'.arch.Process', N'U') IS NOT NULL
                THEN N'WARN - already deployed. The clean bundle uses plain CREATE TABLE and will FAIL on a populated database; use the per-object update scripts instead.'
           ELSE N'OK - exists but empty' END;

INSERT @res(Item, Value_, Verdict)
SELECT N'Archive database $(ArchiveDb)',
       ISNULL((SELECT CONVERT(nvarchar(100), state_desc) + N', ' + CONVERT(nvarchar(20), recovery_model_desc)
               FROM sys.databases WHERE name = N'$(ArchiveDb)'), N'(missing)'),
       CASE
           WHEN NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$(ArchiveDb)')
                THEN N'OK - will be created by 02_databases.sql'
           WHEN (SELECT recovery_model_desc FROM sys.databases WHERE name = N'$(ArchiveDb)') <> N'FULL'
                THEN N'WARN - archive DB should be FULL recovery: it is the only copy of irreversibly deleted rows and the hourly LOG backup job no-ops under SIMPLE'
           ELSE N'OK' END;

-- Free space. The archive receives a copy of every deleted row, and the source is
-- in FULL recovery, so the delete volume also drives log growth.
INSERT @res(Item, Value_, Verdict)
SELECT N'Data volume free space',
       CONVERT(nvarchar(50), CONVERT(decimal(18,1), MIN(vs.available_bytes) / 1073741824.0)) + N' GB on ' + MIN(vs.volume_mount_point),
       CASE WHEN MIN(vs.available_bytes) / 1073741824.0 < 10 THEN N'WARN - under 10 GB free; size the archive DB deliberately before a large first drain'
            ELSE N'OK' END
FROM sys.master_files mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
WHERE mf.database_id = DB_ID(N'master');

-- Timezone name must resolve, or every cutoff expression breaks at run time.
INSERT @res(Item, Value_, Verdict)
SELECT N'Timezone data available',
       CONVERT(nvarchar(50), (SELECT COUNT(*) FROM sys.time_zone_info)) + N' zones',
       CASE WHEN EXISTS (SELECT 1 FROM sys.time_zone_info WHERE name = N'Central European Standard Time')
            THEN N'OK'
            ELSE N'STOP - the configured source timezone is not in sys.time_zone_info' END;

SELECT Item, Value_, Verdict FROM @res ORDER BY Ord;

SELECT
    Section = 'PRECHECK_SUMMARY',
    Stops   = (SELECT COUNT(*) FROM @res WHERE Verdict LIKE N'STOP%'),
    Warns   = (SELECT COUNT(*) FROM @res WHERE Verdict LIKE N'WARN%'),
    Verdict = CASE WHEN EXISTS (SELECT 1 FROM @res WHERE Verdict LIKE N'STOP%')
                   THEN N'STOP - resolve the blocking items before deploying'
                   ELSE N'OK - instance is ready for 02_databases.sql' END;
GO
