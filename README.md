# El Niño and essential health services in India: HMIS state-month panel, code, results contract and aggregate data

Code, every reported number and the aggregate data of a pre-specified state-month analysis of El Niño and the continuity of essential maternal, child and outpatient services in India, from routine Health Management Information System (HMIS) reports, April 2012 to February 2020 (34 state-level units). The analysis relates antenatal care registration, third doses of a DPT-containing vaccine, institutional deliveries, outpatient attendance and reported childhood diarrhoea to the El Niño phase of the traditional Oceanic Niño Index (Model T, with a time random effect), to the interaction of El Niño with each state's monsoon sensitivity (Model S, year-month fixed effects) and to local heatwave days and rainfall deficit (Model L, year-month fixed effects); it reports pre-specified minimum detectable effects, mediation by local climate, state heterogeneity, distributed lags, the Indian Ocean Dipole, an ENSO-index comparison (traditional ONI, RONI, Niño-3.4) and an out-of-sample forecast comparison.

Repository: https://github.com/hssling/elnino-hmis-services-india

**Paper (manuscript; the citation will be added on publication):**
Siddalingaiah H S. El Niño and the continuity of essential maternal, child and outpatient services in India: a state-month analysis of routine health information system data, 2012–2020.

Please cite the paper once it is published, and this repository through `CITATION.cff`.

**Companion analyses** (their code and aggregate data are public; the analyses themselves are manuscripts under review):
- El Niño and malaria across Indian states, 2002–2025: https://github.com/hssling/elnino-malaria-india, https://doi.org/10.5281/zenodo.23424043
- El Niño, local climate and child health in India (NFHS-4 and NFHS-5): https://github.com/hssling/elnino-child-india, https://doi.org/10.5281/zenodo.23599461
- El Niño, heat extremes, drought and mortality in India, 2001–2024: https://github.com/hssling/elnino-heat-india, https://doi.org/10.5281/zenodo.23556278
- El Niño Health Vulnerability Atlas of India (synthesis; its state monsoon-sensitivity table is an input here): https://github.com/hssling/elnino-health-atlas-india, https://doi.org/10.5281/zenodo.23632647

## Pre-specified analysis

A results contract (`papers/E/results_keys.md`) listing every reported quantity with its definition, source, display and the verdict rules for hypotheses H7–H9 was committed before any model containing an ENSO or local-climate term was fitted to an HMIS outcome. Its disclosure paragraph records what was known at that time (the data format, the panel and its completeness and gate tables, the April 2017 format-break ratios, the power-simulation design); no association between ENSO or local climate and any HMIS outcome had been computed. Later changes are dated amendments in the same file; the third amendment, made after the Model T estimates were known, raised the optimiser's iteration limits only and is disclosed as such. The study was not registered in an external registry. The design specification is included (the implementation plan, an internal working document, is not):

- `docs/superpowers/specs/2026-10-24-paper-e-hmis-services-design.md`: design specification (its sections 10–12 override its body text).
- `papers/E/results_keys.md`: the results contract and its amendments (674 keys).

Timeline, from the history of the author's working repository (first commit of each file; times are IST, UTC+05:30):

| Step | File | First commit (IST) |
|---|---|---|
| Design specification | `docs/superpowers/specs/2026-10-24-paper-e-hmis-services-design.md` | 2026-10-24 18:38 (`7fdeee6`) |
| Results contract (`papers/E/results_keys.md`) | `papers/E/results_keys.md` | 2026-10-25 03:49 (`a8b653b`) |
| State-month panel (`data/derived/hmis/hmis_state_month.csv`) | `data/derived/hmis/hmis_state_month.csv` | 2026-10-25 02:22 (`95d00c0`) |
| Power simulation design (`models/E/01_power.R`) | `models/E/01_power.R` | 2026-10-25 05:11 (`6984b56`) |
| First exposure model (`models/E/02_primary.R`) | `models/E/02_primary.R` | 2026-10-25 07:35 (`ddaf688`) |
| First results file (`papers/E/results.json`) | `papers/E/results.json` | 2026-10-26 01:33 (`a82d04e`) |

