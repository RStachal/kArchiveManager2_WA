# kArchiveManager 2.0 operational modes

This document defines the operational modes that matter during approval,
production operation, incident review, and audit.

There are two independent controls:

- run mode: `@DryRun = 1` versus real archive/delete execution
- audit level: `AuditLevel = NONE`, `BATCH`, `OBJECT`, or `ROW`

`@DryRun` controls whether source/archive data is changed. `AuditLevel`
controls how much evidence is written for a real run.

## Summary

| Mode | Use when | Writes source/archive data | Writes per-key audit | Main evidence |
| --- | --- | --- | --- | --- |
| `DRYRUN` | Preview before a real run | No | No | Candidate preview, `Run`/`RunItem` with `DRYRUN` status |
| `ROW` audit | You need proof for each archived/deleted document/key | Yes | Yes | `Run`, `RunItem`, `RunItemObject`, `RunDocAudit` |
| `NONE` audit | High-volume cleanup where per-key evidence is not required | Yes | No | `Run`, `RunItem`, `RunItemObject`, archive table rows |
| `BATCH` audit | Summary-level evidence is enough | Yes | No, in current implementation | `Run`, `RunItem`, `RunItemObject` |

`OBJECT` is accepted by metadata constraints for compatibility, but current
runtime behavior should be treated as summary-level evidence, like `BATCH`,
unless a future implementation explicitly adds object-level audit rows.

## DRYRUN

`DRYRUN` is selected by procedure parameter, for example:

```sql
EXEC arch.usp_RunConfiguredProcesses_Prepared
    @ProcessCode = N'SHIPPING',
    @SourceDb = N'Edge',
    @ArchiveDb = N'kArchiveManagerBackups',
    @StopAtUtc = @StopAtUtc,
    @DryRun = 1,
    @MaxCandidates = 100;
```

### Guarantees

- Does not delete source rows.
- Does not insert rows into archive tables.
- Uses the same configured process/source/archive mapping as real execution.
- For `ANCHOR` prepared-batch processes, materializes preview keys in
  `arch.WorkBatch` and `arch.WorkBatchKey`.
- For `TIMESTAMP` keyset processes, executes the timestamp candidate query in
  preview mode and records a `DRYRUN` `Run`/`RunItem`.
- Reports candidate counts and cutoff values so the operator can review scope.

### Does not guarantee

- It does not prove that a later real run will see exactly the same candidates;
  source data can change between preview and execution.
- It does not prove that archive inserts and source deletes will succeed.
  Permission, constraint, schema, lock, and deadlock failures can still happen
  during the real run.
- It does not write `RunDocAudit`, because no row was actually archived/deleted.
- For high-volume `TIMESTAMP` processes, it does not persist every preview key
  in `arch.WorkBatchKey`.

### Required operator action

- Review candidate counts and cutoff dates.
- For pilot runs, review specific keys before real execution.
- Close preview-only `WorkBatch` rows after review with:

```sql
EXEC arch.usp_CloseDryRunWorkBatches
    @ApplyChanges = 1;
```

## ROW audit

`ROW` audit is configured through `arch.Process.AuditLevel` or, preferably for
database-specific behavior, `arch.ProcessDatabase.AuditLevel`.

```sql
UPDATE pd
SET AuditLevel = N'ROW'
FROM arch.ProcessDatabase pd
JOIN arch.Process p
  ON p.ProcessId = pd.ProcessId
WHERE p.ProcessCode = N'SHIPPING'
  AND pd.SourceDb = N'KMWEBV'
  AND pd.ArchiveDb = N'kArchiveManagerBackups';
```

### Guarantees

- Writes one `arch.RunDocAudit` row per processed document/key.
- Links each audited key to `RunItemId`.
- `RunItemId` links to `arch.RunItem`, and `RunItem.RunId` links to
  `arch.Run`, where `SourceDb` and `ArchiveDb` are stored.
- `arch.v_RunDocAuditDetailed` exposes the full trace:
  key, process, source database, archive database, cutoff, status, and counts.
- Supports post-run evidence that:
  - the key was processed,
  - source rows for that key are gone,
  - archive rows for that key exist,
  - the key is not offered again by a repeated dry-run.

### Does not guarantee

- It does not automatically prove business correctness of the cutoff rule.
  The cutoff expression and retention policy still must be reviewed.
- It does not store a full copy of every source row in Admin DB. Row contents
  live in the archive database tables.
- It increases Admin DB write volume and storage usage.
- For very large runs, it can become the bottleneck because every processed key
  writes an audit row.

### Recommended use

- Use for document-oriented processes such as `SHIPPING` and `RECEIVING`.
- Use for integration tables when customer or compliance requirements require
  per-key traceability.
- Avoid for very high-volume log cleanup unless per-key proof is mandatory.

## NONE audit

`NONE` audit disables per-key audit rows.

```sql
UPDATE pd
SET AuditLevel = N'NONE'
FROM arch.ProcessDatabase pd
JOIN arch.Process p
  ON p.ProcessId = pd.ProcessId
WHERE p.ProcessCode = N'RF_LOG2'
  AND pd.ArchiveDb = N'kArchiveManagerBackups';
```

