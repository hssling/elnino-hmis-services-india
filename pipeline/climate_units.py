"""Unit-level climate exposures: climate_state_year pooled to the 34 outcome analysis units.

Each unit's value is the area-weighted mean over its member states (GADM state ids in
pipeline/reference/state_frame.csv) that have a non-NaN value for that column; the weights are
renormalised over those members, so a masked member drops out rather than counting as 0. A unit-year
column with no non-NaN member stays NaN. Only AP_TG (Andhra Pradesh + Telangana), JK (Jammu and Kashmir +
Ladakh) and DNH_DD (Dadra and Nagar Haveli + Daman and Diu) have more than one member; every other unit is
its single state's value (so masked single-member units stay NaN).

aggregate() pools over `keys` (default ("year",), the annual table; Paper E passes ("year", "month") for unit-months).
"""
from pathlib import Path

import numpy as np
import pandas as pd

from pipeline.outcomes import states
from pipeline.paths import DERIVED

NON_VALUE = ["region_id", "region_name", "state_id", "state_name", "year", "month", "qc_masked", "qc_infilled"]
OUT_NAME = "climate_unit_year.csv"


def state_areas(derived=DERIVED) -> dict:
    """Area (km2) per state region_id: sum of the r025 grid-overlap areas in _parts/weights_r025_state.csv,
    or, if that file is absent, recomputed from GADM (equal-area projection)."""
    w = Path(derived) / "_parts" / "weights_r025_state.csv"
    if w.exists():
        return pd.read_csv(w).groupby("region_id").area_km2.sum().to_dict()
    from pipeline import boundaries
    from pipeline.grid_weights import EQUAL_AREA
    g = boundaries.load("state")
    return dict(zip(g.region_id, g.geometry.to_crs(EQUAL_AREA).area / 1e6))


def aggregate(cy: pd.DataFrame, areas: dict, columns=None, keys=("year",)) -> pd.DataFrame:
    """Pool state rows to units within each combination of `keys` (default ("year",): state-year rows; Paper E
    passes ("year", "month")). Returns unit_id, `keys`, `columns`, n_members (member states present),
    n_members_used (members contributing a value, taken as the minimum over the columns that have any
    contributor; 0 when every column is NaN)."""
    keys = list(keys)
    if columns is None:
        columns = [c for c in cy.columns if c not in NON_VALUE]
    gid_unit = {g: u for u, ms in zip(states.frame().unit_id, states.frame().gid1_members) for g in ms}
    df = cy[["region_id"] + keys + list(columns)].copy()
    df["unit_id"] = df.region_id.map(gid_unit)
    if df.unit_id.isna().any():
        raise KeyError(f"regions not in the unit frame: {sorted(df.region_id[df.unit_id.isna()].unique())}")
    df["_w"] = df.region_id.map(areas)
    if df._w.isna().any():
        raise KeyError(f"no area for regions: {sorted(df.region_id[df._w.isna()].unique())}")
    rows = []
    for gkey, g in df.groupby(["unit_id"] + keys, sort=True):
        rec = {"unit_id": gkey[0]}
        rec.update({k: int(v) for k, v in zip(keys, gkey[1:])})
        counts = []
        for c in columns:
            ok = g[c].notna().to_numpy()
            w = g._w.to_numpy()[ok]
            rec[c] = float(np.average(g[c].to_numpy()[ok], weights=w)) if ok.any() else np.nan
            if ok.any():
                counts.append(int(ok.sum()))
        rec["n_members"] = len(g)
        rec["n_members_used"] = min(counts) if counts else 0
        rows.append(rec)
    return pd.DataFrame(rows, columns=["unit_id"] + keys + list(columns) + ["n_members", "n_members_used"])


def build(derived=DERIVED) -> Path:
    derived = Path(derived)
    cy = pd.read_csv(derived / "climate_state_year.csv", dtype={"qc_masked": str})
    out = aggregate(cy, state_areas(derived))
    missing = set(states.UNITS) - set(out.unit_id)
    if missing:
        raise ValueError(f"units with no climate rows: {sorted(missing)}")
    path = derived / OUT_NAME
    out.to_csv(path, index=False)
    return path


if __name__ == "__main__":
    print(build())