**Differences from the author's working copies.** The copies here differ from the committed originals only in these ways:
- local drive paths are replaced by repository-relative ones (`<repo>`);
- e-mail addresses are removed from documents;
- the names of the version-control tags that pin the companion analyses' inputs are shortened to `paperA-submitted`, `paperB-submitted`, `paperC-submitted`, `paperC-submitted-2`, `paperD-submitted` and `paperD-ready` in every file (the original names also carried the name of the journal each companion analysis was submitted to);
- notes about journal selection and submission timing in the design specification are replaced by the marked text "[journal-selection or submission note redacted from the public copy; not part of the analysis protocol]";
- `data/MANIFEST.csv` holds only the rows of the HMIS acquisition (the working copy also lists the inputs of the companion analyses);
- No FY2020-21 (April 2020 to March 2021) HMIS value is included: those months come from the HMIS portal's FY2020-21 files, which state no explicit licence, so their rows were **removed** from every released table (removed from: `data/derived/hmis/differencing_report.csv` (7 rows); `data/derived/hmis/gate_summary.csv` (7 rows); `data/derived/hmis/hmis_model.csv` (408 rows); `data/derived/hmis/hmis_state_month.csv` (408 rows); `papers/E/figures/data/figure_1.csv` (12 rows); `papers/E/figures/data/figure_2.csv` (408 rows); `pipeline/reference/hmis_reviewed.csv` (114 rows)). They are used in the paper only in a sensitivity analysis; its estimates (model results, not HMIS values) are in `papers/E/output/sensitivity.csv` and `papers/E/results.json`. The portal's FY2020-21 file list (`pipeline/reference/hmis_sources.csv`, `data/MANIFEST.csv`, `data/derived/hmis/acquisition_report.md`: names, URLs, sizes and hashes) is kept so that users can rebuild those rows from the portal with `python -I pipeline/hmis/run.py fetch` and the panel steps.

The analyses, decision rules, amendments, data and results are otherwise verbatim. Internal decision identifiers (for example "ruling", "F61" or "Task 8") refer to the author's analysis log; the decisions that affect the analysis are described in the documents themselves.

## Contents

```
./                                 11 files
data/                              MANIFEST.csv
data/derived/                      climate_state_month.csv, enso_monthly.csv, qc_month_adjustments.csv
                                   # ENSO indices and the state-month climate table
data/derived/hmis/                 8 files
                                   # state-month panel, model table, climate by unit-month, gate and break reports
data/derived/model/                population_2001_2027.csv
                                   # population projections by unit
docs/superpowers/specs/            2026-10-24-paper-e-hmis-services-design.md
                                   # design specification, 2026-10-24
models/                            .Rprofile, DESCRIPTION, renv.lock, setup.R
                                   # renv lock file and setup, R 4.5.3
models/D/R/                        contract.R
                                   # the companion synthesis's contract reader, sourced by models/E
models/E/                          8 files
                                   # R analysis: run_all.R and steps 01-06
models/E/R/                        8 files
                                   # helpers: monthly fitters, power, verdicts, mediation, secondary, forecast, results
models/common/R/                   8 files
                                   # shared R functions (frozen since the companion analyses)
models/common/tests/               run.R
models/common/tests/testthat/      9 files
                                   # testthat suite (Paper E tests and helpers)
models/renv/                       .gitignore, activate.R, settings.json
papers/D/output/                   risk_index.csv
                                   # the companion synthesis's state monsoon-sensitivity table (CC BY 4.0)
papers/E/                          .gitignore, check_results_keys.py, results.json, results_keys.md, traceability.csv
                                   # results.json, results contract, traceability table, key check
papers/E/figures/                  make_figures.py
papers/E/figures/data/             6 files
                                   # figure data
papers/E/output/                   11 files
                                   # aggregate outputs of models/E
papers/E/tables/                   make_tables.py, table1_crosswalk.md, table2_panel.md
                                   # descriptive tables and their data
papers/E/tables/data/              table2.csv
pipeline/                          14 files
                                   # shared climate, ENSO and validation modules imported by pipeline/hmis
pipeline/hmis/                     13 files
                                   # HMIS download, parsing, crosswalk, flags, panel and gates, model table, sources
pipeline/outcomes/                 __init__.py, fetch.py, gates.py, states.py
                                   # state frame and shared gate helpers
pipeline/reference/                hmis_item_crosswalk.csv, hmis_programme_events.csv, hmis_reviewed.csv, hmis_sources.csv, state_frame.csv
                                   # HMIS item crosswalk, programme events, reviewed dispositions, portal file list, state frame
tests/                             __init__.py
tests/hmis/                        14 files
                                   # pytest suite for pipeline/hmis, synthetic fixtures only
tests/hmis/fixtures/               8 files
                                   # synthetic HMIS workbooks in the three portal formats (no real values)
tools/                             __init__.py, build_manuscript.py
```

