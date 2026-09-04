-- ============================================================================
-- 25 - DOCUMENT SETS: header > details, one table in exactly one process
-- ============================================================================
-- Completes the configuration into five document sets. Each set has ONE header
-- table and its details, deleted bottom-up (deepest detail first, header last),
-- and NO table appears in two sets.
--
--   AAD_ORDER_ARCH        header t_order
--                           10 t_order_detail_comment   (detail of a detail)
--                           20 t_order_comment
--                           30 t_order_detail           (detail)
--                           40 t_pack
--                           50 t_order                  <- HEADER, last
--
--   AAD_PICKDETAIL_ARCH   header t_pick_detail
--                           10 t_allocation
--                           20 t_pick_detail            <- HEADER, last
--
--   AAD_TRANLOG_ARCH      header t_tran_log
--                           10 t_tran_log_reason
--                           20 t_tran_log_sn
--                           30 t_tran_log               <- HEADER, last
--
--   AAD_WORKQ_ARCH        header t_work_q
--                           10 t_work_q_assignment
--                           20 t_work_q_dependency (parent side)
--                           30 t_work_q_dependency (dependent side)
--                           40 t_work_q                 <- HEADER, last
--
--   ADV_LOGMSG_ARCH       header t_log_message (a log line has no details)
--
-- ---------------------------------------------------------------------------
-- WHY t_pick_detail AND t_tran_log ARE NOT DETAILS OF t_order ANY MORE
-- ---------------------------------------------------------------------------
-- Business-wise they belong to the order, and the earlier configuration did hang
-- them off it. But each of them has details OF ITS OWN:
--     t_pick_detail -> t_allocation      (joined by pick_id)
--     t_tran_log    -> t_tran_log_reason, t_tran_log_sn  (joined by tran_log_id,
--                                                         and those FKs are ENFORCED)
-- kArchiveManager builds its keyset from the anchor table alone, so from an
-- order-anchored process the keyset carries order_number + wh_id and there is no
-- way to express "join t_allocation on the pick_id of the pick rows we just
-- selected" - that is a second hop, and SELECT is forbidden in configuration SQL
-- (arch.usp_AssertSafeSqlExpression, THROW 50400).
--
-- Keeping them as order details would therefore have left t_allocation,
-- t_tran_log_reason and t_tran_log_sn behind as orphans - and in the t_tran_log
-- case the enforced FK would have BLOCKED the delete outright.
--
-- Promoting each to the header of its own set fixes both problems: every table
-- reaches its own children, and the enforced FKs are honoured because an ANCHOR
-- deletes its header last.
--
-- ---------------------------------------------------------------------------
-- RUN ORDER ACROSS THE SETS
-- ---------------------------------------------------------------------------
-- Within a set the ObjectSpec DeleteOrder guarantees details-before-header.
-- ACROSS sets, ProcessDatabase.RunOrder decides which set runs first, and the
-- order matters because the links between sets are by naming convention with no
-- foreign key - nothing would stop us from archiving an order header while its
-- picks are still in the source, leaving rows that point at a document that is
-- no longer there.
--
--   10  AAD_PICKDETAIL_ARCH   picks + allocations   (deepest dependent on orders)
--   20  AAD_TRANLOG_ARCH      transaction log       (references orders/picks)
--   30  AAD_ORDER_ARCH        order documents       (the thing they point at)
--   40  AAD_WORKQ_ARCH        work queues           (independent of orders)
--   50  ADV_LOGMSG_ARCH       application log       (independent)
--
-- This is best-effort, not a guarantee: each set uses its own cutoff and its own
-- state gate, so a pick can legitimately outlive its order (unshipped) or an
-- order can age out while a pick is retained. Cross-set consistency is checked by
-- 23_verify_standalone.sql section C, not enforced by the runner.
--
-- ---------------------------------------------------------------------------
-- DELIBERATELY NOT ARCHIVED - and why
-- ---------------------------------------------------------------------------
--   t_employee                 has a work_q_id column (7 rows here). It is MASTER
--                              data - a pointer to the operator's current task,
--                              not history. Never archive it. But note the
--                              consequence: a work queue referenced by a live
--                              employee row could still be archived by the work-queue
--                              set, leaving that pointer dangling. The state gate
--                              (work_status IN 'C','P') makes that unlikely, since a
--                              completed queue should no longer be anyone's current task.
--   t_track_tran_log_holding   links by tran_log_holding_id, NOT tran_log_id, so
--                              the transaction-log keyset cannot reach it. It also
--                              carries shipping addresses (personal data), so it
--                              needs a retention rule - just not this one. Raise
--                              separately.
--   t_label, t_pick_container  no pick_id column (verified) - reachable only
--                              through t_allocation.allocation_id or a
--                              wh_id+order_number+container_id triple. Out of scope
--                              rather than guessed at.
--   t_tran_log_holding         transient staging heap that usp_process_tran_log
--                              drains continuously. Archiving from it would race
--                              the WMS transaction processor.
-- ============================================================================
:setvar AdminDb "kArchiveManagerAdmin"
:setvar WmsDb   "AAD"
:setvar AdvDb   "ADV"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar SourceTimezone "Central European Standard Time"
:setvar RetentionDays "90"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-------------------------------------------------------------------------------
-- 1) Re-shape AAD_ORDER_ARCH into a pure order document set and enable it.
--    It previously also carried t_pick_detail and t_tran_log; those now have
--    their own sets, so they are removed here to avoid two processes competing
--    for the same rows.
-------------------------------------------------------------------------------
DECLARE @Pc     sysname        = N'AAD_ORDER_ARCH';
DECLARE @By     nvarchar(256)  = N'kam-deploy';
DECLARE @Reason nvarchar(1000) = N'Order document set: header t_order plus its own details only.';
DECLARE @Tz     nvarchar(200)  = N'$(SourceTimezone)';
DECLARE @CsId   bigint         = NULL;
DECLARE @OsId   int            = NULL;

