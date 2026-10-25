"""Validation gates that must pass before any modelling (spec §3.3)."""
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

from pipeline import manifest as mf
from pipeline.climate_annual import BASE, PROPAGATION_FILE, QC_REVIEWED, read_qc_reviewed
from pipeline.enso import SEASONS
from pipeline.paths import BLOCKLIST, DERIVED, month_table
from pipeline.qc_nearzero import NEARZERO_FRAC, NEARZERO_SHARE
from pipeline import subdivision as sub
from pipeline.subdivision import MIN_R as SUB_MIN_R

REF = Path(__file__).parent / "reference"
# Fixed by the GADM 4.1 canonicalisation (data/README.md "Known limitations"); never derived from the data.
EXPECTED_REGIONS = {"country": 1, "state": 36, "district": 666}
QC_VARIABLES = ("rain_jjas_mm", "rain_annual_mm")
QC_LOW, QC_HIGH = 0.25, 2.5                  # Ruling R20: ratio to the region's 1981-2010 median
POWER_RATIO_BAND = (0.5, 2.0)                # IMD/POWER JJAS ratio outside this band = outlier state-year


@dataclass
class GateResult:
    name: str
    passed: bool
    detail: str


def gate_allindia_jjas(country_year, reference, min_r=0.95, max_abs_diff=5.0) -> GateResult:
    cy = country_year[country_year.region_id == "IND"] if "region_id" in country_year else country_year
    normal = cy[cy.year.between(1981, 2020)].rain_jjas_mm.mean()
    ours = cy.assign(ours=100 * (cy.rain_jjas_mm - normal) / normal)[["year", "ours"]]
    m = reference.merge(ours, on="year")
    if len(m) < 10:
        return GateResult("allindia_jjas", False, f"only {len(m)} overlapping reference years")
    r = np.corrcoef(m.dep_pct, m.ours)[0, 1]
    d = m.ours - m.dep_pct
    bias = d.mean()
    raw = d.abs().max()
    adj = (d - bias).abs().max()
    ok = bool(r >= min_r and adj <= max_abs_diff)
    return GateResult("allindia_jjas", ok,
                      f"n={len(m)} r={r:.3f} bias={bias:+.1f} pp raw max|diff|={raw:.1f} pp "
                      f"bias-adjusted max|diff|={adj:.1f} pp (normal 1981-2020; IMD refs use era-specific LPAs)")


def _season_ord(season, year):
    return year * 12 + SEASONS.index(season)


def gate_enso_episodes(episodes, reference, tolerance_seasons=1) -> GateResult:
    missing = []
    for _, ref in reference.iterrows():
        cand = episodes[episodes.phase == ref.phase]
        d = (cand.apply(lambda e: _season_ord(e.start_season, e.start_year), axis=1)
             - _season_ord(ref.start_season, ref.start_year)).abs()
        if len(d) == 0 or d.min() > tolerance_seasons:
            missing.append(f"{ref.phase} {ref.start_season} {ref.start_year}")
    return GateResult("enso_episodes", not missing, "all matched" if not missing else "unmatched: " + "; ".join(missing))


def gate_blocklist(manifest_rows) -> GateResult:
    bad = [r["url"] for r in manifest_rows
           if any(b.lower() in (r.get("url", "") + r.get("path", "")).lower() for b in BLOCKLIST)]
    return GateResult("blocklist", not bad, "clean" if not bad else "blocked sources present: " + "; ".join(bad))


