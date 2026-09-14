# Production Readiness Checklist

Use this checklist before the first production real-run and before every major
release rollout.

## v2 hardened clean deploy — canonical (do this for a fresh customer install)

- [ ] Ran `release-package/deploy_clean_v2_full.sql` (SQLCMD mode, `:setvar Root` set) — 0 errors.
- [ ] `release-package/verify_clean_deploy.sql` returned **PASS** (all expected objects; no v1/relics/smoke).
- [ ] `release-package/selftest_acceptance.sql` passed (archive/delete/restore/audit/TZ-gate smoke, self-cleaned).
- [ ] Archive DB `kArchiveManagerBackups` is in **FULL recovery** (set by `create_kArchiveManagerBackups.sql`; confirm `recovery_model_desc='FULL'`).
- [ ] Ran `deploy/v2/047_operational_alerting.sql` with real SMTP + operator e-mail; **received a test alert e-mail**.
- [ ] Ran `deploy/v2/048_archive_db_backup.sql` with a real `@BackupRoot`; FULL+LOG jobs present; **restore rehearsal passed**.
- [ ] Admin Console auth configured: at least one of `AdminConsole:AdminUsers` / `Operators` / `EditPasswordSha256`,
      with `RequireAuthenticatedApi=true` + `WindowsAuthEnabled=true` and `ASPNETCORE_ENVIRONMENT=Production` on the IIS host.
- [ ] DB-specific **SEED applied** (customer source-DB names + archive DB; Process / ProcessDatabase / ObjectSpec /
      ProcessKeySpec / IndexRequirement / RunProfile + `AT TIME ZONE` cutoff expressions) — the clean bundle ships
      objects only, **no runnable processes**.
- [ ] **Console read grants applied** — ran `deploy/v2/051_grant_console_read_source_dbs.sql` so the app-pool login has
      `db_datareader` in every enabled SOURCE database + the archive DB (otherwise the dashboard returns 503 / masked
      Msg 916 on cross-DB row counts). The real archive+delete still runs under the SQL Agent job identity, not the pool.
- [ ] `arch.usp_Frontend_GoLiveReadiness` (Admin Console → **Go-live**) shows **0 FAIL**.

> The numbered-script items in the sections below (`16`/`17`/`29`/`30`/`32`/`33`, `smoke-tests/`, `health/`) belong to
> the older pre-hardening deploy path and are **superseded for a clean install** by the canonical bundle above.

## Environment

- [ ] Admin DB backup completed.
- [ ] Archive DB backup completed.
- [ ] Source DB backup or restore point completed.
- [ ] SQL Agent job ownership reviewed.
- [ ] Maintenance window approved.
- [ ] Rollback/recovery owner assigned.

## Deployment

- [ ] Correct path selected: clean deploy or 1.0 upgrade.
- [ ] SQLCMD variables reviewed.
- [ ] Deployment completed without scripting errors.
- [ ] `16_update_audit_reporting.sql` applied.
- [ ] `17_update_operational_maintenance.sql` applied.
- [ ] `29_update_frontend_security_roles.sql` applied.
- [ ] `30_frontend_api_readiness_check.sql` applied.
- [ ] `32_update_frontend_iis_principal_permissions.sql` applied for IIS app pool identity.
- [ ] `33_update_frontend_concurrency_metadata.sql` applied.
- [ ] Recovery scripts reviewed in preview mode.

## Configuration

- [ ] Enabled processes reviewed.
- [ ] SourceDb/ArchiveDb mappings reviewed.
- [ ] `ArchiveSchema = {SourceDb}` or approved equivalent confirmed.
- [ ] Retention/cutoff values approved per source database.
- [ ] AuditLevel selected per process and documented.
- [ ] `RF_LOG2` and high-volume integration processes reviewed for `NONE`
      audit unless per-key evidence is explicitly required.

## Source Indexes

- [ ] ANCHOR process source indexes reviewed.
- [ ] `RF_LOG2` index on `DATE_TIME, ROWID` confirmed or installed.
- [ ] `DNLOAD_ARCHIVE` index on `date_archived, ROWID` confirmed or installed.
- [ ] `UPLOADARCHIVE.KAM_TIMESTMP_DT` computed column confirmed or installed.
- [ ] `UPLOADARCHIVE` index on `KAM_TIMESTMP_DT, ROWID` confirmed or installed.
- [ ] Admin index requirements updated with
      `19_update_timestamp_index_requirements.sql` if computed upload index is used.

## Archive Targets

- [ ] Archive database exists.
- [ ] Archive schemas exist for every enabled source database.
- [ ] Archive tables provisioned.
- [ ] Existing archive rows for pilot keys reviewed.
- [ ] Archive table permissions reviewed.

## Validation

- [ ] `deploy/v2/smoke-tests/00_smoke_metadata_and_config.sql` completed.
- [ ] `deploy/v2/smoke-tests/28_frontend_api_readiness_smoke.sql` completed.
- [ ] `deploy/v2/smoke-tests/30_frontend_iis_principal_permissions_smoke.sql` completed.
- [ ] Admin Console `/health` returns `OK`.
- [ ] Admin Console `/api/readiness` returns `apiOk=true` and `databaseOk=true`.
- [ ] Dry-run completed for target process/source database.
- [ ] Candidate keys reviewed for first pilot.
- [ ] Guarded low-limit real-run completed.
- [ ] Health pack completed with no `FAIL`.
- [ ] Repeated dry-run does not offer already archived/deleted keys.

## Go/No-Go

- [ ] Business owner approved candidate scope.
- [ ] DBA approved execution window and log capacity.
- [ ] Recovery plan reviewed.
- [ ] Next run limit documented.
- [ ] Operator recorded RunId/RunItemId and health output.
