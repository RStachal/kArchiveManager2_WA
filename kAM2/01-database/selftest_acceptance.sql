/* ============================================================================
   kArchiveManager 2.0 — TURNKEY SELF-TEST (acceptance smoke). READ/WRITE but FULLY SELF-CONTAINED:
   builds a synthetic ANCHOR process on a throwaway selftest schema inside kArchiveManagerAdmin,
   runs the REAL archive+DELETE pipeline, asserts the invariants, exercises restore + the timezone
   gate, then tears everything down. Touches NO real data. Re-runnable (cleans up at start + end).
   Returns one result set of checks (any Result='FAIL' = problem).
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_WARNINGS ON;
USE [kArchiveManagerAdmin];

DECLARE @db sysname = DB_NAME();           -- source = archive = this control DB (self-contained)
DECLARE @pc sysname = N'ZZ_SELFTEST';
DECLARE @res TABLE (Seq int IDENTITY(1,1), Result char(4), Check_ nvarchar(200), Detail nvarchar(400));

/* ---------- teardown helper (run at start to clear any residue, and at end) ---------- */
DECLARE @cleanup nvarchar(max) = N'
DECLARE @pid int = (SELECT ProcessId FROM arch.Process WHERE ProcessCode = N''ZZ_SELFTEST'');
IF @pid IS NOT NULL
BEGIN
    DECLARE @rids TABLE (RunId bigint);
    INSERT @rids SELECT RunId FROM arch.Run r WHERE EXISTS (SELECT 1 FROM arch.RunItem ri WHERE ri.RunId=r.RunId AND ri.ProcessId=@pid);
    DELETE a FROM arch.RunDocAudit a JOIN arch.RunItem ri ON ri.RunItemId=a.RunItemId WHERE ri.ProcessId=@pid;
    DELETE rio FROM arch.RunItemObject rio JOIN arch.RunItem ri ON ri.RunItemId=rio.RunItemId WHERE ri.ProcessId=@pid;
    DELETE wbk FROM arch.WorkBatchKey wbk JOIN arch.WorkBatch wb ON wb.WorkBatchId=wbk.WorkBatchId WHERE wb.ProcessId=@pid;
    DELETE FROM arch.WorkBatch WHERE ProcessId=@pid;
    DELETE FROM arch.RunItem WHERE ProcessId=@pid;
    DELETE FROM arch.Run WHERE RunId IN (SELECT RunId FROM @rids);
    DELETE FROM arch.IndexRequirement WHERE ProcessId=@pid;
    DELETE FROM arch.ObjectSpec WHERE ProcessId=@pid;
    DELETE FROM arch.ProcessKeySpec WHERE ProcessId=@pid;
    DELETE FROM arch.ProcessDatabase WHERE ProcessId=@pid;
    DELETE FROM arch.Process WHERE ProcessId=@pid;
END;
DROP TABLE IF EXISTS selftest.SELFTEST_DOCS;
DROP TABLE IF EXISTS selftest_arch.SELFTEST_DOCS;
IF SCHEMA_ID(N''selftest'') IS NOT NULL EXEC(N''DROP SCHEMA selftest'');
IF SCHEMA_ID(N''selftest_arch'') IS NOT NULL EXEC(N''DROP SCHEMA selftest_arch'');';
EXEC sys.sp_executesql @cleanup;

/* ---------- 1) synthetic source table (with a rowversion column to exercise the restore fix) ---------- */
EXEC(N'CREATE SCHEMA selftest');
CREATE TABLE selftest.SELFTEST_DOCS
(
    DocId   int          NOT NULL CONSTRAINT PK_SELFTEST_DOCS PRIMARY KEY,
    Created datetime     NOT NULL,
    Payload nvarchar(100) NULL,
    rv      rowversion   NOT NULL
);
DECLARE @old datetime = DATEADD(DAY, -800, GETDATE());   -- below a 365-day retention -> candidates
DECLARE @new datetime = GETDATE();                        -- above cutoff -> not candidates
INSERT selftest.SELFTEST_DOCS (DocId, Created, Payload) VALUES
    (1,@old,N'old-1'),(2,@old,N'old-2'),(3,@old,N'old-3'),
    (4,@new,N'new-4'),(5,@new,N'new-5'),(6,@new,N'new-6');

