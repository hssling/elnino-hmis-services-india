"""ENSO exposures for the HMIS month panel (Paper E, Task 5; spec §4).

Month index: ym = 12*year + month - 1 (as in the panel). Windows: PRIMARY_START (April 2012) .. PRIMARY_END
(February 2020), 95 modelled months; March 2020 is outside the primary window (spec §5.1: covid_mar2020 is
"equivalent to excluding the month"); FY2021_END = March 2021 closes the FY2020-21 sensitivity rows.

enso_exposures(enso, yms) reads data/derived/enso_monthly.csv rows (`month` is the centre month of each 3-month
season for oni_anom and roni; nino34_anom and dmi are calendar-month values) and returns one row per ym with:
- oni, roni: the season ENDING in month t, i.e. the row whose centre month is t - 1 (August -> JJA; spec §4);
- nino34_3m, dmi_3m: means of the calendar-month values over t-2..t (all three months required, else NaN), so the
  comparator indices share the ONI's smoothing; dmi_3m is the IOD "season ending in t" (plan decision);
- en_t = max(oni, 0), ln_t = min(oni, 0); en_roni/ln_roni and en_n34/ln_n34 likewise from roni and nino34_3m;
- en_ep1415 = en_t*I(ep1415), en_ep1819 = en_t*I(ep1819), en_other = en_t*I(neither): the episode-specific
  Model T terms over the §5.7 LOEO windows in EPISODES (plan decision); they sum to en_t.
A missing ENSO row leaves every term built from it NaN (never 0).
"""
import numpy as np
import pandas as pd


def ym_of(year: int, month: int) -> int:
    return 12 * int(year) + int(month) - 1


PRIMARY_START = ym_of(2012, 4)
PRIMARY_END = ym_of(2020, 2)
FY2021_END = ym_of(2021, 3)
EPISODES = {"ep1415": (ym_of(2014, 10), ym_of(2016, 12)), "ep1819": (ym_of(2018, 9), ym_of(2020, 2))}
EXPOSURE_COLUMNS = ["ym", "oni", "roni", "nino34_3m", "dmi_3m", "en_t", "ln_t", "en_roni", "ln_roni", "en_n34",
                    "ln_n34", "en_ep1415", "en_ep1819", "en_other"]


def _by_ym(enso: pd.DataFrame, col: str) -> pd.Series:
    s = pd.Series(enso[col].to_numpy(dtype=float), index=12 * enso.year.astype(int) + enso.month.astype(int) - 1)
    if s.index.duplicated().any():
        raise ValueError(f"duplicate ENSO months in {col}")
    return s


def _mean3(s: pd.Series, t: np.ndarray) -> np.ndarray:
    win = np.column_stack([s.reindex(t - k).to_numpy() for k in (2, 1, 0)])
    out = np.full(len(t), np.nan)
    full = ~np.isnan(win).any(axis=1)
    out[full] = win[full].mean(axis=1)
    return out


def enso_exposures(enso: pd.DataFrame, yms) -> pd.DataFrame:
    t = np.asarray(list(yms), dtype=int)
    e = pd.DataFrame({"ym": t})
    e["oni"] = _by_ym(enso, "oni_anom").reindex(t - 1).to_numpy()
    e["roni"] = _by_ym(enso, "roni").reindex(t - 1).to_numpy()
    e["nino34_3m"] = _mean3(_by_ym(enso, "nino34_anom"), t)
    e["dmi_3m"] = _mean3(_by_ym(enso, "dmi"), t)
    for x, en, ln in (("oni", "en_t", "ln_t"), ("roni", "en_roni", "ln_roni"), ("nino34_3m", "en_n34", "ln_n34")):
        e[en] = np.maximum(e[x], 0)          # NaN stays NaN (np.maximum propagates NaN)
        e[ln] = np.minimum(e[x], 0)
    in_ep = {k: e.ym.between(*v).to_numpy() for k, v in EPISODES.items()}
    e["en_ep1415"] = e.en_t * in_ep["ep1415"]
    e["en_ep1819"] = e.en_t * in_ep["ep1819"]
    e["en_other"] = e.en_t * ~(in_ep["ep1415"] | in_ep["ep1819"])
    return e[EXPOSURE_COLUMNS]
