"""Cached, manifest-recorded downloads for outcome sources.

Cache layout: RAW_ROOT/<source_id>/<filename> (or <root>/<source_id>/... when get() is given a root),
with <root>/<source_id>/.urls.json
mapping each URL fetched for that source to its cached filename. Two different URLs
that would share a cached filename (same basename, no explicit filename) raise
ValueError rather than silently overwriting or reusing each other's file.
"""
import json
import shutil
import time
from pathlib import Path
from urllib.parse import urlparse

import requests

from pipeline import manifest as mf
from pipeline.paths import RAW, check_source

RAW_ROOT = RAW / "outcomes"
UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
TIMEOUT = (30, 300)
SIDECAR = ".urls.json"


class FetchError(RuntimeError):
    pass


class LocalSourceMissing(FileNotFoundError):
    """A read-only local source file (url "local:<path>") does not exist (and no cached copy either)."""


class CacheIntegrityError(RuntimeError):
    """A cached copy cannot be verified against its MANIFEST row (SHA-256 differs, or no row)."""


def wayback(url: str, year: int) -> str:
    return f"https://web.archive.org/web/{year}id_/{url}"


def _check_magic(body: bytes, kind: str | None, url: str) -> None:
    if kind == "pdf" and not body.startswith(b"%PDF"):
        raise FetchError(f"{url}: expected PDF, got {body[:40]!r}")
    if kind == "zip" and not body.startswith(b"PK\x03\x04"):          # .zip and .xlsx (OOXML is a zip)
        raise FetchError(f"{url}: expected ZIP, got {body[:40]!r}")
    if kind == "html":
        head = body[:4096].lower()
        if b"<html" not in head and b"<!doctype" not in head:
            raise FetchError(f"{url}: expected HTML, got {body[:40]!r}")


def _load_urls(src_dir: Path) -> dict:
    p = src_dir / SIDECAR
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}


def _remember(src_dir: Path, urls: dict, url: str, name: str) -> None:
    if urls.get(url) != name:
        urls[url] = name
        (src_dir / SIDECAR).write_text(json.dumps(urls, indent=1, sort_keys=True), encoding="utf-8")


def _inside(path: Path, directory: Path) -> bool:
    """True when path resolves to a location inside directory (no escape via '..', absolute or drive names)."""
    try:
        Path(path).resolve().relative_to(Path(directory).resolve())
    except ValueError:
        return False
    return Path(path).resolve() != Path(directory).resolve()


def _has_manifest_row(dest: Path, manifest=None) -> bool:
    key = mf._key(dest)
    return any(r["path"] == key for r in (mf.read() if manifest is None else mf.read(manifest)))


def _record(dest: Path, url: str, manifest=None) -> None:
    if manifest is None:
        mf.record(dest, url)
    else:
        mf.record(dest, url, manifest=manifest)


def get(source_id: str, url: str, filename: str | None = None, session=None, sleep=time.sleep,
        kind: str | None = None, root: Path | None = None, manifest: Path | None = None) -> Path:
    """Return the cached file for url, downloading it if absent.

    kind: "pdf", "html" or "zip" (also .xlsx) checks the body's magic bytes; None checks PDF magic
    only when the name ends in .pdf. Cache hits are checked the same way.
    root: cache root (default RAW_ROOT); the file lands at <root>/<source_id>/<filename>.
    manifest: MANIFEST file for the provenance row (default data/MANIFEST.csv).
    """
    src_dir = Path(RAW_ROOT if root is None else root) / source_id
    name = filename or Path(urlparse(url).path).name or "index.html"
    urls = _load_urls(src_dir)
    if filename is None:
        clash = [u for u, f in urls.items() if f == name and u != url]
        if clash:
            raise ValueError(f"{url} and {clash[0]} both map to cached file {name!r} under "
                             f"{source_id!r}; pass an explicit filename")
    effective = kind or ("pdf" if name.lower().endswith(".pdf") else None)
    dest = src_dir / name
    if not _inside(dest, src_dir) or any(c in name for c in ("/", "\\", ":")) or name in (".", ".."):
        raise ValueError(f"unsafe cache file name {name!r} for {url}: must stay inside {src_dir}")

    if dest.exists() and dest.stat().st_size > 0:
        _check_magic(dest.read_bytes(), effective, url)
        if not _has_manifest_row(dest, manifest):
            _record(dest, url, manifest)
        _remember(src_dir, urls, url, name)
        return dest

    dest.parent.mkdir(parents=True, exist_ok=True)
    s = session or requests.Session()
    last = "no attempt"
    for attempt in range(1, 5):
        try:
            r = s.get(url, headers=UA, timeout=TIMEOUT)
            body = r.content
            if r.status_code == 200 and body:
                _check_magic(body, effective, url)
                tmp = dest.with_suffix(dest.suffix + ".part")
                tmp.write_bytes(body)
                tmp.replace(dest)
                _record(dest, url, manifest)
                _remember(src_dir, urls, url, name)
                return dest
            last = f"HTTP {r.status_code}"
        except requests.RequestException as e:
            last = f"{type(e).__name__}: {e}"
        sleep(5 * attempt)
    raise FetchError(f"{url} failed: {last}")


def manifest_sha(path, manifest=None) -> str | None:
    """SHA-256 recorded in the MANIFEST (default data/MANIFEST.csv) for path, or None when it has no row."""
    key = mf._key(path)
    rows = mf.read() if manifest is None else mf.read(manifest)
    return next((r["sha256"] for r in rows if r["path"] == key), None)


def local_copy(source_id: str, src) -> Path:
    """Copy a read-only local source into RAW_ROOT/<source_id>/ and record it in the MANIFEST
    (url "local:<src>"). Re-copied (and re-recorded) whenever the source's SHA-256 differs from
    the copy or from the copy's MANIFEST row.

    When the original is absent (e.g. the external drive is not mounted) the cached copy is used if
    its SHA-256 equals its MANIFEST row; a cached copy that does not match (or has no row) raises
    CacheIntegrityError. No original and no cached copy raises LocalSourceMissing."""
    src = check_source(Path(src))
    dest = Path(RAW_ROOT) / source_id / src.name
    if not src.is_file():
        if not dest.is_file():
            raise LocalSourceMissing(f"{source_id}: local source {src} not found and no cached copy {dest}")
        recorded = manifest_sha(dest)
        if recorded is None:
            raise CacheIntegrityError(f"{source_id}: {src} not found; cached copy {dest} has no MANIFEST row")
        if mf.sha256_file(dest) != recorded:
            raise CacheIntegrityError(f"{source_id}: {src} not found; cached copy {dest} SHA-256 differs from "
                                      "its MANIFEST row")
        return dest
    sha = mf.sha256_file(src)
    if dest.exists() and mf.sha256_file(dest) == sha and manifest_sha(dest) == sha:
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists() or mf.sha256_file(dest) != sha:
        shutil.copy2(src, dest)
    mf.record(dest, f"local:{src}")
    return dest
