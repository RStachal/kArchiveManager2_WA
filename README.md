# kArchiveManager 2.0 — deployment package for Koerber Warehouse Advantage

Deploys, configures and tests kArchiveManager 2.0 against a Koerber WA / K.Motion
schema, as **five document sets** with a header → detail hierarchy.

Built and verified end-to-end on **SQL Server 2022, collation `Czech_CS_AS`**,
against `AAD` (394 tables) and `ADV` (47 tables). Every script here has been
executed on that instance; the notes below record what actually happened.

---

## The one rule that shapes everything

> **We never create our own objects in a WMS database.**
> kArchiveManager writes only to `kArchiveManagerAdmin` and
> `kArchiveManagerBackups`. Source databases are **read + delete only** — no
> indexes, no columns, no constraints, no triggers.

This is not caution for its own sake. An earlier revision of this package did
create four indexes in `AAD`, two of them filtered, and **that broke the WMS
write path**:

- SQL Server refuses *any* data modification on a table carrying a filtered
  index (or a computed-column index, or an indexed view) unless the connection
  has `QUOTED_IDENTIFIER ON` — it fails with `Msg 1934`.
- `AAD` is full of objects compiled with `QUOTED_IDENTIFIER OFF`: **240 of its
  1 147 modules, including 8 active triggers** — among them
  `dbo.tr_order_master_insert` on `t_order`.

Result: with a filtered index on `t_order`, that vendor trigger's `UPDATE` failed
and **no order could be inserted at all**. Reproduced independently on
`t_tran_log` from a plain `SET QUOTED_IDENTIFIER OFF` session, which would have
stopped the WMS writing transaction history.

Neither failure was caught by `usp_ValidateConfiguration` — only by trying to
insert a row. `08_source_indexes.sql` is therefore a **read-only report** that
hands DDL to the schema owner; it has no Apply switch. Verification of a clean
footprint is built into it (`B_OUR_FOOTPRINT` must read 0/0).

---

## The five document sets

Each set has ONE header table and its details. Details are deleted first, the
header last. **No table appears in two sets** — enforced by the `OVERLAP_CHECK`
in `25_seed_document_sets.sql`.

| RunOrder | Process | Strategy | Header (deleted last) | Details (bottom-up) |
|---|---|---|---|---|
| 10 | `AAD_PICKDETAIL_ARCH` | ANCHOR | `t_pick_detail` | `t_allocation` |
| 20 | `AAD_TRANLOG_ARCH` | ANCHOR | `t_tran_log` | `t_tran_log_reason`, `t_tran_log_sn` |
| 30 | `AAD_ORDER_ARCH` | ANCHOR | `t_order` | `t_order_detail_comment` → `t_order_comment` → `t_order_detail` → `t_pack` |
| 40 | `AAD_WORKQ_ARCH` | TIMESTAMP | `t_work_q` | `assignment`, `dependency` (both sides) |
| 50 | `ADV_LOGMSG_ARCH` | ANCHOR | `t_log_message` | — |

### Why `t_pick_detail` and `t_tran_log` are not details of the order

Business-wise they belong to the order. But each has **details of its own**:
`t_allocation` joins by `pick_id`, and `reason`/`sn` join by `tran_log_id` —
with **enforced** FKs. From an order-anchored process the keyset carries only
`order_number` + `wh_id`, so those children are a *second hop*, and
`arch.usp_AssertSafeSqlExpression` forbids `SELECT` in configuration SQL
(`THROW 50400`).

As order details they would have been orphaned, and for `t_tran_log` the
enforced FK would have **blocked the delete outright**. Promoting each to its own
header fixes both.

### Why ANCHOR for tables that look like a timestamp job

TIMESTAMP picks its driving table as `TOP(1) ORDER BY DeleteOrder`, i.e. deletes
it **first**. `t_tran_log`'s children have `NO_ACTION` FKs pointing at it, so the
engine **blocks** deleting the parent while they exist. Those two requirements are
irreconcilable. ANCHOR deletes its header **last** — and nothing says an anchor
must be a "document", so the table anchors itself.

Also relevant: TIMESTAMP supports exactly **one** key column (`#Candidates` and
`#Batch` in `027` carry `Key1` only; a second key fails with
`Invalid column name 'Key2'`), while ANCHOR carries `Key1..Key8`.

### `ADV.t_log_message` has no key at all

Measured on live data: **no primary key, no unique index**, and no natural
combination is unique either —

