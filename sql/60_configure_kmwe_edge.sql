/* ============================================================================
   kArchiveManager 2.0 — konfigurace pro procesy WMS Edge nad databází KMWE
   ----------------------------------------------------------------------------
   Vychází z odzkoušené konfigurace Edge v seed_tested_processes.sql a upravuje
   ji podle návrhu odsouhlaseného se zákazníkem 18. 6. 2026:

     * retence 15 měsíců (450 dní), rolující — CutoffMode = 0
     * tři plány: RECEIVING (příjmy), SHIPPING (výdeje), RF_LOG2 (systémový log)
     * oproti dodávanému seedu navíc BACKRD2 a SHIPMSTR2 (návrh je vyžaduje)
     * archivní schéma = název zdrojové databáze, takže CZ (KMWE) a SK (KWMESK)
       skončí v oddělených schématech téže archivní databáze

   ODLIŠNOSTI OD DODÁVANÉHO SEEDU A JEJICH DŮVOD
   ----------------------------------------------------------------------------
   1. RF_LOG2 se v dodávaném seedu řídí sloupcem TIMESTMP. Ten v KMWE NEEXISTUJE.
      Čas nese DATE_TIME nvarchar(46) ve tvaru 'yyyyMMdd HH:mm:ss.ff'. Výraz ho
      proto skládá na ISO 8601 a parsuje přes TRY_CONVERT se stylem 126.
   2. Dvacet řádků RF_LOG2 má DATE_TIME prázdný řetězec (ne NULL). Brána je
      vylučuje: co nejde datovat, se nearchivuje ani nemaže.
   3. Dodávaný seed používá v TimestampExpr tvrdý CAST. Validace na to hlásí
      WARN (riziko formátu a jazyka). U sloupců typu datetime jde o pouhé
      rozšíření typu, které selhat nemůže, takže CAST zůstává; u řetězcového
      DATE_TIME je nasazen TRY_CONVERT, jak validace vyžaduje.

   POŽADAVEK NA PROSTŘEDÍ
   ----------------------------------------------------------------------------
   KMWE musí být na compatibility level >= 130. Na úrovni 100 není TRY_CONVERT
   k dispozici a konfigurace logu by selhala s chybou 195.

   Skript je idempotentní: pokud plány existují, bez @Reseed = 1 se neprovede.
   Spustitelný v SSMS i přes sqlcmd, nepoužívá :setvar.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE [kArchiveManagerAdmin];
GO

DECLARE @SourceDb   sysname = N'KMWE';
DECLARE @ArchiveDb  sysname = N'kArchiveManagerBackups';
DECLARE @Retention  int     = 450;        -- 15 měsíců
DECLARE @SafetyLag  int     = 1440;       -- 24 h pod cutoffem se nesahá
DECLARE @Tz         nvarchar(100) = N'Central European Standard Time';
DECLARE @Reseed     bit     = 0;          -- 1 = nejdřív smazat stávající tři plány

DECLARE @codes TABLE (ProcessCode sysname PRIMARY KEY);
INSERT @codes VALUES (N'RECEIVING'), (N'SHIPPING'), (N'RF_LOG2');

/* ---------- 0) kontrola prostředí ---------------------------------------- */
IF DB_ID(@SourceDb) IS NULL
    THROW 60001, 'Zdrojová databáze neexistuje.', 1;

DECLARE @compat tinyint = (SELECT compatibility_level FROM sys.databases WHERE name = @SourceDb);
IF @compat < 130
BEGIN
    DECLARE @m nvarchar(200) = CONCAT(N'KMWE je na compatibility level ', @compat,
        N'; TRY_CONVERT vyžaduje 130 a výš. Zvyšte compat level, nebo použijte TRY_CAST.');
    THROW 60002, @m, 1;
END;

IF DB_ID(@ArchiveDb) IS NULL
    THROW 60003, 'Archivní databáze neexistuje — spusťte nejdřív 02_databases.sql.', 1;

