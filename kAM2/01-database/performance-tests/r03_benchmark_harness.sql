/* ============================================================================
 * R-03 PERFORMANCE BENCHMARK HARNESS — kArchiveManager 2.0
 * ----------------------------------------------------------------------------
 * Captures FULL per-run performance metrics with correct attribution and
 * evaluates configurable acceptance criteria, for the v2 runner chain
 * (arch.usp_RunConfiguredProcesses_Prepared -> ANCHOR 014/015/016 or TIMESTAMP 027).
 *
 * Objects (schema [bench], kept separate from the product schema [arch]):
 *   bench.Run                  - one row per benchmark run, all metrics + verdict
 *   bench.AcceptanceThreshold  - tunable thresholds (seeded with defaults)
 *   Extended Events session 'bench_concurrency' (deadlocks / lock escalation / spills)
 *   bench.usp_RunBenchmark     - snapshot -> invoke runner -> snapshot -> store -> evaluate
 *   bench.usp_EvaluateAcceptance
 *   bench.vw_BenchmarkReport / bench.usp_BenchmarkReport
 *
 * MEASUREMENT MODEL (see docs/v2-performance-benchmark.md for the full rationale):
 *   - CPU / logical reads / physical reads / writes : delta of sys.dm_exec_sessions
 *     on the harness's OWN session (@@SPID) across the EXEC. The runner is a proc, so
 *     all its batches/transactions run on this session and the cumulative session
 *     counters attribute cleanly to this run.
 *   - tempdb                : delta of sys.dm_db_session_space_usage alloc counters (this @@SPID).
 *   - log bytes per DB      : delta of the cumulative 'Log Bytes Flushed/sec' perf counter
 *     (sys.dm_os_performance_counters, instance_name = DB name) for source + archive DB.
 *   - log free space at start: DBCC SQLPERF(LOGSPACE) (drives the "run cannot fill the log" gate).
 *   - lock waits            : delta of sys.dm_os_wait_stats LCK_M_* (instance-wide proxy).
 *   - deadlocks / lock escalation / sort+hash spills : ring-buffer XE session, read before STOP.
 *
 * *** ISOLATION REQUIREMENT ***: log-bytes, lock-wait and XE counts are instance/DB-window
 * measurements. Run the benchmark on an OTHERWISE-IDLE instance (no concurrent writers on the
 * source/archive DBs) or the deltas will be polluted. Session CPU/reads/tempdb are per-session and
 * remain accurate regardless.
 *
 * Permissions: VIEW SERVER STATE, ALTER ANY EVENT SESSION, ALTER TRACE (or CONTROL SERVER),
 * plus EXECUTE on the runner chain. This is an operator/benchmark tool, NOT the least-privilege
 * runtime account.
 *
 * Idempotent: safe to re-run. Drops/recreates the XE session and procs; preserves data tables.
 * ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
USE [kArchiveManagerAdmin];
GO

IF SCHEMA_ID(N'bench') IS NULL EXEC(N'CREATE SCHEMA [bench] AUTHORIZATION [dbo];');
GO

/* ---- bench.Run : results table -------------------------------------------- */
IF OBJECT_ID(N'bench.Run', N'U') IS NULL
BEGIN
    CREATE TABLE bench.Run
    (
        BenchRunId                 bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_bench_Run PRIMARY KEY,
        Label                      nvarchar(200)  NULL,
        ScaleLabel                 nvarchar(40)   NULL,   -- small/medium/large/prod-rep
        Strategy                   varchar(10)    NULL,   -- ANCHOR / TIMESTAMP / MIXED (operator hint)
        CheapMode                  bit            NULL,
        ProcessCode                sysname        NULL,
        SourceDb                   sysname        NULL,
        ArchiveDb                  sysname        NULL,
        DryRun                     bit            NOT NULL DEFAULT(0),
        MaxCandidates              int            NULL,
        -- timing
        StartedAtUtc               datetime2(3)   NOT NULL,
        EndedAtUtc                 datetime2(3)   NOT NULL,
        DurationMs                 bigint         NOT NULL,
        -- linkage to product telemetry
        KArchiveRunIdFrom          bigint         NULL,
        KArchiveRunIdTo            bigint         NULL,
        -- volume / correctness
        RowsArchived               bigint         NOT NULL DEFAULT(0),
        RowsDeleted                bigint         NOT NULL DEFAULT(0),
        Mode1Archived              bigint         NOT NULL DEFAULT(0),
        Mode1Deleted               bigint         NOT NULL DEFAULT(0),
        Mode1Divergence            bigint         NOT NULL DEFAULT(0),
        HadMode1                   bit            NOT NULL DEFAULT(0),
        RowsPerSec                 decimal(18,1)  NULL,
        BadRunItems                int            NOT NULL DEFAULT(0),
        -- engine metrics (session-attributed)
        CpuMs                      bigint         NULL,
        LogicalReads               bigint         NULL,
        PhysicalReads              bigint         NULL,
        Writes                     bigint         NULL,
        TempdbAllocKB              bigint         NULL,
        LockWaitMs                 bigint         NULL,
        -- log (per DB, window-attributed)
        SourceLogBytes             bigint         NULL,
        ArchiveLogBytes            bigint         NULL,
        SourceLogFreeBytesAtStart  bigint         NULL,
        ArchiveLogFreeBytesAtStart bigint         NULL,
        -- recovery models, captured at run time (drive the SIMPLE-skip log gate)
        SourceRecovery             nvarchar(20)   NULL,
        ArchiveRecovery            nvarchar(20)   NULL,
        -- concurrency (XE, window-attributed)
        Deadlocks                  int            NULL,
        LockEscalationsTotal       int            NULL,
        LockEscalationsSource      int            NULL,
        SortWarnings               int            NULL,
        HashWarnings               int            NULL,
        -- verdict
        Verdict                    varchar(12)    NULL,   -- PASS / FAIL / DRYRUN
        FailReasons                nvarchar(max)  NULL,
        Notes                      nvarchar(max)  NULL,
        CreatedAtUtc               datetime2(0)   NOT NULL DEFAULT(sysutcdatetime())
    );
