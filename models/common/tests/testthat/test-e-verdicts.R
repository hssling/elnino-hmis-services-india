# Paper E Task 8: Holm family, H7-H9 verdicts, the Model S reading rule, the month-block bootstrap and the
# primary-model assembly (models/E/R/verdicts.R, models/E/R/monthly.R, models/E/02_primary.R). The rules are the
# contract's (papers/E/results_keys.md §2-§5, "Rules fixed before results"; rulings F18, F52). models/common/R is
# frozen; nothing here edits it.

local({
  root <- if (exists("MODELS_ROOT")) MODELS_ROOT else normalizePath(file.path(getwd(), "..", "..", ".."), winslash = "/")
  for (f in c("common_e.R", "monthly.R", "power.R", "verdicts.R")) source(file.path(root, "E", "R", f), local = globalenv())
  source(file.path(root, "E", "02_primary.R"), local = globalenv())
})

YES <- "consistent with"
NO <- "not consistent with"

# sim_month_panel() plus the episode terms of the contract (ep1415 = Oct 2014..Dec 2016, ep1819 = Sep 2018..Feb 2020)
sim_with_episodes <- function(...) {
  d <- sim_month_panel(...)
  ep1415 <- d$ym >= 2014L * 12L + 9L & d$ym <= 2016L * 12L + 11L
  ep1819 <- d$ym >= 2018L * 12L + 8L & d$ym <= 2020L * 12L + 1L
  d[, `:=`(en_ep1415 = en_t * ep1415, en_ep1819 = en_t * ep1819, en_other = en_t * !(ep1415 | ep1819))]
  d[]
}

# A primary table as run_primary() assembles it, with chosen estimates.
fake_primary_table <- function(drop_penta3 = TRUE) {
  one <- function(o, model, term, est = -0.05, se = 0.02, p = 0.001, p_kind = "wald", B_ok = NA_integer_,
                  time_re = "ar1", status = "ok", error = NA_character_) {
    data.table::data.table(outcome = o, model = model, term = term, est = est, se = se, irr = exp(est),
               lo = exp(est - 1.959964 * se), hi = exp(est + 1.959964 * se), p = p, p_kind = p_kind, B_ok = B_ok,
               time_re = time_re, re_used = "us", n = 3100L, n_units = 34L, status = status, error = error)
  }
  rows <- list()
  for (o in INDS) {
    rows <- c(rows, list(one(o, "T", "en_t"), one(o, "T", "ln_t", est = 0.02),
                         one(o, "T_ep", "en_ep1415", est = -0.04), one(o, "T_ep", "en_ep1819", est = -0.06),
                         one(o, "T_ep", "en_other"), one(o, "T_ep", "ln_t"),
                         one(o, "S", "en_S", est = -0.03, se = 0.01, time_re = NA), one(o, "S", "ln_S", time_re = NA),
                         one(o, "L", "spi3_dry_l0", est = 0.04, se = 0.01, time_re = NA),
                         one(o, "L", "spi3_wet_l0", est = 0.01, p = 0.5, time_re = NA),
                         one(o, "L", "heatwave_days_l0", est = 0.001, p = 0.6, time_re = NA)))
  }
  tab <- data.table::rbindlist(rows)
  # opd: the time chain reached the block bootstrap and no resample crossed 0
  tab[outcome == "opd" & model %in% c("T", "T_ep"), `:=`(p_kind = "bootstrap", B_ok = 1000L, time_re = "block_bootstrap")]
  tab[outcome == "opd" & model == "T" & term == "en_t", p := 0]
  # inst_del: the episode model failed
  tab[outcome == "inst_del" & model == "T_ep", `:=`(est = NA, se = NA, irr = NA, lo = NA, hi = NA, p = NA,
                                                    status = "error", error = "fit_nb: boom")]
  # penta3: dropped by the 20% masking rule
  if (drop_penta3) tab[outcome == "penta3", `:=`(est = NA, se = NA, irr = NA, lo = NA, hi = NA, p = NA, time_re = NA, re_used = NA,
                                n = NA, n_units = NA, status = "dropped",
                                error = "dropped: more than 20% of state-months masked")]
  # diarr_u5 decreases (H8 hypothesises an increase)
  tab[outcome == "diarr_u5" & model == "T", est := -0.08]
  tab[outcome == "diarr_u5" & model == "T", `:=`(irr = exp(est), lo = exp(est - 1.959964 * se), hi = exp(est + 1.959964 * se))]
  tab[]
}

