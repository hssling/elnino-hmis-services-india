"""HMIS gates and reviewed dispositions (Paper E, Task 4; spec §3.5, §3.6, §10.2; rulings F32, F37, F39).
Fixtures are synthetic (ruling F1); every file the tests write goes to tmp_path (ruling F9)."""
import math
import zipfile

import numpy as np
import pandas as pd
import pytest

from pipeline.hmis import gates as hg
from pipeline.hmis import panel as hpn
from pipeline.hmis import run
from pipeline.hmis.crosswalk import INDICATORS, PRIMARY5
from pipeline.hmis.difference import FY_MONTHS
from pipeline.validate import GateResult

from tests.hmis.test_panel import across_states_html, cat, cell, crows, drows, srows


def long(values, unit="KL", fy="2014-15", indicator="anc_reg", months=FY_MONTHS):
    vals = [float(v) for v in values]
    return pd.DataFrame({"unit_id": unit, "fy": fy, "month": list(months)[:len(vals)], "indicator": indicator,
                         "value": vals})


def lk(df, **kw):
    for k, v in kw.items():
        df = df[df[k] == v]
    return df


# ---- district-sum gate (spec §3.5, §12.2) ---------------------------------------------------------------------
def test_district_sum_gate_tolerances_on_full_months_only():
    raw = long([1000, 1000, 50, 50, 1000])
    dsum = long([1019, 1021, 55, 56, 1500]).rename(columns={"value": "dsum"})
    comp = long([1.0, 1.0, 1.0, 1.0, 0.95]).rename(columns={"value": "comp"})
    fails, res = hg.gate_district_sum(raw, dsum, comp)
    assert isinstance(res, GateResult) and not res.passed
    assert sorted(fails.month) == [5, 7]                                    # 1000 vs 1021 and 50 vs 56
    assert set(fails.check) == {"district_sum"} and list(fails.columns) == hg.FAIL_COLUMNS
    assert "tested 4" in res.detail


