> **This release ships the stored procedure only.** The stand-alone script form of this tool is
> maintained privately and is not included here. Everything below that describes the procedure
> applies; references to the `_v1.sql` script do not.

# Predicting a tipping point before it bites

`TippingPointAnalysis_v1.sql` (and its procedure form
`DBAdmin.dbo.usp_TippingPointAnalysis`) look at one query plan plus the table's
statistics and tell you, **before** a bad plan is ever compiled:

- what row-count estimate the optimizer will actually use for each
  local-variable, table-variable, or parameter predicate, and where that number
  comes from;
- how far that estimate is from what the statistics histogram says is really in
  the column;
- the **tipping point** -- the row count, and the mapped-back data value, at
  which the plan flips from a fast indexed seek to a full scan;
- which values are dangerous to compile for, and which are dangerous to *reuse*
  a selective plan against.

It never runs or compiles your query. It reads a plan that already exists,
does arithmetic against the histogram, and prints one row per predicate. Every
fix it suggests is commented-out text you review.

---

## Before you start -- prerequisites

| # | You need | How to check | If missing |
|---|---|---|---|
| 1 | A connection to the **database the query lives in** (integrated auth) | `sqlcmd -S <server> -d <db> -E -C -I -Q "SELECT DB_NAME();"` | Connect to the right database -- the tool reads *that* database's catalog and statistics. |
| 2 | **SQL Server 2016 or newer** (any edition; Azure SQL DB / MI included) | `SELECT SERVERPROPERTY('ProductMajorVersion');` >= 13 | Below 2016 the tool pre-flight aborts -- `sys.dm_db_stats_histogram` does not exist. |
| 3 | Permissions: **VIEW DATABASE STATE**, **SHOWPLAN**, and either `SELECT` on the target table or `db_owner` / `db_ddladmin` | you can already `SELECT` from the table and view a plan | `DBCC SHOW_STATISTICS ... WITH DENSITY_VECTOR` (the only source of `all_density`) needs one of those. Ask the DBA team for a role that has them. |
| 4 | **A plan to feed it** -- one of: a cached plan for a procedure/function, a Query Store `query_id`, or pasted showplan XML | see Step 1 | If nothing has a plan yet, run the query once (in dev) so it caches, or capture the plan from SSMS. |
| 5 | For the **script**: `sqlcmd` or an ADO.NET client. For the **procedure**: any client, including `dbatools`. | -- | `Invoke-DbaQuery` can choke on scripts in this repo that build SQL text; `sqlcmd` sends the batch verbatim. `EXEC` of the procedure is always fine. |

---

## Step 1 -- choose how you feed it a plan

Supply **exactly one**. The tool validates this at pre-flight.

