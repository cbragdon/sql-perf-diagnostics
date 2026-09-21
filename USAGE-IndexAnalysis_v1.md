> **This release ships the stored procedure only.** The stand-alone script form of this tool is
> maintained privately and is not included here. Everything below that describes the procedure
> applies; references to the `_v1.sql` script do not.

# Reviewing a database's indexes against the real workload

`IndexAnalysis_v1.sql` (and its procedure form `DBAdmin.dbo.usp_IndexAnalysis`)
read the catalog, the index and missing-index DMVs, and Query Store, and produce
a per-index verdict: **add, drop, rework, or leave alone** -- ranked by what the
live workload actually does, and showing which queries a proposed drop would
affect.

It is a clean-room reimplementation of Jason Strate's `sp_IndexAnalysis` with a
Query Store correlation layer his has no equivalent of. It reads only -- every
`CREATE INDEX` / `DROP INDEX` / `ALTER INDEX` it produces is emitted as a
commented-out line for you to review and run yourself.

---

## Before you start -- prerequisites

| # | You need | How to check | If missing |
|---|---|---|---|
| 1 | A connection to the **database whose indexes you are reviewing** (integrated auth) | `sqlcmd -S <server> -d <db> -E -C -I -Q "SELECT DB_NAME();"` | Connect to that database. The script reads *that* database's catalog; the procedure reaches others via `@DatabaseName`. |
| 2 | **SQL Server 2016 or newer**, any edition, or Azure SQL Managed Instance | `SELECT SERVERPROPERTY('ProductMajorVersion');` >= 13 | Below 2016 the pre-flight aborts -- the Query Store correlation has nothing to read. |
| 3 | **VIEW SERVER STATE** (2016-2019) or **VIEW SERVER PERFORMANCE STATE** (2022+), plus **VIEW DATABASE STATE** | you can already query `sys.dm_db_index_usage_stats` and `sys.dm_db_missing_index_details` | Ask the DBA team for a role that has them. Without them the usage / missing-index sections come back empty (nothing errors). |
| 4 | **Query Store ON** in the target database -- *optional but recommended* | `SELECT actual_state_desc FROM sys.database_query_store_options;` = `READ_WRITE` | Not required. Without it the ranking silently falls back to cumulative DMV counters (`@RankingSource` effectively `DMV`), and the missing-index -> query bridge and drop-risk blast radius are empty. |
| 5 | A client: **`sqlcmd`**, ADO.NET, **or `dbatools`** -- all fine here | -- | The generated DDL is `-- ` line-commented (not `/* */`), so `Invoke-DbaQuery` runs this script *and* the procedure without the parser problem the parameter-sniffing script has. |

---

## Step 1 -- decide the scope

| Scope | How | When |
|---|---|---|
| Whole database | leave `@TableName` / `@TableList` NULL (default) | Periodic index review; consolidation. |
| One table | `@TableName = 'Sales.SalesOrderDetail'` (bare or schema-qualified, brackets optional) | Checking the tables a feature touches. A typo **aborts** with a message -- it never silently returns nothing. |
| Several named tables | `@TableList = 'Sales.SalesOrderDetail, Person.Address, dbo.Widget'` | A change set spanning a few tables. Every unresolved name aborts the run. |

`@TableName` and `@TableList` union -- set either, both, or neither.

---

## Step 2 -- run it

### As the script

Edit the **USER SETTINGS** block at the top (scope, `@Output`, `@RankingSource`,
`@LookbackDays`, `@IncludeBufferPool`), then:

```bash
sqlcmd -S localhost -d AdventureWorks2019 -E -C -I -i IndexAnalysis_v1.sql -o idx.txt -s"|" -W
```

(Windows paths from Git Bash use backslashes -- `'D:\SQLTools\...'`.)

### As the procedure

```sql
EXEC DBAdmin.dbo.usp_IndexAnalysis
     @DatabaseName = 'AdventureWorks2019',
     @Output       = 'DETAILED';
```

Every result set gains a leading `DatabaseName` column; nothing else differs
from the script. Fleet use:

```sql
EXEC DBAdmin.dbo.usp_IndexAnalysis
     @AllDatabases           = 1,          -- every online, writable, non-system database
     @ExcludeDatabases       = 'ReportingArchive, Scratch',
     @ExcludeHostingDatabase = 1;          -- skip DBAdmin itself (default)
```

### The parameters that matter

| Parameter | Default | What it does |
|---|---|---|
| `@Output` | `DUMP` | `DUMP` = every column, every row. `DETAILED` = the analyst subset (action, pros, cons, columns, sizes, usage, waits). `DUPLICATE` / `OVERLAPPING` / `REALIGN` = only rows of that kind. `MISSING` = the missing-index -> Query Store bridge. `COMPRESSION` = only indexes with a PAGE recommendation. |
| `@RankingSource` | `BLEND` | `DMV` = cumulative counters only (reset on restart / rebuild). `QS` = Query Store runtime over `@LookbackDays` only. `BLEND` = Query Store where it has coverage for the object, cumulative counters where it does not; each row states which drove it. |
| `@WorkloadType` | `OLTP` | Drives the compression recommendation. `OLTP` = per-index test: scan % > `@CompressionScanPctForPage` (75) **and** update % < `@CompressionUpdatePctForPage` (20), from `sys.dm_db_index_operational_stats`; or an append-only pattern (inserts > `@CompressionAppendOnlyInsertPct` 90, updates below the limit). `DW` = page-compress every sizeable uncompressed / ROW-compressed object, skipping the test -- Microsoft's data-warehouse shortcut. Set `@RecommendCompression = 0` to switch it off entirely. |
| `@LookbackDays` | `14` | Query Store window for the correlation sections. |
| `@IncludeBufferPool` | `1` | The buffer-pool residency probe -- the slowest collector on a big instance. `0` skips it and reports `buffered_mb` / `pct_in_buffer` as NULL. |
| `@UnusedIndexMinDaysSinceStartup` | `7` | If the instance restarted fewer than N days ago, `DROP-USAGE` is withheld (the `TOOSOON` con) -- the counters are too fresh to trust. |
| `@LockWaitTotalMsWarn` | `300000` | Row + page lock wait above this (5 minutes) -> `LOCKWAIT`. Not gated on uptime: presence is the finding here, so a short uptime can only cause a miss, never a false report. |
| `@HeapForwardedFetchWarn` | `1` | Forwarded fetches on a heap at or above this -> `HEAPFWD`. |
| `@HeapDeleteWarn` | `1` | Leaf deletes on a heap at or above this -> `HEAPDEL`. |
| `@LowStatsSamplePct` | `25.0` | Index statistics built from below this percent of rows -> `STATSAMP<n>`. |
| `@StatsSampleMinRows` | `10000` | ... and only on an index of at least this many rows; a low sample on a small table means nothing, since SQL Server reads most of it anyway. |
| `@MissingIndexMinImpact` | `1.0` | `(user_seeks + user_scans) x avg_user_impact` floor for a missing index to become a `CREATE`. Lower it to see more. |
| `@DropRiskMaxQueriesPerIndex` | `20` | Cap on blast-radius rows per drop candidate in the secondary result set. |
| `@Debug` | `0` | `1` adds diagnostic detail. |

---

## Step 3 -- read the primary result set

One row per index, plus synthetic rows for missing indexes and FK gaps.
`row_kind` tells them apart: `INDEX`, `MISSING`, `FKGAP`.

### `index_action` -- one verb, most consequential first

| Action | Meaning |
|---|---|
| `ENABLE` | A disabled index -- rebuild to bring it back. |
| `DROP-DUP` | An exact duplicate of a lower-`index_id` index (same key columns and direction, same includes). The other one is the keeper. |
| `DROP-DUP?` | Same, but Query Store shows a query still naming *this* index specifically. Look before you drop. |
| `DROP-USAGE` | A nonclustered index with zero cumulative reads and a safe window since the last restart. |
| `DROP-USAGE?` | Same, but Query Store shows reads inside `@LookbackDays`. The `?` means Query Store disagrees with the cumulative counter. |
| `REALIGN` | A clustered index or heap taking heavy key lookups, or almost no read traffic -- the row layout is working against the workload. |
| `SEQKEY` | Last-page insert contention -> consider `OPTIMIZE_FOR_SEQUENTIAL_KEY` (2019+). |
| `CREATE` | A missing index above `@MissingIndexMinImpact` (top N per table), or a foreign key with no supporting index. |
| `BLEND` | A lower-impact missing index that folds into an existing index's leading key instead of being created on its own. |
| `DROP-HYPO` | A hypothetical index (Database Engine Tuning Advisor leftover). Always safe to drop -- it has no data and no plan can use it. Appears only on a `row_kind = 'HYPO'` row. |
| `---` | Nothing to do. |

