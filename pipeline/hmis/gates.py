"""HMIS state-month gates and reviewed dispositions (Paper E, Task 4; spec §3.5, §3.6, §10.2, §12; rulings F32, F33,
F37, F39).

Every gate takes long frames and returns (failing cells as FAIL_COLUMNS, pipeline.validate.GateResult). The panel
frame a gate reads (`panel_raw`) is long: unit_id, fy, month (calendar), indicator, value (the official state
aggregate, pooled to the 34 units, before any gate). GateResult.passed is True only when no cell fails; a failing
cell is not an error, it gets a disposition.

Gates:
- `gate_district_sum(panel_raw, dsum, comp)`: on unit-months whose districts are 100% valid (comp == 1), the state
  value against the unscaled district sum, `outcomes.gates.agree(a, b, tol_rel=0.02, tol_abs=5.0)` (2% when both
  are >= 100, else +-5).
- `gate_negative_share(dm)`: per indicator, the share of negative district values among reported district values;
  above 1%, every unit-month holding a negative district value fails.
- `gate_negative_state(panel_raw)`: a negative state value.
- `gate_plausibility(panel_raw)`: a value > 3x or < 0.33x the unit's median for the same calendar month within its
  era over the primary FYs (E1 FY2012-13..2016-17, E2 FY2017-18..2019-20; FY2020-21 compared with E2), tested only
  where that median is >= 20. Highs: default mask. Lows: default keep (default_keep_low, ruling F41), except lows
  covering every available month (>= 10) of a unit-FY: default mask (default_mask_fy_level, ruling F42).
- `gate_national(panel_raw, national)`: the sum of the 34 units against the folder-1 All India value net of the M/O
  rows (ruling F39; run.NATIONAL_COLUMNS), within 1% (`agree(tol_rel=0.01)`). A failing indicator-month fails for
  all units (unit_id "ALL"). A month without a national value reads "not available" and masks nothing.
- `gate_partial_component(state)`: per indicator x FY, the share of non-missing unit-months with a missing component
  that was non-zero elsewhere in the FY (rulings F32, F37); above 5% those unit-months fail. penta3 and mcv1 have
  substitute components and are exempt (their shares are still reported by `partial_shares`).

Dispositions (spec §10.2): `apply_dispositions(panel, failures, reviewed)` masks every failing cell (default, logged
with its rule) unless a reviewed row (same indicator, unit_id, fy, month, check) says `keep`. A national failure
(unit_id "ALL") masks that indicator-month for every unit. The returned log has REVIEWED_COLUMNS and is written to
`pipeline/reference/hmis_reviewed.csv` by `write_reviewed`, which keeps the author's rows (rule starting
"reviewed") and regenerates the default rows on every build.

Hand-off tables:
- `pipeline/reference/hmis_reviewed.csv` (tracked, state-level; REVIEWED_COLUMNS): indicator, unit_id (or "ALL" for
  national_total), fy, month (calendar), check (CHECKS), disposition (mask / keep), rule (RULES text for a default
  row; "reviewed: ..." for an author row), reason, evidence (the numbers behind the failure).
- `data/derived/hmis/gate_summary.csv` (tracked; SUMMARY_COLUMNS; built by panel.build_panel via `gate_summary`):
  one row per indicator x scope ("primary" = FY2012-13..2019-20, "fy2020_21"): primary5, state_months (units x
  months), reported (non-missing state values before the gates), masked_<check> (unit-months masked by each
  check), kept_by_review, masked (any check), masked_share (masked / (reported)), comp_lt_090 (reported, not
  masked, completeness < 0.90), entering_models (the final `<ind>` values), dropped (primary scope only: masked_share
  > 0.20), district_sum_tested, national_months_tested, national_months_failed, national_months_not_available,
  national_not_available (FYs with months lacking a national value, "fy (n of 12)"), negative_district_share,
  partial_share_max (largest indicator x FY share), partial_exempt, note.
- `data/derived/hmis/break_ratio_2017.csv` (tracked; `break_ratio_2017`): indicator, mar2017, apr2017 (sums of the
  units' pre-gate state values over the units reporting both months), ratio, gt25pct (|ratio - 1| > 0.25),
  n_units. Descriptive only (spec §3.4).

`dropped_indicators(panel, 0.20)`, `check_halt(dropped, panel)` and `unusable_fys(panel)` read the wide panel
(panel.panel_columns). PanelHalt is raised when two or more PRIMARY5 indicators are dropped or more than one FY of
April 2012 - March 2020 is unusable (no unit has a final value for any PRIMARY5 indicator); exactly one unusable FY
is returned so the caller masks and reports it (spec §10.2, §10.6).
"""
from pathlib import Path

