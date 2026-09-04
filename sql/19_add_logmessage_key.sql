-- ============================================================================
-- 19 - ADD A SURROGATE KEY TO ADV.dbo.t_log_message
-- ============================================================================
-- ############################################################################
-- ##  DO NOT USE. SUPERSEDED BY 24_seed_logmessage_anchor.sql.              ##
-- ##                                                                        ##
-- ##  HOUSE RULE: we never create our own objects in a WMS/vendor database. ##
-- ##  kArchiveManager writes only to kArchiveManagerAdmin and               ##
-- ##  kArchiveManagerBackups. Source databases (AAD, ADV, ...) are          ##
-- ##  read/delete only - no indexes, no columns, no constraints.            ##
-- ##                                                                        ##
-- ##  This script ADDS A COLUMN AND AN INDEX to ADV.dbo.t_log_message, so it##
-- ##  breaks that rule. It is kept only as documentation of the alternative,##
-- ##  and it must not be run without the schema owner (Koerber) explicitly  ##
-- ##  owning the change.                                                    ##
-- ##                                                                        ##
-- ##  USE 24_seed_logmessage_anchor.sql INSTEAD. It archives the same table ##
-- ##  with ZERO schema change, by anchoring on the natural composite        ##
-- ##  identity (logged_on_utc + log_sequence + process_id + thread_id +     ##
-- ##  thread_sequence) instead of a surrogate key. It is deployed and       ##
-- ##  tested: 200 rows archived in a capped run, then 13,903 in a full one, ##
-- ##  divergence 0, ntext payload intact.                                   ##
-- ############################################################################
-- (Original header follows, for the record.)
-- ============================================================================
-- WHY THIS IS NEEDED
--   kArchiveManager identifies each candidate row by a key. The TIMESTAMP
--   strategy supports exactly ONE key column, and the runner enforces that the
--   key is UNIQUE among eligible rows (#Candidates carries a UNIQUE index on
--   Key1 plus a DupCnt column; two eligible rows sharing a key abort the run
--   with THROW 50115).
--
--   dbo.t_log_message has NO usable key. Measured on the live table
--   (18,575 rows, 2025-09-11 .. 2026-09-04):
--
--     PRIMARY KEY / unique index .................. NONE
--       i_log_message                CLUSTERED,    is_unique = 0, key = logged_on_utc
--       i_log_message_logged_on_local NONCLUSTERED, is_unique = 0
--     distinct log_sequence ....................... 18,538 of 18,575  -> 37 duplicates
--     distinct logged_on_utc ...................... 12,444 of 18,575
--     distinct machine_id ......................... 1
--
--   And it is not just the single columns - no natural combination is unique
--   either. Duplicate GROUP BY groups found:
--     (log_sequence, process_id) .................................. 24
--     (log_sequence, process_id, thread_id) ....................... 15
--     (logged_on_utc, log_sequence) ............................... 25
--     (process_id, thread_id, thread_sequence) .................... 144
--     (logged_on_utc, log_sequence, process_id, thread_id, thread_sequence) .. 2
--     + resource_code + line_number ............................... 2
--
--   Those last two groups are FULLY IDENTICAL rows (2 pairs). So the table
--   genuinely has no natural key, and a composite key would not help even if the
--   product supported one (arch.WorkBatchKey's PK is (WorkBatchId, Key1, Key2),
--   so Key1+Key2 must be unique - and they are not).
--
--   A surrogate IDENTITY column is therefore the only way to archive this table
--   through kArchiveManager with a full audit trail and a working restore path.
--
-- WHAT THIS DOES
--   Adds  kam_row_id bigint IDENTITY(1,1) NOT NULL  and a UNIQUE index on it.
--   * Adding a NOT NULL IDENTITY column is a metadata-only operation for the
--     column itself, but SQL Server must still stamp every existing row, so it
--     takes a schema-modification lock for the duration. On 18.5k rows that is
--     instant; on a multi-million-row log table, schedule it.
--   * It does NOT change any existing column, index or constraint.
--   * The name is prefixed kam_ so it is obviously not vendor-owned.
--
-- REVERSIBLE
--   DROP INDEX [UX_KAM_t_log_message_kam_row_id] ON [dbo].[t_log_message];
--   ALTER TABLE [dbo].[t_log_message] DROP COLUMN [kam_row_id];
--
-- VENDOR CAVEAT
--   ADV is a Koerber Advantage database. Adding a column to a vendor table needs
--   sign-off, and a vendor upgrade that rebuilds the table will drop it - after
--   which this script must be re-run and the archive process re-validated.
--
-- ALTERNATIVE IF YOU DO NOT WANT TO TOUCH THE SCHEMA
--   A log table is append-only, so a plain date-driven purge needs no row key:
--     DELETE TOP (4000) FROM dbo.t_log_message WHERE logged_on_utc < @cutoff;
--   in a loop. That is simple and safe, but it gives up everything
--   kArchiveManager adds: the archived copy, the run audit trail, the retention
--   floor, legal holds and the restore path. Decide deliberately.
-- ============================================================================
:setvar SourceDb "ADV"
:setvar Apply "0"

