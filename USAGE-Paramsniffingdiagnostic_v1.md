> **This release ships the stored procedure only.** The stand-alone script form of this tool is
> maintained privately and is not included here. Everything below that describes the procedure
> applies; references to the `_v1.sql` script do not.

# Diagnosing an unstable (parameter-sniffing) plan

`Paramsniffingdiagnostic_v1.sql` (and its procedure form
`DBAdmin.dbo.usp_ParameterSniffingDiagnostic`) read Query Store and the plan
cache and, for each statement whose plan looks unstable, score **seven signals
out of 100**, band the result **Low / Medium / High / Critical**, and emit:

- a **base index** for the statement, one row per *access path* (a table read
  twice in a plan gets a recommendation per access);
- a **recompile-vs-force-plan** recommendation, gated by how often the statement
  runs;
- a seven-column **stability matrix**;
- `isXML` / `isJSON` flags where the ordinary B-tree recommendation needs
  reinterpreting;
- **`[AI Prompt]`** -- a copy/paste prompt for a model: every plan the statement
  compiled to side by side, the live plan cache, statistics freshness, the plan
  itself, and this script's findings.

It reads only. `BaseIndexCreateSQL` / `BaseIndexDropSQL` /
`RecommendedRecompileSQL` are commented-out text you review and run yourself.

---

## Before you start -- prerequisites

| # | You need | How to check | If missing |
|---|---|---|---|
| 1 | A connection to the **database the statement runs in** (integrated auth) | `sqlcmd -S <server> -d <db> -E -C -I -Q "SELECT DB_NAME();"` | Connect to that database. The script reads *that* database's Query Store; the procedure reaches others via `@DatabaseName`. |
| 2 | **SQL Server 2016 or newer**, and **Query Store ON** in the target with data in the lookback window | `SELECT actual_state_desc FROM sys.database_query_store_options;` = `READ_WRITE` | Below 2016 the pre-flight aborts -- the whole script is built on Query Store. If Query Store is off, turn it on and wait for the workload to populate it. |
| 3 | **VIEW DATABASE STATE** (or ownership), plus **SHOWPLAN** | you can already view an execution plan for the query | Ask the DBA team for a role that has them. |
| 4 | *(2019+, optional)* the **`LAST_QUERY_PLAN_STATS`** database-scoped configuration ON | `SELECT * FROM sys.database_scoped_configurations WHERE name = 'LAST_QUERY_PLAN_STATS';` | Without it the four actual-plan signals (`MemoryGrantStability`, `ParallelismStability`, `OperatorSkewStability`, `SpillStability`) report `Unavailable` -- the other three signals and the whole index engine still work. |
| 5 | For the **script**: `sqlcmd` or an ADO.NET client. For the **procedure**: any client, including `dbatools`. | -- | `dbatools`' `Invoke-DbaQuery` trips on the `/* */` pair inside the generated `CREATE INDEX` text and **cannot run the script**. `sqlcmd` sends the batch verbatim; `EXEC` of the procedure is always fine. |

---

## Step 1 -- know what you are pointing it at

This tool is scoped **by object**, not by `query_id`. If you arrived here from
the timeout finder's `NextStep` ("run Paramsniffingdiagnostic and look up
query_id N"), set `@TargetObjectName` to the **procedure** that statement belongs
to, run the tool, then find that `query_id` in the output.

| Scope | How | When |
|---|---|---|
| One object | `@TargetObjectName = 'dbo.usp_GetOrders'` (bare or schema-qualified, brackets optional; a typo aborts) | Investigating a specific procedure -- the common case. |
| Everything in the window | leave `@TargetObjectName` NULL (default) | Instance-wide triage: "what has unstable plans right now". |
| Include ad-hoc / dynamic SQL | `@IncludeAdHocAndDynamicSQL = 1` | The statement runs through `sp_executesql` or is an ad-hoc batch. Off by default -- on a busy instance this is a lot of unowned noise. Dynamic SQL cannot be attributed back to the procedure that issued it. |

