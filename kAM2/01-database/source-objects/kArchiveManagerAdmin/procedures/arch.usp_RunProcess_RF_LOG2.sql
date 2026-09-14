USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- P1.3 LEGACY BLOCK (v1.0 entrypoint). RF_LOG2 now archives through the unified
-- TIMESTAMP path: arch.usp_RunProfile_Prepared -> arch.usp_RunConfiguredProcesses_Prepared
-- -> arch.usp_RunTimestampProcess (v2/027). This entrypoint is intentionally blocked.
CREATE OR ALTER PROCEDURE [arch].[usp_RunProcess_RF_LOG2]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @AsOfUtc datetime2(0) = NULL,
    @StopAtUtc datetime2(0) = NULL,
    @DryRun bit = NULL
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50006, 'LEGACY BLOCKED: arch.usp_RunProcess_RF_LOG2 is v1.0 only. Use arch.usp_RunProfile_Prepared', 1;
END
GO
