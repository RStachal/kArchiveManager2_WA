/* ============================================================================
   061_console_operators.sql — DB-managed Admin Console operators (arch.ConsoleOperator).
   ----------------------------------------------------------------------------
   Moves Admin Console operator credentials from appsettings into the control DB so they can be
   managed from the Console (add/edit/disable, set password) without an app-pool recycle. The API
   verifies the submitted password against the stored PBKDF2 hash SERVER-SIDE; the hash is returned
   only to the API auth path (usp_Api_GetConsoleOperatorForAuth, granted to the config/advanced admin
   roles the app login holds). appsettings Operators + the shared EditPasswordSha256 remain as a
   bootstrap/fallback (used first, and the only way in if the DB is unreachable).
   Idempotent. Error codes use the free 50510+ band. Read/manage granted to karch_config_admin.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'arch.ConsoleOperator', N'U') IS NULL
BEGIN
    CREATE TABLE arch.ConsoleOperator
    (
        OperatorId     int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ConsoleOperator PRIMARY KEY,
        Username       nvarchar(128)     NOT NULL CONSTRAINT UQ_ConsoleOperator_Username UNIQUE,
        DisplayName    nvarchar(200)     NULL,
        PasswordSha256 nvarchar(400)     NOT NULL,   -- PBKDF2-SHA256$iters$salt$hash (or legacy 64-hex)
        IsEnabled      bit               NOT NULL CONSTRAINT DF_ConsoleOperator_IsEnabled DEFAULT(1),
        IsElevated     bit               NOT NULL CONSTRAINT DF_ConsoleOperator_IsElevated DEFAULT(0),
        CreatedAt      datetime2(0)      NOT NULL CONSTRAINT DF_ConsoleOperator_CreatedAt DEFAULT(sysutcdatetime()),
        ModifiedAt     datetime2(0)      NOT NULL CONSTRAINT DF_ConsoleOperator_ModifiedAt DEFAULT(sysutcdatetime())
    );
    PRINT 'arch.ConsoleOperator created.';
END
GO

-- AUTH path: returns the stored hash + flags for ONE enabled operator. Sensitive (returns the hash) —
-- granted only to the config/advanced admin roles the app login holds, never to viewer.
CREATE OR ALTER PROCEDURE arch.usp_Api_GetConsoleOperatorForAuth
    @Username nvarchar(128)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) Username, DisplayName, PasswordSha256, IsEnabled, IsElevated
    FROM arch.ConsoleOperator
    WHERE Username = @Username AND IsEnabled = 1;
END
GO

-- Management LIST: never returns password hashes.
CREATE OR ALTER PROCEDURE arch.usp_Api_ListConsoleOperators
AS
BEGIN
    SET NOCOUNT ON;
    SELECT OperatorId, Username, DisplayName, IsEnabled, IsElevated, CreatedAt, ModifiedAt
    FROM arch.ConsoleOperator
    ORDER BY Username;
END
GO

-- Upsert an operator. @PasswordSha256 is the PBKDF2 hash the API computed from the typed password;
-- NULL on update keeps the current password (so you can edit flags without resetting the password).
CREATE OR ALTER PROCEDURE arch.usp_Api_SaveConsoleOperator
    @Username nvarchar(128),
    @DisplayName nvarchar(200) = NULL,
    @PasswordSha256 nvarchar(400) = NULL,
    @IsEnabled bit = 1,
    @IsElevated bit = 0,
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Username = NULLIF(LTRIM(RTRIM(@Username)), N'');
    SET @DisplayName = NULLIF(LTRIM(RTRIM(@DisplayName)), N'');
    SET @PasswordSha256 = NULLIF(LTRIM(RTRIM(@PasswordSha256)), N'');

    IF @Username IS NULL
        THROW 50510, 'Username is required.', 1;

    IF EXISTS (SELECT 1 FROM arch.ConsoleOperator WHERE Username = @Username)
    BEGIN
        UPDATE arch.ConsoleOperator
        SET DisplayName = @DisplayName,
            PasswordSha256 = COALESCE(@PasswordSha256, PasswordSha256),
            IsEnabled = @IsEnabled,
            IsElevated = @IsElevated,
            ModifiedAt = sysutcdatetime()
        WHERE Username = @Username;
    END
    ELSE
    BEGIN
        IF @PasswordSha256 IS NULL
            THROW 50511, 'A password is required when creating a new operator.', 1;
        INSERT arch.ConsoleOperator (Username, DisplayName, PasswordSha256, IsEnabled, IsElevated)
        VALUES (@Username, @DisplayName, @PasswordSha256, @IsEnabled, @IsElevated);
    END

    EXEC arch.usp_Api_ListConsoleOperators;
END
GO

CREATE OR ALTER PROCEDURE arch.usp_Api_DeleteConsoleOperator
    @Username nvarchar(128),
    @RequestedBy nvarchar(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM arch.ConsoleOperator WHERE Username = @Username;
    EXEC arch.usp_Api_ListConsoleOperators;
END
GO

IF DATABASE_PRINCIPAL_ID(N'karch_config_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON arch.usp_Api_GetConsoleOperatorForAuth TO karch_config_admin;
    GRANT EXECUTE ON arch.usp_Api_ListConsoleOperators TO karch_config_admin;
    GRANT EXECUTE ON arch.usp_Api_SaveConsoleOperator TO karch_config_admin;
    GRANT EXECUTE ON arch.usp_Api_DeleteConsoleOperator TO karch_config_admin;
END;
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON arch.usp_Api_GetConsoleOperatorForAuth TO karch_advanced_admin;
    GRANT EXECUTE ON arch.usp_Api_ListConsoleOperators TO karch_advanced_admin;
    GRANT EXECUTE ON arch.usp_Api_SaveConsoleOperator TO karch_advanced_admin;
    GRANT EXECUTE ON arch.usp_Api_DeleteConsoleOperator TO karch_advanced_admin;
END;
GO
PRINT 'arch.ConsoleOperator API installed (GetForAuth / List / Save / Delete).';
GO
