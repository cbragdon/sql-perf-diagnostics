> **Scope note for this release.** Stage 1 ships as the stored procedure `usp_FindTimeoutStatementsNQueryStore`.
> The Extended Events tooling is maintained privately and is not included; the sections that
> instructed you to run it have been removed. Extended Events is still referred to in places as
> a technique -- that discussion stands on its own and needs none of this project's scripts.

# Troubleshooting: Client Aborted Timeout Issues in SQL Query

## Overview

This page covers triaging a report that a SQL Server request stopped running because the client
gave up waiting on it — not a server-side failure, though it's usually reported as one. It covers
what "aborted" actually means, the three things a request is typically stuck on, a fixed
three-stage procedure for finding the cause, and how to decide whether the root cause is parameter
sniffing.

## Symptoms

- Application or driver reports a timeout error, most commonly:
  - .NET / SqlClient: `Execution Timeout Expired. The timeout period elapsed prior to completion
    of the operation or the server is not responding.`
  - ODBC: `[HYT00] Timeout expired`
- Intermittent — the same call usually completes normally.
- Nothing corresponding shows up as a SQL Server error in the log, because nothing on the server
  actually failed (see "What 'timeout' actually means," below).
- Often reported as "the database is slow" or "the database timed out," whether or not the
  database turns out to be the actual cause.

## Scope

Applies to any SQL Server instance or Azure SQL Managed Instance with Query Store enabled
(`ALTER DATABASE ... SET QUERY_STORE = ON` — off by default after a restore). The scripts
referenced below detect platform and feature capability directly rather than gating on a version
number, so they run the same way on-box and on Managed Instance.

## What "timeout" actually means on the server side

It doesn't mean SQL Server refused the request. It means **the client stopped waiting**: the driver
gives up after 30 seconds, sends an `attention` (cancel) to the server, and the request is torn
down mid-wait, whatever it was waiting on.

The common explanation — "it exceeded the lock timeout" — is usually not what happened.
`SET LOCK_TIMEOUT` defaults to **-1 (wait forever)**, and almost nothing sets it explicitly, so SQL
Server itself is typically not bounding the wait at all. The 30-second ceiling almost always belongs
to the client, not the server.

That's the exact signal both timeout finders key on — Query Store's `execution_type = 3` and
Extended Events' `attention` event are two views of the same moment. Neither tool can tell a real
driver timeout apart from someone clicking Cancel in SSMS, because that distinction never reaches
the server. A spike in aborts is evidence callers are giving up; the wait category below is what
tells you why.

## The three waits

### Lock — blocked behind another session

**Wait type:** `LCK_M_%`

Another transaction is holding a resource this request needs, and hasn't released it. The longer
that other transaction runs, the longer this one sits — with no server-side ceiling unless someone
configured one.

A blocked call we measured showed **3,006 ms of a 3,010 ms wait attributed to Lock — 99.9%
coverage.** That's the clean signature: almost the entire client wait explained by one category.
When you see a number like that, go find the blocker; the query plan isn't the story.

### Memory — waiting on a workspace memory grant

**Wait type:** `RESOURCE_SEMAPHORE` (also `CMEMTHREAD`, `CMEMPARTITIONED`, `MEMORY_GRANT_UPDATE`)

Not OS paging. This is SQL Server's memory grant queue — a query that needs workspace memory
for a sort or hash operation queues behind other queries until enough is available. A grant sized
too high by a bad cardinality estimate (the classic sniffing symptom) queues longer than it needs
to and can starve behind itself under concurrency.

We've confirmed this wait produces the same object_id/hash pair in both
`Find-TimeoutStatements_N_QueryStore_v1.sql` and the Extended Events finder — the cross-tool match
holds here too. This is also one of the seven signals
`Paramsniffingdiagnostic_v1.sql` scores directly: `@MemoryGrantVarianceThreshold` (25%) drives the
`MemoryGrantFeedbackState`/`MemoryGrantFeedbackNote` columns, so a memory-wait timeout is worth
running through the main diagnostic even if nothing else points at sniffing yet.

