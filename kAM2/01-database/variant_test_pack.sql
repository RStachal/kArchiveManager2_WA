/* ============================================================================
   kArchiveManager 2.0 — MANUAL VARIANT TEST PACK ("testy na všechny varianty z ruky")
   ----------------------------------------------------------------------------
   FULLY SELF-CONTAINED. Builds a synthetic source table + two throwaway processes
   (one ANCHOR, one TIMESTAMP) inside kArchiveManagerAdmin, then drives the REAL
   pipeline through every variant and asserts expected==actual. Touches NO real data.
   Re-runnable (cleans up at start + end). Returns one result set; any Result='FAIL'
   is a problem.

   Run by hand in SSMS (F5) against kArchiveManagerAdmin AFTER the clean object deploy.
   This complements selftest_acceptance.sql (single happy path) by covering the full
   Mode x Strategy matrix + gates.

   Variants covered:
     A1 ANCHOR    Mode=1 archive+delete (Divergence=0) + AuditLevel=ROW (per-doc audit)
     A2 ANCHOR    Mode=0 delete-only (AllowDeleteWithoutArchive; archive untouched)
     A3 ANCHOR    Mode=2 copy-only (source kept; archive filled; re-run copies 0 = idempotent)
     A4 ANCHOR    DryRun=1 (preview; no mutation)
     A5 ANCHOR    Retention-floor gate (THROW 50210)
     A6 ANCHOR    Legal-hold (held key excluded -> survives)
     A7 ANCHOR    Timezone gate (raw cutoff THROW 50200)
     T1 TIMESTAMP Mode=1 archive+delete (Divergence=0)
     T2 TIMESTAMP Mode=2 copy-only (idempotent)
     T3 TIMESTAMP DryRun=1 (preview; no mutation)
     T4 TIMESTAMP AuditLevel NONE vs BATCH vs ROW (audit-row counts)
     R1 RESTORE   un-archive round-trip (T-27)
     S1 STOP      usp_Api_RequestRunStop stamps cancel + persists who/why, first-writer-wins (T-10)
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_WARNINGS ON;
USE [kArchiveManagerAdmin];

DECLARE @db sysname = DB_NAME();                 -- source = archive = this control DB (self-contained)
DECLARE @pcA sysname = N'ZZ_VT_ANCHOR';
DECLARE @pcT sysname = N'ZZ_VT_TS';
DECLARE @res TABLE (Seq int IDENTITY(1,1), Result char(4), Variant nvarchar(12), Check_ nvarchar(160), Detail nvarchar(400));

/* ---------- teardown helper (run at start to clear residue, and at end) ---------- */
DECLARE @cleanup nvarchar(max) = N'
DECLARE @pids TABLE (ProcessId int);
INSERT @pids SELECT ProcessId FROM arch.Process WHERE ProcessCode IN (N''ZZ_VT_ANCHOR'',N''ZZ_VT_TS'');
IF EXISTS (SELECT 1 FROM @pids)
BEGIN
    DELETE a FROM arch.RunDocAudit a JOIN arch.RunItem ri ON ri.RunItemId=a.RunItemId WHERE ri.ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE rio FROM arch.RunItemObject rio JOIN arch.RunItem ri ON ri.RunItemId=rio.RunItemId WHERE ri.ProcessId IN (SELECT ProcessId FROM @pids);
    DECLARE @rids TABLE (RunId bigint);
    INSERT @rids SELECT DISTINCT ri.RunId FROM arch.RunItem ri WHERE ri.ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE wbk FROM arch.WorkBatchKey wbk JOIN arch.WorkBatch wb ON wb.WorkBatchId=wbk.WorkBatchId WHERE wb.ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE FROM arch.WorkBatch WHERE ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE FROM arch.RunItem WHERE ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE FROM arch.Run WHERE RunId IN (SELECT RunId FROM @rids);
    IF OBJECT_ID(N''arch.RestoreAudit'',N''U'') IS NOT NULL DELETE FROM arch.RestoreAudit WHERE ProcessCode IN (N''ZZ_VT_ANCHOR'',N''ZZ_VT_TS'');
    IF OBJECT_ID(N''arch.LegalHold'',N''U'') IS NOT NULL DELETE FROM arch.LegalHold WHERE ProcessCode IN (N''ZZ_VT_ANCHOR'',N''ZZ_VT_TS'');
    DELETE FROM arch.IndexRequirement WHERE ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE FROM arch.ObjectSpec WHERE ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE FROM arch.ProcessKeySpec WHERE ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE FROM arch.ProcessDatabase WHERE ProcessId IN (SELECT ProcessId FROM @pids);
    DELETE FROM arch.Process WHERE ProcessId IN (SELECT ProcessId FROM @pids);
END;
IF OBJECT_ID(N''arch.RetentionPolicy'',N''U'') IS NOT NULL UPDATE arch.RetentionPolicy SET MinRetentionDays = 0;
DROP TABLE IF EXISTS vtest.DOCS;
DROP TABLE IF EXISTS vtest_arch.DOCS;
IF SCHEMA_ID(N''vtest'') IS NOT NULL EXEC(N''DROP SCHEMA vtest'');
IF SCHEMA_ID(N''vtest_arch'') IS NOT NULL EXEC(N''DROP SCHEMA vtest_arch'');';
EXEC sys.sp_executesql @cleanup;

/* ---------- re-seed helper: clear run-state (so each section re-prepares cleanly — no leftover
   WorkBatch from a prior section), reset source to 6 rows (3 old candidates + 3 new), drop archive ---------- */
