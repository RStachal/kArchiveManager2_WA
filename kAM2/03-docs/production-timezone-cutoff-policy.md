# kArchiveManager 2.0 — Production Timezone & Cutoff Policy

**Date:** 2026-05-28 (resolution update 2026-05-29)  
**Status:** ✅ IMPLEMENTED — see *Resolution (2026-05-29)* below  
**Risk:** K1 - Cutoff timezone verification

---

## Resolution (2026-05-29)

Risk K1 is now **closed in code** for both cutoff paths, and the fix is part of the
deploy bundle (not just a manual live-DB patch):

- **Object side** — `ObjectSpec.TimestampExpr` wrapped in `AT TIME ZONE` via
  `v2/031_apply_time_zone_conversions.sql` (live DB) and shipped wrapped by the seed
  `deploy/v2/02_configure_original_processes.sql` (fresh deploy).
- **Anchor side** — `arch.Process.AnchorTimestampExpr` (and any `ProcessDatabase`
  override) wrapped via `v2/034_apply_anchor_time_zone_conversions.sql` (live DB) and
  shipped wrapped by the seed. This is the expression the live v2 ANCHOR path actually
  uses for the cutoff in `arch.usp_PrepareCandidates` — the original `031` did **not**
  cover it, which left RECEIVING/SHIPPING deletes off by the TZ offset.
- **Runtime gate** — `v2/035_usp_AssertTimezonePolicyApplied` throws **50200** and blocks
  real deletes (Mode 0/1) when the governing cutoff expression is not UTC-normalized.
  It is called from `usp_RunPreparedBatch` (ANCHOR) and `usp_RunTimestampProcess`
  (TIMESTAMP) only on the real run; dry-runs/previews are exempt. (The sketch in §5.1
  below said `THROW 50001`; that code was already used by P1.3, so the gate uses 50200.)
- **Smoke test** — `deploy/v2/smoke-tests/31_timezone_policy_smoke.sql` verifies the data
  is wrapped, the gate procedure exists, the gate actually throws 50200 for a raw
  expression (rollback-wrapped), and the conversion shifts local→UTC as expected.

**On the "38 vs 11" expression counts:** the §1 inventory of *38* counts every distinct
timestamp reference across all processes and per-DB rows (object specs + anchors +
overrides). Script `031` reported *11* because that is the number of distinct
`ObjectSpec.TimestampExpr` **definitions**; the anchor expressions were the residual gap
that `034` closes. Both paths are now covered.

**Pending (operator/DBA, not code):** confirm the source databases (Edge / KMWEBV /
KMWE_Test / AAD) store local CET/CEST so `Central European Standard Time` is the correct
`@SourceTimezone`, and obtain product-owner sign-off before the first real delete.

---

## 1. Executive Summary

This document establishes the **official timezone handling policy** for kArchiveManager 2.0 production delete/archive operations.

**Current State:**
- Runtime uses `SYSUTCDATETIME()` for cutoff calculations
- 38 source timestamp expressions are configured across 5 processes
- **NO `AT TIME ZONE` conversions are present** in any timestamp expression
- 27/38 expressions use raw column references (DATE_CREAT, DATE_TIME, BILLEDDATE, etc.)
- 5/38 expressions use explicit datetime2 conversions
- 6/38 are anchor-driven (NULL timestamp expressions)

**Decision:** Assume **raw source columns are LOCAL TIME** in their source database until proven otherwise.

---

## 2. Timezone Classification

### A. Timestamp Expression Types (Current Configuration)

| Type | Count | Examples | Risk Level |
|------|-------|----------|-----------|
| RAW column reference | 27 | `DATE_CREAT`, `DATE_TIME`, `BILLEDDATE` | **HIGH** |
| datetime2 conversion | 5 | `COALESCE(CONVERT(datetime2(3), t.date_archived), ...)` | MEDIUM |
| NULL (anchor-driven) | 6 | WA_AAD smoke processes | LOW |

### B. Source Databases & Their Timezone Assumptions

| Source DB | Typical Columns | Assumed TZ | Evidence |
|-----------|-----------------|-----------|----------|
| Edge | DATE_CREAT, DATECREATE, BILLEDDATE | LOCAL (CET/CEST) | WMS source, no UTC suffix in DDL |
| KMWE_Test | DATE_CREAT, DATE_TIME, TIMESTMP | LOCAL (CET/CEST) | Test instance of Edge |
| KMWEBV | DATE_CREAT, DATE_TIME, TIMESTMP | LOCAL (CET/CEST) | Variant of Edge |
| AAD | (anchor-driven) | LOCAL (CET/CEST) | Business system, no conversion indicated |

---

## 3. Production Rules (MUST follow before delete/archive)

### Rule 3.1: Cutoff Calculation is UTC-based

