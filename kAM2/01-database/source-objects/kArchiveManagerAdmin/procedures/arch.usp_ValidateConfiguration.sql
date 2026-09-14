USE [kArchiveManagerAdmin]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [arch].[usp_ValidateConfiguration]
    @ProcessCode sysname = NULL,
    @SourceDb sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Findings
    (
        Severity varchar(10) NOT NULL,
        ProcessCode sysname NULL,
        SourceDb sysname NULL,
        ArchiveDb sysname NULL,
        ObjectName nvarchar(300) NULL,
        Finding nvarchar(4000) NOT NULL,
        SuggestedSql nvarchar(max) NULL,   -- concrete remediation SQL the operator can copy/run
        ActionKey nvarchar(60) NULL        -- when set, a safe one-click remediation exists (Console "Apply"); dispatched by arch.usp_Api_ApplyConfigFix
    );

    INSERT #Findings(Severity, ProcessCode, Finding)
    SELECT 'ERROR', p.ProcessCode, N'Process is enabled but has no ObjectSpec rows.'
    FROM arch.Process p
    WHERE p.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND NOT EXISTS (SELECT 1 FROM arch.ObjectSpec os WHERE os.ProcessId = p.ProcessId);

    INSERT #Findings(Severity, ProcessCode, Finding)
    SELECT 'ERROR', p.ProcessCode, N'Process is enabled but has no enabled ProcessDatabase mapping.'
    FROM arch.Process p
    WHERE p.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND NOT EXISTS
      (
          SELECT 1
          FROM arch.ProcessDatabase pd
          WHERE pd.ProcessId = p.ProcessId
            AND pd.IsEnabled = 1
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'WARN',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        N'Redundant database override in arch.ProcessDatabase: ' + v.ConfigName
        + N' equals the arch.Process default. Keep this ProcessDatabase column NULL unless the database intentionally differs.'
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    CROSS APPLY
    (
        VALUES
            (N'Mode', CASE WHEN pd.Mode IS NOT NULL AND pd.Mode = p.Mode THEN 1 ELSE 0 END),
            (N'RetentionDays', CASE WHEN pd.RetentionDays IS NOT NULL AND pd.RetentionDays = p.RetentionDays THEN 1 ELSE 0 END),
            (N'CutoffSafetyLagMinutes', CASE WHEN pd.CutoffSafetyLagMinutes IS NOT NULL AND pd.CutoffSafetyLagMinutes = p.CutoffSafetyLagMinutes THEN 1 ELSE 0 END),
            (N'CutoffMode', CASE WHEN pd.CutoffMode IS NOT NULL AND pd.CutoffMode = p.CutoffMode THEN 1 ELSE 0 END),
            (N'CutoffDate', CASE WHEN pd.CutoffDate IS NOT NULL AND pd.CutoffDate = p.CutoffDate THEN 1 ELSE 0 END),
            (N'BatchDocCount', CASE WHEN pd.BatchDocCount IS NOT NULL AND pd.BatchDocCount = p.BatchDocCount THEN 1 ELSE 0 END),
            (N'BatchRowCount', CASE WHEN pd.BatchRowCount IS NOT NULL AND pd.BatchRowCount = p.BatchRowCount THEN 1 ELSE 0 END),
            (N'MaxBatchesPerRun', CASE WHEN pd.MaxBatchesPerRun IS NOT NULL AND pd.MaxBatchesPerRun = p.MaxBatchesPerRun THEN 1 ELSE 0 END),
            (N'DelayMsBetweenBatches', CASE WHEN pd.DelayMsBetweenBatches IS NOT NULL AND pd.DelayMsBetweenBatches = p.DelayMsBetweenBatches THEN 1 ELSE 0 END),
            (N'UseAppLock', CASE WHEN pd.UseAppLock IS NOT NULL AND pd.UseAppLock = p.UseAppLock THEN 1 ELSE 0 END),
            (N'AppLockResource', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AppLockResource)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AppLockResource)), N'') = NULLIF(LTRIM(RTRIM(p.AppLockResource)), N'') THEN 1 ELSE 0 END),
            (N'LockTimeoutMs', CASE WHEN pd.LockTimeoutMs IS NOT NULL AND pd.LockTimeoutMs = p.LockTimeoutMs THEN 1 ELSE 0 END),
            (N'DeadlockPriority', CASE WHEN NULLIF(LTRIM(RTRIM(pd.DeadlockPriority)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.DeadlockPriority)), N'') = NULLIF(LTRIM(RTRIM(p.DeadlockPriority)), N'') THEN 1 ELSE 0 END),
            (N'AnchorSchema', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorSchema)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorSchema)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorSchema)), N'') THEN 1 ELSE 0 END),
            (N'AnchorTable', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorTable)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorTable)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorTable)), N'') THEN 1 ELSE 0 END),
            (N'AnchorDocKeyExpr', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorDocKeyExpr)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorDocKeyExpr)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorDocKeyExpr)), N'') THEN 1 ELSE 0 END),
            (N'AnchorDocKey2Expr', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorDocKey2Expr)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorDocKey2Expr)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorDocKey2Expr)), N'') THEN 1 ELSE 0 END),
            (N'AnchorTimestampExpr', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorTimestampExpr)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorTimestampExpr)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorTimestampExpr)), N'') THEN 1 ELSE 0 END),
            (N'AnchorExtraWhereSql', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AnchorExtraWhereSql)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AnchorExtraWhereSql)), N'') = NULLIF(LTRIM(RTRIM(p.AnchorExtraWhereSql)), N'') THEN 1 ELSE 0 END),
            (N'AllowDeleteWithoutArchive', CASE WHEN pd.AllowDeleteWithoutArchive IS NOT NULL AND pd.AllowDeleteWithoutArchive = p.AllowDeleteWithoutArchive THEN 1 ELSE 0 END),
            (N'DocKeyLabel', CASE WHEN NULLIF(LTRIM(RTRIM(pd.DocKeyLabel)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.DocKeyLabel)), N'') = NULLIF(LTRIM(RTRIM(p.DocKeyLabel)), N'') THEN 1 ELSE 0 END),
            (N'AuditLevel', CASE WHEN NULLIF(LTRIM(RTRIM(pd.AuditLevel)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.AuditLevel)), N'') = NULLIF(LTRIM(RTRIM(p.AuditLevel)), N'') THEN 1 ELSE 0 END),
            (N'RequireSupportingIndex', CASE WHEN pd.RequireSupportingIndex IS NOT NULL AND pd.RequireSupportingIndex = p.RequireSupportingIndex THEN 1 ELSE 0 END),
            (N'MaxRowsPerTransaction', CASE WHEN pd.MaxRowsPerTransaction IS NOT NULL AND pd.MaxRowsPerTransaction = p.MaxRowsPerTransaction THEN 1 ELSE 0 END),
            (N'CandidateWhereSql', CASE WHEN NULLIF(LTRIM(RTRIM(pd.CandidateWhereSql)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.CandidateWhereSql)), N'') = NULLIF(LTRIM(RTRIM(p.CandidateWhereSql)), N'') THEN 1 ELSE 0 END),
            (N'CandidateOrderSql', CASE WHEN NULLIF(LTRIM(RTRIM(pd.CandidateOrderSql)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(pd.CandidateOrderSql)), N'') = NULLIF(LTRIM(RTRIM(p.CandidateOrderSql)), N'') THEN 1 ELSE 0 END)
    ) AS v(ConfigName, IsRedundant)
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND v.IsRedundant = 1;

    -- CRITICAL SAFETY: oversized per-transaction delete batch -> lock escalation on the PRODUCTION source.
    -- SQL Server escalates a statement's row locks to a TABLE X lock at ~5000 locks; a per-batch DELETE of
    -- more than that many source rows therefore takes an exclusive lock on the whole source table and BLOCKS
    -- OLTP for the batch duration (proven live: 50000-row batch -> OBJECT X lock + blocked readers; 4000 -> safe).
    -- Block go-live for any enabled mapping whose effective per-transaction ROW cap exceeds the safe limit.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        N'Per-transaction delete batch is too large ('
          + CONVERT(nvarchar(20), (SELECT MAX(v) FROM (VALUES
                (COALESCE(pd.BatchRowCount, p.BatchRowCount)),
                (COALESCE(pd.BatchDocCount, p.BatchDocCount)),
                (COALESCE(pd.MaxRowsPerTransaction, p.MaxRowsPerTransaction))) AS x(v)))
          + N' rows). A single DELETE of that many rows can escalate to a TABLE X lock on the production source '
          + N'and block OLTP for the batch duration. Keep BatchRowCount, BatchDocCount and MaxRowsPerTransaction <= 4000 '
          + N'and raise MaxBatchesPerRun to keep throughput (e.g. 4000 x 250 = 1,000,000 rows per run). '
          + N'(The runner also hard-caps the per-transaction delete at 4000 as a backstop.)'
    FROM arch.ProcessDatabase pd
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND (   COALESCE(pd.BatchRowCount, p.BatchRowCount, 0) > 4000
           OR COALESCE(pd.BatchDocCount, p.BatchDocCount, 0) > 4000
           OR COALESCE(pd.MaxRowsPerTransaction, p.MaxRowsPerTransaction, 0) > 4000);

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'WARN',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        N'Global arch.Process CutoffDate is active for a process with multiple enabled database mappings. Prefer setting CutoffMode/CutoffDate in arch.ProcessDatabase when cutoffs are database-specific.'
    FROM arch.Process p
    JOIN arch.ProcessDatabase pd
      ON pd.ProcessId = p.ProcessId
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND p.CutoffMode = 1
      AND p.CutoffDate IS NOT NULL
      AND pd.CutoffMode IS NULL
      AND pd.CutoffDate IS NULL
      AND 1 <
      (
          SELECT COUNT_BIG(*)
          FROM arch.ProcessDatabase pd2
          WHERE pd2.ProcessId = p.ProcessId
            AND pd2.IsEnabled = 1
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'WARN',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        QUOTENAME(COALESCE(NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N''), os.SourceSchema))
        + N'.' + QUOTENAME(COALESCE(NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N''), os.SourceTable)),
        N'Redundant object override in arch.ObjectSpecDatabaseOverride: ' + v.ConfigName
        + N' equals the arch.ObjectSpec default. Keep this override column NULL unless the database/table intentionally differs.'
    FROM arch.ObjectSpecDatabaseOverride osdo
    JOIN arch.ProcessDatabase pd
      ON pd.ProcessDatabaseId = osdo.ProcessDatabaseId
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    JOIN arch.ObjectSpec os
      ON os.ObjectSpecId = osdo.ObjectSpecId
     AND os.ProcessId = p.ProcessId
    CROSS APPLY
    (
        VALUES
            (N'SourceSchemaOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.SourceSchemaOverride)), N'') = NULLIF(LTRIM(RTRIM(os.SourceSchema)), N'') THEN 1 ELSE 0 END),
            (N'SourceTableOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.SourceTableOverride)), N'') = NULLIF(LTRIM(RTRIM(os.SourceTable)), N'') THEN 1 ELSE 0 END),
            (N'TimestampExprOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.TimestampExprOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.TimestampExprOverride)), N'') = NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') THEN 1 ELSE 0 END),
            (N'JoinToAnchorPredicateSqlOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.JoinToAnchorPredicateSqlOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.JoinToAnchorPredicateSqlOverride)), N'') = NULLIF(LTRIM(RTRIM(os.JoinToAnchorPredicateSql)), N'') THEN 1 ELSE 0 END),
            (N'AdditionalWhereSqlOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.AdditionalWhereSqlOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.AdditionalWhereSqlOverride)), N'') = NULLIF(LTRIM(RTRIM(os.AdditionalWhereSql)), N'') THEN 1 ELSE 0 END),
            (N'ArchiveSchemaOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.ArchiveSchemaOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.ArchiveSchemaOverride)), N'') = NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') THEN 1 ELSE 0 END),
            (N'ArchiveTableOverride', CASE WHEN NULLIF(LTRIM(RTRIM(osdo.ArchiveTableOverride)), N'') IS NOT NULL AND NULLIF(LTRIM(RTRIM(osdo.ArchiveTableOverride)), N'') = NULLIF(LTRIM(RTRIM(os.ArchiveTable)), N'') THEN 1 ELSE 0 END),
            (N'RequireArchiveForDeleteOverride', CASE WHEN osdo.RequireArchiveForDeleteOverride IS NOT NULL AND osdo.RequireArchiveForDeleteOverride = os.RequireArchiveForDelete THEN 1 ELSE 0 END)
    ) AS v(ConfigName, IsRedundant)
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND osdo.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND v.IsRedundant = 1;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        p.ProcessCode,
        pd.SourceDb,
        pd.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'ObjectSpecDatabaseOverride points to an ObjectSpec from a different process than its ProcessDatabase mapping.'
    FROM arch.ObjectSpecDatabaseOverride osdo
    JOIN arch.ProcessDatabase pd
      ON pd.ProcessDatabaseId = osdo.ProcessDatabaseId
    JOIN arch.Process p
      ON p.ProcessId = pd.ProcessId
    JOIN arch.ObjectSpec os
      ON os.ObjectSpecId = osdo.ObjectSpecId
    WHERE p.IsEnabled = 1
      AND pd.IsEnabled = 1
      AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR pd.SourceDb = @SourceDb)
      AND os.ProcessId <> pd.ProcessId;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Anchor-driven process has incomplete anchor configuration.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
      AND
      (
          e.AnchorSchema IS NULL
          OR e.AnchorTable IS NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorDocKeyExpr)), N'') IS NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorTimestampExpr)), N'') IS NULL
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'WARN',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Non-anchor process has anchor fields populated even though SelectionStrategy is not ANCHOR.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'ANCHOR'
      AND
      (
          e.AnchorSchema IS NOT NULL
          OR e.AnchorTable IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorDocKeyExpr)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorDocKey2Expr)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorTimestampExpr)), N'') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(e.AnchorExtraWhereSql)), N'') IS NOT NULL
      );

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Anchor-driven ObjectSpec requires JoinToAnchorPredicateSql.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND EXISTS
      (
          SELECT 1
          FROM arch.v_ProcessDatabaseEffective e
          WHERE e.ProcessDatabaseId = os.ProcessDatabaseId
            AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
      )
      AND os.DeleteMode = 1
      AND NULLIF(LTRIM(RTRIM(os.JoinToAnchorPredicateSql)), N'') IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Row-driven ObjectSpec requires TimestampExpr.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'TIMESTAMP'
      AND e.AnchorTable IS NULL
      AND os.DeleteMode = 0
      AND NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'TIMESTAMP process requires ObjectSpec.DeleteMode = 1.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND os.DeleteMode <> 1;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'TIMESTAMP process requires TimestampExpr and JoinToAnchorPredicateSql on every ObjectSpec.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND
      (
          NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NULL
          OR NULLIF(LTRIM(RTRIM(os.JoinToAnchorPredicateSql)), N'') IS NULL
      );

    -- Cheap-mode misconfiguration (WARN): a CandidateSelectExpr (cheap local-time projection) only takes
    -- effect when the mapping ALSO has a sargable CandidateWhereSql cutoff (027 @cheapMode needs BOTH). Set
    -- alone it is silently ignored and the runner falls back to the slower per-row AT TIME ZONE candidate
    -- selection -> surface it so the operator either completes or removes the cheap-mode setup.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'WARN',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'ObjectSpec.CandidateSelectExpr is set but the mapping has no CandidateWhereSql cutoff, so cheap-mode candidate selection will NOT activate (the runner uses the slower per-row AT TIME ZONE path). Set a sargable CandidateWhereSql on arch.ProcessDatabase (raw indexed column vs @CutoffUtc) to enable it, or clear CandidateSelectExpr.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.CandidateSelectExpr)), N'') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(e.CandidateWhereSql)), N'') IS NULL;

    -- Cheap-mode active (INFO): the sargable string cutoff is only correct when the source time column is
    -- lexicographically chronological (ISO yyyymmdd...). A mixed/non-ISO format makes it under-select rows
    -- SILENTLY (it never deletes the wrong rows, but may process 0 -> KMWE_Test.RF_LOG2 lesson). Remind the
    -- operator to verify the column format before trusting cheap-mode on this source.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'INFO',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Cheap-mode candidate selection is active (CandidateSelectExpr + CandidateWhereSql both set). Verify the source time column is lexicographically chronological (ISO yyyymmdd...): a mixed/non-ISO string format makes the sargable cutoff under-select rows silently (never wrong rows, but possibly 0). Use classic mode (clear CandidateWhereSql) for mixed-format columns.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.CandidateSelectExpr)), N'') IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(e.CandidateWhereSql)), N'') IS NOT NULL;

    -- Cheap-mode AVAILABLE (INFO, performance opportunity + one-click remediation): a TIMESTAMP process whose
    -- TimestampExpr applies per-row AT TIME ZONE for candidate selection, but cheap-mode is NOT enabled
    -- (no CandidateWhereSql cutoff). Enabling cheap-mode removes the per-row AT TIME ZONE from the candidate
    -- scan (the dominant scan cost on large sources; measured ~17x on RF_LOG2). The derived config is
    -- CORRECTNESS-EQUIVALENT: it compares the SAME local timestamp (TimestampExpr with the AT TIME ZONE tail
    -- stripped) to the SAME cutoff (@CutoffUtc converted to the source's local zone ONCE), and the retention
    -- floor (50210) + safe-expr gate (50400) still apply unchanged. Offered ONLY when the mapping has exactly
    -- ONE enabled TIMESTAMP ObjectSpec (single timestamp table) so the per-ProcessDatabase CandidateWhereSql is
    -- unambiguous, and only when the local-time core + zone can be parsed from the expression. ActionKey lets
    -- the Console show an "Apply" button -> arch.usp_Api_ApplyConfigFix derives + validates + sets it server-side.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql, ActionKey)
    SELECT
        'INFO',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Performance: this TIMESTAMP process uses per-row AT TIME ZONE for candidate selection and cheap-mode is not enabled. Enabling cheap-mode removes the per-row AT TIME ZONE from the candidate scan (the dominant cost on large sources) and is correctness-equivalent (same local timestamp vs the same cutoff; retention floor and safe-expr gate still apply).',
        N'Enable cheap-mode (one-click, ActionKey=ENABLE_CHEAP_MODE) -> sets ObjectSpec.CandidateSelectExpr = '
          + d.localCore
          + N'   and   arch.ProcessDatabase.CandidateWhereSql = (' + d.localCore
          + N') < CONVERT(datetime2(0), @CutoffUtc AT TIME ZONE N''UTC'' AT TIME ZONE N''' + d.zone + N''').'
          + N' Or run: EXEC arch.usp_Api_ApplyConfigFix @ActionKey=N''ENABLE_CHEAP_MODE'', @ProcessCode=N'''
          + REPLACE(os.ProcessCode, N'''', N'''''') + N''', @SourceDb=N''' + REPLACE(os.SourceDb, N'''', N'''''') + N'''.',
        N'ENABLE_CHEAP_MODE'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    CROSS APPLY (SELECT atzPos = CHARINDEX(N' AT TIME ZONE ', os.TimestampExpr)) p1
    CROSS APPLY (SELECT localCore = LTRIM(RTRIM(LEFT(os.TimestampExpr, NULLIF(p1.atzPos, 0) - 1)))) p2
    CROSS APPLY (SELECT zTail = SUBSTRING(os.TimestampExpr, CHARINDEX(N'AT TIME ZONE N''', os.TimestampExpr) + 15, 200)) p3
    CROSS APPLY (SELECT zone = LEFT(p3.zTail, NULLIF(CHARINDEX(N'''', p3.zTail), 0) - 1)) p4
    CROSS APPLY (SELECT localCore = p2.localCore, zone = p4.zone) d
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NOT NULL
      AND os.TimestampExpr LIKE N'% AT TIME ZONE N''%'
      AND NULLIF(LTRIM(RTRIM(e.CandidateWhereSql)), N'') IS NULL          -- cheap-mode currently OFF
      AND NULLIF(d.localCore, N'') IS NOT NULL
      AND NULLIF(d.zone, N'') IS NOT NULL
      AND
      (
          SELECT COUNT_BIG(*)
          FROM arch.v_ObjectSpecDatabaseEffective os2
          WHERE os2.ProcessDatabaseId = os.ProcessDatabaseId
            AND os2.ObjectIsEnabled = 1
      ) = 1;

    -- T-23 (timezone validity): a zone name in AT TIME ZONE must resolve in sys.time_zone_info, otherwise
    -- AT TIME ZONE THROWs at run time and the scheduled run wedges. Surface a typo'd source zone at
    -- config-validation time (fail-fast) by extracting the FIRST AT TIME ZONE N'...' literal from each
    -- enabled timestamp expression and checking it. (The deeper, SILENT hazard — text-date CONVERT being
    -- SET LANGUAGE / DATEFORMAT-sensitive — is a documented config guideline: use ISO/lexically-chronological
    -- source date columns; the runner intentionally does not pin SET LANGUAGE. See the operational docs.)
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT DISTINCT
        'WARN', src.ProcessCode, src.SourceDb, src.ArchiveDb, src.ObjectName,
        N'Timestamp expression references time zone ''' + z.Zone
        + N''' which is not in sys.time_zone_info on this instance — AT TIME ZONE will THROW at run time. Fix the zone name (see SELECT name FROM sys.time_zone_info) before enabling real runs.'
    FROM
    (
        SELECT e2.ProcessCode, e2.SourceDb, e2.ArchiveDb, ObjectName = CONVERT(nvarchar(300), NULL), Expr = e2.AnchorTimestampExpr
        FROM arch.v_ProcessDatabaseEffective e2
        WHERE e2.IsEnabled = 1
          AND COALESCE(e2.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
          AND e2.AnchorTimestampExpr LIKE N'%AT TIME ZONE N''%'
          AND (@ProcessCode IS NULL OR e2.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e2.SourceDb = @SourceDb)
        UNION ALL
        SELECT os.ProcessCode, os.SourceDb, os.ArchiveDb, QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable), os.TimestampExpr
        FROM arch.v_ObjectSpecDatabaseEffective os
        WHERE os.ProcessDatabaseIsEnabled = 1 AND os.ObjectIsEnabled = 1
          AND os.TimestampExpr LIKE N'%AT TIME ZONE N''%'
          AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
    ) src
    CROSS APPLY
    (
        SELECT Zone = LEFT(
                 SUBSTRING(src.Expr, CHARINDEX(N'AT TIME ZONE N''', src.Expr) + 15, 200),
                 NULLIF(CHARINDEX(N'''', SUBSTRING(src.Expr, CHARINDEX(N'AT TIME ZONE N''', src.Expr) + 15, 200)), 0) - 1)
    ) z
    WHERE z.Zone IS NOT NULL AND z.Zone <> N''
      AND NOT EXISTS (SELECT 1 FROM sys.time_zone_info t WHERE t.name = z.Zone);

    -- Mixed-format / language hazard (WARN): a TIMESTAMP-strategy source whose TimestampExpr applies a HARD
    -- CAST/CONVERT (no TRY_) to a text date column THROWs under a non-us_english session for English month-name
    -- values (e.g. 'Apr 9 2025') and can fail the scheduled run; under us_english the same value parses, so it
    -- is an environment-dependent latent failure (the runner intentionally does not pin SET LANGUAGE). A
    -- defensive TRY_CONVERT (+ optional TRY_PARSE ... USING 'en-US') yields NULL instead of throwing, so any
    -- unparseable rows are safely skipped (never archived/deleted, divergence unaffected) and are then counted
    -- by arch.usp_Frontend_TimestampRetentionGaps. This is a METADATA check (no source-row IO): it flags the
    -- non-defensive expression and emits a SuggestedSql fix. (If cheap-mode is used, make CandidateSelectExpr
    -- defensive too.) Excludes expressions already using TRY_CONVERT/TRY_PARSE/TRY_CAST.
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql)
    SELECT
        'WARN', os.ProcessCode, os.SourceDb, os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'TimestampExpr uses a hard CAST/CONVERT (no TRY_) on a TIMESTAMP source. If the source date column is text, English month-name values (e.g. ''Apr 9 2025'') THROW under a non-us_english session and can fail the run; under us_english they parse, so this is an environment-dependent latent failure. Recommended defensive expression (replace <col> with the source column): COALESCE(TRY_CONVERT(datetime2, t.<col>), TRY_PARSE(t.<col> AS datetime2 USING ''en-US'')) AT TIME ZONE N''Central European Standard Time'' AT TIME ZONE N''UTC''. Unparseable rows then yield NULL (safely skipped) and are counted by arch.usp_Frontend_TimestampRetentionGaps. If cheap-mode is active, make CandidateSelectExpr defensive too. Ignore if the source column is already a real datetime/UTC type.',
        N'UPDATE os SET TimestampExpr = N''<DOSADTE_DEFENZIVNI_VYRAZ_Z_FINDING>'' FROM arch.ObjectSpec os JOIN arch.Process p ON p.ProcessId = os.ProcessId WHERE p.ProcessCode = N'''
          + REPLACE(os.ProcessCode, N'''', N'''''') + N''' AND os.SourceSchema = N'''
          + REPLACE(os.SourceSchema, N'''', N'''''') + N''' AND os.SourceTable = N'''
          + REPLACE(os.SourceTable, N'''', N'''''') + N''';'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
      AND NULLIF(LTRIM(RTRIM(os.TimestampExpr)), N'') IS NOT NULL
      AND (os.TimestampExpr LIKE N'%CAST(%' OR os.TimestampExpr LIKE N'%CONVERT(%')
      AND os.TimestampExpr NOT LIKE N'%TRY_CAST%'
      AND os.TimestampExpr NOT LIKE N'%TRY_CONVERT%'
      AND os.TimestampExpr NOT LIKE N'%TRY_PARSE%';

    IF OBJECT_ID(N'arch.ProcessKeySpec', N'U') IS NOT NULL
    BEGIN
        INSERT #Findings(Severity, ProcessCode, Finding)
        SELECT
            'ERROR',
            p.ProcessCode,
            N'TIMESTAMP process requires arch.ProcessKeySpec KeyOrdinal=1.'
        FROM arch.Process p
        WHERE p.IsEnabled = 1
          AND (@ProcessCode IS NULL OR p.ProcessCode = @ProcessCode)
          AND COALESCE(p.SelectionStrategy, N'ANCHOR') = N'TIMESTAMP'
          AND NOT EXISTS
          (
              SELECT 1
              FROM arch.ProcessKeySpec pks
              WHERE pks.ProcessId = p.ProcessId
                AND pks.KeyOrdinal = 1
                AND NULLIF(LTRIM(RTRIM(pks.SourceExpressionSql)), N'') IS NOT NULL
          );

        INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
        SELECT DISTINCT
            'WARN',
            e.ProcessCode,
            e.SourceDb,
            e.ArchiveDb,
            N'Process defines ProcessKeySpec keys beyond Key2, but arch.WorkBatchKey primary key is currently (WorkBatchId, Key1, Key2). Ensure Key1/Key2 are unique for prepared batches or migrate the WorkBatchKey key design before using multi-column keys.'
        FROM arch.v_ProcessDatabaseEffective e
        JOIN arch.ProcessKeySpec pks
          ON pks.ProcessId = e.ProcessId
        WHERE e.IsEnabled = 1
          AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
          AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'TIMESTAMP'
          AND pks.KeyOrdinal > 2;
    END;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Source database does not exist on this SQL instance.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND DB_ID(e.SourceDb) IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'Archive database does not exist on this SQL instance.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb)
      AND DB_ID(e.ArchiveDb) IS NULL;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, Finding)
    SELECT
        'ERROR',
        e.ProcessCode,
        e.SourceDb,
        e.ArchiveDb,
        N'SourceDb and ArchiveDb are identical for an archive+delete or copy-only process.'
    FROM arch.v_ProcessDatabaseEffective e
    WHERE e.IsEnabled = 1
      AND e.Mode IN (1, 2)
      AND e.SourceDb = e.ArchiveDb
      AND (@ProcessCode IS NULL OR e.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR e.SourceDb = @SourceDb);

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Anchor-driven process requires ObjectSpec.DeleteMode = 1.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') = N'ANCHOR'
      AND os.DeleteMode <> 1;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Row-driven process requires ObjectSpec.DeleteMode = 0.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND COALESCE(e.SelectionStrategy, N'ANCHOR') <> N'TIMESTAMP'
      AND e.AnchorTable IS NULL
      AND os.DeleteMode <> 0;

    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    SELECT
        'ERROR',
        os.ProcessCode,
        os.SourceDb,
        os.ArchiveDb,
        QUOTENAME(os.SourceSchema) + N'.' + QUOTENAME(os.SourceTable),
        N'Delete-only mode is blocked because RequireArchiveForDelete=1 and AllowDeleteWithoutArchive=0.'
    FROM arch.v_ObjectSpecDatabaseEffective os
    JOIN arch.v_ProcessDatabaseEffective e
      ON e.ProcessDatabaseId = os.ProcessDatabaseId
    WHERE os.ProcessDatabaseIsEnabled = 1
      AND os.ObjectIsEnabled = 1
      AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
      AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb)
      AND e.Mode = 0
      AND COALESCE(os.RequireArchiveForDelete, 1) = 1
      AND COALESCE(e.AllowDeleteWithoutArchive, 0) = 0;

    DECLARE
        @vProcessCode sysname,
        @vSourceDb sysname,
        @vArchiveDb sysname,
        @vMode tinyint,
        @vSourceSchema sysname,
        @vSourceTable sysname,
        @vArchiveSchema sysname,
        @vArchiveTable sysname,
        @sql nvarchar(max);

    DECLARE object_check CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            os.ProcessCode,
            os.SourceDb,
            os.ArchiveDb,
            e.Mode,
            os.SourceSchema,
            os.SourceTable,
            CONVERT(nvarchar(128), REPLACE(
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo' THEN N'{SourceDb}'
                    ELSE LTRIM(RTRIM(os.ArchiveSchema))
                END,
                N'{SourceDb}', os.SourceDb)) AS ArchiveSchema,
            COALESCE(NULLIF(os.ArchiveTable, N''), os.SourceTable)
        FROM arch.v_ObjectSpecDatabaseEffective os
        JOIN arch.v_ProcessDatabaseEffective e
          ON e.ProcessDatabaseId = os.ProcessDatabaseId
        WHERE os.ProcessDatabaseIsEnabled = 1
          AND os.ObjectIsEnabled = 1
          AND DB_ID(os.SourceDb) IS NOT NULL
          AND DB_ID(os.ArchiveDb) IS NOT NULL
          AND (@ProcessCode IS NULL OR os.ProcessCode = @ProcessCode)
          AND (@SourceDb IS NULL OR os.SourceDb = @SourceDb);

    OPEN object_check;
    FETCH NEXT FROM object_check INTO @vProcessCode, @vSourceDb, @vArchiveDb, @vMode, @vSourceSchema, @vSourceTable, @vArchiveSchema, @vArchiveTable;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
