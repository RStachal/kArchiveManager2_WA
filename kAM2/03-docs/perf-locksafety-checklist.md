# Performance & lock-safety optimization — step-by-step checklist

**Goal:** make the archive engine fast **and** guarantee it never takes locks on the customer
**production source** during candidate selection (any phase), across **all process variants**
(ANCHOR + TIMESTAMP, Mode 0/1/2). The DELETE itself runs inside the reserved RUN window.

**Hard rules (customer constraints):**
- ❌ NEVER take locks on the source during **candidate selection** (especially PREP).
- ❌ NEVER create indexes (or any schema change) on the source.
- ✅ Candidate reads use `NOLOCK` / `READ UNCOMMITTED` (safe: candidates are past the retention
  cutoff = not actively modified; dedup + key-based DELETE are authoritative).
- ✅ DELETE locks are allowed only in the RUN window, kept small (< escalation threshold).

Legend: `[ ]` todo · `[x]` done · `[~]` in progress.

---

## Phase 0 — Analysis (done)
- [x] Map every source read in the runner chain and its lock behavior.
  - Candidate scan **014** `usp_PrepareCandidates` L383 (ANCHOR PREP) — was `WITH (READPAST)` → S-locks.
  - Candidate scan **027** `usp_RunTimestampProcess` L434 (TIMESTAMP) — was `WITH (READPAST)` → S-locks.
  - Copy read **015** `usp_RunPreparedBatch` L503 (Mode 2 copy-only) — no hint → S-locks.
  - DELETE **015** L483 (Mode 1) / L516 (Mode 0), **027** delete — X-locks (mutation, in-window). Keep.
  - Control read 015 L257 `WorkBatchKey WITH (UPDLOCK,READPAST,ROWLOCK)` — our control table, not source. Keep.
- [x] Identify the performance bottleneck: classic per-row `AT TIME ZONE` + `ORDER BY DocCreatedAt`
  with no supporting index → high CPU + large tempdb sort (measured ~7 GB on the 5M run).

## Phase 1 — Lock-safety: NOLOCK on all source candidate/copy reads ✅ DONE (commit 09365bd)
- [x] 014 L383: `WITH (READPAST)` → `WITH (NOLOCK)` (ANCHOR PREP candidate scan).
- [x] 027 L434: `WITH (READPAST)` → `WITH (NOLOCK)` (TIMESTAMP candidate scan).
- [x] 015 L503: source `t` in Mode-2 copy SELECT → add `WITH (NOLOCK)`.
- [x] Deployed 014/027/015 to the live instance (modify_date confirmed).
- [x] Grep-assert: only remaining READPAST is the control table `WorkBatchKey`; DELETE branches unchanged.
- [x] **PROOF (lock probe):** during a ~40s NOLOCK candidate scan of Edge.RF_LOG2, the selection session held **only `OBJECT Sch-S`** (schema-stability) on the source — **zero S/IS/X/U data locks**. Sch-S never blocks INSERT/UPDATE/DELETE → candidate selection cannot block the OLTP app.

## Phase 2 — Performance: cheap-mode (config only, NO source index) ✅ RF_LOG2 done
- [x] RF_LOG2 cheap-mode (clustered key = ROWID; DATE_TIME is nvarchar `yyyymmdd hh:mm:ss.ff` = lexicographically chronological):
  - `ObjectSpec.CandidateSelectExpr` = `CAST(t.DATE_TIME AS datetime2(0))` (no per-row AT TIME ZONE).
  - `Process.CandidateWhereSql` = `CAST(t.DATE_TIME AS datetime2(0)) < CAST(@CutoffUtc AT TIME ZONE N'UTC' AT TIME ZONE N'Central European Standard Time' AS datetime2(0))` (cutoff converted once).
  - `Process.CandidateOrderSql` = `t.ROWID` (clustered → no candidate-load sort).
