"""Monthly HMIS checks (Paper E, Task 3; spec §12, rulings F29-F31).

The portal workbooks hold MONTHLY values (spec §12.1), so nothing is differenced: this module keeps the name
from the plan but holds the checks that replace differencing.

- `FY_MONTHS`: the calendar months of a fiscal year, April first.
- `month_total_check(long, tol=0.01)`: for every unit x item of a parsed file (parse.parse_member(...,
  fy_total=True)), the 12 monthly values against the file's FY-total column (spec §12.4). Returns CHECK_COLUMNS:
    state_raw, district_raw ("" on state rows), fy, item_code, sum_months (sum of the non-missing months; NaN when
    all 12 are missing), fy_total (NaN when blank), rel_diff ((sum_months - fy_total) / fy_total; 0 when both
    are 0, inf when only the total is 0, NaN when either is missing), pass (|rel_diff| <= tol; True when no
    month is reported and the total is blank or 0; False when months are reported and the total is blank),
    is_state_aggregate, type, source_file.
- `flag_negative(dm)`: a negative monthly district value is NaN and flagged `negative` (spec §12.3).
- `mark_nofile(dm, lists)`: every listed district of a state-FY gets 12 months x the indicators; a listed
  district with no value in a month (no row, or a missing value) is NaN and flagged `nofile` (spec §12.3).
- `vintage_mixed(state_dates, all_india_dates)`: a state-FY whose workbook(s) and the All-India file carry
  different status dates (spec §12.3: reported, never masked). Returns VINTAGE_COLUMNS
    state_raw, fy, status_date_state, status_date_all_india (distinct ISO dates joined by ";", "" if none),
    vintage_mixed (more than one distinct date across both; False when either side has no date).
- `is_non_state(name)`: the central-ministry members/rows "M O Defence" and "M O Railways" (ruling F30).
"""
import re

import numpy as np
import pandas as pd

FY_MONTHS = (4, 5, 6, 7, 8, 9, 10, 11, 12, 1, 2, 3)
CHECK_COLUMNS = ["state_raw", "district_raw", "fy", "item_code", "sum_months", "fy_total", "rel_diff", "pass",
                 "is_state_aggregate", "type", "source_file"]
VINTAGE_COLUMNS = ["state_raw", "fy", "status_date_state", "status_date_all_india", "vintage_mixed"]
DISTRICT_KEYS = ["state_raw", "fy", "district_raw"]
_NON_STATE = {"modefence", "morailways"}


def is_non_state(name: str) -> bool:
    """True for "M O Defence" / "M/O Railways" (any case, spacing or punctuation; a path or extension is ignored)."""
    name = re.sub(r"\.(xlsx?|csv)$", "", str(name), flags=re.I)
    last = name.replace("\\", "/").split("/")[-1]                    # a member path, or "M/O Defence" itself
    return any(re.sub(r"[^a-z]", "", x.lower()) in _NON_STATE for x in (name, last))


def month_total_check(long: pd.DataFrame, tol: float = 0.01) -> pd.DataFrame:
    """The 12 monthly values of each unit x item against the file's FY total (spec §12.4)."""
    if "fy_total" not in long.columns:
        raise KeyError("month_total_check needs the fy_total column (parse_member(..., fy_total=True))")
    keys = ["source_file", "fy", "state_raw", "district_raw", "is_state_aggregate", "item_code", "type"]
    if long.empty:
        return pd.DataFrame(columns=CHECK_COLUMNS)
    g = long.groupby(keys, sort=False, dropna=False)
    out = pd.DataFrame({"sum_months": g["value"].sum(min_count=1), "fy_total": g["fy_total"].first()}).reset_index()
    s, t = out.sum_months, out.fy_total
    with np.errstate(divide="ignore", invalid="ignore"):
        rel = np.where((t == 0) & (s == 0), 0.0, (s - t) / t)
    out["rel_diff"] = np.where(s.isna() | t.isna(), np.nan, rel)
    nothing = s.isna() & (t.isna() | (t == 0))
    out["pass"] = nothing | (np.abs(out.rel_diff) <= tol)
    return out[CHECK_COLUMNS]


def flag_negative(dm: pd.DataFrame) -> pd.DataFrame:
    """Adds `negative` (value < 0); those values become NaN."""
    dm = dm.copy()
    dm["negative"] = (dm["value"] < 0).fillna(False).astype(bool)
    dm.loc[dm.negative, "value"] = np.nan
    return dm


def mark_nofile(dm: pd.DataFrame, lists: pd.DataFrame) -> pd.DataFrame:
    """Completes `dm` to every listed district x FY month x indicator of its state-FYs and adds `nofile`.
    Added rows have value NaN, n_present 0, n_components from the indicator's other rows, status_date and
    source_file from the state-FY's other rows. A district in `dm` but not in `lists` is an error."""
    listed = lists[DISTRICT_KEYS].drop_duplicates()
    unlisted = dm[DISTRICT_KEYS].drop_duplicates().merge(listed, how="left", indicator=True)
    unlisted = unlisted[unlisted["_merge"] == "left_only"]
    if len(unlisted):
        r = unlisted.iloc[0]
        raise ValueError(f"district {r.district_raw!r} ({r.state_raw}, {r.fy}) is not in the district lists")
    inds = dm[["fy", "indicator", "n_components"]].drop_duplicates(["fy", "indicator"])
    months = pd.DataFrame({"month": list(FY_MONTHS)})
    frame = listed.merge(inds, on="fy").merge(months, how="cross")
    keys = DISTRICT_KEYS + ["indicator", "month"]
    out = frame.merge(dm.drop(columns="n_components"), on=keys, how="left")
    meta = dm.groupby(["state_raw", "fy"])[["status_date", "source_file"]].first()
    miss = out.source_file.isna()
    if miss.any():
        filled = out.loc[miss, ["state_raw", "fy"]].join(meta, on=["state_raw", "fy"])
        out.loc[miss, "status_date"] = filled["status_date"].values
        out.loc[miss, "source_file"] = filled["source_file"].fillna("").values
    out["n_present"] = out["n_present"].fillna(0).astype(int)
    if "partial_component" in out.columns:
        out["partial_component"] = out["partial_component"].astype("boolean").fillna(False).astype(bool)
    out["value"] = out["value"].astype(float)
    out["nofile"] = out["value"].isna()
    cols = [c for c in dm.columns if c in out.columns] + [c for c in out.columns if c not in dm.columns]
    return out[cols].reset_index(drop=True)


def _dates(s: pd.Series) -> str:
    return ";".join(sorted({str(d) for d in s.dropna() if str(d) not in ("", "None", "NaT")}))


def vintage_mixed(state_dates: pd.DataFrame, all_india_dates: pd.DataFrame) -> pd.DataFrame:
    """state_dates: state_raw, fy, status_date (one row per state file); all_india_dates: fy, status_date."""
    st = state_dates.groupby(["state_raw", "fy"], sort=True)["status_date"].apply(_dates).rename("status_date_state")
    ai = all_india_dates.groupby("fy")["status_date"].apply(_dates).rename("status_date_all_india")
    out = st.reset_index().join(ai, on="fy")
    out["status_date_all_india"] = out["status_date_all_india"].fillna("")

    def mixed(r):
        a, b = r.status_date_state, r.status_date_all_india
        return bool(a and b and len(set(a.split(";")) | set(b.split(";"))) > 1)

    out["vintage_mixed"] = out.apply(mixed, axis=1).astype(bool) if len(out) else pd.Series(dtype=bool)
    return out[VINTAGE_COLUMNS]
