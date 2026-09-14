# kArchiveManager 2.0 — Uživatelský manuál

Průvodce obsluhy pro **Admin Console**. Obsahuje vše potřebné pro práci s konzolí — sekce, obrazovky,
tabulky, grafy a jejich atributy. Technické detaily aplikace (SQL objekty, API, nasazení) jsou v **Admin
manuálu** (sekce **Configuration** po přihlášení operátora).

## Co kArchiveManager dělá

kArchiveManager automaticky **archivuje stará data** z provozních databází (WMS/ERP — logy, doklady,
integrace) do oddělené **archivní databáze**. Cíl: udržet provozní databáze štíhlé a rychlé a přitom data
**neztratit** — zůstanou bezpečně uložená a dohledatelná v archivu.

Klíčové pravidlo: archivace je vždy **„nejdřív archivuj, pak smaž"** v jedné transakci. Smazáno ze zdroje je
přesně to, co se předtím úspěšně zkopírovalo do archivu (kontrola **Divergence = 0**). Nic se neztratí ani
nesmaže „omylem".

---

# Admin Console

Webové rozhraní pro **sledování** archivace (dostupné běžnému uživateli) a pro **konfiguraci** (vyhrazeno
přihlášeným operátorům). Otevřeš ho v prohlížeči na adrese, kterou sdělí administrátor.

## Sekce v levé liště — k čemu slouží

| Sekce | Princip / k čemu je |
|---|---|
| **Dashboard** | Vstupní souhrn: kolik dat je ve zdroji vs. v archivu, kolik procesů je aktivních, poslední běhy a zdraví systému. Volně ke stažení je zde **User manual**. |
| **Analysis & Estimates** | Grafy objemů dat (zejm. systémové logy RF/L) a **odhad další dávky** — kolik MB a řádků by příští běh zpracoval, podle Source DB v hlavičce (prázdné = všechny DB). |
| **Runs** | Historie běhů archivace a jejich stavy; kliknutím na běh se otevře detail (položky, objekty, doklady, dávky). |
| **Document lookup** | Vyhledání konkrétního dokladu — zda je ještě ve zdroji, nebo už přesunutý v archivu. |
| **Configuration** | Nastavení procesů, mapování, objektů, klíčů, indexů, run profilů; plánování SQL jobů; správa operátorů. **Jen pro přihlášené operátory.** |
| **Validation** | Kontrola správnosti konfigurace (nálezy ERROR/WARN/INFO se doporučeným SQL). |
| **Go-live** | Brána připravenosti instance na ostrý provoz (přehled kontrol). |

## Přihlášení a oprávnění

- **Přehledy a vyhledávání** jsou dostupné bez přihlášení.
- **Úpravy konfigurace** vyžadují přihlášení operátora — tlačítko **Lock / Unlock** vpravo nahoře (pole
  **Operator** + **Password**). Po přihlášení svítí „Editing as … (jméno)".
- Některé operace (např. **restore** dat zpět do produkce) vyžadují **elevovaného** operátora.

## Společné prvky (hlavička, indikátory)

**Filtr v hlavičce** (platí pro všechny sekce):

