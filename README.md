# kArchiveManager 2.0 — deployment package for Koerber Warehouse Advantage

Deploys, configures and tests kArchiveManager 2.0 against a Koerber WA / K.Motion
schema, as **six document sets** with a header → detail hierarchy.

Built and verified end-to-end on **SQL Server 2022, collation `Czech_CS_AS`**,
against `AAD` (394 tables) and `ADV` (47 tables). Every script here has been
executed on that instance; the notes below record what actually happened.

**Deploying at a customer site: follow [DEPLOYMENT.md](DEPLOYMENT.md).** It is the
runbook — eight phases with a stop condition on each, plus 7b (reporting) and 7c
(the console). This file explains *why* the configuration looks the way it does.

**Showing it to an audience: follow [PRESENTATION.md](PRESENTATION.md).** The demo
script, the measured numbers, and the four places a live walkthrough goes wrong —
including a job that fails one second after it starts unless `55` has been run.

**The Admin Console** (the web UI, an IIS application) is in
[`kAM2/02-admin-console/`](kAM2/02-admin-console/), deployed and verified on this
server at `http://localhost:8089`. [ADMIN-CONSOLE.md](ADMIN-CONSOLE.md) records the
six corrections it needed before it would run, three of them permission gaps the
shipped scripts do not close, two of which fail silently.

---

## What is in this repository

Two layers, and it matters which one you are looking at.

```
kAM2/                       THE PRODUCT - the vendor handover, complete
  01-database/              deploy bundle, source objects, operational add-ons,
                            manual tests, performance tests
  02-admin-console/         the published ASP.NET Core app (net10.0) + sample config
  03-docs/                  23 documents, incl. the admin manual
  04-runbooks/              7 runbooks, incl. customer-deploy and console-on-IIS
  05-training/              L1-L2 training material

README.md DEPLOYMENT.md     THIS DEPLOYMENT - the Warehouse Advantage configuration,
ADMIN-CONSOLE.md            what was corrected, and what was measured
PRESENTATION.md
sql/                        the six document sets, their seeds, tests and verification
reports/                    the SSRS dashboard, and why it does not fit as shipped
```

`kAM2/` is the product as the vendor shipped it, with **one deliberate change**:
`02-admin-console/app/KArchiveManager.AdminConsole.Api.deps.json` carries the native
`Microsoft.Data.SqlClient.SNI.dll` asset declaration. Without it the console cannot
open a SQL connection under IIS at all — see correction 1 in
[ADMIN-CONSOLE.md](ADMIN-CONSOLE.md). The file here is byte-identical to the one
running on this server.

Everything outside `kAM2/` is this deployment: the configuration, the evidence, and
the defects found while proving it. Where the two disagree about product deployment,
the vendor runbooks win; where they disagree about the six WA document sets, this
package wins. The table at the end of [ADMIN-CONSOLE.md](ADMIN-CONSOLE.md) says
which is authoritative where.

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

## The six document sets

Each set has ONE header table and its details. Details are deleted first, the
header last. **No table appears in two sets** — enforced by the `OVERLAP_CHECK`
in `25_seed_document_sets.sql`, and repeated in `26` and `27`.

| RunOrder | Process | Strategy | Header (deleted last) | Details (bottom-up) |
|---|---|---|---|---|
| 10 | `AAD_PICKDETAIL_ARCH` | ANCHOR | `t_pick_detail` | `t_allocation`, `t_pick_task_uom` |
| 20 | `AAD_TRANLOG_ARCH` | ANCHOR | `t_tran_log` | `t_tran_log_reason`, `t_tran_log_sn` |
| 30 | `AAD_ORDER_ARCH` | ANCHOR | `t_order` | `t_order_detail_comment` → `t_order_comment` → `t_order_detail` → `t_pack` → `t_container_master` → `t_order_status` → `t_geek_pick_order` |
| 40 | `AAD_WORKQ_ARCH` | TIMESTAMP | `t_work_q` | `assignment`, `dependency` (both sides) |
| 50 | `ADV_LOGMSG_ARCH` | ANCHOR | `t_log_message` | — |
| 60 | `AAD_PO_ARCH` | ANCHOR | `t_po_master` | `t_po_detail_comment` → `t_po_comment` → `t_po_detail` → `t_rcpt_ship_po` |

