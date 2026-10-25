"""District flags, completeness and the flags step (Paper E, Task 3; spec §3.6, §12; rulings F10, F11, F29-F32).
Fixtures are synthetic (ruling F1); every file the tests write goes to tmp_path (ruling F9)."""
import importlib.util
import math
import zipfile
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from pipeline.hmis import crosswalk as cx
from pipeline.hmis import difference as hd
from pipeline.hmis import flags as hf
from pipeline.hmis import parse as hp
from pipeline.hmis import run

FIX = Path(__file__).resolve().parent / "fixtures"
E1_STATE = FIX / "e1_synthetic_state_1415.xls.html"
E2_HTML = FIX / "e2_synthetic_state_1920.xls.html"
E3_STATE = FIX / "e3_synthetic_state_2021_oct.xlsx"
E3_ALLINDIA = FIX / "e3_synthetic_allindia_2021_apr.xlsx"


@pytest.fixture(scope="module")
def xw():
    return cx.load_crosswalk()


def _make_fixtures():
    spec = importlib.util.spec_from_file_location("hmis_make_fixtures", FIX / "make_fixtures.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def dm_rows(values, district="District A", indicator="anc_reg", state="Test State", fy="2014-15",
            n_components=1):
    vals = [float(v) for v in values]
    return pd.DataFrame({"fy": fy, "month": list(hd.FY_MONTHS)[:len(vals)], "state_raw": state,
                         "district_raw": district, "indicator": indicator, "value": vals,
                         "n_components": n_components, "n_present": [0 if math.isnan(v) else n_components
                                                                     for v in vals],
                         "partial_component": False, "status_date": date(2016, 1, 29), "source_file": "x.xls"})


def flagged(values, **kw):
    dm = dm_rows(values, **kw)
    return hf.flag_all(dm, pd.DataFrame({"state_raw": dm.state_raw.iloc[0], "fy": dm.fy.iloc[0],
                                         "district_raw": [dm.district_raw.iloc[0]]}))


def by_month(df):
    return df.set_index("month")


# ---- nonreport and catchup (spec §3.6) -------------------------------------------------------------------
def test_thresholds():
    assert hf.NONREPORT_MIN_MEDIAN == 20 and hf.CATCHUP_FACTOR == 3


def test_nonreport_threshold_median_20():
    out = by_month(flagged([0] + [20] * 11))                       # median 20 -> the zero is a non-report
    assert out.loc[4, "nonreport"] and math.isnan(out.loc[4, "value"]) and not out.loc[4, "valid"]
    assert out.loc[4, "value_raw"] == 0
    out = by_month(flagged([0] + [19] * 11))                       # median 19 -> a real zero
    assert not out.loc[4, "nonreport"] and out.loc[4, "value"] == 0 and out.loc[4, "valid"]


def test_catchup_after_nonreport_only():
    out = by_month(flagged([20, 0, 61] + [20] * 9))                # 3 x median + 1 after a non-report
    assert out.loc[5, "nonreport"] and out.loc[6, "catchup"] and math.isnan(out.loc[6, "value"])
    out = by_month(flagged([20, 0, 60] + [20] * 9))                # exactly 3 x median: not a catch-up
    assert out.loc[5, "nonreport"] and not out.loc[6, "catchup"] and out.loc[6, "value"] == 60
    out = by_month(flagged([20, 20, 61] + [20] * 9))               # after a valid month: not a catch-up
    assert not out.catchup.any() and out.loc[6, "value"] == 61


def test_catchup_never_crosses_fiscal_years():
    a = dm_rows([20] * 11 + [0], fy="2014-15")                     # March 2015 non-report
    b = dm_rows([61] + [20] * 11, fy="2015-16")                    # April 2015 large: different FY
    lists = pd.DataFrame({"state_raw": "Test State", "fy": ["2014-15", "2015-16"],
                          "district_raw": "District A"})
    out = hf.flag_all(pd.concat([a, b], ignore_index=True), lists)
    assert out[(out.fy == "2014-15") & (out.month == 3)].nonreport.all()
    assert not out[out.fy == "2015-16"].catchup.any()


