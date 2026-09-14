/* TEST 6 racing session — launched TWICE concurrently on RECEIVING@KMWEBV (ANCHOR). One should win;
   the other should be rejected (applock / concurrency guard). No double-archiving, Div=0, no deadlock. */
SET NOCOUNT ON;
USE [kArchiveManagerAdmin];
DECLARE @msg nvarchar(300), @t0 datetime2(3)=SYSUTCDATETIME();
BEGIN TRY
    EXEC arch.usp_RunConfiguredProcesses_Prepared
        @ProcessCode='RECEIVING', @SourceDb='KMWEBV', @ArchiveDb='kArchiveManagerBackups',
        @DryRun=0, @MaxCandidates=20000;
    SET @msg='OK completed';
END TRY
BEGIN CATCH
    SET @msg=CONCAT('CAUGHT err=',ERROR_NUMBER(),' : ',LEFT(ERROR_MESSAGE(),180));
END CATCH
PRINT CONCAT('ANCHOR SESSION @',CONVERT(varchar(23),SYSUTCDATETIME(),121),' (',DATEDIFF(MILLISECOND,@t0,SYSUTCDATETIME()),'ms): ',@msg);
