# kArchiveManager 2.0 — Release Manifest

The authoritative customer deliverable. The clean install is the **bundle in this folder** plus
the **object scripts it `:r`-includes**, then the parameterized operational add-ons under
`deploy/v2/`. The legacy numbered `00`/`13`–`33` scripts are **not** the clean-customer path (see
`README.md` → "Existing-environment upgrade"); `00_deploy_2_0_clean.sql` fails
`verify_clean_deploy.sql`.

## Clean-deploy bundle (`release-package/`)
- `deploy_clean_v2_full.sql` — SQLCMD master (set `:setvar Root`).
- `deploy_clean_v2_full_SSMS.sql` — classic, no-SQLCMD equivalent (every `:r` inlined).
- `verify_clean_deploy.sql` — post-deploy object-set assertion (expect **PASS**).
- `selftest_acceptance.sql` — turnkey behavioral smoke (archive/delete/restore/audit/TZ-gate, self-cleans).
- `variant_test_pack.sql` — manual variant test pack: ANCHOR/TIMESTAMP × Mode 0/1/2, DryRun, AuditLevel NONE/BATCH/ROW, retention-floor gate (50210), legal-hold, TZ gate (50200), restore round-trip, stop-audit. Fully self-contained on a throwaway schema; expect **ALL VARIANTS PASSED**.
- `example-process-calls.sql`, `example-process-calls-RSTSQL2022.sql` — ad-hoc call examples (template + concrete).
- `deploy/v2/seed_tested_processes.sql` — reference/template seed of the tested processes (adapt to customer DB names; adjacent, not in this folder).

## Object scripts the master includes (`kArchiveManagerAdmin/` + `Databases/`)
- **Databases:** `create_kArchiveManagerAdmin.sql`, `create_kArchiveManagerBackups.sql` (archive in **FULL recovery**).
- **Tables:** `Tables/arch.*.sql` — base config + run + audit tables.
- **Core/metadata:** `v2/010` core metadata; `v2/022/023/024` effective views + monitoring + `v_OperationalHealth`.
- **Runner:** `v2/014` PrepareCandidates · `015` RunPreparedBatch · `027` RunTimestampProcess (T-22 collation + T-04 divergence guard) · `016` RunPreparedBatches + RunConfiguredProcesses_Prepared · `020` RunProfile_Prepared · `030` RecoverStaleRuns.
- **Gates/helpers:** `035` TZ gate (THROW 50200) · `046` safe-expression validator (T-05, THROW 50400) · `011` ValidateIndexRequirements (missing index = WARN + SuggestedSql) · `012` ExplainProcessPlan · `procedures/` GetOutputColumns, EnsureArchiveTableLikeSource (T-19 drift compare), ProvisionArchiveTablesForProcess, ValidateConfiguration (+ SuggestedSql).
- **Runtime hardening:** `040` run cancel/stop · `042` restore + `RestoreAudit` + purge guard (T-27, THROW 50404/50405) · `044` run liveness (T-03) · `045` audit immutability DENY (T-09).
- **Admin Console API:** `frontend/001`–`009` (read/lookup/validation/config-write incl. 4-eyes T-06 56310-56313 + audit-level T-08) · `frontend/010` `karch_*` role model + grants.
- **Readiness/visibility:** `v2/049` go-live readiness · `v2/050` timestamp retention gaps (T-20).
- **Runtime least-privilege (T-33):** `v2/055` role `karch_runtime` (EXECUTE on the runner chain + `VIEW DEFINITION ON SCHEMA::arch`) + `usp_VerifyRunnerPrivileges` (run-start gate, wired into the RUN CONFIGURED VALIDATE step) + `usp_CaptureRunnerPrivilegeInventory` + `arch.RunnerPrivilegeInventory`.
- **Retention floor + legal-hold (T-21):** `v2/056` `arch.RetentionPolicy` + `usp_AssertRetentionFloor` (THROW 50210 gate in 014/015/027) + `arch.LegalHold` (candidate exclusion in 014/027, claim-time park in 015) + management API (`usp_Api_SetRetentionFloor`/`AddLegalHold`/`ReleaseLegalHold`/`usp_Frontend_GetLegalHolds`).
- **Copy-only mode (Mode=2):** `v2/057` widens the Mode CHECK to {0,1,2} + `usp_GetCopyDedupInfo` (source-PK dedup predicate + archive dedup index). Runners 015/027 gain a copy-only branch (`INSERT…SELECT…NOT EXISTS`, no delete, idempotent backup); `usp_GetOutputColumns` gains a source-aliased select list.
- **Indexes:** `indexes/Indexes.sql` (admin DB).

## Parameterized operational add-ons (`deploy/v2/`, run after the bundle)
- `051_grant_console_read_source_dbs.sql` — app-pool read on source/archive DBs (**required** for dashboard).
- `047_operational_alerting.sql` — Database Mail + failure alerting.
- `048_archive_db_backup.sql` — archive-DB FULL+LOG backup jobs.
- `052_archive_with_index_parking.sql` — optional high-volume perf helper (`usp_RunTimestampProcessParked`).
- `053_runtime_least_privilege_principal.sql` — create the dedicated non-sysadmin runner login + cross-DB least-priv grants (T-33).
- `054_runner_job_least_privilege.sql` — re-own the RUN CONFIGURED Agent job to the runner login (T-33).
- `043_remove_overprivileged_principals.sql` — existing-env T-01 remediation (a clean install has no orphan).

## Documentation
- `docs/kArchiveManager-geneze-dokumentace.md` — ⭐ single entry-point (principle, console, validation, audit, perf, best practices).
- `docs/v2-operational-modes.md`, `docs/v2-performance-best-practices.md`, `docs/audit-model.md`, `docs/governance-model.md`.
- `docs/admin-console-customer-deploy-runbook.md`, `docs/admin-console-iis-deployment.md`, `docs/production-go-live-runbook.md`, `docs/production-go-no-go-checklist.md`.
- `release-package/README.md`, `operator-runbook.md`, `production-readiness-checklist.md`.

### Release artifacts (v2.0)
- `release-package/RELEASE-NOTES-v2.0.md` — what's in 2.0, install/upgrade, known limitations + release conditions (R-03…R-06).
- `docs/v2-performance-benchmark.md` + `tools/r03_benchmark/` — R-03 performance-benchmark harness (full metrics: log MB/run, tempdb, logical reads, deadlocks, lock escalation) + acceptance criteria + operator runbook + sign-off.
- `CHANGELOG.md` (product root) — versioned change history (Keep a Changelog / SemVer).
- `docs/COMPATIBILITY-MATRIX.md` — supported SQL Server versions/editions, recovery models, HA, OS, .NET, browsers (Tested / Supported / Verify-before-prod).
- `docs/legacy-consolidation.md` — decision record: the v1.0 surface is retired/tombstoned; v2.0 prepared-batch is the sole active mechanism (blocker R-01).

## Release verification (before tagging)
- `deploy_clean_v2_full.sql` (or `_SSMS`) on a fresh DB → **0 errors**; `verify_clean_deploy.sql` = **PASS**; `selftest_acceptance.sql` = **PASS**; `variant_test_pack.sql` = **ALL VARIANTS PASSED**.
- `git diff --check`.
- No script defaults to destructive behavior without an explicit flag (root operator-tools are guarded; `043` is `@IConfirm='NO'` by default).
- Phase-14 SQL Agent jobs (`047`/`048`/RECOVER STALE RUNS) validated on an Agent-enabled instance.