| Combination | Duplicate groups |
|---|---|
| `log_sequence` | 37 rows |
| `log_sequence, process_id` | 24 |
| `logged_on_utc, log_sequence` | 25 |
| `logged_on_utc, log_sequence, process_id, thread_id` | 15 (40 rows) |
| **+ `thread_sequence`** | **2** |

`thread_sequence` is the column that separates them. The last 2 groups are pairs
of **fully identical rows**.

It is archived anyway, with no schema change, because:

- **Key1 carries the whole identity as one delimited string** — unique by
  construction. Spreading the five columns across `Key1..Key5` would NOT work:
  `PK_WorkBatchKey` is `(WorkBatchId, Key1, Key2)`, and `(logged_on_utc,
  log_sequence)` has 25 duplicate groups. `Key2..Key6` repeat the typed columns
  so the delete join compares real values.
- **The runner deduplicates candidates** — `014` lines 388–405 build a `dedupe`
  CTE with `ROW_NUMBER() OVER (PARTITION BY <keys>)` and take `rn = 1`. The two
  identical rows collapse to one candidate; the delete join then matches both and
  archives both. Divergence stays 0. *Proven in the test: 41 candidates → 42 rows.*
- **ISO 8601 (style 126)** for the datetime part — the default conversion style is
  language-dependent and the key would change shape with the session.
- `ntext` (`arguments`, `details`) survives `DELETE ... OUTPUT ... INTO` — verified
  empirically, and the archived payload was intact (max 3 716 bytes).

`19_add_logmessage_key.sql` (add a surrogate `IDENTITY`) is kept only as
documentation of the alternative and is marked **DO NOT USE** — it breaks the
house rule. `24_seed_logmessage_anchor.sql` supersedes it.

---

## Deliberately not archived

| Table | Why |
|---|---|
| `t_employee` | Has `work_q_id`, but it is **master data** — a pointer to the operator's current task. Never archive. Consequence: a queue referenced by a live employee could still be archived; the `work_status IN ('C','P')` gate makes that unlikely. |
| `t_track_tran_log_holding` | Links by `tran_log_holding_id`, not `tran_log_id`, so the keyset cannot reach it. Carries **shipping addresses (personal data)**, so it needs a retention rule — just not this one. Raise separately. |
| `t_label`, `t_pick_container` | No `pick_id`; reachable only via `t_allocation.allocation_id`. Out of scope rather than guessed. |
| `t_tran_log_holding` | Transient staging heap that `usp_process_tran_log` drains continuously — archiving would race the WMS. |

---

## Prerequisites

- SQL Server **2016+** (2019+ recommended; `AT TIME ZONE`, `STRING_SPLIT`)
- **sysadmin** for the deploy
- **SQL Agent running** — the bundle installs jobs in Phase 14, and with
  `:on error exit` a stopped Agent **aborts the deploy**, silently losing
  Phases 14b/14c
- Source databases ONLINE, compat ≥ 130
- A checkout of `ArchiveManager1.0` (pass as `-RepoRoot`)
- The configured timezone present in `sys.time_zone_info`

Collations need not match. Archive tables copy collation **per column from the
source**, and the runner re-collates its `#Keys` temp table to the source
collation before joining. Verified on `Czech_CS_AS` throughout.

---

## How to run it

```powershell
cd <this folder>

# 1) Instance suitability (read-only, safe anywhere)
.\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -Stage precheck

# 2) Does the source schema match the assumptions? (read-only)
.\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -Stage analyse

# 3) Deploy the product (databases + core bundle + verify + selftest + 13 variants)
.\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -Stage deploy `
                 -RepoRoot D:\src\WMSArchiveManager\legacy\ArchiveManager1.0

# 4) Configure all five document sets + provision archive tables
.\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -AdvDb WA_ADV `
                 -Stage configure -RetentionDays 540

# 5) Runner login + job ownership (prints the manual steps - they need a password)
.\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -Stage runtime

# 6) Pre-flight + test data + dry pass. DELETES NOTHING.
.\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -AdvDb WA_ADV -Stage test

#    >>> review _logs\09_preflight_data.log and _logs\22_simulate_job.log <<<

# 7) Real run - replays both Agent job steps, then verifies. DELETES.
.\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -AdvDb WA_ADV `
                 -Stage realrun -IConfirm

