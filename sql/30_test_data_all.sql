-- ============================================================================
-- 30 - TEST DATA for all five document sets (consolidated)
-- ============================================================================
-- Replaces 21_test_data_standalone.sql and 26_test_data_docsets.sql.
-- Re-runnable: removes its own rows first.
--
-- TAGS (used by 99_cleanup_test.sql):
--   t_order            order_number LIKE 'KAMT-%'
--   t_tran_log         generic_text1 = 'KAMTEST'
--   t_pick_detail      lot_number    = 'KAMTEST'
--   t_work_q           work_q_id LIKE 'KAMTQ%'
--   ADV.t_log_message  machine_id    = 'KAMTEST'
--
-- DESIGN PRINCIPLE: every set gets rows that MUST archive and rows that MUST
-- survive, each for a DIFFERENT reason. A run that deletes everything old is not
-- a passing test - it has to leave the gated rows alone.
--
-- Cutoff for RetentionDays=90 + 1 day lag is approx 2026-06-05 (run date 2026-09-04).
-- OLD dates are 2025-04..2025-06, RECENT dates are 2026-08.
--
-- ---------------------------------------------------------------------------
-- CASE MATRIX
-- ---------------------------------------------------------------------------
-- ORDER SET (header t_order)
--   KAMT-O1  S, old, FULL TREE: 2 lines + 2 line comments + 1 comment + 1 pack
--                                                -> ARCHIVE  7 rows  *hierarchy test*
--   KAMT-O2  D, old, header + 1 line + 1 comment -> ARCHIVE  3 rows
--   KAMT-O3  U, old                              -> KEEP  status gate
--   KAMT-O4  S, old, lock_flag set               -> KEEP  lock gate
--   KAMT-O5  S, old, consolidated_order_number   -> KEEP  consolidation gate
--   KAMT-O6  S, ship date = 1900 sentinel, OLD order_date  -> ARCHIVE  sentinel falls back
--   KAMT-O7  S, ship date = 1900 sentinel, RECENT order_date -> KEEP
--   KAMT-O8  S, recent                           -> KEEP  too recent
--
-- PICK SET (header t_pick_detail)
--   PK-1  SHIPPED, old, WITH allocation -> ARCHIVE  2 rows  *child test*
--   PK-2  SHIPPED, old                  -> ARCHIVE  1 row
--   PK-3  RELEASED, old                 -> KEEP  live work
--   PK-4  LOADED, old                   -> KEEP  on a truck, not gone
--   PK-5  PICKED, old                   -> KEEP  not dispatched
--   PK-6  SHIPPED, recent               -> KEEP  too recent
--
-- TRANSACTION-LOG SET (header t_tran_log)
--   TL-1  old, no children                 -> ARCHIVE  1 row
--   TL-2  old, 1 reason + 2 serial numbers -> ARCHIVE  4 rows  *ENFORCED-FK test*
--         This is the case that justifies ANCHOR over TIMESTAMP for this set:
--         both children have NO_ACTION FKs to tran_log_id, so the parent cannot
--         be deleted while they exist. ANCHOR deletes the header LAST.
--   TL-3  1900 sentinel start_tran_date  -> KEEP  sentinel gate
--   TL-4  recent                          -> KEEP  too recent
--
-- WORK-QUEUE SET (header t_work_q)
--   WQ-1  C, old, with assignment  -> ARCHIVE  2 rows
--   WQ-2  P, old                   -> ARCHIVE  1 row
--   WQ-3  C, recent                -> KEEP  too recent
--   WQ-4  U, old                   -> KEEP  unassigned
--   WQ-5  A, old                   -> KEEP  assigned
--   WQ-6  H, old, dependent of WQ-2 -> KEEP  on hold
--         WQ-2 -> WQ-6 is a finish-start dependency: archiving the parent removes
--         the dependency row and leaves WQ-6 on Hold with no parent. Correct per
--         configuration, and exactly what 09_preflight_data.sql section G counts.
--
-- APPLICATION-LOG SET (header ADV.t_log_message)
--   LG-old   40 rows, logged_on_utc 2025-05 -> ARCHIVE
--   LG-new   10 rows, logged_on_utc 2026-08 -> KEEP  too recent
--   LG-dup    2 identical rows, old          -> ARCHIVE BOTH as one candidate
--         The natural key has genuine duplicates in this table; the candidate
--         dedupe (ROW_NUMBER ... WHERE rn = 1) yields ONE key and the delete join
--         then matches both rows, so both are archived. Divergence must stay 0.
-- ============================================================================
:setvar WmsDb "AAD"
:setvar AdvDb "ADV"