import numpy as np
import pandas as pd

from pipeline.hmis.crosswalk import INDICATORS, PRIMARY5
from pipeline.outcomes.gates import agree
from pipeline.validate import GateResult

REF = Path(__file__).resolve().parents[1] / "reference"
REVIEWED_PATH = REF / "hmis_reviewed.csv"
PRIMARY_FYS = tuple(f"{y}-{(y + 1) % 100:02d}" for y in range(2012, 2020))
FY2021 = "2020-21"
LONG_KEYS = ["unit_id", "fy", "month", "indicator"]
FAIL_COLUMNS = ["indicator", "unit_id", "fy", "month", "check", "rule", "evidence", "default"]
REVIEWED_COLUMNS = ["indicator", "unit_id", "fy", "month", "check", "disposition", "rule", "reason", "evidence"]
CHECKS = ("negative_share", "negative_state", "district_sum", "plausibility", "national_total", "partial_component",
          "fy_unusable")
LOW_TOKEN = "keep_low:plausibility"                     # flag token of a default-kept plausibility low (F41)
DISPOSITIONS = ("mask", "keep")
PARTIAL_EXEMPT = ("penta3", "mcv1")                    # substitute components (ruling F37)
TOL_DISTRICT_REL, TOL_DISTRICT_ABS, TOL_NATIONAL = 0.02, 5.0, 0.01
MAX_NEGATIVE_SHARE, MAX_PARTIAL_SHARE, MAX_MASKED = 0.01, 0.05, 0.20
PLAUS_HI, PLAUS_LO, PLAUS_MIN_MEDIAN = 3.0, 0.33, 20.0
FY_LEVEL_MIN_MONTHS = 10                                # ruling F42
DEFAULT_REASON = "default disposition, no author review (spec §10.2)"
DEFAULT_KEEP_REASON = ("default keep, no author review (ruling F41): a low is kept in the primary series and "
                       "masked only in the <ind>_masklow sensitivity")
RULES = {
    "negative_share": "default mask (spec §3.3/§10.2): the indicator's share of negative district values is above "
                      "1%; state-months holding a negative district value",
    "negative_state": "default mask (spec §10.2): negative state-aggregate value",
    "district_sum": "default mask (spec §3.5/§10.1/§12.2): state row vs the unscaled sum of districts on a month "
                    "with 100% valid districts differs by > 2% (both >= 100) or > 5 (either < 100)",
    "plausibility": "default mask (spec §3.6/§10.2, ruling F41): > 3x the unit's median for the same calendar month "
                    "within its era (E1 FY2012-13..2016-17, E2 FY2017-18..2019-20; FY2020-21 vs E2; median >= 20)",
    "plausibility_low": "default_keep_low (ruling F41): < 0.33x the unit's median for the same calendar month within "
                        "its era (FY2020-21 vs E2; median >= 20); kept, masked only in the <ind>_masklow sensitivity",
    "plausibility_fy_level": "default_mask_fy_level (ruling F42): every available month (>= 10) of the unit-FY is "
                             "< 0.33x the within-era calendar-month median, a definition or reporting artefact, not a "
                             "disruption; masked",
    "national_total": "default mask (spec §3.5/§10.2, ruling F39): sum of the 34 units vs the folder-1 All India "
                      "value net of M/O rows differs by > 1%; the indicator-month is masked for all units",
    "partial_component": "default mask (spec §12.6, rulings F32/F37): indicator x FY share of state-months with a "
                         "missing component that is non-zero elsewhere in the FY is above 5% (penta3, mcv1 exempt)",
    "fy_unusable": "default mask (spec §10.2/§10.6): the only unusable FY of the primary window (no unit has a final "
                   "value for any PRIMARY5 indicator); every value column of the FY is masked for all units",
}
SUMMARY_COLUMNS = (["indicator", "scope", "primary5", "state_months", "reported"]
                   + [f"masked_{c}" for c in CHECKS]
                   + ["kept_by_review", "masked", "masked_share", "comp_lt_090", "entering_models", "dropped",
                      "kept_low", "district_sum_tested", "national_months_tested", "national_months_failed",
                      "national_months_not_evaluable", "national_months_not_available", "national_not_available", "negative_district_share",
                      "partial_share_max", "partial_exempt", "note"])


