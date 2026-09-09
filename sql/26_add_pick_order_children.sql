-- ============================================================================
-- 26 - TWO CHILD TABLES THE DATA-MODEL ANALYSIS FOUND MISSING
-- ============================================================================
-- Adds two ObjectSpec rows to sets that already exist and are already tested.
-- No new process, no new key, no change to any cutoff or gate - so the existing
-- test evidence for those sets stays valid and only the new tables need proving.
--
--   t_pick_container  -> AAD_ORDER_ARCH       joined on (order_number, wh_id)
--   t_pick_task_uom   -> AAD_PICKDETAIL_ARCH  joined on (pick_id)
--
-- WHY THESE TWO, AND NOT THE OTHER FIFTY-ONE CANDIDATES
--
-- The supplied data models (WA-1cast, WA-2cast, AAD-Notify) document every
-- parent-child relation of the five configured sets, and every one of them was
-- already configured. But those models cover only 185 of AAD's 394 tables, and
-- five of our own fourteen tables appear in NO model at all (t_allocation,
-- t_work_q + its two children, ADV.t_log_message). AAD also has just 217 foreign
-- keys, and t_work_q and t_allocation have none - so parent-child logic here is
-- mostly LOGICAL, expressed as shared key columns rather than declared.
--
-- Searching on shared key columns produced 53 candidates. They were then filtered
-- on one question that decides the matter: DOES THE APPLICATION DELETE IT ITSELF?
-- A table the WMS purges needs no retention from us, and archiving it would race
-- the application's own logic. That test eliminated almost everything:
--   * t_tran_log_holding (+ _reason, _sn) - usp_process_tran_log is a drain loop:
--     it takes MAX(tran_log_holding_id) as a high-water mark, copies the rows into
--     t_tran_log, then DELETEs everything <= that mark with no filter at all, and
--     loops until the table is empty. Its rows are transactions IN FLIGHT.
--   * the cartonisation/optimiser family (t_cartonize_results,
--     t_container_optimize_block/status/xml) - usp_cartonize_q and
--     usp_afa_hold_shipment delete them by cartonization_batch_id; usp_cartonize_q
--     even runs our exact candidate predicate itself.
--   * t_sto_attrib_collection_master - has a detail_checksum column and is
--     referenced by nine tables including t_stored_item (live inventory) and
--     t_bom_detail. It is a content-deduplicated shared pool, not a child.
--   * master and configuration data - t_item_uom (88 referencing modules),
--     t_pick_put_master/detail, t_employee, t_item_master. Note that pick_put_id
--     is a pick/put PROFILE, a different concept from pick_id.
--
-- The two tables below survived that filter: nothing in the WMS deletes them on
-- the normal path, they carry the anchor key, and they are document-scoped.
--
-- NOT DONE HERE, DELIBERATELY: t_order_manifest also survived, but it needs a
-- third key (order_id) added to the ORDER key spec and it is a heap with no index
-- at all, so its delete join would scan the whole table every batch. Small
-- benefit, largest blast radius - left out until someone asks for it.
-- ============================================================================
:setvar AdminDb "kArchiveManagerAdmin"
:setvar WmsDb "AAD"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---------------------------------------------------------------------------
   Refuse to run against a configuration that does not have the two parent sets,
   and refuse if the source tables are not there. A missing table would otherwise
   be discovered later as a validation warning rather than now as a clear stop.
   --------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM arch.Process WHERE ProcessCode = N'AAD_ORDER_ARCH')
    THROW 60700, 'AAD_ORDER_ARCH does not exist - run 04_seed_order.sql / 25_seed_document_sets.sql first.', 1;
IF NOT EXISTS (SELECT 1 FROM arch.Process WHERE ProcessCode = N'AAD_PICKDETAIL_ARCH')
    THROW 60701, 'AAD_PICKDETAIL_ARCH does not exist - run 20_seed_standalone.sql first.', 1;
