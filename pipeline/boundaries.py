"""GADM 4.1 India boundaries at country / state / district level."""
import geopandas as gpd

from pipeline.paths import EXTERNAL

GPKG = EXTERNAL / "gadm41_IND.gpkg"


def _canon(ids):
    """GADM disputed-area units (Z<digits>. prefix) are mapped onto Indian ids."""
    return ids.str.replace(r"^Z\d+\.", "IND.", regex=True)


def load(level: str, path=GPKG) -> gpd.GeoDataFrame:
    if level == "country":
        g = gpd.read_file(path, layer="ADM_ADM_0")
        g = g.dissolve().reset_index(drop=True)
        g["region_id"], g["region_name"], g["state_id"], g["state_name"] = "IND", "India", "IND", "India"
    elif level == "state":
        g = gpd.read_file(path, layer="ADM_ADM_1")
        g["GID_1"] = _canon(g["GID_1"])
        g = g.dissolve(by="GID_1", as_index=False, aggfunc="first")
        g["region_id"], g["region_name"] = g["GID_1"], g["NAME_1"]
        g["state_id"], g["state_name"] = g["GID_1"], g["NAME_1"]
    elif level == "district":
        g = gpd.read_file(path, layer="ADM_ADM_2")
        g["GID_1"], g["GID_2"] = _canon(g["GID_1"]), _canon(g["GID_2"])
        g = g.dissolve(by="GID_2", as_index=False, aggfunc="first")
        g["region_id"], g["region_name"] = g["GID_2"], g["NAME_2"]
        g["state_id"], g["state_name"] = g["GID_1"], g["NAME_1"]
    else:
        raise ValueError(level)
    g = g[["region_id", "region_name", "state_id", "state_name", "geometry"]].to_crs("EPSG:4326")
    g["geometry"] = g.geometry.make_valid()
    return g.sort_values("region_id").reset_index(drop=True)
