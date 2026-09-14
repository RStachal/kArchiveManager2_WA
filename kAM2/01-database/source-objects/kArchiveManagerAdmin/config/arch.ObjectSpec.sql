USE [kArchiveManagerAdmin]
GO
SET NOCOUNT ON;
GO

DECLARE @ReceivingProcessId int =
(
    SELECT ProcessId
    FROM arch.Process
    WHERE ProcessCode = N'RECEIVING'
);

DECLARE @ShippingProcessId int =
(
    SELECT ProcessId
    FROM arch.Process
    WHERE ProcessCode = N'SHIPPING'
);

DECLARE @RfLog2ProcessId int =
(
    SELECT ProcessId
    FROM arch.Process
    WHERE ProcessCode = N'RF_LOG2'
);

IF @ReceivingProcessId IS NULL
BEGIN
    RAISERROR(N'Process RECEIVING not found in arch.Process.', 16, 1);
    RETURN;
END;

IF @ShippingProcessId IS NULL
BEGIN
    RAISERROR(N'Process SHIPPING not found in arch.Process.', 16, 1);
    RETURN;
END;

IF @RfLog2ProcessId IS NULL
BEGIN
    RAISERROR(N'Process RF_LOG2 not found in arch.Process.', 16, 1);
    RETURN;
END;

BEGIN TRAN;

DELETE FROM arch.ObjectSpec
WHERE ProcessId IN (@ReceivingProcessId, @ShippingProcessId, @RfLog2ProcessId);

INSERT INTO arch.ObjectSpec
(
    ProcessId,
    SourceSchema,
    SourceTable,
    DeleteOrder,
    DeleteMode,
    TimestampExpr,
    JoinToAnchorPredicateSql,
    AdditionalWhereSql,
    ArchiveSchema,
    ArchiveTable,
    RequireArchiveForDelete,
    NaturalKeyLabel
)
VALUES
(@ShippingProcessId,  N'dbo', N'SHIPDETL',  10, 1, N'DATECREATE',                                 N't.PACKSLIP = k.DocKey', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),
(@ShippingProcessId,  N'dbo', N'SHIPDETL2', 20, 1, N'DATECREATE',                                 N't.PACKSLIP = k.DocKey', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),
(@ShippingProcessId,  N'dbo', N'SHIPMSTR',  30, 1, N'COALESCE(DATE_SHIP, DATECREATE)',            N't.PACKSLIP = k.DocKey', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),
(@ShippingProcessId,  N'dbo', N'SHIPLINE',  40, 1, N'BILLEDDATE',                                 N't.PACKSLIP = k.DocKey', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),
(@ShippingProcessId,  N'dbo', N'SHIPLINE2', 50, 1, N'BILLEDDATE',                                 N't.PACKSLIP = k.DocKey', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),
(@ShippingProcessId,  N'dbo', N'SHIPHIST',  60, 1, N'COALESCE(DATE_SHIP, DATE_CREAT, DATE_UPLD)', N't.PACKSLIP = k.DocKey', NULL, N'{SourceDb}', NULL, 1, N'PACKSLIP'),
(@ReceivingProcessId, N'dbo', N'BACKRD',    10, 1, N'DATE_CREAT',                                 N't.PO_NUM = k.DocKey',   NULL, N'{SourceDb}', NULL, 1, N'PO_NUM'),
(@ReceivingProcessId, N'dbo', N'BACKRH',    20, 1, N'DATE_CREAT',                                 N't.PO_NUM = k.DocKey',   NULL, N'{SourceDb}', NULL, 1, N'PO_NUM'),
(@RfLog2ProcessId,    N'dbo', N'RF_LOG2',   10, 1, N't.DATE_TIME',                                N't.ROWID = k.Key1',      N't.DATE_TIME IS NOT NULL', N'{SourceDb}', NULL, 1, N'ROWID');

COMMIT;
GO

SELECT *
FROM arch.Process
WHERE ProcessCode IN (N'RECEIVING', N'SHIPPING', N'RF_LOG2');

SELECT p.ProcessCode, os.*
FROM arch.ObjectSpec os
JOIN arch.Process p
  ON p.ProcessId = os.ProcessId
WHERE p.ProcessCode IN (N'RECEIVING', N'SHIPPING', N'RF_LOG2')
ORDER BY p.ProcessCode, os.DeleteOrder, os.ObjectSpecId;
GO