class PanelHalt(RuntimeError):
    """Two or more PRIMARY5 indicators dropped, or more than one FY of the primary window unusable (spec §10.2)."""


def _seq(x) -> bool:
    return isinstance(x, (list, tuple, pd.Series))


def _fail(df: pd.DataFrame, check: str, evidence, rule=None, default="mask") -> pd.DataFrame:
    """Failing cells as FAIL_COLUMNS. `evidence` (and `rule` / `default` when sequences) are aligned with df's rows
    BEFORE the output is sorted, so each row keeps its own evidence (task-4 review I-1)."""
    if df.empty:
        return pd.DataFrame(columns=FAIL_COLUMNS)
    out = df[["indicator", "unit_id", "fy", "month"]].copy()
    out["check"] = check
    out["rule"] = list(rule) if _seq(rule) else (rule or RULES[check])
    out["evidence"] = list(evidence) if _seq(evidence) else evidence
    out["default"] = list(default) if _seq(default) else default
    out["month"] = out["month"].astype(int)
    out = out.sort_values(["indicator", "unit_id", "fy", "month"], kind="stable")
    return out[FAIL_COLUMNS].reset_index(drop=True)


def _result(name: str, fails: pd.DataFrame, detail: str) -> GateResult:
    return GateResult(name, fails.empty, f"{len(fails)} failing cells; {detail}")


def _num(x) -> str:
    return "NA" if pd.isna(x) else f"{x:.0f}"


# ---- gates ----------------------------------------------------------------------------------------------------
def gate_district_sum(panel_raw, dsum, comp, tol_rel=TOL_DISTRICT_REL, tol_abs=TOL_DISTRICT_ABS):
    m = (panel_raw[LONG_KEYS + ["value"]].merge(dsum[LONG_KEYS + ["dsum"]], on=LONG_KEYS)
         .merge(comp[LONG_KEYS + ["comp"]], on=LONG_KEYS))
    t = m[(m.comp >= 1 - 1e-12) & m.value.notna() & m.dsum.notna()]
    bad = t[pd.Series([not agree(a, b, tol_rel, tol_abs) for a, b in zip(t.value, t.dsum)], index=t.index,
                      dtype=bool)]
    ev = [f"state={_num(a)} district_sum={_num(b)} comp=1" for a, b in zip(bad.value, bad.dsum)]
    fails = _fail(bad, "district_sum", ev)
    return fails, _result("hmis_district_sum", fails, f"tested {len(t)} unit-months with 100% valid districts "
                                                      f"(tolerance {tol_rel:.0%} / +-{tol_abs:g})")


def negative_shares(dm) -> pd.DataFrame:
    """Per indicator: n (reported district values), n_negative, share."""
    rep = dm[dm.value_raw.notna()]
    g = rep.groupby("indicator")
    out = pd.DataFrame({"n": g.size(), "n_negative": g["negative"].sum()}).reindex(list(INDICATORS)).fillna(0)
    out["share"] = out.n_negative / out.n.where(out.n > 0)
    return out.reset_index()


def gate_negative_share(dm, max_share=MAX_NEGATIVE_SHARE):
    """dm: district-month rows with unit_id, fy, month, indicator, value_raw, negative."""
    sh = negative_shares(dm)
    over = sh[sh.share > max_share]
    neg = dm[dm.negative.astype(bool) & dm.indicator.isin(over.indicator)]
    cells = neg.groupby(LONG_KEYS).size().rename("n_neg").reset_index()
    share = dict(zip(sh.indicator, sh.share))
    ev = [f"indicator negative share {share[i]:.4f} > {max_share:g}; {k} negative district value(s)"
          for i, k in zip(cells.indicator, cells.n_neg)]
    fails = _fail(cells, "negative_share", ev)
    txt = ", ".join(f"{r.indicator} {r.share:.4f}" for r in sh.itertuples() if r.n > 0)
    return fails, _result("hmis_negative_share", fails, f"negative district shares: {txt or 'none reported'}")