/* ---------- 1) idempotence ------------------------------------------------ */
IF EXISTS (SELECT 1 FROM arch.Process p JOIN @codes c ON c.ProcessCode = p.ProcessCode)
BEGIN
    IF @Reseed = 0
    BEGIN
        PRINT 'Plány už existují a @Reseed = 0 — skript neprovedl nic.';
        SELECT CONVERT(varchar(20), p.ProcessCode) AS ProcessCode, p.RetentionDays, p.SelectionStrategy,
               (SELECT COUNT(*) FROM arch.ObjectSpec o WHERE o.ProcessId = p.ProcessId) AS Tabulek
        FROM arch.Process p JOIN @codes c ON c.ProcessCode = p.ProcessCode
        ORDER BY p.ProcessCode;
        RETURN;
    END;

    PRINT 'Reseed: mažu stávající tři plány.';
    DELETE ks FROM arch.ProcessKeySpec ks
        JOIN arch.Process p ON p.ProcessId = ks.ProcessId JOIN @codes c ON c.ProcessCode = p.ProcessCode;
    DELETE ir FROM arch.IndexRequirement ir
        WHERE ir.ObjectSpecId IN (SELECT o.ObjectSpecId FROM arch.ObjectSpec o
            JOIN arch.Process p ON p.ProcessId = o.ProcessId JOIN @codes c ON c.ProcessCode = p.ProcessCode);
    DELETE o FROM arch.ObjectSpec o
        JOIN arch.Process p ON p.ProcessId = o.ProcessId JOIN @codes c ON c.ProcessCode = p.ProcessCode;
    DELETE pd FROM arch.ProcessDatabase pd
        JOIN arch.Process p ON p.ProcessId = pd.ProcessId JOIN @codes c ON c.ProcessCode = p.ProcessCode;
    DELETE p FROM arch.Process p JOIN @codes c ON c.ProcessCode = p.ProcessCode;
END;

BEGIN TRAN;

/* ---------- 2) plány ------------------------------------------------------ */
-- Společné: Mode = 1 (archivovat a smazat), RequireArchiveForDelete na objektech,
-- AllowDeleteWithoutArchive = 0, aplikační zámek proti souběhu.
-- AuditLevel: u dokladů ROW (stopa na jednotlivý doklad), u logu NONE —
-- dokumentem je tam jediný řádek, takže by stopa narostla stejně jako archiv.

INSERT arch.Process
    (ProcessCode, [Description], IsEnabled, Mode, RetentionDays, CutoffSafetyLagMinutes,
     BatchDocCount, BatchRowCount, MaxBatchesPerRun, DelayMsBetweenBatches,
     UseAppLock, LockTimeoutMs, DeadlockPriority,
     AnchorSchema, AnchorTable, AnchorDocKeyExpr, AnchorTimestampExpr,
     AllowDeleteWithoutArchive, CutoffMode, DocKeyLabel, SelectionStrategy, AuditLevel,
     RequireSupportingIndex, MaxRowsPerTransaction, CreatedAt, ModifiedAt)
VALUES
    (N'RECEIVING', N'kArchiveManager - historie prijmu (WMS Edge)', 1, 1, @Retention, @SafetyLag,
     500, NULL, 100, 0,
     1, 10000, N'LOW',
     N'dbo', N'BACKRH', N'a.PO_NUM',
     N'CAST(a.DATE_CREAT AS datetime2) AT TIME ZONE N''' + @Tz + N''' AT TIME ZONE N''UTC''',
     0, 0, N'PO_NUM', N'ANCHOR', N'ROW',
     1, 4000, SYSUTCDATETIME(), SYSUTCDATETIME()),

    (N'SHIPPING', N'kArchiveManager - historie vydeju (WMS Edge)', 1, 1, @Retention, @SafetyLag,
     1000, NULL, 500, 0,
     1, 10000, N'LOW',
     N'dbo', N'SHIPHIST', N'a.PACKSLIP',
     N'CAST(COALESCE(a.DATE_UPLD, a.DATE_SHIP, a.DATE_CREAT) AS datetime2) AT TIME ZONE N''' + @Tz + N''' AT TIME ZONE N''UTC''',
     0, 0, N'PACKSLIP', N'ANCHOR', N'ROW',
     1, 4000, SYSUTCDATETIME(), SYSUTCDATETIME()),

    -- Log nemá hlavičku: dokumentem je samotný řádek, proto TIMESTAMP a klíč ROWID.
    -- BatchRowCount i MaxRowsPerTransaction 4000 — nad tím SQL Server eskaluje
    -- zámek na celou tabulku.
    (N'RF_LOG2', N'kArchiveManager - historie systemoveho logu (WMS Edge)', 1, 1, @Retention, @SafetyLag,
     NULL, 4000, 20, 0,
     1, 10000, N'LOW',
     NULL, NULL, NULL, NULL,
     0, 0, N'ROWID', N'TIMESTAMP', N'NONE',
     1, 4000, SYSUTCDATETIME(), SYSUTCDATETIME());

