/* ============================================================================
   kArchiveManager 2.0 — Customer Seed: NaniNails s.r.o.
   ----------------------------------------------------------------------------
   Zdrojová WMS DB : CHANGE_ME_SOURCE_DB  ← DOPLŇTE před spuštěním
   Archivní DB     : kArchiveManagerBackups
   Časové pásmo    : Central European Standard Time (CZ/SK)
   Datum seedu     : fresh deploy
   ----------------------------------------------------------------------------
   INSTRUKCE:
     1. Nahraďte CHANGE_ME_SOURCE_DB názvem WMS databáze (např. KMWE, KMWEBV…)
     2. Spusťte AFTER deploy_clean_v2_full_SSMS.sql + verify_clean_deploy.sql
     3. Zkontrolujte: EXEC arch.usp_ValidateConfiguration
     4. Projděte test_customer_naninails.sql (dry-run, explain)

   PROČ TAKTO NAKONFIGUROVÁNO:
   • RetentionDays=365 (NE 540):
       Nejstarší data BACKRH/SHIPHIST jsou z 2025-01-06.
       Dnes (2026-06-29) = 539 dní zpět.
       RetentionDays=540 → cutoff=2024-12-07 → ŽÁDNÍ kandidáti (0 řádků k archivaci).
       RetentionDays=365 → cutoff=2025-06-29 → ihned ~6 měs. starých dat jako kandidáti.
       Po odebrání starých dat plán = každý rok se archivuje 1 rok starých dat.

   • RF_LOG2 je JEDINÝ aktivní (IsEnabled=1 v ProcessDatabase).
       RECEIVING a SHIPPING jsou připraveny ale vypnuty (IsEnabled=0).
       Zákazník zapne po ověření indexů a dry-run pro každý proces zvlášť.

   • AuditLevel:
       RF_LOG2  → NONE   (velký objem, dohledání dle ROWID)
       RECEIVING/SHIPPING → BATCH (stávající standard; přepněte na ROW pro doc-lookup)

   IDEMPOTENCE: Seed selže, pokud procesy RECEIVING/SHIPPING/RF_LOG2 již existují.
   Na dev instanci s existujícími procesy spusťte UPDATE variantu nebo smažte záznamy.
   ============================================================================ */

USE [kArchiveManagerAdmin];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

/* ---- PARAMETRY (upravte před spuštěním) --------------------------------- */
DECLARE @SourceDb         nvarchar(128) = N'CHANGE_ME_SOURCE_DB';   -- ← ZMĚŇTE
DECLARE @ArchiveDb        nvarchar(128) = N'kArchiveManagerBackups';

-- @BackupOldConfig = 1: před smazáním zálohovatel stávající konfiguraci
--   do tabulek arch.Process_bak_YYYYMMDD_HHMMSS atd. v kArchiveManagerAdmin.
-- @ReplaceExisting = 1: smaže stávající záznamy RECEIVING/SHIPPING/RF_LOG2
--   a nahraje tuto novou konfiguraci (vyžaduje @BackupOldConfig = 1).
-- Pokud oba = 0 a procesy existují → skript selže (původní chování).
DECLARE @BackupOldConfig  bit           = 0;                         -- ← 1 pro zálohu
DECLARE @ReplaceExisting  bit           = 0;                         -- ← 1 pro přepsání
/* ------------------------------------------------------------------------- */

DECLARE @ProcessCodes nvarchar(200) = N'''RECEIVING'',N''SHIPPING'',N''RF_LOG2''';
DECLARE @Exists bit = CASE WHEN EXISTS (
    SELECT 1 FROM arch.Process
    WHERE ProcessCode IN (N'RECEIVING', N'SHIPPING', N'RF_LOG2')) THEN 1 ELSE 0 END;

-- Bezpečnostní pojistka: nahrazení bez zálohy je zakázáno
IF @ReplaceExisting = 1 AND @BackupOldConfig = 0
    THROW 60001, N'@ReplaceExisting = 1 vyzaduje @BackupOldConfig = 1. Zaloha je povinna.', 1;

-- Pokud procesy neexistují a @ReplaceExisting = 1, upozornění (ne chyba)
IF @Exists = 0 AND @ReplaceExisting = 1
    PRINT 'INFO: Procesy neexistuji, preskakuji backup/delete.';

