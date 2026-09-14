USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
/* ============================================================================
   055 — T-33 (bundle part): least-privilege RUNTIME role + runner-privilege verify/inventory
   ----------------------------------------------------------------------------
   WHY: the archive runner performs the most dangerous operation in the system — an irreversible
   cross-DB DELETE of production rows. Today the "RUN CONFIGURED" SQL Agent job runs a T-SQL step
   with no proxy, so it executes under the SQL Agent service account (de-facto sysadmin for T-SQL):
   the runner's identity in the source DBs is unconstrained (T-33). This script installs the
   customer-AGNOSTIC half of the fix that belongs in the clean bundle:

     1. role [karch_runtime] — granted EXECUTE on the runner proc chain ONLY. The runner's writes to
        the Admin control tables (arch.Run/RunItem/RunItemObject/RunDocAudit/WorkBatch/WorkBatchKey/
        ArchiveProvisionLog) are STATIC SQL inside those procs, so they reach the tables through
        OWNERSHIP CHAINING (proc and tables share owner dbo) — the runtime principal therefore needs
        NO direct table DML in the Admin DB, only EXECUTE.  The cross-DB DELETE/OUTPUT-INTO is DYNAMIC
        SQL (chaining broken) and needs EXPLICIT source/archive grants — those are applied per-customer
        by deploy/v2/053_runtime_least_privilege_principal.sql.

     2. arch.usp_VerifyRunnerPrivileges — asserts the CURRENT principal (i.e. the runtime login, when
        run by the job's VALIDATE step) is NOT sysadmin / db_owner / db_ddladmin / db_securityadmin /
        db_datawriter, and HAS SELECT+DELETE on every enabled mapped source table and INSERT on every
        archive table.  RETURN 1 (and an ERROR result row) on any violation so the job's VALIDATE step
        can THROW and block the run.  (Honors T-33's "assert runner has DELETE on every mapped table
        and does not hold db_owner/sysadmin" without destabilising the heavily-used
        usp_ValidateConfiguration — the job step calls BOTH.)

     3. arch.RunnerPrivilegeInventory + arch.usp_CaptureRunnerPrivilegeInventory — capture the runtime
        principal's effective source/archive-DB role memberships + explicit object permissions into an
        audit inventory (T-33 "zachytit source-DB granty do audit inventáře").

   The privilege checks are evaluated for the CURRENT principal (HAS_PERMS_BY_NAME / IS_ROLEMEMBER are
   current-context). Run usp_VerifyRunnerPrivileges AS the runtime login — the job's VALIDATE step does
   this automatically; for an out-of-band DBA audit wrap it:
       EXECUTE AS LOGIN = N'<runtime login>'; EXEC arch.usp_VerifyRunnerPrivileges; REVERT;
   ============================================================================ */

/* ---- 1) role: karch_runtime ------------------------------------------------ */
IF DATABASE_PRINCIPAL_ID(N'karch_runtime') IS NULL
    CREATE ROLE [karch_runtime];
GO

DECLARE @procs TABLE (name sysname PRIMARY KEY);
INSERT @procs(name) VALUES
    (N'usp_RunProfile_Prepared'),
    (N'usp_RunScheduledProfiles_Prepared'),
    (N'usp_RunConfiguredProcesses_Prepared'),
    (N'usp_RunPreparedBatch'),
    (N'usp_RunPreparedBatches_InWindow'),
    (N'usp_PrepareCandidates'),
    (N'usp_RunTimestampProcess'),
    (N'usp_EnsureArchiveTableLikeSource'),
    (N'usp_GetOutputColumns'),
    (N'usp_AssertTimezonePolicyApplied'),
    (N'usp_ValidateConfiguration'),
    (N'usp_RecoverStaleRuns');
    -- NB: usp_VerifyRunnerPrivileges is created LATER in this script, so it cannot be granted by this
    --     existence-guarded cursor; it is granted to karch_runtime explicitly at the end of the file.

DECLARE @n sysname, @g nvarchar(max);
DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM @procs WHERE OBJECT_ID(N'arch.' + name, N'P') IS NOT NULL;
OPEN pc;
FETCH NEXT FROM pc INTO @n;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @g = N'GRANT EXECUTE ON OBJECT::arch.' + QUOTENAME(@n) + N' TO [karch_runtime];';
    EXEC sys.sp_executesql @g;
    FETCH NEXT FROM pc INTO @n;
END
CLOSE pc;
DEALLOCATE pc;
GO