IF NOT EXISTS
(
    SELECT 1
    FROM ' + QUOTENAME(@vSourceDb) + N'.sys.tables t
    INNER JOIN ' + QUOTENAME(@vSourceDb) + N'.sys.schemas s
        ON s.schema_id = t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @pSourceSchema COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @pSourceTable COLLATE DATABASE_DEFAULT
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    VALUES
    (
        ''ERROR'',
        @pProcessCode,
        @pSourceDb,
        @pArchiveDb,
        QUOTENAME(@pSourceSchema) + N''.'' + QUOTENAME(@pSourceTable),
        N''Configured source table does not exist.''
    );
	END;';

        IF @vMode IN (1, 2)   -- archive+delete (1) and copy-only (2) both require the archive table
        BEGIN
            SET @sql = @sql + N'

	IF NOT EXISTS
	(
	    SELECT 1
	    FROM ' + QUOTENAME(@vArchiveDb) + N'.sys.tables t
    INNER JOIN ' + QUOTENAME(@vArchiveDb) + N'.sys.schemas s
        ON s.schema_id = t.schema_id
    WHERE s.name COLLATE DATABASE_DEFAULT = @pArchiveSchema COLLATE DATABASE_DEFAULT
      AND t.name COLLATE DATABASE_DEFAULT = @pArchiveTable COLLATE DATABASE_DEFAULT
)
BEGIN
    INSERT #Findings(Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding)
    VALUES
    (
        ''WARN'',
        @pProcessCode,
        @pSourceDb,
        @pArchiveDb,
        QUOTENAME(@pArchiveSchema) + N''.'' + QUOTENAME(@pArchiveTable),
	        N''Archive table does not exist yet; provision it before delete/archive runs or allow the provisioning procedure to create it.''
	    );
	END;';
        END;

        EXEC sys.sp_executesql
            @sql,
            N'@pProcessCode sysname,
              @pSourceDb sysname,
              @pArchiveDb sysname,
              @pSourceSchema sysname,
              @pSourceTable sysname,
              @pArchiveSchema sysname,
              @pArchiveTable sysname',
            @pProcessCode = @vProcessCode,
            @pSourceDb = @vSourceDb,
            @pArchiveDb = @vArchiveDb,
            @pSourceSchema = @vSourceSchema,
            @pSourceTable = @vSourceTable,
            @pArchiveSchema = @vArchiveSchema,
            @pArchiveTable = @vArchiveTable;

        FETCH NEXT FROM object_check INTO @vProcessCode, @vSourceDb, @vArchiveDb, @vMode, @vSourceSchema, @vSourceTable, @vArchiveSchema, @vArchiveTable;
    END

    CLOSE object_check;
    DEALLOCATE object_check;

    /* Concrete remediation SQL for the deterministically-fixable findings. */
    -- archive table not yet provisioned -> the exact provisioning call
    UPDATE #Findings
    SET SuggestedSql =
        N'EXEC arch.usp_ProvisionArchiveTablesForProcess @ProcessCode=N''' + REPLACE(ProcessCode, N'''', N'''''')
      + N''', @SourceDb=N''' + REPLACE(SourceDb, N'''', N'''''')
      + N''', @ArchiveDb=N''' + REPLACE(ArchiveDb, N'''', N'''''') + N''';'
    WHERE Finding LIKE N'Archive table does not exist%'
      AND ProcessCode IS NOT NULL AND SourceDb IS NOT NULL AND ArchiveDb IS NOT NULL;

    -- redundant ProcessDatabase override -> NULL out the redundant column (keeps the arch.Process default)
    UPDATE #Findings
    SET SuggestedSql =
        N'UPDATE pd SET ' + QUOTENAME(LTRIM(RTRIM(SUBSTRING(Finding,
              CHARINDEX(N'arch.ProcessDatabase: ', Finding) + 22,
              CHARINDEX(N' equals', Finding) - (CHARINDEX(N'arch.ProcessDatabase: ', Finding) + 22)))))
      + N' = NULL FROM arch.ProcessDatabase pd JOIN arch.Process p ON p.ProcessId = pd.ProcessId'
      + N' WHERE p.ProcessCode=N''' + REPLACE(ProcessCode, N'''', N'''''')
      + N''' AND pd.SourceDb=N''' + REPLACE(SourceDb, N'''', N'''''')
      + N''' AND pd.ArchiveDb=N''' + REPLACE(ArchiveDb, N'''', N'''''') + N''';'
    WHERE Finding LIKE N'Redundant database override in arch.ProcessDatabase:%'
      AND CHARINDEX(N' equals', Finding) > CHARINDEX(N'arch.ProcessDatabase: ', Finding) + 22
      AND ProcessCode IS NOT NULL AND SourceDb IS NOT NULL AND ArchiveDb IS NOT NULL;

    SELECT Severity, ProcessCode, SourceDb, ArchiveDb, ObjectName, Finding, SuggestedSql, ActionKey
    FROM #Findings
    ORDER BY CASE Severity WHEN 'ERROR' THEN 0 ELSE 1 END, ProcessCode, SourceDb, ObjectName;

    IF EXISTS (SELECT 1 FROM #Findings WHERE Severity = 'ERROR')
        RETURN 1;

    RETURN 0;
END
GO