### Guarantees

- Real runs still write `arch.Run`, `arch.RunItem`, and `arch.RunItemObject`.
- `RowsDeleted`, `RowsArchived`, `DocsDone`, `BatchesDone`, status, cutoff, and
  error messages are still recorded.
- Archive tables still contain the archived data when `Mode = 1`.
- Source rows are deleted only after successful archive insert in the same
  transaction scope.
- Best performance profile for high-volume timestamp cleanup.

### Does not guarantee

- No per-key evidence is written to `arch.RunDocAudit`.
- Admin DB alone cannot answer "was this exact key processed?" unless the key
  can be inferred from archive rows or external logs.
- Repeated dry-run overlap checks must compare against archive/source data, not
  `RunDocAudit`.
- It is not suitable when auditors require a per-document/key ledger in Admin DB.

### Recommended use

- Use for high-volume technical logs such as `RF_LOG2`.
- Use when archive tables are the authoritative evidence and per-key Admin DB
  audit is not required.
- Use for performance and storage-sensitive production runs after pilot tests
  have proven the process.

## BATCH audit

`BATCH` audit is summary-level evidence. In the current implementation it does
not write `RunDocAudit`; it relies on run and object-level counters.

### Guarantees

- Writes `arch.Run` and `arch.RunItem`.
- Writes `arch.RunItemObject` counts per configured source table.
- Records status, cutoff, mode, batch count, document count, rows deleted, rows
  archived, start/end time, and error message.
- Lower overhead than `ROW` audit.

### Does not guarantee

- Does not provide one Admin DB audit row per processed key in the current
  runtime.
- Does not prove exact key-level membership without checking archive/source
  tables.
- For `TIMESTAMP` keyset processes, detailed `WorkBatchKey` staging is not used.

### Recommended use

- Use only when summary-level evidence is acceptable.
- Prefer `ROW` when per-key traceability is contractually required.
- Prefer `NONE` when high-volume performance matters and archive rows are enough
  evidence.

## Operational checks by mode

### After every real run

```sql
SELECT TOP (100) *
FROM arch.v_OperationalHealth
ORDER BY LastActivityAtUtc DESC;
```

Expected result for a clean system: no `ERROR` rows. `FAILED_RECENT` rows can be
acceptable after intentional negative tests, but should be explained.

### For ROW audit processes

```sql
SELECT
    ProcessCode,
    SourceDb,
    ArchiveDb,
    RunItemId,
    DocsDone,
    RowsDeleted,
    RowsArchived,
    AuditRows = COUNT_BIG(a.RunDocAuditId)
FROM arch.v_RunItemsRecent ri
LEFT JOIN arch.RunDocAudit a
  ON a.RunItemId = ri.RunItemId
WHERE ri.Status = N'OK'
  AND ri.DocsDone > 0
GROUP BY
    ProcessCode,
    SourceDb,
    ArchiveDb,
    RunItemId,
    DocsDone,
    RowsDeleted,
    RowsArchived
ORDER BY RunItemId DESC;
```

For `AuditLevel = ROW`, `AuditRows` should match `DocsDone`.

### For NONE/BATCH audit processes

Use `RunItemObject` and archive table verification instead of `RunDocAudit`:

```sql
SELECT TOP (100)
    r.SourceDb,
    r.ArchiveDb,
    p.ProcessCode,
    ri.RunItemId,
    ri.Status,
    ri.DocsDone,
    ri.RowsDeleted,
    ri.RowsArchived,
    rio.SourceSchema,
    rio.SourceTable,
    rio.RowsDeleted AS ObjectRowsDeleted,
    rio.RowsArchived AS ObjectRowsArchived
FROM arch.RunItem ri
JOIN arch.Run r
  ON r.RunId = ri.RunId
JOIN arch.Process p
  ON p.ProcessId = ri.ProcessId
LEFT JOIN arch.RunItemObject rio
  ON rio.RunItemId = ri.RunItemId
ORDER BY ri.RunItemId DESC, rio.SourceSchema, rio.SourceTable;
```

## Recommended defaults

| Process type | Recommended audit level | Reason |
| --- | --- | --- |
| Business document archive/delete | `ROW` | Strong per-key proof |
| High-volume technical log cleanup | `NONE` | Performance and storage |
| Integration history tables | `ROW` for pilots, then `ROW` or `NONE` by compliance need | Depends on customer traceability requirement |
| Experimental/new process | `ROW` for first pilots | Easier post-run verification |
| Stable large process with external evidence | `NONE` | Lower Admin DB overhead |

## Production approval checklist

Before enabling a scheduled real run:

1. Run `DRYRUN` and review candidate counts.
2. Provision archive tables and validate object existence.
3. Confirm cutoff and retention policy.
4. Confirm supporting source indexes.
5. Choose `AuditLevel` explicitly per process/source database.
6. Run a small guarded real-run.
7. Verify archive rows, source deletion, counts, and audit behavior.
8. Check `arch.v_OperationalHealth`.
9. Document accepted evidence level: `ROW`, `NONE`, or `BATCH`.
