/* ============================================================================
   verify_clean_deploy.sql — assert a CLEAN v2 deploy: prod objects present, nothing extra.
   READ-ONLY. Run against kArchiveManagerAdmin after deploy_clean_v2_full.sql.
   Any row with Result='FAIL' is a problem. ============================================================================ */
SET NOCOUNT ON;
USE [kArchiveManagerAdmin];

DECLARE @chk TABLE (Result char(4), Check_ nvarchar(200), Detail nvarchar(2000));

/* ---- MUST NOT EXIST (clean install carries no v1 / relics / smoke) ---- */
INSERT @chk SELECT 'FAIL', N'legacy_v1 schema present', N''
WHERE SCHEMA_ID(N'legacy_v1') IS NOT NULL;

INSERT @chk
SELECT 'FAIL', N'v1 / stub procedure present in arch', name
FROM sys.objects
WHERE type='P' AND SCHEMA_NAME(schema_id)='arch'
  AND name IN (N'usp_RunAll',N'usp_RunConfiguredProcesses',N'usp_RunWorkBatch',N'usp_RunWorkBatches_InWindow',
               N'usp_PrepWorkBatch_Receiving',N'usp_PrepWorkBatch_Shipping',N'usp_CaptureRowCountSnapshot',
               N'usp_EstimateWorkBatchImpact',N'usp_EstimateLatestWorkBatchImpact',N'usp_EstimateCurrentProcessImpact_RF_LOG2',
               N'usp_RunScheduledProfiles_Prepared',N'usp_RunProcess',N'usp_RunProcess_RF_LOG2',N'usp_RunProcess_TimestampKeyset');

INSERT @chk
SELECT 'FAIL', N'relic table present', name
FROM sys.tables
WHERE SCHEMA_NAME(schema_id)='arch' AND (name='RowCountSnapshot' OR name LIKE '%[_]Backup[_]%');

INSERT @chk
SELECT 'FAIL', N'smoke/test process seeded', ProcessCode
FROM arch.Process WHERE ProcessCode LIKE '%OSTRY_SMOKE%' OR ProcessCode LIKE 'WA_AAD%';

/* ---- MUST EXIST (core prod objects) ---- */
INSERT @chk
SELECT 'FAIL', N'expected table missing', t.n
FROM (VALUES (N'Process'),(N'ProcessDatabase'),(N'ObjectSpec'),(N'ObjectSpecDatabaseOverride'),(N'ProcessKeySpec'),
             (N'IndexRequirement'),(N'RunProfile'),(N'SelectionStrategy'),(N'Run'),(N'RunItem'),(N'RunItemObject'),
             (N'RunDocAudit'),(N'WorkBatch'),(N'WorkBatchKey'),(N'ConfigChangeSet'),(N'ConfigChangeField'),
             (N'ConfigChangeItem'),(N'ArchiveProvisionLog'),(N'RestoreAudit'),(N'RunnerPrivilegeInventory'),
             (N'RetentionPolicy'),(N'LegalHold')) t(n)
WHERE OBJECT_ID(N'arch.'+t.n,N'U') IS NULL;

INSERT @chk
SELECT 'FAIL', N'expected view missing', v.n
FROM (VALUES (N'v_ProcessDatabaseEffective'),(N'v_ObjectSpecDatabaseEffective'),(N'v_LastRunPerProcess'),
             (N'v_RunItemsRecent'),(N'v_OperationalHealth')) v(n)
WHERE OBJECT_ID(N'arch.'+v.n,N'V') IS NULL;

INSERT @chk
SELECT 'FAIL', N'expected procedure missing', p.n
FROM (VALUES (N'usp_RunProfile_Prepared'),(N'usp_RunConfiguredProcesses_Prepared'),(N'usp_RunPreparedBatch'),
             (N'usp_RunPreparedBatches_InWindow'),(N'usp_RunTimestampProcess'),(N'usp_PrepareCandidates'),
             (N'usp_RecoverStaleRuns'),(N'usp_RestoreFromArchive'),(N'usp_Api_RequestRunStop'),
             (N'usp_AssertSafeSqlExpression'),(N'usp_AssertTimezonePolicyApplied'),(N'usp_EnsureArchiveTableLikeSource'),
             (N'usp_GetOutputColumns'),(N'usp_ValidateConfiguration'),(N'usp_Api_SaveProcess'),
             (N'usp_Api_SaveProcessDatabase'),(N'usp_Api_SaveObjectSpec'),(N'usp_Api_FinalizeConfigChangeSet'),
             (N'usp_Frontend_GetRecentRuns'),(N'usp_Frontend_GoLiveReadiness'),(N'usp_Frontend_TimestampRetentionGaps'),
             (N'usp_VerifyRunnerPrivileges'),(N'usp_CaptureRunnerPrivilegeInventory'),
             (N'usp_AssertRetentionFloor'),(N'usp_Api_AddLegalHold'),(N'usp_Api_ReleaseLegalHold'),
             (N'usp_Api_SetRetentionFloor'),(N'usp_Frontend_GetLegalHolds'),(N'usp_GetCopyDedupInfo')) p(n)