test_that("holm family excludes not-estimable tests and marks them not consistent", {
  t <- data.table::data.table(test_id = 1:3, hypothesis = "H7", outcome = c("a","b","c"), est = c(-.1,-.1,NA), p = c(.01,.02,NA), direction = "lt")
  h <- holm_family(t)
  expect_equal(h$p_holm[1:2], p.adjust(c(.01,.02), "holm")); expect_true(is.na(h$p_holm[3]))
  expect_identical(verdict_h7(NA, NA, NA, NA), "not consistent with")
  expect_identical(not_estimable("dropped: more than 20% of state-months masked"),
                   "not estimable (dropped: more than 20% of state-months masked)")
})

test_that("holm over 13 tests equals p.adjust", {
  p <- c(0.001, 0.02, 0.3, 0.04, 0.01, 0.0004, 0.5, 0.03, 0.2, 0.9, 0.012, 0.07, 0.002)
  t <- data.table::data.table(test_id = 13:1, hypothesis = c(rep("H7", 4), "H8", rep("H9", 8)), outcome = letters[1:13],
                  est = rnorm(13), p = p, direction = c(rep("lt", 4), "gt", rep(c("lt", "gt"), 4)))
  h <- holm_family(t)
  expect_equal(h$p_holm, p.adjust(p, "holm"))
  expect_identical(h$test_id, 13:1)                     # row order and the other columns are kept
  expect_identical(h$direction, t$direction)
  expect_error(holm_family(t[, !"direction"]), "direction")
})

test_that("H7 needs both episode IRRs below 1", {
  expect_identical(verdict_h7(0.95, 0.01, 0.97, 1.01), NO)
  expect_identical(verdict_h7(0.95, 0.01, 0.97, 0.99), YES)
  expect_identical(verdict_h7(0.95, 0.06, 0.97, 0.99), NO)      # Holm p not below 0.05
  expect_identical(verdict_h7(1.02, 0.001, 0.97, 0.99), NO)     # wrong direction
  expect_identical(verdict_h7(0.95, 0.01, NA, NA), NO)          # episode model not estimable: (ii) fails
  expect_identical(verdict_h7(c(0.95, 0.95), c(0.01, 0.01), c(0.97, 0.97), c(0.99, 1.2)), c(YES, NO))
})

test_that("H8 reduction is not consistent", {
  expect_identical(verdict_h8(0.9, 0.001, 0.9, 0.9), NO)
  expect_identical(verdict_h8(1.1, 0.001, 1.05, 1.02), YES)
  expect_identical(verdict_h8(1.1, 0.001, 1.05, 0.98), NO)      # one episode below 1
  expect_identical(verdict_h8(1.1, 0.2, 1.05, 1.02), NO)
  expect_identical(verdict_h8(1.1, 0.001, NA, 1.02), NO)
})

test_that("H9 dry sign: positive coefficient = lower services", {
  expect_identical(verdict_h9(1.00, 0.5, 0.02, 0.01), YES)      # spi3_dry beta > 0 (values <= 0): lower with deficit
  expect_identical(verdict_h9(1.00, 0.5, -0.02, 0.01), NO)     # beta < 0: higher with deficit
  expect_identical(verdict_h9(0.98, 0.01, -0.02, 0.5), YES)    # heatwave IRR < 1
  expect_identical(verdict_h9(1.02, 0.01, -0.02, 0.01), NO)
  expect_identical(verdict_h9(0.98, 0.06, 0.02, 0.06), NO)
  expect_identical(verdict_h9(NA, NA, 0.02, 0.01), YES)        # one term not estimable, the other suffices
  expect_identical(verdict_h9(NA, NA, NA, NA), NO)
})

test_that("overall verdict text names outcomes", {
  v <- c(anc_reg = YES, penta3 = NO, inst_del = YES, opd = NO)
  o <- overall_verdict(v)
  expect_identical(o$verdict, YES)
  expect_identical(o$text, "consistent with H7 for ANC registration and institutional deliveries")
  # canonical order whatever the input order; ", " then " and " before the last label
  o3 <- overall_verdict(c(opd = YES, anc_reg = YES, penta3 = YES, inst_del = NO), hypothesis = "H9")
  expect_identical(o3$text,
                   "consistent with H9 for ANC registration, third dose of a DPT-containing vaccine and outpatient attendance")
  expect_identical(overall_verdict(c(anc_reg = NO, penta3 = YES))$text,
                   "consistent with H7 for third dose of a DPT-containing vaccine")
  none <- overall_verdict(c(anc_reg = NO, penta3 = NO, inst_del = NO, opd = NO), hypothesis = "H9")
  expect_identical(none, list(verdict = NO, text = "not consistent with H9"))
  expect_error(overall_verdict(c(anc_reg = "maybe")), "verdict")
})

