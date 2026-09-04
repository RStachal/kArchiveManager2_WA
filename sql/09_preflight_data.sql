-- ============================================================================
-- PRE-FLIGHT ON LIVE DATA - run this BEFORE the first real archive run
-- ============================================================================
-- READ-ONLY. Changes nothing. Its job is to answer, on the ACTUAL data of the
-- target instance, the questions the configuration cannot answer by itself.
--
-- Every section prints a verdict:
--   OK    - safe to proceed
--   WARN  - proceed, but understand what you are accepting
--   STOP  - do NOT run a real archive until this is resolved
--
-- Sections:
--   A  volume + date range of the candidate set (how much a first run would move)
--   B  the sentinel-date trap (are 1900-01-01 ship dates actually present?)
--   C  status domain reality check (are there values outside the documented set?)
--   D  order_id / natural-key consistency (a mismatch aborts an archive batch)
--   E  t_tran_log children (t_tran_log_reason / t_tran_log_sn) - the FK blocker
--   F  work_q_id global uniqueness (the TIMESTAMP single-key assumption)
--   G  work-queue dependency stranding risk
--   H  supporting indexes actually present
--   I  cross-warehouse order_number collisions
-- ============================================================================
:setvar SourceDb "AAD"
:setvar RetentionDays "90"
:setvar SourceTimezone "Central European Standard Time"

:on error exit

USE [$(SourceDb)];
GO

SET NOCOUNT ON;
GO

PRINT '=== kArchiveManager pre-flight on $(SourceDb) (READ-ONLY) ===';
GO

DECLARE @CutoffUtc datetime2(0) =
    DATEADD(MINUTE, -1440, DATEADD(DAY, -$(RetentionDays), CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz nvarchar(200) = N'$(SourceTimezone)';

PRINT 'Effective cutoff (UTC): ' + CONVERT(varchar(30), @CutoffUtc, 126);
PRINT 'Rows dated before that instant are eligible; the gates below still apply.';

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- A) Candidate volume for AAD_ORDER_ARCH ---';
-------------------------------------------------------------------------------
;WITH cand AS
(
    SELECT o.wh_id, o.order_number,
           AnchorUtc = CAST(CAST(COALESCE(NULLIF(o.actual_ship_date, '19000101'), o.order_date) AS datetime2)
                       AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0))
    FROM dbo.t_order o
    WHERE o.status IN (N'S', N'D')
      AND o.lock_flag IS NULL
      AND o.consolidated_order_number IS NULL
)
SELECT
    Section          = 'A_ORDER_CANDIDATES',
    TotalHeaders     = (SELECT COUNT_BIG(*) FROM dbo.t_order),
    GatedHeaders     = (SELECT COUNT_BIG(*) FROM cand),
    EligibleHeaders  = (SELECT COUNT_BIG(*) FROM cand WHERE AnchorUtc < @CutoffUtc),
    OldestEligible   = (SELECT MIN(AnchorUtc) FROM cand WHERE AnchorUtc < @CutoffUtc),
    NewestEligible   = (SELECT MAX(AnchorUtc) FROM cand WHERE AnchorUtc < @CutoffUtc);

