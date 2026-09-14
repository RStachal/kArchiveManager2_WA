/*
Frontend concurrency metadata update.

Installs the optimistic-concurrency support the Admin Console uses to protect ObjectSpec edits:
the ObjectSpec CreatedAt/ModifiedAt columns + ModifiedAt trigger (idempotent), and the
arch.usp_Api_CheckConfigConcurrency procedure.

The v_ObjectSpecDatabaseEffective VIEW that projects these columns is owned SOLELY by
kArchiveManagerAdmin\v2\022_effective_database_overrides.sql. This script intentionally does NOT
re-create that view: doing so once shipped an older column list that dropped the cheap-mode
CandidateSelectExpr column and broke the TIMESTAMP runner. On an existing environment, (re-)run
022 to refresh the view with the ModifiedAt columns.
*/

PRINT 'kArchiveManager frontend concurrency metadata update started.';
GO

USE [kArchiveManagerAdmin]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF COL_LENGTH(N'arch.ObjectSpec', N'CreatedAt') IS NULL
BEGIN
    ALTER TABLE [arch].[ObjectSpec]
    ADD [CreatedAt] datetime2(0) NOT NULL
        CONSTRAINT [DF_ObjectSpec_CreatedAt] DEFAULT (sysutcdatetime()) WITH VALUES;
END
GO

IF COL_LENGTH(N'arch.ObjectSpec', N'ModifiedAt') IS NULL
BEGIN
    ALTER TABLE [arch].[ObjectSpec]
    ADD [ModifiedAt] datetime2(0) NOT NULL
        CONSTRAINT [DF_ObjectSpec_ModifiedAt] DEFAULT (sysutcdatetime()) WITH VALUES;
END
GO

CREATE OR ALTER TRIGGER [arch].[tr_ObjectSpec_SetModifiedAt]
ON [arch].[ObjectSpec]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF TRIGGER_NESTLEVEL() > 1
        RETURN;

    UPDATE os
    SET ModifiedAt = CONVERT(datetime2(0), sysutcdatetime())
    FROM [arch].[ObjectSpec] AS os
    JOIN inserted AS i
      ON i.ObjectSpecId = os.ObjectSpecId;
END
GO

-- NOTE: v_ObjectSpecDatabaseEffective is created by v2/022 (single source of truth) and projects the
-- ObjectSpec ModifiedAt columns added above. This script does NOT re-create the view — see header.

CREATE OR ALTER PROCEDURE [arch].[usp_Api_CheckConfigConcurrency]
    @EntityType nvarchar(80),
    @ExpectedModifiedAt datetime2(0),
    @ProcessCode sysname = NULL,
    @ProcessDatabaseId int = NULL,
    @SourceDb sysname = NULL,
    @ArchiveDb sysname = NULL,
    @ObjectSpecId int = NULL,
    @ObjectSpecDatabaseOverrideId int = NULL,
    @RunProfileId int = NULL,
    @ProcessKeySpecId int = NULL,
    @IndexRequirementId int = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentModifiedAt datetime2(0);

    IF @ExpectedModifiedAt IS NULL
    BEGIN
        SELECT State = 0, CurrentModifiedAt = CONVERT(datetime2(0), NULL);
        RETURN;
    END;

    IF @EntityType = N'Process'
    BEGIN
        SELECT @CurrentModifiedAt = ModifiedAt
        FROM arch.Process
        WHERE ProcessCode = @ProcessCode;
    END
    ELSE IF @EntityType = N'ProcessDatabase'
    BEGIN
        SELECT TOP (1) @CurrentModifiedAt = pd.ModifiedAt
        FROM arch.ProcessDatabase pd
        JOIN arch.Process p
          ON p.ProcessId = pd.ProcessId
        WHERE (@ProcessDatabaseId IS NOT NULL AND pd.ProcessDatabaseId = @ProcessDatabaseId)
           OR (@ProcessDatabaseId IS NULL AND p.ProcessCode = @ProcessCode AND pd.SourceDb = @SourceDb AND pd.ArchiveDb = @ArchiveDb);
    END
    ELSE IF @EntityType = N'ObjectSpec'
    BEGIN
        SELECT @CurrentModifiedAt = ModifiedAt
        FROM arch.ObjectSpec
        WHERE ObjectSpecId = @ObjectSpecId;
    END
    ELSE IF @EntityType = N'ObjectSpecDatabaseOverride'
    BEGIN
        IF @ObjectSpecDatabaseOverrideId IS NULL
            SET @CurrentModifiedAt = @ExpectedModifiedAt;
        ELSE
            SELECT @CurrentModifiedAt = ModifiedAt
            FROM arch.ObjectSpecDatabaseOverride
            WHERE ObjectSpecDatabaseOverrideId = @ObjectSpecDatabaseOverrideId;
    END
    ELSE IF @EntityType = N'RunProfile'
    BEGIN
        SELECT @CurrentModifiedAt = ModifiedAt
        FROM arch.RunProfile
        WHERE RunProfileId = @RunProfileId;
    END
    ELSE IF @EntityType = N'ProcessKeySpec'
    BEGIN
        SELECT @CurrentModifiedAt = ModifiedAt
        FROM arch.ProcessKeySpec
        WHERE ProcessKeySpecId = @ProcessKeySpecId;
    END
    ELSE IF @EntityType = N'IndexRequirement'
    BEGIN
        SELECT @CurrentModifiedAt = ModifiedAt
        FROM arch.IndexRequirement
        WHERE IndexRequirementId = @IndexRequirementId;
    END
    ELSE
        THROW 57600, 'Unsupported concurrency entity type.', 1;

    SELECT
        State = CASE
            WHEN @CurrentModifiedAt IS NULL THEN 404
            WHEN CONVERT(datetime2(0), @CurrentModifiedAt) = CONVERT(datetime2(0), @ExpectedModifiedAt) THEN 0
            ELSE 409
        END,
        CurrentModifiedAt = @CurrentModifiedAt;
END
GO

IF DATABASE_PRINCIPAL_ID(N'karch_config_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Api_CheckConfigConcurrency] TO [karch_config_admin];
GO

IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Api_CheckConfigConcurrency] TO [karch_advanced_admin];
GO

SELECT
    ViewName = N'arch.v_ObjectSpecDatabaseEffective',
    HasObjectSpecModifiedAt =
        CONVERT(bit, CASE WHEN COL_LENGTH(N'arch.v_ObjectSpecDatabaseEffective', N'ObjectSpecModifiedAt') IS NULL THEN 0 ELSE 1 END),
    HasObjectSpecOverrideModifiedAt =
        CONVERT(bit, CASE WHEN COL_LENGTH(N'arch.v_ObjectSpecDatabaseEffective', N'ObjectSpecOverrideModifiedAt') IS NULL THEN 0 ELSE 1 END),
    ObjectSpecModifiedAtTriggerId = OBJECT_ID(N'arch.tr_ObjectSpec_SetModifiedAt', N'TR'),
    CheckProcedureId = OBJECT_ID(N'arch.usp_Api_CheckConfigConcurrency', N'P');
GO

PRINT 'kArchiveManager frontend concurrency metadata update completed.';
GO
