/* FULL MEASURED RUN — 3 TIMESTAMP mappings @ ~1M, Mode 1 + ROW audit, cheap-mode. */
SET NOCOUNT ON; SET XACT_ABORT ON;
USE [kArchiveManagerAdmin];
PRINT CONCAT('FULL RUN start ', CONVERT(varchar(19),SYSUTCDATETIME(),120));

EXEC bench.usp_RunBenchmark @ProcessCode=N'RF_LOG2', @SourceDb=N'KMWEBV', @ArchiveDb=N'kArchiveManagerBackups',
     @Label=N'RF_LOG2@KMWEBV 1M cheap+ROWaudit', @ScaleLabel=N'1M', @Strategy=N'TIMESTAMP', @CheapMode=1,
     @MaxCandidates=1000000, @StopMinutes=60, @DryRun=0;

EXEC bench.usp_RunBenchmark @ProcessCode=N'INTEGRACE_DNLOAD', @SourceDb=N'KMWEBV', @ArchiveDb=N'kArchiveManagerBackups',
     @Label=N'DNLOAD@KMWEBV 1M cheap+ROWaudit', @ScaleLabel=N'1M', @Strategy=N'TIMESTAMP', @CheapMode=1,
     @MaxCandidates=1000000, @StopMinutes=60, @DryRun=0;

EXEC bench.usp_RunBenchmark @ProcessCode=N'INTEGRACE_UPLOAD', @SourceDb=N'KMWEBV', @ArchiveDb=N'kArchiveManagerBackups',
     @Label=N'UPLOAD@KMWEBV 1M cheap+ROWaudit', @ScaleLabel=N'1M', @Strategy=N'TIMESTAMP', @CheapMode=1,
     @MaxCandidates=1000000, @StopMinutes=60, @DryRun=0;

PRINT CONCAT('FULL RUN end ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
