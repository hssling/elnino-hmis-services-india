"""Paper E sources table (Task 11): papers/E/sources.md.

    python -I pipeline/hmis/run.py sources        # writes papers/E/sources.md

sources_md(out) writes one row per data/raw/hmis entry of data/MANIFEST.csv (path, URL, retrieval date (UTC), SHA-256,
licence) and one row per external input of the HMIS model table (the ENSO index files, the IMD gridded rainfall and
Tmax files, the population sources, the GADM boundaries, the companion hazard index and the programme-event sources),
with the verbatim GODL-India attribution (spec §3; plan Global Constraints). Portal-only FY2020-21 files are cited to
the portal with a note that it states no explicit licence. Licences marked "to be confirmed by author" repeat
data/README.md, which records that no licence was independently verified by the pipeline. No data value is written.
A data/raw/hmis folder without a licence rule is an error (a new folder needs a rule here first).

A MANIFEST URL of the form "local:<path>" (a file copied from a local folder) is never printed: the row shows its
public source (PUBLIC_SOURCE, from data/README.md) instead, a local: row without one is an error, and sources_md()
refuses to write any text containing "local:" or a drive-letter path (review fix round 1).

Hand-off: papers/E/sources.md (tracked; regenerated in full on every run, rows in MANIFEST order).
"""
import csv
import hashlib
import re
from pathlib import Path

from pipeline.paths import MANIFEST_PATH, ROOT

OUT_PATH = ROOT / "papers" / "E" / "sources.md"
EVENTS_PATH = ROOT / "pipeline" / "reference" / "hmis_programme_events.csv"
GODL_ATTRIBUTION = ("Health Management Information System (HMIS), Ministry of Health and Family Welfare, Government of "
                    "India; via data.gov.in / hmis.mohfw.gov.in; Government Open Data License \u2013 India")
GODL_SHORT = "GODL-India (attribution above)"
PORTAL_ONLY = "hmis.mohfw.gov.in portal (FY2020-21, portal only); the portal states no explicit licence"
PORTAL_METADATA = "portal listing or page script (metadata only; read as text, never executed); no licence stated"
HMIS_LICENCE = {
    "hmis_c2_1_all_india": GODL_SHORT,
    "hmis_c2_3_states_months": GODL_SHORT,
    "hmis_c2_4_subdistricts": GODL_SHORT,
    "hmis_c2_1_all_india_fy2021": PORTAL_ONLY,
    "hmis_c2_2_states_districts_fy2021": PORTAL_ONLY,
    "listings": PORTAL_METADATA,
    "portal_js": PORTAL_METADATA,
    "programme_events": "Press Information Bureau, Government of India, press release (cited for programme dates)",
    "srs": "Reserve Bank of India web page (cited; SRS birth rates not retrieved, ruling F23)",
}
NOAA = "NOAA (U.S. Government data); terms to be confirmed by author"
IMD = "IMD Pune; terms to be confirmed by author"
# External inputs with a MANIFEST row: (path or prefix, what, licence).
EXTERNAL = [
    ("data/raw/enso/oni.ascii.txt", "ONI (traditional), NOAA CPC", NOAA),
    ("data/raw/enso/RONI.ascii.txt", "Relative ONI (RONI), NOAA CPC", NOAA),
    ("data/raw/enso/ersst5.nino.mth.91-20.ascii", "Nino-3.4 monthly anomaly (ERSSTv5, 1991-2020 base), NOAA CPC", NOAA),
    ("data/raw/enso/dmi.had.long.data", "Dipole Mode Index (HadISST), NOAA PSL", NOAA),
    ("data/raw/imd/rain_", "IMD gridded daily rainfall, 0.25 deg (cite Pai et al. 2014, MAUSAM 65:1-18)", IMD),
    ("data/raw/imd/tmax_", "IMD gridded daily Tmax, 1 deg (cite Srivastava et al. 2009, Atmos Sci Lett 10:249-254)", IMD),
    ("data/raw/outcomes/census_a02/", "Census of India 2001 and 2011, Table A-02 (population on 1 March)",
     "Government of India publication; terms to be confirmed by author"),
    ("data/raw/outcomes/rgi_proj2020/", "RGI/NCP population projections 2011-2036 (Table 8, 1 March)",
     "Government of India publication; terms to be confirmed by author"),
    ("data/external/gadm41_IND.gpkg", "GADM 4.1 India boundaries (state areas for pooled units; not redistributed)",
     "GADM licence: academic and other non-commercial use (https://gadm.org/license.html)"),
]
# Public sources of inputs whose MANIFEST url is "local:<path>" (copied from a local folder; data/README.md).
PUBLIC_SOURCE = {
    "data/external/gadm41_IND.gpkg": "https://gadm.org/download_country.html (GADM 4.1, file gadm41_IND.gpkg)",
}
LOCAL_PATH_RE = re.compile(r"local:|(^|[^A-Za-z])[A-Za-z]:[\\/]")


def public_url(path: str, url: str) -> str:
    """The URL to print: the MANIFEST url, or for a "local:" copy its public source (never the local path)."""
    if not url.startswith("local:"):
        return url
    if path not in PUBLIC_SOURCE:
        raise ValueError(f"{path} is a local copy (MANIFEST url local:...) with no public source in PUBLIC_SOURCE")
    return PUBLIC_SOURCE[path]


# External inputs without a MANIFEST row (repository files): (path, what, url, licence).
EXTERNAL_REPO = [
    ("papers/D/output/risk_index.csv",
     "Companion El Ni\u00f1o health-risk synthesis, column hazard_rain (% of JJAS rain lost per +1 \u00b0C ONI, 1981-2009)",
     "https://doi.org/10.5281/zenodo.23632647", "CC BY 4.0 (released results of the companion synthesis)"),
]


