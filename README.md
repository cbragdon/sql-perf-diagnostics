# SQL Server performance diagnostics

Five diagnostics for SQL Server, Azure SQL Managed Instance and Azure SQL Database performance
problems. Everything here is **reviewable T-SQL, PowerShell or Python that a DBA reads and runs** --
nothing installs an agent, schedules a job, or applies a change on its own. Every fix the tools
suggest is emitted as **commented-out text for a human to review**, never as live DDL.

Two of the five are reactive (something already hurt). Three are proactive (run them before a change
ships).

| Tool | Answers | Ships as | Reactive / proactive |
|---|---|---|---|
| **Parameter-sniffing diagnostic** | Which statements have unstable plans, why, and what index or recompile would help | stored procedure | Reactive |
| **Client-timeout finder** | Which statements callers are abandoning, and what they were waiting on | stored procedure | Reactive |
| **Index analysis** | Duplicates, overlaps, unused indexes, missing indexes, FK gaps, heap and structural findings -- weighted by what actually ran | stored procedure | Either |
| **TippingPointAnalysis** | For a given predicate, what estimate the optimizer will use and whether it will tip from seek to scan -- before a bad plan is ever compiled | stored procedure | Proactive |
| **ComparePlans** | Which of 2-4 rewrite candidates is genuinely better, and why | Python, offline | Proactive |

**The four T-SQL diagnostics ship as stored procedures.** That is the deployable form and the more
capable one: a procedure analyses any database on the instance, or all of them, rather than
whichever one the query window happens to point at. Each also exists as a stand-alone script that
is held to cell-for-cell identical output -- those scripts are the project's own test apparatus and
are maintained privately, so they are not part of this release. Some documents here still describe
them; each of those carries a note at the top saying so.

The Extended Events stage of the timeout family is likewise not included, and the sections that
instructed you to run it have been removed from the documents in this release.

## How the five fit together

They are one process, not five unrelated utilities -- each hands the next something concrete.

**When something already hurts, start at the cheapest evidence and narrow.**

1. **Client-timeout finder** (`usp_FindTimeoutStatementsNQueryStore`) -- start here. It reads Query
   Store, which is already collecting and already holds days of history, so there is nothing to set
   up and nothing that had to be running before the incident. It answers *which statements are
   callers giving up on, and what were they waiting for*. Its **`NextStep`** column then says
   whether the next tool is warranted, and hands over the **`query_id`** to use.
2. **Parameter-sniffing diagnostic** (`usp_ParameterSniffingDiagnostic`) -- takes that `query_id`
   and answers *why* the plan is unstable: seven signals scored out of 100, a stability matrix,
   every plan the statement compiled to side by side with the parameter values each was compiled
   for, and a candidate index in `BaseIndexCreateSQL`.
3. **Index analysis** (`usp_IndexAnalysis`) -- run this **before** you create that index. Step 2
   reasons about one statement **in isolation**; it never looks at what else is on the table or who
   else reads it, which is exactly why that column is called *base* index and not *recommended*.
   This is the tool that knows whether the candidate duplicates or overlaps an index you already
   have, whether widening an existing one is the better move, and what else would lose a reader if
   you dropped something.

**Before a change ships, the same evidence runs forwards instead of backwards.**

4. **TippingPointAnalysis** (`usp_TippingPointAnalysis`) -- for a predicate you are about to deploy:
   which estimate will the optimizer actually use, where is the seek-to-scan tipping point, and will
   this query cross it. Answered from one plan plus statistics, with nothing executed and nothing
   compiled.
5. **ComparePlans** (`ComparePlans_v1.py`) -- capture the **actual** plans for two to four rewrite
   candidates and compare them offline, with no connection to anything. `--analyze-indexes` closes
   the loop back to step 3: when ComparePlans generates a `CREATE INDEX`, it runs `usp_IndexAnalysis`
   against that table and tells you whether to realign an existing index instead -- one command for
   "propose an index, then check it against the ones already there".