DECLARE @reseed nvarchar(max) = N'
DECLARE @p TABLE (ProcessId int);
INSERT @p SELECT ProcessId FROM arch.Process WHERE ProcessCode IN (N''ZZ_VT_ANCHOR'',N''ZZ_VT_TS'');
DECLARE @r TABLE (RunId bigint);
INSERT @r SELECT DISTINCT ri.RunId FROM arch.RunItem ri WHERE ri.ProcessId IN (SELECT ProcessId FROM @p);
DELETE a FROM arch.RunDocAudit a JOIN arch.RunItem ri ON ri.RunItemId=a.RunItemId WHERE ri.ProcessId IN (SELECT ProcessId FROM @p);
DELETE rio FROM arch.RunItemObject rio JOIN arch.RunItem ri ON ri.RunItemId=rio.RunItemId WHERE ri.ProcessId IN (SELECT ProcessId FROM @p);
DELETE wbk FROM arch.WorkBatchKey wbk JOIN arch.WorkBatch wb ON wb.WorkBatchId=wbk.WorkBatchId WHERE wb.ProcessId IN (SELECT ProcessId FROM @p);
DELETE FROM arch.WorkBatch WHERE ProcessId IN (SELECT ProcessId FROM @p);
DELETE FROM arch.RunItem WHERE ProcessId IN (SELECT ProcessId FROM @p);
DELETE FROM arch.Run WHERE RunId IN (SELECT RunId FROM @r);
DELETE FROM vtest.DOCS;
DROP TABLE IF EXISTS vtest_arch.DOCS;
DECLARE @old datetime = DATEADD(DAY, -800, GETDATE());   -- below 365-day retention -> candidate
DECLARE @new datetime = GETDATE();                        -- above cutoff -> not a candidate
INSERT vtest.DOCS (DocId, Created, Payload) VALUES
    (1,@old,N''old-1''),(2,@old,N''old-2''),(3,@old,N''old-3''),
    (4,@new,N''new-4''),(5,@new,N''new-5''),(6,@new,N''new-6'');';

/* ---------- synthetic source table ---------- */
EXEC(N'CREATE SCHEMA vtest');
EXEC(N'CREATE SCHEMA vtest_arch');
CREATE TABLE vtest.DOCS
(
    DocId   int           NOT NULL CONSTRAINT PK_VT_DOCS PRIMARY KEY,
    Created datetime      NOT NULL,
    Payload nvarchar(100) NULL,
    rv      rowversion    NOT NULL
);

/* ---------- common config fragments ---------- */
DECLARE @tz nvarchar(200) = N' AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''';
DECLARE @anchorTs nvarchar(400) = N'CAST(a.Created' + @tz;
DECLARE @tsExpr    nvarchar(400) = N'CAST(t.Created' + @tz;

/* ============================================================================
   PROCESS A = ANCHOR (doc-based). Default Mode=1, AuditLevel=ROW.
   ============================================================================ */
INSERT arch.Process (ProcessCode,Description,IsEnabled,Mode,RetentionDays,CutoffSafetyLagMinutes,
    BatchDocCount,BatchRowCount,MaxBatchesPerRun,DelayMsBetweenBatches,UseAppLock,AppLockResource,
    LockTimeoutMs,DeadlockPriority,AnchorSchema,AnchorTable,AnchorDocKeyExpr,AnchorDocKey2Expr,
    AnchorTimestampExpr,AnchorExtraWhereSql,AllowDeleteWithoutArchive,CreatedAt,ModifiedAt,CutoffMode,
    CutoffDate,DocKeyLabel,SelectionStrategy,AuditLevel,RequireSupportingIndex,MaxRowsPerTransaction,
    CandidateWhereSql,CandidateOrderSql)
VALUES (@pcA,N'Variant test ANCHOR (throwaway)',1,1,365,0,100,NULL,10,0,0,NULL,10000,N'LOW',N'vtest',
    N'DOCS',N'a.DocId',NULL,@anchorTs,NULL,0,SYSUTCDATETIME(),SYSUTCDATETIME(),0,NULL,
    N'DocId',N'ANCHOR',N'ROW',0,NULL,NULL,NULL);
DECLARE @pidA int = (SELECT ProcessId FROM arch.Process WHERE ProcessCode=@pcA);
INSERT arch.ProcessKeySpec (ProcessId,KeyOrdinal,KeyName,SourceExpressionSql,SqlType,IsRequired,CreatedAt,ModifiedAt)
VALUES (@pidA,1,N'DocId',N'a.DocId',N'int',1,SYSUTCDATETIME(),SYSUTCDATETIME());
INSERT arch.ObjectSpec (ProcessId,SourceSchema,SourceTable,DeleteOrder,DeleteMode,TimestampExpr,
    JoinToAnchorPredicateSql,AdditionalWhereSql,ArchiveSchema,ArchiveTable,RequireArchiveForDelete,NaturalKeyLabel)
VALUES (@pidA,N'vtest',N'DOCS',10,1,@tsExpr,N't.DocId = k.Key1',NULL,N'vtest_arch',N'DOCS',1,N'DocId');
INSERT arch.ProcessDatabase (ProcessId,SourceDb,ArchiveDb,IsEnabled,RunOrder,CreatedAt,ModifiedAt)
VALUES (@pidA,@db,@db,1,1,SYSUTCDATETIME(),SYSUTCDATETIME());

/* ============================================================================
   PROCESS T = TIMESTAMP (log-based). Default Mode=1, AuditLevel=NONE.
   ============================================================================ */
INSERT arch.Process (ProcessCode,Description,IsEnabled,Mode,RetentionDays,CutoffSafetyLagMinutes,
    BatchDocCount,BatchRowCount,MaxBatchesPerRun,DelayMsBetweenBatches,UseAppLock,AppLockResource,
    LockTimeoutMs,DeadlockPriority,AnchorSchema,AnchorTable,AnchorDocKeyExpr,AnchorDocKey2Expr,
    AnchorTimestampExpr,AnchorExtraWhereSql,AllowDeleteWithoutArchive,CreatedAt,ModifiedAt,CutoffMode,
    CutoffDate,DocKeyLabel,SelectionStrategy,AuditLevel,RequireSupportingIndex,MaxRowsPerTransaction,
    CandidateWhereSql,CandidateOrderSql)
VALUES (@pcT,N'Variant test TIMESTAMP (throwaway)',1,1,365,0,NULL,1000,20,0,0,NULL,10000,N'LOW',NULL,
    NULL,NULL,NULL,NULL,NULL,0,SYSUTCDATETIME(),SYSUTCDATETIME(),0,NULL,
    N'DocId',N'TIMESTAMP',N'NONE',0,1000,NULL,N'DocCreatedAt, Key1');
DECLARE @pidT int = (SELECT ProcessId FROM arch.Process WHERE ProcessCode=@pcT);
INSERT arch.ProcessKeySpec (ProcessId,KeyOrdinal,KeyName,SourceExpressionSql,SqlType,IsRequired,CreatedAt,ModifiedAt)
VALUES (@pidT,1,N'DocId',N't.DocId',N'int',1,SYSUTCDATETIME(),SYSUTCDATETIME());
INSERT arch.ObjectSpec (ProcessId,SourceSchema,SourceTable,DeleteOrder,DeleteMode,TimestampExpr,
    JoinToAnchorPredicateSql,AdditionalWhereSql,ArchiveSchema,ArchiveTable,RequireArchiveForDelete,NaturalKeyLabel)
