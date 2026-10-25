"""The tracked state-month panel, data/derived/hmis/hmis_state_month.csv (Paper E, Task 4). Reads the file only."""
import pandas as pd

from pipeline.hmis import panel as hpn
from pipeline.hmis.crosswalk import INDICATORS
from pipeline.outcomes import states


def _panel():
    return pd.read_csv(hpn.PANEL_PATH, dtype={"fy": str, "unit_id": str})


def test_panel_shape():
    p = _panel()
    assert list(p.columns) == hpn.panel_columns()
    assert sorted(p.unit_id.unique()) == sorted(states.UNITS) and p.unit_id.nunique() == 34
    want = set(range(12 * 2012 + 3, 12 * 2020 + 3))                      # April 2012 .. March 2020
    if (p.fy == "2020-21").any():
        want |= set(range(12 * 2020 + 3, 12 * 2021 + 3))                  # FY2020-21 acquired
    assert len(want) in (96, 108)
    for u, g in p.groupby("unit_id"):
        assert set(g.ym) == want, u
    assert not p.duplicated(["unit_id", "ym"]).any()
    assert len(p) == 34 * len(want)


def test_panel_has_no_district_columns():
    p = _panel()
    assert not any("district_raw" in c for c in p.columns)
    assert not any(c.startswith("district") for c in p.columns)


def test_final_values_are_a_subset_of_raw():
    p = _panel()
    for i in INDICATORS:
        assert (p[i].isna() | (p[i] == p[f"{i}_raw"])).all(), i
        assert (p[f"comp_{i}"].dropna().between(0, 1)).all(), i
