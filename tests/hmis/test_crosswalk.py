"""HMIS item crosswalk (Paper E, Task 2): code AND normalised text must match; sums keep missing as missing."""
import math
import re
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from pipeline import manifest as mf
from pipeline.hmis import crosswalk as cx
from pipeline.hmis import parse as hp

FIX = Path(__file__).resolve().parent / "fixtures"
E1_STATE = FIX / "e1_synthetic_state_1415.xls.html"
E2_HTML = FIX / "e2_synthetic_state_1920.xls.html"
E3_STATE = FIX / "e3_synthetic_state_2021_oct.xlsx"


def long_of(path, fy):
    return hp.parse_member(path.name.removesuffix(".html"), path.read_bytes(), fy)


@pytest.fixture(scope="module")
def xw():
    return cx.load_crosswalk()


def ind(out, indicator, unit, month, col="district_raw"):
    sel = out[(out.indicator == indicator) & (out[col] == unit) & (out.month == month)]
    assert len(sel) == 1
    return sel.iloc[0]


def test_load_crosswalk_rows(xw):
    assert list(xw.columns) == cx.XW_COLUMNS
    assert set(cx.PRIMARY5) <= set(cx.INDICATORS)
    assert sorted(zip(xw.indicator, xw.era)) == sorted((i, e) for i in cx.INDICATORS for e in ("E1", "E2", "E3"))
    assert set(xw["combine"]) <= {"single", "sum"}
    for r in xw.itertuples():
        assert (r.combine == "single") == (len(r.item_codes.split("|")) == 1)
        re.compile(r.text_pattern)
    pen = xw[(xw.indicator == "penta3") & (xw.era == "E1")].iloc[0]
    assert set(pen.item_codes.split("|")) == {"10.1.04C", "10.1.04"}    # Penta3 + DPT3 (E1)
    fic = xw[(xw.indicator == "fic") & (xw.era == "E2")].iloc[0]
    assert set(fic.item_codes.split("|")) == {"9.2.4.a", "9.2.4.b"}     # 9-11 months, male + female


def test_normalise_text():
    assert cx.normalise_text("  Childhood   Diseases – Diarrhoea ") == "childhood diseases-diarrhoea"
    assert cx.normalise_text("Measles & Rubella (MR)- 1st Dose") == "measles and rubella (mr)-1st dose"
    assert cx.normalise_text("A—B − C‐D") == "a-b-c-d"


def test_apply_crosswalk_e1_columns_and_sums(xw):
    long = long_of(E1_STATE, "2014-15")
    out = cx.apply_crosswalk(long, xw)
    assert list(out.columns) == cx.OUT_COLUMNS
    assert set(out.indicator) == set(cx.INDICATORS)
    assert len(out) == 2 * 12 * len(cx.INDICATORS)                       # one row per unit-month-indicator
    v = long.set_index(["district_raw", "item_code", "month", "type"]).value
    r = ind(out, "penta3", "District B", 8)
    assert r.value == v[("District B", "10.1.04C", 8, "TOTAL")] + v[("District B", "10.1.04", 8, "TOTAL")]
    assert (r.n_components, r.n_present) == (2, 2)
    assert ind(out, "anc_reg", "District A", 4).value == v[("District A", "1.1", 4, "TOTAL")]
    assert math.isnan(ind(out, "diarr_u5", "District B", 6).value)        # "NA" stays missing
    assert not out.cumulative.any() and set(out.source_file) == {E1_STATE.name.removesuffix(".html")}


def test_crosswalk_requires_code_and_text(xw):
    long = long_of(E1_STATE, "2014-15")
    long.loc[long.item_code == "1.1", "item_text"] = "Live births"
    with pytest.raises(cx.CrosswalkError, match=r"1\.1") as e:
        cx.apply_crosswalk(long, xw)
    assert E1_STATE.name.removesuffix(".html") in str(e.value)


def test_missing_item_raises_naming_file_and_code(xw):
    long = long_of(E1_STATE, "2014-15")
    long = long[long.item_code != "12.7"]
    with pytest.raises(cx.CrosswalkError, match=r"12\.7") as e:
        cx.apply_crosswalk(long, xw)
    assert E1_STATE.name.removesuffix(".html") in str(e.value)


def test_duplicated_code_type_raises(xw):
    long = long_of(E1_STATE, "2014-15")
    long = pd.concat([long, long[long.item_code == "2.2"].head(1)], ignore_index=True)
    with pytest.raises(cx.CrosswalkError, match=r"2\.2"):
        cx.apply_crosswalk(long, xw)


def test_text_match_tolerates_dash_and_case_variants(xw):
    pat = xw[(xw.indicator == "diarr_u5") & (xw.era == "E2")].text_pattern.iloc[0]
    for s in ("Childhood Diseases – Diarrhoea", "Childhood Diseases - Diarrhoea", "CHILDHOOD DISEASES-DIARRHOEA"):
        assert re.search(pat, cx.normalise_text(s)), s
    long = long_of(E2_HTML, "2019-20")
    long.loc[long.item_code == "10.11", "item_text"] = "CHILDHOOD DISEASES–DIARRHOEA"
    assert set(cx.apply_crosswalk(long, xw).indicator) == set(cx.INDICATORS)


def test_inst_del_e1_sum_min_count(xw):
    long = long_of(E1_STATE, "2014-15")
    a = long.district_raw == "District A"
    long.loc[a & (long.item_code == "2.2") & (long.month == 4), "value"] = 10
    long.loc[a & (long.item_code == "2.3") & (long.month == 4), "value"] = np.nan
    long.loc[a & long.item_code.isin(["2.2", "2.3"]) & (long.month == 5), "value"] = np.nan
    out = cx.apply_crosswalk(long, xw)
    r = ind(out, "inst_del", "District A", 4)
    assert (r.value, r.n_components, r.n_present) == (10, 2, 1)
    r = ind(out, "inst_del", "District A", 5)
    assert math.isnan(r.value) and r.n_present == 0


def test_mcv1_zero_in_922_is_real(xw):
    out = cx.apply_crosswalk(long_of(E2_HTML, "2019-20"), xw)      # fixture: 9.2.1 = 50, 9.2.2 = 0
    r = ind(out, "mcv1", "District A", 4)
    assert (r.value, r.n_present) == (50, 2)


def test_e3_aggregate_rows_survive_crosswalk(xw):
    out = cx.apply_crosswalk(long_of(E3_STATE, "2020-21"), xw)
    agg = out[out.is_state_aggregate]
    assert len(agg) == len(cx.INDICATORS) and set(agg.state_raw) == {"Test State"}
    assert ind(out, "anc_reg", "", 10).value == 777


def test_empty_long_gives_empty_frame(xw):
    out = cx.apply_crosswalk(pd.DataFrame(columns=hp.LONG_COLUMNS), xw)
    assert out.empty and list(out.columns) == cx.OUT_COLUMNS


def test_crosswalk_rows_verified_in_manifest(xw):
    assert cx.verify_crosswalk(xw, mf.read()) == []


def test_verify_crosswalk_reports_unlisted_and_empty(xw):
    bad = xw.copy()
    bad.loc[0, "verified_in_file"] = "data/raw/hmis/nowhere.zip::x.xls"
    bad.loc[1, "verified_in_file"] = ""
    problems = cx.verify_crosswalk(bad, mf.read())
    assert len(problems) == 2
    assert any("nowhere.zip" in p for p in problems)
