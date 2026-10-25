"""State-month panel (Paper E, Task 4; spec §3.5, §3.6, §10.1, §12; rulings F33, F34, F36, F37, F38, F39).
Fixtures are synthetic (ruling F1); every file the tests write goes to tmp_path (ruling F9)."""
import math
from datetime import date

import numpy as np
import pandas as pd
import pytest

from pipeline.hmis import flags as hfl
from pipeline.hmis import panel as hpn
from pipeline.hmis import parse as hp
from pipeline.hmis.difference import FY_MONTHS

FIX = __import__("pathlib").Path(__file__).resolve().parent / "fixtures"


# ---- synthetic Task 3 hand-off tables --------------------------------------------------------------------
def srows(state, fy, values, indicator="anc_reg", months=FY_MONTHS, source=None, partial=False, n_components=1,
          n_present=None, status=date(2016, 1, 29)):
    """state_month rows (flags.STATE_COLUMNS) for one state, FY and indicator."""
    vals = [float(v) for v in values]
    months = list(months)[:len(vals)]
    pres = n_present if n_present is not None else [0 if math.isnan(v) else n_components for v in vals]
    return pd.DataFrame({"fy": fy, "month": months, "state_raw": state, "indicator": indicator, "value": vals,
                         "n_components": n_components, "n_present": pres, "partial_component": partial,
                         "status_date": status, "source_file": source or f"{fy}/All_India.xls"})[hfl.STATE_COLUMNS]


def crows(state, fy, comp, indicator="anc_reg", n_districts=10, months=FY_MONTHS, comp_full=None):
    comp = [comp] * len(months) if np.isscalar(comp) else list(comp)
    cf = comp if comp_full is None else ([comp_full] * len(months) if np.isscalar(comp_full) else comp_full)
    n_valid = [round(c * n_districts) for c in comp]
    return pd.DataFrame({"state_raw": state, "fy": fy, "month": list(months)[:len(comp)], "indicator": indicator,
                         "n_districts": n_districts, "n_valid": n_valid, "comp": comp,
                         "n_valid_full": [round(c * n_districts) for c in cf], "comp_full": cf})[hfl.COMP_COLUMNS]


def drows(state, fy, values, indicator="anc_reg", district="District A", months=FY_MONTHS, negative=None):
    """district_month rows (flags.DM_COLUMNS): one district carrying the valid sum of each month."""
    vals = [float(v) for v in values]
    neg = negative or [False] * len(vals)
    valid = [not (math.isnan(v) or n) for v, n in zip(vals, neg)]
    return pd.DataFrame({"fy": fy, "month": list(months)[:len(vals)], "state_raw": state, "district_raw": district,
                         "indicator": indicator, "value_raw": [(-1.0 if n else v) for v, n in zip(vals, neg)],
                         "value": [v if ok else np.nan for v, ok in zip(vals, valid)], "n_components": 1,
                         "n_present": 1, "partial_component": False, "negative": neg, "nofile": False,
                         "nonreport": False, "catchup": False, "valid": valid, "status_date": date(2016, 1, 29),
                         "source_file": f"{fy}/{state}.xls"})[hfl.DM_COLUMNS]


def cat(*frames):
    return pd.concat(frames, ignore_index=True)


def cell(panel, unit, fy, month, col):
    r = panel[(panel.unit_id == unit) & (panel.fy == fy) & (panel.month == month)]
    assert len(r) == 1
    return r[col].iloc[0]


# ---- labels ------------------------------------------------------------------------------------------------
@pytest.mark.parametrize("label,unit", [("_Kerala", "KL"), ("Andhra Pradesh Old", "AP_TG"), ("Telangana", "AP_TG"),
                                        ("Jammu and Kashmir", "JK"), ("Ladakh", "JK"),
                                        ("Andaman & Nicobar Islands", "AN"), ("A & N Islands", "AN"),
                                        ("The Dadra and Nagar Haveli and Daman and Diu", "DNH_DD"),
                                        ("Dadra & Nagar Haveli", "DNH_DD"), ("Daman & Diu", "DNH_DD"),
                                        ("All India", "TOTAL")])
def test_hmis_labels_resolve(label, unit):
    assert hpn.resolve_hmis_state(label) == unit


