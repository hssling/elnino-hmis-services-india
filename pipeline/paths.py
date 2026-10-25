"""Project directory constants and the synthetic-source blocklist."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
RAW = DATA / "raw"
EXTERNAL = DATA / "external"
DERIVED = DATA / "derived"
MANIFEST_PATH = DATA / "MANIFEST.csv"

# Files known to contain synthetic or defective values (see spec §1). Matched
# case-insensitively against the full path.
BLOCKLIST = (
    "climate_india_2000_2023.csv",
    "dengue_climate_india.csv",
    "india_dengue_monthly_real.csv",
    "state_year_cases_climate.csv",
    "climate_change_vector_diseases_data_collection",
)


class BlockedSourceError(ValueError):
    """Raised when code tries to read a blocklisted (synthetic/defective) source."""


def check_source(path) -> Path:
    p = Path(path)
    text = str(p).lower()
    for bad in BLOCKLIST:
        if bad.lower() in text:
            raise BlockedSourceError(f"Blocked synthetic/defective source: {p}")
    return p


def month_table(level: str, derived=DERIVED) -> Path:
    """Path of climate_<level>_month.csv or its .csv.gz form (district is gzipped); error if both exist."""
    base = Path(derived) / f"climate_{level}_month.csv"
    gz = base.with_name(base.name + ".gz")
    if base.exists() and gz.exists():
        raise ValueError(f"Both {base.name} and {gz.name} exist in {base.parent}; delete the stale one")
    return gz if gz.exists() else base