### CPU — usually invisible, and that's the tell

**Wait type:** `SOS_SCHEDULER_YIELD`

This is the one the standard explanation gets least right for SQL Server: CPU contention doesn't
show up as one long wait. A CPU-bound request yields the scheduler constantly, but each yield is
sub-millisecond. Measured on this instance: capturing every wait for 90 seconds produced **zero**
`SOS_SCHEDULER_YIELD` events — the session's own duration floor discarded all of them.

So, **the absence of a qualifying wait is the CPU signature**, not a category you'll see named.
That's why both finders carry a `WaitCoveragePct` column: it's the percentage of the client's total
wait that the dominant category explains. One captured case shows the failure mode if
you skip that column: "Buffer IO" topped the category list at 105 ms, but against a 3,012 ms call
that's **3.5% coverage**. The request wasn't waiting on IO; it was running,
CPU-bound, on a self-join, and the biggest of several tiny noise waits won the label by default.
Under roughly 25% coverage, read the category as noise and look at duration instead.

(Query Store's own wait reporting doesn't have this blind spot — it sums wait time per category
regardless of how small each individual wait was, so it *can* report "CPU" directly. The two tools
measure differently on purpose — see "Reading the Finders' Output" below.)

## Quick reference

| Category | Wait type(s) | What it means | Next step |
|---|---|---|---|
| **Lock** | `LCK_M_%` | Blocked behind another session | Find the blocker |
| **Memory** | `RESOURCE_SEMAPHORE` | Queued for a workspace memory grant | Check memory grant variance in the main diagnostic |
| **CPU** | `SOS_SCHEDULER_YIELD` | Rarely captured directly — low `WaitCoveragePct` with high duration is the tell | Look at the plan's cost, not the wait list |
| Buffer IO | `PAGEIOLATCH_%` | Waiting on a physical page read | Check for a missing index / cold cache |
| User Wait | `WAITFOR` | Not a server wait at all — a script-authored delay | Only Extended Events sees this; Query Store has no row for it |

## Diagnostic Procedure

Two stages, in a fixed order, because each answers a different question:

1. **`Find-TimeoutStatements_N_QueryStore_v1.sql`** — always start here. Already on, holds days of
   history. Its `TopWaitCategory` and `WaitCoveragePct` columns are where the table above comes
   from. Read its `NextStep` column: it tells you directly whether stage two is warranted. On a
   multi-statement procedure, check `PctDurationBeforeAbortedStmt` before you tune anything — a
   high value means the statement named in the output is not where the caller's time went.
2. **`Paramsniffingdiagnostic_v1.sql`** — same source, asking *why* the plan is unstable. Run it
   when stage one shows more than one plan for the query (`NextStep` hands you the `query_id`).
   Every recommendation it produces is commented-out text for review, never auto-applied.

Match rows between stages on the right key: stage 1 → 2 by `query_id`. Never on object
name — a shared statement text between two different procedures
produces the same `query_hash` on purpose.

### Scoping a run to one object

Both stages take the same parameter. Leave it alone and you get every object, which is the
default and the original behaviour:

```sql
DECLARE @TargetObjectName NVARCHAR(776) = N'dbo.usp_GetOrders';
```

Bare, schema-qualified, and bracketed names all work — the name is resolved rather than
string-matched. Set it once per script; it scopes the entire run, not just the final result.

Four things worth knowing before you use it:

- **A typo aborts rather than returning nothing.** That is deliberate. An empty result from a
  misspelled name is indistinguishable from "this object never times out", and the second reading
  is the dangerous one. You will get a message naming the problem — wrong spelling, wrong schema,
  wrong database, or an object that exists but isn't a stored procedure.
- **Ad-hoc and dynamic SQL disappear from a targeted run.** They have no owning object, so there is
  nothing to target them by. This holds regardless of any include-ad-hoc setting.