END
GO

/* ---- additive: recovery models (idempotent; CREATE TABLE above is skipped on re-run) ---- */
IF COL_LENGTH(N'bench.Run', N'SourceRecovery') IS NULL
    ALTER TABLE bench.Run ADD SourceRecovery nvarchar(20) NULL;
IF COL_LENGTH(N'bench.Run', N'ArchiveRecovery') IS NULL
    ALTER TABLE bench.Run ADD ArchiveRecovery nvarchar(20) NULL;
GO

/* ---- bench.AcceptanceThreshold : tunable gates ---------------------------- */
IF OBJECT_ID(N'bench.AcceptanceThreshold', N'U') IS NULL
BEGIN
    CREATE TABLE bench.AcceptanceThreshold
    (
        Code         varchar(40)   NOT NULL CONSTRAINT PK_bench_Threshold PRIMARY KEY,
        NumericValue decimal(18,4)  NOT NULL,
        Notes        nvarchar(400)  NULL
    );
END
GO
MERGE bench.AcceptanceThreshold AS t
USING (VALUES
    ('DEADLOCKS_MAX',              0,    N'Deadlocks during the run window. Data-safety: must be 0.'),
    ('LOCK_ESCALATION_SOURCE_MAX', 0,    N'Lock escalations on the SOURCE database during the run. Must be 0 to protect OLTP concurrency (size BatchRowCount below the 5000-lock escalation threshold).'),
    ('DIVERGENCE_MODE1',           0,    N'Mode=1 RowsArchived - RowsDeleted. Core invariant: archived == deleted. Must be 0.'),
    ('LOG_BUDGET_FRACTION',        0.50, N'Per-DB: log bytes generated by the run must be < this fraction of the log FREE space at run start, so a single run cannot fill the log.'),
    ('TEMPDB_MAX_MB',              4096, N'tempdb pages allocated by the run session (MB). Flags runaway sort/hash spill.'),
    ('ROWS_PER_SEC_MIN',           800,  N'Minimum throughput (deleted+archived rows / sec). Measured baselines: ~1600-3000 normal, ~3128 cheap-mode @100M. 800 is a conservative floor.'),
    ('MIN_ROWS_FOR_RATE',          5000, N'Throughput gate applies ONLY when (deleted+archived) >= this. Below it, fixed per-run overhead dominates and rows/sec is meaningless (a 2-row run is not "slow").'),
    ('BAD_RUNITEMS_MAX',           0,    N'arch.RunItem rows with Status NOT IN (OK,DRYRUN,SKIPPED,NOOP). Must be 0.')
) AS s(Code, NumericValue, Notes)
ON t.Code = s.Code
WHEN MATCHED AND t.Notes <> s.Notes THEN UPDATE SET Notes = s.Notes
WHEN NOT MATCHED THEN INSERT (Code, NumericValue, Notes) VALUES (s.Code, s.NumericValue, s.Notes);
GO

