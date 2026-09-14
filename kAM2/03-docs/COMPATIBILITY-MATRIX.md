# Compatibility Matrix — kArchiveManager 2.0

**Date:** 2026-06-18 · **Applies to:** v2.0.0

Legend: **✅ Tested** = exercised on a live instance during development/verification ·
**🟢 Supported** = designed for and expected to work, not yet formally certified on that exact
configuration · **🟡 Verify before prod** = supported by design but listed as a release condition ·
**❌ Not supported**.

---

## SQL Server engine

| Configuration | Status | Notes |
|---|---|---|
| SQL Server 2022 (Developer) | ✅ Tested | Primary development + verification instance `RADIM-STACHAL\RSTSQL2022`. |
| SQL Server 2019 | 🟢 Supported | Minimum supported version. No 2022-only feature is required at runtime (Ledger is optional, see below). 🟡 Run `verify_clean_deploy.sql` + `variant_test_pack.sql` on a 2019 instance before first production use. |
| SQL Server 2017 and earlier | ❌ Not supported | Relies on `AT TIME ZONE` / `STRING_AGG` / `datetime2` patterns standardized in 2016+; only 2019+ is validated. |
| Azure SQL Database (single DB) | ❌ Not supported | Cross-database three-part names (`SourceDb.dbo.Table` ↔ `kArchiveManagerBackups`) and SQL Agent jobs are unavailable. |
| Azure SQL Managed Instance | 🟡 Verify before prod | Cross-DB + Agent exist; not tested. Treat as a separate certification. |

### Edition

| Edition | Status | Notes |
|---|---|---|
| Developer | ✅ Tested | |
| Enterprise | 🟢 Supported | No Enterprise-only feature is required. |
| Standard | 🟡 Verify before prod | Expected to work (no partitioning/online-index dependency). 🟡 Certify a clean deploy + a representative sweep on Standard. |
| Express | ❌ Not supported | No SQL Agent; 10 GB DB cap conflicts with archive growth. |

### Recovery model & high availability

| Configuration | Status | Notes |
|---|---|---|
| `kArchiveManagerBackups` in **FULL** recovery | ✅ Tested / required | The deploy creates the archive DB in FULL. Ensure regular log backups. |
| Source DB in FULL recovery | 🟢 Supported | Large `DELETE … OUTPUT` batches generate log; size `BatchRowCount`/`MaxBatchesPerRun` to your log free space (see performance docs). |
| Source DB in SIMPLE recovery | 🟡 Verify before prod | Functionally supported; log-growth profile differs. Validate batch sizing. |
| Always On Availability Groups | 🟡 Verify before prod | Cross-DB writes + Agent on the primary are expected to work; replica/failover behavior **not yet verified**. Tracked as release condition R-04. |
| Log shipping / mirroring | 🟡 Verify before prod | Not tested. |

> **Timezone:** the platform stores all timestamps in UTC (`SYSUTCDATETIME`). The timezone policy
> gate (50200) must pass; configure the source-data timezone correctly (see
> `docs/production-timezone-cutoff-policy.md`).

### Optional 2022+ features

| Feature | Status | Notes |
|---|---|---|
| SQL Server 2022 Ledger for audit tamper-evidence | 🟢 Optional (not required) | Current audit immutability is DENY-based access control. Converting `RunDocAudit`/`ConfigChange*` to updatable Ledger tables is a planned follow-up and is **not** needed on 2019. |

---

## Admin Console

| Component | Status | Notes |
|---|---|---|
| .NET runtime | ✅ Tested | **.NET 9.0** (ASP.NET Core minimal API). |
| Hosting — IIS (in-process) | ✅ Tested | Site on `:8089` at `C:\inetpub\kAMAdminConsole`; Windows Authentication optional for the AD allowlist (keep Anonymous for the SPA/reads). |
| Hosting — Kestrel (dev) | 🟢 Supported | Windows identity is anonymous → shared-password fallback. |
| Authentication | ✅ Tested | DB-backed console operators (PBKDF2) + config operators + shared-password fallback; optional Windows/AD allowlist. |
| OS — Windows Server 2019/2022 | 🟢 Supported | IIS + .NET 9 hosting bundle. Dev verified on Windows 11. |
| SPA browser | 🟢 Supported | Current Chromium/Edge/Firefox. No IE support. |

---

## Authentication to SQL

| Mode | Status | Notes |
|---|---|---|
| Windows / Integrated | ✅ Tested | Live instance is Windows-only auth. Runner must be a Windows account; use a dedicated non-sysadmin service account at the customer (see runbook / R-05). |
| SQL logins | 🟢 Supported | Where the instance permits mixed mode. |

---

## Release conditions affecting this matrix

The following are **not** data-safety blockers but must be cleared before declaring a configuration
production-certified (see `RELEASE-NOTES-v2.0.md`):

- **R-03** — formal performance benchmark at customer scale (logical reads, log MB/run, tempdb,
  deadlocks) with acceptance criteria.
- **R-04** — Standard edition + SIMPLE/FULL recovery + Always On certification pass.
- **R-05** — deploy with a dedicated non-sysadmin runner login (not the app-pool account).
- **R-06** — v1.0 → 2.0 upgrade dry-run on a representative v1 instance.