def gate_negative_state(panel_raw):
    bad = panel_raw[panel_raw.value < 0]
    fails = _fail(bad, "negative_state", [f"state={_num(v)}" for v in bad.value])
    return fails, _result("hmis_negative_state", fails, f"tested {int(panel_raw.value.notna().sum())} state values")


def reference_era(fy: str) -> str:
    """The plausibility reference era of an FY (ruling F41): E1 for FY2012-13..2016-17, E2 from FY2017-18 (FY2020-21
    is compared with E2)."""
    return "E1" if int(str(fy)[:4]) < 2017 else "E2"


def gate_plausibility(panel_raw, ref_fys=PRIMARY_FYS, hi=PLAUS_HI, lo=PLAUS_LO, min_median=PLAUS_MIN_MEDIAN):
    """Ruling F41: the unit's median for the same calendar month over the primary FYs of the same era. A value above
    hi x median fails with default mask; below lo x median fails with default keep (rule default_keep_low), except
    when the lows cover every available month (>= FY_LEVEL_MIN_MONTHS) of the unit-FY: default mask, rule
    default_mask_fy_level (ruling F42)."""
    keys = ["unit_id", "indicator", "month", "_era"]
    r = panel_raw.assign(_era=panel_raw.fy.map(reference_era))
    ref = r[r.fy.isin(ref_fys)].groupby(keys)["value"].median().rename("median").reset_index()
    m = r.merge(ref, on=keys, how="left")
    t = m[m.value.notna() & (m["median"] >= min_median)]
    high, low = t.value > hi * t["median"], t.value < lo * t["median"]
    # F42: a low covering every available month (>= FY_LEVEL_MIN_MONTHS) of a unit-FY is masked, not kept
    fkeys = ["unit_id", "indicator", "fy"]
    n_avail = m[m.value.notna()].groupby(fkeys).size().rename("_n_avail")
    n_low = t[low].groupby(fkeys).size().rename("_n_low")
    lvl = pd.concat([n_avail, n_low], axis=1).fillna(0)
    lvl = lvl[(lvl._n_avail >= FY_LEVEL_MIN_MONTHS) & (lvl._n_low == lvl._n_avail)].index
    bad = t[high | low]
    is_low = (bad.value < lo * bad["median"]).tolist()
    in_lvl = pd.MultiIndex.from_frame(bad[fkeys]).isin(lvl).tolist() if len(bad) else []
    kind = ["fy_level" if lw and lv else ("low" if lw else "high") for lw, lv in zip(is_low, in_lvl)]
    ev = [f"value={_num(v)} median={_num(md)} ratio={v / md:.2f} reference={e}"
          for v, md, e in zip(bad.value, bad["median"], bad._era)]
    rule_of = {"high": RULES["plausibility"], "low": RULES["plausibility_low"],
               "fy_level": RULES["plausibility_fy_level"]}
    fails = _fail(bad, "plausibility", ev, rule=[rule_of[k] for k in kind],
                  default=["keep" if k == "low" else "mask" for k in kind])
    n_lvl, n_keep = kind.count("fy_level"), kind.count("low")
    return fails, _result("hmis_plausibility", fails, f"{int(high.sum())} high masked, {n_lvl} FY-level low masked "
                                                      f"(default_mask_fy_level), {n_keep} low kept "
                                                      f"(default_keep_low); tested {len(t)} values (calendar-month "
                                                      f"median within era >= {min_median:g}; band {lo:g}x-{hi:g}x)")