def _cell(x) -> str:
    return str(x).replace("|", "\\|").replace("\n", " ")


def _sha256_lf(path: Path) -> str:
    """SHA-256 after CRLF -> LF (git's autocrlf checkout of a committed LF file)."""
    return hashlib.sha256(path.read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def _manifest(manifest: Path) -> list[dict]:
    with open(manifest, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def hmis_rows(manifest: Path = MANIFEST_PATH) -> list[dict]:
    """One dict per data/raw/hmis MANIFEST row: path, url, retrieved (UTC date), sha256, licence, deleted."""
    out = []
    for r in _manifest(manifest):
        p = r["path"].replace("\\", "/")
        if not p.startswith("data/raw/hmis/"):
            continue
        folder = p.split("/")[3]
        if folder not in HMIS_LICENCE:
            raise ValueError(f"no licence rule for {p} (folder {folder}); add one to HMIS_LICENCE")
        out.append({"path": p, "url": public_url(p, r["url"]), "retrieved": r["retrieved_utc"][:10], "sha256": r["sha256"],
                    "licence": HMIS_LICENCE[folder], "deleted": str(r.get("deleted", "0")) not in ("0", "", "False")})
    return out


def external_rows(manifest: Path = MANIFEST_PATH, root: Path = ROOT) -> list[dict]:
    rows = _manifest(manifest)
    out = []
    for key, what, lic in EXTERNAL:
        hit = [r for r in rows if (r["path"].startswith(key) if key.endswith(("/", "_")) else r["path"] == key)]
        if not hit:
            raise ValueError(f"external input {key} has no MANIFEST row")
        out += [{"path": r["path"], "what": what, "url": public_url(r["path"], r["url"]), "retrieved": r["retrieved_utc"][:10],
                 "sha256": r["sha256"], "licence": lic} for r in hit]
    for path, what, url, lic in EXTERNAL_REPO:
        out.append({"path": path, "what": what, "url": url, "retrieved": "repository file",
                    "sha256": _sha256_lf(root / path) + " (LF)", "licence": lic})
    return out


def event_rows(events: Path = EVENTS_PATH) -> list[dict]:
    with open(events, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    return [{"event": r["event"], "source": r["source_url"], "accessed": r["accessed"],
             "status": "PROVISIONAL (pending the author's confirmation)" if "PROVISIONAL" in r["note"] else "confirmed"}
            for r in rows]


def sources_md(out: Path = OUT_PATH, manifest: Path = MANIFEST_PATH, events: Path = EVENTS_PATH,
               root: Path = ROOT) -> Path:
    hm = hmis_rows(manifest)
    ex = external_rows(manifest, root)
    ev = event_rows(events)
    n_godl = sum(r["licence"] == GODL_SHORT for r in hm)
    n_portal = sum(r["licence"] == PORTAL_ONLY for r in hm)
    lines = [
        "# Paper E: data sources",
        "",
        "Generated by `pipeline/hmis/sources_md.py` (`python -I pipeline/hmis/run.py sources`) from `data/MANIFEST.csv`, "
        "`pipeline/reference/hmis_programme_events.csv` and the repository files named below. Do not edit by hand.",
        "",
        "## Attribution (HMIS)",
        "",
        GODL_ATTRIBUTION,
        "",
        f"HMIS files for FY2012-13 to FY2019-20 ({n_godl} files) are used under this attribution. The FY2020-21 files "
        f"({n_portal} files) were downloaded from the hmis.mohfw.gov.in portal only; they are cited to the portal, "
        "which states no explicit licence. Raw HMIS files are not redistributed.",
        "",
        f"## HMIS portal files ({len(hm)} rows of `data/MANIFEST.csv` under `data/raw/hmis/`)",
        "",
        "| Path | URL | Retrieved (UTC) | SHA-256 | Licence |",
        "|---|---|---|---|---|",
    ]
    lines += [f"| `{r['path']}` | {_cell(r['url'])} | {r['retrieved']} | `{r['sha256']}` | "
              f"{_cell(r['licence'] + (' (file deleted)' if r['deleted'] else ''))} |" for r in hm]
    lines += [
        "",
        f"## External inputs ({len(ex)} files)",
        "",
        "Inputs of `data/derived/hmis/hmis_model.csv` other than HMIS: ENSO and IOD indices, IMD gridded rainfall and "
        "maximum temperature (SPI-3, heatwave days, Tmax anomaly), population (offset), state areas (pooled units) and "
        "the companion rainfall-hazard index (`S_z`). SHA-256 values marked (LF) are of the repository file after "
        "CRLF -> LF.",
        "",
        "| Path | Input | URL | Retrieved (UTC) | SHA-256 | Licence |",
        "|---|---|---|---|---|---|",
    ]
    lines += [f"| `{r['path']}` | {_cell(r['what'])} | {_cell(r['url'])} | {r['retrieved']} | `{r['sha256']}` | "
              f"{_cell(r['licence'])} |" for r in ex]
    lines += [
        "",
        f"## Programme-event sources ({len(ev)} rows of `pipeline/reference/hmis_programme_events.csv`)",
        "",
        "Cited web sources for the programme-indicator months (fetched pages, where kept, are listed above with their "
        "SHA-256 under `data/raw/hmis/programme_events/`).",
        "",
        "| Event | Source | Accessed | Status |",
        "|---|---|---|---|",
    ]
    lines += [f"| {_cell(r['event'])} | {_cell(r['source'])} | {r['accessed']} | {r['status']} |" for r in ev]
    text = "\n".join(lines) + "\n"
    bad = [ln for ln in text.splitlines() if LOCAL_PATH_RE.search(ln)]
    if bad:
        raise ValueError(f"sources.md would print a local path: {bad[0][:120]}")
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8", newline="\n")
    return out
