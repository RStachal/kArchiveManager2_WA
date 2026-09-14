USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- P1.3 LEGACY BLOCK (v1.0 entrypoint).
-- The real TIMESTAMP keyset logic now lives in arch.usp_RunTimestampProcess
-- (v2/027_usp_RunTimestampProcess.sql), invoked internally by the unified
-- runner arch.usp_RunConfiguredProcesses_Prepared (v2/016). Operators must use
-- arch.usp_RunProfile_Prepared. This entrypoint is intentionally blocked.
CREATE OR ALTER PROCEDURE [arch].[usp_RunProcess_TimestampKeyset]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @AsOfUtc datetime2(0) = NULL,
    @StopAtUtc datetime2(0) = NULL,
    @DryRun bit = NULL
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50005, 'LEGACY BLOCKED: arch.usp_RunProcess_TimestampKeyset is v1.0 only. Use arch.usp_RunProfile_Prepared', 1;
END
GO