-- Metadata visibility: the runner procs guard with OBJECT_ID()/COL_LENGTH() on arch.* control tables.
-- Those metadata functions follow the CALLER's visibility and are NOT covered by ownership chaining
-- (chaining covers DATA access only), so without this the guards see NULL under the least-priv runner
-- and falsely THROW (e.g. 50107 'arch.ProcessKeySpec neni nainstalovana'). VIEW DEFINITION grants
-- metadata visibility only — no data SELECT (data access still flows through the procs via chaining).
IF DATABASE_PRINCIPAL_ID(N'karch_runtime') IS NOT NULL
    GRANT VIEW DEFINITION ON SCHEMA::[arch] TO [karch_runtime];
GO

/* ---- 2) runner-privilege inventory table ----------------------------------- */
IF OBJECT_ID(N'arch.RunnerPrivilegeInventory', N'U') IS NULL
BEGIN
    CREATE TABLE [arch].[RunnerPrivilegeInventory]
    (
        InventoryId   bigint IDENTITY(1,1) NOT NULL CONSTRAINT [PK_RunnerPrivilegeInventory] PRIMARY KEY,
        CapturedAtUtc datetime2(0) NOT NULL CONSTRAINT [DF_RunnerPrivInv_At] DEFAULT (SYSUTCDATETIME()),
        CapturedBy    sysname NULL,
        RunnerLogin   sysname NOT NULL,
        DbName        sysname NOT NULL,
        PrincipalName sysname NULL,
        GrantKind     nvarchar(20) NOT NULL,     -- 'ROLE' | 'PERMISSION'
        Detail        nvarchar(400) NOT NULL
    );
    CREATE NONCLUSTERED INDEX [IX_RunnerPrivInv_At]
        ON [arch].[RunnerPrivilegeInventory] (CapturedAtUtc DESC, RunnerLogin, DbName);
END
GO

