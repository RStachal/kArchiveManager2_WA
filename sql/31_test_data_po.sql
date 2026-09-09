-- ============================================================================
-- 31 - TEST DATA FOR THE PURCHASE ORDER SET (AAD_PO_ARCH)
-- ============================================================================
-- Six purchase orders, chosen so that a run which archives all of them is a
-- FAILURE, not a pass. Three must survive, and each survives for a different
-- reason, so that a broken gate shows up as a specific wrong row rather than as
-- a wrong total.
--
--   KAMPO-1  ARCHIVE   closed 2025-01-15, full depth: 2 detail lines, 1 header
--                      comment, 2 detail comments, 1 link to a CLOSED shipment.
--                      This is the delete-order test: t_po_detail_comment has a
--                      CASCADE FK from t_po_detail, so if the archiver deletes
--                      the detail before copying the comments, the cascade
--                      destroys rows that were never archived and the run
--                      reports fewer archived than deleted.
--   KAMPO-2  ARCHIVE   closed 2025-03-01, one detail line only - the minimal
--                      document, proving the set does not depend on comments.
--   KAMPO-3  KEEP      status 'O' with an old create_date and closed_date NULL.
--                      Held by the status gate. If this disappears, the gate is
--                      not being applied and OPEN purchase orders are at risk.
--   KAMPO-4  KEEP      status 'C' but closed 10 days ago. Held by the cutoff.
--   KAMPO-5  KEEP      status 'C' with closed_date NULL - a state that should
--                      not exist, since usp_util_close_inbound_order writes both
--                      in one statement. Included precisely because a cutoff
--                      comparison against NULL is UNKNOWN, not TRUE, and that
--                      behaviour should be proven rather than assumed.
--   KAMPO-6  ARCHIVE   closed 2025-02-01 but linked to an OPEN shipment.
--                      THIS ONE IS EXPECTED TO BE ARCHIVED, and that is the
--                      point: the gate "only archive a PO whose shipments are
--                      closed" cannot be expressed in configuration, because
--                      arch.usp_AssertSafeSqlExpression refuses subqueries. So
--                      this row exercises the one exposure the set has, and
--                      section D of 27_seed_po_set.sql is the only thing that
--                      reports it. If D counts 0 while KAMPO-6 exists, D is broken.
--
-- SCHEMA OBSTACLES THIS SEED HAS TO CLEAR, all of them real
--   * tr_po_master_insert fires on every insert. Its sibling on t_order sets
--     client_code = ISNULL(client_code, wh_id), which then violates the client FK
--     when wh_id is not a client code. client_code and display_po_number are
--     therefore supplied explicitly so the trigger has nothing to invent.
--   * t_po_detail has FKs to t_item_master (item_number, wh_id), t_location and
--     t_whse, so the item and location must already exist: PRODUKT1 and B001 on K01.
--   * t_po_master has FKs to t_vendor and t_client: VENDOR1 and K01.
--   * t_rcpt_ship requires carrier_id (FK to t_carrier) and date_expected, both
--     NOT NULL with no default. carrier_id 1 = PPL.
--   * Warehouse must be K01, never DEFAULT - DEFAULT is not a client code, so a
--     document created there cannot satisfy fk_po_master_client_code.
--
-- Tag: po_number LIKE 'KAMPO-%' and shipment_number LIKE 'KAMSH-%'.
-- 99_cleanup_test.sql removes them.
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

