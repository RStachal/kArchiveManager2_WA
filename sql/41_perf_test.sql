-- ============================================================================
-- 41 - PERFORMANCE TEST: how many rows does one minute archive+delete?
-- ============================================================================
-- Runs each document set on its own for a bounded window and reports the rate
-- per table. Requires 40_perf_seed.sql to have run first.
--
-- WHAT IS MEASURED
--   Mode = 1, so every row is COPIED to the archive database and then DELETED
--   from the source, inside the runner's normal batching and transactions. The
--   rate therefore includes the candidate scan, the archive insert, the delete,
--   the run bookkeeping and log writes - i.e. what the scheduled job will
--   actually do, not a raw DELETE benchmark.
--
-- HOW THE WINDOW IS ENFORCED
--   Three separate things can stop a run, and for this to measure a RATE the
--   stopping condition must be TIME:
--     RunProfile.RunWindowMinutes  - the wall-clock window            <- we want this
--     RunProfile.MaxCandidates     - a cap on candidates              -> set to NULL
--     Process.MaxBatchesPerRun     - a cap on batches                 -> raised, then restored
--   The configured MaxBatchesPerRun (200-250) would otherwise stop a fast set
--   early and understate it. Original values are saved and put back at the end,
--   including on failure.
--
--   The window is checked BETWEEN batches, so a run overshoots by up to one
--   batch. The report uses the ACTUAL elapsed time, not the nominal 60 s.
--
-- VALIDITY CHECK
--   If a set exhausts its eligible rows before the window closes, its number is
--   a volume, not a rate. The report flags that as DATA EXHAUSTED and the figure
--   must not be quoted as throughput - seed more rows and repeat.
--
-- CONTEXT FOR THE NUMBERS
--   There are NO custom indexes in the WMS databases (house rule - see
--   08_source_indexes.sql), so these are honest no-index figures, which is the
--   production scenario. Two sets do have a usable native index on their cutoff
--   column (t_tran_log.i_tran_log leads on start_tran_date; ADV.i_log_message is
--   clustered on logged_on_utc); t_order, t_pick_detail and t_work_q have none,
--   so their candidate scan reads the whole table each pass.
-- ============================================================================
:setvar AdminDb "kArchiveManagerAdmin"
-- The source databases are needed for the still-eligible snapshot. They must be
-- declared here even though this script otherwise works entirely inside the admin
-- database: Run-Deploy.ps1 rewrites only :setvar lines that already exist, and it
-- calls sqlcmd without -v, so a name that is not declared cannot be overridden.
:setvar WmsDb "AAD"
:setvar AdvDb "ADV"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar RunnerLogin "karch_runtime_svc"
:setvar WindowMinutes "1"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

PRINT '=== Performance test: $(WindowMinutes) minute(s) per document set ===';
PRINT '';
GO

-------------------------------------------------------------------------------
-- Save the batching caps, then lift them so TIME is the only limit.
--
-- THE BASELINE IS DURABLE, AND IT IS NEVER OVERWRITTEN. Both properties are
-- load-bearing, and the first version of this script had neither:
--   * it kept the baseline in a ##global temp table, so a run that died before
--     the restore took the only record of the original values with it;
--   * the next run then read MaxBatchesPerRun = 1000000 - the LIFTED value left
--     behind - and dutifully "restored" that. All five processes were silently
--     left with a million-batch cap, which is a real production hazard: it
--     removes the only bound on how long one scheduled run can hold locks.
-- A row in perf.TestBaseline that is only ever INSERTed WHERE NOT EXISTS cannot
-- degrade that way. A crashed cycle leaves the true originals sitting there and
-- the next 41 (or 42_perf_restore.sql) puts them back.
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

DECLARE @PerfCap int = 1000000;

-- Refuse to capture a value that is itself a perf sentinel: that can only mean a
-- previous cycle died between lift and restore, and the genuine original is
-- already on file (or lost, in which case guessing is worse than reporting it).
INSERT perf.TestBaseline(ItemKind, ItemName, IntValue)
SELECT 'PROCESS_CAP', p.ProcessCode, p.MaxBatchesPerRun
FROM arch.Process p
WHERE p.IsEnabled = 1
  AND p.MaxBatchesPerRun <> @PerfCap
  AND NOT EXISTS (SELECT 1 FROM perf.TestBaseline b
                  WHERE b.ItemKind = 'PROCESS_CAP' AND b.ItemName = p.ProcessCode);

IF EXISTS (SELECT 1 FROM arch.Process p
           WHERE p.IsEnabled = 1 AND p.MaxBatchesPerRun = @PerfCap
             AND NOT EXISTS (SELECT 1 FROM perf.TestBaseline b
                             WHERE b.ItemKind = 'PROCESS_CAP' AND b.ItemName = p.ProcessCode))
