USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/**
 * ============================================================================
 * 034_apply_anchor_time_zone_conversions.sql
 * ============================================================================
 *
 * Purpose:
 *   Apply AT TIME ZONE conversions to the ANCHOR-side cutoff expression
 *   (arch.Process.AnchorTimestampExpr and any arch.ProcessDatabase override)
 *   so the candidate cutoff window for ANCHOR-strategy processes (RECEIVING,
 *   SHIPPING) compares apples-to-apples with the UTC cutoff.
 *
 * Background (Risk K1 — anchor residual gap):
 *   Script 031 wrapped only arch.ObjectSpec.TimestampExpr. But the live v2
 *   ANCHOR path applies the cutoff in arch.usp_PrepareCandidates using
 *   AnchorTimestampExpr (read from arch.v_ProcessDatabaseEffective), NOT
 *   ObjectSpec.TimestampExpr (the anchor DELETE only joins the prepared key
 *   set, with no timestamp re-filter). Raw local AnchorTimestampExpr vs UTC
 *   cutoff => delete window off by the TZ offset (1-2h, DST edges).
 *
 * Strategy (mirrors 031):
 *     CAST(<expr> AS datetime2) AT TIME ZONE @SourceTimezone AT TIME ZONE 'UTC'
 *
 * Safety:
 *   - Backs up current AnchorTimestampExpr values (both tables) before changes.
 *   - Idempotent: skips expressions that already contain AT TIME ZONE.
 *   - Wrapped inside a single transaction.
 *
 * Configuration:
 *   @SourceTimezone — defaults to 'Central European Standard Time'.
 *   Re-run with a different value for customers in other timezones.
 *
 * Scope note:
 *   Env-specific operational script (like 028/031/033). NOT part of the
 *   regenerated deploy bundle. A fresh deploy ships the wrapped expressions
 *   directly from deploy/v2/02_configure_original_processes.sql.
 *
 * Rollback:
 *   See backup table arch.AnchorTimestampExpr_Backup_<yyyymmdd> (instructions
 *   printed at the end).
 *
 * Created: 2026-05-29
 * Related: v2/031 (ObjectSpec side), v2/035 (runtime gate),
 *          docs/production-timezone-cutoff-policy.md
 * ============================================================================
 */

DECLARE @SourceTimezone sysname = N'Central European Standard Time';
DECLARE @BackupTable sysname = N'AnchorTimestampExpr_Backup_' + CONVERT(varchar(8), GETDATE(), 112);

PRINT N'============================================================================';
PRINT N'Anchor AT TIME ZONE Migration - kArchiveManager 2.0';
PRINT N'============================================================================';
PRINT N'Source Timezone: ' + @SourceTimezone;
PRINT N'Backup Table: arch.' + @BackupTable;
PRINT N'';

-- =========================================================================
-- STEP 1: Create backup table (both Process and ProcessDatabase scopes)
-- =========================================================================

DECLARE @CreateBackupSql nvarchar(max);
SET @CreateBackupSql = N'
IF OBJECT_ID(N''arch.' + @BackupTable + N''', N''U'') IS NOT NULL
    DROP TABLE arch.' + QUOTENAME(@BackupTable) + N';

CREATE TABLE arch.' + QUOTENAME(@BackupTable) + N'
(
    Scope             varchar(20)   NOT NULL,
    ProcessId         int           NOT NULL,
    ProcessDatabaseId int           NULL,
    ProcessCode       sysname       NULL,
    SourceDb          sysname       NULL,
    OldAnchorExpr     nvarchar(4000) NULL,
    BackedUpAtUtc     datetime2(0)  NOT NULL
);

INSERT INTO arch.' + QUOTENAME(@BackupTable) + N' (Scope, ProcessId, ProcessDatabaseId, ProcessCode, SourceDb, OldAnchorExpr, BackedUpAtUtc)
SELECT N''Process'', p.ProcessId, NULL, p.ProcessCode, NULL, p.AnchorTimestampExpr, CONVERT(datetime2(0), SYSUTCDATETIME())
FROM arch.Process p
WHERE p.AnchorTimestampExpr IS NOT NULL;

INSERT INTO arch.' + QUOTENAME(@BackupTable) + N' (Scope, ProcessId, ProcessDatabaseId, ProcessCode, SourceDb, OldAnchorExpr, BackedUpAtUtc)
SELECT N''ProcessDatabase'', pd.ProcessId, pd.ProcessDatabaseId, p.ProcessCode, pd.SourceDb, pd.AnchorTimestampExpr, CONVERT(datetime2(0), SYSUTCDATETIME())
FROM arch.ProcessDatabase pd
JOIN arch.Process p ON p.ProcessId = pd.ProcessId
WHERE pd.AnchorTimestampExpr IS NOT NULL;
';
EXEC sys.sp_executesql @CreateBackupSql;
PRINT N'Backup created in arch.' + @BackupTable;
PRINT N'';

-- =========================================================================
-- STEP 2: Show plan (what will change)
-- =========================================================================

PRINT N'=== CONVERSION PLAN ===';

