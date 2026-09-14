USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/**
 * ============================================================================
 * arch.usp_RecoverStaleRuns
 * ============================================================================
 *
 * Purpose:
 *   Detect and recover stale Run/RunItem/WorkBatch records that did not
 *   complete their lifecycle (e.g., session terminated, server restart,
 *   client disconnect during execution).
 *
 * Recovery logic:
 *   1. Stale Run: Status='RUNNING' and StartedAt < (now - @StaleAfterMinutes)
 *      → Check related RunItem status:
 *        - If RunItem='OK': fix Run.Status='OK', EndedAt = max(RunItem.EndedAt)
 *        - If RunItem='RUNNING': mark as FAILED with reason
 *        - If RunItem='FAILED': fix Run.Status='FAILED', EndedAt = max(RunItem.EndedAt)
 *
 *   2. Stale WorkBatch: Status='Running' and LastProgressAtUtc < (now - @StaleAfterMinutes)
 *      → If WorkBatchKey has no Status=0 or 1 (all done): Status='Completed'
 *      → Otherwise: Status='Paused' (can resume on next run)
 *
 * Parameters:
 *   @StaleAfterMinutes - timeout threshold (default: 30 min)
 *   @DryRun - 1 = preview only, 0 = apply changes
 *   @MaxRecoveries - safety limit (default: 100)
 *
 * Output:
 *   Result set with recovered records
 *
 * Schedule: Recommended to run as SQL Agent job every 15 minutes
 *
 * Created: 2026-05-28
 * Version: 1.0
 * ============================================================================
 */

