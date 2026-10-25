"""HMIS state-month panel (Paper E, Task 4; spec §3.5, §3.6, §10.1, §10.2, §12; rulings F2, F9, F33, F34, F36-F39).

State value (ruling F33, spec §12.2): the official monthly state aggregate, i.e. the state's row in the FY's
`All_India.xls` (FY2012-13..2019-20) or, for FY2020-21, the state aggregate column group of the folder-2
state-month files. Nothing is differenced. Member rows are pooled to the 34 units of
`pipeline/reference/state_frame.csv` by summing with min_count=1 per (unit_id, indicator, fy, month): Andhra Pradesh +
Telangana + "Andhra Pradesh Old" -> AP_TG, Jammu & Kashmir + Ladakh -> JK, Dadra & Nagar Haveli + Daman & Diu (or
the merged UT) -> DNH_DD. In FY2020-21, where the merged-UT file and the stale pre-merger single-UT files cover the
same month, only the merged-UT file is used (ruling F36). Any other pair of source rows for one unit-month whose
labels cover the same territory fails the build with DuplicateSourceError naming both files.

Districts are only the completeness layer (spec §10.1): a unit-month value enters models when comp >= 0.90, where
comp = valid districts / districts listed in the state-FY (pooled units: summed over members). The gates and
default dispositions are in pipeline/hmis/gates.py.

Inputs (Task 3 hand-offs, git-ignored, data/derived/hmis/_parts/): state_month.csv.gz, completeness.csv.gz,
district_month.csv.gz (columns in pipeline/hmis/flags.py) and national_month.csv.gz (run.NATIONAL_COLUMNS, written
by `python -I pipeline/hmis/run.py national`; absent -> the national gate reads "not available").

Hand-off: `data/derived/hmis/hmis_state_month.csv` (tracked; state-level; one row per unit x month, every unit x
month of the FYs built present, missing = empty, never 0). Columns (panel_columns()):
- unit_id (34 units), fy ("2014-15"), year, month (calendar), ym = 12*year + month - 1, era (E1 FY2012-13..2016-17,
  E2 FY2017-18..2019-20, E3 FY2020-21);
- for each indicator in INDICATORS (diarr_u5, anc_reg, penta3, mcv1, fic, inst_del, opd):
  - `<ind>`: the state value after the gate masks and the completeness filter (comp >= 0.90) and, if exactly one
    FY of the primary window is unusable, masked in that FY (every value column, logged in hmis_reviewed.csv
    with check fy_unusable). The primary model outcome;
  - `<ind>_raw`: the state value after the gate masks, before the completeness filter (the 0.75 and
    no-threshold sensitivities);
  - `<ind>_scaled`: the sum of the valid districts / comp (spec §10.1 sensitivity; NaN where a gate masked the
    state value, and when comp is 0 or missing);
  - `<ind>_allcomp`: `<ind>_raw` kept only where every crosswalk component of the state row is present and
    comp_full >= 0.90 (all-components sensitivity, ruling F37; equal to `<ind>` for single-item indicators);
  - `<ind>_masklow`: `<ind>` with the default-kept plausibility lows masked too (the "mask lows" sensitivity,
    ruling F41);
  - `comp_<ind>`, `n_districts_<ind>` (NaN when the unit-month has no district list);
  - `flag_<ind>`: ";"-joined tokens: the gate checks that masked the cell (gates.CHECKS, incl. "fy_unusable"),
    "keep:<check>" for an author keep, "keep_low:plausibility" for a default-kept low (F41), "comp_lt_090"
    (filtered by completeness);
- status_date_min, status_date_max: the range of the "Status As On" dates of the unit-month's state rows (ISO).
Also written (tracked): gate_summary.csv and break_ratio_2017.csv (columns in gates.py), the reviewed dispositions
pipeline/reference/hmis_reviewed.csv, and the "## Paper E HMIS gates" section of data/derived/validation_report.md
(replaced in place on every build).
"""
from pathlib import Path

import numpy as np
import pandas as pd

from pipeline.hmis import gates as hg
from pipeline.hmis.crosswalk import INDICATORS
from pipeline.hmis.difference import FY_MONTHS
from pipeline.hmis.gates import PRIMARY_FYS, FY2021, LONG_KEYS, PanelHalt  # noqa: F401  (PanelHalt re-exported)
from pipeline.hmis.parse import era_for_fy
from pipeline.outcomes import states
from pipeline.paths import DERIVED
from pipeline.validate import GateResult, format_result

