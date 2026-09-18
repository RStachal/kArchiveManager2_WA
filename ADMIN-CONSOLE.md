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

It is **deployed and running on this server**:

| | |
|---|---|
| Address | `http://localhost:8089` (site listens on `0.0.0.0:8089`) |
| Path | `C:\inetpub\kArchiveManager\AdminConsole` |
| App pool | `kAM Admin Console` — No Managed Code, `ApplicationPoolIdentity` |
| SQL identity | `IIS APPPOOL\kAM Admin Console` |
| Operator | `admin` (DB-managed, `IsElevated = 1`) |

Reaching it from another machine additionally needs an inbound firewall rule —
see *Remote access* at the end. It is deliberately **not** open yet.

This file records what the handover package needed before it would actually run,
because eight things in it do not match its own documentation. The authoritative
procedure remains `04-runbooks/admin-console-iis-deployment.md`; read this first,
then follow that.

---

## Verified against this configuration

Every endpoint below was called over **IIS**, as the app-pool identity — not with
Kestrel as a sysadmin, which is a far weaker test and hides every permission
problem in the next section.

| Check | Result |
|---|---|
| `/health` | `status: OK` |
| `/api/readiness` | `databaseOk: true`, `processCount: 6`, `mappingCount: 6` |
| required objects / roles / EXECUTE | `33/33`, `4/4`, `33/33` — nothing missing |
| `/api/dashboard/process-config` | 200 |
| `/api/dashboard/process-summary` | 200 — all six sets, correct source/archive counts |
| `/api/dashboard/table-counts` | 200 |
| `/api/runs/recent` | 200 |
| `/api/golive-readiness` | 200 — **0 blockers**, 1 warning |
| `/api/jobs` | 200 — both kAM jobs with schedule state |
| `/api/security/status` | `isConfigured: true`, `operatorsConfigured: true` |
| `/api/security/unlock` | 200 — edit token issued for operator `admin` |
| `/api/operators`, `/api/security/access`, `/api/security/last-logins` | 200 with the token |
| `/api/legal-holds`, `/api/estimates` | 200 |
| `POST /api/validation/configuration` | 200 — returns findings |
| `/` (SPA) | 200, `index.html` + assets served |

The one go-live warning is `047_operational_alerting` (Database Mail, operator,
job failure notification). Not applied here by decision — this is a presentation
environment with no SMTP. On a customer system it must be applied.

`GET /api/config/processes` and `GET /api/validation/configuration` return 404.
That is **not** a defect: both are POST-only in this build. The SPA calls them
with a payload.

---

## Eight corrections to the shipped package

### 1. The native SQL driver is not resolved — BLOCKING

```
System.DllNotFoundException: Unable to load DLL 'Microsoft.Data.SqlClient.SNI.dll'
   at Interop.Windows.Sni.SniNativeMethods.UnmanagedIsTokenRestricted(...)
   at Microsoft.Data.SqlClient.SqlConnection.InternalOpenAsync(...)
```

`/api/readiness` returns `databaseOk: false` and the console is unusable.

The file **is** in the package, at
`app/runtimes/win-x64/native/Microsoft.Data.SqlClient.SNI.dll`. The problem is that
`KArchiveManager.AdminConsole.Api.deps.json` declares only the *managed* runtime
assets and **no native asset at all**, so the .NET host never probes that folder.
This is a RID-agnostic (portable) publish; `Microsoft.Data.SqlClient` on Windows
with `Trusted_Connection=True` needs the native SNI.

**Copying the DLL to the application root is not enough under IIS.** It works
under Kestrel, and that is how the earlier revision of this document described the
fix — but the in-process IIS worker still threw `DllNotFoundException` with the
app-root copy already present (stdout log `stdout_20260914115722`, copy made 11
minutes earlier). The exception only disappeared after the `deps.json` entry was
added.

**Fix — declare the native asset.** In
`KArchiveManager.AdminConsole.Api.deps.json`, inside the
`Microsoft.Data.SqlClient/<version>` target, add a `runtimeTargets` entry:

```json
"runtimes/win-x64/native/Microsoft.Data.SqlClient.SNI.dll": {
  "rid": "win-x64",
  "assetType": "native",
  "fileVersion": "6.0.2.0"
}
```

