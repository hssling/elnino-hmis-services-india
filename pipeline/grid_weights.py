"""Area weights between a regular grid and polygons, and region aggregation."""
import geopandas as gpd
import numpy as np
import pandas as pd
from scipy import sparse
from shapely.geometry import box

EQUAL_AREA = "+proj=aea +lat_1=12 +lat_2=28 +lat_0=20 +lon_0=80 +datum=WGS84 +units=m +no_defs"


def cell_polygons(grid) -> gpd.GeoDataFrame:
    h = grid.step / 2
    rows = [(i, j, box(lon - h, lat - h, lon + h, lat + h))
            for i, lat in enumerate(grid.lats) for j, lon in enumerate(grid.lons)]
    return gpd.GeoDataFrame(rows, columns=["ilat", "ilon", "geometry"], geometry="geometry", crs="EPSG:4326")


def compute_weights(grid, regions: gpd.GeoDataFrame) -> pd.DataFrame:
    # Intersect in lon/lat (cell edges are exact graticule lines), then project the
    # pieces for area. Intersecting in the projected CRS creates spurious slivers
    # because straight projected edges differ from graticule-aligned cell edges.
    cells = cell_polygons(grid)
    reg = regions[["region_id", "geometry"]].to_crs("EPSG:4326")
    ov = gpd.overlay(reg, cells, how="intersection", keep_geom_type=True)
    ov["area_km2"] = ov.geometry.to_crs(EQUAL_AREA).area / 1e6
    ov = ov[ov.area_km2 > 1e-6]  # drop edge-touching slivers (< 1 m²)
    ov["weight"] = ov.area_km2 / ov.groupby("region_id").area_km2.transform("sum")
    return pd.DataFrame(ov[["region_id", "ilat", "ilon", "area_km2", "weight"]]).reset_index(drop=True)


class Aggregator:
    def __init__(self, grid, regions: gpd.GeoDataFrame, weights: pd.DataFrame | None = None):
        self.grid = grid
        self.region_ids = list(regions["region_id"])
        w = weights if weights is not None else compute_weights(grid, regions)
        rix = {r: k for k, r in enumerate(self.region_ids)}
        cols = w.ilat.to_numpy() * grid.nlon + w.ilon.to_numpy()
        self.W = sparse.csr_matrix(
            (w.weight.to_numpy(), (w.region_id.map(rix).to_numpy(), cols)),
            shape=(len(self.region_ids), grid.nlat * grid.nlon),
        )
        rp = regions.to_crs("EPSG:4326").geometry.representative_point()
        self._rep = np.column_stack([rp.y.to_numpy(), rp.x.to_numpy()])
        lat, lon = np.meshgrid(grid.lats, grid.lons, indexing="ij")
        self._cells = np.column_stack([lat.ravel(), lon.ravel()])
        self.fallback_regions: list[str] = []

    def apply(self, field: np.ndarray) -> np.ndarray:
        t = field.shape[0]
        v = field.reshape(t, -1)
        valid = ~np.isnan(v)
        num = (self.W @ np.where(valid, v, 0.0).T).T
        den = (self.W @ valid.T.astype(float)).T
        with np.errstate(invalid="ignore", divide="ignore"):
            out = np.where(den > 0, num / den, np.nan)
        self.fallback_regions = []
        if not valid.any():
            raise ValueError("Aggregator.apply: no valid (non-NaN) cell at any timestep")
        for k, rid in enumerate(self.region_ids):
            bad = np.flatnonzero(np.isnan(out[:, k]))
            if bad.size == 0:
                continue
            dlat, dlon = (self._cells - self._rep[k]).T
            d = np.hypot(dlat, dlon * np.cos(np.radians(self._rep[k, 0])))
            used = False
            for t in bad:
                if valid[t].any():
                    out[t, k] = v[t, np.argmin(np.where(valid[t], d, np.inf))]
                    used = True
            if used:
                self.fallback_regions.append(rid)
        return out