def gate_completeness(month, expected_regions, years, level=None, allowed_nan=frozenset()) -> GateResult:
    """Fixed region count x years x 12 rows, one row per region-month; NaN in rain_mm/tmax_mean only
    in (region_id, year) pairs listed in `allowed_nan` (reviewed QC masks)."""
    years = list(years)
    sub = month[month.year.isin(years)]
    want = expected_regions * len(years) * 12
    n_reg = sub.region_id.nunique()
    dup = int(sub.duplicated(["region_id", "year", "month"]).sum())
    isna = sub[["rain_mm", "tmax_mean"]].isna()
    allowed = set(allowed_nan)
    explained = pd.Series([(r, int(y)) in allowed for r, y in zip(sub.region_id, sub.year)], index=sub.index, dtype=bool)
    na = {k: int(v) for k, v in isna[~explained].sum().items()}
    n_explained = int(isna[explained].any(axis=1).sum())
    ok = len(sub) == want and n_reg == expected_regions and dup == 0 and sum(na.values()) == 0
    return GateResult("completeness" + (f"_{level}" if level else ""), ok,
                      f"rows={len(sub)} expected={want} regions={n_reg} expected_regions={expected_regions} "
                      f"duplicates={dup} missing={na} qc-explained NaN={n_explained}")


def qc_flags(year_table, level, base=BASE, lo=QC_LOW, hi=QC_HIGH) -> pd.DataFrame:
    """Region-years whose JJAS or annual rain is < lo or > hi times the region's base-period median."""
    rows = []
    t = year_table
    for var in QC_VARIABLES:
        med = t[t.year.between(*base)].groupby("region_id")[var].median()
        ratio = t[var] / t.region_id.map(med)
        bad = t[(ratio < lo) | (ratio > hi)]
        for idx, x in bad.iterrows():
            rows.append({"level": level, "region_id": x.region_id, "region_name": x.get("region_name", ""),
                         "year": int(x.year), "variable": var, "ratio": float(ratio[idx])})
    cols = ["level", "region_id", "region_name", "year", "variable", "ratio"]
    return pd.DataFrame(rows, columns=cols).sort_values(["level", "region_id", "year", "variable"]).reset_index(drop=True)


def gate_qc_plausibility(year_tables: dict, reviewed: pd.DataFrame) -> GateResult:
    """Ruling R20: every flagged region-year must be reviewed; every reviewed 'mask' must be applied."""
    key = ["level", "region_id", "year", "variable"]
    flags = pd.concat([qc_flags(t, lvl) for lvl, t in year_tables.items()], ignore_index=True)
    seen = {(str(r.level), str(r.region_id), int(r.year), str(r.variable)) for r in reviewed.itertuples()}
    unreviewed = [f for f in flags[key].itertuples(index=False, name=None)
                  if (str(f[0]), str(f[1]), int(f[2]), str(f[3])) not in seen]
    not_applied = []
    for m in reviewed[reviewed.disposition == "mask"].itertuples():
        t = year_tables.get(m.level)
        if t is None:
            continue
        row = t[(t.region_id == m.region_id) & (t.year == int(m.year))]
        tagged = len(row) == 1 and m.variable in str(row.qc_masked.fillna("").item()).split(";")
        if len(row) != 1 or not pd.isna(row[m.variable].item()) or not tagged:
            not_applied.append(f"{m.level} {m.region_id} {m.year} {m.variable}")
    n_keep = int((reviewed.disposition == "keep").sum())
    n_mask = int((reviewed.disposition == "mask").sum())
    detail = (f"flagged={len(flags)} (ratio to {BASE[0]}-{BASE[1]} median <{QC_LOW} or >{QC_HIGH}; "
              f"levels {'/'.join(year_tables)}; masked values are NaN and not re-flagged) "
              f"reviewed: keep={n_keep} mask={n_mask} unreviewed={len(unreviewed)}")
    if unreviewed:
        detail += "; unreviewed: " + "; ".join(" ".join(map(str, u)) for u in unreviewed[:10]) + (
            " ..." if len(unreviewed) > 10 else "")
    if not_applied:
        detail += "; mask not applied: " + "; ".join(not_applied[:10])
    return GateResult("qc_plausibility", not unreviewed and not not_applied, detail)


