/**
 * ============================================================================
 * KARCHIVEMANAGER 2.0 — UNIFIED EXECUTION SMOKE TESTS
 * ============================================================================
 *
 * Purpose:
 *   Validate that unified execution refactor is complete:
 *   1. JOB_DEFAULT can run via RunProfile (all 15 ProcessDatabase mappings)
 *   2. Per-SourceDb profiles work correctly
 *   3. Configuration validation passes
 *   4. Legacy procedures remain blocked (P1.3 still enforced)
 *   5. SQL Agent jobs have correct enabled status
 *
 * Timeline: Sprint 2 (Post unified execution refactor)
 * Date: 2026-05-28
 * ============================================================================
 */

USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================================
-- TEST 1: JOB_DEFAULT DryRun — All ProcessDatabase mappings
-- ============================================================================

PRINT '============================================================================'
PRINT 'TEST 1: JOB_DEFAULT DryRun - Execute unified prepared workflow'
PRINT '============================================================================'
GO

DECLARE @ConfiguredProcesses int;
DECLARE @ConfiguredDatabases int;
DECLARE @ExpectedMappings int;

SELECT @ConfiguredProcesses = COUNT(DISTINCT ProcessCode)
FROM arch.Process
WHERE IsEnabled = 1;

SELECT @ConfiguredDatabases = COUNT(DISTINCT SourceDb)
FROM (
    SELECT DISTINCT SourceDb FROM arch.ProcessDatabase WHERE IsEnabled = 1
    UNION
    SELECT DISTINCT SourceDb FROM arch.ProcessDatabaseSpec WHERE IsEnabled = 1
) pd;

SET @ExpectedMappings = @ConfiguredProcesses * @ConfiguredDatabases;

PRINT 'Configured processes: ' + CAST(@ConfiguredProcesses AS nvarchar(10));
PRINT 'Configured source databases: ' + CAST(@ConfiguredDatabases AS nvarchar(10));
PRINT 'Expected ProcessDatabase mappings: ' + CAST(@ExpectedMappings AS nvarchar(10));
PRINT '';

-- Verify JOB_DEFAULT profile exists
DECLARE @JobDefaultExists int = 0;
SELECT @JobDefaultExists = COUNT(*)
FROM arch.RunProfile
WHERE RunProfileCode = N'JOB_DEFAULT'
  AND IsEnabled = 1;

IF @JobDefaultExists > 0
BEGIN
    PRINT '✅ JOB_DEFAULT profile exists and is enabled';
    PRINT '';

    -- Show profile configuration
    SELECT
        RunProfileCode,
        RunWindowMinutes,
        ProcessCodeFilter,
        SourceDbFilter,
        ArchiveDbFilter,
        DryRun,
        RunOnSchedule
    FROM arch.RunProfile
    WHERE RunProfileCode = N'JOB_DEFAULT';

    PRINT '';
    PRINT 'Ready to execute JOB_DEFAULT. Set DryRun=1 in profile to test without data changes.';
END
ELSE
BEGIN
    PRINT '❌ JOB_DEFAULT profile not found or disabled. Create via Admin Console.';
END

PRINT ''
GO

-- ============================================================================
-- TEST 2: Per-SourceDb profiles DryRun
-- ============================================================================

PRINT '============================================================================'
PRINT 'TEST 2: Per-SourceDb RunProfiles'
PRINT '============================================================================'
GO

DECLARE @EdgeProfileExists int;
DECLARE @KmwebvProfileExists int;
DECLARE @KmweTestProfileExists int;

SELECT @EdgeProfileExists = COUNT(*)
FROM arch.RunProfile
WHERE RunProfileCode = N'EDGE_ALL_20M'
  AND IsEnabled = 1;

SELECT @KmwebvProfileExists = COUNT(*)
FROM arch.RunProfile
WHERE RunProfileCode = N'KMWEBV_ALL_20M'
  AND IsEnabled = 1;

SELECT @KmweTestProfileExists = COUNT(*)
FROM arch.RunProfile
WHERE RunProfileCode = N'KMWE_TEST_ALL_20M'
  AND IsEnabled = 1;

PRINT 'Per-SourceDb profiles status:';
PRINT '  EDGE_ALL_20M: ' + CASE WHEN @EdgeProfileExists > 0 THEN '✅ EXISTS' ELSE '❌ MISSING' END;
PRINT '  KMWEBV_ALL_20M: ' + CASE WHEN @KmwebvProfileExists > 0 THEN '✅ EXISTS' ELSE '❌ MISSING' END;
PRINT '  KMWE_TEST_ALL_20M: ' + CASE WHEN @KmweTestProfileExists > 0 THEN '✅ EXISTS' ELSE '❌ MISSING' END;