test_that("reading rule S covers three cases", {
  expect_identical(reading_rule_s(YES, 0.95, 0.91, 0.99, 0.96), "agrees in direction")
  expect_identical(reading_rule_s(YES, 0.97, 0.93, 1.01, 0.96), "null or opposite")
  expect_identical(reading_rule_s(YES, 1.06, 1.02, 1.10, 0.96), "null or opposite")
  expect_identical(reading_rule_s(NO, 0.95, 0.91, 0.99, 0.96), "not applicable (H7 not consistent with)")
  # the contract's further cases (F52): Model S not estimable under an H7 consistent outcome; outcomes outside H7
  expect_identical(reading_rule_s(YES, NA, NA, NA, 0.96, s_reason = "fit_nb: no structure converged for anc_reg"),
                   "not estimable (fit_nb: no structure converged for anc_reg)")
  expect_identical(reading_rule_s(NA_character_, 0.95, 0.91, 0.99, 1.05), "not applicable (outcome outside H7)")
})

test_that("block_resample keeps units, months and contiguous blocks", {
  d <- sim_month_panel(n_units = 4, n_months = 95, seed = 3)
  set.seed(99); before <- .Random.seed
  r <- block_resample(d, block = 12L, seed = 7)
  expect_identical(.Random.seed, before)                   # the caller's RNG stream is restored
  expect_identical(nrow(r), nrow(d))
  expect_setequal(as.character(unique(r$unit_id)), as.character(unique(d$unit_id)))
  expect_true(all(table(as.character(r$unit_id)) == 95L))
  lv <- levels(r$ym_f)
  expect_length(lv, 95L); expect_false(anyDuplicated(lv) > 0)
  expect_true(all(lv %in% as.character(r$ym_f)))
  k <- as.integer(sub("^.*_", "", lv)); ym_lab <- as.integer(sub("_.*$", "", lv))
  expect_identical(sort(unique(k)), 1:8)                   # ceiling(95 / 12) blocks, the last truncated to 11
  expect_identical(as.vector(table(k)), c(rep(12L, 7), 11L))
  for (kk in unique(k)) expect_true(all(diff(ym_lab[k == kk]) == 1L))   # each block is consecutive months
  expect_identical(as.integer(r$ym), as.integer(sub("_.*$", "", as.character(r$ym_f))))
  # covariates keep their original values
  m <- unique(d[, .(ym, en_t0 = en_t, t_c0 = t_c)])
  chk <- m[r, on = "ym"]
  expect_equal(chk$en_t, chk$en_t0); expect_equal(chk$t_c, chk$t_c0)
  expect_identical(block_resample(d, 12L, seed = 7), r)
  expect_false(identical(block_resample(d, 12L, seed = 8)$ym, r$ym))
})

test_that("bootstrap summary: percentile CI and two-sided bootstrap p", {
  s <- .boot_summary(c(0.1, 0.2, 0.3, 0.4, 0.5))
  expect_identical(s$p, 0)
  expect_equal(c(s$lo, s$hi), stats::quantile(c(0.1, 0.2, 0.3, 0.4, 0.5), c(0.025, 0.975), names = FALSE))
  expect_equal(.boot_summary(c(-0.2, -0.1, 0.1, 0.2, 0.3))$p, 2 * min(2 / 5, 3 / 5))
  expect_identical(.boot_summary(c(-1, 1))$p, 1)
})