def gate_nearzero_reviewed(regions: pd.DataFrame, reviewed: pd.DataFrame, n_cells: int) -> GateResult:
    """Every region-year with >= NEARZERO_SHARE of its valid area in near-zero-fill cells
    (qc_rain_nearzero_regions.csv, pipeline.qc_nearzero) must have a reviewed row (any variable) in
    qc_reviewed.csv for the same level, region_id and year whose evidence cites the near-zero diagnostic
    (contains "nearzero" / "near-zero")."""
    seen = {(str(r.level), str(r.region_id), int(r.year)) for r in reviewed.itertuples()}
    keys = [(str(r.level), str(r.region_id), int(r.year)) for r in regions.itertuples()]
    unreviewed = [k for k in keys if k not in seen]
    cited = {(str(r.level), str(r.region_id), int(r.year)) for r in reviewed.itertuples()
             if "nearzero" in str(r.evidence).lower().replace("-", "").replace(" ", "")}
    no_ref = [k for k in keys if k in seen and k not in cited]
    disp = {}
    for r in reviewed.itertuples():
        disp.setdefault((str(r.level), str(r.region_id), int(r.year)), set()).add(r.disposition)
    n_mask = sum(1 for k in keys if "mask" in disp.get(k, set()))
    n_keep = sum(1 for k in keys if k in disp and "mask" not in disp[k])
    detail = (f"cells flagged={n_cells} (annual total < {NEARZERO_FRAC:.0%} of the cell's {BASE[0]}-{BASE[1]} "
              f"median) region-years={len(keys)} (>= {NEARZERO_SHARE:.0%} of valid area flagged) "
              f"reviewed: keep={n_keep} mask={n_mask} unreviewed={len(unreviewed)}")
    if unreviewed:
        detail += "; unreviewed: " + "; ".join(" ".join(map(str, u)) for u in unreviewed[:10]) + (
            " ..." if len(unreviewed) > 10 else "")
    if no_ref:
        detail += "; evidence without near-zero reference: " + "; ".join(" ".join(map(str, u)) for u in no_ref[:10])
    return GateResult("nearzero_reviewed", not unreviewed and not no_ref, detail)


def gate_district_mask_propagation(reviewed: pd.DataFrame, propagation: pd.DataFrame, year_tables: dict,
                                   district_state: dict) -> GateResult:
    """Every reviewed district mask must be propagated to its state and to the country
    (qc_district_mask_propagation.csv, climate_annual.infill_masked_districts) and applied there: an
    'infilled' parent row carries the district_masks_infilled tag with that variable and a value, a 'masked'
    one (or one masked by its own reviewed mask) is NaN; 'no_valid_cells' needs nothing. Fails otherwise."""
    dm = reviewed[(reviewed.level == "district") & (reviewed.disposition == "mask")]
    prop = {(str(r.level), str(r.region_id), int(r.year), str(r.variable)): r for r in propagation.itertuples()}
    country = year_tables["country"]
    cid = str(country.region_id.iloc[0])
    missing, not_applied, counts = [], [], {}
    for m in dm.itertuples():
        for level, rid in (("state", str(district_state.get(str(m.region_id), ""))), ("country", cid)):
            key = (level, rid, int(m.year), str(m.variable))
            r = prop.get(key)
            if r is None:
                missing.append(" ".join(map(str, key)))
                continue
            counts.setdefault(level, {}).setdefault(r.action, set()).add(key)
            if r.action == "no_valid_cells":
                continue
            t = year_tables[level]
            row = t[(t.region_id.astype(str) == rid) & (t.year == int(m.year))]
            if len(row) != 1:
                not_applied.append(" ".join(map(str, key)))
                continue
            value, tag = row[m.variable].item(), str(row.qc_masked.fillna("").item())
            ok = (pd.isna(value) if (r.action == "masked" or bool(getattr(r, "reviewed_mask", False)))
                  else ("district_masks_infilled" in tag and m.variable in tag and pd.notna(value)))
            if not ok:
                not_applied.append(" ".join(map(str, key)))
    parts = [f"{lvl}: " + " ".join(f"{a}={len(k)}" for a, k in sorted(c.items())) for lvl, c in sorted(counts.items(), reverse=True)]
    detail = (f"reviewed district masks={len(dm)}; " + "; ".join(parts) +
              f"; not propagated={len(missing)} not applied={len(not_applied)}")
    if missing:
        detail += "; not propagated: " + "; ".join(sorted(set(missing))[:10])
    if not_applied:
        detail += "; not applied: " + "; ".join(sorted(set(not_applied))[:10])
    return GateResult("district_mask_propagation", not missing and not not_applied, detail)