/* ---------------- clear any previous run of this seed -------------------- */
-- Child first, then parent: t_po_detail_comment cascades from t_po_detail, but
-- t_po_comment and t_po_detail hold NO_ACTION FKs to the master, and
-- t_rcpt_ship_po holds one to both the master and the shipment.
PRINT 'Clearing previous PO test rows ...';
DELETE FROM dbo.t_rcpt_ship_po      WHERE po_number LIKE N'KAMPO-%' OR shipment_number LIKE N'KAMSH-%';
DELETE FROM dbo.t_po_detail_comment WHERE po_number LIKE N'KAMPO-%';
DELETE FROM dbo.t_po_comment        WHERE po_number LIKE N'KAMPO-%';
DELETE FROM dbo.t_po_detail         WHERE po_number LIKE N'KAMPO-%';
DELETE FROM dbo.t_po_master         WHERE po_number LIKE N'KAMPO-%';
DELETE FROM dbo.t_rcpt_ship         WHERE shipment_number LIKE N'KAMSH-%';
GO

/* ---------------- headers ------------------------------------------------ */
DECLARE @PO table (PoNumber nvarchar(60) PRIMARY KEY, Status_ nvarchar(20),
                   CreateDate datetime, ClosedDate datetime, Expect varchar(10), Why nvarchar(200));
INSERT @PO VALUES
 (N'KAMPO-1', N'C', '2024-11-01', '2025-01-15', 'ARCHIVE', N'closed and old, full child depth incl. a closed shipment link'),
 (N'KAMPO-2', N'C', '2025-01-01', '2025-03-01', 'ARCHIVE', N'closed and old, one detail line only'),
 (N'KAMPO-3', N'O', '2024-10-01', NULL,         'KEEP',    N'still OPEN - held by the status gate'),
 (N'KAMPO-4', N'C', '2026-08-01', NULL,         'KEEP',    N'closed only 10 days ago - held by the cutoff'),
 (N'KAMPO-5', N'C', '2024-09-01', NULL,         'KEEP',    N'status C but closed_date NULL - cutoff vs NULL is UNKNOWN'),
 (N'KAMPO-6', N'C', '2024-12-01', '2025-02-01', 'ARCHIVE', N'closed and old but linked to an OPEN shipment - the exposure case');

-- KAMPO-4's closed_date has to be relative to today or the test rots: a hardcoded
-- date would eventually fall past the retention window and silently become an
-- ARCHIVE case, turning a real regression into a green run.
UPDATE @PO SET ClosedDate = DATEADD(DAY, -10, CONVERT(datetime, SYSUTCDATETIME())) WHERE PoNumber = N'KAMPO-4';

INSERT dbo.t_po_master (po_number, wh_id, status, create_date, closed_date,
                        client_code, display_po_number, vendor_code, residential_flag)
SELECT p.PoNumber, N'K01', p.Status_, p.CreateDate, p.ClosedDate,
       N'K01', p.PoNumber, N'VENDOR1', N'N'
FROM @PO p;
PRINT '  headers: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

/* ---------------- detail lines ------------------------------------------ */
-- Two lines for KAMPO-1, one for everything else. schedule_number defaults to 0
-- and is part of pk_po_detail, so it is left to the default deliberately - the
-- detail-comment FK carries it too and both must agree.
INSERT dbo.t_po_detail (po_number, line_number, item_number, wh_id, qty, location_id, closed_date)
SELECT m.po_number, l.n, N'PRODUKT1', N'K01', 10, N'B001', m.closed_date
FROM dbo.t_po_master m
CROSS JOIN (VALUES (N'1'), (N'2')) AS l(n)
WHERE m.po_number LIKE N'KAMPO-%'
  AND (m.po_number = N'KAMPO-1' OR l.n = N'1');
PRINT '  detail lines: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

/* ---------------- header comment (KAMPO-1 only) ------------------------- */
INSERT dbo.t_po_comment (po_number, wh_id, comment_type, comment_text, sequence, comment_date)
VALUES (N'KAMPO-1', N'K01', N'R', N'kAM test header comment', 0, '2024-11-02');
PRINT '  header comments: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

/* ---------------- detail comments (KAMPO-1 only) ------------------------ */
-- These are the CASCADE victims. Two of them, on both lines, so a wrong delete
-- order loses a measurable number rather than a single row that might be missed.
INSERT dbo.t_po_detail_comment (wh_id, po_number, line_number, item_number, comment_text)
SELECT N'K01', N'KAMPO-1', d.line_number, N'PRODUKT1',
       N'kAM test line comment on line ' + d.line_number
