USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER VIEW [arch].[v_LastRunPerProcess]
AS
WITH x AS
(
    SELECT
        p.ProcessCode,
        p.Description,
        r.SourceDb,
        r.ArchiveDb,
        ri.RunItemId,
        r.RunId,
        ri.StartedAt,
        ri.EndedAt,
        ri.Status,
        ri.RowsDeleted,
        ri.RowsArchived,
        ri.DocsDone,
        ROW_NUMBER() OVER
        (
            PARTITION BY p.ProcessCode, r.SourceDb, r.ArchiveDb
            ORDER BY ri.StartedAt DESC, ri.RunItemId DESC
        ) AS rn
    FROM arch.Process p
    JOIN arch.RunItem ri
      ON ri.ProcessId = p.ProcessId
    JOIN arch.Run r
      ON r.RunId = ri.RunId
)
SELECT
    ProcessCode,
    Description,
    SourceDb,
    ArchiveDb,
    RunId,
    RunItemId,
    StartedAt,
    EndedAt,
    Status,
    DocsDone,
    RowsDeleted,
    RowsArchived
FROM x
WHERE rn = 1;
GO

CREATE OR ALTER VIEW [arch].[v_RunItemsRecent]
AS
SELECT TOP (5000)
    r.RunId,
    p.ProcessCode,
    r.SourceDb,
    r.ArchiveDb,
    ri.RunItemId,
    ri.AsOfUtc,
    ri.CutoffUtc,
    ri.Mode,
    ri.Status,
    ri.StartedAt,
    ri.EndedAt,
    ri.BatchesDone,
    ri.DocsDone,
    ri.RowsDeleted,
    ri.RowsArchived,
    ri.ErrorMessage
FROM arch.RunItem ri
JOIN arch.Run r
  ON r.RunId = ri.RunId
JOIN arch.Process p
  ON p.ProcessId = ri.ProcessId
ORDER BY ri.StartedAt DESC, ri.RunItemId DESC;
GO

CREATE OR ALTER VIEW [arch].[v_RunDocAuditDetailed]
AS
SELECT
    a.RunDocAuditId,
    a.RunItemId,
    ri.RunId,
    ri.ProcessId,
    ProcessCode = a.ProcessCode,
    ConfigProcessCode = p.ProcessCode,
    r.SourceDb,
    r.ArchiveDb,
    a.DocKeyLabel,
    a.DocKey,
    a.DocCreatedAt,
    a.DeletedAt,
    a.Archived,
    ri.AsOfUtc,
    ri.CutoffUtc,
    ri.Mode,
    RunStatus = r.Status,
    RunStartedAt = r.StartedAt,
    RunEndedAt = r.EndedAt,
    RunItemStatus = ri.Status,
    RunItemStartedAt = ri.StartedAt,
    RunItemEndedAt = ri.EndedAt,
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
  ON p.ProcessId = ri.ProcessId;
GO
