-- ============================================================================
-- kArchiveManager 2.0 — CLEAN customer deploy (full v2, audit-hardened)
-- ============================================================================
-- Builds EXACTLY the production v2 object set on a fresh server. Pure v2:
--   * NO legacy_v1 schema, NO v1 procedures, NO v1 THROW-stub tombstones
--   * NO relic tables (RowCountSnapshot, *_Backup_*)
--   * NO smoke/test seed (WA_AAD_*_OSTRY_SMOKE)
--   * DB-specific process/mapping SEED is DEFERRED (customer DB names unknown) — see the separate
--     customer-seed step; this bundle only creates objects + the role model + the SelectionStrategy enum.
-- Includes all audit fixes (T-01..T-19, T-08, restore rowversion). SSMS: enable Query -> SQLCMD Mode.
-- Set Root to the ArchiveManager1.0 folder. Run verify_clean_deploy.sql afterwards (expects PASS).
--
-- ✅ VALIDATED end-to-end on a FRESH empty database (SQL Server 2019 LocalDB, 2026-06-04): deploys
--    Phases 0-13 with zero errors and verify_clean_deploy.sql returns PASS (all expected objects,
--    no v1/relics/smoke). Phase 14 jobs require SQL Agent (not present on LocalDB) — validate on a
--    real Agent-enabled instance.
-- NOTE: intended for a FRESH/empty kArchiveManagerAdmin. The Tables\ scripts use plain CREATE TABLE
--    (not IF-guarded), so RE-running on an already-populated DB errors on existing tables; for an
--    existing environment use the per-object update scripts instead of this whole-DB bundle.
-- ============================================================================
:setvar Root "C:\CHANGE_ME\ArchiveManager1.0"
:on error exit
PRINT 'kArchiveManager 2.0 CLEAN deploy started. Root=$(Root)';
GO

-- ---- Phase 0: databases (control DB + archive DB shell) ----
:r "$(Root)\Databases\create_kArchiveManagerAdmin.sql"
GO
:r "$(Root)\Databases\create_kArchiveManagerBackups.sql"
GO

-- ---- Phase 1: schema ----
:r "$(Root)\kArchiveManagerAdmin\schemas\arch.sql"
GO

-- ---- Phase 2: base tables (RowCountSnapshot relic intentionally OMITTED) ----
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.Process.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.ObjectSpec.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.ProcessDatabase.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.ObjectSpecDatabaseOverride.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.RunProfile.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.WorkBatch.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.WorkBatchKey.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.Run.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.RunItem.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.RunItemObject.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.RunDocAudit.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\Tables\arch.ArchiveProvisionLog.sql"
GO

-- ---- Phase 3: v2 upgrade shims + core (creates ProcessKeySpec/IndexRequirement/SelectionStrategy
--               + seeds the SelectionStrategy enum) ----
:r "$(Root)\kArchiveManagerAdmin\v2\001_upgrade_to_2_0.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\010_universal_archive_core.sql"
GO
-- 001 creates the v1-era arch.RowCountSnapshot metrics table (only the quarantined v1
-- usp_CaptureRowCountSnapshot used it); 010's references to it are all OBJECT_ID-guarded no-ops.
-- Drop it so the clean install carries no relic table.
USE [kArchiveManagerAdmin];
GO
DROP TABLE IF EXISTS [arch].[RowCountSnapshot];
GO

-- ---- Phase 4: change-set / audit tables + changeset procs (frontend/004 creates ConfigChange*) ----
:r "$(Root)\kArchiveManagerAdmin\frontend\004_frontend_audit.sql"
GO

-- ---- Phase 5: Run column extensions REQUIRED by the runner procs below ----
--   040 adds Run.CancelRequestedAtUtc + 'STOPPED' CK + usp_Api_RequestRunStop (its role grant is
--   guarded and re-applied in Phase 13 once roles exist); 044 adds Run.WorkerSessionId/LoginTime.
:r "$(Root)\kArchiveManagerAdmin\v2\040_run_cancel_support.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\044_run_liveness_tracking.sql"
GO

-- ---- Phase 6: indexes ----
:r "$(Root)\kArchiveManagerAdmin\indexes\Indexes.sql"
GO

-- ---- Phase 7: views (effective config, monitoring, operational health) ----
:r "$(Root)\kArchiveManagerAdmin\v2\022_effective_database_overrides.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\023_monitoring_views.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\024_operational_maintenance.sql"
GO

