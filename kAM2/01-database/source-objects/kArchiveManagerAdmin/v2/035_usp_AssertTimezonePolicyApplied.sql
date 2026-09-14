USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/**
 * ============================================================================
 * 035_usp_AssertTimezonePolicyApplied.sql
 * ============================================================================
 *
 * Purpose:
 *   Defense-in-depth runtime gate for P0.5 Risk K1 (timezone cutoff).
 *   Blocks real DELETE operations when the cutoff timestamp expression that
 *   governs candidate selection is NOT UTC-normalized via AT TIME ZONE.
 *
 * Where it is called:
 *   - arch.usp_RunPreparedBatch  (ANCHOR delete path)    -> checks AnchorTimestampExpr
 *   - arch.usp_RunTimestampProcess (TIMESTAMP delete path) -> checks ObjectSpec.TimestampExpr
 *   Both call this only on the REAL run (@DryRun = 0), so dry-run / candidate
 *   preview keep working even before the timezone policy is applied.
 *
 * Convention:
 *   Even genuinely-UTC sources must wrap their expression with
 *   AT TIME ZONE 'UTC' to explicitly signal that timezone has been addressed.
 *   This keeps the gate a simple, low-false-positive presence check while
 *   forcing a conscious decision per source.
 *
 * Error code:
 *   THROW 50200 — distinct from P1.3's 50001-50006 (RunProfile validation /
 *   legacy blocks) and usp_RunTimestampProcess's 50100-50109, so operators get
 *   an unambiguous signal. (The original policy sketch said 50001, which was
 *   already taken by P1.3.)
 *
 * Created: 2026-05-29
 * Related: v2/031 (ObjectSpec.TimestampExpr), v2/034 (AnchorTimestampExpr),
 *          docs/production-timezone-cutoff-policy.md
 * ============================================================================
 */
CREATE OR ALTER PROCEDURE [arch].[usp_AssertTimezonePolicyApplied]
    @ProcessId int,
    @SourceDb  sysname,
    @ArchiveDb sysname
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @SelectionStrategy nvarchar(30),
        @AnchorTimestampExpr nvarchar(4000),
        @ProcessCode sysname,
        @offenders nvarchar(max),
        @msg nvarchar(2048);

    SELECT TOP (1)
        @SelectionStrategy = COALESCE(e.SelectionStrategy, N'ANCHOR'),
        @AnchorTimestampExpr = e.AnchorTimestampExpr,
        @ProcessCode = e.ProcessCode
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessId = @ProcessId
      AND e.SourceDb = @SourceDb
      AND e.ArchiveDb = @ArchiveDb
      AND e.IsEnabled = 1;

    -- Nothing enabled to guard; upstream procedures already validate existence.
    IF @ProcessCode IS NULL
        RETURN;

    IF @SelectionStrategy = N'ANCHOR'
    BEGIN
        IF @AnchorTimestampExpr IS NOT NULL
           AND @AnchorTimestampExpr NOT LIKE N'%AT TIME ZONE%'
        BEGIN
            SET @msg =
                N'Timezone policy not applied (P0.5 Risk K1): AnchorTimestampExpr for process '''
                + @ProcessCode + N''' on source ''' + @SourceDb
                + N''' is not UTC-normalized: ''' + LEFT(@AnchorTimestampExpr, 180)
                + N'''. Wrap it with AT TIME ZONE before running real deletes. Delete blocked.';
            THROW 50200, @msg, 1;
        END;
    END
    ELSE IF @SelectionStrategy = N'TIMESTAMP'
    BEGIN
        SELECT @offenders =
            STRING_AGG(CONVERT(nvarchar(max), e.SourceSchema + N'.' + e.SourceTable), N', ')
        FROM arch.v_ObjectSpecDatabaseEffective e
        WHERE e.ProcessId = @ProcessId
          AND e.SourceDb = @SourceDb
          AND e.ArchiveDb = @ArchiveDb
          AND e.ObjectIsEnabled = 1
          AND e.TimestampExpr IS NOT NULL
          AND e.TimestampExpr NOT LIKE N'%AT TIME ZONE%';

        IF @offenders IS NOT NULL
        BEGIN
            SET @msg =
                N'Timezone policy not applied (P0.5 Risk K1): TimestampExpr for process '''
                + @ProcessCode + N''' on source ''' + @SourceDb
                + N''' is not UTC-normalized on: ' + @offenders
                + N'. Wrap each with AT TIME ZONE before running real deletes. Delete blocked.';
            THROW 50200, @msg, 1;
        END;
    END;
END
GO