def gate_subdivision_jjas(t: pd.DataFrame, reviewed: pd.DataFrame, min_r=SUB_MIN_R, mapped=None, imd_names=None,
                          expected=None) -> GateResult:
    """Our JJAS rain aggregated to IMD subdivisions vs IMD's official sub-divisional series: fails if any
    subdivision has r < min_r and is not listed in pipeline/reference/subdivision_reviewed.csv, if a mapped
    subdivision name is absent from the IMD file, or if the number compared differs from `expected`."""
    if t.empty:
        return GateResult("subdivision_jjas", False, "no subdivision with enough overlapping years")
    problems = []
    if mapped is not None and imd_names is not None:
        absent = sorted(set(mapped) - set(imd_names))
        if absent:
            problems.append("mapped subdivisions not in IMD file: " + ", ".join(absent))
    if expected is not None and len(t) != expected:
        problems.append(f"compared {len(t)} != expected {expected}")
    low = t[t.r < min_r]
    known = set(reviewed.subdivision)
    unrev = [s for s in low.subdivision if s not in known]
    worst = t.loc[t.r.idxmin()]
    detail = (f"subdivisions={len(t)} years {int(t.first_year.min())}-{int(t.last_year.max())} "
              f"median r={t.r.median():.3f} min r={worst.r:.3f} ({worst.subdivision}) "
              f"mean ratio ours/IMD {t.mean_ratio.min():.2f}-{t.mean_ratio.max():.2f}; "
              f"r<{min_r}: {len(low)}")
    rev = [s for s in low.subdivision if s in known]
    if rev:
        detail += "; reviewed exceptions: " + ", ".join(rev)
    if unrev:
        detail += f"; unreviewed r<{min_r}: " + ", ".join(unrev)
    if problems:
        detail += "; " + "; ".join(problems)
    return GateResult("subdivision_jjas", not unrev and not problems, detail)


DIAGNOSTIC_GATES = {"power_vs_imd"}


CLIMATE_UNIT_START = 1981


def gate_climate_unit_year(t: pd.DataFrame, units=None, start=CLIMATE_UNIT_START) -> GateResult:
    """climate_unit_year.csv: the unit set equals the outcome unit frame (default the 34 units of
    pipeline/reference/state_frame.csv), (unit_id, year) is unique and every unit has every year
    start..max(year) (contiguous)."""
    if units is None:
        from pipeline.outcomes import states
        units = states.UNITS
    units = set(map(str, units))
    have = set(t.unit_id.astype(str))
    fails = []
    if have != units:
        fails.append(f"units absent {sorted(units - have)} unexpected {sorted(have - units)}")
    dup = int(t.duplicated(["unit_id", "year"]).sum())
    if dup:
        fails.append(f"duplicate (unit_id, year)={dup}")
    last = int(t.year.max()) if len(t) else start - 1
    want = {(u, y) for u in units for y in range(start, last + 1)}
    keys = set(zip(t.unit_id.astype(str), t.year.astype(int)))
    if keys != want:
        miss, extra = sorted(want - keys), sorted(keys - want)
        fails.append(f"unit-years absent={len(miss)} {miss[:5]} outside {start}-{last}={len(extra)} {extra[:5]}")
    detail = f"units={len(have)} (frame {len(units)}) years={start}-{last} rows={len(t)}"
    return GateResult("climate_unit_year", not fails, detail + ("; " + "; ".join(fails) if fails else ""))


def climate_unit_year_check(derived=DERIVED) -> GateResult:
    path = Path(derived) / "climate_unit_year.csv"
    if not path.exists():
        return GateResult("climate_unit_year", False, f"missing {path.name} (run python -m pipeline.climate_units)")
    return gate_climate_unit_year(pd.read_csv(path))


def label(r: GateResult) -> str:
    return "FAIL" if not r.passed else ("DIAG" if r.name in DIAGNOSTIC_GATES else "PASS")


def format_result(r: GateResult) -> str:
    return f"{label(r)} {r.name} {r.detail}"


