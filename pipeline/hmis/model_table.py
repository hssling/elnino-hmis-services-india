"""HMIS model table (Paper E, Task 5; spec §3.7, §3.9, §4, §5.1; rulings F2, F9, F21, F23, F41).

Inputs: the gated state-month panel (data/derived/hmis/hmis_state_month.csv, pipeline/hmis/panel.py),
climate_unit_month.csv (pipeline/hmis/climate_month.py), data/derived/enso_monthly.csv, the 1 March population
series data/derived/model/population_2001_2027.csv (read only), Paper D's papers/D/output/risk_index.csv
(`hazard_rain`, read only) and pipeline/reference/hmis_programme_events.csv.

Programme events (pipeline/reference/hmis_programme_events.csv): event, indicator (one of PROGRAMME_INDICATORS),
start_ym and end_ym ("YYYY-MM", inclusive; a blank end_ym is an open-ended step), applies_to (outcomes,
";"-joined, or "all"), source_url, accessed (ISO date), note. An indicator is 1 in every month covered by any of
its rows, else 0. Rows whose months rest on a search-engine excerpt, Vikaspedia or a holiday-calendar site carry
the token PROVISIONAL in their note (Task 14 lists them for the author).

`applies_to` is recorded but NOT applied in the table: every programme column is filled for every outcome row.
The model scripts (Tasks 7/8) must restrict the terms per spec §5.1 (mi_round to the immunisation outcomes penta3,
mcv1 and fic; pmsma to anc_reg; laqshya to inst_del): programme_terms_for(<ind>) returns the programme columns
that apply to an outcome, read from `applies_to`. covid_fy2021, pmsma, laqshya and diwali are sensitivity-only
terms (SENSITIVITY_ONLY; include_sensitivity=False leaves them out).

Lags are built by lag_merge (a merge on ym - k within `keys`), never by shift(): a month absent from the source
leaves the lag NaN.

Hand-off: data/derived/hmis/hmis_model.csv (tracked; ruling F2: never data/derived/model/). One row per unit x
month, 34 units x April 2012..March 2021 (108 months); missing is empty, never 0. Columns (model_columns()):
- the panel columns (panel.panel_columns(): unit_id, fy, year, month, ym, era, per indicator <ind>, <ind>_raw,
  <ind>_scaled, <ind>_allcomp, <ind>_masklow (ruling F41 "mask lows" sensitivity), comp_<ind>, n_districts_<ind>,
  flag_<ind>; status_date_min/max);
- in_primary (1 for April 2012..February 2020, 95 months), small_unit (1 for SMALL_UNITS);
- moy (calendar month 1-12), t_months (0 at April 2012), t_c = (t_months - 47) / 12 (a linear
  reparameterisation of t_months for numerical stability), sin12 = sin(2*pi*moy/12), cos12 = cos(2*pi*moy/12),
  era_e2 (1 from April 2017: the HMIS format-2017 era, FY2020-21 included; identical to hmis_format2017 and
  kept only as a descriptor: models use hmis_format2017, never both);
- the ENSO exposures of pipeline/hmis/exposure.py: oni, roni, nino34_3m, dmi_3m, en_t, ln_t, en_roni, ln_roni,
  en_n34, ln_n34, en_ep1415, en_ep1819, en_other; en_t_l0..en_t_l6 (en_t at ym - k);
- S_raw (Paper D hazard_rain: % of JJAS rain lost per +1 deg C ONI, 1981-2009), S_z (S_raw z-scored over the 32
  units with a value, ddof = 1; NA for AN and LD), en_S = en_t*S_z, ln_S = ln_t*S_z;
- <v>_l0, <v>_l1, <v>_l2 for v in CLIMATE_VARS (spi3, spi3_dry, spi3_wet, heatwave_days, tmax_anom at ym - k; AN
  rain terms NaN);
- per indicator: log1p_<ind>_lag12 (log1p of <ind> at ym - 12), <ind>_c75 (<ind>_raw where comp_<ind> >= 0.75,
  else NaN), <ind>_c00 (<ind>_raw, no completeness threshold);
- the programme indicators (PROGRAMME_INDICATORS, 0/1);
- pop_mid (population linearly interpolated between 1 March anchors to day 15 of the month), days (calendar
  days, February 2016 = 29), log_pop_days = log(pop_mid * days) (the primary offset);
- log_births, log_preg: the births-offset sensitivity (spec §3.7). SRS crude birth rates were not retrieved
  (SRS_STATUS), so both are NaN (ruling F23).
"""
import math
from pathlib import Path