-- ---- Phase 8: provisioning + validation helper procs (GetOutputColumns BEFORE 042 restore) ----
:r "$(Root)\kArchiveManagerAdmin\procedures\arch.usp_GetOutputColumns.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\procedures\arch.usp_EnsureArchiveTableLikeSource.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\procedures\arch.usp_ProvisionArchiveTablesForProcess.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\procedures\arch.usp_ValidateConfiguration.sql"
GO

-- ---- Phase 9: safe-expression validator (BEFORE the frontend save procs that call it) ----
:r "$(Root)\kArchiveManagerAdmin\v2\046_safe_expression_validator.sql"
GO

-- ---- Phase 10: runner chain + gates (035 TZ gate BEFORE 015/027 which call it) ----
:r "$(Root)\kArchiveManagerAdmin\v2\035_usp_AssertTimezonePolicyApplied.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\011_usp_ValidateIndexRequirements.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\012_usp_ExplainProcessPlan.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\014_usp_PrepareCandidates.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\015_usp_RunPreparedBatch.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\027_usp_RunTimestampProcess.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\016_usp_RunPreparedBatches.sql"        -- also creates usp_RunConfiguredProcesses_Prepared
GO
:r "$(Root)\kArchiveManagerAdmin\v2\020_usp_RunProfile_Prepared.sql"        -- creates usp_RunProfile_Prepared (+ dead usp_RunScheduledProfiles_Prepared, dropped next)
GO
-- 020 also creates usp_RunScheduledProfiles_Prepared, a superseded scheduler with NO callers
-- (the RUN CONFIGURED job calls usp_RunProfile_Prepared directly). Drop it so the clean install
-- carries nothing extra.
USE [kArchiveManagerAdmin];
GO
DROP PROCEDURE IF EXISTS [arch].[usp_RunScheduledProfiles_Prepared];
GO
:r "$(Root)\kArchiveManagerAdmin\v2\030_usp_RecoverStaleRuns.sql"
GO

-- ---- Phase 11: restore (after GetOutputColumns) + audit immutability DENY ----
:r "$(Root)\kArchiveManagerAdmin\v2\042_usp_RestoreFromArchive.sql"         -- guarded grant re-applied in Phase 13
GO
:r "$(Root)\kArchiveManagerAdmin\v2\045_audit_immutability.sql"
GO

-- ---- Phase 12: Admin Console API procs (Api_* / Frontend_*) ----
:r "$(Root)\kArchiveManagerAdmin\frontend\001_frontend_read_api.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\frontend\002_frontend_lookup_validation_api.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\frontend\003_frontend_config_lookup_api.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\frontend\005_frontend_process_write_api.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\frontend\006_frontend_object_write_api.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\frontend\007_frontend_enable_disable_api.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\frontend\008_frontend_run_profile_write_api.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\frontend\009_frontend_advanced_config_write_api.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\049_golive_readiness.sql"        -- arch.usp_Frontend_GoLiveReadiness (go-live gate)
GO
:r "$(Root)\kArchiveManagerAdmin\v2\050_timestamp_retention_gaps.sql"   -- arch.usp_Frontend_TimestampRetentionGaps (T-20 retention-gap visibility)
GO
:r "$(Root)\kArchiveManagerAdmin\v2\060_estimate_next_run_impact.sql"   -- arch.usp_Api_EstimateNextRunImpact (next-run MB/row sizing estimate, "Analýza a odhady")
GO
:r "$(Root)\kArchiveManagerAdmin\v2\061_console_operators.sql"          -- arch.ConsoleOperator + DB-managed Console operators API
GO
:r "$(Root)\kArchiveManagerAdmin\v2\062_console_login_audit.sql"        -- arch.ConsoleLoginAudit + record/get console login API (Configuration "Poslední přihlášení" panel)
GO

-- ---- Phase 12b: frontend concurrency proc (optimistic-concurrency for ObjectSpec edits) ----
-- Creates arch.usp_Api_CheckConfigConcurrency (required by ReadinessService) + idempotent
-- ObjectSpec CreatedAt/ModifiedAt columns + ModifiedAt trigger. The v_ObjectSpecDatabaseEffective
-- VIEW that projects these columns is owned solely by v2/022 (single source of truth); this script
-- does NOT re-create it. Runs AFTER 022 (view) and BEFORE frontend/010 (so 010's grant finds the proc).
:r "$(Root)\deploy\v2\33_update_frontend_concurrency_metadata.sql"
GO

-- ---- Phase 13: role model + EXECUTE grants (AFTER all procs exist) ----
:r "$(Root)\kArchiveManagerAdmin\frontend\010_frontend_security_roles.sql"
GO

-- ---- Phase 13b: re-apply the guarded stop/restore grants now that the roles exist ----
USE [kArchiveManagerAdmin];
GO
IF DATABASE_PRINCIPAL_ID(N'karch_operator') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Api_RequestRunStop] TO [karch_operator];
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_RestoreFromArchive] TO [karch_advanced_admin];
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GoLiveReadiness] TO [karch_viewer];
GO