test_that("fit_model_t falls back to the block bootstrap when the time chain does not converge", {
  d <- sim_with_episodes(n_units = 3, n_months = 95, seed = 2)
  never <- function(formula, data, family = glmmTMB::nbinom2()) stop("no convergence")
  calls <- list()
  boot_spy <- function(spec, d, term, B, block, seed, cores, fit_fun, progress = NULL) {
    expect_true(is.function(progress))                       # the bootstrap reports progress (primary.log)
    calls[[length(calls) + 1L]] <<- list(fixed = spec$fixed, term = term, B = B, block = block, seed = seed)
    k <- length(term)
    list(term = term, est = setNames(rep(-0.1, k), term), se = setNames(rep(0.05, k), term),
         irr = setNames(rep(exp(-0.1), k), term), lo = setNames(rep(0.8, k), term), hi = setNames(rep(0.99, k), term),
         p = setNames(rep(0, k), term), B = B, B_ok = 990L, re_used = "diag", n = 285L, n_units = 3L)
  }
  r <- fit_model_t(d, "y", B = 1000L, fit_fun = never, boot_fun = boot_spy, log_fun = function(...) NULL)
  expect_identical(r$time_re, "block_bootstrap")
  expect_identical(r$re_used, "diag")
  expect_identical(r$n, 285L)
  expect_length(calls, 2L)
  expect_identical(calls[[1]]$term, c("en_t", "ln_t"))
  expect_identical(calls[[2]]$term, c("en_ep1415", "en_ep1819", "en_other", "ln_t"))
  expect_identical(calls[[2]]$fixed[1:4], c("en_ep1415", "en_ep1819", "en_other", "ln_t"))
  expect_identical(c(calls[[1]]$B, calls[[1]]$block, calls[[1]]$seed), c(1000L, 12L, SEED_E))
  expect_setequal(r$rows$term, c("en_t", "ln_t", "en_ep1415", "en_ep1819", "en_other", "ln_t"))
  en <- r$rows[model == "T" & term == "en_t"]
  expect_identical(en$p_kind, "bootstrap"); expect_identical(en$p, 0); expect_identical(en$B_ok, 990L)
  expect_identical(en$status, "ok"); expect_identical(en$time_re, "block_bootstrap")
  expect_identical(unique(r$rows[model == "T_ep"]$time_re), "block_bootstrap")
})

test_that("fit_model_t: an error that is not an estimation failure stops the run (F56)", {
  d <- sim_with_episodes(n_units = 3, n_months = 95, seed = 2)
  d[, demonet := NULL]
  expect_error(fit_model_t(d, "y", boot_fun = function(...) stop("the bootstrap must not run")), "missing column")
  expect_error(fit_model_l(d, "y"), "missing column")
  # a programming error inside the fitter call path is not swallowed either
  d2 <- sim_with_episodes(n_units = 3, n_months = 95, seed = 2)
  expect_error(fit_model_s(d2, "y"), "S_z")
  expect_error(model_t_resolve(list(status = "chain_failed", ind = "y", part = "T", spec = t_spec("y"), terms = T_TERMS),
                               d2, boot_fun = function(...) stop("object 'oops' not found")), "oops")
})

test_that("estimation failures are recognised by message (F56)", {
  for (m in c("fit_nb: no structure converged for y (tried us, diag, int)",
              "block_bootstrap_irr: every bootstrap refit failed: boom",
              "block_bootstrap_irr: term(s) not estimated on the original rows: en_t",
              "block bootstrap: more than 10% of refits failed",
              "term_row: term(s) not in model: en_t",
              "mediate: a-path fit did not converge (or non-positive-definite Hessian)",
              "mediate: b-path coefficient 'm1' is unidentified (NA)",
              "mediate: a-path fit failed: Error in optimHess(...)"))
    expect_true(is_estimation_failure(m), info = m)
  for (m in c("complete_rows: missing column(s): demonet", "fit_nb: no complete rows remain for y (0 rows dropped)",
              "object 'S_z' not found", "mediate_m: the models were not fitted on the same rows: a 3, b 2"))
    expect_false(is_estimation_failure(m), info = m)
})

test_that("a genuine non-convergence is not estimable and leaves the Holm family at 12 (F56)", {
  d <- sim_with_episodes(n_units = 3, n_months = 95, seed = 2)
  d[, `:=`(spi3_dry_l0 = pmin(rnorm(.N), 0), spi3_wet_l0 = pmax(rnorm(.N), 0), heatwave_days_l0 = rpois(.N, 1))]
  never <- function(formula, data, family = glmmTMB::nbinom2()) stop("no convergence")
  l <- fit_model_l(d, "y", fit_fun = never)
  expect_true(all(l$rows$status == "error"))
  expect_match(l$error, "^fit_nb: no structure converged for y")
  # model T chain exhausted and the bootstrap failing its 10% rule: not estimable with the bootstrap reason
  logged <- character()
  rt <- model_t_resolve(list(status = "chain_failed", ind = "y", part = "T", spec = t_spec("y"), terms = T_TERMS), d,
                        boot_fun = function(...) stop(errorCondition(
                          "block bootstrap: more than 10% of refits failed (most common error, 140 of 1000 refits: unit random effect us did not converge)",
                          class = "e_boot_too_many_failed", B_ok = 850L, B = 1000L,
                          error_counts = c("unit random effect us did not converge" = 140L, "term(s) unidentified (NA): en_t" = 10L))),
                        log_fun = function(...) logged <<- c(logged, paste0(...)))
  expect_identical(unique(rt$error),
                   "block bootstrap: more than 10% of refits failed (most common error, 140 of 1000 refits: unit random effect us did not converge)")
  expect_true(any(grepl("140 x unit random effect us did not converge", logged, fixed = TRUE)))
  expect_true(any(grepl("10 x term(s) unidentified (NA): en_t", logged, fixed = TRUE)))
  expect_identical(unique(rt$B_ok), 850L)
  tab <- fake_primary_table(drop_penta3 = FALSE)
  hw <- l$rows[term == "heatwave_days_l0"]
  tab[outcome == "anc_reg" & model == "L" & term == "heatwave_days_l0",
      `:=`(est = NA_real_, se = NA_real_, irr = NA_real_, lo = NA_real_, hi = NA_real_, p = NA_real_, status = "error",
           error = hw$error)]
  holm <- primary_holm(tab)
  expect_identical(sum(!is.na(holm$p_holm)), 12L)
  e <- primary_entries(tab, holm, units = list(s = list(n = 32L, excluded = c("AN", "LD")), l = list(n = 33L, excluded = "AN")))
  expect_identical(e[["E.h9.anc_reg.hw.p_holm"]]$display, paste0("not estimable (", hw$error, ")"))
  expect_identical(e[["E.l.anc_reg.hw.irr"]]$display, paste0("not estimable (", hw$error, ")"))
})