/* ---------- 2) configure a synthetic ANCHOR process (AuditLevel=ROW) ---------- */
DECLARE @tz nvarchar(200) = N' AS datetime2) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''';
DECLARE @anchorTs nvarchar(400) = N'CAST(a.Created' + @tz;

INSERT arch.Process (ProcessCode,Description,IsEnabled,Mode,RetentionDays,CutoffSafetyLagMinutes,
    BatchDocCount,BatchRowCount,MaxBatchesPerRun,DelayMsBetweenBatches,UseAppLock,AppLockResource,
    LockTimeoutMs,DeadlockPriority,AnchorSchema,AnchorTable,AnchorDocKeyExpr,AnchorDocKey2Expr,
    AnchorTimestampExpr,AnchorExtraWhereSql,AllowDeleteWithoutArchive,CreatedAt,ModifiedAt,CutoffMode,
    CutoffDate,DocKeyLabel,SelectionStrategy,AuditLevel,RequireSupportingIndex,MaxRowsPerTransaction,
    CandidateWhereSql,CandidateOrderSql)
VALUES (@pc,N'Self-test (throwaway)',1,1,365,0,100,NULL,10,0,0,NULL,10000,N'LOW',N'selftest',
    N'SELFTEST_DOCS',N'a.DocId',NULL,@anchorTs,NULL,0,SYSUTCDATETIME(),SYSUTCDATETIME(),0,NULL,
    N'DocId',N'ANCHOR',N'ROW',0,NULL,NULL,NULL);
DECLARE @pid int = (SELECT ProcessId FROM arch.Process WHERE ProcessCode=@pc);

INSERT arch.ProcessKeySpec (ProcessId,KeyOrdinal,KeyName,SourceExpressionSql,SqlType,IsRequired,CreatedAt,ModifiedAt)
VALUES (@pid,1,N'DocId',N'a.DocId',N'int',1,SYSUTCDATETIME(),SYSUTCDATETIME());

INSERT arch.ObjectSpec (ProcessId,SourceSchema,SourceTable,DeleteOrder,DeleteMode,TimestampExpr,
    JoinToAnchorPredicateSql,AdditionalWhereSql,ArchiveSchema,ArchiveTable,RequireArchiveForDelete,NaturalKeyLabel)
VALUES (@pid,N'selftest',N'SELFTEST_DOCS',10,1,N'CAST(t.Created'+@tz,N't.DocId = k.Key1',NULL,N'selftest_arch',N'SELFTEST_DOCS',1,N'DocId');

INSERT arch.ProcessDatabase (ProcessId,SourceDb,ArchiveDb,IsEnabled,RunOrder,CreatedAt,ModifiedAt)
VALUES (@pid,@db,@db,1,1,SYSUTCDATETIME(),SYSUTCDATETIME());

/* ---------- 3) timezone gate NEGATIVE: a raw (non-UTC-normalized) cutoff must be blocked on a real run ---------- */
UPDATE arch.Process SET AnchorTimestampExpr = N'CAST(a.Created AS datetime2)' WHERE ProcessId=@pid;  -- no AT TIME ZONE
BEGIN TRY
    EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=@pc,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@MaxCandidates=100;
    INSERT @res VALUES('FAIL',N'TZ gate blocks raw cutoff on real run',N'run was NOT blocked');
END TRY
BEGIN CATCH
    INSERT @res SELECT CASE WHEN ERROR_NUMBER()=50200 OR ERROR_MESSAGE() LIKE '%AT TIME ZONE%' OR ERROR_MESSAGE() LIKE '%50200%' THEN 'PASS' ELSE 'FAIL' END,
        N'TZ gate blocks raw cutoff on real run', LEFT(ERROR_MESSAGE(),200);
END CATCH
UPDATE arch.Process SET AnchorTimestampExpr = @anchorTs WHERE ProcessId=@pid;   -- restore UTC-normalized expr

