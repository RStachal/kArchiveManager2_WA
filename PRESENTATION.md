# Driving the demo

A script for showing kArchiveManager 2.0 working, on the reference instance, to an
audience. Every step below was executed end to end on 2026-09-14 and the numbers
are the ones that came back.

The short version of what you are proving: **nothing is deleted that was not first
copied, and nothing is touched that the configuration did not name.** Everything
else is detail.

---

## Before the room fills

### Reset to a clean baseline — 5 minutes, and worth it

```
sql/99_cleanup_test.sql     edit :setvar CleanTestData "1", run it
sql/40_perf_seed.sql        run it
```

That order matters. `40` reuses the same key space every time (`KAMT-OF*`,
`KAMPO-B*`, `KAMTB*`), so seeding onto a non-empty archive leaves the archive
holding two generations of the same keys. Nothing breaks, but the dashboard counts
stop meaning anything and `33_verify_bulk.sql` starts reporting violations that are
not real.

Reset also gives you the better demo: **the archive starts empty**, so the audience
watches it fill from zero instead of watching a number that was already large get
larger.

State after the reset, as measured:

| | source | archive |
|---|---:|---:|
| `t_order` | 25 000 | 0 |
| `t_pick_detail` | 75 000 | 0 |
| `t_pick_container` | 25 000 | 0 |
| `t_pick_task_uom` | 75 000 | 0 |
| `t_tran_log` | 75 000 | 0 |
| `t_work_q` | 75 001 | 0 |
| `t_po_master` | 25 001 | 0 |
| `ADV.t_log_message` | 90 000 | 0 |

220 000 eligible documents, and **55 000 rows deliberately held back** — an order
that is not shipped, a pick that is not `SHIPPED`, a PO still open, a transaction
inside the retention window. Those are the point of the whole demo: they are how
you prove the tool is selective rather than merely fast.

### Check these four things

```sql
-- 1. configuration is valid
EXEC arch.usp_ValidateConfiguration;          -- returns 0, one known WARN (below)

-- 2. nothing is in flight
SELECT Status, COUNT(*) FROM arch.WorkBatch GROUP BY Status;   -- no Running, no Paused

-- 3. the PREP job can actually run   <-- see the blocker below
SELECT name, SUSER_SNAME(owner_sid) FROM msdb.dbo.sysjobs WHERE name LIKE 'kArchiveManager%';

-- 4. the console answers
--    http://localhost:8089  -> readiness databaseOk true, processCount 6
```

---

## One blocker you must fix first

**`kArchiveManager - PREP CONFIGURED` fails one second after it starts.** If you
demonstrate the jobs without fixing this, the first thing the audience sees is a
red cross.

```
Step 1 VALIDATE CONFIGURATION  FAILED
kArchiveManager runner privilege gate failed. See arch.usp_VerifyRunnerPrivileges.
[SQLSTATE 42000] (Error 51001)
```

The job is owned by a sysadmin. Its step 1 runs `arch.usp_VerifyRunnerPrivileges`,
which exists precisely to refuse a sysadmin runner — so the gate is right and the
job is wrong. The shipped add-on `054_runner_job_least_privilege.sql` re-owns only
`RUN CONFIGURED` (its `@JobNameLike` default is that exact name), and `PREP`
carries the identical gate while keeping whatever login deployed it.

Fix, then prove it:

```
sql/55_fix_prep_job_owner.sql      set @Apply = 1, run as sysadmin
EXEC msdb.dbo.sp_start_job @job_name = N'kArchiveManager - PREP CONFIGURED';
```

Section B of that script evaluates the gate **as the runner** before you change
anything: it must print `GateReturnCode 0`. If it does not, re-owning the job only
moves the failure.

---

## The walkthrough

### 1. The configuration, and why it looks like that

Open the console at `http://localhost:8089`, Configuration. Six document sets:

| Set | Strategy | Anchor | Keys | Gate |
|---|---|---|---|---|
| `AAD_ORDER_ARCH` | ANCHOR | `t_order` | order_number + wh_id | `status IN (S,D)`, not locked, not consolidated |
| `AAD_PICKDETAIL_ARCH` | ANCHOR | `t_pick_detail` | pick_id | `status = SHIPPED` |
| `AAD_PO_ARCH` | ANCHOR | `t_po_master` | po_number + wh_id | `status = C` and `closed_date` set |
| `AAD_TRANLOG_ARCH` | ANCHOR | `t_tran_log` | tran_log_id | dated after the epoch sentinel |
| `AAD_WORKQ_ARCH` | TIMESTAMP | — | work_q_id | driving table carries the timestamp |
| `ADV_LOGMSG_ARCH` | ANCHOR | `t_log_message` | composite | retention 23 days |