| Input | Use when | Note |
|---|---|---|
| `@ObjectName = 'dbo.usp_GetOrders'` | The query is in a stored procedure or function and has run recently | Takes the **newest** cached plan for that object. If the cache was cleared, run it once first. |
| `@QueryId = 42` | You already found the statement in Query Store (e.g. from the timeout finder's `query_id`, or `sp_QuickieStore`) | Reads the plan Query Store has stored for it. |
| `@PlanXml = N'<ShowPlanXML ...>'` | You have the plan as a file or clipboard (SSMS: right-click the plan -> *Show Execution Plan XML*), or the query is ad hoc | Paste the whole `<ShowPlanXML>` document. |

The tool does **not** compile or execute anything -- all three inputs are "the
plan already exists".

---

## Step 2 -- run it

### As the script

Edit the `DECLARE` block at the top (Section 1), set one target, then:

```bash
sqlcmd -S localhost -d AdventureWorks2019 -E -C -I -i TippingPointAnalysis_v1.sql -o tp.txt -s"|" -W
```

(Windows paths from Git Bash must use backslashes -- `'D:\SQLTools\...'`.)

### As the procedure

```sql
EXEC DBAdmin.dbo.usp_TippingPointAnalysis
     @DatabaseName = 'AdventureWorks2019',
     @ObjectName   = 'dbo.usp_GetOrders';
```

The procedure output is identical to the script's, plus a leading
`DatabaseName` column. `@DatabaseName` defaults to the current database.

### The parameters that matter

| Parameter | Default | What it does |
|---|---|---|
| `@ObjectName` / `@QueryId` / `@PlanXml` | NULL | The target. Set exactly one. |
| `@TippingPointPageFraction` | `0.333` | The seek+lookup -> scan heuristic: roughly one-third of the table's data pages, in rows. Lower it if your rows are wide. |
| `@SkewRatioThreshold` | `10.0` | Histogram `MAX(equal_rows) / AVG(equal_rows)` above which the column is called "skewed". |
| `@EstimateVsTruthThreshold` | `10.0` | The estimate-vs-histogram gap that gets flagged. Also the sort key -- worst first. |
| `@StaleStatsModFraction` | `0.200` | `modification_counter / rows` above which statistics are called stale. |
| `@IncludeSniffableParameters` | `1` | Also analyse real parameters, not just local/table variables. |
| `@ProbeCardinalitySweep` | `1` | Emit the `[ProbeSweepScript]` for the optional second pass (Step 4). |
| `@TopPredicates` | `50` | Row cap. |
| `@Debug` | `0` | `1` also returns result set 2: the per-column histogram detail (first 10 + last 5 steps). |

---

## Step 3 -- read result set 1 (one row per predicate)

Rows are ordered worst-first by `EstimateVsTruthRatio`. Read a row left to right
in five groups.

**1. What predicate this is** -- `VariableName`, `VariableKind`
(`LocalVar` / `TableVar` / `SniffedParam` / `UnknownParam` / `FoldedLiteral`),
`SchemaName` / `TableName` / `ColumnName`, `PredicateOp`, `PredicateKind`
(`EQUALITY` / `RANGE` / `TABLEVAR`).

**2. What the optimizer will estimate** -- `ComputedOptimizerEstimate` and
`EstimateSource`:

| `EstimateSource` | Meaning |
|---|---|
| `Density` | `TableCardinality x all_density` -- a local variable with statistics present. |
| `Guess10Pct` | Equality with no usable statistics -- a fixed 10% of the table. |
| `Guess30Pct` | A range (`>`, `<`, `BETWEEN`) on a local variable -- a fixed 30% guess, **with or without** statistics. |
| `TableVar1Row` | Table variable, estimated at 1 row (compat <= 140, or deferred compilation off). |
| `DeferredCompile` | Table variable, real row count from the cached plan (compat >= 150, deferred compilation on) -- still **no column statistics**. |
| `SniffedValue` | A parameter whose value was known at compile time; the estimate is that value's own histogram rows. |
| `FoldedLiteral` | `OPTION (RECOMPILE)` -- the variable became a literal and the histogram is used directly. No action. |

`PlanEstimateRows` is the plan's own number; `ModelExplainsPlan = yes` means the
tool's computed estimate matches it within 2x (a sanity check that the regime
model fits this plan).

**3. What the histogram really says** -- `HistogramMaxEqRows` (the heaviest
single value), `HistogramTruthForValue` (the compiled-for value's own rows, for
a sniffed parameter), `HistogramSkewRatio`, `EstimateVsTruthRatio`,
`SkewDirection` (`under` / `over`), `TopHeavyValues`.

**4. The tipping point** -- `TippingPointRows` (NULL when the index is covering
-- there is no seek/scan flip), `HistSteps`, `StepsAboveTipping`,
`TippingValueNote` (plain-English), and `WillTip`:

| `WillTip` | Meaning |
|---|---|
| `n/a` | Covering index -- no seek/scan tipping point exists. |
| `no` | Estimate and worst value both stay below the tipping point. |
| `already scanning` | The density/guess estimate already exceeds the tipping point, so the compiled plan is a stable scan. |
| `yes (worst value)` | A seek plan whose histogram has values above the tipping point -- reuse for a heavy value tips it. |
| `yes (sniffing: heavy values tip)` | A **sniffed** parameter compiled for a value *below* the tipping point, but the histogram has heavy values *above* it. The classic parameter-sniffing landmine. |

**5. Statistics health & the fix** -- `StatName`, `StatsSampledPct`,
`StatsLastUpdated`, `StatsStale`, then `[Fix]` -- advisory text; any DDL in it
(`UPDATE STATISTICS`, `CREATE STATISTICS`, a covering index) is commented out.

### Worked example

`dbo.tp3_sniffedparam_rare` compiled for `ProductID = 725` (about 5 rows). The
row reads:

```
VariableKind        SniffedParam
EstimateSource      SniffedValue      ComputedOptimizerEstimate 5
HistogramMaxEqRows  4187              EstimateVsTruthRatio      775x
TippingPointRows    264               WillTip  yes (sniffing: heavy values tip)
Fix   Plan compiled for (725) (est 5); the histogram's heaviest value is 4187
      (775x). Reusing this plan for a heavy value is the sniffing risk.
      OPTIMIZE FOR UNKNOWN (stability) or OPTION (RECOMPILE) (accuracy).
```

Read: the cached seek+lookup plan is fine for `725`, but any caller passing a
common `ProductID` reuses that plan and does thousands of lookups instead of
scanning. Fix the parameter handling before it ships.

---

## Step 4 (optional) -- fold in the precise crossovers

The seek->scan tipping point is computed analytically. The other crossovers
(join type, parallelism, aggregate strategy) need real compiles, which the tool
cannot do itself without risking execution. So with `@ProbeCardinalitySweep = 1`
it *emits* a script in the `[ProbeSweepScript]` column instead.

1. Copy the `[ProbeSweepScript]` text. It is a `SET SHOWPLAN_XML ON` batch with
   `GO` separators -- run it in **SSMS** (client-side `GO` batching, where
   `SHOWPLAN_XML` works), not through the tool.
2. Concatenate every `<ShowPlanXML>` document it produces.
3. Re-invoke the tool with that text in `@ProbePlanXml` (and the same target).

Result set 1 comes back with `PreciseCrossover` filled -- e.g.
`Index Seek -> Clustered Index Scan between values 856 and 969 (join type changes)`
-- the measured crossover, bracketing the heuristic tipping point.

---

## Limits (v1)

- **No execution, no compile.** Reads existing plans only (`@ObjectName`,
  `@QueryId`, `@PlanXml`).
- **A plan nested deeper than 128 levels cannot be analysed** -- SQL Server's `xml`
  type cannot hold it. Every target says so: `@QueryId` and `@ObjectName` report the
  plan as too deep (rather than failing, or claiming nothing is cached), and a pasted
  `@PlanXml` is refused with the same reason. A long nested expression in the
  statement is the usual cause.
- The seek/scan tipping point is analytic; the probe-sweep crossovers are
  **sampled** -- reported as "between two probed cardinalities", not solved.
- Single-column predicates precisely; composite statistics use **leading-column
  density**, disclosed per row.
- **PSP** (SQL Server 2022 / compat 160): reported when in play; the
  dispatcher's plan choice is not predicted.
- **Row goals** (`TOP` / `FAST N` / `EXISTS`) shift the effective tipping point;
  flagged, not modelled.
- **Memory-optimized table variables**: detected and flagged; histogram
  analysis N/A.
- Pre-2017 plans lack `<OptimizerStatsUsage>` -- statistics are matched by
  leading-column name, disclosed per row.
- Database compatibility level gates only the *regime* the tool reports, never
  the reads. Validated at compat 150 on one SQL Server 2025 box; swept compat
  100-170 on that box; not measured on a real Managed Instance.
