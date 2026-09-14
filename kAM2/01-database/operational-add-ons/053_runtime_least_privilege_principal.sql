/* ============================================================================
   053 — T-33 (deploy part): create the least-privilege RUNTIME principal + cross-DB grants
   ----------------------------------------------------------------------------
   Companion to kArchiveManagerAdmin/v2/055 (role [karch_runtime] + verify/inventory procs, in the
   clean bundle). This script creates the customer's dedicated runner login and grants it the MINIMUM
   it needs to run the archive runner unattended:

     • Admin DB  : member of [karch_runtime] => EXECUTE on the runner proc chain only. The runner's
                   writes to the Admin control tables travel through ownership chaining, so NO direct
                   table DML is granted here.
     • Source DB : SELECT + DELETE on ONLY the mapped source tables (the cross-DB DELETE is dynamic
                   SQL, so these must be explicit). No DDL, no other tables, no db_owner.
     • Archive DB: INSERT + SELECT + ALTER on the archive schema(s) + CREATE TABLE (DELETE...OUTPUT
                   INTO target + schema-drift widen). NO DELETE/UPDATE => the unattended runner can
                   never purge or tamper with the archive (purge stays a karch_approver/DBA action).

   It pre-provisions the archive tables (as the DBA running it), captures the grants into
   arch.RunnerPrivilegeInventory, and runs arch.usp_VerifyRunnerPrivileges AS the new login to prove
   the footprint is correct.

   PARAMETERIZED + IDEMPOTENT. Edit the CHANGE-ME block, run in classic SSMS (NO SQLCMD mode) as
   sysadmin, against the instance hosting the Admin/source/archive DBs. One logic batch (the CHANGE-ME
   values are declared exactly once). Re-run after mapping new processes/tables — and ESPECIALLY after
   mapping a process whose archive schema is new (a non-dbo runner cannot CREATE SCHEMA at run time;
   this script pre-creates the schemas as the DBA).

   NOTE on the SQL Agent job (separate step): a T-SQL Agent step ignores @proxy_name and runs as the
   JOB OWNER (or, if the owner is sysadmin, as the Agent service account). Re-own the jobs to this
   login with deploy/v2/054 so the runner actually executes under this least-privilege identity.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    /* =========================== CHANGE-ME =============================== */
    @RuntimeLogin        sysname       = N'karch_runtime_svc',          -- SQL login, or N'DOMAIN\svc-karchive' for Windows
    @LoginType           varchar(10)   = 'SQL',                         -- 'SQL' | 'WINDOWS'
    @SqlPassword         nvarchar(128) = N'<<SET-A-STRONG-PASSWORD>>',  -- used only when @LoginType='SQL'
    @SourceDbsCsv        nvarchar(max) = N'KMWEBV,Edge,KMWE_Test,AAD',  -- source DBs to grant on
    @ArchiveDb           sysname       = N'kArchiveManagerBackups',
    @PreProvisionArchive bit           = 1,                             -- 1 = create archive tables now (recommended)
    @Apply               bit           = 0;                            -- 0 = print plan only; 1 = apply
    /* ===================================================================== */

DECLARE @sql nvarchar(max);

IF @LoginType = 'SQL' AND (@SqlPassword IS NULL OR @SqlPassword = N'<<SET-A-STRONG-PASSWORD>>')
BEGIN
    RAISERROR('Set @SqlPassword (or switch @LoginType to WINDOWS). Nothing was changed.', 16, 1);
    RETURN;
END

/* ---- preview ------------------------------------------------------------- */
PRINT '--- Mapped source tables that will receive SELECT+DELETE (via role [karch_runtime]) ---';
SELECT DISTINCT os.SourceDb, SourceObject = QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable)
FROM arch.v_ObjectSpecDatabaseEffective os
WHERE os.ProcessDatabaseIsEnabled = 1 AND os.ObjectIsEnabled = 1
  AND EXISTS (SELECT 1 FROM STRING_SPLIT(@SourceDbsCsv, N',') s WHERE LTRIM(RTRIM(s.value)) = os.SourceDb)
