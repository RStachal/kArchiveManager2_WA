# kArchiveManager 2.0 — Geneze a ucelená dokumentace

**Verze produktu:** 2.0 (zpevněný / audit-hardened build)
**Datum dokumentu:** 2026-06-04
**Vlastník:** Radim Stachal / KODYS
**Určeno pro:** provozní administrátory, DBA, nasazovací inženýry a zákaznický tým

> Tento dokument je „od kořene": vysvětluje princip chodu aplikace v kostce a srozumitelně,
> popisuje zásadní funkcionality, ovládání Admin Console, validační a bezpečnostní mechanismy
> při zpracování dat, auditní systém, výkon a dopad na produkci a doporučené best practices.
> Popisuje **aktuální zpevněný stav** (čistý v2 build po produkčním auditu) — ne historický stav v1.

---

## Obsah

1. [Princip chodu aplikace v kostce](#1-princip-chodu-aplikace-v-kostce)
2. [Zásadní funkcionality](#2-zásadní-funkcionality)
3. [Admin Console — možnosti, nastavení a ovládání](#3-admin-console--možnosti-nastavení-a-ovládání)
4. [Validace dat a bezpečnostní mechanismy při zpracování](#4-validace-dat-a-bezpečnostní-mechanismy-při-zpracování)
5. [Auditní systém aplikace](#5-auditní-systém-aplikace)
6. [Výkon a dopad na produkci](#6-výkon-a-dopad-na-produkci)
7. [Best practices pro práci s aplikací](#7-best-practices-pro-práci-s-aplikací)
8. [Příloha A — slovníček objektů](#příloha-a--slovníček-klíčových-objektů)
9. [Příloha B — chybové kódy](#příloha-b--chybové-kódy)

---

## 1. Princip chodu aplikace v kostce

**kArchiveManager** je univerzální nástroj pro SQL Server, který **řízeně promazává a volitelně
archivuje historická data** mimo provozní (zdrojové) databáze. Neřeší jeden pevně „zadrátovaný"
proces — je to **konfigurační framework**: chování je popsáno metadaty, ne procedurou na míru.
Nový proces se přidá *konfigurací*, ne psaním nové speciální mazací procedury.

### 1.1 Tři databázové role

| Databáze | Účel | Obsah |
| --- | --- | --- |
| **kArchiveManagerAdmin** (řídicí) | Mozek systému | Konfigurace, plánování, stav rozpracované práce, audit, monitoring. **Neobsahuje archivovaná data.** |
| **kArchiveManagerBackups** (archivní) | System-of-record smazaných dat | Archivované řádky, oddělené schématy podle zdrojové DB (`Edge`, `KMWEBV`, …). Doporučen režim FULL recovery. |
| **Zdrojové databáze** (zákaznické) | Provozní data | Aplikace z nich po dávkách maže; **nikdy nemění schéma ani business logiku**. |

### 1.2 Životní cyklus jednoho běhu (3 fáze)

Každý proces běží ve třech explicitních fázích — to je jádro celé architektury:

```
1. SELECT   → vyber kandidáty do resumovatelného keysetu (podle strategie procesu)
2. ARCHIVE  → (jen Mode=1) vlož vybrané řádky do archivní DB
3. DELETE   → smaž zdrojové řádky JOINem na materializovaný keyset, po dávkách
```

Důsledek tohoto návrhu: runner **nikdy neskenuje opakovaně velké zdrojové tabulky** generickým
`DELETE TOP` s predikátem. Kandidáti se vyberou jednou, zapíší do keysetu a maže/archivuje se
přes indexovaný join. Zápis auditu a výsledku po objektech jde do Admin DB.

### 1.3 Řetězec spuštění (oficiální v2 cesta)

```
arch.usp_RunProfile_Prepared            -- vstupní bod: 1 run profil (pro SQL Agent i ad hoc)
  └─ arch.usp_RunConfiguredProcesses_Prepared   -- vybere procesy podle filtru
       ├─ ANCHOR strategie:
       │    arch.usp_PrepareCandidates          -- naplní WorkBatch + WorkBatchKey
       │      └─ arch.usp_RunPreparedBatches_InWindow
       │           └─ arch.usp_RunPreparedBatch  -- archive + delete jedné dávky
       └─ TIMESTAMP strategie:
            arch.usp_RunTimestampProcess         -- časový cutoff bez velkého keyset stagingu
```

> **Pravidlo č. 1:** Pro veškerý produkční provoz se používá **výhradně** `usp_RunProfile_Prepared`
> (případně `usp_RunConfiguredProcesses_Prepared` pro ad hoc). V1.0 procedury (`usp_RunProcess`,
> `usp_RunProcess_RF_LOG2`, `usp_RunProcess_TimestampKeyset`, `usp_RunWorkBatch…`) **v čistém
> zákaznickém buildu vůbec neexistují** — build je čistě v2. (Na upgradovaném prostředí jsou
> případně karanténované/blokované.)

### 1.4 Dvě nezávislé „páky" provozu

Vždy se rozhoduje ve dvou nezávislých osách:

- **Run mode** — `@DryRun = 1` (náhled, nic nemaže/nearchivuje) vs. `@DryRun = 0` (reálné zpracování).
- **AuditLevel** — `NONE` / `BATCH` / `OBJECT` / `ROW` (kolik důkazů se zapíše o reálném běhu).

`@DryRun` řídí, jestli se data mění. `AuditLevel` řídí, kolik se zapíše stop. Viz §5.

### 1.5 Konfigurační model šablona → override

```
arch.Process            (šablona procesu — společná pro všechny DB)
   ↓ přepisuje per-DB
arch.ProcessDatabase    (mapování proces × zdrojová DB × archivní DB — runtime override)

arch.ObjectSpec         (tabulky, které proces zpracovává)
   ↓ přepisuje per-DB
arch.ObjectSpecDatabaseOverride  (odchylky objektu v jedné DB)
```

Runtime **nečte tyto tabulky přímo** — čte **efektivní views**, které slučují šablonu a override
a u každé hodnoty ukazují i její původ:

- `arch.v_ProcessDatabaseEffective` — výsledná konfigurace procesu pro danou DB (+ `RetentionDaysSource`, `AuditLevelSource`, `CutoffDateSource`).
- `arch.v_ObjectSpecDatabaseEffective` — výsledná objektová konfigurace.

**Pravidlo vyhodnocení:** je-li hodnota nastavená v `ProcessDatabase` → použije se ta; jinak se
použije šablona z `Process`.

---

## 2. Zásadní funkcionality

### 2.1 Univerzální, metadaty řízené promazávání
- Tři režimy zpracování: **Mode = 1** archivace + mazání (přesun do archivu, pak smazání zdroje),
  **Mode = 0** mazání bez archivace (delete-only), a **Mode = 2** **kopie bez mazání** (copy-only /
  idempotentní záloha): zkopíruje vybrané řádky do archivu, **zdroj nikdy nemaže** a vkládá jen řádky,
  které v archivu ještě nejsou (dedup podle PK zdroje). Re-run je idempotentní (zkopíruje 0 nových).
  `RowsArchived` udává skutečně zkopírované řádky. Vyžaduje PRIMARY KEY na zdrojové tabulce.
- Jeden proces nad **více zdrojovými databázemi**; jedna nebo více archivních DB.
- Oddělení archivních dat podle zdroje (doporučeno `ArchiveSchema = N'{SourceDb}'`).
- Per-databázové odchylky bez kopírování procesu.

### 2.2 Strategie výběru kandidátů (`SelectionStrategy`)

| Strategie | Kdy použít | Aktivně používané |
| --- | --- | --- |
| **ANCHOR** | Dokladové modely (parent + child tabulky) — `RECEIVING`, `SHIPPING` | ✅ |
| **TIMESTAMP** | Velké historické/log tabulky řízené časovým cutoffem — `RF_LOG2`, integrace | ✅ |
| KEYSET | ID dodává zákazník / upstream proces | připraveno v metadatech |
| RANGE | Monotónní ID / sekvence | připraveno |
| PARTITION | Velké časově partitionované tabulky (switch/truncate) | připraveno |
| CUSTOM_QUERY | Neobvyklý zákaznický model | připraveno |
| ORPHAN | Child řádky bez parenta (indexovaný anti-join) | připraveno |
| SOFT_DELETE | Úklid podle status/flag sloupce | připraveno |

### 2.3 Batchování a časová okna
- `BatchDocCount`, `BatchRowCount`, `MaxBatchesPerRun`, `DelayMsBetweenBatches` — bezpečné dávkování.
- `RunWindowMinutes` / `@StopAtUtc` — běh se sám ukončí na konci časového okna.
- `MaxRowsPerTransaction` — limit velikosti transakce (růst logu).

### 2.4 Resumovatelnost, souběh a samoléčení
- `WorkBatch` + `WorkBatchKey` (statusy 0=připraveno, 1=claimnuto, 2=hotovo, 3=chyba) — zpracování po klíčích lze přerušit a navázat.
- `UseAppLock` / `AppLockResource` / `LockTimeoutMs` / `DeadlockPriority` — ochrana souběhu.
- **Liveness tracking** (`Run.WorkerSessionId`, `WorkerSessionLoginTimeUtc`) — běh je svázaný se session workera.
- **Recovery zaseknutých běhů** — `arch.usp_RecoverStaleRuns` + SQL Agent job *RECOVER STALE RUNS*: osiřelé běhy se samy uvolní.
- **Storno běhu** — `Run.CancelRequestedAtUtc` + `arch.usp_Api_RequestRunStop`: kooperativní zastavení.

### 2.5 Obnova z archivu (restore)
- `arch.usp_RestoreFromArchive` — round-trip zpět ze `kArchiveManagerBackups` do zdroje.
- Korektně vynechá `rowversion`/`timestamp` sloupce (`usp_GetOutputColumns @ExcludeRowversion = 1`) — jinak by restore selhal na „cannot insert explicit value into a timestamp column".

### 2.6 Validace a vysvětlení plánu
- `arch.usp_ValidateConfiguration` — konzistence konfigurace.
- `arch.usp_ValidateIndexRequirements` — existence zdrojových tabulek/sloupců/indexů podle metadat.
- `arch.usp_ExplainProcessPlan` — vysvětlí plán, objekty, strategii, klíče a indexové předpoklady.
- `arch.usp_EnsureArchiveTableLikeSource` / `usp_ProvisionArchiveTablesForProcess` — připraví archivní tabulky podle zdroje; **smiřuje typy sloupců** (WIDEN / OK / BLOCK).

### 2.7 Monitoring a operační zdraví
- `arch.v_OperationalHealth` — souhrnný „semafor" (řádky se `Severity = ERROR` = problém).
- `arch.v_LastRunPerProcess`, `arch.v_RunItemsRecent` — poslední běhy a jejich výsledky.

### 2.8 Go-live readiness (provozní brána)
- `arch.usp_Frontend_GoLiveReadiness` — **read-only** kontrola připravenosti k ostrému provozu, která kódově ověřuje výsledky produkčního auditu (privilegia, čistota, audit coverage, TZ gate, alerting, zálohy archivu…). Vrací verdikt READY / NOT READY a seznam kontrol. Dostupné i v Admin Console (záložka **Go-live**).

---

## 3. Admin Console — možnosti, nastavení a ovládání

Admin Console je webová aplikace (React SPA + .NET API), která je tenkou vrstvou nad Admin DB
procedurami (`arch.usp_Api_*` pro zápis, `arch.usp_Frontend_*` pro čtení). **Veškerý zápis jde
přes uložené procedury** — API nesestavuje žádné ad hoc DML nad konfigurací.

### 3.1 Navigace / obrazovky

| Záložka | Účel |
| --- | --- |
| **Dashboard** | Přehled stavu, pohybů a zdraví. |
| **RF/L charts** | Grafy pohybu (typicky RF/L logy). |
| **Runs** | Historie běhů (Run / RunItem / RunItemObject), detail, storno běhu. |
| **Document lookup** | Dohledání konkrétního dokladu/klíče — funguje jen pro procesy s `AuditLevel = ROW`. |
| **Configuration** | Editor konfigurace: Process, ProcessDatabase, ObjectSpec(+override), ProcessKeySpec, IndexRequirement, RunProfile. |
| **Validation** | Spuštění `ValidateConfiguration` / `ValidateIndexRequirements` / `ExplainProcessPlan`. |
| **Go-live** | Go-live readiness panel (viz §2.8) — verdikt + tabulka kontrol s doporučeními. |

### 3.2 Editace konfigurace (Configuration)
- Editor pracuje nad **efektivními views** — vidíš výslednou hodnotu i její původ (šablona vs. per-DB override).
- Každá změna se ukládá přes `usp_Api_Save*` proceduru a zaznamenává jako **change set** (kdo / kdy / důvod / které pole se změnilo). Editor konzole **vynucuje povinný důvod ≥ 6 znaků** — ale jde o **klientskou kontrolu v UI** (`ConfigurationEditor.tsx`); samotná `usp_Api_*` save procedura délku ani přítomnost důvodu nevaliduje (`@ChangeReason` je volitelný, NULL/prázdný projde). Přímý volající mimo konzoli (sqlcmd / API klient) tedy může uložit změnu bez důvodu. Viditelné v panelu **Change history**, exportovatelné do CSV.
- **Editační zámek (edit lock):** zapisovat smí jen autorizovaná session (viz §4.3). Token `X-Admin-Edit-Token` je svázán s reálnou identitou — audit připisuje změnu skutečnému operátorovi, ne servisnímu účtu API.
- **Nebezpečné změny vyžadují explicitní potvrzení v editoru** — např. vypnutí procesu, oslabení ochrany mazání, odebrání `AT TIME ZONE` z cutoff výrazu, nebo nastavení `AuditLevel = NONE` na proces v `Mode = 1` (nezablokuje, ale upozorní).

### 3.3 Volba auditu z konzole
Audit je **plně v rukou operátora** — vědomě se zapíná/vypíná a volí jeho způsob:
- `AuditLevel` lze nastavit na `arch.Process` (default) i na `arch.ProcessDatabase` (per-DB override).
- Kotva a klíče dokladu se řídí přes `AnchorDocKeyExpr` / `DocKeyLabel` (ANCHOR) a `ProcessKeySpec` (klíče kandidátů, typicky `ROWID`).

### 3.4 Nasazení a běh konzole (provozní)
- API: ASP.NET Core, čte connection string a sekci `AdminConsole` z `appsettings.json`.
- V Production je zapnut tvrdý gate `RequireAuthenticatedApi = true` (fail-fast při startu, pokud není autentizace nakonfigurovaná).
- IIS: zapnout **Windows Authentication** (a ponechat **Anonymous** pro SPA a read-only/readiness endpointy). Detaily viz [admin-console-iis-deployment.md](admin-console-iis-deployment.md) a [governance-model.md](governance-model.md).

---

## 4. Validace dat a bezpečnostní mechanismy při zpracování

Bezpečnost je řešena ve **vrstvách** — od konfigurace přes runtime gaty až po práva v DB.

### 4.1 Validace před spuštěním
- **Konzistence konfigurace** — `usp_ValidateConfiguration` (chybějící mapování, kolize, nevyplněné povinné hodnoty).
- **Indexové předpoklady** — `usp_ValidateIndexRequirements` ověří, že zdrojové tabulky/sloupce/indexy z `arch.IndexRequirement` reálně existují → brání pomalému/nebezpečnému běhu.
- **Smíření schématu archivu** — `usp_EnsureArchiveTableLikeSource`: stejný typ a širší = WIDEN, archiv dost široký = OK, nekompatibilní = **BLOCK (THROW 50410)**. Archiv tak nikdy tiše neořízne data.

### 4.2 Ochrana proti SQL injection ve volných výrazech (T-05)
Konfigurace obsahuje volně psané SQL fragmenty (`CandidateWhereSql`, `AnchorTimestampExpr`,
`TimestampExpr`, `JoinToAnchorPredicateSql`, `AdditionalWhereSql` …). Každý takový fragment
prochází při uložení validátorem **`arch.usp_AssertSafeSqlExpression`**, který odmítne:
- statement terminátor `;`, řádkové `--` i blokové `/* */` komentáře,
- DDL/DML/EXEC klíčová slova (jako celá slova — interpunkce se převede na mezery přes `TRANSLATE`),
- `xp_` / `sp_` prefixy,
- špatně zanořené závorky (skenuje hloubku).

Validátor je zadrátovaný do save procedur (`005`/`006`/`009`), takže nebezpečný výraz **vůbec
neuloží** — neřeší se to až za běhu. Odmítnutý výraz vyhodí **`THROW 50400`**.

### 4.3 Autorizace zápisu (tři koexistující cesty + role)
Editaci hlídá edit lock; autorizace se uděluje jednou ze tří cest (kontrolováno v tomto pořadí):

1. **Windows/AD identita** (doporučená produkční cesta) — přihlášený Windows uživatel musí být na allowlistu `AdminConsole:AdminUsers`. Bez hesla; editor ukáže „Editing as DOMAIN\user".
2. **Lokální operátorský účet** — `AdminConsole:Operators` (`Username` + `PasswordSha256` + `DisplayName`). Per-uživatel identita bez AD; audit připíše změnu jménem operátora.
3. **Sdílené heslo (fallback)** — `AdminConsole:EditPassword(Sha256)` → `X-Admin-Edit-Token`, pro dev / nouzový break-glass přístup.

Všechny tři razí stejný token svázaný s identitou (kvůli auditu). Odemčení je **rate-limited**.

**Databázový model rolí** (role a základní granty zakládá skript `010_frontend_security_roles`;
granty na **storno běhu** a **restore z archivu** dodávají skripty `040_run_cancel_support` resp.
`042_usp_RestoreFromArchive`, ne 010):

| Role | Smí | Grant z |
| --- | --- | --- |
| `karch_viewer` | čtení (Frontend_Get*), readiness panel, `SELECT` na Process/ProcessDatabase | 010 (+ 049) |
| `karch_operator` | validace/explain + **storno běhu** (`usp_Api_RequestRunStop`) | 010 (+ **040**) |
| `karch_config_admin` | ukládání standardní konfigurace (Save*, Set*Enabled) | 010 |
| `karch_advanced_admin` | klíče/indexy + **restore z archivu** (`usp_RestoreFromArchive`) | 010 (+ **042**) |
| `karch_approver` | change-set workflow (Create/Record/**Finalize**) | 010 |

Aplikační pool drží **jen role `karch_*`** — žádné DB-wide `EXECUTE` ani `db_datawriter`
(produkční audit, nález T-01, to kontroluje go-live readiness).

### 4.4 Volitelné 4-eyes schválení (T-06)
Nad standardní „audited immediate-publish" model lze vynutit oddělení pravomocí přes
`arch.usp_Api_FinalizeConfigChangeSet`, který hlídá:
- **žádné sebeschválení** — schvalovatel ≠ žadatel (`THROW 56310`),
- **jen `karch_approver`** (sysadmin obchází) smí schvalovat/publikovat (`THROW 56311`),
- **stavový automat** PENDING_APPROVAL → APPROVED → PUBLISHED, žádné přeskočení (`THROW 56312/56313`).

### 4.5 Časová brána cutoffu (Risk K1 / TZ gate)
Cutoff výrazy musí být normalizované na UTC:
```sql
CAST(... AS datetime2) AT TIME ZONE 'Central European Standard Time' AT TIME ZONE 'UTC'
```
Runtime to vynucuje přes **`arch.usp_AssertTimezonePolicyApplied`** — pokud reálný běh
(`@DryRun = 0`) narazí na cutoff bez `AT TIME ZONE`, vyhodí **`THROW 50200`** a proces neběží.
Brání to mazání podle špatně interpretovaného lokálního/UTC času (časový posun = jiná data).

### 4.6 Bezpečnost samotného mazání
- **Archive-before-delete invariant (Mode = 1):** zdrojový řádek se smaže **až po** úspěšném vložení do archivu, ve stejném transakčním rozsahu. Runtime hlídá **Divergence = 0** (RowsArchived == RowsDeleted) — nesoulad je chyba.
- `RequireArchiveForDelete` / `AllowDeleteWithoutArchive` — explicitní kontrola, zda objekt smí jít delete-only.
- Delete-only (`Mode = 0`) je vědomá volba, ne výchozí.

---

## 5. Auditní systém aplikace

### 5.1 Filozofie
Audit je **volba operátora**, ne vnucené chování. Aplikace umí od minimální provozní stopy po
plný per-dokladový důkaz; volí se vědomě podle objemu a požadavku na dohledatelnost.

### 5.2 Úrovně (`AuditLevel`)

| Úroveň | Zapisuje | Hlavní důkaz | Kdy |
| --- | --- | --- | --- |
| **NONE** | Run / RunItem / RunItemObject | Souhrn + archivní řádky | Velkoobjemový log (`RF_LOG2`) — archiv je důkaz |
| **BATCH** | Run / RunItem / RunItemObject | Souhrn na úrovni běhu/objektu | Stačí souhrnný důkaz |
| **OBJECT** | jako BATCH (objektové počty) | Per-objekt počty | Kompatibilita; chová se jako BATCH |
| **ROW** | + `arch.RunDocAudit` (1 řádek / doklad) | Per-dokladová stopa | Dokladové procesy, regulace, integrace s dohledatelností |

> `DRYRUN` (`@DryRun = 1`) je nezávislá osa: zapíše `Run`/`RunItem` se statusem `DRYRUN`, nahlásí
> počty kandidátů a cutoff, ale **nic nemaže/nearchivuje a nepíše `RunDocAudit`** (žádný řádek se reálně nezpracoval).

### 5.3 Auditní objekty (Admin DB)
- **`arch.Run`** — hlavička spuštění: source/archive DB, host, aplikace, uživatel, status, chyba, liveness session.
- **`arch.RunItem`** — detail za proces: cutoff, mode, počet dávek/dokladů, smazané a archivované řádky.
- **`arch.RunItemObject`** — souhrn po zdrojových objektech (kolik řádků smazáno/archivováno v každé tabulce).
- **`arch.RunDocAudit`** — per-klíč/doklad (jen `ROW`); navázáno na `RunItemId` → `RunItem.RunId` → `Run`.
- **`arch.ConfigChangeSet` / `ConfigChangeField` / `ConfigChangeItem`** — audit *konfiguračních* změn (kdo/kdy/proč/co).
- **`arch.ArchiveProvisionLog`** — log vytváření/kontroly archivních tabulek.
- **`arch.RestoreAudit`** — append-only log reálných restore/purge operací (kdo/proces/DB/purge/počty/čas; T-27).

### 5.4 Neměnnost auditu (T-09)
Auditní stopa je **tamper-resistant** — skript `045_audit_immutability` nasazuje:
- `DENY UPDATE, DELETE` na `RunDocAudit`, `ConfigChangeField`, `ConfigChangeItem`,
- `DENY DELETE` na `ConfigChangeSet`, `Run`, `RunItem`, `RunItemObject` (vůči `public`).

Společně s tím, že aplikační pool nedrží `db_datawriter` (T-01), nelze stopu přes konzoli ani
servisní účet přepsat či smazat.

### 5.5 Ověření auditu po běhu
```sql
-- Provozní zdraví (po každém reálném běhu)
SELECT TOP (100) * FROM arch.v_OperationalHealth ORDER BY LastActivityAtUtc DESC; -- 0 ERROR = OK

-- ROW audit: AuditRows musí odpovídat DocsDone
SELECT ProcessCode, SourceDb, ArchiveDb, ri.RunItemId, DocsDone, RowsDeleted, RowsArchived,
       AuditRows = COUNT_BIG(a.RunDocAuditId)
FROM arch.v_RunItemsRecent ri
LEFT JOIN arch.RunDocAudit a ON a.RunItemId = ri.RunItemId
WHERE ri.Status = N'OK' AND ri.DocsDone > 0
GROUP BY ProcessCode, SourceDb, ArchiveDb, ri.RunItemId, DocsDone, RowsDeleted, RowsArchived
ORDER BY ri.RunItemId DESC;
```
Pro `NONE`/`BATCH` se ověřuje přes `RunItemObject` a kontrolu archivních/zdrojových tabulek
(ne přes `RunDocAudit`, který je prázdný).

---

## 6. Výkon a dopad na produkci

**Cílový rozsah:** databáze 100–200+ GB, zdrojové tabulky 50–100M+ řádků.

### 6.1 Nepřekročitelné zásady (non-negotiables)
- Žádné produkční table scany při výběru kandidátů.
- Žádné neomezené (unbounded) DELETE.
- Žádné funkce na filtrovaných zdrojových sloupcích, pokud nejsou kryté perzistovaným počítaným sloupcem + indexem.
- Žádný velkoobjemový per-row audit ve výchozím stavu.
- Žádný delete mode před dry-runem, validací a revizí plánu.

### 6.2 Jak se minimalizuje dopad
- **Výběr kandidátů jednou** do `WorkBatchKey`, řazený podle indexovaného klíče/timestampu/partition.
- **Malé, resumovatelné dávky** — omezují růst transakčního logu.
- **`CandidateHash`** pro efektivní širší složené klíče.
- **Indexové požadavky** (`arch.IndexRequirement`, typy SELECTION/JOIN/DELETE/ORDER/PARTITION) jsou deklarované a validované.
- **TIMESTAMP strategie** nevytváří velký `WorkBatchKey` staging — vybírá přímo přes timestamp index (vhodné pro miliony řádků).
- Doporučené zdrojové indexy (např. `RF_LOG2`: `DATE_TIME, ROWID`; `DNLOAD_ARCHIVE`: `date_archived, ROWID`; `UPLOADARCHIVE`: počítaný `KAM_TIMESTMP_DT, ROWID`) viz [v2-performance-best-practices.md](v2-performance-best-practices.md).

### 6.3 Provozní pojistky
- Start s dry-runem a limity `MaxRowsPerTransaction`.
- Sledovat růst transakčního logu, wait types, lock escalation, deadlocky.
- Nízká `DeadlockPriority` pro úklidové joby.
- Krátký lock timeout + retry/resume místo dlouhého blokování.
- `READPAST` jen tam, kde je přeskočení zamčených řádků provozně přijatelné.
- Archivní tabulky vytvořené/validované **před** velkým produkčním během.

### 6.4 Dopad auditu na výkon
`ROW` audit produkuje řádově **100–1000× více** auditních řádků než `BATCH` (1 řádek na doklad
vs. 1 na dávku). Pro velkoobjemové procesy proto `NONE`/`BATCH`, `ROW` jen kde je per-dokladová
dohledatelnost skutečně potřeba.

### 6.5 Dopad na archivní DB
`kArchiveManagerBackups` je system-of-record smazaných dat → **musí mít vlastní zálohu**
(FULL + LOG) a restore drill. Skript `048_archive_db_backup` připraví joby (parametrizované,
nutno vyplnit cestu/retenci). Go-live readiness hlídá stáří poslední FULL zálohy.

---

## 7. Best practices pro práci s aplikací

### 7.1 Postup zavedení nového procesu
1. Šablona v `arch.Process` (kód, Mode, retence, cutoff, batch limity, strategie, `AuditLevel`).
2. Mapování v `arch.ProcessDatabase` (zdroj × archiv, per-DB odchylky).
3. Objekty v `arch.ObjectSpec` (+ `ObjectSpecDatabaseOverride` pro odlišnosti).
4. Klíče v `arch.ProcessKeySpec` (TIMESTAMP typicky `ROWID`).
5. Výkonnostní požadavky do `arch.IndexRequirement`.
6. **Validace:** `usp_ValidateConfiguration` + `usp_ValidateIndexRequirements` + `usp_ExplainProcessPlan`.
7. **Provision** archivních tabulek.
8. **Dry-run** a revize počtu kandidátů + cutoffu.
9. Malý **guarded reálný běh**, ověřit počty, archiv, mazání, audit, `v_OperationalHealth`.
10. Teprve pak povolit plánovaný běh.

### 7.2 Volba auditu (doporučené defaulty)
| Typ procesu | `AuditLevel` | Důvod |
| --- | --- | --- |
| Dokladová archivace/mazání (`RECEIVING`, `SHIPPING`) | `ROW` | Silný per-klíč důkaz |
| Velkoobjemový technický log (`RF_LOG2`) | `NONE` | Výkon a velikost Admin DB |
| Integrační historie | `ROW` pro piloty, pak `ROW`/`NONE` dle compliance | Závisí na dohledatelnosti |
| Nový/experimentální proces | `ROW` pro první piloty | Snazší ověření po běhu |

### 7.3 Časový cutoff
- Cutoff výrazy **vždy** s `AT TIME ZONE … AT TIME ZONE 'UTC'` (jinak `THROW 50200` v reálném běhu).
- Konzistentní cutoff politiku napříč DB (pozor na mix pevný `CutoffDate` vs. rolling retence).

### 7.4 Provozní disciplína
- Nikdy reálný běh bez předchozího dry-runu a revize plánu.
- Po každém běhu zkontrolovat `v_OperationalHealth` (0 ERROR).
- Zapnout job *RECOVER STALE RUNS* (samoléčení) a alerting (`047`) na ERROR ve `v_OperationalHealth`.
- Pravidelně zálohovat **archivní** DB a zkoušet restore.
- Konfigurační změny dělat přes konzoli (kvůli auditu) s **vypovídajícím důvodem**; nebezpečné změny vědomě potvrzovat.

### 7.5 Před ostrým provozem — Go-live readiness
Spustit `arch.usp_Frontend_GoLiveReadiness` (nebo záložku **Go-live**) a vyřešit **všechny FAIL**
před zapnutím reálných mazacích jobů. Verdikt READY/NOT READY + doporučení u každé kontroly.

### 7.6 Čeho se vyvarovat
- ❌ Volat v1.0 runner procedury (v čistém buildu neexistují; na upgradu jsou blokované).
- ❌ Obcházet edit lock nebo zápis konfigurace mimo `usp_Api_*`.
- ❌ Mazat/přepisovat auditní tabulky (chráněno DENY).
- ❌ Reálný běh s `AuditLevel = NONE` na dokladovém procesu, kde je potřeba dohledatelnost.
- ❌ Velký běh bez ověřených zdrojových indexů.

---

## Příloha A — slovníček klíčových objektů

**Konfigurace:** `arch.Process` (šablona) · `arch.ProcessDatabase` (per-DB override) ·
`arch.ObjectSpec` (tabulky) · `arch.ObjectSpecDatabaseOverride` · `arch.ProcessKeySpec` (klíče) ·
`arch.IndexRequirement` (indexy) · `arch.RunProfile` (profil běhu) · `arch.SelectionStrategy` (číselník).

**Efektivní views:** `arch.v_ProcessDatabaseEffective` · `arch.v_ObjectSpecDatabaseEffective`.

**Runtime/stav:** `arch.WorkBatch` · `arch.WorkBatchKey`.

**Audit/monitoring:** `arch.Run` · `arch.RunItem` · `arch.RunItemObject` · `arch.RunDocAudit` ·
`arch.ConfigChangeSet`/`ConfigChangeField`/`ConfigChangeItem` · `arch.ArchiveProvisionLog` ·
views `v_OperationalHealth`, `v_LastRunPerProcess`, `v_RunItemsRecent`.

**Runner:** `usp_RunProfile_Prepared` → `usp_RunConfiguredProcesses_Prepared` →
ANCHOR: `usp_PrepareCandidates` → `usp_RunPreparedBatches_InWindow` → `usp_RunPreparedBatch`;
TIMESTAMP: `usp_RunTimestampProcess`.

**Gaty/helpery:** `usp_AssertTimezonePolicyApplied` · `usp_AssertSafeSqlExpression` ·
`usp_EnsureArchiveTableLikeSource` · `usp_GetOutputColumns` · `usp_ValidateConfiguration` ·
`usp_ValidateIndexRequirements` · `usp_ExplainProcessPlan` · `usp_ProvisionArchiveTablesForProcess`.

**Provoz:** `usp_RecoverStaleRuns` · `usp_Api_RequestRunStop` · `usp_RestoreFromArchive` ·
`usp_Frontend_GoLiveReadiness` · `usp_Frontend_TimestampRetentionGaps` (T-20 retenční mezery).

**Role:** `karch_viewer` · `karch_operator` · `karch_config_admin` · `karch_advanced_admin` · `karch_approver`.

---

## Příloha B — chybové kódy

| Kód | Význam |
| --- | --- |
| `50200` | TZ gate: reálný běh narazil na cutoff bez `AT TIME ZONE` (Risk K1). |
| `50400` | Validátor volných SQL výrazů (T-05, `usp_AssertSafeSqlExpression`): výraz obsahuje terminátor `;` / komentář / nevyvážené závorky / zakázané klíčové slovo (DDL/DML/EXEC) nebo `xp_`/`sp_` prefix — uložení zablokováno. |
| `50404` | Restore purge (T-27): `@PurgeArchive=1` bez členství v `karch_approver` (sysadmin obchází). |
| `50405` | Restore purge (T-27): purge zablokován u mapování s AuditLevel < ROW (archiv je jediná per-row stopa). |
| `50410` | Smíření schématu archivu: nekompatibilní typ sloupce (BLOCK). |
| `56310` | 4-eyes: schvalovatel = žadatel (sebeschválení zakázáno). |
| `56311` | 4-eyes: schvalovat smí jen `karch_approver` (nebo sysadmin). |
| `56312` | 4-eyes: change set musí být APPROVED před PUBLISHED. |
| `56313` | 4-eyes: APPROVED jen z PENDING_APPROVAL. |

---

## Související dokumentace
- [v2-universal-architecture.md](v2-universal-architecture.md) — architektura a strategie.
- [v2-operational-modes.md](v2-operational-modes.md) — run mode × audit level detailně.
- [audit-model.md](audit-model.md) · [governance-model.md](governance-model.md) — auditní a governance model.
- [v2-performance-best-practices.md](v2-performance-best-practices.md) — výkon ve velkém měřítku.
- [runtime-execution-paths.md](runtime-execution-paths.md) — ⚠️ historické (zmiňuje neexistující `WorkBatchHistory` a blokované v1 procedury); aktuální runtime cesta je v §1.3 výše.
- [production-go-live-runbook.md](production-go-live-runbook.md) · [admin-console-customer-deploy-runbook.md](admin-console-customer-deploy-runbook.md) — nasazení a go-live.
- Čistý deploy: `legacy/ArchiveManager1.0/deploy/v2/release-package/` (deploy_clean_v2_full.sql + verify + selftest).
