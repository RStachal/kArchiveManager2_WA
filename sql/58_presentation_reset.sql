-- ============================================================================
-- 58 - RESET TO A PRESENTATION START
-- ============================================================================
-- Brings kArchiveManagerAdmin and the archive database back to the state you
-- want an audience to see first: the configuration intact, and nothing else.
-- Every run, every batch, every audit row and every archived row is gone, so the
-- demo fills an empty archive from a full source and the dashboard numbers all
-- start at zero.
--
-- WHAT IT KEEPS - the configuration, and only that
--   arch.Process                 the six document sets
--   arch.ProcessDatabase         their source/archive mappings
--   arch.ProcessKeySpec          their keys
--   arch.ObjectSpec              their tables, delete order and joins
--   arch.ObjectSpecDatabaseOverride
--   arch.RunProfile              JOB_DEFAULT and ALL_DRYRUN
--   arch.RetentionPolicy         the retention floor
--   arch.SelectionStrategy       the strategy catalogue (product data)
--   arch.IndexRequirement        what the configuration needs from the DBA
--   arch.ConsoleOperator         who can log in to the console
--   arch.LegalHold               holds are a deliberate act; see the switch below
--
-- WHAT IT REMOVES - the records
--   arch.Run / RunItem / RunItemObject      run history
--   arch.WorkBatch / WorkBatchKey           prepared candidates
--   arch.RunDocAudit                        the per-document trail
--   arch.ArchiveProvisionLog                archive table provisioning log
--   arch.RestoreAudit                       restore history
--   arch.RunnerPrivilegeInventory           privilege-gate snapshots (regenerated)
--   arch.ConfigChangeSet / Item / Field     the configuration change history
--   perf.TestBaseline                       throughput-test baseline, if present
--   every row in every <ArchiveDb> table    the tables STAY, emptied
--
-- TWO THINGS WORTH A SECOND THOUGHT BEFORE YOU RUN IT
--
-- 1. arch.RunDocAudit carries DENY UPDATE, DELETE to public - script 045, audit
--    immutability. That DENY is real and it is there for a reason. A sysadmin
--    bypasses permission checks entirely, so this script CAN clear it, and on a
--    presentation instance that is the right call. On anything carrying real
--    archived documents it is not: the per-document trail is the evidence that a
--    given document was archived rather than lost. @ClearDocAudit is separate
--    from @Apply for exactly that reason.
--
-- 2. The configuration CHANGE HISTORY is also a record, not configuration, so it
--    goes. That is deliberate - a change log full of test runs invites questions
--    about your testing rather than about the product, and an empty history makes
--    a live configuration change in the demo actually visible. Set
--    @ClearChangeHistory = 0 to keep it.
--
-- THIS SCRIPT DOES NOT TOUCH THE WMS DATABASES. Restoring AAD/ADV to their
-- starting state is a separate step, done with RESTORE DATABASE from a backup
-- taken before any archiving ran. Remember what that costs: a restore replaces
-- every database principal, so the runner and the console both lose their users
-- and NOTHING warns you - see ADMIN-CONSOLE.md, "Two traps". Re-run 053 and 051
-- afterwards, in that order, and check the runner gate returns 0.
--
-- Idempotent. Safe to run twice. Requires sysadmin.
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ArchiveDb          sysname = N'kArchiveManagerBackups';
DECLARE @Apply              bit = 0;   -- 1 = do it
DECLARE @ClearDocAudit      bit = 1;   -- 0 = keep arch.RunDocAudit (see note 1)
DECLARE @ClearChangeHistory bit = 1;   -- 0 = keep arch.ConfigChangeSet/Item/Field
DECLARE @ClearLegalHolds    bit = 0;   -- 0 = keep holds; they are a deliberate act

IF DB_ID(@ArchiveDb) IS NULL
BEGIN
    RAISERROR('Archive database %s not found.', 16, 1, @ArchiveDb);
    RETURN;
END;

------------------------------------------------------------------------------
-- A) Refuse to run while anything is in flight. Clearing WorkBatchKey under a
--    live run would leave the runner deleting from a candidate set that no
--    longer exists.
------------------------------------------------------------------------------
DECLARE @live int = (SELECT COUNT(*) FROM arch.Run WHERE Status = N'RUNNING')
                  + (SELECT COUNT(*) FROM arch.WorkBatch WHERE Status IN (N'Running'));
IF @live > 0
BEGIN
    SELECT Section = 'A_IN_FLIGHT', RunId, Status, StartedAt FROM arch.Run WHERE Status = N'RUNNING';
    RAISERROR('Something is still running. Stop the RUN job, let arch.usp_RecoverStaleRuns settle it, then re-run. Nothing was changed.', 16, 1);
    RETURN;