`t_pick_task_uom` was added by `26` after the data-model analysis; `AAD_PO_ARCH`
is the inbound set added by `27`. See *The inbound side* below for why purchase
orders needed a set of their own.

**The ORDER set is FK-complete, and that took two attempts.** `sys.foreign_keys`
lists six tables referencing `t_order`; three of them — `t_container_master`,
`t_order_status`, `t_geek_pick_order` — were missing until 2026-09-16, and on real
data the `t_order` delete fails on the foreign key the moment one of them holds a
row. `26` section 1b adds them, conditionally: `t_geek_pick_order` is a Geek+
robotics extension and will not exist on every site.

`t_pick_container` is **not** in the set, for the opposite reason — see
*The container family* below.

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
| `t_label` | No `pick_id`; reachable only via `t_allocation.allocation_id`. Out of scope rather than guessed. |
| `t_tran_log_holding`, `_reason`, `_sn` | Pre-commit staging that `usp_process_tran_log` drains **to empty**: it takes `MAX(tran_log_holding_id)` as a high-water mark, copies the rows into `t_tran_log`, deletes everything `<=` that mark with no filter at all, then loops until the table is empty. Its rows are transactions **in flight**. Accumulation there means the drain is broken — and those are exactly the rows that must not be deleted. |
| `t_sto_attrib_collection_master`, `_detail` | Looks like a child of `t_pick_detail` and `t_order_detail` (both carry `stored_attribute_id`), but it has a **`detail_checksum`** column and is referenced by **nine** tables including `t_stored_item` (live inventory) and `t_bom_detail`. It is a content-deduplicated shared pool. Deleting a collection because one pick aged out would break every other row sharing that checksum. |
| Cartonisation / optimiser: `t_cartonize_results`, `t_container_optimize_block` / `_status` / `_xml` | The application purges them itself by `cartonization_batch_id` — `usp_cartonize_q` runs our exact candidate predicate, and `usp_afa_hold_shipment` / `usp_afo_hold_wave` delete all three optimiser tables. Their `order_number` and `hu_id` are also **nullable**, so an order-anchored predicate would only ever half-clear them while looking complete. |
| `t_item_uom`, `t_pick_put_master` / `_detail`, `t_item_master` | Master and configuration data. `t_item_uom` alone is referenced by 88 modules. Note that `pick_put_id` is a pick/put **profile** — a different concept from `pick_id`. |
| `ADV.t_log_message_action` | Name suggests a child of `t_log_message`; it is a log-*level* configuration table (`application_id`, `action_type`, `log_level_override`) with no relationship to it at all. |

**`t_pick_container` left this list, was added to the ORDER set, and has now been
taken out again.** Each step was right on the evidence available at the time, and
the sequence is worth keeping because the third step is the one that matters.

It was first excluded as "reachable only via `t_allocation.allocation_id`" — wrong;
it carries `order_number` + `wh_id` directly. `26` therefore added it to the ORDER
set at `DeleteOrder` 45, and the throughput tests passed. They passed because the
seeded containers had no children. See *The container family*.

---

## The container family, and why it is deferred rather than configured

`t_pick_container` has three tables carrying an enforced, trusted foreign key
**into** it on `(wh_id, container_id)`:

| child | FK since | rows on the reference data |
|---|---|---:|
| `t_container_detail` | 2024-02 | 1 443 |
| `t_container_station` | 2024-01 | 711 |
| `t_container_master` | 2024-01 | 1 010 |

Delete a container while any of them still references it and the delete fails.
`t_container_master` is fine — it carries `order_number`, so it joins to the ORDER
set plainly and is configured there at `DeleteOrder` 43. The other two **do not
have `order_number`**. Their only path to the order runs through
`t_pick_container`, and the runtime builds

```sql
DELETE t FROM <table> t INNER JOIN #Keys k ON <JoinToAnchorPredicateSql>
```

