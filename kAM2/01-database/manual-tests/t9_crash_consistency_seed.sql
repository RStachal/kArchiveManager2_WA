/* TEST 11 seed — 200k RF_LOG2, small batches + delay so the run can be killed mid-flight. */
SET NOCOUNT ON; SET XACT_ABORT ON;
USE [kArchiveManagerAdmin];
EXEC('USE [kArchiveManagerBackups]; TRUNCATE TABLE [KMWEBV].[RF_LOG2];');
TRUNCATE TABLE KMWEBV.dbo.RF_LOG2;
;WITH n AS (SELECT TOP (500000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM sys.all_columns a CROSS JOIN sys.all_columns b)
INSERT KMWEBV.dbo.RF_LOG2 (ROWID, DATE_TIME, USERID, [ACTION], QUANTITY, PACKSLIP)
SELECT NEWID(), CONVERT(nvarchar(46), DATEADD(SECOND,(rn-1)*30,'2023-01-01'),121), N'BENCH','PICK',1,CONCAT(N'PS',rn) FROM n;
UPDATE pd SET pd.Mode=1, pd.AuditLevel='NONE', pd.BatchRowCount=2000, pd.MaxBatchesPerRun=300,
              pd.DelayMsBetweenBatches=200, pd.CutoffMode=0, pd.RetentionDays=540
FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId
WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
DECLARE @s bigint=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.RF_LOG2);
PRINT CONCAT('TEST11 seed done: source=',@s,' archive=0');
