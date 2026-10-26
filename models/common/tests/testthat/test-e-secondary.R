# Paper E Task 9: secondary and sensitivity analyses (models/E/R/secondary.R, models/E/04_secondary.R): the
# sensitivity cases (contract papers/E/results_keys.md §11; rulings F19, F23, F28, F44), the distributed-lag basis
# (§10), the IOD counts and fit (§9; F14), the heterogeneity test and rule (§8), the Model L lag-sum and Tmax
# sensitivities (§5 cum02, tmax) and the key assembly. models/common/R is frozen; nothing here edits it. No test
# fits a model to a real HMIS outcome: the real model table is read only for its exposure columns.

local({
  root <- if (exists("MODELS_ROOT")) MODELS_ROOT else normalizePath(file.path(getwd(), "..", "..", ".."), winslash = "/")
  for (f in c("common_e.R", "monthly.R", "power.R", "verdicts.R", "secondary.R"))
    source(file.path(root, "E", "R", f), local = globalenv())
  source(file.path(root, "E", "04_secondary.R"), local = globalenv())
})

# A panel laid out like hmis_model.csv with every column a sensitivity case touches. Units: the seven small units
# plus `n_big` others. Outcome columns are simulated counts; nothing here is real HMIS data.
sec_panel <- function(n_big = 5, n_months = 95, seed = 3, births = FALSE) {
  d <- sim_month_panel(n_units = length(SMALL_UNITS) + n_big, n_months = n_months, seed = seed)
  lab <- c(SMALL_UNITS, sprintf("B%02d", seq_len(n_big)))
  d[, unit_id := factor(lab[as.integer(unit_id)])]
  set.seed(seed)
  for (o in INDS) {
    d[, (o) := y]
    for (s in c("_c75", "_c00", "_scaled", "_masklow", "_allcomp")) d[, paste0(o, s) := y]
  }
  d[, `:=`(sin12 = sin(2 * pi * as.integer(moy) / 12), cos12 = cos(2 * pi * as.integer(moy) / 12),
           era_e2 = hmis_format2017, pmsma = 0L, laqshya = 0L, diwali = as.integer(as.integer(moy) == 11L),
           covid_mar2020 = 0L, covid_fy2021 = 0L, oni = en_t + ln_t, dmi_3m = round(0.4 * sin(ym / 5) + 0.05, 2),
           log_births = if (births) log_pop_days - 4 else NA_real_, log_preg = if (births) log_pop_days - 3.9 else NA_real_)]
  d[, S_z := round(sin(as.integer(unit_id)), 2)]
  d[, `:=`(en_S = en_t * S_z, ln_S = ln_t * S_z)]
  d[, unit_era := interaction(unit_id, era_e2, sep = ":", drop = TRUE, lex.order = TRUE)]
  for (k in 0:6) d[, paste0("en_t_l", k) := en_t]
  for (v in c("spi3_dry", "spi3_wet", "heatwave_days", "tmax_anom")) for (k in 0:2) d[, paste0(v, "_l", k) := 0]
  d[]
}

fy_ok <- list(ok = TRUE, reason = NA_character_)
E2E_OPD_NOT_OK <- character()      # opd sensitivities not estimable on the end-to-end panel (set from the run)

# Tables shaped as run_secondary() assembles them (columns documented in 04_secondary.R), with chosen values.
fake_secondary_tables <- function(dropped = character()) {
  est <- function(status = "ok", e = -0.05, se = 0.02, time_re = "ar1", error = NA_character_) {
    if (status != "ok") return(data.table::data.table(est = NA_real_, se = NA_real_, irr = NA_real_, lo = NA_real_,
      hi = NA_real_, p = NA_real_, p_kind = NA_character_, B_ok = NA_integer_, time_re = NA_character_,
      re_used = NA_character_, n = NA_integer_, n_units = NA_integer_, status = status, error = error))
    data.table::data.table(est = e, se = se, irr = exp(e), lo = exp(e - 1.959964 * se), hi = exp(e + 1.959964 * se),
                           p = 0.01, p_kind = if (is.na(time_re)) "wald" else "wald", B_ok = NA_integer_,
                           time_re = time_re, re_used = "us", n = 3100L, n_units = 34L, status = "ok",
                           error = NA_character_)
  }
  drop_reason <- "dropped: more than 20% of state-months masked"
  sens <- list(); l <- list(); dlm <- list(); iod <- list(); het <- list()
  for (o in INDS) {
    dr <- o %in% dropped
    for (id in SENS_IDS) {
      disp <- NA_character_; st <- if (dr) "dropped" else "ok"
      if (!dr && id == "births") { st <- "skip"; disp <- "not available (SRS not retrieved)" }
      if (!dr && id == "allcomp" && o %in% c("diarr_u5", "anc_reg")) {
        st <- "skip"; disp <- "not applicable (single-item indicator; identical to the primary analysis)"
      }
      sens[[length(sens) + 1L]] <- cbind(data.table::data.table(analysis = "sens", outcome = o, case = id, term = "en_t"),
                                         est(st, error = if (dr) drop_reason else NA_character_),
                                         data.table::data.table(display = disp))
    }
    for (v in c("hw", "dry", "wet"))
      l[[length(l) + 1L]] <- cbind(data.table::data.table(analysis = "l_cum02", outcome = o, case = v, term = v),
                                   est(if (dr) "dropped" else "ok", e = 0.02, se = 0.01, time_re = NA))
    l[[length(l) + 1L]] <- cbind(data.table::data.table(analysis = "l_tmax", outcome = o, case = "tmax", term = "tmax_anom_l0"),
                                 est(if (dr) "dropped" else "ok", e = -0.01, se = 0.004, time_re = NA))
    dlm[[length(dlm) + 1L]] <- data.table::data.table(outcome = o, lag = 0:6, est = log(0.98), se = 0.01, irr = 0.98,
                                                      lo = 0.95, hi = 1.01, p_kind = "wald", B_ok = NA_integer_,
                                                      time_re = "ar1", re_used = "us", n = 3100L, n_units = 34L,
                                                      status = if (dr) "dropped" else "ok", error = NA_character_)
    for (tm in c("dmi_3m", "en_t:dmi_3m"))
      iod[[length(iod) + 1L]] <- cbind(data.table::data.table(outcome = o, term = tm), est(if (dr) "dropped" else "ok"))
    h <- list(outcome = o, lrt_p = 0.2, df = 3L, stat = 1.5, slope_sd = 0.08, sd_lo = 0.001, sd_hi = 0.5, pd_hess = TRUE,
              lrt_p_1415 = 0.3, lrt_p_1819 = 0.4, holds_1415 = FALSE, holds_1819 = FALSE, identifiable = FALSE,
              time_re = "ar1", re_null = "us", re_alt = "us", n = 3100L, n_units = 34L, status = "ok",
              error = NA_character_, drop_errors = "")
    if (o == "anc_reg") h <- utils::modifyList(h, list(lrt_p = 0.001, sd_lo = 0.04, sd_hi = 0.16, lrt_p_1415 = 0.01,
                                                         lrt_p_1819 = 0.02, holds_1415 = TRUE, holds_1819 = TRUE,
                                                         identifiable = TRUE))
    if (o == "penta3") h <- utils::modifyList(h, list(sd_lo = NA_real_, sd_hi = NA_real_))
    if (o == "inst_del") h <- utils::modifyList(h, list(status = "error", error = "no converged time random effect"))
    if (dr) h <- utils::modifyList(h, list(status = "dropped", error = drop_reason))
    het[[o]] <- data.table::as.data.table(h)
  }
  list(sens = data.table::rbindlist(sens, fill = TRUE), l = data.table::rbindlist(l), dlm = data.table::rbindlist(dlm),
       iod = data.table::rbindlist(iod),
       iod_n = data.table::data.table(combo = c("warm_pos", "warm_neg", "cool_pos", "cool_neg"),
                                      n_months = c(30L, 10L, 20L, 35L)),
       het = data.table::rbindlist(het))
}

