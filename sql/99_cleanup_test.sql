-- ============================================================================
-- 99 - CLEANUP (remove the test footprint)
-- ============================================================================
-- Four independent scopes, each with its own switch, all defaulting to 0.
-- Section A always runs and reports what each switch WOULD remove.
--
--   CleanTestData   - delete rows tagged as test data, from BOTH the source and
--                     the archive. Tags used by 30_test_data_all.sql:
--                       t_order            order_number LIKE 'KAMT-%'
--                       t_tran_log         generic_text1 = 'KAMTEST'
--                       t_pick_detail      lot_number    = 'KAMTEST'
--                       t_work_q           work_q_id LIKE 'KAMTQ%'
--                       ADV.t_log_message  machine_id    = 'KAMTEST'
--                     Legacy tags from earlier revisions are included too
--                     (KAMTEST-%, KAMDOC-%, KAMSTD, KAMTESTQ%, KAMSTDQ%).
--   CleanRunHistory - delete arch.Run / RunItem / RunItemObject / WorkBatch(+Key)
--                     and the baseline table. arch.RunDocAudit is protected by a
--                     DENY on UPDATE/DELETE (audit immutability, script 045), so
--                     that part may fail BY DESIGN - it is caught and reported.
--   CleanProfiles   - remove the run profiles this package creates, EXCEPT
--                     JOB_DEFAULT (the Agent job hardcodes it).
--   CleanConfig     - remove all five processes and their configuration.
--                     Archive TABLES and archived ROWS are left alone: they are
--                     the system of record, so dropping them is a separate,
--                     manual decision.
--
-- NOT touched by any switch, on purpose:
--   * real archived data in <ArchiveDb>.ADV.t_log_message that came from a
--     production run rather than from test rows,
--   * anything in the WMS databases other than the tagged test rows - we never
--     create objects there, so there is nothing of ours to remove.
-- ============================================================================
:setvar AdminDb   "kArchiveManagerAdmin"
:setvar WmsDb     "AAD"
:setvar AdvDb     "ADV"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar CleanTestData "0"
:setvar CleanRunHistory "0"
:setvar CleanProfiles "0"
:setvar CleanConfig "0"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

PRINT 'CleanTestData=$(CleanTestData)  CleanRunHistory=$(CleanRunHistory)  CleanProfiles=$(CleanProfiles)  CleanConfig=$(CleanConfig)';
GO

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- A) What the test-data cleanup would remove ---';
-------------------------------------------------------------------------------
DECLARE @rep nvarchar(max) = N'
SELECT Section=''A_SOURCE'', TableName=''t_order'',        Rows_=COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_order        WHERE order_number LIKE N''KAMT-%'' OR order_number LIKE N''KAMTEST-%'' OR order_number LIKE N''KAMDOC-%''
UNION ALL SELECT ''A_SOURCE'', ''t_tran_log'',    COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_tran_log    WHERE generic_text1 IN (N''KAMTEST'', N''KAMSTD'')
UNION ALL SELECT ''A_SOURCE'', ''t_pick_detail'', COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_pick_detail WHERE lot_number IN (N''KAMTEST'', N''KAMSTD'')
UNION ALL SELECT ''A_SOURCE'', ''t_work_q'',      COUNT_BIG(*) FROM ' + QUOTENAME(N'$(WmsDb)') + N'.dbo.t_work_q      WHERE work_q_id LIKE N''KAMTQ%'' OR work_q_id LIKE N''KAMTESTQ%'' OR work_q_id LIKE N''KAMSTDQ%''
UNION ALL SELECT ''A_SOURCE'', ''t_log_message'', COUNT_BIG(*) FROM ' + QUOTENAME(N'$(AdvDb)') + N'.dbo.t_log_message WHERE machine_id = N''KAMTEST''
UNION ALL SELECT ''A_ARCHIVE'', ''t_order'',        COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_order        WHERE order_number LIKE N''KAMT-%'' OR order_number LIKE N''KAMTEST-%'' OR order_number LIKE N''KAMDOC-%''
UNION ALL SELECT ''A_ARCHIVE'', ''t_tran_log'',    COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_tran_log    WHERE generic_text1 IN (N''KAMTEST'', N''KAMSTD'')
UNION ALL SELECT ''A_ARCHIVE'', ''t_pick_detail'', COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_pick_detail WHERE lot_number IN (N''KAMTEST'', N''KAMSTD'')
UNION ALL SELECT ''A_ARCHIVE'', ''t_work_q'',      COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(WmsDb)') + N'.t_work_q      WHERE work_q_id LIKE N''KAMTQ%'' OR work_q_id LIKE N''KAMTESTQ%'' OR work_q_id LIKE N''KAMSTDQ%''
UNION ALL SELECT ''A_ARCHIVE'', ''t_log_message'', COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(AdvDb)') + N'.t_log_message WHERE machine_id = N''KAMTEST''
ORDER BY Section, TableName;';
EXEC sys.sp_executesql @rep;
GO

