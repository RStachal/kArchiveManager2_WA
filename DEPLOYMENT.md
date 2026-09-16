# Deploying kArchiveManager 2.0 at a customer site

A runbook, not an overview. Every step has a stop condition, and the numbers in
the verification steps are the ones that decide whether to go on. `README.md`
explains *why* the configuration looks the way it does; this file is *what to do*.

Written from an end-to-end deployment on SQL Server 2022, collation
`Czech_CS_AS`, against `AAD` (394 tables) and `ADV` (47 tables), and from the
failures that deployment hit. Where a step exists because something went wrong,
it says so.

---

## The rule that outranks everything else

> **No kArchiveManager object is ever created in a WMS database.**

Only `kArchiveManagerAdmin` and `kArchiveManagerBackups` are written to. Source
databases are **read + delete only** — no indexes, no columns, no constraints, no
triggers.

This is not a preference. An earlier revision created four indexes in `AAD`, two
of them filtered, and **broke the WMS write path**: SQL Server refuses any DML on
a table carrying a filtered index unless the connection has
`QUOTED_IDENTIFIER ON`, and `AAD` has 240 of its 1 147 modules compiled with it
OFF — including 8 active triggers, one of them `tr_order_master_insert` on
`t_order`. With that index in place **no order could be inserted at all**, and
`usp_ValidateConfiguration` did not catch it. Only inserting a row did.

`08_source_indexes.sql` therefore hands index DDL to the schema owner and has no
Apply switch. It verifies a zero footprint on every run (`B_OUR_FOOTPRINT` must
read 0/0). If a step in this runbook asks for an index, it is a request to the
customer's DBA, never something you run.

---

## Before you go on site

| Requirement | Why, and what happens without it |
|---|---|
| SQL Server 2016+ (2019+ preferred) | `AT TIME ZONE`, `STRING_SPLIT` |
| **sysadmin** for the deploy itself | the bundle creates databases, logins and Agent jobs |
| **SQL Agent running** | the bundle installs jobs in Phase 14. With `:on error exit` a stopped Agent **aborts the deploy** and silently loses Phases 14b/14c |
| Source databases ONLINE, compat ≥ 130 | |
| The configured timezone in `sys.time_zone_info` | a missing zone fails the cutoff, not the deploy |
| A checkout of `ArchiveManager1.0` | passed as `-RepoRoot` |
| A password for the runner login | you will be prompted; it never goes in a file that is committed |
| **A maintenance window for the first real run** | the first pass over a backlog is the slowest thing this product ever does — see *Sizing* |

Collations need not match. Archive tables copy collation per column from the
source, and the runner re-collates its key temp table before joining.

---

## Phase 1 — Assess the instance (read-only, safe on production)

```powershell
.\Run-Deploy.ps1 -Server <SRV> -SourceDb <WMS> -Stage precheck
.\Run-Deploy.ps1 -Server <SRV> -SourceDb <WMS> -Stage analyse
```

`precheck` covers version, permissions, Agent state, collation and free space.
`analyse` re-verifies every schema assumption the configuration makes: tables,
columns, the composite key, the CASCADE graph, sentinel defaults and status
domains.

**STOP if `analyse` reports a missing table or column.** The configuration is
built for a specific WA schema version. A missing column means the customer's
version differs and the affected set needs redesigning, not forcing.

### Also do this now, before anything is installed

Two questions decide the whole shape of the deployment, and both are cheap to
answer read-only:

**1. How much data is actually there?**

```sql
SELECT t.name, SUM(p.rows) AS Rows_
FROM sys.tables t JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name IN ('t_tran_log','t_pick_detail','t_work_q','t_order','t_order_detail',
                 't_po_master','t_po_detail','t_pick_task_uom','t_container_master')
GROUP BY t.name ORDER BY Rows_ DESC;
```

**2. Does the WMS already purge any of it?** Anything the application deletes
itself needs no retention from us, and archiving it would race the application.
Check `ADV.dbo.t_adv_control` for `LogPurgeMaximumDays`, `LogPurgeMaximumSize`
and `LogPurgeToSize`, and list the Agent jobs. On the reference instance ADV
purges its log at 30 days and caps the table at 100 000 rows, while **AAD has no
housekeeping job at all**.

