# Driving the demo

A script for showing kArchiveManager 2.0 working, on the reference instance, to an
audience. Every step below was executed end to end on 2026-09-14 and the numbers
are the ones that came back.

The short version of what you are proving: **nothing is deleted that was not first
copied, and nothing is touched that the configuration did not name.** Everything
else is detail.

---

## Before the room fills

### The fastest reset: restore the four `_PresentationStart` backups

The reference instance has a captured starting point — configuration intact,
archive empty, both WMS databases full — as four verified FULL backups in the
instance's default backup folder:

```
AAD_PresentationStart.bak                     124 MB
ADV_PresentationStart.bak                      12 MB
kArchiveManagerAdmin_PresentationStart.bak      7 MB
kArchiveManagerBackups_PresentationStart.bak    1 MB
```

Restoring all four puts you back at the start in about fifteen seconds, and it is
the only reset that is guaranteed self-consistent — the archive matches the source
it was emptied against.

**These four carry the runner and console database users**, because the principals
were re-created before the backups were taken. Restoring *them* therefore does not
need `053` and `051` afterwards. Restoring any **older** backup does — including
`AAD_PREZENTACE_START.bak` / `ADV_PREZENTACE_START.bak`, which predate the
principals. A restore replaces every database principal and nothing warns you, so
when in doubt spend the two seconds:

```sql
EXEC arch.usp_VerifyRunnerPrivileges;   -- must return 0
EXECUTE AS LOGIN = N'IIS APPPOOL\kAM Admin Console';
SELECT name, HAS_DBACCESS(name) FROM sys.databases
WHERE name IN ('AAD','ADV','kArchiveManagerAdmin','kArchiveManagerBackups');
REVERT;                                 -- every row must be 1
```

### Restoring these from SSMS can leave ADV unusable — check it every time

The SSMS restore wizard emits `SET SINGLE_USER WITH ROLLBACK IMMEDIATE`, the
restore, then `SET MULTI_USER`. **That last statement races anything reconnecting
to the database, and on this server it loses**: the Körber One Advantage Platform
holds ten sessions against `ADV` and grabs the one free slot the instant the
restore finishes. The database is then stuck in `SINGLE_USER` with the WMS
application holding it, and the next job dies:

```
Step 1 VALIDATE CONFIGURATION  FAILED
Database 'ADV' is already open and can only have one user at a time.
[SQLSTATE 42000] (Error 924)
```

Seen on 2026-09-16: `AAD` won the race and `ADV` lost, from the same wizard, one
minute apart. So check after every restore, and fix it by taking the single slot
yourself before opening the door — a plain `SET MULTI_USER` deadlocks against the
application and fails:

```sql
SELECT name, user_access_desc FROM sys.databases
WHERE name IN ('AAD','ADV','kArchiveManagerAdmin','kArchiveManagerBackups');

-- if anything says SINGLE_USER:
SET DEADLOCK_PRIORITY HIGH;
ALTER DATABASE [ADV] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;  -- the slot is now yours
ALTER DATABASE [ADV] SET MULTI_USER;
```

Restoring from a script rather than the wizard avoids the wizard's
`WITH RESTRICTED_USER` default, but not the race — the two `ALTER` statements above
are the reliable fix either way.

To rebuild that starting point from scratch instead — after a demo, or on another
instance — use `sql/58_presentation_reset.sql`. It clears every record from
`kArchiveManagerAdmin` while leaving the configuration untouched, and empties the
archive tables without dropping them. It does **not** touch the WMS databases;
those come from their own backup.

**What the demo will move**, measured on this starting point:

| set | eligible documents |
|---|---:|
| `ADV_LOGMSG_ARCH` | 58 473 |
| `AAD_TRANLOG_ARCH` | 9 008 |
| `AAD_ORDER_ARCH` | 334 |
| `AAD_PO_ARCH` | 124 |
| `AAD_PICKDETAIL_ARCH` | 56 |

One caveat on the ADV figure: **Warehouse Advantage purges `t_log_message`
itself**, at 30 days and a 100 000-row cap. The table shrinks on its own between
the moment you restore and the moment you run, so expect the ADV number to be
lower than the one above and do not treat the difference as rows the tool missed.
It is the one set where the source moves without us.

### Know which data you are standing on

The reference instance has held **two different data sets** in its life, and the
demo differs depending on which one is loaded. Check first:

```sql
SELECT COUNT(*) AS Orders,
       SUM(CASE WHEN order_number LIKE N'KAMT-%' THEN 1 ELSE 0 END) AS Seeded
FROM AAD.dbo.t_order;
```

**Real WMS data** (`Seeded = 0`) — what is loaded since **2026-09-15**. 843 orders,
1 055 containers, 1 132 picks, 111 POs, 44 926 ADV messages, with the real
foreign keys enforced. This is the honest demo: the audience sees their own kind
of data move, and the FK-completeness of the ORDER set is exercised for real. Do
**not** run `40_perf_seed.sql` on top of it — that would mix synthetic keys into a
real schema. There is no reset; the archive simply fills as you run.

