/* ============================================================================
   kArchiveManager 2.0 — účet pro Admin Console běžící na JINÉM stroji
   ----------------------------------------------------------------------------
   Dodávané skripty (051, 059, 063–066) počítají s tím, že konzole běží na témže
   stroji jako SQL Server, a přidělují práva identitě aplikačního fondu IIS
   (`IIS APPPOOL\kAM Admin Console`). To tady nejde použít ze dvou důvodů:

     * konzole běží na jiném stroji (RADIM-STACHAL) než SQL Server (WA01),
     * ani jeden z nich není v doméně, takže Windows autentizace mezi nimi
       neprojde.

   Konzole se proto připojuje SQL loginem. Tento skript mu přidělí přesně tu
   sadu práv, kterou dokumentuje ADMIN-CONSOLE.md — včetně tří oprávnění, bez
   nichž konzole nehlásí chybu, ale vrací NESPRÁVNÉ ODPOVĚDI (nuly v grafech,
   prázdné panely, „databáze v pořádku: ne“ bez jediné chybějící položky):

     1. pět rolí karch_* místo pouhého karch_viewer,
     2. čtení z msdb (go-live kontrola čte sysjobs a spol.),
     3. VIEW DATABASE PERFORMANCE STATE (grafy čtou sys.dm_db_partition_stats).

   karch_runtime se ZÁMĚRNĚ nepřiděluje — to je role běhového účtu. Konzole
   nesmí mít právo mazat ze zdrojových tabulek.

   Heslo se předává parametrem @Password; skript ho nikam nevypisuje.
   @Apply = 0 jen vypíše plán.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE [master];
GO

DECLARE @Login     sysname       = N'karch_console';
DECLARE @Password  nvarchar(128) = N'<<SET-A-STRONG-PASSWORD>>';
DECLARE @AdminDb   sysname       = N'kArchiveManagerAdmin';
DECLARE @ArchiveDb sysname       = N'kArchiveManagerBackups';
DECLARE @SourceDb  sysname       = N'KMWE';
DECLARE @Apply     bit           = 0;

IF @Password IS NULL OR @Password = N'<<SET-A-STRONG-PASSWORD>>'
BEGIN
    RAISERROR('Nastavte @Password. Nic se nezmenilo.', 16, 1);
    RETURN;
END;

DECLARE @sql nvarchar(max), @plan nvarchar(max) = N'';

/* ---------- 1) login ------------------------------------------------------ */
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @Login)
    SET @plan += N'CREATE LOGIN ' + QUOTENAME(@Login) + N' WITH PASSWORD = <skryto>, CHECK_POLICY = ON;' + CHAR(10);
ELSE
    SET @plan += N'-- login ' + QUOTENAME(@Login) + N' uz existuje; heslo se prenastavi' + CHAR(10);

/* ---------- 2) admin DB: uživatel + pět rolí + DMV právo ------------------- */
SET @plan += N'USE ' + QUOTENAME(@AdminDb) + N': uzivatel, role karch_viewer/operator/config_admin/advanced_admin/approver'
           + N' (BEZ karch_runtime), GRANT VIEW DATABASE PERFORMANCE STATE' + CHAR(10);

/* ---------- 3) archivní DB: jen čtení ------------------------------------- */
SET @plan += N'USE ' + QUOTENAME(@ArchiveDb) + N': uzivatel, db_datareader, GRANT VIEW DATABASE PERFORMANCE STATE' + CHAR(10);

/* ---------- 4) zdrojová DB: jen čtení (odhady a validace) ------------------ */
SET @plan += N'USE ' + QUOTENAME(@SourceDb) + N': uzivatel, db_datareader, GRANT VIEW DATABASE PERFORMANCE STATE'
           + N'  -- POUZE CTENI, zadny DELETE' + CHAR(10);

/* ---------- 5) msdb: čtení pro go-live kontrolu ---------------------------- */
SET @plan += N'USE msdb: uzivatel, SELECT na sysjobs, sysjobsteps, sysjobschedules, sysschedules,'
           + N' sysjobservers, sysjobactivity, sysjobhistory, sysoperators' + CHAR(10);

PRINT '--- plan ---';
PRINT @plan;