- **The run prints its own scope.** Every run says either `--- Scope: ALL objects` or
  `--- Scope: SINGLE OBJECT -- [dbo].[...]`, so output pasted into a ticket without its parameters
  cannot be mistaken for a full sweep.

### Asking an AI for a second opinion

Stage two's last output column is `AI Prompt`, an XML cell. Click it and SSMS opens the prompt in
its own window; copy it from there into ChatGPT, Claude, Gemini, Copilot or whatever your team uses.
(Do not copy the grid cell itself — SSMS strips the line breaks from copied cells by default, and the
prompt arrives as one unreadable line.) No setup, no API key, and nothing leaves the server on its
own — the column is only ever text sitting in a result set.

What makes it worth more than describing the problem in your own words is that the prompt carries
the EVIDENCE, not just the tool's conclusions, and says where every figure came from: every plan the
statement has compiled to, side by side, with the parameter values each was compiled for, whether it
ran parallel, and the spread of its duration, CPU, reads and rows from Query Store; what the plan
cache holds right now, read first because it is what is running; statistics freshness; the execution
plan itself; and then the tool's findings for that row — severity against its ceiling, the
seven-signal stability matrix, the index columns the plan implies — plus only the caveats that are
actually true for that row. It asks the model for a diagnosis and ONE first action with its T-SQL,
the T-SQL that rolls it back, and a query that proves it worked, and to name anything that looks
internally inconsistent, which is often the most useful thing it says.

Three things to settle before the team starts using it:

- **Check what you are allowed to paste.** The prompt embeds the statement text, and statement text
  routinely carries table names, column names and sometimes literal values from the workload. It
  also embeds the execution plan by default, which carries more schema detail again and the
  parameter values each plan was compiled for; set `@AIPromptIncludePlanXml = 0` to leave the plan
  out. That is your organisation's data going into a third-party service. Clear it against
  your data-handling policy before it becomes habit — of everything in this chain, this is the only
  step that sends anything outside the building.
- **The answer is not authority.** It is a second opinion from something that cannot see your
  instance, your workload or your release calendar. Everything stage two recommends is still
  commented-out text for a human to review, and a model agreeing with it does not change that.
  Treat a confident answer with exactly the suspicion you would give a confident junior.
- **The plan is not included by default.** That is deliberate — stage two returns one row per
  access path, so embedding the plan would repeat it on every row. The prompt says so and points
  at the `EstimatedPlanXML` column on the same row. Paste it alongside if you want the plan itself
  read, subject to the first bullet.
- **Two prompts for the same table are not the same question.** Each covers one access path and
  implies a different index. The prompt names its access path and says outright that the others are
  not repeats, so an AI reading them one at a time will not conflate them — but if you paste
  several at once, keep them separate or you will get advice that merges indexes the plan needs
  kept apart.

The column is populated on **every** row, always, so a blank cell means something is wrong rather
than "nothing to say about this one". `@AI = 0` turns generation off while still emitting the
column, so the result-set shape never changes. `@AI = 1` exists in Brent Ozar's `sp_BlitzCache`,
where it calls the AI provider's API from inside SQL Server — it is deliberately **not** implemented
here and will abort if you set it, because it would mean storing a provider API key in a
database-scoped credential.

## Reading the Finders' Output

Both finders report `AbortedExecutions`, `ClientAborts`, and `ExceptionAborts`, and the numbers
disagree between them. Neither is wrong — they're counting different things.

These are two recorders pointed at the same event, running on different sampling rules. The
columns share names because they share a *concept*, not because they share a *measurement*.
Before any single column makes sense, two things have to be settled: what one **row** represents,
and what **window** it was counted over. Those differ between the tools and explain most of the
gap on their own. The rest of the gap is that two of the four columns genuinely measure different
quantities.

### What one row represents

Check this first — it usually means you're not comparing like with like even before you look at a
number.

