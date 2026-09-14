USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NULL
    CREATE ROLE [karch_viewer];
GO

IF DATABASE_PRINCIPAL_ID(N'karch_operator') IS NULL
    CREATE ROLE [karch_operator];
GO

IF DATABASE_PRINCIPAL_ID(N'karch_config_admin') IS NULL
    CREATE ROLE [karch_config_admin];
GO

IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NULL
    CREATE ROLE [karch_advanced_admin];
GO

IF DATABASE_PRINCIPAL_ID(N'karch_approver') IS NULL
    CREATE ROLE [karch_approver];
GO

DECLARE @Grants table
(
    RoleName sysname NOT NULL,
    SchemaName sysname NOT NULL,
    ObjectName sysname NOT NULL,
    Required bit NOT NULL
);

INSERT INTO @Grants(RoleName, SchemaName, ObjectName, Required)
VALUES
    (N'karch_viewer', N'arch', N'usp_Frontend_GetProcessConfigSummary', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetEffectiveProcessDatabases', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetEffectiveObjects', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetTableMovementCounts', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetProcessMovementSummary', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetProcessedHistory', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetWorkBatchActivity', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetRecentRuns', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetRunDetail', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_SearchDocumentAuditSummary', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_SearchDocumentAuditDetails', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetConfigChangeHistory', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetProcessKeySpecs', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetIndexRequirements', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetRunProfiles', 1),
    (N'karch_viewer', N'arch', N'usp_Frontend_GetSelectionStrategies', 1),

    (N'karch_operator', N'arch', N'usp_Api_ValidateConfiguration', 1),
    (N'karch_operator', N'arch', N'usp_Api_ValidateIndexRequirements', 1),
    (N'karch_operator', N'arch', N'usp_Api_ExplainProcessPlan', 1),

    (N'karch_config_admin', N'arch', N'usp_Api_SaveProcess', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SaveProcessDatabase', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SaveObjectSpec', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SaveObjectSpecOverride', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SaveRunProfile', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_CheckConfigConcurrency', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SetProcessEnabled', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SetProcessDatabaseEnabled', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SetObjectOverrideEnabled', 1),
    (N'karch_config_admin', N'arch', N'usp_Api_SetRunProfileEnabled', 1),

    (N'karch_advanced_admin', N'arch', N'usp_Api_SaveProcessKeySpec', 1),
    (N'karch_advanced_admin', N'arch', N'usp_Api_SaveIndexRequirement', 1),
    (N'karch_advanced_admin', N'arch', N'usp_Api_CheckConfigConcurrency', 1),

    (N'karch_approver', N'arch', N'usp_Api_CreateConfigChangeSet', 1),
    (N'karch_approver', N'arch', N'usp_Api_RecordConfigFieldChange', 1),
    (N'karch_approver', N'arch', N'usp_Api_FinalizeConfigChangeSet', 1);

DECLARE
    @RoleName sysname,
    @SchemaName sysname,
    @ObjectName sysname,
    @Sql nvarchar(max);

DECLARE grant_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    RoleName,
    SchemaName,
    ObjectName
FROM @Grants
WHERE OBJECT_ID(QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName), N'P') IS NOT NULL
ORDER BY
    RoleName,
    ObjectName;

OPEN grant_cursor;
FETCH NEXT FROM grant_cursor INTO @RoleName, @SchemaName, @ObjectName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql =
        N'GRANT EXECUTE ON OBJECT::' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ObjectName) +
        N' TO ' + QUOTENAME(@RoleName) + N';';

    EXEC sys.sp_executesql @Sql;

    FETCH NEXT FROM grant_cursor INTO @RoleName, @SchemaName, @ObjectName;
END;

CLOSE grant_cursor;
DEALLOCATE grant_cursor;

IF OBJECT_ID(N'arch.Process', N'U') IS NOT NULL
    GRANT SELECT ON OBJECT::[arch].[Process] TO [karch_viewer];

IF OBJECT_ID(N'arch.ProcessDatabase', N'U') IS NOT NULL
    GRANT SELECT ON OBJECT::[arch].[ProcessDatabase] TO [karch_viewer];

GRANT VIEW DEFINITION ON SCHEMA::[arch] TO [karch_viewer];

SELECT
    RoleName,
    SchemaName,
    ObjectName,
    GrantStatus =
        CASE
            WHEN OBJECT_ID(QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName), N'P') IS NULL THEN N'SKIPPED_MISSING_OBJECT'
            WHEN HAS_PERMS_BY_NAME(QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName), N'OBJECT', N'EXECUTE') = 1 THEN N'GRANTED_OR_OWNED_BY_CALLER'
            ELSE N'CHECK_ROLE_PERMISSION'
        END
FROM @Grants
ORDER BY
    RoleName,
    ObjectName;
GO
