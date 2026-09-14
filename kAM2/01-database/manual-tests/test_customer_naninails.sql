/* ============================================================================
   kArchiveManager 2.0 — Manuální testy: NaniNails s.r.o.
   ----------------------------------------------------------------------------
   Spouštějte postupně po nasazení seed_customer_naninails.sql.
   Každá sekce je samostatný krok — nespouštějte vše najednou.
   Zdrojová DB: nahraďte CHANGE_ME_SOURCE_DB.
   ============================================================================ */

USE [kArchiveManagerAdmin];
GO
SET NOCOUNT ON;

/* ============================================================================
   KROK 1 — Ověření konfigurace (read-only, vždy první)
   ============================================================================ */

-- 1a. Validace konzistence konfigurace (0 ERROR = seed je správně)
EXEC arch.usp_ValidateConfiguration;
GO

-- 1b. Efektivní konfigurace po COALESCE Process ← ProcessDatabase
SELECT ProcessCode, SourceDb, ArchiveDb, IsEnabled, Mode,
       SelectionStrategy, AuditLevel, RetentionDays, CutoffMode, CutoffDate
FROM arch.v_ProcessDatabaseEffective
WHERE ProcessCode IN (N'RECEIVING', N'SHIPPING', N'RF_LOG2')
ORDER BY ProcessCode;
GO

-- 1c. Kontrola požadovaných indexů na zdrojové DB
EXEC arch.usp_ValidateIndexRequirements;
GO

/* ============================================================================
   KROK 2 — Explain plán (co by se archivovalo, bez spuštění)
   ============================================================================ */
EXEC arch.usp_ExplainProcessPlan @ProcessCode = N'RF_LOG2';
GO
EXEC arch.usp_ExplainProcessPlan @ProcessCode = N'RECEIVING';
GO
EXEC arch.usp_ExplainProcessPlan @ProcessCode = N'SHIPPING';
GO

/* ============================================================================
   KROK 3 — DRY-RUN RF_LOG2 (ověření počtu kandidátů a cutoffu)
   Nic se nesmaže ani nearchivuje. Zkontrolujte:
     • CandidateCount > 0 (pokud 0, viz poznámka níže)
     • CutoffUtc odpovídá ~1 rok zpět
   ============================================================================ */
DECLARE @Stop datetime2(0) = DATEADD(MINUTE, 5, SYSUTCDATETIME());
EXEC arch.usp_RunConfiguredProcesses_Prepared
    @ProcessCode   = N'RF_LOG2',
    @SourceDb      = N'CHANGE_ME_SOURCE_DB',
    @ArchiveDb     = N'kArchiveManagerBackups',
    @StopAtUtc     = @Stop,
    @DryRun        = 1,
    @MaxCandidates = 500;
GO

-- Po dry-run zkontrolujte výsledek běhu
SELECT TOP 5 RunId, ProcessCode, SourceDb, Status, DryRun,
             StartedAt, FinishedAt, CandidateCount, ArchivedCount, DeletedCount,
             ErrorMessage
FROM arch.v_RunItemsRecent
ORDER BY RunItemId DESC;
GO

/* ============================================================================
   POZNÁMKA — Pokud CandidateCount = 0 pro RF_LOG2:
   Příčiny:
     a) Sloupec DATE_TIME je jiného typu než DATETIME (ověřte sp_help 'RF_LOG2')
     b) Všechny záznamy mají DATE_TIME = NULL (vyloučeny AdditionalWhereSql)
     c) Nejstarší záznamy s DATE_TIME IS NOT NULL jsou novější než cutoff (365 dní)
        → snižte RetentionDays nebo použijte CutoffMode=1 s explicitním CutoffDate
   Diagnostika:
     SELECT TOP 10 ROWID, DATE_TIME, CREATEDDATE
     FROM [CHANGE_ME_SOURCE_DB].dbo.RF_LOG2
     WHERE DATE_TIME IS NOT NULL
     ORDER BY DATE_TIME;
   ============================================================================ */

/* ============================================================================
   KROK 4 — Provisioning archivních tabulek (jednou před prvním ostrým během)
   Vytvoří prázdné tabulky v kArchiveManagerBackups.
   ============================================================================ */
EXEC arch.usp_ProvisionArchiveTablesForProcess
    @ProcessCode = N'RF_LOG2',
    @SourceDb    = N'CHANGE_ME_SOURCE_DB',
    @ArchiveDb   = N'kArchiveManagerBackups';
GO

-- Ověření provisioning výsledku (tabulky existují v kArchiveManagerBackups?)
SELECT s.name AS ArchiveSchema, t.name AS ArchiveTable, t.create_date
FROM [kArchiveManagerBackups].sys.tables t
JOIN [kArchiveManagerBackups].sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = N'CHANGE_ME_SOURCE_DB'    -- název schématu = název zdrojové DB
ORDER BY t.name;
GO

