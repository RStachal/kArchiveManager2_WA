# kArchive Manager 2.0 — kompletní postup nasazení u zákazníka (krok po kroku)

Jeden ucelený postup nasazení **celé aplikace** (SQL platforma + Admin Console + joby + seed + ověření).
Detaily jednotlivých kroků jsou v runboocích v `04-runbooks/`; tento dokument je **závazné pořadí**.

> Konvence: 🟦 SQL (SSMS / sqlcmd) · 🟩 PowerShell / IIS · ✅ kontrola (musí projít) · ⚠️ pozor.

---

## 0. Předpoklady ⏱
- **SQL Server 2019+** (Standard nebo vyšší; viz `COMPATIBILITY-MATRIX.md`), SQL Agent zapnutý.
- **Windows Server** + **IIS** + **.NET 9 Hosting Bundle** (ASP.NET Core) pro Admin Console.
- Účty: účet s **sysadmin** pro deploy; **dedikovaný non-sysadmin Windows servisní účet** pro runner
  (`DOMAIN\svc-karchive`); aplikační pool účet pro Console.
- Znáte: názvy zdrojových DB, retenci/cutoff per proces, časovou zónu dat, noční okno, cestu pro zálohy.
- Balíček rozbalen na serveru; v SSMS nastaven `:setvar Root` na složku `ArchiveManager1.0` (nebo použijte `_SSMS` variantu bez SQLCMD módu).

---

## 1. Nasazení SQL platformy 🟦
1. Spusťte **`01-database/deploy_clean_v2_full_SSMS.sql`** (klasicky, F5) — vytvoří DB
   `kArchiveManagerAdmin` + `kArchiveManagerBackups` (FULL recovery) + všechny objekty + role + (vypnuté) joby.
2. ✅ Spusťte **`verify_clean_deploy.sql`** → musí vrátit **PASS** (všechny objekty, žádné v1/relikty/smoke).

## 2. Behaviorální smoke (na čisté instalaci) 🟦
3. ✅ **`selftest_acceptance.sql`** → PASS (syntetický archive/delete/restore/audit/TZ-gate na throwaway schématu, sám se uklidí).
4. ✅ **`variant_test_pack.sql`** → **ALL VARIANTS PASSED** (ANCHOR/TIMESTAMP × Mode 0/1/2, audit, brány, restore).

## 3. Seed zákaznických procesů 🟦
5. Vezměte **`01-database/seed_tested_processes.sql`** jako šablonu a **upravte**: názvy zdrojových DB,
   per-proces **Mode / RetentionDays / CutoffMode+CutoffDate / AT TIME ZONE výraz / AuditLevel**.
   ⚠️ Vypněte testovací `WA_AAD_*_OSTRY_SMOKE` procesy. Zvažte `AuditLevel=ROW` (auditovatelnost) vs `NONE` (výkon).
6. (Výkon, volitelné, bez indexů ve zdroji) Pro velkoobjemové TIMESTAMP procesy (např. RF_LOG2) zapněte
   **cheap-mode** (`CandidateSelectExpr` bez per-row AT TIME ZONE + `CandidateOrderSql` = clustered klíč) a
   držte `BatchRowCount ≤ 4000` (lock-safe). Viz `perf-locksafety-checklist.md`.
7. ✅ **Validation** (konzole) nebo `usp_ValidateConfiguration` → žádné ERROR (chybějící indexy jsou jen WARN).

## 4. Runner — least-privilege login (T-33) 🟦 ⚠️ KRITICKÉ
8. Spusťte **`01-database/operational-add-ons/053_runtime_least_privilege_principal.sql`** s vyplněným
   CHANGE-ME: `@RuntimeLogin='DOMAIN\svc-karchive'`, `@LoginType='WINDOWS'`, `@SourceDbsCsv=…`, `@Apply=1`.
   → vytvoří granty (per-table SELECT/DELETE na zdroji, INSERT/SELECT/ALTER na archivu) + pre-provision archivu.