VALUES (@pidT,N'vtest',N'DOCS',10,1,@tsExpr,N't.DocId = k.Key1',N't.Created IS NOT NULL',N'vtest_arch',N'DOCS',1,N'DocId');
INSERT arch.ProcessDatabase (ProcessId,SourceDb,ArchiveDb,IsEnabled,RunOrder,CreatedAt,ModifiedAt)
VALUES (@pidT,@db,@db,1,1,SYSUTCDATETIME(),SYSUTCDATETIME());

DECLARE @riid bigint, @arch bigint, @del bigint, @srcLeft int, @arcRows int, @auditRows int, @status nvarchar(20);
-- archive table only exists after a run that actually archived (Mode 1/2); delete-only + DryRun leave it absent.
-- A missing table is a compile-time bind error in an ad-hoc batch, so read the count via OBJECT_ID-guarded dynamic SQL.
DECLARE @arcCountSql nvarchar(200) = N'SELECT @n=COUNT(*) FROM vtest_arch.DOCS';

/* =========================== A1: ANCHOR Mode=1 + ROW audit =========================== */
EXEC sys.sp_executesql @reseed;
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=@pcA,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@MaxCandidates=100;
SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidA ORDER BY ri.RunItemId DESC);
SELECT @arch=ISNULL(SUM(RowsArchived),0),@del=ISNULL(SUM(RowsDeleted),0) FROM arch.RunItemObject WHERE RunItemId=@riid;
SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
SET @arcRows=0; IF OBJECT_ID(N'vtest_arch.DOCS') IS NOT NULL EXEC sys.sp_executesql @arcCountSql,N'@n int OUTPUT',@n=@arcRows OUTPUT;
SELECT @auditRows=COUNT(*) FROM arch.RunDocAudit WHERE RunItemId=@riid;
SELECT @status=Status FROM arch.RunItem WHERE RunItemId=@riid;
INSERT @res VALUES(CASE WHEN @status=N'OK' AND @del=3 AND @arch=3 THEN 'PASS' ELSE 'FAIL' END,N'A1',N'ANCHOR Mode=1: 3 archived = 3 deleted, Divergence=0',CONCAT(N'status=',@status,N' arch=',@arch,N' del=',@del));
INSERT @res VALUES(CASE WHEN @srcLeft=3 AND @arcRows=3 THEN 'PASS' ELSE 'FAIL' END,N'A1',N'source 3 left, archive has 3',CONCAT(N'srcLeft=',@srcLeft,N' arcRows=',@arcRows));
INSERT @res VALUES(CASE WHEN @auditRows=3 THEN 'PASS' ELSE 'FAIL' END,N'A1',N'AuditLevel=ROW wrote per-doc RunDocAudit',CONCAT(N'auditRows=',@auditRows));

/* =========================== A2: ANCHOR Mode=0 delete-only =========================== */
EXEC sys.sp_executesql @reseed;
UPDATE arch.Process SET Mode=0, AllowDeleteWithoutArchive=1 WHERE ProcessId=@pidA;
UPDATE arch.ObjectSpec SET RequireArchiveForDelete=0 WHERE ProcessId=@pidA;
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=@pcA,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@MaxCandidates=100;
SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidA ORDER BY ri.RunItemId DESC);
SELECT @arch=ISNULL(SUM(RowsArchived),0),@del=ISNULL(SUM(RowsDeleted),0) FROM arch.RunItemObject WHERE RunItemId=@riid;
SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
SET @arcRows=0; IF OBJECT_ID(N'vtest_arch.DOCS') IS NOT NULL EXEC sys.sp_executesql @arcCountSql,N'@n int OUTPUT',@n=@arcRows OUTPUT;
SELECT @status=Status FROM arch.RunItem WHERE RunItemId=@riid;
INSERT @res VALUES(CASE WHEN @status=N'OK' AND @del=3 AND @arch=0 AND @srcLeft=3 THEN 'PASS' ELSE 'FAIL' END,N'A2',N'ANCHOR Mode=0: 3 deleted, 0 archived, source 3 left',CONCAT(N'status=',@status,N' del=',@del,N' arch=',@arch,N' srcLeft=',@srcLeft));
INSERT @res VALUES(CASE WHEN @arcRows=0 THEN 'PASS' ELSE 'FAIL' END,N'A2',N'delete-only left archive empty',CONCAT(N'arcRows=',@arcRows));
-- restore Mode=1 defaults
UPDATE arch.Process SET Mode=1, AllowDeleteWithoutArchive=0 WHERE ProcessId=@pidA;
UPDATE arch.ObjectSpec SET RequireArchiveForDelete=1 WHERE ProcessId=@pidA;

/* =========================== A3: ANCHOR Mode=2 copy-only (idempotent) =========================== */
EXEC sys.sp_executesql @reseed;
UPDATE arch.Process SET Mode=2 WHERE ProcessId=@pidA;
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=@pcA,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@MaxCandidates=100;
SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidA ORDER BY ri.RunItemId DESC);
SELECT @arch=ISNULL(SUM(RowsArchived),0),@del=ISNULL(SUM(RowsDeleted),0) FROM arch.RunItemObject WHERE RunItemId=@riid;
SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
SET @arcRows=0; IF OBJECT_ID(N'vtest_arch.DOCS') IS NOT NULL EXEC sys.sp_executesql @arcCountSql,N'@n int OUTPUT',@n=@arcRows OUTPUT;
SELECT @status=Status FROM arch.RunItem WHERE RunItemId=@riid;
INSERT @res VALUES(CASE WHEN @status=N'OK' AND @arch=3 AND @del=0 AND @srcLeft=6 THEN 'PASS' ELSE 'FAIL' END,N'A3',N'ANCHOR Mode=2: 3 copied, 0 deleted, source kept (6)',CONCAT(N'status=',@status,N' arch=',@arch,N' del=',@del,N' srcLeft=',@srcLeft));
INSERT @res VALUES(CASE WHEN @arcRows=3 THEN 'PASS' ELSE 'FAIL' END,N'A3',N'archive received 3 copies',CONCAT(N'arcRows=',@arcRows));
-- re-run WITHOUT reseed: idempotent -> 0 new copies, archive still 3
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=@pcA,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@MaxCandidates=100;
SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidA ORDER BY ri.RunItemId DESC);
SELECT @arch=ISNULL(SUM(RowsArchived),0) FROM arch.RunItemObject WHERE RunItemId=@riid;
SET @arcRows=0; IF OBJECT_ID(N'vtest_arch.DOCS') IS NOT NULL EXEC sys.sp_executesql @arcCountSql,N'@n int OUTPUT',@n=@arcRows OUTPUT;
INSERT @res VALUES(CASE WHEN @arch=0 AND @arcRows=3 THEN 'PASS' ELSE 'FAIL' END,N'A3',N'Mode=2 re-run is idempotent (0 new, archive still 3)',CONCAT(N'arch2=',@arch,N' arcRows=',@arcRows));
UPDATE arch.Process SET Mode=1 WHERE ProcessId=@pidA;

