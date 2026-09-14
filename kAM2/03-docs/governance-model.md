# kArchiveManager 2.0 — Governance Model

**Status:** Adopted for pilot (P1.1, Option A)
**Owner:** Radim Stachal / KODYS
**Related:** [p1-production-hardening-plan.md](p1-production-hardening-plan.md) §P1.1

---

## Model: Audited Immediate-Publish

kArchiveManager 2.0 governs configuration changes with an **audited immediate-publish**
model. This document states that model honestly so operators and reviewers know exactly
what protection is — and is not — in force.

**How it works**

- Every configuration change made through the Admin Console is written through an
  `arch.usp_Api_Save*` procedure and recorded as a change set in `arch.ConfigChangeSet`
  (visible on the Admin Console **Change history** panel and exportable to CSV).
- Each change set records **who** requested it (`RequestedBy`), **when**, a mandatory
  **change reason** (≥ 6 characters), and the **fields** that changed.
- After a successful save the change is **published immediately** (status `Published`)
  and the configuration validation is run.
- **Reads are anonymous; edits require a login.** The read surface — Dashboard, Analysis &
  Estimates, Runs, Document lookup — is served without authentication so the data is easy to reach.
  The write/operational surface — **Configuration, Validation, Go-live** (and run-stop / restore) —
  is gated behind an **edit lock** and, in Production, the `RequireAuthenticatedApi` floor.
- Authorization is granted by one of four coexisting paths (checked in this order):
  - **DB-managed operators (default / primary path):** `username` + password operators stored in
    the control DB (`arch.ConsoleOperator`), managed live from the console's **Configuration →
    Operators** panel — no appsettings edit or app-pool recycle. Domain-independent: no SSMS/AD
    accounts. A seeded **`admin`** default (sa-like: enabled + elevated) bootstraps the first login;
    create your own operators, then **disable `admin`**. Enable with `AdminConsole:DbOperatorsEnabled:true`
    and seed via migration `064_console_default_operator.sql` (run `hash-password`, paste the PBKDF2 value).
    The stored hash is verified server-side; the editor shows "Editing as <operator>" and `RequestedBy`
    records that operator.
  - **Windows/AD identity (optional):** the authenticated Windows user must be on the
    `AdminConsole:AdminUsers` allowlist (requires `WindowsAuthEnabled:true` + IIS Windows Auth).
    No password; editor shows "Editing as DOMAIN\user".
  - **Local operator account (config file):** a per-operator `username` + password in
    `AdminConsole:Operators` (username + `PasswordSha256` + optional `displayName`). Same UX as the
    DB operators but static in appsettings (needs a recycle to change).
  - **Shared password (fallback):** `AdminConsole:EditPassword(Sha256)` → `X-Admin-Edit-Token`,
    a no-username shared credential for dev / emergency / break-glass. Left **empty (off)** in the
    default template.
- All four mint the same `X-Admin-Edit-Token`; the token is bound to the resolved identity so the
  audit trail attributes the change to the real operator (not the API service account).
- Only an authorized session can write. Dangerous changes (disabling a process, weakening
  delete protection, removing `AT TIME ZONE` from a cutoff expression) require an explicit
  in-editor confirmation before they can be saved.

**Enforcement level: audit, not approval.** There is **no mandatory second-person
(4-eyes) approval gate.** A single authorized operator can make and publish a change.
The control is *accountability after the fact* (a complete, attributed audit trail),
not *prevention before the fact*.

---

## Suitable / not suitable

✅ Suitable for:
- Internal-only administration by a trusted KODYS team with process discipline.
- A pilot / extended-pilot phase where the audit trail provides sufficient accountability.

❌ Not sufficient on its own for:
- External-facing or multi-tenant operation.
- Regulated environments that mandate enforced separation of duties (4-eyes).
- Shared-credential anonymity concerns — see "Known limitations".

---

## Known limitations (be honest)

- **No enforced approval** — approval is not required, so the model relies on operator
  discipline plus the audit trail.
- **Allowlist, not AD groups (yet).** Authorization is an explicit user allowlist in config;
  it is not driven by AD group membership. Group-based roles can be added later.
- The **shared password fallback** is a shared credential (no per-user identity). It is **off by
  default** now that DB-managed operators give each operator their own username+password without a
  domain. Prefer DB operators (or the Windows/AD path); enable the shared password only for
  emergency/break-glass and keep it disabled otherwise.
- The seeded **`admin`** default is a shared bootstrap credential (like SQL `sa`) — disable it once
  real per-operator accounts exist so every published change is attributed to a named operator.

