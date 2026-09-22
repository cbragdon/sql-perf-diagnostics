#!/usr/bin/env python3
"""
ComparePlans_v1.py -- compare 2 to 4 SQL Server ACTUAL execution plans so a
developer can tell, during development, which version of a query is better and
why, before it ships.

    python ComparePlans_v1.py before.sqlplan after.sqlplan
    python ComparePlans_v1.py "v1=a.sqlplan" "v2 covering idx=b.sqlplan" "v3 rewrite=c.sqlplan"
    python ComparePlans_v1.py a.sqlplan b.sqlplan --format md
    python ComparePlans_v1.py a.sqlplan b.sqlplan c.sqlplan d.sqlplan --emit-prompt
    python ComparePlans_v1.py --single one.sqlplan           # anti-pattern check, no comparison

Part of the parameter-sniffing / timeout / index-analysis diagnostic family, but
unlike the rest it is a single Python artifact (no stored-procedure twin, so no
cell-for-cell equivalence gate -- it is validated by fixtures instead). It reads
nothing but local plan files: no database connection, no Query Store, no cache.

Capture an actual plan with SSMS "Include Actual Execution Plan" (Ctrl+M) then
Save Execution Plan As, or with `SET STATISTICS XML ON`. An ESTIMATED plan is
rejected -- it has none of the runtime numbers the comparison is built on.

The verdict is advisory. A person reads it and decides. `--emit-prompt` appends
a block to hand to a Claude Code / Copilot CLI session running Erik Darling's
sqlserver-query-plans skill for the narrative read.

v1.2 adds a RECOMMENDATIONS section: each fired signal and each detected
anti-pattern (local variable, non-sargable predicate, implicit conversion,
eager index spool, ...) gets a deterministic, commented-out fix woven with the
plan's own numbers, plus a one-line recommended action per plan.

`--format text` prints the BRIEF report by default (verdict, recommendations,
recommended action, caveats). `--full` adds INPUTS, SIGNALS, and the leaf-access
/ structural / resource / timing tables. `--no-recommendations` implies `--full`
(v1.1-shaped output). `md` and `json` are always the full report.
`--dump-catalog` prints the fix catalog as Markdown; `--color auto|always|never`
adds ANSI colour to `--format text` (auto = only to a terminal; never for md /
json / --emit-prompt).

v1.7 adds `--analyze-indexes SERVER`: after a CREATE INDEX is generated, connect
to SERVER with sqlcmd and run DBAdmin.dbo.usp_IndexAnalysis for that table,
appending its DETAILED output so the proposed index can be judged against the
table's existing indexes. Integrated / Microsoft Entra auth only
(`--auth windows|entra|entra-interactive`) -- no password path, ever. The
connection is opt-in; without the flag the tool stays fully offline. A failure
there (server down, proc not deployed, sqlcmd missing) prints in the section and
the comparison still exits 0. The section lists the table's existing indexes and
any drop/realign actions; `--show-missing-indexes` adds the missing-index DMV
proposals after them (off by default -- they are workload-volatile), under a
light-blue caveat + link to MS "Tune nonclustered missing index suggestions":
the DMV output is one input to index design, not a prescription. With
`--realign-missing-indexes` a one-line gloss on what a REALIGN line means follows
the caveat.
`--realign-missing-indexes` (implies --show-missing-indexes; **--single ONLY**) adds
a `REALIGN -- CREATE INDEX` line under each proposal whose driving Query Store query
sorts or groups, reordering the key -- equality/filter, then GROUP BY, then ORDER BY
last -- so the Sort / Hash Aggregate is eliminated. It is rejected in a 2-4 plan comparison --
the realignment is a per-plan recommendation and a comparison has no single plan to
attribute it to; use `--show-missing-indexes` there instead. The REALIGN line is
renderer-built, so `--format json`'s raw grid blob does not carry it -- json
consumers get `missing_order_by_cols` / `missing_group_by_cols` / `missing_window_kind`
in the grid and build it themselves. When the driving query used a window function
(`missing_window_kind` = 'FPOC' with a WHERE filter, 'POC' without), the REALIGN
caveat names the realigned key as a windowing POC index (P = PARTITION BY, seen in
the plan as a Segment; O = OVER ... ORDER BY). An UNFILTERED window function raises
no missing-index hint at all -- `--single` then emits a `WINDOW_FN_NO_INDEX`
advisory instead (the POC index is not synthesised: OVER (PARTITION BY ...) parsing
is deferred).

`--single <plan>` runs just the deterministic anti-pattern checks on ONE plan --
eager index spool, local variable, non-sargable predicate, implicit conversion,
missing join predicate, no statistics, 1-row table variable -- with the catalog
fix and generated DDL, but no comparison and no verdict (there is no baseline).
It is the checklist half; "why is this plan slow" stays with the plugin
(`--single <plan> --emit-prompt`). `--analyze-indexes` and every output format
work in this mode too -- and in `--single`, `--analyze-indexes` also engages when
the plan carries the optimizer's own `<MissingIndexes>` hint (not only when an
eager index spool generated a `CREATE INDEX`), so any plan with a missing-index
suggestion can be analysed and its proposals realigned.

Every generated CREATE INDEX carries `WITH (FILLFACTOR = 90)` (house default);
`--fill-factor N` overrides it, `--fill-factor 0` or `100` omits the clause.

Depends on the vendored plan_extract.py (Erik Darling's extract.py, MIT, pinned).
Standard library only (subprocess is only reached by --analyze-indexes).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import textwrap
import xml.etree.ElementTree as ET

import plan_extract as px

NS = px.NS

# --- optional ANSI colour for --format text (never for md / json / --emit-prompt) ---
_ANSI = {
    "reset": "\033[0m", "bold": "\033[1m", "dim": "\033[2m",
    "red": "\033[31m", "green": "\033[32m", "yellow": "\033[33m",
    "magenta": "\033[35m", "cyan": "\033[36m", "orange": "\033[38;5;215m",  # light orange
    "white": "\033[37m", "lightblue": "\033[38;5;117m",  # light blue
}

# Shown under the missing-index proposals header (MS "Tune nonclustered missing index
# suggestions"): the DMV output is a hint, not a prescription.
_MISSING_INDEX_CAVEAT = (
    "Due to their limitations, missing index suggestions are best treated as one of several "
    "sources of information when performing index analysis, design, tuning, and testing. "
    "Missing index suggestions aren't prescriptions to create indexes exactly as suggested.")
_MISSING_INDEX_CAVEAT_URL = (
    "https://learn.microsoft.com/en-us/sql/relational-databases/indexes/"
    "tune-nonclustered-missing-index-suggestions?view=sql-server-ver17")
# One-line gloss on the REALIGN line, shown only when --realign-missing-indexes is on.
_REALIGN_BLURB = (
    "A REALIGN line below a proposal index is this tool's index alignment with the query "
    "text filtering, joins, and columns for it -- the same columns reordered so "
    "equality/filter leads, then GROUP BY, then ORDER BY as the last key column, so the "
    "driving query's Sort / Hash Aggregate is eliminated too, not just the lookup.")
# every wrapped line of the two blurbs above -- _colourise paints these light blue
_MI_BLURB_LINES = frozenset(
    textwrap.wrap(_MISSING_INDEX_CAVEAT, 96)
    + [_MISSING_INDEX_CAVEAT_URL]
    + textwrap.wrap(_REALIGN_BLURB, 96))


class _Colour:
    """c('text', 'green', 'bold') -> wrapped in ANSI, or plain when disabled."""

    def __init__(self, on):
        self.on = on

    def __call__(self, s, *styles):
        if not self.on or not styles:
            return s
        return "".join(_ANSI[x] for x in styles) + s + _ANSI["reset"]


def _want_colour(mode):
    """mode: 'auto' | 'always' | 'never'. auto = a real terminal on stdout."""
    if mode == "always":
        return True
    if mode == "never":
        return False
    if os.environ.get("NO_COLOR") is not None:      # https://no-color.org/
        return False
    try:
        return sys.stdout.isatty()
    except Exception:
        return False


_VERDICT_STYLE = {"BETTER": ("green",), "WORSE": ("red",),
                  "MIXED": ("yellow",), "~ SAME": ("dim",)}

# --- tunables (named, not buried) --------------------------------------------
COST_DOWN_FRACTION = 0.98      # "cost went down" = below this multiple of baseline
READS_UP_FRACTION = 1.05      # "reads went up"  = above this multiple of baseline
GRANT_CHANGE_MULTIPLE = 2.0   # granted memory grew/shrank by at least this factor
CE_SKEW_MIN = 10.0            # per-operator actual/est ratio that counts as "off"
READS_MATERIAL_FRACTION = 0.30  # a reads change this large (either way) is "material"
READS_MATERIAL_FLOOR = 500    # ...but ignore changes smaller than this in absolute reads
TIME_MATERIAL_FRACTION = 0.30  # elapsed/CPU change this large (either way) is "material"
TIME_MATERIAL_FLOOR_MS = 50   # ...but ignore changes smaller than this in absolute ms
SPILL_GREW_MULTIPLE = 2.0     # both plans spill, and this one's tempdb IO is this many x
LOOKUP_EXPLOSION_MIN = 1_000  # total key/RID-lookup executions that count as an explosion
LOOKUP_EXPLOSION_MULTIPLE = 2.0
THREAD_SKEW_MIN = 10.0        # busiest/quietest worker row ratio on a parallel operator
GRANT_OVERALLOC_MULTIPLE = 4.0   # granted this many x used ...
GRANT_OVERALLOC_FLOOR_KB = 5_000  # ...and at least this big (ignore tiny grants)
MIN_MEMORY_GRANT_KB = 1024   # 'min memory per query' default -- an Excessive Grant
                             # warning at or below this is the floor, not an over-estimate
INDEX_CHANGE_MIN_UPTIME_DAYS = 7   # usp_IndexAnalysis leans on DMV counters that reset on
                                   # restart; below this, DROP-USAGE / MISSING rows are not
                                   # trustworthy. A full business cycle (~4 weeks) is better.
DEFAULT_FILLFACTOR = 90   # house standard for every generated CREATE INDEX -- 10% leaf free
                          # space for splits. --fill-factor overrides; 0 / 100 omits the clause.
UDF_DOMINATES_FRACTION = 0.50    # scalar-UDF elapsed this share of total elapsed
DEFAULT_SMALL_DATA_ROWS = 10_000

# window-function operators -- a plan carrying one of these ran an OVER () clause
# (ranking -> Sequence Project; row-mode aggregate -> Segment; batch -> Window Aggregate).
_WINDOW_OPS = ("Sequence Project", "Segment", "Window Aggregate")

# --- v1.2 anti-pattern detection tunables -----------------------------------
TABLEVAR_JOIN_ROWS_FLOOR = 100   # a table var estimated at 1 row that really returned this many
# Rewind case only (LAZY_SPOOL_REWIND), not the recursive-CTE case: a recursive
# spool is informational regardless of rebind count (f22's own fixture rebinds only
# ~45 times and is still worth surfacing), but a REWIND spool's whole value is
# "is this rewinding enough to be a genuine concern" -- measured on f14's plan,
# 20 rebinds (post-fix, 'b') reads as trivial noise, 3,250 (pre-fix, 'a') does not.
LAZY_SPOOL_REBIND_FLOOR = 100
NONSARGABLE_FUNCS = ("CONVERT(", "CAST(", "SUBSTRING(", "LEFT(", "RIGHT(", "DATEPART(",
                     "UPPER(", "LOWER(", "LTRIM(", "RTRIM(", "ISNULL(", "COALESCE(",
                     "YEAR(", "MONTH(", "DAY(", "REPLACE(", "STUFF(")

# Which signals count for/against a version in the VERDICT tally.
_REGRESSION_CODES = {"COST_DOWN_READS_UP", "NEW_SPILL", "SPILL_GREW", "GRANT_GREW", "CE_MISS_WORSE",
                     "ACCESS_REGRESSED", "READS_UP", "SLOWER", "BATCH_MODE_LOST",
                     "LOOKUP_EXPLOSION", "THREAD_SKEW", "GRANT_OVERALLOCATED", "UDF_TIME_UP",
                     "NEW_LAZY_SPOOL_REWIND"}
# NEW_LAZY_SPOOL_RECURSIVE is deliberately NOT a regression code: it fires when a
# version's query is recursive and the baseline's is not (or recurses less), which
# can be the CORRECT shape, not a performance defect -- same "ship" framing as its
# single-plan counterpart LAZY_SPOOL_RECURSIVE. Still reported as a signal so the
# difference is visible; just not held against the version in the verdict tally.
_IMPROVEMENT_CODES = {"SPILL_RESOLVED", "GRANT_SHRANK", "ACCESS_IMPROVED", "READS_DOWN",
                      "FASTER", "BATCH_MODE_GAINED", "UDF_TIME_DOWN", "LAZY_SPOOL_RESOLVED"}


# ===========================================================================
# Per-plan load + model
# ===========================================================================

class PlanRejected(Exception):
    def __init__(self, label, path, reason):
        super().__init__(reason)
        self.label, self.path, self.reason = label, path, reason


def _leaf_objects(node):
    """(schema.table, index, alias) for every Object this operator names."""
    out = []
    for e in px.local_elements(node.el):
        if px.tag(e) != "Object":
            continue
        table = px.unbracket(e.get("Table", ""))
        if not table:
            continue
        schema = px.unbracket(e.get("Schema", ""))
        out.append((
            f"{schema}.{table}".strip("."),
            px.unbracket(e.get("Index", "")),
            px.unbracket(e.get("Alias", "")),
        ))
    return out


def _object_database(node):
    """The database the first real Object on this operator lives in, or None."""
    for e in px.local_elements(node.el):
        if px.tag(e) == "Object" and e.get("Database") and e.get("Table"):
            return px.unbracket(e.get("Database"))
    return None


def _is_leaf_access(node):
    p = node.physical
    return ("Scan" in p or "Seek" in p or "Lookup" in p) and not node.is_exchange


def _is_join(node):
    return node.physical in ("Nested Loops", "Merge Join", "Hash Match") and any(
        k in node.logical for k in ("Join", "Semi", "Anti")
    )


def _is_lookup(node):
    """Key Lookup / RID Lookup, or an IndexScan flagged Lookup='1' under a seek."""
    if "Lookup" in node.physical:
        return True
    for e in px.local_elements(node.el):
        if px.tag(e) in ("IndexScan", "RIDLookup") and e.get("Lookup") in ("1", "true"):
            return True
    return False


def _spill_tempdb_pages(node):
    """tempdb page IO (writes + reads) a spilling operator did. 0 if it did not spill."""
    total = 0.0
    w = node.el.find(NS + "Warnings")
    if w is None:
        return 0.0
    for el_name in ("SortSpillDetails", "HashSpillDetails", "ExchangeSpillDetails"):
        for s in w.findall(NS + el_name):
            total += px.num(s, "WritesToTempDb") + px.num(s, "ReadsFromTempDb")
    return total


def _worst_thread_skew(node):
    """(ratio, effectively_serial) for one operator's worker threads."""
    workers = [t["rows"] for t in node.threads if t["thread"] > 0]
    if len(workers) < 2:
        return 1.0, False
    hi, lo = max(workers), min(workers)
    if hi < 100:
        return 1.0, False
    idle = sum(1 for x in workers if x == 0)
    ratio = hi / lo if lo > 0 else float("inf")
    return ratio, idle == len(workers) - 1


def _index_from_spool(spool):
    """{table, keys, includes} for the permanent index an eager index spool stands in for.
    Keys come from the spool's own RangeColumns, INCLUDE from its OutputList."""
    keys = []
    for e in px.local_elements(spool.el):
        if px.tag(e) != "SeekPredicateNew":
            continue
        for rc in e.iter(NS + "RangeColumns"):
            for c in rc.findall(NS + "ColumnReference"):
                nm = px.unbracket(c.get("Column", ""))
                if nm and nm not in keys:
                    keys.append(nm)
    includes = []
    for c in (px.node_output_list(spool) or []):
        nm = c.split(".")[-1]
        if nm and nm not in keys and nm not in includes:
            includes.append(nm)
    table, rows = "(table)", 0.0
    stack = list(spool.children)
    while stack:
        n = stack.pop(0)
        objs = _leaf_objects(n)
        if objs:
            table, rows = objs[0][0], n.actual_rows
            break
        stack.extend(n.children)
    return {"table": table, "keys": keys, "includes": includes, "rows": rows}