def national_comparison(panel_raw, national, tol=TOL_NATIONAL, n_units=34) -> pd.DataFrame:
    """fy, month, indicator, units_sum, national, rel_diff, status: pass / fail / "not available" (no national
    value) / "not evaluable" (fewer than all 34 units have a value; masks nothing, task-4 review M-1)."""
    keys = ["fy", "month", "indicator"]
    g = panel_raw.groupby(keys)["value"]
    s = pd.DataFrame({"units_sum": g.sum(min_count=1), "_n": g.count()}).reset_index()
    nat = national[keys + ["national"]] if national is not None and len(national) else \
        pd.DataFrame(columns=keys + ["national"])
    nat = nat.astype({"month": int})
    m = s.merge(nat, on=keys, how="left")
    m["national"] = m["national"].astype(float)
    m["rel_diff"] = (m.units_sum - m.national) / m.national.where(m.national != 0)

    def status(a, b, n):
        if pd.isna(b):
            return "not available"
        if n < n_units:
            return "not evaluable"
        return "pass" if agree(a, b, tol, 5.0) else "fail"
    m["status"] = [status(a, b, n) for a, b, n in zip(m.units_sum, m.national, m._n)]
    return m[keys + ["units_sum", "national", "rel_diff", "status"]]


def gate_national(panel_raw, national, tol=TOL_NATIONAL):
    c = national_comparison(panel_raw, national, tol)
    bad = c[c.status == "fail"].assign(unit_id="ALL")
    ev = [f"units_sum={_num(a)} national={_num(b)} rel_diff={d:+.4f}" for a, b, d in
          zip(bad.units_sum, bad.national, bad.rel_diff)]
    fails = _fail(bad, "national_total", ev)
    ne = int((c.status == "not evaluable").sum())
    na = c[c.status == "not available"]
    na_txt = "; ".join(f"{fy} {ind} ({n} of 12)" for (fy, ind), n in
                       na.groupby(["fy", "indicator"]).size().items()) or "none"
    return fails, _result("hmis_national_total", fails,
                          f"tested {int(c.status.isin(['pass', 'fail']).sum())} indicator-months within "
                          f"{tol:.0%} with all 34 units present; not evaluable (a unit missing; masks "
                          f"nothing): {ne}; not available (masks nothing): {na_txt}")


def partial_shares(state) -> pd.DataFrame:
    """indicator, fy, n (non-missing unit-months), n_partial, share, exempt."""
    s = state[state.value.notna()]
    g = s.groupby(["indicator", "fy"])
    out = pd.DataFrame({"n": g.size(), "n_partial": g["partial_component"].sum()}).reset_index()
    out["share"] = out.n_partial / out.n
    out["exempt"] = out.indicator.isin(PARTIAL_EXEMPT)
    return out


def gate_partial_component(state, max_share=MAX_PARTIAL_SHARE, exempt=PARTIAL_EXEMPT):
    """state: unit-level rows with unit_id, fy, month, indicator, value, partial_component."""
    sh = partial_shares(state)
    over = sh[(sh.share > max_share) & ~sh.indicator.isin(exempt)]
    s = state[state.value.notna() & state.partial_component.astype(bool)]
    bad = s.merge(over[["indicator", "fy", "share"]], on=["indicator", "fy"])
    ev = [f"indicator x FY partial share {x:.3f} > {max_share:g}" for x in bad.share]
    fails = _fail(bad, "partial_component", ev)
    hi = sh.sort_values("share", ascending=False).head(3)
    txt = ", ".join(f"{r.indicator} {r.fy} {r.share:.3f}{' (exempt)' if r.exempt else ''}" for r in hi.itertuples())
    return fails, _result("hmis_partial_component", fails, f"largest shares: {txt or 'none'}")


# ---- reviewed dispositions ----------------------------------------------------------------------------------------
def empty_reviewed() -> pd.DataFrame:
    return pd.DataFrame(columns=REVIEWED_COLUMNS)


def _norm(r: pd.DataFrame) -> pd.DataFrame:
    r = r.copy()
    for c in REVIEWED_COLUMNS:
        if c not in r:
            r[c] = ""
    r = r[REVIEWED_COLUMNS].fillna("").astype(str).apply(lambda s: s.str.strip())
    r["month"] = r.month.str.replace(r"\.0$", "", regex=True)
    return r