---

## Step 2 -- run it

### As the script

Edit the **USER SETTINGS** block at the top (the four most-changed parameters),
and any Section 1 threshold you want to move, then:

```bash
sqlcmd -S localhost -d AdventureWorks2019 -E -C -I -i Paramsniffingdiagnostic_v1.sql -o psd.txt -s"|" -W
```

(Windows paths from Git Bash use backslashes -- `'D:\SQLTools\...'`.)

### As the procedure

```sql
EXEC DBAdmin.dbo.usp_ParameterSniffingDiagnostic
     @DatabaseName     = 'AdventureWorks2019',
     @TargetObjectName = 'dbo.usp_GetOrders';
```

Every result set gains a leading `DatabaseName` column; nothing else differs.
Fleet use: `@AllDatabases = 1` with `@IncludeDatabases` / `@ExcludeDatabases` /
`@ExcludeHostingDatabase`.

### The parameters that matter

| Parameter | Default | What it does |
|---|---|---|
| `@IndexRecommendationMode` | `'B'` | Which table the index recommendation targets: `A` = every table referenced; `B` = highest-IO table; `C` = worst cardinality-skew table; `D` = most/worst-spilling table. |
| `@ShowModeComparison` | `1` | Adds a **second result set** showing which table modes B, C and D would each rank first, with the IO / skew / spill figures side by side. Never changes the primary result set. |
| `@TargetObjectName` | NULL | Scope the whole run to one object. |
| `@IncludeAdHocAndDynamicSQL` | `0` | Widen the intake to `object_id = 0` statements. |
| `@LookbackDays` | `14` | Query Store window. |
| `@MinimumSeverityScore` | `0` | Hide rows scoring below this. |
| `@AI` | `2` | `2` builds the `[AI Prompt]` column; `0` skips it but still emits the column (shape never changes); `1` deliberately aborts -- it would need a stored API credential. |
| `@AIPromptIncludePlanXml` | `1` | Embeds the execution plan in the prompt: this row's last actual plan when it is the plan in cache, otherwise Query Store's compile-time plan. A plan over `@AIPromptPlanXmlMaxChars` (30000) is left out and the prompt says so -- never truncated. Set `0` to leave the plan in its column. |
| `@JoinColumnKeyPolicy` | `'S'` | `S` makes only seek-worthy or order-supplying join columns index keys; `A` restores the older behaviour where every join column was a key. |

---

## Step 3 -- read result set 1 (one row per candidate access path)

Rows are ordered worst-first by `SniffingSeverityScore`. Read a row in these
groups.

**1. Identity** -- `object_name`, `query_id`, `plan_id`, `query_hash`,
`query_sql_text`, `CacheLastExecutionTime`, `CacheActualPlanAvailable`.

**2. Severity** -- `SniffingSeverityScore`, `SniffingSeverityBand`
(`Low` / `Medium` / `High` / `Critical`), `SniffingSeverityScoreCeiling`,
`SignalsUnavailable`. **Read the score against its ceiling, not against 100** --
a ceiling below 100 means some signals could not be evaluated on this row, so a
low score can be absence of evidence rather than evidence of absence.

**3. Stability matrix** -- one column per signal, each
`Stable` / `Unstable` / `Unavailable` / `N/A`:
`PlanStability`, `PlanShapeStability`, `MemoryGrantStability`,
`ParallelismStability`, `OperatorSkewStability`, `SpillStability`,
`IOVarianceStability` -- plus `SniffingSeveritySignals` (the same signals
collapsed into one readable list) and `MemoryGrantFeedbackState` /
`MemoryGrantFeedbackNote` (whether the engine has already corrected this plan's
grant, so an `Unstable` can be judged).

