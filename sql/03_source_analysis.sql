-- ============================================================================
-- 03 - SOURCE SCHEMA ANALYSIS (read-only)
-- ============================================================================
-- Run this on the TARGET instance BEFORE seeding any configuration. The two seed
-- scripts encode assumptions about the Warehouse Advantage schema that were
-- verified on one instance; a different WA version, a customer customisation or a
-- different module set can invalidate them. This script re-checks every one of
-- them and prints OK / WARN / STOP.
--
-- What it verifies, and why each matters:
--   A  the tables the configuration references exist
--   B  the columns the expressions reference exist, with compatible types
--   C  the anchor really is (order_number, wh_id) - i.e. order_number alone is
--      NOT unique. If a single-column unique index exists on this instance, the
--      configuration is over-specified but still correct.
--   D  the CASCADE graph out of t_order - anything cascading that is NOT in the
--      archive set gets destroyed WITHOUT a copy
--   E  which date columns carry the 1900 sentinel default (drives the cutoff shape)
--   F  the status domain, from the instance's own lookup table
--   G  t_tran_log's order linkage columns and its enforced child FKs
--   H  the work-queue linkage (t_pick_detail.work_q_id) and dependency tables
-- ============================================================================
:setvar SourceDb "AAD"

:on error exit

USE [$(SourceDb)];
GO
SET NOCOUNT ON;
GO

PRINT '=== Source schema analysis: $(SourceDb) ===';
GO

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- A) Required tables ---';
-------------------------------------------------------------------------------
SELECT
    Section = 'A_TABLES',
    x.TableName,
    Present = CASE WHEN OBJECT_ID(N'dbo.' + x.TableName, N'U') IS NOT NULL THEN 'yes' ELSE 'NO' END,
    Rows_   = ISNULL((SELECT SUM(p.rows) FROM sys.partitions p
                      WHERE p.object_id = OBJECT_ID(N'dbo.' + x.TableName) AND p.index_id IN (0,1)), -1),
    UsedBy  = x.UsedBy,
    Verdict = CASE WHEN OBJECT_ID(N'dbo.' + x.TableName, N'U') IS NULL AND x.Required = 1 THEN 'STOP - required table missing'
                   WHEN OBJECT_ID(N'dbo.' + x.TableName, N'U') IS NULL THEN 'WARN - optional table missing; drop it from the ObjectSpec set'
                   ELSE 'OK' END
FROM (VALUES
    (N't_order',                1, N'order process - ANCHOR table'),
    (N't_order_detail',         1, N'order process'),
    (N't_order_comment',        1, N'order process'),
    (N't_order_detail_comment', 1, N'order process'),
    (N't_pack',                 1, N'order process - CASCADE victim'),
    (N't_pick_detail',          1, N'order process'),
    (N't_tran_log',             1, N'order process'),
    (N't_work_q',               1, N'work-queue process - driving table'),
    (N't_work_q_assignment',    1, N'work-queue process'),
    (N't_work_q_dependency',    1, N'work-queue process'),
    (N't_tran_log_reason',      0, N'NOT archived - checked for the FK blocker'),
    (N't_tran_log_sn',          0, N'NOT archived - checked for the FK blocker'),
    (N't_lookup',               0, N'status domain source'),
    (N't_whse',                 0, N'warehouse list'),
    (N't_client',               0, N'restore-time FK dependency')
) AS x(TableName, Required, UsedBy)
ORDER BY x.TableName;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- B) Required columns and their types ---';
-------------------------------------------------------------------------------
SELECT
    Section = 'B_COLUMNS',
    x.TableName,
    x.ColumnName,
    x.Role,
    Present  = CASE WHEN c.column_id IS NULL THEN 'NO' ELSE 'yes' END,
    DataType = ISNULL(ty.name, N'-') +
               CASE WHEN ty.name IN (N'nvarchar', N'nchar') THEN N'(' + CAST(c.max_length / 2 AS varchar(10)) + N')'
                    WHEN ty.name IN (N'varchar', N'char')   THEN N'(' + CAST(c.max_length AS varchar(10)) + N')'
                    ELSE N'' END,
    Nullable = CASE WHEN c.is_nullable = 1 THEN 'null' WHEN c.column_id IS NOT NULL THEN 'not null' ELSE '-' END,
    Verdict  = CASE WHEN c.column_id IS NULL THEN 'STOP - expression references a column that does not exist' ELSE 'OK' END
