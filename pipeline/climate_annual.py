"""Annual climate exposures and SPI from region-month tables."""
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

from pipeline.build_climate import LEVELS
from pipeline.paths import DERIVED, month_table

BASE = (1981, 2010)                      # normals, SPI fits and QC medians
NORMAL_PERIOD = f"{BASE[0]}–{BASE[1]}"
QC_REVIEWED = Path(__file__).parent / "reference" / "qc_reviewed.csv"
# A reviewed "mask" on a variable also blanks the exposures derived from the same rainfall.
QC_DEPENDANTS = {
    "rain_jjas_mm": ("rain_jjas_mm", "spi3_sep", "onset_doy"),       # dep_pct / onset_anom follow
    "rain_annual_mm": ("rain_annual_mm", "spi12_dec"),
}
QC_COLUMNS = ["level", "region_id", "region_name", "year", "variable", "ratio", "disposition", "reason", "evidence"]
# Calendar months of the monthly rain series covered by a reviewed mask on each variable.
QC_MONTHS = {"rain_jjas_mm": (6, 7, 8, 9), "rain_annual_mm": tuple(range(1, 13))}
RAIN_MONTH_COLUMNS = ("rain_mm", "rainy_days")      # blanked in masked region-months; temperature is untouched
# District-mask propagation to state/country (infill_masked_districts): mask the parent region-year instead
# of infilling when masked districts cover > MAX_MASKED_SHARE of its valid area or leave < MIN_REST_KM2.
MAX_MASKED_SHARE = 0.5
MIN_REST_KM2 = 1000.0
PROPAGATION_FILE = "qc_district_mask_propagation.csv"     # (level, region_id, year, variable) actions
ADJUSTMENTS_FILE = "qc_month_adjustments.csv"             # (level, region_id, year, month) infilled/masked rain
ADJ_COLUMNS = ["region_id", "year", "month", "action", "rain_mm", "masked_share", "rest_area_km2"]
SUMMARY_COLUMNS = ["region_id", "year", "variable", "action", "n_masked_districts"]


def read_qc_reviewed(path=QC_REVIEWED) -> pd.DataFrame:
    """The reviewed QC list (pipeline/reference/qc_reviewed.csv); empty frame if absent."""
    path = Path(path)
    if not path.exists():
        return pd.DataFrame(columns=QC_COLUMNS)
    q = pd.read_csv(path, dtype={"region_id": str, "level": str, "variable": str, "disposition": str})
    missing = set(QC_COLUMNS) - set(q.columns)
    if missing:
        raise ValueError(f"{path}: missing columns {sorted(missing)}")
    bad = set(q.disposition) - {"keep", "mask"}
    if bad:
        raise ValueError(f"{path}: disposition must be keep or mask, got {sorted(bad)}")
    unknown = set(q.variable) - set(QC_DEPENDANTS)
    if unknown:
        raise ValueError(f"{path}: unknown qc variable(s) {sorted(unknown)}")
    dup = q[q.duplicated(["level", "region_id", "year", "variable"], keep=False)]
    if len(dup):
        keys = sorted({f"{r.level} {r.region_id} {r.year} {r.variable}" for r in dup.itertuples()})
        raise ValueError(f"{path}: duplicate (level, region_id, year, variable) rows: " + "; ".join(keys[:10]))
    return q


def qc_mask_for_level(level: str, path=QC_REVIEWED) -> pd.DataFrame:
    q = read_qc_reviewed(path)
    return q[(q.level == level) & (q.disposition == "mask")][["region_id", "year", "variable"]].reset_index(drop=True)


def _check_qc_variables(qc_mask) -> None:
    unknown = set(qc_mask.variable) - set(QC_DEPENDANTS)
    if unknown:
        raise ValueError(f"unknown qc variable(s) {sorted(unknown)}")


