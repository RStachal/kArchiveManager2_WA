# kAM Admin Console - Customer Deployment Runbook

This runbook is the customer-facing path for deploying the Admin Console as an
IIS web application named `kAM Admin Console`.

## Target topology

- IIS site or web application: `kAM Admin Console`
- Application pool: `kAM Admin Console`
- Physical path example: `C:\inetpub\kAMAdminConsole`
- API and frontend are deployed together. ASP.NET Core serves `/api/*`,
  `/health`, `/api/readiness`, and the React UI from `wwwroot`.
- SQL identity for integrated security:
  `IIS APPPOOL\kAM Admin Console`

## Prerequisites

- IIS installed.
- ASP.NET Core Hosting Bundle for the API target framework `net9.0`.
- SQL Server connectivity from the IIS server to `kArchiveManagerAdmin`.
- Admin DB contains the current v2 runtime objects.
- The operator has SQL rights to deploy scripts and create/grant the IIS login.

## SQL deployment order

Use the `classic-ssms` scripts when deploying manually from SSMS.

Run these after the base v2 install or current project update:

```text
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\20_update_frontend_read_api.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\21_update_frontend_lookup_validation_api.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\22_update_frontend_config_lookup_api.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\23_update_frontend_audit.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\24_update_frontend_process_write_api.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\25_update_frontend_object_write_api.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\26_update_frontend_enable_disable_api.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\27_update_frontend_run_profile_write_api.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\28_update_frontend_advanced_config_write_api.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\29_update_frontend_security_roles.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\30_frontend_api_readiness_check.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\33_update_frontend_concurrency_metadata.sql
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\32_update_frontend_iis_principal_permissions.sql
```

If the customer uses the WA/AAD smoke configuration, also review:

```text
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\31_seed_wa_aad_smoke_config.sql
```

## SQL permissions

Do not grant `sysadmin` to the IIS app pool account.

Run:

```text
legacy\ArchiveManager1.0\deploy\v2\classic-ssms\32_update_frontend_iis_principal_permissions.sql
```

Default principal:

```text
IIS APPPOOL\kAM Admin Console
```

The script grants the frontend roles and effective `EXECUTE` access needed by
the API. It also supports advanced-admin permissions for ProcessKeySpec and
IndexRequirement edits.

Verify with:

```text
legacy\ArchiveManager1.0\deploy\v2\smoke-tests\28_frontend_api_readiness_smoke.sql
legacy\ArchiveManager1.0\deploy\v2\smoke-tests\30_frontend_iis_principal_permissions_smoke.sql
```

## Publish and deploy

Run PowerShell from the repository root, not from `C:\WINDOWS\system32`:

```powershell
Set-Location C:\Users\stachal\WMSArchiveManager

.\legacy\ArchiveManager1.0\admin-console\publish-admin-console.ps1 `
  -DeployToIis `
  -DeployPath "C:\inetpub\kAMAdminConsole" `
  -IisAppPoolName "kAM Admin Console" `
  -RunSmoke `
  -SmokeBaseUrl "http://localhost:8089"
