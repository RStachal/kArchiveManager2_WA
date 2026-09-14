/* FULL ANCHOR RUN — RECEIVING + SHIPPING ~1M each, Mode 1 + ROW audit. */
SET NOCOUNT ON; SET XACT_ABORT ON;
USE [kArchiveManagerAdmin];
PRINT CONCAT('ANCHOR RUN start ', CONVERT(varchar(19),SYSUTCDATETIME(),120));

EXEC bench.usp_RunBenchmark @ProcessCode=N'RECEIVING', @SourceDb=N'KMWEBV', @ArchiveDb=N'kArchiveManagerBackups',
     @Label=N'RECEIVING@KMWEBV ~1M ANCHOR+ROWaudit', @ScaleLabel=N'1M', @Strategy=N'ANCHOR',
     @MaxCandidates=60000, @StopMinutes=60, @DryRun=0;

EXEC bench.usp_RunBenchmark @ProcessCode=N'SHIPPING', @SourceDb=N'KMWEBV', @ArchiveDb=N'kArchiveManagerBackups',
     @Label=N'SHIPPING@KMWEBV 1M ANCHOR+ROWaudit', @ScaleLabel=N'1M', @Strategy=N'ANCHOR',
     @MaxCandidates=100000, @StopMinutes=60, @DryRun=0;

PRINT CONCAT('ANCHOR RUN end ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