---

## Phase 2 — Install the product

```powershell
.\Run-Deploy.ps1 -Server <SRV> -SourceDb <WMS> -Stage deploy `
                 -RepoRoot <path>\ArchiveManager1.0
```

Creates `kArchiveManagerAdmin` and `kArchiveManagerBackups`, deploys the core
bundle, runs the verify and selftest, and applies the 13 variant packs.

**Check the log for `Msg 213`** on `variant_test_pack.sql`. If present, the
checkout predates the fix: `usp_ValidateConfiguration` returns **eight** columns,
not seven — Phase 14b adds a trailing `ActionKey` — and a seven-column
`INSERT ... EXEC` fails. Fixed in `452445f` of the product repo.

---

## Phase 3 — Configure the document sets

```powershell
.\Run-Deploy.ps1 -Server <SRV> -SourceDb <WMS> -AdvDb <ADV> `
                 -Stage configure -RetentionDays 540
```

This runs, in order: `03` analysis, `04`/`05`/`20`/`24`/`25` set configuration,
`26` (the two added children), `27` (the PO set), `06` provisioning and `07`
validation.

### Retention is a decision, not a parameter

`-RetentionDays` applies to the AAD sets. **The ADV log set overrides it**:
`24_seed_logmessage_anchor.sql` clamps that one process to sit inside the
vendor's own purge window and prints `*** RETENTION CLAMPED ***` with the
arithmetic. On the reference instance a requested 90 became **23**, because ADV
deletes at 30 and a 90-day cutoff would select rows the WMS had already removed —
the process would report success with zero rows for ever.

Set a **retention floor** as a guard against a mistyped retention. It ships
disabled:

```sql
EXEC arch.usp_Api_SetRetentionFloor @MinRetentionDays = 365, @RequestedBy = 'dba';
```

### `MaxCandidates = NULL` is a 400 000-row ceiling, not "no limit"

`JOB_DEFAULT` ships with it `NULL`. For a **TIMESTAMP** process that means the
runner computes its own cap of 100 batches × a hard-capped 4 000 rows, so
`AAD_WORKQ_ARCH` cannot move more than **400 000 rows per invocation however long
its window is**, and raising `MaxBatchesPerRun` above 100 changes nothing. Decide
deliberately:

```sql
-- Raises the ceiling for EVERY process in the profile, including the ANCHOR sets,
-- whose candidate preparation then costs more up front (15-17 s per 600 000 keys).
EXEC arch.usp_Api_SaveRunProfile @RunProfileCode = N'JOB_DEFAULT', ...
     @MaxCandidates = 2000000, ...;
```

Leaving it alone is also defensible — a fixed per-run ceiling is easy to reason
about. Just do not assume the window is the only limit.

### Check FK-completeness yourself — the validator does not

`arch.usp_ValidateConfiguration` does **not** compare a set against
`sys.foreign_keys`, and it does **not** run the runtime's SQL safety gate over
`JoinToAnchorPredicateSql` — it checks only that the predicate is *present*. Both
gaps were paid for on the reference instance: PREP passed, validation returned
`0`, and RUN failed on its first batch.

Run this per anchor table, against the customer's schema, and read every row:

```sql
-- every table with an FK into the anchor must be in the set, or the anchor
-- delete fails the moment one of them holds a row for an archived document
SELECT FkChild = OBJECT_NAME(fk.parent_object_id),
       InSet   = CASE WHEN EXISTS (SELECT 1 FROM arch.ObjectSpec o
                                   JOIN arch.Process p ON p.ProcessId = o.ProcessId
                                   WHERE p.ProcessCode = N'<SET>'
                                     AND o.SourceTable = OBJECT_NAME(fk.parent_object_id))
                      THEN 'yes' ELSE '*** MISSING ***' END
FROM <WMS>.sys.foreign_keys fk
WHERE fk.referenced_object_id = OBJECT_ID(N'<WMS>.dbo.<anchor>')
GROUP BY OBJECT_NAME(fk.parent_object_id);
```