class LoadedPlan:
    def __init__(self, label, path):
        self.label = label
        self.path = path

        try:
            root_el = px.load_plan(path)
        except OSError as e:
            raise PlanRejected(label, path, f"could not read the file: {e}")
        except ValueError as e:
            raise PlanRejected(label, path, str(e))
        except ET.ParseError as e:
            raise PlanRejected(label, path, f"not valid showplan XML: {e}")

        if px.tag(root_el) != "ShowPlanXML":
            raise PlanRejected(label, path,
                               f"parsed as <{px.tag(root_el)}>, not <ShowPlanXML> -- not a query plan")

        stmts = [e for e in root_el.iter()
                 if px.tag(e) == "StmtSimple" and e.find(NS + "QueryPlan") is not None]
        if not stmts:
            raise PlanRejected(label, path, "no statement with a query plan")
        if len(stmts) > 1:
            raise PlanRejected(
                label, path,
                f"{len(stmts)} statements carry a plan -- capture the one query in isolation "
                f"(a single SELECT, not a batch or a whole procedure)")

        stmt = stmts[0]
        qp = stmt.find(NS + "QueryPlan")
        root_relop = qp.find(NS + "RelOp")
        if root_relop is None:
            raise PlanRejected(label, path, "the statement's plan has no operators")

        self.stmt_el = stmt
        self.qp_el = qp
        self.root = px.Node(root_relop)
        self.nodes = px.flatten(self.root)
        self.has_actual = any(n.has_actual for n in self.nodes)
        if not self.has_actual:
            raise PlanRejected(
                label, path,
                "ESTIMATED plan -- no runtime counters. Capture the ACTUAL plan: SSMS "
                "'Include Actual Execution Plan' (Ctrl+M) then run, or SET STATISTICS XML ON.")

        self.build = root_el.get("Build", "?")
        self.query_hash = (stmt.get("QueryHash") or "").lower() or None
        self.query_plan_hash = (stmt.get("QueryPlanHash") or "").lower() or None
        self.ce_model = stmt.get("CardinalityEstimationModelVersion", "?")
        self.subtree_cost = px.num(stmt, "StatementSubTreeCost")
        self.statement_text = px.statement_text(stmt)

        dop = qp.get("DegreeOfParallelism")
        self.dop = dop
        self.is_serial = dop in (None, "0", "1")

        mg = qp.find(NS + "MemoryGrantInfo")
        self.granted_kb = px.num(mg, "GrantedMemory") if mg is not None else 0.0
        self.used_kb = px.num(mg, "MaxUsedMemory") if mg is not None else 0.0
        self.requested_kb = px.num(mg, "RequestedMemory") if mg is not None else 0.0

        self.total_logical_reads = sum(n.logical_reads for n in self.nodes)
        self.total_leaf_rows = sum(n.actual_rows for n in self.nodes if not n.children)

        # warnings / spills
        self.warnings = list(px.parse_warnings(qp))
        for n in self.nodes:
            for w in n.warnings:
                self.warnings.append(f"node {n.node_id} {n.label}: {w}")
        self.spills = [w for w in self.warnings if "spill" in w.lower()]

        # structural fingerprint
        self.joins = sorted(n.physical for n in self.nodes if _is_join(n))
        self.sort_count = sum(1 for n in self.nodes if n.physical == "Sort")
        self.spool_count = sum(1 for n in self.nodes if "Spool" in n.physical)

        # parameters
        self.parameters = []
        pl = qp.find(NS + "ParameterList")
        if pl is not None:
            for c in pl.findall(NS + "ColumnReference"):
                comp, run = c.get("ParameterCompiledValue"), c.get("ParameterRuntimeValue")
                if comp is None and run is None:
                    continue
                self.parameters.append((c.get("Column", "?"), comp, run))

        # v1.2: a @-ref used in the plan body with NO sniffed value -- local variable
        # or un-sniffed parameter -- means the optimizer used a fixed guess, not the
        # histogram. A true sniffed parameter carries a ParameterCompiledValue.
        _sniffed = set()
        if pl is not None:
            for c in pl.findall(NS + "ColumnReference"):
                if c.get("Column") and c.get("ParameterCompiledValue") is not None:
                    _sniffed.add(c.get("Column"))
        self.param_names = _sniffed
        _lv = set()
        for c in root_relop.iter(NS + "ColumnReference"):
            col = c.get("Column", "")
            if col.startswith("@") and not c.get("Table") and col not in _sniffed:
                _lv.add(col)
        self.local_variables = sorted(_lv)

        # missing indexes
        self.missing_indexes = []
        mi_root = qp.find(NS + "MissingIndexes")
        if mi_root is not None:
            for grp in mi_root.findall(NS + "MissingIndexGroup"):
                impact = px.num(grp, "Impact")
                for mi in grp.findall(NS + "MissingIndex"):
                    table = px.unbracket(f"{mi.get('Schema','')}.{mi.get('Table','')}").strip(".")
                    cols = []
                    for cg in mi.findall(NS + "ColumnGroup"):
                        # showplan gives these bracketed ([ProductID]); strip to bare
                        # identifiers so _ddl_from_missing_index builds a clean index
                        # name and key list, matching _covering_index_from_lookup.
                        names = [px.unbracket(c.get("Name", "")) for c in cg.findall(NS + "Column")]
                        cols.append((cg.get("Usage", "?"), tuple(names)))
                    self.missing_indexes.append((table, tuple(cols), impact))

        # leaf accesses, keyed by table with a repeat ordinal
        self.leaf_accesses = self._collect_leaf_accesses()

        # schema.table -> database (from the plan XML), for --analyze-indexes
        self.table_databases = {}
        for n in self.nodes:
            dbv = _object_database(n)
            if not dbv:
                continue
            for tbl, _idx, _al in _leaf_objects(n):
                self.table_databases.setdefault(tbl, dbv)

        # worst per-operator cardinality skew (for CE_MISS_WORSE)
        self.worst_skew = self._worst_skew()

        # --- v1.1: timing, spill magnitude, batch mode, lookups, thread skew, UDF ---
        qts = qp.find(NS + "QueryTimeStats")
        self.elapsed_ms = px.num(qts, "ElapsedTime") if qts is not None else None
        self.cpu_ms = px.num(qts, "CpuTime") if qts is not None else None
        self.udf_elapsed_ms = px.num(qts, "UdfElapsedTime") if qts is not None else 0.0
        self.udf_cpu_ms = px.num(qts, "UdfCpuTime") if qts is not None else 0.0

        self.spill_tempdb_pages = sum(_spill_tempdb_pages(n) for n in self.nodes)
        self.spill_level = max(
            (int(px.num(s, "SpillLevel"))
             for n in self.nodes
             for w in ([n.el.find(NS + "Warnings")] if n.el.find(NS + "Warnings") is not None else [])
             for s in w.findall(NS + "SpillToTempDb")),
            default=0)

        self.batch_operators = sum(1 for n in self.nodes if n.mode == "Batch")

        self.lookup_executions = sum(
            n.actual_executions for n in self.nodes if _is_lookup(n) and n.has_actual)

        skews = [_worst_thread_skew(n) for n in self.nodes if len(n.threads) > 1]
        self.worst_thread_skew = max((r for r, _ in skews), default=1.0)
        self.effectively_serial_ops = sum(1 for _, s in skews if s)

        self.grant_overalloc_ratio = (
            self.granted_kb / self.used_kb if self.used_kb > 0 else 0.0)

        # --- v1.2: anti-pattern detection off the plan XML ---
        # non-sargable predicate: a function/CONVERT on the filtered column inside a
        # SCAN leaf that has no seek predicate to fall back on.
        self.nonsargable = []
        for n in self.nodes:
            if not _is_leaf_access(n) or "Scan" not in n.physical:
                continue
            pred = px.node_predicate(n)
            if not pred:
                continue
            if any(f in pred.upper() for f in NONSARGABLE_FUNCS) and not px.node_seek_predicates(n):
                objs = _leaf_objects(n)
                self.nonsargable.append((objs[0][0] if objs else "(table)", pred, n.actual_rows))

        # A hashed GROUP BY hides what it groups by. Measured on a captured plan: a
        # Hash Match with LogicalOp="Aggregate" puts the grouping columns in
        # <HashKeysBuild> and the plan carries NO <GroupBy> element anywhere -- only a
        # Stream Aggregate writes one. Anything that shreds <GroupBy> to rebuild an
        # index key (usp_IndexAnalysis's realign shred) is blind to the grouping here.
        self.hash_agg_grouping = []
        # NB descendant search: <GroupBy> is a child of <StreamAggregate>/<Segment>,
        # not of the RelOp, so a direct find() here silently never matches.
        if not any(n.el.find(".//" + NS + "GroupBy") is not None for n in self.nodes):
            for n in self.nodes:
                # The physical-op half is belt-and-braces and provably redundant: a
                # Stream Aggregate has no <Hash>, and a Hash Match JOIN's LogicalOp is a
                # join, so "Aggregate" + <HashKeysBuild> already implies a hash aggregate.
                # Disclosed because a mutant dropping it survives the whole suite -- there
                # is no plan shape that can pin it, so it is not separately tested.
                if n.physical != "Hash Match" or "Aggregate" not in n.logical:
                    continue
                h = n.el.find(NS + "Hash")
                hk = h.find(NS + "HashKeysBuild") if h is not None else None
                if hk is None:
                    continue
                cols = [c.get("Column") for c in hk.findall(NS + "ColumnReference")
                        if c.get("Column")]
                if cols:
                    self.hash_agg_grouping = cols
                    break

        # eager INDEX spool (not table spool) + the permanent index that removes it
        self.eager_spool = None
        for n in self.nodes:
            if px.is_eager_index_spool(n):
                self.eager_spool = _index_from_spool(n)
                break

        # lazy spool (Table Spool or Index Spool, LogicalOp="Lazy Spool") -- rows
        # cached on demand rather than the whole input consumed up front. Skip a
        # stack replay of an earlier spool (px.is_lazy_spool_replay): a recursive
        # CTE's own reference to its accumulated working table is NOT a second
        # physical cache, and counting it as one would double-report.
        #
        # Classify by searching DESCENDANTS for a Concatenation, not ancestors --
        # confirmed against a real capture, not assumed: a recursive CTE's PRIMARY
        # spool (the one that survives the replay filter above) is the operator that
        # READS OUT the accumulated working table, so the recursion's own
        # Concatenation (UNION ALL of anchor + recursive member) sits BELOW it in the
        # tree, as its child -- here, literally: Index Spool (NodeId 0) wraps
        # Concatenation (NodeId 1) directly. An ancestor walk from the primary spool
        # was tried first and never matched, because the primary spool IS the root of
        # this shape, with no ancestors at all -- caught by printing the actual
        # parent chain rather than assuming the walk direction. A spool with no
        # Concatenation anywhere beneath it is caching a rewound branch for some
        # other reason (typically a correlated Nested Loops).
        # A replay's OWN rebind count is the meaningful one -- how many times the
        # working table actually gets re-read -- not the primary spool's (that
        # operator executes once itself, so its own est_rebinds reads 0). Map
        # PrimaryNodeId -> the largest rebind count among its replays first.
        replay_rebinds = {}
        for n in self.nodes:
            if px.is_lazy_spool(n) and px.is_lazy_spool_replay(n):
                pid = n.el.find(NS + "Spool").get("PrimaryNodeId")
                replay_rebinds[pid] = max(replay_rebinds.get(pid, 0.0), n.est_rebinds)

        self.lazy_spools = []
        for n in self.nodes:
            if not px.is_lazy_spool(n) or px.is_lazy_spool_replay(n):
                continue
            is_recursive = any(c.physical == "Concatenation" for c in px.flatten(n))
            rebinds = replay_rebinds.get(n.node_id, n.est_rebinds)
            if not is_recursive and rebinds < LAZY_SPOOL_REBIND_FLOOR:
                continue    # trivial rewind count -- not worth surfacing (see the floor's own comment)
            self.lazy_spools.append({
                "recursive": is_recursive,
                "rebinds": rebinds,
                "rows": n.actual_rows if n.has_actual else n.est_rows,
            })

        # table variable estimated at 1 row but really feeding a join with many
        self.tablevar_1row = []
        for n in self.nodes:
            if not _is_leaf_access(n):
                continue
            for tbl, _idx, _al in _leaf_objects(n):
                if (tbl.startswith("@") and n.est_rows <= 1.0
                        and n.actual_rows >= TABLEVAR_JOIN_ROWS_FLOOR):
                    self.tablevar_1row.append((tbl, n.actual_rows))

        # a row goal (TOP / FAST N / EXISTS) reshaping the plan
        self.has_row_goal = any(
            n.el.get("EstimateRowsWithoutRowGoal") is not None for n in self.nodes)

    def _collect_leaf_accesses(self):
        seen = {}
        accesses = {}
        for n in self.nodes:
            if not _is_leaf_access(n):
                continue
            objs = _leaf_objects(n)
            if not objs:
                continue
            table, index, _alias = objs[0]
            seen[table] = seen.get(table, 0) + 1
            key = table if seen[table] == 1 else f"{table} #{seen[table]}"
            execs = max(1.0, n.actual_executions)
            accesses[key] = {
                "table": table,
                "index": index or "(heap/clustered)",
                "op": n.physical,
                "node_id": n.node_id,
                "est_rows": n.est_rows,
                "actual_rows": n.actual_rows,
                "actual_per_exec": n.actual_rows / execs,
                "executions": n.actual_executions,
                "reads": n.logical_reads,
                "spill": any("spill" in w.lower() for w in n.warnings),
            }
        return accesses

    def _worst_skew(self):
        worst = 1.0
        for n in self.nodes:
            if not n.has_actual or n.is_exchange:
                continue
            execs = max(1.0, n.actual_executions)
            ratio = (n.actual_rows / execs + 1) / (n.est_rows + 1)
            worst = max(worst, ratio, 1.0 / ratio if ratio else 1.0)
        return worst


# ===========================================================================
# Comparison
# ===========================================================================