**4. Remediation** -- `PlanForcingCandidate`, `SuggestedRemediationPath`,
`RootCauseHint`, `RecommendedRecompileSQL` (commented-out, frequency-gated).

**5. Runtime rollup and estimate-vs-actual** -- `TotalExecutions`,
`AvgLogicalReads`, `AvgDurationMs`, `PlanCount`, `WorstPlanAvgIO` /
`BestPlanAvgIO` / `IOVarianceRatio`, then `EstimatedRows` vs `CacheActualRows`,
`EstimatedMemoryGrant` vs `CacheActualMemoryGrant`, and the parallelism flags.

**6. Which cardinality estimator produced those estimates** --
`DatabaseCompatibilityLevel`, `LegacyCEDatabaseSetting`,
`PlanCardinalityEstimationModel`, `MixedCEModelAcrossPlans`,
`PlanUsesLegacyCE`. Read this group before you read group 5 as evidence of
sniffing. `PlanUsesLegacyCE = 'Yes'` means this plan's row estimates came from
the 2012-era model (CE 70), which reaches a plan three ways -- the database sits
at compatibility level 100 or 110; `LEGACY_CARDINALITY_ESTIMATION` is ON for the
database, **which forces model 70 at any level, 170 included** (measured); or the
statement itself carries `USE HINT('FORCE_LEGACY_CARDINALITY_ESTIMATION')` or
trace flag 9481. So a database can report compatibility level 160 and still have
every estimate produced by the old model, and only `LegacyCEDatabaseSetting` and
`PlanUsesLegacyCE` say so. Under CE 70 the estimate-derived readings --
`OperatorSkewStability`, `MemoryGrantStability`, `IOVarianceRatio` -- fire more
often for estimator reasons than for parameter sniffing (measured on this
project's own workload: 16 rows read skew `Unstable` under CE 70 against 12 under
CE 150). Nothing is suppressed on that account -- the legacy estimator is not
always the wrong one -- so the `[AI Prompt]` caveat names the cause and points
you at the ESTIMATE vs ACTUAL figures. `MixedCEModelAcrossPlans` is the related
warning that this statement's plans were not all compiled by the same model, so
their `EstimatedRows` are not comparable with each other.
`LegacyCEDatabaseSetting` describes the **analysed** database, not the utility
database the procedure runs from.

**7. The index recommendation** -- `TableSchemaRaw` / `TableNameRaw`,
`TableRank`, and `AccessNodeId` / `AccessPhysicalOp` / `KeyScope` /
`AccessPathsOnThisTable` (why the same table can appear on two rows -- two
different access paths need two different indexes). `AccessActualRows`,
`AccessActualIO` and `TotalActualIO` are NULL when the row's plan was not read
from an actual plan, and the two IO columns also when that plan recorded no
logical reads -- the last actual plan never does, so today they are always NULL.
NULL means not measured, never zero. Then
`BaseIndexKeyColumns`, `BaseIndexIncludeColumns`, `BaseIndexCreateSQL`,
`BaseIndexDropSQL`, `BaseIndexBasis`, `isXML`, `isJSON`.

**8. `[AI Prompt]`** -- the last column, an **XML cell**. Click it: SSMS opens
the prompt in its own window with the line breaks intact. Copy from there into
ChatGPT / Claude / Gemini / Copilot. (Copying the grid cell itself loses the line
breaks -- SSMS strips CR/LF from copied cells by default -- which is why it is
not plain text.) Every figure is labelled with where it came from:

- **Every plan the statement compiled to, side by side** -- `[PLAN]` the
  parameter values each plan was compiled for, serial or parallel, operators,
  warnings, missing-index hints; `[QS]` executions and the min / max / stdev of
  duration, CPU, reads and rows, plus DOP, memory and tempdb use.
