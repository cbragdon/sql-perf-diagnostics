# Worked example -- the missing-index DMV proposes, the plan corrects it

SQL Server's missing-index suggestions are built from a query's *filters* and its *output
columns*. They do not consider `ORDER BY` or `GROUP BY` at all. So a suggestion can be perfectly
correct about which columns you need and still leave a Sort or a Hash Aggregate standing in the
plan -- it removed the lookup and stopped there.

This example shows the suggestion, and then the same columns reordered so the sort goes too.
Unlike [the offline example](EXAMPLE-OfflineIndexAnalysis.md), this one reads the live catalog and
Query Store: the correction needs to know which query drove the proposal.

## The query

```sql
CREATE OR ALTER PROCEDURE dbo.RealignDemo_Both @lt MONEY AS
BEGIN
    SET NOCOUNT ON;
    SELECT   OrderQty, ModifiedDate, COUNT_BIG(*) AS n
    FROM     dbo.RealignDemo
    WHERE    LineTotal = @lt          -- equality filter
    GROUP BY OrderQty, ModifiedDate   -- grouping
    ORDER BY ModifiedDate DESC        -- and a final order
    OPTION (ORDER GROUP);
END;
```

An equality filter, a grouping and an ordering -- three different demands on one index.

```bash
python ComparePlans_v1.py --single realign_demo_both.sqlplan \
       --analyze-indexes localhost --utility-db DBAdmin \
       --realign-missing-indexes
```

![Live index analysis with a missing-index proposal and the realigned key beneath it](images/index-realign.png)

## What it found

1. **A dead index, unrelated to your query.** `IX_RealignDemo_ProductID` is 1.76 MB serving
   **0 seeks, 0 scans, 0 lookups and 0 updates** -- pure maintenance cost. Your plan never touches
   `ProductID`, so nothing in the plan could have revealed it; it comes from the usage DMVs, and
   it comes with a reconstructed `CREATE` so the drop is reversible.
2. **The proposal from the missing-index DMVs:** key `[LineTotal]`, `INCLUDE (OrderQty,
   ModifiedDate)`, impact 2604.32. Correct as far as it goes -- it covers the query and removes
   the lookup.
3. **`query_id(s): 1472` -- which query asked for it.** This is the Query Store bridge, and it is
   the thing that makes the correction below possible: without knowing the driving query, there is
   no way to know what it sorts by. `sp_BlitzIndex` has no equivalent, because it does not read
   Query Store at all.
4. **The DMV's own `CREATE`, verbatim.** Build this and the key lookup disappears. The
   `GROUP BY` and `ORDER BY` still need a Sort, because nothing in the suggestion addresses them.
5. **`REALIGN` -- the same three columns, reordered.**

```sql
-- the DMV's suggestion
CREATE INDEX ... ON dbo.RealignDemo ([LineTotal]) INCLUDE ([OrderQty], [ModifiedDate]);

-- realigned
CREATE INDEX ... ON dbo.RealignDemo ([LineTotal], [ModifiedDate] DESC, [OrderQty]);
```

`ModifiedDate` is promoted out of `INCLUDE` into the key, **with its `DESC` direction**, and
`OrderQty` follows it. The filter still leads, so the seek is unchanged -- but the rows now arrive
already in the order the query wants, and the Sort is gone as well as the lookup.

## The detail worth pausing on

The key order did not come from reading the SQL text. Read naively, `GROUP BY OrderQty,
ModifiedDate` would suggest `OrderQty` first. The tool reads the **plan's own Sort operator**,
which in this plan is:

```
OrderBy: ModifiedDate   Ascending=0     <- DESC
OrderBy: OrderQty       Ascending=1
```

`OPTION (ORDER GROUP)` let the optimizer satisfy the grouping and the final ordering with a single
sort on `(ModifiedDate DESC, OrderQty)`, and the realigned key matches that exactly. Had the tool
trusted the query text it would have produced a key in the wrong order and the Sort would have
survived. **The plan is ground truth; the text is a description of intent.**

## Two impact numbers, two different scales

The plan's own hint reports `impact 64`; the DMV proposal reports `2604.32`. They are not
comparable and neither is a percentage of the other. A plan hint's impact is the optimizer's
estimated improvement for that one compilation; a DMV proposal's is cumulative across every
execution it has seen. **Rank proposals against each other within one source, never across.**

## What the tool says about its own advice

The section carries Microsoft's own caution, not this project's paraphrase of it: missing-index
suggestions *"aren't prescriptions to create indexes exactly as suggested"*, and are best treated
as one input among several. The REALIGN line is one more input, not a prescription either -- it
assumes the driving query is the one worth optimising for, and on a table serving many queries
that is a judgement only a person can make.

Everything above is commented-out text. Nothing was created, altered or dropped.

> **About the input.** The `.sqlplan` used here is one of this project's test fixtures, which are
> apparatus for its own equivalence gates and are not part of this release. The output above is
> real, not mocked. To follow along on your own query, capture an **actual** plan -- in SSMS,
> Ctrl+M then run and save the plan, or `SET STATISTICS XML ON;` and save the XML with a
> `.sqlplan` extension. An estimated plan is rejected: the analysis needs runtime numbers.

Back to [USAGE-ComparePlans_v1.md](USAGE-ComparePlans_v1.md) ·
[USAGE-IndexAnalysis_v1.md](USAGE-IndexAnalysis_v1.md).
