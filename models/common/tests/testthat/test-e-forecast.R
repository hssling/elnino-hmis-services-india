# Paper E Task 10: forecast comparison (Models A/B/C) and ENSO-index comparison (models/E/R/forecast_e.R,
# models/E/05_forecast.R). Contract papers/E/results_keys.md §11 (roni, nino34), §12 and §13; rulings F6, F7, F15,
# F52, F56. models/common/R is frozen; nothing here edits it. No test reads an HMIS outcome.

local({
  root <- if (exists("MODELS_ROOT")) MODELS_ROOT else normalizePath(file.path(getwd(), "..", "..", ".."), winslash = "/")
  for (f in c("common_e.R", "monthly.R", "power.R", "verdicts.R")) source(file.path(root, "E", "R", f), local = globalenv())
  source(file.path(root, "E", "05_forecast.R"), local = globalenv())
})

ym_of <- function(year, month) as.integer(year) * 12L + as.integer(month) - 1L

# sim_month_panel() plus the RONI / Nino-3.4 series and their en/ln terms (one value per month, as in the model table)
sim_with_indices <- function(...) {
  d <- sim_month_panel(...)
  m <- unique(d[, .(ym, oni = en_t + ln_t)])
  set.seed(7)
  m[, `:=`(roni = round(oni + stats::rnorm(.N, 0, 0.15), 2), nino34_3m = round(1.05 * oni + stats::rnorm(.N, 0, 0.1), 3))]
  d <- m[d, on = "ym"]
  d[, `:=`(en_roni = pmax(roni, 0), ln_roni = pmin(roni, 0), en_n34 = pmax(nino34_3m, 0), ln_n34 = pmin(nino34_3m, 0))]
  data.table::setorder(d, unit_id, ym)
  d[]
}

# ---- splits --------------------------------------------------------------------------------------------------------

test_that("LOEO month splits are the two episode windows", {
  s <- loeo_month_splits()
  expect_identical(vapply(s, `[[`, "", "id"), c("ep1415", "ep1819"))
  expect_identical(lengths(lapply(s, `[[`, "test_years")), c(27L, 18L))
  expect_identical(range(s[[1]]$test_years), c(ym_of(2014, 10), ym_of(2016, 12)))
  expect_identical(range(s[[2]]$test_years), c(ym_of(2018, 9), ym_of(2020, 2)))
  expect_true(all(diff(s[[1]]$test_years) == 1L) && all(diff(s[[2]]$test_years) == 1L))
  expect_null(s[[1]]$train_max)
})

test_that("rolling FY splits train on prior FYs", {
  ym <- rep(ym_of(2012, 4):ym_of(2020, 2), 3)                     # the 95 primary months, three units
  s <- rolling_splits_fy(ym, fy_start_of(ym))
  expect_length(s, 5L)
  expect_identical(vapply(s, `[[`, "", "id"), sprintf("fy%d", 2015:2019))
  expect_identical(s[[1]]$test_years, ym_of(2015, 4):ym_of(2016, 3))
  expect_identical(s[[1]]$train_max, ym_of(2015, 3))
  expect_identical(s[[5]]$test_years, ym_of(2019, 4):ym_of(2020, 2))  # the last origin scores Apr 2019 - Feb 2020
  expect_identical(s[[5]]$train_max, ym_of(2019, 3))
  expect_identical(fy_start_of(c(ym_of(2013, 3), ym_of(2013, 4))), c(2012L, 2013L))
  expect_length(rolling_splits_fy(ym, fy_start_of(ym), first_test = 2018L), 2L)
  expect_error(rolling_splits_fy(ym, fy_start_of(ym)[-1]), "same length")
})

test_that("lag-12 buffer drops training rows whose lag is in test", {
  d <- data.table::data.table(unit_id = factor(rep(c("U1", "U2"), each = 48)), ym = rep(24147L + 0:47, 2))
  test <- 24160L + 0:5
  out <- drop_lag_leak(d, test, lag = 12L)
  gone <- setdiff(unique(d$ym), unique(out$ym))
  expect_identical(sort(gone), 24172L + 0:5)                       # training rows carrying a test month's outcome
  expect_true(all(test %in% out$ym))                               # test rows are never dropped
  expect_identical(nrow(out), nrow(d) - 12L)
  # a test month whose lag-12 month is also in the test set stays a test row
  long_test <- 24150L + 0:20
  expect_true(all(long_test %in% drop_lag_leak(d, long_test, 12L)$ym))
  expect_identical(sort(setdiff(unique(d$ym), drop_lag_leak(d, long_test, 12L)$ym)), 24171L + 0:11)
})

test_that("compare_models_m trains without the leaked months (spy fitter)", {
  d <- sim_month_panel(n_units = 5, n_months = 48, seed = 3)
  d[, log1p_y_lag12 := log1p(data.table::shift(y, 12L)), by = unit_id]
  spec <- nb_spec("y", fixed = c("log1p_y_lag12"), offset = "log_pop_days", trend_df = 0L)
  seen <- list()
  spy <- function(formula, data, family = glmmTMB::nbinom2()) {
    seen[[length(seen) + 1L]] <<- sort(unique(data$year))
    glmmTMB_fit(formula, data, family)
  }
  sp <- list(list(id = "t1", test_years = 24170L + 0:5))
  r <- compare_models_m(list(A = spec), d, sp, lag = 12L, n_draws = 10L, seed = 5L, fitter = spy)
  expect_length(seen, 1L)
  tr <- seen[[1]]
  expect_false(any(c(24170L + 0:5, 24182L + 0:5) %in% tr))
  expect_true(all(c(24169L, 24176L, 24181L, 24188L) %in% tr))
  expect_false(any(tr < 24159L))                                   # the first 12 months have no lag-12 outcome
  expect_true(all(r$per_split$scored))
  expect_identical(sort(unique(r$per_split$ym)), 24170L + 0:5)
  expect_identical(r$summary$n, nrow(r$per_split))
})

