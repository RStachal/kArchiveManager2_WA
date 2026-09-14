USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_ExplainProcessPlan]
    @ProcessCode sysname,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID(N'arch.IndexRequirement', N'U') IS NULL
    BEGIN
        RAISERROR(N'2.0 metadata is not installed. Run v2/010_universal_archive_core.sql first.', 16, 1);
        RETURN;
    END;

    SELECT
        p.ProcessCode,
        p.Description,
        p.IsEnabled,
        p.Mode,
        ModeName = CASE p.Mode WHEN 1 THEN N'ARCHIVE_DELETE' ELSE N'DELETE_ONLY' END,
        SelectionStrategy = COALESCE(p.SelectionStrategy, N'ANCHOR'),
        p.RetentionDays,
        p.CutoffSafetyLagMinutes,
        p.BatchDocCount,
        p.BatchRowCount,
        p.MaxBatchesPerRun,
        p.MaxRowsPerTransaction,
        p.AuditLevel,
        p.RequireSupportingIndex,
        p.AnchorSchema,
        p.AnchorTable,
        p.AnchorDocKeyExpr,
        p.AnchorDocKey2Expr,
        p.AnchorTimestampExpr,
        p.CandidateWhereSql,
        p.CandidateOrderSql
    FROM arch.Process p
    WHERE p.ProcessCode = @ProcessCode;

    SELECT
        e.ProcessDatabaseId,
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        e.IsEnabled,
        e.RunOrder,
        e.Mode,
        e.ModeSource,
        e.RetentionDays,
        e.RetentionDaysSource,
        e.CutoffSafetyLagMinutes,
        e.CutoffSafetyLagMinutesSource,
        e.CutoffMode,
        e.CutoffModeSource,
        e.CutoffDate,
        e.CutoffDateSource,
        e.BatchDocCount,
        e.BatchDocCountSource,
        e.BatchRowCount,
        e.BatchRowCountSource,
        e.MaxBatchesPerRun,
        e.MaxBatchesPerRunSource,
        e.MaxRowsPerTransaction,
        e.MaxRowsPerTransactionSource,
        e.AuditLevel,
        e.AuditLevelSource,
        e.AnchorSchema,
        e.AnchorSchemaSource,
        e.AnchorTable,
        e.AnchorTableSource,
        e.AnchorTimestampExpr,
        e.AnchorTimestampExprSource,
        e.CandidateWhereSql,
        e.CandidateWhereSqlSource,
        e.CandidateOrderSql,
        e.CandidateOrderSqlSource
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessCode = @ProcessCode
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
    ORDER BY e.RunOrder, e.SourceDb, e.ArchiveDb;

    SELECT
        os.ProcessCode,
        os.ObjectSpecId,
        ObjectName = QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        os.DeleteOrder,
        os.DeleteMode,
        os.TimestampExpr,
        os.TimestampExprSource,
        os.JoinToAnchorPredicateSql,
        os.JoinToAnchorPredicateSqlSource,
        os.AdditionalWhereSql,
        os.AdditionalWhereSqlSource,
        ArchiveObjectName =
            QUOTENAME(CONVERT(nvarchar(128), REPLACE(
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo' THEN N'{SourceDb}'
                    ELSE LTRIM(RTRIM(os.ArchiveSchema))
                END,
                N'{SourceDb}', COALESCE(@SourceDb, N'{SourceDb}'))))
            + N'.' + QUOTENAME(COALESCE(os.ArchiveTable, os.SourceTable)),
        os.ArchiveSchemaSource,
        os.ArchiveTableSource,
        os.RequireArchiveForDelete,
        os.RequireArchiveForDeleteSource,
        os.NaturalKeyLabel,
        os.CandidateSelectExpr
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessCode = @ProcessCode
      AND os.ObjectIsEnabled = 1
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
    ORDER BY os.SourceDb, os.DeleteOrder, os.ObjectSpecId;

    SELECT
        p.ProcessCode,
        pks.KeyOrdinal,
        pks.KeyName,
        pks.SourceExpressionSql,
        pks.SqlType,
        pks.IsRequired
    FROM arch.ProcessKeySpec pks
    JOIN arch.Process p
      ON p.ProcessId = pks.ProcessId
    WHERE p.ProcessCode = @ProcessCode
    ORDER BY pks.KeyOrdinal;

    SELECT
        p.ProcessCode,
        ir.RequirementType,
        ObjectName = QUOTENAME(ir.SourceSchema) + N'.' + QUOTENAME(ir.SourceTable),
        ir.KeyColumnsCsv,
        ir.IncludeColumnsCsv,
        ir.FilterSql,
        ir.IsMandatory,
        ir.Notes
    FROM arch.IndexRequirement ir
    JOIN arch.Process p
      ON p.ProcessId = ir.ProcessId
    WHERE p.ProcessCode = @ProcessCode
    ORDER BY ir.RequirementType, ir.SourceSchema, ir.SourceTable, ir.IndexRequirementId;

    SELECT
        FindingType = N'NEXT_STEP',
        Finding = N'Run EXEC arch.usp_ValidateConfiguration @ProcessCode = @ProcessCode, @SourceDb = @SourceDb before dry-run.'
    UNION ALL
    SELECT
        N'NEXT_STEP',
        N'Run EXEC arch.usp_ValidateIndexRequirements @ProcessCode = @ProcessCode, @SourceDb = @SourceDb before delete/archive mode.'
    UNION ALL
    SELECT
        N'PERFORMANCE',
        N'Review actual execution plans for candidate selection and source deletes on customer data volume.';
END
GO