/* ---------- 3) klíče dokumentu -------------------------------------------- */
INSERT arch.ProcessKeySpec (ProcessId, KeyOrdinal, KeyName, SourceExpressionSql, SqlType, IsRequired, CreatedAt, ModifiedAt)
SELECT p.ProcessId, 1, N'PO_NUM',   N'a.PO_NUM',   N'nvarchar(50)', 1, SYSUTCDATETIME(), SYSUTCDATETIME()
    FROM arch.Process p WHERE p.ProcessCode = N'RECEIVING'
UNION ALL
SELECT p.ProcessId, 1, N'PACKSLIP', N'a.PACKSLIP', N'nvarchar(40)', 1, SYSUTCDATETIME(), SYSUTCDATETIME()
    FROM arch.Process p WHERE p.ProcessCode = N'SHIPPING'
UNION ALL
SELECT p.ProcessId, 1, N'ROWID',    N't.ROWID',    N'uniqueidentifier', 1, SYSUTCDATETIME(), SYSUTCDATETIME()
    FROM arch.Process p WHERE p.ProcessCode = N'RF_LOG2';

/* ---------- 4) tabulky ----------------------------------------------------- */
-- DeleteOrder: potomci napřed, kotva jako poslední. Cizí klíče v KMWE nejsou,
-- takže pořadí drží jen tato konfigurace — proto je u kotvy nejvyšší číslo.
-- ArchiveSchema {SourceDb} se při provisioningu rozvine na název zdrojové DB.

DECLARE @tz2 nvarchar(300) = N' AT TIME ZONE N''' + @Tz + N''' AT TIME ZONE N''UTC''';