def compare(plans, baseline_idx, small_data_rows, with_recommendations=True,
            fill_factor=DEFAULT_FILLFACTOR):
    base = plans[baseline_idx]
    frame_keys = []
    for p in plans:
        for k in p.leaf_accesses:
            if k not in frame_keys:
                frame_keys.append(k)
    frame_keys.sort()

    signals = []

    # --- global: identical plans -------------------------------------------
    for i in range(len(plans)):
        for j in range(i + 1, len(plans)):
            if plans[i].query_plan_hash and plans[i].query_plan_hash == plans[j].query_plan_hash:
                signals.append({
                    "code": "IDENTICAL_PLAN", "scope": "global",
                    "detail": f"'{plans[i].label}' and '{plans[j].label}' compiled to the same "
                              f"plan (QueryPlanHash {plans[i].query_plan_hash}). Any difference in "
                              f"their runtime numbers is data or parameter values, not the plan.",
                })

    # --- global: query-hash mismatch -------------------------------------
    hashes = {p.query_hash for p in plans if p.query_hash}
    if len(hashes) > 1:
        signals.append({
            "code": "QUERY_HASH_MISMATCH", "scope": "global",
            "detail": "the plans do not all share a QueryHash -- they may be different queries. "
                      "This tool does not check that the versions are semantically equivalent; "
                      "that is the developer's responsibility.",
        })

    # --- global advisory: a scalar UDF is the query -----------------------
    for p in plans:
        if p.elapsed_ms and p.udf_elapsed_ms >= p.elapsed_ms * UDF_DOMINATES_FRACTION:
            signals.append({
                "code": "UDF_DOMINATES", "scope": "global",
                "detail": f"'{p.label}': scalar UDF(s) account for "
                          f"{p.udf_elapsed_ms / p.elapsed_ms * 100:,.0f}% of elapsed time "
                          f"({p.udf_elapsed_ms:,.0f} of {p.elapsed_ms:,.0f} ms). Inlining or "
                          f"removing the UDF is likely the whole optimisation.",
            })

    # --- per non-baseline plan vs baseline --------------------------------
    for p in plans:
        if p is base:
            continue
        tag = f"'{p.label}' vs baseline '{base.label}'"

        if (p.subtree_cost < base.subtree_cost * COST_DOWN_FRACTION
                and p.total_logical_reads > base.total_logical_reads * READS_UP_FRACTION
                and base.total_logical_reads > 0):
            signals.append({
                "code": "COST_DOWN_READS_UP", "scope": p.label,
                "detail": f"{tag}: estimated cost {p.subtree_cost:,.3f} < {base.subtree_cost:,.3f}, "
                          f"but actual logical reads {p.total_logical_reads:,.0f} > "
                          f"{base.total_logical_reads:,.0f}. The cost estimate disagrees with what "
                          f"the query actually did -- do not rank on the SSMS cost percentage.",
            })

        if p.spills and not base.spills:
            signals.append({
                "code": "NEW_SPILL", "scope": p.label,
                "detail": f"{tag}: a spill to tempdb that the baseline does not have -- "
                          + "; ".join(p.spills[:3]),
            })

        if base.granted_kb > 0 and p.granted_kb >= base.granted_kb * GRANT_CHANGE_MULTIPLE:
            signals.append({
                "code": "GRANT_GREW", "scope": p.label,
                "detail": f"{tag}: memory grant {p.granted_kb:,.0f} KB is "
                          f"{p.granted_kb / base.granted_kb:,.1f}x the baseline "
                          f"{base.granted_kb:,.0f} KB.",
            })
        elif p.granted_kb > 0 and base.granted_kb >= p.granted_kb * GRANT_CHANGE_MULTIPLE:
            signals.append({
                "code": "GRANT_SHRANK", "scope": p.label,
                "detail": f"{tag}: memory grant {p.granted_kb:,.0f} KB is "
                          f"{base.granted_kb / p.granted_kb:,.1f}x smaller than the baseline "
                          f"{base.granted_kb:,.0f} KB.",
            })

        if base.spills and not p.spills:
            signals.append({
                "code": "SPILL_RESOLVED", "scope": p.label,
                "detail": f"{tag}: the baseline's spill to tempdb is gone.",
            })
        elif (p.spills and base.spills
              and p.spill_tempdb_pages >= base.spill_tempdb_pages * SPILL_GREW_MULTIPLE
              and base.spill_tempdb_pages > 0):
            signals.append({
                "code": "SPILL_GREW", "scope": p.label,
                "detail": f"{tag}: both spill, but this one moves {p.spill_tempdb_pages:,.0f} "
                          f"tempdb pages vs {base.spill_tempdb_pages:,.0f} "
                          f"({p.spill_tempdb_pages / base.spill_tempdb_pages:,.1f}x).",
            })

        # a spool is caching machinery, not a tempdb SPILL (a memory-grant overflow
        # warning) -- unrelated concepts that read similarly; keep the wording distinct.
        # Split recursive vs rewind here too, same reason as the single-plan
        # detection: they need different fix text (recursion isn't fixed by
        # restructuring a per-row correlation), so one comparison code covering both
        # would have to give wrong advice for whichever case it did not assume.
        p_recur = any(s["recursive"] for s in p.lazy_spools)
        p_rewind = any(not s["recursive"] for s in p.lazy_spools)
        base_recur = any(s["recursive"] for s in base.lazy_spools)
        base_rewind = any(not s["recursive"] for s in base.lazy_spools)
        if p_recur and not base_recur:
            signals.append({
                "code": "NEW_LAZY_SPOOL_RECURSIVE", "scope": p.label,
                "detail": f"{tag}: a recursive CTE's working table (Lazy Spool) that the "
                          f"baseline does not have -- extra tempdb I/O the baseline did not pay, "
                          f"likely because this version's query is recursive and the baseline's "
                          f"is not (or recurses less).",
            })
        if p_rewind and not base_rewind:
            signals.append({
                "code": "NEW_LAZY_SPOOL_REWIND", "scope": p.label,
                "detail": f"{tag}: caches a rewound/rebound branch (Lazy Spool) that the "
                          f"baseline does not -- extra tempdb I/O the baseline did not pay.",
            })
        if base.lazy_spools and not p.lazy_spools:
            signals.append({
                "code": "LAZY_SPOOL_RESOLVED", "scope": p.label,
                "detail": f"{tag}: the baseline's Lazy Spool is gone.",
            })

        # --- elapsed / CPU time (item 1) ---
        if base.elapsed_ms is not None and p.elapsed_ms is not None:
            d = p.elapsed_ms - base.elapsed_ms
            frac = abs(d) / base.elapsed_ms if base.elapsed_ms > 0 else (1.0 if d else 0.0)
            if abs(d) >= TIME_MATERIAL_FLOOR_MS and frac >= TIME_MATERIAL_FRACTION:
                code = "SLOWER" if d > 0 else "FASTER"
                cpu_note = ""
                if base.cpu_ms is not None and p.cpu_ms is not None:
                    cpu_note = f"; CPU {base.cpu_ms:,.0f} -> {p.cpu_ms:,.0f} ms"
                signals.append({
                    "code": code, "scope": p.label,
                    "detail": f"{tag}: elapsed {base.elapsed_ms:,.0f} -> {p.elapsed_ms:,.0f} ms "
                              f"({d:+,.0f}, {frac * 100:,.0f}% {'slower' if d > 0 else 'faster'})"
                              f"{cpu_note}.",
                })

        # --- batch vs row mode (item 3) ---
        if base.batch_operators > 0 and p.batch_operators == 0:
            signals.append({
                "code": "BATCH_MODE_LOST", "scope": p.label,
                "detail": f"{tag}: the baseline runs {base.batch_operators} operator(s) in batch "
                          f"mode; this version runs entirely in row mode.",
            })
        elif base.batch_operators == 0 and p.batch_operators > 0:
            signals.append({
                "code": "BATCH_MODE_GAINED", "scope": p.label,
                "detail": f"{tag}: this version runs {p.batch_operators} operator(s) in batch mode; "
                          f"the baseline is entirely row mode.",
            })

        # --- key/RID lookup explosion (item 4) ---
        if (p.lookup_executions >= LOOKUP_EXPLOSION_MIN
                and p.lookup_executions >= base.lookup_executions * LOOKUP_EXPLOSION_MULTIPLE):
            signals.append({
                "code": "LOOKUP_EXPLOSION", "scope": p.label,
                "detail": f"{tag}: {p.lookup_executions:,.0f} key/RID-lookup executions "
                          f"(baseline {base.lookup_executions:,.0f}). A seek that then looks up "
                          f"most rows one at a time usually loses to a scan or a covering index.",
            })

        # --- parallel thread skew (item 5) ---
        if (p.worst_thread_skew >= THREAD_SKEW_MIN
                and p.worst_thread_skew >= base.worst_thread_skew * 2):
            extra = (f"; {p.effectively_serial_ops} operator(s) ran effectively serial"
                     if p.effectively_serial_ops else "")
            ratio = "inf" if p.worst_thread_skew == float("inf") else f"{p.worst_thread_skew:,.0f}x"
            signals.append({
                "code": "THREAD_SKEW", "scope": p.label,
                "detail": f"{tag}: busiest parallel worker did {ratio} the rows of the quietest "
                          f"(baseline {base.worst_thread_skew:,.0f}x){extra}. Parallelism is not "
                          f"buying what the DOP suggests.",
            })

        # --- memory grant over-allocation (item 6) ---
        if (p.granted_kb >= GRANT_OVERALLOC_FLOOR_KB
                and p.grant_overalloc_ratio >= GRANT_OVERALLOC_MULTIPLE
                and base.grant_overalloc_ratio < GRANT_OVERALLOC_MULTIPLE):
            signals.append({
                "code": "GRANT_OVERALLOCATED", "scope": p.label,
                "detail": f"{tag}: granted {p.granted_kb:,.0f} KB, used only {p.used_kb:,.0f} KB "
                          f"({p.grant_overalloc_ratio:,.1f}x). Over-grant reserves memory other "
                          f"queries then cannot get, even though this query runs fine.",
            })

        # --- scalar UDF time (item 7) ---
        if base.udf_elapsed_ms or p.udf_elapsed_ms:
            d = p.udf_elapsed_ms - base.udf_elapsed_ms
            base_ref = base.udf_elapsed_ms or 1.0
            frac = abs(d) / base_ref
            if abs(d) >= TIME_MATERIAL_FLOOR_MS and frac >= TIME_MATERIAL_FRACTION:
                code = "UDF_TIME_UP" if d > 0 else "UDF_TIME_DOWN"
                signals.append({
                    "code": code, "scope": p.label,
                    "detail": f"{tag}: scalar-UDF elapsed {base.udf_elapsed_ms:,.0f} -> "
                              f"{p.udf_elapsed_ms:,.0f} ms ({d:+,.0f}).",
                })

        # material change in total logical reads (either direction)
        if base.total_logical_reads > 0:
            delta = p.total_logical_reads - base.total_logical_reads
            frac = abs(delta) / base.total_logical_reads
            if abs(delta) >= READS_MATERIAL_FLOOR and frac >= READS_MATERIAL_FRACTION:
                code = "READS_UP" if delta > 0 else "READS_DOWN"
                signals.append({
                    "code": code, "scope": p.label,
                    "detail": f"{tag}: logical reads {base.total_logical_reads:,.0f} -> "
                              f"{p.total_logical_reads:,.0f} ({delta:+,.0f}, {frac * 100:,.0f}% "
                              f"{'more' if delta > 0 else 'fewer'}).",
                })

        if p.worst_skew >= base.worst_skew * 2 and p.worst_skew >= CE_SKEW_MIN:
            signals.append({
                "code": "CE_MISS_WORSE", "scope": p.label,
                "detail": f"{tag}: worst per-operator estimate is off by {p.worst_skew:,.1f}x "
                          f"(baseline {base.worst_skew:,.1f}x). The optimizer is working from a "
                          f"worse cardinality guess in this version.",
            })

        if p.is_serial != base.is_serial:
            became = "serial" if p.is_serial else "parallel"
            signals.append({
                "code": "PARALLELISM_CHANGED", "scope": p.label,
                "detail": f"{tag}: went {became} (baseline DOP {base.dop or '1'}, this DOP "
                          f"{p.dop or '1'}).",
            })

        # An access-shape flip is only labelled improved / regressed when total
        # reads agree. A scan -> seek that then does thousands of key lookups
        # (reads up) is NOT an improvement -- that case is COST_DOWN_READS_UP.
        reads_rose = p.total_logical_reads > base.total_logical_reads * 1.05
        reads_fell = p.total_logical_reads < base.total_logical_reads * 0.95
        for k in frame_keys:
            b_cell, p_cell = base.leaf_accesses.get(k), p.leaf_accesses.get(k)
            if not b_cell or not p_cell:
                continue
            if "Seek" in b_cell["op"] and "Scan" in p_cell["op"] and not reads_fell:
                signals.append({
                    "code": "ACCESS_REGRESSED", "scope": p.label,
                    "detail": f"{tag}: {k} went from {b_cell['op']} ({b_cell['actual_rows']:,.0f} "
                              f"rows) to {p_cell['op']} ({p_cell['actual_rows']:,.0f} rows).",
                })
            elif "Scan" in b_cell["op"] and "Seek" in p_cell["op"] and not reads_rose:
                signals.append({
                    "code": "ACCESS_IMPROVED", "scope": p.label,
                    "detail": f"{tag}: {k} went from {b_cell['op']} ({b_cell['actual_rows']:,.0f} "
                              f"rows) to {p_cell['op']} ({p_cell['actual_rows']:,.0f} rows).",
                })

    # --- structural deltas vs baseline ----------------------------------
    structural = {}
    for p in plans:
        if p is base:
            continue
        deltas = []
        if p.joins != base.joins:
            deltas.append(f"join operators {base.joins or '[]'} -> {p.joins or '[]'}")
        if p.sort_count != base.sort_count:
            deltas.append(f"Sort operators {base.sort_count} -> {p.sort_count}")
        if p.spool_count != base.spool_count:
            deltas.append(f"Spool operators {base.spool_count} -> {p.spool_count}")
        if p.is_serial != base.is_serial:
            deltas.append(f"{'parallel->serial' if p.is_serial else 'serial->parallel'}")
        for k in frame_keys:
            b_cell, p_cell = base.leaf_accesses.get(k), p.leaf_accesses.get(k)
            if b_cell and p_cell and b_cell["op"] != p_cell["op"]:
                deltas.append(f"{k}: {b_cell['op']} -> {p_cell['op']}")
            elif b_cell and p_cell and b_cell["index"] != p_cell["index"]:
                deltas.append(f"{k}: index {b_cell['index']} -> {p_cell['index']}")
        structural[p.label] = deltas

    # --- verdict per non-baseline plan (tally of directional signals) -----
    verdict = {}
    for p in plans:
        if p is base:
            continue
        my = [s for s in signals if s.get("scope") == p.label]
        regs = sorted({s["code"] for s in my if s["code"] in _REGRESSION_CODES})
        imps = sorted({s["code"] for s in my if s["code"] in _IMPROVEMENT_CODES})
        if regs and not imps:
            call = "WORSE"
        elif imps and not regs:
            call = "BETTER"
        elif imps and regs:
            call = "MIXED"
        else:
            call = "~ SAME"
        reads_note = ""
        if base.total_logical_reads or p.total_logical_reads:
            reads_note = f"reads {base.total_logical_reads:,.0f} -> {p.total_logical_reads:,.0f}"
        verdict[p.label] = {
            "call": call,
            "regressions": regs,
            "improvements": imps,
            "reads_note": reads_note,
        }

    # --- small-data caveat ---------------------------------------------
    max_rows = max((c["actual_rows"] for p in plans for c in p.leaf_accesses.values()),
                   default=0.0)
    small_data = max_rows < small_data_rows

    result = {
        "frame_keys": frame_keys,
        "signals": signals,
        "structural": structural,
        "verdict": verdict,
        "small_data": small_data,
        "max_leaf_rows": max_rows,
        "small_data_rows": small_data_rows,
        "fill_factor": fill_factor,
    }

    # --- v1.2: anti-pattern detections + deterministic recommendations -----
    if with_recommendations:
        result["detections"] = detect_antipatterns(plans)
        result["recommendations"] = recommend(plans, baseline_idx, result)
        result["actions"] = {
            p.label: recommended_action(p, plans, baseline_idx, result) for p in plans
        }

    return result


# ===========================================================================
# Anti-pattern detection + recommendations  (v1.2)
#
# Detections are shaped like signals ({code, scope, detail}) so the renderers
# treat them uniformly. RECOMMENDATIONS below is the SINGLE SOURCE OF TRUTH --
# ComparePlans-Recommendations-Catalog.md is generated from it (--dump-catalog)
# and test_compareplans.py asserts the two stay byte-identical.
# ===========================================================================

def detect_antipatterns(plans):
    """One record per (plan, anti-pattern). Runs on every plan, baseline included."""
    out = []
    # a row goal on EVERY version is not a difference to flag -- only note it when
    # some versions have one and others do not.
    flag_row_goal = any(p.has_row_goal for p in plans) and not all(p.has_row_goal for p in plans)
    for p in plans:
        who = f"'{p.label}'"

        if p.local_variables:
            lv = ", ".join(p.local_variables)
            verb = "is" if len(p.local_variables) == 1 else "are"
            out.append({
                "code": "LOCAL_VARIABLE", "scope": p.label,
                "detail": f"{who}: {lv} {verb} used in a predicate but not in <ParameterList> -- the "
                          f"optimizer had no value to sniff, so it used a fixed guess, not the histogram.",
            })

        for table, predtext, rows in p.nonsargable:
            out.append({
                "code": "NON_SARGABLE_PREDICATE", "scope": p.label,
                "detail": f"{who}: an expression wraps the filtered column of {table}, so the plan "
                          f"scans {rows:,.0f} rows instead of seeking ({predtext}).",
            })

        _warn_seen = set()
        for w in p.warnings:
            wl = w.lower()
            if wl.startswith("implicit conversion"):
                code = "IMPLICIT_CONVERSION"
            elif "join predicate" in wl or "nojoinpredicate" in wl.replace(" ", ""):
                code = "NO_JOIN_PREDICATE"
            elif wl.startswith("no statistics on"):
                code = "NO_STATISTICS"
            else:
                continue
            if code in _warn_seen:          # one per code per plan -- the fix is the same
                continue
            _warn_seen.add(code)
            out.append({"code": code, "scope": p.label, "detail": f"{who}: {w}"})

        if p.eager_spool:
            sp = p.eager_spool
            keycols = ", ".join(sp["keys"]) or "the correlated column"
            out.append({
                "code": "EAGER_INDEX_SPOOL", "scope": p.label,
                "detail": f"{who}: SQL Server builds a temporary index over {sp['table']} "
                          f"({sp['rows']:,.0f} rows) at run time to serve the {keycols} lookup, "
                          f"because no permanent index covers it -- that build is pure overhead "
                          f"and dominates the query.",
            })

        for sp in p.lazy_spools:
            if sp["recursive"]:
                out.append({
                    "code": "LAZY_SPOOL_RECURSIVE", "scope": p.label,
                    "detail": f"{who}: a recursive CTE's own working table (Lazy Spool), "
                              f"rebuilt/replayed an estimated {sp['rebinds']:,.1f} times, holding "
                              f"{sp['rows']:,.0f} rows -- SQL Server's required bookkeeping for the "
                              f"recursion, not itself a defect.",
                })
            else:
                out.append({
                    "code": "LAZY_SPOOL_REWIND", "scope": p.label,
                    "detail": f"{who}: SQL Server is caching a branch (Lazy Spool, {sp['rows']:,.0f} "
                              f"rows) that gets rewound/rebound an estimated {sp['rebinds']:,.1f} "
                              f"times rather than re-executing it per outer row -- usually a "
                              f"correlated per-row pattern that could be a set-based join instead.",
                })

        for name, actual in p.tablevar_1row:
            out.append({
                "code": "TABLE_VARIABLE_1ROW", "scope": p.label,
                "detail": f"{who}: table variable {name} is estimated at 1 row but returned "
                          f"{actual:,.0f}; downstream joins are sized for 1 row.",
            })

        if p.has_row_goal and flag_row_goal:
            out.append({
                "code": "ROW_GOAL", "scope": p.label,
                "detail": f"{who}: a row goal (TOP / FAST N / EXISTS) is active here but not on "
                          f"every version -- reads and the seek/scan choice are not comparable "
                          f"like-for-like.",
            })

    # A HINT is always the last thing to try, so this advisory is appended after every
    # other detection -- recommend() walks the list in order, so it lands last in the
    # RECOMMENDATIONS a reader sees. It is not a defect in the query; it says the plan
    # does not expose what the query groups by, which is why no realigned index appears.
    for p in plans:
        if p.hash_agg_grouping:
            cols = ", ".join(p.hash_agg_grouping)
            out.append({
                "code": "HASH_AGG_HIDES_GROUPING", "scope": p.label,
                "detail": f"'{p.label}': the GROUP BY is done by a Hash Match, which keeps its "
                          f"grouping columns ({cols}) as hash keys and writes no <GroupBy> into "
                          f"the plan -- so a tool reading this plan cannot tell what the query "
                          f"groups by, and cannot suggest an index key that would serve it.",
            })

    seen, deduped = set(), []
    for d in out:
        k = (d["code"], d["scope"], d["detail"])
        if k not in seen:
            seen.add(k)
            deduped.append(d)
    return deduped


def _index_name(table, keys, suffix=""):
    return "IX_" + table.split(".")[-1] + "_" + "_".join(keys[:3]) + suffix


def _fillfactor_clause(fillfactor):
    """' WITH (FILLFACTOR = N)' for 1..99, '' for 0 / 100 / None (server default)."""
    try:
        n = int(fillfactor)
    except (TypeError, ValueError):
        return ""
    return f" WITH (FILLFACTOR = {n})" if 1 <= n <= 99 else ""


def _fmt_ddl(name, table, keys, includes, why, fillfactor=DEFAULT_FILLFACTOR):
    """A commented CREATE INDEX + its paired rollback DROP -- every generated index
    ships with the statement that reverses it, for change management."""
    line = f"CREATE INDEX {name} ON {table} ({', '.join(keys)})"
    if includes:
        line += f" INCLUDE ({', '.join(includes)})"
    line += _fillfactor_clause(fillfactor)
    return (f"-- {why}\n"
            f"-- {line};\n"
            f"-- ROLLBACK:  DROP INDEX {name} ON {table};")


def _ddl_from_missing_index(mi, fillfactor=DEFAULT_FILLFACTOR):
    table, colgroups, impact = mi
    eq, ineq, inc = [], [], []
    for usage, names in colgroups:
        dst = {"EQUALITY": eq, "INEQUALITY": ineq, "INCLUDE": inc}.get(usage.upper(), inc)
        dst.extend(n for n in names if n)
    keys = eq + ineq
    if not keys:
        return None
    return _fmt_ddl(_index_name(table, keys), table, keys, inc,
                    f"optimizer-suggested (impact {impact:,.0f}); column order and INCLUDE are the "
                    f"optimizer's, not tuned -- review against existing indexes, or run usp_IndexAnalysis",
                    fillfactor)


def _ddl_from_spool(sp, fillfactor=DEFAULT_FILLFACTOR):
    if not sp or not sp.get("keys"):
        return None
    return _fmt_ddl(_index_name(sp["table"], sp["keys"]), sp["table"], sp["keys"], sp["includes"],
                    "replaces the run-time eager index spool; keys/INCLUDE are from the spool, "
                    "not tuned -- review before creating", fillfactor)


def _covering_index_from_lookup(plan, fillfactor=DEFAULT_FILLFACTOR):
    """A covering CREATE INDEX that removes a key/RID lookup: keys from the driving
    seek, INCLUDE from the lookup's own output. Returns _fmt_ddl text or None."""
    lookup = next((n for n in plan.nodes if _is_lookup(n) and n.has_actual), None)
    if lookup is None:
        return None
    objs = _leaf_objects(lookup)
    table = objs[0][0] if objs else None
    if not table:
        return None
    includes = []
    for c in (px.node_output_list(lookup) or []):
        nm = c.split(".")[-1]
        if nm and nm not in includes:
            includes.append(nm)
    seek = next((n for n in plan.nodes
                 if "Seek" in n.physical and not _is_lookup(n)
                 and _leaf_objects(n) and _leaf_objects(n)[0][0] == table), None)
    keys, existing = [], None
    if seek is not None:
        so = _leaf_objects(seek)
        existing = (so[0][1] or None) if so else None
        for e in px.local_elements(seek.el):
            if px.tag(e) != "SeekPredicateNew":
                continue
            for rc in e.iter(NS + "RangeColumns"):
                for c in rc.findall(NS + "ColumnReference"):
                    nm = px.unbracket(c.get("Column", ""))
                    if nm and not nm.startswith("@") and nm not in keys:
                        keys.append(nm)
    includes = [c for c in includes if c not in keys]
    if not keys or not includes:
        return None
    why = "covering index -- removes the key lookup; keys/INCLUDE are from the plan, not tuned"
    if existing:
        why += f" (widens what {existing} already seeks on)"
    why += " -- review and rename"
    return _fmt_ddl(_index_name(table, keys, "_covering"), table, keys, includes, why, fillfactor)


def _poc_index_from_plan(plan, fillfactor=DEFAULT_FILLFACTOR):
    """A POC (Partition / Order / Cover) index for a window function's OVER()
    clause: key = the window Sort's columns verbatim (PARTITION BY then frame
    ORDER BY, ASC/DESC from the plan), INCLUDE = the scanned table's other output
    columns. That single index removes the Sort the OVER() forces. Read straight
    from the plan (the Sort under a Sequence Project / Window Aggregate / Segment)
    -- returns (_fmt_ddl text, table, db) or None when the shape can't be read."""
    wf = next((n for n in plan.nodes if n.physical in _WINDOW_OPS), None)
    if wf is None:
        return None
    srt, stack = None, list(wf.children)
    while stack:
        n = stack.pop(0)
        if n.physical == "Sort":
            srt = n
            break
        stack.extend(n.children)
    if srt is None:
        return None
    key_defs, key_bare, seen = [], [], set()
    for e in px.local_elements(srt.el):
        if px.tag(e) != "OrderByColumn":
            continue
        cr = e.find(NS + "ColumnReference")
        col = px.unbracket(cr.get("Column", "")) if cr is not None else ""
        if not col or col.startswith(("@", "Expr")) or col in seen:
            continue
        seen.add(col)
        key_defs.append(f"[{col}] DESC" if e.get("Ascending") in ("false", "0") else f"[{col}]")
        key_bare.append(col)
    if not key_bare:
        return None
    walk, leaf = list(srt.children), None
    while walk:
        n = walk.pop(0)
        if not n.children and _leaf_objects(n):
            leaf = n
            break
        walk.extend(n.children)
    if leaf is None:
        return None
    table = _leaf_objects(leaf)[0][0]
    if not table:
        return None
    includes = []
    for c in (px.node_output_list(leaf) or []):
        nm = c.split(".")[-1]
        if nm and not nm.startswith("Expr") and nm not in key_bare and f"[{nm}]" not in includes:
            includes.append(f"[{nm}]")
    why = ("POC index for the OVER() clause -- key = PARTITION BY then frame ORDER BY "
           "(ASC/DESC from the plan's Sort), which removes the Sort; INCLUDE is the "
           "scanned columns, not tuned -- review and rename")
    return (_fmt_ddl(_index_name(table, key_bare, "_poc"), table, key_defs, includes, why, fillfactor),
            table, _object_database(leaf))