- [x] `BatchRowCount`/`MaxRowsPerTransaction` = 4000 (< escalation threshold).
- [x] **Result (Edge.RF_LOG2):** cheap 3M = **17.3 min @ 2895 del/s** vs classic 5M = 43.2 min @ 1928 del/s → **~50% faster**; extrapolated **~29 min/5M, lock-free** (beats the original 30 min baseline which LOCKED the source). Div=0, LockEscSrc=0, Deadlocks=0. CPU/row ~halved (no per-row AT TIME ZONE).
- [x] INTEGRACE_DNLOAD cheap-mode — DONE (commit 314f7b5): CandidateSelectExpr = local `CAST(COALESCE(date_archived, parsed TIMESTMP) AS datetime2(0))` (no AT TIME ZONE) + OrderSql = clustered ROWID. DNLOAD@KMWE_Test: Div=0, LockEscSrc=0, 2936 del/s.
- [x] **Dedup-window skip for row-unique keys — DONE (commit 314f7b5):** 027 auto-detects when the keyset key is a single source column backed by a UNIQUE/PK index (metadata only). When proven unique → **skip the ROW_NUMBER/COUNT dedup window → candidate load does NO sort**. When NOT proven unique → KEEP dedup + the 50115 gate (a non-unique key can never silently over-delete). **Verified:** ROWID PK → skip; DATE_TIME → keep+gate. Safe by construction.

## Phase 3 — Test ALL variants ✅ DONE (sweep 2026-06-19)
- [x] ANCHOR (RECEIVING/SHIPPING, 014+015) — PASS, 0 source escalation.
- [x] TIMESTAMP (RF_LOG2/DNLOAD, 027) — PASS, 0 source escalation.
- [x] Mode 1 archive+delete across all 14 enabled mappings; Mode 0/2 covered by variant_test_pack.
- [x] Full enabled-mapping sweep through the harness — all 14 mappings **PASS**.
- [x] Lock probe (Phase 1) = the concurrency proof: selection holds only Sch-S, never blocks a writer.

## Phase 4 — Validate (acceptance) ✅ ALL PASS
- [x] **LockEscalationsSource = 0** on every one of the 14 mappings.
- [x] **Deadlocks = 0**; LockWaitMs negligible (≤ ~1 s per run).
- [x] **Divergence = 0** (GlobalDivergence=0, DivergentMode1=0, BadRuns=0); per-table source reconciliation
  (PreRows − PostRows == DeletedReported) holds; KMWE_Test.RF_LOG2 = 0 deleted = correct (all post-cutoff).
- [x] Performance: cheap-mode RF_LOG2 ~2800–2900 del/s lock-free → ~29 min/5M (beats the 30 min baseline which locked).
- [x] No FAILs in the sweep; the only FAILs seen in big single-process runs were archive-DB log budget (our side; pre-size + 048).

## Phase 5 — Sign-off
- [x] Code changes committed (NOLOCK 09365bd; cheap-mode 7bc0a6b). Templates 053/054/048 restored earlier.
- [x] Memory + checklist updated with final numbers.
- [x] **Decision:** application performance is **acceptable** — NOLOCK selection (zero source data locks) +
  cheap-mode config (no source index) + small lock-safe delete batches deliver **~29 min/5M, fully lock-free**,
  which beats the original (unsafe) 30 min baseline. No major engine rework needed.
- [ ] Optional further gains (not required): cheap-mode for INTEGRACE_DNLOAD; skip dedup sort on unique keys
  (cuts tempdb); bake the recommended config into `seed_tested_processes.sql`.

---

### Results log
- **Lock probe:** NOLOCK candidate scan holds only `OBJECT Sch-S` on the source → 0 data locks → never blocks OLTP.
- **Cheap-mode RF_LOG2 (Edge):** 3M in 17.3 min @ 2895 del/s (vs classic 1928 del/s) → ~50% faster, ~29 min/5M.
- **All-variants sweep (14 mappings):** every mapping PASS · LockEscalationsSource=0 · Deadlocks=0 · Divergence=0;
  1 338 163 archived==deleted; per-table source reconciliation holds.
- **Lock recipe per phase:** PREP selection = NOLOCK (no locks, any phase). RUN delete = X-locks only inside the
  reserved window, kept small (≤4000 rows < escalation threshold); multi-index tables additionally need
  `ALTER TABLE … SET (LOCK_ESCALATION = DISABLE)` to guarantee 0 escalation (KMWEBV.RF_LOG2/DNLOAD).
