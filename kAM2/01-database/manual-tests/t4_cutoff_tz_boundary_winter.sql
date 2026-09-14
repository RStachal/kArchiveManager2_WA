/* TEST 4 — Cutoff / time-zone boundary precision. Fixed cutoff 2024-01-01 00:00:00.
   The runner treats @CutoffUtc as UTC; cheap-mode compares local DATE_TIME < (cutoff UTC->CEST).
   So the EFFECTIVE local boundary is shifted by the CET offset (+1h in winter). Marker rows
   straddle 2024-01-01 00:00..02:00 local; survivors (still in source) are >= effective cutoff. */
SET NOCOUNT ON; SET XACT_ABORT ON;
USE [kArchiveManagerAdmin];
PRINT CONCAT('TEST4 start ', CONVERT(varchar(19),SYSUTCDATETIME(),120));

UPDATE pd SET pd.CutoffMode=1, pd.CutoffDate='2024-01-01 00:00:00', pd.AuditLevel='NONE'
FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId
WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';

TRUNCATE TABLE KMWEBV.dbo.RF_LOG2;
INSERT KMWEBV.dbo.RF_LOG2 (ROWID, DATE_TIME, USERID, [ACTION], QUANTITY, PACKSLIP) VALUES
 (NEWID(),'2023-12-31 23:00:00','TZ','MARK',1,'TZ_2023-12-31_23:00:00'),
 (NEWID(),'2023-12-31 23:59:59','TZ','MARK',1,'TZ_2023-12-31_23:59:59'),
 (NEWID(),'2024-01-01 00:00:00','TZ','MARK',1,'TZ_2024-01-01_00:00:00'),
 (NEWID(),'2024-01-01 00:30:00','TZ','MARK',1,'TZ_2024-01-01_00:30:00'),
 (NEWID(),'2024-01-01 00:59:59','TZ','MARK',1,'TZ_2024-01-01_00:59:59'),
 (NEWID(),'2024-01-01 01:00:00','TZ','MARK',1,'TZ_2024-01-01_01:00:00'),
 (NEWID(),'2024-01-01 01:00:01','TZ','MARK',1,'TZ_2024-01-01_01:00:01'),
 (NEWID(),'2024-01-01 01:30:00','TZ','MARK',1,'TZ_2024-01-01_01:30:00'),
 (NEWID(),'2024-01-01 02:00:00','TZ','MARK',1,'TZ_2024-01-01_02:00:00'),
 (NEWID(),'2024-01-02 00:00:00','TZ','MARK',1,'TZ_2024-01-02_00:00:00');

EXEC bench.usp_RunBenchmark @ProcessCode='RF_LOG2',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@Label='TZ boundary markers',@ScaleLabel='tz',@Strategy='TIMESTAMP',@CheapMode=1,@MaxCandidates=1000,@StopMinutes=10,@DryRun=0;

/* restore rolling cutoff (CutoffMode=0) + ROW audit */
UPDATE pd SET pd.CutoffMode=0, pd.CutoffDate=NULL, pd.AuditLevel='ROW'
FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId
WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
PRINT CONCAT('TEST4 end ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