9. Spusťte **`054_runner_job_least_privilege.sql`**: `@RuntimeLogin='DOMAIN\svc-karchive'`,
   `@JobNameLike='kArchiveManager - %CONFIGURED'`, `@Apply=1` → přeovní PREP+RUN joby na runnera.
10. ✅ Ověřte: `EXECUTE AS LOGIN='DOMAIN\svc-karchive'; EXEC arch.usp_VerifyRunnerPrivileges; REVERT;` → jediný **OK** řádek.
> ⚠️ **Po každé obnově (restore) zdrojové/archivní DB se granty smažou → znovu spusťte krok 8–9** (+ případně `ALTER DATABASE [X] SET MULTI_USER`). Jinak joby padají na **51001**.

## 5. Zálohy archivu 🟦
11. Pre-size log archivu (aby velké běhy nerostly log za běhu) a spusťte **`048_archive_db_backup.sql`**
    s vyplněným `@BackupRoot` (existující složka, zapisovatelná Agent účtem) → FULL (denně) + LOG (hodinově) joby.
12. (Volitelné) `047_operational_alerting.sql` (alerty), `051_grant_console_read_source_dbs.sql` (čtení zdrojů pro Dashboard).

## 6. Admin Console na IIS 🟩
13. Publikujte: **`02-admin-console/publish-admin-console.ps1 -OutputPath <web>`** (nebo použijte předpublikovanou `02-admin-console/app/`).
14. Vytvořte IIS site (např. `:8089`), app pool (.NET CLR „No Managed Code", identita = aplikační účet).
15. Upravte **`appsettings.json`**: connection string na `kArchiveManagerAdmin` (Trusted_Connection).
    Pro produkci nastavte **Windows auth allowlist** (`AdminConsole:AdminUsers`) a **elevated tier**
    (`AdminConsole:ElevatedAdminUsers`) pro restore. Detail: `04-runbooks/admin-console-iis-deployment.md`.
    ⚠️ **IIS na jiném serveru než SQL** je podporováno (běžná topologie, **žádný double-hop**): `Server=`
    míří na vzdálenou instanci, a **identita app poolu** (dedikovaný `DOMAIN\svc-kam-console`, nebo SQL login)
    musí mít login + console role na `kArchiveManagerAdmin` + TCP/port otevřený. Viz sekce „IIS on a SEPARATE
    server" v IIS runbooku.
16. ✅ Otevřete URL → Dashboard se načte, „API OK / DB OK".

## 7. Plánování a aktivace jobů 🟦 / konzole
17. V **Configuration → Plánování** (nebo `sp_update_job`) **zapněte** PREP (denně, dříve) + RUN (denně, později) joby.
    ⚠️ Joby tím poběží automaticky v nočním okně — potvrďte s zákazníkem.

## 8. Produkční ověření 🟦
18. ✅ Spusťte malý **DryRun** (konzole / proc) na jednom procesu → preview kandidátů, žádné mazání.
19. ✅ (Volitelně) první ostrý běh v okně + rekonciliace: `archived == deleted`, **Divergence=0**, zdroj pre−post sedí.
20. ✅ Projděte **`04-runbooks/production-go-no-go-checklist.md`** a **`release-conditions-status.md`** (R-04..R-07 dle prostředí).

## 9. Předání podpoře
21. Vyplňte „Klíčová fakta" v `05-training/training-l1-l2-support.md` (instance, DB, runner, okno, kontakty).
22. Proškolte L1/L2 dle školicí šablony. Předejte uživatelskou + admin příručku (`03-docs/manuals/`).

---

## Akceptační podpis
```
Instance / edice / recovery : __________   Datum / nasadil : __________
verify_clean_deploy = PASS  : [ ]   selftest + variant_test_pack = PASS : [ ]
Seed aplikován + Validation bez ERROR : [ ]   Runner ověřen (usp_VerifyRunnerPrivileges = OK) : [ ]
Zálohy archivu (048) běží : [ ]   Admin Console dostupná + Windows auth + elevated tier : [ ]
PREP/RUN naplánovány : [ ]   DryRun/ostrý běh Divergence=0 : [ ]   Go-no-go projito : [ ]
Podpora proškolena (L1/L2) : [ ]
```
