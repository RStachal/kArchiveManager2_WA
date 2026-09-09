-- ============================================================================
-- 40 - BULK TEST DATA FOR ALL SIX SETS (volume correctness + throughput)
-- ============================================================================
-- Seeds every table of every configured set to a realistic volume - 10 000 to
-- 100 000 rows each - and serves TWO tests from the same data:
--
--   1) CORRECTNESS AT VOLUME. Does the configuration process exactly the rows it
--      is supposed to, and nothing else, when there are hundreds of thousands of
--      them? Verified by 33_verify_bulk.sql.
--   2) THROUGHPUT. How many rows are copied to the archive and deleted from the
--      source in one minute? Measured by 41_perf_test.sql.
--
-- A SIGNIFICANT PART OF THE DATA MUST SURVIVE, AND THAT IS THE POINT
--
-- Earlier versions of this script seeded only eligible rows, because their only
-- job was to measure a rate. That cannot answer "were ONLY the configured rows
-- processed" - if everything is eligible, a predicate that matches too much looks
-- identical to one that is correct. So every set now also gets GATED rows, at
-- volume, each held back for a specific reason:
--
--   set          eligible                       gated, and why it must survive
--   TRANLOG      start_tran_date past cutoff    dated inside the retention window
--   PICKDETAIL   status SHIPPED, old            status PICKED (not terminal)
--   WORKQ        work_status C, old             work_status R (not in C/P)
--   ORDER        status S, shipped long ago     status U (not terminal)
--   PO           status C, closed long ago      status O (still open)
--   LOGMSG       inside the archivable age band n/a - see the ADV note below
--
-- GatedPct sets the proportion. At the default 20 the verification has roughly
-- one gated row in five to check, which is enough to catch an over-matching
-- predicate without halving the volume available to the rate test.
--
-- TAGS - 99_cleanup_test.sql removes all of these
--   t_order            order_number LIKE 'KAMT-%'      t_work_q  work_q_id LIKE 'KAMTQ%'
--   t_tran_log         generic_text1 = 'KAMTEST'       t_pick_detail lot_number = 'KAMTEST'
--   t_po_master        po_number LIKE 'KAMPO-B%'       t_rcpt_ship shipment_number LIKE 'KAMSH-B%'
--   t_pick_container   container_id LIKE 'KAMTC-B%'    ADV.t_log_message machine_id = 'KAMTEST'
--
-- NOTE ON REALISM: this instance has NO custom indexes in the WMS databases (see
-- the house rule in 08_source_indexes.sql), so the resulting figures are the
-- honest no-index throughput - which is exactly the production scenario.
-- t_tran_log and t_log_message do have a usable native index on their cutoff
-- column; t_order, t_pick_detail, t_work_q and t_po_master do not, so expect
-- them to be slower per row.
--
-- Seeding takes a few minutes. Reduce the counts for a quick smoke.
-- ============================================================================
:setvar WmsDb "AAD"
:setvar AdvDb "ADV"
:setvar AdminDb "kArchiveManagerAdmin"
-- Header counts. Every table of every set lands between 10 000 and 100 000 rows,
-- which is the band this data set is specified for. The child multipliers below
-- are chosen to keep the child tables inside it too - a child seeded for every
-- tenth parent would fall under 10 000 at these header volumes.
:setvar TranLogRows "75000"
:setvar PickRows "75000"
:setvar WorkQRows "75000"
:setvar OrderDocs "25000"
:setvar PoDocs "25000"
-- LogRows is a REQUEST. ADV enforces a hard row cap on t_log_message
-- (t_adv_control.LogPurgeMaximumSize) and trims the OLDEST rows down to
-- LogPurgeToSize regardless of age, so the real budget is computed below and
-- this value is only an upper bound.
:setvar LogRows "300000"
-- Percentage of each set's headers that must be GATED - held back by the
-- configuration. 0 turns this back into a pure rate seed.
:setvar GatedPct "20"
-- Child rows for every Nth parent. 5 keeps t_allocation, the tran-log children
-- and the work-queue children at ~15 000 rows each.
:setvar ChildEvery "5"
-- Comment tables are seeded for every Nth parent separately: at ChildEvery they
-- would fall below 10 000.
:setvar CommentEvery "2"
-- The ADV log purge (see the block below) must be held off for the whole
-- seed + measure cycle. Set to 0 only if you accept that ADV gets no figure.
:setvar SuspendAdvLogPurge "1"

:on error exit

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

PRINT '=== Performance seed starting. This takes a few minutes. ===';
GO

/* =========================================================================
   HOLD OFF WAREHOUSE ADVANTAGE'S OWN LOG PURGE

   ADV ships Agent job 'Log Maintenance' -> ADV.usp_PurgeLog, which deletes
   from t_log_message on TWO conditions read from ADV.dbo.t_adv_control:
     LogPurgeMaximumDays - anything older than n days
     LogPurgeMaximumSize / LogPurgeToSize - if the row count exceeds the first,
       the OLDEST rows are deleted down to the second REGARDLESS OF AGE
   On the reference instance: 30 days / 100000 / 95000.

   That job destroyed a previous perf seed: 300000 log rows were gone 29 seconds
   after seeding, no archive run, nothing in arch.Run. The seeded rows sit inside
   the age window on purpose (see the ADV seed below), so the age branch cannot
   touch them - but exceeding the size cap makes the age-blind branch fire.

   DISABLING THE JOB IS NOT ENOUGH, AND THAT IS THE IMPORTANT PART.
   sp_update_job @enabled = 0 suppresses only SCHEDULE-driven execution. An
   explicit sp_start_job runs a disabled job perfectly happily, and on this
   instance the Warehouse Advantage service does exactly that: msdb job history
   shows 'The Job was invoked by User HJS' at 14:53 and again at 15:08, the second
   one WHILE THE JOB WAS DISABLED, in the middle of a measurement. It trimmed
   t_log_message to 95148 rows mid-run, which is why that ADV figure came out at
   1277 rows/s instead of the 3780 rows/s measured in an undisturbed window - our
   run was competing with a bulk delete on the same table, and 26000 prepared keys
   pointed at rows the purge had already removed (DocsDone 86000, RowsDeleted
   60000).

   So the disable is kept - it removes the scheduled trigger, which is worth
   having - but it is NOT relied upon. The actual protection is to stay under
   LogPurgeMaximumSize, so neither branch of the purge has anything to do. The
   row budget is computed for that in the ADV seed below, and 41_perf_test.sql
   reports any purge that ran during the measurement so an affected figure is
   never quoted as clean.

   Deliberately NOT done: raising LogPurgeMaximumSize, or denying EXECUTE on
   usp_PurgeLog to the application login. Both would work, and both change the
   behaviour of the customer's WMS to suit our test. Not our call to make.

   The prior enabled state is recorded in perf.TestBaseline in OUR OWN admin
   database, never in a session temp table: an earlier version of 41_perf_test.sql
   kept its baseline in ##PerfSaved, a failed run left the values lifted, and the
   next run then captured the LIFTED values as if they were the originals. A
   durable row that is never overwritten cannot do that. 41_perf_test.sql restores
   it, 42_perf_restore.sql restores it by hand, 99_cleanup_test.sql sweeps it.

   arch.usp_Api_SetAgentJobEnabled is deliberately NOT used: it is whitelisted to
   kArchiveManager's own jobs (arch.fn_IsControllableAgentJob, THROW 50118) and
   refusing to touch a vendor job is the correct behaviour, so this goes direct.
   ========================================================================= */
