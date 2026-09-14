# kArchiveManager 2.0 — Production Go / No-Go Checklist

**Účel:** jediný rozhodovací bod „pustit ostré mazání do produkce ANO/NE". Vyplň před povolením
job‑em řízeného ostrého běhu (`RUN CONFIGURED`). Vychází z runbooku
[`deploy/v2/test-plan/README.md`](../deploy/v2/test-plan/README.md), nálezů
[`professional-hardening-recommendations.md`](professional-hardening-recommendations.md) a živého
dry‑runu z 2026‑06‑02 na `RADIM-STACHAL\RSTSQL2022`.

> **Pravidlo:** všechny položky v sekci A + B musí být ✅. Sekce C jsou bezpečnostní/správnostní
> rizika — buď ✅ vyřešeno, nebo vědomě **risk‑accepted** s podpisem. Bez podpisů v sekci D = **No‑Go**.

---

## A. Funkční důkaz (validační runbook T01–T11)

Spusť na **cílové** instanci (ideálně kopii produkce). Stav z dry‑runu 2026‑06‑02 (RSTSQL2022) v závorce.

- [ ] **T01** Anchor cutoffy UTC‑normalizované — `034` + smoke `31` 0 ERROR  _(✔ ověřeno)_
- [ ] **T02** Recovery job `RECOVER STALE RUNS` enabled, plán 15 min  _(✔)_
- [ ] **T03** `usp_ValidateConfiguration` + `usp_ValidateIndexRequirements` 0 ERROR a runtime smoke `38` `FailedChecks=0`  _(✔ po `37`)_
- [ ] **T04** Timezone policy smoke `31` 0 ERROR  _(✔)_
- [ ] **T05** Gate `THROW 50200` blokuje raw cutoff  _(✔)_
- [ ] **T06** Dry‑run `/validate` odmítne chybnou změnu a nic nepersistuje  _(✔)_
- [ ] **T07** Reálný save odmítne stejný chybný payload (parita, žádná tichá korupce)  _(✔; po F1 fixu vrací 400 s hláškou)_
- [ ] **T08** Operátorský login → `RequestedBy = <operator>` v auditu; špatné heslo → 401; bez tokenu → 423  _(✔ op1)_
- [ ] **T09** Optimistická konkurence: stale `ExpectedModifiedAt` → 409; po refreshi save projde  _(✔)_
- [ ] **T10** Guarded ostrý delete na TEST DB: `RowsArchived = RowsDeleted` (Divergence=0), health pack bez FAIL  _(✔ na Edge se zálohou)_
- [ ] **T11** Recovery zaseknutého běhu reálným jobem (RUNNING → FAILED, WorkBatch → Completed)  _(✔)_

## B. Provozní prerekvizity (must‑have)

- [ ] **Connection string** API míří na produkční DB (`appsettings`/`ConnectionStrings__ArchiveManagerAdmin` nebo IIS). Pozn.: na dev stroji řízeno **Machine env var** → fresh checkout/IIS si nastaví vlastní.
- [ ] **Zálohy zdrojových DB** naplánované (FULL + log) a **restore rehearsal** proveden (recommendation O1).
- [ ] **Restore point** těsně před prvním ostrým během (`BACKUP DATABASE … WITH COPY_ONLY`).
- [ ] **SQL Server Agent** běží a má autostart (`Automatic`), ne `Manual`.
- [ ] **Job `RUN CONFIGURED`** existuje, kroky VALIDATE → RUN, a je **enabled** teprve při Go (vytvořen `SQL job - RUN CONFIGURED.sql`, defaultně disabled). Plán nastaven na reálné okno.
- [ ] **Recovery job** enabled (15 min) — ✔ nasazeno.
- [ ] **Deploy manifest aktuální**: `024` (operational maintenance + `v_OperationalHealth`), `034`, `036`, `037` (indexy) jsou v bundlu / nasazeny. Ověř `T00_db_currency_check.sql` = vše OK + `/api/readiness` `missingObjects/Roles/Permissions = []`.
- [ ] **Cutoff politika potvrzena DBA**: zdrojové DB ukládají lokální CET/CEST (předpoklad `@SourceTimezone`); KMWEBV pevný vs Edge/KMWE_Test rolling je záměr.
- [ ] **Monitoring**: alert na FAILED běhy (health `05`) + na selhání recovery jobu (recommendation O2 — job zatím bez notifikace).

## C. Bezpečnost / správnost (vyřeš nebo risk‑accept)

| # | Položka | Stav | Pozn. |
|---|---------|------|-------|
| S1 | Rate‑limit / lockout na `/api/security/unlock` | ☐ řešeno / ☐ risk‑accept | online brute‑force |
| S2 | KDF místo unsalted SHA‑256 pro hesla (operátoři i shared) | ☐ / ☐ | dnes SHA‑256 |
| S3 | Autentizace read + `explain-plan`/`documents` endpointů | ☐ / ☐ | dnes anonymní |
| S4 | Rozdělit přeprivilegovaný DB login API | ☐ / ☐ | jeden login = všechny role |
| C1 | Restore / un‑archive capability + provenance | ☐ / ☐ | mazání je dnes one‑way |
| C3 | Sargable cutoff (konverze parametru, ne sloupce) | ☐ / ☐ | velké tabulky = scan |
| C4 | Post‑run reconciliation **gate** (ne jen report) | ☐ / ☐ | dnes ruční health |
| F1 | Save chyby 503→400 | ✅ | opraveno 2026‑06‑02 |

## D. Podpisy (bez nich = No‑Go)

- [ ] **DBA** (zálohy, cutoff TZ, restore rehearsal): __________________  datum: ______
- [ ] **Vlastník aplikace** (T01–T11 green, hardening risk‑accept): __________________  datum: ______
- [ ] **Provoz / bezpečnost** (S1–S4 stav, monitoring): __________________  datum: ______

**Rozhodnutí:** ☐ GO  ☐ NO‑GO  — podpis: __________________  datum: ______

> Po GO: enable `RUN CONFIGURED` (`sp_update_job @enabled=1`), nastav plán, a prvních pár běhů
> sleduj přes health pack (`02`/`04`/`05`) + reconciliation (`T10_reconciliation.sql`).
