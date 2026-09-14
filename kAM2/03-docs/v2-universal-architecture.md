# kArchiveManager 2.0 universal architecture

Goal: make archive/delete behavior metadata-driven across customer-specific data models, without process-specific delete procedures.

## Core Principle

Every process should run in three explicit phases:

1. Select candidates into a resumable keyset.
2. Archive configured objects from the source database into the archive database.
3. Delete source rows by joining to the materialized keyset.

The runner must not repeatedly scan large source tables with generic `DELETE TOP` predicates.

## Selection Strategies

| Strategy | Use when | Required performance shape |
| --- | --- | --- |
| `ANCHOR` | Parent/child document models | Seek/range on anchor, indexed joins from children to keyset |
| `KEYSET` | Customer or upstream process supplies IDs | Keyset loaded into `WorkBatchKey`, indexed joins by configured keys |
| `RANGE` | Monotonic ID, sequence, or row number cleanup | Range seek on the key column |
| `TIMESTAMP` | Time retention for logs/history | Sargable timestamp predicate backed by index |
| `PARTITION` | Large time-partitioned tables | Partition switch/truncate where schema allows it |
| `CUSTOM_QUERY` | Unusual customer model | Reviewed query emitting standard key columns |
| `ORPHAN` | Child rows without parent | Indexed anti-join, never unindexed `NOT EXISTS` over large tables |
| `SOFT_DELETE` | Status/flag-driven cleanup | Indexed status/flag plus optional cutoff |

## Metadata Added for 2.0

- `arch.Process.SelectionStrategy`
- `arch.Process.AuditLevel`
- `arch.Process.RequireSupportingIndex`
- `arch.Process.MaxRowsPerTransaction`
- `arch.Process.CandidateWhereSql`
- `arch.Process.CandidateOrderSql`
- `arch.ProcessKeySpec`
- `arch.IndexRequirement`
- extended `arch.WorkBatchKey` with `Key3` through `Key8` and `CandidateHash`

## Runner Direction

The current 1.0 `WorkBatch` model is the right foundation. For 2.0, the specific `PrepWorkBatch_Receiving` and `PrepWorkBatch_Shipping` procedures should be replaced by a generic candidate-prep procedure that understands `SelectionStrategy`.

Proposed new procedures:

- `arch.usp_PrepareCandidates`
- `arch.usp_ExplainProcessPlan`
- `arch.usp_ValidateIndexRequirements`
- `arch.usp_RunPreparedBatch`

The existing `arch.usp_RunWorkBatch` can be evolved into `arch.usp_RunPreparedBatch` after the candidate key model is stable.

## Current 2.0 Scripts

- `v2/010_universal_archive_core.sql`: adds universal metadata and keyset extensions.
- `v2/011_usp_ValidateIndexRequirements.sql`: validates declared source index requirements.
- `v2/012_usp_ExplainProcessPlan.sql`: prints the process strategy, objects, keys, and index expectations.
- `v2/013_seed_wms_anchor_requirements.sql`: maps current `RECEIVING` and `SHIPPING` processes to the generic `ANCHOR` model.
- `v2/014_usp_PrepareCandidates.sql`: generic candidate-prep implementation for `ANCHOR` and `TIMESTAMP`.
- `v2/015_usp_RunPreparedBatch.sql`: 2.0 prepared-batch archive/delete runner with row audit controlled by `AuditLevel`.
- `v2/016_usp_RunPreparedBatches.sql`: windowed prepared-batch runner and configured-process wrapper.
- `v2/017_seed_rf_log2_timestamp.sql`: maps `RF_LOG2` to the first `TIMESTAMP` pilot over `DATE_TIME`, with default key audit disabled through `AuditLevel = N'NONE'`.
- `v2/018_seed_integration_archive_timestamp.sql`: maps `INTEGRACE_DNLOAD` and `INTEGRACE_UPLOAD` to TIMESTAMP cleanup processes.
- `v2/022_effective_database_overrides.sql`: adds database-specific runtime overrides and effective configuration views.
- `v2/023_monitoring_views.sql`: adds current monitoring views for recent and latest runs.
