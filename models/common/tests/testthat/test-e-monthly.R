# Paper E Task 7: monthly model helpers (models/E/R/common_e.R, models/E/R/monthly.R). models/common/R is frozen;
# these helpers call nb_spec / spec_formula / fit_nb / glmmTMB_fit unchanged.

local({
  root <- if (exists("MODELS_ROOT")) MODELS_ROOT else normalizePath(file.path(getwd(), "..", "..", ".."), winslash = "/")
  for (f in c("common_e.R", "monthly.R", "power.R")) source(file.path(root, "E", "R", f), local = globalenv())
})

test_that("t_spec builds the Model T formula", {
  f <- deparse1(spec_formula(t_spec("anc_reg")))
  expect_match(f, "anc_reg ~ en_t + ln_t + moy + t_c + hmis_format2017 + demonet + offset(log_pop_days) + (1 + t_c | unit_id)",
               fixed = TRUE)
  s <- t_spec("opd")
  expect_identical(s$slopes, "t_c")
  expect_identical(s$trend_df, 0L)
  expect_identical(s$re, "us")
  expect_identical(s$offset, "log_pop_days")
  expect_false(grepl("splines", f, fixed = TRUE))
  # exposure and extra replace / extend the fixed terms in order
  e <- t_spec("anc_reg", exposure = c("en_ep1415", "en_ep1819", "en_other", "ln_t"), extra = "diwali")
  expect_identical(e$fixed, c("en_ep1415", "en_ep1819", "en_other", "ln_t", "moy", "t_c", "hmis_format2017", "demonet",
                              "diwali"))
  expect_identical(t_spec("anc_reg", exposure = character())$fixed, c("moy", "t_c", "hmis_format2017", "demonet"))
})

test_that("mi_round only for immunisation outcomes", {
  for (o in c("penta3", "mcv1", "fic")) expect_identical(programme_terms(o), c("hmis_format2017", "demonet", "mi_round"))
  for (o in c("opd", "anc_reg", "inst_del", "diarr_u5")) expect_identical(programme_terms(o), c("hmis_format2017", "demonet"))
  expect_match(deparse1(spec_formula(t_spec("penta3"))), "demonet + mi_round + offset(log_pop_days)", fixed = TRUE)
  # era_e2 is never a model term (identical to hmis_format2017; F45)
  for (o in INDS) expect_false("era_e2" %in% t_spec(o)$fixed)
})

test_that("nb_fitter_with adds the time RE to NB fits only", {
  seen <- list()
  spy <- function(formula, data, family) {
    seen[[length(seen) + 1L]] <<- list(f = deparse1(formula), family = family$family)
    "fitted"
  }
  fitter <- nb_fitter_with(c(TIME_RE[["iid"]], "splines::ns(t_c, df = 2)"), fit_fun = spy)
  expect_identical(fitter(y ~ x + offset(lp) + (1 + t_c | unit_id), data.frame()), "fitted")
  fitter(m ~ x, data.frame(), family = stats::gaussian())
  expect_identical(seen[[1]]$family, "nbinom2")
  expect_identical(seen[[1]]$f, "y ~ x + offset(lp) + (1 + t_c | unit_id) + (1 | ym_f) + splines::ns(t_c, df = 2)")
  expect_identical(seen[[2]]$family, "gaussian")
  expect_identical(seen[[2]]$f, "m ~ x")
  # no extra terms: the formula passes through unchanged
  nb_fitter_with(character(), fit_fun = spy)(y ~ x, data.frame())
  expect_identical(seen[[3]]$f, "y ~ x")
  expect_identical(unname(TIME_RE), c("ar1(ym_f + 0 | national)", "(1 | ym_f)"))
  expect_identical(names(TIME_RE), c("ar1", "iid"))
})

test_that("nb_fitter_with's fitter references no Paper E helper (safe to ship to PSOCK workers)", {
  skip_if_not_installed("codetools")
  fitter <- nb_fitter_with(TIME_RE[["ar1"]])
  e_helpers <- c("TIME_RE", "nb_fitter_with", "t_spec", "programme_terms", "fit_time_chain", "term_row",
                 "read_hmis_model", "elog", "simulate_power", "mde")
  expect_length(intersect(codetools::findGlobals(fitter), e_helpers), 0L)
  expect_length(intersect(codetools::findGlobals(nb_fitter_with), e_helpers), 0L)
})