ORDER BY os.SourceDb, SourceObject;

PRINT '--- Archive schemas that will receive INSERT+SELECT+ALTER ---';
SELECT DISTINCT
       ArchiveSchema = CONVERT(sysname, REPLACE(
            CASE WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo'
                 THEN N'{SourceDb}' ELSE LTRIM(RTRIM(os.ArchiveSchema)) END, N'{SourceDb}', os.SourceDb))
FROM arch.v_ObjectSpecDatabaseEffective os
WHERE os.ProcessDatabaseIsEnabled = 1 AND os.ObjectIsEnabled = 1 AND os.ArchiveDb = @ArchiveDb
  AND EXISTS (SELECT 1 FROM STRING_SPLIT(@SourceDbsCsv, N',') s WHERE LTRIM(RTRIM(s.value)) = os.SourceDb)
ORDER BY ArchiveSchema;

IF @Apply = 0
BEGIN
    PRINT 'PREVIEW ONLY (@Apply=0). Review the lists above, set @Apply=1, then re-run.';
    RETURN;
END

/* 1) server login --------------------------------------------------------- */
IF SUSER_ID(@RuntimeLogin) IS NULL
BEGIN
    IF @LoginType = 'WINDOWS'
        SET @sql = N'CREATE LOGIN ' + QUOTENAME(@RuntimeLogin) + N' FROM WINDOWS;';
    ELSE
        SET @sql = N'CREATE LOGIN ' + QUOTENAME(@RuntimeLogin) + N' WITH PASSWORD = ' + QUOTENAME(@SqlPassword, '''')
                 + N', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;';
    EXEC (@sql);
    PRINT 'Created login [' + @RuntimeLogin + '].';
END
ELSE PRINT 'Login [' + @RuntimeLogin + '] already exists — left as-is.';

/* never let the runner be sysadmin (it would bypass every per-table check) */
IF IS_SRVROLEMEMBER(N'sysadmin', @RuntimeLogin) = 1
    RAISERROR('Login [%s] is a member of sysadmin. Remove it from sysadmin before using it as the runner identity.', 16, 1, @RuntimeLogin);

/* 2) Admin DB: user + karch_runtime membership ---------------------------- */
SET @sql = N'
IF DATABASE_PRINCIPAL_ID(@u) IS NULL CREATE USER ' + QUOTENAME(@RuntimeLogin) + N' FOR LOGIN ' + QUOTENAME(@RuntimeLogin) + N';
IF IS_ROLEMEMBER(N''karch_runtime'', @u) = 0 ALTER ROLE [karch_runtime] ADD MEMBER ' + QUOTENAME(@RuntimeLogin) + N';';
EXEC sys.sp_executesql @sql, N'@u sysname', @u = @RuntimeLogin;
PRINT 'Admin DB: user mapped + added to [karch_runtime].';

/* 3) Source DBs: role + user + SELECT/DELETE on mapped tables -------------- */
DECLARE @db sysname;
DECLARE dbc CURSOR LOCAL FAST_FORWARD FOR
    SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@SourceDbsCsv, N',')
    WHERE NULLIF(LTRIM(RTRIM(value)), N'') IS NOT NULL;
OPEN dbc;
FETCH NEXT FROM dbc INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF DB_ID(@db) IS NULL
    BEGIN
        PRINT 'Source DB [' + @db + '] does not exist — skipped.';
        FETCH NEXT FROM dbc INTO @db; CONTINUE;
    END;

    DECLARE @grants nvarchar(max) = N'';
    /* ObjectSpec tables = read-joined AND deleted -> SELECT + DELETE */
    SELECT @grants = @grants + N'GRANT SELECT, DELETE ON OBJECT::'
                   + QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable) + N' TO [karch_runtime];' + CHAR(10)
    FROM (SELECT DISTINCT SourceSchema, SourceTable
          FROM arch.v_ObjectSpecDatabaseEffective
          WHERE ProcessDatabaseIsEnabled = 1 AND ObjectIsEnabled = 1 AND SourceDb = @db) os;
    /* ANCHOR candidate (header) table is SCANNED for selection (014) but may have NO ObjectSpec row
       (it is never itself deleted) -> SELECT only. Redundant+harmless if it is also an ObjectSpec table. */
    SELECT @grants = @grants + N'GRANT SELECT ON OBJECT::'
                   + QUOTENAME(a.AnchorSchema) + N'.' + QUOTENAME(a.AnchorTable) + N' TO [karch_runtime];' + CHAR(10)
    FROM (SELECT DISTINCT AnchorSchema, AnchorTable
          FROM arch.v_ProcessDatabaseEffective
          WHERE IsEnabled = 1 AND COALESCE(SelectionStrategy, N'ANCHOR') = N'ANCHOR' AND SourceDb = @db
            AND NULLIF(LTRIM(RTRIM(AnchorTable)), N'') IS NOT NULL
            AND NULLIF(LTRIM(RTRIM(AnchorSchema)), N'') IS NOT NULL) a;

    SET @sql = N'USE ' + QUOTENAME(@db) + N';
IF DATABASE_PRINCIPAL_ID(N''karch_runtime'') IS NULL CREATE ROLE [karch_runtime];
IF DATABASE_PRINCIPAL_ID(@u) IS NULL CREATE USER ' + QUOTENAME(@RuntimeLogin) + N' FOR LOGIN ' + QUOTENAME(@RuntimeLogin) + N';
IF IS_ROLEMEMBER(N''karch_runtime'', @u) = 0 ALTER ROLE [karch_runtime] ADD MEMBER ' + QUOTENAME(@RuntimeLogin) + N';
' + @grants;
    EXEC sys.sp_executesql @sql, N'@u sysname', @u = @RuntimeLogin;
    PRINT 'Source DB [' + @db + ']: role + user + per-table SELECT/DELETE applied.';

    FETCH NEXT FROM dbc INTO @db;
END
CLOSE dbc;
DEALLOCATE dbc;

/* 4) (optional) pre-provision archive tables as the DBA, so the runner needs no CREATE at run time */
IF @PreProvisionArchive = 1 AND OBJECT_ID(N'arch.usp_ProvisionArchiveTablesForProcess', N'P') IS NOT NULL
BEGIN
    DECLARE @pc sysname, @sd sysname, @ad sysname;
    DECLARE pp CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT e.ProcessCode, e.SourceDb, e.ArchiveDb
        FROM arch.v_ProcessDatabaseEffective e
        WHERE e.IsEnabled = 1 AND e.Mode = 1
          AND EXISTS (SELECT 1 FROM STRING_SPLIT(@SourceDbsCsv, N',') s WHERE LTRIM(RTRIM(s.value)) = e.SourceDb);
    OPEN pp;
    FETCH NEXT FROM pp INTO @pc, @sd, @ad;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC arch.usp_ProvisionArchiveTablesForProcess @ProcessCode = @pc, @SourceDb = @sd, @ArchiveDb = @ad;
        END TRY
        BEGIN CATCH
            PRINT 'Provision skipped for ' + @pc + '/' + @sd + ': ' + ERROR_MESSAGE();
        END CATCH
        FETCH NEXT FROM pp INTO @pc, @sd, @ad;
    END
    CLOSE pp;
    DEALLOCATE pp;
    PRINT 'Archive tables pre-provisioned for enabled Mode=1 mappings.';
END

/* 5) Archive DB: role + user + INSERT/SELECT/ALTER on the archive schema(s) (NO delete/update) */
DECLARE @aschemas nvarchar(max) = N'';
SELECT @aschemas = @aschemas
        + N'IF SCHEMA_ID(N''' + REPLACE(s.ArchiveSchema, N'''', N'''''') + N''') IS NULL EXEC(N''CREATE SCHEMA ' + QUOTENAME(s.ArchiveSchema) + N' AUTHORIZATION dbo'');' + CHAR(10)
        + N'GRANT INSERT, SELECT, ALTER ON SCHEMA::' + QUOTENAME(s.ArchiveSchema) + N' TO [karch_runtime];' + CHAR(10)
FROM (
    SELECT DISTINCT CONVERT(sysname, REPLACE(
            CASE WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo'
                 THEN N'{SourceDb}' ELSE LTRIM(RTRIM(os.ArchiveSchema)) END, N'{SourceDb}', os.SourceDb)) AS ArchiveSchema
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessDatabaseIsEnabled = 1 AND os.ObjectIsEnabled = 1 AND os.ArchiveDb = @ArchiveDb
      AND EXISTS (SELECT 1 FROM STRING_SPLIT(@SourceDbsCsv, N',') s WHERE LTRIM(RTRIM(s.value)) = os.SourceDb)
) s;

SET @sql = N'USE ' + QUOTENAME(@ArchiveDb) + N';
IF DATABASE_PRINCIPAL_ID(N''karch_runtime'') IS NULL CREATE ROLE [karch_runtime];
IF DATABASE_PRINCIPAL_ID(@u) IS NULL CREATE USER ' + QUOTENAME(@RuntimeLogin) + N' FOR LOGIN ' + QUOTENAME(@RuntimeLogin) + N';
IF IS_ROLEMEMBER(N''karch_runtime'', @u) = 0 ALTER ROLE [karch_runtime] ADD MEMBER ' + QUOTENAME(@RuntimeLogin) + N';
'   /* CREATE TABLE only matters together with ALTER ON SCHEMA (self-provisioning a new table into a
       granted schema); skip it when no archive schema is granted for this DB to avoid a stray privilege */
  + CASE WHEN NULLIF(@aschemas, N'') IS NOT NULL THEN N'GRANT CREATE TABLE TO [karch_runtime];' + CHAR(10) ELSE N'' END
  + ISNULL(@aschemas, N'');