END;

------------------------------------------------------------------------------
-- B) Before
------------------------------------------------------------------------------
SELECT Section = 'B_ADMIN_BEFORE', TableName = t.name, Rows = SUM(p.rows),
       Keep = CASE WHEN t.name IN (N'Process', N'ProcessDatabase', N'ProcessKeySpec', N'ObjectSpec',
                                   N'ObjectSpecDatabaseOverride', N'RunProfile', N'RetentionPolicy',
                                   N'SelectionStrategy', N'IndexRequirement', N'ConsoleOperator', N'LegalHold')
                   THEN 'configuration - KEEP' ELSE 'record - clear' END
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE SCHEMA_NAME(t.schema_id) = 'arch'
GROUP BY t.name
HAVING SUM(p.rows) > 0
ORDER BY Keep DESC, t.name;

DECLARE @archRows bigint, @archTables int, @sql nvarchar(max);
SET @sql = N'SELECT @r = SUM(p.rows), @t = COUNT(DISTINCT t.object_id)
             FROM ' + QUOTENAME(@ArchiveDb) + N'.sys.tables t
             JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.partitions p
               ON p.object_id = t.object_id AND p.index_id IN (0,1);';
EXEC sys.sp_executesql @sql, N'@r bigint OUTPUT, @t int OUTPUT', @r = @archRows OUTPUT, @t = @archTables OUTPUT;
SELECT Section = 'B_ARCHIVE_BEFORE', ArchiveDb = @ArchiveDb, Tables = @archTables, Rows = @archRows;

IF @Apply = 0
BEGIN
    PRINT '';
    PRINT '58: PLAN ONLY. Set @Apply = 1 to clear everything marked "record - clear"';
    PRINT '    and empty every table in ' + @ArchiveDb + ' (the tables themselves stay).';
    RETURN;
END;

------------------------------------------------------------------------------
-- C) Admin records. Child-first, so no foreign key complains.
------------------------------------------------------------------------------
BEGIN TRAN;

DELETE FROM arch.WorkBatchKey;             PRINT '  WorkBatchKey            cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';
DELETE FROM arch.WorkBatch;                PRINT '  WorkBatch               cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';
DELETE FROM arch.RunItemObject;            PRINT '  RunItemObject           cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';

IF @ClearDocAudit = 1
BEGIN
    -- DENY UPDATE/DELETE to public (045). A sysadmin bypasses permission checks,
    -- so this succeeds; it is left as its own switch because it should be a
    -- decision, not a side effect.
    DELETE FROM arch.RunDocAudit;          PRINT '  RunDocAudit             cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')  [audit-immutable by design]';
END
ELSE
    PRINT '  RunDocAudit             KEPT (@ClearDocAudit = 0)';

DELETE FROM arch.RunItem;                  PRINT '  RunItem                 cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';
DELETE FROM arch.Run;                      PRINT '  Run                     cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';
DELETE FROM arch.ArchiveProvisionLog;      PRINT '  ArchiveProvisionLog     cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';
DELETE FROM arch.RestoreAudit;             PRINT '  RestoreAudit            cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';
DELETE FROM arch.RunnerPrivilegeInventory; PRINT '  RunnerPrivilegeInventory cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';

IF @ClearLegalHolds = 1
BEGIN
    DELETE FROM arch.LegalHold;            PRINT '  LegalHold               cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';
END;

IF @ClearChangeHistory = 1
BEGIN
    DELETE FROM arch.ConfigChangeField;    PRINT '  ConfigChangeField       cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';
    DELETE FROM arch.ConfigChangeItem;     PRINT '  ConfigChangeItem        cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';
    DELETE FROM arch.ConfigChangeSet;      PRINT '  ConfigChangeSet         cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';
END
ELSE
    PRINT '  ConfigChange*           KEPT (@ClearChangeHistory = 0)';

IF OBJECT_ID(N'perf.TestBaseline', N'U') IS NOT NULL
BEGIN
    DELETE FROM perf.TestBaseline;         PRINT '  perf.TestBaseline       cleared (' + CONVERT(varchar(12), @@ROWCOUNT) + ')';
END;

COMMIT;

