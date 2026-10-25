"""HMIS model table (Paper E, Task 5): lags, programme indicators, offsets, S_i and the table itself."""
import math

import numpy as np
import pandas as pd
import pytest

from pipeline.hmis import exposure as ex
from pipeline.hmis import model_table as mt
from pipeline.hmis.crosswalk import INDICATORS
from pipeline.outcomes import states


def _lf(path) -> bytes:
    """File bytes with CRLF normalised (a Windows checkout with core.autocrlf may convert tracked CSVs)."""
    return path.read_bytes().replace(b"\r\n", b"\n")


def test_lag_merge_not_shift():
    df = pd.DataFrame({"unit_id": ["A"] * 4 + ["B"] * 2,
                       "ym": [100, 101, 103, 104, 100, 101],          # A has no row for ym 102
                       "x": [1.0, 2.0, 4.0, 5.0, 10.0, 20.0]})
    out = mt.lag_merge(df, ["x"], ["unit_id"], 1).set_index(["unit_id", "ym"])
    assert math.isnan(out.loc[("A", 103), "x_l1"])                     # not the previous row (2.0)
    assert out.loc[("A", 104), "x_l1"] == 4.0 and out.loc[("A", 101), "x_l1"] == 1.0
    assert math.isnan(out.loc[("A", 100), "x_l1"])
    assert out.loc[("B", 101), "x_l1"] == 10.0                         # never crosses units
    assert len(out) == len(df) and out.x.tolist() == df.x.tolist()
    nat = mt.lag_merge(pd.DataFrame({"ym": [1, 2, 4], "e": [0.1, 0.2, 0.4]}), ["e"], [], 2).set_index("ym")
    assert nat.loc[4, "e_l2"] == 0.2 and math.isnan(nat.loc[2, "e_l2"])
    with pytest.raises(ValueError):
        mt.lag_merge(pd.concat([df, df.iloc[:1]]), ["x"], ["unit_id"], 1)


def test_offsets_leap_february_2016_and_mid_month_population():
    pop = pd.DataFrame({"unit_id": ["A"] * 3, "year": [2015, 2016, 2017], "population": [1000.0, 1366.0, 2000.0]})
    yms = [ex.ym_of(2016, 2), ex.ym_of(2015, 2), ex.ym_of(2016, 3), ex.ym_of(2015, 9)]
    o = mt.offsets(["A"], yms, pop).set_index("ym")
    assert o.loc[ex.ym_of(2016, 2), "days"] == 29 and o.loc[ex.ym_of(2015, 2), "days"] == 28
    # 15 Sep 2015 is 198 days after 1 Mar 2015; the 2015-16 anchor interval has 366 days (leap day 29 Feb 2016)
    assert o.loc[ex.ym_of(2015, 9), "pop_mid"] == pytest.approx(1000 + 366 * 198 / 366)
    # 15 Mar 2016: 14 days after 1 Mar 2016, interval to 1 Mar 2017 is 365 days
    assert o.loc[ex.ym_of(2016, 3), "pop_mid"] == pytest.approx(1366 + 634 * 14 / 365)
    # 15 Feb 2015 precedes the first anchor: no extrapolation
    assert math.isnan(o.loc[ex.ym_of(2015, 2), "pop_mid"]) and math.isnan(o.loc[ex.ym_of(2015, 2), "log_pop_days"])
    r = o.loc[ex.ym_of(2016, 2)]
    assert r.log_pop_days == pytest.approx(math.log(r.pop_mid * 29))
    assert list(mt.offsets(["A"], yms, pop).columns) == ["unit_id", "ym", "pop_mid", "days", "log_pop_days"]


def test_s_z_na_for_an_ld_and_standardised_over_32(tmp_path):
    units = states.UNITS
    vals = {u: float(i) for i, u in enumerate(units)}
    vals["LD"] = 99.0                                                  # a stray value for LD is still NA
    p = tmp_path / "risk_index.csv"
    pd.DataFrame({"unit_id": units, "hazard_rain": [np.nan if u == "AN" else vals[u] for u in units]}).to_csv(
        p, index=False)
    s = mt.sensitivity_s(p).set_index("unit_id")
    assert list(mt.sensitivity_s(p).columns) == ["unit_id", "S_raw", "S_z"]
    assert len(s) == 34
    assert s.loc[["AN", "LD"]].isna().all().all()
    ok = s.S_z.dropna()
    assert len(ok) == 32
    assert ok.mean() == pytest.approx(0, abs=1e-12) and ok.std(ddof=1) == pytest.approx(1)
    raw = s.S_raw.dropna()
    assert np.allclose(ok, (raw - raw.mean()) / raw.std(ddof=1))