No manuscript text is included.

## Data

**HMIS attribution (verbatim, as the licence requires):** Health Management Information System (HMIS), Ministry of Health and Family Welfare, Government of India; via data.gov.in / hmis.mohfw.gov.in; Government Open Data License – India

The raw HMIS workbooks (Standard Reports, "C2. Data Itemwise Monthly (up to sub district)", financial years 2012-13 to 2019-20, with FY2020-21 as a sensitivity extension) are **not redistributed**. They are public on the HMIS portal, https://hmis.mohfw.gov.in/ (Standard Reports); `python -I pipeline/hmis/run.py fetch` downloads them at a polite rate into `data/raw/hmis/` and records each file's URL, retrieval date and SHA-256 in `data/MANIFEST.csv` (`pipeline/reference/hmis_sources.csv` lists the portal files). The derived tables are included:

- `data/derived/hmis/hmis_state_month.csv`: the state-month panel, 34 units × months, seven harmonised indicators (official monthly state rows, district-completeness shares, gate flags); **no district-level values**. Missing is an empty cell, never 0.
- `data/derived/hmis/hmis_model.csv`: the model table (panel plus ENSO exposures, local climate, offsets, programme indicators, lags).
- `data/derived/hmis/climate_unit_month.csv`: IMD gridded rainfall and maximum temperature aggregated to units by month (SPI-3, heatwave days, Tmax anomaly).
- `data/derived/hmis/gate_summary.csv`, `break_ratio_2017.csv`, `differencing_report.csv`, `acquisition_report.md`, `fy2021_status.json`: completeness, gate and format-break reports and the acquisition record.
- `pipeline/reference/hmis_item_crosswalk.csv`, `hmis_programme_events.csv`, `hmis_reviewed.csv`: the indicator crosswalk across the April 2017 format change, the programme-event months (several marked provisional) and the reviewed gate dispositions.
- `data/derived/enso_monthly.csv`, `data/derived/climate_state_month.csv`, `data/derived/qc_month_adjustments.csv`, `data/derived/model/population_2001_2027.csv`, `papers/D/output/risk_index.csv`: the ENSO, climate (with its infilled or masked rain months), population and monsoon-sensitivity inputs of the model table.
- `data/MANIFEST.csv`: the HMIS rows of the acquisition manifest (path, public URL, retrieval time, SHA-256, size; no values).

## Results

All tables are UTF-8 CSV; missing is an empty cell (NaN), never 0.

