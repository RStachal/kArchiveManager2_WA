-- ============================================================================
-- 34 - GIVE THE EMPTY ORDER CHILDREN SOMETHING TO ARCHIVE (demo only)
-- ============================================================================
-- On the reference customer data three tables of the ORDER set are configured
-- correctly and hold NO ROWS AT ALL:
--
--     t_order_comment           0 rows
--     t_order_detail_comment    0 rows
--     t_geek_pick_order         0 rows   (Geek+ robotics extension, not in use)
--
-- Nothing is wrong with that. It does mean their archive tables stay at zero
-- through a full run, so a demo that promises "every table in the archive fills"
-- cannot keep its promise, and the three zeros read as a fault rather than as an
-- absence of data.
--
-- This seeds a small, tagged, FK-valid set of rows against orders that are
-- ALREADY ARCHIVABLE, so the next run moves them with their order and every
-- configured archive table receives something.
--
-- IT IS FOR A DEMONSTRATION INSTANCE. Do not run it on a customer's production
-- database: it writes into the WMS. That is the one thing this package otherwise
-- never does, and the exception is deliberate and confined to this file.
--
-- Rows are tagged so they can be found and removed again:
--     t_order_comment.comment_text         starts 'KAMDEMO'
--     t_order_detail_comment.comment_text  starts 'KAMDEMO'
--     t_geek_pick_order.out_batch_code     = 'KAMDEMO'
--
-- Every row is attached to an order that passes the AAD_ORDER_ARCH gate
-- (status IN (S,D), not locked, not consolidated) and is older than the cutoff,
-- so it is archived on the next run rather than sitting there for ever.
--
-- Idempotent: it deletes its own tagged rows first, then re-seeds.
-- ============================================================================
:setvar WmsDb "AAD"
:setvar RetentionDays "90"
:setvar SourceTimezone "Central European Standard Time"
:setvar DemoOrders "40"

:on error exit

USE [$(WmsDb)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @Tz  nvarchar(200) = N'$(SourceTimezone)';
DECLARE @Cut datetime2(0)  = DATEADD(MINUTE, -1440, DATEADD(DAY, -$(RetentionDays), CONVERT(datetime2(0), SYSUTCDATETIME())));

PRINT '';
PRINT '=== 34 - filling the three empty ORDER children ===';
PRINT 'Cutoff (UTC): ' + CONVERT(varchar(30), @Cut, 126);

------------------------------------------------------------------------------
-- A) The orders we will hang the rows on: archivable, and the oldest first so
--    they are comfortably inside the cutoff rather than on its edge.
------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Target') IS NOT NULL DROP TABLE #Target;
CREATE TABLE #Target (order_id int NULL, wh_id nvarchar(20) NOT NULL, order_number nvarchar(60) NOT NULL);

INSERT #Target (order_id, wh_id, order_number)
SELECT TOP ($(DemoOrders)) o.order_id, o.wh_id, o.order_number
FROM dbo.t_order o
WHERE o.status IN (N'S', N'D')
  AND o.lock_flag IS NULL
  AND o.consolidated_order_number IS NULL
  AND CAST(COALESCE(NULLIF(o.actual_ship_date, '19000101'), o.order_date) AS datetime2)
        AT TIME ZONE @Tz AT TIME ZONE N'UTC' < @Cut
ORDER BY COALESCE(NULLIF(o.actual_ship_date, '19000101'), o.order_date);

SELECT Section = 'A_TARGET_ORDERS', Orders = COUNT(*) FROM #Target;

IF NOT EXISTS (SELECT 1 FROM #Target)
BEGIN
    PRINT 'No archivable orders found - nothing seeded. Restore the source data first.';
    RETURN;
END;

------------------------------------------------------------------------------
-- B) Clear anything this script seeded before
------------------------------------------------------------------------------
DELETE FROM dbo.t_order_detail_comment WHERE comment_text LIKE N'KAMDEMO%';
DELETE FROM dbo.t_order_comment        WHERE comment_text LIKE N'KAMDEMO%';
DELETE FROM dbo.t_geek_pick_order      WHERE out_batch_code = N'KAMDEMO';
PRINT '  previous demo rows removed';