def test_s_z_on_paper_d_risk_index():
    s = mt.sensitivity_s(mt.RISK_INDEX).set_index("unit_id")
    assert s.S_z.notna().sum() == 32 and s.loc[["AN", "LD"]].S_z.isna().all()


def test_programme_indicators_demonet_exact_months():
    yms = range(ex.PRIMARY_START, ex.FY2021_END + 1)
    p = mt.programme_indicators(yms, mt.read_events())
    assert list(p.columns) == ["ym"] + list(mt.PROGRAMME_INDICATORS)
    p = p.set_index("ym")
    on = sorted(p.index[p.demonet == 1])
    assert on == [ex.ym_of(2016, 11), ex.ym_of(2016, 12), ex.ym_of(2017, 1)]
    assert p.loc[ex.ym_of(2017, 3), "hmis_format2017"] == 0 and p.loc[ex.ym_of(2017, 4), "hmis_format2017"] == 1
    assert p.loc[ex.FY2021_END, "hmis_format2017"] == 1                 # open-ended step
    assert sorted(p.index[p.covid_mar2020 == 1]) == [ex.ym_of(2020, 3)]
    assert sorted(p.index[p.covid_fy2021 == 1]) == list(range(ex.ym_of(2020, 4), ex.FY2021_END + 1))
    assert p.loc[ex.ym_of(2015, 4), "mi_round"] == 1 and p.loc[ex.ym_of(2014, 12), "mi_round"] == 0
    assert p.loc[ex.ym_of(2016, 5), "pmsma"] == 0 and p.loc[ex.ym_of(2016, 6), "pmsma"] == 1
    assert p.loc[ex.ym_of(2017, 11), "laqshya"] == 0 and p.loc[ex.ym_of(2017, 12), "laqshya"] == 1
    assert p.diwali.sum() == 9 and set(p.index[p.diwali == 1] % 12 + 1) <= {10, 11}
    assert p.isin([0, 1]).all().all()


def test_programme_terms_for_follows_applies_to():
    common = ["hmis_format2017", "demonet", "covid_mar2020", "covid_fy2021", "diwali"]
    assert mt.programme_terms_for("penta3") == ["hmis_format2017", "demonet", "mi_round", "covid_mar2020",
                                                "covid_fy2021", "diwali"]
    for i in ("mcv1", "fic"):
        assert "mi_round" in mt.programme_terms_for(i)
    assert mt.programme_terms_for("anc_reg") == sorted(common + ["pmsma"], key=mt.PROGRAMME_INDICATORS.index)
    assert mt.programme_terms_for("inst_del") == sorted(common + ["laqshya"], key=mt.PROGRAMME_INDICATORS.index)
    for i in ("diarr_u5", "opd"):
        assert mt.programme_terms_for(i) == common
    assert mt.programme_terms_for("penta3", include_sensitivity=False) == ["hmis_format2017", "demonet", "mi_round",
                                                                          "covid_mar2020"]
    assert mt.programme_terms_for("anc_reg", include_sensitivity=False) == ["hmis_format2017", "demonet",
                                                                           "covid_mar2020"]
    with pytest.raises(ValueError):
        mt.programme_terms_for("malaria")
    bad = pd.DataFrame({"indicator": ["mi_round"], "applies_to": ["penta3;measles"]})
    with pytest.raises(ValueError):
        mt.programme_terms_for("penta3", events=bad)


def test_provisional_rows_are_tagged():
    ev = mt.read_events()
    weak = ~ev.source_url.str.contains("relid=121405|^spec", regex=True)
    assert ev.note[weak].str.contains("PROVISIONAL").all()
    assert not ev.note[~weak].str.contains("PROVISIONAL").any()


def test_programme_indicators_reject_unknown_indicator():
    ev = pd.DataFrame({"indicator": ["nonsense"], "start_ym": ["2015-01"], "end_ym": ["2015-02"]})
    with pytest.raises(ValueError):
        mt.programme_indicators([ex.ym_of(2015, 1)], ev)