IF NOT EXISTS (SELECT 1 FROM arch.Process WHERE ProcessCode = @Pc)
    THROW 60700, 'AAD_ORDER_ARCH does not exist - run 04_seed_order.sql first.', 1;

DECLARE @Pid int = (SELECT ProcessId FROM arch.Process WHERE ProcessCode = @Pc);

-- Drop the two tables that are now headers of their own sets.
DELETE osdo
FROM arch.ObjectSpecDatabaseOverride osdo
JOIN arch.ObjectSpec os ON os.ObjectSpecId = osdo.ObjectSpecId
WHERE os.ProcessId = @Pid AND os.SourceTable IN (N't_pick_detail', N't_tran_log');

DELETE FROM arch.ObjectSpec
WHERE ProcessId = @Pid AND SourceTable IN (N't_pick_detail', N't_tran_log');

DELETE ir
FROM arch.IndexRequirement ir
WHERE ir.ProcessId = @Pid AND ir.SourceTable IN (N't_pick_detail', N't_tran_log');

PRINT 'Removed t_pick_detail and t_tran_log from AAD_ORDER_ARCH (they are now their own sets).';

-- Re-assert the remaining objects with a contiguous bottom-up DeleteOrder.
DECLARE @ordObjects table (DeleteOrder int PRIMARY KEY, SourceTable sysname);
INSERT @ordObjects VALUES
    (10, N't_order_detail_comment'),
    (20, N't_order_comment'),
    (30, N't_order_detail'),
    (40, N't_pack'),
    (50, N't_order');          -- header, last

DECLARE @do int, @st sysname;
DECLARE co CURSOR LOCAL FAST_FORWARD FOR SELECT DeleteOrder, SourceTable FROM @ordObjects ORDER BY DeleteOrder;
OPEN co; FETCH NEXT FROM co INTO @do, @st;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @OsId = (SELECT TOP (1) os.ObjectSpecId FROM arch.ObjectSpec os
                 WHERE os.ProcessId = @Pid AND os.SourceSchema = N'dbo' AND os.SourceTable = @st);

    EXEC arch.usp_Api_SaveObjectSpec
        @ObjectSpecId             = @OsId OUTPUT,
        @ProcessCode              = @Pc,
        @RequestedBy              = @By,
        @ChangeReason             = @Reason,
        @SourceSchema             = N'dbo',
        @SourceTable              = @st,
        @DeleteOrder              = @do,
        @DeleteMode               = 1,
        @TimestampExpr            = NULL,
        @JoinToAnchorPredicateSql = N't.order_number = k.Key1 AND t.wh_id = k.Key2',
        @AdditionalWhereSql       = NULL,
        @ArchiveSchema            = N'{SourceDb}',
        @ArchiveTable             = NULL,
        @RequireArchiveForDelete  = 1,
        @NaturalKeyLabel          = N'ORDER_NUMBER',
        @ConfigChangeSetId        = @CsId OUTPUT;

    FETCH NEXT FROM co INTO @do, @st;
