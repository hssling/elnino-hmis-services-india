"""Monthly HMIS checks (Paper E, Task 3; spec §12, rulings F29-F31). The portal files are monthly, so nothing is
differenced: negative monthly values, listed districts with no value (nofile), the 12-month vs FY-total check,
vintage_mixed per state-FY and the non-state (M/O) members. Fixtures are synthetic (ruling F1)."""
import math
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from pipeline.hmis import difference as hd
from pipeline.hmis import parse as hp

FIX = Path(__file__).resolve().parent / "fixtures"
E1_STATE = FIX / "e1_synthetic_state_1415.xls.html"
E2_HTML = FIX / "e2_synthetic_state_1920.xls.html"
E3_STATE = FIX / "e3_synthetic_state_2021_oct.xlsx"


def dm_rows(values, district="District A", indicator="anc_reg", state="Test State", fy="2014-15"):
    """A district-month frame: one row per FY month (April first) for one district and indicator."""
    return pd.DataFrame({"fy": fy, "month": list(hd.FY_MONTHS)[:len(values)], "state_raw": state,
                         "district_raw": district, "indicator": indicator, "value": [float(v) for v in values],
                         "n_components": 1, "n_present": [0 if pd.isna(v) else 1 for v in values],
                         "status_date": date(2016, 1, 29), "source_file": "x.xls"})


def lists_of(state, fy, districts):
    return pd.DataFrame({"state_raw": state, "fy": fy, "district_raw": list(districts)})


def test_fy_months_april_to_march():
    assert hd.FY_MONTHS == (4, 5, 6, 7, 8, 9, 10, 11, 12, 1, 2, 3)


# ---- parse exposes the FY-total column (without changing LONG_COLUMNS) -----------------------------------
def test_parse_exposes_fy_total_only_on_request():
    plain = hp.parse_member(E1_STATE.name.removesuffix(".html"), E1_STATE.read_bytes(), "2014-15")
    assert list(plain.columns) == hp.LONG_COLUMNS
    df = hp.parse_member(E1_STATE.name.removesuffix(".html"), E1_STATE.read_bytes(), "2014-15", fy_total=True)
    assert list(df.columns) == hp.LONG_COLUMNS + ["fy_total"]
    a = df[(df.district_raw == "District A") & (df.item_code == "1.1")]
    assert a.fy_total.nunique() == 1 and a.fy_total.iloc[0] == a.value.sum()      # fixture Total = sum of months
    e2 = hp.parse_member(E2_HTML.name.removesuffix(".html"), E2_HTML.read_bytes(), "2019-20", fy_total=True)
    b = e2[(e2.district_raw == "District B") & (e2.item_code == "10.11")]
    assert b.fy_total.iloc[0] == b.value.sum() and b.fy_total.iloc[0] < 20000     # the Total split of the Total
    e3 = hp.parse_member(E3_STATE.name, E3_STATE.read_bytes(), "2020-21", fy_total=True)
    assert e3.fy_total.isna().all()                                 # one month per file: no FY total


def test_parse_counts_unparseable_cells_per_member():
    rows = [list(r) for r in hp.read_table(E1_STATE.name.removesuffix(".html"), E1_STATE.read_bytes())]
    one = next(r for r in rows if len(r) > 3 and r[1] == "1.1")
    one[4] = "abc"
    df = hp.parse_e1(rows, "2014-15", None, "one_bad.xls")
    assert df.attrs["bad_cells"] == 1 and df.attrs["n_cells"] == len(df)
    clean = hp.parse_member(E1_STATE.name.removesuffix(".html"), E1_STATE.read_bytes(), "2014-15")
    assert clean.attrs["bad_cells"] == 0
    e3 = hp.parse_member(E3_STATE.name, E3_STATE.read_bytes(), "2020-21")
    assert e3.attrs["bad_cells"] == 0 and e3.attrs["n_cells"] == len(e3)


# ---- month-total check (spec §12.4) ----------------------------------------------------------------------
def total_rows(months, total, unit="District A", code="1.1"):
    return pd.DataFrame({"fy": "2014-15", "month": list(hd.FY_MONTHS)[:len(months)], "state_raw": "Test State",
                         "district_raw": unit, "is_state_aggregate": False, "item_code": code,
                         "type": "TOTAL", "value": [float(v) for v in months], "fy_total": float(total),
                         "source_file": "x.xls"})


def test_month_total_check_pass_and_fail_at_1pct():
    long = pd.concat([total_rows([10] * 12, 120, "D1"), total_rows([10] * 12, 121.2, "D2"),
                      total_rows([10] * 12, 122, "D3"), total_rows([10] * 12, 118.9, "D4")])
    out = hd.month_total_check(long).set_index("district_raw")
    assert out.loc["D1", "sum_months"] == 120 and out.loc["D1", "rel_diff"] == 0 and out.loc["D1", "pass"]
    assert out.loc["D2", "pass"]                                   # |120 - 121.2| / 121.2 = 0.0099
    assert not out.loc["D3", "pass"]                               # 0.0164
    assert out.loc["D4", "pass"]                                   # 0.0093
    assert out.loc["D3", "rel_diff"] == pytest.approx((120 - 122) / 122)


