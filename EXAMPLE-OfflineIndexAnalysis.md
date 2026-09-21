# Worked example -- index advice from a plan file, with no server

Someone sends you a `.sqlplan` from production. You cannot reach that instance, or you can but you
would rather not run anything against it yet. What can be said about indexing from the plan alone?

Quite a lot, as it turns out -- and this example is also about where that stops, because the line
between "read from the plan" and "needs the server" is the whole point.

## The query

```sql
SELECT TOP (5000) th1.TransactionID,
       (SELECT TOP (1) th2.ActualCost
        FROM   Production.TransactionHistory th2
        WHERE  th2.Quantity = th1.Quantity       -- no index on Quantity
        ORDER BY th2.ActualCost DESC) AS TopCost
FROM   Production.TransactionHistory th1;
```

A correlated subquery filtering on a column with no index behind it. Nothing about that is
visible in the text -- you have to look at what the optimizer did about it.

```bash
# fully offline: reads a file, contacts nothing
python ComparePlans_v1.py --single f14_eager_spool_a.sqlplan --color always
```

![Offline anti-pattern check with a synthesised index, followed by the optional live index
analysis cross-check](images/compareplans-index-offline.png)

## What the plan alone gives you

1. **`EAGER_INDEX_SPOOL` -- SQL Server builds a temporary index over 113,463 rows at run time,**
   because no permanent index covers the `Quantity` lookup. It builds that index, uses it, throws
   it away, and does it again on the next execution. The build *is* the query's cost: 274,531
   logical reads to return 5,000 rows.
2. **The permanent index that spool stands in for, with its rollback.** The keys and `INCLUDE`
   are not guessed -- they are read out of the spool's own definition, which is SQL Server
   describing the index it wished existed. The `WITH (FILLFACTOR = 90)` is this project's default,
   not the plan's, and is adjustable with `--fill-factor`.

Both of those came from an XML file on your laptop. No connection, no permission, no load on the
instance, and nothing that has to wait for a change window.

## Where offline analysis stops

The plan can tell you what *this* query wanted. It cannot tell you anything about the table:
whether an index already exists that nearly covers this, whether the table is carrying ten indexes
already, whether anything else reads the column, or whether some *other* index has become dead
weight. That needs the catalog and the usage DMVs, which means the server.

```bash
# the optional second step -- now it does connect
python ComparePlans_v1.py --single f14_eager_spool_a.sqlplan \
       --analyze-indexes localhost --utility-db DBAdmin
```

3. **The tool marks the boundary itself.** The section is labelled *live*, and it warns that it
   reads the **current** catalog while the plan you handed it was captured earlier -- the table's
   indexes may have changed in between. That caveat is the tool refusing to let you conflate two
   different moments in time.
4. **Instance uptime, because two of the findings depend on it.** `DROP-USAGE` and the
   missing-index suggestions ride on DMVs that reset on service restart. Eleven days clears this
   project's seven-day floor, so the usage counters below are worth trusting. Under a week they
   would be withheld and the row would carry `TOOSOON` instead -- a statement about the evidence,
   not about the index.
5. **A finding that has nothing to do with your query.**
   `IX_TransactionHistory_ReferenceOrderID_ReferenceOrderLineID` is 2.45 MB of index serving
   **0 seeks, 0 scans, 0 lookups** -- and it is on the same table you were about to add an index
   to. You would never have found it from the plan, because your query never touches it. The
   `DROP INDEX` comes with a reconstructed `CREATE` above it so the change is reversible; that
   `CREATE` is rebuilt from the catalog, and the tool lists what it cannot recover (fill factor,
   compression, filegroup placement).
6. **The indexes already there.** Three on the table, two needing no action. This is the check
   the offline half cannot make: your proposed `(Quantity) INCLUDE (ActualCost)` does not overlap
   `PK_TransactionHistory_TransactionID` or `IX_TransactionHistory_ProductID`, so it is genuinely
   new rather than a near-duplicate of something already being maintained.

## The shape of the workflow

Offline gets you a *candidate*, immediately, from a file someone emailed you. The live step turns
that candidate into a decision by putting it next to everything else on the table. Both halves
emit commented-out DDL and neither one runs anything -- a person reads it and decides.

If the live step fails -- no `sqlcmd`, server unreachable, `usp_IndexAnalysis` not installed --
the section reports the error and the exit code stays `0`. The offline analysis above it is
unaffected, because it never needed the server in the first place.

Back to [USAGE-ComparePlans_v1.md](USAGE-ComparePlans_v1.md).