def mask_months(month: pd.DataFrame, qc_mask) -> pd.DataFrame:
    """Copy of a region-month table with the rain columns (RAIN_MONTH_COLUMNS) set to NaN in masked
    region-months and a boolean `qc_masked` column. `qc_mask` has region_id, year, variable: a mask on
    rain_annual_mm covers all 12 months of that year, a mask on rain_jjas_mm covers Jun-Sep (QC_MONTHS)."""
    out = month.copy()
    out["qc_masked"] = False
    if qc_mask is None or len(qc_mask) == 0:
        return out
    _check_qc_variables(qc_mask)
    keys = pd.MultiIndex.from_tuples(
        {(str(m.region_id), int(m.year), mo) for m in qc_mask.itertuples() for mo in QC_MONTHS[m.variable]})
    rows = pd.MultiIndex.from_arrays([out.region_id.astype(str), out.year.astype(int), out.month.astype(int)])
    flag = rows.isin(keys)
    out["qc_masked"] = flag
    cols = [c for c in RAIN_MONTH_COLUMNS if c in out]
    out.loc[flag, cols] = np.nan
    return out


def apply_qc_to_month(month: pd.DataFrame, level: str, path=QC_REVIEWED, derived=DERIVED) -> pd.DataFrame:
    """Region-month table of `level` with the reviewed QC masks applied.

    district: rain_mm/rainy_days NaN and qc_masked True in masked region-months (mask_months).
    state / country: additionally applies the district-mask propagation written by build_all
    (<derived>/qc_month_adjustments.csv): infilled region-months get the infilled rain_mm, rainy_days NaN and
    qc_infilled True; masked ones get NaN rain and qc_masked True; then the level's own reviewed masks.
    Raises FileNotFoundError if the adjustments file is missing and ValueError for any other level, so
    contaminated values are never returned silently."""
    if level == "district":
        return mask_months(month, qc_mask_for_level(level, path))
    if level not in ("state", "country"):
        raise ValueError(f"apply_qc_to_month: unsupported level {level!r}")
    adj_path = Path(derived) / ADJUSTMENTS_FILE
    if not adj_path.exists():
        raise FileNotFoundError(f"{adj_path} (run pipeline.climate_annual.build_all)")
    adj = pd.read_csv(adj_path, dtype={"region_id": str})
    adj = adj[adj.level == level]
    out = month.copy()
    rows = pd.MultiIndex.from_arrays([out.region_id.astype(str), out.year.astype(int), out.month.astype(int)])
    keys = pd.MultiIndex.from_arrays([adj.region_id.astype(str), adj.year.astype(int), adj.month.astype(int)])
    lookup = pd.Series(np.arange(len(adj), dtype=float), index=keys)
    pos = lookup.reindex(rows).to_numpy()
    hit = ~np.isnan(pos)
    act = np.full(len(out), "", dtype=object)
    val = np.full(len(out), np.nan)
    act[hit] = adj.action.to_numpy()[pos[hit].astype(int)]
    val[hit] = adj.rain_mm.to_numpy()[pos[hit].astype(int)]
    infilled, masked = act == "infilled", act == "masked"
    out.loc[infilled, "rain_mm"] = val[infilled]
    cols = [c for c in RAIN_MONTH_COLUMNS if c in out]
    out.loc[masked, cols] = np.nan
    if "rainy_days" in out:
        out.loc[infilled, "rainy_days"] = np.nan
    out = mask_months(out, qc_mask_for_level(level, path))
    out["qc_masked"] = out.qc_masked.to_numpy() | masked
    out["qc_infilled"] = infilled & ~out.qc_masked.to_numpy()
    return out


def monthly_climatology(grids_dir, base=BASE) -> np.ndarray:
    """(12, nlat, nlon) mean monthly rain per cell over the base-period years whose
    rain_monthly_<year>.npz exists in grids_dir (NaN-ignoring); FileNotFoundError if none."""
    grids_dir = Path(grids_dir)
    files = [grids_dir / f"rain_monthly_{y}.npz" for y in range(base[0], base[1] + 1)]
    files = [f for f in files if f.exists()]
    if not files:
        raise FileNotFoundError(f"no rain_monthly_<year>.npz for {base[0]}-{base[1]} in {grids_dir}")
    stack = []
    for f in files:
        with np.load(f) as z:
            stack.append(z["rain"].astype(float))
    with np.errstate(invalid="ignore"), warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        return np.nanmean(np.stack(stack), axis=0)


def infill_masked_districts(month: pd.DataFrame, district_mask, grids_dir, region_weights: pd.DataFrame,
                            district_weights: pd.DataFrame, climatology: np.ndarray, district_region,
                            max_share=MAX_MASKED_SHARE, min_rest_km2=MIN_REST_KM2):
    """Propagate reviewed district masks to a parent level (state or country) on the 0.25 deg grid.

    For every parent region-month containing masked districts with valid cells, the masked districts' cells
    (their intersection areas, district_weights.area_km2) are infilled at the rest of the region's ratio to
    normal: value = R x N_all / N_rest, where R is the area-weighted mean of the region's remaining valid cells
    and N_all, N_rest are the area-weighted base-period climatologies (monthly_climatology) of all valid
    cells and of the remaining cells. (Plain exclusion with area renormalisation would infill the masked area
    at the region mean, biasing the total wherever its normal differs, e.g. Tamil Nadu's low JJAS normal.)
    If the masked share of the region's valid area exceeds `max_share`, or the unmasked remainder is below
    `min_rest_km2`, the region-month is masked (NaN) instead; a variable (QC_MONTHS) with any masked month is
    masked for all its months. Districts with no valid cell (e.g. Andaman and Nicobar, nearest-cell fallback)
    are not in the grid aggregate and need nothing ("no_valid_cells").

    `district_region` maps district region_id -> parent region_id. Returns (month table with rain_mm replaced
    and rainy_days NaN in infilled months / rain NaN in masked months, monthly adjustments [ADJ_COLUMNS],
    summary per (region_id, year, variable) [SUMMARY_COLUMNS]; action infilled / masked / no_valid_cells)."""
    out = month.copy()
    empty = (out, pd.DataFrame(columns=ADJ_COLUMNS), pd.DataFrame(columns=SUMMARY_COLUMNS))
    if district_mask is None or len(district_mask) == 0:
        return empty
    _check_qc_variables(district_mask)
    region_of = {str(k): str(v) for k, v in dict(district_region).items()}
    dm = district_mask.assign(region_id=district_mask.region_id.astype(str), year=district_mask.year.astype(int))
    unknown = sorted(set(dm.region_id) - set(region_of))
    if unknown:
        raise ValueError(f"districts without a parent region: {unknown[:5]}")
    dm["parent"] = dm.region_id.map(region_of)
    grids_dir = Path(grids_dir)
    rw = region_weights.assign(region_id=region_weights.region_id.astype(str)).groupby(
        ["region_id", "ilat", "ilon"]).area_km2.sum()
    dwt = district_weights.assign(region_id=district_weights.region_id.astype(str))
    adj_rows, summ_rows = [], []
    for y, gy in dm.groupby("year"):
        with np.load(grids_dir / f"rain_monthly_{y}.npz") as z:
            grid = z["rain"].astype(float)
        for rid, g in gy.groupby("parent"):
            cells = rw.loc[rid] if rid in rw.index.get_level_values(0) else pd.Series(dtype=float)
            il, jl = cells.index.get_level_values(0).to_numpy(), cells.index.get_level_values(1).to_numpy()
            months = {}
            for m in g.itertuples():
                for mo in QC_MONTHS[m.variable]:
                    months.setdefault(mo, set()).add(m.region_id)
            res = {}
            for mo, dists in months.items():
                f, c = grid[mo - 1], climatology[mo - 1]
                x, n = f[il, jl], c[il, jl]
                ok = np.isfinite(x) & np.isfinite(n)
                a_all = cells.to_numpy() * ok
                dw = dwt[dwt.region_id.isin(dists)]
                m_area = dw.groupby(["ilat", "ilon"]).area_km2.sum().reindex(cells.index, fill_value=0.0).to_numpy()
                m_area = np.minimum(m_area, cells.to_numpy()) * ok
                masked_total, total = float(m_area.sum()), float(a_all.sum())
                if masked_total <= 0:
                    continue
                rest = total - masked_total
                share = masked_total / total
                if share > max_share or rest < min_rest_km2 or rest <= 0:
                    res[mo] = ("masked", np.nan, share, rest)
                    continue
                a_rest = a_all - m_area
                xz, nz = np.where(ok, x, 0.0), np.where(ok, n, 0.0)
                r_rest = (a_rest * xz).sum() / a_rest.sum()
                n_rest = (a_rest * nz).sum() / a_rest.sum()
                n_all = (a_all * nz).sum() / total
                res[mo] = ("infilled", r_rest * n_all / n_rest if n_rest > 0 else r_rest, share, rest)
            masked_months = set()
            for var, gv in g.groupby("variable"):
                vm = [mo for mo in QC_MONTHS[var] if mo in res]
                action = ("no_valid_cells" if not vm else
                          "masked" if any(res[mo][0] == "masked" for mo in vm) else "infilled")
                if action == "masked":
                    masked_months |= set(QC_MONTHS[var])
                summ_rows.append((rid, int(y), var, action, int(gv.region_id.nunique())))
            for mo in range(1, 13):
                if mo in masked_months:
                    share, rest = res.get(mo, (None, None, np.nan, np.nan))[2:]
                    action, value = "masked", np.nan
                elif mo in res:
                    action, value, share, rest = res[mo]
                else:
                    continue
                sel = (out.region_id.astype(str) == rid) & (out.year == y) & (out.month == mo)
                out.loc[sel, "rain_mm"] = value
                if "rainy_days" in out:
                    out.loc[sel, "rainy_days"] = np.nan
                adj_rows.append((rid, int(y), mo, action, value, share, rest))
    adj = pd.DataFrame(adj_rows, columns=ADJ_COLUMNS)
    summ = pd.DataFrame(summ_rows, columns=SUMMARY_COLUMNS).sort_values(["region_id", "year", "variable"])
    return out, adj, summ.reset_index(drop=True)


def _apply_qc_mask(a: pd.DataFrame, qc_mask) -> pd.DataFrame:
    a = a.copy()
    a["qc_masked"] = ""
    if qc_mask is None or len(qc_mask) == 0:
        return a
    _check_qc_variables(qc_mask)
    for m in qc_mask.itertuples():
        sel = (a.region_id == m.region_id) & (a.year == int(m.year))
        a.loc[sel, list(QC_DEPENDANTS[m.variable])] = np.nan
        a.loc[sel, "qc_masked"] = a.loc[sel, "qc_masked"].map(lambda t: m.variable if not t else f"{t};{m.variable}")
    return a


def spi(monthly: pd.Series, scale: int, base=BASE) -> pd.Series:
    acc = monthly.rolling(scale, min_periods=scale).sum()
    out = pd.Series(np.nan, index=monthly.index, dtype=float)
    years = acc.index.year
    for m in range(1, 13):
        sel = acc.index.month == m
        ref = acc[sel & (years >= base[0]) & (years <= base[1])].dropna()
        nonzero = ref[ref > 0]
        if len(nonzero) < 10 or nonzero.std() == 0:
            continue
        q = (ref == 0).mean()
        try:
            a, loc, b = stats.gamma.fit(nonzero, floc=0)
        except Exception:  # degenerate sample → SPI undefined for this month
            continue
        x = acc[sel]
        h = q + (1 - q) * stats.gamma.cdf(x.clip(lower=0), a, loc=0, scale=b)
        # Zero accumulations take the centre of the zero mass, H(0) = q/2 (Stagge JH et al. 2015,
        # Int J Climatol 35:4027-4040). H(0) = q would give totally dry months near-normal SPI
        # wherever zeros are common.
        h = np.where(x == 0, q / 2 if q > 0 else 1e-6, h)
        out[sel] = stats.norm.ppf(np.clip(h, 1e-6, 1 - 1e-6))
        out[sel & acc.isna()] = np.nan
    return out