# code -> {headline, fix, caveat}.  The dict is the source of truth for the catalog doc.
RECOMMENDATIONS = {
    "HASH_AGG_HIDES_GROUPING": {
        "headline": "The GROUP BY is hashed, so index tools cannot see what it groups by",
        "fix": "Nothing here is wrong with the query -- this is about getting a good index "
               "suggestion for it. In order: (1) build the index the missing-index suggestion "
               "proposes, if there is one, and re-capture the plan -- once the rows arrive in "
               "order the optimizer usually switches to a Stream Aggregate on its own, and the "
               "grouping becomes visible; (2) if the query is supposed to return sorted rows, "
               "add the ORDER BY it needs, which often produces that same shape; (3) LAST "
               "RESORT, and only to look -- compile it once with OPTION (ORDER GROUP) under "
               "SET SHOWPLAN_XML ON (nothing executes) and pass that plan to "
               "usp_IndexAnalysis @StatementPlanXml. That hint forces a Stream Aggregate, so "
               "the grouping columns become readable and you get the realigned index to build.",
        "caveat": "If you use the hint, take it back out again -- it is a way to SEE the index "
                  "you need, not the fix. On its own it forces a sort that was not there and "
                  "makes the query slower; once the index exists it changes nothing. And a hash "
                  "aggregate is often the right choice, so this is a note about what the tooling "
                  "can read, not a fault to correct.",
    },
    "LOOKUP_EXPLOSION": {
        "headline": "Key/RID lookups are the cost -- cover the query or stop reusing a selective plan",
        "fix": "Add a covering index so the lookup's columns are in the index, or -- if this is one "
               "plan compiled for a rare value and reused for common ones -- fix the reuse with "
               "OPTIMIZE FOR / OPTION (RECOMPILE) / (2022+) parameter-sensitive plans.",
        "caveat": "If the lookup count is small at production scale, or the index already covers "
                  "and the plan just chose wrong, an index will not help.",
    },
    "COST_DOWN_READS_UP": {
        "headline": "Lower estimated cost, more actual work -- rank on reads, not the cost %",
        "fix": "Choose the version with fewer logical reads. If the cheap-looking plan is a "
               "seek + lookup, cover it; if it is a scan the optimizer under-costed, check "
               "statistics and the row estimate.",
        "caveat": "Cost is always an estimate; this is a reason to distrust it here, not a fix.",
    },
    "ACCESS_REGRESSED": {
        "headline": "A table went seek -> scan and reads rose",
        "fix": "Restore the index the better version used, or make the predicate sargable (no "
               "function / CONVERT on the filtered column).",
        "caveat": "A deliberate scan is correct when the query touches most of the table.",
    },
    "NEW_SPILL": {
        "headline": "New spill to tempdb",
        "fix": "Fix the row estimate the sort/hash is sized from (update statistics, remove a "
               "local variable), raise the memory grant, or add an index that removes the sort.",
        "caveat": "A one-level spill on a large sort at production scale is not always worth "
                  "chasing.",
    },
    "SPILL_GREW": {
        "headline": "Both versions spill; this one moves far more tempdb",
        "fix": "Same as a new spill -- estimate, grant, or index. Check granted-vs-used memory in "
               "RESOURCE DELTAS first; if a grant hint caused it, back the hint off.",
        "caveat": "None beyond the grant-hint case.",
    },
    "GRANT_GREW": {
        "headline": "Memory grant doubled or more",
        "fix": "The optimizer expects more rows through a memory-consuming operator. Update "
               "statistics; check for a new sort/hash the other version avoids.",
        "caveat": "A larger grant is fine if the version is faster and the memory is there.",
    },
    "GRANT_OVERALLOCATED": {
        "headline": "Grants far more memory than it uses",
        "fix": "Remove a MIN_GRANT_PERCENT hint, add MAX_GRANT_PERCENT, or fix the over-estimate "
               "feeding the grant. Over-grant starves other queries under concurrency.",
        "caveat": "Ignore for a query that runs once in isolation.",
    },
    "CE_MISS_WORSE": {
        "headline": "Worse cardinality estimate driving the plan",
        "fix": "Update statistics on the filtered columns. If a local variable or non-sargable "
               "predicate is involved, fix that. Run usp_TippingPointAnalysis for the exact "
               "estimate and the value where the plan flips.",
        "caveat": "A large ratio on a tiny operator (few rows either way) may not be material.",
    },
    "BATCH_MODE_LOST": {
        "headline": "Dropped from batch mode to row mode",
        "fix": "Remove whatever disabled batch mode -- a DISALLOW_BATCH_MODE / USE HINT, or a "
               "construct that forces row mode. Confirm a columnstore index or the batch-mode-on-"
               "rowstore conditions still hold.",
        "caveat": "Row mode can win on a small result where batch-mode startup is not amortised.",
    },
    "UDF_DOMINATES": {
        "headline": "A scalar UDF is most of the elapsed time",
        "fix": "Inline the scalar UDF (SQL Server 2019+ does this automatically when it qualifies), "
               "or rewrite it as an inline table-valued function or a computed column.",
        "caveat": "None -- a per-row scalar UDF over a large set is almost always the whole cost.",
    },
    "UDF_TIME_UP": {
        "headline": "Scalar-UDF time went up",
        "fix": "Same as UDF_DOMINATES -- inline it or convert to an inline TVF.",
        "caveat": "A small absolute change on a small set may not matter.",
    },
    "THREAD_SKEW": {
        "headline": "Parallel workers are badly unbalanced",
        "fix": "The distribution key sends most rows to one worker. Repartition on a more even key, "
               "or reconsider whether this query should run parallel.",
        "caveat": "Advisory -- no fixture reproduces this reliably; check the per-thread rows in "
                  "the plan.",
    },
    "IDENTICAL_PLAN": {
        "headline": "The rewrite compiled to the same plan",
        "fix": "Do not ship this as a fix -- any runtime difference is data or parameter values. "
               "To get a different plan the change must alter the optimizer's options (an index, "
               "a hint, a sargable predicate).",
        "caveat": "None.",
    },
    "QUERY_HASH_MISMATCH": {
        "headline": "The versions are not the same query text",
        "fix": "Confirm they return the same result set before choosing between them -- this tool "
               "does not check semantic equivalence.",
        "caveat": "Expected when comparing genuine rewrites; still verify the results.",
    },
    "LOCAL_VARIABLE": {
        "headline": "{subject} drives the estimate -- a fixed guess, not the histogram",
        "fix": "Replace {subject} with a parameter, add OPTION (RECOMPILE) to fold it to a "
               "compile-time literal, or make it a constant. Run usp_TippingPointAnalysis for the "
               "estimate it produces and the value where the plan tips.",
        "caveat": "OPTION (RECOMPILE) trades a compile per execution for accuracy -- fine for a "
                  "low-frequency statement, not a hot one.",
    },
    "NON_SARGABLE_PREDICATE": {
        "headline": "A function / CONVERT on the filtered column blocks an index seek",
        "fix": "Compare on the column's native type: move the CONVERT/expression to the other side "
               "of the comparison, or persist the derived value in a computed column and index it.",
        "caveat": "If the column genuinely needs transforming per row, a computed column + index "
                  "is the route, not a rewrite.",
    },
    "IMPLICIT_CONVERSION": {
        "headline": "An implicit type conversion is changing the plan",
        "fix": "Align the parameter or literal type to the column's type so no CONVERT lands on "
               "the column side.",
        "caveat": "A conversion on the literal side (not the column) is harmless.",
    },
    "NO_JOIN_PREDICATE": {
        "headline": "A join has no ON condition",
        "fix": "Add the missing join predicate -- an unintended cross join multiplies row counts.",
        "caveat": "Frequently benign for a deliberate 1-row cross join; confirm it is intended.",
    },
    "NO_STATISTICS": {
        "headline": "The optimizer had no statistics on a filtered column",
        "fix": "CREATE STATISTICS on the named column(s), or confirm AUTO_CREATE_STATISTICS is ON "
               "for the database.",
        "caveat": "None.",
    },
    "EAGER_INDEX_SPOOL": {
        "headline": "SQL Server is building a temporary index at run time",
        "fix": "Create the permanent index the spool stands in for. The skeleton below is from the "
               "spool's own keys and output -- review against the existing indexes.",
        "caveat": "If the spool is over a small set at production scale it can be cheaper than "
                  "maintaining another index.",
    },
    "LAZY_SPOOL_RECURSIVE": {
        "headline": "A recursive CTE's own working table (Lazy Spool)",
        "fix": "Not an indexing problem -- the spool is SQL Server's required bookkeeping for the "
               "recursion. If the tempdb cost matters, bound MAXRECURSION, or restructure the "
               "recursive member so it does not need to carry the full accumulated history "
               "(e.g. track only the latest level if that is all the query needs).",
        "caveat": "Present in essentially every recursive CTE; this is a note, not a defect. Its "
                  "tempdb cost scales with recursion depth and fan-out, not with an absent index.",
    },
    "LAZY_SPOOL_REWIND": {
        "headline": "A repeatedly rewound branch is being cached instead of re-executed",
        "fix": "Not an indexing problem -- an index does not remove the spool. Check whether the "
               "correlated, per-outer-row pattern driving the rewind can become a single set-based "
               "join instead.",
        "caveat": "SQL Server chose to cache because re-executing the branch per row was estimated "
                  "as more expensive; removing the spool without removing the rewind can make the "
                  "plan slower, not faster.",
    },
    "NEW_LAZY_SPOOL_RECURSIVE": {
        "headline": "This version's query is recursive where the baseline's is not (or recurses less)",
        "fix": "Not necessarily a defect to fix -- confirm whether the recursion is intentional and "
               "correct (the baseline may simply not handle the same cases). If the tempdb cost "
               "matters, bound MAXRECURSION or restructure the recursive member.",
        "caveat": "A recursive CTE's own working table is required bookkeeping, not something an "
                  "index removes -- do not chase this the way a genuine regression is chased.",
    },
    "NEW_LAZY_SPOOL_REWIND": {
        "headline": "New Lazy Spool caching a rewound branch that the baseline does not need",
        "fix": "Not an indexing problem. Check what changed about the query shape -- a rewrite that "
               "introduced a correlated per-row pattern, or a plan choice a fresher statistics "
               "update would revert -- rather than adding an index.",
        "caveat": "A spool is deliberate caching machinery, not a tempdb spill -- do not conflate "
                  "this with NEW_SPILL/SPILL_GREW, which are a memory-grant overflow warning on a "
                  "Sort/Hash, an unrelated concept.",
    },
    "TABLE_VARIABLE_1ROW": {
        "headline": "{subject}: a table variable estimated at 1 row, feeding a join",
        "fix": "Switch {subject} to a #temp table (it gets statistics and a real estimate), or add "
               "OPTION (RECOMPILE) so the count is known at compile time. On 2019+/compat 150 "
               "confirm table-variable deferred compilation is on.",
        "caveat": "A table variable that really holds ~1 row is fine.",
    },
    "ROW_GOAL": {
        "headline": "A row goal (TOP / FAST N / EXISTS) is shaping the plan",
        "fix": "Compare the versions like-for-like -- a row goal makes the plan stop early, so "
               "reads and the seek/scan choice are not comparable to a version without one. If "
               "the row goal is unintended, remove the TOP / FAST hint.",
        "caveat": "Usually intended; this is a note, not a defect.",
    },
}


def _plan_by_label(plans, label):
    for p in plans:
        if p.label == label:
            return p
    return None


def _fill_subject(text, subject, fallback):
    return text.replace("{subject}", subject or fallback)


def recommend(plans, baseline_idx, result):
    """One record per (code, scope) that has a catalog entry, with a commented CREATE INDEX
    attached where the plan gives enough to build one."""
    fired, seen, vsbest_done, ddl_done = [], set(), set(), set()
    ff = result.get("fill_factor", DEFAULT_FILLFACTOR)
    for s in list(result["signals"]) + list(result.get("detections", [])):
        code, scope = s["code"], s.get("scope", "global")
        if code not in RECOMMENDATIONS or (code, scope) in seen:
            continue
        seen.add((code, scope))
        e = RECOMMENDATIONS[code]
        detail = s["detail"]
        # once per scope, add what the best plan actually does -- the concrete
        # "and version X already avoids it" a lookup table cannot phrase itself.
        if scope != "global" and scope not in vsbest_done and code in (
                "LOOKUP_EXPLOSION", "ACCESS_REGRESSED", "COST_DOWN_READS_UP", "NEW_SPILL",
                "SPILL_GREW", "EAGER_INDEX_SPOOL", "NON_SARGABLE_PREDICATE", "CE_MISS_WORSE",
                "LOCAL_VARIABLE"):
            here = _plan_by_label(plans, scope)
            best = min((q for q in plans if q.label != scope),
                       key=lambda q: q.total_logical_reads, default=None)
            if here is not None and best is not None and best.total_logical_reads < here.total_logical_reads:
                extra = f" '{best.label}' does {best.total_logical_reads:,.0f} logical reads"
                if best.elapsed_ms is not None and here.elapsed_ms is not None:
                    extra += f" / {best.elapsed_ms:,.0f} ms vs {here.total_logical_reads:,.0f} / {here.elapsed_ms:,.0f} ms here"
                else:
                    extra += f" vs {here.total_logical_reads:,.0f} here"
                detail = detail.rstrip(".") + "." + extra + "."
                vsbest_done.add(scope)
        # name the specific subject where the plan gives one, so "replace the local
        # variable" becomes "replace @pid" (unambiguous with several in one query).
        subject = None
        here = _plan_by_label(plans, scope)
        if here:
            if code == "LOCAL_VARIABLE" and here.local_variables:
                subject = ", ".join(here.local_variables)
            elif code == "TABLE_VARIABLE_1ROW" and here.tablevar_1row:
                subject = ", ".join(n for n, _ in here.tablevar_1row)
        headline = _fill_subject(e["headline"], subject, "the variable")
        fix = _fill_subject(e["fix"], subject, "the variable")
        rec = {"code": code, "scope": scope, "headline": headline, "fix": fix,
               "caveat": e["caveat"], "ddl": None, "detail": detail}
        if code in ("LOOKUP_EXPLOSION", "ACCESS_REGRESSED", "COST_DOWN_READS_UP", "NEW_SPILL"):
            pl = _plan_by_label(plans, scope) or plans[baseline_idx]
            if scope not in ddl_done:
                if pl.missing_indexes:
                    rec["ddl"] = _ddl_from_missing_index(
                        max(pl.missing_indexes, key=lambda m: m[2]), ff)
                else:
                    rec["ddl"] = _covering_index_from_lookup(pl, ff)   # synthesise from seek + lookup
                if rec["ddl"]:
                    ddl_done.add(scope)
        elif code == "EAGER_INDEX_SPOOL":
            pl = _plan_by_label(plans, scope)
            if pl and pl.eager_spool:
                rec["ddl"] = _ddl_from_spool(pl.eager_spool, ff)
        fired.append(rec)

    # collapse an identical generated index recommended for several plans into one
    # block that names them all (a 4-way comparison otherwise repeats the same DDL).
    by_ddl = {}
    for r in fired:
        if r["ddl"]:
            by_ddl.setdefault(r["ddl"], []).append(r)
    for group in by_ddl.values():
        if len(group) > 1:
            group[0]["ddl_also"] = [r["scope"] for r in group[1:]]
            for r in group[1:]:
                r["ddl"] = None

    # tag each surviving DDL rec with the table + database it targets (for --analyze-indexes)
    for r in fired:
        if not r["ddl"]:
            continue
        m = re.search(r"CREATE INDEX \S+ ON (\S+) \(", r["ddl"])
        if not m:
            continue
        r["ddl_table"] = m.group(1)
        pl = _plan_by_label(plans, r["scope"])
        r["ddl_db"] = pl.table_databases.get(m.group(1)) if pl else None
    return fired


# code -> the short "why" after "hold -- " in RECOMMENDED ACTION, in priority order.
# Root causes (a bad estimate, a non-sargable predicate, a run-time index build)
# rank ABOVE the symptoms they produce (a lookup storm, a seek->scan) so the
# action names the fix, not the side effect.
_ACTION_HOLD = [
    ("EAGER_INDEX_SPOOL", "add the covering index"),
    ("LAZY_SPOOL_REWIND", "restructure the repeated per-row re-evaluation"),
    ("NEW_LAZY_SPOOL_REWIND", "restructure the repeated per-row re-evaluation"),
    ("NON_SARGABLE_PREDICATE", "make the predicate sargable"),
    ("IMPLICIT_CONVERSION", "align the parameter types"),
    ("LOCAL_VARIABLE", "replace the local variable"),
    ("TABLE_VARIABLE_1ROW", "use a #temp table"),
    ("NO_JOIN_PREDICATE", "add the join predicate"),
    ("BATCH_MODE_LOST", "restore batch mode"),
    ("UDF_DOMINATES", "inline the scalar UDF"),
    ("UDF_TIME_UP", "inline the scalar UDF"),
    ("LOOKUP_EXPLOSION", "add a covering index"),
    ("ACCESS_REGRESSED", "restore the index / make the predicate sargable"),
    ("NEW_SPILL", "fix the memory grant / estimate"),
    ("SPILL_GREW", "fix the memory grant / estimate"),
    ("GRANT_OVERALLOCATED", "cap the memory grant"),
    ("GRANT_GREW", "check statistics"),
    ("CE_MISS_WORSE", "update statistics"),
    ("NO_STATISTICS", "create statistics"),
]


def recommended_action(p, plans, baseline_idx, result):
    """'ship' / 'hold -- <fix>' / 'investigate -- <what>', for one plan (baseline included)."""
    codes = {s["code"] for s in list(result["signals"]) + list(result.get("detections", []))
             if s.get("scope") == p.label}
    for s in result["signals"]:
        if s.get("scope") == "global" and f"'{p.label}'" in s.get("detail", ""):
            codes.add(s["code"])
    global_codes = {s["code"] for s in result["signals"] if s.get("scope") == "global"}

    for code, why in _ACTION_HOLD:
        if code in codes:
            return f"hold -- {why}"
    if "IDENTICAL_PLAN" in codes:
        return "investigate -- same plan as another version (difference is data/params)"
    if "QUERY_HASH_MISMATCH" in global_codes:
        return "investigate -- not the same query text; verify the results match"
    if "THREAD_SKEW" in codes:
        return "investigate -- parallel workers badly unbalanced"
    # small-data is a CAVEATS-section concern, not an action verb -- see the plan.
    if p is plans[baseline_idx]:
        return "ship"
    if result["verdict"].get(p.label, {}).get("call") == "WORSE":
        return "investigate -- worse than baseline with no single clear fix"
    return "ship"