import numpy as np
import pandas as pd

from pipeline.hmis import exposure as ex
from pipeline.hmis.crosswalk import INDICATORS
from pipeline.hmis.panel import PANEL_PATH, panel_columns
from pipeline.hmis.parse import era_for_fy
from pipeline.outcomes import states
from pipeline.paths import DERIVED, ROOT

HMIS_DIR = DERIVED / "hmis"
MODEL_PATH = HMIS_DIR / "hmis_model.csv"
CLIMATE_PATH = HMIS_DIR / "climate_unit_month.csv"
ENSO_PATH = DERIVED / "enso_monthly.csv"
POP_PATH = DERIVED / "model" / "population_2001_2027.csv"
RISK_INDEX = ROOT / "papers" / "D" / "output" / "risk_index.csv"
EVENTS_PATH = ROOT / "pipeline" / "reference" / "hmis_programme_events.csv"
EVENT_COLUMNS = ["event", "indicator", "start_ym", "end_ym", "applies_to", "source_url", "accessed", "note"]
PROGRAMME_INDICATORS = ("hmis_format2017", "demonet", "mi_round", "covid_mar2020", "covid_fy2021", "pmsma",
                        "laqshya", "diwali")
SENSITIVITY_ONLY = ("covid_fy2021", "pmsma", "laqshya", "diwali")      # spec §5.1, ruling F19
SMALL_UNITS = ("LD", "CH", "PY", "DNH_DD", "AN", "SK", "GA")
S_NA_UNITS = ("AN", "LD")
CLIMATE_VARS = ("spi3", "spi3_dry", "spi3_wet", "heatwave_days", "tmax_anom")
CLIMATE_LAGS = (0, 1, 2)
EN_LAGS = range(0, 7)
T_CENTRE = 47
SRS_STATUS = "not available (SRS not retrieved)"


def lag_merge(df: pd.DataFrame, cols, keys, k: int) -> pd.DataFrame:
    """df with `<col>_l<k>` = the value of `col` at ym - k within the same `keys`, by a merge (never shift())."""
    keys, cols = list(keys), list(cols)
    if df.duplicated(keys + ["ym"]).any():
        raise ValueError(f"lag_merge: duplicate {keys + ['ym']} rows")
    src = df[keys + ["ym"] + cols].copy()
    src["ym"] = src.ym + k
    src = src.rename(columns={c: f"{c}_l{k}" for c in cols})
    return df.merge(src, on=keys + ["ym"], how="left", validate="one_to_one")


def _ym_text(s) -> float:
    if s is None or (isinstance(s, float) and math.isnan(s)) or str(s).strip() == "":
        return math.inf
    y, m = str(s).strip().split("-")
    return float(ex.ym_of(int(y), int(m)))


def read_events(path=EVENTS_PATH) -> pd.DataFrame:
    ev = pd.read_csv(path, dtype=str, keep_default_na=False).replace({"": np.nan})
    if list(ev.columns) != EVENT_COLUMNS:
        raise ValueError(f"{path}: columns {list(ev.columns)} != {EVENT_COLUMNS}")
    return ev


def programme_indicators(yms, events: pd.DataFrame) -> pd.DataFrame:
    unknown = set(events.indicator) - set(PROGRAMME_INDICATORS)
    if unknown:
        raise ValueError(f"unknown programme indicator(s) {sorted(unknown)}")
    t = np.asarray(list(yms), dtype=int)
    out = pd.DataFrame({"ym": t})
    for ind in PROGRAMME_INDICATORS:
        on = np.zeros(len(t), dtype=bool)
        for r in events[events.indicator == ind].itertuples():
            start, end = _ym_text(r.start_ym), _ym_text(r.end_ym)
            if start == math.inf or end < start:
                raise ValueError(f"bad month range for {ind}: {r.start_ym!r}..{r.end_ym!r}")
            on |= (t >= start) & (t <= end)
        out[ind] = on.astype(int)
    return out


