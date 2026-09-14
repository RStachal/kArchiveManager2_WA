# kArchiveManager 2.0 — Customer Handover Package

Production-ready deliverable: a universal, configuration-driven WMS archiving platform
(control DB `kArchiveManagerAdmin` + archive DB `kArchiveManagerBackups`) with a web Admin
Console, full audit trail, and SQL Agent automation.

This package is **self-contained**. Follow the steps in order.

> ⭐ **START HERE — the complete, ordered, end-to-end deployment procedure is
> `04-runbooks/customer-deploy-guide.md`.** The numbered sections below are the summary; that guide
> is the authoritative step-by-step (DB → seed → runner → backups → Admin Console → jobs → smoke → go-live)
> with an acceptance sign-off. New colleagues: see the support training in `05-training/`.

---

## 0. Prerequisites (customer server)

- **SQL Server 2019+** (tested on 2022). SQL Server Agent enabled (for the jobs).
- For the Admin Console: **Windows Server + IIS** with the **ASP.NET Core Hosting Bundle**
  (.NET 8/9 runtime) installed. (See `04-runbooks/admin-console-iis-deployment.md`.)
- An account with `sysadmin` (or equivalent) to run the database deploy once.

---

## 1. Database deploy (`01-database/`)

Run **one** of the two bundles against a fresh server (it creates both databases):

- **Primary — classic SSMS, no SQLCMD mode:** open `deploy_clean_v2_full_SSMS.sql` in SSMS and
  run with F5. Fully self-contained (every include inlined).
- **Alternative — SQLCMD:** `deploy_clean_v2_full.sql` requires SQLCMD Mode + the `source-objects/`
  folder; set `:setvar Root "<path-to>\source-objects"` at the top first. (`source-objects/`
  contains `kArchiveManagerAdmin/` + `Databases/`, the scripts the SQLCMD master `:r`-includes.)

Then **verify** (each must pass):

1. `verify_clean_deploy.sql` → **PASS** (all expected objects, no v1/relics/smoke).
2. `selftest_acceptance.sql` → **PASS** (turnkey behavioral smoke: archive/delete/restore/audit/TZ-gate on a throwaway schema, self-cleans).
3. `variant_test_pack.sql` → **ALL VARIANTS PASSED** (ANCHOR/TIMESTAMP × Mode 0/1/2, DryRun, audit levels, retention-floor & TZ gates, restore, stop-audit).

> The SQL Agent jobs require SQL Agent. `RUN CONFIGURED` ships **DISABLED** by design (see step 5).

---

## 2. Configure processes (seed)

Define the processes/mappings for the customer's databases either:

- **Admin Console** (recommended): Configuration tab → create processes, source/archive mappings,
  object specs, key specs, run profiles; or
- **Script:** adapt `01-database/seed_tested_processes.sql` to the customer DB names (it is a
  reference seed of the tested processes — RF_LOG2, INTEGRACE_DNLOAD/UPLOAD, RECEIVING, SHIPPING).

Timezone/cutoff policy: see `03-docs/production-timezone-cutoff-policy.md`.

---

## 3. Operational add-ons (`01-database/operational-add-ons/`, parameterized)

Run after the bundle, filling the `CHANGE-ME` placeholders:

- `051_grant_console_read_source_dbs.sql` — **required**: app-pool read on source/archive DBs (dashboard).
- `053_runtime_least_privilege_principal.sql` + `054_runner_job_least_privilege.sql` — **recommended**:
  dedicated non-sysadmin runner login + least-privilege cross-DB grants (T-33), re-own the job to it.
- `047_operational_alerting.sql` — Database Mail + failure alerting.
- `048_archive_db_backup.sql` — archive-DB FULL+LOG backup jobs.
- `052_archive_with_index_parking.sql` — *optional* high-volume perf helper.
- `063_console_apply_config_fix.sql` — Admin Console **"Apply fix"** button (self-contained:
  `usp_ValidateConfiguration` w/ `ActionKey` + `usp_Api_ApplyConfigFix` + grants). **Already included in the
  clean-deploy chain** (`deploy_clean_v2_full.sql`); the copy here is for reference / re-apply.
- `064_console_default_operator.sql` — **REQUIRED**: seed the default `admin` Console operator so someone can
  log in. Parameterized: (1) run `KArchiveManager.AdminConsole.Api.exe hash-password "<password>"`, (2) paste the
  `PBKDF2-...` value into the script (replacing `CHANGE-ME`), (3) run it. Creates a `sa`-like default (enabled,
  elevated) — **disable it** from the console once you've created real operators. The console starts without it,
  but **nobody can edit Configuration / Validation / Go-live** until at least one enabled operator exists.
