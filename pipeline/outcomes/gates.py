"""Outcome validation gates (Phase 2a, Task 9): cross-source agreement, national totals, completeness
and plausibility of the state x year outcome panels, with reviewed exceptions; partial-year values
(Ruling P17: a chosen value whose raw_label carries records.PARTIAL_YEAR must be masked by a reviewed
row) and the population denominators (34 units x 2001-2027, positive, equal to the offline rebuild).

Reviewed exceptions live in pipeline/reference/outcomes_reviewed.csv (read_reviewed):
  outcome,unit_id,year,variable,source_id,check,disposition,reason,evidence
  check        cross_source | national_total | completeness | plausibility | missing_source
  disposition  use_source:<source_id> | mask | keep | non_reporting
A row silences a gate item only when outcome (if the gate is run for an outcome), unit_id, year and
variable all match exactly. Rows with a blank year or blank/"ALL" unit are documentary and silence
nothing, with one exception: a check=missing_source row (unit_id ALL, a year, the variable or blank)
excuses the NaN cells of that year in the completeness gate only when the whole year is empty for that
variable (no unit has a value), i.e. the gap is the missing source's year, not a unit's.

Gate detail strings list each failing item as "UNIT YEAR VARIABLE" (cross_source), "SOURCE YEAR
VARIABLE" (national_total) or "UNIT YEAR" (completeness, plausibility).
"""
import io
import itertools
import math
from pathlib import Path

import pandas as pd

from pipeline.paths import DERIVED
from pipeline.validate import GateResult

REF = Path(__file__).resolve().parents[1] / "reference"
REVIEWED = REF / "outcomes_reviewed.csv"
REVIEWED_COLUMNS = ["outcome", "unit_id", "year", "variable", "source_id", "check", "disposition", "reason",
                    "evidence"]
CHECKS = {"cross_source", "national_total", "completeness", "plausibility", "missing_source"}
DISPOSITIONS = {"mask", "keep", "non_reporting"}
LOWER_BOUND_SOURCES = {"foodgrain_dld"}       # Ruling P10: lower-bound crop sum; pairs non-gating
NO_NATIONAL_TOTAL = {"foodgrain_dld"}          # publishes no all-India total
TOL_REL, TOL_ABS, TOL_NATIONAL = 0.02, 5.0, 0.01


# ---------------------------------------------------------------- reviewed exceptions

def _empty_reviewed() -> pd.DataFrame:
    return pd.DataFrame(columns=REVIEWED_COLUMNS)


def _norm_reviewed(rev) -> pd.DataFrame:
    if rev is None or len(rev) == 0:
        return _empty_reviewed()
    r = rev.copy()
    for c in REVIEWED_COLUMNS:
        if c not in r:
            r[c] = ""
    r = r[REVIEWED_COLUMNS].fillna("").astype(str).apply(lambda s: s.str.strip())
    r["year"] = r.year.str.replace(r"\.0$", "", regex=True)
    return r


def read_reviewed(path=REVIEWED) -> pd.DataFrame:
    """outcomes_reviewed.csv, validated: known check/disposition, non-empty reason and evidence, no
    wildcard unit/variable/year values."""
    r = _norm_reviewed(pd.read_csv(path, dtype=str, keep_default_na=False))
    for i, x in r.iterrows():
        where = f"{Path(path).name} row {i + 2}"
        if x.check not in CHECKS:
            raise ValueError(f"{where}: check {x.check!r} not in {sorted(CHECKS)}")
        if not (x.disposition in DISPOSITIONS or (x.disposition.startswith("use_source:")
                                                  and len(x.disposition) > len("use_source:"))):
            raise ValueError(f"{where}: disposition {x.disposition!r}")
        if not x.reason or not x.evidence:
            raise ValueError(f"{where}: reason and evidence are required")
        if any(ch in f"{x.unit_id}{x.variable}{x.year}{x.source_id}" for ch in "*?%"):
            raise ValueError(f"{where}: wildcards are not allowed")
        if x.year and not x.year.isdigit():
            raise ValueError(f"{where}: year {x.year!r}")
        if x.check == "missing_source" and not x.source_id:
            raise ValueError(f"{where}: missing_source rows need a source_id")
        if x.check == "cross_source" and len({p for p in x.source_id.split("|") if p}) != 2:
            raise ValueError(f"{where}: cross_source rows name the disagreeing pair as source_id 'a|b'")
    dup = r.duplicated(["outcome", "unit_id", "year", "variable", "source_id", "check"], keep=False)
    if dup.any():
        raise ValueError(f"duplicate reviewed rows: {r[dup].head(4).to_dict('records')}")
    return r


