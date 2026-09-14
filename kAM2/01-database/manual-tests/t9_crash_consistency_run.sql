SET NOCOUNT ON;
USE [kArchiveManagerAdmin];
EXEC arch.usp_RunConfiguredProcesses_Prepared
    @ProcessCode='RF_LOG2', @SourceDb='KMWEBV', @ArchiveDb='kArchiveManagerBackups',
    @DryRun=0, @MaxCandidates=500000;
