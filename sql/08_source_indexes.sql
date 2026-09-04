-- ============================================================================
-- 08 - SOURCE INDEX REPORT  (READ-ONLY - CREATES NOTHING)
-- ============================================================================
-- !! HOUSE RULE: WE NEVER CREATE OUR OWN INDEXES IN A WMS DATABASE. !!
--    kArchiveManager only ever creates objects in its OWN databases
--    (kArchiveManagerAdmin, kArchiveManagerBackups). The source databases -
--    AAD, ADV and any other Koerber schema - are read/delete only. No indexes,
--    no columns, no constraints, no triggers.
--
--    This script therefore only REPORTS which indexes the configured processes
--    would benefit from. Handing that report to Koerber (or to whoever owns the
--    schema) is the correct next step. It does not create anything, and it has
--    no Apply switch to turn on.
--
-- ---------------------------------------------------------------------------
-- WHY THE RULE EXISTS - THIS WAS LEARNED THE HARD WAY ON THIS INSTANCE
-- ---------------------------------------------------------------------------
-- An earlier revision of this script did create four indexes in AAD, two of them
-- filtered. That broke the WMS write path, twice over:
--
--   1. SQL Server refuses ANY data modification on a table carrying a filtered
--      index (or an index on a computed column, or an indexed view) unless the
--      connection has QUOTED_IDENTIFIER ON - it fails with Msg 1934.
--   2. AAD is full of compiled objects that were created with
--      QUOTED_IDENTIFIER OFF: 240 of its 1,146 modules, including 8 ACTIVE
--      triggers - among them dbo.tr_order_master_insert on t_order.
--
--   The result: with a filtered index on t_order, that vendor trigger's UPDATE
--   failed and NO ORDER COULD BE INSERTED AT ALL. Reproduced again independently
--   on t_tran_log from a plain SET QUOTED_IDENTIFIER OFF session, which would
--   have stopped the WMS writing transaction history.
--
--   Neither failure was caught by usp_ValidateConfiguration - only by actually
--   trying to insert a row. That is exactly the class of damage the house rule
--   prevents: an archiving tool has no business changing the physical design of
--   a live vendor schema, however well-intentioned the index.
--
-- ---------------------------------------------------------------------------
-- CONSEQUENCE FOR PERFORMANCE, STATED HONESTLY
-- ---------------------------------------------------------------------------
-- Without these indexes the candidate scans below are table/clustered scans.
-- On an empty or small instance that costs nothing. At production volume it
-- matters, and the mitigations that stay inside our own remit are:
--   * run archiving in a maintenance window,
--   * keep MaxCandidates / MaxBatchesPerRun modest so each run is short,
--   * accept a longer first drain and let subsequent runs be incremental,
--   * or get the indexes approved and created BY THE SCHEMA OWNER.
-- arch.IndexRequirement still records the need, so
-- arch.usp_ValidateIndexRequirements keeps reporting the gap as a WARN with
-- SuggestedSql. That is visibility without interference, and it is the intended
-- end state - a permanent WARN here is not a defect.
--
-- ---------------------------------------------------------------------------
-- IF THE SCHEMA OWNER DOES APPROVE THEM
-- ---------------------------------------------------------------------------
-- Hand over the DDL from the report below and insist on two things:
--   * NO FILTERED INDEXES (no WHERE clause) - see the failure above. Put the
--     would-be filter column in INCLUDE instead.
--   * NO indexes on computed columns and no indexed views, for the same reason.
-- After they are created, re-run 07_validate.sql: the WARNs should clear.
-- ============================================================================
:setvar SourceDb "AAD"
:setvar AdminDb  "kArchiveManagerAdmin"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

PRINT '=== Source index report for $(SourceDb) - READ-ONLY, nothing will be created ===';
PRINT '';
GO

-------------------------------------------------------------------------------
-- A) What the configuration declares it needs, and whether it is there
-------------------------------------------------------------------------------
PRINT '--- A) Declared index requirements vs actual indexes ---';
GO
EXEC arch.usp_ValidateIndexRequirements;
GO

-------------------------------------------------------------------------------
-- B) Write-path exposure in the source database
--    Anything reported here means a filtered index / computed-column index /
--    indexed view on that table would break writes for those callers.
-------------------------------------------------------------------------------
PRINT '';
PRINT '--- B) QUOTED_IDENTIFIER exposure in $(SourceDb) ---';
GO
DECLARE @sql nvarchar(max) = N'
USE ' + QUOTENAME(N'$(SourceDb)') + N';

SELECT
    Section        = ''B_EXPOSURE'',
    ModulesTotal   = (SELECT COUNT_BIG(*) FROM sys.sql_modules),
    ModulesQiOff   = (SELECT COUNT_BIG(*) FROM sys.sql_modules WHERE uses_quoted_identifier = 0),
    TriggersQiOff  = (SELECT COUNT_BIG(*) FROM sys.sql_modules m JOIN sys.triggers t ON t.object_id = m.object_id WHERE m.uses_quoted_identifier = 0),
    Verdict        = CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules WHERE uses_quoted_identifier = 0)
                          THEN ''This database contains objects compiled with QUOTED_IDENTIFIER OFF. A filtered index, a computed-column index or an indexed view on a table they modify WILL break them (Msg 1934). Never add one.''
                          ELSE ''No QUOTED_IDENTIFIER OFF modules found - but a CLIENT connection can still use OFF, so the rule stands.'' END;