GO

DECLARE @missing nvarchar(max) = N'';
DECLARE @chk nvarchar(max) = N'
SELECT @out = STUFF((SELECT N'', '' + t.n FROM (VALUES (N''t_pick_container''), (N''t_pick_task_uom'')) AS t(n)
                     WHERE NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(WmsDb)') + N'.sys.tables st
                                       WHERE st.name = t.n COLLATE DATABASE_DEFAULT)
                     FOR XML PATH('''')), 1, 2, '''');';
EXEC sys.sp_executesql @chk, N'@out nvarchar(max) OUTPUT', @out = @missing OUTPUT;

IF @missing IS NOT NULL AND @missing <> N''
BEGIN
    PRINT 'Missing in $(WmsDb): ' + @missing;
    THROW 60702, 'A source table this script configures does not exist. Nothing was changed.', 1;
END
ELSE
    PRINT 'Both source tables are present in $(WmsDb).';
GO

/* ===========================================================================
   1) t_pick_container -> AAD_ORDER_ARCH
   ===========================================================================
   A container is a per-order carton instance: 31 columns of shipping fact -
   tracking_number, bol_number, freight_cost, manifest_status, actual_ship_date,
   plus print_data nvarchar(max). Created per document by usp_allocate and
   usp_bpk_create_container_record.

   IT BELONGS TO THE ORDER, NOT TO THE PICK. It carries a single order_number and
   is shared across many picks of the same order, which is why the application's
   own removal path (usp_afa_remove_line_data) deletes a container only when NO
   pick of that order still references it. Order-granularity archiving reproduces
   that semantics; pick-granularity would break it.

   NOTHING PURGES IT ON THE SHIP PATH - VERIFIED, NOT ASSUMED. A pattern search
   for DELETE near the table name lists usp_shp_tx, which would have made this a
   self-managed table. Reading the procedure disproves it: usp_shp_tx mentions
   t_pick_container only at lines 282 and 463, both LEFT OUTER JOIN ... WITH
   (NOLOCK), and its four DELETEs target serial numbers, t_stored_item,
   t_hu_master and t_work_q_assignment. Every DELETE of t_pick_container in the
   database is an undo or hold path (usp_afa_remove_*, usp_afo_remove_*,
   usp_*_hold_*, usp_replan_allocated_picks). Containers of shipped orders are
   never removed.

   DeleteOrder 45: after t_pack (40), before the anchor t_order (50). The anchor
   is always deleted last, so anything joined to it must precede it.

   ONE ACCEPTED LIMITATION: order_number is NULLABLE on this table. A container
   with no order can never match the predicate and is left in place. That is the
   safe direction - we never delete a row we cannot attribute - but it does mean
   the table is not fully drained by this set. Rows in that state need a separate
   answer if they turn out to be common on a live instance.
   =========================================================================== */
DECLARE @PcOrder sysname       = N'AAD_ORDER_ARCH';
DECLARE @By      nvarchar(256) = N'kam-deploy';
DECLARE @RsnPc   nvarchar(1000) = N'Per-order carton and manifest detail. Found by the data-model analysis: no WMS process removes it after shipping, so it accumulates for the life of the database.';
DECLARE @CsId    bigint = NULL;
DECLARE @OsId    int    = NULL;

EXEC arch.usp_Api_SaveObjectSpec
    @ObjectSpecId             = @OsId OUTPUT,
    @ProcessCode              = @PcOrder,
    @RequestedBy              = @By,
    @ChangeReason             = @RsnPc,
    @SourceSchema             = N'dbo',
    @SourceTable              = N't_pick_container',
    @DeleteOrder              = 45,
    @DeleteMode               = 1,
    @TimestampExpr            = NULL,   -- rides the anchor's cutoff
    @JoinToAnchorPredicateSql = N't.order_number = k.Key1 AND t.wh_id = k.Key2',
    @AdditionalWhereSql       = NULL,
    @ArchiveSchema            = N'{SourceDb}',
    @ArchiveTable             = NULL,
    @RequireArchiveForDelete  = 1,
    @NaturalKeyLabel          = N'ORDER_NUMBER',
    @ConfigChangeSetId        = @CsId OUTPUT;

-- i_pick_container_ordnum is (order_number, wh_id) - exactly the join columns, in
-- that order - so this one is genuinely satisfied, unlike t_pack whose
-- requirement is on record as MISSING.
SET @OsId = NULL;
DECLARE @IrId int = NULL;
EXEC arch.usp_Api_SaveIndexRequirement
    @IndexRequirementId = @IrId OUTPUT,
    @ProcessCode        = @PcOrder,
    @RequestedBy        = @By,
    @ChangeReason       = @RsnPc,
    @RequirementType    = N'JOIN',
    @SourceSchema       = N'dbo',
    @SourceTable        = N't_pick_container',
    @KeyColumnsCsv      = N'order_number,wh_id',
    @IsMandatory        = 0,
    @Notes              = N'Satisfied by the existing i_pick_container_ordnum (order_number, wh_id) - the join seeks. No index is needed from the schema owner.',
    @ConfigChangeSetId  = @CsId OUTPUT;
GO

/* ===========================================================================
   2) t_pick_task_uom -> AAD_PICKDETAIL_ARCH
   ===========================================================================
   Per-pick cartonisation detail: how one pick's quantity maps to uom and pattern
   inside a carton. pick_id is bigint NOT NULL, the same type as
   t_pick_detail.pick_id, so the predicate covers every row - there is no orphan
   class here, unlike t_pick_container.

   It has no order_number at all, so PICKDETAIL is the only set it could join to.
   Across the whole database only two modules reference it (usp_afo_hold_wave and
   usp_afa_hold_shipment) and both only delete it while un-releasing work. Nothing
   ever SELECTs it. After a normal pick-and-ship the rows are dead weight.

   DeleteOrder 15: before the anchor t_pick_detail (20), alongside t_allocation.
   =========================================================================== */
DECLARE @PcPick sysname        = N'AAD_PICKDETAIL_ARCH';
DECLARE @By2    nvarchar(256)  = N'kam-deploy';
DECLARE @RsnPu  nvarchar(1000) = N'Per-pick cartonisation detail. Found by the data-model analysis: nothing in the WMS reads it and only the un-release paths delete it, so it survives every completed pick.';
DECLARE @CsId2  bigint = NULL;
DECLARE @OsId2  int    = NULL;

EXEC arch.usp_Api_SaveObjectSpec
    @ObjectSpecId             = @OsId2 OUTPUT,
    @ProcessCode              = @PcPick,
    @RequestedBy              = @By2,
    @ChangeReason             = @RsnPu,
    @SourceSchema             = N'dbo',
    @SourceTable              = N't_pick_task_uom',
    @DeleteOrder              = 15,
    @DeleteMode               = 1,
    @TimestampExpr            = NULL,
    @JoinToAnchorPredicateSql = N't.pick_id = k.Key1',
    @AdditionalWhereSql       = NULL,
    @ArchiveSchema            = N'{SourceDb}',
    @ArchiveTable             = NULL,
    @RequireArchiveForDelete  = 1,
    @NaturalKeyLabel          = N'PICK_ID',
    @ConfigChangeSetId        = @CsId2 OUTPUT;

-- This one is NOT satisfied, and the requirement says so. The table is a HEAP
-- with no primary key, and its only index ui_pick_task_uom leads on
-- (wh_id, cartonization_batch_id, planned_actual, line_number, pick_id) - pick_id
-- is the FIFTH key column, so a join on pick_id alone cannot seek it and will scan
-- the heap once per batch. Registered as MISSING for the schema owner to action,
-- exactly as was done for t_pack and t_work_q_dependency. Since the process has
-- RequireSupportingIndex = 1 this will surface as a validation WARN until an index
-- exists - which is the intended behaviour, not a defect.
DECLARE @IrId2 int = NULL;
EXEC arch.usp_Api_SaveIndexRequirement
    @IndexRequirementId = @IrId2 OUTPUT,
    @ProcessCode        = @PcPick,
    @RequestedBy        = @By2,
    @ChangeReason       = @RsnPu,
    @RequirementType    = N'JOIN',
    @SourceSchema       = N'dbo',
    @SourceTable        = N't_pick_task_uom',
    @KeyColumnsCsv      = N'pick_id',
    @IsMandatory        = 0,
    @Notes              = N'MISSING - t_pick_task_uom is a heap whose only index ui_pick_task_uom has pick_id as its fifth key column, so the delete join scans. Suggested for the schema owner: CREATE NONCLUSTERED INDEX IX_t_pick_task_uom_pick_id ON dbo.t_pick_task_uom (pick_id). NEVER created by this package - see the house rule in 08_source_indexes.sql.',
    @ConfigChangeSetId  = @CsId2 OUTPUT;
GO

PRINT '';
PRINT '26_add_pick_order_children: configuration applied.';
GO

/* ---------------------------- verification ------------------------------- */
SELECT Section = 'OBJECTSPEC', p.ProcessCode, os.DeleteOrder, os.SourceTable,
       os.JoinToAnchorPredicateSql, os.RequireArchiveForDelete, os.NaturalKeyLabel
FROM arch.ObjectSpec os
JOIN arch.Process p ON p.ProcessId = os.ProcessId
WHERE p.ProcessCode IN (N'AAD_ORDER_ARCH', N'AAD_PICKDETAIL_ARCH')
ORDER BY p.ProcessCode, os.DeleteOrder;

-- The anchor must still be last in its set. If a DeleteOrder collision pushed it
-- out of last place the set would delete its header before its children.
SELECT Section = 'ANCHOR_IS_LAST', p.ProcessCode, p.AnchorTable,
       AnchorDeleteOrder = a.DeleteOrder,
       MaxDeleteOrder    = (SELECT MAX(os2.DeleteOrder) FROM arch.ObjectSpec os2 WHERE os2.ProcessId = p.ProcessId),
       Verdict = CASE WHEN a.DeleteOrder = (SELECT MAX(os2.DeleteOrder) FROM arch.ObjectSpec os2 WHERE os2.ProcessId = p.ProcessId)
                      THEN 'ok - anchor deleted last' ELSE '*** ANCHOR IS NOT LAST ***' END
FROM arch.Process p
JOIN arch.ObjectSpec a ON a.ProcessId = p.ProcessId AND a.SourceTable = p.AnchorTable
WHERE p.ProcessCode IN (N'AAD_ORDER_ARCH', N'AAD_PICKDETAIL_ARCH')
ORDER BY p.ProcessCode;

-- No table may appear in two sets: two processes deleting the same rows on
-- different cutoffs is the one configuration error this package cannot recover
-- from. 25_seed_document_sets.sql makes the same check across all five sets.
SELECT Section = 'OVERLAP_CHECK', os.SourceTable, Sets = COUNT(DISTINCT os.ProcessId),
       Which = STUFF((SELECT N', ' + p2.ProcessCode
                      FROM arch.ObjectSpec os2 JOIN arch.Process p2 ON p2.ProcessId = os2.ProcessId
                      WHERE os2.SourceTable = os.SourceTable
                      ORDER BY p2.ProcessCode FOR XML PATH('')), 1, 2, '')
FROM arch.ObjectSpec os
GROUP BY os.SourceTable
HAVING COUNT(DISTINCT os.ProcessId) > 1;

IF @@ROWCOUNT = 0 PRINT 'OVERLAP_CHECK: no table is configured in more than one set.';
GO