/* =========================== A4: ANCHOR DryRun (no mutation) =========================== */
EXEC sys.sp_executesql @reseed;
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=@pcA,@SourceDb=@db,@ArchiveDb=@db,@DryRun=1,@MaxCandidates=100;
SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
SET @arcRows=0; IF OBJECT_ID(N'vtest_arch.DOCS') IS NOT NULL EXEC sys.sp_executesql @arcCountSql,N'@n int OUTPUT',@n=@arcRows OUTPUT;
INSERT @res VALUES(CASE WHEN @srcLeft=6 AND @arcRows=0 THEN 'PASS' ELSE 'FAIL' END,N'A4',N'ANCHOR DryRun: source untouched (6), archive empty',CONCAT(N'srcLeft=',@srcLeft,N' arcRows=',@arcRows));

/* =========================== A5: Retention-floor gate (THROW 50210) =========================== */
EXEC sys.sp_executesql @reseed;
IF OBJECT_ID(N'arch.usp_AssertRetentionFloor',N'P') IS NOT NULL
BEGIN
    EXEC arch.usp_Api_SetRetentionFloor @MinRetentionDays=10000, @RequestedBy=N'vtest';
    -- direct gate: a cutoff = now is far more recent than (now - 10000 days) -> THROW 50210
    BEGIN TRY
        DECLARE @nowUtc datetime2(0) = SYSUTCDATETIME();
        EXEC arch.usp_AssertRetentionFloor @SourceDb=@db, @ArchiveDb=@db, @CutoffUtc=@nowUtc;
        INSERT @res VALUES('FAIL',N'A5',N'retention floor THROW 50210 on too-recent cutoff',N'gate did NOT throw');
    END TRY
    BEGIN CATCH
        INSERT @res SELECT CASE WHEN ERROR_NUMBER()=50210 THEN 'PASS' ELSE 'FAIL' END,
            N'A5',N'retention floor THROW 50210 on too-recent cutoff',CONCAT(N'errno=',ERROR_NUMBER(),N' ',LEFT(ERROR_MESSAGE(),150));
    END CATCH
    -- and the orchestrator must delete nothing under an active floor (run logged FAILED, source intact)
    BEGIN TRY EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=@pcA,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@MaxCandidates=100; END TRY BEGIN CATCH END CATCH
    SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
    INSERT @res VALUES(CASE WHEN @srcLeft=6 THEN 'PASS' ELSE 'FAIL' END,N'A5',N'floor-active run deleted nothing (source 6)',CONCAT(N'srcLeft=',@srcLeft));
    EXEC arch.usp_Api_SetRetentionFloor @MinRetentionDays=0, @RequestedBy=N'vtest';
END
ELSE INSERT @res VALUES('SKIP',N'A5',N'retention floor (056 not deployed)',N'usp_AssertRetentionFloor missing');

/* =========================== A6: Legal-hold (held key survives) =========================== */
EXEC sys.sp_executesql @reseed;
IF OBJECT_ID(N'arch.LegalHold',N'U') IS NOT NULL
BEGIN
    EXEC arch.usp_Api_AddLegalHold @ProcessCode=@pcA, @HoldKey=N'1', @Reason=N'variant test hold', @SourceDb=@db, @RequestedBy=N'vtest';  -- hold DocId=1
    EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=@pcA,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@MaxCandidates=100;
    SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidA ORDER BY ri.RunItemId DESC);
    SELECT @del=ISNULL(SUM(RowsDeleted),0) FROM arch.RunItemObject WHERE RunItemId=@riid;
    DECLARE @heldStillThere int = (SELECT COUNT(*) FROM vtest.DOCS WHERE DocId=1);
    INSERT @res VALUES(CASE WHEN @del=2 AND @heldStillThere=1 THEN 'PASS' ELSE 'FAIL' END,N'A6',N'legal-hold excluded DocId=1 (2 deleted, held survives)',CONCAT(N'del=',@del,N' heldThere=',@heldStillThere));
    DELETE FROM arch.LegalHold WHERE ProcessCode=@pcA;
END
ELSE INSERT @res VALUES('SKIP',N'A6',N'legal-hold (056 not deployed)',N'arch.LegalHold missing');

/* =========================== A7: Timezone gate (raw cutoff THROW 50200) =========================== */
EXEC sys.sp_executesql @reseed;
UPDATE arch.Process SET AnchorTimestampExpr=N'CAST(a.Created AS datetime2)' WHERE ProcessId=@pidA;  -- no AT TIME ZONE
UPDATE arch.ObjectSpec SET TimestampExpr=N'CAST(t.Created AS datetime2)' WHERE ProcessId=@pidA;
BEGIN TRY
    EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=@pcA,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@MaxCandidates=100;
    INSERT @res VALUES('FAIL',N'A7',N'TZ gate blocks raw cutoff on real run (50200)',N'run was NOT blocked');
END TRY
BEGIN CATCH
    INSERT @res SELECT CASE WHEN ERROR_NUMBER()=50200 OR ERROR_MESSAGE() LIKE '%AT TIME ZONE%' OR ERROR_MESSAGE() LIKE '%50200%' THEN 'PASS' ELSE 'FAIL' END,
        N'A7',N'TZ gate blocks raw cutoff on real run (50200)',LEFT(ERROR_MESSAGE(),200);
END CATCH
UPDATE arch.Process SET AnchorTimestampExpr=@anchorTs WHERE ProcessId=@pidA;
UPDATE arch.ObjectSpec SET TimestampExpr=@tsExpr WHERE ProcessId=@pidA;