test_that("run_primary stops on a data error instead of writing not-estimable keys (F56)", {
  pw <- tempfile(fileext = ".csv"); writeLines("outcome", pw)
  gate <- tempfile(fileext = ".csv")
  data.table::fwrite(data.table::data.table(indicator = INDS, scope = "primary", dropped = "False"), gate)
  d <- sim_with_episodes(n_units = 3, n_months = 95, seed = 2)          # no HMIS outcome columns
  expect_error(run_primary(cores = 1L, power_csv = pw, gate_csv = gate, d = d, write = FALSE,
                           check_design = function() "design ok"), "missing column")
})

test_that("every Paper E fit gets the F61 optimiser limits (Models T, S, L, the block bootstrap)", {
  d <- sim_with_episodes(n_units = 4, n_months = 36, seed = 2)
  d[, `:=`(S_z = c(-1, 0.5, 1, 0.2)[as.integer(unit_id)])]
  d[, `:=`(en_S = en_t * S_z, ln_S = ln_t * S_z, spi3_dry_l0 = pmin(rnorm(.N), 0), spi3_wet_l0 = pmax(rnorm(.N), 0),
           heatwave_days_l0 = rpois(.N, 1))]
  seen <- list()
  real <- glmmTMB::glmmTMB
  testthat::local_mocked_bindings(glmmTMB = function(formula, data, family, control = glmmTMB::glmmTMBControl(), ...) {
    seen[[length(seen) + 1L]] <<- control$optCtrl
    real(formula, data = data, family = family, control = control, ...)
  }, .package = "glmmTMB")
  ok_ctrl <- function(cs) length(cs) > 0 && all(vapply(cs, function(o) identical(o$iter.max, 1e4) && identical(o$eval.max, 1e4), NA))
  model_t_part(d, "y", "T"); expect_true(ok_ctrl(seen), info = "Model T"); seen <- list()
  fit_model_s(d, "y"); expect_true(ok_ctrl(seen), info = "Model S"); seen <- list()
  fit_model_l(d, "y"); expect_true(ok_ctrl(seen), info = "Model L"); seen <- list()
  tryCatch(block_bootstrap_irr(t_spec("y"), d, "en_t", B = 2L, seed = 1L), error = function(e) NULL)
  expect_true(ok_ctrl(seen), info = "block bootstrap"); seen <- list()
  # the common default fitter handed to a Paper E helper is replaced by the controlled one (Tasks 9/10 inherit it)
  fit_time_chain(t_spec("y"), d, chain = "iid", fit_fun = glmmTMB_fit); expect_true(ok_ctrl(seen), info = "fit_time_chain")
  seen <- list()
  nb_fitter_with(character(), glmmTMB_fit)(spec_formula(t_spec("y"), "int"), d); expect_true(ok_ctrl(seen))
  expect_identical(e_fitter(glmmTMB_fit), e_glmmTMB_fit)
  spy <- function(formula, data, family = glmmTMB::nbinom2()) "spy"
  expect_identical(e_fitter(spy), spy)                        # an injected test fitter is used as it is
})

