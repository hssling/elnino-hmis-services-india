"""HMIS era parsers (Paper E, Task 2; spec §3.2 as amended by the Task 2 inspection).

Raw downloads are untrusted data. Zips are read in place (`iter_members`, no extraction); workbooks are parsed as
data only (HTML with the standard-library parser, .xlsx with openpyxl read-only); nothing in them is executed.

Layouts found in the cached portal files (Step 1 inspection, 2026-10-24; tests/hmis/fixtures/FIXTURES.md):

- The folder-3 zips ("All States and Districts Across Months") hold one workbook per state plus `All_India.xls`.
  The `.xls` members are SAS HTML exports ("Data ItemWise Report"), not BIFF; FY2017-18 Telangana is `.xlsx`.
  Title lines: "Data ItemWise Report for - <unit>", "Provisional Figures for - <yyyy-yyyy>", "Status As On: ...".
  Rows are unit x item (4 id columns: unit, item code, item text, type); columns are the 12 months April..March
  plus an FY Total. The values are MONTHLY (the Total column is their sum), so `cumulative` is False.
  - E1 (FY2012-13 to 2016-17): one column per month.
  - E2 (FY2017-18 to 2019-20): five columns per month: Total [(A+B) or (C+D)], Public, Private, Urban, Rural.
    Only Total is kept. FY2019-20 writes codes as 'quoted' strings; quotes are stripped.
  - The unit-label row reads "District" in a state workbook (rows are districts) and "State" in `All_India.xls`
    (rows are states; these rows are the state aggregates, `is_state_aggregate` True, `district_raw` "").
- E3 (FY2020-21): one month per .xlsx (folder 2: one per state and month; folder 1: All India across states).
  Column groups (unit x the five splits); the first group is the state itself (state files) or "All India"
  (folder-1 files). Only the Total split is kept. Item codes are written '1.1 (leading quote).
- FY2012-13 has the E1 layout and FY2017-18 the E2 layout, so no E0 or E2a parser is needed.

Hand-off (Task 3 consumes this): `parse_member` returns a DataFrame with LONG_COLUMNS
  fy (str "2014-15"), month (int 1-12, calendar), state_raw (str, the file's unit name or the state row/column
  name), district_raw (str; "" on aggregate rows), is_state_aggregate (bool), item_code (str, quotes stripped),
  item_text (str, whitespace collapsed), type (str, e.g. "TOTAL"), value (float; NaN for "NA", "-", blank and
  the <=1% unparseable cells, never 0), cumulative (bool; False for every portal layout), status_date
  (datetime.date or None, from "Status As On"), source_file (str, the name passed in, "<zip>::<member>").
Task 3 additions (LONG_COLUMNS consumers unaffected):
- `parse_member(..., fy_total=True)` appends one column after LONG_COLUMNS, `fy_total` (float): the file's FY Total
  cell (Total split of the Total group in E2) for that unit x item x type, repeated on its 12 month rows; NaN for
  E3, whose files hold one month and no FY total. Used by `difference.month_total_check` (spec §12.4).
- Every parsed frame carries `attrs["n_cells"]` (value cells read) and `attrs["bad_cells"]` (cells that were not
  numbers and became NaN; at most 1% or the file raises LayoutError), for the per-member log.
Task 4 addition: `parse_national(name, data, fy)` reads a folder-1 "All India Across State(s)" month file (E3
column groups from FY2017-18, or `parse_across_states` for the FY2012-13..2016-17 one-column-per-state layout) into
LONG_COLUMNS with one aggregate row per unit ("All India", the states, the M/O rows).
"""
import codecs
import csv
import io
import math
import re
import warnings
import zipfile
from datetime import date
from html.parser import HTMLParser
from pathlib import Path
from typing import Iterator

import pandas as pd

LONG_COLUMNS = ["fy", "month", "state_raw", "district_raw", "is_state_aggregate", "item_code", "item_text",
                "type", "value", "cumulative", "status_date", "source_file"]