Measured on this data, 2026-09-16, one RUN of the ORDER set: **1 977 rows
archived, 1 977 deleted, divergence 0**; 334 orders in 7 batches; 0 orphans, 0
gate violations; 509 orders left, every one of them not yet eligible.

**Seeded test data** (`Seeded > 0`) — what `40_perf_seed.sql` produces, and what
the throughput numbers below were measured on. If you want that instead:

```
sql/99_cleanup_test.sql     edit :setvar CleanTestData "1", run it
sql/40_perf_seed.sql        run it
```

in that order — `40` reuses the same key space every time (`KAMT-OF*`, `KAMPO-B*`,
`KAMTB*`), so seeding onto a non-empty archive leaves two generations of the same
keys in it. Reset gives the archive an empty start, and the seed holds back
**55 000 rows deliberately** — an order not shipped, a pick not `SHIPPED`, a PO
still open — which is how you prove the tool is selective rather than merely fast.

Either way, the safety story is the same. On real data it is simply true rather
than demonstrated.

### Check these five things

```sql
-- 1. configuration is valid
EXEC arch.usp_ValidateConfiguration;          -- returns 0, one known WARN (below)

-- 2. nothing is in flight
SELECT Status, COUNT(*) FROM arch.WorkBatch GROUP BY Status;   -- no Running, no Paused

-- 3. the jobs are owned by the runner, not a sysadmin (else PREP fails 51001)
SELECT name, SUSER_SNAME(owner_sid) FROM msdb.dbo.sysjobs WHERE name LIKE 'kArchiveManager%';

-- 3b. the console can still reach every source database. A RESTORE of a WMS
--     database takes its user with it and NOTHING warns you - readiness stays
--     green and one dashboard panel returns 503. Costs two seconds to check.
EXECUTE AS LOGIN = N'IIS APPPOOL\kAM Admin Console';
SELECT name, HAS_DBACCESS(name) FROM sys.databases
WHERE name IN ('AAD','ADV','kArchiveManagerAdmin','kArchiveManagerBackups');
REVERT;                                        -- any 0 -> re-run 051

-- 4. the console answers
--    http://localhost:8089  -> readiness databaseOk true, processCount 6
```

---

## The blocker that used to be here — fixed on this instance

**`kArchiveManager - PREP CONFIGURED` used to fail one second after it started**,
so the first thing an audience saw was a red cross:

```
Step 1 VALIDATE CONFIGURATION  FAILED
kArchiveManager runner privilege gate failed. See arch.usp_VerifyRunnerPrivileges.
[SQLSTATE 42000] (Error 51001)  -- executed as NT AUTHORITY\SYSTEM
```

The job was owned by a sysadmin. Its step 1 runs `arch.usp_VerifyRunnerPrivileges`,
which exists precisely to refuse a sysadmin runner — the gate was right and the job
was wrong. The shipped add-on `054_runner_job_least_privilege.sql` re-owns only
`RUN CONFIGURED` (its `@JobNameLike` default is that exact name), and `PREP` carries
the identical gate while keeping whatever login deployed it.

**Applied on this instance on 2026-09-14.** All five jobs now run as they should:

| Job | Owner | Started | Outcome |
|---|---|---|---|
| PREP CONFIGURED | `karch_runtime_svc` | manually | both steps **SUCCEEDED**, 5 batches prepared |
| RUN CONFIGURED | `karch_runtime_svc` | manually | step 1 SUCCEEDED, step 2 archived and deleted, cancelled on request |
| RECOVER STALE RUNS | `karch_runtime_svc` | manually **and on its own schedule** | SUCCEEDED |
| BACKUP ARCHIVE DB (FULL) | sysadmin | manually | SUCCEEDED, verified |
| BACKUP ARCHIVE DB (LOG) | sysadmin | manually **and on its own schedule** | SUCCEEDED, 249 464 pages |

If you are on a different instance:

```
sql/56_agent_jobs.sql              building a new instance - creates all five jobs
sql/55_fix_prep_job_owner.sql      repairing an existing one - re-owns PREP only
```

Either way, prove it rather than assuming — the failure costs one second, so it is
cheap to test:

```sql
EXEC msdb.dbo.sp_start_job @job_name = N'kArchiveManager - PREP CONFIGURED';
-- then read msdb.dbo.sysjobhistory: step 1 must say SUCCEEDED, and
-- "Executed as user: <the runner>", not NT AUTHORITY\SYSTEM.
```

Section B of `55` evaluates the gate **as the runner** before changing anything: it
must print `GateReturnCode 0`. If it does not, re-owning the job only moves the
failure somewhere less obvious.

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

**On the seeded data**, one minute, one set (`AAD_PICKDETAIL_ARCH`):

| table | deleted from source in 60 s |
|---|---:|
| `t_pick_detail` | 216 000 |
| `t_pick_task_uom` | 216 000 |
| `t_allocation` | 43 566 |
| **total** | **475 566** |

