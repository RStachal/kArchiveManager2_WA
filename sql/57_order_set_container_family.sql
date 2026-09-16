-- ============================================================================
-- 57 - ORDER SET: REMOVE THE CONTAINER FAMILY THE RUNTIME CANNOT EXECUTE
-- ============================================================================
-- On 2026-09-15 five ObjectSpec rows were added to AAD_ORDER_ARCH by direct
-- INSERT - not through arch.usp_Api_SaveObjectSpec, which is where the product
-- enforces usp_AssertSafeSqlExpression. arch.ConfigChangeSet has no record of
-- them. Two of the five carry a join predicate the runtime refuses:
--
--   t_container_detail   t.wh_id = k.Key2 AND EXISTS (SELECT 1 FROM t_pick_container ...)
--   t_container_station  t.wh_id = k.Key2 AND EXISTS (SELECT 1 FROM t_pick_container ...)
--
-- arch.usp_VerifyRunnerPrivileges and arch.usp_ValidateConfiguration both pass,
-- because neither runs the safety gate on JoinToAnchorPredicateSql - the
-- validator checks only that the predicate is PRESENT. PREP passes because it
-- touches the anchor alone. RUN fails on its first ORDER batch:
--
--   arch.usp_RunPreparedBatches_InWindow failed: Unsafe SQL in advanced
--   configuration field [ObjectSpec.JoinToAnchorPredicateSql] ... (Error 50000)
--
-- WHOEVER ADDED THEM WAS RIGHT TO TRY. All three container tables have an
-- enforced foreign key INTO t_pick_container:
--
--   t_container_detail   (wh_id, container_id) -> t_pick_container   FK, trusted, 2024
--   t_container_station  (wh_id, container_id) -> t_pick_container   FK, trusted, 2024
--   t_container_master   (wh_id, container_id) -> t_pick_container   FK, trusted, 2024
--
-- and t_pick_container was in the ORDER set at DeleteOrder 45 (added by
-- 26_add_pick_order_children.sql). On the real data now loaded, 506 containers
-- of archive-eligible orders have such children. Deleting t_pick_container
-- with them still present violates the FK. The earlier throughput tests never
-- hit this because the seeded containers (KAMTC-B%) had no children.
--
-- WHY IT CANNOT BE FIXED IN PLACE
-- The runtime builds  DELETE t FROM <table> t INNER JOIN #Keys k ON <predicate>
-- and the predicate may reference only t and k. t_container_detail and
-- t_container_station have no order_number - their only path to the order is
-- through t_pick_container - so no single-hop predicate exists, and the gate
-- refuses the subquery that would express the hop. This is the same reason
-- t_pick_task_uom lives in the PICKDETAIL set (it carries pick_id) rather than
-- the ORDER set: a grandchild goes into the set whose anchor key it holds.
--
-- WHAT THIS SCRIPT DOES
-- Removes the two unexpressible rows AND t_pick_container itself, because:
--   * t_pick_container has NO foreign key to t_order (verified: sys.foreign_keys
--     referencing t_order lists six tables, and t_pick_container is not one),
--     so the ORDER set does not need it to delete orders cleanly;
--   * left in, it fails on the FK from the two children the set can no longer
--     express.
-- The other three additions STAY - they are FK children of t_order with plain
-- joins, and without them the t_order delete fails on real data:
--   43 t_container_master    t.order_number = k.Key1 AND t.wh_id = k.Key2
--   47 t_order_status        t.order_number = k.Key1 AND t.wh_id = k.Key2
--   48 t_geek_pick_order     t.order_number = k.Key1 AND t.wh_id = k.Key2
--
-- After this the ORDER set is FK-complete for t_order:
--   t_container_master, t_geek_pick_order, t_order_comment, t_order_detail,
--   t_order_status, t_pack - all six FK children present, plus
--   t_order_detail_comment beneath t_order_detail.
--
-- WHAT IS DEFERRED, DELIBERATELY
-- The container family (t_pick_container + its three children) stays in the
-- source, untouched. Archiving it needs a set of its own, anchored on
-- t_pick_container with keys (container_id, wh_id), children joined
-- t.container_id = k.Key1 AND t.wh_id = k.Key2 - all plain, all safe. Two
-- decisions belong to the data-model owner before that set is written:
--   1. The gate. Container status is NOT a proxy for order completion here:
--      575 of 1 039 ACTIVE containers belong to SHIPPED orders. A cutoff on
--      actual_ship_date / create_date is the honest option.
--   2. t_container_master has FKs to BOTH t_order and t_pick_container, so it
--      must be deletable by either set. Configuring it in both is allowed by the
--      product (t_work_q_dependency is configured twice already) - whichever
--      set runs first takes it, the other finds nothing.
--
-- Writes an arch.ConfigChangeSet / ConfigChangeItem record, since the product
-- has no delete API for ObjectSpec and the audit trail should not have a hole.
-- Idempotent: rows already gone are reported, not re-deleted.
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ProcessCode sysname = N'AAD_ORDER_ARCH';
DECLARE @Apply       bit     = 0;      -- set 1 to apply

