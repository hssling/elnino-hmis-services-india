"""HMIS portal acquisition (Paper E, spec §3.1): polite, capped, challenge-stopping, manifest-recorded.

Sources (hmis.mohfw.gov.in Standard Reports, anonymous, no login):
- listing endpoint  LIST_URL + base64(<folder path>)      -> JSON, cached by list_folder()
- download endpoint DOWNLOAD_URL + quote(<file path>)       -> zip / xlsx, cached by download()

Raw cache (git-ignored, untrusted data, never executed):
- data/raw/hmis/<source_id>/<file_name> (+ .urls.json sidecar), one MANIFEST row per file;
- data/raw/hmis/listings/<sha1(path)>.json, one MANIFEST row per listing;
- data/raw/hmis/request_log.csv: every request of the foreground runs (url, utc, status, bytes);
- data/raw/hmis/request_log_fy2021.csv: every request of the FY2020-21 job (its budget counts these rows);
- data/raw/hmis/fy2021_plan.csv and fy2021_progress.json: the FY2020-21 job's plan and progress.

Hand-off tables:
- pipeline/reference/hmis_sources.csv (SOURCES_CSV), written by run.py `discover`, read by `fetch`:
  source_id, fy, folder, listing_path, file_name, url, kind, bytes_listed.
  folder is one of FOLDERS; bytes_listed is the size the portal listing states (bytes, may be blank).
- data/raw/hmis/fy2021_plan.csv: the FY2020-21 rows, same columns (folder "district_months_2021").
- data/derived/hmis/fy2021_status.json (STATUS_PATH), written only when the FY2020-21 job ends:
  {"status": "acquired"|"dropped", "reason": str, "n_requests": int, "n_files": int}.
- data/manifest_parts/hmis_fy2021.csv (MANIFEST_PART): the FY2020-21 job's MANIFEST rows (same columns as
  data/MANIFEST.csv; the job never writes data/MANIFEST.csv). merge_manifest_part() merges it at the
  Task 9 sync point.

Politeness and integrity: one request at a time, >= ZIP_INTERVAL_S between zips and >= SMALL_INTERVAL_S
between small files; the existing fetch.get retry and back-off; a cache hit is verified against its
MANIFEST SHA-256. Never bypass a challenge: PoliteSession raises ChallengeDetected on a CAPTCHA/WAF
page, a login redirect, HTTP 401/407/429 or a second consecutive 403, and the run stops. No user-agent
rotation, no proxies, no alternative paths. No header or URL ever carries an e-mail address.
"""
import base64
import csv
import hashlib
import json
import re
import shutil
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, urlparse

import requests

from pipeline import manifest as mf
from pipeline.outcomes import fetch
from pipeline.paths import DATA, DERIVED, MANIFEST_PATH, RAW, ROOT

HMIS_ROOT = RAW / "hmis"
ZIP_INTERVAL_S = 5.0
SMALL_INTERVAL_S = 2.0
FY2021_BUDGET = 10_000
MIN_FREE_BYTES = 2 * 1024**3

PORTAL = "https://hmis.mohfw.gov.in"
LIST_URL = PORTAL + "/getFiles?fpath="
DOWNLOAD_URL = PORTAL + "/downloadfiles?filepath="
SOURCES_CSV = ROOT / "pipeline" / "reference" / "hmis_sources.csv"
SOURCE_FIELDS = ["source_id", "fy", "folder", "listing_path", "file_name", "url", "kind", "bytes_listed"]
FOLDERS = ("all_states_months", "all_india", "district_months_2021", "subdistrict_months_1920", "datagov_fill")
STATUS_PATH = DERIVED / "hmis" / "fy2021_status.json"
MANIFEST_PART = DATA / "manifest_parts" / "hmis_fy2021.csv"
LOG_FIELDS = ["url", "utc", "status", "bytes"]

ENCODE_URI_SAFE = ";,/?:@&=+$-_.!~*'()#"
HIDDEN_YEARS = ("2022-2023", "2023-2024", "2024-2025", "2025-2026", "2026-2027")
CHALLENGE_WORDS = ("captcha", "recaptcha", "cf-chl", "access denied", "login")
CHALLENGE_PATH_WORDS = ("login", "signin", "captcha")


