/*==================================================================================================
  usp_TippingPointAnalysis.sql   ->   DBAdmin.dbo.usp_TippingPointAnalysis

  Procedure form of TippingPointAnalysis_v1.sql. Held to cell-for-cell output equivalence with the
  script (TestRunners/Validate-TippingPointFamily.ps1). The one permitted difference is a leading
  DatabaseName column on every result set.

  The entire script body runs inside a USE [@DatabaseName] dynamic batch -- the timeout-finder
  pattern, not the PSD collection/analysis split. There is no cross-database aggregation here (a
  query / procedure lives in one database), so DB_NAME() resolves to the target throughout and no
  DB_ID() guard is needed on the plan-cache / Query Store joins.

  See TippingPointAnalysis_v1.sql for the full header: the version/regime matrix, dependencies,
  permissions, and disclosed simplifications.
==================================================================================================*/
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_TippingPointAnalysis
    @DatabaseName                sysname       = NULL,   -- where the object / query lives; NULL = current database
    @ObjectName                  NVARCHAR(776) = NULL,   -- newest cached plan for it
    @QueryId                     BIGINT        = NULL,   -- a Query Store query_id
    @PlanXml                     NVARCHAR(MAX) = NULL,   -- pasted showplan XML
    @ProbePlanXml                NVARCHAR(MAX) = NULL,   -- second pass: concatenated [ProbeSweepScript] output
    @TippingPointPageFraction    DECIMAL(5,3)  = 0.333,
    @SkewRatioThreshold          DECIMAL(10,2) = 10.0,
    @EstimateVsTruthThreshold    DECIMAL(10,2) = 10.0,
    @StaleStatsModFraction       DECIMAL(5,3)  = 0.200,
    @ProbeCardinalitySweep       BIT           = 1,
    @ProbeValueCount             INT           = 12,
    @IncludeSniffableParameters  BIT           = 1,
    @TopPredicates               INT           = 50,
    @Debug                       BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    SET @DatabaseName = ISNULL(@DatabaseName, DB_NAME());

    IF DB_ID(@DatabaseName) IS NULL
    BEGIN
        DECLARE @m1 NVARCHAR(300) = N'*** Database ' + QUOTENAME(@DatabaseName) + N' does not exist or is not visible. ***';
        RAISERROR(@m1, 16, 1);
        RETURN;
    END

    IF CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 AND @DatabaseName <> DB_NAME()
    BEGIN
        RAISERROR('*** Azure SQL Database: cross-database is not available. Connect to the target database and re-run. ***', 16, 1);
        RETURN;
    END

    /*  The script body, verbatim, minus its parameter DECLAREs (now this procedure's parameters)
        and its GO separators. Character-for-character the script's SQL, so the equivalence test
        compares the same statements in two contexts.                                             */
    DECLARE @body NVARCHAR(MAX) = N'SET NOCOUNT ON;

DROP TABLE IF EXISTS #PlanXml;
DROP TABLE IF EXISTS #Pred;
DROP TABLE IF EXISTS #Leaf;
DROP TABLE IF EXISTS #StatsUsage;
DROP TABLE IF EXISTS #StatResolved;
DROP TABLE IF EXISTS #DensityVector;
DROP TABLE IF EXISTS #Histogram;
DROP TABLE IF EXISTS #ProbePlanXml;
DROP TABLE IF EXISTS #Result;
DROP TABLE IF EXISTS #StatDetail;

/*------------------------------------------------------------------------------------------------
  1. PARAMETERS -- every threshold named and tunable, none buried in a predicate.
------------------------------------------------------------------------------------------------*/
/*  TARGET -- supply EXACTLY ONE. Pre-flight validates. All three are "the plan already exists":
    the tool never compiles or executes anything (see the header).
*/

/*  SECOND PASS ONLY -- paste the concatenated output of the [ProbeSweepScript] this tool emitted
    on the first pass, to fold the precise (join / parallelism) crossovers into result set 1.    */


/*------------------------------------------------------------------------------------------------
  2. PLATFORM & CAPABILITY DETECTION -- by NAME, not version number.
------------------------------------------------------------------------------------------------*/
DECLARE @EngineEdition INT          = CONVERT(INT, SERVERPROPERTY(''EngineEdition''));
DECLARE @MajorVersion  INT          = CASE WHEN CONVERT(INT, SERVERPROPERTY(''EngineEdition'')) IN (1,2,3,4)
                                           THEN CONVERT(INT, SERVERPROPERTY(''ProductMajorVersion'')) END; -- box only
DECLARE @PlatformName  NVARCHAR(40) = CASE CONVERT(INT, SERVERPROPERTY(''EngineEdition''))
                                           WHEN 5 THEN N''Azure SQL Database''
                                           WHEN 8 THEN N''Azure SQL Managed Instance''
                                           WHEN 11 THEN N''Azure Synapse''
                                           ELSE N''SQL Server'' END;
DECLARE @DatabaseName  SYSNAME      = DB_NAME();
DECLARE @CompatLevel   INT          = (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID());

DECLARE @HasHistogramDmv BIT = CASE WHEN OBJECT_ID(''sys.dm_db_stats_histogram'')     IS NULL THEN 0 ELSE 1 END;
DECLARE @HasQueryStore   BIT = CASE WHEN OBJECT_ID(''sys.query_store_query'')         IS NULL THEN 0 ELSE 1 END;
DECLARE @HasPspVariant   BIT = CASE WHEN OBJECT_ID(''sys.query_store_query_variant'') IS NULL THEN 0 ELSE 1 END;

DECLARE @DscLegacyCe   SQL_VARIANT = (SELECT value FROM sys.database_scoped_configurations WHERE name = ''LEGACY_CARDINALITY_ESTIMATION'');
DECLARE @DscParamSniff SQL_VARIANT = (SELECT value FROM sys.database_scoped_configurations WHERE name = ''PARAMETER_SNIFFING'');
DECLARE @DscDeferredTv SQL_VARIANT = (SELECT value FROM sys.database_scoped_configurations WHERE name = ''DEFERRED_COMPILATION_TV'');
DECLARE @DscPsp        SQL_VARIANT = (SELECT value FROM sys.database_scoped_configurations WHERE name = ''PARAMETER_SENSITIVE_PLAN_OPTIMIZATION'');

DECLARE @TableVarDeferred BIT = CASE WHEN @CompatLevel >= 150 AND CONVERT(INT, ISNULL(@DscDeferredTv, 1)) = 1 THEN 1 ELSE 0 END;
DECLARE @PspActive        BIT = CASE WHEN @CompatLevel >= 160 AND CONVERT(INT, ISNULL(@DscPsp, 1)) = 1 THEN 1 ELSE 0 END;

