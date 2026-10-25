"""District-month flags and state-month completeness (Paper E, Task 3; spec §3.6, §10.1, §12; rulings F10, F11,
F29-F32). Missing is never zero: a flagged district-month is NaN, and a listed district with no value is `nofile`.

Flags on monthly district values (one row per state_raw x district_raw x FY x month x indicator):
- `negative` (difference.flag_negative): a negative monthly value;
- `nofile` (difference.mark_nofile): a district listed in the state-FY with no value that month;
- `nonreport`: a zero where the district's FY median for the indicator is >= NONREPORT_MIN_MEDIAN (20); the
  median is taken over the district's months with no `negative` or `nofile` flag (reported zeros included);
- `catchup`: a value > CATCHUP_FACTOR (3) x that median in the month right after a `nonreport` month of the
  same FY (April never follows the previous FY's March);
- `valid`: none of the four flags and a non-missing value. `value` is NaN unless `valid`; `value_raw` keeps the
  reported number. `vintage_mixed` is a state-FY property (difference.vintage_mixed), reported, never masked.

Hand-off tables (Task 4 consumes them; all git-ignored under data/derived/hmis/_parts/ except the report):
- `district_month.csv.gz` (DM_COLUMNS): fy, month (calendar), state_raw (the state workbook's title unit),
  district_raw, indicator, value_raw, value, n_components, n_present, partial_component, negative, nofile,
  nonreport, catchup, valid, status_date, source_file.
- `state_month.csv.gz` (STATE_COLUMNS): the official state aggregate (spec §12.2): the state's row in the FY's
  `All_India.xls` (FY2012-13..2019-20) or the first column group of the FY2020-21 state-month file. fy, month,
  state_raw (the All_India row name or the E3 title unit), indicator, value, n_components, n_present,
  partial_component, status_date, source_file. M/O Defence and M/O Railways rows are excluded (ruling F30).
- `completeness.csv.gz` (COMP_COLUMNS): state_raw, fy, month, indicator, n_districts (districts listed in any
  file of the state-FY), n_valid, comp = n_valid / n_districts, n_valid_full (valid AND n_present ==
  n_components), comp_full (the all-components-present sensitivity).
- `vintage.csv.gz` (VINTAGE_COLUMNS, difference.py), `month_total_check.csv.gz` (difference.CHECK_COLUMNS, the
  crosswalk items only) and `members.csv.gz` (run.MEMBER_COLUMNS: one row per zip member or file, with status
  parsed / excluded / error and the count of unparseable value cells).
- `data/derived/hmis/differencing_report.csv` (tracked; REPORT_COLUMNS; counts and shares only, one row per
  indicator x FY): n_district_months, negative, nonreport, catchup, vintage_mixed (district-months in
  vintage-mixed state-FYs), nofile, share_flagged (any of negative / nofile / nonreport / catchup over
  n_district_months), vintage_mixed_state_fys, month_total_checked and month_total_fail (unit x item checks
  of the indicator's items, districts and state rows), state_months (non-missing state aggregates),
  partial_component (share of those where a missing component was non-zero elsewhere in the FY; F32: Task 4
  masks them if > 5%), state_all_components_share and district_all_components_share (n_present ==
  n_components among non-missing values), notes (excluded members, member errors, upload-status concordance).
"""
import numpy as np
import pandas as pd

from pipeline.hmis.crosswalk import INDICATORS, UNIT_MONTH
from pipeline.hmis import difference as _hd
from pipeline.hmis.difference import FY_MONTHS, flag_negative, is_non_state, mark_nofile
from pipeline.hmis.parse import era_for_fy

NONREPORT_MIN_MEDIAN = 20
CATCHUP_FACTOR = 3
VINTAGE_COLUMNS = _hd.VINTAGE_COLUMNS                               # re-exported for the hand-off docs
FLAGS = ["negative", "nofile", "nonreport", "catchup"]
DM_COLUMNS = ["fy", "month", "state_raw", "district_raw", "indicator", "value_raw", "value", "n_components",
              "n_present", "partial_component", "negative", "nofile", "nonreport", "catchup", "valid",
              "status_date", "source_file"]
STATE_COLUMNS = ["fy", "month", "state_raw", "indicator", "value", "n_components", "n_present",
                 "partial_component", "status_date", "source_file"]
COMP_COLUMNS = ["state_raw", "fy", "month", "indicator", "n_districts", "n_valid", "comp", "n_valid_full",
                "comp_full"]