test_that("primary tasks on PSOCK workers see the panel as a data.table", {
  d <- sim_with_episodes(n_units = 3, n_months = 24, seed = 2)
  d[, S_z := 1]                                                # Model S runs, then lacks the outcome column
  cl <- .e_cluster(1L)
  on.exit(parallel::stopCluster(cl), add = TRUE)
  parallel::clusterCall(cl, .e_primary_init, MODELS_ROOT)
  parallel::clusterCall(cl, .e_set_global, ".E_PRIMARY_DATA", d)
  err <- tryCatch(parallel::clusterApplyLB(cl, list(list(ind = "anc_reg", part = "S")), .e_primary_task),
                  error = function(e) conditionMessage(e))
  expect_match(err, "missing column(s): anc_reg", fixed = TRUE)    # the data error, not a data.frame indexing error
})

test_that("bootstrap progress is logged every 50 refits", {
  seen <- character()
  pr <- boot_progress_logger("anc_reg T", every = 50L, log_fun = function(...) seen <<- c(seen, paste0(...)))
  for (k in c(seq(44L, 1000L, by = 44L), 1000L)) pr(k, 1000L)
  expect_length(seen, 20L)                                   # each multiple of 50 crossed once (the last is 1000)
  expect_match(seen[1], "anc_reg T: block bootstrap 88 of 1000 refits", fixed = TRUE)
  expect_match(seen[length(seen)], "1000 of 1000", fixed = TRUE)
})

test_that("Model T block bootstrap fixes the unit random effect and applies the 10% rule (F57)", {
  d <- sim_with_episodes(n_units = 4, n_months = 36, seed = 6)
  spec <- t_spec("y")
  resample_calls <- list()
  fail_first <- 0L
  m0 <- NULL
  spy <- function(formula, data, family = glmmTMB::nbinom2()) {
    if (any(grepl("_", levels(data$ym_f), fixed = TRUE))) {           # a month-block resample
      resample_calls[[length(resample_calls) + 1L]] <<- deparse1(formula)
      if (length(resample_calls) <= fail_first) stop("simulated non-convergence")
      return(m0)                                               # a converged fit, without refitting (fast)
    }
    m <- glmmTMB_fit(formula, data, family = family)
    m0 <<- m
    m
  }
  fail_first <- 2L                                             # 2 of 20 = 10%: not more than 10%
  bb <- block_bootstrap_irr(spec, d, "en_t", B = 20L, seed = 3L, fit_fun = spy)
  expect_identical(bb$B_ok, 18L); expect_identical(bb$B_failed, 2L)
  expect_length(resample_calls, 20L)                           # one fit per resample: no fallback chain
  want <- deparse1(spec_formula(spec, bb$re_used))
  expect_true(all(unlist(resample_calls) == want))
  resample_calls <- list(); fail_first <- 3L                   # 3 of 20 > 10%
  err <- tryCatch(block_bootstrap_irr(spec, d, "en_t", B = 20L, seed = 3L, fit_fun = spy), error = function(e) e)
  expect_s3_class(err, "e_boot_too_many_failed")
  expect_identical(conditionMessage(err),
                   "block bootstrap: more than 10% of refits failed (most common error, 3 of 20 refits: unit random effect us: simulated non-convergence)" |>
                     sub(pattern = "effect us:", replacement = paste0("effect ", bb$re_used, ":"), fixed = TRUE))
  expect_true(is_estimation_failure(err))
  expect_identical(err$B_ok, 17L)
  expect_identical(unname(err$error_counts), 3L)
  expect_identical(bb$error_counts, c("unit random effect us: simulated non-convergence" = 2L) |>
                     stats::setNames(paste0("unit random effect ", bb$re_used, ": simulated non-convergence")))
})

