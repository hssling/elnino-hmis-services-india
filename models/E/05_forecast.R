# Paper E Task 10: forecast comparison (Models A/B/C) and the ENSO-index comparison (contract
# papers/E/results_keys.md §11 roni/nino34, §12, §13; spec §5.7 and §4; rulings F6, F7, F15, F52, F56).
#
# Run from <repo>/models, only after 02_primary.R has written papers/E/output/primary_estimates.csv with the F61
# optimiser limits and that file is committed in a commit after 257aacc (contract Amendment 3): the index comparison
# uses each outcome's ONI Model T time random-effect step. run_forecast() refuses to start otherwise
# (assert_primary_post_f61()).
#   Rscript E/05_forecast.R             # cores e_cores() (F54), re-checked before each block bootstrap; B = 1,000
#   --cores=N   --B=N   --draws=N (predictive draws, default 200)   --out-skill=PATH   --out-idx=PATH   --rds=PATH
#
# Forecast comparison (§12), per outcome not dropped by the 20% masking rule:
#   Models A, B, C = fc_specs(<ind>) (A: month of year as 11 numeric indicators moy_02..moy_12 (= factor moy with
#   January the reference; the frozen common linear_predictor() takes numeric fixed effects only), t_c, programme
#   terms, log1p_<ind>_lag12, unit random intercept and
#   trend slope, offset log_pop_days; B: A + spi3_dry_l0, spi3_wet_l0, heatwave_days_l0; C: B + en_t, ln_t, dmi_3m),
#   NB2 in glmmTMB through the common fit_nb(), scored with the common compare_models() / oos_metrics() through
#   compare_models_m(): one common-row set per design (complete on every model's variables: 33 units, rows from April
#   2013), the lag-12 leakage buffer, seeds SEED_E + i - 1 for split i, the >10% failed-split flag and the F6
#   scored-row intersection after pooling. LOEO (ep1415, ep1819) compares A, B, C, C_roni and C_nino34 (Model C with
#   RONI / Nino-3.4 terms: the §13 skill); the rolling origins FY2015-16 .. FY2019-20 compare A, B and C.
# Index comparison (§13 and E.sens.<I>.{roni,nino34}): Model T with en_roni/ln_roni or en_n34/ln_n34 in place of
#   en_t/ln_t, at exactly the time random-effect step of the outcome's ONI Model T (no further fallback). The ONI row
#   is the primary Model T itself (primary_estimates.csv), refitted at its ar1/iid step only to read its AIC (the
#   refit must reproduce the primary estimate). Under the block-bootstrap step the RONI and Nino-3.4 fits use the
#   same block_bootstrap_irr() resamples (seed SEED_E, B = 1,000, cores), and the ONI row is read from the primary
#   bootstrap. std_effect = exp(beta x sd_index), sd_index = the SD of the entered index series over the 95 primary
#   months (index_sd(); F7), written to index_comparison.csv for Task 11 (F15: E.exposure.* is panel_keys()'s).
# Every NB fit uses the F61 optimiser limits (e_glmmTMB_fit: nlminb iter.max = eval.max = 1e4; compare_models_m()
#   and index_effects() substitute it for the common default fitter).
# A genuine estimation failure is not estimable / not estimated; any other error stops the run (F56).
# Coefficients unidentified in a split's training fit (e.g. a programme step constant in training; set to 0 for
#   prediction by common rule P5) are logged per outcome x design x split to models/E/logs/forecast.log and named in
#   the description of E.fc.<I>.rule.
#
# Outputs:
#   papers/E/output/forecast_skill.csv: outcome, design (loeo / rolling), model (A, B, C, C_roni, C_nino34), split_id
#     ("pooled" = the scored rows of every split of the design; otherwise the fold / origin id: ep1415, ep1819,
#     fy2015 .. fy2019), male, rmse_log1p, log_score, coverage95, n (scored unit-months), n_failed_splits, n_splits
#     (evaluable splits), flag (NA, too_many_failed_fits, no_evaluable_splits). Pooled rows carry the counts and flag;
#     per-split rows exist only for scored (unflagged) models.
#   papers/E/output/index_comparison.csv (one row per outcome x index), Paper D's harvest convention
#     (data/derived/synthesis/index_effects_harvest.csv): paper (E), outcome, index (oni, roni, nino34), lag (0), term
#     (the en term), estimate, lo, hi (LOG scale, log IRR per +1 deg C: beta and its Wald or percentile bounds, as D's
#     harvest), scale (log_irr), ci_source (wald / bootstrap percentile), p, aic, skill_loeo_male, skill_roll_male,
#     skill_logscore (as D's harvest; skill_loeo_male / skill_logscore are LOEO pooled Model C with that index;
#     skill_roll_male is the rolling-origin pooled MALE of Model C for oni only and NA for roni and nino34, because
#     the contract's index skill (§13) is LOEO and the rolling design compares A, B and C with ONI only), then the E
#     columns: p_kind, beta_se (SE, or bootstrap SD, of beta), irr, irr_lo, irr_hi (exp scale, per +1 deg C),
#     sd_index (SD of the entered index over the 95 primary months; Task 11 reads it, F15), std_beta (beta x
#     sd_index), std_effect, std_lo, std_hi (exp scale, per SD), se (SE of beta x sd_index), aic_reason, time_re,
#     re_used, n, n_units, B_ok, status (ok / error / dropped), error. D's harvest columns not produced here:
#     skill_loeo_male_noenso, skill_roll_male_noenso, skill_basis, needs_refit, needs_refit_skill, source_key, tag
#     (Paper D's synthesis bookkeeping; Model B's MALE is in forecast_skill.csv).
#   models/E/_cache/forecast.rds (git-ignored): list(skill, idx, entries, compare (the compare_models_m results),
#     unidentified (outcome, design, model, split_id, unidentified, n_test_rows_nonzero_unidentified), settings,
#     runtime_min).
#   run_forecast() returns list(entries (the 168 contract keys this script owns), skill, idx, unidentified, provenance,
#     runtime_min).