```sql
-- Runtime cutoff calculation (current implementation)
DECLARE @AsOfUtc datetime2 = SYSUTCDATETIME();
DECLARE @CutoffDays int = 365; -- from Process.RetentionDays
DECLARE @CutoffUtc datetime2 = DATEADD(DAY, -@CutoffDays, @AsOfUtc);
```

**Implication:** `@CutoffUtc` is in UTC. All timestamps being compared must be converted to UTC.

### Rule 3.2: Source Timestamp Interpretation

**For RAW column references (27 specs):**
- Treat as **LOCAL TIME** in the source database
- Before comparison with `@CutoffUtc`, must convert to UTC using `AT TIME ZONE`

**For datetime2 conversions (5 specs):**
- INTEGRACE_DNLOAD, INTEGRACE_UPLOAD use explicit conversions
- Verify these produce UTC-normalized datetime2 values
- If not, add `AT TIME ZONE 'UTC'` wrapper

**For anchor-driven (6 specs):**
- No explicit timestamp; uses anchor table's timestamp
- Verify anchor table timestamps are also in LOCAL time
- Apply same conversion rules

### Rule 3.3: Timezone Conversion Requirement (NEW)

**Before entering production delete/archive:**

All timestamp expressions must be updated to explicitly convert to UTC:

```sql
-- CURRENT (UNSAFE - local time)
TimestampExpr = 'DATE_CREAT'

-- REQUIRED (SAFE - UTC explicit)
TimestampExpr = 'CONVERT(datetime2, CONVERT(datetimeoffset, DATE_CREAT, 121) AT TIME ZONE ''UTC'') AS ts'
-- OR if source columns are already aware of timezone:
TimestampExpr = 'DATE_CREAT AT TIME ZONE ''Central European Time'' AT TIME ZONE ''UTC'''
```

---

## 4. Implementation Timeline

### Phase 0 (CURRENT - Pilot/Test Only)
- ✅ No delete operations allowed on production data
- ✅ Smoke tests use prepared workflow with no actual deletes
- ✅ Configuration is validated
- ✅ Indexes are in place
- **Status:** READY FOR PILOT

### Phase 1 (BEFORE REAL DELETE)
- [ ] **Verify source timezone awareness**
  - Interview database owner for each source DB
  - Confirm: Are timestamps UTC or local time?
  - Confirm: Which timezone is "local"? (CET/CEST?)
  
- [ ] **Add explicit `AT TIME ZONE` to all 38 timestamp expressions**
  - Update ObjectSpec.TimestampExpr for 27 raw references
  - Wrap datetime2 conversions for 5 INTEGRACE specs
  - Verify anchor-driven specs inherit correct timezone handling
  
- [ ] **Update documentation field in ObjectSpec**
  - Add `TimestampExprNotes` or comment explaining timezone assumption
  
- [ ] **Create timezone smoke test**
  - Test that cutoff calculation produces expected date ranges
  - Run with test data and verify correct records are selected
  
- [ ] **Get sign-off from DBA/data owner**
  - Confirm timezone assumptions
  - Confirm cutoff window produces correct candidate sets

### Phase 2 (PRODUCTION CUTOVER)
- Only after Phase 1 is complete
- First delete run: use very old cutoff date (e.g., 5 years)
- Verify deleted row count is reasonable for retention window
- Monitor audit logs for correctness
- Gradually move to production retention windows

---

## 5. Risk Mitigation

### Immediate Actions (NOW)

1. **Lock the pilot gate:**
   - Smoke tests may continue
   - Real delete/archive is **BLOCKED** until timezone policy is applied
   - Add runtime check in prepared workflow:
     ```sql
     IF EXISTS (SELECT 1 FROM arch.ObjectSpec WHERE TimestampExpr LIKE '%AT TIME ZONE%')
       OR EXISTS (SELECT 1 FROM arch.ObjectSpec WHERE TimestampExpr IS NULL)
       BEGIN
         -- Safe to proceed
       END
       ELSE
       BEGIN
         THROW 50001, 'Timezone policy not applied. Delete operations blocked.', 1;
       END
     ```

2. **Document current assumption:**
   - Assume all raw timestamps = LOCAL time
   - Assume local timezone = CET/CEST (Central European)
   - Assumption is TEMPORARY and MUST be verified

3. **Create verification checklist:**
   - [ ] DBA confirms: Edge/KMWE_Test/KMWEBV use CET/CEST local time
   - [ ] DBA confirms: AAD source timestamps are local (not UTC)
   - [ ] DBA confirms: No daylight saving edge cases exist
   - [ ] Dev adds `AT TIME ZONE` to all 38 expressions
   - [ ] QA tests timezone smoke test with multiple cutoff dates
   - [ ] Product owner signs off on timezone policy

---

## 6. Root Cause Analysis (Why This Matters)

### The Risk