**Query Store: one row per plan.** A procedure the optimizer built three plans for produces three
rows, each carrying its own counts. That's deliberate — when a proc times out on one plan and runs
fine on another, splitting the rows is what makes the sniffing visible. (Counts statement
executions.)

**Extended Events: one row per object.** That same procedure is a single row, with all three
plans' aborts added together. Extended Events has no plan identity to split on, so it reports at
the level it can actually see. (Counts calls — one per client give-up.)

So the Extended Events figure for a procedure is normally the *sum* of its Query Store rows, not a
match to any one of them. Underneath that, the unit differs too: Query Store counts how many times
a **statement** was aborted, Extended Events counts how many times a **caller** gave up. One abort
of a five-statement procedure is a single call in Extended Events, and lands against whichever
statement happened to be running in Query Store.

### What window it counted over

**Query Store: a time window** — seven days by default (`@LookbackDays = 7`), cut short by
whatever retention actually holds. Always on; it was already recording before anyone noticed a
problem, which is the whole reason to start there.

**Extended Events: a size window** — whatever currently fits in the ring buffer, and the session
must already be running. Not a period of time at all: it holds the most recent events, drops the
oldest under pressure, and is emptied when the session stops. Two runs minutes apart can
legitimately report different totals.

The practical consequence: the two tools almost never hold the same set of events, so an exact
match between their totals would be the coincidence, not the expectation.

### The columns, one at a time

**`AbortedExecutions`** — in both tools this is the headline number: how often this thing was
given up on. The difference here is only the grain and window above.
*Verdict: compare with care — sum the Query Store rows for one object first, and even then expect
the windows to differ.*

**`ClientAborts`** — tells you nothing in either tool as currently configured.
- Query Store: a real breakdown, but the filter feeding it only admits client aborts in the first
  place (`@IncludeExceptionAborts = 0` by default), so it always equals `AbortedExecutions` unless
  someone turns exception aborts on.
- Extended Events: identical to `AbortedExecutions` by construction — literally the same
  `COUNT(*)` expression twice. Nothing can enter the result set without a client abort, because a
  client abort is the event the whole query is driven from.
- *Verdict: carries no information — equal to `AbortedExecutions` in both tools under the
  defaults.*

**`ExceptionAborts`** — same name, two unrelated quantities, and the one most likely to be misread
in a meeting.
- Query Store: executions that ended in an error *instead of* a client cancel. Mutually exclusive
  with `ClientAborts` — the two split the total between them and always add up to it. Off by
  default, so in practice it reads zero.
- Extended Events: error messages raised *during* calls that were aborted. Additive, not exclusive
  — one aborted call can raise several errors or none, so this column can exceed
  `AbortedExecutions` several times over with nothing wrong.
- *Verdict: never comparable — a partition of the total in one tool, an overlapping count in the
  other.*

**`IntervalsAffected` and `MinutesAffected`** — different names because they're different units,
deliberately.
- Query Store `IntervalsAffected`: how many collection buckets contained an abort. The bucket is
  whatever that database's interval length is set to — thirty minutes on this instance — and
  lands on a fixed grid, not on the abort's own clock.
- Extended Events `MinutesAffected`: how many distinct wall-clock minutes contained an abort. A
  fixed, self-explanatory unit that means the same thing on every server.
- Twenty aborts spread across twenty-five minutes reads as **1** interval and up to **20**
  minutes. Worse, the ratio isn't fixed: Query Store's bucket size is a per-database setting, so
  identical activity on a differently-configured server produces a different number.
- *Verdict: never comparable — about 30× apart on this instance, and the factor changes per
  database.*

### How much of the wait happened before the blamed statement

Four columns, Query Store finder only. They exist because of a structural blind spot: **Query Store
records durations per statement, not per call.** For a multi-statement procedure, the only
statement marked as aborted is the one that happened to be running when the client gave up. The
statements that ran before it completed normally and are filed separately — so
`StatementMaxDurationMs` describes one statement, not what the caller waited.