test_that("Model S and Model L specifications, rows and terms", {
  d <- sim_with_episodes(n_units = 4, n_months = 95, seed = 2)
  d[, S_z := c(-1, 0.5, 1, NA)[as.integer(unit_id)]]
  d[, `:=`(en_S = en_t * S_z, ln_S = ln_t * S_z, spi3_dry_l0 = pmin(rnorm(.N), 0), spi3_wet_l0 = pmax(rnorm(.N), 0),
           heatwave_days_l0 = rpois(.N, 1))]
  d[unit_id == "U01", spi3_dry_l0 := NA]
  seen <- list()
  spy <- function(formula, data, family = glmmTMB::nbinom2()) {
    seen[[length(seen) + 1L]] <<- list(f = deparse1(formula), n = nrow(data), units = nlevels(droplevels(data$unit_id)))
    stop("spy")
  }
  s <- fit_model_s(d, "y", fit_fun = spy)
  expect_match(seen[[1]]$f, "y ~ en_S + ln_S + ym_f + offset(log_pop_days) + (1 + t_c | unit_id)", fixed = TRUE)
  expect_false(grepl("moy|hmis_format2017|ym_f\\)", seen[[1]]$f))     # no programme terms, no time random effect
  expect_identical(seen[[1]]$n, 3L * 95L); expect_identical(seen[[1]]$units, 3L)
  expect_identical(s$rows$term, c("en_S", "ln_S")); expect_true(all(s$rows$status == "error"))
  seen <- list()
  l <- fit_model_l(d, "y", fit_fun = spy)
  expect_match(seen[[1]]$f,
               "y ~ spi3_dry_l0 + spi3_wet_l0 + heatwave_days_l0 + ym_f + offset(log_pop_days) + (1 + t_c | unit_id)",
               fixed = TRUE)
  expect_identical(seen[[1]]$units, 3L)                   # complete_rows drops the unit without rain
  expect_identical(l$rows$term, c("spi3_dry_l0", "spi3_wet_l0", "heatwave_days_l0"))
})

test_that("primary entries: contract key set, verdicts, Holm and display rules", {
  tab <- fake_primary_table()
  holm <- primary_holm(tab)
  expect_identical(nrow(holm), 13L)
  expect_identical(sum(!is.na(holm$p_holm)), 10L)          # penta3's three tests leave the family
  opd <- holm[outcome == "opd" & hypothesis == "H7"]
  expect_true(opd$at_bound); expect_equal(opd$p, 2 / 1000)
  e <- primary_entries(tab, holm, units = list(s = list(n = 32L, excluded = c("AN", "LD")),
                                               l = list(n = 33L, excluded = "AN")))
  want <- primary_contract_keys(file.path(REPO_ROOT, "papers", "E", "results_keys.md"))
  expect_length(want, 156L)
  expect_setequal(names(e), want)
  for (k in names(e)) expect_true(is.character(e[[k]]$display) && nzchar(e[[k]]$display), info = k)
  dsp <- function(k) e[[k]]$display
  # verdicts
  expect_identical(dsp("E.h7.anc_reg.verdict"), YES)
  expect_identical(dsp("E.h7.inst_del.verdict"), NO)        # episode model failed: condition (ii) fails
  expect_identical(dsp("E.h7.penta3.verdict"), NO)
  expect_identical(dsp("E.h8.verdict"), NO)                 # a reduction does not satisfy H8
  expect_identical(dsp("E.h7.verdict_text"), "consistent with H7 for ANC registration and outpatient attendance")
  expect_identical(dsp("E.h9.anc_reg.verdict"), YES)        # spi3_dry beta 0.04 > 0, p_holm < 0.05
  expect_identical(dsp("E.h9.verdict"), YES)
  expect_identical(dsp("E.h9.verdict_text"),
                   "consistent with H9 for ANC registration, institutional deliveries and outpatient attendance")
  # deficit display: exp(-beta), bounds swapped
  expect_identical(dsp("E.l.anc_reg.dry.irr"), fmt_ci(exp(-0.04), exp(-0.04 - 1.959964 * 0.01), exp(-0.04 + 1.959964 * 0.01)))
  expect_equal(e[["E.l.anc_reg.dry.irr"]]$value, exp(-0.04))
  expect_identical(dsp("E.l.anc_reg.wet.irr"), fmt_ci(exp(0.01), exp(0.01 - 1.959964 * 0.02), exp(0.01 + 1.959964 * 0.02)))
  expect_identical(dsp("E.t.anc_reg.irr_ln"), fmt_ci(exp(-0.02), exp(-0.02 - 1.959964 * 0.02), exp(-0.02 + 1.959964 * 0.02)))
  expect_identical(dsp("E.s.anc_reg.irr_ln"), fmt_ci(exp(0.05), exp(0.05 - 1.959964 * 0.02), exp(0.05 + 1.959964 * 0.02)))
  expect_identical(dsp("E.l.anc_reg.hw.p"), "0.600")
  # bootstrap p of 0 and its Holm display
  expect_identical(dsp("E.t.opd.p_en"), "<0.002")
  expect_identical(dsp("E.t.opd.p_en_holm"), paste0("<", fmt_p(opd$p_holm)))
  expect_identical(dsp("E.t.opd.time_re"), "moving-block bootstrap over months (block 12, B = 1,000)")
  expect_identical(dsp("E.t.anc_reg.time_re"), "AR(1) year-month random effect")
  expect_identical(e[["E.t.anc_reg.time_re"]]$value, "ar1")
  expect_identical(dsp("E.t.anc_reg.re_used"), "correlated random intercept and trend slope")
  expect_identical(dsp("E.t.anc_reg.n"), "3,100")
  # not estimable and not applicable
  drop <- "not estimable (dropped: more than 20% of state-months masked)"
  for (k in c("E.t.penta3.irr_en", "E.t.penta3.p_en", "E.t.penta3.p_en_holm", "E.t.penta3.irr_en.ep1415",
              "E.s.penta3.irr", "E.l.penta3.hw.irr", "E.h9.penta3.hw.p_holm", "E.h9.penta3.dry.p_holm")) {
    expect_identical(dsp(k), drop, info = k)
    expect_true(is.na(e[[k]]$value), info = k)
  }
  expect_identical(dsp("E.t.inst_del.irr_en.ep1819"), "not estimable (fit_nb: boom)")
  expect_identical(dsp("E.t.mcv1.p_en_holm"), "not applicable (secondary outcome; outside the Holm family)")
  expect_true(is.na(e[[ "E.t.mcv1.p_en_holm"]]$value))
  # Model S readings
  expect_identical(dsp("E.s.anc_reg.reading"), "agrees in direction")
  expect_identical(dsp("E.s.inst_del.reading"), "not applicable (H7 not consistent with)")
  expect_identical(dsp("E.s.diarr_u5.reading"), "not applicable (outcome outside H7)")
  expect_identical(dsp("E.s.n_units"), "32")
  expect_match(e[["E.s.n_units"]]$description, "AN, LD", fixed = TRUE)
  expect_identical(dsp("E.l.n_units"), "33")
  expect_identical(e[["E.t.anc_reg.irr_en"]]$script, "models/E/02_primary.R")
})

