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

    -------------------------------------------------------------------------
    -- AND INVALIDATE THE CANDIDATE BATCHES THAT ADDRESSED THOSE ROWS
    --
    -- A run cut short by RunWindowMinutes leaves its WorkBatch in status Paused
    -- with the unprocessed keys attached, and the NEXT run resumes it - with the
    -- cutoff it was prepared under. That is correct product behaviour, and it is
    -- exactly wrong once the rows those keys name have been deleted above.
    --
    -- Left behind, they are not merely untidy: the next REAL run would resume a
    -- test-era cutoff instead of selecting fresh candidates, and arch.v_OperationalHealth
    -- reports OPEN_WORKBATCH ("Open WorkBatch can block ANCHOR candidate
    -- preparation") until they are cleared. Observed on the reference instance:
    -- four Paused batches survived a cleanup, each holding keys for rows that no
    -- longer existed.
    --
    -- The script that deletes the rows is the script that invalidates the keys -
    -- the same rule 40_perf_seed.sql follows. Failed is terminal and is not
    -- resumed; the keys stay on file as an audit trail.
    -------------------------------------------------------------------------
    PRINT '--- Invalidating candidate batches whose rows were just deleted ---';

    DECLARE @Killed table (WorkBatchId bigint PRIMARY KEY, PrevStatus nvarchar(40),
                           PreparedAtUtc datetime2(7), CutoffUtc datetime2(7));

    UPDATE wb
    SET Status = N'Failed',
        CompletedAtUtc = SYSUTCDATETIME(),
        Notes = LEFT(ISNULL(wb.Notes + N' | ', N'')
                + N'Discarded by 99_cleanup_test.sql: the test rows these keys addressed were deleted.', 500)
    OUTPUT inserted.WorkBatchId, deleted.Status, inserted.PreparedAtUtc, inserted.RangeToUtc
    INTO @Killed(WorkBatchId, PrevStatus, PreparedAtUtc, CutoffUtc)
    FROM arch.WorkBatch wb
    WHERE wb.Status NOT IN (N'Completed', N'Failed');

    IF EXISTS (SELECT 1 FROM @Killed)
        SELECT Section = 'STALE_BATCH_DISCARDED', k.WorkBatchId,
               ProcessCode = p.ProcessCode, k.PrevStatus, k.PreparedAtUtc,
               CutoffItWouldHaveReused = k.CutoffUtc,
               KeyCount = (SELECT COUNT(*) FROM arch.WorkBatchKey wk WHERE wk.WorkBatchId = k.WorkBatchId)
        FROM @Killed k
        JOIN arch.WorkBatch wb ON wb.WorkBatchId = k.WorkBatchId
        JOIN arch.Process p ON p.ProcessId = wb.ProcessId
        ORDER BY k.WorkBatchId;
    ELSE
        PRINT 'No open candidate batches.';
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
      AND (
            RunProfileCode IN
            (
                N'ORDER_DRYRUN', N'ORDER_RUN', N'WORKQ_DRYRUN', N'WORKQ_RUN',
                N'GUARDED_ORDER_RUN', N'GUARDED_WORKQ_RUN',
                N'STANDALONE_DRYRUN', N'STANDALONE_RUN',
                N'LOGMSG_DRYRUN', N'LOGMSG_RUN200',
                N'AAD_ORDER_DRYRUN', N'AAD_ORDER_RUN'
            )
            -- The performance profiles are generated per process by
            -- 41_perf_test.sql, one per enabled set, so they cannot be listed by
            -- name here: a newly added document set would silently leave its
            -- PERF_ profile behind. They carry MaxCandidates = 2000000 and a
            -- one-minute window - a benchmarking configuration that has no
            -- business surviving into a scheduled environment.
            OR RunProfileCode LIKE N'PERF[_]%'
          );

    PRINT 'Profiles removed.';
END;
GO

-------------------------------------------------------------------------------
-- D2) WHAT THE PERFORMANCE SCRIPTS CHANGED OUTSIDE THEIR OWN TEST DATA
--
-- 40_perf_seed.sql / 41_perf_test.sql temporarily lift arch.Process.MaxBatchesPerRun
-- to 1000000 and disable the vendor's 'Log Maintenance' job, recording the previous
-- values in perf.TestBaseline. 41 restores them at the end, but a killed session
-- cannot. This restore is deliberately NOT behind a switch: a million-batch cap
-- removes the only bound on how long one scheduled run may hold locks, and a
-- disabled vendor job is a change to the customer's environment. Neither is ever
-- an intended resting state. 42_perf_restore.sql is the standalone equivalent.
-------------------------------------------------------------------------------
-- The table is CREATED rather than tested for. A T-SQL batch is bound before any
-- of it executes, so `IF OBJECT_ID(...) IS NOT NULL` cannot protect a batch that
-- names a missing table - it fails with Msg 208 and, under ":on error exit",
-- takes the rest of this script with it. Since the perf stage is optional, that
-- would have broken cleanup on every deployment that skipped it, AFTER sections
-- B/C/D had already committed their deletes. (README documents this exact trap:
-- "IF does not prevent compilation".)
IF SCHEMA_ID(N'perf') IS NULL EXEC(N'CREATE SCHEMA perf AUTHORIZATION dbo;');
GO
IF OBJECT_ID(N'perf.TestBaseline', N'U') IS NULL
    CREATE TABLE perf.TestBaseline
    (
        ItemKind      varchar(20)   NOT NULL,
        ItemName      nvarchar(256) NOT NULL,
        IntValue      int           NULL,
        CapturedAtUtc datetime2(0)  NOT NULL CONSTRAINT DF_perf_TestBaseline_At DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_perf_TestBaseline PRIMARY KEY (ItemKind, ItemName)
    );
