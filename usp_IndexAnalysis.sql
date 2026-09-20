/*==================================================================================================
  dbo.usp_IndexAnalysis  --  procedure form of IndexAnalysis_v1.sql

  Installs in a DBA utility database (DBAdmin) and reads any database on the same instance, or all
  of them (@AllDatabases = 1). Derived from IndexAnalysis_v1.sql, which remains the annotated
  reference: the reasoning behind the analysis lives there, not here.

  HELD TO CELL-FOR-CELL OUTPUT EQUIVALENCE WITH THE SCRIPT. For one target database and the same
  parameters, this procedure's primary result set must equal the script's, column for column and
  row for row, apart from the leading DatabaseName column this procedure adds. That equivalence is
  the acceptance test for any change to either file -- see TestRunners/Validate-IndexAnalysisFamily.ps1.

  HOW IT REACHES THE TARGET
    Every COLLECTION statement (Sections 3-9 and 11a's exact bridge) runs inside a dynamic batch
    whose first line is USE [target], executed through sp_executesql. Unqualified catalog
    references then resolve in the target, so the collection SQL is character for character what
    the script runs -- which is what makes the equivalence test compare the same SQL in two
    contexts rather than rewritten SQL. Temp tables are created here, in the outer scope, because
    a table created inside the dynamic batch dies with it.

    The ANALYSIS half (Sections 10, 11b/11c/11d, 12, 13) reads only those temp tables, no catalog,
    so it runs unchanged in this procedure's own (DBAdmin) context -- again identical SQL to the
    script. DB_NAME() / DB_ID() appear ONLY inside USE-wrapped collection batches, where they
    resolve to the target; nowhere in the analysis half (that trap sank two [AI Prompt] rows in
    the sibling procedure).

  PERMISSIONS
    VIEW SERVER STATE (the instance-wide index and missing-index DMVs; VIEW SERVER PERFORMANCE
    STATE on 2022+ implies it) and VIEW DATABASE STATE in each target (Query Store). Intended to
    be certificate-signed so callers need only EXECUTE. Do not enable TRUSTWORTHY to solve this.

  PLATFORM
    Box SQL Server and Azure SQL Managed Instance. Azure SQL Database (EngineEdition 5) cannot run
    this pattern at all -- it has no cross-database access; install and run the script in the
    target database instead.

  RESULT SETS
    1. The index analysis, shaped by @Output, with a leading DatabaseName column.
    2. Drop-risk detail: one row per (drop candidate, Query Store query still reading it). Always
       emitted, may be empty.
    3. #PreflightNotes: warning-level conditions per database (Query Store not readable so ranking
       fell back to DMV; instance restarted inside @UnusedIndexMinDaysSinceStartup so DROP-USAGE
       was withheld). Emitted only when non-empty. The script PRINTs these; a procedure driven by
       @AllDatabases = 1 across many databases cannot rely on PRINT reaching the caller, so they
       become rows -- same treatment as usp_FindTimeoutStatementsNQueryStore.
    4. #SkippedDatabases: databases asked for and not analysed. Emitted only when non-empty.

  QUOTED_IDENTIFIER / ANSI_NULLS are captured into the module AT CREATE TIME (sys.sql_modules),
  not read from the caller's session. The analysis half runs XML data-type methods (.nodes() /
  .value()) inline in INSERT ... SELECT, which requires QUOTED_IDENTIFIER ON for those statements
  to succeed at all. Pinned explicitly rather than trusted to the deploy session's default --
  a plain sqlcmd deploy has been measured capturing QUOTED_IDENTIFIER OFF.
==================================================================================================*/
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.usp_IndexAnalysis
    /*  Cross-database scope -------------------------------------------------------------------- */
    @DatabaseName                 sysname       = NULL,   -- NULL = current database
    @AllDatabases                 BIT           = 0,      -- every online, writable, non-system database
    @IncludeDatabases             NVARCHAR(MAX) = NULL,   -- comma-separated; only with @AllDatabases = 1
    @ExcludeDatabases             NVARCHAR(MAX) = NULL,   -- comma-separated; only with @AllDatabases = 1
    @ExcludeHostingDatabase       BIT           = 1,      -- @AllDatabases = 1 skips DB_NAME() (this proc's own DB) by default

    /*  Table scope (same as the script) ------------------------------------------------------- */
    @TableName                    NVARCHAR(776) = NULL,   -- one table; bare or schema-qualified
    @TableList                    NVARCHAR(MAX) = NULL,   -- comma-separated list; unions with @TableName
    @StatementPlanXml             NVARCHAR(MAX) = NULL,   -- Piece 1: a SHOWPLAN_XML document for ONE statement. The tables it touches BECOME
                                                          -- the scope (so it cannot be combined with @TableName / @TableList or @AllDatabases),
                                                          -- its <MissingIndexes> hints become proposals (proposal_source = 'STATEMENT') and its
                                                          -- Sort / GroupBy give them a realign shape. Parsed as XML, never concatenated into
                                                          -- anything this procedure executes. @Statement (raw text) is SCRIPT-ONLY by design --
                                                          -- see IndexAnalysis_v1.sql Section 2b for why nothing can compile it from in here.

    /*  Output + ranking (same as the script) -------------------------------------------------- */
    @Output                       VARCHAR(20)   = 'DUMP', -- DUMP | DETAILED | DUPLICATE | OVERLAPPING | REALIGN | MISSING | COMPRESSION | DEPENDENTS (needs @IncludeDependentObjects = 1)
    @RankingSource                VARCHAR(5)    = 'BLEND',-- DMV | QS | BLEND
    @LookbackDays                 INT           = 14,
    @IncludeBufferPool            BIT           = 1,

    /*  Detection toggles -------------------------------------------------------------------- */
    @DetectDuplicates             BIT           = 1,
    @DetectOverlapping            BIT           = 1,
    @DetectSiblings               BIT           = 1,
    @IncludeMissingIndexes        BIT           = 1,
    @IncludeMissingFKIndexes      BIT           = 1,
    @IncludeDependentObjects      BIT           = 0,      -- Section 9b (opt-in): every referencing view / proc / function / trigger / FK child per table, with plan evidence
    @ConsolidatePartitionStats    BIT           = 1,
    @CheckCompression             BIT           = 1,
    @RecommendCompression         BIT           = 1,      -- Section 12d: emit a U/S-based PAGE recommendation
    @WorkloadType                 VARCHAR(4)    = 'OLTP', -- OLTP (per-object U/S test) | DW (page-compress every sizeable object)

    /*  Thresholds (same defaults as the script) --------------------------------------------- */
    @MaxMissingIndexesPerTable    INT           = 2147483647, -- default = no cap; lower to surface only the N highest-impact per table
    @MissingIndexMinImpact        DECIMAL(18,4) = 1.0,
    @MissingIndexBlendMinImpact   DECIMAL(18,4) = 0.1,
    @UnusedIndexMinDaysSinceStartup INT         = 7,
    @LowUsagePercentThreshold     DECIMAL(6,2)  = 1.0,
    @ScanHeavyMinScans            INT           = 100,
    @ScanToSeekRatioThreshold     INT           = 1000,
    @LookupHeavyMinLookups        INT           = 1000,
    @RealignLowUsagePercent       DECIMAL(6,2)  = 5.0,
    @SeqKeyMinPageLatchWaits      BIGINT        = 10000,
    @WriteHeavyReadsPerWrite      DECIMAL(9,3)  = 0.10,
    /*  Tier 2 (2026-09-13): lock-wait and heap cons. 300,000 ms = 5 minutes is sp_BlitzIndex
        check 11's own number; the two heap thresholds mirror its "> 0".                          */
    @LockWaitTotalMsWarn          BIGINT        = 300000,
    @HeapForwardedFetchWarn       BIGINT        = 1,
    @HeapDeleteWarn               BIGINT        = 1,
    /*  Tier 3 (2026-09-13): statistics sampling. See the script's Section 12j header.            */
    @LowStatsSamplePct            DECIMAL(6,2)  = 25.0,
    @StatsSampleMinRows           BIGINT        = 10000,
    @WideCoveringMinKeyPlusInclude INT          = 4,
    @WideCoveringPct25            DECIMAL(6,2)  = 25.0,
    @WideCoveringPct50            DECIMAL(6,2)  = 50.0,
    @WideCoveringPct90            DECIMAL(6,2)  = 90.0,
    /*  Section 12f structural (catalog-only) findings -- no DMV, no Query Store, so no freshness
        caveat and no uptime floor. See IndexAnalysis_v1.sql Section 12f.                         */
    @WideClusteredMaxKeyColumns   INT           = 3,       -- > this many key columns in a CLUSTERED key -> CLWIDE
    @WideClusteredMaxKeyBytes     INT           = 16,      -- ... or more than this many bytes, summed from #ColumnWidth
    @LowFillFactorPct             TINYINT       = 80,      -- fill_factor at or below this, and not 0/default -> FILL<n>
    /*  Section 12g table-level findings. A TABLE row is emitted ONLY when one of these fires.     */
    @WideTableMaxColumns          INT           = 35,      -- >= this many columns -> TBLWIDE
    @WideTableMaxRowBytes         INT           = 2000,    -- ... or this many non-LOB bytes per row (summed from #ColumnWidth)
    @ManyNonclusteredIndexes      INT           = 10,      -- >= this many NC indexes on one table -> NCMANY<n>
    @ColumnMixMinColumns          INT           = 3,       -- NOTNULL<n>of<m> / STRING<n>of<m> only apply above this column count
    @IdentityRangeUsedPctWarn     DECIMAL(5,2)  = 70.0,    -- identity this far through its type's range -> IDENT<n>%
    @PageCompressionRowThreshold  INT           = 1000,
    @CompressionScanPctForPage    DECIMAL(6,2)  = 75.0,   -- S must exceed this  (OLTP mode)
    @CompressionUpdatePctForPage  DECIMAL(6,2)  = 20.0,   -- U must be below this (OLTP mode)
    @CompressionAppendOnlyInsertPct DECIMAL(6,2) = 90.0,  -- inserts above this % + U below the limit -> PAGE even at low S
    @MinQsExecutionsForBridge     BIGINT        = 1,
    @DropRiskMaxQueriesPerIndex   INT           = 20,
    @QsWeightMetric               VARCHAR(10)   = 'DURATION',
    @MaxIndexKeyColumns           INT           = 16,
    @MaxIndexKeyBytes             INT           = 1700,
    @GeneratedIndexNamePrefix     SYSNAME       = N'IX_',

    @Debug                        BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*----------------------------------------------------------------------------------------------
      SESSION-LEVEL STATE (instance-wide facts, computed once)
    ----------------------------------------------------------------------------------------------*/
    DECLARE
        @EngineEdition        INT           = TRY_CAST(SERVERPROPERTY('EngineEdition') AS INT),
        @EditionName          NVARCHAR(128) = CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)),
        @MajorVersion         INT           = CASE WHEN TRY_CAST(SERVERPROPERTY('EngineEdition') AS INT) IN (1,2,3,4)
                                                   THEN TRY_CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) END,
        @PlatformName         NVARCHAR(60)  =
            CASE TRY_CAST(SERVERPROPERTY('EngineEdition') AS INT)
                 WHEN 5  THEN N'Azure SQL Database'
                 WHEN 6  THEN N'Azure Synapse (dedicated pool)'
                 WHEN 8  THEN N'Azure SQL Managed Instance'
                 WHEN 9  THEN N'Azure SQL Edge'
                 WHEN 11 THEN N'Azure Synapse serverless / Fabric'
                 WHEN 12 THEN N'Fabric SQL database'
                 ELSE N'SQL Server' END,
        @SqlServerStartTime   DATETIME2(3)  = (SELECT sqlserver_start_time FROM sys.dm_os_sys_info),
        @DaysSinceStartup     INT           = DATEDIFF(DAY, (SELECT sqlserver_start_time FROM sys.dm_os_sys_info), SYSDATETIME()),
        @LookbackStart        DATETIME2(7)  = DATEADD(DAY, -@LookbackDays, SYSUTCDATETIME()),
        @HasSequentialKeyOption BIT         = CASE WHEN TRY_CAST(SERVERPROPERTY('EngineEdition') AS INT) IN (1,2,3,4)
                                                   THEN CASE WHEN TRY_CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 15 THEN 1 ELSE 0 END
                                                   ELSE 1 END,   -- MI / Azure: always >= 2019
        @HasFunctionStatsDmv  BIT           = CASE WHEN OBJECT_ID('sys.dm_exec_function_stats') IS NULL THEN 0 ELSE 1 END;  -- 2016 SP1+; Section 9b

    /*  Per-iteration working variables */
    DECLARE
        @Sql                  NVARCHAR(MAX),
        @Inner                NVARCHAR(MAX),   -- un-escaped collection SQL run by a nested sp_executesql
        @sqlPlan              NVARCHAR(MAX),   -- Section 9c Query Store plan pull (SET, not DECLARE, in the loop)
        @sqlCachePlan         NVARCHAR(MAX),   -- Section 9c plan-cache pull for CACHE-only dependents
        @sqlBridge            NVARCHAR(MAX),   -- Section 11a exact-bridge dynamic batch
        @Use                  NVARCHAR(MAX),
        @DbQuoted             sysname,
        @DbId                 INT,
        @Rows                 INT,
        @Msg                  NVARCHAR(2000),
        @DbCount              INT,
        @SkipReason           NVARCHAR(600),
        @Unresolved           NVARCHAR(MAX),
        @ScopeToTables        BIT = 0,
        @StatementMode        BIT = CASE WHEN NULLIF(LTRIM(RTRIM(@StatementPlanXml)), N'') IS NOT NULL THEN 1 ELSE 0 END,
        @DatabaseCompatibilityLevel INT,
        @QsActualState        TINYINT,
        @QsStateDesc          NVARCHAR(60),
        @QueryStoreUsable     BIT,
        @EffectiveRankingSource VARCHAR(5),
        @HasQueryStore        BIT,
        @HasMissingIndexQueryDmv BIT,
        @HasNativeJsonType    BIT;

    /*----------------------------------------------------------------------------------------------
      PARAMETER VALIDATION -- fail before touching any database
    ----------------------------------------------------------------------------------------------*/
    IF @EngineEdition = 5
    BEGIN
        RAISERROR('Azure SQL Database does not support cross-database access. Install and run IndexAnalysis_v1.sql in the target database instead.', 16, 1);
        RETURN;
    END;

    IF @Output NOT IN ('DUMP','DETAILED','DUPLICATE','OVERLAPPING','REALIGN','MISSING','COMPRESSION','DEPENDENTS','LEGEND')
    BEGIN
        RAISERROR('Invalid @Output ''%s''. Valid: DUMP, DETAILED, DUPLICATE, OVERLAPPING, REALIGN, MISSING, COMPRESSION, DEPENDENTS, LEGEND.', 16, 1, @Output); RETURN;
    END;

    /*  @Output = 'LEGEND' -- what every pros / cons token means, in plain English. Static, emitted
        before any collection, identical to the script's so the equivalence gate compares it. See
        IndexAnalysis_v1.sql's LEGEND block for why it exists and why DIRECTION is stated.        */
    IF @Output = 'LEGEND'
    BEGIN
        SELECT v.kind, v.token, v.meaning
        FROM (VALUES
            ('PRO', 'PK',              N'Primary key.'),
            ('PRO', 'UQ',              N'Unique index that is not the primary key.'),
            ('PRO', 'CLU',             N'The clustered index.'),
            ('PRO', 'FK',              N'Supports a foreign key: its key begins with the FK''s columns.'),
            ('PRO', 'MIFK',            N'This row IS a proposed index for a foreign key that has none.'),
            ('PRO', '$ $$ $$$ $$$+',   N'Read:write ratio band -- at least 1, 10, 100, 1000 reads per write. More $ is more read-dominant.'),
            ('CON', 'HP',              N'Heap: the table has no clustered index.'),
            ('CON', 'HEAPFWD',         N'A HEAP whose forwarded records are being followed: a row grew past its page, left a forwarding pointer, and every read since pays an extra page fetch. Only a rebuild clears them. Counter is cumulative since the last restart.'),
            ('CON', 'HEAPDEL',         N'A HEAP with deletes. Deleting from a heap does not deallocate the emptied pages, so its size and scan cost stay put until it is rebuilt. Counter is cumulative since the last restart.'),
            ('CON', 'HEAPPK',          N'The table is a HEAP whose PRIMARY KEY is NONCLUSTERED -- usually an accident rather than a decision. Catalog-only, so a restart cannot make it wrong.'),
            ('CON', 'LOCKWAIT',        N'Row plus page lock wait on this index exceeds @LockWaitTotalMsWarn. A flag, not a number: see row_lock_wait_in_ms for the magnitude, which is cumulative since the last restart.'),
            ('CON', 'DSB',             N'The index is disabled.'),
            ('CON', 'DUP',             N'An exact duplicate of another index here -- same key columns AND same includes.'),
            ('CON', 'OVLP',            N'Overlaps another index: they share leading key column(s).'),
            ('CON', 'SIB',             N'Sibling: the same key columns in a different order.'),
            ('CON', 'LKUP',            N'Lookup-heavy: key lookups outnumber seeks plus scans.'),
            ('CON', 'SCN',             N'Scan-heavy: scans dominate seeks by more than @ScanToSeekRatioThreshold.'),
            ('CON', 'U1%',             N'Serves under @LowUsagePercentThreshold of this table''s total reads.'),
            ('CON', 'WIDE',            N'Many key + include columns, but below the C25% covering band.'),
            ('CON', 'C25% C50% C90%',  N'Carries at least 25 / 50 / 90 percent of the table''s columns. Higher is wider.'),
            ('CON', 'NOCMP',           N'Uncompressed and big enough that PAGE compression is worth considering.'),
            ('CON', 'W$',              N'Write-heavy: fewer than @WriteHeavyReadsPerWrite reads per write.'),
            ('CON', 'JSONCOL',         N'The table HAS a native json column. (Was NJSON, which read as "no JSON".)'),
            ('CON', 'TOOSOON',         N'A DROP-USAGE verdict was WITHHELD -- the instance has been up fewer than @UnusedIndexMinDaysSinceStartup days, so the usage counters cannot be trusted yet. Not a statement about the index. (Was RECENT, which read as "recently created".)'),
            ('CON', 'UNVERIFIED',      N'A dependent object with no plan evidence anywhere -- nothing proves it still runs, and nothing proves it does not.'),
            ('CON', 'DEPUNV',          N'This index is a drop candidate on a table that has at least one UNVERIFIED dependent. Verify before dropping.'),
            ('CON', 'CLNU',            N'The clustered index is not unique, so SQL Server adds a uniquifier -- and every nonclustered index carries it too.'),
            ('CON', 'CLWIDE',          N'The clustered key exceeds @WideClusteredMaxKeyColumns columns or @WideClusteredMaxKeyBytes bytes. Its width repeats in every nonclustered index.'),
            ('CON', 'FILL<n>',         N'Fill factor is n percent, at or below @LowFillFactorPct. LOWER n = more empty space reserved on every page.'),
            ('CON', 'FILTCOL<n>',      N'This FILTERED index''s WHERE names n columns the index does not contain, as key or INCLUDE -- so the optimizer must re-check the filter against the base table. create_index_sql carries the column names and the DROP_EXISTING rebuild that fixes it.'),
            ('CON', 'HYPO',            N'A hypothetical index: a Database Engine Tuning Advisor leftover with no data and no storage, which no plan can ever use. Its row_kind is HYPO and its action is DROP-HYPO. Nothing else on the row is measured, because there is nothing there to measure.'),
            ('CON', 'TBLWIDE',         N'The table exceeds @WideTableMaxColumns columns or @WideTableMaxRowBytes non-LOB bytes per row.'),
            ('CON', 'NCMANY<n>',       N'The table carries n nonclustered indexes, at or above @ManyNonclusteredIndexes. HIGHER n is worse.'),
            ('CON', 'NOTNULL<n>of<m>', N'Only n of the table''s m columns are NOT NULL -- essentially nothing is required. READ THIS ONE BACKWARDS: a LOWER n is the finding, and 0of7 is worse than 1of7.'),
            ('CON', 'STRING<n>of<m>',  N'n of the table''s m columns are a string or LOB type. HIGHER n is the finding.'),
            ('CON', 'IDENT<n>%',       N'An identity column has consumed n percent of its data type''s range. HIGHER n is worse; at 100 inserts fail.'),
            ('CON', 'COLLMIX',         N'At least one column''s collation differs from the database''s -- a silent source of join and comparison surprises.'),
            ('CON', 'REPL<n>of<m>',    N'n of the table''s m columns belong to at least one replication publication, so an index or column change here has to be reasoned about against replication too.'),
            ('CON', 'FKCASC',          N'A foreign key ON THIS TABLE uses CASCADE on update or delete, so writes here can fan out.'),
            ('CON', 'PART<n>',         N'This index is built on a partition scheme, across n partitions. Informational, but it changes how every size and usage figure on the row should be read.'),
            ('CON', 'PARTNA',          N'NON-ALIGNED: the table is partitioned but this index is not. Partition SWITCH needs every index aligned, so one stray index costs the whole switching strategy.'),
            ('CON', 'STATSAMP<n>',     N'This index''s statistics were last built from only n percent of the rows, below @LowStatsSamplePct. Every estimate drawn from that histogram inherits the sampling error.'),
            ('CON', 'RESUMABLE',       N'A resumable ALTER INDEX was PAUSED against this index and never finished. The half-built index keeps its allocation and blocks further DDL on it until resumed or aborted.'),
            ('CON', 'CSTORE<n>',       N'The table has n COLUMNSTORE indexes, which this tool does not analyse -- it collects rowstore only. Their absence from the report is not evidence they are absent from the table.'),
            ('CON', 'MEMOPT',          N'The table is MEMORY-OPTIMIZED (In-Memory OLTP). Rowstore index analysis does not describe it; treat this report as covering the table''s disk-based structures only.')
        ) AS v(kind, token, meaning);
        RETURN;
    END;
    IF @Output = 'DEPENDENTS' AND @IncludeDependentObjects = 0
    BEGIN
        RAISERROR('@Output = DEPENDENTS needs @IncludeDependentObjects = 1 -- the dependent-object intake is opt-in.', 16, 1); RETURN;
    END;
    IF @RankingSource NOT IN ('DMV','QS','BLEND')
    BEGIN
        RAISERROR('Invalid @RankingSource ''%s''. Valid: DMV, QS, BLEND.', 16, 1, @RankingSource); RETURN;
    END;
    IF @QsWeightMetric NOT IN ('DURATION','CPU','EXECUTIONS')
    BEGIN
        RAISERROR('Invalid @QsWeightMetric ''%s''. Valid: DURATION, CPU, EXECUTIONS.', 16, 1, @QsWeightMetric); RETURN;
    END;
    IF @WorkloadType NOT IN ('OLTP','DW')
    BEGIN
        RAISERROR('Invalid @WorkloadType ''%s''. Valid: OLTP, DW.', 16, 1, @WorkloadType); RETURN;
    END;
    IF @AllDatabases = 0 AND (@IncludeDatabases IS NOT NULL OR @ExcludeDatabases IS NOT NULL)
    BEGIN
        RAISERROR('@IncludeDatabases and @ExcludeDatabases only apply when @AllDatabases = 1.', 16, 1); RETURN;
    END;

    /*----------------------------------------------------------------------------------------------
      DATABASE LIST -- identical shape to usp_ParameterSniffingDiagnostic
    ----------------------------------------------------------------------------------------------*/
    DROP TABLE IF EXISTS #DatabaseList;
    DROP TABLE IF EXISTS #SkippedDatabases;
    DROP TABLE IF EXISTS #NameList;

    CREATE TABLE #DatabaseList     (DatabaseName sysname NOT NULL PRIMARY KEY);
    CREATE TABLE #SkippedDatabases (DatabaseName sysname NOT NULL, Reason NVARCHAR(600) NOT NULL);
    CREATE TABLE #NameList         (Which CHAR(3) NOT NULL, DatabaseName sysname NOT NULL);

    /*  spt_values tally split -- no STRING_SPLIT (needs compat 130+ in THIS database). */
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
          AND d.state = 0 AND d.is_in_standby = 0 AND d.is_read_only = 0
          AND d.source_database_id IS NULL
          AND (@IncludeDatabases IS NULL
               OR EXISTS (SELECT 1 FROM #NameList n WHERE n.Which = 'inc' AND n.DatabaseName = d.name))
          AND NOT EXISTS (SELECT 1 FROM #NameList n WHERE n.Which = 'exc' AND n.DatabaseName = d.name)
          AND (@ExcludeHostingDatabase = 0 OR d.name <> DB_NAME());

        /*  Every requested database that did not make #DatabaseList, with its ACTUAL reason(s). The
            filter above rejects a database for seven distinct causes, and this names each one that
            applies, in the filter's own order.

            FIXED 2026-09-13. This used to emit one lumped message -- "not eligible: offline,
            standby, read only, a snapshot, or a system database" -- for every non-existence skip.
            It was reported for the HOSTING database and for names in @ExcludeDatabases too, two
            causes it did not even mention, so a reader went looking for an offline or read-only
            database that did not exist. Found while writing TestCase-IndexAnalysis-Walkthrough.sql.

            DB_ID() decides existence exactly as before. sys.databases supplies the rest. STUFF on an
            empty string returns NULL (verified), and Reason is NOT NULL, so a name DB_ID() resolves
            but sys.databases does not show this login gets an honest fallback instead of failing
            the insert. The same defect was in usp_ParameterSniffingDiagnostic and
            usp_FindTimeoutStatementsNQueryStore, fixed the same way; TestRunners\
            Validate-FleetSkipReasons.ps1 holds all three to it.                                  */
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
            RAISERROR(@Msg, 16, 1); RETURN;
        END;
        IF NOT EXISTS (SELECT 1 FROM sys.databases
                       WHERE database_id = DB_ID(@DatabaseName)
                         AND state = 0 AND is_in_standby = 0 AND source_database_id IS NULL)
        BEGIN
            SET @Msg = N'Database ' + QUOTENAME(@DatabaseName) + N' is not online, is in standby, or is a snapshot.';
            RAISERROR(@Msg, 16, 1); RETURN;
        END;
        INSERT #DatabaseList (DatabaseName) VALUES (@DatabaseName);
    END;

    SELECT @DbCount = COUNT(*) FROM #DatabaseList;
    IF @DbCount = 0
    BEGIN
        /*  Say WHICH situation this is. With names in @IncludeDatabases the skipped-databases result
            set below carries each one's true reason, so point there rather than guess at a cause.
            Aligned 2026-09-13 with the sibling procedures, whose old wording asserted a single
            cause that was false whenever a database was excluded by name or as the host.        */
        SET @Msg = CASE WHEN @IncludeDatabases IS NOT NULL
                        THEN N'No eligible database to analyse: every database named in @IncludeDatabases was excluded. The skipped-databases result set gives each one''s reason.'
                        ELSE N'No eligible database to analyse: no online, writable, non-system database remains after @ExcludeDatabases and @ExcludeHostingDatabase.' END;
        RAISERROR(@Msg, 16, 1);
        IF EXISTS (SELECT 1 FROM #SkippedDatabases) SELECT DatabaseName, Reason FROM #SkippedDatabases ORDER BY DatabaseName;
        RETURN;
    END;

    /*----------------------------------------------------------------------------------------------
      REQUESTED TABLE NAMES -- split ONCE here (pure string work); resolved to object_ids per
      database inside the loop, in the target's context, because OBJECT_ID() is context-bound.
    ----------------------------------------------------------------------------------------------*/
    DROP TABLE IF EXISTS #RequestedNames;
    CREATE TABLE #RequestedNames (nm NVARCHAR(776) NOT NULL);

    /*  STATEMENT MODE (Piece 1) -- see IndexAnalysis_v1.sql Section 2b. The plan is parsed HERE, in
        the procedure's own context, because parsing XML needs no database context at all; only
        resolving the names it yields to object_ids does, and that happens in the target through the
        existing #RequestedNames path below, unchanged.                                            */
    IF @StatementMode = 1
       AND (NULLIF(LTRIM(RTRIM(@TableName)), N'') IS NOT NULL OR NULLIF(LTRIM(RTRIM(@TableList)), N'') IS NOT NULL)
    BEGIN
        RAISERROR('Statement mode takes its table scope FROM THE PLAN -- do not also set @TableName / @TableList.', 16, 1);
        RETURN;
    END;
    IF @StatementMode = 1 AND @AllDatabases = 1
    BEGIN
        RAISERROR('@StatementPlanXml analyses one statement, which belongs to ONE database -- use @DatabaseName, not @AllDatabases.', 16, 1);
        RETURN;
    END;

    DROP TABLE IF EXISTS #StatementPlan;
    CREATE TABLE #StatementPlan (plan_xml XML NULL);

    IF @StatementMode = 1
    BEGIN
        BEGIN TRY
            INSERT #StatementPlan (plan_xml) SELECT CONVERT(XML, @StatementPlanXml);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 6335
                RAISERROR('@StatementPlanXml is nested deeper than the 128 levels SQL Server''s xml type allows (Msg 6335), so this plan cannot be read here.', 16, 1);
            ELSE
                RAISERROR('@StatementPlanXml is not valid XML. Paste the whole <ShowPlanXML> ... </ShowPlanXML> document exactly as SHOWPLAN_XML returned it.', 16, 1);
            RETURN;
        END CATCH;

        IF NOT EXISTS (SELECT 1 FROM #StatementPlan sp
                       WHERE sp.plan_xml.exist('declare namespace p="http://schemas.microsoft.com/sqlserver/2004/07/showplan"; //p:RelOp') = 1)
        BEGIN
            RAISERROR('@StatementPlanXml parsed as XML but carries no <RelOp> operators -- it does not look like a showplan document.', 16, 1);
            RETURN;
        END;

        /*  Names only -- resolution to object_ids is the target's job. Same exclusions as the
            script: no @Table, another database, or a temp table / table variable.                */
        ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        INSERT #RequestedNames (nm)
        SELECT DISTINCT o.n.value('@Schema', 'NVARCHAR(300)') + N'.' + o.n.value('@Table', 'NVARCHAR(300)')
        FROM   #StatementPlan sp
        CROSS APPLY sp.plan_xml.nodes('//RelOp/*/Object') AS o(n)
        WHERE  o.n.value('@Table',  'NVARCHAR(300)') IS NOT NULL
          AND  o.n.value('@Schema', 'NVARCHAR(300)') IS NOT NULL
          AND  o.n.value('@Table',  'NVARCHAR(300)') NOT LIKE N'[[]#%'
          AND  o.n.value('@Table',  'NVARCHAR(300)') NOT LIKE N'[[]@%'
          AND  (o.n.value('@Database', 'NVARCHAR(300)') IS NULL
                OR o.n.value('@Database', 'NVARCHAR(300)') = QUOTENAME(COALESCE(@DatabaseName, DB_NAME())));

        IF NOT EXISTS (SELECT 1 FROM #RequestedNames)
        BEGIN
            RAISERROR('@StatementPlanXml names no table in %s. Check @DatabaseName matches the database the statement ran against.', 16, 1, @DatabaseName);
            RETURN;
        END;
    END;

    IF NULLIF(LTRIM(RTRIM(@TableName)), N'') IS NOT NULL
        INSERT #RequestedNames (nm) VALUES (LTRIM(RTRIM(@TableName)));

    IF NULLIF(LTRIM(RTRIM(@TableList)), N'') IS NOT NULL
        INSERT #RequestedNames (nm)
        SELECT LTRIM(RTRIM(SUBSTRING(N',' + @TableList + N',', t.n + 1,
                    CHARINDEX(N',', N',' + @TableList + N',', t.n + 1) - t.n - 1)))
        FROM (SELECT TOP (LEN(@TableList)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
              FROM master..spt_values) AS t
        WHERE SUBSTRING(N',' + @TableList + N',', t.n, 1) = N','
          AND CHARINDEX(N',', N',' + @TableList + N',', t.n + 1) > t.n
          AND LTRIM(RTRIM(SUBSTRING(N',' + @TableList + N',', t.n + 1,
                    CHARINDEX(N',', N',' + @TableList + N',', t.n + 1) - t.n - 1))) <> N'';

    SET @ScopeToTables = CASE WHEN EXISTS (SELECT 1 FROM #RequestedNames) THEN 1 ELSE 0 END;

    /*==========================================================================================
      TEMP TABLES -- created ONCE here, in the outer scope, so the USE-wrapped dynamic batches can
      INSERT into them. TRUNCATEd at the top of every database iteration. Every CREATE below is
      character-identical to the matching one in IndexAnalysis_v1.sql -- the collection SQL that
      fills them is identical too, which is what the equivalence gate rests on.
    ==========================================================================================*/
    DROP TABLE IF EXISTS #TargetObjects;
    DROP TABLE IF EXISTS #TableMeta;
    DROP TABLE IF EXISTS #IndexColumns;
    DROP TABLE IF EXISTS #IndexMeta;
    DROP TABLE IF EXISTS #BufferPool;
    DROP TABLE IF EXISTS #UsageStats;
    DROP TABLE IF EXISTS #OperationalStats;
    DROP TABLE IF EXISTS #MissingIndex;
    DROP TABLE IF EXISTS #MissingIndexColumn;
    DROP TABLE IF EXISTS #ForeignKeyGap;
    DROP TABLE IF EXISTS #TableStructure;
    DROP TABLE IF EXISTS #FilterColumnGap;
    DROP TABLE IF EXISTS #HypotheticalIndex;
    DROP TABLE IF EXISTS #IndexStatsSample;
    DROP TABLE IF EXISTS #ResumableOp;
    DROP TABLE IF EXISTS #PlanEvidence;
    DROP TABLE IF EXISTS #PlanTableShape;
    DROP TABLE IF EXISTS #DependentHint;
    DROP TABLE IF EXISTS #DependentHintColumn;
    DROP TABLE IF EXISTS #DependentHintColumnRaw;
    DROP TABLE IF EXISTS #ProposalDependent;
    DROP TABLE IF EXISTS #ColumnWidth;
    DROP TABLE IF EXISTS #QsMissingBridge;
    DROP TABLE IF EXISTS #QsIndexUsage;
    DROP TABLE IF EXISTS #QsQueryWeight;
    DROP TABLE IF EXISTS #IndexAnalysis;
    DROP TABLE IF EXISTS #Results;
    DROP TABLE IF EXISTS #DropRiskResults;
    DROP TABLE IF EXISTS #PreflightNotes;

    CREATE TABLE #TargetObjects
    (
        object_id       INT           NOT NULL PRIMARY KEY,
        requested_name  NVARCHAR(776) NOT NULL
    );

    /*  Section 12g's inputs -- filled in the TARGET's context (see 3b), read by 12g from here.    */
    CREATE TABLE #TableStructure
    (
        object_id                  INT           NOT NULL PRIMARY KEY,
        non_nullable_columns       INT           NOT NULL,
        string_or_lob_columns      INT           NOT NULL,
        collation_mismatch_columns INT           NOT NULL,
        replicated_columns         INT           NOT NULL, /* sys.columns.is_replicated -- 12g's REPL token */
        columnstore_index_count    INT           NOT NULL, /* Tier 3: CSTORE<n> -- NOT collected elsewhere  */
        is_memory_optimized        BIT           NOT NULL, /* Tier 3: MEMOPT                                */
        identity_pct_used          DECIMAL(5,2)  NULL,
        has_cascading_fk           BIT           NOT NULL
    );

    /*  Section 12f's FILTCOL input and Section 12h's HYPO rows. Both are filled in the TARGET's
        context (see 4b / 4c) and read from here, so the analysis half needs no target context.
        See the script's Section 4b / 4c headers for why a hypothetical index cannot simply ride
        #IndexMeta -- its CROSS APPLY to sys.dm_db_partition_stats finds zero rows for one.        */
    CREATE TABLE #FilterColumnGap
    (
        object_id       INT           NOT NULL,
        index_id        INT           NOT NULL,
        missing_count   INT           NOT NULL,
        missing_columns NVARCHAR(MAX) NULL,
        PRIMARY KEY (object_id, index_id)
    );

    /*  Tier 3 inputs, both filled in the TARGET's context (4d / 4e) and read from the analysis
        half. See the script's Section 4d / 4e headers.                                           */
    CREATE TABLE #IndexStatsSample
    (
        object_id    INT           NOT NULL,
        index_id     INT           NOT NULL,
        stats_rows   BIGINT        NULL,
        rows_sampled BIGINT        NULL,
        sample_pct   DECIMAL(6,2)  NULL,
        PRIMARY KEY (object_id, index_id)
    );

    CREATE TABLE #ResumableOp
    (
        object_id        INT           NOT NULL,
        index_id         INT           NOT NULL,
        state_desc       NVARCHAR(60)  NULL,
        percent_complete DECIMAL(6,2)  NULL,
        PRIMARY KEY (object_id, index_id)
    );

    CREATE TABLE #HypotheticalIndex
    (
        object_id               INT           NOT NULL,
        index_id                INT           NOT NULL,
        index_name              SYSNAME       NULL,
        type_desc               NVARCHAR(60)  NOT NULL,
        is_unique               BIT           NOT NULL,
        key_columns_display     NVARCHAR(MAX) NULL,
        include_columns_display NVARCHAR(MAX) NULL,
        filter_definition       NVARCHAR(MAX) NULL,
        PRIMARY KEY (object_id, index_id)
    );

    CREATE TABLE #TableMeta
    (
        schema_id               INT            NOT NULL,
        schema_name             SYSNAME        NOT NULL,
        object_id               INT            NOT NULL PRIMARY KEY,
        table_name              SYSNAME        NOT NULL,
        object_name             NVARCHAR(300)  NOT NULL,
        table_column_count      INT            NOT NULL,
        table_row_count         BIGINT         NOT NULL,
        has_unique_index        BIT            NOT NULL,
        is_heap                 BIT            NOT NULL,
        has_xml_column          BIT            NOT NULL,
        has_native_json_column  BIT            NOT NULL,
        date_created            DATETIME       NULL,
        date_modified           DATETIME       NULL
    );

    CREATE TABLE #IndexColumns
    (
        object_id           INT      NOT NULL,
        index_id            INT      NOT NULL,
        column_id           INT      NOT NULL,
        column_name         SYSNAME  NOT NULL,
        key_ordinal         INT      NOT NULL,
        is_included         BIT      NOT NULL,
        is_descending_key   BIT      NOT NULL,
        is_clustering_key   BIT      NOT NULL,
        column_data_type    SYSNAME  NULL,
        is_lob              BIT      NOT NULL
    );

    CREATE TABLE #IndexMeta
    (
        object_id               INT            NOT NULL,
        index_id                INT            NOT NULL,
        index_name              SYSNAME        NULL,
        type_desc               NVARCHAR(60)   NOT NULL,
        is_primary_key          BIT            NOT NULL,
        is_unique               BIT            NOT NULL,
        is_unique_constraint    BIT            NOT NULL,
        is_disabled             BIT            NOT NULL,
        has_filter              BIT            NOT NULL,
        filter_definition       NVARCHAR(MAX)  NULL,
        fill_factor             TINYINT        NOT NULL,  /* sys.indexes.fill_factor; 0 = the default, i.e. 100 */
        filegroup_name          NVARCHAR(128)  NULL,
        data_compression_desc   NVARCHAR(60)   NULL,
        partition_number        INT            NOT NULL,
        partition_count         INT            NOT NULL,
        is_on_partition_scheme  BIT            NOT NULL,  /* sys.data_spaces.type = 'PS' -- Tier 3 PART/PARTNA */
        index_row_count         BIGINT         NOT NULL,
        reserved_page_count     BIGINT         NOT NULL,
        used_page_count         BIGINT         NOT NULL,
        size_mb                 DECIMAL(14,2)  NOT NULL,
        key_column_count        INT            NOT NULL,
        include_column_count    INT            NOT NULL,
        key_columns_display     NVARCHAR(MAX)  NULL,
        include_columns_display NVARCHAR(MAX)  NULL,
        key_signature           NVARCHAR(MAX)  NOT NULL,
        include_signature       NVARCHAR(MAX)  NOT NULL,
        distinct_key_signature  NVARCHAR(MAX)  NOT NULL,
        PRIMARY KEY (object_id, index_id, partition_number)
    );

    CREATE TABLE #BufferPool
    (
        object_id           INT           NOT NULL,
        index_id            INT           NOT NULL,
        partition_number    INT           NOT NULL,
        buffered_page_count BIGINT        NOT NULL,
        buffered_mb         DECIMAL(14,2) NOT NULL,
        PRIMARY KEY (object_id, index_id, partition_number)
    );

    CREATE TABLE #UsageStats
    (
        object_id       INT     NOT NULL,
        index_id        INT     NOT NULL,
        user_seeks      BIGINT  NOT NULL,
        user_scans      BIGINT  NOT NULL,
        user_lookups    BIGINT  NOT NULL,
        user_updates    BIGINT  NOT NULL,
        last_user_read  DATETIME NULL,
        last_user_update DATETIME NULL,
        PRIMARY KEY (object_id, index_id)
    );

    CREATE TABLE #OperationalStats
    (
        object_id                    INT     NOT NULL,
        index_id                     INT     NOT NULL,
        partition_number             INT     NOT NULL,
        range_scan_count             BIGINT  NOT NULL,
        singleton_lookup_count       BIGINT  NOT NULL,
        row_lock_count               BIGINT  NOT NULL,
        row_lock_wait_count          BIGINT  NOT NULL,
        row_lock_wait_in_ms          BIGINT  NOT NULL,
        page_lock_count              BIGINT  NOT NULL,
        page_lock_wait_count         BIGINT  NOT NULL,
        page_lock_wait_in_ms         BIGINT  NOT NULL,
        page_latch_wait_count        BIGINT  NOT NULL,
        page_latch_wait_in_ms        BIGINT  NOT NULL,
        page_io_latch_wait_count     BIGINT  NOT NULL,
        page_io_latch_wait_in_ms     BIGINT  NOT NULL,
        leaf_insert_count            BIGINT  NOT NULL,
        leaf_delete_count            BIGINT  NOT NULL,
        leaf_update_count            BIGINT  NOT NULL,
        leaf_ghost_count             BIGINT  NOT NULL,
        leaf_allocation_count        BIGINT  NOT NULL,
        nonleaf_allocation_count     BIGINT  NOT NULL,
        leaf_page_merge_count        BIGINT  NOT NULL,
        page_compression_attempt_count BIGINT NOT NULL,
        page_compression_success_count BIGINT NOT NULL,
        forwarded_fetch_count        BIGINT  NOT NULL,  /* heaps only -- Section 12i's HEAPFWD */
        PRIMARY KEY (object_id, index_id, partition_number)
    );

    CREATE TABLE #MissingIndex
    (
        missing_index_id        INT IDENTITY(1,1) PRIMARY KEY,
        group_handle            INT            NULL,   /* NULL for a Section 9d proposal: mined from a dependent's plan, no DMV group behind it */
        index_handle            INT            NULL,
        object_id               INT            NOT NULL,
        unique_compiles         BIGINT         NOT NULL,
        user_seeks              BIGINT         NOT NULL,
        user_scans              BIGINT         NOT NULL,
        avg_total_user_cost     FLOAT          NOT NULL,
        avg_user_impact         FLOAT          NOT NULL,
        last_user_seek          DATETIME       NULL,
        impact                  DECIMAL(18,4)  NOT NULL,
        equality_columns        NVARCHAR(MAX)  NULL,
        inequality_columns      NVARCHAR(MAX)  NULL,
        included_columns        NVARCHAR(MAX)  NULL,
        driving_evidence_id     INT            NULL,   /* Section 9d / 11a-2: the #PlanEvidence plan whose shape this proposal takes */
        proposal_source         VARCHAR(12)    NOT NULL /* DMV (Section 8) | DEPENDENT (Section 9d: the hint in a dependent object's own plan) */
    );

    /*  Section 9d working tables -- the optimizer's own missing-index hints, read out of the
        EXISTING plans of a table's Section 9b dependents. See the script's Section 9d header.    */
    CREATE TABLE #DependentHint
    (
        hint_id              INT IDENTITY(1,1) PRIMARY KEY,
        evidence_id          INT           NOT NULL,
        dependent_object_id  INT           NULL,       /* NULL when the plan is a pasted @StatementPlanXml, which is not an object */
        referenced_object_id INT           NOT NULL,
        hint_impact          FLOAT         NOT NULL,
        hint_xml             XML           NULL,
        eq_sig               NVARCHAR(MAX) NULL,
        ineq_sig             NVARCHAR(MAX) NULL,
        incl_sig             NVARCHAR(MAX) NULL,
        equality_columns     NVARCHAR(MAX) NULL,
        inequality_columns   NVARCHAR(MAX) NULL,
        included_columns     NVARCHAR(MAX) NULL,
        missing_index_id     INT           NULL
    );

    CREATE TABLE #DependentHintColumn
    (
        hint_id       INT         NOT NULL,
        column_id     INT         NOT NULL,
        column_name   SYSNAME     NOT NULL,
        column_usage  VARCHAR(20) NOT NULL,
        ordinal       INT         NOT NULL,
        PRIMARY KEY (hint_id, column_usage, column_id)
    );

    CREATE TABLE #ProposalDependent
    (
        missing_index_id    INT           NOT NULL,
        source_label        NVARCHAR(400) NOT NULL,   /* "[schema].[object] (QS|CACHE)" or "<<pasted statement>> (STATEMENT)" */
        PRIMARY KEY (missing_index_id, source_label)
    );

    CREATE TABLE #MissingIndexColumn
    (
        missing_index_id  INT      NOT NULL,
        column_id         INT      NOT NULL,
        column_name       SYSNAME  NOT NULL,
        column_usage      VARCHAR(20) NOT NULL,
        ordinal           INT      NOT NULL,
        PRIMARY KEY (missing_index_id, column_id, column_usage)
    );

    CREATE TABLE #ForeignKeyGap
    (
        foreign_key_name   SYSNAME        NOT NULL,
        parent_object_id   INT            NOT NULL,
        referenced_object_id INT          NOT NULL,
        fk_column_count    INT            NOT NULL,
        fk_columns_display NVARCHAR(MAX)  NOT NULL,
        fk_key_signature   NVARCHAR(MAX)  NOT NULL,
        PRIMARY KEY (foreign_key_name, parent_object_id)
    );

    CREATE TABLE #DependentObject                  /* Section 9b -- see the script's header for the model */
    (
        referenced_object_id INT           NOT NULL,   /* the table in scope */
        dependent_object_id  INT           NOT NULL,
        dependent_schema     SYSNAME       NOT NULL,
        dependent_name       SYSNAME       NOT NULL,
        dependent_type_desc  NVARCHAR(60)  NOT NULL,   /* sys.objects.type_desc, or 'FOREIGN KEY (child table)' */
        dependency_kind      VARCHAR(12)   NOT NULL,   /* EXPRESSION | FOREIGN_KEY */
        evidence_source      VARCHAR(10)   NOT NULL,   /* QS | CACHE | QS+CACHE | NONE | INLINED | STRUCTURAL */
        last_evidence_time   DATETIME2(3)  NULL,       /* UTC; NULL when there is no plan evidence */
        PRIMARY KEY (referenced_object_id, dependent_object_id, dependency_kind)
    );

    CREATE TABLE #QsMissingBridge
    (
        bridge_id           INT IDENTITY(1,1) PRIMARY KEY,
        missing_index_id    INT           NOT NULL,
        query_id            BIGINT        NOT NULL,
        query_object_name   NVARCHAR(300) NULL,
        executions          BIGINT        NOT NULL,
        avg_duration_ms     DECIMAL(18,2) NOT NULL,
        total_duration_ms   DECIMAL(20,2) NOT NULL,
        avg_cpu_ms          DECIMAL(18,2) NOT NULL,
        match_method        VARCHAR(12)   NOT NULL
    );

    /*  THE INTAKE CONTRACT -- see the script's Section 11 header. Every plan the engine may read
        is a #PlanEvidence row with its provenance; every (plan, table) shape the engine wants is
        a #PlanTableShape row, filled by the 11-shape step. Query Store is the only source today. */
    CREATE TABLE #PlanEvidence
    (
        evidence_id         INT IDENTITY(1,1) PRIMARY KEY,
        evidence_source     VARCHAR(12)   NOT NULL,   /* QS today; DEPENDENT / STATEMENT are the planned next two */
        query_id            BIGINT        NULL,       /* Query Store query_id; NULL for a plan that is not from Query Store */
        plan_id             BIGINT        NULL,       /* Query Store plan_id;  ditto */
        query_object_id     INT           NULL,       /* the object the plan belongs to; 0 / NULL = ad hoc */
        executions          BIGINT        NOT NULL,
        total_duration_ms   DECIMAL(20,2) NOT NULL,
        total_cpu_ms        DECIMAL(20,2) NOT NULL,
        avg_duration_ms     DECIMAL(18,2) NOT NULL,
        plan_xml            XML           NULL,
        plan_text           NVARCHAR(MAX) NULL        /* set ONLY when plan_xml could not be converted (a plan too deep for xml); Section 11b searches it */
    );

    CREATE TABLE #PlanTableShape
    (
        evidence_id         INT           NOT NULL,
        object_id           INT           NOT NULL,
        order_by_cols       NVARCHAR(MAX) NULL,       /* 11-shape: outermost result Sort, this table's columns, ` DESC` kept */
        group_by_cols       NVARCHAR(MAX) NULL,       /* 11-shape: first GroupBy, this table's columns, alphabetical */
        has_window_op       BIT           NULL,       /* 11-shape; NULL = requested, not yet shredded */
        PRIMARY KEY (evidence_id, object_id)
    );

    /*  Section 12e's per-column byte-width / key-eligibility table. Filled in the TARGET's context
        (sys.columns is per-database); created here so the dynamic batch that fills it can see it.
        Types from sys.dm_exec_describe_first_result_set over the script's own SELECT, not typed by
        hand (the script builds it with SELECT ... INTO).                                          */
    CREATE TABLE #ColumnWidth
    (
        object_id           INT            NOT NULL,
        column_name         NVARCHAR(128)  NOT NULL,
        ineligible_reason   NVARCHAR(231)  NULL,
        is_variable_length  INT            NOT NULL,
        estimated_bytes     INT            NULL
    );

    CREATE TABLE #QsIndexUsage
    (
        usage_id           INT IDENTITY(1,1) PRIMARY KEY,
        object_id          INT           NOT NULL,
        index_id           INT           NOT NULL,
        index_name_raw     NVARCHAR(300) NULL,
        query_id           BIGINT        NOT NULL,
        executions         BIGINT        NOT NULL,
        total_duration_ms  DECIMAL(20,2) NOT NULL,
        avg_duration_ms    DECIMAL(18,2) NOT NULL,
        access_op          VARCHAR(20)   NOT NULL
    );

    CREATE TABLE #QsQueryWeight
    (
        object_id           INT           NOT NULL PRIMARY KEY,
        qs_executions       BIGINT        NOT NULL,
        qs_total_duration_ms DECIMAL(20,2) NOT NULL,
        qs_total_cpu_ms     DECIMAL(20,2) NOT NULL,
        qs_weight           DECIMAL(20,2) NOT NULL
    );

    CREATE TABLE #IndexAnalysis
    (
        analysis_id             INT IDENTITY(1,1) PRIMARY KEY,
        row_kind                VARCHAR(10)    NOT NULL,   /* INDEX | MISSING | FKGAP | DEPENDENT */
        schema_name             SYSNAME        NOT NULL,
        table_name              SYSNAME        NOT NULL,
        object_name             NVARCHAR(300)  NOT NULL,
        object_id               INT            NOT NULL,
        index_id                INT            NULL,
        index_name              NVARCHAR(300)  NOT NULL,
        type_desc               NVARCHAR(60)   NULL,
        partition_number        INT            NULL,
        is_primary_key          BIT            NULL,
        is_unique               BIT            NULL,
        is_unique_constraint    BIT            NULL,   /* INDEX rows: a UNIQUE CONSTRAINT (not a plain unique index) -- like
                                                           is_primary_key, needs ALTER TABLE to re-add, not CREATE INDEX. Not
                                                           output anywhere; feeds the DROP-row create_index_sql reconstruction only. */
        is_disabled             BIT            NULL,
        is_heap                 BIT            NULL,
        has_filter              BIT            NULL,
        filter_definition       NVARCHAR(MAX)  NULL,
        fill_factor             TINYINT        NULL,   /* INDEX rows: sys.indexes.fill_factor, 0 = default (100). Internal like
                                                          is_unique_constraint -- not in any output SELECT; the FILL<n> con
                                                          carries the number, so no result-set shape changed for it.        */
        filegroup_name          NVARCHAR(128)  NULL,
        data_compression_desc   NVARCHAR(60)   NULL,
        table_row_count         BIGINT         NULL,
        index_row_count         BIGINT         NULL,
        size_mb                 DECIMAL(14,2)  NULL,
        buffered_mb             DECIMAL(14,2)  NULL,
        table_buffered_mb       DECIMAL(14,2)  NULL,
        pct_in_buffer           DECIMAL(6,2)   NULL,
        key_column_count        INT            NULL,
        include_column_count    INT            NULL,
        table_column_count      INT            NULL,
        key_columns_display     NVARCHAR(MAX)  NULL,
        include_columns_display NVARCHAR(MAX)  NULL,
        key_signature           NVARCHAR(MAX)  NULL,
        include_signature       NVARCHAR(MAX)  NULL,
        distinct_key_signature  NVARCHAR(MAX)  NULL,
        user_seeks              BIGINT         NULL,
        user_scans              BIGINT         NULL,
        user_lookups            BIGINT         NULL,
        user_updates            BIGINT         NULL,
        user_total              BIGINT         NULL,
        reads_per_write         DECIMAL(18,2)  NULL,
        user_total_pct          DECIMAL(6,2)   NULL,
        last_user_read          DATETIME       NULL,
        row_lock_wait_in_ms     BIGINT         NULL,
        /*  Section 12i's inputs -- INTERNAL, not output columns, so #Results is untouched. They
            cannot ride inside their own tokens either: all three are live operational counters and
            index_cons is compared strictly, so LOCKWAIT / HEAPFWD / HEAPDEL are flags. See the
            script's Section 12i header.                                                          */
        page_lock_wait_in_ms    BIGINT         NULL,
        forwarded_fetch_count   BIGINT         NULL,
        leaf_delete_count       BIGINT         NULL,
        /*  Section 12j's inputs, also internal. stats_sample_pct DOES ride inside its token,
            unlike the Tier 2 three: statistics metadata only moves when statistics are rebuilt,
            which needs writes, and no gate run writes to what it analyses.                       */
        partition_count         INT            NULL,
        is_on_partition_scheme  BIT            NULL,
        stats_sample_pct        DECIMAL(6,2)   NULL,
        has_resumable_op        BIT            NULL,
        page_latch_wait_count   BIGINT         NULL,
        page_latch_wait_in_ms   BIGINT         NULL,
        leaf_allocation_count   BIGINT         NULL,
        page_compression_success_rate DECIMAL(6,2) NULL,
        ops_scan_pct            DECIMAL(6,2)   NULL,   /* S -- range_scan_count / D   (D = the MS paper's denominator) */
        ops_update_pct          DECIMAL(6,2)   NULL,   /* U -- leaf_update_count / D                                   */
        ops_insert_pct          DECIMAL(6,2)   NULL,   /* leaf_insert_count / D -- for the append-only carve-out        */
        recommended_compression VARCHAR(4)     NULL,   /* 'PAGE' or NULL -- Section 12d. ROW is never recommended.      */
        compression_reason      NVARCHAR(400)  NULL,
        compression_sql         NVARCHAR(MAX)  NULL,   /* commented ALTER INDEX/TABLE ... REBUILD WITH (DATA_COMPRESSION = PAGE) */
        missing_impact          DECIMAL(18,4)  NULL,
        missing_unique_compiles BIGINT         NULL,
        equality_columns        NVARCHAR(MAX)  NULL,
        inequality_columns      NVARCHAR(MAX)  NULL,
        missing_include_columns NVARCHAR(MAX)  NULL,
        missing_order_by_cols   NVARCHAR(MAX)  NULL,   /* MISSING rows: driving QS query's ORDER BY cols ([Bracketed], ' DESC' kept) -- for an FPOC realign */
        missing_group_by_cols   NVARCHAR(MAX)  NULL,   /* MISSING rows: that query's GROUP BY cols                                                            */
        missing_window_kind     NVARCHAR(4)    NULL,   /* MISSING rows: 'FPOC' (proposal carries a filter) / 'POC' (none) when the driving plan has a
                                                         window operator (Sequence Project / Segment / Window Aggregate); NULL otherwise -- labels the
                                                         realigned key as a windowing POC index (OVER () is not parsed; the shredded GROUP BY IS it). */
        proposal_source         VARCHAR(12)    NULL,   /* MISSING rows: DMV (Section 8) | DEPENDENT (Section 9d: a hint in a dependent's own plan)  */
        dependent_sources       NVARCHAR(MAX)  NULL,   /* MISSING rows: the Section 9b dependents whose plans carry this hint, "[s].[n] (QS|CACHE)" */
        dependency_kind         VARCHAR(12)    NULL,   /* DEPENDENT rows (Section 9b): EXPRESSION | FOREIGN_KEY                      */
        evidence_source         VARCHAR(10)    NULL,   /* DEPENDENT rows: QS | CACHE | QS+CACHE | NONE | INLINED | STRUCTURAL        */
        last_evidence_time      DATETIME2(3)   NULL,   /* DEPENDENT rows: newest plan evidence, UTC; NULL when there is none         */
        fk_column_count         INT            NULL,
        duplicate_of            NVARCHAR(MAX)  NULL,
        overlaps_with           NVARCHAR(MAX)  NULL,
        sibling_of              NVARCHAR(MAX)  NULL,
        blend_target_index      NVARCHAR(300)  NULL,
        qs_query_ids            NVARCHAR(MAX)  NULL,
        qs_executions           BIGINT         NULL,
        qs_avg_duration_ms      DECIMAL(18,2)  NULL,
        qs_total_duration_ms    DECIMAL(20,2)  NULL,
        qs_avg_cpu_ms           DECIMAL(18,2)  NULL,
        qs_table_weight         DECIMAL(20,2)  NULL,
        qs_drop_risk_query_ct   INT            NULL,
        rank_source             VARCHAR(5)     NULL,
        table_rank              INT            NULL,
        index_action            VARCHAR(16)    NULL,
        index_pros              VARCHAR(200)   NULL,
        index_cons             VARCHAR(200)   NULL,
        create_index_sql        NVARCHAR(MAX)  NULL,
        drop_index_sql          NVARCHAR(MAX)  NULL,
        realigned_create_index_sql NVARCHAR(MAX) NULL   /* MISSING rows only: create_index_sql
                                                            reordered equality -> GROUP BY -> ORDER
                                                            BY (last) -- see 13b. */
    );

    /*  #Results -- the primary output accumulator. Its columns are inherited from #IndexAnalysis
        (SELECT ... INTO ... WHERE 1 = 0), never retyped, so the two can never drift on type. A
        leading DatabaseName and a trailing SourceAnalysisId (a plain INT copy of #IndexAnalysis's
        IDENTITY, so the copy carries no IDENTITY property) are added. */
    SELECT
        CAST(NULL AS sysname) AS DatabaseName,
        ia.row_kind, ia.schema_name, ia.table_name, ia.object_name, ia.object_id, ia.index_id,
        ia.index_name, ia.type_desc, ia.partition_number, ia.is_primary_key, ia.is_unique,
        ia.is_disabled, ia.is_heap, ia.has_filter, ia.filter_definition, ia.filegroup_name,
        ia.data_compression_desc, ia.table_row_count, ia.index_row_count, ia.size_mb, ia.buffered_mb,
        ia.table_buffered_mb, ia.pct_in_buffer, ia.key_column_count, ia.include_column_count,
        ia.table_column_count, ia.key_columns_display, ia.include_columns_display, ia.key_signature,
        ia.include_signature, ia.distinct_key_signature, ia.user_seeks, ia.user_scans,
        ia.user_lookups, ia.user_updates, ia.user_total, ia.reads_per_write, ia.user_total_pct,
        ia.last_user_read, ia.row_lock_wait_in_ms, ia.page_latch_wait_count, ia.page_latch_wait_in_ms,
        ia.leaf_allocation_count, ia.page_compression_success_rate,
        ia.ops_scan_pct, ia.ops_update_pct, ia.ops_insert_pct, ia.recommended_compression, ia.compression_reason,
        ia.missing_impact,
        ia.missing_unique_compiles, ia.equality_columns, ia.inequality_columns,
        ia.missing_include_columns, ia.missing_order_by_cols, ia.missing_group_by_cols,
        ia.missing_window_kind, ia.proposal_source, ia.dependent_sources,
        ia.dependency_kind, ia.evidence_source, ia.last_evidence_time,
        ia.fk_column_count, ia.duplicate_of, ia.overlaps_with,
        ia.sibling_of, ia.blend_target_index, ia.qs_query_ids, ia.qs_executions,
        ia.qs_avg_duration_ms, ia.qs_total_duration_ms, ia.qs_avg_cpu_ms, ia.qs_table_weight,
        ia.qs_drop_risk_query_ct, ia.rank_source, ia.table_rank, ia.index_action, ia.index_pros,
        ia.index_cons, ia.create_index_sql, ia.drop_index_sql, ia.realigned_create_index_sql, ia.compression_sql,
        CAST(ia.analysis_id AS INT) AS SourceAnalysisId,
        CAST(NULL AS VARCHAR(12)) AS match_method   /* MISSING mode: 'HASH' (2019+) or 'PLANXML' */
    INTO #Results
    FROM #IndexAnalysis ia
    WHERE 1 = 0;

    CREATE TABLE #DropRiskResults
    (
        DatabaseName      sysname       NULL,
        object_name       NVARCHAR(300) NULL,
        index_name        NVARCHAR(300) NULL,
        index_action      VARCHAR(16)   NULL,
        query_id          BIGINT        NULL,
        access_op         VARCHAR(20)   NULL,
        executions        BIGINT        NULL,
        total_duration_ms DECIMAL(20,2) NULL,
        avg_duration_ms   DECIMAL(18,2) NULL
    );

    CREATE TABLE #PreflightNotes
    (
        DatabaseName sysname       NOT NULL,
        Note         NVARCHAR(400) NOT NULL
    );

    /*==========================================================================================
      PER-DATABASE LOOP. Watermark, not a cursor -- matches usp_ParameterSniffingDiagnostic and
      usp_SQL_Server_System_Report.

      COLLECTION PATTERN. Each Section 3-9 block is a plain, un-escaped copy of the script's SQL
      held in @Inner, run by a NESTED sp_executesql that inherits the USE [target] context the
      outer batch sets. Only the tiny outer wrapper ("EXEC sys.sp_executesql @InnerIn, <sig>...")
      carries any quote doubling -- the collection SQL itself needs none, which is what keeps it
      character-identical to the script and the equivalence test meaningful.
    ==========================================================================================*/
    DECLARE @LoopDb sysname = (SELECT MIN(DatabaseName) FROM #DatabaseList);

    WHILE @LoopDb IS NOT NULL
    BEGIN
        SET @DbId       = DB_ID(@LoopDb);
        SET @DbQuoted   = QUOTENAME(@LoopDb);
        SET @Use        = N'USE ' + @DbQuoted + N';' + NCHAR(13) + NCHAR(10);
        SET @Unresolved = NULL;
        SET @SkipReason = NULL;

        SELECT @DatabaseCompatibilityLevel = compatibility_level
        FROM sys.databases WHERE database_id = @DbId;

        /*  Reset every per-iteration temp table. TRUNCATE (not DELETE) so the IDENTITY seeds on
            #IndexAnalysis / #MissingIndex / #PlanEvidence / #QsMissingBridge / #QsIndexUsage
            restart at 1 for every database -- exactly what a fresh run of the script produces.  */
        TRUNCATE TABLE #TargetObjects;      TRUNCATE TABLE #TableMeta;
        TRUNCATE TABLE #TableStructure;
        TRUNCATE TABLE #FilterColumnGap;    TRUNCATE TABLE #HypotheticalIndex;
        TRUNCATE TABLE #IndexStatsSample;   TRUNCATE TABLE #ResumableOp;
        TRUNCATE TABLE #IndexColumns;       TRUNCATE TABLE #IndexMeta;
        TRUNCATE TABLE #BufferPool;         TRUNCATE TABLE #UsageStats;
        TRUNCATE TABLE #OperationalStats;   TRUNCATE TABLE #MissingIndex;
        TRUNCATE TABLE #MissingIndexColumn; TRUNCATE TABLE #ForeignKeyGap;
        TRUNCATE TABLE #DependentObject;
        TRUNCATE TABLE #PlanEvidence;       TRUNCATE TABLE #PlanTableShape;
        TRUNCATE TABLE #DependentHint;      TRUNCATE TABLE #DependentHintColumn;
        TRUNCATE TABLE #ProposalDependent;  TRUNCATE TABLE #ColumnWidth;
        TRUNCATE TABLE #QsMissingBridge;    TRUNCATE TABLE #QsIndexUsage;
        TRUNCATE TABLE #QsQueryWeight;
        TRUNCATE TABLE #IndexAnalysis;

        /*--------------------------------------------------------------------------------------
          TARGET TABLE RESOLUTION -- in the target's context (OBJECT_ID is context bound). Any
          unresolved name skips the whole database (@AllDatabases = 1) or aborts (@AllDatabases
          = 0): a partial list is never silently analysed, same rule as the script.
        --------------------------------------------------------------------------------------*/
        IF @ScopeToTables = 1
        BEGIN
            SET @Sql = @Use + N'
            INSERT #TargetObjects (object_id, requested_name)
            SELECT OBJECT_ID(r.nm), MIN(r.nm)
            FROM   #RequestedNames r
            WHERE  OBJECT_ID(r.nm) IS NOT NULL
              AND  OBJECT_ID(r.nm) IN (SELECT object_id FROM sys.tables)
            GROUP BY OBJECT_ID(r.nm);

            SELECT @UnresolvedOut = STUFF((SELECT N'', '' + r.nm
                                          FROM   #RequestedNames r
                                          WHERE  OBJECT_ID(r.nm) IS NULL
                                             OR  OBJECT_ID(r.nm) NOT IN (SELECT object_id FROM sys.tables)
                                          FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), 1, 2, N'''');';
            EXEC sys.sp_executesql @Sql, N'@UnresolvedOut NVARCHAR(MAX) OUTPUT', @UnresolvedOut = @Unresolved OUTPUT;

            /*  A name the CALLER typed and that does not resolve is an error -- a partial list is
                never silently analysed. A name derived from a pasted PLAN is different: the caller
                never wrote it, and a plan legitimately names things that are not user tables here
                (a view expanded elsewhere, a cross-database object). Those are dropped, and only an
                empty result is an error. Same distinction the script makes.                       */
            IF @Unresolved IS NOT NULL AND @StatementMode = 0
                SET @SkipReason = N'requested table(s) not found here: ' + @Unresolved;

            IF @StatementMode = 1 AND NOT EXISTS (SELECT 1 FROM #TargetObjects)
                SET @SkipReason = N'@StatementPlanXml names no user table here';
        END;

        /*--------------------------------------------------------------------------------------
          PREFLIGHT -- in the target's context so every probe answers for the target.
        --------------------------------------------------------------------------------------*/
        IF @SkipReason IS NULL
        BEGIN
            SET @HasQueryStore = 0; SET @HasMissingIndexQueryDmv = 0; SET @HasNativeJsonType = 0;
            SET @QsActualState = NULL; SET @QsStateDesc = NULL;

            SET @Sql = @Use + N'
            SELECT @HasQsOut   = CASE WHEN OBJECT_ID(''sys.query_store_query'')                     IS NULL THEN 0 ELSE 1 END,
                   @HasMidqOut = CASE WHEN OBJECT_ID(''sys.dm_db_missing_index_group_stats_query'') IS NULL THEN 0 ELSE 1 END,
                   @HasJsonOut = CASE WHEN @MajorVersionIn >= 17 THEN 1
                                      WHEN @MajorVersionIn IS NULL
                                           AND EXISTS (SELECT 1 FROM sys.types WHERE name = ''json'' AND system_type_id = user_type_id)
                                           THEN 1
                                      ELSE 0 END;
            IF OBJECT_ID(''sys.database_query_store_options'') IS NOT NULL
                SELECT @QsStateOut = actual_state, @QsStateDescOut = actual_state_desc
                FROM sys.database_query_store_options;';
            EXEC sys.sp_executesql @Sql,
                 N'@MajorVersionIn INT,
                   @HasQsOut BIT OUTPUT, @HasMidqOut BIT OUTPUT, @HasJsonOut BIT OUTPUT,
                   @QsStateOut TINYINT OUTPUT, @QsStateDescOut NVARCHAR(60) OUTPUT',
                 @MajorVersionIn = @MajorVersion,
                 @HasQsOut = @HasQueryStore OUTPUT, @HasMidqOut = @HasMissingIndexQueryDmv OUTPUT,
                 @HasJsonOut = @HasNativeJsonType OUTPUT,
                 @QsStateOut = @QsActualState OUTPUT, @QsStateDescOut = @QsStateDesc OUTPUT;

            SET @QueryStoreUsable = CASE WHEN @HasQueryStore = 1 AND @QsActualState IN (1, 2) THEN 1 ELSE 0 END;
            SET @EffectiveRankingSource = CASE WHEN @QueryStoreUsable = 0 THEN 'DMV' ELSE @RankingSource END;

            IF @RankingSource <> 'DMV' AND @QueryStoreUsable = 0
                INSERT #PreflightNotes (DatabaseName, Note)
                VALUES (@LoopDb, N'Query Store not readable (actual_state '
                                 + ISNULL(CONVERT(NVARCHAR(10), @QsActualState), N'NULL')
                                 + N'). Section 11 correlation skipped; ranking fell back to DMV counters.');

            IF @DaysSinceStartup < @UnusedIndexMinDaysSinceStartup
                INSERT #PreflightNotes (DatabaseName, Note)
                VALUES (@LoopDb, N'Instance started ' + CONVERT(NVARCHAR(10), @DaysSinceStartup)
                                 + N' day(s) ago (< @UnusedIndexMinDaysSinceStartup = '
                                 + CONVERT(NVARCHAR(10), @UnusedIndexMinDaysSinceStartup)
                                 + N'). DROP-USAGE withheld; affected rows carry a TOOSOON con.');
        END;

        /*--------------------------------------------------------------------------------------
          SKIP / ABORT -- fatal when a single database was asked for, a skip under @AllDatabases.
        --------------------------------------------------------------------------------------*/
        IF @SkipReason IS NOT NULL
        BEGIN
            IF @AllDatabases = 0
            BEGIN
                SET @Msg = @DbQuoted + N': ' + @SkipReason
                         + N'. Aborting rather than returning an empty result, which would be indistinguishable from a database with no findings.';
                RAISERROR(@Msg, 16, 1);
                RETURN;
            END;
            INSERT #SkippedDatabases (DatabaseName, Reason) VALUES (@LoopDb, @SkipReason);
            IF @Debug = 1 RAISERROR('skipping %s: %s', 0, 0, @LoopDb, @SkipReason) WITH NOWAIT;
            SET @LoopDb = (SELECT MIN(DatabaseName) FROM #DatabaseList WHERE DatabaseName > @LoopDb);
            CONTINUE;
        END;

        /*====================================================================================
          COLLECTION -- Sections 3 through 9.
        ====================================================================================*/

        /*  3. #TableMeta  */
        SET @Inner = N'
INSERT #TableMeta
      (schema_id, schema_name, object_id, table_name, object_name, table_column_count,
       table_row_count, has_unique_index, is_heap, has_xml_column, has_native_json_column,
       date_created, date_modified)
SELECT s.schema_id,
       s.name,
       t.object_id,
       t.name,
       QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name),
       cc.column_count,
       COALESCE(rc.row_count, 0),
       CASE WHEN uq.object_id IS NOT NULL THEN 1 ELSE 0 END,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes hi
                         WHERE hi.object_id = t.object_id AND hi.index_id = 0) THEN 1 ELSE 0 END,
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns xc
                         JOIN sys.types xt ON xt.user_type_id = xc.user_type_id
                         WHERE xc.object_id = t.object_id AND xt.name = N''xml'') THEN 1 ELSE 0 END,
       CASE WHEN @HasNativeJsonType = 1
                 AND EXISTS (SELECT 1 FROM sys.columns jc
                             JOIN sys.types jt ON jt.user_type_id = jc.user_type_id
                             WHERE jc.object_id = t.object_id AND jt.name = N''json'')
            THEN 1 ELSE 0 END,
       t.create_date,
       t.modify_date
FROM   sys.tables  t
JOIN   sys.schemas s ON s.schema_id = t.schema_id
CROSS APPLY (SELECT COUNT(*) AS column_count FROM sys.columns c WHERE c.object_id = t.object_id) cc
OUTER APPLY (SELECT SUM(ps.row_count) AS row_count
             FROM sys.dm_db_partition_stats ps
             WHERE ps.object_id = t.object_id AND ps.index_id IN (0, 1)) rc
OUTER APPLY (SELECT TOP (1) i.object_id
             FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_unique = 1) uq
WHERE  t.is_ms_shipped = 0
  AND  t.type = N''U''
  AND  (@ScopeToTables = 0 OR t.object_id IN (SELECT object_id FROM #TargetObjects));';
        SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn, N''@HasNativeJsonType BIT, @ScopeToTables BIT'', @HasNativeJsonType = @HNJ, @ScopeToTables = @STT;';
        EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX), @HNJ BIT, @STT BIT',
             @InnerIn = @Inner, @HNJ = @HasNativeJsonType, @STT = @ScopeToTables;

        /*  3b. #TableStructure -- Section 12g's inputs. Every one needs the TARGET's catalog, so it
            is collected here; 12g itself then runs on temp tables only and needs no target context.
            Byte width is deliberately NOT collected -- 12g sums #ColumnWidth instead, so the
            per-type sizing rules keep exactly one home. See the script's Section 3b comment.      */
        SET @Inner = N'
INSERT #TableStructure (object_id, non_nullable_columns, string_or_lob_columns,
                        collation_mismatch_columns, replicated_columns, columnstore_index_count,
                        is_memory_optimized, identity_pct_used, has_cascading_fk)
SELECT tm.object_id,
       cnt.non_nullable_columns,
       cnt.string_or_lob_columns,
       cnt.collation_mismatch_columns,
       cnt.replicated_columns,
       /*  Tier 3. Section 4 collects rowstore only (type 0/1/2), so a columnstore index is
           invisible to the rest of this tool BY DESIGN -- B-tree reasoning says nothing true about
           one. Counted here so the reader is told they exist and are out of scope.               */
       (SELECT COUNT(*) FROM sys.indexes cs WHERE cs.object_id = tm.object_id AND cs.type IN (5, 6)),
       (SELECT CONVERT(BIT, COALESCE(MAX(CONVERT(TINYINT, t2.is_memory_optimized)), 0))
        FROM   sys.tables t2 WHERE t2.object_id = tm.object_id),
       idn.pct_used,
       CASE WHEN EXISTS (SELECT 1 FROM sys.foreign_keys fk
                         WHERE fk.parent_object_id = tm.object_id
                           AND (fk.delete_referential_action <> 0 OR fk.update_referential_action <> 0))
            THEN 1 ELSE 0 END
FROM   #TableMeta tm
CROSS APPLY (
    SELECT SUM(CASE WHEN c.is_nullable = 0 THEN 1 ELSE 0 END) AS non_nullable_columns,
           SUM(CASE WHEN c.max_length = -1
                         OR t.name IN (N''char'', N''varchar'', N''nchar'', N''nvarchar'', N''text'', N''ntext'', N''xml'', N''json'')
                    THEN 1 ELSE 0 END)                        AS string_or_lob_columns,
           SUM(CASE WHEN c.collation_name IS NOT NULL
                         AND c.collation_name <> CONVERT(NVARCHAR(128), DATABASEPROPERTYEX(DB_NAME(), ''Collation''))
                    THEN 1 ELSE 0 END)                        AS collation_mismatch_columns,
           /*  sp_BlitzIndex check 70. Counted over ALL of sys.columns, not the clustered index''s
               own column list the way theirs does -- is_replicated is a COLUMN property, so a heap
               or a narrow clustered key would otherwise understate it. See the script Section 3b.  */
           SUM(CASE WHEN c.is_replicated = 1 THEN 1 ELSE 0 END) AS replicated_columns
    FROM   sys.columns c
    JOIN   sys.types   t ON t.user_type_id = c.system_type_id
    WHERE  c.object_id = tm.object_id
) cnt
OUTER APPLY (
    SELECT TOP (1)
           CASE WHEN mx.max_value IS NULL OR CONVERT(FLOAT, ic.last_value) <= 0 THEN NULL
                ELSE CONVERT(DECIMAL(5,2), 100.0 * CONVERT(FLOAT, ic.last_value) / mx.max_value)
           END AS pct_used
    FROM   sys.identity_columns ic
    JOIN   sys.types ty ON ty.user_type_id = ic.system_type_id
    CROSS APPLY (SELECT CASE ty.name WHEN N''tinyint''  THEN 255.0
                                     WHEN N''smallint'' THEN 32767.0
                                     WHEN N''int''      THEN 2147483647.0
                                     WHEN N''bigint''   THEN 9223372036854775807.0
                                     ELSE NULL END AS max_value) mx
    WHERE  ic.object_id = tm.object_id
      AND  ic.last_value IS NOT NULL
) idn;';
        SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn;';
        EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX)', @InnerIn = @Inner;

        /*  4a. #IndexColumns -- declared key + include columns  */
        SET @Inner = N'
INSERT #IndexColumns (object_id, index_id, column_id, column_name, key_ordinal, is_included,
                      is_descending_key, is_clustering_key, column_data_type, is_lob)
SELECT ic.object_id, ic.index_id, ic.column_id, c.name,
       CASE WHEN ic.is_included_column = 1 THEN 0 ELSE ic.key_ordinal END,
       ic.is_included_column,
       ic.is_descending_key,
       0,
       ty.name,
       CASE WHEN ty.name IN (N''xml'',N''text'',N''ntext'',N''image'')
                 OR (ty.name IN (N''varchar'',N''nvarchar'',N''varbinary'') AND c.max_length = -1)
            THEN 1 ELSE 0 END
FROM   sys.index_columns ic
JOIN   sys.indexes  i  ON i.object_id = ic.object_id AND i.index_id = ic.index_id
JOIN   sys.columns  c  ON c.object_id = ic.object_id AND c.column_id = ic.column_id
JOIN   sys.types    ty ON ty.user_type_id = c.user_type_id
JOIN   #TableMeta   tm ON tm.object_id = ic.object_id
WHERE  i.type IN (1, 2)
  AND  i.is_hypothetical = 0;';
        SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn;';
        EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX)', @InnerIn = @Inner;

        /*  4b. #IndexColumns -- implicit clustering-key columns on each nonclustered index  */
        SET @Inner = N'
INSERT #IndexColumns (object_id, index_id, column_id, column_name, key_ordinal, is_included,
                      is_descending_key, is_clustering_key, column_data_type, is_lob)
SELECT nc.object_id, nc.index_id, ck.column_id, c.name, 0, 1, ck.is_descending_key, 1, ty.name,
       CASE WHEN ty.name IN (N''xml'',N''text'',N''ntext'',N''image'')
                 OR (ty.name IN (N''varchar'',N''nvarchar'',N''varbinary'') AND c.max_length = -1)
            THEN 1 ELSE 0 END
FROM   sys.indexes nc
JOIN   #TableMeta tm ON tm.object_id = nc.object_id
JOIN   sys.index_columns ck ON ck.object_id = nc.object_id AND ck.index_id = 1 AND ck.is_included_column = 0
JOIN   sys.columns c  ON c.object_id = ck.object_id AND c.column_id = ck.column_id
JOIN   sys.types   ty ON ty.user_type_id = c.user_type_id
WHERE  nc.type = 2 AND nc.is_hypothetical = 0
  AND  NOT EXISTS (SELECT 1 FROM sys.index_columns k2
                   WHERE k2.object_id = nc.object_id AND k2.index_id = nc.index_id
                     AND k2.column_id = ck.column_id AND k2.is_included_column = 0);';
        SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn;';
        EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX)', @InnerIn = @Inner;

        /*  4c. #IndexMeta  */
        SET @Inner = N'
INSERT #IndexMeta
      (object_id, index_id, index_name, type_desc, is_primary_key, is_unique, is_unique_constraint,
       is_disabled, has_filter, filter_definition, fill_factor, filegroup_name, data_compression_desc,
       partition_number, partition_count, is_on_partition_scheme,
       index_row_count, reserved_page_count, used_page_count,
       size_mb, key_column_count, include_column_count, key_columns_display, include_columns_display,
       key_signature, include_signature, distinct_key_signature)
SELECT i.object_id,
       i.index_id,
       i.name,
       CASE WHEN i.is_unique = 1 THEN N''UNIQUE '' ELSE N'''' END + i.type_desc,
       i.is_primary_key,
       i.is_unique,
       i.is_unique_constraint,
       i.is_disabled,
       CASE WHEN i.has_filter = 1 THEN 1 ELSE 0 END,
       i.filter_definition,
       i.fill_factor,
       ds.name,
       px.data_compression_desc,
       px.partition_number,
       px.partition_count,
       CASE WHEN ds.type = ''PS'' THEN 1 ELSE 0 END,
       px.row_count,
       px.reserved_page_count,
       px.used_page_count,
       CAST(px.reserved_page_count * 8.0 / 1024 AS DECIMAL(14,2)),
       kc.key_column_count,
       nc.include_column_count,
       kd.key_columns_display,
       nd.include_columns_display,
       ksig.key_signature,
       isig.include_signature,
       dsig.distinct_key_signature
FROM   sys.indexes i
JOIN   #TableMeta  tm ON tm.object_id = i.object_id
LEFT  JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
CROSS APPLY
(
    SELECT CASE WHEN @ConsolidatePartitionStats = 0 THEN p.partition_number ELSE -1 END AS partition_number,
           COUNT(*)                       AS partition_count,
           SUM(ps.row_count)              AS row_count,
           SUM(ps.reserved_page_count)    AS reserved_page_count,
           SUM(ps.used_page_count)        AS used_page_count,
           CASE MAX(p.data_compression)
                WHEN 0 THEN N''NONE'' WHEN 1 THEN N''ROW'' WHEN 2 THEN N''PAGE''
                WHEN 3 THEN N''COLUMNSTORE'' WHEN 4 THEN N''COLUMNSTORE_ARCHIVE'' ELSE N''MIXED'' END AS data_compression_desc
    FROM   sys.partitions p
    JOIN   sys.dm_db_partition_stats ps
             ON ps.object_id = p.object_id AND ps.index_id = p.index_id AND ps.partition_id = p.partition_id
    WHERE  p.object_id = i.object_id AND p.index_id = i.index_id
    GROUP  BY CASE WHEN @ConsolidatePartitionStats = 0 THEN p.partition_number ELSE -1 END
) px
CROSS APPLY (SELECT COUNT(*) AS key_column_count
             FROM #IndexColumns k
             WHERE k.object_id = i.object_id AND k.index_id = i.index_id AND k.is_included = 0) kc
CROSS APPLY (SELECT COUNT(*) AS include_column_count
             FROM #IndexColumns n
             WHERE n.object_id = i.object_id AND n.index_id = i.index_id
               AND n.is_included = 1 AND n.is_clustering_key = 0) nc
OUTER APPLY (SELECT STUFF((SELECT N'', '' + QUOTENAME(k.column_name)
                                  + CASE WHEN k.is_descending_key = 1 THEN N'' DESC'' ELSE N'''' END
                           FROM #IndexColumns k
                           WHERE k.object_id = i.object_id AND k.index_id = i.index_id AND k.is_included = 0
                           ORDER BY k.key_ordinal
                           FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), 1, 2, N'''')
             AS key_columns_display) kd
OUTER APPLY (SELECT STUFF((SELECT N'', '' + QUOTENAME(n.column_name)
                           FROM #IndexColumns n
                           WHERE n.object_id = i.object_id AND n.index_id = i.index_id
                             AND n.is_included = 1 AND n.is_clustering_key = 0
                           ORDER BY n.column_name
                           FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), 1, 2, N'''')
             AS include_columns_display) nd
CROSS APPLY (SELECT COALESCE((SELECT CONCAT(N''c'', k.column_id, CASE WHEN k.is_descending_key = 1 THEN N''D'' ELSE N''A'' END, N''.'')
                              FROM #IndexColumns k
                              WHERE k.object_id = i.object_id AND k.index_id = i.index_id AND k.is_included = 0
                              ORDER BY k.key_ordinal
                              FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), N'''')
             AS key_signature) ksig
CROSS APPLY (SELECT COALESCE((SELECT CONCAT(N''c'', n.column_id, N''.'')
                              FROM (SELECT DISTINCT column_id
                                    FROM #IndexColumns n2
                                    WHERE n2.object_id = i.object_id AND n2.index_id = i.index_id AND n2.is_included = 1) n
                              ORDER BY n.column_id
                              FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), N'''')
             AS include_signature) isig
CROSS APPLY (SELECT COALESCE((SELECT CONCAT(N''c'', d.column_id, N''.'')
                              FROM (SELECT DISTINCT column_id
                                    FROM #IndexColumns d2
                                    WHERE d2.object_id = i.object_id AND d2.index_id = i.index_id AND d2.is_included = 0) d
                              ORDER BY d.column_id
                              FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), N'''')
             AS distinct_key_signature) dsig
WHERE  i.type IN (0, 1, 2)
  AND  i.is_hypothetical = 0;';
        SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn, N''@ConsolidatePartitionStats BIT'', @ConsolidatePartitionStats = @CPS;';
        EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX), @CPS BIT',
             @InnerIn = @Inner, @CPS = @ConsolidatePartitionStats;

        /*  4d. #FilterColumnGap -- sp_BlitzIndex check 34. A filtered index whose WHERE names a
            column the index does not contain. Detected through sys.sql_expression_dependencies
            (referencing_class 7 = INDEX, referencing_minor_id = index_id, referenced_minor_id =
            column_id), NOT by parsing filter_definition text -- see the script's Section 4b header
            for the four-case probe that settled the semantics.                                     */
        SET @Inner = N'
INSERT #FilterColumnGap (object_id, index_id, missing_count, missing_columns)
SELECT i.object_id, i.index_id, cnt.missing_count, lst.missing_columns
FROM   sys.indexes i
JOIN   #TableMeta tm ON tm.object_id = i.object_id
CROSS APPLY (SELECT COUNT(*) AS missing_count
             FROM   sys.sql_expression_dependencies sed
             WHERE  sed.referenced_id        = i.object_id
               AND  sed.referencing_class    = 7
               AND  sed.referencing_minor_id = i.index_id
               AND  sed.referenced_class     = 1
               AND  sed.referenced_minor_id  > 0
               AND  NOT EXISTS (SELECT 1 FROM sys.index_columns ic
                                WHERE ic.object_id = sed.referenced_id
                                  AND ic.index_id  = sed.referencing_minor_id
                                  AND ic.column_id = sed.referenced_minor_id)) cnt
OUTER APPLY (SELECT STUFF((SELECT N'', '' + QUOTENAME(c.name)
                           FROM   sys.sql_expression_dependencies sed2
                           JOIN   sys.columns c ON c.object_id = sed2.referenced_id
                                               AND c.column_id = sed2.referenced_minor_id
                           WHERE  sed2.referenced_id        = i.object_id
                             AND  sed2.referencing_class    = 7
                             AND  sed2.referencing_minor_id = i.index_id
                             AND  sed2.referenced_class     = 1
                             AND  sed2.referenced_minor_id  > 0
                             AND  NOT EXISTS (SELECT 1 FROM sys.index_columns ic2
                                              WHERE ic2.object_id = sed2.referenced_id
                                                AND ic2.index_id  = sed2.referencing_minor_id
                                                AND ic2.column_id = sed2.referenced_minor_id)
                           ORDER  BY c.name
                           FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), 1, 2, N'''')
             AS missing_columns) lst
WHERE  i.has_filter = 1
  AND  i.is_hypothetical = 0
  AND  i.type IN (1, 2)
  AND  cnt.missing_count > 0;';
        SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn;';
        EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX)', @InnerIn = @Inner;

        /*  4e. #HypotheticalIndex -- sp_BlitzIndex check 41, Database Engine Tuning Advisor
            leftovers. Collected on its own because #IndexColumns / #IndexMeta both exclude
            is_hypothetical, and #IndexMeta could not carry one anyway: its CROSS APPLY to
            sys.dm_db_partition_stats finds ZERO rows for a hypothetical index, so the row would be
            eliminated silently. Emitted as row_kind = ''HYPO'' by Section 12h.                      */
        SET @Inner = N'
INSERT #HypotheticalIndex (object_id, index_id, index_name, type_desc, is_unique,
                           key_columns_display, include_columns_display, filter_definition)
SELECT i.object_id, i.index_id, i.name,
       CASE WHEN i.is_unique = 1 THEN N''UNIQUE '' ELSE N'''' END + i.type_desc,
       i.is_unique,
       kd.key_columns_display,
       nd.include_columns_display,
       i.filter_definition
FROM   sys.indexes i
JOIN   #TableMeta tm ON tm.object_id = i.object_id
OUTER APPLY (SELECT STUFF((SELECT N'', '' + QUOTENAME(c.name)
                                  + CASE WHEN ic.is_descending_key = 1 THEN N'' DESC'' ELSE N'''' END
                           FROM   sys.index_columns ic
                           JOIN   sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                           WHERE  ic.object_id = i.object_id AND ic.index_id = i.index_id
                             AND  ic.is_included_column = 0
                           ORDER  BY ic.key_ordinal
                           FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), 1, 2, N'''')
             AS key_columns_display) kd
OUTER APPLY (SELECT STUFF((SELECT N'', '' + QUOTENAME(c.name)
                           FROM   sys.index_columns ic
                           JOIN   sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                           WHERE  ic.object_id = i.object_id AND ic.index_id = i.index_id
                             AND  ic.is_included_column = 1
                           ORDER  BY c.name
                           FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), 1, 2, N'''')
             AS include_columns_display) nd
WHERE  i.is_hypothetical = 1
  AND  i.type IN (1, 2);';
        SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn;';
        EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX)', @InnerIn = @Inner;

        /*  4d. #IndexStatsSample -- how much of the table SQL Server read when it last built each
            INDEX's statistics. Index statistics only (stats_id = index_id); the auto-created
            _WA_Sys_* column statistics have no index row to hang a con on and are a statistics
            -maintenance finding rather than an index one. See the script's Section 4d header.    */
        SET @Inner = N'
INSERT #IndexStatsSample (object_id, index_id, stats_rows, rows_sampled, sample_pct)
SELECT s.object_id, s.stats_id, sp.rows, sp.rows_sampled,
       CONVERT(DECIMAL(6,2), sp.rows_sampled * 100.0 / NULLIF(sp.rows, 0))
FROM   sys.stats s
JOIN   #TableMeta tm ON tm.object_id = s.object_id
JOIN   sys.indexes i ON i.object_id = s.object_id AND i.index_id = s.stats_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE  i.type IN (1, 2)
  AND  sp.rows IS NOT NULL;';
        SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn;';
        EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX)', @InnerIn = @Inner;

        /*  4e. #ResumableOp -- a resumable ALTER INDEX paused and never finished. The half-built
            index keeps its allocation and blocks further DDL on it. sys.index_resumable_operations
            is 2017+, which needs no gate: this procedure already aborts below 2019.              */
        SET @Inner = N'
INSERT #ResumableOp (object_id, index_id, state_desc, percent_complete)
SELECT iro.object_id, iro.index_id, iro.state_desc,
       CONVERT(DECIMAL(6,2), iro.percent_complete)
FROM   sys.index_resumable_operations iro
JOIN   #TableMeta tm ON tm.object_id = iro.object_id;';
        SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn;';
        EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX)', @InnerIn = @Inner;

        /*  5. #BufferPool  (skipped when @IncludeBufferPool = 0)  */
        IF @IncludeBufferPool = 1
        BEGIN
            SET @Inner = N'
;WITH au AS
(
    SELECT p.object_id, p.index_id,
           CASE WHEN @ConsolidatePartitionStats = 0 THEN p.partition_number ELSE -1 END AS partition_number,
           a.allocation_unit_id
    FROM   sys.allocation_units a
    JOIN   sys.partitions p ON p.hobt_id = a.container_id AND a.type IN (1, 3)
    UNION ALL
    SELECT p.object_id, p.index_id,
           CASE WHEN @ConsolidatePartitionStats = 0 THEN p.partition_number ELSE -1 END,
           a.allocation_unit_id
    FROM   sys.allocation_units a
    JOIN   sys.partitions p ON p.partition_id = a.container_id AND a.type = 2
)
INSERT #BufferPool (object_id, index_id, partition_number, buffered_page_count, buffered_mb)
SELECT au.object_id, au.index_id, au.partition_number,
       COUNT_BIG(*),
       CAST(COUNT_BIG(*) * 8.0 / 1024 AS DECIMAL(14,2))
FROM   sys.dm_os_buffer_descriptors bd
JOIN   au ON au.allocation_unit_id = bd.allocation_unit_id
JOIN   #TableMeta tm ON tm.object_id = au.object_id
WHERE  bd.database_id = DB_ID()
GROUP  BY au.object_id, au.index_id, au.partition_number;';
            SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn, N''@ConsolidatePartitionStats BIT'', @ConsolidatePartitionStats = @CPS;';
            EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX), @CPS BIT',
                 @InnerIn = @Inner, @CPS = @ConsolidatePartitionStats;
        END;

        /*  6. #UsageStats  */
        SET @Inner = N'
INSERT #UsageStats (object_id, index_id, user_seeks, user_scans, user_lookups, user_updates,
                    last_user_read, last_user_update)
SELECT ius.object_id, ius.index_id,
       ius.user_seeks, ius.user_scans, ius.user_lookups, ius.user_updates,
       (SELECT MAX(v) FROM (VALUES (ius.last_user_seek), (ius.last_user_scan), (ius.last_user_lookup)) AS x(v)),
       ius.last_user_update
FROM   sys.dm_db_index_usage_stats ius
JOIN   #TableMeta tm ON tm.object_id = ius.object_id
WHERE  ius.database_id = DB_ID();';
        SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn;';
        EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX)', @InnerIn = @Inner;

        /*  7. #OperationalStats  */
        SET @Inner = N'
INSERT #OperationalStats
      (object_id, index_id, partition_number,
       range_scan_count, singleton_lookup_count,
       row_lock_count, row_lock_wait_count, row_lock_wait_in_ms,
       page_lock_count, page_lock_wait_count, page_lock_wait_in_ms,
       page_latch_wait_count, page_latch_wait_in_ms,
       page_io_latch_wait_count, page_io_latch_wait_in_ms,
       leaf_insert_count, leaf_delete_count, leaf_update_count, leaf_ghost_count,
       leaf_allocation_count, nonleaf_allocation_count, leaf_page_merge_count,
       page_compression_attempt_count, page_compression_success_count,
       forwarded_fetch_count)
SELECT ios.object_id, ios.index_id,
       CASE WHEN @ConsolidatePartitionStats = 0 THEN ios.partition_number ELSE -1 END,
       SUM(ios.range_scan_count),        SUM(ios.singleton_lookup_count),
       SUM(ios.row_lock_count),          SUM(ios.row_lock_wait_count),  SUM(ios.row_lock_wait_in_ms),
       SUM(ios.page_lock_count),         SUM(ios.page_lock_wait_count), SUM(ios.page_lock_wait_in_ms),
       SUM(ios.page_latch_wait_count),   SUM(ios.page_latch_wait_in_ms),
       SUM(ios.page_io_latch_wait_count),SUM(ios.page_io_latch_wait_in_ms),
       SUM(ios.leaf_insert_count),       SUM(ios.leaf_delete_count),
       SUM(ios.leaf_update_count),       SUM(ios.leaf_ghost_count),
       SUM(ios.leaf_allocation_count),   SUM(ios.nonleaf_allocation_count),
       SUM(ios.leaf_page_merge_count),
       SUM(ios.page_compression_attempt_count), SUM(ios.page_compression_success_count),
       SUM(ios.forwarded_fetch_count)
FROM   sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) ios
JOIN   #TableMeta tm ON tm.object_id = ios.object_id
GROUP  BY ios.object_id, ios.index_id,
          CASE WHEN @ConsolidatePartitionStats = 0 THEN ios.partition_number ELSE -1 END;';
        SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn, N''@ConsolidatePartitionStats BIT'', @ConsolidatePartitionStats = @CPS;';
        EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX), @CPS BIT',
             @InnerIn = @Inner, @CPS = @ConsolidatePartitionStats;

        /*  8. #MissingIndex + #MissingIndexColumn  */
        IF @IncludeMissingIndexes = 1
        BEGIN
            SET @Inner = N'
INSERT #MissingIndex
      (group_handle, index_handle, object_id, unique_compiles, user_seeks, user_scans,
       avg_total_user_cost, avg_user_impact, last_user_seek, impact,
       equality_columns, inequality_columns, included_columns, proposal_source)
SELECT migs.group_handle, mid.index_handle, mid.object_id,
       migs.unique_compiles, migs.user_seeks, migs.user_scans,
       migs.avg_total_user_cost, migs.avg_user_impact, migs.last_user_seek,
       CAST((migs.user_seeks + migs.user_scans) * migs.avg_user_impact AS DECIMAL(18,4)),
       mid.equality_columns, mid.inequality_columns, mid.included_columns, ''DMV''
FROM   sys.dm_db_missing_index_details      mid
JOIN   sys.dm_db_missing_index_groups       mig  ON mig.index_handle = mid.index_handle
JOIN   sys.dm_db_missing_index_group_stats  migs ON migs.group_handle = mig.index_group_handle
JOIN   #TableMeta tm ON tm.object_id = mid.object_id
WHERE  mid.database_id = DB_ID()
  AND  CAST((migs.user_seeks + migs.user_scans) * migs.avg_user_impact AS DECIMAL(18,4)) >= @MissingIndexBlendMinImpact
/*  DETERMINISTIC IDENTITY ASSIGNMENT -- mirrors the script. missing_index_id feeds the <<missing #N>>
    label and the Section 11 bridge join, and the DMVs return rows in no guaranteed order; SQL Server
    assigns IDENTITY in ORDER BY sequence for INSERT ... SELECT. This ORDER BY was missing here until
    2026-09-12: the procedure numbered the same suggestions differently from the script (and could
    differ run to run) -- found by a byte-compare of the two DUMP outputs; the gate now has a label
    tripwire, because its loose MISSING compare cannot see labels.                                  */
ORDER  BY mid.object_id,
          COALESCE(mid.equality_columns,   N''''),
          COALESCE(mid.inequality_columns, N''''),
          COALESCE(mid.included_columns,   N'''');

INSERT #MissingIndexColumn (missing_index_id, column_id, column_name, column_usage, ordinal)
SELECT mi.missing_index_id, mic.column_id, mic.column_name, mic.column_usage,
       ROW_NUMBER() OVER (PARTITION BY mi.missing_index_id, mic.column_usage ORDER BY mic.column_id)
FROM   #MissingIndex mi
CROSS APPLY sys.dm_db_missing_index_columns(mi.index_handle) mic;';
            SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn, N''@MissingIndexBlendMinImpact DECIMAL(18,4)'', @MissingIndexBlendMinImpact = @MIB;';
            EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX), @MIB DECIMAL(18,4)',
                 @InnerIn = @Inner, @MIB = @MissingIndexBlendMinImpact;
        END;

        /*  9. #ForeignKeyGap  */
        IF @IncludeMissingFKIndexes = 1
        BEGIN
            SET @Inner = N'
;WITH fkcols AS
(
    SELECT fk.name AS foreign_key_name, fk.parent_object_id, fk.referenced_object_id,
           fkc.parent_column_id, fkc.constraint_column_id, c.name AS column_name
    FROM   sys.foreign_keys fk
    JOIN   sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    JOIN   sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
    JOIN   #TableMeta tm ON tm.object_id = fk.parent_object_id
),
fkagg AS
(
    SELECT foreign_key_name, parent_object_id, referenced_object_id,
           COUNT(*) AS fk_column_count,
           STUFF((SELECT N'', '' + QUOTENAME(x.column_name)
                  FROM fkcols x
                  WHERE x.foreign_key_name = f.foreign_key_name AND x.parent_object_id = f.parent_object_id
                  ORDER BY x.constraint_column_id
                  FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), 1, 2, N'''') AS fk_columns_display,
           COALESCE((SELECT CONCAT(N''c'', x.parent_column_id, N''A.'')
                     FROM fkcols x
                     WHERE x.foreign_key_name = f.foreign_key_name AND x.parent_object_id = f.parent_object_id
                     ORDER BY x.constraint_column_id
                     FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(MAX)''), N'''') AS fk_key_signature
    FROM   fkcols f
    GROUP  BY foreign_key_name, parent_object_id, referenced_object_id
)
INSERT #ForeignKeyGap
SELECT a.foreign_key_name, a.parent_object_id, a.referenced_object_id,
       a.fk_column_count, a.fk_columns_display, a.fk_key_signature
FROM   fkagg a
WHERE  NOT EXISTS (SELECT 1 FROM #IndexMeta im
                   WHERE im.object_id = a.parent_object_id
                     AND im.partition_number = (SELECT MIN(partition_number) FROM #IndexMeta im2
                                                WHERE im2.object_id = a.parent_object_id AND im2.index_id = im.index_id)
                     AND LEFT(im.key_signature, LEN(a.fk_key_signature)) = a.fk_key_signature);';
            SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn;';
            EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX)', @InnerIn = @Inner;
        END;

        /*  9b. #DependentObject -- opt-in. The four statements are the script's Section 9b body
            verbatim; @QueryStoreUsable / @LookbackStart / @HasFunctionStatsDmv travel in as
            parameters of the nested sp_executesql so the collection text stays identical.       */
        IF @IncludeDependentObjects = 1
        BEGIN
            SET @Inner = N'
/*  9b-1. The dependents themselves. Evidence starts as NONE (or INLINED / STRUCTURAL where no
          plan of its own can exist) and is upgraded by the three evidence passes below.       */
INSERT #DependentObject
      (referenced_object_id, dependent_object_id, dependent_schema, dependent_name,
       dependent_type_desc, dependency_kind, evidence_source, last_evidence_time)
SELECT DISTINCT d.referenced_id, o.object_id, s.name, o.name, o.type_desc, ''EXPRESSION'',
       CASE WHEN o.type IN (''V'',''IF'') THEN ''INLINED'' ELSE ''NONE'' END, NULL
FROM   sys.sql_expression_dependencies d
JOIN   sys.objects o  ON o.object_id = d.referencing_id
JOIN   sys.schemas s  ON s.schema_id = o.schema_id
JOIN   #TableMeta tm  ON tm.object_id = d.referenced_id
WHERE  d.referencing_id <> d.referenced_id          /* the table itself (its computed columns) */
  AND  d.referencing_class = 1                       /* OBJECT_OR_COLUMN */
  AND  o.type IN (''V'',''P'',''FN'',''IF'',''TF'',''TR'')       /* not C (check) / D (default) / U (the table) */
  AND  o.is_ms_shipped = 0
UNION
SELECT DISTINCT fk.referenced_object_id, ct.object_id, s.name, ct.name,
       CONVERT(NVARCHAR(60), N''FOREIGN KEY (child table)''), ''FOREIGN_KEY'', ''STRUCTURAL'', NULL
FROM   sys.foreign_keys fk
JOIN   sys.tables  ct ON ct.object_id = fk.parent_object_id
JOIN   sys.schemas s  ON s.schema_id = ct.schema_id
JOIN   #TableMeta tm  ON tm.object_id = fk.referenced_object_id
WHERE  fk.parent_object_id <> fk.referenced_object_id;  /* a self-referencing FK is the table, not a dependent */

/*  9b-2. Plan-cache evidence: procedure and trigger stats (every supported engine). The cache
          last_execution_time is server-local datetime; shifted to UTC so it compares with the
          Query Store datetimeoffset below.                                                    */
UPDATE dobj
SET    evidence_source = ''CACHE'', last_evidence_time = c.last_exec_utc
FROM   #DependentObject dobj
CROSS APPLY (SELECT MAX(CONVERT(DATETIME2(3), DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), x.last_execution_time))) AS last_exec_utc
             FROM (SELECT ps.last_execution_time FROM sys.dm_exec_procedure_stats ps
                   WHERE  ps.database_id = DB_ID() AND ps.object_id = dobj.dependent_object_id
                   UNION ALL
                   SELECT ts.last_execution_time FROM sys.dm_exec_trigger_stats ts
                   WHERE  ts.database_id = DB_ID() AND ts.object_id = dobj.dependent_object_id) x) c
WHERE  dobj.evidence_source = ''NONE'' AND c.last_exec_utc IS NOT NULL;

/*  9b-3. Function stats -- a 2016 SP1+ DMV, so the statement is only ever bound where it exists. */
IF @HasFunctionStatsDmv = 1
    UPDATE dobj
    SET    evidence_source = ''CACHE'', last_evidence_time = c.last_exec_utc
    FROM   #DependentObject dobj
    CROSS APPLY (SELECT MAX(CONVERT(DATETIME2(3), DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), fs.last_execution_time))) AS last_exec_utc
                 FROM sys.dm_exec_function_stats fs
                 WHERE fs.database_id = DB_ID() AND fs.object_id = dobj.dependent_object_id) c
    WHERE  dobj.evidence_source = ''NONE'' AND c.last_exec_utc IS NOT NULL;

/*  9b-4. Query Store evidence inside the lookback -- the durable source; the cache empties on a
          restart or a DBCC FREEPROCCACHE. NONE -> QS, CACHE -> QS+CACHE.                      */
IF @QueryStoreUsable = 1
    UPDATE dobj
    SET    evidence_source     = CASE WHEN dobj.evidence_source = ''CACHE'' THEN ''QS+CACHE'' ELSE ''QS'' END,
           last_evidence_time  = CASE WHEN dobj.last_evidence_time IS NULL OR q.last_exec_utc > dobj.last_evidence_time
                                      THEN q.last_exec_utc ELSE dobj.last_evidence_time END
    FROM   #DependentObject dobj
    CROSS APPLY (SELECT MAX(CONVERT(DATETIME2(3), SWITCHOFFSET(rs.last_execution_time, ''+00:00''))) AS last_exec_utc
                 FROM   sys.query_store_query q
                 JOIN   sys.query_store_plan  p  ON p.query_id = q.query_id
                 JOIN   sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
                 WHERE  q.object_id = dobj.dependent_object_id
                   AND  rs.last_execution_time >= @LookbackStart) q
    WHERE  dobj.evidence_source IN (''NONE'',''CACHE'') AND q.last_exec_utc IS NOT NULL;';
            SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn, N''@QueryStoreUsable BIT, @LookbackStart DATETIME2(7), @HasFunctionStatsDmv BIT'', @QueryStoreUsable = @QSU, @LookbackStart = @LBS, @HasFunctionStatsDmv = @HFS;';
            EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX), @QSU BIT, @LBS DATETIME2(7), @HFS BIT',
                 @InnerIn = @Inner, @QSU = @QueryStoreUsable, @LBS = @LookbackStart, @HFS = @HasFunctionStatsDmv;
        END;

        /*--------------------------------------------------------------------------------------
          9c. INTAKE -- plan evidence -> #PlanEvidence. See the script's Section 9c header for
          the model. Both pulls read per-database catalog / DMV state, so both run in the
          TARGET's context; this ran as Section 11-pre until 2026-09-12 and moved here because
          Section 9d's proposals must exist before Section 10 assembles the MISSING rows.
        --------------------------------------------------------------------------------------*/
        IF @QueryStoreUsable = 1
        BEGIN
            SET @sqlPlan = N'
            INSERT #PlanEvidence (evidence_source, query_id, plan_id, query_object_id, executions,
                                  total_duration_ms, total_cpu_ms, avg_duration_ms, plan_xml)
            SELECT ''QS'', p.query_id, p.plan_id, q.object_id,
                   rs.executions, rs.total_duration_ms, rs.total_cpu_ms,
                   CASE WHEN rs.executions > 0 THEN rs.total_duration_ms / rs.executions ELSE 0 END,
                   TRY_CAST(p.query_plan AS XML)   /* TRY_CAST, not CONVERT -- MEASURED 2026-09-14: a plan nested deeper than
                                                  the 128 levels the xml type allows is valid showplan text
                                                  that CONVERT rejects with Msg 6335, and one such plan in the
                                                  target Query Store aborted this whole run. TRY_CAST returns
                                                  NULL instead, and IS compat-100 safe (verified at 100); only
                                                  TRY_CONVERT is gated to 110+. */
            FROM   sys.query_store_plan p
            JOIN   sys.query_store_query q ON q.query_id = p.query_id
            CROSS APPLY (SELECT SUM(rs0.count_executions) AS executions,
                                SUM(rs0.avg_duration  * rs0.count_executions) / 1000.0 AS total_duration_ms,
                                SUM(rs0.avg_cpu_time  * rs0.count_executions) / 1000.0 AS total_cpu_ms
                         FROM   sys.query_store_runtime_stats rs0
                         WHERE  rs0.plan_id = p.plan_id
                           AND  rs0.execution_type = 0
                           AND  rs0.last_execution_time >= @LookbackStartUtc) rs
            WHERE  rs.executions IS NOT NULL;
            /*  A plan TRY_CAST could not convert -- nested deeper than the 128 levels the xml type allows --
                keeps its text, so Section 11b can still find the indexes it reads. Only those rows. */
            UPDATE pe
            SET    pe.plan_text = p.query_plan
            FROM   #PlanEvidence pe
            JOIN   sys.query_store_plan p ON p.plan_id = pe.plan_id
            WHERE  pe.evidence_source = ''QS'' AND pe.plan_xml IS NULL AND p.query_plan IS NOT NULL;';
            SET @Sql = @Use + @sqlPlan;
            EXEC sys.sp_executesql @Sql,
                 N'@LookbackStartUtc DATETIME2(7)',
                 @LookbackStartUtc = @LookbackStart;
        END;

        IF @IncludeDependentObjects = 1
        BEGIN
            /*  9c-2. 'CACHE' rows -- only for CACHE-only dependents: a QS-evidenced dependent's
                plans are already here as 'QS' rows, and mining both would count the same statement
                twice. database_id = DB_ID(): object_ids are not unique across databases. The
                per-STATEMENT plan (dm_exec_query_stats offsets + dm_exec_text_query_plan), not the
                procedure's whole-batch plan, which would fuse every statement's Sort and hint into
                one document. Function stats are 2016 SP1+, so that branch is spliced in only when
                the DMV exists -- a compile-time reference to a missing DMV fails the whole batch. */
            SET @sqlCachePlan = N'
INSERT #PlanEvidence (evidence_source, query_id, plan_id, query_object_id, executions,
                      total_duration_ms, total_cpu_ms, avg_duration_ms, plan_xml)
SELECT ''CACHE'', NULL, NULL, x.object_id,
       qs.execution_count,
       qs.total_elapsed_time / 1000.0, qs.total_worker_time / 1000.0,
       CASE WHEN qs.execution_count > 0 THEN (qs.total_elapsed_time / 1000.0) / qs.execution_count ELSE 0 END,
       TRY_CAST(tqp.query_plan AS XML)
FROM  (SELECT ps.object_id, ps.plan_handle FROM sys.dm_exec_procedure_stats ps WHERE ps.database_id = DB_ID()
       UNION ALL
       SELECT ts.object_id, ts.plan_handle FROM sys.dm_exec_trigger_stats ts WHERE ts.database_id = DB_ID()'
            + CASE WHEN @HasFunctionStatsDmv = 1 THEN N'
       UNION ALL
       SELECT fs.object_id, fs.plan_handle FROM sys.dm_exec_function_stats fs WHERE fs.database_id = DB_ID()' ELSE N'' END
            + N') x
JOIN   sys.dm_exec_query_stats qs ON qs.plan_handle = x.plan_handle
CROSS APPLY sys.dm_exec_text_query_plan(qs.plan_handle, qs.statement_start_offset, qs.statement_end_offset) tqp
WHERE  x.object_id IN (SELECT d.dependent_object_id FROM #DependentObject d WHERE d.evidence_source = ''CACHE'')
  AND  tqp.query_plan IS NOT NULL;';
            SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn;';
            EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX)', @InnerIn = @sqlCachePlan;
        END;

        /*  9c-3. The pasted statement plan (Piece 1). One row, no query_id / plan_id / object --
            it belongs to no object, which is what distinguishes it downstream. executions = 1 is
            load-bearing: 9d's derived impact is SUM(executions x @Impact), so a single occurrence
            makes a statement proposal's missing_impact the optimizer's own estimated percentage.
            Different scale from a DMV proposal -- see #MissingIndex.proposal_source.             */
        IF @StatementMode = 1
            INSERT #PlanEvidence (evidence_source, query_id, plan_id, query_object_id, executions,
                                  total_duration_ms, total_cpu_ms, avg_duration_ms, plan_xml)
            SELECT 'STATEMENT', NULL, NULL, NULL, 1, 0, 0, 0, sp.plan_xml
            FROM   #StatementPlan sp
            WHERE  sp.plan_xml IS NOT NULL;

        /*--------------------------------------------------------------------------------------
          9d. DEPENDENT PLAN MINING -> proposals. Verbatim from the script (see its Section 9d
          header for the model, the dedupe rule and the derived-impact formula). Reads only temp
          tables plus @DbQuoted -- which this loop already sets to QUOTENAME(@LoopDb), the TARGET's
          name, so the <MissingIndex Database=...> test is against the right database -- and
          #TableMeta's STORED schema / table names, never OBJECT_NAME(object_id), which would
          resolve in DBAdmin here. So it runs correctly in this analysis-half context.
        --------------------------------------------------------------------------------------*/
        IF @IncludeDependentObjects = 1 OR @StatementMode = 1
        BEGIN
            /*  9d-1. Hints naming a table in scope. Two kinds of plan qualify, and the LEFT JOIN is
                what keeps them apart: a Query Store / plan-cache plan contributes only where its
                owning object is genuinely a dependent OF THAT TABLE (d matched), while a pasted
                @StatementPlanXml contributes to any table in scope its hint names -- it has no
                owning object, which is why dependent_object_id is NULL for it. #TableMeta is joined
                on the hint's OWN schema/table rather than through the dependent mapping, since a
                statement has no mapping.                                                          */
            ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
            INSERT #DependentHint (evidence_id, dependent_object_id, referenced_object_id, hint_impact, hint_xml)
            SELECT pe.evidence_id, d.dependent_object_id, tm.object_id,
                   g.n.value('@Impact', 'FLOAT'),
                   m.n.query('.')
            FROM   #PlanEvidence pe
            CROSS APPLY pe.plan_xml.nodes('//MissingIndexes/MissingIndexGroup') AS g(n)
            CROSS APPLY g.n.nodes('MissingIndex') AS m(n)
            JOIN   #TableMeta tm
                     ON  QUOTENAME(tm.schema_name) = m.n.value('@Schema', 'NVARCHAR(300)')
                     AND QUOTENAME(tm.table_name)  = m.n.value('@Table',  'NVARCHAR(300)')
            LEFT  JOIN (SELECT DISTINCT dependent_object_id, referenced_object_id
                        FROM   #DependentObject
                        WHERE  dependency_kind = 'EXPRESSION') d
                     ON  d.dependent_object_id  = pe.query_object_id
                    AND  d.referenced_object_id = tm.object_id
            WHERE  pe.plan_xml IS NOT NULL
              AND  m.n.value('@Database', 'NVARCHAR(300)') = @DbQuoted
              AND  (pe.evidence_source = 'STATEMENT' OR d.dependent_object_id IS NOT NULL);

            /*  9d-2. The hint's columns, ordinal by @ColumnId within usage -- the DMV's own order.
                Materialised first: XML methods are not allowed in a GROUP BY or a window frame.  */
            IF OBJECT_ID('tempdb..#DependentHintColumnRaw') IS NOT NULL DROP TABLE #DependentHintColumnRaw;
            ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
            SELECT h.hint_id,
                   c.n.value('@ColumnId', 'INT')            AS column_id,
                   c.n.value('@Name',     'NVARCHAR(300)')  AS quoted_name,
                   cg.n.value('@Usage',   'VARCHAR(20)')    AS column_usage
            INTO   #DependentHintColumnRaw
            FROM   #DependentHint h
            CROSS APPLY h.hint_xml.nodes('/MissingIndex/ColumnGroup') AS cg(n)
            CROSS APPLY cg.n.nodes('Column') AS c(n);

            INSERT #DependentHintColumn (hint_id, column_id, column_name, column_usage, ordinal)
            SELECT r.hint_id, r.column_id,
                   REPLACE(SUBSTRING(r.quoted_name, 2, LEN(r.quoted_name) - 2), N']]', N']'),   /* exact inverse of QUOTENAME(x) */
                   r.column_usage,
                   ROW_NUMBER() OVER (PARTITION BY r.hint_id, r.column_usage ORDER BY r.column_id)
            FROM   #DependentHintColumnRaw r
            WHERE  r.column_id IS NOT NULL AND r.quoted_name LIKE N'[[]%]';
            DROP TABLE #DependentHintColumnRaw;

            /*  9d-3. Signatures (the dedupe key) and DMV-format display strings per hint.        */
            UPDATE h
            SET    eq_sig   = s.eq_sig,   ineq_sig = s.ineq_sig, incl_sig = s.incl_sig,
                   equality_columns = s.eq_disp, inequality_columns = s.ineq_disp, included_columns = s.incl_disp
            FROM   #DependentHint h
            CROSS APPLY (SELECT
                STUFF((SELECT N',' + CONVERT(NVARCHAR(10), c.column_id) FROM #DependentHintColumn c WHERE c.hint_id = h.hint_id AND c.column_usage = 'EQUALITY'   ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N'') AS eq_sig,
                STUFF((SELECT N',' + CONVERT(NVARCHAR(10), c.column_id) FROM #DependentHintColumn c WHERE c.hint_id = h.hint_id AND c.column_usage = 'INEQUALITY' ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N'') AS ineq_sig,
                STUFF((SELECT N',' + CONVERT(NVARCHAR(10), c.column_id) FROM #DependentHintColumn c WHERE c.hint_id = h.hint_id AND c.column_usage = 'INCLUDE'    ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N'') AS incl_sig,
                STUFF((SELECT N', ' + QUOTENAME(c.column_name) FROM #DependentHintColumn c WHERE c.hint_id = h.hint_id AND c.column_usage = 'EQUALITY'   ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS eq_disp,
                STUFF((SELECT N', ' + QUOTENAME(c.column_name) FROM #DependentHintColumn c WHERE c.hint_id = h.hint_id AND c.column_usage = 'INEQUALITY' ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS ineq_disp,
                STUFF((SELECT N', ' + QUOTENAME(c.column_name) FROM #DependentHintColumn c WHERE c.hint_id = h.hint_id AND c.column_usage = 'INCLUDE'    ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS incl_disp) s;

            /*  9d-4. A DMV twin: same table, same column_ids per usage -> the hint supports it.  */
            UPDATE h
            SET    missing_index_id = t.missing_index_id
            FROM   #DependentHint h
            JOIN  (SELECT mi.missing_index_id, mi.object_id,
                          STUFF((SELECT N',' + CONVERT(NVARCHAR(10), c.column_id) FROM #MissingIndexColumn c WHERE c.missing_index_id = mi.missing_index_id AND c.column_usage = 'EQUALITY'   ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N'') AS eq_sig,
                          STUFF((SELECT N',' + CONVERT(NVARCHAR(10), c.column_id) FROM #MissingIndexColumn c WHERE c.missing_index_id = mi.missing_index_id AND c.column_usage = 'INEQUALITY' ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N'') AS ineq_sig,
                          STUFF((SELECT N',' + CONVERT(NVARCHAR(10), c.column_id) FROM #MissingIndexColumn c WHERE c.missing_index_id = mi.missing_index_id AND c.column_usage = 'INCLUDE'    ORDER BY c.column_id FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, N'') AS incl_sig
                   FROM   #MissingIndex mi
                   WHERE  mi.proposal_source = 'DMV') t
                   ON  t.object_id = h.referenced_object_id
                   AND COALESCE(t.eq_sig,   N'') = COALESCE(h.eq_sig,   N'')
                   AND COALESCE(t.ineq_sig, N'') = COALESCE(h.ineq_sig, N'')
                   AND COALESCE(t.incl_sig, N'') = COALESCE(h.incl_sig, N'');

            /*  9d-5. New proposals: every unmatched (table, column set) once, derived impact at or
                above the BLEND floor, numbered AFTER the DMV rows with the same content ORDER BY
                as Section 8 -- so two runs on the same plans label the same proposal the same way. */
            INSERT #MissingIndex
                  (group_handle, index_handle, object_id, unique_compiles, user_seeks, user_scans,
                   avg_total_user_cost, avg_user_impact, last_user_seek, impact,
                   equality_columns, inequality_columns, included_columns, proposal_source)
            SELECT NULL, NULL, h.referenced_object_id,
                   COUNT(DISTINCT h.evidence_id), SUM(pe.executions), 0,
                   0, MAX(h.hint_impact), NULL,
                   CAST(SUM(pe.executions * h.hint_impact) AS DECIMAL(18,4)),
                   h.equality_columns, h.inequality_columns, h.included_columns,
                   /*  A pasted statement wins the label when both kinds of plan carry the same
                       hint: the caller asked about the statement, so that is the headline.       */
                   CASE WHEN MAX(CASE WHEN pe.evidence_source = 'STATEMENT' THEN 1 ELSE 0 END) = 1
                        THEN 'STATEMENT' ELSE 'DEPENDENT' END
            FROM   #DependentHint h
            JOIN   #PlanEvidence pe ON pe.evidence_id = h.evidence_id
            WHERE  h.missing_index_id IS NULL
            GROUP  BY h.referenced_object_id, h.eq_sig, h.ineq_sig, h.incl_sig,
                      h.equality_columns, h.inequality_columns, h.included_columns
            HAVING CAST(SUM(pe.executions * h.hint_impact) AS DECIMAL(18,4)) >= @MissingIndexBlendMinImpact
            ORDER  BY h.referenced_object_id,
                      COALESCE(h.equality_columns,   N''),
                      COALESCE(h.inequality_columns, N''),
                      COALESCE(h.included_columns,   N'');

            UPDATE h
            SET    missing_index_id = mi.missing_index_id
            FROM   #DependentHint h
            JOIN   #MissingIndex mi
                   ON  mi.proposal_source IN ('DEPENDENT','STATEMENT')
                   AND mi.object_id = h.referenced_object_id
                   AND COALESCE(mi.equality_columns,   N'') = COALESCE(h.equality_columns,   N'')
                   AND COALESCE(mi.inequality_columns, N'') = COALESCE(h.inequality_columns, N'')
                   AND COALESCE(mi.included_columns,   N'') = COALESCE(h.included_columns,   N'')
            WHERE  h.missing_index_id IS NULL;

            /*  9d-6. Columns for the new proposals; the driving plan for every proposal a
                dependent's plan supports (11a-2 overrides it wherever a Query Store bridge
                exists); and the dependent -> proposal links behind dependent_sources.            */
            INSERT #MissingIndexColumn (missing_index_id, column_id, column_name, column_usage, ordinal)
            SELECT h.missing_index_id, c.column_id, c.column_name, c.column_usage, c.ordinal
            FROM  (SELECT missing_index_id, MIN(hint_id) AS hint_id
                   FROM   #DependentHint WHERE missing_index_id IS NOT NULL
                   GROUP  BY missing_index_id) h
            JOIN   #MissingIndex mi ON mi.missing_index_id = h.missing_index_id AND mi.proposal_source IN ('DEPENDENT','STATEMENT')
            JOIN   #DependentHintColumn c ON c.hint_id = h.hint_id;

            UPDATE mi
            SET    driving_evidence_id = d.evidence_id
            FROM   #MissingIndex mi
            JOIN  (SELECT h.missing_index_id, h.evidence_id,
                          ROW_NUMBER() OVER (PARTITION BY h.missing_index_id
                                             ORDER BY pe.executions DESC, h.evidence_id ASC) AS rn
                   FROM   #DependentHint h
                   JOIN   #PlanEvidence pe ON pe.evidence_id = h.evidence_id
                   WHERE  h.missing_index_id IS NOT NULL) d
                   ON d.missing_index_id = mi.missing_index_id AND d.rn = 1;

            INSERT #ProposalDependent (missing_index_id, source_label)
            SELECT DISTINCT h.missing_index_id,
                   CASE WHEN h.dependent_object_id IS NULL
                        THEN N'<<pasted statement>> (' + pe.evidence_source + N')'
                        ELSE QUOTENAME(d.dependent_schema) + N'.' + QUOTENAME(d.dependent_name)
                             + N' (' + pe.evidence_source + N')' END
            FROM   #DependentHint h
            JOIN   #PlanEvidence pe ON pe.evidence_id = h.evidence_id
            LEFT  JOIN (SELECT DISTINCT dependent_object_id, dependent_schema, dependent_name
                        FROM   #DependentObject) d ON d.dependent_object_id = h.dependent_object_id
            WHERE  h.missing_index_id IS NOT NULL;

            IF @Debug = 1
            BEGIN
                SELECT @Rows = COUNT(*) FROM #MissingIndex WHERE proposal_source = 'DEPENDENT';
                RAISERROR('%s: %d proposal(s) mined from dependent plans (Section 9d)', 0, 0, @LoopDb, @Rows) WITH NOWAIT;
            END;
        END;

        /*====================================================================================
          ANALYSIS -- Sections 10 through 13, verbatim from the script. Reads only the temp
          tables above; no catalog access, so it runs unchanged in this procedure's context.
          The two Query Store COLLECTION calls inside it (11-pre, 11a exact bridge) are the
          only statements re-wrapped with @Use.
        ====================================================================================*/
    /*  10a. Existing indexes.                                                                        */
    INSERT #IndexAnalysis
          (row_kind, schema_name, table_name, object_name, object_id, index_id, index_name, type_desc,
           partition_number, is_primary_key, is_unique, is_unique_constraint, fill_factor, is_disabled, is_heap, has_filter, filter_definition,
           filegroup_name, data_compression_desc, table_row_count, index_row_count, size_mb,
           buffered_mb, pct_in_buffer, key_column_count, include_column_count, table_column_count,
           key_columns_display, include_columns_display, key_signature, include_signature, distinct_key_signature,
           user_seeks, user_scans, user_lookups, user_updates, user_total, reads_per_write, last_user_read,
           row_lock_wait_in_ms, page_lock_wait_in_ms, forwarded_fetch_count, leaf_delete_count,
           page_latch_wait_count, page_latch_wait_in_ms, leaf_allocation_count,
           page_compression_success_rate, ops_scan_pct, ops_update_pct, ops_insert_pct,
           partition_count, is_on_partition_scheme, stats_sample_pct, has_resumable_op)
    SELECT 'INDEX', tm.schema_name, tm.table_name, tm.object_name, im.object_id, im.index_id,
           COALESCE(im.index_name, N'[HEAP]'), im.type_desc, im.partition_number,
           im.is_primary_key, im.is_unique, im.is_unique_constraint, im.fill_factor, im.is_disabled, tm.is_heap, im.has_filter, im.filter_definition,
           im.filegroup_name, im.data_compression_desc, tm.table_row_count, im.index_row_count, im.size_mb,
           bp.buffered_mb,
           CASE WHEN im.reserved_page_count > 0 AND bp.buffered_page_count IS NOT NULL
                THEN CAST(100.0 * bp.buffered_page_count / im.reserved_page_count AS DECIMAL(6,2)) END,
           im.key_column_count, im.include_column_count, tm.table_column_count,
           im.key_columns_display, im.include_columns_display, im.key_signature, im.include_signature, im.distinct_key_signature,
           us.user_seeks, us.user_scans, us.user_lookups, us.user_updates,
           COALESCE(us.user_seeks,0) + COALESCE(us.user_scans,0) + COALESCE(us.user_lookups,0),
           CASE WHEN COALESCE(us.user_updates,0) > 0
                THEN CAST((COALESCE(us.user_seeks,0)+COALESCE(us.user_scans,0)+COALESCE(us.user_lookups,0)) * 1.0
                          / us.user_updates AS DECIMAL(18,2)) END,
           us.last_user_read,
           os.row_lock_wait_in_ms, os.page_lock_wait_in_ms, os.forwarded_fetch_count, os.leaf_delete_count,
           os.page_latch_wait_count, os.page_latch_wait_in_ms, os.leaf_allocation_count,
           CASE WHEN os.page_compression_attempt_count > 0
                THEN CAST(100.0 * os.page_compression_success_count / os.page_compression_attempt_count AS DECIMAL(6,2)) END,
           /*  S / U / insert% per the MS best-practices paper. D = range_scan + leaf_insert + leaf_delete
               + leaf_update + leaf_page_merge + singleton_lookup. NULL when D = 0 (no operational history). */
           CASE WHEN od.d > 0 THEN CAST(100.0 * os.range_scan_count   / od.d AS DECIMAL(6,2)) END,
           CASE WHEN od.d > 0 THEN CAST(100.0 * os.leaf_update_count  / od.d AS DECIMAL(6,2)) END,
           CASE WHEN od.d > 0 THEN CAST(100.0 * os.leaf_insert_count  / od.d AS DECIMAL(6,2)) END,
           im.partition_count, im.is_on_partition_scheme, ss.sample_pct,
           CASE WHEN ro.object_id IS NOT NULL THEN 1 ELSE 0 END
    FROM   #IndexMeta im
    JOIN   #TableMeta tm ON tm.object_id = im.object_id
    LEFT  JOIN #IndexStatsSample ss ON ss.object_id = im.object_id AND ss.index_id = im.index_id
    LEFT  JOIN #ResumableOp     ro ON ro.object_id = im.object_id AND ro.index_id = im.index_id
    LEFT  JOIN #UsageStats us ON us.object_id = im.object_id AND us.index_id = im.index_id
    LEFT  JOIN #BufferPool bp ON bp.object_id = im.object_id AND bp.index_id = im.index_id
                             AND bp.partition_number = im.partition_number
    LEFT  JOIN #OperationalStats os ON os.object_id = im.object_id AND os.index_id = im.index_id
                                   AND os.partition_number = im.partition_number
    OUTER APPLY (SELECT CAST(COALESCE(os.range_scan_count,0)      + COALESCE(os.leaf_insert_count,0)
                           + COALESCE(os.leaf_delete_count,0)     + COALESCE(os.leaf_update_count,0)
                           + COALESCE(os.leaf_page_merge_count,0) + COALESCE(os.singleton_lookup_count,0)
                             AS DECIMAL(20,0)) AS d) od;

    /*  10b. Missing-index groups above the BLEND floor.                                              */
    IF @IncludeMissingIndexes = 1
    BEGIN
        INSERT #IndexAnalysis
              (row_kind, schema_name, table_name, object_name, object_id, index_id, index_name,
               type_desc, table_row_count, table_column_count, key_column_count, include_column_count,
               key_columns_display, include_columns_display, missing_impact, missing_unique_compiles,
               equality_columns, inequality_columns, missing_include_columns,
               proposal_source, dependent_sources,
               user_seeks, user_scans, user_total)
        SELECT 'MISSING', tm.schema_name, tm.table_name, tm.object_name, mi.object_id, NULL,
               N'<<missing #' + CONVERT(NVARCHAR(10), mi.missing_index_id) + N'>>',
               N'NONCLUSTERED (proposed)', tm.table_row_count, tm.table_column_count,
               (SELECT COUNT(*) FROM #MissingIndexColumn c WHERE c.missing_index_id = mi.missing_index_id AND c.column_usage <> 'INCLUDE'),
               (SELECT COUNT(*) FROM #MissingIndexColumn c WHERE c.missing_index_id = mi.missing_index_id AND c.column_usage = 'INCLUDE'),
               COALESCE(mi.equality_columns, N'')
                 + CASE WHEN mi.equality_columns IS NOT NULL AND mi.inequality_columns IS NOT NULL THEN N', ' ELSE N'' END
                 + COALESCE(mi.inequality_columns, N''),
               mi.included_columns,
               mi.impact, mi.unique_compiles,
               mi.equality_columns, mi.inequality_columns, mi.included_columns,
               mi.proposal_source, ds.list,
               mi.user_seeks, mi.user_scans, mi.user_seeks + mi.user_scans
        FROM   #MissingIndex mi
        JOIN   #TableMeta tm ON tm.object_id = mi.object_id
        /*  Section 9d: the dependents whose plans carry this proposal's hint -- NULL when none (and
            always NULL with @IncludeDependentObjects = 0, when #ProposalDependent is empty).      */
        CROSS APPLY (SELECT STUFF((SELECT N', ' + pd.source_label
                                   FROM   #ProposalDependent pd
                                   WHERE  pd.missing_index_id = mi.missing_index_id
                                   ORDER  BY pd.source_label
                                   FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS list) ds;
    END;

    /*  10c. Foreign key gaps.                                                                        */
    IF @IncludeMissingFKIndexes = 1
    BEGIN
        INSERT #IndexAnalysis
              (row_kind, schema_name, table_name, object_name, object_id, index_id, index_name,
               type_desc, table_row_count, table_column_count, key_column_count, key_columns_display,
               key_signature, fk_column_count)
        SELECT 'FKGAP', tm.schema_name, tm.table_name, tm.object_name, g.parent_object_id, NULL,
               N'<<fk: ' + g.foreign_key_name + N'>>', N'NONCLUSTERED (proposed, FK)',
               tm.table_row_count, tm.table_column_count, g.fk_column_count, g.fk_columns_display,
               g.fk_key_signature, g.fk_column_count
        FROM   #ForeignKeyGap g
        JOIN   #TableMeta tm ON tm.object_id = g.parent_object_id;
    END;

    /*  10d. Duplicate / overlapping / sibling lists (existing indexes only), and BLEND targets for
            missing rows. Comparison is on the FIRST partition's signature per index -- signatures do
            not vary by partition.                                                                    */
    ;WITH one_per_index AS
    (
        SELECT * FROM #IndexAnalysis ia
        WHERE  ia.row_kind = 'INDEX'
          AND  ia.partition_number = (SELECT MIN(partition_number) FROM #IndexAnalysis x
                                      WHERE x.object_id = ia.object_id AND x.index_id = ia.index_id)
    )
    UPDATE ia
    SET    duplicate_of =
             CASE WHEN @DetectDuplicates = 1 THEN
                  STUFF((SELECT N', ' + d.index_name
                         FROM one_per_index d
                         WHERE d.object_id = ia.object_id AND d.index_id <> ia.index_id
                           AND d.key_signature = ia.key_signature
                           AND d.include_signature = ia.include_signature
                           AND COALESCE(d.filter_definition, N'') = COALESCE(ia.filter_definition, N'')
                         ORDER BY d.index_name
                         FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') END,
           overlaps_with =
             CASE WHEN @DetectOverlapping = 1 THEN
                  STUFF((SELECT N', ' + o.index_name
                         FROM one_per_index o
                         WHERE o.object_id = ia.object_id AND o.index_id <> ia.index_id
                           AND ia.key_signature <> o.key_signature
                           AND (LEFT(o.key_signature, LEN(ia.key_signature)) = ia.key_signature
                                OR LEFT(ia.key_signature, LEN(o.key_signature)) = o.key_signature)
                           AND COALESCE(o.filter_definition, N'') = COALESCE(ia.filter_definition, N'')
                         ORDER BY o.index_name
                         FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') END,
           sibling_of =
             CASE WHEN @DetectSiblings = 1 THEN
                  STUFF((SELECT N', ' + s.index_name
                         FROM one_per_index s
                         WHERE s.object_id = ia.object_id AND s.index_id <> ia.index_id
                           AND s.distinct_key_signature = ia.distinct_key_signature
                           AND s.key_signature <> ia.key_signature
                         ORDER BY s.index_name
                         FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') END
    FROM   #IndexAnalysis ia
    WHERE  ia.row_kind = 'INDEX';

    /*  A missing-index row can BLEND if some existing nonclustered index on the same table has the
        missing key's leading equality column(s) as its own leading key -- i.e. the missing signature
        and an existing signature share a leading prefix. Cheapest deterministic proxy: an existing
        key_signature whose first "c<id>" token matches the missing row's first equality column id.   */
    UPDATE ia
    SET    blend_target_index = x.tgt
    FROM   #IndexAnalysis ia
    CROSS APPLY
    (
        SELECT TOP (1) e.index_name AS tgt
        FROM   #MissingIndex mi
        JOIN   #MissingIndexColumn mic
               ON mic.missing_index_id = mi.missing_index_id
              AND mic.column_usage = 'EQUALITY' AND mic.ordinal = 1
        JOIN   #IndexAnalysis e
               ON e.row_kind = 'INDEX' AND e.object_id = mi.object_id AND e.index_id > 1
              AND e.key_signature LIKE CONCAT(N'c', mic.column_id, N'[AD].%')
        WHERE  mi.object_id = ia.object_id
          AND  mi.missing_index_id = CASE WHEN ia.index_name LIKE N'<<missing #%>>' THEN CONVERT(INT, REPLACE(REPLACE(ia.index_name, N'<<missing #', N''), N'>>', N'')) END
        ORDER  BY e.key_column_count, e.index_name
    ) x
    WHERE  ia.row_kind = 'MISSING'
      AND  ia.missing_impact < @MissingIndexMinImpact
      AND  ia.missing_impact >= @MissingIndexBlendMinImpact;

    /*  user_total_pct -- this index's share of its table's total read operations, DMV basis.         */
    UPDATE ia
    SET    user_total_pct =
             CASE WHEN t.tbl_reads > 0
                  THEN CAST(100.0 * ia.user_total / t.tbl_reads AS DECIMAL(6,2)) END
    FROM   #IndexAnalysis ia
    CROSS APPLY (SELECT SUM(x.user_total) AS tbl_reads
                 FROM #IndexAnalysis x
                 WHERE x.object_id = ia.object_id AND x.row_kind = 'INDEX'
                   AND x.partition_number = ia.partition_number) t
    WHERE  ia.row_kind = 'INDEX';

    /*  table_buffered_mb rollup.                                                                     */
    UPDATE ia
    SET    table_buffered_mb = t.tbmb
    FROM   #IndexAnalysis ia
    CROSS APPLY (SELECT SUM(x.buffered_mb) AS tbmb
                 FROM #IndexAnalysis x WHERE x.object_id = ia.object_id AND x.row_kind = 'INDEX') t;

    /*  10e. Dependent objects (Section 9b) -- one row per (table, dependent). The marker naming
            matches <<missing #N>> / <<fk: ...>>; the dependent's own type is in type_desc. Always
            index_action '---' (informational); Section 12c adds UNVERIFIED when it has no evidence. */
    IF @IncludeDependentObjects = 1
    BEGIN
        INSERT #IndexAnalysis
              (row_kind, schema_name, table_name, object_name, object_id, index_id, index_name,
               type_desc, table_row_count, table_column_count,
               dependency_kind, evidence_source, last_evidence_time)
        SELECT 'DEPENDENT', tm.schema_name, tm.table_name, tm.object_name, tm.object_id, NULL,
               N'<<dependent: ' + QUOTENAME(dobj.dependent_schema) + N'.' + QUOTENAME(dobj.dependent_name) + N'>>',
               dobj.dependent_type_desc, tm.table_row_count, tm.table_column_count,
               dobj.dependency_kind, dobj.evidence_source, dobj.last_evidence_time
        FROM   #DependentObject dobj
        JOIN   #TableMeta tm ON tm.object_id = dobj.referenced_object_id;
    END;

    /*------------------------------------------------------------------------------------------------
      11. QUERY STORE CORRELATION

      Skipped entirely when @QueryStoreUsable = 0 -- every qs_* column then stays NULL and ranking is
      the DMV basis. Three products:

        11-pre    #PlanEvidence     one row per PLAN the engine may read -- today every Query Store plan
                                    with runtime in the lookback window (the INTAKE)
        11a       #QsMissingBridge  for each missing-index group, the Query Store queries it is FOR
        11b       #QsIndexUsage     for each (index), the Query Store queries that still READ it
        11c       #QsQueryWeight    per table, a restart-proof workload weight for ranking
        11-shape  #PlanTableShape   per requested (plan, table): that plan's ORDER BY / GROUP BY columns
                                    attributed to that table, plus a window-operator tell

      11b and 11c share one shred of the Query Store stored plan XML: every rowstore Index / Heap
      access node, matched back to a table in #TableMeta and to an index_id by name. WITH XMLNAMESPACES
      prefixes the shred, or every .value()/.nodes() call silently returns nothing.

      THE INTAKE CONTRACT: see the script's Section 11 header. #PlanEvidence / #PlanTableShape are
      created in the outer scope above and truncated per database; a new evidence source inserts
      #PlanEvidence rows, proposes through #MissingIndex, requests its #PlanTableShape pairs, and
      touches nothing downstream. 11b / 11c filter evidence_source = 'QS' explicitly.
    ------------------------------------------------------------------------------------------------*/




    IF @QueryStoreUsable = 1
    BEGIN
        /*  11-pre (the Query Store plan pull into #PlanEvidence) now runs as Section 9c, BEFORE
            Section 10, so that Section 9d's proposals exist when the MISSING rows are assembled. */

        /*  11b/11c source. Shred every rowstore Object access node. Object/@Schema and @Table carry
            literal brackets ([Sales]); @Index does too. Match @Table to QUOTENAME(table_name); if
            @Index is present, resolve it to an index_id by name, else infer from @IndexKind. The
            two CROSS APPLYs use distinct aliases (r for the physical-op element, o for its Object
            child) -- reusing one alias for both is a bind error.

            The .value() extractions are pulled into #ShreddedAccess FIRST: XML methods are not allowed
            in a GROUP BY clause (Msg 4148), so the grouping runs off plain column aliases.            */
        DROP TABLE IF EXISTS #ShreddedAccess;
        ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        SELECT tm.object_id,
               rid.index_id                                   AS resolved_index_id,
               o.n.value('@IndexKind', 'NVARCHAR(40)')        AS index_kind,
               o.n.value('@Index', 'NVARCHAR(300)')           AS index_name_raw,
               qp.query_id,
               qp.executions,
               qp.total_duration_ms,
               qp.avg_duration_ms,
               r.op.value('local-name(.)', 'VARCHAR(20)')     AS access_op
        INTO   #ShreddedAccess
        FROM   #PlanEvidence qp
        CROSS APPLY qp.plan_xml.nodes('//RelOp/*') AS r(op)
        CROSS APPLY r.op.nodes('Object') AS o(n)
        JOIN   #TableMeta tm
                 ON  QUOTENAME(tm.table_name)  = o.n.value('@Table',  'NVARCHAR(300)')
                 AND QUOTENAME(tm.schema_name) = o.n.value('@Schema', 'NVARCHAR(300)')
        OUTER APPLY (SELECT im.index_id
                     FROM #IndexMeta im
                     WHERE im.object_id = tm.object_id
                       AND QUOTENAME(im.index_name) = o.n.value('@Index', 'NVARCHAR(300)')) rid
        WHERE  r.op.value('local-name(.)', 'VARCHAR(20)') IN
               ('IndexSeek','IndexScan','ColumnstoreIndexScan','TableScan')
          AND  qp.evidence_source = 'QS';         /* 11b / 11c: what actually RAN -- Query Store only */

        INSERT #QsIndexUsage (object_id, index_id, index_name_raw, query_id, executions,
                              total_duration_ms, avg_duration_ms, access_op)
        SELECT sa.object_id,
               COALESCE(sa.resolved_index_id,
                        CASE WHEN sa.index_kind = 'Heap' THEN 0
                             WHEN sa.index_kind IN ('Clustered','ViewClustered') THEN 1
                             ELSE -1 END),
               sa.index_name_raw,
               sa.query_id,
               SUM(sa.executions),
               SUM(sa.total_duration_ms),
               CAST(AVG(sa.avg_duration_ms) AS DECIMAL(18,2)),
               sa.access_op
        FROM   #ShreddedAccess sa
        GROUP  BY sa.object_id,
                  COALESCE(sa.resolved_index_id,
                           CASE WHEN sa.index_kind = 'Heap' THEN 0
                                WHEN sa.index_kind IN ('Clustered','ViewClustered') THEN 1
                                ELSE -1 END),
                  sa.index_name_raw, sa.query_id, sa.access_op;
        DROP TABLE IF EXISTS #ShreddedAccess;

        /*  11b fallback for plans too deep for the xml type (Section 9c keeps their text): searched as text for
            Schema="[s]" Table="[t]" Index="[i]" so drop-risk keeps every reader. See the script. */
        INSERT #QsIndexUsage (object_id, index_id, index_name_raw, query_id, executions,
                              total_duration_ms, avg_duration_ms, access_op)
        SELECT im.object_id, im.index_id, QUOTENAME(im.index_name), th.query_id,
               SUM(th.executions), SUM(th.total_duration_ms), CAST(AVG(th.avg_duration_ms) AS DECIMAL(18,2)),
               'PlanTooDeep'
        FROM  (SELECT qp.query_id, qp.executions, qp.total_duration_ms, qp.avg_duration_ms, qp.plan_text, tm.object_id,
                      N'Schema="' + REPLACE(REPLACE(REPLACE(REPLACE(QUOTENAME(tm.schema_name), N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), N'"', N'&quot;')
                    + N'" Table="' + REPLACE(REPLACE(REPLACE(REPLACE(QUOTENAME(tm.table_name), N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), N'"', N'&quot;') + N'"' AS table_attrs
               FROM   #PlanEvidence qp
               JOIN   #TableMeta tm
                        ON CHARINDEX((N'Table="' + REPLACE(REPLACE(REPLACE(REPLACE(QUOTENAME(tm.table_name), N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), N'"', N'&quot;') + N'"') COLLATE Latin1_General_BIN2,
                                     qp.plan_text COLLATE Latin1_General_BIN2) > 0
               WHERE  qp.evidence_source = 'QS'
                 AND  qp.plan_xml IS NULL
                 AND  qp.plan_text IS NOT NULL) th
        JOIN   #IndexMeta im ON im.object_id = th.object_id AND im.index_name IS NOT NULL
        WHERE  CHARINDEX((th.table_attrs + N' Index="' + REPLACE(REPLACE(REPLACE(REPLACE(QUOTENAME(im.index_name), N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), N'"', N'&quot;') + N'"') COLLATE Latin1_General_BIN2,
                         th.plan_text COLLATE Latin1_General_BIN2) > 0
        GROUP  BY im.object_id, im.index_id, im.index_name, th.query_id;


        /*  11c. Per-table workload weight -- one contribution per DISTINCT Query Store query that
            touches the table, so a query hitting two of its indexes is not double counted. The
            weight metric is @QsWeightMetric.                                                        */
        INSERT #QsQueryWeight (object_id, qs_executions, qs_total_duration_ms, qs_total_cpu_ms, qs_weight)
        SELECT d.object_id,
               SUM(qp.executions),
               SUM(qp.total_duration_ms),
               SUM(qp.total_cpu_ms),
               CASE @QsWeightMetric
                    WHEN 'DURATION'   THEN SUM(qp.total_duration_ms)
                    WHEN 'CPU'        THEN SUM(qp.total_cpu_ms)
                    WHEN 'EXECUTIONS' THEN CAST(SUM(qp.executions) AS DECIMAL(20,2))
               END
        FROM   (SELECT DISTINCT object_id, query_id FROM #QsIndexUsage) d
        JOIN   #PlanEvidence qp ON qp.query_id = d.query_id AND qp.evidence_source = 'QS'
        GROUP  BY d.object_id;

        /*  11a. Missing-index -> Query Store bridge.
            2019+  exact: group_handle -> dm_db_missing_index_group_stats_query -> query_hash ->
                   query_store_query.query_hash. Reached via sp_executesql because the DMV fails at
                   COMPILE time on 2016/2017.
            2016/2017 fallback: shred the <MissingIndexes> node out of the Query Store plan XML and
                   match table + equality/inequality column set.                                     */
        IF @HasMissingIndexQueryDmv = 1 AND @IncludeMissingIndexes = 1
        BEGIN
            SET @sqlBridge = N'
                INSERT #QsMissingBridge (missing_index_id, query_id, query_object_name, executions,
                                         avg_duration_ms, total_duration_ms, avg_cpu_ms, match_method)
                SELECT mi.missing_index_id, q.query_id,
                       CASE WHEN q.object_id <> 0 THEN QUOTENAME(OBJECT_SCHEMA_NAME(q.object_id)) + N''.'' + QUOTENAME(OBJECT_NAME(q.object_id))
                            ELSE N''(ad hoc / dynamic SQL)'' END,
                       agg.executions,
                       CASE WHEN agg.executions > 0 THEN agg.total_duration_ms / agg.executions ELSE 0 END,
                       agg.total_duration_ms,
                       CASE WHEN agg.executions > 0 THEN agg.total_cpu_ms / agg.executions ELSE 0 END,
                       ''HASH''
                FROM   #MissingIndex mi
                JOIN   sys.dm_db_missing_index_group_stats_query gsq ON gsq.group_handle = mi.group_handle
                JOIN   sys.query_store_query q ON q.query_hash = gsq.query_hash
                CROSS APPLY (SELECT SUM(rs.count_executions) AS executions,
                                    SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS total_duration_ms,
                                    SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS total_cpu_ms
                             FROM   sys.query_store_plan p
                             JOIN   sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
                             WHERE  p.query_id = q.query_id
                               AND  rs.execution_type = 0
                               AND  rs.last_execution_time >= @LookbackStartUtc) agg
                WHERE  agg.executions >= @MinExec;';
            SET @Sql = @Use + @sqlBridge;
            EXEC sys.sp_executesql @Sql,
                 N'@LookbackStartUtc DATETIME2(7), @MinExec BIGINT',
                 @LookbackStartUtc = @LookbackStart, @MinExec = @MinQsExecutionsForBridge;
        END;
        ELSE IF @IncludeMissingIndexes = 1
        BEGIN
            /*  Fallback for engine 2016 / 2017, where dm_db_missing_index_group_stats_query does not
                exist. The stored plan XML carries its own <MissingIndexes> recommendation; match it
                to our #MissingIndex rows on schema + table + the COUNT of EQUALITY and INEQUALITY
                columns. This is weaker than the 2019+ query_hash join -- it can over-match when one
                table has two missing-index suggestions of the same shape -- so match_method is
                reported ('PLANXML') and the caller can see which rows came this way. Untestable on
                the 2025 development box; see the delivery notes.                                      */
            ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
            INSERT #QsMissingBridge (missing_index_id, query_id, query_object_name, executions,
                                     avg_duration_ms, total_duration_ms, avg_cpu_ms, match_method)
            SELECT mi.missing_index_id, qp.query_id,
                   CASE WHEN qp.query_object_id IS NOT NULL AND qp.query_object_id <> 0
                        THEN QUOTENAME(OBJECT_SCHEMA_NAME(qp.query_object_id)) + N'.' + QUOTENAME(OBJECT_NAME(qp.query_object_id))
                        ELSE N'(ad hoc / dynamic SQL)' END,
                   SUM(qp.executions), CAST(AVG(qp.avg_duration_ms) AS DECIMAL(18,2)),
                   SUM(qp.total_duration_ms),
                   CAST(AVG(qp.total_cpu_ms / NULLIF(qp.executions, 0)) AS DECIMAL(18,2)),
                   'PLANXML'
            FROM   #PlanEvidence qp
            CROSS APPLY qp.plan_xml.nodes('//MissingIndexes/MissingIndexGroup/MissingIndex') AS m(n)
            CROSS APPLY (SELECT m.n.value('@Schema', 'NVARCHAR(300)') AS sch,
                                m.n.value('@Table',  'NVARCHAR(300)') AS tbl,
                                m.n.value('count(ColumnGroup[@Usage="EQUALITY"]/Column)',   'INT') AS eq_ct,
                                m.n.value('count(ColumnGroup[@Usage="INEQUALITY"]/Column)', 'INT') AS ineq_ct) mx
            JOIN   #TableMeta tm ON QUOTENAME(tm.table_name) = mx.tbl AND QUOTENAME(tm.schema_name) = mx.sch
            JOIN   #MissingIndex mi ON mi.object_id = tm.object_id
            JOIN   (SELECT missing_index_id,
                           SUM(CASE WHEN column_usage = 'EQUALITY'   THEN 1 ELSE 0 END) AS eq_ct,
                           SUM(CASE WHEN column_usage = 'INEQUALITY' THEN 1 ELSE 0 END) AS ineq_ct
                    FROM   #MissingIndexColumn
                    GROUP  BY missing_index_id) mc
                   ON mc.missing_index_id = mi.missing_index_id
                  AND mc.eq_ct = mx.eq_ct AND mc.ineq_ct = mx.ineq_ct
            WHERE  qp.plan_xml IS NOT NULL AND qp.evidence_source = 'QS'
            GROUP  BY mi.missing_index_id, qp.query_id, qp.query_object_id;
        END;

        /*  11a-2. Which evidence plan SHAPES each proposal: the dominant bridged query (most total
            duration; ties -> lowest query_id) and, of that query's stored plans, the most executed
            (ties -> lowest plan_id). That last tie-break is new with the intake refactor: before it, a
            query with two stored plans handed over whichever one the join met first. Recorded on the
            proposal itself, then requested from the shape shred (after this block). Where a bridge
            exists this overrides a driving plan Section 9d may already have set from a dependent's
            plan -- the Query Store bridge wins, so DMV proposals keep today's behaviour.            */
        UPDATE mi
        SET    driving_evidence_id = d.evidence_id
        FROM   #MissingIndex mi
        JOIN  (SELECT mb.missing_index_id, pe.evidence_id,
                      ROW_NUMBER() OVER (PARTITION BY mb.missing_index_id
                                         ORDER BY mb.total_duration_ms DESC, mb.query_id ASC,
                                                  pe.executions DESC, pe.plan_id ASC) AS rn
               FROM   #QsMissingBridge mb
               JOIN   #PlanEvidence pe ON pe.evidence_source = 'QS' AND pe.query_id = mb.query_id
                                      AND pe.plan_xml IS NOT NULL) d
               ON d.missing_index_id = mi.missing_index_id AND d.rn = 1;

        /*  Fold the Query Store figures back onto #IndexAnalysis. ------------------------------------ */

        /*  MISSING rows: the bridge summary.                                                          */
        UPDATE ia
        SET    qs_query_ids     = b.query_id_list,
               qs_executions    = b.executions,
               qs_avg_duration_ms = b.avg_duration_ms,
               qs_total_duration_ms = b.total_duration_ms,
               qs_avg_cpu_ms    = b.avg_cpu_ms
        FROM   #IndexAnalysis ia
        CROSS APPLY (SELECT SUM(x.executions) AS executions,
                            CAST(AVG(x.avg_duration_ms) AS DECIMAL(18,2)) AS avg_duration_ms,
                            SUM(x.total_duration_ms) AS total_duration_ms,
                            CAST(AVG(x.avg_cpu_ms) AS DECIMAL(18,2)) AS avg_cpu_ms,
                            STUFF((SELECT N', ' + CONVERT(NVARCHAR(20), y.query_id)
                                   FROM #QsMissingBridge y
                                   WHERE y.missing_index_id = CASE WHEN ia.index_name LIKE N'<<missing #%>>' THEN CONVERT(INT, REPLACE(REPLACE(ia.index_name, N'<<missing #', N''), N'>>', N'')) END
                                   ORDER BY y.total_duration_ms DESC
                                   FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS query_id_list
                     FROM #QsMissingBridge x
                     WHERE x.missing_index_id = CASE WHEN ia.index_name LIKE N'<<missing #%>>' THEN CONVERT(INT, REPLACE(REPLACE(ia.index_name, N'<<missing #', N''), N'>>', N'')) END) b
        WHERE  ia.row_kind = 'MISSING' AND b.executions IS NOT NULL;

        /*  INDEX rows: drop-risk (11b) and the table weight (11c).                                    */
        UPDATE ia
        SET    qs_drop_risk_query_ct = u.query_ct,
               qs_query_ids = u.query_id_list,
               qs_executions = u.executions,
               qs_total_duration_ms = u.total_duration_ms
        FROM   #IndexAnalysis ia
        CROSS APPLY (SELECT COUNT(DISTINCT x.query_id) AS query_ct,
                            SUM(x.executions) AS executions,
                            SUM(x.total_duration_ms) AS total_duration_ms,
                            STUFF((SELECT TOP (@DropRiskMaxQueriesPerIndex) N', ' + CONVERT(NVARCHAR(20), y.query_id)
                                   FROM (SELECT query_id, SUM(total_duration_ms) AS d FROM #QsIndexUsage y2
                                         WHERE y2.object_id = ia.object_id AND y2.index_id = ia.index_id
                                         GROUP BY query_id) y
                                   ORDER BY y.d DESC
                                   FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS query_id_list
                     FROM #QsIndexUsage x
                     WHERE x.object_id = ia.object_id AND x.index_id = ia.index_id) u
        WHERE  ia.row_kind = 'INDEX';

        UPDATE ia
        SET    qs_table_weight = w.qs_weight
        FROM   #IndexAnalysis ia
        JOIN   #QsQueryWeight w ON w.object_id = ia.object_id;
    END;

    /*  11-shape -- OUTSIDE the Query Store guard since 2026-09-12: a proposal whose driving plan
        came from the plan cache (Section 9d, a CACHE-only dependent) needs its shape shredded even
        when Query Store is unusable. Reads temp tables only, so it runs in either context.        */
    INSERT #PlanTableShape (evidence_id, object_id)
    SELECT DISTINCT mi.driving_evidence_id, mi.object_id
    FROM   #MissingIndex mi
    WHERE  mi.driving_evidence_id IS NOT NULL;

    /*  THE INTAKE SHRED -- the one place a plan's shape is read for a table. Fills every requested
        (evidence plan, table) pair in #PlanTableShape: the rows are requested just above for every
        proposal with a driving plan -- a Query Store bridge's (11a-2) or a dependent's (9d) -- and
        a future pasted-plan path would request its pairs the same way, with no code here. Per pair:
        the OUTERMOST result Sort's columns ((...)[1] in document order, which is plan-tree
        pre-order, so the top Sort; .nodes() keeps that order) and the FIRST GroupBy's columns, both
        restricted to THAT table's own columns -- a query that joins another table and sorts on ITS
        column must not have that attributed here; matched on #TableMeta's stored names, never
        OBJECT_NAME(object_id), which resolves in DBAdmin here (this analysis half is NOT
        USE [target]) and returns NULL. @Column is unbracketed in showplan, so QUOTENAME it to match
        key_columns_display; ` DESC` from @Ascending false/0; expression / parameter keys (Expr%, @%)
        skipped; non-Distinct Sorts only. And whether a window operator -- Sequence Project
        (ranking), Segment (row-mode window aggregate) or Window Aggregate -- is anywhere in it.   */
    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    UPDATE s
    SET    order_by_cols = ob.cols,
           group_by_cols = gb.cols,
           has_window_op = wf.present
    FROM   #PlanTableShape s
    JOIN   #PlanEvidence pe ON pe.evidence_id = s.evidence_id
    JOIN   #TableMeta tm ON tm.object_id = s.object_id
    CROSS APPLY (SELECT STUFF((
                    SELECT N', ' + QUOTENAME(oc.n.value('(ColumnReference/@Column)[1]', 'NVARCHAR(300)'))
                           + CASE WHEN oc.n.value('@Ascending', 'NVARCHAR(10)') IN (N'false', N'0') THEN N' DESC' ELSE N'' END
                    FROM   pe.plan_xml.nodes('(//RelOp/Sort[@Distinct="false" or @Distinct="0"])[1]/OrderBy/OrderByColumn') AS oc(n)
                    WHERE  oc.n.value('(ColumnReference/@Column)[1]', 'NVARCHAR(300)') IS NOT NULL
                      AND  oc.n.value('(ColumnReference/@Column)[1]', 'NVARCHAR(300)') NOT LIKE N'Expr%'
                      AND  oc.n.value('(ColumnReference/@Column)[1]', 'NVARCHAR(300)') NOT LIKE N'@%'
                      AND  oc.n.value('(ColumnReference/@Table)[1]',  'NVARCHAR(300)') = QUOTENAME(tm.table_name)
                      AND  oc.n.value('(ColumnReference/@Schema)[1]', 'NVARCHAR(300)') = QUOTENAME(tm.schema_name)
                    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS cols) ob
    CROSS APPLY (SELECT STUFF((
                    SELECT N', ' + QUOTENAME(g.col)
                    FROM  (SELECT DISTINCT gc.n.value('@Column', 'NVARCHAR(300)') AS col
                           FROM   pe.plan_xml.nodes('(//GroupBy)[1]/ColumnReference') AS gc(n)
                           WHERE  gc.n.value('@Table',  'NVARCHAR(300)') = QUOTENAME(tm.table_name)
                             AND  gc.n.value('@Schema', 'NVARCHAR(300)') = QUOTENAME(tm.schema_name)) g
                    WHERE  g.col IS NOT NULL AND g.col NOT LIKE N'Expr%' AND g.col NOT LIKE N'@%'
                    ORDER  BY g.col
                    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS cols) gb
    CROSS APPLY (SELECT CASE WHEN pe.plan_xml.exist('//RelOp[@PhysicalOp = "Sequence Project"
                                                          or @PhysicalOp = "Segment"
                                                          or @PhysicalOp = "Window Aggregate"]') = 1
                             THEN 1 ELSE 0 END AS present) wf
    WHERE  s.has_window_op IS NULL AND pe.plan_xml IS NOT NULL;

    /*  MISSING rows: the driving plan's ORDER BY / GROUP BY and window tell, read from the intake
        shape -- so a caller (ComparePlans --realign-missing-indexes; Section 13b) can reorder the
        proposed key by FPOC and drop the query's Sort / Hash Aggregate. missing_window_kind: a
        window operator in the driving plan means the realigned key is really a windowing POC index
        -- its GROUP BY slot is the OVER (PARTITION BY ...) list (which surfaces as a Segment
        <GroupBy>), its ORDER BY slot the OVER (ORDER BY ...). 'FPOC' when the proposal also carries
        a filter (equality / inequality columns), 'POC' when it does not. This only LABELS the
        REALIGN line -- the tool still does not parse OVER () itself.                              */
    UPDATE ia
    SET    missing_order_by_cols = NULLIF(s.order_by_cols, N''),
           missing_group_by_cols = NULLIF(s.group_by_cols, N''),
           missing_window_kind   = CASE WHEN s.has_window_op = 1
                                        THEN CASE WHEN ia.equality_columns IS NOT NULL
                                                  OR   ia.inequality_columns IS NOT NULL
                                                  THEN N'FPOC' ELSE N'POC' END
                                        ELSE NULL END
    FROM   #IndexAnalysis ia
    JOIN   #MissingIndex mi
           ON mi.missing_index_id = CASE WHEN ia.index_name LIKE N'<<missing #%>>'
                                         THEN CONVERT(INT, REPLACE(REPLACE(ia.index_name, N'<<missing #', N''), N'>>', N'')) END
    JOIN   #PlanTableShape s ON s.evidence_id = mi.driving_evidence_id AND s.object_id = mi.object_id
    WHERE  ia.row_kind = 'MISSING';

    /*------------------------------------------------------------------------------------------------
      11d. RANK CANDIDATES WITHIN EACH TABLE

      DENSE_RANK, not ROW_NUMBER -- every partition of an index shares one rank, and Modes DUPLICATE /
      OVERLAPPING / REALIGN must not lose a partition to a tie break.

      rank_source per row:
         'QS'  when @EffectiveRankingSource is QS, or is BLEND and Query Store has coverage for the
               table (#QsQueryWeight has a row) -- rank by this index's Query Store executions.
         'DMV' otherwise -- rank by user_total (seeks + scans + lookups).                             */
    ;WITH ranked AS
    (
        SELECT ia.analysis_id,
               CASE WHEN @EffectiveRankingSource = 'QS' THEN 'QS'
                    WHEN @EffectiveRankingSource = 'BLEND' AND w.object_id IS NOT NULL THEN 'QS'
                    ELSE 'DMV' END AS rs,
               DENSE_RANK() OVER (
                   PARTITION BY ia.object_id
                   ORDER BY
                       CASE WHEN (@EffectiveRankingSource = 'QS'
                                  OR (@EffectiveRankingSource = 'BLEND' AND w.object_id IS NOT NULL))
                            THEN COALESCE(ia.qs_executions, 0)
                            ELSE COALESCE(ia.user_total, 0) END DESC,
                       ia.index_id ) AS rnk
        FROM   #IndexAnalysis ia
        LEFT  JOIN #QsQueryWeight w ON w.object_id = ia.object_id
        WHERE  ia.row_kind = 'INDEX'
    )
    UPDATE ia
    SET    rank_source = r.rs,
           table_rank  = r.rnk
    FROM   #IndexAnalysis ia
    JOIN   ranked r ON r.analysis_id = ia.analysis_id;

    /*------------------------------------------------------------------------------------------------
      12. ACTION + PROS / CONS

      index_action -- ONE verb per row, most consequential first:
         ENABLE       a disabled index (rebuild to bring it back)
         DROP-DUP     an exact duplicate of a lower-index_id sibling (keep the other)
         DROP-DUP?    ditto, but Query Store shows a query still naming this one specifically
         DROP-USAGE   a nonclustered index with zero cumulative reads, safe window since startup
         DROP-USAGE?  ditto, but Query Store shows reads inside @LookbackDays
         REALIGN      a clustered index / heap taking heavy lookups or almost no read traffic
         SEQKEY       last-page insert contention signature -> OPTIMIZE_FOR_SEQUENTIAL_KEY (2019+)
         CREATE       a missing index above @MissingIndexMinImpact (top N per table), or an FK gap
         BLEND        a lower-impact missing index that folds into an existing index's leading key
         ---          nothing to do

      index_pros / index_cons -- compact tokens, comma separated. Pros: PK, UQ, CLU, FK, MIFK, and
      read:write bands $ / $$ / $$$ / $$$+. Cons: HP, DUP, OVLP, SIB, LKUP, SCN, U1%, WIDE, C25% /
      C50% / C90%, NOCMP, DSB, W$, JSONCOL, TOOSOON (DROP-USAGE withheld -- counters too fresh).

      NOTE ON CREATE-JSON: v1 emits a JSONCOL token (table has a native json column, engine 2025) as
      a pointer, NOT a generated CREATE JSON INDEX statement and NOT its own action -- path extraction
      from Query Store plans is deferred, same phase boundary as columnstore / vector guidance.
    ------------------------------------------------------------------------------------------------*/

    /*  12a. Which duplicate is the KEEPER: lowest index_id wins (PK / clustered first). Only the
            non-keepers get DROP-DUP.                                                                 */
    ;WITH dup_keeper AS
    (
        SELECT ia.analysis_id,
               MIN(CASE WHEN ia.duplicate_of IS NOT NULL THEN ia.index_id END)
                   OVER (PARTITION BY ia.object_id, ia.key_signature, ia.include_signature) AS keeper_index_id
        FROM   #IndexAnalysis ia
        WHERE  ia.row_kind = 'INDEX'
    )
    UPDATE ia
    SET    index_action =
            CASE
                WHEN ia.is_disabled = 1 THEN 'ENABLE'
                WHEN ia.duplicate_of IS NOT NULL AND ia.index_id > 1
                     AND ia.index_id <> dk.keeper_index_id
                     AND ia.is_primary_key = 0 AND ia.is_unique = 0
                    THEN CASE WHEN COALESCE(ia.qs_drop_risk_query_ct, 0) > 0 THEN 'DROP-DUP?' ELSE 'DROP-DUP' END
                WHEN ia.index_id > 1 AND ia.duplicate_of IS NULL AND ia.is_unique = 0
                     AND ia.has_filter = 0
                     AND COALESCE(ia.user_total, 0) = 0
                     AND NOT EXISTS (SELECT 1 FROM #ForeignKeyGap g WHERE g.parent_object_id = ia.object_id
                                     AND LEFT(ia.key_signature, LEN(g.fk_key_signature)) = g.fk_key_signature)
                    THEN CASE WHEN COALESCE(ia.qs_drop_risk_query_ct, 0) > 0 THEN 'DROP-USAGE?'
                              WHEN @DaysSinceStartup < @UnusedIndexMinDaysSinceStartup THEN '---'   /* withheld; TOOSOON con added below */
                              ELSE 'DROP-USAGE' END
                WHEN ia.index_id IN (0, 1)
                     AND ( (COALESCE(ia.user_lookups, 0) >= @LookupHeavyMinLookups
                            AND ia.user_lookups > COALESCE(ia.user_seeks, 0))
                        OR (COALESCE(ia.user_total_pct, 100) < @RealignLowUsagePercent
                            AND EXISTS (SELECT 1 FROM #IndexAnalysis x WHERE x.object_id = ia.object_id
                                        AND x.row_kind = 'INDEX' AND COALESCE(x.user_total,0) > 0)) )
                    THEN 'REALIGN'
                WHEN @HasSequentialKeyOption = 1 AND ia.index_id >= 1
                     AND COALESCE(ia.page_latch_wait_count, 0) >= @SeqKeyMinPageLatchWaits
                     AND EXISTS (SELECT 1 FROM #IndexColumns k
                                 WHERE k.object_id = ia.object_id AND k.index_id = ia.index_id
                                   AND k.is_included = 0 AND k.key_ordinal = 1 AND k.is_descending_key = 0)
                    THEN 'SEQKEY'
                ELSE '---'
            END
    FROM   #IndexAnalysis ia
    JOIN   dup_keeper dk ON dk.analysis_id = ia.analysis_id
    WHERE  ia.row_kind = 'INDEX';

    /*  12b. MISSING and FKGAP actions.                                                               */
    ;WITH missing_ranked AS
    (
        SELECT ia.analysis_id,
               ROW_NUMBER() OVER (PARTITION BY ia.object_id ORDER BY ia.missing_impact DESC) AS impact_rank
        FROM   #IndexAnalysis ia
        WHERE  ia.row_kind = 'MISSING'
    )
    UPDATE ia
    SET    index_action =
             CASE
                 WHEN ia.missing_impact >= @MissingIndexMinImpact AND mr.impact_rank <= @MaxMissingIndexesPerTable THEN 'CREATE'
                 WHEN ia.missing_impact >= @MissingIndexBlendMinImpact AND ia.blend_target_index IS NOT NULL      THEN 'BLEND'
                 ELSE '---'
             END
    FROM   #IndexAnalysis ia
    JOIN   missing_ranked mr ON mr.analysis_id = ia.analysis_id;

    UPDATE #IndexAnalysis SET index_action = 'CREATE' WHERE row_kind = 'FKGAP';
    UPDATE #IndexAnalysis SET index_action = '---'    WHERE row_kind = 'DEPENDENT';

    /*  12c. Pros / cons token strings. CONCAT seeded with a MAX literal so the 4000-char cap cannot
            eat a trailing token; COALESCE (not ISNULL) so the fallback keeps its full type.          */
    UPDATE ia
    SET    index_pros = NULLIF(STUFF(CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                CASE WHEN ia.is_primary_key = 1 THEN N', PK' ELSE N'' END,
                CASE WHEN ia.is_unique = 1 AND ia.is_primary_key = 0 THEN N', UQ' ELSE N'' END,
                CASE WHEN ia.index_id = 1 THEN N', CLU' ELSE N'' END,
                CASE WHEN ia.row_kind = 'FKGAP' THEN N', MIFK'
                     WHEN EXISTS (SELECT 1 FROM #ForeignKeyGap g WHERE g.parent_object_id = ia.object_id
                                  AND ia.key_signature IS NOT NULL
                                  AND LEFT(ia.key_signature, LEN(g.fk_key_signature)) = g.fk_key_signature) THEN N', FK'
                     ELSE N'' END,
                CASE WHEN ia.reads_per_write IS NULL THEN N''
                     WHEN ia.reads_per_write >= 1000 THEN N', $$$+'
                     WHEN ia.reads_per_write >= 100  THEN N', $$$'
                     WHEN ia.reads_per_write >= 10   THEN N', $$'
                     WHEN ia.reads_per_write >= 1    THEN N', $'
                     ELSE N'' END
            ), 1, 2, N''), N''),
           index_cons = NULLIF(STUFF(CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                CASE WHEN ia.is_heap = 1 AND ia.index_id = 0 THEN N', HP' ELSE N'' END,
                CASE WHEN ia.is_disabled = 1 THEN N', DSB' ELSE N'' END,
                CASE WHEN ia.duplicate_of  IS NOT NULL THEN N', DUP'  ELSE N'' END,
                CASE WHEN ia.overlaps_with IS NOT NULL THEN N', OVLP' ELSE N'' END,
                CASE WHEN ia.sibling_of    IS NOT NULL THEN N', SIB'  ELSE N'' END,
                CASE WHEN COALESCE(ia.user_lookups,0) >= @LookupHeavyMinLookups
                          AND ia.user_lookups > COALESCE(ia.user_seeks,0) + COALESCE(ia.user_scans,0) THEN N', LKUP' ELSE N'' END,
                CASE WHEN COALESCE(ia.user_scans,0) >= @ScanHeavyMinScans
                          AND COALESCE(ia.user_seeks,0) * @ScanToSeekRatioThreshold < ia.user_scans THEN N', SCN' ELSE N'' END,
                CASE WHEN ia.row_kind = 'INDEX' AND ia.index_id > 1
                          AND COALESCE(ia.user_total_pct, 100) < @LowUsagePercentThreshold THEN N', U1%' ELSE N'' END,
                CASE WHEN ia.row_kind = 'INDEX' AND ia.index_id > 1
                          AND COALESCE(ia.key_column_count,0) + COALESCE(ia.include_column_count,0) >= @WideCoveringMinKeyPlusInclude
                          AND ia.table_column_count > 0
                     THEN CASE
                            WHEN 100.0 * (ia.key_column_count + ia.include_column_count) / ia.table_column_count >= @WideCoveringPct90 THEN N', C90%'
                            WHEN 100.0 * (ia.key_column_count + ia.include_column_count) / ia.table_column_count >= @WideCoveringPct50 THEN N', C50%'
                            WHEN 100.0 * (ia.key_column_count + ia.include_column_count) / ia.table_column_count >= @WideCoveringPct25 THEN N', C25%'
                            ELSE N', WIDE' END
                     ELSE N'' END,
                CASE WHEN @CheckCompression = 1 AND ia.row_kind = 'INDEX'
                          AND ia.data_compression_desc = N'NONE'
                          AND COALESCE(ia.index_row_count,0) >= @PageCompressionRowThreshold THEN N', NOCMP' ELSE N'' END,
                CASE WHEN ia.reads_per_write IS NOT NULL AND ia.reads_per_write < @WriteHeavyReadsPerWrite THEN N', W$' ELSE N'' END,
                CASE WHEN EXISTS (SELECT 1 FROM #TableMeta t WHERE t.object_id = ia.object_id AND t.has_native_json_column = 1)
                     THEN N', JSONCOL' ELSE N'' END,
                CASE WHEN ia.index_id > 1 AND ia.duplicate_of IS NULL AND ia.is_unique = 0
                          AND COALESCE(ia.user_total,0) = 0 AND COALESCE(ia.qs_drop_risk_query_ct,0) = 0
                          AND @DaysSinceStartup < @UnusedIndexMinDaysSinceStartup THEN N', TOOSOON' ELSE N'' END,
                /*  Section 9b. UNVERIFIED on the dependent's own row; DEPUNV on a drop candidate (or a
                    TOOSOON-held one, which is a drop candidate in waiting) whose table has one.        */
                CASE WHEN ia.row_kind = 'DEPENDENT' AND ia.evidence_source = 'NONE' THEN N', UNVERIFIED' ELSE N'' END,
                CASE WHEN @IncludeDependentObjects = 1 AND ia.row_kind = 'INDEX'
                          AND (ia.index_action LIKE 'DROP-%'
                               OR (ia.index_id > 1 AND ia.duplicate_of IS NULL AND ia.is_unique = 0
                                   AND COALESCE(ia.user_total,0) = 0 AND COALESCE(ia.qs_drop_risk_query_ct,0) = 0
                                   AND @DaysSinceStartup < @UnusedIndexMinDaysSinceStartup))
                          AND EXISTS (SELECT 1 FROM #DependentObject u
                                      WHERE u.referenced_object_id = ia.object_id AND u.evidence_source = 'NONE')
                     THEN N', DEPUNV' ELSE N'' END
            ), 1, 2, N''), N'')
    FROM   #IndexAnalysis ia;

    /*------------------------------------------------------------------------------------------------
      12d. COMPRESSION RECOMMENDATION -- a U/S-based PAGE recommendation, per the SQL Server technical
           article "Data Compression: Strategy, Capacity Planning and Best Practices" (Mishra, 2009).

           U = leaf_update_count / D,  S = range_scan_count / D, both from sys.dm_db_index_operational_stats,
           D = range_scan + leaf_insert + leaf_delete + leaf_update + leaf_page_merge + singleton_lookup
           (computed into ops_scan_pct / ops_update_pct / ops_insert_pct at collection).

           @WorkloadType = 'OLTP' (default) -- object by object:
                S > @CompressionScanPctForPage  AND  U < @CompressionUpdatePctForPage   (scan-heavy, rarely updated)
             OR inserts > @CompressionAppendOnlyInsertPct AND U < @CompressionUpdatePctForPage
                     (write-once / rarely-read log & audit pattern -- a PAGE candidate even when S is low)
           @WorkloadType = 'DW'   -- the paper's shortcut: page-compress every sizeable object, skip U/S.

           ROW is NEVER recommended. Nothing is recommended when the operational-stats numbers are
           absent (ops_scan_pct IS NULL) or fresher than @UnusedIndexMinDaysSinceStartup -- OLTP mode
           only; DW mode does not depend on the counters. Applies to data_compression NONE (compress)
           and ROW (upgrade to PAGE); PAGE / columnstore / mixed are left alone.
    ------------------------------------------------------------------------------------------------*/
    IF @RecommendCompression = 1
    BEGIN
        UPDATE ia
        SET    recommended_compression = N'PAGE',
               compression_reason =
                 CASE
                   WHEN @WorkloadType = 'DW'
                        THEN N'DW / data-mart workload -- page-compress all sizeable objects (assumes CPU headroom); the MS best-practices shortcut'
                   WHEN COALESCE(ia.ops_insert_pct, 0) >= @CompressionAppendOnlyInsertPct
                        THEN CONCAT(N'append-only (inserts ', CONVERT(NVARCHAR(10), ia.ops_insert_pct),
                                    N'%, updates ', CONVERT(NVARCHAR(10), ia.ops_update_pct),
                                    N'%) -- write-once / rarely read; a PAGE candidate even at low scan %')
                   ELSE CONCAT(N'S=', CONVERT(NVARCHAR(10), ia.ops_scan_pct), N'% > ',
                               CONVERT(NVARCHAR(10), @CompressionScanPctForPage),
                               N', U=', CONVERT(NVARCHAR(10), ia.ops_update_pct), N'% < ',
                               CONVERT(NVARCHAR(10), @CompressionUpdatePctForPage),
                               N' -- scan-heavy and rarely updated')
                 END
                 + CASE WHEN ia.data_compression_desc = N'ROW' THEN N' (currently ROW -- upgrade to PAGE)' ELSE N'' END
                 + CASE WHEN ia.is_heap = 1 AND ia.index_id = 0
                        THEN N' | Heap DML pages don''t get PAGE compression until the heap is rebuilt.' ELSE N'' END
        FROM   #IndexAnalysis ia
        WHERE  ia.row_kind = 'INDEX'
          AND  ia.index_id IS NOT NULL
          AND  ia.data_compression_desc IN (N'NONE', N'ROW')
          AND  COALESCE(ia.index_row_count, 0) >= @PageCompressionRowThreshold
          AND  (
                 @WorkloadType = 'DW'
              OR (@WorkloadType = 'OLTP'
                  AND @DaysSinceStartup >= @UnusedIndexMinDaysSinceStartup
                  AND ia.ops_scan_pct IS NOT NULL
                  AND ( (ia.ops_scan_pct   >  @CompressionScanPctForPage
                         AND ia.ops_update_pct < @CompressionUpdatePctForPage)
                     OR (COALESCE(ia.ops_insert_pct, 0) >= @CompressionAppendOnlyInsertPct
                         AND ia.ops_update_pct < @CompressionUpdatePctForPage) ))
              );
    END;

    /*------------------------------------------------------------------------------------------------
      12e. KEY-COLUMN BYTE WIDTH  (feeds the REVIEW guard added to Section 13's generated DDL text)

      @MaxIndexKeyBytes has been reserved since this file's first draft, waiting on exactly this: a
      byte-precise companion to the key-COLUMN-COUNT guard (@MaxIndexKeyColumns) already live in
      Section 13. Two distinct failure modes, not one -- confirmed against Microsoft's own CREATE
      INDEX / included-columns / json-data-type docs (2026-09-12), not assumed:
        - CATEGORICALLY impossible as a key column, regardless of width. ntext / text / image are
          barred from an index ENTIRELY, key or include, and can't appear in a comparison predicate
          at all without a CONVERT first -- so neither the missing-index DMV nor the Section 11a
          plan-XML shred can ever surface one as a key candidate; this branch is a defensive
          backstop, not a reachable path (same disclosed-gap shape as ComparePlans' THREAD_SKEW: "no
          fixture", not "untested"). varchar(max) / nvarchar(max) / varbinary(max) / xml / json are
          barred as a KEY specifically -- legal as INCLUDE (which is why this guard is never applied
          to an INCLUDE list) -- and are equally non-comparable, so they can't reach a real
          proposal's key either.
        - Numerically too wide. A legal key-column type whose declared/summed size exceeds
          @MaxIndexKeyBytes (1700 -- the current, 2016+ engine limit; the pre-2016 900-byte floor is
          not modelled, nothing in this fleet runs pre-2016). Two different messages: an all-fixed-
          width key already over the limit fails CREATE INDEX outright; a key containing a variable-
          length column can still be CREATED and only fails later, on an insert/update that pushes
          the actual data past the limit (Microsoft: "the combined sizes of the data ... can never
          exceed the limit" -- the declared max is a ceiling, not a guaranteed failure at create time).
      Per-column byte sizes: fixed types by documented size; decimal/numeric banded by precision
      (5/9/13/17 bytes for precision 1-9/10-19/20-28/29-38, Microsoft's own decimal/numeric storage
      table); bounded variable-length types by max_length (already byte-correct for nvarchar/nchar,
      which store 2 bytes per declared character). An unrecognised type is flagged via
      ineligible_reason, never silently guessed -- matches this file's own no-silent-guessing rule.  */
    /*  Built in the TARGET's context via dynamic SQL: sys.columns / sys.types are per-database and
        this analysis half runs in DBAdmin. #ColumnWidth is created in the outer scope and truncated
        per database; the SELECT below is the script's, verbatim, literals doubled for the dynamic
        string, and it filters on the rows' stored object_id, never OBJECT_ID(name). Until 2026-09-12
        this ran here as STATIC SQL -- DBAdmin's own catalog, OBJECT_ID(name) resolving in DBAdmin --
        so the width guard silently never fired from the procedure (same trap class as the
        OBJECT_NAME(object_id) realign bug of 2026-09-07). Found while re-reading for the intake
        work; @Debug = 1 now reports the row count so the fill is observable.                     */
    SET @Inner = N'
INSERT #ColumnWidth (object_id, column_name, ineligible_reason, is_variable_length, estimated_bytes)
SELECT       c.object_id,
             c.name                                                         AS column_name,
             CASE WHEN t.name IN (N''text'', N''ntext'', N''image'')
                       THEN N''cannot be a key or include column (Microsoft: text/ntext/image are excluded from indexes entirely)''
                  WHEN t.name = N''xml''
                       THEN N''cannot be a key column (Microsoft: xml can''''t be compared or sorted; legal only as INCLUDE)''
                  WHEN t.name = N''json''
                       THEN N''cannot be a key column (Microsoft: the json type can''''t be used as a key column; legal only as INCLUDE)''
                  WHEN t.name IN (N''varchar'', N''nvarchar'', N''varbinary'') AND c.max_length = -1
                       THEN N''cannot be a key column (Microsoft: '' + t.name + N''(max) is a LOB type excluded from index keys; legal only as INCLUDE)''
                  WHEN t.name IN (N''varchar'', N''nvarchar'', N''char'', N''nchar'', N''varbinary'', N''binary'',
                                   N''decimal'', N''numeric'', N''bigint'', N''int'', N''smallint'', N''tinyint'',
                                   N''bit'', N''datetime'', N''smalldatetime'', N''date'', N''time'', N''datetime2'',
                                   N''datetimeoffset'', N''money'', N''smallmoney'', N''float'', N''real'',
                                   N''uniqueidentifier'')
                       THEN NULL
                  ELSE N''type not recognised by this check -- review manually''
             END                                                            AS ineligible_reason,
             CASE WHEN t.name IN (N''varchar'', N''nvarchar'', N''varbinary'') AND c.max_length <> -1
                  THEN 1 ELSE 0 END                                         AS is_variable_length,
             CASE WHEN t.name IN (N''varchar'', N''nvarchar'', N''char'', N''nchar'', N''varbinary'', N''binary'')
                       AND c.max_length <> -1
                       THEN CONVERT(INT, c.max_length)
                  WHEN t.name IN (N''decimal'', N''numeric'')
                       THEN CASE WHEN c.precision <= 9  THEN 5
                                 WHEN c.precision <= 19 THEN 9
                                 WHEN c.precision <= 28 THEN 13
                                 ELSE 17 END
                  WHEN t.name IN (N''bigint'', N''datetime'', N''money'', N''float'')       THEN 8
                  WHEN t.name IN (N''smalldatetime'', N''smallmoney'', N''real'', N''int'') THEN 4
                  WHEN t.name = N''smallint''                                  THEN 2
                  WHEN t.name IN (N''tinyint'', N''bit'')                        THEN 1
                  WHEN t.name = N''date''                                      THEN 3
                  WHEN t.name = N''time''           THEN CASE WHEN c.scale <= 2 THEN 3 WHEN c.scale <= 4 THEN 4 ELSE 5 END
                  WHEN t.name = N''datetime2''      THEN CASE WHEN c.scale <= 2 THEN 6 WHEN c.scale <= 4 THEN 7 ELSE 8 END
                  WHEN t.name = N''datetimeoffset'' THEN CASE WHEN c.scale <= 2 THEN 8 WHEN c.scale <= 4 THEN 9 ELSE 10 END
                  WHEN t.name = N''uniqueidentifier''                         THEN 16
                  ELSE NULL
             END                                                            AS estimated_bytes
FROM   sys.columns c
JOIN   sys.types   t ON t.user_type_id = c.system_type_id
WHERE  c.object_id IN (SELECT DISTINCT ia.object_id FROM #IndexAnalysis ia);';
    SET @Sql = @Use + N'EXEC sys.sp_executesql @InnerIn;';
    EXEC sys.sp_executesql @Sql, N'@InnerIn NVARCHAR(MAX)', @InnerIn = @Inner;
    IF @Debug = 1
    BEGIN
        SELECT @Rows = COUNT(*) FROM #ColumnWidth;
        RAISERROR('%s: %d column-width row(s) (Section 12e, filled in the target''s context)', 0, 0, @LoopDb, @Rows) WITH NOWAIT;
    END;

    /*------------------------------------------------------------------------------------------------
      12f. STRUCTURAL (CATALOG-ONLY) CONS -- CLNU / CLWIDE / FILL<n>. See the script's Section 12f
      header for what each one means and why this tier was done first: these read sys.indexes and
      sys.columns only, so they carry no freshness caveat and no uptime floor. Appended after 12e
      because the CLWIDE byte test needs #ColumnWidth.
    ------------------------------------------------------------------------------------------------*/
    UPDATE ia
    SET    index_cons = NULLIF(STUFF(CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                CASE WHEN ia.index_cons IS NOT NULL THEN N', ' + ia.index_cons ELSE N'' END,
                CASE WHEN ia.row_kind = 'INDEX' AND ia.index_id = 1 AND ia.is_unique = 0
                     THEN N', CLNU' ELSE N'' END,
                CASE WHEN ia.row_kind = 'INDEX' AND ia.index_id = 1
                          AND (COALESCE(ia.key_column_count, 0) > @WideClusteredMaxKeyColumns
                               OR COALESCE(clw.total_bytes, 0) > @WideClusteredMaxKeyBytes)
                     THEN N', CLWIDE' ELSE N'' END,
                CASE WHEN ia.row_kind = 'INDEX' AND ia.index_id >= 1
                          AND ia.fill_factor BETWEEN 1 AND @LowFillFactorPct
                     THEN N', FILL' + CONVERT(NVARCHAR(3), ia.fill_factor) ELSE N'' END,
                CASE WHEN ia.row_kind = 'INDEX' AND fcg.missing_count > 0
                     THEN N', FILTCOL' + CONVERT(NVARCHAR(10), fcg.missing_count) ELSE N'' END
            ), 1, 2, N''), N'')
    FROM   #IndexAnalysis ia
    LEFT  JOIN #FilterColumnGap fcg ON fcg.object_id = ia.object_id AND fcg.index_id = ia.index_id
    OUTER APPLY (
        SELECT SUM(cw.estimated_bytes) AS total_bytes
        FROM (
            SELECT REPLACE(REPLACE(LTRIM(RTRIM(REPLACE(REPLACE(x.i.value('.','NVARCHAR(400)'), N' DESC', N''), N' ASC', N''))), N'[', N''), N']', N'') AS bare_name
            FROM   (SELECT CAST(N'<i>' + REPLACE(ia.key_columns_display, N',', N'</i><i>') + N'</i>' AS XML) AS x) kx
            CROSS APPLY kx.x.nodes('i') AS x(i)
            WHERE  ia.key_columns_display IS NOT NULL
        ) p
        LEFT JOIN #ColumnWidth cw ON cw.object_id = ia.object_id AND cw.column_name = p.bare_name
    ) clw
    WHERE  ia.row_kind = 'INDEX';

    /*------------------------------------------------------------------------------------------------
      12g. TABLE-LEVEL STRUCTURAL FINDINGS -> row_kind = 'TABLE'. See the script's Section 12g header
      for each token and for why sp_BlitzIndex's include-usage checks (30/31) are deliberately NOT
      here: they GROUP BY database_name, so a per-table version fired on 57 of 65 tables -- noise,
      not a finding. A TABLE row is emitted ONLY when at least one finding fires.
    ------------------------------------------------------------------------------------------------*/
    ;WITH nc AS (
        SELECT object_id,
               COUNT(DISTINCT index_id) AS nc_count
        FROM   #IndexAnalysis
        WHERE  row_kind = 'INDEX' AND index_id > 1
        GROUP  BY object_id
    )
    INSERT #IndexAnalysis
          (row_kind, schema_name, table_name, object_name, object_id, index_id, index_name, type_desc,
           table_row_count, table_column_count, index_action, index_cons)
    SELECT 'TABLE', tm.schema_name, tm.table_name, tm.object_name, tm.object_id, NULL,
           N'<<table>>', N'TABLE',
           tm.table_row_count, tm.table_column_count, '---', f.cons
    FROM   #TableMeta tm
    JOIN   #TableStructure ts ON ts.object_id = tm.object_id
    LEFT  JOIN nc ON nc.object_id = tm.object_id
    CROSS APPLY (SELECT SUM(cw.estimated_bytes) AS nonlob_bytes
                 FROM   #ColumnWidth cw WHERE cw.object_id = tm.object_id) w
    CROSS APPLY (SELECT NULLIF(STUFF(CONCAT(CAST(N'' AS NVARCHAR(MAX)),
            CASE WHEN tm.table_column_count >= @WideTableMaxColumns
                      OR COALESCE(w.nonlob_bytes, 0) >= @WideTableMaxRowBytes THEN N', TBLWIDE' ELSE N'' END,
            CASE WHEN COALESCE(nc.nc_count, 0) >= @ManyNonclusteredIndexes
                 THEN N', NCMANY' + CONVERT(NVARCHAR(10), nc.nc_count) ELSE N'' END,
            CASE WHEN ts.non_nullable_columns <= 1 AND tm.table_column_count > @ColumnMixMinColumns
                 THEN N', NOTNULL' + CONVERT(NVARCHAR(10), ts.non_nullable_columns)
                      + N'of' + CONVERT(NVARCHAR(10), tm.table_column_count) ELSE N'' END,
            CASE WHEN (tm.table_column_count - ts.string_or_lob_columns) <= 1
                      AND tm.table_column_count > @ColumnMixMinColumns
                 THEN N', STRING' + CONVERT(NVARCHAR(10), ts.string_or_lob_columns)
                      + N'of' + CONVERT(NVARCHAR(10), tm.table_column_count) ELSE N'' END,
            CASE WHEN ts.identity_pct_used >= @IdentityRangeUsedPctWarn
                 THEN N', IDENT' + CONVERT(NVARCHAR(10), CONVERT(INT, ts.identity_pct_used)) + N'%' ELSE N'' END,
            CASE WHEN ts.collation_mismatch_columns > 0 THEN N', COLLMIX' ELSE N'' END,
            CASE WHEN ts.replicated_columns > 0
                 THEN N', REPL' + CONVERT(NVARCHAR(10), ts.replicated_columns)
                      + N'of' + CONVERT(NVARCHAR(10), tm.table_column_count) ELSE N'' END,
            CASE WHEN ts.has_cascading_fk = 1 THEN N', FKCASC' ELSE N'' END,
            /*  Tier 3, table-level: index structures Section 4 never collected (rowstore only), so
                the reader is told they exist rather than left to infer absence from silence.     */
            CASE WHEN ts.columnstore_index_count > 0
                 THEN N', CSTORE' + CONVERT(NVARCHAR(10), ts.columnstore_index_count) ELSE N'' END,
            CASE WHEN ts.is_memory_optimized = 1 THEN N', MEMOPT' ELSE N'' END
        ), 1, 2, N''), N'') AS cons) f
    WHERE  f.cons IS NOT NULL;

    /*------------------------------------------------------------------------------------------------
      12h. HYPOTHETICAL INDEXES -> row_kind = 'HYPO'  (Tier 1 increment 3). See the script's Section
      12h header for why this is a fifth row kind rather than an INDEX row with a new verb: a
      hypothetical index has ZERO rows in sys.dm_db_partition_stats so it could never ride
      #IndexMeta, and a distinct kind keeps it structurally out of every INDEX-row aggregate (12g's
      nonclustered count already being one) instead of relying on each future section to filter it.
      Emitted after all analysis, so nothing upstream can join to it.
    ------------------------------------------------------------------------------------------------*/
    INSERT #IndexAnalysis
          (row_kind, schema_name, table_name, object_name, object_id, index_id, index_name, type_desc,
           is_unique, key_columns_display, include_columns_display, filter_definition,
           table_row_count, table_column_count, index_action, index_cons)
    SELECT 'HYPO', tm.schema_name, tm.table_name, tm.object_name, h.object_id, h.index_id,
           h.index_name, h.type_desc, h.is_unique,
           h.key_columns_display, h.include_columns_display, h.filter_definition,
           tm.table_row_count, tm.table_column_count, 'DROP-HYPO', N'HYPO'
    FROM   #HypotheticalIndex h
    JOIN   #TableMeta tm ON tm.object_id = h.object_id;

    /*------------------------------------------------------------------------------------------------
      12i. LOCK-WAIT AND HEAP CONS (Tier 2). LOCKWAIT (their check 11), HEAPFWD (43/44/45/46 -- ONE
      finding, their three size bands being a priority split we do not need since size_mb is on the
      row), HEAPDEL (49), HEAPPK (47). Their check 48 is our existing W$ and is not re-added.
      NO uptime floor, deliberately: the floor exists for DROP-USAGE because ABSENCE is the finding
      there, and a young instance fakes it. Here PRESENCE is the finding, so a short uptime can only
      cause a miss, never a false report. Flags rather than numbers because these are live counters
      and index_cons is compared strictly. See the script's Section 12i header for the full argument.
    ------------------------------------------------------------------------------------------------*/
    UPDATE ia
    SET    index_cons = NULLIF(STUFF(CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                CASE WHEN ia.index_cons IS NOT NULL THEN N', ' + ia.index_cons ELSE N'' END,
                CASE WHEN COALESCE(ia.row_lock_wait_in_ms, 0) + COALESCE(ia.page_lock_wait_in_ms, 0)
                          > @LockWaitTotalMsWarn
                     THEN N', LOCKWAIT' ELSE N'' END,
                CASE WHEN ia.index_id = 0 AND COALESCE(ia.forwarded_fetch_count, 0) >= @HeapForwardedFetchWarn
                     THEN N', HEAPFWD' ELSE N'' END,
                CASE WHEN ia.index_id = 0 AND COALESCE(ia.leaf_delete_count, 0) >= @HeapDeleteWarn
                     THEN N', HEAPDEL' ELSE N'' END,
                CASE WHEN ia.index_id = 0 AND EXISTS (SELECT 1 FROM #IndexAnalysis pk
                                                      WHERE pk.object_id = ia.object_id
                                                        AND pk.row_kind = 'INDEX'
                                                        AND pk.is_primary_key = 1
                                                        AND pk.type_desc LIKE N'%NONCLUSTERED%')
                     THEN N', HEAPPK' ELSE N'' END
            ), 1, 2, N''), N'')
    FROM   #IndexAnalysis ia
    WHERE  ia.row_kind = 'INDEX';

    /*------------------------------------------------------------------------------------------------
      12j. PARTITIONING / STATISTICS SAMPLING / RESUMABLE OPERATIONS (Tier 3). PART<n> (their check
      64), PARTNA (65 -- the table is partitioned, judged by its heap or clustered index, and THIS
      index is not, which is what breaks partition SWITCH), STATSAMP<n> (statistics built from too
      thin a sample), RESUMABLE (a paused ALTER INDEX holding a half-built index). STATSAMP carries
      its number where Tier 2's tokens do not: statistics metadata only moves when statistics are
      rebuilt, which needs writes, so it is stable across a comparison. CSTORE<n> and MEMOPT are the
      table-level half and live in 12g. See the script's Section 12j header.
    ------------------------------------------------------------------------------------------------*/
    UPDATE ia
    SET    index_cons = NULLIF(STUFF(CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                CASE WHEN ia.index_cons IS NOT NULL THEN N', ' + ia.index_cons ELSE N'' END,
                CASE WHEN ia.is_on_partition_scheme = 1
                     THEN N', PART' + CONVERT(NVARCHAR(10), COALESCE(ia.partition_count, 0)) ELSE N'' END,
                CASE WHEN COALESCE(ia.is_on_partition_scheme, 0) = 0
                          AND EXISTS (SELECT 1 FROM #IndexAnalysis par
                                      WHERE par.object_id = ia.object_id
                                        AND par.row_kind = 'INDEX'
                                        AND par.index_id IN (0, 1)
                                        AND par.is_on_partition_scheme = 1)
                     THEN N', PARTNA' ELSE N'' END,
                CASE WHEN ia.stats_sample_pct < @LowStatsSamplePct
                          AND COALESCE(ia.index_row_count, 0) >= @StatsSampleMinRows
                     THEN N', STATSAMP' + CONVERT(NVARCHAR(10), CONVERT(INT, ia.stats_sample_pct)) ELSE N'' END,
                CASE WHEN ia.has_resumable_op = 1 THEN N', RESUMABLE' ELSE N'' END
            ), 1, 2, N''), N'')
    FROM   #IndexAnalysis ia
    WHERE  ia.row_kind = 'INDEX';

    /*------------------------------------------------------------------------------------------------
      13. GENERATED DDL TEXT  (commented out -- for review, never executed by this script)

      Generated statements are single-line and prefixed '-- ' so the whole column value is an inert
      T-SQL line comment. This also keeps the script parseable by dbatools' Invoke-DbaQuery, which
      chokes on '/* */' pairs inside string literals (the reason its sibling PSD script must be run
      through sqlcmd). Nothing here is DDL that runs; a human copies the text, removes '-- ', reviews.
    ------------------------------------------------------------------------------------------------*/
    UPDATE ia
    SET    create_index_sql =
             CASE
                 WHEN ia.index_action IN ('CREATE','BLEND') AND ia.row_kind = 'MISSING' THEN
                      CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                             CASE WHEN ia.index_action = 'BLEND'
                                  THEN N'BLEND into ' + ia.blend_target_index + N': ' ELSE N'' END,
                             N'CREATE INDEX ', gen.name,
                             N' ON ', ia.object_name, N' (',
                             COALESCE(ia.key_columns_display, N''), N')',
                             CASE WHEN ia.missing_include_columns IS NOT NULL
                                  THEN N' INCLUDE (' + ia.missing_include_columns + N')' ELSE N'' END,
                             N';  -- impact ', CONVERT(NVARCHAR(30), ia.missing_impact),
                             CASE WHEN ia.qs_query_ids IS NOT NULL THEN N' ; QS query_id(s): ' + ia.qs_query_ids ELSE N'' END,
                             CASE WHEN ia.dependent_sources IS NOT NULL THEN N' ; dependent(s): ' + ia.dependent_sources ELSE N'' END,
                             /*  Width guard. Section 12e's #ColumnWidth backs both checks below:
                                 column COUNT (@MaxIndexKeyColumns) and, since 2026-09-12, byte WIDTH
                                 (@MaxIndexKeyBytes) -- the engine's own hard limits are 32 key columns
                                 / 1700 bytes for a nonclustered index (900 pre-2016, not modelled).   */
                             CASE WHEN COALESCE(ia.key_column_count, 0) > @MaxIndexKeyColumns
                                  THEN N' ; REVIEW: ' + CONVERT(NVARCHAR(10), ia.key_column_count)
                                       + N' key columns exceeds @MaxIndexKeyColumns ('
                                       + CONVERT(NVARCHAR(10), @MaxIndexKeyColumns)
                                       + N') -- consider moving trailing columns to INCLUDE'
                                  ELSE N'' END,
                             CASE WHEN widthcheck.has_ineligible = 1
                                  THEN N' ; REVIEW: key column ' + widthcheck.ineligible_msg
                                  WHEN widthcheck.total_bytes > @MaxIndexKeyBytes
                                  THEN N' ; REVIEW: estimated ' + CASE WHEN widthcheck.has_variable_length = 1 THEN N'MAXIMUM ' ELSE N'' END
                                       + N'key width ' + CONVERT(NVARCHAR(10), widthcheck.total_bytes) + N' bytes exceeds @MaxIndexKeyBytes ('
                                       + CONVERT(NVARCHAR(10), @MaxIndexKeyBytes) + N')'
                                       + CASE WHEN widthcheck.has_variable_length = 1
                                              THEN N' -- will succeed today only if current data is narrower; a future update widening it will fail -- narrow the declared size or move a variable-length column to INCLUDE'
                                              ELSE N' -- CREATE INDEX will be rejected by the engine as written' END
                                  ELSE N'' END)
                 WHEN ia.row_kind = 'FKGAP' THEN
                      CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                             N'CREATE INDEX ', gen.name,
                             N' ON ', ia.object_name, N' (', ia.key_columns_display, N');  -- supports FK ',
                             REPLACE(REPLACE(ia.index_name, N'<<fk: ', N''), N'>>', N''))
                 WHEN ia.index_action IN ('DROP-DUP','DROP-DUP?','DROP-USAGE','DROP-USAGE?') THEN
                      /*  The reversing CREATE for a drop candidate -- a DROP ships with its own
                          rollback, the same change-control pairing every other action gets. A
                          PRIMARY KEY / UNIQUE CONSTRAINT is not a scriptable CREATE INDEX (it is
                          ALTER TABLE ... ADD CONSTRAINT); a non-B-tree type (XML / SPATIAL /
                          COLUMNSTORE) is not reliably reconstructable from these columns either --
                          both name what to do instead. Otherwise: CLUSTERED/NONCLUSTERED read off
                          ia.type_desc, UNIQUE off ia.is_unique (a plain unique index, NOT a
                          constraint), key/include/filter off the catalog columns already collected.
                          NOT captured, named in the comment: fill factor, DATA_COMPRESSION,
                          PAD_INDEX, lock and sequential-key options, filegroup / partition
                          placement -- same caveat ComparePlans' own reconstruction carries.        */
                      CASE
                          WHEN ia.is_primary_key = 1 OR ia.is_unique_constraint = 1 THEN
                               CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                                      N'ROLLBACK:  re-add ', QUOTENAME(ia.index_name),
                                      N' from the live definition -- a PRIMARY KEY / UNIQUE constraint is ALTER TABLE, not CREATE INDEX.')
                          WHEN ia.type_desc NOT IN (N'CLUSTERED', N'NONCLUSTERED', N'UNIQUE CLUSTERED', N'UNIQUE NONCLUSTERED')
                               OR ia.key_columns_display IS NULL THEN
                               CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                                      N'ROLLBACK:  recreate ', QUOTENAME(ia.index_name), N' (', COALESCE(ia.type_desc, N'index'),
                                      N') from the live definition -- not scripted (reconstruction is unreliable for this index type).')
                          ELSE
                               CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                                      N'ROLLBACK:  CREATE ',
                                      CASE WHEN ia.is_unique = 1 THEN N'UNIQUE ' ELSE N'' END,
                                      CASE WHEN ia.type_desc LIKE N'%NONCLUSTERED%' THEN N'NONCLUSTERED' ELSE N'CLUSTERED' END,
                                      N' INDEX ', QUOTENAME(ia.index_name), N' ON ', ia.object_name,
                                      N' (', ia.key_columns_display, N')',
                                      CASE WHEN ia.include_columns_display IS NOT NULL
                                           THEN N' INCLUDE (' + ia.include_columns_display + N')' ELSE N'' END,
                                      CASE WHEN ia.filter_definition IS NOT NULL
                                           THEN N' WHERE ' + ia.filter_definition ELSE N'' END,
                                      N';  -- key columns, sort direction, INCLUDE and filter are from the catalog grid; fill factor, '
                                    + N'data compression, PAD_INDEX, lock and sequential-key options, and filegroup / '
                                    + N'partition placement are NOT -- diff against the live index before running.')
                      END
                 /*  FILTCOL: the widened rebuild that closes a filtered index's filter-column gap.
                     AFTER the drop branch on purpose -- a drop candidate's reversing CREATE wins.
                     DROP_EXISTING = ON is correct here and only here: the index already exists.  */
                 WHEN fcg.missing_count > 0 AND ia.key_columns_display IS NOT NULL THEN
                      CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                             N'CREATE ',
                             CASE WHEN ia.is_unique = 1 THEN N'UNIQUE ' ELSE N'' END,
                             CASE WHEN ia.type_desc LIKE N'%NONCLUSTERED%' THEN N'NONCLUSTERED' ELSE N'CLUSTERED' END,
                             N' INDEX ', QUOTENAME(ia.index_name), N' ON ', ia.object_name,
                             N' (', ia.key_columns_display, N')',
                             N' INCLUDE (',
                             CASE WHEN ia.include_columns_display IS NOT NULL
                                  THEN ia.include_columns_display + N', ' ELSE N'' END,
                             fcg.missing_columns, N')',
                             CASE WHEN ia.filter_definition IS NOT NULL
                                  THEN N' WHERE ' + ia.filter_definition ELSE N'' END,
                             N' WITH (DROP_EXISTING = ON);',
                             N'  -- adds ', fcg.missing_columns,
                             N', named by this index''s own filter but absent from it. Until then the '
                           + N'optimizer has to re-check the filter against the base table. Fill factor, '
                           + N'compression and filegroup are NOT carried over -- diff against the live index first.')
                 ELSE NULL
             END,
           drop_index_sql =
             CASE
                 WHEN ia.index_action IN ('CREATE','BLEND') AND ia.row_kind = 'MISSING' THEN
                      /*  The reversing DROP for a missing-index proposal -- a CREATE ships with
                          its own rollback, same as a DROP action ships with its reversing CREATE
                          above. gen.name is computed once (in the CROSS APPLY below) and shared
                          with create_index_sql, so the two can never name different indexes.    */
                      CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                             N'ROLLBACK:  DROP INDEX ', gen.name, N' ON ', ia.object_name,
                             N';  -- undoes the CREATE above, if applied.')
                 WHEN ia.row_kind = 'FKGAP' THEN
                      CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                             N'ROLLBACK:  DROP INDEX ', gen.name, N' ON ', ia.object_name,
                             N';  -- undoes the CREATE above, if applied.')
                 WHEN ia.index_action IN ('DROP-DUP','DROP-DUP?','DROP-USAGE','DROP-USAGE?') THEN
                      CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                             N'DROP INDEX ', QUOTENAME(ia.index_name), N' ON ', ia.object_name, N';',
                             CASE WHEN ia.index_action LIKE '%?'
                                  THEN N'  -- CAUTION: Query Store shows ' + CONVERT(NVARCHAR(10), ia.qs_drop_risk_query_ct)
                                       + N' query(ies) still using this index in the last '
                                       + CONVERT(NVARCHAR(10), @LookbackDays) + N' days: ' + COALESCE(ia.qs_query_ids, N'')
                                  ELSE N'' END,
                             /*  Section 9b: the caution Query Store alone cannot raise -- objects that
                                 reference this table with no plan anywhere. Empty unless
                                 @IncludeDependentObjects = 1 and at least one such dependent exists.  */
                             CASE WHEN dep.unverified_ct > 0
                                  THEN N'  -- CAUTION: ' + CONVERT(NVARCHAR(10), dep.unverified_ct)
                                       + N' dependent object(s) reference this table with no plan-cache or Query Store evidence in the last '
                                       + CONVERT(NVARCHAR(10), @LookbackDays) + N' days: ' + dep.unverified_list
                                       + N' -- verify before dropping'
                                  ELSE N'' END)
                 WHEN ia.index_action = 'DROP-HYPO' THEN
                      /*  Section 12h. No Query Store or dependent caution: a hypothetical index has
                          no data and cannot appear in any plan, so nothing can be reading it.     */
                      CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                             N'DROP INDEX ', QUOTENAME(ia.index_name), N' ON ', ia.object_name, N';',
                             N'  -- hypothetical index: a Database Engine Tuning Advisor leftover. It has '
                           + N'no data and no storage and can never be used by a plan. No rollback is '
                           + N'offered because there is nothing to restore.')
                 WHEN ia.index_action = 'ENABLE' THEN
                      CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                             N'ALTER INDEX ', QUOTENAME(ia.index_name), N' ON ', ia.object_name, N' REBUILD;')
                 WHEN ia.index_action = 'SEQKEY' THEN
                      CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                             N'ALTER INDEX ', QUOTENAME(ia.index_name), N' ON ', ia.object_name,
                             N' SET (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON);')
                 ELSE NULL
             END,
           compression_sql =
             CASE WHEN ia.recommended_compression = N'PAGE' THEN
                  CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)),
                         CASE WHEN ia.is_heap = 1 AND ia.index_id = 0
                              THEN N'ALTER TABLE ' + ia.object_name + N' REBUILD WITH (DATA_COMPRESSION = PAGE);'
                              ELSE N'ALTER INDEX ' + QUOTENAME(ia.index_name) + N' ON ' + ia.object_name
                                   + N' REBUILD WITH (DATA_COMPRESSION = PAGE);' END,
                         N'  -- ', ia.compression_reason)
                  ELSE NULL
             END
    FROM   #IndexAnalysis ia
    LEFT  JOIN #FilterColumnGap fcg ON fcg.object_id = ia.object_id AND fcg.index_id = ia.index_id
                                   AND ia.row_kind = 'INDEX'
    CROSS APPLY (SELECT
                    CASE
                        WHEN ia.index_action IN ('CREATE','BLEND') AND ia.row_kind = 'MISSING' THEN
                             /*  All key columns (equality + inequality), falling back to the
                                 include set, then a literal. A CHECKSUM suffix over the full
                                 key|include text disambiguates same-key suggestions that differ
                                 only in their INCLUDE list (three ProductID-keyed misses on one
                                 table, e.g.). Computed ONCE here so create_index_sql and
                                 drop_index_sql can never name different indexes for the same row. */
                             QUOTENAME(LEFT(@GeneratedIndexNamePrefix
                                + ia.table_name + N'_'
                                + REPLACE(REPLACE(REPLACE(REPLACE(
                                      COALESCE(NULLIF(ia.key_columns_display, N''),
                                               NULLIF(ia.missing_include_columns, N''), N'idx'),
                                      N'[',N''), N']',N''), N', ', N'_'), N' ', N'')
                                + N'_' + CONVERT(NVARCHAR(10),
                                      ABS(CHECKSUM(CONCAT(CAST(N'' AS NVARCHAR(MAX)),
                                          ia.key_columns_display, N'|', ISNULL(ia.missing_include_columns, N'')))) % 100000),
                                120))
                        WHEN ia.row_kind = 'FKGAP' THEN
                             QUOTENAME(LEFT(@GeneratedIndexNamePrefix + ia.table_name + N'_FK_'
                                + REPLACE(REPLACE(REPLACE(REPLACE(ia.key_columns_display, N'[',N''),N']',N''),N', ',N'_'),N' ',N''), 120))
                        ELSE NULL
                    END AS name) gen
    CROSS APPLY (
        /*  Section 12e's #ColumnWidth summed over this row's own key_columns_display -- same
            bracket/DESC-stripping split idiom as the REALIGN CTEs below, kept local here (no shared
            temp table) since this is the only place a MISSING/BLEND row's DMV-verbatim key needs it. */
        SELECT SUM(cw.estimated_bytes)                                                AS total_bytes,
               MAX(CASE WHEN cw.ineligible_reason IS NOT NULL THEN 1 ELSE 0 END)       AS has_ineligible,
               MIN(CASE WHEN cw.ineligible_reason IS NOT NULL
                        THEN QUOTENAME(p.bare_name) + N' ' + cw.ineligible_reason END) AS ineligible_msg,
               MAX(cw.is_variable_length)                                             AS has_variable_length
        FROM (
            SELECT REPLACE(REPLACE(LTRIM(RTRIM(REPLACE(REPLACE(x.i.value('.','NVARCHAR(400)'), N' DESC', N''), N' ASC', N''))), N'[', N''), N']', N'') AS bare_name
            FROM   (SELECT CAST(N'<i>' + REPLACE(ia.key_columns_display, N',', N'</i><i>') + N'</i>' AS XML) AS x) kx
            CROSS APPLY kx.x.nodes('i') AS x(i)
            WHERE  ia.key_columns_display IS NOT NULL
        ) p
        LEFT JOIN #ColumnWidth cw ON cw.object_id = ia.object_id AND cw.column_name = p.bare_name
    ) widthcheck
    CROSS APPLY (
        /*  Section 9b dependents of this row's table with no plan evidence. An aggregate, so always
            exactly one row (0 / NULL when there are none, and #DependentObject is simply empty when
            @IncludeDependentObjects = 0) -- never filters the UPDATE.                                */
        SELECT COUNT(*) AS unverified_ct,
               STUFF((SELECT N', ' + QUOTENAME(u2.dependent_schema) + N'.' + QUOTENAME(u2.dependent_name)
                      FROM   #DependentObject u2
                      WHERE  u2.referenced_object_id = ia.object_id AND u2.evidence_source = 'NONE'
                      ORDER  BY u2.dependent_schema, u2.dependent_name
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS unverified_list
        FROM   #DependentObject u
        WHERE  u.referenced_object_id = ia.object_id AND u.evidence_source = 'NONE'
    ) dep;

    /*------------------------------------------------------------------------------------------------
      13b. REALIGNED CREATE INDEX for a MISSING / BLEND row  (Curtis, 2026-09-10: "the DESC wasn't
      included in the CREATE statement ... add it as a second column")

      create_index_sql above mirrors the missing-index DMV's own suggestion verbatim: equality +
      inequality columns are the KEY, everything else -- including missing_order_by_cols /
      missing_group_by_cols -- lands in INCLUDE. INCLUDE columns carry no sort direction in T-SQL at
      all, so a sort/group column the DMV only ever puts in INCLUDE can never show ASC/DESC there --
      not a bug, a structural limit of that key shape. realigned_create_index_sql is a SECOND
      suggestion for the same proposal: key = equality columns, then missing_group_by_cols, then
      missing_order_by_cols (a column in both takes the ORDER BY's direction; ORDER BY is always the
      trailing key column, so the query's own Sort / Hash Aggregate goes away too), INCLUDE = whatever
      is left of missing_include_columns + inequality_columns (a range predicate can't share the key
      with ORDER BY without forcing the Sort back). Ported from ComparePlans' _fpoc_realign_index,
      which has run this exact algorithm since 2026-09-07 -- this is the SQL-native version, so the
      fact no longer needs ComparePlans to surface it.

      SIMPLIFICATION, disclosed rather than silent: unlike ComparePlans' rendering, this does NOT trim
      a trailing key column that is already a leading prefix of the table's clustered key (the row
      locator a nonclustered index carries implicitly). Skipping that trim can leave one redundant,
      but never WRONG, explicit key column. NULL when there is nothing to realign: no GROUP BY / ORDER
      BY on this proposal, or the realigned key would come out identical to the DMV's own key.
    ------------------------------------------------------------------------------------------------*/
    IF OBJECT_ID('tempdb..#Realign') IS NOT NULL DROP TABLE #Realign;
    CREATE TABLE #Realign (analysis_id INT NOT NULL, realign_sql NVARCHAR(MAX) NULL);

    ;WITH KeySrc AS (
        -- F -> P -> O, each column split from its comma list with its ORIGINAL order preserved (the
        -- standard XML-node string-split idiom -- compat-100 safe, no STRING_SPLIT/ordinal needed).
        -- src bands the three sources (1=equality, 2=GROUP BY, 3=ORDER BY) so a UNION-wide position
        -- number (src*100000 + within-list ordinal) orders the key once grouped below. A column
        -- present in BOTH GROUP BY and ORDER BY takes its ORDER BY occurrence's POSITION, not its
        -- GROUP BY one (KeyCols' keypos prefers src=3) -- "ORDER BY is always the trailing key
        -- column" means the ORDER BY clause's own column sequence decides where shared columns land
        -- among themselves, not missing_group_by_cols' (arbitrary) sequence. Direction is taken from
        -- src=3 the same way, unchanged. Bug fixed 2026-09-11 (Curtis, reproduced on a Managed
        -- Instance): keypos previously used MIN() across all sources, which let a shared column's
        -- GROUP BY-banded position win even when its ORDER BY position should have -- e.g. "GROUP BY
        -- UnitPrice, ModifiedDate ORDER BY UnitPrice, ModifiedDate" realigned to (ModifiedDate,
        -- UnitPrice), backwards from what the query's own ORDER BY needs, because
        -- missing_group_by_cols happened to list them alphabetically.
        SELECT ia.analysis_id, ia.object_name, ia.key_columns_display, p.src, p.ord, p.bare_name, p.dir
        FROM   #IndexAnalysis ia
        CROSS APPLY (
            SELECT 1 AS src, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS ord,
                   REPLACE(REPLACE(LTRIM(RTRIM(REPLACE(REPLACE(e.i.value('.','NVARCHAR(400)'), N' DESC', N''), N' ASC', N''))), N'[', N''), N']', N'') AS bare_name,
                   CASE WHEN e.i.value('.','NVARCHAR(400)') LIKE N'% DESC' THEN N' DESC' ELSE N'' END AS dir
            FROM   (SELECT CAST(N'<i>' + REPLACE(ia.equality_columns, N',', N'</i><i>') + N'</i>' AS XML) AS x) ex
   CROSS APPLY ex.x.nodes('i') AS e(i)
            WHERE  ia.equality_columns IS NOT NULL
            UNION ALL
            SELECT 2, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
                   REPLACE(REPLACE(LTRIM(RTRIM(REPLACE(REPLACE(g.i.value('.','NVARCHAR(400)'), N' DESC', N''), N' ASC', N''))), N'[', N''), N']', N''),
                   CASE WHEN g.i.value('.','NVARCHAR(400)') LIKE N'% DESC' THEN N' DESC' ELSE N'' END
            FROM   (SELECT CAST(N'<i>' + REPLACE(ia.missing_group_by_cols, N',', N'</i><i>') + N'</i>' AS XML) AS x) gx
   CROSS APPLY gx.x.nodes('i') AS g(i)
            WHERE  ia.missing_group_by_cols IS NOT NULL
            UNION ALL
            SELECT 3, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
                   REPLACE(REPLACE(LTRIM(RTRIM(REPLACE(REPLACE(o.i.value('.','NVARCHAR(400)'), N' DESC', N''), N' ASC', N''))), N'[', N''), N']', N''),
                   CASE WHEN o.i.value('.','NVARCHAR(400)') LIKE N'% DESC' THEN N' DESC' ELSE N'' END
            FROM   (SELECT CAST(N'<i>' + REPLACE(ia.missing_order_by_cols, N',', N'</i><i>') + N'</i>' AS XML) AS x) ox
   CROSS APPLY ox.x.nodes('i') AS o(i)
            WHERE  ia.missing_order_by_cols IS NOT NULL
        ) p
        WHERE  ia.row_kind = 'MISSING' AND ia.index_action IN ('CREATE','BLEND')
          AND (ia.missing_group_by_cols IS NOT NULL OR ia.missing_order_by_cols IS NOT NULL)
    ),
    KeyCols AS (
        SELECT analysis_id, object_name, key_columns_display, bare_name,
               COALESCE(MAX(CASE WHEN src = 3 THEN src * 100000 + ord END), MIN(src * 100000 + ord)) AS keypos,
               ISNULL(MAX(CASE WHEN src = 3 THEN dir END), N'') AS dir
        FROM   KeySrc
        GROUP  BY analysis_id, object_name, key_columns_display, bare_name
    ),
    IncSrc AS (
        -- C (+ demoted range/inequality cols) -- same split idiom, no direction (INCLUDE has none).
        SELECT ia.analysis_id, p.src, p.ord, p.bare_name
        FROM   #IndexAnalysis ia
        CROSS APPLY (
            SELECT 1 AS src, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS ord,
                   REPLACE(REPLACE(LTRIM(RTRIM(REPLACE(REPLACE(m.i.value('.','NVARCHAR(400)'), N' DESC', N''), N' ASC', N''))), N'[', N''), N']', N'') AS bare_name
            FROM   (SELECT CAST(N'<i>' + REPLACE(ia.missing_include_columns, N',', N'</i><i>') + N'</i>' AS XML) AS x) mx
   CROSS APPLY mx.x.nodes('i') AS m(i)
            WHERE  ia.missing_include_columns IS NOT NULL
            UNION ALL
            SELECT 2, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
                   REPLACE(REPLACE(LTRIM(RTRIM(REPLACE(REPLACE(q.i.value('.','NVARCHAR(400)'), N' DESC', N''), N' ASC', N''))), N'[', N''), N']', N'')
            FROM   (SELECT CAST(N'<i>' + REPLACE(ia.inequality_columns, N',', N'</i><i>') + N'</i>' AS XML) AS x) qx
   CROSS APPLY qx.x.nodes('i') AS q(i)
            WHERE  ia.inequality_columns IS NOT NULL
        ) p
        WHERE  ia.row_kind = 'MISSING' AND ia.index_action IN ('CREATE','BLEND')
          AND (ia.missing_group_by_cols IS NOT NULL OR ia.missing_order_by_cols IS NOT NULL)
    ),
    IncCols AS (
        SELECT analysis_id, bare_name, MIN(src * 100000 + ord) AS incpos
        FROM   IncSrc
        GROUP  BY analysis_id, bare_name
    )
    INSERT #Realign (analysis_id, realign_sql)
    SELECT k.analysis_id,
           CONCAT(CAST(N'-- ' AS NVARCHAR(MAX)), N'REALIGN -- CREATE INDEX ',
                  /*  Name derived from the REALIGNED key/include text itself (same CHECKSUM-suffix
                      technique the base gen.name uses above) -- NOT from k.analysis_id, an IDENTITY
                      value that is NOT guaranteed to land on the same number in the script's own
                      #IndexAnalysis and the procedure's, even for the identical underlying proposal.
                      Data-derived means script and procedure always compute the SAME name.          */
                  QUOTENAME(LEFT(N'IX_realigned_'
                     + REPLACE(REPLACE(REPLACE(REPLACE(keylist.key_text, N'[',N''), N']',N''), N', ',N'_'), N' ',N'')
                     + N'_' + CONVERT(NVARCHAR(10),
                           ABS(CHECKSUM(CONCAT(CAST(N'' AS NVARCHAR(MAX)), keylist.key_text, N'|', ISNULL(inclist.inc_text, N'')))) % 100000),
                     120)),
                  N' ON ', k.object_name, N' (', keylist.key_text, N')',
                  CASE WHEN inclist.inc_text IS NOT NULL THEN N' INCLUDE (' + inclist.inc_text + N')' ELSE N'' END,
                  N';  -- key ordered equality/filter -> GROUP BY -> ORDER BY (last) so the query''s Sort / ',
                  N'Hash Aggregate is removed, not just the lookup; range / inequality cols stay in INCLUDE ',
                  N'(can''t share the key with ORDER BY without a Sort). Clustered-key trailing columns are ',
                  N'NOT trimmed here (unlike ComparePlans'' rendering) -- diff against the live index first.',
                  /*  Same @MaxIndexKeyBytes guard as Section 13a's create_index_sql (2026-09-12), applied
                      to the REALIGNED key instead of the DMV's verbatim one -- reordering columns doesn't
                      change their summed width, but it's a different key list and deserves its own check
                      rather than assuming 13a's already covered it.                                     */
                  CASE WHEN widthcheck.has_ineligible = 1
                       THEN N' ; REVIEW: key column ' + widthcheck.ineligible_msg
                       WHEN widthcheck.total_bytes > @MaxIndexKeyBytes
                       THEN N' ; REVIEW: estimated ' + CASE WHEN widthcheck.has_variable_length = 1 THEN N'MAXIMUM ' ELSE N'' END
                            + N'key width ' + CONVERT(NVARCHAR(10), widthcheck.total_bytes) + N' bytes exceeds @MaxIndexKeyBytes ('
                            + CONVERT(NVARCHAR(10), @MaxIndexKeyBytes) + N')'
                            + CASE WHEN widthcheck.has_variable_length = 1
                                   THEN N' -- will succeed today only if current data is narrower; a future update widening it will fail -- narrow the declared size or move a variable-length column to INCLUDE'
                                   ELSE N' -- CREATE INDEX will be rejected by the engine as written' END
                       ELSE N'' END)
    FROM (SELECT DISTINCT analysis_id, object_name, key_columns_display FROM KeyCols) k
    CROSS APPLY (
        SELECT STUFF((SELECT N', ' + QUOTENAME(kc.bare_name) + kc.dir
                      FROM KeyCols kc WHERE kc.analysis_id = k.analysis_id
                      ORDER BY kc.keypos
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') AS key_text
    ) keylist
    CROSS APPLY (
        SELECT NULLIF(STUFF((SELECT N', ' + QUOTENAME(ic.bare_name)
                      FROM IncCols ic
                      WHERE ic.analysis_id = k.analysis_id
                        AND ic.bare_name NOT IN (SELECT kc2.bare_name FROM KeyCols kc2 WHERE kc2.analysis_id = k.analysis_id)
                      ORDER BY ic.incpos
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'') AS inc_text
    ) inclist
    CROSS APPLY (
        SELECT SUM(cw.estimated_bytes)                                                  AS total_bytes,
               MAX(CASE WHEN cw.ineligible_reason IS NOT NULL THEN 1 ELSE 0 END)         AS has_ineligible,
               MIN(CASE WHEN cw.ineligible_reason IS NOT NULL
                        THEN QUOTENAME(kc3.bare_name) + N' ' + cw.ineligible_reason END) AS ineligible_msg,
               MAX(cw.is_variable_length)                                               AS has_variable_length
        FROM   KeyCols kc3
        JOIN   #IndexAnalysis iax ON iax.analysis_id = kc3.analysis_id      /* the row's stored object_id, never OBJECT_ID(name) */
        LEFT JOIN #ColumnWidth cw ON cw.object_id = iax.object_id AND cw.column_name = kc3.bare_name
        WHERE  kc3.analysis_id = k.analysis_id
    ) widthcheck
    WHERE keylist.key_text IS NOT NULL
      AND keylist.key_text <> COALESCE(k.key_columns_display, N'');

    UPDATE ia
    SET    realigned_create_index_sql = r.realign_sql
    FROM   #IndexAnalysis ia
    JOIN   #Realign r ON r.analysis_id = ia.analysis_id;

    DROP TABLE #Realign;

        /*====================================================================================
          ACCUMULATE this database's rows. #Results mirrors #IndexAnalysis (positional -- the
          SELECT ... INTO that created it fixed the column order), with DatabaseName prepended,
          a plain-INT SourceAnalysisId, and match_method resolved here while #QsMissingBridge is
          still live.
        ====================================================================================*/
        INSERT #Results
        SELECT
            @LoopDb,
            ia.row_kind, ia.schema_name, ia.table_name, ia.object_name, ia.object_id, ia.index_id,
            ia.index_name, ia.type_desc, ia.partition_number, ia.is_primary_key, ia.is_unique,
            ia.is_disabled, ia.is_heap, ia.has_filter, ia.filter_definition, ia.filegroup_name,
            ia.data_compression_desc, ia.table_row_count, ia.index_row_count, ia.size_mb, ia.buffered_mb,
            ia.table_buffered_mb, ia.pct_in_buffer, ia.key_column_count, ia.include_column_count,
            ia.table_column_count, ia.key_columns_display, ia.include_columns_display, ia.key_signature,
            ia.include_signature, ia.distinct_key_signature, ia.user_seeks, ia.user_scans,
            ia.user_lookups, ia.user_updates, ia.user_total, ia.reads_per_write, ia.user_total_pct,
            ia.last_user_read, ia.row_lock_wait_in_ms, ia.page_latch_wait_count, ia.page_latch_wait_in_ms,
            ia.leaf_allocation_count, ia.page_compression_success_rate,
            ia.ops_scan_pct, ia.ops_update_pct, ia.ops_insert_pct, ia.recommended_compression, ia.compression_reason,
            ia.missing_impact,
            ia.missing_unique_compiles, ia.equality_columns, ia.inequality_columns,
            ia.missing_include_columns, ia.missing_order_by_cols, ia.missing_group_by_cols,
            ia.missing_window_kind, ia.proposal_source, ia.dependent_sources,
            ia.dependency_kind, ia.evidence_source, ia.last_evidence_time,
            ia.fk_column_count, ia.duplicate_of, ia.overlaps_with,
            ia.sibling_of, ia.blend_target_index, ia.qs_query_ids, ia.qs_executions,
            ia.qs_avg_duration_ms, ia.qs_total_duration_ms, ia.qs_avg_cpu_ms, ia.qs_table_weight,
            ia.qs_drop_risk_query_ct, ia.rank_source, ia.table_rank, ia.index_action, ia.index_pros,
            ia.index_cons, ia.create_index_sql, ia.drop_index_sql, ia.realigned_create_index_sql, ia.compression_sql,
            ia.analysis_id,
            (SELECT TOP (1) qb.match_method
             FROM #QsMissingBridge qb
             WHERE qb.missing_index_id = TRY_CONVERT(INT, REPLACE(REPLACE(ia.index_name, N'<<missing #', N''), N'>>', N'')))
        FROM #IndexAnalysis ia;

        INSERT #DropRiskResults
              (DatabaseName, object_name, index_name, index_action, query_id, access_op,
               executions, total_duration_ms, avg_duration_ms)
        SELECT @LoopDb, ia.object_name, ia.index_name, ia.index_action,
               u.query_id, u.access_op, u.executions, u.total_duration_ms, u.avg_duration_ms
        FROM   #IndexAnalysis ia
        JOIN   #QsIndexUsage u ON u.object_id = ia.object_id AND u.index_id = ia.index_id
        WHERE  ia.row_kind = 'INDEX'
          AND  ia.index_action IN ('DROP-DUP','DROP-DUP?','DROP-USAGE','DROP-USAGE?');

        IF @Debug = 1
        BEGIN
            SELECT @Rows = COUNT(*) FROM #IndexAnalysis;
            RAISERROR('%s: %d analysis row(s)', 0, 0, @LoopDb, @Rows) WITH NOWAIT;
        END;

        SET @LoopDb = (SELECT MIN(DatabaseName) FROM #DatabaseList WHERE DatabaseName > @LoopDb);
    END;   -- per-database loop

    /*==============================================================================================
      OUTPUT. Same six shapes as the script's Section 14, reading #Results and prepending
      DatabaseName. Ordering matches the script exactly except DatabaseName is inserted as the
      second sort key (right after the table-weight key) -- for a single-database run that column
      is constant, so row order is identical and the equivalence test holds; across databases the
      worst-weighted candidate on the instance still sorts first, then by database name.
    ==============================================================================================*/
    IF @Output = 'DUMP'
    BEGIN
        SELECT
            r.DatabaseName,
            r.row_kind, r.index_action, r.index_pros, r.index_cons, r.schema_name, r.table_name,
            r.object_name, r.index_id, r.index_name, r.type_desc, r.partition_number, r.is_primary_key,
            r.is_unique, r.is_disabled, r.is_heap, r.has_filter, r.filter_definition, r.filegroup_name,
            r.data_compression_desc, r.table_row_count, r.index_row_count, r.size_mb, r.buffered_mb,
            r.table_buffered_mb, r.pct_in_buffer, r.key_column_count, r.include_column_count,
            r.table_column_count, r.key_columns_display, r.include_columns_display, r.user_seeks,
            r.user_scans, r.user_lookups, r.user_updates, r.user_total, r.reads_per_write,
            r.user_total_pct, r.last_user_read, r.row_lock_wait_in_ms, r.page_latch_wait_count,
            r.page_latch_wait_in_ms, r.leaf_allocation_count, r.page_compression_success_rate,
            r.ops_scan_pct, r.ops_update_pct, r.ops_insert_pct, r.recommended_compression, r.compression_reason,
            r.missing_impact, r.missing_unique_compiles, r.equality_columns, r.inequality_columns,
            r.missing_include_columns, r.missing_order_by_cols, r.missing_group_by_cols,
            r.missing_window_kind,
            r.proposal_source,
            r.dependent_sources,
            r.dependency_kind, r.evidence_source, r.last_evidence_time,
            r.fk_column_count, r.duplicate_of, r.overlaps_with, r.sibling_of,
            r.blend_target_index, r.rank_source, r.table_rank, r.qs_query_ids, r.qs_executions,
            r.qs_avg_duration_ms, r.qs_total_duration_ms, r.qs_avg_cpu_ms, r.qs_table_weight,
            r.qs_drop_risk_query_ct, r.create_index_sql, r.drop_index_sql, r.realigned_create_index_sql, r.compression_sql
        FROM #Results r
        ORDER BY COALESCE(r.qs_table_weight, r.table_buffered_mb, 0) DESC,
                 r.DatabaseName,
                 r.object_id,
                 COALESCE(r.table_rank, 2147483647),
                 r.row_kind,
                 COALESCE(r.index_id, 2147483647),
                 r.SourceAnalysisId;
    END;
    ELSE IF @Output = 'DETAILED'
    BEGIN
        SELECT
            r.DatabaseName,
            r.index_action, r.index_pros, r.index_cons, r.object_name, r.index_name, r.type_desc,
            r.key_columns_display, r.include_columns_display, r.filter_definition, r.is_primary_key,
            r.is_unique, r.is_disabled, r.size_mb, r.buffered_mb, r.pct_in_buffer, r.index_row_count,
            r.user_seeks, r.user_scans, r.user_lookups, r.user_updates, r.reads_per_write,
            r.user_total_pct, r.rank_source, r.table_rank, r.missing_impact, r.qs_executions,
            r.qs_avg_duration_ms, r.qs_drop_risk_query_ct, r.qs_query_ids, r.duplicate_of,
            r.overlaps_with,
            r.equality_columns, r.inequality_columns, r.missing_order_by_cols, r.missing_group_by_cols,
            r.missing_window_kind,
            r.proposal_source,
            r.dependent_sources,
            r.dependency_kind, r.evidence_source, r.last_evidence_time,
            r.ops_scan_pct, r.ops_update_pct, r.recommended_compression, r.compression_reason,
            r.create_index_sql, r.drop_index_sql, r.realigned_create_index_sql, r.compression_sql
        FROM #Results r
        WHERE r.row_kind <> 'INDEX'
           OR r.index_action <> '---'
           OR r.index_pros IS NOT NULL
           OR r.index_cons IS NOT NULL
           OR r.index_id IS NOT NULL
           OR r.recommended_compression IS NOT NULL
        ORDER BY COALESCE(r.qs_table_weight, r.table_buffered_mb, 0) DESC,
                 r.DatabaseName,
                 r.object_id,
                 COALESCE(r.table_rank, 2147483647),
                 r.row_kind,
                 COALESCE(r.index_id, 2147483647),
                 r.SourceAnalysisId;
    END;
    ELSE IF @Output = 'DUPLICATE'
    BEGIN
        SELECT
            r.DatabaseName,
            DENSE_RANK() OVER (ORDER BY r.DatabaseName, r.object_id, r.key_signature, r.include_signature) AS duplicate_group,
            r.index_action, r.object_name, r.index_name, r.type_desc, r.key_columns_display,
            r.include_columns_display, r.is_primary_key, r.is_unique, r.duplicate_of, r.size_mb,
            r.index_row_count, r.user_total, r.user_updates, r.qs_drop_risk_query_ct, r.drop_index_sql
        FROM #Results r
        WHERE r.row_kind = 'INDEX' AND r.duplicate_of IS NOT NULL
        ORDER BY r.DatabaseName, r.object_id, r.key_signature, r.include_signature, r.index_id, r.SourceAnalysisId;
    END;
    ELSE IF @Output = 'OVERLAPPING'
    BEGIN
        SELECT
            r.DatabaseName,
            r.index_action, r.object_name, r.index_name, r.overlaps_with, r.type_desc,
            r.key_columns_display, r.include_columns_display, r.is_primary_key, r.is_unique, r.size_mb,
            r.index_row_count, r.user_total, r.user_updates, r.qs_drop_risk_query_ct
        FROM #Results r
        WHERE r.row_kind = 'INDEX' AND r.overlaps_with IS NOT NULL
        ORDER BY r.DatabaseName, r.object_id, r.key_signature, r.index_id, r.SourceAnalysisId;
    END;
    ELSE IF @Output = 'REALIGN'
    BEGIN
        SELECT
            r.DatabaseName,
            r.index_action, r.object_name, r.index_name, r.type_desc, r.index_pros, r.index_cons,
            r.index_row_count, r.user_seeks, r.user_scans, r.user_lookups, r.user_updates,
            r.user_total_pct, r.size_mb, r.buffered_mb, r.key_columns_display, r.include_columns_display
        FROM #Results r
        WHERE EXISTS (SELECT 1 FROM #Results x
                      WHERE x.DatabaseName = r.DatabaseName AND x.object_id = r.object_id
                        AND x.index_action = 'REALIGN')
        ORDER BY r.DatabaseName, r.object_id, COALESCE(r.index_id, 2147483647), r.SourceAnalysisId;
    END;
    ELSE IF @Output = 'COMPRESSION'
    BEGIN
        SELECT
            r.DatabaseName,
            r.object_name,
            r.index_name,
            r.type_desc,
            r.is_heap,
            r.data_compression_desc,
            r.index_row_count,
            r.size_mb,
            r.user_updates,
            r.ops_scan_pct,
            r.ops_update_pct,
            r.ops_insert_pct,
            r.recommended_compression,
            r.compression_reason,
            r.compression_sql
        FROM #Results r
        WHERE r.row_kind = 'INDEX' AND r.recommended_compression IS NOT NULL
        ORDER BY COALESCE(r.qs_table_weight, r.table_buffered_mb, 0) DESC,
                 r.DatabaseName, r.object_id, COALESCE(r.index_id, 2147483647), r.SourceAnalysisId;
    END;
    ELSE IF @Output = 'MISSING'
    BEGIN
        SELECT
            r.DatabaseName,
            r.object_name,
            r.index_name          AS missing_index_label,
            r.index_action,
            r.missing_impact,
            r.missing_unique_compiles,
            r.equality_columns,
            r.inequality_columns,
            r.missing_include_columns,
            r.missing_order_by_cols,
            r.missing_group_by_cols,
            r.missing_window_kind,
            r.proposal_source,
            r.dependent_sources,
            r.blend_target_index,
            r.qs_executions,
            r.qs_avg_duration_ms,
            r.qs_total_duration_ms,
            r.qs_avg_cpu_ms,
            r.qs_query_ids,
            r.match_method,
            r.create_index_sql,
            r.realigned_create_index_sql
        FROM #Results r
        WHERE r.row_kind = 'MISSING'
        ORDER BY r.DatabaseName, COALESCE(r.qs_total_duration_ms, -1) DESC, r.missing_impact DESC, r.SourceAnalysisId;
    END;
    ELSE IF @Output = 'DEPENDENTS'
    BEGIN
        /*  Section 9b rows only -- who references each table in scope, and what vouches for how.
            Sorted on catalog identity (table, kind, name), never on the IDENTITY copy.          */
        SELECT
            r.DatabaseName,
            r.object_name,
            r.index_name          AS dependent_label,
            r.type_desc           AS dependent_type,
            r.dependency_kind,
            r.evidence_source,
            r.last_evidence_time,
            r.index_cons
        FROM #Results r
        WHERE r.row_kind = 'DEPENDENT'
        ORDER BY r.DatabaseName, r.object_id, r.dependency_kind, r.index_name;
    END;

    /*  SECONDARY result set: drop-risk detail. Always emitted so the result-set count is stable. */
    SELECT
        d.DatabaseName,
        d.object_name,
        d.index_name,
        d.index_action,
        d.query_id,
        d.access_op,
        d.executions,
        d.total_duration_ms,
        d.avg_duration_ms
    FROM #DropRiskResults d
    ORDER BY d.DatabaseName, d.object_name, d.index_name, d.total_duration_ms DESC;

    /*  Warning-level preflight notes -- emitted only when there is something to say. */
    IF EXISTS (SELECT 1 FROM #PreflightNotes)
        SELECT DatabaseName, Note FROM #PreflightNotes ORDER BY DatabaseName, Note;

    /*  Databases asked for and not analysed -- visible, never a silently empty result. */
    IF EXISTS (SELECT 1 FROM #SkippedDatabases)
        SELECT DatabaseName, Reason FROM #SkippedDatabases ORDER BY DatabaseName;
END;
GO
