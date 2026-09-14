# Admin Console on this deployment

The Admin Console is the web UI for kArchiveManager 2.0 — dashboard, configuration,
validation, run history, document lookup and the go-live gate. It ships in the
customer handover package as an IIS application:

```
kArchiveManager-2.0-handover-2026-07-14.zip
  └── 02-admin-console/
      ├── app/                        the published ASP.NET Core app (46 files)
      ├── appsettings.sample.json
      └── publish-admin-console.ps1
```

This file records what happened when that package was put against **this**
deployment, because three things in it do not match what its own documentation
says. The authoritative procedure remains
`04-runbooks/admin-console-iis-deployment.md` in the handover; read this first,
then follow that.

---

## Verified: the console works against this configuration

Run with Kestrel directly (`dotnet KArchiveManager.AdminConsole.Api.dll`) against
`kArchiveManagerAdmin` on this instance:

| Check | Result |
|---|---|
| `/health` | `status: OK` |
| `/api/readiness` | `databaseOk: true`, `processCount: 6`, `mappingCount: 6` |
| required objects / roles / EXECUTE | `33/33`, `4/4`, `33/33` — **nothing missing** |
| `/api/dashboard/process-config` | HTTP 200 |
| `/api/dashboard/process-summary` | HTTP 200 — all six sets with correct source/archive counts |
| `/api/dashboard/table-counts` | HTTP 200 |
| `/api/golive-readiness` | HTTP 200 |
| `/api/runs/recent` | HTTP 200 |

So the database side of this deployment is already complete for the console — the
core bundle created every object, role and grant it needs. Nothing in `01-database`
has to be re-run for it.

---

## Three corrections to the shipped package

### 1. The app cannot open a SQL connection as published — BLOCKING

```
System.DllNotFoundException: Unable to load DLL 'Microsoft.Data.SqlClient.SNI.dll'
   at Interop.Windows.Sni.SniNativeMethods.UnmanagedIsTokenRestricted(...)
   at Microsoft.Data.SqlClient.SqlConnection.InternalOpenAsync(...)
```

`/api/readiness` returns `databaseOk: false` and the console is unusable.

The file **is** in the package, at
`app/runtimes/win-x64/native/Microsoft.Data.SqlClient.SNI.dll`. The problem is that
`KArchiveManager.AdminConsole.Api.deps.json` declares only the *managed* runtime
assets —

```
runtimes/unix/lib/net8.0/Microsoft.Data.SqlClient.dll
runtimes/win/lib/net8.0/Microsoft.Data.SqlClient.dll
```

— and **no native asset at all**. The .NET host resolves native libraries through
`deps.json`, so it never probes `runtimes/win-x64/native/`. This is a
RID-agnostic (portable) publish; `Microsoft.Data.SqlClient` 7.0.1 on Windows with
`Trusted_Connection=True` needs the native SNI.

**Fix, verified on this instance** — copy the native DLL to the application root,
which the host probes directly:

```powershell
Copy-Item "<app>\runtimes\win-x64\native\Microsoft.Data.SqlClient.SNI.dll" "<app>\"
```

After that, `databaseOk: true`. Do this **every time the app folder is
redeployed** — or, better, have the build republish with `-r win-x64` so the RID
assets land correctly and this step disappears.

### 2. `KArchiveManager.AdminConsole.Api.exe` does not exist in the package

Add-on `064_console_default_operator.sql` instructs:

> run `KArchiveManager.AdminConsole.Api.exe hash-password "<password>"`

and throws `50512` with the same text if the hash is not filled in. There is no
`.exe` anywhere in the handover — the publish is portable, so the entry point is
the DLL. Use:

```powershell
dotnet KArchiveManager.AdminConsole.Api.dll hash-password "<password>"
# -> PBKDF2-SHA256$100000$<salt>$<hash>
```

Verified working. Paste that value into `064` in place of `CHANGE-ME`.

### 3. The target framework is `net10.0`, not 8 or 9

| Source | Says |
|---|---|
| handover `README.md` | "ASP.NET Core Hosting Bundle (.NET 8/9 runtime)" |
| `04-runbooks/admin-console-iis-deployment.md` | "Hosting Bundle for the API target framework `net9.0`" |
| `app/KArchiveManager.AdminConsole.Api.runtimeconfig.json` | **`net10.0`**, `Microsoft.AspNetCore.App 10.0.0` |

