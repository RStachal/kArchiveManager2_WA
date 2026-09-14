# kArchiveManager 2.0 — Official Runtime Execution Paths

> ⚠️ **HISTORICAL / SUPERSEDED (2026-05-28).** This describes a *transitional* v2 build where v1 procedures were
> BLOCKED in place, and it references `arch.WorkBatchHistory`. The **clean customer build contains NO v1 procedures
> at all** and has **no `WorkBatchHistory` table** — the real audit log is `arch.Run` / `arch.RunItem` /
> `arch.RunItemObject` / `arch.RunDocAudit`. For the current, accurate runtime path see
> **kArchiveManager-geneze-dokumentace.md §1.3**. Kept for history only — do not hand this file to a customer.

**Date:** 2026-05-28  
**Status:** Production Policy (P1.3 Runtime Path Standardization)  
**Audience:** Database operators, DBA, deployment engineers

---

## Executive Summary

kArchiveManager 2.0 has **two execution paths**: official (v2.0) and legacy (v1.0 compatibility). 

**Bottom line:** Use **ONLY** the v2.0 prepared workflow. Legacy procedures are blocked with a clear error message.

| Path | Procedure | Status | Use Case |
|------|-----------|--------|----------|
| **v2.0 Prepared** | `arch.usp_RunProfile_Prepared` | ✅ ALLOWED | **ALL PRODUCTION OPERATIONS** |
| **v1.0 Legacy** | `arch.usp_RunProcess` | ❌ **BLOCKED** | Migration/backward-compat only (throw error) |
| **v1.0 Variant: Timestamp** | `arch.usp_RunProcess_TimestampKeyset` | ❌ **BLOCKED** | Legacy support (throw error) |
| **v1.0 Variant: RF_LOG2** | `arch.usp_RunProcess_RF_LOG2` | ❌ **BLOCKED** | Legacy support (throw error) |

---

## ✅ Official v2.0 Execution Path (USE THIS)

### Entry Point
```sql
EXEC arch.usp_RunProfile_Prepared
    @RunProfileCode = 'DAILY_CLEANUP'
```

### Execution Sequence
```
arch.usp_RunProfile_Prepared
  ↓ (Validates RunProfile configuration)
  ↓
arch.usp_RunConfiguredProcesses_Prepared
  ↓ (Prepares candidate records for each process)
  ↓
arch.usp_PrepareCandidates
  ↓ (Batches candidates into WorkBatch)
  ↓
arch.usp_RunPreparedBatches_InWindow
  ↓ (Executes batches within time window)
  ↓
arch.usp_RunPreparedBatch
  ↓ (Executes single batch: archive/delete/cleanup)
  ↓
arch.WorkBatchHistory (audit log)
```

### Prerequisites
- RunProfile must exist in `arch.RunProfile` table
- RunProfile must have `IsEnabled = 1`
- RunProfile must have valid `RunWindowMinutes` (> 0)
- All Process configurations must be validated (0 errors from `arch.usp_ValidateConfiguration`)

### Example: Run Daily Cleanup
```sql
-- Check if profile exists
SELECT RunProfileCode, IsEnabled, RunWindowMinutes, RunOnSchedule
FROM arch.RunProfile
WHERE RunProfileCode = 'DAILY_CLEANUP';

-- If exists and enabled, run it
EXEC arch.usp_RunProfile_Prepared
    @RunProfileCode = 'DAILY_CLEANUP';

-- Expected output
-- Prepared candidates for process X: 5000 rows
-- Batched into 50 batches of ~100 rows each
-- Executed 50 batches in 00:02:34
-- Summary: 5000 archive, 0 delete
```

### Return Codes
- **0** — Success, all batches completed
- **50001** — Configuration table/procedure missing (infrastructure error)
- **50002** — RunProfile not found or disabled
- **50003** — Invalid runtime limits (negative values, zero window, etc.)
- **50004+** — See "Legacy Procedures" section

---

## ❌ Legacy v1.0 Execution Paths (BLOCKED)

