"""HMIS era parsers (Paper E, Task 2). Fixtures are synthetic (ruling F1): real layouts, invented units and numbers."""
import math
import zipfile
from datetime import date
from pathlib import Path

import pytest

from pipeline.hmis import parse as hp

FIX = Path(__file__).resolve().parent / "fixtures"
E1_STATE = FIX / "e1_synthetic_state_1415.xls.html"
E1_ALLINDIA = FIX / "e1_synthetic_allindia_1213.xls.html"
E2_HTML = FIX / "e2_synthetic_state_1920.xls.html"
E2_XLSX = FIX / "e2_synthetic_state_1718.xlsx"
E3_STATE = FIX / "e3_synthetic_state_2021_oct.xlsx"
E3_ALLINDIA = FIX / "e3_synthetic_allindia_2021_apr.xlsx"
FY = {E1_STATE: "2014-15", E1_ALLINDIA: "2012-13", E2_HTML: "2019-20", E2_XLSX: "2017-18",
      E3_STATE: "2020-21", E3_ALLINDIA: "2020-21"}


def rows_of(path):
    return hp.read_table(path.name.removesuffix(".html"), path.read_bytes())


def parsed(path):
    return hp.parse_member(path.name.removesuffix(".html"), path.read_bytes(), FY[path])


def cell(df, unit, code, month, col="district_raw"):
    sel = df[(df[col] == unit) & (df.item_code == code) & (df.month == month) & (df.type == "TOTAL")]
    assert len(sel) == 1, (unit, code, month, len(sel))
    return sel.value.iloc[0]


# ---- era detection ---------------------------------------------------------------------------------------
def test_detect_era_each_fixture():
    assert hp.detect_era(rows_of(E1_STATE)) == "E1"
    assert hp.detect_era(rows_of(E1_ALLINDIA)) == "E1"
    assert hp.detect_era(rows_of(E2_HTML)) == "E2"
    assert hp.detect_era(rows_of(E2_XLSX)) == "E2"
    assert hp.detect_era(rows_of(E3_STATE)) == "E3"
    assert hp.detect_era(rows_of(E3_ALLINDIA)) == "E3"


def test_unknown_layout_raises_layout_error():
    # the data.gov.in spike header (Indicator / S.No. / Parameters / Type, then _State) is not a portal layout
    spike = [["Parameters", "S.No.", "Indicator", "Type", "_Test State", "District A"],
             ["x", "1.1", "Total number of pregnant women Registered for ANC", "TOTAL", "1", "2"]]
    with pytest.raises(hp.LayoutError):
        hp.detect_era(spike)
    swapped = [list(r) for r in rows_of(E1_STATE)]
    i = next(k for k, r in enumerate(swapped) if "April" in r)
    a, b = swapped[i].index("April"), swapped[i].index("May")
    swapped[i][a], swapped[i][b] = "May", "April"
    with pytest.raises(hp.LayoutError):
        hp.detect_era(swapped)
    with pytest.raises(hp.LayoutError):
        hp.detect_era([["Data ItemWise Report for - Test State"], ["no table here"]])


def test_parse_member_checks_fy_against_title():
    with pytest.raises(hp.LayoutError, match="2014-2015"):
        hp.parse_member(E1_STATE.name.removesuffix(".html"), E1_STATE.read_bytes(), "2015-16")


# ---- E1 --------------------------------------------------------------------------------------------------
def test_parse_e1_state_aggregate_value():
    agg = parsed(E1_ALLINDIA)
    assert list(agg.columns) == hp.LONG_COLUMNS
    assert cell(agg, "State P", "1.1", 4, col="state_raw") == 4321
    assert agg.is_state_aggregate.all() and set(agg.state_raw) == {"State P", "State Q"}
    assert set(agg.district_raw) == {""}
    dist = parsed(E1_STATE)
    assert not dist.is_state_aggregate.any()
    assert set(dist.state_raw) == {"Test State"} and set(dist.district_raw) == {"District A", "District B"}


def test_parse_e1_months_types_and_metadata():
    df = parsed(E1_STATE)
    assert sorted(df.month.unique()) == list(range(1, 13))        # 12 month columns; the Total column dropped
    assert set(df.fy) == {"2014-15"} and set(df.source_file) == {E1_STATE.name.removesuffix(".html")}
    assert not df.cumulative.any()                                 # the portal files hold monthly values
    assert set(df.status_date) == {date(2016, 1, 29)}
    assert set(df.type[df.item_code == "16.3.02"]) == {"1. Balance From Previous Month", "5. Total Stock"}
    # formula cell: 100 * (item index + 1) + 10 * unit index + month (District B, item 1.1, March)
    assert cell(df, "District B", "1.1", 3) == 100 + 10 + 3


def test_na_is_nan_never_zero():
    df = parsed(E1_STATE)
    assert math.isnan(cell(df, "District B", "12.7", 6))         # "NA"
    assert math.isnan(cell(df, "District B", "12.7", 7))         # blank
    assert cell(df, "District A", "10.1.04", 5) == 0               # a reported zero stays zero