test_that("compare_models_m pools splits: >10% failed splits flag a model; scored rows are the F6 intersection", {
  d <- sim_panel(n_units = 8, years = 2002:2025, seed = 4)
  d[, ym := year]
  # B fails (no structure converges) when its training rows lack both 2012 and 2013: only the split testing 2012,
  # whose lag-1 buffer drops 2013
  fail_b <- function(formula, data, family = glmmTMB::nbinom2()) {
    if ("x" %in% all.vars(formula) && !any(c(2012L, 2013L) %in% data$year)) stop("simulated non-convergence")
    glmmTMB_fit(formula, data, family)
  }
  specs <- list(A = nb_spec("y", fixed = character(), offset = "log_pop", trend_df = 0L),
                B = nb_spec("y", fixed = "x", offset = "log_pop", trend_df = 0L))
  two <- list(list(id = "s1", test_years = 2012L), list(id = "s2", test_years = 2016L))
  r2 <- compare_models_m(specs, d, two, lag = 1L, n_draws = 10L, fitter = fail_b)
  sb <- r2$summary[model == "B"]
  expect_identical(sb$flag, "too_many_failed_fits")
  expect_identical(c(sb$n_failed_splits, sb$n_splits), c(1L, 2L))
  expect_true(is.na(sb$male))
  sa <- r2$summary[model == "A"]
  expect_true(is.na(sa$flag))
  expect_identical(sa$n, 16L)                                      # A keeps both splits: B is flagged, outside the intersection
  expect_identical(sort(unique(r2$split_metrics$model)), "A")
  expect_true(any(grepl("fit_nb: no structure converged", r2$fail_reasons$error)))

  eleven <- lapply(2012:2022, function(y) list(id = paste0("s", y), test_years = y))
  r11 <- compare_models_m(specs, d, eleven, lag = 1L, n_draws = 10L, fitter = fail_b)
  expect_true(all(is.na(r11$summary$flag)))                        # 1 of 11 failed: not > 10%
  # the split B failed is unscored for A too (F6), so both are scored on the same 10 splits
  expect_identical(r11$summary$n, c(80L, 80L))
  expect_false(any(r11$per_split[model == "A" & split_id == "s2012"]$scored))
  expect_identical(r11$summary[model == "A"]$n_unscored_other_model, 8L)
  expect_setequal(unique(r11$split_metrics$split_id), paste0("s", setdiff(2012:2022, 2012L)))
})

test_that("compare_models_m stops on a split error that is not an estimation failure (F56)", {
  expect_error(stop_non_estimation(data.table::data.table(model = "A", split_id = "s", stage = "fit",
                                                          error = "object 'zz' not found")),
               "not an estimation failure")
  expect_silent(stop_non_estimation(data.table::data.table(model = "A", split_id = "s", stage = "fit",
                                                           error = "fit_nb: no structure converged for y (tried int)")))
  expect_silent(stop_non_estimation(data.table::data.table(model = "A", split_id = "s", stage = "draw",
                                                           error = "joint precision unavailable")))
  expect_error(stop_non_estimation(data.table::data.table(model = "A", split_id = "s", stage = "fit",
                                                          error = "fit_nb: no complete rows remain for y")),
               "not an estimation failure")
})

test_that("compare_models_m equals compare_models on an annual panel with lag 1", {
  skip_if_slow_disabled()
  d <- sim_panel(n_units = 12, years = 2002:2025, seed = 11)
  d[, log1p_y_lag1 := log1p(data.table::shift(y, 1L)), by = unit_id]
  d[, ym := year]
  specs <- list(A = nb_spec("y", fixed = "log1p_y_lag1", slopes = character(), offset = "log_pop", trend_df = 0L),
                B = nb_spec("y", fixed = c("log1p_y_lag1", "x"), slopes = character(), offset = "log_pop", trend_df = 0L))
  splits <- c(list(list(id = "f1", test_years = 2009:2011), list(id = "f2", test_years = 2016:2017)),
              rolling_splits(2002:2025, first_test = 2022))
  ref <- compare_models(specs, d, splits, n_draws = 50, seed = 9L)
  expect_true(ref$lag_buffer)
  got <- compare_models_m(specs, d, splits, lag = 1L, n_draws = 50L, seed = 9L)
  for (col in c("male", "rmse_log1p", "log_score", "coverage95"))
    expect_equal(got$summary[[col]], ref$summary[[col]], tolerance = 1e-8)
  expect_identical(got$summary$n, ref$summary$n)
  m <- merge(got$split_metrics, ref$split_metrics, by = c("model", "split_id"))
  expect_identical(nrow(m), nrow(ref$split_metrics))
  expect_equal(m$male.x, m$male.y, tolerance = 1e-8)
})

# ---- specs and the rule --------------------------------------------------------------------------------------------