Needed after every redeploy. The durable fix is on the build side: republish with
`-r win-x64` so the RID assets land correctly and this step disappears.

### 2. `KArchiveManager.AdminConsole.Api.exe` does not exist in the package

Add-on `064_console_default_operator.sql` instructs:

> run `KArchiveManager.AdminConsole.Api.exe hash-password "<password>"`

and throws `50512` with the same text if the hash is not filled in. There is no
`.exe` anywhere in the handover — the publish is portable, so the entry point is
the DLL:

```powershell
dotnet KArchiveManager.AdminConsole.Api.dll hash-password "<password>"
# -> PBKDF2-SHA256$100000$<salt>$<hash>
```

Paste that value into `064` in place of `CHANGE-ME`. Write the file as UTF-8 — an
ANSI round-trip corrupts the em-dash in the seeded `DisplayName`, and that string
is shown in the console header.

### 3. The target framework is `net10.0`, not 8 or 9

| Source | Says |
|---|---|
| handover `README.md` | "ASP.NET Core Hosting Bundle (.NET 8/9 runtime)" |
| `04-runbooks/admin-console-iis-deployment.md` | "Hosting Bundle for the API target framework `net9.0`" |
| `app/KArchiveManager.AdminConsole.Api.runtimeconfig.json` | **`net10.0`**, `Microsoft.AspNetCore.App 10.0.0` |

Install the **.NET 10 Hosting Bundle** (`dotnet-hosting-10.0.12-win.exe` here). An
8 or 9 bundle will not start the app. Verify the module, not the runtime:
registry `HKLM\SOFTWARE\Microsoft\IIS Extensions\IIS AspNetCore Module V2` and
`C:\Program Files\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll`. Checking
`System32\inetsrv\aspnetcorev2.dll` is misleading — IIS Express ships its own copy
elsewhere and the V2 module does not live in `System32\inetsrv`.

### 4. `databaseOk: false` with nothing reported missing — role MEMBERSHIP

The most expensive failure to diagnose, because every field contradicts it:

```json
{"databaseOk":false,"processCount":6,"mappingCount":6,
 "missingObjects":[],"missingRoles":[],"missingExecutePermissions":[],"error":null}
```

The connection works, the procedures answer, `error` is `null`, nothing is listed
as missing — and the verdict is still false. `missingRoles` reports whether the
roles **exist in the database**, not whether the calling principal is **in** them.
`databaseOk` additionally evaluates membership, and reports the shortfall nowhere.

Granting `karch_viewer` alone — which is what step 6 of the IIS runbook says — is
not enough. Add the console login to every non-runtime role:

```sql
ALTER ROLE karch_viewer         ADD MEMBER [IIS APPPOOL\kAM Admin Console];
ALTER ROLE karch_operator       ADD MEMBER [IIS APPPOOL\kAM Admin Console];
ALTER ROLE karch_config_admin   ADD MEMBER [IIS APPPOOL\kAM Admin Console];
ALTER ROLE karch_advanced_admin ADD MEMBER [IIS APPPOOL\kAM Admin Console];
ALTER ROLE karch_approver       ADD MEMBER [IIS APPPOOL\kAM Admin Console];
```

`karch_runtime` is deliberately **not** granted — that is the runner role, and
this deployment keeps the two identities apart (see correction 5).

This never shows up when the console is tested with Kestrel under an interactive
sysadmin account, which is exactly why it was missed. **Test the console as the
app-pool identity or the test is worthless.**

### 5. Go-live readiness needs msdb reads — `059` part 1b, and only that part

`/api/golive-readiness` returns **500** with a masked message:

```
{"error":"Server configuration error.",
 "detail":"A required database permission is missing. Contact the administrator (see server logs)."}
```

`arch.usp_Frontend_GoLiveReadiness` reads `msdb.dbo.sysoperators`, `sysjobs` and
`backupset` **directly**, and `/api/jobs` reads the schedule tables. The app-pool
identity has no msdb user at all. Apply the read grants from
`059_console_job_control_grants.sql`:

```sql
USE msdb;
CREATE USER [IIS APPPOOL\kAM Admin Console] FOR LOGIN [IIS APPPOOL\kAM Admin Console];
-- GRANT SELECT ON: sysjobs, sysjobsteps, sysjobschedules, sysschedules, sysjobservers,
--                  sysjobactivity, sysjobhistory, sysoperators, sysalerts,
--                  sysnotifications, syscategories, backupset, backupmediafamily
```

`059` steps 2 and 3 were **deliberately skipped** here. They transfer ownership of
the PREP/RUN jobs to the console login and grant it `karch_runtime`, merging the
console and runner identities. This deployment already has a least-privilege
runner (`053`/`054`) and keeping them separate is worth more than console job
control. Skipping them costs only the ability to enable/reschedule jobs from the
UI; the panel still *reads* correctly with the grants above.

### 6. `061` never grants the operator API — nobody can log in

With the operator seeded by `064` and `DbOperatorsEnabled: true`,
`/api/security/status` still reported `operatorsConfigured: false`, and the login
box rejected the correct password.

`arch.ConsoleOperator` has **no direct permissions by design** — access is via four
procedures through ownership chaining. `061_console_operators.sql` grants EXECUTE
on them to `karch_config_admin` and `karch_advanced_admin`, but:

* those grants are wrapped in `IF DATABASE_PRINCIPAL_ID(...) IS NOT NULL`, so if
  `061` runs before the roles exist they are **silently skipped**; and
* `061` lives in `01-database/source-objects/kArchiveManagerAdmin/v2/`, not in
  `operational-add-ons/`, so it is not in the list an operator works through.

On this instance the table and the four procedures existed with **zero** grants.
Re-apply just the grant block:

```sql
GRANT EXECUTE ON arch.usp_Api_GetConsoleOperatorForAuth TO karch_config_admin;
GRANT EXECUTE ON arch.usp_Api_ListConsoleOperators      TO karch_config_admin;
GRANT EXECUTE ON arch.usp_Api_SaveConsoleOperator       TO karch_config_admin;
GRANT EXECUTE ON arch.usp_Api_DeleteConsoleOperator     TO karch_config_admin;
-- and the same four to karch_advanced_admin
```

After this, `operatorsConfigured: true` and `POST /api/security/unlock` returns an
edit token.

### 7. The dashboard chart legend is rendered where nobody can see it

The bars on **Source vs Archived by table** are teal and amber with nothing on
screen to say which is which, and the second chart, **Difference by table**, uses
the same two colours for something else entirely. On a dashboard shown to an
audience that is the first question asked and the worst one to answer by guessing.

The legend is not missing. The bundle builds it:

```jsx
<div className="chart-legend">
  <span><span className="legend-dot source"  />Source</span>
  <span><span className="legend-dot archive" />Archived</span>
</div>
```

and renders it as the **last child of `.bar-chart`** — which is
`max-height: 460px; overflow-y: auto`. With twenty-odd configured tables it sits
below the fold, so only someone who scrolls the chart to its very end ever sees
it. `Difference by table` has no legend element at all.

What the colours actually mean, read out of the stylesheet rather than inferred:

| | | |
|---|---|---|
| `.bar.source` | `#0f766e` teal | rows still in the source database |
| `.bar.archive` | `#d97706` amber | rows present in the archive |
| `.delta.negative` | `#0f766e` teal | difference < 0 — **archive holds more** |
| `.delta.positive` | `#b45309` amber | difference > 0 — source holds more |

Two things worth knowing before explaining this on stage. It is **source versus
archive, not deleted versus archived** — for the ANCHOR sets every `ObjectSpec`
has `RequireArchiveForDelete = 1`, so an archived row is also a deleted row and
the two readings coincide in effect, but the bar plots `sourceRows` and
`archivedRows`. And on the difference chart **teal means negative**, which is the
normal end state rather than a problem: the archive is ahead because the source
rows are gone.

**Fix** — [`console/chart-legend.css`](console/chart-legend.css) in this package.
It pins the existing legend to the bottom of the scroll port and adds a hover
tooltip to all four bar types, so the difference chart is covered too. CSS only;
the JS bundle is not touched, which matters because the console ships minified
with no source map and a broken bundle is a blank page.

