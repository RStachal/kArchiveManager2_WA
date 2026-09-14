# RF_LOG2 — výkon zpracování velkého objemu (analýza + páky)

**Cíl (2026-06-12):** zpracovat **5 000 000 řádků ≤ 30 min** (≥ ~2 800 ř/s) i na tabulce **až 100 M řádků**,
za **constraintů zákazníka**: (a) **nelze nasazovat žádné nové indexy** na zdrojové tabulky, (b) tabulku
**nelze dlouho blokovat** (→ vylučuje DISABLE/REBUILD indexů, tj. index-parking). Funkcionalita musí být
navržena tak, aby to splnila i tak.

RF_LOG2 běží přes `arch.usp_RunTimestampProcess` (strategie TIMESTAMP): kandidáti se vyberou **jednou**
do `#Candidates` (klíč = `ROWID`), pak se po dávkách (`BatchRowCount` 50000 × `MaxBatchesPerRun`) maže přes
`DELETE t … OUTPUT deleted.* INTO <archiv>` joinem na `#Batch` přes `ROWID` (clustered PK). Invariant
Mode=1: `Divergence=0` (archivováno == smazáno), atomicky.

## Dvě úzká hrdla a jejich řešení

### 1) Výběr kandidátů — musí být O(@MaxRows), ne O(velikost tabulky)
Naivně se cutoff vyhodnocoval per-row přes `CAST(DATE_TIME AS datetime2) AT TIME ZONE … AT TIME ZONE …`
(timezone-correct, ale **drahé** — ~27 µs/řádek) a řadilo se přes `ORDER BY DocCreatedAt` (výpočet → SORT
celého eligible setu). Na 10M to dělalo **~5 min CPU-bound** (paralelní `CXSYNC_PORT`), na 100M by to bylo
neúnosné.

**Řešení — „cheap mode" (no per-row AT TIME ZONE):**
- `ObjectSpec.CandidateSelectExpr` = levný **lokální** výraz pro projekci času (`CONVERT(datetime2(0), t.DATE_TIME)`),
- `CandidateWhereSql` = autoritativní cutoff: převede `@CutoffUtc` na **lokální čas zdroje JEDNOU** (skalárně)
  a porovná **raw indexovaný sloupec** jako řetězec — `[DATE_TIME] < CONVERT(char(8), (@CutoffUtc AT TIME ZONE N'UTC') AT TIME ZONE N'Central European Standard Time', 112)`,
- `CandidateOrderSql` = `[DATE_TIME]` (raw indexovaný sloupec).

Protože `DATE_TIME` je `nvarchar` ve formátu `yyyymmdd hh:mm:ss.ff` (**lexikálně = chronologicky**), je tohle
porovnání **sargable** na **existujícím** indexu `AOI_RF_LOG2_DATE_TIME` (DATE_TIME leading) — **žádný nový
index netřeba**. Plán: `Index SEEK … ORDERED FORWARD` + `Top(@MaxRows)`, **bez Sortu, bez per-row AT TIME ZONE,
bez full scanu**. Čte jen nejstarších @MaxRows a zastaví → **nezávislé na velikosti tabulky** (10M i 100M čte
stejných 5M). Přesný `AT TIME ZONE` cutoff se per-row **přeskočí**; bezpečné, protože string-bound je
konzervativní (dříve, den-granularita → nikdy nepřearchivuje) a **retention floor (50210)** stále hlídá
absolutní `@CutoffUtc`. Naměřeno: candidate-fáze **~3,4 s / 1 M** vs ~57 s/1M s AT TIME ZONE (**~17×**).
`TimestampExpr` zůstává AT TIME ZONE výraz → **timezone gate (50200) stále prochází**.