test_that("fc_specs builds Models A, B and C with the index's terms", {
  s <- fc_specs("penta3")
  expect_named(s, c("A", "B", "C"))
  expect_identical(s$A$fixed, c(sprintf("moy_%02d", 2:12), "t_c", "hmis_format2017", "demonet", "mi_round", "log1p_penta3_lag12"))
  expect_identical(s$B$fixed, c(s$A$fixed, "spi3_dry_l0", "spi3_wet_l0", "heatwave_days_l0"))
  expect_identical(s$C$fixed, c(s$B$fixed, "en_t", "ln_t", "dmi_3m"))
  for (m in s) {
    expect_identical(m$slopes, "t_c"); expect_identical(m$offset, "log_pop_days"); expect_identical(m$trend_df, 0L)
  }
  expect_identical(fc_specs("opd")$A$fixed, c(MOY_DUMMIES, "t_c", "hmis_format2017", "demonet", "log1p_opd_lag12"))
  expect_identical(tail(fc_specs("opd", "roni")$C$fixed, 3), c("en_roni", "ln_roni", "dmi_3m"))
  expect_identical(tail(fc_specs("opd", "nino34")$C$fixed, 3), c("en_n34", "ln_n34", "dmi_3m"))
  expect_identical(fc_specs("opd", "roni")$B, fc_specs("opd")$B)
  expect_error(fc_specs("opd", "dmi"))
  expect_false(.uses_lag_outcome(s$A))                             # the common lag-1 buffer stays off; ours applies
})

test_that("month-of-year indicators reproduce the factor moy", {
  d <- data.table::data.table(moy = factor(c(1, 2, 12, NA), levels = 1:12))
  out <- add_moy_dummies(d)
  expect_identical(out$moy_02, c(0L, 1L, 0L, NA)); expect_identical(out$moy_12, c(0L, 0L, 1L, NA))
  expect_true(all(out[1, MOY_DUMMIES, with = FALSE] == 0L))
  expect_false("moy_02" %in% names(d))                             # the input is not modified
  # the same fitted model as the factor (identical log-likelihood)
  p <- sim_month_panel(n_units = 4, n_months = 36, seed = 5)
  f1 <- glmmTMB_fit(y ~ moy + t_c + offset(log_pop_days) + (1 | unit_id), p)
  f2 <- glmmTMB_fit(stats::as.formula(paste("y ~", paste(MOY_DUMMIES, collapse = " + "),
                                           "+ t_c + offset(log_pop_days) + (1 | unit_id)")), add_moy_dummies(p))
  expect_equal(as.numeric(stats::logLik(f1)), as.numeric(stats::logLik(f2)), tolerance = 1e-6)
  expect_error(add_moy_dummies(data.table::data.table(moy = 13L)), "1..12")
})

psm <- function(c_loeo, b_loeo, c_roll, b_roll) {
  ids <- c("ep1415", "ep1819", sprintf("fy%d", 2015:2019))
  data.table::data.table(model = rep(c("B", "C"), each = 7), split_id = rep(ids, 2),
                         male = c(b_loeo, b_roll, c_loeo, c_roll))
}

test_that("fc_rule needs both folds and 4 of 5 origins", {
  ADD <- "adds skill over local climate"; NO <- "no added skill demonstrated"
  b <- rep(0.20, 5)
  expect_identical(fc_rule(psm(c(0.10, 0.10), c(0.2, 0.2), c(0.1, 0.1, 0.1, 0.1, 0.3), b)), ADD)   # 4 of 5
  expect_identical(fc_rule(psm(c(0.10, 0.10), c(0.2, 0.2), c(0.1, 0.1, 0.1, 0.3, 0.3), b)), NO)    # 3 of 5
  expect_identical(fc_rule(psm(c(0.10, 0.25), c(0.2, 0.2), rep(0.1, 5), b)), NO)                   # one fold fails
  expect_identical(fc_rule(psm(c(0.20, 0.10), c(0.2, 0.2), rep(0.1, 5), b)), NO)                   # a tie is not lower
  expect_identical(fc_rule(psm(c(NA, 0.10), c(0.2, 0.2), rep(0.1, 5), b)), NO)                     # NA (flagged) is not lower
  p <- psm(c(0.10, 0.10), c(0.2, 0.2), c(0.1, 0.1, 0.1, 0.1, 0.3), b)
  expect_identical(fc_rule(p[!(model == "C" & split_id == "ep1819")]), NO)                         # a fold missing
  expect_identical(fc_counts(p)$n_roll_better, 4L)
  expect_identical(fc_counts(p)$n_roll, 5L)
  expect_identical(unname(fc_counts(p)$loeo_better), c(TRUE, TRUE))
  expect_error(fc_rule(rbind(p, p)), "one MALE")
})

# ---- index standardisation -----------------------------------------------------------------------------------------