def _pair(a: str, b: str = None) -> str:
    """Order-free key of a source pair: 'a|b' (sorted)."""
    parts = [a, b] if b is not None else str(a).split("|")
    return "|".join(sorted(p for p in parts if p))


def _reviewed_keys(rev, check: str, outcome=None, key=("unit_id", "year", "variable"), dispositions=None) -> dict:
    r = _norm_reviewed(rev)
    r = r[(r.check == check) & (r.year != "")]
    if dispositions is not None:
        r = r[r.disposition.isin(dispositions)]
    if "source_id" in key and check == "cross_source":
        r = r.assign(source_id=r.source_id.map(_pair))
    if outcome is not None:
        r = r[r.outcome == outcome]
    return {tuple(str(x[k]) for k in key): x.disposition for _, x in r.iterrows()}


# ---------------------------------------------------------------- pooling (within source)

POOLED_UNITS = {"AP_TG", "JK", "DNH_DD"}


def pool(records: pd.DataFrame) -> pd.DataFrame:
    """Sum the rows of one (unit_id, year, variable, source_id) - e.g. Andhra Pradesh + Telangana - with
    skipna and min_count=1 (all members NaN -> NaN, never 0). provisional = any member provisional;
    partial_pool = some members NaN and others not (raw_label lists the members)."""
    key = ["unit_id", "year", "variable", "source_id"]
    multi = records[~records.unit_id.isin(POOLED_UNITS | {"TOTAL"})].groupby(key).raw_label.nunique()
    if (multi > 1).any():       # e.g. "Orissa" and "Odisha" in one table would be double-counted
        raise ValueError(f"several rows of one non-pooled unit in one source: {multi[multi > 1].index[:5].tolist()}")
    if records.empty:
        return pd.DataFrame(columns=key + ["value", "provisional", "raw_label", "n_members", "partial_pool"])
    g = records.groupby(key, sort=False)
    out = g.agg(value=("value", lambda s: s.sum(min_count=1)), provisional=("provisional", "any"),
                raw_label=("raw_label", lambda s: " + ".join(dict.fromkeys(map(str, s)))),
                n_members=("value", "size"), n_present=("value", "count")).reset_index()
    out["partial_pool"] = (out.n_present > 0) & (out.n_present < out.n_members)
    return out.drop(columns="n_present")


# ---------------------------------------------------------------- cross-source

def agree(a: float, b: float, tol_rel=TOL_REL, tol_abs=TOL_ABS) -> bool:
    """Both >= 100: |a-b| <= tol_rel x the smaller value; either < 100: |a-b| <= tol_abs."""
    if min(a, b) >= 100:
        return abs(a - b) <= tol_rel * min(a, b) + 1e-9
    return abs(a - b) <= tol_abs + 1e-9


def _pairs(records, tol_rel, tol_abs) -> pd.DataFrame:
    p = pool(records[records.unit_id != "TOTAL"])
    p = p[p.value.notna()]
    rows = []
    for (u, y, v), g in p.groupby(["unit_id", "year", "variable"], sort=True):
        if len(g) < 2:
            continue
        g = g.sort_values("source_id")
        for (_, a), (_, b) in itertools.combinations(g.iterrows(), 2):
            if agree(a.value, b.value, tol_rel, tol_abs):
                continue
            rows.append({"unit_id": u, "year": int(y), "variable": v,
                         "source_a": a.source_id, "value_a": a.value, "provisional_a": bool(a.provisional),
                         "source_b": b.source_id, "value_b": b.value, "provisional_b": bool(b.provisional),
                         "diff": b.value - a.value,
                         "rel_diff": (b.value - a.value) / min(a.value, b.value) if min(a.value, b.value) > 0
                         else math.nan,
                         "provisional_pair": bool(a.provisional or b.provisional),
                         "lower_bound_pair": bool({a.source_id, b.source_id} & LOWER_BOUND_SOURCES),
                         "partial_pool": bool(a.partial_pool or b.partial_pool)})
    cols = ["unit_id", "year", "variable", "source_a", "value_a", "provisional_a", "source_b", "value_b",
            "provisional_b", "diff", "rel_diff", "provisional_pair", "lower_bound_pair", "partial_pool"]
    return pd.DataFrame(rows, columns=cols)


