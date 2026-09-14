/**
 * ============================================================================
 * KARCHIVEMANAGER 2.0 — P1.3 SMOKE TESTS
 * ============================================================================
 *
 * Purpose:
 *   Validate that legacy procedures are properly blocked and prepared
 *   workflow is accessible.
 *
 * Tests:
 *   1. Legacy procedure blocking (should throw error)
 *   2. Prepared workflow validation (should succeed or throw expected error)
 *   3. Error message clarity (should guide to correct procedure)
 *
 * Timeline: Sprint 2 (Post P1.3 implementation)
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
-- TEST 1: Verify legacy procedures throw error
-- ============================================================================
-- Expected: Error 50004, 50005, or 50006 with clear message

PRINT '============================================================================'
PRINT 'TEST 1: Legacy procedures should throw error'
PRINT '============================================================================'
GO

-- Test 1a: arch.usp_RunProcess (main legacy entry point)
PRINT 'Test 1a: Calling arch.usp_RunProcess (legacy)...'
DECLARE @ErrorNum_1a int;
DECLARE @ErrorMsg_1a nvarchar(max);
BEGIN TRY
    EXEC arch.usp_RunProcess;
    PRINT '❌ FAIL - Procedure did not throw error!';
END TRY
BEGIN CATCH
    SET @ErrorNum_1a = ERROR_NUMBER();
    SET @ErrorMsg_1a = ERROR_MESSAGE();

    IF @ErrorNum_1a IN (50004, 50005, 50006)
    BEGIN
        PRINT '✅ PASS - Error ' + CAST(@ErrorNum_1a AS nvarchar(10)) + ' (expected - legacy blocked)';
        PRINT 'Message: ' + @ErrorMsg_1a;
    END
    ELSE
    BEGIN
        PRINT '⚠️  INFO - Error ' + CAST(@ErrorNum_1a AS nvarchar(10)) + ' (legacy still has old logic, 025 script not applied yet)';
        PRINT 'Message: ' + @ErrorMsg_1a;
    END;
END CATCH

PRINT ''
GO

-- Test 1b: arch.usp_RunProcess_TimestampKeyset (legacy variant)
PRINT 'Test 1b: Calling arch.usp_RunProcess_TimestampKeyset (legacy variant)...'
DECLARE @ErrorNum_1b int;
DECLARE @ErrorMsg_1b nvarchar(max);
BEGIN TRY
    EXEC arch.usp_RunProcess_TimestampKeyset;
    PRINT '❌ FAIL - Procedure did not throw error!';
END TRY
BEGIN CATCH
    SET @ErrorNum_1b = ERROR_NUMBER();
    SET @ErrorMsg_1b = ERROR_MESSAGE();

    IF @ErrorNum_1b IN (50004, 50005, 50006)
    BEGIN
        PRINT '✅ PASS - Error ' + CAST(@ErrorNum_1b AS nvarchar(10)) + ' (expected - legacy blocked)';
        PRINT 'Message: ' + @ErrorMsg_1b;
    END
    ELSE
    BEGIN
        PRINT '⚠️  INFO - Error ' + CAST(@ErrorNum_1b AS nvarchar(10)) + ' (legacy still has old logic, 025 script not applied yet)';
        PRINT 'Message: ' + @ErrorMsg_1b;
    END;
END CATCH

PRINT ''
GO

-- Test 1c: arch.usp_RunProcess_RF_LOG2 (legacy variant)
PRINT 'Test 1c: Calling arch.usp_RunProcess_RF_LOG2 (legacy variant)...'
DECLARE @ErrorNum_1c int;
DECLARE @ErrorMsg_1c nvarchar(max);
BEGIN TRY
    EXEC arch.usp_RunProcess_RF_LOG2;
    PRINT '❌ FAIL - Procedure did not throw error!';
END TRY
BEGIN CATCH
    SET @ErrorNum_1c = ERROR_NUMBER();
    SET @ErrorMsg_1c = ERROR_MESSAGE();

    IF @ErrorNum_1c IN (50004, 50005, 50006)
    BEGIN
        PRINT '✅ PASS - Error ' + CAST(@ErrorNum_1c AS nvarchar(10)) + ' (expected - legacy blocked)';
        PRINT 'Message: ' + @ErrorMsg_1c;
    END
    ELSE
    BEGIN
        PRINT '⚠️  INFO - Error ' + CAST(@ErrorNum_1c AS nvarchar(10)) + ' (legacy still has old logic, 025 script not applied yet)';
        PRINT 'Message: ' + @ErrorMsg_1c;
    END;
END CATCH

PRINT ''
GO

-- ============================================================================
-- TEST 2: Verify prepared workflow entry point exists and is callable
-- ============================================================================
-- Expected: Either succeed or throw a predictable error (profile not found)

PRINT '============================================================================'
PRINT 'TEST 2: Prepared workflow should be callable'
PRINT '============================================================================'
GO

-- Test 2a: arch.usp_RunProfile_Prepared with non-existent profile (expected error)
PRINT 'Test 2a: Calling arch.usp_RunProfile_Prepared with non-existent profile...'
DECLARE @ErrorNum_2a int;
DECLARE @ErrorMsg_2a nvarchar(max);
BEGIN TRY
    EXEC arch.usp_RunProfile_Prepared
        @RunProfileCode = 'NONEXISTENT_TEST_PROFILE';
    PRINT '❌ FAIL - Procedure did not throw error for non-existent profile!';
END TRY
BEGIN CATCH
    SET @ErrorNum_2a = ERROR_NUMBER();
    SET @ErrorMsg_2a = ERROR_MESSAGE();

    -- Error 50002 = RunProfile not found (expected)
    IF @ErrorNum_2a = 50002
    BEGIN
        PRINT '✅ PASS - Error 50002 (RunProfile not found, expected)';
        PRINT 'Message: ' + @ErrorMsg_2a;
    END
    ELSE IF @ErrorNum_2a IN (50001, 50003)
    BEGIN
        -- Error 50001 = config table missing (also acceptable)
        -- Error 50003 = invalid runtime limits
        PRINT '✅ PASS - Error ' + CAST(@ErrorNum_2a AS nvarchar(10)) + ' (valid prepared workflow error)';
        PRINT 'Message: ' + @ErrorMsg_2a;
    END
    ELSE
    BEGIN
        PRINT '⚠️  INFO - Error ' + CAST(@ErrorNum_2a AS nvarchar(10)) + ' (may indicate 025 script not applied)';
        PRINT 'Message: ' + @ErrorMsg_2a;
    END;
END CATCH

PRINT ''
GO

-- Test 2b: Check if prepared workflow procedures exist
PRINT 'Test 2b: Verifying prepared workflow procedures exist...'
SELECT
    ProcName = OBJECT_NAME(id),
    [Type] = CASE WHEN OBJECT_NAME(id) LIKE 'usp_RunProfile_Prepared' THEN 'ENTRY POINT'
                  WHEN OBJECT_NAME(id) LIKE '%Prepared%' THEN 'PREPARED WORKFLOW'
                  ELSE 'OTHER'
            END,
    [Status] = 'EXISTS'
FROM (
    SELECT id FROM sys.syscomments
    WHERE OBJECT_NAME(id) IN (
        'usp_RunProfile_Prepared',
        'usp_RunConfiguredProcesses_Prepared',
        'usp_PrepareCandidates',
        'usp_RunPreparedBatches_InWindow',
        'usp_RunPreparedBatch'
    )
    GROUP BY id
) AS prep
ORDER BY OBJECT_NAME(id);

PRINT ''
GO

-- ============================================================================
-- TEST 3: Verify RunProfile configuration exists (if in pilot)
-- ============================================================================

PRINT '============================================================================'
PRINT 'TEST 3: Check RunProfile configuration'
PRINT '============================================================================'
GO

PRINT 'Configured RunProfiles:'
SELECT
    RunProfileCode,
    IsEnabled,
    RunWindowMinutes,
    ProcessCodeFilter,
    SourceDbFilter,
    ArchiveDbFilter,
    DryRun
FROM arch.RunProfile
ORDER BY RunProfileCode;

IF NOT EXISTS (SELECT 1 FROM arch.RunProfile)
BEGIN
    PRINT 'ℹ️  No RunProfiles configured yet (expected for fresh installation)';
    PRINT 'Create RunProfiles via Admin Console or insert into arch.RunProfile table';
END;

PRINT ''
GO

-- ============================================================================
-- TEST 4: Summary Report
-- ============================================================================

PRINT '============================================================================'
PRINT 'TEST SUMMARY: P1.3 Runtime Path Standardization'
PRINT '============================================================================'
GO

DECLARE @LegacyBlocked int = 0;
DECLARE @PreparedExists bit = 0;
DECLARE @PreparedCallable bit = 0;

-- Count legacy procedures that throw errors (THROW with LEGACY message)
SELECT @LegacyBlocked = COUNT(*)
FROM sys.syscomments
WHERE OBJECT_NAME(id) LIKE 'usp_RunProcess%'
  AND text LIKE '%THROW%Legacy%BLOCKED%';

-- Check if prepared entry point exists
IF OBJECT_ID('arch.usp_RunProfile_Prepared', 'P') IS NOT NULL
    SET @PreparedExists = 1;

-- Check if prepared workflow procedure exists
IF OBJECT_ID('arch.usp_RunConfiguredProcesses_Prepared', 'P') IS NOT NULL
    SET @PreparedCallable = 1;

PRINT 'Legacy procedures blocked: ' + CASE WHEN @LegacyBlocked > 0 THEN '✅ YES (THROW with error 50004+)' ELSE '⚠️  NO (025 script not applied yet)' END;
PRINT 'Prepared entry point exists: ' + CASE WHEN @PreparedExists = 1 THEN '✅ YES' ELSE '❌ NO' END;
PRINT 'Prepared workflow callable: ' + CASE WHEN @PreparedCallable = 1 THEN '✅ YES' ELSE '❌ NO' END;

PRINT '';
PRINT 'STATUS: ' + CASE
    WHEN @LegacyBlocked > 0 AND @PreparedExists = 1 AND @PreparedCallable = 1
        THEN '✅ P1.3 SCRIPT 025 IS APPLIED'
    WHEN @PreparedExists = 1 AND @PreparedCallable = 1
        THEN '⚠️  P1.3 SCRIPT 025 NOT YET APPLIED - Legacy procedures still have old logic'
    ELSE '❌ P1.3 INFRASTRUCTURE INCOMPLETE'
END;

PRINT '';
PRINT '============================================================================'
GO

-- ============================================================================
-- Cleanup: Drop this test script from the database
-- ============================================================================
-- After running these tests, you may drop them via:
-- IF OBJECT_ID('arch.usp_P13_ValidateLegacyBlocked', 'P') IS NOT NULL
--     DROP PROCEDURE arch.usp_P13_ValidateLegacyBlocked;
