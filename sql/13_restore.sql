-- ============================================================================
-- 13 - RESTORE FROM ARCHIVE (undo a run)
-- ============================================================================
-- Puts archived rows back into the source database. This is the escape hatch if
-- 12_verify.sql shows something unexpected, or if a document turns out to be
-- needed again.
--
-- SAFETY: @Apply defaults to 0 = preview. Set it to 1 to actually write.
--
-- KNOWN CONSTRAINTS - read before relying on this
--   1. It is DBA-only by design. arch.usp_RestoreFromArchive is granted to
--      karch_advanced_admin, not to the unattended runner.
--   2. rowversion / timestamp columns are excluded on the way back (they cannot
--      be inserted); that fix is in the audit-hardened build this package targets.
--   3. The archive side is de-duplicated on restore, so restoring twice does not
--      double the rows.
--   4. THE INSERT TRIGGER FIRES. dbo.tr_order_master_insert runs on every
--      re-inserted t_order row and executes
--          client_code = ISNULL(client_code, wh_id)
--      which must satisfy fk_order_client_code -> t_client(wh_id, client_code).
--      If the archived document belongs to a warehouse that has no matching
--      t_client row, the restore fails with FK 547. Check section A below FIRST.
--   5. Order of insertion matters: the header must exist before its children,
--      because the children's foreign keys point at it. The procedure handles
--      that ordering itself (reverse of the delete order).
--   6. !! IT CANNOT BE FILTERED TO INDIVIDUAL DOCUMENTS !!
--      The shipped signature is
--        (@ProcessCode, @SourceDb, @ArchiveDb, @DryRun, @MaxRows, @PurgeArchive,
--         @RequestedBy)
--      - there is NO document-key parameter. A restore therefore brings back
--      EVERYTHING archived for that process/source pair, bounded only by
--      @MaxRows. If you need a single document back, either restore into a
--      staging copy of the database and copy that one document across, or write
--      a targeted INSERT from the archive table yourself.
--      DocKeyLike below is used ONLY by the preview/reporting sections of this
--      script, never by the restore call itself.
-- ============================================================================
:setvar AdminDb "kArchiveManagerAdmin"
:setvar SourceDb "AAD"
:setvar ArchiveDb "kArchiveManagerBackups"
:setvar ProcessCode "AAD_ORDER_ARCH"
-- Reporting filter for sections A, B and D of this script only (see note 6).
:setvar DocKeyLike "KAMTEST-%"
-- Upper bound on rows written back by the restore call.
:setvar MaxRows "10000"
:setvar Apply "0"

:on error exit

USE [$(AdminDb)];
GO
SET NOCOUNT ON;
GO

PRINT 'Mode: ' + CASE WHEN $(Apply) = 1 THEN 'APPLY - rows will be written back' ELSE 'PREVIEW ONLY' END;
PRINT 'Process: $(ProcessCode)   DocKey filter: $(DocKeyLike)';
GO

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- A) Restore feasibility: does every archived header have a t_client row? ---';
-------------------------------------------------------------------------------
-- The vendor insert trigger will set client_code = wh_id when it is NULL, so the
-- pair (wh_id, client_code) must exist in t_client or the insert fails with 547.
DECLARE @chk nvarchar(max) = N'
SELECT
    Section = ''A_FEASIBILITY'',
    a.wh_id,
    Headers = COUNT_BIG(*),
    ClientRowExists = CASE WHEN EXISTS
        (SELECT 1 FROM ' + QUOTENAME(N'$(SourceDb)') + N'.dbo.t_client c
          WHERE c.wh_id = a.wh_id) THEN ''yes'' ELSE ''NO'' END,
    Verdict = CASE WHEN EXISTS
        (SELECT 1 FROM ' + QUOTENAME(N'$(SourceDb)') + N'.dbo.t_client c
          WHERE c.wh_id = a.wh_id)
        THEN ''OK - restore can satisfy fk_order_client_code''
        ELSE ''STOP - no t_client row for this warehouse; the insert trigger will fail with FK 547'' END
FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(SourceDb)') + N'.t_order a
WHERE a.order_number LIKE N''$(DocKeyLike)''
GROUP BY a.wh_id;';
EXEC sys.sp_executesql @chk;
GO

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- B) What is available in the archive ---';
-------------------------------------------------------------------------------
DECLARE @avail nvarchar(max) = N'
SELECT Section = ''B_AVAILABLE'', TableName = ''t_order'',                Rows_ = COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(SourceDb)') + N'.t_order                WHERE order_number LIKE N''$(DocKeyLike)''
UNION ALL SELECT ''B_AVAILABLE'', ''t_order_detail'',         COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(SourceDb)') + N'.t_order_detail         WHERE order_number LIKE N''$(DocKeyLike)''
UNION ALL SELECT ''B_AVAILABLE'', ''t_order_comment'',        COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(SourceDb)') + N'.t_order_comment        WHERE order_number LIKE N''$(DocKeyLike)''
UNION ALL SELECT ''B_AVAILABLE'', ''t_order_detail_comment'', COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(SourceDb)') + N'.t_order_detail_comment WHERE order_number LIKE N''$(DocKeyLike)''
UNION ALL SELECT ''B_AVAILABLE'', ''t_pack'',                 COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(SourceDb)') + N'.t_pack                 WHERE order_number LIKE N''$(DocKeyLike)''
UNION ALL SELECT ''B_AVAILABLE'', ''t_pick_detail'',          COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(SourceDb)') + N'.t_pick_detail          WHERE order_number LIKE N''$(DocKeyLike)''
UNION ALL SELECT ''B_AVAILABLE'', ''t_tran_log'',             COUNT_BIG(*) FROM ' + QUOTENAME(N'$(ArchiveDb)') + N'.' + QUOTENAME(N'$(SourceDb)') + N'.t_tran_log             WHERE outbound_order_number LIKE N''$(DocKeyLike)''
ORDER BY TableName;';
EXEC sys.sp_executesql @avail;
GO

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- C) Restore ---';
-------------------------------------------------------------------------------
-- The shipped procedure handles the column mapping, the insertion order, the
-- rowversion exclusion and the archive-side dedup.
-- @PurgeArchive = 0 keeps the archive copy after restoring, so the operation is
-- repeatable and the archive stays the system of record. Set it to 1 only when
-- you deliberately want the rows to exist in exactly one place again.
IF $(Apply) = 1
BEGIN
    PRINT 'Restoring (dry-run first, then for real) ...';

    -- The procedure has its own DryRun mode; use it as a last look before writing.
    EXEC arch.usp_RestoreFromArchive
        @ProcessCode  = N'$(ProcessCode)',
        @SourceDb     = N'$(SourceDb)',
        @ArchiveDb    = N'$(ArchiveDb)',
        @DryRun       = 1,
        @MaxRows      = $(MaxRows),
        @PurgeArchive = 0,
        @RequestedBy  = N'kam-deploy';

    EXEC arch.usp_RestoreFromArchive
        @ProcessCode  = N'$(ProcessCode)',
        @SourceDb     = N'$(SourceDb)',
        @ArchiveDb    = N'$(ArchiveDb)',
        @DryRun       = 0,
        @MaxRows      = $(MaxRows),
        @PurgeArchive = 0,
        @RequestedBy  = N'kam-deploy';

    PRINT 'Restore completed.';
END
ELSE
BEGIN
    PRINT 'PREVIEW - nothing restored. Set Apply=1 to write the rows back.';
    PRINT 'Running the procedure''s own DryRun so you can see what it WOULD do:';

    EXEC arch.usp_RestoreFromArchive
        @ProcessCode  = N'$(ProcessCode)',
        @SourceDb     = N'$(SourceDb)',
        @ArchiveDb    = N'$(ArchiveDb)',
        @DryRun       = 1,
        @MaxRows      = $(MaxRows),
        @PurgeArchive = 0,
        @RequestedBy  = N'kam-deploy';

    SELECT
        Section   = 'C_SIGNATURE',
        Parameter = p.name,
        DataType  = TYPE_NAME(p.user_type_id),
        Ordinal   = p.parameter_id
    FROM sys.parameters p
    WHERE p.object_id = OBJECT_ID(N'arch.usp_RestoreFromArchive')
    ORDER BY p.parameter_id;
END;
GO

-------------------------------------------------------------------------------
PRINT '';
PRINT '--- D) Post-restore state ---';
-------------------------------------------------------------------------------
DECLARE @post nvarchar(max) = N'
SELECT Section = ''D_SOURCE_NOW'', TableName = ''t_order'', Rows_ = COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(SourceDb)') + N'.dbo.t_order WHERE order_number LIKE N''$(DocKeyLike)''
UNION ALL SELECT ''D_SOURCE_NOW'', ''t_order_detail'', COUNT_BIG(*)
FROM ' + QUOTENAME(N'$(SourceDb)') + N'.dbo.t_order_detail WHERE order_number LIKE N''$(DocKeyLike)'';';
EXEC sys.sp_executesql @post;
GO

PRINT '';
PRINT '13_restore: done. Re-run 12_verify.sql to re-check the reconciliation.';
GO