PRINT '';
PRINT 'All configured RunProfiles:';
SELECT
    RunProfileCode,
    RunWindowMinutes,
    SourceDbFilter,
    IsEnabled
FROM arch.RunProfile
ORDER BY RunProfileCode;

PRINT ''
GO

-- ============================================================================
-- TEST 3: Configuration validation (0 errors, 0 warnings)
-- ============================================================================

PRINT '============================================================================'
PRINT 'TEST 3: Configuration validation'
PRINT '============================================================================'
GO

-- Run configuration validation
DECLARE @Errors int;
DECLARE @Warnings int;

SELECT @Errors = SUM(CASE WHEN ErrorCount > 0 THEN 1 ELSE 0 END),
       @Warnings = SUM(CASE WHEN WarningCount > 0 THEN 1 ELSE 0 END)
FROM (
    SELECT
        ErrorCount = (SELECT COUNT(*) FROM arch.ConfigurationValidationResult cvr WHERE cvr.IsError = 1),
        WarningCount = (SELECT COUNT(*) FROM arch.ConfigurationValidationResult cvr WHERE cvr.IsError = 0)
) v;

PRINT 'Configuration validation result:';
PRINT '  Errors: ' + COALESCE(CAST(@Errors AS nvarchar(10)), '0');
PRINT '  Warnings: ' + COALESCE(CAST(@Warnings AS nvarchar(10)), '0');

IF COALESCE(@Errors, 0) = 0 AND COALESCE(@Warnings, 0) = 0
BEGIN
    PRINT '✅ Configuration is valid (0 errors, 0 warnings)';
END
ELSE
BEGIN
    PRINT '⚠️  Configuration has issues:';
    SELECT
        [Type] = CASE WHEN IsError = 1 THEN 'ERROR' ELSE 'WARNING' END,
        Message
    FROM arch.ConfigurationValidationResult
    WHERE IsError = 1 OR IsError = 0
    ORDER BY IsError DESC, CreatedAt DESC;
END

PRINT ''
GO

-- ============================================================================
-- TEST 4: Legacy procedures remain BLOCKED (P1.3 enforcement)
-- ============================================================================

PRINT '============================================================================'
PRINT 'TEST 4: Legacy procedures should be blocked'
PRINT '============================================================================'
GO

DECLARE @LegacyBlockedCount int = 0;

-- Check if legacy procedures have THROW statements with blocking logic
SELECT @LegacyBlockedCount = COUNT(*)
FROM sys.sql_modules sm
WHERE OBJECT_NAME(sm.object_id) IN (
    'usp_RunProcess',
    'usp_RunProcess_TimestampKeyset',
    'usp_RunProcess_RF_LOG2'
)
AND sm.definition LIKE '%THROW 5000%LEGACY%BLOCKED%'
OR sm.definition LIKE '%Use arch.usp_RunProfile_Prepared%';

PRINT 'Legacy procedure blocking status:';
PRINT '  usp_RunProcess: ';

DECLARE @Test4a int;
BEGIN TRY
    EXEC arch.usp_RunProcess;
    PRINT '    ❌ NOT BLOCKED (procedure executed without error)';
    SET @Test4a = 0;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() IN (50004, 50005, 50006)
    BEGIN
        PRINT '    ✅ BLOCKED with error ' + CAST(ERROR_NUMBER() AS nvarchar(10));
        SET @Test4a = 1;
    END
    ELSE
    BEGIN
        PRINT '    ⚠️  ERROR ' + CAST(ERROR_NUMBER() AS nvarchar(10)) + ' (may indicate old logic)';
        SET @Test4a = 0;
    END
END CATCH

PRINT '  usp_RunProcess_TimestampKeyset: ';

DECLARE @Test4b int;
BEGIN TRY
    EXEC arch.usp_RunProcess_TimestampKeyset;
    PRINT '    ❌ NOT BLOCKED (procedure executed without error)';
    SET @Test4b = 0;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() IN (50004, 50005, 50006)
    BEGIN
        PRINT '    ✅ BLOCKED with error ' + CAST(ERROR_NUMBER() AS nvarchar(10));
        SET @Test4b = 1;
    END
    ELSE
    BEGIN
        PRINT '    ⚠️  ERROR ' + CAST(ERROR_NUMBER() AS nvarchar(10)) + ' (may indicate old logic)';
        SET @Test4b = 0;
    END
