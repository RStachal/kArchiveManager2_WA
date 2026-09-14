# kArchive Manager 2.0 — školení podpory L1 / L2

> **Šablona prezentace pro zaškolení kolegů.** Cíl: po školení umí L1/L2 nástroj **obsluhovat,
> sledovat a řešit běžné incidenty** bez detailní znalosti vnitřní architektury. Každý „modul" =
> blok prezentace; ⏱ = orientační čas; 🎯 = co má účastník umět; 💬 = mluvené poznámky lektora.
>
> **Délka:** ~90 min + 30 min hands-on. **Předpoklady:** přístup do Admin Console (read), základ SQL Serveru.

---

## Modul 0 — Úvod a cíl školení ⏱5 min
🎯 *Vědět, k čemu nástroj slouží a koho podporujeme.*
- **Co je kArchive Manager 2.0:** nástroj, který **bezpečně archivuje a maže stará data** z produkčních
  databází WMS (Warehouse Advantage / KMWE / Edge…). Staré záznamy se zkopírují do archivní databáze a
  z produkce smažou — produkce zůstává štíhlá a rychlá, ale data nejsou ztracená (lze je dohledat/obnovit).
- **Kdo to ovládá:** archivace běží automaticky (noční SQL Agent joby). Lidé pracují přes **Admin Console**
  (webová aplikace) — konfigurace, sledování, kontroly, dohledání dokladu.
- **Naše role (L1/L2):** sledovat zdraví, odpovědět „kde jsou moje data", reagovat na chyby jobů,
  eskalovat složitější věci. **Nemažeme data ručně, neměníme produkční schéma.**

💬 *Zdůrazni: nástroj je „bezpečný z principu" — co se smaže, je vždy nejdřív zazálohováno; vše je auditované.*

---

## Modul 1 — Klíčové pojmy (slovník podpory) ⏱10 min
🎯 *Rozumět pojmům, které uvidí v konzoli a v logu.*

| Pojem | Co to znamená (lidsky) |
|---|---|
| **Proces** | Jeden typ dat k archivaci (např. `RF_LOG2` = systémové logy, `RECEIVING` = příjmové doklady). |
| **Mapping** | Proces nasazený na konkrétní zdrojovou DB (`RF_LOG2 @ Edge`). |
| **Retence / Cutoff** | Hranice stáří — co je starší, je „způsobilé" k archivaci. Mladší data se nikdy nedotknou. |
| **Kandidát** | Konkrétní řádek/doklad způsobilý k archivaci v daném běhu. |
| **Run (běh)** | Jedno spuštění archivace. Má stav OK / FAILED / DRYRUN a počty řádků. |
| **Archiv** | Databáze `kArchiveManagerBackups` — sem se ukládají kopie smazaných řádků. |
| **Režim (Mode)** | **1** = archivovat + smazat (běžné), **0** = jen smazat, **2** = jen kopírovat (bez mazání). |
| **Audit** | Záznam „co/kdy/kdo smazal" — `RunDocAudit`. Nelze ho měnit ani mazat. |
| **Divergence** | Kontrolní číslo: u režimu 1 musí být **0** = „smazáno přesně to, co bylo zazálohováno". |

💬 *Klíčová věta pro zákazníka: „Mode 1 → archivováno == smazáno, Divergence = 0. Jinak se nic nesmaže."*

---

## Modul 2 — Jak to funguje (jen princip, ne architektura) ⏱10 min
🎯 *Umět vysvětlit tok zákazníkovi na vysoké úrovni.*