CREATE OR ALTER PROCEDURE arch.usp_RecoverStaleRuns
    @StaleAfterMinutes int = 30,
    @DryRun bit = 0,
    @MaxRecoveries int = 100,
    @VerboseOutput bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now datetime2(0) = SYSUTCDATETIME();
    DECLARE @StaleThreshold datetime2(0) = DATEADD(MINUTE, -@StaleAfterMinutes, @Now);
    DECLARE @StaleReason nvarchar(200);
    SET @StaleReason = N'Recovered by usp_RecoverStaleRuns after ' + CAST(@StaleAfterMinutes AS varchar(10)) + N' minutes of inactivity';

    -- =========================================================================
    -- COLLECT: Stale runs
    -- =========================================================================
    DECLARE @StaleRuns TABLE (
        RunId bigint NOT NULL PRIMARY KEY,
        ProcessCode sysname NULL,
        SourceDb sysname NULL,
        StartedAt datetime2 NULL,
        MinutesRunning int NULL,
        RunItemStatus nvarchar(40) NULL,
        RunItemEndedAt datetime2 NULL,
        RowsArchived bigint NULL,
        RowsDeleted bigint NULL,
        Action nvarchar(20) NULL,
        Reason nvarchar(200) NULL
    );

    INSERT INTO @StaleRuns (RunId, ProcessCode, SourceDb, StartedAt, MinutesRunning, RunItemStatus, RunItemEndedAt, RowsArchived, RowsDeleted)
    SELECT TOP (@MaxRecoveries)
        r.RunId,
        p.ProcessCode,
        r.SourceDb,
        r.StartedAt,
        DATEDIFF(MINUTE, r.StartedAt, @Now),
        ri.Status,
        ri.EndedAt,
        ri.RowsArchived,
        ri.RowsDeleted
    FROM arch.Run r
    LEFT JOIN arch.RunItem ri ON r.RunId = ri.RunId
    LEFT JOIN arch.Process p ON ri.ProcessId = p.ProcessId
    WHERE r.Status = N'RUNNING'
      AND (r.EndedAt IS NULL)
      AND r.StartedAt < @StaleThreshold
      -- T-03: never recover a run whose worker session is still alive — this eliminates the
      -- recovery-vs-live-run race (a legitimate run can run up to RunWindowMinutes, well past the
      -- stale threshold). A run is recoverable only if it predates session tracking (WorkerSessionId
      -- NULL = older than the 044 deploy, worker definitely gone) OR no live session matches its SPID.
      AND (r.WorkerSessionId IS NULL
           OR NOT EXISTS (SELECT 1 FROM sys.dm_exec_sessions s
                          WHERE s.session_id = r.WorkerSessionId
                            AND s.login_time = r.WorkerSessionLoginTimeUtc))
    ORDER BY r.RunId;

    -- Decide action per Run (smart detection of likely outcome)
    UPDATE @StaleRuns
    SET Action = CASE
            -- RunItem explicitly closed:
            WHEN RunItemStatus = N'OK' THEN N'CLOSE_OK'
            WHEN RunItemStatus = N'FAILED' THEN N'CLOSE_FAILED'
            WHEN RunItemStatus = N'DRYRUN' THEN N'CLOSE_DRYRUN'
            -- RunItem stuck in RUNNING with a dead worker session (we only reach here once the
            -- worker is provably gone). T-03: NEVER infer success from transient equal counters — a
            -- run killed mid-way shows archived==deleted for the batches it finished while candidates
            -- remain. Always mark FAILED so the next run idempotently re-processes the remainder.
            WHEN RunItemStatus = N'RUNNING' THEN N'MARK_FAILED'
            WHEN RunItemStatus IS NULL THEN N'MARK_FAILED'
            ELSE N'INVESTIGATE'
        END,
        Reason = CASE
            WHEN RunItemStatus = N'OK' THEN N'RunItem completed OK but Run was not closed (orphaned by session disconnect)'
            WHEN RunItemStatus = N'FAILED' THEN N'RunItem failed but Run was not closed'
            WHEN RunItemStatus = N'DRYRUN' THEN N'DryRun completed but Run was not closed'
            WHEN RunItemStatus = N'RUNNING'
                THEN N'Worker session ended while run was RUNNING (archived='
                     + CAST(ISNULL(RowsArchived, 0) AS varchar(20))
                     + N' deleted=' + CAST(ISNULL(RowsDeleted, 0) AS varchar(20))
                     + N'); marked FAILED for safe re-processing — success is never inferred.'
            WHEN RunItemStatus IS NULL THEN N'Run has no RunItem (incomplete initialization)'
            ELSE N'Unknown state - manual investigation required'
        END;

    -- =========================================================================
    -- COLLECT: Stale workbatches
    -- =========================================================================
    DECLARE @StaleBatches TABLE (
        WorkBatchId bigint NOT NULL PRIMARY KEY,
        ProcessCode sysname NULL,
        SourceDb sysname NULL,
        LastProgressAtUtc datetime2 NULL,
        MinutesSinceProgress int NULL,
        OpenKeys int NULL,
        Action nvarchar(20) NULL,
        Reason nvarchar(200) NULL
    );

    INSERT INTO @StaleBatches (WorkBatchId, ProcessCode, SourceDb, LastProgressAtUtc, MinutesSinceProgress, OpenKeys)
    SELECT TOP (@MaxRecoveries)
        wb.WorkBatchId,
        p.ProcessCode,
        wb.SourceDb,
        wb.LastProgressAtUtc,
        DATEDIFF(MINUTE, COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc), @Now),
        (SELECT COUNT(*) FROM arch.WorkBatchKey wbk WHERE wbk.WorkBatchId = wb.WorkBatchId AND wbk.Status IN (0, 1))
    FROM arch.WorkBatch wb
    LEFT JOIN arch.Process p ON wb.ProcessId = p.ProcessId
    WHERE wb.Status = N'Running'
      AND COALESCE(wb.LastProgressAtUtc, wb.StartedAtUtc, wb.PreparedAtUtc) < @StaleThreshold
    ORDER BY wb.WorkBatchId;

    UPDATE @StaleBatches
    SET Action = CASE
            WHEN OpenKeys = 0 THEN N'CLOSE_COMPLETE'
            ELSE N'PAUSE_FOR_RETRY'
        END,
        Reason = CASE
            WHEN OpenKeys = 0 THEN N'All keys processed but batch was not marked Completed'
            ELSE N'No progress for ' + CAST(MinutesSinceProgress AS varchar(10)) + N' min, ' + CAST(OpenKeys AS varchar(10)) + N' keys still pending'
        END;

    -- =========================================================================
    -- APPLY RECOVERIES (if not DryRun)
    -- =========================================================================
    IF @DryRun = 0
    BEGIN
        BEGIN TRANSACTION;

        -- Close OK runs (RunItem was already OK)
        UPDATE r
        SET r.Status = N'OK',
            r.EndedAt = COALESCE(sr.RunItemEndedAt, @Now)
        FROM arch.Run r
        INNER JOIN @StaleRuns sr ON r.RunId = sr.RunId
        WHERE sr.Action = N'CLOSE_OK';

        -- T-03: CLOSE_OK_INFERRED removed — recovery never marks a still-RUNNING run OK. Such runs
        -- now take the MARK_FAILED path below (safe re-processing on the next run).

        -- Close FAILED runs
        UPDATE r
        SET r.Status = N'FAILED',
            r.EndedAt = COALESCE(sr.RunItemEndedAt, @Now),
            r.ErrorMessage = COALESCE(r.ErrorMessage, sr.Reason)
        FROM arch.Run r
        INNER JOIN @StaleRuns sr ON r.RunId = sr.RunId
        WHERE sr.Action = N'CLOSE_FAILED';

        -- Close DRYRUN runs
        UPDATE r
        SET r.Status = N'DRYRUN',
            r.EndedAt = COALESCE(sr.RunItemEndedAt, @Now)
        FROM arch.Run r
        INNER JOIN @StaleRuns sr ON r.RunId = sr.RunId
        WHERE sr.Action = N'CLOSE_DRYRUN';

        -- Mark stuck (still RUNNING) as FAILED
        UPDATE ri
        SET ri.Status = N'FAILED',
            ri.EndedAt = @Now,
            ri.ErrorMessage = sr.Reason
        FROM arch.RunItem ri
        INNER JOIN @StaleRuns sr ON ri.RunId = sr.RunId
        WHERE sr.Action = N'MARK_FAILED';

        UPDATE r
        SET r.Status = N'FAILED',
            r.EndedAt = @Now,
            r.ErrorMessage = sr.Reason
        FROM arch.Run r
        INNER JOIN @StaleRuns sr ON r.RunId = sr.RunId
        WHERE sr.Action = N'MARK_FAILED';

        -- Close stale workbatches
        UPDATE wb
        SET wb.Status = N'Completed',
            wb.CompletedAtUtc = @Now
        FROM arch.WorkBatch wb
        INNER JOIN @StaleBatches sb ON wb.WorkBatchId = sb.WorkBatchId
        WHERE sb.Action = N'CLOSE_COMPLETE';

        UPDATE wb
        SET wb.Status = N'Paused',
            wb.Notes = sb.Reason
        FROM arch.WorkBatch wb
        INNER JOIN @StaleBatches sb ON wb.WorkBatchId = sb.WorkBatchId
        WHERE sb.Action = N'PAUSE_FOR_RETRY';

        -- Reset claimed keys (so they can be retried)
        UPDATE wbk
        SET wbk.Status = 0,
            wbk.ClaimedAtUtc = NULL,
            wbk.ClaimedBy = NULL
        FROM arch.WorkBatchKey wbk
        INNER JOIN @StaleBatches sb ON wbk.WorkBatchId = sb.WorkBatchId
        WHERE sb.Action = N'PAUSE_FOR_RETRY'
          AND wbk.Status = 1;

        COMMIT TRANSACTION;
    END;

    -- =========================================================================
    -- OUTPUT: Report
    -- =========================================================================
    IF @VerboseOutput = 1
    BEGIN
        PRINT N'============================================================================';
        PRINT N'arch.usp_RecoverStaleRuns - Recovery Report';
        PRINT N'============================================================================';
        PRINT N'Mode: ' + CASE WHEN @DryRun = 1 THEN N'DRY RUN (preview only)' ELSE N'APPLIED' END;
        PRINT N'Stale threshold: ' + CAST(@StaleAfterMinutes AS varchar(10)) + N' minutes';
        PRINT N'Current UTC time: ' + CONVERT(varchar(30), @Now, 121);
        PRINT N'';

        DECLARE @RunRecCount int = (SELECT COUNT(*) FROM @StaleRuns);
        DECLARE @BatchRecCount int = (SELECT COUNT(*) FROM @StaleBatches);

        PRINT N'Stale Runs found: ' + CAST(@RunRecCount AS varchar(10));
        PRINT N'Stale WorkBatches found: ' + CAST(@BatchRecCount AS varchar(10));
        PRINT N'';
    END;

    -- Result set 1: Stale runs
    SELECT
        [Result] = N'RUN',
        RunId,
        ProcessCode,
        SourceDb,
        StartedAt,
        MinutesRunning,
        RunItemStatus,
        RowsArchived,
        RowsDeleted,
        Action,
        Reason
    FROM @StaleRuns
    ORDER BY RunId;

    -- Result set 2: Stale workbatches
    SELECT
        [Result] = N'WORKBATCH',
        WorkBatchId,
        ProcessCode,
        SourceDb,
        LastProgressAtUtc,
        MinutesSinceProgress,
        OpenKeys,
        Action,
        Reason
    FROM @StaleBatches
    ORDER BY WorkBatchId;

END;
GO

PRINT N'✅ arch.usp_RecoverStaleRuns created/updated';
PRINT N'';
PRINT N'Usage examples:';
PRINT N'  EXEC arch.usp_RecoverStaleRuns @DryRun = 1;                  -- Preview';
PRINT N'  EXEC arch.usp_RecoverStaleRuns @DryRun = 0;                  -- Apply (default 30 min)';
PRINT N'  EXEC arch.usp_RecoverStaleRuns @StaleAfterMinutes = 60;      -- Apply with 60-min threshold';
GO