**What actually carries between the steps.** Step 1 to step 2 hops on `query_id`. Steps 2, 3 and 5
all converge on the same decision -- one table, one index -- which is why step 3 belongs between
*"here is an index that would help this statement"* and actually creating it. Every T-SQL tool takes
`@DatabaseName` plus an object-level scope, so each step narrows to what the previous one found.

None of this is a required order. Index analysis on its own is a good weekly review, TippingPoint
answers a question nothing else here asks, and ComparePlans never touches a server at all.


## What makes this different from the tools you already have

The Query Store correlation. `sp_BlitzCache` and `sp_BlitzIndex` are excellent and this is not a
replacement for either -- but neither reads Query Store at all (verified against their source:
`grep -c query_store` returns 0 in both). Their evidence therefore dies with the plan cache, which
a restart, a `CREATE INDEX`, or memory pressure empties. Query Store survives all three, so a
drop-index recommendation here is weighed against what actually ran over days, not over whatever
happens to be cached right now.

## Tested at every compatibility level the engine supports

Not a sample of levels -- **all of them.** SQL Server 2025 and every Azure SQL Managed Instance
update policy accept exactly eight database compatibility levels, **100 through 170**, and each of
the four T-SQL diagnostics is swept across all eight.

Each sweep rebuilds the test workload at the level under test and compares the stored procedure
against its stand-alone script **cell for cell** -- one differing column in one row fails the run.
All four pairs read ALL PASS at every level.

**That also covers every cardinality estimator those levels produce, including the legacy one.**
The compatibility level does not decide the estimator on its own, which is the part that catches
people out, and it is measured here rather than assumed. A plan compiles under CE model 70 by three
independent routes:

| Route | Effect |
|---|---|
| Compatibility level 100 or 110 | Every plan in the database compiles at model 70 |
| `LEGACY_CARDINALITY_ESTIMATION = ON` (database-scoped) | Every plan compiles at model 70 **at any level, 100 through 170** |
| `USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION')`, or trace flag 9481 | That one statement compiles at model 70, overriding both of the above |

So a database can report compatibility level 160 and still have every estimate produced by the
2012-era model, with nothing in the level saying so. The parameter-sniffing diagnostic reports both
facts rather than leaving them to be inferred: `LegacyCEDatabaseSetting` for the database, and per
row `PlanUsesLegacyCE` read from **the plan's own recorded model** rather than deduced from the
level -- NULL, never a guess, when a plan records none. The caveat it raises names which of the
three routes caused it.

It is disclosed, not scored. The estimator decides how often the cardinality-derived signals fire
-- on this project's own workload, 16 rows read skew-unstable under CE 70 against 12 under CE 150
-- but some of that skew is real at both, so suppressing the signal would hide it. The reader is
told which estimator produced the numbers instead.

One difference is tolerated, and printed rather than hidden: below compatibility level 130 the
engine's float-to-decimal rounding rule changed, so a few averages in the AI-prompt column can
differ by one unit in the last digit. Every other cell must match exactly.

## Requirements

| # | Requirement | Notes |
|---|---|---|
| 1 | **SQL Server 2019+** (or Azure SQL MI / DB) | Each tool self-gates and aborts with a message naming what it needs. A few index-analysis findings need newer builds; the native `json` support needs SQL Server 2025. |
| 2 | **Query Store ON** in the database being analysed | Off by default after a restore: `ALTER DATABASE [YourDb] SET QUERY_STORE = ON;` |
| 3 | **Permissions** | `VIEW SERVER STATE` (`VIEW SERVER PERFORMANCE STATE` on 2022+), `VIEW DATABASE STATE`, `SHOWPLAN`. Exact per-tool requirements are in each `USAGE-*.md`. |
| 4 | **Integrated / Entra authentication** | There is no password path anywhere in this toolset -- no `-P`, no connection string, no stored credential. By design. |
| 5 | **Python 3** (ComparePlans only) | Standard library only. No `pip install`. |
| 6 | **sqlcmd** (optional) | Only for the installer and the command-line examples. SSMS alone is fine. |

## Install

**ComparePlans needs no installation** -- it is a Python script that reads plan files and never
connects to a server. Skip to *First run* for it.