| Column | What it is |
|---|---|
| `PrecedingStatementCount` | How many statements run *before* the aborted one in the same procedure body. 0 means single-statement, and the statement's duration genuinely is the wait. |
| `PrecedingStatementsAvgMs` | Their combined typical duration. |
| `AccountedStatementMsAvg` | That plus the aborted statement's own duration. |
| `PctDurationBeforeAbortedStmt` | Share of accounted time that ran *before* the statement Query Store blamed. |

**`PctDurationBeforeAbortedStmt` is the one to read first on any multi-statement procedure.** A
high value means the statement named in the output is not where the caller's time went, and tuning
it will not fix the timeout. One measured case: 57.3% — the aborted statement accounted for
1,239 ms of a 2,901 ms total, so the majority of the wait was already spent before it started.

Three things to know before quoting these numbers:

- **"Duration", not "wait" — deliberately.** These are elapsed time, from the same source as
  `StatementAvgDurationMs`. They are *not* wait-stat time and must not be read like
  `WaitCoveragePct`. A CPU-bound preceding statement contributes its full duration while waiting on
  nothing at all.
- **`AccountedStatementMsAvg` is a floor, not the client's wait.** It sums statement durations only.
  The caller also pays call setup, parse, and the gaps between statements, none of which Query
  Store attributes to any statement — measured at 124–1,532 ms per call. The real wait is always
  larger. Extended Events measures it directly; this does not.
- **These are averages over the window, not one specific call.** Query Store holds no session or
  request identifier, so no column here can tie a preceding statement to a particular incident.
  Correlating by timestamp was tried, measured, and rejected — it was less accurate than the
  averages and a portion of its matches silently drew from a different call.

They are also better-scoped than the older `ObjectAvgTotalMs_Approx`, which sums *every* statement
Query Store holds for the object — including statements that run *after* the abort point and
statements belonging to superseded versions of the procedure. These four count only genuine
predecessors in the current procedure body.

### Column-by-column reference

| Column | Query Store counts | Extended Events counts | Verdict |
|---|---|---|---|
| `AbortedExecutions` | Aborted statement executions, per plan, over 7 days | Aborted calls, per object, over the ring buffer | Compare only after summing plans |
| `ClientAborts` | Same as `AbortedExecutions` under defaults | Same as `AbortedExecutions`, always | Carries no information |
| `ExceptionAborts` | Executions that errored *instead of* being cancelled — 0 by default | Errors raised *during* an aborted call — can exceed the abort count | Never comparable |
| `IntervalsAffected` | Distinct 30-minute collection buckets | — | Never comparable |
| `MinutesAffected` | — | Distinct wall-clock minutes | Never comparable |
| `PrecedingStatementCount` | Statements running before the aborted one | — | Query Store finder only |
| `PrecedingStatementsAvgMs` | Their combined typical duration | — | Query Store finder only |
| `AccountedStatementMsAvg` | Preceding + aborted statement — a **floor** on the client's wait | — | Query Store finder only |
| `PctDurationBeforeAbortedStmt` | Share of accounted time spent before the blamed statement | — | Query Store finder only |

### What "aborted" does and does not mean

Applies to both tools: an abort means **the client stopped waiting**. It does not mean SQL Server
failed, and it does not necessarily mean a timeout.

A command timeout expiring in the driver and a person clicking Cancel in SSMS send the engine an
identical signal. Neither tool can tell them apart, because the distinction never reaches the
server. A spike in these counts is evidence that callers are giving up — establish *why* before
reporting it as a timeout rate.

## Judging Whether It's Parameter Sniffing

These finders find *that* something is being abandoned. They don't diagnose *why* — stage two
does that, and this is how you decide whether running it is warranted.

You don't have to judge this yourself; the stage-one finder already decides, and writes the answer
in its `NextStep` column. When a query has more than one plan, `NextStep` reads *"Multiple plans
exist — run Paramsniffingdiagnostic_v1.sql and look up query_id N"*, with the `query_id` filled in
for you. When it has one, `NextStep` says so, and a timeout there is unlikely to be sniffing. Read
that column before forming an opinion.