-- ---- Phase 13c: T-33 runtime least-privilege role + runner-privilege verify/inventory ----
-- (after the karch_* roles exist; the customer runner login + cross-DB grants are applied by the
--  parameterized add-on deploy\v2\053_runtime_least_privilege_principal.sql, then deploy\v2\054.)
:r "$(Root)\kArchiveManagerAdmin\v2\055_runtime_runner_role_and_verify.sql"
GO
-- T-21: retention floor + legal-hold (gate proc + register; runners 014/015/027 enforce it).
:r "$(Root)\kArchiveManagerAdmin\v2\056_retention_floor_and_legal_hold.sql"
GO
-- Mode=2 copy-only (idempotent backup, no delete): Mode CHECK widen + dedup helper (runners 015/027 honor it).
:r "$(Root)\kArchiveManagerAdmin\v2\057_copy_only_mode.sql"
GO

-- ---- Phase 14: SQL Agent jobs (RUN CONFIGURED ships DISABLED; RECOVER STALE RUNS enabled) ----
:r "$(Root)\kArchiveManagerAdmin\v2\036_install_recover_stale_runs_job.sql"
GO
:r "$(Root)\kArchiveManagerAdmin\v2\SQL job - RUN CONFIGURED.sql"
GO
-- PREP job (two-phase front-load, ships DISABLED) + Console job-control API (usp_Api_*AgentJob*).
-- The msdb privilege grant for the console login is the parameterized add-on deploy\v2\059.
:r "$(Root)\kArchiveManagerAdmin\v2\058_agent_job_control.sql"
GO
-- ---- Phase 14b: Console "Apply fix" (self-contained: usp_ValidateConfiguration w/ ActionKey findings +
--       usp_Api_ValidateConfiguration wrapper passthrough + usp_Api_ApplyConfigFix + grants). Placed after
--       the Phase-13 role model so its guarded EXECUTE grants resolve; without this the Validation
--       screen's one-click "Apply fix" backend proc (usp_Api_ApplyConfigFix) would be absent. ----
:r "$(Root)\kArchiveManagerAdmin\v2\063_console_apply_config_fix.sql"
GO
-- ---- Phase 14c: legal-hold + retention-floor console surface (getter + grants to the elevated console
--       role so L2 operators can place/release holds and set the floor from the console). After roles. ----
:r "$(Root)\kArchiveManagerAdmin\v2\066_legal_hold_console.sql"
GO
-- Operational add-ons are PARAMETERIZED (fill CHANGE-ME) and OPTIONAL — run separately after config:
--   deploy\v2\047_operational_alerting.sql   (Database Mail + failure alerting, T-14)
--   deploy\v2\048_archive_db_backup.sql       (archive DB FULL+LOG backup jobs, T-16)
-- REQUIRED post-deploy (parameterized): seed the default Admin Console operator so someone can log in —
--   kArchiveManagerAdmin\v2\064_console_default_operator.sql
--     1) run: KArchiveManager.AdminConsole.Api.exe hash-password "<password>"
--     2) paste the PBKDF2 value into 064 (replacing CHANGE-ME), then run it. Creates the 'admin'
--        default (sa-like, disable after creating real operators). The console starts but nobody can
--        edit Configuration/Validation/Go-live until at least one enabled operator exists.

-- ---- DEFERRED (run when customer DB names are known) ----
--   Real-process SEED: Process templates + ObjectSpec + ProcessKeySpec + ProcessDatabase mappings +
--   RunProfile + IndexRequirement + AT-TIME-ZONE cutoff exprs (v2/013,017,018,019,021,031,033,034 and/or
--   Admin Console). EXCLUDED here so the bundle creates objects only, no DB-specific test data.
--   Source-DB performance indexes (deploy\v2\37_create_recommended_source_indexes_current.sql) — per source DB.

PRINT 'kArchiveManager 2.0 CLEAN deploy completed.';
PRINT 'Post-deploy checks: 1) verify_clean_deploy.sql (object-set assert), 2) selftest_acceptance.sql';
PRINT '  (turnkey behavioral smoke: synthetic archive+DELETE+restore+audit+TZ-gate on a throwaway';
PRINT '   schema, then self-cleanup — proves the pipeline works here without touching real data).';
GO