def _power_jjas(imd_state_year, power_state_month) -> pd.DataFrame:
    pj = (power_state_month[power_state_month.month.isin([6, 7, 8, 9])]
          .groupby(["region_id", "year"], as_index=False).rain_mm.sum().rename(columns={"rain_mm": "power"}))
    return imd_state_year.merge(pj, on=["region_id", "year"]).dropna(subset=["rain_jjas_mm", "power"])


def power_outliers(imd_state_year, power_state_month, band=POWER_RATIO_BAND) -> pd.DataFrame:
    """State-years whose IMD/POWER JJAS ratio falls outside `band`."""
    m = _power_jjas(imd_state_year, power_state_month)
    if "region_name" not in m:
        m["region_name"] = ""
    m["ratio"] = m.rain_jjas_mm / m.power
    o = m[(m.ratio < band[0]) | (m.ratio > band[1])].rename(
        columns={"rain_jjas_mm": "imd_jjas_mm", "power": "power_jjas_mm"})
    return o[["region_id", "region_name", "year", "imd_jjas_mm", "power_jjas_mm", "ratio"]].sort_values(
        ["region_id", "year"]).reset_index(drop=True)


def power_table(imd_state_year, power_state_month, min_years=10) -> pd.DataFrame:
    """Per-state correlation of POWER vs IMD JJAS rainfall (ascending r)."""
    m = _power_jjas(imd_state_year, power_state_month)
    names = (imd_state_year[["region_id", "region_name"]].drop_duplicates("region_id")
             if "region_name" in imd_state_year else pd.DataFrame({"region_id": m.region_id.unique(), "region_name": ""}))
    rows = []
    for rid, g in m.groupby("region_id"):
        if len(g) >= min_years:
            rows.append({"region_id": rid, "r": float(np.corrcoef(g.rain_jjas_mm, g.power)[0, 1]), "n_years": len(g)})
    t = pd.DataFrame(rows, columns=["region_id", "r", "n_years"]).dropna()
    t = names.merge(t, on="region_id")
    return t[["region_id", "region_name", "r", "n_years"]].sort_values("r").reset_index(drop=True)


def gate_power_vs_imd(imd_state_year, power_state_month, min_years=10, table=None) -> GateResult:
    """Diagnostic only: passes whenever it can be computed. `table` is a precomputed power_table."""
    t = table if table is not None else power_table(imd_state_year, power_state_month, min_years)
    if t.empty:
        return GateResult("power_vs_imd", False, "no state with enough overlapping years")
    return GateResult("power_vs_imd", True,
                      f"states={len(t)} median r={t.r.median():.3f} min r={t.r.min():.3f}")


# Subdivision-years checked against IMD's official series in the report (masked and unmasked grid values).
SUBDIVISION_CHECKS = [("Saurashtra & Kutch", 1987), ("Saurashtra & Kutch", 2011), ("Tamil Nadu", 2002),
                      ("Tamil Nadu", 2003), ("Tamil Nadu", 2011), ("Tamil Nadu", 2012),
                      ("Arunachal Pradesh", 1999), ("Jammu & Kashmir", 2001)]


def _subdivision_checks(merged, district_month, mapping, areas, imd) -> pd.DataFrame:
    jj = (district_month[district_month.month.isin([6, 7, 8, 9])].groupby(["region_id", "year"], as_index=False)
          .rain_mm.sum(min_count=4).rename(columns={"rain_mm": "rain_jjas_mm"}))
    raw = sub.aggregate(jj, mapping, areas, min_area_frac=0.0).rename(columns={"ours_mm": "unmasked_mm"})
    keys = pd.DataFrame(SUBDIVISION_CHECKS, columns=["subdivision", "year"])
    out = (keys.merge(imd, on=["subdivision", "year"], how="left")
           .merge(merged[["subdivision", "year", "ours_mm"]], on=["subdivision", "year"], how="left")
           .merge(raw[["subdivision", "year", "unmasked_mm"]], on=["subdivision", "year"], how="left"))
    return out