```powershell
# elevated - the wwwroot ACLs refuse a normal user
Get-Content <package>\console\chart-legend.css -Raw |
  Add-Content 'C:\inetpub\kArchiveManager\AdminConsole\wwwroot\assets\index-PwqARZjk.css'
```

Then **Ctrl+F5**. The filename carries a content hash that does *not* change when
the file is edited in place, so the browser keeps serving its cached copy. A
console redeploy overwrites the file and the block is lost — same class of
local patch as correction 1, and the same real answer: it belongs in the product's
own stylesheet.

### 8. Analysis & Estimates shows nothing but zeros — a DMV permission

The screen renders, the rows are there, every number is `0.00` and every process
reports `missingTableCount` equal to its table count. Run the same procedure as a
sysadmin and it returns real figures, which is the tell — this is correction 4 all
over again, in a different place.

```
EXECUTE AS LOGIN = N'IIS APPPOOL\kAM Admin Console';
EXEC arch.usp_Api_EstimateNextRunImpact;
-- Msg 262: VIEW DATABASE PERFORMANCE STATE permission denied in database 'AAD'.
```

`arch.usp_Api_EstimateNextRunImpact` sizes the configured tables from
`sys.dm_db_partition_stats`. On SQL Server 2022 that DMV needs **`VIEW DATABASE
PERFORMANCE STATE`**, which `db_datareader` does not carry and which `051` does not
grant. The procedure cannot read the stats, concludes the tables are not there,
and reports zeros rather than failing — so nothing in the UI says a permission is
missing.

Grant it in every source database and the archive:

```sql
USE [AAD];                    GRANT VIEW DATABASE PERFORMANCE STATE TO [IIS APPPOOL\kAM Admin Console];
USE [ADV];                    GRANT VIEW DATABASE PERFORMANCE STATE TO [IIS APPPOOL\kAM Admin Console];
USE [kArchiveManagerBackups]; GRANT VIEW DATABASE PERFORMANCE STATE TO [IIS APPPOOL\kAM Admin Console];
```

Read-only and metadata-only: it reveals sizes and statistics, not data. After it,
`missingTableCount` drops to 0 and the screen fills.

This is the **third** permission that `051` should hand the console and does not,
after the five `karch_*` roles (correction 4) and the msdb reads (correction 5).
All three share a shape worth naming: the console degrades to a wrong answer
rather than an error, so **every console screen has to be checked as the app-pool
identity**. A sysadmin sees a working product.

---

## Two traps

### Creating the login

`SUSER_SID(N'IIS APPPOOL\kAM Admin Console')` returns a SID **even when no SQL
login exists** — Windows resolves the virtual account regardless. A create-login
script guarded with `IF SUSER_SID(...) IS NULL` therefore reports "login already
exists", creates nothing, and leaves an orphaned database user behind. Test
`sys.server_principals` instead:

```sql
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @AppLogin)
    CREATE LOGIN [...] FROM WINDOWS;
```

### Restoring a source database silently revokes the console's read access

A `RESTORE DATABASE` replaces every database principal with the ones in the backup.
The console's user in that source database is simply gone, and **nothing tells
you** — no error at startup, no failed login, no warning in
`/api/readiness`, which stays `databaseOk: true` because it only checks
`kArchiveManagerAdmin`.

The single symptom is one dashboard panel:

```
GET /api/dashboard/process-summary  ->  503
{"error":"Database call failed.",
 "detail":"Check ConnectionStrings:ArchiveManagerAdmin and verify that
           kArchiveManagerAdmin is reachable."}
```

The detail text points at the wrong database. The log has the truth —
`Error Number:916` — which is *the server principal is not able to access the
database under the current security context*.

Observed here on 2026-09-16: `AAD` had been restored from a customer backup the
previous day at 14:32, bringing 27 of the customer's own orphaned SQL users with
it and taking the console's user with it. The archive **jobs kept working**, which
makes it harder to spot, because the runner login had been re-created afterwards
and the console had not.

Diagnose it in one query — run it as yourself, it impersonates for you:

