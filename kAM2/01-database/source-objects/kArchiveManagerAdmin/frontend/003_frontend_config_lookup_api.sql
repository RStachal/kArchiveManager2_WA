USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetProcessKeySpecs]
    @ProcessCode sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pks.ProcessKeySpecId,
        p.ProcessId,
        p.ProcessCode,
        pks.KeyOrdinal,
        pks.KeyName,
        pks.SourceExpressionSql,
        pks.SqlType,
        pks.IsRequired,
        pks.CreatedAt,
        pks.ModifiedAt
    FROM arch.ProcessKeySpec pks
    JOIN arch.Process p
      ON p.ProcessId = pks.ProcessId
    WHERE (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
    ORDER BY
        p.ProcessCode,
        pks.KeyOrdinal;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetIndexRequirements]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @RequirementType nvarchar(20) = NULL,
    @MandatoryOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ir.IndexRequirementId,
        ir.ProcessId,
        p.ProcessCode,
        ir.ObjectSpecId,
        ObjectName =
            CASE
                WHEN os.ObjectSpecId IS NULL THEN NULL
                ELSE QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable)
            END,
        ir.RequirementType,
        ir.SourceSchema,
        ir.SourceTable,
        ir.KeyColumnsCsv,
        ir.IncludeColumnsCsv,
        ir.FilterSql,
        ir.IsMandatory,
        ir.Notes,
        ir.CreatedAt,
        ir.ModifiedAt,
        EnabledMappingCount = COALESCE(mapCounts.EnabledMappingCount, CONVERT(bigint, 0))
    FROM arch.IndexRequirement ir
    JOIN arch.Process p
      ON p.ProcessId = ir.ProcessId
    LEFT JOIN arch.ObjectSpec os
      ON os.ObjectSpecId = ir.ObjectSpecId
    OUTER APPLY
    (
        SELECT EnabledMappingCount = COUNT_BIG(*)
        FROM arch.v_ProcessDatabaseEffective e
        WHERE e.ProcessId = p.ProcessId
          AND e.IsEnabled = 1
          AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
    ) mapCounts
    WHERE (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@RequirementType IS NULL OR ir.RequirementType = @RequirementType)
      AND (@MandatoryOnly = 0 OR ir.IsMandatory = 1)
      AND (@SourceDb IS NULL OR mapCounts.EnabledMappingCount > 0)
    ORDER BY
        p.ProcessCode,
        ir.RequirementType,
        ir.SourceSchema,
        ir.SourceTable,
        ir.IndexRequirementId;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetRunProfiles]
    @RunProfileCode sysname = NULL,
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @IncludeDisabled bit = 1,
    @ScheduledOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        rp.RunProfileId,
        rp.RunProfileCode,
        rp.Description,
        rp.IsEnabled,
        rp.RunOnSchedule,
        rp.RunOrder,
        rp.ProcessCodeFilter,
        rp.SourceDbFilter,
        rp.ArchiveDbFilter,
        rp.RunWindowMinutes,
        rp.DryRun,
        rp.MaxCandidates,
        rp.PausedCooldownSeconds,
        rp.CreatedAt,
        rp.ModifiedAt,
        MatchingEnabledTargetCount = COALESCE(targetCounts.MatchingEnabledTargetCount, CONVERT(bigint, 0))
    FROM arch.RunProfile rp
    OUTER APPLY
    (
        SELECT MatchingEnabledTargetCount = COUNT_BIG(*)
        FROM arch.v_ProcessDatabaseEffective e
        WHERE e.IsEnabled = 1
          AND (rp.ProcessCodeFilter IS NULL OR e.ProcessCode = rp.ProcessCodeFilter)
          AND (rp.SourceDbFilter IS NULL OR e.SourceDb = rp.SourceDbFilter)
          AND (rp.ArchiveDbFilter IS NULL OR e.ArchiveDb = rp.ArchiveDbFilter)
          AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
          AND (@ArchiveDb IS NULL OR e.ArchiveDb = @ArchiveDb)
    ) targetCounts
    WHERE (@RunProfileCode IS NULL OR rp.RunProfileCode = @RunProfileCode)
      AND (@IncludeDisabled = 1 OR rp.IsEnabled = 1)
      AND (@ScheduledOnly = 0 OR rp.RunOnSchedule = 1)
      AND (@ProcessCode IS NULL OR rp.ProcessCodeFilter IS NULL OR rp.ProcessCodeFilter = @ProcessCode)
      AND (@SourceDb IS NULL OR rp.SourceDbFilter IS NULL OR rp.SourceDbFilter = @SourceDb)
      AND (@ArchiveDb IS NULL OR rp.ArchiveDbFilter IS NULL OR rp.ArchiveDbFilter = @ArchiveDb)
    ORDER BY
        rp.RunOrder,
        rp.RunProfileCode;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetSelectionStrategies]
    @IncludeDisabled bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        StrategyCode,
        Description,
        RequiresAnchor,
        RequiresTimestamp,
        RequiresRange,
        RequiresExternalKeyset,
        IsEnabled
    FROM arch.SelectionStrategy
    WHERE (@IncludeDisabled = 1 OR IsEnabled = 1)
    ORDER BY StrategyCode;
END
GO