def test_month_total_check_columns_and_missing_cells():
    long = pd.concat([total_rows([np.nan] * 12, np.nan, "allNA"), total_rows([np.nan] * 12, 0, "NAzero"),
                      total_rows([5] + [np.nan] * 11, 5, "partly"), total_rows([5] * 12, np.nan, "noTotal"),
                      total_rows([0] * 12, 0, "zeros"), total_rows([0] * 11 + [3], 0, "zeroTotal")])
    out = hd.month_total_check(long)
    assert list(out.columns[:8]) == ["state_raw", "district_raw", "fy", "item_code", "sum_months", "fy_total",
                                     "rel_diff", "pass"]
    out = out.set_index("district_raw")
    assert out.loc["allNA", "pass"] and out.loc["NAzero", "pass"]  # nothing reported, nothing to check
    assert math.isnan(out.loc["allNA", "sum_months"])              # missing months stay missing, never 0
    assert out.loc["partly", "pass"] and out.loc["zeros", "pass"]
    assert not out.loc["noTotal", "pass"]                          # months reported, total missing
    assert not out.loc["zeroTotal", "pass"]                        # total 0, months sum to 3


def test_month_total_check_on_synthetic_workbooks_passes():
    for path, fy in ((E1_STATE, "2014-15"), (E2_HTML, "2019-20")):
        out = hd.month_total_check(hp.parse_member(path.name.removesuffix(".html"), path.read_bytes(), fy, fy_total=True))
        assert len(out) > 0 and out["pass"].all()


def test_month_total_check_needs_fy_total():
    with pytest.raises(KeyError, match="fy_total"):
        hd.month_total_check(hp.parse_member(E1_STATE.name.removesuffix(".html"), E1_STATE.read_bytes(), "2014-15"))


# ---- negative and nofile (spec §12.3) --------------------------------------------------------------------
def test_negative_monthly_value_nan_and_flagged():
    dm = hd.flag_negative(dm_rows([10, -3, 0, 12]))
    assert list(dm.negative) == [False, True, False, False]
    assert math.isnan(dm.value.iloc[1]) and dm.value.iloc[2] == 0 and dm.value.iloc[0] == 10


def test_nofile_for_listed_district_with_no_month_value():
    dm = pd.concat([dm_rows([10] * 12, "District A"), dm_rows([10, 11, np.nan] + [10] * 9, "District B")])
    out = hd.mark_nofile(dm, lists_of("Test State", "2014-15", ["District A", "District B", "District C"]))
    assert len(out) == 3 * 12                                      # District C (listed, no rows) gets 12 rows
    c = out[out.district_raw == "District C"]
    assert c.nofile.all() and c.value.isna().all() and (c.n_components == 1).all() and (c.n_present == 0).all()
    b = out[out.district_raw == "District B"].set_index("month")
    assert b.loc[6, "nofile"] and math.isnan(b.loc[6, "value"])
    assert not b.loc[5, "nofile"] and b.loc[5, "value"] == 11
    assert not out[out.district_raw == "District A"].nofile.any()


def test_nofile_keeps_reported_zero():
    out = hd.mark_nofile(dm_rows([0] * 12), lists_of("Test State", "2014-15", ["District A"]))
    assert not out.nofile.any() and (out.value == 0).all()


def test_mark_nofile_rejects_unlisted_district():
    with pytest.raises(ValueError, match="District Z"):
        hd.mark_nofile(dm_rows([1] * 12, "District Z"), lists_of("Test State", "2014-15", ["District A"]))


# ---- vintage_mixed per state-FY (spec §12.3: reported, not masked) ---------------------------------------
def test_vintage_mixed_per_state_fy():
    state = pd.DataFrame({"state_raw": ["S1", "S2", "S3", "S4"], "fy": "2014-15",
                          "status_date": [date(2016, 1, 29), date(2016, 2, 1), None, date(2016, 1, 29)]})
    ai = pd.DataFrame({"fy": ["2014-15"], "status_date": [date(2016, 1, 29)]})
    out = hd.vintage_mixed(state, ai).set_index("state_raw")
    assert list(out.columns) == ["fy", "status_date_state", "status_date_all_india", "vintage_mixed"]
    assert not out.loc["S1", "vintage_mixed"] and out.loc["S2", "vintage_mixed"]
    assert not out.loc["S3", "vintage_mixed"]                      # a missing date sets no flag
    assert out.loc["S2", "status_date_state"] == "2016-02-01"
    none = hd.vintage_mixed(state, pd.DataFrame({"fy": ["2014-15"], "status_date": [None]}))
    assert not none.vintage_mixed.any()


def test_vintage_mixed_when_state_month_files_disagree():
    # FY2020-21: one file per state and month, so a state-FY can carry several dates
    state = pd.DataFrame({"state_raw": ["S1", "S1"], "fy": "2020-21",
                          "status_date": [date(2024, 10, 1), date(2024, 11, 2)]})
    ai = pd.DataFrame({"fy": ["2020-21"], "status_date": [date(2024, 10, 1)]})
    out = hd.vintage_mixed(state, ai)
    assert len(out) == 1 and out.vintage_mixed.iloc[0]
    assert out.status_date_state.iloc[0] == "2024-10-01;2024-11-02"


# ---- non-state members (ruling F30) ----------------------------------------------------------------------
@pytest.mark.parametrize("name", ["M O Defence.xls", "2019-2020/M O Railways.xls", "M/O Defence",
                                  "m/o  railways", "M_O_Defence"])
def test_non_state_members_excluded_by_name(name):
    assert hd.is_non_state(name)


@pytest.mark.parametrize("name", ["Mizoram.xls", "Andhra Pradesh Old.xls", "Madhya Pradesh", "All_India.xls",
                                  "Meghalaya"])
def test_states_are_not_excluded(name):
    assert not hd.is_non_state(name)