BEGIN
    PRINT '*** WARNING: a process is already at the perf cap with no baseline on file. ***';
    PRINT '    A previous run must have been killed between lifting and restoring, and';
    PRINT '    its original MaxBatchesPerRun is not recoverable from here. Run';
    PRINT '    42_perf_restore.sql afterwards - its CAP_UNRECOVERABLE section names the';
    PRINT '    configured value and the owning seed script for each affected process.';
    SELECT Section = 'CAP_UNRECOVERABLE', p.ProcessCode, p.MaxBatchesPerRun
    FROM arch.Process p
    WHERE p.IsEnabled = 1 AND p.MaxBatchesPerRun = @PerfCap
      AND NOT EXISTS (SELECT 1 FROM perf.TestBaseline b
                      WHERE b.ItemKind = 'PROCESS_CAP' AND b.ItemName = p.ProcessCode);
END;

UPDATE arch.Process SET MaxBatchesPerRun = @PerfCap, ModifiedAt = SYSUTCDATETIME() WHERE IsEnabled = 1;

SELECT Section = 'CAPS_LIFTED', ProcessCode = b.ItemName,
       OriginalMaxBatchesPerRun = b.IntValue, NowLiftedTo = p.MaxBatchesPerRun,
       BaselineTakenAtUtc = b.CapturedAtUtc
FROM perf.TestBaseline b
JOIN arch.Process p ON p.ProcessCode = b.ItemName
WHERE b.ItemKind = 'PROCESS_CAP'
ORDER BY b.ItemName;
GO

-------------------------------------------------------------------------------
-- One bounded profile per enabled set.
--
-- MaxCandidates IS SET EXPLICITLY, AND MUST BE. Leaving it NULL does NOT mean
-- "no cap" - it means the runner computes one, and for the TIMESTAMP strategy
-- that computed value is capped at 100 batches no matter how high
-- MaxBatchesPerRun is:
--
--     -- 027_usp_RunTimestampProcess.sql, in the @MaxRows IS NULL branch
--     @DefaultCandidateBatches = CASE WHEN @MaxBatches > 100 THEN 100 ELSE @MaxBatches END
--     @MaxRows = @BatchRowCount * @DefaultCandidateBatches
--
-- with @BatchRowCount itself hard-capped at 4000 (lock escalation), so the
-- ceiling is 4000 x 100 = 400000 rows per invocation. That is exactly what was
-- measured before this was understood: t_work_q stopped at 400000 rows in 100
-- batches after 43 of the 60 seconds, with 200000 rows still eligible, and the
-- validity check happily called it "TIME was the limit". It was not.
--
-- Candidates are read from the source ONCE per run - there is no loop back to
-- preparation - so this cap is a hard ceiling on the volume of a whole run, for
-- both strategies. Raising MaxBatchesPerRun above 100 changes nothing for
-- TIMESTAMP; only MaxCandidates does, because it bypasses that CASE entirely.
--
-- OPERATIONAL CONSEQUENCE, worth more than the benchmark: a scheduled TIMESTAMP
-- process left with MaxCandidates NULL will never move more than 400000 rows per
-- invocation, however long its window is.
-------------------------------------------------------------------------------
:setvar MaxCandidates "2000000"

DECLARE @pc sysname, @db sysname, @code sysname, @ord int = 500;
DECLARE @rp int, @cs bigint;

DECLARE cp CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.ProcessCode, pd.SourceDb
    FROM arch.Process p
    JOIN arch.ProcessDatabase pd ON pd.ProcessId = p.ProcessId
    WHERE p.IsEnabled = 1 AND pd.IsEnabled = 1
    ORDER BY pd.RunOrder;
OPEN cp;
FETCH NEXT FROM cp INTO @pc, @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @code = N'PERF_' + @pc;
    SET @rp = NULL; SET @cs = NULL;
    EXEC arch.usp_Api_SaveRunProfile
        @RunProfileId      = @rp OUTPUT,
        @RunProfileCode    = @code,
        @RequestedBy       = N'kam-perf',
        @ChangeReason      = N'Bounded window performance measurement.',
        @Description       = N'Perf: one set, time-bounded, no candidate cap.',
        @IsEnabled         = 1,
        @RunOnSchedule     = 0,
        @RunOrder          = @ord,
        @ProcessCodeFilter = @pc,
        @SourceDbFilter    = @db,
        @RunWindowMinutes  = $(WindowMinutes),
        @DryRun            = 0,
        @MaxCandidates     = $(MaxCandidates),
        @ConfigChangeSetId = @cs OUTPUT;
    SET @ord = @ord + 1;
    FETCH NEXT FROM cp INTO @pc, @db;
END;
CLOSE cp; DEALLOCATE cp;

SELECT Section = 'PERF_PROFILES', RunProfileCode, ProcessCodeFilter, SourceDbFilter,
       RunWindowMinutes, ISNULL(CONVERT(varchar(20), MaxCandidates), '(none)') AS MaxCandidates
FROM arch.RunProfile WHERE RunProfileCode LIKE N'PERF[_]%' ORDER BY RunOrder;
GO

