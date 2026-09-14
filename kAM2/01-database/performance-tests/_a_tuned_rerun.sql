/* (a) Close finding #1 (source lock escalation): lower the TIMESTAMP delete batch below the
   ~5000-lock escalation threshold, then re-run the mappings that escalated and prove 0 escalations.
   Trade-off measured too: smaller batches avoid escalation at some throughput cost. */
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
USE [kArchiveManagerAdmin];

PRINT '=== tune RF_LOG2 + INTEGRACE_DNLOAD to 4000-row batches (< 5000 escalation threshold) ===';
UPDATE arch.Process
   SET BatchRowCount = 4000, MaxRowsPerTransaction = 4000, MaxBatchesPerRun = 100, ModifiedAt = SYSUTCDATETIME()
WHERE ProcessCode IN (N'RF_LOG2', N'INTEGRACE_DNLOAD');

DECLARE @startBench bigint = (SELECT ISNULL(MAX(BenchRunId),0) FROM bench.Run);
DECLARE @adb sysname = N'kArchiveManagerBackups';

EXEC bench.usp_RunBenchmark @ProcessCode=N'RF_LOG2', @SourceDb=N'Edge', @ArchiveDb=@adb,
     @Label=N'RF_LOG2@Edge tuned-4k', @ScaleLabel=N'tuned-4k', @Strategy=N'TIMESTAMP', @MaxCandidates=200000, @StopMinutes=60, @DryRun=0;
EXEC bench.usp_RunBenchmark @ProcessCode=N'RF_LOG2', @SourceDb=N'KMWEBV', @ArchiveDb=@adb,
     @Label=N'RF_LOG2@KMWEBV tuned-4k', @ScaleLabel=N'tuned-4k', @Strategy=N'TIMESTAMP', @MaxCandidates=200000, @StopMinutes=60, @DryRun=0;
EXEC bench.usp_RunBenchmark @ProcessCode=N'RF_LOG2', @SourceDb=N'KMWE_Test', @ArchiveDb=@adb,
     @Label=N'RF_LOG2@KMWE_Test tuned-4k', @ScaleLabel=N'tuned-4k', @Strategy=N'TIMESTAMP', @MaxCandidates=200000, @StopMinutes=60, @DryRun=0;
EXEC bench.usp_RunBenchmark @ProcessCode=N'INTEGRACE_DNLOAD', @SourceDb=N'KMWEBV', @ArchiveDb=@adb,
     @Label=N'DNLOAD@KMWEBV tuned-4k', @ScaleLabel=N'tuned-4k', @Strategy=N'TIMESTAMP', @MaxCandidates=200000, @StopMinutes=60, @DryRun=0;
EXEC bench.usp_RunBenchmark @ProcessCode=N'INTEGRACE_DNLOAD', @SourceDb=N'KMWE_Test', @ArchiveDb=@adb,
     @Label=N'DNLOAD@KMWE_Test tuned-4k', @ScaleLabel=N'tuned-4k', @Strategy=N'TIMESTAMP', @MaxCandidates=200000, @StopMinutes=60, @DryRun=0;

PRINT '=== TUNED re-run verdicts (expect 0 escalations, Divergence=0) ===';
SELECT BenchRunId, Verdict, Label, RowsDeleted, Div=Mode1Divergence, RowsPerSec,
       LockEscSrc=LockEscalationsSource, Deadlocks, ArchiveLogMB, FailReasons
FROM bench.vw_BenchmarkReport WHERE BenchRunId > @startBench ORDER BY BenchRunId;