REPORT_COLUMNS = ["indicator", "fy", "n_district_months", "negative", "nonreport", "catchup", "vintage_mixed",
                  "nofile", "share_flagged", "vintage_mixed_state_fys", "month_total_checked", "month_total_fail",
                  "state_months", "partial_component", "state_all_components_share",
                  "district_all_components_share", "notes"]
_SERIES = ["state_raw", "district_raw", "fy", "indicator"]
_POS = {m: i for i, m in enumerate(FY_MONTHS)}


def flag_district_months(dm: pd.DataFrame) -> pd.DataFrame:
    """Adds `nonreport`, `catchup` and `valid` to a frame that already has `negative` and `nofile`; sets
    `value` to NaN wherever a flag is set."""
    dm = dm.copy()
    dm["_pos"] = dm["month"].map(_POS)
    dm = dm.sort_values(_SERIES + ["_pos"], kind="stable").reset_index(drop=True)
    by = [dm[k] for k in _SERIES]
    base = ~dm.negative & ~dm.nofile & dm.value.notna()
    med = dm.value.where(base).groupby(by).transform("median")
    dm["nonreport"] = (base & (dm.value == 0) & (med >= NONREPORT_MIN_MEDIAN)).astype(bool)
    prev = dm.groupby(_SERIES, sort=False)["nonreport"].shift(1, fill_value=False).astype(bool)
    prev_pos = dm.groupby(_SERIES, sort=False)["_pos"].shift(1)
    dm["catchup"] = (base & (dm.value > CATCHUP_FACTOR * med) & prev & (prev_pos == dm._pos - 1)).astype(bool)
    dm["valid"] = (~dm[FLAGS].any(axis=1) & dm.value.notna()).astype(bool)
    dm["value"] = dm.value.where(dm.valid)
    return dm.drop(columns="_pos")


def flag_all(dm: pd.DataFrame, lists: pd.DataFrame) -> pd.DataFrame:
    """Crosswalked district rows (fy, month, state_raw, district_raw, indicator, value, n_components, n_present,
    partial_component, status_date, source_file) -> DM_COLUMNS: nofile, negative, nonreport, catchup, valid."""
    dm = dm.copy()
    if "partial_component" not in dm.columns:
        dm["partial_component"] = False
    dm["value_raw"] = dm["value"].astype(float)
    dm = flag_district_months(flag_negative(mark_nofile(dm, lists)))
    return dm.sort_values(["fy", "state_raw", "district_raw", "indicator", "month"],
                          key=lambda s: s.map(_POS) if s.name == "month" else s, kind="stable"
                          )[DM_COLUMNS].reset_index(drop=True)


def district_lists(long: pd.DataFrame) -> pd.DataFrame:
    """Every district (non-aggregate row) in any file of each state-FY: state_raw, fy, district_raw. State rows
    (is_state_aggregate, district_raw "") and M/O members are never districts (rulings F11, F30)."""
    d = long[~long.is_state_aggregate.astype(bool) & (long.district_raw != "")]
    out = d[["state_raw", "fy", "district_raw"]].drop_duplicates()
    mo = {s for s in out.state_raw.unique() if is_non_state(s)}
    return out[~out.state_raw.isin(mo)].reset_index(drop=True)


def completeness(dm_flagged: pd.DataFrame, lists: pd.DataFrame) -> pd.DataFrame:
    """COMP_COLUMNS per state x FY x month x indicator; the denominator is the listed districts."""
    listed = lists[["state_raw", "fy", "district_raw"]].drop_duplicates()
    n_dist = listed.groupby(["state_raw", "fy"]).size().rename("n_districts").reset_index()
    inds = dm_flagged[["fy", "indicator"]].drop_duplicates()
    frame = n_dist.merge(inds, on="fy").merge(pd.DataFrame({"month": list(FY_MONTHS)}), how="cross")
    d = dm_flagged.merge(listed, on=["state_raw", "fy", "district_raw"])
    d = d.assign(full=d.valid & (d.n_present == d.n_components))
    keys = ["state_raw", "fy", "month", "indicator"]
    g = d.groupby(keys).agg(n_valid=("valid", "sum"), n_valid_full=("full", "sum")).reset_index()
    out = frame.merge(g, on=keys, how="left")
    out[["n_valid", "n_valid_full"]] = out[["n_valid", "n_valid_full"]].fillna(0).astype(int)
    out["comp"] = out.n_valid / out.n_districts
    out["comp_full"] = out.n_valid_full / out.n_districts
    out = out.sort_values(["fy", "state_raw", "indicator", "month"], key=lambda s: s.map(_POS)
                          if s.name == "month" else s, kind="stable")
    return out[COMP_COLUMNS].reset_index(drop=True)


