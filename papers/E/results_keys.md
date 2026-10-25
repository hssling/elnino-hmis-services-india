# Paper E: results contract (`papers/E/results.json`)

This contract lists every key that the Paper E scripts write to `papers/E/results.json` (674 keys). The design is `docs/superpowers/specs/2026-10-24-paper-e-hmis-services-design.md` (§10 builder-check resolutions, §11 author decisions and §12 data-format correction override its body text); the plan is `docs/superpowers/plans/2026-10-24-paper-e-hmis-services.md`; the controller rulings are in the Paper E SDD ledger (`preflight-rulings.md`, F-numbers). Entries use the Paper 0 schema `{"<key>": {"value", "display", "script", "description"}}`, written with `res_entry()` / `write_results()` (`models/common/R/results.R`). The producing scripts are `models/E/01_power.R` (§7), `models/E/02_primary.R` (§2–§5), `models/E/03_mediation.R` (§6), `models/E/04_secondary.R` (§8–§11), `models/E/05_forecast.R` (§12–§13) and `models/E/06_results.R` (§1 through `panel_keys()` in `models/E/R/results_e.R`, and §14). One command, run from `<repo>/models`, builds the file: `Rscript E/run_all.R`. `write_e_results()` stops unless the keys written equal `contract_keys("../papers/E/results_keys.md", prefix = "E")`. `tools/build_manuscript.py` fails on a missing key or a null display, and `papers/E/check_results_keys.py` cross-checks the manuscript placeholders against this file.

**What was known when this contract was written (disclosure; resolution (controller, 2026-10-25, F46)).** This file was committed alone, before any script under `models/E/` existed and before any model was fitted to HMIS outcomes. The following were known:
- **The data format.** The portal files are monthly, not cumulative (spec §12): the state value is the state's own row of each FY's `All_India.xls` (FY2020-21: the state-aggregate column group of the folder-2 state-month files), nothing is differenced, and districts are only the completeness layer.
- **The panel** (`data/derived/hmis/hmis_state_month.csv`, 34 units × 108 months) and **the model table** (`data/derived/hmis/hmis_model.csv`, 34 × 108 rows, 3,230 unit-months in the 95-month primary window), with their column definitions.
- **The completeness and gate tables** (`gate_summary.csv`, `pipeline/reference/hmis_reviewed.csv`). No gate failed except plausibility. Gate-masked shares over the gate scope FY2012-13 to 2019-20 (96 months, March 2020 included; `gate_summary.csv` scope `primary`) were 0.86% (diarr_u5), 0% (anc_reg, inst_del), 0.37% (penta3), 0.06% (mcv1), 0.03% (fic) and 0.09% (opd). No outcome was dropped and no FY was unusable. The two FY-level lows masked by F42 are GJ diarr_u5 2012-13 and KL penta3 2012-13.
- **The national March→April 2017 ratios** (`break_ratio_2017.csv`): diarr_u5 0.753, anc_reg 0.920, penta3 0.786, mcv1 0.876, fic 0.862, inst_del 0.838, opd 0.816; none beyond 25%.
- **The status dates:** 19 September 2015 to 6 November 2020 in the primary window; 1 October 2024 for FY2020-21.
- **FY2020-21:** acquired (456 folder-2 state-month files, 493 requests; `data/derived/hmis/fy2021_status.json` status `acquired`, to be committed at the Task 9 sync point, F3).
- **The exposure counts:** 95 primary months, 34 with ONI ≥ 0.5 and 6 with ONI ≤ −0.5; SD of ONI 0.7495 °C, of RONI 0.7605 °C, of the smoothed Niño-3.4 anomaly (`nino34_3m`) 0.7968 °C (0.814 raw); ONI maximum +2.59 °C. While this contract was written, the ENSO-phase × IOD-sign month counts (§9) were tabulated from the exposure columns alone, to confirm that no primary month has ONI or `dmi_3m` exactly 0.
- **SRS crude birth rates were not retrieved** (the only bulk source returned a CAPTCHA page; F23), so the births offset is not available.
- **Programme-event months** (`pipeline/reference/hmis_programme_events.csv`): MI phase I is confirmed from a fetched PIB page; 19 rows (other MI/IMI rounds, PMSMA, LaQshya, Diwali) are PROVISIONAL, from search-engine excerpts, Vikaspedia or a holiday-calendar site, pending the author's confirmation (Task 14).
- **The power-simulation design** (spec §5.8 as amended by §10.5; plan Task 7) and the published results of Papers A–D on other outcomes.

No ENSO or local-climate estimate on any HMIS outcome was computed, plotted or seen: no model containing `en_t`, `ln_t`, an ENSO index, `S_z` or a local-climate term had been fitted to an HMIS outcome, and Tasks 1–5 computed no such association.

Later additions are dated amendments, committed before the step that produces them runs, and add no verdict.

**Amendment (2026-10-25, before any model script exists; Task 6 review fix round 1).** Made after the Task 6 review and controller rulings F47 and F48, with `models/E/` still absent and no model fitted. Key names and the 674-key count are unchanged; no verdict rule changed. The text was corrected in place:
1. **Mediation a-path covariates** are now recorded as a controller ruling, a deliberate deviation from spec §5.4 (F48, §6), and removed from the contract's own resolutions (§15).
2. **Index comparability.** `E.idx.*` and `E.sens.<I>.{roni,nino34}` use the time random-effect step of the outcome's ONI Model T, the same step for all three indices, so `std_effect` = `sens`^`sd_index` (§11, §13).
3. **Model S reading.** A fifth reading, `not estimable (<reason>)`, covers an H7 outcome that is `consistent with` while Model S is not estimable (rules).
4. **Holm display.** A Holm-adjusted p is never displayed below its raw p's display bound; a block-bootstrap p of 0 enters the family at its bound 2/B_ok (Conventions; time random-effect chain).
5. **`era_e2` and `unit_era`.** `era_e2` is not a model term, but it defines `unit_era` (= `unit_id` × `era_e2`) for the `era_int` sensitivity (Common definitions).
6. **Masked-share scope.** The disclosed gate-masked shares are named with their gate scope, FY2012-13 to 2019-20 (96 months, March 2020 included), not the 95-month primary window.
7. **Break threshold.** The 0.75/1.25 descriptive band was written after the ratios were seen; `diarr_u5` (0.753) is discussed in the manuscript regardless (Data rule 6).
8. **Verdict-sentence template.** `E.h7.verdict_text` and `E.h9.verdict_text` now display a full clause (`consistent with H7 for …` / `not consistent with H7`), and `{LIST}` puts "and" before the last label (§3).
9. **Symmetric diarrhoea MDE (resolution (controller, 2026-10-25), F47).** For `diarr_u5` (H8 hypothesises an increase) the power simulation injects IRRs 1/0.90, 1/0.95, 1/0.97 and 1/0.99 and counts a rejection when the two-sided p < 0.05 and the estimate is > 1; the display when none reaches 80% is `not reached at IRR 1.11` (MDE rule; §7). The earlier "decrease side, read approximately" caveat is withdrawn.

**Amendment 2 (2026-10-25, before any model with exposure terms was fitted to HMIS outcomes; Task 8 code review).** Made after the Task 8 code review and controller rulings F56–F58, with the power simulation still running and no model containing `en_t`, `ln_t`, an ENSO index, `S_z` or a local-climate term fitted to an HMIS outcome. Key names and the 674-key count are unchanged; no verdict rule changed.
1. **Scope of "not estimable" (resolution (controller, 2026-10-25), F56).** Only a genuine estimation failure (no unit random-effect structure converges, a term is not estimated, or the block bootstrap fails item 2) makes a test or key `not estimable (<reason>)`; any other error (a missing column, no complete rows, a programming error) stops the run.
2. **Model T block bootstrap (resolution (controller, 2026-10-25), F57).** Every resample is refitted with the unit random-effect structure selected on the original rows (no per-resample fallback); a resample that does not converge with it fails. If more than 10% of the B = 1,000 refits fail, the estimates of that step read `not estimable (block bootstrap: more than 10% of refits failed)`; the number of successful refits (B_ok) is recorded in the `description` and in `primary_estimates.csv`.
3. **Mediation when Model T is not estimable (resolution (controller, 2026-10-25), F58).** Every `E.med.<I>.*` key reads `not estimable (Model T: <reason>)`. `not estimated (no total association)` is used only when Model T was estimated and its `en_t` 95% CI includes 1 (§6). An outcome dropped by the 20% rule keeps `not estimable (dropped: more than 20% of state-months masked)`.
4. **`E.med.<I>.indirect` when `flag` is `too_many_failed_fits`** displays the point IRR followed by ` (CI not estimated: >10% of bootstrap refits failed)`, e.g. `0.98 (CI not estimated: >10% of bootstrap refits failed)`, as `prop` does (§6).

