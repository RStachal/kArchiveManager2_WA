# kArchiveManager 2.0 — podklad pro hodinovou prezentaci

Scénář toho, **co říkat a v jakém pořadí**. Technické „jak to naklikat" je vedle
v [`PRESENTATION.md`](PRESENTATION.md); tenhle dokument je řečnická osnova.

Napsáno pro prezentujícího, ne pro zákazníka — obsahuje i věci, které se nahlas
neříkají.

---

## Než vejdou do místnosti

**Server se vypne přesně 60 minut po startu.** Vypršela zkušební licence Windows
Serveru a `wlms.exe` vynucuje hodinové vypínání; prodloužení jsou vyčerpaná.
Hodinová prezentace se tedy do jednoho nastartování vejde jen tak tak.

1. **Restartujte server těsně před začátkem.** Tím máte celých 60 minut, ne zbytek
   po někom jiném.
2. Po startu jednou otevřete `http://localhost:8089`, ať se app pool nahodí mimo
   pohled publika (startuje se na první požadavek).
3. Zkontrolujte, že stojíte na výchozím bodu — archiv musí být prázdný:

```sql
SELECT Runs=(SELECT COUNT(*) FROM arch.Run),
       Keys=(SELECT COUNT(*) FROM arch.WorkBatchKey),
       ArchiveRows=(SELECT ISNULL(SUM(p.rows),0)
                    FROM kArchiveManagerBackups.sys.tables t
                    JOIN kArchiveManagerBackups.sys.partitions p
                      ON p.object_id=t.object_id AND p.index_id IN (0,1));
-- musí být 0 / 0 / 0
```

Když nejsou nuly, obnovte čtyři zálohy `*_PresentationStart.bak` — postup je
v `PRESENTATION.md`. Počítejte s tím, že u ADV může zůstat `SINGLE_USER`; ta past
je tam popsaná taky.

---

## Časový plán

| min | blok | cíl |
|---:|---|---|
| 0–5 | Proč vůbec archivovat | jedna věta, kterou si mají zapamatovat |
| 5–15 | Principy | dokument, ne tabulka. Dvě strategie. Retence a brána |
| 15–32 | **Bezpečnostní mechanismy** | těžiště — proč tomu můžou věřit na produkci |
| 32–50 | Živé demo | PREP → klíče, RUN → archiv, ověření |
| 50–55 | Co dělá operátor | jen konzole, žádné SSMS |
| 55–60 | Co potřebujeme od vás | rozhodnutí, ne úkoly |

Demo samo trvá **necelé 4 minuty**. Zbytek je vyprávění, takže když se zdržíte,
krátí se povídání, ne demo.

---

## Blok 1 (0–5 min) — Proč

WMS databáze roste navždy. Objednávka z roku 2019 se nikdy nesmaže, protože
nikdo si netroufne. Zálohy se prodlužují, reindexace trvá, disk roste.

**Jedna věta, kterou mají odejít:**

> Nic se nesmaže, co nebylo předtím zkopírováno. A nesáhne se na nic, co není
> v konfiguraci pojmenované.

Všechno ostatní je detail téhle věty.

Rozdíl proti mazacímu skriptu: archiv je **systém záznamu**. Řádek nezmizí,
přestěhuje se. Zůstává dotazovatelný, zálohovaný, obnovitelný.

---

## Blok 2 (5–15 min) — Principy

### Jednotkou je dokument, ne tabulka

Nearchivuje se „tabulka t_order". Archivuje se **objednávka** — hlavička a
všechny její řádky, komentáře, obaly, stavy. Buď odejde celý dokument, nebo nic.

Na téhle instanci je nakonfigurováno **šest dokumentových sad** nad 23 tabulkami:

| sada | kotva | klíč | brána |
|---|---|---|---|
| `AAD_ORDER_ARCH` | `t_order` | order_number + wh_id | status S/D, není zamčená, není konsolidovaná |
| `AAD_PICKDETAIL_ARCH` | `t_pick_detail` | pick_id | status = SHIPPED |
| `AAD_PO_ARCH` | `t_po_master` | po_number + wh_id | status = C a closed_date vyplněné |
| `AAD_TRANLOG_ARCH` | `t_tran_log` | tran_log_id | datum po epoše |
| `AAD_WORKQ_ARCH` | — (TIMESTAMP) | work_q_id | work_status C/P |
| `ADV_LOGMSG_ARCH` | `t_log_message` | složený | retence 23 dní |

