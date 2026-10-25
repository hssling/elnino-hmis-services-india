# Paper E: El Niño and the continuity of essential health services in India, HMIS 2012–2020 (design)

**Status:** draft for author approval, 2026-10-24. Choices marked *(builder's/author's call)* are defaults that the builder may refine, or the author may override, without re-opening the design.

**Sources.** Feasibility spike `docs/superpowers/paperE-notes/2026-10-24-hmis-feasibility-spike.md` (data facts). House style and methods conventions: `docs/superpowers/specs/2026-10-15-phase2-papers-a-c-design.md` (§2, Amendment A1, §6 roadmap). Latest spec structure: `docs/superpowers/specs/2026-10-23-paper-d-synthesis-atlas-design.md`.

**Author decisions (binding, 2026-10-24).**
- State-month panel, FY2012-13 to FY2019-20 (April 2012 to March 2020).
- FY2020-21 is a COVID-flagged sensitivity analysis only. It never enters the primary analysis.
- Indicators: diarrhoea in children under 5; ANC registration; Penta3 and MCV/full immunisation; OPD attendance; institutional deliveries (harmonised across the 2017-18 break).
- El Niño episodes studied: 2014–16 and 2018–19. The 2023–24 episode is out of scope because public HMIS after FY2020-21 requires a login, and we never log in.
- Target: [journal-selection or submission note redacted from the public copy; not part of the analysis protocol]
- Sole author: Dr Siddalingaiah H S.

**Working title:** *El Niño and the continuity of essential maternal, child and outpatient services in India: a state-month analysis of routine HMIS data, 2012–2020.*

## 1. Intent and why

Papers A–C asked whether El Niño changes **disease**: malaria and dengue, heat deaths, farm distress and child growth. Paper D synthesised those results. Paper E asks a different question, about **services**: does El Niño disrupt the delivery and use of essential health services?

The plausible pathways are these:
- drought and heat reduce travel to facilities and outreach sessions;
- floods and heavy rain close roads and sub-centres;
- distress migration moves pregnant women and infants out of the catchments where they were registered;
- heat and water scarcity may raise diarrhoea in under-5s, which shows up as more facility visits, or fewer visits if access is impaired.

What is new versus A–D:
- **Outcome type:** service contacts (ANC, immunisation, deliveries, OPD), plus reported childhood diarrhoea.
- **Time scale:** monthly, not annual. This is the first programme paper that can resolve within-season timing.
- **Data system:** routine HMIS facility reports.
- **Identification:** state-month variation in local weather within the same calendar month. National shocks can be absorbed by year-month fixed effects. That was impossible in the annual panels.

The honest expectation, given A–D, is a small or null total ENSO association with wide uncertainty. Paper E is designed so that a null is informative: a stated minimum detectable effect, two episodes judged separately, and a local-climate pathway that has much more identifying variation than ENSO itself.

## 2. Goals, non-goals, anti-goals

**Goals**
1. A validated, harmonised **state-month HMIS panel** for 34 units × 96 months (April 2012 to March 2020), plus FY2020-21 as a flagged extension. It has an item crosswalk across the 2017-18 break, monthly values differenced from cumulative files, and a reporting-completeness measure for each cell.
2. **Total El Niño association** with each service outcome (hypotheses H7 and H8), with inference that respects a national exposure.
3. **Local-climate pathway** (H9): rainfall anomaly and heatwave days versus services, within calendar month across states, plus the share of any total association carried by local climate.
4. **Predictive value**: nested forecast Models A/B/C, LOEO and rolling-origin validation, and the ONI vs RONI vs Niño-3.4 comparison (Amendment A1).
5. A journal package and a public code-and-aggregates release, on the author's go-ahead.

**Non-goals**
- District-level analysis, maps or rankings. Districts are used only as the aggregation and completeness layer inside the pipeline.
- Any data that need a login, registration, an API key (including keys embedded in data.gov.in pages) or third-party copies (Dataful). FY2021-22 to 2025-26 are out of scope.
- The 2023–24 El Niño. The paper names this gap as a limitation, with a formal MoHFW data request as the route to close it.
- A 2026–27 service outlook. The data end in 2020, and services are not forecast targets in this programme.
- Analysis of COVID-19 effects. FY2020-21 is used only to show whether conclusions survive its inclusion.
- A gradient-boosting or machine-learning comparison *(builder's/author's call; the same reasoning as Paper D §2)*.

**Anti-goals** (failure even if the code works)
- Causal over-claiming, for example "El Niño caused N missed vaccinations". Estimates are associations in reported service counts. No attributable-burden numbers.
- State-specific El Niño sensitivity claims or rankings, unless identified by the rule in §5.5. Papers A and C found random-slope SDs at the boundary, and there is no reason to expect better identification from 8 years.
- Reading a reporting artefact (non-reporting, catch-up reporting, an item renumbering) as a service disruption. Missing is never zero (§3.6).
- Treating HMIS as covering the private sector. Private reporting is minimal, so claims concern publicly reported services.
- Mentioning any prior paper of the author that the programme's standing disclosure rule excludes (the same rule as Papers B and D).

## 3. Data

### 3.1 Acquisition (`pipeline/hmis/fetch.py`, reusing `pipeline/outcomes/fetch.get`)

**Primary source, FY2012-13 to FY2019-20.** HMIS portal Standard Reports → "C2. Data Itemwise Monthly (up to sub district)" → "3. All States and Districts Across Months":
- 8 annual zips, 13–62 MB each (about 300 MB in total);
- listing endpoint `https://hmis.mohfw.gov.in/getFiles?fpath=<base64 path>`;
- download endpoint `https://hmis.mohfw.gov.in/downloadfiles?filepath=<URL-encoded path>`.

Each zip holds per-state "upto <month>" files. These are wide (one row per item, one column per district plus a `_State` aggregate) and cumulative within the financial year.

**Cross-check source.** Folder "1. All India Across States", where it exists for a year. It is used only for the national-total gate.

**FY2020-21 sensitivity.** The portal "4. All Districts Across Subdistricts / 2020-2021 / A.MonthWise" holds per-district, per-month .xlsx files (about 0.03–0.04 MB each; roughly 700 districts × 12 ≈ 8,400 files). The builder first checks whether folders 1 or 2 hold state-level 2020-21 files, and uses those if they do.
- Budget rule: at most 10,000 requests, spaced at least 2 s apart (about 5–6 hours, run once, resumable).
- If more are needed, stop and ask the author. If the author declines, FY2020-21 is dropped and the paper says so.

**data.gov.in.** Legacy per-district CSVs are used only to fill a specific gap that the builder finds in a portal zip. Use the legacy `http://data.gov.in/sites/default/files/...` path, which follows a 301 redirect; the `/files/ogdpv2dms/...` path returns 403. Each fill is logged.

**Politeness and integrity rules**
- One request at a time, at least 5 s apart for zips and at least 2 s for small files, with the existing retry and back-off.
- Cache under `data/raw/hmis/<source_id>/`, with a `.urls.json` sidecar and a `data/MANIFEST.csv` row for each file (URL, UTC retrieval time, SHA-256, bytes). A cache hit is verified against its SHA-256.
- **Never bypass a challenge.** On a CAPTCHA, WAF page, login redirect or repeated 403, stop the run and report it. Do not rotate user-agents, use proxies or try alternative paths to get round it. The stale-path redirect above is the only path substitution allowed, because it is a documented legacy URL, not a block.
- Downloaded files are untrusted data:
  - Read zips in place with `zipfile`, with a path-traversal guard and no extraction to disk.
  - Read .xlsx with `openpyxl` in read-only mode.
  - Never execute anything from a download, and run parsers with `python -I`.
- Disk: D: has about 7 GB free. Keep the zips, parse in streaming fashion, and write only derived CSVs.
- **Licence and attribution:**
  - data.gov.in content: GODL-India. Attribute "Health Management Information System (HMIS), Ministry of Health and Family Welfare, Government of India; via data.gov.in / hmis.mohfw.gov.in; Government Open Data License – India", with URLs, in `papers/E/sources.md`, the data-availability statement and the release README.
  - Portal-only files (FY2020-21): cite the portal and note that it states no explicit licence.

### 3.2 Parsing by era (`pipeline/hmis/parse.py`)

| Era | Financial years | Layout (from the spike) | Parser |
|---|---|---|---|
| E1 | 2012-13 to 2016-17 | Columns Indicator, S.No., Parameters, Type, then `_State` plus districts (Total only); "NA" strings; status-date line | `parse_e1` |
| E2 | 2017-18 to 2019-20 | 4 id columns, then `_State` plus districts × 5 splits (Total, Public, Private, Urban, Rural); only Total is used | `parse_e2` |
| E3 | 2020-21 | Per-district monthly .xlsx with a 5-line header and "Status as on …"; sub-district columns plus the district aggregate | `parse_e3` |