class ChallengeDetected(RuntimeError):
    """The site answered with a challenge (CAPTCHA/WAF page, login redirect, 401/407/429, repeated 403).
    The run stops; nothing is retried or worked round. Not a requests.RequestException, so fetch.get
    never retries it."""


class BudgetExceeded(RuntimeError):
    """The request log already holds `budget` rows; no further request is made."""


class UnsafeFileName(ValueError):
    """A file name that is absolute, has a path separator, drive colon or '..' component, or would resolve
    outside <root>/<source_id>. Refused before any request; nothing is written."""


def _utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class PoliteSession:
    """One request at a time, at least min_interval seconds apart (measured from the end of the previous
    request), each one appended to log_path; a challenge raises ChallengeDetected."""

    def __init__(self, min_interval: float, log_path: Path, budget: int | None = None, session=None,
                 clock=time.monotonic, sleep=time.sleep):
        self.min_interval, self.log_path, self.budget = float(min_interval), Path(log_path), budget
        self.session = session or requests.Session()
        self.clock, self.sleep = clock, sleep
        self._last = None
        self._n403 = 0

    def n_logged(self) -> int:
        """Rows in log_path, including rows from earlier runs."""
        if not self.log_path.exists():
            return 0
        with open(self.log_path, newline="", encoding="utf-8") as fh:
            return max(sum(1 for _ in fh) - 1, 0)

    def _log(self, url: str, status, nbytes: int) -> None:
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        new = not self.log_path.exists()
        with open(self.log_path, "a", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            if new:
                w.writerow(LOG_FIELDS)
            w.writerow([url, _utc(), status, nbytes])

    def get(self, url: str, headers=None, timeout=None) -> requests.Response:
        hdrs = dict(fetch.UA if headers is None else headers)
        if any("@" in str(v) for v in hdrs.values()) or "@" in url:
            raise ValueError("refusing to send a request carrying '@' (no e-mail address is ever sent)")
        if self.budget is not None and self.n_logged() >= self.budget:
            raise BudgetExceeded(f"request budget {self.budget} reached ({self.log_path})")
        if self._last is not None:
            wait = self.min_interval - (self.clock() - self._last)
            if wait > 0:
                self.sleep(wait)
        try:
            r = self.session.get(url, headers=hdrs, timeout=timeout or fetch.TIMEOUT)
            body = r.content or b""
        except requests.RequestException as e:
            self._log(url, f"ERR {type(e).__name__}", 0)
            self._last = self.clock()
            raise
        self._last = self.clock()
        self._log(url, r.status_code, len(body))
        self._check(url, r, body)
        return r

    @property
    def challenge_log(self) -> Path:
        """Sibling CSV (utc, url, message) of every challenge this log's sessions met."""
        return self.log_path.with_name(self.log_path.stem + "_challenges.csv")

    def _challenge(self, url: str, msg: str):
        new = not self.challenge_log.exists()
        with open(self.challenge_log, "a", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            if new:
                w.writerow(["utc", "url", "message"])
            w.writerow([_utc(), url, msg])
        raise ChallengeDetected(msg)

    def _check(self, url: str, r, body: bytes) -> None:
        status = r.status_code
        if status in (401, 407, 429):
            self._challenge(url, f"HTTP {status} at {url}")
        if status == 403:
            self._n403 += 1
            if self._n403 >= 2:
                self._challenge(url, f"second consecutive HTTP 403 at {url}")
        else:
            self._n403 = 0
        final = (urlparse(getattr(r, "url", None) or url).path or "").lower()
        hit = next((w for w in CHALLENGE_PATH_WORDS if w in final), None)
        if hit:
            self._challenge(url, f"redirected to a {hit} page ({r.url}) from {url}")
        head = body[:65536].lstrip(b"\xef\xbb\xbf \t\r\n")
        if head.startswith(b"<"):
            text = body.lower()
            hit = next((w for w in CHALLENGE_WORDS if w.encode() in text), None)
            if hit:
                self._challenge(url, f"HTML page mentioning {hit!r} instead of data at {url}")


def free_bytes(path: Path) -> int:
    """Free bytes on the drive holding path (its nearest existing ancestor)."""
    p = Path(path).resolve()
    while not p.exists():
        p = p.parent
    return shutil.disk_usage(p).free


def portal_path(entry_path: str) -> str:
    """A listing entry's path as the portal's own script passes it on: "BASEDIR/" dropped, "&" -> ":::"."""
    p = entry_path.replace("BASEDIR", "", 1) if entry_path.startswith("BASEDIR") else entry_path
    return p.lstrip("/").replace("&", ":::")


def listing_url(path: str) -> str:
    """getFiles?fpath=base64(UTF-8 path), unquoted, exactly as standardReports.min.js builds it
    (btoa(unescape(encodeURIComponent(path))))."""
    return LIST_URL + base64.b64encode(path.encode("utf-8")).decode("ascii")


def download_url(entry_path: str) -> str:
    """downloadfiles?filepath=encodeURI(path with "&" -> ":::") with "BASEDIR" removed, exactly as the portal's
    file links build it (standardReports.html: filepath={{f.encodedpath.replace('BASEDIR', '')}})."""
    return DOWNLOAD_URL + quote(entry_path.replace("&", ":::"), safe=ENCODE_URI_SAFE).replace("BASEDIR", "", 1)


def anonymous_view(entries: list[dict]) -> list[dict]:
    """The entries the portal shows an anonymous visitor (the non-logged-in branch of
    standardReports.min.js). Folders marked "--L" (login only) and FY2022-23 onwards are never listed or
    downloaded; FY2021-22 files only for April and May. Mirrors the portal; never widens it."""
    out = []
    for k in entries:
        path = k.get("path", "")
        if k.get("isdirectory"):
            parts = k.get("name", "").split("--")
            flag = parts[1] if len(parts) > 1 else ""
            if flag in ("P", "") and not any(y in path for y in HIDDEN_YEARS):
                out.append(k)
            continue
        shown = display_name(k)
        early_2122 = "2021-2022" in path and any(m in shown for m in ("Apr", "May"))
        if early_2122 or ("2022-2023" not in path and "2021-2022" not in path):
            out.append(k)
    return out


def display_name(entry: dict) -> str:
    """Portal display name, as the portal script derives it: "<order>~<name>--<flag>" -> "<name>"."""
    bits = entry.get("name", "").split("--")[0].split("~")
    return bits[1] if len(bits) > 1 and bits[1] else bits[0]


def _recorded_sha(path: Path, manifest: Path) -> str | None:
    """SHA-256 of path's row in `manifest`, else in data/MANIFEST.csv (read only)."""
    sha = fetch.manifest_sha(path, manifest=manifest)
    if sha is None and Path(manifest).resolve() != Path(MANIFEST_PATH).resolve():
        sha = fetch.manifest_sha(path, manifest=MANIFEST_PATH)
    return sha


def _verify_cached(dest: Path, manifest: Path) -> bool:
    """True when dest exists and matches its MANIFEST row; CacheIntegrityError when it exists and does not."""
    if not dest.exists():
        return False
    recorded = _recorded_sha(dest, manifest)
    if recorded is None or mf.sha256_file(dest) != recorded:
        raise fetch.CacheIntegrityError(
            f"{dest}: cached copy {'has no MANIFEST row' if recorded is None else 'SHA-256 differs from its MANIFEST row'}"
            "; inspect and delete it by hand before re-downloading")
    return True


def list_folder(path: str, session: PoliteSession, root: Path | None = None,
                manifest: Path = MANIFEST_PATH) -> list[dict]:
    """The portal's JSON listing of a Standard Reports folder, cached at <root>/listings/<sha1(path)>.json."""
    root = Path(HMIS_ROOT if root is None else root)
    src_dir = root / "listings"
    dest = src_dir / (hashlib.sha1(path.encode("utf-8")).hexdigest() + ".json")
    url = listing_url(path)
    if _verify_cached(dest, manifest):
        return json.loads(dest.read_text(encoding="utf-8"))
    r = session.get(url)
    if r.status_code != 200:
        raise fetch.FetchError(f"listing {path!r}: HTTP {r.status_code}")
    try:
        data = json.loads(r.content.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise fetch.FetchError(f"listing {path!r}: not JSON ({r.content[:60]!r})") from e
    if not isinstance(data, list) or not all(isinstance(x, dict) for x in data):
        raise fetch.FetchError(f"listing {path!r}: expected a JSON list of objects, got {type(data).__name__}")
    src_dir.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(".json.part")
    tmp.write_bytes(r.content)
    tmp.replace(dest)
    mf.record(dest, url, manifest=manifest)
    urls = fetch._load_urls(src_dir)
    fetch._remember(src_dir, urls, url, dest.name)
    paths_file = src_dir / ".paths.json"
    paths = json.loads(paths_file.read_text(encoding="utf-8")) if paths_file.exists() else {}
    if paths.get(dest.name) != path:
        paths[dest.name] = path
        paths_file.write_text(json.dumps(paths, indent=1, sort_keys=True), encoding="utf-8")
    return data


def checked_dest(root: Path, row: dict) -> Path:
    """<root>/<source_id>/<file_name>, or UnsafeFileName (also appended to <root>/refused_rows.csv with the
    reason) when file_name is not one plain component or the path resolves outside <root>/<source_id>."""
    name, base = str(row.get("file_name", "")), Path(root) / row["source_id"]
    dest = base / name
    reason = None
    if not name or name in (".", "..") or any(c in name for c in ("/", "\\", ":")) or Path(name).is_absolute():
        reason = "file name is empty, absolute, '..' or has a path separator or drive colon"
    elif not fetch._inside(dest, base):
        reason = f"resolves outside {base}"
    if reason:
        log = Path(root) / "refused_rows.csv"
        log.parent.mkdir(parents=True, exist_ok=True)
        new = not log.exists()
        with open(log, "a", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            if new:
                w.writerow(["utc", "source_id", "file_name", "url", "reason"])
            w.writerow([_utc(), row["source_id"], name, row.get("url", ""), reason])
        raise UnsafeFileName(f"refusing {name!r} under {row['source_id']!r}: {reason}")
    return dest


def download(row: dict, session: PoliteSession, root: Path | None = None,
             manifest: Path = MANIFEST_PATH) -> Path:
    """Download one hmis_sources row to <root>/<source_id>/<file_name> (zip magic checked), or return the
    cached copy after verifying its SHA-256 against the MANIFEST (no request)."""
    root = Path(HMIS_ROOT if root is None else root)
    dest = checked_dest(root, row)
    if _verify_cached(dest, manifest):
        return dest
    need = int(row.get("bytes_listed") or 0)
    free = free_bytes(root)
    if free - need < MIN_FREE_BYTES:
        raise RuntimeError(f"refusing to download {row['file_name']}: {free / 1024**3:.2f} GB free on the "
                           f"drive, {need / 1024**3:.2f} GB needed, floor {MIN_FREE_BYTES / 1024**3:.0f} GB")
    return fetch.get(row["source_id"], row["url"], row["file_name"], session=session, sleep=session.sleep,
                     kind="zip", root=root, manifest=manifest)


def read_sources(path: Path = SOURCES_CSV) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def write_sources(rows: list[dict], path: Path = SOURCES_CSV) -> None:
    bad = [r["folder"] for r in rows if r["folder"] not in FOLDERS]
    if bad:
        raise ValueError(f"unknown folder value(s) {sorted(set(bad))}")
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=SOURCE_FIELDS, lineterminator="\n")
        w.writeheader()
        w.writerows({k: r.get(k, "") for k in SOURCE_FIELDS} for r in rows)


def merge_manifest_part(part: Path = MANIFEST_PART, manifest: Path = MANIFEST_PATH) -> int:
    """Upsert every row of a manifest part (by path) into the MANIFEST; returns the number of part rows.
    Run only when no job is writing the part (the Task 9 sync point)."""
    part = Path(part)
    if not part.exists():
        raise FileNotFoundError(part)
    new = mf.read(part)
    keys = {r["path"] for r in new}
    rows = [r for r in mf.read(manifest) if r["path"] not in keys] + new
    mf._write(rows, manifest)
    return len(new)


# ---------------------------------------------------------------------------- discovery

C2_PATH = "Standard Reports/5~C2. Data Itemwise Monthly (up to sub district)"
C2_NAME = "C2. Data Itemwise Monthly (up to sub district)"
SUB_ALL_INDIA = "1. All India Across States"
SUB_STATES_DISTRICTS = "2. All States Across Districts"
SUB_STATES_MONTHS = "3. All States and Districts Across Months"
SUB_SUBDISTRICTS = "4. All Districts Across Subdistricts"
PRIMARY_FYS = tuple(f"{y}-{str(y + 1)[2:]}" for y in range(2012, 2020))       # FY2012-13 .. FY2019-20
FY2021_DIR = "2020-2021(Data is Provisional)"
FOLDER4_MAX_BYTES = 1024**3               # folder-4 FY2019-20 zip only if listed <= 1 GB ...
FOLDER4_MIN_FREE_AFTER = 3 * 1024**3      # ... and D: keeps >= 3 GB free after it
UPLOAD_STATUS_WORDS = ("reporting status", "uploading status", "compilation status")


def fy_label(name: str) -> str | None:
    """'2014-2015.zip' or '2020-2021(Data is Provisional)' -> '2014-15'; None when no FY in the name."""
    m = re.search(r"(20\d\d)-(20\d\d)", name)
    return f"{m.group(1)}-{m.group(2)[2:]}" if m and int(m.group(2)) == int(m.group(1)) + 1 else None


def listed_bytes(entry: dict) -> str:
    """The listing's '50.14 MB' as bytes (MB taken as 1024**2; approximate, for the disk check only)."""
    size = str(entry.get("fileSize", "")).strip()
    if not size.upper().endswith("MB"):
        return ""
    return str(int(round(float(size[:-2].strip()) * 1024**2)))


def safe_name(text: str) -> str:
    """A portal-derived name reduced to one plain file-name component: characters outside [A-Za-z0-9._-]
    (path separators, drive colons, spaces, "&") become "_", and leading dots are dropped, so "../../x.zip"
    -> "_.._x.zip"-style names can never climb out of the download directory. Empty results raise."""
    out = re.sub(r"[^A-Za-z0-9._-]+", "_", text).strip("_").lstrip(".")
    if not out or out in (".", ".."):
        raise UnsafeFileName(f"portal name {text!r} leaves no usable file name")
    return out


def _child(entries: list[dict], shown: str) -> dict:
    hits = [e for e in anonymous_view(entries) if display_name(e) == shown]
    if len(hits) != 1:
        raise LookupError(f"expected one folder {shown!r}, found {len(hits)}")
    return hits[0]


def _file_row(entry: dict, source_id: str, fy: str, folder: str, listing_path: str, file_name=None) -> dict:
    name = display_name(entry)
    return {"source_id": source_id, "fy": fy, "folder": folder, "listing_path": listing_path,
            "file_name": safe_name(file_name or name), "url": download_url(entry["path"]),
            "kind": Path(name).suffix.lstrip(".").lower(), "bytes_listed": listed_bytes(entry)}


def find_upload_status(root_entries: list[dict]) -> list[dict]:
    """Standard Reports folders that look like a data uploading/reporting status report, each with whether
    the portal shows it to anonymous visitors (spec §3.6). Login-only folders are reported, never opened."""
    anon = {e["path"] for e in anonymous_view(root_entries)}
    return [{"name": display_name(e), "raw_name": e["name"], "anonymous": e["path"] in anon}
            for e in root_entries if any(w in display_name(e).lower() for w in UPLOAD_STATUS_WORDS)]


def discover(session: PoliteSession, root: Path | None = None, manifest: Path = MANIFEST_PATH) -> dict:
    """List the C2 folders (polite listing calls only) and return {"rows": hmis_sources rows,
    "upload_status": find_upload_status(...), "fy2021_state_level": counts of state-level FY2020-21 files}.

    Rows: folder-3 zips for PRIMARY_FYS (all_states_months); folder-1 zips for PRIMARY_FYS and the folder-1
    FY2020-21 A.MonthWise files (all_india); the folder-4 FY2019-20 zip (subdistrict_months_1920)."""
    kw = {"root": root, "manifest": manifest}
    top = list_folder("Standard Reports", session, **kw)
    c2 = _child(top, C2_NAME)
    subs = list_folder(portal_path(c2["path"]), session, **kw)
    rows = []

    f3 = _child(subs, SUB_STATES_MONTHS)
    for e in anonymous_view(list_folder(portal_path(f3["path"]), session, **kw)):
        fy = fy_label(display_name(e))
        if not e["isdirectory"] and fy in PRIMARY_FYS:
            rows.append(_file_row(e, "hmis_c2_3_states_months", fy, "all_states_months", portal_path(f3["path"])))

    f1 = _child(subs, SUB_ALL_INDIA)
    f1_entries = anonymous_view(list_folder(portal_path(f1["path"]), session, **kw))
    for e in f1_entries:
        fy = fy_label(display_name(e))
        if not e["isdirectory"] and fy in PRIMARY_FYS:
            rows.append(_file_row(e, "hmis_c2_1_all_india", fy, "all_india", portal_path(f1["path"])))
    state_level = {"folder1_monthwise_files": 0, "folder2_monthwise_states": 0}
    fy21 = [e for e in f1_entries if e["isdirectory"] and display_name(e) == FY2021_DIR]
    if fy21:
        mw = _child(list_folder(portal_path(fy21[0]["path"]), session, **kw), "A.MonthWise")
        lp = portal_path(mw["path"])
        for e in anonymous_view(list_folder(lp, session, **kw)):
            if not e["isdirectory"]:
                rows.append(_file_row(e, "hmis_c2_1_all_india_fy2021", "2020-21", "all_india", lp))
                state_level["folder1_monthwise_files"] += 1

    f2 = _child(subs, SUB_STATES_DISTRICTS)
    f2_fy21 = [e for e in anonymous_view(list_folder(portal_path(f2["path"]), session, **kw))
               if e["isdirectory"] and display_name(e) == FY2021_DIR]
    if f2_fy21:
        mw = _child(list_folder(portal_path(f2_fy21[0]["path"]), session, **kw), "A.MonthWise")
        state_level["folder2_monthwise_states"] = sum(
            bool(e["isdirectory"]) for e in anonymous_view(list_folder(portal_path(mw["path"]), session, **kw)))

    f4 = _child(subs, SUB_SUBDISTRICTS)
    for e in anonymous_view(list_folder(portal_path(f4["path"]), session, **kw)):
        if not e["isdirectory"] and fy_label(display_name(e)) == "2019-20":
            rows.append(_file_row(e, "hmis_c2_4_subdistricts", "2019-20", "subdistrict_months_1920",
                                  portal_path(f4["path"])))
    rows.sort(key=lambda r: (FOLDERS.index(r["folder"]), r["fy"], r["file_name"]))
    return {"rows": rows, "upload_status": find_upload_status(top), "fy2021_state_level": state_level}


def folder4_allowed(row: dict, free: int) -> bool:
    """Folder-4 FY2019-20 rule: the listed zip is <= 1 GB and the drive keeps >= 3 GB free after it."""
    need = int(row.get("bytes_listed") or 0)
    return 0 < need <= FOLDER4_MAX_BYTES and free - need >= FOLDER4_MIN_FREE_AFTER


# ---------------------------------------------------------------------------- FY2020-21 job


def plan_fy2021(session: PoliteSession, root: Path | None = None,
                manifest: Path = MANIFEST_PART) -> tuple[list[dict], int]:
    """FY2020-21 state-level month files: folder 2 (All States Across Districts) / 2020-2021 / A.MonthWise /
    <state> / *.xlsx, one file per state-month holding the state's district columns and its aggregate.
    Returns (rows, requests a full run needs: every listing call in the plan, cached or not, plus one per
    file)."""
    kw = {"root": root, "manifest": manifest}
    subs = list_folder(C2_PATH, session, **kw)
    f2 = _child(subs, SUB_STATES_DISTRICTS)
    fy_dir = _child(list_folder(portal_path(f2["path"]), session, **kw), FY2021_DIR)
    mw = _child(list_folder(portal_path(fy_dir["path"]), session, **kw), "A.MonthWise")
    states = [e for e in anonymous_view(list_folder(portal_path(mw["path"]), session, **kw)) if e["isdirectory"]]
    n_list = 4 + len(states)
    rows = []
    for st in sorted(states, key=display_name):
        lp = portal_path(st["path"])
        for e in anonymous_view(list_folder(lp, session, **kw)):
            if not e["isdirectory"]:
                rows.append(_file_row(e, "hmis_c2_2_states_districts_fy2021", "2020-21", "district_months_2021",
                                      lp, file_name=f"{safe_name(display_name(st))}__{safe_name(display_name(e))}"))
    return rows, n_list + len(rows)


def _write_json(path: Path, obj: dict) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".part")
    tmp.write_text(json.dumps(obj, indent=1) + "\n", encoding="utf-8")
    tmp.replace(path)


def acquire_fy2021(session_factory, out_dir: Path | None = None, status_path: Path = STATUS_PATH,
                   manifest: Path = MANIFEST_PART) -> dict:
    """Plan and download the FY2020-21 files (resumable: verified cache hits make no request).

    Dropped, with no download, when the plan needs more than FY2021_BUDGET requests; dropped on any
    ChallengeDetected or BudgetExceeded (spec §11). status_path is written only at those ends or when every
    planned file is acquired; progress goes to <out_dir>/fy2021_progress.json. Any other error (network,
    cache integrity) is written to the progress file and re-raised, leaving no final status."""
    out_dir = Path(HMIS_ROOT if out_dir is None else out_dir)
    progress = out_dir / "fy2021_progress.json"
    session = session_factory()
    n_files = 0

    def final(state: str, reason: str) -> dict:
        s = {"status": state, "reason": reason, "n_requests": session.n_logged(), "n_files": n_files}
        _write_json(status_path, s)
        _write_json(progress, {**s, "utc": _utc()})
        return s

    try:
        _write_json(progress, {"status": "planning", "utc": _utc(), "n_requests": session.n_logged()})
        rows, n_needed = plan_fy2021(session, root=out_dir, manifest=manifest)
        write_sources(rows, out_dir / "fy2021_plan.csv")
        if n_needed > FY2021_BUDGET:
            return final("dropped", f"plan needs {n_needed} requests, over the {FY2021_BUDGET}-request budget")
        refused = 0
        for i, row in enumerate(rows, 1):
            try:
                download(row, session, root=out_dir, manifest=manifest)
                n_files += 1
            except UnsafeFileName:
                refused += 1                                   # recorded in <out_dir>/refused_rows.csv
            _write_json(progress, {"status": "downloading", "utc": _utc(), "files_done": i,
                                   "files_planned": len(rows), "refused": refused, "n_requests": session.n_logged()})
        if refused:
            return final("acquired", f"{n_files} of {len(rows)} planned files downloaded and verified; {refused} "
                                     "refused for unsafe file names (refused_rows.csv)")
        return final("acquired", f"all {len(rows)} planned files downloaded and verified")
    except ChallengeDetected as e:
        return final("dropped", f"site check: {e}")
    except BudgetExceeded as e:
        return final("dropped", f"request budget: {e}")
    except Exception as e:
        _write_json(progress, {"status": "error", "utc": _utc(), "error": f"{type(e).__name__}: {e}",
                               "files_done": n_files, "n_requests": session.n_logged()})
        raise
