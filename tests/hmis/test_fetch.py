"""HMIS acquisition: polite session, challenge stop, budget, verified cache (fake sessions and clocks only)."""
import base64
import csv
import hashlib
import json

import pytest

from pipeline import manifest as mf
from pipeline.hmis import fetch as hf
from pipeline.outcomes import fetch as of
from pipeline.paths import MANIFEST_PATH


@pytest.fixture(autouse=True)
def _real_manifest_untouched():
    """No test in this module may write the tracked data/MANIFEST.csv."""
    before = mf.sha256_file(MANIFEST_PATH) if MANIFEST_PATH.exists() else None
    yield
    after = mf.sha256_file(MANIFEST_PATH) if MANIFEST_PATH.exists() else None
    assert before == after, "a test wrote data/MANIFEST.csv"


class Resp:
    def __init__(self, content=b"PK\x03\x04zipdata", status=200, url=None):
        self.content, self.status_code, self.url = content, status, url


class FakeSession:
    """Returns queued responses (the last one repeats); records every call."""

    def __init__(self, *responses):
        self.responses = list(responses) or [Resp()]
        self.calls = []

    def get(self, url, headers=None, timeout=None, **kw):
        self.calls.append({"url": url, "headers": dict(headers or {}), "timeout": timeout, **kw})
        r = self.responses.pop(0) if len(self.responses) > 1 else self.responses[0]
        if r.url is None:
            return Resp(r.content, r.status_code, url)
        return r


def polite(tmp_path, inner, interval=0.0, budget=None, log="request_log.csv"):
    return hf.PoliteSession(interval, tmp_path / log, budget=budget, session=inner,
                            clock=lambda: 0.0, sleep=lambda s: None)


def zip_row(name="x.zip", source_id="hmis_fy1415", folder="all_states_months"):
    return {"source_id": source_id, "fy": "2014-15", "folder": folder, "listing_path": "Standard Reports/x",
            "file_name": name, "url": f"https://hmis.example/downloadfiles?filepath={name}",
            "kind": name.rsplit(".", 1)[-1], "bytes_listed": ""}


@pytest.fixture
def hroot(tmp_path, monkeypatch):
    root = tmp_path / "raw_hmis"
    monkeypatch.setattr(hf, "HMIS_ROOT", root)
    monkeypatch.setattr(hf, "free_bytes", lambda path: 50 * 1024**3)
    return root


def manifest_rows(path):
    return mf.read(path)


# ---------------------------------------------------------------------------- PoliteSession