def cross_source_table(records, tol_rel=TOL_REL, tol_abs=TOL_ABS) -> pd.DataFrame:
    """Every disagreeing pair of sources for the same (unit, year, variable) after within-source pooling
    (TOTAL rows excluded; they are checked by national_totals)."""
    return _pairs(records, tol_rel, tol_abs)


def cross_source(records, tol_rel=TOL_REL, tol_abs=TOL_ABS, reviewed=None, outcome=None,
                 report_path=None) -> GateResult:
    """Fails on disagreements between two FINAL values not listed (check=cross_source) in the reviewed
    file. Provisional-vs-any and lower-bound (foodgrain_dld) pairs are reported but do not gate.
    report_path: write all disagreements there (columns of cross_source_table + gating, reviewed)."""
    t = cross_source_table(records, tol_rel, tol_abs)
    rev = _reviewed_keys(reviewed, "cross_source", outcome, key=("unit_id", "year", "variable", "source_id"))
    keys = [(str(r.unit_id), str(r.year), str(r.variable), _pair(r.source_a, r.source_b)) for r in t.itertuples()]
    t["reviewed"] = [rev.get(k, "") for k in keys]
    t["gating"] = ~t.provisional_pair & ~t.lower_bound_pair
    if outcome is not None:
        t.insert(0, "outcome", outcome)
    if report_path is not None:
        Path(report_path).parent.mkdir(parents=True, exist_ok=True)
        t.to_csv(report_path, index=False)
    bad = t[t.gating & (t.reviewed == "")]
    items = sorted({f"{r.unit_id} {r.year} {r.variable}" for r in bad.itertuples()})
    detail = (f"disagreeing pairs={len(t)} (provisional {int(t.provisional_pair.sum())}, lower-bound "
              f"{int((t.lower_bound_pair & ~t.provisional_pair).sum())}, reviewed {int((t.reviewed != '').sum())})")
    if items:
        ex = {}
        for r in bad.itertuples():
            ex.setdefault(f"{r.unit_id} {r.year} {r.variable}",
                          f"{r.source_a} {r.value_a:g} vs {r.source_b} {r.value_b:g}")
        detail += f"; unreviewed final disagreements={len(items)}: " + "; ".join(f"{k} ({ex[k]})" for k in items)
    return GateResult(f"outcome_cross_source{'_' + outcome if outcome else ''}", not items, detail)


# ---------------------------------------------------------------- national totals

def national_table(records, tol_rel=TOL_NATIONAL) -> pd.DataFrame:
    """Per source-year-variable with a non-NaN TOTAL row: sum of unit rows vs the printed total."""
    r = records[~records.source_id.isin(NO_NATIONAL_TOTAL)]
    tot = r[(r.unit_id == "TOTAL") & r.value.notna()]
    rows = []
    for (s, y, v), g in tot.groupby(["source_id", "year", "variable"]):
        if len(g) != 1:
            raise ValueError(f"{s} {y} {v}: {len(g)} TOTAL rows")
        t = float(g.value.iloc[0])
        units = r[(r.source_id == s) & (r.year == y) & (r.variable == v) & (r.unit_id != "TOTAL")]
        ssum = float(units.value.sum(min_count=1)) if len(units) else math.nan
        ok = (not math.isnan(ssum)) and abs(ssum - t) <= tol_rel * abs(t) + 1e-9
        rows.append({"source_id": s, "year": int(y), "variable": v, "units_sum": ssum, "total": t,
                     "rel_diff": (ssum - t) / t if t else math.nan, "n_units": int(units.value.notna().sum()),
                     "ok": ok})
    return pd.DataFrame(rows, columns=["source_id", "year", "variable", "units_sum", "total", "rel_diff",
                                       "n_units", "ok"])