GO

IF EXISTS (SELECT 1 FROM perf.TestBaseline)
BEGIN
    PRINT '';
    PRINT '--- D2) Restoring what the performance test changed ---';

    UPDATE p
    SET MaxBatchesPerRun = b.IntValue, ModifiedAt = SYSUTCDATETIME()
    FROM arch.Process p
    JOIN perf.TestBaseline b ON b.ItemName = p.ProcessCode AND b.ItemKind = 'PROCESS_CAP'
    WHERE p.MaxBatchesPerRun <> b.IntValue;

    DELETE b
    FROM perf.TestBaseline b
    JOIN arch.Process p ON p.ProcessCode = b.ItemName
    WHERE b.ItemKind = 'PROCESS_CAP' AND p.MaxBatchesPerRun = b.IntValue;

    -- A row whose process no longer exists has nothing to restore, and the
    -- join-based delete above can never clear it. Left alone it would make every
    -- future cleanup print PERF_BASELINE_STILL_PENDING for ever.
    DELETE b
    FROM perf.TestBaseline b
    WHERE b.ItemKind = 'PROCESS_CAP'
      AND NOT EXISTS (SELECT 1 FROM arch.Process p WHERE p.ProcessCode = b.ItemName);

    DECLARE @PJob sysname, @PWant int, @PNow int;
    DECLARE cjb CURSOR LOCAL FAST_FORWARD FOR
        SELECT ItemName, IntValue FROM perf.TestBaseline WHERE ItemKind = 'AGENT_JOB';
    OPEN cjb;
    FETCH NEXT FROM cjb INTO @PJob, @PWant;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @PNow = (SELECT TOP (1) CONVERT(int, enabled) FROM msdb.dbo.sysjobs WHERE name = @PJob);
        IF @PNow IS NOT NULL
        BEGIN
            IF @PNow <> @PWant EXEC msdb.dbo.sp_update_job @job_name = @PJob, @enabled = @PWant;
            DELETE FROM perf.TestBaseline WHERE ItemKind = 'AGENT_JOB' AND ItemName = @PJob;
        END;
        FETCH NEXT FROM cjb INTO @PJob, @PWant;
    END;
    CLOSE cjb; DEALLOCATE cjb;

    IF EXISTS (SELECT 1 FROM perf.TestBaseline)
        SELECT Section = 'PERF_BASELINE_STILL_PENDING', ItemKind, ItemName, IntValue FROM perf.TestBaseline;
    ELSE
        PRINT 'Performance-test changes fully restored.';
END
ELSE
    PRINT 'D2) Nothing outstanding from the performance test.';
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
