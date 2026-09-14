# Release Notes — kArchiveManager 2.0.0

**Release date:** 2026-06 (release candidate) · **Audience:** DBAs, operators, integrators
See `../../../CHANGELOG.md` for the full change list and `../../../docs/COMPATIBILITY-MATRIX.md` for
supported platforms.

---

## What this release is

kArchiveManager 2.0 is a configuration-driven, mapping-aware **archive-and-delete platform** for
SQL Server, plus a web **Admin Console**. It replaces the v1.0 WMS-hardcoded procedures with a
single, auditable engine that guarantees — for archive+delete (Mode 1) — that every deleted row was
first captured in the archive (`archived == deleted`, `Divergence = 0`).

## Highlights

- **One consolidated runtime mechanism** (prepared-batch model); the v1.0 procedures are retired and
  not shipped — see `../../../docs/legacy-consolidation.md`.
- **Two strategies, one entry point:** ANCHOR (two-phase) and TIMESTAMP (keyset), with operational
  modes archive+delete / delete-only / copy-only.
- **Atomic archive-then-delete** via `DELETE … OUTPUT INTO archive`; no `TRUNCATE` in the runtime.
- **Cheap-mode** candidate selection for 100M-row sources (index-ordered, sargable, no per-row
  `AT TIME ZONE`).
- **Full audit trail** (per-document `RunDocAudit`, `RunItemObject` counts, run telemetry) with
  configurable audit levels and DENY-based immutability.
- **Admin Console** for configuration, dry-run/explain, estimates, runs, restore, validation,
  go-live checks, and SQL Agent job control — with RBAC and 4-eyes change control.
- **Defense-in-depth gates:** timezone (50200), retention floor + legal-hold (50210), safe-expression
  (50400), concurrency (50116/50320), key uniqueness (50115), runner least-privilege (51001).

## Install / upgrade

- **Clean install (recommended):** run `deploy_clean_v2_full.sql` (SQLCMD mode) or
  `deploy_clean_v2_full_SSMS.sql` (no SQLCMD), set `:setvar Root`. Then run `verify_clean_deploy.sql`
  (expect **PASS**) and `variant_test_pack.sql` (expect **ALL VARIANTS PASSED**).
- **Existing v1.0 environment:** see `README.md` → "Existing-environment upgrade"
  (`deploy/v2/01_upgrade_existing_1_0_to_2_0.sql`). Do **not** use `00_deploy_2_0_clean.sql` for a
  clean install — it intentionally fails `verify_clean_deploy.sql`.
- **Admin Console:** see `../../../docs/admin-console-iis-deployment.md`.
- Apply the parameterized operational add-ons under `deploy/v2/` (runner least-privilege 053/054,
  job-control grants 059) per the customer environment.

## Upgrade notes (from 1.0)

- The v1.0 run/prepare/estimate procedures are retired. On upgrade they are blocked
  (`THROW 'LEGACY BLOCKED …'`) and moved to the `legacy_v1` schema; any external scheduler/script
  that called them directly must be repointed to `usp_RunProfile_Prepared` / the SQL Agent jobs.
- Audit and configuration tables are additive; no destructive schema change to existing data.

## Known limitations / release conditions

This release candidate is **functionally complete and data-safe**. Before declaring a specific
customer environment production-certified, clear these conditions (none is a data-loss risk).
**Status of each is tracked in `../../../docs/release-conditions-status.md`** (R-03 verified;
R-04 edition+recovery verified, AG = customer-certify; R-05/R-06/R-07 mechanisms verified, customer deploy/config remains).

| ID | Condition | Status |
|---|---|---|
| R-03 | Performance benchmark (+ lock-safety) at customer scale, with acceptance criteria. | ✅ verified-here (harness + cheap-mode + NOLOCK) |
| R-04 | Certify on edition / recovery model / HA (Standard, SIMPLE/FULL, Always On). | 🟡 Standard+recovery verified; AG = customer-certify |
| R-05 | Run SQL Agent jobs under a **dedicated non-sysadmin** service account. | 🔵 mechanism (053/054) proven; customer svc account |
| R-06 | Dry-run the v1.0 → 2.0 upgrade on a v1 copy. | 🔵 upgrade path audited; customer dry-run |
| R-07 | Configure the Admin Console elevated tier for restore. | 🔵 mechanism present; customer config |

Other known limitations: audit immutability is access-control hardening, not cryptographic
tamper-evidence (SQL 2022 Ledger conversion is a planned follow-up).

## Support artifacts in this package

`README.md`, `release-manifest.md`, `HANDOVER-README.md`, `operator-runbook.md`,
`production-readiness-checklist.md`, `verify_clean_deploy.sql`, `selftest_acceptance.sql`,
`variant_test_pack.sql`, `example-process-calls*.sql`.