def national_totals(records, tol_rel=TOL_NATIONAL, reviewed=None, outcome=None) -> GateResult:
    t = national_table(records, tol_rel)
    rev = _reviewed_keys(reviewed, "national_total", outcome, key=("source_id", "year", "variable"))
    bad = t[~t.ok]
    unrev = [r for r in bad.itertuples() if (r.source_id, str(r.year), r.variable) not in rev]
    detail = f"source-years={len(t)} outside {tol_rel:.0%}={len(bad)} (reviewed {len(bad) - len(unrev)})"
    if unrev:
        detail += "; unreviewed: " + "; ".join(
            f"{r.source_id} {r.year} {r.variable} (units {r.units_sum:.0f} vs total {r.total:.0f}, "
            f"{100 * r.rel_diff:+.2f}%)" if not math.isnan(r.units_sum)
            else f"{r.source_id} {r.year} {r.variable} (no unit values)" for r in unrev)
    return GateResult(f"outcome_national_total{'_' + outcome if outcome else ''}", not unrev, detail)


# ---------------------------------------------------------------- completeness

def completeness(panel, years, units, var, reviewed=None, outcome=None) -> GateResult:
    """Every unit x year row present; NaN in `var` only where reviewed (check=completeness for the
    unit-year, a mask / non_reporting row of another check for it, or a check=missing_source row for
    (ALL, year) when the whole year is empty)."""
    years, units = [int(y) for y in years], list(units)
    p = panel[panel.unit_id.isin(units) & panel.year.isin(years)]
    present = {(str(u), int(y)) for u, y in zip(p.unit_id, p.year)}
    dup = p.duplicated(["unit_id", "year"]).sum()
    absent = [(u, y) for u in units for y in years if (u, y) not in present]
    rev = _reviewed_keys(reviewed, "completeness", outcome, dispositions=("mask", "non_reporting"))  # keep: no
    nr = _norm_reviewed(reviewed)                   # a reviewed mask / non_reporting row of any check makes NaN
    nr = nr[nr.disposition.isin(["mask", "non_reporting"]) & (nr.check != "missing_source") & (nr.year != "")]
    if outcome is not None:
        nr = nr[nr.outcome == outcome]
    rev.update({(x.unit_id, x.year, x.variable): x.disposition for x in nr.itertuples()})
    ms = _norm_reviewed(reviewed)
    ms = ms[(ms.check == "missing_source") & (ms.unit_id == "ALL") & (ms.year != "")
            & ms.variable.isin(["", var])]
    if outcome is not None:
        ms = ms[ms.outcome == outcome]
    empty_years = {int(y) for y, g in p.groupby("year") if g[var].isna().all()}
    excused_years = {int(y) for y in ms.year} & empty_years
    nan = p[p[var].isna()]
    unrev = [(str(u), int(y)) for u, y in zip(nan.unit_id, nan.year)
             if (str(u), str(int(y)), var) not in rev and int(y) not in excused_years]
    n_ms = sum(1 for u, y in zip(nan.unit_id, nan.year)          # excused only by the missing-source year
               if int(y) in excused_years and (str(u), str(int(y)), var) not in rev)
    detail = (f"{var}: units={len(units)} years={years[0]}-{years[-1]} NaN={len(nan)} (reviewed "
              f"{len(nan) - len(unrev) - n_ms}, missing-source years {sorted(excused_years) or '-'}: {n_ms})")
    fails = []
    if dup:
        fails.append(f"duplicate unit-years={dup}")
    if absent:
        fails.append(f"absent rows={len(absent)}: " + ", ".join(f"{u} {y}" for u, y in absent))
    if unrev:
        fails.append(f"unreviewed NaN={len(unrev)}: " + ", ".join(f"{u} {y}" for u, y in sorted(unrev)))
    if fails:
        detail += "; " + "; ".join(fails)
    return GateResult(f"outcome_completeness{'_' + outcome if outcome else ''}_{var}", not fails, detail)