-- Pokud procesy existují a @ReplaceExisting = 0 → selhání
IF @Exists = 1 AND @ReplaceExisting = 0
    THROW 60000, N'Procesy RECEIVING/SHIPPING/RF_LOG2 jiz existuji. Nastavte @BackupOldConfig=1 a @ReplaceExisting=1 pro nahrazeni.', 1;

/* ---- ZÁLOHA stávající konfigurace --------------------------------------- */
IF @Exists = 1 AND @BackupOldConfig = 1
BEGIN
    DECLARE @BakSuffix nvarchar(40)
        = N'bak_' + REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(19), GETDATE(), 120),
                                             N'-', N''), N':', N''), N' ', N'_');
    DECLARE @sql nvarchar(max);

    PRINT N'Zalohuji konfiguraci do arch.[*_' + @BakSuffix + N'] ...';

    SET @sql = N'SELECT * INTO arch.[Process_' + @BakSuffix
             + N'] FROM arch.Process'
             + N' WHERE ProcessCode IN (N''RECEIVING'',N''SHIPPING'',N''RF_LOG2'')';
    EXEC sp_executesql @sql;

    SET @sql = N'SELECT pd.* INTO arch.[ProcessDatabase_' + @BakSuffix
             + N'] FROM arch.ProcessDatabase pd'
             + N' JOIN arch.Process p ON p.ProcessId = pd.ProcessId'
             + N' WHERE p.ProcessCode IN (N''RECEIVING'',N''SHIPPING'',N''RF_LOG2'')';
    EXEC sp_executesql @sql;

    SET @sql = N'SELECT os.* INTO arch.[ObjectSpec_' + @BakSuffix
             + N'] FROM arch.ObjectSpec os'
             + N' JOIN arch.Process p ON p.ProcessId = os.ProcessId'
             + N' WHERE p.ProcessCode IN (N''RECEIVING'',N''SHIPPING'',N''RF_LOG2'')';
    EXEC sp_executesql @sql;

    SET @sql = N'SELECT pks.* INTO arch.[ProcessKeySpec_' + @BakSuffix
             + N'] FROM arch.ProcessKeySpec pks'
             + N' JOIN arch.Process p ON p.ProcessId = pks.ProcessId'
             + N' WHERE p.ProcessCode IN (N''RECEIVING'',N''SHIPPING'',N''RF_LOG2'')';
    EXEC sp_executesql @sql;

    SET @sql = N'SELECT ir.* INTO arch.[IndexRequirement_' + @BakSuffix
             + N'] FROM arch.IndexRequirement ir'
             + N' JOIN arch.Process p ON p.ProcessId = ir.ProcessId'
             + N' WHERE p.ProcessCode IN (N''RECEIVING'',N''SHIPPING'',N''RF_LOG2'')';
    EXEC sp_executesql @sql;

    PRINT N'Zaloha dokoncena (suffix: ' + @BakSuffix + N').';
    PRINT N'Zalohovane tabulky lze smazat prikazy:';
    PRINT N'  DROP TABLE arch.[Process_' + @BakSuffix + N'];';
    PRINT N'  DROP TABLE arch.[ProcessDatabase_' + @BakSuffix + N'];';
    PRINT N'  DROP TABLE arch.[ObjectSpec_' + @BakSuffix + N'];';
    PRINT N'  DROP TABLE arch.[ProcessKeySpec_' + @BakSuffix + N'];';
    PRINT N'  DROP TABLE arch.[IndexRequirement_' + @BakSuffix + N'];';
END