WHERE OBJECT_ID(N'arch.'+p.n,N'P') IS NULL;

/* ---- Admin Console runtime API surface — MUST match ReadinessService.requiredObjects ----
   Guards against bundle drift: a proc that /api/readiness requires but the clean bundle
   forgot to create (this is exactly what produced the console "Missing objects:
   usp_Api_CheckConfigConcurrency" / DB-check warning). Keep this list in sync with
   admin-console/.../Data/ReadinessService.cs. */
INSERT @chk
SELECT 'FAIL', N'readiness-required API proc missing', p.n
FROM (VALUES (N'usp_Frontend_GetProcessConfigSummary'),(N'usp_Frontend_GetEffectiveProcessDatabases'),
             (N'usp_Frontend_GetEffectiveObjects'),(N'usp_Frontend_GetTableMovementCounts'),
             (N'usp_Frontend_GetProcessMovementSummary'),(N'usp_Frontend_GetProcessedHistory'),
             (N'usp_Frontend_GetWorkBatchActivity'),(N'usp_Frontend_GetRecentRuns'),
             (N'usp_Frontend_GetRunDetail'),(N'usp_Frontend_SearchDocumentAuditSummary'),
             (N'usp_Frontend_SearchDocumentAuditDetails'),(N'usp_Frontend_GetProcessKeySpecs'),
             (N'usp_Frontend_GetIndexRequirements'),(N'usp_Frontend_GetRunProfiles'),
             (N'usp_Frontend_GetSelectionStrategies'),(N'usp_Frontend_GetConfigChangeHistory'),
             (N'usp_Api_ValidateConfiguration'),(N'usp_Api_ValidateIndexRequirements'),
             (N'usp_Api_ExplainProcessPlan'),(N'usp_Api_SaveProcess'),(N'usp_Api_SaveProcessDatabase'),
             (N'usp_Api_SaveObjectSpec'),(N'usp_Api_SaveObjectSpecOverride'),(N'usp_Api_SaveRunProfile'),
             (N'usp_Api_SaveProcessKeySpec'),(N'usp_Api_SaveIndexRequirement'),(N'usp_Api_CheckConfigConcurrency'),
             (N'usp_Api_SetProcessEnabled'),(N'usp_Api_SetProcessDatabaseEnabled'),
             (N'usp_Api_SetObjectOverrideEnabled'),(N'usp_Api_SetRunProfileEnabled'),
             (N'usp_Api_RequestRunStop')) p(n)
WHERE OBJECT_ID(N'arch.'+p.n,N'P') IS NULL;

INSERT @chk
SELECT 'FAIL', N'expected role missing', r.n
FROM (VALUES (N'karch_viewer'),(N'karch_operator'),(N'karch_config_admin'),(N'karch_advanced_admin'),(N'karch_approver'),
             (N'karch_runtime')) r(n)
WHERE DATABASE_PRINCIPAL_ID(r.n) IS NULL;

INSERT @chk
SELECT 'FAIL', N'expected Run column missing (T-03/cancel)', c.n
FROM (VALUES (N'CancelRequestedAtUtc'),(N'CancelRequestedBy'),(N'CancelReason'),(N'WorkerSessionId'),(N'WorkerSessionLoginTimeUtc')) c(n)
WHERE COL_LENGTH(N'arch.Run', c.n) IS NULL;

/* ---- Grants + immutability (T-02 / T-09) ---- */
INSERT @chk
SELECT 'FAIL', N'grant missing: usp_Api_RequestRunStop -> karch_operator', N''
WHERE NOT EXISTS (SELECT 1 FROM sys.database_permissions pm JOIN sys.database_principals pr ON pr.principal_id=pm.grantee_principal_id
    WHERE pm.major_id=OBJECT_ID('arch.usp_Api_RequestRunStop') AND pm.permission_name='EXECUTE' AND pm.state_desc='GRANT' AND pr.name='karch_operator');

INSERT @chk
SELECT 'FAIL', N'grant missing: usp_RestoreFromArchive -> karch_advanced_admin', N''
WHERE NOT EXISTS (SELECT 1 FROM sys.database_permissions pm JOIN sys.database_principals pr ON pr.principal_id=pm.grantee_principal_id
    WHERE pm.major_id=OBJECT_ID('arch.usp_RestoreFromArchive') AND pm.permission_name='EXECUTE' AND pm.state_desc='GRANT' AND pr.name='karch_advanced_admin');

INSERT @chk
SELECT 'FAIL', N'audit immutability DENY missing on RunDocAudit', N''
WHERE NOT EXISTS (SELECT 1 FROM sys.database_permissions WHERE major_id=OBJECT_ID('arch.RunDocAudit') AND permission_name IN ('UPDATE','DELETE') AND state_desc='DENY');

/* ---- report ---- */
IF EXISTS (SELECT 1 FROM @chk)
    SELECT Result, Check_, Detail FROM @chk ORDER BY Check_;
ELSE
    SELECT 'PASS' AS Result, N'Clean deploy verified: all expected objects present, no v1/relics/smoke.' AS Check_;