def test_unmapped_state_label_fails_naming_it():
    with pytest.raises(hpn.UnmappedStateError, match="Atlantis Pradesh"):
        hpn.resolve_hmis_state("Atlantis Pradesh")
    assert issubclass(hpn.UnmappedStateError, KeyError)
    rows = srows("Atlantis Pradesh", "2014-15", [1] * 12)
    with pytest.raises(hpn.UnmappedStateError, match="Atlantis Pradesh"):
        hpn.state_series(rows)


# ---- the state value (ruling F33) ---------------------------------------------------------------------------
def test_state_value_from_all_india_state_row_not_district_sum():
    st = srows("Kerala", "2014-15", [1000] * 12)
    comp = crows("Kerala", "2014-15", 0.9)
    dm = drows("Kerala", "2014-15", [810] * 12)
    p = hpn.assemble(st, comp, dm, fys=["2014-15"])["panel"]
    assert cell(p, "KL", "2014-15", 4, "anc_reg") == 1000
    assert cell(p, "KL", "2014-15", 4, "anc_reg_raw") == 1000
    assert cell(p, "KL", "2014-15", 4, "anc_reg_scaled") == pytest.approx(900)


def test_completeness_filter_090():
    comp = [0.89, 0.90] + [1.0] * 10
    st = srows("Kerala", "2014-15", [1000] * 12)
    p = hpn.assemble(st, crows("Kerala", "2014-15", comp, n_districts=100), drows("Kerala", "2014-15", [1000] * 12),
                     fys=["2014-15"])["panel"]
    assert math.isnan(cell(p, "KL", "2014-15", 4, "anc_reg"))
    assert cell(p, "KL", "2014-15", 4, "anc_reg_raw") == 1000
    assert "comp_lt_090" in cell(p, "KL", "2014-15", 4, "flag_anc_reg")
    assert cell(p, "KL", "2014-15", 5, "anc_reg") == 1000
    assert cell(p, "KL", "2014-15", 4, "comp_anc_reg") == pytest.approx(0.89)
    assert cell(p, "KL", "2014-15", 4, "n_districts_anc_reg") == 100


def test_scaled_sensitivity_is_valid_sum_over_comp():
    st = srows("Kerala", "2014-15", [1000] * 12)
    p = hpn.assemble(st, crows("Kerala", "2014-15", 0.9), drows("Kerala", "2014-15", [720] * 12),
                     fys=["2014-15"])["panel"]
    assert cell(p, "KL", "2014-15", 6, "anc_reg_scaled") == pytest.approx(800)
    p0 = hpn.assemble(st, crows("Kerala", "2014-15", 0.0), drows("Kerala", "2014-15", [np.nan] * 12),
                      fys=["2014-15"])["panel"]
    assert math.isnan(cell(p0, "KL", "2014-15", 6, "anc_reg_scaled"))


def test_pooled_units_absorb_ap_tg_split():
    ap = srows("Andhra Pradesh", "2014-15", [100, 100] + [60] * 10)          # Apr-May include TG districts
    tg = srows("Telangana", "2014-15", [np.nan, np.nan] + [40] * 10)          # TG file from June
    s = hpn.state_series(cat(ap, tg))
    v = s[(s.unit_id == "AP_TG") & (s.indicator == "anc_reg")].sort_values("month").value
    assert (v == 100).all() and len(v) == 12
    old = hpn.state_series(srows("Andhra Pradesh Old", "2013-14", [100] * 12))
    assert set(old.unit_id) == {"AP_TG"}


def test_state_series_min_count_keeps_all_missing_nan():
    s = hpn.state_series(cat(srows("Jammu and Kashmir", "2020-21", [np.nan] * 12),
                             srows("Ladakh", "2020-21", [np.nan] * 11 + [5])))
    s = s.set_index("month").value
    assert math.isnan(s[4]) and s[3] == 5