def programme_terms_for(indicator: str, include_sensitivity: bool = True, events=None) -> list[str]:
    """The programme columns (in PROGRAMME_INDICATORS order) whose events apply to the HMIS outcome `indicator`,
    from `applies_to` ("all" or ";"-joined outcomes). With include_sensitivity=False the SENSITIVITY_ONLY terms
    are left out (the primary-model set). Raises ValueError for an unknown outcome or applies_to token."""
    if indicator not in INDICATORS:
        raise ValueError(f"unknown HMIS indicator {indicator!r}")
    ev = read_events() if events is None else events
    terms = set()
    for r in ev.itertuples():
        targets = {s.strip() for s in str(r.applies_to).split(";") if s.strip()}
        bad = targets - set(INDICATORS) - {"all"}
        if bad:
            raise ValueError(f"unknown applies_to token(s) {sorted(bad)} for {r.indicator}")
        if "all" in targets or indicator in targets:
            terms.add(r.indicator)
    if not include_sensitivity:
        terms -= set(SENSITIVITY_ONLY)
    return [c for c in PROGRAMME_INDICATORS if c in terms]


def offsets(units, yms, pop: pd.DataFrame) -> pd.DataFrame:
    """pop_mid: population on day 15 of the month, linear between the 1 March anchors (no extrapolation: NaN
    outside the anchors); days: calendar days in the month; log_pop_days = log(pop_mid * days)."""
    t = np.asarray(list(yms), dtype=int)
    year, month = t // 12, t % 12 + 1
    mid = pd.to_datetime(pd.DataFrame({"year": year, "month": month, "day": 15})).to_numpy()
    days = pd.PeriodIndex.from_fields(year=year, month=month, freq="M").days_in_month.to_numpy()
    rows = []
    for u in units:
        p = pop[pop.unit_id == u].sort_values("year")
        if p.empty:
            raise KeyError(f"no population rows for unit {u}")
        anchors = pd.to_datetime(pd.DataFrame({"year": p.year, "month": 3, "day": 1})).to_numpy()
        x = (mid - anchors[0]) / np.timedelta64(1, "D")
        xa = (anchors - anchors[0]) / np.timedelta64(1, "D")
        pm = np.interp(x, xa, p.population.to_numpy(dtype=float), left=np.nan, right=np.nan)
        rows.append(pd.DataFrame({"unit_id": u, "ym": t, "pop_mid": pm, "days": days,
                                  "log_pop_days": np.log(pm * days)}))
    return pd.concat(rows, ignore_index=True)[["unit_id", "ym", "pop_mid", "days", "log_pop_days"]]


def sensitivity_s(path=RISK_INDEX) -> pd.DataFrame:
    r = pd.read_csv(path, usecols=["unit_id", "hazard_rain"])
    s = pd.DataFrame({"unit_id": states.UNITS}).merge(r, on="unit_id", how="left", validate="one_to_one")
    missing = set(states.UNITS) - set(r.unit_id)
    if missing:
        raise KeyError(f"{path}: units missing {sorted(missing)}")
    s["S_raw"] = s.hazard_rain.where(~s.unit_id.isin(S_NA_UNITS))
    ok = s.S_raw.notna()
    s["S_z"] = (s.S_raw - s.S_raw[ok].mean()) / s.S_raw[ok].std(ddof=1)
    return s[["unit_id", "S_raw", "S_z"]]


def model_columns() -> list[str]:
    cols = panel_columns() + ["in_primary", "small_unit", "moy", "t_months", "t_c", "sin12", "cos12", "era_e2"]
    cols += ex.EXPOSURE_COLUMNS[1:] + [f"en_t_l{k}" for k in EN_LAGS]
    cols += ["S_raw", "S_z", "en_S", "ln_S"]
    cols += [f"{v}_l{k}" for v in CLIMATE_VARS for k in CLIMATE_LAGS]
    for i in INDICATORS:
        cols += [f"log1p_{i}_lag12", f"{i}_c75", f"{i}_c00"]
    return cols + list(PROGRAMME_INDICATORS) + ["pop_mid", "days", "log_pop_days", "log_births", "log_preg"]


def _fy(ym: pd.Series) -> pd.Series:
    y = ym // 12 - (ym % 12 + 1 < 4)
    return y.astype(str) + "-" + ((y + 1) % 100).map("{:02d}".format)