HMIS_DIR = DERIVED / "hmis"
PARTS = HMIS_DIR / "_parts"
PANEL_PATH = HMIS_DIR / "hmis_state_month.csv"
SUMMARY_PATH = HMIS_DIR / "gate_summary.csv"
BREAK_PATH = HMIS_DIR / "break_ratio_2017.csv"
NATIONAL_PART = PARTS / "national_month.csv.gz"
VALIDATION_REPORT = DERIVED / "validation_report.md"
REPORT_HEADING = "## Paper E HMIS gates"
COMP_MIN = 0.90
_EPS = 1e-9
UNIT_KEYS = ["unit_id", "fy", "month"]

# Territories behind the labels of the pooled units: two rows of one unit-month may be summed only when their
# territories are disjoint. A label not listed here covers its whole unit.
_COMPONENTS = {
    "ANDHRA PRADESH": {"AP"}, "TELANGANA": {"TG"}, "TELENGANA": {"TG"}, "ANDHRA PRADESH OLD": {"AP", "TG"},
    "JAMMU AND KASHMIR": {"JK"}, "LADAKH": {"LA"},
    "DADRA AND NAGAR HAVELI": {"DNH"}, "DAMAN AND DIU": {"DD"},
    "DADRA AND NAGAR HAVELI AND DAMAN AND DIU": {"DNH", "DD"},
}
_POOLED = {"AP_TG": {"AP", "TG"}, "JK": {"JK", "LA"}, "DNH_DD": {"DNH", "DD"}}


class UnmappedStateError(KeyError):
    """An HMIS state label that does not resolve to one of the 34 units."""


class DuplicateSourceError(ValueError):
    """Two source rows for one unit-month that cover the same territory (ruling F36)."""


def resolve_hmis_state(label: str) -> str:
    """Strip a leading "_" and resolve through pipeline.outcomes.states ("All India" -> "TOTAL")."""
    s = str(label).strip().lstrip("_").strip()
    unit = states.resolve(s)
    if unit is None:
        raise UnmappedStateError(f"unmapped HMIS state label {label!r} (add it to the aliases of "
                                 "pipeline/reference/state_frame.csv only if it is a variant of a state name)")
    return unit


def _territory(label: str, unit: str) -> frozenset:
    return frozenset(_COMPONENTS.get(states.normalise(str(label).lstrip("_")), _POOLED.get(unit, {unit})))


_MERGED_DNH_DD = "DADRA AND NAGAR HAVELI AND DAMAN AND DIU"


def _drop_superseded(rows: pd.DataFrame) -> pd.DataFrame:
    """Ruling F36: wherever a merged-UT (DNH + DD) row exists for a unit-month (any indicator), every row of that
    unit-month whose territory is strictly inside the merged UT (the stale pre-merger single-UT files) is dropped,
    for all indicators (task-4 review M-6)."""
    merged = rows.state_raw.map(lambda s: states.normalise(str(s).lstrip("_")) == _MERGED_DNH_DD)
    if not merged.any():
        return rows
    um = ["unit_id", "fy", "month"]
    has = rows[merged][um].drop_duplicates().assign(_has=True)
    flag = rows[um].merge(has, on=um, how="left")["_has"].notna().values
    inside = rows["_terr"].map(lambda t: t < frozenset({"DNH", "DD"})).values
    return rows[~(flag & inside)]


def _guard(rows: pd.DataFrame) -> None:
    keys = ["unit_id", "fy", "month", "indicator"]
    multi = rows[rows.duplicated(keys, keep=False)]
    for k, g in multi.groupby(keys, sort=False):
        items = list(zip(g["_terr"], g.source_file, g.state_raw))
        for a in range(len(items)):
            for b in range(a + 1, len(items)):
                if items[a][0] & items[b][0]:
                    raise DuplicateSourceError(
                        f"{k[0]} {k[1]} month {k[2]} {k[3]}: {items[a][2]!r} in {items[a][1]} and {items[b][2]!r} in "
                        f"{items[b][1]} cover the same territory; not a legitimate pool (ruling F36)")


