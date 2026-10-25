# Paper E Task 10: forecast comparison (Models A/B/C, spec §5.7) and the ENSO-index comparison (spec §4/§8)
# (contract papers/E/results_keys.md §11 roni/nino34, §12, §13; rulings F6, F7, F15, F52, F56). Sourced after
# common/R/load.R, common_e.R, monthly.R and verdicts.R (05_forecast.R does this). models/common/R is frozen: the
# monthly comparison calls the common compare_models() unchanged, once per split, and pools the splits here.
#
# The year-month index `ym` = year * 12 + month - 1 (hmis_model.csv), so ym - 12 is the same month a year earlier.

FC_LOEO_IDS <- c("ep1415", "ep1819")
FC_LOCAL <- c("spi3_dry_l0", "spi3_wet_l0", "heatwave_days_l0")
FC_INDEX_TERMS <- list(oni = c("en_t", "ln_t"), roni = c("en_roni", "ln_roni"), nino34 = c("en_n34", "ln_n34"))
FC_INDEX_SERIES <- c(oni = "oni", roni = "roni", nino34 = "nino34_3m")      # the entered index series (SD source)
FC_INDICES <- names(FC_INDEX_TERMS)
FC_RULE_YES <- "adds skill over local climate"
FC_RULE_NO <- "no added skill demonstrated"
NO_LIKELIHOOD <- "no likelihood under the block bootstrap"
# Month of year enters the forecast models as 11 numeric indicators (January the reference): the same model as the
# factor `moy` under treatment contrasts, but the frozen common linear_predictor() (used by compare_models() to
# predict test rows) supports numeric fixed effects only.
MOY_DUMMIES <- sprintf("moy_%02d", 2:12)
Z95 <- 1.959964

.ym_of <- function(year, month) as.integer(year) * 12L + as.integer(month) - 1L

# Start year of the Indian financial year (April-March) of each ym: April 2015 .. March 2016 -> 2015.
fy_start_of <- function(ym) (as.integer(ym) - 3L) %/% 12L

# ---- splits ---------------------------------------------------------------------------------------------------------

# The two LOEO folds (contract §12): ep1415 = October 2014 .. December 2016 (27 months), ep1819 = September 2018 ..
# February 2020 (18 months). test_years holds ym values (compare_models_m sets year := ym).
loeo_month_splits <- function() {
  list(list(id = "ep1415", test_years = .ym_of(2014, 10):.ym_of(2016, 12)),
       list(id = "ep1819", test_years = .ym_of(2018, 9):.ym_of(2020, 2)))
}

# Rolling origins (contract §12): per FY t >= first_test present in the data, test_years = the ym values of FY t,
# train_max = the last ym of FY t - 1 (March of calendar year t). ids "fy<t>".
rolling_splits_fy <- function(ym, fy_start_year, first_test = 2015L) {
  ym <- as.integer(ym); fy <- as.integer(fy_start_year)
  if (length(ym) != length(fy)) stop("rolling_splits_fy: ym and fy_start_year must have the same length", call. = FALSE)
  if (anyNA(ym) || anyNA(fy)) stop("rolling_splits_fy: ym and fy_start_year must not be NA", call. = FALSE)
  ts <- sort(unique(fy[fy >= as.integer(first_test)]))
  lapply(ts, function(t) list(id = sprintf("fy%d", t), test_years = sort(unique(ym[fy == t])), train_max = .ym_of(t, 3)))
}

# The lag leakage buffer: a training row (ym outside test_ym) whose ym - lag is a test month carries that test
# month's outcome in its lagged-outcome covariate, so it is dropped. Test rows are never dropped.
drop_lag_leak <- function(d, test_ym, lag = 12L) {
  d <- data.table::as.data.table(d)
  d[!(!(ym %in% test_ym) & (ym - as.integer(lag)) %in% test_ym)]
}