/* =========================== T1: TIMESTAMP Mode=1 archive+delete =========================== */
EXEC sys.sp_executesql @reseed;
EXEC arch.usp_RunTimestampProcess @ProcessCode=@pcT,@SourceDb=@db,@ArchiveDb=@db,@MaxRows=100,@DryRun=0;
SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidT ORDER BY ri.RunItemId DESC);
SELECT @arch=ISNULL(SUM(RowsArchived),0),@del=ISNULL(SUM(RowsDeleted),0) FROM arch.RunItemObject WHERE RunItemId=@riid;
SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
SET @arcRows=0; IF OBJECT_ID(N'vtest_arch.DOCS') IS NOT NULL EXEC sys.sp_executesql @arcCountSql,N'@n int OUTPUT',@n=@arcRows OUTPUT;
SELECT @status=Status FROM arch.RunItem WHERE RunItemId=@riid;
INSERT @res VALUES(CASE WHEN @status=N'OK' AND @del=3 AND @arch=3 AND @srcLeft=3 AND @arcRows=3 THEN 'PASS' ELSE 'FAIL' END,N'T1',N'TIMESTAMP Mode=1: 3 archived = 3 deleted, Divergence=0',CONCAT(N'status=',@status,N' arch=',@arch,N' del=',@del,N' srcLeft=',@srcLeft));

/* =========================== T2: TIMESTAMP Mode=2 copy-only (idempotent) =========================== */
EXEC sys.sp_executesql @reseed;
UPDATE arch.Process SET Mode=2 WHERE ProcessId=@pidT;
EXEC arch.usp_RunTimestampProcess @ProcessCode=@pcT,@SourceDb=@db,@ArchiveDb=@db,@MaxRows=100,@DryRun=0;
SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidT ORDER BY ri.RunItemId DESC);
SELECT @arch=ISNULL(SUM(RowsArchived),0),@del=ISNULL(SUM(RowsDeleted),0) FROM arch.RunItemObject WHERE RunItemId=@riid;
SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
SET @arcRows=0; IF OBJECT_ID(N'vtest_arch.DOCS') IS NOT NULL EXEC sys.sp_executesql @arcCountSql,N'@n int OUTPUT',@n=@arcRows OUTPUT;
SELECT @status=Status FROM arch.RunItem WHERE RunItemId=@riid;
INSERT @res VALUES(CASE WHEN @status=N'OK' AND @arch=3 AND @del=0 AND @srcLeft=6 AND @arcRows=3 THEN 'PASS' ELSE 'FAIL' END,N'T2',N'TIMESTAMP Mode=2: 3 copied, 0 deleted, source kept',CONCAT(N'status=',@status,N' arch=',@arch,N' del=',@del,N' srcLeft=',@srcLeft));
EXEC arch.usp_RunTimestampProcess @ProcessCode=@pcT,@SourceDb=@db,@ArchiveDb=@db,@MaxRows=100,@DryRun=0;  -- re-run
SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidT ORDER BY ri.RunItemId DESC);
SELECT @arch=ISNULL(SUM(RowsArchived),0) FROM arch.RunItemObject WHERE RunItemId=@riid;
SET @arcRows=0; IF OBJECT_ID(N'vtest_arch.DOCS') IS NOT NULL EXEC sys.sp_executesql @arcCountSql,N'@n int OUTPUT',@n=@arcRows OUTPUT;
INSERT @res VALUES(CASE WHEN @arch=0 AND @arcRows=3 THEN 'PASS' ELSE 'FAIL' END,N'T2',N'TIMESTAMP Mode=2 re-run idempotent (0 new, archive still 3)',CONCAT(N'arch2=',@arch,N' arcRows=',@arcRows));
UPDATE arch.Process SET Mode=1 WHERE ProcessId=@pidT;

/* =========================== T3: TIMESTAMP DryRun (no mutation) =========================== */
EXEC sys.sp_executesql @reseed;
EXEC arch.usp_RunTimestampProcess @ProcessCode=@pcT,@SourceDb=@db,@ArchiveDb=@db,@MaxRows=100,@DryRun=1;
SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
SET @arcRows=0; IF OBJECT_ID(N'vtest_arch.DOCS') IS NOT NULL EXEC sys.sp_executesql @arcCountSql,N'@n int OUTPUT',@n=@arcRows OUTPUT;
INSERT @res VALUES(CASE WHEN @srcLeft=6 AND @arcRows=0 THEN 'PASS' ELSE 'FAIL' END,N'T3',N'TIMESTAMP DryRun: source untouched (6), archive empty',CONCAT(N'srcLeft=',@srcLeft,N' arcRows=',@arcRows));

/* =========================== T4: AuditLevel NONE vs BATCH vs ROW =========================== */
-- NONE
EXEC sys.sp_executesql @reseed;
UPDATE arch.Process SET AuditLevel=N'NONE' WHERE ProcessId=@pidT;
EXEC arch.usp_RunTimestampProcess @ProcessCode=@pcT,@SourceDb=@db,@ArchiveDb=@db,@MaxRows=100,@DryRun=0;
SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidT ORDER BY ri.RunItemId DESC);
SELECT @auditRows=COUNT(*) FROM arch.RunDocAudit WHERE RunItemId=@riid;
INSERT @res VALUES(CASE WHEN @auditRows=0 THEN 'PASS' ELSE 'FAIL' END,N'T4',N'AuditLevel=NONE wrote 0 per-doc audit rows',CONCAT(N'auditRows=',@auditRows));
-- ROW
EXEC sys.sp_executesql @reseed;
UPDATE arch.Process SET AuditLevel=N'ROW' WHERE ProcessId=@pidT;
EXEC arch.usp_RunTimestampProcess @ProcessCode=@pcT,@SourceDb=@db,@ArchiveDb=@db,@MaxRows=100,@DryRun=0;
SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidT ORDER BY ri.RunItemId DESC);
SELECT @auditRows=COUNT(*) FROM arch.RunDocAudit WHERE RunItemId=@riid;
INSERT @res VALUES(CASE WHEN @auditRows=3 THEN 'PASS' ELSE 'FAIL' END,N'T4',N'AuditLevel=ROW wrote 3 per-doc audit rows',CONCAT(N'auditRows=',@auditRows));
UPDATE arch.Process SET AuditLevel=N'NONE' WHERE ProcessId=@pidT;

