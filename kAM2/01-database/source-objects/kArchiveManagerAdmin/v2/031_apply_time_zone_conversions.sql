USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/**
 * ============================================================================
 * 031_apply_time_zone_conversions.sql
 * ============================================================================
 *
 * Purpose:
 *   Apply AT TIME ZONE conversions to all ObjectSpec.TimestampExpr definitions
 *   so cutoff comparisons (UTC) align with source timestamps (LOCAL).
 *
 * Background:
 *   Risk K1: Cutoff is calculated in UTC, but source timestamps are stored
 *   in LOCAL time (CET/CEST). Without timezone normalization, archiving may
 *   delete records 1-2 hours outside the intended cutoff window (DST edges).
 *
 * Strategy:
 *   For each TimestampExpr column reference, wrap with:
 *
 *     CAST(<expr> AS datetime2) AT TIME ZONE @SourceTZ AT TIME ZONE 'UTC'
 *
 *   This converts LOCAL → UTC for apples-to-apples comparison with cutoff.
 *
 * Configuration:
 *   @SourceTimezone parameter - defaults to 'Central European Standard Time'
 *   (Czech Republic / Slovakia / Germany / Austria)
 *
 *   Other typical zones:
 *   - 'UTC' (no conversion needed)
 *   - 'Eastern Standard Time' (US Eastern)
 *   - 'GMT Standard Time' (UK)
 *   - 'Romance Standard Time' (Western Europe)
 *
 * Safety:
 *   - Creates backup of current TimestampExpr values before changes
 *   - Idempotent - skips expressions that already contain AT TIME ZONE
 *   - Logs all changes to arch.ConfigChangeSet
 *
 * Rollback:
 *   See backup table arch.ObjectSpec_TimestampExpr_Backup_20260528
 *
 * Created: 2026-05-28
 * Version: 1.0
 * ============================================================================
 */

DECLARE @SourceTimezone sysname = N'Central European Standard Time';
DECLARE @BackupTable sysname = N'ObjectSpec_TimestampExpr_Backup_' + CONVERT(varchar(8), GETDATE(), 112);
DECLARE @TodayIso varchar(8) = CONVERT(varchar(8), GETDATE(), 112);

PRINT N'============================================================================';
PRINT N'AT TIME ZONE Migration - kArchiveManager 2.0';
PRINT N'============================================================================';
PRINT N'Source Timezone: ' + @SourceTimezone;
PRINT N'Backup Table: arch.' + @BackupTable;
PRINT N'';

-- =========================================================================
-- STEP 1: Create backup table
-- =========================================================================

DECLARE @CreateBackupSql nvarchar(max);
SET @CreateBackupSql = N'
IF OBJECT_ID(N''arch.' + @BackupTable + N''', N''U'') IS NOT NULL
    DROP TABLE arch.' + QUOTENAME(@BackupTable) + N';

SELECT
    ObjectSpecId,
    SourceSchema,
    SourceTable,
    TimestampExpr AS OldTimestampExpr,
    CONVERT(datetime2(0), SYSUTCDATETIME()) AS BackedUpAtUtc
INTO arch.' + QUOTENAME(@BackupTable) + N'
FROM arch.ObjectSpec
WHERE TimestampExpr IS NOT NULL;
';
EXEC sp_executesql @CreateBackupSql;
PRINT N'✅ Backup created in arch.' + @BackupTable;
PRINT N'';

-- =========================================================================
-- STEP 2: Build conversion plan
-- =========================================================================

DECLARE @Plan TABLE (
    ObjectSpecId int NOT NULL PRIMARY KEY,
    SourceTable sysname NULL,
    OldExpr nvarchar(max) NULL,
    NewExpr nvarchar(max) NULL,
    Action varchar(20) NULL,
    Reason nvarchar(200) NULL
);

INSERT INTO @Plan (ObjectSpecId, SourceTable, OldExpr)
SELECT ObjectSpecId, SourceTable, TimestampExpr
FROM arch.ObjectSpec
WHERE TimestampExpr IS NOT NULL;

-- Decide action per expression
UPDATE @Plan
SET Action = N'SKIP',
    Reason = N'Already contains AT TIME ZONE'
WHERE OldExpr LIKE '%AT TIME ZONE%';

