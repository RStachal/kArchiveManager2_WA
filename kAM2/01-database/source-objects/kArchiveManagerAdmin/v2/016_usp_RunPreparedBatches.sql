USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_RunPreparedBatches_InWindow]
    @ProcessCode sysname,
    @SourceDb sysname = NULL,
    @StopAtUtc datetime2(0),
    @DryRun bit = 0,
    @PausedCooldownSeconds int = 60
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
    BEGIN
        RAISERROR(N'2.0 metadata is not installed. Run v2/010_universal_archive_core.sql first.', 16, 1);
        RETURN;
    END;

    DECLARE
        @ProcessId int,
        @MaxBatches int,
        @DelayMs int,
        @UseAppLock bit,
        @AppLockResource nvarchar(200),
        @LockTimeoutMs int,
        @i int = 0,
        @wb bigint = NULL,
        @lres int,
        @DelayStr varchar(20) = NULL,
        @AppLockTaken bit = 0,
        @AppLockOverride nvarchar(200),
        @AppLockParent nvarchar(200) = N'KARCHIVE_MANAGER:' + @ProcessCode,
        @ParentLockTaken bit = 0;

    SELECT TOP (1)
        @ProcessId = e.ProcessId,
        @MaxBatches = COALESCE(e.MaxBatchesPerRun, 100000),
        @DelayMs = COALESCE(e.DelayMsBetweenBatches, 0),
        @UseAppLock = e.UseAppLock,
        @AppLockOverride = NULLIF(e.AppLockResource, N''),
        @AppLockResource = COALESCE(NULLIF(e.AppLockResource, N''), N'KARCHIVE_MANAGER:' + e.ProcessCode + COALESCE(N':' + @SourceDb, N'')),
        @LockTimeoutMs = COALESCE(e.LockTimeoutMs, 10000)
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessCode = @ProcessCode
      AND e.IsEnabled = 1
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
    ORDER BY CASE WHEN e.SourceDb = @SourceDb THEN 0 ELSE 1 END, e.RunOrder, e.ProcessDatabaseId;

    IF @ProcessId IS NULL
    BEGIN
        RAISERROR(N'Process not found or disabled: %s', 16, 1, @ProcessCode);
        RETURN;
    END;

    IF @DelayMs > 0
    BEGIN
        DECLARE @h int = @DelayMs / 3600000;
        DECLARE @m int = (@DelayMs % 3600000) / 60000;
        DECLARE @s int = (@DelayMs % 60000) / 1000;
        DECLARE @ms int = @DelayMs % 1000;

        SET @DelayStr =
            RIGHT('00' + CONVERT(varchar(2), @h), 2) + ':' +
            RIGHT('00' + CONVERT(varchar(2), @m), 2) + ':' +
            RIGHT('00' + CONVERT(varchar(2), @s), 2) + '.' +
            RIGHT('000' + CONVERT(varchar(3), @ms), 3);
    END;

    IF @UseAppLock = 1
    BEGIN
        -- Lock hierarchy (audit hardening): a process-wide invocation (@SourceDb IS NULL) takes the parent
        -- resource 'KARCHIVE_MANAGER:<PC>' EXCLUSIVE, while a per-DB invocation takes that parent SHARED
        -- (intent) + its own child '...:<PC>:<src>' EXCLUSIVE. Previously the two grains were different
        -- resource strings that did NOT mutually exclude, so a NULL-scope run could race a per-DB run on
        -- the same process+DB. Parent is always acquired FIRST (deadlock-safe ordering); two different
        -- source DBs still run concurrently (Shared+Shared). An explicit AppLockResource override keeps
        -- the single-resource behavior (the operator took control of the grain).
        IF @AppLockOverride IS NULL AND @SourceDb IS NOT NULL
        BEGIN
            EXEC @lres = sys.sp_getapplock
                @Resource = @AppLockParent,
                @LockMode = 'Shared',
                @LockOwner = 'Session',
                @LockTimeout = @LockTimeoutMs;

            IF @lres < 0
            BEGIN
                RAISERROR(N'arch.usp_RunPreparedBatches_InWindow failed to acquire parent applock: %s', 16, 1, @AppLockParent);
                RETURN;
            END;

            SET @ParentLockTaken = 1;
        END;

        EXEC @lres = sys.sp_getapplock
            @Resource = @AppLockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Session',
            @LockTimeout = @LockTimeoutMs;

        IF @lres < 0
        BEGIN
            IF @ParentLockTaken = 1
                EXEC sys.sp_releaseapplock @Resource = @AppLockParent, @LockOwner = 'Session';
            RAISERROR(N'arch.usp_RunPreparedBatches_InWindow failed to acquire applock: %s', 16, 1, @AppLockResource);
            RETURN;
        END;

        SET @AppLockTaken = 1;
    END;

    BEGIN TRY
        WHILE SYSUTCDATETIME() < @StopAtUtc AND @i < @MaxBatches
        BEGIN
            SET @i += 1;
            SET @wb = NULL;

            ;WITH candidates AS
            (
                SELECT
                    wb.WorkBatchId,
                    wb.Status,
                    wb.PreparedAtUtc,
                    wb.LastProgressAtUtc,
                    sort1 = CASE WHEN wb.Status = 'Prepared' THEN 0 ELSE 1 END
                FROM arch.WorkBatch wb
                WHERE wb.ProcessId = @ProcessId
                  AND (@SourceDb IS NULL OR wb.SourceDb = @SourceDb)
                  AND wb.Status IN ('Prepared','Paused')
                  AND (
                        wb.Status = 'Prepared'
                        OR wb.LastProgressAtUtc IS NULL
                        OR wb.LastProgressAtUtc < DATEADD(SECOND, -@PausedCooldownSeconds, CONVERT(datetime2(0), SYSUTCDATETIME()))
                      )
            )
            SELECT TOP (1) @wb = c.WorkBatchId
            FROM candidates c
            ORDER BY c.sort1, c.PreparedAtUtc, c.WorkBatchId;

            IF @wb IS NULL
                BREAK;

            EXEC arch.usp_RunPreparedBatch
                @WorkBatchId = @wb,
                @StopAtUtc = @StopAtUtc,
                @DryRun = @DryRun;

            IF @DelayStr IS NOT NULL
                WAITFOR DELAY @DelayStr;
        END;

        IF @AppLockTaken = 1
        BEGIN
            EXEC @lres = sys.sp_releaseapplock @Resource = @AppLockResource, @LockOwner = 'Session';
            SET @AppLockTaken = 0;
            -- A silent release failure would leave the Session-scoped lock held for the rest of the session,
            -- blocking every subsequent process+DB run in this orchestrator pass. Fail loudly instead.
            IF @lres < 0
                RAISERROR(N'arch.usp_RunPreparedBatches_InWindow failed to RELEASE applock (result %d); the Session lock may remain held: %s', 16, 1, @lres, @AppLockResource);
        END;
        IF @ParentLockTaken = 1
        BEGIN
            EXEC @lres = sys.sp_releaseapplock @Resource = @AppLockParent, @LockOwner = 'Session';
            SET @ParentLockTaken = 0;
            IF @lres < 0
                RAISERROR(N'arch.usp_RunPreparedBatches_InWindow failed to RELEASE parent applock (result %d); the Session lock may remain held: %s', 16, 1, @lres, @AppLockParent);
        END;
    END TRY
    BEGIN CATCH
        -- Surface a release failure WITHOUT masking the original error: fold it into the message.
        DECLARE @relNote nvarchar(200) = N'';
        IF @AppLockTaken = 1
        BEGIN
            EXEC @lres = sys.sp_releaseapplock @Resource = @AppLockResource, @LockOwner = 'Session';
            IF @lres < 0 SET @relNote = @relNote + N' [applock release failed]';
        END;
        IF @ParentLockTaken = 1
        BEGIN
            EXEC @lres = sys.sp_releaseapplock @Resource = @AppLockParent, @LockOwner = 'Session';
            IF @lres < 0 SET @relNote = @relNote + N' [parent applock release failed]';
        END;

        DECLARE @err nvarchar(4000) = ERROR_MESSAGE();
        RAISERROR(N'arch.usp_RunPreparedBatches_InWindow failed: %s%s', 16, 1, @err, @relNote);
        RETURN;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_RunConfiguredProcesses_Prepared]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @StopAtUtc datetime2(0) = NULL,
    @DryRun bit = 0,
    @MaxCandidates int = NULL,
    @PausedCooldownSeconds int = 60,
    -- Two-phase split for the PREP/RUN Agent jobs. BOTH = prepare+run (default, back-compat);
    -- PREP = ANCHOR candidate preparation only (TIMESTAMP is single-phase -> no-op in PREP);
    -- RUN = run prepared ANCHOR batches + run TIMESTAMP processes (no preparation).
    @Phase varchar(4) = 'BOTH'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NULL
    BEGIN
        RAISERROR(N'2.0 metadata is not installed. Run v2/010_universal_archive_core.sql first.', 16, 1);
        RETURN;
    END;

    SET @Phase = UPPER(NULLIF(LTRIM(RTRIM(@Phase)), N''));
    IF @Phase IS NULL SET @Phase = N'BOTH';
    IF @Phase NOT IN (N'BOTH', N'PREP', N'RUN')
        THROW 50117, 'Invalid @Phase (expected BOTH, PREP or RUN).', 1;

    IF @StopAtUtc IS NULL
        SET @StopAtUtc = DATEADD(MINUTE, 55, CONVERT(datetime2(0), SYSUTCDATETIME()));

    DECLARE
        @p sysname,
        @src sysname,
        @arc sysname,
        @pid int,
        @strategy nvarchar(30),
        @wb bigint,
        @openWb bigint,
        @failCount int = 0,
        @firstErr nvarchar(2000) = NULL;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        e.ProcessId,
        COALESCE(e.SelectionStrategy, N'ANCHOR') AS SelectionStrategy
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR e.ArchiveDb = @ArchiveDb)
    ORDER BY e.RunOrder, e.ProcessCode, e.SourceDb, e.ProcessDatabaseId;

    OPEN c;
    FETCH NEXT FROM c INTO @p, @src, @arc, @pid, @strategy;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF CONVERT(datetime2(0), SYSUTCDATETIME()) >= @StopAtUtc
            BREAK;

        -- Failure isolation: each (process, source DB) runs inside its own TRY/CATCH so one failure
        -- does NOT abort the rest of the nightly queue. The inner proc already records its FAILED run;
        -- here we tally and continue, then surface an aggregate error after the loop (so the Agent job
        -- step reports failure and alerting fires) without having skipped later processes.
        BEGIN TRY
            IF @strategy = N'TIMESTAMP'
            BEGIN
                -- TIMESTAMP is single-phase (keyset) — no separate prepare. Runs in BOTH/RUN; no-op in PREP.
                IF @Phase IN (N'BOTH', N'RUN')
                BEGIN
                    IF OBJECT_ID(N'arch.usp_RunTimestampProcess', N'P') IS NULL
                        THROW 50130, 'TIMESTAMP process requires arch.usp_RunTimestampProcess (run v2/027_usp_RunTimestampProcess.sql first).', 1;

                    EXEC arch.usp_RunTimestampProcess
                        @ProcessCode = @p,
                        @SourceDb = @src,
                        @ArchiveDb = @arc,
                        @AsOfUtc = NULL,
                        @StopAtUtc = @StopAtUtc,
                        @BatchRowCount = NULL,
                        @MaxRows = @MaxCandidates,
                        @DryRun = @DryRun;
                END
            END
            ELSE
            BEGIN
                SET @wb = NULL;
                SET @openWb = NULL;

                SELECT TOP (1) @openWb = wb.WorkBatchId
                FROM arch.WorkBatch wb
                WHERE wb.ProcessId = @pid
                  AND wb.SourceDb = @src
                  AND wb.ArchiveDb = @arc
                  AND wb.Status IN ('Prepared','Running','Paused')
                ORDER BY wb.WorkBatchId;

                -- PREP phase: build the WorkBatch (only if none is already open). Skipped in RUN phase.
                IF @Phase IN (N'BOTH', N'PREP') AND @openWb IS NULL
                BEGIN
                    EXEC arch.usp_PrepareCandidates
                        @ProcessCode = @p,
                        @SourceDb = @src,
                        @ArchiveDb = @arc,
                        @MaxCandidates = @MaxCandidates,
                        @WorkBatchId = @wb OUTPUT;
                END;

                -- RUN phase: process prepared batches in the window. Skipped in PREP phase.
                IF @Phase IN (N'BOTH', N'RUN')
                    EXEC arch.usp_RunPreparedBatches_InWindow
                        @ProcessCode = @p,
                        @SourceDb = @src,
                        @StopAtUtc = @StopAtUtc,
                        @DryRun = @DryRun,
                        @PausedCooldownSeconds = @PausedCooldownSeconds;
            END
        END TRY
        BEGIN CATCH
            -- A doomed transaction from the failed process must not bleed into the next iteration.
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            SET @failCount += 1;
            IF @firstErr IS NULL
                SET @firstErr = LEFT(CONCAT(@p, N'/', @src, N': ', ERROR_MESSAGE()), 2000);
        END CATCH

        FETCH NEXT FROM c INTO @p, @src, @arc, @pid, @strategy;
    END

    CLOSE c;
    DEALLOCATE c;

    IF @failCount > 0
        RAISERROR(N'usp_RunConfiguredProcesses_Prepared: %d process(es) failed; first failure: %s', 16, 1, @failCount, @firstErr);
END
GO
