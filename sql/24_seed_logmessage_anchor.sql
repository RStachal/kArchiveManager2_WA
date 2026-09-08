-- ============================================================================
-- 24 - ADV.dbo.t_log_message via ANCHOR on its natural composite key
--      (the alternative to 19_add_logmessage_key.sql - NO schema change)
-- ============================================================================
-- WHY ANCHOR AND NOT TIMESTAMP
--   t_log_message has no PRIMARY KEY and no unique index, and TIMESTAMP supports
--   exactly ONE key column, so the timestamp route needs a surrogate key added to
--   the table (see 19_add_logmessage_key.sql).
--   ANCHOR carries Key1..Key8, so the table can anchor ITSELF on its natural
--   composite identity - no schema change at all.
--
-- THE KEY, AND WHY IT IS THESE FIVE COLUMNS
--   Measured on the live table (18,822 rows). Duplicate GROUP BY groups:
--       log_sequence ............................................ 37 dup rows
--       log_sequence, process_id ................................ 24 groups
--       log_sequence, process_id, thread_id ..................... 15 groups
--       logged_on_utc, log_sequence ............................. 25 groups
--       logged_on_utc, log_sequence, process_id, thread_id ...... 15 groups / 40 rows
--     + thread_sequence ......................................... 2 groups
--   thread_sequence is the column that actually separates them - within each
--   4-column duplicate group the rows differ only by it (e.g. 68/69, 1/2,
--   70/71/72). Adding it takes the table from 15 duplicate groups down to 2.
--
--   Those last 2 groups are pairs of FULLY IDENTICAL rows (verified: even a
--   7-column grouping leaves the same 2). They are harmless here, and this is
--   the part worth understanding:
--
--     arch.usp_PrepareCandidates deduplicates the candidate set itself. Lines
--     388-405 build a "dedupe" CTE with
--         ROW_NUMBER() OVER (PARTITION BY <Key1..Key8> ORDER BY <...>)
--     and then take WHERE rn = 1. So a repeated key yields ONE keyset row - it
--     cannot violate PK_WorkBatchKey (WorkBatchId, Key1, Key2).
--     At delete time the join matches BOTH identical source rows, so both are
--     archived and both are deleted: RowsArchived = RowsDeleted, divergence 0.
--     Identical rows are simply processed together, which is the correct outcome.
--
-- THE TIMEZONE
--   logged_on_utc is datetime NOT NULL and is ALREADY UTC - the table carries a
--   separate logged_on_local for local time. The wrapper must therefore NOT shift
--   the value: 'UTC' -> 'UTC' is a deliberate no-op that exists only to satisfy
--   the timezone gate (arch.usp_AssertTimezonePolicyApplied, THROW 50200, requires
--   the literal text AT TIME ZONE). Using the CET wrapper here would silently move
--   the cutoff by one or two hours.
--
-- FORMAT 126 IS NOT COSMETIC
--   Key values are carried as nvarchar(256): the runner emits
--   Key<i> = CONVERT(nvarchar(256), <SourceExpressionSql>). Converting a datetime
--   to a string with the DEFAULT style is language-dependent, so the key would
--   change shape with the session language and stop matching. Style 126 (ISO 8601)
--   is culture-invariant, so the key is stable. The join converts back with the
--   same style. The conversion sits on the KEYSET side of the predicate
--   (k.Key1), leaving t.logged_on_utc bare so the clustered index i_log_message
--   (which leads on logged_on_utc) is still seekable.
--
-- WHICH OF THE TWO APPROACHES TO USE
--   This one       : no schema change, slightly more complex config, join needs a
--                    conversion on the keyset side.
--   19_add_...key  : one added IDENTITY column, simplest possible config and a
--                    clean single-column seek, but it touches a vendor table and a
--                    vendor upgrade that rebuilds the table would drop it.
--   Both are correct. This script is the default because it changes nothing in ADV.
-- ============================================================================
:setvar AdminDb   "kArchiveManagerAdmin"
:setvar AdvDb     "ADV"
:setvar ArchiveDb "kArchiveManagerBackups"
-- RetentionDays is a REQUEST, not the final value: it is clamped to sit inside
-- ADV's own log purge window (t_adv_control.LogPurgeMaximumDays). See the block
-- above the usp_Api_SaveProcess call - at 90 days this process archives nothing.
:setvar RetentionDays "90"
:setvar ProcessCode "ADV_LOGMSG_ARCH"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF DB_ID(N'$(AdvDb)') IS NULL THROW 60600, 'ADV source database does not exist.', 1;
IF OBJECT_ID(N'$(AdvDb)' + N'.dbo.t_log_message', N'U') IS NULL
    THROW 60601, 'ADV.dbo.t_log_message does not exist.', 1;