------------------------------------------------------------------------------
-- A) What the set looks like now, and which rows the runtime would refuse
------------------------------------------------------------------------------
DECLARE @pid int = (SELECT ProcessId FROM arch.Process WHERE ProcessCode = @ProcessCode);
IF @pid IS NULL
BEGIN
    RAISERROR('Process %s not found.', 16, 1, @ProcessCode);
    RETURN;
END;

DECLARE @gate TABLE (ObjectSpecId int PRIMARY KEY, Verdict nvarchar(40));
DECLARE @id int, @sql nvarchar(max), @v nvarchar(40);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT ObjectSpecId, JoinToAnchorPredicateSql FROM arch.ObjectSpec WHERE ProcessId = @pid;
OPEN c; FETCH NEXT FROM c INTO @id, @sql;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC arch.usp_AssertSafeSqlExpression @Expression = @sql, @FieldName = N'ObjectSpec.JoinToAnchorPredicateSql';
        SET @v = N'ok';
    END TRY
    BEGIN CATCH
        SET @v = N'REFUSED ' + CONVERT(nvarchar(10), ERROR_NUMBER());
    END CATCH;
    INSERT @gate VALUES (@id, @v);
    FETCH NEXT FROM c INTO @id, @sql;
END;
CLOSE c; DEALLOCATE c;

SELECT Section = 'A_BEFORE', o.ObjectSpecId, o.DeleteOrder, o.SourceTable,
       RuntimeGate = g.Verdict,
       FkToOrder = CASE WHEN EXISTS (SELECT 1 FROM AAD.sys.foreign_keys fk
                                     WHERE fk.parent_object_id = OBJECT_ID(N'AAD.' + o.SourceSchema + N'.' + o.SourceTable)
                                       AND fk.referenced_object_id = OBJECT_ID(N'AAD.dbo.t_order')) THEN 'yes' ELSE '-' END,
       Action = CASE WHEN o.SourceTable IN (N't_container_detail', N't_container_station', N't_pick_container') THEN 'REMOVE' ELSE 'keep' END
FROM arch.ObjectSpec o
LEFT JOIN @gate g ON g.ObjectSpecId = o.ObjectSpecId
WHERE o.ProcessId = @pid
ORDER BY o.DeleteOrder;

------------------------------------------------------------------------------
-- B) Snapshot of what will be removed - keep this output
------------------------------------------------------------------------------
SELECT Section = 'B_SNAPSHOT', o.ObjectSpecId, o.SourceSchema, o.SourceTable, o.DeleteOrder, o.DeleteMode,
       o.JoinToAnchorPredicateSql, o.AdditionalWhereSql, o.ArchiveSchema, o.ArchiveTable,
       o.RequireArchiveForDelete, o.NaturalKeyLabel, o.CreatedAt, o.ModifiedAt
FROM arch.ObjectSpec o
WHERE o.ProcessId = @pid
  AND o.SourceTable IN (N't_container_detail', N't_container_station', N't_pick_container');