-------------------------------------------------------------------------------
-- B) Test data - source side, children before parents
-------------------------------------------------------------------------------
IF $(CleanTestData) = 1
BEGIN
    PRINT '';
    PRINT '--- B) Deleting tagged test rows from the SOURCE ---';

    DECLARE @src nvarchar(max) = N'
    USE ' + QUOTENAME(N'$(WmsDb)') + N';

    -- work-queue set
    DELETE FROM dbo.t_work_q_dependency WHERE parent_work_q_id LIKE N''KAMTQ%'' OR dependent_work_q_id LIKE N''KAMTQ%''
                                           OR parent_work_q_id LIKE N''KAMTESTQ%'' OR dependent_work_q_id LIKE N''KAMTESTQ%''
                                           OR parent_work_q_id LIKE N''KAMSTDQ%'' OR dependent_work_q_id LIKE N''KAMSTDQ%'';
    DELETE FROM dbo.t_work_q_assignment WHERE work_q_id LIKE N''KAMTQ%'' OR work_q_id LIKE N''KAMTESTQ%'' OR work_q_id LIKE N''KAMSTDQ%'';
    DELETE FROM dbo.t_work_q            WHERE work_q_id LIKE N''KAMTQ%'' OR work_q_id LIKE N''KAMTESTQ%'' OR work_q_id LIKE N''KAMSTDQ%'';

    -- transaction-log set (children first: their FKs are enforced)
    DELETE FROM dbo.t_tran_log_reason WHERE tran_log_id IN (SELECT tran_log_id FROM dbo.t_tran_log WHERE generic_text1 IN (N''KAMTEST'', N''KAMSTD''));
    DELETE FROM dbo.t_tran_log_sn     WHERE tran_log_id IN (SELECT tran_log_id FROM dbo.t_tran_log WHERE generic_text1 IN (N''KAMTEST'', N''KAMSTD''));
    DELETE FROM dbo.t_tran_log        WHERE generic_text1 IN (N''KAMTEST'', N''KAMSTD'');
    -- and any tran_log rows that only carry a test order number
    DELETE FROM dbo.t_tran_log WHERE outbound_order_number LIKE N''KAMT-%'' OR outbound_order_number LIKE N''KAMTEST-%'' OR outbound_order_number LIKE N''KAMDOC-%''
                                 OR inbound_order_number  LIKE N''KAMT-%'' OR inbound_order_number  LIKE N''KAMTEST-%'';

    -- pick set
    DELETE FROM dbo.t_allocation  WHERE pick_id IN (SELECT pick_id FROM dbo.t_pick_detail WHERE lot_number IN (N''KAMTEST'', N''KAMSTD''));
    DELETE FROM dbo.t_pick_detail WHERE lot_number IN (N''KAMTEST'', N''KAMSTD'');
    DELETE FROM dbo.t_pick_detail WHERE order_number LIKE N''KAMT-%'' OR order_number LIKE N''KAMTEST-%'' OR order_number LIKE N''KAMDOC-%'';

    -- order set (deepest child first; the cascade would take most of them anyway)
    DELETE FROM dbo.t_pack                 WHERE order_number LIKE N''KAMT-%'' OR order_number LIKE N''KAMTEST-%'' OR order_number LIKE N''KAMDOC-%'';
    DELETE FROM dbo.t_order_detail_comment WHERE order_number LIKE N''KAMT-%'' OR order_number LIKE N''KAMTEST-%'' OR order_number LIKE N''KAMDOC-%'';
    DELETE FROM dbo.t_order_comment        WHERE order_number LIKE N''KAMT-%'' OR order_number LIKE N''KAMTEST-%'' OR order_number LIKE N''KAMDOC-%'';
    DELETE FROM dbo.t_order_detail         WHERE order_number LIKE N''KAMT-%'' OR order_number LIKE N''KAMTEST-%'' OR order_number LIKE N''KAMDOC-%'';
    DELETE FROM dbo.t_order                WHERE order_number LIKE N''KAMT-%'' OR order_number LIKE N''KAMTEST-%'' OR order_number LIKE N''KAMDOC-%'';';
    EXEC sys.sp_executesql @src;

    DECLARE @adv nvarchar(max) = N'
    USE ' + QUOTENAME(N'$(AdvDb)') + N';
    DELETE FROM dbo.t_log_message WHERE machine_id = N''KAMTEST'';';
    EXEC sys.sp_executesql @adv;

    PRINT '--- Deleting tagged test rows from the ARCHIVE ---';
    DECLARE @arc nvarchar(max) = N'
    USE ' + QUOTENAME(N'$(ArchiveDb)') + N';
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_work_q_dependency    WHERE parent_work_q_id LIKE N''KAM%Q%'' OR dependent_work_q_id LIKE N''KAM%Q%'';
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_work_q_assignment    WHERE work_q_id LIKE N''KAM%Q%'';
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_work_q               WHERE work_q_id LIKE N''KAM%Q%'';
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_tran_log_reason      WHERE tran_log_id IN (SELECT tran_log_id FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_tran_log WHERE generic_text1 IN (N''KAMTEST'', N''KAMSTD''));
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_tran_log_sn          WHERE tran_log_id IN (SELECT tran_log_id FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_tran_log WHERE generic_text1 IN (N''KAMTEST'', N''KAMSTD''));
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_tran_log             WHERE generic_text1 IN (N''KAMTEST'', N''KAMSTD'') OR outbound_order_number LIKE N''KAM%-%'';
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_allocation           WHERE pick_id IN (SELECT pick_id FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_pick_detail WHERE lot_number IN (N''KAMTEST'', N''KAMSTD''));
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_pick_detail          WHERE lot_number IN (N''KAMTEST'', N''KAMSTD'') OR order_number LIKE N''KAM%-%'';
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_pack                 WHERE order_number LIKE N''KAM%-%'';
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_order_detail_comment WHERE order_number LIKE N''KAM%-%'';
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_order_comment        WHERE order_number LIKE N''KAM%-%'';
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_order_detail         WHERE order_number LIKE N''KAM%-%'';
    DELETE FROM ' + QUOTENAME(N'$(WmsDb)') + N'.t_order                WHERE order_number LIKE N''KAM%-%'';
    DELETE FROM ' + QUOTENAME(N'$(AdvDb)') + N'.t_log_message          WHERE machine_id = N''KAMTEST'';';
    EXEC sys.sp_executesql @arc;

    PRINT 'Test data removed from both sides.';
