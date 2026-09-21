/*==================================================================================================
  dbo.usp_ParameterSniffingDiagnostic -- COLLECTION LAYER

  Installs in a DBA utility database (DBAdmin) and reads any database on the same instance.
  Derived from Paramsniffingdiagnostic_v1.sql, which remains the annotated reference; the reasoning
  behind the analysis lives there and in TestCases_v1.sql rather than being duplicated here.

  THIS FILE IS THE COLLECTION LAYER ONLY. It resolves a target database, verifies Query Store is
  usable, probes engine features in the target's context, and fills the temp tables the analysis
  half consumes. Sections 5 through 12 of the v1 script are not here yet.

  HOW IT REACHES THE TARGET
    Every collection statement runs inside a dynamic batch whose first line is USE [target].
    Unqualified catalog references then resolve in the target, so the collection SQL is character
    for character what the v1 script already runs -- which is what makes an output-equivalence
    test between the two meaningful. Temp tables are created here, in the outer scope, because a
    table created inside the dynamic batch dies with it.

  PERMISSIONS
    VIEW SERVER STATE (plan cache DMVs) and VIEW DATABASE STATE in each target (Query Store).
    Intended to be certificate-signed so callers need only EXECUTE on this procedure. Do not
    enable TRUSTWORTHY to solve this.

  PLATFORM
    Box SQL Server and Azure SQL Managed Instance. Azure SQL Database (EngineEdition 5) cannot
    run this pattern at all -- it has no cross-database access.

  Parameters below are the ones collection needs. The analysis thresholds arrive with the analysis
  half; adding them early would mean shipping parameters that do nothing.

  QUOTED_IDENTIFIER/ANSI_NULLS are captured into the module AT CREATE TIME (sys.sql_modules), not
  read from the caller's session at execution time -- so the deploying tool's ambient defaults
  decide this permanently unless pinned here. The analysis half's INSERT...SELECT (Section 9 on)
  runs XML data type methods (.value()/.nodes()) inline in the same statement, which requires
  QUOTED_IDENTIFIER ON for that INSERT to succeed at all (Msg "INSERT failed because the following
  SET options have incorrect settings"). Pinned explicitly rather than trusted to the deploy
  session's default -- measured 2026-09-03: a plain sqlcmd deploy captured QUOTED_IDENTIFIER OFF.
==================================================================================================*/
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_ParameterSniffingDiagnostic
    @DatabaseName                  sysname       = NULL,   -- NULL = current database
    @AllDatabases                  BIT           = 0,      -- every online database with Query Store running
    @IncludeDatabases              NVARCHAR(MAX) = NULL,   -- comma-separated; only with @AllDatabases = 1
    @ExcludeDatabases              NVARCHAR(MAX) = NULL,   -- comma-separated; only with @AllDatabases = 1
    @ExcludeHostingDatabase        BIT           = 1,      -- @AllDatabases = 1 skips DB_NAME() by default:
                                                             -- the database this proc lives in accumulates
                                                             -- the proc's OWN analytical query volume in its
                                                             -- Query Store, not application workload; set 0
                                                             -- to analyse it anyway (measured 2026-09-03: a
                                                             -- self-loaded Query Store made #OperatorLeafMap's
                                                             -- ancestor/leaf XPath walk scale to 96M+ rows).
    @LookbackDays                  INT           = 14,
    @TargetObjectName              NVARCHAR(776) = NULL,   -- NULL = every object
    @IncludeAdHocAndDynamicSQL     BIT           = 0,
    @ExcludeSelfCapturedStatements BIT           = 1,
    @AnnotateMemoryGrantFeedback   BIT           = 1,

    @IndexRecommendationMode       CHAR(1)       = 'B',    -- A all tables, B highest IO, C worst skew, D most spills
    @ShowModeComparison            BIT           = 1,
    @JoinColumnKeyPolicy           CHAR(1)       = 'S',    -- S seek-worthy join columns key, A all join columns key
    @MinimumSeverityScore          INT           = 0,
    @HighIOLogicalReadsThreshold   BIGINT        = 50000,
    @IOVarianceScoreThreshold      DECIMAL(9,2)  = 5.0,
    @IOVarianceRecommendationThreshold DECIMAL(9,2) = 10.0,
    @CardinalitySkewThreshold      DECIMAL(9,2)  = 5.0,
    @MemoryGrantVarianceThreshold  DECIMAL(9,2)  = 0.25,
    @HighFrequencyExecutionsPerDayThreshold DECIMAL(18,2) = 1000.0,
    @MaxIndexKeyColumns            INT           = 32,
    @MaxIndexKeyBytes              INT           = 1700,
    @AllowLobIncludeColumns        BIT           = 0,
    @AI                            TINYINT       = 2,      -- 2 build the prompt, 0 skip it but keep the column
    @AIPromptIncludePlanXml        BIT           = 1,
    @AIPromptPlanXmlMaxChars       INT           = 30000,
    @AIPromptSqlTextMaxChars       INT           = 4000,
    @Debug                         BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @Sql            NVARCHAR(MAX),
        @Use            NVARCHAR(MAX),   -- MAX-typed, so every @Use + N'...' concatenation stays MAX
        @DbQuoted       sysname,
        @DbId           INT,
        @EngineEdition  INT = TRY_CAST(SERVERPROPERTY('EngineEdition') AS INT),
        @HasQueryStore  BIT = 0,
        @HasWaitStats   BIT = 0,
        @HasPlanStats   BIT = 0,
        @HasPlanFeedbk  BIT = 0,
        @HasPlanFeedbackView BIT = 0,
        @HasQueryVariantView BIT = 0,
        @QsActualState  TINYINT,
        @QsStateDesc    NVARCHAR(60),
        @TargetObjectId INT,
        @Rows           INT,
        @SkipReason     NVARCHAR(400),
        @DbCount        INT,
        @Msg            NVARCHAR(2000);

    IF @AI = 1
    BEGIN
        RAISERROR('@AI = 1 is deliberately unimplemented. It would call a provider REST API from inside SQL Server, which needs a database-scoped credential holding an API key. Use @AI = 2, which emits a copy/paste prompt.', 16, 1);
        RETURN;
    END;

    DECLARE
        @NL                         CHAR(2)       = CHAR(13) + CHAR(10),
        @EditionName                NVARCHAR(128) = CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)),
        @ProductLevel               NVARCHAR(20)  = CAST(SERVERPROPERTY('ProductLevel') AS NVARCHAR(20)),
        @ProductBuild               INT           = TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(50)), 2) AS INT),
        @UpdatePolicy               NVARCHAR(128) = TRY_CAST(SERVERPROPERTY('ProductUpdateType') AS NVARCHAR(128)),
        @IsBoxSqlServer             BIT,
        @MajorVersion               INT,
        @PlatformName               NVARCHAR(60),
        @DataCompressionSupported   BIT,
        @DatabaseCompatibilityLevel INT,
        @LegacyCEDatabaseSetting    NVARCHAR(40),
        @QueryCaptureMode           NVARCHAR(60),
        @QueryStoreState            NVARCHAR(60);

    SET @IsBoxSqlServer = CASE WHEN @EngineEdition IN (1,2,3,4) THEN 1 ELSE 0 END;
    SET @MajorVersion   = CASE WHEN @IsBoxSqlServer = 1 THEN TRY_CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) END;
    SET @PlatformName   =
        CASE @EngineEdition WHEN 5  THEN N'Azure SQL Database'
                            WHEN 6  THEN N'Azure Synapse (dedicated pool)'
                            WHEN 8  THEN N'Azure SQL Managed Instance'
                            WHEN 9  THEN N'Azure SQL Edge'
                            WHEN 10 THEN N'Azure Arc-managed SQL Instance'
                            WHEN 11 THEN N'Azure Synapse serverless / Fabric'
                            WHEN 12 THEN N'Fabric SQL database'
                            ELSE N'SQL Server' END;
    SET @DataCompressionSupported =
        CASE WHEN @EngineEdition IN (5, 8) THEN 1
             WHEN @EngineEdition = 3       THEN 1
             WHEN @EngineEdition IN (2, 4) THEN
                  CASE WHEN @MajorVersion >= 14 THEN 1
                       WHEN @MajorVersion = 13
                            AND (ISNULL(@ProductLevel, 'RTM') <> 'RTM' OR ISNULL(@ProductBuild, 0) >= 4001)
                                           THEN 1
                       ELSE 0 END
             ELSE 0 END;

    /*----------------------------------------------------------------------------------------
      TARGET RESOLUTION
    ----------------------------------------------------------------------------------------*/
    IF @EngineEdition = 5
    BEGIN
        RAISERROR('Azure SQL Database does not support cross-database access. Install and run this in the target database instead.', 16, 1);
        RETURN;
    END;

    IF @AllDatabases = 0 AND (@IncludeDatabases IS NOT NULL OR @ExcludeDatabases IS NOT NULL)
    BEGIN
        RAISERROR('@IncludeDatabases and @ExcludeDatabases only apply when @AllDatabases = 1.', 16, 1);
        RETURN;
    END;

    DROP TABLE IF EXISTS #DatabaseList;
    DROP TABLE IF EXISTS #SkippedDatabases;
    DROP TABLE IF EXISTS #NameList;

    CREATE TABLE #DatabaseList (DatabaseName sysname NOT NULL PRIMARY KEY);
    CREATE TABLE #SkippedDatabases (DatabaseName sysname NOT NULL, Reason NVARCHAR(400) NOT NULL);
    CREATE TABLE #NameList (Which CHAR(3) NOT NULL, DatabaseName sysname NOT NULL);

    /*  STRING_SPLIT needs compat 130+ in the database this batch compiles in -- DBAdmin, not the
        target, since this runs before any target is even chosen. DBAdmin is 150 today, but that
        is a setting nobody here is watching, not a guarantee; a tally split has no such floor.  */
    IF @IncludeDatabases IS NOT NULL
        INSERT #NameList (Which, DatabaseName)
        SELECT 'inc', LTRIM(RTRIM(SUBSTRING(N',' + @IncludeDatabases + N',', t.n + 1,
                    CHARINDEX(N',', N',' + @IncludeDatabases + N',', t.n + 1) - t.n - 1)))
        FROM (SELECT TOP (LEN(@IncludeDatabases)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
              FROM master..spt_values) AS t
        WHERE SUBSTRING(N',' + @IncludeDatabases + N',', t.n, 1) = N','
          AND CHARINDEX(N',', N',' + @IncludeDatabases + N',', t.n + 1) > t.n
          AND LTRIM(RTRIM(SUBSTRING(N',' + @IncludeDatabases + N',', t.n + 1,
                    CHARINDEX(N',', N',' + @IncludeDatabases + N',', t.n + 1) - t.n - 1))) <> N'';
    IF @ExcludeDatabases IS NOT NULL
        INSERT #NameList (Which, DatabaseName)
        SELECT 'exc', LTRIM(RTRIM(SUBSTRING(N',' + @ExcludeDatabases + N',', t.n + 1,
                    CHARINDEX(N',', N',' + @ExcludeDatabases + N',', t.n + 1) - t.n - 1)))
        FROM (SELECT TOP (LEN(@ExcludeDatabases)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
              FROM master..spt_values) AS t
        WHERE SUBSTRING(N',' + @ExcludeDatabases + N',', t.n, 1) = N','
          AND CHARINDEX(N',', N',' + @ExcludeDatabases + N',', t.n + 1) > t.n
          AND LTRIM(RTRIM(SUBSTRING(N',' + @ExcludeDatabases + N',', t.n + 1,
                    CHARINDEX(N',', N',' + @ExcludeDatabases + N',', t.n + 1) - t.n - 1))) <> N'';

    IF @AllDatabases = 1
    BEGIN
        /*  is_query_store_on is the SETTING. Databases that pass here can still turn out to have
            Query Store stopped, which the per-database preflight catches and reports as a skip. */
        INSERT #DatabaseList (DatabaseName)
        SELECT d.name
        FROM sys.databases d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.is_in_standby = 0
          AND d.is_read_only = 0
          AND d.source_database_id IS NULL
          AND d.is_query_store_on = 1
          AND (@IncludeDatabases IS NULL
               OR EXISTS (SELECT 1 FROM #NameList n WHERE n.Which = 'inc' AND n.DatabaseName = d.name))
          AND NOT EXISTS (SELECT 1 FROM #NameList n WHERE n.Which = 'exc' AND n.DatabaseName = d.name)
          AND (@ExcludeHostingDatabase = 0 OR d.name <> DB_NAME());

        /*  A database asked for by name and then filtered out is REPORTED, not dropped silently --
            otherwise a typo and a genuinely ineligible database look identical.                 */
        /*  FIXED 2026-09-13: name each cause that actually applies, in the filter's own order, instead
            of one lumped message. The lumped text was reported for the HOSTING database and for names
            in @ExcludeDatabases -- two causes it did not even list -- sending the reader to look for
            an offline or read-only database that did not exist. Same defect, same fix, as
            usp_IndexAnalysis and usp_FindTimeoutStatementsNQueryStore; TestRunners\
            Validate-FleetSkipReasons.ps1 holds all three to it. STUFF on an empty string returns
            NULL and Reason is NOT NULL, hence the COALESCE fallback.                              */
        INSERT #SkippedDatabases (DatabaseName, Reason)
        SELECT n.DatabaseName,
               CASE WHEN DB_ID(n.DatabaseName) IS NULL
                        THEN N'does not exist or is not visible to this login'
                    ELSE COALESCE(STUFF(CONCAT(CAST(N'' AS NVARCHAR(600)),
                             CASE WHEN d.database_id <= 4
                                  THEN N'; a system database' ELSE N'' END,
                             CASE WHEN d.state <> 0
                                  THEN N'; not ONLINE (state ' + d.state_desc + N')' ELSE N'' END,
                             CASE WHEN d.is_in_standby = 1
                                  THEN N'; in STANDBY' ELSE N'' END,
                             CASE WHEN d.is_read_only = 1
                                  THEN N'; READ_ONLY' ELSE N'' END,
                             CASE WHEN d.source_database_id IS NOT NULL
                                  THEN N'; a database snapshot' ELSE N'' END,
                             CASE WHEN d.is_query_store_on = 0
                                  THEN N'; Query Store not enabled' ELSE N'' END,
                             CASE WHEN EXISTS (SELECT 1 FROM #NameList x
                                               WHERE x.Which = 'exc' AND x.DatabaseName = n.DatabaseName)
                                  THEN N'; also named in @ExcludeDatabases' ELSE N'' END,
                             CASE WHEN @ExcludeHostingDatabase = 1 AND d.name = DB_NAME()
                                  THEN N'; it hosts this procedure and @ExcludeHostingDatabase = 1 (pass 0 to include it)' ELSE N'' END
                         ), 1, 2, N''),
                         N'not eligible, and sys.databases does not show this login why')
               END
        FROM #NameList n
        LEFT JOIN sys.databases d ON d.name = n.DatabaseName
        WHERE n.Which = 'inc'
          AND NOT EXISTS (SELECT 1 FROM #DatabaseList dl WHERE dl.DatabaseName = n.DatabaseName);
    END
    ELSE
    BEGIN
        SET @DatabaseName = ISNULL(@DatabaseName, DB_NAME());

        IF DB_ID(@DatabaseName) IS NULL
        BEGIN
            SET @Msg = N'Database ' + QUOTENAME(@DatabaseName) + N' does not exist or is not visible to this login.';
            RAISERROR(@Msg, 16, 1);
            RETURN;
        END;

        IF NOT EXISTS (SELECT 1 FROM sys.databases
                       WHERE database_id = DB_ID(@DatabaseName)
                         AND state = 0 AND is_in_standby = 0 AND source_database_id IS NULL)
        BEGIN
            SET @Msg = N'Database ' + QUOTENAME(@DatabaseName) + N' is not online, is in standby, or is a snapshot.';
            RAISERROR(@Msg, 16, 1);
            RETURN;
        END;

        INSERT #DatabaseList (DatabaseName) VALUES (@DatabaseName);
    END;

    SELECT @DbCount = COUNT(*) FROM #DatabaseList;

    IF @DbCount = 0
    BEGIN
        /*  FIXED 2026-09-13. The old text asserted "no online, writable, non-system database has
            Query Store enabled" -- false whenever the database was excluded by name or as the host,
            which is exactly when this path is reached with @IncludeDatabases. Now it says which
            situation applies, and points at the per-database reasons when there are some.       */
        SET @Msg = CASE WHEN @IncludeDatabases IS NOT NULL
                        THEN N'No eligible database to analyse: every database named in @IncludeDatabases was excluded. The skipped-databases result set gives each one''s reason.'
                        ELSE N'No eligible database to analyse: no online, writable, non-system database with Query Store enabled remains after @ExcludeDatabases and @ExcludeHostingDatabase.' END;
        RAISERROR(@Msg, 16, 1);
        IF EXISTS (SELECT 1 FROM #SkippedDatabases) SELECT DatabaseName, Reason FROM #SkippedDatabases ORDER BY DatabaseName;
        RETURN;
    END;

    DROP TABLE IF EXISTS #Results;
    DROP TABLE IF EXISTS #ModeResults;

    CREATE TABLE #Results (
        [DatabaseName]                         sysname NULL,
        [object_name]                          nvarchar(128) NULL,
        [object_id]                            bigint NULL,
        [query_id]                             bigint NULL,
        [plan_id]                              bigint NULL,
        [query_hash]                           binary(8) NULL,
        [query_plan_hash]                      binary(8) NULL,
        [plan_handle]                          varbinary(64) NULL,
        [query_sql_text]                       nvarchar(MAX) NULL,
        [CacheLastExecutionTime]               datetime NULL,
        [CacheActualPlanAvailable]             int NULL,
        [SniffingSeverityScore]                int NULL,
        [SniffingSeverityBand]                 varchar(8) NULL,
        [SniffingSeverityScoreCeiling]         int NULL,
        [SignalsUnavailable]                   int NULL,
        [PlanStability]                        varchar(8) NULL,
        [PlanShapeStability]                   varchar(11) NULL,
        [MemoryGrantStability]                 varchar(11) NULL,
        [ParallelismStability]                 varchar(11) NULL,
        [OperatorSkewStability]                varchar(11) NULL,
        [SpillStability]                       varchar(11) NULL,
        [IOVarianceStability]                  varchar(11) NULL,
        [MemoryGrantFeedbackState]             nvarchar(60) NULL,
        [MemoryGrantFeedbackNote]              nvarchar(254) NULL,
        [SniffingSeveritySignals]              nvarchar(MAX) NULL,
        [PlanForcingCandidate]                 varchar(3) NULL,
        [SuggestedRemediationPath]             varchar(99) NULL,
        [RootCauseHint]                        varchar(77) NULL,
        [HighDurationLowCpu_DominantWaitCategory] varchar(48) NULL,
        [TotalExecutions]                      bigint NULL,
        [AvgLogicalReads]                      float NULL,
        [MaxLogicalReads]                      bigint NULL,
        [AvgDurationMs]                        float NULL,
        [MaxDurationMs]                        decimal(26,6) NULL,
        [AvgCpuTimeMs]                         float NULL,
        [PlanCount]                            int NULL,
        [WorstPlanAvgIO]                       float NULL,
        [BestPlanAvgIO]                        float NULL,
        [IOVarianceRatio]                      float NULL,
        [EstimatedRows]                        float NULL,
        [CacheActualRows]                      float NULL,
        [EstimatedMemoryGrant]                 float NULL,
        [CacheActualMemoryGrant]               float NULL,
        [EstimatedParallelismFlag]             bit NULL,
        [CacheActualParallelismFlag]           bit NULL,
        [EstimateVsActualRatio]                float NULL,
        [MaxToMinRowRatio]                     bigint NULL,
        [TableSchemaRaw]                       nvarchar(128) NULL,
        [TableNameRaw]                         nvarchar(128) NULL,
        [TableRank]                            bigint NULL,
        [AccessNodeId]                         int NULL,
        [AccessPhysicalOp]                     nvarchar(50) NULL,
        [KeyScope]                             nvarchar(85) NULL,
        [AccessPathsOnThisTable]               int NULL,
        [ComputedIncludeColumns]               nvarchar(MAX) NULL,
        [AccessEstimateIO]                     float NULL,
        [AccessActualIO]                       float NULL,
        [AccessEstimateRows]                   float NULL,
        [AccessActualRows]                     float NULL,
        [TotalActualIO]                        float NULL,
        [TotalEstimateIO]                      float NULL,
        [WorstSkewRatio]                       float NULL,
        [SpillEventCount]                      int NULL,
        [WorstSpillLevel]                      int NULL,
        [SpillDetectionSource]                 varchar(20) NULL,
        [SpillAttributionTied]                 varchar(3) NULL,
        [EstimatedTableSizeMB]                 decimal(29,7) NULL,
        [BaseIndexCompression]               varchar(4) NULL,
        [CandidateIndexName]                   nvarchar(124) NULL,
        [KeyColumnCount]                       int NULL,
        [KeyByteSize]                          int NULL,
        [ExcludedKeyColumns]                   nvarchar(MAX) NULL,
        [ExcludedIncludeColumns]               nvarchar(MAX) NULL,
        [isXML]                                bit NULL,
        [isJSON]                               nvarchar(20) NULL,
        [BaseIndexKeyColumns]           nvarchar(MAX) NULL,
        [BaseIndexIncludeColumns]       nvarchar(MAX) NULL,
        [KeyColumnsFromPredicates]             nvarchar(MAX) NULL,
        [KeyColumnsFromJoins]                  nvarchar(MAX) NULL,
        [KeyColumnsFromGroupBy]                nvarchar(MAX) NULL,
        [KeyColumnsFromOrderBy]                nvarchar(MAX) NULL,
        [EstimatedPlanXML]                     xml NULL,
        [CacheActualPlanXML]                   xml NULL,
        [BaseIndexCreateSQL]            nvarchar(MAX) NULL,
        [BaseIndexDropSQL]              nvarchar(400) NULL,
        [BaseIndexBasis]             varchar(185) NULL,
        [RecommendedRecompileSQL]              nvarchar(MAX) NULL,
        [Platform]                             nvarchar(60) NULL,
        [EditionName]                          nvarchar(128) NULL,
        [EngineEdition]                        int NULL,
        [QueryCaptureMode]                     nvarchar(60) NULL,
        [SQLServerMajorVersion]                int NULL,
        [MIUpdatePolicy]                       nvarchar(128) NULL,
        [DatabaseCompatibilityLevel]           int NULL,
        [LegacyCEDatabaseSetting]              nvarchar(40) NULL,
        [PlanCardinalityEstimationModel]       int NULL,
        [MixedCEModelAcrossPlans]              varchar(3) NULL,
        [PlanUsesLegacyCE]                     varchar(3) NULL,
        [PspoRole]                             nvarchar(12) NULL,
        [PspoParentQueryId]                    bigint NULL,
        [PspoVariantCount]                     int NULL,
        [AI Prompt]                            xml NULL,
        [AIPromptText]                         nvarchar(max) NULL,  -- staging: stripped into [AI Prompt] after the loop, then dropped
        [AIPromptTcRowId]                      int NULL             -- internal: rejoins a row to ITS table candidate for the prompt UPDATEs; dropped after the loop
    );

    CREATE TABLE #ModeResults (
        [DatabaseName]                         sysname NULL,
        [object_name]                          nvarchar(128) NULL,
        [query_id]                             bigint NULL,
        [plan_id]                              bigint NULL,
        [TableName]                            nvarchar(257) NULL,
        [CandidateTableCount]                  int NULL,
        [TableRankB]                           bigint NULL,
        [ModeB_RankedIO]                       float NULL,
        [TableRankC]                           bigint NULL,
        [ModeC_RankedSkew]                     float NULL,
        [TableRankD]                           bigint NULL,
        [ModeD_RankedSpill]                    int NULL,
        [ModeB_Winner]                         nvarchar(257) NULL,
        [ModeC_Winner]                         nvarchar(257) NULL,
        [ModeD_Winner]                         nvarchar(257) NULL,
        [ModeAgreement]                        varchar(22) NULL,
        [ModeB_InputIsFlat]                    varchar(3) NULL,
        [ModeC_InputIsFlat]                    varchar(3) NULL,
        [ModeD_InputIsFlat]                    varchar(3) NULL,
        [ModeD_AttributionWasTied]             varchar(3) NULL
    );

    /*======================================================================================
      PER-DATABASE LOOP. Watermark rather than a cursor, matching usp_SQL_Server_System_Report.
    ======================================================================================*/
    SET @DatabaseName = (SELECT MIN(DatabaseName) FROM #DatabaseList);

    WHILE @DatabaseName IS NOT NULL
    BEGIN
    SET @DbId = DB_ID(@DatabaseName);

    SELECT @DatabaseCompatibilityLevel = compatibility_level
    FROM sys.databases WHERE database_id = @DbId;

    SET @DbQuoted = QUOTENAME(@DatabaseName);
    SET @Use      = N'USE ' + @DbQuoted + N';' + NCHAR(13) + NCHAR(10);

    /*  Every temp table below is rebuilt per iteration. The analysis half creates most of them
        with SELECT ... INTO, which fails on the second pass unless the previous one is gone.  */
    DROP TABLE IF EXISTS #PlanAgg;              DROP TABLE IF EXISTS #BestPlanLookup;
    DROP TABLE IF EXISTS #LookupBranchLeaves;   DROP TABLE IF EXISTS #LookupPairs;
    DROP TABLE IF EXISTS #LeafAttribution;      DROP TABLE IF EXISTS #TableRollup;
    DROP TABLE IF EXISTS #OperatorLeafMap;      DROP TABLE IF EXISTS #LeafColumnsRaw;
    DROP TABLE IF EXISTS #ComputedColumnSources;
    DROP TABLE IF EXISTS #ComputedColumnEligibility;
    DROP TABLE IF EXISTS #ComputedColumnRelayAliases;
    DROP TABLE IF EXISTS #JsonFunctionRelayAliases;
    DROP TABLE IF EXISTS #JsonTrapColumns;
    DROP TABLE IF EXISTS #ColumnEligibility;    DROP TABLE IF EXISTS #EligibilityTables;
    DROP TABLE IF EXISTS #TableKeyColumns;      DROP TABLE IF EXISTS #TableIncludeColumns;
    DROP TABLE IF EXISTS #SpillEvents;          DROP TABLE IF EXISTS #SpillRollup;
    DROP TABLE IF EXISTS #AccessSet;            DROP TABLE IF EXISTS #TableCandidates;
    DROP TABLE IF EXISTS #Scored;               DROP TABLE IF EXISTS #ScoredBanded;
    DROP TABLE IF EXISTS #AIPlanOperators;      DROP TABLE IF EXISTS #AIPlanWarnings;
    DROP TABLE IF EXISTS #AIPromptPlan;         DROP TABLE IF EXISTS #StatsFreshness;

    /*----------------------------------------------------------------------------------------
      PREFLIGHT -- executed in the target's context so every probe answers for the target

      is_query_store_on reflects the SETTING. actual_state reflects whether Query Store is
      actually running: it drops itself to READ_ONLY on hitting MAX_STORAGE_SIZE_MB, and a
      read-only store records nothing new while still reporting as "on".
    ----------------------------------------------------------------------------------------*/
    SET @LegacyCEDatabaseSetting = NULL;   -- per iteration: never inherit the previous database's value

    SET @Sql = @Use + N'
    SELECT @ActualStateOut  = dqso.actual_state,
           @StateDescOut    = dqso.actual_state_desc,
           @CaptureModeOut  = dqso.query_capture_mode_desc
    FROM sys.database_query_store_options dqso;

    /*  LEGACY_CARDINALITY_ESTIMATION is per-database, so it is read HERE, inside USE [target] --
        read in the analysis half it would report the utility database''s own setting. */
    SELECT @LegacyCeOut = CASE WHEN CONVERT(INT, dsc.value) = 1 THEN N''ON'' ELSE N''OFF'' END
                        + CASE WHEN dsc.value_for_secondary IS NULL THEN N''''
                               ELSE N''; secondary '' + CASE WHEN CONVERT(INT, dsc.value_for_secondary) = 1
                                                             THEN N''ON'' ELSE N''OFF'' END END
    FROM sys.database_scoped_configurations dsc
    WHERE dsc.name = N''LEGACY_CARDINALITY_ESTIMATION'';

    SELECT @HasQueryStoreOut = CASE WHEN OBJECT_ID(''sys.query_store_query'')          IS NULL THEN 0 ELSE 1 END,
           @HasWaitStatsOut  = CASE WHEN OBJECT_ID(''sys.query_store_wait_stats'')     IS NULL THEN 0 ELSE 1 END,
           @HasPlanStatsOut  = CASE WHEN OBJECT_ID(''sys.dm_exec_query_plan_stats'')   IS NULL THEN 0 ELSE 1 END,
           @HasPlanFeedbkOut = CASE WHEN OBJECT_ID(''sys.query_store_plan_feedback'')  IS NULL THEN 0 ELSE 1 END,
           @HasQueryVarOut   = CASE WHEN OBJECT_ID(''sys.query_store_query_variant'')  IS NULL THEN 0 ELSE 1 END;

    SELECT @TargetObjectIdOut = CASE WHEN @TargetObjectNameIn IS NOT NULL
                                     THEN OBJECT_ID(@TargetObjectNameIn) END;';

    EXEC sys.sp_executesql @Sql,
        N'@TargetObjectNameIn NVARCHAR(776),
          @ActualStateOut TINYINT OUTPUT, @StateDescOut NVARCHAR(60) OUTPUT,
          @CaptureModeOut NVARCHAR(60) OUTPUT,
          @HasQueryStoreOut BIT OUTPUT, @HasWaitStatsOut BIT OUTPUT,
          @HasPlanStatsOut BIT OUTPUT, @HasPlanFeedbkOut BIT OUTPUT,
          @HasQueryVarOut BIT OUTPUT,
          @LegacyCeOut NVARCHAR(40) OUTPUT,
          @TargetObjectIdOut INT OUTPUT',
        @TargetObjectNameIn = @TargetObjectName,
        @ActualStateOut     = @QsActualState  OUTPUT,
        @StateDescOut       = @QsStateDesc    OUTPUT,
        @CaptureModeOut     = @QueryCaptureMode OUTPUT,
        @HasQueryStoreOut   = @HasQueryStore  OUTPUT,
        @HasWaitStatsOut    = @HasWaitStats   OUTPUT,
        @HasPlanStatsOut    = @HasPlanStats   OUTPUT,
        @HasPlanFeedbkOut   = @HasPlanFeedbk  OUTPUT,
        @HasQueryVarOut     = @HasQueryVariantView OUTPUT,
        @LegacyCeOut        = @LegacyCEDatabaseSetting OUTPUT,
        @TargetObjectIdOut  = @TargetObjectId OUTPUT;

    SET @QueryStoreState     = @QsStateDesc;
    SET @HasPlanFeedbackView = @HasPlanFeedbk;

    SET @SkipReason = NULL;

    IF @HasQueryStore = 0 OR @QsActualState IS NULL OR @QsActualState = 0
        SET @SkipReason = N'Query Store is not running (actual_state: ' + ISNULL(@QsStateDesc, N'OFF') + N')';
    ELSE IF @TargetObjectName IS NOT NULL AND @TargetObjectId IS NULL
        SET @SkipReason = N'@TargetObjectName ' + QUOTENAME(@TargetObjectName) + N' did not resolve here';

    /*  One database failing preflight is fatal when it is the one that was asked for, and a skip
        when the caller asked for all of them. Either way it is stated, never silently empty. */
    IF @SkipReason IS NOT NULL
    BEGIN
        IF @AllDatabases = 0
        BEGIN
            SET @Msg = @DbQuoted + N': ' + @SkipReason
                     + N'. Aborting rather than returning an empty result, which would be indistinguishable from a database with no findings.';
            RAISERROR(@Msg, 16, 1);
            RETURN;
        END;

        INSERT #SkippedDatabases (DatabaseName, Reason) VALUES (@DatabaseName, @SkipReason);
        IF @Debug = 1 RAISERROR('skipping %s: %s', 0, 0, @DatabaseName, @SkipReason) WITH NOWAIT;
        SET @DatabaseName = (SELECT MIN(DatabaseName) FROM #DatabaseList WHERE DatabaseName > @DatabaseName);
        CONTINUE;
    END;

    /*----------------------------------------------------------------------------------------
      TEMP TABLES -- created here so the dynamic batches can INSERT into them.

      Types are taken from what the v1 script's SELECT ... INTO actually produced, read out of
      tempdb rather than transcribed. Two would not have been guessed: MaxDurationMs is
      numeric(26,6) and EstimatedTableSizeMB is numeric(29,7).
    ----------------------------------------------------------------------------------------*/
    DROP TABLE IF EXISTS #RuntimeRollup;
    DROP TABLE IF EXISTS #WaitRollup;
    DROP TABLE IF EXISTS #GrantFeedback;
    DROP TABLE IF EXISTS #PspoVariant;
    DROP TABLE IF EXISTS #CacheMatch;
    DROP TABLE IF EXISTS #ClusteringKeyColumns;
    DROP TABLE IF EXISTS #TableSizeLookup;
    DROP TABLE IF EXISTS #XmlColumnCheck;
    DROP TABLE IF EXISTS #JsonNativeColumnCheck;

    CREATE TABLE #RuntimeRollup (
        plan_id           BIGINT         NOT NULL,
        TotalExecutions   BIGINT         NULL,
        AvgLogicalReads   FLOAT          NULL,
        MaxLogicalReads   BIGINT         NULL,
        AvgDurationMs     FLOAT          NULL,
        MaxDurationMs     NUMERIC(26,6)  NULL,
        AvgCpuTimeMs      FLOAT          NULL,
        AvgRowcount       FLOAT          NULL,
        MaxRowcount       BIGINT         NULL,
        MinRowcount       BIGINT         NULL,
        LastExecutionTime DATETIMEOFFSET NULL,
        -- Added 2026-09-14 for the [AI Prompt]. Types read from the script's SELECT ... INTO.
        FirstExecutionTime DATETIMEOFFSET NULL,
        MinDurationMs      NUMERIC(26,6)  NULL,
        StdevDurationMs    FLOAT          NULL,
        MinCpuTimeMs       NUMERIC(26,6)  NULL,
        MaxCpuTimeMs       NUMERIC(26,6)  NULL,
        StdevCpuTimeMs     FLOAT          NULL,
        MinLogicalReads    BIGINT         NULL,
        StdevLogicalReads  FLOAT          NULL,
        AvgLogicalWrites   FLOAT          NULL,
        MaxLogicalWrites   BIGINT         NULL,
        AvgPhysicalReads   FLOAT          NULL,
        StdevRowcount      FLOAT          NULL,
        MinDop             BIGINT         NULL,
        MaxDop             BIGINT         NULL,
        AvgUsedMemoryKB    FLOAT          NULL,
        MaxUsedMemoryKB    NUMERIC(22,1)  NULL,
        AvgTempdbKB        FLOAT          NULL,
        MaxTempdbKB        FLOAT          NULL
    );

    CREATE TABLE #WaitRollup (
        plan_id     BIGINT NOT NULL,
        LockWaitMs  BIGINT NULL,
        IOWaitMs    BIGINT NULL,
        TotalWaitMs BIGINT NULL
    );

    CREATE TABLE #GrantFeedback (
        plan_id       BIGINT       NOT NULL,
        FeedbackState NVARCHAR(60) NULL,
        AdditionalKB  BIGINT       NULL
    );

    /*  PSPO query variants -- full account in Paramsniffingdiagnostic_v1.sql, Section 3c.
        sys.query_store_query_variant is PER DATABASE, so it is read inside the USE [target] batch;
        this table is created out here because a temp table that batch writes to must live in the
        outer scope, or it dies with the batch.                                                  */
    CREATE TABLE #PspoVariant (
        variant_query_id BIGINT NOT NULL PRIMARY KEY,
        parent_query_id  BIGINT NOT NULL,
        parent_object_id BIGINT NULL,
        variant_count    INT    NOT NULL
    );

    CREATE TABLE #CacheMatch (
        query_id                   BIGINT         NOT NULL,
        plan_id                    BIGINT         NOT NULL,
        query_hash                 BINARY(8)      NOT NULL,
        query_plan_hash            BINARY(8)      NOT NULL,
        QueryPlanHashText          VARCHAR(34)    NULL,
        QueryHashText              VARCHAR(34)    NULL,
        object_id                  BIGINT         NULL,
        object_name                NVARCHAR(128)  NOT NULL,
        query_sql_text             NVARCHAR(MAX)  NULL,
        EstimatedPlanXML           XML            NULL,
        TotalExecutions            BIGINT         NULL,
        AvgLogicalReads            FLOAT          NULL,
        MaxLogicalReads            BIGINT         NULL,
        AvgDurationMs              FLOAT          NULL,
        MaxDurationMs              NUMERIC(26,6)  NULL,
        AvgCpuTimeMs               FLOAT          NULL,
        AvgRowcount                FLOAT          NULL,
        MaxRowcount                BIGINT         NULL,
        MinRowcount                BIGINT         NULL,
        LastExecutionTime          DATETIMEOFFSET NULL,
        plan_handle                VARBINARY(64)  NULL,
        CachePlanHash              BINARY(8)      NULL,
        CacheLastExecutionTime     DATETIME       NULL,
        CacheActualPlanXML         XML            NULL,
        CacheActualPlanAvailable   INT            NOT NULL,
        PlanCompatModel            INT            NULL,
        EstimatedRows              FLOAT          NULL,
        EstimatedMemoryGrant       FLOAT          NULL,
        EstimatedParallelismFlag   BIT            NULL,
        CacheActualRows            FLOAT          NULL,
        CacheActualMemoryGrant     FLOAT          NULL,
        CacheActualParallelismFlag BIT            NULL,
        -- Added 2026-09-14 for the [AI Prompt]. Types read from the script's SELECT ... INTO.
        IsForcedPlan               BIT            NULL,
        ForceFailureCount          BIGINT         NULL,
        PlanCompileCount           BIGINT         NULL,
        CacheCreationTime          DATETIME       NULL,
        CacheExecutionCount        BIGINT         NULL,
        CacheTotalWorkerMs         NUMERIC(26,6)  NULL,
        CacheMinWorkerMs           NUMERIC(26,6)  NULL,
        CacheMaxWorkerMs           NUMERIC(26,6)  NULL,
        CacheTotalElapsedMs        NUMERIC(26,6)  NULL,
        CacheMinElapsedMs          NUMERIC(26,6)  NULL,
        CacheMaxElapsedMs          NUMERIC(26,6)  NULL,
        CacheTotalLogicalReads     BIGINT         NULL,
        CacheMinLogicalReads       BIGINT         NULL,
        CacheMaxLogicalReads       BIGINT         NULL,
        CacheTotalLogicalWrites    BIGINT         NULL,
        CacheTotalRows             BIGINT         NULL,
        CacheMinRows               BIGINT         NULL,
        CacheMaxRows               BIGINT         NULL,
        CacheStmtStart             INT            NULL,
        CacheStmtEnd               INT            NULL,
        -- Added 2026-09-14: which cached statement, and whether it can be told apart. Internal.
        CacheSqlHandle             VARBINARY(64)  NULL,
        CacheIsThisStatement       INT            NULL,
        CacheSameHashStatements    INT            NULL,
        CacheStmtOrdinal           BIGINT         NULL,
        QsSameHashQueries          INT            NULL,
        CacheAttributionDeclined   BIT            NOT NULL,
        CacheActualHashMatches     INT            NULL,
        CacheActualPlanDeclined    BIT            NOT NULL,
        CacheMinGrantKB            BIGINT         NULL,
        CacheMaxGrantKB            BIGINT         NULL,
        CacheMinUsedGrantKB        BIGINT         NULL,
        CacheMaxUsedGrantKB        BIGINT         NULL,
        CacheMaxIdealGrantKB       BIGINT         NULL,
        CacheTotalSpills           BIGINT         NULL,
        CacheMaxSpills             BIGINT         NULL,
        CacheMinDop                BIGINT         NULL,
        CacheMaxDop                BIGINT         NULL,
        PspoRole                   NVARCHAR(12)   NULL,
        PspoParentQueryId          BIGINT         NULL,
        PspoVariantCount           INT            NULL
    );

    CREATE TABLE #ClusteringKeyColumns (
        TableSchemaRaw NVARCHAR(258) NULL,
        TableNameRaw   NVARCHAR(258) NULL,
        ColumnName     sysname       NULL
    );

    CREATE TABLE #TableSizeLookup (
        TableSchemaRaw       NVARCHAR(258)  NULL,
        TableNameRaw         NVARCHAR(258)  NULL,
        EstimatedTableSizeMB NUMERIC(29,7)  NULL
    );

    -- Section 8c in the script: isXML output column. Same unfiltered, whole-database shape as
    -- #TableSizeLookup immediately above -- computed here, before #TableRollup exists, for the
    -- same reason #TableSizeLookup is. See the script's own comment for the full reasoning.
    CREATE TABLE #XmlColumnCheck (
        TableSchemaRaw NVARCHAR(258) NULL,
        TableNameRaw   NVARCHAR(258) NULL,
        isXML          BIT           NULL
    );

    -- Section 8d in the script: isJSON's NativeCovered/NativeUncovered states. Same shape as
    -- #XmlColumnCheck immediately above, same reason. See the script's own comment.
    CREATE TABLE #JsonNativeColumnCheck (
        TableSchemaRaw  NVARCHAR(258) NULL,
        TableNameRaw    NVARCHAR(258) NULL,
        NativeJsonState NVARCHAR(20)  NULL
    );

    /*----------------------------------------------------------------------------------------
      RUNTIME STATS -- rolled up to one row per plan_id before anything joins it.
      last_execution_time is UTC, so the lookback compares against SYSUTCDATETIME().
    ----------------------------------------------------------------------------------------*/
    SET @Sql = @Use + N'
    INSERT INTO #RuntimeRollup
        (plan_id, TotalExecutions, AvgLogicalReads, MaxLogicalReads, AvgDurationMs,
         MaxDurationMs, AvgCpuTimeMs, AvgRowcount, MaxRowcount, MinRowcount, LastExecutionTime,
         FirstExecutionTime, MinDurationMs, StdevDurationMs, MinCpuTimeMs, MaxCpuTimeMs,
         StdevCpuTimeMs, MinLogicalReads, StdevLogicalReads, AvgLogicalWrites, MaxLogicalWrites,
         AvgPhysicalReads, StdevRowcount, MinDop, MaxDop, AvgUsedMemoryKB, MaxUsedMemoryKB,
         AvgTempdbKB, MaxTempdbKB)
    SELECT
        agg.plan_id, agg.TotalExecutions, agg.AvgLogicalReads, agg.MaxLogicalReads, agg.AvgDurationMs,
        agg.MaxDurationMs, agg.AvgCpuTimeMs, agg.AvgRowcount, agg.MaxRowcount, agg.MinRowcount,
        agg.LastExecutionTime,
        agg.FirstExecutionTime,
        agg.MinDurationMs,
        SQRT(CASE WHEN agg.VarDuration > 0 THEN agg.VarDuration ELSE 0 END) / 1000.0     AS StdevDurationMs,
        agg.MinCpuTimeMs,
        agg.MaxCpuTimeMs,
        SQRT(CASE WHEN agg.VarCpu > 0 THEN agg.VarCpu ELSE 0 END) / 1000.0               AS StdevCpuTimeMs,
        agg.MinLogicalReads,
        SQRT(CASE WHEN agg.VarReads > 0 THEN agg.VarReads ELSE 0 END)                    AS StdevLogicalReads,
        agg.AvgLogicalWrites,
        agg.MaxLogicalWrites,
        agg.AvgPhysicalReads,
        SQRT(CASE WHEN agg.VarRows > 0 THEN agg.VarRows ELSE 0 END)                      AS StdevRowcount,
        agg.MinDop,
        agg.MaxDop,
        agg.AvgUsedMemoryKB,
        agg.MaxUsedMemoryKB,
        CAST(NULL AS FLOAT)                                                              AS AvgTempdbKB,
        CAST(NULL AS FLOAT)                                                              AS MaxTempdbKB
    FROM (
        SELECT
            rs.plan_id,
            SUM(rs.count_executions)                                                                      AS TotalExecutions,
            SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0)       AS AvgLogicalReads,
            MAX(rs.max_logical_io_reads)                                                                   AS MaxLogicalReads,
            (SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0)) / 1000.0     AS AvgDurationMs,
            MAX(rs.max_duration) / 1000.0                                                                  AS MaxDurationMs,
            (SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0)) / 1000.0     AS AvgCpuTimeMs,
            SUM(rs.avg_rowcount * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0)               AS AvgRowcount,
            MAX(rs.max_rowcount)                                                                           AS MaxRowcount,
            MIN(rs.min_rowcount)                                                                           AS MinRowcount,
            MAX(rs.last_execution_time)                                                                    AS LastExecutionTime,
            MIN(rs.first_execution_time)                                                                   AS FirstExecutionTime,
            MIN(rs.min_duration) / 1000.0                                                                  AS MinDurationMs,
            SUM(rs.count_executions * (SQUARE(rs.stdev_duration) + SQUARE(rs.avg_duration))) / NULLIF(SUM(rs.count_executions), 0)
              - SQUARE(SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0))     AS VarDuration,
            MIN(rs.min_cpu_time) / 1000.0                                                                  AS MinCpuTimeMs,
            MAX(rs.max_cpu_time) / 1000.0                                                                  AS MaxCpuTimeMs,
            SUM(rs.count_executions * (SQUARE(rs.stdev_cpu_time) + SQUARE(rs.avg_cpu_time))) / NULLIF(SUM(rs.count_executions), 0)
              - SQUARE(SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0))     AS VarCpu,
            MIN(rs.min_logical_io_reads)                                                                   AS MinLogicalReads,
            SUM(rs.count_executions * (SQUARE(rs.stdev_logical_io_reads) + SQUARE(rs.avg_logical_io_reads))) / NULLIF(SUM(rs.count_executions), 0)
              - SQUARE(SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0)) AS VarReads,
            SUM(rs.avg_logical_io_writes * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0)      AS AvgLogicalWrites,
            MAX(rs.max_logical_io_writes)                                                                  AS MaxLogicalWrites,
            SUM(rs.avg_physical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0)      AS AvgPhysicalReads,
            SUM(rs.count_executions * (SQUARE(rs.stdev_rowcount) + SQUARE(rs.avg_rowcount))) / NULLIF(SUM(rs.count_executions), 0)
              - SQUARE(SUM(rs.avg_rowcount * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0))     AS VarRows,
            MIN(rs.min_dop)                                                                                AS MinDop,
            MAX(rs.max_dop)                                                                                AS MaxDop,
            SUM(rs.avg_query_max_used_memory * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) * 8.0 AS AvgUsedMemoryKB,
            MAX(rs.max_query_max_used_memory) * 8.0                                                        AS MaxUsedMemoryKB
        FROM sys.query_store_runtime_stats rs
        WHERE rs.execution_type = 0
          AND rs.last_execution_time > DATEADD(DAY, -@LookbackDaysIn, SYSUTCDATETIME())
        GROUP BY rs.plan_id
    ) agg;';

    EXEC sys.sp_executesql @Sql, N'@LookbackDaysIn INT', @LookbackDaysIn = @LookbackDays;
    SET @Rows = @@ROWCOUNT;

    /*  Tempdb use per plan: 2017+ columns, so gated -- a static reference stops the batch
        compiling on 2016. Pooled-stdev and every other expression above are lifted verbatim
        from the script's Section 2; see the note there.                                   */
    IF COL_LENGTH('sys.query_store_runtime_stats', 'max_tempdb_space_used') IS NOT NULL
    BEGIN
        SET @Sql = @Use + N'
        UPDATE rr
        SET rr.AvgTempdbKB = t.AvgTempdbKB,
            rr.MaxTempdbKB = t.MaxTempdbKB
        FROM #RuntimeRollup rr
        JOIN (SELECT rs.plan_id,
                     SUM(rs.avg_tempdb_space_used * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) * 8.0 AS AvgTempdbKB,
                     MAX(rs.max_tempdb_space_used) * 8.0                                                        AS MaxTempdbKB
              FROM sys.query_store_runtime_stats rs
              WHERE rs.execution_type = 0
                AND rs.last_execution_time > DATEADD(DAY, -@LookbackDaysIn, SYSUTCDATETIME())
              GROUP BY rs.plan_id) t ON t.plan_id = rr.plan_id;';

        EXEC sys.sp_executesql @Sql, N'@LookbackDaysIn INT', @LookbackDaysIn = @LookbackDays;
    END;

    IF @Debug = 1 RAISERROR('#RuntimeRollup: %d row(s)', 0, 0, @Rows) WITH NOWAIT;

    /*----------------------------------------------------------------------------------------
      WAIT STATS -- 2017+. Left empty on older engines; everything downstream LEFT JOINs it.
    ----------------------------------------------------------------------------------------*/
    IF @HasWaitStats = 1
    BEGIN
        SET @Sql = @Use + N'
        INSERT INTO #WaitRollup (plan_id, LockWaitMs, IOWaitMs, TotalWaitMs)
        SELECT
            ws.plan_id,
            SUM(CASE WHEN ws.wait_category_desc = ''Lock'' THEN ws.total_query_wait_time_ms ELSE 0 END),
            SUM(CASE WHEN ws.wait_category_desc IN (''Buffer IO'',''Tran Log IO'',''Other Disk IO'',''Network IO'') THEN ws.total_query_wait_time_ms ELSE 0 END),
            SUM(ws.total_query_wait_time_ms)
        FROM sys.query_store_wait_stats ws
        JOIN sys.query_store_runtime_stats_interval rsi
          ON rsi.runtime_stats_interval_id = ws.runtime_stats_interval_id
        WHERE ws.execution_type = 0
          AND rsi.start_time > DATEADD(DAY, -@LookbackDaysIn, SYSUTCDATETIME())
        GROUP BY ws.plan_id;';

        EXEC sys.sp_executesql @Sql, N'@LookbackDaysIn INT', @LookbackDaysIn = @LookbackDays;
    END;

    /*----------------------------------------------------------------------------------------
      PSPO QUERY VARIANTS -- 2022+ and MI. Without this a parameter-sensitive statement is
      INVISIBLE: a variant carries object_id 0 and holds every execution, while the dispatcher
      carries the object_id and records no runtime at all, so the collection below dropped both.
      Measured 2026-09-21; the full account is in the script's Section 3c.
    ----------------------------------------------------------------------------------------*/
    IF @HasQueryVariantView = 1
    BEGIN
        SET @Sql = @Use + N'
        INSERT INTO #PspoVariant (variant_query_id, parent_query_id, parent_object_id, variant_count)
        SELECT v.query_variant_query_id,
               MIN(v.parent_query_id),
               MIN(pq.object_id),
               MIN(vc.n)
        FROM sys.query_store_query_variant v
        JOIN sys.query_store_query pq ON pq.query_id = v.parent_query_id
        CROSS APPLY (SELECT COUNT(DISTINCT v2.query_variant_query_id)
                     FROM sys.query_store_query_variant v2
                     WHERE v2.parent_query_id = v.parent_query_id) vc(n)
        GROUP BY v.query_variant_query_id;';

        BEGIN TRY
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            PRINT '*** PSPO variant mapping skipped for ' + @DatabaseName + ': ' + ERROR_MESSAGE() + ' ***';
        END CATCH
    END;

    /*----------------------------------------------------------------------------------------
      MEMORY GRANT FEEDBACK -- 2022+ and MI. An annotation: never fatal.
    ----------------------------------------------------------------------------------------*/
    IF @HasPlanFeedbk = 1 AND @AnnotateMemoryGrantFeedback = 1
    BEGIN
        SET @Sql = @Use + N'
        INSERT INTO #GrantFeedback (plan_id, FeedbackState, AdditionalKB)
        SELECT pf.plan_id,
               MAX(pf.state_desc),
               SUM(TRY_CAST(j.AdditionalMemoryKB AS BIGINT))
        FROM sys.query_store_plan_feedback pf
        OUTER APPLY OPENJSON(pf.feedback_data)
                    WITH (AdditionalMemoryKB NVARCHAR(40) ''$.AdditionalMemoryKB'') AS j
        WHERE pf.feature_desc = N''Memory Grant Feedback''
        GROUP BY pf.plan_id;';

        BEGIN TRY
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            PRINT '*** Memory grant feedback annotation skipped: ' + ERROR_MESSAGE() + ' ***';
        END CATCH
    END;

    /*----------------------------------------------------------------------------------------
      CACHE MATCH -- Query Store joined to the plan cache.

      WITH XMLNAMESPACES is mandatory on every statement that shreds plan XML. Without it each
      .value() returns NULL silently -- no error, just wrong numbers.

      The dm_exec_sql_text join carries a dbid filter that the v1 script does not need and MUST
      have here: object_id is unique within a database, not across them, so without it a cached
      statement from another database with a colliding object_id can satisfy the match.
    ----------------------------------------------------------------------------------------*/
    SET @Sql = @Use + N'
    WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
    INSERT INTO #CacheMatch
        (query_id, plan_id, query_hash, query_plan_hash, QueryPlanHashText, QueryHashText,
         object_id, object_name, query_sql_text, EstimatedPlanXML,
         TotalExecutions, AvgLogicalReads, MaxLogicalReads, AvgDurationMs, MaxDurationMs,
         AvgCpuTimeMs, AvgRowcount, MaxRowcount, MinRowcount, LastExecutionTime,
         plan_handle, CachePlanHash, CacheLastExecutionTime, CacheActualPlanXML,
         CacheActualPlanAvailable, PlanCompatModel, EstimatedRows, EstimatedMemoryGrant,
         EstimatedParallelismFlag, CacheActualRows, CacheActualMemoryGrant, CacheActualParallelismFlag,
         IsForcedPlan, ForceFailureCount, PlanCompileCount,
         CacheCreationTime, CacheExecutionCount, CacheTotalWorkerMs, CacheMinWorkerMs, CacheMaxWorkerMs,
         CacheTotalElapsedMs, CacheMinElapsedMs, CacheMaxElapsedMs, CacheTotalLogicalReads,
         CacheMinLogicalReads, CacheMaxLogicalReads, CacheTotalLogicalWrites, CacheTotalRows,
         CacheMinRows, CacheMaxRows, CacheStmtStart, CacheStmtEnd,
         CacheSqlHandle, CacheIsThisStatement, CacheSameHashStatements, CacheStmtOrdinal,
         CacheAttributionDeclined, CacheActualPlanDeclined,
         PspoRole, PspoParentQueryId, PspoVariantCount)
    SELECT
        qsq.query_id,
        qsp.plan_id,
        qsq.query_hash,
        qsp.query_plan_hash,
        CONVERT(VARCHAR(34), qsp.query_plan_hash, 1),
        CONVERT(VARCHAR(34), qsq.query_hash, 1),
        qsq.object_id,
        ISNULL(OBJECT_NAME(COALESCE(NULLIF(qsq.object_id, 0), pv.parent_object_id)),
               N''AdHocOrDynamicSQL''),
        qst.query_sql_text,
        EP.EstPlanXml,
        rr.TotalExecutions, rr.AvgLogicalReads, rr.MaxLogicalReads, rr.AvgDurationMs,
        rr.MaxDurationMs, rr.AvgCpuTimeMs, rr.AvgRowcount, rr.MaxRowcount, rr.MinRowcount,
        rr.LastExecutionTime,
        dqs.plan_handle,
        dqs.query_plan_hash,
        dqs.last_execution_time,
        ap.CacheActualPlanXML,
        ap.CacheActualPlanAvailable,
        TRY_CAST(EP.EstPlanXml.value(''(//StmtSimple/@CardinalityEstimationModelVersion)[1]'', ''varchar(10)'') AS INT),
        EP.EstPlanXml.value(''(//QueryPlan/RelOp)[1]/@EstimateRows'', ''float''),
        EP.EstPlanXml.value(''(//QueryPlan/MemoryGrantInfo/@SerialDesiredMemory)[1]'', ''float''),
        -- Any operator flagged parallel, not the root: a parallel plan''s root is often a serial
        -- operator above the Gather Streams. See the 2026-09-14 note in the script''s Section 4.
        CONVERT(BIT, EP.EstPlanXml.exist(''//RelOp[@Parallel = "1" or @Parallel = "true"]'')),
        CAST(NULL AS FLOAT),
        CAST(NULL AS FLOAT),
        CAST(NULL AS BIT),
        qsp.is_forced_plan, qsp.force_failure_count, qsp.count_compiles,
        dqs.creation_time, dqs.execution_count,
        dqs.total_worker_time  / 1000.0, dqs.min_worker_time  / 1000.0, dqs.max_worker_time  / 1000.0,
        dqs.total_elapsed_time / 1000.0, dqs.min_elapsed_time / 1000.0, dqs.max_elapsed_time / 1000.0,
        dqs.total_logical_reads, dqs.min_logical_reads, dqs.max_logical_reads, dqs.total_logical_writes,
        dqs.total_rows, dqs.min_rows, dqs.max_rows, dqs.statement_start_offset, dqs.statement_end_offset,
        CONVERT(VARBINARY(64), dqs.sql_handle), dqs.IsThisStatement, dqs.SameHashStatements, dqs.StmtOrdinal,
        CAST(0 AS BIT), CAST(0 AS BIT),
        CASE WHEN pv.variant_query_id IS NOT NULL THEN N''Variant'' END,
        pv.parent_query_id,
        pv.variant_count
    FROM sys.query_store_query qsq
    JOIN sys.query_store_query_text qst ON qsq.query_text_id = qst.query_text_id
    JOIN sys.query_store_plan qsp       ON qsq.query_id = qsp.query_id
    JOIN #RuntimeRollup rr              ON qsp.plan_id = rr.plan_id
    LEFT JOIN #PspoVariant pv           ON pv.variant_query_id = qsq.query_id
    CROSS APPLY (SELECT TRY_CAST(qsp.query_plan AS XML) AS EstPlanXml) EP
    OUTER APPLY (
        SELECT TOP (1) qs2.plan_handle, qs2.sql_handle, qs2.query_plan_hash, qs2.last_execution_time,
               qs2.creation_time, qs2.execution_count,
               qs2.total_worker_time, qs2.min_worker_time, qs2.max_worker_time,
               qs2.total_elapsed_time, qs2.min_elapsed_time, qs2.max_elapsed_time,
               qs2.total_logical_reads, qs2.min_logical_reads, qs2.max_logical_reads,
               qs2.total_logical_writes, qs2.total_rows, qs2.min_rows, qs2.max_rows,
               qs2.statement_start_offset, qs2.statement_end_offset,
               CASE WHEN qs2.sql_handle = qsq.last_compile_batch_sql_handle
                     AND qs2.statement_start_offset = qsq.last_compile_batch_offset_start
                    THEN 1 ELSE 0 END                                                             AS IsThisStatement,
               COUNT(*) OVER (PARTITION BY qs2.plan_handle)                                       AS SameHashStatements,
               ROW_NUMBER() OVER (PARTITION BY qs2.plan_handle ORDER BY qs2.statement_start_offset) AS StmtOrdinal
        FROM sys.dm_exec_query_stats qs2
        CROSS APPLY sys.dm_exec_sql_text(qs2.sql_handle) st2
        WHERE qs2.query_hash = qsq.query_hash
          AND st2.dbid = DB_ID()
          AND ISNULL(st2.objectid, 0) = ISNULL(qsq.object_id, 0)
          /*  Declines for a PSPO variant, explicitly rather than as a side effect of the dbid
              guard above -- see the long note in Section 3c of the script. Stated here because the
              two artifacts must decline for the SAME reason, not merely reach the same answer.  */
          AND pv.variant_query_id IS NULL
        ORDER BY IsThisStatement DESC, qs2.last_execution_time DESC
    ) dqs
    CROSS APPLY (
        SELECT CAST(NULL AS XML) AS CacheActualPlanXML, 0 AS CacheActualPlanAvailable
    ) ap
    WHERE (@TargetObjectIdIn IS NULL
           OR COALESCE(NULLIF(qsq.object_id, 0), pv.parent_object_id) = @TargetObjectIdIn)
      AND (COALESCE(NULLIF(qsq.object_id, 0), pv.parent_object_id)
               IN (SELECT object_id FROM sys.objects WHERE type = ''P'')
       OR (@IncludeAdHocIn = 1
           AND ISNULL(qsq.object_id, 0) = 0
           AND (@ExcludeSelfIn = 0
                OR (    qst.query_sql_text NOT LIKE N''%#PlanAgg%''
                    AND qst.query_sql_text NOT LIKE N''%#CacheMatch%''
                    AND qst.query_sql_text NOT LIKE N''%#LeafColumnsRaw%''
                    AND qst.query_sql_text NOT LIKE N''%#TableCandidates%''
                    AND qst.query_sql_text NOT LIKE N''%#ColumnEligibility%''
                    AND qst.query_sql_text NOT LIKE N''%#RuntimeRollup%''
                    AND qst.query_sql_text NOT LIKE N''%#Scored%''))));';

    EXEC sys.sp_executesql @Sql,
        N'@TargetObjectIdIn INT, @IncludeAdHocIn BIT, @ExcludeSelfIn BIT',
        @TargetObjectIdIn = @TargetObjectId,
        @IncludeAdHocIn   = @IncludeAdHocAndDynamicSQL,
        @ExcludeSelfIn    = @ExcludeSelfCapturedStatements;
    SET @Rows = @@ROWCOUNT;

    IF @Debug = 1 RAISERROR('#CacheMatch: %d row(s)', 0, 0, @Rows) WITH NOWAIT;

    /*----------------------------------------------------------------------------------------
      ATTRIBUTION CHECK (2026-09-14) -- verbatim from the script's Section 4, which carries the
      reasoning: a procedure can hold several statements with one query_hash, and a cache entry is
      kept for a row only when it is certainly that row's statement. Runs in the target's context
      because it reads that database's Query Store, and in its own batch so @Rows above stays the
      INSERT's count.
    ----------------------------------------------------------------------------------------*/
    SET @Sql = @Use + N'
    UPDATE cm
    SET cm.QsSameHashQueries = (SELECT COUNT(*)
                                FROM sys.query_store_query q3
                                WHERE q3.object_id = cm.object_id
                                  AND q3.query_hash = cm.query_hash
                                  AND q3.last_compile_batch_sql_handle = cm.CacheSqlHandle)
    FROM #CacheMatch cm
    WHERE cm.plan_handle IS NOT NULL;

    UPDATE #CacheMatch
    SET CacheAttributionDeclined = 1,
        plan_handle = NULL, CacheSqlHandle = NULL, CachePlanHash = NULL,
        CacheLastExecutionTime = NULL, CacheCreationTime = NULL, CacheExecutionCount = NULL,
        CacheTotalWorkerMs = NULL, CacheMinWorkerMs = NULL, CacheMaxWorkerMs = NULL,
        CacheTotalElapsedMs = NULL, CacheMinElapsedMs = NULL, CacheMaxElapsedMs = NULL,
        CacheTotalLogicalReads = NULL, CacheMinLogicalReads = NULL, CacheMaxLogicalReads = NULL,
        CacheTotalLogicalWrites = NULL, CacheTotalRows = NULL, CacheMinRows = NULL, CacheMaxRows = NULL,
        CacheStmtStart = NULL, CacheStmtEnd = NULL, CacheStmtOrdinal = NULL
    WHERE plan_handle IS NOT NULL
      AND (   (CacheSameHashStatements > 1 AND (CacheIsThisStatement = 0 OR QsSameHashQueries < CacheSameHashStatements))
           OR (CacheIsThisStatement = 0 AND QsSameHashQueries > 1));';

    EXEC sys.sp_executesql @Sql;

    /*----------------------------------------------------------------------------------------
      ACTUAL-PLAN CAPTURE -- 2019+. dm_exec_query_plan_stats is server-scoped, so this runs
      without a context switch; plan_handle already identifies the row uniquely.

      The narrowing is keyed on QueryHashText, not the plan hash: the plan hash only matches when
      the row's Query Store plan happens to be the cached one, which is exactly false for the
      stale-plan rows this tool exists to find.

      It keeps ONE statement -- the CacheStmtOrdinal-th with the hash -- and only when the batch plan
      holds exactly as many as the cache does; otherwise the actual plan is declined, never left
      whole, because a whole batch describes other statements (2026-09-14; the script's Section 4a
      has the measurements).
    ----------------------------------------------------------------------------------------*/
    IF @HasPlanStats = 1
    BEGIN
        SET @Sql = N'
        UPDATE cm
        SET cm.CacheActualPlanXML       = qps.query_plan,
            cm.CacheActualPlanAvailable = 1
        FROM #CacheMatch cm
        CROSS APPLY sys.dm_exec_query_plan_stats(cm.plan_handle) qps
        WHERE cm.plan_handle IS NOT NULL
          AND qps.query_plan IS NOT NULL;';

        EXEC sys.sp_executesql @Sql;

        WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        UPDATE cm
        SET cm.CacheActualHashMatches = cm.CacheActualPlanXML.value(
                'count(//StmtSimple[@QueryHash=sql:column("cm.QueryHashText")])', 'int')
        FROM #CacheMatch cm
        WHERE cm.CacheActualPlanXML IS NOT NULL;

        WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        UPDATE cm
        SET cm.CacheActualPlanXML = cm.CacheActualPlanXML.query(
                '(//StmtSimple[@QueryHash=sql:column("cm.QueryHashText")])[sql:column("cm.CacheStmtOrdinal")]')
        FROM #CacheMatch cm
        WHERE cm.CacheActualPlanXML IS NOT NULL
          AND cm.CacheActualHashMatches >= 1
          AND cm.CacheActualHashMatches = cm.CacheSameHashStatements;

        UPDATE #CacheMatch
        SET CacheActualPlanXML       = NULL,
            CacheActualPlanAvailable = 0,
            CacheActualPlanDeclined  = 1
        WHERE CacheActualPlanXML IS NOT NULL
          AND CASE WHEN CacheActualHashMatches >= 1 AND CacheActualHashMatches = CacheSameHashStatements
                   THEN 1 ELSE 0 END = 0;   -- CASE, so a NULL count declines rather than keeping the batch

        -- //RelOp[RunTimeInformation], not (//QueryPlan/RelOp)[1]: a pass-through Compute Scalar
        -- carries no RunTimeInformation of its own, and XQuery sum() over an empty node-set
        -- returns 0 rather than NULL -- a plausible-looking wrong row count.
        WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        UPDATE cm
        SET cm.CacheActualRows            = cm.CacheActualPlanXML.value('sum((//RelOp[RunTimeInformation])[1]/RunTimeInformation/RunTimeCountersPerThread/@ActualRows)', 'float'),
            cm.CacheActualMemoryGrant     = cm.CacheActualPlanXML.value('(//QueryPlan/MemoryGrantInfo/@SerialDesiredMemory)[1]', 'float'),
            -- Any operator flagged parallel -- the same question the estimated side asks.
            cm.CacheActualParallelismFlag = CONVERT(BIT, cm.CacheActualPlanXML.exist('//RelOp[@Parallel = "1" or @Parallel = "true"]'))
        FROM #CacheMatch cm
        WHERE cm.CacheActualPlanXML IS NOT NULL;
    END;

    /*----------------------------------------------------------------------------------------
      [AI Prompt] EVIDENCE PER PLAN (2026-09-14) -- verbatim from the script's Section 4b, which
      carries the reasoning. Cache first, Query Store as well; the last actual plan carries no
      runtime parameter values, so the prompt reports compiled ones.
    ----------------------------------------------------------------------------------------*/
    /*  Grant, spill and DOP counters are later-build columns of sys.dm_exec_query_stats -- named
        statically on an older engine they would stop the whole batch compiling, the Section 3 problem
        again -- so the read is dynamic and gated on the columns existing. It re-reads the ONE cached
        statement Section 4 picked, pinned by plan_handle and statement offsets, so it cannot describe a
        different statement.                                                                          */
    IF COL_LENGTH('sys.dm_exec_query_stats', 'max_used_grant_kb') IS NOT NULL
       AND COL_LENGTH('sys.dm_exec_query_stats', 'max_spills') IS NOT NULL
       AND COL_LENGTH('sys.dm_exec_query_stats', 'max_dop') IS NOT NULL
    BEGIN
        DECLARE @CacheCountersSql NVARCHAR(MAX) = N'
        UPDATE cm
        SET cm.CacheMinGrantKB      = qs.min_grant_kb,
            cm.CacheMaxGrantKB      = qs.max_grant_kb,
            cm.CacheMinUsedGrantKB  = qs.min_used_grant_kb,
            cm.CacheMaxUsedGrantKB  = qs.max_used_grant_kb,
            cm.CacheMaxIdealGrantKB = qs.max_ideal_grant_kb,
            cm.CacheTotalSpills     = qs.total_spills,
            cm.CacheMaxSpills       = qs.max_spills,
            cm.CacheMinDop          = qs.min_dop,
            cm.CacheMaxDop          = qs.max_dop
        FROM #CacheMatch cm
        JOIN sys.dm_exec_query_stats qs
          ON  qs.plan_handle            = cm.plan_handle
          AND qs.statement_start_offset = cm.CacheStmtStart
          AND qs.statement_end_offset   = cm.CacheStmtEnd;';

        EXEC sys.sp_executesql @CacheCountersSql;
    END;

    /*  Operators and warnings are materialised first because XML methods cannot appear in GROUP BY
        (Msg 4148). Parallelism operators are named by their logical form (Gather Streams, Repartition
        Streams), which is the part a reader needs.                                                   */
    WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT cm.query_id,
           cm.plan_id,
           CASE WHEN r.o.value('@PhysicalOp', 'nvarchar(60)') = N'Parallelism'
                THEN r.o.value('@LogicalOp', 'nvarchar(60)')
                ELSE r.o.value('@PhysicalOp', 'nvarchar(60)') END                    AS OperatorName,
           r.o.value('@NodeId', 'int')                                               AS NodeId
    INTO #AIPlanOperators
    FROM #CacheMatch cm
    CROSS APPLY cm.EstimatedPlanXML.nodes('//RelOp') r(o);

    /*  A warning is either a child element of <Warnings> (SpillToTempDb, PlanAffectingConvert,
        ColumnsWithNoStatistics, ...) or a true-valued attribute on it (NoJoinPredicate, ...). Both are
        read. PLAN = the stored plan of this row; ACTUAL = the cached statement's last actual plan.     */
    WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT cm.query_id, cm.plan_id, CAST('PLAN' AS VARCHAR(6)) AS PlanSource,
           w.n.value('local-name(.)', 'nvarchar(128)')  AS WarningName
    INTO #AIPlanWarnings
    FROM #CacheMatch cm
    CROSS APPLY cm.EstimatedPlanXML.nodes('//Warnings/*') w(n)
    UNION ALL
    SELECT cm.query_id, cm.plan_id, 'PLAN', a.v.value('local-name(.)', 'nvarchar(128)')
    FROM #CacheMatch cm
    CROSS APPLY cm.EstimatedPlanXML.nodes('//Warnings/@*') a(v)
    WHERE a.v.value('.', 'nvarchar(10)') IN (N'1', N'true')
    UNION ALL
    SELECT cm.query_id, cm.plan_id, 'ACTUAL', w.n.value('local-name(.)', 'nvarchar(128)')
    FROM #CacheMatch cm
    CROSS APPLY cm.CacheActualPlanXML.nodes('//Warnings/*') w(n)
    UNION ALL
    SELECT cm.query_id, cm.plan_id, 'ACTUAL', a.v.value('local-name(.)', 'nvarchar(128)')
    FROM #CacheMatch cm
    CROSS APPLY cm.CacheActualPlanXML.nodes('//Warnings/@*') a(v)
    WHERE a.v.value('.', 'nvarchar(10)') IN (N'1', N'true');

    /*  One row per plan. Every list is built with an explicit ORDER BY, so the same plan produces the
        same text on every run and in both artifacts -- nodes() does not promise document order.       */
    WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT
        cm.query_id,
        cm.plan_id,
        CONVERT(BIT, CASE WHEN cm.CachePlanHash = cm.query_plan_hash THEN 1 ELSE 0 END)       AS IsCachedPlan,
        cm.EstimatedParallelismFlag                                                           AS IsParallel,
        STUFF((SELECT N', ' + prm.ParameterName + N' = ' + prm.CompiledValue
               FROM (SELECT DISTINCT
                            COALESCE(pr.c.value('@Column', 'nvarchar(128)'), N'?')                               AS ParameterName,
                            COALESCE(pr.c.value('@ParameterCompiledValue', 'nvarchar(4000)'), N'(not recorded)') AS CompiledValue
                     FROM cm.EstimatedPlanXML.nodes('//StmtSimple/QueryPlan/ParameterList/ColumnReference') pr(c)) prm
               ORDER BY prm.ParameterName, prm.CompiledValue
               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'')                AS CompiledParameters,
        cm.EstimatedPlanXML.value('(//StmtSimple/@StatementEstRows)[1]', 'float')             AS EstStatementRows,
        cm.EstimatedPlanXML.value('(//StmtSimple/@StatementSubTreeCost)[1]', 'float')         AS EstSubtreeCost,
        cm.EstimatedPlanXML.value('count(//RelOp[@PhysicalOp = "Parallelism"])', 'int')       AS ParallelismOperators,
        cm.EstimatedPlanXML.value('count(//MissingIndexes/MissingIndexGroup)', 'int')         AS MissingIndexHints,
        STUFF((SELECT N', ' + o.OperatorName
                      + CASE WHEN o.OperatorCount > 1 THEN N' x' + CONVERT(NVARCHAR(10), o.OperatorCount) ELSE N'' END
               FROM (SELECT ao.OperatorName, COUNT(*) AS OperatorCount, MIN(ao.NodeId) AS FirstNodeId
                     FROM #AIPlanOperators ao
                     WHERE ao.query_id = cm.query_id AND ao.plan_id = cm.plan_id
                     GROUP BY ao.OperatorName) o
               ORDER BY o.FirstNodeId, o.OperatorName
               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'')                AS OperatorSummary,
        STUFF((SELECT N', ' + w.WarningName
               FROM (SELECT DISTINCT aw.WarningName FROM #AIPlanWarnings aw
                     WHERE aw.query_id = cm.query_id AND aw.plan_id = cm.plan_id AND aw.PlanSource = 'PLAN') w
               ORDER BY w.WarningName
               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'')                AS PlanWarnings,
        cm.CacheActualPlanXML.value('(//QueryPlan/@DegreeOfParallelism)[1]', 'int')           AS ActualDop,
        cm.CacheActualPlanXML.value('(//QueryPlan/MemoryGrantInfo/@GrantedMemory)[1]', 'bigint') AS ActualGrantedKB,
        cm.CacheActualPlanXML.value('(//QueryPlan/MemoryGrantInfo/@MaxUsedMemory)[1]', 'bigint') AS ActualMaxUsedKB,
        STUFF((SELECT N', ' + w.WarningName
               FROM (SELECT DISTINCT aw.WarningName FROM #AIPlanWarnings aw
                     WHERE aw.query_id = cm.query_id AND aw.plan_id = cm.plan_id AND aw.PlanSource = 'ACTUAL') w
               ORDER BY w.WarningName
               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'')                AS ActualWarnings,
        rr.FirstExecutionTime, rr.LastExecutionTime, rr.TotalExecutions,
        rr.AvgDurationMs, rr.MinDurationMs, rr.MaxDurationMs, rr.StdevDurationMs,
        rr.AvgCpuTimeMs, rr.MinCpuTimeMs, rr.MaxCpuTimeMs, rr.StdevCpuTimeMs,
        rr.AvgLogicalReads, rr.MinLogicalReads, rr.MaxLogicalReads, rr.StdevLogicalReads,
        rr.AvgLogicalWrites, rr.MaxLogicalWrites, rr.AvgPhysicalReads,
        rr.AvgRowcount, rr.MinRowcount, rr.MaxRowcount, rr.StdevRowcount,
        rr.MinDop, rr.MaxDop, rr.AvgUsedMemoryKB, rr.MaxUsedMemoryKB, rr.AvgTempdbKB, rr.MaxTempdbKB,
        cm.IsForcedPlan, cm.ForceFailureCount, cm.PlanCompileCount,
        cm.CachePlanHash, cm.CacheActualPlanAvailable, cm.CacheCreationTime, cm.CacheLastExecutionTime,
        cm.CacheExecutionCount,
        cm.CacheTotalWorkerMs, cm.CacheMinWorkerMs, cm.CacheMaxWorkerMs,
        cm.CacheTotalElapsedMs, cm.CacheMinElapsedMs, cm.CacheMaxElapsedMs,
        cm.CacheTotalLogicalReads, cm.CacheMinLogicalReads, cm.CacheMaxLogicalReads, cm.CacheTotalLogicalWrites,
        cm.CacheTotalRows, cm.CacheMinRows, cm.CacheMaxRows,
        cm.CacheMinGrantKB, cm.CacheMaxGrantKB, cm.CacheMinUsedGrantKB, cm.CacheMaxUsedGrantKB, cm.CacheMaxIdealGrantKB,
        cm.CacheTotalSpills, cm.CacheMaxSpills, cm.CacheMinDop, cm.CacheMaxDop,
        cm.CacheAttributionDeclined, cm.CacheIsThisStatement, cm.CacheSameHashStatements, cm.QsSameHashQueries,
        cm.CacheActualPlanDeclined, cm.CacheActualHashMatches
    INTO #AIPromptPlan
    FROM #CacheMatch cm
    JOIN #RuntimeRollup rr ON rr.plan_id = cm.plan_id;

    /*----------------------------------------------------------------------------------------
      CATALOG READS -- QUOTENAME on both sides is load-bearing, not cosmetic. Showplan carries
      Object/@Schema and @Table with the brackets embedded as literal characters ("[Sales]"),
      while sys.schemas.name and sys.objects.name do not, so an unquoted catalog side never
      matches anything.
    ----------------------------------------------------------------------------------------*/
    SET @Sql = @Use + N'
    INSERT INTO #ClusteringKeyColumns (TableSchemaRaw, TableNameRaw, ColumnName)
    SELECT QUOTENAME(s.name), QUOTENAME(o.name), c.name
    FROM sys.indexes i
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
    JOIN sys.columns c        ON c.object_id  = ic.object_id AND c.column_id = ic.column_id
    JOIN sys.objects o        ON o.object_id  = i.object_id
    JOIN sys.schemas s        ON s.schema_id  = o.schema_id
    WHERE i.type = 1;

    INSERT INTO #TableSizeLookup (TableSchemaRaw, TableNameRaw, EstimatedTableSizeMB)
    SELECT QUOTENAME(s.name), QUOTENAME(o.name), SUM(ps.reserved_page_count) * 8.0 / 1024.0
    FROM sys.dm_db_partition_stats ps
    JOIN sys.objects o ON o.object_id = ps.object_id
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE ps.index_id IN (0, 1)
    GROUP BY s.name, o.name;

    INSERT INTO #XmlColumnCheck (TableSchemaRaw, TableNameRaw, isXML)
    SELECT TableSchemaRaw, TableNameRaw, CAST(1 AS BIT)
    FROM (
        SELECT QUOTENAME(s.name) AS TableSchemaRaw, QUOTENAME(o.name) AS TableNameRaw
        FROM sys.columns c
        JOIN sys.types ty   ON ty.user_type_id = c.user_type_id
        JOIN sys.objects o  ON o.object_id = c.object_id
        JOIN sys.schemas s  ON s.schema_id = o.schema_id
        WHERE ty.name = ''xml''
        UNION
        SELECT N''[sys]'', QUOTENAME(it.name)
        FROM sys.internal_tables it
        WHERE it.internal_type_desc = ''XML_INDEX_NODES''
    ) x;

    -- Section 8d in the script: isJSON native-column check, including the hidden
    -- json_index_* internal table -- see the script''s own comment for the full reasoning,
    -- including the correction of a first-draft claim that no such internal table existed.
    INSERT INTO #JsonNativeColumnCheck (TableSchemaRaw, TableNameRaw, NativeJsonState)
    SELECT x.TableSchemaRaw, x.TableNameRaw,
           CASE WHEN SUM(CASE WHEN cov.column_id IS NULL THEN 1 ELSE 0 END) > 0
                THEN ''NativeUncovered'' ELSE ''NativeCovered'' END
    FROM (
        SELECT QUOTENAME(s.name) AS TableSchemaRaw, QUOTENAME(o.name) AS TableNameRaw,
               c.object_id, c.column_id
        FROM sys.columns c
        JOIN sys.types ty   ON ty.user_type_id = c.user_type_id
        JOIN sys.objects o  ON o.object_id = c.object_id
        JOIN sys.schemas s  ON s.schema_id = o.schema_id
        WHERE ty.name = ''json''
    ) x
    LEFT JOIN (
        SELECT DISTINCT c2.object_id, c2.column_id
        FROM sys.json_indexes ji
        JOIN sys.index_columns ic ON ic.object_id = ji.object_id AND ic.index_id = ji.index_id
        JOIN sys.columns c2       ON c2.object_id = ic.object_id AND c2.column_id = ic.column_id
    ) cov
        ON  cov.object_id = x.object_id AND cov.column_id = x.column_id
    GROUP BY x.TableSchemaRaw, x.TableNameRaw

    UNION

    SELECT N''[sys]'', QUOTENAME(it.name), ''NativeCovered''
    FROM sys.internal_tables it
    WHERE it.internal_type_desc = ''JSON_INDEX_TABLE'';';

    EXEC sys.sp_executesql @Sql;

    /*  #ColumnEligibility is NOT collected here. It filters on #LeafColumnsRaw, which does not
        exist until the plan XML has been shredded, so it needs a second trip to the target after
        the first analysis pass. Collecting every column of every table instead would be the
        alternative, and on a real database that is a great deal of rows to carry for nothing.  */

    /*==========================================================================================
      ANALYSIS -- operates on the temp tables above. Transferred from Sections 5-12 of
      Paramsniffingdiagnostic_v1.sql, which remains the annotated reference for why any of it
      is the way it is.
    ==========================================================================================*/
    SELECT
        cm.query_id,
        MAX(rr.AvgLogicalReads)          AS WorstPlanAvgIO,
        MIN(rr.AvgLogicalReads)          AS BestPlanAvgIO,
        COUNT(DISTINCT cm.plan_id)       AS PlanCount
    INTO #PlanAgg
    FROM #CacheMatch cm
    JOIN #RuntimeRollup rr ON rr.plan_id = cm.plan_id
    GROUP BY cm.query_id;

    ;WITH RankedPlans AS (
        SELECT cm.query_id, cm.plan_id, rr.AvgLogicalReads,
               ROW_NUMBER() OVER (PARTITION BY cm.query_id ORDER BY rr.AvgLogicalReads ASC) AS BestRank
        FROM #CacheMatch cm
        JOIN #RuntimeRollup rr ON rr.plan_id = cm.plan_id
    )
    SELECT query_id, plan_id AS BestPlanID
    INTO #BestPlanLookup
    FROM RankedPlans
    WHERE BestRank = 1;

    -- A seek and its own key/RID lookup are not independent access paths -- the lookup exists
    -- only because the seek's index does not cover enough columns. Detected via SQL Server's own
    -- Lookup="1" showplan marker on a Nested Loops inner branch that resolves to exactly one leaf,
    -- paired with an outer branch that also resolves to exactly one leaf on the same table. See
    -- TestCases_v1.sql for the empirical validation (7 pairs, 0 false positives) this was checked
    -- against before being trusted. Paths are evaluated directly against the original plan XML,
    -- not a re-rooted .query() fragment -- self:: did not behave as expected against one.
    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT cm.object_name, cm.query_id, cm.plan_id,
           NL.value('@NodeId', 'int') AS NLNodeId, CAST('Outer' AS VARCHAR(5)) AS Which,
           Leaf.value('@NodeId', 'int')                              AS LeafNodeId,
           Leaf.value('(./*/Object/@Schema)[1]', 'nvarchar(128)')     AS SchemaRaw,
           Leaf.value('(./*/Object/@Table)[1]', 'nvarchar(128)')      AS TableRaw,
           CAST(0 AS BIT)                                             AS HasLookup
    INTO #LookupBranchLeaves
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp[@PhysicalOp="Nested Loops"]') AS N(NL)
    CROSS APPLY NL.nodes('./NestedLoops/RelOp[1][contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")][*/Object/@Table]') AS OA(Leaf)
    WHERE AP.PlanXml IS NOT NULL

    UNION ALL

    SELECT cm.object_name, cm.query_id, cm.plan_id,
           NL.value('@NodeId', 'int'), 'Outer',
           Leaf.value('@NodeId', 'int'),
           Leaf.value('(./*/Object/@Schema)[1]', 'nvarchar(128)'),
           Leaf.value('(./*/Object/@Table)[1]', 'nvarchar(128)'),
           0
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp[@PhysicalOp="Nested Loops"]') AS N(NL)
    CROSS APPLY NL.nodes('./NestedLoops/RelOp[1]//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")][*/Object/@Table]') AS OB(Leaf)
    WHERE AP.PlanXml IS NOT NULL;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    INSERT INTO #LookupBranchLeaves (object_name, query_id, plan_id, NLNodeId, Which, LeafNodeId, SchemaRaw, TableRaw, HasLookup)
    SELECT cm.object_name, cm.query_id, cm.plan_id,
           NL.value('@NodeId', 'int'), 'Inner',
           Leaf.value('@NodeId', 'int'),
           Leaf.value('(./*/Object/@Schema)[1]', 'nvarchar(128)'),
           Leaf.value('(./*/Object/@Table)[1]', 'nvarchar(128)'),
           Leaf.exist('./*[@Lookup="1"]')
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp[@PhysicalOp="Nested Loops"]') AS N(NL)
    CROSS APPLY NL.nodes('./NestedLoops/RelOp[2][contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")][*/Object/@Table]') AS IA(Leaf)
    WHERE AP.PlanXml IS NOT NULL

    UNION ALL

    SELECT cm.object_name, cm.query_id, cm.plan_id,
           NL.value('@NodeId', 'int'), 'Inner',
           Leaf.value('@NodeId', 'int'),
           Leaf.value('(./*/Object/@Schema)[1]', 'nvarchar(128)'),
           Leaf.value('(./*/Object/@Table)[1]', 'nvarchar(128)'),
           Leaf.exist('./*[@Lookup="1"]')
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp[@PhysicalOp="Nested Loops"]') AS N(NL)
    CROSS APPLY NL.nodes('./NestedLoops/RelOp[2]//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")][*/Object/@Table]') AS IB(Leaf)
    WHERE AP.PlanXml IS NOT NULL;

    ;WITH OuterOne AS (
        SELECT object_name, query_id, plan_id, NLNodeId,
               MAX(LeafNodeId) AS OuterLeafId, MAX(SchemaRaw) AS OuterSchema, MAX(TableRaw) AS OuterTable
        FROM #LookupBranchLeaves WHERE Which = 'Outer'
        GROUP BY object_name, query_id, plan_id, NLNodeId
        HAVING COUNT(*) = 1
    ),
    InnerOne AS (
        SELECT object_name, query_id, plan_id, NLNodeId,
               MAX(LeafNodeId) AS InnerLeafId, MAX(SchemaRaw) AS InnerSchema, MAX(TableRaw) AS InnerTable,
               MAX(CAST(HasLookup AS INT)) AS HasLookup
        FROM #LookupBranchLeaves WHERE Which = 'Inner'
        GROUP BY object_name, query_id, plan_id, NLNodeId
        HAVING COUNT(*) = 1
    )
    SELECT o.object_name, o.query_id, o.plan_id,
           o.OuterLeafId AS SeekNodeId, i.InnerLeafId AS LookupNodeId
    INTO #LookupPairs
    FROM OuterOne o
    JOIN InnerOne i
      ON i.object_name = o.object_name AND i.query_id = o.query_id AND i.plan_id = o.plan_id AND i.NLNodeId = o.NLNodeId
    WHERE i.HasLookup = 1
      AND i.InnerSchema = o.OuterSchema AND i.InnerTable = o.OuterTable;

    CREATE CLUSTERED INDEX IX_LookupPairs ON #LookupPairs (object_name, query_id, plan_id, LookupNodeId);

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT
        cm.object_name, cm.query_id, cm.plan_id,

        LeafOp.value('@NodeId', 'int')                                                                     AS AccessNodeId,
        LeafOp.value('@PhysicalOp', 'nvarchar(50)')                                                        AS PhysicalOp,
        LeafOp.value('(./*/Object/@Schema)[1]', 'nvarchar(128)')                                            AS TableSchemaRaw,
        LeafOp.value('(./*/Object/@Table)[1]', 'nvarchar(128)')                                              AS TableNameRaw,
        LeafOp.value('@EstimateRows', 'float')                                                               AS EstimateRows,
        LeafOp.value('@EstimateIO', 'float')                                                                 AS EstimateIO,
        LeafOp.exist('./RunTimeInformation')                                                                  AS HasActualData,
        LeafOp.value('sum(./RunTimeInformation/RunTimeCountersPerThread/@ActualRows)', 'float')               AS ActualRowsSum,
        LeafOp.value('sum(./RunTimeInformation/RunTimeCountersPerThread/@ActualLogicalReads)', 'float')       AS ActualLogicalReadsSum,
        -- Whether reads were RECORDED at all -- the sum is 0 either way; see the script's Section 6.
        LeafOp.exist('./RunTimeInformation/RunTimeCountersPerThread/@ActualLogicalReads')                     AS HasActualReads
    INTO #LeafAttribution
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")]') AS T(LeafOp)
    WHERE AP.PlanXml IS NOT NULL
      AND LeafOp.exist('(./*/Object/@Table)[1]') = 1
      -- A lookup leaf contributes no row of its own -- the merged access is represented by its
      -- paired seek leaf's own row instead. Without this, two rows would share one AccessNodeId
      -- once the Include pass below remaps the lookup's columns onto the seek's id, and the final
      -- SELECT's join on AccessNodeId expects at most one.
      AND NOT EXISTS (
          SELECT 1 FROM #LookupPairs lp
          WHERE lp.object_name = cm.object_name AND lp.query_id = cm.query_id AND lp.plan_id = cm.plan_id
            AND lp.LookupNodeId = LeafOp.value('@NodeId', 'int')
      );

    SELECT
        object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw,
        SUM(EstimateIO)                                                                                       AS TotalEstimateIO,
        SUM(ActualLogicalReadsSum)                                                                            AS TotalActualIO,
        MAX(CASE WHEN HasActualData = 1 AND EstimateRows > 0 AND ActualRowsSum > 0
                 THEN CASE WHEN ActualRowsSum >= EstimateRows THEN ActualRowsSum / EstimateRows
                           ELSE EstimateRows / ActualRowsSum END
                 ELSE NULL END)                                                                                AS WorstSkewRatio,
        MAX(CAST(HasActualData AS INT))                                                                        AS AnyActualData,
        MAX(CAST(HasActualReads AS INT))                                                                       AS AnyActualReads,
        COUNT(*)                                                                                                AS LeafTouchCount
    INTO #TableRollup
    FROM #LeafAttribution
    GROUP BY object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT DISTINCT
        cm.object_name, cm.query_id, cm.plan_id,
        Anc.value('@NodeId', 'int')                            AS SourceNodeId,
        Leaf.value('(./*/Object/@Schema)[1]', 'nvarchar(128)')  AS TableSchemaRaw,
        Leaf.value('(./*/Object/@Table)[1]', 'nvarchar(128)')   AS TableNameRaw,
        -- A lookup leaf reports its PAIRED SEEK's node id here, not its own -- this single
        -- substitution is what makes the Filter/join/Sort attribution passes below (which all
        -- resolve AccessNodeId through this table) follow the merge automatically.
        COALESCE(lp.SeekNodeId, Leaf.value('@NodeId', 'int'))  AS AccessNodeId
    INTO #OperatorLeafMap
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp') AS AN(Anc)
    CROSS APPLY Anc.nodes('.//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")][*/Object/@Table]') AS LN(Leaf)
    LEFT JOIN #LookupPairs lp
           ON  lp.object_name = cm.object_name AND lp.query_id = cm.query_id AND lp.plan_id = cm.plan_id
           AND lp.LookupNodeId = Leaf.value('@NodeId', 'int')
    WHERE AP.PlanXml IS NOT NULL;

    CREATE CLUSTERED INDEX IX_OperatorLeafMap
        ON #OperatorLeafMap (object_name, query_id, plan_id, SourceNodeId, TableSchemaRaw, TableNameRaw);

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT
        cm.object_name, cm.query_id, cm.plan_id,
        LeafOp.value('(./*/Object/@Schema)[1]', 'nvarchar(128)')  AS TableSchemaRaw,
        LeafOp.value('(./*/Object/@Table)[1]', 'nvarchar(128)')   AS TableNameRaw,
        CAST('Key' AS VARCHAR(10))                                AS ColumnRole,

        ColRef.value('@Column', 'nvarchar(128)')                  AS ColumnName,

        CAST(NULL AS INT)                                         AS SortNodeId,
        CAST(NULL AS INT)                                         AS SortOrdinal,
        CAST(NULL AS BIT)                                         AS SortAsc,

        LeafOp.value('@NodeId', 'int')                            AS AccessNodeId
    INTO #LeafColumnsRaw
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")]') AS T(LeafOp)
    -- FIXED 2026-09-04: restricted to RangeColumns/IsNotNull -- RangeExpressions (the seek's
    -- comparison VALUE, not its own column) can legitimately name a different table on a
    -- correlated Nested Loops seek, and the old, unrestricted XPath leaked it in. See the
    -- script's own full reasoning (confirmed against showplanxml.xsd) at the same line.
    CROSS APPLY LeafOp.nodes('.//SeekPredicates//ColumnReference[@Table][local-name(..)="RangeColumns" or local-name(..)="IsNotNull"]') AS PK(ColRef)

    WHERE AP.PlanXml IS NOT NULL
      AND LeafOp.exist('(./*/Object/@Table)[1]') = 1
      -- A lookup leaf's own seek predicate is its seek on the CLUSTERING KEY, already free on any
      -- nonclustered index -- excluded, not remapped, so it never becomes a KEY column of the
      -- merged recommendation just because it happened to be how the lookup found the row.
      AND NOT EXISTS (
          SELECT 1 FROM #LookupPairs lp
          WHERE lp.object_name = cm.object_name AND lp.query_id = cm.query_id AND lp.plan_id = cm.plan_id
            AND lp.LookupNodeId = LeafOp.value('@NodeId', 'int')
      );

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    INSERT INTO #LeafColumnsRaw (object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, ColumnRole, ColumnName, AccessNodeId)
    SELECT
        cm.object_name, cm.query_id, cm.plan_id,
        LeafOp.value('(./*/Object/@Schema)[1]', 'nvarchar(128)'),
        LeafOp.value('(./*/Object/@Table)[1]', 'nvarchar(128)'),
        'Key',
        ColRef.value('@Column', 'nvarchar(128)'),
        LeafOp.value('@NodeId', 'int')
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")]') AS T(LeafOp)

    CROSS APPLY LeafOp.nodes('./*/Predicate//ColumnReference[@Table]') AS SP(ColRef)
    WHERE AP.PlanXml IS NOT NULL
      AND LeafOp.exist('(./*/Object/@Table)[1]') = 1
      -- Same exclusion as the seek-predicate pass above, same reason.
      AND NOT EXISTS (
          SELECT 1 FROM #LookupPairs lp
          WHERE lp.object_name = cm.object_name AND lp.query_id = cm.query_id AND lp.plan_id = cm.plan_id
            AND lp.LookupNodeId = LeafOp.value('@NodeId', 'int')
      );

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    INSERT INTO #LeafColumnsRaw (object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, ColumnRole, ColumnName, AccessNodeId)
    SELECT
        src.object_name, src.query_id, src.plan_id,
        COALESCE(olm.TableSchemaRaw, src.SchemaRaw), COALESCE(olm.TableNameRaw, src.TableRaw), 'Key', src.ColumnName,

        COALESCE(olm.AccessNodeId, -1)
    FROM (
        SELECT cm.object_name, cm.query_id, cm.plan_id,
               FiltOp.value('@NodeId', 'int')            AS SourceNodeId,
               ColRef.value('@Schema', 'nvarchar(128)')  AS SchemaRaw,
               ColRef.value('@Table', 'nvarchar(128)')   AS TableRaw,
               ColRef.value('@Column', 'nvarchar(128)')  AS ColumnName
        FROM #CacheMatch cm
        CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
        CROSS APPLY AP.PlanXml.nodes('//RelOp[@PhysicalOp="Filter"]') AS F(FiltOp)
        CROSS APPLY FiltOp.nodes('./Filter/Predicate//ColumnReference[@Table]') AS FP(ColRef)
        WHERE AP.PlanXml IS NOT NULL
    ) src
    -- Temp tables omit @Schema and leave @Table unbracketed on a ColumnReference under
    -- Filter/Predicate, OuterReferences, GroupBy and the join-key elements (measured 2026-09-03,
    -- Test 22) -- the OR branch below falls back to a name-only, bracket-normalized match
    -- against #OperatorLeafMap's own (always bracket-qualified) TableNameRaw when Schema is
    -- NULL, instead of silently stamping the row unattributed (-1). See
    -- Paramsniffingdiagnostic_v1.sql pass 3 for the full reasoning.
    LEFT JOIN #OperatorLeafMap olm
           ON  olm.object_name = src.object_name AND olm.query_id = src.query_id
           AND olm.plan_id = src.plan_id        AND olm.SourceNodeId = src.SourceNodeId
           AND (
                (src.SchemaRaw IS NOT NULL
                 AND olm.TableSchemaRaw = src.SchemaRaw AND olm.TableNameRaw = src.TableRaw)
                OR
                (src.SchemaRaw IS NULL AND olm.TableNameRaw = QUOTENAME(src.TableRaw))
               );

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    INSERT INTO #LeafColumnsRaw (object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, ColumnRole, ColumnName, AccessNodeId)
    SELECT
        cm.object_name, cm.query_id, cm.plan_id,
        COALESCE(olm.TableSchemaRaw, ColRef.value('@Schema', 'nvarchar(128)')),
        COALESCE(olm.TableNameRaw, ColRef.value('@Table', 'nvarchar(128)')),
        CASE ColRef.value('local-name(..)', 'nvarchar(60)')

            WHEN 'HashKeysBuild'        THEN CASE WHEN RO.Op.value('@LogicalOp', 'nvarchar(60)') LIKE '%Join%'
                                                  THEN CASE WHEN @JoinColumnKeyPolicy = 'S' THEN 'Include' ELSE 'Join' END
                                                  ELSE 'Group' END
            WHEN 'HashKeysProbe'        THEN CASE WHEN RO.Op.value('@LogicalOp', 'nvarchar(60)') LIKE '%Join%'
                                                  THEN CASE WHEN @JoinColumnKeyPolicy = 'S' THEN 'Include' ELSE 'Join' END
                                                  ELSE 'Group' END

            WHEN 'InnerSideJoinColumns' THEN 'Join'
            WHEN 'OuterSideJoinColumns' THEN 'Join'

            WHEN 'OuterReferences'      THEN CASE WHEN @JoinColumnKeyPolicy = 'S' THEN 'Include' ELSE 'Join' END

            WHEN 'GroupBy'              THEN 'Group'
        END,
        ColRef.value('@Column', 'nvarchar(128)'),
        COALESCE(olm.AccessNodeId, -1)
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp') AS RO(Op)
    CROSS APPLY RO.Op.nodes('./*/*/ColumnReference[@Table][local-name(..)="HashKeysBuild" or local-name(..)="HashKeysProbe" or local-name(..)="InnerSideJoinColumns" or local-name(..)="OuterSideJoinColumns" or local-name(..)="OuterReferences" or local-name(..)="GroupBy"]') AS JX(ColRef)
    -- Same temp-table fallback as the Filter pass above.
    LEFT JOIN #OperatorLeafMap olm
           ON  olm.object_name = cm.object_name AND olm.query_id = cm.query_id
           AND olm.plan_id = cm.plan_id
           AND olm.SourceNodeId   = RO.Op.value('@NodeId', 'int')
           AND (
                (ColRef.value('@Schema', 'nvarchar(128)') IS NOT NULL
                 AND olm.TableSchemaRaw = ColRef.value('@Schema', 'nvarchar(128)')
                 AND olm.TableNameRaw   = ColRef.value('@Table', 'nvarchar(128)'))
                OR
                (ColRef.value('@Schema', 'nvarchar(128)') IS NULL
                 AND olm.TableNameRaw = QUOTENAME(ColRef.value('@Table', 'nvarchar(128)')))
               )
    WHERE AP.PlanXml IS NOT NULL;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    INSERT INTO #LeafColumnsRaw (object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, ColumnRole, ColumnName,
                                 SortNodeId, SortOrdinal, SortAsc, AccessNodeId)
    SELECT
        cm.object_name, cm.query_id, cm.plan_id,
        COALESCE(olm.TableSchemaRaw, ColRef.value('@Schema', 'nvarchar(128)')),
        COALESCE(olm.TableNameRaw, ColRef.value('@Table', 'nvarchar(128)')),
        'Order',
        ColRef.value('@Column', 'nvarchar(128)'),
        RO.Op.value('@NodeId', 'int'),
        OB.OBCol.value('for $s in . return count($s/../OrderByColumn[. << $s]) + 1', 'int'),
        ISNULL(OB.OBCol.value('@Ascending', 'bit'), 1),

        COALESCE(olm.AccessNodeId, -1)
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp') AS RO(Op)
    CROSS APPLY RO.Op.nodes('./*/*/OrderByColumn') AS OB(OBCol)
    CROSS APPLY OB.OBCol.nodes('./ColumnReference[@Table]') AS JX(ColRef)
    -- Same temp-table fallback as the Filter pass above.
    LEFT JOIN #OperatorLeafMap olm
           ON  olm.object_name = cm.object_name AND olm.query_id = cm.query_id
           AND olm.plan_id = cm.plan_id
           AND olm.SourceNodeId   = RO.Op.value('@NodeId', 'int')
           AND (
                (ColRef.value('@Schema', 'nvarchar(128)') IS NOT NULL
                 AND olm.TableSchemaRaw = ColRef.value('@Schema', 'nvarchar(128)')
                 AND olm.TableNameRaw   = ColRef.value('@Table', 'nvarchar(128)'))
                OR
                (ColRef.value('@Schema', 'nvarchar(128)') IS NULL
                 AND olm.TableNameRaw = QUOTENAME(ColRef.value('@Table', 'nvarchar(128)')))
               )
    WHERE AP.PlanXml IS NOT NULL;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    INSERT INTO #LeafColumnsRaw (object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, ColumnRole, ColumnName, AccessNodeId)
    SELECT
        cm.object_name, cm.query_id, cm.plan_id,
        LeafOp.value('(./*/Object/@Schema)[1]', 'nvarchar(128)'),
        LeafOp.value('(./*/Object/@Table)[1]', 'nvarchar(128)'),
        'Include',
        ColRef.value('@Column', 'nvarchar(128)'),
        -- THE MERGE ITSELF: a lookup leaf's own OutputList is what it exists to fetch -- unlike
        -- its seek predicate, these ARE genuinely new to the merged access. Reassigned to the
        -- paired seek's AccessNodeId so the Include-column aggregation folds them into that one
        -- recommendation instead of the lookup producing a row of its own.
        COALESCE(lp.SeekNodeId, LeafOp.value('@NodeId', 'int')) AS AccessNodeId
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")]') AS T(LeafOp)
    CROSS APPLY LeafOp.nodes('./OutputList/ColumnReference[@Table]') AS OL(ColRef)
    LEFT JOIN #LookupPairs lp
           ON  lp.object_name = cm.object_name AND lp.query_id = cm.query_id AND lp.plan_id = cm.plan_id
           AND lp.LookupNodeId = LeafOp.value('@NodeId', 'int')
    WHERE AP.PlanXml IS NOT NULL
      AND LeafOp.exist('(./*/Object/@Table)[1]') = 1;

    -- A leaf's own OutputList never carries a computed column's name -- only the raw columns it
    -- reads do, since the value is synthesised by a Compute Scalar ABOVE the leaf. Detected here so
    -- the recommendation can disclose when a computed column the statement selects is already
    -- covered by an access's own key+include, without literally naming it. A plan re-references an
    -- already-computed value by relaying it through every ComputeScalar between the definition and
    -- the root, so the same name is "defined" multiple times at different depths -- everywhere
    -- except the true definition is self-referential (its own source is the computed column naming
    -- itself), excluded below by scoping to each DefinedValue's own subtree, not a broad descendant
    -- search. See TestCases_v1.sql for the four structurally different shapes this was checked
    -- against before being trusted.
    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT
        cm.object_name, cm.query_id, cm.plan_id,
        DV.value('(./ColumnReference[@ComputedColumn="1"]/@Schema)[1]', 'nvarchar(128)') AS TableSchemaRaw,
        DV.value('(./ColumnReference[@ComputedColumn="1"]/@Table)[1]', 'nvarchar(128)')  AS TableNameRaw,
        DV.value('(./ColumnReference[@ComputedColumn="1"]/@Column)[1]', 'nvarchar(128)') AS ComputedColumnName,
        SrcCol.value('@Column', 'nvarchar(128)')                                         AS SourceColumnName
    INTO #ComputedColumnSources
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp/*/DefinedValues/DefinedValue[ColumnReference[@ComputedColumn="1"]]') AS D(DV)
    CROSS APPLY DV.nodes('./ScalarOperator//ColumnReference[@Table]') AS SC(SrcCol)
    WHERE AP.PlanXml IS NOT NULL
      AND NOT (SrcCol.value('@ComputedColumn', 'nvarchar(5)') = '1'
               AND SrcCol.value('@Column', 'nvarchar(128)') = DV.value('(./ColumnReference[@ComputedColumn="1"]/@Column)[1]', 'nvarchar(128)'));

        /*  SECOND TRIP TO THE TARGET. #ColumnEligibility filters on #LeafColumnsRaw, which does not
            exist until the plan XML above has been shredded, so this cannot be collected up front.
            QUOTENAME on the catalog side is load-bearing: showplan carries Object/@Schema and @Table
            with brackets embedded as literal characters, and sys.schemas.name does not.            */
        CREATE TABLE #ColumnEligibility (
            TableSchemaRaw  NVARCHAR(258) NULL,
            TableNameRaw    NVARCHAR(258) NULL,
            ColumnName      sysname       NULL,
            TypeName        sysname       NOT NULL,
            KeyEligible     INT           NOT NULL,
            IncludeEligible INT           NOT NULL,
            IsLobType       INT           NOT NULL,
            KeyBytes        SMALLINT      NULL
        );

        CREATE TABLE #EligibilityTables (
            TableSchemaRaw NVARCHAR(258) NULL,
            TableNameRaw   NVARCHAR(258) NULL
        );

        INSERT INTO #EligibilityTables (TableSchemaRaw, TableNameRaw)
        SELECT DISTINCT lc.TableSchemaRaw, lc.TableNameRaw FROM #LeafColumnsRaw lc;

        SET @Sql = @Use + N'
        INSERT INTO #ColumnEligibility
            (TableSchemaRaw, TableNameRaw, ColumnName, TypeName, KeyEligible, IncludeEligible, IsLobType, KeyBytes)
        SELECT
            QUOTENAME(s.name), QUOTENAME(o.name), c.name, t.name,
            CASE WHEN t.name IN (''text'', ''ntext'', ''image'', ''xml'') THEN 0
                 WHEN c.max_length = -1                                  THEN 0
                 ELSE 1 END,
            CASE WHEN t.name IN (''text'', ''ntext'', ''image'')          THEN 0
                 ELSE 1 END,
            CASE WHEN t.name IN (''text'', ''ntext'', ''image'', ''xml'') THEN 1
                 WHEN c.max_length = -1                                  THEN 1
                 ELSE 0 END,
            CASE WHEN c.max_length = -1 THEN NULL ELSE c.max_length END
        FROM sys.columns  c
        JOIN sys.types    t ON t.user_type_id = c.user_type_id
        JOIN sys.objects  o ON o.object_id    = c.object_id
        JOIN sys.schemas  s ON s.schema_id    = o.schema_id
        WHERE o.type IN (''U'', ''V'')
          AND EXISTS (SELECT 1 FROM #EligibilityTables et
                      WHERE et.TableSchemaRaw = QUOTENAME(s.name)
                        AND et.TableNameRaw   = QUOTENAME(o.name));'

        EXEC sys.sp_executesql @Sql;

        /*  Computed-column indexability -- Curtis: a legally-indexable computed column belongs in
            the actual recommendation, not a side disclosure; an illegal one gets flagged with why.
            COLUMNPROPERTY('IsIndexable') needs ANSI_NULLS/ANSI_PADDING/ANSI_WARNINGS/ARITHABORT/
            CONCAT_NULL_YIELDS_NULL ON and NUMERIC_ROUNDABORT OFF to answer reliably -- measured
            2026-09-03: a caller missing even one of these can read a genuinely indexable column as
            not indexable. QUOTED_IDENTIFIER/ANSI_NULLS are already pinned at CREATE time above; the
            rest are ordinary session SETs, set here rather than trusted to the caller.           */
        SET ANSI_PADDING ON;
        SET ANSI_WARNINGS ON;
        SET ARITHABORT ON;
        SET CONCAT_NULL_YIELDS_NULL ON;
        SET NUMERIC_ROUNDABORT OFF;

        CREATE TABLE #ComputedColumnEligibility (
            TableSchemaRaw     NVARCHAR(258) NULL,
            TableNameRaw       NVARCHAR(258) NULL,
            ComputedColumnName sysname       NULL,
            TypeName           sysname       NULL,
            IsEligible         INT           NULL,
            Reason             NVARCHAR(300) NULL
        );

        SET @Sql = @Use + N'
        INSERT INTO #ComputedColumnEligibility
            (TableSchemaRaw, TableNameRaw, ComputedColumnName, TypeName, IsEligible, Reason)
        SELECT
            cc.TableSchemaRaw, cc.TableNameRaw, cc.ComputedColumnName, t.name,
            CASE WHEN COLUMNPROPERTY(c.object_id, c.name, ''IsIndexable'') = 1
                      AND NOT ((t.name IN (''text'',''ntext'',''image'',''xml'') OR c.max_length = -1)
                               AND @AllowLobIn = 0)
                 THEN 1 ELSE 0 END,
            CASE WHEN COLUMNPROPERTY(c.object_id, c.name, ''IsIndexable'') = 1
                      AND NOT ((t.name IN (''text'',''ntext'',''image'',''xml'') OR c.max_length = -1)
                               AND @AllowLobIn = 0)
                 THEN NULL
                 WHEN COLUMNPROPERTY(c.object_id, c.name, ''IsDeterministic'') = 0
                 THEN ''computed, not deterministic -- can return a different value for the same inputs, so the engine will not index it''
                 WHEN COLUMNPROPERTY(c.object_id, c.name, ''IsPrecise'') = 0
                 THEN ''computed, not precise -- float/real is involved in its definition, so the engine will not index it''
                 WHEN tbl.uses_ansi_nulls = 0
                 THEN ''computed, table created with ANSI_NULLS OFF -- the engine will not index any computed column on it''
                 WHEN (t.name IN (''text'',''ntext'',''image'',''xml'') OR c.max_length = -1) AND @AllowLobIn = 0
                 THEN ''computed, LOB policy -- result type is '' + t.name + '', excluded by default; set @AllowLobIncludeColumns = 1 to include it anyway''
                 ELSE ''computed, not indexable (engine declined; no more specific reason resolved)''
            END
        FROM (SELECT DISTINCT TableSchemaRaw, TableNameRaw, ComputedColumnName FROM #ComputedColumnSources) cc
        JOIN sys.schemas s   ON QUOTENAME(s.name) = cc.TableSchemaRaw
        JOIN sys.objects o   ON o.schema_id = s.schema_id AND QUOTENAME(o.name) = cc.TableNameRaw
        JOIN sys.tables  tbl ON tbl.object_id = o.object_id
        JOIN sys.columns c   ON c.object_id = o.object_id AND c.name = cc.ComputedColumnName
        JOIN sys.types   t   ON t.user_type_id = c.user_type_id;'

        EXEC sys.sp_executesql @Sql, N'@AllowLobIn BIT', @AllowLobIn = @AllowLobIncludeColumns;

        -- A predicate/Filter comparison against a computed column is sometimes relayed through
        -- an anonymous Exprnnnn alias with no @Table (measured 2026-09-03, Test 23's TotalDue).
        -- This resolves the alias back to the real, indexable-in-spirit computed column it
        -- stands for. Pure XML shredding on already-collected plan XML -- no target access
        -- needed, so this is static, not dynamic, unlike the block above it.
        ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        SELECT
            cm.object_name, cm.query_id, cm.plan_id,
            DV.value('(./ColumnReference/@Column)[1]', 'nvarchar(128)')        AS ExprAlias,
            RealCol.value('@Schema', 'nvarchar(128)')                          AS TableSchemaRaw,
            RealCol.value('@Table', 'nvarchar(128)')                           AS TableNameRaw,
            RealCol.value('@Column', 'nvarchar(128)')                          AS ComputedColumnName
        INTO #ComputedColumnRelayAliases
        FROM #CacheMatch cm
        CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
        CROSS APPLY AP.PlanXml.nodes('//RelOp/*/DefinedValues/DefinedValue[not(ColumnReference/@Table)]') AS D(DV)
        CROSS APPLY DV.nodes('./ScalarOperator/Identifier/ColumnReference[@ComputedColumn="1"][@Table]') AS RC(RealCol)
        WHERE AP.PlanXml IS NOT NULL;

        -- Key columns, pass 2c: see Paramsniffingdiagnostic_v1.sql for the full reasoning.
        ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        INSERT INTO #LeafColumnsRaw (object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, ColumnRole, ColumnName, AccessNodeId)
        SELECT
            cm.object_name, cm.query_id, cm.plan_id,
            rca.TableSchemaRaw, rca.TableNameRaw, 'Key', rca.ComputedColumnName,
            LeafOp.value('@NodeId', 'int')
        FROM #CacheMatch cm
        CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
        CROSS APPLY AP.PlanXml.nodes('//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")]') AS T(LeafOp)
        CROSS APPLY LeafOp.nodes('./*/Predicate//ColumnReference[not(@Table)]') AS SP(ColRef)
        JOIN #ComputedColumnRelayAliases rca
            ON  rca.object_name = cm.object_name AND rca.query_id = cm.query_id AND rca.plan_id = cm.plan_id
            AND rca.ExprAlias = ColRef.value('@Column', 'nvarchar(128)')
        JOIN #ComputedColumnEligibility cce
            ON  cce.TableSchemaRaw = rca.TableSchemaRaw AND cce.TableNameRaw = rca.TableNameRaw
            AND cce.ComputedColumnName = rca.ComputedColumnName AND cce.IsEligible = 1
        WHERE AP.PlanXml IS NOT NULL
          AND LeafOp.exist('(./*/Object/@Table)[1]') = 1
          AND NOT EXISTS (
              SELECT 1 FROM #LookupPairs lp
              WHERE lp.object_name = cm.object_name AND lp.query_id = cm.query_id AND lp.plan_id = cm.plan_id
                AND lp.LookupNodeId = LeafOp.value('@NodeId', 'int')
          );

        -- Key columns, pass 3c: see Paramsniffingdiagnostic_v1.sql for the full reasoning.
        ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        INSERT INTO #LeafColumnsRaw (object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, ColumnRole, ColumnName, AccessNodeId)
        SELECT
            src.object_name, src.query_id, src.plan_id,
            rca.TableSchemaRaw, rca.TableNameRaw, 'Key', rca.ComputedColumnName,
            COALESCE(olm.AccessNodeId, -1)
        FROM (
            SELECT cm.object_name, cm.query_id, cm.plan_id,
                   FiltOp.value('@NodeId', 'int')            AS SourceNodeId,
                   ColRef.value('@Column', 'nvarchar(128)')  AS ExprAlias
            FROM #CacheMatch cm
            CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
            CROSS APPLY AP.PlanXml.nodes('//RelOp[@PhysicalOp="Filter"]') AS F(FiltOp)
            CROSS APPLY FiltOp.nodes('./Filter/Predicate//ColumnReference[not(@Table)]') AS FP(ColRef)
            WHERE AP.PlanXml IS NOT NULL
        ) src
        JOIN #ComputedColumnRelayAliases rca
            ON  rca.object_name = src.object_name AND rca.query_id = src.query_id AND rca.plan_id = src.plan_id
            AND rca.ExprAlias = src.ExprAlias
        JOIN #ComputedColumnEligibility cce
            ON  cce.TableSchemaRaw = rca.TableSchemaRaw AND cce.TableNameRaw = rca.TableNameRaw
            AND cce.ComputedColumnName = rca.ComputedColumnName AND cce.IsEligible = 1
        LEFT JOIN #OperatorLeafMap olm
               ON  olm.object_name = src.object_name AND olm.query_id = src.query_id
               AND olm.plan_id = src.plan_id        AND olm.SourceNodeId = src.SourceNodeId
               AND olm.TableSchemaRaw = rca.TableSchemaRaw AND olm.TableNameRaw = rca.TableNameRaw;

        -- Scope, deliberate: passes 2c/3c only, not pass 1 (a computed column with no existing
        -- index cannot be seeked on) and not pass 4a/4b (untested -- see the script).

        -- 7e. JSON FUNCTION RELAY ALIASES (added 2026-09-04) -- see Paramsniffingdiagnostic_v1.sql
        -- for the full reasoning. A predicate wrapping an ORDINARY column in JSON_VALUE()/
        -- JSON_PATH_EXISTS() can relay through a bare Exprnnnn alias the same way 7d's computed
        -- columns do, but 7d's XPath requires @ComputedColumn="1" and does not match this case.
        -- No separate eligibility table needed -- #ColumnEligibility (Section 8) already
        -- classifies the resolved column correctly (json reports max_length = -1, the same LOB
        -- bucket nvarchar(max)/xml already use) once it is visible in #LeafColumnsRaw.
        ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        SELECT
            cm.object_name, cm.query_id, cm.plan_id,
            DV.value('(./ColumnReference/@Column)[1]', 'nvarchar(128)')        AS ExprAlias,
            RealCol.value('@Schema', 'nvarchar(128)')                          AS TableSchemaRaw,
            RealCol.value('@Table', 'nvarchar(128)')                           AS TableNameRaw,
            RealCol.value('@Column', 'nvarchar(128)')                          AS ColumnName
        INTO #JsonFunctionRelayAliases
        FROM #CacheMatch cm
        CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
        CROSS APPLY AP.PlanXml.nodes('//RelOp/*/DefinedValues/DefinedValue[not(ColumnReference/@Table)]') AS D(DV)
        CROSS APPLY DV.nodes('./ScalarOperator//Intrinsic[@FunctionName="json_value" or @FunctionName="json_path_exists"]/ScalarOperator[1]/Identifier/ColumnReference[@Table][not(@ComputedColumn="1")]') AS RC(RealCol)
        WHERE AP.PlanXml IS NOT NULL;

        -- Key columns, pass 3d: see Paramsniffingdiagnostic_v1.sql for the full reasoning. FILTER
        -- shape, not scan-predicate -- a first read of this relay's surrounding text, without
        -- checking which RelOp owned it, wrongly assumed the 2c shape; a direct per-NodeId dump
        -- (both plan_ids) showed the leaf scan carries no Predicate at all here, and the real
        -- comparison lives on a separate Filter RelOp above it, matching 3c not 2c. See the
        -- script's own note in this section, and TestCases_v1.sql "TEST 28 FIX", for the full
        -- account of catching this mid-implementation.
        ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        INSERT INTO #LeafColumnsRaw (object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, ColumnRole, ColumnName, AccessNodeId)
        SELECT
            src.object_name, src.query_id, src.plan_id,
            jra.TableSchemaRaw, jra.TableNameRaw, 'Key', jra.ColumnName,
            COALESCE(olm.AccessNodeId, -1)
        FROM (
            SELECT cm.object_name, cm.query_id, cm.plan_id,
                   FiltOp.value('@NodeId', 'int')            AS SourceNodeId,
                   ColRef.value('@Column', 'nvarchar(128)')  AS ExprAlias
            FROM #CacheMatch cm
            CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
            CROSS APPLY AP.PlanXml.nodes('//RelOp[@PhysicalOp="Filter"]') AS F(FiltOp)
            CROSS APPLY FiltOp.nodes('./Filter/Predicate//ColumnReference[not(@Table)]') AS FP(ColRef)
            WHERE AP.PlanXml IS NOT NULL
        ) src
        JOIN #JsonFunctionRelayAliases jra
            ON  jra.object_name = src.object_name AND jra.query_id = src.query_id AND jra.plan_id = src.plan_id
            AND jra.ExprAlias = src.ExprAlias
        LEFT JOIN #OperatorLeafMap olm
               ON  olm.object_name = src.object_name AND olm.query_id = src.query_id
               AND olm.plan_id = src.plan_id        AND olm.SourceNodeId = src.SourceNodeId
               AND olm.TableSchemaRaw = jra.TableSchemaRaw AND olm.TableNameRaw = jra.TableNameRaw;

        -- 7f. JSON TRAP COLUMNS -- see Paramsniffingdiagnostic_v1.sql for the full reasoning.
        -- Feeds isJSON's TextTrap state: a JSON_VALUE/JSON_PATH_EXISTS predicate, direct or
        -- relayed, that reached a narrow (non-LOB) text column. Union of the direct shape
        -- (Test 27 Statement 2) and the already-resolved relay (#JsonFunctionRelayAliases,
        -- Test 28's shape) -- the eligibility gate (LOB vs. not) is applied downstream, where
        -- isJSON itself is computed, not here.
        ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        SELECT DISTINCT
            cm.object_name, cm.query_id, cm.plan_id,
            RealCol.value('@Schema', 'nvarchar(128)') AS TableSchemaRaw,
            RealCol.value('@Table', 'nvarchar(128)')  AS TableNameRaw,
            RealCol.value('@Column', 'nvarchar(128)') AS ColumnName
        INTO #JsonTrapColumns
        FROM #CacheMatch cm
        CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
        CROSS APPLY AP.PlanXml.nodes('.//Predicate//Intrinsic[@FunctionName="json_value" or @FunctionName="json_path_exists"]/ScalarOperator[1]/Identifier/ColumnReference[@Table][not(@ComputedColumn="1")]') AS RC(RealCol)
        WHERE AP.PlanXml IS NOT NULL

        UNION

        SELECT object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, ColumnName
        FROM #JsonFunctionRelayAliases;

    ;WITH OrderPick AS (

        SELECT object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, AccessNodeId,
               QUOTENAME(ColumnName) AS QuotedColumn,
               SortNodeId, SortOrdinal, SortAsc,
               ROW_NUMBER() OVER (PARTITION BY object_name, query_id, plan_id, TableSchemaRaw,
                                               TableNameRaw, AccessNodeId, QUOTENAME(ColumnName)
                                  ORDER BY SortNodeId, SortOrdinal) AS SortPick
        FROM #LeafColumnsRaw
        WHERE ColumnRole = 'Order'
          AND ColumnName IS NOT NULL
          AND SortNodeId IS NOT NULL
    ),
    RoleAgg AS (

        SELECT lc.object_name, lc.query_id, lc.plan_id, lc.TableSchemaRaw, lc.TableNameRaw,
               lc.AccessNodeId,
               QUOTENAME(lc.ColumnName) AS QuotedColumn,
               MIN(CASE lc.ColumnRole WHEN 'Key'   THEN 1
                                      WHEN 'Join'  THEN 2
                                      WHEN 'Group' THEN 3
                                      WHEN 'Order' THEN 4 END) AS RolePriority,
               MAX(ce.KeyBytes)                                AS KeyBytes
        FROM #LeafColumnsRaw lc
        LEFT JOIN #ColumnEligibility ce
               ON  ce.TableSchemaRaw = lc.TableSchemaRaw
               AND ce.TableNameRaw   = lc.TableNameRaw
               AND ce.ColumnName     = lc.ColumnName
        WHERE lc.ColumnRole IN ('Key', 'Join', 'Group', 'Order')
          AND lc.ColumnName IS NOT NULL
          AND ISNULL(ce.KeyEligible, 1) = 1
        GROUP BY lc.object_name, lc.query_id, lc.plan_id, lc.TableSchemaRaw, lc.TableNameRaw,
                 lc.AccessNodeId, QUOTENAME(lc.ColumnName)
    ),
    RoleRanked AS (
        SELECT a.object_name, a.query_id, a.plan_id, a.TableSchemaRaw, a.TableNameRaw, a.AccessNodeId,
               a.QuotedColumn, a.RolePriority, a.KeyBytes,
               op.SortNodeId, op.SortOrdinal, op.SortAsc,

               CASE WHEN op.SortAsc = 0 THEN ' DESC' ELSE '' END AS DirectionSuffix
        FROM RoleAgg a
        LEFT JOIN OrderPick op
               ON  op.SortPick       = 1
               AND op.object_name    = a.object_name
               AND op.query_id       = a.query_id
               AND op.plan_id        = a.plan_id
               AND op.TableSchemaRaw = a.TableSchemaRaw
               AND op.TableNameRaw   = a.TableNameRaw
               AND op.AccessNodeId   = a.AccessNodeId
               AND op.QuotedColumn   = a.QuotedColumn
    ),
    RoleGroups AS (

        SELECT DISTINCT object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, AccessNodeId
        FROM #LeafColumnsRaw
        WHERE ColumnRole IN ('Key', 'Join', 'Group', 'Order')
          AND ColumnName IS NOT NULL
    )
    SELECT g.object_name, g.query_id, g.plan_id, g.TableSchemaRaw, g.TableNameRaw, g.AccessNodeId,
           STUFF((SELECT ',' + r.QuotedColumn + r.DirectionSuffix
                  FROM RoleRanked r
                  WHERE r.object_name = g.object_name AND r.query_id = g.query_id AND r.plan_id = g.plan_id
                    AND r.TableSchemaRaw = g.TableSchemaRaw AND r.TableNameRaw = g.TableNameRaw
                    AND r.AccessNodeId = g.AccessNodeId
                  ORDER BY r.RolePriority, ISNULL(r.SortNodeId, 0), ISNULL(r.SortOrdinal, 0), r.QuotedColumn
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '')          AS KeyColumns,

           STUFF((SELECT ',' + r.QuotedColumn
                  FROM RoleRanked r
                  WHERE r.object_name = g.object_name AND r.query_id = g.query_id AND r.plan_id = g.plan_id
                    AND r.TableSchemaRaw = g.TableSchemaRaw AND r.TableNameRaw = g.TableNameRaw
                    AND r.AccessNodeId = g.AccessNodeId
                    AND r.RolePriority = 1
                  ORDER BY r.QuotedColumn
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '')          AS PredicateColumns,
           STUFF((SELECT ',' + r.QuotedColumn
                  FROM RoleRanked r
                  WHERE r.object_name = g.object_name AND r.query_id = g.query_id AND r.plan_id = g.plan_id
                    AND r.TableSchemaRaw = g.TableSchemaRaw AND r.TableNameRaw = g.TableNameRaw
                    AND r.AccessNodeId = g.AccessNodeId
                    AND r.RolePriority = 2
                  ORDER BY r.QuotedColumn
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '')          AS JoinColumns,
           STUFF((SELECT ',' + r.QuotedColumn
                  FROM RoleRanked r
                  WHERE r.object_name = g.object_name AND r.query_id = g.query_id AND r.plan_id = g.plan_id
                    AND r.TableSchemaRaw = g.TableSchemaRaw AND r.TableNameRaw = g.TableNameRaw
                    AND r.AccessNodeId = g.AccessNodeId
                    AND r.RolePriority = 3
                  ORDER BY r.QuotedColumn
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '')          AS GroupByColumns,

           STUFF((SELECT ',' + r.QuotedColumn + r.DirectionSuffix
                  FROM RoleRanked r
                  WHERE r.object_name = g.object_name AND r.query_id = g.query_id AND r.plan_id = g.plan_id
                    AND r.TableSchemaRaw = g.TableSchemaRaw AND r.TableNameRaw = g.TableNameRaw
                    AND r.AccessNodeId = g.AccessNodeId
                    AND r.RolePriority = 4
                  ORDER BY ISNULL(r.SortNodeId, 0), ISNULL(r.SortOrdinal, 0), r.QuotedColumn
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '')          AS OrderByColumns,

           (SELECT COUNT(*)
              FROM RoleRanked r
             WHERE r.object_name = g.object_name AND r.query_id = g.query_id AND r.plan_id = g.plan_id
               AND r.TableSchemaRaw = g.TableSchemaRaw AND r.TableNameRaw = g.TableNameRaw
               AND r.AccessNodeId = g.AccessNodeId) AS KeyColumnCount,
           (SELECT CASE WHEN COUNT(*) <> COUNT(r.KeyBytes) THEN NULL ELSE SUM(r.KeyBytes) END
              FROM RoleRanked r
             WHERE r.object_name = g.object_name AND r.query_id = g.query_id AND r.plan_id = g.plan_id
               AND r.TableSchemaRaw = g.TableSchemaRaw AND r.TableNameRaw = g.TableNameRaw
               AND r.AccessNodeId = g.AccessNodeId) AS KeyByteSize,

           STUFF((SELECT ',' + QUOTENAME(x.ColumnName) + ' (' + x.TypeName + ')'
                  FROM (SELECT DISTINCT lc2.ColumnName, ce2.TypeName
                        FROM #LeafColumnsRaw lc2
                        JOIN #ColumnEligibility ce2
                          ON  ce2.TableSchemaRaw = lc2.TableSchemaRaw
                          AND ce2.TableNameRaw   = lc2.TableNameRaw
                          AND ce2.ColumnName     = lc2.ColumnName
                        WHERE lc2.object_name = g.object_name AND lc2.query_id = g.query_id
                          AND lc2.plan_id = g.plan_id
                          AND lc2.TableSchemaRaw = g.TableSchemaRaw AND lc2.TableNameRaw = g.TableNameRaw
                          AND lc2.AccessNodeId = g.AccessNodeId
                          AND lc2.ColumnRole IN ('Key', 'Join', 'Group', 'Order')
                          AND ce2.KeyEligible = 0) x
                  ORDER BY x.ColumnName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '')          AS ExcludedKeyColumns
    INTO #TableKeyColumns
    FROM RoleGroups g;

    ;WITH DedupInclude AS (
        SELECT DISTINCT lc.object_name, lc.query_id, lc.plan_id, lc.TableSchemaRaw, lc.TableNameRaw,
               lc.AccessNodeId,
               QUOTENAME(lc.ColumnName) AS QuotedColumn
        FROM #LeafColumnsRaw lc
        WHERE lc.ColumnRole = 'Include' AND lc.ColumnName IS NOT NULL

          AND NOT EXISTS (
              SELECT 1 FROM #LeafColumnsRaw keyrow
              WHERE keyrow.ColumnRole IN ('Key', 'Join', 'Group', 'Order')
                AND keyrow.object_name = lc.object_name AND keyrow.query_id = lc.query_id AND keyrow.plan_id = lc.plan_id
                AND keyrow.TableSchemaRaw = lc.TableSchemaRaw AND keyrow.TableNameRaw = lc.TableNameRaw

                AND keyrow.AccessNodeId = lc.AccessNodeId
                AND keyrow.ColumnName = lc.ColumnName
          )
          AND NOT EXISTS (
              SELECT 1 FROM #ClusteringKeyColumns ck
              WHERE ck.TableSchemaRaw = lc.TableSchemaRaw AND ck.TableNameRaw = lc.TableNameRaw
                AND ck.ColumnName = lc.ColumnName
          )

          AND NOT EXISTS (
              SELECT 1 FROM #ColumnEligibility ce
              WHERE ce.TableSchemaRaw = lc.TableSchemaRaw AND ce.TableNameRaw = lc.TableNameRaw
                AND ce.ColumnName = lc.ColumnName
                AND (ce.IncludeEligible = 0
                     OR (ce.IsLobType = 1 AND @AllowLobIncludeColumns = 0))
          )
    )
    ,
    IncludeGroups AS (
        SELECT DISTINCT object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, AccessNodeId
        FROM DedupInclude
    )

    SELECT g.object_name, g.query_id, g.plan_id, g.TableSchemaRaw, g.TableNameRaw, g.AccessNodeId,
           -- Real include columns UNIONed with legally-indexable computed columns (7c below) --
           -- see Paramsniffingdiagnostic_v1.sql for the full reasoning. Applies to every access
           -- path of the table; guarded against double-listing a column that is also a key.
           STUFF((SELECT ',' + x.QuotedColumn
                  FROM (
                      SELECT d.QuotedColumn
                      FROM DedupInclude d
                      WHERE d.object_name = g.object_name AND d.query_id = g.query_id AND d.plan_id = g.plan_id
                        AND d.TableSchemaRaw = g.TableSchemaRaw AND d.TableNameRaw = g.TableNameRaw
                        AND d.AccessNodeId = g.AccessNodeId
                      UNION
                      SELECT QUOTENAME(cce.ComputedColumnName)
                      FROM #ComputedColumnEligibility cce
                      WHERE cce.TableSchemaRaw = g.TableSchemaRaw AND cce.TableNameRaw = g.TableNameRaw
                        AND cce.IsEligible = 1
                        AND NOT EXISTS (SELECT 1 FROM #TableKeyColumns tkc
                                         WHERE tkc.TableSchemaRaw = g.TableSchemaRaw AND tkc.TableNameRaw = g.TableNameRaw
                                           AND tkc.AccessNodeId = g.AccessNodeId
                                           AND CHARINDEX(QUOTENAME(cce.ComputedColumnName), ISNULL(tkc.KeyColumns, '')) > 0)
                  ) x
                  ORDER BY x.QuotedColumn
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '') AS IncludeColumns,

           STUFF((SELECT ',' + QUOTENAME(x.ColumnName) + ' (' + x.TypeName + ', ' + x.Reason + ')'
                  FROM (SELECT DISTINCT lc3.ColumnName, ce3.TypeName,
                               CASE WHEN ce3.IncludeEligible = 0 THEN 'engine' ELSE 'LOB policy' END AS Reason
                        FROM #LeafColumnsRaw lc3
                        JOIN #ColumnEligibility ce3
                          ON  ce3.TableSchemaRaw = lc3.TableSchemaRaw
                          AND ce3.TableNameRaw   = lc3.TableNameRaw
                          AND ce3.ColumnName     = lc3.ColumnName
                        WHERE lc3.object_name = g.object_name AND lc3.query_id = g.query_id
                          AND lc3.plan_id = g.plan_id
                          AND lc3.TableSchemaRaw = g.TableSchemaRaw AND lc3.TableNameRaw = g.TableNameRaw
                          AND lc3.AccessNodeId = g.AccessNodeId
                          AND lc3.ColumnRole = 'Include'
                          AND (ce3.IncludeEligible = 0
                               OR (ce3.IsLobType = 1 AND @AllowLobIncludeColumns = 0))
                        UNION
                        SELECT cce2.ComputedColumnName, cce2.TypeName, cce2.Reason
                        FROM #ComputedColumnEligibility cce2
                        WHERE cce2.TableSchemaRaw = g.TableSchemaRaw AND cce2.TableNameRaw = g.TableNameRaw
                          AND cce2.IsEligible = 0) x
                  ORDER BY x.ColumnName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '') AS ExcludedIncludeColumns,

           -- Informational only, never a gate: which names in IncludeColumns above are computed.
           STUFF((SELECT ',' + QUOTENAME(cce3.ComputedColumnName)
                  FROM #ComputedColumnEligibility cce3
                  WHERE cce3.TableSchemaRaw = g.TableSchemaRaw AND cce3.TableNameRaw = g.TableNameRaw
                    AND cce3.IsEligible = 1
                    AND NOT EXISTS (SELECT 1 FROM #TableKeyColumns tkc2
                                     WHERE tkc2.TableSchemaRaw = g.TableSchemaRaw AND tkc2.TableNameRaw = g.TableNameRaw
                                       AND tkc2.AccessNodeId = g.AccessNodeId
                                       AND CHARINDEX(QUOTENAME(cce3.ComputedColumnName), ISNULL(tkc2.KeyColumns, '')) > 0)
                  ORDER BY cce3.ComputedColumnName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '') AS ComputedIncludeColumns
    INTO #TableIncludeColumns
    FROM IncludeGroups g;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT
        cm.object_name, cm.query_id, cm.plan_id,
        SpillOp.value('@PhysicalOp', 'nvarchar(50)')                                    AS SpillingOperator,
        SpillOp.value('(./Warnings/SpillToTempDb/@SpillLevel)[1]', 'int')               AS SpillLevel,

        CAST(CASE WHEN SpillOp.exist('./Warnings/SpillToTempDb') = 1 THEN 'SpillToTempDb'
                  ELSE 'SpillOccurred' END AS VARCHAR(20))                              AS SpillDetectionSource,
        Attributed.AttributedSchema,
        Attributed.AttributedTable,
        Attributed.AttributedActualRows,

        CAST(CASE WHEN TieInfo.LeavesSharingTopRowCount > 1 THEN 'Yes' ELSE 'No' END AS VARCHAR(3))
                                                                                        AS SpillAttributionTied
    INTO #SpillEvents
    FROM #CacheMatch cm
    CROSS APPLY (SELECT CASE WHEN cm.query_plan_hash = cm.CachePlanHash AND cm.CacheActualPlanXML IS NOT NULL THEN cm.CacheActualPlanXML ELSE cm.EstimatedPlanXML END AS PlanXml) AP
    CROSS APPLY AP.PlanXml.nodes('//RelOp[Warnings/SpillToTempDb or Warnings/SpillOccurred]') AS S(SpillOp)

    OUTER APPLY (
        SELECT TOP (1)
            LeafOp2.value('(./*/Object/@Schema)[1]', 'nvarchar(128)') AS AttributedSchema,
            LeafOp2.value('(./*/Object/@Table)[1]', 'nvarchar(128)')  AS AttributedTable,
            LeafOp2.value('sum(./RunTimeInformation/RunTimeCountersPerThread/@ActualRows)', 'float') AS AttributedActualRows
        FROM SpillOp.nodes('.//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")]') AS T2(LeafOp2)
        WHERE LeafOp2.exist('(./*/Object/@Table)[1]') = 1
        ORDER BY
            LeafOp2.value('sum(./RunTimeInformation/RunTimeCountersPerThread/@ActualRows)', 'float') DESC,
            LeafOp2.value('@EstimateIO', 'float') DESC,
            LeafOp2.value('(./*/Object/@Schema)[1]', 'nvarchar(128)') ASC,
            LeafOp2.value('(./*/Object/@Table)[1]', 'nvarchar(128)') ASC
    ) Attributed
    OUTER APPLY (

        SELECT COUNT(*) AS LeavesSharingTopRowCount
        FROM SpillOp.nodes('.//RelOp[contains(@PhysicalOp,"Scan") or contains(@PhysicalOp,"Seek")]') AS T3(LeafOp3)
        WHERE LeafOp3.exist('(./*/Object/@Table)[1]') = 1
          AND LeafOp3.value('sum(./RunTimeInformation/RunTimeCountersPerThread/@ActualRows)', 'float')
              = Attributed.AttributedActualRows
    ) TieInfo
    WHERE AP.PlanXml IS NOT NULL;

    SELECT
        object_name, query_id, plan_id,
        AttributedSchema AS TableSchemaRaw, AttributedTable AS TableNameRaw,
        COUNT(*)                     AS SpillEventCount,
        MAX(ISNULL(SpillLevel, 0))   AS WorstSpillLevel,

        MIN(SpillDetectionSource)    AS SpillDetectionSource,

        MAX(SpillAttributionTied)    AS SpillAttributionTied
    INTO #SpillRollup
    FROM #SpillEvents
    WHERE AttributedTable IS NOT NULL
    GROUP BY object_name, query_id, plan_id, AttributedSchema, AttributedTable;

    SELECT object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, AccessNodeId
    INTO #AccessSet
    FROM (
        SELECT object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, AccessNodeId
          FROM #LeafAttribution
        UNION
        SELECT object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, AccessNodeId
          FROM #TableKeyColumns
        UNION
        SELECT object_name, query_id, plan_id, TableSchemaRaw, TableNameRaw, AccessNodeId
          FROM #TableIncludeColumns
    ) u;

    SELECT
        tr.object_name, tr.query_id, tr.plan_id, tr.TableSchemaRaw, tr.TableNameRaw,
        tr.TotalEstimateIO, tr.TotalActualIO, tr.WorstSkewRatio, tr.AnyActualData, tr.AnyActualReads, tr.LeafTouchCount,
        sp.SpillEventCount, sp.WorstSpillLevel, sp.SpillDetectionSource, sp.SpillAttributionTied,
        kc.KeyColumns, ic.IncludeColumns,

        kc.KeyColumnCount, kc.KeyByteSize, kc.ExcludedKeyColumns, ic.ExcludedIncludeColumns,

        kc.PredicateColumns, kc.JoinColumns, kc.GroupByColumns, kc.OrderByColumns,
        ts.EstimatedTableSizeMB,
        CASE WHEN ts.EstimatedTableSizeMB > 128 THEN 'PAGE' WHEN ts.EstimatedTableSizeMB IS NOT NULL THEN 'ROW' ELSE NULL END AS BaseIndexCompression,

        LEFT('IX_' + REPLACE(tr.object_name, '.', '_') + '_'
                  + REPLACE(REPLACE(REPLACE(ISNULL(tr.TableNameRaw, ''), '.', '_'), '[', ''), ']', ''), 103)
          + '_Recommended_'
          + LEFT(CONVERT(VARCHAR(64),
                  HASHBYTES('SHA2_256',
                      CONVERT(NVARCHAR(4000),
                            ISNULL(tr.TableSchemaRaw, '') + N'|' + ISNULL(tr.TableNameRaw, '')
                          + N'|' + ISNULL(kc.KeyColumns, '') + N'|' + ISNULL(ic.IncludeColumns, ''))), 2), 8)
          AS CandidateIndexName,

        DENSE_RANK() OVER (
            PARTITION BY tr.object_name, tr.query_id, tr.plan_id
            ORDER BY
                CASE @IndexRecommendationMode
                    WHEN 'B' THEN COALESCE(NULLIF(tr.TotalActualIO, 0), tr.TotalEstimateIO, 0)
                    WHEN 'C' THEN COALESCE(tr.WorstSkewRatio, 0)
                    WHEN 'D' THEN COALESCE(sp.WorstSpillLevel, 0) * 1000000 + COALESCE(sp.SpillEventCount, 0)
                    ELSE          COALESCE(NULLIF(tr.TotalActualIO, 0), tr.TotalEstimateIO, 0)
                END DESC
        ) AS TableRank,

        DENSE_RANK() OVER (
            PARTITION BY tr.object_name, tr.query_id, tr.plan_id
            ORDER BY COALESCE(NULLIF(tr.TotalActualIO, 0), tr.TotalEstimateIO, 0) DESC
        ) AS TableRankB,
        DENSE_RANK() OVER (
            PARTITION BY tr.object_name, tr.query_id, tr.plan_id
            ORDER BY COALESCE(tr.WorstSkewRatio, 0) DESC
        ) AS TableRankC,
        DENSE_RANK() OVER (
            PARTITION BY tr.object_name, tr.query_id, tr.plan_id
            ORDER BY (COALESCE(sp.WorstSpillLevel, 0) * 1000000 + COALESCE(sp.SpillEventCount, 0)) DESC
        ) AS TableRankD,

        COALESCE(NULLIF(tr.TotalActualIO, 0), tr.TotalEstimateIO, 0)                          AS ModeB_RankedIO,
        COALESCE(tr.WorstSkewRatio, 0)                                                        AS ModeC_RankedSkew,
        COALESCE(sp.WorstSpillLevel, 0) * 1000000 + COALESCE(sp.SpillEventCount, 0)           AS ModeD_RankedSpill,

        acc.AccessNodeId,
        la.PhysicalOp                                                                         AS AccessPhysicalOp,
        la.EstimateIO                                                                         AS AccessEstimateIO,
        la.ActualLogicalReadsSum                                                              AS AccessActualIO,
        la.HasActualReads                                                                     AS AccessHasActualReads,
        la.EstimateRows                                                                       AS AccessEstimateRows,
        la.ActualRowsSum                                                                      AS AccessActualRows,
        CASE WHEN acc.AccessNodeId = -1
             THEN 'UNATTRIBUTED -- no leaf access was found beneath the operator these columns came from'
             ELSE 'Access node ' + CAST(acc.AccessNodeId AS VARCHAR(10))
                  + ISNULL(' (' + la.PhysicalOp + ')', '') END                                AS KeyScope,

        (SELECT COUNT(DISTINCT olm.AccessNodeId) FROM #OperatorLeafMap olm
          WHERE olm.object_name = acc.object_name AND olm.query_id = acc.query_id
            AND olm.plan_id = acc.plan_id
            AND olm.TableSchemaRaw = acc.TableSchemaRaw AND olm.TableNameRaw = acc.TableNameRaw)
                                                                                              AS AccessPathsOnThisTable,
        -- Which of ic.IncludeColumns above are computed -- see 7c. Pure passthrough, informational.
        ic.ComputedIncludeColumns                                                            AS ComputedIncludeColumns,
        -- Section 8c in the script.
        ISNULL(xc.isXML, 0)                                                                  AS isXML,
        -- Sections 7f/8d in the script -- see there for the full reasoning.
        CASE
            WHEN EXISTS (
                SELECT 1 FROM #JsonTrapColumns jtc
                JOIN #ColumnEligibility ce
                  ON  ce.TableSchemaRaw = jtc.TableSchemaRaw AND ce.TableNameRaw = jtc.TableNameRaw
                  AND ce.ColumnName     = jtc.ColumnName
                WHERE jtc.object_name   = tr.object_name AND jtc.query_id = tr.query_id AND jtc.plan_id = tr.plan_id
                  AND jtc.TableSchemaRaw = tr.TableSchemaRaw AND jtc.TableNameRaw = tr.TableNameRaw
                  AND ce.KeyEligible = 1
            ) THEN N'TextTrap'
            WHEN jn.NativeJsonState IS NOT NULL THEN jn.NativeJsonState
            ELSE NULL
        END                                                                                 AS isJSON
    INTO #TableCandidates

    FROM #AccessSet acc
    JOIN #TableRollup tr
        ON  tr.object_name = acc.object_name AND tr.query_id = acc.query_id AND tr.plan_id = acc.plan_id
        AND tr.TableSchemaRaw = acc.TableSchemaRaw AND tr.TableNameRaw = acc.TableNameRaw
    LEFT JOIN #SpillRollup sp
        ON  sp.object_name = tr.object_name AND sp.query_id = tr.query_id AND sp.plan_id = tr.plan_id
        AND sp.TableSchemaRaw = tr.TableSchemaRaw AND sp.TableNameRaw = tr.TableNameRaw
    LEFT JOIN #TableKeyColumns kc
        ON  kc.object_name = tr.object_name AND kc.query_id = tr.query_id AND kc.plan_id = tr.plan_id
        AND kc.TableSchemaRaw = tr.TableSchemaRaw AND kc.TableNameRaw = tr.TableNameRaw
        AND kc.AccessNodeId = acc.AccessNodeId
    LEFT JOIN #TableIncludeColumns ic
        ON  ic.object_name = tr.object_name AND ic.query_id = tr.query_id AND ic.plan_id = tr.plan_id
        AND ic.TableSchemaRaw = tr.TableSchemaRaw AND ic.TableNameRaw = tr.TableNameRaw
        AND ic.AccessNodeId = acc.AccessNodeId
    LEFT JOIN #LeafAttribution la
        ON  la.object_name = acc.object_name AND la.query_id = acc.query_id AND la.plan_id = acc.plan_id
        AND la.TableSchemaRaw = acc.TableSchemaRaw AND la.TableNameRaw = acc.TableNameRaw
        AND la.AccessNodeId = acc.AccessNodeId
    LEFT JOIN #TableSizeLookup ts
        ON  ts.TableSchemaRaw = tr.TableSchemaRaw AND ts.TableNameRaw = tr.TableNameRaw
    LEFT JOIN #XmlColumnCheck xc
        ON  xc.TableSchemaRaw = tr.TableSchemaRaw AND xc.TableNameRaw = tr.TableNameRaw
    LEFT JOIN #JsonNativeColumnCheck jn
        ON  jn.TableSchemaRaw = tr.TableSchemaRaw AND jn.TableNameRaw = tr.TableNameRaw;

    /*----------------------------------------------------------------------------------------
      STATISTICS FRESHNESS (2026-09-14) -- a third trip into the target, because the candidate
      tables are only known now. Same query as the script's Section 9c. COLLATE DATABASE_DEFAULT:
      the candidate names are in tempdb, the catalog names in the target.
    ----------------------------------------------------------------------------------------*/
    CREATE TABLE #StatsFreshness (
        TableSchemaRaw      NVARCHAR(258)  NULL,
        TableNameRaw        NVARCHAR(258)  NULL,
        StatsName           NVARCHAR(128)  NULL,
        LeadingColumn       NVARCHAR(128)  NULL,
        IsIndexStatistics   BIT            NULL,
        NoRecompute         BIT            NULL,
        LastUpdated         DATETIME2(7)   NULL,
        RowsInTable         BIGINT         NULL,
        RowsSampled         BIGINT         NULL,
        ModificationCounter BIGINT         NULL
    );

    SET @Sql = @Use + N'
    INSERT INTO #StatsFreshness
        (TableSchemaRaw, TableNameRaw, StatsName, LeadingColumn, IsIndexStatistics, NoRecompute,
         LastUpdated, RowsInTable, RowsSampled, ModificationCounter)
    SELECT
        tc.TableSchemaRaw,
        tc.TableNameRaw,
        CONVERT(NVARCHAR(128), s.name),
        CONVERT(NVARCHAR(128), c.name),
        CONVERT(BIT, CASE WHEN s.auto_created = 0 AND s.user_created = 0 THEN 1 ELSE 0 END),
        s.no_recompute,
        sp.last_updated,
        sp.rows,
        sp.rows_sampled,
        sp.modification_counter
    FROM (SELECT DISTINCT TableSchemaRaw, TableNameRaw
          FROM #TableCandidates
          WHERE TableNameRaw IS NOT NULL) tc
    JOIN sys.objects o
        ON  QUOTENAME(SCHEMA_NAME(o.schema_id)) COLLATE DATABASE_DEFAULT = tc.TableSchemaRaw COLLATE DATABASE_DEFAULT
        AND QUOTENAME(o.name)                   COLLATE DATABASE_DEFAULT = tc.TableNameRaw   COLLATE DATABASE_DEFAULT
    JOIN sys.stats s          ON s.object_id = o.object_id
    JOIN sys.stats_columns sc ON sc.object_id = s.object_id AND sc.stats_id = s.stats_id AND sc.stats_column_id = 1
    JOIN sys.columns c        ON c.object_id = sc.object_id AND c.column_id = sc.column_id
    OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp;';

    EXEC sys.sp_executesql @Sql;

    SELECT
        cm.*,
        pa.PlanCount, pa.WorstPlanAvgIO, pa.BestPlanAvgIO,
        bp.BestPlanID,
        wr.LockWaitMs, wr.IOWaitMs, wr.TotalWaitMs,
        CASE WHEN EXISTS (SELECT 1 FROM #SpillEvents se WHERE se.query_id = cm.query_id AND se.plan_id = cm.plan_id)
             THEN 1 ELSE 0 END AS HasAnySpill,
        (
            (CASE WHEN pa.PlanCount > 1 THEN 25 ELSE 0 END) +
            (CASE WHEN cm.CachePlanHash IS NOT NULL AND cm.CachePlanHash <> cm.query_plan_hash THEN 15 ELSE 0 END) +

            (CASE WHEN cm.CacheActualMemoryGrant IS NULL OR cm.EstimatedMemoryGrant IS NULL THEN 0
                  WHEN cm.EstimatedMemoryGrant = 0 AND cm.CacheActualMemoryGrant = 0 THEN 0
                  WHEN cm.EstimatedMemoryGrant = 0 OR  cm.CacheActualMemoryGrant = 0 THEN 15
                  WHEN ABS(cm.CacheActualMemoryGrant - cm.EstimatedMemoryGrant) > (cm.EstimatedMemoryGrant * @MemoryGrantVarianceThreshold)
                  THEN 15 ELSE 0 END) +
            (CASE WHEN cm.CacheActualParallelismFlag IS NOT NULL AND cm.EstimatedParallelismFlag IS NOT NULL
                       AND cm.CacheActualParallelismFlag <> cm.EstimatedParallelismFlag
                  THEN 10 ELSE 0 END) +

            (CASE WHEN (CASE WHEN cm.EstimatedRows > 0 AND cm.CacheActualRows > 0
                             THEN CASE WHEN cm.CacheActualRows >= cm.EstimatedRows THEN cm.CacheActualRows / cm.EstimatedRows
                                       ELSE cm.EstimatedRows / cm.CacheActualRows END
                        END) > @CardinalitySkewThreshold
                  THEN 15 ELSE 0 END) +
            (CASE WHEN EXISTS (SELECT 1 FROM #SpillEvents se WHERE se.query_id = cm.query_id AND se.plan_id = cm.plan_id)
                  THEN 10 ELSE 0 END) +

            (CASE WHEN (CASE WHEN pa.BestPlanAvgIO > 0 THEN pa.WorstPlanAvgIO / pa.BestPlanAvgIO END) > @IOVarianceScoreThreshold
                  THEN 10 ELSE 0 END)
        ) AS SniffingSeverityScore,
        CASE
            WHEN cm.AvgDurationMs > 0 AND cm.AvgCpuTimeMs IS NOT NULL
                 AND (cm.AvgDurationMs - cm.AvgCpuTimeMs) > (cm.AvgDurationMs * 0.5)
            THEN
                CASE WHEN ISNULL(wr.LockWaitMs, 0) >= ISNULL(wr.IOWaitMs, 0) AND ISNULL(wr.LockWaitMs, 0) > 0 THEN 'Lock'
                     WHEN ISNULL(wr.IOWaitMs, 0) > ISNULL(wr.LockWaitMs, 0) AND ISNULL(wr.IOWaitMs, 0) > 0 THEN 'IO'
                     WHEN ISNULL(wr.TotalWaitMs, 0) > 0 THEN 'Other'
                     ELSE 'Unknown (no wait-stats coverage for this window)'
                END
            ELSE NULL
        END AS HighDurationLowCpu_DominantWaitCategory
    INTO #Scored
    FROM #CacheMatch cm
    JOIN #PlanAgg pa       ON pa.query_id = cm.query_id
    LEFT JOIN #BestPlanLookup bp ON bp.query_id = cm.query_id
    LEFT JOIN #WaitRollup wr ON wr.plan_id = cm.plan_id;

    ;WITH StabilityFlags AS (
        SELECT
            s.*,

            CASE WHEN s.PlanCount > 1 THEN 'Unstable' ELSE 'Stable' END AS PlanStability,

            CASE WHEN s.CachePlanHash IS NULL                                    THEN 'Unavailable'
                 WHEN s.CachePlanHash <> s.query_plan_hash                       THEN 'Unstable'
                 ELSE 'Stable' END                                               AS PlanShapeStability,

            CASE WHEN s.CacheActualMemoryGrant IS NULL OR s.EstimatedMemoryGrant IS NULL
                                                                                 THEN 'Unavailable'
                 WHEN s.EstimatedMemoryGrant = 0 AND s.CacheActualMemoryGrant = 0 THEN 'N/A'
                 WHEN s.EstimatedMemoryGrant = 0 OR  s.CacheActualMemoryGrant = 0 THEN 'Unstable'
                 WHEN ABS(s.CacheActualMemoryGrant - s.EstimatedMemoryGrant) > (s.EstimatedMemoryGrant * @MemoryGrantVarianceThreshold)
                                                                                 THEN 'Unstable'
                 ELSE 'Stable' END                                               AS MemoryGrantStability,

            CASE WHEN s.CacheActualParallelismFlag IS NULL OR s.EstimatedParallelismFlag IS NULL
                                                                                 THEN 'Unavailable'
                 WHEN s.CacheActualParallelismFlag <> s.EstimatedParallelismFlag THEN 'Unstable'
                 ELSE 'Stable' END                                               AS ParallelismStability,

            CASE WHEN s.CacheActualRows IS NULL OR s.EstimatedRows IS NULL       THEN 'Unavailable'
                 WHEN s.EstimatedRows <= 0 OR s.CacheActualRows <= 0             THEN 'N/A'
                 WHEN (CASE WHEN s.CacheActualRows >= s.EstimatedRows
                            THEN s.CacheActualRows / s.EstimatedRows
                            ELSE s.EstimatedRows / s.CacheActualRows END) > @CardinalitySkewThreshold
                                                                                 THEN 'Unstable'
                 ELSE 'Stable' END                                               AS OperatorSkewStability,

            CASE WHEN s.CacheActualPlanAvailable = 0
                      OR s.CachePlanHash IS NULL
                      OR s.query_plan_hash <> s.CachePlanHash                    THEN 'Unavailable'
                 WHEN s.HasAnySpill = 1                                          THEN 'Unstable'
                 ELSE 'Stable' END                                               AS SpillStability,

            CASE WHEN s.PlanCount <= 1                                           THEN 'N/A'
                 WHEN s.BestPlanAvgIO IS NULL OR s.BestPlanAvgIO <= 0            THEN 'Unavailable'
                 WHEN s.WorstPlanAvgIO / s.BestPlanAvgIO > @IOVarianceScoreThreshold
                                                                                 THEN 'Unstable'
                 ELSE 'Stable' END                                               AS IOVarianceStability,

            CASE WHEN @AnnotateMemoryGrantFeedback = 0 THEN 'Not requested'
                 WHEN @HasPlanFeedbackView = 0         THEN 'Not available on this engine'
                 WHEN gf.FeedbackState IS NULL         THEN 'None recorded'
                 ELSE gf.FeedbackState END                                       AS MemoryGrantFeedbackState,

            CASE WHEN @AnnotateMemoryGrantFeedback = 0 OR @HasPlanFeedbackView = 0 THEN NULL
                 WHEN gf.FeedbackState = 'FEEDBACK_VALID'
                      THEN 'Engine has applied a VALIDATED grant correction to this plan ('
                           + ISNULL(CAST(gf.AdditionalKB AS VARCHAR(20)), '?') + ' KB across operators).'
                           + ' An Unstable MemoryGrantStability here may be that correction rather than'
                           + ' parameter sniffing -- check whether the grant is still moving before acting.'
                 WHEN gf.FeedbackState IN ('PENDING_VALIDATION','IN_VALIDATION')
                      THEN 'Engine is currently trialling a grant correction on this plan; the grant is'
                           + ' expected to move between executions while that settles.'
                 WHEN gf.FeedbackState = 'VERIFICATION_REGRESSED'
                      THEN 'Engine tried a grant correction and it made things worse, so it was rolled'
                           + ' back. The instability is real.'
                 WHEN gf.FeedbackState IS NULL THEN NULL
                 ELSE 'Feedback state ' + gf.FeedbackState + ' -- see sys.query_store_plan_feedback.'
            END                                                                  AS MemoryGrantFeedbackNote
        FROM #Scored s
        LEFT JOIN #GrantFeedback gf ON gf.plan_id = s.plan_id
    ),
    ScoredBanded AS (
        SELECT
            sf.*,

            CASE WHEN (CASE WHEN sf.BestPlanAvgIO > 0 THEN sf.WorstPlanAvgIO / sf.BestPlanAvgIO END)
                      > @IOVarianceRecommendationThreshold THEN 1 ELSE 0 END        AS TriggerIOVariance,
            CASE WHEN sf.AvgLogicalReads > @HighIOLogicalReadsThreshold
                 THEN 1 ELSE 0 END                                                  AS TriggerHighLogicalReads,
            CASE WHEN (CASE WHEN sf.EstimatedRows > 0 AND sf.CacheActualRows > 0
                            THEN CASE WHEN sf.CacheActualRows >= sf.EstimatedRows
                                      THEN sf.CacheActualRows / sf.EstimatedRows
                                      ELSE sf.EstimatedRows / sf.CacheActualRows END
                       END) > @CardinalitySkewThreshold THEN 1 ELSE 0 END           AS TriggerCardinalitySkew,

            (CASE WHEN sf.PlanStability        IN ('Stable','Unstable') THEN 25 ELSE 0 END +
             CASE WHEN sf.PlanShapeStability   IN ('Stable','Unstable') THEN 15 ELSE 0 END +
             CASE WHEN sf.MemoryGrantStability IN ('Stable','Unstable') THEN 15 ELSE 0 END +
             CASE WHEN sf.ParallelismStability IN ('Stable','Unstable') THEN 10 ELSE 0 END +
             CASE WHEN sf.OperatorSkewStability IN ('Stable','Unstable') THEN 15 ELSE 0 END +
             CASE WHEN sf.SpillStability       IN ('Stable','Unstable') THEN 10 ELSE 0 END +
             CASE WHEN sf.IOVarianceStability  IN ('Stable','Unstable') THEN 10 ELSE 0 END
            ) AS SniffingSeverityScoreCeiling,
            (CASE WHEN sf.PlanStability         = 'Unavailable' THEN 1 ELSE 0 END +
             CASE WHEN sf.PlanShapeStability    = 'Unavailable' THEN 1 ELSE 0 END +
             CASE WHEN sf.MemoryGrantStability  = 'Unavailable' THEN 1 ELSE 0 END +
             CASE WHEN sf.ParallelismStability  = 'Unavailable' THEN 1 ELSE 0 END +
             CASE WHEN sf.OperatorSkewStability = 'Unavailable' THEN 1 ELSE 0 END +
             CASE WHEN sf.SpillStability        = 'Unavailable' THEN 1 ELSE 0 END +
             CASE WHEN sf.IOVarianceStability   = 'Unavailable' THEN 1 ELSE 0 END
            ) AS SignalsUnavailable,
            CASE
                WHEN sf.SniffingSeverityScore BETWEEN 0 AND 25 THEN 'Low'
                WHEN sf.SniffingSeverityScore BETWEEN 26 AND 50 THEN 'Medium'
                WHEN sf.SniffingSeverityScore BETWEEN 51 AND 75 THEN 'High'
                ELSE 'Critical'
            END AS SniffingSeverityBand,

            STUFF((
                SELECT ', ' + Sig.Signal
                FROM (VALUES
                    (1, CASE WHEN sf.PlanStability         = 'Unstable' THEN 'PlanStability' END),
                    (2, CASE WHEN sf.PlanShapeStability    = 'Unstable' THEN 'PlanShapeStability' END),
                    (3, CASE WHEN sf.MemoryGrantStability  = 'Unstable' THEN 'MemoryGrantStability' END),
                    (4, CASE WHEN sf.ParallelismStability  = 'Unstable' THEN 'ParallelismStability' END),
                    (5, CASE WHEN sf.OperatorSkewStability = 'Unstable' THEN 'OperatorSkewStability' END),
                    (6, CASE WHEN sf.SpillStability        = 'Unstable' THEN 'SpillStability' END),
                    (7, CASE WHEN sf.IOVarianceStability   = 'Unstable' THEN 'IOVarianceStability' END)
                ) AS Sig(SignalOrder, Signal)
                WHERE Sig.Signal IS NOT NULL

                ORDER BY Sig.SignalOrder
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '') AS SniffingSeveritySignals,
            CASE WHEN sf.PlanStability = 'Unstable' OR sf.IOVarianceStability = 'Unstable'
                      OR sf.OperatorSkewStability = 'Unstable' OR sf.SpillStability = 'Unstable'
                 THEN 'Yes' ELSE 'No' END AS PlanForcingCandidate,
            CASE
                WHEN sf.HighDurationLowCpu_DominantWaitCategory = 'Lock'
                    THEN 'Investigate blocking/locking -- indexing will not resolve this on its own'
                WHEN sf.PlanStability = 'Unstable'
                    THEN 'Multiple plans detected -- see RecommendedRecompileSQL for a frequency-aware recommendation.'
                WHEN sf.PlanShapeStability = 'Unstable'
                    THEN 'Plan shape drift detected -- update stats, review predicates, or see RecommendedRecompileSQL.'
                WHEN sf.MemoryGrantStability = 'Unstable'
                    THEN 'Memory grant instability -- update stats or see RecommendedRecompileSQL.'
                WHEN sf.ParallelismStability = 'Unstable'
                    THEN 'Parallelism mismatch -- review row estimates or MAXDOP settings.'
                WHEN sf.OperatorSkewStability = 'Unstable'
                    THEN 'Severe rowcount skew -- update stats, rewrite predicates, or see RecommendedRecompileSQL.'
                WHEN sf.SpillStability = 'Unstable'
                    THEN 'TempDB spills detected -- increase memory grant, fix row estimates, or see RecommendedRecompileSQL.'
                WHEN sf.IOVarianceStability = 'Unstable'
                    THEN 'High IO variance -- consider indexing improvements or forcing the best plan.'
                WHEN sf.AvgLogicalReads > @HighIOLogicalReadsThreshold
                    THEN 'High logical reads -- consider adding or adjusting indexes.'
                ELSE 'No immediate action required.'
            END AS SuggestedRemediationPath,
            CASE
                WHEN sf.HighDurationLowCpu_DominantWaitCategory = 'Lock'
                    THEN 'Blocking/lock contention -- not a plan or indexing issue.'
                WHEN sf.PlanStability = 'Unstable'
                    THEN 'Parameter sniffing: multiple plans generated for different parameter sets.'
                WHEN sf.PlanShapeStability = 'Unstable'
                    THEN 'Plan regression or parameter sensitivity caused plan shape drift.'
                WHEN sf.MemoryGrantStability = 'Unstable'
                    THEN 'Incorrect cardinality estimates causing memory grant volatility.'
                WHEN sf.ParallelismStability = 'Unstable'
                    THEN 'Parallelism chosen inconsistently due to row estimate differences.'
                WHEN sf.OperatorSkewStability = 'Unstable'
                    THEN 'Severe cardinality mismatch -- stats may be stale or predicates non-SARGable.'
                WHEN sf.SpillStability = 'Unstable'
                    THEN 'Insufficient memory grant or underestimated row counts causing spills.'
                WHEN sf.IOVarianceStability = 'Unstable'
                    THEN 'IO explosion likely caused by missing or inefficient indexes.'
                WHEN sf.AvgLogicalReads > @HighIOLogicalReadsThreshold
                    THEN 'High IO suggests missing indexes or poor index selection.'
                ELSE 'No root cause detected.'
            END AS RootCauseHint,

            CASE WHEN EXISTS (
                     SELECT 1 FROM #CacheMatch cm2
                     WHERE cm2.query_id = sf.query_id
                       AND cm2.PlanCompatModel IS NOT NULL
                       AND sf.PlanCompatModel IS NOT NULL
                       AND cm2.PlanCompatModel <> sf.PlanCompatModel)
                 THEN 'Yes' ELSE 'No' END AS MixedCEModelAcrossPlans,

            /*  PlanUsesLegacyCE -- the PLAN's own estimator, not the database's setting. CE model 70 reaches
                a plan three ways, all measured 2026-09-17 on this engine: compatibility level 100 or 110;
                LEGACY_CARDINALITY_ESTIMATION ON at ANY level (a database can read compat 170 and still
                compile every plan at 70); or the statement itself carrying trace flag 9481 or the query hint
                FORCE_LEGACY_CARDINALITY_ESTIMATION. Reading the plan's own model catches all three, which is
                why this is not derived from the compatibility level. NULL when the plan records no model at
                all -- an unreadable plan is not evidence of a modern estimator, and must not read 'No'.  */
            CASE WHEN sf.PlanCompatModel IS NULL THEN NULL
                 WHEN sf.PlanCompatModel = 70    THEN 'Yes'
                 ELSE 'No' END AS PlanUsesLegacyCE
        FROM StabilityFlags sf
    )
    SELECT *
    INTO #ScoredBanded
    FROM ScoredBanded;

    /*  [AI Prompt] IS BUILT ACROSS FOUR STATEMENTS (2026-09-14) -- the script's Section 11 has the
        reasoning and the measurements. One statement building the whole prompt measured 114 levels
        deep here against the xml type's 128, because every correlated subquery is a nested loop on
        the deepest path. The INSERT below carries the prompt's first four sections; three UPDATEs
        append the rest in order, each confined to THIS database's rows. Section text is verbatim. */
    ALTER TABLE #TableCandidates ADD AIPromptTcRowId INT IDENTITY(1, 1);

    INSERT INTO #Results
    SELECT
        @DatabaseName,
        sb.object_name, sb.object_id, sb.query_id, sb.plan_id, sb.query_hash, sb.query_plan_hash, sb.plan_handle,
        sb.query_sql_text,
        sb.CacheLastExecutionTime, sb.CacheActualPlanAvailable,
        sb.SniffingSeverityScore, sb.SniffingSeverityBand,

        sb.SniffingSeverityScoreCeiling,
        sb.SignalsUnavailable,

        sb.PlanStability, sb.PlanShapeStability, sb.MemoryGrantStability, sb.ParallelismStability,
        sb.OperatorSkewStability, sb.SpillStability, sb.IOVarianceStability,

        sb.MemoryGrantFeedbackState, sb.MemoryGrantFeedbackNote,
        sb.SniffingSeveritySignals, sb.PlanForcingCandidate,
        sb.SuggestedRemediationPath, sb.RootCauseHint,
        sb.HighDurationLowCpu_DominantWaitCategory,
        sb.TotalExecutions, sb.AvgLogicalReads, sb.MaxLogicalReads, sb.AvgDurationMs, sb.MaxDurationMs, sb.AvgCpuTimeMs,
        sb.PlanCount, sb.WorstPlanAvgIO, sb.BestPlanAvgIO,
        CASE WHEN sb.BestPlanAvgIO > 0 THEN sb.WorstPlanAvgIO / sb.BestPlanAvgIO END AS IOVarianceRatio,
        sb.EstimatedRows, sb.CacheActualRows, sb.EstimatedMemoryGrant, sb.CacheActualMemoryGrant,
        sb.EstimatedParallelismFlag, sb.CacheActualParallelismFlag,

        CASE WHEN sb.EstimatedRows > 0 AND sb.AvgRowcount IS NOT NULL THEN sb.AvgRowcount / sb.EstimatedRows END AS EstimateVsActualRatio,
        CASE WHEN sb.MinRowcount > 0 THEN sb.MaxRowcount / sb.MinRowcount END AS MaxToMinRowRatio,
        tc.TableSchemaRaw, tc.TableNameRaw, tc.TableRank,

        tc.AccessNodeId, tc.AccessPhysicalOp, tc.KeyScope, tc.AccessPathsOnThisTable,
        tc.ComputedIncludeColumns,
        -- Actual figures only where they were measured (2026-09-14): a sum over missing counters is 0,
        -- which reads as measured. Rows need an actual plan (the AP test); the IO columns need recorded
        -- reads, which the last actual plan never has. See the script.
        tc.AccessEstimateIO,
        CASE WHEN tc.AccessHasActualReads = 1 THEN tc.AccessActualIO END,
        tc.AccessEstimateRows,
        CASE WHEN sb.query_plan_hash = sb.CachePlanHash AND sb.CacheActualPlanXML IS NOT NULL THEN tc.AccessActualRows END,
        CASE WHEN tc.AnyActualReads = 1 THEN tc.TotalActualIO END,
        tc.TotalEstimateIO, tc.WorstSkewRatio, tc.SpillEventCount, tc.WorstSpillLevel, tc.SpillDetectionSource, tc.SpillAttributionTied,
        tc.EstimatedTableSizeMB, tc.BaseIndexCompression, tc.CandidateIndexName,

        tc.KeyColumnCount, tc.KeyByteSize, tc.ExcludedKeyColumns, tc.ExcludedIncludeColumns,
        -- Section 8c in the script.
        tc.isXML,
        -- Sections 7f/8d in the script.
        tc.isJSON,

        tc.KeyColumns     AS BaseIndexKeyColumns,
        tc.IncludeColumns AS BaseIndexIncludeColumns,

        tc.PredicateColumns AS KeyColumnsFromPredicates,
        tc.JoinColumns      AS KeyColumnsFromJoins,
        tc.GroupByColumns   AS KeyColumnsFromGroupBy,
        tc.OrderByColumns   AS KeyColumnsFromOrderBy,
        sb.EstimatedPlanXML, sb.CacheActualPlanXML,

        CASE

            WHEN (@IndexRecommendationMode = 'A' OR tc.TableRank = 1)
                 AND tc.KeyColumns IS NOT NULL
                 AND tc.KeyColumnCount > @MaxIndexKeyColumns
            THEN '-- NOT GENERATED: this table contributed ' + CAST(tc.KeyColumnCount AS VARCHAR(10))
                 + ' key columns, over the ' + CAST(@MaxIndexKeyColumns AS VARCHAR(10)) + '-column limit'
                 + CHAR(13) + '-- for a composite index key. The full list is in BaseIndexKeyColumns.'
                 + CHAR(13) + '-- Narrow the query, or pick the leading columns by selectivity and index those.'
            WHEN (@IndexRecommendationMode = 'A' OR tc.TableRank = 1)
                 AND tc.KeyColumns IS NOT NULL
                 AND tc.KeyByteSize > @MaxIndexKeyBytes
            THEN '-- NOT GENERATED: the key columns total ' + CAST(tc.KeyByteSize AS VARCHAR(10))
                 + ' bytes, over the ' + CAST(@MaxIndexKeyBytes AS VARCHAR(10)) + '-byte limit for a'
                 + CHAR(13) + '-- nonclustered index key. The full list is in BaseIndexKeyColumns.'
                 + CHAR(13) + '-- Included columns do not count toward this limit -- moving a wide column'
                 + CHAR(13) + '-- out of the key and into INCLUDE may be enough, if it is not needed for seeking.'
            WHEN (@IndexRecommendationMode = 'A' OR tc.TableRank = 1)
                 AND tc.KeyColumns IS NOT NULL
            THEN
                '-- CREATE INDEX ' + tc.CandidateIndexName + CHAR(13) +
                '-- ON ' + ISNULL(tc.TableSchemaRaw + '.', '') + ISNULL(tc.TableNameRaw, '') + '(' + tc.KeyColumns + ')' + CHAR(13) +
                '-- INCLUDE (' + ISNULL(tc.IncludeColumns, '/* no additional output columns identified */') + ')' +

                CASE WHEN @DataCompressionSupported = 1
                     THEN CHAR(13) + '-- WITH (DATA_COMPRESSION = ' + ISNULL(tc.BaseIndexCompression, 'ROW') + ')'
                     ELSE '' END + ';' + CHAR(13) +
                CASE WHEN @DataCompressionSupported = 1 THEN ''
                     ELSE '-- DATA_COMPRESSION was deliberately OMITTED: this instance is SQL Server 2016 RTM on a' + CHAR(13)
                        + '-- non-Enterprise edition, where compression is unavailable (it arrived for Standard/Web/' + CHAR(13)
                        + '-- Express in 2016 SP1). Apply SP1 or later to use it. The index itself is unaffected.' + CHAR(13)
                     END +
                '-- Heuristic recommendation -- review key-column order and selectivity before executing.' + CHAR(13) +
                '-- Key columns carry ASC/DESC taken from the plan''s own ORDER BY; see BaseIndexKeyColumns.' + CHAR(13) +
                '-- See BaseIndexBasis for whether this is urgent or informational.'
            WHEN tc.TableNameRaw IS NULL
            THEN '-- No table candidate could be extracted from this plan -- nothing to index.'
            WHEN NOT (@IndexRecommendationMode = 'A' OR tc.TableRank = 1)
            THEN '-- Not the table selected by @IndexRecommendationMode = ' + @IndexRecommendationMode
                 + ' (this table ranked ' + CAST(tc.TableRank AS VARCHAR(10)) + ').' + CHAR(13)
                 + '-- Set @IndexRecommendationMode = ''A'' to see a recommendation for every table in this plan.'

            WHEN tc.KeyColumns IS NULL AND tc.ExcludedKeyColumns IS NOT NULL
            THEN '-- NOT GENERATED: every key-role column found for this table is an index-key-ineligible'
                 + CHAR(13) + '-- type, so there is nothing left to build a key from. Excluded: '
                 + tc.ExcludedKeyColumns + CHAR(13)
                 + '-- ntext, text, image, xml and the max types cannot be index key columns. If this query'
                 + CHAR(13) + '-- needs to filter on that column, an index will not help it -- consider full-text'
                 + CHAR(13) + '-- search, a computed hash or prefix column, or restructuring the predicate.'
            ELSE '-- No key columns could be extracted for this table from the captured plan, so no'
                 + CHAR(13) + '-- CREATE INDEX can be generated. This usually means the plan contains no seek'
                 + CHAR(13) + '-- predicate, scan residual predicate, or Filter predicate referencing this table.'
        END AS BaseIndexCreateSQL,
        CASE
            WHEN (@IndexRecommendationMode = 'A' OR tc.TableRank = 1)
                 AND tc.KeyColumns IS NOT NULL
            THEN '-- DROP INDEX ' + tc.CandidateIndexName + ' ON ' + ISNULL(tc.TableSchemaRaw + '.', '') + ISNULL(tc.TableNameRaw, '') + ';'
            ELSE '-- No index recommended above; nothing to drop.'
        END AS BaseIndexDropSQL,

        CASE
            WHEN NOT ((@IndexRecommendationMode = 'A' OR tc.TableRank = 1) AND tc.KeyColumns IS NOT NULL)
                 THEN NULL
            WHEN sb.TriggerIOVariance + sb.TriggerHighLogicalReads + sb.TriggerCardinalitySkew = 0
                 THEN 'Informational -- no severity trigger fired. The statement is not currently '
                    + 'showing instability or excessive IO, but this is the index its predicates imply. '
                    + 'Review on merit, not urgency.'
            ELSE 'ACT ON THIS -- triggered by: ' + STUFF(
                     CASE WHEN sb.TriggerIOVariance       = 1 THEN ', IO variance between plans past '
                          + CAST(@IOVarianceRecommendationThreshold AS VARCHAR(20)) + 'x' ELSE '' END
                   + CASE WHEN sb.TriggerHighLogicalReads = 1 THEN ', average logical reads past '
                          + CAST(@HighIOLogicalReadsThreshold AS VARCHAR(20)) ELSE '' END
                   + CASE WHEN sb.TriggerCardinalitySkew  = 1 THEN ', cardinality skew past '
                          + CAST(@CardinalitySkewThreshold AS VARCHAR(20)) + 'x' ELSE '' END
                 , 1, 2, '')
        END AS BaseIndexBasis,

        CASE
            WHEN sb.PlanStability = 'Unstable' OR sb.PlanShapeStability = 'Unstable' OR sb.MemoryGrantStability = 'Unstable'
                 OR sb.OperatorSkewStability = 'Unstable' OR sb.SpillStability = 'Unstable'
            THEN
                CASE
                    WHEN (ISNULL(sb.TotalExecutions, 0) * 1.0) / NULLIF(@LookbackDays, 0) > @HighFrequencyExecutionsPerDayThreshold
                    THEN
                        '-- High execution frequency (~' + CAST(CAST(ISNULL(sb.TotalExecutions, 0) * 1.0 / NULLIF(@LookbackDays, 0) AS DECIMAL(18,2)) AS VARCHAR(20)) + '/day over the ' + CAST(@LookbackDays AS VARCHAR(10)) + '-day window) -- OPTION(RECOMPILE) on every call is likely too costly.' + CHAR(13) +
                        '-- Consider forcing the best-observed plan instead: EXEC sys.sp_query_store_force_plan @query_id = ' + CAST(sb.query_id AS VARCHAR(20)) + ', @plan_id = ' + ISNULL(CAST(sb.BestPlanID AS VARCHAR(20)), 'N/A') + ';' + CHAR(13) +
                        '-- Or, if one parameter value dominates the workload: OPTION (OPTIMIZE FOR (@ParamName = <representative typical value>)).' + CHAR(13) +
                        '-- Starting point based on execution volume, not a certainty -- the right frequency threshold depends on this statement''s own compile cost and available CPU headroom.'
                    ELSE
                        '-- Execution frequency (~' + CAST(CAST(ISNULL(sb.TotalExecutions, 0) * 1.0 / NULLIF(@LookbackDays, 0) AS DECIMAL(18,2)) AS VARCHAR(20)) + '/day over the ' + CAST(@LookbackDays AS VARCHAR(10)) + '-day window) is low enough that per-call recompilation is likely affordable.' + CHAR(13) +
                        '-- Consider OPTION (RECOMPILE) on the specific statement in [' + sb.object_name + '] (query_id ' + CAST(sb.query_id AS VARCHAR(20)) + ').' + CHAR(13) +
                        '-- Statement captured by Query Store: ' + LEFT(ISNULL(sb.query_sql_text, ''), 200) + CASE WHEN LEN(ISNULL(sb.query_sql_text, '')) > 200 THEN '...' ELSE '' END + CHAR(13) +
                        '-- Confirm this statement is the actual bottleneck before adding a per-call recompile.'
                END
            ELSE NULL
        END AS RecommendedRecompileSQL,
        @PlatformName                  AS Platform,
        @EditionName                   AS EditionName,
        @EngineEdition                 AS EngineEdition,

        @QueryCaptureMode              AS QueryCaptureMode,

        @MajorVersion                  AS SQLServerMajorVersion,

        @UpdatePolicy                  AS MIUpdatePolicy,
        @DatabaseCompatibilityLevel    AS DatabaseCompatibilityLevel,
        @LegacyCEDatabaseSetting       AS LegacyCEDatabaseSetting,
        sb.PlanCompatModel             AS PlanCardinalityEstimationModel,

        sb.MixedCEModelAcrossPlans,
        sb.PlanUsesLegacyCE,
        sb.PspoRole,
        sb.PspoParentQueryId,
        sb.PspoVariantCount,

        CAST(NULL AS XML) AS [AI Prompt],   -- filled after the per-database loop
        CASE WHEN @AI <> 2 THEN CAST(
                N'-- AI prompt generation is off (@AI = 0). Set @AI = 2 to build a copy/paste prompt '
              + N'for ChatGPT, Claude or Gemini out of this row''s findings.' AS NVARCHAR(MAX))
        ELSE

            CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                N'You are a very senior SQL Server database developer and query-tuning specialist. Give ',
                N'real-world, actionable advice. Skip pleasantries, skip the disclaimer about needing more ',
                N'information, and do not ask follow-up questions -- assume you get exactly one response, ',
                N'so make it complete.', @NL, @NL,
                N'The people reading your answer will ACT on it, so do not leave them guessing. Commit to a ',
                N'diagnosis and to ONE first action they can run: its exact T-SQL, the T-SQL that rolls it back, ',
                N'and how to verify it worked. If the evidence below really cannot support a decision, name the ',
                N'one missing fact and give the exact query that collects it -- never stop at "cannot tell".', @NL, @NL,
                N'Prefer query and index changes over instance-level configuration changes, and say what each ',
                N'recommendation costs as well as what it gains.', @NL, @NL,
                N'Everything below was produced by a parameter-sniffing diagnostic that read the plan cache ',
                N'first and Query Store as well, scored seven signals against a ceiling, and extracted ',
                N'candidate index columns from the plan XML. Treat its findings as MEASUREMENTS, not as ',
                N'conclusions: judge whether its reading is right, and tell me if it has misread the situation.', @NL, @NL,
                N'============================================================', @NL,
                N'  PARAMETER SNIFFING ANALYSIS REQUEST', @NL,
                N'============================================================', @NL)

          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- WHERE EACH FIGURE COMES FROM ---', @NL,
                N'[CACHE]  the plan cache: what is running NOW, counted since that plan was cached (the reactive view)', @NL,
                N'[ACTUAL] the last actual execution plan the plan cache kept for the statement (LAST_QUERY_PLAN_STATS)', @NL,
                N'[QS]     Query Store: every plan over the last ', CONVERT(NVARCHAR(10), @LookbackDays),
                    N' day(s), measured, surviving restarts (the proactive view)', @NL,
                N'[PLAN]   a stored plan''s XML: compile-time estimates, and the parameter values it was COMPILED for', @NL,
                N'[STATS]  the table''s statistics metadata', @NL,
                N'[TOOL]   this diagnostic''s own reading of all of the above', @NL,
                N'"not captured" means that source had nothing for this statement. It never means zero.', @NL)

          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- ENVIRONMENT ---', @NL,
                N'Platform              : ', COALESCE(@PlatformName, N'(unknown)'), @NL,
                N'Edition               : ', COALESCE(@EditionName, N'(unknown)'), @NL,
                N'EngineEdition         : ', COALESCE(CONVERT(NVARCHAR(10), @EngineEdition), N'(unknown)'), @NL,
                N'Engine major version  : ', COALESCE(CONVERT(NVARCHAR(10), @MajorVersion),
                                                    N'(not read -- platform identified by name, not version number)'), @NL,
                N'MI update policy      : ', COALESCE(@UpdatePolicy, N'(n/a -- not Managed Instance)'), @NL,
                -- @DatabaseName, not DB_NAME(): the analysis runs in the utility database, so
                -- DB_NAME() names THIS database and the prompt would attribute the findings --
                -- and the CREATE INDEX text beside them -- to the wrong one.
                N'Database              : ', COALESCE(@DatabaseName, N'(unknown)'), @NL,
                N'DB compatibility level: ', COALESCE(CONVERT(NVARCHAR(10), @DatabaseCompatibilityLevel), N'(unknown)'), @NL,
                N'Legacy CE (database)  : ', COALESCE(@LegacyCEDatabaseSetting, N'(not available)'),
                                             N'   <- LEGACY_CARDINALITY_ESTIMATION; ON forces the CE 70 estimator at ANY compat level', @NL,
                N'Query Store           : ', COALESCE(@QueryStoreState, N'(unknown)'),
                                             N'  |  QUERY_CAPTURE_MODE = ', COALESCE(@QueryCaptureMode, N'(unknown)'), @NL,
                N'Lookback window       : ', CONVERT(NVARCHAR(10), @LookbackDays), N' day(s)', @NL,
                N'This plan''s CE model  : ', COALESCE(CONVERT(NVARCHAR(10), sb.PlanCompatModel),
                                                     N'(not recorded in this plan)'),
                N'   <- the model this plan was COMPILED under, which can differ from the database''s current compat level', @NL)

          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- STATEMENT UNDER ANALYSIS ---', @NL,
                N'Object      : ', COALESCE(sb.object_name, N'(ad-hoc or dynamic SQL -- no owning object)'), @NL,
                N'query_id    : ', COALESCE(CONVERT(NVARCHAR(30), sb.query_id), N'(n/a)'),
                N'   plan_id: ', COALESCE(CONVERT(NVARCHAR(30), sb.plan_id), N'(n/a)'), @NL,
                N'query_hash  : ', COALESCE(CONVERT(NVARCHAR(34), sb.query_hash, 1), N'(n/a)'),
                N'   query_plan_hash: ', COALESCE(CONVERT(NVARCHAR(34), sb.query_plan_hash, 1), N'(n/a)'), @NL,
                N'Last executed (plan cache): ', COALESCE(CONVERT(NVARCHAR(30), sb.CacheLastExecutionTime, 120),
                                                        N'(no plan-cache match -- see caveats)'), @NL,
                @NL, N'SQL text:', @NL,
                CASE
                    WHEN sb.query_sql_text IS NULL THEN N'(no statement text captured by Query Store)'
                    WHEN DATALENGTH(sb.query_sql_text) / 2 > @AIPromptSqlTextMaxChars
                        THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), LEFT(sb.query_sql_text, @AIPromptSqlTextMaxChars), @NL,
                                    N'-- [TRUNCATED at @AIPromptSqlTextMaxChars = ',
                                    CONVERT(NVARCHAR(20), @AIPromptSqlTextMaxChars),
                                    N' characters. Full text is in the query_sql_text column of this row.]')
                    ELSE sb.query_sql_text
                END, @NL)
        END AS AIPromptText,
        tc.AIPromptTcRowId
    FROM #ScoredBanded sb
    LEFT JOIN #TableCandidates tc
        ON tc.object_name = sb.object_name AND tc.query_id = sb.query_id AND tc.plan_id = sb.plan_id
    LEFT JOIN #AIPromptPlan app
        ON app.query_id = sb.query_id AND app.plan_id = sb.plan_id
    WHERE sb.SniffingSeverityScore >= @MinimumSeverityScore
    ORDER BY sb.SniffingSeverityScore DESC, sb.object_name, sb.query_id, sb.plan_id, tc.TableRank;

    -- [AI Prompt], part 2 of 4: every plan of the statement
    UPDATE r
    SET    r.AIPromptText = r.AIPromptText
          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- EVERY PLAN THIS STATEMENT COMPILED TO ([QS] last ', CONVERT(NVARCHAR(10), @LookbackDays), N' day(s)) ---', @NL,
                CONVERT(NVARCHAR(10), (SELECT COUNT(*) FROM #AIPromptPlan p WHERE p.query_id = sb.query_id)),
                    N' plan(s). THIS row is plan_id ', COALESCE(CONVERT(NVARCHAR(30), sb.plan_id), N'(n/a)'),
                    N'. What differs between them is the evidence.', @NL,
                COALESCE((
                    SELECT CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                        @NL, N'plan_id ', CONVERT(NVARCHAR(30), p.plan_id),
                            CASE WHEN p.plan_id = sb.plan_id THEN N'   <== THIS ROW' ELSE N'' END,
                            CASE WHEN p.IsCachedPlan = 1 THEN N'   [CACHE] the plan cached right now' ELSE N'' END, @NL,
                        N'  [PLAN] compiled for   : ', COALESCE(p.CompiledParameters, CASE WHEN p.IsParallel IS NULL THEN N'not captured (the stored plan could not be read as XML)' ELSE N'no parameters in this plan (literals or local variables)' END), @NL,
                        N'  [PLAN] shape          : ',
                            CASE WHEN p.IsParallel = 1
                                 THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'PARALLEL (', CONVERT(NVARCHAR(10), p.ParallelismOperators), N' parallelism operator(s))')
                                 WHEN p.IsParallel = 0 THEN N'serial'
                                 ELSE N'not captured' END,
                            N' ; estimated rows ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.EstStatementRows AS DECIMAL(38,0))), N'not captured'), N' ; estimated cost ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.EstSubtreeCost AS DECIMAL(38,4))), N'not captured'), @NL,
                        N'  [PLAN] operators      : ', COALESCE(p.OperatorSummary, N'not captured'), @NL,
                        N'  [PLAN] warnings       : ', COALESCE(p.PlanWarnings, CASE WHEN p.IsParallel IS NULL THEN N'not captured' ELSE N'none' END),
                            N' ; missing-index hints: ', COALESCE(CONVERT(NVARCHAR(10), p.MissingIndexHints), N'not captured'), @NL,
                        N'  [QS]   executions     : ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.TotalExecutions AS DECIMAL(38,0))), N'not captured'),
                            N' (first ', COALESCE(CONVERT(NVARCHAR(19), p.FirstExecutionTime, 120), N'not captured'), N', last ', COALESCE(CONVERT(NVARCHAR(19), p.LastExecutionTime, 120), N'not captured'), N' UTC)',
                            N' ; forced: ', CASE WHEN p.IsForcedPlan = 1 THEN N'YES' ELSE N'no' END,
                            CASE WHEN p.ForceFailureCount > 0
                                 THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N' (', CONVERT(NVARCHAR(20), p.ForceFailureCount), N' forcing failure(s))')
                                 ELSE N'' END,
                            N' ; compiles: ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.PlanCompileCount AS DECIMAL(38,0))), N'not captured'), @NL,
                        N'  [QS]   duration ms    : avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.AvgDurationMs AS DECIMAL(38,2))), N'not captured'), N'  min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MinDurationMs AS DECIMAL(38,2))), N'not captured'),
                            N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MaxDurationMs AS DECIMAL(38,2))), N'not captured'), N'  stdev ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.StdevDurationMs AS DECIMAL(38,2))), N'not captured'), @NL,
                        N'  [QS]   CPU ms         : avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.AvgCpuTimeMs AS DECIMAL(38,2))), N'not captured'), N'  min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MinCpuTimeMs AS DECIMAL(38,2))), N'not captured'),
                            N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MaxCpuTimeMs AS DECIMAL(38,2))), N'not captured'), N'  stdev ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.StdevCpuTimeMs AS DECIMAL(38,2))), N'not captured'),
                            CASE WHEN p.AvgDurationMs > 0 AND p.AvgCpuTimeMs > p.AvgDurationMs * 1.2
                                 THEN N'   (CPU exceeds elapsed time: more than one thread did the work)' ELSE N'' END, @NL,
                        N'  [QS]   logical reads  : avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.AvgLogicalReads AS DECIMAL(38,0))), N'not captured'), N'  min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MinLogicalReads AS DECIMAL(38,0))), N'not captured'),
                            N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MaxLogicalReads AS DECIMAL(38,0))), N'not captured'), N'  stdev ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.StdevLogicalReads AS DECIMAL(38,0))), N'not captured'),
                            N' ; physical reads avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.AvgPhysicalReads AS DECIMAL(38,0))), N'not captured'), N' ; writes avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.AvgLogicalWrites AS DECIMAL(38,0))), N'not captured'), @NL,
                        N'  [QS]   rows returned  : avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.AvgRowcount AS DECIMAL(38,0))), N'not captured'), N'  min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MinRowcount AS DECIMAL(38,0))), N'not captured'),
                            N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MaxRowcount AS DECIMAL(38,0))), N'not captured'), N'  stdev ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.StdevRowcount AS DECIMAL(38,0))), N'not captured'), @NL,
                        N'  [QS]   DOP            : min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MinDop AS DECIMAL(38,0))), N'not captured'), N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MaxDop AS DECIMAL(38,0))), N'not captured'), @NL,
                        N'  [QS]   memory used KB : avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.AvgUsedMemoryKB AS DECIMAL(38,0))), N'not captured'), N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MaxUsedMemoryKB AS DECIMAL(38,0))), N'not captured'),
                            N' ; tempdb KB avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.AvgTempdbKB AS DECIMAL(38,0))), N'not captured'), N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(p.MaxTempdbKB AS DECIMAL(38,0))), N'not captured'), @NL)
                    FROM #AIPromptPlan p
                    WHERE p.query_id = sb.query_id
                    ORDER BY p.plan_id
                    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), N'(no plans found for this statement)'),
                @NL, N'[TOOL] across these plans: ',
                    CONVERT(NVARCHAR(10), (SELECT COUNT(*) FROM #AIPromptPlan p WHERE p.query_id = sb.query_id AND p.IsParallel = 1)), N' parallel, ',
                    CONVERT(NVARCHAR(10), (SELECT COUNT(*) FROM #AIPromptPlan p WHERE p.query_id = sb.query_id AND p.IsParallel = 0)), N' serial ; ',
                    CASE WHEN (SELECT COUNT(DISTINCT p.CompiledParameters) FROM #AIPromptPlan p WHERE p.query_id = sb.query_id) = 0
                         THEN N'no compiled parameter values found'
                         ELSE CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                CONVERT(NVARCHAR(10), (SELECT COUNT(DISTINCT p.CompiledParameters) FROM #AIPromptPlan p WHERE p.query_id = sb.query_id)),
                                N' distinct set(s) of compiled parameter values') END,
                    N' ; avg logical reads from ',
                    COALESCE(CONVERT(NVARCHAR(50), TRY_CAST((SELECT MIN(p.AvgLogicalReads) FROM #AIPromptPlan p WHERE p.query_id = sb.query_id) AS DECIMAL(38,0))), N'not captured'), N' to ',
                    COALESCE(CONVERT(NVARCHAR(50), TRY_CAST((SELECT MAX(p.AvgLogicalReads) FROM #AIPromptPlan p WHERE p.query_id = sb.query_id) AS DECIMAL(38,0))), N'not captured'),
                    N' ; avg duration ms from ',
                    COALESCE(CONVERT(NVARCHAR(50), TRY_CAST((SELECT MIN(p.AvgDurationMs) FROM #AIPromptPlan p WHERE p.query_id = sb.query_id) AS DECIMAL(38,2))), N'not captured'), N' to ',
                    COALESCE(CONVERT(NVARCHAR(50), TRY_CAST((SELECT MAX(p.AvgDurationMs) FROM #AIPromptPlan p WHERE p.query_id = sb.query_id) AS DECIMAL(38,2))), N'not captured'), @NL)
    FROM #Results r
    JOIN #ScoredBanded sb
        ON sb.query_id = r.query_id AND sb.plan_id = r.plan_id
    LEFT JOIN #TableCandidates tc
        ON tc.AIPromptTcRowId = r.AIPromptTcRowId
    LEFT JOIN #AIPromptPlan app
        ON app.query_id = sb.query_id AND app.plan_id = sb.plan_id
    WHERE r.DatabaseName = @DatabaseName
      AND @AI = 2;

    -- [AI Prompt], part 3 of 4: live plan cache through estimate vs actual
    UPDATE r
    SET    r.AIPromptText = r.AIPromptText
          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- LIVE PLAN CACHE (reactive: what is running now) ---', @NL,
                CASE
                    WHEN app.CacheAttributionDeclined = 1
                        THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                            N'[CACHE] Not matched to this row. ',
                            CASE WHEN app.CacheIsThisStatement = 1
                                 THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                        N'The cached procedure runs ', CONVERT(NVARCHAR(10), app.CacheSameHashStatements),
                                        N' statements with this query_hash, but Query Store holds them as ', CONVERT(NVARCHAR(10), app.QsSameHashQueries),
                                        N' quer', CASE WHEN app.QsSameHashQueries = 1 THEN N'y' ELSE N'ies' END,
                                        N' -- it merges character-identical statements into one query -- so this row''s Query Store ',
                                        N'figures may cover more than one cached statement, and no single cache entry can be matched to them with certainty.')
                                 ELSE CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                        N'This row''s Query Store query was last compiled as a statement the plan cache does not hold now ',
                                        N'-- an earlier version of the procedure, or a statement not run since the plan was cached -- and ',
                                        N'the procedure has more than one statement with this query_hash (', CONVERT(NVARCHAR(10), app.CacheSameHashStatements),
                                        N' cached, ', CONVERT(NVARCHAR(10), app.QsSameHashQueries), N' in Query Store for the cached version), ',
                                        N'so a cache entry could describe a different statement.') END,
                            N' The cache counters and the last actual plan are left out rather than guessed; every runtime ',
                            N'figure in this prompt comes from Query Store.', @NL)
                    WHEN app.CachePlanHash IS NULL
                        THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                            N'[CACHE] Nothing for this statement is in the plan cache right now -- evicted, cleared by a ',
                            N'restart or a configuration change, or not run since. Every runtime figure in this prompt ',
                            N'therefore comes from Query Store, and no actual plan is available.', @NL)
                    ELSE CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                        N'[CACHE] cached plan     : ',
                            COALESCE((SELECT CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'plan_id ', CONVERT(NVARCHAR(30), MIN(p.plan_id)))
                                      FROM #AIPromptPlan p
                                      WHERE p.query_id = sb.query_id AND p.IsCachedPlan = 1
                                      HAVING COUNT(*) > 0),
                                     N'a plan Query Store does not hold for this window'),
                            N' (query_plan_hash ', CONVERT(NVARCHAR(34), app.CachePlanHash, 1), N') -- ',
                            CASE WHEN app.IsCachedPlan = 1 THEN N'this is THIS row''s plan'
                                 ELSE N'NOT this row''s plan, so the figures below describe a different plan' END, @NL,
                        N'[CACHE] cached since    : ', COALESCE(CONVERT(NVARCHAR(19), app.CacheCreationTime, 120), N'not captured'), N' server time ; last run ', COALESCE(CONVERT(NVARCHAR(19), app.CacheLastExecutionTime, 120), N'not captured'), @NL,
                        N'[CACHE] executions      : ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheExecutionCount AS DECIMAL(38,0))), N'not captured'), N' since it was cached', @NL,
                        N'[CACHE] CPU ms          : total ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheTotalWorkerMs AS DECIMAL(38,2))), N'not captured'),
                            N'  avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheTotalWorkerMs / NULLIF(app.CacheExecutionCount, 0) AS DECIMAL(38,2))), N'not captured'),
                            N'  min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMinWorkerMs AS DECIMAL(38,2))), N'not captured'), N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMaxWorkerMs AS DECIMAL(38,2))), N'not captured'), @NL,
                        N'[CACHE] duration ms     : total ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheTotalElapsedMs AS DECIMAL(38,2))), N'not captured'),
                            N'  avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheTotalElapsedMs / NULLIF(app.CacheExecutionCount, 0) AS DECIMAL(38,2))), N'not captured'),
                            N'  min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMinElapsedMs AS DECIMAL(38,2))), N'not captured'), N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMaxElapsedMs AS DECIMAL(38,2))), N'not captured'), @NL,
                        N'[CACHE] logical reads   : total ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheTotalLogicalReads AS DECIMAL(38,0))), N'not captured'),
                            N'  avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheTotalLogicalReads * 1.0 / NULLIF(app.CacheExecutionCount, 0) AS DECIMAL(38,0))), N'not captured'),
                            N'  min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMinLogicalReads AS DECIMAL(38,0))), N'not captured'), N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMaxLogicalReads AS DECIMAL(38,0))), N'not captured'),
                            N' ; writes total ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheTotalLogicalWrites AS DECIMAL(38,0))), N'not captured'), @NL,
                        N'[CACHE] rows returned   : total ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheTotalRows AS DECIMAL(38,0))), N'not captured'),
                            N'  min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMinRows AS DECIMAL(38,0))), N'not captured'), N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMaxRows AS DECIMAL(38,0))), N'not captured'), @NL,
                        N'[CACHE] memory grant KB : granted min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMinGrantKB AS DECIMAL(38,0))), N'not captured'), N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMaxGrantKB AS DECIMAL(38,0))), N'not captured'),
                            N' ; used min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMinUsedGrantKB AS DECIMAL(38,0))), N'not captured'), N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMaxUsedGrantKB AS DECIMAL(38,0))), N'not captured'),
                            N' ; ideal max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMaxIdealGrantKB AS DECIMAL(38,0))), N'not captured'), @NL,
                        N'[CACHE] spills          : total ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheTotalSpills AS DECIMAL(38,0))), N'not captured'), N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMaxSpills AS DECIMAL(38,0))), N'not captured'),
                            N' ; DOP min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMinDop AS DECIMAL(38,0))), N'not captured'), N'  max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.CacheMaxDop AS DECIMAL(38,0))), N'not captured'), @NL,
                        N'[ACTUAL] last actual plan: ',
                            CASE WHEN app.CacheActualPlanAvailable = 1
                                 THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                        N'DOP ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.ActualDop AS DECIMAL(38,0))), N'not captured'), N' ; ',
                                        CASE WHEN app.ActualGrantedKB IS NULL THEN N'no memory grant'
                                             ELSE CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'memory granted ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.ActualGrantedKB AS DECIMAL(38,0))), N'not captured'),
                                                         N' KB, max used ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.ActualMaxUsedKB AS DECIMAL(38,0))), N'not captured'), N' KB') END,
                                        N' ; warnings: ', COALESCE(app.ActualWarnings, N'none'),
                                        N'. It records actual rows and DOP, not the parameter values it ran with.')
                                 WHEN app.CacheActualPlanDeclined = 1
                                 THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                        N'not used -- it covers the whole procedure, and this statement could not be isolated in it (',
                                        CONVERT(NVARCHAR(10), app.CacheActualHashMatches), N' simple statement(s) there carry this query_hash, the plan cache holds ',
                                        CONVERT(NVARCHAR(10), app.CacheSameHashStatements), N'), so it would describe other statements too')
                                 ELSE N'not captured (LAST_QUERY_PLAN_STATS is OFF, or the engine predates SQL Server 2019)' END, @NL)
                END)

          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- WHAT THIS DIAGNOSTIC CONCLUDED ---', @NL,
                N'Severity score : ', COALESCE(CONVERT(NVARCHAR(10), sb.SniffingSeverityScore), N'(n/a)'),
                                      N' out of a possible ', COALESCE(CONVERT(NVARCHAR(10), sb.SniffingSeverityScoreCeiling), N'(n/a)'),
                                      N'   (band: ', COALESCE(sb.SniffingSeverityBand, N'(n/a)'), N')', @NL,
                N'                 Read the score against that CEILING, not against 100. The ceiling ',
                N'drops below 100 when a signal could not be evaluated on this engine.', @NL,
                N'Signals fired  : ', COALESCE(sb.SniffingSeveritySignals, N'(none -- every evaluated signal came back Stable)'), @NL,

                N'Signals scored : ', CONVERT(NVARCHAR(10), (CASE WHEN sb.PlanStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.PlanShapeStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.MemoryGrantStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.ParallelismStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.OperatorSkewStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.SpillStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.IOVarianceStability IN ('Stable','Unstable') THEN 1 ELSE 0 END)), N' of 7 produced a verdict', @NL,
                N'Not evaluated  : ', CONVERT(NVARCHAR(10), 7 - (CASE WHEN sb.PlanStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.PlanShapeStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.MemoryGrantStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.ParallelismStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.OperatorSkewStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.SpillStability IN ('Stable','Unstable') THEN 1 ELSE 0 END + CASE WHEN sb.IOVarianceStability IN ('Stable','Unstable') THEN 1 ELSE 0 END)), N' of 7 -- ',
                    CONVERT(NVARCHAR(10), (CASE WHEN sb.PlanStability = 'Unavailable' THEN 1 ELSE 0 END + CASE WHEN sb.PlanShapeStability = 'Unavailable' THEN 1 ELSE 0 END + CASE WHEN sb.MemoryGrantStability = 'Unavailable' THEN 1 ELSE 0 END + CASE WHEN sb.ParallelismStability = 'Unavailable' THEN 1 ELSE 0 END + CASE WHEN sb.OperatorSkewStability = 'Unavailable' THEN 1 ELSE 0 END + CASE WHEN sb.SpillStability = 'Unavailable' THEN 1 ELSE 0 END + CASE WHEN sb.IOVarianceStability = 'Unavailable' THEN 1 ELSE 0 END)), N' Unavailable (input could not be measured), ',
                    CONVERT(NVARCHAR(10), (CASE WHEN sb.PlanStability = 'N/A' THEN 1 ELSE 0 END + CASE WHEN sb.PlanShapeStability = 'N/A' THEN 1 ELSE 0 END + CASE WHEN sb.MemoryGrantStability = 'N/A' THEN 1 ELSE 0 END + CASE WHEN sb.ParallelismStability = 'N/A' THEN 1 ELSE 0 END + CASE WHEN sb.OperatorSkewStability = 'N/A' THEN 1 ELSE 0 END + CASE WHEN sb.SpillStability = 'N/A' THEN 1 ELSE 0 END + CASE WHEN sb.IOVarianceStability = 'N/A' THEN 1 ELSE 0 END)), N' N/A (the comparison does not apply to this row).',
                    N' The SignalsUnavailable column reports only the first of those two numbers.', @NL,
                N'Root cause hint: ', COALESCE(sb.RootCauseHint, N'(none)'), @NL,
                N'Suggested path : ', COALESCE(sb.SuggestedRemediationPath, N'(none)'), @NL,
                N'Plan-forcing candidate: ', COALESCE(sb.PlanForcingCandidate, N'(n/a)'), @NL,
                N'Dominant wait when duration >> CPU: ', COALESCE(sb.HighDurationLowCpu_DominantWaitCategory,
                    N'(not flagged -- CPU accounts for most of this statement''s duration)'), @NL)

          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- STABILITY MATRIX (the 7 scored signals) ---', @NL,
                N'  PlanStability        (25 pts): ', COALESCE(sb.PlanStability, N'(n/a)'),
                    N'   [tests: more than one plan in the window]', @NL,
                N'  PlanShapeStability   (15 pts): ', COALESCE(sb.PlanShapeStability, N'(n/a)'),
                    N'   [tests: cached plan hash vs Query Store plan hash]', @NL,
                N'  MemoryGrantStability (15 pts): ', COALESCE(sb.MemoryGrantStability, N'(n/a)'),
                    N'   [tests: compile-time SerialDesiredMemory vs actual]', @NL,
                N'  ParallelismStability (10 pts): ', COALESCE(sb.ParallelismStability, N'(n/a)'),
                    N'   [tests: estimated vs actual parallel flag]', @NL,
                N'  OperatorSkewStability(15 pts): ', COALESCE(sb.OperatorSkewStability, N'(n/a)'),
                    N'   [tests: actual vs estimated rows, symmetric ratio]', @NL,
                N'  SpillStability       (10 pts): ', COALESCE(sb.SpillStability, N'(n/a)'),
                    N'   [tests: tempdb spills recorded against this plan]', @NL,
                N'  IOVarianceStability  (10 pts): ', COALESCE(sb.IOVarianceStability, N'(n/a)'),
                    N'   [tests: worst plan avg IO vs best plan avg IO]', @NL,
                N'Each [tests: ...] above says what that signal MEASURES -- it is not a statement about ',
                N'this row. The verdict is the single word before it.', @NL,
                N'  Stable / Unstable  the signal was evaluated and this is its verdict.', @NL,
                N'  Unavailable        the engine or the capture could not supply the input. NOT a pass ',
                N'-- it scores 0 and lowers the ceiling.', @NL,
                N'  N/A                the comparison does not apply to this row (for example, variance ',
                N'BETWEEN plans when only one plan exists). Also scores 0 and also lowers the ceiling.', @NL,

                CASE WHEN sb.MemoryGrantFeedbackState IS NOT NULL
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), @NL, N'Memory grant feedback state: ', sb.MemoryGrantFeedbackState, @NL,
                                 CASE WHEN sb.MemoryGrantFeedbackNote IS NOT NULL
                                      THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'  ', sb.MemoryGrantFeedbackNote, @NL)
                                      ELSE N'' END)
                     ELSE N'' END)

          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- THIS ROW''S PLAN IN CONTEXT ([QS] last ', CONVERT(NVARCHAR(10), @LookbackDays), N' day(s)) ---', @NL,
                N'Executions of this plan : ', COALESCE(CONVERT(NVARCHAR(30), sb.TotalExecutions), N'(n/a)'),
                    N'   (~', COALESCE(CONVERT(NVARCHAR(30), TRY_CAST(COALESCE(sb.TotalExecutions, 0) * 1.0 / NULLIF(@LookbackDays, 0) AS DECIMAL(18,2))), N'n/a'), N'/day)', @NL,
                N'Plans for the statement : ', COALESCE(CONVERT(NVARCHAR(10), sb.PlanCount), N'(n/a)'),
                    N'   worst plan avg reads ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(sb.WorstPlanAvgIO AS DECIMAL(38,2))), N'(n/a)'),
                    N'   best plan avg reads ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(sb.BestPlanAvgIO AS DECIMAL(38,2))), N'(n/a)'), @NL,
                N'IO variance ratio       : ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(CASE WHEN sb.BestPlanAvgIO > 0 THEN sb.WorstPlanAvgIO / sb.BestPlanAvgIO END AS DECIMAL(38,2))),
                         N'(n/a -- best plan avg IO is 0 or unknown)'), N'   (the worst plan''s average reads over the best plan''s)', @NL,
                CASE WHEN sb.MaxRowcount > sb.MinRowcount
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                            N'Rows returned by this ONE plan range from ', CONVERT(NVARCHAR(30), sb.MinRowcount), N' to ',
                            CONVERT(NVARCHAR(30), sb.MaxRowcount), N' across its executions -- a wide spread on one plan is ',
                            N'the classic shape of a sniffing-sensitive predicate.', @NL)
                     ELSE N'' END,
                N'Best observed plan_id for forcing: ', COALESCE(CONVERT(NVARCHAR(30), sb.BestPlanID), N'(none identified)'), @NL)

          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- ESTIMATE vs ACTUAL FOR THIS ROW''S PLAN ---', @NL,
                N'Rows          : [PLAN] estimated ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.EstStatementRows AS DECIMAL(38,0))), N'not captured'),
                    N' ; [QS] measured avg ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.AvgRowcount AS DECIMAL(38,0))), N'not captured'), N' (min ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.MinRowcount AS DECIMAL(38,0))), N'not captured'), N', max ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.MaxRowcount AS DECIMAL(38,0))), N'not captured'), N')',
                    N' ; [ACTUAL] ', CASE WHEN app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1
                                         THEN COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(sb.CacheActualRows AS DECIMAL(38,0))), N'not captured') ELSE N'not captured for this plan' END, @NL,
                N'Memory        : [PLAN] desired at compile ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(sb.EstimatedMemoryGrant AS DECIMAL(38,0))), N'not captured'), N' KB',
                    N' ; [QS] max used ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.MaxUsedMemoryKB AS DECIMAL(38,0))), N'not captured'), N' KB',
                    N' ; [ACTUAL] ', CASE WHEN app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1
                                         THEN CASE WHEN app.ActualGrantedKB IS NULL THEN N'no memory grant'
                                                   ELSE CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'granted ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.ActualGrantedKB AS DECIMAL(38,0))), N'not captured'),
                                                               N' KB, max used ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.ActualMaxUsedKB AS DECIMAL(38,0))), N'not captured'), N' KB') END
                                         ELSE N'not captured for this plan' END, @NL,
                N'Parallelism   : [PLAN] ', CASE WHEN app.IsParallel = 1 THEN N'parallel' WHEN app.IsParallel = 0 THEN N'serial' ELSE N'not captured' END,
                    N' ; [QS] max DOP ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.MaxDop AS DECIMAL(38,0))), N'not captured'),
                    N' ; [ACTUAL] ', CASE WHEN app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1
                                         THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'DOP ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(app.ActualDop AS DECIMAL(38,0))), N'not captured')) ELSE N'not captured for this plan' END, @NL)
    FROM #Results r
    JOIN #ScoredBanded sb
        ON sb.query_id = r.query_id AND sb.plan_id = r.plan_id
    LEFT JOIN #TableCandidates tc
        ON tc.AIPromptTcRowId = r.AIPromptTcRowId
    LEFT JOIN #AIPromptPlan app
        ON app.query_id = sb.query_id AND app.plan_id = sb.plan_id
    WHERE r.DatabaseName = @DatabaseName
      AND @AI = 2;

    -- [AI Prompt], part 4 of 4: table access path through the ask
    UPDATE r
    SET    r.AIPromptText = r.AIPromptText
          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- TABLE ACCESS PATH ON THIS ROW ---', @NL,
                CASE WHEN tc.TableNameRaw IS NULL THEN
                    CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'None. No table could be attributed from this plan, so there is no index ',
                           N'analysis on this row. That usually means the plan has no seek predicate, no ',
                           N'scan residual predicate and no Filter predicate naming a base table.', @NL)
                ELSE
                    CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                        N'Table        : ', COALESCE(tc.TableSchemaRaw, N''), N'.', COALESCE(tc.TableNameRaw, N''), @NL,

                        N'Access path  : ', COALESCE(tc.KeyScope, N'(n/a)'), @NL,
                        CASE WHEN COALESCE(tc.AccessPathsOnThisTable, 0) > 1
                             THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                    N'               This table is read ', CONVERT(NVARCHAR(10), tc.AccessPathsOnThisTable),
                                    N' times in this plan and EACH access gets its own row and its own prompt. ',
                                    N'They are different indexes, not a repeat -- a key lookup, for instance, ',
                                    N'wants one index for the seek and the clustering key for the lookup. Judge ',
                                    N'this one on its own; do not assume the others are the same.', @NL)
                             ELSE N'' END,

                        N'Access IO    : actual ', CASE WHEN app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1 AND tc.AccessHasActualReads = 1 THEN COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(tc.AccessActualIO AS DECIMAL(38,6))), N'(n/a)') WHEN app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1 THEN N'not recorded (the last actual plan carries no I/O counters)' ELSE N'not captured' END,
                            N'   estimated ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(tc.AccessEstimateIO AS DECIMAL(38,6))), N'(n/a)'), @NL,
                        N'Access rows  : actual ', CASE WHEN app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1 THEN COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(tc.AccessActualRows AS DECIMAL(38,2))), N'(n/a)') ELSE N'not captured' END,
                            N'   estimated ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(tc.AccessEstimateRows AS DECIMAL(38,2))), N'(n/a)'),
                            N'   <- THIS access path''s own figures. The Total/Worst lines below are the whole table''s.', @NL,
                        N'Rank         : ', COALESCE(CONVERT(NVARCHAR(10), tc.TableRank), N'(n/a)'),
                            N' of ', CONVERT(NVARCHAR(10), (SELECT COUNT(*) FROM #TableCandidates tc2
                                                            WHERE tc2.object_name = sb.object_name
                                                              AND tc2.query_id    = sb.query_id
                                                              AND tc2.plan_id     = sb.plan_id)),
                            N' candidate table(s) in this plan, ranked by @IndexRecommendationMode = ''',
                            @IndexRecommendationMode, N'''', @NL,
                        N'               (Other tables in this plan, and other access paths on THIS table, ',
                        N'appear on their own rows of this result set. This prompt covers the one access ',
                        N'named above. Ranking selects a TABLE; every access path of the selected table ',
                        N'then gets a recommendation.)', @NL,
                        N'Estimated size: ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(tc.EstimatedTableSizeMB AS DECIMAL(38,2))), N'(n/a)'), N' MB', @NL,
                        N'Total IO     : actual ', CASE WHEN app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1 AND tc.AnyActualReads = 1 THEN COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(tc.TotalActualIO AS DECIMAL(38,2))), N'(n/a)') WHEN app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1 THEN N'not recorded (the last actual plan carries no I/O counters)' ELSE N'not captured' END,
                            N'   estimated ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(tc.TotalEstimateIO AS DECIMAL(38,2))), N'(n/a)'), @NL,
                        N'Worst skew   : ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(tc.WorstSkewRatio AS DECIMAL(38,2))), N'(n/a)'), N'x', @NL,
                        N'Spills       : ', COALESCE(CONVERT(NVARCHAR(10), tc.SpillEventCount), N'0'),
                            N' event(s), worst level ', COALESCE(CONVERT(NVARCHAR(10), tc.WorstSpillLevel), N'(n/a)'),
                            N', detected via ', COALESCE(tc.SpillDetectionSource, N'(n/a)'), @NL,
                        N'Statistics that lead on this row''s key or predicate columns [STATS] (server time):', @NL,
                        COALESCE((
                            SELECT CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                N'  ', sf.StatsName, N' on ', QUOTENAME(sf.LeadingColumn),
                                CASE WHEN sf.IsIndexStatistics = 1 THEN N' (index)' ELSE N'' END,
                                N' : updated ', COALESCE(CONVERT(NVARCHAR(19), sf.LastUpdated, 120), N'never'),
                                N', ', COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(sf.RowsInTable AS DECIMAL(38,0))), N'not captured'), N' rows, sampled ',
                                COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(sf.RowsSampled * 100.0 / NULLIF(sf.RowsInTable, 0) AS DECIMAL(38,1))), N'not captured'), N'%, ',
                                COALESCE(CONVERT(NVARCHAR(50), TRY_CAST(sf.ModificationCounter AS DECIMAL(38,0))), N'not captured'), N' modification(s) since',
                                CASE WHEN sf.NoRecompute = 1 THEN N', NORECOMPUTE' ELSE N'' END, @NL)
                            FROM #StatsFreshness sf
                            WHERE sf.TableSchemaRaw = tc.TableSchemaRaw
                              AND sf.TableNameRaw   = tc.TableNameRaw
                              AND CHARINDEX(QUOTENAME(sf.LeadingColumn), CONCAT(tc.PredicateColumns, N',', tc.KeyColumns)) > 0
                            ORDER BY sf.StatsName
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'),
                            CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'  none found that lead on these columns', @NL)),
                        N'Columns the plan implies for an index on this table:', @NL,
                        N'  key     : ', COALESCE(tc.KeyColumns, N'(none extractable)'),
                            N'   [', COALESCE(CONVERT(NVARCHAR(10), tc.KeyColumnCount), N'0'), N' column(s), ',
                            COALESCE(CONVERT(NVARCHAR(10), tc.KeyByteSize), N'?'), N' bytes]', @NL,
                        N'  include : ', COALESCE(tc.IncludeColumns, N'(none)'), @NL,
                        N'  from predicates: ', COALESCE(tc.PredicateColumns, N'(none)'), @NL,
                        N'  from joins     : ', COALESCE(tc.JoinColumns, N'(none)'), @NL,
                        N'  from group by  : ', COALESCE(tc.GroupByColumns, N'(none)'), @NL,
                        N'  from order by  : ', COALESCE(tc.OrderByColumns, N'(none)'), @NL,
                        CASE WHEN tc.ExcludedKeyColumns IS NOT NULL
                             THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'  EXCLUDED from the key (type-ineligible): ', tc.ExcludedKeyColumns, @NL) ELSE N'' END,
                        CASE WHEN tc.ExcludedIncludeColumns IS NOT NULL
                             THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'  EXCLUDED from include: ', tc.ExcludedIncludeColumns, @NL) ELSE N'' END,
                        -- ExcludedIncludeColumns above already carries a computed column that
                        -- COULD NOT be added, with a specific reason (7c) -- this only flags the
                        -- ones that WERE added, so a reader does not mistake a derived value for a
                        -- stored one.
                        CASE WHEN tc.ComputedIncludeColumns IS NOT NULL
                             THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                      N'  Note: ', tc.ComputedIncludeColumns, N' in the include list above ',
                                      CASE WHEN tc.ComputedIncludeColumns LIKE '%,%'
                                           THEN N'are computed columns'
                                           ELSE N'is a computed column' END,
                                      N' -- not stored on the base table, computed on the fly ',
                                      N'and materialized only inside this index.', @NL)
                             ELSE N'' END,
                        N'  The key order above is a heuristic (predicate -> join -> group -> order). Plan XML ',
                        N'does not expose selectivity, so leading-column choice is exactly the kind of judgement ',
                        N'I want you to second-guess.', @NL,

                        N'  Key-vs-include for JOIN columns followed @JoinColumnKeyPolicy = ''',
                        @JoinColumnKeyPolicy, N''' -- ',
                        CASE WHEN @JoinColumnKeyPolicy = 'S'
                             THEN N'only join columns the plan actually seeks or sorts on became keys. A merge '
                                + N'join needs ordered inputs so its columns are keys; a hash join scans and '
                                + N'hashes, seeking on nothing, so its columns became INCLUDEs; nested-loops '
                                + N'correlated columns are produced by the outer side, so they became INCLUDEs '
                                + N'too. This is why "from joins" below may name a column absent from the key.'
                             ELSE N'every join column became a key column regardless of whether the plan seeks '
                                + N'or sorts on it. Expect wider keys than the plan strictly needs.' END, @NL)
                END)

          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- WHAT THE TOOL RECOMMENDS ---', @NL,
                N'Index urgency: ',
                CASE
                    WHEN tc.KeyColumns IS NULL OR NOT (@IndexRecommendationMode = 'A' OR tc.TableRank = 1)
                        THEN N'no index recommendation was generated for this row -- see the '
                           + N'BaseIndexCreateSQL column, which states why'
                    WHEN sb.TriggerIOVariance + sb.TriggerHighLogicalReads + sb.TriggerCardinalitySkew = 0
                        THEN N'INFORMATIONAL -- no severity trigger fired. This is the index the '
                           + N'predicates imply, not an urgent fix. Judge it on merit.'
                    ELSE CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'ACT ON THIS -- triggered by:',
                            CASE WHEN sb.TriggerIOVariance = 1
                                 THEN N' [IO variance past ' + CONVERT(NVARCHAR(20), @IOVarianceRecommendationThreshold) + N'x]' ELSE N'' END,
                            CASE WHEN sb.TriggerHighLogicalReads = 1
                                 THEN N' [avg logical reads past ' + CONVERT(NVARCHAR(20), @HighIOLogicalReadsThreshold) + N']' ELSE N'' END,
                            CASE WHEN sb.TriggerCardinalitySkew = 1
                                 THEN N' [cardinality skew past ' + CONVERT(NVARCHAR(20), @CardinalitySkewThreshold) + N'x]' ELSE N'' END)
                END, @NL,
                CASE WHEN tc.CandidateIndexName IS NOT NULL
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'Proposed index name: ', tc.CandidateIndexName, @NL) ELSE N'' END,
                N'The runnable (commented-out) CREATE INDEX text for this row is in the ',
                N'BaseIndexCreateSQL column -- paste it in alongside this prompt if you want it ',
                N'reviewed verbatim. It is never executed by this tool.', @NL, @NL,
                N'Recompile vs plan forcing: ',
                CASE
                    WHEN NOT (sb.PlanStability = 'Unstable' OR sb.PlanShapeStability = 'Unstable'
                              OR sb.MemoryGrantStability = 'Unstable' OR sb.OperatorSkewStability = 'Unstable'
                              OR sb.SpillStability = 'Unstable')
                        THEN N'not offered -- no plan-instability signal fired, so recompiling is not the '
                           + N'relevant lever here.'
                    WHEN (COALESCE(sb.TotalExecutions, 0) * 1.0) / NULLIF(@LookbackDays, 0) > @HighFrequencyExecutionsPerDayThreshold
                        THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'execution rate is ABOVE the ',
                                CONVERT(NVARCHAR(20), @HighFrequencyExecutionsPerDayThreshold),
                                N'/day threshold, so OPTION(RECOMPILE) on every call is likely too costly. ',
                                N'The tool points at forcing plan_id ',
                                COALESCE(CONVERT(NVARCHAR(30), sb.BestPlanID), N'(none identified)'),
                                N' via sp_query_store_force_plan, or OPTIMIZE FOR a dominant value.')
                    ELSE CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'execution rate is BELOW the ',
                            CONVERT(NVARCHAR(20), @HighFrequencyExecutionsPerDayThreshold),
                            N'/day threshold, so a per-call OPTION(RECOMPILE) is likely affordable. Full text ',
                            N'is in the RecommendedRecompileSQL column.')
                END, @NL)

          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- EXECUTION PLAN FOR THIS ROW''S PLAN ---', @NL,
                CASE
                    WHEN @AIPromptIncludePlanXml = 0
                        THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'Not embedded (@AIPromptIncludePlanXml = 0). The compile-time plan is in ',
                                    N'this row''s EstimatedPlanXML column',
                                    CASE WHEN app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1
                                         THEN N', and its last actual plan is in CacheActualPlanXML' ELSE N'' END,
                                    N'. Paste one in if you want the plan itself analysed.')
                    WHEN app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1 AND sb.CacheActualPlanXML IS NOT NULL
                         AND DATALENGTH(CAST(sb.CacheActualPlanXML AS NVARCHAR(MAX))) / 2 <= @AIPromptPlanXmlMaxChars
                        THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                    N'[ACTUAL] this plan''s last actual execution plan (actual rows per operator and DOP; ',
                                    N'no runtime parameter values):', @NL,
                                    CAST(sb.CacheActualPlanXML AS NVARCHAR(MAX)))
                    WHEN sb.EstimatedPlanXML IS NULL
                        THEN N'No plan XML is available for this row: the plan Query Store stored could not be read as XML -- most often because it is nested deeper than the 128 levels SQL Server''s xml type allows. Nothing above that says not captured was measured.'
                    WHEN DATALENGTH(CAST(sb.EstimatedPlanXML AS NVARCHAR(MAX))) / 2 > @AIPromptPlanXmlMaxChars
                        THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'OMITTED DELIBERATELY, NOT TRUNCATED. This plan is ',
                                    CONVERT(NVARCHAR(30), DATALENGTH(CAST(sb.EstimatedPlanXML AS NVARCHAR(MAX))) / 2),
                                    N' characters, over the @AIPromptPlanXmlMaxChars limit of ',
                                    CONVERT(NVARCHAR(20), @AIPromptPlanXmlMaxChars),
                                    N'. Half a plan is worse than none -- you would reason confidently about ',
                                    N'operators you cannot see. Raise the limit, or paste EstimatedPlanXML in yourself.')
                    ELSE CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                N'[PLAN] the compile-time plan Query Store stored for this row (estimates only',
                                CASE WHEN app.CacheAttributionDeclined = 1 THEN N'; the plan cache could not be matched to this row, so no actual plan is used'
                                     WHEN app.IsCachedPlan = 1 AND app.CacheActualPlanDeclined = 1 THEN N'; its last actual plan could not be isolated from the procedure''s, so none is used'
                                     WHEN app.IsCachedPlan = 1 THEN N'; the plan cache holds no actual plan for it'
                                     ELSE N'; it is not the plan in cache, so no actual plan exists for it' END,
                                N'):', @NL,
                                CAST(sb.EstimatedPlanXML AS NVARCHAR(MAX)))
                END, @NL)

          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- READ THESE BEFORE CONCLUDING ANYTHING ---', @NL,
                CASE WHEN sb.SignalsUnavailable > 0
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'* ', CONVERT(NVARCHAR(10), sb.SignalsUnavailable),
                                 N' of 7 signals could not be evaluated, so the score comes from a ceiling of ',
                                 COALESCE(CONVERT(NVARCHAR(10), sb.SniffingSeverityScoreCeiling), N'?'),
                                 N' rather than 100. A low score here is partly an absence of evidence, not ',
                                 N'evidence of absence.', @NL) ELSE N'' END,
                CASE WHEN sb.MixedCEModelAcrossPlans = 'Yes'
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'* THE PLANS FOR THIS query_id STRADDLE TWO CARDINALITY-ESTIMATION MODELS. ',
                                 N'Compatibility level changed while Query Store still held older plans. ',
                                 N'EstimatedRows is not comparable across them, so the skew, memory-grant and ',
                                 N'IO-variance readings may be measuring a compat change rather than parameter ',
                                 N'sensitivity -- and PlanCount > 1 has an explanation unrelated to sniffing.', @NL)
                     ELSE N'' END,
                CASE WHEN sb.PspoRole = N'Variant'
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                 N'* THIS ROW IS ONE PARAMETER SENSITIVE PLAN VARIANT, not the whole statement. ',
                                 N'The engine split this statement into ',
                                 COALESCE(CONVERT(NVARCHAR(10), sb.PspoVariantCount), N'several'),
                                 N' variants, one per cardinality range, because it found the predicate ',
                                 N'skewed. So the engine ALREADY treats this statement as parameter sensitive: ',
                                 N'the question is not whether to act, but whether this variant''s own plan is ',
                                 N'right for its own range. Its siblings are the other rows sharing parent ',
                                 N'query_id ', COALESCE(CONVERT(NVARCHAR(20), sb.PspoParentQueryId), N'(unknown)'),
                                 N'. Plan-cache figures read Unavailable here by design -- a variant runs as a ',
                                 N'prepared statement whose cache identity is not the procedure''s, so matching ',
                                 N'one would be a guess. A recompile hint is usually the WRONG answer for a ',
                                 N'variant: the engine is already doing what a hint would force.', @NL)
                     ELSE N'' END,
                CASE WHEN sb.PlanUsesLegacyCE = 'Yes'
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'* THIS PLAN WAS COMPILED BY THE LEGACY CARDINALITY ESTIMATOR (model 70)',
                                 CASE WHEN @DatabaseCompatibilityLevel <= 110
                                      THEN N' -- the database is at compatibility level '
                                           + CONVERT(NVARCHAR(10), @DatabaseCompatibilityLevel)
                                      WHEN @LegacyCEDatabaseSetting LIKE N'ON%'
                                      THEN N' -- LEGACY_CARDINALITY_ESTIMATION is ON for this database, whose compatibility level is '
                                           + COALESCE(CONVERT(NVARCHAR(10), @DatabaseCompatibilityLevel), N'(unknown)')
                                      ELSE N' -- neither the compatibility level nor LEGACY_CARDINALITY_ESTIMATION accounts for it, so the statement itself carries USE HINT(''FORCE_LEGACY_CARDINALITY_ESTIMATION'') or trace flag 9481' END,
                                 N'. Its row estimates come from the 2012-era model, so the cardinality-derived readings -- ',
                                 N'OperatorSkewStability, MemoryGrantStability and the IO-variance ratio -- fire more often for ',
                                 N'estimator reasons here than for parameter sniffing. Measured on this project''s own workload: ',
                                 N'16 rows read skew Unstable under CE 70 against 12 under CE 150, and the four extra were the older ',
                                 N'model''s estimates crossing the threshold on statements the current one estimates well. Read the ',
                                 N'ESTIMATE vs ACTUAL figures above before calling this parameter sniffing.', @NL)
                     ELSE N'' END,
                CASE WHEN NOT (app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1)
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'* No actual execution plan ',
                                 CASE WHEN app.CacheAttributionDeclined = 1 OR (app.IsCachedPlan = 1 AND app.CacheActualPlanDeclined = 1)
                                      THEN N'can be attributed to' ELSE N'exists for' END,
                                 N' THIS row''s plan -- the LIVE PLAN CACHE ',
                                 N'section says why -- so every [ACTUAL] figure is "not captured" and the estimate-vs-actual ',
                                 N'comparison rests on Query Store''s measured runtime instead.', @NL)
                     ELSE N'' END,
                CASE WHEN sb.PlanCount = 1
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'* Only ONE plan exists in this window. Parameter sniffing can still be ',
                                 N'happening -- a single bad plan reused for every parameter value is the ',
                                 N'textbook case -- but there is no plan-to-plan comparison available here.', @NL)
                     ELSE N'' END,
                CASE WHEN COALESCE(sb.TotalExecutions, 0) < 10
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'* Only ', COALESCE(CONVERT(NVARCHAR(30), sb.TotalExecutions), N'0'),
                                 N' execution(s) in the window. The averages above are thin -- treat them as ',
                                 N'indicative, not as a stable baseline.', @NL)
                     ELSE N'' END,
                CASE WHEN app.IsCachedPlan = 1 AND sb.CacheActualPlanAvailable = 1 AND sb.CacheActualParallelismFlag = 1
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'* This plan ran in PARALLEL. Actual row and IO figures are summed across ',
                                 N'RunTimeCountersPerThread for every thread. That is the standard convention, ',
                                 N'but it is flagged in this project as not yet verified against a captured ',
                                 N'parallel spilling plan -- so treat the actual-side numbers on this row with ',
                                 N'more caution than the serial ones.', @NL)
                     ELSE N'' END,
                CASE WHEN @QueryCaptureMode = N'AUTO'
                     THEN CONCAT(CAST(N'' AS NVARCHAR(MAX)), N'* QUERY_CAPTURE_MODE is AUTO, so cheap and infrequent statements are ',
                                 N'filtered out by internal thresholds. The absence of a statement is NOT ',
                                 N'evidence it did not run -- do not conclude this procedure has only the ',
                                 N'statements you can see.', @NL)
                     ELSE N'' END,
                N'* Query Store aggregates per interval. Averages here are execution-weighted across the ',
                N'window and can hide a bimodal distribution -- which is exactly what parameter sniffing ',
                N'produces. A "moderate" average may be two very different populations.', @NL,
                N'* Every recommendation this tool emits is commented-out text for human review. Nothing ',
                N'has been executed against this database.', @NL)

          + CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                @NL, N'--- ANSWER WITH ---', @NL,
                N'1. Diagnosis. Is this parameter sniffing? Commit to the most likely cause and name the figures above ',
                N'that drove it -- compare the plans'' compiled parameter values, shapes and measured runtime. If it is ',
                N'something else (stale statistics, a missing index, blocking, implicit conversion, a non-SARGable ',
                N'predicate, row-goal trouble), say which and why.', @NL,
                N'2. If it IS sniffing: which parameter, and which compiled values above show the skew.', @NL,
                N'3. The ONE change to make first: its exact T-SQL, the T-SQL that rolls it back, and why it beats ',
                N'RECOMPILE / OPTIMIZE FOR / forcing a plan / an index / a rewrite / a statistics fix for THIS statement.', @NL,
                N'4. How to verify it worked: the exact query to run afterwards, and the result that proves it.', @NL,
                N'5. Your read on the proposed index: is the key column order right, and would you move anything ',
                N'between key and include?', @NL,
                N'6. If the evidence truly cannot support a decision: the single missing fact, and the exact query ',
                N'that collects it. Do not stop at "cannot tell".', @NL,
                N'7. Anything above that looks internally inconsistent or too good to be true. I would rather hear ',
                N'that the tool is wrong than get a confident answer built on a bad reading.', @NL)
    FROM #Results r
    JOIN #ScoredBanded sb
        ON sb.query_id = r.query_id AND sb.plan_id = r.plan_id
    LEFT JOIN #TableCandidates tc
        ON tc.AIPromptTcRowId = r.AIPromptTcRowId
    LEFT JOIN #AIPromptPlan app
        ON app.query_id = sb.query_id AND app.plan_id = sb.plan_id
    WHERE r.DatabaseName = @DatabaseName
      AND @AI = 2;

    IF @ShowModeComparison = 1
    BEGIN
        ;WITH CandidateCounts AS (
            SELECT object_name, query_id, plan_id, COUNT(*) AS CandidateTableCount
            FROM #TableCandidates
            GROUP BY object_name, query_id, plan_id
        ),
        Winners AS (
            SELECT
                object_name, query_id, plan_id,
                MAX(CASE WHEN TableRankB = 1 THEN ISNULL(TableSchemaRaw + '.', '') + ISNULL(TableNameRaw, '') END) AS ModeB_Winner,
                MAX(CASE WHEN TableRankC = 1 THEN ISNULL(TableSchemaRaw + '.', '') + ISNULL(TableNameRaw, '') END) AS ModeC_Winner,
                MAX(CASE WHEN TableRankD = 1 THEN ISNULL(TableSchemaRaw + '.', '') + ISNULL(TableNameRaw, '') END) AS ModeD_Winner
            FROM #TableCandidates
            GROUP BY object_name, query_id, plan_id
        )
        INSERT INTO #ModeResults
        SELECT
            @DatabaseName,
            tc.object_name,
            tc.query_id,
            tc.plan_id,
            ISNULL(tc.TableSchemaRaw + '.', '') + ISNULL(tc.TableNameRaw, '') AS TableName,
            cc.CandidateTableCount,
            tc.TableRankB,  tc.ModeB_RankedIO,
            tc.TableRankC,  tc.ModeC_RankedSkew,
            tc.TableRankD,  tc.ModeD_RankedSpill,
            w.ModeB_Winner,
            w.ModeC_Winner,
            w.ModeD_Winner,
            CASE
                WHEN cc.CandidateTableCount = 1 THEN 'Single candidate table'
                WHEN w.ModeB_Winner = w.ModeC_Winner AND w.ModeC_Winner = w.ModeD_Winner THEN 'All three agree'
                WHEN w.ModeB_Winner = w.ModeC_Winner OR w.ModeC_Winner = w.ModeD_Winner
                  OR w.ModeB_Winner = w.ModeD_Winner THEN 'Partial agreement'
                ELSE 'B/C/D disagree'
            END AS ModeAgreement,

            CASE WHEN MIN(tc.ModeB_RankedIO)    OVER (PARTITION BY tc.object_name, tc.query_id, tc.plan_id)
                    = MAX(tc.ModeB_RankedIO)    OVER (PARTITION BY tc.object_name, tc.query_id, tc.plan_id)
                 THEN 'Yes' ELSE 'No' END AS ModeB_InputIsFlat,
            CASE WHEN MIN(tc.ModeC_RankedSkew)  OVER (PARTITION BY tc.object_name, tc.query_id, tc.plan_id)
                    = MAX(tc.ModeC_RankedSkew)  OVER (PARTITION BY tc.object_name, tc.query_id, tc.plan_id)
                 THEN 'Yes' ELSE 'No' END AS ModeC_InputIsFlat,
            CASE WHEN MIN(tc.ModeD_RankedSpill) OVER (PARTITION BY tc.object_name, tc.query_id, tc.plan_id)
                    = MAX(tc.ModeD_RankedSpill) OVER (PARTITION BY tc.object_name, tc.query_id, tc.plan_id)
                 THEN 'Yes' ELSE 'No' END AS ModeD_InputIsFlat,

            ISNULL(tc.SpillAttributionTied, 'n/a') AS ModeD_AttributionWasTied
        FROM #TableCandidates tc
        JOIN CandidateCounts cc
            ON cc.object_name = tc.object_name AND cc.query_id = tc.query_id AND cc.plan_id = tc.plan_id
        JOIN Winners w
            ON w.object_name = tc.object_name AND w.query_id = tc.query_id AND w.plan_id = tc.plan_id
        ;
    END


    IF @Debug = 1
    BEGIN
        SELECT @Rows = COUNT(*) FROM #CacheMatch;
        RAISERROR('%s: %d statement(s) analysed', 0, 0, @DatabaseName, @Rows) WITH NOWAIT;
    END;

    SET @DatabaseName = (SELECT MIN(DatabaseName) FROM #DatabaseList WHERE DatabaseName > @DatabaseName);
    END;   -- per-database loop

    /*  [AI Prompt] is finished here, not inside the INSERT: inline, the 29 nested REPLACEs made that
        statement's plan 148 levels deep, past the 128 the xml type allows, so any tool converting
        this database's Query Store plans to xml failed on it with Msg 6335 (measured 2026-09-14 --
        the index-analysis gate). Same text, same collation, same characters, so the same cells.
        TRANSLATE is not an option: 2017+, and the script's floor is 2016. See the script.         */
    UPDATE #Results
    SET    [AI Prompt] = (SELECT REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(AIPromptText COLLATE Latin1_General_BIN2, NCHAR(0), N''), NCHAR(1), N''), NCHAR(2), N''), NCHAR(3), N''), NCHAR(4), N''), NCHAR(5), N''), NCHAR(6), N''), NCHAR(7), N''), NCHAR(8), N''), NCHAR(11), N''), NCHAR(12), N''), NCHAR(14), N''), NCHAR(15), N''), NCHAR(16), N''), NCHAR(17), N''), NCHAR(18), N''), NCHAR(19), N''), NCHAR(20), N''), NCHAR(21), N''), NCHAR(22), N''), NCHAR(23), N''), NCHAR(24), N''), NCHAR(25), N''), NCHAR(26), N''), NCHAR(27), N''), NCHAR(28), N''), NCHAR(29), N''), NCHAR(30), N''), NCHAR(31), N'')
                            AS [processing-instruction(ai_prompt)] FOR XML PATH(''), TYPE);

    ALTER TABLE #Results DROP COLUMN AIPromptText, AIPromptTcRowId;

    /*======================================================================================
      OUTPUT. Severity leads the sort rather than database name: this is a triage tool, and
      the worst statement on the instance should be the first row whichever database it is in.
    ======================================================================================*/
    SELECT *
    FROM #Results
    WHERE SniffingSeverityScore >= @MinimumSeverityScore
    ORDER BY SniffingSeverityScore DESC, DatabaseName, object_name, query_id, plan_id, TableRank;

    IF @ShowModeComparison = 1
        SELECT *
        FROM #ModeResults
        ORDER BY DatabaseName, object_name, query_id, plan_id, TableRankB;

    /*  Emitted only when there is something to say. A database that was asked for and not
        analysed has to be visible, or an empty result reads as "nothing wrong here".        */
    IF EXISTS (SELECT 1 FROM #SkippedDatabases)
        SELECT DatabaseName, Reason FROM #SkippedDatabases ORDER BY DatabaseName;
END;
GO