### Dvě strategie, a proč na tom záleží

**ANCHOR** — kotva se maže **jako poslední**. Nejdřív děti v pořadí `DeleteOrder`,
hlavička až nakonec. To je důvod, proč je přerušení bezpečné: nejhorší stav je
dokument, jehož děti už jsou v archivu a hlavička ještě ve zdroji. Doběhne se a
je hotovo.

**TIMESTAMP** — řídící tabulka první, ostatní ji následují. Tak jede fronta práce,
která nemá dokumentovou hlavičku.

### Retence není parametr, je to rozhodnutí

`RetentionDays` 90 na AAD sadách, **23 na ADV** — a to číslo je zajímavé: ADV si
svůj log maže samo po 30 dnech, takže 90denní cutoff by vybíral řádky, které WMS
už dávno smazal, a proces by navždy hlásil úspěch s nulou. Nástroj to pozná a
retenci **sám sníží** a napíše aritmetiku.

K tomu `CutoffSafetyLagMinutes` = 1440, tedy den navíc nad retenci. Cutoff se
počítá v UTC s převodem přes `AT TIME ZONE`, ne lokálním časem — jinak by se
selekce na přelomu letního času posunula.

---

## Blok 3 (15–32 min) — Bezpečnostní mechanismy

**Tohle je jádro.** Zákazník se ptá na jednu věc: *co když to smaže něco, co
nemělo?* Odpovědí není ujištění, ale vrstvy.

### 1. Archivace a mazání jsou jeden příkaz

Řádek se nekopíruje a pak nemaže. Maže se příkazem, jehož `OUTPUT` klauzule
zapisuje mazané řádky rovnou do archivu:

```sql
DELETE t OUTPUT deleted.* INTO <archiv> FROM <zdroj> t JOIN #Keys k ON ...
```

Jedna transakce. Nemůže nastat stav „smazáno, nezazálohováno" — ne proto, že by
se to hlídalo, ale protože to jinak neumí.

Pojistka nad tím: **všech 24 objektů má `RequireArchiveForDelete = 1`** a všech
šest procesů `AllowDeleteWithoutArchive = 0`.

### 2. Kontrola divergence

Každý běh počítá zvlášť archivované a smazané řádky. Rozdíl musí být nula.
Na tomhle prostředí naměřeno: **76 351 archivováno = 76 351 smazáno, divergence 0**.
Při větším testu 2 986 057 = 2 986 057, také nula.

### 3. Brána: co přežít musí

Každá sada má podmínku, která drží zpátky nedokončené dokumenty. To se
**dokazuje, ne tvrdí** — a je to nejlepší okamžik prezentace:

> Když doběhla sada pro picky, zůstal ve zdrojové tabulce **přesně jeden řádek**.
> A byl to ten jediný, který neměl status SHIPPED.

Při testu na 75 000 řádcích zůstalo přesně 15 000 — tedy přesně tolik, kolik jich
bránu neprošlo. Ne přibližně.

### 4. Nikdy nesaháme do WMS databáze

Žádný index, sloupec, trigger ani tabulka. Jen `SELECT` a `DELETE` na
pojmenovaných tabulkách.

**Tohle řekněte příběhem, ne pravidlem.** Dřívější verze si v AAD vytvořila čtyři
indexy, dva filtrované — a **zastavila zápis do WMS**. SQL Server odmítne jakékoliv
DML nad tabulkou s filtrovaným indexem, pokud spojení nemá `QUOTED_IDENTIFIER ON`,
a v AAD je 240 z 1 147 modulů zkompilováno s OFF, včetně osmi aktivních triggerů.
Žádnou objednávku nešlo založit. Od té doby se požadavky na indexy **předávají DBA
zákazníka** a nástroj je nevytváří, ani kdyby chtěl — ten skript nemá přepínač.

### 5. Runner nesmí být sysadmin

Účet, pod kterým archivace běží, má **jen SELECT a DELETE** na mapovaných
tabulkách, nic víc. Žádné DDL, žádná práva mimo konfiguraci.

A není to jen doporučení: **job se odmítne spustit**, pokud je vlastněn
sysadminem — krok 1 zahlásí `Error 51001` a nic se nesmaže. Tuhle bránu jsme
tady vyzkoušeli tak, že selhala; opravila se změnou vlastníka jobu, ne vypnutím
kontroly.