GO

DECLARE @Pc     sysname        = N'$(ProcessCode)';
DECLARE @By     nvarchar(256)  = N'kam-deploy';
DECLARE @Reason nvarchar(1000) = N'Application log retention, self-anchored on the natural composite identity (no schema change).';
DECLARE @CsId   bigint         = NULL;
DECLARE @KsId   int            = NULL;
DECLARE @OsId   int            = NULL;

-- Cutoff: already-UTC column, wrapped as a no-op purely for the gate.
DECLARE @AnchorTs nvarchar(4000) =
    N'TRY_CONVERT(datetime2, a.logged_on_utc) AT TIME ZONE N''UTC'' AT TIME ZONE N''UTC''';

-------------------------------------------------------------------------------
-- WAREHOUSE ADVANTAGE ALREADY PURGES THIS TABLE, AND IT WILL WIN
--
-- ADV ships its own housekeeping: Agent job 'Log Maintenance' -> ADV.usp_PurgeLog,
-- driven by three rows in ADV.dbo.t_adv_control:
--     LogPurgeMaximumDays  DELETE ... WHERE DATEDIFF(day, logged_on_utc, GETUTCDATE()) > n
--     LogPurgeMaximumSize  if COUNT(*) exceeds this, delete oldest down to
--     LogPurgeToSize       ... this many rows, REGARDLESS OF AGE
-- On the reference instance: 30 days / 100000 rows / 95000 rows.
--
-- So a retention of 90 days archives NOTHING, EVER. Our cutoff would select rows
-- older than 90 days; ADV deleted them at 30. The two windows are disjoint and no
-- amount of waiting fixes it - the run reports success with zero rows forever.
-- This was found empirically: 300000 seeded log rows vanished 29 seconds after
-- the seed finished, with no archive run and no trace in arch.Run.
--
-- Retention is therefore CLAMPED to sit inside ADV's own window, with a week of
-- headroom so a late run still finds rows. kArchiveManager then captures the
-- messages into the archive database BEFORE ADV discards them, which is the whole
-- point of archiving a table that something else already prunes.
--
-- The size cap is NOT defended against here - it is age-blind, so if the table
-- exceeds LogPurgeMaximumSize the purge takes the oldest rows whatever we do. The
-- only real answer is to run often enough that the table stays under the cap;
-- 09_preflight_data.sql reports the current count against it.
-------------------------------------------------------------------------------
DECLARE @Requested int = $(RetentionDays);
DECLARE @PurgeDays int, @PurgeMaxRows int, @PurgeToRows int;

DECLARE @ctl nvarchar(max) =
    N'SELECT @d = MAX(CASE WHEN string_key = ''LogPurgeMaximumDays'' THEN TRY_CONVERT(int, string_value) END),
             @m = MAX(CASE WHEN string_key = ''LogPurgeMaximumSize'' THEN TRY_CONVERT(int, string_value) END),
             @t = MAX(CASE WHEN string_key = ''LogPurgeToSize''      THEN TRY_CONVERT(int, string_value) END)
      FROM ' + QUOTENAME(N'$(AdvDb)') + N'.dbo.t_adv_control;';
EXEC sys.sp_executesql @ctl,
     N'@d int OUTPUT, @m int OUTPUT, @t int OUTPUT',
     @d = @PurgeDays OUTPUT, @m = @PurgeMaxRows OUTPUT, @t = @PurgeToRows OUTPUT;

DECLARE @Effective int = @Requested;

IF @PurgeDays IS NULL
    PRINT 'INFO: no LogPurgeMaximumDays in t_adv_control - keeping the requested retention of '
          + CAST(@Requested AS varchar(10)) + ' days. Verify that nothing else prunes this table.';
ELSE IF @PurgeDays > 0 AND @Requested >= @PurgeDays
BEGIN
    SET @Effective = CASE WHEN @PurgeDays - 7 < 1 THEN 1 ELSE @PurgeDays - 7 END;
    PRINT '*** RETENTION CLAMPED ***';
    PRINT '    requested        : ' + CAST(@Requested AS varchar(10)) + ' days';
    PRINT '    ADV purges after : ' + CAST(@PurgeDays AS varchar(10)) + ' days (t_adv_control.LogPurgeMaximumDays)';
    PRINT '    effective        : ' + CAST(@Effective AS varchar(10)) + ' days';
    PRINT '    Reason: at the requested value every eligible row would already have been';
    PRINT '    deleted by ADV.usp_PurgeLog, so this process would archive nothing at all.';