USE [$(AdminDb)];
GO

IF SCHEMA_ID(N'perf') IS NULL EXEC(N'CREATE SCHEMA perf AUTHORIZATION dbo;');
GO
IF OBJECT_ID(N'perf.TestBaseline', N'U') IS NULL
    CREATE TABLE perf.TestBaseline
    (
        ItemKind      varchar(20)   NOT NULL,   -- 'AGENT_JOB' | 'PROCESS_CAP'
        ItemName      nvarchar(256) NOT NULL,
        IntValue      int           NULL,
        CapturedAtUtc datetime2(0)  NOT NULL CONSTRAINT DF_perf_TestBaseline_At DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_perf_TestBaseline PRIMARY KEY (ItemKind, ItemName)
    );
GO

DECLARE @Job sysname = N'Log Maintenance';
DECLARE @Enabled int =
    (SELECT TOP (1) CONVERT(int, j.enabled) FROM msdb.dbo.sysjobs j WHERE j.name = @Job);

IF @Enabled IS NULL
    PRINT 'INFO: Agent job "Log Maintenance" not present - nothing to suspend.';
ELSE IF $(SuspendAdvLogPurge) = 0
    PRINT 'WARN: SuspendAdvLogPurge = 0. The ADV purge may delete the seeded log rows mid-test.';
ELSE
BEGIN
    -- NEVER overwrite an existing baseline row: if a previous cycle crashed with
    -- the job already disabled, the row still holds the TRUE original state.
    INSERT perf.TestBaseline(ItemKind, ItemName, IntValue)
    SELECT 'AGENT_JOB', @Job, @Enabled
    WHERE NOT EXISTS (SELECT 1 FROM perf.TestBaseline b
                      WHERE b.ItemKind = 'AGENT_JOB' AND b.ItemName = @Job);

    EXEC msdb.dbo.sp_update_job @job_name = @Job, @enabled = 0;

    SELECT Section = 'ADV_PURGE_SUSPENDED', JobName = @Job,
           WasEnabled = (SELECT IntValue FROM perf.TestBaseline
                         WHERE ItemKind = 'AGENT_JOB' AND ItemName = @Job),
           NowEnabled = (SELECT CONVERT(int, enabled) FROM msdb.dbo.sysjobs WHERE name = @Job);
END;
GO

/* =========================================================================
   INVALIDATE ANY PREPARED CANDIDATE BATCH BEFORE DELETING THE ROWS IT POINTS AT

   A run that is cut short by RunWindowMinutes leaves its WorkBatch in status
   Paused with the unprocessed keys still attached, ON PURPOSE: the next run
   resumes it, with the ORIGINAL cutoff, so a long backlog is worked through in
   consistent slices instead of being re-selected from scratch every time. That
   is correct product behaviour and must not be "fixed".

   It is however fatal to a repeated measurement. This seed deletes the test rows
   and inserts new ones, and the surrogate keys change: t_pick_detail.pick_id and
   t_tran_log.tran_log_id are IDENTITY columns, so the resumed keys address rows
   that no longer exist. Observed on this instance, and the reason this block
   exists: a second perf run resumed the previous cycle's Paused batches and
   reported Status OK, DocsDone 78000 and 210000, RowsDeleted 0 - two sets
   silently produced no measurement at all. The order set was worse than useless:
   its keys are natural (order_number, wh_id), so they still matched, and it
   happily deleted 47800 rows against a cutoff from three days earlier.

   So the script that destroys the rows is the script that invalidates the keys.
   The batches are marked Failed, which is terminal and is not resumed, rather
   than deleted - the keys stay on file as an audit trail. Failed batches do not
   block fresh candidate preparation (verified: eight of them were present while
   ADV prepared a new batch normally).

   THIS IS A TEST-DATA OPERATION. Never run it against a production backlog: a
   Paused batch there holds real pending work, and discarding it means those rows
   are simply skipped until the next selection happens to pick them up again.
   ========================================================================= */
USE [$(AdminDb)];
GO

-- The OUTPUT clause may reference ONLY the target row and the inserted/deleted
-- pseudo-tables: no joins, and no subqueries (Msg 10705). So it captures the bare
-- facts and the report below joins for ProcessCode and counts the keys.
DECLARE @Invalidated table (WorkBatchId bigint PRIMARY KEY, PrevStatus nvarchar(40),
                            PreparedAtUtc datetime2(7), CutoffUtc datetime2(7));

UPDATE wb
SET Status = N'Failed',
    CompletedAtUtc = SYSUTCDATETIME(),
    Notes = LEFT(ISNULL(wb.Notes + N' | ', N'')
            + N'Discarded by 40_perf_seed.sql: the source rows these keys address are being re-seeded.', 500)
