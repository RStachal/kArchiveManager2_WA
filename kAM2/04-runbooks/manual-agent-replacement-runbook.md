# kArchiveManager 2.0 — Manual run without SQL Server Agent (runbook)

When SQL Server Agent is unavailable (service stopped, not dispatching, or policy-restricted),
the scheduled PREP/RUN jobs can be replaced 1:1 by the SQL below. The statements are the **exact
job-step bodies** of `kArchiveManager - PREP CONFIGURED` and `kArchiveManager - RUN CONFIGURED`,
executed under the same least-privilege identity the jobs use. Verified live 2026-07-14
(KMWE 540-day delete-only process + 1M-row bulk purge).

## Prerequisites

- Run as a sysadmin (or any login with `IMPERSONATE` on the runner login).
- The runner login (default `karch_runtime_svc`, created by `deploy/v2/053`) must exist and the
  jobs' grants must be in place (053 applied for every enabled source DB).

> **Why `EXECUTE AS` is mandatory:** the T-33 privilege gate (`arch.usp_VerifyRunnerPrivileges`)
> **fails with error 51001 when evaluated as sysadmin** — by design, the unattended runner must
> not be sysadmin. Running the block below without the `EXECUTE AS LOGIN` wrapper therefore
> aborts before any deletion. This is a feature, not a bug.

## 1) PREP phase (validation + privilege gate + prepare)

```sql
USE [kArchiveManagerAdmin];
EXECUTE AS LOGIN = N'karch_runtime_svc';
BEGIN TRY
    DECLARE @rc int; EXEC @rc = arch.usp_ValidateConfiguration;
    IF @rc <> 0 THROW 51000, N'kArchiveManager validation failed.', 1;
    DECLARE @rp int; EXEC @rp = arch.usp_VerifyRunnerPrivileges;
    IF @rp <> 0 THROW 51001, N'Runner privilege gate failed.', 1;
    EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'JOB_DEFAULT', @Phase = N'PREP';
    REVERT;
END TRY
BEGIN CATCH
    IF ORIGINAL_LOGIN() <> SUSER_SNAME() REVERT;
    THROW;
END CATCH
```

## 2) RUN phase (the actual archive/delete — run right after PREP)

```sql
USE [kArchiveManagerAdmin];
EXECUTE AS LOGIN = N'karch_runtime_svc';
BEGIN TRY
    DECLARE @rc int; EXEC @rc = arch.usp_ValidateConfiguration;
    IF @rc <> 0 THROW 51000, N'kArchiveManager validation failed.', 1;
    DECLARE @rp int; EXEC @rp = arch.usp_VerifyRunnerPrivileges;
    IF @rp <> 0 THROW 51001, N'Runner privilege gate failed.', 1;
    EXEC arch.usp_RunProfile_Prepared @RunProfileCode = N'JOB_DEFAULT';
    REVERT;
END TRY
BEGIN CATCH
    IF ORIGINAL_LOGIN() <> SUSER_SNAME() REVERT;
    THROW;
END CATCH
```

## 3) Check the result

```sql
SELECT TOP (5) ri.RunItemId, p.ProcessCode, ri.SourceDb, ri.Status,
       ri.RowsArchived, ri.RowsDeleted, ri.StartedAt
FROM kArchiveManagerAdmin.arch.RunItem ri
JOIN kArchiveManagerAdmin.arch.Process p ON p.ProcessId = ri.ProcessId
ORDER BY ri.RunItemId DESC;
```

Expected: `Status = OK`; for Mode=1 `RowsArchived = RowsDeleted` (divergence 0); `RowsDeleted = 0`
is the **correct** steady-state result when nothing has aged past the retention cutoff.

## Bulk purges: the per-invocation keyset cap

One RUN invocation processes at most `min(MaxBatchesPerRun, 100) × BatchRowCount` rows
(**400 000 with the shipped 4000-row batches**) — a deliberate keyset/tempdb safety ceiling in
`usp_RunTimestampProcess`. Daily increments are unaffected (a day is a single batch). For an
initial backlog purge, simply repeat the RUN block until it reports `RowsDeleted = 0`
(e.g. a 1M backlog = 3 invocations; measured 2026-07-14: ~2 200 rows/s end-to-end in the
heaviest profile, i.e. ≈ 6–8 min per 1M rows).

## Troubleshooting: Agent installed but `sp_start_job` says "SQLServerAgent is not currently running"

Symptoms: the Agent Windows service is *Running*, yet `msdb.dbo.syssessions` is empty and
`SQLAGENT.OUT` loops `[150] SQL Server does not accept the connection (error: 0) …
Verify Connection On Start` every 30 s.

Check in this order:

1. **ODBC driver registration (root cause found in the field, 2026-07-14).** SQLAGENT.EXE
   connects through the ODBC Driver Manager. If `HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers`
   is empty (registration wiped; the DLL alone is not enough), **every** Agent on the machine
   fails exactly like this — and `sqlcmd` typically fails too while .NET clients still work.
   Fix (elevated): reinstall the driver, e.g.
   `msiexec /i msodbcsql.msi IACCEPTMSODBCSQLLICENSETERMS=YES /qn`
   (the MSI ships on SQL Server media under `…\x64\Setup\x64\`), then restart the Agent service.
2. **Named-instance resolution.** For a named instance the Agent connects by
   `MACHINE\INSTANCE`: the **SQL Server Browser** service must be running (and a network
   protocol — Named Pipes or TCP — enabled). Shared-Memory-only lockdowns break the Agent.
3. **Agent XPs** enabled: `sp_configure 'Agent XPs', 1; RECONFIGURE;`.
4. **Authentication mode** (only if the runner/console use SQL logins): the instance must run in
   mixed mode (`LoginMode = 2`), applied after an engine restart.
