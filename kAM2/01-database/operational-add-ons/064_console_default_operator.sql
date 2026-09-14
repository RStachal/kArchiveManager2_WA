/* ============================================================================
   064_console_default_operator.sql — seed the "sa-like" default Admin Console operator.
   ----------------------------------------------------------------------------
   The DB-operator auth model (see 061) needs at least ONE enabled operator or nobody can log
   in to Configuration / Validation / Go-live. This seeds a single default account — think of it
   as SQL Server's 'sa': a bootstrap login you use to create the real operators, then DISABLE.

   PARAMETERIZED TEMPLATE (fail-fast, like the 053/054/048 connection templates):
     1. Generate a hash for your chosen password with the shipped CLI:
            KArchiveManager.AdminConsole.Api.exe hash-password "<your-strong-password>"
        (prints a PBKDF2-SHA256$... string)
     2. Paste it into @PasswordSha256 below, replacing 'CHANGE-ME'.
     3. Run this script. It refuses to run while the placeholder is unchanged, and it will NOT
        clobber an existing setup (only seeds when arch.ConsoleOperator is empty).

   After go-live: create your own named operators in the console, then disable this default
   ('admin') from the operators panel. Idempotent + safe to re-run. Error band 50510+.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @Username       nvarchar(128) = N'admin';
DECLARE @DisplayName    nvarchar(200) = N'Default admin (sa-like — disable once real operators exist)';
DECLARE @PasswordSha256 nvarchar(400) = N'CHANGE-ME';   -- <-- paste hash-password output here

IF @PasswordSha256 = N'CHANGE-ME' OR NULLIF(LTRIM(RTRIM(@PasswordSha256)), N'') IS NULL
    THROW 50512, 'Set @PasswordSha256 first: run "KArchiveManager.AdminConsole.Api.exe hash-password ""<password>""" and paste the PBKDF2-SHA256$... value into 064_console_default_operator.sql, replacing CHANGE-ME.', 1;

-- Basic hash-format guard so a mis-pasted value fails here, not silently at every login attempt.
IF @PasswordSha256 NOT LIKE N'PBKDF2-SHA256$%$%$%'
   AND @PasswordSha256 NOT LIKE N'[0-9a-fA-F]%'   -- allow legacy 64-hex SHA-256
    THROW 50513, 'Malformed @PasswordSha256. Expected a PBKDF2-SHA256$iters$salt$hash value from the hash-password CLI (or a 64-hex legacy SHA-256).', 1;

IF NOT EXISTS (SELECT 1 FROM arch.ConsoleOperator)
BEGIN
    -- Seed via the upsert proc so any future validation there applies uniformly. Elevated=1 so the
    -- default can operate Go-live (the elevated surface) during initial setup.
    EXEC arch.usp_Api_SaveConsoleOperator
        @Username    = @Username,
        @DisplayName = @DisplayName,
        @PasswordSha256 = @PasswordSha256,
        @IsEnabled   = 1,
        @IsElevated  = 1,
        @RequestedBy = N'064_seed';
    PRINT 'Default operator ''admin'' seeded (enabled, elevated). Change its password / disable it after creating real operators.';
END
ELSE
    PRINT 'arch.ConsoleOperator already populated — default operator seed skipped (no clobber).';
GO
