/**
 * kArchiveManager 2.0 — Unified Execution Refactor
 * Replace legacy SQL Agent jobs with prepared workflow job
 * Date: 2026-05-28
 */

USE [msdb]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

PRINT '============================================================================'
PRINT 'STEP 3: Replace legacy SQL Agent jobs with unified execution job'
PRINT '============================================================================'

-- Step 1: Disable legacy "PREP 20:00" job (legacy v1.0 prep workflow)
PRINT 'Disabling legacy job: "kArchiveManager - PREP 20:00"'
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'kArchiveManager - PREP 20:00')
BEGIN
    EXEC msdb.dbo.sp_update_job @job_name = N'kArchiveManager - PREP 20:00', @enabled = 0;
    PRINT '✅ Job disabled'
END
ELSE
BEGIN
    PRINT '⚠️  Job not found (may have been deleted already)'
END

PRINT ''
GO

-- Step 2: Disable legacy "RUN 00:05" job (legacy v1.0 execution workflow)
PRINT 'Disabling legacy job: "kArchiveManager - RUN 00:05"'
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'kArchiveManager - RUN 00:05')
BEGIN
    EXEC msdb.dbo.sp_update_job @job_name = N'kArchiveManager - RUN 00:05', @enabled = 0;
    PRINT '✅ Job disabled'
END
ELSE
BEGIN
    PRINT '⚠️  Job not found (may have been deleted already)'
END

PRINT ''
GO

-- Step 3: Enable "kArchiveManager - RUN CONFIGURED" job (v2.0 prepared workflow)
PRINT 'Enabling prepared workflow job: "kArchiveManager - RUN CONFIGURED"'
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'kArchiveManager - RUN CONFIGURED')
BEGIN
    EXEC msdb.dbo.sp_update_job @job_name = N'kArchiveManager - RUN CONFIGURED', @enabled = 1;
    PRINT '✅ Job enabled'
END
ELSE
BEGIN
    PRINT '❌ Job not found (must be created via SQL job definition file)'
END

PRINT ''
GO

-- Step 4: Verify current job status
PRINT '============================================================================'
PRINT 'Job Status Summary'
PRINT '============================================================================'

SELECT
    [Job Name] = sj.name,
    [Enabled] = CASE WHEN sj.enabled = 1 THEN 'YES ✅' ELSE 'NO ❌' END,
    [Status] = CASE
        WHEN sj.name LIKE '%PREP%' THEN 'LEGACY (should be disabled)'
        WHEN sj.name LIKE '%RUN 00:05%' THEN 'LEGACY (should be disabled)'
        WHEN sj.name LIKE '%RUN CONFIGURED%' THEN 'PREPARED (should be enabled)'
        ELSE 'UNKNOWN'
    END
FROM msdb.dbo.sysjobs sj
WHERE sj.name LIKE N'kArchiveManager%'
ORDER BY sj.name;

PRINT ''
PRINT '============================================================================'
PRINT 'Step 3 Complete: Legacy jobs disabled, prepared job enabled'
PRINT '============================================================================'
GO