def test_numeric_cells_with_commas_dashes_blanks():
    assert hp.to_number("1,234") == 1234 and hp.to_number(" 12 ") == 12 and hp.to_number("12.0") == 12
    assert all(math.isnan(hp.to_number(x)) for x in ("-", "", "NA", "  "))
    with pytest.raises(ValueError):
        hp.to_number("abc")
    assert hp.to_number(7) == 7 and math.isnan(hp.to_number(None))


def test_unparseable_fy_total_cell_counts_as_bad():
    rows = [list(r) for r in rows_of(E1_STATE)]
    one = next(r for r in rows if len(r) > 16 and r[1] == "1.1")
    one[16] = "abc"                                                 # the FY Total column of E1 (4 + 12)
    df = hp.parse_e1(rows, "2014-15", None, "bad_total.xls", fy_total=True)
    assert df.attrs["bad_cells"] == 1 and math.isnan(df.loc[df.district_raw == one[0]].query("item_code == '1.1'").fy_total.iloc[0])
    assert hp.parse_e1(rows, "2014-15", None, "bad_total.xls").attrs["bad_cells"] == 0


def test_more_than_one_percent_bad_cells_raises_naming_file():
    rows = [list(r) for r in rows_of(E1_STATE)]
    items = [r for r in rows if len(r) > 3 and r[1] in {"1.1", "2.2"}]
    for r in items:                                                 # 4 rows x 12 months of ~360 rows x 12
        r[4:16] = ["abc"] * 12
    with pytest.raises(hp.LayoutError, match="bad_file.xls"):
        hp.parse_e1(rows, "2014-15", None, "bad_file.xls")
    rows = [list(r) for r in rows_of(E1_STATE)]
    one = next(r for r in rows if len(r) > 3 and r[1] == "1.1")
    one[4] = "abc"                                                  # one bad cell is under 1%: NaN, not an error
    df = hp.parse_e1(rows, "2014-15", None, "one_bad.xls")
    assert math.isnan(cell(df, one[0], "1.1", 4))


# ---- E2 --------------------------------------------------------------------------------------------------
@pytest.mark.parametrize("path", [E2_HTML, E2_XLSX], ids=["html_1920", "xlsx_1718"])
def test_e2_keeps_total_split_only(path):
    df = parsed(path)
    assert df.value.notna().all()
    assert (df.value < 20000).all()                                 # Public/Private/Urban/Rural are 20000+
    assert sorted(df.month.unique()) == list(range(1, 13))
    assert set(df.district_raw) == {"District A", "District B"}
    assert "1.1" in set(df.item_code) and not any("'" in c for c in df.item_code)   # 2019-20 quotes codes
    assert len(df) == 2 * 13 * 12                                   # 2 districts x 13 item rows x 12 months


def test_e2_values_and_status_date():
    df = parsed(E2_HTML)
    assert cell(df, "District A", "9.2.1", 4) == 50 and cell(df, "District A", "9.2.2", 4) == 0
    assert set(df.status_date) == {date(2020, 11, 6)}
    assert cell(parsed(E2_XLSX), "District B", "10.11", 12) == 100 * 9 + 10 + 12


# ---- E3 --------------------------------------------------------------------------------------------------
def test_e3_keeps_district_aggregate_only():
    df = parsed(E3_STATE)
    assert set(df.month) == {10} and not df.cumulative.any()
    assert (df.value < 20000).all() and df.value.notna().all()
    agg = df[df.is_state_aggregate]
    assert set(agg.state_raw) == {"Test State"} and set(agg.district_raw) == {""}
    assert set(df[~df.is_state_aggregate].district_raw) == {"District A", "District B"}
    assert cell(df, "", "1.1", 10) == 777
    assert len(df) == 3 * 13                                        # 3 column groups x 13 item rows
    assert set(df.status_date) == {date(2024, 10, 1)}


def test_e3_all_india_file_gives_state_aggregates():
    df = parsed(E3_ALLINDIA)
    assert df.is_state_aggregate.all() and set(df.month) == {4}
    assert set(df.state_raw) == {"All India", "State P", "State Q"}


def test_e3_month_must_agree_with_title():
    with pytest.raises(hp.LayoutError, match="month"):
        hp.parse_e3(rows_of(E3_STATE), "2020-21", 4, E3_STATE.name)
    assert set(hp.parse_e3(rows_of(E3_STATE), "2020-21", None, "x.xlsx").month) == {10}


# ---- helpers ---------------------------------------------------------------------------------------------
def test_parse_status_date_formats():
    assert hp.parse_status_date([["Status As On: 19SEP2015"]]) == date(2015, 9, 19)
    assert hp.parse_status_date([["x"], ["Status As On: 29 Jan 2016, 2:00 PM"]]) == date(2016, 1, 29)
    assert hp.parse_status_date([["Status As On: 01 Oct 2024,06:01:05"]]) == date(2024, 10, 1)
    assert hp.parse_status_date([["no date"]]) is None


