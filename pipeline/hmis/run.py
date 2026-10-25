"""Paper E HMIS pipeline CLI.

    python -I pipeline/hmis/run.py discover        # polite listing calls -> pipeline/reference/hmis_sources.csv
    python -I pipeline/hmis/run.py fetch           # primary acquisition (folder 3, folder 1, folder-4 FY2019-20)
    python -I pipeline/hmis/run.py fetch --fy2021  # FY2020-21 job (background; manifest part, status file)
    python -I pipeline/hmis/run.py report          # data/derived/hmis/acquisition_report.md
    python -I pipeline/hmis/run.py parse --sample  # Task 2: parse one member per FY + every crosswalk
                                                   # verified_in_file; counts only (no values) to stdout and
                                                   # data/derived/hmis/_parts/parse_sample.json (git-ignored)
    python -I pipeline/hmis/run.py flags [--fy 2014-15 ...]
                                                   # Task 3 (alias: difference): every FY, member by member:
                                                   # parse, crosswalk, district flags, completeness, the
                                                   # month-total check; tables to data/derived/hmis/_parts/
                                                   # (git-ignored) and counts to differencing_report.csv
    python -I pipeline/hmis/run.py national [--fy ...]
                                                   # Task 4 (ruling F39): folder-1 All India month files net of
                                                   # the folder-3 All_India.xls M/O rows ->
                                                   # data/derived/hmis/_parts/national_month.csv.gz (git-ignored)
    python -I pipeline/hmis/run.py panel [--refresh-national]
                                                   # Task 4: `national` if its part is absent, then
                                                   # pipeline/hmis/panel.build_outputs: hmis_state_month.csv,
                                                   # gate_summary.csv, break_ratio_2017.csv, hmis_reviewed.csv and
                                                   # the validation-report section; exit 2 on PanelHalt
    python -I pipeline/hmis/run.py model-table     # Task 5: data/derived/hmis/climate_unit_month.csv
                                                   # (pipeline/hmis/climate_month.py), then
                                                   # data/derived/hmis/hmis_model.csv (pipeline/hmis/model_table.py);
                                                   # prints row counts and the primary-window NaN share per outcome
    python -I pipeline/hmis/run.py sources         # Task 11: papers/E/sources.md (pipeline/hmis/sources_md.py):
                                                   # every data/raw/hmis MANIFEST row and the external inputs, with
                                                   # URL, retrieval date, SHA-256, licence and the GODL attribution

Hand-offs (besides those in pipeline/hmis/fetch.py):
- data/raw/hmis/discovery.json: {"utc", "upload_status": [{name, raw_name, anonymous}],
  "fy2021_state_level": {folder1_monthwise_files, folder2_monthwise_states}} from `discover`;
- data/raw/hmis/fetch_decisions.json: {"utc", "folder4_fy2019_20": str, "refused": [str], "free_bytes_after": int}
  from `fetch`; data/raw/hmis/refused_rows.csv: utc, source_id, file_name, url, reason (unsafe names refused).
- `flags` writes, under data/derived/hmis/_parts/ (git-ignored; district-level), district_month, state_month,
  completeness, vintage, month_total_check and members (.csv.gz; columns in pipeline/hmis/flags.py and
  difference.py; members: MEMBER_COLUMNS below), and the tracked data/derived/hmis/differencing_report.csv
  (flags.REPORT_COLUMNS; counts and shares by indicator x FY only).
  MEMBER_COLUMNS: fy, source_file ("<repo path>::<member>" or the file path), member, status (parsed /
  excluded / error), era, units (state or district units read), excluded_units (M/O rows dropped from a
  parsed file), long_rows, n_cells (value cells read), bad_cells (cells that were not numbers -> NaN), seconds,
  message (the exclusion reason or the error).
- `national` writes NATIONAL_COLUMNS: fy, month (calendar), indicator, all_india (the "All India" column of the
  folder-1 month file; FY2020-21: hmis_c2_1_all_india_fy2021), mo_in_national (the file has M/O columns), mo_value
  (M/O Defence + M/O Railways from the folder-3 All_India.xls; FY2020-21: the national file's own M/O columns),
  national (all_india - mo_value when mo_in_national, M/O missing counted as 0), status_date, source_file, note
  ("no month file", "not parsed: ..." for the two FY2017-18 BIFF workbooks, or "item absent ..."). National-level only.
"""
import argparse
import csv
import json
import re
import sys
import time
import zipfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from pipeline import manifest as mf  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from pipeline.hmis import crosswalk as hx  # noqa: E402
from pipeline.hmis import difference as hd  # noqa: E402
from pipeline.hmis import fetch as hf  # noqa: E402
from pipeline.hmis import flags as hfl  # noqa: E402
from pipeline.hmis import parse as hp  # noqa: E402
from pipeline.paths import DERIVED, MANIFEST_PATH, ROOT  # noqa: E402

REPORT_PATH = DERIVED / "hmis" / "acquisition_report.md"
# Observations from the 2026-10-24 acquisition run, carried into the report (file facts only, no data values).
ACQUISITION_NOTES = (
    "The portal script (`standardReports.min.js`) and page template (`standardReports.html`) were each read "
    "once as text, never executed, and cached under `data/raw/hmis/portal_js/` with MANIFEST rows. They give "
    "the listing call (base64 of the folder path) and the file link (`downloadfiles?filepath=` + encodeURI of "
    "the path with `BASEDIR` removed).",
    "The 4 HTTP 500 responses are one file tried 4 times with back-off under a first URL form that kept the "
    "`BASEDIR` prefix; with the portal's own link form every download returned 200. Not a challenge.",
    "Folder-3 and folder-1 zips use standard deflate and hold per-state `.xls` workbooks (BIFF); FY2017-18 has "
    "one `.xlsx` in folder 3 and 12 in folder 1. No member path is absolute or contains `..`.",
    "The folder-4 FY2019-20 zip holds 16,894 sub-district month `.xls` files under "
    "`2019-2020/A.Monthwise/<state>/<district>/`, compressed with Deflate64 (zip method 9), which Python's "
    "zipfile cannot read; about 36.5 GB uncompressed, so it must never be extracted to disk. Using it needs a "
    "streaming Deflate64 decoder; otherwise FY2019-20 rests on the folder-3 cumulative files.",
)