def dump_catalog():
    """The RECOMMENDATIONS dict as Markdown -- ComparePlans-Recommendations-Catalog.md is this."""
    L = [
        "# ComparePlans recommendations catalog",
        "",
        "_Generated by `python ComparePlans_v1.py --dump-catalog`. Do not edit by hand -- edit the "
        "`RECOMMENDATIONS` dict in `ComparePlans_v1.py`. `test_compareplans.py` asserts this file is "
        "byte-identical to a fresh dump._",
        "",
        "One row per signal or detection the tool can recommend on. A code that fires with no row "
        "here still appears under `SIGNALS`; it simply has no canned fix -- that is the "
        "`--emit-prompt` case.",
        "",
        "| code | recommendation | standard fix | when it does not apply |",
        "|---|---|---|---|",
    ]
    for code in sorted(RECOMMENDATIONS):
        e = RECOMMENDATIONS[code]
        # {subject} is filled with the real name (e.g. @pid / @tv) at run time; show
        # a placeholder in the generic catalog.
        hd = e["headline"].replace("{subject}", "<the variable>")
        fx = e["fix"].replace("{subject}", "<the variable>")
        L.append(f"| `{code}` | {hd} | {fx} | {e['caveat']} |")
    L.append("")
    return "\n".join(L)


# ===========================================================================
# Live index-analysis hand-off (--analyze-indexes) -- opt-in, shells out to
# sqlcmd (the family's connection tool), integrated / Entra auth only.
# ===========================================================================

_SERVER_RE = re.compile(
    r"^(tcp:)?[A-Za-z0-9_.][A-Za-z0-9._\-]*(\\[A-Za-z0-9_.][A-Za-z0-9._\-]*)?(,\d{1,5})?$")


def _valid_server(s):
    """A host / FQDN / host\\instance / tcp:host,port -- and nothing that could
    smuggle a second sqlcmd switch or a password."""
    return bool(s) and bool(_SERVER_RE.match(s))


_AUTH_SWITCH = {"windows": ["-E"], "entra": ["-G"], "entra-interactive": ["-G"]}


def run_index_analysis(server, auth, utility_db, db, table):
    """EXEC usp_IndexAnalysis for one table via sqlcmd. Returns a dict; never raises."""
    dbq, tblq = (db or "").replace("'", "''"), (table or "").replace("'", "''")
    q = ("SET NOCOUNT ON; "
         "BEGIN TRY SELECT 'UPTIME' AS tag, "
         "CONVERT(varchar(19), sqlserver_start_time, 120) AS start_time, "
         "DATEDIFF(DAY, sqlserver_start_time, GETDATE()) AS days_up "
         "FROM sys.dm_os_sys_info; END TRY BEGIN CATCH END CATCH; "
         "EXEC dbo.usp_IndexAnalysis "
         f"@DatabaseName = N'{dbq}', @TableName = N'{tblq}', @Output = 'DETAILED';")
    cmd = ["sqlcmd", "-S", server, "-d", utility_db, "-C", "-I", "-b", "-W", "-s", "|",
           "-m", "11", *_AUTH_SWITCH.get(auth, ["-E"]), "-Q", q]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except FileNotFoundError:
        return {"ok": False, "server": server, "table": table,
                "text": "sqlcmd not found on PATH -- install the SQL Server command-line tools."}
    except subprocess.TimeoutExpired:
        return {"ok": False, "server": server, "table": table,
                "text": "usp_IndexAnalysis timed out after 120s."}
    out = (r.stdout or "").strip()
    if r.returncode != 0:
        err = (r.stderr or "").strip()
        return {"ok": False, "server": server, "table": table,
                "text": f"sqlcmd exit {r.returncode}:\n{out or err or '(no output)'}"}
    return {"ok": True, "server": server, "table": table, "text": out or "(no rows)"}


def gather_index_analysis(plans, result, server, auth, utility_db):
    """One usp_IndexAnalysis call per distinct (db, table) that got a generated index."""
    seen, todo = set(), []
    for r in result.get("recommendations", []):
        t = r.get("ddl_table")
        if t and t not in seen:
            seen.add(t)
            todo.append((r.get("ddl_db"), t))
    out = {t: run_index_analysis(server, auth, utility_db, db, t) for db, t in todo}
    if not result.get("show_missing_indexes"):
        # honour the default everywhere, including --format json's raw blob: strip
        # the missing-index (index_action = CREATE) rows out of the captured text.
        for res in out.values():
            if res.get("ok"):
                res["text"] = _raw_without_missing(res["text"])
    return out


def _raw_without_missing(raw):
    """Drop the missing-index (index_action = CREATE) DATA rows from the raw
    usp_IndexAnalysis pipe grid. Headers, the '---' rules, every other row, blank
    lines and result-set boundaries are untouched; a non-grid string (an error)
    passes straight through."""
    lines = raw.splitlines()
    keep, i = [], 0
    while i < len(lines):
        line = lines[i]
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        is_rule = bool(nxt.strip()) and set(nxt.strip()) <= set("-|")
        if "|" in line and is_rule:
            cols = [c.strip() for c in line.split("|")]
            aidx = cols.index("index_action") if "index_action" in cols else None
            keep.append(line)
            keep.append(nxt)
            j = i + 2
            while j < len(lines):
                d = lines[j]
                nd = lines[j + 1] if j + 1 < len(lines) else ""
                if "|" in d and bool(nd.strip()) and set(nd.strip()) <= set("-|"):
                    break                          # next result set's header
                if d.strip() and aidx is not None:
                    cells = d.split("|")
                    if aidx < len(cells) and cells[aidx].strip().upper() == "CREATE":
                        j += 1
                        continue
                keep.append(d)
                j += 1
            i = j
        else:
            keep.append(line)
            i += 1
    return "\n".join(keep)


# --- turning usp_IndexAnalysis's wide grid into a readable per-index summary ---

def _ia_result_sets(raw):
    """sqlcmd '-W -s |' output -> [{cols: [...], rows: [{col: val}]}], one per
    result set. A header is any '|' line immediately followed by a '---|---' rule."""
    lines = raw.splitlines()

    def is_rule(s):
        s = s.strip()
        return bool(s) and set(s) <= set("-|")
    sets, i = [], 0
    while i < len(lines):
        line = lines[i]
        if "|" in line and i + 1 < len(lines) and is_rule(lines[i + 1]):
            cols = [c.strip() for c in line.split("|")]
            rows, j = [], i + 2
            while j < len(lines):
                nxt = lines[j]
                if not nxt.strip():
                    j += 1
                    continue
                if "|" in nxt and j + 1 < len(lines) and is_rule(lines[j + 1]):
                    break                      # next result set's header
                vals = nxt.split("|")
                if len(vals) > len(cols):       # a '|' inside a data value
                    vals = vals[:len(cols) - 1] + ["|".join(vals[len(cols) - 1:])]
                vals += [""] * (len(cols) - len(vals))
                rows.append({c: v.strip() for c, v in zip(cols, vals)})
                j += 1
            sets.append({"cols": cols, "rows": rows})
            i = j
        else:
            i += 1
    return sets


def _v(row, key):
    """A cell value, with NULL / blank normalised to ''."""
    x = (row.get(key) or "").strip()
    return "" if x.upper() == "NULL" else x


def _ia_uptime(ia):
    """From an index_analysis map, the instance start time + whole days up, or None
    (probe failed, or the caller lacks the permission for sys.dm_os_sys_info)."""
    raw = next((v["text"] for v in (ia or {}).values() if v.get("ok")), None)
    if not raw:
        return None
    for s in _ia_result_sets(raw):
        if "days_up" not in s["cols"] or not s["rows"]:
            continue
        row = s["rows"][0]
        try:
            return {"start": _v(row, "start_time"), "days": int(_v(row, "days_up"))}
        except ValueError:
            return None
    return None


def _ia_uptime_lines(ia, min_days):
    """The 'server started ... up N days' line for the section header, plus a
    warning when uptime is under `min_days`. Indented 2. [] if the probe failed."""
    up = _ia_uptime(ia)
    if up is None:
        return []
    d = up["days"]
    L = [f"  server started {up['start']}  --  up {d:,} day{'s' if d != 1 else ''}"]
    if d < min_days:
        L += [
            f"  !! only {d:,} day{'s' if d != 1 else ''} of uptime -- usp_IndexAnalysis leans on "
            "counters that reset on restart",
            "     (sys.dm_db_index_usage_stats, the missing-index DMVs), so its DROP-USAGE / "
            "MISSING rows are",
            f"     not yet reliable. Best practice: at least {min_days} days, ideally a full "
            "business cycle (~4 weeks,",
            "     to catch weekly and month-end jobs) of normal activity before acting on them.",
        ]
    return L


def _debracket(s):
    """'[Production].[TransactionHistory]' -> 'production.transactionhistory'."""
    return (s or "").replace("[", "").replace("]", "").strip().lower()


def _norm_cols(s):
    """'[ProductID], [Foo]' -> ['productid', 'foo'] for prefix comparison."""
    return [_debracket(c) for c in s.split(",") if c.strip()]


def _parse_generated_index(ddl_text):
    """The CREATE INDEX line the tool built -> (name, [keys], [includes]) or None."""
    if not ddl_text:
        return None
    m = re.search(r"CREATE INDEX (\S+) ON \S+ \(([^)]*)\)(?:\s*INCLUDE \(([^)]*)\))?", ddl_text)
    if not m:
        return None
    keys = [k.strip() for k in m.group(2).split(",") if k.strip()]
    inc = [k.strip() for k in (m.group(3) or "").split(",") if k.strip()]
    return (m.group(1), keys, inc)


_IA_ACTION_ORDER = ["DROP-DUP", "DROP-USAGE", "BLEND", "REALIGN", "CREATE", "CREATE-JSON",
                    "ENABLE", "SEQKEY"]


def _qb(name):
    """[Bracket] a bare identifier; leave an already-bracketed one alone."""
    name = (name or "").strip()
    return name if name.startswith("[") else f"[{name}]"


def _recreate_index_ddl(row, fillfactor=DEFAULT_FILLFACTOR):
    """A commented CREATE INDEX that REVERSES a DROP recommendation, rebuilt from
    the catalog columns in the grid -- so a drop ships with its rollback (change
    control). Returns comment lines indented 8, or a note when it can't script it."""
    name, table = _v(row, "index_name"), _v(row, "object_name")
    keys, td = _v(row, "key_columns_display"), _v(row, "type_desc").upper()
    if _v(row, "is_primary_key") == "1" or _v(row, "index_action") == "":
        return [f"        -- ROLLBACK:  re-add {_qb(name)} from the live definition "
                f"(a PRIMARY KEY / UNIQUE constraint -- ALTER TABLE, not CREATE INDEX)."]
    if td not in ("CLUSTERED", "NONCLUSTERED") or not keys:
        return [f"        -- ROLLBACK:  recreate {_qb(name)} ({td or 'index'}) from the live "
                f"definition -- not scripted (reconstruction is unreliable for this index type)."]
    uniq = "UNIQUE " if _v(row, "is_unique") == "1" else ""
    stmt = f"CREATE {uniq}{td} INDEX {_qb(name)} ON {table} ({keys})"
    if _v(row, "include_columns_display"):
        stmt += f" INCLUDE ({_v(row, 'include_columns_display')})"
    if _v(row, "filter_definition"):
        stmt += f" WHERE {_v(row, 'filter_definition')}"
    ffc = _fillfactor_clause(fillfactor)
    stmt += ffc
    ff_note = (f"FILLFACTOR is this tool's default ({fillfactor}), not the dropped index's; "
               if ffc else "fill factor, ")
    return [f"        -- ROLLBACK:  {stmt};",
            "        --            key columns, sort direction, INCLUDE and filter are from the "
            "catalog grid;",
            f"        --            {ff_note}data compression, PAD_INDEX, lock and sequential-key "
            "options, and",
            "        --            filegroup / partition placement are NOT -- diff against the live "
            "index before running."]


def _fpoc_realign_index(row, tbl_raw, fillfactor, ck_cols=()):
    """A REALIGN -- CREATE INDEX line that reorders a missing-index proposal's key
    -- equality/filter cols, then GROUP BY cols, then ORDER BY cols last (ASC/DESC)
    -- so the query's Sort / Hash Aggregate is eliminated. Range/inequality cols are
    demoted to INCLUDE (a range can't share the key with ORDER BY without forcing
    the Sort back). ck_cols (the table's clustered key, or () for a heap) are never
    added -- a nonclustered index already carries them as the row locator: they are
    dropped from INCLUDE always, and from the trailing key positions (the locator
    sits there implicitly, and the engine can scan it backwards for DESC).
    Returns [line, caveat] or None when the realigned key would equal the DMV
    proposal's own key + INCLUDE (nothing to realign).
    (v1 reads only top-level GROUP BY / result ORDER BY. It does not parse
    OVER (PARTITION BY ...) -- but a window function's PARTITION BY surfaces in the
    plan as a Segment <GroupBy>, so it arrives through the GROUP BY path; when
    usp_IndexAnalysis flags that (missing_window_kind = 'FPOC' / 'POC') the caveat
    names the realigned key as a windowing POC index.)"""
    def cols(v):
        # "[A], [B] DESC" -> [("[A]", ""), ("[B]", " DESC")]  -- keep brackets + direction
        out = []
        for c in (_v(row, v) or "").split(","):
            c = c.strip()
            if not c:
                continue
            m = re.match(r"(.+?)(?:\s+(ASC|DESC))?\s*$", c, re.I)
            out.append((m.group(1).strip(), f" {m.group(2).upper()}" if m.group(2) else ""))
        return out

    eq = cols("equality_columns")
    grp = cols("missing_group_by_cols")
    ordby = cols("missing_order_by_cols")
    ineq = cols("inequality_columns")
    inc = cols("include_columns_display")
    if not ordby and not grp:
        return None

    ck = {_debracket(c) for c in ck_cols}                   # clustered-key columns (implicit locator)
    ck_list = [_debracket(c) for c in ck_cols]              # ...in order
    ord_dir = {_debracket(n): d for n, d in ordby}          # ORDER BY direction per column
    key, seen = [], set()
    for name, direction in eq + grp + ordby:                # F -> P -> O
        k = _debracket(name)
        if k and k not in seen:
            seen.add(k)
            # a GROUP BY col that is also sorted takes the ORDER BY's ASC/DESC
            key.append(name + (ord_dir.get(k, "") or direction))
    _bare = lambda s: _debracket(re.sub(r"\s+(ASC|DESC)$", "", s, flags=re.I))
    # A nonclustered index carries the clustered key as its row locator, appended
    # in CK order, ascending, at the very end. So drop trailing key columns only
    # while they form a LEADING PREFIX of the CK -- those the locator already
    # provides (a DESC ORDER BY there gets a backward scan). A CK column that is
    # mid-key, or the 2nd CK column without the 1st, the locator cannot serve, so
    # it stays explicit.
    m = 0
    for cand in range(1, min(len(key), len(ck_list)) + 1):
        if [_bare(x) for x in key[-cand:]] == ck_list[:cand]:
            m = cand
    if m:
        del key[-m:]
    keyset = {_bare(k) for k in key}
    include, dropped_ck = [], (m > 0)
    for name, _d in inc + ineq:                             # C (+ demoted range cols)
        k = _debracket(name)
        if k and k in ck:                                   # a CK col is never worth INCLUDE-ing
            dropped_ck = True
            continue
        if (k and k not in keyset
                and k not in {_debracket(x) for x in include}):
            include.append(name)

    if not key:
        return None                                         # all-CK key -- the clustered index serves it
    dmv_key = [_debracket(x) for x in _norm_cols(_v(row, "key_columns_display"))]
    if [_bare(k) for k in key] == dmv_key:
        return None                                         # same order the DMV already gave

    name = (_v(row, "index_name") or "IX_realigned").replace("<<missing #", "IX_realigned_").replace(">>", "")
    line = f"CREATE INDEX [{name}] ON {tbl_raw} ({', '.join(key)})"
    if include:
        line += f" INCLUDE ({', '.join(include)})"
    line += _fillfactor_clause(fillfactor)
    ck_note = ""
    if dropped_ck:
        ck_note = (" Clustered-key columns (a leading CK prefix at the key tail, or in INCLUDE) are "
                   "omitted -- a nonclustered index already carries them as the row locator.")
    wkind = (_v(row, "missing_window_kind") or "").strip().upper()
    if wkind in ("FPOC", "POC"):
        # a window-function realignment: only the P / O / F breakdown, not the
        # generic GROUP BY / ORDER BY caveat (Curtis's call).
        _p = ", ".join(n for n, _ in grp) or "(none)"
        _o = ", ".join(n + d for n, d in ordby) or "(none)"
        caveat = (f"        --         [{wkind}] the driving query uses a window function; this "
                  f"realigned key is a windowing {wkind} index -- P (PARTITION BY, seen as the "
                  f"plan's Segment) = {_p}; O (OVER ... ORDER BY) = {_o}"
                  + (f"; F (WHERE) leads on {', '.join(n for n, _ in eq)}." if wkind == "FPOC"
                     else " (no WHERE filter).")
                  + ck_note)
    else:
        caveat = ("        --         key ordered equality/filter -> GROUP BY -> ORDER BY (last) so "
                  "the query's Sort / Hash Aggregate is removed, not just the lookup; range / "
                  "inequality cols stay in INCLUDE (can't share the key with ORDER BY without a "
                  "Sort). If a range is highly selective, prefer the DMV index above." + ck_note)
    return [f"        REALIGN -- {line};", caveat]


