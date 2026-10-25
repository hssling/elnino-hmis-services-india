"""ENSO index parsing and NOAA-rule episode classification."""
from pathlib import Path

import numpy as np
import pandas as pd

SEASONS = ["DJF", "JFM", "FMA", "MAM", "AMJ", "MJJ", "JJA", "JAS", "ASO", "SON", "OND", "NDJ"]
_CENTRE = {s: i + 1 for i, s in enumerate(SEASONS)}


class InvalidONIFile(ValueError):
    """ONI content failed parsing or the sanity check (e.g. an HTML error page, a truncated file or a
    malformed season line)."""


def parse_oni(path) -> pd.DataFrame:
    return parse_oni_text(Path(path).read_text())


def parse_oni_text(text: str) -> pd.DataFrame:
    rows = []
    for line in text.splitlines():
        parts = line.split()
        if not parts or parts[0] not in _CENTRE:
            continue
        try:
            if len(parts) != 4:
                raise ValueError(f"{len(parts)} fields")
            rows.append((parts[0], int(parts[1]), _CENTRE[parts[0]], float(parts[2]), float(parts[3])))
        except ValueError as e:
            raise InvalidONIFile(f"malformed ONI season line {line.strip()!r} ({e})") from e
    df = pd.DataFrame(rows, columns=["season", "year", "month", "total", "anom"])
    return df.sort_values(["year", "month"]).reset_index(drop=True)


def round_half_away(x) -> np.ndarray:
    x = np.asarray(x, dtype=float)
    return np.sign(x) * np.floor(np.abs(x) * 10 + 0.5 + 1e-9) / 10


def intensity(peak_abs: float) -> str:
    p = round_half_away([abs(peak_abs)])[0]
    if p >= 2.0:
        return "very_strong"
    if p >= 1.5:
        return "strong"
    if p >= 1.0:
        return "moderate"
    return "weak"


def classify(oni: pd.DataFrame, threshold=0.5, min_run=5) -> pd.DataFrame:
    c = oni.copy().reset_index(drop=True)
    r = round_half_away(c["anom"].to_numpy())
    sign = np.where(r >= threshold, 1, np.where(r <= -threshold, -1, 0))
    c["phase"], c["episode_id"], c["provisional"], c["ongoing"] = "neutral", 0, False, False
    n, i, ep = len(c), 0, 0
    while i < n:
        if sign[i] == 0:
            i += 1
            continue
        j = i
        while j + 1 < n and sign[j + 1] == sign[i]:
            j += 1
        length, trailing = j - i + 1, j == n - 1
        if length >= min_run or trailing:
            ep += 1
            idx = c.index[i : j + 1]
            c.loc[idx, "phase"] = "el_nino" if sign[i] == 1 else "la_nina"
            c.loc[idx, "episode_id"] = ep
            c.loc[idx, "provisional"] = length < min_run
            c.loc[idx, "ongoing"] = trailing
        i = j + 1
    return c


def episodes(classified: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for eid, g in classified[classified.episode_id > 0].groupby("episode_id"):
        peak = g.loc[g["anom"].abs().idxmax(), "anom"]
        rows.append({
            "episode_id": eid, "phase": g.phase.iloc[0],
            "start_season": g.season.iloc[0], "start_year": int(g.year.iloc[0]),
            "end_season": g.season.iloc[-1], "end_year": int(g.year.iloc[-1]),
            "n_seasons": len(g), "peak_anom": float(round_half_away([peak])[0]),
            "intensity": intensity(peak),
            "provisional": bool(g.provisional.iloc[0]), "ongoing": bool(g.ongoing.iloc[0]),
        })
    return pd.DataFrame(rows)


def annual(classified: pd.DataFrame, roni: pd.DataFrame | None = None,
           monthly_extra: pd.DataFrame | None = None) -> pd.DataFrame:
    """Annual ENSO table. `roni` (parse_roni output) adds roni_jjas / roni_djf_next; `monthly_extra`
    (year, month, nino34_anom, dmi) adds nino34_jjas, dmi_jjas (Jun-Sep) and dmi_son (Sep-Nov).
    Window means are NaN unless every contributing month is present."""
    c = classified.set_index(["year", "month"])
    rows = []
    for y in sorted(classified.year.unique()):
        jjas = [c.anom.get((y, m)) for m in (6, 7, 8, 9)]
        jjas = [v for v in jjas if v is not None and not pd.isna(v)]
        djf_next = c.anom.get((y + 1, 1))
        jas = c.loc[(y, 8)] if (y, 8) in c.index else None
        djf = c.loc[(y, 1)] if (y, 1) in c.index else None
        decaying = False
        if djf is not None and djf.phase == "el_nino":
            g = classified[classified.episode_id == djf.episode_id]
            decaying = int(g.year.iloc[0]) < y
        rows.append({
            "year": int(y),
            "oni_jjas": float(np.mean(jjas)) if len(jjas) == 4 else np.nan,
            "oni_djf_next": float(djf_next) if djf_next is not None else np.nan,
            "el_nino_developing": bool(jas is not None and jas.phase == "el_nino"),
            "el_nino_decaying": bool(decaying),
            "la_nina_developing": bool(jas is not None and jas.phase == "la_nina"),
        })
    out = pd.DataFrame(rows)
    if roni is not None:
        r = roni.set_index(["year", "month"])["roni"]
        out["roni_jjas"] = [_window_mean(r, y, (6, 7, 8, 9)) for y in out.year]
        out["roni_djf_next"] = [float(r.get((y + 1, 1), np.nan)) for y in out.year]
    if monthly_extra is not None:
        idx = monthly_extra.set_index(["year", "month"])
        out["nino34_jjas"] = [_window_mean(idx["nino34_anom"], y, (6, 7, 8, 9)) for y in out.year]
        out["dmi_jjas"] = [_window_mean(idx["dmi"], y, (6, 7, 8, 9)) for y in out.year]
        out["dmi_son"] = [_window_mean(idx["dmi"], y, (9, 10, 11)) for y in out.year]
    return out


def _window_mean(series: pd.Series, year: int, months) -> float:
    vals = [series.get((year, m), np.nan) for m in months]
    return np.nan if any(pd.isna(v) for v in vals) else float(np.mean(vals))


def parse_roni(path) -> pd.DataFrame:
    """CPC RONI.ascii.txt: `SEAS YR ANOM` (3 columns; 4 with TOTAL also accepted); last column is the anomaly."""
    rows = []
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] in _CENTRE and parts[1].isdigit():
            rows.append((parts[0], int(parts[1]), _CENTRE[parts[0]], float(parts[-1])))
    df = pd.DataFrame(rows, columns=["season", "year", "month", "roni"])
    return df.sort_values(["year", "month"]).reset_index(drop=True)


def parse_dmi(path) -> pd.DataFrame:
    rows = []
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        if len(parts) == 13 and parts[0].isdigit() and len(parts[0]) == 4:
            y = int(parts[0])
            for m, v in enumerate(parts[1:], start=1):
                val = float(v)
                rows.append((y, m, np.nan if val <= -99 else val))
    return pd.DataFrame(rows, columns=["year", "month", "dmi"])


def parse_nino34(path) -> pd.DataFrame:
    """CPC ersst5.nino.mth.91-20.ascii: YR MON NINO1+2 ANOM NINO3 ANOM NINO4 ANOM NINO3.4 ANOM."""
    rows = []
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        if len(parts) == 10 and parts[0].isdigit():
            rows.append((int(parts[0]), int(parts[1]), float(parts[8]), float(parts[9])))
    return pd.DataFrame(rows, columns=["year", "month", "nino34", "nino34_anom"])
