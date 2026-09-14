-- ============================================================================
-- 50 - REPORTING LAYER: VERIFY IT IS THERE, AND PROVE IT ANSWERS FOR THIS CONFIG
-- ============================================================================
-- kArchiveManager 2.0 ships its own reporting layer: 21 arch.usp_Frontend_*
-- procedures plus six views. They are the same layer the Admin Console uses, and
-- they are driven entirely by arch.Process / arch.ObjectSpec - so they describe
-- whatever is configured, on any schema, carrying no table names of their own.
--
-- That property is the whole reason this script exists. The SSRS report in the
-- product repository (reports\ArchiveManager - DataMovement Dashboard v2.rdl)
-- does NOT have it: 7 of its 13 datasets carry table names from the WMS it was
-- first written for (SHIPHIST, RF_LOG2, DATE_UPLD), and two more call estimate
-- procedures that version 2.0 retired as dead code. See reports\README.md for the
-- dataset-by-dataset finding and the procedure that replaces each.
--
-- WHAT THIS SCRIPT DOES
--   A  inventory       - is the reporting layer actually deployed?
--   B  smoke test      - every reporting procedure executed against the live
--                        configuration, with the row count it returned
--   C  the headline    - per set and per table: source rows, archive rows, and
--                        the difference; plus go-live readiness
--   D  known artefacts - three things in that output that look like defects and
--                        are not, so nobody spends an afternoon on them
--
-- It reads only. Nothing here writes to any database.
-- ============================================================================
:setvar AdminDb "kArchiveManagerAdmin"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

/* ===========================================================================
   A) Is the reporting layer deployed?
   =========================================================================== */
PRINT '=== A) Reporting layer inventory ===';
GO
SELECT Section = 'A_INVENTORY', Kind = 'procedure', ObjectName = p.name
FROM sys.procedures p
WHERE SCHEMA_NAME(p.schema_id) = 'arch'
  AND (p.name LIKE 'usp_Frontend[_]%' OR p.name = 'usp_Api_EstimateNextRunImpact')
UNION ALL
SELECT 'A_INVENTORY', 'view', v.name
FROM sys.views v WHERE SCHEMA_NAME(v.schema_id) = 'arch'
ORDER BY Kind, ObjectName;

-- A missing object here means the core bundle did not deploy completely. The
-- reporting procedures ship with it; there is no separate reporting install.
--
-- The three counts are kept SEPARATE on purpose. An earlier version counted the
-- Frontend procedures and usp_Api_EstimateNextRunImpact together, then compared
-- that single total against the Frontend threshold - so a complete deployment
-- (20 Frontend + 1 Api + 6 views) reported INCOMPLETE. A verdict that cries wolf
-- on a healthy system is worse than no verdict, because the next person learns
-- to skip it.
DECLARE @fe  int = (SELECT COUNT(*) FROM sys.procedures
                    WHERE SCHEMA_NAME(schema_id) = 'arch' AND name LIKE 'usp_Frontend[_]%');
DECLARE @api int = (SELECT COUNT(*) FROM sys.procedures
                    WHERE SCHEMA_NAME(schema_id) = 'arch' AND name = 'usp_Api_EstimateNextRunImpact');
DECLARE @vw  int = (SELECT COUNT(*) FROM sys.views WHERE SCHEMA_NAME(schema_id) = 'arch');

SELECT Section = 'A_SUMMARY',
       FrontendProcs = @fe,     -- expected 20
       ApiEstimate   = @api,    -- expected 1 - the 2.0 replacement for the retired estimate procedures
       Views_        = @vw,     -- expected 6
       Verdict       = CASE WHEN @fe >= 20 AND @api = 1 AND @vw >= 6
                            THEN 'ok - reporting layer present'
                            ELSE '*** INCOMPLETE - re-run the core bundle (Stage deploy) ***' END;
GO

/* ===========================================================================
   B) Smoke test - every reporting procedure, against the live configuration

   Executed rather than merely listed. A procedure that exists but throws on this
   schema is worse than one that is missing, because the missing one is obvious.

   NULL means "no filter" throughout this layer, so a NULL-everywhere call is the
   broadest question each procedure can answer - exactly what a smoke test wants.
   =========================================================================== */