def subdivision_check(derived, imd_subdivisions, subdivision_map, subdivision_reviewed, expected_districts=666,
                       expected_subdivisions=sub.EXPECTED_SUBDIVISIONS, district_year=None):
    """(gate, comparison table, merged subdivision-years, mapping, areas, IMD table); a missing input file
    gives a FAIL gate and empty tables instead of an exception."""
    d = Path(derived)
    missing = [str(x) for x in (imd_subdivisions, subdivision_map) if not Path(x).exists()]
    if missing:
        return (GateResult("subdivision_jjas", False, "missing input: " + "; ".join(missing)),
                pd.DataFrame(), pd.DataFrame(), None, None, None)
    mapping = sub.read_mapping(subdivision_map, expected_districts)
    areas = sub.district_areas(d / "_parts")
    imd_sub = sub.read_imd_subdivisions(imd_subdivisions)
    dy = district_year if district_year is not None else pd.read_csv(d / "climate_district_year.csv")
    ours_sub = sub.aggregate(dy, mapping, areas)
    stable = sub.compare(ours_sub, imd_sub)
    merged = ours_sub.merge(imd_sub, on=["subdivision", "year"])
    merged = merged[merged.year.between(*sub.OVERLAP)]
    g = gate_subdivision_jjas(stable, sub.read_reviewed(subdivision_reviewed), mapped=mapping.imd_subdivision.unique(),
                              imd_names=imd_sub.subdivision.unique(), expected=expected_subdivisions)
    return g, stable, merged, mapping, areas, imd_sub


