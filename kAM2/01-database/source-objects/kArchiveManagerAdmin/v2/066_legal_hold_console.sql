/* ============================================================================
   066_legal_hold_console.sql — expose legal-hold + retention-floor management to the Admin Console.
   ----------------------------------------------------------------------------
   056 built the compliance API (usp_Api_AddLegalHold / usp_Api_ReleaseLegalHold / usp_Frontend_GetLegalHolds
   / usp_Api_SetRetentionFloor) but granted the mutating procs only to karch_approver — so the Admin
   Console (whose app login is in karch_config_admin/karch_advanced_admin, NOT karch_approver) could not
   drive them, and there was no console surface. This migration:
     * adds a read-only getter for the retention floor (usp_Frontend_GetRetentionFloor), and
     * grants the legal-hold / retention-floor procs to the ELEVATED console role (karch_advanced_admin)
       so L2 operators can place/release holds and set the floor from the console (the endpoints are
       IsElevated-gated). Read getters are also granted to the viewer/operator roles.
   karch_approver keeps its grants (unchanged). Idempotent.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [arch].[usp_Frontend_GetRetentionFloor]
AS
BEGIN
    SET NOCOUNT ON;
    SELECT MinRetentionDays, ModifiedAtUtc, ModifiedBy
    FROM arch.RetentionPolicy WHERE PolicyId = 1;
END
GO

/* Grants: elevated console role drives the compliance actions; viewer/operator can read. */
IF DATABASE_PRINCIPAL_ID(N'karch_advanced_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON [arch].[usp_Api_SetRetentionFloor]      TO [karch_advanced_admin];
    GRANT EXECUTE ON [arch].[usp_Api_AddLegalHold]           TO [karch_advanced_admin];
    GRANT EXECUTE ON [arch].[usp_Api_ReleaseLegalHold]       TO [karch_advanced_admin];
    GRANT EXECUTE ON [arch].[usp_Frontend_GetLegalHolds]     TO [karch_advanced_admin];
    GRANT EXECUTE ON [arch].[usp_Frontend_GetRetentionFloor] TO [karch_advanced_admin];
END;
IF DATABASE_PRINCIPAL_ID(N'karch_config_admin') IS NOT NULL
BEGIN
    GRANT EXECUTE ON [arch].[usp_Frontend_GetLegalHolds]     TO [karch_config_admin];
    GRANT EXECUTE ON [arch].[usp_Frontend_GetRetentionFloor] TO [karch_config_admin];
END;
IF DATABASE_PRINCIPAL_ID(N'karch_viewer') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GetRetentionFloor] TO [karch_viewer];
IF DATABASE_PRINCIPAL_ID(N'karch_operator') IS NOT NULL
    GRANT EXECUTE ON [arch].[usp_Frontend_GetRetentionFloor] TO [karch_operator];
GO
PRINT 'Legal-hold + retention-floor console API installed (getter + elevated-console grants).';
GO