with only `t` and `k` in scope. Expressing the hop needs a subquery, and
`arch.usp_AssertSafeSqlExpression` refuses subqueries — `THROW 50400`.

So the container family needs a **set of its own**, anchored on `t_pick_container`
with keys `(container_id, wh_id)`, where every child join is a plain equality. Two
decisions belong to the data-model owner before that set is written:

1. **The gate.** Container status is not a proxy for order completion here: 575 of
   1 039 `ACTIVE` containers sit on orders that are already `SHIPPED`. A cutoff on
   `actual_ship_date` is the honest option, not a status test.
2. **`t_container_master` has two parents** — foreign keys to both `t_order` and
   `t_pick_container` — so it must be deletable by either set. Configuring one
   table in two sets is allowed (`t_work_q_dependency` already is); whichever set
   runs first takes the rows and the other finds nothing.

Until then containers of archived orders stay in the source. That exposure is
**measured, not hidden**: `33_verify_bulk.sql` section F counts it every run. On
the reference data after the first real-data run: 563 containers, 674
`t_container_detail` rows, 397 `t_container_station` rows.

---

## The inbound side, and why it needed its own set

The five original sets cover **outbound** (orders, picks) and the logs. Inbound had
no retention at all, and the WMS does not clean it up:
`usp_util_close_inbound_order` sets `t_po_master.status = 'C'` and
`closed_date = CONVERT(DATE, GETDATE())` — and contains **no `DELETE` at all**. The
only code that removes real PO rows is `usp_al_import_inbound_order`, and only when
the host sends `processing_code = 'Delete'`. `AAD` has **no SQL Agent housekeeping
job whatsoever** — the only purge job on the instance is ADV's own `Log Maintenance`.
So a closed purchase order stays for the life of the database.

`AAD_PO_ARCH` is therefore the direct mirror of the ORDER set: `pk_po_master` is
`(po_number, wh_id)`, so the composite natural key is unique by definition, and the
children hold `NO_ACTION` FKs to the header, which forces ANCHOR for the same
reason as `t_tran_log`.

**The cutoff is `closed_date` alone, with no fallback.** The ORDER set needs
`COALESCE(NULLIF(actual_ship_date,'19000101'), order_date)` because `t_order`
defaults its nullable datetimes to the 1900 sentinel. `t_po_master.closed_date` has
no default, is NULL until closing, and is written by the same statement that sets
`status = 'C'`. Adding a `create_date` fallback would archive **open** purchase
orders. Don't.

### `t_rcpt_ship_po` is a junction between two documents — read before enabling

It links a PO to an inbound shipment (`t_rcpt_ship`), with a `NO_ACTION` FK to
`t_po_master` and a `CASCADE` FK from `t_rcpt_ship`. Three consequences:

- It **must** be in the set. Leaving it out makes the header delete fail with
  `Msg 547` for every PO ever received against a shipment.
- Archiving a PO therefore removes that shipment's link to it. That is inherent to
  archiving the PO at all — keeping the junction while deleting the PO would leave
  it pointing at nothing, and the FK forbids it regardless.
- The rows are preserved **in the archive** next to the PO, so the fact stays
  recoverable; only the live shipment view loses it.

The ideal gate — *only archive a PO whose linked shipments are also closed* —
**cannot be expressed in configuration**. `arch.usp_AssertSafeSqlExpression` refuses
any subquery (probed directly: `NOT EXISTS` → `THROW 50400`, while a plain
status/date predicate, an `AT TIME ZONE` cutoff and a `CASE` expression are all
accepted), and `t_po_master` carries no "received" flag to test instead. Section D
of `27_seed_po_set.sql` therefore **measures** the exposure — how many eligible POs
link to a shipment that is still open — so it is a decision taken with a number
rather than a surprise. `31_test_data_po.sql` includes `KAMPO-6` for exactly this
case: it *is* archived despite its open shipment, and if section D reports 0 while
that row exists, section D is broken.

### Test result for the inbound set