END;
GO

-------------------------------------------------------------------------------
-- C) Run history
-------------------------------------------------------------------------------
IF $(CleanRunHistory) = 1
BEGIN
    PRINT '';
    PRINT '--- C) Deleting run history ---';

    BEGIN TRY
        DELETE FROM arch.RunDocAudit;
        PRINT 'RunDocAudit cleared.';
    END TRY
    BEGIN CATCH
        -- Expected when the audit-immutability DENY from script 045 is in force.
        PRINT 'RunDocAudit NOT cleared - audit immutability DENY is working as designed: ' + ERROR_MESSAGE();
    END CATCH;

    DELETE FROM arch.RunItemObject;
    DELETE FROM arch.RunItem;
    DELETE FROM arch.Run;
    DELETE FROM arch.WorkBatchKey;
    DELETE FROM arch.WorkBatch;

    IF OBJECT_ID(N'dbo.KamDeployBaseline', N'U') IS NOT NULL
        DELETE FROM dbo.KamDeployBaseline;

    PRINT 'Run history cleared.';
END;
GO

-------------------------------------------------------------------------------
-- D) Run profiles (JOB_DEFAULT is always kept - the Agent job hardcodes it)
-------------------------------------------------------------------------------
IF $(CleanProfiles) = 1
BEGIN
    PRINT '';
    PRINT '--- D) Removing this package''s run profiles (JOB_DEFAULT kept) ---';

    DELETE FROM arch.RunProfile
    WHERE RunProfileCode <> N'JOB_DEFAULT'
      AND RunProfileCode IN
      (
          N'ORDER_DRYRUN', N'ORDER_RUN', N'WORKQ_DRYRUN', N'WORKQ_RUN',
          N'GUARDED_ORDER_RUN', N'GUARDED_WORKQ_RUN',
          N'STANDALONE_DRYRUN', N'STANDALONE_RUN',
          N'LOGMSG_DRYRUN', N'LOGMSG_RUN200',
          N'AAD_ORDER_DRYRUN', N'AAD_ORDER_RUN'
      );

    PRINT 'Profiles removed.';
