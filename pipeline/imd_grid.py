"""IMD Pune gridded archive: grid definitions, robust download, binary reader.

Binary layout (verified 2026-10-14 against imdlib 0.3.1 and an IMD 2023 Tmax file):
little-endian float32, C order (days, nlat, nlon), first row = southernmost latitude.
Missing: rain -999, temperature 99.9.
"""
import calendar
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import requests

from pipeline import manifest as mf


@dataclass(frozen=True)
class Grid:
    lon0: float
    lat0: float
    step: float
    nlon: int
    nlat: int

    @property
    def lons(self) -> np.ndarray:
        return self.lon0 + self.step * np.arange(self.nlon)

    @property
    def lats(self) -> np.ndarray:
        return self.lat0 + self.step * np.arange(self.nlat)


RAIN = Grid(66.5, 6.5, 0.25, 135, 129)
TEMP = Grid(67.5, 7.5, 1.0, 31, 31)
GRID_OF = {"rain": RAIN, "tmax": TEMP, "tmin": TEMP}
URLS = {
    "rain": ("https://imdpune.gov.in/cmpg/Griddata/rainfall.php", "rain"),
    "tmax": ("https://imdpune.gov.in/cmpg/Griddata/maxtemp.php", "maxtemp"),
    "tmin": ("https://imdpune.gov.in/cmpg/Griddata/mintemp.php", "mintemp"),
}


class IMDDownloadError(RuntimeError):
    pass


def days_in_year(year: int) -> int:
    return 366 if calendar.isleap(year) else 365


def expected_bytes(var: str, year: int) -> int:
    g = GRID_OF[var]
    return days_in_year(year) * g.nlat * g.nlon * 4


def _default_post(url, data, timeout):
    return requests.post(url, data=data, timeout=timeout)


def download(var, year, dest_dir, post=None, sleep=time.sleep, retries=6, backoff=10.0) -> Path:
    post = post or _default_post
    url, field = URLS[var]
    dest = Path(dest_dir) / f"{var}_{year}.grd"
    dest.parent.mkdir(parents=True, exist_ok=True)
    want = expected_bytes(var, year)
    last = "no attempt"
    for attempt in range(1, retries + 1):
        try:
            r = post(url, {field: str(year)}, (30, 600))
            if r.status_code == 200 and len(r.content) == want:
                tmp = dest.with_suffix(".part")
                tmp.write_bytes(r.content)
                tmp.replace(dest)
                mf.record(dest, f"{url} POST {field}={year}")
                return dest
            last = f"HTTP {r.status_code}, {len(r.content)} bytes (want {want})"
        except requests.RequestException as e:
            last = f"{type(e).__name__}: {e}"
        sleep(backoff * attempt)
    raise IMDDownloadError(f"IMD {var} {year} failed after {retries} attempts: {last}")


def read(var: str, path, year: int) -> np.ndarray:
    g = GRID_OF[var]
    a = np.fromfile(path, dtype="<f4")
    n = days_in_year(year) * g.nlat * g.nlon
    if a.size != n:
        raise ValueError(f"{path}: {a.size} values, expected {n}")
    a = a.reshape(days_in_year(year), g.nlat, g.nlon).astype(np.float32)
    if var == "rain":
        a[a <= -998] = np.nan
    else:
        a[a >= 99] = np.nan
    return a