if (!exists("MODELS_ROOT")) source("common/R/load.R")
if (!exists("E_DIR")) source(file.path(MODELS_ROOT, "E", "R", "common_e.R"))
source(file.path(MODELS_ROOT, "E", "02_primary.R"))      # monthly.R, power.R, verdicts.R, dropped_outcomes(), B_T, ...
source(file.path(MODELS_ROOT, "E", "R", "forecast_e.R"))

FORECAST_SCRIPT <- "models/E/05_forecast.R"
FC_N_DRAWS <- 200L
NOT_EST_FAILED <- "not estimated (>10% of refits failed)"
FC_MODEL_TEXT <- c(A = "Model A (month of year as 11 indicators moy_02..moy_12 + t_c + programme terms + log1p_<ind>_lag12)",
                   B = "Model B (Model A + spi3_dry_l0 + spi3_wet_l0 + heatwave_days_l0)",
                   C = "Model C (Model B + en_t + ln_t + dmi_3m)",
                   C_roni = "Model C with RONI (Model B + en_roni + ln_roni + dmi_3m)",
                   C_nino34 = "Model C with Nino-3.4 (Model B + en_n34 + ln_n34 + dmi_3m)")
FC_INDEX_LABEL <- c(oni = "traditional ONI", roni = "RONI", nino34 = "Nino-3.4 (nino34_3m)")

# The contract keys this script owns: §12 (E.fc.*), §13 (E.idx.*) and E.sens.<I>.{roni,nino34} (168 keys).
forecast_contract_keys <- function(path = file.path(PAPER_E, "results_keys.md")) {
  k <- contract_keys(path, prefix = "E")
  k[grepl("^E\\.(fc|idx)\\.", k) | grepl("^E\\.sens\\.[^.]+\\.(roni|nino34)$", k)]
}

.flag_text <- function(flag) if (identical(flag, "no_evaluable_splits")) "not estimated (no evaluable splits)" else NOT_EST_FAILED

# ---- results keys -------------------------------------------------------------------------------------------------