/* ---- PROMAZÁNÍ stávající konfigurace ------------------------------------ */
IF @Exists = 1 AND @ReplaceExisting = 1
BEGIN
    PRINT N'Mazam starou konfiguraci RECEIVING/SHIPPING/RF_LOG2 ...';
    DELETE ir
    FROM arch.IndexRequirement ir
    JOIN arch.Process p ON p.ProcessId = ir.ProcessId
    WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING', N'RF_LOG2');

    DELETE os
    FROM arch.ObjectSpec os
    JOIN arch.Process p ON p.ProcessId = os.ProcessId
    WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING', N'RF_LOG2');

    DELETE pks
    FROM arch.ProcessKeySpec pks
    JOIN arch.Process p ON p.ProcessId = pks.ProcessId
    WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING', N'RF_LOG2');

    DELETE pd
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p ON p.ProcessId = pd.ProcessId
    WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING', N'RF_LOG2');

    -- RunProfile: smažeme pouze profily specifické pro tento seed
    DELETE FROM arch.RunProfile
    WHERE RunProfileCode IN (N'JOB_DEFAULT', N'DRYRUN_ALL', N'RF_LOG2_PROD');

    -- arch.Process NESMAZAT — má FK z arch.Run/arch.RunItem (zachování historie).
    -- Použijeme UPDATE na místě (ProcessId se nezmění, RunItem history zůstane).
    UPDATE arch.Process SET
        Description = N'KArchiveManager - Purchase Order History',
        IsEnabled = 1, Mode = 1, RetentionDays = 365, CutoffSafetyLagMinutes = 1440,
        BatchDocCount = 500, BatchRowCount = NULL, MaxBatchesPerRun = 100,
        DelayMsBetweenBatches = 0, UseAppLock = 1, AppLockResource = NULL,
        LockTimeoutMs = 10000, DeadlockPriority = N'LOW',
        AnchorSchema = N'dbo', AnchorTable = N'BACKRH', AnchorDocKeyExpr = N'PO_NUM',
        AnchorDocKey2Expr = NULL,
        AnchorTimestampExpr = N'CAST(DATE_CREAT AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
        AnchorExtraWhereSql = NULL, AllowDeleteWithoutArchive = 0,
        CutoffMode = 0, CutoffDate = NULL, DocKeyLabel = N'PO_NUM',
        SelectionStrategy = N'ANCHOR', AuditLevel = N'BATCH',
        RequireSupportingIndex = 1, MaxRowsPerTransaction = NULL,
        CandidateWhereSql = NULL, CandidateOrderSql = NULL,
        ModifiedAt = SYSUTCDATETIME()
    WHERE ProcessCode = N'RECEIVING';

    UPDATE arch.Process SET
        Description = N'KArchiveManager - Sales Order History',
        IsEnabled = 1, Mode = 1, RetentionDays = 365, CutoffSafetyLagMinutes = 1440,
        BatchDocCount = 1000, BatchRowCount = NULL, MaxBatchesPerRun = 500,
        DelayMsBetweenBatches = 0, UseAppLock = 1, AppLockResource = NULL,
        LockTimeoutMs = 10000, DeadlockPriority = N'LOW',
        AnchorSchema = N'dbo', AnchorTable = N'SHIPHIST', AnchorDocKeyExpr = N'PACKSLIP',
        AnchorDocKey2Expr = NULL,
        AnchorTimestampExpr = N'CAST(COALESCE(DATE_UPLD,DATE_SHIP,DATE_CREAT) AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
        AnchorExtraWhereSql = NULL, AllowDeleteWithoutArchive = 0,
        CutoffMode = 0, CutoffDate = NULL, DocKeyLabel = N'PACKSLIP',
        SelectionStrategy = N'ANCHOR', AuditLevel = N'BATCH',
        RequireSupportingIndex = 1, MaxRowsPerTransaction = NULL,
        CandidateWhereSql = NULL, CandidateOrderSql = NULL,
        ModifiedAt = SYSUTCDATETIME()
    WHERE ProcessCode = N'SHIPPING';

    UPDATE arch.Process SET
        Description = N'KArchiveManager - System log history',
        IsEnabled = 1, Mode = 1, RetentionDays = 365, CutoffSafetyLagMinutes = 1440,
        BatchDocCount = NULL, BatchRowCount = 4000, MaxBatchesPerRun = 250,
        DelayMsBetweenBatches = 0, UseAppLock = 1, AppLockResource = NULL,
        LockTimeoutMs = 10000, DeadlockPriority = N'LOW',
        AnchorSchema = NULL, AnchorTable = NULL, AnchorDocKeyExpr = NULL,
        AnchorDocKey2Expr = NULL, AnchorTimestampExpr = NULL,
        AnchorExtraWhereSql = NULL, AllowDeleteWithoutArchive = 0,
        CutoffMode = 0, CutoffDate = NULL, DocKeyLabel = N'ROWID',
        SelectionStrategy = N'TIMESTAMP', AuditLevel = N'NONE',
        RequireSupportingIndex = 1, MaxRowsPerTransaction = 4000,
        CandidateWhereSql = NULL, CandidateOrderSql = N'DocCreatedAt, Key1',
        ModifiedAt = SYSUTCDATETIME()
    WHERE ProcessCode = N'RF_LOG2';   -- BatchRowCount/MaxRowsPerTransaction<=4000 (source lock-escalation guard); MaxBatchesPerRun 250 keeps 1,000,000 rows/run

    PRINT N'UPDATE arch.Process OK (ProcessId + RunItem history zachovany).';
    PRINT N'Stara konfigurace child tabulek smazana.';