test_that("std effect is beta times the index SD", {
  w <- std_effect_wald(0.1, 0.02, 0.75)
  expect_equal(w$std_beta, 0.075)
  expect_equal(w$std_effect, exp(0.075))
  expect_equal(w$std_lo, exp((0.1 - 1.959964 * 0.02) * 0.75))
  expect_equal(w$std_hi, exp((0.1 + 1.959964 * 0.02) * 0.75))
  expect_equal(w$std_se, 0.015)
  bt <- std_effect_boot(beta = 0.1, boot_sd = 0.03, beta_lo = 0.02, beta_hi = 0.2, sd_index = 0.8)
  expect_equal(bt$std_effect, exp(0.08)); expect_equal(bt$std_lo, exp(0.016)); expect_equal(bt$std_hi, exp(0.16))
  expect_equal(bt$std_se, 0.024)

  d <- sim_with_indices(n_units = 6, beta_en = -0.05, seed = 21)
  m <- unique(d[, .(ym, roni, en_roni)])
  expect_equal(index_sd(d, "roni"), stats::sd(m$roni))             # the INDEX SD over the months (F7) ...
  expect_false(isTRUE(all.equal(index_sd(d, "roni"), stats::sd(m$en_roni))))   # ... never the SD of the en term
  expect_identical(index_sd(d, "oni"), stats::sd(unique(d[, .(ym, oni)])$oni))
  bad <- data.table::copy(d); bad[1, roni := roni + 1]
  expect_error(index_sd(bad, "roni"), "more than one value")

  r <- index_effects(d, "y", "roni", time_re = "iid")
  f <- fit_time_chain(t_spec("y", exposure = c("en_roni", "ln_roni")), d, chain = "iid")
  b <- unname(glmmTMB::fixef(f$model)$cond["en_roni"])
  se <- unname(sqrt(diag(stats::vcov(f$model)$cond))["en_roni"])
  expect_identical(r$status, "ok")
  expect_identical(r$time_re, "iid")
  expect_equal(r$sd_index, index_sd(d, "roni"))
  expect_equal(r$beta, b, tolerance = 1e-8)
  expect_equal(r$std_effect, exp(b * r$sd_index), tolerance = 1e-8)
  expect_equal(r$std_lo, exp((b - 1.959964 * se) * r$sd_index), tolerance = 1e-6)
  expect_equal(r$se, se * r$sd_index, tolerance = 1e-6)
  expect_equal(r$irr, exp(b), tolerance = 1e-8)
  expect_equal(r$aic, stats::AIC(f$model), tolerance = 1e-8)
  expect_identical(r$n, as.integer(f$n))
})

test_that("index_effects under the block-bootstrap step: percentile bounds scaled, no AIC", {
  d <- sim_with_indices(n_units = 4, n_months = 30, seed = 2)
  got <- NULL
  fake_boot <- function(spec, d, term, B, block, seed, cores, fit_fun, progress) {
    got <<- list(term = term, B = B, seed = seed, fixed = spec$fixed)
    list(term = term, est = c(en_n34 = 0.1, ln_n34 = 0.01), se = c(en_n34 = 0.03, ln_n34 = 0.02),
         irr = exp(c(en_n34 = 0.1, ln_n34 = 0.01)), lo = exp(c(en_n34 = 0.02, ln_n34 = -0.03)),
         hi = exp(c(en_n34 = 0.2, ln_n34 = 0.05)), p = c(en_n34 = 0.004, ln_n34 = 0.6), B = B, B_ok = 990L,
         B_failed = 10L, re_used = "diag", n = 120L, n_units = 4L)
  }
  r <- index_effects(d, "y", "nino34", time_re = "block_bootstrap", sd_index = 0.8, B = 1000L, boot_fun = fake_boot)
  expect_identical(got$term, c("en_n34", "ln_n34"))
  expect_identical(got$seed, SEED_E)
  expect_identical(got$B, 1000L)
  expect_true(all(c("en_n34", "ln_n34", "moy", "t_c") %in% got$fixed))
  expect_identical(r$status, "ok")
  expect_identical(r$p_kind, "bootstrap")
  expect_equal(r$std_effect, exp(0.08)); expect_equal(r$std_lo, exp(0.016)); expect_equal(r$std_hi, exp(0.16))
  expect_equal(r$se, 0.024)
  expect_true(is.na(r$aic))
  expect_identical(r$aic_reason, "no likelihood under the block bootstrap")
  expect_identical(r$B_ok, 990L)
  expect_equal(r$irr, exp(0.1)); expect_equal(r$lo, exp(0.02))

  too_many <- function(...) stop(errorCondition("block bootstrap: more than 10% of refits failed",
                                                class = "e_boot_too_many_failed", B_ok = 850L, B = 1000L))
  r2 <- index_effects(d, "y", "nino34", time_re = "block_bootstrap", sd_index = 0.8, boot_fun = too_many)
  expect_identical(r2$status, "error")
  expect_identical(r2$error, "block bootstrap: more than 10% of refits failed")
  expect_identical(r2$B_ok, 850L)
})

test_that("index_effects uses the ONI step only: no fallback, not estimable on non-convergence; other errors stop", {
  d <- sim_with_indices(n_units = 4, n_months = 30, seed = 2)
  calls <- 0L
  never <- function(formula, data, family = glmmTMB::nbinom2()) { calls <<- calls + 1L; stop("no convergence") }
  r <- index_effects(d, "y", "roni", time_re = "ar1", sd_index = 0.76, fit_fun = never)
  expect_identical(r$status, "error")
  expect_identical(r$error, "ar1 time random effect did not converge (the step of the ONI Model T; no further fallback)")
  expect_identical(calls, 3L)                                      # us, diag, int at the ar1 step only; no iid step
  expect_true(is.na(r$std_effect))
  expect_error(index_effects(d[, !"en_roni"], "y", "roni", time_re = "iid", sd_index = 0.76, fit_fun = never),
               "missing column")
  expect_error(index_effects(d, "y", "roni", time_re = "nope", sd_index = 0.76), "time_re")
})