### 2) Mazání — ~per-row floor (13 NC indexů + cross-DB OUTPUT, plně logováno)
DELETE udržuje clustered PK + **každý** NC index (RF_LOG2 jich má ~13) + `OUTPUT … INTO <archiv>` (plně
logovaný cross-DB zápis). To je nevyhnutelná per-row práce — **~3 300 ř/s** na tomto HW. Klíčové: **je
nezávislá na velikosti tabulky** (per-row údržba, hloubka B-stromu roste jen logaritmicky), takže 5M na 100M
trvá ~stejně jako na 10M.

## Naměřeno (RADIM-STACHAL\RSTSQL2022, Edge.RF_LOG2, 10,2 M řádků)

| Běh | Konfigurace | Doba | Průtok | Pozn. |
|---|---|---|---|---|
| 5 000 000 | per-row AT TIME ZONE cutoff (regrese) | ~87,6 min | ~950 ř/s | drahý AT TIME ZONE na každý řádek |
| 5 000 000 | **cheap mode (lokální string seek, NONE audit)** | **26,6 min (1 598 s)** | **3 128 ř/s** (ustálené mazání ~3 300) | candidate ~2 min + mazání ~25 min; **≤ 30 min ✓** |

Mazání běží ustáleně ~3 300 ř/s; candidate-fáze je ~2 min (z toho seek+TOP ~sekundy, zbytek dedup-window +
build unikátního indexu `#Candidates` nad 5M — další případná páka). **Na 100M se čísla nemění** (candidate
seek je bounded, mazání per-row).

## Konfigurace „cheap mode" pro RF_LOG2 (per deployment)
```sql
-- 1) cheap lokální projekce (sdílený ObjectSpec)
UPDATE os SET CandidateSelectExpr = N'CONVERT(datetime2(0), t.DATE_TIME)'
FROM arch.ObjectSpec os JOIN arch.Process p ON p.ProcessId=os.ProcessId
WHERE p.ProcessCode=N'RF_LOG2' AND os.SourceTable=N'RF_LOG2';
-- 2) sargable lokální cutoff + řazení dle indexovaného sloupce (per SourceDb; uprav TZ dle zdroje)
UPDATE pd SET
  CandidateWhereSql = N'[DATE_TIME] < CONVERT(char(8), (@CutoffUtc AT TIME ZONE N''UTC'') AT TIME ZONE N''Central European Standard Time'', 112)',
  CandidateOrderSql = N'[DATE_TIME]',
  BatchRowCount = 50000, MaxBatchesPerRun = 100, AuditLevel = N'NONE'   -- 100×50000 = 5 000 000 / běh
FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId
WHERE p.ProcessCode=N'RF_LOG2' AND pd.SourceDb=N'<SourceDb>';
```
Předpoklad: zdroj má **existující** index s časovým sloupcem jako leading (zde `AOI_RF_LOG2_DATE_TIME`) — to
NEvytváříme, pouze využíváme. Formát `DATE_TIME` musí být lexikálně chronologický (ISO-like); jinak uprav
`CandidateWhereSql` na odpovídající string-formát.