-- Note where the vendor log purge stands, so the report can tell whether it ran
-- while we were measuring. It can be started by the application at any time, and
-- disabling the Agent job does not stop that.
IF OBJECT_ID(N'tempdb..##PurgeBefore', N'U') IS NOT NULL DROP TABLE ##PurgeBefore;
CREATE TABLE ##PurgeBefore (LastInstanceId int NULL);
INSERT ##PurgeBefore
SELECT ISNULL(MAX(h.instance_id), 0)
FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name = N'Log Maintenance';
GO

-------------------------------------------------------------------------------
-- Record where the measurement starts, so the report can isolate these runs.
-------------------------------------------------------------------------------
IF OBJECT_ID(N'tempdb..##PerfStart', N'U') IS NOT NULL DROP TABLE ##PerfStart;
CREATE TABLE ##PerfStart (StartedAtUtc datetime2(0) NOT NULL, MaxRunId bigint NOT NULL);
INSERT ##PerfStart SELECT SYSUTCDATETIME(), ISNULL(MAX(RunId), 0) FROM arch.Run;
GO

-------------------------------------------------------------------------------
-- Clear open DRY-RUN batches, then run each set. Impersonating the runner login
-- keeps this on the same code path as the Agent job (see 22_simulate_job.sql).
--
-- usp_CloseDryRunWorkBatches does exactly what its name says - DRY-RUN batches.
-- A Paused REAL batch is left alone, because resuming it is the product's
-- intended behaviour. That is handled in 40_perf_seed.sql, which is what
-- invalidates it, and the guard below refuses to measure if one slipped through.
-------------------------------------------------------------------------------
DECLARE @pc2 sysname;
DECLARE cq CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT ProcessCode FROM arch.Process;
OPEN cq;
FETCH NEXT FROM cq INTO @pc2;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC arch.usp_CloseDryRunWorkBatches @StaleMinutes = 0, @ApplyChanges = 1, @OnlyProcessCode = @pc2, @IncludeRunning = 0;
    FETCH NEXT FROM cq INTO @pc2;
END;
CLOSE cq; DEALLOCATE cq;
GO

-------------------------------------------------------------------------------
-- GUARD: A RESUMED BATCH MAKES THE MEASUREMENT MEANINGLESS, SO REFUSE TO START
--
-- An open (Paused / Prepared / Running) batch is resumed with the cutoff it was
-- prepared under, not today's. After a re-seed its keys point at rows that no
-- longer exist, and the run then reports Status OK with tens of thousands of
-- documents and zero rows deleted - a result that looks like a measurement and
-- is not one. Failing loudly here is far better than publishing that number.
-------------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM arch.WorkBatch WHERE Status NOT IN (N'Completed', N'Failed'))
BEGIN
    SELECT Section = 'OPEN_BATCH_BLOCKS_MEASUREMENT', wb.WorkBatchId, p.ProcessCode,
           wb.Status, wb.PreparedAtUtc, CutoffItWouldReuse = wb.RangeToUtc,
           KeyCount = (SELECT COUNT(*) FROM arch.WorkBatchKey k WHERE k.WorkBatchId = wb.WorkBatchId)
    FROM arch.WorkBatch wb
    JOIN arch.Process p ON p.ProcessId = wb.ProcessId
    WHERE wb.Status NOT IN (N'Completed', N'Failed')
    ORDER BY wb.WorkBatchId;

    THROW 60900, 'Open candidate batch present - run 40_perf_seed.sql first, which invalidates it. Measuring now would resume a stale cutoff and report a false rate.', 1;
END;
GO

PRINT '';
PRINT '--- Running each set for $(WindowMinutes) minute(s). Please wait. ---';
GO

-- The profile list is resolved HERE, as the caller, into a GLOBAL temp table.
-- Two reasons this cannot be done inside the impersonated block:
--   * the runner login holds EXECUTE on the runner chain but NOT SELECT on
--     arch.RunProfile - that is the least-privilege model working as intended,
--     and reading it as the runner fails with "SELECT permission was denied";
--   * a local temp table would not be the issue, but the run list has to exist
--     before impersonation starts.
IF OBJECT_ID(N'tempdb..##PerfQueue', N'U') IS NOT NULL DROP TABLE ##PerfQueue;
CREATE TABLE ##PerfQueue (Ord int IDENTITY(1,1) PRIMARY KEY, RunProfileCode sysname NOT NULL);
INSERT ##PerfQueue(RunProfileCode)
SELECT RunProfileCode FROM arch.RunProfile WHERE RunProfileCode LIKE N'PERF[_]%' ORDER BY RunOrder;
GO

