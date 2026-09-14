USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/* ============================================================================
   arch.usp_Frontend_GoLiveReadiness — operationalizes the production audit as a LIVE go-live gate.
   READ-ONLY. Returns one row per check: Category, CheckName, Severity (OK/INFO/WARN/FAIL), Detail,
   Recommendation. FAIL = go-live blocker. Surfaced by the Admin Console "Go-live readiness" panel.
   ============================================================================ */
CREATE OR ALTER PROCEDURE arch.usp_Frontend_GoLiveReadiness
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @r TABLE (Ord int IDENTITY(1,1), Category sysname, CheckName nvarchar(200),
                      Severity varchar(6), Detail nvarchar(1000), Recommendation nvarchar(500));

    /* ---------- A. PRIVILEGES ---------- */
    DECLARE @overpriv nvarchar(1000) = (
        SELECT STRING_AGG(name, N', ') FROM (
            SELECT DISTINCT pr.name
            FROM sys.database_permissions pm JOIN sys.database_principals pr ON pr.principal_id=pm.grantee_principal_id
            WHERE pm.permission_name='EXECUTE' AND pm.class_desc='DATABASE' AND pm.state_desc='GRANT' AND pr.name<>'dbo'
            UNION
            SELECT mp.name FROM sys.database_role_members drm
            JOIN sys.database_principals rp ON rp.principal_id=drm.role_principal_id AND rp.name='db_datawriter'
            JOIN sys.database_principals mp ON mp.principal_id=drm.member_principal_id AND mp.name<>'dbo'
        ) x);
    INSERT @r SELECT N'Privileges', N'No over-privileged principals',
        CASE WHEN @overpriv IS NULL THEN 'OK' ELSE 'FAIL' END,
        CASE WHEN @overpriv IS NULL THEN N'No non-dbo principal holds DB-wide EXECUTE or db_datawriter.' ELSE N'Over-privileged: '+@overpriv END,
        N'DROP / least-privilege these logins; the API pool should hold only karch_* roles. (T-01)';

    INSERT @r SELECT N'Privileges', N'Destructive procs granted to a role', sev, det, N'GRANT EXECUTE on stop/restore to karch_operator / karch_advanced_admin. (T-02)'
    FROM (SELECT
        sev = CASE WHEN stop_ok=1 AND restore_ok=1 THEN 'OK' ELSE 'FAIL' END,
        det = N'usp_Api_RequestRunStop granted='+CONVERT(varchar,stop_ok)+N', usp_RestoreFromArchive granted='+CONVERT(varchar,restore_ok)
      FROM (SELECT
        stop_ok = CASE WHEN EXISTS(SELECT 1 FROM sys.database_permissions pm JOIN sys.database_principals pr ON pr.principal_id=pm.grantee_principal_id WHERE pm.major_id=OBJECT_ID('arch.usp_Api_RequestRunStop') AND pm.permission_name='EXECUTE' AND pm.state_desc='GRANT' AND pr.type='R') THEN 1 ELSE 0 END,
        restore_ok = CASE WHEN EXISTS(SELECT 1 FROM sys.database_permissions pm JOIN sys.database_principals pr ON pr.principal_id=pm.grantee_principal_id WHERE pm.major_id=OBJECT_ID('arch.usp_RestoreFromArchive') AND pm.permission_name='EXECUTE' AND pm.state_desc='GRANT' AND pr.type='R') THEN 1 ELSE 0 END) a) b;

    /* ---------- B. LEGACY / RELICS ---------- */
    INSERT @r SELECT N'Cleanliness', N'No legacy_v1 / v1 procedures',
        CASE WHEN c=0 THEN 'OK' ELSE 'WARN' END, N'legacy_v1 + v1-stub objects: '+CONVERT(varchar,c),
        N'A fresh customer install should have none; on an upgraded env they are quarantined. (T-11/T-13)'
    FROM (SELECT c=(SELECT COUNT(*) FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id WHERE s.name='legacy_v1')
                 + (SELECT COUNT(*) FROM sys.objects WHERE type='P' AND SCHEMA_NAME(schema_id)='arch' AND name IN(N'usp_RunProcess',N'usp_RunProcess_RF_LOG2',N'usp_RunProcess_TimestampKeyset'))) z;

    INSERT @r SELECT N'Cleanliness', N'No relic tables',
        CASE WHEN c=0 THEN 'OK' ELSE 'WARN' END, N'relic tables: '+CONVERT(varchar,c),
        N'Drop arch.RowCountSnapshot and *_Backup_* once TZ-rollback window is closed.'
    FROM (SELECT c=(SELECT COUNT(*) FROM sys.tables WHERE SCHEMA_NAME(schema_id)='arch' AND (name='RowCountSnapshot' OR name LIKE '%[_]Backup[_]%'))) z;

    /* ---------- C. AUDIT GOVERNANCE ---------- */
    INSERT @r SELECT N'Audit', N'Per-document audit coverage (Mode=1)',
        CASE WHEN tot=0 OR below>0 THEN 'INFO' ELSE 'OK' END,
        CASE WHEN tot=0 THEN N'No enabled Mode=1 mappings configured yet.'
             ELSE CONVERT(varchar,below)+N' of '+CONVERT(varchar,tot)+N' enabled Mode=1 mappings have AuditLevel < ROW (no per-row trail)' END,
        N'Operator-controlled choice; set AuditLevel=ROW where a per-document deletion trail is required. (T-08)'
    FROM (SELECT tot=COUNT(*), below=ISNULL(SUM(CASE WHEN AuditLevel<>N'ROW' THEN 1 ELSE 0 END),0)
          FROM arch.v_ProcessDatabaseEffective WHERE IsEnabled=1 AND Mode=1) z;

    INSERT @r SELECT N'Audit', N'Audit trail is tamper-resistant (DENY on RunDocAudit)',
        CASE WHEN EXISTS(SELECT 1 FROM sys.database_permissions WHERE major_id=OBJECT_ID('arch.RunDocAudit') AND permission_name IN('UPDATE','DELETE') AND state_desc='DENY') THEN 'OK' ELSE 'WARN' END,
        N'', N'Deploy 045_audit_immutability (DENY UPDATE/DELETE) + remove db_datawriter logins. (T-09)';

    /* ---------- D. CONFIG / TIMEZONE GATE ---------- */
    INSERT @r SELECT N'Config', N'Timezone gate coverage (enabled Mode=1 cutoffs UTC-normalized)',
        CASE WHEN raw=0 THEN 'OK' ELSE 'FAIL' END,
        CONVERT(varchar,raw)+N' enabled Mode=1 mappings have a cutoff expression without AT TIME ZONE (real runs blocked by THROW 50200)',
        N'Wrap the cutoff in CAST(...) AT TIME ZONE ... AT TIME ZONE UTC, or these processes cannot run. (Risk K1)'
    FROM (SELECT raw=COUNT(*) FROM arch.v_ProcessDatabaseEffective e WHERE e.IsEnabled=1 AND e.Mode=1
            AND ( (COALESCE(e.SelectionStrategy,N'ANCHOR')=N'ANCHOR' AND ISNULL(e.AnchorTimestampExpr,N'') NOT LIKE N'%AT TIME ZONE%')
               OR (COALESCE(e.SelectionStrategy,N'ANCHOR')=N'TIMESTAMP' AND NOT EXISTS (
                     SELECT 1 FROM arch.v_ObjectSpecDatabaseEffective os WHERE os.ProcessDatabaseId=e.ProcessDatabaseId AND os.ObjectIsEnabled=1
                       AND ISNULL(os.TimestampExpr,N'') LIKE N'%AT TIME ZONE%') ) )) z;

    /* ---------- E. OPERATIONS ---------- */
    INSERT @r SELECT N'Operations', N'No operational-health errors',
        CASE WHEN c=0 THEN 'OK' ELSE 'FAIL' END, CONVERT(varchar,c)+N' ERROR rows in arch.v_OperationalHealth',
        N'Investigate FAILED runs / ROW_COUNT_MISMATCH / ROW_AUDIT_MISSING before go-live.'
    FROM (SELECT c=(SELECT COUNT(*) FROM arch.v_OperationalHealth WHERE Severity=N'ERROR')) z;

    INSERT @r SELECT N'Operations', N'Failure alerting configured',
        CASE WHEN mail=1 AND op=1 AND notify>0 THEN 'OK' ELSE 'WARN' END,
        N'DatabaseMail='+CONVERT(varchar,mail)+N', operator='+CONVERT(varchar,op)+N', jobs emailing on failure='+CONVERT(varchar,notify),
        N'Run 047_operational_alerting (Database Mail + operator + job notify + HEALTH ALERT job). (T-14)'
    FROM (SELECT
        mail=(SELECT CONVERT(int,ISNULL((SELECT CONVERT(int,value_in_use) FROM sys.configurations WHERE name='Database Mail XPs'),0))),
        op=(SELECT CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysoperators WHERE enabled=1) THEN 1 ELSE 0 END),
        notify=(SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE 'kArchiveManager%' AND notify_level_email=2)) z;

    INSERT @r SELECT N'Operations', N'Archive DB recent backup',
        CASE WHEN last_full IS NULL THEN 'WARN' WHEN last_full < DATEADD(DAY,-2,GETDATE()) THEN 'WARN' ELSE 'OK' END,
        N'kArchiveManagerBackups last FULL backup: '+ISNULL(CONVERT(varchar(30),last_full,120),N'NONE'),
        N'kArchiveManagerBackups is the system-of-record for deleted rows - schedule FULL+LOG backups + restore drill. (T-16)'
    FROM (SELECT last_full=(SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset WHERE database_name='kArchiveManagerBackups' AND type='D')) z;

    INSERT @r SELECT N'Operations', N'Stale-run recovery job enabled',
        CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name='kArchiveManager - RECOVER STALE RUNS' AND enabled=1) THEN 'OK' ELSE 'WARN' END,
        N'', N'Enable the RECOVER STALE RUNS job so orphaned runs self-heal.';

    /* ---------- Summary verdict ---------- */
    INSERT @r SELECT N'Summary', N'Go-live verdict',
        CASE WHEN EXISTS(SELECT 1 FROM @r WHERE Severity='FAIL') THEN 'FAIL'
             WHEN EXISTS(SELECT 1 FROM @r WHERE Severity='WARN') THEN 'WARN' ELSE 'OK' END,
        CONVERT(varchar,(SELECT COUNT(*) FROM @r WHERE Severity='FAIL'))+N' blocker(s), '
        +CONVERT(varchar,(SELECT COUNT(*) FROM @r WHERE Severity='WARN'))+N' warning(s)',
        N'Resolve all FAIL items before enabling the RUN CONFIGURED job for real deletes.';

    SELECT Category, CheckName, Severity, Detail, Recommendation
    FROM @r ORDER BY CASE WHEN Category='Summary' THEN 0 ELSE 1 END,
                     CASE Severity WHEN 'FAIL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'INFO' THEN 2 ELSE 3 END, Ord;
END
GO
-- Read-only readiness proc: grant to the viewer role so the Admin Console (app-pool identity) can call it.
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GoLiveReadiness] TO [karch_viewer];
GO
PRINT '049_golive_readiness deployed (arch.usp_Frontend_GoLiveReadiness + karch_viewer grant).';
GO