You configure RECEIVING process to delete records older than 365 days:
```sql
DECLARE @AsOfUtc datetime2 = SYSUTCDATETIME();  -- 2026-05-28 14:30:00.0000000
DECLARE @CutoffUtc datetime2 = DATEADD(DAY, -365, @AsOfUtc);  -- 2025-05-28 14:30:00.0000000
```

Query finds records where `DATE_CREAT < @CutoffUtc`:
```sql
-- CURRENT CODE (UNSAFE)
WHERE DATE_CREAT < @CutoffUtc  -- Comparing LOCAL 2025-05-28 vs UTC 2025-05-28

-- Example: If it's 3pm CET (UTC+2), then:
-- @AsOfUtc = 2026-05-28 13:30 UTC
-- @CutoffUtc = 2025-05-28 13:30 UTC
-- But Edge server thinks 3pm local = 2026-05-28 15:30 local
-- So it deletes records from 2026-05-28 13:30 local = 2026-05-28 11:30 UTC (WRONG - deletes 2h more than intended!)
```

**Impact:** Off-by-timezone-offset hours of data deleted incorrectly.

---

## 7. Decision Log

| Date | Decision | Owner | Status |
|------|----------|-------|--------|
| 2026-05-28 | Assume raw timestamps are LOCAL (CET/CEST) | Radim Stachal | ADOPTED |
| 2026-05-28 | Block real delete until `AT TIME ZONE` applied | Development | IMPLEMENTED |
| 2026-05-28 | Add `AT TIME ZONE` to `ObjectSpec.TimestampExpr` (script 031) | Development | DONE |
| 2026-05-29 | Add `AT TIME ZONE` to `AnchorTimestampExpr` (script 034) + ship wrapped in seed | Development | DONE |
| 2026-05-29 | Runtime delete gate `usp_AssertTimezonePolicyApplied` (THROW 50200, scripts 035/015/027) | Development | DONE |
| 2026-05-29 | Timezone smoke test (smoke-tests/31) | Development | DONE |
| TBD | DBA verification of source timezone assumptions | DBA | PENDING |
| TBD | Production sign-off | Product Owner | PENDING |

---

## 8. Appendix: Timestamp Expression Inventory

### INTEGRACE_DNLOAD (5 databases)
- **Edge:** `COALESCE(CONVERT(datetime2(3), t.date_archived), ...)`
- **KMWE_Test:** `COALESCE(CONVERT(datetime2(3), t.date_archived), ...)`
- **KMWEBV:** `COALESCE(CONVERT(datetime2(3), t.date_archived), ...)`

### INTEGRACE_UPLOAD (5 databases)
- **Edge:** `TRY_CONVERT(datetime2(3), STUFF(STUFF(...)))`
- **KMWE_Test:** `TRY_CONVERT(datetime2(3), STUFF(STUFF(...)))`
- **KMWEBV:** `TRY_CONVERT(datetime2(3), STUFF(STUFF(...)))`

### RECEIVING (6 databases)
- **Edge, KMWE_Test, KMWEBV (each):**
  - dbo.BACKRD: `DATE_CREAT`
  - dbo.BACKRH: `DATE_CREAT`

### SHIPPING (9 databases)
- **Edge, KMWE_Test, KMWEBV (each):**
  - dbo.SHIPDETL: `DATECREATE`
  - dbo.SHIPDETL2: `DATECREATE`
  - dbo.SHIPHIST: `COALESCE(DATE_UPLD, DATE_SHIP, DATE_CREAT)`
  - dbo.SHIPLINE: `BILLEDDATE`
  - dbo.SHIPLINE2: `BILLEDDATE`
  - dbo.SHIPMSTR: `COALESCE(DATE_SHIP, DATECREATE)`

### RF_LOG2 (3 databases)
- **Edge, KMWE_Test, KMWEBV:** `t.DATE_TIME`

### WA_AAD_PRIJEM_OSTRY_SMOKE (anchor-driven)
- dbo.t_receipt: (null)
- dbo.t_tran_log: (null)

### WA_AAD_VYDEJ_OSTRY_SMOKE (anchor-driven)
- dbo.t_order: (null)
- dbo.t_order_detail: (null)
- dbo.t_pick_detail: (null)
- dbo.t_tran_log: (null)

---

## 9. Next Steps (Action Items)

1. **This week:**
   - [ ] Get approval of this policy document
   - [ ] Schedule DBA interview for timezone verification
   
2. **Next sprint:**
   - [ ] Implement `AT TIME ZONE` conversions
   - [ ] Add timezone validation gate to prepared workflow
   - [ ] Create and run timezone smoke test
   
3. **Before production:**
   - [ ] DBA sign-off on timezone assumptions
   - [ ] Product owner sign-off on policy
   - [ ] Create runbook for timezone troubleshooting
   - [ ] Archive this policy document as part of deployment checklist

---

**Policy Owner:** Development Lead  
**Last Updated:** 2026-05-28  
**Next Review:** After Phase 1 timezone verification complete