**A `?` suffix always means "Query Store still sees something reading this"** --
treat it as a review flag, not a drop instruction.

### `index_pros` / `index_cons` -- comma-separated tokens

The table below is a convenience. **`@Output = 'LEGEND'` is the authoritative copy**, because it
comes out of the artifact in front of you and therefore cannot go stale:

```sql
EXEC dbo.usp_IndexAnalysis @DatabaseName = 'YourDb', @Output = 'LEGEND';
```

It runs before any collection -- no scan, no Query Store read, nothing touched in the target
database -- so it is safe to run anywhere, any time, just to read the vocabulary.

![The full pros and cons token vocabulary printed by @Output = 'LEGEND', with callouts on four
instructive entries](images/indexanalysis-legend.png)

**Four entries worth reading closely, because each teaches how the vocabulary works:**

1. **`$ $$ $$$ $$$+` carries a measurement, not a flag.** More `$` is more read-dominant --
   at least 1, 10, 100 or 1000 reads per write. Several tokens work this way (`FILL<n>`,
   `NCMANY<n>`, `IDENT<n>%`), so the token itself usually tells you the magnitude and you do not
   have to go looking for the column it came from.
2. **`TOOSOON` is a statement about the EVIDENCE, not about the index.** It means a `DROP-USAGE`
   verdict was *withheld* because the instance has not been up long enough for the usage counters
   to mean anything. It says nothing about the index at all. The entry also names its old spelling
   -- `RECENT`, which read as "recently created" and was exactly the wrong idea -- so output you
   captured before the rename still decodes.
3. **`HYPO` has its own `row_kind`.** A hypothetical index is a Tuning Advisor leftover with no
   data and no storage; nothing else on the row is measured *because there is nothing there to
   measure*, which is why it is kept out of the ordinary index rows rather than analysed as one.
4. **`NOTNULL<n>of<m>` reads backwards, and says so.** A LOWER n is the finding -- `0of7` is worse
   than `1of7`. Both it and `STRING<n>of<m>` carry their own denominator, so the ratio that makes
   it a finding is visible at the point you read it rather than in a footnote.



Pros: `PK`, `UQ` (unique), `CLU` (clustered), `FK`, `MIFK` (supports an FK), and
read:write bands `$` / `$$` / `$$$` / `$$$+`.

Cons:

| Token | Meaning |
|---|---|
| `HP` | Heap (no clustered index). |
| `HEAPFWD` | A heap whose **forwarded records** are being followed: a row grew past its page, left a forwarding pointer, and every read since pays an extra page fetch. Only a rebuild clears them. |
| `HEAPDEL` | A heap **with deletes**. Deleting from a heap does not deallocate the emptied pages, so its size and scan cost stay put until it is rebuilt. |
| `HEAPPK` | The table is a heap whose **primary key is nonclustered** -- usually an accident rather than a decision. Catalog-only, so a restart cannot make it wrong. |
| `LOCKWAIT` | Row plus page lock wait on this index exceeds `@LockWaitTotalMsWarn` (default 300,000 ms = 5 minutes). A flag, not a number: `row_lock_wait_in_ms` carries the magnitude. |
| `PART<n>` | This index is built on a **partition scheme**, across n partitions. Informational, but it changes how every size and usage figure on the row should be read. |
| `PARTNA` | **Non-aligned**: the table is partitioned and this index is not. Partition `SWITCH` needs every index aligned, so one stray index costs the whole switching strategy. |
| `STATSAMP<n>` | This index's statistics were last built from only n percent of the rows, below `@LowStatsSamplePct`. Every estimate drawn from that histogram inherits the sampling error. |
| `RESUMABLE` | A resumable `ALTER INDEX` was **paused** against this index and never finished. The half-built index keeps its allocation and blocks further DDL on it until resumed or aborted. |
| `DSB` | Disabled. |
| `DUP` | Has an exact duplicate -- same key columns and same includes. |
| `OVLP` | Its key is a leading prefix of another index's key (or vice versa). |
| `SIB` | Same distinct key columns as another index, different order/includes -- informational. |
| `LKUP` | Key lookups above the threshold and exceeding seeks + scans. |
| `SCN` | Scans dominate seeks by more than `@ScanToSeekRatioThreshold`. |
| `U1%` | Doing under 1% of its table's read traffic. |
| `WIDE` / `C25%` / `C50%` / `C90%` | Key + include columns are this share of the table's columns -- a near-covering index that costs write and space. |
| `NOCMP` | Uncompressed and large enough that compression is worth considering. |
| `W$` | Write-heavy: reads:writes below `@WriteHeavyReadsPerWrite`. |
| `JSONCOL` | The table **has** a native `json` column (engine 2025) -- a pointer that JSON-index guidance may apply. Not an action in v1. |
| `TOOSOON` | `DROP-USAGE` was **withheld**: the instance has been up fewer than `@UnusedIndexMinDaysSinceStartup` days, so the usage counters cannot be trusted yet. Says nothing about the index itself. |
| `UNVERIFIED` | A dependent object with no plan evidence anywhere -- nothing proves it still runs, and nothing proves it does not. |
| `DEPUNV` | A drop candidate on a table that has at least one `UNVERIFIED` dependent. Verify before dropping. |
| `CLNU` | The clustered index is not unique, so SQL Server adds a uniquifier -- and every nonclustered index carries it too. |
| `CLWIDE` | The clustered key exceeds `@WideClusteredMaxKeyColumns` columns or `@WideClusteredMaxKeyBytes` bytes. Its width repeats in every nonclustered index. |
| `FILL<n>` | Fill factor is n percent, at or below `@LowFillFactorPct`. A **lower** n reserves more empty space on every page. |
| `FILTCOL<n>` | This **filtered** index's `WHERE` names n columns the index does not contain, as key or as `INCLUDE`, so the optimizer has to re-check the filter against the base table. `create_index_sql` carries the column names and a `DROP_EXISTING = ON` rebuild that adds them. |
| `HYPO` | A hypothetical index -- a Database Engine Tuning Advisor leftover with no data and no storage that no plan can use. Arrives on its own `row_kind = 'HYPO'` row with `index_action = 'DROP-HYPO'`; nothing else on the row is measured. |
| `TBLWIDE` | The table exceeds `@WideTableMaxColumns` columns or `@WideTableMaxRowBytes` non-LOB bytes per row. |
| `NCMANY<n>` | The table carries n nonclustered indexes, at or above `@ManyNonclusteredIndexes`. Higher n is worse. |
| `NOTNULL<n>of<m>` | Only n of the table's m columns are `NOT NULL`. **Read this one backwards:** a *lower* n is the finding, and `NOTNULL0of7` is worse than `NOTNULL1of7`. |
| `STRING<n>of<m>` | n of the table's m columns are a string or LOB type. Higher n is the finding. |
| `IDENT<n>%` | An identity column has consumed n percent of its data type's range. Higher is worse; at 100 inserts fail. |
| `COLLMIX` | At least one column's collation differs from the database's -- a silent source of join and comparison surprises. |
| `REPL<n>of<m>` | n of the table's m columns belong to at least one replication publication, so an index or column change here has to be reasoned about against replication too. |
| `CSTORE<n>` | The table has n **columnstore** indexes, which this tool does not analyse -- it collects rowstore only. Their absence from the report is not evidence they are absent from the table. |
| `MEMOPT` | The table is **memory-optimized** (In-Memory OLTP). Rowstore index analysis does not describe it; treat the report as covering the table's disk-based structures only. |
| `FKCASC` | A foreign key on this table uses `CASCADE` on update or delete, so writes here can fan out. |