EXEC sys.sp_executesql @sql, N'@u sysname', @u = @RuntimeLogin;
PRINT 'Archive DB [' + @ArchiveDb + ']: role + user + per-schema INSERT/SELECT/ALTER + CREATE TABLE applied (no DELETE/UPDATE).';

/* OPTIONAL — only if you also want this runner to OWN 'kArchiveManager - RECOVER STALE RUNS'
   (deploy/v2/054 @AlsoRecover=1): usp_RecoverStaleRuns reads OTHER sessions in sys.dm_exec_sessions
   to tell a live run from a dead one; without VIEW SERVER STATE the runner sees only its own session
   and would wrongly recover live runs (T-03 race). Uncomment to grant the (read-only, server-wide) right.
   By default recovery stays owned by the Agent service account / sysadmin, so this is NOT granted. */
-- IF SUSER_ID(@RuntimeLogin) IS NOT NULL GRANT VIEW SERVER STATE TO [karch_runtime_svc];

/* 6) inventory + verify --------------------------------------------------- */
EXEC arch.usp_CaptureRunnerPrivilegeInventory @RunnerLogin = @RuntimeLogin, @DbsCsv = @SourceDbsCsv, @CapturedBy = NULL;
EXEC arch.usp_CaptureRunnerPrivilegeInventory @RunnerLogin = @RuntimeLogin, @DbsCsv = @ArchiveDb,    @CapturedBy = NULL;

PRINT '--- Verifying runner footprint AS [' + @RuntimeLogin + '] ---';
SET @sql = N'EXECUTE AS LOGIN = ' + QUOTENAME(@RuntimeLogin, '''') + N';
EXEC arch.usp_VerifyRunnerPrivileges;
REVERT;';
EXEC (@sql);

PRINT 'Done. If VerifyRunnerPrivileges returned any ERROR row, fix the grant (its SuggestedSql) and re-run. Then re-own the Agent jobs with deploy/v2/054.';
GO