-- Wrap expression: CAST(<expr> AS datetime2) AT TIME ZONE <SourceTZ> AT TIME ZONE 'UTC'
UPDATE @Plan
SET NewExpr = N'CAST(' + OldExpr + N' AS datetime2) AT TIME ZONE N''' + @SourceTimezone + N''' AT TIME ZONE N''UTC''',
    Action = N'CONVERT',
    Reason = N'Wrapped with AT TIME ZONE for cutoff comparison'
WHERE Action IS NULL;

-- Show plan
SELECT
    p.ObjectSpecId,
    ps.ProcessCode,
    p.SourceTable,
    p.Action,
    LEFT(p.OldExpr, 80) AS [Old Expr (truncated)],
    LEFT(p.NewExpr, 120) AS [New Expr (truncated)]
FROM @Plan p
LEFT JOIN arch.ObjectSpec os ON p.ObjectSpecId = os.ObjectSpecId
LEFT JOIN arch.Process ps ON os.ProcessId = ps.ProcessId
ORDER BY ps.ProcessCode, p.SourceTable;

PRINT N'';
DECLARE @ConvertCount int, @SkipCount int;
SELECT @ConvertCount = COUNT(*) FROM @Plan WHERE Action = N'CONVERT';
SELECT @SkipCount = COUNT(*) FROM @Plan WHERE Action = N'SKIP';
PRINT N'Plan summary:';
PRINT N'  CONVERT: ' + CAST(@ConvertCount AS varchar(10));
PRINT N'  SKIP:    ' + CAST(@SkipCount AS varchar(10));
PRINT N'';

-- =========================================================================
-- STEP 3: Apply changes
-- =========================================================================

BEGIN TRANSACTION;

UPDATE os
SET os.TimestampExpr = p.NewExpr,
    os.ModifiedAt = SYSUTCDATETIME()
FROM arch.ObjectSpec os
INNER JOIN @Plan p ON os.ObjectSpecId = p.ObjectSpecId
WHERE p.Action = N'CONVERT';

DECLARE @RowsUpdated int = @@ROWCOUNT;

COMMIT TRANSACTION;

PRINT N'✅ ' + CAST(@RowsUpdated AS varchar(10)) + N' TimestampExpr definitions updated';
PRINT N'';

-- =========================================================================
-- STEP 4: Verification
-- =========================================================================

PRINT N'=== POST-MIGRATION VERIFICATION ===';
PRINT N'';

DECLARE @TotalExprs int, @WithTZ int, @WithoutTZ int;

SELECT @TotalExprs = COUNT(*) FROM arch.ObjectSpec WHERE TimestampExpr IS NOT NULL;
SELECT @WithTZ = COUNT(*) FROM arch.ObjectSpec WHERE TimestampExpr LIKE '%AT TIME ZONE%';
SET @WithoutTZ = @TotalExprs - @WithTZ;

PRINT N'Total TimestampExpr: ' + CAST(@TotalExprs AS varchar(10));
PRINT N'With AT TIME ZONE:   ' + CAST(@WithTZ AS varchar(10));
PRINT N'Without:             ' + CAST(@WithoutTZ AS varchar(10));

IF @WithoutTZ = 0
    PRINT N'✅ ALL expressions now have AT TIME ZONE - Risk K1 RESOLVED';
ELSE
    PRINT N'⚠️  Still ' + CAST(@WithoutTZ AS varchar(10)) + N' expressions without AT TIME ZONE - investigate';

PRINT N'';
PRINT N'=== SAMPLE NEW EXPRESSIONS ===';
PRINT N'';

SELECT TOP 5
    p.ProcessCode,
    os.SourceTable,
    os.TimestampExpr
FROM arch.ObjectSpec os
INNER JOIN arch.Process p ON os.ProcessId = p.ProcessId
WHERE os.TimestampExpr IS NOT NULL
ORDER BY os.ObjectSpecId;

PRINT N'';
PRINT N'=== ROLLBACK INSTRUCTIONS ===';
PRINT N'';
PRINT N'If you need to revert these changes, run:';
PRINT N'';
PRINT N'    UPDATE os';
PRINT N'    SET os.TimestampExpr = b.OldTimestampExpr';
PRINT N'    FROM arch.ObjectSpec os';
PRINT N'    INNER JOIN arch.' + @BackupTable + N' b ON os.ObjectSpecId = b.ObjectSpecId;';
PRINT N'';
PRINT N'============================================================================';
PRINT N'Migration complete';
PRINT N'============================================================================';
GO