SELECT
    Section    = ''B_TRIGGERS_AT_RISK'',
    TableName  = OBJECT_NAME(t.parent_id),
    TriggerName = t.name,
    Disabled_  = t.is_disabled,
    Note       = ''An active trigger compiled with QUOTED_IDENTIFIER OFF: any filtered index on its table blocks every insert/update that fires it.''
FROM sys.triggers t
JOIN sys.sql_modules m ON m.object_id = t.object_id
WHERE m.uses_quoted_identifier = 0
  AND t.parent_id > 0
ORDER BY OBJECT_NAME(t.parent_id), t.name;

SELECT
    Section = ''B_EXISTING_RISKY_INDEXES'',
    TableName = OBJECT_NAME(i.object_id),
    IndexName = i.name,
    Kind_ = CASE WHEN i.has_filter = 1 THEN ''FILTERED'' ELSE ''computed-column'' END,
    FilterDef = ISNULL(i.filter_definition, N''-''),
    Verdict = ''PRE-EXISTING risk, not created by us. Writes to this table already require QUOTED_IDENTIFIER ON.''
FROM sys.indexes i
WHERE i.has_filter = 1
   OR EXISTS
   (
       SELECT 1
       FROM sys.index_columns ic
       JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
       WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND c.is_computed = 1
   );

SELECT
    Section = ''B_OUR_FOOTPRINT'',
    OurIndexes = (SELECT COUNT_BIG(*) FROM sys.indexes WHERE name LIKE N''IX[_]KAM[_]%'' OR name LIKE N''UX[_]KAM[_]%''),
    OurColumns = (SELECT COUNT_BIG(*) FROM sys.columns WHERE name LIKE N''kam[_]%''),
    Verdict = CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE name LIKE N''IX[_]KAM[_]%'' OR name LIKE N''UX[_]KAM[_]%'')
                     OR EXISTS (SELECT 1 FROM sys.columns WHERE name LIKE N''kam[_]%'')
                   THEN ''STOP - kArchiveManager objects exist in this WMS database. They must not. Drop them.''
                   ELSE ''OK - kArchiveManager has left no physical trace in this database, which is the required state.'' END;';
EXEC sys.sp_executesql @sql;
GO

-------------------------------------------------------------------------------
-- C) The DDL to hand to the schema owner, if and when they approve it
--    NOT EXECUTED. No filters anywhere - deliberately.
-------------------------------------------------------------------------------
PRINT '';
PRINT '--- C) Proposed DDL for the schema owner (NOT executed) ---';
GO
SELECT
    Section = 'C_PROPOSED_DDL',
    x.TableName,
    Purpose = x.Purpose,
    ProposedDdl = x.Ddl
FROM (VALUES
    (N't_order',
     N'Retention candidate scan on the order document set. status is an INCLUDE, never a filter.',
     N'CREATE NONCLUSTERED INDEX [IX_t_order_arch_cand] ON [dbo].[t_order] ([order_date], [wh_id], [order_number]) INCLUDE ([actual_ship_date], [lock_flag], [consolidated_order_number], [status]);'),
    (N't_pack',
     N'Archive join and ON DELETE CASCADE enforcement; t_pack has only pk_pack (id, wh_id).',
     N'CREATE NONCLUSTERED INDEX [IX_t_pack_wh_order] ON [dbo].[t_pack] ([wh_id], [order_number]);'),
    (N't_pick_detail',
     N'Pick retention scan: filters on status, orders by create_date; neither is indexed today.',
     N'CREATE NONCLUSTERED INDEX [IX_t_pick_detail_status_created] ON [dbo].[t_pick_detail] ([status], [create_date]) INCLUDE ([pick_id]);'),
    (N't_allocation',
     N'Child join from the pick keyset.',
     N'CREATE NONCLUSTERED INDEX [IX_t_allocation_pick] ON [dbo].[t_allocation] ([pick_id]);'),
    (N't_work_q',
     N'Work-queue retention scan: filters on work_status, orders by datetime_stamp.',
     N'CREATE NONCLUSTERED INDEX [IX_t_work_q_status_stamp] ON [dbo].[t_work_q] ([work_status], [datetime_stamp]) INCLUDE ([work_q_id], [wh_id], [work_type]);'),
    (N't_work_q_dependency',
     N'Dependent-side delete join; dependent_work_q_id is only the SECOND PK column.',
     N'CREATE NONCLUSTERED INDEX [IX_t_work_q_dep_dependent] ON [dbo].[t_work_q_dependency] ([dependent_work_q_id], [wh_id]) INCLUDE ([parent_work_q_id], [status], [dependency_type]);')
) AS x(TableName, Purpose, Ddl)
ORDER BY x.TableName;

SELECT
    Section = 'C_NOTE',
    Note = 't_tran_log needs NO new index: its retention cutoff uses start_tran_date, which is the leading key of the existing i_tran_log. The transaction-log set is self-anchored on tran_log_id (its clustered PK) and its children join on tran_log_id, which they already index. ADV.t_log_message needs none either: the existing clustered i_log_message leads on logged_on_utc, and the delete join uses that same column.';
GO

PRINT '';
PRINT '08_source_indexes: report complete. NOTHING was created.';
GO