| PO | Expected | Outcome |
|---|---|---|
| `KAMPO-1` | ARCHIVE, full depth | 7 rows |
| `KAMPO-2` | ARCHIVE, minimal | 2 rows |
| `KAMPO-6` | ARCHIVE despite open shipment | 3 rows |
| `KAMPO-3` | KEEP — status `O` | survived |
| `KAMPO-4` | KEEP — closed 10 days ago | survived |
| `KAMPO-5` | KEEP — `closed_date` NULL | survived |

3 documents, **12 archived = 12 deleted, divergence 0**, per table
`t_po_master` 3 / `t_po_detail` 4 / `t_po_comment` 1 / `t_po_detail_comment` 2 /
`t_rcpt_ship_po` 2. Both shipments still present — `t_rcpt_ship` is in no set and
was not touched. Orphan check 0/0/0. `KAMPO-6`'s link row is in the archive.

The `t_po_detail_comment` count is the delete-order proof: it cascades from
`t_po_detail`, so if the archiver deleted the detail before copying the comments,
the cascade would destroy rows that were never archived and archived would fall
below deleted.

### Test result for the added children

`t_pick_task_uom` 1 archived = 1 deleted, divergence 0.

`t_pick_container` also passed this test — 1 archived = 1 deleted, the container on
a **held** order survived, and the one with `order_number` NULL was left in place.
**That result was correct and still misleading**, which is the lesson worth
keeping: the test rows had no `t_container_detail` or `t_container_station`
children, so the foreign key that makes the delete impossible on real data was
never exercised. A child table proved safe against data that lacked the very rows
that break it. The table is no longer in the set — see *The container family*.

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

## Correctness at volume — were ONLY the configured rows processed?

The functional test (66 rows, 15 gated cases) proves the gates work. It does not
prove they still work when there are hundreds of thousands of rows, and it cannot
prove that a predicate does not match *too much* — with a handful of documents,
an over-matching predicate and a correct one look the same.

So `40_perf_seed.sql` seeds every table of every set to **10 000–100 000 rows**
and makes **20 % of each set deliberately gated**, using the exact attribute that
set's gate tests:

| Set | Eligible | Gated, and why it must survive |
|---|---|---|
| `AAD_TRANLOG_ARCH` | `start_tran_date` past the cutoff | dated **inside** the retention window |
| `AAD_PICKDETAIL_ARCH` | status `SHIPPED`, old | status `PICKED` — not terminal |
| `AAD_WORKQ_ARCH` | `work_status` `C`, old | `work_status` `R` — outside `(C,P)` |
| `AAD_ORDER_ARCH` | status `S`, shipped long ago | status `U` — not terminal |
| `AAD_PO_ARCH` | status `C`, closed long ago | status `O` — still open, `closed_date` NULL |

21 of 22 tables landed in the band; `t_pack` holds 7 rows because its primary key
is `(id, wh_id)` and `id` is a foreign key to `t_employee` — seven employees on
K01, so seven rows, whatever the order volume.

### Result: three real runs over ~534 000 seeded rows

| Check | Result |
|---|---|
| Rows archived vs deleted | **593 836 = 593 836, divergence 0** |
| Gate violations in the archive (12 checks) | **all 0** |
| Orphan checks (9 relationships) | **all 0** |
| Reconciliation `source + archive` vs seeded | **equal for every table** |
| `v_OperationalHealth` | no non-OK rows |

The gate check is asked of the **archive**, not the source, and that is the point:
a source count cannot distinguish "correctly kept" from "wrongly never selected".
Asking whether the archive contains a row that should have been held gives a
yes/no answer with no interpretation. All twelve came back 0 —

- no order outside status `(S,D)`, and none inside the retention window;
- no pick outside `SHIPPED`, and none inside the window;
- no `t_tran_log` row inside the window;
- no work queue outside `(C,P)`, and none inside the window;
- no PO outside status `C`, and none with a NULL or too-recent `closed_date`;
- no `t_container_master` whose order is still in the source, and no
  `t_pick_task_uom` whose pick is still in the source — the added children do not
  over-match;
- and **no archive table at all for `t_rcpt_ship`**, which is in no set.

`ORDER` and `PO` each needed exactly two runs, as predicted from
`BatchDocCount 50 × MaxBatchesPerRun 200 = 10 000 documents per run` against
20 000 eligible documents. That is a cap doing its job, not a failure —
`33_verify_bulk.sql` section B distinguishes the two.

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

