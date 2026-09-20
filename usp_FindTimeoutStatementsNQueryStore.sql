/*==================================================================================================
  dbo.usp_FindTimeoutStatementsNQueryStore -- COLLECTION LAYER

  Installs in a DBA utility database (DBAdmin) and reads any database on the same instance, or all
  of them. Derived from Find-TimeoutStatements_N_QueryStore_v1.sql, which remains the annotated
  reference; the reasoning behind every gate, every threshold, and every documented gotcha lives
  there, not duplicated here. Same relationship as usp_ParameterSniffingDiagnostic has to
  Paramsniffingdiagnostic_v1.sql -- cell-for-cell output equivalence against the script, run
  directly against the same database, is the acceptance test for any change to either.

  HOW IT REACHES THE TARGET
    Every collection statement runs inside a dynamic batch whose first line is USE [target].
    Unqualified catalog references then resolve in the target, so the collection SQL is character
    for character what the v1 script already runs. #AbortedStats and #AbortWaits are created here,
    in the outer scope, per iteration, because a table created inside the dynamic batch dies with
    it -- same reason usp_ParameterSniffingDiagnostic creates its own per-iteration temp tables in
    the outer scope.

    UNLIKE usp_ParameterSniffingDiagnostic, there is no separate "collect into temp tables, then
    analyse statically" split here. The v1 script's own Section 4 reads sys.query_store_plan /
    sys.query_store_query / sys.query_store_query_text LIVE, joined directly against the already-
    populated #AbortedStats/#AbortWaits -- it never materialises them into an intermediate temp
    table the way the main diagnostic's #CacheMatch does. So Section 4 ALSO runs inside the
    USE-wrapped dynamic batch here, with DB_NAME() replaced by a bound @DatabaseNameIn parameter
    (DB_NAME() inside a USE'd batch would in fact resolve correctly, but binding it explicitly
    matches this project's own hard-won rule -- DB_NAME() anywhere outside a body actually proven
    to run post-USE is a standing trap -- and costs nothing here).

  PERMISSIONS
    VIEW SERVER STATE is NOT required (this script never touches the plan cache) -- VIEW DATABASE
    STATE in each target is enough, matching what the v1 script itself needs to read Query Store.
    Intended to be certificate-signed so callers need only EXECUTE on this procedure, same
    intent as usp_ParameterSniffingDiagnostic.

  PLATFORM
    Box SQL Server and Azure SQL Managed Instance. Azure SQL Database (EngineEdition 5) cannot run
    this pattern at all -- it has no cross-database access. Same gate, same reason, as the sibling
    procedure.

  WHY THE PREFLIGHT LOOKS DIFFERENT HERE THAN IN usp_ParameterSniffingDiagnostic
    The v1 script's own preflight (its Section 1b) is not a single pass/fail gate -- it is eight
    gates, several of which are WARNINGS rather than stops (Query Store READ_ONLY, retention
    shorter than the lookback, storage near full, capture mode NONE, a read-only AG secondary,
    history coverage short of the lookback). A script run at a console can PRINT all of that; a
    procedure driven by @AllDatabases = 1 across many databases cannot rely on PRINT reaching the
    caller the same way, and printing eight lines per database per run would drown the one thing
    that matters. So the SUBSTANCE of every gate survives, but reshaped: hard stops become
    @SkipReason (RAISERROR and abort when @AllDatabases = 0; a row in #SkippedDatabases otherwise,
    exactly like usp_ParameterSniffingDiagnostic's own single @SkipReason), and everything that was
    a WARNING in the script becomes a row in #PreflightNotes -- a new accumulator this procedure
    introduces because the sibling procedure's own preflight never needed one (its gate is
    genuinely binary: Query Store is running here, usably, or it is not).

  QUOTED_IDENTIFIER/ANSI_NULLS pinned at CREATE time for the same reason as the sibling procedure:
  the XML shredding in Section 4 needs QUOTED_IDENTIFIER ON, and that is captured into the module
  permanently at deploy time, not read from the caller's session.
==================================================================================================*/
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_FindTimeoutStatementsNQueryStore
    @DatabaseName                  sysname       = NULL,   -- NULL = current database
    @AllDatabases                  BIT           = 0,      -- every online database with Query Store running
    @IncludeDatabases              NVARCHAR(MAX) = NULL,   -- comma-separated; only with @AllDatabases = 1
    @ExcludeDatabases              NVARCHAR(MAX) = NULL,   -- comma-separated; only with @AllDatabases = 1
    @ExcludeHostingDatabase        BIT           = 1,      -- skip DB_NAME() (this proc's own database) by
                                                             -- default when @AllDatabases = 1 -- same reason
                                                             -- as the sibling procedure: this proc's own
                                                             -- analytical queries would otherwise pollute
                                                             -- its own Query Store and be reported back.
    @LookbackDays                  INT           = 7,
    @MinAbortedExecutions          INT           = 1,      -- raise to hide one-off aborts
    @TopN                          INT           = 50,     -- row cap PER DATABASE, ordered by worst max duration
    @IncludeExceptionAborts        BIT           = 0,      -- 1 also returns execution_type 4 (errors)
    @TargetObjectName              NVARCHAR(776) = NULL,   -- NULL = every object. Resolved PER DATABASE inside
                                                             -- the loop (unlike the script, which resolves it
                                                             -- once against the single connected database) --
                                                             -- a name that fails to resolve in one database is
                                                             -- a per-database skip when @AllDatabases = 1, and
                                                             -- a hard abort when it is not.
    @IncludeSecondaryReplicas      BIT           = 1,      -- see the v1 script's own header
    @HistoryCoverageWarnPercent    INT           = 90,     -- see the v1 script's own Gate 8
    @Debug                         BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @Sql            NVARCHAR(MAX),
        @Use            NVARCHAR(MAX),
        @DbQuoted       sysname,
        @DbId           INT,
        @EngineEdition  INT = TRY_CAST(SERVERPROPERTY('EngineEdition') AS INT),
        @Since          DATETIME2(7),
        @DbCount        INT,
        @Rows           INT,
        @SkipReason     NVARCHAR(400),
        @Msg            NVARCHAR(2000),
        @TargetObjectId INT;

    /*  Same gate, same reason, as usp_ParameterSniffingDiagnostic: Azure SQL Database has no
        cross-database access, so this whole USE-[target] pattern cannot work there at all.       */
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

    /*======================================================================================
      DATABASE TARGETING -- verbatim from usp_ParameterSniffingDiagnostic. Generically reusable,
      not specific to what either procedure analyses; kept identical rather than reinvented so the
      two procedures behave the same way for the same @DatabaseName/@AllDatabases/@IncludeDatabases/
      @ExcludeDatabases/@ExcludeHostingDatabase inputs.
    ======================================================================================*/
    DROP TABLE IF EXISTS #DatabaseList;
    DROP TABLE IF EXISTS #SkippedDatabases;
    DROP TABLE IF EXISTS #PreflightNotes;
    DROP TABLE IF EXISTS #NameList;

    CREATE TABLE #DatabaseList (DatabaseName sysname NOT NULL PRIMARY KEY);
    CREATE TABLE #SkippedDatabases (DatabaseName sysname NOT NULL, Reason NVARCHAR(400) NOT NULL);
    /*  NEW relative to the sibling procedure -- see the header. Non-fatal, per-database findings
        that were PRINT warnings in the v1 script: Query Store READ_ONLY, retention shorter than
        the lookback, storage near full, capture mode NONE, a read-only AG secondary, or history
        coverage short of @LookbackDays.                                                          */
    CREATE TABLE #PreflightNotes (DatabaseName sysname NOT NULL, Note NVARCHAR(500) NOT NULL);
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

        /*  FIXED 2026-09-13: name each cause that actually applies, in the filter's own order, instead
            of one lumped message. The lumped text was reported for the HOSTING database and for names
            in @ExcludeDatabases -- two causes it did not even list -- sending the reader to look for
            an offline or read-only database that did not exist. Same defect, same fix, as
            usp_IndexAnalysis and usp_ParameterSniffingDiagnostic; TestRunners\
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

    /*======================================================================================
      RESULT ACCUMULATOR. Column list and types mirror the v1 script's own final SELECT exactly,
      with DatabaseName prepended -- same convention as usp_ParameterSniffingDiagnostic. Types
      derived from tempdb.sys.columns after a real run, not guessed -- see TestCases_v1.sql for
      the verification record if any were corrected after the first deployment.
    ======================================================================================*/
    DROP TABLE IF EXISTS #Results;

    CREATE TABLE #Results (
        [DatabaseName]                 sysname           NULL,
        [ObjectName]                   nvarchar(128)     NULL,
        [AbortedExecutions]            bigint            NULL,
        [ClientAborts]                 bigint            NULL,
        [ExceptionAborts]              bigint            NULL,
        [IntervalsAffected]            int               NULL,
        [SuccessfulExecutions]         bigint            NULL,
        [CompletionPattern]            varchar(56)       NULL,
        [TopWaitCategory]              nvarchar(128)     NULL,
        [TopWaitTotalMs]               bigint            NULL,
        [TopWaitMaxMs]                 bigint            NULL,
        [AllWaitMs]                    bigint            NULL,
        [PlansForThisQuery]            int               NULL,
        [StatementsInObject]           int               NULL,
        [query_sql_text]               nvarchar(max)     NULL,
        [StatementSubTreeCost]         float             NULL,
        [PlanCompatModel]              int               NULL,
        [QueryPlanXml]                 xml               NULL,
        [NextStep]                     varchar(100)      NULL,
        [LastAbortStartTime]           datetimeoffset(7) NULL,
        [LastAbortEndTime]             datetimeoffset(7) NULL,
        [LastAbortDurationMs]          decimal(18,2)     NULL,
        [DurationScopeNote]            varchar(405)      NULL,
        [StatementMaxDurationMs]       decimal(18,2)     NULL,
        [StatementAvgDurationMs]       decimal(18,2)     NULL,
        [StatementMaxCpuMs]            decimal(18,2)     NULL,
        [StatementMaxLogicalReads]     bigint            NULL,
        [ObjectAvgTotalMs_Approx]      decimal(18,2)     NULL,
        [PrecedingStatementCount]      int               NULL,
        [PrecedingStatementsAvgMs]     decimal(18,2)     NULL,
        [AccountedStatementMsAvg]      decimal(18,2)     NULL,
        [PctDurationBeforeAbortedStmt] decimal(5,1)      NULL,
        [object_id]                    bigint            NULL,
        [query_id]                     bigint            NULL,
        [plan_id]                      bigint            NULL,
        [query_hash]                   binary(8)         NULL,
        [query_plan_hash]              binary(8)         NULL,
        [ReplicaScope]                 nvarchar(60)      NULL
    );

    SET @Since = DATEADD(DAY, -@LookbackDays, SYSUTCDATETIME());

    /*======================================================================================
      PER-DATABASE LOOP. Watermark rather than a cursor, matching usp_ParameterSniffingDiagnostic.
    ======================================================================================*/
    SET @DatabaseName = (SELECT MIN(DatabaseName) FROM #DatabaseList);

    WHILE @DatabaseName IS NOT NULL
    BEGIN
    SET @DbId     = DB_ID(@DatabaseName);
    SET @DbQuoted = QUOTENAME(@DatabaseName);
    SET @Use      = N'USE ' + @DbQuoted + N';' + NCHAR(13) + NCHAR(10);

    DROP TABLE IF EXISTS #AbortedStats;
    DROP TABLE IF EXISTS #AbortWaits;

    /*  Same shape as the v1 script's own #AbortedStats/#AbortWaits -- see its Sections 2/3. */
    CREATE TABLE #AbortedStats (
        plan_id                  BIGINT            NOT NULL,
        AbortedExecutions        BIGINT            NULL,
        IntervalsAffected        INT               NULL,
        StatementMaxDurationMs   FLOAT             NULL,
        StatementAvgDurationMs   FLOAT             NULL,
        LastAbortEndTime         DATETIMEOFFSET(7) NULL,
        LastAbortDurationMs      FLOAT             NULL,
        StatementMaxCpuMs        FLOAT             NULL,
        StatementMaxLogicalReads BIGINT            NULL,
        ClientAborts             BIGINT            NULL,
        ExceptionAborts          BIGINT            NULL,
        ReplicaScope             NVARCHAR(60)      NULL
    );

    CREATE TABLE #AbortWaits (
        plan_id                  BIGINT       NOT NULL,
        TopWaitCategory          NVARCHAR(128) NULL,
        TopWaitTotalMs           BIGINT       NULL,
        TopWaitMaxMs             BIGINT       NULL,
        AllWaitMs                BIGINT       NULL
    );

    /*----------------------------------------------------------------------------------------
      PREFLIGHT -- runs in the target's context so every probe answers for the target, not for
      DBAdmin. Condensed from the v1 script's eight gates into output parameters; see the header
      for why the WARNING gates land in #PreflightNotes instead of PRINT.

      wait_stats_capture_mode_desc needs its OWN, second dynamic call, exactly like the v1 script's
      own Gate 6 -- an EXISTENCE check against sys.all_columns is safe inside a single compiled
      batch (it never references the column by name at compile time), but actually READING the
      column's value is not: deferred name resolution does not apply to a plain batch, the same
      reason Section 2 below has to splice its replica columns in as text rather than reference
      them unconditionally. Everything else here is safe to combine into one call.
    ----------------------------------------------------------------------------------------*/
    DECLARE
        @QsActualState        NVARCHAR(60)  = NULL,
        @QsDesiredState       NVARCHAR(60)  = NULL,
        @QsReadOnlyReason     INT           = NULL,
        @QsCaptureMode        NVARCHAR(60)  = NULL,
        @QsStaleDays          BIGINT        = NULL,
        @QsCurrentMb          BIGINT        = NULL,
        @QsMaxMb              BIGINT        = NULL,
        @HasQueryStore        BIT           = 0,
        @WaitStatsViewExists  BIT           = 0,
        @WaitCaptureColExists BIT           = 0,
        @WaitCaptureDesc      NVARCHAR(60)  = NULL,
        @ReplicaAware         BIT           = 0,
        @Updateability        NVARCHAR(128) = NULL,
        @OldestExecutionUtc   DATETIMEOFFSET(7) = NULL,
        @HistoryMinutes       BIGINT        = NULL,
        @LookbackMinutes      BIGINT        = NULL,
        @CoveragePercent      INT           = NULL;

    SET @Sql = @Use + N'
    SELECT @ActualStateOut    = dqso.actual_state_desc,
           @DesiredStateOut   = dqso.desired_state_desc,
           @ReadOnlyReasonOut = dqso.readonly_reason,
           @CaptureModeOut    = dqso.query_capture_mode_desc,
           @StaleDaysOut      = dqso.stale_query_threshold_days,
           @CurrentMbOut      = dqso.current_storage_size_mb,
           @MaxMbOut          = dqso.max_storage_size_mb
    FROM sys.database_query_store_options dqso;

    SELECT @HasQueryStoreOut       = CASE WHEN OBJECT_ID(''sys.query_store_query'')        IS NULL THEN 0 ELSE 1 END,
           @WaitStatsViewExistsOut = CASE WHEN OBJECT_ID(''sys.query_store_wait_stats'')   IS NULL THEN 0 ELSE 1 END,
           @WaitCaptureColExistsOut = CASE WHEN EXISTS (
                                          SELECT 1 FROM sys.all_columns
                                          WHERE object_id = OBJECT_ID(''sys.database_query_store_options'')
                                            AND name = ''wait_stats_capture_mode_desc'')
                                       THEN 1 ELSE 0 END,
           @ReplicaAwareOut        = CASE WHEN OBJECT_ID(''sys.query_store_replicas'') IS NOT NULL
                                           AND EXISTS (
                                               SELECT 1 FROM sys.all_columns
                                               WHERE object_id = OBJECT_ID(''sys.query_store_runtime_stats'')
                                                 AND name = ''replica_group_id'')
                                      THEN 1 ELSE 0 END,
           @UpdateabilityOut       = CAST(DATABASEPROPERTYEX(DB_NAME(), ''Updateability'') AS NVARCHAR(128));

    SELECT @OldestExecutionUtcOut = MIN(rs.first_execution_time)
    FROM sys.query_store_runtime_stats rs;

    SELECT @TargetObjectIdOut = CASE WHEN @TargetObjectNameIn IS NOT NULL THEN OBJECT_ID(@TargetObjectNameIn) END;';

    EXEC sys.sp_executesql @Sql,
        N'@TargetObjectNameIn NVARCHAR(776),
          @ActualStateOut NVARCHAR(60) OUTPUT, @DesiredStateOut NVARCHAR(60) OUTPUT,
          @ReadOnlyReasonOut INT OUTPUT, @CaptureModeOut NVARCHAR(60) OUTPUT,
          @StaleDaysOut BIGINT OUTPUT, @CurrentMbOut BIGINT OUTPUT, @MaxMbOut BIGINT OUTPUT,
          @HasQueryStoreOut BIT OUTPUT, @WaitStatsViewExistsOut BIT OUTPUT,
          @WaitCaptureColExistsOut BIT OUTPUT, @ReplicaAwareOut BIT OUTPUT,
          @UpdateabilityOut NVARCHAR(128) OUTPUT,
          @OldestExecutionUtcOut DATETIMEOFFSET(7) OUTPUT,
          @TargetObjectIdOut INT OUTPUT',
        @TargetObjectNameIn      = @TargetObjectName,
        @ActualStateOut          = @QsActualState        OUTPUT,
        @DesiredStateOut         = @QsDesiredState        OUTPUT,
        @ReadOnlyReasonOut       = @QsReadOnlyReason       OUTPUT,
        @CaptureModeOut          = @QsCaptureMode          OUTPUT,
        @StaleDaysOut            = @QsStaleDays            OUTPUT,
        @CurrentMbOut            = @QsCurrentMb            OUTPUT,
        @MaxMbOut                = @QsMaxMb                OUTPUT,
        @HasQueryStoreOut        = @HasQueryStore          OUTPUT,
        @WaitStatsViewExistsOut  = @WaitStatsViewExists     OUTPUT,
        @WaitCaptureColExistsOut = @WaitCaptureColExists    OUTPUT,
        @ReplicaAwareOut         = @ReplicaAware            OUTPUT,
        @UpdateabilityOut        = @Updateability           OUTPUT,
        @OldestExecutionUtcOut   = @OldestExecutionUtc      OUTPUT,
        @TargetObjectIdOut       = @TargetObjectId          OUTPUT;

    /*  Second, separate dynamic call -- only reachable, and only compiled, when the column is
        already known to exist. See the comment above.                                          */
    IF @WaitCaptureColExists = 1
    BEGIN
        SET @Sql = @Use + N'SELECT @DescOut = wait_stats_capture_mode_desc FROM sys.database_query_store_options;';
        EXEC sys.sp_executesql @Sql, N'@DescOut NVARCHAR(60) OUTPUT', @DescOut = @WaitCaptureDesc OUTPUT;
    END;

    SET @SkipReason = NULL;

    /*  HARD STOPS -- mirror Gates 1-3 of the v1 script (no Query Store catalog, no options row,
        Query Store OFF) plus the per-database @TargetObjectName resolution failure. One database
        failing this is fatal when it is the one that was asked for, and a skip when the caller
        asked for all of them -- same duality as usp_ParameterSniffingDiagnostic's own gate.     */
    IF @HasQueryStore = 0
        SET @SkipReason = N'Query Store catalog views are not present on this database''s engine';
    ELSE IF @QsActualState IS NULL
        SET @SkipReason = N'sys.database_query_store_options returned no row (master/tempdb cannot have Query Store, or this is not a user database)';
    ELSE IF @QsActualState = N'OFF'
        SET @SkipReason = N'Query Store is OFF -- there is no data to search. Enable it with ALTER DATABASE ' + @DbQuoted + N' SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);';
    ELSE IF @TargetObjectName IS NOT NULL AND @TargetObjectId IS NULL
        SET @SkipReason = N'@TargetObjectName ' + QUOTENAME(@TargetObjectName) + N' did not resolve here';

    IF @SkipReason IS NOT NULL
    BEGIN
        IF @AllDatabases = 0
        BEGIN
            SET @Msg = @DbQuoted + N': ' + @SkipReason + N'. Aborting rather than returning an empty result, which would be indistinguishable from a database with no timeouts.';
            RAISERROR(@Msg, 16, 1);
            RETURN;
        END;

        INSERT #SkippedDatabases (DatabaseName, Reason) VALUES (@DatabaseName, @SkipReason);
        IF @Debug = 1 RAISERROR('skipping %s: %s', 0, 0, @DatabaseName, @SkipReason) WITH NOWAIT;
        SET @DatabaseName = (SELECT MIN(DatabaseName) FROM #DatabaseList WHERE DatabaseName > @DatabaseName);
        CONTINUE;
    END;

    /*  WARNINGS -- reported, never fatal. See Gates 4/5/6(b)/7/8 of the v1 script for the full
        reasoning behind each one; the substance is unchanged, only the delivery mechanism is.   */
    IF @QsActualState = N'READ_ONLY'
        INSERT #PreflightNotes (DatabaseName, Note)
        VALUES (@DatabaseName, N'Query Store is READ_ONLY -- not capturing new executions. Results are historical only; a recent timeout may be absent. readonly_reason = ' + CAST(ISNULL(@QsReadOnlyReason, 0) AS VARCHAR(20)) + N' (bitmask: storage limit reached, database read-only, single-user mode, or out of disk).');

    IF @QsActualState <> @QsDesiredState
        INSERT #PreflightNotes (DatabaseName, Note)
        VALUES (@DatabaseName, N'Query Store requested state is ' + ISNULL(@QsDesiredState, N'(unknown)') + N' but the actual state is ' + ISNULL(@QsActualState, N'(unknown)') + N' -- the engine overrode the request.');

    IF @QsStaleDays IS NOT NULL AND @QsStaleDays < @LookbackDays
        INSERT #PreflightNotes (DatabaseName, Note)
        VALUES (@DatabaseName, N'@LookbackDays = ' + CAST(@LookbackDays AS VARCHAR(10)) + N' but STALE_QUERY_THRESHOLD_DAYS is ' + CAST(@QsStaleDays AS VARCHAR(20)) + N' -- the effective lookback is ' + CAST(@QsStaleDays AS VARCHAR(20)) + N' days.');

    IF @QsMaxMb > 0 AND @QsCurrentMb * 100 / NULLIF(@QsMaxMb, 0) >= 90
        INSERT #PreflightNotes (DatabaseName, Note)
        VALUES (@DatabaseName, N'Query Store storage is at ' + CAST(@QsCurrentMb * 100 / NULLIF(@QsMaxMb, 0) AS VARCHAR(10)) + N'% of MAX_STORAGE_SIZE_MB (' + CAST(@QsCurrentMb AS VARCHAR(20)) + N' / ' + CAST(@QsMaxMb AS VARCHAR(20)) + N' MB). Cleanup may already have discarded older data.');

    IF @QsCaptureMode = N'NONE'
        INSERT #PreflightNotes (DatabaseName, Note)
        VALUES (@DatabaseName, N'QUERY_CAPTURE_MODE = NONE -- no NEW queries are being captured. Only statements already known to Query Store will appear.');

    IF @WaitStatsViewExists = 0
        INSERT #PreflightNotes (DatabaseName, Note)
        VALUES (@DatabaseName, N'sys.query_store_wait_stats does not exist on this engine (SQL Server 2017+ / Azure SQL Database). Wait columns will be NULL.');
    ELSE IF @WaitCaptureColExists = 0 OR @WaitCaptureDesc <> N'ON'
        INSERT #PreflightNotes (DatabaseName, Note)
        VALUES (@DatabaseName, N'WAIT_STATS_CAPTURE_MODE is ' + ISNULL(@WaitCaptureDesc, N'(unreadable)') + N' for this database, so wait columns will be NULL even though the engine supports them.');

    DECLARE @WaitStatsUsable BIT = CASE WHEN @WaitStatsViewExists = 1 AND @WaitCaptureColExists = 1 AND @WaitCaptureDesc = N'ON' THEN 1 ELSE 0 END;

    IF @Updateability = N'READ_ONLY'
        INSERT #PreflightNotes (DatabaseName, Note)
        VALUES (@DatabaseName, N'This database is READ_ONLY -- a readable AG secondary, or a read-only database. Rows here were persisted by the PRIMARY and replicated in; do not correlate against this replica''s own local plan cache.');

    IF @OldestExecutionUtc IS NULL
        INSERT #PreflightNotes (DatabaseName, Note)
        VALUES (@DatabaseName, N'Query Store holds NO execution history at all -- just cleared, or nothing has executed since it was enabled. An empty result means "nothing was recorded", not "nothing timed out".');
    ELSE
    BEGIN
        SET @HistoryMinutes  = DATEDIFF_BIG(MINUTE, @OldestExecutionUtc, SYSUTCDATETIME());
        SET @LookbackMinutes = CAST(@LookbackDays AS BIGINT) * 1440;
        SET @CoveragePercent = CASE WHEN @LookbackMinutes <= 0 THEN 100
                                    ELSE CAST((@HistoryMinutes * 100) / @LookbackMinutes AS INT) END;

        IF @CoveragePercent < @HistoryCoverageWarnPercent
            INSERT #PreflightNotes (DatabaseName, Note)
            VALUES (@DatabaseName, N'@LookbackDays = ' + CAST(@LookbackDays AS VARCHAR(10)) + N' but only ' + CAST(@CoveragePercent AS VARCHAR(10)) + N'% of that is actually retained (oldest execution ' + CONVERT(VARCHAR(30), @OldestExecutionUtc, 126) + N' UTC). An empty result covers only what Query Store still holds.');
    END;

    /*----------------------------------------------------------------------------------------
      SECTION 2: ABORTED RUNTIME STATS, AGGREGATED PER PLAN.
      Verbatim from the v1 script's own Section 2 -- only the @Use prefix is new; every embedded
      quote below was already correctly doubled for one level of sp_executesql, and stays that
      way, because this string still passes through exactly one sp_executesql call, same as it
      always did.
    ----------------------------------------------------------------------------------------*/
    SET @Sql = @Use + N'
WITH AbortRows AS (
    SELECT rs.plan_id, rs.runtime_stats_interval_id, rs.execution_type, rs.count_executions,
           rs.avg_duration, rs.max_duration, rs.last_duration, rs.last_execution_time,
           rs.max_cpu_time, rs.max_logical_io_reads,'
    + CASE WHEN @ReplicaAware = 1 THEN N'
           IsSecondary = CASE WHEN r.role_type IS NULL OR r.role_type IN (1, 3) THEN 0 ELSE 1 END,'
                                  ELSE N'
           IsSecondary = CONVERT(INT, 0),' END
    + N'
           ROW_NUMBER() OVER (PARTITION BY rs.plan_id
                              ORDER BY rs.last_execution_time DESC, rs.runtime_stats_interval_id DESC) AS LastRn
    FROM sys.query_store_runtime_stats rs'
    + CASE WHEN @ReplicaAware = 1 THEN N'
    LEFT JOIN sys.query_store_replicas r ON r.replica_group_id = rs.replica_group_id' ELSE N'' END
    + N'
    WHERE (rs.execution_type = 3 OR (@IncludeExceptionAbortsIn = 1 AND rs.execution_type = 4))
      AND rs.last_execution_time >= @SinceIn'
    + CASE WHEN @ReplicaAware = 1 THEN N'
      AND (@IncludeSecondaryReplicasIn = 1
           OR r.role_type IS NULL OR r.role_type IN (1, 3))' ELSE N'' END
    + N'
)
INSERT INTO #AbortedStats (plan_id, AbortedExecutions, IntervalsAffected, StatementMaxDurationMs,
                           StatementAvgDurationMs, LastAbortEndTime, LastAbortDurationMs,
                           StatementMaxCpuMs, StatementMaxLogicalReads, ClientAborts,
                           ExceptionAborts, ReplicaScope)