/* =========================== T5: TIMESTAMP Mode=0 delete-only =========================== */
EXEC sys.sp_executesql @reseed;
UPDATE arch.Process SET Mode=0, AllowDeleteWithoutArchive=1 WHERE ProcessId=@pidT;
UPDATE arch.ObjectSpec SET RequireArchiveForDelete=0 WHERE ProcessId=@pidT;
EXEC arch.usp_RunTimestampProcess @ProcessCode=@pcT,@SourceDb=@db,@ArchiveDb=@db,@MaxRows=100,@DryRun=0;
SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidT ORDER BY ri.RunItemId DESC);
SELECT @arch=ISNULL(SUM(RowsArchived),0),@del=ISNULL(SUM(RowsDeleted),0) FROM arch.RunItemObject WHERE RunItemId=@riid;
SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
SET @arcRows=0; IF OBJECT_ID(N'vtest_arch.DOCS') IS NOT NULL EXEC sys.sp_executesql @arcCountSql,N'@n int OUTPUT',@n=@arcRows OUTPUT;
SELECT @status=Status FROM arch.RunItem WHERE RunItemId=@riid;
INSERT @res VALUES(CASE WHEN @status=N'OK' AND @del=3 AND @arch=0 AND @srcLeft=3 THEN 'PASS' ELSE 'FAIL' END,N'T5',N'TIMESTAMP Mode=0: 3 deleted, 0 archived, source 3 left',CONCAT(N'status=',@status,N' del=',@del,N' arch=',@arch,N' srcLeft=',@srcLeft));
INSERT @res VALUES(CASE WHEN @arcRows=0 THEN 'PASS' ELSE 'FAIL' END,N'T5',N'delete-only left archive empty',CONCAT(N'arcRows=',@arcRows));
UPDATE arch.Process SET Mode=1, AllowDeleteWithoutArchive=0 WHERE ProcessId=@pidT;
UPDATE arch.ObjectSpec SET RequireArchiveForDelete=1 WHERE ProcessId=@pidT;

/* =========================== T6: TIMESTAMP key uniqueness gate (THROW 50115) =========================== */
-- Switch the TIMESTAMP key to a NON-unique column (Payload) with duplicated values among eligible rows:
-- the runtime gate must refuse the real run (the keyset DELETE would touch never-evaluated rows).
EXEC sys.sp_executesql @reseed;
UPDATE vtest.DOCS SET Payload = N'dup' WHERE DocId IN (1, 2);   -- two OLD rows share one key value
UPDATE arch.ProcessKeySpec SET SourceExpressionSql = N't.Payload' WHERE ProcessId=@pidT AND KeyOrdinal=1;
UPDATE arch.ObjectSpec SET JoinToAnchorPredicateSql = N't.Payload = k.Key1' WHERE ProcessId=@pidT;
BEGIN TRY
    EXEC arch.usp_RunTimestampProcess @ProcessCode=@pcT,@SourceDb=@db,@ArchiveDb=@db,@MaxRows=100,@DryRun=0;
    INSERT @res VALUES('FAIL',N'T6',N'uniqueness gate blocks non-unique TIMESTAMP key (50115)',N'run was NOT blocked');
END TRY
BEGIN CATCH
    -- 027's CATCH re-wraps inner errors via RAISERROR (errno 50000), so match the gate by message too.
    INSERT @res SELECT CASE WHEN ERROR_NUMBER()=50115 OR ERROR_MESSAGE() LIKE N'%not unique among eligible rows%' THEN 'PASS' ELSE 'FAIL' END,
        N'T6',N'uniqueness gate blocks non-unique TIMESTAMP key (50115)',CONCAT(N'errno=',ERROR_NUMBER(),N' ',LEFT(ERROR_MESSAGE(),140));
END CATCH
SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
INSERT @res VALUES(CASE WHEN @srcLeft=6 THEN 'PASS' ELSE 'FAIL' END,N'T6',N'gate-blocked run deleted nothing (source 6)',CONCAT(N'srcLeft=',@srcLeft));
UPDATE arch.ProcessKeySpec SET SourceExpressionSql = N't.DocId' WHERE ProcessId=@pidT AND KeyOrdinal=1;
UPDATE arch.ObjectSpec SET JoinToAnchorPredicateSql = N't.DocId = k.Key1' WHERE ProcessId=@pidT;

/* =========================== T7: runtime safe-expression gate (THROW 50400) =========================== */
-- A direct table write (bypassing the Save* API validation) plants a statement terminator in
-- AdditionalWhereSql; the runner must refuse to concatenate it (DryRun included - the candidate
-- scan would execute it too).
IF OBJECT_ID(N'arch.usp_AssertSafeSqlExpression',N'P') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql @reseed;
    UPDATE arch.ObjectSpec SET AdditionalWhereSql = N'1=1; DELETE FROM vtest.DOCS --' WHERE ProcessId=@pidT;
    BEGIN TRY
        EXEC arch.usp_RunTimestampProcess @ProcessCode=@pcT,@SourceDb=@db,@ArchiveDb=@db,@MaxRows=100,@DryRun=1;
        INSERT @res VALUES('FAIL',N'T7',N'runtime safe-expr gate blocks injected fragment (50400)',N'run was NOT blocked');
    END TRY
    BEGIN CATCH
        INSERT @res SELECT CASE WHEN ERROR_NUMBER()=50400 THEN 'PASS' ELSE 'FAIL' END,
            N'T7',N'runtime safe-expr gate blocks injected fragment (50400)',CONCAT(N'errno=',ERROR_NUMBER(),N' ',LEFT(ERROR_MESSAGE(),140));
    END CATCH
    SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
    INSERT @res VALUES(CASE WHEN @srcLeft=6 THEN 'PASS' ELSE 'FAIL' END,N'T7',N'gate-blocked run touched nothing (source 6)',CONCAT(N'srcLeft=',@srcLeft));
    UPDATE arch.ObjectSpec SET AdditionalWhereSql = N't.Created IS NOT NULL' WHERE ProcessId=@pidT;
END
ELSE INSERT @res VALUES('SKIP',N'T7',N'runtime safe-expr gate (046 not deployed)',N'usp_AssertSafeSqlExpression missing');