```

The script builds the frontend, publishes the API, mirrors the package to IIS,
grants file permissions, restarts the app pool, and checks `/health` and
`/api/readiness`.

If you run the command from the script folder instead:

```powershell
Set-Location C:\Users\stachal\WMSArchiveManager\legacy\ArchiveManager1.0\admin-console
.\publish-admin-console.ps1 -DeployToIis -DeployPath "C:\inetpub\kAMAdminConsole" -IisAppPoolName "kAM Admin Console"
```

## IIS settings

Application pool:

- Name: `kAM Admin Console`
- .NET CLR version: `No Managed Code`
- Managed pipeline mode: `Integrated`
- Identity: `ApplicationPoolIdentity` or an approved domain service account

File permissions:

- App root: read and execute for `IIS AppPool\kAM Admin Console`
- `logs` folder: modify for `IIS AppPool\kAM Admin Console`

Minimum environment variables:

```powershell
[Environment]::SetEnvironmentVariable(
  "ConnectionStrings__ArchiveManagerAdmin",
  "Server=SQLSERVER;Database=kArchiveManagerAdmin;Trusted_Connection=True;TrustServerCertificate=True;",
  "Machine"
)
```

> **TLS note:** `TrustServerCertificate=True` disables validation of the SQL Server certificate and is
> acceptable **only** when the API and SQL Server are on the same host (loopback). When they are on
> separate hosts, prefer `Encrypt=True` with a properly trusted/installed certificate (omit
> `TrustServerCertificate`) so the API↔SQL channel is protected against man-in-the-middle.

Generate the edit-password hash with the **built-in `hash-password` CLI**, which produces a salted
PBKDF2-HMAC-SHA256 hash (do **not** use a plain SHA-256 — unsalted SHA-256 is offline-crackable and is
only accepted for backward compatibility):

```powershell
# From the deployed app folder (uses the published DLL):
dotnet KArchiveManager.AdminConsole.Api.dll hash-password "change-me"
# …or from source: dotnet run --project <ApiProject> -- hash-password "change-me"

# Copy the printed "PBKDF2-SHA256$...$...$..." value into the env var (or appsettings):
[Environment]::SetEnvironmentVariable("AdminConsole__EditPasswordSha256", "<paste-PBKDF2-hash>", "Machine")
```

Use the same `hash-password` output for every `AdminConsole:Operators[].PasswordSha256` entry. The
shared `EditPasswordSha256` is a fallback — prefer named Windows users (`AdminConsole:AdminUsers`) or
named `Operators` so every change is attributable to a person in the audit trail.

Recycle the app pool after changing machine-level variables.

## Expected web.config

The generated `web.config` must contain exactly one `<configuration>` root and
one `<aspNetCore ... />` element inside it:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <location path="." inheritInChildApplications="false">
    <system.webServer>
      <handlers>
        <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
      </handlers>
      <aspNetCore processPath="dotnet" arguments=".\KArchiveManager.AdminConsole.Api.dll" stdoutLogEnabled="false" stdoutLogFile=".\logs\stdout" hostingModel="inprocess" />
    </system.webServer>
  </location>
</configuration>
```

Do not append a second `<aspNetCore ... />` line after `</configuration>`.

## Verification

Open:

```text
http://localhost:8089/health
http://localhost:8089/api/readiness
http://localhost:8089/
```

Expected:

- `/health` returns `status: OK`.
- `/api/readiness` returns `apiOk: true`, `databaseOk: true`,
  `missingObjects: []`, and `missingRoles: []`.
- UI header shows `API OK / DB OK`.
- Dashboard and RF/L charts return data according to configured processes,
  source databases, archive schemas, and run history.

## Troubleshooting

`The term ... publish-admin-console.ps1 is not recognized`

- You are probably in `C:\WINDOWS\system32`.
- Run `Set-Location C:\Users\stachal\WMSArchiveManager` first, or use the full
  script path.

HTTP 500.19, invalid XML

- `web.config` has malformed XML.
- Remove any extra `<aspNetCore ... />` outside `<configuration>`.

HTTP 500.30, app failed to start

- Check `C:\inetpub\kAMAdminConsole\logs\stdout_*.log` if stdout logging is
  enabled.
- Confirm the ASP.NET Core Hosting Bundle is installed.
- Confirm environment variables are visible to IIS and recycle the app pool.

`/health` is OK but dashboard says `Check ConnectionStrings...`

- The API is running, but a database procedure call failed.
- Open `/api/readiness`.
- If readiness is OK, check endpoint-specific SQL rights and SQL errors.
- If readiness reports missing permissions, run script `32`.
- If readiness reports missing objects, rerun frontend scripts `20` through
  `30` and `33`.

Port is already used

- Change IIS binding or stop the other site using the same port.

Dashboard/RF-L data looks incomplete

- Verify process mappings in Configuration.
- Verify archive schema names match the configured source DB display names.
- Verify source/archive object existence in Validation.
- For tables without a completed run, RF/L charts show current source/archive
  counts, but run-history charts show `No run yet`.