IF @Apply = 0
BEGIN
    PRINT '@Apply = 0 — nic se neprovedlo.';
    RETURN;
END;

/* ========================= provedení =======================================
   Dynamické SQL se skládá do proměnné a teprve pak spouští. Zanořené
   EXEC('...' + QUOTENAME(...)) uvnitř sp_executesql se nerozplete korektně,
   proto se mu tu záměrně vyhýbáme.
   ========================================================================== */
DECLARE @l nvarchar(300) = QUOTENAME(@Login);
DECLARE @p nvarchar(300) = N'N''' + REPLACE(@Password, N'''', N'''''') + N'''';

BEGIN TRY
    /* login */
    IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @Login)
        SET @sql = N'CREATE LOGIN ' + @l + N' WITH PASSWORD = ' + @p + N', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;';
    ELSE
        SET @sql = N'ALTER LOGIN ' + @l + N' WITH PASSWORD = ' + @p + N', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;'
                 + N'ALTER LOGIN ' + @l + N' ENABLE;';
    EXEC sys.sp_executesql @sql;
    PRINT 'login: hotovo';

    /* admin DB: uživatel + pět rolí + DMV právo (karch_runtime se nepřiděluje) */
    SET @sql = N'USE ' + QUOTENAME(@AdminDb) + N';'
      + N'IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''' + @Login + N''')'
      + N'  CREATE USER ' + @l + N' FOR LOGIN ' + @l + N';'
      + N'ALTER ROLE karch_viewer         ADD MEMBER ' + @l + N';'
      + N'ALTER ROLE karch_operator       ADD MEMBER ' + @l + N';'
      + N'ALTER ROLE karch_config_admin   ADD MEMBER ' + @l + N';'
      + N'ALTER ROLE karch_advanced_admin ADD MEMBER ' + @l + N';'
      + N'ALTER ROLE karch_approver       ADD MEMBER ' + @l + N';'
      + N'GRANT VIEW DATABASE PERFORMANCE STATE TO ' + @l + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'admin DB: uzivatel + 5 roli + VIEW DATABASE PERFORMANCE STATE';

    /* archivní a zdrojová DB: pouze čtení */
    DECLARE @db sysname;
    DECLARE cd CURSOR LOCAL FAST_FORWARD FOR SELECT @ArchiveDb UNION ALL SELECT @SourceDb;
    OPEN cd; FETCH NEXT FROM cd INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'USE ' + QUOTENAME(@db) + N';'
          + N'IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''' + @Login + N''')'
          + N'  CREATE USER ' + @l + N' FOR LOGIN ' + @l + N';'
          + N'ALTER ROLE db_datareader ADD MEMBER ' + @l + N';'
          + N'GRANT VIEW DATABASE PERFORMANCE STATE TO ' + @l + N';';
        EXEC sys.sp_executesql @sql;
        PRINT 'cteni v DB: ' + @db;
        FETCH NEXT FROM cd INTO @db;
    END
    CLOSE cd; DEALLOCATE cd;

    /* msdb: čtení pro go-live kontrolu (059, část 1b) */
    SET @sql = N'USE msdb;'
      + N'IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''' + @Login + N''')'
      + N'  CREATE USER ' + @l + N' FOR LOGIN ' + @l + N';'
      + N'GRANT SELECT ON dbo.sysjobs TO '          + @l + N';'
      + N'GRANT SELECT ON dbo.sysjobsteps TO '      + @l + N';'
      + N'GRANT SELECT ON dbo.sysjobschedules TO '  + @l + N';'
      + N'GRANT SELECT ON dbo.sysschedules TO '     + @l + N';'
      + N'GRANT SELECT ON dbo.sysjobservers TO '    + @l + N';'
      + N'GRANT SELECT ON dbo.sysjobactivity TO '   + @l + N';'
      + N'GRANT SELECT ON dbo.sysjobhistory TO '    + @l + N';'
      + N'GRANT SELECT ON dbo.sysoperators TO '     + @l + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'msdb: cteni pro go-live kontrolu';

    PRINT 'Hotovo.';
END TRY
BEGIN CATCH
    PRINT 'CHYBA: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO
