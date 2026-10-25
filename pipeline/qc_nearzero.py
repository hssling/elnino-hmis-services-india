"""Cell-level near-zero-fill diagnostic for the IMD 0.25 deg rain grid (Phase 2 Task 0).

Ruling R19 masks cells whose annual total is exactly 0 mm. Some no-station fills are not exactly zero
(e.g. a constant 8 mm or 130 mm per year over a high-rainfall area). This diagnostic flags cell-years whose
annual total is below NEARZERO_FRAC of the cell's own 1981-2010 median annual total, and lists the state /
district region-years with at least NEARZERO_SHARE of their valid area in flagged cells. Each listed
region-year must be reviewed in pipeline/reference/qc_reviewed.csv (gate `nearzero_reviewed`).
"""
from pathlib import Path

import numpy as np
import pandas as pd

from pipeline import imd_grid
from pipeline.climate_annual import BASE
from pipeline.paths import DERIVED

NEARZERO_FRAC = 0.05      # cell-year annual total < 5% of the cell's own base-period median
NEARZERO_SHARE = 0.10     # region-year listed when >= 10% of its valid area is in flagged cells
CELL_COLUMNS = ["year", "ilat", "ilon", "lat", "lon", "annual_mm", "base_median_mm", "ratio"]
REGION_COLUMNS = ["level", "region_id", "year", "flagged_share", "n_flagged_cells", "est_bias_pct"]


def annual_cell_totals(grids_dir, years) -> np.ndarray:
    """(n_years, nlat, nlon) Jan-Dec totals from rain_monthly_<year>.npz; NaN where any month is NaN
    (sea, outside the grid's land mask, or R19-masked cell-years)."""
    grids_dir = Path(grids_dir)
    out = []
    for y in years:
        p = grids_dir / f"rain_monthly_{y}.npz"
        if not p.exists():
            raise FileNotFoundError(p)
        with np.load(p) as z:
            out.append(z["rain"].astype(float).sum(axis=0))
    return np.stack(out)


def _base_median(totals, years, base):
    sel = np.array([base[0] <= y <= base[1] for y in years])
    b = totals[sel]
    med = np.full(totals.shape[1:], np.nan)
    ok = np.isfinite(b).any(axis=0)
    med[ok] = np.nanmedian(b[:, ok], axis=0)
    return med


def nearzero_cells(totals, years, lats=imd_grid.RAIN.lats, lons=imd_grid.RAIN.lons, base=BASE,
                   frac=NEARZERO_FRAC) -> pd.DataFrame:
    """Cell-years (valid, not already R19-masked) with annual total < frac x the cell's base median."""
    med = _base_median(totals, years, base)
    with np.errstate(invalid="ignore", divide="ignore"):
        ratio = totals / med
    flag = np.isfinite(ratio) & (med > 0) & (ratio < frac)
    k, i, j = np.nonzero(flag)
    df = pd.DataFrame({"year": np.asarray(years)[k], "ilat": i, "ilon": j, "lat": np.asarray(lats)[i],
                       "lon": np.asarray(lons)[j], "annual_mm": totals[k, i, j], "base_median_mm": med[i, j],
                       "ratio": ratio[k, i, j]}, columns=CELL_COLUMNS)
    return df.sort_values(["year", "ilat", "ilon"]).reset_index(drop=True)


def region_shares(totals, years, cells: pd.DataFrame, weights: pd.DataFrame, level: str,
                  min_share=NEARZERO_SHARE, base=BASE) -> pd.DataFrame:
    """Region-years whose flagged cells cover >= min_share of the region's valid (non-NaN) weight.

    est_bias_pct: 100 x (region annual mean / counterfactual - 1), where the counterfactual replaces each
    flagged cell's total with its base median times the median ratio-to-base-median of the region's
    unflagged valid cells that year (NaN if the region has no unflagged valid cell)."""
    med = _base_median(totals, years, base)
    il, jl = weights.ilat.to_numpy(), weights.ilon.to_numpy()
    wt = weights.weight.to_numpy()
    rid = weights.region_id.to_numpy()
    rows = []
    for y in sorted(set(cells.year)):
        k = years.index(int(y))
        flagged = np.zeros(totals.shape[1:], dtype=bool)
        c = cells[cells.year == y]
        flagged[c.ilat.to_numpy(), c.ilon.to_numpy()] = True
        tot = totals[k][il, jl]
        valid = np.isfinite(tot)
        fl = flagged[il, jl] & valid
        d = pd.DataFrame({"region_id": rid, "wv": wt * valid, "wf": wt * fl, "fl": fl, "valid": valid,
                          "tot": np.where(valid, tot, 0.0), "med": med[il, jl], "w": wt})
        for r, g in d.groupby("region_id", sort=True):
            wv = g.wv.sum()
            if wv <= 0 or g.wf.sum() / wv < min_share:
                continue
            unf = g[g.valid & ~g.fl & (g.med > 0)]
            actual = (g.w * g.tot)[g.valid].sum() / wv
            if len(unf):
                scale = float(np.median(unf.tot / unf.med))
                cf_tot = np.where(g.fl, g.med * scale, g.tot)
                cf = (g.w * cf_tot)[g.valid].sum() / wv
                bias = 100 * (actual / cf - 1) if cf > 0 else np.nan
            else:
                bias = np.nan
            rows.append({"level": level, "region_id": r, "year": int(y), "flagged_share": g.wf.sum() / wv,
                         "n_flagged_cells": int(g.fl.sum()), "est_bias_pct": bias})
    return pd.DataFrame(rows, columns=REGION_COLUMNS).sort_values(["level", "region_id", "year"]).reset_index(drop=True)


def build(grids_dir=DERIVED / "grids", parts_dir=DERIVED / "_parts", out_dir=DERIVED, levels=("state", "district"),
          lats=imd_grid.RAIN.lats, lons=imd_grid.RAIN.lons) -> dict[str, Path]:
    """Write qc_rain_nearzero_cells.csv and qc_rain_nearzero_regions.csv to out_dir."""
    grids_dir, parts_dir, out_dir = Path(grids_dir), Path(parts_dir), Path(out_dir)
    years = sorted(int(p.stem.split("_")[-1]) for p in grids_dir.glob("rain_monthly_*.npz")
                   if p.stem.split("_")[-1].isdigit())
    if not years:
        raise FileNotFoundError(f"no rain_monthly_<year>.npz in {grids_dir}")
    totals = annual_cell_totals(grids_dir, years)
    cells = nearzero_cells(totals, years, lats, lons)
    parts = []
    for level in levels:
        w = pd.read_csv(parts_dir / f"weights_r025_{level}.csv")
        s = region_shares(totals, years, cells, w, level)
        names_path = out_dir / f"climate_{level}_year.csv"
        if names_path.exists():
            names = pd.read_csv(names_path, usecols=["region_id", "region_name"]).drop_duplicates("region_id")
            s = s.merge(names, on="region_id", how="left")
        else:
            s["region_name"] = ""
        parts.append(s)
    regions = pd.concat(parts, ignore_index=True)
    regions = regions[["level", "region_id", "region_name", "year", "flagged_share", "n_flagged_cells", "est_bias_pct"]]
    out = {"cells": out_dir / "qc_rain_nearzero_cells.csv", "regions": out_dir / "qc_rain_nearzero_regions.csv"}
    cells.round({"annual_mm": 2, "base_median_mm": 2, "ratio": 5}).to_csv(out["cells"], index=False)
    regions.round({"flagged_share": 4, "est_bias_pct": 2}).to_csv(out["regions"], index=False)
    return out


if __name__ == "__main__":
    for k, p in build().items():
        print(k, p)
