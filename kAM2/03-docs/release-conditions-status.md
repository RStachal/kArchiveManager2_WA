# Release conditions R-03…R-07 — status

**Date:** 2026-06-19. Tracks the "READY WITH CONDITIONS" items from the release-readiness audit.
Each condition is marked **Verified-here** (proven on the dev/test instance), **Customer-action**
(can only be completed in the customer environment), or **Partial**.

Legend: ✅ verified-here · 🔵 customer-action (mechanism proven, runbook below) · 🟡 partial.

---

## R-03 — Performance benchmark ✅ Verified-here
- Harness `tools/r03_benchmark/` + `docs/v2-performance-benchmark.md`; measured Edge.RF_LOG2 5M and
  full 14-mapping sweep with correct attribution.
- **Lock-safety (customer-critical):** candidate selection takes **0 source data locks** (NOLOCK,
  proven by lock probe — only `Sch-S`); all variants 0 escalation / 0 deadlocks / Divergence=0.
- **Speed:** cheap-mode + dedup-skip → ~29 min/5M lock-free (beats the unsafe 30 min baseline).
  See `docs/perf-locksafety-checklist.md`.

## R-04 — Edition / recovery model / Always-On 🟡 Partial (Standard+recovery verified; AG = customer-certify)
- **Edition (Standard):** ✅ **No Enterprise-only feature is used** anywhere in the shipped bundle,
  v2 procs, tables, frontend, or Admin Console — static audit found **0** of: partitioning,
  `ONLINE=ON` index ops, `DATA_COMPRESSION`, columnstore, in-memory OLTP, Resource Governor, CDC,
  Change Tracking, FILESTREAM; no `MAXDOP` hints; no Ledger in the clean bundle. The platform is
  **edition-agnostic → SQL Server Standard is supported.** (Dev/Developer edition is feature-identical
  to Enterprise, so the static absence of Enterprise features is the authoritative proof.)
- **Recovery model:** ✅ The full sweep ran against **SIMPLE-recovery** sources (KMWE_Test, KMWEBV)
  **and FULL** sources (Edge, AAD) with the **FULL** archive DB — all `Divergence=0`. Mixed
  source recovery models are exercised. Source-log volume on FULL sources is real (≈14 GB/5M) →
  ensure source log backups keep up (customer DBA).
- **Always-On AG:** 🔵 not tested (no AG here). Certification steps:
  1. SQL Agent runner jobs exist on every replica but must execute only where the relevant DBs are
     **primary** (guard the step with `sys.fn_hadr_is_primary_replica` or run via the AG-aware agent).
  2. Cross-DB source→archive: both must be writable/readable on the active node (same AG, or archive
     outside AG but reachable). 3. Archive DB log backups via the AG backup-preference. 4. Mid-run
     failover: `usp_RecoverStaleRuns` liveness reads node-local sessions — re-validate after failover.

## R-05 — Dedicated non-sysadmin runner login 🔵 Customer-action (mechanism ✅ proven)
- ✅ The least-privilege runner model is built and proven: role `karch_runtime` (055) + cross-DB
  per-table SELECT/DELETE + archive INSERT/SELECT/ALTER (no DELETE) via **053**, job re-ownership via
  **054**, and the run-start gate `usp_VerifyRunnerPrivileges` **rejects sysadmin** (THROW 51001).
  Applied + verified this session (`KODYS\RADIM-STACHAL$` runner, `usp_VerifyRunnerPrivileges` = OK,
  PREP/RUN jobs run under it).
- 🔵 Customer step: create a **dedicated** `DOMAIN\svc-karchive` (not the app-pool account) and run
  053 (`@LoginType='WINDOWS'`, `@Apply=1`) + 054 (`@JobNameLike='kArchiveManager - %CONFIGURED'`).
  **Re-run after any source/archive DB restore** (restore wipes the grants).

## R-06 — v1.0 → 2.0 upgrade dry-run 🔵 Customer-action (path ✅ audited)
- ✅ Upgrade path audited: `deploy/v2/01_upgrade_existing_1_0_to_2_0.sql` applies
  `032_archive_legacy_procedures.sql` which **transfers every v1 procedure out of `arch` into the
  `legacy_v1` schema** (so `arch.usp_Run*` callers fail), and the legacy proc **source files are now
  THROW-stubs** (R-01). Net: post-upgrade the legacy surface is neutralized two ways.
- 🔵 Customer step: restore a copy of the customer's **v1.0** instance, run `01_upgrade…`, then confirm:
  legacy procs are in `legacy_v1` / throw, the v2 object set verifies, and a dry-run produces candidates.

## R-07 — Elevated tier / SoD 🔵 Customer-action (mechanism ✅ present + ✅ unit-tested)
- ✅ The elevated tier exists: restore-from-archive (production-mutating) is gated on **`IsElevated`**
  (`EditSecurity` + `AdminConsoleEndpoints` + `ConfigWriteRequests`); elevation comes from
  `AdminConsole:ElevatedAdminUsers` (Windows allowlist) or `arch.ConsoleOperator.IsElevated`; the
  shared password is never elevated.
- ✅ **Test coverage added** (`EditSecurityTests`, 51/51 pass): back-compat (no tier → authorized==elevated);
  elevated operator IS elevated while a plain operator is NOT; shared password never elevated once a tier
  is configured; Windows user on the elevated allowlist is elevated, others authorized-but-not-elevated;
  unauthorized request is never elevated.
- 🔵 Customer step: populate `ElevatedAdminUsers` / set operator `IsElevated` so restore requires an
  elevated identity (otherwise back-compat = any unlocked editor). Consider AD-group tiers for SoD.

---

## Summary for go-live
- **Verified here:** R-03 (perf + lock-safety), R-04 edition (Standard-compatible) + recovery (SIMPLE+FULL),
  and the **mechanisms** for R-05/R-06/R-07.
- **Remaining = customer-environment certification** (cannot be done on the dev instance): Always-On AG
  (R-04), dedicated svc runner login (R-05), v1→v2 upgrade dry-run on a v1 copy (R-06), elevated-tier
  config (R-07). Each has a concrete runbook above.
- No remaining item is a **data-safety** risk; all are environment/topology certifications.