------------------------------------------------------------------------------
-- C) t_order_comment - FK to t_order on (order_id) and on (wh_id, order_number),
--    so both must come from the same real order row.
------------------------------------------------------------------------------
INSERT dbo.t_order_comment (order_id, wh_id, order_number, header_footer, comment_type, sequence, comment_date, comment_text)
SELECT t.order_id, t.wh_id, t.order_number, N'H', N'W', 1,
       DATEADD(DAY, -120, GETDATE()),
       N'KAMDEMO order comment for ' + t.order_number
FROM #Target t;
PRINT '  t_order_comment        seeded: ' + CONVERT(varchar(10), @@ROWCOUNT);

------------------------------------------------------------------------------
-- D) t_order_detail_comment - FK to t_order_DETAIL, on (order_detail_id) and on
--    (wh_id, order_number, line_number). Take real detail lines of the same
--    orders so both constraints are satisfied by construction.
------------------------------------------------------------------------------
INSERT dbo.t_order_detail_comment (order_detail_id, wh_id, order_number, comment_type, line_number, item_number, sequence, comment_date, comment_text)
SELECT d.order_detail_id, d.wh_id, d.order_number, N'W', d.line_number, d.item_number, 1,
       DATEADD(DAY, -120, GETDATE()),
       N'KAMDEMO line comment for ' + d.order_number + N'/' + d.line_number
FROM dbo.t_order_detail d
JOIN #Target t ON t.wh_id = d.wh_id AND t.order_number = d.order_number;
PRINT '  t_order_detail_comment seeded: ' + CONVERT(varchar(10), @@ROWCOUNT);

------------------------------------------------------------------------------
-- E) t_geek_pick_order - FK to t_order on (wh_id, order_number). Twenty-four
--    NOT NULL columns, so every one is given a value; none of them mean anything
--    beyond making the row legal.
------------------------------------------------------------------------------
INSERT dbo.t_geek_pick_order
    (wh_id, order_number, container_id, owner_code, wave_id, order_type, is_waiting, is_partial,
     is_allow_pick_lack, is_auto_push_wall, can_merge, container_type, is_allow_split, priority,
     expected_finish_date, pick_id, item_number, client_code, quantity, sku_level,
     out_batch_code, container_label, send_to_geek)
SELECT t.wh_id, t.order_number, N'KAMDEMO-' + t.order_number, N'KAMDEMO', N'KAMDEMO-WAVE',
       1, 0, 0, 0, 0, 0, N'TOTE', 0, 5,
       DATEADD(DAY, -120, GETDATE()), 0, N'PRODUKT1', t.wh_id, 1, 0,
       N'KAMDEMO', N'KAMDEMO-LABEL', N'N'
FROM #Target t;
PRINT '  t_geek_pick_order      seeded: ' + CONVERT(varchar(10), @@ROWCOUNT);

------------------------------------------------------------------------------
-- F) Result - every one of these must now be non-zero, and every row must
--    belong to an order the next run will take.
------------------------------------------------------------------------------
SELECT Section = 'F_SEEDED',
       t_order_comment        = (SELECT COUNT_BIG(*) FROM dbo.t_order_comment        WHERE comment_text  LIKE N'KAMDEMO%'),
       t_order_detail_comment = (SELECT COUNT_BIG(*) FROM dbo.t_order_detail_comment WHERE comment_text  LIKE N'KAMDEMO%'),
       t_geek_pick_order      = (SELECT COUNT_BIG(*) FROM dbo.t_geek_pick_order      WHERE out_batch_code = N'KAMDEMO');

SELECT Section = 'F_ALL_ON_ARCHIVABLE_ORDERS',
       Verdict = CASE WHEN NOT EXISTS (
           SELECT 1 FROM dbo.t_order_comment c
           WHERE c.comment_text LIKE N'KAMDEMO%'
             AND NOT EXISTS (SELECT 1 FROM #Target t WHERE t.wh_id = c.wh_id AND t.order_number = c.order_number))
       THEN 'ok - every seeded row hangs on an archivable order'
       ELSE '*** some seeded rows are on orders that will not be archived ***' END;

DROP TABLE #Target;
GO
PRINT '';
PRINT '34: done. The next RUN archives these with their orders, so every configured';
PRINT 'archive table receives rows. 99_cleanup_test.sql does NOT know these tags -';
PRINT 'remove them with the three DELETEs in section B if you need the source clean.';
