"""Provenance manifest: one row per raw/external file (upsert by path)."""
import csv
import hashlib
from datetime import datetime, timezone
from pathlib import Path

from pipeline.paths import MANIFEST_PATH, ROOT

FIELDS = ["path", "url", "retrieved_utc", "sha256", "bytes", "deleted"]


def sha256_file(path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _key(path) -> str:
    p = Path(path).resolve()
    try:
        return p.relative_to(ROOT).as_posix()
    except ValueError:
        return p.as_posix()


def read(manifest=MANIFEST_PATH) -> list[dict]:
    m = Path(manifest)
    if not m.exists():
        return []
    with open(m, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def _write(rows, manifest) -> None:
    m = Path(manifest)
    m.parent.mkdir(parents=True, exist_ok=True)
    with open(m, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)


def record(path, url, manifest=MANIFEST_PATH) -> dict:
    p = Path(path)
    row = {
        "path": _key(p),
        "url": url,
        "retrieved_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sha256": sha256_file(p),
        "bytes": str(p.stat().st_size),
        "deleted": "0",
    }
    rows = [r for r in read(manifest) if r["path"] != row["path"]]
    rows.append(row)
    _write(rows, manifest)
    return row


def mark_deleted(path, manifest=MANIFEST_PATH) -> None:
    key = _key(path)
    rows = read(manifest)
    for r in rows:
        if r["path"] == key:
            r["deleted"] = "1"
    _write(rows, manifest)


def retrieval_date(paths, manifest=MANIFEST_PATH):
    """Latest retrieved_utc date (UTC calendar date) among the manifest rows for `paths` (repo-relative
    keys, e.g. data/external/malaria_india_official_1995_2025.csv). Used to pin 'today' in rules that depend
    on data completeness (ruling R21) to the data-retrieval date. KeyError if a path is not listed."""
    from datetime import date as _date
    rows = {r["path"]: r for r in read(manifest)}
    out = []
    for p in paths:
        key = p if p in rows else _key(p)
        if key not in rows:
            raise KeyError(f"{p} not in {manifest}")
        out.append(_date.fromisoformat(rows[key]["retrieved_utc"][:10]))
    return max(out)
