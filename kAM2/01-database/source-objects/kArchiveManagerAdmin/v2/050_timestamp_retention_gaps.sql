USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/* ============================================================================
   050 — T-20 retention-gap VISIBILITY (read-only, no behavior change)
   ----------------------------------------------------------------------------
   The TIMESTAMP runner selects candidates with `TimestampExpr < cutoff`. A row whose
   TimestampExpr is NULL (or whose raw value does not parse) evaluates to UNKNOWN and is
   therefore PERMANENTLY excluded from deletion — retention / GDPR erasure never reaches it,
   silently. arch.usp_Frontend_TimestampRetentionGaps surfaces, per enabled TIMESTAMP mapping,
   how many such unreachable rows exist on the candidate table.

   This is VISIBILITY ONLY. It does not change what gets deleted. Whether NULL/unparseable
   rows should become eligible for deletion (and after how long) is a business/compliance
   decision, deliberately left to an explicit opt-in rather than changing delete behavior here.
   ============================================================================ */
CREATE OR ALTER PROCEDURE arch.usp_Frontend_TimestampRetentionGaps
    @ProcessCode sysname = NULL,
    @SourceDb    sysname = NULL,
    @ArchiveDb   sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- read-only monitoring: a per-mapping count that errors (e.g. a raw CONVERT on bad data) is CAUGHT and
    -- reported, not fatal — so XACT_ABORT must be OFF or the catch would doom an INSERT...EXEC caller.
    SET XACT_ABORT OFF;

    DECLARE @out TABLE
    (
        ProcessCode sysname, SourceDb sysname, ArchiveDb sysname,
        CandidateSchema sysname NULL, CandidateTable sysname NULL,
        TimestampExpr nvarchar(4000) NULL,
        TotalRows bigint NULL,
        NullOrUnparseableRows bigint NULL,
        Note nvarchar(400) NULL
    );

    DECLARE @pc sysname, @sd sysname, @ad sysname, @pdid int,
            @cs sysname, @ct sysname, @texpr nvarchar(4000),
            @srcFq nvarchar(512), @sql nvarchar(max),
            @total bigint, @nullcnt bigint, @err nvarchar(400);

    DECLARE m CURSOR LOCAL FAST_FORWARD FOR
    SELECT e.ProcessCode, e.SourceDb, e.ArchiveDb, e.ProcessDatabaseId
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb   IS NULL OR e.SourceDb   = @SourceDb)
      AND (@ArchiveDb  IS NULL OR e.ArchiveDb  = @ArchiveDb);

    OPEN m;
    FETCH NEXT FROM m INTO @pc, @sd, @ad, @pdid;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @cs = NULL; SET @ct = NULL; SET @texpr = NULL;

        -- candidate object = first by DeleteOrder (same one the runner builds its keyset from)
        SELECT TOP (1)
            @cs = os.SourceSchema, @ct = os.SourceTable, @texpr = os.TimestampExpr
        FROM arch.v_ObjectSpecDatabaseEffective os
        WHERE os.ProcessDatabaseId = @pdid AND os.ObjectIsEnabled = 1
        ORDER BY os.DeleteOrder, os.ObjectSpecId;

        IF @cs IS NULL OR NULLIF(LTRIM(RTRIM(@texpr)), N'') IS NULL
        BEGIN
            INSERT @out VALUES (@pc, @sd, @ad, @cs, @ct, @texpr, NULL, NULL, N'SKIP: no enabled candidate object / TimestampExpr');
            FETCH NEXT FROM m INTO @pc, @sd, @ad, @pdid; CONTINUE;
        END;

        SET @srcFq = QUOTENAME(@sd) + N'.' + QUOTENAME(@cs) + N'.' + QUOTENAME(@ct);
        IF DB_ID(@sd) IS NULL OR OBJECT_ID(@srcFq, N'U') IS NULL
        BEGIN
            INSERT @out VALUES (@pc, @sd, @ad, @cs, @ct, @texpr, NULL, NULL, N'SKIP: source database/table not found');
            FETCH NEXT FROM m INTO @pc, @sd, @ad, @pdid; CONTINUE;
        END;

        SET @total = NULL; SET @nullcnt = NULL; SET @err = NULL;
        BEGIN TRY
            -- alias 't' matches the runner so a bare-column TimestampExpr resolves identically.
            SET @sql = N'SELECT @t = COUNT_BIG(*),
                                @n = COUNT_BIG(CASE WHEN (' + @texpr + N') IS NULL THEN 1 END)
                         FROM ' + @srcFq + N' t WITH (NOLOCK);';
            EXEC sys.sp_executesql @sql, N'@t bigint OUTPUT, @n bigint OUTPUT', @t = @total OUTPUT, @n = @nullcnt OUTPUT;
        END TRY
        BEGIN CATCH
            -- a raw (non-TRY) CONVERT in TimestampExpr that throws on bad data is itself a retention gap
            SET @err = N'EXPR ERROR (likely unparseable values present): ' + LEFT(ERROR_MESSAGE(), 320);
        END CATCH;

        INSERT @out VALUES (@pc, @sd, @ad, @cs, @ct, @texpr, @total, @nullcnt,
            COALESCE(@err,
                     CASE WHEN ISNULL(@nullcnt, 0) > 0
                          THEN N'WARN: rows with NULL timestamp are never reached by retention'
                          ELSE N'OK' END));

        FETCH NEXT FROM m INTO @pc, @sd, @ad, @pdid;
    END;
    CLOSE m; DEALLOCATE m;

    SELECT ProcessCode, SourceDb, ArchiveDb, CandidateSchema, CandidateTable,
           TimestampExpr, TotalRows, NullOrUnparseableRows, Note
    FROM @out
    ORDER BY CASE WHEN ISNULL(NullOrUnparseableRows, 0) > 0 OR Note LIKE N'EXPR ERROR%' THEN 0 ELSE 1 END,
             ProcessCode, SourceDb;
END
GO
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_TimestampRetentionGaps] TO [karch_viewer];
GO
PRINT '050_timestamp_retention_gaps deployed (arch.usp_Frontend_TimestampRetentionGaps + karch_viewer grant).';
GO
