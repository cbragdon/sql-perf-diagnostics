> **This release ships `usp_FindTimeoutStatementsNQueryStore` only.** The stand-alone stage 1
> script and the stage 3 Extended Events tooling are maintained privately, and the sections
> describing them have been removed from this copy.

# Finding the statements callers are timing out on

A developer reports a timeout. This family answers, in order: **which statements
callers abandoned** (stage 1), and **why that plan is unstable** (stage 2 = the
parameter-sniffing pair).

This document covers **stage 1** -- `Find-TimeoutStatements_N_QueryStore_v1.sql`
and its procedure form `DBAdmin.dbo.usp_FindTimeoutStatementsNQueryStore` -- and
where to go next. Stage 1 is always-on, needs no setup, and reads days of history
the engine already keeps. Start here.

| Stage | Tool | Needs |
|---|---|---|
| 1 | this doc | Query Store (on by default on MI / Azure SQL DB). Run any time. |
| 2 | `Paramsniffingdiagnostic_v1.sql` / `usp_ParameterSniffingDiagnostic` -- see `USAGE-Paramsniffingdiagnostic_v1.md` | Same Query Store. Run any time. |

---

## Before you start -- prerequisites (stage 1)

| # | You need | How to check | If missing |
|---|---|---|---|
| 1 | A connection to the **database the statement runs in** (integrated auth) | `sqlcmd -S <server> -d <db> -E -C -I -Q "SELECT DB_NAME();"` | Connect to that database. The script reads *that* database's Query Store; the procedure reaches others via `@DatabaseName`. |
| 2 | **SQL Server 2016 or newer**, and **Query Store** with history covering `@LookbackDays` | `SELECT actual_state_desc, desired_state_desc FROM sys.database_query_store_options;` | Below 2016 the pre-flight aborts. `READ_WRITE` and `READ_ONLY` are both readable; `READ_ONLY` just cannot record new aborts. |
| 3 | **VIEW DATABASE STATE** (or ownership) | you can already query `sys.query_store_runtime_stats` | Ask the DBA team for a role that has it. |
| 4 | *(optional)* **`WAIT_STATS_CAPTURE_MODE`** ON for the wait columns | `SELECT wait_stats_capture_mode_desc FROM sys.database_query_store_options;` = `ON` | Without it `TopWaitCategory` and the other wait columns are NULL. Everything else still works. |
| 5 | A client: `sqlcmd`, ADO.NET, **or `dbatools`** | -- | This script builds no `/* */` text, so `Invoke-DbaQuery` runs it and the procedure without the parser problem the parameter-sniffing script has. |

---

## Step 1 -- run the finder

### As the procedure

```sql
EXEC DBAdmin.dbo.usp_FindTimeoutStatementsNQueryStore
     @DatabaseName = 'AdventureWorks2019';
```

Every result set gains a leading `DatabaseName` column. The warnings the script
`PRINT`s become a `#PreflightNotes` result set instead (a `PRINT` does not
reliably reach a caller sweeping many databases). Fleet use: `@AllDatabases = 1`
with `@IncludeDatabases` / `@ExcludeDatabases` / `@ExcludeHostingDatabase`;
databases asked for and not analysed appear in `#SkippedDatabases`, whose reason
names every cause that applies, separated by `; ` -- a system database, not
ONLINE, in STANDBY, READ_ONLY, a database snapshot, Query Store not enabled, also
named in `@ExcludeDatabases`, or "it hosts this procedure" when
`@ExcludeHostingDatabase = 1` (the default) skipped the utility database.

### The parameters

| Parameter | Default | What it does |
|---|---|---|
| `@LookbackDays` | `7` | How far back to look. |
| `@MinAbortedExecutions` | `1` | Raise to hide one-off aborts and keep only repeat offenders. |
| `@TopN` | `50` | Row cap, worst max duration first (per database in the procedure). |
| `@IncludeExceptionAborts` | `0` | `1` also returns `execution_type = 4` (errors, `ABORT_QUERY_EXECUTION`), counted separately so a mixed statement is not misread as a pure timeout. |
| `@TargetObjectName` | NULL | Scope to one object (a typo aborts, rather than returning an empty set). |
| `@IncludeSecondaryReplicas` | `1` | Label aborts that occurred on an AG secondary (`AbortReplicaRole`). |

---

## Step 2 -- read the result set (one row per aborted plan)