# The 168 entries from the skill table (forecast_skill.csv layout) and the index table (index_comparison.csv
# layout, before the harvest columns). An outcome in `dropped` reads not estimable (dropped: ...) in every key.
forecast_entries <- function(skill, idx, dropped = character(), script = FORECAST_SCRIPT, B = B_T, n_draws = FC_N_DRAWS,
                             unidentified = NULL) {
  un <- if (is.null(unidentified)) data.table::data.table(outcome = character(), design = character()) else
    data.table::as.data.table(unidentified)
  sk <- data.table::as.data.table(skill)
  ix <- data.table::as.data.table(idx)
  E <- list()
  put <- function(k, value, display, description) E[[k]] <<- res_entry(value, display, script, description)
  pooled <- function(o, des, m) {
    r <- sk[outcome == o & design == des & model == m & split_id == "pooled"]
    if (nrow(r) != 1L) stop(sprintf("forecast_entries: %d pooled rows for %s %s %s", nrow(r), o, des, m), call. = FALSE)
    r
  }
  splits_of <- function(o, des, m) sk[outcome == o & design == des & model == m & split_id != "pooled"]
  per_split_text <- function(o, des, m) {
    s <- splits_of(o, des, m)
    if (!nrow(s)) return("none scored")
    paste(sprintf("%s %s", s$split_id, vapply(s$male, .s6, "")), collapse = ", ")
  }
  draws_text <- sprintf("NB2 (glmmTMB, fit_nb chain us -> diag -> int), %d predictive draws per split, seeds SEED_E + i - 1 = %d + i - 1, lag-12 leakage buffer",
                        as.integer(n_draws), SEED_E)
  for (o in INDS) {
    fc_keys <- sprintf("E.fc.%s.%s", o, c("male_a", "male_b", "male_c", "male_diff_c_b", "male_diff_b_a", "n_roll_c_better", "rule"))
    idx_keys <- as.vector(outer(sprintf("E.idx.%s.%s", o, FC_INDICES), c("std_effect", "se", "male", "log_score", "aic"), paste, sep = "."))
    sens_keys <- sprintf("E.sens.%s.%s", o, c("roni", "nino34"))
    if (o %in% dropped) {
      for (k in c(fc_keys, idx_keys, sens_keys))
        put(k, NA, not_estimable(DROPPED_REASON), sprintf("%s: %s was dropped by the 20%% masking rule (gate_summary.csv, scope primary); not fitted", k, o))
      next
    }

    # §12 forecast comparison
    loeo_desc <- function(m) {
      r <- pooled(o, "loeo", m)
      sprintf("LOEO MALE of %s for %s, pooled over the scored rows of both folds (ep1415 Oct 2014 to Dec 2016, ep1819 Sep 2018 to Feb 2020; rows common to Models A, B, C, C_roni and C_nino34): %s scored unit-months; MALE = %s; per fold: %s; %d of %d evaluable splits failed; %s",
              sub("<ind>", o, FC_MODEL_TEXT[[m]], fixed = TRUE), o, fmt_int(r$n), .s6(r$male), per_split_text(o, "loeo", m),
              r$n_failed_splits, r$n_splits, draws_text)
    }
    for (m in c("A", "B", "C")) {
      r <- pooled(o, "loeo", m)
      k <- sprintf("E.fc.%s.male_%s", o, tolower(m))
      if (is.na(r$flag)) put(k, r$male, fmt_num(r$male, 3), loeo_desc(m))
      else put(k, NA, .flag_text(r$flag), loeo_desc(m))
    }
    diff_key <- function(k, m1, m0, what) {
      r1 <- pooled(o, "loeo", m1); r0 <- pooled(o, "loeo", m0)
      desc <- sprintf("%s, LOEO pooled (%s): MALE_%s %s minus MALE_%s %s", what, o, m1, .s6(r1$male), m0, .s6(r0$male))
      if (!is.na(r1$flag) || !is.na(r0$flag))
        return(put(k, NA, .flag_text(if (!is.na(r1$flag)) r1$flag else r0$flag), desc))
      v <- r1$male - r0$male
      put(k, v, fmt_num(v, 3, plus = TRUE), sprintf("%s = %s", desc, .s6(v)))
    }
    diff_key(sprintf("E.fc.%s.male_diff_c_b", o), "C", "B", "MALE_C - MALE_B (negative = the ENSO terms add skill)")
    diff_key(sprintf("E.fc.%s.male_diff_b_a", o), "B", "A", "MALE_B - MALE_A (negative = local climate adds skill)")
    rb <- pooled(o, "rolling", "B"); rc <- pooled(o, "rolling", "C")
    roll_rows <- rbind(splits_of(o, "rolling", "B"), splits_of(o, "rolling", "C"))[, list(model, split_id, male)]
    loeo_rows <- rbind(splits_of(o, "loeo", "B"), splits_of(o, "loeo", "C"))[, list(model, split_id, male)]
    roll_desc <- sprintf("Rolling origins FY2015-16 to FY2019-20 (train on FYs <= t - 1, predict FY t; %s): per-origin MALE of Model B: %s; Model C: %s; %s",
                         o, per_split_text(o, "rolling", "B"), per_split_text(o, "rolling", "C"), draws_text)
    k <- sprintf("E.fc.%s.n_roll_c_better", o)
    if (!is.na(rb$flag) || !is.na(rc$flag)) {
      put(k, NA, .flag_text(if (!is.na(rc$flag)) rc$flag else rb$flag), roll_desc)
    } else {
      cnt <- fc_counts(roll_rows)
      put(k, cnt$n_roll_better, sprintf("%d of %d", cnt$n_roll_better, cnt$n_roll),
          sprintf("Rolling origins with per-origin MALE_C < MALE_B: %d of %d. %s", cnt$n_roll_better, cnt$n_roll, roll_desc))
    }
    rule <- fc_rule(rbind(loeo_rows, roll_rows))
    cl <- fc_counts(rbind(loeo_rows, roll_rows))
    put(sprintf("E.fc.%s.rule", o), rule, rule, paste0(
        sprintf("Forecast rule (spec 5.7; no verdict): Model C adds skill over local climate iff MALE_C < MALE_B in both LOEO folds and in at least 4 of 5 rolling origins; low-powered with 2 folds. %s: per-fold LOEO MALE A: %s; B: %s; C: %s; C < B in folds: %s; rolling origins with C < B: %d of %d (a flagged model has no per-split MALE and is never lower)",
                o, per_split_text(o, "loeo", "A"), per_split_text(o, "loeo", "B"), per_split_text(o, "loeo", "C"),
                paste(sprintf("%s %s", names(cl$loeo_better), cl$loeo_better), collapse = ", "), cl$n_roll_better, cl$n_roll),
                sprintf(". Coefficients unidentified in training and set to 0 for prediction (common rule P5): LOEO: %s; rolling: %s",
                        fc_unidentified_text(un[outcome == o & design == "loeo"]),
                        fc_unidentified_text(un[outcome == o & design == "rolling"]))))

    # §13 index comparison and E.sens.<I>.{roni,nino34}
    for (ki in FC_INDICES) {
      r <- ix[outcome == o & index == ki]
      if (nrow(r) != 1L) stop(sprintf("forecast_entries: %d index rows for %s %s", nrow(r), o, ki), call. = FALSE)
      ok <- identical(r$status, "ok") && !is.na(r$beta)
      reason <- if (!is.na(r$error)) r$error else "estimate missing"
      boot <- identical(r$p_kind, "bootstrap")
      fit_text <- sprintf("Model T for %s with the %s terms %s/%s in place of en_t/ln_t (%s); time random effect: the step of the outcome's ONI Model T, %s, no further fallback; unit random effect %s; %s unit-months, %s units",
                          o, FC_INDEX_LABEL[[ki]], FC_INDEX_TERMS[[ki]][1], FC_INDEX_TERMS[[ki]][2],
                          if (ki == "oni") "the primary Model T itself" else "a refit",
                          if (is.na(r$time_re)) "none" else r$time_re, if (is.na(r$re_used)) "none" else r$re_used,
                          if (is.na(r$n)) "NA" else fmt_int(r$n), if (is.na(r$n_units)) "NA" else r$n_units)
      est_text <- if (ok) sprintf("beta (log IRR per +1 deg C) = %s, %s = %s; sd_index = %s (SD of %s over the 95 primary months); beta x sd_index = %s; per-SD IRR %s (%s %s to %s)%s",
                                  .s6(r$beta), if (boot) "bootstrap SD" else "SE", .s6(r$beta_se), .s6(r$sd_index),
                                  FC_INDEX_SERIES[[ki]], .s6(r$std_beta), .s6(r$std_effect),
                                  if (boot) "percentile 95% CI" else "Wald 95% CI", .s6(r$std_lo), .s6(r$std_hi),
                                  if (boot) sprintf("; block bootstrap, block 12, %d of %d resamples succeeded, seeds SEED_E + i - 1 = %d + i - 1", r$B_ok, B, SEED_E) else "")
                  else not_estimable(reason)
      base <- sprintf("E.idx.%s.%s", o, ki)
      if (ok) {
        put(paste0(base, ".std_effect"), r$std_effect, fmt_ci(r$std_effect, r$std_lo, r$std_hi, 2),
            sprintf("El Nino-phase IRR per 1 SD of %s, lag 0, exp(beta x sd_index). %s; %s", FC_INDEX_LABEL[[ki]], fit_text, est_text))
        put(paste0(base, ".se"), r$se, fmt_num(r$se, 3),
            sprintf("SE of beta x sd_index (log scale)%s. %s; %s", if (boot) ", the bootstrap SD of beta times sd_index" else "", fit_text, est_text))
        if (boot) put(paste0(base, ".aic"), NA, not_estimable(NO_LIKELIHOOD),
                      sprintf("AIC of the Model T fit with %s: %s. %s", FC_INDEX_LABEL[[ki]], not_estimable(NO_LIKELIHOOD), fit_text))
        else put(paste0(base, ".aic"), r$aic, fmt_num(r$aic, 1),
                 sprintf("AIC of the Model T fit with %s = %s (same rows for the three indices). %s", FC_INDEX_LABEL[[ki]], .s6(r$aic), fit_text))
      } else {
        for (s in c(".std_effect", ".se", ".aic"))
          put(paste0(base, s), NA, not_estimable(reason), sprintf("%s: %s. %s", paste0(base, s), not_estimable(reason), fit_text))
      }
      cm <- if (ki == "oni") "C" else paste0("C_", ki)
      pc <- pooled(o, "loeo", cm)
      sk_desc <- sprintf("Forecast %s for %s, LOEO pooled over both folds: %s scored unit-months; MALE = %s, mean NB negative log score = %s nats per unit-month; per fold MALE: %s; %s",
                         FC_MODEL_TEXT[[cm]], o, fmt_int(pc$n), .s6(pc$male), .s6(pc$log_score), per_split_text(o, "loeo", cm), draws_text)
      if (is.na(pc$flag)) {
        put(paste0(base, ".male"), pc$male, fmt_num(pc$male, 3), sk_desc)
        put(paste0(base, ".log_score"), pc$log_score, fmt_num(pc$log_score, 3), sk_desc)
      } else {
        put(paste0(base, ".male"), NA, .flag_text(pc$flag), sk_desc)
        put(paste0(base, ".log_score"), NA, .flag_text(pc$flag), sk_desc)
      }
      if (ki != "oni") {
        k <- sprintf("E.sens.%s.%s", o, ki)
        if (ok) put(k, r$irr, fmt_ci(r$irr, r$lo, r$hi, 2),
                    sprintf("Sensitivity %s: Model T IRR per +1 deg C of %s (%s, %s). %s; %s; p = %s (%s)", ki, FC_INDEX_TERMS[[ki]][1],
                            if (boot) "percentile 95% CI" else "Wald 95% CI", "same fit as E.idx", fit_text, est_text, .s6(r$p),
                            if (boot) "two-sided bootstrap p" else "two-sided Wald"))
        else put(k, NA, not_estimable(reason), sprintf("Sensitivity %s: %s. %s", ki, not_estimable(reason), fit_text))
      }
    }
  }
  E[order(names(E), method = "radix")]
}