---

## Deployment — recommended default: DB-managed operators (no AD, no appsettings edits)

The shipped template runs this model: `WindowsAuthEnabled:false`, `DbOperatorsEnabled:true`,
empty shared `EditPasswordSha256`. Bootstrap it once, then manage everything from the console:

1. Seed the default `admin` operator — run migration `064_console_default_operator.sql`:
   generate a hash with `KArchiveManager.AdminConsole.Api.exe hash-password "<password>"`, paste the
   `PBKDF2-SHA256$...` value into the script (replacing `CHANGE-ME`), then run it.
2. Sign in to the console as `admin` + that password. Open **Configuration → Operators**, add your
   named operators (each gets username + password + optional elevation), then **disable `admin`**.
3. No appsettings edit or app-pool recycle is needed to add / disable / repassword an operator —
   changes take effect immediately. This is the domain-independent, per-operator-identity path.

## Deployment — option A: local operator accounts in config (no AD required)

Static alternative to the DB operators — provision operators directly in `appsettings.json`
(needs an app-pool recycle to change; no domain, no IIS Windows Auth):

```jsonc
"AdminConsole": {
  "Operators": [
    { "Username": "jnovak", "DisplayName": "Jan Novak", "PasswordSha256": "PBKDF2-SHA256$100000$<salt>$<hash>", "Enabled": true }
  ]
}
```

- **`PasswordSha256` holds a salted PBKDF2-HMAC-SHA256 hash** (S2). Despite the historical field name, the
  API stores/verifies a `PBKDF2-SHA256$iterations$salt$hash` string with a per-hash random salt. Generate it
  with the API's CLI (so it matches the verification exactly):
  ```powershell
  dotnet run --project KArchiveManager.AdminConsole.Api -- hash-password "the-password"
  # (or, on a deployed box) KArchiveManager.AdminConsole.Api.exe hash-password "the-password"
  ```
  Paste the full `PBKDF2-SHA256$...` output into `PasswordSha256`. The same CLI/value works for the shared
  `AdminConsole:EditPasswordSha256`. Legacy unsalted SHA-256 hex still verifies for back-compat, but
  **regenerate any existing hashes as PBKDF2** before production.
- Never store a plaintext operator password; an operator entry without `PasswordSha256` is ignored.
- Set `Enabled: false` to revoke an operator. Operators sign in with their username + password and
  are attributed by name in the audit trail.

## Deployment — option B: Windows/AD authorization (optional)

1. Add the allowed Windows accounts to `AdminConsole:AdminUsers` (e.g. `["DOMAIN\\jnovak"]`)
   and keep `AdminConsole:WindowsAuthEnabled: true` in the API `appsettings.json`.
2. On the IIS site, enable **Windows Authentication** (keep **Anonymous Authentication** on so
   the SPA and read-only/readiness endpoints stay reachable). The in-process ASP.NET Core
   integration forwards the Windows token to the app.
3. Optionally configure a `AdminConsole:EditPassword(Sha256)` as the break-glass fallback.
4. `WindowsAuthEnabled` is set to `false` in `appsettings.Development.json` so the API runs
   under Kestrel (dev) without an IIS Windows-auth handler.

Options A and B (and the shared password) coexist; configure whichever the deployment needs.

---

## Runtime execution identity — least privilege (T-33)

Config governance above covers *who may change configuration*. A separate control covers *what
identity runs the irreversible archive+DELETE at run time*. By default a SQL Agent **T-SQL** job step
runs under the SQL Agent service account (effectively sysadmin for T-SQL) — far more than the runner
needs. The least-privilege model (clean bundle `kArchiveManagerAdmin/v2/055` + add-ons
`deploy/v2/053`/`054`) constrains it:

- **Dedicated non-sysadmin login** in role **`karch_runtime`**: EXECUTE on the runner proc chain +
  `VIEW DEFINITION ON SCHEMA::arch` (so the procs' `OBJECT_ID()` guards resolve — metadata visibility
  is *not* covered by ownership chaining). The runner's writes to the Admin control tables flow through
  **ownership chaining**, so it holds **no** direct table DML in the Admin DB.
- **Source DBs:** SELECT + DELETE on **only the mapped tables** (the cross-DB DELETE is dynamic SQL, so
  chaining does not apply); plus SELECT on the ANCHOR candidate table. No DDL, no other tables, no db_owner.
