# Testovací nasazení nad KMWE (procesy WMS Edge)

Záznam nasazení z 2. 11. 2026. Databázová část na **WA01** (192.168.120.128),
Admin Console odděleně na **RADIM-STACHAL** (192.168.120.1).

## Co bylo nasazeno

| Vrstva | Stav |
| --- | --- |
| `kArchiveManagerAdmin`, `kArchiveManagerBackups` | založeny načisto, jádro (63 includes) |
| Samotesty jádra | PASS — archivace, mazání, audit, obnova i brána časové zóny |
| Variantní sada | 36 PASS / 0 FAIL — ANCHOR i TIMESTAMP ve všech režimech |
| Konfigurace | 3 plány, 11 tabulek, retence 450 dní |
| Archivní tabulky | 11, ve schématu `KMWE` |
| Požadavky na indexy | 14, z toho 3 nepokryté (jen varování) |
| Běhový účet + účet konzole | SQL loginy, ověřeny přes TCP i záporně |
| Joby SQL Agenta | 5, PREP a RUN záměrně vypnuté |
| PREP | 50 klíčů příjmy, 499 výdeje — zdroj nedotčen |
| RUN nanečisto | zdroj beze změny, archiv prázdný |
| **První ostrý běh** | **neproveden — čeká na rozhodnutí** |

## Konfigurace plánů

| Plán | Strategie | Kotva / řídící tabulka | Klíč | Tabulek | Audit |
| --- | --- | --- | --- | --- | --- |
| `RECEIVING` | ANCHOR | `BACKRH` | `PO_NUM` | 3 | ROW |
| `SHIPPING` | ANCHOR | `SHIPHIST` | `PACKSLIP` | 7 | ROW |
| `RF_LOG2` | TIMESTAMP | `RF_LOG2` (řádek) | `ROWID` | 1 | NONE |

Proti dodávanému seedu přibyly **`BACKRD2` a `SHIPMSTR2`**, které návrh ze
18. 6. 2026 vyžaduje. Obě se vážou na hlavičku stejně jako ostatní potomci
(`PO_NUM`, resp. `PACKSLIP`), cizí klíče v KMWE nejsou žádné, takže pořadí
mazání drží výhradně konfigurace — kotva má proto nejvyšší `DeleteOrder`.

Audit na jednotlivý doklad je zapnutý u obou dokladových plánů. U logu zůstává
vypnutý záměrně: dokumentem je tam jediný řádek, takže by stopa narostla stejně
jako archiv.

## Pět věcí, které se musely upravit oproti dodávanému stavu

### 1. KMWE bylo na compatibility level 100 — `TRY_CONVERT` tam nefunguje

Precheck to hlásil jako blokátor s odůvodněním, že selže `AT TIME ZONE`. **To
odůvodnění je nesprávné** — `AT TIME ZONE` je funkce verze serveru, ne compat
levelu, a ověřeně funguje i na úrovni 100, včetně dynamického SQL napříč
databázemi. Skutečně selhává `TRY_CONVERT` (vyžaduje 110+), na kterém stojí
konfigurace logu; `TRY_CAST` přitom projde.

Po dohodě byl **compat level zvýšen na 130**. Původní hodnota byla 100, návrat
je jednořádkový.

> Pravidlo v `sql/01_precheck.sql:63` stojí za opravu: podmínka je správná
> (compat < 130 vadí), ale pojmenovává špatnou příčinu, takže vede diagnostiku
> jinam.

### 2. RF_LOG2 se v KMWE neřídí sloupcem `TIMESTMP`

Dodávaný seed parsuje `TIMESTMP`. Ten v KMWE **neexistuje**. Čas nese
`DATE_TIME nvarchar(46)` ve tvaru `'20220210 13:12:48.37'`. Konfigurace ho
skládá na ISO 8601 a parsuje přes `TRY_CONVERT(..., 126)`.

**Dvacet řádků ze 7 436 má `DATE_TIME` prázdný řetězec** (ne NULL). Brána je
vylučuje: co nejde datovat, se nearchivuje ani nemaže.

### 3. Cheap-mode u logu

Validace sama doporučila a nabídla jedním krokem (`ENABLE_CHEAP_MODE`)
odstranění `AT TIME ZONE` z kandidátního scanu. U produkčních objemů logu
(134 mil. řádků, ~110 GB) je to dominantní náklad, takže byl zapnut.

Pozor: `DATE_TIME` ve tvaru `yyyyMMdd` řadí lexikálně shodně s chronologií,
takže index nad ním rozsahový dotaz obslouží — ale jen při porovnání na surový
řetězec. Cheap-mode porovnává hodnotu po parsování, což SARGable není. **U
produkčních objemů to stojí za ověření plánem.**

### 4. Profil běhu `JOB_DEFAULT` nezakládá pro Edge nic

Joby z `sql/56_agent_jobs.sql` volají `arch.usp_RunProfile_Prepared` s profilem
`JOB_DEFAULT`, ale ten zakládá jen `sql/04_seed_order.sql` — tedy AAD seed. Při
nasazení nad Edge by **joby na první spuštění spadly**. Profil byl doplněn přes
`arch.usp_Api_SaveRunProfile` (okno 55 minut), takže vznikl i záznam o změně
konfigurace.

