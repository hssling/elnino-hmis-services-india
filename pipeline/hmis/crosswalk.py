"""HMIS item crosswalk (Paper E, Task 2; spec §3.4).

`pipeline/reference/hmis_item_crosswalk.csv` maps each analysis indicator, per era, to HMIS item codes. An item
is used only when its code AND its normalised text match (`text_pattern`, a regex searched in
`normalise_text(item_text)`); a code whose text does not match, a missing item, or a duplicated
(code, type) row stops the build with CrosswalkError naming the file and the code.

Era by FY (parse.era_for_fy): E1 FY2012-13..2016-17, E2 FY2017-18..2019-20, E3 FY2020-21.

Hand-off (Task 3 consumes this): `apply_crosswalk(long, xw)` returns OUT_COLUMNS
  fy, month, state_raw, district_raw, is_state_aggregate (as in parse.LONG_COLUMNS), indicator (one of
  INDICATORS), value (float: the item value, or the sum of the items with min_count=1, so all-missing stays
  NaN), n_components (int, items in the crosswalk row), n_present (int, items with a non-missing value),
  cumulative (bool), status_date (date or None), source_file (str).
One row per (source_file, unit, month, indicator) present in the long table.
"""
import re
import unicodedata
from pathlib import Path

import pandas as pd

from pipeline.hmis.parse import era_for_fy

REF = Path(__file__).resolve().parents[1] / "reference"
XW_PATH = REF / "hmis_item_crosswalk.csv"
INDICATORS = ("diarr_u5", "anc_reg", "penta3", "mcv1", "fic", "inst_del", "opd")
PRIMARY5 = ("diarr_u5", "anc_reg", "penta3", "inst_del", "opd")
ERAS = ("E1", "E2", "E3")
XW_COLUMNS = ["indicator", "era", "item_codes", "combine", "text_pattern", "definition_note", "verified_in_file"]
OUT_COLUMNS = ["fy", "month", "state_raw", "district_raw", "is_state_aggregate", "indicator", "value",
               "n_components", "n_present", "cumulative", "status_date", "source_file"]
UNIT_MONTH = ["fy", "month", "state_raw", "district_raw", "is_state_aggregate"]


class CrosswalkError(ValueError):
    """A crosswalk item that is missing, duplicated, or whose text does not match its code."""


def normalise_text(s: str) -> str:
    """Lower case; every Unicode dash -> '-'; whitespace collapsed; no spaces around '-'; '&' -> 'and'."""
    s = "".join("-" if unicodedata.category(c) == "Pd" or c == "−" else c for c in str(s).lower())
    s = s.replace("&", " and ")
    s = " ".join(s.split())
    return re.sub(r"\s*-\s*", "-", s)


def load_crosswalk(path=XW_PATH) -> pd.DataFrame:
    """The crosswalk table, validated: one row per indicator x era, 'single' = one code, 'sum' = two or more,
    every pattern compiles."""
    xw = pd.read_csv(path, dtype=str, keep_default_na=False)
    if list(xw.columns) != XW_COLUMNS:
        raise CrosswalkError(f"{path}: columns {list(xw.columns)} != {XW_COLUMNS}")
    keys = list(zip(xw.indicator, xw.era))
    want = [(i, e) for i in INDICATORS for e in ERAS]
    if sorted(keys) != sorted(want):
        raise CrosswalkError(f"{path}: need exactly one row per indicator x era; extra "
                             f"{sorted(set(keys) - set(want))}, missing {sorted(set(want) - set(keys))}, "
                             f"duplicated {sorted({k for k in keys if keys.count(k) > 1})}")
    for r in xw.itertuples():
        codes = [c for c in r.item_codes.split("|") if c]
        if r.combine not in ("single", "sum") or (r.combine == "single") != (len(codes) == 1) or not codes:
            raise CrosswalkError(f"{path}: {r.indicator} {r.era}: combine {r.combine!r} with codes {r.item_codes!r}")
        try:
            re.compile(r.text_pattern)
        except re.error as e:
            raise CrosswalkError(f"{path}: {r.indicator} {r.era}: bad text_pattern ({e})") from e
    return xw


def _check_items(g: pd.DataFrame, source_file: str, row) -> pd.DataFrame:
    codes = row.item_codes.split("|")
    sub = g[g.item_code.isin(codes)]
    missing = [c for c in codes if c not in set(sub.item_code)]
    if missing:
        raise CrosswalkError(f"{source_file}: item {', '.join(missing)} ({row.indicator}, {row.era}) not found")
    pat = re.compile(row.text_pattern)
    for code, text in sub[["item_code", "item_text"]].drop_duplicates().itertuples(index=False):
        if not pat.search(normalise_text(text)):
            raise CrosswalkError(f"{source_file}: item {code} text {text!r} does not match the {row.indicator} "
                                 f"({row.era}) pattern {row.text_pattern!r}")
    dup = sub.duplicated(UNIT_MONTH + ["item_code", "type"], keep=False)
    if dup.any():
        d = sub[dup].iloc[0]
        raise CrosswalkError(f"{source_file}: item {d.item_code} type {d.type!r} duplicated "
                             f"({d.state_raw}/{d.district_raw}, month {d.month})")
    n_types = sub.groupby("item_code")["type"].nunique()
    if (n_types > 1).any():
        code = n_types[n_types > 1].index[0]
        raise CrosswalkError(f"{source_file}: item {code} has several types; the crosswalk needs one")
    return sub


def apply_crosswalk(long: pd.DataFrame, xw: pd.DataFrame) -> pd.DataFrame:
    """Long item rows (parse.LONG_COLUMNS) -> one row per unit-month-indicator (OUT_COLUMNS)."""
    parts = []
    for (fy, source_file), g in long.groupby(["fy", "source_file"], sort=False):
        era = era_for_fy(fy)
        base = g[UNIT_MONTH].drop_duplicates()
        meta = {"cumulative": bool(g.cumulative.iloc[0]), "status_date": g.status_date.iloc[0]}
        for row in xw[xw.era == era].itertuples():
            sub = _check_items(g, source_file, row)
            grp = sub.groupby(UNIT_MONTH, sort=False)["value"]
            agg = pd.DataFrame({"value": grp.sum(min_count=1), "n_present": grp.count()}).reset_index()
            out = base.merge(agg, on=UNIT_MONTH, how="left")
            out["n_present"] = out["n_present"].fillna(0).astype(int)
            out["n_components"] = len(row.item_codes.split("|"))
            out["indicator"] = row.indicator
            out["cumulative"] = meta["cumulative"]
            out["status_date"] = meta["status_date"]
            out["source_file"] = source_file
            parts.append(out[OUT_COLUMNS])
    if not parts:
        return pd.DataFrame(columns=OUT_COLUMNS)
    out = pd.concat(parts, ignore_index=True)
    out["value"] = out["value"].astype(float)
    return out


def verify_crosswalk(xw: pd.DataFrame, manifest_rows) -> list[str]:
    """Problems with `verified_in_file` ('<repo path>::<member>', or '<repo path>' for a file that is not an
    archive): empty, or naming a path with no MANIFEST row."""
    listed = {r["path"] for r in manifest_rows if str(r.get("deleted", "0")) != "1"}
    problems = []
    for r in xw.itertuples():
        v = str(r.verified_in_file).strip()
        if not v:
            problems.append(f"{r.indicator} {r.era}: verified_in_file is empty")
            continue
        path = v.split("::", 1)[0]
        if path not in listed:
            problems.append(f"{r.indicator} {r.era}: {path} has no MANIFEST row")
    return problems