# ---- negative values ---------------------------------------------------------------------------------------
def test_negative_share_above_1pct_masks_affected_state_months():
    def dm(n_neg, n=200):
        d = cat(*[drows("Kerala", "2014-15", [10] * 12, district=f"D{k}",
                        negative=[k < n_neg and m == 0 for m in range(12)]) for k in range(n // 12 + 1)])
        d["unit_id"] = "KL"
        return d
    low, res_low = hg.gate_negative_share(dm(1))                             # 1 of 204 < 1%
    assert low.empty and res_low.passed
    high, res_high = hg.gate_negative_share(dm(3))                           # 3 of 204 > 1%
    assert len(high) == 1 and high.iloc[0].month == 4 and high.iloc[0].unit_id == "KL"
    assert not res_high.passed


def test_negative_state_value_fails():
    fails, res = hg.gate_negative_state(long([5, -1, 0]))
    assert list(fails.month) == [5] and not res.passed


# ---- plausibility (spec §3.6, §10.2, ruling F41) --------------------------------------------------------------
E1_FYS = [f"{y}-{(y + 1) % 100:02d}" for y in range(2012, 2017)]
E2_FYS = ["2017-18", "2018-19", "2019-20"]


def test_plausibility_band_calendar_month_median_within_era():
    april = [100, 100, 301, 32, 100]                                         # E1 median 100: 3.01x high, 0.32x low
    raw = cat(*[long([a] + [100] * 11, fy=fy) for fy, a in zip(E1_FYS, april)],
              *[long([19] * 12, unit="GA", fy=fy) for fy in E1_FYS[:3]],
              *[long([60] * 12, unit="GA", fy=fy) for fy in E1_FYS[3:]],   # median 19: exempt
              *[long([300] + [100] * 11, fy=fy) for fy in E2_FYS])           # exactly 3x the E1 level: own era
    fails, res = hg.gate_plausibility(raw)
    got = sorted(zip(fails.unit_id, fails.fy, fails.month, fails["default"]))
    assert got == [("KL", "2014-15", 4, "mask"), ("KL", "2015-16", 4, "keep")]
    low = fails[fails["default"] == "keep"].iloc[0]
    assert low.rule.startswith("default_keep_low") and low.check == "plausibility"
    assert not res.passed and "1 high masked" in res.detail and "1 low kept" in res.detail


def test_plausibility_level_drop_at_2017_is_not_masked():
    """Bihar-like: diarr_u5 about 40,000 a month in E1 and about 7,000 in E2 (the 2017 item change)."""
    raw = cat(*[long([40000 + 500 * k] * 12, unit="BR", fy=fy, indicator="diarr_u5") for k, fy in enumerate(E1_FYS)],
              *[long([7000 + 100 * k] * 12, unit="BR", fy=fy, indicator="diarr_u5") for k, fy in enumerate(E2_FYS)])
    fails, res = hg.gate_plausibility(raw)
    assert fails.empty and res.passed


def test_plausibility_fy2021_compared_with_e2():
    raw = cat(*[long([1000] * 12, fy=fy) for fy in E1_FYS], *[long([100] * 12, fy=fy) for fy in E2_FYS],
              long([20, 350] + [100] * 10, fy="2020-21"))
    fails, _ = hg.gate_plausibility(raw)
    assert sorted(zip(fails.fy, fails.month, fails["default"])) == [("2020-21", 4, "keep"), ("2020-21", 5, "mask")]


def _fy_level_case(target):
    """KL penta3 at 1000 a month in four E1 FYs and `target` (12 values) in FY2012-13 (ruling F42)."""
    return cat(long(target, fy="2012-13", indicator="penta3"),
               *[long([1000] * 12, fy=fy, indicator="penta3") for fy in E1_FYS[1:]])


def test_fy_level_low_is_masked_with_its_own_rule():
    fails, res = hg.gate_plausibility(_fy_level_case([40] * 12))             # all 12 months at 0.04x
    f = fails[fails.fy == "2012-13"]
    assert len(f) == 12 and (f["default"] == "mask").all()
    assert f.rule.str.startswith("default_mask_fy_level").all()
    assert all("value=40 median=1000" in e for e in f.evidence)
    assert "12 FY-level low masked" in res.detail


def test_partial_fy_lows_stay_default_keep_low():
    nine_low = hg.gate_plausibility(_fy_level_case([40] * 9 + [1000] * 3))[0]
    assert len(nine_low) == 9 and (nine_low["default"] == "keep").all()
    assert nine_low.rule.str.startswith("default_keep_low").all()
    nine_available = hg.gate_plausibility(_fy_level_case([40] * 9 + [np.nan] * 3))[0]
    assert len(nine_available) == 9 and (nine_available["default"] == "keep").all()


def test_gate_evidence_belongs_to_its_own_row():
    """Failing cells arrive in non-sorted order (UP before BR); each row's evidence names its own value."""
    raw = cat(*[long([1000] * 12, unit="UP", fy=fy) for fy in E1_FYS[:4]], long([9999] + [1000] * 11, unit="UP",
                                                                                fy=E1_FYS[4]),
              *[long([100] * 12, unit="BR", fy=fy) for fy in E1_FYS[:4]], long([555] + [100] * 11, unit="BR",
                                                                              fy=E1_FYS[4]))
    fails, _ = hg.gate_plausibility(raw)
    ev = dict(zip(fails.unit_id, fails.evidence))
    assert "value=9999 median=1000" in ev["UP"] and "value=555 median=100" in ev["BR"]
    st = cat(long([100] * 12, unit="UP", indicator="opd"), long([100] * 12, unit="BR", indicator="inst_del"))
    st["partial_component"] = [k < 6 for k in range(12)] + [k < 1 for k in range(12)]
    st.loc[st.unit_id == "BR", "fy"] = "2013-14"
    pf, _ = hg.gate_partial_component(st)
    for r in pf.itertuples():
        want = "0.500" if r.unit_id == "UP" else "0.083"
        assert want in r.evidence, (r.unit_id, r.evidence)


# ---- national gate (ruling F39) ----------------------------------------------------------------------------
def national(rows):
    return pd.DataFrame(rows, columns=["fy", "month", "indicator", "national"])


def all_units(values, **kw):
    from pipeline.outcomes import states
    return cat(*[long(values, unit=u, **kw) for u in states.UNITS])


def test_national_gate_masks_indicator_month_for_all_units():
    raw = all_units([500 / 34] * 3)
    nat = national([("2014-15", 4, "anc_reg", 504.0), ("2014-15", 5, "anc_reg", 510.0),
                    ("2014-15", 6, "anc_reg", np.nan)])
    fails, res = hg.gate_national(raw, nat)
    assert list(fails.month) == [5] and set(fails.unit_id) == {"ALL"}
    assert "not available" in res.detail
    cmp = hg.national_comparison(raw, nat)
    assert lk(cmp, month=6).status.iloc[0] == "not available"
    assert lk(cmp, month=4).status.iloc[0] == "pass"
    panel = raw.assign(flag="")
    masked, log = hg.apply_dispositions(panel, fails, hg.empty_reviewed())
    may = masked[masked.month == 5]
    assert may.value.isna().all() and len(may) == 34
    assert masked[masked.month != 5].value.notna().all()
    assert (log.unit_id == "ALL").all() and (log.disposition == "mask").all()


def test_national_gate_needs_all_34_units():
    raw = all_units([10.0] * 2)
    raw.loc[(raw.unit_id == "GA") & (raw.month == 4), "value"] = np.nan        # one unit missing in April
    nat = national([("2014-15", 4, "anc_reg", 340.0), ("2014-15", 5, "anc_reg", 340.0)])
    fails, res = hg.gate_national(raw, nat)
    assert fails.empty and "not evaluable" in res.detail
    cmp = hg.national_comparison(raw, nat)
    assert lk(cmp, month=4).status.iloc[0] == "not evaluable" and lk(cmp, month=5).status.iloc[0] == "pass"


# ---- partial components (rulings F32, F37) -----------------------------------------------------------------
def test_partial_component_rule_masks_additive_sums_only():
    def st(ind, n_partial):
        s = long([100] * 12, indicator=ind)
        s["partial_component"] = [k < n_partial for k in range(12)]
        return s
    fails, res = hg.gate_partial_component(cat(st("inst_del", 1), st("opd", 0), st("fic", 0)))
    assert len(fails) == 1 and fails.iloc[0].indicator == "inst_del"           # 1/12 > 5%
    exempt, _ = hg.gate_partial_component(cat(st("penta3", 6), st("mcv1", 6)))
    assert exempt.empty
    shares = hg.partial_shares(cat(st("penta3", 6), st("inst_del", 0)))
    assert lk(shares, indicator="penta3").share.iloc[0] == pytest.approx(0.5)


# ---- dispositions -------------------------------------------------------------------------------------------
def fail_row(month=4, unit="KL", check="plausibility", indicator="anc_reg", fy="2014-15"):
    return pd.DataFrame([{"indicator": indicator, "unit_id": unit, "fy": fy, "month": month, "check": check,
                          "rule": hg.RULES[check], "evidence": "value=1 median=100",
                          "default": "mask"}])[hg.FAIL_COLUMNS]


def test_default_disposition_is_mask_logged_with_rule():
    panel = long([1, 100, 100]).assign(flag="")
    masked, log = hg.apply_dispositions(panel, fail_row(), hg.empty_reviewed())
    assert math.isnan(lk(masked, month=4).value.iloc[0]) and lk(masked, month=4)["flag"].iloc[0] == "plausibility"
    assert list(log.columns) == hg.REVIEWED_COLUMNS
    assert log.iloc[0].disposition == "mask" and log.iloc[0].rule == hg.RULES["plausibility"]


def test_reviewed_keep_overrides_default_mask(tmp_path):
    rev = pd.DataFrame([{"indicator": "anc_reg", "unit_id": "KL", "fy": "2014-15", "month": 4,
                         "check": "plausibility", "disposition": "keep", "rule": "reviewed: author",
                         "reason": "campaign month", "evidence": "state press release"}])
    path = tmp_path / "hmis_reviewed.csv"
    rev.to_csv(path, index=False)
    reviewed = hg.read_reviewed(path)
    panel = long([1, 100, 100]).assign(flag="")
    kept, log = hg.apply_dispositions(panel, fail_row(), reviewed)
    assert lk(kept, month=4).value.iloc[0] == 1 and lk(kept, month=4)["flag"].iloc[0] == "keep:plausibility"
    assert log.iloc[0].disposition == "keep" and log.iloc[0].reason == "campaign month"
    other, _ = hg.apply_dispositions(panel, fail_row(check="district_sum"), reviewed)   # other check: masked
    assert math.isnan(lk(other, month=4).value.iloc[0])


def test_read_reviewed_validates(tmp_path):
    bad = tmp_path / "bad.csv"
    pd.DataFrame([{"indicator": "anc_reg", "unit_id": "KL", "fy": "2014-15", "month": 4, "check": "vibes",
                   "disposition": "keep", "rule": "reviewed: x", "reason": "r", "evidence": "e"}]).to_csv(bad,
                                                                                                  index=False)
    with pytest.raises(ValueError, match="vibes"):
        hg.read_reviewed(bad)
    assert hg.read_reviewed(tmp_path / "absent.csv").empty


def test_default_keep_low_rows_are_accepted_and_honoured(tmp_path):
    low = fail_row(month=4).assign(rule=hg.RULES["plausibility_low"], default="keep")
    panel = long([1, 100, 100]).assign(flag="")
    kept, log = hg.apply_dispositions(panel, low, hg.empty_reviewed())
    assert lk(kept, month=4).value.iloc[0] == 1 and lk(kept, month=4)["flag"].iloc[0] == hg.LOW_TOKEN
    assert log.iloc[0].disposition == "keep" and log.iloc[0].rule.startswith("default_keep_low")
    path = tmp_path / "hmis_reviewed.csv"
    hg.write_reviewed(log, path)
    back = hg.read_reviewed(path)                                             # accepted on the next build
    assert back.iloc[0].disposition == "keep" and hg.manual_rows(back).empty
    bad = back.assign(rule="whatever")
    bad.to_csv(path, index=False)
    with pytest.raises(ValueError, match="keep row"):
        hg.read_reviewed(path)


def test_write_reviewed_keeps_manual_rows_and_regenerates_defaults(tmp_path):
    path = tmp_path / "hmis_reviewed.csv"
    manual = pd.DataFrame([{"indicator": "anc_reg", "unit_id": "KL", "fy": "2014-15", "month": 4,
                            "check": "plausibility", "disposition": "keep", "rule": "reviewed: author",
                            "reason": "r", "evidence": "e"}])
    panel = long([1, 1, 100]).assign(flag="")
    _, log = hg.apply_dispositions(panel, cat(fail_row(4), fail_row(5)), manual)
    hg.write_reviewed(log, path)
    back = hg.read_reviewed(path)
    assert len(back) == 2 and set(back.disposition) == {"keep", "mask"}
    assert len(hg.manual_rows(back)) == 1


# ---- dropped indicators and the halt rules (spec §10.2) ------------------------------------------------------
def wide(fys=("2014-15",), masked=None, final=None, units=("KL", "GA")):
    """A small wide panel: every indicator present (value 100), with `masked` {indicator: share of cells
    masked} and `final` {fy: NaN for every PRIMARY5 final value}."""
    rows = []
    for fy in fys:
        for u in units:
            for m in FY_MONTHS:
                rows.append({"unit_id": u, "fy": fy, "month": m})
    p = pd.DataFrame(rows)
    for ind in INDICATORS:
        p[ind] = 100.0
        p[f"{ind}_raw"] = 100.0
        p[f"flag_{ind}"] = ""
    for ind, share in (masked or {}).items():
        k = int(round(share * len(p)))
        p.loc[p.index[:k], [ind, f"{ind}_raw"]] = np.nan
        p.loc[p.index[:k], f"flag_{ind}"] = "plausibility"
    for fy in (final or []):
        p.loc[p.fy == fy, list(PRIMARY5)] = np.nan
    return p


def test_indicator_dropped_above_20pct_masked():
    p = wide(masked={"opd": 0.25, "anc_reg": 0.125})
    assert hg.dropped_indicators(p) == ["opd"]
    share = hg.masked_share(p)
    assert share["opd"] == pytest.approx(0.25) and share["anc_reg"] == pytest.approx(0.125)


def test_halt_two_primary_indicators_dropped():
    p = wide(masked={"opd": 0.25, "anc_reg": 0.5})
    dropped = hg.dropped_indicators(p)
    with pytest.raises(hg.PanelHalt, match="anc_reg.*opd|opd.*anc_reg"):
        hg.check_halt(dropped, p)
    assert hpn.PanelHalt is hg.PanelHalt
    assert hg.check_halt(hg.dropped_indicators(wide(masked={"opd": 0.25, "fic": 0.9})), p) == []


def test_halt_two_fys_unusable_but_not_one():
    fys = ("2012-13", "2013-14", "2014-15")
    one = wide(fys=fys, final=["2013-14"])
    assert hg.check_halt([], one) == ["2013-14"]
    two = wide(fys=fys, final=["2012-13", "2013-14"])
    with pytest.raises(hg.PanelHalt, match="2012-13.*2013-14"):
        hg.check_halt([], two)
    covid = wide(fys=fys + ("2020-21",), final=["2020-21"])                  # outside the primary window
    assert hg.check_halt([], covid) == []


def test_assemble_masks_one_unusable_fy_and_reports_it():
    st = cat(*[srows("Kerala", fy, [1000] * 12, indicator=i) for fy in ("2013-14", "2014-15") for i in PRIMARY5])
    comp = cat(*[crows("Kerala", fy, 1.0 if fy == "2014-15" else 0.5, indicator=i)
                 for fy in ("2013-14", "2014-15") for i in PRIMARY5])
    dm = cat(*[drows("Kerala", fy, [1000] * 12, indicator=i) for fy in ("2013-14", "2014-15") for i in PRIMARY5])
    out = hpn.assemble(st, comp, dm, fys=["2013-14", "2014-15"])
    assert out["unusable"] == ["2013-14"] and out["halt"] is None
    assert "fy_unusable" in cell(out["panel"], "KL", "2013-14", 4, "flag_anc_reg")


# ---- the 2017 format break (spec §3.4) ------------------------------------------------------------------------
def test_break_ratio_2017_from_national_sums():
    v = cat(long([100] * 12, fy="2016-17"), long([50] * 12, unit="GA", fy="2016-17"),
            long([130] * 12, fy="2017-18"), long([np.nan] * 12, unit="GA", fy="2017-18"),
            long([10] * 12, fy="2016-17", indicator="opd"), long([12] * 12, fy="2017-18", indicator="opd"))
    br = hg.break_ratio_2017(v)
    assert list(br.columns) == ["indicator", "mar2017", "apr2017", "ratio", "gt25pct", "n_units"]
    a = br.set_index("indicator")
    assert a.loc["anc_reg", "mar2017"] == 100 and a.loc["anc_reg", "ratio"] == pytest.approx(1.3)
    assert bool(a.loc["anc_reg", "gt25pct"]) and not bool(a.loc["opd", "gt25pct"])
    assert a.loc["anc_reg", "n_units"] == 1


# ---- the panel step on synthetic parts (tmp_path only) ----------------------------------------------------------
def _parts(tmp_path):
    parts = tmp_path / "_parts"
    parts.mkdir()
    fys = ["2014-15", "2020-21"]
    st = cat(*[srows("Kerala", fy, [1000] * 12, indicator=i) for fy in fys for i in INDICATORS])
    comp = cat(*[crows("Kerala", fy, 1.0, indicator=i) for fy in fys for i in INDICATORS])
    dm = cat(*[drows("Kerala", fy, [1000] * 12, indicator=i) for fy in fys for i in INDICATORS])
    st.to_csv(parts / "state_month.csv.gz", index=False)
    comp.to_csv(parts / "completeness.csv.gz", index=False)
    dm.to_csv(parts / "district_month.csv.gz", index=False)
    return parts


def test_build_panel_writes_only_where_told(tmp_path):
    parts = _parts(tmp_path)
    report = tmp_path / "validation_report.md"
    report.write_text("# Validation report\n\nexisting text\n", encoding="utf-8")
    out = tmp_path / "out" / "hmis_state_month.csv"
    kw = dict(out=out, parts=parts, reviewed_path=tmp_path / "hmis_reviewed.csv",
              summary_out=tmp_path / "out" / "gate_summary.csv", break_out=tmp_path / "out" / "break.csv",
              report_path=report, fys=["2014-15", "2020-21"])
    assert hpn.build_panel(**kw) == out
    p = pd.read_csv(out)
    assert len(p) == 34 * 24 and list(p.columns) == hpn.panel_columns()
    s = pd.read_csv(tmp_path / "out" / "gate_summary.csv")
    assert set(s.scope) == {"primary", "fy2020_21"} and set(s.indicator) == set(INDICATORS)
    assert list(s.columns) == hg.SUMMARY_COLUMNS
    text = report.read_text(encoding="utf-8")
    assert "existing text" in text and text.count("## Paper E HMIS gates") == 1
    hpn.build_panel(**kw)                                                     # idempotent report section
    assert report.read_text(encoding="utf-8").count("## Paper E HMIS gates") == 1
    assert (tmp_path / "hmis_reviewed.csv").exists()


def test_national_step_reads_folder1_and_subtracts_mo_from_all_india_xls(tmp_path):
    """Folder-1 national month files (synthetic across-states layout) and the folder-3 All_India.xls M/O rows."""
    from tests.hmis.test_flags import _make_fixtures
    mk = _make_fixtures()
    root = tmp_path / "hmis"
    f1 = root / run.FOLDER1
    f1.mkdir(parents=True)
    with zipfile.ZipFile(f1 / "2014-2015.zip", "w") as z:
        z.writestr("2014-2015/A.MonthWise/A - April.xls", across_states_html(items=[
            (c, t, ty[0]) for c, t, ty in mk.E1_ITEMS if len(ty) == 1]))
        z.writestr("2014-2015/B.Cummulative/A - UpTo_April.xls", b"<html></html>")
    f3 = root / run.FOLDER3
    f3.mkdir()
    allindia = mk.sas_html("e1_allindia", "State", "All India", "2014-2015", "29 Jan 2016, 2:00 PM",
                           ["State P", "M O Defence"], mk.E1_ITEMS, splits=False)
    with zipfile.ZipFile(f3 / "2014-2015.zip", "w") as z:
        z.writestr("2014-2015/All_India.xls", allindia)
    out = tmp_path / "national_month.csv.gz"
    nat = run.national(out=out, root=root, fys=["2014-15"])
    assert out.exists() and list(nat.columns) == run.NATIONAL_COLUMNS
    apr = nat[(nat.month == 4) & (nat.indicator == "anc_reg")].iloc[0]
    assert bool(apr.mo_in_national)
    assert apr.national == pytest.approx(apr.all_india - apr.mo_value)
    may = nat[(nat.month == 5) & (nat.indicator == "anc_reg")].iloc[0]
    assert math.isnan(may.national) and "no month file" in may.note
    assert len(nat) == 12 * len(INDICATORS)