def state_series(state_rows: pd.DataFrame) -> pd.DataFrame:
    """flags.STATE_COLUMNS rows -> one row per (unit_id, indicator, fy, month): value (sum of the members,
    min_count=1), partial_component (any member), all_components (every member row with a value has all its
    components), status_date_min / status_date_max (ISO, over member rows with a value), n_sources."""
    r = state_rows.copy()
    r["unit_id"] = [resolve_hmis_state(s) for s in r.state_raw]
    if (r.unit_id == "TOTAL").any():
        raise UnmappedStateError(f"a national row among the state rows: {sorted(set(r[r.unit_id == 'TOTAL'].state_raw))}")
    r["_terr"] = [_territory(s, u) for s, u in zip(r.state_raw, r.unit_id)]
    kept = _drop_superseded(r)
    superseded = r.drop(index=kept.index)
    r = kept
    _guard(r)
    r["partial_component"] = r.partial_component.astype(bool) & r.value.notna()
    r["_full"] = (r.n_present >= r.n_components) | r.value.isna()
    r["_date"] = pd.to_datetime(r.status_date, errors="coerce").where(r.value.notna())
    keys = ["unit_id", "indicator", "fy", "month"]
    g = r.groupby(keys, sort=False)
    out = pd.DataFrame({"value": g["value"].sum(min_count=1), "partial_component": g["partial_component"].any(),
                        "all_components": g["_full"].all(), "status_date_min": g["_date"].min(),
                        "status_date_max": g["_date"].max(), "n_sources": g.size()}).reset_index()
    out["all_components"] = out.all_components & out.value.notna()
    for c in ("status_date_min", "status_date_max"):
        out[c] = out[c].dt.strftime("%Y-%m-%d")
    out["month"] = out.month.astype(int)
    out.attrs["superseded"] = superseded.groupby(["fy", "state_raw"]).size().to_dict()
    return out


def unit_completeness(comp: pd.DataFrame) -> pd.DataFrame:
    """flags.COMP_COLUMNS -> per unit: n_districts, n_valid, comp, comp_full (summed over the pooled members)."""
    c = comp.copy()
    c["unit_id"] = [resolve_hmis_state(s) for s in c.state_raw]
    g = c.groupby(LONG_KEYS, sort=False)[["n_districts", "n_valid", "n_valid_full"]].sum().reset_index()
    nd = g.n_districts.where(g.n_districts > 0)
    g["comp"] = g.n_valid / nd
    g["comp_full"] = g.n_valid_full / nd
    g["month"] = g.month.astype(int)
    return g[LONG_KEYS + ["n_districts", "comp", "comp_full"]]


def with_units(dm: pd.DataFrame) -> pd.DataFrame:
    d = dm.copy()
    lab = {s: resolve_hmis_state(s) for s in d.state_raw.unique()}
    d["unit_id"] = d.state_raw.map(lab)
    return d


def district_sums(dm: pd.DataFrame) -> pd.DataFrame:
    """Valid district values summed per unit-month-indicator (min_count=1): dsum."""
    d = dm if "unit_id" in dm else with_units(dm)
    v = d[d.valid.astype(bool)]
    out = v.groupby(LONG_KEYS)["value"].sum(min_count=1).rename("dsum").reset_index()
    out["month"] = out.month.astype(int)
    return out


def unit_frame(fys) -> pd.DataFrame:
    rows = []
    for fy in fys:
        y0 = int(fy[:4])
        for u in states.UNITS:
            for m in FY_MONTHS:
                y = y0 if m >= 4 else y0 + 1
                rows.append((u, fy, y, m, 12 * y + m - 1, era_for_fy(fy)))
    return pd.DataFrame(rows, columns=["unit_id", "fy", "year", "month", "ym", "era"])


def panel_columns() -> list[str]:
    cols = ["unit_id", "fy", "year", "month", "ym", "era"]
    for i in INDICATORS:
        cols += [i, f"{i}_raw", f"{i}_scaled", f"{i}_allcomp", f"{i}_masklow", f"comp_{i}", f"n_districts_{i}",
                 f"flag_{i}"]
    return cols + ["status_date_min", "status_date_max"]


def _tokens(flags: pd.Series, mask: pd.Series, token: str) -> pd.Series:
    return hg._add_flag(flags.fillna("").astype(str), mask.fillna(False).astype(bool), token)


VALUE_COLUMNS = ["value", "value_gated", "scaled", "allcomp", "masklow"]         # grid columns behind each <ind>*