# Adds the month-of-year indicator columns MOY_DUMMIES (moy_02 .. moy_12 = 1 in that calendar month) from `moy`
# (a factor with levels 1..12 or an integer); a missing moy stays missing.
add_moy_dummies <- function(d) {
  d <- data.table::copy(data.table::as.data.table(d))
  m <- as.integer(as.character(d$moy))
  if (any(!is.na(m) & !m %in% 1:12)) stop("add_moy_dummies: moy must lie in 1..12", call. = FALSE)
  for (k in 2:12) data.table::set(d, j = sprintf("moy_%02d", k), value = as.integer(m == k))
  d[]
}

# ---- the monthly model comparison ----------------------------------------------------------------------------------

# F56: a failed split counts as a failed fit (common >10% rule) only for a genuine estimation failure. Fit-stage
# errors must be estimation failures (is_estimation_failure(), e.g. "fit_nb: no structure converged"); a draw-stage
# error (the joint precision of a converged fit cannot be used for the predictive draws) is numerical and counts as
# one. Anything else stops the run.
stop_non_estimation <- function(fail_reasons) {
  fr <- data.table::as.data.table(fail_reasons)
  if (!nrow(fr)) return(invisible(NULL))
  bad <- fr[stage != "draw" & !vapply(error, is_estimation_failure, NA)]
  if (nrow(bad))
    stop(sprintf("compare_models_m: a split error is not an estimation failure (model %s, split %s, stage %s): %s",
                 bad$model[1], bad$split_id[1], bad$stage[1], first_line(bad$error[1])), call. = FALSE)
  invisible(NULL)
}

# Nested comparison on a monthly panel (contract §12; brief Task 10; ruling F6). For split i: copy the data with
# year := ym, drop the training rows whose ym - lag is in the test set (drop_lag_leak), and call the common
# compare_models(specs, d_i, list(split_i), n_draws, seed + i - 1) (so split i uses the seed the common all-splits
# call would give it). The specs' log1p_<ind>_lag12 does not match the common lag-1 pattern, so the common buffer
# stays off and this one applies. Then pool: a model whose failed splits exceed 10% of its evaluable splits is
# flagged ("too_many_failed_fits"; "no_evaluable_splits" if all were skipped) with NA metrics; `scored` is
# recomputed as the intersection of (split_id, unit_id, ym) over the unflagged models (F6: a split failed by any one
# of them is unscored for all); summary and split_metrics are computed with common oos_metrics on scored rows.
# Returns list(summary (model, male, rmse_log1p, log_score, coverage95, n, n_failed_splits, flag, n_splits,
# n_unscored_other_model), per_split (model, split_id, unit_id, year (= ym), ym, y, mu, lo, hi, theta, scored),
# split_metrics (model, split_id, metrics), fail_reasons, split_info, excluded, lag).
# Every fit gets the F61 optimiser limits: the common default fitter is replaced by e_glmmTMB_fit (e_fitter(); an
# injected test fitter is used as it is), because the common path (compare_models -> cv_predict -> fit_nb) never
# passes through the Paper E fitters.
compare_models_m <- function(specs, data, splits, lag = 12L, n_draws = 200L, seed = SEED_E, fitter = e_glmmTMB_fit) {
  fitter <- e_fitter(fitter)
  d <- data.table::copy(data.table::as.data.table(data))
  if (!"ym" %in% names(d)) stop("compare_models_m: data needs a ym column", call. = FALSE)
  d[, year := as.integer(ym)]
  per <- list(); info <- list(); fr <- list(); si <- list(); ex <- list()
  for (i in seq_along(splits)) {
    sp <- splits[[i]]
    di <- drop_lag_leak(d, sp$test_years, lag)
    r <- compare_models(specs, di, list(sp), n_draws = n_draws, seed = as.integer(seed) + i - 1L, fitter = fitter)
    per[[i]] <- r$per_split
    info[[i]] <- r$summary[, list(model, n_failed_splits, n_splits)]
    fr[[i]] <- r$fail_reasons; si[[i]] <- r$split_info; ex[[i]] <- r$excluded
  }
  fail_reasons <- data.table::rbindlist(fr, fill = TRUE)
  stop_non_estimation(fail_reasons)
  # The pooled flag, the intersection of scored rows and the summary below re-implement common compare_models()
  # (models/common/R/validate.R, lines 179-205: steps 3-4 of its rule) over the pooled splits, as the plan mandates
  # ("pool per_split, recompute summary"); models/common/R is frozen, so a change to the common rule must be
  # mirrored here by hand.
  info <- data.table::rbindlist(info)[, list(n_failed_splits = as.integer(sum(n_failed_splits)),
                                             n_splits = as.integer(sum(n_splits))), by = model]
  info[, flag := data.table::fifelse(n_splits == 0L, "no_evaluable_splits",
                                     data.table::fifelse(n_failed_splits > 0.1 * n_splits, "too_many_failed_fits",
                                                         NA_character_))]
  per_split <- data.table::rbindlist(per)
  per_split[, ym := year]
  per_split[, scored := FALSE]
  ok_models <- info[is.na(flag), model]
  key_cols <- c("split_id", "unit_id", "year")
  if (length(ok_models) && nrow(per_split)) {
    keys <- Reduce(function(a, b) data.table::fintersect(a, b),
                   lapply(ok_models, function(m) unique(per_split[model == m, ..key_cols])))
    per_split[keys, on = key_cols, scored := model %in% ok_models]
  }
  na_metrics <- list(male = NA_real_, rmse_log1p = NA_real_, log_score = NA_real_, coverage95 = NA_real_, n = 0L)
  summary <- data.table::rbindlist(lapply(names(specs), function(m) {
    r <- info[model == m]
    met <- if (is.na(r$flag)) {
      s <- per_split[model == m & scored == TRUE]
      .metric_row(oos_metrics(s$y, s$mu, s$theta, s$lo, s$hi))
    } else .metric_row(na_metrics)
    n_unscored <- if (is.na(r$flag)) nrow(per_split[model == m & scored == FALSE]) else NA_integer_
    cbind(data.table::data.table(model = m), met, r[, list(n_failed_splits, flag, n_splits)],
          n_unscored_other_model = as.integer(n_unscored))
  }))
  split_metrics <- if (any(per_split$scored))
    per_split[scored == TRUE, .metric_row(oos_metrics(y, mu, theta, lo, hi)), by = list(model, split_id)]
  else cbind(data.table::data.table(model = character(), split_id = character()), .metric_row(na_metrics)[0])
  list(summary = summary[], per_split = per_split[], split_metrics = split_metrics[], fail_reasons = fail_reasons[],
       split_info = data.table::rbindlist(si, fill = TRUE), excluded = data.table::rbindlist(ex, fill = TRUE),
       lag = as.integer(lag))
}

# Forecast Models A, B and C for outcome `ind` (contract §12). A: month of year (MOY_DUMMIES, see above; the data
# need add_moy_dummies()), trend, the outcome's programme terms and log1p_<ind>_lag12, with unit random intercept and
# trend slope and the population-days offset; B: A + the three concurrent local-climate terms; C: B + the index's
# en/ln terms + dmi_3m.
fc_specs <- function(ind, index = "oni") {
  index <- match.arg(index, FC_INDICES)
  a <- c(MOY_DUMMIES, "t_c", programme_terms(ind), sprintf("log1p_%s_lag12", ind))
  mk <- function(fixed) nb_spec(ind, fixed = fixed, slopes = "t_c", offset = "log_pop_days", trend_df = 0L)
  list(A = mk(a), B = mk(c(a, FC_LOCAL)), C = mk(c(a, FC_LOCAL, FC_INDEX_TERMS[[index]], "dmi_3m")))
}

# The LOEO comparison set: A, B and C (ONI), plus C with RONI and with Nino-3.4 (contract §13 skill), all on the same
# common rows and the same seeds.
fc_specs_loeo <- function(ind) {
  s <- fc_specs(ind, "oni")
  c(s, list(C_roni = fc_specs(ind, "roni")$C, C_nino34 = fc_specs(ind, "nino34")$C))
}

# Coefficients unidentified in a split's training fit (NA; set to 0 for prediction by common rule P5, e.g. a programme
# step constant in training) from compare_models_m()'s split_info: data.table(model, split_id, unidentified,
# n_test_rows_nonzero_unidentified), only the rows with at least one such coefficient.
fc_unidentified <- function(cm) {
  si <- data.table::as.data.table(cm$split_info)
  if (!nrow(si) || !"unidentified" %in% names(si))
    return(data.table::data.table(model = character(), split_id = character(), unidentified = character(),
                                  n_test_rows_nonzero_unidentified = integer()))
  si[!is.na(unidentified) & nzchar(unidentified),
     list(model, split_id, unidentified, n_test_rows_nonzero_unidentified = as.integer(n_test_rows_nonzero_unidentified))]
}

# One line per split: "<split> <coefficients> (<n> test rows non-zero; models A, B, C)", or "none".
fc_unidentified_text <- function(u) {
  u <- data.table::as.data.table(u)
  if (!nrow(u)) return("none")
  g <- u[, list(models = paste(model, collapse = ", ")), by = list(split_id, unidentified, n_test_rows_nonzero_unidentified)]
  paste(sprintf("%s %s (%d test rows non-zero; models %s)", g$split_id, gsub(";", ", ", g$unidentified, fixed = TRUE),
                g$n_test_rows_nonzero_unidentified, g$models), collapse = "; ")
}

# ---- the forecast rule ----------------------------------------------------------------------------------------------

# Per-split comparison of C with B: per_split_male is data.table(model, split_id, male) with at most one row per
# model and split; the LOEO folds are loeo_ids, every other split_id is a rolling origin. A missing or NA MALE is
# never "lower". Returns list(loeo_better (named by fold), n_roll_better, n_roll).
fc_counts <- function(per_split_male, loeo_ids = FC_LOEO_IDS) {
  p <- data.table::as.data.table(per_split_male)
  if (anyDuplicated(p[, list(model, split_id)]))
    stop("fc_rule: one MALE per model and split expected", call. = FALSE)
  male <- function(m, sid) { v <- p[model == m & split_id == sid]$male; if (length(v)) v else NA_real_ }
  better <- function(sid) isTRUE(male("C", sid) < male("B", sid))
  origins <- setdiff(unique(p$split_id), loeo_ids)
  list(loeo_better = vapply(stats::setNames(loeo_ids, loeo_ids), better, NA),
       n_roll_better = as.integer(sum(vapply(origins, better, NA))), n_roll = length(origins))
}

# Forecast rule (spec §5.7): "adds skill over local climate" iff MALE_C < MALE_B in both LOEO folds and in at least
# 4 of the rolling origins; otherwise "no added skill demonstrated".
fc_rule <- function(per_split_male, loeo_ids = FC_LOEO_IDS, min_origins = 4L) {
  k <- fc_counts(per_split_male, loeo_ids)
  if (all(k$loeo_better) && k$n_roll_better >= min_origins) FC_RULE_YES else FC_RULE_NO
}

# ---- the index comparison -------------------------------------------------------------------------------------------

# SD (n - 1) of the entered index series over the months of `d` (one value per month; F7: the INDEX SD, never the
# SD of the en term). oni -> oni, roni -> roni, nino34 -> nino34_3m.
index_sd <- function(d, index) {
  index <- match.arg(index, FC_INDICES)
  col <- FC_INDEX_SERIES[[index]]
  m <- unique(data.table::as.data.table(d)[, c("ym", col), with = FALSE])
  if (anyDuplicated(m$ym)) stop("index_sd: more than one value of ", col, " in a month", call. = FALSE)
  if (anyNA(m[[col]])) stop("index_sd: ", col, " is missing in ", sum(is.na(m[[col]])), " month(s)", call. = FALSE)
  stats::sd(m[[col]])
}