> ### Dvě varianty cheap-mode — pozor na očekávaný výkon
> Číslo **5M / 26,6 min** výše platí pro **sargable (raw-string) variantu** nahoře: `CandidateWhereSql`
> porovnává **surový indexovaný sloupec** s řetězcovým cutoffem → `Index SEEK`, candidate-fáze ~3,4 s/1M.
> Vyžaduje **lexikálně-ISO** sloupec + existující index.
>
> Konzolové tlačítko **„Apply fix"** (a proc `arch.usp_Api_ApplyConfigFix`, ActionKey `ENABLE_CHEAP_MODE`)
> odvozuje **formát-bezpečnou, ale NE-sargable** variantu: vezme lokální jádro `TimestampExpr` (např.
> `CAST(t.DATE_TIME AS datetime2)`, resp. defenzivní `COALESCE(TRY_CONVERT, TRY_PARSE …)`) a porovná ho jako
> **datetime** s cutoffem převedeným do lokálního času (`(<localCore>) < CONVERT(datetime2(0), @CutoffUtc AT TIME
> ZONE N'UTC' AT TIME ZONE N'<zóna>')`). Odstraní tím per-row `AT TIME ZONE` (hlavní cena), ale **obalený sloupec
> = žádný index SEEK** → candidate-fáze je dražší než u sargable varianty.
>
> **Naměřeno na dev instanci (2026-06/07, cheap-mode přes Apply, RF_LOG2/Edge):** studený plný běh
> **Mode=1 + ROW audit** ≈ **5,8 min/1M** (2 861 ř/s, Div=0, per-dokumentová stopa); **NONE/BATCH audit**
> ≈ **5,0 min/1M** → **5M ≈ 25–30 min**. Izolovaná cena per-dokumentového (ROW) auditu = **+59 s/1M (+33 %)**.
> Cíl 5M/30 min tedy drží i s Apply-variantou; **maximální** výkon (index SEEK, ~3,4 s/1M candidate) dá jen
> ruční **sargable** konfigurace na ISO sloupci výše. Doporučení: velkoobjem = cheap-mode (Apply nebo sargable)
> + **BATCH** audit; **ROW** jen když je nutná forenzní per-dokumentová stopa (+~5 min/5M).

## Páky (seřazeno podle dopadu, za daných constraintů)
1. **Cheap-mode candidate selection** (výše) — odstraní per-row AT TIME ZONE; candidate ~17×, bounded, 100M-scalable.
2. **AuditLevel = NONE** pro velkoobjemové logy (ROW = +1 plně logovaný řádek/dokument; ~+11 % na 5M).
3. **`MaxBatchesPerRun × BatchRowCount`** nastavit na cílový objem/běh (5M = 100×50000).
4. **Maintenance window** + sledovat `WRITELOG`/`PAGEIOLATCH`/`LCK_*` (66h incident = víkendová kontence).

## Co je vyloučeno daným zadáním / zamítnuto
- **Index-parking (`052`)** — DISABLE/REBUILD NC indexů; REBUILD na 100M tabulce dlouho **blokuje** → porušuje
  „tabulku nelze dlouho blokovat". (Zůstává jen pro výjimečné maintenance-window backlog drainy.)
- **Nové indexy na zdroji** — zakázáno zadáním; cheap mode proto cílí na **existující** index.
- **Per-row AT TIME ZONE cutoff** — hlavní příčina regrese; nahrazeno převodem cutoffu na lokální čas jednou.
- **Minimal/BULK_LOGGED** — `OUTPUT … INTO` je vždy plně logované; archiv je ve FULL recovery (durabilita).
- **Paralelní streamy** — applock serializuje proces/zdroj.

## Pro EXTRÉMNÍ objem / trvale vysoký přírůstek: partition switch
Pokud má být headroom velký i do budoucna, je cílová architektura **partition switch**: partitionovat
`RF_LOG2` podle data a archivovat celé staré partition přes `ALTER TABLE … SWITCH` = **metadata-only,
prakticky okamžité, bez per-row mazání i bez blokování**. Vyžaduje partitionovaný zdroj + zarovnaný archiv
(zásah do schématu, ne nový index). `SelectionStrategy` má rezervovanou hodnotu `PARTITION`.