/* =========================== T8: cheap-mode candidate selection (no per-row AT TIME ZONE) =========================== */
-- High-volume path: CandidateSelectExpr (cheap LOCAL expr) + sargable CandidateWhereSql cutoff (converts
-- @CutoffUtc to local ONCE); the per-row AT TIME ZONE residual is SKIPPED. Must still archive exactly the
-- eligible rows with Divergence=0. (Synthetic Created is datetime; correctness check, not a perf check.)
EXEC sys.sp_executesql @reseed;
UPDATE arch.ObjectSpec SET CandidateSelectExpr = N'CONVERT(datetime2(0), t.Created)' WHERE ProcessId=@pidT;
UPDATE arch.Process SET
    CandidateWhereSql = N't.Created < CONVERT(datetime2(0), (@CutoffUtc AT TIME ZONE N''UTC'') AT TIME ZONE N''Central European Standard Time'')',
    CandidateOrderSql = N't.Created'
WHERE ProcessId=@pidT;
EXEC arch.usp_RunTimestampProcess @ProcessCode=@pcT,@SourceDb=@db,@ArchiveDb=@db,@MaxRows=100,@DryRun=0;
SELECT @riid=(SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pidT ORDER BY ri.RunItemId DESC);
SELECT @arch=ISNULL(SUM(RowsArchived),0),@del=ISNULL(SUM(RowsDeleted),0) FROM arch.RunItemObject WHERE RunItemId=@riid;
SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
SET @arcRows=0; IF OBJECT_ID(N'vtest_arch.DOCS') IS NOT NULL EXEC sys.sp_executesql @arcCountSql,N'@n int OUTPUT',@n=@arcRows OUTPUT;
SELECT @status=Status FROM arch.RunItem WHERE RunItemId=@riid;
INSERT @res VALUES(CASE WHEN @status=N'OK' AND @del=3 AND @arch=3 AND @srcLeft=3 AND @arcRows=3 THEN 'PASS' ELSE 'FAIL' END,N'T8',N'cheap-mode candidate (no per-row AT TIME ZONE): 3 archived=3 deleted, Divergence=0',CONCAT(N'status=',@status,N' arch=',@arch,N' del=',@del,N' srcLeft=',@srcLeft));
UPDATE arch.ObjectSpec SET CandidateSelectExpr = NULL WHERE ProcessId=@pidT;
UPDATE arch.Process SET CandidateWhereSql = NULL, CandidateOrderSql = N'DocCreatedAt, Key1' WHERE ProcessId=@pidT;

/* =========================== T9: cheap-mode config validation (usp_ValidateConfiguration WARN/INFO) =========================== */
-- Rule A (WARN): CandidateSelectExpr set without a sargable CandidateWhereSql -> cheap-mode cannot activate.
-- Rule B (INFO): both set -> cheap-mode active, remind to verify the time-column format is ISO-chronological.
DECLARE @vfind table (Severity varchar(10), ProcessCode sysname NULL, SourceDb sysname NULL, ArchiveDb sysname NULL, ObjectName nvarchar(300) NULL, Finding nvarchar(4000), SuggestedSql nvarchar(max) NULL);
DECLARE @warnCnt int, @infoCnt int;
-- 9a: projection set, cutoff missing -> WARN must fire
UPDATE arch.ObjectSpec SET CandidateSelectExpr = N'CONVERT(datetime2(0), t.Created)' WHERE ProcessId=@pidT;
UPDATE arch.Process SET CandidateWhereSql = NULL WHERE ProcessId=@pidT;
DELETE @vfind; INSERT @vfind EXEC arch.usp_ValidateConfiguration @ProcessCode=@pcT, @SourceDb=@db;
SELECT @warnCnt = COUNT(*) FROM @vfind WHERE Severity='WARN' AND Finding LIKE N'%cheap-mode candidate selection will NOT activate%';
INSERT @res VALUES(CASE WHEN @warnCnt>=1 THEN 'PASS' ELSE 'FAIL' END,N'T9',N'validation WARNs CandidateSelectExpr set without CandidateWhereSql',CONCAT(N'warn=',@warnCnt));
-- 9b: add the sargable cutoff -> WARN clears, INFO (cheap-mode active) appears
UPDATE arch.Process SET CandidateWhereSql = N't.Created < CONVERT(datetime2(0), (@CutoffUtc AT TIME ZONE N''UTC'') AT TIME ZONE N''Central European Standard Time'')' WHERE ProcessId=@pidT;
DELETE @vfind; INSERT @vfind EXEC arch.usp_ValidateConfiguration @ProcessCode=@pcT, @SourceDb=@db;
SELECT @warnCnt = COUNT(*) FROM @vfind WHERE Severity='WARN' AND Finding LIKE N'%cheap-mode candidate selection will NOT activate%';
SELECT @infoCnt = COUNT(*) FROM @vfind WHERE Severity='INFO' AND Finding LIKE N'%Cheap-mode candidate selection is active%';
INSERT @res VALUES(CASE WHEN @warnCnt=0 AND @infoCnt>=1 THEN 'PASS' ELSE 'FAIL' END,N'T9',N'WARN clears + INFO appears when cheap-mode fully configured',CONCAT(N'warn=',@warnCnt,N' info=',@infoCnt));
UPDATE arch.ObjectSpec SET CandidateSelectExpr = NULL WHERE ProcessId=@pidT;
UPDATE arch.Process SET CandidateWhereSql = NULL, CandidateOrderSql = N'DocCreatedAt, Key1' WHERE ProcessId=@pidT;

/* =========================== T10: timezone-name validity (T-23: WARN on a zone not in sys.time_zone_info) =========================== */
DECLARE @savTs nvarchar(4000) = (SELECT TimestampExpr FROM arch.ObjectSpec WHERE ProcessId=@pidT);
UPDATE arch.ObjectSpec SET TimestampExpr = N'CAST(t.Created AS datetime2) AT TIME ZONE N''Totally Bogus Zone'' AT TIME ZONE N''UTC''' WHERE ProcessId=@pidT;
DELETE @vfind; INSERT @vfind EXEC arch.usp_ValidateConfiguration @ProcessCode=@pcT, @SourceDb=@db;
SELECT @warnCnt = COUNT(*) FROM @vfind WHERE Severity='WARN' AND Finding LIKE N'%not in sys.time_zone_info%';
INSERT @res VALUES(CASE WHEN @warnCnt>=1 THEN 'PASS' ELSE 'FAIL' END,N'T10',N'validation WARNs unresolvable AT TIME ZONE name (T-23)',CONCAT(N'warn=',@warnCnt));
UPDATE arch.ObjectSpec SET TimestampExpr = @savTs WHERE ProcessId=@pidT;