:on error exit

USE [$(SourceDb)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @Apply bit = CONVERT(bit, $(Apply));

IF OBJECT_ID(N'dbo.t_log_message', N'U') IS NULL
    THROW 60400, 'dbo.t_log_message does not exist in this database.', 1;

-- Current state
SELECT
    Section       = 'CURRENT_STATE',
    Rows_         = (SELECT ISNULL(SUM(p.rows), 0) FROM sys.partitions p
                     WHERE p.object_id = OBJECT_ID(N'dbo.t_log_message') AND p.index_id IN (0,1)),
    HasKeyColumn  = CASE WHEN COL_LENGTH(N'dbo.t_log_message', N'kam_row_id') IS NOT NULL THEN 'yes' ELSE 'NO' END,
    UniqueIndexes = (SELECT COUNT(*) FROM sys.indexes i
                     WHERE i.object_id = OBJECT_ID(N'dbo.t_log_message') AND i.is_unique = 1),
    Verdict       = CASE
                        WHEN COL_LENGTH(N'dbo.t_log_message', N'kam_row_id') IS NOT NULL
                             THEN 'OK - surrogate key already present'
                        WHEN @Apply = 1 THEN 'WILL ADD kam_row_id'
                        ELSE 'would add kam_row_id (preview; set Apply=1)'
                    END;

IF @Apply = 1
BEGIN
    IF COL_LENGTH(N'dbo.t_log_message', N'kam_row_id') IS NULL
    BEGIN
        PRINT 'Adding kam_row_id bigint IDENTITY(1,1) NOT NULL ...';
        ALTER TABLE dbo.t_log_message ADD kam_row_id bigint IDENTITY(1,1) NOT NULL;
        PRINT 'Column added.';
    END
    ELSE
        PRINT 'kam_row_id already present - skipped.';

    IF NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE object_id = OBJECT_ID(N'dbo.t_log_message')
                     AND name = N'UX_KAM_t_log_message_kam_row_id')
    BEGIN
        PRINT 'Creating UX_KAM_t_log_message_kam_row_id ...';
        -- Unique, so the archiver's key assumption is enforced by the engine
        -- rather than merely assumed. Also gives the delete join a seek.
        CREATE UNIQUE NONCLUSTERED INDEX [UX_KAM_t_log_message_kam_row_id]
            ON dbo.t_log_message (kam_row_id);
        PRINT 'Index created.';
    END
    ELSE
        PRINT 'Unique index already present - skipped.';

    -- The candidate scan filters and orders by logged_on_utc. The clustered
    -- index already leads on it, so no extra index is needed for selection.
    PRINT '';
    PRINT 'NOTE: the clustered index i_log_message already leads on logged_on_utc,';
    PRINT '      so the retention scan is a clustered range seek. No extra index needed.';
END;
GO

-- Verify the key really is unique now.
-- This MUST go through dynamic SQL: SQL Server compiles the whole batch before
-- executing it, so a static reference to kam_row_id fails with Msg 207 even
-- inside an IF branch that would never run when the column is absent.
IF COL_LENGTH(N'dbo.t_log_message', N'kam_row_id') IS NOT NULL
BEGIN
    DECLARE @ver nvarchar(max) = N'
    DECLARE @rows bigint, @distinct bigint;
    SELECT @rows = COUNT_BIG(*), @distinct = COUNT_BIG(DISTINCT kam_row_id) FROM dbo.t_log_message;
    SELECT
        Section      = ''KEY_VERIFICATION'',
        Rows_        = @rows,
        DistinctKeys = @distinct,
        Verdict      = CASE WHEN @rows = @distinct
                            THEN ''OK - kam_row_id is unique; the TIMESTAMP single-key requirement is satisfied''
                            ELSE ''STOP - kam_row_id is NOT unique, which should be impossible for an IDENTITY column'' END;';
    EXEC sys.sp_executesql @ver;
END
ELSE
    PRINT 'KEY_VERIFICATION skipped - kam_row_id not present (preview mode).';
GO

SELECT
    Section = 'INDEXES_NOW',
    IndexName = i.name,
    i.type_desc,
    i.is_unique,
    KeyCols = STUFF((SELECT N', ' + c.name
                     FROM sys.index_columns ic
                     JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                     WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                     ORDER BY ic.key_ordinal
                     FOR XML PATH(''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'')
FROM sys.indexes i
WHERE i.object_id = OBJECT_ID(N'dbo.t_log_message') AND i.type > 0
ORDER BY i.is_unique DESC, i.name;
GO

PRINT '';
PRINT '19_add_logmessage_key: done.';
GO
