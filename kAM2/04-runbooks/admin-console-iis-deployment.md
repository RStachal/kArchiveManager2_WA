# kAM Admin Console - IIS deployment

## Recommended topology

Deploy the Admin Console as one IIS web application:

- ASP.NET Core API hosts `/api/*` and `/health`.
- The built React frontend is served from the API `wwwroot`.
- The browser uses same-origin calls, so production CORS is not required.
- The frontend uses relative asset and API paths, so it can run as a dedicated IIS site or as a virtual application, for example `/AdminConsole`.

## Customer server prerequisites

- Windows Server with IIS enabled.
- ASP.NET Core Hosting Bundle for the API target framework `net9.0`.
- Network access from the IIS application pool identity to SQL Server.
- Deployed Admin DB objects in `kArchiveManagerAdmin`.

## Build publish package

Run from repository root. If PowerShell currently shows `C:\WINDOWS\system32`,
change directory first:

```powershell
Set-Location C:\Users\stachal\WMSArchiveManager
```

```powershell
.\legacy\ArchiveManager1.0\admin-console\publish-admin-console.ps1
```

The default output is:

```text
legacy\ArchiveManager1.0\admin-console\publish\kAM-admin-console
```

Custom output example:

```powershell
.\legacy\ArchiveManager1.0\admin-console\publish-admin-console.ps1 -OutputPath "C:\Deploy\kAM-admin-console"
```

Build + deploy to IIS path + smoke checks:

```powershell
.\legacy\ArchiveManager1.0\admin-console\publish-admin-console.ps1 `
  -DeployToIis `
  -DeployPath "C:\inetpub\kAMAdminConsole" `
  -IisAppPoolName "kAM Admin Console" `
  -RunSmoke `
  -SmokeBaseUrl "http://localhost:8089"