def test_median_ignores_negative_and_nofile_months():
    # 6 missing (nofile) and 2 negative months; the 4 reported months 0, 30, 30, 30 have median 30
    out = by_month(flagged([np.nan] * 6 + [-5, -5, 0, 30, 30, 30]))
    assert out.nofile.sum() == 6 and out.negative.sum() == 2
    assert out.loc[12, "nonreport"]                                 # December: zero, median 30 (15 with negatives)


def test_any_flag_makes_value_nan_and_invalid():
    out = flagged([np.nan, -1, 0, 61] + [20] * 8)
    flags = out[["negative", "nofile", "nonreport", "catchup"]].any(axis=1)
    assert out.loc[flags, "value"].isna().all() and not out.loc[flags, "valid"].any()
    assert out.loc[~flags, "valid"].all() and out.loc[~flags, "value"].notna().all()
    assert list(out.columns) == hf.DM_COLUMNS


# ---- district lists and completeness (F10, F11) ----------------------------------------------------------
def test_state_aggregate_is_not_a_district():
    long = hp.parse_member(E3_STATE.name, E3_STATE.read_bytes(), "2020-21")    # group 1 = the state itself
    lists = hf.district_lists(long)
    assert list(lists.columns) == ["state_raw", "fy", "district_raw"]
    assert set(lists.district_raw) == {"District A", "District B"}             # never "" (the state column)
    agg = cx.apply_crosswalk(long, cx.load_crosswalk())
    dm = agg[~agg.is_state_aggregate].assign(partial_component=False)
    comp = hf.completeness(hf.flag_all(dm, lists), lists)
    assert (comp[comp.month == 10].n_districts == 2).all()


def test_completeness_uses_listed_districts():
    names = [f"District {k}" for k in range(10)]
    dm = pd.concat([dm_rows([30] * 12, d) for d in names[:9]]
                   + [dm_rows([30] * 3 + [np.nan] + [30] * 8, names[9])], ignore_index=True)
    lists = pd.DataFrame({"state_raw": "Test State", "fy": "2014-15", "district_raw": names})
    comp = hf.completeness(hf.flag_all(dm, lists), lists)
    assert list(comp.columns) == hf.COMP_COLUMNS
    jul = comp[(comp.month == 7) & (comp.indicator == "anc_reg")].iloc[0]
    assert (jul.n_districts, jul.n_valid, jul.comp) == (10, 9, 0.9)
    assert comp[comp.month != 7].comp.eq(1.0).all()


def test_completeness_counts_listed_district_with_no_rows():
    lists = pd.DataFrame({"state_raw": "Test State", "fy": "2014-15", "district_raw": ["District A", "District B"]})
    comp = hf.completeness(hf.flag_all(dm_rows([30] * 12), lists), lists)
    assert (comp.n_districts == 2).all() and (comp.comp == 0.5).all()


def test_completeness_all_components_sensitivity():
    a = dm_rows([30] * 12, "District A", "inst_del", n_components=2)
    a.loc[a.month == 4, "n_present"] = 1                            # one of two components present in April
    b = dm_rows([30] * 12, "District B", "inst_del", n_components=2)
    lists = pd.DataFrame({"state_raw": "Test State", "fy": "2014-15", "district_raw": ["District A", "District B"]})
    comp = hf.completeness(hf.flag_all(pd.concat([a, b], ignore_index=True), lists), lists).set_index("month")
    assert comp.loc[4, "comp"] == 1.0 and comp.loc[4, "comp_full"] == 0.5 and comp.loc[4, "n_valid_full"] == 1
    assert comp.loc[5, "comp_full"] == 1.0


def test_neg_share():
    lists = pd.DataFrame({"state_raw": "Test State", "fy": "2014-15", "district_raw": ["District A"]})
    out = hf.neg_share(hf.flag_all(dm_rows([-1, 5, np.nan] + [5] * 9), lists))
    assert list(out.columns) == ["indicator", "n", "n_negative", "share"]
    r = out.iloc[0]
    assert (r.indicator, r.n, r.n_negative) == ("anc_reg", 11, 1) and r.share == pytest.approx(1 / 11)


