/* R-03 FULL MEASURED RUN + source/target reconciliation (clean deploy, archive starts EMPTY).
   Runs every enabled Mode=1 mapping through bench.usp_RunBenchmark (full metrics + ROW audit),
   caps: Edge.RF_LOG2=1,000,000; other RF_LOG2 / INTEGRACE_DNLOAD=200,000; small ones drain fully.
   Then validates SOURCE (pre-post == deleted == archived) and TARGET (archive total == deleted total). */
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET ANSI_WARNINGS ON;
USE [kArchiveManagerAdmin];

DECLARE @start datetime2(0) = SYSUTCDATETIME();
DECLARE @startRI bigint    = (SELECT ISNULL(MAX(RunItemId),0) FROM arch.RunItem);
DECLARE @startBench bigint = (SELECT ISNULL(MAX(BenchRunId),0) FROM bench.Run);
PRINT CONCAT('MEASURED RUN start UTC=', CONVERT(varchar(19),@start,120));

CREATE TABLE #pre (SourceDb sysname, Tbl sysname, PreRows bigint);
INSERT #pre VALUES
 ('Edge',N'RF_LOG2',          (SELECT COUNT_BIG(*) FROM Edge.dbo.RF_LOG2)),
 ('KMWEBV',N'RF_LOG2',        (SELECT COUNT_BIG(*) FROM KMWEBV.dbo.RF_LOG2)),
 ('KMWE_Test',N'RF_LOG2',     (SELECT COUNT_BIG(*) FROM KMWE_Test.dbo.RF_LOG2)),
 ('KMWE_Test',N'DNLOAD_ARCHIVE',(SELECT COUNT_BIG(*) FROM KMWE_Test.dbo.DNLOAD_ARCHIVE)),
 ('KMWEBV',N'DNLOAD_ARCHIVE',   (SELECT COUNT_BIG(*) FROM KMWEBV.dbo.DNLOAD_ARCHIVE));

DECLARE @pc sysname,@sdb sysname,@adb sysname,@mc int,@scale nvarchar(40),@lbl nvarchar(200);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
  SELECT e.ProcessCode,e.SourceDb,e.ArchiveDb FROM arch.v_ProcessDatabaseEffective e WHERE e.IsEnabled=1
  ORDER BY e.RunOrder,e.SourceDb,e.ProcessCode;
OPEN c; FETCH NEXT FROM c INTO @pc,@sdb,@adb;
WHILE @@FETCH_STATUS=0
BEGIN
  SET @mc = CASE WHEN @pc=N'RF_LOG2' AND @sdb=N'Edge' THEN 1000000
                 WHEN @pc=N'RF_LOG2' THEN 200000
                 WHEN @pc=N'INTEGRACE_DNLOAD' THEN 200000
                 ELSE 1000000 END;
  SET @scale = CASE WHEN @pc=N'RF_LOG2' AND @sdb=N'Edge' THEN N'large-1M' ELSE N'std' END;
  SET @lbl = CONCAT(@pc,N'@',@sdb);
  BEGIN TRY
    EXEC bench.usp_RunBenchmark @ProcessCode=@pc, @SourceDb=@sdb, @ArchiveDb=@adb,
         @Label=@lbl, @ScaleLabel=@scale, @MaxCandidates=@mc, @StopMinutes=180, @DryRun=0;
  END TRY BEGIN CATCH PRINT CONCAT('ERROR ',@pc,'/',@sdb,': ',ERROR_MESSAGE()); END CATCH
  FETCH NEXT FROM c INTO @pc,@sdb,@adb;
END
CLOSE c; DEALLOCATE c;

PRINT '=== PER MAPPING (Mode=1, AUDIT=ROW): rows / divergence / duration / rate / audit ===';
;WITH ri AS (
  SELECT r.SourceDb,p.ProcessCode,ri.RunItemId,ri.Status,
   CAST(ri.RowsArchived AS bigint) Arch, CAST(ri.RowsDeleted AS bigint) Del,
   Dur=DATEDIFF(SECOND,r.StartedAt,r.EndedAt),
   Aud=(SELECT COUNT_BIG(*) FROM arch.RunDocAudit a WHERE a.RunItemId=ri.RunItemId)
  FROM arch.RunItem ri JOIN arch.Run r ON r.RunId=ri.RunId JOIN arch.Process p ON p.ProcessId=ri.ProcessId
  WHERE ri.RunItemId>@startRI)
SELECT SourceDb,ProcessCode,Status=MAX(Status),RowsArchived=SUM(Arch),RowsDeleted=SUM(Del),
   Divergence=SUM(Arch)-SUM(Del),DurationSec=SUM(Dur),DurationMin=CAST(SUM(Dur)/60.0 AS decimal(6,1)),
   RowsPerSec=CASE WHEN SUM(Dur)>0 THEN SUM(Del)/SUM(Dur) END, AuditRows=SUM(Aud)