### What Are Legacy Procedures?
These are procedures from kArchiveManager v1.0. They are **no longer supported** and will be **removed in v2.1**.

### Why They're Blocked
1. **Runtime safety:** Prevents operators from accidentally using old logic in production
2. **Audit trail:** Forces all operations through the v2.0 prepared path (logged in `arch.WorkBatchHistory`)
3. **Configuration integrity:** v2.0 uses RunProfile (declarative), v1.0 uses inline parameters (procedural)

### What Happens If You Try?
```sql
-- This no longer works
EXEC arch.usp_RunProcess 
    @ProcessCode = 'SHIPPING',
    @SourceDb = 'Edge',
    @ArchiveDb = 'kArchiveManagerArchive';

-- Error:
-- Msg 50004, Level 16, State 1
-- LEGACY PROCEDURE BLOCKED. arch.usp_RunProcess is v1.0 legacy
-- compatibility only and is no longer supported. Use
-- arch.usp_RunProfile_Prepared with a configured RunProfile instead.
-- See documentation: runtime-execution-paths.md
```

### Legacy Procedures List
All these procedures now throw an error (50004, 50005, or 50006):

| Procedure | Blocked Since | Replacement |
|-----------|---------------|-------------|
| `arch.usp_RunProcess` | 2026-05-28 | Use `usp_RunProfile_Prepared` with RunProfile |
| `arch.usp_RunProcess_TimestampKeyset` | 2026-05-28 | Use `usp_RunProfile_Prepared` with RunProfile |
| `arch.usp_RunProcess_RF_LOG2` | 2026-05-28 | Use `usp_RunProfile_Prepared` with RunProfile |
| Other procedures in `arch_legacy_compatibility` | TBD v2.1 | Archived in documentation |

---

## Migration Guide

### If You Have Old Scripts Using Legacy Procedures

**Example: Old script (v1.0)**
```sql
-- OLD CODE - DO NOT USE
DECLARE @StopAtUtc datetime2(0) = DATEADD(HOUR, 1, SYSUTCDATETIME());
EXEC arch.usp_RunProcess
    @ProcessCode = 'RECEIVING',
    @SourceDb = 'Edge',
    @ArchiveDb = 'kArchiveManagerArchive',
    @StopAtUtc = @StopAtUtc,
    @DryRun = 1;
```

**Migration steps:**

1. **Create a RunProfile** in the Admin Console or with SQL:
   ```sql
   INSERT INTO arch.RunProfile (
       RunProfileCode,
       ProcessCodeFilter,
       SourceDbFilter,
       ArchiveDbFilter,
       RunWindowMinutes,
       DryRun,
       RunOnSchedule,
       IsEnabled,
       CreatedBy
   ) VALUES (
       'RECEIVING_CLEANUP',
       'RECEIVING',
       'Edge',
       'kArchiveManagerArchive',
       60,  -- Run window
       1,   -- DryRun = true initially for testing
       0,   -- Don't auto-run on schedule
       1,   -- Enabled
       SUSER_SNAME()
   );
   ```

2. **Update your script** to use the new path:
   ```sql
   -- NEW CODE - USE THIS
   EXEC arch.usp_RunProfile_Prepared
       @RunProfileCode = 'RECEIVING_CLEANUP';
   ```

3. **Test** the new script:
   - First run with `DryRun = 1` in the RunProfile
   - Verify output shows expected candidate counts
   - Check `arch.WorkBatchHistory` for audit trail
   - Update RunProfile to `DryRun = 0` when confident

4. **Remove old scripts** to prevent accidental use

### Getting Help
- Check Admin Console UI: Dashboard → Configuration → RunProfiles
- Query `arch.RunProfile` table to see all configured profiles
- Run `arch.usp_ValidateConfiguration` to check for configuration errors
- Contact your DBA if issues arise during migration

---

## Audit & Compliance

### Audit Trail
All v2.0 operations are logged in `arch.WorkBatchHistory`:

```sql
SELECT
    WorkBatchHistoryId,
    RunProfileCode,
    ProcessCode,
    SourceDb,
    ArchiveDb,
    ExecutedAtUtc,
    ExecutedBy = SUSER_SNAME(),
    RowsArchived,
    RowsDeleted,
    RowsScanned,
    DurationSeconds
FROM arch.WorkBatchHistory
WHERE ExecutedAtUtc >= DATEADD(DAY, -7, SYSUTCDATETIME())
ORDER BY ExecutedAtUtc DESC;
```

### Why Legacy Isn't Logged (To Archive)?
v1.0 legacy procedures:
- Don't use the prepared workflow
- Don't populate `arch.WorkBatchHistory`
- Have no consistent audit trail
- Are **not suitable for production**

This is why they are blocked.

---

## Operational Checklist

Before deploying to production:

- [ ] All RunProfiles configured and validated in `arch.RunProfile`
- [ ] Test scripts updated to use `arch.usp_RunProfile_Prepared`
- [ ] DBA confirmed no legacy procedures are called from scheduled jobs
- [ ] Monitoring configured to alert on error 50004 (legacy procedure calls)
- [ ] Operator runbook distributed and reviewed
- [ ] Team trained on new execution path
- [ ] Archive/delete operations run in DryRun = 1 mode first
- [ ] Audit trail verified in `arch.WorkBatchHistory`

---

## Rollback / Recovery

### If a Legacy Procedure Call Fails
You'll see:
```
Msg 50004, Level 16, State 1
LEGACY PROCEDURE BLOCKED...
```

**Action:**
1. Do NOT try to work around it
2. Identify the script that called the legacy procedure
3. Migrate it to use `arch.usp_RunProfile_Prepared` (see Migration Guide above)
4. Create or update a RunProfile to match the old parameters
5. Test with DryRun = 1 first

### If You Need Temporary Access to Legacy (Not Recommended)
Contact your DBA. They can:
1. Create a special admin procedure that temporarily re-enables legacy support
2. Only grant access to trusted users with separate audit logging
3. Set an expiration date on the override

**Do NOT** modify the SQL scripts to remove the THROW statements—this defeats the safety mechanism.

---

## Timeline

| Date | Event | Status |
|------|-------|--------|
| 2026-05-28 | Script 025 applied; legacy procedures blocked | IMPLEMENTED |
| 2026-06-04 | All team scripts migrated to v2.0 path | PENDING |
| 2026-06-11 | Production pilot uses only v2.0 path | PLANNED |
| 2026-06-30 | v2.1 removes legacy procedures entirely | PLANNED |

---

## FAQ

**Q: Will my old scripts break?**  
A: Yes, intentionally. This prevents accidents in production. Migrate to v2.0 path (see above).

**Q: Can I disable the legacy procedure blocking?**  
A: No. The blocking is enforced in the SQL procedures themselves. To remove it, you'd need to modify the scripts, which requires database ownership—and at that point, you should ask: "Why do I need legacy support?" The answer is probably "I don't; I need to update my scripts."

**Q: What if I have automated jobs that use legacy procedures?**  
A: Update them to use `arch.usp_RunProfile_Prepared` with a RunProfile. The new path is simpler and more reliable. See Migration Guide.

**Q: Is there a compatibility mode or switch?**  
A: No. v2.0 is the standard. Legacy is deprecated and will be removed in v2.1.

**Q: How long until legacy is removed?**  
A: v2.1 (estimated end of 2026). Current timeline: all v1.0 support removed.

---

## Related Documentation

- [Admin Console Frontend — Development Plan](admin-console-fe-development-plan.md) — How to configure RunProfiles in the UI
- [P1 Production Hardening Plan](p1-production-hardening-plan.md) — Section P1.3 for technical details
- [Production Timezone & Cutoff Policy](production-timezone-cutoff-policy.md) — Timestamp handling in the prepared workflow

---

**Document Owner:** Development Lead  
**Last Updated:** 2026-05-28  
**Next Review:** After v2.1 release (legacy removal complete)