A `MISSING` is one of two things, and they need opposite answers:

* the child **carries the anchor key** → add it to the set with a plain
  `t.<key> = k.Key1` join, as `26` section 1b does for the three FK children of
  `t_order` that were missing until 2026-09-16;
* the child **does not carry it** and is reachable only through another table →
  it cannot go in this set at all. The runtime joins `#Keys` to one table with
  only `t` and `k` in scope, and `arch.usp_AssertSafeSqlExpression` refuses the
  subquery that would express the hop (`THROW 50400`). That family needs its own
  set, anchored where the key actually lives.

`26` prints an `FK_COMPLETE_ORDER` block for exactly this reason, and
`57_order_set_container_family.sql` prints the safety-gate verdict for every
predicate in a set. Run `57` in plan mode on any instance you did not build
yourself.

**STOP if `07_validate.sql` reports any blocker**, or if the FK check above prints
a `MISSING` you have not decided about. Index WARNs are expected and are not
blockers; see Phase 4.

---

## Phase 4 — Hand the index requests to the DBA

```powershell
.\Run-Deploy.ps1 -Server <SRV> -SourceDb <WMS> -Stage analyse   # 08 runs read-only
```

`08_source_indexes.sql` prints the indexes the configuration would benefit from,
the QUOTED_IDENTIFIER exposure of each target table, and DDL for the schema owner
with **no filtered predicates**. Send section C to the customer's DBA.

Two things to say when you send it:

- **The validation cannot tell you whether an index actually helps.**
  `usp_ValidateIndexRequirements` warns only when *no* index contains the required
  columns **as key columns** — it does not check whether they *lead*. On the
  reference instance `t_pick_task_uom`'s requirement on `pick_id` validates clean
  while the delete join scans a heap, because `pick_id` is the fifth key column of
  the only index. Read the index definition; a green validation is not a seek.
- The `arch.IndexRequirement.Notes` field records the truth per requirement,
  including which ones are marked MISSING.

Deploying without these indexes works. It is just slower, and the retention scan
reads whole tables.

---

## Phase 5 — Runner login and job ownership

```powershell
.\Run-Deploy.ps1 -Server <SRV> -SourceDb <WMS> -Stage runtime
```

Prints the manual steps for `053` (runner login, least-privilege grants) and `054`
(job ownership). Run them with a real password.

Three things that cost time if forgotten:

- **`053` must be re-run after ANY configuration change that adds a table.** The
  grants are computed from the tables mapped at that moment. Add a table, skip
  `053`, and the run fails with `SELECT permission was denied`. This bit twice
  during development.
- **The privilege gate refuses a sysadmin, by design.**
  `usp_VerifyRunnerPrivileges` checks the *caller's* rights, so testing as
  yourself reproduces a failure the real job would not have. That is why
  `22_simulate_job.sql` impersonates the runner with `EXECUTE AS`.
- The password belongs in your password manager, not in the repo. `.gitignore`
  excludes `*.RUN.sql` for this reason.

---

## Phase 6 — Prove it on the customer's data, before deleting anything

```powershell
.\Run-Deploy.ps1 -Server <SRV> -SourceDb <WMS> -AdvDb <ADV> -Stage test
```

Runs `09_preflight_data.sql`, seeds test documents, and does a **dry pass that
deletes nothing**.

`09_preflight_data.sql` is the most important read of the whole deployment. Its
nine sections measure the customer's actual data against every assumption:
volume, sentinel dates, status domains, key consistency, FK blockers, key
uniqueness and dependency stranding. **Read it before going further**, and treat
any STOP verdict as a stop.

Then review `_logs\22_simulate_job.log`. The dry pass shows what *would* be
touched.

> A TIMESTAMP dry run reports `DocsDone = 0`. That is an artefact of the dry-run
> path, not an empty candidate set. Use the real run or `09` to size a TIMESTAMP
> set.

---

## Phase 7 — First real run, in a window