test_that("the ONI row comes from the primary Model T", {
  wald <- data.table::data.table(outcome = "opd", model = "T", term = "en_t", est = -0.05, se = 0.02, irr = exp(-0.05),
                                 lo = exp(-0.05 - 1.959964 * 0.02), hi = exp(-0.05 + 1.959964 * 0.02), p = 0.01,
                                 p_kind = "wald", B_ok = NA_integer_, time_re = "ar1", re_used = "us", n = 3100L,
                                 n_units = 34L, status = "ok", error = NA_character_)
  r <- index_effect_from_primary(wald, sd_index = 0.75, aic = 1234.5)
  expect_equal(r$std_effect, exp(-0.05 * 0.75))
  expect_equal(r$std_effect, wald$irr^0.75)                        # E.idx.<I>.oni.std_effect = E.t.<I>.irr_en ^ oni_sd
  expect_equal(r$std_lo, wald$lo^0.75)
  expect_equal(r$se, 0.015)
  expect_equal(r$aic, 1234.5)
  boot <- data.table::copy(wald)[, `:=`(p_kind = "bootstrap", B_ok = 997L, time_re = "block_bootstrap", se = 0.03,
                                        lo = exp(-0.11), hi = exp(0.004))]
  rb <- index_effect_from_primary(boot, sd_index = 0.75)
  expect_equal(rb$std_lo, exp(-0.11 * 0.75)); expect_equal(rb$std_hi, exp(0.004 * 0.75))
  expect_equal(rb$se, 0.0225)
  expect_true(is.na(rb$aic)); expect_identical(rb$aic_reason, "no likelihood under the block bootstrap")
  expect_identical(rb$B_ok, 997L)
  bad <- data.table::copy(wald)[, `:=`(status = "error", est = NA_real_, error = "fit_nb: no structure converged for opd")]
  rn <- index_effect_from_primary(bad, sd_index = 0.75)
  expect_identical(rn$status, "error")
  expect_identical(rn$error, "Model T: fit_nb: no structure converged for opd")
})

# ---- keys ----------------------------------------------------------------------------------------------------------

# Tables as run_forecast() assembles them, for every outcome; fic is dropped, mcv1's Model T used the block
# bootstrap, opd's Model C failed >10% of the rolling refits, inst_del's ONI Model T was not estimable.
fake_forecast_tables <- function() {
  live <- setdiff(INDS, "fic")
  ids <- list(loeo = c("ep1415", "ep1819"), rolling = sprintf("fy%d", 2015:2019))
  sk <- list()
  for (o in live) for (des in names(ids)) {
    mods <- if (des == "loeo") c("A", "B", "C", "C_roni", "C_nino34") else c("A", "B", "C")
    for (m in mods) {
      male <- c(A = 0.20, B = 0.19, C = 0.18, C_roni = 0.181, C_nino34 = 0.182)[[m]]
      flag <- if (o == "opd" && des == "rolling" && m == "C") "too_many_failed_fits" else NA_character_
      for (sid in c("pooled", ids[[des]])) {
        if (!is.na(flag) && sid != "pooled") next
        v <- if (!is.na(flag)) NA_real_ else male + if (sid == "fy2019" && m == "C") 0.05 else 0
        sk[[length(sk) + 1L]] <- data.table::data.table(outcome = o, design = des, model = m, split_id = sid,
                                                        male = v, rmse_log1p = v, log_score = if (is.na(v)) NA_real_ else 8 + v,
                                                        coverage95 = 0.9, n = if (sid == "pooled") 1400L else 300L,
                                                        n_failed_splits = if (is.na(flag)) 0L else 1L, n_splits = 5L, flag = flag)
      }
    }
  }
  sk <- data.table::rbindlist(sk)
  ix <- list()
  for (o in live) for (k in c("oni", "roni", "nino34")) {
    sdv <- c(oni = 0.7495, roni = 0.7605, nino34 = 0.7968)[[k]]
    boot <- o == "mcv1"
    bad <- o == "inst_del"
    b <- -0.04
    w <- if (boot) std_effect_boot(b, 0.02, -0.08, 0.001, sdv) else std_effect_wald(b, 0.015, sdv)
    ix[[length(ix) + 1L]] <- data.table::data.table(
      outcome = o, index = k, term = FC_INDEX_TERMS[[k]][1], beta = if (bad) NA_real_ else b,
      beta_se = if (bad) NA_real_ else 0.015, irr = if (bad) NA_real_ else exp(b),
      lo = if (bad) NA_real_ else exp(b - 0.03), hi = if (bad) NA_real_ else exp(b + 0.03),
      p = if (bad) NA_real_ else 0.01, p_kind = if (boot) "bootstrap" else "wald", sd_index = sdv,
      std_beta = if (bad) NA_real_ else w$std_beta, std_effect = if (bad) NA_real_ else w$std_effect,
      std_lo = if (bad) NA_real_ else w$std_lo, std_hi = if (bad) NA_real_ else w$std_hi,
      se = if (bad) NA_real_ else w$std_se, aic = if (bad || boot) NA_real_ else 30000.27,
      aic_reason = if (boot) "no likelihood under the block bootstrap" else NA_character_,
      time_re = if (bad) NA_character_ else if (boot) "block_bootstrap" else "ar1", re_used = "us", n = 3100L,
      n_units = 34L, B_ok = if (boot) 995L else NA_integer_, status = if (bad) "error" else "ok",
      error = if (bad) "Model T: fit_nb: no structure converged for inst_del" else NA_character_)
  }
  list(skill = sk, idx = data.table::rbindlist(ix))
}