# ---- tables -------------------------------------------------------------------------------------------------------

# Skill rows of one compare_models_m() result (forecast_skill.csv layout).
skill_rows <- function(o, design, cm) {
  p <- cm$summary[, list(outcome = o, design = design, model, split_id = "pooled", male, rmse_log1p, log_score,
                         coverage95, n = as.integer(n), n_failed_splits, n_splits, flag)]
  s <- cm$split_metrics[, list(outcome = o, design = design, model, split_id, male, rmse_log1p, log_score, coverage95,
                               n = as.integer(n), n_failed_splits = NA_integer_, n_splits = NA_integer_, flag = NA_character_)]
  data.table::rbindlist(list(p, s))
}

# index_comparison.csv (columns in the header above): Paper D's harvest convention, so estimate, lo and hi are on the
# LOG scale (beta and its bounds per +1 deg C) and the IRR-scale values are irr, irr_lo and irr_hi. The index rows
# (index_effects() layout) carry lo/hi on the IRR scale; they are renamed here.
index_comparison_table <- function(idx, skill) {
  ix <- data.table::copy(data.table::as.data.table(idx))
  cm <- c(oni = "C", roni = "C_roni", nino34 = "C_nino34")
  sk <- data.table::as.data.table(skill)
  loeo <- sk[design == "loeo" & split_id == "pooled", list(outcome, model, skill_loeo_male = male, skill_logscore = log_score)]
  roll <- sk[design == "rolling" & split_id == "pooled" & model == "C", list(outcome, skill_roll_male_c = male)]
  ix[, model := cm[index]]
  ix <- merge(ix, loeo, by = c("outcome", "model"), all.x = TRUE, sort = FALSE)
  ix <- merge(ix, roll, by = "outcome", all.x = TRUE, sort = FALSE)
  data.table::setnames(ix, c("lo", "hi"), c("irr_lo", "irr_hi"))
  ix[, `:=`(paper = "E", lag = 0L, estimate = beta, lo = log(irr_lo), hi = log(irr_hi), scale = "log_irr",
            skill_roll_male = data.table::fifelse(index == "oni", skill_roll_male_c, NA_real_),
            ci_source = data.table::fifelse(p_kind %in% "bootstrap", "bootstrap percentile",
                                            data.table::fifelse(p_kind %in% "wald", "wald", NA_character_)))]
  cols <- c("paper", "outcome", "index", "lag", "term", "estimate", "lo", "hi", "scale", "ci_source", "p", "aic",
            "skill_loeo_male", "skill_roll_male", "skill_logscore", "p_kind", "beta_se", "irr", "irr_lo", "irr_hi",
            "sd_index", "std_beta", "std_effect", "std_lo", "std_hi", "se", "aic_reason", "time_re", "re_used", "n",
            "n_units", "B_ok", "status", "error")
  ix <- ix[order(match(outcome, INDS), match(index, FC_INDICES)), ..cols]
  ix[]
}