# 8) OPTIONAL - throughput measurement. Seeds ~2.6 M rows, then archives and
#    deletes them for one minute per set. Not part of a normal deployment.
.\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -AdvDb WA_ADV `
                 -Stage perf -IConfirm

#    The perf stage already runs the undo in a finally. This is only needed if
#    the whole PowerShell session died with it:
.\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -Stage perfrestore

# 9) Remove the test footprint (test rows + run history + profiles)
.\Run-Deploy.ps1 -Server SQLPROD01 -SourceDb WA_LIVE -Stage cleanup -IConfirm
```

`-Stage all` does 3–4 plus pre-flight and **stops before the real run**.

Each script also runs standalone: edit its `:setvar` block and use
`sqlcmd -S <server> -E -b -I -f 65001 -i <file>`.

### Before the first real run

- [ ] `09_preflight_data.sql` reports **no `STOP`**
- [ ] the dry pass selected the documents you expected — and only those
- [ ] `07_validate.sql` reports **0 ERROR**
- [ ] `kArchiveManagerBackups` has a recent **FULL backup** (it becomes the only copy)
- [ ] you are in an agreed maintenance window

### After the run

`23_verify_standalone.sql`:
- **section B** — `source now + archive now == source before + archive before`, per table
- **section C** — `C_ORPHAN_CHECK` must read **0 / 0 / 0**

---

## Test results on WA01

`-Stage test` then `-Stage realrun -IConfirm`, run twice with identical results
(the test data seed is re-runnable, so the second pass had fresh rows):

| RunOrder | Set | Documents | Archived = Deleted | Divergence |
|---|---|---|---|---|
| 10 | `AAD_PICKDETAIL_ARCH` | 2 | 3 | **0** |
| 20 | `AAD_TRANLOG_ARCH` | 2 | 5 | **0** |
| 30 | `AAD_ORDER_ARCH` | 3 | 12 | **0** |
| 40 | `AAD_WORKQ_ARCH` | 2 | 4 | **0** |
| 50 | `ADV_LOGMSG_ARCH` | 41 | 42 | **0** |
| | **total** | | **66** | **0** |

Matched the predicted 66 exactly. `C_ORPHAN_CHECK` = 0/0/0.

**What each number proves**

- **TRANLOG 5 rows** = 2 headers + 1 `reason` + 2 `sn`. The enforced-FK children
  went with their parent — the whole reason this set is ANCHOR and not TIMESTAMP.
- **ORDER 12 rows** across four levels (`t_order` 3, `t_order_detail` 4,
  `t_order_detail_comment` 2, `t_order_comment` 2, `t_pack` 1). One document
  (`KAMT-O1`) had rows at every level, so a wrong delete order would have let the
  CASCADE destroy children before they were copied.
- **LOGMSG 41 → 42** = candidate dedupe working on the two identical rows.
- **PICKDETAIL 3** = 2 picks + 1 allocation.
- **WORKQ 4** = 2 queues + 1 assignment + 1 dependency.

**And all 15 gated cases survived**, each for its own reason: status not terminal
(`U`, `R`, `RELEASED`, `LOADED`, `PICKED`, `A`, `H`), `lock_flag` set,
`consolidated_order_number` set, the `1900-01-01` sentinel, and simply too recent.
A run that deletes everything old is not a pass — the gates have to hold.

---

## Throughput on WA01 — how much moves in one minute

`40_perf_seed.sql` then `41_perf_test.sql`. Mode 1 throughout, so **every row is
copied to `kArchiveManagerBackups` and then deleted from the source**, inside the
runner's normal batching, transactions and bookkeeping — this is not a raw
`DELETE` benchmark. One minute per document set, run through the same impersonated
runner login as the Agent job.

Single SQL Server 2022 instance, `Czech_CS_AS`, **no custom indexes in the WMS
databases** (the house rule) — so these are honest no-index figures, which is the
production scenario.

**Ranges from three consecutive runs, not a single number.** The same script on
the same instance with the same data varies by up to a factor of two on this box,
so a point value would be false precision. Median is given because with n = 3 it
is more representative than a mean.

### Per table — rows moved in one minute

