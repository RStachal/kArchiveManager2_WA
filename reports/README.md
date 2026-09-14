# Reporting

Two things live here, and they are not equivalent.

1. **The reporting layer that ships with kArchiveManager 2.0** — 20
   `arch.usp_Frontend_*` procedures, `arch.usp_Api_EstimateNextRunImpact` and six
   views. It is driven entirely by `arch.Process` / `arch.ObjectSpec`, so it
   describes whatever is configured, on any schema, carrying no table names of its
   own. **This is the reporting for this deployment.** Verify it with
   [`../sql/50_reporting.sql`](../sql/50_reporting.sql).

2. **`ArchiveManager - DataMovement Dashboard v2.rdl`** — the SSRS dashboard from
   the product repository, copied here unchanged except for the connection string.
   **Most of its panels do not work against this deployment.** Read the finding
   below before spending time on it.

---

## The finding: the dashboard predates this product version

The report was last changed on **15 May 2026**. The 2.0 cleanup that retired the
procedures two of its panels call happened on **28 May 2026**, thirteen days
later, in `032_archive_legacy_procedures.sql`. The report was never updated, and
it was written against a **different customer's WMS schema** — it contains table
names (`SHIPHIST`, `RF_LOG2`) and a column (`DATE_UPLD`) that do not exist in
Warehouse Advantage.

Every dataset was executed against this deployment. Results:

| Dataset | Against this deployment | Why |
|---|---|---|
| `dsReportContext` | **works** | reads `arch.v_ProcessDatabaseEffective` |
| `dsProcessConfig` | **works** — all 6 sets | reads `arch.Process` |
| `dsTableCounts` | **works** — 132 rows | probes columns with `COL_LENGTH` and adapts |
| `dsProcessedByRunDayAndTable` | **works** — 147 rows | legacy names appear only in a sort `CASE` |
| `dsDocLookupSummary` | **works** | reads `arch.RunDocAudit` |
| `dsDocLookupDetails` | **works** | reads `arch.RunDocAudit` |
| `dsDailyArchivedHistory` | **silently empty** | whitelists `SHIPHIST`, `SHIPLINE`, `RF_LOG2` by name |
| `dsProcessSummary` | **partial** | hardcoded `ProcessCode → table` mapping for `RECEIVING` / `SHIPPING` / `RF_LOG2` |
| `dsDeleteBacklogByDay` | **silently empty** | joins `dbo.SHIPHIST` on `DATE_UPLD` |
| `dsDeleteBacklogSummary` | **fails** `Msg 208` | `Invalid object name 'AAD.dbo.SHIPHIST'` |
| `dsEstimateSummary` | **fails** `Msg 2812` | calls `arch.usp_EstimateLatestWorkBatchImpact` |
| `dsEstimateDetail` | **fails** `Msg 2812` | same procedure |
| `dsEstimateRFLOG2` | **dead** | targets `usp_EstimateCurrentProcessImpact_RF_LOG2` |

Six work, four are silently wrong, three fail outright.

**The silent four are the dangerous ones.** A panel that throws gets fixed; a
panel that renders an empty chart gets believed. `dsDeleteBacklogByDay` and
`dsDailyArchivedHistory` will draw a clean, empty graph on a system that is
archiving hundreds of thousands of rows a day.

### About the two retired procedures

`032_archive_legacy_procedures.sql` lists them explicitly as dead code and moves
them out of `arch` into `legacy_v1`:

> 9. `usp_EstimateLatestWorkBatchImpact` (orphan)
> 10. `usp_EstimateCurrentProcessImpact_RF_LOG2` (orphan, WMS-specific)

On this instance they are not in `legacy_v1` either — a clean 2.0 install never
creates them, and `usp_Frontend_GoLiveReadiness` confirms `legacy_v1 + v1-stub
objects: 0`. **Do not re-create them to make the report run.** Their 2.0
replacement is `arch.usp_Api_EstimateNextRunImpact`, which is deployed and takes
`@SourceDb`, `@ArchiveDb`, `@ProcessCode`, `@IncludeDisabled`,
`@ArchiveGrowthFactor`, `@LogMultiplier`, `@SafetyFactor`.

---

## What to use instead

Every panel in the dashboard has a live, schema-agnostic equivalent:

| Dashboard panel | Use instead |
|---|---|
| Process configuration | `arch.usp_Frontend_GetProcessConfigSummary` |
| Per-set movement | `arch.usp_Frontend_GetProcessMovementSummary` |
| Per-table movement | `arch.usp_Frontend_GetTableMovementCounts` |
| Processed history by day | `arch.usp_Frontend_GetProcessedHistory` |
| Recent runs / run detail | `arch.usp_Frontend_GetRecentRuns`, `...GetRunDetail` |
| Document lookup | `arch.usp_Frontend_SearchDocumentAuditSummary`, `...Details` |
| Delete backlog | `arch.usp_Frontend_TimestampRetentionGaps` |
| Estimates | `arch.usp_Api_EstimateNextRunImpact` |
| Work batch activity | `arch.usp_Frontend_GetWorkBatchActivity` |
| Readiness / health | `arch.usp_Frontend_GoLiveReadiness`, `arch.v_OperationalHealth` |

All of them take `NULL` as "no filter" and were executed against this deployment
by `50_reporting.sql` — 19 of 19 passed.

---

## Deploying the dashboard anyway

If the customer wants this specific layout, treat it as a **starting point that
needs six datasets rewritten**, not as a finished artefact.

1. Open it in Report Builder or Visual Studio (SSRS 2016 schema).
2. Point `DataSource1` at the customer instance — the connection string in this
   copy is deliberately `REPLACE_WITH_YOUR_SQL_INSTANCE`.
3. Rewrite the seven datasets listed as *silently wrong*, *fails* or *dead* to
   call the procedures in the table above. Keep each dataset's **output column
   names unchanged** — the tablix bindings reference them by name, so a renamed
   column silently blanks a column in the rendered report.
4. Deploy to the Report Server (`rs.exe`, the web portal, or Visual Studio).
   SSRS is present and running on the reference instance
   (`SQLServerReportingServices`).
5. Re-run `50_reporting.sql` afterwards and compare its section C totals against
   what the dashboard renders. They must agree.

### Two artefacts that are not bugs

- **`t_work_q_dependency` appears twice** in per-table output. The work-queue set
  configures it twice on purpose — once joined on `parent_work_q_id`, once on
  `dependent_work_q_id` — so both sides of a dependency are archived with their
  queue. One row per `ObjectSpec` means the table is listed twice with identical
  counts. Do not `SUM` that column without a `DISTINCT` on the table name.
- **`ADV_LOGMSG_ARCH` shows a negative difference** (archive holds more than
  source). Warehouse Advantage purges `t_log_message` itself, so source rows
  disappear without us while the archive accumulates. That is the expected steady
  state, not a reconciliation failure.