/* ============================================================================
   KROK 5 — Go-live kontrolní seznam
   Všechny položky musí být PASS před ostrým během na produkci.
   ============================================================================ */
EXEC arch.usp_Frontend_GoLiveReadiness;
GO

/* ============================================================================
   KROK 6 — OSTRÝ RUN RF_LOG2 (první dávka, omezená na 50 000 řádků)
   Spustit AŽ PO:
     • Dry-run ukázal CandidateCount > 0
     • Provisioning proběhl (KROK 4)
     • Go-live PASS (KROK 5)
     • Záloha kArchiveManagerBackups provedena
   ============================================================================ */
/*
DECLARE @Stop datetime2(0) = DATEADD(MINUTE, 20, SYSUTCDATETIME());
EXEC arch.usp_RunConfiguredProcesses_Prepared
    @ProcessCode   = N'RF_LOG2',
    @SourceDb      = N'CHANGE_ME_SOURCE_DB',
    @ArchiveDb     = N'kArchiveManagerBackups',
    @StopAtUtc     = @Stop,
    @DryRun        = 0,
    @MaxCandidates = 50000;
*/
GO

/* ============================================================================
   KROK 7 — Ověření výsledku po ostrém runu
   ============================================================================ */
-- Poslední běhy
SELECT TOP 10 RunId, ProcessCode, SourceDb, Status, DryRun,
              StartedAt, FinishedAt, CandidateCount, ArchivedCount, DeletedCount,
              ErrorMessage
FROM arch.v_RunItemsRecent
ORDER BY RunItemId DESC;
GO

-- Provozní zdraví (0 ERROR řádků = OK)
SELECT ProcessCode, SourceDb, Status, LastActivityAtUtc, ArchivedTotal, DeletedTotal
FROM arch.v_OperationalHealth
WHERE ProcessCode IN (N'RF_LOG2', N'RECEIVING', N'SHIPPING')
ORDER BY LastActivityAtUtc DESC;
GO

-- Divergence ověření (archivedCount = deletedCount, Divergence = 0)
SELECT TOP 5 RunId, ProcessCode, SourceDb,
             ArchivedCount, DeletedCount,
             (ArchivedCount - DeletedCount) AS Divergence
FROM arch.v_RunItemsRecent
WHERE ProcessCode = N'RF_LOG2'
ORDER BY RunItemId DESC;
GO

/* ============================================================================
   KROK 8 — Aktivace RECEIVING + SHIPPING (po ověření RF_LOG2)

   Podmínky před aktivací:
     1. RF_LOG2 ostrý run proběhl bez ERROR, Divergence = 0
     2. Provisioning archivních tabulek pro RECEIVING i SHIPPING
     3. Indexy na zdrojové DB ověřeny (usp_ValidateIndexRequirements)
     4. Dry-run každého procesu ukázal rozumný CandidateCount

   Aktivace:
   UPDATE arch.ProcessDatabase
      SET IsEnabled = 1, ModifiedAt = SYSUTCDATETIME()
   WHERE ProcessCode IN (N'RECEIVING', N'SHIPPING')
     AND SourceDb = N'CHANGE_ME_SOURCE_DB';
   ============================================================================ */

/* ============================================================================
   KROK 9 — Diagnostické dotazy
   ============================================================================ */

-- Přímé ověření nejstarších kandidátů RF_LOG2 ze zdrojové DB
/*
SELECT TOP 10 ROWID, DATE_TIME, CREATEDDATE
FROM [CHANGE_ME_SOURCE_DB].dbo.RF_LOG2
WHERE DATE_TIME IS NOT NULL
ORDER BY DATE_TIME;
*/

-- Přímé ověření nejstarších kandidátů RECEIVING ze zdrojové DB
/*
SELECT TOP 10 PO_NUM, DATE_CREAT, RECVD_ON
FROM [CHANGE_ME_SOURCE_DB].dbo.BACKRH
ORDER BY DATE_CREAT;
*/

-- Přímé ověření nejstarších kandidátů SHIPPING ze zdrojové DB
/*
SELECT TOP 10 PACKSLIP, DATE_UPLD, DATE_SHIP, DATE_CREAT
FROM [CHANGE_ME_SOURCE_DB].dbo.SHIPHIST
ORDER BY COALESCE(DATE_UPLD, DATE_SHIP, DATE_CREAT);
*/

-- Aktuální cutoff pro každý process
SELECT p.ProcessCode, pd.SourceDb, pd.IsEnabled,
       COALESCE(pd.RetentionDays, p.RetentionDays) AS EffRetentionDays,
       DATEADD(DAY, -COALESCE(pd.RetentionDays, p.RetentionDays), CAST(GETDATE() AS date)) AS CutoffApprox
FROM arch.ProcessDatabase pd
JOIN arch.Process p ON p.ProcessId = pd.ProcessId
WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING', N'RF_LOG2');
GO