-- výraz pro řetězcový čas logu: 'yyyyMMdd HH:mm:ss.ff' -> ISO 8601 -> datetime2
DECLARE @logTs nvarchar(600) =
    N'TRY_CONVERT(datetime2(2), STUFF(STUFF(STUFF(NULLIF(LTRIM(RTRIM(t.DATE_TIME)), N''''), 9, 1, N''T''), 7, 0, N''-''), 5, 0, N''-''), 126)';

INSERT arch.ObjectSpec
    (ProcessId, SourceSchema, SourceTable, DeleteOrder, DeleteMode, TimestampExpr,
     JoinToAnchorPredicateSql, AdditionalWhereSql, ArchiveSchema, ArchiveTable,
     RequireArchiveForDelete, NaturalKeyLabel)
-- ---- RECEIVING: BACKRD, BACKRD2 (potomci) -> BACKRH (kotva) ----
SELECT p.ProcessId, N'dbo', N'BACKRD',  10, 1, N'CAST(t.DATE_CREAT AS datetime2)'  + @tz2, N't.PO_NUM = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PO_NUM'
    FROM arch.Process p WHERE p.ProcessCode = N'RECEIVING'
UNION ALL
SELECT p.ProcessId, N'dbo', N'BACKRD2', 15, 1, N'CAST(t.DATECREATE AS datetime2)' + @tz2, N't.PO_NUM = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PO_NUM'
    FROM arch.Process p WHERE p.ProcessCode = N'RECEIVING'
UNION ALL
SELECT p.ProcessId, N'dbo', N'BACKRH',  20, 1, N'CAST(t.DATE_CREAT AS datetime2)'  + @tz2, N't.PO_NUM = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PO_NUM'
    FROM arch.Process p WHERE p.ProcessCode = N'RECEIVING'
-- ---- SHIPPING: detaily, nosiče a řádky -> SHIPHIST (kotva) ----
UNION ALL
SELECT p.ProcessId, N'dbo', N'SHIPDETL',  10, 1, N'CAST(t.DATECREATE AS datetime2)' + @tz2, N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'
    FROM arch.Process p WHERE p.ProcessCode = N'SHIPPING'
UNION ALL
SELECT p.ProcessId, N'dbo', N'SHIPDETL2', 20, 1, N'CAST(t.DATECREATE AS datetime2)' + @tz2, N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'
    FROM arch.Process p WHERE p.ProcessCode = N'SHIPPING'
UNION ALL
SELECT p.ProcessId, N'dbo', N'SHIPMSTR',  30, 1, N'CAST(COALESCE(t.DATE_SHIP, t.DATECREATE) AS datetime2)' + @tz2, N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'
    FROM arch.Process p WHERE p.ProcessCode = N'SHIPPING'
UNION ALL
SELECT p.ProcessId, N'dbo', N'SHIPMSTR2', 35, 1, N'CAST(t.DATECREATE AS datetime2)' + @tz2, N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'
    FROM arch.Process p WHERE p.ProcessCode = N'SHIPPING'
UNION ALL
SELECT p.ProcessId, N'dbo', N'SHIPLINE',  40, 1, N'CAST(t.BILLEDDATE AS datetime2)' + @tz2, N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'
    FROM arch.Process p WHERE p.ProcessCode = N'SHIPPING'
UNION ALL
SELECT p.ProcessId, N'dbo', N'SHIPLINE2', 50, 1, N'CAST(t.BILLEDDATE AS datetime2)' + @tz2, N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'
    FROM arch.Process p WHERE p.ProcessCode = N'SHIPPING'
UNION ALL
SELECT p.ProcessId, N'dbo', N'SHIPHIST',  60, 1, N'CAST(COALESCE(t.DATE_UPLD, t.DATE_SHIP, t.DATE_CREAT) AS datetime2)' + @tz2, N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'
    FROM arch.Process p WHERE p.ProcessCode = N'SHIPPING'
-- ---- RF_LOG2: jediná tabulka, dokumentem je řádek ----
-- AdditionalWhereSql vylučuje řádky s prázdným DATE_TIME: co nejde datovat,
-- se nearchivuje ani nemaže.
UNION ALL
SELECT p.ProcessId, N'dbo', N'RF_LOG2', 10, 1, @logTs + @tz2, N't.ROWID = k.Key1', @logTs + N' IS NOT NULL', N'{SourceDb}', NULL, 1, N'ROWID'
    FROM arch.Process p WHERE p.ProcessCode = N'RF_LOG2';

/* ---------- 5) mapování na databázi ---------------------------------------- */
-- Přepisy zůstávají NULL: platí nastavení z arch.Process. Až přibude KWMESK,
-- přidá se jen další řádek sem.
INSERT arch.ProcessDatabase (ProcessId, SourceDb, ArchiveDb, IsEnabled, RunOrder)
SELECT p.ProcessId, @SourceDb, @ArchiveDb, 1,
       CASE p.ProcessCode WHEN N'RECEIVING' THEN 1010 WHEN N'SHIPPING' THEN 1020 ELSE 1030 END
FROM arch.Process p JOIN @codes c ON c.ProcessCode = p.ProcessCode;

COMMIT;

/* ---------- 6) výsledek ---------------------------------------------------- */
PRINT '--- nakonfigurovane plany ---';
SELECT CONVERT(varchar(12), p.ProcessCode) AS Plan_,
       CONVERT(varchar(10), p.SelectionStrategy) AS Strategie,
       CONVERT(varchar(12), ISNULL(p.AnchorTable, N'(radek)')) AS Kotva,
       CONVERT(varchar(10), p.DocKeyLabel) AS Klic,
       p.RetentionDays AS Retence,
       CONVERT(varchar(6), p.AuditLevel) AS Audit,
       (SELECT COUNT(*) FROM arch.ObjectSpec o WHERE o.ProcessId = p.ProcessId) AS Tabulek
FROM arch.Process p JOIN @codes c ON c.ProcessCode = p.ProcessCode
ORDER BY p.ProcessCode;

PRINT '--- tabulky v poradi mazani (kotva posledni) ---';
SELECT CONVERT(varchar(12), p.ProcessCode) AS Plan_, o.DeleteOrder AS Poradi,
       CONVERT(varchar(14), o.SourceTable) AS Tabulka,
       o.RequireArchiveForDelete AS VyzadujeArchiv
FROM arch.ObjectSpec o JOIN arch.Process p ON p.ProcessId = o.ProcessId
JOIN @codes c ON c.ProcessCode = p.ProcessCode
ORDER BY p.ProcessCode, o.DeleteOrder;
GO

/* ============================================================================
   7) Požadavky na indexy — samostatná dávka s vlastní pojistkou
   ----------------------------------------------------------------------------
   Popisují, které indexy archivaci pomohou. Nástroj je JEN VYPÍŠE i s hotovým
   DDL; do WMS databáze nikdy nic nezakládá — to je rozhodnutí DBA zákazníka.

   SELECTION = scan kandidátů nad řídící tabulkou (čas + klíč dokumentu)
   JOIN      = dohledání potomků podle klíče

   U RF_LOG2 je klíčem scanu DATE_TIME, tedy řetězec. Formát 'yyyyMMdd HH:mm:ss.ff'
   řadí lexikálně shodně s chronologií, takže index nad ním rozsahový dotaz
   obslouží — ale jen pokud se predikát porovnává na surový řetězec. Cheap-mode
   porovnává hodnotu po parsování, což SARGable není; u produkčních objemů
   (134 mil. řádků) to stojí za ověření plánem.
   ============================================================================ */
GO

USE [kArchiveManagerAdmin];
GO

SET NOCOUNT ON;

IF EXISTS (SELECT 1 FROM arch.IndexRequirement ir
           JOIN arch.Process p ON p.ProcessId = ir.ProcessId
           WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING', N'RF_LOG2'))
BEGIN
    PRINT 'Pozadavky na indexy uz existuji - preskakuji.';
END
ELSE
BEGIN
    DECLARE @req TABLE (ProcessCode sysname, ReqType varchar(20), Tbl sysname, KeyCols nvarchar(200));
    INSERT @req VALUES
        (N'RECEIVING', 'SELECTION', N'BACKRH',    N'DATE_CREAT,PO_NUM'),
        (N'RECEIVING', 'JOIN',      N'BACKRH',    N'PO_NUM'),
        (N'RECEIVING', 'JOIN',      N'BACKRD',    N'PO_NUM'),
        (N'RECEIVING', 'JOIN',      N'BACKRD2',   N'PO_NUM'),
        (N'SHIPPING',  'SELECTION', N'SHIPHIST',  N'DATE_UPLD,PACKSLIP'),
        (N'SHIPPING',  'JOIN',      N'SHIPHIST',  N'PACKSLIP'),
        (N'SHIPPING',  'JOIN',      N'SHIPDETL',  N'PACKSLIP'),
        (N'SHIPPING',  'JOIN',      N'SHIPDETL2', N'PACKSLIP'),
        (N'SHIPPING',  'JOIN',      N'SHIPMSTR',  N'PACKSLIP'),
        (N'SHIPPING',  'JOIN',      N'SHIPMSTR2', N'PACKSLIP'),
        (N'SHIPPING',  'JOIN',      N'SHIPLINE',  N'PACKSLIP'),
        (N'SHIPPING',  'JOIN',      N'SHIPLINE2', N'PACKSLIP'),
        (N'RF_LOG2',   'SELECTION', N'RF_LOG2',   N'DATE_TIME,ROWID'),
        (N'RF_LOG2',   'JOIN',      N'RF_LOG2',   N'ROWID');

    INSERT arch.IndexRequirement
        (ProcessId, ObjectSpecId, RequirementType, SourceSchema, SourceTable,
         KeyColumnsCsv, IncludeColumnsCsv, FilterSql, IsMandatory, Notes, CreatedAt, ModifiedAt)
    SELECT p.ProcessId, o.ObjectSpecId, r.ReqType, N'dbo', r.Tbl,
           r.KeyCols, NULL, NULL, 0,
           N'Doporuceni kArchiveManager; zaklada vyhradne DBA zakaznika.',
           SYSUTCDATETIME(), SYSUTCDATETIME()
    FROM @req r
    JOIN arch.Process p ON p.ProcessCode = r.ProcessCode
    JOIN arch.ObjectSpec o ON o.ProcessId = p.ProcessId
                          AND o.SourceSchema = N'dbo'
                          AND o.SourceTable = r.Tbl;

    PRINT CONCAT('Zalozeno pozadavku na indexy: ', @@ROWCOUNT);
END;
GO