-- EXECUTE AS, the loop and REVERT must all sit in ONE batch: impersonation ends
-- at the batch boundary, so a GO between them would silently run the archiving
-- as the caller instead of as the job owner.
DECLARE @code sysname, @i int = 1, @max int = (SELECT MAX(Ord) FROM ##PerfQueue);

EXECUTE AS LOGIN = '$(RunnerLogin)';

WHILE @i <= @max
BEGIN
    SELECT @code = RunProfileCode FROM ##PerfQueue WHERE Ord = @i;
    BEGIN TRY
        EXEC arch.usp_RunProfile_Prepared @RunProfileCode = @code;
    END TRY
    BEGIN CATCH
        PRINT 'Run ' + ISNULL(@code, N'(null)') + ' failed: ' + ERROR_MESSAGE();
    END CATCH;
    SET @i = @i + 1;
END;

REVERT;
GO

-------------------------------------------------------------------------------
-- SNAPSHOT WHAT IS STILL ELIGIBLE - NOW, BEFORE ANYTHING IS RESTORED
--
-- This has to happen before the vendor log purge job is switched back on. It was
-- originally read at the end of the script, after the restore, and by then ADV's
-- own purge had already trimmed t_log_message down to LogPurgeToSize - taking the
-- seeded rows with it. The report therefore said "0 still eligible" and dismissed
-- a perfectly good 3780 rows/s as DATA EXHAUSTED. The number was right; the
-- moment it was taken was wrong.
--
-- TWO THINGS PROTECT THE RESTORE FROM THIS BLOCK, and both are necessary:
--
--   * the source database names come from $(WmsDb) / $(AdvDb), not literals. An
--     earlier version hardcoded AAD and ADV here, which happened to work only
--     because the reference instance is named that way. Anywhere else it raised
--     Msg 208 - and because this block sits BEFORE the restore, ":on error exit"
--     would have terminated sqlcmd with all five caps still at 1000000 and the
--     vendor job still disabled. A diagnostic must never be able to do that.
--
--   * the whole snapshot is wrapped in TRY/CATCH. Safety must not depend on
--     reporting succeeding: if this fails for any other reason the script says
--     so, leaves the table empty, and carries on to put everything back.
-------------------------------------------------------------------------------
DECLARE @AadRet0 int, @AadLag0 int, @AdvRet0 int, @AdvLag0 int;
SELECT @AadRet0 = MIN(RetentionDays), @AadLag0 = MIN(CutoffSafetyLagMinutes)
FROM arch.Process WHERE ProcessCode LIKE N'AAD[_]%';
SELECT @AdvRet0 = RetentionDays, @AdvLag0 = CutoffSafetyLagMinutes
FROM arch.Process WHERE ProcessCode = N'ADV_LOGMSG_ARCH';

DECLARE @Cut0 datetime2(0) =
    DATEADD(MINUTE, -ISNULL(@AadLag0, 1440), DATEADD(DAY, -ISNULL(@AadRet0, 90), CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @CutAdv0 datetime2(0) =
    DATEADD(MINUTE, -ISNULL(@AdvLag0, 1440), DATEADD(DAY, -ISNULL(@AdvRet0, 90), CONVERT(datetime2(0), SYSUTCDATETIME())));
DECLARE @Tz0 nvarchar(200) = N'Central European Standard Time';

IF OBJECT_ID(N'tempdb..##PerfRemaining', N'U') IS NOT NULL DROP TABLE ##PerfRemaining;
CREATE TABLE ##PerfRemaining (ProcessCode sysname PRIMARY KEY, StillEligible bigint NOT NULL,
                              TakenAtUtc datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME());

DECLARE @W nvarchar(300) = QUOTENAME(N'$(WmsDb)') + N'.dbo.';
DECLARE @A nvarchar(300) = QUOTENAME(N'$(AdvDb)') + N'.dbo.';

DECLARE @snap nvarchar(max) = N'
SELECT ''AAD_ORDER_ARCH'', COUNT_BIG(*)
FROM ' + @W + N't_order o
WHERE o.order_number LIKE N''KAMT-%'' AND o.status IN (N''S'', N''D'')
  AND o.lock_flag IS NULL AND o.consolidated_order_number IS NULL
  AND CAST(CAST(COALESCE(NULLIF(o.actual_ship_date,''19000101''), o.order_date) AS datetime2)
      AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''AAD_PICKDETAIL_ARCH'', COUNT_BIG(*)
FROM ' + @W + N't_pick_detail p
WHERE p.lot_number = N''KAMTEST'' AND p.status = N''SHIPPED''
  AND CAST(TRY_CONVERT(datetime2, p.create_date) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''AAD_TRANLOG_ARCH'', COUNT_BIG(*)
FROM ' + @W + N't_tran_log l
WHERE l.generic_text1 = N''KAMTEST'' AND l.start_tran_date > ''19000102''
  AND CAST(TRY_CONVERT(datetime2, l.start_tran_date) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''AAD_WORKQ_ARCH'', COUNT_BIG(*)
FROM ' + @W + N't_work_q q
WHERE q.work_q_id LIKE N''KAMTQ%'' AND q.datetime_stamp IS NOT NULL AND q.work_status IN (N''C'', N''P'')
  AND CAST(TRY_CONVERT(datetime2, q.datetime_stamp) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''AAD_PO_ARCH'', COUNT_BIG(*)
FROM ' + @W + N't_po_master m2
WHERE m2.po_number LIKE N''KAMPO-B%'' AND m2.status = N''C'' AND m2.closed_date IS NOT NULL
  AND CAST(CAST(m2.closed_date AS datetime2) AT TIME ZONE @Tz AT TIME ZONE N''UTC'' AS datetime2(0)) < @Cut
UNION ALL
SELECT ''ADV_LOGMSG_ARCH'', COUNT_BIG(*)
FROM ' + @A + N't_log_message m
WHERE m.machine_id = N''KAMTEST''
  AND CAST(TRY_CONVERT(datetime2, m.logged_on_utc) AT TIME ZONE N''UTC'' AT TIME ZONE N''UTC'' AS datetime2(0)) < @CutAdv;';

BEGIN TRY
    INSERT ##PerfRemaining(ProcessCode, StillEligible)
    EXEC sys.sp_executesql @snap,
         N'@Cut datetime2(0), @CutAdv datetime2(0), @Tz nvarchar(200)',
         @Cut = @Cut0, @CutAdv = @CutAdv0, @Tz = @Tz0;
END TRY
BEGIN CATCH
    PRINT '*** The still-eligible snapshot failed: ' + ERROR_MESSAGE();
    PRINT '    The VALIDITY section will report UNKNOWN. This does NOT affect the';
    PRINT '    measured rates, and the restore below still runs.';
END CATCH;
GO

-------------------------------------------------------------------------------
-- Put EVERYTHING back before any reporting can fail: the batching caps and the
-- vendor log purge job that 40_perf_seed.sql suspended. The baseline rows are
-- deleted only after the value has actually been written back, so a failure here
-- leaves them on file for 42_perf_restore.sql instead of losing them.
-------------------------------------------------------------------------------
UPDATE p
SET MaxBatchesPerRun = b.IntValue, ModifiedAt = SYSUTCDATETIME()
FROM arch.Process p
JOIN perf.TestBaseline b ON b.ItemName = p.ProcessCode AND b.ItemKind = 'PROCESS_CAP';

SELECT Section = 'CAPS_RESTORED', p.ProcessCode, p.MaxBatchesPerRun,
       Verdict = CASE WHEN p.MaxBatchesPerRun = b.IntValue THEN 'restored' ELSE 'MISMATCH' END
FROM arch.Process p
JOIN perf.TestBaseline b ON b.ItemName = p.ProcessCode AND b.ItemKind = 'PROCESS_CAP'
ORDER BY p.ProcessCode;

DELETE b
FROM perf.TestBaseline b
JOIN arch.Process p ON p.ProcessCode = b.ItemName
WHERE b.ItemKind = 'PROCESS_CAP' AND p.MaxBatchesPerRun = b.IntValue;
GO

-- The vendor purge job. sp_update_job is called only when the recorded state
-- differs from the current one, so re-running this is harmless.
DECLARE @Job sysname, @Want int, @Now int;
DECLARE cj CURSOR LOCAL FAST_FORWARD FOR
    SELECT b.ItemName, b.IntValue FROM perf.TestBaseline b WHERE b.ItemKind = 'AGENT_JOB';
OPEN cj;
FETCH NEXT FROM cj INTO @Job, @Want;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Now = (SELECT TOP (1) CONVERT(int, enabled) FROM msdb.dbo.sysjobs WHERE name = @Job);
    IF @Now IS NULL
        PRINT 'WARN: job "' + @Job + '" no longer exists - baseline row kept.';
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

IF EXISTS (SELECT 1 FROM perf.TestBaseline)
    SELECT Section = 'BASELINE_STILL_PENDING', ItemKind, ItemName, IntValue, CapturedAtUtc
    FROM perf.TestBaseline ORDER BY ItemKind, ItemName;
GO

-------------------------------------------------------------------------------
-- RESULTS
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- THE CONDITIONS THE MEASUREMENT RAN UNDER
--
-- Archiving is write-bound: every row is INSERTed into the archive database and
-- DELETEd from the source, so WRITELOG is the dominant wait and the state of the
-- transaction logs governs the result. Two identical runs of this script on the
-- same instance produced 4364 and 2372 rows/s for t_pick_detail - a factor of two
-- - with an identical candidate-preparation time, i.e. the whole difference was
-- in the write phase. The cause was not established, but by the second run the
-- source log had reached 23.8 GB in FULL recovery with every VLF active and
-- log_reuse_wait_desc = LOG_BACKUP.
--
-- A throughput figure without these numbers beside it is not reproducible, so
-- they are recorded with every run. If you are comparing two results and they
-- disagree, compare this section first.
-------------------------------------------------------------------------------
PRINT '';
PRINT '=== CONDITIONS: the log state that governs write throughput ===';
GO
SELECT
    Section        = 'CONDITIONS',
    DbName         = d.name,
    Recovery       = d.recovery_model_desc,
    LogReuseWait   = d.log_reuse_wait_desc,
    LogSizeMB      = CONVERT(int, lf.size * 8.0 / 1024),
    LogGrowth      = CASE WHEN lf.is_percent_growth = 1
                          THEN CONVERT(varchar(20), lf.growth) + '%'
                          ELSE CONVERT(varchar(20), CONVERT(int, lf.growth * 8.0 / 1024)) + ' MB' END,
    DataSizeMB     = CONVERT(int, df.size * 8.0 / 1024),
    Note           = CASE
                       WHEN d.log_reuse_wait_desc = N'LOG_BACKUP' AND lf.is_percent_growth = 1
                         THEN 'log cannot be reused until a log backup runs, AND it grows by a percentage - both throttle a bulk archive'
                       WHEN d.log_reuse_wait_desc = N'LOG_BACKUP'
                         THEN 'log cannot be reused until a log backup runs'
                       WHEN lf.is_percent_growth = 1
                         THEN 'percentage autogrowth: each growth is larger than the last and blocks all log writes while it zeroes'
                       ELSE 'ok'
                     END
FROM sys.databases d
CROSS APPLY (SELECT TOP (1) size, growth, is_percent_growth FROM sys.master_files
             WHERE database_id = d.database_id AND type_desc = 'LOG' ORDER BY file_id) lf
CROSS APPLY (SELECT TOP (1) size FROM sys.master_files
             WHERE database_id = d.database_id AND type_desc = 'ROWS' ORDER BY file_id) df
WHERE d.name IN (N'$(WmsDb)', N'$(AdvDb)', N'$(AdminDb)', N'$(ArchiveDb)')
ORDER BY d.name;
GO

PRINT '';
PRINT '=== RESULT: per document set ===';
GO
DECLARE @from bigint = (SELECT MaxRunId FROM ##PerfStart);

;WITH r AS
(
    SELECT
        p.ProcessCode,
        p.SelectionStrategy,
        r.RunId,
        r.Status,
        ri.DocsDone,
        ri.RowsArchived,
        ri.RowsDeleted,
        ri.BatchesDone,
        ElapsedMs = DATEDIFF(MILLISECOND, r.StartedAt, r.EndedAt)
    FROM arch.Run r
    JOIN arch.RunItem ri ON ri.RunId = r.RunId
    JOIN arch.Process p ON p.ProcessId = ri.ProcessId
    WHERE r.RunId > @from AND r.Status <> N'DRYRUN'
)
SELECT
    Section       = 'PERF_BY_SET',
    r.ProcessCode,
    r.SelectionStrategy,
    Status_       = r.Status,
    Documents     = r.DocsDone,
    Batches       = r.BatchesDone,
    RowsArchived  = r.RowsArchived,
    RowsDeleted   = r.RowsDeleted,
    Divergence    = r.RowsArchived - r.RowsDeleted,
    ElapsedSec    = CONVERT(decimal(10,1), r.ElapsedMs / 1000.0),
    RowsPerSecond = CASE WHEN r.ElapsedMs > 0
                         THEN CONVERT(decimal(12,0), r.RowsDeleted * 1000.0 / r.ElapsedMs)
                         ELSE NULL END,
    DocsPerSecond = CASE WHEN r.ElapsedMs > 0
                         THEN CONVERT(decimal(12,1), r.DocsDone * 1000.0 / r.ElapsedMs)
                         ELSE NULL END
FROM r
ORDER BY r.RunId;
GO

PRINT '';
PRINT '=== RESULT: per table (this is the per-table answer) ===';
GO
DECLARE @from2 bigint = (SELECT MaxRunId FROM ##PerfStart);

;WITH t AS
(
    SELECT
        p.ProcessCode,
        rio.SourceTable,
        RowsArchived = SUM(rio.RowsArchived),
        RowsDeleted  = SUM(rio.RowsDeleted),
        ElapsedMs    = MAX(DATEDIFF(MILLISECOND, r.StartedAt, r.EndedAt))
    FROM arch.RunItemObject rio
    JOIN arch.RunItem ri ON ri.RunItemId = rio.RunItemId
    JOIN arch.Run r ON r.RunId = ri.RunId
    JOIN arch.Process p ON p.ProcessId = ri.ProcessId
    WHERE r.RunId > @from2 AND r.Status <> N'DRYRUN'
    GROUP BY p.ProcessCode, rio.SourceTable
)
SELECT
    Section       = 'PERF_BY_TABLE',
    t.ProcessCode,
    t.SourceTable,
    t.RowsArchived,
    t.RowsDeleted,
    Divergence    = t.RowsArchived - t.RowsDeleted,
    ElapsedSec    = CONVERT(decimal(10,1), t.ElapsedMs / 1000.0),
    RowsPerSecond = CASE WHEN t.ElapsedMs > 0
                         THEN CONVERT(decimal(12,0), t.RowsDeleted * 1000.0 / t.ElapsedMs)
                         ELSE NULL END
FROM t
ORDER BY t.ProcessCode, t.RowsDeleted DESC;
GO

PRINT '';
PRINT '=== VALIDITY: was TIME the limit, or did the data run out? ===';
GO
-- Read from the snapshot taken immediately after the runs, NOT from a fresh count.
-- By this point the vendor log purge has been switched back on and may already
-- have trimmed ADV.t_log_message, which would make a genuine rate look like an
-- exhausted data set. The snapshot is the only honest source for this verdict.
-- LEFT JOIN from the process list, not a plain SELECT from the snapshot: if the
-- snapshot failed the table is empty, and a query that only reads it would print
-- nothing at all - which reads as "no problem" rather than "not verified".
SELECT
    Section       = 'VALIDITY',
    p.ProcessCode,
    StillEligible = r.StillEligible,
    Verdict       = CASE WHEN r.ProcessCode IS NULL THEN 'UNKNOWN - the snapshot did not run; treat the rate as unverified'
                         WHEN r.StillEligible > 0   THEN 'TIME was the limit - the rate is a genuine throughput'
                         ELSE 'DATA EXHAUSTED - this is a volume, not a rate; seed more and repeat' END,
    MeasuredAtUtc = r.TakenAtUtc
FROM arch.Process p
LEFT JOIN ##PerfRemaining r ON r.ProcessCode = p.ProcessCode
WHERE p.IsEnabled = 1
ORDER BY p.ProcessCode;

PRINT '';
PRINT 'StillEligible > 0  => TIME was the limit; the rate is a genuine throughput.';
PRINT 'StillEligible = 0  => DATA EXHAUSTED; that set finished early and its';
PRINT '                      figure is a volume, not a rate. Seed more and repeat.';
GO

-------------------------------------------------------------------------------
-- A SET THAT PRODUCED NO RUN AT ALL IS NOT THE SAME AS A SET THAT RAN AND FOUND
-- NOTHING, and the per-set report cannot tell them apart - a missing run simply
-- does not appear as a row, which reads like an oversight rather than a result.
-- ADV_LOGMSG_ARCH did exactly this on the first attempt and the absence was only
-- noticed because its 300000 seeded rows were also gone.
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- PREPARE VERSUS PROCESS
--
-- The end-to-end figure above is what one scheduled run achieves, and that is
-- the number that matters operationally. But an ANCHOR run spends part of its
-- window SELECTING candidates before it moves a single row, and on a cold
-- backlog that share is large - so "rows per second" over the whole window
-- understates how fast the archiver actually moves rows once it has a keyset.
-- arch.WorkBatch carries the three timestamps needed to separate the two.
-- TIMESTAMP processes do not use WorkBatch at all, so they have no split.
-------------------------------------------------------------------------------
PRINT '';
PRINT '=== SPLIT: candidate preparation vs row processing (ANCHOR only) ===';
GO
DECLARE @fromS bigint = (SELECT MaxRunId FROM ##PerfStart);

SELECT
    Section        = 'PERF_SPLIT',
    p.ProcessCode,
    wb.WorkBatchId,
    Keys           = (SELECT COUNT(*) FROM arch.WorkBatchKey k WHERE k.WorkBatchId = wb.WorkBatchId),
    PrepareSec     = CONVERT(decimal(10,1), DATEDIFF(MILLISECOND, wb.PreparedAtUtc, wb.StartedAtUtc) / 1000.0),
    ProcessSec     = CONVERT(decimal(10,1), DATEDIFF(MILLISECOND, wb.StartedAtUtc, ISNULL(wb.CompletedAtUtc, wb.LastProgressAtUtc)) / 1000.0),
    RowsDeleted    = ri.RowsDeleted,
    SustainedRowsPerSec =
        CASE WHEN DATEDIFF(MILLISECOND, wb.StartedAtUtc, ISNULL(wb.CompletedAtUtc, wb.LastProgressAtUtc)) > 0
             THEN CONVERT(decimal(12,0), ri.RowsDeleted * 1000.0
                  / DATEDIFF(MILLISECOND, wb.StartedAtUtc, ISNULL(wb.CompletedAtUtc, wb.LastProgressAtUtc)))
             ELSE NULL END
FROM arch.WorkBatch wb
JOIN arch.Process p ON p.ProcessId = wb.ProcessId
JOIN arch.RunItem ri ON ri.ProcessId = wb.ProcessId AND ri.RunId > @fromS
WHERE wb.PreparedAtUtc >= (SELECT StartedAtUtc FROM ##PerfStart)
  AND wb.StartedAtUtc IS NOT NULL
ORDER BY p.ProcessCode;
GO

-------------------------------------------------------------------------------
-- DID THE VENDOR LOG PURGE INTERFERE?
--
-- If ADV.usp_PurgeLog ran during the measurement it deleted rows from under the
-- ADV run - competing for locks, and leaving prepared keys addressing rows that
-- no longer exist (which shows up as DocsDone much larger than RowsDeleted).
-- An ADV figure from such a window is not a clean measurement and must be
-- labelled, not quietly published.
-------------------------------------------------------------------------------
PRINT '';
PRINT '=== INTERFERENCE: did the vendor log purge run while we measured? ===';
GO
;WITH h AS
(
    SELECT h.instance_id, h.run_date, h.run_time, h.run_duration, h.message
    FROM msdb.dbo.sysjobhistory h
    JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
    WHERE j.name = N'Log Maintenance' AND h.step_id = 0
      AND h.instance_id > (SELECT LastInstanceId FROM ##PurgeBefore)
)
SELECT
    Section  = 'PURGE_INTERFERENCE',
    RanAt    = CONVERT(varchar(8), h.run_date) + ' ' + RIGHT('000000' + CONVERT(varchar(6), h.run_time), 6),
    DurationSec = h.run_duration,
    -- 'invoked by User <login>' is the giveaway that this was an explicit
    -- sp_start_job from the application rather than the schedule.
    InvokedBy = h.message,
    Impact   = 'ADV_LOGMSG_ARCH figures from this run are NOT clean - the purge deleted rows concurrently'
FROM h
ORDER BY h.instance_id;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobhistory h
               JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
               WHERE j.name = N'Log Maintenance' AND h.step_id = 0
                 AND h.instance_id > (SELECT LastInstanceId FROM ##PurgeBefore))
    PRINT 'No vendor purge ran during the measurement - the ADV figure is clean.';
GO

PRINT '';
PRINT '=== COVERAGE: did every configured set actually get measured? ===';
GO
DECLARE @from3 bigint = (SELECT MaxRunId FROM ##PerfStart);

-- The dry-run filter has to be applied while SELECTING the run items, not in the
-- ON clause of a trailing LEFT JOIN: there it would leave the RunItem row in place
-- with a NULL Run and a dry run would still be counted as an observation.
;WITH obs AS
(
    SELECT ri.ProcessId, ri.RunItemId, ri.RowsDeleted
    FROM arch.RunItem ri
    JOIN arch.Run r ON r.RunId = ri.RunId
    WHERE ri.RunId > @from3 AND r.Status <> N'DRYRUN'
)
SELECT
    Section = 'COVERAGE',
    p.ProcessCode,
    ExpectedProfile = ISNULL(q.RunProfileCode, N'(none)'),
    RunsObserved    = COUNT(o.RunItemId),
    RowsDeleted     = ISNULL(SUM(o.RowsDeleted), 0),
    Verdict         = CASE
                        WHEN q.RunProfileCode IS NULL          THEN 'NOT QUEUED - no perf profile was created'
                        WHEN COUNT(o.RunItemId) = 0            THEN 'NO RUN - queued but never executed; check the run loop output above'
                        WHEN ISNULL(SUM(o.RowsDeleted), 0) = 0 THEN 'RAN, ZERO ROWS - nothing was eligible at the cutoff'
                        ELSE 'measured'
                      END
FROM arch.Process p
LEFT JOIN ##PerfQueue q ON q.RunProfileCode = N'PERF_' + p.ProcessCode
LEFT JOIN obs o ON o.ProcessId = p.ProcessId
WHERE p.IsEnabled = 1
GROUP BY p.ProcessCode, q.RunProfileCode
ORDER BY p.ProcessCode;
GO

-------------------------------------------------------------------------------
-- REMOVE THE BENCHMARKING PROFILES
--
-- These were created by this script, so this script disposes of them. They are
-- enabled, DryRun = 0, RunWindowMinutes = 1 and MaxCandidates = 2000000 - a
-- benchmarking configuration that has no business sitting in a customer's
-- kArchiveManagerAdmin afterwards. RunOnSchedule = 0 keeps the Agent job (which
-- names JOB_DEFAULT) from touching them, so they are untidy rather than
-- dangerous - but leaving them behind would also make 42_perf_restore.sql's
-- claim to undo everything 40/41 changed untrue.
--
-- Matched by prefix, not by a list of names: they are generated one per enabled
-- process, so a newly added document set would otherwise leave its profile here.
-------------------------------------------------------------------------------
DELETE FROM arch.RunProfile WHERE RunProfileCode LIKE N'PERF[_]%';

SELECT Section = 'PERF_PROFILES_REMOVED', Removed = @@ROWCOUNT,
       Remaining = (SELECT COUNT(*) FROM arch.RunProfile WHERE RunProfileCode LIKE N'PERF[_]%');
GO

DROP TABLE IF EXISTS ##PerfStart;
DROP TABLE IF EXISTS ##PerfQueue;
DROP TABLE IF EXISTS ##PerfRemaining;
DROP TABLE IF EXISTS ##PurgeBefore;
GO

PRINT '';
PRINT '41_perf_test: done.';
GO