### 6. Konfigurace nesmí obsahovat kód

Pole jako spojovací podmínka nebo výraz cutoffu jsou vyhodnocována jako výrazy,
ale **nesmí obsahovat poddotaz, příkaz ani volání procedury** — `usp_AssertSafeSqlExpression`
takový zápis odmítne chybou `50400`. Nejde tedy do konfigurace propašovat
`DELETE` ani `EXEC`.

Podobně cutoff **musí** obsahovat `AT TIME ZONE`, jinak `50200`. Časová zóna není
volitelná.

### 7. Dopad na produkci je omezený předem

- `MaxRowsPerTransaction` ≤ **4000** — nad tím SQL Server eskaluje zámek na celou
  tabulku. Tady 2000 (u fronty 4000).
- **Běhové okno 55 minut** — běh se sám ukončí, ať je hotovo nebo ne.
- **Aplikační zámek** (`UseAppLock = 1`) — dva běhy si nevlezou do cesty.
- Dávkování po dokumentech, mezi dávkami prodleva.

Nástroj je navržen jako **přerušitelný, ne rychlý**. To je vlastnost, ne kompromis.

### 8. Přerušení je normální stav

Když běh zemře uprostřed — výpadek, restart, ruční zastavení:

- rozpracovaná dávka se **uloží i s nezpracovanými klíči** a příště pokračuje
- běh se označí `FAILED`, **nikdy „úspěšný"**

Ukázka, kterou stojí za to přečíst nahlas — z reálného zásahu na tomhle serveru:

> `archived=44289 deleted=44289 ... marked FAILED for safe re-processing —
> success is never inferred.`

Čísla seděla na kus. Systém přesto odmítl prohlásit běh za úspěšný. To je
konzervativnost, kterou chcete.

Job `RECOVER STALE RUNS` tyhle situace uklízí sám každých 15 minut.

### 9. Audit

| co | kde | vlastnost |
|---|---|---|
| každý dokument | `arch.RunDocAudit` | **neměnný** — `DENY UPDATE, DELETE` |
| každá změna konfigurace | `arch.ConfigChangeSet` / `Item` / `Field` | kdo, kdy, proč, co přesně |
| přihlášení do konzole | `arch.ConsoleLoginAudit` | |
| každý běh a dávka | `arch.Run`, `RunItem`, `WorkBatch` | |

Buďte upřímní k jedné věci: **per-dokumentový audit je zapnutý u dvou sad ze šesti**
(`AuditLevel = ROW` na objednávkách a nákupkách). U čtyř logových sad je vypnutý,
protože stopa na každý řádek u desítek milionů řádků stojí víc, než přináší.
Je to nastavení, ne opomenutí, a lze ho kdykoliv zapnout.

### 10. Pojistky, které lze zapnout

- **Legal hold** — dokument pod držením se nesmaže, a to i když bylo držení
  přidáno *až po* přípravě dávky.
- **Copy-only režim** — kopíruje do archivu a ve zdroji nemaže vůbec.
- **Retenční podlaha** — odmítne konfiguraci s kratší retencí, než je povolené
  minimum. **Na téhle instanci je 0, tedy vypnutá** — zmiňte to jako položku
  k nastavení před ostrým provozem, ne jako hotovou věc:

```sql
EXEC arch.usp_Api_SetRetentionFloor @MinRetentionDays = 365, @RequestedBy = 'dba';
```

- **Dry run** — profil `ALL_DRYRUN` vybere kandidáty a nahlásí, co by odešlo,
  bez jediného zápisu.

### 11. Obnova

`arch.usp_RestoreFromArchive` umí vrátit dokument zpět. Je to jediná operace,
která **zapisuje do produkčního zdroje**, takže právo k ní je **záměrně odepřeno**
— náhled funguje, skutečná obnova vyžaduje vědomé rozhodnutí DBA. To není
nedodělek, to je zámek.

---

## Blok 4 (32–50 min) — Živé demo

### Konzole: `http://localhost:8089`

**Dashboard — horní dlaždice**

| dlaždice | co říct |
|---|---|
| Active processes | 6 nakonfigurovaných sad |
| Source rows | kolik je ve WMS **v nakonfigurovaných tabulkách** |
| Archived rows | kolik už je v archivu — na startu **0** |
| Recent non-OK runs | musí být 0 |

