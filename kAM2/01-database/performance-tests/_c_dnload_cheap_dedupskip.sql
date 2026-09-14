/* DNLOAD cheap-mode (no per-row AT TIME ZONE; OrderSql=clustered ROWID) + validate the 027 dedup-skip
   (unique key ROWID -> no candidate window sort -> lowest tempdb). RF_LOG2 + DNLOAD are both ROWID-PK. */
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
USE [kArchiveManagerAdmin];

-- DNLOAD cheap-mode: local projection of COALESCE(date_archived, parsed TIMESTMP), NO AT TIME ZONE.
UPDATE os SET os.CandidateSelectExpr =
  N'CAST(COALESCE(CONVERT(datetime2(3), t.date_archived), TRY_CONVERT(datetime2(3), STUFF(STUFF(STUFF(REPLACE(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(25), t.TIMESTMP))), N''''), N''/'', N''.''), 9, 0, N''T''), 7, 0, N''-''), 5, 0, N''-''), 126)) AS datetime2(0))',
  os.ModifiedAt = SYSUTCDATETIME()
FROM arch.ObjectSpec os JOIN arch.Process p ON p.ProcessId = os.ProcessId
WHERE p.ProcessCode = N'INTEGRACE_DNLOAD';

UPDATE arch.Process
   SET CandidateWhereSql =
       N'CAST(COALESCE(CONVERT(datetime2(3), t.date_archived), TRY_CONVERT(datetime2(3), STUFF(STUFF(STUFF(REPLACE(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(25), t.TIMESTMP))), N''''), N''/'', N''.''), 9, 0, N''T''), 7, 0, N''-''), 5, 0, N''-''), 126)) AS datetime2(0)) < CAST(@CutoffUtc AT TIME ZONE N''UTC'' AT TIME ZONE N''Central European Standard Time'' AS datetime2(0))',
       CandidateOrderSql = N't.ROWID', ModifiedAt = SYSUTCDATETIME()
WHERE ProcessCode = N'INTEGRACE_DNLOAD';

DECLARE @sb bigint = (SELECT ISNULL(MAX(BenchRunId),0) FROM bench.Run);
-- RF_LOG2 (cheap + dedup-skip): expect tempdb FAR below the classic ~4GB@3M
EXEC bench.usp_RunBenchmark @ProcessCode=N'RF_LOG2', @SourceDb=N'KMWEBV', @ArchiveDb=N'kArchiveManagerBackups',
     @Label=N'RF_LOG2@KMWEBV cheap+nodupsort', @ScaleLabel=N'opt', @Strategy=N'TIMESTAMP', @MaxCandidates=200000, @StopMinutes=30, @DryRun=0;
-- DNLOAD (cheap + dedup-skip)
EXEC bench.usp_RunBenchmark @ProcessCode=N'INTEGRACE_DNLOAD', @SourceDb=N'KMWE_Test', @ArchiveDb=N'kArchiveManagerBackups',
     @Label=N'DNLOAD@KMWE_Test cheap+nodupsort', @ScaleLabel=N'opt', @Strategy=N'TIMESTAMP', @MaxCandidates=200000, @StopMinutes=30, @DryRun=0;

PRINT '=== cheap + dedup-skip results (expect Div=0, LockEscSrc=0, SortWarnings=0, LOW tempdb) ===';
SELECT BenchRunId, Verdict, Label, RowsDeleted, Div=Mode1Divergence, DurationSec, RealDelPerSec=CAST(RowsDeleted/NULLIF(DurationSec,0) AS int),
       TempdbMB, SortWarnings, LockEscSrc=LockEscalationsSource, Deadlocks, FailReasons
FROM bench.vw_BenchmarkReport WHERE BenchRunId > @sb ORDER BY BenchRunId;