| Set | Table | Rows in 1 min (min – max) | Rows/s median | Rows/s range |
|---|---|---|---|---|
| `AAD_WORKQ_ARCH` | `t_work_q` | 292 000 – 376 000 | **5 667** | 4 949 – 6 267 |
| | `t_work_q_assignment` | 29 591 – 38 359 | 570 | 502 – 639 |
| | `t_work_q_dependency` | 29 591 – 38 359 | 570 | 502 – 639 |
| `AAD_TRANLOG_ARCH` | `t_tran_log` | 102 000 – 196 000 | **3 400** | 2 372 – 4 667 |
| | `t_tran_log_sn` | 9 864 – 18 906 | 329 | 229 – 450 |
| | `t_tran_log_reason` | 9 864 – 18 906 | 329 | 229 – 450 |
| `AAD_PICKDETAIL_ARCH` | `t_pick_detail` | 102 000 – 192 000 | **4 278** | 2 372 – 4 364 |
| | `t_allocation` | 9 864 – 18 906 | 430 | 229 – 434 |
| `ADV_LOGMSG_ARCH` | `t_log_message` | 84 000 – 85 520 | **2 940** | 1 500 – 2 949 |
| `AAD_ORDER_ARCH` | `t_order_detail` | 14 600 – 17 400 | 264 | 256 – 300 |
| | `t_order` | 7 300 – 8 700 | 132 | 128 – 150 |
| | `t_order_comment` | 7 300 – 8 700 | 132 | 128 – 150 |
| | `t_order_detail_comment` | 746 – 912 | 14 | 13 – 16 |
| | `t_pack` | 2 – 3 | — | — |

### Per set

| Set | Strategy | Rows moved in 1 min | Rows/s median | Rows/s range | Prepare |
|---|---|---|---|---|---|
| `AAD_WORKQ_ARCH` | TIMESTAMP | 351 182 – 452 718 | **6 807** | 5 952 – 7 545 | — |
| `AAD_PICKDETAIL_ARCH` | ANCHOR | 111 864 – 210 906 | **4 712** | 2 601 – 4 793 | 11–16 s |
| `AAD_TRANLOG_ARCH` | ANCHOR | 121 728 – 233 812 | **4 058** | 2 831 – 5 567 | 11–12 s |
| `ADV_LOGMSG_ARCH` | ANCHOR | 84 000 – 85 520 | **2 940** | 1 500 – 2 949 | 2 s |
| `AAD_ORDER_ARCH` | ANCHOR | 29 948 – 35 715 | **542** | 525 – 616 | 1–2 s |

`Divergence` (archived − deleted) was **0** on every row of every table in all
three runs, and `C_ORPHAN_CHECK` was 0/0/0 afterwards. Each run archived and
deleted roughly **0.8–1.0 million rows** across its five one-minute windows.

### Why the runs disagree — and what that tells you

No set was consistently fast or slow: `t_pick_detail` went 4 364 → 2 372 → 4 278
and `t_log_message` 2 949 → 2 940 → 1 500. Different sets were the outlier in
different runs, which is the signature of a shared resource, not of a per-set
problem.

What is ruled out: candidate preparation took a comparable 11–16 s for the same
600 000 keys every time, so the source scan is not the variable; no source-log
autogrowth occurred *during* any measurement; the VLF count is a healthy 41; the
vendor purge never ran inside a measurement window (`PURGE_INTERFERENCE` empty in
all three); and `COVERAGE` and `VALIDITY` passed in all three.

So the variance sits in the **write** phase — the archive `INSERT` plus the source
`DELETE`. `WRITELOG` is the dominant wait on this instance, and the source log had
reached **28.8 GB in FULL recovery with every VLF active and
`log_reuse_wait_desc = LOG_BACKUP`** by the last run. **The exact mechanism was
not proven**, and stating it as fact would be dishonest.

The operational lesson stands regardless, and it is the useful part:

> At these volumes the archiver is write-bound, and the **source database's log
> configuration governs throughput** — not the archiver's settings. Pre-size the
> source log, use a fixed-MB autogrowth rather than a percentage (this instance
> grew 164 MB → 2 162 MB in 10 % steps, the last two blocking for 2.1 s and 2.5 s
> each), and keep log backups running so the log can be reused. Archiving a large
> backlog writes as much log volume as the deletes it performs.
>
> **Measure on the target instance.** Take three runs, not one.

`41_perf_test.sql` therefore prints a `CONDITIONS` section with the recovery
model, log-reuse wait and log size of every database involved, so two results can
be compared on equal terms. On this instance it reports, correctly:
`log cannot be reused until a log backup runs, AND it grows by a percentage -
both throttle a bulk archive`.

### Reading these numbers honestly