test_that("the real NB fitter: an iid time RE fit recovers a known en_t coefficient and term_row matches irr_table", {
  d <- sim_month_panel(n_units = 12, n_months = 95, beta_en = -0.10, theta = 30, sd_ym = 0.03, seed = 11)
  d[, anc_reg := y]
  f <- fit_nb(t_spec("anc_reg"), d, fitter = nb_fitter_with(TIME_RE[["iid"]]))
  expect_match(deparse1(stats::formula(f$model)), "| unit_id) + (1 | ym_f)", fixed = TRUE)
  tr <- term_row(f, "en_t")
  expect_named(tr, c("term", "est", "se", "irr", "lo", "hi", "p"))
  expect_lt(abs(tr$est - (-0.10)), 0.05)
  it <- irr_table(f, "en_t")
  expect_equal(tr$irr, unname(it$irr))
  expect_equal(tr$lo, unname(it$lo))
  expect_equal(tr$hi, unname(it$hi))
  expect_equal(tr$p, unname(it$p))
  expect_equal(tr$irr, exp(tr$est))
  expect_identical(term_row(f, c("en_t", "ln_t"))$term, c("en_t", "ln_t"))
  expect_error(term_row(f, "en_S"), "not in model")
})

test_that("fit_time_chain falls back from ar1 to iid", {
  d <- sim_month_panel(n_units = 10, n_months = 60, seed = 2)
  d[, anc_reg := y]
  calls <- character()
  fake <- function(formula, data, family = glmmTMB::nbinom2()) {
    txt <- deparse1(formula)
    calls <<- c(calls, txt)
    if (grepl("ar1(", txt, fixed = TRUE)) stop("simulated ar1 non-convergence")
    glmmTMB::glmmTMB(formula, data = data, family = family)
  }
  f <- fit_time_chain(t_spec("anc_reg"), d, fit_fun = fake)
  expect_s3_class(f, "nbfit")
  expect_identical(f$time_re, "iid")
  expect_identical(f$time_attempts, c("ar1", "iid"))
  expect_match(f$time_errors, "^ar1: ")
  # the injected fitter was used at every step: 3 ar1 attempts (us -> diag -> int), then iid
  expect_true(all(grepl("ar1(ym_f + 0 | national)", calls[1:3], fixed = TRUE)))
  expect_true(grepl("(1 | ym_f)", calls[4], fixed = TRUE))
  expect_length(calls, 4L)
  # extra terms reach every step
  calls <- character()
  g <- fit_time_chain(t_spec("anc_reg"), d, chain = "iid", extra = "sin(2 * pi * t_c)", fit_fun = fake)
  expect_identical(g$time_re, "iid")
  expect_match(calls[1], "(1 | ym_f) + sin(2 * pi * t_c)", fixed = TRUE)
})

test_that("fit_time_chain errors naming block_bootstrap", {
  d <- sim_month_panel(n_units = 6, n_months = 30, seed = 3)
  d[, anc_reg := y]
  never <- function(formula, data, family = glmmTMB::nbinom2()) stop("no")
  expect_error(fit_time_chain(t_spec("anc_reg"), d, fit_fun = never), "block_bootstrap")
  expect_error(fit_time_chain(t_spec("anc_reg"), d, chain = "ar2", fit_fun = never), "unknown time random effect")
  # the final error carries every step's message (review fix round 1, item 1)
  msg <- tryCatch(fit_time_chain(t_spec("anc_reg"), d, fit_fun = never), error = conditionMessage)
  expect_match(msg, "block_bootstrap", fixed = TRUE)
  expect_match(msg, "ar1: fit_nb: no structure converged for anc_reg (tried us, diag, int)", fixed = TRUE)
  expect_match(msg, "iid: fit_nb: no structure converged for anc_reg (tried us, diag, int)", fixed = TRUE)
})

test_that("fit_time_chain rethrows errors that are not non-convergence, never sending them to block_bootstrap", {
  d <- sim_month_panel(n_units = 6, n_months = 30, seed = 3)
  d[, anc_reg := y]
  calls <- 0L
  spy <- function(formula, data, family = glmmTMB::nbinom2()) { calls <<- calls + 1L; stop("should not be reached") }
  # a missing fixed column (complete_rows in fit_nb)
  msg <- tryCatch(fit_time_chain(t_spec("anc_reg", extra = "pmsma_typo"), d, fit_fun = spy), error = conditionMessage)
  expect_match(msg, "pmsma_typo", fixed = TRUE)
  expect_false(grepl("block_bootstrap", msg, fixed = TRUE))
  # a missing column inside an `extra` expression
  msg <- tryCatch(fit_time_chain(t_spec("anc_reg"), d, extra = "splines::ns(t_x, df = 2)", fit_fun = spy),
                  error = conditionMessage)
  expect_match(msg, "t_x", fixed = TRUE)
  expect_false(grepl("block_bootstrap", msg, fixed = TRUE))
  # an `extra` expression that does not parse
  msg <- tryCatch(fit_time_chain(t_spec("anc_reg"), d, extra = "ns(t_c,, ", fit_fun = spy), error = conditionMessage)
  expect_match(msg, "ns(t_c,, ", fixed = TRUE)
  expect_false(grepl("block_bootstrap", msg, fixed = TRUE))
  # the time random effect's grouping columns must exist
  msg <- tryCatch(fit_time_chain(t_spec("anc_reg"), d[, !"national"], fit_fun = spy), error = conditionMessage)
  expect_match(msg, "national", fixed = TRUE)
  expect_false(grepl("block_bootstrap", msg, fixed = TRUE))
  expect_identical(calls, 0L)
})