test_that("cores rule (speed ruling): 3 while the power run is alive, else detectCores() - 1", {
  pf <- tempfile(fileext = ".txt")
  n <- parallel::detectCores()
  writeLines(c("RUNNING 2026-10-25 06:00:00", sprintf("pid %d", Sys.getpid())), pf)     # this R process: alive
  expect_true(power_run_alive(pf))
  expect_identical(e_cores(pf), as.integer(min(3L, max(1L, n - 1L))))
  writeLines(c("DONE 2026-10-25 09:00:00", sprintf("pid %d", Sys.getpid())), pf)
  expect_false(power_run_alive(pf))
  expect_identical(e_cores(pf), as.integer(max(1L, n - 1L)))
  expect_false(power_run_alive(file.path(tempdir(), "no-progress.txt")))
})

test_that("run_primary needs the power design committed, not power.csv (speed ruling)", {
  # the design check: the contract and 01_power.R tracked and without uncommitted changes
  clean <- function(args) if (args[1] == "ls-files") args[length(args)] else character()
  expect_match(assert_power_design_fixed(git = clean), "results_keys.md")
  untracked <- function(args) if (args[1] == "ls-files") character() else character()
  expect_error(assert_power_design_fixed(git = untracked), "not committed")
  dirty <- function(args) if (args[1] == "ls-files") args[length(args)] else paste(" M", args[length(args)])
  expect_error(assert_power_design_fixed(git = dirty), "uncommitted changes")
  expect_error(run_primary(power_csv = file.path(tempdir(), "no-power.csv"), write = FALSE,
                           check_design = function() stop("the power design is not committed")), "power design")
})

test_that("block_bootstrap_irr returns a finite CI on a simulated panel", {
  skip_if_slow_disabled()
  d <- sim_with_episodes(n_units = 8, n_months = 95, beta_en = -0.1, seed = 5)
  bb <- block_bootstrap_irr(t_spec("y"), d, c("en_t", "ln_t"), B = 20L, block = 12L, seed = 11L)
  expect_identical(bb$B, 20L)
  expect_gte(bb$B_ok, 18L)
  expect_true(all(is.finite(c(bb$irr, bb$lo, bb$hi, bb$p))))
  expect_true(all(bb$lo < bb$hi))
  expect_true(all(bb$p >= 0 & bb$p <= 1))
  expect_identical(names(bb$irr), c("en_t", "ln_t"))
  expect_true(bb$re_used %in% c("us", "diag", "int"))
  expect_identical(bb$n, nrow(d))
  # the same seeds give the same resamples
  bb2 <- block_bootstrap_irr(t_spec("y"), d, "en_t", B = 3L, block = 12L, seed = 11L)
  expect_equal(unname(bb2$betas[, "en_t"]), unname(bb$betas[1:3, "en_t"]))
})