- **Four of five sets were stopped by the clock in both runs**, leaving 51 300 –
  498 000 rows still eligible per set — so those are rates, not volumes. The
  script proves this rather than assuming it (`VALIDITY` section), and takes the
  snapshot *before* restoring anything, because the vendor purge would otherwise
  falsify it.
- **`ADV_LOGMSG_ARCH` drained everything it was allowed to have** (29 s in both
  runs), so ~2 940 rows/s is a floor — and the two runs agreeing to within 0.3 %
  is the clearest signal in the whole table. This is structural, not a seeding
  mistake: ADV caps `t_log_message` at 100 000 rows and trims to 95 000, so its
  whole archivable population is **smaller than one minute of throughput**.
  kArchiveManager will always empty it well inside the window.
- **`t_order` looks slow because a document is not a row.** 128–150 documents/s is
  four tables deep with a `BatchDocCount` of 50 — five separate statements per
  batch against five tables. Compare rows: 525–616 rows/s.
- **`t_pack` moved 2–3 rows and that is close to its maximum.** Its primary key is
  `(id, wh_id)` and `id` is a foreign key to `t_employee` — it identifies the
  *packer*. Seven employees on K01 means at most seven rows, whatever the order
  volume. A per-table rate for it is meaningless by construction; the rows are
  there so "structurally tiny" is not misread as "never tested".
- **Child tables run at roughly a tenth of their parent** because the seed gives
  every tenth parent a child (`ChildEvery`), not because they are ten times
  slower. Their rate scales with how many children real documents have.
- **The 11–12 second prepare** on the two 600 000-row sets is real work a scheduled
  run also does: candidates are selected **once** per run, so a cold backlog pays
  it up front. It is amortised over a longer window — which is why the shipped
  `JOB_DEFAULT` profile uses 55 minutes, not one.

### Extrapolating to a real window — read the caveats first

A 55-minute `JOB_DEFAULT` window at these rates is worth **single-digit to low
tens of millions of rows** for the log-shaped sets. That range is deliberately
loose, for three reasons that all matter more than the arithmetic:

1. **The per-set rate varied 2× between two runs here** (above). Measure on the
   target instance rather than trusting this table.
2. **A TIMESTAMP process is capped at 400 000 rows per invocation** while
   `MaxCandidates` is `NULL` — which is how `JOB_DEFAULT` ships. No window length
   changes that. See the operational note below.
3. **Throughput is write-bound**, so it degrades as the source log fills and
   recovers when it is backed up. A first pass over a large backlog will not run
   at steady-state speed.

Size the first production run from a measurement, not from this README.

---

## Scripts

| Script | Writes? | Purpose |
|---|---|---|
| `01_precheck.sql` | no | Version, permissions, Agent, collation, free space |
| `02_databases.sql` | **yes** (own DBs) | Creates both kAM databases, explicitly sized |
| `03_source_analysis.sql` | no | Re-verifies every schema assumption: tables, columns, composite key, CASCADE graph, sentinel defaults, status domains |
| `04_seed_order.sql` | **yes** (config) | Order document set |
| `05_seed_workq.sql` | **yes** (config) | Work-queue set (TIMESTAMP) |
| `20_seed_standalone.sql` | **yes** (config) | Transaction-log + pick sets |
| `24_seed_logmessage_anchor.sql` | **yes** (config) | ADV application log, no schema change |
| `25_seed_document_sets.sql` | **yes** (config) | Shapes the sets header>detail, sets RunOrder, `OVERLAP_CHECK` |
| `06_provision.sql` | **yes** (archive) | Creates the archive tables |
| `07_validate.sql` | no | Config validation, index requirements, go-live readiness, effective config, retention floor |
| `08_source_indexes.sql` | **no** | **Read-only** index report + write-path exposure + DDL for the schema owner |
| `09_preflight_data.sql` | no | Measures live data: volume, sentinels, status domains, key consistency, FK blocker, key uniqueness, dependency stranding |
| `30_test_data_all.sql` | **yes** (test rows) | Test data for all five sets, both directions |
| `22_simulate_job.sql` | **DELETES** if `RunForReal=1` | Replays both Agent job steps, impersonating the runner login |
| `23_verify_standalone.sql` | no | Run log, reconciliation, FK-children check, orphan check, remaining eligible, health |
| `11_realrun_guarded.sql` | **DELETES** | Capped run with a pre-run baseline; blocked unless `IConfirm=YES` |
| `12_verify.sql` | no | Baseline reconciliation for the order/work-queue pair |
| `13_restore.sql` | opt-in | Restore from archive |
| `19_add_logmessage_key.sql` | — | **DO NOT USE** — breaks the house rule; see `24` |
| `40_perf_seed.sql` | **yes** (test rows) | Bulk seed for throughput measurement: ~2.6 M eligible rows across all 14 tables, sized so a 60-second run cannot drain it. Invalidates stale candidate batches, keeps ADV under the vendor size cap |
| `41_perf_test.sql` | **DELETES** | One-minute run per set through the impersonated runner; per-table and per-set rates, prepare/process split, validity, coverage and vendor-purge interference checks. Lifts and restores the batching caps |
| `42_perf_restore.sql` | **yes** (restore) | Undoes all three things `40`/`41` change outside their test data: the batching caps and the vendor job (from `perf.TestBaseline`) and the generated `PERF_*` profiles. `-Stage perf` runs it in a `finally`, so it fires even when the measurement dies mid-way. Idempotent — safe on an instance where the perf scripts never ran |
| `99_cleanup_test.sql` | opt-in | Removes test rows / run history / profiles / config (four switches). Always restores the performance-test baseline |