# Raised from the brief's 300 MB: the FY2017-18 and FY2018-19 Uttar Pradesh members are 312 MB uncompressed.
MAX_MEMBER_BYTES = 400_000_000
ARCHIVE_EXTENSIONS = (".zip", ".7z", ".rar", ".gz", ".tgz", ".tar", ".bz2", ".xz", ".cab", ".jar")
MONTH_NAMES = ["April", "May", "June", "July", "August", "September", "October", "November", "December",
               "January", "February", "March"]
FY_MONTHS = [4, 5, 6, 7, 8, 9, 10, 11, 12, 1, 2, 3]
SPLITS = ("total", "public", "private", "urban", "rural")
BAD_CELL_SHARE = 0.01
ERA_FIRST_FY = (("E1", 2012), ("E2", 2017), ("E3", 2020))       # by FY start year; E3 is FY2020-21 only
_MON = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10,
        "nov": 11, "dec": 12}
_MONTH_TOKEN = re.compile(r"(?<![A-Za-z])(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|"
                          r"aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?![A-Za-z])",
                          re.IGNORECASE)
_CODE = re.compile(r"^\d+(\.[0-9A-Za-z()]+)*$")
_NUMBER = re.compile(r"^[+-]?(\d+(\.\d*)?|\.\d+)$")
_STATUS = re.compile(r"status\s+as\s+on\s*:?\s*(\d{1,2})\s*([A-Za-z]{3})[A-Za-z]*\.?\s*,?\s*(\d{4})", re.I)
_TITLE = re.compile(r"^data\s*item\s*wise\s+report\s+for\s*-?\s*(.+?)\s*$", re.I)
_FY_TITLE = re.compile(r"provisional\s+figures\s+for\s*-?\s*(\d{4})\s*-\s*(\d{2,4})", re.I)
_MONTH_TITLE = re.compile(r"and\s+month\s*-\s*([A-Za-z]+)", re.I)


class LayoutError(ValueError):
    """A file whose layout is not one of the known eras, or whose values are not numbers."""


class UnsafeArchiveError(ValueError):
    """A zip member with an absolute or escaping path, a nested archive, or an oversize member."""


# ---- archives ----------------------------------------------------------------------------------------------
def _check_member(info: zipfile.ZipInfo, max_bytes: int) -> None:
    name = info.filename
    parts = re.split(r"[\\/]", name)
    if name.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", name) or ".." in parts:
        raise UnsafeArchiveError(f"unsafe member path {name!r}")
    if name.lower().endswith(ARCHIVE_EXTENSIONS):
        raise UnsafeArchiveError(f"nested archive {name!r}")
    if info.file_size > max_bytes:
        raise UnsafeArchiveError(f"member {name!r} is {info.file_size:,} bytes (> {max_bytes:,})")


def iter_members(zip_path: Path, max_bytes: int = MAX_MEMBER_BYTES, only=None) -> Iterator[tuple[str, bytes]]:
    """Yield (member name, bytes) for each file member, read in place (never extracted). Every member name and
    size is checked before the first one is read; a member that inflates past max_bytes is refused too.
    `only`: optional set of member names to read (all are still checked)."""
    with zipfile.ZipFile(zip_path) as z:
        infos = z.infolist()
        for info in infos:
            _check_member(info, max_bytes)
        for info in infos:
            if info.is_dir() or (only is not None and info.filename not in only):
                continue
            with z.open(info) as fh:
                data = fh.read(max_bytes + 1)
            if len(data) > max_bytes:
                raise UnsafeArchiveError(f"member {info.filename!r} inflates past {max_bytes:,} bytes")
            yield info.filename, data


# ---- tables ------------------------------------------------------------------------------------------------
def _clean(s) -> str:
    return " ".join(str(s).split())