### Per set — the run that covered all six

| Set | Strategy | Documents | Rows in 1 min | Elapsed | Rows/s | Prepare |
|---|---|---|---|---|---|---|
| `AAD_WORKQ_ARCH` | TIMESTAMP | 244 000 | **342 638** | 60 s | **5 711** | — |
| `AAD_TRANLOG_ARCH` | ANCHOR | 106 000 | **147 100** | 37 s | **3 976** | 15 s |
| `AAD_PICKDETAIL_ARCH` | ANCHOR | 58 000 | **127 508** | 35 s | **3 643** | 17 s |
| `ADV_LOGMSG_ARCH` | ANCHOR | 83 577 | **83 577** | 55 s | **1 520** | 2 s |
| `AAD_PO_ARCH` | ANCHOR | 10 700 | **53 652** | 57 s | **941** | 1 s |
| `AAD_ORDER_ARCH` | ANCHOR | 6 650 | **36 582** | 57 s | **642** | 2 s |
| | | | **791 057** | | | |

**Five of the six were stopped by the clock**, with 49 300 – 556 000 rows still
eligible per set, so those are rates and not volumes. `ADV_LOGMSG_ARCH` drained
its whole allowed population in 55 s — structural, not a seeding mistake: ADV caps
`t_log_message` at 100 000 rows, so its entire archivable population is smaller
than one minute of throughput.

### Per table

| Set | Table | Rows in 1 min | Rows/s |
|---|---|---|---|
| `AAD_WORKQ_ARCH` | `t_work_q` | 244 000 | **4 067** |
| | `t_work_q_assignment` | 49 319 | 822 |
| | `t_work_q_dependency` | 49 319 | 822 |
| `AAD_TRANLOG_ARCH` | `t_tran_log` | 106 000 | **2 865** |
| | `t_tran_log_reason` | 20 550 | 555 |
| | `t_tran_log_sn` | 20 550 | 555 |
| `AAD_PICKDETAIL_ARCH` | `t_pick_detail` | 58 000 | **1 657** |
| | `t_pick_task_uom` | 58 000 | **1 657** |
| | `t_allocation` | 11 508 | 329 |
| `ADV_LOGMSG_ARCH` | `t_log_message` | 83 577 | **1 520** |
| `AAD_PO_ARCH` | `t_po_detail` | 21 400 | 375 |
| | `t_po_detail_comment` | 10 776 | 189 |
| | `t_po_master` | 10 700 | 188 |
| | `t_po_comment` | 5 388 | 95 |
| | `t_rcpt_ship_po` | 5 388 | 95 |
| `AAD_ORDER_ARCH` | `t_order_detail` | 13 300 | 233 |
| | `t_order` | 6 650 | 117 |
| | `t_order_comment` | 6 650 | 117 |
| | `t_pick_container` † | 6 650 | 117 |
| | `t_order_detail_comment` | 3 330 | 58 |
| | `t_pack` | 2 | — |

`Divergence` (archived − deleted) was **0** on every table, `COVERAGE` reported all
six sets measured, and `PURGE_INTERFERENCE` was empty so the ADV figure is clean.

† `t_pick_container` was in the ORDER set when this was measured and is not any
more (*The container family*). The row is left as recorded rather than deleted —
the measurement happened. Its rate is also the reason the removal costs nothing
in throughput terms: at 117 rows/s it was never the constraint.

### Earlier runs, for the variance

