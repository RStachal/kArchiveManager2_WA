/* TEST 6 prep — seed RECEIVING (ANCHOR): 20k BACKRH headers (PO_NUM) + 380k BACKRD details
   (19/header, same PO_NUM), 2023 dates. Small doc batches + delay so two runs overlap. */
SET NOCOUNT ON; SET XACT_ABORT ON;
USE [kArchiveManagerAdmin];
EXEC('USE [kArchiveManagerBackups]; TRUNCATE TABLE [KMWEBV].[BACKRH]; TRUNCATE TABLE [KMWEBV].[BACKRD];');
TRUNCATE TABLE KMWEBV.dbo.BACKRH;
TRUNCATE TABLE KMWEBV.dbo.BACKRD;
;WITH n AS (SELECT TOP (20000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM sys.all_columns a CROSS JOIN sys.all_columns b)
INSERT KMWEBV.dbo.BACKRH (ROWID, PO_NUM, DATE_CREAT, BILLEDDATE)
SELECT NEWID(), CONCAT(N'PO',rn), DATEADD(SECOND,(rn-1)*60,'2023-01-01'), DATEADD(SECOND,(rn-1)*60,'2023-01-01') FROM n;
DECLARE @done int=0;
WHILE @done < 380000
BEGIN
  ;WITH n AS (SELECT TOP (95000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) + @done AS rn FROM sys.all_columns a CROSS JOIN sys.all_columns b)
  INSERT KMWEBV.dbo.BACKRD (ROWID, PO_NUM, DATE_CREAT, BILLEDDATE, BACKRH_ID)
  SELECT NEWID(), CONCAT(N'PO', ((rn-1)%20000)+1), DATEADD(SECOND,(rn-1)*5,'2023-01-01'), DATEADD(SECOND,(rn-1)*5,'2023-01-01'), NEWID() FROM n;
  SET @done += 95000;
END
UPDATE pd SET pd.Mode=1, pd.AuditLevel='NONE', pd.BatchDocCount=200, pd.MaxBatchesPerRun=150, pd.UseAppLock=1, pd.DelayMsBetweenBatches=20
FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId
WHERE p.ProcessCode='RECEIVING' AND pd.SourceDb='KMWEBV';
DECLARE @h bigint=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.BACKRH), @d bigint=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.BACKRD);
PRINT CONCAT('TEST6 prep done: BACKRH=',@h,' BACKRD=',@d);