def _format_index_analysis(raw, generated, fillfactor=DEFAULT_FILLFACTOR, show_missing=False,
                           realign=False):
    """raw usp_IndexAnalysis grid + the tool's own generated indexes
    ({table_lower: [(name,[keys],[inc]), ...]}) -> readable lines indented 4.
    show_missing (default off): also list the missing-index DMV proposals, after
    the existing indexes -- they are workload-volatile, so opt in with
    --show-missing-indexes. realign (default off, implies show_missing): under
    each proposal add a REALIGN -- CREATE INDEX line whose key is reordered
    equality/filter -> GROUP BY -> ORDER BY (last)."""
    sets = _ia_result_sets(raw)
    main = next((s for s in sets
                 if {"index_action", "index_name", "type_desc"} <= set(s["cols"])), None)
    if main is None:
        out = ["    (could not parse usp_IndexAnalysis output -- raw below)"]
        out += [f"    {ln}" for ln in raw.splitlines()]
        return out

    rows = main["rows"]
    tbl_raw = _v(rows[0], "object_name") if rows else ""
    actionable = [r for r in rows if _v(r, "index_action") not in ("", "---")]
    keep = [r for r in rows if _v(r, "index_action") in ("", "---")]
    other_rows = [r for r in actionable if _v(r, "index_action") != "CREATE"]
    create_rows = [r for r in actionable if _v(r, "index_action") == "CREATE"]

    # the table's clustered key -- a nonclustered index carries it as the row
    # locator, so --realign-missing-indexes must not re-add it.
    _clu = next((r for r in rows if "CLUSTERED" in _v(r, "type_desc").upper()
                 and "NONCLUSTERED" not in _v(r, "type_desc").upper()), None)
    ck_cols = _norm_cols(_v(_clu, "key_columns_display")) if _clu else []

    def _impact(r):
        try:
            return float(_v(r, "missing_impact") or 0)
        except ValueError:
            return 0.0

    # collapse duplicate missing-index proposals into a distinct list: a proposal
    # is the same when its key + include columns match; the highest-impact one
    # wins, and its query_id list is the union across the collapsed group. The
    # missing-index DMVs routinely return the same index once per driving query.
    mi_sig, mi_winners = {}, []
    for r in create_rows:
        sig = (tuple(_norm_cols(_v(r, "key_columns_display"))),
               tuple(_norm_cols(_v(r, "include_columns_display"))))
        if sig in mi_sig:
            mi_sig[sig].append(r)
        else:
            mi_sig[sig] = [r]
            mi_winners.append(sig)
    mi_groups = []
    for sig in mi_winners:
        grp = sorted(mi_sig[sig], key=_impact, reverse=True)
        ids = []
        for r in grp:
            for qid in (_v(r, "qs_query_ids") or "").split(","):
                qid = qid.strip()
                if qid and qid not in ids:
                    ids.append(qid)
        mi_groups.append((grp[0], grp, ids))
    mi_groups.sort(key=lambda t: _impact(t[0]), reverse=True)

    n_actions = len(other_rows) + (len(mi_groups) if show_missing else 0)
    n_real = len(other_rows) + len(keep)       # real indexes only -- never the CREATE proposals
    out = [f"    {n_real} index(es) on this table, {n_actions} flagged for action."]

    def order(r):
        a = _v(r, "index_action")
        return (_IA_ACTION_ORDER.index(a) if a in _IA_ACTION_ORDER else 99, a)

    for r in sorted(other_rows, key=order):
        name = _v(r, "index_name") or "(heap / clustered)"
        out.append("")
        out.append(f"    [{_v(r, 'index_action')}]  {name}")
        bits = [b for b in (_v(r, "type_desc"),
                            f"{_v(r, 'size_mb')} MB" if _v(r, "size_mb") else "") if b]
        usage = " / ".join(f"{_v(r, k) or '0'} {lbl}" for k, lbl in (
            ("user_seeks", "seeks"), ("user_scans", "scans"),
            ("user_lookups", "lookups"), ("user_updates", "updates")))
        out.append(f"        {', '.join(bits)}  --  {usage}")
        if _v(r, "key_columns_display"):
            out.append(f"        keys:     {_v(r, 'key_columns_display')}")
        if _v(r, "include_columns_display"):
            out.append(f"        include:  {_v(r, 'include_columns_display')}")
        flags = "  ".join(b for b in (_v(r, "index_pros"), _v(r, "index_cons")) if b)
        if flags:
            out.append(f"        flags:    {flags}")
        if _v(r, "duplicate_of"):
            out.append(f"        duplicate of:  {_v(r, 'duplicate_of')}")
        if _v(r, "overlaps_with"):
            out.append(f"        overlaps with: {_v(r, 'overlaps_with')}")
        for sqlcol in ("create_index_sql", "drop_index_sql"):
            if _v(r, sqlcol):
                out.append(f"        {_v(r, sqlcol)}")
        # a DROP ships with the CREATE that reverses it, unless the proc already
        # gave one (change control / rollback).
        if _v(r, "index_action").startswith("DROP") and not _v(r, "create_index_sql"):
            out.extend(_recreate_index_ddl(r, fillfactor))

    if keep:
        out.append("")
        out.append("    existing indexes (no action):")
        w = max((len(_v(r, "index_name")) for r in keep), default=0)
        for r in keep:
            nm = _v(r, "index_name") or "(heap / clustered)"
            kc = _v(r, "key_columns_display")
            ic = _v(r, "include_columns_display")
            tail = f"  keys {kc}" + (f"  include {ic}" if ic else "")
            out.append(f"        {nm.ljust(w)}  {_v(r, 'type_desc')}{tail}")

    # cross-reference: does the tool's own generated index just re-lead an
    # existing one? (the BLEND / "widen this instead" hint Curtis asked for)
    for _gname, gkeys, _ginc in generated.get(_debracket(tbl_raw), []):
        if not gkeys:
            continue
        lead = _debracket(gkeys[0])
        for r in rows:
            if _v(r, "index_action") == "CREATE":
                continue                       # can't "widen" a proposed index
            ecols = _norm_cols(_v(r, "key_columns_display"))
            if ecols and ecols[0] == lead:
                en = _v(r, "index_name")
                gk = ", ".join(gkeys)
                full = [_debracket(k) for k in gkeys]
                covered = ecols[:len(full)] == full
                if covered:
                    out.append("")
                    out.append(f"    >> the recommended index ({gk}) is a key-prefix of existing "
                               f"{en} -- widen {en}'s INCLUDE rather than add a new index.")
                else:
                    out.append("")
                    out.append(f"    >> the recommended index leads on {gkeys[0]}; existing {en} "
                               f"already leads on the same column -- consider REALIGN/BLEND "
                               f"(widen {en}) instead of a second index.")
                break

    # missing-index DMV proposals -- AFTER the existing indexes, and only when asked
    # for (--show-missing-indexes): they are workload-volatile and not what a
    # drop / realign review is usually about.
    if show_missing and mi_groups:
        out.append("")
        out.append("    PROPOSED MISSING INDEX(ES) from the missing-index DMVs, distinct, "
                   "highest impact first:")
        for cl in textwrap.wrap(_MISSING_INDEX_CAVEAT, 96):
            out.append(f"    {cl}")
        out.append(f"    {_MISSING_INDEX_CAVEAT_URL}")
        if realign:
            out.append("")
            for bl in textwrap.wrap(_REALIGN_BLURB, 96):
                out.append(f"    {bl}")
        for winner, grp, ids in mi_groups:
            out.append("")
            out.append(f"    [CREATE]  {_v(winner, 'index_name') or '(proposed)'}")
            if _v(winner, "key_columns_display"):
                out.append(f"        keys:     {_v(winner, 'key_columns_display')}")
            if _v(winner, "include_columns_display"):
                out.append(f"        include:  {_v(winner, 'include_columns_display')}")
            if len(grp) > 1:
                seen_i = ", ".join(f"{_impact(g):.2f}" for g in grp)
                out.append(f"        impact:   {_impact(winner):.2f}  "
                           f"(best of {len(grp)} duplicate proposals: {seen_i})")
            else:
                out.append(f"        impact:   {_impact(winner):.2f}")
            if ids:
                out.append(f"        query_id(s): {', '.join(ids)}")
            ddl = _v(winner, "create_index_sql")
            if ddl:
                # the proc appends "  -- impact N ; QS query_id(s): N" -- now shown
                # on its own lines above, and only for the single winner, so drop it
                ddl = re.sub(r"\s*--\s*impact\b.*$", "", ddl).rstrip()
                out.append(f"        {ddl}")
            if realign:
                rl = _fpoc_realign_index(winner, tbl_raw, fillfactor, ck_cols)
                if rl:
                    out.extend(rl)

    blast = next((s for s in sets if "access_op" in s["cols"] and s["rows"]), None)
    if blast:
        out.append("")
        out.append("    drop-risk -- Query Store still shows reads on a drop candidate:")
        for r in blast["rows"]:
            out.append(f"        {_v(r, 'index_name')}: query_id {_v(r, 'query_id')}  "
                       f"{_v(r, 'access_op')}  {_v(r, 'executions')} execs, "
                       f"avg {_v(r, 'avg_duration_ms')} ms")
    return out


def _generated_index_map(result):
    """{table_lower: [(name, [keys], [includes]), ...]} from the fired recommendations."""
    m = {}
    for r in result.get("recommendations", []):
        if not r.get("ddl") or not r.get("ddl_table"):
            continue
        parsed = _parse_generated_index(r["ddl"])
        if parsed:
            m.setdefault(_debracket(r["ddl_table"]), []).append(parsed)
    return m


# ===========================================================================
# Rendering
# ===========================================================================

def _fmt(n, nd=0):
    return f"{n:,.{nd}f}"


# --- colour: a line-scoped post-pass over render_text() output ----------------
# With colour OFF it is a pure pass-through, so --no-recommendations / piped
# output stay byte-identical.

_RULE_RE = re.compile(r"^-- [A-Z].*?-{2,}\s*$")
_SUBRULE_RE = re.compile(r"^\s+-- [A-Z].*--\s*$")
_CODE_RE = re.compile(r"^(\s*)\[([A-Z_]+)\](.*)$")
_ACTION_RE = re.compile(r"^(\s+\*?\S[^\n]*?\s)(ship|hold -- .+|investigate -- .+)$")

# T-SQL keywords in a generated CREATE / DROP INDEX line -> orange
_TSQL_KW_RE = re.compile(
    r"\b(CREATE|DROP|ALTER|TABLE|ADD|CONSTRAINT|PRIMARY|KEY|UNIQUE|CLUSTERED|"
    r"NONCLUSTERED|INDEX|ON|INCLUDE|WHERE|WITH|ASC|DESC|DATA_COMPRESSION)\b")


def _hl_ddl(s, c, base):
    """Colour recognised T-SQL keywords orange, the rest in `base` style."""
    parts = _TSQL_KW_RE.split(s)
    return "".join(c(p, "orange", "bold") if i % 2 else c(p, base)
                   for i, p in enumerate(parts) if p)


def _colourise(text, on):
    if not on:
        return text
    c = _Colour(True)
    out, section = [], None
    for line in text.split("\n"):
        if _RULE_RE.match(line):
            section = line.split()[1]
            out.append(c(line, "cyan", "bold"))
            continue
        if _SUBRULE_RE.match(line):
            out.append(c(line, "cyan", "bold"))
            continue
        mc = _CODE_RE.match(line)
        if mc:
            out.append(f"{mc.group(1)}{c('[' + mc.group(2) + ']', 'yellow')}{mc.group(3)}")
            continue
        ma = _ACTION_RE.match(line)
        if ma:
            verb = ma.group(2)
            sty = ("green",) if verb == "ship" else ("yellow",) if verb.startswith("hold") else ("cyan",)
            out.append(ma.group(1) + c(verb, *sty))
            continue
        if section == "VERDICT" and line.startswith("  ") and not line.startswith("   "):
            for call, sty in _VERDICT_STYLE.items():
                if call in line:
                    line = line.replace(call, c(call, *sty), 1)
                    break
            out.append(line)
            continue
        stripped = line.lstrip()
        indent = line[:len(line) - len(stripped)]
        if stripped.startswith("-- ROLLBACK:"):
            label, _, rest = stripped.partition(":")
            label = c(label + ":", "magenta", "bold")   # the undo marker stands apart
            if re.search(r"\b(CREATE|DROP)\b.*\bINDEX\b", rest):
                out.append(indent + label + _hl_ddl(rest, c, "green"))
            else:
                out.append(indent + label + c(rest, "magenta", "bold"))
            continue
        if stripped.startswith("-- also recommended for:"):
            out.append(c(line, "dim"))
            continue
        if stripped.startswith("PROPOSED MISSING INDEX(ES) "):
            head = "PROPOSED MISSING INDEX(ES)"          # same colour as [CREATE]
            out.append(indent + c(head, "yellow") + c(stripped[len(head):], "white"))
            continue
        if stripped in _MI_BLURB_LINES:                  # the caveat + link + REALIGN gloss
            if "REALIGN" in stripped:                    # the word matches its colour on the actual line
                painted = stripped.replace(
                    "REALIGN", c("REALIGN", "yellow") + _ANSI["lightblue"], 1)
                out.append(indent + _ANSI["lightblue"] + painted + _ANSI["reset"])
            else:
                out.append(indent + c(stripped, "lightblue"))
            continue
        if stripped.startswith("-- CREATE ") or stripped.startswith("-- DROP "):
            out.append(indent + _hl_ddl(stripped, c, "green"))
            continue
        if stripped.startswith("REALIGN -- "):
            _, _, rest = stripped.partition(" -- ")       # 'REALIGN' label, then the statement
            out.append(indent + c("REALIGN", "yellow") + " " + _hl_ddl("-- " + rest, c, "green"))
            continue
        out.append(line)
    return "\n".join(out)


_DETAIL_PREFIX_RE = re.compile(r"^'[^']*'(?: vs baseline '[^']*')?:\s*")


def render_text(plans, base_idx, result, full=False):
    """full=False (default) is the BRIEF report: verdict, recommendations, action,
    caveats. full=True adds INPUTS, SIGNALS, and the four evidence tables."""
    base = plans[base_idx]
    L = []
    if full:
        L.append("=" * 78)
        L.append(f"COMPARE PLANS -- {len(plans)} actual plans, baseline: '{base.label}'")
        L.append("=" * 78)
        L.append("")
        L.append("-- INPUTS --------------------------------------------------------------------")
        for i, p in enumerate(plans):
            mark = "  (baseline)" if i == base_idx else ""
            L.append(f"  [{i + 1}] {p.label}{mark}")
            L.append(f"      file        : {p.path}")
            L.append(f"      query hash  : {p.query_hash or '(none)'}   plan hash: {p.query_plan_hash or '(none)'}")
            L.append(f"      CE model    : {p.ce_model}   DOP: {p.dop or '1'}   build: {p.build}")
            if p.parameters:
                for name, comp, run in p.parameters:
                    flag = ""
                    if comp is not None and run is not None and comp != run:
                        flag = "   <-- compiled for a different value than it ran with"
                    L.append(f"      param {name}: compiled={comp} runtime={run}{flag}")
        L.append("")
    else:
        L.append(f"COMPARE PLANS -- {len(plans)} plans, baseline: '{base.label}'   "
                 f"(brief; --full for the evidence tables)")
        L.append("")

    L.append("-- VERDICT (vs baseline; advisory -- you decide) ----------------------------")
    if not result["verdict"]:
        L.append("  (nothing to compare against the baseline)")
    for label, v in result["verdict"].items():
        bits = []
        if v["improvements"]:
            bits.append("+ " + ", ".join(v["improvements"]))
        if v["regressions"]:
            bits.append("- " + ", ".join(v["regressions"]))
        if v["reads_note"]:
            bits.append(v["reads_note"])
        L.append(f"  {label:<28} {v['call']:<8} {'  |  '.join(bits)}")
    L.append("")

    if full:
        L.append("-- SIGNALS -------------------------------------------------------------------")
        if not result["signals"]:
            L.append("  (none fired -- read the matrix and resource deltas below)")
        for s in result["signals"]:
            L.append(f"  [{s['code']}]")
            L.append(f"      {s['detail']}")
        L.append("")

    if "recommendations" in result:
        L.append("-- RECOMMENDATIONS (advisory; every fix is commented-out text for review) ------")
        if not result["recommendations"]:
            L.append("  (no canned fix for the fired signals -- --emit-prompt for a written read)")
        for r in result["recommendations"]:
            where = "all versions" if r["scope"] == "global" else r["scope"]
            L.append(f"  [{r['code']}]  ({where})")
            L.append(f"      {r['headline']}")
            what = _DETAIL_PREFIX_RE.sub("", r.get("detail", "")).strip()
            if what:
                L.append(f"      what happened: {what}")
            L.append(f"      fix: {r['fix']}")
            if r["ddl"]:
                for dl in r["ddl"].splitlines():
                    L.append(f"      {dl}")
                if r.get("ddl_also"):
                    L.append(f"      -- also recommended for: {', '.join(r['ddl_also'])}")
            L.append(f"      when it does not apply: {r['caveat']}")
        L.append("")
        L.append("  -- RECOMMENDED ACTION per version --")
        for i, p in enumerate(plans):
            mark = "*" if i == base_idx else " "
            L.append(f"   {mark}{p.label[:30]:<30} {result['actions'][p.label]}")
        L.append("")

    ia = result.get("index_analysis")
    if ia:
        srv = next(iter(ia.values()))["server"]
        gen = _generated_index_map(result)
        L.append(f"-- INDEX ANALYSIS (live -- usp_IndexAnalysis on {srv}) --------------------")
        L.append("  !! reads the LIVE catalog -- the plans compared here were captured earlier;")
        L.append("     the table's indexes may have changed since.")
        L += _ia_uptime_lines(ia, result.get("min_uptime_days", INDEX_CHANGE_MIN_UPTIME_DAYS))
        for tbl, res in ia.items():
            L.append("")
            if not res["ok"]:
                L.append(f"  {tbl}  [FAILED]")
                for ln in res["text"].splitlines():
                    L.append(f"      {ln}")
                continue
            L.append(f"  {tbl}")
            L.extend(_format_index_analysis(
                res["text"], gen, result.get("fill_factor", DEFAULT_FILLFACTOR),
                result.get("show_missing_indexes", False),
                result.get("realign_missing_indexes", False)))
        L.append("")

    if not full:
        L.append("-- CAVEATS ------------------------------------------------------------------")
        _append_caveats(L, result)
        L.append("")
        return "\n".join(L)

    L.append("-- LEAF ACCESS (one row per table; read across the versions) ----------------")
    header = f"  {'table / access':<38}" + "".join(f"{p.label[:20]:<22}" for p in plans)
    L.append(header)
    for k in result["frame_keys"]:
        cells = []
        for p in plans:
            c = p.leaf_accesses.get(k)
            if not c:
                cells.append(f"{'-- absent --':<22}")
            else:
                spill = " SPILL" if c["spill"] else ""
                cells.append(f"{c['op'][:12]} {_fmt(c['actual_rows'])}r/{_fmt(c['reads'])}rd{spill}"[:21].ljust(22))
        L.append(f"  {k:<38}" + "".join(cells))
        idx_row = []
        for p in plans:
            c = p.leaf_accesses.get(k)
            idx_row.append((("idx " + c["index"])[:21]).ljust(22) if c else " " * 22)
        L.append(f"  {'':<38}" + "".join(idx_row))
    L.append("  (cell = physical op, rows out, logical reads)")
    L.append("")

    L.append("-- STRUCTURAL DELTAS vs baseline -------------------------------------------")
    any_struct = False
    for p in plans:
        if p is base:
            continue
        deltas = result["structural"].get(p.label, [])
        if not deltas:
            continue
        any_struct = True
        L.append(f"  {p.label}:")
        for d in deltas:
            L.append(f"      {d}")
    if not any_struct:
        L.append("  (no shape differences from the baseline)")
    L.append("")

    L.append("-- RESOURCE DELTAS -------------------------------------------------------------")
    L.append(f"  {'version':<24}{'reads':>14}{'grant KB':>12}{'used KB':>12}{'DOP':>6}{'cost':>12}{'spills':>8}")
    for i, p in enumerate(plans):
        mark = "*" if i == base_idx else " "
        L.append(f" {mark}{p.label[:23]:<23}{_fmt(p.total_logical_reads):>14}{_fmt(p.granted_kb):>12}"
                 f"{_fmt(p.used_kb):>12}{(p.dop or '1'):>6}{p.subtree_cost:>12,.3f}{len(p.spills):>8}")
    L.append("  (* = baseline; cost is an ESTIMATE, never a measurement)")
    L.append("")

    L.append("-- TIMING & EXECUTION -----------------------------------------------------------")
    L.append(f"  {'version':<24}{'elapsed ms':>12}{'CPU ms':>10}{'UDF ms':>9}{'batch ops':>11}"
             f"{'lookups':>10}{'spill IO pg':>13}{'thr skew':>10}")
    for i, p in enumerate(plans):
        mark = "*" if i == base_idx else " "
        el = _fmt(p.elapsed_ms) if p.elapsed_ms is not None else "n/a"
        cp = _fmt(p.cpu_ms) if p.cpu_ms is not None else "n/a"
        sk = ("inf" if p.worst_thread_skew == float("inf")
              else f"{p.worst_thread_skew:,.0f}x" if p.worst_thread_skew > 1 else "-")
        L.append(f" {mark}{p.label[:23]:<23}{el:>12}{cp:>10}{_fmt(p.udf_elapsed_ms):>9}"
                 f"{p.batch_operators:>11}{_fmt(p.lookup_executions):>10}"
                 f"{_fmt(p.spill_tempdb_pages):>13}{sk:>10}")
    L.append("  (elapsed/CPU come from QueryTimeStats -- 'n/a' if the capture omitted them)")
    L.append("")

    L.append("-- CAVEATS ------------------------------------------------------------------")
    _append_caveats(L, result)
    L.append("")
    return "\n".join(L)