Three earlier runs of the five original sets gave `t_pick_detail`
2 372 / 4 364 / 4 278 rows/s and `t_log_message` 2 949 / 2 940 / 1 500 — **up to a
factor of two apart**, with a different set as the outlier each time. Treat any
single figure above as an order of magnitude.

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
| `26_add_pick_order_children.sql` | **yes** (config) | Adds `t_pick_task_uom` to the PICKDETAIL set, and the three missing FK children of `t_order` (`t_container_master`, `t_order_status`, `t_geek_pick_order` — the last skipped where the site has no Geek+ extension). Records why the other 51 candidates were rejected, and why `t_pick_container` is **not** added |
| `27_seed_po_set.sql` | **yes** (config) | Sixth set: purchase orders (`AAD_PO_ARCH`). Section D measures the shipment-link exposure that cannot be gated in configuration |
| `31_test_data_po.sql` | **yes** (test rows) | Six purchase orders: three archived, three held for three different reasons, plus the open-shipment case |
| `32_test_data_children.sql` | **yes** (test rows) | Self-contained cases for the two added children, including a container with `order_number` NULL that must survive |
| `33_verify_bulk.sql` | no | The volume test's verdict: reconciliation, completeness, **12 gate checks against the archive**, 8 orphan checks, divergence and health, plus section F measuring the deferred container exposure. Section C is the "only the configured rows" test — read the timing caveat printed above it |
| `50_reporting.sql` | no | Verifies the 2.0 reporting layer is deployed, **executes all 19 reporting procedures** against the live configuration, prints per-set and per-table movement plus go-live readiness, and documents three output artefacts that look like defects and are not |
| `40_perf_seed.sql` | **yes** (test rows) | Bulk seed for throughput measurement: ~2.6 M eligible rows across all 14 tables, sized so a 60-second run cannot drain it. Invalidates stale candidate batches, keeps ADV under the vendor size cap |
| `41_perf_test.sql` | **DELETES** | One-minute run per set through the impersonated runner; per-table and per-set rates, prepare/process split, validity, coverage and vendor-purge interference checks. Lifts and restores the batching caps |
| `42_perf_restore.sql` | **yes** (restore) | Undoes all three things `40`/`41` change outside their test data: the batching caps and the vendor job (from `perf.TestBaseline`) and the generated `PERF_*` profiles. `-Stage perf` runs it in a `finally`, so it fires even when the measurement dies mid-way. Idempotent — safe on an instance where the perf scripts never ran |
| `55_fix_prep_job_owner.sql` | opt-in | Re-owns `PREP CONFIGURED` to the runner login. Without it the PREP job **fails every time it is started** — it carries the runner privilege gate but `054` re-owns only `RUN CONFIGURED`, so the gate evaluates a sysadmin and refuses. Evaluates the gate as the runner first. Use on an **existing** instance |
| `56_agent_jobs.sql` | opt-in | All **five** Agent jobs in one script — PREP, RUN, RECOVER STALE RUNS and the two archive backups — with the ownership, schedules and step text this deployment was tested with, and both runner jobs owned correctly from the outset. Use when **building** an instance; it replaces the job-creating parts of `028`/`036`/`048`/`054` rather than supplementing them |
| `57_order_set_container_family.sql` | opt-in | Removes `t_pick_container` and the two container children from the ORDER set on an instance where an earlier revision of `26` added them, or where someone added them by hand. Prints the runtime safety gate's verdict on **every** join predicate in the set first, then proves FK-completeness against `sys.foreign_keys`. Writes a `ConfigChangeSet` record, because the product has no delete API for `ObjectSpec` |
| `58_presentation_reset.sql` | opt-in | Resets `kArchiveManagerAdmin` to configuration only and empties the archive tables without dropping them, so a demo fills an empty archive from a full source. Refuses to run while anything is in flight. Separate switches for the per-document audit trail (`DENY`-protected by design), the configuration change history and legal holds. Does **not** touch the WMS databases |
| `99_cleanup_test.sql` | opt-in | Removes test rows / run history / profiles / config (four switches). Always restores the performance-test baseline. Covers all 21 configured tables — the PO family and the two children added by `26`/`27` were missing until 2026-09-14 |

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

**The same applies when a table leaves a set.** `arch.IndexRequirement` rows do
not follow the `ObjectSpec` out, so removing a table leaves the console's index
panel asking the DBA for an index on something this configuration no longer
touches — and leaves the next reader taking the requirement as evidence the table
is still configured. `57_order_set_container_family.sql` deletes both, in one
transaction, with both recorded in the same `ConfigChangeSet`.