def run_all(derived=DERIVED, qc_reviewed=QC_REVIEWED, expected=EXPECTED_REGIONS,
            imd_subdivisions=sub.IMD_SUBDIVISION_CSV, subdivision_map=sub.MAPPING,
            subdivision_reviewed=sub.SUBDIVISION_REVIEWED, outcomes_reviewed=None) -> list[GateResult]:
    d = Path(derived)
    year_tables = {lvl: pd.read_csv(d / f"climate_{lvl}_year.csv", dtype={"qc_masked": str})
                   for lvl in ("state", "district")}
    cy = pd.read_csv(d / "climate_country_year.csv", dtype={"qc_masked": str})
    sy = year_tables["state"]
    reviewed = read_qc_reviewed(qc_reviewed)
    power = pd.read_csv(d / "power_state_month.csv")
    ptable = power_table(sy, power)
    outliers = power_outliers(sy, power)
    res = [
        gate_allindia_jjas(cy, pd.read_csv(REF / "imd_allindia_jjas_departure.csv")),
        gate_enso_episodes(pd.read_csv(d / "enso_episodes.csv"), pd.read_csv(REF / "noaa_enso_episodes.csv")),
        gate_blocklist(mf.read()),
    ]
    month_tables = {lvl: pd.read_csv(month_table(lvl, d)) for lvl in ("country", "state", "district")}
    for lvl, m in month_tables.items():
        masked = reviewed[(reviewed.level == lvl) & (reviewed.disposition == "mask")]
        allowed = {(str(r), int(y)) for r, y in zip(masked.region_id, masked.year)}
        res.append(gate_completeness(m, expected[lvl], range(1981, int(m.year.max()) + 1), lvl, allowed))
    district_month = month_tables["district"]
    res.append(gate_qc_plausibility(year_tables, reviewed))
    prop_path = d / PROPAGATION_FILE
    district_state = dict(zip(district_month.region_id.astype(str), district_month.state_id.astype(str))) \
        if "state_id" in district_month else {}
    if prop_path.exists():
        res.append(gate_district_mask_propagation(
            reviewed, pd.read_csv(prop_path, dtype={"region_id": str}),
            {"state": year_tables["state"], "country": cy}, district_state))
    elif len(reviewed[(reviewed.level == "district") & (reviewed.disposition == "mask")]):
        res.append(GateResult("district_mask_propagation", False, f"missing {prop_path.name} "
                                                                  "(run python -m pipeline.climate_annual)"))
    nz_path, nzc_path = d / "qc_rain_nearzero_regions.csv", d / "qc_rain_nearzero_cells.csv"
    if nz_path.exists() and nzc_path.exists():
        nz = pd.read_csv(nz_path, dtype={"region_id": str})
        res.append(gate_nearzero_reviewed(nz, reviewed, n_cells=len(pd.read_csv(nzc_path))))
    else:
        nz = pd.DataFrame()
        res.append(GateResult("nearzero_reviewed", False, f"missing {nz_path.name} / {nzc_path.name} "
                                                          "(run python -m pipeline.qc_nearzero)"))
    sg, stable, merged, mapping, areas, imd_sub = subdivision_check(
        d, imd_subdivisions, subdivision_map, subdivision_reviewed, expected["district"],
        expected.get("subdivisions", sub.EXPECTED_SUBDIVISIONS), district_year=year_tables["district"])
    res.append(sg)
    sub_reviewed = sub.read_reviewed(subdivision_reviewed)
    checks = (_subdivision_checks(merged, district_month, mapping, areas, imd_sub) if mapping is not None
              else pd.DataFrame(columns=["subdivision", "year", "imd_jjas_mm", "ours_mm", "unmasked_mm"]))
    pg = gate_power_vs_imd(sy, power, table=ptable)
    pg.detail += (f" outlier state-years={len(outliers)} "
                  f"(IMD/POWER JJAS ratio outside {POWER_RATIO_BAND[0]}-{POWER_RATIO_BAND[1]})")
    res.append(pg)
    res.append(climate_unit_year_check(d))
    outcome_dir = d / "outcomes"
    if outcome_dir.is_dir():                                        # Phase 2a panels (assemble.build_all)
        if not (outcome_dir / "outcome_records_all.csv.gz").exists():
            res.append(GateResult("outcome_records", False, f"{outcome_dir} exists but outcome_records_all.csv.gz "
                                                            "is missing (run python -m pipeline.outcomes.assemble)"))
        else:
            from pipeline.outcomes import gates as outcome_gates
            res += outcome_gates.run_outcome_gates(
                outcome_dir,
                reviewed_path=outcome_gates.REVIEWED if outcomes_reviewed is None else outcomes_reviewed)
    lines = ["# Validation report", "", "| Gate | Result | Detail |", "|---|---|---|"]
    lines += [f"| {r.name + (' (diagnostic)' if r.name in DIAGNOSTIC_GATES else '')} | {label(r)} | {r.detail} |"
              for r in res]
    lines += ["", "## NASA POWER cross-check (diagnostic, not a gate)", "",
              "Correlation of NASA POWER JJAS rainfall with IMD JJAS rainfall per state, ascending r.", "",
              "| region_id | region_name | r | n_years |", "|---|---|---|---|"]
    lines += [f"| {x.region_id} | {x.region_name} | {x.r:.3f} | {x.n_years} |"
              for x in ptable.itertuples()]
    lines += ["", f"### POWER outlier state-years (IMD/POWER JJAS ratio outside "
                  f"{POWER_RATIO_BAND[0]}-{POWER_RATIO_BAND[1]})", "",
              "| region_id | region_name | year | IMD JJAS mm | POWER JJAS mm | ratio |", "|---|---|---|---|---|---|"]
    lines += [f"| {x.region_id} | {x.region_name} | {x.year} | {x.imd_jjas_mm:.0f} | {x.power_jjas_mm:.0f} | "
              f"{x.ratio:.2f} |" for x in outliers.itertuples()]
    lines += ["", "## IMD sub-divisional rainfall check (gate subdivision_jjas)", "",
              "District JJAS rain (QC-masked annual table) aggregated to IMD meteorological subdivisions "
              "(pipeline/reference/district_to_imd_subdivision.csv; area-weighted; subdivision-years with < "
              f"{sub.MIN_AREA_FRAC:.0%} of the area unmasked dropped) vs IMD's official sub-divisional JJAS series "
              f"(data.gov.in, 1901-2017), {sub.OVERLAP[0]}-{sub.OVERLAP[1]}. Ascending r; the gate fails on r < "
              f"{sub.MIN_R} unless the subdivision is listed in pipeline/reference/subdivision_reviewed.csv.", "",
              "| subdivision | n_years | r | mean ratio ours/IMD | reviewed |", "|---|---|---|---|---|"]
    rv = dict(zip(sub_reviewed.subdivision, sub_reviewed.reason))
    lines += [f"| {x.subdivision} | {x.n_years} | {x.r:.3f} | {x.mean_ratio:.2f} | {rv.get(x.subdivision, '')} |"
              for x in stable.itertuples()]
    lines += ["", "### Checked subdivision-years (JJAS mm)", "",
              "| subdivision | year | IMD official | ours (QC-masked) | ours (unmasked grid) |", "|---|---|---|---|---|"]
    fmt = lambda x: "" if pd.isna(x) else f"{x:.0f}"
    lines += [f"| {x.subdivision} | {x.year} | {fmt(x.imd_jjas_mm)} | {fmt(x.ours_mm)} | {fmt(x.unmasked_mm)} |"
              for x in checks.itertuples()]
    if prop_path.exists():
        pr = pd.read_csv(prop_path, dtype={"region_id": str})
        pr = pr[pr.action != "no_valid_cells"]
        names = dict(zip(year_tables["state"].region_id.astype(str), year_tables["state"].region_name))
        lines += ["", "## District-mask propagation (gate district_mask_propagation)", "",
                  "State and country region-years containing reviewed district masks with valid grid cells "
                  "(qc_district_mask_propagation.csv): masked districts' cells infilled at the rest of the region's "
                  "ratio to its 1981-2010 normal, or the region-year masked when the masked share is > 50% or the "
                  "remainder < 1,000 km2. Rows with no valid masked cells (Andaman and Nicobar) are omitted.", "",
                  "| level | region_id | region_name | year | variable | action | masked districts | own reviewed mask |",
                  "|---|---|---|---|---|---|---|---|"]
        lines += [f"| {x.level} | {x.region_id} | {names.get(x.region_id, 'India' if x.level == 'country' else '')} | "
                  f"{x.year} | {x.variable} | {x.action} | {x.n_masked_districts} | {bool(x.reviewed_mask)} |"
                  for x in pr.itertuples()]
    if len(nz):
        disp = {}
        for r in reviewed.itertuples():
            disp.setdefault((str(r.level), str(r.region_id), int(r.year)), set()).add(r.disposition)
        lines += ["", "## Near-zero-fill cells (gate nearzero_reviewed)", "",
                  f"Region-years with >= {NEARZERO_SHARE:.0%} of their valid area in 0.25 deg cells whose annual total "
                  f"is < {NEARZERO_FRAC:.0%} of the cell's {BASE[0]}-{BASE[1]} median (qc_rain_nearzero_regions.csv). "
                  "est. bias: region annual mean vs a counterfactual with the flagged cells at their median scaled "
                  "by the region's unflagged cells.", "",
                  "| level | region_id | region_name | year | flagged share | flagged cells | est. bias % | disposition |",
                  "|---|---|---|---|---|---|---|---|"]
        lines += [f"| {x.level} | {x.region_id} | {x.region_name} | {x.year} | {x.flagged_share:.2f} | "
                  f"{x.n_flagged_cells} | {fmt(x.est_bias_pct)} | "
                  f"{'/'.join(sorted(disp.get((str(x.level), str(x.region_id), int(x.year)), {'unreviewed'})))} |"
                  for x in nz.itertuples()]
    if len(reviewed):
        lines += ["", "## Reviewed QC flags (pipeline/reference/qc_reviewed.csv)", "",
                  "| level | region_id | region_name | year | variable | ratio | disposition | reason |",
                  "|---|---|---|---|---|---|---|---|"]
        lines += [f"| {x.level} | {x.region_id} | {x.region_name} | {x.year} | {x.variable} | {x.ratio:.2f} | "
                  f"{x.disposition} | {x.reason} |" for x in reviewed.itertuples()]
    (d / "validation_report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return res


if __name__ == "__main__":
    results = run_all()
    for r in results:
        print(format_result(r))
    sys.exit(0 if all(r.passed for r in results) else 1)