test_that("sens ids match the contract", {
  k <- contract_keys(file.path(PAPER_E, "results_keys.md"), prefix = "E")
  suffixes <- unique(sub("^E\\.sens\\.[a-z0-9_]+\\.", "", grep("^E\\.sens\\.", k, value = TRUE)))
  expect_setequal(c(SENS_IDS, "roni", "nino34"), suffixes)
  expect_length(SENS_IDS, 14L)
  expect_true(all(c("masklow", "allcomp") %in% SENS_IDS))        # F44 (the brief's list lacked them)
  expect_false(any(c("roni", "nino34") %in% SENS_IDS))           # Task 10
})

test_that("nosmall drops exactly the seven small units", {
  d <- sec_panel()
  cs <- sens_case("nosmall", d, "anc_reg")
  kept <- levels(droplevels(cs$data$unit_id))
  expect_setequal(setdiff(levels(d$unit_id), kept), c("LD", "CH", "PY", "DNH_DD", "AN", "SK", "GA"))
  expect_identical(SMALL_UNITS, c("LD", "CH", "PY", "DNH_DD", "AN", "SK", "GA"))
  expect_equal(nrow(cs$data), nrow(d[!unit_id %in% SMALL_UNITS]))
  expect_identical(cs$spec, t_spec("anc_reg"))
  expect_length(cs$extra, 0L)
})

test_that("dlm basis is 7 x 3 and the cross-basis uses the merged lags", {
  b <- dlm_basis()
  expect_identical(dim(b), c(7L, 3L))
  expect_equal(unname(b), unname(unclass(splines::ns(0:6, df = 3, intercept = TRUE)))[, 1:3], ignore_attr = TRUE)
  # the lag columns are the table's merged en_t_l0..en_t_l6, never a shift of en_t within the panel
  d <- sec_panel(n_big = 1, n_months = 20)
  set.seed(9)
  for (k in 0:6) d[, paste0("en_t_l", k) := round(stats::runif(.N), 2)]
  cb <- cross_basis(d, b)
  expect_true(all(c("en_cb1", "en_cb2", "en_cb3") %in% names(cb)))
  want <- as.matrix(d[, paste0("en_t_l", 0:6), with = FALSE]) %*% b
  expect_equal(unname(as.matrix(cb[, c("en_cb1", "en_cb2", "en_cb3")])), unname(want))
  expect_false("en_cb1" %in% names(d))                              # d is not modified in place
  expect_error(cross_basis(d[, !"en_t_l6"], b), "en_t_l6")
})

test_that("dlm_curve maps coefficients and covariance through the basis", {
  b <- dlm_basis()
  beta <- c(en_cb1 = -0.02, en_cb2 = 0.01, en_cb3 = -0.03)
  V <- diag(c(1e-4, 4e-4, 9e-4)); dimnames(V) <- list(names(beta), names(beta))
  cv <- dlm_curve_from(beta, V, b)
  expect_equal(cv$lag, 0:6)
  expect_equal(log(cv$irr), as.vector(b %*% beta))
  se <- unname(sqrt(diag(b %*% V %*% t(b))))
  expect_equal(log(cv$lo), as.vector(b %*% beta) - 1.959964 * se)
  expect_equal(log(cv$hi), as.vector(b %*% beta) + 1.959964 * se)
  # bootstrap version: percentile intervals of the resampled curves, failed resamples (NA rows) left out
  bb <- list(est = beta, betas = rbind(matrix(rep(beta, 50), 50, byrow = TRUE) +
                                         matrix(stats::rnorm(150, 0, 0.01), 50), NA), B_ok = 50L)
  colnames(bb$betas) <- names(beta)
  cb <- dlm_curve(bb, b)
  curves <- bb$betas[1:50, ] %*% t(b)
  expect_equal(log(cb$lo), unname(apply(curves, 2, stats::quantile, 0.025, names = FALSE)))
  expect_equal(log(cb$irr), as.vector(b %*% beta))
})