- Output, in long format: `fy, month, state_raw, district_raw, is_state_aggregate, item_code, item_text, type, value, cumulative (bool), status_date, source_file`.
- "NA" becomes NaN, never 0.
- The leading underscore marks the aggregate column (`_Kerala`). Sub-district and "Urban" columns are dropped where a district aggregate exists.
- Each era parser is tested on a fixture cut from one real file per era (the spike's e1 to e5 shapes).
- The parser fails loudly on an unknown header layout.
- The FY2012-13 layout and a FY2017-18 sample are not yet seen. Inspect both first; if either differs, it gets its own parser (E0 or E2a).

### 3.3 Differencing cumulative files (`pipeline/hmis/difference.py`)

- Within a financial year, for each district and item: `value[m] = upto[m] − upto[m−1]`, with `upto[Apr] = value[Apr]`.
- Before differencing, check that all files in one FY zip share a status date (or record each one). Differences across files with different status dates mix revision vintages; flag those months as `vintage_mixed`.
- **Negative increments** (revisions) set the district-month to NaN and add a flag. The count of affected district-months is reported. Gate: at most 1% of district-months per indicator; above that, a reviewed disposition is required.
- **Zero increments** on high-volume items are not taken at face value (§3.6).
- Where both month-specific and cumulative files exist (2019-20 sub-district month files; 2020-21), month files take precedence. The cumulative files then serve as a check that the month files sum to the cumulative value within 1%.

### 3.4 Item crosswalk (`pipeline/reference/hmis_item_crosswalk.csv`)

Columns: `indicator, era, item_codes, combine, text_pattern, definition_note, verified_in_file`. Matching requires both the item code and a normalised-text regex. A code whose text does not match fails the build.

| Indicator (analysis variable) | E1, pre-2017-18 | E2/E3, from 2017-18 | Harmonised definition and break handling |
|---|---|---|---|
| `diarr_u5`: diarrhoea, children under 5 | 12.7 "Diarrhoea and Dehydration … below 5" | 10.11 "Childhood Diseases – Diarrhoea" (0–5 years) | Wording changes, so `hmis_format2017` step indicator; secondary check with era-specific state intercepts. Inpatient items (10.12, 14.4.7) are not used |
| `anc_reg`: ANC registration | 1.1 | 1.1 | Unchanged |
| `penta3`: third dose of a DPT-containing vaccine | 10.1.04C (Penta3) **plus** DPT3 where a state had not yet switched to pentavalent (item to be located) | 9.1.8 | Pentavalent was phased in by state up to about 2015. Sum Penta3 + DPT3 *(builder verifies DPT3 item codes)* |
| `mcv1`: first measles-containing dose | 10.1.12 measles first dose | 9.2.1 "MR/MCV" + 9.2.2 "Measles 1st dose" | Always sum. A zero in 9.2.2 after MR introduction is real, not missing |
| `fic`: full immunisation | 10.1.13.c (9–11 months) | 9.2.4.a + 9.2.4.b (male + female) | Sum. Age bands to be checked against E2 files; secondary outcome |
| `inst_del`: institutional deliveries | 2.2 public + 2.3 private | 2.2 "Institutional Deliveries (Including C-Sections)" | Sum E1 rows, so the series is continuous. Break indicator as for all outcomes |
| `opd`: outpatient attendance | 14.12.1 "OPD attendance (All)" | 14.2.1 Allopathic + 14.2.2 AYUSH | Sum E2 rows, to approximate "All" |

`verified_in_file` must name a real cached file for every era row before the panel is built. The national March 2017 → April 2017 ratio for each indicator is reported descriptively. A jump above 25% is discussed, but it does not by itself exclude the indicator.

### 3.5 District → state → 34 units

- **Primary state value:** the file's own `_State` aggregate.
- **Check:** the sum of district Total columns.
- **Gate:** agreement within 2% (counts ≥ 100) or ±5 (counts < 100), or a reviewed disposition in `pipeline/reference/hmis_reviewed.csv`.
- State names are mapped through `pipeline/outcomes/states.py` and the aliases in `pipeline/reference/state_frame.csv`, after stripping the underscore and adding HMIS variants. Unmapped names fail the build.
- **Pooled units.**
  - AP_TG pools Andhra Pradesh and Telangana; this absorbs the June 2014 split, including part-year 2014-15 files.
  - JK pools Jammu & Kashmir and Ladakh (separate from November 2019).
  - DNH_DD pools Dadra & Nagar Haveli and Daman & Diu (merged January 2020).
- District names are free text, but they are needed only to count reporting districts within a state, not to link boundaries. No district crosswalk is built.
- **National-total gate:** the sum of the 34 units against the "All India Across States" file, where one exists, within 1%.

### 3.6 Reporting completeness: missing is not zero

**District-month flags**, per indicator:
- `nonreport`: a zero increment where the district's median monthly value for that indicator in the same FY is ≥ 20;
- `negative`;
- `vintage_mixed`;
- `catchup`: a value more than 3× the district's FY median immediately after a `nonreport` month.

Flagged district-months are NaN.

**State-month completeness** `comp_<ind>` = the share of the state's districts in that FY with a valid, unflagged value. The district count per FY comes from the files themselves.

**Primary rule.** A state-month value enters models only if `comp_<ind>` ≥ 0.90. Otherwise it is NaN, not scaled up. *(Threshold: builder's/author's call; sensitivities at ≥ 0.75 and with no threshold.)*

**Plausibility.** A state-month above 3× or below 0.33× its unit's FY median (counts ≥ 20) goes to `hmis_reviewed.csv` with a disposition (keep / mask) and a reason.

**Small units** (LD, CH, PY, DNH_DD, AN, SK, GA) are kept. Their small counts are handled by the NB model, and a sensitivity excludes them.

A public HMIS "data uploading status" report would be a better completeness measure. If the builder finds one anonymously in the portal's Standard Reports, it replaces the inferred `nonreport` flag after a concordance check.

### 3.7 Denominators

- **Primary offset:** `log(population_it × days_in_month_t)`.
  - Population is the annual unit population in `data/derived/model/population_2001_2027.csv` (Census 2011 + RGI projections), linearly interpolated to mid-month.
  - Days in the month handles February and the 2016 leap year.
- **Sensitivity for ANC, immunisation and deliveries:** offset `log(expected births)`, with expected births = population × SRS state crude birth rate (annual, from public SRS bulletins, with a MANIFEST row). Expected pregnancies = 1.1 × expected births, used for ANC only.
  - Units without an SRS CBR use the nearest parent or neighbouring value, flagged.
  - *(Builder's call: drop this sensitivity if SRS parsing exceeds half a day.)*
- Coverage-style ratios (for example Penta3 per 1,000 expected births) are shown **descriptively only** in Table 2, as a plausibility check against NFHS-4/5 levels.

### 3.8 Provisional values

All HMIS values are provisional, as of each file's status date: for example, Kerala 2014-15 "as on 29 Jan 2016", Durg 2019-20 "25 Sep 2020", and the FY2020-21 files regenerated in October 2024.
- The panel stores `status_date` per cell.
- The manuscript states the range of status dates (a results key) and that later revisions are not reflected.

### 3.9 Climate and ENSO inputs (reuse)

- **ENSO:** `data/derived/enso_monthly.csv` (`oni_anom`, `roni`, `nino34_anom`, `dmi`; `month` is the centre month of each 3-month season) and `enso_episodes.csv`.
- **Local climate:** `data/derived/climate_state_month.csv` (IMD gridded, 36 GADM states, 1981–2025), aggregated to the 34 units area-weighted. Generalise `pipeline/climate_units.aggregate` to month keys, renormalising weights over non-NaN members.
- **Derived monthly variables:**
  - SPI-3, from `climate_annual.spi(…, scale = 3)` with the 1981–2010 base and the R22 masking rule;
  - Tmax anomaly against the 1981–2010 monthly normal;
  - `heatwave_days`, as already defined (Tmax ≥ 45 °C, or ≥ 40 °C with a departure ≥ 4.5 °C).
- A&N rainfall is masked (Phase 1 R19/R20), so A&N is excluded from rainfall terms only.

**Output tables**
- `data/derived/hmis/hmis_state_month.csv`: `unit_id, fy, year, month, ym, era`, then per indicator the value, `comp_`, `n_districts` and `flag_`, then `status_date_min/max`.
- `data/derived/model/hmis_model.csv`: the above joined to exposures, climate, indicators and offsets.

Lags are built by merging on `ym − k`, never by `shift()` (`model_inputs.py` convention).

## 4. Exposure

**Primary exposure (pre-specified).** The traditional ONI for the 3-month season **ending in month t**, that is the season centred on month t − 1. For August, this is JJA. It uses no future sea-surface temperature, and it is the most recent value that could describe conditions during the service month.

It is split by phase, as in Amendment A1:
- `en_t = pmax(ONI, 0)`, the El Niño term (the H7 and H8 coefficient), per +1 °C;
- `ln_t = pmin(ONI, 0)`, the La Niña term.

**Exposure in the primary window** (April 2012 to February 2020; 95 modelled months):
- 34 months with ONI ≥ 0.5: episode 2014–16 (20 months), 2018–19 (10) and the weak 2019–20 episode (4, November 2019 to February 2020);
- 6 months with ONI ≤ −0.5 (La Niña 2017–18; 5 La Niña-phase months);
- SD of ONI 0.75 °C; maximum +2.59 °C.

The La Niña term is weakly identified and is reported as such. The 2019–20 weak episode is in the data through the continuous exposure. For validation it is merged with 2018–19 into one fold (§5.6).

**Lags.**
- Primary: lag 0 as defined above.
- Secondary: a distributed lag over k = 0–6 months, a natural-spline lag basis with 3 df (`dlnm`, or splines coded by hand). It captures the pre-monsoon heat that follows an El Niño peak (for example April–June 2016) and the monsoon-season drought. Exploratory, with no verdict.

**Comparators** (secondary aim, Amendment A1 item 1):
- RONI (CPC's official index since February 2026);
- the Niño-3.4 anomaly, as a 3-month running mean aligned to the same season, so all three indices share the same smoothing.

Each index is refit with everything else identical. Effects are reported per +1 °C and per 1 SD over the 95 study months (SDs: ONI 0.75, RONI 0.76, Niño-3.4 0.82, the last before smoothing). Skill is compared by LOEO and rolling-origin MALE and log score, and AIC. No index is claimed to be superior.

**IOD.** The monthly DMI for the season ending in month t, and its interaction with `en_t`. Secondary, with no verdict. The four ENSO-phase × IOD-sign combinations are tabulated with their month counts.

**Local climate (pathway, H9).**
- Primary terms:
  - `spi3_dry = pmin(SPI-3, 0)`;
  - `spi3_wet = pmax(SPI-3, 0)`;
  - `heatwave_days`.
- Timing: concurrent month (lag 0). A 0–2 month lag is secondary.
- Sensitivity: the Tmax anomaly replaces heatwave days. The two are not entered together.

**Pre-specified state rainfall sensitivity `S_i`.** The percentage of JJAS rain lost per +1 °C ONI, 1981–2009, taken from Paper D (`papers/D/output/risk_index.csv`, column `hazard_rain`) and standardised across units. It is computed from years before the study window, so it is external to the HMIS data. A&N has no value and is excluded from this model.

## 5. Models (R, `models/E/`, reusing `models/common/R/`)

All models are negative-binomial (NB2) GLMMs in `glmmTMB`, built through `nb_spec`/`fit_nb`, with the fallback chain and `complete_rows`.

**Monthly extensions to `models/common`** (tested with `testthat`):
- a `ym` time index;
- a trend term in months;
- calendar-month fixed effects;
- month-keyed `loeo_splits`/`rolling_splits` (test blocks of `ym`);
- the lag-outcome leakage buffer (ruling P6) generalised to lag 12;
- `mediate()` accepting fixed effects other than `ns(year)`.

Annual behaviour must be unchanged: the Paper A, C and D tests must still pass.

### 5.1 Programme-change indicators (all models unless noted)

| Indicator | Months | Applies to |
|---|---|---|
| `hmis_format2017` | step from April 2017 | all outcomes |
| `demonet` | pulse, November 2016 to January 2017 | all |
| `mi_round` | Mission Indradhanush and Intensified MI campaign months: launched December 2014; rounds from April 2015; IMI October 2017 to January 2018; Gram Swaraj and Extended Gram Swaraj Abhiyan 2018; IMI 2.0 December 2019 to March 2020. **Exact months to verify from PIB/MoHFW** and record in `pipeline/reference/hmis_programme_events.csv` with sources | immunisation outcomes |
| `covid_mar2020` | March 2020 (lockdown from 25 March) | all; equivalent to excluding the month |
| `covid_fy2021` | FY2020-21 months | FY2020-21 sensitivity only |

PMSMA (from June 2016; ANC), LaQshya (from December 2017; deliveries) and a Diwali-month indicator (October or November) are sensitivity additions only.

IMI 2.0 overlaps the weak 2019–20 El Niño, and MI round 1 overlaps the 2015 developing phase. This confounding is stated in the paper and is the main reason for Model S (§5.3).

### 5.2 Model T: total association (H7, H8)

`y_it ~ en_t + ln_t + factor(month_of_year) + t_months + programme indicators + offset(log(pop_it × days_t)) + (1 + t_months | unit) + (1 | ym)`

- **Why the `(1 | ym)` crossed random effect.** ENSO varies only over time. Without a time-level error term, 34 units would be treated as 34 independent replicates of each month, and the SEs would be far too small. The `ym` effect makes the effective sample about the number of months. Upgrade to `ar1(ym + 0 | national)` if it converges; fall back to iid `(1 | ym)`; final fallback, a moving-block bootstrap over months (block = 12, B = 1,000). The contract records which was used.
- **Trend.** No spline in time over 8 years, because a flexible national trend would absorb the 2014–16 episode. A state-specific linear trend (random slope) captures programme expansion. A sensitivity uses `ns(t, df = 2)`.
- **Seasonality.** Common month-of-year fixed effects. Sensitivity: unit × first-harmonic (sin/cos) interactions.
- **Episode check** (part of the verdict). Refit with `en_t × episode` (2014–16 vs 2018–20) to get each episode's IRR.

### 5.3 Model S: differential association (robustness to national shocks; no verdict)

`y_it ~ en_t:S_i + ln_t:S_i + factor(ym) + (1 + t_months | unit) + offset(...)`

- Year-month fixed effects absorb every national shock: demonetisation, MI rounds, format changes and El Niño's own common effect.
- The coefficient asks whether services fall more during El Niño in states whose monsoon rain is historically more ENSO-sensitive.
- It uses a pre-specified, external sensitivity measure. It is not an estimated health slope, so it does not break the anti-goal.

**Reading rule** (fixed in the contract):
- If H7 is "consistent with" but Model S is null or in the opposite direction, the Discussion must say the total association may reflect coincident national events.
- If both agree in direction, the Discussion may say the association is "not explained by national shocks".

### 5.4 Model L: local-climate association (H9) and mediated share

`y_it ~ spi3_dry_it + spi3_wet_it + heatwave_days_it + factor(ym) + (1 + t_months | unit) + offset(...)`

This compares states within the same calendar month, which gives the strongest identification available in this design.

**Mediated share of the total.**
- Product of coefficients, as in Papers A and C: an a-path (`en_t` → each local-climate variable, Gaussian, with month-of-year fixed effects and a unit random effect) and a b-path (Model T plus the three local-climate terms).
- Cluster bootstrap by unit, B = 1,000 (`mediate()`).
- Reported only when the total association's 95% CI excludes 1. Otherwise it is "not estimated (no total association)".

### 5.5 Estimand hierarchy, heterogeneity and inference

Estimands are reported in this order and never merged:
1. **Total** (Model T; H7, H8).
2. **Differential** (Model S).
3. **Local-climate associations** (Model L; H9) and the **local-climate-mediated share** of the total.
4. **Predictive value** (Models A/B/C, §5.6).

**State heterogeneity.**
- A secondary Model T with an `en_t` random slope, tested by LRT against the primary model.
- State-specific statements are permitted only if (i) the LRT p < 0.05, (ii) the slope SD is not at the boundary (the Hessian is positive definite and the SD's lower CI is > 0.01), and (iii) the result holds when either episode is dropped.
- Even then, the paper shows conditional modes as a figure with intervals, never as a ranking. If the rule fails, the paper says state differences are not identifiable.

**IRR CIs** are Wald, from the chosen covariance structure. Bootstrap CIs are used only where stated.

### 5.6 Hypotheses and verdict rules (fixed in `papers/E/results_keys.md` before any model runs)

Programme numbering continues from Paper B (H4–H6).

**H7 (services, primary).** During the El Niño phase, the use of essential services is lower.
- Family: `anc_reg`, `penta3`, `inst_del`, `opd`.
- Per outcome, `consistent with` if and only if:
  - (i) the Model T IRR per +1 °C for `en_t` is < 1, with a Holm-adjusted p < 0.05 across the 4 outcomes; **and**
  - (ii) both episode-specific IRRs are < 1 (point estimates).
- Otherwise `not consistent with`.
- The overall `E.h7.verdict` is `consistent with` if at least one outcome is consistent, and its text names the outcomes.

**H8 (diarrhoea, primary for the disease outcome).** Reported diarrhoea in under-5s is higher during the El Niño phase.
- `consistent with` if and only if the Model T IRR is > 1 with p < 0.05 (a single test) **and** both episode IRRs are > 1.
- A reduction is reported and discussed (it could reflect lost access), but it does not satisfy H8.

**H9 (local-climate pathway).** Within the same calendar month, services are lower in state-months with more heatwave days or with rainfall deficit (SPI-3 below 0).
- Tests: `heatwave_days` and `spi3_dry` × the four service outcomes, giving 8 tests, Holm-adjusted together.
- For heatwave days, a decrease means IRR < 1. For `spi3_dry`, whose values are ≤ 0, "lower services with deficit" means a coefficient > 0.
- Per outcome, `consistent with` if either term is significant in the hypothesised direction after Holm adjustment. The overall verdict follows the H7 pattern.
- `spi3_wet` (flood or excess rain) and diarrhoea under Model L are reported without a verdict.

**Secondary outcomes** (`mcv1`, `fic`) and every sensitivity analysis carry no verdict.

**Fixed vocabulary:** `consistent with` / `not consistent with`. A failed fit gives `not estimable (<reason>)` and counts as not consistent.

### 5.7 Forecast comparison (secondary; descriptive rule, no verdict)

**Models**, all scored out of sample on the same folds:
- **Model A:** unit random effects + month-of-year + trend + programme indicators + `log1p(y_{t−12})`;
- **Model B:** A + the local-climate terms;
- **Model C:** B + `en_t`, `ln_t` (+ DMI).

**LOEO folds**, monthly blocks covering each episode plus a 6-month lag tail:
- F1: October 2014 to December 2016;
- F2: September 2018 to February 2020 (2018–19 and 2019–20 merged, because they are adjacent).

**Rolling origin:** train on FYs ≤ t − 1 and predict FY t, for t = 2015-16 to 2019-20 (5 origins).

**Metrics:** MALE, RMSE on log1p, NB log score, and 95% prediction-interval coverage (`oos_metrics`, `compare_models`).

**Rule.** Model C "adds skill over local climate" only if its MALE is lower than Model B's in both LOEO folds and in at least 4 of 5 rolling origins. Otherwise the conclusion is "no added skill demonstrated". With 2 folds this is low-powered, and the text says so.

### 5.8 Power, stated honestly

The total association rests on about 34 El Niño months in essentially **two independent episodes**. Any national event in those months is a candidate confounder.

**Pre-specified simulation**, run after the contract commit and before Model T is read:
1. Fit Model T without the ENSO terms.
2. Simulate 500 datasets from it with the IRR for `en_t` injected at 0.90, 0.95, 0.97 and 0.99 per +1 °C.
3. Refit and report power at α = 0.05. The minimum detectable effect is the smallest IRR with ≥ 80% power.

Report the MDE per outcome (key `E.power.<ind>.mde`). Every null in the Discussion is read against it ("effects larger than X% per +1 °C are unlikely; smaller effects cannot be excluded").

Model S and Model L draw on cross-state variation in every month and are expected to be much better powered. That is why H9 exists.

### 5.9 Sensitivity analyses (no verdicts)

1. FY2020-21 included, with `covid_fy2021` and the La Niña 2020–21 months.
2. Completeness threshold at 0.75, and no threshold.
3. Expected-births offset (§3.7).
4. Excluding small units.
5. Era-specific unit intercepts, in place of the single format step.
6. `ns(t, 2)` trend; harmonic seasonality.
7. PMSMA, LaQshya and Diwali indicators added.
8. RONI and Niño-3.4 (also the A1 comparison).
9. Distributed lag 0–6.
10. Dropping each episode in turn.

## 6. Results contract, traceability, outputs

- **Contract first.** `papers/E/results_keys.md` is committed **before** any model in §5 runs. It follows Paper C's format: conventions table, `fmt_*` displays, a key table with meaning, unit, producer, display and target sections, the verdict rules verbatim, and fixed templates for verdict sentences.
  - Later additions are dated amendments, committed before the producing step runs, and add no verdicts.
  - A disclosure paragraph states what was known when the contract was written (the panel, the completeness tables and the power simulation design; no ENSO estimates).
- **Keys** use the namespace `E.`, for example `E.panel.n_state_months`, `E.comp.<ind>.median`, `E.status_date.range`, `E.t.<ind>.irr_en`, `E.t.<ind>.irr_en.ep1415`, `E.h7.<ind>.verdict`, `E.s.<ind>.irr`, `E.l.<ind>.hw.irr`, `E.med.<ind>.prop`, `E.fc.<ind>.male_diff_c_b`, `E.idx.<ind>.<index>.{std_effect,se,male,log_score}` and `E.power.<ind>.mde`.
- **Writing results.** `models/E/*_results.R` writes `papers/E/results.json` via `res_entry()`/`write_results()`. `tools/build_manuscript.py` fails on a missing key or a null display. `papers/E/check_results_keys.py` cross-checks the manuscript against the contract.
- **Traceability.**
  - `papers/E/sources.md` gives every source with URL, retrieval date, SHA-256 (from MANIFEST) and licence.
  - Reviewed dispositions are in `hmis_reviewed.csv`.
  - Programme events and their sources are in `hmis_programme_events.csv`.
  - The crosswalk names the file each item was verified in.
  - Gate results are appended to `data/derived/validation_report.md`.
- **Figures.**
  1. National monthly series of the five primary indicators, April 2012 to March 2021, with El Niño months shaded, the April 2017 format line and FY2020-21 greyed.
  2. Heatmap of reporting completeness, unit × month.
  3. Forest plot of IRR per +1 °C El Niño-phase ONI by outcome: total (Model T, both episodes marked), differential (Model S) and local climate (Model L).
  4. Distributed-lag curves, 0–6 months.
  5. Forecast skill: MALE differences, C − B and B − A, by fold and origin.
- **Tables.**
  1. Indicator crosswalk and harmonised definitions.
  2. Panel description: state-months, completeness, monthly counts, coverage ratios.
  3. Primary estimates and verdicts (H7–H9).
  4. Forecast comparison and index comparison.
- **Supplement:** all sensitivity analyses; the IOD and phase tables; the state frame; full crosswalk with item texts; gate report; MDE simulation; state heterogeneity (only if the §5.5 rule passes); RECORD checklist.
- **Release** (author's go-ahead only): public repository `hssling/elnino-hmis-services-india` holding code and the derived state-month panel, with GODL-India attribution and a Zenodo DOI. Use the exporter pattern of `tools/export_release_d.py`, with a history-collapsed single commit and a blob scan. Raw HMIS files are not redistributed; the README gives download scripts and URLs.

## 7. Reporting, journal, limitations, risks, timeline

**Reporting:**
- RECORD, the routinely-collected-data extension of STROBE, with the checklist in the supplement;
- STROBE items adapted for an ecological time-series design, stated as such;
- ethics: the programme's "Not applicable" wording for secondary analysis of aggregated public data;
- AI-use disclosure, as in Papers A–D.

**Candidate journals** (all **to verify** on the journal's own site at submission). Excluded:
- journals where a programme paper is under review [journal-selection or submission note redacted from the public copy; not part of the analysis protocol];
- [journal-selection or submission note redacted from the public copy; not part of the analysis protocol]
- [journal-selection or submission note redacted from the public copy; not part of the analysis protocol]

| # | Journal | Fee basis (to verify) | Fit |
|---|---|---|---|
| 1 | [journal-selection or submission note redacted from the public copy; not part of the analysis protocol] | | |
| 2 | [journal-selection or submission note redacted from the public copy; not part of the analysis protocol] | | |
| 3 | [journal-selection or submission note redacted from the public copy; not part of the analysis protocol] | | |
| 4 | [journal-selection or submission note redacted from the public copy; not part of the analysis protocol] | | |

[journal-selection or submission note redacted from the public copy; not part of the analysis protocol]

**Limitations to state:**
- Two El Niño episodes, and MDE-bounded nulls.
- Temporal confounding by national programmes. Model S mitigates this, but its own assumption is that sensitivity and programme timing are unrelated.
- HMIS is provisional, public-sector-dominated and subject to reporting artefacts. The completeness rule is inferred, not observed.
- The 2017-18 item break.
- Facility-reported diarrhoea mixes incidence and care-seeking.
- No 2023–24 data.
- State aggregation hides within-state contrasts.
- Population denominators are interpolated projections.

| Risk | Mitigation |
|---|---|
| Portal paths change, or a challenge appears | Cache with SHA-256; stop on any challenge, never bypass; data.gov.in legacy fallback for specific gaps; report the gap |
| Cumulative differencing creates artefacts | Negative, non-report and catch-up flags; vintage check; month files preferred where present |
| Item text or codes differ from the spike samples (FY2012-13, FY2017-18 unseen) | Inspect those years first; text-regex gate; new era parser if needed |
| Pentavalent rollout or MR switch distort the immunisation series | DPT3 + Penta3 and MR + measles sums; the March→April 2017 ratio report |
| National shocks coincide with El Niño (MI round 1, IMI 2.0) | `mi_round` indicators; Model S with year-month fixed effects; reading rule |
| Under-stated SEs from a national exposure | `(1 | ym)` / AR(1) time effect; block bootstrap fallback |
| Model non-convergence with crossed effects | `fit_nb` fallback chain; recorded in the contract keys |
| FY2020-21 too costly to acquire | Budget rule (§3.1); drop with a statement |
| Disk space | Stream from zips; derived CSVs only |

**Timeline** (from 26 October 2026; [journal-selection or submission note redacted from the public copy; not part of the analysis protocol]; the ASO 2026 refreshes in early November take priority):

| Week | Work |
|---|---|
| 1 | Acquisition, era parsers with fixtures, crosswalk verification on FY2012-13 and FY2017-18 |
| 2 | Differencing, completeness, aggregation and gates; panel; monthly climate; `models/common` extensions with tests |
| 3 | Contract commit, then power simulation and models; reviews |
| 4 | Manuscript, figures, supplement; journal check; package; final review |

Target: ready to submit in early December 2026.

## 8. Integration with Paper D (note only)

Paper E writes `E.idx.<outcome>.<index>.{std_effect, se, male, log_score}` in the shape of Paper D's harvest (`papers/D/output/index_effects_harvest.csv`): the El Niño-phase term per 1 SD over E's own study months, at lag 0.

A later Paper D update could add E's count outcomes to the pooled ONI/RONI/Niño-3.4 comparison, raising k above 3. Because E is monthly and A/C are annual, such an update should pool E in a separate stratum or as a sensitivity analysis, and its own dated contract amendment must say so. Paper E itself makes no pooled claim.

## 9. Left to the builder; open questions

**Builder's/author's calls** (decided here; may be refined with a note in the plan):
- the completeness threshold (0.90) and the non-report rule (median ≥ 20);
- AR(1) vs iid time effect, and the block length;
- harmonic seasonality details;
- DPT3 item codes before pentavalent;
- exact MI/IMI months (with sources);
- whether SRS CBR parsing is worth it;
- the DLM basis;
- the Niño-3.4 smoothing;
- whether a public uploading-status report exists;
- the fixture cuts;
- the plan's task split (the expected plan: acquisition → parsing and crosswalk → panel and gates → monthly model core → contract → analyses → manuscript → package and release).

**Open questions for the author** (defaults apply if unanswered):
1. **FY2020-21 acquisition**, if only per-district monthly files exist (about 8,400 small requests, about 5–6 hours at a polite rate). Default: proceed within the 10,000-request budget.
2. **Journal order.** [journal-selection or submission note redacted from the public copy; not part of the analysis protocol]
3. **Public release** of code and the derived state-month panel (GitHub + Zenodo) as for A–D. Default: yes, only on your go-ahead.
4. **Submission timing.** [journal-selection or submission note redacted from the public copy; not part of the analysis protocol] Related manuscripts are disclosed as in Paper D.

## 10. Builder-check resolutions (2026-10-24, coordinator's calls; the author may override)

1. **State-month value.** Primary: difference the file's own `_State` cumulative column (option c). The district flags (§3.6) act only as a completeness filter: a state-month is kept if at least 90% of its districts are valid in that month, otherwise it is missing. Sensitivity: the sum of unflagged districts, scaled up by the share of districts reporting (valid districts / all districts listed for the state-year). The 2% gate compares the differenced `_State` value with the unscaled district sum on months with 100% valid districts. Headline completeness is the share of district-months valid.
2. **Reviewed dispositions without the author.** Defaults, each logged in `hmis_reviewed.csv` with the rule applied:
   - A cell that fails a gate (negative increment beyond 1%, district-sum mismatch beyond 2%, more than 3× the state's median for that calendar month, national-total mismatch beyond 1%) is masked to missing, never replaced.
   - An indicator with more than 20% of state-months masked is dropped from the primary analysis and reported descriptively.
   - The build halts and reports to the author only if two or more of the five indicators are dropped, or a fiscal year is wholly unusable (see 6).
3. **Tests.** All p-values are two-sided Wald p-values. A verdict also needs the pre-specified direction. Holm adjustment applies across all the H7–H9 tests together.
4. **Mediation bootstrap.** Moving-block bootstrap over months (block length 12, the whole panel resampled by month blocks, models refitted), with B = 500. If the projected compute time exceeds 24 hours, B is reduced to 200 and the reduction is reported. The cluster bootstrap by unit is a sensitivity only.
5. **Power simulation.** It runs after the contract is committed. It is descriptive (minimum detectable effect, no verdict). A Model T without ENSO terms may be fitted for it once the contract is committed. Budget: 200 simulations × 4 effect sizes × the analysed outcomes, using the iid `(1 | ym)` structure, run in parallel, with a wall-clock target of 8 hours or less.
6. **Portal gaps.** For any gap, including a whole year, fall back to data.gov.in per-district CSVs under the same polite caps. If neither source gives a usable state-year, mask it and report. If more than one fiscal year of the primary window is unusable, stop and report to the author.
7. **Model S units.** The two units without `S_i` are A&N and Lakshadweep (`NA by rule` in Paper D). Model S runs on 32 units, and the contract states n = 32 and the exclusion rule.

## 11. Author decisions (2026-10-24)

- Design approved; proceed to the implementation plan (subagent-driven execution).
- Journal order: [journal-selection or submission note redacted from the public copy; not part of the analysis protocol]
- FY2020-21: include as the COVID-flagged sensitivity, within the 10,000-request cap. Drop it, with a statement, if it needs more requests or if any site check appears.
- Public release of the code and the state-month panel (GitHub + Zenodo), as for A–D, only after the author's explicit go-ahead.

## 12. Data-format correction after parsing the real files (2026-10-25, coordinator's calls; the author may override)

Parsing the cached portal zips (Task 2) showed that the feasibility spike's file shapes (§3.2, §3.3) do not describe the files actually acquired. The analytical intent of §3.5, §3.6 and §10.1 is unchanged: an official state aggregate per month, kept only when at least 90% of the state's districts report validly. Only the mechanics change.

1. **The files are monthly, not cumulative.** Each FY2012-13 to 2019-20 zip holds one workbook per state plus `All_India.xls`. The `.xls` members are SAS HTML exports with rows = items and columns = the 12 months April–March plus an FY total. No "upto" files exist, so the differencing of §3.3 and the `negative`-increment and `vintage_mixed`-across-months logic do not arise. FY2020-21 (folder 2) is also monthly.
2. **Primary state value** (replaces "difference the `_State` column"): the state's own row in that FY's `All_India.xls` for that month. For FY2020-21 it is the first (state-aggregate) column group of the state-month file. The 90% completeness filter, the 2% district-sum gate (now: the `All_India` state row versus the unscaled sum of district values, on months with 100% valid districts) and the scaled district-sum sensitivity apply as in §10.1.
3. **District flags** (§3.6) are computed on the monthly district values in the state workbooks: `negative` (a negative monthly value), `nonreport`, `catchup`, and `nofile` (a district listed in the state-FY but with no value in that month). `vintage_mixed` is redefined as a state-FY whose state workbook and `All_India.xls` carry different status dates; it is reported, not masked.
4. **Internal check** (replaces the §3.3 month-file versus cumulative check): for every unit and item, the 12 monthly values must sum to the file's FY-total column within 1%; failures go to `hmis_reviewed.csv`.
5. **Non-state members.** "M O Defence" and "M O Railways" members are central-ministry reports, not states; they are excluded by name and the exclusion is reported. "Andhra Pradesh Old" maps to the AP_TG unit.
6. **Sum indicators** (`penta3`, `mcv1`, `fic`, `inst_del`, `opd`) keep `min_count=1`. The share of state-months where a component is missing while it was non-zero elsewhere in the same FY is reported per indicator; above 5%, those state-months are masked.
7. The folder-4 FY2019-20 sub-district zip (Deflate64) is not used; there is no month-file precedence question.
