USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- T-27: append-only audit of every real restore (and archive purge). Created here so it travels with 042.
IF OBJECT_ID(N'arch.RestoreAudit', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[RestoreAudit]
    (
        RestoreAuditId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_RestoreAudit PRIMARY KEY,
        OccurredAtUtc  datetime2(3) NOT NULL CONSTRAINT DF_RestoreAudit_OccurredAtUtc DEFAULT (SYSUTCDATETIME()),
        RequestedBy    nvarchar(256) NULL,
        ActorLogin     sysname NOT NULL CONSTRAINT DF_RestoreAudit_ActorLogin DEFAULT (SUSER_SNAME()),
        ProcessCode    sysname NOT NULL,
        SourceDb       sysname NOT NULL,
        ArchiveDb      sysname NOT NULL,
        PurgeArchive   bit NOT NULL,
        RowsRestored   bigint NOT NULL,
        ObjectsTouched int NOT NULL
    );
END;
GO
-- Tamper-resistance (mirrors 045_audit_immutability): the restore log is append-only.
DENY UPDATE, DELETE ON [arch].[RestoreAudit] TO public;
GO

/* ============================================================================
 * 042 — Restore / un-archive (C1)
 * ============================================================================
 * Copies archived rows back from the archive DB into the source tables for a
 * process, reversing an over-eager archive. Design:
 *   - Per enabled ObjectSpec, in REVERSE DeleteOrder (parents/masters before
 *     children) so FK order is satisfied on insert.
 *   - Idempotent: only rows missing from the source are inserted (NOT EXISTS on
 *     the source PRIMARY KEY). Re-running restores nothing extra.
 *   - IDENTITY-safe: SET IDENTITY_INSERT around tables that have an identity.
 *   - Atomic: the whole restore runs in one transaction.
 *   - @DryRun = 1 (default) only reports how many rows WOULD be restored.
 *   - Archive copies are LEFT intact by default (copy semantics). @PurgeArchive=1
 *     removes the restored rows from the archive afterwards (move semantics).
 *
 * NOTE: after restoring, rows older than the cutoff would be re-archived on the
 * next run — adjust retention/cutoff (or disable the mapping) if the restore is
 * meant to be permanent.
 * ============================================================================ */
CREATE OR ALTER PROCEDURE [arch].[usp_RestoreFromArchive]
    @ProcessCode   sysname,
    @SourceDb      sysname,
    @ArchiveDb     sysname,
    @DryRun        bit = 1,
    @MaxRows       int = NULL,          -- optional cap per table
    @PurgeArchive  bit = 0,
    @RequestedBy   nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF DB_ID(@SourceDb) IS NULL  THROW 50400, 'Source database does not exist.', 1;
    IF DB_ID(@ArchiveDb) IS NULL THROW 50401, 'Archive database does not exist.', 1;

    DECLARE @ProcessId int, @ProcessDatabaseId int;
    SELECT TOP (1) @ProcessId = e.ProcessId, @ProcessDatabaseId = e.ProcessDatabaseId
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.ProcessCode = @ProcessCode AND e.SourceDb = @SourceDb AND e.ArchiveDb = @ArchiveDb;

    IF @ProcessId IS NULL
        THROW 50402, 'Process/source/archive mapping not found.', 1;

    -- T-27: @PurgeArchive=1 DELETEs the archive copy = the only surviving copy of those rows (and, for
    -- BATCH/NONE mappings, the only per-row trace). Gate it server-side regardless of caller:
    --   (a) only a member of karch_approver (sysadmin bypasses) may purge;
    --   (b) refuse purge when the mapping's effective AuditLevel < ROW (no per-row trail exists).
    -- The Admin Console API additionally never forwards a client-supplied purge flag (it always sends 0).
    IF @PurgeArchive = 1
    BEGIN
        IF COALESCE(IS_MEMBER('karch_approver'), 0) = 0 AND IS_SRVROLEMEMBER('sysadmin') = 0
            THROW 50404, 'Purging the archive requires membership in karch_approver.', 1;

        DECLARE @PurgeAuditLevel nvarchar(20);
        SELECT TOP (1) @PurgeAuditLevel = COALESCE(NULLIF(LTRIM(RTRIM(e.AuditLevel)), N''), N'BATCH')
        FROM arch.v_ProcessDatabaseEffective e
        WHERE e.ProcessId = @ProcessId AND e.SourceDb = @SourceDb AND e.ArchiveDb = @ArchiveDb;

        IF @PurgeAuditLevel <> N'ROW'
            THROW 50405, 'Purging the archive is blocked for mappings with AuditLevel < ROW (the archive is the only per-row trace of the deleted rows).', 1;
    END;

    -- Enabled objects, parents first (reverse of delete order).
    DECLARE @Obj TABLE
    (
        Seq int IDENTITY(1,1) PRIMARY KEY,
        SourceSchema sysname, SourceTable sysname,
        ArchiveSchema sysname, ArchiveTable sysname
    );
    INSERT @Obj (SourceSchema, SourceTable, ArchiveSchema, ArchiveTable)
    SELECT
        os.SourceSchema, os.SourceTable,
        CONVERT(sysname, REPLACE(
            CASE WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo'
                 THEN N'{SourceDb}' ELSE LTRIM(RTRIM(os.ArchiveSchema)) END, N'{SourceDb}', @SourceDb)),
        COALESCE(os.ArchiveTable, os.SourceTable)
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessDatabaseId = @ProcessDatabaseId AND os.ObjectIsEnabled = 1
    ORDER BY os.DeleteOrder DESC, os.ObjectSpecId DESC;

    IF NOT EXISTS (SELECT 1 FROM @Obj)
        THROW 50403, 'Process has no enabled ObjectSpec to restore.', 1;

    DECLARE @Result TABLE
    (
        SourceObject nvarchar(400), ArchiveObject nvarchar(400),
        ArchiveRows bigint NULL, RestorableRows bigint NULL, RestoredRows bigint NULL, Note nvarchar(200) NULL
    );

    DECLARE @Seq int, @ss sysname, @st sysname, @as2 sysname, @at sysname,
            @srcFq nvarchar(512), @arcFq nvarchar(512),
            @cols nvarchar(max), @dummy nvarchar(max),
            @pkJoin nvarchar(max), @pkCols nvarchar(max), @hasId bit, @arcCount bigint, @restorable bigint, @n bigint,
            @sql nvarchar(max);

    DECLARE @started bit = 0;
    BEGIN TRY
        IF @DryRun = 0
        BEGIN
            BEGIN TRAN;
            SET @started = 1;
        END;

        DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Seq, SourceSchema, SourceTable, ArchiveSchema, ArchiveTable FROM @Obj ORDER BY Seq;
        OPEN c; FETCH NEXT FROM c INTO @Seq, @ss, @st, @as2, @at;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @srcFq = QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@ss) + N'.' + QUOTENAME(@st);
            SET @arcFq = QUOTENAME(@ArchiveDb) + N'.' + QUOTENAME(@as2) + N'.' + QUOTENAME(@at);
            SET @cols = NULL; SET @pkJoin = NULL; SET @pkCols = NULL; SET @hasId = 0; SET @arcCount = NULL; SET @restorable = NULL;

            IF OBJECT_ID(@arcFq, N'U') IS NULL OR OBJECT_ID(@srcFq, N'U') IS NULL
            BEGIN
                INSERT @Result VALUES (@srcFq, @arcFq, NULL, NULL, NULL, N'SKIP: source or archive table missing');
                FETCH NEXT FROM c INTO @Seq, @ss, @st, @as2, @at; CONTINUE;
            END;

            -- column list (non-computed) shared by source + archive. @ExcludeRowversion=1: a
            -- rowversion/timestamp column cannot be INSERTed explicitly on restore (it auto-generates),
            -- so it is omitted from both the INSERT target list and the SELECT from the archive.
            EXEC arch.usp_GetOutputColumns @SourceDb=@SourceDb, @SourceSchema=@ss, @SourceTable=@st,
                 @IncludeComputed=0, @ExcludeRowversion=1, @DeletedSelectList=@dummy OUTPUT, @TargetColumnList=@cols OUTPUT;

            -- source PK join (required for safe dedup)
            SET @sql = N'SELECT @j = STRING_AGG(CONVERT(nvarchar(max), N''s.'' + QUOTENAME(c.name) + N'' = arc.'' + QUOTENAME(c.name)), N'' AND '') WITHIN GROUP (ORDER BY ic.key_ordinal)
                         FROM ' + QUOTENAME(@SourceDb) + N'.sys.indexes i
                         JOIN ' + QUOTENAME(@SourceDb) + N'.sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                         JOIN ' + QUOTENAME(@SourceDb) + N'.sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                         WHERE i.is_primary_key = 1 AND i.object_id = OBJECT_ID(@fq);';
            EXEC sys.sp_executesql @sql, N'@fq nvarchar(512), @j nvarchar(max) OUTPUT', @fq=@srcFq, @j=@pkJoin OUTPUT;

            -- source PK column list (bare) for de-duplicating the archive side (see the INSERT below).
            SET @sql = N'SELECT @pc = STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(c.name)), N'', '') WITHIN GROUP (ORDER BY ic.key_ordinal)
                         FROM ' + QUOTENAME(@SourceDb) + N'.sys.indexes i
                         JOIN ' + QUOTENAME(@SourceDb) + N'.sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                         JOIN ' + QUOTENAME(@SourceDb) + N'.sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                         WHERE i.is_primary_key = 1 AND i.object_id = OBJECT_ID(@fq);';
            EXEC sys.sp_executesql @sql, N'@fq nvarchar(512), @pc nvarchar(max) OUTPUT', @fq=@srcFq, @pc=@pkCols OUTPUT;

            -- does the source table have an identity column?
            SET @sql = N'SELECT @hi = CASE WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@SourceDb) + N'.sys.columns WHERE object_id = OBJECT_ID(@fq) AND is_identity = 1) THEN 1 ELSE 0 END;';
            EXEC sys.sp_executesql @sql, N'@fq nvarchar(512), @hi bit OUTPUT', @fq=@srcFq, @hi=@hasId OUTPUT;

            IF @pkJoin IS NULL
            BEGIN
                INSERT @Result VALUES (@srcFq, @arcFq, NULL, NULL, NULL, N'SKIP: source table has no PRIMARY KEY (cannot dedup safely)');
                FETCH NEXT FROM c INTO @Seq, @ss, @st, @as2, @at; CONTINUE;
            END;

            -- counts
            -- @restorable counts DISTINCT primary keys missing from source (not raw archive rows) so the
            -- preview matches what the de-duplicated INSERT will actually restore when the archive holds
            -- duplicate keys (e.g. after repeated copy-only runs).
            SET @sql = N'SELECT @ac = COUNT_BIG(*) FROM ' + @arcFq + N';
                         SELECT @rc = COUNT_BIG(*) FROM (SELECT DISTINCT ' + @pkCols + N' FROM ' + @arcFq + N' arc WHERE NOT EXISTS (SELECT 1 FROM ' + @srcFq + N' s WHERE ' + @pkJoin + N')) _d;';
            EXEC sys.sp_executesql @sql, N'@ac bigint OUTPUT, @rc bigint OUTPUT', @ac=@arcCount OUTPUT, @rc=@restorable OUTPUT;

            IF @DryRun = 1
            BEGIN
                INSERT @Result VALUES (@srcFq, @arcFq, @arcCount, @restorable, NULL, N'DRYRUN');
            END
            ELSE
            BEGIN
                -- De-duplicate the archive side to ONE row per primary key (ROW_NUMBER PARTITION BY PK):
                -- the archive may legitimately hold duplicate keys (repeated copy-only runs / prior
                -- restore-then-rearchive cycles). Inserting them raw would raise a PK violation on the
                -- source and abort the whole restore. The NOT EXISTS still skips keys already in source.
                SET @sql =
                    CASE WHEN @hasId = 1 THEN N'SET IDENTITY_INSERT ' + @srcFq + N' ON;' + CHAR(10) ELSE N'' END +
                    N'INSERT INTO ' + @srcFq + N' (' + @cols + N')' + CHAR(10) +
                    N'SELECT ' + CASE WHEN @MaxRows IS NOT NULL THEN N'TOP (' + CONVERT(nvarchar(20), @MaxRows) + N') ' ELSE N'' END +
                    @cols + N' FROM (' + CHAR(10) +
                    N'    SELECT ' + @cols + N', ROW_NUMBER() OVER (PARTITION BY ' + @pkCols + N' ORDER BY (SELECT NULL)) AS _rn' + CHAR(10) +
                    N'    FROM ' + @arcFq + N' arc' + CHAR(10) +
                    N'    WHERE NOT EXISTS (SELECT 1 FROM ' + @srcFq + N' s WHERE ' + @pkJoin + N')' + CHAR(10) +
                    N') _d WHERE _rn = 1;' + CHAR(10) +
                    CASE WHEN @hasId = 1 THEN N'SET IDENTITY_INSERT ' + @srcFq + N' OFF;' ELSE N'' END;
                EXEC (@sql);
                SET @n = @@ROWCOUNT;

                IF @PurgeArchive = 1 AND @n > 0
                BEGIN
                    SET @sql = N'DELETE arc FROM ' + @arcFq + N' arc WHERE EXISTS (SELECT 1 FROM ' + @srcFq + N' s WHERE ' + @pkJoin + N');';
                    EXEC (@sql);
                END;

                INSERT @Result VALUES (@srcFq, @arcFq, @arcCount, @restorable, @n, CASE WHEN @PurgeArchive=1 THEN N'RESTORED + purged archive' ELSE N'RESTORED (archive kept)' END);
            END;

            FETCH NEXT FROM c INTO @Seq, @ss, @st, @as2, @at;
        END;
        CLOSE c; DEALLOCATE c;

        -- T-27: append-only log of the real restore (atomic with it). Records the authenticated actor,
        -- the purge flag, and the totals so an irreversible restore/purge is reconstructable afterwards.
        IF @DryRun = 0
            INSERT [arch].[RestoreAudit](RequestedBy, ProcessCode, SourceDb, ArchiveDb, PurgeArchive, RowsRestored, ObjectsTouched)
            SELECT @RequestedBy, @ProcessCode, @SourceDb, @ArchiveDb, @PurgeArchive,
                   ISNULL(SUM(RestoredRows), 0), COUNT(CASE WHEN RestoredRows IS NOT NULL THEN 1 END)
            FROM @Result;

        IF @started = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF @started = 1 AND XACT_STATE() <> 0 ROLLBACK;
        DECLARE @err nvarchar(4000) = ERROR_MESSAGE();
        RAISERROR(N'arch.usp_RestoreFromArchive failed: %s', 16, 1, @err);
        RETURN;
    END CATCH;

    SELECT
        ProcessCode = @ProcessCode, SourceDb = @SourceDb, ArchiveDb = @ArchiveDb,
        Mode = CASE WHEN @DryRun = 1 THEN N'DRYRUN' ELSE N'RESTORE' END,
        RequestedBy = @RequestedBy,
        SourceObject, ArchiveObject, ArchiveRows, RestorableRows, RestoredRows, Note
    FROM @Result
    ORDER BY SourceObject;
END
GO

-- T-02: restore writes back to the PRODUCTION source DB and (with @PurgeArchive=1) deletes the
-- archive copy. Grant EXECUTE only to karch_advanced_admin (the highest config role the app pool
-- holds) so the endpoint works WITHOUT relying on the over-privileged orphan login [IIS APPPOOL\Console].
-- Deliberately NOT granted to karch_operator / karch_config_admin.
-- Follow-up (T-06/T-27): gate restore + @PurgeArchive behind a distinct approver/runtime credential.
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_RestoreFromArchive] TO [karch_advanced_admin];
GO

PRINT '042_usp_RestoreFromArchive deployed (+ karch_advanced_admin grant).';
GO
