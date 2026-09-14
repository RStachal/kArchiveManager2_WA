USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ============================================================================
-- LEGACY TOMBSTONE (v1.0) -- arch.usp_EstimateCurrentProcessImpact_RF_LOG2
-- ----------------------------------------------------------------------------
-- This v1.0 procedure is superseded by the v2.0 prepared-batch model and is
-- intentionally neutralized to an inert blocking gate. The v2.0 product bundle
-- (deploy/v2/release-package/deploy_clean_v2_full.sql) NEVER creates this
-- object; only the deprecated modular/upgrade scripts still :r this path, and
-- they now create this harmless gate instead of live v1 delete/archive logic.
-- The original v1.0 body is preserved in git history.
-- Replacement: arch.usp_Api_EstimateNextRunImpact
-- See: docs/legacy-consolidation.md  (consolidation decision record)
-- ============================================================================
CREATE OR ALTER PROCEDURE [arch].[usp_EstimateCurrentProcessImpact_RF_LOG2]
(
      @SourceDb sysname
    , @AsOfUtc  datetime2(0) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50028, 'LEGACY BLOCKED: arch.usp_EstimateCurrentProcessImpact_RF_LOG2 is v1.0 only and has been retired. Use arch.usp_Api_EstimateNextRunImpact (v2.0 prepared-batch model).', 1;
END
GO