def test_polite_session_spaces_requests(tmp_path):
    t, sleeps = [0.0], []
    inner = FakeSession()
    ps = hf.PoliteSession(5.0, tmp_path / "log.csv", session=inner, clock=lambda: t[0], sleep=sleeps.append)
    ps.get("https://hmis.example/a")
    t[0] = 1.0
    ps.get("https://hmis.example/b")
    assert sleeps == [4.0]
    assert ps.n_logged() == 2
    with open(tmp_path / "log.csv", newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    assert [r["url"] for r in rows] == ["https://hmis.example/a", "https://hmis.example/b"]
    assert set(rows[0]) == {"url", "utc", "status", "bytes"} and rows[0]["status"] == "200"


def test_html_200_instead_of_zip_stops_run_without_caching(tmp_path, hroot):
    man = tmp_path / "MANIFEST.csv"
    captcha = FakeSession(Resp(b"<html><body>Please solve the reCAPTCHA</body></html>"))
    with pytest.raises(hf.ChallengeDetected):
        hf.download(zip_row(), polite(tmp_path, captcha), manifest=man)
    assert captcha.calls and len(captcha.calls) == 1

    plain = FakeSession(Resp(b"<html><body>Not found</body></html>"))
    with pytest.raises(of.FetchError):
        hf.download(zip_row(), polite(tmp_path, plain), manifest=man)
    assert len(plain.calls) == 1
    assert not any(hroot.rglob("*.zip")) and not any(hroot.rglob("*.part"))
    assert manifest_rows(man) == []
    assert not issubclass(hf.ChallengeDetected, hf.requests.RequestException)
    assert not issubclass(hf.BudgetExceeded, hf.requests.RequestException)


def test_repeated_403_raises_challenge_same_headers(tmp_path, hroot):
    inner = FakeSession(Resp(b"Forbidden", status=403))
    with pytest.raises(hf.ChallengeDetected, match="403"):
        hf.download(zip_row(), polite(tmp_path, inner), manifest=tmp_path / "M.csv")
    assert len(inner.calls) == 2                                    # one retry, then stop: no 3rd attempt
    assert inner.calls[0]["headers"] == inner.calls[1]["headers"] == of.UA   # no user-agent rotation


def test_single_403_then_ok_is_not_a_challenge(tmp_path):
    inner = FakeSession(Resp(b"Forbidden", status=403), Resp(b"ok"), Resp(b"Forbidden", status=403))
    ps = polite(tmp_path, inner)
    assert ps.get("https://hmis.example/a").status_code == 403
    assert ps.get("https://hmis.example/b").status_code == 200
    assert ps.get("https://hmis.example/c").status_code == 403    # counter reset by the 200


@pytest.mark.parametrize("status", [401, 407, 429])
def test_auth_and_rate_limit_statuses_are_challenges(tmp_path, status):
    with pytest.raises(hf.ChallengeDetected, match=str(status)):
        polite(tmp_path, FakeSession(Resp(b"", status=status))).get("https://hmis.example/a")


def test_login_redirect_detected(tmp_path):
    inner = FakeSession(Resp(b"PK\x03\x04", url="https://hmis.mohfw.gov.in/login?next=/x.zip"))
    ps = polite(tmp_path, inner)
    with pytest.raises(hf.ChallengeDetected, match="login"):
        ps.get("https://hmis.mohfw.gov.in/downloadfiles?filepath=x.zip")
    with open(ps.challenge_log, newline="", encoding="utf-8") as fh:
        assert "login" in list(csv.DictReader(fh))[0]["message"]                # every challenge is recorded
    # a query string mentioning login is not a redirect to a login page
    ok = FakeSession(Resp(b"[]", url="https://hmis.mohfw.gov.in/getFiles?fpath=bG9naW4="))
    assert polite(tmp_path, ok).get("https://hmis.mohfw.gov.in/getFiles?fpath=bG9naW4=").status_code == 200


def test_resume_skips_verified_cache_and_counts_budget_across_runs(tmp_path, hroot):
    man = tmp_path / "MANIFEST.csv"
    row = zip_row("x.zip")
    dest = hroot / row["source_id"] / "x.zip"
    # (a) cached zip with a matching MANIFEST row -> no request
    dest.parent.mkdir(parents=True)
    dest.write_bytes(b"PK\x03\x04cached")
    mf.record(dest, row["url"], manifest=man)
    inner = FakeSession()
    assert hf.download(row, polite(tmp_path, inner), manifest=man) == dest and inner.calls == []
    # (b) a stale partial download is overwritten by a fresh download
    row_b = zip_row("y.zip")
    part = hroot / row_b["source_id"] / "y.zip.part"
    part.write_bytes(b"PK\x03\x04trunc")
    inner = FakeSession(Resp(b"PK\x03\x04fresh"))
    got = hf.download(row_b, polite(tmp_path, inner), manifest=man)
    assert got.read_bytes() == b"PK\x03\x04fresh" and not part.exists() and len(inner.calls) == 1
    assert of.manifest_sha(got, manifest=man) == mf.sha256_file(got)
    # (c) cached bytes changed after recording -> CacheIntegrityError, no request
    dest.write_bytes(b"PK\x03\x04tampered")
    inner = FakeSession()
    with pytest.raises(of.CacheIntegrityError):
        hf.download(row, polite(tmp_path, inner), manifest=man)
    assert inner.calls == []
    # (d) the budget counts rows already in the log from earlier runs
    log = tmp_path / "budget_log.csv"
    with open(log, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["url", "utc", "status", "bytes"])
        w.writerows([[f"https://hmis.example/{i}", "2026-10-24T00:00:00Z", "200", "1"] for i in range(9_999)])
    inner = FakeSession()
    ps = hf.PoliteSession(0.0, log, budget=hf.FY2021_BUDGET, session=inner, clock=lambda: 0.0,
                          sleep=lambda s: None)
    assert ps.n_logged() == 9_999
    ps.get("https://hmis.example/ok")
    with pytest.raises(hf.BudgetExceeded):
        ps.get("https://hmis.example/over")
    assert len(inner.calls) == 1 and ps.n_logged() == 10_000


def test_download_refuses_when_disk_low(tmp_path, hroot, monkeypatch):
    monkeypatch.setattr(hf, "free_bytes", lambda path: hf.MIN_FREE_BYTES - 1)
    inner = FakeSession()
    with pytest.raises(RuntimeError, match="free"):
        hf.download(zip_row(), polite(tmp_path, inner), manifest=tmp_path / "M.csv")
    assert inner.calls == []
    # a listed size that would take free space below the floor is refused as well
    monkeypatch.setattr(hf, "free_bytes", lambda path: hf.MIN_FREE_BYTES + 10)
    with pytest.raises(RuntimeError, match="free"):
        hf.download({**zip_row(), "bytes_listed": "11"}, polite(tmp_path, inner), manifest=tmp_path / "M.csv")
    assert inner.calls == []


def test_no_email_in_any_request(tmp_path, hroot):
    inner = FakeSession(Resp(b'[{"name": "a.zip"}]'), Resp(b"PK\x03\x04data"))
    ps = polite(tmp_path, inner)
    man = tmp_path / "M.csv"
    hf.list_folder("Data/C2/3", ps, manifest=man)
    hf.download(zip_row(), ps, manifest=man)
    assert len(inner.calls) == 2
    for call in inner.calls:
        assert "@" not in call["url"]
        assert all("@" not in str(v) for v in call["headers"].values())
        assert all("@" not in str(v) for v in (call.get("params") or {}).values())
    with pytest.raises(ValueError, match="@"):
        ps.get("https://hmis.example/a", headers={"From": "someone@example.org"})
    assert len(inner.calls) == 2


# ---------------------------------------------------------------------------- listings


def test_list_folder_caches_json_with_manifest_row(tmp_path, hroot):
    man = tmp_path / "M.csv"
    inner = FakeSession(Resp(b'[{"name": "2014-2015.zip", "size": "13 MB"}]'))
    ps = polite(tmp_path, inner)
    got = hf.list_folder("Data/C2/3", ps, manifest=man)
    assert got == [{"name": "2014-2015.zip", "size": "13 MB"}]
    # base64 of the UTF-8 path, unquoted, as the portal's own script sends it
    assert inner.calls[0]["url"] == hf.LIST_URL + base64.b64encode(b"Data/C2/3").decode()
    cached = hroot / "listings" / (hashlib.sha1(b"Data/C2/3").hexdigest() + ".json")
    assert json.loads(cached.read_text(encoding="utf-8")) == got
    assert [r["path"] for r in manifest_rows(man)] == [mf._key(cached)]
    assert hf.list_folder("Data/C2/3", ps, manifest=man) == got and len(inner.calls) == 1   # cache hit


def test_list_folder_rejects_non_json_without_caching(tmp_path, hroot):
    man = tmp_path / "M.csv"
    inner = FakeSession(Resp(b"<html><body>Server error</body></html>"))
    with pytest.raises(of.FetchError):
        hf.list_folder("Data/C2/3", polite(tmp_path, inner), manifest=man)
    assert not any(hroot.rglob("*.json")) and manifest_rows(man) == []


# ---------------------------------------------------------------------------- FY2020-21 job


def _acquire(tmp_path, inner, **kw):
    return hf.acquire_fy2021(lambda: polite(tmp_path, inner, budget=hf.FY2021_BUDGET, log="fy21_log.csv"),
                             out_dir=tmp_path / "raw_hmis", status_path=tmp_path / "fy2021_status.json",
                             manifest=tmp_path / "manifest_parts" / "hmis_fy2021.csv", **kw)


def test_fy2021_plan_over_budget_drops_without_downloads(tmp_path, hroot, monkeypatch):
    calls = []
    monkeypatch.setattr(hf, "plan_fy2021", lambda session, **k: ([zip_row()] * 10_001, 10_001))
    monkeypatch.setattr(hf, "download", lambda *a, **k: calls.append(a))
    status = _acquire(tmp_path, FakeSession())
    assert status["status"] == "dropped" and "10001" in status["reason"] and calls == []
    assert json.loads((tmp_path / "fy2021_status.json").read_text(encoding="utf-8")) == status
    assert set(status) == {"status", "reason", "n_requests", "n_files"}


def test_fy2021_challenge_drops(tmp_path, hroot, monkeypatch):
    def plan(session, **k):
        raise hf.ChallengeDetected("HTTP 429 at https://hmis.example/x")
    monkeypatch.setattr(hf, "plan_fy2021", plan)
    status = _acquire(tmp_path, FakeSession())
    assert status["status"] == "dropped" and "429" in status["reason"]


def test_fy2021_acquired_writes_manifest_part_only(tmp_path, hroot, monkeypatch):
    rows = [zip_row(f"d{i}.xlsx", source_id="hmis_fy2021_ST") for i in range(3)]
    monkeypatch.setattr(hf, "plan_fy2021", lambda session, **k: (rows, 5))
    inner = FakeSession(Resp(b"PK\x03\x04xlsx"))
    status = _acquire(tmp_path, inner)
    assert status == {"status": "acquired", "reason": "all 3 planned files downloaded and verified",
                      "n_requests": 3, "n_files": 3}
    part = tmp_path / "manifest_parts" / "hmis_fy2021.csv"
    assert len(manifest_rows(part)) == 3
    # rerun: everything verified from cache, no new requests
    status2 = _acquire(tmp_path, inner)
    assert status2["status"] == "acquired" and len(inner.calls) == 3


def test_merge_manifest_part(tmp_path):
    main, part = tmp_path / "MANIFEST.csv", tmp_path / "part.csv"
    base = {"retrieved_utc": "2026-10-24T00:00:00Z", "bytes": "1", "deleted": "0"}
    mf._write([{**base, "path": "a", "url": "ua", "sha256": "1"}, {**base, "path": "b", "url": "ub", "sha256": "2"}],
              main)
    mf._write([{**base, "path": "b", "url": "ub", "sha256": "3"}, {**base, "path": "c", "url": "uc", "sha256": "4"}],
              part)
    assert hf.merge_manifest_part(part, main) == 2
    got = {r["path"]: r["sha256"] for r in mf.read(main)}
    assert got == {"a": "1", "b": "3", "c": "4"}
    assert hf.merge_manifest_part(part, main) == 2 and len(mf.read(main)) == 3      # idempotent
    with pytest.raises(FileNotFoundError):
        hf.merge_manifest_part(tmp_path / "absent.csv", main)


# ---------------------------------------------------------------------------- portal tree (synthetic)

B = "BASEDIR/Standard Reports"
C2 = f"{B}/5~C2. Data Itemwise Monthly (up to sub district)"


def _d(path, name=None):
    return {"path": path, "name": name or path.rsplit("/", 1)[-1], "isdirectory": True, "fileSize": "0.00 MB",
            "parentDirectory": path.rsplit("/", 1)[0]}


def _f(path, size="1.50 MB"):
    return {"path": path, "name": path.rsplit("/", 1)[-1], "isdirectory": False, "fileSize": size,
            "parentDirectory": path.rsplit("/", 1)[0]}


def synthetic_tree():
    f1, f2, f3, f4 = (f"{C2}/1. All India Across States", f"{C2}/2. All States Across Districts",
                      f"{C2}/3. All States and Districts Across Months", f"{C2}/4. All Districts Across Subdistricts")
    fy21 = "2020-2021(Data is Provisional)"
    tree = {
        B: [_d(f"{B}/1~A.1. Data Reporting Status (Upto District Level)--L"), _d(C2),
            _d(f"{B}/9~F.1. Performance of Key HMIS Indicators(upto District Level)")],
        C2: [_d(f1), _d(f2), _d(f3), _d(f4), _d(f"{C2}/7. All India Across State Across Financial Year--L")],
        f1: [_f(f"{f1}/2011-2012.zip"), _f(f"{f1}/2012-2013.zip"), _f(f"{f1}/2019-2020.zip"), _d(f"{f1}/{fy21}"),
             _d(f"{f1}/2022-2023")],
        f"{f1}/{fy21}": [_d(f"{f1}/{fy21}/A.MonthWise"), _d(f"{f1}/{fy21}/B.Cummulative")],
        f"{f1}/{fy21}/A.MonthWise": [_f(f"{f1}/{fy21}/A.MonthWise/A-Apr.xlsx", "0.42 MB"),
                                     _f(f"{f1}/{fy21}/A.MonthWise/B-May.xlsx", "0.43 MB")],
        f2: [_f(f"{f2}/2019-2020.zip"), _d(f"{f2}/{fy21}")],
        f"{f2}/{fy21}": [_d(f"{f2}/{fy21}/A.MonthWise")],
        f"{f2}/{fy21}/A.MonthWise": [_d(f"{f2}/{fy21}/A.MonthWise/State A"),
                                     _d(f"{f2}/{fy21}/A.MonthWise/State B & C")],
        f"{f2}/{fy21}/A.MonthWise/State A": [_f(f"{f2}/{fy21}/A.MonthWise/State A/A-State A_Apr.xlsx", "0.05 MB"),
                                             _f(f"{f2}/{fy21}/A.MonthWise/State A/B-State A_May.xlsx", "0.05 MB")],
        f"{f2}/{fy21}/A.MonthWise/State B & C": [
            _f(f"{f2}/{fy21}/A.MonthWise/State B & C/A-State B & C_Apr.xlsx", "0.05 MB")],
        f3: [_f(f"{f3}/2011-2012.zip", "15.39 MB"), _f(f"{f3}/2012-2013.zip", "15.65 MB"),
             _f(f"{f3}/2019-2020.zip", "50.14 MB")],
        f4: [_f(f"{f4}/2018-2019.zip", "758.88 MB"), _f(f"{f4}/2019-2020.zip", "765.06 MB"), _d(f"{f4}/{fy21}")],
    }
    return {hf.portal_path(k): v for k, v in tree.items()}


class PortalSession(FakeSession):
    """Answers getFiles?fpath=<b64> from a synthetic tree; fails the test on any other path."""

    def __init__(self, tree):
        super().__init__()
        self.tree, self.listed = tree, []

    def get(self, url, headers=None, timeout=None, **kw):
        self.calls.append({"url": url, "headers": dict(headers or {}), "timeout": timeout})
        assert url.startswith(hf.LIST_URL), url
        path = base64.b64decode(url[len(hf.LIST_URL):]).decode("utf-8")
        assert path in self.tree, f"listed a path outside the anonymous tree: {path}"
        self.listed.append(path)
        return Resp(json.dumps(self.tree[path]).encode(), url=url)


def test_anonymous_view_mirrors_portal_filter():
    entries = [_d(f"{B}/x--L"), _d(f"{B}/y--P"), _d(f"{B}/z"), _d(f"{B}/2023-2024"),
               _f(f"{B}/2021-2022/A-X_Apr.xlsx"), _f(f"{B}/2021-2022/C-X_Jun.xlsx"), _f(f"{B}/2020-2021/C-X_Jun.xlsx"),
               _f(f"{B}/2022-2023/a.xlsx")]
    shown = [e["path"].rsplit(f"{B}/", 1)[1] for e in hf.anonymous_view(entries)]
    assert shown == ["y--P", "z", "2021-2022/A-X_Apr.xlsx", "2020-2021/C-X_Jun.xlsx"]
    assert hf.display_name({"name": "5~C2. Data Itemwise Monthly (up to sub district)"}) == \
        "C2. Data Itemwise Monthly (up to sub district)"
    assert hf.display_name({"name": "7. All India--L"}) == "7. All India"


def test_paths_and_urls():
    assert hf.portal_path(f"{B}/a & b/c.zip") == "Standard Reports/a ::: b/c.zip"
    assert hf.download_url(f"{B}/3. All/2014-2015.zip") == \
        hf.DOWNLOAD_URL + "/Standard%20Reports/3.%20All/2014-2015.zip"
    assert hf.download_url(f"{B}/S & T/x(1).xlsx") == hf.DOWNLOAD_URL + "/Standard%20Reports/S%20:::%20T/x(1).xlsx"
    assert hf.fy_label("2014-2015.zip") == "2014-15" and hf.fy_label("2020-2021(Data is Provisional)") == "2020-21"
    assert hf.fy_label("A.MonthWise") is None and hf.fy_label("2014-2016") is None
    assert hf.listed_bytes({"fileSize": "1.50 MB"}) == str(int(1.5 * 1024**2)) and hf.listed_bytes({}) == ""


def test_discover_lists_only_anonymous_folders(tmp_path, hroot):
    inner = PortalSession(synthetic_tree())
    out = hf.discover(polite(tmp_path, inner), manifest=tmp_path / "M.csv")
    rows = out["rows"]
    assert {(r["folder"], r["fy"], r["file_name"]) for r in rows} == {
        ("all_states_months", "2012-13", "2012-2013.zip"), ("all_states_months", "2019-20", "2019-2020.zip"),
        ("all_india", "2012-13", "2012-2013.zip"), ("all_india", "2019-20", "2019-2020.zip"),
        ("all_india", "2020-21", "A-Apr.xlsx"), ("all_india", "2020-21", "B-May.xlsx"),
        ("subdistrict_months_1920", "2019-20", "2019-2020.zip")}
    assert all(r["url"].startswith(hf.DOWNLOAD_URL) for r in rows)
    assert {r["kind"] for r in rows} == {"zip", "xlsx"}
    assert next(r for r in rows if r["folder"] == "subdistrict_months_1920")["bytes_listed"] == \
        str(int(round(765.06 * 1024**2)))
    assert out["upload_status"] == [{"name": "A.1. Data Reporting Status (Upto District Level)",
                                     "raw_name": "1~A.1. Data Reporting Status (Upto District Level)--L",
                                     "anonymous": False}]
    assert out["fy2021_state_level"] == {"folder1_monthwise_files": 2, "folder2_monthwise_states": 2}
    assert not any("--L" in p or "2022-2023" in p for p in inner.listed)
    hf.write_sources(rows, tmp_path / "sources.csv")
    assert hf.read_sources(tmp_path / "sources.csv") == [{k: r[k] for k in hf.SOURCE_FIELDS} for r in rows]


def test_plan_fy2021_counts_listings_and_files(tmp_path, hroot):
    inner = PortalSession(synthetic_tree())
    rows, n = hf.plan_fy2021(polite(tmp_path, inner), manifest=tmp_path / "part.csv")
    assert [r["file_name"] for r in rows] == ["State_A__A-State_A_Apr.xlsx", "State_A__B-State_A_May.xlsx",
                                              "State_B_C__A-State_B_C_Apr.xlsx"]
    assert {r["folder"] for r in rows} == {"district_months_2021"} and {r["fy"] for r in rows} == {"2020-21"}
    assert ":::" in rows[2]["url"] and "&" not in rows[2]["url"]
    assert n == 4 + 2 + 3                                   # C2, folder 2, FY dir, A.MonthWise, 2 states; 3 files
    assert len(inner.calls) == 6
    rows2, n2 = hf.plan_fy2021(polite(tmp_path, inner), manifest=tmp_path / "part.csv")
    assert (rows2, n2) == (rows, n) and len(inner.calls) == 6           # listings now cached


def test_folder4_rule():
    gb = 1024**3
    assert hf.folder4_allowed({"bytes_listed": str(int(0.75 * gb))}, free=12 * gb)
    assert not hf.folder4_allowed({"bytes_listed": str(int(1.1 * gb))}, free=12 * gb)     # over 1 GB
    assert not hf.folder4_allowed({"bytes_listed": str(int(0.75 * gb))}, free=int(3.5 * gb))  # < 3 GB left
    assert not hf.folder4_allowed({"bytes_listed": ""}, free=12 * gb)                      # size unknown


# ---------------------------------------------------------------------------- run.py steps


def test_fetch_primary_skips_fy2021_rows_and_applies_folder4_rule(tmp_path, hroot, monkeypatch):
    from pipeline.hmis import run
    src = tmp_path / "sources.csv"
    rows = [zip_row("2014-2015.zip"), zip_row("A__x.xlsx", folder="district_months_2021"),
            {**zip_row("2019-2020.zip", source_id="hmis_c2_4"), "folder": "subdistrict_months_1920",
             "bytes_listed": str(2 * 1024**3)}]
    hf.write_sources(rows, src)
    got = []
    monkeypatch.setattr(hf, "download", lambda row, session, **k: got.append(row["file_name"]) or hroot / "x")
    run.fetch_primary(src)
    assert got == ["2014-2015.zip"]
    dec = json.loads((hroot / "fetch_decisions.json").read_text(encoding="utf-8"))
    assert dec["folder4_fy2019_20"].startswith("skipped") and "cumulative only for 2019-20" in dec["folder4_fy2019_20"]


def test_report_writes_to_given_path(tmp_path, hroot):
    from pipeline.hmis import run
    src, man = tmp_path / "sources.csv", tmp_path / "M.csv"
    row = zip_row("2014-2015.zip")
    hf.write_sources([row, zip_row("2015-2016.zip")], src)
    f = hroot / row["source_id"] / row["file_name"]
    f.parent.mkdir(parents=True)
    f.write_bytes(b"PK\x03\x04data")
    mf.record(f, row["url"], manifest=man)
    hf._write_json(hroot / "discovery.json", {"upload_status": [
        {"name": "A.1. Data Reporting Status (Upto District Level)", "raw_name": "x--L", "anonymous": False}],
        "fy2021_state_level": {"folder1_monthwise_files": 12, "folder2_monthwise_states": 38}})
    text = run.report(out=tmp_path / "r.md", sources=src, manifest=man, status_path=tmp_path / "absent.json",
                      part=tmp_path / "absent.csv")
    assert (tmp_path / "r.md").read_text(encoding="utf-8") == text
    assert mf.sha256_file(f) in text and "1 of 2 listed files downloaded" in text
    assert "not downloaded" in text and "login only" in text and "not final yet" in text
    assert "None seen" in text


# ---------------------------------------------------------------------------- unsafe portal file names

UNSAFE = ["../../evil.zip", r"C:\x.zip", "/abs.zip", "a/b.zip"]


def _files_outside(tmp_path, base):
    base = base.resolve()
    return [p for p in tmp_path.rglob("*") if p.is_file() and p.suffix in (".zip", ".part")
            and base not in p.resolve().parents]


@pytest.mark.parametrize("name", UNSAFE)
def test_portal_names_are_sanitised_and_stay_in_source_dir(tmp_path, hroot, name):
    entry = {"path": f"{B}/x/{name}", "name": name, "isdirectory": False, "fileSize": "0.01 MB"}
    row = hf._file_row(entry, "hmis_src", "2014-15", "all_states_months", "Standard Reports/x")
    fn = row["file_name"]
    assert "/" not in fn and "\\" not in fn and ":" not in fn and not fn.startswith(".") and fn.endswith(".zip")
    inner = FakeSession(Resp(b"PK\x03\x04data"))
    got = hf.download(row, polite(tmp_path, inner), manifest=tmp_path / "M.csv")
    assert got.parent.resolve() == (hroot / "hmis_src").resolve()
    assert _files_outside(tmp_path, hroot / "hmis_src") == []


@pytest.mark.parametrize("name", UNSAFE + ["..", ""])
def test_download_refuses_unsanitised_names_without_request_or_write(tmp_path, hroot, name):
    row = {**zip_row(), "source_id": "hmis_src", "file_name": name}
    inner = FakeSession(Resp(b"PK\x03\x04data"))
    with pytest.raises(hf.UnsafeFileName):
        hf.download(row, polite(tmp_path, inner), manifest=tmp_path / "M.csv")
    assert inner.calls == [] and _files_outside(tmp_path, hroot / "hmis_src") == []
    assert not any((hroot / "hmis_src").rglob("*.zip")) if (hroot / "hmis_src").exists() else True
    with open(hroot / "refused_rows.csv", newline="", encoding="utf-8") as fh:
        assert [r["file_name"] for r in csv.DictReader(fh)] == [name]
    assert manifest_rows(tmp_path / "M.csv") == []


def test_outcomes_get_refuses_escaping_filename(tmp_path, monkeypatch):
    monkeypatch.setattr(of.mf, "record", lambda *a, **k: None)
    inner = FakeSession(Resp(b"PK\x03\x04data"))
    for name in ["../evil.zip", "a/b.zip", r"C:\x.zip"]:
        with pytest.raises(ValueError, match="unsafe"):
            of.get("src", "https://x.org/f.zip", name, session=inner, sleep=lambda s: None, kind="zip",
                   root=tmp_path / "root")
    assert inner.calls == [] and not any(tmp_path.rglob("*.zip"))


def test_fy2021_job_skips_refused_rows(tmp_path, hroot, monkeypatch):
    rows = [zip_row("ok.xlsx", source_id="s"), {**zip_row("bad.xlsx", source_id="s"), "file_name": "../bad.xlsx"}]
    monkeypatch.setattr(hf, "plan_fy2021", lambda session, **k: (rows, 3))
    status = _acquire(tmp_path, FakeSession(Resp(b"PK\x03\x04x")))
    assert status["status"] == "acquired" and status["n_files"] == 1 and "1 refused" in status["reason"]