FROM (VALUES
    (N't_order',    N'order_number',              N'anchor Key1'),
    (N't_order',    N'wh_id',                     N'anchor Key2'),
    (N't_order',    N'status',                    N'archiving gate'),
    (N't_order',    N'lock_flag',                 N'archiving gate'),
    (N't_order',    N'consolidated_order_number', N'archiving gate'),
    (N't_order',    N'order_date',                N'cutoff fallback (NOT NULL)'),
    (N't_order',    N'actual_ship_date',          N'cutoff primary (no default = clean)'),
    (N't_tran_log', N'outbound_order_number',     N'join to the order'),
    (N't_tran_log', N'inbound_order_number',      N'MUST NOT be joined - it is a purchase order'),
    (N't_tran_log', N'wh_id',                     N'join to the order'),
    (N't_tran_log', N'start_tran_date',           N'reporting / index'),
    (N't_work_q',   N'work_q_id',                 N'work-queue Key1'),
    (N't_work_q',   N'wh_id',                     N'work-queue warehouse'),
    (N't_work_q',   N'work_status',               N'work-queue gate'),
    (N't_work_q',   N'datetime_stamp',            N'work-queue cutoff'),
    (N't_pick_detail', N'work_q_id',              N'documents the order->work_q link (not used by config)'),
    (N't_pick_detail', N'order_number',           N'join to the order'),
    (N't_pick_detail', N'wh_id',                  N'join to the order')
) AS x(TableName, ColumnName, Role)
LEFT JOIN sys.columns c
       ON c.object_id = OBJECT_ID(N'dbo.' + x.TableName)
      AND c.name = x.ColumnName
LEFT JOIN sys.types ty ON ty.user_type_id = c.user_type_id
ORDER BY x.TableName, x.ColumnName;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- C) Is the anchor really composite? ---';
-------------------------------------------------------------------------------
SELECT
    Section   = 'C_ANCHOR_KEY',
    IndexName = i.name,
    i.type_desc,
    i.is_unique,
    KeyCols   = STUFF((SELECT N', ' + c2.name
                       FROM sys.index_columns ic2
                       JOIN sys.columns c2 ON c2.object_id = ic2.object_id AND c2.column_id = ic2.column_id
                       WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id AND ic2.is_included_column = 0
                       ORDER BY ic2.key_ordinal
                       FOR XML PATH(''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'')
FROM sys.indexes i
WHERE i.object_id = OBJECT_ID(N'dbo.t_order')
  AND i.is_unique = 1
ORDER BY i.is_primary_key DESC, i.name;

SELECT
    Section = 'C_VERDICT',
    Verdict = CASE
        WHEN EXISTS
        (
            -- a UNIQUE index whose ONLY key column is order_number
            SELECT 1 FROM sys.indexes i
            WHERE i.object_id = OBJECT_ID(N'dbo.t_order') AND i.is_unique = 1
              AND (SELECT COUNT(*) FROM sys.index_columns ic WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0) = 1
              AND EXISTS (SELECT 1 FROM sys.index_columns ic
                          JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                          WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0 AND c.name = N'order_number')
        )
        THEN 'INFO - order_number IS unique on its own here. The composite (order_number, wh_id) key stays correct, just over-specified.'
        ELSE 'OK - order_number is NOT unique on its own; the composite anchor key is REQUIRED.'
    END,
    Warehouses = (SELECT COUNT_BIG(*) FROM dbo.t_whse);

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- D) CASCADE graph out of t_order (rows destroyed with the header) ---';
-------------------------------------------------------------------------------
-- Any table listed here with delete_referential_action_desc = CASCADE loses its
-- rows when a header is deleted, whether or not it is archived. Every such table
-- MUST be in the ObjectSpec set or its data is lost with no copy.
SELECT
    Section        = 'D_CASCADE',
    ChildTable     = OBJECT_NAME(fk.parent_object_id),
    ParentTable    = OBJECT_NAME(fk.referenced_object_id),
    ForeignKey     = fk.name,
    OnDelete       = fk.delete_referential_action_desc,
    FkColumns      = STUFF((SELECT N', ' + pc.name
                            FROM sys.foreign_key_columns fkc
                            JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
                            WHERE fkc.constraint_object_id = fk.object_id
                            ORDER BY fkc.constraint_column_id
                            FOR XML PATH(''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''),
    InArchiveSet   = CASE WHEN OBJECT_NAME(fk.parent_object_id) IN
                          (N't_order_detail', N't_order_comment', N't_order_detail_comment', N't_pack', N't_order')
                          THEN 'yes' ELSE 'NO' END,
    Verdict        = CASE WHEN fk.delete_referential_action_desc = N'CASCADE'
                           AND OBJECT_NAME(fk.parent_object_id) NOT IN
                               (N't_order_detail', N't_order_comment', N't_order_detail_comment', N't_pack', N't_order')
                          THEN 'STOP - cascades but is NOT archived: its rows would be destroyed without a copy'
                          ELSE 'OK' END
FROM sys.foreign_keys fk
WHERE fk.referenced_object_id IN (OBJECT_ID(N'dbo.t_order'), OBJECT_ID(N'dbo.t_order_detail'))
ORDER BY OnDelete DESC, ChildTable;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- E) Sentinel-date defaults on t_order ---';
-------------------------------------------------------------------------------
-- Columns defaulted to 1900-01-01 look "very old" instead of "not happened yet".
-- Using one of them as a cutoff would archive live documents. This lists which
-- ones are affected on THIS instance; actual_ship_date should have NO default.
SELECT
    Section    = 'E_DEFAULTS',
    ColumnName = c.name,
    DefaultDef = dc.definition,
    Verdict    = CASE
                     WHEN c.name = N'actual_ship_date' AND dc.definition IS NOT NULL
                          THEN 'WARN - actual_ship_date HAS a default here; the "genuinely NULL until shipped" assumption does not hold'
                     WHEN dc.definition LIKE N'%1900%' THEN 'INFO - sentinel default; never use as a cutoff without NULLIF'
                     ELSE 'OK'
                 END
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
WHERE c.object_id = OBJECT_ID(N'dbo.t_order')
  AND ty.name IN (N'datetime', N'datetime2', N'date', N'smalldatetime')
ORDER BY c.name;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- F) Status domain from this instance''s lookup table ---';
-------------------------------------------------------------------------------
SELECT
    Section    = 'F_STATUS',
    StatusCode = l.[text],
    Meaning    = l.description,
    InWhitelist = CASE WHEN l.[text] IN (N'S', N'D') THEN 'YES - archivable' ELSE 'no - retained' END
FROM dbo.t_lookup l
WHERE l.source = N't_order' AND l.lookup_type = N'STATUS'
ORDER BY l.sequence;

SELECT
    Section = 'F_WORKQ_STATUS',
    StatusCode = l.[text],
    Meaning    = l.description,
    InWhitelist = CASE WHEN l.[text] IN (N'C', N'P') THEN 'YES - archivable' ELSE 'no - retained' END
FROM dbo.t_lookup l
WHERE l.source = N't_work_q' AND l.lookup_type = N'STATUS'
ORDER BY l.sequence;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- G) t_tran_log linkage and its enforced child FKs ---';
-------------------------------------------------------------------------------
SELECT
    Section    = 'G_TRANLOG_FK',
    ChildTable = OBJECT_NAME(fk.parent_object_id),
    ForeignKey = fk.name,
    OnDelete   = fk.delete_referential_action_desc,
    Verdict    = 'STOP if rows exist - see 09_preflight_data.sql section E. This FK blocks deleting the parent t_tran_log row, and the child cannot be reached from the order key.'
