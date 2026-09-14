/* Phase 2: cheap-mode for RF_LOG2 (config only, NO source index).
   - CandidateSelectExpr (ObjectSpec): cheap LOCAL projection, NO per-row AT TIME ZONE.
   - CandidateWhereSql (Process): cutoff converted UTC->local ONCE; compares the cheap-cast column (no per-row TZ).
   - CandidateOrderSql (Process): the CLUSTERED key ROWID -> index-ordered scan, NO tempdb sort.
   Lock-safety unchanged (NOLOCK selection + small delete batches). */
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
USE [kArchiveManagerAdmin];

UPDATE os SET os.CandidateSelectExpr = N'CAST(t.DATE_TIME AS datetime2(0))', os.ModifiedAt = SYSUTCDATETIME()
FROM arch.ObjectSpec os JOIN arch.Process p ON p.ProcessId = os.ProcessId
WHERE p.ProcessCode = N'RF_LOG2';

UPDATE arch.Process
   SET CandidateWhereSql = N'CAST(t.DATE_TIME AS datetime2(0)) < CAST(@CutoffUtc AT TIME ZONE N''UTC'' AT TIME ZONE N''Central European Standard Time'' AS datetime2(0))',
       CandidateOrderSql = N't.ROWID',
       ModifiedAt = SYSUTCDATETIME()
WHERE ProcessCode = N'RF_LOG2';

DECLARE @startBench bigint = (SELECT ISNULL(MAX(BenchRunId),0) FROM bench.Run);
EXEC bench.usp_RunBenchmark @ProcessCode=N'RF_LOG2', @SourceDb=N'Edge', @ArchiveDb=N'kArchiveManagerBackups',
     @Label=N'RF_LOG2@Edge cheap 100k', @ScaleLabel=N'cheap-100k', @Strategy=N'TIMESTAMP', @CheapMode=1,
     @MaxCandidates=100000, @StopMinutes=20, @DryRun=0;

PRINT '=== cheap-mode 100k validation (expect Div=0, LockEscSrc=0, low tempdb vs classic 7GB@5M) ===';
SELECT BenchRunId, Verdict, RowsDeleted, Div=Mode1Divergence, DurationSec, RowsPerSec,
       LockEscSrc=LockEscalationsSource, Deadlocks, TempdbMB, SortWarnings=SortWarnings, FailReasons
FROM bench.vw_BenchmarkReport WHERE BenchRunId > @startBench;