-- Row fan-out per eligible header, so the first run's size is known in advance.
;WITH cand AS
(
    SELECT o.wh_id, o.order_number
    FROM dbo.t_order o
    WHERE o.status IN (N'S', N'D')
      AND o.lock_flag IS NULL
      AND o.consolidated_order_number IS NULL
      AND CAST(CAST(COALESCE(NULLIF(o.actual_ship_date, '19000101'), o.order_date) AS datetime2)
          AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @CutoffUtc
)
SELECT Section = 'A_ROW_FANOUT', TableName = 't_order',                Rows_ = COUNT_BIG(*) FROM cand
UNION ALL SELECT 'A_ROW_FANOUT', 't_order_detail',         COUNT_BIG(*) FROM dbo.t_order_detail d         JOIN cand c ON c.wh_id = d.wh_id AND c.order_number = d.order_number
UNION ALL SELECT 'A_ROW_FANOUT', 't_order_comment',        COUNT_BIG(*) FROM dbo.t_order_comment x        JOIN cand c ON c.wh_id = x.wh_id AND c.order_number = x.order_number
UNION ALL SELECT 'A_ROW_FANOUT', 't_order_detail_comment', COUNT_BIG(*) FROM dbo.t_order_detail_comment x JOIN cand c ON c.wh_id = x.wh_id AND c.order_number = x.order_number
UNION ALL SELECT 'A_ROW_FANOUT', 't_pack',                 COUNT_BIG(*) FROM dbo.t_pack x                 JOIN cand c ON c.wh_id = x.wh_id AND c.order_number = x.order_number
UNION ALL SELECT 'A_ROW_FANOUT', 't_pick_detail',          COUNT_BIG(*) FROM dbo.t_pick_detail x          JOIN cand c ON c.wh_id = x.wh_id AND c.order_number = x.order_number
UNION ALL SELECT 'A_ROW_FANOUT', 't_tran_log',             COUNT_BIG(*) FROM dbo.t_tran_log x             JOIN cand c ON c.wh_id = x.wh_id AND c.order_number = x.outbound_order_number
ORDER BY TableName;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- B) Sentinel-date trap (1900-01-01 defaults instead of NULL) ---';
-------------------------------------------------------------------------------
-- If actual_ship_date carries the sentinel, the configured expression falls back
-- to order_date. That is intended, but you should know how many rows rely on it.
SELECT
    Section              = 'B_SENTINEL',
    ShipDateSentinel     = SUM(CASE WHEN o.actual_ship_date = '19000101' THEN 1 ELSE 0 END),
    ShipDateNull         = SUM(CASE WHEN o.actual_ship_date IS NULL THEN 1 ELSE 0 END),
    ShipDateReal         = SUM(CASE WHEN o.actual_ship_date IS NOT NULL AND o.actual_ship_date <> '19000101' THEN 1 ELSE 0 END),
    Verdict              = CASE
                               WHEN SUM(CASE WHEN o.actual_ship_date = '19000101' THEN 1 ELSE 0 END) = 0 THEN 'OK - no sentinel ship dates'
                               ELSE 'WARN - some documents fall back to order_date; confirm that is the intended retention basis'
                           END
FROM dbo.t_order o;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- C) Status domain reality check ---';
-------------------------------------------------------------------------------
-- The configuration whitelists status IN ('S','D'). There is NO check constraint
-- on the column, so the host interface can write anything. Any value listed here
-- that should be treated as terminal must be added to AnchorExtraWhereSql.
SELECT
    Section = 'C_STATUS_DOMAIN',
    o.status,
    Headers = COUNT_BIG(*),
    InWhitelist = CASE WHEN o.status IN (N'S', N'D') THEN 'YES - archivable' ELSE 'no - retained' END,
    KnownInLookup = CASE WHEN EXISTS
                         (SELECT 1 FROM dbo.t_lookup l
                          WHERE l.source = N't_order' AND l.lookup_type = N'STATUS'
                            AND l.[text] = o.status)
                    THEN 'yes' ELSE 'NO - undocumented value' END
FROM dbo.t_order o
GROUP BY o.status
ORDER BY Headers DESC;

SELECT
    Section = 'C_VERDICT',
    Verdict = CASE WHEN EXISTS
                   (SELECT 1 FROM dbo.t_order o
                    WHERE NOT EXISTS (SELECT 1 FROM dbo.t_lookup l
                                      WHERE l.source = N't_order' AND l.lookup_type = N'STATUS'
                                        AND l.[text] = o.status))
              THEN 'WARN - undocumented status values exist; review the C_STATUS_DOMAIN list before archiving'
              ELSE 'OK - every status value is in the documented lookup' END;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- D) order_id vs natural-key consistency ---';