# ---------------------------------------------------------------- plausibility

WINDOW, MIN_OBS = 7, 3          # Ruling P11: centred rolling 7-year median, >= 3 non-NaN observations


def plausibility_table(panel, var, lo=0.2, hi=5.0, min_count=20, split=None, window=WINDOW,
                       min_obs=MIN_OBS) -> pd.DataFrame:
    """Unit-years whose value is outside lo-hi x the reference median = the centred rolling `window`-year
    median of the unit's own series (calendar years; at least `min_obs` non-NaN values in the window,
    the year itself included). split: a year where the series is cut (definition break; the windows
    do not cross it). Reference medians below min_count are not checked; NaN cells are ignored.
    (Ruling P11: a whole-series median flags secular trends, not parse/unit/typo errors.)"""
    out = []
    for u, g in panel[["unit_id", "year", var]].groupby("unit_id"):
        g = g.set_index("year")[var].sort_index()
        segments = [g] if split is None else [g[g.index < split], g[g.index >= split]]
        for seg in segments:
            if seg.notna().sum() == 0:
                continue
            full = seg.reindex(range(int(seg.index.min()), int(seg.index.max()) + 1))
            med = full.rolling(window, center=True, min_periods=min_obs).median()
            ratio = full / med
            k = full.notna() & (med >= min_count) & ((ratio < lo) | (ratio > hi))
            for y in full.index[k]:
                out.append({"unit_id": u, "year": int(y), "variable": var, "value": float(full[y]),
                            "median": float(med[y]), "ratio": float(ratio[y])})
    return pd.DataFrame(out, columns=["unit_id", "year", "variable", "value", "median", "ratio"])


def plausibility(panel, var, lo=0.2, hi=5.0, min_count=20, reviewed=None, outcome=None, split=None) -> GateResult:
    t = plausibility_table(panel, var, lo, hi, min_count, split=split)
    rev = _reviewed_keys(reviewed, "plausibility", outcome)
    unrev = [r for r in t.itertuples() if (str(r.unit_id), str(int(r.year)), var) not in rev]
    detail = (f"{var}: flagged unit-years={len(t)} (outside {lo}-{hi} x centred {WINDOW}-year median"
              f"{f', split at {split}' if split else ''}; reviewed {len(t) - len(unrev)})")
    if unrev:
        detail += "; unreviewed: " + ", ".join(f"{r.unit_id} {int(r.year)} (x{r.ratio:.2f})" for r in unrev)
    return GateResult(f"outcome_plausibility{'_' + outcome if outcome else ''}_{var}", not unrev, detail)


# ---------------------------------------------------------------- partial years (Ruling P17)

def partial_year_cells(records, ranks: dict, reviewed=None, outcome=None, units=None, years=None) -> pd.DataFrame:
    """Cells (unit_id, year, variable) whose chosen value (assemble.choose) is a partial-year record
    (records.PARTIAL_YEAR in its raw_label), with the reviewed disposition that apply_reviewed would
    apply to the cell ("" when none; keep rows change nothing) and ok = the disposition is mask, or
    use_source:<id> of a source whose value for the cell is not partial-year. units / years: restrict
    to the panel's cells."""
    from pipeline.outcomes import assemble, records as rec_mod
    cols = ["unit_id", "year", "variable", "source_id", "value", "disposition", "ok"]
    r = records[records.unit_id != "TOTAL"]
    ch = assemble.choose(r, ranks)
    if units is not None:
        ch = ch[ch.unit_id.isin(list(units))]
    if years is not None:
        ch = ch[ch.year.isin([int(y) for y in years])]
    labels = pool(r).set_index(["unit_id", "year", "variable", "source_id"]).raw_label
    key = lambda c, sid: (c.unit_id, int(c.year), c.variable, sid)              # noqa: E731
    part = ch[[sid != "" and rec_mod.is_partial(labels.get(key(c, sid), ""))
               for c, sid in zip(ch.itertuples(), ch.source_id)]]
    rev = _norm_reviewed(reviewed)
    rev = rev[(rev.year != "") & (rev.variable != "") & ~rev.unit_id.isin(["", "ALL", "TOTAL"])
              & (rev.check != "missing_source") & (rev.disposition != "keep")]
    if outcome is not None:
        rev = rev[rev.outcome == outcome]
    disp = {(x.unit_id, int(x.year), x.variable): x.disposition for x in rev.itertuples()}   # last row wins
    rows = []
    for c in part.itertuples():
        d = disp.get((c.unit_id, int(c.year), c.variable), "")
        ok = d == "mask" or (d.startswith("use_source:")
                             and not rec_mod.is_partial(labels.get(key(c, d.split(":", 1)[1]), "")))
        rows.append({"unit_id": c.unit_id, "year": int(c.year), "variable": c.variable, "source_id": c.source_id,
                     "value": c.value, "disposition": d, "ok": ok})
    return pd.DataFrame(rows, columns=cols)