> **Worked example:** [EXAMPLE-TimeoutCauses.md](EXAMPLE-TimeoutCauses.md) runs four statements
> that are each aborted by a client at three seconds and shows the finder attributing each to a
> *different* cause -- CPU starvation, blocking, a cold cache and memory-grant queueing -- with
> real output, how each condition was produced, and what the abort counts do and do not mean.

**What counts as a timeout:** `execution_type = 3` -- a *client-initiated*
aborted execution. The client (application, driver, SSMS) gave up; the server was
still working. The same statement can also have completed successfully at other
times -- that ratio is the point, not a contradiction.

Columns, by group:

- **Identity** -- `object_name`, `query_id`, `plan_id`, `query_sql_text`,
  `QueryPlanXml`, `StatementSubTreeCost`, `PlanCompatModel`.
- **Abort counts** -- `AbortedExecutions`, `ExceptionAborts`, `ClientAborts`.
- **The most recent abort, as one event** -- `LastAbortStartTime` (derived from
  the recorded end time minus that execution's duration), `LastAbortEndTime`,
  `LastAbortDurationMs`.
- **`CompletionPattern`** -- "Also completes -- N successful run(s)" versus
  "Never completed in this window". The former is the classic parameter-sniffing
  signature.
- **Duration scope** -- `StatementMaxDurationMs` / `StatementAvgDurationMs` /
  `StatementMaxCpuMs` are **one statement's** numbers. `DurationScopeNote`
  explains what that covers; `PrecedingStatementCount` /
  `PrecedingStatementsAvgMs` add the part of a multi-statement call that ran
  *before* the blamed statement; `ObjectAvgTotalMs_Approx` is order-of-magnitude
  only.
- **Waits** -- `TopWaitCategory`, `TopWaitTotalMs`, `TopWaitMaxMs`, `AllWaitMs`
  (NULL when wait capture is off).
- **`PlansForThisQuery`** -- more than one plan is what stage 2 scores.
- **`NextStep`** -- either "Multiple plans exist -- run
  Paramsniffingdiagnostic_v1.sql and look up query_id N" or "Single plan -- a
  timeout here is less likely to be parameter sniffing".
- **`AbortReplicaRole`** -- `PRIMARY only` / `SECONDARY only` /
  `PRIMARY + SECONDARY` (you cannot create an index on a secondary, so the
  remediation differs).

---

## Step 3 -- follow `NextStep`

- **Multiple plans** -> stage 2. Run `Paramsniffingdiagnostic_v1.sql` /
  `usp_ParameterSniffingDiagnostic` scoped to that object
  (`USAGE-Paramsniffingdiagnostic_v1.md`), then find the `query_id` this row
  handed you. The hop key from stage 1 to stage 2 is `query_id`.

---

## Facts worth knowing before you quote a number

- **Query Store keeps one `runtime_stats` row per `(plan_id, execution_type,
  interval)`.** `AbortedExecutions` counts every abort, but every `LastAbort*`
  column describes only the *last* abort in an interval -- never a specific
  incident. At the default 30-60 minute interval this bites constantly.
- **`ExceptionAborts` reads 0 unless `@IncludeExceptionAborts = 1`.** With the
  default, `ClientAborts` equals `AbortedExecutions` -- neither column carries
  extra information.
- **`StatementsInObject` can include superseded statement versions** after a
  `CREATE OR ALTER` -- Query Store keeps the old `query_id` until it ages out.
  Verify against the current procedure body. `PrecedingStatementCount` excludes
  superseded versions; it is the trustworthy one.
- **Query Store has no `session_id` / `request_id`.** Statements cannot be tied
  to a specific call. Timestamp-adjacency matching was built, measured over 22
  runs, and rejected -- less accurate than plain averages.

---

## Limits (v1)

- **2016 floor** (Query Store). Wait columns need `WAIT_STATS_CAPTURE_MODE` ON
  (2017+).
- Per **statement**, not per call. A multi-statement procedure's total wait is
  approximated (`PrecedingStatements*`, `ObjectAvgTotalMs_Approx`).
- Current tag `v1.1-timeout-family`; the fixture family passes 18/18; database
  compat 100-170 swept on one SQL Server 2025 box
  (`TestRunners/Test-TimeoutCompatLevels.ps1`, 8/8). Not measured on a real
  Managed Instance -- detection is by engine name, so MI is expected to work but
  is not confirmed.