def test_programme_events_file_documented():
    ev = mt.read_events()
    assert list(ev.columns) == ["event", "indicator", "start_ym", "end_ym", "applies_to", "source_url", "accessed",
                                "note"]
    assert ev.source_url.notna().all() and ev.accessed.notna().all()


@pytest.fixture(scope="module")
def built(tmp_path_factory):
    out = tmp_path_factory.mktemp("model") / "hmis_model.csv"
    return mt.build_model_table(out=out), out


def test_model_table_shape(built):
    path, _ = built
    m = pd.read_csv(path, dtype={"fy": str})
    assert len(m) == 34 * 108 and m.unit_id.nunique() == 34
    assert not m.duplicated(["unit_id", "ym"]).any()
    assert set(m.ym) == set(range(ex.PRIMARY_START, ex.FY2021_END + 1))
    assert m.in_primary.sum() == 34 * 95
    assert list(m.columns) == mt.model_columns()
    assert set(m.unit_id[m.small_unit == 1]) == {"LD", "CH", "PY", "DNH_DD", "AN", "SK", "GA"}
    first = m[m.ym == ex.PRIMARY_START]
    assert (first.t_months == 0).all() and np.allclose(first.t_c, -47 / 12)
    assert np.allclose(m.en_S, m.en_t * m.S_z, equal_nan=True)
    assert m.loc[m.unit_id.isin(["AN", "LD"]), "en_S"].isna().all()
    assert m.loc[m.unit_id == "AN", ["spi3_dry_l0", "spi3_wet_l0"]].isna().all().all()
    assert m.loc[m.unit_id == "AN", "heatwave_days_l0"].notna().all()
    expo = ["en_t", "ln_t", "en_t_l6", "oni", "roni", "nino34_3m", "dmi_3m"]
    assert m.loc[m.in_primary == 1, expo].notna().all().all()
    for i in INDICATORS:
        for c in (i, f"{i}_masklow", f"{i}_c75", f"{i}_c00", f"log1p_{i}_lag12"):
            assert c in m.columns, c
        assert (m[f"{i}_c00"].isna() == m[f"{i}_raw"].isna()).all()
        assert (m[f"{i}_c75"].isna() | (m[f"comp_{i}"] >= 0.75)).all()
    assert m.log_births.isna().all() and m.log_preg.isna().all()        # SRS not retrieved (ruling F23)


def test_model_table_lags_agree_with_source(built):
    path, _ = built
    m = pd.read_csv(path, dtype={"fy": str}).set_index(["unit_id", "ym"])
    t = ex.ym_of(2016, 8)
    assert m.loc[("UP", t), "en_t_l3"] == m.loc[("UP", t - 3), "en_t"]
    v = m.loc[("UP", t - 12), "penta3"]
    assert pd.notna(v), "UP penta3 in Aug 2015 should be present for this check"
    assert m.loc[("UP", t), "log1p_penta3_lag12"] == pytest.approx(np.log1p(v))
    cl = pd.read_csv(mt.CLIMATE_PATH).set_index(["unit_id", "ym"])
    assert m.loc[("RJ", t), "spi3_dry_l2"] == pytest.approx(cl.loc[("RJ", t - 2), "spi3_dry"])


def test_tracked_model_table_is_current(built):
    _, out = built
    assert mt.MODEL_PATH.exists(), "run python -I pipeline/hmis/run.py model-table"
    assert _lf(mt.MODEL_PATH) == _lf(out), "hmis_model.csv is stale: rerun model-table"


def test_run_model_table_step_writes_to_given_paths(tmp_path):
    from pipeline.hmis import run
    res = run.model_table_step(climate_out=tmp_path / "c.csv", model_out=tmp_path / "m.csv")
    assert res["model_rows"] == 34 * 108 and res["primary_rows"] == 34 * 95 and res["climate_units"] == 34
    assert _lf(tmp_path / "c.csv") == _lf(mt.CLIMATE_PATH), "climate_unit_month.csv is stale: rerun model-table"
    assert set(res["nan_share"].outcome) >= set(INDICATORS) and res["srs"] == mt.SRS_STATUS
