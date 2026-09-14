/* ============================================================================
   065_grant_console_restore_source_insert.sql — OPT-IN: enable "Restore from archive" from the Console.
   ----------------------------------------------------------------------------
   WHY THIS IS OPT-IN (read before running):
   The archiving engine is deliberately least-privilege: NEITHER the console login NOR the runner login
   has INSERT on the production SOURCE databases — the tool only ever reads + deletes (archives OUT) from
   source, it never writes INTO it. "Restore from archive" (un-archive: copy rows from the archive DB back
   INTO the source) is the ONE operation that writes to a production source, so by default it FAILS from
   the console with: "The INSERT permission was denied on the object '<table>', database '<source>'".

   This script grants the Console's source-side principal INSERT on the mapped source tables so the L2
   "Restore from archive" button can complete a real restore. It is a genuine privilege expansion: the
   console login gains INSERT on those production source tables. Only apply it if you want restore to be
   operable from the console; otherwise leave restore as a DBA-only operation (run arch.usp_RestoreFromArchive
   directly under a privileged login). Restore is already gated to the ELEVATED (L2) console tier and audited.

   PARAMETERIZED (fail-fast, like the 051/053 add-ons): set @SourceDb and @ConsolePrincipal, then run.
   Idempotent. Grants INSERT only on the tables that are actual archive targets for enabled mappings.
   ============================================================================ */
USE [master];
GO
SET NOCOUNT ON;

DECLARE @SourceDb        sysname = N'CHANGE_ME_SOURCE_DB';   -- e.g. N'KMWEBV'
DECLARE @ConsolePrincipal sysname = N'CHANGE_ME_CONSOLE_LOGIN'; -- the DB user the Admin Console connects as, e.g. N'kam_console'

IF @SourceDb = N'CHANGE_ME_SOURCE_DB' OR @ConsolePrincipal = N'CHANGE_ME_CONSOLE_LOGIN'
    THROW 50610, 'Set @SourceDb and @ConsolePrincipal first (this grant gives the console INSERT on production source tables — opt-in only).', 1;

IF DB_ID(@SourceDb) IS NULL
    THROW 50611, 'Source database not found on this instance.', 1;

-- Build GRANT INSERT statements for every distinct source table that is an enabled archiving target in @SourceDb.
DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql
    + N'IF USER_ID(' + QUOTENAME(@ConsolePrincipal, '''') + N') IS NULL '
    + N'CREATE USER ' + QUOTENAME(@ConsolePrincipal) + N' FOR LOGIN ' + QUOTENAME(@ConsolePrincipal) + N';' + CHAR(10)
    + N'GRANT INSERT ON ' + QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable)
    + N' TO ' + QUOTENAME(@ConsolePrincipal) + N';' + CHAR(10)
FROM
(
    SELECT DISTINCT e.SourceSchema, e.SourceTable
    FROM arch.v_ObjectSpecDatabaseEffective e
    WHERE e.ObjectIsEnabled = 1
      AND e.SourceDb = @SourceDb
) os;

IF NULLIF(@sql, N'') IS NULL
BEGIN
    PRINT 'No enabled source tables found for ' + @SourceDb + ' — nothing to grant.';
    RETURN;
END;

-- Execute inside the source DB.
DECLARE @exec nvarchar(max) = N'USE ' + QUOTENAME(@SourceDb) + N'; ' + CHAR(10) + @sql;
EXEC (@exec);
PRINT 'Granted INSERT on enabled source tables in [' + @SourceDb + '] to [' + @ConsolePrincipal + '] — "Restore from archive" is now operable from the console (L2).';
PRINT 'To revert: USE [' + @SourceDb + ']; REVOKE INSERT ON <schema>.<table> FROM [' + @ConsolePrincipal + '];';
GO