- **The live plan cache** -- `[CACHE]` the cached plan's counters since it was
  cached (CPU, duration, reads, writes, rows, memory granted / used, spills, DOP)
  and `[ACTUAL]` its last actual plan -- and whether that cached plan is *this*
  row's plan. The cache is read first because it is what is running now; Query
  Store is read as well because it holds every plan and survives restarts. When a
  procedure repeats a statement (several statements with one `query_hash`) and
  the cache entry cannot be matched to the row with certainty, the prompt says it
  is **not matched** and why, and leaves the cache figures out rather than guess.
- **`[STATS]`** statistics freshness for the row's key and predicate columns.
- This script's findings and the caveats true for that row, and the execution
  plan XML.

"not captured" means the source had nothing -- never zero. The last actual plan
records actual rows and DOP but not the parameter values it ran with, so the
prompt shows compiled values only. The prompt asks the model for a diagnosis
and ONE first action with its T-SQL, rollback and a verification query. It makes
no outbound call itself.

### The other result set

With `@ShowModeComparison = 1` (default) a **second result set** follows: one row
per `(object, query_id, plan_id)` with the table modes B, C and D would each rank
first and the underlying IO / skew / spill numbers. The procedure also emits
`#SkippedDatabases` when `@AllDatabases = 1` skipped anything. Its reason names
every cause that applies, separated by `; ` -- a system database, not ONLINE, in
STANDBY, READ_ONLY, a database snapshot, Query Store not enabled, also named in
`@ExcludeDatabases`, or "it hosts this procedure" when
`@ExcludeHostingDatabase = 1` (the default) skipped the utility database.

---

## The generated SQL is text for review -- never live

`BaseIndexCreateSQL` / `BaseIndexDropSQL` and `RecommendedRecompileSQL` are
commented-out T-SQL. Copy, read, test, run it yourself. When `isXML` is set, read
`BaseIndexCreateSQL` as a pointer to *XML-index* guidance, not literal B-tree
text; `isJSON` (`TextTrap` / `NativeUncovered` / `NativeCovered`) is a similar
reinterpret-this flag.

The "base" index is the statement **in isolation** -- it does not look at what
else is on the table or who else queries it. Consolidating it against the
existing indexes is a separate step (see `usp_IndexAnalysis`).

---

## Limits (v1)

- **2016 floor** (Query Store). On 2016 the four actual-plan signals and
  wait-category disambiguation are `Unavailable`; on 2017 the four actual-plan
  signals are `Unavailable`; 2019+ / Azure SQL MI is full coverage.
- Analyses statements owned by procedures unless `@IncludeAdHocAndDynamicSQL = 1`;
  dynamic SQL cannot be attributed to its parent object.
- One row per **access path**, not per table. Modes B / C / D still pick a
  *table*.
- **Repeated statements.** When a procedure holds several statements with the
  same `query_hash`, a row keeps its plan-cache figures only when its own cached
  statement can be identified -- character-identical statements are ONE Query
  Store query, so theirs cannot -- and its actual plan only when the procedure's
  plan can be narrowed to that one statement. Otherwise `CacheActualPlanAvailable`
  is 0, the cache columns are empty, the row is analysed from Query Store's own
  plan for it, and the prompt says why.
- `@AI = 1` is unimplemented (no stored credentials); `@AI = 2` builds a prompt
  and makes no outbound call.
- The **script** needs `sqlcmd` / ADO.NET; `dbatools`' `Invoke-DbaQuery` cannot
  parse it. The **procedure** is fine through any client.
- Validated at database compat 150 on one SQL Server 2025 box; swept compat
  100-170 on that box, where the script and the procedure both run at every
  level. Below compat 130 a figure in the script's `[AI Prompt]` that sits on a
  rounding boundary can read one unit apart from the procedure's (0.48 against
  0.47): SQL Server rounds floats by an older rule there, and the script formats
  under the analysed database's level while the procedure formats under
  DBAdmin's. Not measured on a real Managed Instance -- detection is by engine
  name, so MI is expected to work but is not confirmed.