END

BEGIN TRAN;

/* --------------------------------------------------------------------------
   1. arch.Process — pouze pro fresh deploy (@Exists = 0)
   Pro replace (@ReplaceExisting = 1) byl proces výše UPDATEován in-place.
   -------------------------------------------------------------------------- */
IF @Exists = 0
INSERT arch.Process (
    [ProcessCode], [Description], [IsEnabled], [Mode],
    [RetentionDays], [CutoffSafetyLagMinutes], [BatchDocCount], [BatchRowCount],
    [MaxBatchesPerRun], [DelayMsBetweenBatches], [UseAppLock], [AppLockResource],
    [LockTimeoutMs], [DeadlockPriority],
    [AnchorSchema], [AnchorTable], [AnchorDocKeyExpr], [AnchorDocKey2Expr],
    [AnchorTimestampExpr], [AnchorExtraWhereSql], [AllowDeleteWithoutArchive],
    [CutoffMode], [CutoffDate], [DocKeyLabel],
    [SelectionStrategy], [AuditLevel], [RequireSupportingIndex],
    [MaxRowsPerTransaction], [CandidateWhereSql], [CandidateOrderSql]
)
VALUES
-- RECEIVING — ANCHOR, doklady PO (BACKRH + BACKRD)
(N'RECEIVING', N'KArchiveManager - Purchase Order History',
 1, 1,
 365, 1440, 500, NULL,
 100, 0, 1, NULL,
 10000, N'LOW',
 N'dbo', N'BACKRH', N'PO_NUM', NULL,
 N'CAST(DATE_CREAT AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
 NULL, 0,
 0, NULL, N'PO_NUM',
 N'ANCHOR', N'BATCH', 1,
 NULL, NULL, NULL),

-- SHIPPING — ANCHOR, doklady PACKSLIP (SHIPHIST + 5 dílčích tabulek)
(N'SHIPPING', N'KArchiveManager - Sales Order History',
 1, 1,
 365, 1440, 1000, NULL,
 500, 0, 1, NULL,
 10000, N'LOW',
 N'dbo', N'SHIPHIST', N'PACKSLIP', NULL,
 N'CAST(COALESCE(DATE_UPLD, DATE_SHIP, DATE_CREAT) AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
 NULL, 0,
 0, NULL, N'PACKSLIP',
 N'ANCHOR', N'BATCH', 1,
 NULL, NULL, NULL),

-- RF_LOG2 — TIMESTAMP, jeden záznam = jeden řádek (ROWID)
(N'RF_LOG2', N'KArchiveManager - System log history',
 1, 1,
 365, 1440, NULL, 4000,
 250, 0, 1, NULL,
 10000, N'LOW',
 NULL, NULL, NULL, NULL,
 NULL, NULL, 0,
 0, NULL, N'ROWID',
 N'TIMESTAMP', N'NONE', 1,
 4000, NULL, N'DocCreatedAt, Key1');
 -- BatchRowCount + MaxRowsPerTransaction capped at 4000 (per-batch DELETE stays under SQL Server's
 -- ~5000 lock-escalation threshold so it cannot take a TABLE X lock on the production source and block
 -- OLTP); MaxBatchesPerRun raised to 250 so throughput is unchanged (4000 x 250 = 1,000,000 rows/run).

