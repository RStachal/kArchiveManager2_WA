/* TEST 9 — legal-hold exclusion (RECEIVING, HoldKey = PO_NUM). Hold PO5; it must NOT be archived/
   deleted (excluded at PREP, 014); all other POs archive normally. Then release + re-run -> PO5 archives. */
SET NOCOUNT ON; SET XACT_ABORT ON;
USE [kArchiveManagerAdmin];
PRINT CONCAT('TEST9 start ', CONVERT(varchar(19),SYSUTCDATETIME(),120));

/* clean + seed 10 POs x 5 details = 50 BACKRD + 10 BACKRH */
EXEC('USE [kArchiveManagerBackups]; TRUNCATE TABLE [KMWEBV].[BACKRH]; TRUNCATE TABLE [KMWEBV].[BACKRD];');
TRUNCATE TABLE KMWEBV.dbo.BACKRH; TRUNCATE TABLE KMWEBV.dbo.BACKRD;
;WITH n AS (SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM sys.all_columns)
INSERT KMWEBV.dbo.BACKRH (ROWID, PO_NUM, DATE_CREAT) SELECT NEWID(), CONCAT(N'PO',rn), '2023-06-01' FROM n;
;WITH n AS (SELECT TOP (50) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) rn FROM sys.all_columns)
INSERT KMWEBV.dbo.BACKRD (ROWID, PO_NUM, DATE_CREAT, BACKRH_ID) SELECT NEWID(), CONCAT(N'PO',((rn-1)%10)+1), '2023-06-01', NEWID() FROM n;
UPDATE pd SET pd.Mode=1, pd.AuditLevel='NONE' FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId WHERE p.ProcessCode='RECEIVING' AND pd.SourceDb='KMWEBV';

/* place legal hold on PO5 */
DECLARE @holdId bigint;
EXEC arch.usp_Api_AddLegalHold @ProcessCode='RECEIVING', @SourceDb='KMWEBV', @HoldKey='PO5', @Reason='battery test 9';
SET @holdId = (SELECT TOP(1) LegalHoldId FROM arch.LegalHold WHERE ProcessCode='RECEIVING' AND HoldKey='PO5' AND ReleasedAtUtc IS NULL ORDER BY LegalHoldId DESC);

/* run with hold active */
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode='RECEIVING',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@DryRun=0,@MaxCandidates=100;
DECLARE @srcHeld bigint=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.BACKRH)+(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.BACKRD);
DECLARE @po5 bigint=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.BACKRH WHERE PO_NUM='PO5')+(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.BACKRD WHERE PO_NUM='PO5');
DECLARE @other bigint=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.BACKRH WHERE PO_NUM<>'PO5')+(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.BACKRD WHERE PO_NUM<>'PO5');
PRINT CONCAT('WITH HOLD: source total=',@srcHeld,' | PO5 remaining=',@po5,' (expect 6 = 1 hdr+5 det, held) | non-PO5 remaining=',@other,' (expect 0, archived)');

/* release hold, re-run -> PO5 should now archive */
EXEC arch.usp_Api_ReleaseLegalHold @LegalHoldId=@holdId;
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode='RECEIVING',@SourceDb='KMWEBV',@ArchiveDb='kArchiveManagerBackups',@DryRun=0,@MaxCandidates=100;
DECLARE @srcAfter bigint=(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.BACKRH)+(SELECT COUNT_BIG(*) FROM KMWEBV.dbo.BACKRD);
PRINT CONCAT('AFTER RELEASE+RERUN: source total=',@srcAfter,' (expect 0, PO5 now archived)');

UPDATE pd SET pd.AuditLevel='ROW' FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId=pd.ProcessId WHERE p.ProcessCode='RECEIVING' AND pd.SourceDb='KMWEBV';
PRINT CONCAT('TEST9 end ', CONVERT(varchar(19),SYSUTCDATETIME(),120));
