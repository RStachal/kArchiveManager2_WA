# Manual test battery — kArchiveManager 2.0

Reproducible manual tests that exercise correctness, performance, safety and resilience of the
archiving engine. All were executed live on `RADIM-STACHAL\RSTSQL2022` (2026-06-24); every run
reconciled with **Divergence = 0, 0 deadlocks, 0 data loss**.

## How to run
Each `.sql` runs against the control DB via SSMS or sqlcmd, e.g.:
```
sqlcmd -S <instance> -d kArchiveManagerAdmin -E -i t1_audit_overhead_ab.sql
```
They use the R-03 benchmark harness (`../r03_benchmark/r03_benchmark_harness.sql`) for metrics, and
seed/clean test data in the source DB (KMWEBV) and archive (kArchiveManagerBackups). **Run only on a
test instance** — they seed and delete data. Config is set at the EFFECTIVE level
(`arch.ProcessDatabase`, which overrides `arch.Process`) and restored at the end.

## Tests

| File | Proves | Expected result |
|---|---|---|
| `t1_audit_overhead_ab.sql` | Cost of per-row audit | NONE ~9 100 rows/s vs ROW ~7 200 rows/s (≈21% overhead); NONE writes 0 audit rows, ROW writes 1/row; Div=0 |
| `t2_mode_curve_idempotency.sql` | The three modes + copy-only idempotency | Mode 1: src→0, +archive; Mode 0: src→0, +0 archive; Mode 2: src intact, +archive, **2nd run +0 (idempotent)** |
| `t3_restore_roundtrip.sql` | Restore-from-archive | archive 50k → restore → source 50k restored, archive copy kept |
| `t4_cutoff_tz_boundary_winter.sql` | Fixed cutoff TZ (winter) | `CutoffDate 2024-01-01` → effective local boundary **01:00 CET** (UTC+1), strict `<` |
| `t5_cutoff_tz_boundary_summer_dst.sql` | Fixed cutoff TZ (summer/DST) | `CutoffDate 2024-07-01` → effective local boundary **02:00 CEST** (UTC+2) |
| `t6_retention_floor_50210.sql` | Retention-floor gate | floor=365d + cutoff now−1d → real run **blocked (50210)**, nothing deleted; **dry-run exempt** |
| `t7_legal_hold_exclusion.sql` | Legal hold | held doc stays in source (excluded), others archive; release → archives |
| `t8_anchor_concurrency_prep.sql` + `_run.sql` | Concurrency on an ANCHOR mapping | run `_run.sql` twice concurrently: one OK, the other rejected (applock); source drained once, archive no double, Div=0 |
| `t9_crash_consistency_seed.sql` + `_run.sql` | Crash-consistency | seed, launch `_run.sql`, KILL its session mid-flight: source+archive sum == seeded total, **0 overlap** (in-flight batch rolled back atomically); then `usp_RecoverStaleRuns` closes the orphan and a re-run drains the rest |
| `perf_fullrun_timestamp_1M.sql` | Throughput, TIMESTAMP processes @ ~1M | RF_LOG2 / DNLOAD / UPLOAD, Mode 1 + ROW audit, Div=0, lock-safe |
| `perf_fullrun_anchor_1M.sql` | Throughput, ANCHOR processes @ ~1M | RECEIVING / SHIPPING, Mode 1, Div=0 |

## Concurrency / crash tests — operator notes
- **Concurrency**: open two SSMS query windows and run `t8_..._run.sql` (or `t9_..._run.sql`) in both at
  once. The applock serializes them; the loser fails with *"failed to acquire applock"*.
- **Crash**: run `t9_crash_consistency_seed.sql`, start `t9_crash_consistency_run.sql`, then in another
  window `KILL <spid>` of the running session while the archive count is climbing. Verify
  `source + archive == seeded total` and that no ROWID is in both.