test_that("forecast_entries writes exactly the contract's §11 (roni, nino34), §12 and §13 keys", {
  ft <- fake_forecast_tables()
  E <- forecast_entries(ft$skill, ft$idx, dropped = "fic")
  want <- forecast_contract_keys()
  expect_length(want, 168L)
  expect_setequal(names(E), want)
  disp <- function(k) E[[k]]$display
  expect_identical(disp("E.fc.anc_reg.male_a"), "0.200")
  expect_identical(disp("E.fc.anc_reg.male_diff_c_b"), "−0.010")
  expect_identical(disp("E.fc.anc_reg.male_diff_b_a"), "−0.010")
  expect_identical(disp("E.fc.anc_reg.n_roll_c_better"), "4 of 5")
  expect_identical(disp("E.fc.anc_reg.rule"), "adds skill over local climate")
  expect_identical(E[["E.fc.anc_reg.rule"]]$value, "adds skill over local climate")
  expect_identical(disp("E.fc.opd.n_roll_c_better"), "not estimated (>10% of refits failed)")
  expect_identical(disp("E.fc.opd.rule"), "no added skill demonstrated")
  expect_identical(disp("E.fc.opd.male_c"), "0.180")               # LOEO C is fine; only the rolling C failed
  dr <- "not estimable (dropped: more than 20% of state-months masked)"
  for (k in grep("\\.fic\\.", want, value = TRUE)) expect_identical(disp(k), dr)
  # §13
  expect_identical(disp("E.idx.opd.oni.std_effect"), fmt_ci(exp(-0.04 * 0.7495), exp((-0.04 - 1.959964 * 0.015) * 0.7495),
                                                             exp((-0.04 + 1.959964 * 0.015) * 0.7495), 2))
  expect_identical(disp("E.idx.opd.oni.se"), fmt_num(0.015 * 0.7495, 3))
  expect_identical(disp("E.idx.opd.oni.aic"), "30000.3")
  expect_identical(disp("E.idx.opd.roni.male"), "0.181")
  expect_identical(disp("E.idx.opd.nino34.log_score"), "8.182")
  expect_identical(disp("E.idx.mcv1.roni.aic"), "not estimable (no likelihood under the block bootstrap)")
  expect_identical(disp("E.idx.mcv1.roni.std_effect"), fmt_ci(exp(-0.04 * 0.7605), exp(-0.08 * 0.7605), exp(0.001 * 0.7605), 2))
  expect_identical(disp("E.idx.inst_del.nino34.std_effect"), "not estimable (Model T: fit_nb: no structure converged for inst_del)")
  expect_identical(disp("E.sens.inst_del.roni"), "not estimable (Model T: fit_nb: no structure converged for inst_del)")
  expect_identical(disp("E.idx.inst_del.nino34.male"), "0.182")   # skill does not depend on Model T
  expect_identical(disp("E.sens.opd.roni"), fmt_ci(exp(-0.04), exp(-0.07), exp(-0.01), 2))
  expect_true(is.na(E[["E.idx.inst_del.oni.std_effect"]]$value))
  for (e in E) {
    expect_true(is.character(e$display) && nzchar(e$display))
    expect_identical(e$script, "models/E/05_forecast.R")
  }
})

test_that("run_forecast refuses to start before the primary Model T estimates exist", {
  expect_error(run_forecast(primary_csv = file.path(tempdir(), "no_such_primary.csv"), write = FALSE),
               "primary_estimates")
})

test_that("run_forecast needs primary_estimates.csv committed after the F61 contract commit 257aacc", {
  fake_git <- function(tracked = TRUE, dirty = FALSE, later = TRUE) {
    calls <- list()
    f <- function(args) {
      calls[[length(calls) + 1L]] <<- args
      switch(args[1], `ls-files` = if (tracked) "papers/E/output/primary_estimates.csv" else character(),
             status = if (dirty) " M papers/E/output/primary_estimates.csv" else character(),
             log = if (later) "abc1234 2026-10-25 12:00:00 +0530 results(paperE): primary rerun" else character())
    }
    list(git = f, calls = function() calls)
  }
  expect_error(assert_primary_post_f61(git = fake_git(tracked = FALSE)$git, release = FALSE), "not committed")
  expect_error(assert_primary_post_f61(git = fake_git(dirty = TRUE)$git, release = FALSE), "uncommitted changes")
  expect_error(assert_primary_post_f61(git = fake_git(later = FALSE)$git, release = FALSE), "not committed after 257aacc")
  g <- fake_git()
  expect_match(assert_primary_post_f61(git = g$git, release = FALSE), "committed after 257aacc (last: abc1234", fixed = TRUE)
  lg <- Filter(function(a) a[1] == "log", g$calls())[[1]]
  expect_true("257aacc..HEAD" %in% lg)
  expect_identical(tail(lg, 1), "papers/E/output/primary_estimates.csv")
  pcsv <- file.path(tempdir(), "primary_estimates_guard.csv"); writeLines("x", pcsv)
  expect_error(run_forecast(primary_csv = pcsv, write = FALSE, check_primary = function() stop("run_forecast: guard hit")),
               "guard hit")
})

test_that("unidentified training coefficients are listed per split and named in the rule description", {
  cm <- list(split_info = data.table::data.table(
    model = c("A", "B", "C", "A"), split_id = c("ep1415", "ep1415", "ep1415", "ep1819"), n_train = 100L,
    n_test = 50L, re_used = "us", unidentified = c("demonet", "demonet", "demonet", ""),
    n_test_rows_nonzero_unidentified = c(99L, 99L, 99L, 0L), fit_messages = ""))
  u <- fc_unidentified(cm)
  expect_identical(nrow(u), 3L)
  expect_identical(fc_unidentified_text(u), "ep1415 demonet (99 test rows non-zero; models A, B, C)")
  expect_identical(fc_unidentified_text(u[0]), "none")
  ft <- fake_forecast_tables()
  un <- cbind(data.table::data.table(outcome = "anc_reg", design = "loeo"), u)
  E <- forecast_entries(ft$skill, ft$idx, dropped = "fic", unidentified = un)
  expect_match(E[["E.fc.anc_reg.rule"]]$description,
               "LOEO: ep1415 demonet (99 test rows non-zero; models A, B, C); rolling: none", fixed = TRUE)
  expect_match(E[["E.fc.opd.rule"]]$description, "LOEO: none; rolling: none", fixed = TRUE)
})