### 5. `variant_test_pack.sql` byl pozadu za procedurou

`@vfind` deklarovala 7 sloupců, zatímco `arch.usp_ValidateConfiguration` vrací 8
(přibyl `ActionKey`) → `Msg 213`. Oprava existovala v repozitáři
`WMSArchiveManager` (452445f) a byla sem přenesena.

## Komunikace mezi stroji

WA01 **není v doméně** (WORKGROUP), takže Windows autentizace z RADIM-STACHAL
neprojde. Konzole se proto připojuje **SQL loginem**. Dodávané skripty
(051, 059, 063–066) počítají s identitou aplikačního fondu IIS na témže stroji;
pro vzdálenou konzoli vznikl `sql/61_console_principal_sql_login.sql`, který
přidělí tutéž sadu práv SQL loginu.

Ověřeno přes TCP z adresy 192.168.120.128:

| Zkouška | Výsledek |
| --- | --- |
| přihlášení `karch_console` | prošlo |
| pět rolí `karch_*` (bez `karch_runtime`) | přiděleno |
| DMV pro grafy (`VIEW DATABASE PERFORMANCE STATE`) | čte |
| `msdb` pro go-live kontrolu | vidí 37 jobů |
| **DELETE ve zdroji** | **odmítnuto (229)** |
| **DELETE v archivu** | **odmítnuto (229)** |
| SELECT ve zdroji | prošlo |

Firewall je na WA01 **vypnutý na všech profilech** — pro testovací prostředí to
stačí, u zákazníka bude potřeba pravidlo pro 1433.

## Nasazení konzole na RADIM-STACHAL

Aplikace konzole **je v repozitáři** — v `kAM2/02-admin-console/app/`, včetně
`wwwroot`. Ověřeno, že `KArchiveManager.AdminConsole.Api.dll` je bajt za bajtem
shodná s instalací běžící na WA01 a obě cílí na `net10.0`. Instalační skript
proto bere soubory odtud a **žádný balíček není potřeba**; vše podstatné je
verzované, takže to přežije výměnu stroje.

Na RADIM-STACHAL stačí mít klon repozitáře a v PowerShellu **jako správce**:

```powershell
# předpoklad: role IIS a .NET 10 Hosting Bundle
# POZOR: aplikace cílí na net10.0. Runtime 8 ani 9 nestačí, přestože to
# dodávaný handover README tvrdí. Po instalaci bundlu: iisreset

cd <klon>\console
.\Install-Console-Remote.ps1 `
    -SqlServer 192.168.120.128 `
    -SqlPassword '<heslo karch_console>' `
    -UseEnvVar
```

Bez klonu repozitáře lze předat `-PayloadZip <cesta>`. Balíček
`console/AdminConsole-payload.zip` existuje na WA01, ale **v gitu není** a může
zastarat — je to jen offline alternativa, ne hlavní cesta.

`-UseEnvVar` uloží connection string do proměnné prostředí aplikačního fondu,
takže heslo nezůstane v `appsettings.json` na disku.

Skript sám ověří: práva správce, modul IIS, přítomnost `AspNetCoreModuleV2`,
dostupnost portu 1433, **skutečné přihlášení SQL loginem**, a po nasazení
zavolá `/health` a `/api/readiness`. Při neúspěchu vypíše nejčastější příčiny.

Zároveň řeší **vadu č. 1 z `ADMIN-CONSOLE.md`**: `Microsoft.Data.SqlClient.SNI.dll`
leží tam, kam ho uloží NuGet — v `runtimes\win-x64\native\` — a ASP.NET Core si
ho u framework-dependent nasazení sám nenajde. Bez kopie do kořene se konzole
k databázi nepřipojí, a skript tu kopii udělá automaticky.

## Co zbývá

1. **První ostrý běh** (`RUN` s profilem `JOB_DEFAULT`) — maže ze zdroje, proto
   čeká na výslovné rozhodnutí. Připraveno je 50 příjmových a 499 výdejových
   dokladů; log se vybírá až za běhu.
2. **Rozvrhy jobů PREP a RUN** — vytvořeny vypnuté. Doporučení: PREP jednou
   denně těsně po pracovní době, RUN hodinově v přiděleném okně (profil drží
   55 minut, takže při hodinovém jobu zbývá pět minut rezervy).
3. **Tři nepokryté indexy** (`BACKRH` selection, `RF_LOG2` selection,
   `SHIPLINE2` join) — nástroj vypisuje hotové DDL, ale **do WMS databáze nic
   nezakládá**. Je to rozhodnutí DBA zákazníka.
4. **Ověřit produkční KWME**: compat level, existenci `TIMESTMP` vs `DATE_TIME`
   a collation. Pokud se liší od této kopie, bude se lišit i konfigurace a test
   by pak ověřoval něco jiného, než co poběží ostře.
5. **SK prostředí (`KWMESK`)** — stačí přidat řádky do `arch.ProcessDatabase`;
   archivní schéma vznikne automaticky pod názvem zdrojové databáze, takže CZ
   a SK zůstanou oddělené v téže archivní databázi.