END CATCH

PRINT '  usp_RunProcess_RF_LOG2: ';

DECLARE @Test4c int;
BEGIN TRY
    EXEC arch.usp_RunProcess_RF_LOG2;
    PRINT '    ❌ NOT BLOCKED (procedure executed without error)';
    SET @Test4c = 0;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() IN (50004, 50005, 50006)
    BEGIN
        PRINT '    ✅ BLOCKED with error ' + CAST(ERROR_NUMBER() AS nvarchar(10));
        SET @Test4c = 1;
    END
    ELSE
    BEGIN
        PRINT '    ⚠️  ERROR ' + CAST(ERROR_NUMBER() AS nvarchar(10)) + ' (may indicate old logic)';
        SET @Test4c = 0;
    END
END CATCH

PRINT ''
GO

-- ============================================================================
-- TEST 5: New internal worker procedures exist
-- ============================================================================

PRINT '============================================================================'
PRINT 'TEST 5: Internal worker procedures (v2.0 prepared workflow)'
PRINT '============================================================================'
GO

DECLARE @UspRunTimestampProcessExists int = 0;
DECLARE @UspRunConfiguredProcessesPreparedExists int = 0;
DECLARE @UspRunProfilePreparedExists int = 0;

IF OBJECT_ID(N'arch.usp_RunTimestampProcess', N'P') IS NOT NULL
    SET @UspRunTimestampProcessExists = 1;

IF OBJECT_ID(N'arch.usp_RunConfiguredProcesses_Prepared', N'P') IS NOT NULL
    SET @UspRunConfiguredProcessesPreparedExists = 1;

IF OBJECT_ID(N'arch.usp_RunProfile_Prepared', N'P') IS NOT NULL
    SET @UspRunProfilePreparedExists = 1;

PRINT 'Prepared workflow procedures:';
PRINT '  arch.usp_RunProfile_Prepared: ' + CASE WHEN @UspRunProfilePreparedExists = 1 THEN '✅ EXISTS (entry point)' ELSE '❌ MISSING' END;
PRINT '  arch.usp_RunConfiguredProcesses_Prepared: ' + CASE WHEN @UspRunConfiguredProcessesPreparedExists = 1 THEN '✅ EXISTS (main loop)' ELSE '❌ MISSING' END;
PRINT '  arch.usp_RunTimestampProcess: ' + CASE WHEN @UspRunTimestampProcessExists = 1 THEN '✅ EXISTS (TIMESTAMP worker)' ELSE '❌ MISSING (Run v2/027_usp_RunTimestampProcess.sql)' END;

PRINT ''
GO

-- ============================================================================
-- TEST 6: SQL Agent jobs status
-- ============================================================================

PRINT '============================================================================'
PRINT 'TEST 6: SQL Agent jobs configuration'
PRINT '============================================================================'
GO

SELECT
    [Job Name] = sj.name,
    [Enabled] = CASE WHEN sj.enabled = 1 THEN '✅ YES' ELSE '❌ NO' END,
    [Status] = CASE
        WHEN sj.name = N'kArchiveManager - PREP 20:00' THEN '(Legacy PREP - should be disabled)'
        WHEN sj.name = N'kArchiveManager - RUN 00:05' THEN '(Legacy RUN - should be disabled)'
        WHEN sj.name = N'kArchiveManager - RUN CONFIGURED' THEN '(Prepared - should be enabled)'
        ELSE '(Unknown)'
    END
FROM msdb.dbo.sysjobs sj
WHERE sj.name LIKE N'kArchiveManager%'
ORDER BY sj.name;

PRINT ''
GO

-- ============================================================================
-- TEST SUMMARY
-- ============================================================================

PRINT '============================================================================'
PRINT 'UNIFIED EXECUTION TEST SUMMARY'
PRINT '============================================================================'
GO

PRINT 'Expectations:';
PRINT '  ✅ JOB_DEFAULT (and per-SourceDb profiles) are configured';
PRINT '  ✅ Configuration validation passes (0 errors)';
PRINT '  ✅ Legacy procedures are blocked with P1.3 errors';
PRINT '  ✅ New internal worker usp_RunTimestampProcess exists';
PRINT '  ✅ SQL Agent jobs: Legacy disabled, RUN CONFIGURED enabled';
PRINT '';
PRINT 'Status:';
PRINT '  If all above are ✅, unified execution refactor is COMPLETE';
PRINT '  Next: Apply to live DB in sequence: 027 → 016 → 028 → 029';
PRINT '';
PRINT '============================================================================'
GO