/* ---------- 4) real archive+DELETE run ---------- */
DECLARE @before int = (SELECT COUNT(*) FROM selftest.SELFTEST_DOCS);
EXEC arch.usp_RunConfiguredProcesses_Prepared @ProcessCode=@pc,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@MaxCandidates=100;

DECLARE @riid bigint = (SELECT TOP 1 ri.RunItemId FROM arch.RunItem ri WHERE ri.ProcessId=@pid ORDER BY ri.RunItemId DESC);
DECLARE @arch bigint = (SELECT ISNULL(SUM(RowsArchived),0) FROM arch.RunItemObject WHERE RunItemId=@riid);
DECLARE @del  bigint = (SELECT ISNULL(SUM(RowsDeleted),0)  FROM arch.RunItemObject WHERE RunItemId=@riid);
DECLARE @srcLeft int = (SELECT COUNT(*) FROM selftest.SELFTEST_DOCS);
DECLARE @arcRows int = (SELECT COUNT(*) FROM selftest_arch.SELFTEST_DOCS);
DECLARE @auditRows int = (SELECT COUNT(*) FROM arch.RunDocAudit WHERE RunItemId=@riid);
DECLARE @status nvarchar(20) = (SELECT Status FROM arch.RunItem WHERE RunItemId=@riid);

INSERT @res VALUES('', N'run completed OK', @status);
UPDATE @res SET Result = CASE WHEN @status=N'OK' THEN 'PASS' ELSE 'FAIL' END WHERE Check_=N'run completed OK';
INSERT @res VALUES(CASE WHEN @del=@arch AND @del>0 THEN 'PASS' ELSE 'FAIL' END, N'Mode=1 invariant Divergence=0', CONCAT(N'archived=',@arch,N' deleted=',@del));
INSERT @res VALUES(CASE WHEN @srcLeft=3 THEN 'PASS' ELSE 'FAIL' END, N'old docs deleted from source (3 of 6 remain)', CONCAT(N'remaining=',@srcLeft));
INSERT @res VALUES(CASE WHEN @arcRows=3 THEN 'PASS' ELSE 'FAIL' END, N'old docs copied to archive', CONCAT(N'archiveRows=',@arcRows));
INSERT @res VALUES(CASE WHEN @auditRows=3 THEN 'PASS' ELSE 'FAIL' END, N'AuditLevel=ROW wrote per-doc RunDocAudit', CONCAT(N'auditRows=',@auditRows));

/* ---------- 5) restore round-trip (exercises the rowversion-column fix) ---------- */
EXEC arch.usp_RestoreFromArchive @ProcessCode=@pc,@SourceDb=@db,@ArchiveDb=@db,@DryRun=0,@PurgeArchive=0,@RequestedBy=N'selftest';
DECLARE @srcAfterRestore int = (SELECT COUNT(*) FROM selftest.SELFTEST_DOCS);
INSERT @res VALUES(CASE WHEN @srcAfterRestore=6 THEN 'PASS' ELSE 'FAIL' END, N'restore round-trip (rowversion-safe) brought rows back', CONCAT(N'sourceRows=',@srcAfterRestore));

/* ---------- 6) teardown ---------- */
EXEC sys.sp_executesql @cleanup;
INSERT @res VALUES(CASE WHEN OBJECT_ID(N'selftest.SELFTEST_DOCS') IS NULL AND SCHEMA_ID(N'selftest') IS NULL
                        AND NOT EXISTS (SELECT 1 FROM arch.Process WHERE ProcessCode=@pc) THEN 'PASS' ELSE 'FAIL' END,
    N'teardown removed synthetic objects + config', N'');

/* ---------- report ---------- */
IF EXISTS (SELECT 1 FROM @res WHERE Result='FAIL')
    SELECT Result, Check_, Detail FROM @res ORDER BY Seq;
ELSE
    SELECT 'PASS' AS Result, N'SELF-TEST PASSED: archive+delete+audit+restore+TZ-gate all verified; synthetic objects cleaned up.' AS Check_, N'' AS Detail;
