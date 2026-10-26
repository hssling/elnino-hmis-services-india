"""Release mode of the Paper E tests (final review, finding 3).

The public release (tools/export_release_e.py) is one root commit without the author's version-control tags (and the
archived zip has no .git at all), ships no FY2020-21 HMIS rows, and cannot ship the GADM boundary file. RELEASE is True
when the release marker file is at the repository root or E_RELEASE_MODE=1 (E_RELEASE_MODE=0 forces the private
behaviour); the few tests that need the private history or FY2020-21 rows are skipped or adapted there, each with its
reason.
"""
import csv
import io
import os
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MARKER = REPO / ".elnino-hmis-release"
FY2021 = "2020-21"


def release_mode() -> bool:
    env = os.environ.get("E_RELEASE_MODE", "")
    if env == "1":
        return True
    if env == "0":
        return False
    return MARKER.is_file()


RELEASE = release_mode()


def without_fy2021(data: bytes, column: str = "fy") -> bytes:
    """CSV bytes without the rows whose `column` is 2020-21, rewritten as the exporter writes a stripped table
    (csv module, LF line ends); unchanged when no row is removed."""
    text = data.decode("utf-8").replace("\r\n", "\n")
    rows = list(csv.DictReader(io.StringIO(text)))
    keep = [r for r in rows if (r.get(column) or "").strip() != FY2021]
    if len(keep) == len(rows):
        return text.encode("utf-8")
    out = io.StringIO()
    w = csv.DictWriter(out, fieldnames=list(rows[0].keys()), lineterminator="\n")
    w.writeheader()
    w.writerows(keep)
    return out.getvalue().encode("utf-8")