# ---- end to end (synthetic outcomes only; anc_reg at the iid step, mcv1 at the block-bootstrap step, B = 4) ----------------------------------------------------------------------------

# A synthetic model table with every column run_forecast() reads, for all seven outcomes (no HMIS value).
sim_forecast_table <- function(n_units = 4, seed = 31) {
  d <- sim_with_indices(n_units = n_units, beta_en = -0.03, seed = seed)
  set.seed(seed)
  for (o in INDS) {
    mu <- exp(log(d$y + 1) + stats::rnorm(nrow(d), 0, 0.05))
    data.table::set(d, j = o, value = as.numeric(stats::rnbinom(nrow(d), size = 30, mu = mu)))
  }
  m <- unique(d[, .(ym)])[, dmi_3m := round(stats::rnorm(.N, 0, 0.3), 3)]
  d <- m[d, on = "ym"]
  z <- stats::rnorm(nrow(d))
  d[, `:=`(spi3_dry_l0 = pmin(z, 0), spi3_wet_l0 = pmax(z, 0), heatwave_days_l0 = stats::rpois(.N, 1))]
  data.table::setorder(d, unit_id, ym)
  for (o in INDS) d[, (sprintf("log1p_%s_lag12", o)) := log1p(data.table::shift(get(o), 12L)), by = unit_id]
  d[]
}

test_that("run_forecast assembles the keys, the skill table and the index table (synthetic panel)", {
  skip_if_slow_disabled()
  d <- sim_forecast_table()
  tmp <- file.path(tempdir(), "e_forecast_e2e"); dir.create(tmp, showWarnings = FALSE)
  gate <- file.path(tmp, "gate_summary.csv")
  data.table::fwrite(data.table::data.table(indicator = INDS, scope = "primary",
                                            dropped = ifelse(INDS %in% c("anc_reg", "mcv1"), "False", "True")), gate)
  f <- fit_time_chain(t_spec("anc_reg"), d, chain = "iid")
  en <- term_row(f, "en_t")
  prim <- data.table::rbindlist(lapply(INDS, function(o) data.table::data.table(
    outcome = o, model = "T", term = "en_t", est = NA_real_, se = NA_real_, irr = NA_real_, lo = NA_real_,
    hi = NA_real_, p = NA_real_, p_kind = NA_character_, B_ok = NA_integer_, time_re = NA_character_,
    re_used = NA_character_, n = NA_integer_, n_units = NA_integer_, status = "dropped",
    error = "dropped: more than 20% of state-months masked")))
  prim[outcome == "anc_reg", `:=`(est = en$est, se = en$se, irr = en$irr, lo = en$lo, hi = en$hi, p = en$p,
                                  p_kind = "wald", time_re = "iid", re_used = f$re_used, n = as.integer(f$n),
                                  n_units = 4L, status = "ok", error = NA_character_)]
  prim[outcome == "mcv1", `:=`(est = -0.02, se = 0.03, irr = exp(-0.02), lo = exp(-0.08), hi = exp(0.04), p = 0.5,
                               p_kind = "bootstrap", B_ok = 4L, time_re = "block_bootstrap", re_used = "us", n = as.integer(f$n),
                               n_units = 4L, status = "ok", error = NA_character_)]
  pcsv <- file.path(tmp, "primary_estimates.csv")
  data.table::fwrite(prim, pcsv)
  out <- run_forecast(cores = 1L, primary_csv = pcsv, gate_csv = gate, d = d, B = 4L, n_draws = 20L,
                      check_primary = function() "synthetic primary (test)",
                      out_skill = file.path(tmp, "forecast_skill.csv"), out_idx = file.path(tmp, "index_comparison.csv"),
                      rds = file.path(tmp, "forecast.rds"))
  expect_setequal(names(out$entries), forecast_contract_keys())
  expect_true(all(file.exists(file.path(tmp, c("forecast_skill.csv", "index_comparison.csv", "forecast.rds")))))
  sk <- data.table::fread(file.path(tmp, "forecast_skill.csv"))
  expect_setequal(unique(sk$outcome), c("anc_reg", "mcv1"))
  expect_setequal(unique(sk[design == "loeo"]$model), c("A", "B", "C", "C_roni", "C_nino34"))
  expect_setequal(unique(sk[design == "rolling" & split_id != "pooled"]$split_id), sprintf("fy%d", 2015:2019))
  # identical scored rows for every model of a design
  expect_identical(length(unique(sk[split_id == "pooled" & outcome == "anc_reg" & design == "loeo"]$n)), 1L)
  ix <- data.table::fread(file.path(tmp, "index_comparison.csv"))
  expect_identical(nrow(ix), 6L)
  a <- ix[outcome == "anc_reg"]
  expect_equal(a[index == "oni"]$sd_index, index_sd(d, "oni"))
  expect_equal(a[index == "oni"]$std_effect, en$irr^index_sd(d, "oni"), tolerance = 1e-8)
  expect_identical(unique(a$time_re), "iid")
  expect_identical(length(unique(a$n)), 1L)
  expect_true(all(is.finite(a$aic)))
  # Paper D's harvest convention: estimate, lo, hi on the log scale; irr, irr_lo, irr_hi on the IRR scale
  expect_equal(a$lo, log(a$irr_lo)); expect_equal(a$hi, log(a$irr_hi)); expect_equal(a$irr, exp(a$estimate))
  expect_true(all(a$lo < a$estimate & a$estimate < a$hi))
  expect_identical(names(ix)[1:15], c("paper", "outcome", "index", "lag", "term", "estimate", "lo", "hi", "scale",
                                      "ci_source", "p", "aic", "skill_loeo_male", "skill_roll_male", "skill_logscore"))
  expect_equal(a[index == "oni"]$skill_roll_male,
               sk[outcome == "anc_reg" & design == "rolling" & model == "C" & split_id == "pooled"]$male)
  expect_true(all(is.na(a[index != "oni"]$skill_roll_male)))
  expect_true(all(c("outcome", "design", "model", "split_id", "unidentified") %in% names(out$unidentified)))
  E <- out$entries
  r <- a[index == "roni"]
  expect_identical(E[["E.sens.anc_reg.roni"]]$display, fmt_ci(r$irr, r$irr_lo, r$irr_hi, 2))
  expect_equal(E[["E.idx.anc_reg.roni.std_effect"]]$value, E[["E.sens.anc_reg.roni"]]$value^r$sd_index, tolerance = 1e-8)
  expect_identical(E[["E.idx.penta3.roni.std_effect"]]$display, "not estimable (dropped: more than 20% of state-months masked)")
  m <- ix[outcome == "mcv1"]
  expect_identical(unique(m$time_re), "block_bootstrap")
  expect_identical(length(unique(m[status == "ok"]$n)), 1L)
  expect_identical(E[["E.idx.mcv1.oni.aic"]]$display, "not estimable (no likelihood under the block bootstrap)")
  expect_identical(E[["E.fc.fic.rule"]]$display, "not estimable (dropped: more than 20% of state-months masked)")
  expect_true(E[["E.fc.anc_reg.rule"]]$display %in% c("adds skill over local climate", "no added skill demonstrated"))
})

