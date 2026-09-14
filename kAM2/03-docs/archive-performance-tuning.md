# Archive performance & config tuning

Operational guidance distilled from the measured test battery on `RADIM-STACHAL\RSTSQL2022`
(2026-06-24). Covers three things operators repeatedly ask about: the archive primary key, the
config override model, and the cutoff time-zone.

---

## 1. Why archive tables carry a primary key (and why we keep it)

Archive tables are provisioned to mirror the source columns (`usp_EnsureArchiveTableLikeSource`)
**including the source primary key** (e.g. `RF_LOG2.ROWID`). The PK is not decoration — three
features depend on it:

- **Copy-only (Mode 2) idempotency.** A re-run must not duplicate rows. Dedup is by PK: the second
  copy of the same source rows inserts **0** rows. *Verified: Mode 2 run twice over 100k → archive
  delta on the 2nd run = 0.*
- **Restore correctness.** `usp_RestoreFromArchive` relies on key identity to put rows back without
  duplicating. *Verified: archive 50k → restore → source 50k, archive 50k kept.*
- **Duplicate-archive prevention.** The uniqueness gate (50115) and the archive-as-system-of-record
  guarantee require a unique key.

**Decision: KEEP the PK.** Removing it would break dedup/restore for a marginal write gain — see §2.

### The size/throughput trade-off (measured)

Clustered-PK maintenance makes inserts cost more as the archive grows. Same 200k RF_LOG2 run,
cheap-mode, **identical except archive size**:

| Archive table size at start | Throughput |
|---|--:|
| empty | **~9 100 rows/s** |
| ~5 M+ accumulated | **~2 900 rows/s** (≈3× slower) |

This is the dominant throughput factor at scale — bigger than the audit level (see §4). It is an
accepted cost of an indexed, dedup-capable archive. Mitigations, in order of leverage:

1. **Index parking (`052_archive_with_index_parking.sql`)** — disables non-clustered archive
   indexes during the run and rebuilds them after (≈1.5× faster, fully reversible). Requires
   `@KeepIndexesCsv` = the index needed for the run; it `THROW 50700`s on an empty list and
   rebuilds unconditionally after the archive phase. Use in a maintenance window for large loads.
2. **`BatchRowCount` tuning** — smaller batches reduce lock footprint but add per-batch overhead;
   larger batches are faster but hold more locks. With `LOCK_ESCALATION=DISABLE` on multi-index
   source tables, ~10k–50k is a good range (no escalation, good throughput).
3. **Partitioning** — for 100M+ archives, range-partition the archive by date so inserts hit the
   newest partition and old data can be switched out for purge/cold storage.

> Do **not** `ALTER` the PK off live archive tables. ~98% of a large run's time is the per-row
> DELETE on the source, not archive PK maintenance — parking beats PK removal.

---

## 2. Config layering: Process defaults vs ProcessDatabase overrides

`arch.Process` holds **process-level defaults**; `arch.ProcessDatabase` holds **per-mapping
overrides**. The runner reads `arch.v_ProcessDatabaseEffective`, which computes every overridable
column as `COALESCE(pd.X, p.X)` — **the mapping value wins when set.** This is the standard
"default + per-instance override" pattern (like CSS cascade or k8s configmaps): set a default once,
override per source/archive DB only where needed.

**The gotcha it creates:** editing a value in *Process configuration* has **no runtime effect** for
a mapping that overrides that field. *Verified: setting `Process.AuditLevel=NONE` did nothing for
RF_LOG2@KMWEBV because the mapping had `AuditLevel=ROW`.*

**How the console now surfaces it (no precedence change — just visibility):**
- **Database mappings → `Overrides` column** lists exactly which fields each mapping overrides
  (e.g. `Audit, BatchRows`), or `—` when fully inherited. Source flags render as badges
  (amber = overridden at mapping, neutral = inherited).
- The **Process editor** shows an advisory: *these are defaults; a mapping can override them.*
- Panel notes spell out that `ProcessDatabase` = mapping override, `Process` = inherited default.

To change a value that a mapping overrides, **edit the mapping** (Database mappings), not the
process. The effective view exposes a `<Field>Source` flag for every overridable column.

---

## 3. Cutoff & time zone — keep it simple

