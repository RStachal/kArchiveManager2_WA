USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/**
 * ============================================================================
 * 032_archive_legacy_procedures.sql
 * ============================================================================
 *
 * Purpose:
 *   Move legacy v1.0 procedures out of arch schema into legacy_v1 schema.
 *   This removes clutter from arch (the production schema) while preserving
 *   the procedures for forensic/reference purposes.
 *
 * Rationale:
 *   These 11 procedures are confirmed dead code:
 *   - No EXEC references from any other procedure
 *   - No references from frontend/API code
 *   - Replaced by v2.0 prepared-batch model
 *
 * What stays in arch (CONFIRMED LIVE):
 *   - usp_RunProfile_Prepared, usp_RunConfiguredProcesses_Prepared
 *   - usp_RunPreparedBatches_InWindow, usp_RunPreparedBatch
 *   - usp_PrepareCandidates, usp_RunTimestampProcess
 *   - usp_EnsureArchiveTableLikeSource (called by RunPreparedBatch)
 *   - usp_GetOutputColumns (called by RunPreparedBatch)
 *   - usp_ProvisionArchiveTablesForProcess (manual provisioning tool)
 *   - usp_ValidateConfiguration, usp_ValidateIndexRequirements
 *   - usp_RunProcess, usp_RunProcess_TimestampKeyset, usp_RunProcess_RF_LOG2
 *     (P1.3 BLOCKING gates - throw 50004-50006 to prevent operator misuse)
 *   - All usp_Api_* (called by REST API)
 *   - All usp_Frontend_* (called by Admin Console)
 *   - usp_RecoverStaleRuns (operational tool)
 *
 * What moves to legacy_v1 (CONFIRMED DEAD):
 *   1. usp_PrepWorkBatch_Receiving (WMS-hardcoded, replaced by PrepareCandidates)
 *   2. usp_PrepWorkBatch_Shipping (WMS-hardcoded, replaced by PrepareCandidates)
 *   3. usp_RunWorkBatch (v1.0 batch runner)
 *   4. usp_RunWorkBatches_InWindow (v1.0 window runner)
 *   5. usp_RunAll (v1.0 master)
 *   6. usp_RunConfiguredProcesses (v1.0 orchestrator)
 *   7. usp_RunScheduledProfiles_Prepared (orphan, no callers)
 *   8. usp_EstimateWorkBatchImpact (orphan)
 *   9. usp_EstimateLatestWorkBatchImpact (orphan)
 *   10. usp_EstimateCurrentProcessImpact_RF_LOG2 (orphan, WMS-specific)
 *   11. usp_CaptureRowCountSnapshot (utility, no callers)
 *
 * Rollback:
 *   For each procedure: ALTER SCHEMA arch TRANSFER legacy_v1.<proc_name>;
 *
 * Created: 2026-05-28
 * Version: 1.0
 * ============================================================================
 */

PRINT N'============================================================================';
PRINT N'Archive Legacy v1.0 Procedures - kArchiveManager 2.0';
PRINT N'============================================================================';
PRINT N'';

-- =========================================================================
-- STEP 1: Create legacy_v1 schema if it doesn't exist
-- =========================================================================

IF SCHEMA_ID(N'legacy_v1') IS NULL
BEGIN
    EXEC(N'CREATE SCHEMA legacy_v1 AUTHORIZATION dbo');
    PRINT N'✅ Schema [legacy_v1] created';
END
ELSE
BEGIN
    PRINT N'ℹ️  Schema [legacy_v1] already exists';
END;

PRINT N'';

-- =========================================================================
-- STEP 2: Transfer procedures (one at a time, with safety checks)
-- =========================================================================

DECLARE @DeadProcs TABLE (
    ProcName sysname NOT NULL PRIMARY KEY,
    OrderId int NOT NULL
);

INSERT INTO @DeadProcs (ProcName, OrderId) VALUES
    (N'usp_PrepWorkBatch_Receiving', 1),
    (N'usp_PrepWorkBatch_Shipping', 2),
    (N'usp_RunWorkBatch', 3),
    (N'usp_RunWorkBatches_InWindow', 4),
    (N'usp_RunAll', 5),
    (N'usp_RunConfiguredProcesses', 6),
    (N'usp_RunScheduledProfiles_Prepared', 7),
    (N'usp_EstimateWorkBatchImpact', 8),
    (N'usp_EstimateLatestWorkBatchImpact', 9),
    (N'usp_EstimateCurrentProcessImpact_RF_LOG2', 10),
    (N'usp_CaptureRowCountSnapshot', 11);