# Per-SD effect from a Wald fit (F7; contract §13): exp(beta x sd_index), bounds exp((beta -/+ 1.959964 se) x
# sd_index), se of beta x sd_index (log scale).
std_effect_wald <- function(beta, se, sd_index) {
  list(std_beta = beta * sd_index, std_se = se * sd_index, std_effect = exp(beta * sd_index),
       std_lo = exp((beta - Z95 * se) * sd_index), std_hi = exp((beta + Z95 * se) * sd_index))
}

# Per-SD effect under the block bootstrap (contract §13; progress ruling): the point is exp(beta-hat x sd_index) from
# the fit on the original rows, the bounds are the percentile bounds of beta scaled by sd_index, and se is the
# bootstrap SD of beta x sd_index.
std_effect_boot <- function(beta, boot_sd, beta_lo, beta_hi, sd_index) {
  list(std_beta = beta * sd_index, std_se = boot_sd * sd_index, std_effect = exp(beta * sd_index),
       std_lo = exp(beta_lo * sd_index), std_hi = exp(beta_hi * sd_index))
}

.idx_row <- function(ind, index, sd_index, time_re, status = "ok", error = NA_character_) {
  data.table::data.table(outcome = ind, index = index, term = FC_INDEX_TERMS[[index]][1], beta = NA_real_,
                         beta_se = NA_real_, irr = NA_real_, lo = NA_real_, hi = NA_real_, p = NA_real_,
                         p_kind = NA_character_, sd_index = sd_index, std_beta = NA_real_, std_effect = NA_real_,
                         std_lo = NA_real_, std_hi = NA_real_, se = NA_real_, aic = NA_real_,
                         aic_reason = NA_character_, time_re = time_re, re_used = NA_character_, n = NA_integer_,
                         n_units = NA_integer_, B_ok = NA_integer_, status = status, error = error)
}

.fill_idx <- function(r, beta, beta_se, lo, hi, p, p_kind, w, aic, aic_reason, re_used, n, n_units, B_ok) {
  v <- list(beta = beta, beta_se = beta_se, irr = exp(beta), lo = lo, hi = hi, p = p, p_kind = p_kind,
            std_beta = w$std_beta, std_effect = w$std_effect, std_lo = w$std_lo, std_hi = w$std_hi, se = w$std_se,
            aic = as.numeric(aic), aic_reason = as.character(aic_reason), re_used = re_used, n = as.integer(n),
            n_units = as.integer(n_units), B_ok = as.integer(B_ok))
  data.table::set(r, j = names(v), value = v)
  r[]
}

