USE [kArchiveManagerAdmin]
GO
/****** Object:  StoredProcedure [arch].[usp_ProvisionArchiveTablesForProcess]    Script Date: 27.04.2026 15:01:56 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


/* 5) Provisioning helpers */
CREATE OR ALTER PROCEDURE [arch].[usp_ProvisionArchiveTablesForProcess]
    @ProcessCode sysname,
    @SourceDb    sysname,
    @ArchiveDb   sysname,
    @MakeAllNullable bit = 1,
    @IncludeComputed bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ProcessDatabaseId int =
    (
        SELECT ProcessDatabaseId
        FROM arch.v_ProcessDatabaseEffective
        WHERE ProcessCode = @ProcessCode
          AND SourceDb = @SourceDb
          AND ArchiveDb = @ArchiveDb
          AND IsEnabled = 1
    );

    IF @ProcessDatabaseId IS NULL
        THROW 50000, 'Unknown ProcessCode.', 1;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT
        os.SourceSchema,
        os.SourceTable,
        CONVERT(nvarchar(128), REPLACE(
            CASE
                WHEN NULLIF(LTRIM(RTRIM(os.ArchiveSchema)), N'') IS NULL OR LTRIM(RTRIM(os.ArchiveSchema)) = N'dbo' THEN N'{SourceDb}'
                ELSE LTRIM(RTRIM(os.ArchiveSchema))
            END,
            N'{SourceDb}', @SourceDb)) AS ArchiveSchema,
        COALESCE(os.ArchiveTable, os.SourceTable) AS ArchiveTable
    FROM arch.v_ObjectSpecDatabaseEffective os
    WHERE os.ProcessDatabaseId = @ProcessDatabaseId
      AND os.ObjectIsEnabled = 1
    ORDER BY os.DeleteOrder;

    DECLARE @ss sysname, @st sysname, @as sysname, @at sysname;

    OPEN c;
    FETCH NEXT FROM c INTO @ss,@st,@as,@at;

    WHILE @@FETCH_STATUS=0
    BEGIN
        EXEC arch.usp_EnsureArchiveTableLikeSource
            @SourceDb=@SourceDb,
            @ArchiveDb=@ArchiveDb,
            @SourceSchema=@ss,
            @SourceTable=@st,
            @ArchiveSchema=@as,
            @ArchiveTable=@at,
            @MakeAllNullable=@MakeAllNullable,
            @IncludeComputed=@IncludeComputed;

        FETCH NEXT FROM c INTO @ss,@st,@as,@at;
    END

    CLOSE c;
    DEALLOCATE c;
END