Every one of those rows was written to `kArchiveManagerBackups` first, so the real
work rate is roughly **950 000 row operations per minute** on a single-socket
evaluation VM. Across that full test, all six sets: **2 986 057 rows archived,
2 986 057 rows deleted, divergence 0.**

**On the real WMS data** the volumes are far smaller, so do not promise a rate
from this run — promise the *shape*. One RUN on 2026-09-16 moved 68 122 rows
across all six sets in under four minutes, divergence 0:

| set | archived = deleted |
|---|---:|
| `ADV_LOGMSG_ARCH` | 53 377 |
| `AAD_TRANLOG_ARCH` | 12 085 |
| `AAD_WORKQ_ARCH` | 3 012 |
| `AAD_ORDER_ARCH` | 1 977 |
| `AAD_PO_ARCH` | 503 |
| `AAD_PICKDETAIL_ARCH` | 168 |

The ORDER figure is the one to talk through: 334 orders in 7 batches, each batch
taking its `t_order_detail`, `t_pack`, `t_container_master` and `t_order_status`
rows with it and deleting the order header **last**. 509 orders stayed, every one
of them not yet eligible.

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

Results on the settled state:

* **Section C — every gate check 0.** No row in the archive violates the gate it
  was supposed to satisfy. Spot-check live if someone is sceptical: on the seeded
  data, after the pick set completed `AAD.t_pick_detail` held exactly **one** row,
  and it was the one row whose status was not `SHIPPED`.
* **Section D — every orphan check 0.** No archived child lost its parent,
  including `t_rcpt_ship_po`, the junction that links receipts and shipments to POs
  and the one place where archiving a PO could have stranded a live shipment.
* **Section E — archived = deleted, divergence 0.** 1 455 253 on the seeded run;
  68 122 on the real-data run.
* **Section F — deferred exposure, and it is not zero.** 563 containers,
  674 `t_container_detail` and 397 `t_container_station` rows sit in the source
  belonging to orders that are already archived. Say so plainly if it comes up:
  the container family needs its own set and has not got one yet. Nothing is lost
  and nothing is inconsistent — the containers simply have not been archived.

**Run this only when nothing is in flight.** With a batch mid-flight, section C's
child checks legitimately report violations, because ANCHOR archives children before
their header — that is the normal intermediate state, not a fault. Observed during
an interrupted run: 15 012, then 11 097, then **0**, as the batches completed. The
script now prints that warning above section C.

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

**"Why are the containers still there?"** Asked by anyone who watches the counts.
`t_pick_container` is not in the ORDER set, on purpose. It has no foreign key to
`t_order`, so orders archive cleanly without it — but three tables have foreign
keys *into it*, and two of those carry no `order_number`, so an order-keyed set
cannot reach them. They need a set anchored on the container itself. That is
scoped, not forgotten: the exposure is counted every run by `33_verify_bulk.sql`
section F, and the two open decisions are written down in `README.md` under *The
container family*. The honest version is "we found it, we measured it, and we did
not guess at the retention rule for it."

**"Can we get the data back?"** `arch.usp_RestoreFromArchive`, and there is a
console preview for it. It writes into a production source table, so the grant is
withheld by default and a DBA has to make that call deliberately.

---

## If it goes wrong on the day

| Symptom | Cause | Do this |
|---|---|---|
| PREP fails instantly, Error 51001 | job owned by a sysadmin | `sql/55_fix_prep_job_owner.sql`, or `56` on a new instance |
| Stop appears to do nothing | it stopped the run, not the job | `sp_stop_job` |
| A run sits at `RUNNING` forever | worker killed mid-batch | `usp_RecoverStaleRuns @StaleAfterMinutes = 0` |
| Dashboard shows many failed batches | dry-run previews close as `Failed` | read `arch.WorkBatch.Notes` |
| Verification reports gate violations | a batch is still in flight | let it finish, then re-run |
| Nothing is eligible | the reset was not run, or everything is already archived | `99` then `40` (seeded data only) |
| Console shows `databaseOk: false` | app-pool login not in all five roles | `ADMIN-CONSOLE.md`, correction 4 |
| One dashboard panel 503, everything else 200 | a source DB was restored; the console's user went with it (`Msg 916`) | re-run `051`; `ADMIN-CONSOLE.md`, *Two traps* |
| Step 1 fails: *Database 'ADV' is already open* (`Msg 924`) | an SSMS restore left it `SINGLE_USER`; the WMS app took the one slot | `SET SINGLE_USER WITH ROLLBACK IMMEDIATE` then `SET MULTI_USER` — see *Before the room fills* |
| RUN fails: *Unsafe SQL in ... JoinToAnchorPredicateSql* | someone added an ObjectSpec by direct INSERT, past the API gate | `sql/57_order_set_container_family.sql` in plan mode shows which predicate |
| RUN fails on a foreign key | the anchor's set is missing an FK child | the FK-completeness query in `DEPLOYMENT.md` Phase 3 |