/* --------------------------------------------------------------------------
   2. arch.ProcessKeySpec
   (vždy — pro fresh deploy i replace; při replace byly child tabulky výše smazány)
   -------------------------------------------------------------------------- */
INSERT arch.ProcessKeySpec (
    [ProcessId], [KeyOrdinal], [KeyName], [SourceExpressionSql], [SqlType], [IsRequired]
)
VALUES
((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'),
 1, N'PO_NUM', N'a.PO_NUM', N'nvarchar(256)', 1),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 1, N'PACKSLIP', N'a.PACKSLIP', N'nvarchar(256)', 1),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RF_LOG2'),
 1, N'ROWID', N't.ROWID', N'nvarchar(256)', 1);

/* --------------------------------------------------------------------------
   3. arch.ObjectSpec
   RECEIVING : BACKRD (detail, DeleteOrder=10) → BACKRH (anchor, DeleteOrder=20)
   SHIPPING  : detaily 10-50 → SHIPHIST anchor 60
   RF_LOG2   : RF_LOG2 (10)
   NOTE: Pokud zákazník nemá SHIPDETL2/SHIPLINE/SHIPLINE2, smazat příslušné řádky.
   -------------------------------------------------------------------------- */
INSERT arch.ObjectSpec (
    [ProcessId], [SourceSchema], [SourceTable], [DeleteOrder], [DeleteMode],
    [TimestampExpr], [JoinToAnchorPredicateSql], [AdditionalWhereSql],
    [ArchiveSchema], [ArchiveTable], [RequireArchiveForDelete], [NaturalKeyLabel]
)
VALUES
-- RECEIVING
((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'),
 N'dbo', N'BACKRD', 10, 1,
 N'CAST(DATE_CREAT AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
 N't.PO_NUM = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PO_NUM'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'),
 N'dbo', N'BACKRH', 20, 1,
 N'CAST(DATE_CREAT AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
 N't.PO_NUM = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PO_NUM'),

-- SHIPPING — smazat řádky SHIPDETL2/SHIPLINE/SHIPLINE2 pokud tabulky neexistují v zdrojové DB
((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 N'dbo', N'SHIPDETL', 10, 1,
 N'CAST(DATECREATE AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
 N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 N'dbo', N'SHIPDETL2', 20, 1,
 N'CAST(DATECREATE AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
 N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 N'dbo', N'SHIPMSTR', 30, 1,
 N'CAST(COALESCE(DATE_SHIP, DATECREATE) AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
 N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 N'dbo', N'SHIPLINE', 40, 1,
 N'CAST(BILLEDDATE AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
 N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 N'dbo', N'SHIPLINE2', 50, 1,
 N'CAST(BILLEDDATE AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
 N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 N'dbo', N'SHIPHIST', 60, 1,
 N'CAST(COALESCE(DATE_UPLD, DATE_SHIP, DATE_CREAT) AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
 N't.PACKSLIP = k.Key1', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),

-- RF_LOG2
-- DEFENZIVNI TimestampExpr (RF_LOG2.DATE_TIME je nvarchar s MIXED formaty):
--   • TRY_CONVERT  = rychla cesta pro ISO 'yyyymmdd hh:mm:ss' (jazykove nezavisle, sargable)
--   • TRY_PARSE ... USING N'en-US' = fallback pro anglicke nazvy mesicu ('Apr 9 2025 4:09PM'),
--       ktere by pod ceskym SET LANGUAGE shodily tvrdy CAST (Msg 241)
--   • COALESCE short-circuituje → TRY_PARSE (pomaly CLR) bezi jen na anomalnich radcich
-- Fail-soft: neparsovatelny radek → NULL → runner ho BEZPECNE preskoci (nemaze, nearchivuje,
--   nespadne). Razitko se pri mazani nikdy znovu nevyhodnocuje (027) → divergence vzdy = 0.
-- Projde safe-expr validatorem (046) i presence-gate 50200 (obsahuje AT TIME ZONE).
((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RF_LOG2'),
 N'dbo', N'RF_LOG2', 10, 1,
 N'COALESCE(TRY_CONVERT(datetime2, t.DATE_TIME), TRY_PARSE(t.DATE_TIME AS datetime2 USING N''en-US'')) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
 N't.ROWID = k.Key1', N't.DATE_TIME IS NOT NULL',
 N'{SourceDb}', NULL, 1, N'ROWID');

/* --------------------------------------------------------------------------
   4. arch.IndexRequirement
   -------------------------------------------------------------------------- */
INSERT arch.IndexRequirement (
    [ProcessId], [ObjectSpecId], [RequirementType],
    [SourceSchema], [SourceTable], [KeyColumnsCsv], [IncludeColumnsCsv],
    [FilterSql], [IsMandatory], [Notes]
)
VALUES
-- RECEIVING
((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING')
    AND SourceTable=N'BACKRH'),
 N'SELECTION', N'dbo', N'BACKRH', N'DATE_CREAT,PO_NUM', NULL, NULL, 1,
 N'Anchor selection for RECEIVING. Composite (DATE_CREAT, PO_NUM).'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING')
    AND SourceTable=N'BACKRD'),
 N'JOIN', N'dbo', N'BACKRD', N'PO_NUM', NULL, NULL, 1, N'Child join BACKRD → keyset.'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING')
    AND SourceTable=N'BACKRH'),
 N'JOIN', N'dbo', N'BACKRH', N'PO_NUM', NULL, NULL, 1, N'Anchor join BACKRH → keyset.'),

-- SHIPPING
((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING')
    AND SourceTable=N'SHIPHIST'),
 N'SELECTION', N'dbo', N'SHIPHIST', N'DATE_UPLD,PACKSLIP', NULL, NULL, 1,
 N'Anchor selection for SHIPPING.'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING')
    AND SourceTable=N'SHIPDETL'),
 N'JOIN', N'dbo', N'SHIPDETL', N'PACKSLIP', NULL, NULL, 1, N'Child join SHIPDETL.'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING')
    AND SourceTable=N'SHIPDETL2'),
 N'JOIN', N'dbo', N'SHIPDETL2', N'PACKSLIP', NULL, NULL, 1, N'Child join SHIPDETL2.'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING')
    AND SourceTable=N'SHIPMSTR'),
 N'JOIN', N'dbo', N'SHIPMSTR', N'PACKSLIP', NULL, NULL, 1, N'Child join SHIPMSTR.'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING')
    AND SourceTable=N'SHIPLINE'),
 N'JOIN', N'dbo', N'SHIPLINE', N'PACKSLIP', NULL, NULL, 1, N'Child join SHIPLINE.'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING')
    AND SourceTable=N'SHIPLINE2'),
 N'JOIN', N'dbo', N'SHIPLINE2', N'PACKSLIP', NULL, NULL, 1, N'Child join SHIPLINE2.'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING')
    AND SourceTable=N'SHIPHIST'),
 N'JOIN', N'dbo', N'SHIPHIST', N'PACKSLIP', NULL, NULL, 1, N'Anchor join SHIPHIST.'),

