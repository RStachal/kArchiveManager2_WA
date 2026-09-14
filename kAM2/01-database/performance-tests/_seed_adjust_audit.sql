/* After seed_tested_processes.sql: enable ROW audit on the real processes (per-document
   RunDocAudit) and disable the WA_AAD smoke fixtures, so the measured run reflects the
   real processes with full auditing. */
SET NOCOUNT ON;
USE [kArchiveManagerAdmin];

UPDATE arch.Process SET AuditLevel = N'ROW', ModifiedAt = SYSUTCDATETIME()
WHERE ProcessCode NOT LIKE N'WA[_]AAD[_]%';

UPDATE arch.Process SET IsEnabled = 0, ModifiedAt = SYSUTCDATETIME()
WHERE ProcessCode LIKE N'WA[_]AAD[_]%';

-- belt-and-braces: also disable any WA_AAD ProcessDatabase mappings
UPDATE pd SET pd.IsEnabled = 0
FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId = pd.ProcessId
WHERE p.ProcessCode LIKE N'WA[_]AAD[_]%';

PRINT '=== effective enabled mappings + audit level (post-adjust) ===';
SELECT e.ProcessCode, e.SourceDb, e.ArchiveDb, e.Mode, e.SelectionStrategy, e.AuditLevel, e.RunOrder
FROM arch.v_ProcessDatabaseEffective e
WHERE e.IsEnabled = 1
ORDER BY e.RunOrder, e.SourceDb, e.ProcessCode;