# ---- run ----------------------------------------------------------------------------------------------------------

.e_forecast_init <- function(root) {
  loadNamespace("data.table")       # a data.table shipped before the namespace is loaded would index as a data.frame
  source(file.path(root, "E", "05_forecast.R"))
  invisible(TRUE)
}

# One parallel task: a compare_models_m() run (kind "fc", design loeo / rolling) or an index refit at an ar1/iid step
# (kind "idx"); logged to forecast.log.
.e_forecast_task <- function(task) {
  d <- data.table::copy(get(".E_FC_DATA", envir = globalenv()))       # a valid data.table on the worker
  t0 <- Sys.time()
  r <- if (task$kind == "fc") {
    if (task$design == "loeo") compare_models_m(fc_specs_loeo(task$ind), d, loeo_month_splits(), lag = 12L,
                                                n_draws = task$n_draws, seed = SEED_E)
    else compare_models_m(fc_specs(task$ind), d, rolling_splits_fy(d$ym, fy_start_of(d$ym)), lag = 12L,
                          n_draws = task$n_draws, seed = SEED_E)
  } else index_effects(d, task$ind, task$index, task$time_re, sd_index = task$sd_index)
  elog(sprintf("%s %s %s: done in %.1f min", task$ind, task$kind, if (task$kind == "fc") task$design else task$index,
               as.numeric(difftime(Sys.time(), t0, units = "mins"))), file = "forecast.log")
  r
}