The four **stored procedures** are everything else. **Put all four in the same DBA utility
database.** Nothing forces it -- the four are independent, none calls another, and each reads its
target database through its own dynamic SQL -- but one database is the convention worth keeping:

- one place to grant `VIEW SERVER STATE` / `VIEW DATABASE STATE`, rather than four;
- one thing to back up, upgrade and audit when a new version lands;
- ComparePlans' `--analyze-indexes` hand-off points at a single database (below);
- each procedure skips its own host database in fleet mode (`@ExcludeHostingDatabase = 1`, the
  default), which reads predictably when there is one host to skip.

`DBAdmin` is the name this project uses throughout its examples. Any name works:

```powershell
.\Install-Diagnostics.ps1 -SqlInstance 'localhost' -UtilityDatabase 'DBAdmin'
```

Add `-WhatIf` to see what it would do and change nothing. The installer confirms sqlcmd is present,
reports the engine version, checks the database exists, deploys the four files, then re-reads
`sys.procedures` to confirm all four were actually created. It will not create a database for you --
if the target is missing it prints the `CREATE DATABASE` statement for you to review and run.

**Or install them by hand**, which is all the installer does: open each of the four `usp_*.sql`
files in SSMS, point the window at your utility database, and execute. The files carry no `USE`
statement and no hard-coded database name, so they are created wherever the connection points.

**If you do not call it `DBAdmin`, tell ComparePlans.** Its `--analyze-indexes` hand-off runs
`usp_IndexAnalysis` in the database given by `--utility-db`, which defaults to `DBAdmin`. Point it
at yours -- `--analyze-indexes MYSERVER --utility-db DBATools` -- or the section comes back as a
non-fatal failure rather than an index analysis. Everything else is unaffected: the procedures
themselves never reference each other or their own database by name.

## Recommended: enable `LAST_QUERY_PLAN_STATS`

Worth doing before you rely on the parameter-sniffing diagnostic, because several of its columns
depend on it. It is **opt-in and off by default.**

```sql
ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = ON;
```

**What it buys you.** It makes `sys.dm_exec_query_plan_stats` return the equivalent of the last
known *actual* execution plan -- the compile-time plan plus actual rows per operator, actual DOP,
granted and maximum used memory, and spill warnings. Without it that DMF returns nothing, and every
`CacheActual*` column in the parameter-sniffing output reads `Unavailable`. The tool still runs and
still reports honestly; it just has far less to work with.

**Prefer it to trace flag 2451**, which does the same job but is global-only and cannot be set on
Azure SQL Managed Instance, so a mixed estate ends up with two things to audit and the flag
silently doing nothing on the MI half.

**Three things worth knowing before you enable it fleet-wide:**

- **The `ALTER` evicts that database's plan cache.** Expect a recompile storm on a busy database;
  pick your moment.
- **Overhead is undocumented rather than measured as safe.** Microsoft attaches an explicit
  "not meant to be enabled continuously in production" warning to trace flag 2446 and attaches *no*
  such warning to this setting or to 2451 -- but an absence of a prohibition is not a measurement.
  The mechanism keeps the last actual plan beside the cached plan, so the cost lands in plan cache
  memory and scales with how many distinct plans the instance caches. Baseline
  `CACHESTORE_SQLCP` and `CACHESTORE_OBJCP` on a representative instance, enable, and compare.
- **New databases inherit database-scoped configurations from `model`**, so setting `model` covers
  anything created fresh -- but a *restored* database brings its source's setting with it. Re-apply
  after each wave of restores.

Requires SQL Server 2019 or later; `sys.dm_exec_query_plan_stats` does not exist before that and
the configuration option is rejected.

## First run

Point each at a database that has Query Store on. Always pass `@DatabaseName`: it defaults to the
*current* database, so a bare call from a `DBAdmin` window analyses `DBAdmin` itself.