---

## Operational notes learned the hard way

**Re-run `053` after ANY configuration change that adds a table.** It grants only
on the tables mapped at the time it ran. The first ADV run failed with
`SELECT permission was denied on 't_log_message'` for exactly this reason. It is
idempotent.

**The privilege gate fails for a sysadmin, by design.** `usp_VerifyRunnerPrivileges`
checks the *caller's* rights and refuses a sysadmin, because an unattended runner
must not be one. Running the job simulation as yourself therefore reproduces a
failure the real job would not have — so `22_simulate_job.sql` impersonates
`RunnerLogin` with `EXECUTE AS`. That impersonation must be written **statically**
(sqlcmd substitutes `$(RunnerLogin)` before parsing): inside `EXEC('...')` it
would be scoped to the nested batch and end immediately.

**A TIMESTAMP dry run reports `DocsDone = 0`.** It is an artefact of the dry-run
path, not an empty candidate set — the work-queue set reported 0 in the dry pass
and 2 documents in the real run. Use the real run, or `09_preflight_data.sql`, to
size a TIMESTAMP set.

**Dry runs leave their `WorkBatch` open** (status `Paused`) and the next run
refuses to start while one exists. Every script here closes them at both ends.
The shipped close procedure marks them `Failed` — that is its bookkeeping for a
discarded batch, not an error.

**`MaxRowsPerTransaction` must be ≤ 4000** or the validator raises an ERROR: a
single `DELETE` of ~5000 rows escalates to a `TABLE X` lock on the source. Raise
`MaxBatchesPerRun` for throughput instead — but see the next note, because for a
TIMESTAMP process that advice is wrong.

**`MaxCandidates = NULL` is a 400 000-row ceiling, not "no limit"** — and
`JOB_DEFAULT` ships with it `NULL`. In `usp_RunTimestampProcess`, the `@MaxRows IS
NULL` branch computes its own value:

```sql
@DefaultCandidateBatches = CASE WHEN @MaxBatches > 100 THEN 100 ELSE @MaxBatches END
@MaxRows                 = @BatchRowCount * @DefaultCandidateBatches
```

`@BatchRowCount` is itself hard-capped at 4000 (lock escalation), so the ceiling
is **4000 × 100 = 400 000 rows per invocation, however long the window is**.
Raising `MaxBatchesPerRun` above 100 changes nothing for TIMESTAMP: `@MaxBatches`
is used in exactly two places and there is no batch counter in the loop. Only
`MaxCandidates` bypasses that `CASE`.

Candidates are read from the source **once** per run — there is no loop back to
preparation for either strategy — so this is a hard ceiling on a whole run, not a
per-batch throttle. It was measured before it was understood: `t_work_q` stopped
at exactly 400 000 rows in 100 batches after 43 of its 60 seconds, with 200 000
rows still eligible, and the validity check called it "TIME was the limit". With
`MaxCandidates` set explicitly the same set ran the full 60 s and moved 408 432
rows. The ANCHOR path computes `BatchDocCount × MaxBatchesPerRun` with **no**
clamp, so it does not have this ceiling — the two strategies behave differently
here.