test_that("programme_terms equals pipeline/hmis/model_table.programme_terms_for (primary set) minus covid_mar2020", {
  py <- Sys.which(c("python", "python3"))
  py <- py[nzchar(py)]
  skip_if(!length(py), "python not found")
  code <- paste0("import sys, json; sys.path.insert(0, r'", REPO_ROOT, "'); ",
                 "from pipeline.hmis import model_table as mt; ",
                 "print(json.dumps({o: mt.programme_terms_for(o, include_sensitivity=False) for o in sys.argv[1:]}))")
  out <- suppressWarnings(system2(py[[1]], c("-I", "-c", shQuote(code, type = "cmd"), INDS), stdout = TRUE, stderr = TRUE))
  skip_if(!is.null(attr(out, "status")), paste("python could not import pipeline.hmis:", paste(out, collapse = " ")))
  ref <- jsonlite::fromJSON(paste(out, collapse = ""), simplifyVector = TRUE)
  expect_setequal(names(ref), INDS)
  for (o in INDS) expect_identical(programme_terms(o), setdiff(ref[[o]], "covid_mar2020"), info = o)
})

test_that("fit_time_chain with the real fitter records the step it used", {
  skip_if_slow_disabled()
  d <- sim_month_panel(n_units = 12, n_months = 95, sd_ym = 0.08, seed = 4)
  d[, anc_reg := y]
  f <- fit_time_chain(t_spec("anc_reg"), d)
  expect_true(f$time_re %in% c("ar1", "iid"))
  expect_match(deparse1(stats::formula(f$model)), TIME_RE[[f$time_re]], fixed = TRUE)
})

test_that("read_hmis_model builds the factors and the windows", {
  csv <- tempfile(fileext = ".csv")
  on.exit(unlink(csv))
  yms <- 2012L * 12L + 3L + 0:107
  d <- data.table::CJ(unit_id = c("KL", "AN"), ym = rev(yms))
  d[, `:=`(month = ym %% 12L + 1L, year = ym %/% 12L)]
  d[, `:=`(moy = month, in_primary = as.integer(ym <= 2020L * 12L + 1L), era_e2 = as.integer(ym >= 2017L * 12L + 3L),
           anc_reg = ifelse(ym == yms[5], NA, 100))]
  data.table::fwrite(d, csv)
  p <- read_hmis_model("primary", path = csv)
  expect_identical(nrow(p), 2L * 95L)
  expect_identical(levels(p$ym_f), as.character(yms[1:95]))
  expect_identical(levels(p$unit_id), c("AN", "KL"))
  expect_identical(levels(p$moy), as.character(1:12))
  expect_identical(nlevels(p$national), 1L)
  expect_identical(nlevels(p$unit_era), 4L)
  expect_identical(as.character(p$unit_era[p$unit_id == "KL" & p$era_e2 == 1L][1]), "KL:1")
  expect_true(all(c("unit_id", "moy", "ym_f", "national", "unit_era") %in% names(Filter(is.factor, p))))
  expect_true(is.na(p[unit_id == "KL" & ym == yms[5]]$anc_reg))          # missing stays missing
  expect_false(is.unsorted(p[unit_id == "KL"]$ym))
  a <- read_hmis_model("fy2021", path = csv)
  expect_identical(nrow(a), 2L * 108L)
  expect_identical(levels(a$ym_f), as.character(yms))
})

test_that("Paper E constants", {
  expect_identical(SEED_E, 20261024L)
  expect_identical(INDS, c("diarr_u5", "anc_reg", "penta3", "mcv1", "fic", "inst_del", "opd"))
  expect_identical(PRIMARY5, c("diarr_u5", "anc_reg", "penta3", "inst_del", "opd"))
  expect_identical(H7_INDS, c("anc_reg", "penta3", "inst_del", "opd"))
  expect_identical(SMALL_UNITS, c("LD", "CH", "PY", "DNH_DD", "AN", "SK", "GA"))
  expect_identical(E_OUT, file.path(REPO_ROOT, "papers", "E", "output"))
})
