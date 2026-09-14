# kArchiveManager 2.0 — Audit Model

**Status:** Adopted for pilot (P1.2, Option A)
**Owner:** Radim Stachal / KODYS
**Related:** [p1-production-hardening-plan.md](p1-production-hardening-plan.md) §P1.2

---

## Model: Batch-level audit (per process, configurable)

kArchiveManager 2.0 records archive/delete operations at **batch level** by default.
This document states the product promise honestly so nobody assumes a per-document
guarantee that is not in force.

**What is captured**

- Each run/work-batch records who ran it, when, which process and source/archive
  database, the cutoff window, and how many rows were archived vs deleted
  (`arch.Run`, `arch.RunItem`, `arch.RunItemObject`).
- The per-process **`AuditLevel`** controls granularity: `NONE`, `BATCH` (default),
  `OBJECT`, or `ROW`. Pilot processes run at `BATCH` (or `NONE` for high-volume
  `RF_LOG2` to avoid bloating the Admin DB during large deletes).

**Per-document (ROW) audit**

- The row-level table `arch.RunDocAudit` and the Admin Console **Document lookup**
  screen provide per-document traceability ("when was document X archived?").
- This is **only populated when a process runs at `AuditLevel = ROW`/`OBJECT`.**
  At the pilot default (`BATCH`/`NONE`), `arch.RunDocAudit` is empty and Document
  lookup will not find archived documents.

**Product promise (pilot):** "We can show that a batch of records was archived by a
given run, with full run attribution." We do **not** promise per-document lookup unless
the relevant process is explicitly configured for ROW/OBJECT audit.

---

## Suitable / not suitable

✅ Suitable for:
- Internal operational audit — proving a run archived/deleted N rows of a process.
- Compliance goals stated at batch granularity.

❌ Not sufficient (at default BATCH level) for:
- "Find the exact run that archived document X" across all processes.
- Regulatory requirements mandating a per-record audit trail for every process.

---

## Cost trade-off

ROW-level audit produces roughly 100–1000× more audit rows than BATCH (one row per
archived document vs one per batch). Enable it per process only where per-document
traceability is genuinely required; keep high-volume processes at BATCH/NONE.

---

## How to enable per-document audit where needed

1. Set the process (or per-database override) `AuditLevel = ROW` (or `OBJECT`) in the
   Admin Console configuration editor.
2. Confirm `arch.RunDocAudit` is being populated after the next run.
3. Use the **Document lookup** screen to verify per-document traceability.

See `p1-production-hardening-plan.md` §P1.2 Option B for the schema/insert sketch if a
broader ROW-audit rollout is required.

---

## Decision log

| Date | Decision | Owner | Status |
|------|----------|-------|--------|
| 2026-05-28 | Promise batch-level audit for pilot (Option A) | Radim Stachal | ADOPTED |
| 2026-06-01 | Document the model honestly in this file | Development | DONE |
| TBD | Broader ROW-level audit rollout if regulated | Development | DEFERRED |
