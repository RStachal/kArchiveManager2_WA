/* PERFORMANCE TEST — Edge.RF_LOG2 only, 5,000,000 rows, NO auditing, PRODUCTION-SAFE.
   Constraints (customer production source): MUST NOT lock the source (no lock escalation),
   NO source indexes, NO source schema changes. Lock-safety here comes purely from a small
   delete batch (4000 rows < the ~5000-lock escalation threshold for this table) — proven 0
   escalations earlier — so nothing on the source is touched.
   Compares against the historical ~30 min / 5M baseline (which used 50K batches = escalation). */
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
USE [kArchiveManagerAdmin];

PRINT '=== config: RF_LOG2 -> AuditLevel=NONE, 4000-row lock-safe batches, MaxBatches=1500 (>=5M) ===';
UPDATE arch.Process
   SET AuditLevel = N'NONE', BatchRowCount = 4000, MaxRowsPerTransaction = 4000,
       MaxBatchesPerRun = 1500, ModifiedAt = SYSUTCDATETIME()
WHERE ProcessCode = N'RF_LOG2';

DECLARE @startBench bigint = (SELECT ISNULL(MAX(BenchRunId),0) FROM bench.Run);
DECLARE @preEdge bigint    = (SELECT COUNT_BIG(*) FROM Edge.dbo.RF_LOG2);
PRINT CONCAT('Edge.RF_LOG2 pre-rows = ', @preEdge, '  start UTC=', CONVERT(varchar(19),SYSUTCDATETIME(),120));

EXEC bench.usp_RunBenchmark @ProcessCode=N'RF_LOG2', @SourceDb=N'Edge', @ArchiveDb=N'kArchiveManagerBackups',
     @Label=N'RF_LOG2@Edge 5M no-audit lock-safe', @ScaleLabel=N'5M-noaudit', @Strategy=N'TIMESTAMP',
     @CheapMode=0, @MaxCandidates=5000000, @StopMinutes=90, @DryRun=0;

PRINT '=== source reconciliation ===';
SELECT PreRows=@preEdge, PostRows=(SELECT COUNT_BIG(*) FROM Edge.dbo.RF_LOG2),
       Deleted=@preEdge-(SELECT COUNT_BIG(*) FROM Edge.dbo.RF_LOG2);

PRINT '=== PERFORMANCE + LOCKING metrics (the critical bits: LockEscSrc=0, Deadlocks=0, low LockWaitMs) ===';
SELECT BenchRunId, Verdict, RowsDeleted, Div=Mode1Divergence,
       DurationMin=CAST(DurationSec/60.0 AS decimal(6,1)), RowsPerSec,
       LockEscSrc=LockEscalationsSource, Deadlocks, LockWaitMs,
       CpuSec, LogicalReads, TempdbMB, SourceLogMB, ArchiveLogMB, FailReasons
FROM bench.vw_BenchmarkReport WHERE BenchRunId > @startBench;
PRINT CONCAT('end UTC=', CONVERT(varchar(19),SYSUTCDATETIME(),120));
