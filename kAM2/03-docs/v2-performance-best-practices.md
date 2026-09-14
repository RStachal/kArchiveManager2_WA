# kArchiveManager 2.0 performance best practices

Target scale: 100-200+ GB databases and source tables with 50-100M+ rows.

## Non-Negotiables

- No production table scans for candidate selection.
- No unbounded deletes.
- No functions on filtered source columns unless backed by a persisted computed column and index.
- No high-volume per-row audit by default.
- No delete mode before dry-run, validation, and plan review.

## Candidate Selection

- Select candidates once into `arch.WorkBatchKey`.
- Order candidates by an indexed key, timestamp, or partition boundary.
- Keep batches resumable and small enough to limit log growth.
- Use `CandidateHash` to support wider composite keys efficiently.

## Sargable cutoff (large-table candidate scan) — C3

The precise candidate predicate is `<TimestampExpr> < @CutoffUtc`, where `TimestampExpr` typically wraps the
source column (`CAST([col] AS datetime2) AT TIME ZONE 'Central European Standard Time' AT TIME ZONE 'UTC'`).
Because the column is inside a function/`AT TIME ZONE`, this predicate is **not sargable** — it forces a full
scan of the source table on every run (measured: ~3–4 min just to select candidates on a 10M-row RF_LOG2).

**Mitigation (opt-in, per process):** add a **conservative, sargable bound on the raw indexed column** to
`CandidateWhereSql`, referencing the cutoff parameter **`@CutoffUtc`** (exposed to the candidate scan in both
the TIMESTAMP runner `027` and the ANCHOR prep `014`). For a column indexed by `AOI_..._DATE_TIME`:

```sql
-- arch.Process.CandidateWhereSql (or per-DB override):
[DATE_TIME] < DATEADD(HOUR, 26, @CutoffUtc)
```

The function is on the **parameter** side, the raw column on the left, so the index **seeks** to the bound
instead of scanning the whole table. `26` hours is a deliberately loose superset (no time-zone offset exceeds
~14 h, plus DST slack), so it can never exclude an eligible row; the precise `TimestampExpr < @CutoffUtc`
predicate still runs and refines the result exactly. **Safety:** because the bound is ANDed *on top of* the
precise predicate, a too-tight bound can only **under-include** (a row's archival is delayed until the bound is
loosened) — it can never delete a row that should have been retained, nor delete-without-archiving. Validate
with a dry-run: the candidate count must match the un-bounded count; if it is lower, loosen the bound.

This works only when the raw column is itself index-friendly (a `datetime`/`datetime2` column with a supporting
index). For string-typed timestamp columns, index the column or add a computed/persisted UTC column instead.

## Index Requirements

Each process should declare mandatory index requirements in `arch.IndexRequirement`:

- `SELECTION`: supports the candidate predicate and order.
- `JOIN`: supports joining each source table to the candidate keyset.
- `DELETE`: supports the delete path when different from join.
- `ORDER`: supports deterministic batching.
- `PARTITION`: documents partition function/scheme requirements.

## Strategy-Specific Guidance

- `ANCHOR`: index anchor cutoff/order columns and child-table foreign keys to the anchor keys.
- `KEYSET`: index all source joins to candidate keys.
- `RANGE`: use contiguous ranges and avoid gaps becoming a correctness dependency.
- `TIMESTAMP`: use native datetime columns or indexed persisted computed columns.
- `PARTITION`: prefer metadata operations when archive schema and partition alignment allow it.
- `ORPHAN`: require indexes on both sides of the anti-join.

## Current TIMESTAMP Source Indexes

Before production-scale timestamp runs, apply or review
`deploy/v2/18_recommended_timestamp_source_indexes.sql` in every enabled source
database.

Recommended source shapes:

- `RF_LOG2`: `DATE_TIME, ROWID`, plus a supporting `ROWID` join index.
- `DNLOAD_ARCHIVE`: `date_archived, ROWID`, plus a supporting `ROWID` join
  index. `date_archived` is the primary cutoff; `TIMESTMP` parsing remains a
  fallback for rows where `date_archived` is null.
- `UPLOADARCHIVE`: computed datetime column `KAM_TIMESTMP_DT` parsed from
  `TIMESTMP`, indexed with `ROWID`, plus a supporting `ROWID` join index.

After `KAM_TIMESTMP_DT` exists in every enabled `UPLOADARCHIVE` source table,
run `deploy/v2/19_update_timestamp_index_requirements.sql` in Admin DB so
`arch.usp_ValidateIndexRequirements` validates `KAM_TIMESTMP_DT,ROWID` instead
of the raw `TIMESTMP,ROWID` compatibility shape.

## Operational Guardrails

- Start with dry-run and `MaxRowsPerTransaction` limits.
- Monitor transaction log growth, wait types, lock escalation, and deadlocks.
- Use low deadlock priority for cleanup jobs.
- Use short lock timeout and retry/resume rather than long blocking.
- Use `READPAST` only when skipping locked rows is operationally acceptable.
- Keep archive table creation explicit or validated before large production runs.