/* =========================== T10b: defensive TimestampExpr WARN (mixed-format / language hazard) =========================== */
-- A hard CAST/CONVERT (no TRY_) on a TIMESTAMP source THROWs on English month-name text dates under a
-- non-us_english session -> WARN. A defensive TRY_CONVERT (+ TRY_PARSE ... USING 'en-US') clears it.
DECLARE @savTs2 nvarchar(4000) = (SELECT TimestampExpr FROM arch.ObjectSpec WHERE ProcessId=@pidT);
UPDATE arch.ObjectSpec SET TimestampExpr = N'CAST(t.Created AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''' WHERE ProcessId=@pidT;
DELETE @vfind; INSERT @vfind EXEC arch.usp_ValidateConfiguration @ProcessCode=@pcT, @SourceDb=@db;
SELECT @warnCnt = COUNT(*) FROM @vfind WHERE Severity='WARN' AND Finding LIKE N'%hard CAST/CONVERT%';
INSERT @res VALUES(CASE WHEN @warnCnt>=1 THEN 'PASS' ELSE 'FAIL' END,N'T10b',N'validation WARNs hard CAST/CONVERT TimestampExpr (mixed-format/language hazard)',CONCAT(N'warn=',@warnCnt));
UPDATE arch.ObjectSpec SET TimestampExpr = N'COALESCE(TRY_CONVERT(datetime2, t.Created), TRY_PARSE(t.Created AS datetime2 USING N''en-US'')) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''' WHERE ProcessId=@pidT;
DELETE @vfind; INSERT @vfind EXEC arch.usp_ValidateConfiguration @ProcessCode=@pcT, @SourceDb=@db;
SELECT @warnCnt = COUNT(*) FROM @vfind WHERE Severity='WARN' AND Finding LIKE N'%hard CAST/CONVERT%';
INSERT @res VALUES(CASE WHEN @warnCnt=0 THEN 'PASS' ELSE 'FAIL' END,N'T10b',N'WARN clears when TimestampExpr is defensive (TRY_CONVERT/TRY_PARSE)',CONCAT(N'warn=',@warnCnt));
UPDATE arch.ObjectSpec SET TimestampExpr = @savTs2 WHERE ProcessId=@pidT;

/* =========================== R1: restore (un-archive) round-trip (T-27) =========================== */
EXEC sys.sp_executesql @reseed;
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=@pcA,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@MaxCandidates=100;  -- archive+delete 3
SELECT @srcLeft=COUNT(*) FROM vtest.DOCS;
EXEC arch.usp_RestoreFromArchive @ProcessCode=@pcA,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@PurgeArchive=0,@RequestedBy=N'vtest';
DECLARE @srcAfter int = (SELECT COUNT(*) FROM vtest.DOCS);
INSERT @res VALUES(CASE WHEN @srcLeft=3 AND @srcAfter=6 THEN 'PASS' ELSE 'FAIL' END,N'R1',N'restore round-trip brought 3 rows back (3 -> 6)',CONCAT(N'beforeRestore=',@srcLeft,N' afterRestore=',@srcAfter));

/* =========================== S1: stop request + audit (T-10) =========================== */
-- Synthesize a RUNNING run and request a stop; assert it stamps cancel + who/why, first-writer-wins.
IF OBJECT_ID(N'arch.usp_Api_RequestRunStop',N'P') IS NOT NULL
BEGIN
    DECLARE @fakeRun bigint;
    INSERT arch.Run (StartedAt,Status,SourceDb,ArchiveDb,HostName,AppName,InitiatedBy)
    VALUES (SYSUTCDATETIME(),N'RUNNING',@db,@db,N'vtest',N'vtest',N'vtest');
    SET @fakeRun = SCOPE_IDENTITY();
    EXEC arch.usp_Api_RequestRunStop @RunId=@fakeRun, @RequestedBy=N'alice', @Reason=N'first reason';
    EXEC arch.usp_Api_RequestRunStop @RunId=@fakeRun, @RequestedBy=N'bob',   @Reason=N'second reason';  -- first-writer-wins
    DECLARE @cBy nvarchar(256), @cReason nvarchar(400), @cAt datetime2(0);
    SELECT @cAt=CancelRequestedAtUtc, @cBy=CancelRequestedBy, @cReason=CancelReason FROM arch.Run WHERE RunId=@fakeRun;
    INSERT @res VALUES(CASE WHEN @cAt IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,N'S1',N'stop stamped CancelRequestedAtUtc',CONCAT(N'at=',CONVERT(nvarchar(30),@cAt)));
    INSERT @res VALUES(CASE WHEN @cBy=N'alice' AND @cReason=N'first reason' THEN 'PASS' ELSE 'FAIL' END,N'S1',N'stop audit first-writer-wins (alice/first reason)',CONCAT(N'by=',@cBy,N' reason=',@cReason));
    DELETE FROM arch.Run WHERE RunId=@fakeRun;
END
ELSE INSERT @res VALUES('SKIP',N'S1',N'stop (040 not deployed)',N'usp_Api_RequestRunStop missing');

/* =========================== teardown + report =========================== */
EXEC sys.sp_executesql @cleanup;
INSERT @res VALUES(CASE WHEN OBJECT_ID(N'vtest.DOCS') IS NULL AND SCHEMA_ID(N'vtest') IS NULL
                        AND NOT EXISTS (SELECT 1 FROM arch.Process WHERE ProcessCode IN (@pcA,@pcT)) THEN 'PASS' ELSE 'FAIL' END,
    N'--',N'teardown removed synthetic objects + config',N'');

SELECT Result, Variant, Check_, Detail FROM @res ORDER BY Seq;
IF EXISTS (SELECT 1 FROM @res WHERE Result='FAIL')
    SELECT 'FAIL' AS Overall, CONCAT(N'',(SELECT COUNT(*) FROM @res WHERE Result='FAIL'),N' check(s) failed') AS Summary;
ELSE
    SELECT 'PASS' AS Overall, N'ALL VARIANTS PASSED (ANCHOR/TIMESTAMP x Mode 0/1/2, DryRun, audit levels, retention floor, legal-hold, TZ gate, cheap-mode + its config validation, timezone-name validation, restore, stop-audit).' AS Summary;