**A `Paused` batch is resumed with its ORIGINAL cutoff.** That is deliberate and
correct: a backlog is worked through in consistent slices instead of being
re-selected from scratch. It is also a trap whenever the underlying rows are
replaced. Re-seeding test data changes the IDENTITY values of
`t_pick_detail.pick_id` and `t_tran_log.tran_log_id`, so a resumed keyset
addresses rows that no longer exist: the run reports `Status OK`, `DocsDone`
78 000 and 210 000, `RowsDeleted` **0** — a result that looks like a measurement
and is not one. The order set was worse: its keys are natural
(`order_number`, `wh_id`), so they still matched and it deleted 47 800 rows
against a cutoff from three days earlier. `usp_CloseDryRunWorkBatches` does not
help — it closes dry-run batches only, exactly as its name says.

The rule the package follows is **the script that deletes the rows invalidates the
keys**: `40_perf_seed.sql` marks open batches `Failed` before it re-seeds,
`99_cleanup_test.sql` does the same after it removes the test data, and
`41_perf_test.sql` refuses to measure while one is present. `99` did not do this
at first, and four `Paused` batches survived a cleanup holding keys for rows that
no longer existed — with `arch.v_OperationalHealth` reporting `OPEN_WORKBATCH`
("Open WorkBatch can block ANCHOR candidate preparation") until they were cleared.

If you ever need to clear them by hand, `Failed` is the terminal status the
product itself uses for a discarded batch:

```sql
UPDATE arch.WorkBatch
SET Status = N'Failed', CompletedAtUtc = SYSUTCDATETIME()
WHERE Status NOT IN (N'Completed', N'Failed');
```

Never do that on a production backlog: a `Paused` batch there holds real pending
work, and discarding it means those rows are skipped until some later run
happens to select them again.

**`arch.usp_ValidateConfiguration` returns EIGHT columns**, not seven — Phase 14b
(`v2\063`) adds a trailing `ActionKey`. A seven-column `INSERT ... EXEC` fails
with `Msg 213`. This was a real bug in the shipped `variant_test_pack.sql`, fixed
in commit `452445f`.

**`sqlcmd` without `-I` runs with `QUOTED_IDENTIFIER OFF`**, which fails on
filtered indexes and on some DDL. Always pass `-I`.

**Warehouse Advantage already purges `t_log_message`, and at 90 days retention we
archive nothing.** ADV ships Agent job `Log Maintenance` → `ADV.usp_PurgeLog`,
driven by three rows in `ADV.dbo.t_adv_control`:

| Key | On WA01 | Effect |
|---|---|---|
| `LogPurgeMaximumDays` | 30 | deletes anything older than *n* days |
| `LogPurgeMaximumSize` | 100 000 | above this many rows… |
| `LogPurgeToSize` | 95 000 | …delete the **oldest** down to this, **regardless of age** |

With a 90-day retention our cutoff selects rows older than 90 days and ADV deleted
them at 30. **The two windows are disjoint and no amount of waiting fixes it** —
the process reports success with zero rows for ever. Found empirically: 300 000
seeded log rows vanished 29 seconds after the seed, with no archive run and no
trace in `arch.Run`. `24_seed_logmessage_anchor.sql` therefore **clamps** the
retention into the vendor window with a week of headroom (90 → **23** days here)
and prints why. Set the ADV retention below `LogPurgeMaximumDays` or this set is
decoration.

The size cap cannot be defended against — it is age-blind — so the only answer is
to run often enough that the table stays under it. `09_preflight_data.sql` reports
the current count against the cap.

**Disabling an Agent job does not stop it running.** `sp_update_job @enabled = 0`
suppresses only *schedule*-driven execution; an explicit `sp_start_job` runs a
disabled job perfectly happily. On WA01 the WA service does exactly that — msdb
history shows `The Job was invoked by User HJS` at 14:53 and again at 15:08, the
second one **while the job was disabled**, in the middle of a measurement. It
trimmed `t_log_message` mid-run, which is why that ADV figure came out at 1 277
rows/s instead of 2 949, and why 26 000 prepared keys pointed at rows that had
just been deleted (`DocsDone` 86 000 vs `RowsDeleted` 60 000). Never treat a
disabled job as a guarantee: verify from `msdb.dbo.sysjobhistory` that it did not
run, which is what `41_perf_test.sql`'s `PURGE_INTERFERENCE` section does.

**A stale `arch.IndexRequirement` produces a warning nobody can action.** If
`19_add_logmessage_key.sql` was ever run, its requirement on `kam_row_id` survives
the column being dropped, and `usp_ValidateConfiguration` then reports "At least
one required index column does not exist on the source table" on every run, for
ever. A permanent un-actionable WARN is worse than no check — it trains whoever
reads the validation to ignore warnings. `24_seed_logmessage_anchor.sql` now
removes any requirement whose columns are genuinely absent, verified against the
source catalogue.