test_that("dlm_curve recovers a simulated lag shape", {
  skip_if_slow_disabled()
  set.seed(11)
  d <- sim_month_panel(n_units = 12, n_months = 95, seed = 11)
  oni_path <- rep_len(SIM_ONI_PATH, 95 + 6)
  ym0 <- sort(unique(d$ym))
  for (k in 0:6) d[, paste0("en_t_l", k) := pmax(oni_path[match(ym, ym0) + 6L - k], 0)]
  b <- dlm_basis()
  true_lag <- c(0, -0.02, -0.04, -0.05, -0.04, -0.02, 0)
  eta_lag <- as.vector(as.matrix(d[, paste0("en_t_l", 0:6), with = FALSE]) %*% true_lag)
  d[, y := stats::rnbinom(.N, size = 50, mu = exp(log(y + 0.5) + eta_lag))]
  d[, anc_reg := y]
  part <- dlm_part(d, "anc_reg")
  expect_identical(part$status, "ok")
  cv <- part$out
  expect_equal(nrow(cv), 7L)
  expect_true(all(abs(log(cv$irr) - true_lag) < 0.03))
  expect_true(mean(cv$lo < exp(true_lag) & exp(true_lag) < cv$hi) >= 5 / 7)
})

test_that("het_rule requires all conditions", {
  expect_true(het_rule(0.01, TRUE, 0.02, TRUE, TRUE))
  expect_false(het_rule(0.06, TRUE, 0.02, TRUE, TRUE))
  expect_false(het_rule(0.05, TRUE, 0.02, TRUE, TRUE))      # p < 0.05 strictly
  expect_false(het_rule(0.01, FALSE, 0.02, TRUE, TRUE))
  expect_false(het_rule(0.01, TRUE, 0.01, TRUE, TRUE))      # lower CI > 0.01 strictly
  expect_false(het_rule(0.01, TRUE, 0.005, TRUE, TRUE))
  expect_false(het_rule(0.01, TRUE, 0.02, FALSE, TRUE))
  expect_false(het_rule(0.01, TRUE, 0.02, TRUE, FALSE))
  expect_false(het_rule(NA, TRUE, 0.02, TRUE, TRUE))
  expect_false(het_rule(0.01, TRUE, NA, TRUE, TRUE))
  expect_false(het_rule(0.01, TRUE, 0.02, NA, TRUE))
})

test_that("het_test fits the en_t random slope and compares it with Model T by LRT", {
  skip_if_slow_disabled()
  d <- sim_month_panel(n_units = 20, n_months = 95, seed = 21)
  set.seed(21)
  slope <- stats::rnorm(20, 0, 0.15)
  d[, y := stats::rnbinom(.N, size = 30, mu = (y + 0.5) * exp(slope[as.integer(unit_id)] * en_t))]
  d[, anc_reg := y]
  h <- het_test(d, "anc_reg", time_re = "iid")
  expect_true(is.na(h$error))
  expect_true(h$lrt_p < 0.05)
  expect_true(h$df >= 1L)
  expect_true(h$pd_hess)
  expect_true(h$sd_lo < h$slope_sd && h$slope_sd < h$sd_hi)
  expect_true(abs(h$slope_sd - 0.15) < 0.1)
  expect_identical(names(h$modes), c("unit_id", "mode", "sd"))
  expect_equal(nrow(h$modes), 20L)
  expect_true(is.logical(h$holds_1415) && is.logical(h$holds_1819))
})

test_that("het_test does not fit under the bootstrap step", {
  h <- het_test(sec_panel(n_big = 1, n_months = 20), "anc_reg", time_re = "block_bootstrap",
                fit_fun = function(...) stop("must not fit"))
  expect_identical(h$error, "no converged time random effect")
  expect_true(is.na(h$lrt_p))
})

test_that("iod combos sum to 95 months", {
  d <- read_hmis_model("primary")                    # exposure columns only; no outcome is touched
  n <- iod_counts(d)
  expect_identical(n$combo, c("warm_pos", "warm_neg", "cool_pos", "cool_neg"))
  expect_equal(sum(n$n_months), 95L)
  # ties: ONI 0 is cool, dmi_3m 0 is negative (contract §9)
  t <- data.table::data.table(ym = 1:4, unit_id = "A", oni = c(0, 0.5, -0.5, 0.2), dmi_3m = c(0.1, 0, -0.1, 0.3))
  expect_identical(iod_counts(t)$n_months, c(1L, 1L, 1L, 1L))
  # the exposures are national: one value per month
  bad <- data.table::data.table(ym = c(1, 1), unit_id = c("A", "B"), oni = c(0.1, 0.2), dmi_3m = c(0, 0))
  expect_error(iod_counts(bad), "one ONI")
})

test_that("iod fit adds dmi_3m and the en_t:dmi_3m interaction", {
  s <- iod_inputs("penta3")
  expect_identical(s$spec, t_spec("penta3", extra = "dmi_3m"))
  expect_identical(s$extra, "en_t:dmi_3m")
  expect_identical(s$terms, c("dmi_3m", "en_t:dmi_3m"))
})

test_that("births sensitivity is not applicable for opd and diarrhoea", {
  d <- sec_panel(births = TRUE)
  for (o in c("opd", "diarr_u5")) expect_match(sens_case("births", d, o)$skip, "^not applicable \\(")
  expect_identical(sens_case("births", d, "anc_reg")$spec$offset, "log_preg")
  expect_identical(sens_case("births", d, "inst_del")$spec$offset, "log_births")
  expect_true(is.na(sens_case("births", d, "inst_del")$skip))
  # SRS not retrieved (log_births all NA): every outcome reads the contract's display (F23, F44)
  d0 <- sec_panel(births = FALSE)
  for (o in INDS) expect_identical(sens_case("births", d0, o)$skip, "not available (SRS not retrieved)")
})

test_that("ns2 and harmonic terms travel in extra, not in fixed", {
  d <- sec_panel()
  for (id in SENS_IDS) for (o in c("penta3", "anc_reg", "inst_del")) {
    cs <- sens_case(id, d, o, d_fy2021 = d, fy2021 = fy_ok)
    if (!is.na(cs$skip)) next
    expect_true(all(spec_vars(cs$spec) %in% names(cs$data)), info = paste(id, o))
  }
  ns2 <- sens_case("ns2", d, "anc_reg")
  expect_false("t_c" %in% ns2$spec$fixed)
  expect_identical(ns2$spec$slopes, "t_c")
  expect_match(ns2$extra, "^splines::ns\\(t_c, knots = .*, Boundary.knots = c\\(.*\\)\\)$")
  # on the original rows the fixed-knot basis equals splines::ns(t_c, df = 2) (review finding 5) ...
  tc <- complete_rows(d, spec_vars(ns2$spec))$data$t_c
  fixed <- eval(str2lang(ns2$extra), list(t_c = tc))
  expect_equal(unclass(fixed)[, 1:2], unclass(splines::ns(tc, df = 2))[, 1:2], ignore_attr = TRUE, tolerance = 1e-12)
  # ... and on a resample it keeps the original knots
  rs <- sample(tc, length(tc), replace = TRUE)
  expect_equal(attr(eval(str2lang(ns2$extra), list(t_c = rs)), "knots"), attr(fixed, "knots"))
  expect_equal(attr(eval(str2lang(ns2$extra), list(t_c = rs)), "Boundary.knots"), attr(fixed, "Boundary.knots"))
  h <- sens_case("harmonic", d, "anc_reg")
  expect_identical(h$extra, c("unit_id:sin12", "unit_id:cos12"))
  expect_identical(h$spec, t_spec("anc_reg"))
})