def _utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _root() -> Path:
    return Path(hf.HMIS_ROOT)


def discover(sources: Path = hf.SOURCES_CSV) -> dict:
    session = hf.PoliteSession(hf.SMALL_INTERVAL_S, _root() / "request_log.csv")
    out = hf.discover(session)
    hf.write_sources(out["rows"], sources)
    meta = {"utc": _utc(), "upload_status": out["upload_status"], "fy2021_state_level": out["fy2021_state_level"]}
    hf._write_json(_root() / "discovery.json", meta)
    print(f"{len(out['rows'])} files -> {sources}")
    print(json.dumps(meta, indent=1))
    return out


def fetch_primary(sources: Path = hf.SOURCES_CSV) -> list[Path]:
    """Download every hmis_sources row except district_months_2021 (the FY2020-21 job), 5 s apart.
    The folder-4 FY2019-20 zip only under hf.folder4_allowed; otherwise 'cumulative only for 2019-20'."""
    session = hf.PoliteSession(hf.ZIP_INTERVAL_S, _root() / "request_log.csv")
    got, refused, folder4 = [], [], "no folder-4 FY2019-20 row in hmis_sources.csv"
    for row in hf.read_sources(sources):
        if row["folder"] == "district_months_2021":
            continue
        if row["folder"] == "subdistrict_months_1920":
            free = hf.free_bytes(_root())
            cached = (_root() / row["source_id"] / row["file_name"]).exists()
            if not cached and not hf.folder4_allowed(row, free):
                folder4 = (f"skipped: listed {int(row['bytes_listed'] or 0) / 1024**3:.2f} GB with "
                           f"{free / 1024**3:.2f} GB free; cumulative only for 2019-20")
                print(folder4)
                continue
            folder4 = f"downloaded (listed {int(row['bytes_listed'] or 0) / 1024**2:.0f} MB)"
        print(f"{row['folder']} {row['fy']} {row['file_name']}", flush=True)
        try:
            got.append(hf.download(row, session))
        except hf.UnsafeFileName as e:                         # recorded in data/raw/hmis/refused_rows.csv
            refused.append(str(e))
            print(e)
    hf._write_json(_root() / "fetch_decisions.json",
                   {"utc": _utc(), "folder4_fy2019_20": folder4, "refused": refused,
                    "free_bytes_after": hf.free_bytes(_root())})
    print(f"{len(got)} files present; {hf.free_bytes(_root()) / 1024**3:.2f} GB free")
    return got


def fetch_fy2021() -> dict:
    root = _root()
    status = hf.acquire_fy2021(lambda: hf.PoliteSession(hf.SMALL_INTERVAL_S, root / "request_log_fy2021.csv",
                                                        budget=hf.FY2021_BUDGET), out_dir=root)
    print(json.dumps(status))
    return status