END;
GO

-------------------------------------------------------------------------------
-- E) Configuration (archive tables and archived rows are KEPT)
-------------------------------------------------------------------------------
IF $(CleanConfig) = 1
BEGIN
    PRINT '';
    PRINT '--- E) Removing the configuration ---';

    DECLARE @pids table (ProcessId int PRIMARY KEY);
    INSERT @pids(ProcessId)
    SELECT ProcessId FROM arch.Process
    WHERE ProcessCode IN (N'AAD_ORDER_ARCH', N'AAD_PICKDETAIL_ARCH', N'AAD_TRANLOG_ARCH',
                          N'AAD_WORKQ_ARCH', N'ADV_LOGMSG_ARCH');

    DELETE osdo
    FROM arch.ObjectSpecDatabaseOverride osdo
    JOIN arch.ObjectSpec os ON os.ObjectSpecId = osdo.ObjectSpecId
    WHERE os.ProcessId IN (SELECT ProcessId FROM @pids);

    DELETE FROM arch.IndexRequirement WHERE ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE FROM arch.ObjectSpec       WHERE ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE FROM arch.ProcessKeySpec   WHERE ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE FROM arch.ProcessDatabase  WHERE ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE FROM arch.Process          WHERE ProcessId IN (SELECT ProcessId FROM @pids);

    PRINT 'Configuration removed. Archive tables and archived rows were NOT touched.';
END;
GO

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- Final state ---';
GO
SELECT Section='PROCESSES', ProcessCode, SelectionStrategy, IsEnabled FROM arch.Process ORDER BY ProcessCode;
SELECT Section='PROFILES', RunProfileCode, IsEnabled, RunOnSchedule FROM arch.RunProfile ORDER BY RunOrder;
SELECT Section='HISTORY', Runs=(SELECT COUNT_BIG(*) FROM arch.Run), Items=(SELECT COUNT_BIG(*) FROM arch.RunItem), Batches=(SELECT COUNT_BIG(*) FROM arch.WorkBatch);
GO

PRINT '99_cleanup_test: done.';
GO
