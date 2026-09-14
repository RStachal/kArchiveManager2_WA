/* ============================================================================
 * R-03 BENCHMARK DRIVER — operator template
 * ----------------------------------------------------------------------------
 * Prereq: run r03_benchmark_harness.sql once to install schema [bench].
 * Run this on an OTHERWISE-IDLE instance (isolation requirement — see the harness
 * header and docs/v2-performance-benchmark.md).
 *
 * Two sections:
 *   A) SINGLE SCENARIO  — edit the variables, run one benchmarked execution.
 *   B) MATRIX SWEEP     — benchmark every enabled mapping at one scale (cap).
 *
 * After running, see the report:  EXEC bench.usp_BenchmarkReport;
 * ============================================================================ */
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
USE [kArchiveManagerAdmin];
GO

/* ===========================================================================
 * A) SINGLE SCENARIO  ── edit these, then run this batch
 * =========================================================================== */
DECLARE @ProcessCode   sysname       = N'RF_LOG2';
DECLARE @SourceDb       sysname       = N'Edge';
DECLARE @ArchiveDb      sysname       = N'kArchiveManagerBackups';
DECLARE @ScaleLabel     nvarchar(40)  = N'large';        -- small | medium | large | prod-rep
DECLARE @Strategy       varchar(10)   = N'TIMESTAMP';    -- operator hint only
DECLARE @CheapMode      bit           = 1;               -- operator hint only
DECLARE @MaxCandidates  int           = 1000000;         -- the scale cap for this run
DECLARE @DryRun         bit           = 0;
DECLARE @Label          nvarchar(200) = CONCAT(@Strategy, N' ', @ProcessCode, N'@', @SourceDb, N' ', @ScaleLabel,
                                               CASE WHEN @CheapMode=1 THEN N' cheap' ELSE N'' END);

EXEC bench.usp_RunBenchmark
     @ProcessCode = @ProcessCode, @SourceDb = @SourceDb, @ArchiveDb = @ArchiveDb,
     @Label = @Label, @ScaleLabel = @ScaleLabel, @Strategy = @Strategy, @CheapMode = @CheapMode,
     @MaxCandidates = @MaxCandidates, @StopMinutes = 180, @DryRun = @DryRun;
GO

/* ===========================================================================
 * B) MATRIX SWEEP  ── benchmark every enabled mapping at one scale cap.
 *    Uncomment to use. Mirrors tools/_retest_sweep.sql, but each mapping is
 *    measured by bench.usp_RunBenchmark. Adjust the per-mapping caps to taste.
 * =========================================================================== */
/*
DECLARE @SweepScale nvarchar(40) = N'medium';
DECLARE @pc sysname, @sdb sysname, @adb sysname, @cap int;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
  SELECT e.ProcessCode, e.SourceDb, e.ArchiveDb
  FROM arch.v_ProcessDatabaseEffective e WHERE e.IsEnabled = 1
  ORDER BY e.RunOrder, e.SourceDb, e.ProcessCode;
OPEN c; FETCH NEXT FROM c INTO @pc, @sdb, @adb;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @cap = CASE WHEN @pc = N'RF_LOG2' AND @sdb = N'Edge' THEN 1000000
                    WHEN @pc IN (N'RF_LOG2', N'INTEGRACE_DNLOAD') THEN 200000
                    ELSE 100000 END;
    EXEC bench.usp_RunBenchmark
         @ProcessCode = @pc, @SourceDb = @sdb, @ArchiveDb = @adb,
         @Label = CONCAT(@pc, N'@', @sdb, N' ', @SweepScale), @ScaleLabel = @SweepScale,
         @MaxCandidates = @cap, @StopMinutes = 120, @DryRun = 0;
    FETCH NEXT FROM c INTO @pc, @sdb, @adb;
END
CLOSE c; DEALLOCATE c;
*/
GO

/* ===========================================================================
 * REPORT
 * =========================================================================== */
EXEC bench.usp_BenchmarkReport @Top = 50;
GO
