"""Resumable IMD build: temperature + rain grids → region-month tables (country/state/district)."""
import argparse
import os
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd

from pipeline import boundaries, climate_daily as cd, imd_grid
from pipeline import manifest as mf
from pipeline.grid_weights import Aggregator, compute_weights
from pipeline.paths import DERIVED, RAW

LEVELS = ("country", "state", "district")
_AGG: dict = {}
_REGIONS: dict = {}


def _write_csv(df: pd.DataFrame, path: Path) -> None:
    """Atomic write: a file at its final name is always complete."""
    tmp = path.with_name(path.name + ".tmp")
    # mtime=0 keeps gzip output byte-identical across rebuilds of the same data.
    df.to_csv(tmp, index=False,
              compression={"method": "gzip", "mtime": 0} if path.name.endswith(".gz") else None)
    os.replace(tmp, path)


def _regions(level):
    if level not in _REGIONS:
        _REGIONS[level] = boundaries.load(level)
    return _REGIONS[level]


def _aggregator(gridname, grid, level, parts_dir: Path) -> Aggregator:
    key = (gridname, level, str(parts_dir))
    if key not in _AGG:
        regs = _regions(level)
        wpath = parts_dir / f"weights_{gridname}_{level}.csv"
        if wpath.exists():
            w = pd.read_csv(wpath)
        else:
            w = compute_weights(grid, regs)
            wpath.parent.mkdir(parents=True, exist_ok=True)
            _write_csv(w, wpath)
        _AGG[key] = Aggregator(grid, regs, weights=w)
    return _AGG[key]


def _long(values12, region_ids, year, name):
    m = pd.DataFrame(values12, columns=region_ids)
    m["month"] = np.arange(1, 13)
    df = m.melt(id_vars="month", var_name="region_id", value_name=name)
    df["year"] = year
    return df


def _fetch_or_stop(fetch, var, year, raw_dir):
    try:
        return fetch(var, year, raw_dir)
    except imd_grid.IMDDownloadError:
        if year >= date.today().year - 1:
            print(f"NOTICE: IMD {var} {year} not available; stopping at {year - 1}")
            return None
        raise


def build_temperature(years, levels=LEVELS, base=(1981, 2010), raw_dir=RAW / "imd",
                      parts_dir=DERIVED / "_parts", fetch=imd_grid.download) -> None:
    raw_dir, parts_dir = Path(raw_dir), Path(parts_dir)
    parts_dir.mkdir(parents=True, exist_ok=True)
    todo = [y for y in years if not all((parts_dir / f"temp_{l}_{y}.csv").exists() for l in levels)]
    if not todo:
        return

    def get(var, y):
        p = raw_dir / f"{var}_{y}.grd"
        if not p.exists():
            p = _fetch_or_stop(fetch, var, y, raw_dir)
        return None if p is None else imd_grid.read(var, p, y)

    base_tmax = {}
    for y in range(base[0], base[1] + 1):
        a = get("tmax", y)
        if a is not None:
            base_tmax[y] = a
    clim = cd.tmax_climatology(base_tmax)
    for y in todo:
        tmax, tmin = get("tmax", y), get("tmin", y)
        if tmax is None or tmin is None:
            break
        fields = {
            "tmax_mean": cd.daily_to_monthly(tmax, y, "mean"),
            "tmin_mean": cd.daily_to_monthly(tmin, y, "mean"),
            "tmax_ge40_days": cd.monthly_counts(tmax >= 40, y).astype(float),
            "heatwave_days": cd.monthly_counts(cd.heatwave_mask(tmax, y, clim), y).astype(float),
        }
        valid = ~np.isnan(fields["tmax_mean"])
        for k in ("tmax_ge40_days", "heatwave_days"):
            fields[k][~valid] = np.nan
        for level in levels:
            agg = _aggregator("t100", imd_grid.TEMP, level, parts_dir)
            df = None
            for name, f in fields.items():
                part = _long(agg.apply(f), agg.region_ids, y, name)
                df = part if df is None else df.merge(part, on=["region_id", "year", "month"])
            df["fallback"] = df.region_id.isin(agg.fallback_regions)
            _write_csv(df, parts_dir / f"temp_{level}_{y}.csv")


def zero_annual_mask(daily: np.ndarray) -> np.ndarray:
    """(nlat, nlon) True where a cell has data but its annual total is exactly 0 mm.

    Ruling R19: IMD fills some cells with 0 in years without station support; a genuinely
    rainless 0.25 deg cell-year is implausible anywhere in India, so these cells are missing.
    """
    has_data = (~np.isnan(daily)).any(axis=0)
    return has_data & (np.nansum(daily, axis=0) == 0)


def _mask_summary(mask: np.ndarray, grid, year: int) -> pd.DataFrame:
    ii, jj = np.nonzero(mask)
    lats, lons = grid.lats[ii], grid.lons[jj]
    row = {"year": year, "n_cells": int(mask.sum()),
           "lat_min": lats.min() if lats.size else np.nan, "lat_max": lats.max() if lats.size else np.nan,
           "lon_min": lons.min() if lons.size else np.nan, "lon_max": lons.max() if lons.size else np.nan,
           "cells": ";".join(f"{a:.3f},{b:.3f}" for a, b in zip(lats, lons))}
    return pd.DataFrame([row])


