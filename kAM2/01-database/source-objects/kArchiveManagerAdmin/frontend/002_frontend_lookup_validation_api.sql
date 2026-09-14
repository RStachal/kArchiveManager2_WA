USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetRecentRuns]
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @ProcessCode sysname = NULL,
    @DateFromUtc datetime2(0) = NULL,
    @DateToUtc datetime2(0) = NULL,
    @Top int = 500
AS
BEGIN
    SET NOCOUNT ON;

    IF @Top IS NULL OR @Top <= 0
        SET @Top = 500;

    SELECT TOP (@Top)
        v.RunId,
        v.RunItemId,
        v.ProcessCode,
        v.SourceDb,
        v.ArchiveDb,
        v.AsOfUtc,
        v.CutoffUtc,
        v.Mode,
        ModeName = CONVERT(nvarchar(30), CASE v.Mode WHEN 1 THEN N'ARCHIVE_DELETE' WHEN 2 THEN N'COPY_ONLY' ELSE N'DELETE_ONLY' END),
        v.Status,
        v.StartedAt,
        v.EndedAt,
        v.BatchesDone,
        v.DocsDone,
        v.RowsDeleted,
        v.RowsArchived,
        ProcessedRows = CASE WHEN v.Mode = 0 THEN v.RowsDeleted ELSE v.RowsArchived END,
        v.ErrorMessage
    FROM arch.v_RunItemsRecent v
    WHERE (@SourceDb IS NULL OR v.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR v.ArchiveDb = @ArchiveDb)
      AND (@ProcessCode IS NULL OR v.ProcessCode = @ProcessCode)
      AND (@DateFromUtc IS NULL OR v.StartedAt >= @DateFromUtc)
      AND (@DateToUtc IS NULL OR v.StartedAt < @DateToUtc)
    ORDER BY
        v.StartedAt DESC,
        v.RunItemId DESC;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetRunDetail]
    @RunId bigint = NULL,
    @RunItemId bigint = NULL,
    @Top int = 500