test_that("each sensitivity case changes only what the contract lists", {
  d <- sec_panel()
  e <- sens_case("era_int", d, "penta3")
  expect_true("hmis_format2017" %in% e$spec$fixed)                       # F28: the step is kept
  expect_identical(e$extra, "(1 | unit_era)")
  for (s in c(comp075 = "_c75", comp000 = "_c00", scaled = "_scaled", masklow = "_masklow", allcomp = "_allcomp")) {
    id <- names(which(c(comp075 = "_c75", comp000 = "_c00", scaled = "_scaled", masklow = "_masklow",
                        allcomp = "_allcomp") == s))
    cs <- sens_case(id, d, "penta3")
    expect_identical(cs$spec$outcome, paste0("penta3", s))
    expect_identical(cs$spec$fixed, t_spec("penta3")$fixed)              # programme terms of penta3 kept (mi_round)
  }
  for (o in c("diarr_u5", "anc_reg"))
    expect_identical(sens_case("allcomp", d, o)$skip,
                     "not applicable (single-item indicator; identical to the primary analysis)")
  # extra_prog: diwali for every outcome, pmsma for anc_reg only, laqshya for inst_del only (contract §11; F45)
  expect_identical(setdiff(sens_case("extra_prog", d, "anc_reg")$spec$fixed, t_spec("anc_reg")$fixed), c("pmsma", "diwali"))
  expect_identical(setdiff(sens_case("extra_prog", d, "inst_del")$spec$fixed, t_spec("inst_del")$fixed), c("laqshya", "diwali"))
  for (o in c("diarr_u5", "penta3", "mcv1", "fic", "opd"))
    expect_identical(setdiff(sens_case("extra_prog", d, o)$spec$fixed, t_spec(o)$fixed), "diwali")
  # episode windows dropped
  e1 <- sens_case("drop_ep1415", d, "opd")
  expect_false(any(e1$data$ym >= 2014L * 12L + 9L & e1$data$ym <= 2016L * 12L + 11L))
  expect_equal(length(unique(e1$data$ym)), 95L - 27L)
  e2 <- sens_case("drop_ep1819", d, "opd")
  expect_false(any(e2$data$ym >= 2018L * 12L + 8L & e2$data$ym <= 2020L * 12L + 1L))
  expect_equal(length(unique(e2$data$ym)), 95L - 18L)
  expect_error(sens_case("roni", d, "opd"))
})

test_that("fy2021 case runs through March 2021 with both COVID indicators, or reads not estimable", {
  d <- sec_panel()
  dfy <- sec_panel(n_months = 108)
  cs <- sens_case("fy2021", d, "anc_reg", d_fy2021 = dfy, fy2021 = fy_ok)
  expect_true(all(c("covid_mar2020", "covid_fy2021") %in% cs$spec$fixed))       # F19
  expect_equal(length(unique(cs$data$ym)), 108L)
  expect_equal(max(cs$data$ym), 2021L * 12L + 2L)
  no <- sens_case("fy2021", d, "anc_reg", d_fy2021 = dfy, fy2021 = list(ok = FALSE, reason = "not acquired (status running)"))
  expect_identical(no$skip, "not estimable (FY2020-21 not acquired (status running))")
})

test_that("fy2021 case reads not estimable when the model table has no FY2020-21 rows (public release)", {
  d <- sec_panel()
  dfy <- sec_panel(n_months = 108)
  dfy[, fy := "2019-20"]
  cs <- sens_case("fy2021", d, "anc_reg", d_fy2021 = dfy, fy2021 = fy_ok)
  expect_match(cs$skip, "not estimable (FY2020-21 rows not in the model table", fixed = TRUE)
  dfy[ym >= 2020L * 12L + 3L, fy := "2020-21"]
  expect_true(is.na(sens_case("fy2021", d, "anc_reg", d_fy2021 = dfy, fy2021 = fy_ok)$skip))
})

test_that("fy2021_ready reads the status file and requires it committed and clean", {
  p <- tempfile(fileext = ".json")
  writeLines('{\n "status": "acquired",\n "n_files": 456\n}', p)
  clean <- function(args) if (args[1] == "ls-files") p else character()
  expect_true(fy2021_ready(p, git = clean, release = FALSE)$ok)
  dirty <- function(args) if (args[1] == "ls-files") p else paste("M", p)
  expect_match(fy2021_ready(p, git = dirty, release = FALSE)$reason, "uncommitted")
  untracked <- function(args) character()
  expect_match(fy2021_ready(p, git = untracked, release = FALSE)$reason, "not committed")
  writeLines('{"status": "running"}', p)
  r <- fy2021_ready(p, git = clean, release = FALSE)
  expect_false(r$ok)
  expect_identical(r$reason, "not acquired (status running)")
  expect_identical(fy2021_ready(tempfile(), git = clean, release = FALSE)$reason, "status file missing")
})

test_that("model_l_tmax never enters tmax_anom with heatwave_days", {
  s <- l_tmax_spec("opd")
  expect_true("tmax_anom_l0" %in% s$fixed)
  expect_false(any(grepl("heatwave", s$fixed)))
  expect_identical(s$fixed, c("spi3_dry_l0", "spi3_wet_l0", "tmax_anom_l0", "ym_f"))
  l <- l_lags_spec("opd")
  expect_identical(sort(setdiff(l$fixed, "ym_f")),
                   sort(paste0(rep(c("spi3_dry", "spi3_wet", "heatwave_days"), each = 3), "_l", 0:2)))
  expect_false(any(grepl("tmax", l$fixed)))
})