def build_rain(years, levels=LEVELS, raw_dir=RAW / "imd", parts_dir=DERIVED / "_parts",
               grids_dir=DERIVED / "grids", fetch=imd_grid.download) -> None:
    raw_dir, parts_dir, grids_dir = Path(raw_dir), Path(parts_dir), Path(grids_dir)
    parts_dir.mkdir(parents=True, exist_ok=True)
    grids_dir.mkdir(parents=True, exist_ok=True)
    for y in years:
        done = all((parts_dir / f"rain_{l}_{y}.csv").exists() and (parts_dir / f"onset_{l}_{y}.csv").exists()
                   for l in levels) and (grids_dir / f"rain_monthly_{y}.npz").exists() \
            and (parts_dir / f"qcmask_rain_{y}.csv").exists()
        if done:
            continue
        p = raw_dir / f"rain_{y}.grd"
        if not p.exists():
            p = _fetch_or_stop(fetch, "rain", y, raw_dir)
            if p is None:
                break
        daily = imd_grid.read("rain", p, y)
        zero = zero_annual_mask(daily)
        daily[:, zero] = np.nan
        monthly = cd.daily_to_monthly(daily, y, "sum")
        rainy = cd.monthly_counts(daily >= cd.RAINY_DAY_MM, y).astype(float)
        rainy[np.isnan(monthly)] = np.nan
        tmp_npz = grids_dir / f"rain_monthly_{y}.tmp.npz"
        np.savez_compressed(tmp_npz, rain=monthly.astype(np.float32))
        os.replace(tmp_npz, grids_dir / f"rain_monthly_{y}.npz")
        for level in levels:
            agg = _aggregator("r025", imd_grid.RAIN, level, parts_dir)
            df = _long(agg.apply(monthly), agg.region_ids, y, "rain_mm").merge(
                _long(agg.apply(rainy), agg.region_ids, y, "rainy_days"), on=["region_id", "year", "month"])
            df["fallback"] = df.region_id.isin(agg.fallback_regions)
            _write_csv(df, parts_dir / f"rain_{level}_{y}.csv")
            reg_daily = agg.apply(daily)
            onset = [cd.onset_doy(reg_daily[:, k], y) for k in range(reg_daily.shape[1])]
            _write_csv(pd.DataFrame({"region_id": agg.region_ids, "year": y, "onset_doy": onset}),
                       parts_dir / f"onset_{level}_{y}.csv")
        _write_csv(_mask_summary(zero, imd_grid.RAIN, y), parts_dir / f"qcmask_rain_{y}.csv")
        p.unlink()
        mf.mark_deleted(p)


def assemble(levels=LEVELS, parts_dir=DERIVED / "_parts", out_dir=DERIVED) -> dict[str, Path]:
    parts_dir, out_dir = Path(parts_dir), Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out = {}
    keys = ["region_id", "year", "month"]
    for level in levels:
        cat = lambda pat: pd.concat([pd.read_csv(f) for f in sorted(parts_dir.glob(pat))], ignore_index=True)
        temp = cat(f"temp_{level}_*.csv").drop_duplicates(keys).rename(columns={"fallback": "fallback_temp"})
        rain = cat(f"rain_{level}_*.csv").drop_duplicates(keys).rename(columns={"fallback": "fallback_rain"})
        m = rain.merge(temp, on=keys, how="outer")
        names = _regions(level)[["region_id", "region_name", "state_id", "state_name"]]
        m = m.merge(names, on="region_id", how="left")
        m["source"] = "IMD"
        out[f"{level}_month"] = out_dir / (f"climate_{level}_month.csv.gz" if level == "district"
                                           else f"climate_{level}_month.csv")
        _write_csv(m.sort_values(keys), out[f"{level}_month"])
        other = out[f"{level}_month"]
        other = other.with_name(other.name[:-3] if other.name.endswith(".gz") else other.name + ".gz")
        other.unlink(missing_ok=True)
        on = cat(f"onset_{level}_*.csv").drop_duplicates(["region_id", "year"]).sort_values(["region_id", "year"])
        out[f"{level}_onset"] = out_dir / f"climate_{level}_onset.csv"
        _write_csv(on, out[f"{level}_onset"])
    qc = sorted(parts_dir.glob("qcmask_rain_*.csv"))
    if qc:
        out["qc_rain_masked_cells"] = out_dir / "qc_rain_masked_cells.csv"
        q = pd.concat([pd.read_csv(f, keep_default_na=False, na_values=[""]) for f in qc], ignore_index=True)
        _write_csv(q.sort_values("year"), out["qc_rain_masked_cells"])
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, default=1981)
    ap.add_argument("--end", type=int, default=date.today().year - 1)
    a = ap.parse_args()
    yrs = list(range(a.start, a.end + 1))
    build_temperature(yrs)
    build_rain(yrs)
    for k, p in assemble().items():
        print(k, p)