:on error exit

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* =========================================================================
   CLEANUP - children before parents
   ========================================================================= */
USE [$(WmsDb)];
GO
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
   ORDER SET
   ========================================================================= */
USE [$(WmsDb)];
GO
DECLARE @O table
(
    OrderNumber nvarchar(30) NOT NULL PRIMARY KEY,
    Status_     nvarchar(20) NOT NULL,
    OrderDate   datetime     NOT NULL,
    ShipDate    datetime     NULL,
    LockFlag    nvarchar(10) NULL,
    ConsolNo    nvarchar(30) NULL,
    Lines       int          NOT NULL,
    LineCmts    int          NOT NULL,
    PackRow     bit          NOT NULL,
    Expect      varchar(8)   NOT NULL
);

INSERT @O VALUES
    (N'KAMT-O1', N'S', '2025-04-01', '2025-04-15', NULL, NULL,        2, 2, 1, 'ARCHIVE'),
    (N'KAMT-O2', N'D', '2025-05-01', '2025-05-10', NULL, NULL,        1, 0, 0, 'ARCHIVE'),
    (N'KAMT-O3', N'U', '2025-04-02', '2025-04-16', NULL, NULL,        1, 0, 0, 'KEEP'),
    (N'KAMT-O4', N'S', '2025-04-03', '2025-04-17', N'L', NULL,        1, 0, 0, 'KEEP'),
    (N'KAMT-O5', N'S', '2025-04-04', '2025-04-18', NULL, N'KAMT-O1',  1, 0, 0, 'KEEP'),
    (N'KAMT-O6', N'S', '2025-06-01', '1900-01-01', NULL, NULL,        1, 0, 0, 'ARCHIVE'),
    (N'KAMT-O7', N'S', '2026-08-20', '1900-01-01', NULL, NULL,        1, 0, 0, 'KEEP'),
    (N'KAMT-O8', N'S', '2026-08-01', '2026-08-15', NULL, NULL,        1, 0, 0, 'KEEP');

-- client_code AND display_order_number are both supplied so the vendor trigger
-- tr_order_master_insert short-circuits: it fires only when one of them is NULL,
-- and its UPDATE would set client_code = wh_id, failing fk_order_client_code.
INSERT dbo.t_order(wh_id, order_number, status, order_date, actual_ship_date, lock_flag,
                   consolidated_order_number, client_code, display_order_number, priority)
SELECT N'K01', o.OrderNumber, o.Status_, o.OrderDate, o.ShipDate, o.LockFlag,
       o.ConsolNo, N'K01', o.OrderNumber, N'10'
FROM @O o;

INSERT dbo.t_order_detail(wh_id, order_number, line_number, item_number, qty, qty_shipped)
SELECT N'K01', o.OrderNumber, CONVERT(nvarchar(30), n.n), N'PRODUKT1', 10 * n.n, 10 * n.n
FROM @O o JOIN (VALUES (1), (2)) AS n(n) ON n.n <= o.Lines;

INSERT dbo.t_order_comment(wh_id, order_number, header_footer, comment_type, sequence, comment_text, comment_date)
SELECT N'K01', o.OrderNumber, N'H', N'W', 0, N'kam test (' + o.Expect + N')', o.OrderDate
FROM @O o WHERE o.OrderNumber IN (N'KAMT-O1', N'KAMT-O2');

INSERT dbo.t_order_detail_comment(wh_id, order_number, line_number, comment_type, sequence, item_number, comment_text, comment_date)
SELECT N'K01', o.OrderNumber, CONVERT(nvarchar(30), n.n), N'W', 0, N'PRODUKT1',
       N'line note ' + CONVERT(nvarchar(10), n.n), o.OrderDate
FROM @O o JOIN (VALUES (1), (2)) AS n(n) ON n.n <= o.LineCmts;

-- t_pack's PK is (id, wh_id) and id is an FK to t_employee, so at most one row
-- per employee per warehouse. Take a free employee.
INSERT dbo.t_pack(wh_id, id, order_number, location_id, date_logged)
SELECT TOP (1) N'K01', e.id, N'KAMT-O1', N'B001', '2025-04-15'
FROM dbo.t_employee e
WHERE e.wh_id = N'K01'
  AND NOT EXISTS (SELECT 1 FROM dbo.t_pack p WHERE p.id = e.id AND p.wh_id = e.wh_id)
