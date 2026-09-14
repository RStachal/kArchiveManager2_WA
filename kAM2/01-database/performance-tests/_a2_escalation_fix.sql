/* (a, definitive) Batch-size alone is table-dependent (multi-index tables still escalate at 4000 rows
   because each deleted row locks every index). The robust fix is to disable lock escalation on the
   archived source tables, so the batched DELETE never escalates to a table-X lock that blocks OLTP. */
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
USE master;
PRINT '=== disable lock escalation on the source tables that still escalated at 4000-row batches ===';
ALTER TABLE KMWEBV.dbo.RF_LOG2        SET (LOCK_ESCALATION = DISABLE);
ALTER TABLE KMWEBV.dbo.DNLOAD_ARCHIVE SET (LOCK_ESCALATION = DISABLE);

USE kArchiveManagerAdmin;
DECLARE @startBench bigint = (SELECT ISNULL(MAX(BenchRunId),0) FROM bench.Run);
DECLARE @adb sysname = N'kArchiveManagerBackups';
EXEC bench.usp_RunBenchmark @ProcessCode=N'RF_LOG2', @SourceDb=N'KMWEBV', @ArchiveDb=@adb,
     @Label=N'RF_LOG2@KMWEBV noEsc', @ScaleLabel=N'noesc', @Strategy=N'TIMESTAMP', @MaxCandidates=200000, @StopMinutes=60, @DryRun=0;
EXEC bench.usp_RunBenchmark @ProcessCode=N'INTEGRACE_DNLOAD', @SourceDb=N'KMWEBV', @ArchiveDb=@adb,
     @Label=N'DNLOAD@KMWEBV noEsc', @ScaleLabel=N'noesc', @Strategy=N'TIMESTAMP', @MaxCandidates=200000, @StopMinutes=60, @DryRun=0;

PRINT '=== verdicts after LOCK_ESCALATION=DISABLE (expect LockEscSrc=0) ===';
SELECT BenchRunId, Verdict, Label, RowsDeleted, Div=Mode1Divergence, RowsPerSec,
       LockEscSrc=LockEscalationsSource, Deadlocks, FailReasons
FROM bench.vw_BenchmarkReport WHERE BenchRunId > @startBench ORDER BY BenchRunId;
