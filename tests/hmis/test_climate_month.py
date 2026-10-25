"""Unit-month climate for the HMIS panel (Paper E, Task 5; spec §3.9). Synthetic state-month frames only."""
import numpy as np
import pandas as pd
import pytest

from pipeline.hmis import climate_month as cm

GA, AP, TG, AN = "IND.10_1", "IND.2_1", "IND.32_1", "IND.1_1"


def _state_month(regions, years=range(1981, 2016), seed=1):
    rng = np.random.default_rng(seed)
    rows = []
    for r in regions:
        for y in years:
            for m in range(1, 13):
                rows.append({"region_id": r, "year": y, "month": m,
                             "rain_mm": float(rng.gamma(2.0, 50.0)),
                             "tmax_mean": 30 + 5 * np.sin(2 * np.pi * m / 12) + float(rng.normal(0, 1)),
                             "heatwave_days": float(rng.integers(0, 4))})
    return pd.DataFrame(rows)


def test_unit_climate_renormalises_over_nonnan_members():
    sm = _state_month([AP, TG], years=range(1981, 1983))
    sel = (sm.region_id == TG) & (sm.year == 1982) & (sm.month == 7)
    sm.loc[sel, "rain_mm"] = np.nan
    out = cm.from_state_month(sm, {AP: 3.0, TG: 1.0}).set_index(["unit_id", "year", "month"])
    ap = sm.set_index(["region_id", "year", "month"])
    assert out.loc[("AP_TG", 1982, 7), "rain_mm"] == ap.loc[(AP, 1982, 7), "rain_mm"]   # TG masked -> AP only
    exp = (3 * ap.loc[(AP, 1982, 6), "rain_mm"] + ap.loc[(TG, 1982, 6), "rain_mm"]) / 4
    assert out.loc[("AP_TG", 1982, 6), "rain_mm"] == pytest.approx(exp)
    texp = (3 * ap.loc[(AP, 1982, 7), "tmax_mean"] + ap.loc[(TG, 1982, 7), "tmax_mean"]) / 4
    assert out.loc[("AP_TG", 1982, 7), "tmax_mean"] == pytest.approx(texp)               # temperature unaffected
    both = sm.copy()
    both.loc[(both.year == 1982) & (both.month == 7), "rain_mm"] = np.nan
    o2 = cm.from_state_month(both, {AP: 3.0, TG: 1.0}).set_index(["unit_id", "year", "month"])
    assert np.isnan(o2.loc[("AP_TG", 1982, 7), "rain_mm"])                                # never 0


def test_output_columns_and_ym():
    out = cm.from_state_month(_state_month([GA], years=range(1981, 1983)), {GA: 1.0})
    assert list(out.columns) == cm.COLUMNS
    assert (out.ym == 12 * out.year + out.month - 1).all()
    assert len(out) == 24 and (out.unit_id == "GA").all()


def test_spi3_nan_when_window_has_masked_month():
    sm = _state_month([GA])
    sm.loc[(sm.year == 2014) & (sm.month == 5), "rain_mm"] = np.nan
    out = cm.from_state_month(sm, {GA: 1.0}).set_index(["year", "month"])
    for m in (5, 6, 7):                                    # windows ending May, June, July 2014 contain May
        assert np.isnan(out.loc[(2014, m), "spi3"]), m
        assert np.isnan(out.loc[(2014, m), "spi3_dry"]) and np.isnan(out.loc[(2014, m), "spi3_wet"])
    assert np.isfinite(out.loc[(2014, 4), "spi3"]) and np.isfinite(out.loc[(2014, 8), "spi3"])


def test_spi3_missing_row_is_a_gap_not_skipped():
    sm = _state_month([GA])
    sm = sm[~((sm.year == 2014) & (sm.month == 5))]       # the row is absent, not NaN
    out = cm.from_state_month(sm, {GA: 1.0}).set_index(["year", "month"])
    assert np.isnan(out.loc[(2014, 6), "spi3"]) and np.isnan(out.loc[(2014, 7), "spi3"])
    assert (2014, 5) not in out.index or np.isnan(out.loc[(2014, 5), "spi3"])


def test_spi3_split_and_tmax_anomaly():
    sm = _state_month([GA])
    out = cm.from_state_month(sm, {GA: 1.0})
    ok = out.spi3.notna()
    assert np.allclose(out.spi3_dry[ok], np.minimum(out.spi3[ok], 0))
    assert np.allclose(out.spi3_wet[ok], np.maximum(out.spi3[ok], 0))
    base = out[out.year.between(1981, 2010)]
    normal = base.groupby("month").tmax_mean.mean()
    assert np.allclose(out.tmax_anom, out.tmax_mean - out.month.map(normal))
    assert np.allclose(base.groupby("month").tmax_anom.mean(), 0)


def test_an_rain_terms_nan_heatwave_present():
    sm = _state_month([AN, GA])
    sm.loc[sm.region_id == AN, "rain_mm"] = np.nan        # A&N rainfall is QC-masked (Phase 1 R19/R20)
    out = cm.from_state_month(sm, {AN: 1.0, GA: 1.0})
    an = out[out.unit_id == "AN"]
    assert an[["rain_mm", "spi3", "spi3_dry", "spi3_wet"]].isna().all().all()
    assert an.heatwave_days.notna().all() and an.tmax_anom.notna().all()
    assert out[out.unit_id == "GA"].spi3.notna().sum() > 0