test_that("lag sums use the covariance of the three coefficients", {
  est <- c(a = 0.01, b = -0.02, c = 0.03)
  V <- matrix(c(4, 1, 0, 1, 9, 2, 0, 2, 16) * 1e-6, 3, dimnames = list(names(est), names(est)))
  r <- lin_comb(est, V, names(est))
  expect_equal(r$est, 0.02)
  expect_equal(r$se, sqrt(sum(V)))
  expect_equal(r$p, 2 * stats::pnorm(-abs(0.02 / sqrt(sum(V)))))
})

test_that("model_l_lags returns the summed lag IRRs from one fit", {
  skip_if_slow_disabled()
  d <- sec_panel(n_big = 5, n_months = 60, seed = 5)
  set.seed(5)
  for (v in c("spi3_dry", "spi3_wet", "heatwave_days")) for (k in 0:2) d[, paste0(v, "_l", k) := round(stats::rnorm(.N), 2)]
  d[, opd := stats::rnbinom(.N, size = 40, mu = (y + 0.5) * exp(-0.03 * (heatwave_days_l0 + heatwave_days_l1 + heatwave_days_l2)))]
  r <- model_l_lags(d, "opd")
  expect_identical(r$term, c("hw", "dry", "wet"))
  expect_true(abs(log(r[term == "hw"]$irr) + 0.09) < 0.04)
  expect_true(all(r$lo < r$irr & r$irr < r$hi))
  t <- model_l_tmax(d, "opd")
  expect_identical(t$term, "tmax_anom_l0")
})

test_that("every secondary fit gets the F61 optimiser limits (Model L lags and Tmax, het_test, chain parts)", {
  d <- sec_panel(n_big = 1, n_months = 36, seed = 4)
  set.seed(4)
  for (v in c("spi3_dry", "spi3_wet", "heatwave_days", "tmax_anom")) for (k in 0:2)
    d[, paste0(v, "_l", k) := round(stats::rnorm(.N), 2)]
  d[, opd := y]
  seen <- list()
  real <- glmmTMB::glmmTMB
  testthat::local_mocked_bindings(glmmTMB = function(formula, data, family, control = glmmTMB::glmmTMBControl(), ...) {
    seen[[length(seen) + 1L]] <<- control$optCtrl
    real(formula, data = data, family = family, control = control, ...)
  }, .package = "glmmTMB")
  ok_ctrl <- function(cs) length(cs) > 0 &&
    all(vapply(cs, function(o) identical(o$iter.max, 1e4) && identical(o$eval.max, 1e4), NA))
  try(model_l_lags(d, "opd"), silent = TRUE); expect_true(ok_ctrl(seen), info = "model_l_lags"); seen <- list()
  try(model_l_tmax(d, "opd"), silent = TRUE); expect_true(ok_ctrl(seen), info = "model_l_tmax"); seen <- list()
  # the common default fitter handed in is replaced by the controlled one
  try(model_l_tmax(d, "opd", fit_fun = glmmTMB_fit), silent = TRUE); expect_true(ok_ctrl(seen)); seen <- list()
  het_test(d, "opd", time_re = "iid", drop_episodes = FALSE); expect_true(ok_ctrl(seen), info = "het_test"); seen <- list()
  t_chain_part(t_spec("opd"), d, "en_t", extra = "(1 | unit_era)", fit_fun = glmmTMB_fit)
  expect_true(ok_ctrl(seen), info = "t_chain_part"); seen <- list()
  suppressWarnings(extra_fitter("(1 | unit_era)", glmmTMB_fit)(spec_formula(t_spec("opd"), "int"), d))   # a direct fit
  expect_true(ok_ctrl(seen), info = "extra_fitter")
})

test_that("the F62 BFGS fits reach glmmTMB with optim BFGS (Models S and L, cum02, tmax)", {
  d <- sec_panel(n_big = 1, n_months = 36, seed = 4)
  set.seed(4)
  for (v in c("spi3_dry", "spi3_wet", "heatwave_days", "tmax_anom")) for (k in 0:2)
    d[, paste0(v, "_l", k) := round(stats::rnorm(.N), 2)]
  d[, opd := y]
  seen <- list()
  real <- glmmTMB::glmmTMB
  testthat::local_mocked_bindings(glmmTMB = function(formula, data, family, control = glmmTMB::glmmTMBControl(), ...) {
    seen[[length(seen) + 1L]] <<- control
    real(formula, data = data, family = family, control = control, ...)
  }, .package = "glmmTMB")
  ok_bfgs <- function(cs) length(cs) > 0 && all(vapply(cs, function(c) identical(c$optimizer, stats::optim) &&
                                                          identical(c$optArgs$method, "BFGS") &&
                                                          identical(c$optCtrl$maxit, 1e4), NA))
  for (m in c("S", "L")) {
    r <- tryCatch(model_sl_bfgs(d, "opd", model = m), error = function(e) e)
    expect_true(ok_bfgs(seen), info = m); seen <- list()
    if (!inherits(r, "error")) {
      expect_identical(r$term, if (m == "S") S_TERMS else L_TERMS)
      expect_true(all(c("pd_hess", "max_grad", "notes") %in% names(r)))
    }
  }
  try(model_l_lags(d, "opd", fit_fun = e_bfgs_fit), silent = TRUE); expect_true(ok_bfgs(seen)); seen <- list()
  try(model_l_tmax(d, "opd", fit_fun = e_bfgs_fit), silent = TRUE); expect_true(ok_bfgs(seen))
  expect_identical(e_fitter(e_bfgs_fit), e_bfgs_fit)
  expect_identical(BFGS_NOTE, "sensitivity; no verdict; not in the Holm family")
  expect_identical(BFGS_OUTCOMES, "opd")
})

test_that("fitter messages are kept as notes", {
  expect_identical(fit_notes(list(messages = c(" dropping columns from rank-deficient conditional model: x ", "",
                                               "dropping columns from rank-deficient conditional model: x"))),
                   "dropping columns from rank-deficient conditional model: x")
  expect_true(is.na(fit_notes(list(messages = character()))))
  r <- list(status = "ok", rows = data.table::data.table(time_re = "ar1", pd_hess = TRUE, max_grad = 0.001,
                                                         notes = "dropping columns: x"))
  expect_match(.task_status(r), "ok, ar1; pdHess TRUE, max|grad| 0.001 [fitter messages: dropping columns: x]",
               fixed = TRUE)
})

