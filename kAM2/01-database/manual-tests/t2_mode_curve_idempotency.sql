/* TEST 2 — Mode semantics + copy-only idempotency on RF_LOG2 @ 100k.
   Config set at the EFFECTIVE (ProcessDatabase) level — Process-level is masked by pd overrides.
   AuditLevel=NONE to isolate mode behaviour.
   MODE 1 archive+delete: source->0, archive +100k.   MODE 0 delete-only: source->0, archive +0.
   MODE 2 copy-only x2:     source intact, 1st +100k, 2nd +0 (idempotent dedup by PK). */
SET NOCOUNT ON; SET XACT_ABORT ON;
USE [kArchiveManagerAdmin];
PRINT CONCAT('TEST2 start ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
DECLARE @arc0 bigint, @arc1 bigint, @arc2 bigint, @src bigint;
DECLARE @seed nvarchar(max) = N'TRUNCATE TABLE KMWEBV.dbo.RF_LOG2;
;WITH n AS (SELECT TOP (100000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM sys.all_columns a CROSS JOIN sys.all_columns b)
INSERT KMWEBV.dbo.RF_LOG2 (ROWID, DATE_TIME, USERID, [ACTION], QUANTITY, PACKSLIP)
SELECT NEWID(), CONVERT(nvarchar(46), DATEADD(SECOND,(rn-1)*30,''2023-01-01''),121), N''BENCH'',''PICK'',1,CONCAT(N''PS'',rn) FROM n;';

/* set audit NONE at pd level once (held for all mode runs) */
UPDATE pd SET pd.AuditLevel='NONE' FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';

/* ---- MODE 1 ---- */
EXEC sp_executesql @seed;
UPDATE pd SET pd.Mode=1, pd.AllowDeleteWithoutArchive=0 FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
SET @arc0=(SELECT COUNT_BIG(*) FROM kArchiveManagerBackups.KMWEBV.RF_LOG2);
EXEC bench.usp_RunBenchmark @ProcessCode='RF_LOG2',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@Label='MODE1 archive+delete 100k',@ScaleLabel='mode1',@CheapMode=1,@MaxCandidates=100000,@StopMinutes=30,@DryRun=0;
SET @arc1=(SELECT COUNT_BIG(*) FROM kArchiveManagerBackups.KMWEBV.RF_LOG2); SET @src=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.RF_LOG2);
PRINT CONCAT('MODE1 RESULT: source=',@src,' (expect 0)  archiveDelta=',@arc1-@arc0,' (expect 100000)');

/* ---- MODE 0 (delete-only) ---- */
EXEC sp_executesql @seed;
UPDATE pd SET pd.Mode=0, pd.AllowDeleteWithoutArchive=1 FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
SET @arc0=(SELECT COUNT_BIG(*) FROM kArchiveManagerBackups.KMWEBV.RF_LOG2);
EXEC bench.usp_RunBenchmark @ProcessCode='RF_LOG2',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@Label='MODE0 delete-only 100k',@ScaleLabel='mode0',@CheapMode=1,@MaxCandidates=100000,@StopMinutes=30,@DryRun=0;
SET @arc1=(SELECT COUNT_BIG(*) FROM kArchiveManagerBackups.KMWEBV.RF_LOG2); SET @src=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.RF_LOG2);
PRINT CONCAT('MODE0 RESULT: source=',@src,' (expect 0)  archiveDelta=',@arc1-@arc0,' (expect 0 = delete-only)');

/* ---- MODE 2 (copy-only) + idempotency ---- */
EXEC sp_executesql @seed;
UPDATE pd SET pd.Mode=2 FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
SET @arc0=(SELECT COUNT_BIG(*) FROM kArchiveManagerBackups.KMWEBV.RF_LOG2);
EXEC bench.usp_RunBenchmark @ProcessCode='RF_LOG2',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@Label='MODE2 copy-only 100k (1st)',@ScaleLabel='mode2-1',@CheapMode=1,@MaxCandidates=100000,@StopMinutes=30,@DryRun=0;
SET @arc1=(SELECT COUNT_BIG(*) FROM kArchiveManagerBackups.KMWEBV.RF_LOG2); SET @src=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.RF_LOG2);
PRINT CONCAT('MODE2 1st RESULT: source=',@src,' (expect 100000 intact)  archiveDelta=',@arc1-@arc0,' (expect 100000)');
EXEC bench.usp_RunBenchmark @ProcessCode='RF_LOG2',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@Label='MODE2 copy-only 100k (2nd idempotency)',@ScaleLabel='mode2-2',@CheapMode=1,@MaxCandidates=100000,@StopMinutes=30,@DryRun=0;
SET @arc2=(SELECT COUNT_BIG(*) FROM kArchiveManagerBackups.KMWEBV.RF_LOG2); SET @src=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.RF_LOG2);
PRINT CONCAT('MODE2 2nd RESULT: source=',@src,' (expect 100000)  archiveDeltaVs1st=',@arc2-@arc1,' (expect 0 = idempotent)');

/* restore defaults at pd level: Mode=1, AuditLevel=ROW, AllowDeleteWithoutArchive=0 */
UPDATE pd SET pd.Mode=1, pd.AuditLevel='ROW', pd.AllowDeleteWithoutArchive=0 FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId WHERE p.ProcessCode='RF_LOG2' AND pd.SourceDb='KMWEBV';
PRINT CONCAT('TEST2 end ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