def test_dnh_dd_fy2021_uses_merged_file_only():
    merged = "The Dadra and Nagar Haveli and Daman and Diu"
    rows = cat(srows(merged, "2020-21", [300] * 12, source="m.xlsx"),
               srows("Dadra & Nagar Haveli", "2020-21", [200] * 12, source="dnh.xlsx"),
               srows("Daman & Diu", "2020-21", [100] * 12, source="dd.xlsx"))
    s = hpn.state_series(rows)
    assert (s[s.unit_id == "DNH_DD"].value == 300).all()
    pre = hpn.state_series(cat(srows("Dadra & Nagar Haveli", "2018-19", [200] * 12),
                               srows("Daman & Diu", "2018-19", [100] * 12, source="x2")))
    assert (pre.value == 300).all()                                           # pre-merger pool is legitimate


def test_duplicate_sources_for_one_unit_fail_naming_both_files():
    rows = cat(srows("Kerala", "2014-15", [1] * 12, source="a/Kerala.xls"),
               srows("Kerala", "2014-15", [1] * 12, source="b/Kerala.xls"))
    with pytest.raises(hpn.DuplicateSourceError, match="a/Kerala.xls.*b/Kerala.xls|b/Kerala.xls.*a/Kerala.xls"):
        hpn.state_series(rows)
    rows = cat(srows("Andhra Pradesh Old", "2014-15", [1] * 12, source="old.xls"),
               srows("Telangana", "2014-15", [1] * 12, source="tg.xls"))
    with pytest.raises(hpn.DuplicateSourceError, match="old.xls"):
        hpn.state_series(rows)


def test_missing_is_never_zero():
    st = srows("Kerala", "2014-15", [1000] * 12)
    p = hpn.assemble(st, crows("Kerala", "2014-15", 1.0), drows("Kerala", "2014-15", [1000] * 12),
                     fys=["2014-15"])["panel"]
    goa = p[(p.unit_id == "GA") & (p.fy == "2014-15")]
    assert len(goa) == 12
    vals = [c for c in p.columns if any(c == i or c.startswith(i + "_") or c.endswith("_" + i)
                                        for i in hpn.INDICATORS) and not c.startswith("flag_")]
    assert goa[vals].isna().all().all()
    assert len(p) == 34 * 12 and not p.duplicated(["unit_id", "ym"]).any()


def test_panel_columns_and_calendar():
    st = srows("Kerala", "2014-15", [1000] * 12)
    p = hpn.assemble(st, crows("Kerala", "2014-15", 1.0), drows("Kerala", "2014-15", [1000] * 12),
                     fys=["2014-15", "2020-21"])["panel"]
    assert list(p.columns) == hpn.panel_columns()
    jan = p[(p.unit_id == "KL") & (p.fy == "2014-15") & (p.month == 1)].iloc[0]
    assert jan.year == 2015 and jan.ym == 12 * 2015 and jan.era == "E1"
    assert set(p[p.fy == "2020-21"].era) == {"E3"}
    assert cell(p, "KL", "2014-15", 4, "status_date_min") == "2016-01-29"
    assert not any("district_raw" in c for c in p.columns)


def test_allcomp_sensitivity_needs_every_component():
    st = cat(srows("Kerala", "2014-15", [1000] * 12, indicator="inst_del", n_components=2,
                   n_present=[1] + [2] * 11))
    comp = crows("Kerala", "2014-15", 1.0, indicator="inst_del", comp_full=[1.0, 1.0, 0.5] + [1.0] * 9)
    p = hpn.assemble(st, comp, drows("Kerala", "2014-15", [1000] * 12, indicator="inst_del"),
                     fys=["2014-15"])["panel"]
    assert math.isnan(cell(p, "KL", "2014-15", 4, "inst_del_allcomp"))         # state row lacks a component
    assert cell(p, "KL", "2014-15", 5, "inst_del_allcomp") == 1000
    assert math.isnan(cell(p, "KL", "2014-15", 6, "inst_del_allcomp"))         # comp_full < 0.90
    assert cell(p, "KL", "2014-15", 6, "inst_del") == 1000