-------------------------------------------------------------------------------
-- t_order_detail/t_order_comment carry BOTH a nullable order_id (NO_ACTION FK) and
-- the natural key (CASCADE FK). If a child row's order_id points at a DIFFERENT
-- header than its (wh_id, order_number), the NO_ACTION FK raises 547 and aborts
-- the whole archive batch.
SELECT
    Section = 'D_KEY_CONSISTENCY',
    TableName = 't_order_detail',
    Mismatched = COUNT_BIG(*)
FROM dbo.t_order_detail d
JOIN dbo.t_order o ON o.wh_id = d.wh_id AND o.order_number = d.order_number
WHERE d.order_id IS NOT NULL AND d.order_id <> o.order_id
UNION ALL
SELECT 'D_KEY_CONSISTENCY', 't_order_comment', COUNT_BIG(*)
FROM dbo.t_order_comment x
JOIN dbo.t_order o ON o.wh_id = x.wh_id AND o.order_number = x.order_number
WHERE x.order_id IS NOT NULL AND x.order_id <> o.order_id;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- E) t_tran_log children - THE KNOWN FK BLOCKER ---';
-------------------------------------------------------------------------------
-- t_tran_log_reason and t_tran_log_sn have ENFORCED foreign keys to
-- t_tran_log.tran_log_id. That id is not derivable from the order key, so those
-- children CANNOT be included in the order-anchored process, and the FK will
-- block the parent delete if any child row exists for an archived transaction.
-- If Blocking > 0 you must resolve this before enabling t_tran_log in the process
-- (options: purge those children first, drop t_tran_log from the ObjectSpec set,
--  or extend the product to support a second-level child join).
;WITH cand AS
(
    SELECT o.wh_id, o.order_number
    FROM dbo.t_order o
    WHERE o.status IN (N'S', N'D')
      AND o.lock_flag IS NULL
      AND o.consolidated_order_number IS NULL
      AND CAST(CAST(COALESCE(NULLIF(o.actual_ship_date, '19000101'), o.order_date) AS datetime2)
          AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @CutoffUtc
), tl AS
(
    SELECT x.tran_log_id
    FROM dbo.t_tran_log x
    JOIN cand c ON c.wh_id = x.wh_id AND c.order_number = x.outbound_order_number
)
SELECT
    Section = 'E_TRANLOG_CHILDREN',
    ReasonRows = (SELECT COUNT_BIG(*) FROM dbo.t_tran_log_reason r JOIN tl ON tl.tran_log_id = r.tran_log_id),
    SnRows     = (SELECT COUNT_BIG(*) FROM dbo.t_tran_log_sn s     JOIN tl ON tl.tran_log_id = s.tran_log_id),
    Verdict    = CASE
                     WHEN (SELECT COUNT_BIG(*) FROM dbo.t_tran_log_reason r JOIN tl ON tl.tran_log_id = r.tran_log_id)
                        + (SELECT COUNT_BIG(*) FROM dbo.t_tran_log_sn s     JOIN tl ON tl.tran_log_id = s.tran_log_id) = 0
                     THEN 'OK - no child rows on the eligible transactions; the FK will not fire'
                     ELSE 'STOP - child rows exist and their enforced FK WILL block the t_tran_log delete'
                 END;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- F) work_q_id global uniqueness (TIMESTAMP single-key assumption) ---';
-------------------------------------------------------------------------------
-- AAD_WORKQ_ARCH keys on work_q_id ALONE because the TIMESTAMP runner supports
-- only one key column. t_work_q's PK is (work_q_id, wh_id), so verify that no id
-- is reused across warehouses. If Duplicates > 0, do NOT enable that process.
SELECT
    Section    = 'F_WORKQ_KEY',
    Duplicates = COUNT_BIG(*),
    Verdict    = CASE WHEN COUNT_BIG(*) = 0
                      THEN 'OK - work_q_id is unique across warehouses; the single-key config is safe'
                      ELSE 'STOP - work_q_id is reused across warehouses; the single-key delete join could hit the wrong warehouse' END