ORDER BY e.id;
GO

/* =========================================================================
   PICK SET
   ========================================================================= */
DECLARE @P table (Tag varchar(6), Status_ nvarchar(20), CreateDate datetime, Alloc bit, Expect varchar(8));
INSERT @P VALUES
    ('PK-1', N'SHIPPED',  '2025-04-01', 1, 'ARCHIVE'),
    ('PK-2', N'SHIPPED',  '2025-06-01', 0, 'ARCHIVE'),
    ('PK-3', N'RELEASED', '2025-04-02', 0, 'KEEP'),
    ('PK-4', N'LOADED',   '2025-04-03', 0, 'KEEP'),
    ('PK-5', N'PICKED',   '2025-04-04', 0, 'KEEP'),
    ('PK-6', N'SHIPPED',  '2026-08-20', 0, 'KEEP');

INSERT dbo.t_pick_detail(wh_id, order_number, line_number, item_number, status, create_date,
                         planned_quantity, picked_quantity, shipped_quantity, lot_number)
SELECT N'K01', N'KAMT-P' + RIGHT(p.Tag, 1), N'1', N'PRODUKT1', p.Status_, p.CreateDate,
       10, CASE WHEN p.Status_ IN (N'SHIPPED', N'LOADED', N'PICKED') THEN 10 ELSE 0 END,
       CASE WHEN p.Status_ = N'SHIPPED' THEN 10 ELSE 0 END, N'KAMTEST'
FROM @P p;

-- Allocation for the first shipped-and-old pick only
INSERT dbo.t_allocation(wh_id, pick_id, item_number, pick_location, pick_area, quantity, work_type, pick_rule)
SELECT TOP (1) N'K01', pd.pick_id, N'PRODUKT1', N'B001', N'A1', 10, N'03', N'FIFO'
FROM dbo.t_pick_detail pd
WHERE pd.lot_number = N'KAMTEST' AND pd.status = N'SHIPPED' AND pd.create_date = '2025-04-01'
ORDER BY pd.pick_id;
GO

/* =========================================================================
   TRANSACTION-LOG SET
   ========================================================================= */
DECLARE @TL table (Tag varchar(6), TranLogId bigint);

INSERT dbo.t_tran_log(tran_type, employee_id, wh_id, tran_log_holding_id, start_tran_date,
                      start_tran_time, item_number, tran_qty, expiration_date, generic_text1, generic_text2)
OUTPUT inserted.generic_text2, inserted.tran_log_id INTO @TL(Tag, TranLogId)
VALUES
    (N'340', N'ADO', N'K01', 0, '2025-04-10', '1900-01-01 08:00:00', N'PRODUKT1', 5, '1900-01-01', N'KAMTEST', 'TL-1'),
    (N'542', N'ADO', N'K01', 0, '2025-05-20', '1900-01-01 09:30:00', N'PRODUKT1', 7, '1900-01-01', N'KAMTEST', 'TL-2'),
    (N'340', N'ADO', N'K01', 0, '1900-01-01', '1900-01-01 10:00:00', N'PRODUKT1', 3, '1900-01-01', N'KAMTEST', 'TL-3'),
    (N'340', N'ADO', N'K01', 0, '2026-08-15', '1900-01-01 11:00:00', N'PRODUKT1', 9, '1900-01-01', N'KAMTEST', 'TL-4');

-- TL-2 gets the enforced-FK children. This is the case that proves the design.
INSERT dbo.t_tran_log_reason(reason_id, reason_type, tran_log_id)
SELECT N'ADJ01', N'ADJUSTMENT', t.TranLogId FROM @TL t WHERE t.Tag = 'TL-2';

INSERT dbo.t_tran_log_sn(serial_number, tran_log_id, action_type)
SELECT N'SN-KAMTEST-1', t.TranLogId, N'ADD' FROM @TL t WHERE t.Tag = 'TL-2'
UNION ALL
SELECT N'SN-KAMTEST-2', t.TranLogId, N'ADD' FROM @TL t WHERE t.Tag = 'TL-2';
GO

/* =========================================================================
   WORK-QUEUE SET
   ========================================================================= */
-- description is nvarchar(30) - keep the labels short.
INSERT dbo.t_work_q(work_q_id, work_type, work_status, priority, wh_id, description,
                    item_number, qty, datetime_stamp, location_id)