test_that("a slope-SD interval failure inside het_test is not estimable, other errors stop (F56)", {
  d <- sec_panel(n_big = 1, n_months = 20)
  old <- list(lrt = .het_lrt, ci = .slope_sd_ci)
  on.exit({ assign(".het_lrt", old$lrt, envir = globalenv()); assign(".slope_sd_ci", old$ci, envir = globalenv()) })
  assign(".het_lrt", function(...) list(f1 = list(model = NULL)), envir = globalenv())
  assign(".slope_sd_ci", function(...) stop("het_test: theta index does not match the SD", call. = FALSE),
         envir = globalenv())
  h <- het_test(d, "anc_reg", time_re = "iid")
  expect_identical(h$error, "het_test: theta index does not match the SD")
  assign(".slope_sd_ci", function(...) stop("object 'zz' not found", call. = FALSE), envir = globalenv())
  expect_error(het_test(d, "anc_reg", time_re = "iid"), "zz")
})

test_that("task checkpoints round-trip and are ignored when the fingerprint or task differs", {
  dir <- tempfile("ck_")
  task <- list(kind = "sens", ind = "opd", id = "ns2")
  .ckpt_save(dir, task, list(status = "ok", value = 1), fp = c("a", "b"))
  expect_identical(.ckpt_load(dir, task, c("a", "b"))$value, 1)
  expect_null(.ckpt_load(dir, task, c("a", "c")))
  expect_null(.ckpt_load(dir, list(kind = "sens", ind = "opd", id = "harmonic"), c("a", "b")))
  expect_null(.ckpt_load(NULL, task, c("a", "b")))
  expect_false(file.exists(paste0(.ckpt_path(dir, task), ".tmp")))
})

test_that("run_secondary refuses unless primary_estimates.csv is committed after Amendment 3 (257aacc)", {
  ok <- function(args) if (args[1] == "ls-files") "p" else if (args[1] == "log") "abc123 2026-10-25 results" else character()
  expect_match(assert_primary_post_f61(git = ok, caller = "run_secondary", release = FALSE), "committed after 257aacc")
  expect_error(assert_primary_post_f61(git = function(args) character(), caller = "run_secondary", release = FALSE), "is not committed")
  dirty <- function(args) if (args[1] == "ls-files") "p" else if (args[1] == "status") " M p" else character()
  expect_error(assert_primary_post_f61(git = dirty, caller = "run_secondary", release = FALSE), "uncommitted")
  old <- function(args) if (args[1] == "ls-files") "p" else character()
  expect_error(assert_primary_post_f61(git = old, caller = "run_secondary", release = FALSE), "not committed after 257aacc")
  # release mode (final review, finding 3): the history guards are skipped with a logged notice, git is never called
  never <- function(args) stop("git called")
  expect_match(assert_primary_post_f61(git = never, caller = "run_secondary", release = TRUE), "^release mode: run_secondary")
  expect_match(assert_power_design_fixed(git = never, release = TRUE), "^release mode:")
  p <- tempfile(fileext = ".json"); writeLines('{"status": "acquired"}', p)
  expect_true(fy2021_ready(p, git = never, release = TRUE)$ok)
  writeLines('{"status": "running"}', p)
  expect_false(fy2021_ready(p, git = never, release = TRUE)$ok)
  tmp <- tempfile("g_"); dir.create(tmp)
  prim <- file.path(tmp, "primary_estimates.csv")
  data.table::fwrite(data.table::data.table(outcome = INDS, model = "T", term = "en_t", irr = 1, time_re = "ar1",
                                            status = "ok", error = NA_character_), prim)
  expect_error(run_secondary(primary_csv = prim, check_primary = function() stop("run_secondary: guard"),
                             d = sec_panel(n_big = 1, n_months = 20)), "guard")
})

test_that("PSOCK workers use the fitter passed to run_secondary", {
  d <- sec_panel(n_big = 1, n_months = 24, seed = 6)
  tmp <- tempfile("w_"); dir.create(tmp)
  marker <- file.path(tmp, "marker.txt")
  # a top-level spy (global environment) that records the process it runs in, then fails like a non-converging fit
  spy <- eval(bquote(function(formula, data, family = glmmTMB::nbinom2()) {
    cat(Sys.getpid(), "\n", file = .(marker), append = TRUE)
    stop("spy fit")
  }), globalenv())
  prim <- file.path(tmp, "primary_estimates.csv")
  data.table::fwrite(data.table::data.table(outcome = INDS, model = "T", term = "en_t", irr = 0.97, time_re = "iid",
                                            status = "ok", error = NA_character_), prim)
  gate <- file.path(tmp, "gate_summary.csv")
  data.table::fwrite(data.table::data.table(indicator = INDS, scope = "primary", dropped = INDS != "opd"), gate)
  r <- run_secondary(cores = 2L, B = 2L, primary_csv = prim, out_dir = tmp, rds = file.path(tmp, "s.rds"),
                     gate_csv = gate, fy2021 = list(ok = FALSE, reason = "x"), d = d, fit_fun = spy,
                     log_file = file.path(tmp, "s.log"), ckpt_dir = NULL, check_primary = function() "test",
                     bfgs_outcomes = character())
  pids <- unique(trimws(readLines(marker)))
  expect_true(length(setdiff(pids, as.character(Sys.getpid()))) >= 1L)     # the workers fitted with the spy
  expect_true(all(r$tables$sens[outcome == "opd" & status != "skip"]$status == "error"))
  expect_error(run_secondary(cores = 2L, primary_csv = prim, gate_csv = gate, d = d, check_primary = function() "t",
                             fit_fun = function(formula, data, family) NULL, write = FALSE, ckpt_dir = NULL,
                             log_file = file.path(tmp, "s.log"), fy2021 = list(ok = FALSE, reason = "x")),
               "top-level")
})