test_that("every forecast and index fit gets the F61 optimiser limits", {
  d <- add_moy_dummies(sim_forecast_table(n_units = 3, seed = 8))
  seen <- list()
  real <- glmmTMB::glmmTMB
  testthat::local_mocked_bindings(glmmTMB = function(formula, data, family, control = glmmTMB::glmmTMBControl(), ...) {
    seen[[length(seen) + 1L]] <<- control$optCtrl
    real(formula, data = data, family = family, control = control, ...)
  }, .package = "glmmTMB")
  ok_ctrl <- function(cs) length(cs) > 0 && all(vapply(cs, function(o) identical(o$iter.max, 1e4) && identical(o$eval.max, 1e4), NA))
  compare_models_m(fc_specs("anc_reg"), d, loeo_month_splits()[2], n_draws = 5L)
  expect_gte(length(seen), 3L)                                     # Models A, B and C (and any us -> diag -> int fallback)
  expect_true(ok_ctrl(seen), info = "compare_models_m default")
  seen <- list()
  compare_models_m(fc_specs("anc_reg")["A"], d, loeo_month_splits()[2], n_draws = 5L, fitter = glmmTMB_fit)
  expect_true(ok_ctrl(seen), info = "the common default fitter is replaced")
  seen <- list()
  index_effects(d, "anc_reg", "roni", time_re = "iid")
  expect_true(ok_ctrl(seen), info = "index_effects iid")
  seen <- list()
  tryCatch(index_effects(d, "anc_reg", "nino34", time_re = "block_bootstrap", B = 2L), error = function(e) NULL)
  expect_true(ok_ctrl(seen), info = "index_effects block bootstrap")
})

test_that("forecast tasks run on PSOCK workers with the panel as a data.table (2 workers)", {
  d <- add_moy_dummies(sim_forecast_table(n_units = 3, seed = 8))
  tasks <- lapply(c("roni", "nino34"), function(k) list(kind = "idx", ind = "anc_reg", index = k, time_re = "iid",
                                                        sd_index = index_sd(d, k)))
  cl <- .e_cluster(2L)
  on.exit(parallel::stopCluster(cl), add = TRUE)
  parallel::clusterCall(cl, .e_forecast_init, MODELS_ROOT)
  parallel::clusterCall(cl, .e_set_global, ".E_FC_DATA", d)
  par <- parallel::clusterApplyLB(cl, tasks, .e_forecast_task)
  assign(".E_FC_DATA", d, envir = globalenv())
  seq_res <- lapply(tasks, .e_forecast_task)
  expect_identical(vapply(par, `[[`, "", "status"), c("ok", "ok"))
  expect_equal(vapply(par, `[[`, 0, "beta"), vapply(seq_res, `[[`, 0, "beta"), tolerance = 1e-8)
  # a data error on a worker is the data error, not a data.frame indexing error
  bad <- list(kind = "idx", ind = "no_such_outcome", index = "roni", time_re = "iid", sd_index = 0.7)
  err <- tryCatch(parallel::clusterApplyLB(cl, list(bad), .e_forecast_task), error = function(e) conditionMessage(e))
  expect_match(err, "missing column(s): no_such_outcome", fixed = TRUE)
})