```sql
-- Why are this database's plans unstable?
EXEC DBAdmin.dbo.usp_ParameterSniffingDiagnostic @DatabaseName = N'YourDatabase';

-- Which statements are callers giving up on?
EXEC DBAdmin.dbo.usp_FindTimeoutStatementsNQueryStore @DatabaseName = N'YourDatabase';

-- What does the index landscape look like? (start with the token glossary)
EXEC DBAdmin.dbo.usp_IndexAnalysis @DatabaseName = N'YourDatabase', @Output = 'LEGEND';
EXEC DBAdmin.dbo.usp_IndexAnalysis @DatabaseName = N'YourDatabase';

-- Will this predicate tip from seek to scan?
EXEC DBAdmin.dbo.usp_TippingPointAnalysis @DatabaseName = N'YourDatabase',
                                          @ObjectName  = N'dbo.YourProcedure';
```

ComparePlans is offline -- it reads `.sqlplan` files and never connects to anything:

```bash
python ComparePlans_v1.py before.sqlplan after.sqlplan
python ComparePlans_v1.py --single suspect.sqlplan
```

Capture the plans with **actual execution plan** on (`Ctrl+M` in SSMS). Estimated plans are
rejected with a message -- the analysis needs the runtime numbers only an actual plan carries.

## Reading the output

Each tool has a reference document covering every parameter, every output column, and how to read
a result:

- `USAGE-Paramsniffingdiagnostic_v1.md`
- `USAGE-FindTimeoutStatements_v1.md`
- `USAGE-IndexAnalysis_v1.md`
- `USAGE-TippingPointAnalysis_v1.md`
- `USAGE-ComparePlans_v1.md`

Two things worth knowing before you read a first result set:

- **Read the parameter-sniffing score against its ceiling, not against 100.** The ceiling drops
  whenever a signal could not be evaluated on that row, so a low score can be absence of evidence
  rather than evidence of absence.
- **`usp_IndexAnalysis @Output = 'LEGEND'`** prints the authoritative glossary of every pros/cons
  token the version in front of you can emit. Read that rather than any document, including this
  one -- it comes from the artifact itself and cannot go stale.

## Scope and honest limits

- Validated on **SQL Server 2025 Developer Edition** against `AdventureWorks2019`, **on a single
  box**. The compatibility-level and cardinality-estimator coverage is described above; what it
  does not include is a second machine or a second engine build.
- **Azure SQL Managed Instance is expected to work and has not been measured.** Platform detection
  is by edition rather than version number, and the code paths are shared, but expected is not
  measured and this document will not claim otherwise.
- Parameter Sensitive Plan optimization (compatibility 160+) creates multiple plans per query by
  design. The parameter-sniffing diagnostic does not yet account for that, so **treat its plan-count
  signal with suspicion on a compat-160-or-higher database**.
- A handful of findings are implemented but have no automated test because the condition cannot be
  staged safely (replicated columns need a live publication; memory-optimized tables need a
  filegroup that can never be removed). These are disclosed in the per-tool documents rather than
  quietly assumed to work.

## Attribution

**Where the approach came from.** The thinking behind these tools was built on the public teaching
and writing of the SQL Server community, worked through against thirty years of hands-on production
work. Named individually, in alphabetical order, because each shaped a specific part of it:

- **Erik Darling** -- plan reading, and `plan_extract.py` itself (see below).
  [Darling Data](https://erikdarling.com/).
- **Grant Fritchey** -- the execution plan as primary evidence: read what the optimizer actually
  did, rather than reasoning from the query text. Every tool here that shreds plan XML starts from
  that premise.
  [*SQL Server Execution Plans*, 3rd edition](https://www.red-gate.com/simple-talk/featured/sql-server-execution-plans-third-edition-by-grant-fritchey/),
  free from Redgate; [The Scary DBA](https://www.scarydba.com/). Also co-author, with Jason Strate,
  of the second edition of *Expert Performance Indexing in SQL Server* -- see below.
- **Brent Ozar Unlimited** -- the diagnostic stance the toolset takes, and `sp_BlitzCache` /
  `sp_BlitzIndex` as the reference it was measured against rather than copied from. Also parameter
  sniffing over skewed data, and the 201-bucket ceiling on a statistics histogram -- which is why
  `usp_TippingPointAnalysis` reads `sys.dm_db_stats_histogram` directly and reports
  `HistogramSkewRatio` and the heaviest value, instead of trusting a density average to describe an
  uneven column, and why the sniffing diagnostic scores cardinality skew as a signal of its own.
  [Troubleshooting parameter sniffing](https://www.brentozar.com/archive/2016/08/start-troubleshooting-parameter-sniffing-issues/),
  [the 201 buckets problem](https://www.brentozar.com/archive/2020/07/the-201-buckets-problem-part-2-how-bad-estimates-backfire-as-your-data-grows/).
- **Paul Randal** -- wait statistics as the first question to ask, and storage-engine internals.
  The timeout finder's wait categorisation exists because of that framing.
  [SQL Server Wait Types Library](https://www.sqlskills.com/help/waits/),
  [Wait statistics, or please tell me where it hurts](https://www.sqlskills.com/blogs/paul/wait-statistics-or-please-tell-me-where-it-hurts/).
- **Jason Strate** -- indexing as a discipline rather than a bag of tips. The *Expert Performance
  Indexing* series (Apress) runs from *Expert Performance Indexing for SQL Server 2012*, with Ted
  Krueger, through a second edition with Grant Fritchey, *in SQL Server 2019*, and *in Azure SQL
  and SQL Server 2022* with Edward Pollack; that body of work is the background `usp_IndexAnalysis`
  was written against. His `sp_IndexAnalysis` is the tool whose design it answers -- clean-room,
  under the licence terms set out below.
  Companion source for the
  [2019](https://github.com/Apress/expert-perf-index-in-sql-server-2019) and
  [2022](https://github.com/Apress/expert-performance-indexing-in-azure-SQL-and-SQL-server-2022)
  editions.
- **Kimberly Tripp** -- **the tipping point**: the point at which SQL Server stops using a
  nonclustered index plus lookups and scans instead, because the rows it would return are no longer
  selective enough against the table's page count. `usp_TippingPointAnalysis` is named for it, and
  its `@TippingPointPageFraction` default of `0.333` sits at the top of the 25-33% of pages her
  work describes. Also index key design, and the cost of a wide or non-unique clustered key that
  every nonclustered index pays again through its row locator -- the argument behind `CLNU` and
  `CLWIDE`.
  [The Tipping Point Query Answers](https://www.sqlskills.com/blogs/kimberly/the-tipping-point-query-answers/),
  [Tipping Point Queries: more questions](https://www.sqlskills.com/blogs/kimberly/tipping-point-queries-more-questions-to-really-test-you/).

What they teach in common is the shape of every tool here: read the plan instead of guessing,
distrust the estimate, prove a fix before it ships, and never let a tool apply its own
recommendation. The implementation, the Query Store correlation layer, and any defect in either,
are this project's own. **None of them is affiliated with this project, none has reviewed it, and
nothing here should be read as their endorsement.**

- **`plan_extract.py` is Erik Darling's `extract.py`**, vendored verbatim under the MIT License from
  [erikdarlingdata/claude-plugins](https://github.com/erikdarlingdata/claude-plugins) at mirror
  commit `a306273`. Its licence is `LICENSE-plan_extract.txt` and must travel with it.
  ComparePlans' own comparison logic is first-party; the parser is his.
- **The index analysis is a clean-room reimplementation** of the *design ideas* behind Jason
  Strate's `sp_IndexAnalysis`. His licence is internal-use-only and prohibits redistribution, so
  **no code of his appears here** -- the design was referenced, nothing was copied. The Query Store
  correlation layer, the byte-width guard, the dependent-object analysis and the statement-plan
  intake have no equivalent in his tool.
- The comparison with `sp_BlitzCache` / `sp_BlitzIndex` above was made by reading their source, not
  their documentation. Both are Brent Ozar Unlimited's, under their own licence; nothing of theirs
  is included or required here.
- "POC" (Partitioning, Ordering, Covering) is **Itzik Ben-Gan's** term for the window-function index
  pattern. "FPOC" -- prepending the filter -- is this project's own extension and should not be
  attributed to him.

## Licence

MIT. See `LICENSE`. `plan_extract.py` is separately covered by `LICENSE-plan_extract.txt`.