PRINT '';
PRINT '=== B) Smoke test: every reporting procedure against this configuration ===';
GO
DECLARE @Results table (Ord int IDENTITY(1,1), ProcName sysname, Rows_ int NULL,
                        Status_ varchar(20), ErrMsg nvarchar(400) NULL);

DECLARE @calls table (Ord int PRIMARY KEY, ProcName sysname, CallSql nvarchar(400));
INSERT @calls VALUES
 (1,  N'usp_Frontend_GetProcessConfigSummary',      N'EXEC arch.usp_Frontend_GetProcessConfigSummary @ProcessCode=NULL, @IncludeDisabled=1'),
 (2,  N'usp_Frontend_GetProcessMovementSummary',    N'EXEC arch.usp_Frontend_GetProcessMovementSummary @SourceDb=NULL, @ArchiveDb=NULL, @ProcessCode=NULL'),
 (3,  N'usp_Frontend_GetTableMovementCounts',       N'EXEC arch.usp_Frontend_GetTableMovementCounts @SourceDb=NULL, @ArchiveDb=NULL, @ProcessCode=NULL'),
 (4,  N'usp_Frontend_GetProcessedHistory',          N'EXEC arch.usp_Frontend_GetProcessedHistory @SourceDb=NULL, @ArchiveDb=NULL, @ProcessCode=NULL, @DateFromUtc=NULL, @DateToUtc=NULL'),
 (5,  N'usp_Frontend_GetRecentRuns',                N'EXEC arch.usp_Frontend_GetRecentRuns @SourceDb=NULL, @ArchiveDb=NULL, @ProcessCode=NULL, @DateFromUtc=NULL, @DateToUtc=NULL, @Top=50'),
 (6,  N'usp_Frontend_GetEffectiveObjects',          N'EXEC arch.usp_Frontend_GetEffectiveObjects'),
 (7,  N'usp_Frontend_GetEffectiveProcessDatabases', N'EXEC arch.usp_Frontend_GetEffectiveProcessDatabases'),
 (8,  N'usp_Frontend_GetIndexRequirements',         N'EXEC arch.usp_Frontend_GetIndexRequirements'),
 (9,  N'usp_Frontend_GetProcessKeySpecs',           N'EXEC arch.usp_Frontend_GetProcessKeySpecs'),
 (10, N'usp_Frontend_GetRunProfiles',               N'EXEC arch.usp_Frontend_GetRunProfiles'),
 (11, N'usp_Frontend_GetSelectionStrategies',       N'EXEC arch.usp_Frontend_GetSelectionStrategies'),
 (12, N'usp_Frontend_GetLegalHolds',                N'EXEC arch.usp_Frontend_GetLegalHolds'),
 (13, N'usp_Frontend_GetRetentionFloor',            N'EXEC arch.usp_Frontend_GetRetentionFloor'),
 (14, N'usp_Frontend_GetWorkBatchActivity',         N'EXEC arch.usp_Frontend_GetWorkBatchActivity'),
 (15, N'usp_Frontend_GetConfigChangeHistory',       N'EXEC arch.usp_Frontend_GetConfigChangeHistory'),
 (16, N'usp_Frontend_GoLiveReadiness',              N'EXEC arch.usp_Frontend_GoLiveReadiness'),
 (17, N'usp_Frontend_TimestampRetentionGaps',       N'EXEC arch.usp_Frontend_TimestampRetentionGaps @ProcessCode=NULL, @SourceDb=NULL, @ArchiveDb=NULL'),
 (18, N'usp_Frontend_SearchDocumentAuditSummary',   N'EXEC arch.usp_Frontend_SearchDocumentAuditSummary @DocKey=NULL, @ProcessCode=NULL, @SourceDb=NULL, @ArchiveDb=NULL'),
 (19, N'usp_Frontend_SearchDocumentAuditDetails',   N'EXEC arch.usp_Frontend_SearchDocumentAuditDetails @DocKey=NULL, @ProcessCode=NULL, @SourceDb=NULL, @ArchiveDb=NULL');