def build_annual(month: pd.DataFrame, onset: pd.DataFrame, base=BASE, qc_mask=None) -> pd.DataFrame:
    """Annual exposures per region-year. `qc_mask` (region_id, year, variable) blanks reviewed
    artefacts (see QC_DEPENDANTS) before normals are computed; `qc_masked` lists what was blanked.
    Ruling R22: the monthly rain series fed to spi() has the masked months set to NaN (QC_MONTHS), so
    masked artefacts never enter the base-period gamma / zero-probability fits."""
    dup = month.duplicated(["region_id", "year", "month"], keep=False)
    if dup.any():
        raise ValueError(f"duplicate region-month rows: {int(dup.sum())} rows")
    month = month.copy()
    month["_rain_spi"] = mask_months(month[["region_id", "year", "month", "rain_mm"]], qc_mask).rain_mm.to_numpy()
    rows = []
    for rid, g in month.sort_values(["year", "month"]).groupby("region_id"):
        idx = pd.PeriodIndex.from_fields(year=g.year, month=g.month, freq="M")
        # Reindex to a contiguous month range so rolling windows never span a missing month.
        full = pd.period_range(idx.min(), idx.max(), freq="M")
        rain = pd.Series(g._rain_spi.to_numpy(), index=idx).reindex(full)
        s3, s12 = spi(rain, 3, base), spi(rain, 12, base)
        g = g.set_index(idx)
        for y, gy in g.groupby("year"):
            if len(gy) < 12:
                continue
            jjas = gy[gy.month.isin([6, 7, 8, 9])]
            mamj = gy[gy.month.isin([3, 4, 5, 6])]
            rows.append({
                "region_id": rid, "year": int(y),
                "rain_annual_mm": gy.rain_mm.sum(min_count=12),
                "rain_jjas_mm": jjas.rain_mm.sum(min_count=4),
                "spi3_sep": s3.get(pd.Period(f"{y}-09", "M")),
                "spi12_dec": s12.get(pd.Period(f"{y}-12", "M")),
                "tmax_mamj_mean": mamj.tmax_mean.mean() if mamj.tmax_mean.count() == 4 else np.nan,
                "tmax_ge40_days": gy.tmax_ge40_days.sum(min_count=12),
                "heatwave_days": gy.heatwave_days.sum(min_count=12),
                "tmin_mean": gy.tmin_mean.mean() if gy.tmin_mean.count() == 12 else np.nan,
            })
    a = pd.DataFrame(rows).merge(onset[["region_id", "year", "onset_doy"]], on=["region_id", "year"], how="left")
    a = _apply_qc_mask(a, qc_mask)
    in_base = a.year.between(*base)
    normals = a[in_base].groupby("region_id")[["rain_jjas_mm", "tmax_mamj_mean", "onset_doy"]].mean()
    a = a.merge(normals.add_suffix("_base"), left_on="region_id", right_index=True, how="left")
    a["rain_jjas_normal_mm"] = a.rain_jjas_mm_base
    a["rain_jjas_dep_pct"] = 100 * (a.rain_jjas_mm - a.rain_jjas_normal_mm) / a.rain_jjas_normal_mm
    a["tmax_mamj_anom"] = a.tmax_mamj_mean - a.tmax_mamj_mean_base
    a["onset_anom_days"] = a.onset_doy - a.onset_doy_base
    cols = ["region_id", "year", "rain_annual_mm", "rain_jjas_mm", "rain_jjas_normal_mm", "rain_jjas_dep_pct",
            "spi3_sep", "spi12_dec", "onset_doy", "onset_anom_days", "tmax_mamj_mean", "tmax_mamj_anom",
            "tmax_ge40_days", "heatwave_days", "tmin_mean", "qc_masked"]
    return a[cols].sort_values(["region_id", "year"]).reset_index(drop=True)


def _district_state(derived) -> dict:
    d = pd.read_csv(month_table("district", derived), usecols=["region_id", "state_id"]).drop_duplicates("region_id")
    return dict(zip(d.region_id.astype(str), d.state_id.astype(str)))