**Operational signals** — šest signálů. Ukažte `Run health` (OK), `Process
coverage` (6/6) a `Config validation`. Ten hlásí **1 warning** a je dobré ho
vysvětlit dřív, než se někdo zeptá: sada ADV má šest klíčů, zatímco primární klíč
tabulky klíčů je dvousloupcový. Je to neškodné, protože **Key1 není sloupec** —
je to zřetězení všech pěti identifikujících sloupců, takže sám o sobě unikátní.

`Data balance` ukazuje rozdíl zdroj − archiv. **Záporné číslo je normální stav**,
ne chyba.

**Graf „Source vs Archived by table"**

- **tyrkysová = zdroj** (co je pořád ve WMS)
- **jantarová = archiv** (co už je zkopírované)
- legenda je dole v grafu, barvy mají po najetí myší popisek

Pozor na formulaci: je to **zdroj vs. archiv**, ne „smazané vs. zálohované".
Protože ale platí, že archivovaný řádek je zároveň smazaný, vyjde to nastejno —
jen když se někdo zeptá „takže zelená je to, co jste smazali?", správná odpověď
je **„zelená je to, co je pořád ve WMS"**.

**Graf „Difference by table"** — rozdíl zdroj − archiv. **Tyrkysová = záporné =
archiv má víc**, což je cílový stav, ne problém.

### Konfigurace

Otevřete jednu sadu a ukažte tři věci, víc ne:

1. **`DeleteOrder`** — pořadí mazání, kotva na konci
2. **`JoinToAnchorPredicateSql`** — jak dítě najde svou hlavičku
3. **brána** (`AnchorExtraWhereSql`) — co přežije

### PREP

```sql
EXEC msdb.dbo.sp_start_job @job_name = N'kArchiveManager - PREP CONFIGURED';
```

Pak ukažte naplnění klíčů:

```sql
SELECT p.ProcessCode, wb.Status,
       Keys=(SELECT COUNT(*) FROM arch.WorkBatchKey k WHERE k.WorkBatchId=wb.WorkBatchId)
FROM arch.WorkBatch wb JOIN arch.Process p ON p.ProcessId=wb.ProcessId;
```

Očekávejte **5 sad a 67 995 klíčů**. Řekněte, co se právě stalo: *„Zatím se nic
nesmazalo. Systém si jen vypsal seznam dokumentů, které pravidlům vyhovují, a
uložil ho. Až doteď je to čistě čtení."*

**Sad je pět, ne šest, a je to správně** — fronta práce je TIMESTAMP a připraví se
až při běhu. Čekejte na ten dotaz.

### RUN

```sql
EXEC msdb.dbo.sp_start_job @job_name = N'kArchiveManager - RUN CONFIGURED';
```

Trvá necelé 4 minuty. Mezitím mluvte o dávkování a okně.

Pak výsledek:

```sql
SELECT Archived=SUM(RowsArchived), Deleted=SUM(RowsDeleted),
       Divergence=SUM(RowsArchived)-SUM(RowsDeleted) FROM arch.RunItem;
```

A naplnění archivu — **23 z 23 tabulek, žádná prázdná**:

```sql
SELECT s.name, t.name, Rows=SUM(p.rows)
FROM kArchiveManagerBackups.sys.tables t
JOIN kArchiveManagerBackups.sys.schemas s ON s.schema_id=t.schema_id
JOIN kArchiveManagerBackups.sys.partitions p ON p.object_id=t.object_id AND p.index_id IN (0,1)
GROUP BY s.name,t.name ORDER BY SUM(p.rows);
```

### Důkaz selektivity

Tohle je nejsilnější moment celé prezentace. Ukažte, co ve zdroji **zůstalo**:

```sql
SELECT Total=COUNT(*), NotShipped=SUM(CASE WHEN status<>N'SHIPPED' THEN 1 ELSE 0 END)
FROM AAD.dbo.t_pick_detail;
```

*„Zůstalo přesně tolik řádků, kolik jich neprošlo bránou. Ani o jeden víc."*

---

## Blok 5 (50–55 min) — Co dělá operátor

**Operátorovi stačí konzole.** Žádné SSMS, žádný přístup do databáze.