DECLARE @ProcName sysname;
DECLARE @Sql nvarchar(500);
DECLARE @MovedCount int = 0;
DECLARE @SkippedCount int = 0;
DECLARE @FailedCount int = 0;

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT ProcName FROM @DeadProcs ORDER BY OrderId;

OPEN cur;
FETCH NEXT FROM cur INTO @ProcName;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Check if procedure exists in arch
    IF OBJECT_ID(N'arch.' + @ProcName, N'P') IS NOT NULL
    BEGIN
        -- Check if same name doesn't already exist in legacy_v1 (avoid name conflict)
        IF OBJECT_ID(N'legacy_v1.' + @ProcName, N'P') IS NOT NULL
        BEGIN
            -- Already moved before, drop the duplicate in arch (it's dead anyway)
            SET @Sql = N'DROP PROCEDURE arch.' + QUOTENAME(@ProcName);
            BEGIN TRY
                EXEC sp_executesql @Sql;
                PRINT N'  ⚠️  arch.' + @ProcName + N' was DROPPED (duplicate of legacy_v1.' + @ProcName + N')';
                SET @MovedCount = @MovedCount + 1;
            END TRY
            BEGIN CATCH
                PRINT N'  ❌ arch.' + @ProcName + N' DROP failed: ' + ERROR_MESSAGE();
                SET @FailedCount = @FailedCount + 1;
            END CATCH
        END
        ELSE
        BEGIN
            -- Move it
            SET @Sql = N'ALTER SCHEMA legacy_v1 TRANSFER arch.' + QUOTENAME(@ProcName);
            BEGIN TRY
                EXEC sp_executesql @Sql;
                PRINT N'  ✅ arch.' + @ProcName + N' → legacy_v1.' + @ProcName;
                SET @MovedCount = @MovedCount + 1;
            END TRY
            BEGIN CATCH
                PRINT N'  ❌ arch.' + @ProcName + N' transfer failed: ' + ERROR_MESSAGE();
                SET @FailedCount = @FailedCount + 1;
            END CATCH
        END
    END
    ELSE
    BEGIN
        PRINT N'  ⏭️  arch.' + @ProcName + N' does not exist (already moved or never created)';
        SET @SkippedCount = @SkippedCount + 1;
    END;

    FETCH NEXT FROM cur INTO @ProcName;
END;

CLOSE cur;
DEALLOCATE cur;

PRINT N'';
PRINT N'============================================================================';
PRINT N'Summary';
PRINT N'============================================================================';
PRINT N'Moved/Dropped: ' + CAST(@MovedCount AS varchar(10));
PRINT N'Skipped (not present): ' + CAST(@SkippedCount AS varchar(10));
PRINT N'Failed: ' + CAST(@FailedCount AS varchar(10));
PRINT N'';

-- =========================================================================
-- STEP 3: Verify final state
-- =========================================================================

PRINT N'=== Final state in arch schema ===';
PRINT N'';

DECLARE @ArchProcCount int;
SELECT @ArchProcCount = COUNT(*)
FROM sys.objects
WHERE type = 'P'
  AND schema_id = SCHEMA_ID('arch');
PRINT N'Procedures still in arch: ' + CAST(@ArchProcCount AS varchar(10));

DECLARE @LegacyProcCount int;
SELECT @LegacyProcCount = COUNT(*)
FROM sys.objects
WHERE type = 'P'
  AND schema_id = SCHEMA_ID('legacy_v1');
PRINT N'Procedures now in legacy_v1: ' + CAST(@LegacyProcCount AS varchar(10));

PRINT N'';

-- Show the moved procedures
SELECT
    [Schema] = N'legacy_v1',
    [Procedure] = name,
    [Created] = create_date,
    [Status] = N'Archived (not for production use)'
FROM sys.objects
WHERE type = 'P'
  AND schema_id = SCHEMA_ID('legacy_v1')
ORDER BY name;

PRINT N'';
PRINT N'=== ROLLBACK INSTRUCTIONS ===';
PRINT N'';
PRINT N'To restore any procedure back to arch schema:';
PRINT N'    ALTER SCHEMA arch TRANSFER legacy_v1.<procedure_name>;';
PRINT N'';
PRINT N'To remove legacy_v1 entirely (after confirmed not needed):';
PRINT N'    -- Drop each procedure first, then:';
PRINT N'    DROP SCHEMA legacy_v1;';
PRINT N'';
PRINT N'============================================================================';
PRINT N'Cleanup complete';
PRINT N'============================================================================';

GO
