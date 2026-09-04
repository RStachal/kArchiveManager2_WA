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

# 8) Remove the test footprint (test rows + run history + profiles)
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
| `99_cleanup_test.sql` | opt-in | Removes test rows / run history / profiles / config (four switches) |

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
`MaxBatchesPerRun` for throughput instead.

**`arch.usp_ValidateConfiguration` returns EIGHT columns**, not seven — Phase 14b
(`v2\063`) adds a trailing `ActionKey`. A seven-column `INSERT ... EXEC` fails
with `Msg 213`. This was a real bug in the shipped `variant_test_pack.sql`, fixed
in commit `452445f`.

**`sqlcmd` without `-I` runs with `QUOTED_IDENTIFIER OFF`**, which fails on
filtered indexes and on some DDL. Always pass `-I`.

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

**Size the first run.** `JOB_DEFAULT` has no `MaxCandidates`, so it takes
everything eligible — on this instance that was 13 903 log rows in one pass. For a
first production run, cap it.

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