# ---- the national files (ruling F39) -------------------------------------------------------------------------
def across_states_html(fy4="2014-2015", month="April", status="29 Jan 2016, 2:00 PM",
                       units=("All India", "State P", "M/O Defence", "State Q"), items=None):
    """A SYNTHETIC folder-1 'All India Across State' month file (FY2012-13..2016-17 layout: no splits)."""
    items = items or [("1.1", "Total number of pregnant women Registered for ANC", "TOTAL")]
    td = lambda t: f"<td>{t}</td>"
    out = ["<html><head><title>SAS Output</title></head><body>",
           '<h1 class="systemtitle">Data ItemWise Report for All India Across State</h1>',
           f'<h1 class="systemtitle2">Provisional Figures for - {fy4} and Month - {month}</h1>',
           f'<h1 class="systemtitle3">Status As On: {status}</h1>', "<table>",
           "<tr>" + td("") * 4 + "".join(td("State") for _ in units) + "</tr>",
           "<tr>" + td("") * 4 + "".join(td(u.replace("&", "&amp;")) for u in units) + "</tr>"]
    for k, (code, text, typ) in enumerate(items):
        vals = [sum(10 * (j + 1) + k for j in range(1, len(units)))] + [10 * (j + 1) + k for j in range(1, len(units))]
        out.append("<tr>" + td("M1 [ANC]") + td(code) + td(text) + td(typ) + "".join(td(v) for v in vals) + "</tr>")
    out.append("</table></body></html>")
    return "\n".join(out).encode("cp1252")


def test_parse_national_across_states_layout():
    long = hp.parse_national("2014-2015/A.MonthWise/A - April.xls", across_states_html(), "2014-15")
    assert list(long.columns) == hp.LONG_COLUMNS
    assert set(long.state_raw) == {"All India", "State P", "M/O Defence", "State Q"}
    assert long.is_state_aggregate.all() and (long.month == 4).all()
    v = long.set_index("state_raw").value
    assert v["All India"] == v["State P"] + v["M/O Defence"] + v["State Q"]
    assert long.status_date.iloc[0] == date(2016, 1, 29)


def test_parse_national_e3_layout_and_rejects_state_files():
    long = hp.parse_national("A-Apr.xlsx", (FIX / "e3_synthetic_allindia_2021_apr.xlsx").read_bytes(), "2020-21")
    assert "All India" in set(long.state_raw) and (long.month == 4).all()
    with pytest.raises(hp.LayoutError):
        hp.parse_national("Kerala_Oct.xlsx", (FIX / "e3_synthetic_state_2021_oct.xlsx").read_bytes(), "2020-21")
    with pytest.raises(hp.LayoutError, match="month 5"):
        hp.parse_national("2014-2015/A.MonthWise/B - May.xls", across_states_html(), "2014-15")


# ---- fix round 1 (task-4-review I-2, M-3, M-4, M-5, M-6; ruling F41) --------------------------------------------
E1_FYS = ["2012-13", "2013-14", "2014-15", "2015-16", "2016-17"]


def _kerala(fys, april=None, indicator="anc_reg", comp=1.0):
    """Kerala at 1000 a month in every FY; `april` {fy: value} overrides April."""
    april = april or {}
    st = cat(*[srows("Kerala", fy, [april.get(fy, 1000)] + [1000] * 11, indicator=indicator) for fy in fys])
    cp = cat(*[crows("Kerala", fy, comp, indicator=indicator) for fy in fys])
    dm = cat(*[drows("Kerala", fy, [april.get(fy, 1000)] + [1000] * 11, indicator=indicator) for fy in fys])
    return st, cp, dm


def test_low_is_kept_logged_and_masked_only_in_the_masklow_sensitivity():
    st, cp, dm = _kerala(E1_FYS, april={"2014-15": 200, "2015-16": 5000})
    out = hpn.assemble(st, cp, dm, fys=E1_FYS)
    p, log = out["panel"], out["log"]
    assert cell(p, "KL", "2014-15", 4, "anc_reg") == 200                     # low kept (F41)
    assert math.isnan(cell(p, "KL", "2014-15", 4, "anc_reg_masklow"))
    assert cell(p, "KL", "2014-15", 5, "anc_reg_masklow") == 1000
    assert math.isnan(cell(p, "KL", "2015-16", 4, "anc_reg"))                # high masked
    low = log[(log.fy == "2014-15") & (log.month == 4)].iloc[0]
    assert low.disposition == "keep" and low.rule.startswith("default_keep_low") and "value=200" in low.evidence
    s = out["summary"].set_index(["indicator", "scope"]).loc[("anc_reg", "primary")]
    assert s.kept_low == 1 and s.masked_plausibility == 1