```
   Produkční DB (zdroj)                kArchive Manager                 Archiv (kArchiveManagerBackups)
   ┌─────────────────┐    1) VÝBĚR    ┌──────────────────┐   2) ZÁLOHA  ┌──────────────────────────┐
   │ stará data       │ ───────────▶  │ vybere kandidáty │ ───────────▶ │ kopie řádků (FULL backup)│
   │ (za cutoffem)    │  (NEZAMYKÁ!)  │ podle retence    │              └──────────────────────────┘
   │                  │ ◀───────────  │ 3) SMAZÁNÍ v okně │   (smazání a záloha v JEDNÉ transakci)
   └─────────────────┘    3) DELETE   └──────────────────┘
```
- **Výběr kandidátů NIKDY nezamyká produkci** (čte bez zámků) → aplikace zákazníka neběží pomaleji.
- **Mazání** probíhá v dávkách v dohodnutém **nočním okně**, malé dávky → nezamyká celé tabulky.
- **Záloha a smazání jsou atomické** → nikdy se nesmaže nic, co není v archivu.
- **Dvě strategie** (jen pojmenovat): **ANCHOR** (doklad + jeho řádky) a **TIMESTAMP** (logy podle času).

💬 *Nemusíš vysvětlovat ANCHOR vs TIMESTAMP detailně — stačí „dva způsoby výběru podle typu dat".*

---

## Modul 3 — Prohlídka Admin Console ⏱20 min
🎯 *Vědět, k čemu slouží každá obrazovka a kde co najít.* (Otevři konzoli a proklikej živě.)

- **Přihlášení / Unlock:** čtení je volné; změny vyžadují odemčení (operátor + heslo, nebo Windows účet).
  **Elevated** (restore do produkce) vyžaduje vyšší oprávnění.
- **Dashboard** — stav na první pohled: aktivní procesy, počty řádků zdroj/archiv, poslední běhy,
  „Operational signals" (Data balance, Run health, Prep/run queue, Config validation). **Sem se L1 dívá první.**
- **Runs** — historie běhů: stav (OK/FAILED), kolik archivováno/smazáno, trvání, chybová hláška.
- **Document lookup** — *„Byl tenhle doklad zarchivován?"* Zadá se klíč dokladu → ukáže, kdy a kam se přesunul.
- **Analysis & Estimates** — odhad, kolik příští běh zpracuje (řádky / MB) + grafy zdroj vs archiv.
- **Configuration** — procesy, mapování, retence, režim, audit, plánování jobů, operátoři. **Změny = 4 oči.**
- **Validation** — kontrola konfigurace + chybějící indexy (jen doporučení, ne automatické nasazení).
- **Go-live** — finální kontrolní seznam před produkčním spuštěním.

💬 *L1 typicky používá Dashboard + Runs + Document lookup. Configuration je doména L2 / administrátora.*

---

## Modul 4 — Běžné úkoly L1 ⏱10 min
🎯 *Zvládnout nejčastější dotazy bez eskalace.*

1. **„Je systém v pořádku?"** → Dashboard → zelené signály. Červený „Run health" = byl neúspěšný běh → Runs.
2. **„Kde je můj doklad / byl smazán?"** → Document lookup → zadat klíč → ukáže archiv + čas smazání.
3. **„Proč ubyla data v tabulce?"** → Runs → poslední běh procesu → počty + Divergence=0 = korektní archivace.
4. **„Kolik se bude mazat příště?"** → Analysis & Estimates.
5. **„Potřebuju doklad zpět"** → to je **restore** = řádkové vrácení z archivu → **eskalace na L2** (vyžaduje elevated).

💬 *Nikdy neraď zákazníkovi mazat/měnit data ručně v DB. Vše jde přes konzoli nebo eskalaci.*

---

## Modul 5 — Chybové kódy a první reakce ⏱15 min
🎯 *Poznat běžné chyby z logu jobu a vědět, co s nimi.* (Kód uvidíš v historii SQL Agent jobu / hlášce.)

| Kód | Význam | První reakce (L1 → L2) |
|---|---|---|
| **51001** | Runner job nemá oprávnění (běží jako sysadmin / chybí granty). **Časté po obnově DB!** | L2: znovu spustit `053`+`054` (a `SET MULTI_USER`). Viz deploy guide. |
| **51000** | Konfigurace pro běh není platná/aktivní. | L2: zkontrolovat Configuration / Validation. |
| **50200** | Časová zóna není správně nastavená (TZ gate). | L2: ověřit konfiguraci časové zóny procesu. |
| **50210** | Pokus o nastavení retence pod bezpečné minimum. | L2: retence nesmí klesnout pod floor — odmítnuto správně. |
| **50115 / 50116 / 50320** | Souběh / klíč není unikátní / applock. | L2: typicky dva běhy najednou nebo špatný klíč. |
| **50400** | Nebezpečný SQL výraz v konfiguraci (safe-expr gate). | L2: někdo zadal nevalidní výraz do pole konfigurace. |
| **50223** | Copy-only (Mode 2) bez primárního klíče. | L2: tabulka potřebuje PK pro deduplikaci. |
| **50500–50504** | Chyba odhadu (Estimates). | L1: většinou neškodné, zkusit znovu; jinak L2. |

