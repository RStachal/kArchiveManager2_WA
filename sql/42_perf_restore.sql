-- ============================================================================
-- 42 - UNDO WHATEVER THE PERFORMANCE TEST CHANGED
-- ============================================================================
-- 40_perf_seed.sql and 41_perf_test.sql change three things outside their own
-- test data. Two are recorded in perf.TestBaseline:
--
--   PROCESS_CAP  arch.Process.MaxBatchesPerRun, lifted to 1000000 so that TIME is
--                the only thing that can stop a run. Left in place, this removes
--                the only bound on how long ONE scheduled run may hold locks -
--                it is not a cosmetic setting.
--   AGENT_JOB    the vendor's 'Log Maintenance' job, disabled so that ADV's own
--                purge cannot delete the seeded log rows mid-measurement.
--
-- The third needs no baseline because it is created rather than modified:
--
--   PERF_* run profiles, one per enabled process, with RunWindowMinutes = 1 and
--   MaxCandidates = 2000000. 41 deletes them itself at the end; they are removed
--   here too, for the case where it never reached that point.
--
-- 41 restores all three at the end. This script exists for when it never got
-- there - a killed session, a lost connection, sqlcmd hitting :on error exit. It
-- is idempotent and safe to run at any time; with nothing outstanding it does
-- nothing and says so.
--
-- RUN THIS BEFORE LEAVING THE INSTANCE if 41 did not print CAPS_RESTORED and
-- VENDOR_JOB_RESTORED. 99_cleanup_test.sql calls the same logic.
-- ============================================================================
:setvar AdminDb "kArchiveManagerAdmin"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

-------------------------------------------------------------------------------
-- THE TABLE IS CREATED, NOT TESTED FOR
--
-- Every block below names perf.TestBaseline statically, and a T-SQL batch is
-- BOUND BEFORE ANY OF IT EXECUTES - so `IF OBJECT_ID(...) IS NULL` does not
-- protect a batch that mentions a missing table: the whole batch fails with
-- Msg 208 and, under ":on error exit", takes the script with it. That would have
-- made this file fail on exactly the instances where it has nothing to do (the
-- perf scripts never ran there), printing an alarming error instead of "nothing
-- to restore" - the opposite of what a defensive undo should do.
--
-- The alternative is to wrap all four blocks in sp_executesql, which means
-- escaping ~80 lines of T-SQL inside string literals. Creating an empty
-- bookkeeping table in OUR OWN admin database is the smaller price. It is the
-- same DDL as 40/41, it is idempotent, and it leaves nothing behind but an empty
-- two-column table.
--
-- The same trap and the same fix apply to section D2 of 99_cleanup_test.sql.
-------------------------------------------------------------------------------
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

IF NOT EXISTS (SELECT 1 FROM perf.TestBaseline)
    PRINT 'perf.TestBaseline is empty - there is nothing outstanding to restore.';
ELSE
    SELECT Section = 'PENDING', ItemKind, ItemName, IntValue, CapturedAtUtc
    FROM perf.TestBaseline ORDER BY ItemKind, ItemName;
GO