def test_month_from_name():
    assert hp.month_from_name("upto_Mar") == 3
    assert hp.month_from_name("A-Wayanad_Apr.xlsx") == 4
    assert hp.month_from_name("Kerala__G-Kerala_Oct.xlsx") == 10
    assert hp.month_from_name("2012-2013/A.MonthWise/A - April.xls") == 4
    assert hp.month_from_name("Maharashtra__L-Maharashtra_Mar.xlsx") == 3
    with pytest.raises(ValueError):
        hp.month_from_name("2014-2015/Kerala.xls")


def test_era_for_fy():
    assert [hp.era_for_fy(f) for f in ("2012-13", "2016-17", "2017-18", "2019-20", "2020-21")] == \
        ["E1", "E1", "E2", "E2", "E3"]
    with pytest.raises(ValueError):
        hp.era_for_fy("2011-12")


# ---- archives and tables ---------------------------------------------------------------------------------
def _zip(path, members):
    with zipfile.ZipFile(path, "w") as z:
        for name, data in members.items():
            z.writestr(name, data)
    return path


@pytest.mark.parametrize("bad", ["../x.csv", "C:/x.csv", "/abs.csv", "a/../../x.csv", "a\\..\\x.csv",
                                 "inner.zip", "deep/inner.7z"])
def test_zip_member_path_traversal_rejected(tmp_path, bad):
    z = _zip(tmp_path / "a.zip", {"ok.csv": b"a,b\n", bad: b"x"})
    with pytest.raises(hp.UnsafeArchiveError):
        list(hp.iter_members(z))


def test_zip_oversize_member_rejected_and_nothing_yielded_first(tmp_path):
    z = _zip(tmp_path / "a.zip", {"ok.csv": b"a\n", "big.csv": b"x" * 11})
    got = []
    with pytest.raises(hp.UnsafeArchiveError):
        for name, data in hp.iter_members(z, max_bytes=10):
            got.append(name)
    assert got == []                                                # every member is checked before any is read


def test_zip_members_read_in_place(tmp_path):
    z = _zip(tmp_path / "a.zip", {"d/": b"", "d/one.csv": b"a\n", "d/two.csv": b"b\n"})
    assert list(hp.iter_members(z)) == [("d/one.csv", b"a\n"), ("d/two.csv", b"b\n")]
    assert list(hp.iter_members(z, only={"d/two.csv"})) == [("d/two.csv", b"b\n")]
    assert sorted(p.name for p in tmp_path.iterdir()) == ["a.zip"]  # nothing extracted


def test_read_table_csv_encodings():
    assert hp.read_table("x.csv", "\ufeffa,b\n1,\u20ac\n".encode("utf-8")) == [["a", "b"], ["1", "\u20ac"]]
    assert hp.read_table("x.csv", "a,b\n1,\u20ac\n".encode("cp1252")) == [["a", "b"], ["1", "\u20ac"]]


def test_read_table_html_spans_and_title_lines():
    rows = rows_of(E2_HTML)
    assert rows[0] == ["Data ItemWise Report for - Test State"]
    assert rows[1] == ["Provisional Figures for - 2019-2020"]
    hdr = next(r for r in rows if len(r) > 4 and r[4] == "April")
    assert hdr[4:9] == ["April"] * 5 and len(hdr) == 4 + 13 * 5     # colspan expanded
    first = next(r for r in rows if len(r) > 1 and r[1] == "'1.1'")
    last_b = [r for r in rows if len(r) > 1 and r[0] == "District B"]
    assert first[0] == "District A" and len(last_b) == 13           # rowspan filled down


def test_read_table_rejects_binary_xls_and_unknown_types():
    with pytest.raises(hp.LayoutError, match="BIFF"):
        hp.read_table("x.xls", b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\0" * 64)
    with pytest.raises(hp.LayoutError):
        hp.read_table("x.pdf", b"%PDF-1.4")


# ---- one real cached member (skipped without the git-ignored cache; header and shape only) ---------------
REAL_E1 = Path(__file__).resolve().parents[2] / "data/raw/hmis/hmis_c2_3_states_months/2014-2015.zip"
REAL_E3 = Path(__file__).resolve().parents[2] / "data/raw/hmis/hmis_c2_1_all_india_fy2021/A-Apr.xlsx"


def test_real_cached_e1_member_layout():
    if not REAL_E1.exists():
        pytest.skip("HMIS cache absent (data/raw is git-ignored)")
    (name, data), = hp.iter_members(REAL_E1, only={"2014-2015/A & N Islands.xls"})
    rows = hp.read_table(name, data)
    assert hp.detect_era(rows) == "E1"
    assert rows[0][0].startswith("Data ItemWise Report for")
    assert {len(r) for r in rows if len(r) > 1} == {17}            # 4 id columns + 12 months + Total


def test_real_cached_e3_file_layout():
    if not REAL_E3.exists():
        pytest.skip("HMIS cache absent (data/raw is git-ignored)")
    rows = hp.read_table(REAL_E3.name, REAL_E3.read_bytes())
    assert hp.detect_era(rows) == "E3"
    assert hp.month_from_name(REAL_E3.name) == 4