FROM dbo.t_po_detail d
WHERE d.po_number = N'KAMPO-1';
PRINT '  detail comments: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

/* ---------------- shipments and the junction ---------------------------- */
-- KAMSH-CLOSED carries KAMPO-1 (status C), KAMSH-OPEN carries KAMPO-6 (status O).
-- The pair is what makes section D's exposure count meaningful: without an open
-- shipment in the data, D would report 0 whether it worked or not.
INSERT dbo.t_rcpt_ship (wh_id, shipment_number, carrier_id, date_expected, date_received, status, workers_assigned)
VALUES (N'K01', N'KAMSH-CLOSED', 1, '2024-11-05', '2024-11-06', N'C', 0),
       (N'K01', N'KAMSH-OPEN',   1, '2024-12-05', NULL,         N'O', 0);
PRINT '  shipments: ' + CAST(@@ROWCOUNT AS varchar(20));

INSERT dbo.t_rcpt_ship_po (wh_id, shipment_number, po_number)
VALUES (N'K01', N'KAMSH-CLOSED', N'KAMPO-1'),
       (N'K01', N'KAMSH-OPEN',   N'KAMPO-6');
PRINT '  shipment links: ' + CAST(@@ROWCOUNT AS varchar(20));
GO

/* ---------------- what the run is expected to do ------------------------ */
DECLARE @Ret int = $(RetentionDays), @Lag int = 1440;
DECLARE @Cut datetime2(0) = DATEADD(MINUTE, -@Lag, DATEADD(DAY, -@Ret, CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz nvarchar(200) = N'$(SourceTimezone)';

PRINT '';
PRINT 'Cutoff (UTC): ' + CONVERT(varchar(30), @Cut, 126);

SELECT
    Section   = 'EXPECTED',
    m.po_number,
    m.status,
    m.closed_date,
    Rows_     = 1
              + (SELECT COUNT(*) FROM dbo.t_po_detail d         WHERE d.po_number = m.po_number AND d.wh_id = m.wh_id)
              + (SELECT COUNT(*) FROM dbo.t_po_comment c        WHERE c.po_number = m.po_number AND c.wh_id = m.wh_id)
              + (SELECT COUNT(*) FROM dbo.t_po_detail_comment dc WHERE dc.po_number = m.po_number AND dc.wh_id = m.wh_id)
              + (SELECT COUNT(*) FROM dbo.t_rcpt_ship_po rsp    WHERE rsp.po_number = m.po_number AND rsp.wh_id = m.wh_id),
    LinkedShipmentStatus = ISNULL((SELECT MAX(rs.status) FROM dbo.t_rcpt_ship_po rsp
                                   JOIN dbo.t_rcpt_ship rs ON rs.wh_id = rsp.wh_id AND rs.shipment_number = rsp.shipment_number
                                   WHERE rsp.po_number = m.po_number AND rsp.wh_id = m.wh_id), N'(none)'),
    Expected  = CASE
                  WHEN m.status <> N'C'      THEN 'KEEP status'
                  WHEN m.closed_date IS NULL THEN 'KEEP no closed_date'
                  WHEN CAST(CAST(m.closed_date AS datetime2) AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @Cut
                                             THEN 'ARCHIVE'
                  ELSE 'KEEP recent'
                END
FROM dbo.t_po_master m
WHERE m.po_number LIKE N'KAMPO-%'
ORDER BY m.po_number;

PRINT '';
PRINT 'Three documents must survive. A run that archives all six is a FAILURE.';
PRINT 'KAMPO-6 is expected to be archived even though its shipment is open -';
PRINT 'that is the exposure section D of 27_seed_po_set.sql reports.';
GO