END
ELSE
    PRINT 'INFO: requested retention (' + CAST(@Requested AS varchar(10))
          + ' d) is inside the ADV purge window (' + CAST(@PurgeDays AS varchar(10)) + ' d). No clamp needed.';

IF @PurgeMaxRows > 0
    PRINT 'INFO: ADV also enforces a size cap - over ' + CAST(@PurgeMaxRows AS varchar(10))
          + ' rows it deletes the oldest down to ' + CAST(ISNULL(@PurgeToRows, 0) AS varchar(10))
          + ' regardless of age. Run this process often enough to stay under that.';

EXEC arch.usp_Api_SaveProcess
    @ProcessCode               = @Pc,
    @RequestedBy               = @By,
    @ChangeReason              = @Reason,
    @Description               = N'ADV application log history (t_log_message), anchored on its natural composite key.',
    @IsEnabled                 = 1,
    @Mode                      = 1,
    @RetentionDays             = @Effective,
    @CutoffSafetyLagMinutes    = 1440,
    @CutoffMode                = 0,
    @BatchDocCount             = 2000,   -- one "document" == one log row
    @MaxBatchesPerRun          = 250,
    @DelayMsBetweenBatches     = 0,
    @UseAppLock                = 1,
    @LockTimeoutMs             = 10000,
    @DeadlockPriority          = N'LOW',
    @AnchorSchema              = N'dbo',
    @AnchorTable               = N't_log_message',
    @AnchorDocKeyExpr          = N'logged_on_utc',
    @AnchorDocKey2Expr         = N'log_sequence',
    @AnchorTimestampExpr       = @AnchorTs,
    @AnchorExtraWhereSql       = NULL,
    @AllowDeleteWithoutArchive = 0,
    @DocKeyLabel               = N'LOG_ROW',
    @AuditLevel                = N'NONE',   -- a per-row audit would dwarf the log itself
    @ConfigChangeSetId         = @CsId OUTPUT;

UPDATE arch.Process
SET SelectionStrategy      = N'ANCHOR',
    RequireSupportingIndex = 1,
    MaxRowsPerTransaction  = 2000,
    ModifiedAt             = SYSUTCDATETIME()
WHERE ProcessCode = @Pc;

-------------------------------------------------------------------------------
-- KEY LAYOUT - KEY1 CARRIES THE WHOLE IDENTITY ON ITS OWN. THIS IS DELIBERATE.
--
-- arch.WorkBatchKey's primary key is (WorkBatchId, Key1, Key2) - Key3..Key8 are
-- ordinary columns added later and are NOT part of it. So the UNIQUENESS the
-- prepared batch needs is on Key1+Key2 alone, and usp_ValidateConfiguration warns
-- about exactly this whenever a process declares keys beyond Key2.
--
-- Spreading the five identity columns across Key1..Key5 would therefore NOT work:
-- (logged_on_utc, log_sequence) has 25 duplicate groups in this table, and the
-- dedupe CTE partitions by ALL keys - so two rows differing only in Key3..Key5
-- survive deduplication as two candidates and then collide on the primary key.
--
-- Instead Key1 is the full composite rendered as one delimited string, which is
-- unique by construction, and Key2..Key6 repeat the individual columns purely so
-- the delete join can compare real typed values instead of parsing the string.
-- Delimiter '|' is safe: every part is a datetime or a bigint, so none can contain it.
-- ISO 8601 (style 126) keeps the datetime part culture-invariant - the default
-- style is language-dependent and the key would change shape with the session.
-------------------------------------------------------------------------------
DECLARE @keys table (Ord tinyint PRIMARY KEY, KeyName sysname, ExprSql nvarchar(4000));
INSERT @keys VALUES
    (1, N'row_identity',    N'CONVERT(nvarchar(30), a.logged_on_utc, 126) + N''|'' + CONVERT(nvarchar(20), a.log_sequence) + N''|'' + CONVERT(nvarchar(20), a.process_id) + N''|'' + CONVERT(nvarchar(20), a.thread_id) + N''|'' + CONVERT(nvarchar(20), a.thread_sequence)'),
    (2, N'logged_on_utc',   N'CONVERT(nvarchar(30), a.logged_on_utc, 126)'),
    (3, N'log_sequence',    N'a.log_sequence'),
    (4, N'process_id',      N'a.process_id'),
    (5, N'thread_id',       N'a.thread_id'),
    (6, N'thread_sequence', N'a.thread_sequence');