PRINT ''--- '' + @PlatformName
    + CASE WHEN @MajorVersion IS NOT NULL THEN '', ProductMajorVersion '' + CONVERT(VARCHAR(10), @MajorVersion) ELSE '''' END
    + '', database ['' + @DatabaseName + ''] compat '' + CONVERT(VARCHAR(10), @CompatLevel);
PRINT ''--- Regime: table-variable deferred compilation '' + CASE WHEN @TableVarDeferred = 1 THEN ''ON'' ELSE ''OFF'' END
    + '' | PSP '' + CASE WHEN @PspActive = 1 THEN ''ON'' ELSE ''OFF'' END
    + '' | PARAMETER_SNIFFING '' + CASE WHEN CONVERT(INT, ISNULL(@DscParamSniff,1)) = 1 THEN ''ON'' ELSE ''OFF'' END
    + '' | LEGACY_CE '' + CASE WHEN CONVERT(INT, ISNULL(@DscLegacyCe,0)) = 1 THEN ''ON'' ELSE ''OFF'' END;

/*------------------------------------------------------------------------------------------------
  3. PRE-FLIGHT -- resolve the target; obtain the estimated plan; abort with a message if none.
------------------------------------------------------------------------------------------------*/
IF @EngineEdition NOT IN (5,8) AND ISNULL(@MajorVersion, 99) < 13
BEGIN
    RAISERROR(''*** TippingPointAnalysis needs SQL Server 2016 or later (sys.dm_db_stats_histogram). Aborting. ***'', 16, 1);
    RETURN;
END

DECLARE @TargetCount INT =
      (CASE WHEN @ObjectName IS NOT NULL THEN 1 ELSE 0 END)
    + (CASE WHEN @QueryId    IS NOT NULL THEN 1 ELSE 0 END)
    + (CASE WHEN @PlanXml    IS NOT NULL THEN 1 ELSE 0 END);

IF @TargetCount <> 1
BEGIN
    RAISERROR(''*** Supply EXACTLY ONE of @ObjectName, @QueryId, @PlanXml. See the header. ***'', 16, 1);
    RETURN;
END

CREATE TABLE #PlanXml
(
    StatementSeq INT IDENTITY(1,1) PRIMARY KEY,
    PlanXml      XML          NULL,
    SourceNote   NVARCHAR(200) NULL
);

DECLARE @ResolvedObjectId INT = CASE WHEN @ObjectName IS NOT NULL THEN OBJECT_ID(@ObjectName) END;
DECLARE @Msg NVARCHAR(400);

IF @ObjectName IS NOT NULL AND @ResolvedObjectId IS NULL
BEGIN
    SET @Msg = N''*** @ObjectName '' + QUOTENAME(@ObjectName) + N'' did not resolve in ['' + @DatabaseName + N'']. ***'';
    RAISERROR(@Msg, 16, 1);
    RETURN;
END

/*  3a. @QueryId -> pull the estimated plan(s) from Query Store.                                   */
IF @QueryId IS NOT NULL
BEGIN
    IF @HasQueryStore = 0
    BEGIN
        RAISERROR(''*** @QueryId supplied but Query Store is not present on this engine. ***'', 16, 1);
        RETURN;
    END
    /*  TRY_CAST, not CONVERT (2026-09-14): a plan nested deeper than the 128 levels the xml type
        allows is valid showplan text that CONVERT rejects with Msg 6335, aborting the run. TRY_CAST
        returns NULL instead -- and is compat-100 safe (verified at 100); only TRY_CONVERT is gated. */
    INSERT #PlanXml (PlanXml, SourceNote)
    SELECT TRY_CAST(p.query_plan AS XML),
           N''Query Store plan_id '' + CONVERT(VARCHAR(20), p.plan_id)
    FROM sys.query_store_plan AS p
    WHERE p.query_id = @QueryId
      AND p.query_plan IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM #PlanXml WHERE PlanXml IS NOT NULL)
    BEGIN
        IF EXISTS (SELECT 1 FROM #PlanXml)
            RAISERROR(''*** The Query Store plan for that @QueryId is nested deeper than the 128 levels SQL Server''''s xml type allows, so it cannot be read here. ***'', 16, 1);
        ELSE
            RAISERROR(''*** No usable Query Store plan for that @QueryId. ***'', 16, 1);
        RETURN;
    END
    IF EXISTS (SELECT 1 FROM #PlanXml WHERE PlanXml IS NULL)
        PRINT ''--- Note: at least one Query Store plan for that @QueryId is nested deeper than the xml type allows and was skipped.'';
END

/*  3b. @ObjectName -> the most recent cached plan for it. A procedure body is not a single
       compilable query, so for a procedure the cached plan (or its Query Store query_id) is the
       only offline source -- execute it once, then re-run this.                                  */
IF @ObjectName IS NOT NULL
BEGIN
    INSERT #PlanXml (PlanXml, SourceNote)
    SELECT TOP (20) CONVERT(XML, qp.query_plan),
           N''plan cache, plan_handle '' + CONVERT(VARCHAR(130), cp.plan_handle, 1)
    FROM sys.dm_exec_cached_plans AS cp
    CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
    CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle)   AS st
    WHERE qp.query_plan IS NOT NULL
      AND st.objectid = @ResolvedObjectId
      AND st.dbid = DB_ID();

    IF NOT EXISTS (SELECT 1 FROM #PlanXml WHERE PlanXml IS NOT NULL)
    BEGIN
        /*  sys.dm_exec_query_plan returns NULL, not an error, for a plan nested deeper than the 128
            levels the xml type allows -- so a plan that IS cached can arrive here. Say which it is,
            from the batch''s text plan, rather than tell the caller to execute something already
            cached (2026-09-14).                                                                   */
        IF EXISTS (SELECT 1
                   FROM sys.dm_exec_cached_plans AS cp
                   CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
                   CROSS APPLY sys.dm_exec_text_query_plan(cp.plan_handle, 0, -1) AS tqp
                   WHERE st.objectid = @ResolvedObjectId
                     AND st.dbid = DB_ID()
                     AND tqp.query_plan IS NOT NULL
                     AND TRY_CAST(tqp.query_plan AS XML) IS NULL)
            RAISERROR(''*** The cached plan for %s is nested deeper than the 128 levels SQL Server''''s xml type allows, so it cannot be read here. ***'',
                      16, 1, @ObjectName);
        ELSE
            RAISERROR(''*** No cached plan for %s. Execute it once (or pass its Query Store query_id) and retry. ***'',
                      16, 1, @ObjectName);
        RETURN;
    END
END

/*  3c. @PlanXml -> caller pasted showplan XML. Accept it as-is; CONVERT(XML) tolerates a leading
       <?xml ...?> prolog. Multiple concatenated <ShowPlanXML> roots are not valid XML, so a
       single plan is expected here (the multi-plan case is @ProbePlanXml, handled in section 9). */
IF @PlanXml IS NOT NULL
BEGIN
    BEGIN TRY
        INSERT #PlanXml (PlanXml, SourceNote) VALUES (CONVERT(XML, @PlanXml), N''pasted @PlanXml'');
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() = 6335
            RAISERROR(''*** @PlanXml is nested deeper than the 128 levels SQL Server''''s xml type allows, so it cannot be read here. ***'', 16, 1);
        ELSE
            RAISERROR(''*** @PlanXml did not parse as showplan XML. ***'', 16, 1);
        RETURN;
    END CATCH

    IF NOT EXISTS (SELECT 1 FROM #PlanXml WHERE PlanXml IS NOT NULL)
    BEGIN
        RAISERROR(''*** @PlanXml did not parse as showplan XML. ***'', 16, 1);
        RETURN;
    END
END

DECLARE @PlanSrcNote NVARCHAR(200) = ISNULL((SELECT TOP 1 SourceNote FROM #PlanXml WHERE PlanXml IS NOT NULL), ''(none)'');
DECLARE @PlanRowCount INT = (SELECT COUNT(*) FROM #PlanXml WHERE PlanXml IS NOT NULL);
PRINT ''--- Plan source: '' + @PlanSrcNote + ''  ('' + CONVERT(VARCHAR(10), @PlanRowCount) + '' plan row(s))'';

/*------------------------------------------------------------------------------------------------
  4. SHRED THE PLAN -- one #Pred row per variable-driven predicate (a @var / parameter compared
     to a table column), plus one per table-variable leaf. WITH XMLNAMESPACES on every shred.

     Two predicate shapes:
       * <Predicate>//<Compare CompareOp>  -- residual / Filter predicates. One ColumnReference
         has @Table (the column); the other has @Column like ''@%'' and no @Table (the variable).
       * <SeekPredicateNew>//RangeColumns/ColumnReference (the key) + RangeExpressions
         (the compared value, ScalarString like ''[@p]'').
     Table variables: a leaf <Object @Table=''[@tv]''> -- the ''@'' is the table, not a scalar var.
------------------------------------------------------------------------------------------------*/
CREATE TABLE #Pred
(
    PredSeq              INT IDENTITY(1,1) PRIMARY KEY,
    PlanRow              INT           NOT NULL,
    CEModelVersion       INT           NULL,
    StmtOptmLevel        NVARCHAR(20)  NULL,
    StmtHasRecompile     BIT           NOT NULL DEFAULT 0,
    VarName              NVARCHAR(128) NULL,
    VarKind              NVARCHAR(20)  NULL,   -- LocalVar / SniffedParam / UnknownParam / TableVar
    ParamCompiledValue   NVARCHAR(256) NULL,
    ParamRuntimeValue    NVARCHAR(256) NULL,
    CompareOp            NVARCHAR(20)  NULL,   -- EQ / GE / LE / LT / GT / ... ; NULL for TableVar
    PredKind             NVARCHAR(20)  NULL,   -- EQUALITY / RANGE / TABLEVAR
    SchemaNameRaw        NVARCHAR(258) NULL,   -- brackets as literal chars (showplan)
    TableNameRaw         NVARCHAR(258) NULL,
    ColumnName           NVARCHAR(128) NULL,
    LeafPhysicalOp       NVARCHAR(60)  NULL,
    LeafIndexRaw         NVARCHAR(258) NULL,
    LeafIndexOrdered     BIT           NULL,
    LeafEstimateRows     FLOAT         NULL,
    LeafEstRowsRead      FLOAT         NULL,
    LeafTableCardinality FLOAT         NULL,
    LeafRowGoal          BIT           NOT NULL DEFAULT 0
);

;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
INSERT #Pred (PlanRow, CEModelVersion, StmtOptmLevel, StmtHasRecompile,
              VarName, CompareOp, PredKind, SchemaNameRaw, TableNameRaw, ColumnName,
              LeafPhysicalOp, LeafIndexRaw, LeafIndexOrdered,
              LeafEstimateRows, LeafEstRowsRead, LeafTableCardinality, LeafRowGoal)
SELECT
    px.StatementSeq,
    stmt.value(''@CardinalityEstimationModelVersion'', ''int''),
    stmt.value(''@StatementOptmLevel'', ''nvarchar(20)''),
    CASE WHEN stmt.exist(''.//StmtSimple[@StatementType="COND"]'') = 1 THEN 0 ELSE 0 END,   -- refined in sec 5
    cr_var.value(''@Column'', ''nvarchar(128)''),
    cmp.value(''@CompareOp'', ''nvarchar(20)''),
    CASE WHEN cmp.value(''@CompareOp'',''nvarchar(20)'') = ''EQ'' THEN N''EQUALITY'' ELSE N''RANGE'' END,
    cr_col.value(''@Schema'', ''nvarchar(258)''),
    cr_col.value(''@Table'',  ''nvarchar(258)''),
    cr_col.value(''@Column'', ''nvarchar(128)''),
    rel.value(''@PhysicalOp'', ''nvarchar(60)''),
    rel.value(''(.//Object/@Index)[1]'', ''nvarchar(258)''),
    CASE WHEN rel.value(''(.//IndexScan/@Ordered)[1]'',''int'') = 1 THEN 1 ELSE 0 END,
    rel.value(''@EstimateRows'', ''float''),
    rel.value(''@EstimatedRowsRead'', ''float''),
    rel.value(''@TableCardinality'', ''float''),
    CASE WHEN rel.exist(''@EstimateRowsWithoutRowGoal'') = 1 THEN 1 ELSE 0 END
FROM #PlanXml px
CROSS APPLY px.PlanXml.nodes(''//StmtSimple[QueryPlan]'') AS S(stmt)
CROSS APPLY stmt.nodes(''.//RelOp'') AS R(rel)
CROSS APPLY rel.nodes(''.//Predicate//Compare'') AS C(cmp)
CROSS APPLY cmp.nodes(''.//ColumnReference[@Table]'') AS X1(cr_col)
CROSS APPLY cmp.nodes(''.//ColumnReference[not(@Table)][substring(@Column,1,1)="@"]'') AS X2(cr_var)
WHERE px.PlanXml IS NOT NULL;

/*  Seek-predicate shape: key column in RangeColumns, variable in RangeExpressions/@ScalarString. */
;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
INSERT #Pred (PlanRow, CEModelVersion, StmtOptmLevel,
              VarName, CompareOp, PredKind, SchemaNameRaw, TableNameRaw, ColumnName,
              LeafPhysicalOp, LeafIndexRaw, LeafIndexOrdered,
              LeafEstimateRows, LeafEstRowsRead, LeafTableCardinality, LeafRowGoal)
SELECT
    px.StatementSeq,
    stmt.value(''@CardinalityEstimationModelVersion'', ''int''),
    stmt.value(''@StatementOptmLevel'', ''nvarchar(20)''),
    -- variable name: first @token inside the RangeExpressions ScalarString, e.g. "[@pid]"
    REPLACE(REPLACE(rex.value(''(.//ColumnReference[not(@Table)][substring(@Column,1,1)="@"]/@Column)[1]'',''nvarchar(128)''), ''['',''''),'']'',''''),
    part.value(''local-name(.)'', ''nvarchar(20)''),   -- Prefix / StartRange / EndRange
    CASE WHEN part.value(''local-name(.)'',''nvarchar(20)'') = ''Prefix'' THEN N''EQUALITY'' ELSE N''RANGE'' END,
    rc.value(''@Schema'', ''nvarchar(258)''),
    rc.value(''@Table'',  ''nvarchar(258)''),
    rc.value(''@Column'', ''nvarchar(128)''),
    rel.value(''@PhysicalOp'', ''nvarchar(60)''),
    rel.value(''(.//Object/@Index)[1]'', ''nvarchar(258)''),
    CASE WHEN rel.value(''(.//IndexScan/@Ordered)[1]'',''int'') = 1 THEN 1 ELSE 0 END,
    rel.value(''@EstimateRows'', ''float''),
    rel.value(''@EstimatedRowsRead'', ''float''),
    rel.value(''@TableCardinality'', ''float''),
    CASE WHEN rel.exist(''@EstimateRowsWithoutRowGoal'') = 1 THEN 1 ELSE 0 END
FROM #PlanXml px
CROSS APPLY px.PlanXml.nodes(''//StmtSimple[QueryPlan]'') AS S(stmt)
CROSS APPLY stmt.nodes(''.//RelOp'') AS R(rel)
CROSS APPLY rel.nodes(''.//SeekPredicateNew/SeekKeys/*'') AS P(part)
CROSS APPLY part.nodes(''RangeColumns/ColumnReference[@Table]'') AS RCX(rc)
CROSS APPLY part.nodes(''RangeExpressions'') AS REX(rex)
WHERE px.PlanXml IS NOT NULL
  AND rex.exist(''.//ColumnReference[not(@Table)][substring(@Column,1,1)="@"]'') = 1;

/*  Table-variable leaves: <Object @Table=''[@tv]''>. One row per such leaf.                        */
;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
INSERT #Pred (PlanRow, CEModelVersion, VarName, VarKind, PredKind,
              SchemaNameRaw, TableNameRaw, LeafPhysicalOp, LeafEstimateRows,
              LeafEstRowsRead, LeafTableCardinality, LeafRowGoal)
SELECT
    px.StatementSeq,
    stmt.value(''@CardinalityEstimationModelVersion'', ''int''),
    REPLACE(REPLACE(obj.value(''@Table'',''nvarchar(258)''), ''['',''''),'']'',''''),
    N''TableVar'',
    N''TABLEVAR'',
    obj.value(''@Schema'',''nvarchar(258)''),
    obj.value(''@Table'', ''nvarchar(258)''),
    rel.value(''@PhysicalOp'', ''nvarchar(60)''),
    rel.value(''@EstimateRows'', ''float''),
    rel.value(''@EstimatedRowsRead'', ''float''),
    rel.value(''@TableCardinality'', ''float''),
    CASE WHEN rel.exist(''@EstimateRowsWithoutRowGoal'') = 1 THEN 1 ELSE 0 END
FROM #PlanXml px
CROSS APPLY px.PlanXml.nodes(''//StmtSimple[QueryPlan]'') AS S(stmt)
CROSS APPLY stmt.nodes(''.//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")]'') AS R(rel)
CROSS APPLY rel.nodes(''*/Object[substring(@Table,1,2)="[@"]'') AS O(obj)   -- direct grandchild only: the leaf''s own Object, not an ancestor''s
WHERE px.PlanXml IS NOT NULL;

/*  Statement-level OPTION (RECOMPILE) -- from the statement text.                                 */
DROP TABLE IF EXISTS #RecompileStmt;
;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
SELECT DISTINCT px.StatementSeq AS PlanRow
INTO #RecompileStmt
FROM #PlanXml px
CROSS APPLY px.PlanXml.nodes(''//StmtSimple[QueryPlan]'') AS S(stmt)
WHERE px.PlanXml IS NOT NULL
  AND UPPER(REPLACE(REPLACE(stmt.value(''@StatementText'',''nvarchar(max)''), CHAR(13),'' ''), CHAR(10),'' '')) LIKE ''%OPTION %RECOMPILE%'';

UPDATE p SET StmtHasRecompile = 1
FROM #Pred p WHERE EXISTS (SELECT 1 FROM #RecompileStmt rs WHERE rs.PlanRow = p.PlanRow);

/*------------------------------------------------------------------------------------------------
  5. CLASSIFY each @name -- cross-reference <ParameterList>.
       in ParameterList WITH ParameterCompiledValue  -> SniffedParam
       in ParameterList WITHOUT a compiled value      -> UnknownParam (OPTIMIZE FOR UNKNOWN / TF4136 / DSC off / RECOMPILE-inlined)
       @name in a predicate but NOT in ParameterList  -> LocalVar
------------------------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS #ParamList;
CREATE TABLE #ParamList
(
    PlanRow       INT,
    ParamName     NVARCHAR(128),
    CompiledValue NVARCHAR(256),
    RuntimeValue  NVARCHAR(256)
);
;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
INSERT #ParamList (PlanRow, ParamName, CompiledValue, RuntimeValue)
SELECT px.StatementSeq,
       pr.value(''@Column'', ''nvarchar(128)''),
       pr.value(''@ParameterCompiledValue'', ''nvarchar(256)''),
       pr.value(''@ParameterRuntimeValue'',  ''nvarchar(256)'')
FROM #PlanXml px
CROSS APPLY px.PlanXml.nodes(''//QueryPlan/ParameterList/ColumnReference'') AS PR(pr)
WHERE px.PlanXml IS NOT NULL;

UPDATE p
SET VarKind = CASE
                WHEN pl.ParamName IS NULL THEN N''LocalVar''
                WHEN pl.CompiledValue IS NOT NULL THEN N''SniffedParam''
                ELSE N''UnknownParam''
              END,
    ParamCompiledValue = pl.CompiledValue,
    ParamRuntimeValue  = pl.RuntimeValue
FROM #Pred p
LEFT JOIN #ParamList pl ON pl.PlanRow = p.PlanRow AND pl.ParamName = p.VarName
WHERE p.VarKind IS NULL;   -- TableVar rows already set

/*  RECOMPILE folds the variable to a literal -> the optimizer used the histogram directly.       */
UPDATE #Pred SET VarKind = N''FoldedLiteral''
WHERE StmtHasRecompile = 1 AND VarKind IN (N''LocalVar'', N''SniffedParam'', N''UnknownParam'');

/*  Drop rows that are not actually variable-driven (both sides columns, or a constant slipped in). */
DELETE FROM #Pred WHERE VarName IS NULL AND VarKind <> N''TableVar'';

/*  One row per (variable, table, column, operator): a predicate seen at a Seek leaf AND again as
    a residual on the Key Lookup, or as a Compare, collapses to one -- prefer the Seek leaf (that
    is the access the tipping point is about), then the smallest leaf estimate.                   */
;WITH d AS
(
    SELECT PredSeq,
           ROW_NUMBER() OVER (
             PARTITION BY PlanRow, VarName, TableNameRaw, ColumnName, CompareOp, VarKind
             ORDER BY CASE WHEN LeafPhysicalOp LIKE ''%Seek%'' THEN 0 ELSE 1 END,
                      LeafEstimateRows,
                      PredSeq) AS rn
    FROM #Pred
)
DELETE FROM #Pred WHERE PredSeq IN (SELECT PredSeq FROM d WHERE rn > 1);

DECLARE @cAll INT, @cLV INT, @cSP INT, @cUP INT, @cTV INT, @cFL INT;
SELECT @cAll = COUNT(*),
       @cLV = SUM(CASE WHEN VarKind = ''LocalVar''     THEN 1 ELSE 0 END),
       @cSP = SUM(CASE WHEN VarKind = ''SniffedParam'' THEN 1 ELSE 0 END),
       @cUP = SUM(CASE WHEN VarKind = ''UnknownParam'' THEN 1 ELSE 0 END),
       @cTV = SUM(CASE WHEN VarKind = ''TableVar''     THEN 1 ELSE 0 END),
       @cFL = SUM(CASE WHEN VarKind = ''FoldedLiteral'' THEN 1 ELSE 0 END)
FROM #Pred;
PRINT ''--- Predicates extracted: '' + CONVERT(VARCHAR(10), @cAll)
    + ''  (LocalVar '' + CONVERT(VARCHAR(10), @cLV)
    + '', SniffedParam '' + CONVERT(VARCHAR(10), @cSP)
    + '', UnknownParam '' + CONVERT(VARCHAR(10), @cUP)
    + '', TableVar '' + CONVERT(VARCHAR(10), @cTV)
    + '', FoldedLiteral '' + CONVERT(VARCHAR(10), @cFL) + '')'';

/*------------------------------------------------------------------------------------------------
  6. RESOLVE STATISTICS for each predicate column (LocalVar / SniffedParam / UnknownParam /
     FoldedLiteral -- not TableVar). One #StatResolved row per (PlanRow predicate). Pulls:
       * the statistic: leading-column match, cross-checked against <OptimizerStatsUsage>;
       * sys.dm_db_stats_properties: rows / modification_counter / last_updated / steps / sampling;
       * all_density via DBCC SHOW_STATISTICS WITH DENSITY_VECTOR (INSERT ... EXEC);
       * the histogram into #Histogram;
       * in_row_data_page_count for the base table.
------------------------------------------------------------------------------------------------*/
CREATE TABLE #StatsUsage
(
    PlanRow      INT,
    SchemaRaw    NVARCHAR(258),
    TableRaw     NVARCHAR(258),
    StatNameRaw  NVARCHAR(258),
    ModCount     BIGINT,
    SamplingPct  FLOAT,
    LastUpdate   NVARCHAR(40)
);
;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
INSERT #StatsUsage (PlanRow, SchemaRaw, TableRaw, StatNameRaw, ModCount, SamplingPct, LastUpdate)
SELECT px.StatementSeq,
       si.value(''@Schema'',''nvarchar(258)''),
       si.value(''@Table'',''nvarchar(258)''),
       si.value(''@Statistics'',''nvarchar(258)''),
       si.value(''@ModificationCount'',''bigint''),
       si.value(''@SamplingPercent'',''float''),
       si.value(''@LastUpdate'',''nvarchar(40)'')
FROM #PlanXml px
CROSS APPLY px.PlanXml.nodes(''//OptimizerStatsUsage/StatisticsInfo'') AS SI(si)
WHERE px.PlanXml IS NOT NULL;

CREATE TABLE #StatResolved
(
    PredSeq          INT PRIMARY KEY,
    ObjectId         INT NULL,
    StatsId          INT NULL,
    StatName         SYSNAME NULL,
    SchemaName       SYSNAME NULL,
    TableName        SYSNAME NULL,
    ColumnName       SYSNAME NULL,
    StatFromUsage    BIT NOT NULL DEFAULT 0,   -- 1 = named by <OptimizerStatsUsage>, 0 = leading-column guess
    HasStats         BIT NOT NULL DEFAULT 0,
    StatRows         BIGINT NULL,
    RowsSampled      BIGINT NULL,
    Steps            INT NULL,
    ModCounter       BIGINT NULL,
    LastUpdated      DATETIME2(3) NULL,
    SampledPct       DECIMAL(6,2) NULL,
    AllDensity       FLOAT NULL,
    LeadingDistinct  FLOAT NULL,               -- 1 / all_density
    InRowDataPages   BIGINT NULL,
    TableRowCount    BIGINT NULL
);

INSERT #StatResolved (PredSeq, ObjectId, SchemaName, TableName, ColumnName)
SELECT p.PredSeq,
       OBJECT_ID(QUOTENAME(PARSENAME(REPLACE(REPLACE(p.SchemaNameRaw,''['',''''),'']'',''''),1))
                 + ''.'' + QUOTENAME(REPLACE(REPLACE(p.TableNameRaw,''['',''''),'']'',''''))),
       PARSENAME(REPLACE(REPLACE(p.SchemaNameRaw,''['',''''),'']'',''''),1),
       REPLACE(REPLACE(p.TableNameRaw,''['',''''),'']'',''''),
       p.ColumnName
FROM #Pred p
WHERE p.VarKind IN (N''LocalVar'', N''SniffedParam'', N''UnknownParam'', N''FoldedLiteral'')
  AND p.ColumnName IS NOT NULL;

/*  Pick the statistic: (1) the one <OptimizerStatsUsage> names whose leading column is our column;
    (2) else any statistic whose leading column is our column, preferring an index stat, most
    recently updated.                                                                            */
;WITH cand AS
(
    SELECT sr.PredSeq, s.object_id, s.stats_id, s.name AS stat_name,
           ROW_NUMBER() OVER (PARTITION BY sr.PredSeq
                              ORDER BY CASE WHEN su.StatNameRaw IS NOT NULL THEN 0 ELSE 1 END,
                                       CASE WHEN s.auto_created = 0 THEN 0 ELSE 1 END,
                                       sp.last_updated DESC) AS rn,
           CASE WHEN su.StatNameRaw IS NOT NULL THEN 1 ELSE 0 END AS from_usage
    FROM #StatResolved sr
    JOIN sys.stats         s  ON s.object_id = sr.ObjectId
    JOIN sys.stats_columns sc ON sc.object_id = s.object_id AND sc.stats_id = s.stats_id AND sc.stats_column_id = 1
    JOIN sys.columns       c  ON c.object_id = s.object_id AND c.column_id = sc.column_id AND c.name = sr.ColumnName
    OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
    LEFT JOIN #StatsUsage su ON su.PlanRow = (SELECT PlanRow FROM #Pred WHERE PredSeq = sr.PredSeq)
                            AND REPLACE(REPLACE(su.StatNameRaw,''['',''''),'']'','''') = s.name
)
UPDATE sr
SET StatsId = cand.stats_id, StatName = cand.stat_name, StatFromUsage = cand.from_usage, HasStats = 1
FROM #StatResolved sr
JOIN cand ON cand.PredSeq = sr.PredSeq AND cand.rn = 1;

/*  Properties + page count for the resolved statistics.                                          */
UPDATE sr
SET StatRows    = sp.rows,
    RowsSampled = sp.rows_sampled,
    Steps       = sp.steps,
    ModCounter  = sp.modification_counter,
    LastUpdated = sp.last_updated,
    SampledPct  = CASE WHEN sp.rows > 0 THEN CONVERT(DECIMAL(6,2), 100.0 * sp.rows_sampled / sp.rows) END
FROM #StatResolved sr
CROSS APPLY sys.dm_db_stats_properties(sr.ObjectId, sr.StatsId) sp
WHERE sr.HasStats = 1;

UPDATE sr
SET InRowDataPages = x.pages, TableRowCount = x.rc
FROM #StatResolved sr
CROSS APPLY (
    SELECT SUM(ps.in_row_data_page_count) AS pages, SUM(ps.row_count) AS rc
    FROM sys.dm_db_partition_stats ps
    JOIN sys.partitions pt ON pt.partition_id = ps.partition_id
    WHERE ps.object_id = sr.ObjectId AND pt.index_id IN (0, 1)
) x
WHERE sr.ObjectId IS NOT NULL;

/*  all_density via DBCC SHOW_STATISTICS ... WITH DENSITY_VECTOR, one INSERT..EXEC per distinct
    (ObjectId, StatsId). #DensityVector target is created in the OUTER scope (the procedure form
    reuses the same pattern; a batch-local target dies with the dynamic batch).                  */
CREATE TABLE #DensityVector (AllDensity FLOAT, AvgLength FLOAT, Cols NVARCHAR(2000));
CREATE TABLE #DensityResolved (ObjectId INT, StatsId INT, AllDensity FLOAT);

DECLARE @dvObj INT, @dvStat INT, @dvSql NVARCHAR(1000), @dvName NVARCHAR(600);
DECLARE dv CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT ObjectId, StatsId FROM #StatResolved WHERE HasStats = 1;
OPEN dv;
FETCH NEXT FROM dv INTO @dvObj, @dvStat;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @dvName = QUOTENAME(OBJECT_SCHEMA_NAME(@dvObj)) + ''.'' + QUOTENAME(OBJECT_NAME(@dvObj));
    SET @dvSql = N''DBCC SHOW_STATISTICS ('' + QUOTENAME(@dvName, '''''''') + N'', ''
               + QUOTENAME((SELECT name FROM sys.stats WHERE object_id = @dvObj AND stats_id = @dvStat), '''''''')
               + N'') WITH DENSITY_VECTOR'';
    TRUNCATE TABLE #DensityVector;
    BEGIN TRY
        INSERT #DensityVector EXEC (@dvSql);
        INSERT #DensityResolved (ObjectId, StatsId, AllDensity)
        SELECT TOP (1) @dvObj, @dvStat, AllDensity FROM #DensityVector ORDER BY AvgLength;  -- shortest = leading column
    END TRY
    BEGIN CATCH
        INSERT #DensityResolved (ObjectId, StatsId, AllDensity) VALUES (@dvObj, @dvStat, NULL);
    END CATCH
    FETCH NEXT FROM dv INTO @dvObj, @dvStat;
END
CLOSE dv; DEALLOCATE dv;

UPDATE sr
SET AllDensity = dr.AllDensity,
    LeadingDistinct = CASE WHEN dr.AllDensity > 0 THEN 1.0 / dr.AllDensity END
FROM #StatResolved sr
JOIN #DensityResolved dr ON dr.ObjectId = sr.ObjectId AND dr.StatsId = sr.StatsId;

/*  Histogram for every resolved statistic.                                                       */
CREATE TABLE #Histogram
(
    PredSeq           INT,
    StepNumber        INT,
    RangeHighKeyStr   NVARCHAR(256),
    RangeHighKeyNum   FLOAT NULL,
    RangeRows         FLOAT,
    EqualRows         FLOAT,
    DistinctRangeRows BIGINT,
    AvgRangeRows      FLOAT
);
INSERT #Histogram (PredSeq, StepNumber, RangeHighKeyStr, RangeHighKeyNum, RangeRows, EqualRows, DistinctRangeRows, AvgRangeRows)
SELECT sr.PredSeq, h.step_number,
       CONVERT(NVARCHAR(256), h.range_high_key),
       CASE WHEN CONVERT(SYSNAME, SQL_VARIANT_PROPERTY(h.range_high_key, ''BaseType''))
                 IN (''tinyint'',''smallint'',''int'',''bigint'',''decimal'',''numeric'',''float'',''real'',''money'',''smallmoney'')
            THEN CONVERT(FLOAT, h.range_high_key) END,
       h.range_rows, h.equal_rows, h.distinct_range_rows, h.average_range_rows
FROM #StatResolved sr
CROSS APPLY sys.dm_db_stats_histogram(sr.ObjectId, sr.StatsId) h
WHERE sr.HasStats = 1;

DECLARE @srHas INT = (SELECT COUNT(*) FROM #StatResolved WHERE HasStats = 1);
DECLARE @srAll INT = (SELECT COUNT(*) FROM #StatResolved);
DECLARE @hSteps INT = (SELECT COUNT(*) FROM #Histogram);
PRINT ''--- Stats resolved for '' + CONVERT(VARCHAR(10), @srHas) + '' of '' + CONVERT(VARCHAR(10), @srAll)
    + '' predicate column(s); '' + CONVERT(VARCHAR(10), @hSteps) + '' histogram step(s) loaded.'';

/*------------------------------------------------------------------------------------------------
  7-10. ASSEMBLE #Result -- one row per predicate. Compute, per regime:
        * the estimate the optimizer will use (ComputedOptimizerEstimate) + EstimateSource;
        * the plan''s own estimate (PlanEstimateRows) as a cross-check;
        * the histogram truth (max EQ_ROWS, skew ratio, truth-for-known-value, top heavy values);
        * EstimateVsTruthRatio -- the static skew;
        * the heuristic tipping point (TippingPointRows), TippingValue guidance, WillTip;
        * StatsStale;
        * [Fix] -- advisory text, DDL commented out.
------------------------------------------------------------------------------------------------*/
CREATE TABLE #Result
(
    PredSeq                    INT,
    VariableName               NVARCHAR(128),
    VariableKind               NVARCHAR(20),
    SchemaName                 SYSNAME NULL,
    TableName                  SYSNAME NULL,
    ColumnName                 SYSNAME NULL,
    PredicateOp                NVARCHAR(20) NULL,
    PredicateKind              NVARCHAR(20) NULL,
    IndexInPlay                NVARCHAR(258) NULL,
    LeafPhysicalOp             NVARCHAR(60) NULL,
    IsCovering                 BIT NULL,
    RowGoalActive              BIT NULL,
    CEModelVersion             INT NULL,
    Regime                     NVARCHAR(120) NULL,
    ComputedOptimizerEstimate  FLOAT NULL,
    EstimateSource             NVARCHAR(30) NULL,
    PlanEstimateRows           FLOAT NULL,
    ModelExplainsPlan          NVARCHAR(10) NULL,   -- yes / NO (>2x apart)
    HistogramTruthForValue     FLOAT NULL,
    KnownValue                 NVARCHAR(256) NULL,
    HistogramMaxEqRows         FLOAT NULL,
    HistogramSkewRatio         DECIMAL(12,2) NULL,
    TopHeavyValues             NVARCHAR(400) NULL,
    EstimateVsTruthRatio       DECIMAL(12,2) NULL,  -- worst-case: HistogramMaxEqRows / ComputedOptimizerEstimate
    SkewDirection              NVARCHAR(10) NULL,
    TippingPointRows           FLOAT NULL,
    HistSteps                  INT NULL,
    StepsAboveTipping          INT NULL,
    TippingValueNote           NVARCHAR(300) NULL,
    WillTip                    NVARCHAR(40) NULL,
    StatName                   SYSNAME NULL,
    StatFromUsage              BIT NULL,
    StatsSampledPct            DECIMAL(6,2) NULL,
    StatsModFraction           DECIMAL(12,4) NULL,
    StatsLastUpdated           DATETIME2(3) NULL,
    StatsStale                 BIT NULL,
    Fix                        NVARCHAR(1000) NULL,
    ProbeValues                NVARCHAR(600) NULL,
    ProbeSweepScript           NVARCHAR(MAX) NULL,
    PreciseCrossover           NVARCHAR(300) NULL
);

/*  Per-predicate histogram aggregates.                                                           */
DROP TABLE IF EXISTS #HistAgg;
SELECT h.PredSeq,
       COUNT(*)                                            AS Steps,
       MAX(h.EqualRows)                                    AS MaxEq,
       AVG(h.EqualRows)                                    AS AvgEq,
       CONVERT(DECIMAL(12,2), MAX(h.EqualRows) / NULLIF(AVG(h.EqualRows), 0)) AS SkewRatio
INTO #HistAgg
FROM #Histogram h
GROUP BY h.PredSeq;

/*  Top 3 heavy values per predicate (FOR XML PATH -- STRING_AGG needs 130+, and no DISTINCT).    */
DROP TABLE IF EXISTS #TopHeavy;
SELECT x.PredSeq,
       STUFF((SELECT N'', '' + h2.RangeHighKeyStr + N'' ('' + CONVERT(NVARCHAR(20), CONVERT(BIGINT, h2.EqualRows)) + N'')''
              FROM #Histogram h2
              WHERE h2.PredSeq = x.PredSeq
              ORDER BY h2.EqualRows DESC
              FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(400)''), 1, 2, N'''') AS TopHeavy
INTO #TopHeavy
FROM (SELECT DISTINCT PredSeq FROM #Histogram) x;
-- keep only the first ~3 named (trim after the 3rd comma-group) -- cosmetic
UPDATE #TopHeavy
SET TopHeavy = LEFT(TopHeavy, ISNULL(NULLIF(CHARINDEX(N'','', TopHeavy,
                    ISNULL(NULLIF(CHARINDEX(N'','', TopHeavy,
                        ISNULL(NULLIF(CHARINDEX(N'','', TopHeavy, 1), 0), LEN(TopHeavy)) + 1), 0), LEN(TopHeavy)) + 1), 0), LEN(TopHeavy)) - 1)
WHERE TopHeavy IS NOT NULL AND LEN(TopHeavy) > 60;

INSERT #Result
(
    PredSeq, VariableName, VariableKind, SchemaName, TableName, ColumnName, PredicateOp, PredicateKind,
    IndexInPlay, LeafPhysicalOp, RowGoalActive, CEModelVersion, Regime,
    ComputedOptimizerEstimate, EstimateSource, PlanEstimateRows,
    HistogramMaxEqRows, HistogramSkewRatio, TopHeavyValues,
    KnownValue, StatName, StatFromUsage, StatsSampledPct, StatsModFraction, StatsLastUpdated,
    HistSteps, TippingPointRows
)
SELECT
    p.PredSeq,
    p.VarName,
    p.VarKind,
    REPLACE(REPLACE(p.SchemaNameRaw,''['',''''),'']'',''''),
    REPLACE(REPLACE(p.TableNameRaw,''['',''''),'']'',''''),
    p.ColumnName,
    p.CompareOp,
    p.PredKind,
    REPLACE(REPLACE(p.LeafIndexRaw,''['',''''),'']'',''''),
    p.LeafPhysicalOp,
    p.LeafRowGoal,
    p.CEModelVersion,
    N''compat='' + CONVERT(VARCHAR(10), @CompatLevel)
      + N'' CE='' + CONVERT(VARCHAR(10), ISNULL(p.CEModelVersion, @CompatLevel))
      + N'' deferredTV='' + CASE WHEN @TableVarDeferred = 1 THEN N''ON'' ELSE N''OFF'' END
      + N'' sniffing='' + CASE WHEN CONVERT(INT, ISNULL(@DscParamSniff,1)) = 1 THEN N''ON'' ELSE N''OFF'' END
      + CASE WHEN @PspActive = 1 THEN N'' PSP=ON'' ELSE N'''' END,
    /*  ComputedOptimizerEstimate  */
    CASE
      WHEN p.VarKind = N''TableVar''
           THEN CASE WHEN @TableVarDeferred = 1 AND p.LeafEstimateRows > 1.5 THEN p.LeafEstimateRows ELSE 1.0 END
      WHEN p.VarKind = N''SniffedParam'' AND p.PredKind = N''EQUALITY''
           THEN COALESCE(
                  (SELECT TOP 1 h.EqualRows FROM #Histogram h
                   WHERE h.PredSeq = p.PredSeq AND h.RangeHighKeyStr = REPLACE(REPLACE(p.ParamCompiledValue,''('',''''),'')'','''')),
                  (SELECT TOP 1 h.AvgRangeRows FROM #Histogram h
                   WHERE h.PredSeq = p.PredSeq AND h.RangeHighKeyNum >= CASE WHEN REPLACE(REPLACE(p.ParamCompiledValue, ''('', ''''), '')'', '''') NOT LIKE ''%[^0-9.]%'' AND REPLACE(REPLACE(p.ParamCompiledValue, ''('', ''''), '')'', '''') LIKE ''%[0-9]%'' THEN CONVERT(FLOAT, REPLACE(REPLACE(p.ParamCompiledValue, ''('', ''''), '')'', '''')) END
                   ORDER BY h.RangeHighKeyNum),
                  p.LeafEstimateRows)
      WHEN p.VarKind IN (N''LocalVar'', N''UnknownParam'') AND p.PredKind = N''EQUALITY'' AND sr.HasStats = 1 AND sr.AllDensity > 0
           THEN CONVERT(FLOAT, COALESCE(sr.TableRowCount, sr.StatRows, p.LeafTableCardinality)) * sr.AllDensity
      WHEN p.VarKind IN (N''LocalVar'', N''UnknownParam'') AND p.PredKind = N''EQUALITY''
           THEN CONVERT(FLOAT, COALESCE(sr.TableRowCount, p.LeafTableCardinality)) * 0.10
      WHEN p.VarKind IN (N''LocalVar'', N''UnknownParam'') AND p.PredKind = N''RANGE''
           THEN CONVERT(FLOAT, COALESCE(sr.TableRowCount, p.LeafTableCardinality)) * 0.30
      WHEN p.VarKind = N''FoldedLiteral''
           THEN p.LeafEstimateRows
      ELSE p.LeafEstimateRows
    END,
    /*  EstimateSource  */
    CASE
      WHEN p.VarKind = N''TableVar'' AND @TableVarDeferred = 1 AND p.LeafEstimateRows > 1.5 THEN N''DeferredCompile''
      WHEN p.VarKind = N''TableVar''                           THEN N''TableVar1Row''
      WHEN p.VarKind = N''SniffedParam''                       THEN N''SniffedValue''
      WHEN p.VarKind IN (N''LocalVar'', N''UnknownParam'') AND p.PredKind = N''EQUALITY'' AND sr.HasStats = 1 AND sr.AllDensity > 0 THEN N''Density''
      WHEN p.VarKind IN (N''LocalVar'', N''UnknownParam'') AND p.PredKind = N''EQUALITY'' THEN N''Guess10Pct''
      WHEN p.VarKind IN (N''LocalVar'', N''UnknownParam'') AND p.PredKind = N''RANGE''    THEN N''Guess30Pct''
      WHEN p.VarKind = N''FoldedLiteral''                      THEN N''FoldedLiteral''
      ELSE N''PlanValue''
    END,
    p.LeafEstimateRows,
    ha.MaxEq,
    ha.SkewRatio,
    th.TopHeavy,
    CASE WHEN p.VarKind = N''SniffedParam'' THEN p.ParamCompiledValue
         WHEN p.VarKind IN (N''UnknownParam'') THEN p.ParamRuntimeValue END,
    sr.StatName,
    sr.StatFromUsage,
    sr.SampledPct,
    CASE WHEN sr.StatRows > 0 THEN CONVERT(DECIMAL(12,4), 1.0 * sr.ModCounter / sr.StatRows) END,
    sr.LastUpdated,
    ha.Steps,
    CASE WHEN sr.InRowDataPages IS NOT NULL
         THEN CONVERT(FLOAT, sr.InRowDataPages) * @TippingPointPageFraction END
FROM #Pred p
LEFT JOIN #StatResolved sr ON sr.PredSeq = p.PredSeq
LEFT JOIN #HistAgg      ha ON ha.PredSeq = p.PredSeq
LEFT JOIN #TopHeavy     th ON th.PredSeq = p.PredSeq;

/*  Derived columns.                                                                              */
UPDATE r
SET ModelExplainsPlan = CASE
        WHEN r.ComputedOptimizerEstimate IS NULL OR r.PlanEstimateRows IS NULL THEN N''n/a''
        WHEN r.PlanEstimateRows BETWEEN r.ComputedOptimizerEstimate / 2.0 AND r.ComputedOptimizerEstimate * 2.0 THEN N''yes''
        ELSE N''NO'' END,
    HistogramTruthForValue = CASE WHEN r.KnownValue IS NOT NULL THEN
        COALESCE(
          (SELECT TOP 1 h.EqualRows FROM #Histogram h WHERE h.PredSeq = r.PredSeq AND h.RangeHighKeyStr = REPLACE(REPLACE(r.KnownValue,''('',''''),'')'','''')),
          (SELECT TOP 1 h.AvgRangeRows FROM #Histogram h WHERE h.PredSeq = r.PredSeq
             AND h.RangeHighKeyNum >= CASE WHEN REPLACE(REPLACE(r.KnownValue, ''('', ''''), '')'', '''') NOT LIKE ''%[^0-9.]%'' AND REPLACE(REPLACE(r.KnownValue, ''('', ''''), '')'', '''') LIKE ''%[0-9]%'' THEN CONVERT(FLOAT, REPLACE(REPLACE(r.KnownValue, ''('', ''''), '')'', '''')) END ORDER BY h.RangeHighKeyNum)
        ) END,
    EstimateVsTruthRatio = CASE WHEN r.ComputedOptimizerEstimate > 0 AND r.HistogramMaxEqRows IS NOT NULL
        THEN CONVERT(DECIMAL(12,2), r.HistogramMaxEqRows / r.ComputedOptimizerEstimate) END,
    SkewDirection = CASE WHEN r.HistogramMaxEqRows > r.ComputedOptimizerEstimate THEN N''under''
                         WHEN r.HistogramMaxEqRows < r.ComputedOptimizerEstimate THEN N''over'' END,
    StepsAboveTipping = CASE WHEN r.TippingPointRows IS NOT NULL THEN
        (SELECT COUNT(*) FROM #Histogram h WHERE h.PredSeq = r.PredSeq AND h.EqualRows > r.TippingPointRows) END,
    StatsStale = CASE WHEN r.StatsModFraction >= @StaleStatsModFraction THEN 1 ELSE 0 END
FROM #Result r;

/*  IsCovering: no Key/RID Lookup in the plan for this table  ->  seek needs no lookup  ->  covering.
    When covering, there is no seek->scan tipping point.                                          */
DROP TABLE IF EXISTS #LookupTable;
;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
SELECT DISTINCT px.StatementSeq AS PlanRow,
       REPLACE(REPLACE(o.value(''@Table'',''nvarchar(258)''),''['',''''),'']'','''') AS TableName
INTO #LookupTable
FROM #PlanXml px
CROSS APPLY px.PlanXml.nodes(''
    //RelOp[@PhysicalOp="Key Lookup" or @PhysicalOp="RID Lookup"
            or .//IndexScan[@Lookup="1"] or .//RIDLookup]'') AS L(l)   -- a lookup also serialises as Clustered Index Seek + IndexScan/@Lookup
CROSS APPLY l.nodes(''.//Object'') AS O(o)
WHERE px.PlanXml IS NOT NULL;

UPDATE r
SET IsCovering = CASE WHEN r.LeafPhysicalOp LIKE ''%Seek%''
                       AND NOT EXISTS (SELECT 1 FROM #LookupTable lt
                                       JOIN #Pred p ON p.PredSeq = r.PredSeq
                                       WHERE lt.PlanRow = p.PlanRow AND lt.TableName = r.TableName)
                     THEN 1 ELSE 0 END
FROM #Result r;

UPDATE #Result SET TippingPointRows = NULL, TippingValueNote = N''covering index -- no seek/scan tipping point''
WHERE IsCovering = 1;

UPDATE r
SET TippingValueNote = CASE
      WHEN r.TippingPointRows IS NULL THEN r.TippingValueNote
      WHEN ISNULL(r.HistSteps,0) = 0 THEN N''heuristic tipping point ~'' + CONVERT(VARCHAR(20), CONVERT(BIGINT, r.TippingPointRows)) + N'' rows; no histogram to map it to a value''
      ELSE N''values with > '' + CONVERT(VARCHAR(20), CONVERT(BIGINT, r.TippingPointRows))
           + N'' rows tip to a scan; '' + CONVERT(VARCHAR(10), ISNULL(r.StepsAboveTipping, 0))
           + N'' of '' + CONVERT(VARCHAR(10), ISNULL(r.HistSteps, 0)) + N'' histogram values exceed it''
      END,
    WillTip = CASE
      WHEN r.TippingPointRows IS NULL THEN N''n/a''
      /*  SniffedParam: the danger is not the compiled value itself but REUSE of that plan for a
          heavier value. Judge against the histogram''s worst value, not HistogramTruthForValue
          (which is the -- possibly rare -- value the plan was sniffed on).                       */
      WHEN r.VariableKind = N''SniffedParam''
           THEN CASE
                  WHEN r.HistogramMaxEqRows > r.TippingPointRows
                       AND ISNULL(r.HistogramTruthForValue, r.HistogramMaxEqRows) <= r.TippingPointRows
                       THEN N''yes (sniffing: heavy values tip)''
                  WHEN r.HistogramMaxEqRows > r.TippingPointRows THEN N''yes''
                  ELSE N''no''
                END
      WHEN r.HistogramTruthForValue IS NOT NULL
           THEN CASE WHEN r.HistogramTruthForValue > r.TippingPointRows THEN N''yes'' ELSE N''no'' END
      WHEN r.HistogramMaxEqRows > r.TippingPointRows AND r.LeafPhysicalOp LIKE ''%Seek%'' THEN N''yes (worst value)''
      WHEN r.HistogramMaxEqRows > r.TippingPointRows THEN N''already scanning''
      ELSE N''no''
      END
FROM #Result r;

/*  [Fix] -- advisory; DDL commented out.                                                         */
UPDATE r
SET Fix = CASE
    WHEN r.VariableKind = N''FoldedLiteral''
        THEN N''OPTION (RECOMPILE) in effect -- the histogram is used directly. No action.''
    WHEN r.VariableKind = N''TableVar'' AND r.EstimateSource = N''TableVar1Row''
        THEN N''Table variable estimated at 1 row. If it feeds a join/loop with many rows: switch to a #temp table, ''
           + N''or add OPTION (RECOMPILE)'' + CASE WHEN @CompatLevel >= 150 THEN N'', or confirm DEFERRED_COMPILATION_TV = ON'' ELSE N'''' END + N''.''
    WHEN r.VariableKind = N''TableVar''
        THEN N''Deferred compilation gave the real row count, but the table variable still has NO column statistics -- ''
           + N''downstream filters/joins on its columns still guess. A #temp table gets column stats.''
    WHEN r.VariableKind = N''SniffedParam'' AND r.EstimateVsTruthRatio >= @EstimateVsTruthThreshold
        THEN N''Plan compiled for '' + ISNULL(r.KnownValue, N''(a value)'') + N'' (est '' + CONVERT(VARCHAR(20), CONVERT(BIGINT, r.ComputedOptimizerEstimate))
           + N''); the histogram''''s heaviest value is '' + CONVERT(VARCHAR(20), CONVERT(BIGINT, r.HistogramMaxEqRows))
           + N'' ('' + CONVERT(VARCHAR(20), r.EstimateVsTruthRatio) + N''x). Reusing this plan for a heavy value ''
           + N''is the sniffing risk. OPTIMIZE FOR UNKNOWN (stability) or OPTION (RECOMPILE) (accuracy)''
           + CASE WHEN @PspActive = 1 THEN N''; PSP is on -- check sys.query_store_query_variant.'' ELSE N''.'' END
    WHEN r.VariableKind IN (N''LocalVar'', N''UnknownParam'') AND r.EstimateSource = N''Guess10Pct''
        THEN N''No usable statistics on '' + r.ColumnName + N'' -- the equality estimate is a fixed 10% guess. ''
           + N''CREATE STATISTICS, or make the predicate sargable, or OPTION (RECOMPILE).''
    WHEN r.VariableKind IN (N''LocalVar'', N''UnknownParam'') AND r.EstimateSource = N''Guess30Pct''
        THEN N''A range predicate (> / < / BETWEEN) on a local variable always gets a fixed 30% guess -- ''
           + N''the optimizer cannot place an unknown value in the '' + r.ColumnName + N'' histogram, with or without statistics. ''
           + N''Use a literal, OPTION (RECOMPILE), or OPTIMIZE FOR (<value>).''
    WHEN r.VariableKind IN (N''LocalVar'', N''UnknownParam'') AND r.HistogramSkewRatio >= @SkewRatioThreshold AND r.WillTip LIKE ''yes%''
        THEN N''Local variable -> density estimate '' + CONVERT(VARCHAR(20), CONVERT(BIGINT, r.ComputedOptimizerEstimate))
           + N'', but '' + r.ColumnName + N'' is skewed (ratio '' + CONVERT(VARCHAR(20), r.HistogramSkewRatio)
           + N'') and heavy values exceed the tipping point. OPTION (RECOMPILE), a literal, or OPTIMIZE FOR (<hot value>).''
    WHEN r.VariableKind IN (N''LocalVar'', N''UnknownParam'') AND r.WillTip = N''already scanning''
        THEN N''Local variable -> density estimate already exceeds the tipping point, so the plan is a stable scan. ''
           + N''If the scan cost matters, a covering index (see the plan''''s MissingIndexes) removes the tipping point.''
    WHEN r.VariableKind IN (N''LocalVar'', N''UnknownParam'') AND r.IsCovering = 1 AND r.HistogramSkewRatio >= @SkewRatioThreshold
        THEN N''Local variable on '' + r.ColumnName + N'', covered seek -> no key-lookup explosion, so the '' + CONVERT(VARCHAR(20), r.HistogramSkewRatio)
           + N''x skew does not tip a plan here. Watch memory grant / any Sort in the plan for a heavy value. Otherwise low risk.''
    WHEN r.VariableKind IN (N''LocalVar'', N''UnknownParam'') AND r.IsCovering = 1
        THEN N''Local variable on '' + r.ColumnName + N'', covered seek -> no tipping point. Low risk.''
    WHEN r.VariableKind IN (N''LocalVar'', N''UnknownParam'') AND r.HistogramSkewRatio >= @SkewRatioThreshold
        THEN N''Local variable -> density estimate '' + CONVERT(VARCHAR(20), CONVERT(BIGINT, r.ComputedOptimizerEstimate))
           + N''; '' + r.ColumnName + N'' is skewed (ratio '' + CONVERT(VARCHAR(20), r.HistogramSkewRatio) + N'') but the density plan is a stable scan. ''
           + N''A plan sniffed on a selective value and reused for a heavy one would tip -- see @QueryId analysis. OPTION (RECOMPILE) removes the guess.''
    WHEN r.VariableKind IN (N''LocalVar'', N''UnknownParam'')
        THEN N''Local variable -> density estimate; '' + r.ColumnName + N'' is not materially skewed and the plan is stable. ''
           + N''Low risk; leave it.''
    ELSE N''(no specific guidance)''
  END
    + CASE WHEN r.StatsStale = 1
           THEN N''  -- statistics are stale ('' + CONVERT(VARCHAR(20), CONVERT(DECIMAL(6,3), r.StatsModFraction * 100))
              + N''% modified): -- UPDATE STATISTICS '' + QUOTENAME(r.SchemaName) + N''.'' + QUOTENAME(r.TableName)
              + N''('' + QUOTENAME(r.StatName) + N'') WITH FULLSCAN;''
           ELSE N'''' END
FROM #Result r;

/*------------------------------------------------------------------------------------------------
  11. PROBE SWEEP SCRIPT -- ready-to-run SET SHOWPLAN_XML batch (client-side GO batching, where
      SHOWPLAN_XML works). The DBA runs it and re-invokes with @ProbePlanXml. v1 emits the probe
      VALUES and, when the statement text is clean, a wrapped OPTIMIZE FOR script.
------------------------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS #ProbePick;
CREATE TABLE #ProbePick (PredSeq INT, ProbeValue NVARCHAR(256), ProbeRows BIGINT);

IF @ProbeCardinalitySweep = 1
BEGIN
    /*  One representative value per NTILE bucket of the histogram, spanning the range.            */
    INSERT #ProbePick (PredSeq, ProbeValue, ProbeRows)
    SELECT PredSeq, ProbeValue, ProbeRows
    FROM (
        SELECT tiled.PredSeq, tiled.ProbeValue, tiled.ProbeRows,
               ROW_NUMBER() OVER (PARTITION BY tiled.PredSeq, tiled.tile ORDER BY tiled.ProbeRows) AS rn_in_tile
        FROM (
            SELECT h.PredSeq, h.RangeHighKeyStr AS ProbeValue, CONVERT(BIGINT, h.EqualRows) AS ProbeRows,
                   NTILE(@ProbeValueCount) OVER (PARTITION BY h.PredSeq ORDER BY h.EqualRows) AS tile
            FROM #Histogram h
            JOIN #Result r ON r.PredSeq = h.PredSeq
            WHERE h.RangeHighKeyNum IS NOT NULL
              AND r.VariableKind IN (N''LocalVar'', N''SniffedParam'', N''UnknownParam'')
        ) tiled
    ) q
    WHERE q.rn_in_tile = 1;

    UPDATE r
    SET ProbeValues = LEFT(x.vals, 590),
        ProbeSweepScript =
            N''-- Run this whole batch, then re-invoke TippingPointAnalysis with'' + CHAR(13)+CHAR(10)
          + N''-- @ProbePlanXml = the concatenated <ShowPlanXML> output.'' + CHAR(13)+CHAR(10)
          + N''-- Predicate: '' + ISNULL(r.SchemaName + N''.'' + r.TableName + N''.'' + r.ColumnName, N''?'')
          + N''  (variable '' + ISNULL(r.VariableName, N''?'') + N'', column type '' + ISNULL(ct.type_decl, N''?'') + N'')'' + CHAR(13)+CHAR(10)
          + N''SET SHOWPLAN_XML ON;'' + CHAR(13)+CHAR(10) + N''GO'' + CHAR(13)+CHAR(10)
          + x.script
          + N''SET SHOWPLAN_XML OFF;'' + CHAR(13)+CHAR(10) + N''GO'' + CHAR(13)+CHAR(10)
    FROM #Result r
    OUTER APPLY (
        SELECT type_decl = t.name
             + CASE WHEN t.name IN (''varchar'',''char'',''nvarchar'',''nchar'',''varbinary'',''binary'')
                    THEN N''('' + CASE WHEN c.max_length = -1 THEN N''max''
                                     WHEN t.name IN (''nvarchar'',''nchar'') THEN CONVERT(VARCHAR(10), c.max_length/2)
                                     ELSE CONVERT(VARCHAR(10), c.max_length) END + N'')''
                    WHEN t.name IN (''decimal'',''numeric'') THEN N''('' + CONVERT(VARCHAR(10), c.precision) + N'','' + CONVERT(VARCHAR(10), c.scale) + N'')''
                    ELSE N'''' END
        FROM sys.columns c
        JOIN sys.types   t ON t.user_type_id = c.user_type_id
        WHERE c.object_id = OBJECT_ID(QUOTENAME(r.SchemaName) + N''.'' + QUOTENAME(r.TableName))
          AND c.name = r.ColumnName
    ) ct
    CROSS APPLY (
        SELECT
          vals = STUFF((SELECT N'', '' + pk.ProbeValue + N''~'' + CONVERT(VARCHAR(20), pk.ProbeRows)
                        FROM #ProbePick pk WHERE pk.PredSeq = r.PredSeq
                        ORDER BY pk.ProbeRows FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(700)''), 1, 2, N''''),
          script = ISNULL((SELECT
                        N''DECLARE @x '' + ISNULL(ct.type_decl, N''sql_variant'') + N'' = '' + pk.ProbeValue + N'';'' + CHAR(13)+CHAR(10)
                      + N''SELECT * FROM '' + QUOTENAME(r.SchemaName) + N''.'' + QUOTENAME(r.TableName)
                      + N'' WHERE '' + QUOTENAME(r.ColumnName) + N'' = @x''
                      + N'' OPTION (OPTIMIZE FOR (@x = '' + pk.ProbeValue + N''));  -- FROM '' + r.SchemaName + N''.'' + r.TableName + N'' -- probe rows ~ '' + CONVERT(VARCHAR(20), pk.ProbeRows)
                      + CHAR(13)+CHAR(10) + N''GO'' + CHAR(13)+CHAR(10)
                      FROM #ProbePick pk WHERE pk.PredSeq = r.PredSeq
                      ORDER BY pk.ProbeRows
                      FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''),
                    N''-- (no numeric probe values available for this predicate)'' + CHAR(13)+CHAR(10))
    ) x
    WHERE EXISTS (SELECT 1 FROM #ProbePick pk WHERE pk.PredSeq = r.PredSeq);
END

/*------------------------------------------------------------------------------------------------
  11b. SECOND PASS -- fold in the precise crossovers from @ProbePlanXml (the concatenated
       <ShowPlanXML> output of the [ProbeSweepScript]). For each probed OPTIMIZE FOR value, read
       the leaf physical op for the target table and the join operators; order by the value; the
       point where the leaf op flips (Seek <-> Scan) or the join type changes is the crossover.
------------------------------------------------------------------------------------------------*/
IF @ProbePlanXml IS NOT NULL
BEGIN
    DROP TABLE IF EXISTS #ProbePlan;
    CREATE TABLE #ProbePlan (Seq INT IDENTITY(1,1) PRIMARY KEY, PlanXml XML);

    /*  Split the paste on the <ShowPlanXML ...> root boundary with a WHILE loop -- at most a
        dozen probe docs, and this avoids STRING_SPLIT''s 2022+/compat-160 ordinal argument.       */
    DECLARE @pp NVARCHAR(MAX) = @ProbePlanXml;
    DECLARE @s1 INT = CHARINDEX(N''<ShowPlanXML'', @pp);
    DECLARE @e1 INT;
    WHILE @s1 > 0
    BEGIN
        SET @e1 = CHARINDEX(N''</ShowPlanXML>'', @pp, @s1);
        IF @e1 = 0 BREAK;
        BEGIN TRY
            INSERT #ProbePlan (PlanXml)
            VALUES (CONVERT(XML, SUBSTRING(@pp, @s1, @e1 - @s1 + LEN(N''</ShowPlanXML>''))));
        END TRY BEGIN CATCH END CATCH
        SET @s1 = CHARINDEX(N''<ShowPlanXML'', @pp, @e1);
    END

    IF NOT EXISTS (SELECT 1 FROM #ProbePlan)
        BEGIN TRY INSERT #ProbePlan (PlanXml) SELECT CONVERT(XML, @ProbePlanXml); END TRY BEGIN CATCH END CATCH

    DROP TABLE IF EXISTS #ProbeShape;
    ;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
    SELECT
        pp.Seq,
        /*  the OPTIMIZE FOR value, and (fallback) the ''-- probe rows ~ N'' comment I emitted    */
        COALESCE(
          CASE WHEN LTRIM(RTRIM(SUBSTRING(txt, CHARINDEX(N''OPTIMIZE FOR (@x ='', txt) + LEN(N''OPTIMIZE FOR (@x =''), CHARINDEX(N'')'', txt, CHARINDEX(N''OPTIMIZE FOR (@x ='', txt)) - (CHARINDEX(N''OPTIMIZE FOR (@x ='', txt) + LEN(N''OPTIMIZE FOR (@x =''))))) IS NOT NULL AND LTRIM(RTRIM(SUBSTRING(txt, CHARINDEX(N''OPTIMIZE FOR (@x ='', txt) + LEN(N''OPTIMIZE FOR (@x =''), CHARINDEX(N'')'', txt, CHARINDEX(N''OPTIMIZE FOR (@x ='', txt)) - (CHARINDEX(N''OPTIMIZE FOR (@x ='', txt) + LEN(N''OPTIMIZE FOR (@x =''))))) NOT LIKE ''%[^0-9.]%'' AND LEN(LTRIM(RTRIM(SUBSTRING(txt, CHARINDEX(N''OPTIMIZE FOR (@x ='', txt) + LEN(N''OPTIMIZE FOR (@x =''), CHARINDEX(N'')'', txt, CHARINDEX(N''OPTIMIZE FOR (@x ='', txt)) - (CHARINDEX(N''OPTIMIZE FOR (@x ='', txt) + LEN(N''OPTIMIZE FOR (@x ='')))))) > 0 THEN CONVERT(FLOAT, LTRIM(RTRIM(SUBSTRING(txt, CHARINDEX(N''OPTIMIZE FOR (@x ='', txt) + LEN(N''OPTIMIZE FOR (@x =''), CHARINDEX(N'')'', txt, CHARINDEX(N''OPTIMIZE FOR (@x ='', txt)) - (CHARINDEX(N''OPTIMIZE FOR (@x ='', txt) + LEN(N''OPTIMIZE FOR (@x ='')))))) END,
          CASE WHEN LTRIM(RTRIM(SUBSTRING(txt, CHARINDEX(N''probe rows ~'', txt) + LEN(N''probe rows ~''), 20))) IS NOT NULL AND LTRIM(RTRIM(SUBSTRING(txt, CHARINDEX(N''probe rows ~'', txt) + LEN(N''probe rows ~''), 20))) NOT LIKE ''%[^0-9.]%'' AND LEN(LTRIM(RTRIM(SUBSTRING(txt, CHARINDEX(N''probe rows ~'', txt) + LEN(N''probe rows ~''), 20)))) > 0 THEN CONVERT(FLOAT, LTRIM(RTRIM(SUBSTRING(txt, CHARINDEX(N''probe rows ~'', txt) + LEN(N''probe rows ~''), 20)))) END
        ) AS ProbeValueNum,
        LTRIM(SUBSTRING(txt, CHARINDEX(N''FROM '', txt) + 5,
              CHARINDEX(N'' WHERE '', txt) - CHARINDEX(N''FROM '', txt) - 5)) AS TargetTable,
        stmt.value(''(//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")]/@PhysicalOp)[1]'', ''nvarchar(60)'') AS LeafOp,
        stmt.value(''count(//RelOp[contains(@PhysicalOp,"Hash Match")])'', ''int'') AS HashJoins,
        stmt.value(''count(//RelOp[@PhysicalOp="Nested Loops"])'', ''int'') AS LoopJoins,
        stmt.value(''(//QueryPlan/@DegreeOfParallelism)[1]'', ''int'') AS Dop
    INTO #ProbeShape
    FROM #ProbePlan pp
    CROSS APPLY pp.PlanXml.nodes(''//StmtSimple[QueryPlan]'') AS S(stmt)
    CROSS APPLY (SELECT stmt.value(''@StatementText'', ''nvarchar(max)'') AS txt) t
    WHERE pp.PlanXml IS NOT NULL;

    UPDATE r
    SET PreciseCrossover = x.note
    FROM #Result r
    CROSS APPLY
    (
        SELECT note = STUFF((
            /*  #ProbeShape.Seq is emitted in ascending probe-cardinality order by section 11, so
                consecutive Seq = the crossover boundary. ProbeValueNum is the OPTIMIZE FOR value
                (the parameter value that tips).                                                  */
            SELECT N''; '' + a.LeafOp + N'' -> '' + b.LeafOp
                 + N'' between values '' + CONVERT(VARCHAR(30), a.ProbeValueNum) + N'' and '' + CONVERT(VARCHAR(30), b.ProbeValueNum)
                 + CASE WHEN a.LoopJoins <> b.LoopJoins OR a.HashJoins <> b.HashJoins THEN N'' (join type changes)'' ELSE N'''' END
                 + CASE WHEN ISNULL(a.Dop,1) <> ISNULL(b.Dop,1) THEN N'' (DOP '' + CONVERT(VARCHAR(10), ISNULL(a.Dop,1)) + N''->'' + CONVERT(VARCHAR(10), ISNULL(b.Dop,1)) + N'')'' ELSE N'''' END
            FROM #ProbeShape a
            JOIN #ProbeShape b ON b.Seq = a.Seq + 1
            WHERE a.TargetTable LIKE N''%'' + r.TableName + N''%''
              AND (a.LeafOp <> b.LeafOp OR a.HashJoins <> b.HashJoins OR a.LoopJoins <> b.LoopJoins OR ISNULL(a.Dop,1) <> ISNULL(b.Dop,1))
            ORDER BY a.Seq
            FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(300)''), 1, 2, N'''')
    ) x
    WHERE x.note IS NOT NULL AND x.note <> N'''';

    UPDATE #Result SET PreciseCrossover = N''(probed; no crossover in the sampled range)''
    WHERE PreciseCrossover IS NULL AND EXISTS (SELECT 1 FROM #ProbeShape);
END

/*------------------------------------------------------------------------------------------------
  12. OUTPUT.
      Result set 1 -- one row per variable-driven predicate, worst skew first.
      Result set 2 -- per-column statistics detail (always emitted; populated only when @Debug = 1,
                      so the result-set shape never changes).
------------------------------------------------------------------------------------------------*/
SELECT
    DatabaseName = @DatabaseName,
    VariableName, VariableKind, SchemaName, TableName, ColumnName, PredicateOp, PredicateKind,
    IndexInPlay, LeafPhysicalOp, IsCovering, RowGoalActive, CEModelVersion, Regime,
    ComputedOptimizerEstimate = CONVERT(BIGINT, ROUND(ComputedOptimizerEstimate, 0)),
    EstimateSource,
    PlanEstimateRows = CONVERT(BIGINT, ROUND(PlanEstimateRows, 0)),
    ModelExplainsPlan,
    KnownValue,
    HistogramTruthForValue = CONVERT(BIGINT, ROUND(HistogramTruthForValue, 0)),
    HistogramMaxEqRows     = CONVERT(BIGINT, ROUND(HistogramMaxEqRows, 0)),
    HistogramSkewRatio,
    TopHeavyValues,
    EstimateVsTruthRatio,
    SkewDirection,
    TippingPointRows = CONVERT(BIGINT, ROUND(TippingPointRows, 0)),
    HistSteps, StepsAboveTipping, TippingValueNote, WillTip,
    StatName, StatFromUsage, StatsSampledPct, StatsModFraction, StatsLastUpdated, StatsStale,
    [Fix] = Fix,
    ProbeValues,
    [ProbeSweepScript] = ProbeSweepScript,
    PreciseCrossover
FROM #Result
ORDER BY CASE WHEN EstimateVsTruthRatio IS NULL THEN 0 ELSE 1 END DESC,
         EstimateVsTruthRatio DESC,
         VariableName;

CREATE TABLE #StatDetail
(
    SchemaName SYSNAME NULL, TableName SYSNAME NULL, ColumnName SYSNAME NULL, StatName SYSNAME NULL,
    StepNumber INT, RangeHighKey NVARCHAR(256), RangeRows BIGINT, EqualRows BIGINT,
    DistinctRangeRows BIGINT, AvgRangeRows BIGINT
);
IF @Debug = 1
BEGIN
    INSERT #StatDetail
    SELECT r.SchemaName, r.TableName, r.ColumnName, r.StatName,
           h.StepNumber, h.RangeHighKeyStr,
           CONVERT(BIGINT, ROUND(h.RangeRows,0)), CONVERT(BIGINT, ROUND(h.EqualRows,0)),
           h.DistinctRangeRows, CONVERT(BIGINT, ROUND(h.AvgRangeRows,0))
    FROM #Histogram h
    JOIN #Result r ON r.PredSeq = h.PredSeq
    WHERE h.StepNumber <= 10 OR h.StepNumber > (SELECT MAX(StepNumber) FROM #Histogram h2 WHERE h2.PredSeq = h.PredSeq) - 5;
END

SELECT DatabaseName = @DatabaseName, sd.* FROM #StatDetail sd ORDER BY SchemaName, TableName, ColumnName, StepNumber;

/*  cleanup -- idempotent re-run within one session leaves no state.                              */
DROP TABLE IF EXISTS #PlanXml;        DROP TABLE IF EXISTS #Pred;          DROP TABLE IF EXISTS #ParamList;
DROP TABLE IF EXISTS #StatsUsage;     DROP TABLE IF EXISTS #StatResolved;  DROP TABLE IF EXISTS #DensityVector;
DROP TABLE IF EXISTS #DensityResolved;DROP TABLE IF EXISTS #Histogram;     DROP TABLE IF EXISTS #HistAgg;
DROP TABLE IF EXISTS #TopHeavy;       DROP TABLE IF EXISTS #Result;        DROP TABLE IF EXISTS #StatDetail;
DROP TABLE IF EXISTS #ProbePlanXml;   DROP TABLE IF EXISTS #Leaf;';

    DECLARE @sql NVARCHAR(MAX) =
        N'USE ' + QUOTENAME(@DatabaseName) + N';' + NCHAR(13) + NCHAR(10) + @body;

    EXEC sys.sp_executesql @sql,
        N'@ObjectName NVARCHAR(776), @QueryId BIGINT, @PlanXml NVARCHAR(MAX), @ProbePlanXml NVARCHAR(MAX), @TippingPointPageFraction DECIMAL(5,3), @SkewRatioThreshold DECIMAL(10,2), @EstimateVsTruthThreshold DECIMAL(10,2), @StaleStatsModFraction DECIMAL(5,3), @ProbeCardinalitySweep BIT, @ProbeValueCount INT, @IncludeSniffableParameters BIT, @TopPredicates INT, @Debug BIT',
        @ObjectName                 = @ObjectName,
        @QueryId                    = @QueryId,
        @PlanXml                    = @PlanXml,
        @ProbePlanXml               = @ProbePlanXml,
        @TippingPointPageFraction   = @TippingPointPageFraction,
        @SkewRatioThreshold         = @SkewRatioThreshold,
        @EstimateVsTruthThreshold   = @EstimateVsTruthThreshold,
        @StaleStatsModFraction      = @StaleStatsModFraction,
        @ProbeCardinalitySweep      = @ProbeCardinalitySweep,
        @ProbeValueCount            = @ProbeValueCount,
        @IncludeSniffableParameters = @IncludeSniffableParameters,
        @TopPredicates              = @TopPredicates,
        @Debug                      = @Debug;
END
GO
