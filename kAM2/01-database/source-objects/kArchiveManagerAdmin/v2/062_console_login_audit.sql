/* ============================================================================
 * 062 — Console login audit
 * ----------------------------------------------------------------------------
 * Records Admin Console edit-unlock logins (success + failure) so the Config
 * view can show "who logged in and when". Purely additive: no existing auth
 * path changes, and recording is best-effort at the API layer (a DB outage
 * never blocks login). Mirrors the role-grant pattern of 061 (console operators).
 * ============================================================================ */
SET NOCOUNT ON; SET XACT_ABORT ON; SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
USE [kArchiveManagerAdmin];
GO

IF OBJECT_ID(N'arch.ConsoleLoginAudit', N'U') IS NULL
BEGIN
    CREATE TABLE arch.ConsoleLoginAudit
    (
        LoginId         bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ConsoleLoginAudit PRIMARY KEY,
        Username        nvarchar(256)  NULL,           -- resolved operator / "(shared password)"
        WindowsIdentity nvarchar(256)  NULL,           -- HttpContext.User identity, if present
        Source          nvarchar(20)   NOT NULL,       -- shared | operator | windows
        Success         bit            NOT NULL,
        FailureReason   nvarchar(200)  NULL,
        Ip              nvarchar(45)   NULL,
        LoginAtUtc      datetime2(0)   NOT NULL
            CONSTRAINT DF_ConsoleLoginAudit_At DEFAULT (SYSUTCDATETIME())
    );
    CREATE NONCLUSTERED INDEX IX_ConsoleLoginAudit_At   ON arch.ConsoleLoginAudit (LoginAtUtc DESC);
    CREATE NONCLUSTERED INDEX IX_ConsoleLoginAudit_User ON arch.ConsoleLoginAudit (Username, LoginAtUtc DESC);
END
GO

/* Record one login attempt. Called best-effort from the unlock endpoint. */
CREATE OR ALTER PROCEDURE arch.usp_Api_RecordConsoleLogin
    @Username        nvarchar(256) = NULL,
    @WindowsIdentity nvarchar(256) = NULL,
    @Source          nvarchar(20),
    @Success         bit,
    @FailureReason   nvarchar(200) = NULL,
    @Ip              nvarchar(45)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT arch.ConsoleLoginAudit (Username, WindowsIdentity, Source, Success, FailureReason, Ip)
    VALUES (NULLIF(LTRIM(RTRIM(@Username)), N''), NULLIF(LTRIM(RTRIM(@WindowsIdentity)), N''),
            @Source, @Success, NULLIF(LTRIM(RTRIM(@FailureReason)), N''), NULLIF(LTRIM(RTRIM(@Ip)), N''));
END
GO

/* Most recent login attempts, newest first (top of the list = last login). */
CREATE OR ALTER PROCEDURE arch.usp_Api_GetConsoleLastLogins
    @Top int = 20
AS
BEGIN
    SET NOCOUNT ON;
    SET @Top = CASE WHEN @Top IS NULL OR @Top < 1 THEN 20 WHEN @Top > 200 THEN 200 ELSE @Top END;
    SELECT TOP (@Top)
        Username = ISNULL(Username, N'(shared password)'),
        WindowsIdentity,
        Source,
        Success,
        FailureReason,
        Ip,
        LoginAtUtc
    FROM arch.ConsoleLoginAudit
    ORDER BY LoginAtUtc DESC, LoginId DESC;
END
GO

/* Grants — the Admin Console app login holds these roles (same as 061). */
BEGIN TRY
    IF DATABASE_PRINCIPAL_ID('karch_config_admin') IS NOT NULL
    BEGIN
        GRANT EXECUTE ON arch.usp_Api_RecordConsoleLogin   TO karch_config_admin;
        GRANT EXECUTE ON arch.usp_Api_GetConsoleLastLogins TO karch_config_admin;
    END
    IF DATABASE_PRINCIPAL_ID('karch_advanced_admin') IS NOT NULL
    BEGIN
        GRANT EXECUTE ON arch.usp_Api_RecordConsoleLogin   TO karch_advanced_admin;
        GRANT EXECUTE ON arch.usp_Api_GetConsoleLastLogins TO karch_advanced_admin;
    END
END TRY BEGIN CATCH END CATCH;
GO

PRINT '062 console login audit installed (arch.ConsoleLoginAudit + record/get procs).';
GO