**`OUTPUT` cannot contain a subquery** (`Msg 10705`) and cannot reference a joined
table — only the target row and `inserted`/`deleted`. Capture the bare facts and
join afterwards.

**`sys.columns` is not cross-database.** `OBJECT_ID('OtherDb.dbo.t')` resolves a
three-part name, but `sys.columns` only holds the current database's objects — so
column checks against a source must go through dynamic SQL.

**`IF` does not prevent compilation.** A static reference to a missing table or
column fails the whole batch even inside a branch that never runs — hence the
dynamic SQL around the optional checks in `19`, `23` and `12`.

**Watch declared string lengths when building DDL.** `DECLARE @x nvarchar(40)`
silently truncated a 44-character index option string, producing the baffling
`Incorrect syntax near 'P'`.

**`RunDocAudit` can be cleared by a sysadmin.** The audit-immutability `DENY`
(script `045`) is granted against roles, so `sa`-class logins bypass it. The
runner cannot — which is the point — but do not read a successful cleanup as
evidence that the audit trail is tamper-proof against a DBA.

---

## Retention

`-RetentionDays` sets it; the effective cutoff is
`now(UTC) − RetentionDays − CutoffSafetyLagMinutes(1440)`.

The **retention floor** (`arch.RetentionPolicy.MinRetentionDays`) is `0` =
**disabled** by default, so nothing stops a run deleting inside a mandatory
window. For production set it as a guard against a mistyped retention:

```sql
EXEC arch.usp_Api_SetRetentionFloor @MinRetentionDays = 365, @RequestedBy = 'dba';
```

Individual documents can be pinned with `arch.usp_Api_AddLegalHold`.

**The ADV retention is not the one you asked for.** `t_log_message` is already
purged by the vendor, so `24_seed_logmessage_anchor.sql` clamps this one process
into that window — a requested 90 days becomes **23** on WA01
(`LogPurgeMaximumDays` 30, minus a week of headroom). At the requested value the
process would archive nothing at all, for ever. The script prints
`*** RETENTION CLAMPED ***` with the arithmetic; the operational note above
explains why.

**Size the first run — and `MaxCandidates = NULL` does not mean "everything".**
For an ANCHOR process it means `BatchDocCount × MaxBatchesPerRun` (500 000 with
the shipped values). For a **TIMESTAMP** process it means a hard **400 000 rows
per invocation**, whatever the window length, because the runner clamps its own
default to 100 batches of 4000 — see the operational note. `JOB_DEFAULT` ships
with `MaxCandidates = NULL`, so `AAD_WORKQ_ARCH` is currently limited to 400 000
rows per run.

Whether to change that is a tuning decision, not a defect, and it cuts both ways:

```sql
-- Raise the TIMESTAMP ceiling. Note this raises it for EVERY process in the
-- profile, including the ANCHOR sets, whose candidate preparation then costs
-- more up front (11 s for 600 000 keys on WA01).
EXEC arch.usp_Api_SaveRunProfile @RunProfileCode = N'JOB_DEFAULT', ...
     @MaxCandidates = 2000000, ...;
```

At the measured rates, 400 000 rows of `t_work_q` is about 60 seconds of a
55-minute window — so with the shipped configuration that set idles for 54 of
them once it is caught up, and cannot catch up at all on a large backlog. Either
raise `MaxCandidates`, or schedule the job more often and accept a fixed ceiling
per invocation. On a backlog, the second option is a per-run cap you can reason
about; the first is faster but makes one run hold locks for longer.

---

## Not in this package

- **Admin Console / IIS** — console, app-pool principal and operator seed
  (`v2\061–066`, `deploy\v2\32/34/35/51/59`). Database runtime only.
- **Alerting and archive backups** — `047` (Database Mail) and `048` (FULL+LOG
  jobs) need an SMTP server and a backup path. Go-live readiness reports both as
  WARN until done. **The archive backup is not optional**: that database is the
  only copy of rows deleted irreversibly from the source.
- **Enabling the scheduled job** — `kArchiveManager - RUN CONFIGURED` ships
  DISABLED and stays that way. Enable it only after a successful capped real run.
  It hardcodes the `JOB_DEFAULT` profile, which `04_seed_order.sql` creates.
