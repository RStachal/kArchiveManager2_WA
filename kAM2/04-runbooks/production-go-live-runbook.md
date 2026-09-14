# kArchiveManager 2.0 — Production go-live runbook

Ordered cutover steps to take the validated build into production. Do them **in order**; each is
green-before-next. Pairs with the [Go/No-Go checklist](production-go-no-go-checklist.md) (sign-offs)
and the [self-test runbook](../deploy/v2/test-plan/SELF-TEST-cs.md) (T01–T11 evidence).

> Golden rule: enable the real archiving job (`RUN CONFIGURED`) **last**, only after every step below
> is green and the Go/No-Go is signed. Until then keep it **disabled**.

## 0. Prerequisites (must be true)
- T01–T11 passed on a TEST copy of production (see SELF-TEST runbook); Go/No-Go A+B green.
- A **restore point / backup** of every source DB exists, and a **restore rehearsal** was done.
- DBA confirmed the source timezone assumption (`SourceTimezone` = local CET/CEST) for the cutoff.

## 1. Database currency
- Deploy the v2 bundle to the production `kArchiveManagerAdmin` (incl. `024` operational maintenance,
  `034` anchor TZ, `036` recovery job, `037` recommended indexes, `040` cancel support, `042` restore).
- Run `deploy/v2/test-plan/T00_db_currency_check.sql` → **all rows OK** (gate proc, gate wired, anchor
  UTC-normalized, recovery job, `v_OperationalHealth`).
- Run `deploy/v2/38_runtime_smoke_current_configuration.sql` → `FailedChecks=0` (run `37` indexes first).

## 2. Admin Console — connection + auth (production)
- **Connection string** → production `kArchiveManagerAdmin` (`appsettings.json` `ConnectionStrings:ArchiveManagerAdmin`
  or `ConnectionStrings__ArchiveManagerAdmin` env var). No `Server=.` placeholder.
- **Windows auth**: set `AdminConsole:WindowsAuthEnabled=true` and enable **IIS Windows Authentication**
  on the site (keep Anonymous only for the SPA static files if needed). This also auto-enables
  `RequireAuthenticatedApi` (S3) → anonymous `/api/*` is blocked. Fill `AdminConsole:AdminUsers` (DOMAIN\\user allowlist).
- **Operators** (if used) as **PBKDF2** hashes — generate with
  `dotnet run --project <ApiProject> -- hash-password "<password>"`; put the `PBKDF2-SHA256$…` value in
  `AdminConsole:Operators[].PasswordSha256`. **Remove the dev `op1`** test operator.
- `/api/security/unlock` is rate-limited (S1, 5/5 min per IP); confirm reverse-proxy passes the real client IP.

## 3. SQL Agent jobs
- Set the **SQL Server Agent** service to **Automatic** start (not Manual).
- **Recovery job** (`036`): present + **enabled**, schedule every 15 min (verify via `T02`).
- **RUN CONFIGURED**: deploy `kArchiveManagerAdmin/v2/SQL job - RUN CONFIGURED.sql` (creates it **disabled**),
  steps VALIDATE CONFIGURATION → `usp_RunProfile_Prepared @RunProfileCode='JOB_DEFAULT'`. Set the real
  schedule (e.g. nightly window). **Leave disabled until step 6.**
- **Failure alerts (O2)**: configure Database Mail + an operator, then add notification to both jobs
  (`sp_update_job @notify_level_email=2, @notify_email_operator_name='<op>'`) so a FAILED run pages someone.

## 4. Backups & retention
- Source DBs: scheduled **FULL + log** backups; verify a restore works (rehearsal).
- Plan `usp_PurgeRunHistory`-style retention for `Run/RunItem/RunDocAudit` (audit grows with ROW audit).

## 5. Post-deploy verification (no real deletes yet)
- `/api/readiness` → `databaseOk:true`, `missingObjects/Roles/Permissions = []`.
- Smoke 31 (timezone policy) → 0 ERROR; T05 gate → THROW 50200 on a raw cutoff.
- Open the console (Windows-authed); confirm reads work, a listed user can edit, a non-listed user cannot.

## 6. Go (enable real archiving)
- Sign the Go/No-Go.
- Enable `RUN CONFIGURED`: `EXEC msdb.dbo.sp_update_job @job_name=N'kArchiveManager - RUN CONFIGURED', @enabled=1;`
- Watch the first few runs in the console **Runs** (Status/Finished/Duration) + run the health pack
  (`health/02,04,05`) and `T10_reconciliation.sql` (`RowsArchived = RowsDeleted`, Divergence 0, no FAIL).
- If a run over-archives: **Stop run** (graceful) from Runs, then **Restore from archive** (`042`) to
  bring rows back; adjust retention/cutoff before re-enabling.

## 7. Known limitations to communicate
- **Large-table run duration (F4/C3):** sources storing timestamps as non-sortable text (e.g. RF_LOG2
  `DATE_TIME`) or via COALESCE/parse cannot use an index seek for the cutoff → the candidate scan is
  inherent. A persisted computed `datetime2` column + index on the source (customer schema change) is
  the only real speed-up. Don't mistake long durations for a bug.
- **S4 (open):** the API still runs under one DB login holding all roles — split into least-privilege
  read vs write logins before exposing beyond trusted admins.