END;
CLOSE co; DEALLOCATE co;

UPDATE arch.Process
SET IsEnabled = 1, ModifiedAt = SYSUTCDATETIME()
WHERE ProcessCode = @Pc;

PRINT 'AAD_ORDER_ARCH re-shaped as a pure order document set and ENABLED.';
GO

-------------------------------------------------------------------------------
-- 2) Run order across the sets (details-bearing sets before the sets they
--    reference). See the header for why this is best-effort.
-------------------------------------------------------------------------------
DECLARE @ro table (ProcessCode sysname PRIMARY KEY, SourceDb sysname, RunOrder int);
INSERT @ro VALUES
    (N'AAD_PICKDETAIL_ARCH', N'$(WmsDb)', 10),
    (N'AAD_TRANLOG_ARCH',    N'$(WmsDb)', 20),
    (N'AAD_ORDER_ARCH',      N'$(WmsDb)', 30),
    (N'AAD_WORKQ_ARCH',      N'$(WmsDb)', 40),
    (N'ADV_LOGMSG_ARCH',     N'$(AdvDb)', 50);

UPDATE pd
SET RunOrder = r.RunOrder, ModifiedAt = SYSUTCDATETIME()
FROM arch.ProcessDatabase pd
JOIN arch.Process p ON p.ProcessId = pd.ProcessId
JOIN @ro r ON r.ProcessCode = p.ProcessCode AND r.SourceDb = pd.SourceDb;

PRINT 'Run order applied across the document sets.';
GO

-------------------------------------------------------------------------------
-- 3) The full picture
-------------------------------------------------------------------------------
SELECT
    Section = 'DOCUMENT_SETS',
    pd.RunOrder,
    p.ProcessCode,
    p.SelectionStrategy,
    pd.SourceDb,
    HeaderTable = ISNULL(p.AnchorTable, N'(timestamp-driven)'),
    p.RetentionDays,
    p.IsEnabled
FROM arch.Process p
JOIN arch.ProcessDatabase pd ON pd.ProcessId = p.ProcessId
ORDER BY pd.RunOrder;

SELECT
    Section = 'HIERARCHY',
    pd.RunOrder,
    p.ProcessCode,
    os.DeleteOrder,
    os.SourceTable,
    Role_ = CASE WHEN os.SourceTable = p.AnchorTable THEN 'HEADER (deleted last)'
                 WHEN p.SelectionStrategy = N'TIMESTAMP' AND os.DeleteOrder = 10 THEN 'HEADER (drives selection)'
                 ELSE 'detail' END,
    os.JoinToAnchorPredicateSql
FROM arch.ObjectSpec os
JOIN arch.Process p ON p.ProcessId = os.ProcessId
JOIN arch.ProcessDatabase pd ON pd.ProcessId = p.ProcessId
ORDER BY pd.RunOrder, os.DeleteOrder;

-- Every table must appear in exactly one process.
SELECT
    Section = 'OVERLAP_CHECK',
    os.SourceTable,
    Processes = COUNT(DISTINCT p.ProcessCode),
    In_ = STUFF((SELECT N', ' + p2.ProcessCode
                 FROM arch.ObjectSpec os2
                 JOIN arch.Process p2 ON p2.ProcessId = os2.ProcessId
                 WHERE os2.SourceTable = os.SourceTable
                 GROUP BY p2.ProcessCode
                 FOR XML PATH(''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''),
    Verdict = CASE WHEN COUNT(DISTINCT p.ProcessCode) = 1 THEN 'OK'
                   ELSE 'STOP - table is claimed by more than one process' END
FROM arch.ObjectSpec os
JOIN arch.Process p ON p.ProcessId = os.ProcessId
GROUP BY os.SourceTable
ORDER BY COUNT(DISTINCT p.ProcessCode) DESC, os.SourceTable;
GO

PRINT '25_seed_document_sets: done. Re-run 06_provision.sql, then 07_validate.sql.';
GO