Install the **.NET 10** Hosting Bundle. An 8 or 9 bundle will not start the app.

---

## What is still missing on this server

Checked on the reference instance:

| Prerequisite | State | Needed for |
|---|---|---|
| IIS (`W3SVC`) | **running** | — |
| .NET 10 runtime + ASP.NET Core 10 | **installed** | matches `net10.0` |
| **ASP.NET Core Module V2 for IIS** | **MISSING** | IIS hosting — `web.config` references `AspNetCoreModuleV2` |
| IIS app-pool login in SQL | **not created** | `051` cannot run without it |
| `arch.ConsoleOperator` rows | **0** | nobody can log in to edit |

Only *IIS Express*' copy of the module is installed
(`Microsoft ASP.NET Core Module V2 for IIS Express`); `aspnetcorev2.dll` is not in
`C:\Windows\System32\inetsrv` and is not registered in `applicationHost.config`.

**Installing the Hosting Bundle is a machine-level change that needs a download and
a restart of IIS, so it is left for whoever owns this server.** Until then the
console can only be run with Kestrel, which is how the verification above was done.

---

## Deployment order

1. **Install the ASP.NET Core 10 Hosting Bundle**, then `iisreset`.
2. Copy `02-admin-console/app` to e.g. `C:\inetpub\kArchiveManager\AdminConsole`.
3. **Apply correction 1** — copy the native SNI DLL to the app root.
4. Create the IIS site/application: app pool `kAM Admin Console`, **No Managed
   Code**, identity `ApplicationPoolIdentity` (or a domain service account).
5. Edit `app/appsettings.json` — set
   `ConnectionStrings:ArchiveManagerAdmin` to this instance. Leave
   `DbOperatorsEnabled: true`, `WindowsAuthEnabled: false`,
   `EditPasswordSha256: ""` — DB-managed operators are the current auth model.
   (The IIS runbook's environment-variable/`EditPasswordSha256` route is the older
   fallback model; it still works but is not the default any more.)
6. Create the app-pool login in SQL and add it to `karch_viewer` (plus the write
   roles it needs — see `03-docs/governance-model.md`).
7. Run **`051_grant_console_read_source_dbs.sql`** with
   `@ConsoleLogin = N'IIS APPPOOL\kAM Admin Console'` and
   `@DbsCsv = N'AAD,ADV,kArchiveManagerBackups'`. Without it the dashboard returns
   503 on the movement panels — a masked `Msg 916`.
8. Generate the password hash (correction 2), paste it into
   **`064_console_default_operator.sql`**, run it. Without an enabled operator the
   console starts and reads work, but Configuration / Validation / Go-live cannot
   be edited by anyone.
9. Verify: top-bar badge **API OK / DB OK**, dashboard loads, `/api/readiness`
   shows `databaseOk: true` and the expected `processCount`.
10. Disable the default `admin` operator once real operators exist.

### Optional add-ons

- `065_grant_console_restore_source_insert.sql` — **off by design.** Restore is the
  one operation that writes back into a production source, so the console's
  dry-run preview works but a real restore returns `INSERT permission denied`
  unless a DBA runs `arch.usp_RestoreFromArchive` directly, or `065` is applied.
  Applying it is a deliberate privilege expansion.
- `058` / `059` — Agent job control from the console.
- `066` — legal-hold panel.

---

## Relationship to this package's own documents

The handover is the product; this package is its configuration for Koerber
Warehouse Advantage. Where they overlap, prefer the handover:

| Topic | Authoritative source |
|---|---|
| Product deployment, end to end | handover `04-runbooks/customer-deploy-guide.md` |
| Admin Console on IIS | handover `04-runbooks/admin-console-iis-deployment.md` **plus the three corrections above** |
| The six WA document sets, their keys, cutoffs and gates | this package — `README.md` |
| Deploying *those sets* at a customer | this package — `DEPLOYMENT.md` |
| Reporting layer vs the SSRS dashboard | this package — `reports/README.md` |