def neg_share(dm: pd.DataFrame) -> pd.DataFrame:
    """Per indicator: n (district-months with a reported value), n_negative, share."""
    g = dm.groupby("indicator")
    out = pd.DataFrame({"n": g["value_raw"].count(), "n_negative": g["negative"].sum()}).reset_index()
    out["share"] = out.n_negative / out.n.where(out.n > 0)
    return out[["indicator", "n", "n_negative", "share"]]


def partial_component(long: pd.DataFrame, xw: pd.DataFrame) -> pd.DataFrame:
    """Per unit-month x indicator: True when at least one component is present and a missing component has a
    non-zero value in another month of the same FY for the same unit (F32). Single-item indicators: False.
    Pass every month of the FY for a unit (all month files of a state in FY2020-21)."""
    unit = ["fy", "state_raw", "district_raw", "is_state_aggregate"]
    parts = []
    for fy, g in long.groupby("fy", sort=False):
        for r in xw[xw.era == era_for_fy(fy)].itertuples():
            codes = r.item_codes.split("|")
            sub = g[g.item_code.isin(codes)]
            if len(codes) == 1:
                out = sub[UNIT_MONTH].drop_duplicates().assign(partial_component=False)
            else:
                nz = (sub.value > 0).astype(int).groupby([sub[k] for k in unit + ["item_code"]]).transform("max")
                flags = pd.DataFrame({"miss": sub.value.isna() & (nz == 1), "present": sub.value.notna()})
                agg = flags.groupby([sub[k] for k in UNIT_MONTH]).any()
                out = agg.reset_index()
                out["partial_component"] = out.miss & out.present
            parts.append(out.assign(indicator=r.indicator)[UNIT_MONTH + ["indicator", "partial_component"]])
    if not parts:
        return pd.DataFrame(columns=UNIT_MONTH + ["indicator", "partial_component"])
    out = pd.concat(parts, ignore_index=True)
    out["partial_component"] = out.partial_component.astype(bool)
    return out


def _share(num, den):
    return float(num) / den if den else np.nan


def flag_report(dm: pd.DataFrame, state: pd.DataFrame, check: pd.DataFrame, vint: pd.DataFrame,
                xw: pd.DataFrame, notes: dict) -> pd.DataFrame:
    """REPORT_COLUMNS, one row per indicator x FY (every FY in `notes` or in `dm`). Counts and shares only."""
    rows = []
    fys = sorted(set(notes) | set(dm.fy) | set(state.fy))
    for fy in fys:
        era = era_for_fy(fy)
        mixed = set(vint[(vint.fy == fy) & vint.vintage_mixed.astype(bool)].state_raw)
        for ind in INDICATORS:
            d = dm[(dm.fy == fy) & (dm.indicator == ind)]
            s = state[(state.fy == fy) & (state.indicator == ind)]
            codes = "|".join(xw[(xw.era == era) & (xw.indicator == ind)].item_codes).split("|")
            c = check[(check.fy == fy) & check.item_code.isin(codes)]
            n = len(d)
            reported = d.value_raw.notna()
            s_ok = s.value.notna()
            rows.append({
                "indicator": ind, "fy": fy, "n_district_months": n,
                "negative": int(d.negative.sum()), "nonreport": int(d.nonreport.sum()),
                "catchup": int(d.catchup.sum()), "vintage_mixed": int(d.state_raw.isin(mixed).sum()),
                "nofile": int(d.nofile.sum()), "share_flagged": _share(d[FLAGS].any(axis=1).sum(), n),
                "vintage_mixed_state_fys": len(mixed), "month_total_checked": len(c),
                "month_total_fail": int((~c["pass"].astype(bool)).sum()), "state_months": int(s_ok.sum()),
                "partial_component": _share((s.partial_component.astype(bool) & s_ok).sum(), s_ok.sum()),
                "state_all_components_share": _share(((s.n_present == s.n_components) & s_ok).sum(), s_ok.sum()),
                "district_all_components_share": _share(((d.n_present == d.n_components) & reported).sum(),
                                                        reported.sum()),
                "notes": notes.get(fy, "")})
    return pd.DataFrame(rows, columns=REPORT_COLUMNS)