def build_model_table(out=MODEL_PATH, panel_path=PANEL_PATH, climate_path=CLIMATE_PATH, enso_path=ENSO_PATH,
                      pop_path=POP_PATH, risk_path=RISK_INDEX, events_path=EVENTS_PATH) -> Path:
    yms = np.arange(ex.PRIMARY_START, ex.FY2021_END + 1)
    units = sorted(states.UNITS)
    grid = pd.DataFrame([(u, t) for u in units for t in yms], columns=["unit_id", "ym"])
    panel = pd.read_csv(panel_path, dtype={"fy": str, "unit_id": str})
    if list(panel.columns) != panel_columns():
        raise ValueError(f"{panel_path}: columns differ from panel.panel_columns()")
    if panel.duplicated(["unit_id", "ym"]).any():
        raise ValueError(f"{panel_path}: duplicate unit-months")
    m = grid.merge(panel, on=["unit_id", "ym"], how="left", validate="one_to_one")
    year, month, fy = m.ym // 12, m.ym % 12 + 1, _fy(m.ym)
    have = m.fy.notna()
    if not ((m.year[have] == year[have]).all() and (m.month[have] == month[have]).all()
            and (m.fy[have] == fy[have]).all()):
        raise ValueError("panel year/month/fy disagree with ym")
    m["year"], m["month"], m["fy"] = year, month, fy
    m["era"] = m.era.where(have, m.fy.map(era_for_fy))
    m = m[panel_columns()]
    for i in INDICATORS:                      # counts stay integers (as in the panel file) despite NaN rows
        m[f"n_districts_{i}"] = m[f"n_districts_{i}"].astype("Int64")

    m["in_primary"] = m.ym.between(ex.PRIMARY_START, ex.PRIMARY_END).astype(int)
    m["small_unit"] = m.unit_id.isin(SMALL_UNITS).astype(int)
    m["moy"] = m.month.astype(int)
    m["t_months"] = m.ym - ex.PRIMARY_START
    m["t_c"] = (m.t_months - T_CENTRE) / 12
    m["sin12"] = np.sin(2 * np.pi * m.moy / 12)
    m["cos12"] = np.cos(2 * np.pi * m.moy / 12)
    m["era_e2"] = (m.ym >= ex.ym_of(2017, 4)).astype(int)    # == hmis_format2017; models use hmis_format2017 only

    e = ex.enso_exposures(pd.read_csv(enso_path), np.arange(ex.PRIMARY_START - max(EN_LAGS), ex.FY2021_END + 1))
    for k in EN_LAGS:
        e = lag_merge(e, ["en_t"], [], k)
    m = m.merge(e, on="ym", how="left", validate="many_to_one")

    m = m.merge(sensitivity_s(risk_path), on="unit_id", how="left", validate="many_to_one")
    m["en_S"] = m.en_t * m.S_z
    m["ln_S"] = m.ln_t * m.S_z

    cl = pd.read_csv(climate_path)[["unit_id", "ym"] + list(CLIMATE_VARS)]
    for k in CLIMATE_LAGS:
        cl = lag_merge(cl, CLIMATE_VARS, ["unit_id"], k)
    lagged = [f"{v}_l{k}" for v in CLIMATE_VARS for k in CLIMATE_LAGS]
    m = m.merge(cl[["unit_id", "ym"] + lagged], on=["unit_id", "ym"], how="left", validate="one_to_one")

    l12 = lag_merge(m[["unit_id", "ym"] + list(INDICATORS)], INDICATORS, ["unit_id"], 12)
    for i in INDICATORS:
        m[f"log1p_{i}_lag12"] = np.log1p(l12[f"{i}_l12"].to_numpy())
        m[f"{i}_c75"] = m[f"{i}_raw"].where(m[f"comp_{i}"] >= 0.75)
        m[f"{i}_c00"] = m[f"{i}_raw"]

    m = m.merge(programme_indicators(yms, read_events(events_path)), on="ym", how="left", validate="many_to_one")
    pop = pd.read_csv(pop_path)
    m = m.merge(offsets(units, yms, pop), on=["unit_id", "ym"], how="left", validate="one_to_one")
    m["log_births"] = np.nan          # SRS_STATUS (ruling F23)
    m["log_preg"] = np.nan

    m = m[model_columns()].sort_values(["unit_id", "ym"]).reset_index(drop=True)
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    m.to_csv(out, index=False)
    return out


def primary_nan_share(path=MODEL_PATH) -> pd.DataFrame:
    """NaN share of each outcome column over the primary window (34 x 95 unit-months)."""
    m = pd.read_csv(path, dtype={"fy": str})
    p = m[m.in_primary == 1]
    rows = []
    for i in INDICATORS:
        for c in (i, f"{i}_masklow", f"{i}_c75", f"{i}_c00"):
            rows.append({"outcome": c, "n": len(p), "nan": int(p[c].isna().sum()), "nan_share": p[c].isna().mean()})
    return pd.DataFrame(rows)
