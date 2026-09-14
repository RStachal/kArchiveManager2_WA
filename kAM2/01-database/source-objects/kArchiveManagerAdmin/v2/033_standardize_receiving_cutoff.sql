/* ============================================================================
 * 033 — Standardize RECEIVING cutoff policy
 * ============================================================================
 *
 * Problem (found 2026-05-29):
 *   RECEIVING uses rolling retention (CutoffMode=0, RetentionDays=540) in the
 *   arch.Process template. Edge and KMWE_Test inherit it (ProcessDatabase
 *   override = NULL). KMWEBV had an explicit per-DB override CutoffMode=1,
 *   pinning it to a FIXED cutoff (CutoffDate=2024-01-01). That single override
 *   made KMWEBV behave differently from the other two source DBs and was the
 *   root of the "149 orphaned rows" false alarm in the 2026-05-28 test report.
 *
 * Fix:
 *   Clear the KMWEBV CutoffMode override (set to NULL) so it INHERITS the
 *   template's rolling-540-day policy, exactly like Edge and KMWE_Test.
 *
 * Effect after this change:
 *   RECEIVING/KMWEBV effective cutoff = SYSUTCDATETIME() - 540 days - lag.
 *   The next RECEIVING run on KMWEBV will then archive the ~149 rows currently
 *   in [2024-01-01, rolling-cutoff) (all valid candidates, no orphans).
 *   NOTE: this script changes CONFIG ONLY. It does NOT run/delete anything.
 *
 * Idempotent. Read-only verification before and after. Rollback at bottom.
 * ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET NOCOUNT ON;
GO

DECLARE @ProcessId int = (SELECT ProcessId FROM arch.Process WHERE ProcessCode = N'RECEIVING');
IF @ProcessId IS NULL
BEGIN
    RAISERROR(N'Process RECEIVING not found.', 16, 1);
    RETURN;
END;

PRINT '--- BEFORE (effective cutoff per source DB) ---';
SELECT SourceDb,
       CutoffMode        AS CM,
       CutoffModeSource  AS CM_Src,
       RetentionDays     AS Ret,
       CONVERT(varchar(10), CutoffDate, 120) AS CutDate
FROM arch.v_ProcessDatabaseEffective
WHERE ProcessCode = N'RECEIVING'
ORDER BY SourceDb;

UPDATE pd
SET pd.CutoffMode = NULL,
    pd.ModifiedAt = SYSUTCDATETIME()
FROM arch.ProcessDatabase pd
WHERE pd.ProcessId = @ProcessId
  AND pd.SourceDb  = N'KMWEBV'
  AND pd.CutoffMode IS NOT NULL;   -- idempotent: only acts if an override is present

DECLARE @Updated int = @@ROWCOUNT;   -- capture BEFORE any PRINT (PRINT resets @@ROWCOUNT)

PRINT '';
PRINT 'Rows updated: ' + CAST(@Updated AS varchar(10)) + ' (0 = already standardized)';
PRINT '';

PRINT '--- AFTER (all three DBs should now read CM=0, CM_Src=Process) ---';
SELECT SourceDb,
       CutoffMode        AS CM,
       CutoffModeSource  AS CM_Src,
       RetentionDays     AS Ret,
       CONVERT(varchar(10), CutoffDate, 120) AS CutDate
FROM arch.v_ProcessDatabaseEffective
WHERE ProcessCode = N'RECEIVING'
ORDER BY SourceDb;
GO

/* ----------------------------------------------------------------------------
 * ROLLBACK (restore KMWEBV's fixed-cutoff override):
 *
 * UPDATE pd
 * SET pd.CutoffMode = 1,
 *     pd.ModifiedAt = SYSUTCDATETIME()
 * FROM arch.ProcessDatabase pd
 * JOIN arch.Process p ON p.ProcessId = pd.ProcessId
 * WHERE p.ProcessCode = N'RECEIVING' AND pd.SourceDb = N'KMWEBV';
 * ---------------------------------------------------------------------------- */
