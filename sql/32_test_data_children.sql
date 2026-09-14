-- ============================================================================
-- 32 - TEST DATA FOR THE TWO CHILD TABLES ADDED BY 26
-- ============================================================================
-- Self-contained: it creates its own order and pick documents rather than hanging
-- rows off whatever 30_test_data_all.sql happens to have left behind. That keeps
-- 30's documented arithmetic (66 rows) intact and lets this script be run,
-- re-run and cleaned on its own.
--
-- WHAT EACH ROW PROVES
--   t_pick_container on an ARCHIVABLE order  -> the new ObjectSpec at DeleteOrder
--       45 actually fires, and the container goes with its order.
--   t_pick_container on a KEPT order         -> the join is document-scoped. If
--       this one disappears, the predicate is matching more than it should.
--   t_pick_container with order_number NULL  -> the accepted limitation, stated
--       in 26: a container that cannot be attributed to an order can never match
--       the predicate and must be LEFT IN PLACE. This is the safe direction, and
--       it is proven here rather than asserted.
--   t_pick_task_uom on an ARCHIVABLE pick    -> the new ObjectSpec at DeleteOrder
--       15 fires before the anchor.
--   t_pick_task_uom on a KEPT pick           -> pick-scoped, same reasoning.
--
-- Tags: order KAMT-C%, pick lot_number 'KAMTCHILD', container KAMTC%,
-- cartonization batch KAMTB%. 99_cleanup_test.sql removes them by that tag
-- directly - NOT via t_pick_detail. A child keyed only by a reference to its
-- parent cannot be cleaned once the parent row is already gone, which is what
-- happened before 99 was taught about this table: 660 001 archive rows survived
-- a cleanup as orphans.
-- ============================================================================
:setvar WmsDb "AAD"
:setvar RetentionDays "90"
:setvar SourceTimezone "Central European Standard Time"

:on error exit