def _append_caveats(L, result):
    if any(s["code"] in ("SLOWER", "FASTER") for s in result["signals"]):
        L.append("  !! TIMING is one measurement. Cache warmth, blocking and concurrency move "
                 "elapsed time between runs -- re-capture if the difference is borderline, and "
                 "trust reads / spills / grant over a single elapsed number.")
    if result["small_data"]:
        L.append(f"  !! SMALL DATA: the largest table access in any plan returned "
                 f"{_fmt(result['max_leaf_rows'])} rows (< {_fmt(result['small_data_rows'])}). "
                 f"A verdict here may not hold at production row counts. Capture against "
                 f"representative data, or check the cardinalities against Query Store.")
    if any(s["code"] == "QUERY_HASH_MISMATCH" for s in result["signals"]):
        L.append("  !! The versions do not share a query hash. Confirm they return the same "
                 "results before acting on this comparison.")
    L.append("  Estimated cost is the optimizer's fear, not the query's behaviour. Rank on "
             "reads, spills, memory, and actual-vs-estimated rows.")


def render_md(plans, base_idx, result):
    base = plans[base_idx]
    L = [f"# Compare plans -- {len(plans)} actual plans (baseline: **{base.label}**)", ""]

    L.append("## Inputs")
    L.append("")
    L.append("| # | version | query hash | plan hash | CE | DOP |")
    L.append("|---|---|---|---|---|---|")
    for i, p in enumerate(plans):
        mark = " (baseline)" if i == base_idx else ""
        L.append(f"| {i + 1} | {p.label}{mark} | `{p.query_hash or '-'}` | `{p.query_plan_hash or '-'}` "
                 f"| {p.ce_model} | {p.dop or '1'} |")
    L.append("")

    L.append("## Verdict")
    L.append("")
    L.append("_Advisory. You decide._")
    L.append("")
    if result["verdict"]:
        L.append("| version | call | improvements | regressions | reads |")
        L.append("|---|---|---|---|---|")
        for label, v in result["verdict"].items():
            L.append(f"| {label} | **{v['call']}** | {', '.join(v['improvements']) or '-'} "
                     f"| {', '.join(v['regressions']) or '-'} | {v['reads_note'] or '-'} |")
    L.append("")

    L.append("## Signals")
    L.append("")
    if not result["signals"]:
        L.append("_None fired -- read the matrix and resource table below._")
    for s in result["signals"]:
        L.append(f"- **{s['code']}** -- {s['detail']}")
    L.append("")

    if "recommendations" in result:
        L.append("## Recommendations")
        L.append("")
        L.append("_Advisory. Every fix is commented-out text for review._")
        L.append("")
        if not result["recommendations"]:
            L.append("_No canned fix for the fired signals -- use `--emit-prompt` for a written read._")
            L.append("")
        for r in result["recommendations"]:
            where = "all versions" if r["scope"] == "global" else f"`{r['scope']}`"
            L.append(f"### {r['code']} ({where})")
            L.append("")
            L.append(f"**{r['headline']}**")
            L.append("")
            L.append(r["fix"])
            L.append("")
            if r["ddl"]:
                L.append("```sql")
                L.append(r["ddl"])
                L.append("```")
                L.append("")
                if r.get("ddl_also"):
                    L.append(f"_Also recommended for: {', '.join(r['ddl_also'])}._")
                    L.append("")
            L.append(f"_When this does not apply: {r['caveat']}_")
            L.append("")
        L.append("### Recommended action")
        L.append("")
        L.append("| version | action |")
        L.append("|---|---|")
        for i, p in enumerate(plans):
            mark = " \\*" if i == base_idx else ""
            L.append(f"| {p.label}{mark} | {result['actions'][p.label]} |")
        L.append("")

    ia = result.get("index_analysis")
    if ia:
        srv = next(iter(ia.values()))["server"]
        gen = _generated_index_map(result)
        L.append(f"## Index analysis (live -- `usp_IndexAnalysis` on `{srv}`)")
        L.append("")
        L.append("_Reads the live catalog -- the plans compared here were captured earlier; the "
                 "table's indexes may have changed since._")
        L.append("")
        up = _ia_uptime(ia)
        if up:
            mind = result.get("min_uptime_days", INDEX_CHANGE_MIN_UPTIME_DAYS)
            L.append(f"_Instance started {up['start']} -- up {up['days']:,} "
                     f"day{'s' if up['days'] != 1 else ''}._")
            L.append("")
            if up["days"] < mind:
                L.append(f"> **Only {up['days']:,} day{'s' if up['days'] != 1 else ''} of uptime.** "
                         f"`usp_IndexAnalysis` leans on counters that reset on restart "
                         f"(`sys.dm_db_index_usage_stats`, the missing-index DMVs), so its "
                         f"`DROP-USAGE` / `MISSING` rows are not yet reliable. Best practice: at "
                         f"least {mind} days, ideally a full business cycle (~4 weeks, to catch "
                         f"weekly and month-end jobs) of normal activity before acting on them.")
                L.append("")
        for tbl, res in ia.items():
            L.append(f"### `{tbl}`" + ("" if res["ok"] else " -- **FAILED**"))
            L.append("")
            L.append("```")
            if res["ok"]:
                for ln in _format_index_analysis(
                        res["text"], gen,
                        result.get("fill_factor", DEFAULT_FILLFACTOR),
                        result.get("show_missing_indexes", False),
                        result.get("realign_missing_indexes", False)):
                    L.append(ln[4:] if ln.startswith("    ") else ln)
            else:
                L.append(res["text"])
            L.append("```")
            L.append("")

    L.append("## Leaf access")
    L.append("")
    L.append("<div style=\"overflow-x:auto\">")
    L.append("")
    L.append("| table / access | " + " | ".join(p.label for p in plans) + " |")
    L.append("|---" * (len(plans) + 1) + "|")
    for k in result["frame_keys"]:
        cells = []
        for p in plans:
            c = p.leaf_accesses.get(k)
            if not c:
                cells.append("_absent_")
            else:
                spill = " **SPILL**" if c["spill"] else ""
                cells.append(f"{c['op']} on `{c['index']}`<br>{_fmt(c['actual_rows'])} rows / "
                             f"{_fmt(c['reads'])} reads{spill}")
        L.append(f"| {k} | " + " | ".join(cells) + " |")
    L.append("")
    L.append("</div>")
    L.append("")

    L.append("## Structural deltas vs baseline")
    L.append("")
    any_struct = False
    for p in plans:
        if p is base:
            continue
        deltas = result["structural"].get(p.label, [])
        if not deltas:
            continue
        any_struct = True
        L.append(f"**{p.label}**")
        for d in deltas:
            L.append(f"- {d}")
        L.append("")
    if not any_struct:
        L.append("_No shape differences from the baseline._")
        L.append("")

    L.append("## Resource deltas")
    L.append("")
    L.append("| version | reads | grant KB | used KB | DOP | cost (est) | spills |")
    L.append("|---|---|---|---|---|---|---|")
    for i, p in enumerate(plans):
        mark = " \\*" if i == base_idx else ""
        L.append(f"| {p.label}{mark} | {_fmt(p.total_logical_reads)} | {_fmt(p.granted_kb)} | "
                 f"{_fmt(p.used_kb)} | {p.dop or '1'} | {p.subtree_cost:,.3f} | {len(p.spills)} |")
    L.append("")
    L.append("\\* baseline. Cost is an estimate, never a measurement.")
    L.append("")

    L.append("## Timing & execution")
    L.append("")
    L.append("| version | elapsed ms | CPU ms | UDF ms | batch ops | lookups | spill IO (pages) | thread skew |")
    L.append("|---|---|---|---|---|---|---|---|")
    for i, p in enumerate(plans):
        mark = " \\*" if i == base_idx else ""
        el = _fmt(p.elapsed_ms) if p.elapsed_ms is not None else "n/a"
        cp = _fmt(p.cpu_ms) if p.cpu_ms is not None else "n/a"
        sk = ("inf" if p.worst_thread_skew == float("inf")
              else f"{p.worst_thread_skew:,.0f}x" if p.worst_thread_skew > 1 else "-")
        L.append(f"| {p.label}{mark} | {el} | {cp} | {_fmt(p.udf_elapsed_ms)} | {p.batch_operators} "
                 f"| {_fmt(p.lookup_executions)} | {_fmt(p.spill_tempdb_pages)} | {sk} |")
    L.append("")

    timing_caveat = any(s["code"] in ("SLOWER", "FASTER") for s in result["signals"])
    if result["small_data"] or timing_caveat or any(
            s["code"] == "QUERY_HASH_MISMATCH" for s in result["signals"]):
        L.append("## Caveats")
        L.append("")
        if timing_caveat:
            L.append("- **Timing is one measurement.** Cache warmth, blocking and concurrency move "
                     "elapsed time between runs. Re-capture if the difference is borderline; trust "
                     "reads / spills / grant over a single elapsed number.")
        if result["small_data"]:
            L.append(f"- **Small data:** largest table access returned {_fmt(result['max_leaf_rows'])} "
                     f"rows (< {_fmt(result['small_data_rows'])}). The verdict may not hold at "
                     f"production scale.")
        if any(s["code"] == "QUERY_HASH_MISMATCH" for s in result["signals"]):
            L.append("- **Query hash mismatch:** confirm the versions return the same results.")
        L.append("")
    return "\n".join(L)


def build_json(plans, base_idx, result):
    return {
        "baseline": plans[base_idx].label,
        "plans": [
            {
                "label": p.label, "path": p.path,
                "query_hash": p.query_hash, "query_plan_hash": p.query_plan_hash,
                "ce_model": p.ce_model, "dop": p.dop or "1",
                "subtree_cost": round(p.subtree_cost, 4),
                "total_logical_reads": p.total_logical_reads,
                "granted_kb": p.granted_kb, "used_kb": p.used_kb,
                "elapsed_ms": p.elapsed_ms, "cpu_ms": p.cpu_ms,
                "udf_elapsed_ms": p.udf_elapsed_ms, "udf_cpu_ms": p.udf_cpu_ms,
                "batch_operators": p.batch_operators,
                "lookup_executions": p.lookup_executions,
                "spill_tempdb_pages": p.spill_tempdb_pages, "spill_level": p.spill_level,
                "worst_thread_skew": (None if p.worst_thread_skew == float("inf")
                                      else p.worst_thread_skew),
                "effectively_serial_ops": p.effectively_serial_ops,
                "grant_overalloc_ratio": round(p.grant_overalloc_ratio, 2),
                "sort_count": p.sort_count, "spool_count": p.spool_count,
                "joins": p.joins, "spills": p.spills,
                "parameters": [
                    {"name": n, "compiled": c, "runtime": r} for n, c, r in p.parameters
                ],
                "missing_indexes": [
                    {"table": t, "columns": [{"usage": u, "cols": list(cs)} for u, cs in cols],
                     "impact": imp}
                    for t, cols, imp in p.missing_indexes
                ],
                "leaf_accesses": p.leaf_accesses,
            }
            for p in plans
        ],
        "verdict": result["verdict"],
        "signals": result["signals"],
        "structural": result["structural"],
        "small_data": result["small_data"],
        "max_leaf_rows": result["max_leaf_rows"],
        "detections": result.get("detections", []),
        "recommendations": result.get("recommendations", []),
        "actions": result.get("actions", {}),
        "index_analysis": result.get("index_analysis", {}),
        "index_analysis_uptime": _ia_uptime(result.get("index_analysis")),
    }


def build_prompt(plans, base_idx, result):
    L = []
    L.append("You are reading N SQL Server ACTUAL execution plans for what is meant to be the same")
    L.append("query, written different ways (or run with different parameters). Rank them best to")
    L.append("worst for this workload. Explain what changed between them and whether the plan-shape")
    L.append("change accounts for the difference in reads / time / memory. Call out anything that")
    L.append("looks better on estimated cost but worse in actual reads, spills, or memory grant.")
    L.append("Then, for every version that is not the best, give a CONCRETE FIX -- the index, the")
    L.append("rewrite, the hint, or the statistics change -- that would bring it up to the best")
    L.append("version, and say why. Stay consistent with the RECOMMENDATIONS section below (extend")
    L.append("it where the plan warrants; do not contradict it). Any index you write is a starting")
    L.append("point for review, never ready-to-run DDL. Cost is always an estimate.")
    L.append("")
    L.append(f"Baseline for the deltas below: '{plans[base_idx].label}'.")
    L.append("")
    L.append(render_text(plans, base_idx, result, full=True))
    L.append("")
    if result.get("detections"):
        L.append("ANTI-PATTERNS DETECTED (deterministic, straight from the plan XML):")
        for d in result["detections"]:
            L.append(f"  - [{d['code']}] {d['detail']}")
        L.append("")
        L.append("The tool's own canned fixes for these codes are in "
                 "ComparePlans-Recommendations-Catalog.md -- extend them where the plan warrants; "
                 "do not contradict them.")
        L.append("")
    for p in plans:
        L.append("#" * 78)
        L.append(f"# DIGEST -- {p.label}   ({p.path})")
        L.append("#" * 78)
        digest = px.Lines()
        px.describe_statement(p.stmt_el, digest, 8)
        L.append("\n".join(digest))
        L.append("")
    return "\n".join(L)


# ===========================================================================
# Single-plan anti-pattern check (--single) -- no comparison, no verdict.
# The deterministic checklist half: run detect_antipatterns() on ONE plan,
# attach the catalog fix + generated DDL, and stop. "Why is this plan slow"
# stays with the Query Analyzer Plug-In (--single ... --emit-prompt).
# ===========================================================================

_SINGLE_CHECKS = ("eager index spool, local variable, non-sargable predicate, "
                  "implicit conversion, missing join predicate, no statistics, "
                  "1-row table variable")


def analyse_single(plan, small_data_rows, fill_factor=DEFAULT_FILLFACTOR):
    """A comparison-shaped result dict for one plan: no signals, detections only."""
    max_leaf = max((n.actual_rows for n in plan.nodes if not n.children), default=0)
    result = {
        "signals": [], "verdict": {},
        "detections": detect_antipatterns([plan]),
        "small_data": 0 < max_leaf < small_data_rows,
        "max_leaf_rows": max_leaf, "small_data_rows": small_data_rows,
        "fill_factor": fill_factor,
    }
    result["recommendations"] = recommend([plan], 0, result)
    result["action"] = recommended_action(plan, [plan], 0, result)
    return result


def _min_grant_note(p):
    """SQL Server warns 'Excessive Grant' even when the grant is only the configured
    minimum ('min memory per query', default 1 MB). One sentence saying so, so it is
    not read as an over-estimate to fix. '' when it does not apply."""
    if (p.granted_kb and p.granted_kb <= MIN_MEMORY_GRANT_KB
            and any("excessive grant" in w.lower() for w in p.warnings)):
        return (f"the Excessive Grant warning is on a {p.granted_kb:,.0f} KB grant -- that is SQL "
                f"Server's minimum ('min memory per query', default 1 MB), not an over-estimate "
                f"to fix.")
    return ""


def _single_plan_header(p):
    timing = (f"elapsed {p.elapsed_ms:,.0f} ms / CPU {p.cpu_ms:,.0f} ms"
              if p.elapsed_ms is not None else "no QueryTimeStats")
    grant = f"   grant {p.granted_kb:,.0f} KB (used {p.used_kb:,.0f})" if p.granted_kb else ""
    return [
        f"  file        : {p.path}",
        f"  query hash  : {p.query_hash or '(none)'}   plan hash: {p.query_plan_hash or '(none)'}",
        f"  CE model    : {p.ce_model}   DOP: {p.dop or '1'}   build: {p.build}",
        f"  actual plan : {'yes' if p.has_actual else 'NO -- estimated'}   "
        f"reads {p.total_logical_reads:,.0f}   {timing}{grant}",
    ]


def _single_index_analysis_lines(result):
    """The same INDEX ANALYSIS section the comparison path renders, indent 0."""
    ia = result.get("index_analysis")
    if not ia:
        return []
    srv = next(iter(ia.values()))["server"]
    gen = _generated_index_map(result)
    L = [f"-- INDEX ANALYSIS (live -- usp_IndexAnalysis on {srv}) --------------------",
         "  !! reads the LIVE catalog -- this plan was captured earlier;",
         "     the table's indexes may have changed since."]
    L += _ia_uptime_lines(ia, result.get("min_uptime_days", INDEX_CHANGE_MIN_UPTIME_DAYS))
    for tbl, res in ia.items():
        L.append("")
        if not res["ok"]:
            L.append(f"  {tbl}  [FAILED]")
            L += [f"      {ln}" for ln in res["text"].splitlines()]
            continue
        L.append(f"  {tbl}")
        L.extend(_format_index_analysis(
            res["text"], gen, result.get("fill_factor", DEFAULT_FILLFACTOR),
            result.get("show_missing_indexes", False),
            result.get("realign_missing_indexes", False)))
    L.append("")
    return L


def render_single_text(plan, result, full=False):
    p = plan
    L = [f"PLAN CHECK -- anti-patterns in '{p.label}'  (single plan; no comparison)", ""]
    L.append("-- PLAN --------------------------------------------------------------------")
    L += _single_plan_header(p)
    L.append("")

    dets = result["detections"]
    L.append("-- ANTI-PATTERNS (deterministic, from the plan XML) ------------------------")
    if not dets:
        L.append(f"  (none fired -- checks: {_SINGLE_CHECKS})")
    for d in dets:
        L.append(f"  [{d['code']}]")
        L.append(f"      {_DETAIL_PREFIX_RE.sub('', d['detail']).strip()}")
    if dets:
        L.append(f"  => action: {result['action']}")
    L.append("")

    if result["recommendations"]:
        L.append("-- RECOMMENDATIONS (advisory; every fix is commented-out text for review) ------")
        for r in result["recommendations"]:
            L.append(f"  [{r['code']}]")
            L.append(f"      {r['headline']}")
            L.append(f"      fix: {r['fix']}")
            for dl in (r["ddl"] or "").splitlines():
                L.append(f"      {dl}")
            L.append(f"      when it does not apply: {r['caveat']}")
        L.append("")

    L += _single_index_analysis_lines(result)

    if p.warnings:
        L.append("-- ENGINE WARNINGS -------------------------------------------------------------")
        for w in p.warnings:
            L.append(f"  {w}")
        note = _min_grant_note(p)
        if note:
            L.append(f"  note: {note}")
        L.append("")

    L.append("-- NOTE ----------------------------------------------------------------------")
    L.append("  A deterministic anti-pattern check, not a full plan analysis. For \"why is")
    L.append("  this plan slow / what should I change\", hand it to the Query Analyzer")
    L.append("  Plug-In:  --single <plan> --emit-prompt")
    if result.get("small_data"):
        L.append(f"  !! SMALL DATA: largest access returned {_fmt(result['max_leaf_rows'])} rows "
                 f"(< {_fmt(result['small_data_rows'])}) -- may not hold at production scale.")
    L.append("")

    if full:
        L.append("#" * 78)
        L.append(f"# DIGEST -- {p.label}   ({p.path})")
        L.append("#" * 78)
        digest = px.Lines()
        px.describe_statement(p.stmt_el, digest, 8)
        L.append("\n".join(digest))
        L.append("")

    return "\n".join(L)


