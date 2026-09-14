/* TEST 7 — DST summer cutoff. Fixed CutoffDate 2024-07-01 00:00 UTC -> CEST (UTC+2) = 02:00 local.
   Expect markers < 02:00 local archived, >= 02:00 survive (vs +1h in winter, Test 4). */
SET NOCOUNT ON; SET XACT_ABORT ON;
USE [kArchiveManagerAdmin];
PRINT CONCAT('TEST7 start ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
UPDATE pd SET pd.CutoffMode=1, pd.CutoffDate='2024-07-01 00:00:00', pd.AuditLevel='NONE'
FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId
WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
TRUNCATE TABLE KMWEBV.dbo.RF_LOG2;
INSERT KMWEBV.dbo.RF_LOG2 (ROWID, DATE_TIME, USERID, [ACTION], QUANTITY, PACKSLIP) VALUES
 (NEWID(),'2024-06-30 23:00:00','TZ','MARK',1,'S_2024-06-30_23:00:00'),
 (NEWID(),'2024-07-01 00:00:00','TZ','MARK',1,'S_2024-07-01_00:00:00'),
 (NEWID(),'2024-07-01 01:00:00','TZ','MARK',1,'S_2024-07-01_01:00:00'),
 (NEWID(),'2024-07-01 01:59:59','TZ','MARK',1,'S_2024-07-01_01:59:59'),
 (NEWID(),'2024-07-01 02:00:00','TZ','MARK',1,'S_2024-07-01_02:00:00'),
 (NEWID(),'2024-07-01 02:00:01','TZ','MARK',1,'S_2024-07-01_02:00:01'),
 (NEWID(),'2024-07-01 03:00:00','TZ','MARK',1,'S_2024-07-01_03:00:00'),
 (NEWID(),'2024-07-02 00:00:00','TZ','MARK',1,'S_2024-07-02_00:00:00');
EXEC bench.usp_RunBenchmark @ProcessCode='RF_LOG2',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@Label='DST summer cutoff markers',@ScaleLabel='dst',@Strategy='TIMESTAMP',@CheapMode=1,@MaxCandidates=1000,@StopMinutes=10,@DryRun=0;
/* restore rolling cutoff */
UPDATE pd SET pd.CutoffMode=0, pd.CutoffDate=NULL, pd.AuditLevel='ROW'
FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId
WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
PRINT CONCAT('TEST7 end ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