-- RF_LOG2
((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RF_LOG2'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RF_LOG2')
    AND SourceTable=N'RF_LOG2'),
 N'SELECTION', N'dbo', N'RF_LOG2', N'DATE_TIME,ROWID', NULL, N'DATE_TIME IS NOT NULL', 1,
 N'RF_LOG2 timestamp selection — vyžaduje index na (DATE_TIME) WHERE DATE_TIME IS NOT NULL.'),

((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RF_LOG2'),
 (SELECT ObjectSpecId FROM arch.ObjectSpec
  WHERE ProcessId=(SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RF_LOG2')
    AND SourceTable=N'RF_LOG2'),
 N'JOIN', N'dbo', N'RF_LOG2', N'ROWID', NULL, NULL, 1,
 N'Timestamp keyset delete join zpět přes ROWID.');

/* --------------------------------------------------------------------------
   5. arch.ProcessDatabase — mapování na zdrojovou DB zákazníka
   RF_LOG2  : IsEnabled=1 (okamžitě aktivní)
   RECEIVING: IsEnabled=0 (zapnout po ověření indexů + dry-run)
   SHIPPING : IsEnabled=0 (zapnout po ověření indexů + dry-run)
   -------------------------------------------------------------------------- */
INSERT arch.ProcessDatabase (
    [ProcessId], [SourceDb], [ArchiveDb], [IsEnabled], [RunOrder],
    [Mode], [RetentionDays], [CutoffSafetyLagMinutes], [CutoffMode], [CutoffDate],
    [BatchDocCount], [BatchRowCount], [MaxBatchesPerRun], [DelayMsBetweenBatches],
    [UseAppLock], [AppLockResource], [LockTimeoutMs], [DeadlockPriority],
    [AnchorSchema], [AnchorTable], [AnchorDocKeyExpr], [AnchorDocKey2Expr],
    [AnchorTimestampExpr], [AnchorExtraWhereSql], [AllowDeleteWithoutArchive],
    [DocKeyLabel], [AuditLevel], [RequireSupportingIndex], [MaxRowsPerTransaction],
    [CandidateWhereSql], [CandidateOrderSql]
)
VALUES
-- RF_LOG2 — AKTIVNÍ (dědí vše z arch.Process)
((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RF_LOG2'),
 @SourceDb, @ArchiveDb, 1, 30,
 NULL,NULL,NULL,NULL,NULL, NULL,NULL,NULL,NULL,
 NULL,NULL,NULL,NULL, NULL,NULL,NULL,NULL,
 NULL,NULL,NULL, NULL,NULL,NULL,NULL, NULL,NULL),

-- RECEIVING — VYPNUTO, dědí z arch.Process
((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'),
 @SourceDb, @ArchiveDb, 0, 10,
 NULL,NULL,NULL,NULL,NULL, NULL,NULL,NULL,NULL,
 NULL,NULL,NULL,NULL, NULL,NULL,NULL,NULL,
 NULL,NULL,NULL, NULL,NULL,NULL,NULL, NULL,NULL),

-- SHIPPING — VYPNUTO, dědí z arch.Process
((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'SHIPPING'),
 @SourceDb, @ArchiveDb, 0, 20,
 NULL,NULL,NULL,NULL,NULL, NULL,NULL,NULL,NULL,
 NULL,NULL,NULL,NULL, NULL,NULL,NULL,NULL,
 NULL,NULL,NULL, NULL,NULL,NULL,NULL, NULL,NULL);

/* --------------------------------------------------------------------------
   6. arch.RunProfile
   -------------------------------------------------------------------------- */
INSERT arch.RunProfile (
    [RunProfileCode], [Description], [IsEnabled], [RunOnSchedule],
    [RunOrder], [ProcessCodeFilter], [SourceDbFilter], [ArchiveDbFilter],
    [RunWindowMinutes], [DryRun], [MaxCandidates], [PausedCooldownSeconds]
)
VALUES
-- Standardní naplánovaný běh 1× denně přes SQL Agent (RunWindowMinutes=55 = pojistka)
(N'JOB_DEFAULT', N'Default scheduled run — all enabled ProcessDatabase mappings.',
 1, 1, 10, NULL, NULL, NULL, 55, 0, NULL, 60),

-- Manuální dry-run přes Admin Console (verifikace bez mazání)
(N'DRYRUN_ALL', N'Manual dry-run across all enabled mappings.',
 1, 0, 100, NULL, NULL, NULL, 20, 1, 1000, 60),

-- Dedikovaný manuální run RF_LOG2
(N'RF_LOG2_PROD', N'Manual run: RF_LOG2 — první velký run nebo ruční spuštění.',
 1, 0, 200, N'RF_LOG2', @SourceDb, NULL, 60, 0, NULL, 60);

COMMIT;
GO

PRINT '=== Seed NaniNails dokončen. Kontrolní počty: ===';
SELECT 'Process'          t, COUNT(*) n FROM arch.Process
UNION ALL SELECT 'ProcessDatabase', COUNT(*) FROM arch.ProcessDatabase
UNION ALL SELECT 'ObjectSpec',      COUNT(*) FROM arch.ObjectSpec
UNION ALL SELECT 'ProcessKeySpec',  COUNT(*) FROM arch.ProcessKeySpec
UNION ALL SELECT 'IndexRequirement',COUNT(*) FROM arch.IndexRequirement
UNION ALL SELECT 'RunProfile',      COUNT(*) FROM arch.RunProfile;
GO

PRINT '=== Validace konfigurace: ===';
EXEC arch.usp_ValidateConfiguration;
GO
