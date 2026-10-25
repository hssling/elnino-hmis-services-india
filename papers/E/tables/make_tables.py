"""Paper E Tables 1 and 2 as Markdown (Tables 3-4 are written in the manuscript from keys, Task 13).

    python papers/E/tables/make_tables.py                    (from <repo>; needs papers/E/results.json)
    python papers/E/tables/make_tables.py --allow-pending    (drafts from results.pending.json; never committed)

Outputs (out_dir, default papers/E/tables/):
  data/table2.csv      written first and from tracked inputs only (data/derived/hmis/hmis_model.csv), so it is
                       committed independently of results.json: one row per indicator (indicator-level aggregates of
                       state-months; no unit or district value) with columns indicator, label, n_state_months (valid
                       primary-window state-months), count_q1, count_median, count_q3 (reported count per state-month)
                       and source.
  table1_crosswalk.md  the indicator crosswalk: label, role, HMIS item numbers per format era (from
                       pipeline/reference/hmis_item_crosswalk.csv), harmonised definition, and the national
                       March-to-April 2017 ratio (key E.break2017.<I>.ratio, display).
  table2_panel.md      the panel description: units, primary-window months and state-months, status dates
                       (E.panel.*, E.status_date.range); per outcome the valid state-months and the share of
                       district-months valid (E.panel.<I>.n_valid, E.comp.<I>.share_district_months_valid; displays),
                       the state-month count median (IQR) from data/table2.csv (descriptive; source named in the
                       footnote), and the coverage ratio per 1,000 expected births, which reads "not available (SRS not
                       retrieved)" (ruling F23). The median completeness (E.comp.<I>.median) is not shown: it is 100.0%
                       for every outcome and carries no information.
Every key display is copied verbatim; a pending key is an error. The two Markdown tables read papers/E/results.json
and stop if it does not exist; --allow-pending (explicit opt-in) reads the git-ignored results.pending.json with a
warning, and tables built from it must not be committed. n_state_months is checked against E.panel.<I>.n_valid.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import pandas as pd

TABLES = Path(__file__).resolve().parent
PAPER = TABLES.parent
ROOT = TABLES.parents[2]
RESULTS = PAPER / "results.json"
RESULTS_PENDING = PAPER / "results.pending.json"
CROSSWALK = ROOT / "pipeline" / "reference" / "hmis_item_crosswalk.csv"
MODEL_CSV = ROOT / "data" / "derived" / "hmis" / "hmis_model.csv"
EN = "\u2013"
SOURCE = "data/derived/hmis/hmis_model.csv"

OUTCOMES = ["anc_reg", "penta3", "inst_del", "opd", "diarr_u5", "mcv1", "fic"]
LABEL = {"diarr_u5": "Diarrhoea in children under 5 years", "anc_reg": "ANC registration",
         "penta3": "Third dose of a DPT-containing vaccine", "mcv1": "First dose of a measles-containing vaccine",
         "fic": "Full immunisation", "inst_del": "Institutional deliveries", "opd": "Outpatient attendance"}
ROLE = {"anc_reg": "Primary service (H7, H9)", "penta3": "Primary service (H7, H9)",
        "inst_del": "Primary service (H7, H9)", "opd": "Primary service (H7, H9)",
        "diarr_u5": "Primary disease (H8)", "mcv1": "Secondary (no verdict)", "fic": "Secondary (no verdict)"}
DEFINITION = {
    "anc_reg": "Pregnant women registered for antenatal care; the same item in every format.",
    "penta3": "Infants given the third dose of pentavalent or DPT vaccine; before April 2017 the two items are "
              "added because pentavalent was introduced state by state (a child receives one or the other).",
    "inst_del": "Deliveries in public and private institutions, including caesarean sections; the two pre-2017 "
                "items are added to match the single 2017 item.",
    "opd": "Outpatient attendance, all systems; from April 2017 allopathic and AYUSH attendance are added to approximate "
           "the earlier total.",
    "diarr_u5": "Cases of diarrhoea in children under 5 years; the wording changed in April 2017 (with dehydration "
                "before, without after), absorbed by the format-change term.",
    "mcv1": "Infants given a first dose of a measles-containing vaccine; from April 2017 the measles-rubella and "
            "measles first-dose items are added (a child receives one or the other).",
    "fic": "Children aged 9 to 11 months fully immunised; from April 2017 the male and female items are added.",
}
COVERAGE = {"anc_reg", "penta3", "inst_del", "mcv1", "fic"}     # ratios that would use expected births


PENDING_WARNING = ("WARNING: --allow-pending reads the git-ignored {name}; tables built from it are drafts and "
                   "must not be committed (rebuild from the final results.json)")


def load_results(path: Path = RESULTS, allow_pending: bool = False, pending: Path = RESULTS_PENDING) -> dict:
    """papers/E/results.json (an error if it does not exist), or, only with allow_pending, results.pending.json."""
    if allow_pending:
        path = Path(pending)
        if not path.exists():
            raise FileNotFoundError(f"--allow-pending: {path} not found")
        print(PENDING_WARNING.format(name=path.name))
    else:
        path = Path(path)
        if not path.exists():
            raise FileNotFoundError(f"{path} not found: run models/E/run_all.R when every step has finished, or pass "
                                    "--allow-pending to draft from results.pending.json (never committed)")
    return json.loads(path.read_text(encoding="utf-8"))


def disp(res: dict, key: str) -> str:
    if key not in res:
        raise KeyError(f"results.json has no key {key}")
    d = str(res[key]["display"])
    if d.startswith("pending"):
        raise ValueError(f"{key} is pending ({d})")
    return d


def items_text(codes: str) -> str:
    return " + ".join(str(codes).split("|"))


def fmt_int(x: float) -> str:
    return f"{math.floor(float(x) + 0.5):,}"      # half up (round() would round 27,788.5 down, 29,247.5 up)


def table1(res: dict, crosswalk: Path = CROSSWALK) -> str:
    cw = pd.read_csv(crosswalk, dtype=str)
    if set(cw["indicator"]) != set(OUTCOMES):
        raise ValueError("crosswalk indicators differ from the seven outcomes")
    lines = ["# Table 1. Indicator crosswalk and harmonised definitions", "",
             "| Indicator | Role | HMIS items, FY2012-13 to 2016-17 | HMIS items, FY2017-18 to 2020-21 | "
             "Harmonised definition | National April/March 2017 ratio |",
             "|---|---|---|---|---|---|"]
    for o in OUTCOMES:
        g = cw[cw["indicator"] == o].set_index("era")
        e1, e2, e3 = (items_text(g.loc[e, "item_codes"]) for e in ("E1", "E2", "E3"))
        if e2 != e3:
            raise ValueError(f"{o}: FY2020-21 items {e3} differ from FY2017-18 to 2019-20 items {e2}")
        lines.append(f"| {LABEL[o]} | {ROLE[o]} | {e1} | {e2} | {DEFINITION[o]} | "
                     f"{disp(res, f'E.break2017.{o}.ratio')} |")
    lines += ["",
              "Items are the HMIS data-item numbers of the monthly state reports; \"+\" means the items are added. "
              "Each item was matched by its text in every financial year, and the full crosswalk, with the item "
              "texts and the file each was verified in, is in the supplement. The April/March 2017 ratio is the "
              "national ratio of the pre-gate state values for the units reporting both months, around the change of "
              "the HMIS reporting format in April 2017; it is descriptive, and every model contains a format-change "
              "term.", ""]
    return "\n".join(lines)


def table2_data(model_csv: Path = MODEL_CSV) -> pd.DataFrame:
    """Indicator-level description of the valid primary-window state-months of hmis_model.csv (tracked input)."""
    m = pd.read_csv(model_csv, usecols=["in_primary"] + OUTCOMES)
    m = m[m["in_primary"] == 1]
    rows = []
    for o in OUTCOMES:
        v = m[o].dropna()
        q1, med, q3 = v.quantile([0.25, 0.5, 0.75])
        rows.append({"indicator": o, "label": LABEL[o], "n_state_months": len(v), "count_q1": q1,
                     "count_median": med, "count_q3": q3, "source": SOURCE})
    return pd.DataFrame(rows)


def table2(res: dict, data: pd.DataFrame) -> str:
    d = data.set_index("indicator")
    lines = ["# Table 2. Panel description, primary window (April 2012 to February 2020)", "",
             f"Units: {disp(res, 'E.panel.n_units')}. Months: {disp(res, 'E.panel.n_months')}. "
             f"State-months: {disp(res, 'E.panel.n_state_months')}. HMIS status dates (all values provisional): "
             f"{disp(res, 'E.status_date.range')}.", "",
             "| Indicator | State-months with a valid value | District-months valid | "
             "Reported count per state-month, median (IQR)<sup>a</sup> | Coverage per 1,000 expected births |",
             "|---|---|---|---|---|"]
    for o in OUTCOMES:
        n = res[f"E.panel.{o}.n_valid"]["value"]
        if n is None or int(n) != int(d.loc[o, "n_state_months"]):
            raise ValueError(f"E.panel.{o}.n_valid ({n}) differs from hmis_model.csv ({d.loc[o, 'n_state_months']})")
        cov = "not available (SRS not retrieved)" if o in COVERAGE else "not applicable"
        cnt = f"{fmt_int(d.loc[o, 'count_median'])} ({fmt_int(d.loc[o, 'count_q1'])}{EN}{fmt_int(d.loc[o, 'count_q3'])})"
        lines.append(f"| {LABEL[o]} | {disp(res, f'E.panel.{o}.n_valid')} | "
                     f"{disp(res, f'E.comp.{o}.share_district_months_valid')} | {cnt} | {cov} |")
    lines += ["",
              "A state-month enters the analysis only if at least 90% of the districts listed for the state and year "
              "reported the item (completeness = valid / listed districts); otherwise it is missing, never zero and "
              "never scaled up. Values failing a data-quality gate are masked. District-months valid: valid "
              "district-months as a share of listed district-months. Coverage ratios would divide by expected births "
              "from the Sample Registration System, which could not be retrieved, so they are not reported; the "
              "analysis does not depend on them.",
              "",
              f"<sup>a</sup> Descriptive: computed by `papers/E/tables/make_tables.py` from `{SOURCE}` over the valid "
              "primary-window state-months; the unrounded values are in `papers/E/tables/data/table2.csv`. Not a "
              "results.json key.", ""]
    return "\n".join(lines)


def main(out_dir: Path = TABLES, results: Path = RESULTS, crosswalk: Path = CROSSWALK,
         model_csv: Path = MODEL_CSV, allow_pending: bool = False, pending: Path = RESULTS_PENDING) -> list[Path]:
    """Write data/table2.csv (tracked inputs only), then the two Markdown tables (which need results.json)."""
    out_dir = Path(out_dir)
    (out_dir / "data").mkdir(parents=True, exist_ok=True)
    data = table2_data(model_csv)
    csv = out_dir / "data" / "table2.csv"
    data.to_csv(csv, index=False, lineterminator="\n", float_format="%.15g")
    print(f"wrote {csv}")
    paths = [csv]
    res = load_results(results, allow_pending, pending)
    for name, text in (("table1_crosswalk.md", table1(res, crosswalk)), ("table2_panel.md", table2(res, data))):
        p = out_dir / name
        p.write_text(text, encoding="utf-8", newline="\n")
        paths.append(p)
        print(f"wrote {p}")
    return paths


def cli(argv: list[str] | None = None) -> list[Path]:
    import argparse
    ap = argparse.ArgumentParser(description="Write Paper E Tables 1 and 2.")
    ap.add_argument("--out-dir", type=Path, default=TABLES)
    ap.add_argument("--allow-pending", action="store_true",
                    help="read the git-ignored results.pending.json (drafts only; never commit the tables)")
    a = ap.parse_args(argv)
    return main(out_dir=a.out_dir, allow_pending=a.allow_pending)


if __name__ == "__main__":
    cli()
