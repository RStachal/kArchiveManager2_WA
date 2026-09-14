# Changelog — kArchiveManager

All notable changes to kArchiveManager are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and the project uses
[Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

Components covered: the SQL platform (`kArchiveManagerAdmin` + `kArchiveManagerBackups`) and the
Admin Console (.NET 9 API + React SPA). See `docs/COMPATIBILITY-MATRIX.md` for supported platforms.

---

## [Unreleased] — release-readiness hygiene

### Changed
- **Legacy v1.0 source consolidation (blocker R-01).** All 13 dormant v1.0 archive/delete/prepare/
  estimate procedures in `kArchiveManagerAdmin/procedures/` are reduced to inert `THROW … 'LEGACY
  BLOCKED …'` tombstones (errors 50004–50006, 50020–50029). The original bodies remain in git
  history. The shipped clean bundle never created them; this removes the live v1.0 logic from the
  source tree as well. See `docs/legacy-consolidation.md`.
- **Deploy-bundle drift correction.** Regenerated `deploy/v2/classic-ssms/*` and
  `deploy/v2/grouped-ssms/*` from current sources (via `tools/generate_classic_v2_scripts.py` and
  `tools/generate_grouped_v2_deploy.py`), bringing the inlined bundles in line with the v2.0
  feature set (cheap-mode `CandidateSelectExpr`, Mode=2 copy-only, optimistic-concurrency columns)
  and removing the last inlined v1.0 bodies.

### Added
- `CHANGELOG.md`, `docs/COMPATIBILITY-MATRIX.md`, `deploy/v2/release-package/RELEASE-NOTES-v2.0.md`,
  `docs/legacy-consolidation.md` (blocker R-02 — release artifacts).
- **`docs/manual-agent-replacement-runbook.md`** (2026-07-14) — verified 1:1 manual replacement of
  the PREP/RUN Agent jobs (`EXECUTE AS` the least-privilege runner; the T-33 gate rejects direct
  sysadmin runs by design), plus field troubleshooting for "Agent installed but not dispatching"
  (wiped `ODBCINST.INI` driver registration — machine-wide root cause; Browser/protocols/Agent XPs/
  mixed-mode checklist). Shipped in `04-runbooks`.
- `docs/archive-performance-tuning.md` §5–§6 (2026-07-14) — Mode=0 (delete-only) operational
  notes (50112 guard, `AllowDeleteWithoutArchive`, irreversibility) and the measured 1M-row
  benchmark incl. the per-invocation keyset cap (`min(MaxBatchesPerRun,100) × BatchRowCount`,
  400k with shipped defaults).

---

## [2.0.0] — 2026-06 (release candidate)

Major release: a single, consolidated, auditable archive/delete platform plus a web Admin Console.
Replaces the v1.0 WMS-hardcoded procedures with a configuration-driven, mapping-aware engine.

### Added
- **Prepared-batch execution model.** Two strategies behind one entry point
  (`usp_RunProfile_Prepared` → `usp_RunConfiguredProcesses_Prepared`):
  - **ANCHOR** — two-phase: `usp_PrepareCandidates` builds a stable key set (`WorkBatch`/
    `WorkBatchKey`), then `usp_RunPreparedBatch(es_InWindow)` archives+deletes exactly those keys.
  - **TIMESTAMP** — single-phase keyset over the source PK.
- **Operational modes.** Mode 1 (archive+delete), Mode 0 (delete-only, requires explicit
  `AllowDeleteWithoutArchive`), Mode 2 (copy-only, idempotent backup, no delete).
- **Two-phase scheduling.** `@Phase` parameter (`BOTH`/`PREP`/`RUN`) and a dedicated **PREP
  CONFIGURED** SQL Agent job to front-load candidate preparation.
- **Cheap-mode candidate selection** for high-volume TIMESTAMP sources (100M+ rows):
  `ObjectSpec.CandidateSelectExpr` + `ProcessDatabase.CandidateWhereSql` give an index-ordered,
  sargable scan with no per-row `AT TIME ZONE`.
- **Admin Console** (.NET 9 + React): Runs, Document lookup, Configuration editors (Process,
  mapping, ObjectSpec, ProcessKey, IndexRequirement, RunProfile), Validation, Analysis & Estimates,
  Go-live, Dry-run / Explain plan, SQL Agent job enable/schedule control, DB-backed console
  operators, downloadable User & Admin manuals.
- **Estimates:** `usp_Api_EstimateNextRunImpact` — mapping-aware projection of the next batch's
  rows / payload / archive growth / log pressure / planned MB, per process and source DB.
- **Restore:** `usp_RestoreFromArchive` (row-level restore from archive to source, dry-run default)
  with `RestoreAudit` and a triple-gated purge.
- **Audit trail:** per-document `RunDocAudit` (key, created-at, deleted-at, archived flag) +
  `RunItemObject` counts + `Run`/`RunItem` (who/when/status), with configurable audit levels
  (NONE/BATCH/ROW).

### Security
- **RBAC** roles: `karch_viewer`, `karch_operator`, `karch_config_admin`, `karch_advanced_admin`,
  `karch_approver`, `karch_runtime`.
- **Runtime least-privilege (T-33):** jobs run under a non-sysadmin runner with `karch_runtime`;
  `usp_VerifyRunnerPrivileges` is a run-start gate that **rejects sysadmin** runners (THROW 51001).
- **Audit immutability (T-09):** DENY UPDATE/DELETE on audit tables.
- **Safe-expression gate (T-05):** all configurable SQL fragments validated by
  `usp_AssertSafeSqlExpression` (THROW 50400) on both save and run; dynamic SQL uses `QUOTENAME` /
  parameterized `sp_executesql`.
- **Timezone gate (50200)** and **retention floor (50210)** + **legal-hold** (T-21) guard every
  runner path. Concurrency via `sp_getapplock` (THROW 50116 / applock-release 50320) and a
  TIMESTAMP key-uniqueness gate (50115).
- Admin Console: optional Windows/AD authorization allowlist + shared-password fallback, elevated
  tier for restore, write rate-limiting, security headers / CSP, CSV formula-injection guard,
  readiness redaction for unauthenticated callers.

### Changed
- **Data-loss safety invariant:** all deletes are `DELETE … OUTPUT INTO archive` within one
  transaction, so for Mode 1 `archived == deleted` (`Divergence = 0`). No `TRUNCATE` in the runtime.
- Effective configuration resolved through `v_ProcessDatabaseEffective` /
  `v_ObjectSpecDatabaseEffective` (single source of truth; `deploy/v2/022` owns the view).

### Removed / retired
- v1.0 WMS-hardcoded run/prepare/estimate procedures (see **Unreleased** and
  `docs/legacy-consolidation.md`). They are not part of the clean install.

### Known limitations
- Audit immutability is access-control hardening, **not** cryptographic tamper-evidence; SQL Server
  2022 Ledger conversion of `RunDocAudit`/`ConfigChange*` is a planned follow-up.
- Formal performance benchmark at customer scale and a Standard-edition / recovery-model /
  Always-On compatibility pass are tracked as release conditions (see RELEASE-NOTES and
  `docs/COMPATIBILITY-MATRIX.md`).

---

## [1.0.0] — historical

WMS-specific archiving via hardcoded `usp_RunProcess*` / `usp_RunWorkBatch*` /
`usp_PrepWorkBatch_*` procedures. Superseded by 2.0.0.