def _wide(frame, grid, dates) -> pd.DataFrame:
    wide = frame.copy()
    idx = pd.MultiIndex.from_frame(wide[UNIT_KEYS])
    for i in INDICATORS:
        g = grid[grid.indicator == i].set_index(UNIT_KEYS).reindex(idx)
        wide[i] = g.value.values
        wide[f"{i}_raw"] = g.value_gated.values
        wide[f"{i}_scaled"] = g.scaled.values
        wide[f"{i}_allcomp"] = g.allcomp.values
        wide[f"{i}_masklow"] = g.masklow.values
        wide[f"comp_{i}"] = g.comp.values
        wide[f"n_districts_{i}"] = g.n_districts.values
        wide[f"flag_{i}"] = g["flag"].fillna("").values
    return wide.merge(dates, on=UNIT_KEYS, how="left")[panel_columns()]


def _default_fys(state_rows) -> list[str]:
    return list(PRIMARY_FYS) + ([FY2021] if (state_rows.fy == FY2021).any() else [])


def assemble(state_rows, comp, dm, national=None, reviewed=None, fys=None) -> dict:
    """The panel and its gates from the Task 3 tables (no files read or written). Returns a dict: panel (wide,
    panel_columns()), grid (long: LONG_KEYS, raw, value_gated, value, comp, comp_full, n_districts, dsum, flags),
    failures, log (REVIEWED_COLUMNS), results (GateResult list), summary, breaks, national_cmp, dropped,
    unusable, halt (None or the PanelHalt message), status_dates."""
    fys = list(fys) if fys else _default_fys(state_rows)
    reviewed = reviewed if reviewed is not None else hg.empty_reviewed()
    frame = unit_frame(fys)
    s = state_series(state_rows[state_rows.fy.isin(fys)])
    uc = unit_completeness(comp[comp.fy.isin(fys)])
    dmu = with_units(dm[dm.fy.isin(fys)])
    ds = district_sums(dmu)
    grid = frame[UNIT_KEYS].merge(pd.DataFrame({"indicator": list(INDICATORS)}), how="cross")
    grid = (grid.merge(s, on=LONG_KEYS, how="left").merge(uc, on=LONG_KEYS, how="left")
            .merge(ds, on=LONG_KEYS, how="left"))
    grid["partial_component"] = grid.partial_component.astype("boolean").fillna(False).astype(bool)
    grid["all_components"] = grid.all_components.astype("boolean").fillna(False).astype(bool)
    raw = grid[LONG_KEYS + ["value"]]

    gate_out = [hg.gate_negative_share(dmu), hg.gate_negative_state(raw),
                hg.gate_district_sum(raw, ds, uc), hg.gate_plausibility(raw),
                hg.gate_national(raw, national), hg.gate_partial_component(grid)]
    failures = pd.concat([f for f, _ in gate_out if len(f)], ignore_index=True) if any(
        len(f) for f, _ in gate_out) else pd.DataFrame(columns=hg.FAIL_COLUMNS)
    gated, log = hg.apply_dispositions(raw.assign(flag=""), failures, reviewed)
    grid["raw"] = grid["value"]
    grid["value_gated"] = gated["value"].values
    grid["flag"] = gated["flag"].values
    ok = grid.comp >= COMP_MIN - _EPS
    grid["value"] = grid.value_gated.where(ok)
    grid["flag"] = _tokens(grid["flag"], grid.value_gated.notna() & ~ok, "comp_lt_090")
    gate_masked = hg._is_masked(grid["flag"])
    grid["scaled"] = (grid.dsum / grid.comp.where(grid.comp > 0)).where(~gate_masked)
    grid["allcomp"] = grid.value_gated.where(grid.all_components & (grid.comp_full >= COMP_MIN - _EPS))
    grid["masklow"] = grid.value.where(~grid["flag"].str.contains(hg.LOW_TOKEN, regex=False))
    grid["_dmin"] = pd.to_datetime(grid.status_date_min)
    grid["_dmax"] = pd.to_datetime(grid.status_date_max)
    dates = grid.groupby(UNIT_KEYS).agg(status_date_min=("_dmin", "min"), status_date_max=("_dmax", "max"))
    dates = dates.apply(lambda c: c.dt.strftime("%Y-%m-%d")).reset_index()

    wide = _wide(frame, grid, dates)
    dropped = hg.dropped_indicators(wide)
    try:
        unusable, halt = hg.check_halt(dropped, wide), None
    except PanelHalt as e:
        unusable, halt = hg.unusable_fys(wide), str(e)
    if halt is None and len(unusable) == 1:
        sel = grid.fy == unusable[0]
        grid.loc[sel, VALUE_COLUMNS] = np.nan
        grid["flag"] = _tokens(grid["flag"], sel, "fy_unusable")
        extra = pd.DataFrame([{"indicator": i, "unit_id": "ALL", "fy": unusable[0], "month": m,
                               "check": "fy_unusable", "disposition": "mask", "rule": hg.RULES["fy_unusable"],
                               "reason": hg.DEFAULT_REASON, "evidence": "no unit has a final value for any PRIMARY5 "
                                                                       "indicator in this FY"}
                              for i in INDICATORS for m in FY_MONTHS], columns=hg.REVIEWED_COLUMNS)
        log = pd.concat([log, extra], ignore_index=True) if len(log) else extra
        wide = _wide(frame, grid, dates)

    cmp = hg.national_comparison(raw, national)
    summary = hg.gate_summary(grid, wide, cmp, dmu, dropped)
    results = [r for _, r in gate_out]
    detail = (f"dropped indicators: {', '.join(dropped) or 'none'}; unusable primary FYs: "
              f"{', '.join(unusable) or 'none'}" + (f"; HALT: {halt}" if halt else ""))
    sup = "; ".join(f"{fy} {lab} ({n} rows)" for (fy, lab), n in s.attrs.get("superseded", {}).items())
    detail += f"; superseded pre-merger rows dropped (ruling F36): {sup or 'none'}"
    results.append(GateResult("hmis_panel", halt is None, detail))
    sd = {}
    for scope, sel in (("primary", grid.fy.isin(PRIMARY_FYS)), ("fy2020_21", grid.fy == FY2021)):
        g = grid[sel]
        sd[scope] = ((g._dmin.min().strftime("%Y-%m-%d"), g._dmax.max().strftime("%Y-%m-%d"))
                     if g._dmin.notna().any() else None)
    return {"panel": wide, "grid": grid, "failures": failures, "log": log, "results": results,
            "summary": summary, "breaks": hg.break_ratio_2017(raw), "national_cmp": cmp, "dropped": dropped,
            "unusable": unusable, "halt": halt, "status_dates": sd}