def partial_year(records, ranks: dict, reviewed=None, outcome=None, units=None, years=None) -> GateResult:
    """Every cell whose chosen value is a partial-year record must be masked by a reviewed row
    (Ruling P17; see partial_year_cells)."""
    t = partial_year_cells(records, ranks, reviewed, outcome, units, years)
    bad = t[~t.ok]
    by_var = ", ".join(f"{v} {n}" for v, n in t.groupby("variable").size().items()) or "-"
    detail = f"chosen partial-year cells={len(t)} ({by_var}); masked or replaced {int(t.ok.sum())}"
    if len(bad):
        detail += f"; without a reviewed mask={len(bad)}: " + ", ".join(
            f"{r.unit_id} {r.year} {r.variable} ({r.source_id}{', ' + r.disposition if r.disposition else ''})"
            for r in bad.itertuples())
    return GateResult(f"outcome_partial_year{'_' + outcome if outcome else ''}", bad.empty, detail)


# ---------------------------------------------------------------- population denominators

POP_YEARS = range(2001, 2028)
_DEFAULT = object()


def population_gate(path, units=None, years=POP_YEARS, rebuild=_DEFAULT) -> GateResult:
    """population_unit_year.csv: exactly one row per unit x year (default the 34 units, 2001-2027),
    population non-NaN and > 0; and equal (exactly) to rebuild() when given. Default rebuild:
    population.table from the cached raw files (census_a02, rgi_proj2020) when both are cached - the
    build is then offline - else the rebuild is skipped (stated in the detail)."""
    from pipeline.outcomes import population, states
    name, path = "outcome_population", Path(path)
    units = list(states.UNITS if units is None else units)
    years = [int(y) for y in years]
    if rebuild is _DEFAULT:
        rebuild = population.table if population.cached() else None
    if not path.exists():
        return GateResult(name, False, f"missing {path.name} (run python -m pipeline.outcomes.assemble)")
    p = pd.read_csv(path)
    want = {(u, y) for u in units for y in years}
    have = list(zip(p.unit_id.astype(str), p.year.astype(int)))
    fails = []
    if len(have) != len(set(have)):
        fails.append(f"duplicate unit-years={len(have) - len(set(have))}")
    if set(have) != want:
        miss, extra = sorted(want - set(have)), sorted(set(have) - want)
        fails.append(f"rows absent={len(miss)} {miss[:5]} unexpected={len(extra)} {extra[:5]}")
    nan, nonpos = int(p.population.isna().sum()), int((p.population <= 0).sum())
    if nan or nonpos:
        fails.append(f"NaN={nan} non-positive={nonpos}")
    detail = f"units={len(units)} years={years[0]}-{years[-1]} rows={len(p)}"
    if fails:
        return GateResult(name, False, detail + "; " + "; ".join(fails))
    if rebuild is None:
        return GateResult(name, True, detail + "; non-NaN, > 0; rebuild skipped (raw files not cached)")
    try:
        want_df = pd.read_csv(io.StringIO(rebuild().to_csv(index=False)))
        pd.testing.assert_frame_equal(p, want_df, check_dtype=False, check_exact=True)
    except AssertionError as e:
        return GateResult(name, False, detail + f"; differs from the rebuild ({' '.join(str(e).split())[:160]})")
    except Exception as e:                          # a gate reports, it does not crash validation
        return GateResult(name, False, detail + f"; rebuild failed: {type(e).__name__}: {e}")
    return GateResult(name, True, detail + "; non-NaN, > 0; identical to the rebuild from the cached raw files")


