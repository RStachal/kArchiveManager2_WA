/* TEST 3 — Restore round-trip: clean archive, archive 50k (Mode 1), then usp_RestoreFromArchive
   (DryRun=0, PurgeArchive=0) and verify rows return to source + archive copy is kept. pd-level config. */
SET NOCOUNT ON; SET XACT_ABORT ON;
USE [kArchiveManagerBackups];
TRUNCATE TABLE KMWEBV.RF_LOG2;   -- clean archive so the round-trip is unambiguous
GO
USE [kArchiveManagerAdmin];
PRINT CONCAT('TEST3 start ', CONVERT(varchar(19),SYSUTCDATETIME(),120));

TRUNCATE TABLE KMWEBV.dbo.RF_LOG2;
;WITH n AS (SELECT TOP (50000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM sys.all_columns a CROSS JOIN sys.all_columns b)
INSERT KMWEBV.dbo.RF_LOG2 (ROWID, DATE_TIME, USERID, [ACTION], QUANTITY, PACKSLIP)
SELECT NEWID(), CONVERT(nvarchar(46), DATEADD(SECOND,(rn-1)*30,'2023-01-01'),121), N'BENCH','PICK',1,CONCAT(N'PS',rn) FROM n;
UPDATE pd SET pd.Mode=1, pd.AuditLevel='ROW' FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';

/* archive the 50k */
EXEC bench.usp_RunBenchmark @ProcessCode='RF_LOG2',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@Label='RESTORE setup: archive 50k',@ScaleLabel='restore-arch',@CheapMode=1,@MaxCandidates=50000,@StopMinutes=30,@DryRun=0;
DECLARE @srcA bigint=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.RF_LOG2);
DECLARE @arcA bigint=(SELECT COUNT_BIG(*) FROM kArchiveManagerBackups.KMWEBV.RF_LOG2);
PRINT CONCAT('After archive: source=',@srcA,' (expect 0)  archive=',@arcA,' (expect 50000)');

/* restore back into source */
DECLARE @t0 datetime2(3)=SYSUTCDATETIME();
EXEC arch.usp_RestoreFromArchive @ProcessCode='RF_LOG2',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@DryRun=0,@MaxRows=50000,@PurgeArchive=0,@RequestedBy='battery-test';
DECLARE @sec int=DATEDIFF(SECOND,@t0,SYSUTCDATETIME());
DECLARE @srcR bigint=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.RF_LOG2);
DECLARE @arcR bigint=(SELECT COUNT_BIG(*) FROM kArchiveManagerBackups.KMWEBV.RF_LOG2);
DECLARE @rate int=CASE WHEN @sec>0 THEN @srcR/@sec ELSE @srcR END;
PRINT CONCAT('After restore: source=',@srcR,' (expect 50000 restored)  archive=',@arcR,' (expect 50000 kept)  restoreSec=',@sec,'  ~rows/s=',@rate);
PRINT CONCAT('TEST3 end ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