SELECT
    Scope = N'Process',
    p.ProcessId,
    p.ProcessCode,
    SourceDb = CONVERT(sysname, NULL),
    Action = CASE WHEN p.AnchorTimestampExpr LIKE N'%AT TIME ZONE%' THEN N'SKIP' ELSE N'CONVERT' END,
    OldExpr = LEFT(p.AnchorTimestampExpr, 100)
FROM arch.Process p
WHERE p.AnchorTimestampExpr IS NOT NULL
UNION ALL
SELECT
    Scope = N'ProcessDatabase',
    pd.ProcessId,
    p.ProcessCode,
    pd.SourceDb,
    Action = CASE WHEN pd.AnchorTimestampExpr LIKE N'%AT TIME ZONE%' THEN N'SKIP' ELSE N'CONVERT' END,
    OldExpr = LEFT(pd.AnchorTimestampExpr, 100)
FROM arch.ProcessDatabase pd
JOIN arch.Process p ON p.ProcessId = pd.ProcessId
WHERE pd.AnchorTimestampExpr IS NOT NULL
ORDER BY Scope, ProcessCode, SourceDb;

PRINT N'';

-- =========================================================================
-- STEP 3: Apply changes
-- =========================================================================

BEGIN TRANSACTION;

DECLARE @WrapPrefix nvarchar(20) = N'CAST(';
DECLARE @WrapSuffix nvarchar(200) = N' AS datetime2) AT TIME ZONE N''' + @SourceTimezone + N''' AT TIME ZONE N''UTC''';

UPDATE p
SET p.AnchorTimestampExpr = @WrapPrefix + p.AnchorTimestampExpr + @WrapSuffix,
    p.ModifiedAt = SYSUTCDATETIME()
FROM arch.Process p
WHERE p.AnchorTimestampExpr IS NOT NULL
  AND p.AnchorTimestampExpr NOT LIKE N'%AT TIME ZONE%';

DECLARE @ProcessRows int = @@ROWCOUNT;

UPDATE pd
SET pd.AnchorTimestampExpr = @WrapPrefix + pd.AnchorTimestampExpr + @WrapSuffix,
    pd.ModifiedAt = SYSUTCDATETIME()
FROM arch.ProcessDatabase pd
WHERE pd.AnchorTimestampExpr IS NOT NULL
  AND pd.AnchorTimestampExpr NOT LIKE N'%AT TIME ZONE%';

DECLARE @ProcessDatabaseRows int = @@ROWCOUNT;

COMMIT TRANSACTION;

PRINT N'Process.AnchorTimestampExpr updated:         ' + CAST(@ProcessRows AS varchar(10));
PRINT N'ProcessDatabase.AnchorTimestampExpr updated: ' + CAST(@ProcessDatabaseRows AS varchar(10));
PRINT N'';

-- =========================================================================
-- STEP 4: Verification
-- =========================================================================

PRINT N'=== POST-MIGRATION VERIFICATION ===';

DECLARE @RawProcess int, @RawProcessDb int;
SELECT @RawProcess = COUNT(*) FROM arch.Process
    WHERE AnchorTimestampExpr IS NOT NULL AND AnchorTimestampExpr NOT LIKE N'%AT TIME ZONE%';
SELECT @RawProcessDb = COUNT(*) FROM arch.ProcessDatabase
    WHERE AnchorTimestampExpr IS NOT NULL AND AnchorTimestampExpr NOT LIKE N'%AT TIME ZONE%';

PRINT N'Process rows still raw:         ' + CAST(@RawProcess AS varchar(10));
PRINT N'ProcessDatabase rows still raw: ' + CAST(@RawProcessDb AS varchar(10));

IF @RawProcess = 0 AND @RawProcessDb = 0
    PRINT N'All AnchorTimestampExpr values are UTC-normalized - anchor-side Risk K1 RESOLVED';
ELSE
    PRINT N'Still raw AnchorTimestampExpr values present - investigate';

PRINT N'';
PRINT N'=== SAMPLE NEW ANCHOR EXPRESSIONS ===';

SELECT TOP 10 p.ProcessCode, AnchorTimestampExpr = LEFT(p.AnchorTimestampExpr, 160)
FROM arch.Process p
WHERE p.AnchorTimestampExpr IS NOT NULL
ORDER BY p.ProcessCode;

PRINT N'';
PRINT N'=== ROLLBACK INSTRUCTIONS ===';
PRINT N'';
PRINT N'    UPDATE p SET p.AnchorTimestampExpr = b.OldAnchorExpr';
PRINT N'    FROM arch.Process p JOIN arch.' + @BackupTable + N' b ON b.Scope = N''Process'' AND b.ProcessId = p.ProcessId;';
PRINT N'';
PRINT N'    UPDATE pd SET pd.AnchorTimestampExpr = b.OldAnchorExpr';
PRINT N'    FROM arch.ProcessDatabase pd JOIN arch.' + @BackupTable + N' b ON b.Scope = N''ProcessDatabase'' AND b.ProcessDatabaseId = pd.ProcessDatabaseId;';
PRINT N'';
PRINT N'============================================================================';
PRINT N'Anchor migration complete';
PRINT N'============================================================================';
GO