IF @Apply = 0
BEGIN
    PRINT '';
    PRINT '57: PLAN ONLY. Set @Apply = 1 to remove the rows marked REMOVE in section A.';
    RETURN;
END;

------------------------------------------------------------------------------
-- C) Apply, with an audit record
------------------------------------------------------------------------------
BEGIN TRAN;

INSERT arch.ConfigChangeSet (ChangeStatus, RequestedBy, RequestedAtUtc, PublishedBy, PublishedAtUtc, ChangeReason, ValidationStatus, ValidationSummary)
VALUES (N'PUBLISHED', N'kam-deploy', SYSUTCDATETIME(), N'kam-deploy', SYSUTCDATETIME(),
        N'57: remove ObjectSpecs the runtime cannot execute. t_container_detail and t_container_station use EXISTS(SELECT), refused by usp_AssertSafeSqlExpression (50400). t_pick_container removed with them: its FK children cannot be expressed in this set and it has no FK to t_order. Container family deferred to a dedicated set.',
        N'OK', N'Direct removal - the product has no delete API for ObjectSpec.');
DECLARE @cs bigint = SCOPE_IDENTITY();

INSERT arch.ConfigChangeItem (ConfigChangeSetId, EntityType, EntityKey, Operation, ObjectId, CreatedAtUtc)
SELECT @cs, N'ObjectSpec', @ProcessCode + N'|' + o.SourceSchema + N'.' + o.SourceTable, N'DELETE', o.ObjectSpecId, SYSUTCDATETIME()
FROM arch.ObjectSpec o
WHERE o.ProcessId = @pid
  AND o.SourceTable IN (N't_container_detail', N't_container_station', N't_pick_container');

DELETE o
FROM arch.ObjectSpec o
WHERE o.ProcessId = @pid
  AND o.SourceTable IN (N't_container_detail', N't_container_station', N't_pick_container');

SELECT Section = 'C_APPLIED', RowsRemoved = @@ROWCOUNT, ConfigChangeSetId = @cs;
COMMIT;

------------------------------------------------------------------------------
-- D) After: every remaining join must pass the gate
------------------------------------------------------------------------------
DELETE @gate;
DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR
    SELECT ObjectSpecId, JoinToAnchorPredicateSql FROM arch.ObjectSpec WHERE ProcessId = @pid;
OPEN c2; FETCH NEXT FROM c2 INTO @id, @sql;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC arch.usp_AssertSafeSqlExpression @Expression = @sql, @FieldName = N'ObjectSpec.JoinToAnchorPredicateSql';
        SET @v = N'ok';
    END TRY
    BEGIN CATCH
        SET @v = N'REFUSED ' + CONVERT(nvarchar(10), ERROR_NUMBER());
    END CATCH;
    INSERT @gate VALUES (@id, @v);
    FETCH NEXT FROM c2 INTO @id, @sql;
END;
CLOSE c2; DEALLOCATE c2;

SELECT Section = 'D_AFTER', o.DeleteOrder, o.SourceTable, RuntimeGate = g.Verdict
FROM arch.ObjectSpec o LEFT JOIN @gate g ON g.ObjectSpecId = o.ObjectSpecId
WHERE o.ProcessId = @pid ORDER BY o.DeleteOrder;

SELECT Section = 'D_FK_COMPLETE',
       FkChild = OBJECT_NAME(fk.parent_object_id, DB_ID('AAD')),
       InSet = CASE WHEN EXISTS (SELECT 1 FROM arch.ObjectSpec o WHERE o.ProcessId = @pid
                                    AND o.SourceTable = OBJECT_NAME(fk.parent_object_id, DB_ID('AAD'))) THEN 'yes' ELSE '*** MISSING ***' END
FROM AAD.sys.foreign_keys fk
WHERE fk.referenced_object_id = OBJECT_ID(N'AAD.dbo.t_order')
ORDER BY 2;

PRINT '';
PRINT 'Now: EXEC arch.usp_ValidateConfiguration; then start PREP and RUN and read sysjobhistory.';