| obrazovka | k čemu |
|---|---|
| Dashboard | denní pohled — běhy, objemy, signály |
| Runs | historie, co kdy odešlo |
| Document lookup | „kde je objednávka 12345?" |
| Analysis & Estimates | kolik by příští běh vzal, kolik místa |
| Configuration | změna nastavení — vyžaduje přihlášení |
| Validation | kontrola konfigurace před změnou |
| Go-live | seznam podmínek pro ostrý provoz |
| Legal holds | držení dokumentů |

Čtení je anonymní, **editace vyžaduje přihlášení** operátorem vedeným v databázi.
Každé přihlášení i každá změna jsou v auditu.

---

## Blok 6 (55–60 min) — Co potřebujeme od vás

Rozhodnutí, ne úkoly:

1. **Retence** — kolik měsíců zpět musí být dokument okamžitě dostupný? Řekne se
   jednou a platí; z ní plyne všechno ostatní.
2. **Účet pro běh** — vyhrazený, ne sysadmin, ne osobní.
3. **Okno** — kdy smí archivace běžet.
4. **Umístění záloh archivní databáze.** Je to jediná kopie řádku poté, co ze
   zdroje zmizel. Není volitelná.
5. **Indexy** — pokud si konfigurace vyžádá index, vytvoří ho váš DBA. My do WMS
   nesaháme.
6. **Kdo je operátor** a kdo smí měnit konfiguraci.

---

## Pasti — na co si dát pozor

| past | co se stane | co říct |
|---|---|---|
| Server se vypne 60 min po startu | konec prezentace | restartovat těsně před začátkem |
| PREP ukáže 5 sad, ne 6 | někdo se zeptá | fronta práce je TIMESTAMP, jede až v RUN |
| Dry-run dávky se zavírají jako `Failed` | vypadá to na chybu | je to účetnictví náhledu, sloupec `Notes` to říká |
| Tlačítko Stop zastaví **běh**, ne job | vypadá, že nefunguje | job se zastaví přes `sp_stop_job` |
| Kontejnery zůstanou ve zdroji | „proč tyhle ne?" | viz níže |
| Graf Difference — tyrkysová | vypadá jako mínus | archiv má víc, cílový stav |
| Go-live hlásí 1 warning | | alerting `047`, na tomhle stroji není SMTP |

**Nemačkat:** Restore, Apply fix, cokoliv v Configuration — pokud to zrovna
neukazujete schválně.

**Ke kontejnerům**, kdyby se ptali: `t_pick_container` v sadě záměrně není. Nemá
cizí klíč na objednávku, takže objednávky odcházejí čistě i bez něj — ale tři
tabulky mají cizí klíč **do něj** a dvě z nich nenesou číslo objednávky, takže
z objednávkově klíčované sady na ně nedosáhneme. Potřebují vlastní sadu
kotvenou na kontejner. Poctivá formulace: *„našli jsme to, změřili jsme to, a
neuhodli jsme retenční pravidlo — to je rozhodnutí pro vlastníka datového modelu."*
Expozice se měří při každém ověření, není schovaná.

---

## Otázky, které přijdou

**„Co když to smaže něco, co nemělo?"**
Nemůže smazat bez archivace — je to jeden příkaz. Přes 3 miliony řádků, divergence
nula. A archivní databáze má vlastní zálohování.

**„Sáhne to do naší WMS databáze?"**
Jen SELECT a DELETE na pojmenovaných tabulkách. Žádný index, sloupec ani trigger.
Pak ten příběh s filtrovaným indexem — zabere víc než jakékoliv ujištění.

**„Jak dlouho to poběží u nás?"**
Naměřeno půl milionu zdrojových řádků za minutu na jednom testovacím stroji. Ale
neslibujte rychlost — slibte **tvar**: je to omezené shora a přerušitelné.

**„Co když to spadne uprostřed?"**
Blok 3, bod 8. Ukažte tu větu o „success is never inferred".

**„Dostaneme data zpátky?"**
Ano, a právo k tomu je záměrně odepřené.

**„Kdo to bude obsluhovat?"**
Operátor, přes konzoli, bez přístupu do databáze.

---

## Když máte jen 30 minut

Vyhoďte bloky 1 a 6, zkraťte principy na dvě věty. **Nezkracujte blok 3 ani důkaz
selektivity** — to je jediná část, kterou nikdo jiný neukáže.