# ---- files -------------------------------------------------------------------------------------------------------
def _read_parts(parts: Path):
    parts = Path(parts)
    st = pd.read_csv(parts / "state_month.csv.gz", dtype={"fy": str, "state_raw": str})
    comp = pd.read_csv(parts / "completeness.csv.gz", dtype={"fy": str, "state_raw": str})
    dm = pd.read_csv(parts / "district_month.csv.gz", dtype={"fy": str, "state_raw": str, "district_raw": str},
                     usecols=["fy", "month", "state_raw", "district_raw", "indicator", "value_raw", "value",
                              "negative", "valid"])
    for c in ("negative", "valid"):
        dm[c] = dm[c].astype(str).str.lower().eq("true")
    st["partial_component"] = st.partial_component.astype(str).str.lower().eq("true")
    return st, comp, dm


def _fmt(x, nd=0) -> str:
    return "" if pd.isna(x) else (f"{x:,.{nd}f}" if nd else f"{x:,.0f}")


def report_section(res: dict, national_note: str) -> str:
    s = res["summary"]
    pr = s[s.scope == "primary"]
    lines = [REPORT_HEADING, "",
             "Generated by `python -I pipeline/hmis/run.py panel` (pipeline/hmis/panel.py, gates.py). State-month "
             "values are the portal's official monthly state aggregates (the All_India workbook state rows; FY2020-21: "
             "the state aggregate column group), pooled to the 34 units; districts serve only as the completeness "
             "layer (a value enters models when >= 90% of the state's listed districts are valid). Failing cells are "
             "masked by default and logged in pipeline/reference/hmis_reviewed.csv (spec §10.2); plausibility lows "
             "(< 0.33x the within-era calendar-month median) are kept by default and masked only in the "
             "`<ind>_masklow` sensitivity (ruling F41). " + national_note
             + (f" **HALT: {res['halt']}. The panel and hmis_reviewed.csv were not rewritten.**" if res["halt"] else ""),
             ""]
    lines += [f"- {format_result(r)}" for r in res["results"]]
    lines += ["", "### Primary window FY2012-13..2019-20 (gate_summary.csv)", "",
              "| indicator | reported | masked | masked share | lows kept | comp < 0.90 | entering models | dropped |",
              "|---|---|---|---|---|---|---|---|"]
    lines += [f"| {r.indicator} | {r.reported} | {r.masked} | {r.masked_share:.4f} | {r.kept_low} | {r.comp_lt_090} | "
              f"{r.entering_models} | {r.dropped} |" for r in pr.itertuples()]
    sd = res["status_dates"]
    lines += ["", "Status dates (\"Status As On\"): " + "; ".join(
        f"{k} {v[0]} to {v[1]}" for k, v in sd.items() if v) + ".",
        f"Dropped indicators: {', '.join(res['dropped']) or 'none'}. Unusable primary FYs: "
        f"{', '.join(res['unusable']) or 'none'}." + (f" HALT: {res['halt']}" if res["halt"] else ""),
        "", "### National March 2017 to April 2017 ratio (descriptive; spec §3.4)", "",
        "| indicator | March 2017 | April 2017 | ratio | > 25% | units |", "|---|---|---|---|---|---|"]
    lines += [f"| {r.indicator} | {_fmt(r.mar2017)} | {_fmt(r.apr2017)} | "
              f"{'' if pd.isna(r.ratio) else f'{r.ratio:.3f}'} | {r.gt25pct} | {r.n_units} |"
              for r in res["breaks"].itertuples()]
    return "\n".join(lines) + "\n"


