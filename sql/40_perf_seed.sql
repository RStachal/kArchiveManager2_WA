-- ============================================================================
-- 40 - PERFORMANCE TEST DATA (bulk seed)
-- ============================================================================
-- Seeds enough archivable rows that a one-minute run CANNOT exhaust them, so the
-- measured number is a THROUGHPUT and not just "how much test data there was".
-- 41_perf_test.sql checks that explicitly and refuses to report a rate if the
-- data ran out.
--
-- Tagged exactly like 30_test_data_all.sql, so 99_cleanup_test.sql removes it:
--   t_order            order_number LIKE 'KAMT-%'
--   t_tran_log         generic_text1 = 'KAMTEST'
--   t_pick_detail      lot_number    = 'KAMTEST'
--   t_work_q           work_q_id LIKE 'KAMTQ%'
--   ADV.t_log_message  machine_id    = 'KAMTEST'
--
-- ALL ROWS ARE ELIGIBLE: dates well before the cutoff and terminal states
-- (order status 'S', pick 'SHIPPED', work_status 'C'). The functional gates are
-- already proven by 30_test_data_all.sql; this seed exists purely to measure rate.
--
-- SIZING. Published figures for this product are ~3.2k rows/s unoptimised and
-- ~5k rows/s with index parking, so a 60-second window moves roughly 200-300k
-- rows. The defaults below give every set a comfortable multiple of that. They
-- are per-table row counts, not document counts.
--
-- t_work_q is deliberately the largest: it is by far the fastest set (single
-- table, TIMESTAMP strategy, 4000-row transactions) and 200000 rows were consumed
-- in 29 seconds on the reference instance - i.e. it ran out of data and produced
-- a volume instead of a rate. 600000 keeps it busy for the full window.
--
-- NOTE ON REALISM: this instance has NO custom indexes in the WMS databases (see
-- the house rule in 08_source_indexes.sql), so these numbers are the honest
-- no-index throughput - which is exactly the production scenario. t_tran_log and
-- t_log_message do have a usable native index on their cutoff column; t_order,
-- t_pick_detail and t_work_q do not, so expect them to be slower per row.
--
-- Seeding itself takes a few minutes. Reduce the counts for a quick smoke.
-- ============================================================================
:setvar WmsDb "AAD"
:setvar AdvDb "ADV"
:setvar AdminDb "kArchiveManagerAdmin"
-- Every count below is sized so a 60-second run CANNOT drain it. Measured rates
-- on the reference instance, with the volume one minute consumes:
--   t_pick_detail  5405 rows/s -> ~325k    t_tran_log  4654 rows/s -> ~280k
--   t_work_q       9302 rows/s -> ~560k    t_order      163 docs/s -> ~10k docs
-- Doubling those leaves room for a faster machine.
:setvar TranLogRows "600000"
:setvar PickRows "600000"
:setvar WorkQRows "800000"
:setvar OrderDocs "60000"
-- LogRows is a REQUEST. ADV enforces a hard row cap on t_log_message
-- (t_adv_control.LogPurgeMaximumSize) and trims the OLDEST rows down to
-- LogPurgeToSize regardless of age, so the real budget is computed below and
-- this value is only an upper bound.
:setvar LogRows "300000"
-- Fraction of parent rows that get child rows. 10 means every 10th parent, which
-- exercises the child joins and gives each child table a measurable rate without
-- doubling the volume of the set.
:setvar ChildEvery "10"
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
DELETE FROM dbo.t_allocation        WHERE pick_id IN (SELECT pick_id FROM dbo.t_pick_detail WHERE lot_number = N'KAMTEST');
DELETE FROM dbo.t_pick_detail       WHERE lot_number = N'KAMTEST';
DELETE FROM dbo.t_pack                 WHERE order_number LIKE N'KAMT-%';
DELETE FROM dbo.t_order_detail_comment WHERE order_number LIKE N'KAMT-%';
DELETE FROM dbo.t_order_comment        WHERE order_number LIKE N'KAMT-%';
DELETE FROM dbo.t_order_detail         WHERE order_number LIKE N'KAMT-%';
DELETE FROM dbo.t_order                WHERE order_number LIKE N'KAMT-%';
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

PRINT 'Seeding t_tran_log ($(TranLogRows) rows) ...';
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
    -- spread over 2024-01-01 .. 2025-12-31, all comfortably before the cutoff
    DATEADD(DAY, n.i % 730, CONVERT(datetime, '2024-01-01')),
    '1900-01-01 08:00:00',
    N'PRODUKT1', 1, '1900-01-01', N'KAMTEST'
FROM n;
PRINT '  rows: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

PRINT 'Seeding t_pick_detail ($(PickRows) rows) ...';
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
    N'1', N'PRODUKT1', N'SHIPPED',
    DATEADD(DAY, n.i % 730, CONVERT(datetime, '2024-01-01')),
    1, 1, 1, N'KAMTEST'
FROM n;
PRINT '  rows: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

PRINT 'Seeding t_work_q ($(WorkQRows) rows) ...';
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
    N'03', N'C', N'30', N'K01', N'perf',
    N'PRODUKT1', 1,
    DATEADD(DAY, n.i % 730, CONVERT(datetime, '2024-01-01')),
    N'B001'
FROM n;
PRINT '  rows: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

PRINT 'Seeding the order document set ($(OrderDocs) documents) ...';
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
    N'S',
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

-- Allocations for a tenth of the picks, so the child join is exercised without
-- doubling the pick volume.
INSERT dbo.t_allocation(wh_id, pick_id, item_number, pick_location, pick_area, quantity, work_type, pick_rule)
SELECT N'K01', p.pick_id, N'PRODUKT1', N'B001', N'A1', 1, N'03', N'FIFO'
FROM dbo.t_pick_detail p
WHERE p.lot_number = N'KAMTEST' AND p.pick_id % $(ChildEvery) = 0;
PRINT '  allocations: ' + CAST(@@ROWCOUNT AS varchar(20));
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
INSERT dbo.t_order_detail_comment(wh_id, order_number, line_number, item_number, comment_text)
SELECT o.wh_id, o.order_number, N'1', N'PRODUKT1', N'perf line comment'
FROM dbo.t_order o
WHERE o.order_number LIKE N'KAMT-OF%'
  AND CONVERT(int, SUBSTRING(o.order_number, 8, 12)) % $(ChildEvery) = 0;
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
  AND CAST(TRY_CONVERT(datetime2, q.datetime_stamp) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut;
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