**Amendment 3 (2026-10-25, made AFTER the Model T estimates were known; resolution (controller, 2026-10-25), F61).** The first full run of `02_primary.R` (commit 2d68075, `primary_estimates.csv`) had produced the Model T estimates and verdicts. Key names and the 674-key count are unchanged; the model specifications, data, verdict rules and display rules are unchanged.
1. **Optimiser limits only.** Every Paper E negative binomial (and mediation a-path) fit in glmmTMB now uses `glmmTMBControl(optCtrl = list(iter.max = 1e4, eval.max = 1e4))` instead of glmmTMB's default nlminb limits (iter.max 300, eval.max 400). Nothing else in the fitting changed.
2. **Why.** In that first run, Model S and Model L for 6 of the 7 outcomes (all but `diarr_u5`) stopped at nlminb's default iteration or function-evaluation limit (convergence codes 10 and 9) with a positive-definite Hessian and finite covariances, i.e. the optimiser budget, not identification, was exhausted (the models carry 95 year-month fixed effects); they were recorded as not estimable. No Model S or Model L estimate for those six outcomes had been seen when this change was made.
3. **Scope.** All primary models (Models T, S and L, the episode fits, any block bootstrap) are refitted with the same settings, and every later Paper E model uses them. The convergence of every primary fit (positive-definite Hessian, maximum absolute gradient) is recorded. The power simulation (§7), already run with glmmTMB's default limits, is not rerun.
4. **Forecast month-of-year coding.** In the forecast models (§12–§13) month of year enters as 11 indicator columns `moy_02`..`moy_12` (January reference) rather than the factor `moy`, because the frozen common `linear_predictor()` rejects factor fixed effects; the model is identical (same log-likelihood).

**Amendment 4 (2026-10-26; clarification of fact, no rule change; Task 13 review item 18).** Amendment 3 item 3 says the power simulation (§7) "already run with glmmTMB's default limits, is not rerun". That sentence refers to the four outcomes the detached run had completed at the default limits (`diarr_u5`, `anc_reg`, `penta3`, `inst_del`). The run crashed on 2026-10-25 after those four outcomes (a parallel-worker connection failure) and was resumed with `--reuse` for `opd`, `mcv1` and `fic` at the raised F61 limits, finishing after the primary fits had begun; the simulation design, code, seeds and parameters were otherwise unchanged, and the resumed outcomes' `E.power.*` keys come from that resumed run (`power.csv`, commit 544b12f). Key names, the 674-key count, the verdict rules and the display rules are unchanged; the manuscript Methods and Online Resource 1, Note S1 disclose the split.