/* ---- Extended Events session: deadlocks / lock escalation / spills -------- */
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'bench_concurrency')
    DROP EVENT SESSION [bench_concurrency] ON SERVER;
GO
CREATE EVENT SESSION [bench_concurrency] ON SERVER
    ADD EVENT sqlserver.xml_deadlock_report,
    ADD EVENT sqlserver.lock_escalation,
    ADD EVENT sqlserver.sort_warning,
    ADD EVENT sqlserver.hash_warning
    ADD TARGET package0.ring_buffer (SET max_events_limit = 100000)
    WITH (MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF, TRACK_CAUSALITY = OFF);
GO

/* ============================================================================
 * bench.usp_EvaluateAcceptance — sets Verdict + FailReasons on a bench.Run row
 * ============================================================================ */
CREATE OR ALTER PROCEDURE bench.usp_EvaluateAcceptance
    @BenchRunId bigint
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @fails nvarchar(max) = N'';
    DECLARE @dryrun bit, @srcRec nvarchar(20), @arcRec nvarchar(20);
    SELECT @dryrun = DryRun, @srcRec = SourceRecovery, @arcRec = ArchiveRecovery
    FROM bench.Run WHERE BenchRunId = @BenchRunId;

    DECLARE @deadMax decimal(18,4)  = (SELECT NumericValue FROM bench.AcceptanceThreshold WHERE Code='DEADLOCKS_MAX');
    DECLARE @escMax  decimal(18,4)  = (SELECT NumericValue FROM bench.AcceptanceThreshold WHERE Code='LOCK_ESCALATION_SOURCE_MAX');
    DECLARE @divMax  decimal(18,4)  = (SELECT NumericValue FROM bench.AcceptanceThreshold WHERE Code='DIVERGENCE_MODE1');
    DECLARE @logFrac decimal(18,4)  = (SELECT NumericValue FROM bench.AcceptanceThreshold WHERE Code='LOG_BUDGET_FRACTION');
    DECLARE @tdbMax  decimal(18,4)  = (SELECT NumericValue FROM bench.AcceptanceThreshold WHERE Code='TEMPDB_MAX_MB');
    DECLARE @rpsMin  decimal(18,4)  = (SELECT NumericValue FROM bench.AcceptanceThreshold WHERE Code='ROWS_PER_SEC_MIN');
    DECLARE @minRows decimal(18,4)  = (SELECT NumericValue FROM bench.AcceptanceThreshold WHERE Code='MIN_ROWS_FOR_RATE');
    DECLARE @badMax  decimal(18,4)  = (SELECT NumericValue FROM bench.AcceptanceThreshold WHERE Code='BAD_RUNITEMS_MAX');

    -- Concurrency + integrity gates apply even to dry runs that hold locks; data gates are skipped for dry runs.
    SELECT @fails = @fails
        + CASE WHEN Deadlocks > @deadMax
               THEN CONCAT(N'Deadlocks=', Deadlocks, N' (max ', @deadMax, N'); ') ELSE N'' END
        + CASE WHEN LockEscalationsSource > @escMax
               THEN CONCAT(N'Source lock escalations=', LockEscalationsSource, N' (max ', @escMax, N'); ') ELSE N'' END
        + CASE WHEN BadRunItems > @badMax
               THEN CONCAT(N'Bad RunItems=', BadRunItems, N' (max ', @badMax, N'); ') ELSE N'' END
        + CASE WHEN TempdbAllocKB IS NOT NULL AND (TempdbAllocKB/1024.0) > @tdbMax
               THEN CONCAT(N'tempdb=', CAST(TempdbAllocKB/1024.0 AS decimal(18,1)), N' MB (max ', @tdbMax, N'); ') ELSE N'' END
        -- data gates (skip when DryRun)
        + CASE WHEN @dryrun = 0 AND HadMode1 = 1 AND ABS(Mode1Divergence) > @divMax
               THEN CONCAT(N'Mode1 divergence=', Mode1Divergence, N' (must be ', @divMax, N'); ') ELSE N'' END
        -- Log-budget gates apply only to FULL/BULK_LOGGED DBs. Under SIMPLE recovery the log
        -- truncates on every checkpoint, so cumulative bytes-flushed cannot fill the log; comparing
        -- it to point-in-time free space is a false positive. Skip the gate for SIMPLE source/archive.
        + CASE WHEN @dryrun = 0 AND ISNULL(@srcRec, N'') <> N'SIMPLE'
                    AND SourceLogBytes IS NOT NULL AND SourceLogFreeBytesAtStart > 0
                    AND SourceLogBytes >= @logFrac * SourceLogFreeBytesAtStart
               THEN CONCAT(N'Source log ', CAST(SourceLogBytes/1048576.0 AS decimal(18,1)), N' MB >= ', @logFrac,
                           N' x free ', CAST(SourceLogFreeBytesAtStart/1048576.0 AS decimal(18,1)), N' MB; ') ELSE N'' END
        + CASE WHEN @dryrun = 0 AND ISNULL(@arcRec, N'') <> N'SIMPLE'
                    AND ArchiveLogBytes IS NOT NULL AND ArchiveLogFreeBytesAtStart > 0
                    AND ArchiveLogBytes >= @logFrac * ArchiveLogFreeBytesAtStart
               THEN CONCAT(N'Archive log ', CAST(ArchiveLogBytes/1048576.0 AS decimal(18,1)), N' MB >= ', @logFrac,
                           N' x free ', CAST(ArchiveLogFreeBytesAtStart/1048576.0 AS decimal(18,1)), N' MB; ') ELSE N'' END
        + CASE WHEN @dryrun = 0 AND (RowsDeleted + RowsArchived) >= @minRows AND RowsPerSec IS NOT NULL AND RowsPerSec < @rpsMin
               THEN CONCAT(N'Throughput ', RowsPerSec, N' rows/s < min ', @rpsMin, N' (', RowsDeleted+RowsArchived, N' rows); ') ELSE N'' END
    FROM bench.Run WHERE BenchRunId = @BenchRunId;

    UPDATE bench.Run
       SET Verdict     = CASE WHEN @dryrun = 1 THEN N'DRYRUN'
                              WHEN LEN(@fails) = 0 THEN N'PASS' ELSE N'FAIL' END,
           FailReasons = NULLIF(@fails, N'')
     WHERE BenchRunId = @BenchRunId;