## INTEGRACE_DNLOAD a další TIMESTAMP procesy ve velkém měřítku
RF_LOG2 cheap-mode se opírá o **existující** index na časovém sloupci (`AOI_RF_LOG2_DATE_TIME`).
`INTEGRACE_DNLOAD` (tabulka `DNLOAD_ARCHIVE`) ho **nemá** — bez indexu je výběr kandidátů `O(velikost tabulky)`
(scan). Při dosud testovaných objemech (300k / ~90 s, tabulka ~1,8 M) je to v pohodě; teprve při **desítkách
milionů** by byl scan drahý. Navíc má `DNLOAD_ARCHIVE` **smíšený časový zdroj** —
`TimestampExpr = COALESCE(date_archived, parse(TIMESTMP))` — takže žádný **jediný** indexovaný sloupec
nepokryje obě cesty. Možnosti (seřazeno podle preference za zákazníkova zadání „bez nových indexů"):

1. **Akceptovat scan** (default). Pokud `DNLOAD_ARCHIVE` zůstane v řádu jednotek milionů, klasický výběr stačí —
   žádná změna, žádný index. Toto je doporučený výchozí stav.
2. **Výjimka ze zákazu indexů jen pro DNLOAD** + cheap-mode. Skript
   [`deploy/v2/18_recommended_timestamp_source_indexes.sql`](../deploy/v2/18_recommended_timestamp_source_indexes.sql)
   je připraven a vytvoří `IX_KAM_DNLOAD_ARCHIVE_date_archived_ROWID (date_archived, ROWID) WHERE date_archived IS NOT NULL`
   (preview-only; `@ApplyChanges=1` pro vytvoření). **Precondition:** cheap-mode přes `date_archived` je korektní
   jen pokud jsou eligible řádky **spolehlivě** datovány `date_archived`. Řádky, co mají `date_archived NULL` a
   spoléhají na parse `TIMESTMP`, by sargable bound **tiše podselektoval** (nikdy špatná data — jen by je
   nezpracoval; viz formátový caveat výše). Pro takový zdroj buď zůstaň u klasiky, nebo postav perzistovaný
   computed-column index jako u `UPLOADARCHIVE` (skript 18_ to umí: `KAM_TIMESTMP_DT`). Po vytvoření indexu se
   cheap-mode zapne stejně jako u RF_LOG2:
   ```sql
   -- ObjectSpec (sdílený): levná lokální projekce date_archived
   UPDATE os SET CandidateSelectExpr = N'CONVERT(datetime2(0), t.date_archived)'
   FROM arch.ObjectSpec os JOIN arch.Process p ON p.ProcessId=os.ProcessId
   WHERE p.ProcessCode=N'INTEGRACE_DNLOAD' AND os.SourceTable=N'DNLOAD_ARCHIVE';
   -- ProcessDatabase (per zdroj): sargable cutoff na indexovaný datetime sloupec + řazení dle něj
   UPDATE pd SET
     CandidateWhereSql = N'[date_archived] < (@CutoffUtc AT TIME ZONE N''UTC'') AT TIME ZONE N''Central European Standard Time''',
     CandidateOrderSql = N'[date_archived]'
   FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId
   WHERE p.ProcessCode=N'INTEGRACE_DNLOAD' AND pd.SourceDb=N'<SourceDb>';
   ```
   Validace (`usp_ValidateConfiguration`) po nastavení vypíše **INFO** (cheap-mode aktivní → ověř formát/úplnost
   `date_archived`); pokud nastavíš jen `CandidateSelectExpr` bez `CandidateWhereSql`, vypíše **WARN**.
3. **Partition switch** (viz výše) — pro trvale extrémní objem.

## Audit ON + napříč procesy (živě, 2026-06-12)
Sweep všech procesů/DB s **AuditLevel=ROW** (RetentionDays=1 → max eligible). Všechny **OK, Divergence=0,
archiv == smazáno (2 408 861 řádků), 0 bad runs**, 2,4M řádků za **~14 min**. Klíčové sazby s ROW auditem:

| Proces / DB | Řádky | Doba | Průtok | Audit řádků |
|---|---|---|---|---|
| Edge.RF_LOG2 (cheap) | 1 000 000 | 372 s | **2 688 ř/s** | 1 000 000 |
| KMWEBV.RF_LOG2 (cheap) | 806 868 | 272 s | **2 966 ř/s** | 806 868 |
| KMWE_Test.INTEGRACE_DNLOAD | 300 000 | 97 s | 3 092 ř/s | 300 000 |
| KMWEBV.INTEGRACE_DNLOAD | 300 000 | 84 s | 3 571 ř/s | 300 000 |

**ROW audit stojí ~17 % vs NONE** u RF_LOG2 (2 688 vs 3 128 ř/s) → **5M s ROW auditem ≈ 31 min** (mírně přes
30min cíl). Pro garanci **≤30 min použij NONE/BATCH** audit; ROW jen když je nutná per-doc evidence.

**POZOR — cheap-mode je závislý na formátu časového sloupce.** Sargable string-bound (`< CONVERT(char(8),…,112)`)
funguje jen když je sloupec **lexikálně chronologický** (ISO `yyyymmdd…`): Edge a KMWEBV ✓. **KMWE_Test.RF_LOG2
má smíšený formát** (`'20240205…'` i `'Apr 9 2025…'`) → string-bound nesedí → cheap-mode bezpečně **vybral 0**
(nikdy špatná data, jen nezpracoval) → pro takový zdroj nech **classic mode** (`CAST … AT TIME ZONE`, zvládne
oba formáty, jen pomaleji). Cheap-mode tedy konfiguruj **per zdroj** po ověření formátu.

Vedle toho oprava seedu: **INTEGRACE_DNLOAD měl `BatchRowCount=5` (100 ř/běh)** → opraveno na 50000 (jinak
1,8M tabulka prakticky nezpracovatelná). Po opravě 300k/~90 s.

## Časové zóny, locale a DST (T-23)
Cutoff i `TimestampExpr` se opírají o `AT TIME ZONE` a o převod zdrojového času na `datetime2`. Dva háčky:

- **Text-date sloupce jsou locale-citlivé (TICHÉ riziko).** `CONVERT/CAST` textového data jako `'Apr 9 2025 4:09PM'`
  závisí na `SET LANGUAGE`/`DATEFORMAT` session — a runner do dynamického SQL **záměrně nepinuje** `SET LANGUAGE`
  (pinovat na jednu řeč by rozbilo zákazníky s jiným locale). Stejný řetězec se tak může na různých serverech
  rozparsovat na **jiné datum, potichu**. **Doporučení:** zdrojový časový sloupec měj jako **ISO / lexikálně
  chronologický** (`yyyymmdd…`, viz cheap-mode), jako **nativní `datetime`/`datetime2`**, nebo postav **perzistovaný
  computed sloupec** (`18_recommended_timestamp_source_indexes.sql` → `KAM_TIMESTMP_DT` pro `UPLOADARCHIVE`).
  Pro skutečně textový sloupec použij `TRY_CONVERT(datetime2, …, <explicitní styl>)`. KMWE_Test.RF_LOG2 je živá
  ukázka smíšeného formátu (`'20240205…'` i `'Apr 9 2025…'`).
- **Neplatná zóna (HLASITÉ riziko).** Zóna v `AT TIME ZONE` musí existovat v `sys.time_zone_info`; překlep
  (`'Central Europ Standard Time'`) **THROWne za běhu** a naplánovaný běh se zasekne. `usp_ValidateConfiguration`
  nově vypíše **WARN**, když výraz odkazuje zónu mimo `sys.time_zone_info` → odhalí se při validaci, ne ve 3 ráno.
- **DST.** `AT TIME ZONE` je **nedefinované** pro spring-forward chybějící hodinu a **ambiguózní** pro fall-back
  opakovanou hodinu. Pro archivní cutoff je to nepodstatné (hodinová nejednoznačnost 1×/rok vs retence ve dnech) a
  bezpečné (příliš těsný cutoff jen **zpozdí** archivaci, nikdy nesmaže špatně); hlídej jen u sub-hodinové logiky.

## Měřit před/po
elapsed RUNu · `RowsDeleted`/`RowsArchived` (Divergence=0) · skutečný plán candidate-fáze (musí být
**Index Seek … ORDERED FORWARD + Top**, žádný Sort/Scan) · waity (`WRITELOG`, `PAGEIOLATCH_*`, `LCK_*`).