**And a table added without one is the opposite failure.** The three FK children
added to the ORDER set on 2026-09-15 had no requirement at all, so nothing would
have told anyone if a customer site lacked the index and the delete join scanned
the table once per batch. `26` section 1b now **detects** whether an index leads
with `(wh_id, order_number)` and records `satisfied by <name>` or `MISSING` from
what it finds, rather than asserting either. On the reference schema all three are
satisfied — `i_container_master_2`, `i_order_status_key_2`,
`i_geek_pick_order_key_2` — which is exactly the kind of thing that is true here
and may not be true anywhere else.

**`OUTPUT` cannot contain a subquery** (`Msg 10705`) and cannot reference a joined
table — only the target row and `inserted`/`deleted`. Capture the bare facts and
join afterwards.

**`usp_Api_SaveProcessDatabase` has no `@ProcessDatabaseId`.** Every other `Save`
API in the `arch` schema takes an id as an `OUTPUT` parameter; this one identifies
the row by `(ProcessCode, SourceDb, ArchiveDb)` instead. Passing the id fails with
`@ProcessDatabaseId is not a parameter for procedure usp_Api_SaveProcessDatabase`.

**The index-requirement check tests presence, not seekability.**
`arch.usp_ValidateIndexRequirements` warns only when *no* enabled index contains
the required columns **as key columns** — it does not care whether they *lead*. So
`t_pick_task_uom`'s requirement on `pick_id` validates clean even though the only
index is `ui_pick_task_uom (wh_id, cartonization_batch_id, planned_actual,
line_number, pick_id)`, where `pick_id` is the fifth key column and the delete join
scans the heap. Judge seek quality from the index definition; a green validation is
not evidence of one. The requirement's `Notes` field is where the truth is recorded.

**A grep over `sys.sql_modules` is not evidence — read the procedure.** The pattern
`'%DELETE%' + table + '%'` matches whenever *any* `DELETE` appears anywhere before
the table name in a module body, and it produced two wrong conclusions in one
analysis: `usp_shp_tx` looked like it purged `t_pick_container` (it only
`LEFT OUTER JOIN`s it at lines 282 and 463; its four `DELETE`s hit serial numbers,
`t_stored_item`, `t_hu_master` and `t_work_q_assignment`), and `usp_por_create_inv`
/ `usp_shr_create_inv` looked like receiving deletes purchase orders (every `DELETE`
in them targets `#tmp_po_detail` and `#tmp_serial_number_scanned` — temp tables).
Also escape the underscore: in `LIKE`, `_` matches any single character, so
`'%t_returns%'` matches more than `t_returns`. Use `ESCAPE`.

**Never round-trip a UTF-8 file through PowerShell 5.1's `Get-Content`/`Set-Content`.**
`Get-Content -Raw` decodes as the ANSI code page unless told otherwise, so `—`
becomes `â€"`; writing that back with `-Encoding utf8` stores the mojibake *and*
adds a BOM. It turned a one-line heading edit into a 120-line diff of this README.
Use an editor that preserves encoding, or `[System.IO.File]::ReadAllText($p,
[System.Text.Encoding]::UTF8)`.

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

- **Admin Console / IIS** — the console binaries, app-pool principal and operator
  seed (`v2\061–066`, `deploy\v2\32/34/35/51/59`) come from the handover package.
  This package is the database runtime only. It *is* deployed on the reference
  server, and everything that took to get there is in
  [ADMIN-CONSOLE.md](ADMIN-CONSOLE.md).
- **Alerting** — `047` (Database Mail, operator, job failure notification) needs
  an SMTP server. Not applied on the reference server, which has none; it is the
  single remaining go-live WARN there. On a customer system, apply it.
- **Archive backups** — `048` (FULL + LOG jobs) is **applied** on the reference
  server: FULL daily 01:30, LOG hourly, both proven by a real run. **This is not
  optional anywhere**: `kArchiveManagerBackups` is the only copy of rows deleted
  irreversibly from the source. It needs a backup path, so it stays a per-site
  step.
- **Enabling the scheduled job** — `kArchiveManager - RUN CONFIGURED` ships
  DISABLED and stays that way. Enable it only after a successful capped real run.
  It hardcodes the `JOB_DEFAULT` profile, which `04_seed_order.sql` creates.