test_that("an extra-term fitter strips the bootstrap carrier columns and appends the extra terms", {
  seen <- NULL
  spy <- function(formula, data, family = glmmTMB::nbinom2()) { seen <<- deparse1(formula); "fit" }
  spec <- t_spec("anc_reg", extra = c("sin12", "cos12"))
  ff <- extra_fitter(c("unit_id:sin12", "unit_id:cos12"), spy, carriers = c("sin12", "cos12"))
  expect_identical(environment(ff), globalenv())                # PSOCK-safe (block_bootstrap_irr's closure check)
  ff(spec_formula(spec, "us"), NULL)
  expect_identical(seen, deparse1(stats::as.formula(paste(
    "anc_reg ~ en_t + ln_t + moy + t_c + hmis_format2017 + demonet + offset(log_pop_days) + (1 + t_c | unit_id) +",
    "unit_id:sin12 + unit_id:cos12"))))
  expect_error(extra_fitter("x", spy, carriers = "zz")(spec_formula(spec, "us"), NULL), "carrier")
  expect_identical(bootstrap_carriers(t_spec("opd"), c("(1 | unit_era)", "splines::ns(t_c, df = 2)", "en_t:ln_t")),
                   "unit_era")
  expect_identical(bootstrap_carriers(iod_inputs("opd")$spec, iod_inputs("opd")$extra), character())
})

test_that("t_chain_part falls through to the bootstrap and only estimation failures are not estimable", {
  d <- sec_panel(n_big = 1, n_months = 20)
  spec <- t_spec("anc_reg")
  nc <- function(formula, data, family = glmmTMB::nbinom2()) stop("no convergence")
  part <- t_chain_part(spec, d, "en_t", fit_fun = nc)
  expect_identical(part$status, "chain_failed")
  fake_boot <- function(spec, d, term, B, block, seed, cores, fit_fun, progress) {
    list(term = term, est = c(en_t = -0.1), se = c(en_t = 0.05), irr = c(en_t = exp(-0.1)), lo = c(en_t = 0.8),
         hi = c(en_t = 0.99), p = c(en_t = 0.02), B = B, B_ok = B, B_failed = 0L, re_used = "us", n = 100L,
         n_units = 8L, betas = matrix(-0.1, B, 1, dimnames = list(NULL, term)), error_counts = integer())
  }
  r <- t_chain_resolve(part, d, B = 7L, boot_fun = fake_boot, log_fun = function(...) NULL)
  expect_identical(r$rows$time_re, "block_bootstrap")
  expect_identical(r$rows$p_kind, "bootstrap")
  expect_identical(r$rows$B_ok, 7L)
  too_many <- function(...) stop(errorCondition("block bootstrap: more than 10% of refits failed (x)",
                                                class = "e_boot_too_many_failed", B_ok = 3L))
  r2 <- t_chain_resolve(part, d, B = 7L, boot_fun = too_many, log_fun = function(...) NULL)
  expect_identical(r2$rows$status, "error")
  expect_identical(r2$rows$B_ok, 3L)
  expect_match(r2$rows$error, "^block bootstrap: more than 10%")
  prog <- function(...) stop("object 'zz' not found")
  expect_error(t_chain_resolve(part, d, B = 7L, boot_fun = prog, log_fun = function(...) NULL), "zz")
  # a missing column is not an estimation failure: it stops (F56)
  expect_error(t_chain_part(t_spec("nope"), d, "en_t", fit_fun = nc), "missing column")
})

test_that("the real block bootstrap runs with carrier columns on PSOCK workers (harmonic, era_int)", {
  skip_if_slow_disabled()
  d <- sec_panel(n_big = 5, n_months = 60, seed = 12)
  d[, anc_reg := y]
  for (id in c("harmonic", "era_int")) {
    cs <- sens_case(id, d, "anc_reg")
    part <- list(status = "chain_failed", spec = cs$spec, terms = "en_t", extra = cs$extra, error = "test")
    r <- t_chain_resolve(part, cs$data, B = 3L, cores = 2L, log_fun = function(...) NULL, label = id)
    expect_true(r$status %in% c("ok", "error"), info = id)
    if (r$status == "error") expect_match(r$error, "^block bootstrap: more than 10%", info = id)   # convergence only
    else expect_identical(r$rows$time_re, "block_bootstrap")
    expect_false(grepl("carrier|not found|missing column", paste(r$error), ignore.case = TRUE), info = id)
  }
})

test_that("secondary entries cover exactly the contract keys this script owns", {
  want <- secondary_contract_keys()
  expect_length(want, 214L)          # het 21 + iod 18 + dlm 49 + sens 98 + l cum02 21 + l tmax 7
  tabs <- fake_secondary_tables(dropped = "fic")
  E <- secondary_entries(tabs)
  expect_setequal(names(E), want)
  expect_true(all(vapply(E, function(e) is.character(e$display) && nzchar(e$display), NA)))
  expect_identical(E[["E.sens.fic.nosmall"]]$display, "not estimable (dropped: more than 20% of state-months masked)")
  expect_identical(E[["E.het.fic.identifiable"]]$display, "not estimable (dropped: more than 20% of state-months masked)")
  expect_identical(E[["E.sens.opd.births"]]$display, "not available (SRS not retrieved)")
  expect_true(is.na(E[["E.sens.opd.births"]]$value))
  expect_identical(E[["E.sens.anc_reg.allcomp"]]$display,
                   "not applicable (single-item indicator; identical to the primary analysis)")
  expect_identical(E[["E.sens.opd.nosmall"]]$display, fmt_ci(exp(-0.05), exp(-0.05 - 1.959964 * 0.02), exp(-0.05 + 1.959964 * 0.02), 2))
  expect_match(E[["E.sens.opd.nosmall"]]$description, "AR(1) year-month random effect", fixed = TRUE)
  # dry cum02 displays exp(-sum) with swapped bounds; wet and hw exp(sum)
  r <- tabs$l[outcome == "opd" & term == "dry"]
  expect_equal(E[["E.l.opd.dry.cum02"]]$value, 1 / r$irr)
  expect_identical(E[["E.l.opd.dry.cum02"]]$display, fmt_ci(1 / r$irr, 1 / r$hi, 1 / r$lo, 2))
  expect_identical(E[["E.iod.n_months.warm_pos"]]$display, "30")
  expect_identical(E[["E.het.opd.identifiable"]]$display, "not identifiable (spec §5.5 rule not met)")
  expect_identical(E[["E.het.opd.identifiable"]]$value, FALSE)
  expect_identical(E[["E.het.anc_reg.identifiable"]]$display, "identifiable (spec §5.5 rule met)")
  expect_identical(E[["E.het.anc_reg.slope_sd"]]$display, fmt_ci(0.08, 0.04, 0.16, 3))
  expect_identical(E[["E.het.penta3.slope_sd"]]$display, "0.080 (CI not estimable)")
  expect_identical(E[["E.het.inst_del.lrt_p"]]$display, "not estimable (no converged time random effect)")
  expect_identical(E[["E.het.inst_del.identifiable"]]$display, "not estimable (no converged time random effect)")
  expect_identical(E[["E.dlm.opd.lag3"]]$display, fmt_ci(0.98, 0.95, 1.01, 2))
})

