# kArchiveManager 2.0 — Operator Runbook

All object names below are the **canonical clean-deploy** objects (see `release-manifest.md`).

## Normal operation
1. Review `arch.v_OperationalHealth` — 0 rows with `Severity = 'ERROR'` = OK.
2. Review recent runs: `SELECT TOP (50) * FROM arch.v_RunItemsRecent ORDER BY RunItemId DESC;`.
3. Run processes through SQL Agent **run profiles** (`usp_RunProfile_Prepared` → `usp_RunConfiguredProcesses_Prepared`) or guarded ad-hoc calls (`example-process-calls.sql`).
4. After each pilot/release, run `arch.usp_Frontend_GoLiveReadiness` (or Console → **Go-live**) and confirm **0 FAIL**.

## Dry-run → real-run
1. **Dry-run:** `usp_RunConfiguredProcesses_Prepared @DryRun = 1` (ANCHOR) / `usp_RunTimestampProcess @DryRun = 1` (TIMESTAMP). Review candidate counts, cutoff, and key samples.
2. Confirm: source + archive **backups** exist, **archive tables** provisioned, **source indexes** present — a missing source index is a **WARN, never a blocker** (create it from Console → Validation → Indexes via the Suggested SQL).
3. **Real-run** with a low `@MaxCandidates` / `@MaxRows` pilot first; raise limits only after health shows no `ERROR`.
4. After each run check `arch.v_OperationalHealth`; for `ROW` audit verify the `arch.RunDocAudit` count matches the documents processed.

## High-volume backlog drain (optional perf)
Use `arch.usp_RunTimestampProcessParked` (`deploy/v2/052`) in a **maintenance window**: it parks (DISABLE)
the non-essential source nonclustered indexes, archives, then REBUILDs them — ~1.5× throughput on large
drains (measured: RF_LOG2 ~3.2k → ~5k rows/s). Always pass the candidate-selection index in
`@KeepIndexesCsv` so it is never parked. The proc needs `ALTER` on the source table (DBA/maintenance).

## Audit modes
- `ROW` — per-document evidence (`arch.RunDocAudit`); use for document processes / compliance.
- `BATCH` / `OBJECT` — run-level + per-object counts only.
- `NONE` — high-volume logs (e.g. RF_LOG2); the archived rows themselves are the evidence.
Operator-controlled per process/DB. See `docs/v2-operational-modes.md` and `docs/audit-model.md` for exact guarantees.

## Stop / recover / restore
1. **Stop a running run:** find it (`SELECT RunId, Status FROM arch.Run WHERE Status = 'RUNNING';`), then `EXEC arch.usp_Api_RequestRunStop @RunId = …, @RequestedBy = …;` (cooperative — the runner stops at the next batch boundary).
2. **Recover stale/orphaned runs:** `EXEC arch.usp_RecoverStaleRuns @StaleAfterMinutes = 60, @DryRun = 1;` (preview), then `@DryRun = 0`. Schedule this as a SQL Agent job so orphaned `RUNNING` runs self-heal.
3. **Restore (un-archive):** `EXEC arch.usp_RestoreFromArchive @DryRun = 1;` first. `@PurgeArchive = 1` is DBA-only and guarded (THROW 50404/50405); every restore/purge is logged to `arch.RestoreAudit`.

## Incident flow
1. Disable the relevant SQL Agent job.
2. `SELECT * FROM arch.v_OperationalHealth WHERE Severity = 'ERROR';`.
3. Investigate FAILED runs via `arch.v_RunItemsRecent` and `arch.RunItem.ErrorMessage`.
4. If a `RUNNING` run is orphaned (no worker session — `arch.Run.WorkerSessionId`), recover it (above).
5. Re-run `arch.usp_Frontend_GoLiveReadiness` and a dry-run before resuming real runs.

## Evidence to keep
RunId / RunItemId · ProcessCode / SourceDb / ArchiveDb · CutoffUtc + run start/end · `arch.RunItemObject` row counts · `arch.RunDocAudit` (ROW processes) · `arch.RestoreAudit` (restore/purge) · `arch.v_OperationalHealth` output after the run.