OUTPUT inserted.WorkBatchId, deleted.Status, inserted.PreparedAtUtc, inserted.RangeToUtc
INTO @Invalidated(WorkBatchId, PrevStatus, PreparedAtUtc, CutoffUtc)
FROM arch.WorkBatch wb
WHERE wb.Status NOT IN (N'Completed', N'Failed');

IF EXISTS (SELECT 1 FROM @Invalidated)
    SELECT Section = 'STALE_BATCH_DISCARDED', i.WorkBatchId,
           ProcessCode = p.ProcessCode, i.PrevStatus, i.PreparedAtUtc,
           CutoffItWouldHaveReused = i.CutoffUtc,
           KeyCount = (SELECT COUNT(*) FROM arch.WorkBatchKey k WHERE k.WorkBatchId = i.WorkBatchId)
    FROM @Invalidated i
    JOIN arch.WorkBatch wb ON wb.WorkBatchId = i.WorkBatchId
    JOIN arch.Process p ON p.ProcessId = wb.ProcessId
    ORDER BY i.WorkBatchId;
ELSE
    PRINT 'INFO: no open candidate batches - nothing to invalidate.';
GO

/* ---------------- clear any previous test rows ---------------- */
USE [$(WmsDb)];
GO
PRINT 'Clearing previous test rows ...';
DELETE FROM dbo.t_work_q_dependency WHERE parent_work_q_id LIKE N'KAMTQ%' OR dependent_work_q_id LIKE N'KAMTQ%';
DELETE FROM dbo.t_work_q_assignment WHERE work_q_id LIKE N'KAMTQ%';
DELETE FROM dbo.t_work_q            WHERE work_q_id LIKE N'KAMTQ%';
DELETE FROM dbo.t_tran_log_reason   WHERE tran_log_id IN (SELECT tran_log_id FROM dbo.t_tran_log WHERE generic_text1 = N'KAMTEST');
DELETE FROM dbo.t_tran_log_sn       WHERE tran_log_id IN (SELECT tran_log_id FROM dbo.t_tran_log WHERE generic_text1 = N'KAMTEST');
DELETE FROM dbo.t_tran_log          WHERE generic_text1 = N'KAMTEST';
DELETE FROM dbo.t_pick_task_uom     WHERE lot_number = N'KAMTEST' OR cartonization_batch_id LIKE N'KAMTB-B%';
DELETE FROM dbo.t_allocation        WHERE pick_id IN (SELECT pick_id FROM dbo.t_pick_detail WHERE lot_number = N'KAMTEST');
DELETE FROM dbo.t_pick_detail       WHERE lot_number = N'KAMTEST';
DELETE FROM dbo.t_pick_container       WHERE container_id LIKE N'KAMTC-B%' OR order_number LIKE N'KAMT-%';
DELETE FROM dbo.t_pack                 WHERE order_number LIKE N'KAMT-%';
DELETE FROM dbo.t_order_detail_comment WHERE order_number LIKE N'KAMT-%';
DELETE FROM dbo.t_order_comment        WHERE order_number LIKE N'KAMT-%';
DELETE FROM dbo.t_order_detail         WHERE order_number LIKE N'KAMT-%';
DELETE FROM dbo.t_order                WHERE order_number LIKE N'KAMT-%';
-- PO family. The junction goes first: it has a NO_ACTION FK to t_po_master and a
-- CASCADE FK from t_rcpt_ship, so neither parent can be removed while it exists.
DELETE FROM dbo.t_rcpt_ship_po      WHERE po_number LIKE N'KAMPO-B%' OR shipment_number LIKE N'KAMSH-B%';
DELETE FROM dbo.t_po_detail_comment WHERE po_number LIKE N'KAMPO-B%';
DELETE FROM dbo.t_po_comment        WHERE po_number LIKE N'KAMPO-B%';
DELETE FROM dbo.t_po_detail         WHERE po_number LIKE N'KAMPO-B%';
DELETE FROM dbo.t_po_master         WHERE po_number LIKE N'KAMPO-B%';
DELETE FROM dbo.t_rcpt_ship         WHERE shipment_number LIKE N'KAMSH-B%';
GO
USE [$(AdvDb)];
GO
DELETE FROM dbo.t_log_message WHERE machine_id = N'KAMTEST';
GO

/* =========================================================================
   A tally source. sys.all_objects squared gives millions of rows, which is
   plenty, and it needs no permanent helper table in the WMS schema.
   ========================================================================= */
USE [$(WmsDb)];
GO

/* ---------------------------------------------------------------------------
   HOW A ROW IS MADE GATED

   Every seed below decides per row with  (n.i % 100) < $(GatedPct)  - a
   deterministic, evenly spread fraction. Deterministic matters: the verification
   in 33_verify_bulk.sql recomputes the same expression to know exactly which
   rows must still be there, so a re-run compares like with like.

   The gate used is ALWAYS the one the configuration actually tests, never an
   invented column: a status outside the terminal set, or a date inside the
   retention window. A gated row that is gated for a reason the configuration
   does not look at would prove nothing.
   --------------------------------------------------------------------------- */

