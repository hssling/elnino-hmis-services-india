# HMIS parser fixtures (Paper E, Task 2)

**All fixtures are SYNTHETIC (pre-flight ruling F1).** Each one copies the *layout* of a real cached portal
file: the title lines, header rows, row and column spans, item codes, item text and type labels. Every unit
name ("Test State", "District A", "District B", "State P", "State Q") and every number is invented. Nothing was
cut from a downloaded file, and no real value appears here. The files are written by `make_fixtures.py`
(`python -I tests/hmis/fixtures/make_fixtures.py`); its docstring gives the value formula and the special cells.

The three SAS-HTML fixtures are stored as `*.xls.html` (the controlled-data guard treats `.xls` as unscanned binary);
tests read their bytes but pass a member name ending in `.xls` to `parse_member`/`read_table`, which dispatch on it.

The SHA-256 below is the MANIFEST row of the real file whose layout the fixture mirrors (the zip, for members).
The FY2020-21 folder-2 file's row is in `data/manifest_parts/hmis_fy2021.csv` until the Task 9 merge.

| Fixture | Layout mirrored (repo path :: member) | MANIFEST SHA-256 | Rows and columns represented |
|---|---|---|---|
| `e1_synthetic_state_1415.xls.html` | `data/raw/hmis/hmis_c2_3_states_months/2014-2015.zip` :: `2014-2015/Kerala.xls` | `76f2fa0187d7b5ba9a39e0ccac828c0b70367dbddffc4e9386318c6a7a73a0da` | SAS HTML; 3 title lines; header April..March + Total (1 column each); "District" label row; 2 districts x 14 E1 items (all crosswalk codes plus 1.1.1, 10.1.03, 10.1.13.a/b and the two-type stock item 16.3.02, code and text spanning 2 rows); district cell spans its rows; "NA", blank and "0" cells; Grey Box note line |
| `e1_synthetic_allindia_1213.xls.html` | `data/raw/hmis/hmis_c2_3_states_months/2012-2013.zip` :: `2012-2013/All_India.xls` | `88575e9bbbc2af6a8a6845f0ee8879ce3ab712848100e3e22db0107269c38ba3` | As above with the "State" label row (rows are state aggregates), 2 states, status date "19SEP2015" |
| `e2_synthetic_state_1920.xls.html` | `data/raw/hmis/hmis_c2_3_states_months/2019-2020.zip` :: `2019-2020/A & N Islands.xls` | `993fc850c6b600a42e08c6fff2a00cdb9628ac8893f5196893789df033c446e7` | SAS HTML; 4 title lines (incl. the Total = (A+B) or (C+D) note); month row (colspan 5) and split row (Total, Public, Private, Urban, Rural) x 13; "District" label row; 2 districts x 12 E2 items (all crosswalk codes plus DPT3 9.1.5 and the two-type item 16.1.1); codes quoted as `'1.1'` (FY2019-20 style); 9.2.1 = 50 and 9.2.2 = 0 in District A, April |
| `e2_synthetic_state_1718.xlsx` | `data/raw/hmis/hmis_c2_3_states_months/2017-2018.zip` :: `2017-2018/Telangana.xlsx` | `6eac1362185a1ed11b13333ac973175a871a52abfea7e3c7d78fa269b47bd822` | openpyxl workbook, sheet "Sheet1"; title lines as rows 1-4, blank row 5; merged month headers (row 6); split row 7; "District" row 8; district name only on its first row; code and text blank on the second row of a two-type item |
| `e3_synthetic_state_2021_oct.xlsx` | `data/raw/hmis/hmis_c2_2_states_districts_fy2021/Kerala__G-Kerala_Oct.xlsx` | `284e8241a01c2c0d3561beb604fb6bca9b9a80b955c2add4ea8ffa38bf640c6c` | openpyxl workbook, sheet "Data Item Wise Report"; title "Data ItemWise Report for Test State", "... 2020-2021 and Month - Oct-2020", status line; "Districts" row; group row (state first, then 2 districts, merged x 5); split row; 12 E3 items with section labels in column 1 and codes written `'1.1`; numeric cells |
| `e3_synthetic_allindia_2021_apr.xlsx` | `data/raw/hmis/hmis_c2_1_all_india_fy2021/A-Apr.xlsx` | `27ad006d075bebddae03f1158a8d758c0aab407c98d72e5bbd3e46e402cab4cb` | As above, title "... All India Across States", groups "All India", "State P", "State Q", blank "Districts" cell |

## Layouts found in the real files (Step 1 inspection, 2026-10-24)

Read in place with `python -I` (no extraction); only header rows and the first item rows were printed.

- **Folder 3 zips, FY2012-13 to 2019-20** (`hmis_c2_3_states_months`): one workbook per state (38-39 members)
  plus `All_India.xls`. The `.xls` members are **SAS HTML exports**, not BIFF (magic `<html xm`); FY2017-18
  Telangana is a real `.xlsx`. Rows are unit x item (columns: unit, item code, item text, type), columns are
  the 12 months April..March plus an FY Total, so the values are **monthly, not cumulative** (the Total column
  is their sum). State workbooks have a "District" label row and district rows only (no `_State` column);
  `All_India.xls` has a "State" label row and one block per state, which gives the state aggregates.
  - **E1, FY2012-13 to 2016-17**: one column per month. FY2012-13 has the same layout as FY2014-15, so no E0
    parser. Status dates read "19SEP2015" or "29 Jan 2016, 2:00 PM".
  - **E2, FY2017-18 to 2019-20**: five columns per month (Total [(A+B) or (C+D)], Public [A], Private [B],
    Urban [C], Rural [D]). FY2017-18 has the same layout as FY2018-19, so no E2a parser. FY2019-20 writes item
    codes as quoted strings (`'1.1'`), stripped by the parser.
- **E3, FY2020-21**: one month per `.xlsx`. Folder 2 (`hmis_c2_2_states_districts_fy2021`, 456 files): column
  groups = the state, then its districts, each x the five splits. Folder 1 (`hmis_c2_1_all_india_fy2021`,
  12 files): groups = All India, then the states. Codes are written `'1.1`. Status "01 Oct 2024,06:05:11".
- The folder-4 FY2019-20 sub-district zip (Deflate64) is not used.

## Items located

- E1 DPT3: **10.1.04** "Number of Infants (0 to 11 months old) received DPT3 immunisation" (Pentavalent3 is
  10.1.04C); `penta3` E1 = 10.1.04C + 10.1.04.
- E2/E3 full immunisation: only **9.2.4.a / 9.2.4.b** "Children aged between 9 and 11 months fully immunized"
  (male / female), the same 9-11 month band as E1 10.1.13.c. E1 also has 12-23 month items (10.3.1.a-c); they
  are not used.
- E2/E3 also carry DPT3 (9.1.5); the spec's `penta3` E2 row is 9.1.8 only.