def _log_summary(path: Path) -> str:
    if not path.exists():
        return "no requests"
    with open(path, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    by = Counter(r["status"] for r in rows)
    return f"{len(rows)} requests (" + ", ".join(f"HTTP {k}: {v}" for k, v in sorted(by.items())) + ")"


def _challenges(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def _read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def report(out: Path = REPORT_PATH, sources: Path = hf.SOURCES_CSV, manifest: Path = MANIFEST_PATH,
           status_path: Path = hf.STATUS_PATH, part: Path = hf.MANIFEST_PART) -> str:
    """Write the acquisition report from hmis_sources.csv, the MANIFEST (and the FY2020-21 part), the request
    logs, discovery.json, fetch_decisions.json and fy2021_status.json. No data values, only file facts."""
    root = _root()
    man = {r["path"]: r for r in mf.read(manifest)}
    if Path(part).exists():
        man.update({r["path"]: r for r in mf.read(part)})
    rows = hf.read_sources(sources)
    lines = ["# HMIS acquisition report (Paper E, Task 1)", "",
             f"Generated {_utc()} by `python -I pipeline/hmis/run.py report`. Source: HMIS portal Standard Reports, "
             "\"C2. Data Itemwise Monthly (up to sub district)\" (https://hmis.mohfw.gov.in/#!/standardReports), "
             "anonymous access only. Files are cached under `data/raw/hmis/` (git-ignored) with one "
             "`data/MANIFEST.csv` row each.", "",
             "## Files", "",
             "| FY | Folder | File | Bytes | SHA-256 | Retrieved (UTC) |", "|---|---|---|---|---|---|"]
    n_have, total = 0, 0
    for r in sorted(rows, key=lambda r: (r["fy"], r["folder"], r["file_name"])):
        key = mf._key(root / r["source_id"] / r["file_name"])
        m = man.get(key)
        if m:
            n_have += 1
            total += int(m["bytes"])
            lines.append(f"| {r['fy']} | {r['folder']} | {r['file_name']} | {int(m['bytes']):,} | "
                         f"`{m['sha256']}` | {m['retrieved_utc']} |")
        else:
            lines.append(f"| {r['fy']} | {r['folder']} | {r['file_name']} | not downloaded | - | - |")
    lines += ["", f"{n_have} of {len(rows)} listed files downloaded, {total / 1024**2:.1f} MB in total.", ""]
    n_listings = sum(1 for k in man if k.startswith(mf._key(root / "listings") + "/"))
    lines += ["## Requests", "",
              f"- Foreground (discovery, listings and primary downloads): {_log_summary(root / 'request_log.csv')}.",
              f"- FY2020-21 job: {_log_summary(root / 'request_log_fy2021.csv')}.",
              f"- Cached folder listings with MANIFEST rows: {n_listings}.",
              f"- Spacing: at least {hf.ZIP_INTERVAL_S:.0f} s between zip downloads and at least "
              f"{hf.SMALL_INTERVAL_S:.0f} s between listings and small files; one request at a time; "
              "the default user agent, never rotated; no e-mail address in any request.", ""]
    ch = _challenges(root / "request_log_challenges.csv") + _challenges(root / "request_log_fy2021_challenges.csv")
    lines += ["## Challenges", ""]
    lines += [f"- {c['utc']}: {c['message']}" for c in ch] or ["- None seen (no CAPTCHA, WAF page, login "
                                                                 "redirect, HTTP 401/407/429 or repeated 403)."]
    disc, dec, st = _read_json(root / "discovery.json"), _read_json(root / "fetch_decisions.json"), \
        _read_json(Path(status_path))
    lines += ["", "## Decisions", "",
              f"- Folder 4 (All Districts Across Subdistricts), FY2019-20 zip: "
              f"{dec.get('folder4_fy2019_20', 'not yet decided')}.",
              "- Rows refused for unsafe file names (absolute, '..', path separator, or outside their source "
              f"folder): {len(dec.get('refused', []))} in the primary run.",
              "- FY2020-21: state-level month files exist. Folder 1 (All India Across States) / 2020-2021 / "
              f"A.MonthWise has {disc.get('fy2021_state_level', {}).get('folder1_monthwise_files', '?')} month files "
              "(downloaded with the primary run, as the national cross-check). Folder 2 (All States Across Districts) "
              f"/ 2020-2021 / A.MonthWise has {disc.get('fy2021_state_level', {}).get('folder2_monthwise_states', '?')} "
              "state folders of month files; the FY2020-21 job downloads those (district columns plus the state "
              "aggregate), not the roughly 8,400 per-district files of folder 4.",
              "- FY2020-21 job status: " + (f"**{st['status']}**: {st['reason']} ({st['n_requests']} requests, "
                                            f"{st['n_files']} files)." if st else
                                            "not final yet (`data/derived/hmis/fy2021_status.json` absent; progress "
                                            "in `data/raw/hmis/fy2021_progress.json`). Its MANIFEST rows go to "
                                            "`data/manifest_parts/hmis_fy2021.csv` and are merged at the Task 9 "
                                            "sync point."), ""]
    ups = disc.get("upload_status", [])
    lines += ["## Data uploading status report (spec §3.6)", ""]
    if ups:
        lines += [f"- \"{u['name']}\": {'shown to anonymous visitors' if u['anonymous'] else 'login only (marked --L; not opened)'}."
                  for u in ups]
        anon = [u for u in ups if u["anonymous"]]
        lines += ["", "An anonymous reporting-status report exists, so it can replace the inferred flag after "
                      "a concordance check." if anon else
                  "No anonymous data uploading status report: the portal lists these folders only to logged-in "
                  "users. Completeness is therefore inferred from the files (spec §3.6 `nonreport` flags)."]
    else:
        lines += ["- Discovery not run."]
    lines += ["", "## Notes", ""] + [f"- {n}" for n in ACQUISITION_NOTES]
    lines += ["", "## Disk", "",
              f"- Free on the data drive when this report was written: {hf.free_bytes(root) / 1024**3:.2f} GB "
              f"(floor {hf.MIN_FREE_BYTES / 1024**3:.0f} GB).", ""]
    text = "\n".join(lines)
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    return text


SAMPLE_OUT = DERIVED / "hmis" / "_parts" / "parse_sample.json"
SAMPLE_MEMBER = "A & N Islands.xls"            # smallest state workbook with districts, every FY
SAMPLE_FY2021 = "Andaman_Nicobar_Islands__A-Andaman_Nicobar_Islands_Apr.xlsx"


def _fy_short(text: str) -> str | None:
    m = re.search(r"(20\d\d)-(20\d\d)", text)
    return f"{m.group(1)}-{m.group(2)[2:]}" if m else None


def sample_targets(xw, root: Path | None = None) -> list[tuple[str, Path, str | None]]:
    """(fy, file, zip member or None): the A & N Islands workbook of each folder-3 FY, the FY2012-13
    All_India.xls (state-aggregate rows), one FY2020-21 folder-2 month file, and every crosswalk
    verified_in_file (E3 rows are FY2020-21)."""
    root = Path(root or _root())
    f3 = root / "hmis_c2_3_states_months"
    out = [(f"{y}-{(y + 1) % 100:02d}", f3 / f"{y}-{y + 1}.zip", f"{y}-{y + 1}/{SAMPLE_MEMBER}")
           for y in range(2012, 2020)]
    out.append(("2012-13", f3 / "2012-2013.zip", "2012-2013/All_India.xls"))
    out.append(("2020-21", root / "hmis_c2_2_states_districts_fy2021" / SAMPLE_FY2021, None))
    for era, v in sorted(set(zip(xw.era, xw.verified_in_file))):
        path, _, member = v.partition("::")
        fy = "2020-21" if era == "E3" else _fy_short(path)
        out.append((fy, ROOT / path, member or None))
    seen, uniq = set(), []
    for t in out:
        key = (t[0], str(t[1]), t[2])
        if key not in seen:
            seen.add(key)
            uniq.append(t)
    return uniq


def parse_sample(out: Path = SAMPLE_OUT, xw_path: Path = hx.XW_PATH, root: Path | None = None) -> dict:
    """Parse the sample targets and apply the crosswalk. Prints and writes COUNTS only (no data values):
    rows, units, months, status date and, per indicator, unit-months found and non-missing."""
    xw = hx.load_crosswalk(xw_path)
    problems = hx.verify_crosswalk(xw, mf.read())
    results = []
    for fy, path, member in sample_targets(xw, root):
        source = mf._key(path) + (f"::{member}" if member else "")
        if not path.exists():
            results.append({"fy": fy, "source": source, "status": "absent"})
            print(f"{fy}  {source}: absent")
            continue
        if member:
            (_, data), = hp.iter_members(path, only={member})
        else:
            data = path.read_bytes()
        long = hp.parse_member(source, data, fy)
        ind = hx.apply_crosswalk(long, xw)
        units = long[["state_raw", "district_raw"]].drop_duplicates()
        per = {i: {"unit_months": int((ind.indicator == i).sum()),
                   "non_missing": int(ind[ind.indicator == i].value.notna().sum())} for i in hx.INDICATORS}
        dates = sorted({str(d) for d in long.status_date.dropna()})
        r = {"fy": fy, "source": source, "status": "parsed", "era": hp.era_for_fy(fy), "long_rows": len(long),
             "units": len(units), "aggregate_units": int(long.drop_duplicates(["state_raw", "district_raw"])
                                                        .is_state_aggregate.sum()),
             "months": sorted(int(m) for m in long.month.unique()), "cumulative": bool(long.cumulative.any()),
             "status_dates": dates, "indicators": per,
             "all_indicators_found": set(ind.indicator) == set(hx.INDICATORS)}
        results.append(r)
        print(f"{fy} {r['era']}  {source}: {r['long_rows']} rows, {r['units']} units "
              f"({r['aggregate_units']} aggregate), months {r['months'][0]}..{r['months'][-1]} "
              f"x{len(r['months'])}, status {','.join(dates)}; all 7 indicators found: "
              f"{r['all_indicators_found']}; non-missing unit-months "
              + " ".join(f"{i}={v['non_missing']}/{v['unit_months']}" for i, v in per.items()), flush=True)
    summary = {"utc": _utc(), "crosswalk_problems": problems, "files": results}
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(summary, indent=1), encoding="utf-8")
    print(f"crosswalk verified_in_file problems: {problems or 'none'}; summary -> {out}")
    return summary


# ---- Task 3: district flags, completeness and the monthly checks ------------------------------------------
FOLDER3 = "hmis_c2_3_states_months"
FOLDER2_FY2021 = "hmis_c2_2_states_districts_fy2021"
FOLDER1_FY2021 = "hmis_c2_1_all_india_fy2021"
PRIMARY_FYS = tuple(f"{y}-{(y + 1) % 100:02d}" for y in range(2012, 2020))
FY2021 = "2020-21"
PARTS = DERIVED / "hmis" / "_parts"
FLAG_REPORT = DERIVED / "hmis" / "differencing_report.csv"
MEMBER_COLUMNS = ["fy", "source_file", "member", "status", "era", "units", "excluded_units", "long_rows",
                  "n_cells", "bad_cells", "seconds", "message"]
DM_IN = ["fy", "month", "state_raw", "district_raw", "indicator", "value", "n_components", "n_present",
         "partial_component", "status_date", "source_file"]
TABLES = ("district_month", "state_month", "completeness", "vintage", "month_total_check", "members")
PARSE_ERRORS = (hp.LayoutError, hp.UnsafeArchiveError, hx.CrosswalkError)
MIN_FREE_BYTES = 2 * 1024 ** 3


def _xw_codes(xw, era) -> set:
    return {c for v in xw[xw.era == era].item_codes for c in v.split("|")}


def _member_row(fy, source, member, era, status, **kw) -> dict:
    row = dict.fromkeys(MEMBER_COLUMNS)
    row.update(fy=fy, source_file=source, member=member, era=era, status=status, **kw)
    return row


def _drop_non_state(long):
    """(long without M/O rows, number of M/O units dropped)."""
    mo = {s for s in long.state_raw.unique() if hd.is_non_state(s)}
    if not mo:
        return long, 0
    return long[~long.state_raw.isin(mo)], len(mo)


def _with_partial(ind, longx, xw):
    pc = hfl.partial_component(longx, xw)
    out = ind.merge(pc, on=hx.UNIT_MONTH + ["indicator"], how="left")
    out["partial_component"] = out["partial_component"].astype("boolean").fillna(False).astype(bool)
    return out


def _concat(frames, columns):
    frames = [f[columns] for f in frames if len(f)]
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame(columns=columns)


def _finish(members, states, districts, checks, lists, sdates, aidates) -> dict:
    dm_in = _concat(districts, DM_IN)
    lists = _concat(lists, ["state_raw", "fy", "district_raw"]).drop_duplicates()
    dm = hfl.flag_all(dm_in, lists) if len(dm_in) else pd.DataFrame(columns=hfl.DM_COLUMNS)
    comp = hfl.completeness(dm, lists) if len(dm) else pd.DataFrame(columns=hfl.COMP_COLUMNS)
    vint = hd.vintage_mixed(pd.DataFrame(sdates, columns=["state_raw", "fy", "status_date"]),
                            pd.DataFrame(aidates, columns=["fy", "status_date"]))
    return {"district_month": dm, "state_month": _concat(states, hfl.STATE_COLUMNS), "completeness": comp,
            "vintage": vint, "month_total_check": _concat(checks, hd.CHECK_COLUMNS),
            "members": _members_frame(members)}


def _members_frame(members) -> pd.DataFrame:
    m = pd.DataFrame(members, columns=MEMBER_COLUMNS)
    for c in ("units", "excluded_units", "long_rows", "n_cells", "bad_cells"):
        m[c] = m[c].astype("Int64")
    m["seconds"] = m["seconds"].astype(float)
    m["message"] = m["message"].fillna("").astype(str)
    return m


def _error_row(fy, source, member, era, t0, e) -> dict:
    print(f"  {fy} {member}: ERROR {type(e).__name__}: {str(e)[:200]}", flush=True)
    return _member_row(fy, source, member, era, "error", seconds=round(time.time() - t0, 1),
                       message=f"{type(e).__name__}: {str(e)[:300]}")


def flags_fy_zip(zip_path: Path, fy: str, xw) -> dict:
    """One folder-3 FY zip, one member at a time (read in place, never extracted): M/O members excluded by
    name; All_India.xls -> state rows; state workbooks -> district rows, district lists and status dates; the
    month-total check on the crosswalk items. Returns the TABLES frames for this FY."""
    era, zip_path = hp.era_for_fy(fy), Path(zip_path)
    codes = _xw_codes(xw, era)
    with zipfile.ZipFile(zip_path) as z:
        names = [i.filename for i in z.infolist() if not i.is_dir()]
    members, states, districts, checks, lists, sdates, aidates = [], [], [], [], [], [], []
    for member in names:
        source = f"{mf._key(zip_path)}::{member}"
        if hd.is_non_state(member):
            members.append(_member_row(fy, source, member, era, "excluded",
                                       message="non-state central-ministry member (ruling F30)"))
            continue
        t0 = time.time()
        try:
            (_, data), = hp.iter_members(zip_path, only={member})
            long = hp.parse_member(source, data, fy, fy_total=True)
            del data
            n_cells, bad = long.attrs.get("n_cells", 0), long.attrs.get("bad_cells", 0)
            long, n_mo = _drop_non_state(long)
            lists.append(hfl.district_lists(long))
            n_rows, n_units = len(long), len(long[["state_raw", "district_raw"]].drop_duplicates())
            longx = long[long.item_code.isin(codes)]
            del long
            checks.append(hd.month_total_check(longx))
            ind = _with_partial(hx.apply_crosswalk(longx, xw), longx, xw)
        except PARSE_ERRORS as e:
            members.append(_error_row(fy, source, member, era, t0, e))
            continue
        agg = ind[ind.is_state_aggregate]
        states.append(agg)
        districts.append(ind[~ind.is_state_aggregate])
        dates = sorted(set(longx.status_date.dropna())) or [None]
        if len(agg) == len(ind) > 0:                                 # All_India.xls: state rows only
            aidates += [(fy, d) for d in dates]
        else:
            sdates += [(st, fy, d) for st in sorted(set(longx.state_raw)) for d in dates]
        members.append(_member_row(fy, source, member, era, "parsed", units=n_units, excluded_units=n_mo,
                                   long_rows=n_rows, n_cells=n_cells, bad_cells=bad,
                                   seconds=round(time.time() - t0, 1), message=""))
        print(f"  {fy} {member}: {n_units} units, {bad} bad cells, {time.time() - t0:.0f} s", flush=True)
    return _finish(members, states, districts, checks, lists, sdates, aidates)


def flags_fy2021(folder2: Path, folder1: Path, xw) -> dict:
    """FY2020-21 (E3): one .xlsx per state and month (folder 2); the first column group is the state aggregate.
    A state's month files are processed together (partial components need the whole FY). All-India status
    dates come from the folder-1 month files. No FY-total column exists, so there is no month-total check."""
    fy, era = FY2021, "E3"
    codes = _xw_codes(xw, era)
    groups: dict[str, list[Path]] = {}
    for f in sorted(Path(folder2).glob("*.xlsx")):
        groups.setdefault(f.name.split("__")[0], []).append(f)
    members, states, districts, lists, sdates, aidates = [], [], [], [], [], []
    for prefix, files in groups.items():
        inds, longs = [], []
        for f in files:
            source, t0 = mf._key(f), time.time()
            try:
                long = hp.parse_member(source, f.read_bytes(), fy)
                n_cells, bad = long.attrs.get("n_cells", 0), long.attrs.get("bad_cells", 0)
                long, n_mo = _drop_non_state(long)
                lists.append(hfl.district_lists(long))
                longx = long[long.item_code.isin(codes)]
                inds.append(hx.apply_crosswalk(longx, xw))
            except PARSE_ERRORS as e:
                members.append(_error_row(fy, source, f.name, era, t0, e))
                continue
            longs.append(longx)
            dates = sorted(set(longx.status_date.dropna())) or [None]
            sdates += [(st, fy, d) for st in sorted(set(longx[longx.is_state_aggregate].state_raw)) for d in dates]
            members.append(_member_row(fy, source, f.name, era, "parsed",
                                       units=len(long[["state_raw", "district_raw"]].drop_duplicates()),
                                       excluded_units=n_mo, long_rows=len(long), n_cells=n_cells, bad_cells=bad,
                                       seconds=round(time.time() - t0, 1), message=""))
        if not inds:
            continue
        ind = _with_partial(pd.concat(inds, ignore_index=True), pd.concat(longs, ignore_index=True), xw)
        states.append(ind[ind.is_state_aggregate])
        districts.append(ind[~ind.is_state_aggregate])
        print(f"  {fy} {prefix}: {len(files)} month files", flush=True)
    for f in sorted(Path(folder1).glob("*.xlsx")):
        t0 = time.time()
        try:
            aidates.append((fy, hp.parse_status_date(hp.read_table(f.name, f.read_bytes()))))
        except PARSE_ERRORS as e:
            members.append(_error_row(fy, mf._key(f), f.name, era, t0, e))
    return _finish(members, states, districts, [], lists, sdates, aidates)


def _notes(fy: str, members: pd.DataFrame, concordance: str) -> str:
    m = members[members.fy == fy]
    excl = [Path(str(x)).name for x in m[m.status == "excluded"].member]
    rows = int(pd.to_numeric(m.excluded_units, errors="coerce").fillna(0).sum())
    parts = [f"excluded non-state members: {len(excl)}" + (f" ({', '.join(excl)})" if excl else ""),
             f"excluded non-state rows in parsed files: {rows} units"]
    n_err = int((m.status == "error").sum())
    if n_err:
        parts.append(f"{n_err} member errors")
    if fy == FY2021:
        parts.append("FY2020-21 state-month files have no FY-total column, so no month-total check")
    parts.append(concordance)
    return "; ".join(parts)


def _concordance_note(discovery: dict) -> str:
    ups = discovery.get("upload_status", [])
    if any(u.get("anonymous") for u in ups):
        return ("upload-status concordance not run: an anonymous data uploading status report is listed but "
                "not acquired; the inferred nonreport flag is kept")
    return (f"upload-status concordance skipped: no anonymous data uploading status report ({len(ups)} listed, "
            "all login-only); nonreport is inferred (spec §3.6)")


def flags(out_dir: Path = PARTS, report_path: Path = FLAG_REPORT, root: Path | None = None, fys=None,
          xw_path: Path = hx.XW_PATH, discovery: dict | None = None) -> dict:
    """The Task 3 step: every FY (default FY2012-13..2019-20, plus FY2020-21 when its folder exists), member by
    member. Writes the TABLES to `out_dir` (git-ignored) and the counts-only report to `report_path`."""
    root = Path(root or _root())
    xw = hx.load_crosswalk(xw_path)
    if discovery is None:
        discovery = _read_json(root / "discovery.json")
    fys = list(fys) if fys else list(PRIMARY_FYS) + [FY2021]
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for fy in fys:
        if hf.free_bytes(out_dir) < MIN_FREE_BYTES:
            raise RuntimeError("less than 2 GB free on the data drive; stopped")
        t0 = time.time()
        if fy == FY2021:
            d2, d1 = root / FOLDER2_FY2021, root / FOLDER1_FY2021
            if not d2.exists():
                print(f"{fy}: {mf._key(d2)} absent; skipped")
                continue
            res = flags_fy2021(d2, d1, xw)
        else:
            y = int(fy[:4])
            z = root / FOLDER3 / f"{y}-{y + 1}.zip"
            if not z.exists():
                print(f"{fy}: {mf._key(z)} absent; skipped")
                continue
            res = flags_fy_zip(z, fy, xw)
        results.append(res)
        print(f"{fy}: done in {time.time() - t0:.0f} s", flush=True)
    tables = {}
    for k in TABLES:
        cols = list(results[0][k].columns) if results else []
        tables[k] = _concat([r[k] for r in results], cols)
        tables[k].to_csv(out_dir / f"{k}.csv.gz", index=False)
    conc = _concordance_note(discovery)
    notes = {fy: _notes(fy, tables["members"], conc) for fy in sorted(set(tables["members"].fy))}
    rep = hfl.flag_report(tables["district_month"], tables["state_month"], tables["month_total_check"],
                          tables["vintage"], xw, notes)
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    rep.to_csv(report_path, index=False, float_format="%.6f")
    mem = tables["members"]
    return {"report": rep, "tables": tables, "errors": int((mem.status == "error").sum()),
            "excluded": mem[mem.status == "excluded"].member.tolist()}


# ---- Task 4: national totals (ruling F39) and the state-month panel ----------------------------------------------
FOLDER1 = "hmis_c2_1_all_india"
NATIONAL_PART = PARTS / "national_month.csv.gz"
NATIONAL_COLUMNS = ["fy", "month", "indicator", "all_india", "mo_in_national", "mo_value", "national",
                    "status_date", "source_file", "note"]


def _national_from_long(long, xw) -> tuple[pd.DataFrame, bool, pd.DataFrame]:
    """(All India rows per month x indicator, whether the file has M/O columns, M/O sums per month x indicator)."""
    codes = _xw_codes(xw, hp.era_for_fy(long.fy.iloc[0]))
    ind = hx.apply_crosswalk(long[long.item_code.isin(codes)], xw)
    is_ai = ind.state_raw.str.strip().str.lower() == "all india"
    is_mo = ind.state_raw.map(hd.is_non_state)
    mo = ind[is_mo].groupby(["fy", "month", "indicator"])["value"].sum(min_count=1).rename("mo_value").reset_index()
    return ind[is_ai][["fy", "month", "indicator", "value", "status_date", "source_file"]], bool(is_mo.any()), mo


def _national_month_files(zip_path: Path) -> dict[int, str]:
    """Calendar month -> member of the zip's A.MonthWise folder (the B.Cummulative files are not used)."""
    with zipfile.ZipFile(zip_path) as z:
        names = [i.filename for i in z.infolist() if not i.is_dir()]
    out = {}
    for n in names:
        parts = n.replace("\\", "/").split("/")
        if len(parts) >= 2 and parts[-2].lower().replace(".", "").replace(" ", "") == "amonthwise":
            out[hp.month_from_name(parts[-1])] = n
    return out


def _mo_all_india_xls(zip3: Path, fy: str, xw) -> pd.DataFrame:
    """M/O Defence and M/O Railways rows of the folder-3 All_India.xls, summed per month x indicator (F39)."""
    if not zip3.exists():
        return pd.DataFrame(columns=["fy", "month", "indicator", "mo_value"])
    with zipfile.ZipFile(zip3) as z:
        member = next((i.filename for i in z.infolist() if i.filename.lower().endswith("/all_india.xls")), None)
    if member is None:
        return pd.DataFrame(columns=["fy", "month", "indicator", "mo_value"])
    (_, data), = hp.iter_members(zip3, only={member})
    long = hp.parse_member(f"{mf._key(zip3)}::{member}", data, fy)
    long = long[long.state_raw.map(hd.is_non_state)]
    if long.empty:
        return pd.DataFrame(columns=["fy", "month", "indicator", "mo_value"])
    ind = hx.apply_crosswalk(long[long.item_code.isin(_xw_codes(xw, hp.era_for_fy(fy)))], xw)
    return ind.groupby(["fy", "month", "indicator"])["value"].sum(min_count=1).rename("mo_value").reset_index()


def national_fy(fy: str, files: dict, read, xw, mo_xls: pd.DataFrame | None) -> pd.DataFrame:
    """NATIONAL_COLUMNS for one FY. `files`: calendar month -> source name; `read(name)` -> bytes. M/O values come
    from `mo_xls` (All_India.xls) when given, else from the national file's own M/O columns (FY2020-21)."""
    rows = []
    for m in hd.FY_MONTHS:
        base = {"fy": fy, "month": m, "all_india": np.nan, "mo_in_national": False, "mo_value": np.nan,
                "status_date": None, "source_file": "", "note": ""}
        name = files.get(m)
        if name is None:
            rows += [dict(base, indicator=i, note="no month file") for i in hx.INDICATORS]
            continue
        try:
            long = hp.parse_national(name, read(name), fy)
            ai, has_mo, mo_own = _national_from_long(long, xw)
        except PARSE_ERRORS as e:
            rows += [dict(base, indicator=i, source_file=name, note=f"not parsed: {str(e)[:120]}")
                     for i in hx.INDICATORS]
            continue
        mo = mo_xls if mo_xls is not None else mo_own
        mo_v = {r.indicator: r.mo_value for r in mo[mo.month == m].itertuples()} if len(mo) else {}
        av = {r.indicator: (r.value, r.status_date) for r in ai.itertuples()}
        for i in hx.INDICATORS:
            v, d = av.get(i, (np.nan, None))
            rows.append(dict(base, indicator=i, all_india=v, mo_in_national=has_mo, mo_value=mo_v.get(i, np.nan),
                             status_date=d, source_file=name,
                             note="" if i in av else "item absent from the national file"))
    out = pd.DataFrame(rows)
    sub = out.mo_value.fillna(0.0).where(out.mo_in_national, 0.0)
    out["national"] = out.all_india - sub
    return out[NATIONAL_COLUMNS]


def national(out: Path = NATIONAL_PART, root: Path | None = None, fys=None, xw_path: Path = hx.XW_PATH) -> pd.DataFrame:
    """The folder-1 All India month files (A.MonthWise; FY2020-21: hmis_c2_1_all_india_fy2021), net of the M/O rows
    of the folder-3 All_India.xls (ruling F39), to `out` (git-ignored). A month whose file is absent or cannot be
    parsed (two FY2017-18 BIFF workbooks) has national NaN and a note; the gate reads it as "not available"."""
    root = Path(root or _root())
    xw = hx.load_crosswalk(xw_path)
    fys = list(fys) if fys else list(PRIMARY_FYS) + [FY2021]
    frames = []
    for fy in fys:
        t0 = time.time()
        if fy == FY2021:
            d1 = root / FOLDER1_FY2021
            files = {hp.month_from_name(f.name): f.name for f in sorted(d1.glob("*.xlsx"))} if d1.exists() else {}
            frames.append(national_fy(fy, files, lambda n: (d1 / n).read_bytes(), xw, None))
        else:
            y = int(fy[:4])
            z1, z3 = root / FOLDER1 / f"{y}-{y + 1}.zip", root / FOLDER3 / f"{y}-{y + 1}.zip"
            files = _national_month_files(z1) if z1.exists() else {}
            mo = _mo_all_india_xls(z3, fy, xw)

            def read(n, z1=z1):
                (_, data), = hp.iter_members(z1, only={n})
                return data
            nat = national_fy(fy, files, read, xw, mo)
            nat["source_file"] = [f"{mf._key(z1)}::{s}" if s else "" for s in nat.source_file]
            frames.append(nat)
        print(f"  national {fy}: {frames[-1].national.notna().sum()} of {len(frames[-1])} indicator-months, "
              f"{time.time() - t0:.0f} s", flush=True)
    res = pd.concat(frames, ignore_index=True)[NATIONAL_COLUMNS]
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    res.to_csv(out, index=False)
    return res


def panel_step(parts: Path = PARTS, refresh_national: bool = False, **kw) -> dict:
    """`national` (when its part is absent or refresh_national) then panel.build_outputs."""
    from pipeline.hmis import panel as hpn
    if refresh_national or not (Path(parts) / NATIONAL_PART.name).exists():
        national(out=Path(parts) / NATIONAL_PART.name)
    return hpn.build_outputs(parts=parts, **kw)


def model_table_step(climate_out: Path | None = None, model_out: Path | None = None) -> dict:
    """climate_month.build then model_table.build_model_table (Task 5); returns paths, row counts, NaN shares."""
    from pipeline.hmis import climate_month as hcm
    from pipeline.hmis import model_table as hmt
    climate_out = Path(climate_out or hcm.OUT_PATH)
    model_out = Path(model_out or hmt.MODEL_PATH)
    hcm.build(out=climate_out)
    hmt.build_model_table(out=model_out, climate_path=climate_out)
    cl = pd.read_csv(climate_out, usecols=["unit_id", "ym"])
    m = pd.read_csv(model_out, usecols=["unit_id", "ym", "in_primary"])
    return {"climate": climate_out, "model": model_out, "climate_rows": len(cl), "climate_units": cl.unit_id.nunique(),
            "model_rows": len(m), "model_units": m.unit_id.nunique(), "primary_rows": int(m.in_primary.sum()),
            "nan_share": hmt.primary_nan_share(model_out), "srs": hmt.SRS_STATUS}


def _print_model_table_summary(res: dict) -> None:
    print(f"{res['climate']}: {res['climate_rows']} rows, {res['climate_units']} units")
    print(f"{res['model']}: {res['model_rows']} rows, {res['model_units']} units, "
          f"{res['primary_rows']} in the primary window")
    with pd.option_context("display.width", 200, "display.max_rows", 100):
        print(res["nan_share"].to_string(index=False, float_format=lambda x: f"{x:.3f}"))
    print("births/pregnancies offsets:", res["srs"])


def _print_panel_summary(res: dict) -> None:
    from pipeline.validate import format_result
    for r in res["results"]:
        print(format_result(r))
    cols = ["indicator", "scope", "reported", "masked", "masked_share", "comp_lt_090", "entering_models", "dropped",
            "masked_plausibility", "masked_district_sum", "masked_national_total", "national_not_available"]
    with pd.option_context("display.width", 250, "display.max_columns", 30):
        print(res["summary"][cols].to_string(index=False))
        print(res["breaks"].to_string(index=False))
    print("status dates:", res["status_dates"])
    print("dropped:", res["dropped"] or "none", "| unusable FYs:", res["unusable"] or "none",
          "| halt:", res["halt"] or "none")


def _print_flags_summary(out: dict) -> None:
    rep, t = out["report"], out["tables"]
    cols = ["indicator", "fy", "n_district_months", "negative", "nonreport", "catchup", "nofile",
            "share_flagged", "vintage_mixed", "month_total_checked", "month_total_fail", "state_months",
            "partial_component", "state_all_components_share", "district_all_components_share"]
    with pd.option_context("display.width", 250, "display.max_rows", 500, "display.max_columns", 30):
        print("\nFlag counts and shares by indicator x FY (no values):")
        print(rep[cols].to_string(index=False))
    vm = rep[rep.n_district_months > 0]
    high = vm[vm.vintage_mixed / vm.n_district_months > 0.05]
    print("\nvintage_mixed state-FYs:", int(t["vintage"].vintage_mixed.astype(bool).sum()),
          "| indicator x FY with vintage_mixed > 5% of district-months:",
          high[["indicator", "fy"]].values.tolist() or "none")
    print("partial_component share > 5%:",
          rep[rep.partial_component > 0.05][["indicator", "fy"]].values.tolist() or "none")
    mem = t["members"]
    print("members:", mem.status.value_counts().to_dict(), "| excluded:", out["excluded"])
    bad = mem[pd.to_numeric(mem.bad_cells, errors="coerce").fillna(0) > 0]
    print("members with unparseable value cells:",
          bad[["fy", "member", "bad_cells", "n_cells"]].values.tolist() or "none")
    for r in mem[mem.status == "error"].itertuples():
        print(f"ERROR {r.fy} {r.member}: {r.message}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("step", choices=["discover", "fetch", "report", "parse", "flags", "difference", "national",
                                     "panel", "model-table", "sources"])
    ap.add_argument("--fy", nargs="*", help="with flags / national: the FYs to run (default: all)")
    ap.add_argument("--refresh-national", action="store_true", help="with panel: rebuild the national part")
    ap.add_argument("--fy2021", action="store_true", help="with fetch: run the FY2020-21 job")
    ap.add_argument("--sample", action="store_true", help="with parse: one member per FY (Task 2 check)")
    a = ap.parse_args(argv)
    if a.step == "discover":
        discover()
    elif a.step == "fetch" and a.fy2021:
        fetch_fy2021()
    elif a.step == "fetch":
        fetch_primary()
    elif a.step == "parse":
        if not a.sample:
            ap.error("parse needs --sample (the full parse is Task 3)")
        parse_sample()
    elif a.step in ("flags", "difference"):
        out = flags(fys=a.fy)
        _print_flags_summary(out)
        return 1 if out["errors"] else 0
    elif a.step == "national":
        nat = national(fys=a.fy)
        print(f"{nat.national.notna().sum()} of {len(nat)} indicator-months with a national value -> {NATIONAL_PART}")
    elif a.step == "panel":
        res = panel_step(refresh_national=a.refresh_national)
        _print_panel_summary(res)
        return 2 if res["halt"] else 0
    elif a.step == "model-table":
        _print_model_table_summary(model_table_step())
    elif a.step == "sources":
        from pipeline.hmis import sources_md as sm
        out = sm.sources_md()
        print(f"wrote {out}: {len(sm.hmis_rows())} HMIS MANIFEST rows, {len(sm.external_rows())} external inputs")
    else:
        report()
    return 0


if __name__ == "__main__":
    sys.exit(main())
