"""Unit-month climate for the HMIS panel (Paper E, Task 5; spec §3.9, §4).

Order of operations (climate_unit_month):
1. the reviewed QC masks: climate_annual.apply_qc_to_month(<climate_state_month.csv>, "state") (masked
   region-months get NaN rain; district-mask propagation infills or masks; temperature is untouched);
2. pooling per unit-month with climate_units.aggregate(keys=("year", "month")): area-weighted means over the
   member states with a non-NaN value, weights renormalised over those members (a unit-month with no non-NaN
   member stays NaN, never 0);
3. SPI-3 per unit with climate_annual.spi(series, 3) (gamma fit per calendar month, base 1981-2010) on a
   contiguous monthly series, so a masked or absent month makes every 3-month window containing it NaN;
4. tmax_anom = tmax_mean minus the unit's 1981-2010 mean for that calendar month.
A&N rainfall is masked (Phase 1 R19/R20), so its rain_mm, spi3, spi3_dry and spi3_wet are NaN while
heatwave_days and tmax_anom are present.

Hand-off: data/derived/hmis/climate_unit_month.csv (tracked; state-level), one row per unit x month present in
climate_state_month.csv (34 units, 1981 onward). Columns (COLUMNS):
- unit_id, year, month (calendar), ym = 12*year + month - 1;
- rain_mm (unit monthly rainfall, mm), tmax_mean (deg C), heatwave_days (days with Tmax >= 45 deg C, or >= 40 deg C
  with a departure >= 4.5 deg C; area-weighted mean over members);
- spi3 (SPI over the 3 months ending in the month), tmax_anom (deg C);
- spi3_dry = min(spi3, 0), spi3_wet = max(spi3, 0) (the H9 pathway terms).
"""
from pathlib import Path

import numpy as np
import pandas as pd

from pipeline import climate_annual as ca
from pipeline import climate_units as cu
from pipeline.outcomes import states
from pipeline.paths import DERIVED

HMIS_DIR = DERIVED / "hmis"
OUT_PATH = HMIS_DIR / "climate_unit_month.csv"
VALUE_COLUMNS = ["rain_mm", "tmax_mean", "heatwave_days"]
COLUMNS = ["unit_id", "year", "month", "ym", "rain_mm", "tmax_mean", "heatwave_days", "spi3", "tmax_anom",
           "spi3_dry", "spi3_wet"]


def _spi3(g: pd.DataFrame) -> np.ndarray:
    idx = pd.PeriodIndex.from_fields(year=g.year, month=g.month, freq="M")
    full = pd.period_range(idx.min(), idx.max(), freq="M")          # contiguous: a missing row is a gap
    s = ca.spi(pd.Series(g.rain_mm.to_numpy(dtype=float), index=idx).reindex(full), 3, ca.BASE)
    return s.reindex(idx).to_numpy()


def from_state_month(month: pd.DataFrame, areas: dict) -> pd.DataFrame:
    """Steps 2-4 on a QC-masked state-month table (region_id, year, month, rain_mm, tmax_mean, heatwave_days)."""
    u = cu.aggregate(month, areas, columns=VALUE_COLUMNS, keys=("year", "month"))
    u = u.sort_values(["unit_id", "year", "month"]).reset_index(drop=True)
    u["ym"] = 12 * u.year + u.month - 1
    u["spi3"] = np.nan
    for unit, g in u.groupby("unit_id", sort=False):
        u.loc[g.index, "spi3"] = _spi3(g)
    base = u[u.year.between(*ca.BASE)]
    normal = base.groupby(["unit_id", "month"]).tmax_mean.mean().rename("_tmax_normal")
    u = u.merge(normal, left_on=["unit_id", "month"], right_index=True, how="left")
    u["tmax_anom"] = u.tmax_mean - u._tmax_normal
    u["spi3_dry"] = np.minimum(u.spi3, 0)
    u["spi3_wet"] = np.maximum(u.spi3, 0)
    return u[COLUMNS].reset_index(drop=True)


def climate_unit_month(derived=DERIVED) -> pd.DataFrame:
    derived = Path(derived)
    month = pd.read_csv(derived / "climate_state_month.csv")
    qc = ca.apply_qc_to_month(month, "state", derived=derived)
    out = from_state_month(qc, cu.state_areas(derived))
    missing = set(states.UNITS) - set(out.unit_id)
    if missing:
        raise ValueError(f"units with no climate rows: {sorted(missing)}")
    return out


def build(out: Path = OUT_PATH, derived=DERIVED) -> Path:
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    climate_unit_month(derived).to_csv(out, index=False)
    return out
