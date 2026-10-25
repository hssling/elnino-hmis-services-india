"""ENSO exposures for the HMIS month panel (Paper E, Task 5; spec §4)."""
import numpy as np
import pandas as pd
import pytest

from pipeline.hmis import exposure as ex
from pipeline.paths import DERIVED


def _enso(start=(2014, 1), n=36, seed=0):
    rng = np.random.default_rng(seed)
    y0, m0 = start
    yms = np.arange(ex.ym_of(y0, m0), ex.ym_of(y0, m0) + n)
    return pd.DataFrame({"year": yms // 12, "month": yms % 12 + 1,
                         "oni_anom": np.round(rng.normal(0, 1, n), 2), "roni": np.round(rng.normal(0, 1, n), 2),
                         "nino34_anom": np.round(rng.normal(0, 1, n), 2), "dmi": np.round(rng.normal(0, 0.5, n), 3)})


def test_ym_and_windows():
    assert ex.ym_of(2012, 4) == 12 * 2012 + 3
    assert ex.PRIMARY_END - ex.PRIMARY_START + 1 == 95
    assert ex.FY2021_END == ex.ym_of(2021, 3)


def test_oni_season_ending_in_month():
    enso = _enso()
    e = ex.enso_exposures(enso, [ex.ym_of(2015, 8), ex.ym_of(2016, 1)]).set_index("ym")
    jja = enso[(enso.year == 2015) & (enso.month == 7)].iloc[0]          # JJA 2015, centre July
    ndj = enso[(enso.year == 2015) & (enso.month == 12)].iloc[0]         # NDJ 2015/16, centre December 2015
    assert e.loc[ex.ym_of(2015, 8), "oni"] == jja.oni_anom and e.loc[ex.ym_of(2015, 8), "roni"] == jja.roni
    assert e.loc[ex.ym_of(2016, 1), "oni"] == ndj.oni_anom and e.loc[ex.ym_of(2016, 1), "roni"] == ndj.roni


def test_nino34_and_dmi_three_month_means():
    enso = _enso()
    t = ex.ym_of(2015, 8)
    e = ex.enso_exposures(enso, [t]).iloc[0]
    win = enso[(enso.year == 2015) & enso.month.isin([6, 7, 8])]       # months t-2..t (calendar values)
    assert e.nino34_3m == pytest.approx(win.nino34_anom.mean())
    assert e.dmi_3m == pytest.approx(win.dmi.mean())
    # a missing calendar month inside the window gives NaN, not a 2-month mean
    gap = enso[~((enso.year == 2015) & (enso.month == 7))]
    e2 = ex.enso_exposures(gap, [t]).iloc[0]
    assert np.isnan(e2.nino34_3m) and np.isnan(e2.dmi_3m)


def test_phase_split():
    e = ex.enso_exposures(_enso(), range(ex.ym_of(2014, 4), ex.ym_of(2016, 12)))
    for x, en, ln in (("oni", "en_t", "ln_t"), ("roni", "en_roni", "ln_roni"), ("nino34_3m", "en_n34", "ln_n34")):
        assert np.allclose(e[en] + e[ln], e[x])
        assert (e[en] >= 0).all() and (e[ln] <= 0).all()


def test_primary_window_exposure_counts():
    enso = pd.read_csv(DERIVED / "enso_monthly.csv")
    e = ex.enso_exposures(enso, range(ex.PRIMARY_START, ex.PRIMARY_END + 1))
    assert len(e) == 95 and (e.oni >= 0.5).sum() == 34 and (e.oni <= -0.5).sum() == 6
    assert round(e.oni.std(), 2) == 0.75 and e.oni.max() == 2.59 and round(e.roni.std(), 2) == 0.76
    assert e[["oni", "roni", "nino34_3m", "dmi_3m"]].notna().all().all()


def test_episode_terms_partition_en_t():
    enso = pd.read_csv(DERIVED / "enso_monthly.csv")
    e = ex.enso_exposures(enso, range(ex.PRIMARY_START - 6, ex.FY2021_END + 1))
    assert np.allclose(e.en_ep1415 + e.en_ep1819 + e.en_other, e.en_t)
    in1415 = e.ym.between(*ex.EPISODES["ep1415"])
    in1819 = e.ym.between(*ex.EPISODES["ep1819"])
    assert (e.en_ep1415[~in1415] == 0).all() and (e.en_ep1819[~in1819] == 0).all()
    assert (e.en_other[in1415 | in1819] == 0).all()
    assert ex.EPISODES == {"ep1415": (ex.ym_of(2014, 10), ex.ym_of(2016, 12)),
                           "ep1819": (ex.ym_of(2018, 9), ex.ym_of(2020, 2))}


def test_missing_enso_row_stays_nan():
    enso = _enso()
    t = ex.ym_of(2015, 8)
    gap = enso[~((enso.year == 2015) & (enso.month == 7))]               # the JJA 2015 row is absent
    e = ex.enso_exposures(gap, [t]).iloc[0]
    assert np.isnan(e.oni) and np.isnan(e.en_t) and np.isnan(e.ln_t) and np.isnan(e.en_other)