# Amendment 3 / F61 ordering: the primary estimates used must come from the rerun with the optimiser limits, i.e.
# papers/E/output/primary_estimates.csv is tracked, has no uncommitted change, and was committed in a commit after
# 257aacc (the Amendment 3 contract commit). git(args) as .git_repo() (02_primary.R), injectable for tests. Returns the
# last such commit.
assert_primary_post_f61 <- function(path = "papers/E/output/primary_estimates.csv", after = "257aacc", git = .git_repo) {
  if (!length(git(c("ls-files", "--", path)))) stop("run_forecast: ", path, " is not committed", call. = FALSE)
  if (length(git(c("status", "--porcelain", "--", path))))
    stop("run_forecast: ", path, " has uncommitted changes", call. = FALSE)
  later <- git(c("log", shQuote("--format=%h %ci %s"), paste0(after, "..HEAD"), "--", path))
  if (!length(later))
    stop("run_forecast: ", path, " was not committed after ", after, " (contract Amendment 3, F61): rerun 02_primary.R ",
         "with the optimiser limits and commit its estimates first", call. = FALSE)
  sprintf("%s committed after %s (last: %s)", path, after, later[1])
}

run_forecast <- function(cores = NULL, primary_csv = file.path(E_OUT, "primary_estimates.csv"),
                         out_skill = file.path(E_OUT, "forecast_skill.csv"),
                         out_idx = file.path(E_OUT, "index_comparison.csv"), rds = file.path(E_CACHE, "forecast.rds"),
                         gate_csv = GATE_SUMMARY_CSV, contract = file.path(PAPER_E, "results_keys.md"), B = B_T,
                         n_draws = FC_N_DRAWS, write = TRUE, d = NULL, check_primary = assert_primary_post_f61) {
  if (!file.exists(primary_csv))
    stop("run_forecast: ", primary_csv, " (primary_estimates.csv) does not exist: the index comparison uses the time ",
         "random-effect step of each outcome's ONI Model T (contract §13), so 02_primary.R must run first", call. = FALSE)
  provenance <- check_primary()
  t0 <- Sys.time()
  # cores NULL: e_cores() now, and again before each block bootstrap (it rises when the power run ends)
  cores_fun <- if (is.null(cores)) function() e_cores() else { cores <- as.integer(cores); function() cores }
  cores <- cores_fun()
  if (is.null(d)) d <- read_hmis_model("primary")
  d <- add_moy_dummies(d)
  dropped <- intersect(INDS, dropped_outcomes(gate_csv))
  live <- setdiff(INDS, dropped)
  prim <- data.table::fread(primary_csv, na.strings = c("", "NA"))
  prow <- function(o) {
    r <- prim[outcome == o & model == "T" & term == "en_t"]
    if (nrow(r) != 1L) stop(sprintf("run_forecast: %d Model T en_t rows for %s in %s", nrow(r), o, primary_csv), call. = FALSE)
    r
  }
  sds <- vapply(FC_INDICES, function(k) index_sd(d, k), 0)
  elog(sprintf("run_forecast: primary estimates %s", provenance), file = "forecast.log")
  elog(sprintf("run_forecast: start; cores %d; B %d; draws %d; dropped: %s; sd_index oni %.4f, roni %.4f, nino34 %.4f",
               cores, B, n_draws, if (length(dropped)) paste(dropped, collapse = ", ") else "none",
               sds[["oni"]], sds[["roni"]], sds[["nino34"]]), file = "forecast.log")

  tasks <- list()
  for (o in live) {
    tasks <- c(tasks, list(list(kind = "fc", ind = o, design = "loeo", n_draws = n_draws),
                           list(kind = "fc", ind = o, design = "rolling", n_draws = n_draws)))
    pr <- prow(o)
    if (identical(pr$status, "ok") && pr$time_re %in% names(TIME_RE))
      for (k in FC_INDICES) tasks <- c(tasks, list(list(kind = "idx", ind = o, index = k, time_re = pr$time_re,
                                                        sd_index = sds[[k]])))
  }
  if (cores > 1L && length(tasks)) {
    cl <- .e_cluster(min(cores, length(tasks)))
    res <- tryCatch({
      parallel::clusterCall(cl, .e_forecast_init, MODELS_ROOT)
      parallel::clusterCall(cl, .e_set_global, ".E_FC_DATA", d)
      parallel::clusterApplyLB(cl, tasks, .e_forecast_task)
    }, finally = parallel::stopCluster(cl))
  } else {
    assign(".E_FC_DATA", d, envir = globalenv())
    res <- lapply(tasks, .e_forecast_task)
  }
  names(res) <- vapply(tasks, function(t) paste(t$ind, t$kind, if (t$kind == "fc") t$design else t$index), "")

  skill <- list(); idx <- list(); compare <- list(); unident <- list()
  for (o in live) {
    for (des in c("loeo", "rolling")) {
      cm <- res[[paste(o, "fc", des)]]
      compare[[paste(o, des)]] <- cm
      skill[[paste(o, des)]] <- skill_rows(o, des, cm)
      u <- fc_unidentified(cm)
      unident[[paste(o, des)]] <- cbind(data.table::data.table(outcome = rep(o, nrow(u)), design = rep(des, nrow(u))), u)
      for (i in seq_len(nrow(u)))
        elog(sprintf("%s %s split %s model %s: unidentified in training, set to 0 for prediction (common P5): %s; %d test rows non-zero",
                     o, des, u$split_id[i], u$model[i], u$unidentified[i], u$n_test_rows_nonzero_unidentified[i]),
             file = "forecast.log")
    }
    pr <- prow(o)
    oni_refit <- res[[paste(o, "idx oni")]]
    if (!is.null(oni_refit)) {
      # the ONI refit at the primary step must reproduce the primary Model T estimate (contract §13: the oni fit is
      # the primary Model T itself)
      if (!identical(oni_refit$status, "ok") || abs(oni_refit$beta - pr$est) > 1e-4 * pr$se)
        stop(sprintf("run_forecast: the ONI refit for %s (%s, beta %s) does not reproduce the primary Model T (beta %s)",
                     o, oni_refit$status, .s6(oni_refit$beta), .s6(pr$est)), call. = FALSE)
      rows <- list(oni = index_effect_from_primary(pr, sds[["oni"]], aic = oni_refit$aic),
                   roni = res[[paste(o, "idx roni")]], nino34 = res[[paste(o, "idx nino34")]])
    } else if (identical(pr$status, "ok") && identical(pr$time_re, "block_bootstrap")) {
      rows <- list(oni = index_effect_from_primary(pr, sds[["oni"]]))
      for (k in c("roni", "nino34")) {
        cores <- cores_fun()               # re-checked before each bootstrap (it rises when the power run ends)
        elog(sprintf("%s idx %s: block bootstrap at the ONI Model T step, B = %d, %d cores", o, k, B, cores), file = "forecast.log")
        rows[[k]] <- index_effects(d, o, k, "block_bootstrap", sd_index = sds[[k]], B = B, cores = cores,
                                   progress = boot_progress_logger(paste(o, "idx", k), log_fun = function(...) elog(..., file = "forecast.log")))
      }
    } else {
      # Model T not estimated: every index row carries its reason (F58 pattern)
      oni <- index_effect_from_primary(pr, sds[["oni"]])
      rows <- list(oni = oni)
      for (k in c("roni", "nino34"))
        rows[[k]] <- .idx_row(o, k, sds[[k]], NA_character_, oni$status, oni$error)
    }
    ns <- unique(stats::na.omit(vapply(rows, function(r) if (identical(r$status, "ok")) as.numeric(r$n) else NA_real_, 0)))
    if (length(ns) > 1L)
      stop(sprintf("run_forecast: the index fits for %s use different rows (n = %s)", o, paste(ns, collapse = ", ")), call. = FALSE)
    idx[[o]] <- data.table::rbindlist(rows[FC_INDICES], fill = TRUE)
  }
  skill <- data.table::rbindlist(skill)
  idx <- data.table::rbindlist(idx, fill = TRUE)
  unident <- data.table::rbindlist(unident)
  entries <- forecast_entries(skill, idx, dropped, B = B, n_draws = n_draws, unidentified = unident)
  want <- forecast_contract_keys(contract)
  if (!setequal(names(entries), want))
    stop("run_forecast: keys differ from the contract: missing ", paste(setdiff(want, names(entries)), collapse = ", "),
         "; extra ", paste(setdiff(names(entries), want), collapse = ", "), call. = FALSE)
  idx_out <- index_comparison_table(idx, skill)
  runtime <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
  if (write) {
    for (p in c(out_skill, out_idx, rds)) dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
    data.table::fwrite(skill, out_skill, eol = "\n")
    data.table::fwrite(idx_out, out_idx, eol = "\n")
    saveRDS(list(skill = skill, idx = idx_out, entries = entries, compare = compare, unidentified = unident,
                 runtime_min = runtime, settings = list(cores = cores, B = B, n_draws = n_draws, seed = SEED_E,
                                                        dropped = dropped, sd_index = sds, primary = provenance)),
            rds)
    elog(sprintf("run_forecast: wrote %s, %s and %s (%d keys) in %.1f min", out_skill, out_idx, rds, length(entries), runtime),
         file = "forecast.log")
  }
  list(entries = entries, skill = skill, idx = idx_out, unidentified = unident, provenance = provenance,
       runtime_min = runtime)
}