# ---- partial sums (F32) ----------------------------------------------------------------------------------
def test_partial_component_needs_missing_component_nonzero_elsewhere(xw):
    long = hp.parse_member(E2_HTML.name.removesuffix(".html"), E2_HTML.read_bytes(), "2019-20")
    a, b = long.district_raw == "District A", long.district_raw == "District B"
    long.loc[a & (long.item_code == "9.2.4.b") & (long.month == 5), "value"] = np.nan    # non-zero elsewhere
    long.loc[b & (long.item_code == "9.2.4.b"), "value"] = 0.0
    long.loc[b & (long.item_code == "9.2.4.b") & (long.month == 6), "value"] = np.nan    # zero elsewhere
    long.loc[b & long.item_code.isin(["9.2.4.a", "9.2.4.b"]) & (long.month == 7), "value"] = np.nan   # both
    out = hf.partial_component(long, xw)
    assert list(out.columns) == ["fy", "month", "state_raw", "district_raw", "is_state_aggregate", "indicator",
                                 "partial_component"]
    p = out.set_index(["district_raw", "indicator", "month"]).partial_component
    assert p[("District A", "fic", 5)] and p.sum() == 1
    assert not p[("District B", "fic", 6)] and not p[("District B", "fic", 7)]
    assert not p[("District A", "anc_reg", 5)]                      # single-item indicators are never partial


# ---- the flags step on a synthetic zip and synthetic FY2020-21 folders (tmp_path only) -------------------
def _synthetic_root(tmp_path):
    mk = _make_fixtures()
    root = tmp_path / "hmis"
    zdir = root / run.FOLDER3
    zdir.mkdir(parents=True)
    all_india = mk.sas_html("ai", "State", "All India", "2014-2015", "29 Jan 2016, 2:00 PM",
                            ["Test State", "M/O Defence"], mk.E1_ITEMS, splits=False)
    other = mk.sas_html("ai", "State", "All India", "2014-2015", "30 Jan 2016, 2:00 PM",
                        ["Other State"], mk.E1_ITEMS, splits=False)
    other_state = mk.sas_html("os", "District", "Other State", "2014-2015", "30 Jan 2016, 2:00 PM",
                              ["District X"], mk.E1_ITEMS, splits=False)
    with zipfile.ZipFile(zdir / "2014-2015.zip", "w") as z:
        z.writestr("2014-2015/All_India.xls", all_india)
        z.writestr("2014-2015/Test State.xls", E1_STATE.read_bytes())
        z.writestr("2014-2015/M O Railways.xls", b"<html><h1>Data ItemWise Report for - M/O Railways</h1></html>")
    with zipfile.ZipFile(zdir / "2015-2016.zip", "w") as z:     # wrong FY titles: every member is an error
        z.writestr("2015-2016/Other State.xls", other_state)
        z.writestr("2015-2016/All_India.xls", other)
    d2, d1 = root / run.FOLDER2_FY2021, root / run.FOLDER1_FY2021
    d2.mkdir()
    d1.mkdir()
    (d2 / "Test_State__J-Test_State_Oct.xlsx").write_bytes(E3_STATE.read_bytes())
    (d1 / "A-Apr.xlsx").write_bytes(E3_ALLINDIA.read_bytes())
    return root


def test_flags_fy_zip_excludes_mo_and_splits_state_rows(tmp_path, xw):
    root = _synthetic_root(tmp_path)
    res = run.flags_fy_zip(root / run.FOLDER3 / "2014-2015.zip", "2014-15", xw)
    mem = res["members"].set_index("member")
    assert mem.loc["2014-2015/M O Railways.xls", "status"] == "excluded"
    assert mem.loc["2014-2015/All_India.xls", "status"] == "parsed"
    assert mem.loc["2014-2015/All_India.xls", "excluded_units"] == 1             # the M/O Defence state row
    assert (mem.loc[mem.status == "parsed", "bad_cells"] == 0).all()
    st = res["state_month"]
    assert list(st.columns) == hf.STATE_COLUMNS
    assert set(st.state_raw) == {"Test State"} and len(st) == 12 * len(cx.INDICATORS)
    dm = res["district_month"]
    assert list(dm.columns) == hf.DM_COLUMNS
    assert set(dm.district_raw) == {"District A", "District B"} and len(dm) == 2 * 12 * len(cx.INDICATORS)
    nb = dm[(dm.district_raw == "District B") & (dm.indicator == "diarr_u5") & dm.month.isin([6, 7])]
    assert nb.nofile.all() and nb.value.isna().all()                # "NA" and blank cells: nofile, never 0
    comp = res["completeness"]
    assert list(comp.columns) == hf.COMP_COLUMNS and (comp.n_districts == 2).all()
    assert list(res["vintage"].columns) == hf.VINTAGE_COLUMNS and not res["vintage"].vintage_mixed.any()
    chk = res["month_total_check"]
    assert list(chk.columns) == hd.CHECK_COLUMNS and chk["pass"].all()
    assert set(chk.item_code) <= set("|".join(xw[xw.era == "E1"].item_codes).split("|"))
    assert chk.is_state_aggregate.any() and (~chk.is_state_aggregate).any()