`TBLWIDE`, `NCMANY<n>`, `NOTNULL<n>of<m>`, `STRING<n>of<m>`, `IDENT<n>%`,
`COLLMIX`, `REPL<n>of<m>`, `CSTORE<n>`, `MEMOPT` and `FKCASC` describe the **table**, not any one index,
and arrive on their own `row_kind = 'TABLE'` row -- emitted only when at least
one of them fires, so a healthy table adds no row at all. `HYPO` is the other
non-index kind: `row_kind = 'HYPO'`, one row per hypothetical index.

**`@Output = 'LEGEND'` prints this list from the tool itself** -- kind, token and
meaning, straight out of the artifact you are running, with no collection and no
database scan. That is the authoritative copy; this table is a convenience that
can fall behind it. Four tokens were renamed on 2026-09-13 -- `RECENT` ->
`TOOSOON`, `NJSON` -> `JSONCOL`, `NOTNULL<n>` -> `NOTNULL<n>of<m>`, `NONSTR<n>`
-> `STRING<n>of<m>` -- and each legend entry names its old spelling, so output
captured before that date still decodes.

> **Worked example:** [EXAMPLE-IndexRealign.md](EXAMPLE-IndexRealign.md) shows a missing-index
> proposal, the driving `query_id` the Query Store bridge attaches to it, and the realigned key
> that removes the driving query's Sort as well as its lookup.

### `create_index_sql` / `drop_index_sql`

The generated statement, as a `-- ` line comment. Copy it, remove the `-- `,
review it, run it yourself. The script never executes DDL.

### `recommended_compression` / `compression_reason` / `compression_sql`

`recommended_compression` is `PAGE` or NULL -- **ROW is never recommended**, and
nothing is recommended when the operational-stats numbers don't meet the test (or
are too fresh since a restart, in `OLTP` mode). `compression_reason` states why
(the S / U figures, or "DW / data-mart workload"). `compression_sql` is a
commented `-- ALTER INDEX ... REBUILD WITH (DATA_COMPRESSION = PAGE);` (or
`ALTER TABLE ... REBUILD` for a heap). It is a full rebuild -- capacity-plan it
like any index rebuild (workspace, one object at a time, `SORT_IN_TEMPDB = ON`),
and note it removes fragmentation and can change query plans. For a heap the
reason adds: *"Heap DML pages don't get PAGE compression until the heap is
rebuilt."* `ops_scan_pct` (S) and `ops_update_pct` (U) are shown in `DUMP` /
`DETAILED` / `COMPRESSION`. `@Output = 'COMPRESSION'` filters to just the
recommended rows.

**`missing_order_by_cols` / `missing_group_by_cols` / `missing_window_kind`**
(`DUMP`, `DETAILED`, `MISSING`) -- for each `<<missing #N>>` proposal, the driving
Query Store query's `ORDER BY` / `GROUP BY` columns, shredded from that query's
stored plan XML (the dominant bridged query -- most total duration). `ORDER BY`
columns carry ` DESC` where the plan's Sort is descending. The missing-index DMV's
own suggestion ignores sort/grouping; these let a caller rebuild the key in
filter -> GROUP BY -> ORDER BY order so the query's Sort / Hash Aggregate is
eliminated -- which is what ComparePlans `--realign-missing-indexes` does (in its
`--single` mode only). NULL for a proposal with no Query Store bridge, or whose
plan carries no result Sort / GroupBy. Only the outermost result `ORDER BY` and
the first `GROUP BY` are read. `OVER (PARTITION BY ...)` is not parsed as such, but
a window function's `PARTITION BY` surfaces in the plan as a `Segment` operator's
`<GroupBy>`, so it is picked up through the `GROUP BY` path -- and
**`missing_window_kind`** flags that the realigned key is really a windowing POC
index: `'FPOC'` when the proposal also carries a filter, `'POC'` when it does not,
`NULL` when the driving plan has no `Sequence Project` / `Segment` /
`Window Aggregate` operator.

---

## Step 3b -- the other result sets

**Secondary result set -- drop-risk blast radius.** Always emitted (may be
empty). One row per (drop-candidate index, Query Store query that still reads it)
over `@LookbackDays`, with execution count and duration, capped by
`@DropRiskMaxQueriesPerIndex`. If a `DROP-DUP` / `DROP-USAGE` candidate has rows
here, its action in the primary set carries the `?` suffix.