```sql
EXECUTE AS LOGIN = N'IIS APPPOOL\kAM Admin Console';
SELECT name, HAS_DBACCESS(name) FROM sys.databases
WHERE name IN ('AAD','ADV','kArchiveManagerAdmin','kArchiveManagerBackups');
REVERT;
```

A `0` anywhere is the answer. Fix by re-running
`051_grant_console_read_source_dbs.sql` with `@DbsCsv` listing every source plus
the archive. **Add it to the runbook of whoever restores WMS databases** — it will
happen again, and next time it may be the week of a go-live.

---

## Deployment order

1. Install the **ASP.NET Core 10 Hosting Bundle**, then `iisreset`. Verify the
   registry key and `C:\Program Files\IIS\Asp.Net Core Module\V2`.
2. Copy `02-admin-console/app` to e.g. `C:\inetpub\kArchiveManager\AdminConsole`.
3. **Correction 1** — add the native SNI entry to `deps.json`.
4. Create the IIS site/application: app pool `kAM Admin Console`, **No Managed
   Code**, identity `ApplicationPoolIdentity` (or a domain service account).
5. Edit `appsettings.json` — `ConnectionStrings:ArchiveManagerAdmin` to this
   instance. Leave `DbOperatorsEnabled: true`, `WindowsAuthEnabled: false`,
   `EditPasswordSha256: ""` — DB-managed operators are the current auth model.
   (The IIS runbook environment-variable route is the older fallback.)
6. Create the app-pool login — mind the `SUSER_SID` trap above — and add it to
   **all five** non-runtime roles (**correction 4**).
7. Run **`051_grant_console_read_source_dbs.sql`** with
   `@ConsoleLogin = N'IIS APPPOOL\kAM Admin Console'` and
   `@DbsCsv = N'AAD,ADV,kArchiveManagerBackups'`. Without it the dashboard returns
   503 on the movement panels — a masked `Msg 916`.
8. Apply the **msdb read grants** (**correction 5**).
9. Generate the password hash (**correction 2**), paste it into
   **`064_console_default_operator.sql`**, run it as UTF-8.
10. Apply the **`061` operator-API grants** (**correction 6**).
11. Verify **as the app-pool identity**: `/api/readiness` → `databaseOk: true`,
    `/api/golive-readiness` → 200, `/api/security/status` →
    `operatorsConfigured: true`, and `POST /api/security/unlock` returns a token.
12. Disable the default `admin` operator once real operators exist.

On a customer system, also apply `047_operational_alerting` — it is the only
go-live warning left open here, and only because this is a presentation
environment without SMTP.

### Optional add-ons

- `065_grant_console_restore_source_insert.sql` — **off by design.** Restore is the
  one operation that writes back into a production source, so the console dry-run
  preview works but a real restore returns `INSERT permission denied` unless a DBA
  runs `arch.usp_RestoreFromArchive` directly, or `065` is applied. Applying it is
  a deliberate privilege expansion.
- `058` / `059` steps 2–3 — Agent job control from the console, at the cost of
  merging the console and runner identities (**correction 5**).
- `066` — legal-hold panel.

---

## Remote access

The site binds `0.0.0.0:8089`, but no inbound firewall rule exists, so only the
server itself can reach it. Opening it serves an **admin console over plain HTTP**
to the network, so it is left as an explicit decision:

```powershell
New-NetFirewallRule -DisplayName "kAM Admin Console (8089)" -Direction Inbound -Protocol TCP -LocalPort 8089 -Action Allow
```

For anything beyond a presentation, put it behind HTTPS with a real certificate
and restrict the rule to the subnet the operators work from.

---

## Relationship to the other documents here

The handover is the product; this package is its configuration for Koerber
Warehouse Advantage. Where they overlap, prefer the handover:

| Topic | Authoritative source |
|---|---|
| Product deployment, end to end | handover `04-runbooks/customer-deploy-guide.md` |
| Admin Console on IIS | handover `04-runbooks/admin-console-iis-deployment.md` **plus the six corrections above** |
| The six WA document sets, their keys, cutoffs and gates | this package — `README.md` |
| Deploying *those sets* at a customer | this package — `DEPLOYMENT.md` |
| Reporting layer vs the SSRS dashboard | this package — `reports/README.md` |