FROM sys.foreign_keys fk
WHERE fk.referenced_object_id = OBJECT_ID(N'dbo.t_tran_log');

SELECT
    Section = 'G_TRANLOG_ORDERCOLS',
    ColumnName = c.name,
    Meaning = CASE c.name
                  WHEN N'outbound_order_number'  THEN 'THE join column - outbound/shipping order'
                  WHEN N'inbound_order_number'   THEN 'purchase order (t_po_master.po_number) - MUST NOT be joined to t_order'
                  WHEN N'outbound_order_number2' THEN 'second order, tran_type 855 only'
                  WHEN N'load_id'                THEN 'load - fans out across many orders, not used'
                  WHEN N'work_q_id'              THEN 'work queue - two hops from the order, not used'
                  ELSE 'other' END
FROM sys.columns c
WHERE c.object_id = OBJECT_ID(N'dbo.t_tran_log')
  AND c.name IN (N'outbound_order_number', N'inbound_order_number', N'outbound_order_number2', N'load_id', N'work_q_id')
ORDER BY c.name;

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- H) Work-queue linkage ---';
-------------------------------------------------------------------------------
SELECT
    Section = 'H_WORKQ',
    Finding = 't_pick_detail.work_q_id present',
    Value_  = CASE WHEN COL_LENGTH(N'dbo.t_pick_detail', N'work_q_id') IS NOT NULL THEN 'yes' ELSE 'NO' END,
    Note    = 'This is the real order->work_q path (t_order -> t_pick_detail -> t_work_q). It is documented but NOT usable as a child join: the keyset comes from the anchor table alone and SELECT is forbidden in config SQL.'
UNION ALL
SELECT 'H_WORKQ', 't_work_q FK count',
       CAST((SELECT COUNT(*) FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.t_work_q') OR referenced_object_id = OBJECT_ID(N'dbo.t_work_q')) AS varchar(10)),
       'Expected 0. With no FKs the delete order is not enforced by the engine, which is why the parent-before-children order in 05_seed_workq.sql is safe.'
UNION ALL
SELECT 'H_WORKQ', 'pick_ref_number owners in DB',
       CAST((SELECT COUNT(*) FROM sys.columns WHERE name = N'pick_ref_number') AS varchar(10)),
       'pick_ref_number is POLYMORPHIC (order_number / load_id / wave_id / license plate depending on work_type) and is deliberately NOT used for joining.';
GO

PRINT '';
PRINT '03_source_analysis: done. Resolve every STOP before seeding the configuration.';
GO
