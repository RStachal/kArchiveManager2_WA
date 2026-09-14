# Legacy consolidation — decision record (v1.0 → v2.0)

**Status:** Resolved · **Date:** 2026-06-18 · **Scope:** release-readiness blocker **R-01**

This document records the single authoritative answer to the recurring release question:
*"Does the project still contain a parallel legacy (v1.0) archive/delete mechanism alongside the
v2.0 one, and if so which is active?"*

**Answer:** There is exactly **one** active runtime mechanism — the v2.0 prepared-batch model.
Every v1.0 archive/delete/prepare procedure is **dead code**, is **never created by the shipped
product**, and is now reduced to an **inert blocking tombstone** in the source tree. There is no
parallel live path.

---

## 1. What is active (v2.0 — the only runtime path)

```
SQL Agent "RUN/PREP CONFIGURED"  ->  arch.usp_RunProfile_Prepared (@Phase)
                                        -> arch.usp_RunConfiguredProcesses_Prepared
                                             ├─ TIMESTAMP -> arch.usp_RunTimestampProcess        (DELETE … OUTPUT INTO archive)
                                             └─ ANCHOR    -> arch.usp_PrepareCandidates
                                                            -> arch.usp_RunPreparedBatches_InWindow
                                                                 -> arch.usp_RunPreparedBatch     (dynamic DELETE … OUTPUT via usp_GetOutputColumns)
restore   -> arch.usp_RestoreFromArchive            copy-only (Mode 2) -> INSERT … SELECT NOT EXISTS (no delete)
estimates -> arch.usp_Api_EstimateNextRunImpact
```

Live helpers that **stay** in `arch`: `usp_GetOutputColumns`, `usp_EnsureArchiveTableLikeSource`,
`usp_ProvisionArchiveTablesForProcess`, `usp_ValidateConfiguration`,
`usp_ValidateIndexRequirements`, `usp_RecoverStaleRuns`, all `usp_Api_*` / `usp_Frontend_*`.

## 2. What is dead (v1.0 — retired)

| Retired v1.0 procedure | v2.0 replacement | Tombstone error |
|---|---|---|
| `usp_RunProcess` | `usp_RunProfile_Prepared` | 50004 |
| `usp_RunProcess_TimestampKeyset` | `usp_RunProfile_Prepared` | 50005 |
| `usp_RunProcess_RF_LOG2` | `usp_RunProfile_Prepared` | 50006 |
| `usp_RunAll` | `usp_RunProfile_Prepared` | 50020 |
| `usp_RunConfiguredProcesses` | `usp_RunConfiguredProcesses_Prepared` | 50021 |
| `usp_RunWorkBatch` | `usp_RunPreparedBatch` | 50022 |
| `usp_RunWorkBatches_InWindow` | `usp_RunPreparedBatches_InWindow` | 50023 |
| `usp_PrepWorkBatch_Receiving` | `usp_PrepareCandidates` | 50024 |
| `usp_PrepWorkBatch_Shipping` | `usp_PrepareCandidates` | 50025 |
| `usp_EstimateWorkBatchImpact` | `usp_Api_EstimateNextRunImpact` | 50026 |
| `usp_EstimateLatestWorkBatchImpact` | `usp_Api_EstimateNextRunImpact` | 50027 |
| `usp_EstimateCurrentProcessImpact_RF_LOG2` | `usp_Api_EstimateNextRunImpact` | 50028 |
| `usp_CaptureRowCountSnapshot` | `arch.RunItemObject` / `arch.RunDocAudit` (run telemetry) | 50029 |

## 3. How the risk is neutralized (defense in depth)

1. **Source files** — `kArchiveManagerAdmin/procedures/arch.usp_*.sql` for all 13 procedures above
   now contain only their original signature plus `THROW <code>, 'LEGACY BLOCKED …', 1;`. The
   original v1.0 bodies are preserved in **git history**. Running any of these files in SSMS
   creates a harmless gate, **not** live delete/archive logic.
2. **Clean product bundle** — `deploy/v2/release-package/deploy_clean_v2_full.sql` (and its inlined
   `_SSMS` twin) **never `:r`-includes** any legacy procedure. A clean install simply does not have
   these objects. *(Verified: 0 legacy `CREATE` bodies in the shipped bundle.)*
3. **Upgrade path** — `deploy/v2/01_upgrade_existing_1_0_to_2_0.sql` applies
   `v2/025_p1_3_block_legacy_procedures.sql` (the `RunProcess` THROW gates) and
   `v2/032_archive_legacy_procedures.sql` (transfers the remaining v1.0 procedures into the
   `legacy_v1` schema), so an upgraded environment ends with the legacy surface blocked/quarantined.
4. **Post-deploy assertion** — `release-package/verify_clean_deploy.sql` **FAILs** if any legacy
   procedure exists after a clean deploy.

**Live evidence (instance `RADIM-STACHAL\RSTSQL2022`):** zero legacy run/prepare procedures present;
only the v2.0 chain exists. No `TRUNCATE` anywhere in the runtime. Mode=1 invariant
`archived == deleted` (`Divergence = 0`) confirmed by repeated audited sweeps.

## 4. Generated / deprecated deploy artifacts

The following are **derived** artifacts, regenerated from the (now tombstoned) sources by
`tools/generate_classic_v2_scripts.py` and `tools/generate_grouped_v2_deploy.py`:

- `deploy/v2/classic-ssms/*` — no-SQLCMD inlined equivalents of the numbered scripts.
- `deploy/v2/grouped-ssms/*` — grouped clean deploy.

They have been regenerated so that no live v1.0 body remains inlined in them. They are **not** the
clean-customer path — use `release-package/deploy_clean_v2_full.sql`. The legacy numbered
`00`/`01`/`11`/`13`/`14` scripts and `classic-ssms`/`grouped-ssms` exist for the existing-environment
upgrade and manual-SSMS scenarios only; `00_deploy_2_0_clean.sql` intentionally fails
`verify_clean_deploy.sql`.

> **Maintenance rule:** if a legacy source file or a numbered script changes, re-run both generators
> before release so the inlined bundles stay consistent with the sources.

## 5. Conclusion

The consolidation is **complete and proven**. The v2.0 prepared-batch model is the sole active
mechanism; the v1.0 surface is dead, unshipped, and tombstoned. R-01 is resolved.