DECLARE @o tinyint, @kn sysname, @ke nvarchar(4000);
DECLARE ck CURSOR LOCAL FAST_FORWARD FOR SELECT Ord, KeyName, ExprSql FROM @keys ORDER BY Ord;
OPEN ck; FETCH NEXT FROM ck INTO @o, @kn, @ke;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @KsId = NULL;
    EXEC arch.usp_Api_SaveProcessKeySpec
        @ProcessKeySpecId    = @KsId OUTPUT,
        @ProcessCode         = @Pc,
        @RequestedBy         = @By,
        @ChangeReason         = @Reason,
        @KeyOrdinal          = @o,
        @KeyName             = @kn,
        @SourceExpressionSql = @ke,
        @SqlType             = N'nvarchar(256)',
        @IsRequired          = 1,
        @ConfigChangeSetId   = @CsId OUTPUT;
    FETCH NEXT FROM ck INTO @o, @kn, @ke;
END;
CLOSE ck; DEALLOCATE ck;

-- Drop any leftover higher ordinal from an earlier revision.
DELETE ks FROM arch.ProcessKeySpec ks JOIN arch.Process p ON p.ProcessId = ks.ProcessId
WHERE p.ProcessCode = @Pc AND ks.KeyOrdinal > 6;

-------------------------------------------------------------------------------
-- Mapping. Second source database; ArchiveSchema '{SourceDb}' puts the rows in
-- <ArchiveDb>.ADV.*, separate from the AAD schema in the same archive database.
-------------------------------------------------------------------------------
EXEC arch.usp_Api_SaveProcessDatabase
    @ProcessCode       = @Pc,
    @SourceDb          = N'$(AdvDb)',
    @ArchiveDb         = N'$(ArchiveDb)',
    @RequestedBy       = @By,
    @ChangeReason      = @Reason,
    @IsEnabled         = 1,
    @RunOrder          = 50,
    @ConfigChangeSetId = @CsId OUTPUT;

-------------------------------------------------------------------------------
-- The single object: the table is its own anchor.
-- t.logged_on_utc is left BARE on the left of the predicate; the conversion is on
-- the keyset side, so the clustered index stays seekable.
-------------------------------------------------------------------------------
-- Joins on Key2..Key6 (the typed columns), NOT on Key1 - Key1 is the delimited
-- identity string and parsing it here would be both slow and non-sargable.
DECLARE @Join nvarchar(4000) =
    N't.logged_on_utc = CONVERT(datetime, k.Key2, 126)'
  + N' AND t.log_sequence = CONVERT(bigint, k.Key3)'
  + N' AND t.process_id = CONVERT(bigint, k.Key4)'
  + N' AND t.thread_id = CONVERT(bigint, k.Key5)'
  + N' AND t.thread_sequence = CONVERT(bigint, k.Key6)';

SET @OsId = NULL;
EXEC arch.usp_Api_SaveObjectSpec
    @ObjectSpecId             = @OsId OUTPUT,
    @ProcessCode              = @Pc,
    @RequestedBy              = @By,
    @ChangeReason             = @Reason,
    @SourceSchema             = N'dbo',
    @SourceTable              = N't_log_message',
    @DeleteOrder              = 10,
    @DeleteMode               = 1,
    @TimestampExpr            = NULL,   -- ANCHOR: the cutoff lives on the process
    @JoinToAnchorPredicateSql = @Join,
    @AdditionalWhereSql       = NULL,
    @ArchiveSchema            = N'{SourceDb}',
    @ArchiveTable             = NULL,
    @RequireArchiveForDelete  = 1,
    @NaturalKeyLabel          = N'LOG_ROW',
    @ConfigChangeSetId        = @CsId OUTPUT;

DECLARE @IrId int = NULL;
EXEC arch.usp_Api_SaveIndexRequirement
    @IndexRequirementId = @IrId OUTPUT,
    @ProcessCode        = @Pc,
    @RequestedBy        = @By,
    @ChangeReason       = @Reason,
    @RequirementType    = N'SELECTION',
    @SourceSchema       = N'dbo',
    @SourceTable        = N't_log_message',
    @KeyColumnsCsv      = N'logged_on_utc',
    @IsMandatory        = 0,
    @Notes              = N'Satisfied by the existing clustered i_log_message, which leads on logged_on_utc - both the retention scan and the delete join can seek it.',
    @ConfigChangeSetId  = @CsId OUTPUT;