FROM ri GROUP BY SourceDb,ProcessCode ORDER BY SUM(Del) DESC;

PRINT '=== TOTALS ===';
SELECT TotalArchived=SUM(CAST(RowsArchived AS bigint)),TotalDeleted=SUM(CAST(RowsDeleted AS bigint)),
  GlobalDivergence=SUM(CAST(RowsArchived AS bigint))-SUM(CAST(RowsDeleted AS bigint)),
  DivergentMode1=SUM(CASE WHEN Mode=1 AND Status='OK' AND RowsArchived<>RowsDeleted THEN 1 ELSE 0 END),
  BadRuns=SUM(CASE WHEN Status NOT IN('OK','SKIPPED','NOOP','DRYRUN') THEN 1 ELSE 0 END),
  TotalAuditRows=(SELECT COUNT_BIG(*) FROM arch.RunDocAudit a JOIN arch.RunItem r2 ON r2.RunItemId=a.RunItemId WHERE r2.RunItemId>@startRI),
  SweepMinutes=DATEDIFF(MINUTE,@start,SYSUTCDATETIME())
FROM arch.RunItem WHERE RunItemId>@startRI;

PRINT '=== SOURCE reconciliation (PreRows - PostRows == DeletedReported == ArchivedActual) ===';
SELECT pre.SourceDb, pre.Tbl, pre.PreRows,
  PostRows = CASE
     WHEN pre.SourceDb='Edge' AND pre.Tbl='RF_LOG2' THEN (SELECT COUNT_BIG(*) FROM Edge.dbo.RF_LOG2)
     WHEN pre.SourceDb='KMWEBV' AND pre.Tbl='RF_LOG2' THEN (SELECT COUNT_BIG(*) FROM KMWEBV.dbo.RF_LOG2)
     WHEN pre.SourceDb='KMWE_Test' AND pre.Tbl='RF_LOG2' THEN (SELECT COUNT_BIG(*) FROM KMWE_Test.dbo.RF_LOG2)
     WHEN pre.SourceDb='KMWE_Test' AND pre.Tbl='DNLOAD_ARCHIVE' THEN (SELECT COUNT_BIG(*) FROM KMWE_Test.dbo.DNLOAD_ARCHIVE)
     WHEN pre.SourceDb='KMWEBV' AND pre.Tbl='DNLOAD_ARCHIVE' THEN (SELECT COUNT_BIG(*) FROM KMWEBV.dbo.DNLOAD_ARCHIVE) END,
  DeletedReported = (SELECT ISNULL(SUM(CAST(rio.RowsDeleted AS bigint)),0) FROM arch.RunItemObject rio
      JOIN arch.RunItem ri ON ri.RunItemId=rio.RunItemId JOIN arch.Run r ON r.RunId=ri.RunId
      WHERE ri.RunItemId>@startRI AND r.SourceDb=pre.SourceDb AND rio.SourceTable=pre.Tbl),
  ArchivedActual = (SELECT ISNULL(SUM(p2.rows),0) FROM kArchiveManagerBackups.sys.partitions p2
      WHERE p2.index_id IN(0,1) AND p2.object_id=OBJECT_ID('kArchiveManagerBackups.'+QUOTENAME(pre.SourceDb)+'.'+QUOTENAME(pre.Tbl)))
FROM #pre pre ORDER BY pre.PreRows DESC;

PRINT '=== TARGET cross-check: total archive rows == total deleted (archive started EMPTY) ===';
SELECT ArchiveTotalRows=(SELECT ISNULL(SUM(p.rows),0) FROM kArchiveManagerBackups.sys.partitions p
        JOIN kArchiveManagerBackups.sys.tables t ON t.object_id=p.object_id WHERE p.index_id IN(0,1)),
   TotalDeletedThisSweep=(SELECT SUM(CAST(RowsDeleted AS bigint)) FROM arch.RunItem WHERE RunItemId>@startRI);

PRINT '=== BENCHMARK METRICS (R-03) per mapping ===';
SELECT BenchRunId, Verdict, Label, ScaleLabel, DurationSec, RowsArchived, RowsDeleted, Mode1Divergence,
       RowsPerSec, CpuSec, LogicalReads, PhysicalReads, Writes, TempdbMB, SourceLogMB, ArchiveLogMB,
       Deadlocks, LockEscalationsSource, SortWarnings, FailReasons
FROM bench.vw_BenchmarkReport WHERE BenchRunId > @startBench ORDER BY BenchRunId;

PRINT CONCAT('MEASURED RUN end UTC=', CONVERT(varchar(19),SYSUTCDATETIME(),120));