💬 *Nejčastější reálný incident: **po obnově/restoru zdrojové DB padají PREP/RUN joby na 51001** — granty
runnera se obnovou smažou. Řešení je v deploy guide (krok „Runner login"). To je „must-know" pro L2.*

---

## Modul 6 — Co řeší L2 vs. co eskalovat ⏱5 min
🎯 *Vědět, kde končí podpora a začíná engineering.*

| Úroveň | Zvládá |
|---|---|
| **L1** | Sledování (Dashboard/Runs), dohledání dokladu, vysvětlení stavu, sběr informací k incidentu. |
| **L2** | Restart/oprava jobů (51001 → 053/054), validace konfigurace, plánování jobů, restore (elevated), čtení auditu, znovunasazení záloh (048). |
| **Eskalace (engineering)** | Změna chování runneru, výkonové ladění (cheap-mode/dávky), schema/upgrade, podezření na ztrátu dat. |

💬 *Hranice: „mažeme/měníme data v DB ručně" = NIKDY. „Nejasná ztráta dat / Divergence ≠ 0" = okamžitá eskalace.*

---

## Modul 7 — Bezpečnostní pravidla (must-know) ⏱5 min
🎯 *Co podpora nikdy nedělá.*
- ❌ Neměníme ani nemažeme data přímo v produkční DB.
- ❌ Nenasazujeme indexy do zdrojové (zákaznické) DB.
- ❌ Nespouštíme runner pod účtem sysadmina (proto existuje 51001 brána).
- ✅ Restore (vrácení dat) jen přes konzoli s **elevated** oprávněním a se souhlasem.
- ✅ Změny konfigurace jen přes konzoli (4 oči + důvod změny + audit).

---

## Modul 8 — Hands-on / ověření (šablona) ⏱30 min
🎯 *Účastník si vyzkouší a prokáže porozumění.*
1. Najdi na Dashboardu, kolik je aktivních procesů a zda byl poslední běh OK.
2. V Runs najdi poslední běh `RF_LOG2` a přečti: archivováno / smazáno / Divergence.
3. V Document lookup dohledej konkrétní doklad a zjisti, zda je v archivu.
4. V Analysis & Estimates zjisti odhad příští dávky.
5. **Kvíz:** Co znamená 51001? Co uděláš jako L1? Kdy eskaluješ?

---

## Příloha A — Rychlá karta chybových kódů
`51001` runner gate (po restoru!) · `51000` neplatná konfig · `50200` TZ · `50210` retence floor ·
`50115/50116/50320` souběh/klíč/applock · `50400` nebezpečný výraz · `50223` copy bez PK · `50500+` odhad.

## Příloha B — Klíčová fakta o nasazení (vyplnit pro zákazníka)
- SQL instance: `__________`  · Admin DB: `kArchiveManagerAdmin` · Archiv: `kArchiveManagerBackups`
- Zdrojové DB: `__________`  · Admin Console URL: `http://____:____`
- Runner účet (svc): `__________` · Noční okno (PREP/RUN): `__:__ / __:__`
- Kontakt L2 / engineering eskalace: `__________`

## Příloha C — Kam pro detaily (v handover balíčku)
- Uživatelská příručka (`manuals/…user-manual.doc`), Admin příručka (`…kompletni-dokumentace.doc`).
- Kompletní deploy postup: `customer-deploy-guide.md`. Stav release podmínek: `release-conditions-status.md`.
- Provozní runbooky: `04-runbooks/` (operator, IIS, go-live).