forecast_main <- function(args = commandArgs(trailingOnly = TRUE)) {
  opt <- function(name, default) {
    v <- sub(sprintf("^--%s=", name), "", grep(sprintf("^--%s=", name), args, value = TRUE))
    if (length(v)) v[length(v)] else default
  }
  cores <- opt("cores", NA_character_)
  r <- run_forecast(cores = if (is.na(cores)) NULL else as.integer(cores), B = as.integer(opt("B", B_T)),
                    n_draws = as.integer(opt("draws", FC_N_DRAWS)),
                    out_skill = opt("out-skill", file.path(E_OUT, "forecast_skill.csv")),
                    out_idx = opt("out-idx", file.path(E_OUT, "index_comparison.csv")),
                    rds = opt("rds", file.path(E_CACHE, "forecast.rds")))
  for (o in INDS) {
    v <- vapply(c("male_diff_c_b", "male_diff_b_a", "n_roll_c_better", "rule"),
                function(k) r$entries[[sprintf("E.fc.%s.%s", o, k)]]$display, "")
    elog(sprintf("%s: C - B %s; B - A %s; rolling C better %s; rule: %s", o, v[1], v[2], v[3], v[4]), file = "forecast.log")
  }
  invisible(r)
}

if (sys.nframe() == 0L) invisible(forecast_main())