# Model T refitted with the index's en/ln terms in place of en_t/ln_t (contract §11 roni/nino34 and §13), with
# exactly the time random-effect step `time_re` the outcome's ONI Model T used (E.t.<I>.time_re) and no further
# fallback. ar1/iid: fit_time_chain(chain = time_re); Wald beta, std effect, AIC. block_bootstrap: boot_fun (the
# primary block_bootstrap_irr(), same seed, so the same month-block resamples); percentile bounds scaled by
# sd_index, bootstrap SD, no AIC (aic_reason "no likelihood under the block bootstrap"). A genuine estimation
# failure gives status "error" with the F18 reason (the step's non-convergence: "<step> time random effect did
# not converge (the step of the ONI Model T; no further fallback)"); any other error stops (F56). Returns one row:
# outcome, index, term (the en term), beta, beta_se (log IRR per +1 deg C), irr, lo, hi (per +1 deg C: Wald or
# percentile), p, p_kind, sd_index, std_beta, std_effect, std_lo, std_hi, se (SE of beta x sd_index), aic,
# aic_reason, time_re, re_used, n, n_units, B_ok, status, error.
index_effects <- function(d, ind, index, time_re, sd_index = index_sd(d, index), B = 1000L, block = 12L,
                          seed = SEED_E, cores = 1L, fit_fun = e_glmmTMB_fit, boot_fun = block_bootstrap_irr,
                          progress = NULL) {
  index <- match.arg(index, FC_INDICES)
  if (length(time_re) != 1L || !time_re %in% c(names(TIME_RE), "block_bootstrap"))
    stop("index_effects: unknown time_re step: ", paste(time_re, collapse = ", "), call. = FALSE)
  terms <- FC_INDEX_TERMS[[index]]
  spec <- t_spec(ind, exposure = terms)
  r <- .idx_row(ind, index, sd_index, time_re)
  if (time_re == "block_bootstrap") {
    return(catch_estimation_failure({
      bb <- boot_fun(spec, d, terms, B = as.integer(B), block = as.integer(block), seed = as.integer(seed),
                     cores = as.integer(cores), fit_fun = fit_fun, progress = progress)
      e <- terms[1]
      beta_lo <- log(unname(bb$lo[e])); beta_hi <- log(unname(bb$hi[e]))
      .fill_idx(r, unname(bb$est[e]), unname(bb$se[e]), unname(bb$lo[e]), unname(bb$hi[e]), unname(bb$p[e]),
                "bootstrap", std_effect_boot(unname(bb$est[e]), unname(bb$se[e]), beta_lo, beta_hi, sd_index),
                NA_real_, NO_LIKELIHOOD, bb$re_used, bb$n, bb$n_units, bb$B_ok)
    }, function(e) {
      x <- .idx_row(ind, index, sd_index, time_re, "error", first_line(conditionMessage(e)))
      if (!is.null(e$B_ok)) x[, B_ok := as.integer(e$B_ok)]
      x
    }))
  }
  catch_estimation_failure({
    f <- fit_time_chain(spec, d, chain = time_re, fit_fun = fit_fun)
    w <- term_row(f, terms[1])
    .fill_idx(r, w$est, w$se, w$lo, w$hi, w$p, "wald", std_effect_wald(w$est, w$se, sd_index),
              stats::AIC(f$model), NA_character_, f$re_used, f$n, nlevels(f$data$unit_id), NA_integer_)
  }, function(e) {
    msg <- conditionMessage(e)
    reason <- if (startsWith(msg, "fit_time_chain: no time random effect converged"))
      sprintf("%s time random effect did not converge (the step of the ONI Model T; no further fallback)", time_re)
    else first_line(msg)
    .idx_row(ind, index, sd_index, time_re, "error", reason)
  })
}

# The ONI row of the index comparison from the primary Model T row (primary_estimates.csv: model T, term en_t):
# the oni fit IS the primary Model T (contract §13), so std_effect = E.t.<I>.irr_en ^ oni_sd. `aic` comes from the
# refit with the same step (ar1/iid); under the block bootstrap it is "no likelihood". A Model T that was not
# estimated gives status "error" with the reason "Model T: <reason>" (as F58); a dropped outcome keeps its reason.
index_effect_from_primary <- function(prow, sd_index, aic = NA_real_) {
  prow <- data.table::as.data.table(prow)
  if (nrow(prow) != 1L) stop("index_effect_from_primary: one Model T en_t row expected", call. = FALSE)
  ind <- prow$outcome
  if (!identical(prow$status, "ok") || is.na(prow$est)) {
    why <- if (!is.na(prow$error)) prow$error else "estimate missing"
    reason <- if (identical(prow$status, "dropped")) why else paste("Model T:", why)
    return(.idx_row(ind, "oni", sd_index, NA_character_, if (identical(prow$status, "dropped")) "dropped" else "error",
                    reason))
  }
  r <- .idx_row(ind, "oni", sd_index, prow$time_re)
  boot <- identical(prow$p_kind, "bootstrap")
  w <- if (boot) std_effect_boot(prow$est, prow$se, log(prow$lo), log(prow$hi), sd_index)
       else std_effect_wald(prow$est, prow$se, sd_index)
  .fill_idx(r, prow$est, prow$se, prow$lo, prow$hi, prow$p, if (boot) "bootstrap" else "wald", w,
            if (boot) NA_real_ else aic, if (boot) NO_LIKELIHOOD else NA_character_, prow$re_used, prow$n,
            prow$n_units, prow$B_ok)
}