**Key notation and parsing (resolution (controller, 2026-10-24, F20)).** In the key tables, `{a,b,c}` expands shell-style to one key per alternative. There is no nesting; two or more consecutive brace groups expand as a product. The indicator list `<I>` is always written out as `{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}` (7 outcomes) and the H7/H9 service family `<H>` as `{anc_reg,penta3,inst_del,opd}` (4 outcomes); in prose, `<I>` and `<H>` stand for one member. `06_results.R` reads this file with `contract_keys(path, prefix = "E")` from `models/D/R/contract.R` (sourced read-only). Every backticked `E.` token in the first cell of a table row that starts with `` | `E. `` is a key, after brace expansion. Only key tables have such rows. The number of keys in each section is stated in its heading, and the sections sum to the 674 keys above.

## Conventions

| Format | Display example | Rule |
|---|---|---|
| `irr_ci` | `0.97 (95% CI 0.93–1.01)` | `fmt_ci(est, lo, hi, digits = 2)`. En dash between bounds; `" to "` and U+2212 when a bound is negative (never for IRRs). |
| `pct_ci` | `34% (95% CI 12–60%)` | Percent, 0 decimals; negative bounds as `−8% (95% CI −30 to 15%)` (as Paper C). |
| `p` | `0.012`, `<0.001` | `fmt_p(p)`: three decimals, `<0.001` below 0.001, no "P=". A block-bootstrap p of 0 displays `<` + `fmt_num(2 / B_ok, 3)` (its resolution), e.g. `<0.002`. A Holm-adjusted p is never displayed below the display bound of its raw p: a bootstrap p of 0 enters the Holm family at its bound 2/B_ok, and its `p_holm` displays `<` + `fmt_p()` of the adjusted value computed from that bound (e.g. `<0.026`). |
| `int` | `3,230` | `fmt_int(x)`. |
| `num2`, `num3` | `0.75`, `0.753` | `fmt_num(x, 2)`, `fmt_num(x, 3)`; U+2212 for minus. |
| `num3s` | `+0.012`, `−0.008` | `fmt_num(x, 3, plus = TRUE)`. Signed differences. |
| `pct0`, `pct1`, `pct2` | `85%`, `98.5%`, `0.86%` | `fmt_pct(x, digits)`; `x` is a proportion. |
| `k_of_n` | `4 of 5` | Count of a total. |
| `date` | `19 September 2015` | Day, full month name, year. |
| text | as given per key | Fixed vocabulary only, as listed. |

**Value, description and not-estimable displays.**
- `value` is the point estimate on the display scale (an IRR, not a log coefficient), the count, the proportion or the text token. `description` carries the model, the rows, the time random-effect step used, the full-precision estimate, its bounds and the log-scale coefficient and SE to 6 significant digits, and the seed where relevant. `script` is the producing R script.
- **The fixed vocabulary** (resolution (plan, 2026-10-24)): verdict keys hold only `consistent with` or `not consistent with`; an estimate or p key that cannot be produced holds `not estimable (<reason>)`, and an outcome dropped by the 20% masking rule holds `not estimable (dropped: more than 20% of state-months masked)` in every estimate and p key. Other null displays used below are `not estimated (<reason>)`, `not applicable (<reason>)` and `not available (<reason>)`, each with `value` null.
- **Not-estimable tests (resolution (controller, 2026-10-24, F18)).** For a not-estimable test, the estimate and p keys read `not estimable (<reason>)` and the verdict key reads `not consistent with`. `<reason>` is the first line of the error, `no converged time random effect`, or the dropped text above.

## Common definitions

- **Data.** `data/derived/hmis/hmis_model.csv` (ruling F2: never `data/derived/model/`), read by `read_hmis_model()` with factors `unit_id`, `moy`, `ym_f` (every `ym` in time order), `national` (constant) and `unit_era` (= `unit_id` × `era_e2`, the unit × HMIS-format-era factor used only by the `era_int` sensitivity; plan Task 7). The **primary window** is the 95 months April 2012 to February 2020 (`in_primary == 1`; 3,230 unit-months). March 2020 lies outside it: spec §5.1 makes `covid_mar2020` "equivalent to excluding the month" (resolution (plan, 2026-10-24)), so `covid_mar2020` is identically 0 in the primary window and is not entered there. FY2020-21 (April 2020 to March 2021) enters only the `fy2021` sensitivity.
- **Units.** The 34 units of `pipeline/reference/state_frame.csv` (AP_TG, JK and DNH_DD pooled). Units leave a model only through `complete_rows()` (the NA rule), never by hand, except where a sensitivity says so. Missing is never zero.
- **Outcomes.** `<ind>` (the gated state value, kept where `comp_<ind>` ≥ 0.90). Primary service outcomes (H7, H9): `anc_reg`, `penta3`, `inst_del`, `opd`. Primary disease outcome (H8): `diarr_u5`. Secondary outcomes, without a verdict: `mcv1`, `fic`. Labels used in text: `diarr_u5` "diarrhoea in children under 5 years"; `anc_reg` "ANC registration"; `penta3` "third dose of a DPT-containing vaccine"; `mcv1` "first dose of a measles-containing vaccine"; `fic` "full immunisation"; `inst_del` "institutional deliveries"; `opd` "outpatient attendance".
- **Exposure (spec §4).** `oni` is the traditional ONI for the 3-month season ending in month t (the row centred on t − 1). `en_t = pmax(oni, 0)` (El Niño term, per +1 °C) and `ln_t = pmin(oni, 0)` (La Niña term). RONI enters as `en_roni`/`ln_roni`; the Niño-3.4 anomaly as `nino34_3m`, the mean over months t−2..t, split into `en_n34`/`ln_n34`; the DMI as `dmi_3m`, the mean over t−2..t (resolution (plan, 2026-10-24): "season ending in t" with the same smoothing).
- **Episode terms (resolution (plan, 2026-10-24)).** The episode windows are the §5.7 LOEO windows, ep1415 = October 2014 to December 2016 and ep1819 = September 2018 to February 2020 (2018–19 and the weak 2019–20 episode merged). The episode IRRs come from `en_ep1415 = en_t × I(ep1415)` and `en_ep1819 = en_t × I(ep1819)`, fitted in one model that also contains `en_other = en_t × I(neither)` and `ln_t`; the three terms partition `en_t`.
- **Programme indicators (spec §5.1; resolution (controller, 2026-10-25, F45)).** Programme indicators enter each outcome's model only where they apply (`programme_terms_for()`, `applies_to` in `hmis_programme_events.csv`). Primary models: `hmis_format2017` (step from April 2017) and `demonet` (November 2016 to January 2017) for every outcome, plus `mi_round` for `penta3`, `mcv1` and `fic`. December 2014 (the Mission Indradhanush launch) is not coded as an MI round month, because no round was held; the first round was April 2015. `era_e2` is never entered as a model term, because it is identical to `hmis_format2017`; it only defines `unit_era` for the `era_int` sensitivity (amendment 2026-10-25). `pmsma` (ANC only), `laqshya` (deliveries only) and `diwali` (all) enter only the `extra_prog` sensitivity; `covid_mar2020` and `covid_fy2021` only the `fy2021` sensitivity.
- **Offset.** `log_pop_days = log(pop_mid × days)`: unit population interpolated to day 15 of the month, times the calendar days (February 2016 = 29).
- **Trend.** `t_c = (t_months − 47) / 12`, a linear reparameterisation of the spec's `t_months` (resolution (plan, 2026-10-24)).
- **Model T (spec §5.2).** `t_spec(<ind>)`: `<ind> ~ en_t + ln_t + moy + t_c + <programme terms> + offset(log_pop_days) + (1 + t_c | unit_id) + <time RE>`, NB2 in glmmTMB through `fit_nb()` (unit random-effect fallback chain `us` → `diag` → `int`), on the primary window.
- **The time random-effect chain (resolution (plan, 2026-10-24)).** `ar1(ym_f + 0 | national)`, then `(1 | ym_f)`, then a moving-block bootstrap over months (block 12, B = 1,000; `block_bootstrap_irr()`, which refits the model without a time random effect on each month-block resample). The step used is recorded in `E.t.<I>.time_re`. Under the bootstrap step, the CI is the percentile interval and the p is the two-sided bootstrap p, 2 × min(share of resampled coefficients ≤ 0, share ≥ 0); this p replaces the Wald p in the Holm family (resolution (plan, 2026-10-24)). A bootstrap p of 0 enters the family at its resolution bound 2/B_ok, which is conservative for every test in the family (amendment 2026-10-25).
- **Model S (spec §5.3).** `nb_spec(<ind>, fixed = c("en_S", "ln_S", "ym_f"), slopes = "t_c", offset = "log_pop_days", trend_df = 0L)`, where `en_S = en_t × S_z` and `ln_S = ln_t × S_z`. `S_z` is Paper D's `hazard_rain` (% of JJAS rain lost per +1 °C ONI, 1981–2009) z-scored over the 32 units that have it, with ddof = 1 (resolution (plan, 2026-10-24)). Year-month fixed effects; no time random effect and no programme indicators (both absorbed by `ym_f`).
- **Model L (spec §5.4).** As Model S with `fixed = c("spi3_dry_l0", "spi3_wet_l0", "heatwave_days_l0", "ym_f")`: `spi3_dry = pmin(SPI-3, 0)`, `spi3_wet = pmax(SPI-3, 0)`, heatwave days (Tmax ≥ 45 °C, or ≥ 40 °C with a departure ≥ 4.5 °C), concurrent month.
- **Units in each model (resolution (plan, 2026-10-24); spec §10.7).** Model S runs on 32 units (A&N and LD lack `S_z`). Models with rainfall terms (Model L, mediation, forecast Models B and C) run on 33 units (A&N rain is masked). A&N stays in every model without rainfall terms. PY and TN lose the months whose rain was masked by QC (11 SPI-3 months each in the table window).
- **IRR CIs** are Wald, from the chosen covariance structure (spec §5.5); bootstrap CIs only where stated.
- **Seed.** `SEED_E = 20261024L` (`models/E/R/common_e.R`); resample i of any bootstrap uses `SEED_E + i − 1`.
- **Frozen code (resolution (plan, 2026-10-24)).** `models/common/R` is not edited; the monthly extensions are new functions in `models/E/R/` that call the common ones unchanged.

## Data rules stated in Methods (spec §12; rulings F33–F45)

1. **State value (resolution (controller, 2026-10-25, F33, F43)).** The state value is the official monthly state aggregate: the state's own row of each FY's `All_India.xls` for FY2012-13 to 2019-20, and the state-aggregate (first) column group of the FY2020-21 state-month file. It replaces the brief's "sum of the district aggregates" and the spec's differenced `_State` column. Nothing is differenced. Members are pooled with `min_count = 1` (AP + TG + "Andhra Pradesh Old" → AP_TG; J&K + Ladakh → JK; DNH + DD or the merged UT → DNH_DD; F34, F36). Methods describe monthly state aggregates from the portal's All_India workbooks with a district-completeness filter, never "differenced cumulative files" (F35).
2. **Completeness (spec §10.1).** A state-month enters models only if `comp_<ind>` (valid districts / districts listed for the state-FY) ≥ 0.90; otherwise it is missing, never scaled up. Sensitivities: ≥ 0.75, no threshold, and the scaled district sum.
3. **Gates and dispositions (spec §10.2).** A cell failing a gate is masked, never replaced; an outcome with more than 20% of its primary state-months gate-masked is dropped from the primary analysis and reported descriptively; the build halts if two or more of the five primary outcomes are dropped or more than one primary FY is unusable. The district-sum, national-total and 12-month-versus-FY-total checks are internal-consistency checks, never independent validation (F35).
4. **Plausibility (resolution (controller, 2026-10-25, F41, F42)).** A state-month above 3× its unit's same-calendar-month median within era (E1 = FY2012-13 to 2016-17, E2 = FY2017-18 to 2019-20; FY2020-21 compared with E2; median ≥ 20) is masked. A low below 0.33× is kept and logged (rule `default_keep_low`) and masked only in the `masklow` sensitivity, except that lows covering every available month (≥ 10) of a unit-FY are masked by default (rule `default_mask_fy_level`).
5. **Sum indicators (resolution (controller, 2026-10-25, F37)).** `penta3` (Penta3 / DPT3) and `mcv1` (MR / measles first dose) have substitute components (a child receives one or the other), so a missing component is structurally absent; they are exempt from the 5% partial-component masking rule (still reported). `fic`, `inst_del` and `opd` have additive components and keep the rule. The `allcomp` sensitivity requires every component present.
6. **Format break.** The `hmis_format2017` step is in every model. The national March→April 2017 ratios are descriptive (`E.break2017.*`); a ratio below 0.75 or above 1.25 is discussed but excludes nothing. This band was written after the ratios were seen (amendment 2026-10-25); `diarr_u5` (0.753, against 0.93–1.03 in other years) is discussed in Methods and Limitations regardless (controller ruling, Task 13).

## Rules fixed before results (stated verbatim)

**One Holm family (spec §5.6 with §10.3; resolution (plan, 2026-10-24)).** H7–H9 per spec §5.6, but with one Holm family over every H7–H9 test actually performed (§10.3): 4 H7, 1 H8 and 8 H9, i.e. 13 tests when all are estimable.
- Tests that are not estimable leave the family and count as `not consistent with`.
- p-values are two-sided Wald (the block-bootstrap p where the time random-effect chain reaches that step).
- A verdict also needs the pre-specified direction.
- The H8 condition is then "Holm-adjusted p < 0.05".
- The family is `holm_family()`: `stats::p.adjust(method = "holm")` over the non-NA p of the performed tests, whatever their direction; a not-estimable test has `p_holm` NA. The H7 and H8 tests are the Model T `en_t` coefficients of the five primary outcomes; the H9 tests are the Model L `heatwave_days_l0` and `spi3_dry_l0` coefficients of the four service outcomes.

**H7 (services, primary).** During the El Niño phase, the use of essential services is lower. Family: `anc_reg`, `penta3`, `inst_del`, `opd`. Per outcome, `consistent with` if and only if (i) the Model T IRR per +1 °C for `en_t` is < 1, with a Holm-adjusted p < 0.05 in the family above; **and** (ii) both episode-specific IRRs (`en_ep1415`, `en_ep1819`) are < 1 (point estimates). Otherwise `not consistent with`. If the episode model is not estimable, condition (ii) fails; the `en_t` test still counts in the family if it was performed (resolution (contract, 2026-10-25)). The overall `E.h7.verdict` is `consistent with` if at least one outcome is consistent, and `E.h7.verdict_text` names the outcomes.

**H8 (diarrhoea, primary for the disease outcome).** Reported diarrhoea in under-5s is higher during the El Niño phase. `consistent with` if and only if the Model T IRR for `en_t` is > 1 with a Holm-adjusted p < 0.05 **and** both episode IRRs are > 1 (point estimates). Otherwise `not consistent with`. A reduction is reported and discussed (it could reflect lost access), but it does not satisfy H8.

**H9 (local-climate pathway).** Within the same calendar month, services are lower in state-months with more heatwave days or with rainfall deficit (SPI-3 below 0). Tests: `heatwave_days` and `spi3_dry` × the four service outcomes, giving 8 tests, Holm-adjusted together with H7 and H8. For heatwave days, a decrease means IRR < 1. For `spi3_dry`, whose values are ≤ 0, "lower services with deficit" means a coefficient > 0. Per outcome, `consistent with` if either term is significant in the hypothesised direction after Holm adjustment: (`heatwave_days` IRR < 1 and its p_holm < 0.05) or (`spi3_dry` coefficient > 0 and its p_holm < 0.05). The overall verdict follows the H7 pattern. `spi3_wet` (flood or excess rain) and diarrhoea under Model L are reported without a verdict.

**Display of the deficit term (resolution (contract, 2026-10-25)).** `E.l.<I>.dry.*` display the IRR per one SPI-3 unit **more deficit**, `exp(−β)` with the bounds swapped (as Paper C's `irr_spi_dec`), so that a coefficient β > 0 ("lower services with deficit") displays as an IRR < 1, the same direction as heatwave days. The verdict uses β. `description` records β and its SE.

**Secondary outcomes** (`mcv1`, `fic`), Model S, Model L for `diarr_u5`, `spi3_wet`, the mediation, the forecast and index comparisons, the IOD, distributed-lag and heterogeneity analyses, and every sensitivity analysis carry no verdict.

**Model S reading rule (spec §5.3; plan `reading_rule_s()`).** If H7 is `consistent with` but Model S is null or in the opposite direction, the Discussion must say the total association may reflect coincident national events. If both agree in direction, the Discussion may say the association is "not explained by national shocks". Per H7 outcome, `E.s.<H>.reading` is:
- `agrees in direction`: the outcome's H7 verdict is `consistent with` and the Model S `en_S` 95% CI excludes 1 on the same side as the Model T IRR (upper bound < 1);
- `null or opposite`: the outcome's H7 verdict is `consistent with` and the Model S CI includes 1 or lies above 1;
- `not estimable (<reason>)`: the outcome's H7 verdict is `consistent with` and Model S is not estimable; the Discussion treats it as `null or opposite`, the cautious branch (amendment 2026-10-25);
- `not applicable (H7 not consistent with)`: otherwise.
For `diarr_u5`, `mcv1` and `fic`, which have no H7 verdict, the reading is `not applicable (outcome outside H7)` (resolution (contract, 2026-10-25): spec §5.3 names H7 only).

**Mediation rule (spec §5.4 with §10.4).** The local-climate-mediated share is estimated only when the Model T `en_t` 95% CI excludes 1; otherwise every `E.med.<I>.*` key reads `not estimated (no total association)`. Mediation runs for every outcome that meets the condition, with no verdict.

**Forecast rule (spec §5.7).** Model C "adds skill over local climate" only if its MALE is lower than Model B's in both LOEO folds and in at least 4 of 5 rolling origins. Otherwise the conclusion is "no added skill demonstrated". With 2 folds this is low-powered, and the text says so.

**Heterogeneity rule (spec §5.5).** State-specific statements are permitted only if (i) the LRT p < 0.05, (ii) the slope SD is not at the boundary (the Hessian is positive definite and the SD's lower CI is > 0.01), and (iii) the result holds when either episode is dropped (resolution (plan, 2026-10-24): both drop-episode refits give LRT p < 0.05). Even then, the paper shows conditional modes as a figure with intervals, never as a ranking. If the rule fails, the paper says state differences are not identifiable.

**The MDE (resolution (plan, 2026-10-24)).** The MDE is the IRR closest to 1 among 0.90/0.95/0.97/0.99 with power ≥ 0.80 (two-sided p < 0.05 and an estimate below 1). If none reaches it, the display is "not reached at IRR 0.90". **For `diarr_u5` (resolution (controller, 2026-10-25), F47: H8 hypothesises an increase)** the MDE is the IRR closest to 1 among 1/0.90, 1/0.95, 1/0.97 and 1/0.99 (1.111, 1.053, 1.031, 1.010) with power ≥ 0.80 (two-sided p < 0.05 and an estimate above 1). If none reaches it, the display is "not reached at IRR 1.11". Every null in the Discussion is read against it: "effects larger than X% per +1 °C are unlikely; smaller effects cannot be excluded". The MDE is per test at α = 0.05, not Holm-adjusted, so it is optimistic for the 13-test family (resolution (contract, 2026-10-25)).

**FY2020-21 (resolution (controller, 2026-10-24, F3, F19)).** FY2020-21 is a COVID-flagged sensitivity only. It was acquired (folder-2 state-month files). Its keys fall back to `not estimable (FY2020-21 <reason>)` if `fy2021_status.json` is not final and committed at the Task 9 sync point. The `fy2021` sensitivity keeps `covid_mar2020` and adds `covid_fy2021`, an indicator for April 2020 onward.

## 1. Panel, completeness, gates and exposure (64 keys)

Producer: `panel_keys()` in `models/E/R/results_e.R`, called by `06_results.R`. It is the single producer of `E.exposure.*` (resolution (controller, 2026-10-24, F15)); Task 10 only reads them. Inputs: `hmis_model.csv` (primary window unless stated), `gate_summary.csv` (scope `primary`, FY2012-13 to 2019-20, 3,264 unit-months per outcome: the gate rules are applied by FY, so March 2020 is included), `break_ratio_2017.csv` and `fy2021_status.json`.

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.panel.n_units` | Units in the panel | n | `panel_keys()`, distinct `unit_id` | `int` | Abstract, Results ¶1, Table 2 |
| `E.panel.n_months` | Months in the primary window, April 2012 to February 2020 (`in_primary == 1`) | n | `panel_keys()` | `int` | Abstract, Results ¶1 |
| `E.panel.n_state_months` | Unit-months in the primary window (rows, whatever the outcome values) | n | `panel_keys()` | `int` | Abstract, Results ¶1, Table 2 |
| `E.panel.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.n_valid` | Primary-window unit-months with a non-missing `<ind>` (after gates and the 0.90 completeness filter) | n | `panel_keys()` | `int` | Results ¶1, Table 2 |
| `E.comp.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.median` | Median over primary-window unit-months of `comp_<ind>` (valid / listed districts) | proportion | `panel_keys()` | `pct1` | Table 2, Figure 2 |
| `E.comp.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.share_district_months_valid` | Headline completeness (spec §10.1): share of district-months valid, Σ(`comp_<ind>` × `n_districts_<ind>`) / Σ `n_districts_<ind>` over primary-window unit-months with a district list | proportion | `panel_keys()` | `pct1` | Abstract, Results ¶1, Table 2 |
| `E.status_date.{min,max}` | Earliest `status_date_min` and latest `status_date_max` over the primary window (all HMIS values are provisional as of these dates) | date | `panel_keys()` | `date` | Methods, Table 2 |
| `E.status_date.range` | The two dates above as a range; `description` adds the FY2020-21 status date | text | `panel_keys()` | `19 September 2015 to 6 November 2020` form | Methods |
| `E.gates.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.n_masked` | Gate-masked state-months, scope `primary` (`gate_summary.csv` `masked`); the completeness filter is not masking | n | `panel_keys()` | `int` | Results ¶1, Supplement (gate report) |
| `E.gates.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.share_masked` | `masked_share` (masked / reported state-months, scope `primary`) | proportion | `panel_keys()` | `pct2` | Results ¶1, Supplement |
| `E.gates.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.dropped` | Whether the outcome was dropped by the 20% rule (`gate_summary.csv` `dropped`) | text | `panel_keys()` | `not dropped` or `dropped (more than 20% of state-months masked)` | Results ¶1 |
| `E.gates.n_dropped` | Outcomes dropped (expected 0 at the Task 4 build) | n | `panel_keys()` | `int` | Results ¶1 |
| `E.break2017.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.ratio` | National April 2017 / March 2017 ratio of pre-gate state values, units reporting both months (descriptive) | ratio | `panel_keys()`, `break_ratio_2017.csv` | `num3` | Methods, Table 1 |
| `E.exposure.n_months` | Primary months with an ONI value | n | `panel_keys()` | `int` | Results ¶1 |
| `E.exposure.n_en_months` | Primary months with ONI ≥ 0.5 | n | `panel_keys()` | `int` | Abstract, Results ¶1 |
| `E.exposure.n_ln_months` | Primary months with ONI ≤ −0.5 | n | `panel_keys()` | `int` | Results ¶1 |
| `E.exposure.oni_sd` | SD (n − 1) of `oni` over the primary months, one value per month | °C | `panel_keys()` | `num2` | Methods, §13 |
| `E.exposure.oni_max` | Maximum `oni` over the primary months | °C | `panel_keys()` | `fmt_num(x, 2, plus = TRUE)` | Results ¶1 |
| `E.exposure.roni_sd` | SD of `roni` over the primary months | °C | `panel_keys()` | `num2` | Methods, §13 |
| `E.exposure.nino34_sd` | SD of the entered Niño-3.4 series `nino34_3m` (3-month mean) over the primary months; `description` gives the raw calendar-month SD (resolution (plan, 2026-10-24): the spec's 0.82 is not reproduced; the data give 0.81 raw and 0.80 smoothed) | °C | `panel_keys()` | `num2` | Methods, §13 |
| `E.fy2021.status` | Status of the FY2020-21 sensitivity (`fy2021_status.json`, final and committed at the Task 9 sync) | text | `panel_keys()` | `included as a COVID-flagged sensitivity analysis` or `not estimable (FY2020-21 <reason>)` | Methods, Results ¶5 |

## 2. Model T: total association (63 keys)

Producer: `fit_model_t()` in `02_primary.R`. The primary fit gives `en_t` and `ln_t`; the episode fit (`exposure = c("en_ep1415", "en_ep1819", "en_other", "ln_t")`, the same chain, its step recorded in the `description` of the episode keys) gives the episode IRRs.

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.t.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.irr_en` | IRR per +1 °C of the El Niño term `en_t` | IRR per °C | `02_primary.R` | `irr_ci` | Abstract, Results ¶2, Table 3, Figure 3 |
| `E.t.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.{irr_en.ep1415,irr_en.ep1819}` | IRR per +1 °C of `en_ep1415` / `en_ep1819` (episode model) | IRR per °C | `02_primary.R` | `irr_ci` | Results ¶2, Table 3, Figure 3 |
| `E.t.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.p_en` | Two-sided Wald p of `en_t` (bootstrap p under the bootstrap step) | p | `02_primary.R` | `p` | Table 3 |
| `E.t.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.p_en_holm` | Holm-adjusted p of `en_t` in the H7–H9 family; `mcv1`, `fic`: `not applicable (secondary outcome; outside the Holm family)` | p | `02_primary.R`, `holm_family()` | `p` | Results ¶2, Table 3 |
| `E.t.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.irr_ln` | IRR per 1 °C **cooler** La Niña term: `exp(−β_ln)` with the bounds swapped (as Paper C); `description` says the term is weakly identified (6 months with ONI ≤ −0.5) | IRR per °C | `02_primary.R` | `irr_ci` | Table 3 |
| `E.t.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.time_re` | Time random-effect step used (`fit_time_chain()`) | text | `02_primary.R` | `ar1` → `AR(1) year-month random effect`; `iid` → `independent year-month random effect`; `block_bootstrap` → `moving-block bootstrap over months (block 12, B = 1,000)` | Methods, Table 3 |
| `E.t.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.re_used` | Unit random-effect structure used (`fit$re_used`) | text | `02_primary.R` | `us` → `correlated random intercept and trend slope`; `diag` → `uncorrelated random intercept and trend slope`; `int` → `random-intercept-only` | Table 3 |
| `E.t.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.n` | Unit-months in the primary Model T fit | n | `fit$n` | `int` | Table 3 |

## 3. Verdicts H7–H9 (21 keys)

Producer: `verdicts.R` (`holm_family()`, `verdict_h7()`, `verdict_h8()`, `verdict_h9()`, `overall_verdict()`), called by `02_primary.R`.

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.h7.{anc_reg,penta3,inst_del,opd}.verdict` | H7 verdict per service outcome (rule above) | text | `verdict_h7()` | `consistent with` or `not consistent with` | Results ¶2, Table 3 |
| `E.h7.verdict` | Overall H7 verdict: `consistent with` if at least one outcome is | text | `overall_verdict()` | `consistent with` or `not consistent with` | Abstract, Discussion |
| `E.h7.verdict_text` | Overall H7 verdict naming the consistent outcomes (template below) | text | `overall_verdict()` | text | Results ¶2, Discussion |
| `E.h8.verdict` | H8 verdict (`diarr_u5`) | text | `verdict_h8()` | `consistent with` or `not consistent with` | Abstract, Results ¶2, Table 3 |
| `E.h9.{anc_reg,penta3,inst_del,opd}.verdict` | H9 verdict per service outcome | text | `verdict_h9()` | `consistent with` or `not consistent with` | Results ¶3, Table 3 |
| `E.h9.{anc_reg,penta3,inst_del,opd}.{hw.p_holm,dry.p_holm}` | Holm-adjusted p of the Model L `heatwave_days_l0` and `spi3_dry_l0` coefficients in the H7–H9 family | p | `holm_family()` | `p` | Results ¶3, Table 3 |
| `E.h9.verdict` | Overall H9 verdict | text | `overall_verdict()` | `consistent with` or `not consistent with` | Abstract, Discussion |
| `E.h9.verdict_text` | Overall H9 verdict naming the consistent outcomes | text | `overall_verdict()` | text | Results ¶3, Discussion |

**Verdict-sentence templates (amended 2026-10-25).** `{LIST}` joins the labels (Common definitions) of the outcomes whose per-outcome verdict is `consistent with`, in the order `anc_reg`, `penta3`, `inst_del`, `opd`, separated by ", " with " and " before the last label (one label stands alone).
- `E.h7.verdict_text` = `consistent with H7 for {LIST}` when `E.h7.verdict` is `consistent with`, for example `consistent with H7 for ANC registration and institutional deliveries`; otherwise `not consistent with H7`.
- `E.h9.verdict_text` = `consistent with H9 for {LIST}` (the H9 verdicts) or `not consistent with H9`.
- In the manuscript: "These results were {{E.h7.verdict_text}}." and "These results were {{E.h9.verdict_text}}."; for H8, "These results were {{E.h8.verdict}} H8."; per outcome, "For ANC registration, the results were {{E.h7.anc_reg.verdict}} H7." No template places an outcome list between a verdict and the hypothesis label.

## 4. Model S: differential association (29 keys)

Producer: `fit_model_s()` in `02_primary.R`; rows with non-NA `S_z` (32 units).

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.s.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.irr` | IRR of `en_S`: per +1 °C El Niño-phase ONI per +1 SD of the state rainfall sensitivity `S_z` | IRR per °C·SD | `02_primary.R` | `irr_ci` | Results ¶2, Table 3, Figure 3 |
| `E.s.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.irr_ln` | IRR of `ln_S` per 1 °C cooler per +1 SD `S_z`, `exp(−β)` with bounds swapped | IRR per °C·SD | `02_primary.R` | `irr_ci` | Supplement |
| `E.s.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.p` | Two-sided Wald p of `en_S` | p | `02_primary.R` | `p` | Table 3 |
| `E.s.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.reading` | Model S reading (rule above) | text | `reading_rule_s()` | `agrees in direction`, `null or opposite`, `not estimable (<reason>)`, `not applicable (H7 not consistent with)` or `not applicable (outcome outside H7)` | Discussion |
| `E.s.n_units` | Units in Model S (32; `description` names the two excluded, A&N and LD, NA by rule) | n | `02_primary.R` | `int` | Methods |

## 5. Model L: local-climate association (71 keys)

Producer: `fit_model_l()` in `02_primary.R` (lag 0, the H9 tests and `irr`/`p`); `model_l_lags()` and `model_l_tmax()` in `04_secondary.R` (`cum02`, `tmax`). 33 units. `hw` = `heatwave_days`, `dry` = `spi3_dry`, `wet` = `spi3_wet`.

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.l.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.hw.irr` | IRR per additional heatwave day, concurrent month | IRR per day | `02_primary.R` | `irr_ci` | Abstract, Results ¶3, Table 3, Figure 3 |
| `E.l.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.dry.irr` | IRR per one SPI-3 unit more deficit, `exp(−β)` (display rule above) | IRR per SPI unit | `02_primary.R` | `irr_ci` | Abstract, Results ¶3, Table 3, Figure 3 |
| `E.l.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.wet.irr` | IRR per +1 SPI-3 unit of excess (`spi3_wet`), `exp(β)`; no verdict | IRR per SPI unit | `02_primary.R` | `irr_ci` | Results ¶3, Table 3 |
| `E.l.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.hw.p` | Two-sided Wald p of the heatwave-days coefficient (unadjusted) | p | `02_primary.R` | `p` | Table 3 |
| `E.l.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.dry.p` | Two-sided Wald p of the `spi3_dry` coefficient (unadjusted) | p | `02_primary.R` | `p` | Table 3 |
| `E.l.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.wet.p` | Two-sided Wald p of the `spi3_wet` coefficient | p | `02_primary.R` | `p` | Table 3 |
| `E.l.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.hw.cum02` | Spec §4 secondary lag: Model L with each term at lags 0, 1 and 2 entered together; IRR = exp(sum of the three heatwave coefficients), CI from the vcov of the sum (resolution (plan, 2026-10-24)) | IRR per day | `model_l_lags()` | `irr_ci` | Supplement |
| `E.l.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.dry.cum02` | The same for `spi3_dry`, oriented per unit more deficit: `exp(−sum)` | IRR per SPI unit | `model_l_lags()` | `irr_ci` | Supplement |
| `E.l.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.wet.cum02` | The same for `spi3_wet`: `exp(sum)` | IRR per SPI unit | `model_l_lags()` | `irr_ci` | Supplement |
| `E.l.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.tmax.irr` | Sensitivity: Model L with `tmax_anom_l0` replacing `heatwave_days_l0` (never entered together); IRR per +1 °C Tmax anomaly | IRR per °C | `model_l_tmax()` | `irr_ci` | Supplement |
| `E.l.n_units` | Units in Model L (33; A&N rain masked) | n | `02_primary.R` | `int` | Methods |

## 6. Local-climate-mediated share (35 keys)

Producer: `mediate_m()` in `models/E/R/mediation_e.R`, run by `03_mediation.R` only for outcomes whose Model T `en_t` 95% CI excludes 1 (the mediation rule).
- **Paths.** One Gaussian a-path per mediator (`spi3_dry_l0`, `spi3_wet_l0`, `heatwave_days_l0`): mediator ~ `en_t` + covars + `(1 | unit_id)`, where covars are the Model T fixed effects other than `en_t` (`ln_t`, `moy`, `t_c` and the programme terms). This is resolution (controller, 2026-10-25), F48: a deliberate deviation from spec §5.4, which names month-of-year fixed effects and a unit random effect only. The a-path uses the Model T covariates because common `mediate()`'s single `covars` argument feeds all three paths (plan Task 8), which keeps a·b coherent with the total and direct models. One NB b-path: Model T plus the three mediators. The total model is Model T. All three on the same rows (33 units). The NB fits carry the iid `(1 | ym_f)` time random effect (plan). indirect = Σ a_k·b_k; prop = indirect / c_total.
- **Resampling (spec §10.4).** Primary: moving-block bootstrap over months (block 12, the whole panel resampled by month blocks, models refitted), B = 500. If the run time projected from 5 resamples exceeds 24 hours, B = 200 and the reduction is reported in `E.med.<I>.B`. The cluster bootstrap by unit (`bootstrap_units`, same B) is a sensitivity only (`prop_unit`). The >10% failed-refit rule and `prop_flag` work as in common `mediate()`.
- An outcome that does not meet the rule reads `not estimated (no total association)` in all five keys, with `value` null.

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.med.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.prop` | Proportion of the total association carried by the three local-climate terms, × 100, month-block bootstrap percentile CI | % | `03_mediation.R` | `pct_ci`; if `flag` = `too_many_failed_fits`: `34% (CI not estimated: >10% of bootstrap refits failed)`; if `prop_flag` is not `ok`: `not estimable (<prop_flag>)` | Results ¶3, Abstract |
| `E.med.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.prop_unit` | The same with the cluster bootstrap by unit (sensitivity) | % | `03_mediation.R` | as `prop` | Supplement |
| `E.med.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.indirect` | Indirect IRR per +1 °C El Niño-phase ONI, `exp(Σ a_k·b_k)`, month-block bootstrap percentile CI | IRR per °C | `03_mediation.R` | `irr_ci` | Results ¶3 |
| `E.med.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.flag` | Bootstrap status: `flag` and `prop_flag` of the primary run | text | `03_mediation.R` | `ok`, `too_many_failed_fits`, `total_effect_ci_includes_0`, `opposite_signs`, `nonfinite_resample_proportion` (the first non-`ok` of `flag`, then `prop_flag`) | Supplement |
| `E.med.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.B` | Bootstrap resamples requested (500, or 200 after the 24-hour projection); `description` gives the successful count | n | `03_mediation.R` | `int` | Methods, Supplement |

## 7. Power (36 keys)

Producer: `simulate_power()` and `mde()` in `models/E/R/power.R`, run by `01_power.R` after this contract is committed and before any Model T estimate is read (spec §5.8, §10.5).
- **Design.** Fit Model T without `en_t`/`ln_t` (iid `(1 | ym_f)`). Per simulation, redraw the year-month effects from N(0, σ̂²_ym), keep the unit effects at their conditional modes, set μ = exp(η̂ + new ym effect) × IRR^`en_t` and draw y ~ NB2(μ, θ̂). Refit the iid Model T with `en_t` and `ln_t`. Service and secondary outcomes: IRRs 0.90, 0.95, 0.97 and 0.99 per +1 °C, and a rejection is a two-sided p < 0.05 with a coefficient < 0. `diarr_u5` (F47): IRRs 1/0.90, 1/0.95, 1/0.97 and 1/0.99, and a rejection is a two-sided p < 0.05 with a coefficient > 0.
- **Budget (spec §10.5).** 200 simulations per IRR per outcome (spec §5.8's 500 is superseded), in parallel. If the projection exceeds 8 hours, the five primary outcomes run first and `mcv1`/`fic` only if time remains; an outcome not run reads `not estimated (power simulation time budget)` in its five keys.

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.power.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.mde` | Minimum detectable IRR per +1 °C (the MDE rule) | IRR per °C | `mde()` | `num2` (e.g. `0.95`; `diarr_u5` e.g. `1.05`) or `not reached at IRR 0.90` (`diarr_u5`: `not reached at IRR 1.11`) | Abstract, Results ¶2, Discussion |
| `E.power.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.{p090,p095,p097,p099}` | Power at IRR 0.90, 0.95, 0.97, 0.99; for `diarr_u5`, at the reciprocal IRR 1/0.90, 1/0.95, 1/0.97, 1/0.99 (F47): rejections / successful refits (`n_ok` in `description`) | proportion | `simulate_power()` | `pct0` | Supplement (MDE simulation) |
| `E.power.n_sim` | Simulations requested per IRR per outcome | n | `01_power.R` | `int` | Methods |

## 8. State heterogeneity (21 keys)

Producer: `het_test()` and `het_rule()` in `models/E/R/secondary.R`, run by `04_secondary.R`. Model T with `slopes = c("t_c", "en_t")` against the primary Model T by LRT, both with the time random-effect step the primary fit used (resolution (contract, 2026-10-25): the LRT needs the same time structure in both); if the primary used the bootstrap step, all three keys read `not estimable (no converged time random effect)`.

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.het.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.lrt_p` | LRT p, `en_t` random slope versus none (boundary test, reported as is) | p | `het_test()` | `p` | Supplement |
| `E.het.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.slope_sd` | SD of the unit `en_t` slope (log-rate scale) with its Wald CI on the log-SD scale | log IRR per °C | `het_test()` | `fmt_ci(digits = 3)`; no CI → `fmt_num(x, 3)` + ` (CI not estimable)` | Supplement |
| `E.het.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.identifiable` | The §5.5 heterogeneity rule; `value` TRUE/FALSE; Figure S1 only when TRUE | text | `het_rule()` | `identifiable (spec §5.5 rule met)` or `not identifiable (spec §5.5 rule not met)` | Results ¶4, Supplement |

## 9. Indian Ocean Dipole (18 keys)

Producer: `04_secondary.R`. Model T plus `dmi_3m` and `en_t:dmi_3m` (resolution (controller, 2026-10-24, F14)). Month counts: `iod_counts()` over the 95 primary months; warm = ONI > 0, cool = ONI ≤ 0; pos = `dmi_3m` > 0, neg = `dmi_3m` ≤ 0 (resolution (contract, 2026-10-25); no primary month has either exactly 0, so the tie rule does not bind).

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.iod.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.irr_dmi` | IRR per +1 °C `dmi_3m` | IRR per °C | `04_secondary.R` | `irr_ci` | Supplement |
| `E.iod.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.irr_int` | IRR of the interaction `en_t × dmi_3m` | IRR per °C² | `04_secondary.R` | `irr_ci` | Supplement |
| `E.iod.n_months.{warm_pos,warm_neg,cool_pos,cool_neg}` | Primary months in each ENSO-phase × IOD-sign combination (sum 95) | n | `iod_counts()` | `int` | Supplement |

## 10. Distributed lag (49 keys)

Producer: `dlm_basis()`, `cross_basis()` and `dlm_curve()` in `secondary.R`, run by `04_secondary.R`. Exploratory, no verdict. Model T with `en_t` replaced by the cross-basis `en_cb1..en_cb3 = [en_t_l0..en_t_l6] %*% ns(0:6, df = 3, intercept = TRUE)`; `ln_t` stays at lag 0 (resolution (contract, 2026-10-25)); the time random-effect chain as Model T.

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.dlm.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.{lag0,lag1,lag2,lag3,lag4,lag5,lag6}` | IRR per +1 °C El Niño-phase ONI at lag k months, with the CI from `basis %*% V %*% t(basis)` | IRR per °C | `dlm_curve()` | `irr_ci` | Figure 4, Supplement |

## 11. Sensitivity analyses (112 keys)

Producer: `sens_case()` in `secondary.R`, run by `04_secondary.R`, except `roni` and `nino34` (`05_forecast.R`, Task 10). Each key is the Model T `en_t` IRR per +1 °C (`roni`: `en_roni`; `nino34`: `en_n34`) under the change listed, with the time random-effect chain and the step used in `description`. `roni` and `nino34` instead use exactly the step of the outcome's ONI Model T (`E.t.<I>.time_re`), with no further fallback, so they are the same fits as `E.idx.<I>.{roni,nino34}` (amendment 2026-10-25). No verdict. `SENS_IDS` plus `roni` and `nino34` equal the suffixes below.

| Suffix | Change from the primary Model T |
|---|---|
| `fy2021` | Through March 2021 (108 months), with `covid_mar2020` kept and `covid_fy2021` added (resolution (controller, 2026-10-24, F19)); the La Niña 2020–21 months enter through `ln_t`; IMI 3.0 (February–March 2021) is in `mi_round`. `not estimable (FY2020-21 <reason>)` if FY2020-21 is not final at the Task 9 sync (F3) |
| `comp075`, `comp000` | Outcome `<ind>_c75` (completeness ≥ 0.75) or `<ind>_c00` (no threshold) |
| `scaled` | Outcome `<ind>_scaled` (valid-district sum ÷ comp; spec §10.1) |
| `births` | Offset `log_births` (`log_preg` for ANC). SRS was not retrieved, so every outcome reads `not available (SRS not retrieved)` (resolution (controller, 2026-10-24, F23); F44) |
| `nosmall` | The seven small units (LD, CH, PY, DNH_DD, AN, SK, GA) dropped |
| `era_int` | The random intercept `(1 \| unit_era)` added (unit × format era intercepts). The `hmis_format2017` step is **kept**: a deliberate deviation from spec §5.9.5, which replaces the step (resolution (controller, 2026-10-24, F28)) |
| `ns2` | `t_c` removed from the fixed effects and `splines::ns(t_c, df = 2)` added; the random slope stays on `t_c` |
| `harmonic` | `unit_id:sin12` and `unit_id:cos12` added (unit × first harmonic) |
| `extra_prog` | `diwali` added for every outcome, `pmsma` for `anc_reg` only and `laqshya` for `inst_del` only (spec §5.1; F45) |
| `roni`, `nino34` | Model T with `en_roni`/`ln_roni` or `en_n34`/`ln_n34` in place of `en_t`/`ln_t`; IRR per +1 °C (the per-SD comparison is §13) |
| `drop_ep1415`, `drop_ep1819` | The months of that episode window dropped |
| `masklow` | Outcome `<ind>_masklow`: the default-kept plausibility lows also masked (resolution (controller, 2026-10-25, F41, F44)) |
| `allcomp` | Outcome `<ind>_allcomp`: every crosswalk component present (resolution (controller, 2026-10-25, F37, F44)). `diarr_u5` and `anc_reg` are single-item in every era, so their column equals the primary outcome: `not applicable (single-item indicator; identical to the primary analysis)` (resolution (contract, 2026-10-25)) |

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.sens.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.{fy2021,comp075,comp000,scaled,births,nosmall,era_int,ns2,harmonic,extra_prog,roni,nino34,drop_ep1415,drop_ep1819,masklow,allcomp}` | El Niño-term IRR per +1 °C under each sensitivity (table above) | IRR per °C | `04_secondary.R`; `roni`, `nino34`: `05_forecast.R` | `irr_ci`, or the fixed null displays above | Results ¶5, Supplement (sensitivity table) |

## 12. Forecast comparison (49 keys)

Producer: `fc_specs()`, `compare_models_m()` and `fc_rule()` in `models/E/R/forecast_e.R`, run by `05_forecast.R`. No verdict.
- **Models (spec §5.7).** A: `nb_spec(<ind>, fixed = c("moy", "t_c", <programme terms>, "log1p_<ind>_lag12"), slopes = "t_c", offset = "log_pop_days", trend_df = 0L)`; B: A + `spi3_dry_l0`, `spi3_wet_l0`, `heatwave_days_l0`; C: B + `en_t`, `ln_t`, `dmi_3m`. All three are scored on identical rows (33 units; the rows start in April 2013 because the lag-12 outcome needs the previous FY, resolution (plan, 2026-10-24)), with the lag-12 leakage buffer.
- **Splits.** LOEO: ep1415 (October 2014 to December 2016, 27 months) and ep1819 (September 2018 to February 2020, 18 months). Rolling origin: train on FYs ≤ t − 1, predict FY t, t = 2015-16 to 2019-20 (5 origins; the last scores April 2019 to February 2020).
- **Metric.** MALE (mean absolute log error, common `oos_metrics`) pooled over the scored rows of both LOEO folds. A model whose failed splits exceed 10% of evaluable splits reads `not estimated (>10% of refits failed)`, as does any difference involving it.

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.fc.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.{male_a,male_b,male_c}` | LOEO MALE of Models A, B and C | log-error units | `compare_models_m()` | `num3` | Table 4, Figure 5 |
| `E.fc.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.male_diff_c_b` | MALE_C − MALE_B, LOEO (negative = ENSO terms add skill) | log-error units | `05_forecast.R` | `num3s` | Results ¶4, Table 4, Figure 5 |
| `E.fc.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.male_diff_b_a` | MALE_B − MALE_A, LOEO (negative = local climate adds skill) | log-error units | `05_forecast.R` | `num3s` | Results ¶4, Table 4, Figure 5 |
| `E.fc.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.n_roll_c_better` | Rolling origins with per-origin MALE_C < MALE_B | n | `05_forecast.R` | `k_of_n` (`4 of 5`) | Results ¶4, Table 4 |
| `E.fc.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.rule` | The forecast rule; `description` gives the per-fold LOEO MALEs | text | `fc_rule()` | `adds skill over local climate` or `no added skill demonstrated` | Results ¶4, Discussion |

## 13. ENSO-index comparison (105 keys)

Producer: `index_effects()` in `forecast_e.R`, run by `05_forecast.R`; shape of Paper D's harvest (`data/derived/synthesis/index_effects_harvest.csv`, spec §8). No index is claimed to be superior.
- **Standardisation (resolution (controller, 2026-10-24, F7)).** `std_effect` is Model T refitted with that index's en/ln terms, reported as `exp(β × sd_index)` with Wald bounds `exp((β ∓ 1.959964 SE) × sd_index)`, where `sd_index` is the SD of the entered index over the 95 primary months (`E.exposure.oni_sd`, `roni_sd`, `nino34_sd`). It is never standardised by the SD of `en_t`.
- **Comparability (resolution (contract, 2026-10-25); amended 2026-10-25).** All three indices use the time random-effect step that the ONI Model T used for that outcome (`E.t.<I>.time_re`), with no further fallback, so the three fits share rows and structure. The `oni` fit is the primary Model T itself, so `E.idx.<I>.oni.std_effect` = `E.t.<I>.irr_en`^`oni_sd`; the `roni` and `nino34` fits are those of `E.sens.<I>.{roni,nino34}`, so `std_effect` = `sens`^`sd_index`.
  - Under the `ar1` or `iid` step: Wald `std_effect` and `se`, and `aic` from the fit.
  - Under the bootstrap step (all three indices bootstrapped, block 12, B = 1,000): `std_effect` takes the percentile bounds scaled by `sd_index`, `se` is the bootstrap SD of β × `sd_index`, and `aic` reads `not estimable (no likelihood under the block bootstrap)`.
  - If the step does not converge for RONI or Niño-3.4, that index's `std_effect`, `se` and `aic` (and its `E.sens` key) read `not estimable (<reason>)`.
- **Skill.** `male` and `log_score` are those of forecast Model C with that index's en/ln terms (and `dmi_3m`), pooled over the LOEO folds.

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.idx.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.{oni,roni,nino34}.std_effect` | El Niño-phase IRR per 1 SD of the index, lag 0 | IRR per SD | `index_effects()` | `irr_ci` | Results ¶4, Table 4 |
| `E.idx.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.{oni,roni,nino34}.se` | SE of `β × sd_index` (log scale) | log IRR per SD | `index_effects()` | `num3` | Table 4 |
| `E.idx.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.{oni,roni,nino34}.male` | LOEO MALE of Model C with the index | log-error units | `05_forecast.R` | `num3` | Table 4 |
| `E.idx.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.{oni,roni,nino34}.log_score` | LOEO mean NB negative log score of Model C with the index (lower is better) | nats per unit-month | `05_forecast.R` | `num3` | Table 4 |
| `E.idx.{diarr_u5,anc_reg,penta3,mcv1,fic,inst_del,opd}.{oni,roni,nino34}.aic` | AIC of the Model T refit with the index (same rows) | AIC | `index_effects()` | `fmt_num(x, 1)` | Table 4 |

## 14. Generated text (1 key)

Producer: `conclusion_sentence()` in `results_e.R`, called by `06_results.R`. A fixed template filled by code, so the manuscript states the verdicts exactly as `results.json` holds them.
- **No causal wording:** the sentence contains no "cause", "effect of", "impact", "led to", "reduce" or "kills".
- **No paper labels:** it never says "Paper A/B/C/D".
- **Stops:** `06_results.R` stops if an input key is missing, if a verdict is outside `consistent with` / `not consistent with`, or if a null display would be inserted. The template is total: verdict keys are never null (F18).

| Key | Meaning | Unit | Produced by | Display | Feeds |
|---|---|---|---|---|---|
| `E.abstract.conclusion_sentence` | One-sentence conclusion (template below) | text | `conclusion_sentence()` | text | Abstract |

`sentence = "In this state-month analysis of routine HMIS data from India, 2012–2020, the results were " + H7 + "; " + H8 + "; and " + H9 + "."`, where:
- `H7 = {E.h7.verdict} + " lower use of essential services during the El Niño phase" + FOR7`, with `FOR7 = " (" + {LIST7} + ")"` when `E.h7.verdict` is `consistent with`, else empty;
- `H8 = {E.h8.verdict} + " more reported diarrhoea in children under 5 years during the El Niño phase"`;
- `H9 = {E.h9.verdict} + " lower service use in state-months with more heatwave days or a rainfall deficit" + FOR9`, with `FOR9` built from the H9 verdicts as `FOR7`;
- `{LIST7}`, `{LIST9}`: the `{LIST}` of §3.

## 15. Resolutions recorded in this contract

**Plan (resolution (plan, 2026-10-24)).** One Holm family of 13 tests, with H8 on the Holm-adjusted p; not-estimable tests leave the family; episode IRRs from `en_ep1415`/`en_ep1819` with `en_other` in one model, on the LOEO windows; the time random-effect chain and the bootstrap p; the MDE rule and its display; the unit counts per model (32, 33, 34); the fixed vocabulary; the primary window ending in February 2020; the DMI 3-month mean; `S_z` over 32 units with ddof = 1; `t_c`; the Niño-3.4 SD taken from the data; the heterogeneity rule's (iii) as both drop-episode LRTs; `cum02` as the sum of the lag-0–2 coefficients; forecast rows from April 2013; frozen `models/common/R`.

**Controller (resolution (controller, F-number)).** 2026-10-24: F3 (FY2020-21 fallback), F7 (standardisation), F14 (IOD keys), F15 (single producer of `E.exposure.*`), F18 (not-estimable tests), F19 (`fy2021` COVID terms), F20 (key counts, no nesting), F23 (SRS), F28 (`era_int`). 2026-10-25: F33/F43 (state value), F35 (no differencing wording), F37 (substitute components), F41/F42 (plausibility), F44 (`masklow`, `allcomp`, `births`), F45 (programme terms; December 2014; `era_e2`), F46 (disclosure), F47 (symmetric `diarr_u5` MDE), F48 (mediation a-path covariates; deviation from spec §5.4).

**Contract (resolution (contract, 2026-10-25)), written blind to any HMIS estimate.** The `spi3_dry` display orientation; H7 condition (ii) when the episode model fails; the Model S reading for outcomes outside H7; the MDE caveat (per test, not Holm-adjusted); the same time structure in the heterogeneity LRT and in the index comparison (with `E.sens.<I>.{roni,nino34}`); the IOD sign rule at 0; `ln_t` at lag 0 in the distributed-lag model; `allcomp` not applicable to single-item indicators.

## 16. Key index by location

- **Abstract:** E.panel.n_units, E.panel.n_months, E.panel.n_state_months, E.comp.<I>.share_district_months_valid, E.exposure.n_en_months, E.t.<H>.irr_en, E.t.diarr_u5.irr_en, E.l.<H>.hw.irr, E.l.<H>.dry.irr, E.power.<H>.mde, E.med.<I>.prop, E.h7.verdict, E.h8.verdict, E.h9.verdict, E.abstract.conclusion_sentence
- **Methods:** E.status_date.*, E.break2017.*, E.exposure.*_sd, E.fy2021.status, E.s.n_units, E.l.n_units, E.power.n_sim, E.med.<I>.B, E.t.<I>.time_re
- **Results:** §1–§13 keys
- **Discussion:** E.h7.verdict_text, E.h9.verdict_text, E.s.<I>.reading, E.power.<I>.mde, E.fc.<I>.rule
- **Table 2:** E.panel.*, E.comp.*
- **Table 3:** E.t.*, E.h7.*, E.h8.verdict, E.h9.*, E.s.*, E.l.* (lag 0)
- **Table 4:** E.fc.*, E.idx.*
- **Figures:** 2 (E.comp.*), 3 (E.t, E.s, E.l lag 0), 4 (E.dlm.*), 5 (E.fc.*)
- **Supplement:** E.gates.*, E.sens.*, E.iod.*, E.het.*, E.power.<I>.p0*, E.l.<I>.*.cum02, E.l.<I>.tmax.irr, E.med.<I>.prop_unit, E.med.<I>.flag