END
GO

/* ============================================================================
 * bench.usp_RunBenchmark — the harness entry point
 * ============================================================================ */
CREATE OR ALTER PROCEDURE bench.usp_RunBenchmark
    @ProcessCode   sysname,
    @SourceDb      sysname,
    @ArchiveDb     sysname,
    @Label         nvarchar(200) = NULL,
    @ScaleLabel    nvarchar(40)  = NULL,
    @Strategy      varchar(10)   = NULL,   -- optional operator hint (ANCHOR/TIMESTAMP)
    @CheapMode     bit           = NULL,   -- optional operator hint
    @MaxCandidates int           = NULL,
    @StopMinutes   int           = 120,
    @DryRun        bit           = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @srcId int = DB_ID(@SourceDb);
    IF @srcId IS NULL THROW 60001, 'bench.usp_RunBenchmark: source database not found.', 1;
    DECLARE @srcRecovery nvarchar(20) = (SELECT recovery_model_desc FROM sys.databases WHERE name = @SourceDb);
    DECLARE @arcRecovery nvarchar(20) = (SELECT recovery_model_desc FROM sys.databases WHERE name = @ArchiveDb);

    -- ---- window/context reads FIRST (their cost must not count toward the run's session deltas)
    -- log free space at start (drives the "cannot fill the log" gate)
    DECLARE @logspace TABLE (DBName sysname, LogSizeMB float, LogUsedPct float, Status int);
    INSERT INTO @logspace EXEC('DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS');
    DECLARE @srcFree bigint = (SELECT CAST(LogSizeMB*(1.0-LogUsedPct/100.0)*1048576 AS bigint) FROM @logspace WHERE DBName=@SourceDb);
    DECLARE @arcFree bigint = (SELECT CAST(LogSizeMB*(1.0-LogUsedPct/100.0)*1048576 AS bigint) FROM @logspace WHERE DBName=@ArchiveDb);

    DECLARE @srcLog0 bigint = (SELECT TOP(1) cntr_value FROM sys.dm_os_performance_counters
                               WHERE counter_name = N'Log Bytes Flushed/sec' AND RTRIM(instance_name) = @SourceDb);
    DECLARE @arcLog0 bigint = (SELECT TOP(1) cntr_value FROM sys.dm_os_performance_counters
                               WHERE counter_name = N'Log Bytes Flushed/sec' AND RTRIM(instance_name) = @ArchiveDb);

    DECLARE @runId0 bigint = (SELECT ISNULL(MAX(RunId),0) FROM arch.Run);

    -- start a clean concurrency capture window (degrade gracefully if no XE permission)
    DECLARE @xeOn bit = 1;
    BEGIN TRY ALTER EVENT SESSION [bench_concurrency] ON SERVER STATE = STOP; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY ALTER EVENT SESSION [bench_concurrency] ON SERVER STATE = START; END TRY
    BEGIN CATCH SET @xeOn = 0; END CATCH;

    -- ---- session baselines LAST, immediately before the run ----------------
    -- NOTE: use dm_exec_REQUESTS + dm_db_TASK_space_usage (LIVE in-flight request/task) — the
    -- *_sessions DMVs only roll up COMPLETED requests, so they read 0 for work done by the still-
    -- running benchmark batch (including the nested runner EXEC).
    DECLARE @lck0 bigint = (SELECT ISNULL(SUM(wait_time_ms),0) FROM sys.dm_os_wait_stats WHERE wait_type LIKE 'LCK[_]M[_]%');
    DECLARE @tdbUser0 bigint, @tdbInt0 bigint;
    SELECT @tdbUser0 = ISNULL(SUM(user_objects_alloc_page_count),0),
           @tdbInt0  = ISNULL(SUM(internal_objects_alloc_page_count),0)
      FROM sys.dm_db_task_space_usage WHERE session_id = @@SPID;
    DECLARE @cpu0 bigint, @lreads0 bigint, @preads0 bigint, @writes0 bigint;
    SELECT @cpu0 = ISNULL(SUM(cpu_time),0), @lreads0 = ISNULL(SUM(logical_reads),0),
           @preads0 = ISNULL(SUM(reads),0), @writes0 = ISNULL(SUM(writes),0)
      FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    DECLARE @t0 datetime2(7) = SYSUTCDATETIME();
    DECLARE @runErr nvarchar(2048) = NULL;
    DECLARE @stopUtc datetime2(0) = DATEADD(MINUTE, ISNULL(@StopMinutes,120), SYSUTCDATETIME());

    -- ---- invoke the runner (same session => clean per-session attribution) -
    BEGIN TRY
        EXEC arch.usp_RunConfiguredProcesses_Prepared
             @ProcessCode = @ProcessCode, @SourceDb = @SourceDb, @ArchiveDb = @ArchiveDb,
             @StopAtUtc = @stopUtc, @DryRun = @DryRun, @MaxCandidates = @MaxCandidates;
    END TRY
    BEGIN CATCH
        SET @runErr = CONCAT(N'Runner error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE());
    END CATCH;

    DECLARE @t1 datetime2(7) = SYSUTCDATETIME();

    -- ---- read XE ring buffer BEFORE stopping (dm_xe_sessions lists running only)
    DECLARE @xml xml, @dead int = 0, @escT int = 0, @escS int = 0, @sortw int = 0, @hashw int = 0;
    IF @xeOn = 0 SET @runErr = CONCAT(ISNULL(@runErr + N' | ', N''), N'XE not started (need ALTER ANY EVENT SESSION) - concurrency metrics unavailable');
    BEGIN TRY
        SELECT @xml = CAST(t.target_data AS xml)
          FROM sys.dm_xe_sessions s
          JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
         WHERE s.name = N'bench_concurrency' AND t.target_name = N'ring_buffer';

        IF @xml IS NOT NULL
        BEGIN
            ;WITH ev AS (
                SELECT n.value('@name','sysname') AS ename,
                       n.value('(data[@name="database_id"]/value)[1]','int') AS dbid
                FROM @xml.nodes('//RingBufferTarget/event') AS x(n))
            SELECT @dead = SUM(CASE WHEN ename='xml_deadlock_report' THEN 1 ELSE 0 END),
                   @escT = SUM(CASE WHEN ename='lock_escalation' THEN 1 ELSE 0 END),
                   @escS = SUM(CASE WHEN ename='lock_escalation' AND dbid=@srcId THEN 1 ELSE 0 END),
                   @sortw= SUM(CASE WHEN ename='sort_warning' THEN 1 ELSE 0 END),
                   @hashw= SUM(CASE WHEN ename='hash_warning' THEN 1 ELSE 0 END)
            FROM ev;
        END
    END TRY BEGIN CATCH SET @runErr = CONCAT(ISNULL(@runErr+N' | ',N''), N'XE parse: ', ERROR_MESSAGE()); END CATCH;
    BEGIN TRY ALTER EVENT SESSION [bench_concurrency] ON SERVER STATE = STOP; END TRY BEGIN CATCH END CATCH;

    -- ---- post-snapshot -----------------------------------------------------
    DECLARE @cpu1 bigint, @lreads1 bigint, @preads1 bigint, @writes1 bigint;
    SELECT @cpu1 = ISNULL(SUM(cpu_time),0), @lreads1 = ISNULL(SUM(logical_reads),0),
           @preads1 = ISNULL(SUM(reads),0), @writes1 = ISNULL(SUM(writes),0)
      FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    DECLARE @tdbUser1 bigint, @tdbInt1 bigint;
    SELECT @tdbUser1 = ISNULL(SUM(user_objects_alloc_page_count),0),
           @tdbInt1  = ISNULL(SUM(internal_objects_alloc_page_count),0)
      FROM sys.dm_db_task_space_usage WHERE session_id = @@SPID;

    DECLARE @lck1 bigint = (SELECT ISNULL(SUM(wait_time_ms),0) FROM sys.dm_os_wait_stats WHERE wait_type LIKE 'LCK[_]M[_]%');
    DECLARE @srcLog1 bigint = (SELECT TOP(1) cntr_value FROM sys.dm_os_performance_counters
                               WHERE counter_name = N'Log Bytes Flushed/sec' AND RTRIM(instance_name) = @SourceDb);
    DECLARE @arcLog1 bigint = (SELECT TOP(1) cntr_value FROM sys.dm_os_performance_counters
                               WHERE counter_name = N'Log Bytes Flushed/sec' AND RTRIM(instance_name) = @ArchiveDb);

    -- ---- product telemetry for the runs created in this window -------------
    DECLARE @arch bigint=0, @del bigint=0, @m1a bigint=0, @m1d bigint=0, @bad int=0, @hadM1 bit=0, @runIdTo bigint;
    SELECT @runIdTo = ISNULL(MAX(RunId), @runId0) FROM arch.Run;
    SELECT @arch = ISNULL(SUM(ri.RowsArchived),0),
           @del  = ISNULL(SUM(ri.RowsDeleted),0),
           @m1a  = ISNULL(SUM(CASE WHEN ri.Mode=1 THEN ri.RowsArchived END),0),
           @m1d  = ISNULL(SUM(CASE WHEN ri.Mode=1 THEN ri.RowsDeleted END),0),
           @hadM1= ISNULL(CONVERT(bit, MAX(CASE WHEN ri.Mode=1 THEN 1 ELSE 0 END)),0),
           @bad  = ISNULL(SUM(CASE WHEN ri.Status NOT IN (N'OK',N'DRYRUN',N'SKIPPED',N'NOOP') THEN 1 ELSE 0 END),0)
      FROM arch.RunItem ri
      JOIN arch.Run r ON r.RunId = ri.RunId
     WHERE ri.RunId > @runId0;

    DECLARE @durMs bigint = DATEDIFF_BIG(MILLISECOND, @t0, @t1);
    DECLARE @rps decimal(18,1) = CASE WHEN @durMs > 0 THEN (@del + @arch) * 1000.0 / @durMs END;

    -- ---- persist -----------------------------------------------------------
    INSERT INTO bench.Run
        (Label, ScaleLabel, Strategy, CheapMode, ProcessCode, SourceDb, ArchiveDb, DryRun, MaxCandidates,
         StartedAtUtc, EndedAtUtc, DurationMs, KArchiveRunIdFrom, KArchiveRunIdTo,
         RowsArchived, RowsDeleted, Mode1Archived, Mode1Deleted, Mode1Divergence, HadMode1, RowsPerSec, BadRunItems,
         CpuMs, LogicalReads, PhysicalReads, Writes, TempdbAllocKB, LockWaitMs,
         SourceLogBytes, ArchiveLogBytes, SourceLogFreeBytesAtStart, ArchiveLogFreeBytesAtStart,
         SourceRecovery, ArchiveRecovery,
         Deadlocks, LockEscalationsTotal, LockEscalationsSource, SortWarnings, HashWarnings, Notes)
    VALUES
        (@Label, @ScaleLabel, @Strategy, @CheapMode, @ProcessCode, @SourceDb, @ArchiveDb, @DryRun, @MaxCandidates,
         @t0, @t1, @durMs, CASE WHEN @runIdTo>@runId0 THEN @runId0+1 END, NULLIF(@runIdTo,@runId0),
         @arch, @del, @m1a, @m1d, @m1a-@m1d, @hadM1, @rps, @bad,
         @cpu1-@cpu0, @lreads1-@lreads0, @preads1-@preads0, @writes1-@writes0,
         (@tdbUser1-@tdbUser0 + @tdbInt1-@tdbInt0)*8, @lck1-@lck0,
         CASE WHEN @DryRun=1 THEN NULL WHEN @srcLog1>=@srcLog0 THEN @srcLog1-@srcLog0 END,
         CASE WHEN @DryRun=1 THEN NULL WHEN @arcLog1>=@arcLog0 THEN @arcLog1-@arcLog0 END,
         @srcFree, @arcFree,
         @srcRecovery, @arcRecovery,
         @dead, @escT, @escS, @sortw, @hashw, @runErr);

    DECLARE @id bigint = SCOPE_IDENTITY();
    EXEC bench.usp_EvaluateAcceptance @BenchRunId = @id;

    -- ---- return the result row + per-criterion verdict ---------------------
    SELECT * FROM bench.Run WHERE BenchRunId = @id;
END
GO

/* ============================================================================
 * bench.vw_BenchmarkReport — compact, human-readable view of all runs
 * ============================================================================ */
CREATE OR ALTER VIEW bench.vw_BenchmarkReport
AS
SELECT
    BenchRunId, Verdict, Label, ScaleLabel, Strategy, ProcessCode, SourceDb, DryRun,
    SourceRecovery, ArchiveRecovery,
    DurationSec   = CAST(DurationMs/1000.0 AS decimal(10,1)),
    RowsArchived, RowsDeleted, Mode1Divergence,
    RowsPerSec,
    CpuSec        = CAST(CpuMs/1000.0 AS decimal(10,1)),
    LogicalReads, PhysicalReads, Writes,
    TempdbMB      = CAST(TempdbAllocKB/1024.0 AS decimal(12,1)),
    SourceLogMB   = CAST(SourceLogBytes/1048576.0 AS decimal(12,1)),
    ArchiveLogMB  = CAST(ArchiveLogBytes/1048576.0 AS decimal(12,1)),
    SrcLogFreeMB  = CAST(SourceLogFreeBytesAtStart/1048576.0 AS decimal(12,1)),
    LockWaitMs, Deadlocks, LockEscalationsSource, SortWarnings, HashWarnings,
    BadRunItems, FailReasons, CreatedAtUtc
FROM bench.Run;
GO

CREATE OR ALTER PROCEDURE bench.usp_BenchmarkReport @Top int = 50
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP(@Top) * FROM bench.vw_BenchmarkReport ORDER BY BenchRunId DESC;
END
GO

PRINT N'R-03 benchmark harness installed: schema [bench], XE [bench_concurrency], procs usp_RunBenchmark / usp_EvaluateAcceptance / usp_BenchmarkReport.';
GO
