"""Harmonised 34-unit state frame and robust state-label resolution."""
import re
from functools import lru_cache
from pathlib import Path

import pandas as pd

FRAME = Path(__file__).resolve().parents[1] / "reference" / "state_frame.csv"
_TOTAL = re.compile(r"^(GRAND )?TOTALS?\b|^ALL INDIA\b|^INDIA$|SUB ?TOTAL|\bTOTAL$")


def normalise(label: str) -> str:
    s = str(label).upper().replace("&", " AND ")
    s = re.sub(r"[^A-Z ]", " ", s)          # drop digits, punctuation, footnote marks
    s = re.sub(r"\bSL\b|\bNO\b", " ", s) if s.strip().startswith("SL") else s
    s = re.sub(r"\s+", " ", s).strip()
    return re.sub(r"^THE ", "", s)


@lru_cache(maxsize=1)
def frame() -> pd.DataFrame:
    f = pd.read_csv(FRAME, dtype=str)
    f["gid1_members"] = f.gid1_members.str.split("|")
    f["aliases"] = f.aliases.str.split("|")
    return f


@lru_cache(maxsize=1)
def _alias_map() -> dict:
    m = {}
    for _, r in frame().iterrows():
        for a in r.aliases + [r.unit_name]:
            key = normalise(a)
            if key in m and m[key] != r.unit_id:
                raise ValueError(f"alias {key!r} maps to both {m[key]} and {r.unit_id}")
            m[key] = r.unit_id
    return m


UNITS = list(pd.read_csv(FRAME, dtype=str).unit_id)
_alias_map()  # import-time check: conflicting normalised aliases raise ValueError


def resolve(label: str):
    n = normalise(label)
    if not n:
        return None
    if _TOTAL.search(n):
        return "TOTAL"
    return _alias_map().get(n)


def unit_of_gid1(gid1: str) -> str:
    for _, r in frame().iterrows():
        if gid1 in r.gid1_members:
            return r.unit_id
    raise KeyError(gid1)