The two ideas worth saying out loud:

**ANCHOR deletes the anchor last.** Children go first, in `DeleteOrder`, and the
header row last. That is what makes an interruption safe — you can lose the
connection at any point and the worst case is a document whose children are already
archived and whose header is still live. Resume, and it completes.

**TIMESTAMP deletes the driving table first.** `AAD_WORKQ_ARCH` is the one set with
no anchor; the timestamp lives on `t_work_q` and the other three tables follow it.

Two things an alert audience will spot, so get in front of them:

* `t_work_q_dependency` is configured **twice**, at `DeleteOrder` 30 and 40. That is
  deliberate: once joined on `parent_work_q_id`, once on `dependent_work_q_id`, so
  both sides of a dependency leave with their queue. Per-table reports therefore
  list it twice with identical counts.
* Validation emits one **WARN** on `ADV_LOGMSG_ARCH`: it declares six keys while
  `arch.WorkBatchKey`'s primary key is `(WorkBatchId, Key1, Key2)`. It is harmless
  here and you can say why: `Key1` is not a column, it is
  `logged_on_utc|log_sequence|process_id|thread_id|thread_sequence` concatenated —
  the whole composite in one field. Key1 alone is unique, so Key1+Key2 certainly is.

### 2. Preview without touching anything

The `ALL_DRYRUN` profile selects candidates and reports what it would take, writing
nothing:

```sql
EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'ALL_DRYRUN';
```

Say what it is doing, because the batch bookkeeping looks alarming afterwards: a
dry-run WorkBatch is closed with **`Status = 'Failed'`** by
`arch.usp_CloseDryRunWorkBatches`, with a note explaining that no source data was
changed. Successful previews therefore accumulate as "failed" batches. If the
dashboard shows a large failed count on your instance, that is what it is — check
`arch.WorkBatch.Notes` before anyone concludes the tool is broken.

### 3. Start the jobs

```sql
EXEC msdb.dbo.sp_start_job @job_name = N'kArchiveManager - PREP CONFIGURED';
EXEC msdb.dbo.sp_start_job @job_name = N'kArchiveManager - RUN CONFIGURED';
```

Both jobs ship **disabled**, and `sp_start_job` runs a disabled job anyway — that is
SQL Server, not a bug, and it is the intended way to run these on demand. Leave them
disabled; being disabled only stops the *schedule*.

`RUN` prepares its own batches (`@Phase` defaults to BOTH), so it works without PREP.
PREP exists to front-load the candidate scan so the run window is spent deleting
rather than selecting.

Watch it live:

```sql
SELECT RunId, StartedAt, EndedAt, Status, SourceDb FROM arch.Run ORDER BY RunId DESC;
SELECT Status, COUNT(*) FROM arch.WorkBatch GROUP BY Status;
```

### 4. Show the rows moving

Run this before and after a minute:

```sql
SELECT t.name, SUM(p.rows)
FROM AAD.sys.tables t
JOIN AAD.sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name IN ('t_pick_detail','t_pick_task_uom','t_allocation')
GROUP BY t.name;
```

Measured on this instance, one minute, one set (`AAD_PICKDETAIL_ARCH`):

| table | deleted from source in 60 s |
|---|---:|
| `t_pick_detail` | 216 000 |
| `t_pick_task_uom` | 216 000 |
| `t_allocation` | 43 566 |
| **total** | **475 566** |

Every one of those rows was written to `kArchiveManagerBackups` first, so the real
work rate is roughly **950 000 row operations per minute** on a single-socket
evaluation VM.

Across the full test, all six sets: **2 986 057 rows archived, 2 986 057 rows
deleted, divergence 0.**

### 5. Stop it — and know what Stop means

This is the step most likely to embarrass you, so rehearse it.

