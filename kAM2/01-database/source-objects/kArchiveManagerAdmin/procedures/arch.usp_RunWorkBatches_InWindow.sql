USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================================
-- LEGACY TOMBSTONE (v1.0) -- arch.usp_RunWorkBatches_InWindow
-- ----------------------------------------------------------------------------
-- This v1.0 procedure is superseded by the v2.0 prepared-batch model and is
-- intentionally neutralized to an inert blocking gate. The v2.0 product bundle
-- (deploy/v2/release-package/deploy_clean_v2_full.sql) NEVER creates this
-- object; only the deprecated modular/upgrade scripts still :r this path, and
-- they now create this harmless gate instead of live v1 delete/archive logic.
-- The original v1.0 body is preserved in git history.
-- Replacement: arch.usp_RunPreparedBatches_InWindow
-- See: docs/legacy-consolidation.md  (consolidation decision record)
-- ============================================================================
CREATE OR ALTER PROCEDURE [arch].[usp_RunWorkBatches_InWindow]
    @ProcessCode sysname,
    @StopAtUtc datetime2(0),
    @DryRun bit = 0,
    @PausedCooldownSeconds int = 60
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50023, 'LEGACY BLOCKED: arch.usp_RunWorkBatches_InWindow is v1.0 only and has been retired. Use arch.usp_RunPreparedBatches_InWindow (v2.0 prepared-batch model).', 1;
END
GO