- **Archive DB:** INSERT + SELECT + ALTER on the archive schema(s) + CREATE TABLE — but **no DELETE/UPDATE**,
  so the unattended runner can **never purge or tamper** with the archive (purge stays a `karch_approver`/DBA
  action via `arch.usp_RestoreFromArchive`, T-27).
- **Job owner, not proxy:** a T-SQL Agent step ignores `@proxy_name` and runs as the job **owner**;
  `054` re-owns `RUN CONFIGURED` to the non-sysadmin runner so the step executes least-privilege.
- **Run-start gate:** the job's VALIDATE step calls `arch.usp_VerifyRunnerPrivileges`, which asserts the
  runner is not sysadmin/db_owner and holds exactly the grants above (else `THROW` → the run is blocked
  before any delete). Grants are snapshotted to `arch.RunnerPrivilegeInventory` at deploy time.

Verified end-to-end: the least-privilege login archives with `Divergence=0`, is denied a DELETE on the
archive, and the gate `THROW`s when a required source grant is missing.

---

## Retention floor + legal hold (T-21)

Two compliance controls bound the irreversible delete, both enforced at REAL deletes (DryRun exempt),
shipped in the clean bundle (`kArchiveManagerAdmin/v2/056`):

- **Retention floor** — `arch.RetentionPolicy.MinRetentionDays` (a singleton; **default 0 = disabled**,
  the customer sets their policy via `arch.usp_Api_SetRetentionFloor`). `arch.usp_AssertRetentionFloor`
  THROWs **50210** when the effective cutoff is more recent than `now − MinRetentionDays`, i.e. the run
  would delete rows younger than the floor. It checks the *final* cutoff, so it catches both a too-small
  `RetentionDays` and a too-recent explicit `CutoffDate`. Enforced in the TIMESTAMP runner (027), the
  ANCHOR runner (015), and at ANCHOR **prepare** time (014) so a floor-violating config never even builds
  a WorkBatch.
- **Legal hold** — `arch.LegalHold` rows (`ProcessCode` + optional `SourceDb` + `HoldKey` = the process's
  primary candidate key, `Key1`). Active holds are **excluded from every candidate set** at build time
  (014/027); a hold added *after* an ANCHOR WorkBatch is prepared is honored at claim time by **parking**
  the key (`WorkBatchKey.Status = 5`) so it is never deleted/archived and the batch still completes.
  Add/release is a `karch_approver` action (`usp_Api_AddLegalHold` / `usp_Api_ReleaseLegalHold`),
  auditable via `CreatedBy`/`ReleasedBy`; `usp_Frontend_GetLegalHolds` lists them. Holds operate at the
  `Key1` group granularity (for composite-key processes this is over-inclusive but never under-excludes).

The runner edits are `OBJECT_ID`-guarded, so on an environment patched without 056 they degrade gracefully
(no enforcement) rather than erroring. Verified end-to-end: the floor blocks a too-recent cutoff (50210),
a held key survives a run with `Divergence=0`, and a post-prepare hold parks the key without wedging the run.

---

## Upgrade path: enforced 4-eyes (Option B)

If a regulated or multi-tenant deployment needs enforced separation of duties:

1. Add `ApprovedBy` / `ApprovedAtUtc` to the publish path and require approval before a
   change set moves to `Published`.
2. Reject self-approval (`approver ≠ publisher`) and bind both identities to the actual
   authenticated user rather than a free-form name.
3. Surface the approval queue in the Admin Console.

See `p1-production-hardening-plan.md` §P1.1 Option B for the proposed
`arch.usp_Api_PublishConfigChangeSet` shape. This is **not** implemented in the pilot.

---

## Decision log

| Date | Decision | Owner | Status |
|------|----------|-------|--------|
| 2026-05-28 | Adopt audited immediate-publish for pilot (Option A) | Radim Stachal | ADOPTED |
| 2026-06-01 | Document the model honestly in this file | Development | DONE |
| 2026-06-01 | Windows/AD allowlist authorization (augment password); audit records real user | Development | DONE |
| 2026-06-01 | Local operator accounts (username + PasswordSha256) for per-user identity without AD | Development | DONE |
| 2026-06-10 | Runtime least-privilege runner identity (role karch_runtime + 053/054/055; run-start gate) | Development | DONE |
| 2026-06-10 | Retention floor + legal hold (056; floor gate THROW 50210 + candidate exclusion/park) | Development | DONE |
| TBD | AD group-based roles instead of user allowlist | Development | DEFERRED |
| TBD | Implement enforced 4-eyes (Option B) if regulated/multi-tenant | Development | DEFERRED |
