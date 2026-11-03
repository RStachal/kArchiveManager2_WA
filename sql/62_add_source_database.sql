/* ============================================================================
   kArchiveManager 2.0 - pridani dalsi zdrojove databaze k existujicim planum
   ----------------------------------------------------------------------------
   Plany (RECEIVING, SHIPPING, RF_LOG2) jsou na zdrojove databazi nezavisle:
   popisuji tvar dokumentu, ne konkretni instanci. Pridat dalsi prostredi proto
   znamena jen doplnit radky do arch.ProcessDatabase - konfigurace se nekopiruje
   ani nezdvojuje.

   Archivni schema vznikne automaticky pod nazvem zdrojove databaze, takze CZ
   (KMWE) a SK (KMWESK) skonci v ODDELENYCH SCHEMATECH teze archivni databaze -
   presne jak navrh z 18. 6. 2026 pozaduje.

   Prepisy (retence, davkovani, audit) zustavaji NULL, takze pro nove prostredi
   plati tataz pravidla jako pro to prvni. Kdyby se mela lisit, nastavi se az
   tady na urovni ProcessDatabase, ne na urovni planu.

   POZADAVEK: zdrojova databaze musi byt na compatibility level >= 130, jinak
   neni k dispozici TRY_CONVERT a konfigurace logu selze.

   Idempotentni: co uz je namapovane, preskoci.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE [kArchiveManagerAdmin];
GO

DECLARE @SourceDb   sysname = N'KMWESK';
DECLARE @ArchiveDb  sysname = N'kArchiveManagerBackups';
DECLARE @RunOrderBase int   = 2000;      -- aby SK bezelo az po CZ

DECLARE @codes TABLE (ProcessCode sysname PRIMARY KEY, Poradi int);
INSERT @codes VALUES (N'RECEIVING', 10), (N'SHIPPING', 20), (N'RF_LOG2', 30);

/* ---------- kontroly ------------------------------------------------------ */
IF DB_ID(@SourceDb) IS NULL
    THROW 60010, 'Zdrojova databaze neexistuje.', 1;

DECLARE @compat tinyint = (SELECT compatibility_level FROM sys.databases WHERE name = @SourceDb);
IF @compat < 130
BEGIN
    DECLARE @m nvarchar(300) = CONCAT(N'Zdrojova databaze ', @SourceDb, N' je na compatibility level ', @compat,
        N'. Konfigurace logu pouziva TRY_CONVERT, ktery vyzaduje 130 a vys.');
    THROW 60011, @m, 1;
END;

IF NOT EXISTS (SELECT 1 FROM arch.Process p JOIN @codes c ON c.ProcessCode = p.ProcessCode)
    THROW 60012, 'Plany neexistuji - spustte nejdriv 60_configure_kmwe_edge.sql.', 1;

/* ---------- chybi ve zdroji nektera mapovana tabulka? --------------------- */
DECLARE @chybi nvarchar(max) = N'';
DECLARE @sql nvarchar(max) = N'
    SELECT @out = STRING_AGG(CONVERT(nvarchar(max), o.SourceTable), N'', '')
    FROM arch.ObjectSpec o
    JOIN arch.Process p ON p.ProcessId = o.ProcessId
    WHERE p.ProcessCode IN (N''RECEIVING'', N''SHIPPING'', N''RF_LOG2'')
      AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(@SourceDb) + N'.sys.tables t
                      JOIN ' + QUOTENAME(@SourceDb) + N'.sys.schemas s ON s.schema_id = t.schema_id
                      WHERE s.name = o.SourceSchema COLLATE DATABASE_DEFAULT
                        AND t.name = o.SourceTable COLLATE DATABASE_DEFAULT);';
EXEC sys.sp_executesql @sql, N'@out nvarchar(max) OUTPUT', @out = @chybi OUTPUT;

IF NULLIF(@chybi, N'') IS NOT NULL
BEGIN
    DECLARE @m2 nvarchar(max) = CONCAT(N'Ve zdrojove databazi ', @SourceDb, N' chybi mapovane tabulky: ', @chybi);
    THROW 60013, @m2, 1;
END;

/* ---------- mapovani ------------------------------------------------------ */
BEGIN TRAN;

INSERT arch.ProcessDatabase (ProcessId, SourceDb, ArchiveDb, IsEnabled, RunOrder)
SELECT p.ProcessId, @SourceDb, @ArchiveDb, 1, @RunOrderBase + c.Poradi
FROM arch.Process p
JOIN @codes c ON c.ProcessCode = p.ProcessCode
WHERE NOT EXISTS (SELECT 1 FROM arch.ProcessDatabase pd
                  WHERE pd.ProcessId = p.ProcessId AND pd.SourceDb = @SourceDb);

DECLARE @pridano int = @@ROWCOUNT;
COMMIT;

PRINT CONCAT(N'Pridano mapovani: ', @pridano, N' (0 = uz byla namapovana)');

/* ---------- vysledek ------------------------------------------------------ */
SELECT CONVERT(varchar(12), p.ProcessCode) AS Plan_,
       CONVERT(varchar(10), pd.SourceDb)   AS Zdroj,
       CONVERT(varchar(24), pd.ArchiveDb)  AS Archiv,
       pd.RunOrder AS Poradi,
       pd.IsEnabled AS Povoleno,
       ISNULL(CONVERT(varchar(6), pd.RetentionDays), N'dedi') AS Retence
FROM arch.ProcessDatabase pd
JOIN arch.Process p ON p.ProcessId = pd.ProcessId
ORDER BY pd.RunOrder, p.ProcessCode;
GO