FROM
(
    SELECT q.work_q_id
    FROM dbo.t_work_q q
    GROUP BY q.work_q_id
    HAVING COUNT(DISTINCT q.wh_id) > 1
) AS d;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- G) Work-queue dependency stranding risk ---';
-------------------------------------------------------------------------------
-- A finish-start ('FS') dependency parks the DEPENDENT queue on work_status='H'
-- until the parent completes. Archiving an eligible parent removes the dependency
-- row, which leaves a still-live dependent on Hold forever with no parent to
-- release it. This counts exactly those cases.
;WITH elig AS
(
    SELECT q.work_q_id
    FROM dbo.t_work_q q
    WHERE q.datetime_stamp IS NOT NULL
      AND q.work_status IN (N'C', N'P')
      AND CAST(TRY_CONVERT(datetime2, q.datetime_stamp)
          AT TIME ZONE @Tz AT TIME ZONE N'UTC' AS datetime2(0)) < @CutoffUtc
)
SELECT
    Section = 'G_WORKQ_STRANDING',
    StrandedDependents = COUNT_BIG(*),
    Verdict = CASE WHEN COUNT_BIG(*) = 0
                   THEN 'OK - no live dependent would lose its parent'
                   ELSE 'WARN - archiving these parents strands live dependents on Hold; release or resolve them first' END
FROM dbo.t_work_q_dependency dep
JOIN elig p ON p.work_q_id = dep.parent_work_q_id
JOIN dbo.t_work_q d ON d.work_q_id = dep.dependent_work_q_id
WHERE d.work_status NOT IN (N'C', N'P');

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- H) Supporting indexes actually present ---';
-------------------------------------------------------------------------------
-- These are the indexes the configuration DECLARES as requirements. A missing one
-- is never a blocker, but on production volume the candidate scan and the
-- transaction-log join become full scans of the biggest tables in the schema.
SELECT
    Section = 'H_INDEXES',
    x.TableName,
    x.NeededFor,
    Present = CASE WHEN EXISTS
                   (SELECT 1
                    FROM sys.indexes i
                    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal = 1
                    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                    WHERE i.object_id = OBJECT_ID(N'dbo.' + x.TableName)
                      AND c.name = x.LeadingColumn)
              THEN 'yes' ELSE 'NO' END,
    LeadingColumnWanted = x.LeadingColumn
FROM (VALUES
    (N't_order',             N'order_date',            N'candidate scan by retention cutoff'),
    (N't_tran_log',          N'outbound_order_number', N'join transactions to the order key'),
    (N't_pack',              N'wh_id',                 N'archive join + CASCADE enforcement'),
    (N't_work_q',            N'work_status',           N'work-queue candidate scan')
) AS x(TableName, LeadingColumn, NeededFor);

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- I) Cross-warehouse order_number collisions ---';
-------------------------------------------------------------------------------
-- Informational: proves whether the composite (order_number, wh_id) anchor is
-- doing real work on this data set, or whether the instance is single-warehouse.
SELECT
    Section = 'I_WAREHOUSES',
    Warehouses = (SELECT COUNT_BIG(*) FROM dbo.t_whse),
    OrderNumbersInMoreThanOneWh =
    (
        SELECT COUNT_BIG(*) FROM
        (
            SELECT o.order_number
            FROM dbo.t_order o
            GROUP BY o.order_number
            HAVING COUNT(DISTINCT o.wh_id) > 1
        ) AS d
    ),
    Note = 'If the second number is > 0, a single-column order_number anchor would have archived the wrong warehouse.';
GO

PRINT '';
PRINT '=== Pre-flight finished. Resolve every STOP before running 11_realrun_guarded.sql. ===';
GO