PRINT 'Seeding t_tran_log ($(TranLogRows) rows, $(GatedPct)% gated) ...';
;WITH n AS
(
    SELECT TOP ($(TranLogRows)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.t_tran_log
    (tran_type, employee_id, wh_id, tran_log_holding_id, start_tran_date, start_tran_time,
     item_number, tran_qty, expiration_date, generic_text1)
SELECT
    N'340', N'ADO', N'K01', 0,
    -- Eligible rows spread over 2024-01-01 .. 2025-12-31, well before the cutoff.
    -- Gated rows are dated in the last 30 days, i.e. INSIDE the retention window,
    -- which is the only thing this set's cutoff tests.
    CASE WHEN (n.i % 100) < $(GatedPct)
         THEN DATEADD(DAY, -(n.i % 30), CONVERT(datetime, SYSUTCDATETIME()))
         ELSE DATEADD(DAY, n.i % 730, CONVERT(datetime, '2024-01-01')) END,
    '1900-01-01 08:00:00',
    N'PRODUKT1', 1, '1900-01-01', N'KAMTEST'
FROM n;
PRINT '  rows: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

PRINT 'Seeding t_pick_detail ($(PickRows) rows, $(GatedPct)% gated) ...';
;WITH n AS
(
    SELECT TOP ($(PickRows)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.t_pick_detail
    (wh_id, order_number, line_number, item_number, status, create_date,
     planned_quantity, picked_quantity, shipped_quantity, lot_number)
SELECT
    N'K01',
    N'KAMT-PF' + CONVERT(nvarchar(12), n.i),
    N'1', N'PRODUKT1',
    -- The pick set gates on status = 'SHIPPED'. 'PICKED' is a real intermediate
    -- state, so a gated row here is one that is genuinely still in flight.
    CASE WHEN (n.i % 100) < $(GatedPct) THEN N'PICKED' ELSE N'SHIPPED' END,
    DATEADD(DAY, n.i % 730, CONVERT(datetime, '2024-01-01')),
    1, 1, 1, N'KAMTEST'
FROM n;
PRINT '  rows: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

PRINT 'Seeding t_work_q ($(WorkQRows) rows, $(GatedPct)% gated) ...';
;WITH n AS
(
    SELECT TOP ($(WorkQRows)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.t_work_q
    (work_q_id, work_type, work_status, priority, wh_id, description,
     item_number, qty, datetime_stamp, location_id)
SELECT
    N'KAMTQ' + CONVERT(nvarchar(20), n.i),
    N'03',
    -- This set gates on work_status IN ('C','P'). 'R' (released) is outside it.
    CASE WHEN (n.i % 100) < $(GatedPct) THEN N'R' ELSE N'C' END,
    N'30', N'K01', N'perf',
    N'PRODUKT1', 1,
    DATEADD(DAY, n.i % 730, CONVERT(datetime, '2024-01-01')),
    N'B001'
FROM n;
PRINT '  rows: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

PRINT 'Seeding the order document set ($(OrderDocs) documents, $(GatedPct)% gated) ...';
-- client_code AND display_order_number are supplied so the vendor trigger
-- tr_order_master_insert short-circuits instead of running its UPDATE per row.
;WITH n AS
(
    SELECT TOP ($(OrderDocs)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.t_order
    (wh_id, order_number, status, order_date, actual_ship_date,
     client_code, display_order_number, priority)
SELECT
    N'K01',
    N'KAMT-OF' + CONVERT(nvarchar(12), n.i),
    -- The order set gates on status IN ('S','D'). 'U' is outside it.
    CASE WHEN (n.i % 100) < $(GatedPct) THEN N'U' ELSE N'S' END,
    DATEADD(DAY, n.i % 730, CONVERT(datetime, '2024-01-01')),
    DATEADD(DAY, (n.i % 730) + 1, CONVERT(datetime, '2024-01-01')),
    N'K01',
    N'KAMT-OF' + CONVERT(nvarchar(12), n.i),
    N'10'
FROM n;
PRINT '  headers: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- Two lines per document, so the set has a realistic fan-out.
INSERT dbo.t_order_detail(wh_id, order_number, line_number, item_number, qty, qty_shipped)
SELECT o.wh_id, o.order_number, CONVERT(nvarchar(30), l.n), N'PRODUKT1', 1, 1
FROM dbo.t_order o
CROSS JOIN (VALUES (1), (2)) AS l(n)
WHERE o.order_number LIKE N'KAMT-OF%';
PRINT '  lines: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- One header comment per document.
INSERT dbo.t_order_comment(wh_id, order_number, header_footer, comment_type, sequence, comment_text, comment_date)
SELECT o.wh_id, o.order_number, N'H', N'W', 0, N'perf', o.order_date
FROM dbo.t_order o
WHERE o.order_number LIKE N'KAMT-OF%';
PRINT '  comments: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- Allocations for every Nth pick, so the child join is exercised without
-- doubling the pick volume.
INSERT dbo.t_allocation(wh_id, pick_id, item_number, pick_location, pick_area, quantity, work_type, pick_rule)
SELECT N'K01', p.pick_id, N'PRODUKT1', N'B001', N'A1', 1, N'03', N'FIFO'
FROM dbo.t_pick_detail p
WHERE p.lot_number = N'KAMTEST' AND p.pick_id % $(ChildEvery) = 0;
PRINT '  allocations: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- t_pick_container: one per order, added to the ORDER set by 26.
-- container_id is part of pk_pick_container (wh_id, container_id) so it must be
-- unique; the order number supplies that. Note these hang off the ORDER, not the
-- pick - a container is shared across the picks of one order.
INSERT dbo.t_pick_container (container_id, wh_id, cartonization_batch_id, order_number,
                             status, create_date, target_ship_date, actual_ship_date)
SELECT N'KAMTC-B' + SUBSTRING(o.order_number, 8, 20), o.wh_id,
       N'KAMTB-B' + SUBSTRING(o.order_number, 8, 20), o.order_number,
       N'ACTIVE', o.order_date, o.actual_ship_date, o.actual_ship_date
FROM dbo.t_order o
WHERE o.order_number LIKE N'KAMT-OF%';
PRINT '  t_pick_container: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- t_pick_task_uom: one per pick, added to the PICKDETAIL set by 26. lot_number is
-- set to the test tag so the cleanup can find rows even if the batch id changes.
INSERT dbo.t_pick_task_uom (wh_id, cartonization_batch_id, planned_actual, line_number,
                            pick_id, item_number, lot_number, uom, pattern, qty)
SELECT p.wh_id, N'KAMTB-B' + CONVERT(nvarchar(20), p.pick_id), N'P', p.line_number,
       p.pick_id, N'PRODUKT1', N'KAMTEST', N'EA', N'STD', 1
FROM dbo.t_pick_detail p
WHERE p.lot_number = N'KAMTEST';
PRINT '  t_pick_task_uom: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

/* =========================================================================
   THE REMAINING CHILD TABLES

   Without these, six of the fourteen configured tables report 0 rows in the
   per-table result and there is no way to tell "this table is fast" from "this
   table was never exercised". A per-table answer with six blanks is not a
   per-table answer, so every table in the configuration gets rows.

   Each is seeded for every Nth parent ($(ChildEvery)), which is enough to
   measure the join and the cascade without inflating the parent volume.
   ========================================================================= */
PRINT 'Seeding the remaining child tables ...';
GO

-- t_tran_log children. Both are keyed by tran_log_id, an IDENTITY on the parent,
-- so they must be selected FROM the parent rather than generated independently.
INSERT dbo.t_tran_log_reason(reason_id, reason_type, tran_log_id)
SELECT N'KAMT', N'ADJUSTMENT', l.tran_log_id
FROM dbo.t_tran_log l
WHERE l.generic_text1 = N'KAMTEST' AND l.tran_log_id % $(ChildEvery) = 0;
PRINT '  t_tran_log_reason: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

INSERT dbo.t_tran_log_sn(serial_number, tran_log_id)
SELECT N'KAMTSN' + CONVERT(nvarchar(20), l.tran_log_id), l.tran_log_id
FROM dbo.t_tran_log l
WHERE l.generic_text1 = N'KAMTEST' AND l.tran_log_id % $(ChildEvery) = 0;
PRINT '  t_tran_log_sn: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- t_order children. comment_type and sequence carry defaults; line_number is
-- nvarchar, and must match the value used for t_order_detail above ('1' / '2').
-- CommentEvery, not ChildEvery: at these header volumes ChildEvery would put this
-- table under the 10 000-row floor this data set is specified for.
INSERT dbo.t_order_detail_comment(wh_id, order_number, line_number, item_number, comment_text)
SELECT o.wh_id, o.order_number, N'1', N'PRODUKT1', N'perf line comment'
FROM dbo.t_order o
WHERE o.order_number LIKE N'KAMT-OF%'
  AND CONVERT(int, SUBSTRING(o.order_number, 8, 12)) % $(CommentEvery) = 0;
PRINT '  t_order_detail_comment: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- t_pack is the CASCADE victim in this set: it carries no key the anchor can join
-- on and is removed by the FK cascade from t_order.
--
-- IT ALSO CANNOT BE GIVEN VOLUME, AND THAT IS A PROPERTY OF THE SCHEMA. Its
-- primary key is (id, wh_id) and 'id' is a foreign key to t_employee - despite
-- the name, it identifies the PACKER, not the pack. So the table holds at most
-- one row per employee per warehouse: seven rows on this instance, whatever the
-- order volume. Any per-table rate for t_pack is therefore meaningless by
-- construction, and the report will show a handful of rows rather than zero so
-- that "structurally tiny" is not mistaken for "never exercised".
--
-- location_id is a foreign key to t_location as well (B001 exists on K01), and
-- date_logged has a default. An earlier attempt at this insert invented values
-- for both columns and failed on Msg 547.
WITH free_emp AS
(
    SELECT e.id, rn = ROW_NUMBER() OVER (ORDER BY e.id)
    FROM dbo.t_employee e
    WHERE e.wh_id = N'K01'
      AND NOT EXISTS (SELECT 1 FROM dbo.t_pack p WHERE p.id = e.id AND p.wh_id = e.wh_id)
),
tgt AS
(
    SELECT o.order_number, rn = ROW_NUMBER() OVER (ORDER BY o.order_number)
    FROM dbo.t_order o
    WHERE o.order_number LIKE N'KAMT-OF%'
)
INSERT dbo.t_pack(wh_id, id, order_number, location_id)
SELECT N'K01', f.id, t.order_number, N'B001'
FROM free_emp f JOIN tgt t ON t.rn = f.rn;
PRINT '  t_pack: ' + CAST(@@ROWCOUNT AS varchar(20)) + ' (capped by the employee count - see the note above)';
GO

-- t_work_q children.
INSERT dbo.t_work_q_assignment(work_q_id, user_assigned, wh_id)
SELECT q.work_q_id, N'KAMTUSER', q.wh_id
FROM dbo.t_work_q q
WHERE q.work_q_id LIKE N'KAMTQ%'
  AND CONVERT(int, SUBSTRING(q.work_q_id, 6, 20)) % $(ChildEvery) = 0;
PRINT '  t_work_q_assignment: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- Dependencies link one seeded work_q row to the next, so BOTH sides of the
-- relationship are inside the test data. The archiver's configuration covers
-- both directions (parent_work_q_id and dependent_work_q_id), which is why the
-- pair has to exist rather than pointing at a live row.
INSERT dbo.t_work_q_dependency(parent_work_q_id, dependent_work_q_id, status, wh_id)
SELECT q.work_q_id,
       N'KAMTQ' + CONVERT(nvarchar(20), CONVERT(int, SUBSTRING(q.work_q_id, 6, 20)) + 1),
       N'C', q.wh_id
FROM dbo.t_work_q q
WHERE q.work_q_id LIKE N'KAMTQ%'
  AND CONVERT(int, SUBSTRING(q.work_q_id, 6, 20)) % $(ChildEvery) = 0
  AND EXISTS (SELECT 1 FROM dbo.t_work_q q2
              WHERE q2.work_q_id = N'KAMTQ' + CONVERT(nvarchar(20), CONVERT(int, SUBSTRING(q.work_q_id, 6, 20)) + 1));
PRINT '  t_work_q_dependency: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

/* =========================================================================
   THE PURCHASE ORDER SET (AAD_PO_ARCH, added by 27)

   The inbound mirror of the order set, and the only set whose children include a
   junction to a document we do NOT archive (t_rcpt_ship). The shipments are
   seeded here as well, precisely so that the junction has a real second parent -
   without them the exposure that section D of 27 measures could not occur, and a
   test that cannot reproduce a risk does not cover it.

   Half the shipments are left OPEN (status 'O'). Those are the ones section D
   counts: their purchase order is archivable, so the link row goes with it and
   the live shipment loses it.
   ========================================================================= */
PRINT 'Seeding the PO document set ($(PoDocs) documents, $(GatedPct)% gated) ...';

-- client_code and display_po_number are supplied for the same reason as on the
-- order side: tr_po_master_insert would otherwise default client_code to wh_id
-- and violate fk_po_master_client_code.
;WITH n AS
(
    SELECT TOP ($(PoDocs)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.t_po_master
    (po_number, wh_id, status, create_date, closed_date,
     client_code, display_po_number, vendor_code, residential_flag)
SELECT
    N'KAMPO-B' + CONVERT(nvarchar(12), n.i),
    N'K01',
    -- This set gates on status = 'C'. 'O' (open) is the default state and is
    -- outside it, so a gated row here is a purchase order still being received.
    CASE WHEN (n.i % 100) < $(GatedPct) THEN N'O' ELSE N'C' END,
    DATEADD(DAY, n.i % 730, CONVERT(datetime, '2024-01-01')),
    -- closed_date must be NULL when the order is open: that is what the WMS does,
    -- and the cutoff comparison against NULL is UNKNOWN, which is the second half
    -- of this set's gate.
    CASE WHEN (n.i % 100) < $(GatedPct) THEN NULL
         ELSE DATEADD(DAY, (n.i % 730) + 1, CONVERT(datetime, '2024-01-01')) END,
    N'K01',
    N'KAMPO-B' + CONVERT(nvarchar(12), n.i),
    N'VENDOR1', N'N'
FROM n;
PRINT '  headers: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- Two lines per PO. schedule_number is left to its default of 0 and is part of
-- pk_po_detail; the detail-comment FK carries it too and both must agree.
INSERT dbo.t_po_detail (po_number, line_number, item_number, wh_id, qty, location_id, closed_date)
SELECT m.po_number, l.n, N'PRODUKT1', N'K01', 10, N'B001', m.closed_date
FROM dbo.t_po_master m
CROSS JOIN (VALUES (N'1'), (N'2')) AS l(n)
WHERE m.po_number LIKE N'KAMPO-B%';
PRINT '  detail lines: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

INSERT dbo.t_po_comment (po_number, wh_id, comment_type, comment_text, sequence, comment_date)
SELECT m.po_number, m.wh_id, N'R', N'bulk seed header comment', 0, m.create_date
FROM dbo.t_po_master m
WHERE m.po_number LIKE N'KAMPO-B%'
  AND CONVERT(int, SUBSTRING(m.po_number, 8, 20)) % $(CommentEvery) = 0;
PRINT '  header comments: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- The CASCADE victims: t_po_detail_comment cascades from t_po_detail, so these
-- are what prove the delete order at volume. If the archiver deleted the detail
-- before copying them, archived would fall below deleted.
INSERT dbo.t_po_detail_comment (wh_id, po_number, line_number, item_number, comment_text)
SELECT d.wh_id, d.po_number, d.line_number, N'PRODUKT1', N'bulk seed line comment'
FROM dbo.t_po_detail d
WHERE d.po_number LIKE N'KAMPO-B%'
  AND CONVERT(int, SUBSTRING(d.po_number, 8, 20)) % $(CommentEvery) = 0;
PRINT '  detail comments: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- Inbound shipments. carrier_id and date_expected are NOT NULL with no default.
-- Half are left open on purpose - see the block comment above.
;WITH n AS
(
    SELECT TOP ($(PoDocs)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT dbo.t_rcpt_ship (wh_id, shipment_number, carrier_id, date_expected, date_received,
                        status, workers_assigned)
SELECT N'K01', N'KAMSH-B' + CONVERT(nvarchar(12), n.i), 1,
       DATEADD(DAY, n.i % 730, CONVERT(datetime, '2024-01-01')),
       CASE WHEN n.i % 2 = 0 THEN DATEADD(DAY, (n.i % 730) + 1, CONVERT(datetime, '2024-01-01')) ELSE NULL END,
       CASE WHEN n.i % 2 = 0 THEN N'C' ELSE N'O' END,
       0
FROM n
WHERE n.i % $(CommentEvery) = 0;
PRINT '  shipments: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

-- One link per shipment, to the PO with the same ordinal. Both parents therefore
-- exist, which is what makes the junction meaningful.
INSERT dbo.t_rcpt_ship_po (wh_id, shipment_number, po_number)
SELECT rs.wh_id, rs.shipment_number, N'KAMPO-B' + SUBSTRING(rs.shipment_number, 8, 20)
FROM dbo.t_rcpt_ship rs
WHERE rs.shipment_number LIKE N'KAMSH-B%'
  AND EXISTS (SELECT 1 FROM dbo.t_po_master m
              WHERE m.po_number = N'KAMPO-B' + SUBSTRING(rs.shipment_number, 8, 20)
                AND m.wh_id = rs.wh_id);
PRINT '  shipment links: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

USE [$(AdvDb)];
GO
PRINT 'Seeding ADV.t_log_message ($(LogRows) rows) ...';

/* -------------------------------------------------------------------------
   THE ADV SEED DATES ARE NOT ARBITRARY - THEY SIT IN A NARROW BAND

   Two independent deadlines apply to a row in t_log_message:
     older than arch.Process.RetentionDays (+ CutoffSafetyLagMinutes)  -> WE archive it
     older than t_adv_control.LogPurgeMaximumDays                      -> ADV DELETES it
   Only rows between those two ages are archivable at all. Seeding "well before
   the cutoff" like every other set in this script would put every row past ADV's
   deadline, and the vendor purge would take them before we ever ran - which is
   exactly what happened on the first attempt.

   The band is read from the live configuration rather than hardcoded, so this
   still works after someone changes either setting.
   ------------------------------------------------------------------------- */
DECLARE @AdvRet int, @AdvLag int, @PurgeDays int, @PurgeMaxRows int, @PurgeToRows int;

SELECT @AdvRet = p.RetentionDays, @AdvLag = p.CutoffSafetyLagMinutes
FROM [$(AdminDb)].arch.Process p
WHERE p.ProcessCode = N'ADV_LOGMSG_ARCH';

-- All three purge settings are read here, in this batch: the row budget further
-- down needs the size pair, and a variable does not survive a GO.
SELECT @PurgeDays    = MAX(CASE WHEN string_key = N'LogPurgeMaximumDays' THEN TRY_CONVERT(int, string_value) END),
       @PurgeMaxRows = MAX(CASE WHEN string_key = N'LogPurgeMaximumSize' THEN TRY_CONVERT(int, string_value) END),
       @PurgeToRows  = MAX(CASE WHEN string_key = N'LogPurgeToSize'      THEN TRY_CONVERT(int, string_value) END)
FROM dbo.t_adv_control;

-- +1 day of slack on each side: the cutoff moves while the seed runs, and the
-- vendor purge compares with DATEDIFF(day, ...) which rounds towards the boundary.
DECLARE @MinAge int = ISNULL(@AdvRet, 90) + CEILING(ISNULL(@AdvLag, 0) / 1440.0) + 1;
DECLARE @MaxAge int = ISNULL(@PurgeDays, @MinAge + 30) - 1;

IF @MaxAge <= @MinAge
BEGIN
    PRINT '*** ADV BAND IS EMPTY ***';
    PRINT '    archivable from age : ' + CAST(@MinAge AS varchar(10)) + ' days';
    PRINT '    ADV deletes from    : ' + CAST(ISNULL(@PurgeDays, -1) AS varchar(10)) + ' days';
    PRINT '    No row can be both eligible for us and still present. Lower the ADV';
    PRINT '    retention (24_seed_logmessage_anchor.sql clamps it for you) and re-run.';
    SET @MaxAge = @MinAge + 3;   -- seed anyway so the failure is visible, not silent
END
ELSE
    PRINT '  seeding ages ' + CAST(@MinAge AS varchar(10)) + '..' + CAST(@MaxAge AS varchar(10))
          + ' days (eligible for us, not yet due for the ADV purge)';

DECLARE @Span int = @MaxAge - @MinAge + 1;

/* -------------------------------------------------------------------------
   ROW BUDGET: STAY UNDER THE VENDOR SIZE CAP

   LogPurgeMaximumSize is a cap on the WHOLE table and its enforcement is
   age-blind - over the cap, the oldest rows go down to LogPurgeToSize. Our
   seeded rows are deliberately the oldest in the table, so they are first in
   line. Since the purge can be started by the application at any moment
   (disabling the Agent job does not prevent that - see the block at the top),
   the only reliable defence is never to cross the cap.

   Budget = LogPurgeToSize - rows we are not allowed to touch - a safety margin
   for whatever the live system logs while we measure. LogPurgeToSize, not
   LogPurgeMaximumSize, is the right basis: crossing the maximum triggers a trim
   all the way down to the target, so the target is the real ceiling.

   CONSEQUENCE, AND IT IS A RESULT IN ITS OWN RIGHT: on this instance the budget
   is about 90000 rows, while one minute of ADV throughput is roughly 3780 x 60 =
   227000 rows. The archivable population of this table is therefore SMALLER THAN
   ONE MINUTE OF WORK - kArchiveManager will always drain it long before the
   window closes, and the set can only ever report a full-drain time, never a
   60-second rate. That is a property of the vendor's own retention policy, not a
   limitation of the archiver.
   ------------------------------------------------------------------------- */
DECLARE @Keep int = (SELECT COUNT_BIG(*) FROM dbo.t_log_message WHERE machine_id <> N'KAMTEST' OR machine_id IS NULL);
DECLARE @Target int = ISNULL(@PurgeToRows, @PurgeMaxRows);
DECLARE @Margin int = 5000;
DECLARE @Budget int = $(LogRows);

IF @Target IS NULL
    PRINT '  no size cap configured - seeding the requested $(LogRows) rows';
ELSE
BEGIN
    SET @Budget = @Target - @Keep - @Margin;
    IF @Budget < 0 SET @Budget = 0;
    IF @Budget > $(LogRows) SET @Budget = $(LogRows);

    PRINT '  size budget: LogPurgeToSize ' + CAST(@Target AS varchar(10))
          + ' - existing ' + CAST(@Keep AS varchar(10))
          + ' - margin ' + CAST(@Margin AS varchar(10))
          + ' = ' + CAST(@Budget AS varchar(10)) + ' rows (requested $(LogRows))';

    IF @Budget < $(LogRows)
    BEGIN
        PRINT '  NOTE: the request was cut to fit under the vendor size cap. One minute of';
        PRINT '        ADV throughput is larger than the table is allowed to hold, so this set';
        PRINT '        will report a full-drain time rather than a 60-second rate.';
    END;
END;

IF @Budget = 0
    PRINT '*** ADV BUDGET IS ZERO - the table is already at or over its cap. Skipping the ADV seed. ***';

-- The ntext payload is kept short on purpose: the point is row throughput, and a
-- multi-KB LOB per row would measure disk bandwidth instead.
;WITH n AS
(
    SELECT TOP (@Budget) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
),
d AS
(
    SELECT n.i,
           -- whole days back into the band, then minutes within the day so no two
           -- rows share a timestamp and the clustered index gets a realistic spread
           ts = DATEADD(MINUTE, -(n.i % 1440),
                DATEADD(DAY, -(@MinAge + (n.i % @Span)), CONVERT(datetime, SYSUTCDATETIME())))
    FROM n
)
INSERT dbo.t_log_message
(
    logged_on_utc, log_sequence, machine_id, process_id, thread_id, thread_sequence,
    logged_on_local, log_type, log_level, resource_code, line_number,
    application_name, user_id, details
)
SELECT
    d.ts,
    800000000000 + d.i,
    N'KAMTEST',
    9100, 4100, d.i,
    CONVERT(varchar(23), d.ts, 121),
    1, 3, 1000, 1,
    N'kam-perf', N'kamtest',
    N'perf payload'
FROM d;
PRINT '  rows: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

/* =========================================================================
   What is now eligible, per set. 41_perf_test.sql compares against this.
   ========================================================================= */
USE [$(WmsDb)];
GO
DECLARE @Cut datetime2(0) = DATEADD(MINUTE, -1440, DATEADD(DAY, -90, CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz nvarchar(200) = N'Central European Standard Time';

PRINT '';
PRINT 'Cutoff (UTC): ' + CONVERT(varchar(30), @Cut, 126);

SELECT Section = 'ELIGIBLE', ProcessCode = 'AAD_ORDER_ARCH', Headers = COUNT_BIG(*),
       EstRows = COUNT_BIG(*) * 4   -- header + 2 lines + 1 comment
FROM dbo.t_order o
WHERE o.order_number LIKE N'KAMT-%' AND o.status IN (N'S', N'D')
  AND o.lock_flag IS NULL AND o.consolidated_order_number IS NULL
  AND CAST(CAST(COALESCE(NULLIF(o.actual_ship_date,'19000101'), o.order_date) AS datetime2)
      AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut
UNION ALL
SELECT 'ELIGIBLE', 'AAD_PICKDETAIL_ARCH', COUNT_BIG(*), COUNT_BIG(*) + COUNT_BIG(*) / 10
FROM dbo.t_pick_detail p
WHERE p.lot_number = N'KAMTEST' AND p.status = N'SHIPPED'
  AND CAST(TRY_CONVERT(datetime2, p.create_date) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut
UNION ALL
SELECT 'ELIGIBLE', 'AAD_TRANLOG_ARCH', COUNT_BIG(*), COUNT_BIG(*)
FROM dbo.t_tran_log l
WHERE l.generic_text1 = N'KAMTEST' AND l.start_tran_date > '19000102'
  AND CAST(TRY_CONVERT(datetime2, l.start_tran_date) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut
UNION ALL
SELECT 'ELIGIBLE', 'AAD_WORKQ_ARCH', COUNT_BIG(*), COUNT_BIG(*)
FROM dbo.t_work_q q
WHERE q.work_q_id LIKE N'KAMTQ%' AND q.datetime_stamp IS NOT NULL AND q.work_status IN (N'C', N'P')
  AND CAST(TRY_CONVERT(datetime2, q.datetime_stamp) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut
UNION ALL
SELECT 'ELIGIBLE', 'AAD_PO_ARCH', COUNT_BIG(*), COUNT_BIG(*) * 3
FROM dbo.t_po_master m
WHERE m.po_number LIKE N'KAMPO-B%' AND m.status = N'C' AND m.closed_date IS NOT NULL
  AND CAST(CAST(m.closed_date AS datetime2) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut;
GO

/* ---------------------------------------------------------------------------
   HOW MANY ROWS MUST SURVIVE. This is the other half of the specification: the
   verification in 33_verify_bulk.sql compares against these numbers, so they are
   printed here where the data was created rather than recomputed from scratch.
   --------------------------------------------------------------------------- */
DECLARE @Cut3 datetime2(0) = DATEADD(MINUTE, -1440, DATEADD(DAY, -90, CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz3 nvarchar(200) = N'Central European Standard Time';

SELECT Section = 'MUST_SURVIVE', ProcessCode = 'AAD_ORDER_ARCH', Reason = 'status not in (S,D)',
       Headers = COUNT_BIG(*)
FROM dbo.t_order WHERE order_number LIKE N'KAMT-OF%' AND status NOT IN (N'S', N'D')
UNION ALL
SELECT 'MUST_SURVIVE', 'AAD_PICKDETAIL_ARCH', 'status <> SHIPPED', COUNT_BIG(*)
FROM dbo.t_pick_detail WHERE lot_number = N'KAMTEST' AND status <> N'SHIPPED'
UNION ALL
SELECT 'MUST_SURVIVE', 'AAD_TRANLOG_ARCH', 'dated inside the retention window', COUNT_BIG(*)
FROM dbo.t_tran_log
WHERE generic_text1 = N'KAMTEST'
  AND CAST(TRY_CONVERT(datetime2, start_tran_date) AT TIME ZONE @Tz3 AT TIME ZONE N'UTC' AS datetime2(0)) >= @Cut3
UNION ALL
SELECT 'MUST_SURVIVE', 'AAD_WORKQ_ARCH', 'work_status not in (C,P)', COUNT_BIG(*)
FROM dbo.t_work_q WHERE work_q_id LIKE N'KAMTQ%' AND work_status NOT IN (N'C', N'P')
UNION ALL
SELECT 'MUST_SURVIVE', 'AAD_PO_ARCH', 'status <> C (still open)', COUNT_BIG(*)
FROM dbo.t_po_master WHERE po_number LIKE N'KAMPO-B%' AND status <> N'C';
GO

USE [$(AdvDb)];
GO
-- ADV's cutoff is read from the configuration, not hardcoded: 24_seed_logmessage_anchor.sql
-- clamps this process's retention to the ADV purge window, so it is NOT 90 days.
DECLARE @Ret2 int, @Lag2 int;
SELECT @Ret2 = RetentionDays, @Lag2 = CutoffSafetyLagMinutes
FROM [$(AdminDb)].arch.Process WHERE ProcessCode = N'ADV_LOGMSG_ARCH';

DECLARE @Cut2 datetime2(0) =
    DATEADD(MINUTE, -ISNULL(@Lag2, 0), DATEADD(DAY, -ISNULL(@Ret2, 90), CONVERT(datetime2(0), SYSUTCDATETIME())));

PRINT 'ADV retention: ' + CAST(ISNULL(@Ret2, -1) AS varchar(10)) + ' days, cutoff (UTC): '
      + CONVERT(varchar(30), @Cut2, 126);

SELECT Section = 'ELIGIBLE', ProcessCode = 'ADV_LOGMSG_ARCH', Headers = COUNT_BIG(*), EstRows = COUNT_BIG(*)
FROM dbo.t_log_message m
WHERE m.machine_id = N'KAMTEST'
  AND CAST(TRY_CONVERT(datetime2, m.logged_on_utc) AT TIME ZONE N'UTC' AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut2;

-- The size branch of the vendor purge is age-blind, so report the exposure.
DECLARE @Total int = (SELECT COUNT_BIG(*) FROM dbo.t_log_message);
DECLARE @MaxSize int = (SELECT TRY_CONVERT(int, string_value) FROM dbo.t_adv_control WHERE string_key = N'LogPurgeMaximumSize');
SELECT Section = 'ADV_SIZE_CAP', TableRows = @Total, LogPurgeMaximumSize = @MaxSize,
       Verdict = CASE WHEN @MaxSize IS NULL THEN 'no cap configured'
                      WHEN @Total > @MaxSize THEN 'OVER CAP - the vendor purge will trim the oldest rows as soon as its job runs'
                      ELSE 'under cap' END;
GO

PRINT '';
PRINT '40_perf_seed: done. Run 41_perf_test.sql next.';
GO