def write_report_section(path: Path, section: str) -> None:
    """Replace (or append) the REPORT_HEADING section of the validation report."""
    path = Path(path)
    text = path.read_text(encoding="utf-8") if path.exists() else "# Validation report\n"
    lines = text.splitlines()
    if REPORT_HEADING in lines:
        a = lines.index(REPORT_HEADING)
        b = next((k for k in range(a + 1, len(lines)) if lines[k].startswith("## ")), len(lines))
        lines = lines[:a] + lines[b:]
    while lines and not lines[-1].strip():
        lines.pop()
    path.write_text("\n".join(lines) + "\n\n" + section, encoding="utf-8")


def _round(panel: pd.DataFrame) -> pd.DataFrame:
    p = panel.copy()
    for i in INDICATORS:
        p[f"comp_{i}"] = p[f"comp_{i}"].round(6)
        p[f"{i}_scaled"] = p[f"{i}_scaled"].round(2)
    return p


def build_panel(out=PANEL_PATH, parts=PARTS, national_path=None, reviewed_path=hg.REVIEWED_PATH,
                summary_out=SUMMARY_PATH, break_out=BREAK_PATH, report_path=VALIDATION_REPORT, fys=None) -> Path:
    """Read the Task 3 parts, build and gate the panel, write the panel, gate_summary, break ratios, the reviewed
    dispositions and the validation-report section. Raises PanelHalt AFTER writing them when §10.2 halts."""
    res = build_outputs(out, parts, national_path, reviewed_path, summary_out, break_out, report_path, fys)
    if res["halt"]:
        raise PanelHalt(res["halt"])
    return Path(out)


def build_outputs(out=PANEL_PATH, parts=PARTS, national_path=None, reviewed_path=hg.REVIEWED_PATH,
                  summary_out=SUMMARY_PATH, break_out=BREAK_PATH, report_path=VALIDATION_REPORT, fys=None) -> dict:
    """build_panel without the raise; returns assemble()'s dict. On a halt (spec §10.2) only gate_summary.csv,
    break_ratio_2017.csv and the validation-report section (with the HALT line) are written: the tracked panel and
    hmis_reviewed.csv are left as they were (task-4 review M-5)."""
    st, comp, dm = _read_parts(parts)
    national_path = Path(national_path) if national_path else Path(parts) / NATIONAL_PART.name
    if national_path.exists():
        national = pd.read_csv(national_path, dtype={"fy": str})
        note = f"National totals: {national_path.name} (folder-1 All India files net of M/O rows, ruling F39)."
    else:
        national = None
        note = "National totals: not available (no national_month part), so the national gate masks nothing."
    reviewed = hg.read_reviewed(reviewed_path)
    res = assemble(st, comp, dm, national, reviewed, fys)
    for path, df in ((summary_out, res["summary"]), (break_out, res["breaks"])):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        df.to_csv(path, index=False)
    write_report_section(report_path, report_section(res, note))
    if res["halt"]:
        return res
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    _round(res["panel"]).to_csv(out, index=False)
    hg.write_reviewed(res["log"], reviewed_path, manual=reviewed)
    return res