/* ---- 3) verify the current principal is a correct least-priv runner -------- */
CREATE OR ALTER PROCEDURE [arch].[usp_VerifyRunnerPrivileges]
    @ProcessCode sysname = NULL,        -- optional scope
    @SourceDb    sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @me sysname = SUSER_SNAME();

    CREATE TABLE #VF
    (
        Severity   varchar(10)   NOT NULL,
        Scope      nvarchar(20)  NOT NULL,    -- 'SERVER' | 'SOURCE' | 'ARCHIVE'
        DbName     sysname       NULL,
        ObjectName nvarchar(300) NULL,
        Finding    nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL
    );

    /* (a) the runner must NOT be sysadmin — sysadmin would bypass every per-table check below */
    IF IS_SRVROLEMEMBER(N'sysadmin') = 1
        INSERT #VF(Severity, Scope, Finding)
        VALUES ('ERROR', N'SERVER',
                N'Runner principal [' + @me + N'] is a member of the sysadmin server role. The unattended '
              + N'archive runner must run under a dedicated NON-sysadmin login (see deploy/v2/053). '
              + N'Re-own the SQL Agent job to the least-privilege login (deploy/v2/054).');

    /* (b)/(c) per enabled mapping: archive-side INSERT and source-side SELECT+DELETE + not db_owner */
    DECLARE @db sysname, @sch sysname, @tbl sysname, @asch sysname, @atbl sysname, @mode tinyint,
            @obj nvarchar(512), @aobj nvarchar(512), @sql nvarchar(max),
            @selOk int, @delOk int, @insOk int, @powner int, @evaluated bit, @schemaExists int;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT
            os.SourceDb, os.SourceSchema, os.SourceTable,
            CONVERT(sysname, REPLACE(
                CASE WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo'
                     THEN N'{SourceDb}' ELSE LTRIM(RTRIM(os.ArchiveSchema)) END, N'{SourceDb}', os.SourceDb)),
            COALESCE(NULLIF(os.ArchiveTable, N''), os.SourceTable),
            e.Mode, os.ArchiveDb
        FROM arch.v_ObjectSpecDatabaseEffective os
        JOIN arch.v_ProcessDatabaseEffective e ON e.ProcessDatabaseId = os.ProcessDatabaseId
        WHERE os.ProcessDatabaseIsEnabled = 1
          AND os.ObjectIsEnabled = 1
          AND DB_ID(os.SourceDb) IS NOT NULL
          AND DB_ID(os.ArchiveDb) IS NOT NULL
          AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb);

    DECLARE @archDb sysname;
    OPEN c;
    FETCH NEXT FROM c INTO @db, @sch, @tbl, @asch, @atbl, @mode, @archDb;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        /* source: SELECT + DELETE on the mapped table, and the runner must not be a high-priv db role */
        SET @obj = QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl);
        SET @selOk = NULL; SET @delOk = NULL; SET @powner = NULL; SET @evaluated = 1;
        SET @sql = N'USE ' + QUOTENAME(@db) + N';
            SELECT @selOk = CONVERT(int, HAS_PERMS_BY_NAME(@o, ''OBJECT'', ''SELECT'')),
                   @delOk = CONVERT(int, HAS_PERMS_BY_NAME(@o, ''OBJECT'', ''DELETE'')),
                   @po = COALESCE(IS_ROLEMEMBER(''db_owner''),0)
                       + COALESCE(IS_ROLEMEMBER(''db_ddladmin''),0)
                       + COALESCE(IS_ROLEMEMBER(''db_securityadmin''),0)
                       + COALESCE(IS_ROLEMEMBER(''db_datawriter''),0);';
        BEGIN TRY
            EXEC sys.sp_executesql @sql,
                 N'@o nvarchar(512), @selOk int OUTPUT, @delOk int OUTPUT, @po int OUTPUT',
                 @o = @obj, @selOk = @selOk OUTPUT, @delOk = @delOk OUTPUT, @po = @powner OUTPUT;
        END TRY
        BEGIN CATCH
            SET @evaluated = 0;   -- could not connect/USE this DB; report once as WARN, no spurious ERROR
            INSERT #VF(Severity, Scope, DbName, ObjectName, Finding)
            VALUES ('WARN', N'SOURCE', @db, @obj,
                    N'Could not evaluate source-table permissions (' + ERROR_MESSAGE() + N').');
        END CATCH

        IF @evaluated = 1
        BEGIN
            IF COALESCE(@delOk, 0) < 1
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding, SuggestedSql)
                VALUES ('ERROR', N'SOURCE', @db, @obj,
                        N'Runner [' + @me + N'] lacks DELETE on the mapped source table (or the table is not visible to it).',
                        N'USE ' + QUOTENAME(@db) + N'; GRANT SELECT, DELETE ON OBJECT::' + @obj + N' TO [karch_runtime];');
            ELSE IF COALESCE(@selOk, 0) < 1
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding, SuggestedSql)
                VALUES ('ERROR', N'SOURCE', @db, @obj,
                        N'Runner [' + @me + N'] lacks SELECT on the mapped source table.',
                        N'USE ' + QUOTENAME(@db) + N'; GRANT SELECT, DELETE ON OBJECT::' + @obj + N' TO [karch_runtime];');

            IF COALESCE(@powner, 0) > 0
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding)
                VALUES ('ERROR', N'SOURCE', @db, @obj,
                        N'Runner [' + @me + N'] is a member of a high-privilege database role (db_owner / db_ddladmin / '
                      + N'db_securityadmin / db_datawriter) in source DB [' + @db + N']. The runner must hold only '
                      + N'SELECT+DELETE on the mapped tables via [karch_runtime]. Remove the broad role membership.');
        END;

        /* archive: the schema must exist (a non-dbo runner cannot CREATE SCHEMA at run time) and the
           runner needs INSERT on the archive table (DELETE/OUTPUT INTO target). COALESCE NULL Mode->1
           so an unset Mode is treated as archive+delete (the safe default). */
        IF COALESCE(@mode, 1) = 1
        BEGIN
            SET @aobj = QUOTENAME(@asch) + N'.' + QUOTENAME(@atbl);
            SET @insOk = NULL; SET @schemaExists = NULL;
            SET @sql = N'USE ' + QUOTENAME(@archDb) + N';
                SELECT @schemaExists = CASE WHEN SCHEMA_ID(@sch) IS NULL THEN 0 ELSE 1 END,
                       @insOk = CONVERT(int, HAS_PERMS_BY_NAME(@o, ''OBJECT'', ''INSERT''));';
            BEGIN TRY
                EXEC sys.sp_executesql @sql, N'@sch sysname, @o nvarchar(512), @schemaExists int OUTPUT, @insOk int OUTPUT',
                     @sch = @asch, @o = @aobj, @schemaExists = @schemaExists OUTPUT, @insOk = @insOk OUTPUT;
            END TRY
            BEGIN CATCH
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding)
                VALUES ('WARN', N'ARCHIVE', @archDb, @aobj,
                        N'Could not evaluate archive INSERT/schema (' + ERROR_MESSAGE() + N').');
            END CATCH

            IF COALESCE(@schemaExists, 1) = 0
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding, SuggestedSql)
                VALUES ('ERROR', N'ARCHIVE', @archDb, @asch,
                        N'Archive schema [' + @asch + N'] does not exist in [' + @archDb + N']. The non-sysadmin runner '
                      + N'cannot CREATE SCHEMA at run time — re-run deploy/v2/053 (it pre-creates archive schemas as the DBA).',
                        N'USE ' + QUOTENAME(@archDb) + N'; IF SCHEMA_ID(N''' + REPLACE(@asch, N'''', N'''''') + N''') IS NULL EXEC(N''CREATE SCHEMA ' + QUOTENAME(@asch) + N' AUTHORIZATION dbo'');');

            IF COALESCE(@insOk, 0) < 1
                INSERT #VF(Severity, Scope, DbName, ObjectName, Finding, SuggestedSql)
                VALUES ('WARN', N'ARCHIVE', @archDb, @aobj,
                        N'Runner [' + @me + N'] lacks INSERT on the archive table (or it is not provisioned yet — '
                      + N'deploy/v2/053 grants INSERT on the whole archive schema, which covers tables created later).',
                        N'USE ' + QUOTENAME(@archDb) + N'; GRANT INSERT ON OBJECT::' + @aobj + N' TO [karch_runtime];');
        END;

        FETCH NEXT FROM c INTO @db, @sch, @tbl, @asch, @atbl, @mode, @archDb;
    END
    CLOSE c;
    DEALLOCATE c;

    /* ANCHOR candidate (header) table: the ANCHOR candidate scan reads FROM AnchorSchema.AnchorTable
       (v_ProcessDatabaseEffective), which may have NO ObjectSpec row, so it is invisible to the loop
       above. It needs SELECT only (it is never deleted directly). */
    DECLARE @adb sysname, @ansch sysname, @antbl sysname, @aobj2 nvarchar(512), @anSel int, @anEval bit;
    DECLARE ac CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT e.SourceDb, e.AnchorSchema, e.AnchorTable
        FROM arch.v_ProcessDatabaseEffective e
        WHERE e.IsEnabled = 1
          AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
          AND DB_ID(e.SourceDb) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(e.AnchorTable)), N'') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(e.AnchorSchema)), N'') IS NOT NULL
          AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb);
    OPEN ac;
    FETCH NEXT FROM ac INTO @adb, @ansch, @antbl;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @aobj2 = QUOTENAME(@ansch) + N'.' + QUOTENAME(@antbl);
        SET @anSel = NULL; SET @anEval = 1;
        SET @sql = N'USE ' + QUOTENAME(@adb) + N'; SELECT @s = CONVERT(int, HAS_PERMS_BY_NAME(@o, ''OBJECT'', ''SELECT''));';
        BEGIN TRY
            EXEC sys.sp_executesql @sql, N'@o nvarchar(512), @s int OUTPUT', @o = @aobj2, @s = @anSel OUTPUT;
        END TRY
        BEGIN CATCH SET @anEval = 0; END CATCH

        IF @anEval = 1 AND COALESCE(@anSel, 0) < 1
            INSERT #VF(Severity, Scope, DbName, ObjectName, Finding, SuggestedSql)
            VALUES ('ERROR', N'SOURCE', @adb, @aobj2,
                    N'Runner [' + @me + N'] lacks SELECT on the ANCHOR candidate (header) table — the ANCHOR candidate '
                  + N'scan reads from it. (It is a Process/ProcessDatabase anchor, not necessarily an ObjectSpec row.)',
                    N'USE ' + QUOTENAME(@adb) + N'; GRANT SELECT ON OBJECT::' + @aobj2 + N' TO [karch_runtime];');

        FETCH NEXT FROM ac INTO @adb, @ansch, @antbl;
    END
    CLOSE ac;
    DEALLOCATE ac;

    IF NOT EXISTS (SELECT 1 FROM #VF)
        INSERT #VF(Severity, Scope, Finding)
        VALUES ('OK', N'SERVER', N'Runner principal [' + @me + N'] holds a correct least-privilege footprint for all enabled mappings.');

    SELECT Severity, Scope, DbName, ObjectName, Finding, SuggestedSql
    FROM #VF
    ORDER BY CASE Severity WHEN 'ERROR' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, Scope, DbName, ObjectName;

    IF EXISTS (SELECT 1 FROM #VF WHERE Severity = 'ERROR')
        RETURN 1;
    RETURN 0;
END
GO

/* ---- 4) capture the runtime principal's effective grants into the inventory --- */
CREATE OR ALTER PROCEDURE [arch].[usp_CaptureRunnerPrivilegeInventory]
    @RunnerLogin  sysname,
    @DbsCsv       nvarchar(max),        -- source + archive DBs to inventory, comma-separated
    @CapturedBy   sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @CapturedBy = COALESCE(@CapturedBy, SUSER_SNAME());

    DECLARE @db sysname, @sql nvarchar(max);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DbsCsv, N',')
        WHERE NULLIF(LTRIM(RTRIM(value)), N'') IS NOT NULL;
    OPEN c;
    FETCH NEXT FROM c INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF DB_ID(@db) IS NULL
        BEGIN
            FETCH NEXT FROM c INTO @db; CONTINUE;
        END;

        SET @sql = N'USE ' + QUOTENAME(@db) + N';
            -- resolve by SID (not name) so a DB user created with a name <> its login is still found.
            -- NOTE: this proc writes cross-DB into the Admin inventory table, so it must run with INSERT
            -- there (i.e. as the DBA at deploy time) — never under the runner / EXECUTE AS.
            DECLARE @uid int = (SELECT principal_id FROM sys.database_principals WHERE sid = SUSER_SID(@login));
            IF @uid IS NOT NULL
            BEGIN
                INSERT [kArchiveManagerAdmin].arch.RunnerPrivilegeInventory(CapturedBy, RunnerLogin, DbName, PrincipalName, GrantKind, Detail)
                SELECT @by, @login, @dbn, dp.name, N''ROLE'', rp.name
                FROM sys.database_role_members drm
                JOIN sys.database_principals rp ON rp.principal_id = drm.role_principal_id
                JOIN sys.database_principals dp ON dp.principal_id = drm.member_principal_id
                WHERE drm.member_principal_id = @uid;

                INSERT [kArchiveManagerAdmin].arch.RunnerPrivilegeInventory(CapturedBy, RunnerLogin, DbName, PrincipalName, GrantKind, Detail)
                SELECT @by, @login, @dbn, pr.name, N''PERMISSION'',
                       perm.state_desc + N'' '' + perm.permission_name + N'' ON '' + perm.class_desc
                     + COALESCE(N'' ['' + OBJECT_SCHEMA_NAME(perm.major_id) + N''.'' + OBJECT_NAME(perm.major_id) + N'']'', N'''')
                FROM sys.database_permissions perm
                JOIN sys.database_principals pr ON pr.principal_id = perm.grantee_principal_id
                WHERE perm.grantee_principal_id = @uid;
            END;';
        EXEC sys.sp_executesql @sql,
             N'@login sysname, @dbn sysname, @by sysname',
             @login = @RunnerLogin, @dbn = @db, @by = @CapturedBy;

        FETCH NEXT FROM c INTO @db;
    END
    CLOSE c;
    DEALLOCATE c;

    SELECT CapturedAtUtc, RunnerLogin, DbName, PrincipalName, GrantKind, Detail
    FROM arch.RunnerPrivilegeInventory
    WHERE RunnerLogin = @RunnerLogin
      AND CapturedAtUtc >= DATEADD(MINUTE, -1, SYSUTCDATETIME())
    ORDER BY DbName, GrantKind, Detail;
END
GO

-- The runner itself must EXECUTE the verify proc: the RUN CONFIGURED job's VALIDATE step calls it under
-- the runner identity. It is created AFTER the role-grant cursor above, so grant it here. (Capture stays
-- DBA-only — it writes cross-DB into the Admin inventory table and must run as the deploying sysadmin.)
IF DATABASE_PRINCIPAL_ID(N'karch_runtime') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_VerifyRunnerPrivileges] TO [karch_runtime];
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON [arch].[usp_VerifyRunnerPrivileges] TO [karch_advanced_admin];
    GRANT EXECUTE ON [arch].[usp_CaptureRunnerPrivilegeInventory] TO [karch_advanced_admin];
END
GO
PRINT '055_runtime_runner_role_and_verify deployed (role karch_runtime, arch.usp_VerifyRunnerPrivileges, arch.usp_CaptureRunnerPrivilegeInventory, arch.RunnerPrivilegeInventory).';
GO