`arch.usp_Api_RequestRunStop` (the console's Stop button) stops **the current run,
not the job**. It works exactly as designed — the run ends cleanly at the next batch
boundary and records who asked and why — but `usp_RunProfile_Prepared` then moves to
the next process/database pair and opens a *new* run. From the front row it looks
like Stop did nothing.

```sql
-- stops one run; the job carries on
EXEC arch.usp_Api_RequestRunStop @RunId = <id>, @RequestedBy = N'demo', @Reason = N'...';

-- stops the job
EXEC msdb.dbo.sp_stop_job @job_name = N'kArchiveManager - RUN CONFIGURED';
```

`sp_stop_job` kills the worker mid-batch, which leaves the run row saying `RUNNING`
with no end time. That is not corruption, and it is not left to rot: the enabled job
`kArchiveManager - RECOVER STALE RUNS` closes it, and its logic is worth showing —

```sql
EXEC arch.usp_RecoverStaleRuns @StaleAfterMinutes = 0, @DryRun = 1, @VerboseOutput = 1;
```

```
RUN       10168  MARK_FAILED       Worker session ended while run was RUNNING
                                   (archived=44289 deleted=44289); marked FAILED for
                                   safe re-processing - success is never inferred.
WORKBATCH 106    PAUSE_FOR_RETRY   No progress for 1 min, 45300 keys still pending
```

The counts matched exactly and it still refused to call the run successful. That
sentence — *success is never inferred* — is the one to read aloud.

In production the job looks every 15 minutes for runs silent for 30 - two different
numbers, on purpose. For a demo, call the procedure by hand with
`@StaleAfterMinutes = 0` rather than waiting.

### 6. Prove only the configured rows were taken

This is the part that matters, and it is the part most demos skip.

```
sql/33_verify_bulk.sql
```

Results on the settled state after the full run:

* **Section C — 12 gate checks, every one 0.** No row in the archive violates the
  gate it was supposed to satisfy. Spot-check live if someone is sceptical:
  after the pick set completed, `AAD.t_pick_detail` held exactly **one** row, and it
  was the one row whose status was not `SHIPPED`.
* **Section D — 9 orphan checks, every one 0.** No archived child lost its parent,
  including `t_rcpt_ship_po`, the junction that links receipts and shipments to POs
  and the one place where archiving a PO could have stranded a live shipment.
* **Section E — archived 1 455 253, deleted 1 455 253, divergence 0.**

**Run this only when nothing is in flight.** With a batch mid-flight, section C's two
child checks legitimately report violations, because ANCHOR archives children before
their header — that is the normal intermediate state, not a fault. Observed during
this test: 15 012, then 11 097, then **0**, as the batches completed. The script now
prints that warning above section C.

### 7. The console

`http://localhost:8089` — dashboard, per-set movement, run history, go-live gate.
Go-live reports **0 blockers, 1 warning**; the warning is `047` alerting (Database
Mail, operator, failure notification), not applied here because this server has no
SMTP. On a customer system it must be.

**Do not click** Restore, Apply fix, or anything under Configuration during the demo.
Restore is read-only by design (`065` is deliberately not applied, so a real restore
returns `INSERT permission denied`), but the dry-run preview still looks like it did
something.

---

## Answers to the questions you will actually get

**"What if it deletes something it shouldn't?"** It cannot delete without archiving:
every ObjectSpec has `RequireArchiveForDelete = 1`, and the run reconciles archived
against deleted on every batch. Across 2 986 057 rows, divergence was 0. And
`kArchiveManagerBackups` has its own FULL + LOG backup jobs, because it is the only
copy of a row once the source is gone.

**"Does it touch our WMS database?"** Only SELECT and DELETE, on the named tables.
No index, no column, no trigger, no table is ever created in `AAD` or `ADV`. This is
not a preference — an earlier revision created four indexes in `AAD`, two filtered,
and broke the WMS write path outright, because 240 of that database's 1 147 modules
are compiled with `QUOTED_IDENTIFIER OFF` and SQL Server refuses DML against a
filtered index under that setting. `08_source_indexes.sql` therefore hands index DDL
to the customer's DBA and has no Apply switch.

**"How long for our volume?"** Roughly half a million source rows per minute per
set on modest hardware, and it is bounded deliberately: `MaxRowsPerTransaction`
stays at or below 4 000 to avoid lock escalation on the WMS tables, and the run
window is 55 minutes. It is designed to be interruptible, not to be fast.

**"What if it dies halfway?"** Shown in step 5. The batch pauses with its remaining
keys, the run is marked FAILED rather than assumed complete, and the next run
resumes it — under the cutoff it was originally prepared with, so the selection
cannot drift underneath you.

**"Can we get the data back?"** `arch.usp_RestoreFromArchive`, and there is a
console preview for it. It writes into a production source table, so the grant is
withheld by default and a DBA has to make that call deliberately.

---

## If it goes wrong on the day

| Symptom | Cause | Do this |
|---|---|---|
| PREP fails instantly, Error 51001 | job owned by a sysadmin | `sql/55_fix_prep_job_owner.sql` |
| Stop appears to do nothing | it stopped the run, not the job | `sp_stop_job` |
| A run sits at `RUNNING` forever | worker killed mid-batch | `usp_RecoverStaleRuns @StaleAfterMinutes = 0` |
| Dashboard shows many failed batches | dry-run previews close as `Failed` | read `arch.WorkBatch.Notes` |
| Verification reports gate violations | a batch is still in flight | let it finish, then re-run |
| Nothing is eligible | the reset was not run, or everything is already archived | `99` then `40` |
| Console shows `databaseOk: false` | app-pool login not in all five roles | `ADMIN-CONSOLE.md`, correction 4 |