class _TableHTML(HTMLParser):
    """Collects text blocks outside tables (one row each) and table rows as (text, colspan, rowspan) cells."""
    _BLOCK = {"h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "br", "li", "title"}
    _SKIP = {"style", "script", "title"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.items, self._text, self._rows, self._row, self._cell = [], [], None, None, None
        self._depth = self._skip = 0
        self._span = (1, 1)

    def _flush_text(self):
        t = _clean("".join(self._text))
        if t:
            self.items.append(("text", t))
        self._text = []

    def handle_starttag(self, tag, attrs):
        if tag in self._SKIP:
            self._skip += 1
        if tag == "table":
            self._depth += 1
            if self._depth == 1:
                self._flush_text()
                self._rows = []
        elif self._depth == 1 and tag == "tr":
            self._row = []
        elif self._depth == 1 and tag in ("td", "th") and self._row is not None:
            a = dict(attrs)
            self._cell = []
            self._span = (_span(a.get("colspan")), _span(a.get("rowspan")))
        elif tag == "br" and self._cell is not None:
            self._cell.append(" ")
        elif not self._depth and tag in self._BLOCK:
            self._flush_text()

    def handle_endtag(self, tag):
        if tag in self._SKIP:
            self._skip = max(0, self._skip - 1)
        if self._depth == 1 and tag in ("td", "th") and self._cell is not None:
            self._row.append((_clean("".join(self._cell)),) + self._span)
            self._cell = None
        elif self._depth == 1 and tag == "tr" and self._row is not None:
            self._rows.append(self._row)
            self._row = None
        elif tag == "table" and self._depth:
            self._depth -= 1
            if self._depth == 0:
                self.items.append(("table", self._rows))
                self._rows = None
        elif not self._depth and tag in self._BLOCK:
            self._flush_text()

    def handle_data(self, data):
        if self._skip:
            return
        if self._cell is not None:
            self._cell.append(data)
        elif not self._depth:
            self._text.append(data)


def _span(v) -> int:
    try:
        return max(1, min(int(v), 100_000))
    except (TypeError, ValueError):
        return 1


def _expand(rows) -> list[list[str]]:
    """Row/column spans -> a rectangular grid; a spanned cell's text is repeated in every cell it covers."""
    grid, pending = [], {}                                          # column -> (text, rows still to fill)
    for row in rows:
        out, col, i = [], 0, 0
        while i < len(row) or col in pending:
            if col in pending:
                text, left = pending[col]
                out.append(text)
                if left <= 1:
                    del pending[col]
                else:
                    pending[col] = (text, left - 1)
                col += 1
                continue
            text, cs, rs = row[i]
            i += 1
            for _ in range(cs):
                out.append(text)
                if rs > 1:
                    pending[col] = (text, rs - 1)
                col += 1
        grid.append(out)
    return grid


def _html_charset(data: bytes) -> str:
    m = re.search(rb"charset\s*=\s*['\"]?([A-Za-z0-9_-]+)", data[:4096])
    if m:
        try:
            return codecs.lookup(m.group(1).decode("ascii")).name
        except LookupError:
            pass
    return "cp1252"


def _read_html(data: bytes) -> list[list[str]]:
    parser = _TableHTML()
    dec = codecs.getincrementaldecoder(_html_charset(data))(errors="replace")
    step = 1 << 22
    for k in range(0, len(data), step):
        parser.feed(dec.decode(data[k:k + step]))
    parser.feed(dec.decode(b"", final=True))
    parser.close()
    parser._flush_text()
    rows = []
    for kind, v in parser.items:
        rows.extend([[v]] if kind == "text" else _expand(v))
    return rows


def _xlsx_cell(v) -> str:
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def _read_xlsx(data: bytes) -> list[list[str]]:
    import openpyxl
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")                             # openpyxl's "no default style" notice
        wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    try:
        ws = wb.worksheets[0]
        ws.reset_dimensions()                                       # the portal files declare a 1x1 dimension
        return [[_xlsx_cell(c) for c in row] for row in ws.iter_rows(values_only=True)]
    finally:
        wb.close()


def read_table(name: str, data: bytes) -> list[list[str]]:
    """Rows of cell strings. CSV: utf-8-sig, else cp1252. XLSX: openpyxl read-only, first sheet. XLS: the
    portal's SAS HTML export (text lines outside the table become one-cell rows; spans are filled)."""
    ext = Path(name.split("::")[-1]).suffix.lower()
    if ext == ".csv":
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError:
            text = data.decode("cp1252")
        return [list(r) for r in csv.reader(io.StringIO(text))]
    if ext == ".xlsx":
        return _read_xlsx(data)
    if ext in (".xls", ".htm", ".html"):
        if data[:512].lstrip(b"\xef\xbb\xbf \t\r\n").startswith(b"<"):
            return _read_html(data)
        if data[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1":
            raise LayoutError(f"{name}: BIFF .xls workbook; the portal files are HTML exports, BIFF is not handled")
        raise LayoutError(f"{name}: .xls that is neither HTML nor BIFF")
    raise LayoutError(f"{name}: unsupported file type {ext!r}")


# ---- cells and metadata ------------------------------------------------------------------------------------
def to_number(cell) -> float:
    """'NA', '', '-' and whitespace -> NaN; thousands commas stripped; other text -> ValueError."""
    if cell is None:
        return math.nan
    if isinstance(cell, (int, float)) and not isinstance(cell, bool):
        return float(cell)
    s = str(cell).strip()
    if s in ("", "NA", "-"):
        return math.nan
    s = s.replace(",", "")
    if not _NUMBER.match(s):
        raise ValueError(f"not a number: {cell!r}")
    return float(s)


def parse_status_date(rows) -> date | None:
    """The date in the 'Status As On' line ('19SEP2015', '29 Jan 2016, 2:00 PM', '01 Oct 2024,06:01:05')."""
    for row in rows[:20]:
        for c in row:
            m = _STATUS.search(str(c))
            if m and m.group(2).lower() in _MON:
                return date(int(m.group(3)), _MON[m.group(2).lower()], int(m.group(1)))
    return None


def month_from_name(name: str) -> int:
    """Calendar month named in a file name: the last month token ('upto_Mar' -> 3, 'A-Wayanad_Apr.xlsx' -> 4)."""
    hits = _MONTH_TOKEN.findall(str(name))
    if not hits:
        raise ValueError(f"no month in {name!r}")
    return _MON[hits[-1][:3].lower()]


def era_for_fy(fy: str) -> str:
    """'2012-13'..'2016-17' -> E1, '2017-18'..'2019-20' -> E2, '2020-21' -> E3."""
    m = re.fullmatch(r"(\d{4})-(\d{2})", str(fy))
    if not m or (int(m.group(1)) + 1) % 100 != int(m.group(2)):
        raise ValueError(f"bad FY {fy!r}")
    y = int(m.group(1))
    if y < ERA_FIRST_FY[0][1] or y > ERA_FIRST_FY[-1][1]:
        raise ValueError(f"FY {fy} is outside 2012-13..2020-21")
    return [era for era, first in ERA_FIRST_FY if y >= first][-1]


def _code(s) -> str:
    return _clean(s).strip("'\"‘’ ")


def _is_item(row) -> bool:
    return len(row) > 4 and bool(_CODE.match(_code(row[1]))) and _clean(row[2]) != ""


def _item_rows(rows, first):
    """(row, code, text, type) for each item row from `first` on. A row with a type but no code and no text
    continues the item above (the .xlsx files leave merged code/text cells of multi-type items blank)."""
    code = text = None
    for row in rows[first:]:
        if _is_item(row):
            code, text = _code(row[1]), _clean(row[2])
        elif not (code and len(row) > 4 and not _clean(row[1]) and not _clean(row[2]) and _clean(row[3])):
            continue
        yield row, code, text, _clean(row[3])


def _first_item(rows) -> int:
    for i, r in enumerate(rows):
        if _is_item(r):
            return i
    raise LayoutError("no item rows (item code in column 2)")


def _trim(cells) -> list[str]:
    cells = [_clean(c) for c in cells]
    while cells and cells[-1] == "":
        cells.pop()
    return cells


def _ffill(cells) -> list[str]:
    out, last = [], ""
    for c in cells:
        last = c if c else last
        out.append(last)
    return out


def _collapse(cells) -> list[str]:
    out = []
    for c in cells:
        if not out or out[-1] != c:
            out.append(c)
    return out


def _is_split_row(row) -> int:
    """Number of 5-column groups if row[4:] repeats Total, Public, Private, Urban, Rural; else 0."""
    cells = _trim(row[4:]) if len(row) > 4 else []
    if not cells or len(cells) % 5:
        return 0
    words = [c.split(" ")[0].lower() if c else "" for c in cells]
    ok = all(w == SPLITS[k % 5] for k, w in enumerate(words))
    return len(cells) // 5 if ok else 0


def _layout(rows):
    """(era, header facts) for a table, or LayoutError."""
    first = _first_item(rows)
    head = rows[:first]
    month_i = split_i = None
    for i, r in enumerate(head):
        cells = _trim(r[4:]) if len(r) > 4 else []
        if month_i is None and cells and any(c in MONTH_NAMES for c in cells):
            if _collapse(_ffill(cells)) != MONTH_NAMES + ["Total"]:
                raise LayoutError(f"month header is not April..March, Total: {_collapse(_ffill(cells))}")
            month_i = i
        if split_i is None and _is_split_row(r):
            split_i = i
    label = [i for i, r in enumerate(head) if r and _clean(r[0]) in ("District", "State")]
    if month_i is not None:
        width = len(_trim(head[month_i][4:]))
        if split_i is None and width == 13:
            era, per = "E1", 1
        elif split_i == month_i + 1 and _is_split_row(head[split_i]) == 13 and width in (13 * 5 - 4, 13 * 5):
            era, per = "E2", 5
        else:
            raise LayoutError("month header without a matching split row / column count")
        lab = [i for i in label if i > (split_i if split_i is not None else month_i)]
        if not lab:
            raise LayoutError("no 'District' or 'State' label row under the month header")
        return era, {"first": first, "per": per, "unit_label": _clean(head[lab[0]][0])}
    if split_i is not None and split_i >= 1:
        groups = _is_split_row(head[split_i])
        names_row = head[split_i - 1]
        names = [_clean(names_row[4 + 5 * g]) if len(names_row) > 4 + 5 * g else "" for g in range(groups)]
        if not all(names):
            raise LayoutError("E3 column group without a unit name")
        return "E3", {"first": first, "names": names}
    raise LayoutError("unknown header layout (no month header and no split header)")


def detect_era(rows) -> str:
    """'E1', 'E2' or 'E3' from the header rows; LayoutError for anything else."""
    return _layout(rows)[0]


def _title(rows):
    """(unit, (start year, end year) or None, title month or None) from the title lines."""
    unit = fy4 = mon = None
    for r in rows[:12]:
        for c in r[:1]:
            c = _clean(c)
            if unit is None and (m := _TITLE.match(c)):
                unit = m.group(1)
            if fy4 is None and (m := _FY_TITLE.search(c)):
                fy4 = (int(m.group(1)), int(m.group(2)))
            if mon is None and (m := _MONTH_TITLE.search(c)):
                mon = _MON.get(m.group(1)[:3].lower())
    return unit, fy4, mon


def _check_fy(fy, fy4, source_file):
    if fy4 is None:
        return
    y1, y2 = fy4
    want = int(str(fy)[:4])
    if y1 != want or y2 % 100 != (want + 1) % 100:
        raise LayoutError(f"{source_file}: title FY {y1}-{y2} does not match fy {fy}")


def _frame(records, conv=None, fy_total=False) -> pd.DataFrame:
    df = pd.DataFrame.from_records(records, columns=LONG_COLUMNS + (["fy_total"] if fy_total else []))
    df["month"] = df["month"].astype(int)
    df["value"] = df["value"].astype(float)
    df["is_state_aggregate"] = df["is_state_aggregate"].astype(bool)
    df["cumulative"] = df["cumulative"].astype(bool)
    if fy_total:
        df["fy_total"] = df["fy_total"].astype(float)
    df.attrs.update(n_cells=conv.n if conv else 0, bad_cells=conv.bad if conv else 0)
    return df


class _Values:
    """Counts unparseable value cells; more than 1% of a file's kept cells -> LayoutError naming the file."""

    def __init__(self, source_file):
        self.source_file, self.n, self.bad, self.example = source_file, 0, 0, None

    def __call__(self, cell) -> float:
        self.n += 1
        try:
            return to_number(cell)
        except ValueError:
            self.bad += 1
            self.example = self.example or cell
            return math.nan

    def check(self):
        if self.n and self.bad / self.n > BAD_CELL_SHARE:
            raise LayoutError(f"{self.source_file}: {self.bad} of {self.n} value cells are not numbers "
                              f"(e.g. {self.example!r})")


def _parse_across_months(rows, fy, source_file, want_era, fy_total=False):
    era, h = _layout(rows)
    if era != want_era:
        raise LayoutError(f"{source_file}: layout {era}, expected {want_era}")
    unit, fy4, _ = _title(rows)
    _check_fy(fy, fy4, source_file)
    status = parse_status_date(rows)
    aggregate = h["unit_label"] == "State"
    if not aggregate and not unit:
        raise LayoutError(f"{source_file}: no 'Data ItemWise Report for' title line")
    cols = [4 + h["per"] * k for k in range(12)]                     # Total split of each month
    tcol = 4 + h["per"] * 12                                         # the FY Total (its Total split in E2)
    conv, recs, current = _Values(source_file), [], ""
    tconv = conv                                                     # FY-total cells count as value cells too
    for row, code, text, typ in _item_rows(rows, h["first"]):
        current = _clean(row[0]) or current
        if not current:
            raise LayoutError(f"{source_file}: item row before any unit name")
        state, district = (current, "") if aggregate else (unit, current)
        extra = (tconv(row[tcol] if tcol < len(row) else ""),) if fy_total else ()
        for col, month in zip(cols, FY_MONTHS):
            v = conv(row[col] if col < len(row) else "")
            recs.append((fy, month, state, district, aggregate, code, text, typ, v, False, status, source_file)
                        + extra)
    conv.check()
    return _frame(recs, conv, fy_total)


def parse_e1(rows, fy, month, source_file, fy_total=False) -> pd.DataFrame:
    """E1: months across (one column each), units x items down. `month` is unused (months are columns)."""
    return _parse_across_months(rows, fy, source_file, "E1", fy_total)


def parse_e2(rows, fy, month, source_file, fy_total=False) -> pd.DataFrame:
    """E2: months across x 5 splits; only the Total split is kept. `month` is unused (months are columns)."""
    return _parse_across_months(rows, fy, source_file, "E2", fy_total)


def parse_e3(rows, fy, month, source_file, fy_total=False) -> pd.DataFrame:
    """E3: one month per file; column groups = the state (or All India) then its districts (or states), each
    x 5 splits; only the Total split is kept. `month` (from the file name) must agree with the title month."""
    era, h = _layout(rows)
    if era != "E3":
        raise LayoutError(f"{source_file}: layout {era}, expected E3")
    unit, fy4, title_month = _title(rows)
    _check_fy(fy, fy4, source_file)
    if month is not None and title_month is not None and month != title_month:
        raise LayoutError(f"{source_file}: month {month} from the name, {title_month} in the title")
    month = month if month is not None else title_month
    if month is None:
        raise LayoutError(f"{source_file}: no month in the name or the title")
    if not unit:
        raise LayoutError(f"{source_file}: no 'Data ItemWise Report for' title line")
    names = h["names"]
    all_india = unit.lower().startswith("all india")
    if not all_india and names[0].lower() != unit.lower():
        raise LayoutError(f"{source_file}: first column group {names[0]!r} is not the title unit {unit!r}")
    units = []
    for g, name in enumerate(names):
        if all_india:
            units.append((name, "", True))
        else:
            units.append((unit, "", True) if g == 0 else (unit, name, False))
    status = parse_status_date(rows)
    conv, recs = _Values(source_file), []
    for row, code, text, typ in _item_rows(rows, h["first"]):
        for g, (state, district, agg) in enumerate(units):
            col = 4 + 5 * g
            v = conv(row[col] if col < len(row) else "")
            recs.append((fy, month, state, district, agg, code, text, typ, v, False, status, source_file)
                        + ((math.nan,) if fy_total else ()))
    conv.check()
    return _frame(recs, conv, fy_total)


PARSERS = {"E1": parse_e1, "E2": parse_e2, "E3": parse_e3}


def parse_across_states(rows, fy, month, source_file) -> pd.DataFrame:
    """Folder-1 'All India Across State' month file of FY2012-13..2016-17: one month per file, one column per
    unit ("All India", then the states and the M/O rows) under a 'State' label row, no splits. Every unit is an
    aggregate row (`is_state_aggregate` True, `district_raw` "")."""
    first = _first_item(rows)
    head = rows[:first]
    lab = [i for i, r in enumerate(head) if len(r) > 4 and _trim(r[4:]) and set(_trim(r[4:])) == {"State"}]
    if not lab or lab[0] + 1 >= len(head):
        raise LayoutError(f"{source_file}: no 'State' label row followed by the unit names")
    names = _trim(head[lab[0] + 1][4:])
    if not names or not all(names):
        raise LayoutError(f"{source_file}: blank unit name in the across-states header")
    unit, fy4, title_month = _title(rows)
    _check_fy(fy, fy4, source_file)
    if month is not None and title_month is not None and month != title_month:
        raise LayoutError(f"{source_file}: month {month} from the name, {title_month} in the title")
    month = month if month is not None else title_month
    if month is None:
        raise LayoutError(f"{source_file}: no month in the name or the title")
    status = parse_status_date(rows)
    conv, recs = _Values(source_file), []
    for row, code, text, typ in _item_rows(rows, first):
        for g, name in enumerate(names):
            col = 4 + g
            v = conv(row[col] if col < len(row) else "")
            recs.append((fy, month, name, "", True, code, text, typ, v, False, status, source_file))
    conv.check()
    return _frame(recs, conv)


def parse_national(name: str, data: bytes, fy: str) -> pd.DataFrame:
    """A folder-1 national month file ("Data ItemWise Report for All India Across State(s)"), Task 4 (ruling F39):
    the E3 column-group layout (FY2017-18 onward; parse_e3) or the FY2012-13..2016-17 layout without splits
    (parse_across_states). LONG_COLUMNS; one aggregate row per unit ("All India", the states, M/O rows).
    BIFF workbooks (two FY2017-18 months) raise LayoutError, as in read_table."""
    rows = read_table(name, data)
    unit = _title(rows)[0]
    if not unit or not unit.lower().startswith("all india"):
        raise LayoutError(f"{name}: not an All India across-states file (title unit {unit!r})")
    try:
        month = month_from_name(name)
    except ValueError:
        month = None
    try:
        era = detect_era(rows)
    except LayoutError:
        era = None
    if era == "E3":
        return parse_e3(rows, fy, month, name)
    if era is not None:
        raise LayoutError(f"{name}: national file with a months-across ({era}) layout")
    return parse_across_states(rows, fy, month, name)


def parse_member(name: str, data: bytes, fy: str, fy_total: bool = False) -> pd.DataFrame:
    """Parse one workbook (a zip member or a file). The layout era must be the era of `fy` (spec §3.2).
    `fy_total=True` appends the `fy_total` column (see the module docstring)."""
    rows = read_table(name, data)
    era = detect_era(rows)
    if era != era_for_fy(fy):
        raise LayoutError(f"{name}: layout {era} in FY {fy} (expected {era_for_fy(fy)})")
    month = None
    if era == "E3":
        try:
            month = month_from_name(name)
        except ValueError:
            month = None
    return PARSERS[era](rows, fy, month, name, fy_total)
