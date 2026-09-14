/* ============================================================================
   043 — Remove over-privileged orphan principals (audit task T-01)
   ============================================================================
   PROBLEM (verified live on RADIM-STACHAL\RSTSQL2022, 2026-06-03):
     - [IIS APPPOOL\Console]        : member of db_datareader + db_datawriter AND holds a
                                       DATABASE-WIDE GRANT EXECUTE (object = NULL) => can run the
                                       irreversible archive+DELETE runner and rewrite all config/audit.
     - [IIS APPPOOL\DefaultAppPool] : CONNECT + SELECT/EXECUTE on sysrowsets (catalog reconnaissance).
   Neither belongs to the least-privilege design; the intended app pool is
   [IIS APPPOOL\kAM Admin Console] (member of karch_viewer/operator/config_admin/advanced_admin).

   ⚠️  DEPENDENCY — DO NOT RUN BEFORE TASK T-02.
     If the production IIS site actually runs under [IIS APPPOOL\Console], dropping it will LOCK OUT
     the Admin Console. First (T-02): confirm the site runs under [IIS APPPOOL\kAM Admin Console] and
     that GRANT EXECUTE on arch.usp_Api_RequestRunStop / arch.usp_RestoreFromArchive has been added to
     the appropriate karch role. THEN run this.

   This script is IDEMPOTENT and BLOCKED by default. Set @IConfirm = 'YES' to apply.
   It is read-only (prints a report) unless confirmed.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET NOCOUNT ON;
GO

DECLARE @IConfirm varchar(10) = 'NO';   -- <<< set to 'YES' to actually revoke/drop (see T-02 dependency)

/* ---- Pre-flight report (always runs) ------------------------------------ */
PRINT '--- Current grants/roles for the orphan principals ---';
SELECT pr.name AS principal, perm.permission_name, perm.state_desc, perm.class_desc,
       object_name = OBJECT_NAME(perm.major_id)
FROM sys.database_permissions perm
JOIN sys.database_principals pr ON pr.principal_id = perm.grantee_principal_id
WHERE pr.name IN (N'IIS APPPOOL\Console', N'IIS APPPOOL\DefaultAppPool')
ORDER BY pr.name, perm.permission_name;

SELECT rp.name AS role, mp.name AS member
FROM sys.database_role_members drm
JOIN sys.database_principals rp ON rp.principal_id = drm.role_principal_id
JOIN sys.database_principals mp ON mp.principal_id = drm.member_principal_id
WHERE mp.name IN (N'IIS APPPOOL\Console', N'IIS APPPOOL\DefaultAppPool')
ORDER BY rp.name, mp.name;

IF @IConfirm <> 'YES'
BEGIN
    RAISERROR('BLOCKED (T-01): review the report above, satisfy the T-02 dependency, then set @IConfirm=''YES'' to apply the revoke/drop. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---- Apply (only when confirmed) ---------------------------------------- */

-- [IIS APPPOOL\Console]: drop the orphan user. NOTE: REVOKE/ALTER ROLE DROP MEMBER on a Windows
-- principal whose OS account no longer resolves throw Msg 15404 (verified live 2026-06-08). DROP USER
-- works by principal_id (no SID resolution) and CASCADES the role memberships + permissions, so just
-- drop it; the REVOKE/role-drop are only attempted best-effort for the resolvable case.
IF DATABASE_PRINCIPAL_ID(N'IIS APPPOOL\Console') IS NOT NULL
BEGIN
    BEGIN TRY REVOKE EXECUTE FROM [IIS APPPOOL\Console]; END TRY BEGIN CATCH END CATCH
    BEGIN TRY IF IS_ROLEMEMBER(N'db_datawriter', N'IIS APPPOOL\Console') = 1 ALTER ROLE [db_datawriter] DROP MEMBER [IIS APPPOOL\Console]; END TRY BEGIN CATCH END CATCH
    BEGIN TRY IF IS_ROLEMEMBER(N'db_datareader', N'IIS APPPOOL\Console') = 1 ALTER ROLE [db_datareader] DROP MEMBER [IIS APPPOOL\Console]; END TRY BEGIN CATCH END CATCH
    DROP USER [IIS APPPOOL\Console];
    PRINT 'Removed [IIS APPPOOL\Console].';
END
ELSE PRINT '[IIS APPPOOL\Console] not present — nothing to do.';

-- [IIS APPPOOL\DefaultAppPool]: catalog-recon orphan, drop entirely.
IF DATABASE_PRINCIPAL_ID(N'IIS APPPOOL\DefaultAppPool') IS NOT NULL
BEGIN
    DROP USER [IIS APPPOOL\DefaultAppPool];
    PRINT 'Removed [IIS APPPOOL\DefaultAppPool].';
END
ELSE PRINT '[IIS APPPOOL\DefaultAppPool] not present — nothing to do.';
GO

/* ---- Post-verification: no non-dbo principal may hold DB-wide EXECUTE or db_datawriter ---- */
DECLARE @bad int =
(
    SELECT COUNT(*)
    FROM sys.database_permissions perm
    JOIN sys.database_principals pr ON pr.principal_id = perm.grantee_principal_id
    WHERE perm.permission_name = 'EXECUTE' AND perm.class_desc = 'DATABASE'
      AND perm.state_desc = 'GRANT' AND pr.name <> 'dbo'
)
+
(
    SELECT COUNT(*)
    FROM sys.database_role_members drm
    JOIN sys.database_principals rp ON rp.principal_id = drm.role_principal_id
    JOIN sys.database_principals mp ON mp.principal_id = drm.member_principal_id
    WHERE rp.name = 'db_datawriter' AND mp.name <> 'dbo'
);

IF @bad > 0
    RAISERROR('VERIFY FAILED (T-01): a non-dbo principal still holds DB-wide EXECUTE or db_datawriter. Investigate.', 16, 1);
ELSE
    PRINT 'VERIFY OK (T-01): no non-dbo principal holds DB-wide EXECUTE or db_datawriter.';
GO

SET NOEXEC OFF;   -- clear the guard so a reused connection is not left blocked
GO