USE [$(WmsDb)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

PRINT 'Clearing previous child test rows ...';
DELETE FROM dbo.t_pick_container WHERE container_id LIKE N'KAMTC%' OR order_number LIKE N'KAMT-C%';
DELETE FROM dbo.t_pick_task_uom  WHERE cartonization_batch_id LIKE N'KAMTB%';
DELETE FROM dbo.t_allocation     WHERE pick_id IN (SELECT pick_id FROM dbo.t_pick_detail WHERE lot_number = N'KAMTCHILD');
DELETE FROM dbo.t_pick_detail    WHERE lot_number = N'KAMTCHILD' OR order_number LIKE N'KAMT-C%';
DELETE FROM dbo.t_order_detail   WHERE order_number LIKE N'KAMT-C%';
DELETE FROM dbo.t_order          WHERE order_number LIKE N'KAMT-C%';
GO

/* ---------------- two orders: one archivable, one held ------------------- */
-- client_code and display_order_number are supplied so tr_order_master_insert
-- does not fall back to client_code = wh_id and violate fk_order_client_code.
INSERT dbo.t_order (wh_id, order_number, status, order_date, actual_ship_date,
                    client_code, display_order_number, priority)
VALUES (N'K01', N'KAMT-C1', N'S', '2025-01-10', '2025-01-12', N'K01', N'KAMT-C1', N'10'),
       (N'K01', N'KAMT-C2', N'U', '2025-01-10', '19000101',   N'K01', N'KAMT-C2', N'10');
PRINT '  orders: ' + CAST(@@ROWCOUNT AS varchar(20)) + '  (KAMT-C1 archivable, KAMT-C2 held by status U)';

INSERT dbo.t_order_detail (wh_id, order_number, line_number, item_number, qty, qty_shipped)
SELECT o.wh_id, o.order_number, N'1', N'PRODUKT1', 1, 1
FROM dbo.t_order o WHERE o.order_number LIKE N'KAMT-C%';
PRINT '  order lines: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

/* ---------------- three containers -------------------------------------- */
-- The third has NO order_number. It is the one that must survive.
INSERT dbo.t_pick_container (container_id, wh_id, cartonization_batch_id, order_number,
                             status, create_date, target_ship_date, actual_ship_date)
VALUES (N'KAMTC-1', N'K01', N'KAMTB-1', N'KAMT-C1', N'ACTIVE', '2025-01-10', '2025-01-12', '2025-01-12'),
       (N'KAMTC-2', N'K01', N'KAMTB-2', N'KAMT-C2', N'ACTIVE', '2025-01-10', '2025-01-12', NULL),
       (N'KAMTC-3', N'K01', N'KAMTB-3', NULL,       N'ACTIVE', '2025-01-10', NULL,         NULL);
PRINT '  containers: ' + CAST(@@ROWCOUNT AS varchar(20)) + '  (KAMTC-1 goes, KAMTC-2 and KAMTC-3 stay)';
GO

/* ---------------- two picks: one archivable, one held ------------------- */
-- The pick set gates on status = 'SHIPPED' and create_date past the cutoff.
INSERT dbo.t_pick_detail (wh_id, order_number, line_number, item_number, status, create_date,
                          planned_quantity, picked_quantity, shipped_quantity, lot_number)
VALUES (N'K01', N'KAMT-C1', N'1', N'PRODUKT1', N'SHIPPED', '2025-01-11', 1, 1, 1, N'KAMTCHILD'),
       (N'K01', N'KAMT-C2', N'1', N'PRODUKT1', N'PICKED',  '2025-01-11', 1, 1, 0, N'KAMTCHILD');
PRINT '  picks: ' + CAST(@@ROWCOUNT AS varchar(20)) + '  (SHIPPED one archivable, PICKED one held)';
GO

/* ---------------- one t_pick_task_uom row per pick ---------------------- */
INSERT dbo.t_pick_task_uom (wh_id, cartonization_batch_id, planned_actual, line_number,
                            pick_id, item_number, lot_number, uom, pattern, qty)
SELECT p.wh_id,
       N'KAMTB-' + CASE WHEN p.status = N'SHIPPED' THEN N'S' ELSE N'P' END,
       N'P', p.line_number, p.pick_id, N'PRODUKT1', N'KAMTCHILD', N'EA', N'STD', 1
FROM dbo.t_pick_detail p
WHERE p.lot_number = N'KAMTCHILD';
PRINT '  pick_task_uom: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

/* ---------------- expectations ------------------------------------------ */
DECLARE @Ret int = $(RetentionDays), @Lag int = 1440;
DECLARE @Cut datetime2(0) = DATEADD(MINUTE, -@Lag, DATEADD(DAY, -@Ret, CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz nvarchar(200) = N'$(SourceTimezone)';

PRINT '';
PRINT 'Cutoff (UTC): ' + CONVERT(varchar(30), @Cut, 126);

SELECT Section='EXPECT_CONTAINER', c.container_id, OrderNumber=ISNULL(c.order_number, N'(null)'),
       OrderStatus = ISNULL((SELECT o.status FROM dbo.t_order o
                             WHERE o.order_number = c.order_number AND o.wh_id = c.wh_id), N'(no order)'),
       Expected = CASE
                    WHEN c.order_number IS NULL THEN 'KEEP - unattributable, predicate cannot match it'
                    WHEN EXISTS (SELECT 1 FROM dbo.t_order o
                                 WHERE o.order_number = c.order_number AND o.wh_id = c.wh_id
                                   AND o.status IN (N'S', N'D') AND o.lock_flag IS NULL
                                   AND o.consolidated_order_number IS NULL
                                   AND CAST(CAST(COALESCE(NULLIF(o.actual_ship_date,'19000101'), o.order_date) AS datetime2)
                                       AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut)
                         THEN 'ARCHIVE'
                    ELSE 'KEEP - its order is held' END
FROM dbo.t_pick_container c
WHERE c.container_id LIKE N'KAMTC%' ORDER BY c.container_id;

SELECT Section='EXPECT_TASKUOM', u.pick_id, u.cartonization_batch_id,
       PickStatus = p.status,
       Expected = CASE WHEN p.status = N'SHIPPED'
                         AND CAST(TRY_CONVERT(datetime2, p.create_date) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut
                       THEN 'ARCHIVE' ELSE 'KEEP - its pick is held' END
FROM dbo.t_pick_task_uom u
JOIN dbo.t_pick_detail p ON p.pick_id = u.pick_id
WHERE u.cartonization_batch_id LIKE N'KAMTB%' ORDER BY u.pick_id;

PRINT '';
PRINT 'Expected: 1 of 3 containers archived, 1 of 2 pick_task_uom rows archived.';
PRINT 'KAMTC-3 (order_number NULL) surviving is a PASS, not a miss - see 26.';
GO