def read_reviewed(path=REVIEWED_PATH) -> pd.DataFrame:
    """hmis_reviewed.csv, validated: known indicator, check and disposition; month 1-12; rule, reason and evidence
    present; a keep row must be an author row (rule starting 'reviewed'). An absent file reads as empty."""
    path = Path(path)
    if not path.exists():
        return empty_reviewed()
    raw = pd.read_csv(path, dtype=str, keep_default_na=False)
    if list(raw.columns) != REVIEWED_COLUMNS:
        raise ValueError(f"{path.name}: columns {list(raw.columns)} != {REVIEWED_COLUMNS}")
    r = _norm(raw)
    for i, x in r.iterrows():
        where = f"{path.name} row {i + 2}"
        if x.indicator not in INDICATORS:
            raise ValueError(f"{where}: indicator {x.indicator!r}")
        if x.check not in CHECKS:
            raise ValueError(f"{where}: check {x.check!r} not in {list(CHECKS)}")
        if x.disposition not in DISPOSITIONS:
            raise ValueError(f"{where}: disposition {x.disposition!r}")
        if not x.month.isdigit() or not 1 <= int(x.month) <= 12:
            raise ValueError(f"{where}: month {x.month!r}")
        if not (x.rule and x.reason and x.evidence and x.unit_id and x.fy):
            raise ValueError(f"{where}: unit_id, fy, rule, reason and evidence are required")
        if x.disposition == "keep" and not x.rule.startswith(("reviewed", "default_")):
            raise ValueError(f"{where}: a keep row must be an author row (rule 'reviewed: ...') or a generated "
                             "default keep row (rule 'default_...')")
    if r.duplicated(["indicator", "unit_id", "fy", "month", "check"]).any():
        raise ValueError(f"{path.name}: duplicated (indicator, unit_id, fy, month, check) rows")
    return r


def manual_rows(reviewed: pd.DataFrame) -> pd.DataFrame:
    """The author's rows (rule starting 'reviewed'); default rows are regenerated by every build."""
    r = _norm(reviewed) if len(reviewed) else empty_reviewed()
    return r[r.rule.str.startswith("reviewed")].reset_index(drop=True)


def _add_flag(flags: pd.Series, mask, token: str) -> pd.Series:
    out = flags.copy()
    out[mask] = [f"{f};{token}" if f else token for f in flags[mask]]
    return out


def apply_dispositions(panel, failures, reviewed):
    """panel: long rows (LONG_KEYS + value [+ flag]). Returns (panel with masked values and `flag` tokens, the
    disposition log as REVIEWED_COLUMNS). A failure's disposition is the author row's (rule "reviewed: ...") when
    one matches, else the failure's `default` (mask, or keep for a plausibility low, ruling F41). Tokens: the check
    name (masked), "keep:<check>" (author keep), LOW_TOKEN (default_keep_low)."""
    p = panel.copy()
    if "flag" not in p:
        p["flag"] = ""
    p["flag"] = p["flag"].fillna("").astype(str)
    if failures is None or failures.empty:
        return p, empty_reviewed()
    rev = manual_rows(reviewed) if len(reviewed) else empty_reviewed()
    rk = {(x.indicator, x.unit_id, x.fy, int(x.month), x.check): x for x in rev.itertuples()}
    log = []
    for f in failures.itertuples():
        key = (f.indicator, f.unit_id, f.fy, int(f.month), f.check)
        if key in rk:
            x = rk[key]
            log.append({"indicator": f.indicator, "unit_id": f.unit_id, "fy": f.fy, "month": int(f.month),
                        "check": f.check, "disposition": x.disposition, "rule": x.rule, "reason": x.reason,
                        "evidence": x.evidence})
        else:
            disp = getattr(f, "default", "mask") or "mask"
            disp = disp if disp in DISPOSITIONS else "mask"
            log.append({"indicator": f.indicator, "unit_id": f.unit_id, "fy": f.fy, "month": int(f.month),
                        "check": f.check, "disposition": disp, "rule": f.rule,
                        "reason": DEFAULT_REASON if disp == "mask" else DEFAULT_KEEP_REASON, "evidence": f.evidence})
    log = pd.DataFrame(log, columns=REVIEWED_COLUMNS)
    tok = [c if d == "mask" else (LOW_TOKEN if r.startswith("default_keep_low") else f"keep:{c}")
           for c, d, r in zip(log.check, log.disposition, log.rule)]
    for token, sub in log.assign(_tok=tok).groupby("_tok", sort=False):
        hit = pd.Series(False, index=p.index)
        unit_rows = sub[sub.unit_id != "ALL"][LONG_KEYS].drop_duplicates()
        all_rows = sub[sub.unit_id == "ALL"][["fy", "month", "indicator"]].drop_duplicates()
        if len(unit_rows):
            k = p[LONG_KEYS].merge(unit_rows.assign(_hit=True), on=LONG_KEYS, how="left")["_hit"]
            hit |= k.notna().values
        if len(all_rows):
            k = p[["fy", "month", "indicator"]].merge(all_rows.assign(_hit=True), how="left")["_hit"]
            hit |= k.notna().values
        if sub.disposition.iloc[0] == "mask":
            p.loc[hit, "value"] = np.nan
        p["flag"] = _add_flag(p["flag"], hit, token)
    return p, log


