/* TEST 1c — clean audit A/B (NONE vs ROW), controlling for warm-up + archive growth.
   Each run: reset source (reseed 200k) AND reset archive (truncate) => identical conditions.
   1 warm-up (discarded), then NONE,ROW,NONE,ROW measured. cheap-mode, pd-level AuditLevel. */
SET NOCOUNT ON; SET XACT_ABORT ON;
USE [kArchiveManagerAdmin];
PRINT CONCAT('TEST1c start ', CONVERT(varchar(19),SYSUTCDATETIME(),120));

DECLARE @seq TABLE(ord int, lvl nvarchar(20), tag nvarchar(20));
INSERT @seq VALUES (1,'NONE','warmup'),(2,'NONE','ab'),(3,'ROW','ab'),(4,'NONE','ab'),(5,'ROW','ab');
DECLARE @lvl nvarchar(20), @tag nvarchar(20), @lbl nvarchar(120), @scale nvarchar(40);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT lvl, tag FROM @seq ORDER BY ord;
OPEN c; FETCH NEXT FROM c INTO @lvl, @tag;
WHILE @@FETCH_STATUS = 0
BEGIN
    TRUNCATE TABLE KMWEBV.dbo.RF_LOG2;
    EXEC('USE [kArchiveManagerBackups]; TRUNCATE TABLE [KMWEBV].[RF_LOG2];');  -- identical (empty) archive each run
    ;WITH n AS (SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM sys.all_columns a CROSS JOIN sys.all_columns b)
    INSERT KMWEBV.dbo.RF_LOG2 (ROWID, DATE_TIME, USERID, [ACTION], QUANTITY, PACKSLIP)
    SELECT NEWID(), CONVERT(nvarchar(46), DATEADD(SECOND,(rn-1)*30,'2023-01-01'),121), N'BENCH','PICK',1,CONCAT(N'PS',rn) FROM n;
    UPDATE pd SET pd.AuditLevel=@lvl FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
    SET @lbl = CONCAT('AUDIT-AB ', @tag, ' ', @lvl);
    SET @scale = CONCAT(@tag, '-', @lvl);
    EXEC bench.usp_RunBenchmark @ProcessCode='RF_LOG2',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@Label=@lbl,@ScaleLabel=@scale,@CheapMode=1,@MaxCandidates=200000,@StopMinutes=30,@DryRun=0;
    FETCH NEXT FROM c INTO @lvl, @tag;
END
CLOSE c; DEALLOCATE c;
UPDATE pd SET pd.AuditLevel='ROW' FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
PRINT CONCAT('TEST1c end ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