```powershell
.\Run-Deploy.ps1 -Server <SRV> -SourceDb <WMS> -AdvDb <ADV> `
                 -Stage realrun -IConfirm
```

Replays both Agent job steps for real, then verifies.

### The three numbers that decide pass or fail

| Check | Where | Must be |
|---|---|---|
| **Divergence** (archived − deleted) | `23_verify_standalone.sql` section B | **0**, on every table |
| **Orphans** | section C, `C_ORPHAN_CHECK` | **0 / 0 / 0** |
| Gated documents | the expectation table | all survivors present |

Divergence is the one that matters most: a non-zero value means a row was deleted
without being copied. **If divergence is not zero, stop and restore from the
archive** (`13_restore.sql`) before doing anything else.

### Expect several runs, and know why

A set stops when **whichever comes first**: the window closes, the candidate cap
is reached, or the eligible rows run out. The ORDER and PO sets cap at
`BatchDocCount 50 × MaxBatchesPerRun 200 = 10 000 documents per run`, so a
backlog of 20 000 documents needs two runs — that is not a fault. Re-run until
`B_ELIGIBLE` reaches zero or stops falling.

### Sizing the first pass

Measured on the reference instance, no custom indexes in the WMS, one minute per
set:

| Set | Rows in 1 min | Rows/s |
|---|---|---|
| `AAD_WORKQ_ARCH` | 342 638 | **5 711** |
| `AAD_TRANLOG_ARCH` | 147 100 | **3 976** |
| `AAD_PICKDETAIL_ARCH` | 127 508 | **3 643** |
| `ADV_LOGMSG_ARCH` | 83 577 | **1 520** |
| `AAD_PO_ARCH` | 53 652 | **941** |
| `AAD_ORDER_ARCH` | 36 582 | **642** |

Take these as an order of magnitude, not a promise. Three consecutive runs on the
same instance with the same data varied by up to **2×**, and the variance was
entirely in the write phase — `WRITELOG` is the dominant wait. Measure on the
target instance, three times, before quoting a completion date.

### The thing that will actually slow you down

**Throughput is governed by the source database's transaction log, not by the
archiver's settings.** On the reference instance `AAD` reached 38 GB in FULL
recovery with `log_reuse_wait_desc = LOG_BACKUP` and 10 % autogrowth — growth
events of 2 162 MB blocking for 2.5 s each. Before the first pass:

- pre-size the source log for the volume you are about to delete;
- change autogrowth from a **percentage to a fixed MB**;
- make sure **log backups are running** so the log can be reused;
- if the customer can accept it, a bulk-logged interval for the first pass only.

`41_perf_test.sql` prints a `CONDITIONS` section with the recovery model, log
reuse wait and log size of every database involved. Capture it with every
measurement — two results are not comparable without it.

---

## Phase 7b — Reporting

The reporting layer ships **with the core bundle** — there is no separate install.
It is 20 `arch.usp_Frontend_*` procedures, `arch.usp_Api_EstimateNextRunImpact`
and six views, and it is driven entirely by `arch.Process` / `arch.ObjectSpec`, so
it describes whatever is configured without carrying any table names of its own.

Verify it, and prove it answers for the customer's configuration:

```powershell
sqlcmd -S <SRV> -E -b -I -i sql\50_reporting.sql
```

| Section | Must show |
|---|---|
| `A_SUMMARY` | `ok - reporting layer present` (20 Frontend + 1 Api + 6 views) |
| `B_VERDICT` | `Failed = 0` — every reporting procedure executed against this schema |
| `C` | per-set and per-table source vs archive, and go-live readiness |
| `D` | three output artefacts that look like defects and are not |

`A_SUMMARY` reporting INCOMPLETE means the core bundle did not finish — the
reporting procedures come with it, so re-run `-Stage deploy`.

### The SSRS dashboard is not a drop-in

`reports\ArchiveManager - DataMovement Dashboard v2.rdl` comes from the product
repository, but it was last changed **13 days before** the 2.0 cleanup that
retired two of the procedures it calls, and it was written against a **different
customer's WMS schema** — it hardcodes `SHIPHIST`, `RF_LOG2` and `DATE_UPLD`.

Executed dataset by dataset against the reference deployment: **6 of 13 work, 4
are silently wrong, 3 fail outright.** The silently-wrong four are the problem —
a panel that throws gets fixed, a panel that renders an empty chart gets believed.

Read [`reports/README.md`](reports/README.md) before offering it to a customer. It
carries the dataset-by-dataset result and the live procedure that replaces each
panel. Treat the RDL as a layout to rework, not as a finished report.

---

## Phase 7c — Admin Console (optional, but expect a day of it)

The console is the customer-facing UI for everything above: dashboard,
configuration, validation, run history, document lookup and the go-live gate. It
ships in the handover package as an IIS application and it does **not** run as
shipped.

Six things in it contradict its own documentation — a native driver asset the
publish never declares, a `.exe` that does not exist, the wrong target framework
in two documents, and three permission gaps the shipped scripts do not close. Two
of the three fail **silently**: `databaseOk: false` with `missingRoles: []`, and a
login box that rejects a correct password while reporting nothing.

Every one of them is written up, with the reproduction and the fix, in
[`ADMIN-CONSOLE.md`](ADMIN-CONSOLE.md). Work through its **Deployment order**
section; do not follow the handover IIS runbook alone.

The one rule worth repeating here: **verify as the app-pool identity.** Running
the console with Kestrel under an interactive sysadmin account passes every check
and proves nothing — all three permission gaps are invisible that way.

---

## Phase 8 — Hand over to the schedule

1. Confirm the Agent job `kArchiveManager - RUN CONFIGURED` is owned correctly
   (`054`) and enabled.
2. Confirm `kArchiveManager - RECOVER STALE RUNS` is enabled — it closes runs
   whose worker died.
3. **Set up alerting.** `047_operational_alerting` needs an SMTP server and
   creates Database Mail, an operator, job failure notification and a HEALTH
   ALERT job. Go-live readiness reports WARN until this is done.
4. **Back up the archive database.** `048` creates FULL + LOG jobs.
   `kArchiveManagerBackups` is the system of record for every deleted row — an
   unbacked-up archive turns archiving into deletion. Do a restore drill.
5. Remove the test footprint:

```powershell
.\Run-Deploy.ps1 -Server <SRV> -SourceDb <WMS> -Stage cleanup -IConfirm
```

---

## Optional — measure throughput on the customer instance

Only where seeding several hundred thousand test rows into the WMS is acceptable.
It archives and deletes them again, and temporarily lifts the batching caps and
disables the ADV log purge job.

```powershell
.\Run-Deploy.ps1 -Server <SRV> -SourceDb <WMS> -AdvDb <ADV> -Stage perf -IConfirm
.\Run-Deploy.ps1 -Server <SRV> -SourceDb <WMS> -Stage cleanup -IConfirm
```

Read `41_perf_test.log` in this order — the checks come before the numbers:

1. `CAPS_RESTORED` / `VENDOR_JOB_RESTORED` — nothing was left changed
2. `COVERAGE` — every set produced a run
3. `VALIDITY` — `StillEligible > 0`, or the figure is a volume and not a rate
4. `PURGE_INTERFERENCE` — must be empty for the ADV figure to be clean
5. `CONDITIONS` — the log state the numbers were produced under
6. `PERF_BY_TABLE` — the per-table answer

The perf stage runs `42_perf_restore.sql` from a `finally`, so the undo fires even
if the measurement dies. If the whole PowerShell session died, run
`-Stage perfrestore` by hand.

---

## If something goes wrong

| Symptom | Cause | Action |
|---|---|---|
| `SELECT permission was denied` on a source table | a table was added to the configuration after `053` | re-run `053` |
| `Error 51000` / `51001` at job step 1 | privilege gate: the caller is a sysadmin, or a grant is missing | run as the runner login; `usp_VerifyRunnerPrivileges` prints the fix |
| `Msg 1934` on a WMS insert | a filtered index exists on a source table | drop it. Check `08` section B; the house rule exists for this |
| `Msg 547` on a header delete | a child with an enforced FK is not in the set | add it, or find why it is unreachable from the keyset |
| Divergence ≠ 0 | rows deleted without being archived | **stop.** `13_restore.sql`, then investigate |
| Run reports `Status OK`, `DocsDone` large, `RowsDeleted` 0 | a `Paused` WorkBatch was resumed under its **original** cutoff, and the rows it names are gone | see below |
| `OPEN_WORKBATCH` in `v_OperationalHealth` | a run was cut short and left candidates prepared | normal — the next run resumes them. Only clear them if the underlying rows were replaced |
| Validation WARN on an index | expected | Phase 4; not a blocker |

### The `Paused` batch trap, in full

A run cut short by its window leaves its `WorkBatch` in status `Paused` with the
unprocessed keys attached, **on purpose**: the next run resumes it under the
cutoff it was prepared with, so a long backlog is worked in consistent slices.

That becomes wrong the moment the underlying rows are *replaced* rather than
processed — which is what re-seeding test data does, because IDENTITY values
change. Two sets once reported `Status OK`, `DocsDone` 78 000 and 210 000 and
`RowsDeleted` **0**: a result that looks like a measurement and is not one. A
third set was worse — its keys were natural, so they still matched, and it deleted
47 800 rows against a cutoff from three days earlier.

`usp_CloseDryRunWorkBatches` does not help; it closes dry-run batches only, as its
name says. In the package, the script that deletes the rows invalidates the keys.
By hand:

```sql
-- NEVER on a production backlog: a Paused batch there holds real pending work,
-- and discarding it means those rows are skipped until some later run happens to
-- select them again.
UPDATE arch.WorkBatch
SET Status = N'Failed', CompletedAtUtc = SYSUTCDATETIME()
WHERE Status NOT IN (N'Completed', N'Failed');
```

### Disabling an Agent job does not stop it running

`sp_update_job @enabled = 0` suppresses only *schedule*-driven execution. An
explicit `sp_start_job` runs a disabled job. On the reference instance the WA
service does exactly that — msdb history shows `The Job was invoked by User HJS`
while the job was disabled, in the middle of a measurement, and it trimmed
`t_log_message` mid-run. Verify from `msdb.dbo.sysjobhistory` that a job did not
run; never trust the flag.

---

## Evidence from the reference deployment

What was actually proven, so a customer conversation can be specific.

**Volume correctness.** 21 of 22 configured tables seeded to between 10 000 and
100 000 rows (`t_pack` is structurally capped at 7 — its primary key is
`(id, wh_id)` and `id` is a foreign key to `t_employee`), ~534 000 rows in total,
with **20 % of every set deliberately gated**. Three real runs:

- **593 836 rows archived = 593 836 deleted, divergence 0**
- **all 12 gate checks 0** — nothing that should have been held reached the
  archive: no non-terminal status, nothing inside the retention window, no
  container without an archived order, no `task_uom` without an archived pick, and
  no archive table at all for `t_rcpt_ship`, which is in no set
- **all 9 orphan checks 0**
- reconciliation: `source + archive` equalled the seeded count for **every** table
- `v_OperationalHealth`: no non-OK rows

The gated rows were given the exact attribute each set's gate tests, so a gated
row reaching the archive would have meant the predicate matched too much. That is
the test behind "only the configured records were processed" — `33_verify_bulk.sql`
section C.

**Functional gates.** Separately, 15 hand-built gated cases survived, each for a
different reason: non-terminal status, `lock_flag`, `consolidated_order_number`,
the `1900-01-01` sentinel, and simply too recent. A run that deletes everything
old is not a pass.

**Throughput.** Six sets, one minute each, five of the six stopped by the clock
rather than by running out of data. Figures in Phase 7.

**Limits of this evidence.** The reference instance has no operational data of its
own — its largest table is `t_schema_history` at 1 522 rows — so structure and
correctness were established there, never real-world volume or data shape. The
customer's data will differ, which is what Phase 6 is for.