- `papers/E/results.json`: every number reported in the paper, as `{"<key>": {"value", "display", "script", "description"}}` (674 keys); `papers/E/traceability.csv` lists them with the script that wrote each; `python papers/E/check_results_keys.py` cross-checks the keys against the contract.
- `papers/E/output/`: primary estimates (Models T, S, L with episode terms, Holm-adjusted P values and verdicts), mediation, sensitivity analyses, distributed lags, Indian Ocean Dipole, heterogeneity and state slope modes, forecast skill, index comparison, power (minimum detectable effects) and `provenance.csv` (code commit, input and output hashes, seed).
- `papers/E/figures/data/`: the data behind each figure; `papers/E/figures/make_figures.py` draws the figures (black-and-white readable). `papers/E/tables/`: two unnumbered working tables (the indicator crosswalk and a panel description with extra descriptive columns; the paper's own tables are built from `results.json`) and their data.

## Reproduction

This repository is a release copy: it has no history of the author's working repository and none of the model caches (`models/E/_cache/`, git-ignored), and it omits the FY2020-21 rows. The code therefore runs in **release mode**, switched on by the marker file `.elnino-hmis-release` at the root (or `E_RELEASE_MODE=1`; `E_RELEASE_MODE=0` switches it off). In release mode the checks that read the working repository's version-control history (the contract committed before the primary fits, the primary estimates committed after Amendment 3, the FY2020-21 status file committed, the git state recorded in `provenance.csv`) are skipped, each with a logged notice. Nothing else changes.

Requirements: Python 3.10 or later (tested with 3.14) with `pip install -r requirements.txt`; R 4.5.3 with the packages of `models/renv.lock` (`cd models`, then `Rscript setup.R` restores them with renv).

1. **Python tests.** `python -m pytest` (from the root) runs the tests of the HMIS pipeline on synthetic fixtures; network tests are deselected. It includes a rebuild of the model table: `tests/hmis/test_model_table.py::test_tracked_model_table_is_current` rebuilds `data/derived/hmis/hmis_model.csv` from the included panel, unit-month climate, ENSO, population and monsoon-sensitivity tables and checks that it equals the included file (FY2020-21 rows removed). Expected skips, each with its reason: the four tests of `tests/hmis/test_frozen_common.py` (they compare `models/common/R` with version-control tags of the author's working repository); `test_run_model_table_step_writes_to_given_paths` (it rebuilds `climate_unit_month.csv`, which needs the GADM 4.1 boundary file `data/external/gadm41_IND.gpkg`, not redistributable; download it from https://gadm.org to run it); and two parser tests that need the raw HMIS files (step 5).
2. **Key check.** `python papers/E/check_results_keys.py` checks that `papers/E/results.json` holds exactly the 674 keys of the contract, with no pending display.
3. **Results from the included outputs (no fitting, minutes).** `cd models`, then `Rscript E/run_all.R --use-cache`. Without the caches, each step is resolved from the included files: every output table in `papers/E/output/` must be byte-identical (SHA-256, line ends normalised) to the one recorded in `papers/E/output/provenance.csv`; the 36 power keys are recomputed from `power.csv`, the 64 panel, gate, status-date and exposure keys from `data/derived/` and the conclusion sentence from the verdict keys; the other step keys (Models T, S and L, mediation, secondary analyses, forecast), whose computation needs the fitted models, are read from the included `results.json`. The assembled `results.json` and `provenance.csv` are written to `models/E/logs/release_check/` (the included files are never overwritten) and compared with the included `results.json`: the run stops if any value or display differs. Expected log line (`models/E/logs/results.log`): all 674 values and displays identical, and one description different, `E.status_date.range`, whose description names the FY2020-21 status date, which is read from the FY2020-21 rows.
4. **Full refit (hours).** `Rscript E/run_all.R --refit` reruns every step (power simulation, primary models, mediation, secondary analyses, forecast comparison; several hours on 8 cores; checkpoints under `models/E/_cache/` and `models/E/logs/`) and writes `papers/E/results.json` and `papers/E/output/`. Without the FY2020-21 rows the FY2020-21 sensitivity analysis reads "not estimable (FY2020-21 rows not in the model table …)" instead of its published values (`papers/E/output/sensitivity.csv`, case `fy2021`); bootstrap and optimiser results may differ in the last digit across platforms and library versions.
5. **Panel from the portal files (optional).** `python -I pipeline/hmis/run.py fetch` downloads the raw HMIS workbooks into `data/raw/hmis/` and checks each file's SHA-256 against `data/MANIFEST.csv` (its HMIS rows are included); then the `parse` and `panel` steps rebuild `data/derived/hmis/hmis_state_month.csv` (see the docstring of `pipeline/hmis/run.py`), including the FY2020-21 rows. The `model-table` step also rebuilds `climate_unit_month.csv`, which needs the GADM 4.1 boundary file (step 1); `data/derived/climate_state_month.csv` itself is built from the IMD gridded daily rainfall and maximum-temperature files (not redistributed; see `DATA_LICENSE.md`).
6. **Figures.** `python papers/E/figures/make_figures.py` draws the figures from `papers/E/figures/data/`.
7. **R tests.** `cd models && Rscript -e "source('common/R/load.R'); testthat::test_dir('common/tests/testthat', filter = '^e-')"` runs the Paper E R tests (synthetic data; some fit small models and take several minutes).

## Data protection

No record-level or district-level data are included: the HMIS tables hold official state-month values and district-completeness shares only. Before this repository was assembled, every file was checked by the controlled-data guard that the analysis repository runs on every commit, and every blob of the release history was scanned for controlled data, district-level columns, e-mail addresses, local paths and journal or submission notes.

## Licences

- Code: MIT (`LICENSE`).
- Results, aggregate data, derived tables and figure data: CC BY 4.0 (`DATA_LICENSE.md`), subject to the third-party terms listed there; the HMIS-derived values remain subject to the Government Open Data License – India with the attribution above.
- Unit identifiers derived from GADM 4.1 (the `gid1_members` column of `pipeline/reference/state_frame.csv`) remain subject to the GADM licence (https://gadm.org/license.html).

## Contact

Dr Siddalingaiah H S, Department of Community Medicine, Shridevi Institute of Medical Sciences and Research Hospital, Tumakuru, Karnataka, India. ORCID: https://orcid.org/0000-0002-4771-8285.