test_that("run_secondary runs every analysis end to end on a simulated panel and writes the contract keys", {
  skip_if_slow_disabled()
  d <- sec_panel(n_big = 3, n_months = 40, seed = 8)
  set.seed(8)
  for (k in 0:6) d[, paste0("en_t_l", k) := pmax(round(stats::rnorm(.N, 0.3, 0.5), 2), 0)]
  for (v in c("spi3_dry", "spi3_wet", "heatwave_days", "tmax_anom")) for (k in 0:2)
    d[, paste0(v, "_l", k) := round(stats::rnorm(.N), 2)]
  tmp <- tempfile("sec_"); dir.create(tmp)
  prim <- file.path(tmp, "primary_estimates.csv")
  data.table::fwrite(data.table::data.table(outcome = INDS, model = "T", term = "en_t", irr = 0.97,
                                            time_re = c("iid", "block_bootstrap", rep("iid", 5)), status = "ok",
                                            error = NA_character_), prim)
  gate <- file.path(tmp, "gate_summary.csv")
  data.table::fwrite(data.table::data.table(indicator = INDS, scope = "primary", dropped = INDS == "fic"), gate)
  ck <- file.path(tmp, "ckpt")
  r <- run_secondary(cores = 2L, B = 5L, primary_csv = prim, out_dir = tmp, rds = file.path(tmp, "secondary.rds"),
                     gate_csv = gate, fy2021 = list(ok = FALSE, reason = "status file missing"), d = d,
                     log_file = file.path(tmp, "secondary.log"), ckpt_dir = ck, check_primary = function() "test")
  expect_setequal(names(r$entries), secondary_contract_keys())
  for (f in c("sensitivity.csv", "dlm.csv", "iod.csv", "heterogeneity.csv", "het_modes.csv", "secondary.rds"))
    expect_true(file.exists(file.path(tmp, f)), info = f)
  E <- r$entries
  expect_identical(E[["E.sens.opd.fy2021"]]$display, "not estimable (FY2020-21 status file missing)")
  expect_identical(E[["E.sens.fic.ns2"]]$display, "not estimable (dropped: more than 20% of state-months masked)")
  expect_identical(E[["E.het.anc_reg.lrt_p"]]$display, "not estimable (no converged time random effect)")
  expect_identical(E[["E.iod.n_months.warm_pos"]]$value + E[["E.iod.n_months.warm_neg"]]$value +
                     E[["E.iod.n_months.cool_pos"]]$value + E[["E.iod.n_months.cool_neg"]]$value, 40L)
  s <- r$tables$sens[outcome == "opd" & status != "skip"]
  message("E2E opd sensitivity statuses: ", paste(s$case, s$status, s$time_re, collapse = "; "))
  expect_identical(sort(s$case), sort(setdiff(SENS_IDS, c("fy2021", "births"))))
  expect_identical(s[status != "ok"]$case, E2E_OPD_NOT_OK)
  expect_true(all(s[status == "ok"]$time_re %in% c("ar1", "iid", "block_bootstrap")))
  # F62 BFGS rows for opd (descriptive; no key)
  b <- data.table::fread(file.path(tmp, "sensitivity.csv"))[grepl("bfgs", analysis)]
  expect_true(all(c("s_bfgs", "l_bfgs") %in% b$analysis))
  expect_true(all(b$outcome == "opd"))
  expect_true(all(b$note == "sensitivity; no verdict; not in the Holm family"))
  expect_false(any(grepl("bfgs", names(r$entries))))
  hm <- data.table::fread(file.path(tmp, "het_modes.csv"))
  expect_identical(names(hm), c("outcome", "unit_id", "mode", "sd", "identifiable"))
  expect_true(nrow(hm) > 0L && !"anc_reg" %in% hm$outcome)
  # resume: every task comes from its checkpoint; a fitter that fails on use proves nothing is refitted
  r2 <- run_secondary(cores = 1L, B = 5L, primary_csv = prim, out_dir = tmp, rds = file.path(tmp, "secondary.rds"),
                      gate_csv = gate, fy2021 = list(ok = FALSE, reason = "status file missing"), d = d,
                      log_file = file.path(tmp, "secondary2.log"), ckpt_dir = ck, check_primary = function() "test",
                      fit_fun = function(...) stop("must not refit"), boot_fun = function(...) stop("must not refit"))
  expect_identical(r2$entries, r$entries)
  expect_true(any(grepl("from checkpoints, 0 to fit", readLines(file.path(tmp, "secondary2.log")), fixed = TRUE)))
  expect_true(all(c("hw", "dry", "wet", "tmax") %in% r$tables$l[outcome == "opd"]$case))
  expect_equal(nrow(r$tables$dlm), 7L * 7L)
  log <- readLines(file.path(tmp, "secondary.log"), warn = FALSE)
  expect_true(any(grepl("opd sens nosmall: ", log, fixed = TRUE)))
})

test_that("sensitivity crossings flag an H7/H8 point estimate moving across 1", {
  tabs <- fake_secondary_tables()
  prim <- data.table::data.table(outcome = PRIMARY5, model = "T", term = "en_t", irr = c(1.02, 0.97, 0.98, 0.99, 0.96),
                                 status = "ok")
  x <- sens_crossings(tabs$sens, prim)
  expect_true(all(x$outcome %in% PRIMARY5))
  # fake sens IRRs are exp(-0.05) < 1 everywhere: only diarr_u5 (primary 1.02) crosses
  expect_setequal(unique(x$outcome), "diarr_u5")
})