AS
BEGIN
    SET NOCOUNT ON;

    IF @Top IS NULL OR @Top <= 0
        SET @Top = 500;

    IF @RunId IS NULL AND @RunItemId IS NOT NULL
    BEGIN
        SELECT @RunId = RunId
        FROM arch.RunItem
        WHERE RunItemId = @RunItemId;
    END;

    DECLARE @SelectedItems table
    (
        RunItemId bigint NOT NULL PRIMARY KEY,
        RunId bigint NOT NULL,
        ProcessId int NOT NULL,
        ProcessCode sysname NOT NULL,
        AsOfUtc datetime2(0) NOT NULL,
        CutoffUtc datetime2(0) NOT NULL,
        Mode tinyint NOT NULL,
        BatchesDone int NOT NULL,
        DocsDone int NOT NULL,
        RowsDeleted bigint NOT NULL,
        RowsArchived bigint NOT NULL,
        StartedAt datetime2(0) NOT NULL,
        EndedAt datetime2(0) NULL,
        Status nvarchar(20) NOT NULL,
        ErrorMessage nvarchar(max) NULL
    );

    INSERT INTO @SelectedItems
    (
        RunItemId,
        RunId,
        ProcessId,
        ProcessCode,
        AsOfUtc,
        CutoffUtc,
        Mode,
        BatchesDone,
        DocsDone,
        RowsDeleted,
        RowsArchived,
        StartedAt,
        EndedAt,
        Status,
        ErrorMessage
    )
    SELECT
        ri.RunItemId,
        ri.RunId,
        ri.ProcessId,
        p.ProcessCode,
        ri.AsOfUtc,
        ri.CutoffUtc,
        ri.Mode,
        ri.BatchesDone,
        ri.DocsDone,
        ri.RowsDeleted,
        ri.RowsArchived,
        ri.StartedAt,
        ri.EndedAt,
        ri.Status,
        ri.ErrorMessage
    FROM arch.RunItem ri
    JOIN arch.Process p
      ON p.ProcessId = ri.ProcessId
    WHERE (@RunId IS NOT NULL AND ri.RunId = @RunId)
      AND (@RunItemId IS NULL OR ri.RunItemId = @RunItemId);

    SELECT
        r.RunId,
        r.Status,
        r.SourceDb,
        r.ArchiveDb,
        r.StartedAt,
        r.EndedAt,
        r.HostName,
        r.AppName,
        r.InitiatedBy,
        r.CancelRequestedAtUtc,
        r.CancelRequestedBy,
        r.CancelReason,
        ItemCount = COUNT(si.RunItemId),
        BatchesDone = COALESCE(SUM(si.BatchesDone), 0),
        DocsDone = COALESCE(SUM(si.DocsDone), 0),
        RowsDeleted = COALESCE(SUM(si.RowsDeleted), 0),
        RowsArchived = COALESCE(SUM(si.RowsArchived), 0),
        ErrorMessage = COALESCE(
            NULLIF(r.ErrorMessage, N''),
            MAX(NULLIF(si.ErrorMessage, N'')))
    FROM arch.Run r
    LEFT JOIN @SelectedItems si
      ON si.RunId = r.RunId
    WHERE @RunId IS NOT NULL
      AND r.RunId = @RunId
    GROUP BY
        r.RunId,
        r.Status,
        r.SourceDb,
        r.ArchiveDb,
        r.StartedAt,
        r.EndedAt,
        r.HostName,
        r.AppName,
        r.InitiatedBy,
        r.CancelRequestedAtUtc,
        r.CancelRequestedBy,
        r.CancelReason,
        r.ErrorMessage;

    SELECT TOP (@Top)
        si.RunId,
        si.RunItemId,
        si.ProcessCode,
        si.AsOfUtc,
        si.CutoffUtc,
        si.Mode,
        ModeName = CONVERT(nvarchar(30), CASE si.Mode WHEN 1 THEN N'ARCHIVE_DELETE' WHEN 2 THEN N'COPY_ONLY' ELSE N'DELETE_ONLY' END),
        si.Status,
        si.StartedAt,
        si.EndedAt,
        si.BatchesDone,
        si.DocsDone,
        si.RowsDeleted,
        si.RowsArchived,
        ProcessedRows = CASE WHEN si.Mode = 0 THEN si.RowsDeleted ELSE si.RowsArchived END,
        si.ErrorMessage
    FROM @SelectedItems si
    ORDER BY
        si.StartedAt DESC,
        si.RunItemId DESC;

    SELECT TOP (@Top)
        rio.RunItemObjectId,
        rio.RunItemId,
        si.RunId,
        si.ProcessCode,
        rio.SourceSchema,
        rio.SourceTable,
        rio.RowsDeleted,
        rio.RowsArchived,
        rio.LoggedAt
    FROM arch.RunItemObject rio
    JOIN @SelectedItems si
      ON si.RunItemId = rio.RunItemId
    ORDER BY
        rio.LoggedAt DESC,
        rio.RunItemObjectId DESC;

    SELECT TOP (@Top)
        a.RunDocAuditId,
        a.RunItemId,
        si.RunId,
        a.ProcessCode,
        a.DocKeyLabel,
        a.DocKey,
        a.DocCreatedAt,
        a.DeletedAt,
        a.Archived
    FROM arch.RunDocAudit a
    JOIN @SelectedItems si
      ON si.RunItemId = a.RunItemId
    ORDER BY
        a.DeletedAt DESC,
        a.RunDocAuditId DESC;

    SELECT TOP (@Top)
        wb.WorkBatchId,
        ProcessCode = p.ProcessCode,
        wb.SourceDb,
        wb.ArchiveDb,
        wb.RangeFromUtc,
        wb.RangeToUtc,
        wb.ModeSnapshot,
        ModeName = CONVERT(nvarchar(30), CASE wb.ModeSnapshot WHEN 1 THEN N'ARCHIVE_DELETE' WHEN 2 THEN N'COPY_ONLY' ELSE N'DELETE_ONLY' END),
        wb.Status,
        wb.PreparedAtUtc,
        wb.StartedAtUtc,
        wb.LastProgressAtUtc,
        wb.CompletedAtUtc,
        wb.LastKey1,
        wb.LastKey2,
        wb.Notes
    FROM arch.WorkBatch wb
    JOIN arch.Process p
      ON p.ProcessId = wb.ProcessId
    WHERE EXISTS
    (
        SELECT 1
        FROM @SelectedItems si
        JOIN arch.Run r
          ON r.RunId = si.RunId
        WHERE si.ProcessId = wb.ProcessId
          AND r.SourceDb = wb.SourceDb
          AND r.ArchiveDb = wb.ArchiveDb
          AND wb.PreparedAtUtc >= DATEADD(DAY, -1, r.StartedAt)
          AND wb.PreparedAtUtc < COALESCE(DATEADD(DAY, 1, r.EndedAt), SYSUTCDATETIME())
    )
    ORDER BY
        wb.PreparedAtUtc DESC,
        wb.WorkBatchId DESC;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_SearchDocumentAuditSummary]
    @DocKey nvarchar(256),
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Search nvarchar(256) = NULLIF(LTRIM(RTRIM(@DocKey)), N'');

    ;WITH Matches AS
    (
        SELECT
            a.RunDocAuditId,
            a.RunItemId,
            ri.RunId,
            ProcessCode = a.ProcessCode,
            ConfigProcessCode = p.ProcessCode,
            r.SourceDb,
            r.ArchiveDb,
            a.DocKeyLabel,
            a.DocKey,
            a.DocCreatedAt,
            a.DeletedAt,
            a.Archived
        FROM arch.RunDocAudit a
        JOIN arch.RunItem ri
          ON ri.RunItemId = a.RunItemId
        JOIN arch.Run r
          ON r.RunId = ri.RunId
        JOIN arch.Process p
          ON p.ProcessId = ri.ProcessId
        WHERE @Search IS NOT NULL
          AND a.DocKey = @Search
          AND (@ProcessCode IS NULL OR a.ProcessCode = @ProcessCode OR p.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR r.SourceDb = @SourceDb)
          AND (@ArchiveDb IS NULL OR r.ArchiveDb = @ArchiveDb)
    )
    SELECT
        ResultText = CONVERT(nvarchar(4000),
            CASE
                WHEN @Search IS NULL THEN N'Zadejte doklad pro vyhledani.'
                WHEN NOT EXISTS (SELECT 1 FROM Matches) THEN N'Doklad nebyl nalezen v audit logu.'
                ELSE N'Doklad nalezen v audit logu.'
            END),
        DocKey = @Search,
        ProcessCodes =
            STUFF((
                SELECT DISTINCT N', ' + m2.ProcessCode
                FROM Matches m2
                ORDER BY N', ' + m2.ProcessCode
                FOR XML PATH(''), TYPE
            ).value(N'.', N'nvarchar(max)'), 1, 2, N''),
        ArchivedText = CONVERT(nvarchar(10),
            CASE
                WHEN EXISTS (SELECT 1 FROM Matches WHERE Archived = 1) THEN N'ANO'
                WHEN EXISTS (SELECT 1 FROM Matches) THEN N'NE'
                ELSE NULL
            END),
        LatestDeletedAt = (SELECT MAX(DeletedAt) FROM Matches),
        LatestRunId =
            (
                SELECT TOP (1) RunId
                FROM Matches
                ORDER BY DeletedAt DESC, RunDocAuditId DESC
            ),
        LatestRunItemId =
            (
                SELECT TOP (1) RunItemId
                FROM Matches
                ORDER BY DeletedAt DESC, RunDocAuditId DESC
            ),
        SourceDb =
            (
                SELECT TOP (1) SourceDb
                FROM Matches
                ORDER BY DeletedAt DESC, RunDocAuditId DESC
            ),
        ArchiveDb =
            (
                SELECT TOP (1) ArchiveDb
                FROM Matches
                ORDER BY DeletedAt DESC, RunDocAuditId DESC
            );
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_SearchDocumentAuditDetails]
    @DocKey nvarchar(256),
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @Top int = 200
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Search nvarchar(256) = NULLIF(LTRIM(RTRIM(@DocKey)), N'');

    IF @Top IS NULL OR @Top <= 0
        SET @Top = 200;

    SELECT TOP (@Top)
        a.RunDocAuditId,
        a.RunItemId,
        ri.RunId,
        ProcessCode = a.ProcessCode,
        ConfigProcessCode = p.ProcessCode,
        r.SourceDb,
        r.ArchiveDb,
        a.DocKeyLabel,
        a.DocKey,
        a.DocCreatedAt,
        a.DeletedAt,
        a.Archived,
        ArchivedText = CONVERT(nvarchar(10), CASE a.Archived WHEN 1 THEN N'ANO' ELSE N'NE' END),
        ri.Mode,
        ModeText = CONVERT(nvarchar(30), CASE ri.Mode WHEN 1 THEN N'Archive + delete' ELSE N'Delete only' END),
        ri.CutoffUtc,
        StartedAt = ri.StartedAt,
        EndedAt = ri.EndedAt,
        RunStatus = r.Status,
        RunItemStatus = ri.Status,
        ri.BatchesDone,
        ri.DocsDone,
        ri.RowsDeleted,
        ri.RowsArchived,
        r.HostName,
        r.AppName,
        r.InitiatedBy,
        RunErrorMessage = r.ErrorMessage,
        RunItemErrorMessage = ri.ErrorMessage
    FROM arch.RunDocAudit a
    JOIN arch.RunItem ri
      ON ri.RunItemId = a.RunItemId
    JOIN arch.Run r
      ON r.RunId = ri.RunId
    JOIN arch.Process p
      ON p.ProcessId = ri.ProcessId
    WHERE @Search IS NOT NULL
      AND a.DocKey = @Search
      AND (@ProcessCode IS NULL OR a.ProcessCode = @ProcessCode OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR r.SourceDb = @SourceDb)
      AND (@ArchiveDb IS NULL OR r.ArchiveDb = @ArchiveDb)
    ORDER BY
        a.DeletedAt DESC,
        a.RunDocAuditId DESC;
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_ValidateConfiguration]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Findings
    (
        Severity varchar(10) NOT NULL,
        ProcessCode sysname NULL,
        SourceDb sysname NULL,
        ArchiveDb sysname NULL,
        ObjectName nvarchar(300) NULL,
        Finding nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL
    );

    INSERT INTO #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql)
    EXEC arch.usp_ValidateConfiguration
        @ProcessCode = @ProcessCode,
        @SourceDb = @SourceDb;

    DECLARE @ReturnCode int =
        CASE WHEN EXISTS (SELECT 1 FROM #Findings WHERE Severity = 'ERROR') THEN 1 ELSE 0 END;

    SELECT
        ReturnCode = @ReturnCode,
        Severity,
        ProcessCode,
        SourceDb,
        ArchiveDb,
        ObjectName,
        Finding,
        SuggestedSql
    FROM #Findings
    ORDER BY
        CASE Severity WHEN 'ERROR' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END,
        ProcessCode,
        SourceDb,
        ObjectName;

    RETURN COALESCE(@ReturnCode, 0);
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_ValidateIndexRequirements]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Findings
    (
        Severity varchar(10) NOT NULL,
        ProcessCode sysname NOT NULL,
        SourceDb sysname NULL,
        ObjectName nvarchar(300) NOT NULL,
        RequirementType nvarchar(20) NOT NULL,
        KeyColumnsCsv nvarchar(1000) NOT NULL,
        Finding nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL
    );

    INSERT INTO #Findings(Severity, ProcessCode, SourceDb, ObjectName, RequirementType, KeyColumnsCsv, Finding, SuggestedSql)
    EXEC arch.usp_ValidateIndexRequirements
        @ProcessCode = @ProcessCode,
        @SourceDb = @SourceDb;

    DECLARE @ReturnCode int =
        CASE WHEN EXISTS (SELECT 1 FROM #Findings WHERE Severity = 'ERROR') THEN 1 ELSE 0 END;

    SELECT
        ReturnCode = @ReturnCode,
        Severity,
        ProcessCode,
        SourceDb,
        ArchiveDb = CONVERT(sysname, NULL),
        ObjectName,
        RequirementType,
        KeyColumnsCsv,
        Finding,
        SuggestedSql
    FROM #Findings
    ORDER BY
        CASE Severity WHEN 'ERROR' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END,
        ProcessCode,
        SourceDb,
        ObjectName,
        RequirementType;

    RETURN COALESCE(@ReturnCode, 0);
END
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Api_ExplainProcessPlan]
    @ProcessCode sysname,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    EXEC arch.usp_ExplainProcessPlan
        @ProcessCode = @ProcessCode,
        @SourceDb = @SourceDb;
END
GO
