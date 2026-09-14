/* ============================================================================
   045 — Audit immutability hardening (audit task T-09)
   ============================================================================
   PROBLEM: the forensic trail of every deletion (arch.RunDocAudit) and the config-change records
   are fully mutable — no triggers, no temporal/ledger, no DENY. Any principal with direct DML
   (e.g. the over-privileged orphan [IIS APPPOOL\Console] which holds db_datawriter, or a future
   db_datawriter grant) can UPDATE/DELETE the audit after the fact, voiding the "reconstructable"
   guarantee for irreversible deletes.

   FIX (access control): DENY UPDATE/DELETE to public on the append-only audit/forensic tables.
     - Procedures keep working: the runners only INSERT into these tables, and INSERT is not denied;
       proc-mediated DML also runs under ownership chaining (proc owner = table owner = dbo), which
       is not affected by table DENY.
     - dbo / sysadmin are NOT affected (they bypass all permission checks), so controlled
       maintenance (retention purge T-21, test reset) still works under an elevated identity.
     - The orphan / any db_datawriter principal IS blocked from ad-hoc tampering (DENY overrides GRANT).

   SCOPE (only truly append-only objects are locked; tables that the runner legitimately UPDATEs are
   left writable, only their DELETE is denied since the app never deletes them in normal operation):
     RunDocAudit, ConfigChangeField, ConfigChangeItem  -> DENY UPDATE, DELETE (written once)
     ConfigChangeSet                                    -> DENY DELETE      (status is updated DRAFT->PUBLISHED)
     Run, RunItem, RunItemObject                        -> DENY DELETE      (status/counters are updated)

   NOTE: this is access-control hardening, not cryptographic tamper-EVIDENCE. For a tamper-evident
   trail on SQL Server 2022, convert RunDocAudit (and the ConfigChange* tables) to updatable LEDGER
   tables — tracked as a larger follow-up. Combine with task T-01 (remove the orphan logins).

   Idempotent (DENY is repeatable). Safe to run anytime; no data change.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET NOCOUNT ON;
GO

-- Append-only forensic / change-detail tables: never updated or deleted in normal operation.
IF OBJECT_ID(N'arch.RunDocAudit', N'U') IS NOT NULL      DENY UPDATE, DELETE ON arch.RunDocAudit      TO public;
IF OBJECT_ID(N'arch.ConfigChangeField', N'U') IS NOT NULL DENY UPDATE, DELETE ON arch.ConfigChangeField TO public;
IF OBJECT_ID(N'arch.ConfigChangeItem', N'U') IS NOT NULL  DENY UPDATE, DELETE ON arch.ConfigChangeItem  TO public;
GO

-- Tables whose rows are legitimately UPDATEd (status/counters/lifecycle) but never DELETEd by the app.
IF OBJECT_ID(N'arch.ConfigChangeSet', N'U') IS NOT NULL DENY DELETE ON arch.ConfigChangeSet TO public;
IF OBJECT_ID(N'arch.Run', N'U') IS NOT NULL            DENY DELETE ON arch.Run            TO public;
IF OBJECT_ID(N'arch.RunItem', N'U') IS NOT NULL        DENY DELETE ON arch.RunItem        TO public;
IF OBJECT_ID(N'arch.RunItemObject', N'U') IS NOT NULL  DENY DELETE ON arch.RunItemObject  TO public;
GO

PRINT '045_audit_immutability deployed (DENY UPDATE/DELETE on append-only audit tables; DENY DELETE on lifecycle tables).';
GO