GO

-------------------------------------------------------------------------------
-- DROP ANY REQUIREMENT LEFT BEHIND BY 19_add_logmessage_key.sql
--
-- That script (now marked DO NOT USE - it adds a column to a vendor table) also
-- registers a JOIN requirement on kam_row_id. If it was ever run, the row stays
-- in arch.IndexRequirement after the column is gone, and usp_ValidateConfiguration
-- then reports "At least one required index column does not exist on the source
-- table" on EVERY run, for ever. A permanent WARN that cannot be actioned is
-- worse than no check: it trains whoever reads the validation to ignore warnings.
--
-- There is no API procedure to delete a requirement - usp_Api_SaveIndexRequirement
-- only inserts or updates - so this is a direct DELETE. It is confined to
-- kArchiveManagerAdmin, which is ours, and it removes only requirements whose key
-- columns genuinely do not exist on the source table, verified against the source
-- catalog rather than by name. sys.columns is not cross-database, hence dynamic SQL.
-------------------------------------------------------------------------------
DECLARE @Pc2 sysname = N'$(ProcessCode)';
DECLARE @Stale table (IndexRequirementId int PRIMARY KEY, KeyColumnsCsv nvarchar(1000), MissingCol sysname);

-- One row per requirement, not per missing column: a requirement listing two
-- absent columns would otherwise arrive twice and violate the table variable's
-- primary key. Both sides of the name comparison are forced to one collation -
-- sys.columns.name carries the SOURCE database's collation while the CSV carries
-- the admin database's, and on a case-sensitive instance that pairing raises
-- Msg 451 rather than simply not matching.
DECLARE @probe nvarchar(max) = N'
SELECT ir.IndexRequirementId, ir.KeyColumnsCsv, MIN(s.value)
FROM arch.IndexRequirement ir
JOIN arch.Process p ON p.ProcessId = ir.ProcessId
CROSS APPLY STRING_SPLIT(ir.KeyColumnsCsv, '','') s
WHERE p.ProcessCode = @Pc
  AND NOT EXISTS (SELECT 1 FROM ' + QUOTENAME(N'$(AdvDb)') + N'.sys.columns c
                  WHERE c.object_id = OBJECT_ID(N''$(AdvDb)'' + N''.'' + QUOTENAME(ir.SourceSchema) + N''.'' + QUOTENAME(ir.SourceTable))
                    AND c.name COLLATE DATABASE_DEFAULT = LTRIM(RTRIM(s.value)) COLLATE DATABASE_DEFAULT)
GROUP BY ir.IndexRequirementId, ir.KeyColumnsCsv;';

INSERT @Stale(IndexRequirementId, KeyColumnsCsv, MissingCol)
EXEC sys.sp_executesql @probe, N'@Pc sysname', @Pc = @Pc2;

IF EXISTS (SELECT 1 FROM @Stale)
BEGIN
    SELECT Section = 'STALE_INDEX_REQUIREMENT_REMOVED', s.IndexRequirementId,
           s.KeyColumnsCsv, MissingColumn = s.MissingCol,
           Reason = 'column absent from the source table - almost certainly left by 19_add_logmessage_key.sql'
    FROM @Stale s;

    DELETE ir FROM arch.IndexRequirement ir JOIN @Stale s ON s.IndexRequirementId = ir.IndexRequirementId;
END
ELSE
    PRINT 'INFO: no stale index requirements for this process.';
GO

PRINT '24_seed_logmessage_anchor: configuration applied.';
GO

-- Verification
SELECT p.ProcessCode, p.SelectionStrategy, p.Mode, p.RetentionDays, p.AuditLevel,
       p.DocKeyLabel, p.AnchorTable, p.MaxRowsPerTransaction, p.IsEnabled
FROM arch.Process p WHERE p.ProcessCode = N'$(ProcessCode)';

SELECT ks.KeyOrdinal, ks.KeyName, ks.SourceExpressionSql
FROM arch.ProcessKeySpec ks JOIN arch.Process p ON p.ProcessId = ks.ProcessId
WHERE p.ProcessCode = N'$(ProcessCode)' ORDER BY ks.KeyOrdinal;

SELECT os.DeleteOrder, os.SourceTable, os.JoinToAnchorPredicateSql
FROM arch.ObjectSpec os JOIN arch.Process p ON p.ProcessId = os.ProcessId
WHERE p.ProcessCode = N'$(ProcessCode)' ORDER BY os.DeleteOrder;
GO
