"""State-level validation: our district JJAS rain aggregated to IMD meteorological subdivisions and compared
with IMD's official sub-divisional series (data.gov.in "Sub Divisional Monthly Rainfall from 1901 to 2017").

District -> subdivision assignment: pipeline/reference/district_to_imd_subdivision.csv (built by
tools/build_subdivision_map.py from IMD's district list). Aggregation is area-weighted with each district's
land area (sum of its 0.25 deg cell-intersection areas, data/derived/_parts/weights_r025_district.csv).
"""
from pathlib import Path

import numpy as np
import pandas as pd

from pipeline.paths import DERIVED, EXTERNAL

REF = Path(__file__).parent / "reference"
IMD_SUBDIVISION_CSV = EXTERNAL / "imd_subdivision" / "Sub_Division_IMD_2017.csv"
MAPPING = REF / "district_to_imd_subdivision.csv"
SUBDIVISION_REVIEWED = REF / "subdivision_reviewed.csv"
MIN_AREA_FRAC = 0.5          # subdivision-year needs data (not QC-masked) for >= 50% of its district area
OVERLAP = (1981, 2017)
MIN_R = 0.7
EXPECTED_SUBDIVISIONS = 35   # 36 IMD subdivisions minus Andaman & Nicobar (no valid grid cell; masked every year)


def read_imd_subdivisions(path=IMD_SUBDIVISION_CSV) -> pd.DataFrame:
    """Official JJAS totals (mm) per subdivision-year; NA values dropped."""
    d = pd.read_csv(path)
    out = d[["SUBDIVISION", "YEAR", "JJAS"]].rename(
        columns={"SUBDIVISION": "subdivision", "YEAR": "year", "JJAS": "imd_jjas_mm"}).dropna()
    out["year"] = out.year.astype(int)
    return out.reset_index(drop=True)


def read_mapping(path=MAPPING, expected=666) -> pd.DataFrame:
    m = pd.read_csv(path, dtype={"region_id": str})
    if len(m) != expected:
        raise ValueError(f"{path}: {len(m)} districts, expected {expected}")
    if m.region_id.duplicated().any():
        raise ValueError(f"{path}: duplicate region_id {sorted(m.region_id[m.region_id.duplicated()])[:5]}")
    blank = m.imd_subdivision.isna() | (m.imd_subdivision.astype(str).str.strip() == "")
    if blank.any():
        raise ValueError(f"{path}: no subdivision for {sorted(m.region_id[blank])[:5]}")
    return m


def district_areas(parts_dir=DERIVED / "_parts") -> pd.Series:
    return pd.read_csv(Path(parts_dir) / "weights_r025_district.csv").groupby("region_id").area_km2.sum()


def aggregate(district_year: pd.DataFrame, mapping: pd.DataFrame, areas: pd.Series, col="rain_jjas_mm",
              min_area_frac=MIN_AREA_FRAC) -> pd.DataFrame:
    """Area-weighted subdivision means of `col` over districts with data; subdivision-years where the
    districts with data cover < min_area_frac of the subdivision's area are dropped."""
    d = district_year[["region_id", "year", col]].merge(mapping[["region_id", "imd_subdivision"]], on="region_id")
    d["area"] = d.region_id.map(areas).astype(float)
    if d.area.isna().any():
        raise ValueError(f"no area for districts {sorted(d.region_id[d.area.isna()].unique())[:5]}")
    total = mapping.assign(area=mapping.region_id.map(areas)).groupby("imd_subdivision").area.sum()
    ok = d.dropna(subset=[col])
    g = ok.assign(wv=ok[col] * ok.area).groupby(["imd_subdivision", "year"])[["wv", "area"]].sum()
    out = pd.DataFrame({"ours_mm": g.wv / g.area,
                        "area_frac": g.area / total.reindex(g.index.get_level_values(0)).to_numpy()})
    out = out[out.area_frac >= min_area_frac - 1e-12].reset_index().rename(columns={"imd_subdivision": "subdivision"})
    return out[["subdivision", "year", "ours_mm", "area_frac"]]


def compare(ours: pd.DataFrame, imd: pd.DataFrame, years=OVERLAP, min_years=10) -> pd.DataFrame:
    """Per subdivision over `years`: Pearson r and mean ratio (ours / IMD) of JJAS totals (ascending r)."""
    m = ours.merge(imd, on=["subdivision", "year"])
    m = m[m.year.between(*years)]
    rows = []
    for s, g in m.groupby("subdivision"):
        if len(g) < min_years:
            continue
        rows.append({"subdivision": s, "n_years": len(g), "first_year": int(g.year.min()),
                     "last_year": int(g.year.max()), "r": float(np.corrcoef(g.ours_mm, g.imd_jjas_mm)[0, 1]),
                     "mean_ratio": float((g.ours_mm / g.imd_jjas_mm).mean())})
    cols = ["subdivision", "n_years", "first_year", "last_year", "r", "mean_ratio"]
    return pd.DataFrame(rows, columns=cols).sort_values("r").reset_index(drop=True)


def read_reviewed(path=SUBDIVISION_REVIEWED) -> pd.DataFrame:
    """Subdivisions whose low correlation was reviewed (subdivision, reason, evidence); empty if absent."""
    path = Path(path)
    if not path.exists():
        return pd.DataFrame(columns=["subdivision", "reason", "evidence"])
    r = pd.read_csv(path)
    bad = r.reason.isna() | (r.reason.astype(str).str.strip() == "")
    if bad.any():
        raise ValueError(f"{path}: missing reason for {r.subdivision[bad].tolist()}")
    return r


def table(derived=DERIVED, imd_path=IMD_SUBDIVISION_CSV, mapping_path=MAPPING, expected=666):
    """(comparison table, merged subdivision-year frame) from the masked district annual table."""
    d = Path(derived)
    dy = pd.read_csv(d / "climate_district_year.csv", usecols=["region_id", "year", "rain_jjas_mm"])
    mapping = read_mapping(mapping_path, expected)
    ours = aggregate(dy, mapping, district_areas(d / "_parts"))
    imd = read_imd_subdivisions(imd_path)
    merged = ours.merge(imd, on=["subdivision", "year"])
    return compare(ours, imd), merged[merged.year.between(*OVERLAP)].reset_index(drop=True)