VALUES
    (N'KAMTQ1', N'03', N'C', N'30', N'K01', N'complete old',  N'PRODUKT1', 6, '2025-05-05 07:00:00', N'B001'),
    (N'KAMTQ2', N'03', N'P', N'30', N'K01', N'picks compl old', N'PRODUKT1', 5, '2025-05-06 07:00:00', N'B001'),
    (N'KAMTQ3', N'03', N'C', N'30', N'K01', N'complete RECENT', N'PRODUKT1', 4, '2026-08-10 11:00:00', N'B002'),
    (N'KAMTQ4', N'03', N'U', N'30', N'K01', N'unassigned old', N'PRODUKT1', 7, '2025-05-07 08:00:00', N'B003'),
    (N'KAMTQ5', N'03', N'A', N'40', N'K01', N'assigned old',   N'PRODUKT1', 9, '2025-05-08 08:00:00', N'B003'),
    (N'KAMTQ6', N'12', N'H', N'50', N'K01', N'on hold old',    N'PRODUKT1', 11, '2025-05-09 09:00:00', N'B001');

INSERT dbo.t_work_q_assignment(work_q_id, user_assigned, wh_id, status)
VALUES (N'KAMTQ1', N'ADO', N'K01', N'C');

-- Finish-start dependency: archivable parent, dependent still on hold.
INSERT dbo.t_work_q_dependency(parent_work_q_id, dependent_work_q_id, status, dependency_type, wh_id)
VALUES (N'KAMTQ2', N'KAMTQ6', N'ACTIVE', N'FS', N'K01');
GO

/* =========================================================================
   APPLICATION-LOG SET (ADV)
   ========================================================================= */
USE [$(AdvDb)];
GO
-- 40 old rows (archive), 10 recent (keep), plus 2 genuinely identical old rows.
-- machine_id = 'KAMTEST' is the tag; every other column is plausible filler.
INSERT dbo.t_log_message
(
    logged_on_utc, log_sequence, machine_id, process_id, thread_id, thread_sequence,
    logged_on_local, log_type, log_level, resource_code, line_number,
    application_name, user_id, details
)
SELECT
    DATEADD(MINUTE, v.n, CONVERT(datetime, '2025-05-01 10:00:00')),
    900000000000 + v.n,
    N'KAMTEST',
    9001, 4001, v.n,
    CONVERT(varchar(23), DATEADD(MINUTE, v.n, CONVERT(datetime, '2025-05-01 12:00:00')), 121),
    1, 3, 1000 + v.n, v.n,
    N'kam-test', N'kamtest',
    N'test log payload ' + CONVERT(nvarchar(10), v.n)
FROM (SELECT TOP (40) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) AS v;

INSERT dbo.t_log_message
(
    logged_on_utc, log_sequence, machine_id, process_id, thread_id, thread_sequence,
    logged_on_local, log_type, log_level, resource_code, line_number,
    application_name, user_id, details
)
SELECT
    DATEADD(MINUTE, v.n, CONVERT(datetime, '2026-08-20 10:00:00')),
    910000000000 + v.n,
    N'KAMTEST',
    9002, 4002, v.n,
    CONVERT(varchar(23), DATEADD(MINUTE, v.n, CONVERT(datetime, '2026-08-20 12:00:00')), 121),
    1, 3, 2000 + v.n, v.n,
    N'kam-test', N'kamtest',
    N'recent log payload ' + CONVERT(nvarchar(10), v.n)
FROM (SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) AS v;

-- Two rows identical in every identity column, to exercise candidate dedupe.
INSERT dbo.t_log_message
(
    logged_on_utc, log_sequence, machine_id, process_id, thread_id, thread_sequence,
    logged_on_local, log_type, log_level, resource_code, line_number,
    application_name, user_id, details
)
SELECT '2025-05-15 08:30:00', 920000000000, N'KAMTEST', 9003, 4003, 1,
       '2025-05-15 10:30:00.000', 1, 3, 3000, 1, N'kam-test', N'kamtest', N'duplicate payload'
UNION ALL
SELECT '2025-05-15 08:30:00', 920000000000, N'KAMTEST', 9003, 4003, 1,
       '2025-05-15 10:30:00.000', 1, 3, 3000, 1, N'kam-test', N'kamtest', N'duplicate payload';
GO

/* =========================================================================
   EXPECTED OUTCOME - computed from the configured expressions
   ========================================================================= */