def render_single_md(plan, result):
    p = plan
    L = [f"# Plan check -- anti-patterns in `{p.label}`", "", "_Single plan; no comparison._", "",
         "## Plan", ""]
    for ln in _single_plan_header(p):
        L.append(f"- {ln.strip()}")
    L += ["", "## Anti-patterns", ""]
    if not result["detections"]:
        L.append(f"_None fired. Checks: {_SINGLE_CHECKS}._")
    for d in result["detections"]:
        L += [f"### `{d['code']}`", "", _DETAIL_PREFIX_RE.sub("", d["detail"]).strip(), ""]
    if result["detections"]:
        L += [f"**Recommended action:** {result['action']}", ""]

    if result["recommendations"]:
        L += ["## Recommendations", "", "_Advisory; every fix is commented-out text for review._", ""]
        for r in result["recommendations"]:
            L += [f"### `{r['code']}` -- {r['headline']}", "", f"**fix:** {r['fix']}", ""]
            if r["ddl"]:
                L += ["```sql", r["ddl"], "```", ""]
            L += [f"_When this does not apply: {r['caveat']}_", ""]

    ia = result.get("index_analysis")
    if ia:
        srv = next(iter(ia.values()))["server"]
        gen = _generated_index_map(result)
        L += [f"## Index analysis (live -- `usp_IndexAnalysis` on `{srv}`)", ""]
        for tbl, res in ia.items():
            L += [f"### `{tbl}`" + ("" if res["ok"] else " -- **FAILED**"), "", "```"]
            if res["ok"]:
                L += [ln[4:] if ln.startswith("    ") else ln
                      for ln in _format_index_analysis(
                          res["text"], gen,
                          result.get("fill_factor", DEFAULT_FILLFACTOR),
                          result.get("show_missing_indexes", False),
                          result.get("realign_missing_indexes", False))]
            else:
                L.append(res["text"])
            L += ["```", ""]

    if p.warnings:
        L += ["## Engine warnings", ""]
        L += [f"- {w}" for w in p.warnings]
        note = _min_grant_note(p)
        if note:
            L += ["", f"_Note: {note}_"]
        L.append("")

    L += ["---", "_Deterministic anti-pattern check, not a full plan analysis. For \"why is this "
          "plan slow\", use `--single <plan> --emit-prompt` with the Query Analyzer Plug-In._"]
    return "\n".join(L)


def build_single_json(plan, result):
    p = plan
    return {
        "mode": "single",
        "plan": {
            "label": p.label, "file": p.path,
            "query_hash": p.query_hash, "query_plan_hash": p.query_plan_hash,
            "ce_model": p.ce_model, "dop": p.dop, "build": p.build,
            "actual": p.has_actual, "logical_reads": p.total_logical_reads,
            "elapsed_ms": p.elapsed_ms, "cpu_ms": p.cpu_ms,
            "granted_kb": p.granted_kb, "used_kb": p.used_kb,
        },
        "warnings": p.warnings,
        "warning_notes": ([_min_grant_note(p)] if _min_grant_note(p) else []),
        "antipatterns": result["detections"],
        "recommendations": result["recommendations"],
        "action": result["action"],
        "index_analysis": result.get("index_analysis", {}),
        "index_analysis_uptime": _ia_uptime(result.get("index_analysis")),
        "small_data": result.get("small_data", False),
    }


def build_single_prompt(plan, result):
    L = [
        "You are reading ONE SQL Server ACTUAL execution plan. Say what is actually slow and",
        "why -- work through estimated-vs-actual rows (per execution), the engine's own",
        "warnings, where the TIME went (never where the cost went), the memory grant, and",
        "only then indexes. For anything you would change, give a CONCRETE FIX and say why.",
        "Stay consistent with the ANTI-PATTERNS and RECOMMENDATIONS below -- extend where the",
        "plan warrants, do not contradict. Any index is a starting point, never ready-to-run",
        "DDL. Cost is always an estimate.",
        "",
        render_single_text(plan, result, full=False),
        "",
    ]
    if result["detections"]:
        L.append("ANTI-PATTERNS DETECTED (deterministic, straight from the plan XML):")
        for d in result["detections"]:
            L.append(f"  - [{d['code']}] {d['detail']}")
        L.append("")
        L.append("The tool's own canned fixes for these codes are in "
                 "ComparePlans-Recommendations-Catalog.md -- extend them where the plan warrants; "
                 "do not contradict them.")
        L.append("")
    L.append("#" * 78)
    L.append(f"# DIGEST -- {plan.label}   ({plan.path})")
    L.append("#" * 78)
    digest = px.Lines()
    px.describe_statement(plan.stmt_el, digest, 8)
    L.append("\n".join(digest))
    return "\n".join(L)


def run_single(args, ap):
    if args.no_recommendations:
        ap.error("--single and --no-recommendations conflict "
                 "(the recommendations are the whole output)")
    if len(args.plan) != 1:
        ap.error(f"--single takes exactly one plan, got {len(args.plan)}")
    label, path = _split_arg(args.plan[0])
    if not label:
        import os
        label = os.path.splitext(os.path.basename(path))[0]
    try:
        plan = LoadedPlan(label, path)
    except PlanRejected as e:
        print("PLAN VALIDATION FAILED.\n", file=sys.stderr)
        print(f"  REJECTED  {e.label}  ({e.path})", file=sys.stderr)
        print(f"            {e.reason}", file=sys.stderr)
        return 2

    result = analyse_single(plan, args.small_data_rows, args.fill_factor)

    if args.analyze_indexes:
        if not _valid_server(args.analyze_indexes):
            ap.error(f"--analyze-indexes: {args.analyze_indexes!r} is not a valid server name "
                     f"(host / FQDN / host\\instance / tcp:host,port; no switches, no password)")
        result["min_uptime_days"] = args.min_uptime_days
        if args.realign_missing_indexes:
            args.show_missing_indexes = True          # the REALIGN line lives in that block
        result["show_missing_indexes"] = args.show_missing_indexes
        result["realign_missing_indexes"] = args.realign_missing_indexes
        # Engage even without an anti-pattern: if the plan carries the optimizer's own
        # <MissingIndexes> hint and nothing else generated an index, synthesise the
        # CREATE INDEX from that hint so --analyze-indexes (and --realign-missing-indexes)
        # still run against the table. The hint is advisory -- the same caveat the section
        # prints. (An eager index spool still generates its own CREATE INDEX as before.)
        if plan.missing_indexes and not any(r.get("ddl") for r in result["recommendations"]):
            _ddl = _ddl_from_missing_index(
                max(plan.missing_indexes, key=lambda m: m[2]), args.fill_factor)
            if _ddl:
                _m = re.search(r"CREATE INDEX \S+ ON (\S+) \(", _ddl)
                result["recommendations"].append({
                    "code": "MISSING_INDEX_HINT", "scope": plan.label,
                    "headline": "The plan carries the optimizer's own missing-index hint",
                    "fix": "Review the suggested index against the table's existing indexes below.",
                    "caveat": "A plan's <MissingIndexes> hint is one input to index design, "
                              "not a prescription.",
                    "detail": "", "ddl": _ddl,
                    "ddl_table": _m.group(1) if _m else None,
                    "ddl_db": plan.table_databases.get(_m.group(1)) if _m else None,
                })
        elif (not plan.missing_indexes
              and not any(r.get("ddl") for r in result["recommendations"])
              and any(n.physical in _WINDOW_OPS for n in plan.nodes)
              and plan.sort_count):
            # An unfiltered window function: no WHERE -> the optimizer raises no
            # <MissingIndexes> hint and no missing-index DMV proposal, so there is
            # nothing for --realign-missing-indexes to reorder. But the POC index
            # (PARTITION BY then frame ORDER BY, then cover) that removes the Sort
            # CAN be read straight from the plan's own window Sort.
            _poc = _poc_index_from_plan(plan, args.fill_factor)
            _pd = _poc[0] if _poc else None
            result["recommendations"].append({
                "code": "WINDOW_FN_NO_INDEX", "scope": plan.label,
                "headline": "The query uses a window function with no supporting index "
                            "and no missing-index hint",
                "fix": ("A POC index -- key = OVER (PARTITION BY ...) then OVER (ORDER BY ...) "
                        "(ASC/DESC), INCLUDE the scanned columns -- removes the Sort. Synthesised "
                        "below from the plan's own window Sort; review and rename before creating."
                        if _pd else
                        "A POC index -- key = OVER (PARTITION BY ...) then OVER (ORDER BY ...) "
                        "(ASC/DESC), then INCLUDE the SELECT list -- would remove the Sort. Could "
                        "not read the OVER() shape from this plan; build it by hand."),
                "caveat": "With no WHERE on the windowed table the optimizer raises no "
                          "missing-index suggestion, so --realign-missing-indexes has nothing "
                          "to realign here. The key columns come from the plan's Sort, not a "
                          "tuning pass.",
                "detail": "", "ddl": _pd, "ddl_table": None, "ddl_db": None,
            })
        result["index_analysis"] = gather_index_analysis(
            [plan], result, args.analyze_indexes, args.auth, args.utility_db)
        failed = [t for t, r in result["index_analysis"].items() if not r["ok"]]
        if failed:
            print(f"note: --analyze-indexes could not analyse {', '.join(failed)} on "
                  f"{args.analyze_indexes}; the plan check above is unaffected.", file=sys.stderr)

    if args.format == "json":
        payload = build_single_json(plan, result)
        if args.emit_prompt:
            payload["prompt"] = build_single_prompt(plan, result)
        print(json.dumps(payload, indent=2, default=str))
    elif args.format == "md":
        print(render_single_md(plan, result))
        if args.emit_prompt:
            print("\n---\n")
            print(build_single_prompt(plan, result))
    else:
        if args.emit_prompt:
            print(build_single_prompt(plan, result))
        else:
            print(_colourise(render_single_text(plan, result, full=args.full),
                             _want_colour(args.color)))
    return 0


# ===========================================================================
# CLI
# ===========================================================================

def _split_arg(a):
    """'label=path' -> ('label', 'path'); bare 'path' -> (None, 'path').
    Split on the FIRST '=' only. A Windows path separates the drive with ':',
    never '=', so an '=' in the argument is always the label delimiter."""
    if "=" in a:
        label, _, path = a.partition("=")
        if path.strip():
            return label.strip(), path.strip()
    return None, a


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Compare 2 to 4 SQL Server ACTUAL execution plans for one query.")
    ap.add_argument("plan", nargs="*",
                    help="2 to 4 plan files, each 'label=path' or just 'path' "
                         "(with --single: exactly one)")
    ap.add_argument("--single", action="store_true",
                    help="analyse ONE plan for anti-patterns (eager spool, local variable, "
                         "non-sargable predicate, implicit conversion, missing join predicate, "
                         "no statistics, 1-row table variable) -- no comparison, no verdict. "
                         "For a full read, add --emit-prompt.")
    ap.add_argument("--format", choices=("text", "md", "json"), default="text")
    ap.add_argument("--baseline", default="1",
                    help="which version the deltas are measured against: 1-based index or a label "
                         "(default: 1)")
    ap.add_argument("--emit-prompt", action="store_true",
                    help="append an Erik-style analysis prompt with per-plan digests")
    ap.add_argument("--full", action="store_true",
                    help="the long report: add INPUTS, SIGNALS, and the leaf-access / structural / "
                         "resource / timing tables. Default is the brief report.")
    ap.add_argument("--no-recommendations", action="store_true",
                    help="omit the RECOMMENDATIONS section (implies --full: v1.1-compatible output)")
    ap.add_argument("--color", "--colour", choices=("auto", "always", "never"), default="auto",
                    help="ANSI colour for --format text (default: auto = only to a terminal). "
                         "Never applies to md / json / --emit-prompt.")
    ap.add_argument("--dump-catalog", action="store_true",
                    help="print the recommendations catalog as Markdown and exit")
    ap.add_argument("--analyze-indexes", metavar="SERVER",
                    help="after a CREATE INDEX is generated -- or, in --single, if the plan carries "
                         "the optimizer's <MissingIndexes> hint -- connect to SERVER via sqlcmd and "
                         "run DBAdmin.dbo.usp_IndexAnalysis for that table, appending the result. "
                         "Integrated / Entra auth only -- no passwords. Failure is non-fatal.")
    ap.add_argument("--auth", choices=("windows", "entra", "entra-interactive"), default="windows",
                    help="auth for --analyze-indexes: windows (sqlcmd -E, default), entra (-G), "
                         "entra-interactive (-G, forces the browser/device prompt).")
    ap.add_argument("--utility-db", default="DBAdmin",
                    help="database holding usp_IndexAnalysis (default: DBAdmin).")
    ap.add_argument("--min-uptime-days", type=int, default=INDEX_CHANGE_MIN_UPTIME_DAYS,
                    help=f"warn in the INDEX ANALYSIS section when the instance has been up fewer "
                         f"than this many days -- its DMV counters have not accumulated a "
                         f"representative workload (default {INDEX_CHANGE_MIN_UPTIME_DAYS}).")
    ap.add_argument("--show-missing-indexes", action="store_true",
                    help="with --analyze-indexes, also list the missing-index DMV proposals for "
                         "the table (after the existing indexes). Off by default -- the proposals "
                         "are workload-volatile and not usually what a drop/realign review needs.")
    ap.add_argument("--realign-missing-indexes", action="store_true",
                    help="--single ONLY. Under each missing-index proposal, add a REALIGN -- CREATE "
                         "INDEX line that reorders the key -- equality/filter, then GROUP BY, then "
                         "ORDER BY last -- so the query's Sort / Hash Aggregate is eliminated. Implies "
                         "--show-missing-indexes. Needs usp_IndexAnalysis's missing_order_by_cols / "
                         "missing_group_by_cols. Rejected in a 2-4 plan comparison -- no single plan "
                         "to attribute the recommendation to.")
    ap.add_argument("--fill-factor", type=int, default=DEFAULT_FILLFACTOR, metavar="N",
                    help=f"FILLFACTOR for every generated CREATE INDEX (default {DEFAULT_FILLFACTOR}; "
                         f"0 or 100 omits the WITH (FILLFACTOR = N) clause).")
    ap.add_argument("--small-data-rows", type=int, default=DEFAULT_SMALL_DATA_ROWS,
                    help=f"row count below which the small-data caveat fires (default {DEFAULT_SMALL_DATA_ROWS})")
    args = ap.parse_args(argv)

    if args.dump_catalog:
        print(dump_catalog())
        return 0

    if args.single:
        return run_single(args, ap)

    if args.realign_missing_indexes:
        ap.error("--realign-missing-indexes works only with --single. The realignment is a "
                 "per-plan recommendation derived from usp_IndexAnalysis; a 2-4 plan comparison "
                 "has no single plan to attribute it to. For a comparison, use "
                 "--show-missing-indexes to list the missing-index DMV proposals without the "
                 "REALIGN line.")

    if not (2 <= len(args.plan) <= 4):
        ap.error(f"need 2 to 4 plans, got {len(args.plan)}")

    labels_paths = [_split_arg(a) for a in args.plan]
    seen_labels = set()
    specs = []
    for i, (label, path) in enumerate(labels_paths, 1):
        if not label:
            import os
            label = os.path.splitext(os.path.basename(path))[0]
        base_label = label
        n = 2
        while label in seen_labels:
            label = f"{base_label} ({n})"
            n += 1
        seen_labels.add(label)
        specs.append((label, path))

    plans, rejects = [], []
    for label, path in specs:
        try:
            plans.append(LoadedPlan(label, path))
        except PlanRejected as e:
            rejects.append(e)

    if rejects:
        print("PLAN VALIDATION FAILED -- no comparison run.\n", file=sys.stderr)
        for e in rejects:
            print(f"  REJECTED  {e.label}  ({e.path})", file=sys.stderr)
            print(f"            {e.reason}", file=sys.stderr)
        ok = [p.label for p in plans]
        if ok:
            print(f"\n  accepted: {', '.join(ok)}", file=sys.stderr)
        return 2

    # resolve baseline
    base_idx = 0
    b = args.baseline.strip()
    if b.isdigit():
        base_idx = int(b) - 1
        if not (0 <= base_idx < len(plans)):
            ap.error(f"--baseline {b} out of range (have {len(plans)} plans)")
    else:
        matches = [i for i, p in enumerate(plans) if p.label == b]
        if not matches:
            ap.error(f"--baseline '{b}' matches no plan label")
        base_idx = matches[0]

    result = compare(plans, base_idx, args.small_data_rows,
                     with_recommendations=not args.no_recommendations,
                     fill_factor=args.fill_factor)

    if args.analyze_indexes:
        if not _valid_server(args.analyze_indexes):
            ap.error(f"--analyze-indexes: {args.analyze_indexes!r} is not a valid server name "
                     f"(host / FQDN / host\\instance / tcp:host,port; no switches, no password)")
        result["min_uptime_days"] = args.min_uptime_days
        result["show_missing_indexes"] = args.show_missing_indexes
        result["realign_missing_indexes"] = False     # --single only; rejected above for a comparison
        result["index_analysis"] = gather_index_analysis(
            plans, result, args.analyze_indexes, args.auth, args.utility_db)
        failed = [t for t, r in result["index_analysis"].items() if not r["ok"]]
        if failed:
            print(f"note: --analyze-indexes could not analyse {', '.join(failed)} "
                  f"on {args.analyze_indexes} (see the INDEX ANALYSIS section); "
                  f"the plan comparison above is unaffected.", file=sys.stderr)

    if args.format == "json":
        payload = build_json(plans, base_idx, result)
        if args.emit_prompt:
            payload["prompt"] = build_prompt(plans, base_idx, result)
        print(json.dumps(payload, indent=2, default=str))
    elif args.format == "md":
        print(render_md(plans, base_idx, result))
        if args.emit_prompt:
            print("\n---\n")
            print(build_prompt(plans, base_idx, result))
    else:
        if args.emit_prompt:
            print(build_prompt(plans, base_idx, result))
        else:
            full = args.full or args.no_recommendations
            print(_colourise(render_text(plans, base_idx, result, full=full),
                             _want_colour(args.color)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
