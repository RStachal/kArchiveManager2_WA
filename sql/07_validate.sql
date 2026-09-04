-- ============================================================================
-- 07 - CONFIGURATION VALIDATION (read-only)
-- ============================================================================
-- Three gates, in increasing order of strictness:
--   1. arch.usp_ValidateConfiguration     - configuration correctness
--   2. arch.usp_ValidateIndexRequirements - declared vs actual supporting indexes
--   3. arch.usp_Frontend_GoLiveReadiness  - operational readiness for real deletes
--
-- PASS CRITERIA
--   * ValidateConfiguration    : 0 ERROR. WARN and INFO are acceptable, but read
--                                them - "archive table does not exist" means you
--                                have not run 06_provision.sql yet.
--   * ValidateIndexRequirements: a missing index is a WARN with SuggestedSql, never
--                                a blocker. On production volume, act on it anyway
--                                (see 08_source_indexes.sql).
--   * GoLiveReadiness          : 0 FAIL. Expect WARNs for alerting and archive-DB
--                                backups until you configure Database Mail (047)
--                                and the backup jobs (048).
--
-- NOTE on the result-set shape: usp_ValidateConfiguration returns EIGHT columns
-- after deploy Phase 14b (v2\063 adds a trailing ActionKey). If you capture it
-- with INSERT ... EXEC, declare eight columns or you get Msg 213.
-- ============================================================================
:setvar AdminDb "kArchiveManagerAdmin"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

PRINT '=== 1) arch.usp_ValidateConfiguration ===';
GO
EXEC arch.usp_ValidateConfiguration;
GO

PRINT '';
PRINT '=== 2) arch.usp_ValidateIndexRequirements ===';
GO
EXEC arch.usp_ValidateIndexRequirements;
GO

PRINT '';
PRINT '=== 3) arch.usp_Frontend_GoLiveReadiness ===';
GO
EXEC arch.usp_Frontend_GoLiveReadiness;
GO

PRINT '';
PRINT '=== 4) Effective configuration actually in force ===';
GO
-- Reads the effective view, i.e. the per-database overrides merged over the
-- process template, together with the provenance of each value. This is what the
-- runner will use - not arch.Process directly.
SELECT
    e.ProcessCode,
    e.SourceDb,
    e.ArchiveDb,
    e.IsEnabled,
    e.SelectionStrategy,
    e.Mode,
    e.RetentionDays,
    RetentionFrom = e.RetentionDaysSource,
    e.CutoffMode,
    e.CutoffDate,
    e.CutoffSafetyLagMinutes,
    e.AuditLevel,
    e.MaxRowsPerTransaction,
    ComputedCutoffUtc =
        CASE WHEN e.CutoffMode = 1 AND e.CutoffDate IS NOT NULL
             THEN e.CutoffDate
             ELSE DATEADD(MINUTE, -ISNULL(e.CutoffSafetyLagMinutes, 0),
                          DATEADD(DAY, -ISNULL(e.RetentionDays, 0), CONVERT(datetime2(0), SYSUTCDATETIME())))
        END
FROM arch.v_ProcessDatabaseEffective e
ORDER BY e.RunOrder, e.ProcessCode, e.SourceDb;
GO

PRINT '';
PRINT '=== 5) Retention floor and legal holds ===';
GO
-- MinRetentionDays = 0 means the floor is DISABLED: nothing stops a run from
-- deleting inside a mandatory retention window. Set it with
-- EXEC arch.usp_Api_SetRetentionFloor @MinRetentionDays = <n>, @RequestedBy = '...';
-- Once set, a cutoff more recent than (now - floor) aborts with THROW 50210.
SELECT Section = 'RETENTION_FLOOR', MinRetentionDays, ModifiedAtUtc, ModifiedBy,
       Verdict = CASE WHEN MinRetentionDays = 0
                      THEN 'WARN - floor disabled (default). Recommended for production as a guard against a mistyped retention.'
                      ELSE 'OK - floor active' END
FROM arch.RetentionPolicy
WHERE PolicyId = 1;

SELECT Section = 'LEGAL_HOLDS', ProcessCode, SourceDb, HoldKey, Reason, CreatedBy, CreatedAtUtc
FROM arch.LegalHold
WHERE ReleasedAtUtc IS NULL
ORDER BY CreatedAtUtc DESC;
GO