USE [$(WmsDb)];
GO
DECLARE @Cut datetime2(0) = DATEADD(MINUTE, -1440, DATEADD(DAY, -90, CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz nvarchar(200) = N'Central European Standard Time';

PRINT 'Cutoff (UTC): ' + CONVERT(varchar(30), @Cut, 126);

SELECT Section='EXP_ORDER', o.order_number, o.status, o.actual_ship_date, ISNULL(o.lock_flag,N'-') AS lock_,
       ISNULL(o.consolidated_order_number,N'-') AS consol_,
       Rows_ = 1 + (SELECT COUNT(*) FROM dbo.t_order_detail d WHERE d.order_number=o.order_number)
                 + (SELECT COUNT(*) FROM dbo.t_order_detail_comment c WHERE c.order_number=o.order_number)
                 + (SELECT COUNT(*) FROM dbo.t_order_comment c WHERE c.order_number=o.order_number)
                 + (SELECT COUNT(*) FROM dbo.t_pack p WHERE p.order_number=o.order_number),
       Expected = CASE WHEN o.status NOT IN (N'S',N'D') THEN 'KEEP status'
                       WHEN o.lock_flag IS NOT NULL THEN 'KEEP lock'
                       WHEN o.consolidated_order_number IS NOT NULL THEN 'KEEP consol'
                       WHEN CAST(CAST(COALESCE(NULLIF(o.actual_ship_date,'19000101'), o.order_date) AS datetime2)
                            AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut THEN 'ARCHIVE'
                       ELSE 'KEEP recent' END
FROM dbo.t_order o WHERE o.order_number LIKE N'KAMT-%' ORDER BY o.order_number;

SELECT Section='EXP_PICK', p.pick_id, p.order_number, p.status, p.create_date,
       Alloc_ = (SELECT COUNT(*) FROM dbo.t_allocation a WHERE a.pick_id=p.pick_id),
       Expected = CASE WHEN p.status <> N'SHIPPED' THEN 'KEEP status'
                       WHEN CAST(TRY_CONVERT(datetime2, p.create_date) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut THEN 'ARCHIVE'
                       ELSE 'KEEP recent' END
FROM dbo.t_pick_detail p WHERE p.lot_number = N'KAMTEST' ORDER BY p.pick_id;

SELECT Section='EXP_TRANLOG', l.tran_log_id, l.generic_text2 AS tag_, l.start_tran_date,
       Children_ = (SELECT COUNT(*) FROM dbo.t_tran_log_reason r WHERE r.tran_log_id=l.tran_log_id)
                 + (SELECT COUNT(*) FROM dbo.t_tran_log_sn s WHERE s.tran_log_id=l.tran_log_id),
       Expected = CASE WHEN l.start_tran_date <= '19000102' THEN 'KEEP sentinel'
                       WHEN CAST(TRY_CONVERT(datetime2, l.start_tran_date) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut THEN 'ARCHIVE'
                       ELSE 'KEEP recent' END
FROM dbo.t_tran_log l WHERE l.generic_text1 = N'KAMTEST' ORDER BY l.tran_log_id;

SELECT Section='EXP_WORKQ', q.work_q_id, q.work_status, q.datetime_stamp,
       Expected = CASE WHEN q.work_status NOT IN (N'C',N'P') THEN 'KEEP status'
                       WHEN CAST(TRY_CONVERT(datetime2, q.datetime_stamp) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut THEN 'ARCHIVE'
                       ELSE 'KEEP recent' END
FROM dbo.t_work_q q WHERE q.work_q_id LIKE N'KAMTQ%' ORDER BY q.work_q_id;
GO

USE [$(AdvDb)];
GO
DECLARE @Cut2 datetime2(0) = DATEADD(MINUTE, -1440, DATEADD(DAY, -90, CONVERT(datetime2(0), SYSUTCDATETIME())));
SELECT Section='EXP_LOGMSG',
       Expected_ARCHIVE = SUM(CASE WHEN CAST(TRY_CONVERT(datetime2, m.logged_on_utc) AT TIME ZONE N'UTC' AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut2 THEN 1 ELSE 0 END),
       Expected_KEEP    = SUM(CASE WHEN CAST(TRY_CONVERT(datetime2, m.logged_on_utc) AT TIME ZONE N'UTC' AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut2 THEN 0 ELSE 1 END),
       Total_ = COUNT_BIG(*)
FROM dbo.t_log_message m WHERE m.machine_id = N'KAMTEST';
GO

PRINT '30_test_data_all: done.';
GO
