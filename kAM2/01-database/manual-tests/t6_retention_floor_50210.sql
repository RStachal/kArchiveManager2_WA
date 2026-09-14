/* TEST 8 — retention-floor gate (50210). Floor=365d + RF_LOG2 rolling RetentionDays=1 => effective
   cutoff = now-1d, which is INSIDE the 365d floor => real run blocked; dry-run exempt. */
SET NOCOUNT ON; SET XACT_ABORT ON;
USE [kArchiveManagerAdmin];
PRINT CONCAT('TEST8 start ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
EXEC arch.usp_Api_SetRetentionFloor @MinRetentionDays=365, @RequestedBy='battery-test';
UPDATE pd SET pd.CutoffMode=0, pd.RetentionDays=1, pd.AuditLevel='NONE'
FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId
WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
TRUNCATE TABLE KMWEBV.dbo.RF_LOG2;
;WITH n AS (SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM sys.all_columns)
INSERT KMWEBV.dbo.RF_LOG2 (ROWID,DATE_TIME,USERID,[ACTION],QUANTITY,PACKSLIP)
SELECT NEWID(),CONVERT(nvarchar(46),DATEADD(SECOND,(rn-1)*30,'2023-01-01'),121),N'BENCH','PICK',1,CONCAT(N'PS',rn) FROM n;

DECLARE @msg nvarchar(300);
/* (a) real run -> expect blocked (50210 / wrapped) */
BEGIN TRY
    EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode='RF_LOG2',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@DryRun=0,@MaxCandidates=1000;
    SET @msg='NO THROW (UNEXPECTED)';
END TRY BEGIN CATCH SET @msg=CONCAT('err=',ERROR_NUMBER(),' : ',LEFT(ERROR_MESSAGE(),160)); END CATCH
PRINT CONCAT('DryRun=0 RESULT: ',@msg);
DECLARE @cnt bigint = (SELECT COUNT_BIG(*) FROM KMWEBV.dbo.RF_LOG2);
PRINT CONCAT('  source after DryRun=0: ',@cnt,' (expect 1000 = nothing deleted)');

/* (b) dry run -> expect NO throw (floor gate is DryRun-exempt) */
BEGIN TRY
    EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode='RF_LOG2',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@DryRun=1,@MaxCandidates=1000;
    SET @msg='OK no throw (exempt)';
END TRY BEGIN CATCH SET @msg=CONCAT('err=',ERROR_NUMBER(),' : ',LEFT(ERROR_MESSAGE(),160)); END CATCH
PRINT CONCAT('DryRun=1 RESULT: ',@msg);

/* restore: floor off, RetentionDays back to 540, audit ROW */
EXEC arch.usp_Api_SetRetentionFloor @MinRetentionDays=0, @RequestedBy='battery-test';
UPDATE pd SET pd.RetentionDays=540, pd.AuditLevel='ROW'
FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId
WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
PRINT CONCAT('TEST8 end ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