def write_reviewed(log, path=REVIEWED_PATH, manual=None) -> pd.DataFrame:
    """Author rows (from `manual`, else the current file, plus any in the log) and this build's default rows."""
    path = Path(path)
    man = manual_rows(manual if manual is not None else read_reviewed(path))
    lg = _norm(log) if len(log) else empty_reviewed()
    keys = ["indicator", "unit_id", "fy", "month", "check"]
    authored = lg.rule.str.startswith("reviewed")
    out = pd.concat([man, lg[authored], lg[~authored]], ignore_index=True).drop_duplicates(keys, keep="first")
    out["_m"] = out.month.astype(int)
    out = out.sort_values(["indicator", "check", "fy", "_m", "unit_id"]).drop(columns="_m")
    path.parent.mkdir(parents=True, exist_ok=True)
    out[REVIEWED_COLUMNS].to_csv(path, index=False)
    return out[REVIEWED_COLUMNS].reset_index(drop=True)


# ---- indicator and FY rules (spec §10.2) --------------------------------------------------------------------------
def _is_masked(flags: pd.Series) -> pd.Series:
    return flags.fillna("").astype(str).map(lambda f: any(t in CHECKS for t in f.split(";") if t)).astype(bool)


def masked_share(panel, fys=PRIMARY_FYS) -> pd.Series:
    """Per indicator: unit-months masked by a gate / unit-months with a reported state value (masked included)."""
    p = panel[panel.fy.isin(fys)]
    out = {}
    for ind in INDICATORS:
        m = _is_masked(p[f"flag_{ind}"])
        rep = p[f"{ind}_raw"].notna() | m
        out[ind] = float(m.sum()) / rep.sum() if rep.sum() else np.nan
    return pd.Series(out)


def dropped_indicators(panel, max_masked=MAX_MASKED, fys=PRIMARY_FYS) -> list[str]:
    s = masked_share(panel, fys)
    return [i for i in INDICATORS if s[i] > max_masked]


def unusable_fys(panel, fys=PRIMARY_FYS) -> list[str]:
    present = [fy for fy in fys if (panel.fy == fy).any()]
    return [fy for fy in present if panel.loc[panel.fy == fy, list(PRIMARY5)].isna().all().all()]


def check_halt(dropped, panel) -> list[str]:
    """Raises PanelHalt (spec §10.2); otherwise returns the unusable primary FYs (none or one)."""
    lost = sorted(set(dropped) & set(PRIMARY5))
    bad = unusable_fys(panel)
    msgs = []
    if len(lost) >= 2:
        msgs.append(f"{len(lost)} primary indicators dropped (> {MAX_MASKED:.0%} of state-months masked): "
                    f"{', '.join(lost)}")
    if len(bad) > 1:
        msgs.append(f"{len(bad)} fiscal years of April 2012 - March 2020 unusable: {', '.join(bad)}")
    if msgs:
        raise PanelHalt("; ".join(msgs))
    return bad