```

The publish output and the IIS deploy path contain `DEPLOYMENT_SUMMARY.txt`
after a successful run.

## IIS setup

1. Copy the publish folder to the customer server, for example:

```text
C:\inetpub\kArchiveManager\AdminConsole
```

2. In IIS Manager create a new site or application:

- Site name: `kAM Admin Console`
- Physical path: `C:\inetpub\kArchiveManager\AdminConsole`
- Application pool: `No Managed Code`
- App pool name: `kAM Admin Console`
- Identity: `ApplicationPoolIdentity` or a service account with scoped SQL access

3. Configure HTTPS binding with the customer certificate.

4. Set environment variables for the application.

Minimum:

```powershell
[Environment]::SetEnvironmentVariable(
  "ConnectionStrings__ArchiveManagerAdmin",
  "Server=SQLSERVER;Database=kArchiveManagerAdmin;Trusted_Connection=True;TrustServerCertificate=True;",
  "Machine"
)
```

Edit password hash:

```powershell
$password = "change-me"
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($password))
    $hash = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
    [Environment]::SetEnvironmentVariable("AdminConsole__EditPasswordSha256", $hash, "Machine")
}
finally {
    $sha256.Dispose()
}
```

Recycle the application pool after changing machine-level variables.

### IIS on a SEPARATE server from SQL (remote database) — supported

Running the Console on an IIS host that is **not** the SQL Server is fully supported and is the common
production topology. There is **no architectural problem** — the Console is a normal remote-DB web app.
Cover these four points:

1. **Connection string → the remote instance.** Set `Server=` to the remote SQL host (e.g.
   `Server=SQLSRV01\\RSTSQL2022` or, with an explicit port, `Server=sqlsrv01.domain.local,1433`).
   Keep `TrustServerCertificate=True` (the hop IIS→SQL is TLS-encrypted). Everything else unchanged.

2. **App-pool identity must authenticate to the remote SQL.** The Console connects to SQL as the
   **app-pool identity** (a fixed service identity), so with `Trusted_Connection=True`:
   - `ApplicationPoolIdentity` presents to a *remote* SQL as the IIS **machine account** `DOMAIN\IISHOST$`.
     Either grant that machine account a SQL login, **or (recommended)** set the app-pool identity to a
     **dedicated domain service account** (`DOMAIN\svc-kam-console`) and grant *that*.
   - On the SQL Server: `CREATE LOGIN [DOMAIN\svc-kam-console] FROM WINDOWS;` → user in
     `kArchiveManagerAdmin` → add to the console roles (`karch_viewer` for read; plus the write roles it
     needs — see `frontend/010`/`governance-model.md`); run `051_grant_console_read_source_dbs.sql` so the
     Dashboard can read source/archive row counts.
   - **Alternative (no domain/Kerberos):** use a **SQL login** in the connection string
     (`Server=…;User Id=kam_console;Password=…;TrustServerCertificate=True;`) if the instance allows
     mixed-mode auth. Simplest when IIS and SQL are not in the same domain.

3. **No Kerberos "double-hop".** A common worry — it does **not** apply here. The Console does **not**
   delegate the end-user's Windows identity to SQL. End-user Windows auth (the `AdminConsole:AdminUsers`
   allowlist) is **browser ↔ IIS only**; the SQL connection is always **app-pool-identity → SQL** (a
   single hop). So no constrained delegation / SPN gymnastics are needed for the database connection.
   (Standard SPNs for the SQL service still apply for Kerberos vs the app-pool service account, which is
   normal in any domain.)

4. **Network.** Enable **TCP/IP** on the SQL instance, open the instance port (1433 or the named-instance
   port) on the firewall between the IIS host and SQL, and allow **SQL Browser (UDP 1434)** if you connect
   by instance name without an explicit port.

> The **runner and SQL Agent jobs are unaffected** by where IIS lives — they run on the SQL Server. The
> cross-database archive/delete is entirely server-side; the remote Console only calls the `arch.usp_Api_*`
> procedures in `kArchiveManagerAdmin`.

### File system permissions

The app pool identity needs file permissions on the publish folder:

- Read + execute on the app root.
- Modify on `logs` folder (for startup/stdout logs if enabled).

The publish script grants:

- `IIS AppPool\<AppPoolName>` => `RX` on app root
- `IIS AppPool\<AppPoolName>` => `M` on `logs`

## Validation after deploy

Open:

```text
https://server-name/AdminConsole/health
```

If it is deployed as a dedicated site root, use:

```text
https://server-name/health
```

Expected response:

```json
{
  "service": "kAM Admin Console API",
  "status": "OK"
}
```

Then open:

```text
https://server-name/AdminConsole/
```

or, for a dedicated site root:

```text
https://server-name/
```

The UI should show `API OK / DB OK`. If it shows a database warning, verify:

- SQL server name and database in `ConnectionStrings__ArchiveManagerAdmin`
- service account SQL permissions
- required `arch.*` API procedures in `kArchiveManagerAdmin`
- SQL Server network/firewall access

The API maps SQL errors to distinct HTTP responses (T-26), so the status code tells you the cause:
- **500 `Server configuration error`** — a SQL **permission** is missing for the app-pool/runtime login (the
  exact GRANT that's missing is in the **server log only**, never the response). Fix the grant (e.g. re-run
  `deploy/v2/051` / `053`). This is the usual cause when `/health` is OK but `/api/dashboard/*` fails.
- **503 `Database is busy`** with a **`Retry-After`** header — a transient deadlock/timeout; just retry.
- **503 `Database call failed` (check ConnectionStrings)** — the DB is genuinely unreachable: verify the
  connection string, network/firewall, and that `kArchiveManagerAdmin` is online.
- **400 `Configuration change rejected`** — a business-rule rejection; the message says what to fix.

For a full customer runbook, including SQL script order, edit password hash
generation, and common IIS errors, see
`docs/admin-console-customer-deploy-runbook.md`.

## Notes

- Keep configuration secrets in IIS/environment variables, not in `appsettings.json`.
- If the frontend is hosted separately, configure `Cors:AllowedOrigins` for that origin.
- For production, replacing the shared edit password with Windows/AD role-based authorization remains recommended.
