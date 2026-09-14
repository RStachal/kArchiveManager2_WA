# kArchiveManager 2.0 + Admin Console — Kompletní technická dokumentace

**Verze dokumentace:** 2026-06-11 · **Vlastník:** Radim Stachal / KODYS
**Zdroj pravdy:** repozitář `RStachal/WMSArchiveManager`, branch `audit/integration-clean-bundle`

Tento dokument popisuje **kompletně** mechanismy, logiku a možnosti obou aplikací:
**kArchiveManager 2.0** (metadaty řízená archivace a mazání WMS dat na SQL Serveru) a její
webovou správu **Admin Console**. Je psán tak, aby z něj bylo možné porozumět jak provoznímu
chování, tak vnitřní implementaci, konfiguraci a bezpečnostním/správnostním zárukám.

> Doprovodné dokumenty: `governance-model.md`, `audit-model.md`, `v2-operational-modes.md`,
> `v2-performance-best-practices.md`, `rf-log2-run-optimization.md`,
> `production-handover-go-no-go-2026-06-10.md`, provozní runbooky.

---

## Obsah

1. [Přehled a architektura](#1-přehled-a-architektura)
2. [Selekční strategie a mechanika runneru](#2-selekční-strategie-a-mechanika-runneru)
3. [Režimy zpracování a invarianty](#3-režimy-zpracování-a-invarianty)
4. [Cutoff, časové zóny a retence](#4-cutoff-časové-zóny-a-retence)
5. [Bezpečnostní a governance brány](#5-bezpečnostní-a-governance-brány)
6. [Audit model a sledovatelnost](#6-audit-model-a-sledovatelnost)
7. [Restore (un-archive) a Stop/Cancel](#7-restore-un-archive-a-stopcancel)
8. [Konfigurační schéma (referenční)](#8-konfigurační-schéma-referenční)
9. [Admin Console — architektura, API, bezpečnost](#9-admin-console--architektura-api-bezpečnost)
10. [Admin Console — funkce a obrazovky](#10-admin-console--funkce-a-obrazovky)
11. [Nasazení, seedy, SQL joby a provoz](#11-nasazení-seedy-sql-joby-a-provoz)
12. [Referenční chybové kódy a výkon](#12-referenční-chybové-kódy-a-výkon)

---


## 1. Přehled a architektura

### 1.1 Co je kArchiveManager 2.0 a jaký problém řeší

**kArchiveManager 2.0** je univerzální nástroj pro Microsoft SQL Server, který **řízeně promazává a volitelně archivuje historická data** mimo provozní (zdrojové) WMS databáze. Cílem je udržet provozní databáze v rozumné velikosti a výkonu, aniž by se nenávratně ztratila smazaná data — ta jsou (v archivačním režimu) přesunuta do oddělené archivní databáze, která se stává *system-of-record* smazaných řádků.

Nejde o jeden pevně „zadrátovaný" proces. kArchiveManager je **konfigurační framework**: chování každého úklidového procesu je popsáno **metadaty**, nikoli procedurou napsanou na míru. Nový proces (např. archivace jiné tabulky či jiné databáze) se přidá **konfigurací**, ne psaním nové speciální mazací procedury. Tentýž runtime obsluhuje libovolný počet procesů nad libovolným počtem zdrojových databází.

Cílový rozsah nasazení: databáze 100–200+ GB, zdrojové tabulky 50–100M+ řádků. Z toho plynou architektonické zásady popsané dále (žádné produkční table scany, žádné neomezené `DELETE`, dávkování s resumovatelností).

Dokument popisuje **aktuální zpevněný stav** — čistý v2 build po produkčním auditu (*audit-hardened build*), nikoli historický v1 stav. V1.0 runner procedury (`usp_RunProcess`, `usp_RunProcess_RF_LOG2`, `usp_RunProcess_TimestampKeyset`, `usp_RunWorkBatch…`) v čistém zákaznickém buildu vůbec neexistují; na prostředí upgradovaném z v1 jsou karanténované/blokované.

### 1.2 Dvou-databázový model (+ zdrojové DB)

Systém pracuje se třemi databázovými rolemi. Klíčové je **oddělení řízení od archivu**:

| Databáze | Role | Obsah | Recovery model |
| --- | --- | --- | --- |
| **kArchiveManagerAdmin** | Řídicí / „mozek" | Konfigurace, plánování, stav rozpracované práce (keyset), audit, monitoring. **Neobsahuje archivovaná data.** | dle instance |
| **kArchiveManagerBackups** | Archivní / *system-of-record* smazaných dat | Archivované řádky, oddělené schématy podle zdrojové DB. | **FULL** (vynuceno) |
| **Zdrojové databáze** (zákaznické) | Provozní data | Aplikace z nich po dávkách maže; **nikdy nemění jejich schéma ani business logiku.** | dle zákazníka |

#### kArchiveManagerAdmin — řídicí / metadata / audit

Zakládá ji `Databases/create_kArchiveManagerAdmin.sql`. Skript je idempotentní (`IF DB_ID(...) IS NULL CREATE DATABASE`). Důležitý detail: **compatibility level je přitvrzen na minimálně 150** (SQL 2019), protože config/validační/least-privilege skripty používají `STRING_SPLIT`, který vyžaduje DB compat ≥ 130. Na instanci upgradované z verze < 2016 by čerstvá DB jinak mohla zdědit z `model` úroveň 120 a skripty by selhaly:

```sql
IF (SELECT compatibility_level FROM sys.databases WHERE name = N'kArchiveManagerAdmin') < 150
    ALTER DATABASE [kArchiveManagerAdmin] SET COMPATIBILITY_LEVEL = 150;
```

Všechny objekty řídicí DB žijí ve schématu **`arch`** (zakládá ho `001_upgrade_to_2_0.sql`). Tato databáze drží konfiguraci, plán, stav rozpracované práce a kompletní auditní/monitorovací stopu — **ne však samotná archivovaná data**.

#### kArchiveManagerBackups — archiv, FULL recovery

Zakládá ji `Databases/create_kArchiveManagerBackups.sql`, rovněž idempotentně. Protože je archivní DB jediným úložištěm nevratně smazaných řádků, **skript explicitně vynucuje recovery model `FULL`**:

```sql
IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N'kArchiveManagerBackups') <> N'FULL'
    ALTER DATABASE [kArchiveManagerBackups] SET RECOVERY FULL;
```

Důvod je provozní: hodinový LOG-backup job (`deploy/v2/048_archive_db_backup.sql`) je účinný jen ve FULL recovery — pod SIMPLE by tiše neudělal nic (silent no-op). Archivní DB se nastavuje explicitně, aby nedědila náhodný recovery model serverového `model`. Archivní data jsou uvnitř oddělená **schématy podle zdrojové databáze** (doporučení: `ArchiveSchema = N'{SourceDb}'`, např. `Edge`, `KMWEBV`), takže jedna archivní DB může bezpečně držet data z více zdrojů. Tato databáze **musí mít vlastní zálohu** (FULL + LOG) a restore drill; go-live readiness hlídá stáří poslední FULL zálohy.

#### Zdrojové (zákaznické) databáze

Provozní WMS databáze. kArchiveManager z nich **pouze čte a po dávkách maže** vybrané řádky; nikdy nemodifikuje jejich schéma ani aplikační logiku. Vyžaduje na nich existenci deklarovaných tabulek/sloupců/indexů (validováno před během, viz §6 dokumentace), pro Mode=2 navíc PRIMARY KEY na zdrojové tabulce.

### 1.3 Metadaty řízený univerzální runner

Runtime **nečte konfigurační tabulky napřímo** — čte **efektivní views**, které slučují šablonu a per-DB override a zároveň u každé hodnoty vrací její původ. To je definováno v `022_effective_database_overrides.sql`:

- `arch.v_ProcessDatabaseEffective` — výsledná konfigurace procesu pro danou zdrojovou DB.
- `arch.v_ObjectSpecDatabaseEffective` — výsledná objektová (tabulková) konfigurace.

**Pravidlo vyhodnocení** je jednoduchý `COALESCE(per-DB override, šablona)`. View navíc vrací sloupce `*Source` označující, odkud hodnota pochází (`'ProcessDatabase'` vs. `'Process'`), např.:

```sql
Mode            = COALESCE(pd.Mode, p.Mode),
ModeSource      = CASE WHEN pd.Mode IS NULL THEN 'Process' ELSE 'ProcessDatabase' END,
RetentionDays   = COALESCE(pd.RetentionDays, p.RetentionDays),
RetentionDaysSource = ...,
CutoffDate      = COALESCE(pd.CutoffDate, p.CutoffDate),
CutoffDateSource    = ...,
AuditLevel      = COALESCE(NULLIF(LTRIM(RTRIM(pd.AuditLevel)), N''), p.AuditLevel),
AuditLevelSource    = ...
```

Runner je **univerzální**: jeho chování pro daný proces×DB je plně určeno řádkem v efektivním view. Stejný kód obslouží ANCHOR dokladový model i TIMESTAMP velkoobjemový log — liší se jen metadata (`SelectionStrategy`, výrazy, klíče, limity).

#### Tři režimy zpracování (`Mode`)

| Mode | Význam | Maže zdroj? | Archivuje? |
| --- | --- | --- | --- |
| **1** | Archivace + mazání | ano (až po archivaci) | ano |
| **0** | Delete-only (mazání bez archivace) | ano | ne |
| **2** | Copy-only (idempotentní záloha) | **ne, nikdy** | ano (jen řádky, které v archivu ještě nejsou) |

`Mode = 2` (zaveden v `057_copy_only_mode.sql`) je nedestruktivní a idempotentní: dedup je podle **zdrojového PRIMARY KEY**, re-run zkopíruje 0 nových řádků. `RowsArchived` udává skutečně zkopírované řádky tohoto běhu (autoritativní „co se zpracovalo"), nikoli `DocsDone`. Zdrojová tabulka bez PK nelze idempotentně kopírovat → `THROW 50220`. CHECK constraint `CK_Process_Mode` na `arch.Process` (a stejný na `arch.ProcessDatabase`) je v 057 rozšířen, aby přijal hodnotu 2.

#### Dvě nezávislé „páky" provozu

Vždy se rozhoduje ve dvou nezávislých osách:

- **Run mode** — `@DryRun = 1` (náhled; nahlásí počty kandidátů a cutoff, ale **nic nemaže/nearchivuje a nepíše `RunDocAudit`**) vs. `@DryRun = 0` (reálné zpracování).
- **AuditLevel** — `NONE` / `BATCH` / `OBJECT` / `ROW` (kolik důkazů se o reálném běhu zapíše); vynuceno CHECK `CK_Process_AuditLevel`.

### 1.4 Vysokoúrovňový datový tok

Řetězec spuštění (oficiální v2 cesta, vstupní bod pro SQL Agent i ad hoc):

```
arch.usp_RunProfile_Prepared                         -- 1 run profil
  └─ arch.usp_RunConfiguredProcesses_Prepared        -- vybere procesy podle filtru
       ├─ ANCHOR strategie:
       │    arch.usp_PrepareCandidates               -- naplní WorkBatch + WorkBatchKey (keyset)
       │      └─ arch.usp_RunPreparedBatches_InWindow
       │           └─ arch.usp_RunPreparedBatch       -- archive + delete jedné dávky
       └─ TIMESTAMP strategie:
            arch.usp_RunTimestampProcess              -- časový cutoff bez velkého keyset stagingu
```

Životní cyklus jednoho procesu probíhá v explicitních fázích — **konfigurace → kandidáti → dávky → archiv‑pak‑delete → audit**:

1. **Konfigurace** — runner načte efektivní konfiguraci procesu×DB (`v_ProcessDatabaseEffective`, `v_ObjectSpecDatabaseEffective`), klíče kandidátů (`arch.ProcessKeySpec`) a indexové předpoklady (`arch.IndexRequirement`).
2. **SELECT (kandidáti)** — vyberou se kandidáti podle strategie. U ANCHOR se materializují **jednou** do resumovatelného keysetu `arch.WorkBatch` + `arch.WorkBatchKey`. Tím se runner vyhne opakovanému skenování velkých zdrojových tabulek generickým `DELETE TOP` s predikátem.
3. **ARCHIVE** — (Mode 1 a 2) vybrané řádky se vloží do archivní DB.
4. **DELETE (po dávkách)** — (Mode 1 a 0) zdrojové řádky se mažou JOINem na materializovaný keyset / přes indexovaný timestamp, v malých dávkách (omezuje růst transakčního logu, umožňuje resume).
5. **AUDIT** — výsledek a stopa se zapíšou do řídicí DB (`arch.Run` → `arch.RunItem` → `arch.RunItemObject`, u `ROW` navíc `arch.RunDocAudit`).

**Archive-before-delete invariant (Mode = 1):** zdrojový řádek se smaže **až po** úspěšném vložení do archivu, ve stejném transakčním rozsahu. Runtime hlídá **Divergence = 0** (`RowsArchived == RowsDeleted`); nesoulad je chyba.

### 1.5 Konfigurační model: šablona → override

```
arch.Process            (šablona procesu — společná pro všechny DB)
   ↓ přepisuje per-DB
arch.ProcessDatabase    (proces × zdrojová DB × archivní DB — runtime override)

arch.ObjectSpec         (tabulky, které proces zpracovává)
   ↓ přepisuje per-DB
arch.ObjectSpecDatabaseOverride  (odchylky objektu v jedné DB)
```

`arch.ProcessDatabase` (zakládá `001`, override sloupce přidává `022`) nese mj. unikátní klíč `UQ_ProcessDatabase_Process_Source_Archive (ProcessId, SourceDb, ArchiveDb)` a FK na `arch.Process`. Per-DB override sloupce (`Mode`, `RetentionDays`, `CutoffMode`, `CutoffDate`, `BatchDocCount`, `AuditLevel`, kotvové výrazy `AnchorSchema`/`AnchorTable`/`AnchorDocKeyExpr`/`AnchorTimestampExpr` atd.) jsou **NULLABLE** — je-li hodnota NULL, použije se šablona z `arch.Process`.

### 1.6 Strategie výběru kandidátů (`SelectionStrategy`)

Strategie je číselník `arch.SelectionStrategy` (seed v `010_universal_archive_core.sql`), vynucený CHECK constraintem `CK_Process_SelectionStrategy` na `arch.Process`. Každá strategie deklaruje, jaké vstupy vyžaduje (`RequiresAnchor`, `RequiresTimestamp`, `RequiresRange`, `RequiresExternalKeyset`):

| `StrategyCode` | Popis | Aktivně používané |
| --- | --- | --- |
| **ANCHOR** | Výběr parent/anchor řádku následovaný joiny na child tabulky (dokladové modely: `RECEIVING`, `SHIPPING`). | ✅ |
| **TIMESTAMP** | Výběr přes indexovaný časový cutoff (velké log tabulky: `RF_LOG2`, integrace). | ✅ |
| KEYSET | Externě dodaný / nastagovaný keyset. | připraveno |
| RANGE | Omezený monotónní rozsah klíče (identity/sequence). | připraveno |
| PARTITION | Archivace/mazání na úrovni partition (switch/truncate). | připraveno |
| CUSTOM_QUERY | Revidovaný zákaznický dotaz emitující standardní tvar klíče. | připraveno |
| ORPHAN | Child řádky bez parenta (indexovaný anti-join). | připraveno |
| SOFT_DELETE | Úklid podle status/flag sloupce s volitelným cutoffem. | připraveno |

#### ANCHOR vs. TIMESTAMP v kostce

- **ANCHOR** — pro dokladové modely (parent + navázané child tabulky). Vybere kotevní (parent) řádky, ty se s klíči materializují **jednou** do `arch.WorkBatchKey` (resumovatelný keyset; statusy `0`=připraveno, `1`=claimnuto, `2`=hotovo, `3`=chyba dle `CK_WorkBatchKey_Status`). Mazání/archivace child tabulek pak jdou indexovaným JOINem na tento keyset. Doklad je definován výrazy `AnchorDocKeyExpr` / `AnchorDocKey2Expr` / `DocKeyLabel`. Vhodné tam, kde je třeba zachovat referenční konzistenci celého dokladu.
- **TIMESTAMP** — pro velké historické/log tabulky řízené čistě časovým cutoffem. **Nevytváří velký `WorkBatchKey` staging** — vybírá a maže přímo přes timestamp index (`TimestampExpr` / `AnchorTimestampExpr`), což je vhodné pro desítky milionů řádků. Cutoff výraz musí být normalizovaný na UTC (`AT TIME ZONE … AT TIME ZONE 'UTC'`), jinak reálný běh skončí `THROW 50200`.

### 1.7 Vrstvení systému

Systém je vrstvený od datového jádra v SQL přes provozní add-ony až po webovou Admin Console:

1. **Jádro objektů (`arch.*` v řídicí DB)** — tabulky konfigurace (`Process`, `ProcessDatabase`, `ObjectSpec`, `ObjectSpecDatabaseOverride`, `ProcessKeySpec`, `IndexRequirement`, `RunProfile`, číselník `SelectionStrategy`), runtime stav (`WorkBatch`, `WorkBatchKey`), audit (`Run`, `RunItem`, `RunItemObject`, `RunDocAudit`, `ConfigChangeSet`/`ConfigChangeField`/`ConfigChangeItem`, `ArchiveProvisionLog`, `RestoreAudit`, `RowCountSnapshot`), efektivní views a univerzální runner procedury. Definováno postupně skripty `001`, `010` a dalšími v `kArchiveManagerAdmin/v2/`.
2. **Add-ony / zpevnění (číslované skripty `kArchiveManagerAdmin/v2/0xx`)** — provozní a bezpečnostní vrstvy přidávané inkrementálně, mj.: monitoring views (`023`), provozní údržba a recovery zaseknutých běhů (`024`, `030`, `036`), blokace v1 procedur (`025`), TIMESTAMP runner (`027`), TZ konverze a gate (`031`/`034`/`035`), storno běhu (`040`), restore z archivu (`042`), liveness tracking (`044`), neměnnost auditu (`045`), validátor SQL výrazů (`046`), záloha archivu (`048`), go-live readiness (`049`), retenční mezery (`050`), runtime least-privilege role (`055`), retenční floor + legal-hold (`056`), copy-only Mode=2 (`057`). Tyto skripty jsou idempotentní (vzorce `IF … IS NULL`, `CREATE OR ALTER`, `MERGE`) a lze je opakovaně přehrát.
3. **Admin Console (React SPA + .NET API)** — tenká vrstva nad řídicí DB. **Veškerý zápis jde přes uložené procedury** `arch.usp_Api_*` (zápis) a čtení přes `arch.usp_Frontend_*`; API nesestavuje žádné ad hoc DML nad konfigurací. Aplikační pool drží jen role `karch_*` (žádné DB-wide `EXECUTE` ani `db_datawriter`).

> **Pravidlo č. 1 pro produkci:** pro veškerý produkční provoz se používá **výhradně** `usp_RunProfile_Prepared` (případně `usp_RunConfiguredProcesses_Prepared` pro ad hoc). Reálný mazací běh nikdy bez předchozího dry-runu, validace konfigurace/indexů a revize plánu (`usp_ExplainProcessPlan`).


---


## 2. Selekční strategie a mechanika runneru

kArchiveManager 2.0 podporuje dvě selekční strategie, určené sloupcem `SelectionStrategy` v efektivní konfiguraci (`arch.v_ProcessDatabaseEffective`, default `N'ANCHOR'` přes `COALESCE`):

| Strategie | Určeno pro | Mechanika výběru | Vstupní procedura runneru |
|-----------|-----------|------------------|---------------------------|
| `ANCHOR` | dokladové (multi-objektové) procesy | dvoufázová: materializace kandidátních klíčů do persistentního `WorkBatch` (014), pak claim+zpracování po dávkách (015) | `usp_PrepareCandidates` → `usp_RunPreparedBatch` |
| `TIMESTAMP` | logové tabulky (velkoobjemové, jednoklíčové) | jednoprůchodová: kandidáti jednou do `#temp`, mazání po dávkách joinem přes klíč (027) | `usp_RunTimestampProcess` |

Obě strategie sdílejí stejný metadatový model (`arch.v_ProcessDatabaseEffective`, `arch.v_ObjectSpecDatabaseEffective`, `arch.ProcessKeySpec`), stejný provisioning archivu (`usp_EnsureArchiveTableLikeSource` přes `usp_GetOutputColumns`), stejné brány (`usp_AssertTimezonePolicyApplied` — THROW 50200, `usp_AssertRetentionFloor` — THROW 50210, legal-hold přes `arch.LegalHold`) a stejné `Mode` (0 = delete-only, 1 = archive+delete, 2 = copy-only). Liší se v tom, **kde žije seznam kandidátů** (persistentní `WorkBatch`/`WorkBatchKey` vs. dočasná `#Candidates`) a tím i v idempotenci, obnovitelnosti a tlaku na transakční log.

### 2.1 ANCHOR — `usp_PrepareCandidates` (014): budování WorkBatch

Procedura `arch.usp_PrepareCandidates` (`v2/014_usp_PrepareCandidates.sql`) je první fáze. Materializuje seznam dokladových klíčů do trvalých tabulek `arch.WorkBatch` (hlavička) a `arch.WorkBatchKey` (řádky-klíče) a vrací `@WorkBatchId bigint OUTPUT`.

#### Signatura

```sql
EXEC arch.usp_PrepareCandidates
     @ProcessCode  = N'SHIPPING',
     @SourceDb     = N'KMWEBV',
     @ArchiveDb    = N'KMWEBV_Archiv',
     @FromUtc      = NULL,        -- default '19000101'
     @ToUtc        = NULL,        -- default = cutoff (viz níže)
     @MaxCandidates = NULL,       -- default = BatchDocCount * MaxBatchesPerRun
     @WorkBatchId  = @wb OUTPUT;
```

#### Validační brány (pořadí provádění)

1. **Metadata 2.0**: pokud `OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL` → RAISERROR „2.0 metadata is not installed".
2. **Načtení efektivní konfigurace** z `arch.v_ProcessDatabaseEffective` filtrem `ProcessCode + SourceDb + ArchiveDb + IsEnabled = 1`. Pokud `@ProcessId IS NULL` → RAISERROR „Process not found or disabled".
3. **Povolené strategie**: `@SelectionStrategy NOT IN (N'ANCHOR', N'TIMESTAMP')` → RAISERROR (014 implementuje obě, ale viz bod 4).
4. **TIMESTAMP/BATCH výjimka**: `@SelectionStrategy = N'TIMESTAMP' AND @AuditLevel = N'BATCH'` → RAISERROR — taková kombinace běží přes `usp_RunProcess_TimestampKeyset` a nepřipravuje detailní `WorkBatchKey`. (Tj. 014 připravuje TIMESTAMP klíče jen pro `AuditLevel = N'ROW'`.)
5. **Úplnost ANCHOR konfigurace**: `@AnchorSchema`, `@AnchorTable`, `@AnchorTimestampExpr` musí být všechny vyplněné, jinak RAISERROR „ANCHOR process has incomplete anchor configuration".
6. **Úplnost TIMESTAMP konfigurace** (jen pro TIMESTAMP): vybere TOP(1) `ObjectSpec` z `arch.v_ObjectSpecDatabaseEffective` (`ORDER BY DeleteOrder, ObjectSpecId`) a vyžaduje `SourceSchema`, `SourceTable`, `TimestampExpr`.
7. **Existence DB**: `DB_ID(@SourceDb)`/`DB_ID(@ArchiveDb)` nesmí být NULL.

#### Výpočet limitů a cutoffu

```text
@BatchDocCount  = COALESCE(@BatchDocCount, 25)
@BatchRowCount  = COALESCE(@BatchRowCount, @BatchDocCount)
@MaxBatches     = COALESCE(@MaxBatchesPerRun, 50)
@MaxCandidates  = COALESCE(@MaxCandidates,
                    TIMESTAMP ? @BatchRowCount * @MaxBatches
                             : @BatchDocCount * @MaxBatches)   -- TOP (@MaxCandidates)
@LagMin         = COALESCE(@CutoffSafetyLagMinutes, 0)
@FromUtc        = COALESCE(@FromUtc, '19000101')
```

Horní mez `@ToUtc` (= cutoff) se odvodí pokud nebyla předána:
- `CutoffMode = 1 AND CutoffDate IS NOT NULL` → `@ToUtc = @CutoffDate` (fixní datum);
- jinak rolling: `@ToUtc = DATEADD(MINUTE, -@LagMin, DATEADD(DAY, -RetentionDays, SYSUTCDATETIME()))`.

Validace: `@ToUtc <= @FromUtc` → RAISERROR „Invalid candidate range". `@MaxCandidates <= 0` → RAISERROR.

#### Retention floor (T-21) na PREPARE

Před vlastním buildováním se volá (OBJECT_ID-guarded):

```sql
IF OBJECT_ID(N'arch.usp_AssertRetentionFloor', N'P') IS NOT NULL
    EXEC arch.usp_AssertRetentionFloor @ProcessId=@ProcessId, @SourceDb=@SourceDb,
         @ArchiveDb=@ArchiveDb, @CutoffUtc=@ToUtc;   -- THROW 50210 při porušení
```

Cíl: cutoff uvnitř policy-floor je odmítnut **už při přípravě**, takže ANCHOR nikdy nepostaví `WorkBatch`, který by 015 jen odmítl (to by zaseklo re-prepare).

#### Jediný otevřený WorkBatch (concurrency gate)

```sql
SELECT TOP(1) @OpenBatchId = wb.WorkBatchId
FROM arch.WorkBatch wb
WHERE wb.ProcessId=@ProcessId AND wb.SourceDb=@SourceDb AND wb.ArchiveDb=@ArchiveDb
  AND wb.Status IN ('Prepared','Running','Paused')
ORDER BY wb.WorkBatchId;
IF @OpenBatchId IS NOT NULL → RAISERROR (blokuje druhý prepare)
```

Pro daný (proces, zdroj, archiv) smí existovat **maximálně jeden** otevřený `WorkBatch`. Nový se připraví až po dokončení/zrušení předchozího.

#### Konstrukce klíčů z ProcessKeySpec

Klíče se čtou z `arch.ProcessKeySpec` (sloupce `KeyOrdinal`, `SourceExpressionSql`). Vyžaduje se aspoň `KeyOrdinal = 1`; jinak RAISERROR „ANCHOR process requires at least ProcessKeySpec KeyOrdinal=1." Procedura podporuje **až 8 klíčů** (`WHILE @i <= 8`) a dynamicky skládá fragmenty:

- `@SelectKeys`: `Key{i} = CONVERT(nvarchar(256), <SourceExpressionSql>)` (chybějící ordinál → prázdný řetězec `N''`);
- `@PartitionKeys` / `@OrderKeys`: `Key1..Key8` pro dedupe;
- `@HashInput`: `ISNULL(Key{i}, N'')` spojené `N'|'` pro hash.

Pořadí: pokud je `@CandidateOrderSql` vyplněn, použije se přímo jako `@OrderKeys`; jinak `N'DocCreatedAt, ' + Key1..Key8`.

`@Key1Expr` (= `SourceExpressionSql` pro `KeyOrdinal=1`) se používá ve WHERE jako filtr „klíč není NULL ani prázdný".

#### Dočasná tabulka #Candidates

```sql
CREATE TABLE #Candidates (
    Key1..Key8 nvarchar(256) NOT NULL,
    DocCreatedAt datetime2(0) NULL,
    CandidateHash varbinary(32) NULL   -- SHA2_256 přes spojené klíče
);
```

#### AppLock serializace přípravy

Pokud `@UseAppLock = 1`, vezme se relační zámek (Session-scoped):

```sql
EXEC @lres = sys.sp_getapplock
     @Resource = @AppLockResource,   -- viz níže
     @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = @LockTimeoutMs;
IF @lres < 0 → RAISERROR „failed to acquire applock"
```

`@AppLockResource = COALESCE(NULLIF(AppLockResource, N''), N'KARCHIVE_MANAGER:' + ProcessCode + N':' + @SourceDb)`. `@LockTimeoutMs = COALESCE(LockTimeoutMs, 10000)`. Zámek se uvolní (`sp_releaseapplock`) na všech výstupních cestách (i v `BEGIN CATCH` přes `@AppLockTaken`).

#### Dynamický SELECT kandidátů (dedupe ROW_NUMBER)

Sestavený `@sql` (provedený přes `sys.sp_executesql`) má tvar:

```sql
;WITH raw AS (
    SELECT Key1 = CONVERT(...), ..., DocCreatedAt = CONVERT(datetime2(0), <TimestampExpr>)
    FROM [<SourceDb>].[<SourceSchema>].[<SourceTable>] a WITH (READPAST)   -- ANCHOR alias 'a', TIMESTAMP 't'
    WHERE <TimestampExpr> >= @FromUtc
      AND <TimestampExpr> <  @ToUtc
      AND CONVERT(nvarchar(256), <Key1Expr>) IS NOT NULL
      AND LTRIM(RTRIM(CONVERT(nvarchar(256), <Key1Expr>))) <> N''
      [AND (<AnchorExtraWhereSql | CandidateAdditionalWhereSql>)]
      [AND (<CandidateWhereSql>)]
),
dedupe AS (
    SELECT raw.*, rn = ROW_NUMBER() OVER (PARTITION BY Key1..Key8 ORDER BY <OrderKeys>)
    FROM raw
)
INSERT INTO #Candidates(Key1..Key8, DocCreatedAt, CandidateHash)
SELECT TOP (@TopN) Key1..Key8, DocCreatedAt,
       HASHBYTES('SHA2_256', CONVERT(varbinary(max), CONCAT(<HashInput>)))
FROM dedupe WHERE rn = 1
ORDER BY <OrderKeys>;
```

Klíčové vlastnosti:
- **`WITH (READPAST)`** na zdrojové tabulce — kandidátní sken přeskakuje řádky zamčené živým provozem, neblokuje WMS.
- **Dedupe `ROW_NUMBER()`** přes `PARTITION BY Key1..Key8`, ponecháno `rn = 1` — jeden řádek na unikátní dokladový klíč (zdrojová tabulka může mít více řádků se stejným dokladovým klíčem).
- **`CandidateHash`** = `HASHBYTES('SHA2_256', ...)` přes všechny klíče — slouží jako tie-breaker při claim/done joinu v 015.
- **`@CutoffUtc` alias `@ToUtc`**: predikát `@CutoffUtc datetime2(0)` je předán do `sp_executesql` se stejnou hodnotou jako `@ToUtc`. Operátor tak může do `CandidateWhereSql`/`AdditionalWhereSql` přidat **SARGABLE pre-filtr** na surový indexovaný sloupec (např. `N'[DATE_TIME] < DATEADD(HOUR, 26, @CutoffUtc)'`) → kandidátní sken se změní na index seek. Příliš těsná mez jen pod-zahrne (oddálí archivaci), nikdy nesmaže špatné řádky, protože přesný predikát `<TimestampExpr> < cutoff` stále refinuje.

#### Legal-hold filtr (T-21) na PREPARE

Po naplnění `#Candidates` se (OBJECT_ID-guarded) odeberou klíče pod aktivním holdem:

```sql
IF OBJECT_ID(N'arch.LegalHold', N'U') IS NOT NULL
    DELETE c FROM #Candidates c
    WHERE EXISTS (SELECT 1 FROM arch.LegalHold lh
                  WHERE lh.ReleasedAtUtc IS NULL AND lh.ProcessCode = @ProcessCode
                    AND (lh.SourceDb IS NULL OR lh.SourceDb = @SourceDb)
                    AND lh.HoldKey = c.Key1 COLLATE DATABASE_DEFAULT);
```

Klíč pod aktivním holdem (`ReleasedAtUtc IS NULL`) tak nikdy nevstoupí do `WorkBatch` → nikdy nebude archivován+smazán.

#### Zápis do WorkBatch / WorkBatchKey (transakce)

Pokud `#Candidates` je prázdné, procedura uvolní applock a vrátí se (žádný `WorkBatch` se nevytvoří). Jinak v `BEGIN TRAN`:

```sql
INSERT INTO arch.WorkBatch
    (ProcessId, SourceDb, ArchiveDb, RangeFromUtc, RangeToUtc, ModeSnapshot, Status, PreparedAtUtc)
VALUES (@ProcessId, @SourceDb, @ArchiveDb, @FromUtc, @ToUtc, @Mode, 'Prepared', SYSUTCDATETIME());
SET @WorkBatchId = SCOPE_IDENTITY();

INSERT INTO arch.WorkBatchKey
    (WorkBatchId, Key1..Key8, DocCreatedAt, CandidateHash)
SELECT @WorkBatchId, Key1..Key8, DocCreatedAt, CandidateHash
FROM #Candidates
ORDER BY DocCreatedAt, Key1..Key8;
COMMIT;
```

`ModeSnapshot` zmrazí `Mode` v okamžiku přípravy (runner 015 jej čte z `WorkBatch.ModeSnapshot`, ne z aktuální konfigurace). `RangeToUtc` zmrazí cutoff (015 ho používá pro retention-floor obranu).

#### Lifecycle a statusy WorkBatch / WorkBatchKey

`arch.WorkBatch.Status` (textový):

| Status | Význam |
|--------|--------|
| `Prepared` | připraven 014, nezačal běžet |
| `Running` | 015 nastartoval (`StartedAtUtc` stamp) |
| `Paused` | běh skončil s nedodělanými klíči (`Status IN (0,1)`), DryRun, nebo CATCH |
| `Completed` | žádný klíč nezůstal ve stavu (0,1) → `CompletedAtUtc` |

`arch.WorkBatchKey.Status` (číselný — stavový automat klíče):

| Status | Význam |
|--------|--------|
| `0` | nezpracovaný (claimable) |
| `1` | claimnutý (`ClaimedAtUtc`, `ClaimedBy`) |
| `2` | hotovo (`DoneAtUtc`) |
| `3` | trvalá chyba (ne-retryable) |
| `5` | legal-hold park (T-21) — neclaimovatelný, nemaže se, nikdy se neresetuje na Done |

#### CATCH chování v 014

`XACT_STATE() <> 0` → ROLLBACK; uvolnění applocku; RAISERROR „arch.usp_PrepareCandidates failed: %s".

### 2.2 ANCHOR — `usp_RunPreparedBatch` (015): claim a zpracování

Procedura `arch.usp_RunPreparedBatch` (`v2/015_usp_RunPreparedBatch.sql`) je druhá fáze — claimuje připravené `WorkBatchKey` po dávkách a provádí archivaci+mazání. Volá se:

```sql
EXEC arch.usp_RunPreparedBatch
     @WorkBatchId = @wb,
     @StopAtUtc   = '2026-06-11T03:00:00',   -- časová mez okna
     @DryRun      = 0;                        -- 1 = pouze preview
```

#### Načtení kontextu a brány

Z `arch.WorkBatch` se načte `@ProcessId, @SourceDb, @ArchiveDb, @Mode (=ModeSnapshot), @RangeToUtc`. Pokud `WorkBatchId` neexistuje → RAISERROR. Z `arch.v_ProcessDatabaseEffective` se doplní `@SelectionStrategy, @AuditLevel, @BatchDocCount, @BatchRowCount, @MaxRowsPerTransaction, @LockTimeoutMs, @DeadlockPriority, @DocKeyLabel, @AllowDelNoArch`. Musí existovat aspoň jeden enabled `ObjectSpec`, jinak RAISERROR.

Brány (jen pokud `@DryRun = 0`):
- **`usp_AssertTimezonePolicyApplied`** (P0.5 Risk K1) — THROW 50200, pokud cutoff výraz není UTC-normalizovaný (AT TIME ZONE). DryRun je výjimka.
- **`usp_AssertRetentionFloor`** (T-21, OBJECT_ID-guarded) s `@CutoffUtc = @RangeToUtc` — THROW 50210. Primární vynucení je v 014 při PREPARE; tohle je obrana, kdyby floor byl zvednut po přípravě.

#### Velikost dávky

```sql
@BatchUnitCount = TIMESTAMP ? COALESCE(@BatchRowCount, @BatchDocCount, 10000)
                            : COALESCE(@BatchDocCount, @BatchRowCount, 25)   -- ANCHOR
IF @MaxRowsPerTransaction > 0 AND @MaxRowsPerTransaction < @BatchUnitCount
    SET @BatchUnitCount = @MaxRowsPerTransaction;   -- strop na transakci
IF @BatchUnitCount <= 0 → RAISERROR
```

Pro ANCHOR je tedy primární „velikost dávky" `BatchDocCount` (počet **dokladů**, ne řádků), volitelně oříznutý `MaxRowsPerTransaction`.

#### DeadlockPriority a LockTimeout

```sql
IF @DeadlockPriority = N'LOW'  SET DEADLOCK_PRIORITY LOW;
ELSE IF @DeadlockPriority = N'HIGH' SET DEADLOCK_PRIORITY HIGH;
ELSE SET DEADLOCK_PRIORITY NORMAL;   -- default LOW (přes COALESCE)
EXEC(N'SET LOCK_TIMEOUT ' + @LockTimeoutMs + N';');
```

`DeadlockPriority LOW` (default) znamená, že runner je při deadlocku obětí proti živému WMS provozu.

#### WorkBatch → Running + reset stale claimů

```sql
UPDATE arch.WorkBatch SET Status = CASE WHEN Status IN ('Prepared','Paused') THEN 'Running' ELSE Status END,
    StartedAtUtc = COALESCE(StartedAtUtc, SYSUTCDATETIME()) WHERE WorkBatchId = @WorkBatchId;

-- uvolnění klíčů zaseklých v claimu déle než 2 hodiny
UPDATE arch.WorkBatchKey SET Status = 0, ClaimedAtUtc = NULL, ClaimedBy = NULL
WHERE WorkBatchId = @WorkBatchId AND Status = 1
  AND ClaimedAtUtc < DATEADD(HOUR, -2, SYSUTCDATETIME());
```

#### Audit a Run/RunItem (T-03)

Před hlavní smyčkou se založí `arch.Run` (s `WorkerSessionId = @@SPID` a `WorkerSessionLoginTimeUtc` z `sys.dm_exec_sessions` — pro `usp_RecoverStaleRuns`, aby nikdy nereparoval běžící relaci) a `arch.RunItem` (`CutoffUtc = @RangeToUtc`).

#### Hlavní smyčka — atomický claim → delete → done (T-17)

Smyčka běží `WHILE SYSUTCDATETIME() < @StopAtUtc`. Na začátku každé iterace:

1. **Kooperativní cancel (040)**: `IF EXISTS (... arch.Run ... CancelRequestedAtUtc IS NOT NULL) BREAK;` — předchozí dávka je commitnutá, zbývající klíče zůstávají claimable, `WorkBatch` skončí jako `Paused`, Run jako `STOPPED`.

2. **Claim dávky** (atomicky přes UPDATE + OUTPUT):

```sql
;WITH cte AS (
    SELECT TOP (@BatchUnitCount) *
    FROM arch.WorkBatchKey WITH (UPDLOCK, READPAST, ROWLOCK)
    WHERE WorkBatchId = @WorkBatchId AND Status = 0
    ORDER BY DocCreatedAt, Key1..Key8
)
UPDATE cte SET Status = 1, Attempts = Attempts + 1, ClaimedAtUtc = SYSUTCDATETIME(),
    ClaimedBy = SUSER_SNAME(), ErrorMessage = NULL
OUTPUT inserted.Key1..Key8, inserted.AnchorRowGuid, inserted.DocCreatedAt, inserted.CandidateHash
INTO #Claimed (...);
IF NOT EXISTS (SELECT 1 FROM #Claimed) BREAK;
```

`WITH (UPDLOCK, READPAST, ROWLOCK)` je jádro souběžnosti: více workerů může claimovat z téhož `WorkBatch` — `READPAST` přeskočí cizí zamčené (právě claimnuté) řádky, `UPDLOCK` zabrání dvojímu claimu.

3. **DryRun větev** (`@DryRun = 1`): vyselektuje TOP(100) náhled, claim **vrátí** zpět (`Status = 0`), zapíše `Status = N'DRYRUN'` do Run/RunItem, `WorkBatch → Paused` s `Notes = N'DryRun preview only'`, a `RETURN`.

4. **#Keys s kolací zdroje (T-22)**: vytvoří se `#Keys` (mj. `DocKey`, `DocKey2`, `Key1..Key8`, `AnchorRowGuid`, `CandidateHash`). Pokud `DATABASEPROPERTYEX(@SourceDb, 'Collation')` není NULL, sloupce se překolatují na kolaci zdroje (`ALTER TABLE #Keys ALTER COLUMN ... COLLATE <SourceCollation>`) — jinak cross-DB join na zdrojový klíč hází Msg 468 collation conflict. Naplní se z `#Claimed` (`DocKey = Key1`, `DocKey2 = Key2`).

5. **Legal-hold obrana (T-21)**, pokud byl hold přidán po PREPARE: claimnuté klíče pod aktivním holdem se **parkují** (`WorkBatchKey Status = 5`, `ErrorMessage = N'LEGAL HOLD: excluded from deletion ...'`) a vyřadí z `#Keys` i `#Claimed` — nesmažou se, neoznačí jako done, nereclaimují. Vrátí se jako čerstvý kandidát při příštím prepare po uvolnění holdu.

6. **`BEGIN TRAN`** — cyklus přes `ObjectSpec` (kurzor `ORDER BY DeleteOrder`):
   - validace: `DeleteMode <> 1` → RAISERROR; chybějící `JoinToAnchorPredicateSql` → RAISERROR; `Mode = 0 AND RequireArchiveForDelete = 1 AND @AllowDelNoArch = 0` → RAISERROR „Delete-only blocked".
   - `Mode IN (1,2)` → provisioning archivu `usp_EnsureArchiveTableLikeSource` (`@MakeAllNullable = 1, @IncludeComputed = 0`).
   - sloupce přes `usp_GetOutputColumns` (`@delCols` = `DELETED.…`, `@tgtCols` = cílové sloupce, `@srcCols` = `t.[col]`).
   - `Mode = 2` → `usp_GetCopyDedupInfo` (`@pkPred = 'a.[pk]=t.[pk]...'`, `@EnsureIndex = 1`).
   - sestavení a `EXEC(@stmt)`:

| Mode | Příkaz | Mazání zdroje? | Archiv? |
|------|--------|----------------|---------|
| 1 | `DELETE t OUTPUT DELETED.* INTO <archiv> ... FROM <zdroj> t INNER JOIN #Keys k ON <join>` | ano | ano (atomicky) |
| 2 | `INSERT INTO <archiv> SELECT <srcCols> FROM <zdroj> t INNER JOIN #Keys k ON <join> WHERE NOT EXISTS (... a WHERE <pkPred>)` | **ne** (copy-only) | ano (dedup dle PK) |
| 0 | `DELETE t FROM <zdroj> t INNER JOIN #Keys k ON <join>` | ano | ne |

   Pro Mode=2 bez PK predikátu → `THROW 50223`. Po každém objektu `@rc = @@ROWCOUNT` a zápis do `arch.RunItemObject` (Mode=2: deleted=0/archived=@rc; Mode=1: oba=@rc; Mode=0: deleted=@rc/archived=0).

7. **Invariant Mode=1** (před COMMIT): pokud existuje `RunItemObject` s `RowsDeleted > 0 AND RowsArchived <> RowsDeleted` → RAISERROR „Archive/Delete mismatch (Mode=1)" → rollback.

8. **Row-audit** (`@AuditLevel = N'ROW'`): insert do `arch.RunDocAudit` (`DocKey = DocKey` nebo `DocKey + '|' + DocKey2`, `Archived = Mode IN (1,2) ? 1 : 0`).

9. **Mark done (T-17 — uvnitř TÉŽE transakce)**:

```sql
UPDATE k SET Status = 2, DoneAtUtc = SYSUTCDATETIME()
FROM arch.WorkBatchKey k
JOIN #Claimed c ON c.Key1=k.Key1 AND c.Key2=k.Key2 AND ISNULL(c.CandidateHash,0x)=ISNULL(k.CandidateHash,0x)
WHERE k.WorkBatchId=@WorkBatchId AND k.Status = 1;   -- jen stále-claimnuté; nikdy Done(2)/park(5)
```

Toto je jádro crash-konzistence T-17: flip na `Status = 2` (Done) běží **uvnitř stejné transakce** jako delete/archive. Dřív (pre-T-17) běžel po COMMITu → crash v tom okně nechal klíče claimnuté (Status=1), zatímco řádky už byly smazané+archivované → stale-reclaim → re-processing (duplicitní `RunDocAudit`, nafouklý `DocsDone`). Idempotence se nyní odvozuje z perzistentního `Status` klíče, ne z existence zdrojového řádku. Join přes `Key1, Key2, ISNULL(CandidateHash, 0x)`, scope `Status = 1` (klíč v holdu/park 5 nebo Done 2 se nikdy nevzkřísí). Pak `UPDATE arch.WorkBatch SET LastProgressAtUtc, LastKey1, LastKey2` a `COMMIT`. `DROP TABLE #Keys`.

#### Finalizace běhu

Po smyčce:
```text
@FinalStatus = (Run.CancelRequestedAtUtc IS NOT NULL) ? N'STOPPED' : N'OK'
UPDATE RunItem/Run SET Status = @FinalStatus, EndedAt = SYSUTCDATETIME();
IF NOT EXISTS (WorkBatchKey ... Status IN (0,1)) → WorkBatch 'Completed' (CompletedAtUtc)
ELSE → WorkBatch 'Paused' (LastProgressAtUtc)
```

#### CATCH chování v 015 (retry-klasifikace)

```sql
@retryable = (ERROR_NUMBER() IN (1205,1222) OR ERROR_MESSAGE() LIKE N'%collation conflict%') ? 1 : 0
UPDATE k SET Status = (@retryable=1 ? 0 : 3),   -- deadlock/lock-timeout/kolize → znovu claimable; jinak trvalá chyba
    ClaimedAtUtc/ClaimedBy = (@retryable=1 ? NULL : beze změny), ErrorMessage = LEFT(@errmsg,4000)
FROM arch.WorkBatchKey k JOIN #Claimed c ... WHERE k.WorkBatchId=@WorkBatchId AND k.Status = 1;
WorkBatch → 'Paused' (Notes = chyba); RunItem/Run → 'FAILED'; RAISERROR.
```

`1205` = deadlock victim, `1222` = lock request timeout → klíče se vrátí na `Status = 0` (retry). Ostatní chyby → `Status = 3` (trvalá). Scope `Status = 1` opět chrání Done/park klíče.

### 2.3 ANCHOR — orchestrace okna: 016 a 020

#### `usp_RunPreparedBatches_InWindow` (016)

Pohání 015 v daném časovém okně. Načte `@MaxBatches = COALESCE(MaxBatchesPerRun, 100000)`, `@DelayMs = COALESCE(DelayMsBetweenBatches, 0)`, `@UseAppLock`, `@AppLockResource`, `@LockTimeoutMs`. Pokud `@UseAppLock = 1`, drží `sp_getapplock` přes celé okno. Smyčka `WHILE SYSUTCDATETIME() < @StopAtUtc AND @i < @MaxBatches`:

1. vybere další `WorkBatch` (`Status IN ('Prepared','Paused')`), preferuje `Prepared` (`sort1 = 0`), pak nejstarší `PreparedAtUtc`; `Paused` jen pokud `LastProgressAtUtc IS NULL` nebo starší než `@PausedCooldownSeconds` (default 60) — cooldown brání horké smyčce na zaseklém batchi;
2. `EXEC arch.usp_RunPreparedBatch @WorkBatchId=@wb, @StopAtUtc, @DryRun`;
3. `WAITFOR DELAY @DelayStr` (z `@DelayMs` převedeného na `hh:mm:ss.fff`) — throttle mezi dávkami pro odlehčení I/O.

`@DelayMsBetweenBatches` je tedy realizován **mezi voláními 015** (na úrovni 016), zatímco TIMESTAMP runner 027 ho aplikuje mezi vlastními dávkami uvnitř.

#### `usp_RunConfiguredProcesses_Prepared` (016)

Kurzorem prochází enabled procesy z `v_ProcessDatabaseEffective` (`ORDER BY RunOrder, ...`). **Routing podle strategie**:
- `TIMESTAMP` → přímo `EXEC arch.usp_RunTimestampProcess` (vyžaduje, aby procedura existovala, jinak RAISERROR); ANCHOR větev se přeskočí (`CONTINUE`).
- `ANCHOR` → pokud není otevřený `WorkBatch` (`Status IN ('Prepared','Running','Paused')`), zavolá `usp_PrepareCandidates`, pak `usp_RunPreparedBatches_InWindow`.

Tj. jediný „configured run" připraví i zpracuje ANCHOR procesy a samostatně vyřídí TIMESTAMP procesy.

#### `usp_RunProfile_Prepared` (020)

Vstupní bod profilu (`v2/020_usp_RunProfile_Prepared.sql`, validovaná P1.3 verze). Čte `arch.RunProfile` (`RunProfileCode`, `IsEnabled = 1`) a fail-fast THROW:
- `50001` — `arch.RunProfile` / `usp_RunConfiguredProcesses_Prepared` chybí;
- `50002` — profil nenalezen nebo disabled (`@RunWindowMinutes IS NULL`);
- `50003` — neplatné limity (`@RunWindowMinutes <= 0`, `@PausedCooldownSeconds < 0`, `@MaxCandidates <= 0`).

Spočte `@StopAtUtc = DATEADD(MINUTE, @RunWindowMinutes, SYSUTCDATETIME())` a předá filtry (`ProcessCodeFilter/SourceDbFilter/ArchiveDbFilter`, prázdné → NULL) do `usp_RunConfiguredProcesses_Prepared`. Doprovodná `usp_RunScheduledProfiles_Prepared` iteruje profily s `RunOnSchedule = 1` (`ORDER BY RunOrder`) a volá `usp_RunProfile_Prepared` pro každý.

### 2.4 TIMESTAMP — `usp_RunTimestampProcess` (027): jednoprůchodový keyset

Procedura `arch.usp_RunTimestampProcess` (`v2/027_usp_RunTimestampProcess.sql`) je celý runner pro logové tabulky — bez persistentního `WorkBatch`. Kandidáty vybere **jednou** do dočasné `#Candidates` a maže je po dávkách joinem přes klíč.

```sql
EXEC arch.usp_RunTimestampProcess
     @ProcessCode = N'RF_LOG2', @SourceDb = N'KMWEBV', @ArchiveDb = N'KMWEBV_Archiv',
     @AsOfUtc = NULL,          -- default SYSUTCDATETIME()
     @StopAtUtc = NULL, @BatchRowCount = NULL, @MaxRows = NULL, @DryRun = 0;
```

#### Validace (THROW kódy)

`SET ANSI_WARNINGS ON` (T-04 — truncation/overflow při `DELETE ... OUTPUT INTO` vyhodí tvrdou chybu místo tichého uložení zkomoleného archivu). THROW: `50100/50101/50102` (povinné parametry), `50103/50104` (DB neexistuje), `50105` (proces nenalezen), `50106` (strategie není TIMESTAMP), `50107` (chybí `ProcessKeySpec`), `50200` (timezone policy přes `usp_AssertTimezonePolicyApplied`, DryRun exempt), `50108` (`BatchRowCount <= 0`), `50109` (`MaxRows <= 0`), `50210` (retention floor přes `usp_AssertRetentionFloor`, DryRun exempt, OBJECT_ID-guarded), `50110` (žádný ObjectSpec), `50111` (každý ObjectSpec musí mít `DeleteMode=1`, `TimestampExpr`, `JoinToAnchorPredicateSql`), `50112` (delete-only blokován při `RequireArchiveForDelete=1`), `50113` (chybí `ProcessKeySpec KeyOrdinal=1`).

#### Limity a cutoff

```text
@BatchRowCount = COALESCE(@BatchRowCount, ConfiguredBatchRowCount, 50000)   -- velikost dávky = ŘÁDKY
@MaxBatches    = COALESCE(MaxBatchesPerRun, 100)
@DelayMs       = COALESCE(DelayMsBetweenBatches, 0)
@LagMin        = COALESCE(CutoffSafetyLagMinutes, 0)
@MaxRows (pokud NULL) = @BatchRowCount * MIN(@MaxBatches, 100)   -- ořez na 2147483647
@CutoffUtc = (CutoffMode=1 AND CutoffDate IS NOT NULL) ? CutoffDate
                                                       : DATEADD(MINUTE, -@LagMin, DATEADD(DAY, -RetentionDays, @AsOfUtc))
```

Pro TIMESTAMP je primární velikost dávky `BatchRowCount` (počet **řádků**, default 50000), kontrastně k ANCHOR `BatchDocCount` (default 25 dokladů).

#### Provisioning archivu a sloupců (pre-cache do #Obj)

ObjectSpecy se načtou do `#Obj`. Kurzorem `cPrep` se pro `Mode IN (1,2)` provisionuje archiv (`usp_EnsureArchiveTableLikeSource`) a předpočítají sloupce (`usp_GetOutputColumns` → `DelCols/TgtCols/SrcCols`) a pro Mode=2 dedup (`usp_GetCopyDedupInfo` → `PkPredicate`). Tyto se uloží do `#Obj` jednou — **mimo** smyčku dávek.

#### AppLock, DeadlockPriority, LockTimeout

`COALESCE(@UseAppLock, 1) = 1` → `sp_getapplock` Exclusive/Session (THROW 50114 při selhání). `SET DEADLOCK_PRIORITY` dle `@DeadlockPriority`. `SET LOCK_TIMEOUT @LockTimeoutMs`. AppLock se uvolní (THROW 50115 při selhání release) na všech cestách včetně DryRun a CATCH.

#### Načtení kandidátů (jednou) s kolací zdroje (T-22)

```sql
CREATE TABLE #Candidates (CandId bigint IDENTITY PRIMARY KEY, Key1 nvarchar(256) NOT NULL, DocCreatedAt datetime2(0) NULL);
IF @SourceCollation IS NOT NULL → ALTER COLUMN Key1 COLLATE <SourceCollation>;
CREATE UNIQUE INDEX UX_Candidates_Key1 ON #Candidates(Key1);

;WITH raw AS (
    SELECT Key1 = CONVERT(nvarchar(256), <KeyExpr>), DocCreatedAt = CONVERT(datetime2(0), <TimestampExpr>)
    FROM [<SourceDb>].[<CandidateSchema>].[<CandidateTable>] t WITH (READPAST)
    WHERE <TimestampExpr> < @CutoffUtc
      AND CONVERT(nvarchar(256), <KeyExpr>) IS NOT NULL
      AND LTRIM(RTRIM(...)) <> N''
      [AND (<CandidateAdditionalWhereSql>)] [AND (<CandidateWhereSql>)]
),
dedupe AS (SELECT raw.*, rn = ROW_NUMBER() OVER (PARTITION BY raw.Key1 ORDER BY raw.DocCreatedAt, raw.Key1) FROM raw)
INSERT INTO #Candidates(Key1, DocCreatedAt)
SELECT TOP (@MaxRows) Key1, DocCreatedAt FROM dedupe WHERE rn = 1
ORDER BY <OrderSql>   -- COALESCE(CandidateOrderSql, 'DocCreatedAt, Key1')
OPTION (RECOMPILE);
```

Rozdíly proti ANCHOR výběru:
- výběr je **jednoklíčový** (`PARTITION BY raw.Key1`), `KeyExpr` = `ProcessKeySpec KeyOrdinal=1`;
- horní mez je `< @CutoffUtc` (přesný predikát), `@CutoffUtc` je in-scope parametr `sp_executesql` (stejná SARGABLE-cutoff technika jako v 014);
- `WITH (READPAST)` neblokuje živý zápis do logu;
- `OPTION (RECOMPILE)` — plán šitý na konkrétní cutoff/MaxRows;
- po naplnění `CREATE NONCLUSTERED INDEX IX_Candidates_DocCreatedAt ON #Candidates(DocCreatedAt, Key1)` pro rychlé řezání dávek.

#### Legal-hold filtr (T-21) a DryRun

Po načtení (OBJECT_ID-guarded) `DELETE c FROM #Candidates c WHERE EXISTS (... arch.LegalHold ...)` — held klíče se neobjeví ani v dry-run preview. `@DryRun = 1` → vrátí souhrn (`CandidateRows`, `MinCandidateUtc`, `MaxCandidateUtc`) + TOP(100) náhled, zapíše `Status = N'DRYRUN'`, uvolní applock a `RETURN` (nic nemaže).

#### Smyčka dávek (mazání joinem přes klíč)

```sql
CREATE TABLE #Batch (BatchId bigint IDENTITY PK, Key1 nvarchar(256) NOT NULL, DocCreatedAt datetime2(0) NULL);
IF @SourceCollation IS NOT NULL → ALTER COLUMN Key1 COLLATE <SourceCollation>;   -- T-22 (join na zdroj)
CREATE UNIQUE INDEX UX_Batch_Key1 ON #Batch(Key1);

WHILE EXISTS (SELECT 1 FROM #Candidates)
BEGIN
    IF @StopAtUtc IS NOT NULL AND SYSUTCDATETIME() >= @StopAtUtc BREAK;
    IF EXISTS (... arch.Run ... CancelRequestedAtUtc IS NOT NULL) BREAK;   -- cancel (040)
    DELETE FROM #Batch;
    INSERT INTO #Batch SELECT TOP (@BatchRowCount) Key1, DocCreatedAt FROM #Candidates ORDER BY DocCreatedAt, Key1;
    IF NOT EXISTS (...) BREAK;

    BEGIN TRAN;
      -- kurzor cRun přes #Obj (ORDER BY DeleteOrder, RowNo); per objekt:
      --   Mode=1: DELETE t OUTPUT DELETED.* INTO <archiv> ... INNER JOIN #Batch k ON <join> OPTION (RECOMPILE)
      --   Mode=2: INSERT INTO <archiv> SELECT <srcCols> ... INNER JOIN #Batch k ON <join>
      --           WHERE NOT EXISTS (... a WHERE <pkPred>) OPTION (RECOMPILE)   -- THROW 50222 bez PK
      --   Mode=0: DELETE t ... INNER JOIN #Batch k ON <join> OPTION (RECOMPILE)
      -- per objekt: UPSERT do arch.RunItemObject (akumuluje RowsDeleted/RowsArchived)
      IF @AuditLevel = N'ROW' → INSERT arch.RunDocAudit (DocKey = b.Key1, Archived = Mode IN (1,2))
      UPDATE arch.RunItem SET BatchesDone += 1, DocsDone += @DocsBatch, RowsDeleted/RowsArchived += ...;
      DELETE c FROM #Candidates c INNER JOIN #Batch b ON b.Key1 = c.Key1;   -- odebrání zpracovaných z fronty
      IF @Mode = 1 AND EXISTS (RunItemObject del>0 AND arc<>del) → RAISERROR „Archive/Delete mismatch (Mode=1)";  -- T-04
    COMMIT;
    IF @DelayStr IS NOT NULL AND (před @StopAtUtc) → WAITFOR DELAY @DelayStr;   -- throttle UVNITŘ runneru
END;
```

Klíčové: **progres se neukládá persistentně** — fronta žije jen v `#Candidates` po dobu běhu (kandidát se po zpracování smaže `DELETE ... INNER JOIN #Batch`). Crash/restart znamená nové načtení `#Candidates` od cutoffu; idempotenci zajišťuje sám cutoff predikát (`< @CutoffUtc`), protože smazané řádky se příště nevyberou. Mode=2 navíc deduplikuje přes `NOT EXISTS` na archivní PK, takže opakované běhy nezduplikují archiv.

#### Finalizace a CATCH v 027

`@FinalStatus = STOPPED|OK` dle cancelu → `RunItem/Run`. Uvolnění applocku (THROW 50115 při selhání). CATCH: `XACT_STATE() <> 0` → ROLLBACK; `RunItem/Run → FAILED` s `ErrorMessage`; uvolnění applocku; RAISERROR „arch.usp_RunTimestampProcess failed: %s".

### 2.5 Provisioning archivu (like-source)

Společný pro obě strategie, volaný za běhu při `Mode IN (1,2)`.

#### `usp_GetOutputColumns`

Z metadat zdroje (`<SourceDb>.sys.columns/objects/schemas/types`) sestaví tři seznamy:
- `@DeletedSelectList` = `DELETED.[col1], DELETED.[col2], ...` (pro `DELETE ... OUTPUT`);
- `@TargetColumnList` = `[col1], [col2], ...` (cílové sloupce archivu);
- `@SourceSelectList` = `t.[col1], t.[col2], ...` (pro Mode=2 `INSERT ... SELECT`, alias `@SourceAlias`, default `t`).

`@IncludeComputed = 0` vynechá computed sloupce; `@ExcludeRowversion = 1` (restore path) vynechá rowversion/timestamp (nelze ho explicitně INSERTovat). Pokud nejsou žádné sloupce → RAISERROR.

#### `usp_EnsureArchiveTableLikeSource`

Zajistí archivní tabulku „jako zdroj":
1. **Schema**: `@ArchiveSchema` — `NULL`/`dbo` se mapuje na placeholder `{SourceDb}`, ten se nahradí názvem zdroje (archiv je tedy default ve schématu pojmenovaném podle zdrojové DB, ne v `dbo`). Chybějící schéma se vytvoří (`CREATE SCHEMA ... AUTHORIZATION dbo`).
2. **Tabulka chybí** → `CREATE TABLE` se sloupci „like source". Typové mapování: `timestamp`/`rowversion` → `binary(8)`; `varchar/char/varbinary/binary` zachová délku (`max` → `(max)`); `nvarchar/nchar` přepočte `max_length/2`; `decimal/numeric` zachová `(p,s)`; `datetime2/datetimeoffset/time` zachová scale; zachová `COLLATE` u řetězců. `@MakeAllNullable = 1` (default) všechny sloupce NULLABLE (deleted řádek se vždy vejde). Log do `arch.ArchiveProvisionLog` (`Action = N'CREATE_TABLE'`).
3. **Tabulka existuje** → přidá chybějící sloupce (`ALTER TABLE ... ADD ... NULL`, log `ADD_COLUMNS`).
4. **T-19 reconcile drift existujících sloupců**: archiv je jediná kopie smazaných dat, takže rozšířený zdrojový sloupec nesmí tiše truncovat příští `DELETE...OUTPUT INTO`. Stejnotypový růst (delší řetězec, větší decimal precision/scale, hlubší datetime2 scale) → `WIDEN` (auto `ALTER COLUMN`, nikdy nezúží), log `WIDEN_COLUMNS`. Nekompatibilní typová změna → **`THROW 50410`** „Schema drift would corrupt the only copy of deleted data..." (běh se zablokuje do manuálního smíření). Pozn.: source `timestamp/rowversion` se pro drift porovnává jako `binary` (jinak by falešně blokoval proti archivnímu `binary(8)`).

#### `usp_ProvisionArchiveTablesForProcess`

Dávkový provisioning pro celý proces (mimo runtime — operátor předem). Z `v_ProcessDatabaseEffective` ověří `ProcessDatabaseId` (jinak `THROW 50000`), kurzorem přes enabled ObjectSpecy (`ORDER BY DeleteOrder`) volá `usp_EnsureArchiveTableLikeSource` pro každou tabulku se stejným `{SourceDb}` mapováním schématu a `COALESCE(ArchiveTable, SourceTable)`.

### 2.6 Srovnání konfigurace obou strategií

| Aspekt | ANCHOR (014 + 015 + 016) | TIMESTAMP (027) |
|--------|---------------------------|------------------|
| `SelectionStrategy` | `ANCHOR` | `TIMESTAMP` |
| Fronta kandidátů | persistentní `arch.WorkBatch` + `arch.WorkBatchKey` | dočasná `#Candidates` (jen po dobu běhu) |
| Klíče | 1–8 klíčů z `ProcessKeySpec` (`KeyOrdinal 1..8`) | jediný klíč (`KeyOrdinal=1`) |
| Zdroj kandidátů | `AnchorSchema/AnchorTable/AnchorTimestampExpr` | `ObjectSpec.SourceSchema/Table/TimestampExpr` (TOP 1 dle `DeleteOrder`) |
| Velikost dávky | `BatchDocCount` (default 25 **dokladů**), strop `MaxRowsPerTransaction` | `BatchRowCount` (default 50000 **řádků**) |
| `@MaxCandidates`/`@MaxRows` default | `BatchDocCount * MaxBatchesPerRun` (MaxBatches def. 50) | `BatchRowCount * MIN(MaxBatchesPerRun,100)` (MaxBatches def. 100) |
| Claim model | `WorkBatchKey` Status 0→1→2 přes `UPDLOCK, READPAST, ROWLOCK` (více workerů) | bez claimu; `#Candidates` se po dávce maže joinem přes Key1 |
| `DelayMsBetweenBatches` | mezi voláními 015 (v 016 `WAITFOR DELAY`) | uvnitř runneru mezi dávkami (`WAITFOR DELAY`) |
| Idempotence | perzistentní `WorkBatchKey.Status` (T-17, atomický claim→delete→done) | cutoff predikát `< @CutoffUtc` (smazané se nevyberou) + Mode=2 dedup |
| Crash recovery | re-claim nedokončených klíčů (Status 0/1), stale-reclaim po 2 h, `usp_RecoverStaleRuns` | nové načtení `#Candidates` od cutoffu |
| Souběh prepare | jediný otevřený `WorkBatch` na (proces,zdroj,archiv) | applock serializuje celý běh |
| AppLock | volitelný v 014 (prepare) i 016 (window); resource `KARCHIVE_MANAGER:<ProcessCode>:<SourceDb>` | `COALESCE(@UseAppLock,1)=1` (default zapnuto) |
| Audit `BATCH` přes 014 | povoleno | **zakázáno** (RAISERROR — běží přes `usp_RunProcess_TimestampKeyset`) |
| `OPTION (RECOMPILE)` | ne | ano (load i DELETE/INSERT) |
| `READPAST` na zdroji | ano (kandidátní sken) | ano (kandidátní sken) |

Společné pro obě: `Mode` 0/1/2 se stejnou sémantikou; brány `usp_AssertTimezonePolicyApplied` (50200) a `usp_AssertRetentionFloor` (50210, DryRun exempt); legal-hold (`arch.LegalHold`, OBJECT_ID-guarded); `DeadlockPriority` (default `LOW`), `LockTimeout` (default 10000 ms); `SET XACT_ABORT ON`; invariant Mode=1 `RowsArchived == RowsDeleted` před COMMIT (RAISERROR „Archive/Delete mismatch"); kolace zdroje na join sloupcích (T-22); audit `arch.Run`/`arch.RunItem`/`arch.RunItemObject`/`arch.RunDocAudit` (`AuditLevel = N'ROW'`).


---


## 3. Režimy zpracování a invarianty

Procesní režim (sloupec `Mode`) určuje, zda běh data archivuje, maže, nebo jen kopíruje. Doménu `Mode` definuje skript `057_copy_only_mode.sql` jako `{0, 1, 2}` a oba runnery — ANCHOR (`015_usp_RunPreparedBatch.sql`) i TIMESTAMP (`027_usp_RunTimestampProcess.sql`) — větví podle `Mode` v jedné společné kostře (klaim → SQL příkaz → audit → progress → COMMIT). `Mode` je nezávislý na auditní úrovni (`AuditLevel`) a na náhledovém běhu (`@DryRun`), které jsou dokumentovány samostatně (viz `docs/v2-operational-modes.md`).

### 3.1 Přehled režimů

| `Mode` | Název | Zápis do archivu | Mazání zdroje | Generovaný SQL příkaz | `RowsDeleted` | `RowsArchived` |
| --- | --- | --- | --- | --- | --- | --- |
| `1` | archive+delete | Ano | Ano | `DELETE t OUTPUT DELETED.* INTO <archive>` | `@rc` | `@rc` |
| `0` | delete-only | Ne | Ano | `DELETE t` (bez OUTPUT) | `@rc` | `0` |
| `2` | copy-only | Ano | **Ne** | `INSERT INTO <archive> SELECT ... NOT EXISTS` | `0` | `@rc` |

`@rc` je `@@ROWCOUNT` zachycený bezprostředně po `EXEC(@stmt)`. Hodnota `Mode` se v obou runnerech čte z `arch.v_ProcessDatabaseEffective` (sloupec `Mode`); u ANCHOR runneru je navíc uložena do `arch.WorkBatch.ModeSnapshot` v okamžiku PREPARE (`014_usp_PrepareCandidates.sql`), takže běh ctí režim platný v době přípravy, ne v době spuštění.

### 3.2 Doménové omezení `Mode` (CHECK constraint)

Skript `057_copy_only_mode.sql` rozšiřuje doménu `Mode` ze `{0, 1}` na `{0, 1, 2}` na dvou tabulkách:

1. **`arch.Process`** — samostatný constraint `CK_Process_Mode`:

   ```sql
   ALTER TABLE [arch].[Process] WITH CHECK ADD CONSTRAINT [CK_Process_Mode]
       CHECK ([Mode] IN (0, 1, 2));  -- 0 delete-only, 1 archive+delete, 2 copy-only
   ```

2. **`arch.ProcessDatabase`** — klauzule `Mode` je součástí kompozitního constraintu `CK_ProcessDatabase_OverrideLimits`. Skript jej dropuje **přesně podle jména** a znovu vytváří v plném znění; rozšiřuje pouze klauzuli `Mode` (`[Mode] IS NULL OR [Mode] IN (0, 1, 2)`), všechny ostatní validace přepisu (`RetentionDays >= 0`, `CutoffMode IN (0,1)`, `BatchDocCount > 0`, `DeadlockPriority IN ('LOW','NORMAL','HIGH')`, `AuditLevel IN ('NONE','BATCH','OBJECT','ROW')`, `MaxRowsPerTransaction > 0`, …) zůstávají zachovány verbatim.

Obě tabulky jsou aktualizovány jen tehdy, pokud existují (`OBJECT_ID(... , N'U') IS NOT NULL`), takže skript je bezpečně re-deployovatelný.

### 3.3 Mode = 1 (archive+delete) a invariant Divergence = 0

Mode = 1 je primární režim: kandidátské řádky se v **jediné transakci** zkopírují do archivu a současně smažou ze zdroje pomocí atomického `DELETE ... OUTPUT ... INTO`. Tím je archivace-před-smazáním splněna konstrukčně — neexistuje okno, ve kterém by řádek byl smazán bez zápisu do archivu (a naopak).

Generovaný příkaz (TIMESTAMP runner, ANCHOR je analogický s `#Keys` místo `#Batch`):

```sql
DELETE t
OUTPUT DELETED.[c1], DELETED.[c2], ...
INTO [ArchiveDb].[schema].[table] ([c1], [c2], ...)
FROM [SourceDb].[schema].[table] t
INNER JOIN #Batch k ON <JoinToAnchorPredicateSql>
WHERE (<AdditionalWhereSql>)
OPTION (RECOMPILE);
```

Seznam sloupců pro `OUTPUT` (`@delCols` = `DELETED.[...]`) i cílový seznam (`@tgtCols`) odvozuje `arch.usp_GetOutputColumns` ze `sys.columns` zdrojové tabulky (řazeno podle `column_id`), s vyloučením computed sloupců (`@IncludeComputed = 0`).

#### Fail-safe na úrovni SET options (T-04)

TIMESTAMP runner nastavuje na začátku `SET ANSI_WARNINGS ON;`. Při zapnutém `ANSI_WARNINGS` vyvolá string truncation nebo numeric overflow během `DELETE ... OUTPUT INTO <archive>` tvrdou chybu (zachycenou v `BEGIN CATCH` → `ROLLBACK`), místo aby tiše uložila zúžený/poškozený obraz, zatímco zdrojový řádek je již nenávratně smazán. Spolu se `SET XACT_ABORT ON;` to zajišťuje, že jakákoliv chyba v transakci celý dávkový krok vrátí zpět.

#### Runtime guard: kontrola Divergence (T-04)

Před `COMMIT` každé dávky oba runnery vynucují invariant `RowsArchived == RowsDeleted` na úrovni jednotlivých objektů (`arch.RunItemObject`). Pokud existuje objekt s `RowsDeleted > 0`, kde `RowsArchived <> RowsDeleted`, je vyvolán:

```sql
RAISERROR(N'Archive/Delete mismatch (Mode=1). %s', 16, 1, @divg);
```

`@divg` (resp. `@bad` v ANCHOR runneru) je seznam až 50 nesouhlasných objektů ve tvaru `; <SourceTable> del=<n> arc=<m>`. Protože `XACT_ABORT` je zapnutý, `RAISERROR` severity 16 spustí rollback celé dávky. U `DELETE ... OUTPUT INTO` je shoda počtů zaručena konstrukčně; guard je tedy defense-in-depth proti budoucí změně, špatně nastavenému `Mode` nebo částečnému selhání u více-objektového procesu. (Silnější záruka — nezávislá verifikace zpětným čtením archivu — je vedena samostatně jako T-19.)

Kontrola se provádí výhradně pro `@Mode = 1`. Mode = 0 a Mode = 2 ze své podstaty mají divergenci (jeden z počtů je vždy 0), takže guardem neprochází.

### 3.4 Mode = 0 (delete-only)

Mode = 0 maže zdrojové řádky bez jakéhokoliv zápisu do archivu (`DELETE t` bez klauzule `OUTPUT`). Protože jde o destruktivní operaci bez záchytné kopie, je chráněna dvěma nezávislými podmínkami, které musí být splněny současně:

1. **`AllowDeleteWithoutArchive = 1`** (na `arch.Process` nebo `arch.ProcessDatabase`, čteno přes `v_ProcessDatabaseEffective`, default `0`), a
2. **`RequireArchiveForDelete = 0`** na příslušném `ObjectSpec`.

Pokud je u objektu `RequireArchiveForDelete = 1` a `AllowDeleteWithoutArchive = 0`, je delete-only zablokován. Vynucení je ve třech vrstvách:

- **TIMESTAMP runner** (`027`) — pre-flight kontrola nad `#Obj`:

  ```sql
  IF @Mode = 0
     AND @AllowDelNoArch = 0
     AND EXISTS (SELECT 1 FROM #Obj WHERE RequireArchiveForDelete = 1)
      THROW 50112, 'Delete-only je blokovan, protoze nektery ObjectSpec ma RequireArchiveForDelete=1.', 1;
  ```

- **ANCHOR runner** (`015`) — kontrola per-objekt uvnitř kurzoru:

  ```sql
  IF @Mode = 0 AND @reqArch = 1 AND @AllowDelNoArch = 0
      RAISERROR(N'Delete-only blocked for %s.%s (RequireArchiveForDelete=1).', 16, 1, @sSchema, @sTable);
  ```

- **Validace konfigurace** (`arch.usp_ValidateConfiguration`) — staticky před spuštěním vrátí finding `ERROR` s textem *„Delete-only mode is blocked because RequireArchiveForDelete=1 and AllowDeleteWithoutArchive=0.“* pro každý objekt, kde `e.Mode = 0 AND COALESCE(os.RequireArchiveForDelete, 1) = 1 AND COALESCE(e.AllowDeleteWithoutArchive, 0) = 0`. Povšimněte si defaultu `RequireArchiveForDelete = 1` ve validátoru — neuvedená hodnota se interpretuje jako „archiv je vyžadován“, tedy bezpečnější varianta.

V auditních počtech Mode = 0 zapisuje `RowsDeleted = @rc`, `RowsArchived = 0` a (při `AuditLevel = ROW`) `RunDocAudit.Archived = 0`.

### 3.5 Mode = 2 (copy-only) — idempotentní záloha

Mode = 2 zkopíruje kandidátské řádky do archivu, ale **nikdy** nemaže ze zdroje. Je nedestruktivní a idempotentní: opakovaný běh vloží jen nově způsobilé řádky („backup if not exists“). Deduplikace probíhá podle **PRIMÁRNÍHO KLÍČE zdrojové tabulky** — archiv je sloupcová kopie, takže PK sloupce jsou v něm přítomny.

#### Generovaný příkaz

```sql
INSERT INTO [ArchiveDb].[schema].[table] ([c1], [c2], ...)
SELECT t.[c1], t.[c2], ...
FROM [SourceDb].[schema].[table] t
INNER JOIN #Batch k ON <JoinToAnchorPredicateSql>
WHERE (<AdditionalWhereSql>) AND
      NOT EXISTS (SELECT 1 FROM [ArchiveDb].[schema].[table] a WHERE <PkPredicate>)
OPTION (RECOMPILE);
```

Zdrojový seznam sloupců `@srcCols` (`t.[c1],t.[c2],...`) dodává `arch.usp_GetOutputColumns` přes výstupní parametr `@SourceSelectList` (alias `t`); cílový seznam `@tgtCols` je stejný jako u Mode = 1. `<PkPredicate>` je dedup predikát z `arch.usp_GetCopyDedupInfo`.

#### `arch.usp_GetCopyDedupInfo`

Procedura (definovaná v `057_copy_only_mode.sql`, ne v adresáři `procedures/`) odvozuje dedup predikát a zajišťuje dedup index. Signatura:

```sql
EXEC arch.usp_GetCopyDedupInfo
     @SourceDb = @SourceDb, @SourceSchema = @sSchema, @SourceTable = @sTable,
     @ArchiveDb = @ArchiveDb, @ArchiveSchema = @aSchema, @ArchiveTable = @aTable,
     @SourceAlias = N't', @ArchiveAlias = N'a', @EnsureIndex = 1,
     @PkPredicate = @pkPred OUTPUT;
```

Mechanismus:

1. **Najde PK** zdrojové tabulky: dotazem do `<SourceDb>.sys.indexes` zjistí `index_id` indexu s `is_primary_key = 1`. Pokud žádný PK neexistuje (`@pkid IS NULL`):

   ```sql
   THROW 50220, 'Copy-only (Mode=2) requires a PRIMARY KEY on the source table for idempotent dedup; none was found.', 1;
   ```

2. **Sestaví predikát** z PK sloupců (`sys.index_columns` + `sys.columns`, řazeno podle `key_ordinal`) ve tvaru `a.[c1] = t.[c1] AND a.[c2] = t.[c2]` (archivní alias = zdrojový alias). Současně připraví CSV PK sloupců `@pkCsv` pro index. Pokud predikát nelze odvodit:

   ```sql
   THROW 50221, 'Copy-only (Mode=2): could not derive the source primary-key dedup predicate.', 1;
   ```

3. **Zajistí dedup index** na archivu (pokud `@EnsureIndex = 1`): NONCLUSTERED index `IX_kAMCopyDedup` na archivní tabulce nad stejnými PK sloupci. Vytvoření je obaleno `TRY/CATCH` — pokud selže (např. chybějící oprávnění), je **non-fatal**: vypíše `PRINT` a pokračuje; kopie funguje i bez indexu, jen pomaleji.

Index je **non-unique záměrně**: archiv sdílený s historií Mode = 1 může legitimně držet více řádků na jeden zdrojový PK (klíč smazán, znovu vytvořen, znovu smazán). Jedinost obrazu pro daný běh vynucuje per-statement `NOT EXISTS`; souběžné běhy nad týmž objektem jsou už serializovány (TIMESTAMP applock přes `sys.sp_getapplock`, resp. jeden otevřený ANCHOR `WorkBatch`), takže k souběžným duplicitním insertům za normálního provozu nedochází.

#### Druhotná pojistka PK predikátu v runnerech

Oba runnery navíc před sestavením `INSERT`u kontrolují, že predikát není prázdný, a vyhazují vlastní chybový kód:

| Runner | THROW | Text |
| --- | --- | --- |
| TIMESTAMP (`027`) | `50222` | *Copy-only (Mode=2) is missing the source-PK dedup predicate (no PRIMARY KEY?).* |
| ANCHOR (`015`) | `50223` | *Copy-only (Mode=2) requires a PRIMARY KEY on the source table for dedup (predicate missing).* |

#### `RowsArchived` jako autoritativní počet

Sémantika počtů u Mode = 2 (z komentáře v `057`):

- **`RowsArchived`** (`RunItem` / `RunItemObject`) = počet řádků **skutečně zkopírovaných** v daném běhu; je to autoritativní „kolik bylo zpracováno“. Vzniká jako `@@ROWCOUNT` `INSERT`u (`RowsArchived = @rc`, `RowsDeleted = 0`).
- **`DocsDone`** = počet posuzovaných kandidátů (přeskenovaných v daném běhu).
- **`RunDocAudit`** (jen při `AuditLevel = ROW`) zaznamenává `Archived = 1` pro každého kandidáta (`CASE WHEN @Mode IN (1, 2) THEN 1 ELSE 0 END`).

Při idempotentním re-runu `NOT EXISTS` zkopíruje 0 řádků (`RowsArchived = 0`), zatímco `DocsDone` odráží přeskenované kandidáty. **Pro vyhodnocení, kolik bylo nově zazálohováno, čtěte `RowsArchived`, ne `DocsDone`.**

#### Kolace a provisioning

Pro dedup `a.[pk] = t.[pk]` musí archivní PK sloupce sdílet kolaci zdroje. To je splněno pro archivy zřízené `arch.usp_EnsureArchiveTableLikeSource` (kopíruje kolaci zdroje), kterou oba runnery v Mode IN (1, 2) volají **před** sestavením příkazu. Provisioning archivu (`@MakeAllNullable = 1`, `@IncludeComputed = 0`) probíhá identicky pro Mode = 1 i Mode = 2; Mode = 0 archiv nezřizuje.

### 3.6 Společné brány platné pro reálné běhy (všechny režimy)

Před reálným zpracováním (`@DryRun = 0`) procházejí oba runnery společnými branami; náhledové běhy (`@DryRun = 1`) jsou z nich vyňaty:

| Brána | Procedura | THROW | Vyňato při DryRun |
| --- | --- | --- | --- |
| Timezone policy (UTC normalizace cutoffu, P0.5 Risk K1) | `arch.usp_AssertTimezonePolicyApplied` | `50200` | Ano |
| Retention floor (T-21) | `arch.usp_AssertRetentionFloor` | `50210` | Ano |

Retention floor brána je v runnerech obalena `OBJECT_ID(N'arch.usp_AssertRetentionFloor', N'P') IS NOT NULL`, takže runner nasazený bez skriptu `056` degraduje gracefully místo chyby. U ANCHOR runneru je cutoff snapshot předáván jako `WorkBatch.RangeToUtc`; primární vynucení floor je již v PREPARE (`014`), v runneru jde o obranu pro případ, že floor byl zvýšen po přípravě.

Legal-hold (T-21) působí napříč režimy mazání: TIMESTAMP runner drží-zadržené klíče vypouští z `#Candidates` (odráží se i v dry-run náhledu), ANCHOR runner zaklamované klíče pod nově přidaným holdem parkuje (`WorkBatchKey Status = 5`) a vyřazuje z dávky `#Keys`/`#Claimed`. Obojí je `OBJECT_ID`-guarded vůči `arch.LegalHold`.


---


## 4. Cutoff, časové zóny a retence

Cutoff je horní časová hranice stáří dat, která dělí řádky na „dost staré na archivaci/smazání" a „příliš čerstvé, ponechat". V kArchiveManager 2.0 se počítá vždy v UTC a propisuje se do kandidátního filtru jako přesný predikát na `TimestampExpr`. Tato kapitola popisuje, jak se cutoff odvozuje z konfigurace, proč a kde se vynucuje UTC-normalizace přes `AT TIME ZONE`, a jak vypadá sargable optimalizace kandidátního scanu (C3).

### 4.1 Výpočet cutoffu

Cutoff (`@ToUtc` v `arch.usp_PrepareCandidates`, resp. `@CutoffUtc` v `arch.usp_RunTimestampProcess`) se odvozuje ze čtyř efektivních hodnot procesu. Všechny pocházejí z view `arch.v_ProcessDatabaseEffective`, které slučuje hodnotu z `arch.Process` s případným per-DB overridem z `arch.ProcessDatabase` (viz 4.5).

| Sloupec | Typ | Výchozí (COALESCE) | Význam |
|---|---|---|---|
| `CutoffMode` | `tinyint` | — (NULL = rolling) | `0` = rolling retence (počítá se z `RetentionDays`), `1` = pevné datum (`CutoffDate`). CHECK omezuje na `IN (0, 1)`. |
| `CutoffDate` | `datetime2(0)` | — | Pevné datum cutoffu (UTC). Použije se **jen** když `CutoffMode = 1` **a zároveň** `CutoffDate IS NOT NULL`. |
| `RetentionDays` | `int` | `0` (přes `COALESCE`) | Počet dní, které se ponechávají. Cutoff = teď − `RetentionDays`. CHECK `>= 0`. |
| `CutoffSafetyLagMinutes` | `int` | `0` (přes `COALESCE`, mapováno na `@LagMin`) | Bezpečnostní zpoždění v minutách, odečtené navíc od cutoffu (jen v rolling režimu). CHECK `>= 0`. |

#### Rolling retence (CutoffMode = 0 nebo NULL)

Cutoff se počítá od aktuálního UTC času:

- `arch.usp_PrepareCandidates` (ANCHOR/TIMESTAMP+ROW):
  ```sql
  SET @ToUtc = DATEADD(MINUTE, -@LagMin,
                  DATEADD(DAY, -COALESCE(@RetentionDays, 0),
                      CONVERT(datetime2(0), SYSUTCDATETIME())));
  ```
- `arch.usp_RunTimestampProcess` (TIMESTAMP keyset) používá místo `SYSUTCDATETIME()` parametr `@AsOfUtc` (který je sám defaultován na `SYSUTCDATETIME()`, lze ho ale předat zvenčí pro reprodukovatelný/„as-of" běh):
  ```sql
  SET @CutoffUtc = DATEADD(MINUTE, -@LagMin,
                      DATEADD(DAY, -COALESCE(@RetentionDays, 0), @AsOfUtc));
  ```

Pořadí operací: nejprve se odečte `RetentionDays` ve dnech, poté `CutoffSafetyLagMinutes` v minutách. `CutoffSafetyLagMinutes` slouží jako rezerva proti hraničním záznamům těsně na okraji retenčního okna (např. otevřené transakce, replikační zpoždění); typická hodnota v seedu RF_LOG2 je `1440` (1 den) při `RetentionDays = 540`.

#### Pevné datum (CutoffMode = 1)

```sql
IF @CutoffMode = 1 AND @CutoffDate IS NOT NULL
    SET @CutoffUtc = CONVERT(datetime2(0), @CutoffDate);   -- 027
    -- resp. SET @ToUtc = @CutoffDate;                      -- 014
```

V pevném režimu se `RetentionDays` ani `CutoffSafetyLagMinutes` neuplatní — cutoff je přesně `CutoffDate`. Pokud je `CutoffMode = 1`, ale `CutoffDate IS NULL`, propadne výpočet zpět na rolling vzorec (podmínka vyžaduje obojí).

> POZOR na konzistenci cutoff-politiky napříč DB: skript `033_standardize_receiving_cutoff.sql` řeší reálný případ, kdy jedna DB (`KMWEBV`) měla per-DB override `CutoffMode=1, CutoffDate=2024-01-01`, čímž se „zamrzla" na pevné datum, zatímco ostatní DB jely rolling (`CutoffMode=0, RetentionDays=540`). Skript override vynuluje (`SET CutoffMode = NULL`) idempotentně (jen pokud override existuje), aby DB zdědila rolling politiku procesu.

#### Vnější přepis rozsahu (jen 014)

`arch.usp_PrepareCandidates` přijímá nepovinné parametry `@FromUtc`/`@ToUtc`. Je-li `@ToUtc` předáno zvenčí, použije se přímo a celý výpočet z `CutoffMode`/`RetentionDays` se přeskočí. `@FromUtc` defaultuje na `'19000101'`. Platí tvrdá kontrola `@ToUtc <= @FromUtc` → `RAISERROR` „Invalid candidate range". `arch.usp_RunTimestampProcess` analogicky bere `@AsOfUtc` a `@StopAtUtc` (časové okno běhu), nikoli ale přímý cutoff override.

### 4.2 AT TIME ZONE normalizace — proč je povinná

Zdrojové WMS tabulky ukládají časová razítka v **lokálním čase serveru** (CET/CEST, tj. „Central European Standard Time" s letním/zimním posunem), **nikoli** v UTC. Naproti tomu se cutoff počítá z `SYSUTCDATETIME()` (UTC). Porovnávat lokální razítko přímo s UTC cutoffem by znamenalo chybu o offset (+1 h v zimě, +2 h v létě) — to je P0.5 Risk K1: nesprávně by se mohly archivovat/mazat řádky o hodinu až dvě mimo zamýšlené okno.

Řešením je, že `TimestampExpr` (resp. `AnchorTimestampExpr`) musí lokální razítko **normalizovat na UTC** dvojitým `AT TIME ZONE`:

```sql
CAST([col] AS datetime2)
    AT TIME ZONE 'Central European Standard Time'   -- interpretuj uložený čas jako CET/CEST
    AT TIME ZONE 'UTC'                               -- převeď na UTC (DST-aware)
```

První `AT TIME ZONE` připíše naivnímu razítku zónu zdroje (vyřeší i DST přechody), druhý ho převede do UTC. Výsledek je `datetimeoffset`, který se porovnává s UTC cutoffem korektně.

> **Konvence:** I genuinely-UTC zdroj musí svůj výraz obalit `AT TIME ZONE 'UTC'`, aby explicitně signalizoval „zónu jsem vyřešil". Drží to gate jako jednoduchou, low-false-positive kontrolu přítomnosti a nutí k vědomému rozhodnutí pro každý zdroj.

### 4.3 TZ gate — THROW 50200 (P0.5 Risk K1)

Procedura `arch.usp_AssertTimezonePolicyApplied` (`035_usp_AssertTimezonePolicyApplied.sql`) je defense-in-depth runtime brána, která **blokuje reálné DELETE**, pokud cutoff-řídicí výraz není UTC-normalizovaný. Mechanika:

1. Z `arch.v_ProcessDatabaseEffective` načte `SelectionStrategy` (default `'ANCHOR'`), `AnchorTimestampExpr` a `ProcessCode` pro daný `@ProcessId`/`@SourceDb`/`@ArchiveDb` s `IsEnabled = 1`.
2. Pokud `ProcessCode IS NULL` (nic enabled k hlídání) → `RETURN` (existenci validují volající procedury).
3. **ANCHOR**: pokud `AnchorTimestampExpr IS NOT NULL AND AnchorTimestampExpr NOT LIKE N'%AT TIME ZONE%'` → `THROW 50200`.
4. **TIMESTAMP**: přes `STRING_AGG` posbírá z `arch.v_ObjectSpecDatabaseEffective` všechny `ObjectIsEnabled = 1` objekty, kde `TimestampExpr IS NOT NULL AND TimestampExpr NOT LIKE N'%AT TIME ZONE%'`, do `@offenders`. Pokud je seznam neprázdný → `THROW 50200` s výčtem `SourceSchema.SourceTable`.

Kde se volá (vždy **jen na reálném běhu**, `@DryRun = 0`):

| Runner | Cesta | Co kontroluje |
|---|---|---|
| `arch.usp_RunPreparedBatch` | ANCHOR delete path | `AnchorTimestampExpr` |
| `arch.usp_RunTimestampProcess` | TIMESTAMP delete path | každý `ObjectSpec.TimestampExpr` |

V `027` je volání podmíněno `IF @DryRun = 0` (řádek 108), takže **dry-run a candidate-preview fungují i před aplikací TZ politiky** — operátor si může nejdřív ověřit počty kandidátů, gate spadne až při ostrém mazání.

Error kód `50200` je záměrně odlišný od ostatních rodin: P1.3 RunProfile validace používá `50001–50006`, vlastní validace `usp_RunTimestampProcess` `50100–50113`, retention floor `50210–50212`, copy-only `50222`. Operátor tak z čísla pozná přesnou příčinu.

Příklad chybové hlášky (TIMESTAMP):
```
Timezone policy not applied (P0.5 Risk K1): TimestampExpr for process 'RF_LOG2'
on source 'Edge' is not UTC-normalized on: dbo.RF_LOG2. Wrap each with
AT TIME ZONE before running real deletes. Delete blocked.
```

### 4.4 TimestampExpr, sargabilita a C3 sargable cutoff

#### Jak se cutoff propisuje do kandidátního filtru

`TimestampExpr` je textový SQL výraz (z `arch.ObjectSpec` u TIMESTAMP, resp. `AnchorTimestampExpr` u ANCHOR), který se za běhu vloží do dynamického SQL kandidátního scanu. V `027` (TIMESTAMP keyset) vypadá generovaný `raw` CTE takto:

```sql
;WITH raw AS
(
    SELECT
        Key1 = CONVERT(nvarchar(256), <KeyExpr>),
        DocCreatedAt = CONVERT(datetime2(0), <TimestampExpr>)
    FROM [SourceDb].[schema].[table] t WITH (READPAST)
    WHERE <TimestampExpr> < @CutoffUtc          -- PŘESNÝ predikát cutoffu
      AND CONVERT(nvarchar(256), <KeyExpr>) IS NOT NULL
      AND LTRIM(RTRIM(CONVERT(nvarchar(256), <KeyExpr>))) <> N''
      AND (<AdditionalWhereSql>)                 -- volitelně
      AND (<CandidateWhereSql>)                  -- volitelně (sem patří C3 bound)
)
```

V `014` (ANCHOR/TIMESTAMP+ROW prep) je predikát oboustranně omezený rozsahem:
```sql
WHERE <TimestampExpr> >= @FromUtc
  AND <TimestampExpr> <  @ToUtc
```

`@CutoffUtc` je v `014` exponován jako **alias `@ToUtc`** (horní mez kandidátů) — `sp_executesql` ho deklaruje a předává `@CutoffUtc = @ToUtc`. To sjednocuje API obou runnerů: operátor může psát `CandidateWhereSql`/`AdditionalWhereSql` proti `@CutoffUtc` jak v 014, tak v 027.

#### Problém sargability

Přesný predikát `<TimestampExpr> < @CutoffUtc` má raw sloupec **uvnitř funkce/`AT TIME ZONE`** (a typicky uvnitř `CAST`). Tím přestává být **sargable** — optimalizátor nemůže použít index seek a vynutí **full scan** zdrojové tabulky při každém běhu. Naměřeno: ~3–4 min jen na výběr kandidátů na 10M-řádkové `RF_LOG2` (candidate scan ~220 s na 5M běhu).

#### C3 — sargable cutoff (mitigace)

Řešením je přidat do `CandidateWhereSql` (per-proces, opt-in) **konzervativní sargable mez na raw indexovaný sloupec**, odkazující na parametr `@CutoffUtc`:

```sql
-- arch.Process.CandidateWhereSql (nebo per-DB override):
[DATE_TIME] < DATEADD(HOUR, 26, @CutoffUtc)
```

Funkce (`DATEADD`) je teď na **straně parametru**, raw sloupec `[DATE_TIME]` zůstává „holý" na levé straně → index **seekuje** k mezi místo skenování celé tabulky. Tato mez se ANDuje **navíc** k přesnému predikátu, který výsledek nadále zpřesní.

**Bezpečnost (klíčové):** protože je mez aplikována jako přídavný AND nad přesným `TimestampExpr < @CutoffUtc`, příliš těsná mez může jen **under-includovat** — archivace řádku se odloží, dokud se mez neuvolní. **Nikdy** nesmaže řádek, který měl být ponechán, ani nesmaže-bez-archivace. `26` hodin je záměrně volný superset: žádný TZ offset nepřesahuje ~14 h plus rezerva na DST, takže mez nemůže vyloučit eligible řádek.

Validace: spusť dry-run a porovnej počet kandidátů s neomezeným počtem — musí se shodovat. Je-li nižší, mez je příliš těsná, uvolni ji. C3 funguje jen tam, kde je raw sloupec sám index-friendly (`datetime`/`datetime2` s indexem). Pro string-typovaná razítka je třeba sloupec indexovat nebo přidat computed/persisted UTC sloupec.

**Profil dopadu:** Největší výhra v **ustáleném provozu** (tabulka plná recent dat, malý eligible ocas). U **backlog drainu** (většina řádků pod cutoffem) scan-výhra mizí — kandidáty stejně čteš celé. ~98 % času velkoobjemového běhu je stejně per-row fyzická práce při DELETE (clustered PK + ~16 NC indexů RF_LOG2 + plně logovaný `OUTPUT … INTO` archiv), candidate scan je sekundární. Pro takové běhy je silnější páka index-parking (`052`) + `AuditLevel = NONE`.

#### Index pro candidate scan

Aby C3 seek fungoval, doporučené tvary indexů (`deploy/v2/18_recommended_timestamp_source_indexes.sql`):
- `RF_LOG2`: `(DATE_TIME, ROWID)` pro candidate scan + `ROWID` pro join.
- `DNLOAD_ARCHIVE`: `(date_archived, ROWID)`; `date_archived` je primární cutoff, `TIMESTMP` parsing je fallback.
- `UPLOADARCHIVE`: computed `KAM_TIMESTMP_DT` parsovaný z `TIMESTMP`, indexovaný s `ROWID`.

### 4.5 Retenční podlaha a efektivní hodnoty

#### Effective override (022)

Všechny cutoff-řídicí hodnoty mají dvouúrovňovou dědičnost přes `arch.v_ProcessDatabaseEffective` (`022_effective_database_overrides.sql`): per-DB hodnota z `arch.ProcessDatabase` má přednost před hodnotou procesu (`COALESCE(pd.X, p.X)`). View navíc vystavuje `<Sloupec>Source` (`'Process'` nebo `'ProcessDatabase'`), takže je dohledatelné, odkud efektivní hodnota pochází. Týká se `RetentionDays`, `CutoffSafetyLagMinutes`, `CutoffMode`, `CutoffDate`.

#### Retention floor — THROW 50210 (T-21)

Rolling cutoff `DATEADD(DAY, -RetentionDays, now)` neměl spodní mez — jediný špatně nastavený `RetentionDays`/`CutoffDate` (navíc auto-publikovaný přes T-06) mohl smazat příliš čerstvá data. T-21 (`056_retention_floor_and_legal_hold.sql`) přidává globální podlahu:

- Tabulka `arch.RetentionPolicy` (`PolicyId = 1`), sloupec `MinRetentionDays` (`int`, default `0` = podlaha vypnutá, CHECK `>= 0`).
- `arch.usp_AssertRetentionFloor @CutoffUtc` spočítá `@earliest = DATEADD(DAY, -@floor, SYSUTCDATETIME())`. Pokud `@CutoffUtc > @earliest` (cutoff je novější než podlaha → mazaly by se řádky mladší než floor) → `THROW 50210`. Při `@floor <= 0` → no-op (zpětně kompatibilní). NULL cutoff → `THROW 50211` (fail-closed, NULL nesmí tiše projít).

Volá se na obou runnerech a kryje **oba** zdroje cutoffu (RetentionDays i CutoffDate):

| Místo volání | Podmínka | Účel |
|---|---|---|
| `arch.usp_PrepareCandidates` (014, ř. 181) | `OBJECT_ID(...usp_AssertRetentionFloor) IS NOT NULL` | Odmítne PREPARE už při tvorbě WorkBatch, aby ANCHOR nevytvořil dávku, kterou by 015 jen odmítlo (wedge re-prepare). |
| `arch.usp_RunTimestampProcess` (027, ř. 146) | `@DryRun = 0 AND OBJECT_ID(...) IS NOT NULL` | Blokuje reálný delete s cutoffem uvnitř podlahy (dry-run je exempt). |

Oba volání jsou `OBJECT_ID`-guarded → runner nasazený bez `056` (starší/hotfix cesta) degraduje gracefully místo chyby.

### 4.6 Shrnutí kontrol cutoffu (pořadí na reálném běhu)

1. Načti efektivní `CutoffMode`/`CutoffDate`/`RetentionDays`/`CutoffSafetyLagMinutes` z `v_ProcessDatabaseEffective`.
2. Spočítej cutoff (`@CutoffUtc`/`@ToUtc`) — pevný (`CutoffMode=1`) nebo rolling.
3. **Retention floor** (`50210`/`50211`) — cutoff nesmí být novější než `now − MinRetentionDays`.
4. **TZ gate** (`50200`, jen `@DryRun=0`) — `TimestampExpr`/`AnchorTimestampExpr` musí obsahovat `AT TIME ZONE`.
5. Propiš cutoff do kandidátního filtru: přesný `<TimestampExpr> < @CutoffUtc` (+ volitelný C3 sargable bound v `CandidateWhereSql`).
6. **Legal-hold** — z `#Candidates` se odeberou klíče s aktivním `arch.LegalHold` (`ReleasedAtUtc IS NULL`), aby se nikdy nearchivovaly+nesmazaly.


---


## 5. Bezpečnostní a governance brány

kArchiveManager 2.0 chrání nevratnou operaci (cross-DB DELETE produkčních řádků) sadou na sobě nezávislých bran. Brány jsou rozděleny do tří kategorií podle místa vynucení:

1. **Run-time brány** (uvnitř runnerů 014/015/027) — kontrolují vlastní mazací běh; většina je **vyňata pro DryRun** (`@DryRun=1`), takže náhled kandidátů funguje i bez splnění politiky.
2. **Config-time brány** (uvnitř `usp_Api_Save*` / `usp_Api_*` procedur) — kontrolují konfiguraci ve chvíli uložení, ještě než se vůbec spustí běh.
3. **Strukturální / přístupové brány** (DENY, role, ownership chaining) — stálá omezení nezávislá na konkrétním běhu.

Společný princip většiny run-time bran je **fail-closed** a **graceful degradation**: brány zaváděné pozdějšími migracemi (056, 035) jsou v runneru obaleny `OBJECT_ID(...) IS NOT NULL`, takže prostředí bez příslušné migrace běží **bez vynucení** (nikoli s chybou). Naopak vlastní výpočet brány nesmí nikdy „tiše projít" na `NULL` (viz 50211).

Přehled bran a jejich error kódů:

| Brána (task) | Objekt / místo | Error kód | DryRun exempt? | Vynucení |
|---|---|---|---|---|
| TZ gate (K1) | `arch.usp_AssertTimezonePolicyApplied` (015/027) | `50200` | ANO | `THROW` → blok deletu |
| Retention floor (T-21) | `arch.usp_AssertRetentionFloor` (014/015/027) | `50210`, `50211`, `50212` | ANO (run-time); v 014 vždy | `THROW` → blok prepare/deletu |
| Legal-hold (T-21) | `arch.LegalHold` exkluze + park (014/015/027) | `50213`–`50216` (mgmt API) | NE (uplatní se i v náhledu) | exkluze kandidáta / `Status=5` |
| Safe-expression validator (T-05) | `arch.usp_AssertSafeSqlExpression` (Save* procs) | `50400` | n/a (config-time) | `THROW` → odmítnutí uložení |
| 4-eyes / SoD (T-06) | `arch.usp_Api_FinalizeConfigChangeSet` | `56300`–`56313` | n/a (config-time) | `THROW` → blok schválení/publikace |
| Divergence guard (T-04) | atomický `DELETE … OUTPUT INTO` (015) | — (invariant) | n/a | `RowsArchived == RowsDeleted` |
| Immutable audit (T-09) | `DENY UPDATE/DELETE` (045) | — (engine error) | n/a | `DENY` přebíjí `GRANT` |
| Schema-drift reconcile (T-19) | `arch.usp_EnsureArchiveTableLikeSource` | `50410` | NE (proběhne při run) | auto-WIDEN nebo `THROW` |
| Runtime least-privilege (T-33) | role `karch_runtime` + `usp_VerifyRunnerPrivileges` | `RETURN 1` → `THROW` v jobu | n/a | run-start gate ve VALIDATE kroku |
| Run liveness (T-03) | `arch.Run.WorkerSessionId` + `usp_RecoverStaleRuns` | — (recovery logika) | n/a | recovery SKIP živého běhu |

---

### 5.1 TZ gate — timezone-cutoff policy (K1, `THROW 50200`)

**Co kontroluje.** Že cutoff výraz, který řídí výběr kandidátů, je explicitně UTC-normalizovaný přes `AT TIME ZONE`. Cílem je P0.5 Risk K1: mazání podle špatně interpretovaného lokálního vs. UTC času = jiná množina dat.

**Objekt.** `arch.usp_AssertTimezonePolicyApplied @ProcessId, @SourceDb, @ArchiveDb` (migrace `035`).

**Logika.** Načte z `arch.v_ProcessDatabaseEffective` `SelectionStrategy` (default `ANCHOR`):

- **ANCHOR:** pokud `AnchorTimestampExpr IS NOT NULL` a `NOT LIKE N'%AT TIME ZONE%'`, `THROW 50200`.
- **TIMESTAMP:** přes `arch.v_ObjectSpecDatabaseEffective` agreguje (`STRING_AGG`) všechny povolené objekty, jejichž `TimestampExpr IS NOT NULL` a `NOT LIKE N'%AT TIME ZONE%'`; pokud existuje aspoň jeden „offender", `THROW 50200` se seznamem `Schema.Table`.

Konvence: i prokazatelně UTC zdroj musí výraz obalit `AT TIME ZONE 'UTC'` — vědomé potvrzení per zdroj; brána je tak jednoduchý low-false-positive presence check.

**Kdy.** Voláno oběma runnery **pouze při `@DryRun=0`** (015 ř. 99–103, 027 ř. 109). DryRun / náhled kandidátů fungují i před aplikací politiky.

**Jak selže.** `THROW 50200` se zprávou obsahující `ProcessCode`, `SourceDb` a prvních 180 znaků závadného výrazu. Kód 50200 je záměrně oddělen od P1.3 (50001–50006) i od TIMESTAMP runneru (50100–50109), aby měl operátor jednoznačný signál.

```sql
-- runner volá pouze na reálném běhu
IF @DryRun = 0
    EXEC arch.usp_AssertTimezonePolicyApplied
         @ProcessId = @ProcessId, @SourceDb = @SourceDb, @ArchiveDb = @ArchiveDb;
```

---

### 5.2 Retention floor — minimum-retention policy (T-21, `THROW 50210` / `50211`)

**Co kontroluje.** Že efektivní cutoff není novější než `now − MinRetentionDays`, tj. že běh nesmaže řádky mladší než povinné retenční minimum. Pokrývá **oba** zdroje cutoffu (z `RetentionDays` i z explicitního `CutoffDate`), protože kontroluje **finální hodnotu cutoffu**.

**Objekt + úložiště.** `arch.usp_AssertRetentionFloor @ProcessId, @SourceDb, @ArchiveDb, @CutoffUtc` + singleton tabulka `arch.RetentionPolicy` (migrace `056`):

- `PolicyId tinyint` s `CHECK (PolicyId = 1)` — vždy právě jeden řádek.
- `MinRetentionDays int DEFAULT 0` s `CHECK (MinRetentionDays >= 0)` — **0 = floor vypnut** (výchozí; politiku nastaví zákazník).
- `ModifiedAtUtc`, `ModifiedBy`.

**Logika.**

```sql
DECLARE @floor int = COALESCE((SELECT TOP (1) MinRetentionDays FROM arch.RetentionPolicy WHERE PolicyId = 1), 0);
IF @floor <= 0 RETURN;                          -- floor vypnut → no-op (zpětně kompatibilní)
IF @CutoffUtc IS NULL                            -- fail-closed: NULL nesmí tiše projít
    THROW 50211, '...NULL @CutoffUtc...', 1;
DECLARE @earliest = DATEADD(DAY, -@floor, CONVERT(datetime2(0), SYSUTCDATETIME()));
IF @CutoffUtc > @earliest THROW 50210, '...Retention floor violation...', 1;
```

**Kdy a kde.** Vynuceno na **třech místech** (vše OBJECT_ID-guarded):

1. **014 (prepare, ANCHOR)** — voláno **vždy** (i mimo DryRun-rozlišení), s `@CutoffUtc = @ToUtc`, takže floor-porušující konfigurace ani nepostaví WorkBatch (ř. 181–182). Primární vynucení pro ANCHOR.
2. **015 (ANCHOR delete)** — pouze `@DryRun=0`, s `@CutoffUtc = @RangeToUtc` (snapshot cutoffu z WorkBatch). Obrana, pokud byl floor zvýšen po prepare (ř. 108–113).
3. **027 (TIMESTAMP delete)** — pouze `@DryRun=0`, s `@CutoffUtc = @CutoffUtc` (ř. 146–147).

**Jak selže.** `THROW 50210` se zprávou obsahující efektivní cutoff, hranici (`now − floor dní = …`) a návod (zvýšit `RetentionDays`/`CutoffDate`, nebo snížit `MinRetentionDays`). `THROW 50211` při `NULL` cutoffu (fail-closed). Reálné delety jsou zablokovány.

**Management API.** `arch.usp_Api_SetRetentionFloor @MinRetentionDays, @RequestedBy` (zápis politiky; `THROW 50212` při záporné hodnotě; auditováno přes `ModifiedBy`). `GRANT EXECUTE` pouze `karch_approver`; `usp_AssertRetentionFloor` má `GRANT` na `karch_runtime` a `karch_advanced_admin` (out-of-band what-if).

---

### 5.3 Legal-hold — per-key exkluze + claim-time park (T-21, `THROW 50213`–`50216`)

**Co kontroluje.** Že konkrétní dokumenty (např. pod auditem/litigací) nejsou nikdy archivovány+smazány, dokud trvá hold.

**Úložiště.** `arch.LegalHold` (migrace `056`):

| Sloupec | Význam |
|---|---|
| `ProcessCode sysname` | proces, na který hold platí |
| `SourceDb sysname NULL` | **NULL = platí pro všechny source DB** procesu |
| `HoldKey nvarchar(256)` | primární kandidátní klíč procesu = **`Key1`** |
| `Reason nvarchar(400)` | povinný důvod (≥ 6 znaků) |
| `CreatedBy` / `CreatedAtUtc` / `ReleasedAtUtc` / `ReleasedBy` | audit |

Filtrovaný index `IX_LegalHold_Active (ProcessCode, SourceDb, HoldKey) WHERE ReleasedAtUtc IS NULL` pro rychlý lookup v runnerech.

**Dva komplementární mechanismy.**

1. **Exkluze kandidátů při buildu** (014 ř. 396–400, 027 ř. 429–434): aktivní hold (`ReleasedAtUtc IS NULL`, shoda `ProcessCode`, `SourceDb IS NULL OR = @SourceDb`, `HoldKey = c.Key1 COLLATE DATABASE_DEFAULT`) je `DELETE`-nut z `#Candidates`. Držené klíče se tak vůbec nedostanou do WorkBatch a **odrazí se i v DryRun náhledu**.

2. **Claim-time park** (015 ř. 302–335) — obrana pro hold přidaný **po** prepare ANCHOR WorkBatche. Pokud existuje aktivní hold pro proces/DB, klíče se shodou na `HoldKey = k.Key1` nastaví na **`WorkBatchKey.Status = 5`** (`'parked: under legal hold'`), `ClaimedAtUtc/ClaimedBy = NULL`, `ErrorMessage = 'LEGAL HOLD: excluded from deletion (hold added after prepare).'`, a zároveň se vyřadí z `#Keys`/`#Claimed`. Klíč tak **není** smazán/archivován, **není** označen done a **není** re-claimnut; vrátí se jako čerstvý kandidát při příštím prepare po uvolnění holdu.

**Status doména.** Migrace 056 rozšiřuje `CK_WorkBatchKey_Status` na `Status >= 0 AND <= 5` (0 unclaimed, 1 claimed, 2 done, 3 error, 5 legal-hold). Recovery (030) ani done-update (015 ř. ~545) klíč ve stavu 5 „nevzkřísí".

**Granularita.** Hold je klíčován na `Key1`. U composite-key procesů (`ProcessKeySpec.KeyOrdinal > 1`) hold pokryje **všechny** řádky se stejným `Key1` (`Key2..` se nerozlišuje) — bezpečné (nikdy ne-podexkluduje), ale over-inclusive. `usp_Api_AddLegalHold` to vrací jako `Note`.

**Management API (akce `karch_approver`, auditovatelné).**

- `usp_Api_AddLegalHold @ProcessCode, @HoldKey, @Reason, @SourceDb=NULL, @RequestedBy=NULL` — validace: `THROW 50213` (chybí `@ProcessCode`), `50214` (chybí `@HoldKey`), `50215` (`@Reason` povinný, ≥ 6 znaků). Idempotentní (existující aktivní hold vrátí s `Note='already active'`).
- `usp_Api_ReleaseLegalHold @LegalHoldId, @RequestedBy=NULL` — `THROW 50216`, pokud hold neexistuje nebo už je uvolněn.
- `usp_Frontend_GetLegalHolds @ProcessCode=NULL, @ActiveOnly=1` — výpis (granty: `karch_viewer`, `karch_operator`, `karch_approver`).

```sql
EXEC arch.usp_Api_AddLegalHold
     @ProcessCode = N'RECEIVING', @HoldKey = N'DOC-12345',
     @Reason = N'litigation hold 2026/07', @SourceDb = N'KMWEBV';
```

---

### 5.4 Safe-expression validátor (T-05, `THROW 50400`)

**Co kontroluje.** Že volně-textová „advanced" konfigurační pole, která se **doslovně zřetězují** do dynamického DELETE/SELECT proti produkčním zdrojům, jsou jediným skalárním/boolean výrazem — žádné statementy, komentáře, DDL/DML, ani odkazy na procedury. Brání **uloženému second-order SQL injection** (autor configu = de facto neomezený T-SQL autor).

**Objekt.** `arch.usp_AssertSafeSqlExpression @Expression, @FieldName` (migrace `046`). Prázdné/NULL je povoleno (required-ness řeší volající Save proc).

**Tři kontroly (`@why` se nastaví na první porušení).**

1. **Terminátory / komentáře** (raw substring): `;`, `--`, `/*`/`*/`.
2. **Struktura závorek**: levo-pravý sken; `@depth` nesmí jít pod nulu (předčasné uzavření runnerova obalu `(<expr>)` → např. `1=1) OR (1=1` = vždy-true = over-delete) a musí skončit na nule.
3. **Zakázaná klíčová slova (whole-word, case-insensitive) + `xp_`/`sp_`**: interpunkce se přes `TRANSLATE` převede na mezery, takže sloupec `DATE_CREATE`/`disp_qty` neshodí `CREATE`/`sp_`. Blokuje `SELECT, INSERT, UPDATE, DELETE, MERGE, DROP, CREATE, ALTER, TRUNCATE, EXEC, EXECUTE, GRANT, REVOKE, DENY, SHUTDOWN, WAITFOR, RECONFIGURE, BACKUP, RESTORE, BULK, OPENROWSET, OPENQUERY, OPENDATASOURCE, OPENXML` a `XP_`/`SP_`.

**Kdy.** **Synchronně před uložením** každého free-text pole, volá jej každá Save procedura. Ověřená volání:

- `005_frontend_process_write_api.sql`: `AnchorDocKeyExpr`, `AnchorDocKey2Expr`, `AnchorTimestampExpr`, `AnchorExtraWhereSql`, `CandidateWhereSql`, `CandidateOrderSql`.
- `006_frontend_object_write_api.sql`: `TimestampExpr`, `JoinToAnchorPredicateSql`, `AdditionalWhereSql` + jejich `*Override` varianty.
- `009_frontend_advanced_config_write_api.sql`: `SourceExpressionSql` (`ProcessKeySpec`).

**Jak selže.** `THROW 50400` se zprávou `Unsafe SQL in advanced configuration field [<FieldName>]: <why>...`. Jde o defense-in-depth (ne plný parser); trust boundary zůstává „pole smí editovat jen advanced_admin", ale blokuje katastrofální vektory. Kalibrováno proti živému configu (2026-06-03) — všechny legitimní hodnoty (CAST/CONVERT/COALESCE/TRY_CONVERT/ISNULL/STUFF/REPLACE/AT TIME ZONE s vyváženými závorkami) projdou.

---

### 5.5 4-eyes / segregation of duties (T-06, `THROW 56310`–`56313`)

**Kontext.** Governance model je **„audited immediate-publish"** (Option A): Save* procedury publikují změnu okamžitě, mandatorní 4-eyes brána **není** ve výchozím save-path zapojena. Brána T-06 chrání **explicitní approval-workflow path** (a budoucí mandatorní flow) ve `arch.usp_Api_FinalizeConfigChangeSet` (migrace frontend `004`).

**Co kontroluje** při přechodu na `APPROVED` nebo `PUBLISHED`:

- **(a) Žádné self-approval** — `LOWER(@Actor) = LOWER(@requestedBy)` → `THROW 56310` (schvalovatel/publisher se musí lišit od `RequestedBy`).
- **(b) Role approver** — `IS_MEMBER('karch_approver')=0 AND IS_SRVROLEMEMBER('sysadmin')=0` → `THROW 56311` (jen `karch_approver` smí schvalovat/publikovat; `sysadmin` přeskakuje, jako u všech kontrol).
- **(c) State machine** — `PUBLISHED` vyžaduje aktuální stav `APPROVED`, jinak `THROW 56312`; `APPROVED` vyžaduje stav `PENDING_APPROVAL`/`APPROVED`, jinak `THROW 56313`. Nelze přeskočit rovnou na PUBLISHED.

**Doprovodné validace** (stejná proc): `56306` (neplatný `ChangeStatus`), `56307` (neplatný `ValidationStatus`), `56308` (chybí `@Actor`), `56309` (`ConfigChangeSetId` neexistuje). Validace záznamů změn: `56300`–`56305` (`usp_Api_CreateConfigChangeSet` / `usp_Api_RecordConfigFieldChange`).

**Stavový model.** `ConfigChangeSet.ChangeStatus IN ('DRAFT','PENDING_APPROVAL','APPROVED','PUBLISHED','REJECTED','CANCELLED')`; sloupce `ApprovedBy/ApprovedAtUtc` a `PublishedBy/PublishedAtUtc` se plní podle cílového stavu. Upgrade na mandatorní 4-eyes (Option B) je v governance-model.md veden jako DEFERRED.

---

### 5.6 Divergence guard — archive-before-delete invariant (T-04)

**Co kontroluje.** Že u režimu archive+delete (`Mode=1`) je počet archivovaných řádků roven počtu smazaných: **`Divergence = 0` ⇔ `RowsArchived == RowsDeleted`**. Nesoulad je chyba.

**Mechanismus — atomicita, ne dodatečná kontrola.** Runner provádí archivaci a mazání **jediným atomickým příkazem** `DELETE … OUTPUT … INTO <archiv>` (015 ř. 426–470):

```sql
DELETE t
  OUTPUT <inserted/deleted cols>
  INTO <ArchiveDb>.<schema>.<table> (<targetCols>)
  FROM <SourceDb>.<schema>.<table> t ...
SET @rc = @@ROWCOUNT;
```

Zdrojový řádek se smaže **až po** úspěšném zápisu do archivu, ve stejném transakčním rozsahu — `OUTPUT INTO` archivuje právě ty řádky, které DELETE odstraní. Počty proto z konstrukce nemohou divergovat. Per-objekt se zapisují do `arch.RunItemObject(RowsDeleted, RowsArchived)` a agregují do `arch.RunItem`:

- `Mode=1`: `RowsDeleted = @rc`, `RowsArchived = @rc` (oba stejné → Divergence 0).
- `Mode=0` (delete-only, vědomá volba): `RowsDeleted = @rc`, `RowsArchived = 0`.
- `Mode=2` (copy-only): `RowsDeleted = 0`, `RowsArchived = @rc`.

**Související config-brány:** `RequireArchiveForDelete` / `AllowDeleteWithoutArchive` explicitně řídí, zda objekt vůbec smí jít delete-only; delete-only není výchozí stav. Reconciliace (`Divergence`) je samostatně reportována v test-planu (T10).

---

### 5.7 Immutable audit — append-only DENY (T-09)

**Co kontroluje.** Že forenzní stopa každého smazání (`arch.RunDocAudit`) a záznamy změn configu nejdou po faktu přepsat ani smazat libovolným principalem s přímým DML (např. over-privileged orphan `[IIS APPPOOL\Console]` s `db_datawriter`).

**Mechanismus.** Přístupové `DENY` na `public` (migrace `045`):

| Tabulka | DENY |
|---|---|
| `arch.RunDocAudit`, `arch.ConfigChangeField`, `arch.ConfigChangeItem` (append-only) | `UPDATE, DELETE` |
| `arch.ConfigChangeSet` (status DRAFT→PUBLISHED) | `DELETE` |
| `arch.Run`, `arch.RunItem`, `arch.RunItemObject` (status/countery se UPDATEují) | `DELETE` |

**Proč to nerozbije aplikaci.** Runnery do těchto tabulek pouze `INSERT`ují (INSERT není deny-nut) a proc-mediated DML běží přes **ownership chaining** (owner proc = owner tabulka = `dbo`), které `DENY` na tabulce neovlivní. `dbo`/`sysadmin` přebíjejí všechny permission checks (řízená údržba — retenční purge, test reset). Naopak orphan / jakýkoli `db_datawriter` je blokován, protože **`DENY` přebíjí `GRANT`**.

**Limit (poctivě).** Je to access-control hardening, **ne** kryptografická tamper-evidence. Pro tamper-evident stopu na SQL Server 2022 by se `RunDocAudit` (a `ConfigChange*`) převedly na updatable **LEDGER** tabulky — vedeno jako větší follow-up.

---

### 5.8 Schema-drift reconcile (T-19, `THROW 50410`)

**Co kontroluje.** Že změna typu zdrojového sloupce nezpůsobí tiché useknutí/overflow při dalším `DELETE … OUTPUT INTO` — archiv je jediná kopie smazaných dat.

**Objekt.** `arch.usp_EnsureArchiveTableLikeSource` (volá ji 015 ř. 395 i 027 ř. 263 před archivací). Logika ve čtyřech krocích:

1. **Schéma + tabulka chybí** → `CREATE SCHEMA … AUTHORIZATION dbo` / `CREATE TABLE` (typy mapovány: `timestamp`/`rowversion` → `binary(8)`, korektní délky/precision/scale/collation). Log do `arch.ArchiveProvisionLog` (`CREATE_TABLE`).
2. **Chybějící sloupce** (zdroj má, archiv ne) → `ALTER TABLE … ADD <col> … NULL;` (log `ADD_COLUMNS`).
3. **Reconcile existujících sloupců (T-19)** — porovná `sys_type`/`max_length`/`precision`/`scale` zdroje vs. archivu a klasifikuje akci:
   - **WIDEN** (auto): stejný typ a *růst* — `varchar(50)→(100)`, hlubší `decimal` precision/scale, hlubší `datetime2`/`datetimeoffset`/`time` scale. Nikdy se nezužuje.
   - **OK**: stejný typ a archiv je ≥ zdroj (žádná akce).
   - **BLOCK**: jakákoli nekompatibilní změna typu → `THROW 50410` se seznamem sloupců `(src typ → arc typ)` a instrukcí ruční reconciliace před spuštěním.

**Detail T-19.** Zdrojový `timestamp`/`rowversion` se archivuje jako `binary(8)`, proto se i jeho drift-comparison `sys_type` zaznamená jako `binary` — jinak by se porovnával `timestamp` vs. `binary` a falešně blokoval (50410).

**Kdy.** Při reálné archivaci v rámci běhu (není to samostatná DryRun-exempt brána; běží jako součást přípravy cílové tabulky).

---

### 5.9 Runtime least-privilege (T-33)

**Cíl.** Omezit identitu, pod kterou běží nevratný archive+DELETE. SQL Agent **T-SQL** krok ignoruje `@proxy_name` a běží pod *vlastníkem jobu* (resp. pod Agent service accountem, je-li vlastník sysadmin = de facto sysadmin pro T-SQL). T-33 to řeší trojicí: clean-bundle `055` + customer add-ony `053`/`054`.

**(1) Role `karch_runtime`** (`055`): `GRANT EXECUTE` pouze na řetězec runner procedur (`usp_RunProfile_Prepared`, `usp_RunScheduledProfiles_Prepared`, `usp_RunConfiguredProcesses_Prepared`, `usp_RunPreparedBatch`, `usp_RunPreparedBatches_InWindow`, `usp_PrepareCandidates`, `usp_RunTimestampProcess`, `usp_EnsureArchiveTableLikeSource`, `usp_GetOutputColumns`, `usp_AssertTimezonePolicyApplied`, `usp_ValidateConfiguration`, `usp_RecoverStaleRuns`, `usp_VerifyRunnerPrivileges`) + `GRANT VIEW DEFINITION ON SCHEMA::arch`. Zápisy do Admin control tabulek tečou přes **ownership chaining**, takže runtime principal nemá v Admin DB **žádné** přímé table DML.

- **VIEW DEFINITION** je nutné, protože `OBJECT_ID()`/`COL_LENGTH()` guardy v procedurách sledují viditelnost *volajícího* a chaining pokrývá jen data (ne metadata) — bez něj by guardy viděly NULL a falešně `THROW`ovaly.
- Cross-DB DELETE/OUTPUT-INTO je **dynamic SQL** (chaining přerušen) → vyžaduje explicitní granty per-customer v `053`.

**(2) Customer principal + granty** (`deploy/v2/053`, parametrizováno, idempotentní, `@Apply=0` = preview):

- **Source DB:** `SELECT + DELETE` jen na namapované tabulky (`v_ObjectSpecDatabaseEffective`) + `SELECT` na ANCHOR header tabulku. Žádné DDL, žádné jiné tabulky, žádný `db_owner`.
- **Archive DB:** `INSERT + SELECT + ALTER ON SCHEMA` + `CREATE TABLE` — **žádné DELETE/UPDATE**, takže unattended runner nikdy nepročistí ani nezfalšuje archiv (purge zůstává akcí `karch_approver`/DBA přes `usp_RestoreFromArchive`, T-27). Skript pre-provisionuje archivní tabulky (jako DBA — non-dbo runner neumí `CREATE SCHEMA` za běhu).
- Skript guarduje, že login **není** sysadmin (`RAISERROR`), zachytí granty do `arch.RunnerPrivilegeInventory` a na závěr spustí `usp_VerifyRunnerPrivileges` AS nový login.

**(3) Run-start gate `arch.usp_VerifyRunnerPrivileges`** (`055`). Ověřuje **aktuální principal** (`HAS_PERMS_BY_NAME`/`IS_ROLEMEMBER` jsou current-context — proto se volá AS runtime login, což VALIDATE krok jobu dělá automaticky):

- **(a)** runner **není** `sysadmin` → ERROR (sysadmin by obešel všechny per-table checks).
- **(b)/(c)** per povolené mapování: source-side `SELECT`+`DELETE` na tabulce (chybí DELETE/SELECT → ERROR se SuggestedSql), runner **není** v `db_owner`/`db_ddladmin`/`db_securityadmin`/`db_datawriter` (→ ERROR). Archive-side: schéma existuje (jinak ERROR — non-sysadmin neumí CREATE SCHEMA za běhu) a `INSERT` na archivní tabulku (jinak WARN).
- **ANCHOR header tabulka:** samostatný kurzor ověří `SELECT` (kandidátní sken z ní čte, ale nemá ObjectSpec řádek).
- Výsledek: result set s `Severity (ERROR/WARN/OK)`. **`RETURN 1`** existuje-li aspoň jeden ERROR → VALIDATE krok jobu `THROW`ne → běh je zablokován **před** jakýmkoli deletem. Bez nálezu vrací OK řádek a `RETURN 0`.

**(4) Job owner, ne proxy** (`deploy/v2/054`): re-ownuje job `kArchiveManager - RUN CONFIGURED` na non-sysadmin runtime login přes `sp_update_job @owner_login_name`. Guarduje, že login existuje a není sysadmin (jinak by re-own privilegium nesnížil). `@AlsoRecover` defaultně `0`: `RECOVER STALE RUNS` čte cizí session v `sys.dm_exec_sessions`; non-sysadmin bez `VIEW SERVER STATE` vidí jen vlastní session a označil by živé běhy jako FAILED (přesně T-03 race) — recovery proto zůstává vlastněna Agent service accountem / sysadminem (alternativa: granty `VIEW SERVER STATE`, komentovaný řádek v 053).

**(5) Inventář** `arch.RunnerPrivilegeInventory` + `usp_CaptureRunnerPrivilegeInventory` (DBA-only): snapshot role-memberships + object permissions runtime loginu napříč source/archive DB (resolve podle SID, ne jména).

Ověřeno end-to-end: least-priv login archivuje s `Divergence=0`, je odepřen DELETE na archivu, a gate `THROW`ne při chybějícím source grantu.

---

### 5.10 Run liveness + recovery (T-03)

**Problém.** Nehlídaný job `RECOVER STALE RUNS` (každých 15 min, `@StaleAfterMinutes=30`, `@DryRun=0`) určoval „stale" čistě z `arch.Run.StartedAt` (které se neobnovuje). Legitimní běh smí trvat až `RunProfile.RunWindowMinutes` (`JOB_DEFAULT=55`) — běh za 30. minutou by byl mylně označen za stale a buď zabit uprostřed mazání, nebo (hůř) odvozen jako OK, zatímco ještě maže.

**Fix — liveness tracking** (`044`): na `arch.Run` přibyly NULLable sloupce `WorkerSessionId int` a `WorkerSessionLoginTimeUtc datetime2(3)`, které worker zapíše na start běhu.

**Recovery brána** `arch.usp_RecoverStaleRuns` (`030`):

- **Stale Run** = `Status='RUNNING'`, `EndedAt IS NULL`, `StartedAt < (now − @StaleAfterMinutes)` **A ZÁROVEŇ** běh **není živý**:
  ```sql
  AND (r.WorkerSessionId IS NULL                         -- starší než 044 (worker jistě mrtvý)
       OR NOT EXISTS (SELECT 1 FROM sys.dm_exec_sessions s
                      WHERE s.session_id = r.WorkerSessionId
                        AND s.login_time = r.WorkerSessionLoginTimeUtc));
  ```
  Tím se eliminuje recovery-vs-live-run race — recoveruje se jen běh, jehož worker session prokazatelně skončila (nebo předchází migraci 044).
- **Akce per Run:** `RunItem='OK'` → `CLOSE_OK`; `='FAILED'` → `CLOSE_FAILED`; `='DRYRUN'` → `CLOSE_DRYRUN`; `='RUNNING'` nebo `NULL` (dosaženo jen když je worker prokazatelně mrtvý) → **`MARK_FAILED`**. T-03: úspěch se **nikdy** neodvozuje z přechodně shodných counterů (běh zabitý uprostřed má `archived==deleted` pro dokončené dávky, zatímco kandidáti zbývají) — vždy FAILED, aby další běh idempotentně dozpracoval zbytek. Dřívější `CLOSE_OK_INFERRED` byl odstraněn.
- **Stale WorkBatch:** `OpenKeys=0` → `CLOSE_COMPLETE`; jinak `PAUSE_FOR_RETRY` (claimnuté klíče `Status=1` se resetují na `0`, aby je další běh přebral).
- Vše ve `BEGIN TRANSACTION` při `@DryRun=0`; `@DryRun=1` = pouze report. Safety limit `@MaxRecoveries=100`.

**Jak „selže".** Recovery není `THROW` brána — chrání tím, že **SKIPne živé běhy** a stuck běhy uzavře do FAILED pro bezpečné re-processing.


---


## 6. Audit model a sledovatelnost

Auditní stopa kArchiveManageru 2.0 je vícevrstvá: každý běh (Run) i každý dílčí proces (RunItem) zaznamenávají, kdo, kdy, na jakém hostu a s jakým výsledkem operaci spustil, dílčí počty se rozpadají per tabulka (RunItemObject) a volitelně per dokument (RunDocAudit). Vedle běhové stopy se odděleně auditují konfigurační změny (ConfigChangeSet/Item/Field) a každý reálný restore/purge (RestoreAudit). Granularita běhové stopy je řízena hodnotou `AuditLevel` na úrovni procesu (s možností per-database override). Append-only tabulky jsou na úrovni přístupových práv zamčené proti `UPDATE`/`DELETE` (skript `045_audit_immutability.sql`).

Všechny časové sloupce jsou v UTC (`SYSUTCDATETIME()`) — `datetime2(0)` u běhových/config tabulek, `datetime2(3)` u `RestoreAudit.OccurredAtUtc`.

### 6.1 Tabulka `arch.Run` — hlavička běhu (kdo / kdy / host / status / cancel)

Soubor: `kArchiveManagerAdmin/Tables/arch.Run.sql` (+ rozšíření `040_run_cancel_support.sql`, `044_run_liveness_tracking.sql`).

Jeden řádek = jeden spuštěný běh (typicky jedno spuštění SQL Agent jobu „RUN CONFIGURED“ nebo jedno volání API).

| Sloupec | Typ | Význam |
|---|---|---|
| `RunId` | `bigint IDENTITY(1,1)` | PK (`PK_Run`), klastrovaný. |
| `StartedAt` | `datetime2(0)` NOT NULL | Začátek běhu, default `sysutcdatetime()` (`DF_Run_Started`). |
| `EndedAt` | `datetime2(0)` NULL | Konec běhu (NULL dokud běží). |
| `Status` | `nvarchar(20)` NOT NULL | Stav. Default `N'RUNNING'` (`DF_Run_Status`). |
| `SourceDb` | `sysname` NULL | Zdrojová DB. |
| `ArchiveDb` | `sysname` NULL | Archivní DB. |
| `HostName` | `nvarchar(128)` NULL | Hostname spouštěče (`HOST_NAME()`). |
| `AppName` | `nvarchar(128)` NULL | Aplikace (`APP_NAME()`). |
| `InitiatedBy` | `nvarchar(128)` NULL | Přihlášený login spouštěče. |
| `ErrorMessage` | `nvarchar(max)` NULL | Chybový text při selhání. |
| `CancelRequestedAtUtc` | `datetime2(0)` NULL | Kdy byl požadován kooperativní stop (přidáno v 040). |
| `CancelRequestedBy` | `nvarchar(256)` NULL | Kdo požádal o stop (autentizovaný actor, T-10). |
| `CancelReason` | `nvarchar(400)` NULL | Důvod stopu (T-10). |
| `WorkerSessionId` | `int` NULL | SPID pracovní session (liveness, 044). |
| `WorkerSessionLoginTimeUtc` | `datetime2(3)` NULL | Login-time session workeru (liveness, 044). |

**Status (CHECK `CK_Run_Status`):** původně `RUNNING` / `OK` / `FAILED` / `DRYRUN`; skript `040` constraint dropuje podle jména a znovu vytváří rozšířený o `STOPPED`. Výsledná povolená množina:

```sql
[Status] IN (N'DRYRUN', N'FAILED', N'OK', N'RUNNING', N'STOPPED')
```

**Cancel (kooperativní stop):** procedura `arch.usp_Api_RequestRunStop @RunId, @RequestedBy, @Reason` (skript 040). Pouze běh ve stavu `RUNNING` lze zastavit; jinak vrací `Accepted = 0` a hlášku „Run is not running…“. Atribuce je **first-writer-wins** — `COALESCE(...)` zajistí, že opakovaný stop nepřepíše původního žadatele ani čas/důvod:

```sql
UPDATE arch.Run
SET CancelRequestedAtUtc = COALESCE(CancelRequestedAtUtc, SYSUTCDATETIME()),
    CancelRequestedBy    = COALESCE(CancelRequestedBy, @RequestedBy),
    CancelReason         = COALESCE(CancelReason, NULLIF(LTRIM(RTRIM(@Reason)), N''))
WHERE RunId = @RunId AND Status = N'RUNNING';
```

Pracovní procedury (`015_usp_RunPreparedBatch`, `027_usp_RunTimestampProcess`) kontrolují `CancelRequestedAtUtc` na začátku každé dávky a po dokončení rozpracované (již commitnuté) dávky cyklus přeruší; běh skončí ve stavu `STOPPED`, ANCHOR work-batche zůstanou `Paused` pro pozdější resume. Žádný `KILL`, žádný rollback hotové práce. Grant: `usp_Api_RequestRunStop` má `EXECUTE` pro roli `karch_operator` (T-02), aby tlačítko Stop fungovalo pod produkční identitou app-poolu.

**Liveness (044):** sloupce `WorkerSessionId` + `WorkerSessionLoginTimeUtc` slouží proceduře pro obnovu zaseknutých běhů, aby běh, jehož worker session prokazatelně stále žije, nebyl chybně označen jako „stale“ (legitimní běh může běžet až do `RunProfile.RunWindowMinutes`, default 55 min).

**Index:** `IX_Run_Source_Status` na (`SourceDb`, `Status`, `RunId DESC`) INCLUDE (`ArchiveDb`, `StartedAt`, `EndedAt`).

### 6.2 Tabulka `arch.RunItem` — per proces (Mode, cutoff, RowsArchived/Deleted, status)

Soubor: `kArchiveManagerAdmin/Tables/arch.RunItem.sql`.

Jeden řádek = jeden proces (`ProcessId`) zpracovaný v rámci běhu (`RunId`).

| Sloupec | Typ | Význam |
|---|---|---|
| `RunItemId` | `bigint IDENTITY` | PK (`PK_RunItem`). |
| `RunId` | `bigint` NOT NULL | FK `FK_RunItem_Run` → `arch.Run`. |
| `ProcessId` | `int` NOT NULL | FK `FK_RunItem_Process` → `arch.Process`. |
| `AsOfUtc` | `datetime2(0)` NOT NULL | Referenční „as-of“ čas běhu (UTC). |
| `CutoffUtc` | `datetime2(0)` NOT NULL | Vypočtený cutoff (vše starší se archivuje/maže). |
| `Mode` | `tinyint` NOT NULL | Operační režim: `0` = delete-only, `1` = archive+delete, `2` = copy-only (idempotentní záloha bez mazání). |
| `BatchesDone` | `int` NOT NULL | Počet dokončených dávek (default 0). |
| `DocsDone` | `int` NOT NULL | Počet zpracovaných dokumentů/klíčů (default 0). |
| `RowsDeleted` | `bigint` NOT NULL | Počet smazaných řádků (default 0). |
| `RowsArchived` | `bigint` NOT NULL | Počet archivovaných řádků (default 0). |
| `StartedAt` | `datetime2(0)` NOT NULL | Začátek, default `sysutcdatetime()`. |
| `EndedAt` | `datetime2(0)` NULL | Konec. |
| `Status` | `nvarchar(20)` NOT NULL | Stav (default `RUNNING`). |
| `ErrorMessage` | `nvarchar(max)` NULL | Chyba. |

**Status (CHECK `CK_RunItem_Status`):** stejně jako u `Run` rozšířeno skriptem 040 na `DRYRUN` / `FAILED` / `OK` / `RUNNING` / `STOPPED`.

**Integritní constraint `CK_RunItem_NonNegativeTotals`:** `BatchesDone >= 0 AND DocsDone >= 0 AND RowsDeleted >= 0 AND RowsArchived >= 0` — počitadla nelze zaznamenat jako záporná.

**Vztah Mode ↔ počitadla** (jak je plní runner, viz 6.4):
- `Mode = 0` (delete-only): `RowsDeleted = @rc`, `RowsArchived = 0`.
- `Mode = 1` (archive+delete): `RowsDeleted = RowsArchived = @rc` (invariant vynucený před COMMIT, T-04; nesoulad → rollback dávky).
- `Mode = 2` (copy-only): `RowsDeleted = 0`, `RowsArchived = @rc`.

**Index:** `IX_RunItem_Process_Status` na (`ProcessId`, `Status`, `RunId DESC`, `RunItemId DESC`) INCLUDE (`Mode`, `AsOfUtc`, `CutoffUtc`, `RowsDeleted`, `RowsArchived`).

### 6.3 Tabulka `arch.RunItemObject` — per tabulka

Soubor: `kArchiveManagerAdmin/Tables/arch.RunItemObject.sql`.

Rozpad počitadel jednoho `RunItem` na jednotlivé zdrojové tabulky. Plní se **vždy** (nezávisle na `AuditLevel`) — je to objektová úroveň auditu.

| Sloupec | Typ | Význam |
|---|---|---|
| `RunItemObjectId` | `bigint IDENTITY` | PK. |
| `RunItemId` | `bigint` NOT NULL | FK `FK_RunItemObject_RunItem` → `arch.RunItem`. |
| `SourceSchema` | `sysname` NOT NULL | Schéma zdrojové tabulky. |
| `SourceTable` | `sysname` NOT NULL | Název zdrojové tabulky. |
| `RowsDeleted` | `bigint` NOT NULL | Smazané řádky této tabulky. |
| `RowsArchived` | `bigint` NOT NULL | Archivované řádky této tabulky. |
| `LoggedAt` | `datetime2(0)` NOT NULL | Čas zápisu, default `sysutcdatetime()`. |

Constraint `CK_RunItemObject_NonNegativeRows` (`RowsDeleted >= 0 AND RowsArchived >= 0`). Index `IX_RunItemObject_RunItem` na (`RunItemId`, `SourceSchema`, `SourceTable`) INCLUDE (`RowsDeleted`, `RowsArchived`). Runner inkrementálně `UPSERT`uje per (RunItemId, schema, table): existující řádek `UPDATE`, jinak `INSERT`.

### 6.4 Tabulka `arch.RunDocAudit` — per dokument (jen při `AuditLevel = ROW`)

Soubor: `kArchiveManagerAdmin/Tables/arch.RunDocAudit.sql`.

Forenzní stopa pro jednotlivé doklady/klíče. Jeden řádek = jeden zpracovaný dokument.

| Sloupec | Typ | Význam |
|---|---|---|
| `RunDocAuditId` | `bigint IDENTITY` | PK. |
| `RunItemId` | `bigint` NOT NULL | FK `FK_RunDocAudit_RunItem` → `arch.RunItem`. |
| `ProcessCode` | `nvarchar(50)` NOT NULL | Kód procesu (denormalizováno pro rychlé dohledání). |
| `DocKeyLabel` | `nvarchar(50)` NOT NULL | Popisek klíče (např. název klíčového sloupce). |
| `DocKey` | `nvarchar(256)` NOT NULL | Vlastní hodnota klíče dokladu. |
| `DocCreatedAt` | `datetime2(0)` NULL | Čas vzniku dokladu (pro retenční kontrolu). |
| `DeletedAt` | `datetime2(0)` NOT NULL | Čas zpracování, default `sysutcdatetime()`. |
| `Archived` | `bit` NOT NULL | Zda byl doklad zároveň archivován. |

Index `IX_RunDocAudit_RunItem` na (`RunItemId`) INCLUDE (`DocKey`, `DocCreatedAt`, `Archived`).

**Plnění (027_usp_RunTimestampProcess, blok po dokončení dávky):** zápis nastává **pouze** při efektivní úrovni `AuditLevel = N'ROW'`. Příznak `Archived` je `1` pro `Mode IN (1, 2)` (archive+delete i copy-only doklad archivuje), jinak `0`:

```sql
IF @AuditLevel = N'ROW'
BEGIN
    INSERT INTO arch.RunDocAudit(RunItemId, ProcessCode, DocKeyLabel, DocKey, DocCreatedAt, Archived)
    SELECT @RunItemId, @ProcessCode, @DocKeyLabel, b.Key1, b.DocCreatedAt,
           CASE WHEN @Mode IN (1, 2) THEN 1 ELSE 0 END
    FROM #Batch b;
END;
```

> **POZOR — pravda ze zdroje:** Runner kontroluje doslovně `@AuditLevel = N'ROW'`. Úroveň `OBJECT` per-dokumentové řádky do `RunDocAudit` **nezapisuje** (zapisuje se až `RunItemObject`, per tabulka). Starší prozaický popis v `docs/audit-model.md` uvádí „ROW/OBJECT“, kód je však jednoznačný — autoritou je runner.

### 6.5 `AuditLevel` — úrovně a výkonový dopad

Sloupec `arch.Process.AuditLevel nvarchar(20) NOT NULL` (default `N'BATCH'`, `DF_Process_AuditLevel`), validovaný CHECK `CK_Process_AuditLevel`:

```sql
[AuditLevel] IN (N'NONE', N'BATCH', N'OBJECT', N'ROW')
```

Lze přebít per-database overridem (`arch.ProcessDatabase`, viz `022_effective_database_overrides.sql`); runner čte **efektivní** hodnotu z `arch.v_ProcessDatabaseEffective` s fallbackem na `N'BATCH'`:

```sql
@AuditLevel = COALESCE(NULLIF(LTRIM(RTRIM(e.AuditLevel)), N''), N'BATCH')
```

| Úroveň | Co se zapíše | Tabulky se stopou |
|---|---|---|
| `NONE` | Jen hlavička běhu + per-proces počitadla (žádný per-tabulkový ani per-dokumentový detail nad rámec `RunItem`). Doporučeno pro velkoobjemové logy (RF_LOG2). | `Run`, `RunItem` |
| `BATCH` (default) | Jako NONE; běh se atribuuje a počítá per proces. | `Run`, `RunItem` |
| `OBJECT` | Navíc rozpad počtů per zdrojová tabulka. (Per-tabulkové počitadlo `RunItemObject` plní runner ovšem vždy, viz pozn. níže.) | `Run`, `RunItem`, `RunItemObject` |
| `ROW` | Plný per-dokumentový důkaz — jeden řádek `RunDocAudit` na zpracovaný klíč. | `Run`, `RunItem`, `RunItemObject`, `RunDocAudit` |

> Poznámka k `RunItemObject`: runner plní per-tabulkové počty bez ohledu na `AuditLevel`; rozdíl mezi `NONE`/`BATCH` a `OBJECT` je proto v praxi především v očekávané/sledované granularitě a v tom, že monitorovací kontroly (6.8) vyhodnocují `RunDocAudit` jen u mapování s `AuditLevel = ROW`.

**Výkonový dopad ROW auditu (měřeno na RF_LOG2, `docs/rf-log2-run-optimization.md`):** ROW přidá jeden `RunDocAudit` řádek na dokument. Na běhu **5 000 000 řádků**:

| Řádků | AuditLevel | Wall-clock | Průtok |
|---|---|---|---|
| 5 000 000 | `NONE` | ~31,2 min (1 873 s) | ~2 669 ř/s |
| 5 000 000 | `ROW` (per-doc audit) | ~34,7 min (2 082 s) | ~2 401 ř/s; +5 000 000 řádků do `RunDocAudit`; Divergence=0 |

Tedy **ROW audit stojí ~+11 % wall-clock (−10 % průtoku) oproti NONE** (2 082 vs 1 873 s) na 5M běhu, plus 5 milionů plně logovaných řádků v Admin DB. Doporučení: velkoobjemové logy držet na `NONE`, `ROW` zapnout jen tam, kde je per-dokumentový důkaz skutečně vyžadován.

### 6.6 `arch.ConfigChangeSet` (+Item/+Field) — audit konfiguračních změn

Soubor: `kArchiveManagerAdmin/frontend/004_frontend_audit.sql` (tabulky vznikají idempotentně přes `IF OBJECT_ID(...) IS NULL`).

Auditní model konfigurace je třístupňový: **ChangeSet** (transakce změny) → **Item** (změněná entita) → **Field** (konkrétní pole se starou/novou hodnotou).

#### `arch.ConfigChangeSet`

| Sloupec | Typ | Význam |
|---|---|---|
| `ConfigChangeSetId` | `bigint IDENTITY` | PK. |
| `ChangeStatus` | `nvarchar(20)` NOT NULL | Stav, default `N'DRAFT'`. CHECK `CK_ConfigChangeSet_Status`: `DRAFT` / `PENDING_APPROVAL` / `APPROVED` / `PUBLISHED` / `REJECTED` / `CANCELLED`. |
| `RequestedBy` | `nvarchar(256)` NOT NULL | Kdo změnu inicioval. |
| `RequestedAtUtc` | `datetime2(0)` NOT NULL | Default `SYSUTCDATETIME()`. |
| `ApprovedBy` / `ApprovedAtUtc` | `nvarchar(256)` / `datetime2(0)` NULL | Schvalovatel + čas. |
| `PublishedBy` / `PublishedAtUtc` | `nvarchar(256)` / `datetime2(0)` NULL | Publikoval + čas. |
| `ChangeReason` | `nvarchar(1000)` NULL | Důvod změny. |
| `ValidationStatus` | `nvarchar(20)` NULL | Default `N'NOT_RUN'`. CHECK: `NULL` nebo `NOT_RUN` / `OK` / `WARN` / `ERROR`. |
| `ValidationSummary` | `nvarchar(4000)` NULL | Souhrn validace. |

#### `arch.ConfigChangeItem`

`ConfigChangeItemId` (PK), `ConfigChangeSetId` (FK `FK_ConfigChangeItem_ChangeSet`), `EntityType nvarchar(80)`, `EntityKey nvarchar(400)`, `Operation nvarchar(20)` (CHECK `INSERT` / `UPDATE` / `DELETE`), `ObjectId int NULL`, `CreatedAtUtc` (default `SYSUTCDATETIME()`). Index `IX_ConfigChangeItem_ChangeSet`.

#### `arch.ConfigChangeField`

`ConfigChangeFieldId` (PK), `ConfigChangeItemId` (FK `FK_ConfigChangeField_Item`), `FieldName sysname`, `OldValue nvarchar(max) NULL`, `NewValue nvarchar(max) NULL`, `IsAdvancedField bit` (default 0). Index `IX_ConfigChangeField_Item`.

#### Procedury (API vrstva)

| Procedura | Účel | Klíčové chování / error |
|---|---|---|
| `usp_Api_CreateConfigChangeSet @RequestedBy, @ChangeReason, @ConfigChangeSetId OUTPUT` | Založí draft change-set. | THROW `56300` když chybí `@RequestedBy`. |
| `usp_Api_RecordConfigFieldChange @ConfigChangeSetId, @EntityType, @EntityKey, @Operation, @ObjectId, @FieldName, @OldValue, @NewValue, @IsAdvancedField` | Zaznamená změnu jednoho pole; sdružuje Field pod existující Item (jinak Item vytvoří). | Beze změny (`@OldValue == @NewValue`) **nevytvoří** audit řádek (`Recorded = 0`). THROW `56301`–`56305` (neexistující set / chybí EntityType / EntityKey / neplatná Operation / chybí FieldName). |
| `usp_Api_FinalizeConfigChangeSet @ConfigChangeSetId, @ChangeStatus, @ValidationStatus, @ValidationSummary, @Actor` | Přechod stavu + segregation-of-duties (T-06). | Viz níže. |
| `usp_Frontend_GetConfigChangeHistory ...` | Čtení historie (souhrn + detail položek/polí). | — |

**Audited immediate-publish:** Web API při uložení konfigurace dnes **auto-publikuje** (cesta Save* nevolá `usp_Api_FinalizeConfigChangeSet`) — změna se okamžitě zapíše a kompletně se auditované zaznamenají Item/Field s OldValue/NewValue. Procedura `usp_Api_FinalizeConfigChangeSet` chrání explicitní schvalovací workflow a vynucuje:
- **(a) zákaz self-approval:** schvalovatel/publikátor (`@Actor`) musí být odlišný od `RequestedBy` — THROW `56310`.
- **(b) jen `karch_approver`** (sysadmin obchází) smí `APPROVED`/`PUBLISHED` — THROW `56311`.
- **(c) stavový automat:** `PUBLISHED` jen z `APPROVED` (THROW `56312`); `APPROVED` jen z `PENDING_APPROVAL` (THROW `56313`).
- Vstupní validace: neplatný `ChangeStatus` → `56306`, neplatný `ValidationStatus` → `56307`, chybí `@Actor` → `56308`, neexistující set → `56309`.

**Povinný důvod změny (`reason >= 6`):** validace délky důvodu se vynucuje na vstupu Admin Console editoru (`ConfigurationEditor.tsx`: `changeReason.trim().length < 6`). Stejné pravidlo (`LEN >= 6`) platí serverově pro důvod u legal-hold (viz 6.7, THROW `50215`).

### 6.7 `arch.RestoreAudit` a `arch.RunnerPrivilegeInventory`

#### `arch.RestoreAudit` (T-27)

Soubor: `kArchiveManagerAdmin/v2/042_usp_RestoreFromArchive.sql` (tabulka cestuje spolu s restore procedurou). Append-only audit každého reálného restore (un-archive) a každého archive-purge.

| Sloupec | Typ | Význam |
|---|---|---|
| `RestoreAuditId` | `bigint IDENTITY` | PK. |
| `OccurredAtUtc` | `datetime2(3)` NOT NULL | Default `SYSUTCDATETIME()`. |
| `RequestedBy` | `nvarchar(256)` NULL | Žadatel (z API). |
| `ActorLogin` | `sysname` NOT NULL | Default `SUSER_SNAME()` — skutečný SQL login. |
| `ProcessCode` | `sysname` NOT NULL | Proces. |
| `SourceDb` / `ArchiveDb` | `sysname` NOT NULL | DB. |
| `PurgeArchive` | `bit` NOT NULL | Zda šlo o purge (move-sémantiku). |
| `RowsRestored` | `bigint` NOT NULL | Obnovené řádky. |
| `ObjectsTouched` | `int` NOT NULL | Počet dotčených tabulek. |

Tabulka je hned po vytvoření zamčena `DENY UPDATE, DELETE ON arch.RestoreAudit TO public` (zrcadlí 045). Procedura `arch.usp_RestoreFromArchive` (`@DryRun = 1` default) má dvě serverové brány na `@PurgeArchive = 1` (purge je nevratný — maže jedinou přeživší kopii): **(a)** purge smí jen `karch_approver` (sysadmin obchází) — THROW `50404`; **(b)** purge je zakázán u mapování s efektivním `AuditLevel < ROW` (bez per-row stopy) — THROW `50405`.

#### `arch.RunnerPrivilegeInventory` (T-33)

Soubor: `kArchiveManagerAdmin/v2/055_runtime_runner_role_and_verify.sql`. Auditní inventář efektivních oprávnění runtime principalu (runner musí běžet jako dedikovaný **non-sysadmin** login).

| Sloupec | Typ | Význam |
|---|---|---|
| `InventoryId` | `bigint IDENTITY` | PK. |
| `CapturedAtUtc` | `datetime2(0)` NOT NULL | Default `SYSUTCDATETIME()`. |
| `CapturedBy` | `sysname` NULL | Kdo inventář pořídil. |
| `RunnerLogin` | `sysname` NOT NULL | Login runneru. |
| `DbName` | `sysname` NOT NULL | DB, kde se oprávnění vyhodnocovalo. |
| `PrincipalName` | `sysname` NULL | DB principal. |
| `GrantKind` | `nvarchar(20)` NOT NULL | `'ROLE'` nebo `'PERMISSION'`. |
| `Detail` | `nvarchar(400)` NOT NULL | Popis (název role nebo `state permission ON class [obj]`). |

Index `IX_RunnerPrivInv_At` na (`CapturedAtUtc DESC`, `RunnerLogin`, `DbName`). Plní procedura `arch.usp_CaptureRunnerPrivilegeInventory @RunnerLogin, @DbsCsv, @CapturedBy` (cross-DB čtení rolí + permissí podle SID; běží jako DBA). Souvisí s `arch.usp_VerifyRunnerPrivileges`, která pro **aktuálního** principala (job VALIDATE step běží pod runner identitou) ověří, že runner **NENÍ** sysadmin / db_owner / db_ddladmin / db_securityadmin / db_datawriter a má `SELECT`+`DELETE` na všech mapovaných zdrojových tabulkách a `INSERT` na archivních; při jakémkoli `ERROR` vrátí `RETURN 1` a blokuje běh.

### 6.8 Monitorovací views

Soubory: `023_monitoring_views.sql`, `024_operational_maintenance.sql`.

| View | Účel |
|---|---|
| `arch.v_LastRunPerProcess` | Poslední běh per (ProcessCode, SourceDb, ArchiveDb) — `ROW_NUMBER()` + `rn = 1`. Vrací status, počty, DocsDone. |
| `arch.v_RunItemsRecent` | `TOP (5000)` nejnovějších `RunItem` (řazeno `StartedAt DESC, RunItemId DESC`) s plnými počitadly a `ErrorMessage`. |
| `arch.v_RunDocAuditDetailed` | Plný JOIN `RunDocAudit` × `RunItem` × `Run` × `Process` — per-dokumentová stopa obohacená o atribuci běhu (`HostName`, `AppName`, `InitiatedBy`), Mode, cutoff, statusy a chybové texty. |
| `arch.v_OperationalHealth` | Provozní zdraví — UNION několika kontrol (viz níže). |

**`arch.v_OperationalHealth`** (skript 024) sjednocuje 5 typů nálezů se sloupci `HealthArea`, `Severity`, identifikací procesu/DB/běhu/work-batche a `Details`:

| HealthArea | Severity | Kdy se objeví |
|---|---|---|
| `RUNNING_NO_RECENT_ACTIVITY` | WARN | `RunItem` ve stavu `RUNNING` starší než 30 min (kandidát na `usp_MarkStaleRunsFailed`). |
| `FAILED_RECENT` | WARN | `RunItem` `FAILED` za posledních 7 dní (uvádí `ErrorMessage`). |
| `ROW_COUNT_MISMATCH` | ERROR | `RowsDeleted <> RowsArchived` (kontrola Mode/konzistence). |
| `ROW_AUDIT_MISSING` | ERROR | Efektivní `AuditLevel = ROW`, běh `OK`, `DocsDone > 0` (≤ 7 dní), ale `RunDocAudit` má méně řádků než `DocsDone` (chybějící per-row stopa). |
| `OPEN_WORKBATCH` | WARN | Work-batch ve stavu `Prepared` / `Running` / `Paused` (může blokovat ANCHOR přípravu). |

Kontrola `ROW_AUDIT_MISSING` napojuje `arch.v_ProcessDatabaseEffective` a vyhodnocuje se **jen** pro mapování s `AuditLevel = ROW` — tím se ověřuje, že u procesů slibujících per-dokumentovou stopu počet auditních řádků odpovídá `DocsDone`.

Skript 024 navíc obsahuje dvě údržbové procedury: `arch.usp_MarkStaleRunsFailed @StaleMinutes, @ApplyChanges, ...` (preview/aplikace označení zaseknutých `RUNNING` běhů jako `FAILED`; THROW `59000` při `@StaleMinutes < 1`) a `arch.usp_CloseDryRunWorkBatches ...` (uzavření osiřelých dry-run work-batchů; THROW `59010` při `@StaleMinutes < 0`).

### 6.9 Immutabilita auditu (DENY UPDATE/DELETE)

Soubor: `kArchiveManagerAdmin/v2/045_audit_immutability.sql` (audit task T-09).

Problém: forenzní stopa (`arch.RunDocAudit`) a konfigurační záznamy byly plně mutabilní — žádné triggery, žádný ledger, žádné DENY. Jakýkoli principal s přímým DML (např. přeprivilegovaný orphan login nebo budoucí `db_datawriter` grant) by mohl audit dodatečně `UPDATE`/`DELETE` a tím zneplatnit záruku „rekonstruovatelnosti“ nevratných mazání.

Oprava (řízení přístupu, idempotentní, opakovatelná): `DENY UPDATE`/`DELETE` pro `public` na append-only tabulkách. Rozsah je úmyslně rozlišen — append-only tabulky se zamknou proti UPDATE i DELETE, kdežto tabulky, jejichž řádky aplikace legitimně aktualizuje (stav/počitadla/lifecycle), mají zakázán pouze DELETE:

| Tabulka | DENY | Důvod |
|---|---|---|
| `arch.RunDocAudit` | `UPDATE, DELETE` | Append-only forenzní stopa (zapisuje se jednou). |
| `arch.ConfigChangeField` | `UPDATE, DELETE` | Append-only detail změn. |
| `arch.ConfigChangeItem` | `UPDATE, DELETE` | Append-only položky změn. |
| `arch.ConfigChangeSet` | `DELETE` | Status se legitimně mění (DRAFT→PUBLISHED), ale řádek se nikdy nemaže. |
| `arch.Run` | `DELETE` | Status/atribuce/cancel se aktualizují, řádek se nemaže. |
| `arch.RunItem` | `DELETE` | Status/počitadla se aktualizují, řádek se nemaže. |
| `arch.RunItemObject` | `DELETE` | Počty se aktualizují, řádek se nemaže. |
| `arch.RestoreAudit` | `UPDATE, DELETE` | (z 042) Append-only restore/purge log. |

Mechanismus a důsledky:
- **Procedury fungují dál:** runnery do těchto tabulek pouze `INSERT`ují (INSERT není zakázán) a proc-mediated DML jede přes **ownership chaining** (owner procedury = owner tabulky = `dbo`), který table-level `DENY` neovlivňuje.
- **`dbo` / `sysadmin` nejsou dotčeni** (obcházejí všechny permission checky) — řízená údržba (retenční purge T-21, test reset) jde pod elevovanou identitou.
- **Orphan / jakýkoli `db_datawriter` principal je zablokován** od ad-hoc manipulace (`DENY` přebíjí `GRANT`).

> **Poznámka (z hlavičky skriptu):** Jde o **access-control hardening, nikoli kryptografickou tamper-EVIDENCE.** Pro tamper-evident stopu na SQL Serveru 2022 je naplánovaná konverze `RunDocAudit` (a `ConfigChange*`) na updatable LEDGER tabulky jako větší follow-up; kombinuje se s odstraněním orphan loginů (T-01).


---


## 7. Restore (un-archive) a Stop/Cancel

Tato sekce popisuje dvě „reverzní“ a řídicí operace nad archivačními běhy: **Restore** (vrácení zarchivovaných řádků zpět do zdrojové databáze) a **Stop/Cancel** (kooperativní zastavení běžícího běhu). Obě jsou navrženy jako bezpečné: Restore je defaultně pouze náhled a archiv nemaže, Stop je kooperativní (žádný `KILL`, žádný rollback již zarchivované práce). Popsán je celý řetězec napříč vrstvami: Frontend (React) → API (.NET Minimal API) → SQL procedura → runner.

---

### 7.1 Restore (un-archive) — `arch.usp_RestoreFromArchive`

Procedura `[arch].[usp_RestoreFromArchive]` (skript `042_usp_RestoreFromArchive.sql`, feature **T-27**) kopíruje zarchivované řádky zpět z archivní databáze do zdrojových tabulek pro daný proces — tedy reverzuje příliš agresivní archivaci.

#### Signatura a parametry

```sql
CREATE OR ALTER PROCEDURE [arch].[usp_RestoreFromArchive]
    @ProcessCode   sysname,
    @SourceDb      sysname,
    @ArchiveDb     sysname,
    @DryRun        bit = 1,            -- DEFAULT: pouze náhled (preview)
    @MaxRows       int = NULL,         -- volitelný strop řádků na tabulku
    @PurgeArchive  bit = 0,            -- 0 = archiv ponechán (copy), 1 = po restore smazat z archivu (move)
    @RequestedBy   nvarchar(256) = NULL
```

| Parametr | Význam |
|----------|--------|
| `@ProcessCode`, `@SourceDb`, `@ArchiveDb` | Identifikují mapping proces ↔ zdroj ↔ archiv (vyhledává se ve `arch.v_ProcessDatabaseEffective`). |
| `@DryRun` | **Default `1`** — pouze spočítá, kolik řádků by se obnovilo, nic nezapisuje. `0` = reálný restore v transakci. |
| `@MaxRows` | Volitelný strop `TOP (@MaxRows)` na obnovované řádky **na tabulku**. |
| `@PurgeArchive` | Default `0` = **copy semantics** (archiv zůstane). `1` = **move semantics** (po obnově se obnovené řádky z archivu smažou). Server-side přísně hlídaný (viz níže). |
| `@RequestedBy` | Autentizovaný aktér; zapisuje se do `arch.RestoreAudit`. |

#### Vstupní validace a error kódy

Kroky validace na začátku procedury:

1. `IF DB_ID(@SourceDb) IS NULL THROW 50400, 'Source database does not exist.', 1;`
2. `IF DB_ID(@ArchiveDb) IS NULL THROW 50401, 'Archive database does not exist.', 1;`
3. Mapping `ProcessCode`/`SourceDb`/`ArchiveDb` musí existovat ve `v_ProcessDatabaseEffective`, jinak `THROW 50402, 'Process/source/archive mapping not found.', 1;`
4. Musí existovat aspoň jeden enabled `ObjectSpec`, jinak `THROW 50403, 'Process has no enabled ObjectSpec to restore.', 1;`

| Error kód | Význam |
|-----------|--------|
| `50400` | Zdrojová databáze neexistuje. |
| `50401` | Archivní databáze neexistuje. |
| `50402` | Mapping proces/zdroj/archiv nenalezen. |
| `50403` | Proces nemá žádný enabled `ObjectSpec`. |
| `50404` | `@PurgeArchive=1`, ale volající není člen role `karch_approver` (a není `sysadmin`). |
| `50405` | `@PurgeArchive=1`, ale efektivní `AuditLevel < ROW` (archiv je jediná per-row stopa). |

#### Ochrana `@PurgeArchive` (T-27)

Mazání archivu odstraňuje **jedinou dochovanou kopii** těch řádků (a u `BATCH`/`NONE` mappingů i jedinou per-row stopu), proto je purge gateován **server-side bez ohledu na volajícího**:

```sql
IF @PurgeArchive = 1
BEGIN
    IF COALESCE(IS_MEMBER('karch_approver'), 0) = 0 AND IS_SRVROLEMEMBER('sysadmin') = 0
        THROW 50404, 'Purging the archive requires membership in karch_approver.', 1;

    -- efektivní AuditLevel musí být ROW
    IF @PurgeAuditLevel <> N'ROW'
        THROW 50405, 'Purging the archive is blocked for mappings with AuditLevel < ROW ...', 1;
END;
```

- **(a)** Purge smí provést pouze člen role `karch_approver` (`sysadmin` obchází). Jinak `50404`.
- **(b)** Purge je odmítnut, pokud efektivní `AuditLevel` mappingu není `ROW` (defaultně `BATCH`), protože pak je archiv jedinou per-row stopou smazaných dokumentů. Jinak `50405`.
- **Admin Console API navíc nikdy nepředává klientem zaslaný purge flag** — endpoint vždy posílá `@PurgeArchive = false` (viz 7.3). Purge je tak DBA-only přes přímý `EXEC`.

#### Logika obnovy: pořadí, dedup, IDENTITY, rowversion

Procedura sestaví seznam enabled objektů (`@Obj`) v **opačném** `DeleteOrder` (parents/masters před children), aby byl při INSERTu splněn FK řád:

```sql
INSERT @Obj (...)
SELECT ...
FROM arch.v_ObjectSpecDatabaseEffective os
WHERE os.ProcessDatabaseId = @ProcessDatabaseId AND os.ObjectIsEnabled = 1
ORDER BY os.DeleteOrder DESC, os.ObjectSpecId DESC;
```

Pro každý objekt v kurzoru `c`:

1. **Existence tabulek** — pokud zdrojová nebo archivní tabulka chybí, řádek se přeskočí s poznámkou `SKIP: source or archive table missing`.
2. **Seznam sloupců** — `arch.usp_GetOutputColumns` s `@IncludeComputed=0` a `@ExcludeRowversion=1`. **rowversion-safe insert**: sloupec typu `rowversion`/`timestamp` nelze explicitně INSERTovat (auto-generuje se), takže je vyloučen z cílového seznamu i ze `SELECT` z archivu.
3. **PK join** — z `sys.indexes`/`sys.index_columns` se sestaví dedup predikát `s.[pk] = arc.[pk] AND ...` podle PRIMARY KEY zdrojové tabulky. Bez PK se řádek přeskočí: `SKIP: source table has no PRIMARY KEY (cannot dedup safely)`.
4. **IDENTITY-safe** — pokud má zdrojová tabulka identity sloupec, INSERT se obalí `SET IDENTITY_INSERT <src> ON;` … `OFF;`.
5. **Idempotence (dedup)** — vkládají se **pouze řádky chybějící ve zdroji** (`WHERE NOT EXISTS (SELECT 1 FROM <src> s WHERE <pkJoin>)`). Opětovné spuštění tedy už nic nepřidá.

Reálný INSERT (při `@DryRun=0`) vypadá takto:

```sql
SET IDENTITY_INSERT <src> ON;        -- jen pokud má identity
INSERT INTO <src> (<cols>)
SELECT TOP (@MaxRows) <cols> FROM <arc> arc      -- TOP jen pokud @MaxRows zadáno
WHERE NOT EXISTS (SELECT 1 FROM <src> s WHERE <pkJoin>);
SET IDENTITY_INSERT <src> OFF;       -- jen pokud má identity
```

Po INSERTu, pokud `@PurgeArchive = 1 AND @n > 0`, se z archivu smažou nyní obnovené řádky:

```sql
DELETE arc FROM <arc> arc WHERE EXISTS (SELECT 1 FROM <src> s WHERE <pkJoin>);
```

#### Atomicita

Celý reálný restore běží v **jedné transakci** se `SET XACT_ABORT ON`. Transakce se otevírá pouze pro `@DryRun=0` (`BEGIN TRAN; SET @started = 1;`), commit/rollback je řízen příznakem `@started`. Při chybě:

```sql
BEGIN CATCH
    IF @started = 1 AND XACT_STATE() <> 0 ROLLBACK;
    DECLARE @err nvarchar(4000) = ERROR_MESSAGE();
    RAISERROR(N'arch.usp_RestoreFromArchive failed: %s', 16, 1, @err);
    RETURN;
END CATCH;
```

#### `@DryRun = 1` (preview)

V náhledovém režimu se pro každý objekt do `@Result` zapíše `ArchiveRows` (celkový počet v archivu) a `RestorableRows` (kolik chybí ve zdroji = kolik *by se* obnovilo), s poznámkou `DRYRUN`. Nic se nezapisuje do zdroje ani do `RestoreAudit`. Výstupní `Mode` je `DRYRUN`.

#### Audit: `arch.RestoreAudit` (append-only)

Tabulka se vytváří přímo v `042` (cestuje s procedurou), je **append-only** (tamper-resistant):

```sql
DENY UPDATE, DELETE ON [arch].[RestoreAudit] TO public;
```

Sloupce: `RestoreAuditId` (PK IDENTITY), `OccurredAtUtc` (default `SYSUTCDATETIME()`), `RequestedBy`, `ActorLogin` (default `SUSER_SNAME()`), `ProcessCode`, `SourceDb`, `ArchiveDb`, `PurgeArchive`, `RowsRestored`, `ObjectsTouched`.

Zápis do auditu probíhá **pouze při reálném restore (`@DryRun = 0`)** a je **atomický s ním** (uvnitř téže transakce):

```sql
IF @DryRun = 0
    INSERT [arch].[RestoreAudit](RequestedBy, ProcessCode, SourceDb, ArchiveDb, PurgeArchive, RowsRestored, ObjectsTouched)
    SELECT @RequestedBy, @ProcessCode, @SourceDb, @ArchiveDb, @PurgeArchive,
           ISNULL(SUM(RestoredRows), 0), COUNT(CASE WHEN RestoredRows IS NOT NULL THEN 1 END)
    FROM @Result;
```

Nezvratný restore/purge je tak rekonstruovatelný: kdo (`ActorLogin` = ověřená login identita + `RequestedBy`), kdy, jaký mapping, zda purge a kolik řádků/objektů.

#### Výstupní result set

Procedura vrací jeden result set s řádky `@Result`: `ProcessCode`, `SourceDb`, `ArchiveDb`, `Mode` (`DRYRUN` / `RESTORE`), `RequestedBy`, dále per-objekt `SourceObject`, `ArchiveObject`, `ArchiveRows`, `RestorableRows`, `RestoredRows`, `Note`. Poznámka `Note` u reálné obnovy je `RESTORED (archive kept)` nebo `RESTORED + purged archive`.

> **POZOR (re-archivace):** Po obnově jsou řádky starší než cutoff znovu kandidáty pro archivaci při příštím běhu. Pokud má být restore trvalý, je nutné upravit retention/cutoff nebo mapping vypnout.

#### Oprávnění (GRANT)

```sql
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_RestoreFromArchive] TO [karch_advanced_admin];
```

`EXECUTE` má **pouze role `karch_advanced_admin`** (nejvyšší config role, kterou app pool drží). Záměrně **není** udělena `karch_operator` ani `karch_config_admin`. Restore zapisuje do produkčního zdroje (a s purge maže archiv), proto je drženo nad běžným operátorem. Purge je nad rámec toho gateován na `karch_approver` (T-27 / follow-up T-06).

#### Příklad přímého volání (DBA)

```sql
-- Náhled (default):
EXEC arch.usp_RestoreFromArchive
     @ProcessCode = N'RECEIVING', @SourceDb = N'KMWEBV', @ArchiveDb = N'KMWEBV_Archive';

-- Reálný restore bez purge (jak ho volá i Admin Console):
EXEC arch.usp_RestoreFromArchive
     @ProcessCode = N'RECEIVING', @SourceDb = N'KMWEBV', @ArchiveDb = N'KMWEBV_Archive',
     @DryRun = 0, @RequestedBy = N'DOMAIN\\jan.novak';

-- Move semantics (DBA-only, vyžaduje karch_approver + AuditLevel=ROW):
EXEC arch.usp_RestoreFromArchive
     @ProcessCode = N'RECEIVING', @SourceDb = N'KMWEBV', @ArchiveDb = N'KMWEBV_Archive',
     @DryRun = 0, @PurgeArchive = 1;
```

---

### 7.2 Stop/Cancel — kooperativní zastavení běhu

Stop je **kooperativní**, nikoli hard-kill. Procedura `[arch].[usp_Api_RequestRunStop]` (skript `040_run_cancel_support.sql`, feature **T-10**) pouze orazítkuje sloupce na `arch.Run`; vlastní zastavení provede runner, který mezi dávkami kontroluje cancel a udělá `BREAK`. Žádný rollback dokončené práce, žádné `KILL` oprávnění.

#### Schéma `arch.Run` — sloupce cancelu

Skript `040` idempotentně přidává tři sloupce:

| Sloupec | Typ | Význam |
|---------|-----|--------|
| `CancelRequestedAtUtc` | `datetime2(0)` NULL | Časové razítko požadavku na stop. Existence ≠ NULL = signál pro runner. |
| `CancelRequestedBy` | `nvarchar(256)` NULL | Kdo o stop požádal (autentizovaný aktér). T-10. |
| `CancelReason` | `nvarchar(400)` NULL | Důvod zastavení. T-10. |

Stav `STOPPED` byl přidán do CHECK constraintů (`CK_Run_Status`, `CK_RunItem_Status`), které dříve dovolovaly jen `DRYRUN`/`FAILED`/`OK`/`RUNNING`:

```sql
ALTER TABLE arch.Run WITH CHECK ADD CONSTRAINT CK_Run_Status
    CHECK (Status IN (N'DRYRUN', N'FAILED', N'OK', N'RUNNING', N'STOPPED'));
```

Bez tohoto rozšíření by runnerův update na `STOPPED` selhal na CHECK a běh by se chybně označil `FAILED`.

#### `usp_Api_RequestRunStop` — orazítkování (T-10, first-writer-wins)

```sql
CREATE OR ALTER PROCEDURE [arch].[usp_Api_RequestRunStop]
    @RunId       bigint,
    @RequestedBy nvarchar(256) = NULL,
    @Reason      nvarchar(400) = NULL
```

Validace:

| Error kód | Podmínka |
|-----------|----------|
| `50300` | `@RunId IS NULL` → `'@RunId is required.'` |
| `50301` | Běh s daným `RunId` neexistuje → `'Run not found.'` |

Jádro — orazítkuje se **pouze běh ve stavu `RUNNING`**, atributy se zapisují přes `COALESCE` (**first-writer-wins**: opakovaný stop nikdy nepřepíše původní atribuci):

```sql
UPDATE arch.Run
SET CancelRequestedAtUtc = COALESCE(CancelRequestedAtUtc, SYSUTCDATETIME()),
    CancelRequestedBy    = COALESCE(CancelRequestedBy, @RequestedBy),
    CancelReason         = COALESCE(CancelReason, NULLIF(LTRIM(RTRIM(@Reason)), N''))
WHERE RunId = @RunId
  AND Status = N'RUNNING';

DECLARE @accepted bit = CASE WHEN @@ROWCOUNT > 0 THEN 1 ELSE 0 END;
```

Procedura vrací result set: `RunId`, `Accepted` (0/1), `CurrentStatus`, `CancelRequestedAtUtc`, `CancelRequestedBy`, `CancelReason`, `RequestedBy` a `Message`. Když `Accepted = 1`: *„Stop requested; the run will end after the current batch.“* Když běh není `RUNNING` (terminální), vrátí se beze změny s hláškou *„Run is not running (already <Status>); nothing to stop.“*

> **Pozn. k atribuci (T-10):** Dříve `usp_Api_RequestRunStop` aktéra jen vracel ve výsledku, ale neuložil → stop nezvratného delete-runu byl po HTTP odpovědi neatributovatelný. Nyní se `CancelRequestedBy`/`CancelReason` persistuje. (Atribuci restore/purge řeší samostatně `arch.RestoreAudit`, T-27.)

#### Oprávnění (GRANT)

```sql
IF DATABASE_PRINCIPAL_ID(N'karch_operator') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Api_RequestRunStop] TO [karch_operator];
```

Stop musí být spustitelný produkční app-pool identitou (`karch_operator`), aby operátor mohl zastavit „rozjetý“ delete-run. Bez tohoto grantu by nouzové tlačítko Stop selhalo na permission-denied (mapováno na obecné 503).

#### Runner: kontrola cancelu a `BREAK` (027 TIMESTAMP)

Runner `arch.usp_RunTimestampProcess` (`027_usp_RunTimestampProcess.sql`) kontroluje cancel **na začátku batch-loopu**, ještě před zahájením nové dávky. Předchozí dávka je už commitnutá, takže ukončení je čisté:

```sql
WHILE EXISTS (SELECT 1 FROM #Candidates)
BEGIN
    IF @StopAtUtc IS NOT NULL
       AND CONVERT(datetime2(0), SYSUTCDATETIME()) >= @StopAtUtc
        BREAK;

    -- Cooperative cancel (040): operator requested a stop from the console.
    -- The previous batch is already committed; end gracefully (Status='STOPPED').
    IF EXISTS (SELECT 1 FROM arch.Run WHERE RunId = @RunId AND CancelRequestedAtUtc IS NOT NULL)
        BREAK;
    ...
END;
```

Po opuštění smyčky runner vyhodnotí finální status — pokud byl požadován cancel, je `STOPPED`, jinak `OK`:

```sql
DECLARE @FinalStatus nvarchar(20) =
    CASE WHEN EXISTS (SELECT 1 FROM arch.Run WHERE RunId = @RunId AND CancelRequestedAtUtc IS NOT NULL)
         THEN N'STOPPED' ELSE N'OK' END;

UPDATE arch.RunItem SET Status = @FinalStatus, EndedAt = ... WHERE RunItemId = @RunItemId;
UPDATE arch.Run     SET Status = @FinalStatus, EndedAt = ... WHERE RunId = @RunId;
```

**Důsledky pro data:**

- **Zarchivované/smazané dávky zůstávají** — vše do okamžiku stopu je commitnuté, nic se nerolbackuje.
- Běh skončí stavem `STOPPED` (ne `FAILED`).
- **Zbytek je resumovatelný** — nejde o hard-kill; nezpracovaní kandidáti zůstávají a lze je dokončit příštím během.
- AppLock i `LOCK_TIMEOUT`/`DEADLOCK_PRIORITY` se korektně uvolní.

#### ANCHOR větev (015) — analogie a „Paused“

Ekvivalentní runner pro strategii ANCHOR, `arch.usp_RunPreparedBatch` (`015_usp_RunPreparedBatch.sql`), má stejnou kooperativní logiku, ale navíc pracuje s `arch.WorkBatch`:

```sql
-- Cooperative cancel (040): operator requested a stop. The previous batch is
-- committed and remaining WorkBatchKeys stay claimable, so the WorkBatch is left
-- 'Paused' below and can resume later. The run ends with Status='STOPPED'.
IF EXISTS (SELECT 1 FROM arch.Run WHERE RunId = @RunId AND CancelRequestedAtUtc IS NOT NULL)
    BREAK;
```

Po `BREAK` se pracovní dávka nastaví na `WorkBatch.Status = 'Paused'` (ne na terminální stav) a zbývající `WorkBatchKeys` zůstávají claimovatelné — proto lze ANCHOR běh později **resumovat**. Run/RunItem skončí stejně `STOPPED`.

#### Příklad přímého volání

```sql
EXEC arch.usp_Api_RequestRunStop
     @RunId = 12345,
     @RequestedBy = N'DOMAIN\\jan.novak',
     @Reason = N'Spuštěno omylem proti produkci';
```

---

### 7.3 API vrstva — `/api/runs/stop` a `/api/runs/restore`

Oba endpointy jsou definovány v `AdminConsoleEndpoints.cs` (Minimal API) a vyžadují **stejnou autorizaci jako zápisy** (odemčená edit session: `security.IsAuthorized(http)` → jinak `Locked()` = HTTP 401/403 přes `Results.Json`).

#### `POST /api/runs/stop`

```csharp
app.MapPost("/api/runs/stop", async (StopRunRequest request, HttpContext http, SqlProcedureExecutor db, EditSessionStore security, CancellationToken ct) =>
{
    if (!security.IsAuthorized(http))
        return Locked();

    if (request.RunId is null)
        return Results.BadRequest(new { error = "runId is required." });

    return Results.Ok(await FirstAsync(db, "arch.usp_Api_RequestRunStop",
    [
        BigInt("@RunId", request.RunId),
        NVarChar("@RequestedBy", RequestedBy(request.RequestedBy, http, security), 256),
        NVarChar("@Reason", request.Reason, 400)
    ], ct));
}).WithTags("Runs");
```

- Volá `arch.usp_Api_RequestRunStop` a vrací první result set (`Accepted`, `Message`, …).
- `@RunId IS NULL` je zachyceno už na API (`BadRequest`) i v proceduře (`THROW 50300`).

#### `POST /api/runs/restore`

```csharp
app.MapPost("/api/runs/restore", async (RestoreRequest request, HttpContext http, SqlProcedureExecutor db, EditSessionStore security, CancellationToken ct) =>
{
    if (!security.IsAuthorized(http))
        return Locked();

    if (string.IsNullOrWhiteSpace(request.ProcessCode)
        || string.IsNullOrWhiteSpace(request.SourceDb)
        || string.IsNullOrWhiteSpace(request.ArchiveDb))
        return Results.BadRequest(new { error = "processCode, sourceDb and archiveDb are required." });

    return Results.Ok(await FirstAsync(db, "arch.usp_RestoreFromArchive",
    [
        SysName("@ProcessCode", request.ProcessCode),
        SysName("@SourceDb", request.SourceDb),
        SysName("@ArchiveDb", request.ArchiveDb),
        Bit("@DryRun", request.DryRun ?? true),
        Int("@MaxRows", request.MaxRows),
        // T-27: API NIKDY nepředává klientem zaslaný purge flag.
        Bit("@PurgeArchive", false),
        NVarChar("@RequestedBy", RequestedBy(request.RequestedBy, http, security), 256)
    ], ct));
}).WithTags("Runs");
```

- `@DryRun` defaultuje na `true` (`request.DryRun ?? true`) — i kdyby klient nic neposlal, jde o náhled.
- **`@PurgeArchive` je natvrdo `false`** — purge je DBA-only přes přímý `EXEC`, navíc gateováno v proceduře (`karch_approver` + `AuditLevel>=ROW`, error 50404/50405).

#### Atribuce aktéra — `RequestedBy` (T-07)

Obě procedury dostávají `@RequestedBy` z helperu, který **ignoruje klientem zaslanou hodnotu** a derivuje aktéra výhradně z autentizovaného principala (forgeable hodnota by umožnila mis-atribuci nezvratné akce):

```csharp
private static string RequestedBy(string? requestedBy, HttpContext http, EditSessionStore security) =>
    security.AuthenticatedUser(http) ?? http.User.Identity?.Name ?? Environment.UserName;
```

Pořadí: ověřená edit session (lokální operátor / Windows-AD uživatel) → raw Windows identita → service account.

---

### 7.4 Frontend vrstva — tlačítka „Stop run“ a „Restore from archive“

V `RunsView.tsx` jsou v `PanelActions` panelu *Runs* dvě akční tlačítka vázaná na vybraný běh (`props.selectedRun`).

#### Tlačítko „Stop run“ — pouze pro `RUNNING`

Zobrazí se jen pro běh ve stavu `RUNNING`:

```tsx
const selectedRunning = text(props.selectedRun?.status).toUpperCase() === 'RUNNING'
...
{props.selectedRun && selectedRunning ? (
  <button ... title="Stop this running run after the current batch finishes"
    onClick={() => {
      if (window.confirm(
        `Stop run ${selectedRunId}? It finishes the current batch and then stops (Status STOPPED). Already-archived rows stay archived; remaining work can be resumed later.`,
      )) {
        void props.onStopRun(props.selectedRun as Row)
      }
    }}>
    <span>Stop run</span>
  </button>
) : null}
```

#### Tlačítko „Restore from archive“

Zobrazí se pro libovolný vybraný běh (`props.selectedRun`), volá `props.onRestoreRun`.

#### Handler `stopRun` (App.tsx)

```tsx
async function stopRun(row: Row) {
  const runId = Number(row.runId)
  if (!Number.isFinite(runId)) return
  if (!securityStatus?.isUnlocked) {
    setMessage({ scope: 'Stop run', text: 'Unlock editing before stopping a run.', tone: 'info' })
    return
  }
  try {
    const result = await apiPost('/api/runs/stop', { runId }, editToken)
    const row0 = result[0] ?? {}
    const accepted = row0.accepted === true || row0.accepted === 1
    setMessage({ scope: 'Stop run',
      text: text(row0.message) || (accepted ? `Stop requested for run ${runId}.` : `Run ${runId} is not running.`),
      tone: accepted ? 'success' : 'info' })
    await loadDashboard()
  } catch (error) {
    setError('Stop run', error)
  }
}
```

- Vyžaduje odemčenou editaci (`securityStatus?.isUnlocked`), jinak jen info hláška.
- Posílá `editToken` (stejně jako zápisy konfigurace).
- Po odpovědi zobrazí `message` z procedury a reloadne dashboard (běh se překlopí na `STOPPED` po doběhnutí dávky).

#### Handler `restoreRun` (App.tsx) — dvoukrokový (preview → potvrzení)

```tsx
async function restoreRun(row: Row) {
  if (!securityStatus?.isUnlocked) { ...; return }
  const body = { processCode: text(row.processCode), sourceDb: text(row.sourceDb), archiveDb: text(row.archiveDb) }
  if (!body.processCode || !body.sourceDb || !body.archiveDb) return
  try {
    // 1) PREVIEW (dryRun: true)
    const preview = await apiPost('/api/runs/restore', { ...body, dryRun: true }, editToken)
    const restorable = preview.reduce((sum, r) => sum + Number(r.restorableRows ?? 0), 0)
    if (restorable <= 0) { ...'Nothing to restore...'; return }
    // 2) POTVRZENÍ
    if (!window.confirm(`Restore ${restorable} archived row(s) back into ${body.sourceDb} for ${body.processCode}? ...`)) return
    // 3) REÁLNÝ RESTORE (dryRun: false)
    const result = await apiPost('/api/runs/restore', { ...body, dryRun: false }, editToken)
    const restored = result.reduce((sum, r) => sum + Number(r.restoredRows ?? 0), 0)
    setMessage({ scope: 'Restore', text: `Restored ${restored} row(s) into ${body.sourceDb} for ${body.processCode}.`, tone: 'success' })
    await loadDashboard()
  } catch (error) {
    setError('Restore', error)
  }
}
```

Tři kroky:

1. **Preview** — `dryRun: true`; sečte `restorableRows` přes objekty. Když `<= 0`, jen info „Nothing to restore…“.
2. **Potvrzení** — `window.confirm` se shrnutím (kolik řádků, do které DB, že existující se přeskočí, archiv se ponechá a že řádky mohou být znovu archivovány příští běh).
3. **Reálný restore** — `dryRun: false`; sečte `restoredRows`, zobrazí success a reloadne dashboard.

Předání handlerů do `RunsView` (App.tsx):

```tsx
<RunsView ... onStopRun={stopRun} onRestoreRun={restoreRun} />
```

---

### 7.5 Shrnutí celého řetězce

| Operace | FE (RunsView/App.tsx) | API (AdminConsoleEndpoints.cs) | SQL procedura | Runner / efekt |
|---------|------------------------|--------------------------------|---------------|----------------|
| **Stop** | Tlačítko „Stop run“ (jen `RUNNING`) → `confirm` → `stopRun` → `POST /api/runs/stop` `{ runId }` | `usp_Api_RequestRunStop`, `@RequestedBy` z autentizace, error 50300/50301 | `UPDATE arch.Run` razítka `CancelRequestedAtUtc/By/Reason` (COALESCE, first-writer-wins), jen `RUNNING` | Runner (027/015) na začátku dávky vidí razítko → `BREAK` → `Status='STOPPED'`; zarchivované řádky zůstávají, zbytek resumovatelný (ANCHOR WorkBatch → `Paused`) |
| **Restore** | Tlačítko „Restore from archive“ → `restoreRun`: preview (`dryRun:true`) → `confirm` → reálný (`dryRun:false`) | `usp_RestoreFromArchive`, `@DryRun` default true, **`@PurgeArchive=false` natvrdo**, `@RequestedBy` z autentizace | Reverse `DeleteOrder`, NOT EXISTS dedup, IDENTITY_INSERT, rowversion vyloučen, vše v 1 transakci; `arch.RestoreAudit`; error 50400–50405 | Řádky se vrátí do zdroje (idempotentně), archiv ponechán; purge jen DBA + `karch_approver` + `AuditLevel=ROW` |

**Bezpečnostní invarianty:**

- Restore je defaultně náhled (`@DryRun=1`); FE vždy nejdřív zobrazí preview a vyžaduje `confirm`.
- Purge archivu je z Admin Console nedostupný (API posílá `false`); přímo přes `EXEC` jen `karch_approver`/`sysadmin` a jen u `AuditLevel=ROW`.
- Stop je kooperativní (žádný `KILL`, žádný rollback), nezvratná práce zůstává a běh je resumovatelný.
- Atribuce aktéra je vždy odvozena z autentizovaného principala, nikdy z klientem zaslané hodnoty (T-07); stop i restore jsou auditovatelné (`CancelRequestedBy/Reason`, resp. `arch.RestoreAudit`).


---


## 8. Konfigurační schéma (referenční)

Veškerá konfigurace archivace je deklarativní a žije v databázi `kArchiveManagerAdmin`, ve schématu `arch`. Žádná logika běhu není zakódovaná v procedurách napevno — runner (`arch.usp_PrepareCandidates`, `arch.usp_RunPreparedBatch`, `arch.usp_RunTimestampProcess`) čte tyto tabulky a pohledy a z nich generuje dynamický T-SQL. Konfigurace je rozdělená do tří vrstev:

1. **Šablona procesu** — `arch.Process` (jedna definice procesu, sdílená napříč databázemi).
2. **Mapování proces × databáze** — `arch.ProcessDatabase` (které zdrojové/archivní DB proces zpracovává + per-DB override).
3. **Objekty (tabulky) procesu** — `arch.ObjectSpec` (které tabulky mazat/archivovat) a `arch.ProcessKeySpec` (jak vypadá přirozený/dokumentový klíč).

Efektivní (vypočtená) konfigurace, kterou runner skutečně používá, vzniká spojením těchto vrstev v pohledech `arch.v_ProcessDatabaseEffective` a `arch.v_ObjectSpecDatabaseEffective`, kde `ProcessDatabase` (resp. `ObjectSpecDatabaseOverride`) **přebíjí** odpovídající hodnotu z `Process` (resp. `ObjectSpec`).

> Pozn.: Definice tabulek je rozdělena do dvou míst. Základní sloupce vznikají v `Tables/arch.*.sql`; sloupce přidané v rámci univerzálního jádra v2 (`SelectionStrategy`, `AuditLevel`, `RequireSupportingIndex`, `MaxRowsPerTransaction`, `CandidateWhereSql`, `CandidateOrderSql` na `arch.Process`) jsou doplněny idempotentně přes `kArchiveManagerAdmin/v2/010_universal_archive_core.sql`. Stejné sloupce na `arch.ProcessDatabase` přidává `022_effective_database_overrides.sql`.

---

### 8.1 `arch.Process` — šablona procesu

Hlavní tabulka s jedním řádkem na proces. PK `ProcessId` (IDENTITY), přirozený klíč `ProcessCode` (UNIQUE `UQ_ProcessCode`). Cizí klíče z `ProcessDatabase`, `ObjectSpec` a `ProcessKeySpec` na ni odkazují přes `ProcessId`.

#### Identifikace a stav

| Sloupec | Typ | Default | Význam |
|---|---|---|---|
| `ProcessId` | `int IDENTITY` | — | PK. |
| `ProcessCode` | `nvarchar(50)` | — | Stabilní textový kód procesu (např. `RECEIVING`, `RF_LOG2`). UNIQUE. Používá se ve všech EXEC voláních a seedech místo numerického ID. |
| `Description` | `nvarchar(200)` NULL | — | Lidský popis. |
| `IsEnabled` | `bit` | `1` (`DF_Process_IsEnabled`) | Master vypínač procesu. Efektivní `IsEnabled` v pohledu = `Process.IsEnabled AND ProcessDatabase.IsEnabled`. |

#### Strategie výběru a režim

| Sloupec | Typ | Default | Omezení / hodnoty |
|---|---|---|---|
| `SelectionStrategy` | `nvarchar(30) NOT NULL` | `N'ANCHOR'` (`DF_Process_SelectionStrategy`) | `ANCHOR` nebo `TIMESTAMP`. Runner (`usp_PrepareCandidates`) jiné hodnoty odmítne (`RAISERROR ... implements ANCHOR and TIMESTAMP only`). `ANCHOR` = kandidáti se odvozují od kotevní tabulky (`Anchor*`) a join-predikátu; `TIMESTAMP` = kandidáti se odvozují přímo z časového razítka na cílové tabulce. |
| `Mode` | `tinyint NOT NULL` | — | `CK_Process_Mode`: pouze `0`, `1`, `2`. **0** = delete-only (smaž bez archivace), **1** = archive+delete (zarchivuj, pak smaž), **2** = copy-only (idempotentní záloha bez mazání). |
| `AllowDeleteWithoutArchive` | `bit NOT NULL` | `0` (`DF_Process_AllowDelNoArch`) | Bezpečnostní pojistka: povolí mazání, i když archivace neproběhla. Při `0` se delete bez úspěšné archivace zablokuje. |

#### Retence a cutoff

| Sloupec | Typ | Default | Omezení |
|---|---|---|---|
| `RetentionDays` | `int NOT NULL` | — | Počet dní, které zůstávají v živé DB. Kandidát je vše starší než `now - RetentionDays`. `CK_Process_NonNegativeLimits`: `>= 0`. |
| `CutoffSafetyLagMinutes` | `int NOT NULL` | `60` (`DF_Process_Lag`) | Bezpečnostní rezerva (minuty) odečtená od horní hranice okna, aby se nezpracovávaly „čerstvé“ záznamy na hraně. `>= 0`. |
| `CutoffMode` | `tinyint NOT NULL` | `0` (`DF_Process_CutoffMode`) | `CK_Process_CutoffMode`: `0` nebo `1`. `0` = rolling (cutoff = relativně k dnešku přes `RetentionDays`), `1` = fixed (cutoff = pevné `CutoffDate`). |
| `CutoffDate` | `datetime2(0)` NULL | — | Pevné datum cutoffu; používá se jen při `CutoffMode = 1`. |

#### Dávkování a propustnost

| Sloupec | Typ | Default | Omezení |
|---|---|---|---|
| `BatchDocCount` | `int` NULL | — | Velikost dávky v počtu **dokumentů** (ANCHOR). `> 0` pokud nenull. |
| `BatchRowCount` | `int` NULL | — | Velikost dávky v počtu **řádků** (TIMESTAMP). `> 0` pokud nenull. |
| `MaxBatchesPerRun` | `int NOT NULL` | `50` (`DF_Process_MaxBatches`) | Strop počtu dávek na jeden běh. `> 0`. |
| `DelayMsBetweenBatches` | `int NOT NULL` | `0` (`DF_Process_Delay`) | Pauza mezi dávkami (ms) pro snížení tlaku na zdroj. `>= 0`. |
| `MaxRowsPerTransaction` | `int` NULL | — | Strop řádků v jedné transakci (chunking velkých dávek). `> 0` pokud nenull. |

#### Zamykání a souběh

| Sloupec | Typ | Default | Omezení |
|---|---|---|---|
| `UseAppLock` | `bit NOT NULL` | `1` (`DF_Process_UseAppLock`) | Zda použít `sp_getapplock` proti souběžnému běhu téhož procesu. |
| `AppLockResource` | `nvarchar(200)` NULL | — | Název zámkového zdroje; pokud prázdný, runner si jej odvodí. |
| `LockTimeoutMs` | `int NOT NULL` | `10000` (`DF_Process_LockTimeout`) | Timeout čekání na zámek (ms). `>= 0`. |
| `DeadlockPriority` | `nvarchar(10) NOT NULL` | `N'LOW'` (`DF_Process_DLP`) | `CK_Process_DeadlockPriority`: `N'LOW'`, `N'NORMAL'`, `N'HIGH'`. Při deadlocku se obětuje raději archivační session. |

#### Kotva (ANCHOR strategie)

Tyto sloupce mají smysl jen pro `SelectionStrategy = ANCHOR`. Kotevní tabulka určuje množinu „dokumentů“ ke zpracování; podřízené `ObjectSpec` se k ní pak připojují přes `JoinToAnchorPredicateSql`.

| Sloupec | Typ | Význam |
|---|---|---|
| `AnchorSchema` | `sysname` NULL | Schéma kotevní tabulky (typicky `dbo`). |
| `AnchorTable` | `sysname` NULL | Kotevní tabulka (např. `BACKRH`, `SHIPHIST`, `t_receipt`). Alias v dynamickém SQL je `a`. |
| `AnchorDocKeyExpr` | `nvarchar(4000)` NULL | Výraz pro primární dokumentový klíč (Key1), např. `PO_NUM`, `a.receipt_id`. |
| `AnchorDocKey2Expr` | `nvarchar(4000)` NULL | Volitelný druhý dokumentový klíč (Key2), např. `a.wh_id`. |
| `AnchorTimestampExpr` | `nvarchar(4000)` NULL | Výraz pro časové razítko kotvy převedený na UTC. Musí být UTC-normalizovaný (`AT TIME ZONE` pattern), jinak časová politika běh zablokuje. |
| `AnchorExtraWhereSql` | `nvarchar(4000)` NULL | Dodatečný filtr kotvy. |
| `DocKeyLabel` | `nvarchar(50) NOT NULL` | `N'DOCKEY'` (`DF_Process_DocKeyLabel`) | Popisek dokumentového klíče pro audit/UI (např. `PO_NUM`, `PACKSLIP`, `ROWID`). |

#### Audit, index a kandidátní filtry

| Sloupec | Typ | Default | Omezení / význam |
|---|---|---|---|
| `AuditLevel` | `nvarchar(20) NOT NULL` | `N'BATCH'` (`DF_Process_AuditLevel`) | Granularita auditu: `NONE`, `BATCH`, `OBJECT`, `ROW` (na `ProcessDatabase` vynucuje `CK_ProcessDatabase_OverrideLimits`). Vyšší úroveň = více auditních záznamů, vyšší režie. |
| `RequireSupportingIndex` | `bit NOT NULL` | `1` (`DF_Process_RequireSupportingIndex`) | Vynucuje existenci podpůrného indexu (viz `arch.IndexRequirement`); brání pomalým full-scan mazáním. |
| `CandidateWhereSql` | `nvarchar(4000)` NULL | — | Volitelný globální WHERE pro výběr kandidátů. |
| `CandidateOrderSql` | `nvarchar(4000)` NULL | — | Volitelné ORDER BY pro deterministické pořadí výběru (důležité u TIMESTAMP, např. `DocCreatedAt, Key1`). |
| `CreatedAt` / `ModifiedAt` | `datetime2(0) NOT NULL` | `sysutcdatetime()` | Audit razítka (UTC). |

---

### 8.2 `arch.ProcessDatabase` — mapování proces × databáze + per-DB override

Jeden řádek na kombinaci proces × zdrojová DB × archivní DB. Říká, **kde** proces běží a volitelně **přebíjí** kteroukoli laditelnou hodnotu z `arch.Process` pro konkrétní databázi.

- PK `ProcessDatabaseId` (IDENTITY).
- `UQ_ProcessDatabase_Process_Source_Archive` UNIQUE na (`ProcessId`, `SourceDb`, `ArchiveDb`).
- `FK_ProcessDatabase_Process` na `arch.Process(ProcessId)`.
- Index `IX_ProcessDatabase_Enabled_RunOrder` na (`IsEnabled`, `RunOrder`, `ProcessId`) INCLUDE (`SourceDb`, `ArchiveDb`) — runner podle něj plánuje pořadí.

#### Povinné sloupce mapování

| Sloupec | Typ | Default | Význam |
|---|---|---|---|
| `ProcessId` | `int NOT NULL` | — | FK na proces. |
| `SourceDb` | `sysname NOT NULL` | — | Zdrojová (živá) databáze, např. `Edge`, `KMWEBV`, `KMWE_Test`, `AAD`. |
| `ArchiveDb` | `sysname NOT NULL` | — | Cílová archivní databáze, typicky `kArchiveManagerBackups`. |
| `IsEnabled` | `bit NOT NULL` | `1` (`DF_ProcessDatabase_IsEnabled`) | Per-mapování vypínač. |
| `RunOrder` | `int NOT NULL` | `100` (`DF_ProcessDatabase_RunOrder`) | Pořadí zpracování napříč mapováními (nižší = dřív). V seedu se používá konvence „blok podle DB“ (1010, 2010, 3010…). |

#### Override sloupce (NULL = dědí z `arch.Process`)

Všechny následující sloupce jsou **nullable**; `NULL` znamená „použij hodnotu z `arch.Process`“. Validuje je `CK_ProcessDatabase_OverrideLimits` (stejná pravidla jako na `Process`, ale s `IS NULL OR ...`):

`Mode` (`0/1/2`), `RetentionDays` (`>=0`), `CutoffSafetyLagMinutes` (`>=0`), `CutoffMode` (`0/1`), `CutoffDate`, `BatchDocCount` (`>0`), `BatchRowCount` (`>0`), `MaxBatchesPerRun` (`>0`), `DelayMsBetweenBatches` (`>=0`), `UseAppLock`, `AppLockResource`, `LockTimeoutMs` (`>=0`), `DeadlockPriority` (`LOW/NORMAL/HIGH`), `AnchorSchema`, `AnchorTable`, `AnchorDocKeyExpr`, `AnchorDocKey2Expr`, `AnchorTimestampExpr`, `AnchorExtraWhereSql`, `AllowDeleteWithoutArchive`, `DocKeyLabel`, `AuditLevel` (`NONE/BATCH/OBJECT/ROW`), `RequireSupportingIndex`, `MaxRowsPerTransaction` (`>0`), `CandidateWhereSql`, `CandidateOrderSql`.

> Pozn.: `SelectionStrategy` se **nepřebíjí** na úrovni `ProcessDatabase` — je vlastností šablony procesu (v pohledu se počítá výhradně z `Process`).

Příklad override z reálného seedu (`RF_LOG2` na `KMWEBV`): mapování explicitně nastaví `Mode=1`, `RetentionDays=540`, `BatchRowCount=50000`, `MaxBatchesPerRun=20`, `MaxRowsPerTransaction=50000`, `AuditLevel='ROW'`, `CandidateOrderSql='DocCreatedAt, Key1'` — tím přebije šablonu jen pro tuto jednu databázi.

---

### 8.3 `arch.ObjectSpec` — tabulky zpracovávané procesem

Jeden řádek na fyzickou tabulku, kterou proces maže/archivuje. PK `ObjectSpecId`, `FK_ObjectSpec_Process` na `arch.Process(ProcessId)`. Index `IX_ObjectSpec_Process_DeleteOrder` na (`ProcessId`, `DeleteOrder`, `ObjectSpecId`) INCLUDE většiny sloupců.

| Sloupec | Typ | Default | Význam |
|---|---|---|---|
| `ObjectSpecId` | `int IDENTITY` | — | PK. |
| `ProcessId` | `int NOT NULL` | — | FK na proces. |
| `SourceSchema` | `sysname NOT NULL` | — | Schéma zdrojové tabulky (typicky `dbo`). |
| `SourceTable` | `sysname NOT NULL` | — | Zdrojová tabulka (např. `BACKRD`, `SHIPMSTR`, `RF_LOG2`). Alias v dynamickém SQL je `t`. |
| `DeleteOrder` | `int NOT NULL` | — | Pořadí mazání v rámci jednoho dokumentu — **děti před rodiči** kvůli FK (např. SHIPPING: `SHIPDETL`=10 … `SHIPHIST`=60, kotva). |
| `DeleteMode` | `tinyint NOT NULL` | — | `CK_ObjectSpec_DeleteMode`: `0` nebo `1`. Řídí způsob mazání objektu. |
| `TimestampExpr` | `nvarchar(4000)` NULL | — | UTC-normalizovaný výraz časového razítka tabulky. Povinný u TIMESTAMP procesů; u ANCHOR může chybět (čas určuje kotva). U smoke ANCHOR fixtur je `NULL`. |
| `JoinToAnchorPredicateSql` | `nvarchar(4000)` NULL | — | Predikát napojení tabulky na dokumentový klíč. U ANCHOR typicky `t.PO_NUM = k.Key1`; u vícenásobného klíče `... = k.Key1 AND ISNULL(...) = k.Key2`. Alias `k` = sada vybraných klíčů (`WorkBatchKey`). |
| `AdditionalWhereSql` | `nvarchar(4000)` NULL | — | Dodatečný filtr na úrovni objektu (např. `t.DATE_TIME IS NOT NULL`). |
| `ArchiveSchema` | `sysname NOT NULL` | `N'dbo'` (`DF_ObjectSpec_ArchSchema`) | Schéma cílové archivní tabulky. V seedu se používá placeholder `{SourceDb}` (rozvine se za běhu) nebo konkrétní schéma jako `WA_AAD_SMOKE`. |
| `ArchiveTable` | `sysname` NULL | — | Název archivní tabulky. `NULL` = runner odvodí název automaticky (typicky podle zdrojové tabulky). |
| `RequireArchiveForDelete` | `bit NOT NULL` | `1` (`DF_ObjectSpec_ReqArch`) | Pokud `1`, smazání řádku proběhne jen po jeho úspěšné archivaci. Společně s `AllowDeleteWithoutArchive` tvoří dvojitou pojistku proti ztrátě dat. |
| `NaturalKeyLabel` | `nvarchar(50)` NULL | — | Popisek přirozeného klíče tabulky pro audit/UI. |

Per-DB override objektů řeší samostatná tabulka `arch.ObjectSpecDatabaseOverride` (zakládá ji `022_effective_database_overrides.sql`) s `UQ_ObjectSpecDatabaseOverride` na (`ProcessDatabaseId`, `ObjectSpecId`) a FK na obě strany. Přebíjí `SourceSchema/Table`, `TimestampExpr`, `JoinToAnchorPredicateSql`, `AdditionalWhereSql`, `ArchiveSchema/Table`, `RequireArchiveForDelete` plus má vlastní `IsEnabled`.

---

### 8.4 `arch.ProcessKeySpec` — definice dokumentového/přirozeného klíče

Definuje sloupce, které tvoří identitu „dokumentu“ (sady `Key1..KeyN`), podle nichž se kandidáti seskupují a podle nichž se podřízené tabulky připojují ke kotvě. Jeden řádek na komponentu klíče.

| Sloupec | Typ | Default | Omezení / význam |
|---|---|---|---|
| `ProcessKeySpecId` | `int IDENTITY` | — | PK `PK_ProcessKeySpec`. |
| `ProcessId` | `int NOT NULL` | — | `FK_ProcessKeySpec_Process` na `arch.Process`. |
| `KeyOrdinal` | `tinyint NOT NULL` | — | Pořadí komponenty klíče. `CK_ProcessKeySpec_KeyOrdinal`: `BETWEEN 1 AND 8`. `1` → `Key1`, `2` → `Key2` atd. `UQ_ProcessKeySpec_Process_Ordinal` UNIQUE na (`ProcessId`, `KeyOrdinal`). |
| `KeyName` | `sysname NOT NULL` | — | Logický název komponenty (např. `PO_NUM`, `receipt_id`, `wh_id`, `ROWID`). |
| `SourceExpressionSql` | `nvarchar(4000) NOT NULL` | — | Výraz, jak komponentu získat z kotvy/tabulky, např. `a.PO_NUM`, `t.ROWID`, `ISNULL(a.wh_id, N'')`. |
| `SqlType` | `nvarchar(128) NOT NULL` | — | SQL datový typ komponenty pro správné castování (`nvarchar(256)`, `uniqueidentifier`, `nvarchar(30)`…). |
| `IsRequired` | `bit NOT NULL` | `1` (`DF_ProcessKeySpec_IsRequired`) | Zda je komponenta povinná. U druhé komponenty (např. `wh_id`) bývá `0`. |
| `CreatedAt` / `ModifiedAt` | `datetime2(0) NOT NULL` | `sysutcdatetime()` | Audit razítka (UTC). |

> Pozn.: TIMESTAMP procesy mívají jednu komponentu (`ROWID`); ANCHOR procesy se dvěma klíči (např. `WA_AAD_PRIJEM_OSTRY_SMOKE`) mají `receipt_id` jako `KeyOrdinal=1` (required) a `wh_id` jako `KeyOrdinal=2` (optional).

---

### 8.5 `arch.v_ProcessDatabaseEffective` — efektivní konfigurace a precedence override

Definuje ji `022_effective_database_overrides.sql`. Spojuje `arch.ProcessDatabase` (`pd`) s `arch.Process` (`p`) přes `ProcessId` a pro každý laditelný sloupec počítá efektivní hodnotu i její zdroj.

**Pravidlo precedence:** `ProcessDatabase` přebíjí `Process`. Pro jednoduché skalární sloupce (Mode, RetentionDays, BatchDocCount…) se použije

```sql
COALESCE(pd.<Sloupec>, p.<Sloupec>)
```

Pro textové sloupce (Anchor*, AppLockResource, DeadlockPriority, DocKeyLabel, AuditLevel, CandidateWhereSql/OrderSql…) se navíc prázdný/whitespace string považuje za „neuvedeno“:

```sql
COALESCE(NULLIF(LTRIM(RTRIM(pd.<Sloupec>)), N''), p.<Sloupec>)
```

Ke každému efektivnímu sloupci existuje doprovodný sloupec `<Sloupec>Source` typu `varchar(20)`/`varchar(30)` s hodnotou `'Process'` nebo `'ProcessDatabase'`, který říká, **odkud** efektivní hodnota pochází. Příklady: `ModeSource`, `RetentionDaysSource`, `AnchorTimestampExprSource`, `AuditLevelSource`, `CandidateOrderSqlSource`. To umožňuje UI i auditu zobrazit, která hodnota byla zděděná a která přebitá.

Speciální případy:

- `IsEnabled` = `CONVERT(bit, CASE WHEN p.IsEnabled = 1 AND pd.IsEnabled = 1 THEN 1 ELSE 0 END)` — efektivně zapnuto jen když je zapnutý proces **i** mapování. Pohled navíc vystavuje `ProcessIsEnabled` a `MappingIsEnabled` zvlášť.
- `SelectionStrategy` = `COALESCE(p.SelectionStrategy, N'ANCHOR')` — **bez** override z `pd` (a default `ANCHOR`, pokud by byl NULL). Nemá proto `SelectionStrategySource`.
- `DeadlockPriority` přebíjí přes `COALESCE(NULLIF(LTRIM(RTRIM(pd.DeadlockPriority)), N''), p.DeadlockPriority)`.

Analogický pohled `arch.v_ObjectSpecDatabaseEffective` spojuje `v_ProcessDatabaseEffective` s `arch.ObjectSpec` a `LEFT JOIN arch.ObjectSpecDatabaseOverride`, kde override (`osdo`) přebíjí `ObjectSpec` (`os`) podle stejného `COALESCE(NULLIF(...), ...)` vzoru. `ObjectIsEnabled` je `1`, pokud override neexistuje, nebo má `IsEnabled = 1`. Každý sloupec má `<Sloupec>Source` s hodnotou `'ObjectSpec'` nebo `'ObjectSpecDatabaseOverride'`.

---

### 8.6 `arch.RunProfile` — profily plánovaného běhu (kontext)

Nepatří přímo do definice procesu, ale rozhoduje, **které** procesy/DB se v daném běhu zpracují a s jakými limity. Jeden řádek na profil, PK `RunProfileId`, `UQ_RunProfile_Code` na `RunProfileCode`.

| Sloupec | Typ | Default | Význam |
|---|---|---|---|
| `RunProfileCode` | `sysname` | — | Kód profilu. UNIQUE. |
| `IsEnabled` | `bit` | `1` | Profil aktivní. |
| `RunOnSchedule` | `bit` | `0` (`DF_RunProfile_RunOnSchedule`) | Zda profil spouští plánovač (SQL Agent). |
| `RunOrder` | `int` | `100` | Pořadí profilů. |
| `ProcessCodeFilter` / `SourceDbFilter` / `ArchiveDbFilter` | `sysname` NULL | — | Filtry zúžení záběru profilu (NULL = vše). |
| `RunWindowMinutes` | `int` | `55` (`DF_RunProfile_RunWindowMinutes`) | Max. délka okna běhu. `CK_RunProfile_Limits`: `> 0`. |
| `DryRun` | `bit` | `0` (`DF_RunProfile_DryRun`) | Pouze náhled bez zápisu/mazání. |
| `MaxCandidates` | `int` NULL | — | Strop kandidátů. `> 0` pokud nenull. |
| `PausedCooldownSeconds` | `int` | `60` | Prodleva po pozastavení. `>= 0`. |

Index `IX_RunProfile_Schedule` na (`RunOnSchedule`, `IsEnabled`, `RunOrder`, `RunProfileCode`) slouží plánovači.

---

### 8.7 Příklad konfigurace — ANCHOR proces

Proces `RECEIVING` archivuje historii příjemek. Kotvou je hlavička `dbo.BACKRH` (dokument = `PO_NUM`), podřízenou tabulkou `dbo.BACKRD`. Mazání jde děti (`DeleteOrder=10`) před kotvou (`DeleteOrder=20`).

```sql
-- arch.Process (šablona)
INSERT arch.Process
    (ProcessCode, Description, IsEnabled, Mode, RetentionDays, CutoffSafetyLagMinutes,
     BatchDocCount, MaxBatchesPerRun, UseAppLock, LockTimeoutMs, DeadlockPriority,
     AnchorSchema, AnchorTable, AnchorDocKeyExpr, AnchorTimestampExpr,
     AllowDeleteWithoutArchive, CutoffMode, CutoffDate, DocKeyLabel,
     SelectionStrategy, AuditLevel, RequireSupportingIndex)
VALUES
    (N'RECEIVING', N'KArchiveManager - Purchase Order History', 1, 1, 540, 1440,
     500, 100, 1, 10000, N'LOW',
     N'dbo', N'BACKRH', N'PO_NUM',
     N'CAST(DATE_CREAT AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
     0, 0, '2024-01-01T00:00:00.000', N'PO_NUM',
     N'ANCHOR', N'BATCH', 1);

-- arch.ProcessKeySpec (klíč dokumentu)
INSERT arch.ProcessKeySpec (ProcessId, KeyOrdinal, KeyName, SourceExpressionSql, SqlType, IsRequired)
VALUES ((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'),
        1, N'PO_NUM', N'a.PO_NUM', N'nvarchar(256)', 1);

-- arch.ObjectSpec (2 tabulky, děti před rodičem)
INSERT arch.ObjectSpec (ProcessId, SourceSchema, SourceTable, DeleteOrder, DeleteMode,
    TimestampExpr, JoinToAnchorPredicateSql, ArchiveSchema, RequireArchiveForDelete, NaturalKeyLabel)
VALUES
 ((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'),
  N'dbo', N'BACKRD', 10, 1,
  N'CAST(DATE_CREAT AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
  N't.PO_NUM = k.Key1', N'{SourceDb}', 1, N'PO_NUM'),
 ((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'),
  N'dbo', N'BACKRH', 20, 1,
  N'CAST(DATE_CREAT AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
  N't.PO_NUM = k.Key1', N'{SourceDb}', 1, N'PO_NUM');

-- arch.ProcessDatabase (mapování na 3 DB, čistá dědičnost — vše NULL)
INSERT arch.ProcessDatabase (ProcessId, SourceDb, ArchiveDb, IsEnabled, RunOrder)
VALUES
 ((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'), N'Edge',     N'kArchiveManagerBackups', 1, 1010),
 ((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'), N'KMWEBV',   N'kArchiveManagerBackups', 1, 2010),
 ((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RECEIVING'), N'KMWE_Test',N'kArchiveManagerBackups', 1, 3010);
```

Klíčové body: `AnchorTimestampExpr` i `TimestampExpr` jsou UTC-normalizované přes `AT TIME ZONE`; cutoff je rolling (`CutoffMode=0`, `RetentionDays=540`); dávkování po dokumentech (`BatchDocCount=500`); mapování nepřebíjejí nic (všechny override sloupce `NULL`), takže `*Source` v `v_ProcessDatabaseEffective` budou `'Process'`.

---

### 8.8 Příklad konfigurace — TIMESTAMP proces

Proces `RF_LOG2` archivuje systémový log podle časového razítka přímo na tabulce `dbo.RF_LOG2` (bez kotvy). Dávkuje po řádcích a v reálném nasazení používá per-DB override na `KMWEBV`.

```sql
-- arch.Process (TIMESTAMP, žádné Anchor* sloupce)
INSERT arch.Process
    (ProcessCode, Description, IsEnabled, Mode, RetentionDays, CutoffSafetyLagMinutes,
     BatchRowCount, MaxBatchesPerRun, UseAppLock, LockTimeoutMs, DeadlockPriority,
     AllowDeleteWithoutArchive, CutoffMode, CutoffDate, DocKeyLabel,
     SelectionStrategy, AuditLevel, RequireSupportingIndex, MaxRowsPerTransaction, CandidateOrderSql)
VALUES
    (N'RF_LOG2', N'KArchiveManager - System log history', 1, 1, 540, 1440,
     50000, 20, 1, 10000, N'LOW',
     0, 0, '2024-01-01T00:00:00.000', N'ROWID',
     N'TIMESTAMP', N'NONE', 1, 50000, N'DocCreatedAt, Key1');

-- arch.ProcessKeySpec (jediná komponenta = ROWID)
INSERT arch.ProcessKeySpec (ProcessId, KeyOrdinal, KeyName, SourceExpressionSql, SqlType, IsRequired)
VALUES ((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RF_LOG2'),
        1, N'ROWID', N't.ROWID', N'nvarchar(256)', 1);

-- arch.ObjectSpec (jediná tabulka; join na klíč přes ROWID, filtr na razítko)
INSERT arch.ObjectSpec (ProcessId, SourceSchema, SourceTable, DeleteOrder, DeleteMode,
    TimestampExpr, JoinToAnchorPredicateSql, AdditionalWhereSql, ArchiveSchema, RequireArchiveForDelete, NaturalKeyLabel)
VALUES
 ((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RF_LOG2'),
  N'dbo', N'RF_LOG2', 10, 1,
  N'CAST(t.DATE_TIME AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''',
  N't.ROWID = k.Key1', N't.DATE_TIME IS NOT NULL', N'{SourceDb}', 1, N'ROWID');

-- arch.ProcessDatabase: KMWEBV s per-DB OVERRIDE (přebije šablonu jen pro tuto DB)
INSERT arch.ProcessDatabase
    (ProcessId, SourceDb, ArchiveDb, IsEnabled, RunOrder,
     Mode, RetentionDays, CutoffSafetyLagMinutes, CutoffMode, CutoffDate,
     BatchRowCount, MaxBatchesPerRun, DelayMsBetweenBatches, UseAppLock, LockTimeoutMs, DeadlockPriority,
     AuditLevel, RequireSupportingIndex, MaxRowsPerTransaction, CandidateOrderSql)
VALUES
 ((SELECT ProcessId FROM arch.Process WHERE ProcessCode=N'RF_LOG2'),
  N'KMWEBV', N'kArchiveManagerBackups', 1, 2030,
  1, 540, 1440, 0, '2024-01-01T00:00:00.000',
  50000, 20, 0, 1, 10000, N'LOW',
  N'ROW', 1, 50000, N'DocCreatedAt, Key1');
```

Klíčové body: `SelectionStrategy=TIMESTAMP`, takže `Anchor*` sloupce zůstávají `NULL` a kandidáti se odvozují z `TimestampExpr` na samotné tabulce; dávka se počítá v **řádcích** (`BatchRowCount=50000`) a transakce se chunkuje přes `MaxRowsPerTransaction=50000`; `CandidateOrderSql='DocCreatedAt, Key1'` zajišťuje deterministický postup; `AuditLevel` je v šabloně `NONE`, ale override na `KMWEBV` jej zvedá na `ROW`, takže `v_ProcessDatabaseEffective.AuditLevelSource` pro toto mapování vrátí `'ProcessDatabase'`, zatímco u mapování `Edge`/`KMWE_Test` (override `NULL`) vrátí `'Process'`.


---


## 9. Admin Console — architektura, API, bezpečnost

Admin Console je samostatná webová aplikace pro správu konfigurace, sledování běhů a řízení archivačních procesů kArchiveManager 2.0. Skládá se ze dvou částí nasazených jako jeden ASP.NET Core proces (typicky pod IIS):

- **Frontend SPA** (React / Vite) servírovaný jako statické soubory z `wwwroot`.
- **Backend minimal API** (ASP.NET Core) zapsané v `Program.cs` a `AdminConsoleEndpoints.cs`, které veškerou práci s databází deleguje na uložené procedury `arch.usp_Api_*` a `arch.usp_Frontend_*` přes třídu `SqlProcedureExecutor`.

Celý projekt je `KArchiveManager.AdminConsole.Api`; připojovací řetězec k administrační databázi nese jméno `ArchiveManagerAdmin` (DB `kArchiveManagerAdmin`).

### 9.1 Architektura — SPA + minimal API + SqlProcedureExecutor

#### Hostování SPA a fallback

V `Program.cs` se po sestavení aplikace zapojí statický obsah a fallback routa:

- `app.UseDefaultFiles()` + `app.UseStaticFiles()` — servírují buildnutou SPA z `wwwroot`.
- `app.MapFallback(...)` — vrací `index.html` pro libovolnou neznámou (ne-`/api`) cestu (klientský routing SPA). Pokud cesta začíná `/api`, vrací místo HTML JSON `404` `{ "error": "API endpoint was not found." }`. Pokud `index.html` neexistuje (frontend není publikován), vrací `404` `{ "error": "Admin Console frontend is not published." }`.
- `app.MapGet("/health", ...)` — jednoduchý liveness endpoint mimo `/api` prostor, vrací `{ service, status = "OK", utc }`.

#### Registrované služby (DI)

V `Program.cs` jsou jako singletony registrovány tři klíčové služby:

| Služba | Soubor | Role |
| --- | --- | --- |
| `SqlProcedureExecutor` | `Data/SqlProcedureExecutor.cs` | Jediná cesta k DB — volá uložené procedury / explicitní `SELECT`y, mapuje výsledky na `Dictionary<string, object?>`. |
| `ReadinessService` | `Data/ReadinessService.cs` | Readiness probe — ověřuje existenci objektů, rolí a EXECUTE oprávnění. |
| `EditSessionStore` | `Api/EditSecurity.cs` | Autentizace, edit-lock sessions, hashování hesel. |

#### SqlProcedureExecutor — žádné ad-hoc SQL z FE

`SqlProcedureExecutor` čte připojovací řetězec `ArchiveManagerAdmin` z konfigurace; chybí-li, vyhodí `InvalidOperationException` už při konstrukci. Třída poskytuje tři vstupní metody:

- `ExecuteAsync(procedureName, parameters, ct)` — spustí uloženou proceduru (`CommandType.StoredProcedure`). Veškeré endpointy katalogu používají právě tuto cestu — jména procedur jsou pevně dané konstanty v kódu a parametry se vždy předávají jako typované `SqlParameter` (žádná konkatenace uživatelského vstupu do SQL).
- `ExecuteTextAsync(commandText, parameters, ct)` — spustí `CommandType.Text` (interně využívají readiness kontroly přes parametrizované `SELECT`y).
- `ValidateProposedAsync(saveProcedure, saveParameters, processCode, sourceDb, ct)` — pre-save „dry run" (viz níže).

Společný `ExecuteCommandAsync`:

- otevírá novou `SqlConnection` per request (žádné sdílení),
- nastavuje `CommandTimeout = 120` s,
- přidává všechny `SqlParameter` přes `command.Parameters.Add(...)`,
- čte **všechny** result-sety (`do { ... } while (NextResultAsync)`), takže procedury vracející více tabulek jsou plně podporovány,
- názvy sloupců převádí na camelCase (`ToCamelCase`) a duplicitní názvy de-duplikuje příponou (`name`, `name2`, ...). Tím se výstup mapuje 1:1 na JSON klíče očekávané SPA.

`NULL` hodnoty z DB se mapují na `null`; vstupní `null`/prázdné stringy se na straně parametrů převádějí na `DBNull.Value` (helper `DbValue` / `DbNullable`).

#### Dry-run validace (`ValidateProposedAsync`)

Pre-save „what-if" mechanismus pro endpointy `/api/config/*/validate`:

1. otevře spojení a založí explicitní transakci (`BeginTransactionAsync`),
2. spustí navrženou **save** proceduru (např. `arch.usp_Api_SaveProcess`) v této transakci,
3. spustí `arch.usp_Api_ValidateConfiguration` se stejnou transakcí nad ještě **necommitnutým** stavem,
4. transakci **nikdy necommitne** — disposal ji rollbackne, takže se nic neperzistuje.

Pokud samotné aplikování návrhu selže (`SqlException` — porušení constraintu, `THROW` v proceduře), metoda nález nepropaguje jako chybu HTTP, ale vrací ho jako jeden řádek findings se `severity = "ERROR"` a textem `"Proposed change could not be applied: " + ex.Message`; doomed transakce se rollbackne.

#### Read vs write endpointy

| Vlastnost | Read endpointy | Write / akční endpointy |
| --- | --- | --- |
| Metoda | `GET` | `POST` |
| Příklady cest | `/api/dashboard/*`, `/api/config/*` (čtení), `/api/runs/recent|detail`, `/api/documents/search/*` | `/api/config/*` (zápis), `/api/runs/stop`, `/api/runs/restore`, `/api/validation/*` |
| Procedury | `arch.usp_Frontend_*` | `arch.usp_Api_*`, `arch.usp_RestoreFromArchive` |
| Autorizace | bez edit-locku (jen volitelný auth-floor `RequireAuthenticatedApi`) | **vyžadují** `security.IsAuthorized(http)` → jinak `423 Locked` |
| Optimistic concurrency | n/a | `EnsureUnchangedAsync` → případně `409 Conflict` |

Read endpointy se registrují přes `MapAdminConsoleReadEndpoints` (helpery `FirstResultSet` = vrátí první result-set, `AllResultSets` = `{ resultSets }` pro multi-set procedury). Filtry se čtou z query stringu přes `QueryFilters.From(http.Request.Query)`. Write a akční endpointy se registrují přes `MapAdminConsoleWriteEndpoints`, validační přes `MapAdminConsoleValidationEndpoints`.

### 9.2 Edit-lock model (X-Admin-Edit-Token, EditSessionStore)

Zápisy do konfigurace a destruktivní akce nejsou povoleny anonymně — vyžadují odemčenou edit session (nebo autorizovaného Windows uživatele). Model je implementován v `EditSessionStore`.

- **HTTP hlavička:** `X-Admin-Edit-Token` (konstanta `TokenHeader`). Klient po odemčení posílá token v této hlavičce u každého write requestu.
- **Token:** 32 náhodných bytů (`RandomNumberGenerator.GetBytes(32)`) zakódovaných do Base64. Sessions se drží v paměti v `ConcurrentDictionary<string, SessionEntry>` (ordinální porovnání). Session je tedy vázaná na běžící proces (po restartu se vymaže).
- **`SessionEntry`** nese `Username`, `DisplayName` a `ExpiresAt`.
- **Expirace:** doba session = `Math.Max(5, EditSessionMinutes)` minut od odemčení (clamp minimálně na 5 minut, default `60`). `SessionFor(token)` při čtení kontroluje expiraci a expirovanou session aktivně odstraní z dictionary (`TryRemove`).

Tok:

1. `POST /api/security/unlock` — `Unlock(username, password)` ověří přihlašovací údaje a vrátí `{ token, expiresAtUtc, username, displayName }` (nebo `null` → `401`).
2. SPA vkládá `token` do hlavičky `X-Admin-Edit-Token` u write volání.
3. Každý write endpoint na začátku volá `security.IsAuthorized(http)`; není-li autorizován, vrací `423 Locked` (`{ "error": "Configuration editing is locked.", ... }`).
4. `POST /api/security/lock` — `Lock(http)` odebere session pro token v hlavičce.
5. `GET /api/security/status` — `Status(http)` vrací stav UI (viz níže).

`Status(http)` vrací (mj.):

| Pole | Význam |
| --- | --- |
| `isConfigured` | je nakonfigurována nějaká heslová cesta nebo je uživatel Windows-autorizovaný |
| `isUnlocked` | Windows-autorizovaný **nebo** platná edit session |
| `windowsUser` | jméno přihlášeného Windows uživatele (nebo `null`) |
| `windowsAuthorized` | je tento Windows uživatel v allowlistu `AdminUsers` |
| `passwordConfigured` | je nastaveno shared password |
| `operatorsConfigured` | existují lokální operátoři |
| `operatorUser`, `operatorDisplayName` | identita aktivní operator-session (u shared-password session `null`) |
| `expiresAtUtc` | čas expirace session |
| `editSessionMinutes` | `Math.Max(5, EditSessionMinutes)` |

### 9.3 Autentizace — tři koexistující cesty

Konzole podporuje tři nezávislé, současně koexistující autentizační cesty. Konfigurace je v sekci `AdminConsole` (`EditSecurityOptions`).

| # | Cesta | Konfigurace | Mechanismus |
| --- | --- | --- | --- |
| 1 | **Windows allowlist** | `WindowsAuthEnabled = true` + `AdminUsers` (pole `DOMAIN\user`) | `IsWindowsAuthorized` — autentizovaná Windows identita (IIS Negotiate) musí být v allowlistu `AdminUsers` (case-insensitive). Bez hesla. Produkční cesta pod IIS. |
| 2 | **Lokální operátoři** | `Operators[]` (`Username` + `PasswordSha256` + volitelný `DisplayName` + `Enabled`) | `Unlock(username, password)` → `FindOperator` + `VerifyPassword`. Operátor **musí** mít uložený hash hesla — žádná plaintext cesta. |
| 3 | **Shared password fallback** | `EditPasswordSha256` (preferováno) nebo legacy plaintext `EditPassword` | `Unlock(null, password)` → `SharedPasswordMatches`. Jeden sdílený klíč pro odemčení (bez konkrétní identity). |

Windows autentizace se v `Program.cs` zapíná jen když `AdminConsole:WindowsAuthEnabled = true` (default). Pak se registruje `AddAuthentication(IISServerDefaults.AuthenticationScheme)` + `AddAuthorization()` a v pipeline `UseAuthentication()` / `UseAuthorization()`. V Developmentu (Kestrel bez IIS Windows-auth handleru) zůstává vypnutá, takže anonymní čtení a E2E mocky fungují.

#### Atribuce reálného uživatele (RequestedBy)

Audit atribuce (T-07) **nikdy nedůvěřuje** klientem poslanému `requestedBy` (je padělatelný). Skutečný aktér se odvozuje výhradně ze serveru v pevném pořadí priorit (helper `RequestedBy` v `AdminConsoleEndpoints.cs`):

```
security.AuthenticatedUser(http)        // edit session: lokální operátor NEBO Windows-AD uživatel
  ?? http.User.Identity?.Name           // surová Windows identita
  ?? Environment.UserName               // servisní účet (poslední záchyt)
```

`AuthenticatedUser(http)` vrací:
- jméno Windows uživatele, je-li `IsWindowsAuthorized`,
- jinak `Username` z edit session,
- ale u **shared-password** session vrací `null` (sdílené heslo nenese konkrétní identitu) — atribuce pak spadne na Windows identitu, resp. servisní účet.

Tato hodnota se předává do procedur jako parametr `@RequestedBy` (NVarChar 256). Parametr `request.RequestedBy` z těla requestu se v `RequestedBy(...)` záměrně ignoruje.

### 9.4 Hashování hesel — PBKDF2-HMAC-SHA256 (S2)

Implementace v `EditSessionStore` (`HashPassword` / `VerifyPassword` / `IsValidPasswordHash`).

**Formát uloženého hashe:**

```
PBKDF2-SHA256$<iterations>$<base64(salt)>$<base64(hash)>
```

- prefix `PBKDF2-SHA256$` (konstanta `Pbkdf2Prefix`),
- algoritmus `Rfc2898DeriveBytes.Pbkdf2` s `HashAlgorithmName.SHA256`,
- iterace při generování: `Pbkdf2Iterations = 100_000`,
- salt: `Pbkdf2SaltBytes = 16` náhodných bytů per hash,
- délka derivovaného klíče: `Pbkdf2HashBytes = 32`,
- ověření odolné proti časovému útoku: `CryptographicOperations.FixedTimeEquals`.

`HashPassword` vygeneruje nový salt a vrátí kompletní řetězec. `VerifyPassword` parsuje 4 části, čte iteraci a salt **přímo z uloženého hashe** (ne z konstanty) a porovnává v konstantním čase.

**Legacy SHA-256 fallback:** pro zpětnou kompatibilitu se stále ověřuje i nesolený SHA-256 hex (přesně 64 hex znaků). Detekuje se podle toho, že hodnota **nezačíná** prefixem `PBKDF2-SHA256$`. Porovnání běží přes `FixedTimeEquals` nad `Sha256Hex(password)`. Doporučení v kódu: legacy hodnoty regenerovat jako PBKDF2.

**`IsValidPasswordHash(stored)`** validuje, že je hodnota dobře utvořený hash:
- buď PBKDF2 řetězec se 4 částmi, kladnou iterací v rozsahu `(0, Pbkdf2MaxIterations]` a base64-parsovatelným saltem i hashem,
- nebo legacy 64-znakový SHA-256 hex (`Uri.IsHexDigit`).

To dovoluje hostiteli **fail-fast** na chybně vloženém hashi místo tichého zamčení konzole při unlocku.

**Iteration clamp 10M — proč nepinujeme na konstantu:** horní mez `Pbkdf2MaxIterations = 10_000_000`. Iterace se záměrně **nepinuje** na `Pbkdf2Iterations`, protože vložení iterace do samotného hashe je to, co umožňuje časem zvyšovat work-faktor a přitom dál ověřovat staré hashe (standardní PBKDF2/PHC praxe). Cap pouze blokuje patologickou hodnotu (např. ručně dopsaná `2e9`), která by z každého ověření udělala CPU-DoS.

### 9.5 RequireAuthenticatedApi a fail-fast v Production (T-34)

Volitelný „auth floor" nad `/api/*`. Klíč `AdminConsole:RequireAuthenticatedApi` (default = hodnota `WindowsAuthEnabled`) — auto-zapne se v produkci spolu s IIS Windows Auth a zůstane vypnutý pod dev Kestrelem.

Když je zapnutý, middleware v `Program.cs` vyžaduje autentizovaného principala (Windows identita **nebo** platný edit token přes `security.IsAuthorized(context)`) pro každé volání `/api/*` **kromě** readiness probe a security bootstrapu:

- vyňato: `/api/readiness`, `/api/security` (status/unlock/lock),
- jinak: `401 Unauthorized` s `{ error = "Authentication required.", detail = ... }`.

**Tři podmínky odmítnutí startu v Production** (`builder.Environment.IsProduction()`):

1. `RequireAuthenticatedApi = false` → `InvalidOperationException` — odmítá spustit anonymní `/api` plochu (vč. nevratných stop/restore endpointů). Brání tomu, aby config-slip (např. `WindowsAuthEnabled=false`) tiše otevřel API.
2. `RequireAuthenticatedApi = true`, ale **žádná auth cesta není reálně nakonfigurována** (žádný Windows allowlist se zapnutým `WindowsAuthEnabled`, žádný enabled operátor s username+hashem, žádné shared heslo) → `InvalidOperationException` — odmítá spustit konzoli, kterou nikdo nemůže obsluhovat.
3. **Malformed hash** — pokud má enabled operátor `PasswordSha256`, který neprojde `IsValidPasswordHash`, nebo je vadné `EditPasswordSha256` → `InvalidOperationException` s instrukcí regenerovat hash CLI `hash-password "<password>"`. Brání stavu, kdy „nějaká auth cesta existuje", ale za běhu tiše odmítá každý unlock.

### 9.6 Rate-limiter na unlock (S1)

Brute-force obrana na endpointu unlock. V `Program.cs`:

- politika `"unlock"` přes `RateLimitPartition.GetFixedWindowLimiter`,
- partition key = `http.Connection.RemoteIpAddress` (per IP; fallback `"unknown"`),
- `PermitLimit = 5`, `Window = TimeSpan.FromMinutes(5)`, `QueueLimit = 0`,
- `RejectionStatusCode = 429` (`StatusCodes.Status429TooManyRequests`).

Aplikuje se jen na `POST /api/security/unlock` přes `.RequireRateLimiting("unlock")`. Neúspěšné pokusy se navíc logují jako `Warning` se zdrojovou IP (u shared hesla `"(shared password)"`), takže je brute-force pozorovatelný.

### 9.7 SqlErrorClassifier — mapování SqlException → HTTP (T-26)

Globální exception middleware v `Program.cs` zachytává `SqlException` (jen pokud `!Response.HasStarted`), promítne `exception.Errors` na dvojice `(Number, Class)` a předá je `SqlErrorClassifier.Classify(...)` (`Api/SqlErrorClassifier.cs`). Klasifikace je čistá funkce nad n-ticemi (kvůli jednotkové testovatelnosti — `SqlException`/`SqlError` nemají veřejný konstruktor).

Pravidla a priorita (vyhrává v tomto pořadí: BusinessRule → Transient → PermissionDenied → Unavailable):

| Kategorie | Detekce (Number / Class) | HTTP | Tělo / chování |
| --- | --- | --- | --- |
| `BusinessRule` | `Number >= 50000` **nebo** `Class == 16` | `400` | `{ error = "Configuration change rejected.", detail = exception.Message, traceId }`. Záměrný `THROW`/`RAISERROR` z procedury → ukáže se zpráva. Loguje se `Information`. |
| `Transient` | `Number ∈ {1205, 1222, -2}` (deadlock victim / lock-request timeout / command timeout) | `503` | hlavička `Retry-After: 2`; `{ error = "Database is busy.", detail = ..., traceId }`. Loguje se `Warning`. |
| `PermissionDenied` | `Number ∈ {229, 230, 262, 297, 300}` | `500` | `{ error = "Server configuration error.", detail = "A required database permission is missing. ...", traceId }`. Nikdy neprozradí, které oprávnění/objekt chybí; loguje se `Error` (server-side misconfig, ne klientská chyba). |
| `Unavailable` (default) | cokoli ostatní | `503` | `{ error = "Database call failed.", detail = "Check ConnectionStrings:ArchiveManagerAdmin ...", traceId }`. Loguje se `Error`. |

Ostatní (ne-SQL) výjimky spadají do druhého `catch (Exception ...)` → `500` `{ error = "API call failed.", detail = "Review API logs ...", traceId }`. Tím se odstranil dřívější stav, kdy deadlock/timeout/permission-denied padaly do zavádějícího `503` „check ConnectionStrings", i když byla DB dostupná.

### 9.8 CORS (AllowCredentials)

CORS se zapíná jen když je v `Cors:AllowedOrigins` aspoň jeden origin. Default policy:

- `WithOrigins(allowedOrigins)` — **explicitní** seznam originů,
- `AllowAnyHeader()`, `AllowAnyMethod()`,
- `AllowCredentials()` — SPA posílá s `fetch` credentials (Windows/Negotiate token), proto je třeba `Access-Control-Allow-Credentials`. To je validní jen díky explicitním originům (wildcard `*` je s credentials nekompatibilní).

Příklad `appsettings.json`:

```json
"Cors": {
  "AllowedOrigins": [
    "http://localhost:5173",
    "http://127.0.0.1:5173"
  ]
}
```

### 9.9 CLI hash-password

`Program.cs` na začátku rozpozná CLI režim ještě před stavbou web hostu:

```bash
dotnet run --project <ApiProject> -- hash-password "the-password"
```

Při argumentech `["hash-password", "<password>"]` vypíše `EditSessionStore.HashPassword(...)` (PBKDF2 řetězec) na `stdout` a skončí. Slouží ke generování hashe pro `AdminConsole:EditPasswordSha256` i pro `Operators[].PasswordSha256`.

### 9.10 Readiness probe (ReadinessService)

`GET /api/readiness` → `ReadinessService.CheckAsync` vrací `ReadinessResult`. Probe ověří, že je administrační DB nasazená a že připojující se identita má potřebná oprávnění:

- otevře spojení a načte `DB_NAME()`, `DATABASEPROPERTYEX(..., 'Collation')`, `ORIGINAL_LOGIN()`, `USER_NAME()`, `COUNT(*)` z `arch.Process` a `arch.ProcessDatabase`,
- `MissingObjectsAsync` — pro každý objekt z pevného seznamu `requiredObjects` ověří `OBJECT_ID(@ObjectName)` (procedury `arch.usp_Frontend_*` i `arch.usp_Api_*` vč. `arch.usp_Api_RequestRunStop` a `arch.usp_RestoreFromArchive`),
- `MissingRolesAsync` — `DATABASE_PRINCIPAL_ID(@RoleName)` pro role `karch_viewer`, `karch_operator`, `karch_config_admin`, `karch_advanced_admin`,
- `MissingExecutePermissionsAsync` — `HAS_PERMS_BY_NAME(@ObjectName, 'OBJECT', 'EXECUTE')` (T-02): ověří, že připojená identita má EXECUTE na požadované procedury — chybějící GRANT se tak projeví na `/api/readiness` při startu, ne až jako `503` po kliknutí.

`DatabaseOk = true` jen když jsou všechny tři seznamy „missing" prázdné. Výjimka při kontrole → `ApiOk = true`, `DatabaseOk = false` a `Error` s nápovědou (`Check ConnectionStrings:ArchiveManagerAdmin, SQL deployment, and EXECUTE permissions ...`). Probe je vyňata z auth-flooru i edit-locku.

### 9.11 Katalog hlavních endpointů

Autorizace značí: *Read-floor* = jen volitelný `RequireAuthenticatedApi`; *Edit-lock* = navíc `security.IsAuthorized` → jinak `423`; *Veřejné* = vyňato z auth-flooru.

#### Bezpečnost a readiness

| Metoda | Cesta | Procedura / akce | Autorizace |
| --- | --- | --- | --- |
| GET | `/api/readiness` | `ReadinessService.CheckAsync` | Veřejné |
| GET | `/api/security/status` | `EditSessionStore.Status` | Veřejné |
| POST | `/api/security/unlock` | `EditSessionStore.Unlock` (rate-limit 5/5min/IP, `429`) | Veřejné |
| POST | `/api/security/lock` | `EditSessionStore.Lock` | Veřejné |
| GET | `/health` | liveness (mimo `/api`) | Veřejné |

#### Dashboard / read (`arch.usp_Frontend_*`)

| Metoda | Cesta | Procedura | Autorizace |
| --- | --- | --- | --- |
| GET | `/api/dashboard/process-config` | `arch.usp_Frontend_GetProcessConfigSummary` | Read-floor |
| GET | `/api/dashboard/table-counts` | `arch.usp_Frontend_GetTableMovementCounts` | Read-floor |
| GET | `/api/dashboard/process-summary` | `arch.usp_Frontend_GetProcessMovementSummary` | Read-floor |
| GET | `/api/dashboard/processed-history` | `arch.usp_Frontend_GetProcessedHistory` | Read-floor |
| GET | `/api/dashboard/workbatches` | `arch.usp_Frontend_GetWorkBatchActivity` | Read-floor |
| GET | `/api/config/effective/process-databases` | `arch.usp_Frontend_GetEffectiveProcessDatabases` | Read-floor |
| GET | `/api/config/effective/objects` | `arch.usp_Frontend_GetEffectiveObjects` | Read-floor |
| GET | `/api/config/keys` | `arch.usp_Frontend_GetProcessKeySpecs` | Read-floor |
| GET | `/api/config/indexes` | `arch.usp_Frontend_GetIndexRequirements` | Read-floor |
| GET | `/api/config/run-profiles` | `arch.usp_Frontend_GetRunProfiles` | Read-floor |
| GET | `/api/config/selection-strategies` | `arch.usp_Frontend_GetSelectionStrategies` | Read-floor |
| GET | `/api/config/change-history` | `arch.usp_Frontend_GetConfigChangeHistory` (multi-set) | Read-floor |
| GET | `/api/documents/search/summary` | `arch.usp_Frontend_SearchDocumentAuditSummary` | Read-floor |
| GET | `/api/documents/search/details` | `arch.usp_Frontend_SearchDocumentAuditDetails` | Read-floor |
| GET | `/api/runs/recent` | `arch.usp_Frontend_GetRecentRuns` | Read-floor |
| GET | `/api/runs/detail` | `arch.usp_Frontend_GetRunDetail` (multi-set) | Read-floor |
| GET | `/api/golive-readiness` | `arch.usp_Frontend_GoLiveReadiness` | Read-floor |

#### Validace (`arch.usp_Api_*`, POST bez edit-locku)

| Metoda | Cesta | Procedura | Autorizace |
| --- | --- | --- | --- |
| POST | `/api/validation/configuration` | `arch.usp_Api_ValidateConfiguration` | Read-floor |
| POST | `/api/validation/indexes` | `arch.usp_Api_ValidateIndexRequirements` | Read-floor |
| POST | `/api/validation/explain-plan` | `arch.usp_Api_ExplainProcessPlan` (multi-set; `processCode` povinný → jinak `400`) | Read-floor |

#### Zápis konfigurace (`arch.usp_Api_*`, vyžaduje edit-lock)

| Metoda | Cesta | Procedura | Autorizace |
| --- | --- | --- | --- |
| POST | `/api/config/processes` | `arch.usp_Api_SaveProcess` | Edit-lock + concurrency |
| POST | `/api/config/process-databases` | `arch.usp_Api_SaveProcessDatabase` | Edit-lock + concurrency |
| POST | `/api/config/objects` | `arch.usp_Api_SaveObjectSpec` | Edit-lock + concurrency |
| POST | `/api/config/object-overrides` | `arch.usp_Api_SaveObjectSpecOverride` | Edit-lock + concurrency |
| POST | `/api/config/run-profiles` | `arch.usp_Api_SaveRunProfile` | Edit-lock + concurrency |
| POST | `/api/config/process-key-specs` | `arch.usp_Api_SaveProcessKeySpec` | Edit-lock + concurrency |
| POST | `/api/config/index-requirements` | `arch.usp_Api_SaveIndexRequirement` | Edit-lock + concurrency |
| POST | `/api/config/processes/set-enabled` | `arch.usp_Api_SetProcessEnabled` | Edit-lock |
| POST | `/api/config/process-databases/set-enabled` | `arch.usp_Api_SetProcessDatabaseEnabled` | Edit-lock |
| POST | `/api/config/object-overrides/set-enabled` | `arch.usp_Api_SetObjectOverrideEnabled` | Edit-lock |
| POST | `/api/config/run-profiles/set-enabled` | `arch.usp_Api_SetRunProfileEnabled` | Edit-lock |
| POST | `/api/config/processes/validate` | `usp_Api_SaveProcess` (dry-run rollback) | Edit-lock |
| POST | `/api/config/process-databases/validate` | `usp_Api_SaveProcessDatabase` (dry-run rollback) | Edit-lock |
| POST | `/api/config/objects/validate` | `usp_Api_SaveObjectSpec` (dry-run rollback) | Edit-lock |
| POST | `/api/config/object-overrides/validate` | `usp_Api_SaveObjectSpecOverride` (dry-run rollback) | Edit-lock |

#### Řízení běhů (akční, vyžaduje edit-lock)

| Metoda | Cesta | Procedura | Autorizace |
| --- | --- | --- | --- |
| POST | `/api/runs/stop` | `arch.usp_Api_RequestRunStop` (kooperativní stop; `runId` povinný → jinak `400`) | Edit-lock |
| POST | `/api/runs/restore` | `arch.usp_RestoreFromArchive` (`DryRun` default `true`; `processCode`+`sourceDb`+`archiveDb` povinné → jinak `400`) | Edit-lock |

Poznámky k akčním endpointům:
- **Stop** stampne `arch.Run.CancelRequestedAtUtc`, takže batch worker po dokončení aktuální dávky elegantně skončí.
- **Restore**: Admin Console **nikdy** nepředává klientem zadaný purge flag — `@PurgeArchive` je natvrdo `false` (T-27). Mazání archivu (jediné přeživší kopie řádků) je jen DBA-only přes přímý `EXEC` a navíc hlídané v `usp_RestoreFromArchive` (`karch_approver` + `AuditLevel >= ROW` + audit log).

### 9.12 Optimistic concurrency u zápisů

Save endpointy s `ExpectedModifiedAt` volají před vlastním uložením `EnsureUnchangedAsync` → `arch.usp_Api_CheckConfigConcurrency` (s parametry `@EntityType`, klíče entity a `@ExpectedModifiedAt`). Podle vráceného `state`:

- `state == 0` → beze změny, pokračuje se k save,
- `state == 404` (řádek nenalezen) nebo jiný (řádek změněn po otevření editoru) → `409 Conflict` s tělem `{ error = "Configuration row changed.", detail, entityType, expectedModifiedAt, currentModifiedAt }`.

To brání ztrátě cizích změn (lost update) při souběžné editaci.

### 9.13 Příklad konfigurace (`appsettings.json`)

```json
{
  "ConnectionStrings": {
    "ArchiveManagerAdmin": "Server=...;Database=kArchiveManagerAdmin;Trusted_Connection=True;TrustServerCertificate=True;"
  },
  "AdminConsole": {
    "EditPasswordSha256": "PBKDF2-SHA256$100000$<base64-salt>$<base64-hash>",
    "EditSessionMinutes": 60,
    "WindowsAuthEnabled": true,
    "RequireAuthenticatedApi": true,
    "AdminUsers": [ "KODYS\\radim.stachal" ],
    "Operators": [
      {
        "Username": "operator1",
        "PasswordSha256": "PBKDF2-SHA256$100000$<base64-salt>$<base64-hash>",
        "DisplayName": "Operátor 1",
        "Enabled": true
      }
    ]
  }
}
```

Příklad write requestu (uložení procesu s odemčenou session):

```http
POST /api/config/processes
Content-Type: application/json
X-Admin-Edit-Token: <token z /api/security/unlock>

{
  "processCode": "RECEIVING",
  "changeReason": "úprava retence",
  "isEnabled": true,
  "retentionDays": 540,
  "expectedModifiedAt": "2026-06-10T12:00:00"
}
```


---


## 10. Admin Console — funkce a obrazovky

Admin Console je single-page React aplikace (`KArchiveManager.AdminConsole.Web`, Vite + TypeScript), kterou obsluhuje minimal-API backend (`KArchiveManager.AdminConsole.Api`, ASP.NET Core). Aplikace je čistě nadstavbou nad uloženými procedurami v schématu `arch`: backend nemá žádnou business logiku, pouze mapuje HTTP endpointy na `EXEC arch.usp_*` a vrací jejich result-sety jako JSON. Frontend tyto JSON řádky vykresluje v tabulkách, grafech a editoru.

### 10.1 Layout aplikace a sdílené prvky

Kořenová komponenta `App.tsx` drží veškerý stav obrazovek (filtry, načtená data, edit-token, readiness, security status) a vykresluje stabilní rámec (`app-shell`):

| Oblast | Obsah |
|--------|-------|
| `sidebar` | Logo KODYS + levá navigace (`navItems` z `constants/navigation.ts`) |
| `topbar` | Titulek aktivní obrazovky, **EditLockControl** (zámek úprav), **ReadinessBadge** |
| `filter-bar` | Kontextové filtry: Process (select), Source DB / Archive DB (`ComboInput`), checkbox **Include disabled**, tlačítko **Refresh** |
| `ReadinessPanel` | Řádek se stavem DB (OK/varování) — viditelný jen když je `readiness` načteno |
| `notice` | Pruh s hláškou (tone `success`/`info`/`error`, ARIA `alert`/`status`) |
| `ErrorBoundary` | Obaluje aktivní view; klíčováno `${activeView}:${navNonce}` — pád jedné obrazovky neshodí celou aplikaci |

Navigace (`navItems`) má 7 položek mapovaných na `ViewKey`:

| `ViewKey` | Štítek (label) | Ikona |
|-----------|----------------|-------|
| `dashboard` | Dashboard | `BarChart3` |
| `rfl` | RF/L charts | `ChartSpline` |
| `runs` | Runs | `PlayCircle` |
| `lookup` | Document lookup | `FileSearch` |
| `configuration` | Configuration | `Settings2` |
| `validation` | Validation | `ShieldCheck` |
| `golive` | Go-live | `Rocket` |

Vlastnosti rámce:

- **Filtry jsou persistované** do `localStorage` pod klíčem `karchive-admin-console.filters`; čtou se při startu (`readInitialFilters`). Filtr Process/Source/Archive se promítá do query parametrů `processCode`/`sourceDb`/`archiveDb` u většiny GET volání.
- **Hluboké odkazy přes hash** — aktivní obrazovka se zrcadlí do `window.location.hash` (`#runs`, `#configuration`, …; Dashboard = prázdný hash). Při startu `readInitialView` obnoví obrazovku z hashe.
- **`navNonce`** — každý klik v levé navigaci zvýší `navNonce`; ten je součástí klíče `ErrorBoundary`, takže se aktivní view remountuje (zavře případně otevřený editor → zpět na přehled) a znovu se spustí jeho data-efekty.
- **Race-safe načítání** — každé načtení má `requestId` (`beginRequest`/`isCurrentRequest`/`finishRequest`); pozdě dorazivší odpověď se zahodí, takže rychlé přepínání filtrů nezpůsobí přepsání novějších dat staršími.
- **Periodický readiness polling** — `apiReadiness()` se volá každých 30 s (`setInterval(..., 30_000)`) a aktualizuje badge i panel nezávisle na ostatních datech.

`DataTable` (`components/DataTable.tsx`) je sdílená tabulka: klikatelné hlavičky pro řazení (`A-Z`/`Z-A`, numericky i datumově), volitelný `onRowClick` + `selectedRow`, klávesová obsluha (Enter/Space) a automatické **badge** pro sloupce obsahující `status`/`severity` (zelená pro `OK/SUCCESS/PUBLISHED/INFO`, červená pro `FAILED/ERROR/CRITICAL`, oranžová pro `WARNING/WARN/DRYRUN/RUNNING/PREP/STOPPED`). `ExportCsvButton` (`components/ExportCsvButton.tsx`) je u většiny panelů a exportuje právě zobrazené řádky do CSV (`utils/csvExport`), zakázán při 0 řádcích.

### 10.2 Dashboard

Komponenta `DashboardView.tsx`. Provozní přehled celé instalace. Vrchní pruh metrik (`Metric`): **Active processes**, **Source rows**, **Archived rows**, **Recent non-OK runs**. Následují `DashboardSignals` a `DashboardCharts` a čtyři panely s tabulkami:

| Panel | Sloupce (klíče) | Akce |
|-------|-----------------|------|
| Process movement | `processCode`, `sourceDb`, `archiveDb`, `sourceRows`, `archivedRows`, `differenceCount`, `objectCount` | Export CSV |
| Prep / run activity | `workBatchId`, `processCode`, `status`, `candidateRows`, `preparedAtUtc` | klik na řádek → `onOpenWorkbatch` (přejde na Runs) |
| Recent runs | `runItemId`, `processCode`, `sourceDb`, `status`, `docsDone`, `rowsArchived`, `rowsDeleted`, `startedAt` | `StatusFilter`, klik → `onOpenRun` |
| Table counts | `processCode`, `sourceTable`, `archiveTable`, `sourceRows`, `archivedRows`, `sourceObjectExists`, `archiveObjectExists` | Export CSV |

Data dashboardu se načítají hromadně v `loadDashboard()` jedním `Promise.all` z těchto endpointů (a tedy procedur):

| Endpoint | Procedura |
|----------|-----------|
| `GET /api/readiness` | `ReadinessService` (viz 10.9) |
| `GET /api/dashboard/process-config` | `arch.usp_Frontend_GetProcessConfigSummary` |
| `GET /api/dashboard/process-summary` | `arch.usp_Frontend_GetProcessMovementSummary` |
| `GET /api/dashboard/table-counts` | `arch.usp_Frontend_GetTableMovementCounts` |
| `GET /api/dashboard/processed-history` | `arch.usp_Frontend_GetProcessedHistory` |
| `GET /api/runs/recent` (`top=50`) | `arch.usp_Frontend_GetRecentRuns` |
| `GET /api/dashboard/workbatches` (`top=50`) | `arch.usp_Frontend_GetWorkBatchActivity` |
| `GET /api/config/effective/process-databases` | `arch.usp_Frontend_GetEffectiveProcessDatabases` |
| `POST /api/validation/configuration` | `arch.usp_Api_ValidateConfiguration` (pro souhrn chyb/varování; selhání tolerováno → `null`) |

Kliknutí na řádek workbatch (`openWorkbatchFromDashboard`) předvyplní filtry podle `processCode`/`sourceDb`/`archiveDb`, přepne na **Runs** a dotáhne nejbližší související běh (`/api/runs/recent` `top=1`). Kliknutí na běh (`openRunFromDashboard`) přepne na Runs a načte detail.

### 10.3 RF/L charts (denní archivace)

Komponenta `RflChartsView.tsx`. Dedikovaná obrazovka grafů pro RF/L procesy (logy z mobilních terminálů). Data sdílí s dashboardem (`DashboardData`) — nemá vlastní API volání. Řádky se filtrují přes `isRflRow()` podle `processCode`/tabulky (`RF_LOG2`, `INTEGRACE_DNLOAD`, `INTEGRACE_UPLOAD`, `WA_AAD`, `DNLOAD`, `UPLOAD`).

Horní KPI dlaždice: **RF/L mapped tables**, **RF/L source rows**, **RF/L archived rows**, **RF/L runs**. Pak sdílené `DashboardCharts` a vlastní mřížka sloupcových grafů (CSS bary, ne externí knihovna). Datovým zdrojem je `processed-history` (skutečně přenesené řádky), s **fallbackem na `table-counts`** (`No run yet …`), když ještě žádný běh neproběhl:

| Graf (interní název) | Osa / agregace | Hodnota |
|----------------------|----------------|---------|
| `chartDailyArchivedByProcess` | den \| source DB.proces | `processedRows` |
| `chartDailyArchivedByTable` | den \| source DB.tabulka | `processedRows` |
| `chartProcessedByRunDayAndTable` | den \| tabulka (dvojitý bar) | `processedRows` vs `rowsArchived` |
| `chartProcessedByCutoffAndTable` | cutoff \| tabulka | `processedRows` |
| `chartDeleteBacklogByDay` | source DB (jen `SHIPHIST`) | `differenceCount` (backlog ke smazání) |

Pod grafy jsou dvě tabulky: **Dopady aktuální RUN dávky (odhad)** (`buildLatestBatchImpact` — odhad řádků/MB/% DB pro poslední workbatch, hrubý odhad `1024 B/řádek`) a **RF/L latest movement rows** (detail `processed-history`). Každý graf i tabulka má vlastní **Export CSV**.

### 10.4 Runs — detail běhu, Stop run, Restore

Komponenta `RunsView.tsx`. Horní panel **Runs** zobrazuje `dashboard.recentRuns` se sloupci `runId`, `runItemId`, `processCode`, `sourceDb`, `archiveDb`, `modeName`, `status`, `startedAt`, `endedAt`, odvozená **Duration**, `batchesDone`, `docsDone`, `processedRows`, `errorMessage`. Filtruje se checkboxem **Only non-OK** a `StatusFilter`. Klik na řádek → `loadRunDetail`.

Detail (`loadRunDetail`) volá `GET /api/runs/detail` (`arch.usp_Frontend_GetRunDetail`, `AllResultSets`) a rozkládá 5 result-setů do panelů:

| Result-set | Panel | Vybrané sloupce |
|-----------|-------|-----------------|
| `[0]` | **Run detail** (DetailItem grid) | `runId`, `status`, `sourceDb`, `archiveDb`, `startedAt`, `endedAt`, Duration, Rows |
| `[1]` | **Run items** | `runItemId`, `processCode`, `modeName`, `status`, `batchesDone`, `docsDone`, `rowsDeleted`, `rowsArchived`, `errorMessage` |
| `[2]` | **Object movement** | `runItemObjectId`, `sourceSchema`, `sourceTable`, `rowsDeleted`, `rowsArchived`, `loggedAt` |
| `[3]` | **Document audit** | `runDocAuditId`, `docKeyLabel`, `docKey`, `archived`, `deletedAt` |
| `[4]` | **Work batches** | `workBatchId`, `status`, `preparedAtUtc`, `startedAtUtc`, `completedAtUtc`, `lastKey1` |

Detail má **QuickFilter** (full-text přes hodnoty řádku) a každý panel **Export CSV** + `CountChip` (zobrazeno/celkem).

**Stop run** — tlačítko se zobrazí jen pro vybraný běh ve stavu `RUNNING`. Vyžaduje odemčené úpravy (jinak `info` hláška). Po `window.confirm` volá `POST /api/runs/stop` (`arch.usp_Api_RequestRunStop`) s `editToken` v hlavičce. Jde o **kooperativní stop**: backend nastaví `arch.Run.CancelRequestedAtUtc` a worker se po dokončení aktuální dávky korektně zastaví (Status `STOPPED`); již zarchivované řádky zůstávají, zbytek lze později obnovit. Procedura persistuje `CancelRequestedBy`/`CancelReason` (first-writer-wins). Výsledek nese `accepted` (true/1) a `message`; po akci se obnoví dashboard.

**Restore from archive** — tlačítko pro vybraný běh, vyžaduje odemčení. Dvoukrokově:

1. **Dry-run preview** — `POST /api/runs/restore` s `dryRun: true` (`arch.usp_RestoreFromArchive`). Sečte `restorableRows`; je-li ≤ 0, jen `info` hláška (archiv prázdný nebo už v zdroji).
2. **Potvrzení** — `window.confirm` (varuje, že řádky starší než cutoff mohou být při příštím běhu znovu zarchivovány), pak `dryRun: false`. Sečte `restoredRows` a zobrazí výsledek; obnoví dashboard.

Backend u restore **nikdy nepředává klientský purge flag** — natvrdo posílá `@PurgeArchive = false` (T-27). Smazání (purge) archivu je výhradně DBA akce přímým `EXEC` a je dodatečně chráněno v proceduře (`karch_approver` + `AuditLevel >= ROW` + audit log).

### 10.5 Configuration — prohlížení procesů, DB a objektů

Komponenta `ConfigurationView.tsx`. Read-only prohlížení efektivní konfigurace; každá tabulka je zároveň vstupem do editoru (klik na řádek otevře `ConfigurationEditor`, pokud je odemčeno). Načítá `loadConfiguration()` paralelně:

| Panel | Endpoint | Procedura | Editor entity |
|-------|----------|-----------|---------------|
| Process configuration | `GET /api/config/effective/process-databases` *(processRows = `dashboard.processConfig`)* | `arch.usp_Frontend_GetProcessConfigSummary` | `process` |
| Database mappings | `GET /api/config/effective/process-databases` | `arch.usp_Frontend_GetEffectiveProcessDatabases` | `processDatabase` |
| Effective objects | `GET /api/config/effective/objects` | `arch.usp_Frontend_GetEffectiveObjects` | `objectSpec` / `objectOverride` |
| Process keys | `GET /api/config/keys` | `arch.usp_Frontend_GetProcessKeySpecs` | `processKey` |
| Index requirements | `GET /api/config/indexes` | `arch.usp_Frontend_GetIndexRequirements` | `indexRequirement` |
| Run profiles | `GET /api/config/run-profiles` | `arch.usp_Frontend_GetRunProfiles` | `runProfile` |
| Change history | `GET /api/config/change-history` (`top=20`) | `arch.usp_Frontend_GetConfigChangeHistory` | — (viz 10.8) |

Nahoře je výběr **Process** + **Quick filter** (full-text přes všechny hodnoty řádku) a panel **Process detail** s rychlým přehledem (Strategy, Audit, Retention, Mappings, Objects). Panel **Effective objects** má navíc tlačítko **Override** — otevře editor `objectOverride` pro vybraný objekt (per-DB customizace) místo základního `objectSpec`.

Když **nejsou odemčeny úpravy**, zobrazí se `inline-warning` „Configuration editing is locked.“ a `openEditor` je no-op (řádky nelze otevřít k editaci). Na optimistic-concurrency konflikt (HTTP 409) `ConfigurationView` editor zavře (operátor jej znovu otevře nad čerstvými daty).

### 10.6 Editor konfigurace — 4-eyes potvrzení, validace, Explain plan, Suggested SQL

Komponenta `ConfigurationEditor.tsx`. Generický editor řízený deklarací `configEntityDefinitions` (7 entit: `process`, `processDatabase`, `objectSpec`, `objectOverride`, `processKey`, `indexRequirement`, `runProfile`). Každá definice nese: `title`, `endpoint`, seznam polí (`fields`), identitní klíče, `payloadKeys`, `modifiedAtKey` (concurrency token), `auditEntityType` + `auditKey` (mapování na `arch.ConfigChangeItem`). Typy polí: `text`, `number`, `checkbox`, `select`, `date`, `textarea`, `sql`.

**Pracovní tok editoru (dvě fáze — „Review changes“ → „Confirm save“):**

1. Operátor mění pole; `diffRows()` průběžně počítá rozdíl proti původnímu řádku (panel **DiffTable**: Field / Before / After / Risk). `dirty` = existuje aspoň jeden rozdíl.
2. Povinný **Change reason** (`ChangeReasonField`) — uložení blokováno, dokud nemá ≥ 6 znaků (`changeReason.trim().length < 6`).
3. První klik na tlačítko (popisek **„Review changes“**) přepne `reviewReady` a spustí **pre-save validaci** (viz níže). Druhý klik (popisek **„Confirm save“**) sestaví payload a volá `onSave`.
4. `saveDisabled` je true, dokud není splněno vše: žádný `unavailableReason`, nechybí identitní klíče, je `dirty`, reason ≥ 6 znaků, potvrzeno nebezpečí (pokud je), žádné ERROR `proposalIssues`, vyplněna všechna povinná pole.

**Potvrzení nebezpečných změn (4-eyes / informed consent).** Pole mohou mít `dangerousWhen`; pokud diff obsahuje nebezpečnou změnu, `diff.isDangerous = true` a zobrazí se `DangerConfirmation` checkbox, který musí být zaškrtnut. Nebezpečné jsou zejména:

- vypnutí entity (`isEnabled === false`) u procesu, mapování, objektu, override i run profilu,
- oslabení ochrany mazání: `requireArchiveForDelete === false` / `requireArchiveForDeleteOverride === false`,
- **odstranění `AT TIME ZONE`** z cutoff timestamp výrazu (`timestampExpr` / `timestampExprOverride`) — detekováno `isTimezoneRegression()` (regex `AT\s+TIME\s+ZONE`). Toto je **Risk K1**: bez normalizace by se UTC cutoff porovnával s lokálními časy a smazací okno by bylo posunuté o offset zóny. Editor zobrazí explicitní varování a checkbox s textem o reintrodukci K1.

> Anchor timestamp výrazy (`anchorTimestampExpr`/`*Override`) **nejsou v konzoli editovatelné** (proto nejsou v `TIMEZONE_GUARDED_FIELDS`); jejich UTC normalizace se vynucuje server-side (seed + runtime gate THROW 50200).

Další pojistka: pole `auditLevel === 'NONE'` na delete-capable mapování/procesu vyvolá **non-blocking** `inline-warning` (T-08) — informovaný souhlas, že se maže bez per-row audit trailu. Klient navíc dělá `proposalIssues()`: fixed cutoff mode (`cutoffMode = 1`) bez `cutoffDate` je **ERROR** a blokuje uložení.

**Pre-save validace (Validation + Suggested SQL v editoru).** Při přechodu do review se volá `preValidateConfiguration` (`App.tsx`):

- Pro konfiguračně kritické entity (`process`, `processDatabase`, `objectSpec`, `objectOverride`) backend spustí **dry-run**: `POST <endpoint>/validate` (např. `/api/config/processes/validate`). Navrhovaná změna se aplikuje v transakci, která se nikdy necommitne (`ValidateProposedAsync`, rollback při disposal), a vrátí se výsledné validační nálezy — mód `proposed` („applied to a throwaway copy, not saved“).
- Pro ostatní entity se validuje aktuální perzistentní stav scope (`POST /api/validation/configuration` → `arch.usp_Api_ValidateConfiguration`) — mód `current`.

Nálezy se zobrazí přes `ValidationSummary` (počty errors/warnings/findings). Sloupec **Suggested SQL** (`suggestedSql`) z validačních procedur je strojově navržený opravný SQL příkaz; v editoru je součástí nálezů, samostatně se zobrazuje na obrazovce **Validation** (10.7).

**Explain plan.** Backend nabízí `POST /api/validation/explain-plan` → `arch.usp_Api_ExplainProcessPlan` (vyžaduje `processCode`, vrací všechny result-sety jako `{ resultSets }`). Slouží k vysvětlení/odhadu plánu archivace pro proces. **Pozn.:** v aktuální verzi frontendu (`views/`) tento endpoint není napojen na žádné tlačítko — je dostupný přes API (např. ze Swaggeru / přímého volání), nikoli z UI.

**Pre-save review panel** ukazuje `impactPreviewRows`: Entity, Target, Process, Source DB, Archive DB, **Changed fields**, **Risk fields** a **Concurrency token** (hodnota `modifiedAtKey`). Po potvrzení se uloží jen pokud se řádek od otevření editoru nezměnil (viz 10.10).

**Editor history.** Panel „Recent changes to this item“ — `loadEntityHistory` volá `GET /api/config/change-history` (`entityType`, `entityKey`, `top=5`) scoped přesně na editovaný řádek (`arch.ConfigChangeItem` EntityType/EntityKey); read-only, selhání → prázdný seznam.

**Mapování editoru na write endpointy a procedury:**

| Entity | Endpoint (`POST /api/config/…`) | Save procedura |
|--------|----------------------------------|----------------|
| `process` | `/processes` | `arch.usp_Api_SaveProcess` |
| `processDatabase` | `/process-databases` | `arch.usp_Api_SaveProcessDatabase` |
| `objectSpec` | `/objects` | `arch.usp_Api_SaveObjectSpec` |
| `objectOverride` | `/object-overrides` | `arch.usp_Api_SaveObjectSpecOverride` |
| `processKey` | `/process-key-specs` | `arch.usp_Api_SaveProcessKeySpec` |
| `indexRequirement` | `/index-requirements` | `arch.usp_Api_SaveIndexRequirement` |
| `runProfile` | `/run-profiles` | `arch.usp_Api_SaveRunProfile` |

Po úspěšném save (`saveConfiguration` v `App.tsx`) běží post-save validace a refresh; hláška ukazuje ID change setu, např. *„Saved and published. Change set 123. Validation OK.“* (`saveMessage`).

### 10.7 Validation

Komponenta `ValidationView.tsx`. Dvě operátorská tlačítka:

| Tlačítko | Endpoint | Procedura |
|----------|----------|-----------|
| **Configuration** | `POST /api/validation/configuration` | `arch.usp_Api_ValidateConfiguration` |
| **Indexes** | `POST /api/validation/indexes` | `arch.usp_Api_ValidateIndexRequirements` |

Panel **Findings** zobrazuje nálezy se sloupci: `returnCode` (Code), `severity` (badge), `processCode`, `sourceDb`, `archiveDb`, `objectName`, `finding` a **`suggestedSql` (Suggested SQL)** — navržený opravný příkaz. Export do CSV. Filtr scope se bere z globálních filtrů Process/Source. Tytéž nálezy se zobrazují i v editoru (pre-save) a souhrn (počty ERROR/WARN) je na dashboardu.

### 10.8 Change history (ConfigChangeSet + CSV export)

V rámci obrazovky **Configuration** panel **Change history** (`CHANGE_HISTORY_COLUMNS`): `configChangeSetId`, `changeStatus`, `requestedBy` (User), `requestedAtUtc`, `itemCount`, `fieldCount`, `validationStatus`. Zdroj: `GET /api/config/change-history` → `arch.usp_Frontend_GetConfigChangeHistory` (parametry `ConfigChangeSetId`, `DateFromUtc/ToUtc`, `RequestedBy`, `EntityType`, `EntityKey`, `ChangeStatus`, `Top`). Endpoint vrací **více result-setů** (`AllResultSets`); UI zobrazuje první (`resultSets[0]`). Panel má **Export CSV** (`config_change_history.csv`) přes právě zobrazené řádky.

Každá změna provedená editorem zapisuje change set do `arch.ConfigChangeSet` + položky do `arch.ConfigChangeItem` (EntityType/EntityKey/změněná pole) se stavem `Published` (audited immediate-publish — viz 10.11). Scoped historie na konkrétní řádek je dostupná i přímo v editoru (10.6).

### 10.9 Go-live readiness (`usp_Frontend_GoLiveReadiness`, FAIL gate)

Komponenta `GoLiveReadinessView.tsx`. Operacionalizuje produkční audit jako živou go-live bránu. Načítá `GET /api/golive-readiness` → `arch.usp_Frontend_GoLiveReadiness` (read-only). Výsledek se dělí na **Summary** řádek (`category = 'Summary'`) a jednotlivé **Checks**.

Verdikt (severity Summary řádku) řídí banner:

| `severity` Summary | Banner |
|--------------------|--------|
| `OK` | **READY** (`inline-info`) |
| `WARN` | **READY WITH WARNINGS** (`inline-info`) |
| jiné (např. `FAIL`) | **NOT READY** (`inline-warning`) |

Pokud existují řádky se `severity = FAIL`, banner navíc hlásí: *„Resolve all FAIL items before enabling real deletes.“* Tabulka **Checks** má sloupce `category` (Area), `checkName` (Check), `severity` (Status badge), `detail`, `recommendation`. Tlačítko **Refresh** (přes `nonce`) přehraje kontroly. Význam: **jakýkoliv FAIL = NOT READY** — produkce (reálné mazání) se nemá zapínat, dokud nejsou všechny FAIL položky vyřešeny.

Pozn.: vedle této obrazovky existuje samostatný lehčí **readiness probe** `GET /api/readiness` (`ReadinessService`), který napájí badge a panel v topbaru (`databaseOk`, `databaseName`, `processCount`, `mappingCount`, `missingObjects`, `missingRoles`, `missingExecutePermissions`, `executionUser`). Ten ověřuje dostupnost DB, existenci objektů, rolí a EXECUTE oprávnění běhové identity.

### 10.10 Legal holds

**Legal holds (T-21) nemají v Admin Console žádnou samostatnou obrazovku ani API endpoint.** Jsou to čistě serverové/`karch_approver` operace mimo tuto konzoli:

- Přidání/uvolnění holdu: `arch.usp_Api_AddLegalHold` / `arch.usp_Api_ReleaseLegalHold` (akce role `karch_approver`, auditováno přes `CreatedBy`/`ReleasedBy`).
- Výpis holdů: `arch.usp_Frontend_GetLegalHolds`.
- Model: řádky `arch.LegalHold` (`ProcessCode` + volitelně `SourceDb` + `HoldKey = Key1`). Aktivní holdy se **vylučují z každé kandidátní množiny** při buildu (014/027); hold přidaný po přípravě ANCHOR WorkBatch se ctí při claimu **zaparkováním** klíče (`WorkBatchKey.Status = 5`) — nikdy se nesmaže/nezarchivuje a dávka přesto doběhne. Granularita je `Key1` (u kompozitních klíčů over-inclusive, nikdy ne under-exclude).

Dopady legal holdů jsou v konzoli **nepřímo viditelné** přes Runs / Work batches (zaparkované klíče se neprojeví jako smazané) a přes Validation/Go-live readiness; vlastní správa holdů je mimo UI této verze.

### 10.11 Governance — audited immediate-publish, edit-lock, atribuce reálného uživatele

Konzole vynucuje governance model **audited immediate-publish** (`docs/governance-model.md`): kdokoli s odemčenými úpravami může změnu provést a ta se **okamžitě publikuje** (stav `Published`) a zvaliduje. **Nejde o 4-eyes schvalování** — kontrola je *accountability po faktu* (úplný, atribuovaný audit trail), nikoli prevence předem. „4-eyes potvrzení“ v editoru (10.6) je tedy informovaný souhlas operátora s nebezpečnou změnou, **ne** schválení druhou osobou (enforced 4-eyes je dokumentovaný, ale neimplementovaný upgrade — Option B).

**Edit-lock (zámek úprav).** Stav drží `EditLockControl` v topbaru; čte `GET /api/security/status` (`apiSecurityStatus`). Autorizace má tři koexistující cesty (kontrola v tomto pořadí):

1. **Windows/AD identita** — autentizovaný Windows uživatel na allowlistu `AdminConsole:AdminUsers`. Bez hesla; badge „Editing as DOMAIN\user“ (`status.windowsAuthorized`).
2. **Lokální operátor** — `username` + heslo z `AdminConsole:Operators` (`PasswordSha256` = PBKDF2-HMAC-SHA256). Odemčení username+heslem; badge „Editing as <operator>“.
3. **Sdílené heslo (fallback)** — `AdminConsole:EditPassword(Sha256)`, break-glass bez per-user identity.

Stavy `EditLockControl`:

| Stav | UI |
|------|----|
| `status === null` | „Checking edit lock“ (spinner) |
| `windowsAuthorized` | „Editing as <windowsUser>“ (zelená) |
| `!isConfigured` | „Edit access not configured“ (varování) |
| `isUnlocked` | „Editing as <operator>“ + tlačítko **Lock** |
| jinak | formulář (volitelný operator username + heslo) → **Unlock** |

Odemčení (`unlockEditing` → `POST /api/security/unlock`) vrátí `token`, který se uloží do `sessionStorage` (`karchive-admin-console.edit-token`) a posílá se v hlavičce **`X-Admin-Edit-Token`** u všech write volání. Uzamčení (`lockEditing` → `POST /api/security/lock`) token zahodí. Všechny tři cesty razí stejný token vázaný na vyřešenou identitu.

**Vynucení na backendu.** Každý write endpoint (`/api/config/*` save & set-enabled, `/api/runs/stop`, `/api/runs/restore`, všechny `*/validate`) na začátku volá `security.IsAuthorized(http)`; při neúspěchu vrací **HTTP 423 Locked** (`Locked()`, hláška „Configuration editing is locked.“). Frontend write akce navíc kontrolují `securityStatus?.isUnlocked` ještě před voláním (Stop/Restore i save).

**Atribuce reálného uživatele (T-07).** Backend **nikdy nedůvěřuje klientskému `RequestedBy`** (je padělatelný). Aktér se odvozuje výhradně z autentizovaného principalu metodou `RequestedBy(...)`:

```csharp
security.AuthenticatedUser(http) ?? http.User.Identity?.Name ?? Environment.UserName
```

tj. v pořadí: identita edit session (lokální operátor / Windows-AD uživatel) → raw Windows identita → service account. Tato hodnota se předává jako `@RequestedBy` do save procedur a zapisuje do `arch.ConfigChangeSet.RequestedBy`, takže audit trail připisuje změnu reálnému operátorovi (ne service účtu API).

**Optimistic concurrency.** Save endpointy nejdřív volají `EnsureUnchangedAsync` → `arch.usp_Api_CheckConfigConcurrency` proti `@ExpectedModifiedAt` (concurrency token z `modifiedAtKey`). Pokud se řádek od otevření editoru změnil (nebo zmizel), vrací se **HTTP 409 Conflict** s `detail` a `currentModifiedAt`. Frontend (`handleSaveConflict`) pak znovu načte konfiguraci, zavře editor a zobrazí přesnou hlášku včetně času poslední serverové změny.


---


### 10.X Atributy obrazovek a polí (referenční)

Kompletní přehled atributů viditelných v Admin Console. Hluboké konfigurační schéma (sloupce tabulek
`arch.Process`, `ObjectSpec`, `ProcessDatabase`, `ProcessKeySpec`, `RunProfile`, `IndexRequirement`) je
v **kapitole 8**; zde je pohled „co je na které obrazovce a co to znamená".

**Sekce v levé liště — princip:** **Dashboard** (vstupní souhrn zdroj vs. archiv, procesy, běhy, zdraví),
**Analysis & Estimates** (grafy objemů + odhad další dávky), **Runs** (historie běhů a jejich detail),
**Document lookup** (dohledání dokladu ve zdroji/archivu), **Configuration** (procesy, mapování, objekty,
klíče, indexy, run profily, plánování jobů, operátoři — jen po přihlášení), **Validation** (kontrola
konfigurace), **Go-live** (brána připravenosti na ostrý provoz).

**Filtr v hlavičce (všechny sekce):** `Process` (konkrétní proces / All processes), `Source DB` (zdrojová
provozní DB; **prázdné = „Any source" = všechny zdrojové DB**), `Archive DB` (cílová archivní DB),
`Include disabled` (zobrazit i vypnutá), `Refresh`.

**Dashboard** — dlaždice `Active processes`, `Source rows`, `Archived rows`, `Recent non-OK runs`;
operační signály a grafy. Tabulky a sloupce:
- *Process movement*: `Process, Source, Archive, Source rows, Archived, Delta, Objects`.
- *Prep/run dávky*: `Batch, Process, Status, Candidates, Prepared`.
- *Recent runs*: `Run item, Process, Source, Status, Docs, Archived, Deleted, Started`.
- *Table counts*: `Process, Source table, Archive table, Source, Archived, Source ok, Archive ok`.

**Analysis & Estimates — KPI + grafy.** KPI dlaždice: `RF/L mapped tables, RF/L source rows,
RF/L archived rows, RF/L runs`. Grafy (série `Label/Value`, resp. `Label/Source/Archived`): přenesené
řádky podle dne+source DB+procesu, podle dne+tabulky, kontrolní pohled source vs. archived, podle cutoffu,
backlog ke smazání. „Poslední dávka — odhad dopadu": `WorkBatch, Proces, Source DB, Tabulky, Odhad řádků,
Odhad MB, Odhad % DB`. „Poslední pohyby": `Run date, Process, Source DB, Archive DB, Source table,
Processed, Archived, Deleted`.

**Analysis & Estimates — „Odhady další dávky (MB)"** (přepínač *Zobrazit odhady*, default vypnuto; bere
Source DB z hlavičky, prázdné = všechny DB; *Přepočítat*, *Export CSV*). Mapping-aware (proc
`arch.usp_Api_EstimateNextRunImpact`; parametry `@ArchiveGrowthFactor`=1.20, `@LogMultiplier`=3.00,
`@SafetyFactor`=1.30):

| Sloupec | Význam / výpočet |
|---|---|
| **Proces** | Kód procesu. |
| **Source DB** | Zdrojová databáze mapování. |
| **Režim** | `ARCHIVE_DELETE` (Mode 1), `DELETE_ONLY` (0), `COPY_ONLY` (2). |
| **Limit dávky (řádků)** | `COALESCE(BatchRowCount, BatchDocCount, MaxRowsPerTransaction, 1000) × MaxBatchesPerRun` — strop jednoho běhu. Odhad se počítá pro tento limit (ne celou tabulku). |
| **Zdroj řádků** | Součet řádků ve zdrojových tabulkách procesu (z `sys.dm_db_partition_stats`). |
| **Payload MB** | `min(Zdroj řádků, Limit dávky) × prům. velikost řádku` — čistý objem přesunu příští dávkou. |
| **Archiv růst MB** | `Payload × @ArchiveGrowthFactor` (jen Mode 1) — odhad růstu archivní DB vč. režie. |
| **Log tlak MB** | `Payload × @LogMultiplier` — odhad zatížení transakčního logu (archivace + DELETE + indexy). |
| **Plán MB (s rezervou)** | `(Archiv růst + Log tlak) × @SafetyFactor` — plánovací číslo pro kapacitu/log; posuď před spuštěním. |

Detail (na tabulku): `SourceRows`, `UsedMB`, `DataMB`, `IndexMB`, `AvgUsedKBPerRow`,
`OneToOneEstimatedRows`, `OneToOnePayloadMB`, `FullTableUsedMB`, `Status`, `ErrorMessage`.

**Runs** — seznam: `Run, Item, Process, Source, Archive, Mode, Status, Started, Finished, Duration,
Batches, Docs, Rows, Error`. Stavy `OK`/`FAILED`/`STOPPED`/`DRYRUN`. Detail (panely):
- *Run items*: `Item, Process, Mode, Status, Batches, Docs, Deleted, Archived, Error`.
- *Work batches*: `Batch, Process, Status, Prepared, Started, Completed, Last key`.
- *Object movement*: `Object item, Item, Process, Schema, Table, Deleted, Archived, Logged`.
- *Document audit*: `Audit, Item, Process, Label, Key, Archived, Deleted at`.
Akce **Stop** (kooperativní zastavení) a **Restore** (vyžaduje elevovaného operátora; kap. 7).

**Document lookup** — vstup: klíč dokladu. *Souhrn*: `Result, Key, Processes, Archived, Run item, Source`.
*Detaily*: `Audit, Process, Label, Key, Archived, Deleted at, Status`.

**Configuration** — panel detailu procesu + tabulky entit (sémantika sloupců viz **kap. 8**):
- *Process*: `Process, Description, Enabled, Strategy, Retention, Audit, Objects, Modified`.
- *Database mappings*: `Process, Source, Archive, Enabled, Run order, Retention, Batch docs, Batch rows`.
- *Effective objects*: `Process, Source, Table, Order, Enabled, Archive schema, Archive table`.
- *Process keys*: `Process, Ordinal, Name, Expression, SQL type, Required`.
- *Index requirements*: `Process, Type, Object, Key columns, Mandatory, Mappings`.
- *Run profiles*: `Profile, Description, Enabled, Scheduled, Order, Process filter, Source filter, Dry run`.
- *Change history*: `Change set, Status, User, Requested, Items, Fields, Validation`.
Editor exponuje plné konfigurační atributy (Mode, CutoffMode/CutoffDate, BatchDocCount/BatchRowCount/
MaxBatchesPerRun/MaxRowsPerTransaction, AuditLevel, SelectionStrategy, Anchor*Expr, TimestampExpr,
cheap-mode CandidateWhereSql/OrderSql/SelectExpr, ObjectSpec Source/Archive, ProcessKeySpec
SourceExpressionSql, RunProfile okno/filtry, IndexRequirement) — referenčně kap. 8. Změna vyžaduje
**change reason ≥ 6 znaků** a je auditována (kap. 6).

**Configuration → Plánování (SQL Agent joby):** `PREP CONFIGURED` (@Phase=PREP) + `RUN CONFIGURED`
(@Phase=BOTH/RUN, záchytný). Atributy: **Povolit/Zakázat**, **Četnost** (Denně/Každou hodinu), **Čas**
(HH:MM), **Rozvrh aktivní**. Procedury `usp_Api_GetAgentJobs` / `SetAgentJobEnabled` /
`SetAgentJobSchedule` (whitelist na kAM joby; konzolový login potřebuje `SQLAgentUserRole` + vlastnictví —
`deploy/v2/059`).

**Configuration → Operátoři konzole** (DB-managed, `arch.ConsoleOperator`):

| Atribut | Význam |
|---|---|
| **Uživatel** (`Username`) | Přihlašovací jméno (unikát). |
| **Jméno** (`DisplayName`) | Zobrazované jméno do auditu (RequestedBy). |
| **Heslo** | Plaintext jen ve formuláři; API hashuje **PBKDF2-HMAC-SHA256** (sůl, 100k) a ukládá jen `PasswordSha256`. Úprava s prázdným = beze změny. |
| **Povolen** (`IsEnabled`) | Zda se může přihlásit. |
| **Elevovaný** (`IsElevated`) | Smí **restore** do produkce (vyšší tier; kap. 7 / `AdminConsole:ElevatedAdminUsers`). |

Pořadí ověření: **config operátoři** (`AdminConsole:Operators`) → **sdílené heslo** (`EditPasswordSha256`)
→ **DB operátoři** (`arch.ConsoleOperator`). Config + sdílené heslo = bootstrap/fallback (jediná cesta
dovnitř při nedostupné DB). Testovací `op1` je config-based (appsettings.Development.json), proto **není**
v `arch.ConsoleOperator`.

**Validation** — nálezy konfigurace + index requirements; sloupce: `Code, Severity` (ERROR/WARN/INFO),
`Process, Source, Archive, Object, Finding, Suggested SQL`.

**Go-live** — brána připravenosti; sloupce: `Area, Check, Status, Detail, Recommendation`; souhrn
**READY / READY WITH WARNINGS / NOT READY**.

**Stavové indikátory (vpravo nahoře):** `API OK / DB OK` a `Editing as … / Lock`.

### 10.Y Konfigurační hodnoty (editory) — význam, dopad, varování

Hodnoty reálně nastavované v editorech Configuration. ⚠️ = **kritický parametr** (ovlivní nevratné
mazání nebo vypíná pojistku). Sémantika sloupců tabulek viz kap. 8; zde je význam + provozní dopad +
runtime brány.

**Editor procesu (výchozí hodnoty):**

| Pole | Význam, dopad, runtime efekt |
|---|---|
| **Description / Enabled** | Popis; ⚠️ Enabled=off → zdroj neubývá. |
| **Mode** | 1 Archive+delete (invariant archived==deleted, kap. 3) · 0 Delete only ⚠️ maže bez archivu · 2 Copy only (idempotentní kopie, kap. 3). |
| **Retention days** | Klouzavý cutoff (dnes−N). ⚠️ snížení → archivuje/maže víc a hned; spodní mez hlídá **retention floor THROW 50210** (kap. 5). |
| **Cutoff safety lag minutes** | Odečet od cutoffu — chrání hranu (kap. 4). |
| **Cutoff mode / Cutoff date** | Relative vs Fixed; ⚠️ posun data později → víc dat. |
| **Batch doc/row count · Max batches per run** | Strop běhu = `(BatchRowCount\|BatchDocCount\|MaxRowsPerTransaction) × MaxBatchesPerRun`. Vyšší = vyšší průtok, ale větší log tlak (viz Estimates „Plán MB"). |
| **Delay ms between batches** | Throttling mezi dávkami (I/O / OLTP koexistence). |
| **Document key label** | Co se zapisuje do `RunDocAudit.DocKey` (kap. 6). |
| **Audit level** | NONE ⚠️ bez per-row stopy (jediná kopie = archiv, lze i purge) · BATCH/OBJECT agregáty · ROW per-doklad (~+10 % režie, plná dohledatelnost; kap. 6). |
| **Allow delete without archive** | ⚠️ Mode 0 smí mazat řádky bez archivní kopie — pojistka pryč. |

**Editor mapování (override):** stejná pole jako proces (prázdné = dědí) + **Run order** + cheap-mode:
- **Candidate WHERE cutoff (cheap-mode, TIMESTAMP)** — ⚡ SARGABLE cutoff na surovém indexovaném sloupci
  (`@CutoffUtc` převeden do lokálního času JEDNOU). S **Candidate SELECT** aktivuje cheap-mode = index-ordered
  sken **bez per-row AT TIME ZONE** (kap. 2/4). ⚠️ jen na **ISO-chronologickém** sloupci; smíšené formáty
  **tiše pod-vyberou** → NULL = klasický výběr.
- **Candidate ORDER BY (cheap-mode)** — surový sloupec pro index-ordered seek; NULL = dle počítaného času.

**Editor objektu (ObjectSpec):** `Source schema/table`; ⚠️ **Delete order** (FK pořadí — děti před rodiči);
`Delete mode`; **Timestamp expression** (UTC datetime2; ⚠️ musí přes AT TIME ZONE → jinak **TZ gate 50200**);
**Join to anchor predicate** (k.Key1..Key8, ANCHOR); **Additional WHERE filter** (na každý DELETE);
**Candidate SELECT expression** (⚡ cheap-mode projekce; aktivní jen s Candidate WHERE); `Archive schema/table`
(`{SourceDb}` placeholder); ⚠️ **Require archive for delete** (vypnutí = maže bez archivu); `Natural key label`.

**Editor klíče (ProcessKeySpec):** `Key ordinal` (1..8), `Key name`, `Source expression SQL`, ⚠️ `SQL type`
(musí odpovídat zdroji — typ/collation → **uniqueness gate 50115**), `Required`.

**Editor index requirement:** `Requirement type` (Selection/Join/Delete/Order/Partition), `Source schema/table`,
`Key columns CSV`, `Include columns CSV`, `Filter SQL` (gateováno safe-expr), `Mandatory` (Validation hlásí
chybějící + SuggestedSql), `Notes`.

**Editor run profilu:** `Enabled`, `Scheduled` (RunOnSchedule), `Run order`, `Process/Source DB/Archive DB
filter`, ⚠️ **Run window minutes** (StopAtUtc — po vypršení okna běh končí; krátké okno nedokončí velký objem),
`Max candidates`, `Paused cooldown seconds`, `Dry run` (náhled, bez zápisu).

### 10.Z Best practices — výkon a způsob práce s kArchiveManager 2.0

- **Velkoobjemové TIMESTAMP zdroje (100M+):** zapni **cheap-mode** (Candidate WHERE cutoff na mapování +
  Candidate SELECT na objektu) → index-ordered výběr bez per-row AT TIME ZONE. ⚠️ jen na ISO-chronologickém
  sloupci; jinak NULL (klasický výběr). Měřeno: 5M/run ~26–30 min i na 100M-řádkové tabulce bez parkingu indexů.
- **Batch sizing:** strop běhu = `BatchRowCount × MaxBatchesPerRun`; laď dle log prostoru a okna. Větší dávky =
  vyšší průtok, ale větší log tlak — ověř přes **Analysis & Estimates → Plán MB (s rezervou)** PŘED změnou.
- **Dvoufázový PREP/RUN:** PREP job připraví kandidáty přes den (lehká selekce), RUN job v nočním okně jen
  zpracuje (a je záchytný). Nastav PREP před RUN; viz Plánování + kap. 11.
- **Audit level:** ROW jen tam, kde je per-doklad dohledatelnost nutná (režie ~+10 %); velkoobjemové logy
  typicky BATCH/NONE (s vědomím, že NONE = bez per-row stopy). Vždy doplň důvod (Change reason).
- **Retence a cutoff:** drž nad **retention floor** (50210); používej **Cutoff safety lag**; pevný cutoff jen
  výjimečně. Snižování retence = nevratně víc smazaného.
- **Indexy:** udržuj doporučené **Index requirements** (Validation); chybějící index = pomalý kandidátní sken.
- **Least-privilege runner:** joby vlastní dedikovaný **non-sysadmin** login (`deploy/v2/053`+`054`) s rolí
  `karch_runtime`; gate `usp_VerifyRunnerPrivileges` (51001) běh zablokuje, dokud to nesedí. Konzole spravuje
  joby přes `059`.
- **Časové zóny:** všechny časové výrazy převádět přes AT TIME ZONE do UTC (gate 50200); ověř v **Show effective plan**.
- **Invariant Mode=1:** archived==deleted (Divergence=0) — nevypínej Require archive for delete; sleduj v Runs.
- **Provoz:** RUN CONFIGURED v nočním okně; sleduj HEALTH ALERT + RECOVER STALE RUNS; kontroluj **Go-live**
  bránu před ostrým provozem.

## 11. Nasazení, seedy, SQL joby a provoz

Autoritativní zákaznický balíček (clean install) je **bundle ve složce `deploy/v2/release-package/`** plus objektové skripty, které tento bundle přes `:r` includuje, a poté parametrizované provozní add-ony pod `deploy/v2/`. Číslované legacy skripty `00`/`13`–`33` **nejsou** clean-customer cesta — `00_deploy_2_0_clean.sql` vytváří relikt objekty, které `verify_clean_deploy.sql` reportuje jako **FAIL**. Bundle vytváří **pouze objekty** (audit-hardened čistá v2 sada — žádné v1 procedury, žádné relikt tabulky, žádný smoke seed); spustitelné procesy se zavádějí samostatně seedem podle zákaznických DB.

### 11.1 Pořadí nasazení (clean install na čistou DB)

| # | Krok | Artefakt | Očekávaný výsledek |
| - | ---- | -------- | ------------------ |
| 1 | Deploy objektové sady | `deploy_clean_v2_full.sql` (SSMS → **Query → SQLCMD Mode**, nastav `:setvar Root`) **nebo** `deploy_clean_v2_full_SSMS.sql` (klasický, každý `:r` inlinovaný — stačí **F5**, bez SQLCMD módu). Identická objektová sada. | 0 chyb |
| 2 | Verify objektové sady | `verify_clean_deploy.sql` | **PASS** (každý jiný `Result='FAIL'` je problém) |
| 3 | Behaviorální self-test | `selftest_acceptance.sql` | **PASS** (archive/delete/restore/audit/TZ-gate na throwaway schématu, self-clean) |
| 3b | Variantní akceptační pack | `release-package/variant_test_pack.sql` | **PASS** (pokrytí variant Mode/Selection/Audit) |
| 4 | Seed zákaznických procesů | `deploy/v2/seed_tested_processes.sql` jako reference/template — upravit DB názvy + per-process Mode/retence/cutoff/`AT TIME ZONE`/AuditLevel | seed counts + `usp_ValidateConfiguration` bez ERROR |
| 5 | Console read granty (**povinné**) | `deploy/v2/051_grant_console_read_source_dbs.sql` (vyplnit app-pool login + seznam source/archive DB) | dashboard cross-DB counts nevracejí 503 |
| 6 | Trvanlivost archivu | archive DB je ve **FULL recovery**; `deploy/v2/048_archive_db_backup.sql` (vyplnit `@BackupRoot`) → FULL+LOG joby + restore rehearsal | backup joby + úspěšný restore rehearsal |
| 7 | Failure alerting | `deploy/v2/047_operational_alerting.sql` (vyplnit SMTP + operator e-mail) | dorazí testovací alert |
| 8 | Runtime least-privilege (**doporučené**) | `deploy/v2/053_runtime_least_privilege_principal.sql` → `deploy/v2/054_runner_job_least_privilege.sql` | non-sysadmin runner, `usp_VerifyRunnerPrivileges` bez ERROR |
| 9 | (volitelně, high-volume) perf | `deploy/v2/052_archive_with_index_parking.sql` (`usp_RunTimestampProcessParked`) | jen v maintenance okně |
| 10 | Admin Console | publish + IIS hosting, **Production** env, Windows Auth/operators, HTTPS | `/api/readiness` = `apiOk` + `databaseOk` |
| 11 | Compliance controls (T-21) | `usp_Api_SetRetentionFloor` (+ legal-holdy) | retention floor nastaven dle politiky |
| 12 | Go-live brána | `arch.usp_Frontend_GoLiveReadiness` (Console → **Go-live**) | **0 FAIL** před povolením reálných delete |

Objektové skripty, které master `:r`-includuje, žijí pod `kArchiveManagerAdmin/{Databases,Tables,v2,frontend,procedures,indexes}` — pro clean install se **nespouštějí jednotlivě**.

### 11.2 Krok 1 — objekty (`deploy_clean_v2_full[.sql/_SSMS]`)

Master skript vytváří v daném pořadí (fáze):
- **Databáze:** `create_kArchiveManagerAdmin.sql`, `create_kArchiveManagerBackups.sql` (archive ve **FULL recovery**).
- **Tabulky:** `Tables/arch.*.sql` — config + run + audit tabulky (`Tables\` skripty jsou plain `CREATE TABLE`, **nejsou** idempotentní — proto cílí na **čistou** `kArchiveManagerAdmin`).
- **Core/metadata + views + monitoring:** `v2/010`, `v2/022/023/024` (effective views + `v_OperationalHealth`).
- **Runner:** `014` PrepareCandidates · `015` RunPreparedBatch · `027` RunTimestampProcess · `016` RunPreparedBatches + `usp_RunConfiguredProcesses_Prepared` · `020` `usp_RunProfile_Prepared` (po něm `DROP PROCEDURE IF EXISTS [arch].[usp_RunScheduledProfiles_Prepared]` — superseded scheduler bez callerů) · `030` `usp_RecoverStaleRuns`.
- **Gates/helpers:** `035` TZ gate (THROW 50200) · `046` safe-expression validator (THROW 50400) · `011`/`012` index/plan validace · `procedures/` GetOutputColumns, EnsureArchiveTableLikeSource, ProvisionArchiveTablesForProcess, ValidateConfiguration.
- **Runtime hardening:** `040` run cancel/stop · `042` restore + `RestoreAudit` + purge guard (THROW 50404/50405) · `044` run liveness · `045` audit immutability DENY.
- **Admin Console API:** `frontend/001`–`009` + `frontend/010` `karch_*` role model + EXECUTE granty (po vytvoření všech procedur). Fáze 13b znovu aplikuje guarded granty: `usp_Api_RequestRunStop`→`karch_operator`, `usp_RestoreFromArchive`→`karch_advanced_admin`, `usp_Frontend_GoLiveReadiness`→`karch_viewer`.
- **Readiness/visibility:** `v2/049` go-live readiness · `v2/050` timestamp retention gaps.
- **Runtime least-priv (T-33):** `v2/055` role `karch_runtime` + `usp_VerifyRunnerPrivileges` + `usp_CaptureRunnerPrivilegeInventory` + `arch.RunnerPrivilegeInventory`.
- **Retention floor + legal-hold (T-21):** `v2/056` `arch.RetentionPolicy` + `usp_AssertRetentionFloor` (THROW 50210) + `arch.LegalHold` + management API.
- **Copy-only mode (Mode=2):** `v2/057` rozšiřuje Mode CHECK na {0,1,2} + `usp_GetCopyDedupInfo`.
- **SQL Agent joby (fáze 14):** `v2/036_install_recover_stale_runs_job.sql` (RECOVER STALE RUNS, **enabled**) + `v2/SQL job - RUN CONFIGURED.sql` (RUN CONFIGURED, ships **DISABLED**).

Závěrečné PRINT připomínají post-deploy kroky 2) verify a 3) selftest.

### 11.3 Krok 2 — verify + testy

**`verify_clean_deploy.sql`** je object-set assertion. Plní tabulku `@chk` s `Result IN ('FAIL', ...)`; finální řádek je **PASS** jen když žádný FAIL neexistuje. Kontroluje:
- **MUST NOT EXIST:** žádné `legacy_v1` schéma, žádná v1/stub procedura v `arch`, žádná relikt tabulka, žádný smoke/test proces.
- **Expected:** všechny očekávané tabulky, views, procedury, role; T-03/cancel sloupce na `arch.Run`; granty `usp_Api_RequestRunStop → karch_operator`, `usp_RestoreFromArchive → karch_advanced_admin`; audit immutability DENY na `RunDocAudit`.

**`selftest_acceptance.sql`** — turnkey behaviorální smoke: syntetický archive+DELETE+restore+audit+TZ-gate na throwaway schématu, poté self-cleanup; **PASS** dokazuje, že pipeline funguje na daném serveru bez dotyku reálných dat. **`variant_test_pack.sql`** pokrývá varianty Mode/Selection/Audit.

### 11.4 Krok 3 — seed (`deploy/v2/seed_tested_processes.sql`)

Reference seed zachycený z `RADIM-STACHAL\RSTSQL2022.kArchiveManagerAdmin`. FK `ProcessId` se řeší přes `ProcessCode` (přenositelné), takže pro zákazníka stačí upravit `SourceDb`/`ArchiveDb` názvy. Skript:
- `USE [kArchiveManagerAdmin]; SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;`
- **Idempotentní guard:** `IF EXISTS (... ProcessCode IN (...)) THROW 60000, 'Seed target processes already exist - delete them first to re-seed.', 1;`
- Vloží **7** `arch.Process`, **9** `arch.ProcessKeySpec`, **17** `arch.ObjectSpec`, **17** `arch.ProcessDatabase`, **16** `arch.IndexRequirement`, **14** `arch.RunProfile`; `COMMIT;` poté vypíše counts a spustí `EXEC arch.usp_ValidateConfiguration;`.

Seedované procesy a jejich klíčové parametry:

| ProcessCode | SelectionStrategy | Mode | RetentionDays | AuditLevel | Poznámka |
| ----------- | ----------------- | ---- | ------------- | ---------- | -------- |
| `RECEIVING` | ANCHOR (`dbo.BACKRH`, key `PO_NUM`) | 1 | 540 | BATCH | header BACKRH + child BACKRD |
| `SHIPPING` | ANCHOR (`dbo.SHIPHIST`, key `PACKSLIP`) | 1 | 540 | BATCH | 6 objektů DeleteOrder 10–60 |
| `RF_LOG2` | TIMESTAMP (key `ROWID`) | 1 | 540 | NONE (KMWEBV override `ROW`) | high-volume log; `MaxRowsPerTransaction=50000` |
| `INTEGRACE_DNLOAD` | TIMESTAMP (key `ROWID`) | 1 | 540 | BATCH | DNLOAD_ARCHIVE |
| `INTEGRACE_UPLOAD` | TIMESTAMP (key `ROWID`) | 1 | 540 | BATCH | UPLOADARCHIVE |
| `WA_AAD_PRIJEM_OSTRY_SMOKE` | ANCHOR (`dbo.t_receipt`) | 1 | **1** | BATCH | **TEST fixture** — pro PROD disable |
| `WA_AAD_VYDEJ_OSTRY_SMOKE` | ANCHOR (`dbo.t_order`) | 1 | **1** | BATCH | **TEST fixture** — pro PROD disable |

Co upravit pro zákazníka:
- **DB názvy** — `ProcessDatabase.SourceDb`/`ArchiveDb` (seed odkazuje `AAD`/`Edge`/`KMWEBV`/`KMWE_Test`; `ArchiveDb=kArchiveManagerBackups`).
- **Retence** — `RetentionDays` per Process nebo per ProcessDatabase override.
- **Cutoff** — `CutoffMode`/`CutoffDate` a zejména `AnchorTimestampExpr`/`ObjectSpec.TimestampExpr` s `AT TIME ZONE N'Central European Standard Time' AT TIME ZONE N'UTC'` (lokální zdrojový čas → UTC).
- **AuditLevel** — `ROW`/`BATCH`/`OBJECT`/`NONE` per proces/DB.
- **TEST fixtury** `WA_AAD_*_OSTRY_SMOKE` (RetentionDays=1) — pro produkci disable nebo vynechat.

Po seedu musí `arch.usp_ValidateConfiguration` být bez ERROR; chybějící zdrojové indexy jsou **WARN only**, ne blokátor (vytvořit z Console → Validation → Indexes přes Suggested SQL).

### 11.5 Krok 4 — povinné a doporučené add-ony

#### 051 — Console read granty (povinné pro dashboard)

`051_grant_console_read_source_dbs.sql` (`USE [master]`, klasický SSMS, idempotentní, přeskakuje neexistující DB). Vyplnit `@ConsoleLogin` (default `IIS APPPOOL\kAM Admin Console`) a `@DbsCsv` (každá enabled source DB + archive DB). Dashboardové movement-summary procedury (`usp_Frontend_GetProcessMovementSummary`, `GetTableMovementCounts`, …) počítají řádky cross-database; app-pool login je členem `karch_*` rolí pouze v `kArchiveManagerAdmin`, takže bez read-only usera v ostatních DB vrací API 503 (maskovaný Msg 916). Skript dělá `CREATE USER ... FOR LOGIN` + `ALTER ROLE db_datareader ADD MEMBER` — **jen READ**, žádný write/delete (reálný delete běží pod identitou Agent jobu).

#### 047 — Failure alerting (Database Mail + FAILED)

`047_operational_alerting.sql` (`USE [msdb]`, idempotentní). Vyplnit `@OperatorName`, `@OperatorEmail`, `@MailProfile`, `@SmtpServer`, `@SmtpPort`, `@MailFrom`, `@AlertEveryMin` (default 15). Pokud `@SmtpServer`/`@OperatorEmail` zůstane `CHANGE-ME…`, je `@placeholder=1` a mail account/profil se **přeskočí** (operator + job wiring + alert job se přesto nainstalují; mail naběhne až profil existuje). Co dělá:
1. Enable `Database Mail XPs`.
2. Mail account + profil (jen když není placeholder).
3. Operator (`sp_add_operator`/`sp_update_operator`).
4. Failure email na obou platformových jobech: `RUN CONFIGURED` a `RECOVER STALE RUNS` → `@notify_level_email = 2`.
5. **HEALTH ALERT** job (`kArchiveManager - HEALTH ALERT`) — každých `@AlertEveryMin` minut posílá mail, když `arch.v_OperationalHealth` má řádek `Severity='ERROR'` (FAILED runs, `ROW_COUNT_MISMATCH`, `ROW_AUDIT_MISSING`).

#### 048 — Archive DB backup (FULL + LOG)

`048_archive_db_backup.sql` (`USE [msdb]`, idempotentní). `kArchiveManagerBackups` JE backup-of-record (Mode=1 přesune řádky tam a zdroj nevratně smaže), proto musí být zálohovaná a — protože je ve FULL recovery — musí mít LOG zálohy (jinak roste log bez omezení). Vyplnit `@BackupRoot` (jinak `RAISERROR ... 048 BLOCKED`), `@RetentionDaysFull` (default 35), `@RetentionDaysLog` (default 8), `@FullDailyTime`, `@LogEveryMinutes` (default 60). Vytváří:
- **`kArchiveManager - BACKUP ARCHIVE DB (FULL)`** — denně: `BACKUP DATABASE ... WITH COMPRESSION, CHECKSUM, INIT` + `RESTORE VERIFYONLY ... WITH CHECKSUM` + retention přes `xp_delete_file`.
- **`kArchiveManager - BACKUP ARCHIVE DB (LOG)`** — hodinově: `BACKUP LOG` (jen když je DB ve `FULL`) + retention.

Doporučení: integrovat archive DB do zákaznického maintenance řešení (Ola Hallengren / maintenance plans), pokud existuje — tento skript je self-contained fallback. Před go-live **restore rehearsal**.

#### 053 + 054 — Runtime least-privilege (T-33)

**`053_runtime_least_privilege_principal.sql`** (`USE [kArchiveManagerAdmin]`, klasický SSMS, sysadmin, parametrizovaný + idempotentní). CHANGE-ME blok: `@RuntimeLogin` (default `karch_runtime_svc`), `@LoginType` (`SQL`/`WINDOWS`), `@SqlPassword`, `@SourceDbsCsv`, `@ArchiveDb`, `@PreProvisionArchive` (1=vytvořit archive tabulky teď), `@Apply` (0=preview, 1=apply). Vytváří dedikovaný **non-sysadmin** runner s minimem práv:
- **Admin DB:** member role `karch_runtime` → EXECUTE jen na runner proc chain (zápisy do control tabulek jdou přes ownership chaining, žádný přímý table DML).
- **Source DB:** `GRANT SELECT, DELETE` jen na mapované `ObjectSpec` tabulky + `GRANT SELECT` na ANCHOR header tabulku (skenovaná pro selekci, nikdy nemazaná).
- **Archive DB:** `GRANT INSERT, SELECT, ALTER ON SCHEMA::` + `GRANT CREATE TABLE` — **žádný DELETE/UPDATE** ⇒ unattended runner nemůže nikdy purgnout/přepsat archiv (purge zůstává `karch_approver`/DBA akce).

Skript odmítne login v `sysadmin` (`IS_SRVROLEMEMBER`), volitelně pre-provisionuje archive tabulky jako DBA, zachytí granty do `arch.RunnerPrivilegeInventory` (`usp_CaptureRunnerPrivilegeInventory`) a spustí `usp_VerifyRunnerPrivileges` `AS LOGIN` nového usera (dokáže správnost footprintu).

**`054_runner_job_least_privilege.sql`** (`USE [msdb]`, sysadmin, idempotentní) re-ownuje Agent job `kArchiveManager - RUN CONFIGURED` na runner login. Proč owner a ne proxy: **T-SQL subsystem job step ignoruje `@proxy_name`** a běží v kontextu **job ownera** — owner v sysadmin ⇒ step běží jako Agent service account (plná práva, T-33 problém); owner non-sysadmin ⇒ Agent impersonuje ownera (EXECUTE AS LOGIN). CHANGE-ME: `@RuntimeLogin`, `@JobNameLike` (default přesný `kArchiveManager - RUN CONFIGURED`), `@AlsoRecover` (LEAVE 0), `@Apply` (0=preview). `@AlsoRecover` defaultně 0: `RECOVER STALE RUNS` čte CIZÍ session v `sys.dm_exec_sessions`; non-sysadmin bez `VIEW SERVER STATE` vidí jen vlastní session ⇒ označil by živé runy FAILED (T-03 race). Recovery proto zůstává vlastněn Agent service accountem / sysadminem.

#### 052 — Index parking (volitelně, high-volume)

`052_archive_with_index_parking.sql` vytváří `arch.usp_RunTimestampProcessParked`. Pro **backlog drain** v maintenance okně: DISABLE non-essential nonclustered zdrojové indexy, archivuje, pak REBUILD — ~1.5× throughput (RF_LOG2 ~3.2k → ~5k ř/s). `@KeepIndexesCsv` je **required** — candidate-selection index zůstává enabled (skript odmítne běžet bez něj), nikdy nedisabluje clustered/PK/unique. REBUILD je v CATCH-protected finally (indexy se vždy obnoví i při selhání archivu). Volající potřebuje `ALTER` na zdrojové tabulce (DBA/maintenance, nad rámec `karch_*` rolí).

### 11.6 Krok 5 — Compliance (`usp_Api_SetRetentionFloor`)

Z bundlu (T-21, `v2/056`):
- **Retention floor** — `arch.RetentionPolicy` (singleton `PolicyId=1`, `MinRetentionDays` default **0 = vypnuto**). `usp_AssertRetentionFloor` THROWne **50210**, když je efektivní cutoff novější než `now - MinRetentionDays` (běh by smazal uvnitř povinného retenčního okna); gate je volán z runnerů 014/015/027. Nastavení:
  ```sql
  EXEC arch.usp_Api_SetRetentionFloor @MinRetentionDays = 365;   -- dle politiky; 0 = disabled
  ```
  Proc validuje `@MinRetentionDays < 0` (THROW **50212**), UPDATE/INSERT singleton, vrátí `MinRetentionDays, ModifiedAtUtc, ModifiedBy`. Je to `karch_approver` akce.
- **Legal-holdy** — připnutí konkrétních dokumentů: `EXEC arch.usp_Api_AddLegalHold @ProcessCode=…, @HoldKey=<Key1>, @Reason=…;`. Držené klíče jsou vyloučeny z každého candidate setu (014/027) a parkovány v claim-time (015). Správa: `usp_Api_ReleaseLegalHold`, `usp_Frontend_GetLegalHolds`.

### 11.7 Krok 6 — Admin Console (IIS)

1. **Publish:** `legacy\ArchiveManager1.0\admin-console\publish-admin-console.ps1` (volitelně `-DeployToIis -DeployPath … -IisAppPoolName … -RunSmoke -SmokeBaseUrl …`). Jedna IIS web app: ASP.NET Core API hostuje `/api/*` + `/health`, buildnutý React frontend ze `wwwroot` (same-origin, žádné prod CORS).
2. **Prerekvizity serveru:** Windows Server + IIS, ASP.NET Core Hosting Bundle pro `net9.0`, síťový přístup app-pool identity na SQL Server, nasazené objekty v `kArchiveManagerAdmin`.
3. **IIS site/app:** app pool **No Managed Code**; fyzická cesta na publish folder.
4. **Production env** — hostovat v Production prostředí.
5. **Autentizace:** **Windows Authentication** (allowlist `AdminConsole:AdminUsers`) a/nebo lokální operátoři / shared password.
6. **HTTPS.**
7. **Ověření:** `/api/readiness` vrací `apiOk` + `databaseOk`. Detaily v `docs/admin-console-customer-deploy-runbook.md` + `docs/admin-console-iis-deployment.md`.

### 11.8 Krok 7 — Go-live brána

`arch.usp_Frontend_GoLiveReadiness` (READ-ONLY; Console → **Go-live**) operacionalizuje produkční audit jako živou bránu. Vrací jeden řádek na kontrolu: `Category, CheckName, Severity (OK/INFO/WARN/FAIL), Detail, Recommendation`; **FAIL = go-live blokátor**. Kontroluje mj.: over-privileged principály, stop+restore granty, audit immutability, počet `Severity='ERROR'` v `arch.v_OperationalHealth`. Souhrnný řádek = FAIL když existuje jakýkoli FAIL, jinak WARN/OK. **Před povolením reálných delete (enable RUN CONFIGURED jobu) musí být 0 FAIL.**

### 11.9 SQL Agent joby

| Job | Stav po deploy | Schedule | Co dělá | Owner |
| --- | -------------- | -------- | ------- | ----- |
| `kArchiveManager - RUN CONFIGURED` | **DISABLED** | template `Hourly disabled template` (disabled) | Step **VALIDATE CONFIGURATION** + Step **RUN CONFIGURED PROCESSES** | re-own na runner login přes 054 |
| `kArchiveManager - RECOVER STALE RUNS` | **ENABLED** | `Every 15 minutes` (24/7) | `EXEC arch.usp_RecoverStaleRuns @StaleAfterMinutes=30, @DryRun=0, @VerboseOutput=0` | Agent service account / sysadmin (NE runner) |
| `kArchiveManager - HEALTH ALERT` (047) | enabled (po 047) | každých `@AlertEveryMin` (default 15) | mail při `v_OperationalHealth.Severity='ERROR'` | dle 047 |
| `kArchiveManager - BACKUP ARCHIVE DB (FULL)` (048) | enabled (po 048) | denně | FULL backup + VERIFYONLY + retention | dle 048 |
| `kArchiveManager - BACKUP ARCHIVE DB (LOG)` (048) | enabled (po 048) | hodinově | LOG backup + retention | dle 048 |

**RUN CONFIGURED — dvoukrokový:**
1. **VALIDATE CONFIGURATION** (`@on_success_action=3` = jdi na další step, `@on_fail_action=2`): `EXEC @rc = arch.usp_ValidateConfiguration; IF @rc <> 0 THROW 51000`. Poté **T-33 runner privilege gate** — `IF OBJECT_ID(N'arch.usp_VerifyRunnerPrivileges',N'P') IS NOT NULL` → `EXEC @rp = arch.usp_VerifyRunnerPrivileges; IF @rp <> 0 THROW 51001` (step běží v kontextu job ownera, takže `HAS_PERMS_BY_NAME`/`IS_SRVROLEMEMBER` vyhodnocují práva runnera; THROW zablokuje běh před jakýmkoli delete; guarded pro starší instally).
2. **RUN CONFIGURED PROCESSES** (`@on_success_action=1`, `@on_fail_action=2`): `EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'JOB_DEFAULT'`.

**RECOVER STALE RUNS** detekuje Run/RunItem/WorkBatch zaseknuté v `RUNNING` po disconnect/restart a obnoví je (inferuje OK když archived=deleted, jinak FAILED / pause pro resume). Disable přes `EXEC msdb.dbo.sp_update_job @job_name = N'kArchiveManager - RECOVER STALE RUNS', @enabled = 0;`. Owner zůstává privilegovaný (viz 054 `@AlsoRecover`).

Příklady ad-hoc volání viz `release-package/example-process-calls.sql` (template) / `example-process-calls-RSTSQL2022.sql` (konkrétní).

### 11.10 Existing-environment upgrade vs clean install

| | Clean install | Existing-environment (1.0 → 2.0) upgrade |
| --- | ------------- | ---------------------------------------- |
| Cíl | **čistá** `kArchiveManagerAdmin` | existující/upgradovaná DB |
| Objekty | bundle `deploy_clean_v2_full[.sql/_SSMS]` (master `:r`) | per-object skripty pod `kArchiveManagerAdmin/` (vše `CREATE OR ALTER` / guarded `ALTER`) — **NE** whole-DB bundle |
| Tabulky | plain `CREATE TABLE` (ne-idempotentní) | per-object skripty |
| Cleanup | žádný orphan | `deploy/v2/043_remove_overprivileged_principals.sql` (T-01, default `@IConfirm='NO'`) na odstranění over-privileged orphan app-pool loginů |
| Zakázané | — | **NE** `00_deploy_2_0_clean.sql` ani číslované `20`–`33` (vytvoří relikty ⇒ verify FAIL) |

### 11.11 Release brána (před tagováním)

Release je production-ready pouze když na reprezentativní čisté DB:
- `deploy_clean_v2_full.sql` (nebo `_SSMS`) nasazen s 0 chybami a `verify_clean_deploy.sql` = **PASS**;
- `selftest_acceptance.sql` = **PASS**;
- zákaznický seed aplikován a `arch.usp_ValidateConfiguration` bez ERROR (chybějící zdrojové indexy = WARN only);
- archive DB ve FULL recovery s FULL+LOG backup joby + úspěšný restore rehearsal (`048`);
- failure alerting živý (`047`) a dorazil test alert;
- console read granty aplikovány (`051`); Admin Console v **Production** s auth principálem; `/api/readiness` = `apiOk` + `databaseOk`;
- `arch.usp_Frontend_GoLiveReadiness` = **0 FAIL**;
- `production-readiness-checklist.md` podepsán.
- Ověřeno: `git diff --check`; žádný skript nemá destruktivní default bez explicitního flagu; Phase-14 joby (`047`/`048`/RECOVER STALE RUNS) validovány na Agent-enabled instanci.


---


## 12. Referenční chybové kódy a výkon

### 12.1 Přehled chybových kódů

Všechny řízené chyby kArchiveManageru 2.0 jsou vyhazovány přes `THROW <číslo>, <zpráva>, <stav>` (severity třída 16). Číselné rozsahy jsou rozvrženy tak, aby operátor podle čísla jednoznačně poznal, který obranný mechanismus zásah zablokoval, a aby se nepřekrývaly s historickými kódy:

| Rozsah | Mechanismus | Zdrojový skript |
|---|---|---|
| `50001`–`50006` | P1.3 — validace `RunProfile` + blokace legacy v1.0 procedur | `v2/020`, `v2/025` |
| `50100`–`50115` | TIMESTAMP runner — validace parametrů a běhu | `v2/027` |
| `50200` | Timezone gate (P0.5 Risk K1) | `v2/035` |
| `50210`–`50216` | Retention floor + legal-hold (T-21) | `v2/056`, `v2/014`, `v2/027`, `v2/015` |
| `50220`–`50223` | Copy-only / dedup (Mode=2) | `v2/057`, `v2/027`, `v2/015` |
| `50300`–`50301` | Kooperativní stop běhu | `v2/040` |
| `50400` | Safe-expression validator (T-05) | `v2/046` |
| `50400`–`50405` | Restore / purge archivu (T-27) | `v2/042` |
| `50410` | Schema drift archivu (BLOCK, T-19) | `procedures/arch.usp_EnsureArchiveTableLikeSource` |
| `56306`–`56313` | Workflow change-setu + 4-eyes (T-06) | `frontend/004_frontend_audit` |

> **Pozn. ke kolizi 50400:** kód `50400` se používá ve dvou nesouvisejících kontextech — v `v2/046` jako odmítnutí nebezpečného SQL výrazu a v `v2/042` jako „zdrojová databáze neexistuje“. Obě procedury běží v jiném okamžiku (validace konfigurace vs. restore), takže nedochází k záměně; rozlišujícím faktorem je text zprávy. Restore navíc obsazuje souvislý blok `50400`–`50405`.

### 12.2 Detailní tabulka chybových kódů

| Kód | Procedura | Význam / kdy nastane | Zpráva (verbatim) |
|---|---|---|---|
| `50200` | `arch.usp_AssertTimezonePolicyApplied` | REAL DELETE (`@DryRun=0`), kde `AnchorTimestampExpr` (ANCHOR) nebo `TimestampExpr` (TIMESTAMP) NEobsahuje `AT TIME ZONE` → cutoff není UTC-normalizovaný (P0.5 Risk K1). Dry-run je vyňatý. | `Timezone policy not applied (P0.5 Risk K1): ... is not UTC-normalized ... Wrap it with AT TIME ZONE before running real deletes. Delete blocked.` |
| `50210` | `arch.usp_AssertRetentionFloor` | REAL DELETE, kde efektivní cutoff je novější než `now - MinRetentionDays` → run by smazal řádky uvnitř povinného retenčního okna. Pokrývá cutoff odvozený z `RetentionDays` i z `CutoffDate`. Volá se z 027 (`@CutoffUtc`) i 015 (`WorkBatch.RangeToUtc`); preventivně i z 014 při přípravě. | `Retention floor violation: effective cutoff ... is more recent than the policy floor (now - N days = ...). Real deletes blocked. ...` |
| `50211` | `arch.usp_AssertRetentionFloor` | Gate zavolán s `@CutoffUtc IS NULL` při aktivním floor (`MinRetentionDays > 0`) — fail-closed (NULL nesmí tiše projít UNKNOWN porovnáním). | `usp_AssertRetentionFloor called with NULL @CutoffUtc (cannot evaluate the retention floor).` |
| `50212` | `arch.usp_Api_SetRetentionFloor` | Pokus nastavit `MinRetentionDays < 0`. | `MinRetentionDays must be >= 0.` |
| `50213` | `arch.usp_Api_AddLegalHold` | `@ProcessCode` prázdný / NULL. | `@ProcessCode is required.` |
| `50214` | `arch.usp_Api_AddLegalHold` | `@HoldKey` prázdný / NULL. | `@HoldKey is required.` |
| `50215` | `arch.usp_Api_AddLegalHold` | `@Reason` chybí nebo má < 6 znaků (vyžadováno pro audit trail). | `@Reason is required (>= 6 chars) for the audit trail.` |
| `50216` | `arch.usp_Api_ReleaseLegalHold` | Legal hold s daným `@LegalHoldId` neexistuje nebo už byl uvolněn. | `Legal hold not found or already released.` |
| `50220` | `arch.usp_GetCopyDedupInfo` | Mode=2 (copy-only) na zdrojové tabulce BEZ PRIMARY KEY — nelze idempotentně deduplikovat. | `Copy-only (Mode=2) requires a PRIMARY KEY on the source table for idempotent dedup; none was found.` |
| `50221` | `arch.usp_GetCopyDedupInfo` | Mode=2: PK existuje, ale nepodařilo se odvodit predikát NOT-EXISTS pro dedup. | `Copy-only (Mode=2): could not derive the source primary-key dedup predicate.` |
| `50222` | `arch.usp_RunTimestampProcess` (027) | Mode=2 v TIMESTAMP runneru: chybí PK dedup predikát v okamžiku copy. | `Copy-only (Mode=2) is missing the source-PK dedup predicate (no PRIMARY KEY?).` |
| `50223` | `arch.usp_RunPreparedBatch` (015) | Mode=2 v ANCHOR runneru: chybí PK dedup predikát. | `Copy-only (Mode=2) requires a PRIMARY KEY on the source table for dedup (predicate missing).` |
| `50300` | `arch.usp_Api_RequestRunStop` | `@RunId IS NULL`. | `@RunId is required.` |
| `50301` | `arch.usp_Api_RequestRunStop` | Run s daným `@RunId` neexistuje. | `Run not found.` |
| `50400` | `arch.usp_AssertSafeSqlExpression` (046) | Free-text konfigurační výraz obsahuje terminátor `;`, komentář, DDL/DML klíčové slovo, `xp_`/`sp_` odkaz nebo nevyvážené závorky (stored second-order SQL injection, T-05). | `Unsafe SQL in advanced configuration field [...]: <důvod>. It must be a single scalar/boolean expression ...` |
| `50400` | `arch.usp_RestoreFromArchive` (042) | Zdrojová DB (`@SourceDb`) neexistuje. | `Source database does not exist.` |
| `50401` | `arch.usp_RestoreFromArchive` | Archivní DB (`@ArchiveDb`) neexistuje. | `Archive database does not exist.` |
| `50402` | `arch.usp_RestoreFromArchive` | Mapping process/source/archive nenalezen. | `Process/source/archive mapping not found.` |
| `50403` | `arch.usp_RestoreFromArchive` | Proces nemá žádný enabled `ObjectSpec` k restore. | `Process has no enabled ObjectSpec to restore.` |
| `50404` | `arch.usp_RestoreFromArchive` | `@PurgeArchive=1` a volající NENÍ členem `karch_approver` (a není `sysadmin`). | `Purging the archive requires membership in karch_approver.` |
| `50405` | `arch.usp_RestoreFromArchive` | `@PurgeArchive=1` a efektivní `AuditLevel` mappingu je < `ROW` — archiv je jediná per-row stopa smazaných řádků, purge zablokován. | `Purging the archive is blocked for mappings with AuditLevel < ROW ...` |
| `50410` | `arch.usp_EnsureArchiveTableLikeSource` | Schema drift: zdrojový sloupec změnil typ na nekompatibilní (ne pouhé rozšíření) vůči archivu → tichý truncate/overflow do jediné kopie smazaných dat (T-19). Stejný typ + širší = WIDEN (auto), archiv dost široký = OK, jinak BLOCK. | `Schema drift would corrupt the only copy of deleted data on archive ... (incompatible source column type change). Reconcile the archive manually before running. Columns: ...` |
| `56310` | `arch.usp_SetConfigChangeSetStatus` | 4-eyes: schvalovatel/publisher = žadatel (`RequestedBy`) — zákaz sebeschválení (case-insensitive porovnání). | `Segregation of duties: the approver/publisher must differ from the requester (RequestedBy).` |
| `56311` | `arch.usp_SetConfigChangeSetStatus` | 4-eyes: schvalovat/publikovat smí jen člen `karch_approver` (`sysadmin` obchází). | `Only members of karch_approver may approve or publish a configuration change set.` |
| `56312` | `arch.usp_SetConfigChangeSetStatus` | Stavový automat: přechod na `PUBLISHED`, ač change set není `APPROVED`. | `A change set must be APPROVED before it can be PUBLISHED.` |
| `56313` | `arch.usp_SetConfigChangeSetStatus` | Stavový automat: přechod na `APPROVED` z jiného stavu než `PENDING_APPROVAL` (resp. `APPROVED`). | `Only a PENDING_APPROVAL change set can be APPROVED.` |

> **Doplňkové kódy ve stejné proceduře (`frontend/004`):** `56306` (neplatný `ChangeStatus`), `56307` (neplatný `ValidationStatus`), `56308` (`Actor` je povinný), `56309` (`ConfigChangeSetId` neexistuje). Tvoří kontext pro 4-eyes gate `56310`–`56313`.

#### Společné rysy gate-procedur

- **Dry-run je vždy vyňatý.** Timezone gate (`50200`) i retention floor (`50210`) se kontrolují pouze při `@DryRun=0`, takže náhled kandidátů funguje i před aplikací TZ politiky / nastavením floor. To umožňuje bezpečnou validaci nového zdroje předtím, než je obrana plně nakonfigurována.
- **Fail-closed.** `50211` ilustruje princip: NULL hodnota nikdy tiše neprojde — porovnání `@CutoffUtc > @earliest` by s NULL vrátilo UNKNOWN, proto se NULL explicitně odmítne.
- **Backward-compatible defaulty.** `MinRetentionDays = 0` floor vypíná (no-op `RETURN`); legal-hold register je prázdný → exkluze nic neudělá. Obrany se aktivují až zákazníkovou konfigurací.
- **Idempotence vícenásobného volání.** `usp_Api_RequestRunStop` používá `COALESCE` (first-writer-wins) na `CancelRequestedBy`/`CancelReason`, takže opakovaný stop nepřepíše původní atribuci; `usp_Api_AddLegalHold` vrátí existující aktivní hold místo duplikátu.

##### Příklady volání

```sql
-- Nastavení retenčního floor (jen karch_approver) — pod floor se reálné mazání zablokuje 50210
EXEC arch.usp_Api_SetRetentionFloor @MinRetentionDays = 365, @RequestedBy = N'jan.novak';

-- Přidání legal-hold na Key1 (compliance akce; < 6 znaků reason => 50215)
EXEC arch.usp_Api_AddLegalHold
     @ProcessCode = N'RF_LOG2', @HoldKey = N'1234567', @Reason = N'litigation #4471', @SourceDb = N'Edge';

-- Kooperativní stop běhu (po dokončení rozpracované dávky; 50301 když RunId neexistuje)
EXEC arch.usp_Api_RequestRunStop @RunId = 9001, @RequestedBy = N'op.svc', @Reason = N'window over';
```

### 12.3 Mapování `SqlException` → HTTP (T-26)

Admin Console API (`Program.cs`) zachytává `SqlException` v middleware a místo paušálního „503 — zkontroluj ConnectionStrings“ ji klasifikuje. Klasifikace je vyčleněna do čisté, jednotkově testovatelné třídy `SqlErrorClassifier` (`Api/SqlErrorClassifier.cs`), protože `SqlException`/`SqlError` nemají veřejný konstruktor — `Program.cs` proto promítne `exception.Errors` na n-tice `(e.Number, e.Class)` a předá je metodě `Classify`.

#### Klasifikace `(Number, Class)` → `SqlErrorCategory`

```csharp
if (number >= 50000 || cls == 16) business = true;
else if (number is 1205 or 1222 or -2) transient = true;
else if (number is 229 or 230 or 262 or 297 or 300) permissionDenied = true;
```

| `SqlErrorCategory` | Spouštěč (Number / Class) | Význam |
|---|---|---|
| `BusinessRule` | `Number >= 50000` **nebo** `Class == 16` | Záměrný `THROW`/`RAISERROR` business odmítnutí (všechny kódy z 12.2 sem spadají — leží nad 50000). |
| `Transient` | `1205` (deadlock victim), `1222` (lock-request timeout), `-2` (command timeout) | Přechodný, opakovatelný stav; databáze je v pořádku. |
| `PermissionDenied` | `229`, `230`, `262`, `297`, `300` | Chybí `GRANT` pro app-pool / runtime principal = serverová misconfigurace. |
| `Unavailable` | cokoli ostatní (default) | DB nedosažitelná / selhání spojení či zdroje. |

**Přesnost (precedence):** pokud `SqlException` nese více chyb, vyhrává v pořadí `BusinessRule` → `Transient` → `PermissionDenied` → `Unavailable`. Záměrný business `THROW` má přednost (nese operátorovi srozumitelnou zprávu), pak retryable stav, pak RBAC mezera, jinak nedosažitelnost.

#### HTTP odpovědi (`Program.cs`)

| Kategorie | HTTP status | Hlavičky | Tělo (`detail`) | Logování |
|---|---|---|---|---|
| `BusinessRule` | `400 Bad Request` | — | `error: "Configuration change rejected."`, `detail = exception.Message` (předá se text `THROW`) | `LogInformation` |
| `Transient` | `503 Service Unavailable` | `Retry-After: 2` | „A transient database condition (deadlock, lock timeout or command timeout) interrupted the request. Retry in a moment.“ | `LogWarning` |
| `PermissionDenied` | `500 Internal Server Error` | — | „A required database permission is missing. Contact the administrator (see server logs).“ — **nikdy** neprozradí, který objekt/oprávnění chybí | `LogError` |
| `Unavailable` | `503 Service Unavailable` | — | „Check ConnectionStrings:ArchiveManagerAdmin and verify that kArchiveManagerAdmin is reachable.“ | `LogError` |

Každé tělo navíc obsahuje `traceId = context.TraceIdentifier` pro korelaci s logem. Detail business zprávy se klientovi ukazuje záměrně (např. „ProcessCode does not exist.“); detail RBAC chyby se logy drží jen na serveru.

> **Motivace (Finding F1, 2026-06-02 + T-26):** před touto klasifikací padaly deadlock/timeout/permission-denied všechny do zavádějícího 503 „check ConnectionStrings“, i když databáze byla dosažitelná. Emergency Stop tlačítko (grant na `karch_operator` v `v2/040`) bez správného grantu vracelo generické 503 — viz proč je permission-denied nyní samostatná kategorie.

### 12.4 Výkon: naměřené hodnoty

Referenční zátěž = tabulka `RF_LOG2` (vysokoobjemový log; ~16 nonclustered indexů). Strategie TIMESTAMP přes `arch.usp_RunTimestampProcess`: kandidáti se vyberou **jednou** do `#Candidates` (klíč `ROWID`), pak se po dávkách (`BatchRowCount`, default 50000) maže přes `DELETE t … OUTPUT deleted.* INTO <archiv>` joinem na `#Batch` přes `ROWID`. Invariant Mode=1: `Divergence = 0` (archivováno == smazáno), atomicky.

Měřeno na `RADIM-STACHAL\RSTSQL2022`, `Edge.RF_LOG2`:

| Objem | `AuditLevel` | Doba | Průtok | Poznámka |
|---|---|---|---|---|
| 5 000 000 | `NONE` | ~31,2 min (1 873 s) | ~2 669 ř/s | z toho candidate-scan ~220 s |
| 5 000 000 | `ROW` (per-doc audit) | ~34,7 min (2 082 s) | ~2 401 ř/s | +5 000 000 řádků do `arch.RunDocAudit`; `Divergence = 0` |
| 10 000 000 | `NONE` | ~52,5 min (3 148 s) | ~3 177 ř/s | čistý běh (první pokus 66 h kvůli víkendovému lock-waitu) |

**ROW audit stojí ~+11 % wall-clock (−10 % průtoku) oproti `NONE`** na 5M běhu (2 082 vs 1 873 s) — jde o 5 milionů plně logovaných audit-insertů do Admin DB. Pro velkoobjemové logy proto `NONE`/`BATCH`; `ROW` jen tam, kde je nutná per-doc evidence.

### 12.5 Úzké hrdlo

Měření ukazuje, že **~98 % času je per-row fyzická práce při `DELETE`**, nikoli výběr kandidátů:

- `DELETE` na zdroji udržuje **clustered PK + KAŽDÝ nonclustered index** tabulky (`RF_LOG2` jich má ~16) → ~17 logovaných index-maintenance operací na každý smazaný řádek.
- `OUTPUT … INTO <archiv>` je **vždy plně logovaný** cross-DB zápis (archiv je ve FULL recovery kvůli durabilitě).

Candidate-scan je sekundární náklad (~220 s z 1 873 s) a po sargable cutoffu (C3) ho lze srazit na index seek.

### 12.6 Páky (seřazeno podle dopadu)

1. **`AuditLevel = NONE` pro velkoobjemové logy.** `ROW` audit přidá jeden `arch.RunDocAudit` řádek na dokument (5M běh → +5M plně logovaných řádků do Admin DB). Pro `RF_LOG2` doporučeno **`NONE`** (archivní řádky jsou samy důkazem) nebo **`BATCH`** (run-level); `ROW` jen když je vyžadována per-doc evidence.

2. **Index-parking — `deploy/v2/052` (`arch.usp_RunTimestampProcessParked`).** Zaparkuje (`DISABLE`) nepotřebné NC indexy zdrojové tabulky na dobu běhu (keep-list = candidate index + clustered PK), po běhu je `REBUILD`ne. Odstraní údržbu zaparkovaných indexů z každého `DELETE` → **~1,5× rychleji** (měřeno 3 230 → 5 073 ř/s). Nejsilnější u **backlog drainů** (smažeš většinu řádků → rebuild jen přes pár přeživších). DBA helper — vyžaduje `ALTER` na zdroji, guarded rebuild i při selhání, jen v maintenance window.

3. **Sargable cutoff — C3 (`CandidateWhereSql`).** Přesný predikát `<TimestampExpr> < @CutoffUtc` NENÍ sargable (sloupec je uvnitř `AT TIME ZONE`/funkce → full scan, ~3–4 min jen na výběr kandidátů na 10M `RF_LOG2`). Mitigace: do `CandidateWhereSql` (vystaveno v 027 i v ANCHOR prep 014) přidat **konzervativní sargable mez na raw indexovaný sloupec** odkazující parametr `@CutoffUtc`:

   ```sql
   -- arch.Process.CandidateWhereSql (nebo per-DB override):
   [DATE_TIME] < DATEADD(HOUR, 26, @CutoffUtc)
   ```

   Funkce je na **straně parametru**, raw sloupec vlevo → index **seekuje** k mezi místo scanu. `26` hodin je záměrně volný superset (žádný TZ posun nepřekročí ~14 h + DST rezerva), takže nikdy nevyřadí eligible řádek; přesný `TimestampExpr < @CutoffUtc` predikát stále běží a výsledek zpřesní. **Bezpečnost:** mez je ANDovaná *navíc* k přesnému predikátu — příliš těsná mez může jen **pod-zahrnout** (archivace řádku se odloží), nikdy nesmaže řádek, který měl zůstat, ani nesmaže-bez-archivace. Ověř dry-runem: počet kandidátů s mezí se musí rovnat počtu bez meze; je-li nižší, mez uvolni. Velká výhra v **ustáleném provozu**; u backlog drainu (většina řádků pod cutoffem) scan-výhra mizí.

4. **Index hygiena na zdroji.** `ROWID` unikátně indexovaný (candidate join) + `(DATE_TIME, ROWID)` (candidate scan). Doporučené tvary pro běžné zdroje: `RF_LOG2` → `DATE_TIME, ROWID` + `ROWID` join index; `DNLOAD_ARCHIVE` → `date_archived, ROWID`; `UPLOADARCHIVE` → computed `KAM_TIMESTMP_DT` parsovaný z `TIMESTMP`, indexovaný s `ROWID`. Mandatorní indexy se deklarují v `arch.IndexRequirement` (typy `SELECTION`/`JOIN`/`DELETE`/`ORDER`/`PARTITION`) a ověřují `arch.usp_ValidateIndexRequirements`.

5. **Velikost dávky + okno.** `BatchRowCount` ~50000 je rozumný kompromis (růst logu vs. overhead); nad ~50k roste log/lock tlak. Menší dávka (≤4000) + `ROWLOCK` snižuje lock-escalation/kontenci (T-18) za cenu průtoku. Velké drainy v **maintenance window** + hlídat `WRITELOG`/`PAGEIOLATCH_*`/`LCK_*` (66h incident = víkendová kontence).

### 12.7 Extrémní objem (desítky M+ / běh): partition switch

Pro skutečně velký, časově řazený log je nejrychlejší archivace **partition switch**: je-li `RF_LOG2` partitionovaná podle data a archivní tabulka zarovnaná, archivace celé staré partition je `ALTER TABLE … SWITCH PARTITION` = **metadata-only, prakticky okamžité** (žádné per-row mazání ani logování milionů řádků). `SelectionStrategy` má rezervovanou hodnotu `PARTITION`. Vyžaduje **partitionovaný zdroj** (zásah do zákazníkova schématu) + zarovnaný archiv — proto roadmap-volba, ne quick-win. Pro `RF_LOG2` s trvale vysokým přírůstkem je to správná cílová architektura; pro jednorázový backlog drain stačí index-parking (052) + `NONE` audit.

### 12.8 Co bylo zamítnuto

- **Minimal/BULK_LOGGED logování** — `OUTPUT … INTO` je vždy plně logované; archiv je navíc FULL recovery.
- **Paralelní streamy** — applock proces serializuje (jeden běh na proces/zdroj); paralelizace by tříštila I/O.
- **Větší batch jako samospásné** — marginální; nad ~50k roste log/lock tlak.

### 12.9 Co měřit před/po

Elapsed RUNu · `RowsDeleted`/`RowsArchived` (musí `Divergence = 0`) · růst logu zdroj + archiv · wait types (`WRITELOG`, `PAGEIOLATCH_*`, `LCK_*`) · skutečný plán candidate-scanu (seek vs scan) a delete-joinu.

#### Mode=2 (copy-only): jak číst metriky

Mode=2 je nedestruktivní a idempotentní (kopíruje jen řádky, které v archivu nejsou — `NOT EXISTS` na zdrojovém PK). Pozor na čtení výsledků:

- **`RowsArchived`** (`RunItem`/`RunItemObject`) = řádky **skutečně zkopírované** tento běh — autoritativní „co bylo zpracováno“.
- **`DocsDone`** = zvážení kandidáti (na idempotentním re-runu `NOT EXISTS` zkopíruje 0 řádků, ale `DocsDone` reflektuje znovu-naskenované kandidáty).

Pro „kolik bylo nově zazálohováno“ čti `RowsArchived`, ne `DocsDone`. Dedup index (`IX_kAMCopyDedup`) je **non-unique** záměrně (archiv sdílený s Mode=1 historií může legitimně držet víc řádků na jeden zdrojový PK); dedup vynucuje per-statement `NOT EXISTS`.


---