The signals below are what to corroborate it with, and when to ignore the escalation entirely.

**Points toward sniffing:**
- **More than one plan.** `PlansForThisQuery` above 1 is the direct tell, and the one `NextStep`
  keys on. Plan-choice instability isn't possible with a single plan.
- **It usually works.** `CompletionPattern` reading "Also completes" is the classic shape — fine
  most of the time, occasionally catastrophic.
- **Plans disagree with each other.** Because Query Store gives one row per plan, a procedure
  whose plans don't all abort is showing the instability directly.
- **A wide duration spread.** `StatementMaxDurationMs` far above `StatementAvgDurationMs`.
  Corroborating, not conclusive — parameter values alone can do this without any plan change.

**Points somewhere else:**
- **One plan.** `NextStep` will tell you outright. Treat it as a tuning problem, not a sniffing
  one.
- **It never completes.** "Never completed in this window" is a different failure — the statement
  is wrong or the workload is, not the plan choice.
- **Lock waits dominating.** High `WaitCoveragePct` on a Lock category means blocking. Go find the
  blocker; the plan isn't the story.
- **Low wait coverage.** Under roughly 25%, the request was mostly running, not waiting. That's an
  expensive statement, and no plan swap will fix it.

## Resolution

- **Confirmed parameter sniffing** (stage two flagged it): remediation comes out of
  `Paramsniffingdiagnostic_v1.sql` as commented-out `CREATE INDEX`/`DROP INDEX`, recompile, and
  force-plan SQL. Review it and apply what's appropriate by hand — nothing here is meant to run
  unattended. If you want a sanity check on the key-column order or on which lever to pull, the
  `AI Prompt` column on that row is built for exactly that question — read *Asking an AI for a
  second opinion* first, particularly on what you may paste.

  **Expect more than one row per table, and do not treat them as duplicates.** Index
  recommendations are made per *access path*, not per table. A table read twice in one plan — a key
  lookup, or a self-join — gets a separate recommendation for each read, because they need
  different indexes. The classic case is an Index Seek feeding a Clustered Index Seek: one wants
  the seek column, the other wants the clustering key, and merging them produces a composite key
  that is only usable for its leading column. Read `AccessNodeId`, `AccessPhysicalOp` and
  `KeyScope` to tell the rows apart, and `AccessPathsOnThisTable` to see how many a table has.
  Ranking still selects a *table*; every access path of the selected table then gets a
  recommendation.
- **Not parameter sniffing**: route by whichever "Points somewhere else" signal matched, above —
  a blocker to find and address, an expensive query that needs tuning rather than a different
  plan, or a workload/statement problem that no plan change will fix.
- **The blamed statement is not the problem** (`PctDurationBeforeAbortedStmt` high): the aborted
  statement is a symptom of a call that was already nearly out of budget. Tune the preceding
  statements, or split the procedure so a long call is not gated by one client timeout. Tuning the
  statement the output names will not help.

## Related Scripts

- `Paramsniffingdiagnostic_v1.sql` — stage 2. Its last column, `AI Prompt`, is a ready-made
  prompt for an AI second opinion, carrying that row's evidence — every plan side by side, the
  plan cache and Query Store, statistics freshness, the execution plan — as well as its findings
  and caveats. Controlled by `@AI` (2 = build it, the default; 0 = skip it but still emit the
  column; 1 = refused, it would need a stored API key).

## Notes

Both blind spots described above are real, and neither is a defect: Query Store cannot see
non-DML aborts, and Extended Events cannot see further back than its buffer holds. That's why both
scripts exist. The behavior described here was measured against AdventureWorks2019 on the test
instance at compatibility level 150; the interval length quoted for `IntervalsAffected` is that
database's setting — confirm it per server with `sys.database_query_store_options`.