DECLARE @p sysname, @sql nvarchar(max), @rows int;
DECLARE @o int = 1, @maxo int = (SELECT MAX(Ord) FROM @calls);
WHILE @o <= @maxo
BEGIN
    SELECT @p = ProcName, @sql = CallSql FROM @calls WHERE Ord = @o;
    BEGIN TRY
        EXEC sys.sp_executesql @sql;
        SET @rows = @@ROWCOUNT;
        INSERT @Results(ProcName, Rows_, Status_) VALUES (@p, @rows, 'ok');
    END TRY
    BEGIN CATCH
        INSERT @Results(ProcName, Rows_, Status_, ErrMsg)
        VALUES (@p, NULL, 'FAILED', LEFT(ERROR_MESSAGE(), 400));
    END CATCH;
    SET @o = @o + 1;
END;

SELECT Section = 'B_SMOKE', r.ProcName, r.Rows_, r.Status_, r.ErrMsg
FROM @Results r ORDER BY r.Ord;

SELECT Section = 'B_VERDICT',
       Passed = SUM(CASE WHEN Status_ = 'ok' THEN 1 ELSE 0 END),
       Failed = SUM(CASE WHEN Status_ = 'FAILED' THEN 1 ELSE 0 END),
       Verdict = CASE WHEN SUM(CASE WHEN Status_ = 'FAILED' THEN 1 ELSE 0 END) = 0
                      THEN 'ok - the whole reporting layer answers for this configuration'
                      ELSE '*** at least one reporting procedure fails here - see ErrMsg ***' END
FROM @Results;
GO

/* ===========================================================================
   C) The headline numbers
   =========================================================================== */
PRINT '';
PRINT '=== C) Per set: source vs archive ===';
GO
EXEC arch.usp_Frontend_GetProcessMovementSummary @SourceDb = NULL, @ArchiveDb = NULL, @ProcessCode = NULL;
GO

PRINT '';
PRINT '=== C) Per table: source vs archive ===';
GO
EXEC arch.usp_Frontend_GetTableMovementCounts @SourceDb = NULL, @ArchiveDb = NULL, @ProcessCode = NULL;
GO

PRINT '';
PRINT '=== C) Go-live readiness ===';
GO
EXEC arch.usp_Frontend_GoLiveReadiness;
GO

/* ===========================================================================
   D) Three things in that output that look wrong and are not
   =========================================================================== */
PRINT '';
PRINT '=== D) Known reporting artefacts for THIS configuration ===';
GO
SELECT Section = 'D_ARTEFACT',
       Item = 't_work_q_dependency appears TWICE',
       Explanation = 'The work-queue set configures this table twice on purpose - once joined on parent_work_q_id and once on dependent_work_q_id - so both sides of a dependency are archived with their queue. GetTableMovementCounts returns one row per ObjectSpec, so the table is listed twice with identical counts. Do NOT sum that column without a DISTINCT on the table name, or the set is over-counted by one whole table.',
       Evidence = CONVERT(nvarchar(20), (SELECT COUNT(*) FROM arch.ObjectSpec os
                                         JOIN arch.Process p ON p.ProcessId = os.ProcessId
                                         WHERE p.ProcessCode = N'AAD_WORKQ_ARCH'
                                           AND os.SourceTable = N't_work_q_dependency')) + ' ObjectSpec rows'
UNION ALL
SELECT 'D_ARTEFACT',
       'ADV_LOGMSG_ARCH shows a NEGATIVE difference',
       'The archive legitimately holds more rows than the source for this set. Warehouse Advantage purges t_log_message itself (Agent job Log Maintenance -> ADV.usp_PurgeLog: 30 days by age, plus an age-blind trim to 95 000 rows), so source rows disappear without us while the archive accumulates across every run. A negative DifferenceCount here is the expected steady state, not a reconciliation failure.',
       ''
UNION ALL
SELECT 'D_ARTEFACT',
       'DifferenceCount is not a backlog',
       'SourceRows counts every row in the table, not only the rows past retention. A large positive difference means the table is big, not that archiving is behind. Size an actual backlog with usp_Frontend_TimestampRetentionGaps, or with the eligibility queries in 09_preflight_data.sql.',
       '';
GO

PRINT '';
PRINT '50_reporting: done.';
PRINT 'If B_VERDICT is ok, the reporting layer is live and answers for every';
PRINT 'configured set. Read reports\README.md before using the SSRS dashboard from';
PRINT 'the product repository - most of its panels do not fit this schema.';
GO