- `036_install_recover_stale_runs_job.sql` — *optional*: SQL Agent job to auto-recover stale/abandoned runs.
- `058_agent_job_control.sql` — *optional*: PREP/RUN two-phase Agent job + Console job-control API.
- `043_remove_overprivileged_principals.sql` — existing-environment remediation only (guarded, `@IConfirm='NO'` default).
- `065_grant_console_restore_source_insert.sql` — **OPT-IN (off by default)**: enable the console **"Restore
  from archive"** button to perform a *real* restore. By design the tool never writes to a production **source**
  (least privilege) — so restore, the one op that writes back into the source, is **DBA-only by default**: the
  console dry-run *preview* works, but a real restore returns `INSERT permission denied` unless either a DBA runs
  `arch.usp_RestoreFromArchive` directly under a privileged login, **or** you apply `065` to grant the console's
  source-side principal INSERT on the mapped source tables. `065` is a deliberate privilege expansion — apply it
  only if you want restore operable from the console (it stays gated to the elevated **L2** tier and is audited).

---

## 4. Admin Console (`02-admin-console/`)

- Deploy `app/` to IIS — full procedure in `04-runbooks/admin-console-iis-deployment.md`.
- Configure `app/appsettings.json` (a sanitized template ships in the package; see
  `appsettings.sample.json`):
  - `ConnectionStrings:ArchiveManagerAdmin` — point to the customer `kArchiveManagerAdmin`.
  - **Edit access (default model): DB-managed operators** — domain-independent, no SSMS/AD accounts.
    The template ships with `WindowsAuthEnabled:false`, `DbOperatorsEnabled:true`, `EditPasswordSha256:""`.
    Seed the default operator with add-on **`064_console_default_operator.sql`** (above), then add/disable
    operators from the console's **Configuration → Operators** panel. Reads (Dashboard / Analysis / Runs /
    Document lookup) stay anonymous; edits (Configuration / Validation / Go-live) require a username+password
    login. `AdminConsole:AdminUsers` (Windows allowlist) and `EditPasswordSha256` (no-username shared password)
    remain available as opt-in fallbacks. See `03-docs/governance-model.md`.
- Verify: open the site → top-bar badge **API OK / DB OK**, Dashboard loads, Validation clean.
  Editing prompts for **username + password** (the seeded `admin` + the password you set in 064).
- `publish-admin-console.ps1` is included to rebuild/redeploy from source if needed.

---

## 5. Enable automation

`RUN CONFIGURED` ships **disabled** so nothing runs before the config is verified. When ready,
enable it on an off-peak schedule (e.g. **daily 01:00**) — via SSMS (SQL Server Agent → Jobs →
*kArchiveManager - RUN CONFIGURED* → enable + schedule) or `sp_update_job`/`sp_update_schedule`.
`RECOVER STALE RUNS` and `HEALTH ALERT` are enabled automatically.

The job is a two-step gate: **VALIDATE CONFIGURATION** (fails fast on misconfig / missing runner
privileges) → **RUN CONFIGURED PROCESSES**.

---

## 6. Go-live

Work through `04-runbooks/production-go-live-runbook.md` and
`04-runbooks/production-go-no-go-checklist.md`. The Admin Console's **Go-live** tab surfaces the
readiness gate; **Validation** surfaces configuration/index findings.

---

## Documentation (`03-docs/`)

- ⭐ `kArchiveManager-geneze-dokumentace.md` — single entry-point (principle, console, validation, audit, performance, best practices).
- `kArchiveManager-2.0-kompletni-dokumentace.md` — complete admin reference.
- Architecture & operations: `v2-universal-architecture.md`, `v2-operational-modes.md`, `v2-performance-best-practices.md`, `rf-log2-run-optimization.md`, `runtime-execution-paths.md`.
- Audit & governance: `audit-model.md`, `governance-model.md`, `production-timezone-cutoff-policy.md`.
- Release & compatibility: `RELEASE-NOTES-v2.0.md`, `CHANGELOG.md`, `COMPATIBILITY-MATRIX.md`, `legacy-consolidation.md`, `release-conditions-status.md` (R-03…R-07 status).
- Performance & lock-safety: `v2-performance-benchmark.md` + `perf-locksafety-checklist.md` (candidate selection takes **no source locks**; cheap-mode tuning, no source indexes).
- **Manuals** (`03-docs/manuals/`): User manual (Dashboard, free) + Admin manual (Configuration, after login) — also downloadable in the console.

## Manual tests (`01-database/performance-tests/`)
The R-03 benchmark harness (`r03_benchmark_harness.sql` + runners) measures a run's full metrics
(log MB, tempdb, logical reads, deadlocks, **source lock escalation**) against acceptance criteria —
use it to certify performance + lock-safety at customer scale. Methodology: `03-docs/v2-performance-benchmark.md`.

## Support training (`05-training/`)
`training-l1-l2-support.md` — a ready-to-present L1/L2 support training template (tool overview,
Admin Console tour, common tasks, error-code first response, escalation). Fill in the "key facts" before delivery.

---

*Build: clean deploy verified PASS · 5M-row audited run reconciled (Divergence=0) · candidate selection lock-free (proven) · 51/51 unit tests pass.*