def build_all(levels=LEVELS, derived=DERIVED, qc_reviewed=QC_REVIEWED, grids_dir=None, parts_dir=None,
              district_state=None, max_share=MAX_MASKED_SHARE, min_rest_km2=MIN_REST_KM2) -> dict[str, Path]:
    """Annual tables per level. Country and state: reviewed district masks are propagated on the grid
    (infill_masked_districts): masked districts' cells are infilled at the rest of the region's ratio to its
    1981-2010 normal (qc_masked tag "district_masks_infilled:<variables>"), or the region-year variable is
    masked when the masked share is > max_share or the remainder < min_rest_km2 ("<variable>;
    district_masks_masked:<variables>"). Region-years already masked by a reviewed mask at that level are not
    re-tagged. Writes PROPAGATION_FILE and ADJUSTMENTS_FILE (used by apply_qc_to_month). Onset is not adjusted."""
    derived = Path(derived)
    grids_dir = Path(grids_dir) if grids_dir is not None else derived / "grids"
    parts_dir = Path(parts_dir) if parts_dir is not None else derived / "_parts"
    dmask = qc_mask_for_level("district", qc_reviewed)
    clim = None
    out, summaries, adjustments = {}, [], []
    for level in levels:
        month = pd.read_csv(month_table(level, derived))
        onset = pd.read_csv(derived / f"climate_{level}_onset.csv")
        qc = qc_mask_for_level(level, qc_reviewed)
        tags = {}
        if level in ("country", "state") and len(dmask):
            if clim is None:
                clim = monthly_climatology(grids_dir)
            if level == "country":
                parent = {str(d): str(month.region_id.iloc[0]) for d in dmask.region_id}
            else:
                parent = district_state if district_state is not None else _district_state(derived)
            month, adj, summ = infill_masked_districts(
                month, dmask, grids_dir, pd.read_csv(parts_dir / f"weights_r025_{level}.csv"),
                pd.read_csv(parts_dir / "weights_r025_district.csv"), clim, parent, max_share, min_rest_km2)
            reviewed = {(str(r.region_id), int(r.year), r.variable) for r in qc.itertuples()}
            summ["reviewed_mask"] = [(r.region_id, int(r.year), r.variable) in reviewed for r in summ.itertuples()]
            auto = summ[(summ.action == "masked") & ~summ.reviewed_mask]
            qc = pd.concat([qc, auto[["region_id", "year", "variable"]]], ignore_index=True)
            for r in summ[summ.action.isin(["infilled", "masked"]) & ~summ.reviewed_mask].itertuples():
                tags.setdefault((r.region_id, int(r.year)), {}).setdefault(r.action, []).append(r.variable)
            summaries.append(summ.assign(level=level))
            adjustments.append(adj.assign(level=level))
        a = build_annual(month, onset, qc_mask=qc)
        for (rid, y), acts in tags.items():
            sel = (a.region_id.astype(str) == rid) & (a.year == y)
            extra = ";".join(f"district_masks_{k}:" + ";".join(sorted(v)) for k, v in sorted(acts.items()))
            a.loc[sel, "qc_masked"] = a.loc[sel, "qc_masked"].map(lambda t: extra if not t else f"{t};{extra}")
        names = month[["region_id", "region_name", "state_id", "state_name"]].drop_duplicates("region_id")
        a = names.merge(a, on="region_id", how="right")
        out[level] = derived / f"climate_{level}_year.csv"
        a.to_csv(out[level], index=False)
    if summaries:
        cols = ["level"] + SUMMARY_COLUMNS + ["reviewed_mask"]
        pd.concat(summaries, ignore_index=True)[cols].to_csv(derived / PROPAGATION_FILE, index=False)
        pd.concat(adjustments, ignore_index=True)[["level"] + ADJ_COLUMNS].round(
            {"rain_mm": 4, "masked_share": 5, "rest_area_km2": 2}).to_csv(derived / ADJUSTMENTS_FILE, index=False)
    return out


if __name__ == "__main__":
    for k, p in build_all().items():
        print(k, p)