| Pole | Význam |
|---|---|
| **Process** | Konkrétní proces, nebo „All processes". |
| **Source DB** | Zdrojová (provozní) databáze. **Prázdné („Any source") = všechny zdrojové DB.** |
| **Archive DB** | Cílová archivní databáze (obvykle `kArchiveManagerBackups`). |
| **Include disabled** | Zobrazit i vypnutá mapování/procesy. |
| **Refresh** | Znovu načíst data podle filtru. |

**Stavové indikátory vpravo nahoře:** **API OK / DB OK** (konzole je spojená s databází a vše běží; jiný
stav nahlas administrátorovi) a **Editing as … / Lock** (zda jsi přihlášený s právem editace).

## Dashboard

**Metriky (dlaždice):** **Active processes** (počet aktivních procesů), **Source rows** (řádky ve zdroji),
**Archived rows** (řádky v archivu), **Recent non-OK runs** (počet posledních běhů, které neskončily OK).

Dále **operační signály**, **grafy** (objemy podle dne/tabulky) a tyto tabulky:

- **Process movement** — `Process, Source, Archive, Source rows, Archived, Delta` (rozdíl zdroj−archiv), `Objects`.
- **Prep/run dávky** — `Batch, Process, Status, Candidates, Prepared` (čas přípravy).
- **Recent runs** — `Run item, Process, Source, Status, Docs, Archived, Deleted, Started`.
- **Table counts** — `Process, Source table, Archive table, Source, Archived, Source ok, Archive ok` (existence tabulek).

## Analysis & Estimates

**KPI dlaždice:** RF/L mapped tables, RF/L source rows, RF/L archived rows, RF/L runs.

**Grafy:** přenesené řádky podle dne/source DB/procesu, podle dne/tabulky, kontrolní pohled source vs.
archived, podle cutoffu, a backlog ke smazání. Série grafů mají sloupce `Label` + `Value` (jednoduché),
resp. `Label / Source / Archived` (dvojité).

**Odhady další dávky (MB)** — přepínač **Zobrazit odhady** (výchozí vypnuto), tlačítka **Přepočítat** a
**Export CSV**. Bere Source DB z hlavičky; prázdné = všechny DB. Sloupce:

| Sloupec | Význam |
|---|---|
| **Proces** | Kód procesu. |
| **Source DB** | Zdrojová databáze mapování. |
| **Režim** | `ARCHIVE_DELETE` (archivuj a smaž), `DELETE_ONLY` (jen smaž), `COPY_ONLY` (jen kopíruj). |
| **Limit dávky (řádků)** | Nejvyšší počet řádků, který **jeden běh** zpracuje. Odhad se počítá pro tento limit, ne pro celou tabulku. |
| **Zdroj řádků** | Celkový počet řádků aktuálně ve zdrojových tabulkách procesu. |
| **Payload MB** | Objem dat, který příští dávka **přesune** (limit řádků × průměrná velikost řádku). |
| **Archiv růst MB** | O kolik přibližně naroste **archivní DB** (Payload × režie archivu, ~×1,2; jen ARCHIVE_DELETE). |
| **Log tlak MB** | Odhad zatížení **transakčního logu** během dávky (Payload × ~3). |
| **Plán MB (s rezervou)** | Plánovací číslo: (Archiv růst + Log tlak) × bezpečnostní rezerva (~×1,3). Podle něj posuď, zda je dost místa a log prostoru **před** spuštěním. |

## Runs

Seznam běhů — sloupce: `Run, Item, Process, Source, Archive, Mode, Status, Started, Finished, Duration,
Batches, Docs, Rows, Error`. Kliknutím na řádek se otevře **detail** s panely:

- **Run items** — `Item, Process, Mode, Status, Batches, Docs, Deleted, Archived, Error`.
- **Work batches** — `Batch, Process, Status, Prepared, Started, Completed, Last key`.
- **Object movement** — `Object item, Item, Process, Schema, Table, Deleted, Archived, Logged`.
- **Document audit** — `Audit, Item, Process, Label, Key, Archived, Deleted at`.

**Stavy běhů:** **OK** (proběhl v pořádku), **FAILED** (selhal/přerušen; data zůstala konzistentní, opakuje
se příště — opakované FAILED nahlas administrátorovi), **STOPPED** (zastaven operátorem; lze pokračovat),
**DRYRUN** (jen náhled, nic se nemazalo/nearchivovalo).

**Akce:** **Stop** (kooperativní zastavení běhu), **Restore** (vrácení archivovaných řádků zpět do zdroje —
vyžaduje elevovaného operátora; nejdřív náhled, pak potvrzení).

## Document lookup

Zadej **klíč dokladu** (např. číslo dokladu / ROWID) a zjistíš, kde doklad je. **Souhrn:** `Result, Key,
Processes, Archived, Run item, Source`. **Detaily:** `Audit, Process, Label, Key, Archived, Deleted at,
Status`.

## Configuration (jen pro přihlášené operátory)

Konfigurace má panel detailu procesu + tabulky jednotlivých entit. Každá změna vyžaduje **důvod změny
(min. 6 znaků)** a je auditována.

- **Process** — `Process, Description, Enabled, Strategy, Retention, Audit, Objects, Modified`.
- **Database mappings** — `Process, Source, Archive, Enabled, Run order, Retention, Batch docs, Batch rows`.
- **Effective objects** — `Process, Source, Table, Order, Enabled, Archive schema, Archive table`.
- **Process keys** — `Process, Ordinal, Name, Expression, SQL type, Required`.
- **Index requirements** — `Process, Type, Object, Key columns, Mandatory, Mappings`.
- **Run profiles** — `Profile, Description, Enabled, Scheduled, Order, Process filter, Source filter, Dry run`.
- **Change history** — `Change set, Status, User, Requested, Items, Fields, Validation`.

**Plánování — SQL Agent joby** (panel „Plánování"): joby **PREP** (příprava kandidátů přes den) a **RUN**
(zpracování v okně). U každého: **Povolit/Zakázat**, **Četnost** (Denně / Každou hodinu), **Čas** (HH:MM),
**Rozvrh aktivní**.

**Operátoři konzole** (panel „Operátoři konzole"): `Uživatel`, `Jméno`, `Heslo` (ukládá se jen bezpečný
otisk, nikdy čitelně; při úpravě prázdné = beze změny), `Povolen`, `Elevovaný (restore)`.

## Validation

Spustí kontroly konfigurace a indexů. Sloupce nálezů: `Code, Severity` (ERROR/WARN/INFO), `Process, Source,
Archive, Object, Finding, Suggested SQL` (návrh opravy k zkopírování).

## Go-live

Přehled připravenosti na ostrý provoz: `Area, Check, Status, Detail, Recommendation`. Souhrnný stav je
**READY / READY WITH WARNINGS / NOT READY**.

---

## Konfigurace — význam hodnot, dopad a varování

Hodnoty, které se v editorech Configuration reálně nastavují. ⚠️ = **kritický parametr** (ovlivní, co se
nevratně smaže, nebo vypne pojistku) — měň jen s rozmyslem.

### Editor procesu (výchozí hodnoty procesu)

| Pole | Význam a dopad |
|---|---|
| **Description** | Popis procesu (informativní). |
| **Enabled** | Zda proces archivuje. ⚠️ Vypnutí → data ve zdroji přestanou ubývat (rostou). |
| **Mode** | `Archive + delete` = archivuj a smaž · `Delete only` ⚠️ jen smaž **bez archivace** (nelze obnovit) · `Copy only` jen kopíruj do archivu. |
| **Retention days** | Stáří dat k archivaci (cutoff = dnes − N dní). ⚠️ **Snížení** archivuje/maže starší a **více** dat hned (nevratné). Spodní mez hlídá pojistka. |
| **Cutoff safety lag minutes** | Bezpečnostní odstup cutoffu (minuty) — nezpracuje data těsně na hraně. |
| **Cutoff mode** | `Relative retention` (klouzavý, dnes − Retention) nebo `Fixed cutoff date` (pevné datum). |
| **Cutoff date** | Pevné datum (u Fixed). ⚠️ Posun na pozdější datum → archivuje více. |
| **Batch doc count** | Počet **dokladů** na dávku (ANCHOR). |
| **Batch row count** | Počet **řádků** na dávku (TIMESTAMP). |
| **Max batches per run** | Kolik dávek max za běh. **Limit dávky = (Batch row/doc count) × Max batches per run.** Vyšší = víc zpracuje, ale delší běh a větší zátěž logu. |
| **Delay ms between batches** | Pauza mezi dávkami (ms) — šetří I/O a nechá prostor provozu. |
| **Document key label** | Co se zapisuje do auditu jako klíč dokladu (business klíč vs. ROWID). |
| **Audit level** | `NONE` ⚠️ bez auditní stopy · `BATCH/OBJECT` agregované počty · `ROW` stopa na každý doklad (nejvyšší dohledatelnost, ~+10 % režie). |
| **Allow delete without archive** | ⚠️ Povolí v režimu Delete-only mazat i řádky **bez archivní kopie** — odstraňuje pojistku. |

### Editor mapování (override pro konkrétní zdrojovou DB)

Stejná pole jako u procesu, ale jako **override** (prázdné = dědí z procesu) + **Run order** (pořadí
mapování) a **cheap-mode** (výkon):

| Pole | Význam a dopad |
|---|---|
| **Audit level override** | jako výše; „Use process default" dědí z procesu. ⚠️ `NONE` = mazání bez per-row stopy. |
| **Candidate WHERE cutoff (cheap-mode)** | ⚡ Výkonový knob pro velkoobjemové TIMESTAMP zdroje (rychlý index-ordered výběr bez převodu času na každém řádku). ⚠️ Funguje jen na **ISO-chronologickém** (yyyymmdd…) sloupci — u smíšených formátů **tiše vybere méně** (data se nezarchivují, bez chyby). Při pochybnostech nech prázdné. |
| **Candidate ORDER BY (cheap-mode)** | surový časový sloupec pro řazení (index-ordered seek). Prázdné = řadí dle počítaného času. |

### Editor objektu (tabulky)

| Pole | Význam a dopad |
|---|---|
| **Source schema / table** | Zdrojová tabulka. |
| **Delete order** | ⚠️ Pořadí mazání tabulek v rámci dokladu — musí respektovat FK (děti před rodiči), jinak chyba/nekonzistence. |
| **Delete mode** | jako Mode. |
| **Timestamp expression (TIMESTAMP)** | SQL vracející UTC čas řádku. ⚠️ Musí správně převádět do UTC, jinak špatný výběr / TZ pojistka. |
| **Join to anchor predicate (ANCHOR)** | JOIN na klíče dokladu (k.Key1..Key8). |
| **Additional WHERE filter** | Filtr na každý DELETE (vyloučí řádky, co se nikdy nemají archivovat). |
| **Candidate SELECT expression (cheap-mode)** | ⚡ Levná projekce času; aktivní jen s Candidate WHERE cutoff. Prázdné = klasické. |
| **Archive schema / table** | Cíl v archivu (`{SourceDb}` = zástupný symbol pro zdrojovou DB). |
| **Require archive for delete** | ⚠️ Vypnutí = smaže i bez archivní kopie. |
| **Natural key label** | Popisek přirozeného klíče (audit). |

### Editor klíče dokladu / indexu / běhového profilu

- **Klíč dokladu:** `Key ordinal` (1..8), `Key name`, `Source expression SQL` (výraz hodnoty, např. `t.ROWID`), `SQL type` (⚠️ musí odpovídat typu ve zdroji), `Required`.
- **Index requirement:** `Requirement type` (Selection/Join/Delete/Order/Partition), `Source schema/table`, `Key columns CSV`, `Include columns CSV`, `Filter SQL`, `Mandatory` (Validation hlásí chybějící), `Notes`.
- **Run profile:** `Enabled`, `Scheduled`, `Run order`, `Process/Source DB/Archive DB filter`, ⚠️ `Run window minutes` (po vypršení okna se běh ukončí — krátké okno nedokončí velký objem), `Max candidates`, `Paused cooldown seconds`, `Dry run` (náhled, nic nemaže).

## Best practices — práce s Admin Console

- Před uložením zkontroluj hlášku **Concurrency check** (neukládej přes cizí změnu) a vyplň smysluplný
  **Change reason** (povinný, ≥ 6 znaků — jde do auditu).
- Používej **Review changes** (náhled změn) a **Show effective plan** (výsledný plán bez spuštění SQL).
- **Před velkým nebo novým během** zapni **Analysis & Estimates** a podívej se na **Plán MB (s rezervou)** —
  je dost místa a log prostoru?
- Nové nastavení nejdřív vyzkoušej přes **Dry run** profil (nic nesmaže ani nearchivuje).
- **Nevypínej pojistky** (Require archive for delete, Allow delete without archive, Audit = NONE), pokud
  opravdu nevíš proč.
- Rozvrhy jobů nastav **mimo špičku** (noční okno); sleduj **Validation** (ERROR oprav podle Suggested SQL)
  a **Recent non-OK runs**.
- Snížení **Retention days** nebo posun **Cutoff** archivuje/maže **více a nevratně** — rozmysli dopad.
- **Restore** prováděj jen jako **elevovaný** operátor a vždy nejdřív přes náhled.

## Bezpečnost a dohledatelnost dat

- Archivní databáze je **„systém záznamu"** — chráněná (běžný provoz nemůže mazat), pravidelně zálohovaná,
  ve FULL recovery režimu.
- Smazání ze zdroje proběhne **až po** úspěšné archivaci. Auditní stopa (kdo/kdy/co) je neměnná.

## Kdy kontaktovat administrátora

Opakované **FAILED** běhy, jiný stav než „API OK / DB OK", chybějící očekávaná data, nebo potřeba změnit
konfiguraci (retence, procesy, databáze, rozvrhy, operátoři).

## Podrobná dokumentace

Kompletní **Admin manuál** (konfigurace, deploy, audit, výkon, bezpečnost, SQL objekty, API) najdeš ke
stažení v sekci **Configuration** po přihlášení operátora.