**A Query Store plan too deep to read** (nested past the 128 levels SQL Server's
`xml` type allows -- a long nested expression is enough) cannot be shredded as XML.
It no longer stops the run: its text is searched for the indexes it reads, and each
one is credited with that query exactly as a parsed plan would credit it -- shown
here with `access_op` = `PlanTooDeep` -- so a drop candidate never loses a reader to
it. What such a plan cannot contribute is everything else that needs XML: its
missing-index hints, its ORDER BY / GROUP BY shape, and its ranking weight. A pasted
`@StatementPlanXml` that deep is refused with a message that says so.

**Procedure only, emitted when non-empty:**

- `#PreflightNotes` -- per-database warning conditions (Query Store not readable
  so ranking fell back to DMV, retention shorter than `@LookbackDays`, and so
  on). The script `PRINT`s these; the procedure returns them as a result set
  because `PRINT` does not reliably reach a caller sweeping many databases.
- `#SkippedDatabases` -- databases asked for (by name or by `@AllDatabases`) and
  not analysed, with the reason. The reason names every cause that applies,
  separated by `; ` -- a system database, not ONLINE, in STANDBY, READ_ONLY, a
  database snapshot, also named in `@ExcludeDatabases`, or "it hosts this
  procedure" when `@ExcludeHostingDatabase = 1` (the default) skipped `DBAdmin`.

---

## Worked example

Two identical nonclustered indexes on `Sales.SalesOrderDetail` --
`(ProductID) INCLUDE (OrderQty)` -- created as `IX_dup_a` and `IX_dup_b`:

```
index_name   index_action  index_pros  index_cons        drop_index_sql
IX_dup_a     ---           $$          DUP, OVLP         (keeper)
IX_dup_b     DROP-DUP      $$          DUP, OVLP         -- DROP INDEX IX_dup_b ON Sales.SalesOrderDetail;
```

Read: both are flagged `DUP` (they match each other) and `OVLP` (both are a
prefix of the stock `IX_SalesOrderDetail_ProductID`). The lower `index_id`
(`IX_dup_a`) is the keeper; `IX_dup_b` is the one to drop. If Query Store showed
a query naming `IX_dup_b` by hint, the action would read `DROP-DUP?` and that
query would appear in the secondary result set.

---

## Counter-reset caveat -- read before acting on a DROP-USAGE

`sys.dm_db_index_usage_stats` is cleared on service restart and when the index is
rebuilt. `sys.dm_db_missing_index_*` is cleared on restart and when *any* index
is created on the table. A "0 seeks, 0 scans" index may just be an index on a
table that was reindexed yesterday. The defaults mitigate this three ways:
`@UnusedIndexMinDaysSinceStartup` withholds `DROP-USAGE` after a recent restart
(the `TOOSOON` con); `@RankingSource = BLEND` ranks by Query Store runtime, which
survives a restart; and the secondary result set shows every drop candidate's
current Query Store readers. Still -- confirm an index is genuinely unused over a
full business cycle before dropping it.

---

## Limits (v1)

- **No severity score, no banding, no `[AI Prompt]` column** -- deferred, same as
  the parameter-sniffing tool's own phasing.
- `BLEND` folds one missing-index suggestion into one existing index. Full
  cross-index *consolidation* is a later phase.
- Columnstore, vector, and native-JSON transitions are **report-only flags**
  (`JSONCOL` and notes), not generated scripts.
- `sys.dm_db_missing_index_*` membership is volatile; missing-index rows are best
  treated as "there is demand here", not a stable list.
- On 2016 / 2017 the missing-index -> query bridge uses a plan-XML fallback
  (match on table + column set) rather than the exact `query_hash` join
  (2019+). Drop-risk and re-weighting work fully.
- Validated at database compat 150 on one SQL Server 2025 box; swept compat
  100-170 on that box (structural output stable, only recommendation text
  changes). Not measured on a real Managed Instance -- detection is by engine
  name, so MI is expected to work but is not confirmed.