# ---------------------------------------------------------------- missing sources

def missing_sources(missing: pd.DataFrame, reviewed=None) -> GateResult:
    """Every source that could not be obtained (assemble's missing_sources.csv: outcome, source_id,
    reason) must have at least one check=missing_source row in the reviewed file."""
    r = _norm_reviewed(reviewed)
    have = set(zip(r[r.check == "missing_source"].outcome, r[r.check == "missing_source"].source_id))
    unrev = [f"{m.outcome} {m.source_id}" for m in missing.itertuples() if (m.outcome, m.source_id) not in have]
    detail = f"missing sources={len(missing)}" + (f": {', '.join(sorted(missing.source_id))}" if len(missing) else "")
    if unrev:
        detail += "; without a missing_source row: " + ", ".join(unrev)
    return GateResult("outcome_missing_sources", not unrev, detail)


# ---------------------------------------------------------------- all outcome gates on the derived files

def run_outcome_gates(out_dir=DERIVED / "outcomes", reviewed_path=REVIEWED, spec=None) -> list:
    """All outcome gates on the files written by assemble.build_all(). spec: {outcome: {file, years,
    units, split, complete: [var or (var, years)], plausible: [vars]}} (default assemble.GATE_SPEC).
    Writes the disagreeing pairs of every outcome to out_dir/cross_source_report.csv. A missing panel
    file is a FAIL result (outcome_panel_<outcome>), not an exception."""
    from pipeline.outcomes import assemble
    out_dir = Path(out_dir)
    spec = assemble.GATE_SPEC if spec is None else spec
    reviewed = read_reviewed(reviewed_path)
    recs = assemble.read_records(out_dir / "outcome_records_all.csv.gz")
    rk = assemble.ranks()
    res, reports = [], []
    for outcome, s in spec.items():
        r = recs[recs.outcome == outcome]
        tmp = out_dir / f".cross_source_{outcome}.csv"
        res.append(cross_source(r, reviewed=reviewed, outcome=outcome, report_path=tmp))
        reports.append(pd.read_csv(tmp))
        tmp.unlink()
        res.append(national_totals(r, reviewed=reviewed, outcome=outcome))
        res.append(partial_year(r.drop(columns="outcome"), rk, reviewed=reviewed, outcome=outcome,
                                units=s["units"], years=s["years"]))
        if not (out_dir / s["file"]).exists():
            res.append(GateResult(f"outcome_panel_{outcome}", False,
                                  f"missing {s['file']} (run python -m pipeline.outcomes.assemble)"))
            continue
        panel = pd.read_csv(out_dir / s["file"])
        for v in s.get("complete", []):
            v, years = (v, s["years"]) if isinstance(v, str) else v
            res.append(completeness(panel, years, s["units"], v, reviewed=reviewed, outcome=outcome))
        for v in s.get("plausible", []):
            res.append(plausibility(panel, v, reviewed=reviewed, outcome=outcome, split=s.get("split")))
    if "farmer_suicides" in spec:
        from pipeline.outcomes import farmer_zeros
        fr = recs[recs.outcome == "farmer_suicides"].drop(columns="outcome")
        res.append(farmer_zeros.rule_gate(fr, reviewed))
    res.append(assemble.reproduce_gate(out_dir, reviewed_path, outcomes={
        o: {"file": s["file"], "years": s["years"], "units": s["units"], "vars": assemble.OUTCOMES[o]["vars"]}
        for o, s in spec.items()}))
    res.append(population_gate(out_dir / "population_unit_year.csv"))
    pd.concat(reports, ignore_index=True).to_csv(out_dir / "cross_source_report.csv", index=False)
    ms_path = out_dir / "missing_sources.csv"
    if ms_path.exists():
        res.append(missing_sources(pd.read_csv(ms_path, dtype=str, keep_default_na=False), reviewed))
    else:
        res.append(GateResult("outcome_missing_sources", False, f"missing {ms_path.name} (run assemble.build_all)"))
    return res