Two cutoff modes:

- **Relative retention (`CutoffMode=0`, recommended default):** archive rows older than
  `RetentionDays` (minus a safety lag). **No time-zone ambiguity** — the cutoff is `now − N days`.
  Prefer this for routine operation.
- **Fixed cutoff date (`CutoffMode=1`):** archive everything before a specific date. The date is
  interpreted as **00:00:00 UTC**. Source timestamps are local (CET/CEST), normalized via
  `AT TIME ZONE`, so the **effective local boundary shifts by the zone offset**:

  | Fixed `CutoffDate` | Effective local boundary |
  |---|---|
  | `2024-01-01` (winter, CET = UTC+1) | archive rows before **01:00** local on Jan 1 |
  | `2024-07-01` (summer, CEST = UTC+2) | archive rows before **02:00** local on Jul 1 |

  *Verified: with `CutoffDate=2024-01-01`, markers at 00:00 and 00:59:59 local were archived; 01:00
  and later survived (strict `<` boundary at 01:00 local).*

**Console help:** when a fixed cutoff date is set, the editor now shows the resulting **effective
local boundary** live (e.g. *"1. 1. 2024 1:00"*) and labels the field as UTC, so operators see the
real boundary without doing the math. When in doubt, use relative retention.

---

## 4. Audit level cost (for completeness)

Clean A/B (200k, cheap-mode, archive reset each run, warm-up discarded):

| AuditLevel | Throughput | Audit rows (per 200k) |
|---|--:|--:|
| `NONE` | ~9 100 rows/s | 0 |
| `ROW` (per-row trail) | ~7 200 rows/s | 200 000 |

Full per-row audit costs **~21%** throughput — modest, and far smaller than the archive-size effect
in §1. `BATCH`/`OBJECT` write coarser (per-batch / per-object) trails at negligible cost. Choose the
level deliberately per mapping (it is one of the overridable fields, see §2).

---

## 5. Mode=0 (delete-only) — operational notes (2026-07-14)

`Mode = 0` deletes aged rows **without writing them to the archive**. First production-style use
verified 2026-07-14 (RF_LOG2/KMWE, 540-day retention, backlog 41 201 rows purged exactly, daily
increment = one batch, idempotent re-runs = 0).

- **Requirements.** If the ObjectSpec has `RequireArchiveForDelete = 1` (shipped default), the
  mapping must set `AllowDeleteWithoutArchive = 1`, otherwise the run is blocked with error 50112.
  Combine with `AuditLevel = NONE` for a fully store-nothing purge.
- **Irreversibility.** With Mode=0 + `AuditLevel=NONE` there is **no copy and no per-row record**
  of what was deleted (only counts in `arch.RunItem`). This is a deliberate contract — consider
  `AuditLevel = BATCH` (cheap, metadata-only) if any traceability is wanted.
- **Throughput.** Mode=0 is the fastest profile (no archive INSERT, no audit rows) — faster than
  every figure in §4.

## 6. Per-invocation keyset cap + 1M benchmark (2026-07-14)

One TIMESTAMP run processes at most `min(MaxBatchesPerRun, 100) × BatchRowCount` rows
(= **400 000** with the shipped 4000-row batches) — a keyset/tempdb safety ceiling in
`usp_RunTimestampProcess`. Raising `MaxBatchesPerRun` above 100 has no effect on a single
invocation; bulk backlogs are drained by repeating the RUN (scheduled or manual) until it
deletes 0.

Measured 2026-07-14 (heaviest profile: Mode=1 + `ROW` audit, source table with PK + 12 secondary
indexes, machine running three SQL instances under memory pressure):

| Invocation | Rows | Time | Rate |
|---|--:|--:|--:|
| RUN #1 | 400 000 | 167 s | 2 390 r/s |
| RUN #2 | 400 000 | 199 s | 2 007 r/s |
| RUN #3 | 210 026 | 91 s | 2 322 r/s |
| **Total** | **1 010 026** | **457 s (7.6 min)** | **2 210 r/s** |

Divergence 0 on all runs. On dedicated hardware expect the historical baseline
(~2 700–2 800 r/s ⇒ ~6 min per 1M); the per-row delete cost is dominated by source index
maintenance, not by the selection layer.