/* ---------------- batching caps ---------------- */
IF OBJECT_ID(N'perf.TestBaseline', N'U') IS NOT NULL
BEGIN
    UPDATE p
    SET MaxBatchesPerRun = b.IntValue, ModifiedAt = SYSUTCDATETIME()
    FROM arch.Process p
    JOIN perf.TestBaseline b ON b.ItemName = p.ProcessCode AND b.ItemKind = 'PROCESS_CAP'
    WHERE p.MaxBatchesPerRun <> b.IntValue;

    IF @@ROWCOUNT > 0
        SELECT Section = 'CAPS_RESTORED', p.ProcessCode, p.MaxBatchesPerRun,
               Verdict = CASE WHEN p.MaxBatchesPerRun = b.IntValue THEN 'restored' ELSE 'MISMATCH' END
        FROM arch.Process p
        JOIN perf.TestBaseline b ON b.ItemName = p.ProcessCode AND b.ItemKind = 'PROCESS_CAP'
        ORDER BY p.ProcessCode;

    -- Clear only what verifiably matches, so a partial failure stays on the books.
    DELETE b
    FROM perf.TestBaseline b
    JOIN arch.Process p ON p.ProcessCode = b.ItemName
    WHERE b.ItemKind = 'PROCESS_CAP' AND p.MaxBatchesPerRun = b.IntValue;

    -- A row whose process is GONE has nothing left to restore, but the join-based
    -- delete above can never clear it - so without this it would be reported as
    -- outstanding work for ever. A permanent warning nobody can action is exactly
    -- what this package criticises elsewhere, so it is reported once, as what it
    -- actually is, and then removed.
    IF EXISTS (SELECT 1 FROM perf.TestBaseline b
               WHERE b.ItemKind = 'PROCESS_CAP'
                 AND NOT EXISTS (SELECT 1 FROM arch.Process p WHERE p.ProcessCode = b.ItemName))
    BEGIN
        SELECT Section = 'BASELINE_ORPHANED', b.ItemName, b.IntValue, b.CapturedAtUtc,
               Note = 'process no longer configured - nothing to restore, row discarded'
        FROM perf.TestBaseline b
        WHERE b.ItemKind = 'PROCESS_CAP'
          AND NOT EXISTS (SELECT 1 FROM arch.Process p WHERE p.ProcessCode = b.ItemName);

        DELETE b
        FROM perf.TestBaseline b
        WHERE b.ItemKind = 'PROCESS_CAP'
          AND NOT EXISTS (SELECT 1 FROM arch.Process p WHERE p.ProcessCode = b.ItemName);
    END;
END;
GO

/* ---------------- vendor Agent jobs ---------------- */
IF OBJECT_ID(N'perf.TestBaseline', N'U') IS NOT NULL
BEGIN
    DECLARE @Job sysname, @Want int, @Now int;
    DECLARE cj CURSOR LOCAL FAST_FORWARD FOR
        SELECT ItemName, IntValue FROM perf.TestBaseline WHERE ItemKind = 'AGENT_JOB';
    OPEN cj;
    FETCH NEXT FROM cj INTO @Job, @Want;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Now = (SELECT TOP (1) CONVERT(int, enabled) FROM msdb.dbo.sysjobs WHERE name = @Job);
        IF @Now IS NULL
            PRINT 'WARN: job "' + @Job + '" no longer exists - baseline row kept for the record.';
        ELSE
        BEGIN
            IF @Now <> @Want
                EXEC msdb.dbo.sp_update_job @job_name = @Job, @enabled = @Want;

            SELECT Section = 'VENDOR_JOB_RESTORED', JobName = @Job, RestoredTo = @Want,
                   NowEnabled = (SELECT CONVERT(int, enabled) FROM msdb.dbo.sysjobs WHERE name = @Job);

            DELETE FROM perf.TestBaseline
            WHERE ItemKind = 'AGENT_JOB' AND ItemName = @Job
              AND @Want = (SELECT CONVERT(int, enabled) FROM msdb.dbo.sysjobs WHERE name = @Job);
        END;
        FETCH NEXT FROM cj INTO @Job, @Want;
    END;
    CLOSE cj; DEALLOCATE cj;
END;
GO

/* ---------------- benchmarking run profiles ---------------- */
-- No baseline entry for these: 41 CREATES them, so removing them is unconditional
-- rather than a restore. Matched by prefix because they are generated one per
-- enabled process.
IF EXISTS (SELECT 1 FROM arch.RunProfile WHERE RunProfileCode LIKE N'PERF[_]%')
BEGIN
    SELECT Section = 'PERF_PROFILE_REMOVING', RunProfileCode, ProcessCodeFilter,
           RunWindowMinutes, MaxCandidates, IsEnabled
    FROM arch.RunProfile WHERE RunProfileCode LIKE N'PERF[_]%' ORDER BY RunProfileCode;

    DELETE FROM arch.RunProfile WHERE RunProfileCode LIKE N'PERF[_]%';
    PRINT 'Benchmarking run profiles removed.';
