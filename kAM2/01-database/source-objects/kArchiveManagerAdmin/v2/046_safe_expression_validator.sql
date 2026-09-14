/* ============================================================================
   046 — Safe SQL-expression validator (audit task T-05)
   ============================================================================
   PROBLEM: the advanced configuration fields (AnchorTimestampExpr, AnchorExtraWhereSql,
   TimestampExpr, JoinToAnchorPredicateSql, AdditionalWhereSql, CandidateWhereSql, CandidateOrderSql,
   ProcessKeySpec.SourceExpressionSql + their *Override siblings) are concatenated verbatim into the
   dynamic DELETE/SELECT the runner executes against PRODUCTION source databases. They are gated only
   by an app role — a config author is effectively an unconstrained T-SQL author (stored second-order
   SQL injection: e.g. JoinToAnchorPredicateSql = '1=1) ; DELETE FROM ...; --').

   FIX: a reusable assertion the Save* procs call synchronously BEFORE persisting each free-text field.
   It rejects anything that is not a single scalar/boolean expression: statement terminators, comments,
   DDL/DML/exec keywords (whole-word), xp_/sp_ procedure references, and unbalanced parentheses.
   Calibrated against the live config (2026-06-03): every existing legitimate value passes
   (CAST/CONVERT/COALESCE/TRY_CONVERT/ISNULL/STUFF/REPLACE/AT TIME ZONE/... with balanced parens).

   This is defense-in-depth, not a full parser; the trust boundary remains "only advanced_admin may
   edit these", but it blocks the catastrophic vectors. THROW 50400 on rejection.
   Idempotent (CREATE OR ALTER). No data change.
   ============================================================================ */
USE [kArchiveManagerAdmin];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE arch.usp_AssertSafeSqlExpression
    @Expression nvarchar(4000),
    @FieldName  nvarchar(128)
AS
BEGIN
    SET NOCOUNT ON;

    -- Empty/NULL is allowed here; required-ness is enforced by the calling Save proc.
    IF NULLIF(LTRIM(RTRIM(@Expression)), N'') IS NULL
        RETURN;

    DECLARE @raw nvarchar(4000) = @Expression;
    DECLARE @why nvarchar(200) = NULL;

    -- 1) Statement terminators / comment injection (raw substring checks).
    IF @raw LIKE N'%;%'                               SET @why = N'contains a statement terminator '';''';
    ELSE IF @raw LIKE N'%--%'                          SET @why = N'contains a line comment ''--''';
    ELSE IF @raw LIKE N'%/*%' OR @raw LIKE N'%*/%'     SET @why = N'contains a block comment ''/* */''';

    -- 2) Parenthesis STRUCTURE: scan left-to-right; depth must never go negative (which would mean a
    --    ')' closes the runner's wrapping "(<expr>)" early, e.g. "1=1) OR (1=1" -> always-true =
    --    over-delete) and must end at zero. (Note: parentheses inside string literals are not common
    --    in these fields and are treated literally; rewrite such a value if it trips this check.)
    IF @why IS NULL
    BEGIN
        DECLARE @i int = 1, @depth int = 0, @len int = LEN(@raw), @ch nchar(1);
        WHILE @i <= @len
        BEGIN
            SET @ch = SUBSTRING(@raw, @i, 1);
            IF @ch = N'(' SET @depth += 1;
            ELSE IF @ch = N')' SET @depth -= 1;
            IF @depth < 0 BREAK;
            SET @i += 1;
        END;
        IF @depth <> 0
            SET @why = N'has unbalanced or mis-nested parentheses';
    END;

    -- 3) Disallowed keywords (whole-word, case-insensitive) + xp_/sp_ procedure references.
    --    Punctuation is translated to spaces so keywords are matched on word boundaries; a column such
    --    as DATE_CREATE / disp_qty therefore does NOT trip CREATE / sp_.
    IF @why IS NULL
    BEGIN
        DECLARE @punct nvarchar(64) = N'()[]{}<>,.+-*/=!%&|~^@?:;`''"' + NCHAR(9) + NCHAR(10) + NCHAR(13);
        DECLARE @norm  nvarchar(max) =
            N' ' + TRANSLATE(UPPER(@raw), @punct, REPLICATE(N' ', LEN(@punct + N'.') - 1)) + N' ';

        IF     @norm LIKE N'% SELECT %'        OR @norm LIKE N'% INSERT %'
            OR @norm LIKE N'% UPDATE %'        OR @norm LIKE N'% DELETE %'
            OR @norm LIKE N'% MERGE %'         OR @norm LIKE N'% DROP %'
            OR @norm LIKE N'% CREATE %'        OR @norm LIKE N'% ALTER %'
            OR @norm LIKE N'% TRUNCATE %'      OR @norm LIKE N'% EXEC %'
            OR @norm LIKE N'% EXECUTE %'       OR @norm LIKE N'% GRANT %'
            OR @norm LIKE N'% REVOKE %'        OR @norm LIKE N'% DENY %'
            OR @norm LIKE N'% SHUTDOWN %'      OR @norm LIKE N'% WAITFOR %'
            OR @norm LIKE N'% RECONFIGURE %'   OR @norm LIKE N'% BACKUP %'
            OR @norm LIKE N'% RESTORE %'       OR @norm LIKE N'% BULK %'
            OR @norm LIKE N'% OPENROWSET %'    OR @norm LIKE N'% OPENQUERY %'
            OR @norm LIKE N'% OPENDATASOURCE %' OR @norm LIKE N'% OPENXML %'
            OR @norm LIKE N'% XP[_]%'          OR @norm LIKE N'% SP[_]%'
            SET @why = N'contains a disallowed SQL keyword or procedure reference';
    END;

    IF @why IS NOT NULL
    BEGIN
        DECLARE @msg nvarchar(1000) =
            N'Unsafe SQL in advanced configuration field [' + @FieldName + N']: ' + @why
          + N'. It must be a single scalar/boolean expression — no statements, comments, DDL/DML keywords, or procedure calls.';
        ;THROW 50400, @msg, 1;
    END;
END;
GO

PRINT '046_safe_expression_validator deployed (arch.usp_AssertSafeSqlExpression).';
GO