def test_gate_masks_reach_scaled_and_sensitivity_columns():
    st, cp, dm = _kerala(E1_FYS, april={"2015-16": 5000})
    p = hpn.assemble(st, cp, dm, fys=E1_FYS)["panel"]
    for col in ("anc_reg", "anc_reg_raw", "anc_reg_scaled", "anc_reg_allcomp", "anc_reg_masklow"):
        assert math.isnan(cell(p, "KL", "2015-16", 4, col)), col
    assert cell(p, "KL", "2015-16", 5, "anc_reg_scaled") == pytest.approx(1000)


def test_unusable_fy_masks_every_value_column_and_is_logged():
    from pipeline.hmis.crosswalk import PRIMARY5
    fys = ["2013-14", "2014-15"]
    parts = [_kerala(fys, indicator=i) for i in PRIMARY5]
    st = cat(*[x[0] for x in parts])
    cp = cat(*[crows("Kerala", fy, 1.0 if fy == "2014-15" else 0.5, indicator=i) for fy in fys for i in PRIMARY5])
    dm = cat(*[x[2] for x in parts])
    out = hpn.assemble(st, cp, dm, fys=fys)
    assert out["unusable"] == ["2013-14"]
    p = out["panel"]
    sel = p[(p.unit_id == "KL") & (p.fy == "2013-14")]
    for col in ("anc_reg", "anc_reg_raw", "anc_reg_scaled", "anc_reg_allcomp", "anc_reg_masklow"):
        assert sel[col].isna().all(), col
    lg = out["log"][out["log"].check == "fy_unusable"]
    assert len(lg) == 12 * len(hpn.INDICATORS) and set(lg.unit_id) == {"ALL"} and set(lg.fy) == {"2013-14"}


def test_halt_writes_summary_and_report_but_keeps_the_panel(tmp_path):
    fys = ["2012-13", "2013-14"]
    from pipeline.hmis.crosswalk import PRIMARY5
    parts = tmp_path / "_parts"
    parts.mkdir()
    cat(*[srows("Kerala", fy, [1000] * 12, indicator=i) for fy in fys for i in PRIMARY5]).to_csv(
        parts / "state_month.csv.gz", index=False)
    cat(*[crows("Kerala", fy, 0.5, indicator=i) for fy in fys for i in PRIMARY5]).to_csv(
        parts / "completeness.csv.gz", index=False)
    cat(*[drows("Kerala", fy, [1000] * 12, indicator=i) for fy in fys for i in PRIMARY5]).to_csv(
        parts / "district_month.csv.gz", index=False)
    out = tmp_path / "hmis_state_month.csv"
    out.write_text("previous panel\n", encoding="utf-8")
    reviewed = tmp_path / "hmis_reviewed.csv"
    report = tmp_path / "validation_report.md"
    kw = dict(out=out, parts=parts, reviewed_path=reviewed, summary_out=tmp_path / "gate_summary.csv",
              break_out=tmp_path / "break.csv", report_path=report, fys=fys)
    with pytest.raises(hpn.PanelHalt, match="2012-13.*2013-14"):
        hpn.build_panel(**kw)
    assert out.read_text(encoding="utf-8") == "previous panel\n"
    assert (tmp_path / "gate_summary.csv").exists() and not reviewed.exists()
    assert "HALT" in report.read_text(encoding="utf-8")


def test_superseded_single_ut_rows_dropped_for_every_indicator_of_the_month():
    merged = "The Dadra and Nagar Haveli and Daman and Diu"
    rows = cat(srows(merged, "2020-21", [300] * 12, source="m.xlsx"),                      # anc_reg only
               srows("Dadra & Nagar Haveli", "2020-21", [200] * 12, source="dnh.xlsx"),
               srows("Daman & Diu", "2020-21", [100] * 12, source="dd.xlsx"),
               srows("Dadra & Nagar Haveli", "2020-21", [20] * 12, indicator="opd", source="dnh.xlsx"),
               srows("Daman & Diu", "2020-21", [10] * 12, indicator="opd", source="dd.xlsx"))
    s = hpn.state_series(rows)
    assert (s[s.indicator == "anc_reg"].value == 300).all()
    assert s[s.indicator == "opd"].empty or s[s.indicator == "opd"].value.isna().all()