def test_flags_fy2021_uses_first_column_group(tmp_path, xw):
    root = _synthetic_root(tmp_path)
    res = run.flags_fy2021(root / run.FOLDER2_FY2021, root / run.FOLDER1_FY2021, xw)
    st = res["state_month"]
    assert set(st.state_raw) == {"Test State"} and set(st.month) == {10}
    assert st[st.indicator == "anc_reg"].value.iloc[0] == 777
    dm = res["district_month"]
    assert set(dm.district_raw) == {"District A", "District B"} and len(dm) == 2 * 12 * len(cx.INDICATORS)
    assert dm[dm.month != 10].nofile.all()                          # no file for those months
    assert res["month_total_check"].empty                           # one month per file: no FY total
    v = res["vintage"].iloc[0]
    assert v.status_date_state == "2024-10-01" and v.status_date_all_india == "2024-10-01"


def test_flags_step_writes_parts_and_tracked_report_only_where_told(tmp_path, xw):
    root = _synthetic_root(tmp_path)
    parts, report = tmp_path / "_parts", tmp_path / "differencing_report.csv"
    out = run.flags(out_dir=parts, report_path=report, root=root, fys=["2014-15", "2015-16", "2020-21"],
                    discovery={"upload_status": [{"name": "Data Reporting Status", "anonymous": False}]})
    for name in ("district_month", "state_month", "completeness", "month_total_check", "vintage", "members"):
        assert (parts / f"{name}.csv.gz").exists(), name
    rep = pd.read_csv(report)
    assert list(rep.columns) == hf.REPORT_COLUMNS
    assert set(rep.fy) == {"2014-15", "2015-16", "2020-21"} and len(rep) == 3 * len(cx.INDICATORS)
    bad = rep[rep.fy == "2015-16"]
    assert (bad.n_district_months == 0).all() and bad.share_flagged.isna().all()
    assert bad.notes.str.contains("2 member errors").all()
    assert "district_raw" not in rep.columns and "state_raw" not in rep.columns
    r = rep[(rep.fy == "2014-15") & (rep.indicator == "diarr_u5")].iloc[0]
    assert r.n_district_months == 24 and r.nofile == 2 and r.share_flagged == pytest.approx(2 / 24, abs=1e-6)
    assert r.month_total_fail == 0 and r.month_total_checked == 3          # 2 districts + 1 state row
    assert "M O Railways" in r.notes and "skipped" in r.notes
    mem = pd.read_csv(parts / "members.csv.gz")
    assert (mem[mem.fy == "2015-16"].status == "error").all()
    assert out["errors"] == 2


def test_report_counts_vintage_and_partial_components(xw):
    dm = pd.concat([dm_rows([30] * 12, "District A", state="S1"), dm_rows([30] * 12, "District B", state="S2")],
                   ignore_index=True)
    lists = dm[["state_raw", "fy", "district_raw"]].drop_duplicates()
    dm = hf.flag_all(dm, lists)
    st = dm_rows([300] * 12, "", state="S1").drop(columns="district_raw")
    st.loc[st.month == 4, "partial_component"] = True
    vint = pd.DataFrame({"state_raw": ["S1", "S2"], "fy": "2014-15", "status_date_state": ["a", "b"],
                         "status_date_all_india": "a", "vintage_mixed": [False, True]})
    rep = hf.flag_report(dm, st[hf.STATE_COLUMNS], pd.DataFrame(columns=hd.CHECK_COLUMNS), vint, xw,
                         {"2014-15": "note"})
    r = rep.set_index("indicator").loc["anc_reg"]
    assert r.vintage_mixed == 12 and r.vintage_mixed_state_fys == 1 and r.share_flagged == 0
    assert r.state_months == 12 and r.partial_component == pytest.approx(1 / 12)
    assert r.notes == "note"