# ---- the 2017 format break (descriptive) -----------------------------------------------------------------------
def break_ratio_2017(values) -> pd.DataFrame:
    """values: long pre-gate state values (unit_id, fy, month, indicator, value). National sums over the units
    reporting both March 2017 (FY2016-17) and April 2017 (FY2017-18)."""
    mar = values[(values.fy == "2016-17") & (values.month == 3)].set_index(["unit_id", "indicator"]).value
    apr = values[(values.fy == "2017-18") & (values.month == 4)].set_index(["unit_id", "indicator"]).value
    both = pd.concat([mar.rename("mar"), apr.rename("apr")], axis=1).dropna()
    rows = []
    for ind in INDICATORS:
        b = both[both.index.get_level_values("indicator") == ind] if len(both) else both
        m, a = (b.mar.sum(), b.apr.sum()) if len(b) else (np.nan, np.nan)
        ratio = a / m if len(b) and m else np.nan
        rows.append({"indicator": ind, "mar2017": m, "apr2017": a, "ratio": ratio,
                     "gt25pct": bool(pd.notna(ratio) and abs(ratio - 1) > 0.25), "n_units": len(b)})
    return pd.DataFrame(rows, columns=["indicator", "mar2017", "apr2017", "ratio", "gt25pct", "n_units"])


# ---- gate_summary.csv ----------------------------------------------------------------------------------------------
SCOPES = (("primary", PRIMARY_FYS), ("fy2020_21", (FY2021,)))


def _has(flags: pd.Series, pred) -> pd.Series:
    return flags.fillna("").astype(str).map(lambda f: pred([t for t in f.split(";") if t]))


def gate_summary(grid, panel, cmp, dm, dropped) -> pd.DataFrame:
    """SUMMARY_COLUMNS, one row per indicator x scope. `grid`: panel.assemble's long frame (raw = pre-gate value);
    `panel`: the wide panel; `cmp`: national_comparison; `dm`: district-month rows with unit_id."""
    rows = []
    for scope, fys in SCOPES:
        g_all = grid[grid.fy.isin(fys)]
        if g_all.empty:
            continue
        neg = negative_shares(dm[dm.fy.isin(fys)]).set_index("indicator").share
        part = partial_shares(g_all.assign(value=g_all.raw))
        for ind in INDICATORS:
            g = g_all[g_all.indicator == ind]
            fl = g["flag"]
            c = cmp[(cmp.indicator == ind) & cmp.fy.isin(fys)]
            na = c[c.status == "not available"].groupby("fy").size()
            reported = int(g.raw.notna().sum())
            masked = int(_has(fl, lambda t: any(x in CHECKS for x in t)).sum())
            p = part[part.indicator == ind].share
            row = {"indicator": ind, "scope": scope, "primary5": ind in PRIMARY5, "state_months": len(g),
                   "reported": reported}
            for chk in CHECKS:
                row[f"masked_{chk}"] = int(_has(fl, lambda t, chk=chk: chk in t).sum())
            row.update({
                "kept_by_review": int(_has(fl, lambda t: any(x.startswith("keep:") for x in t)).sum()),
                "kept_low": int(_has(fl, lambda t: LOW_TOKEN in t).sum()),
                "masked": masked, "masked_share": masked / reported if reported else np.nan,
                "comp_lt_090": int(_has(fl, lambda t: "comp_lt_090" in t).sum()),
                "entering_models": int(panel.loc[panel.fy.isin(fys), ind].notna().sum()),
                "dropped": bool(scope == "primary" and ind in dropped),
                "district_sum_tested": int(((g.comp >= 1 - 1e-12) & g.raw.notna() & g.dsum.notna()).sum()),
                "national_months_tested": int(c.status.isin(["pass", "fail"]).sum()),
                "national_months_failed": int((c.status == "fail").sum()),
                "national_months_not_evaluable": int((c.status == "not evaluable").sum()),
                "national_months_not_available": int((c.status == "not available").sum()),
                "national_not_available": "; ".join(f"{fy} ({n} of 12)" for fy, n in na.items()),
                "negative_district_share": neg.get(ind, np.nan),
                "partial_share_max": float(p.max()) if len(p) else np.nan,
                "partial_exempt": ind in PARTIAL_EXEMPT,
                "note": "" if scope == "primary" else "COVID-period sensitivity; outside the drop and halt rules"})
            rows.append(row)
    return pd.DataFrame(rows, columns=SUMMARY_COLUMNS)