END
ELSE
    PRINT 'No PERF_ run profiles present.';
GO

/* ---------------- what is left, and the honest verdict ---------------- */
IF OBJECT_ID(N'perf.TestBaseline', N'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM perf.TestBaseline)
    BEGIN
        SELECT Section = 'STILL_PENDING', ItemKind, ItemName, IntValue, CapturedAtUtc
        FROM perf.TestBaseline ORDER BY ItemKind, ItemName;
        PRINT '*** Not everything could be restored - see STILL_PENDING above. ***';
    END
    ELSE
        PRINT 'perf.TestBaseline is now empty: nothing the performance test changed is outstanding.';

    -- A cap sitting at the sentinel with no baseline row cannot be repaired from
    -- the baseline, so the value each seed script configures is printed instead.
    --
    -- These are per-process and they do NOT all come from the same file - an
    -- earlier version of this message said "re-run 20 / 24 / 25", which silently
    -- left two of the five processes at the perf cap: AAD_ORDER_ARCH's 200 is in
    -- 04_seed_order.sql and AAD_WORKQ_ARCH's 250 in 05_seed_workq.sql, while
    -- 25_seed_document_sets.sql never touches MaxBatchesPerRun at all. Naming the
    -- value and its owning script per process removes the guesswork.
    IF EXISTS (SELECT 1 FROM arch.Process WHERE MaxBatchesPerRun = 1000000)
    BEGIN
        SELECT
            Section        = 'CAP_UNRECOVERABLE',
            p.ProcessCode,
            CurrentValue   = p.MaxBatchesPerRun,
            ConfiguredValue = CASE p.ProcessCode
                                WHEN N'AAD_ORDER_ARCH'      THEN 200
                                WHEN N'AAD_WORKQ_ARCH'      THEN 250
                                WHEN N'AAD_TRANLOG_ARCH'    THEN 250
                                WHEN N'AAD_PICKDETAIL_ARCH' THEN 250
                                WHEN N'ADV_LOGMSG_ARCH'     THEN 250
                              END,
            OwningScript   = CASE p.ProcessCode
                                WHEN N'AAD_ORDER_ARCH'      THEN '04_seed_order.sql'
                                WHEN N'AAD_WORKQ_ARCH'      THEN '05_seed_workq.sql'
                                WHEN N'AAD_TRANLOG_ARCH'    THEN '20_seed_standalone.sql'
                                WHEN N'AAD_PICKDETAIL_ARCH' THEN '20_seed_standalone.sql'
                                WHEN N'ADV_LOGMSG_ARCH'     THEN '24_seed_logmessage_anchor.sql'
                                ELSE '(not a process this package configures)'
                              END,
            FixSql         = N'UPDATE arch.Process SET MaxBatchesPerRun = <ConfiguredValue>, ModifiedAt = SYSUTCDATETIME() WHERE ProcessCode = N'''
                             + p.ProcessCode + N''';'
        FROM arch.Process p
        WHERE p.MaxBatchesPerRun = 1000000
        ORDER BY p.ProcessCode;

        PRINT '*** A process is still at the perf cap of 1000000 with no baseline on file. ***';
        PRINT '    See CAP_UNRECOVERABLE above: it names the configured value and the script';
        PRINT '    that owns it for each affected process. Re-running the owning seed script';
        PRINT '    rewrites the whole process configuration; the FixSql column changes only';
        PRINT '    the cap, which is usually what you want.';
    END;
END;
GO

PRINT '';
PRINT '42_perf_restore: done.';
GO