------------------------------------------------------------------------------
-- D) Empty the archive tables, keeping the tables themselves.
--
--    TRUNCATE where it is allowed and DELETE where it is not, decided per table
--    rather than assumed: TRUNCATE is minimally logged and near-instant, which
--    matters because the archive is in FULL recovery and a DELETE of a few
--    hundred thousand rows grows the log for no reason. It is refused on a table
--    that is referenced by a foreign key, so fall back rather than fail.
------------------------------------------------------------------------------
DECLARE @s sysname, @t sysname, @n bigint, @stmt nvarchar(max), @how varchar(10);
DECLARE @tables TABLE (SchemaName sysname, TableName sysname, Rows bigint);

SET @sql = N'SELECT s.name, t.name, SUM(p.rows)
             FROM ' + QUOTENAME(@ArchiveDb) + N'.sys.tables t
             JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.schemas s ON s.schema_id = t.schema_id
             JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
             GROUP BY s.name, t.name;';
INSERT @tables EXEC sys.sp_executesql @sql;

DECLARE cT CURSOR LOCAL FAST_FORWARD FOR SELECT SchemaName, TableName, Rows FROM @tables ORDER BY SchemaName, TableName;
OPEN cT; FETCH NEXT FROM cT INTO @s, @t, @n;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @how = 'TRUNCATE';
    BEGIN TRY
        SET @stmt = N'TRUNCATE TABLE ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@s) + N'.' + QUOTENAME(@t) + N';';
        EXEC sys.sp_executesql @stmt;
    END TRY
    BEGIN CATCH
        SET @how = 'DELETE';
        SET @stmt = N'DELETE FROM ' + QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@s) + N'.' + QUOTENAME(@t) + N';';
        EXEC sys.sp_executesql @stmt;
    END CATCH;
    IF @n > 0
        PRINT '  ' + @s + '.' + @t + ' emptied by ' + @how + ' (' + CONVERT(varchar(12), @n) + ' rows)';
    FETCH NEXT FROM cT INTO @s, @t, @n;
END;
CLOSE cT; DEALLOCATE cT;

------------------------------------------------------------------------------
-- E) After. The configuration must be untouched and everything else at zero.
------------------------------------------------------------------------------
SELECT Section = 'E_CONFIG_INTACT', Processes = (SELECT COUNT(*) FROM arch.Process),
       Enabled      = (SELECT COUNT(*) FROM arch.Process WHERE IsEnabled = 1),
       ObjectSpecs  = (SELECT COUNT(*) FROM arch.ObjectSpec),
       KeySpecs     = (SELECT COUNT(*) FROM arch.ProcessKeySpec),
       RunProfiles  = (SELECT COUNT(*) FROM arch.RunProfile),
       IndexReqs    = (SELECT COUNT(*) FROM arch.IndexRequirement),
       Operators    = (SELECT COUNT(*) FROM arch.ConsoleOperator);

SELECT Section = 'E_RECORDS_CLEARED', Runs = (SELECT COUNT(*) FROM arch.Run),
       WorkBatches = (SELECT COUNT(*) FROM arch.WorkBatch),
       WorkBatchKeys = (SELECT COUNT(*) FROM arch.WorkBatchKey),
       DocAudit = (SELECT COUNT(*) FROM arch.RunDocAudit),
       ChangeSets = (SELECT COUNT(*) FROM arch.ConfigChangeSet);

SET @sql = N'SELECT @r = ISNULL(SUM(p.rows),0), @t = COUNT(DISTINCT t.object_id)
             FROM ' + QUOTENAME(@ArchiveDb) + N'.sys.tables t
             JOIN ' + QUOTENAME(@ArchiveDb) + N'.sys.partitions p
               ON p.object_id = t.object_id AND p.index_id IN (0,1);';
EXEC sys.sp_executesql @sql, N'@r bigint OUTPUT, @t int OUTPUT', @r = @archRows OUTPUT, @t = @archTables OUTPUT;
SELECT Section = 'E_ARCHIVE_AFTER', Tables = @archTables, Rows = @archRows,
       Verdict = CASE WHEN @archRows = 0 THEN 'empty, tables intact' ELSE '*** still holds rows ***' END;

PRINT '';
PRINT 'Next, in this order:';
PRINT '  1. EXEC arch.usp_ValidateConfiguration;       -- must return 0';
PRINT '  2. EXEC arch.usp_VerifyRunnerPrivileges;      -- must return 0';
PRINT '  3. check the console answers on /api/readiness and /api/dashboard/process-summary';
PRINT '  4. leave PREP and RUN CONFIGURED DISABLED - a scheduled fire mid-demo is a real hazard,';
PRINT '     and sp_start_job runs them on demand anyway';
PRINT '  5. back the four databases up under whatever suffix marks this starting point';
