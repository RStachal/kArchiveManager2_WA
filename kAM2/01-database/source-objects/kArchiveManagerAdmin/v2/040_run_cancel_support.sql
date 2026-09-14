USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* ============================================================================
 * 040 — Cooperative run cancellation
 * ============================================================================
 * Lets an operator stop a long-running RUN gracefully from the Admin Console.
 * A stop request just stamps arch.Run.CancelRequestedAtUtc; the batch workers
 * (027 usp_RunTimestampProcess, 015 usp_RunPreparedBatch) check it at the top of
 * their batch loop and BREAK after finishing the in-flight batch (which is already
 * committed) — no rollback of completed work, no KILL privilege required. The run
 * ends with Status='STOPPED'. ANCHOR work batches are left 'Paused' so they can resume.
 *
 * Deploy order: this script, then re-deploy 015 and 027 (cancel-aware workers).
 * ============================================================================ */

IF COL_LENGTH('arch.Run', 'CancelRequestedAtUtc') IS NULL
BEGIN
    ALTER TABLE arch.Run ADD CancelRequestedAtUtc datetime2(0) NULL;
    PRINT 'arch.Run.CancelRequestedAtUtc added.';
END
ELSE
    PRINT 'arch.Run.CancelRequestedAtUtc already present.';
GO

-- T-10: persist WHO requested the stop and WHY. The Admin Console API already resolves the AUTHENTICATED
-- actor (never client-supplied) and passes it as @RequestedBy, but usp_Api_RequestRunStop previously only
-- returned it in the result and never stored it -> a stop of an irreversible delete run was unattributable
-- after the HTTP response. (Restore/purge attribution is already covered by arch.RestoreAudit, T-27.)
-- Columns are added in their own batches before the CREATE OR ALTER below so the proc compiles against them.
IF COL_LENGTH('arch.Run', 'CancelRequestedBy') IS NULL
BEGIN
    ALTER TABLE arch.Run ADD CancelRequestedBy nvarchar(256) NULL;
    PRINT 'arch.Run.CancelRequestedBy added.';
END
ELSE
    PRINT 'arch.Run.CancelRequestedBy already present.';
GO
IF COL_LENGTH('arch.Run', 'CancelReason') IS NULL
BEGIN
    ALTER TABLE arch.Run ADD CancelReason nvarchar(400) NULL;
    PRINT 'arch.Run.CancelReason added.';
END
ELSE
    PRINT 'arch.Run.CancelReason already present.';
GO

-- A cooperatively cancelled run ends with Status='STOPPED'; the existing CK constraints only
-- allow DRYRUN/FAILED/OK/RUNNING, so extend them. (Without this the worker's STOPPED update
-- fails the CHECK and the run is wrongly marked FAILED.)
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RunItem_Status' AND parent_object_id = OBJECT_ID(N'arch.RunItem'))
    ALTER TABLE arch.RunItem DROP CONSTRAINT CK_RunItem_Status;
ALTER TABLE arch.RunItem WITH CHECK ADD CONSTRAINT CK_RunItem_Status
    CHECK (Status IN (N'DRYRUN', N'FAILED', N'OK', N'RUNNING', N'STOPPED'));

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Run_Status' AND parent_object_id = OBJECT_ID(N'arch.Run'))
    ALTER TABLE arch.Run DROP CONSTRAINT CK_Run_Status;
ALTER TABLE arch.Run WITH CHECK ADD CONSTRAINT CK_Run_Status
    CHECK (Status IN (N'DRYRUN', N'FAILED', N'OK', N'RUNNING', N'STOPPED'));
PRINT 'CK_RunItem_Status / CK_Run_Status now allow STOPPED.';
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_RequestRunStop]
    @RunId       bigint,
    @RequestedBy nvarchar(256) = NULL,
    @Reason      nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
        THROW 50300, '@RunId is required.', 1;

    DECLARE @status nvarchar(20) = (SELECT Status FROM arch.Run WHERE RunId = @RunId);

    IF @status IS NULL
        THROW 50301, 'Run not found.', 1;

    -- Only an in-flight run can be stopped; terminal runs are reported back unchanged.
    -- T-10: persist the (authenticated) requester + reason alongside the timestamp, first-writer-wins
    -- (COALESCE) so a repeat stop request never overwrites the original attribution.
    UPDATE arch.Run
    SET CancelRequestedAtUtc = COALESCE(CancelRequestedAtUtc, SYSUTCDATETIME()),
        CancelRequestedBy    = COALESCE(CancelRequestedBy, @RequestedBy),
        CancelReason         = COALESCE(CancelReason, NULLIF(LTRIM(RTRIM(@Reason)), N''))
    WHERE RunId = @RunId
      AND Status = N'RUNNING';

    DECLARE @accepted bit = CASE WHEN @@ROWCOUNT > 0 THEN 1 ELSE 0 END;

    SELECT
        RunId                = @RunId,
        Accepted             = @accepted,
        CurrentStatus        = (SELECT Status FROM arch.Run WHERE RunId = @RunId),
        CancelRequestedAtUtc = (SELECT CancelRequestedAtUtc FROM arch.Run WHERE RunId = @RunId),
        CancelRequestedBy    = (SELECT CancelRequestedBy FROM arch.Run WHERE RunId = @RunId),
        CancelReason         = (SELECT CancelReason FROM arch.Run WHERE RunId = @RunId),
        RequestedBy          = @RequestedBy,
        Message              = CASE WHEN @accepted = 1
                                    THEN N'Stop requested; the run will end after the current batch.'
                                    ELSE N'Run is not running (already ' + (SELECT Status FROM arch.Run WHERE RunId = @RunId) + N'); nothing to stop.' END;
END
GO

-- T-02: the cooperative-stop endpoint must be executable by the production app-pool identity
-- (member of karch_operator). Without this grant the emergency Stop button fails permission-denied
-- (mapped to a generic 503) — the operator cannot stop a runaway delete run. Idempotent.
IF DATABASE_PRINCIPAL_ID(N'karch_operator') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Api_RequestRunStop] TO [karch_operator];
GO

PRINT '040_run_cancel_support deployed (column + arch.usp_Api_RequestRunStop + karch_operator grant).';
GO