SELECT
    a.plan_id,
    SUM(a.count_executions),
    COUNT(DISTINCT a.runtime_stats_interval_id),
    MAX(a.max_duration)  / 1000.0,
    (SUM(a.avg_duration * a.count_executions) / NULLIF(SUM(a.count_executions), 0)) / 1000.0,
    MAX(CASE WHEN a.LastRn = 1 THEN a.last_execution_time END),
    MAX(CASE WHEN a.LastRn = 1 THEN a.last_duration END) / 1000.0,
    MAX(a.max_cpu_time)  / 1000.0,
    MAX(a.max_logical_io_reads),
    SUM(CASE WHEN a.execution_type = 3 THEN a.count_executions ELSE 0 END),
    SUM(CASE WHEN a.execution_type = 4 THEN a.count_executions ELSE 0 END),'
    + CASE WHEN @ReplicaAware = 1 THEN N'
    CASE WHEN MAX(a.IsSecondary) = 1 AND MIN(a.IsSecondary) = 0 THEN N''PRIMARY + SECONDARY''
         WHEN MAX(a.IsSecondary) = 1                            THEN N''SECONDARY only''
         ELSE N''PRIMARY only'' END'
                                  ELSE N'
    N''n/a (no secondary Query Store)''' END
    + N'
FROM AbortRows a
GROUP BY a.plan_id
HAVING SUM(a.count_executions) >= @MinAbortedExecutionsIn;';

    EXEC sys.sp_executesql @Sql,
         N'@IncludeExceptionAbortsIn BIT, @SinceIn DATETIME2(7), @MinAbortedExecutionsIn INT, @IncludeSecondaryReplicasIn BIT',
         @IncludeExceptionAbortsIn   = @IncludeExceptionAborts,
         @SinceIn                    = @Since,
         @MinAbortedExecutionsIn     = @MinAbortedExecutions,
         @IncludeSecondaryReplicasIn = @IncludeSecondaryReplicas;

    /*----------------------------------------------------------------------------------------
      SECTION 3: TOP WAIT CATEGORY PER PLAN. Verbatim from the v1 script's own Section 3, @Use
      prefix added, gated on @WaitStatsUsable exactly as the script gates on it.
    ----------------------------------------------------------------------------------------*/
    IF @WaitStatsUsable = 1
    BEGIN
        SET @Sql = @Use + N'
    WITH PerCategory AS (
        SELECT ws.plan_id,
               ws.wait_category_desc,
               SUM(ws.total_query_wait_time_ms) AS TotalMs,
               MAX(ws.max_query_wait_time_ms)   AS MaxMs
        FROM sys.query_store_wait_stats ws
        WHERE ws.plan_id IN (SELECT plan_id FROM #AbortedStats)
          AND (ws.execution_type = 3 OR (@IncludeExceptionAbortsIn = 1 AND ws.execution_type = 4))
        GROUP BY ws.plan_id, ws.wait_category_desc
    ),
    Ranked AS (
        SELECT plan_id, wait_category_desc, TotalMs, MaxMs,
               SUM(TotalMs) OVER (PARTITION BY plan_id) AS AllMs,
               ROW_NUMBER() OVER (PARTITION BY plan_id ORDER BY TotalMs DESC, wait_category_desc) AS rn
        FROM PerCategory
    )
    INSERT INTO #AbortWaits (plan_id, TopWaitCategory, TopWaitTotalMs, TopWaitMaxMs, AllWaitMs)
    SELECT plan_id, wait_category_desc, TotalMs, MaxMs, AllMs
    FROM Ranked
    WHERE rn = 1;';

        EXEC sys.sp_executesql @Sql, N'@IncludeExceptionAbortsIn BIT', @IncludeExceptionAbortsIn = @IncludeExceptionAborts;
    END;

    /*----------------------------------------------------------------------------------------
      SECTION 4: RESULT, per database, inserted into the shared #Results accumulator.
      Verbatim from the v1 script's own Section 4, with two changes only:
        - DB_NAME() -> @DatabaseNameIn (the only place the script used it; see the header)
        - SELECT TOP (@TopN) ... -> INSERT INTO #Results (...) SELECT TOP (@TopNIn) ...
      Every embedded quote in string literals (''(ad-hoc / dynamic SQL)'', the XML namespace, the
      NextStep/DurationScopeNote text) is doubled for the same one level of sp_executesql the
      script's own Sections 2/3 already needed -- nothing here is doubly nested.
    ----------------------------------------------------------------------------------------*/
    SET @Sql = @Use + N'
;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
INSERT INTO #Results (
    DatabaseName, ObjectName, AbortedExecutions, ClientAborts, ExceptionAborts, IntervalsAffected,
    SuccessfulExecutions, CompletionPattern, TopWaitCategory, TopWaitTotalMs, TopWaitMaxMs, AllWaitMs,
    PlansForThisQuery, StatementsInObject, query_sql_text, StatementSubTreeCost, PlanCompatModel,
    QueryPlanXml, NextStep, LastAbortStartTime, LastAbortEndTime, LastAbortDurationMs,
    DurationScopeNote, StatementMaxDurationMs, StatementAvgDurationMs, StatementMaxCpuMs,
    StatementMaxLogicalReads, ObjectAvgTotalMs_Approx, PrecedingStatementCount,
    PrecedingStatementsAvgMs, AccountedStatementMsAvg, PctDurationBeforeAbortedStmt,
    object_id, query_id, plan_id, query_hash, query_plan_hash, ReplicaScope
)
SELECT TOP (@TopNIn)
    @DatabaseNameIn,
    ISNULL(OBJECT_NAME(q.object_id), ''(ad-hoc / dynamic SQL)''),

    a.AbortedExecutions,
    a.ClientAborts,
    a.ExceptionAborts,
    a.IntervalsAffected,

    ok.SuccessfulExecutions,
    CASE WHEN ok.SuccessfulExecutions IS NULL OR ok.SuccessfulExecutions = 0
         THEN ''Never completed in this window''
         ELSE ''Also completes -- '' + CAST(ok.SuccessfulExecutions AS VARCHAR(20)) + '' successful run(s)''
    END,

    w.TopWaitCategory,
    w.TopWaitTotalMs,
    w.TopWaitMaxMs,
    w.AllWaitMs,

    pc.PlansForThisQuery,

    obj.StatementsInObject,

    qt.query_sql_text,
    px.PlanXml.value(''(//StmtSimple/@StatementSubTreeCost)[1]'', ''float''),
    px.PlanXml.value(''(//StmtSimple/@CardinalityEstimationModelVersion)[1]'', ''int''),
    px.PlanXml,
    CASE WHEN pc.PlansForThisQuery > 1
         THEN ''Multiple plans exist -- run Paramsniffingdiagnostic_v1.sql and look up query_id ''
              + CAST(q.query_id AS VARCHAR(20))
         ELSE ''Single plan -- a timeout here is less likely to be parameter sniffing''
    END,

    DATEADD(MILLISECOND, -CAST(a.LastAbortDurationMs AS INT), a.LastAbortEndTime),
    a.LastAbortEndTime,
    CAST(a.LastAbortDurationMs AS DECIMAL(18,2)),
    CASE WHEN q.object_id IS NULL OR q.object_id = 0
              THEN ''Ad-hoc -- the statement IS the batch, so the statement duration is the wait''
         WHEN obj.StatementsInObject <= 1
              THEN ''One statement recorded -- statement duration is the whole call''
         ELSE ''Query Store holds '' + CAST(obj.StatementsInObject AS VARCHAR(10))
              + '' statements for this object. If the procedure really is multi-statement, the caller''
              + '' also waited on the ones that ran first -- see PrecedingStatementsAvgMs, which''
              + '' counts only the statements that run BEFORE this one and excludes superseded''
              + '' versions. NOTE: this count includes statements from PREVIOUS versions if the''
              + '' procedure has been altered -- verify against the current body.''
    END,

    CAST(a.StatementMaxDurationMs AS DECIMAL(18,2)),
    CAST(a.StatementAvgDurationMs AS DECIMAL(18,2)),
    CAST(a.StatementMaxCpuMs      AS DECIMAL(18,2)),
    a.StatementMaxLogicalReads,
    CAST(obj.ObjectAvgTotalMs AS DECIMAL(18,2)),

    prec.PrecedingStatementCount,
    CAST(prec.PrecedingStatementsAvgMs AS DECIMAL(18,2)),
    CAST(ISNULL(prec.PrecedingStatementsAvgMs, 0)
         + a.StatementAvgDurationMs AS DECIMAL(18,2)),
    CAST(100.0 * ISNULL(prec.PrecedingStatementsAvgMs, 0)
         / NULLIF(ISNULL(prec.PrecedingStatementsAvgMs, 0)
                  + a.StatementAvgDurationMs, 0) AS DECIMAL(5,1)),

    q.object_id,
    q.query_id,
    p.plan_id,
    q.query_hash,
    p.query_plan_hash,

    a.ReplicaScope
FROM #AbortedStats a
JOIN sys.query_store_plan       p  ON p.plan_id      = a.plan_id
JOIN sys.query_store_query      q  ON q.query_id     = p.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
LEFT JOIN #AbortWaits           w  ON w.plan_id      = a.plan_id
CROSS APPLY (SELECT TRY_CAST(p.query_plan AS XML) AS PlanXml) px
OUTER APPLY (
    SELECT SUM(rs2.count_executions) AS SuccessfulExecutions
    FROM sys.query_store_runtime_stats rs2
    WHERE rs2.plan_id = a.plan_id
      AND rs2.execution_type = 0
      AND rs2.last_execution_time >= @SinceIn
) ok
OUTER APPLY (
    SELECT COUNT(DISTINCT p2.plan_id) AS PlansForThisQuery
    FROM sys.query_store_plan p2
    WHERE p2.query_id = q.query_id
) pc
OUTER APPLY (
    SELECT COUNT(*)          AS StatementsInObject,
           SUM(perStmt.AvgMs) AS ObjectAvgTotalMs
    FROM sys.query_store_query q2
    CROSS APPLY (
        SELECT (SUM(rs3.avg_duration * rs3.count_executions)
                  / NULLIF(SUM(rs3.count_executions), 0)) / 1000.0 AS AvgMs
        FROM sys.query_store_plan p3
        JOIN sys.query_store_runtime_stats rs3 ON rs3.plan_id = p3.plan_id
        WHERE p3.query_id = q2.query_id
          AND rs3.last_execution_time >= @SinceIn
    ) perStmt
    WHERE q2.object_id = q.object_id
      AND ISNULL(q.object_id, 0) <> 0
) obj
OUTER APPLY (
    SELECT PrecedingStatementCount  = COUNT(*),
           PrecedingStatementsAvgMs = SUM(perPrec.AvgMs)
    FROM sys.query_store_query q4
    CROSS APPLY (
        SELECT (SUM(rs4.avg_duration * rs4.count_executions)
                  / NULLIF(SUM(rs4.count_executions), 0)) / 1000.0 AS AvgMs
        FROM sys.query_store_plan p4
        JOIN sys.query_store_runtime_stats rs4 ON rs4.plan_id = p4.plan_id
        WHERE p4.query_id = q4.query_id
          AND rs4.execution_type = 0
          AND rs4.last_execution_time >= @SinceIn
    ) perPrec
    WHERE q4.object_id                      = q.object_id
      AND ISNULL(q.object_id, 0)           <> 0
      AND q4.last_compile_batch_sql_handle   = q.last_compile_batch_sql_handle
      AND q4.last_compile_batch_offset_start < q.last_compile_batch_offset_start
      AND perPrec.AvgMs IS NOT NULL
) prec
WHERE @TargetObjectIdIn IS NULL OR q.object_id = @TargetObjectIdIn
ORDER BY a.StatementMaxDurationMs DESC;';

    EXEC sys.sp_executesql @Sql,
         N'@DatabaseNameIn sysname, @TopNIn INT, @SinceIn DATETIME2(7), @TargetObjectIdIn INT',
         @DatabaseNameIn   = @DatabaseName,
         @TopNIn           = @TopN,
         @SinceIn          = @Since,
         @TargetObjectIdIn = @TargetObjectId;

    SELECT @Rows = COUNT(*) FROM #Results WHERE DatabaseName = @DatabaseName;
    IF @Debug = 1 RAISERROR('%s: %d aborted statement(s) found', 0, 0, @DatabaseName, @Rows) WITH NOWAIT;

    SET @DatabaseName = (SELECT MIN(DatabaseName) FROM #DatabaseList WHERE DatabaseName > @DatabaseName);
    END;   -- per-database loop

    /*======================================================================================
      OUTPUT. Worst duration leads the sort rather than database name -- same triage-tool
      reasoning as usp_ParameterSniffingDiagnostic's own severity-first ordering: the worst
      timeout on the instance should be the first row whichever database it is in.
    ======================================================================================*/
    SELECT *
    FROM #Results
    ORDER BY StatementMaxDurationMs DESC, DatabaseName, ObjectName;

    /*  Emitted only when there is something to say -- same convention as #SkippedDatabases. */
    IF EXISTS (SELECT 1 FROM #PreflightNotes)
        SELECT DatabaseName, Note FROM #PreflightNotes ORDER BY DatabaseName;

    IF EXISTS (SELECT 1 FROM #SkippedDatabases)
        SELECT DatabaseName, Reason FROM #SkippedDatabases ORDER BY DatabaseName;
END;
GO
