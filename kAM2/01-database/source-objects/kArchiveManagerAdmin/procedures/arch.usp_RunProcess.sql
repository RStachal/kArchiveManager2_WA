USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- P1.3 LEGACY BLOCK (v1.0 entrypoint). Replaced by the v2.0 prepared-batch
-- model: archiving runs through arch.usp_RunProfile_Prepared ->
-- arch.usp_RunConfiguredProcesses_Prepared. This entrypoint is intentionally blocked.
CREATE OR ALTER PROCEDURE [arch].[usp_RunProcess]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @AsOfUtc datetime2(0) = NULL,
    @StopAtUtc datetime2(0) = NULL,
    @DryRun bit = NULL
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50004, 'LEGACY BLOCKED: arch.usp_RunProcess is v1.0 only. Use arch.usp_RunProfile_Prepared', 1;
END
GO
