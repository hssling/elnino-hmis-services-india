# Paper E Task 8: local-climate-mediated share (models/E/R/mediation_e.R; contract §6, the mediation rule; ruling
# F48: the a-paths use the Model T covariates). models/common/R is frozen: mediate_m() reuses the common a-path
# helpers (.a_path_formula, .fit_a_path, .coef_or_stop, .prop_ci, .pct, bootstrap_units) unchanged.

local({
  root <- if (exists("MODELS_ROOT")) MODELS_ROOT else normalizePath(file.path(getwd(), "..", "..", ".."), winslash = "/")
  for (f in c("common_e.R", "monthly.R", "power.R", "verdicts.R", "mediation_e.R"))
    source(file.path(root, "E", "R", f), local = globalenv())
})

MED_T_COVARS <- c("ln_t", "moy", "t_c", "hmis_format2017", "demonet")

# Simulated panel with three mediators driven by en_t (a = 1, -0.5, 0) and an outcome that depends on them
# (b = 0.10, 0.10, 0.05): the true indirect effect is 1 * 0.10 + (-0.5) * 0.10 + 0 * 0.05 = 0.05.
sim_mediation_panel <- function(n_units = 12, n_months = 95, seed = 4) {
  d <- sim_month_panel(n_units = n_units, n_months = n_months, seed = seed)
  set.seed(seed + 100)
  u <- stats::rnorm(n_units, 0, 0.3)[as.integer(d$unit_id)]
  d[, `:=`(m1 = 1.0 * en_t + u + stats::rnorm(.N, 0, 0.5), m2 = -0.5 * en_t + stats::rnorm(.N, 0, 0.5),
           m3 = stats::rnorm(.N, 0, 0.5))]
  ua <- stats::rnorm(n_units, 0, 0.3)[as.integer(d$unit_id)]
  b_ym <- stats::rnorm(n_months, 0, 0.03)[as.integer(d$ym_f)]
  d[, y := stats::rnbinom(.N, size = 30, mu = exp(-9 + ua + log_pop_days + 0.02 * en_t + 0.10 * m1 + 0.10 * m2 +
                                                   0.05 * m3 + b_ym))]
  d[]
}

test_that("mediation is skipped when the total CI includes 1", {
  expect_false(med_eligible(0.95, 1.02))
  expect_true(med_eligible(0.90, 0.98))
  expect_true(med_eligible(1.01, 1.10))
  expect_false(med_eligible(NA, 0.98))
  k <- mediation_keys("anc_reg", reason = "not estimated (no total association)")
  expect_setequal(names(k), paste0("E.med.anc_reg.", c("prop", "prop_unit", "indirect", "flag", "B")))
  for (e in k) {
    expect_identical(e$display, "not estimated (no total association)")
    expect_true(is.na(e$value))
    expect_identical(e$script, "models/E/03_mediation.R")
  }
})

# A mediate_m() result with chosen numbers.
fake_med <- function(prop = 0.34, lo = 0.12, hi = 0.60, flag = "ok", prop_flag = "ok", indirect = -0.02,
                     B = 500L, B_ok = 497L) {
  list(a = c(spi3_dry_l0 = -0.2, spi3_wet_l0 = 0.1, heatwave_days_l0 = 0.5),
       b = c(spi3_dry_l0 = 0.05, spi3_wet_l0 = 0.01, heatwave_days_l0 = -0.02), c_total = indirect / prop,
       c_direct = indirect / prop - indirect, indirect = indirect,
       indirect_by = c(spi3_dry_l0 = -0.01, spi3_wet_l0 = 0.001, heatwave_days_l0 = -0.011), prop_mediated = prop,
       ci = list(indirect = c(-0.04, -0.005), prop = if (prop_flag == "ok" && flag == "ok") c(lo, hi) else c(NA, NA),
                 c_total = c(-0.1, -0.02)),
       B = B, B_ok = B_ok, B_failed = B - B_ok, flag = flag, prop_flag = prop_flag, n = 3100L, n_units = 33L,
       resample = "month_block", re_used = c(b = "us", total = "us"), seed = SEED_E, block = 12L)
}

test_that("mediation keys follow the contract displays", {
  k <- mediation_keys("opd", mb = fake_med(), unit = fake_med(prop = 0.30, lo = -0.08, hi = 0.65))
  expect_identical(k[["E.med.opd.prop"]]$display, "34% (95% CI 12–60%)")
  expect_equal(k[["E.med.opd.prop"]]$value, 34)
  expect_identical(k[["E.med.opd.prop_unit"]]$display, "30% (95% CI −8 to 65%)")
  expect_identical(k[["E.med.opd.indirect"]]$display, fmt_ci(exp(-0.02), exp(-0.04), exp(-0.005)))
  expect_identical(k[["E.med.opd.flag"]]$display, "ok")
  expect_identical(k[["E.med.opd.B"]]$display, "500")
  expect_match(k[["E.med.opd.B"]]$description, "497", fixed = TRUE)
  many <- mediation_keys("opd", mb = fake_med(flag = "too_many_failed_fits", prop_flag = "not_assessed", B_ok = 400L),
                         unit = fake_med())
  expect_identical(many[["E.med.opd.prop"]]$display, "34% (CI not estimated: >10% of bootstrap refits failed)")
  expect_identical(many[["E.med.opd.flag"]]$display, "too_many_failed_fits")
  opp <- mediation_keys("opd", mb = fake_med(prop_flag = "opposite_signs"), unit = fake_med())
  expect_identical(opp[["E.med.opd.prop"]]$display, "not estimable (opposite_signs)")
  expect_identical(opp[["E.med.opd.flag"]]$display, "opposite_signs")
  # a failed unit-bootstrap sensitivity does not hide the primary result
  ue <- mediation_keys("opd", mb = fake_med(), unit = "fit_nb: no structure converged for opd")
  expect_identical(ue[["E.med.opd.prop_unit"]]$display, "not estimable (fit_nb: no structure converged for opd)")
  expect_identical(ue[["E.med.opd.prop"]]$display, "34% (95% CI 12–60%)")
})

test_that("run_mediation fits nothing when no Model T CI excludes 1 and still writes all 35 keys", {
  source(file.path(MODELS_ROOT, "E", "03_mediation.R"), local = globalenv())
  tmp <- tempfile("med"); dir.create(tmp)
  pe <- data.table::data.table(outcome = INDS, model = "T", term = "en_t", irr = 0.98, lo = 0.95, hi = 1.01,
                               status = "ok", error = NA_character_)
  pe[outcome == "fic", `:=`(irr = NA, lo = NA, hi = NA, status = "dropped",
                            error = "dropped: more than 20% of state-months masked")]
  pe[outcome == "opd", `:=`(irr = NA, lo = NA, hi = NA, status = "error", error = "fit_nb: no structure converged for opd")]
  data.table::fwrite(pe, file.path(tmp, "primary_estimates.csv"))
  r <- run_mediation(cores = 1L, primary_csv = file.path(tmp, "primary_estimates.csv"),
                     out_csv = file.path(tmp, "mediation.csv"), rds = file.path(tmp, "mediation.rds"), log = file.path(tmp, "m.log"), progress_file = file.path(tmp, "prog.txt"),
                     d = data.table::data.table())                # an empty panel: any fit would fail
  expect_length(r$entries, 35L)
  expect_identical(r$entries[["E.med.anc_reg.prop"]]$display, "not estimated (no total association)")
  # F58: Model T not estimable -> not estimable (Model T: <reason>), never "no total association"
  expect_identical(r$entries[["E.med.opd.B"]]$display, "not estimable (Model T: fit_nb: no structure converged for opd)")
  expect_identical(r$entries[["E.med.opd.prop"]]$display, "not estimable (Model T: fit_nb: no structure converged for opd)")
  expect_identical(r$entries[["E.med.fic.indirect"]]$display, "not estimable (dropped: more than 20% of state-months masked)")
  out <- data.table::fread(file.path(tmp, "mediation.csv"))
  expect_identical(nrow(out), 7L)
  expect_true(file.exists(file.path(tmp, "mediation.rds")))
  expect_match(readLines(file.path(tmp, "prog.txt"))[1], "^DONE ")
  expect_true(any(grepl("run_mediation: start", readLines(file.path(tmp, "m.log")), fixed = TRUE)))
  # the entry point writes FAILED to the progress file on any error
  expect_false(mediation_entry(c(paste0("--primary=", file.path(tmp, "none.csv")),
                                 paste0("--progress=", file.path(tmp, "prog2.txt")), paste0("--log=", file.path(tmp, "m2.log")))))
  expect_match(readLines(file.path(tmp, "prog2.txt"))[1], "^FAILED ")
  expect_identical(med_covars("penta3"), c("ln_t", "moy", "t_c", "hmis_format2017", "demonet", "mi_round"))
})

test_that("run_mediation stops on a data error instead of writing not-estimable keys (F56)", {
  source(file.path(MODELS_ROOT, "E", "03_mediation.R"), local = globalenv())
  tmp <- tempfile("med"); dir.create(tmp)
  pe <- data.table::data.table(outcome = INDS, model = "T", term = "en_t", irr = 0.98, lo = 0.95, hi = 1.01,
                               status = "ok", error = NA_character_)
  pe[outcome == "anc_reg", `:=`(irr = 0.95, lo = 0.92, hi = 0.98)]           # eligible
  data.table::fwrite(pe, file.path(tmp, "primary_estimates.csv"))
  d <- sim_mediation_panel(n_units = 3, n_months = 24, seed = 1)               # no anc_reg column
  expect_error(run_mediation(cores = 1L, primary_csv = file.path(tmp, "primary_estimates.csv"),
                             out_csv = file.path(tmp, "mediation.csv"), rds = file.path(tmp, "mediation.rds"), log = file.path(tmp, "m.log"), progress_file = file.path(tmp, "prog.txt"), d = d),
               "missing column")
  expect_false(file.exists(file.path(tmp, "mediation.csv")))
})

test_that("the 24-hour projection reduces B to 200", {
  expect_identical(med_choose_B(secs_per_resample = 10, n_runs = 4, cores = 8, budget_hours = 24), 500L)
  # 120 s x 500 x 14 runs x 1.6 / 7 cores = 53 h > 24 h
  expect_identical(med_choose_B(secs_per_resample = 120, n_runs = 14, cores = 7, budget_hours = 24), 200L)
  expect_equal(med_projection_hours(120, 500L, 14, 7, slowdown = 1.6), 120 * 500 * 14 * 1.6 / 7 / 3600)
})

test_that("mediate_m fits one a-path per mediator, one b-path with all mediators and Model T as the total", {
  d <- sim_mediation_panel(n_units = 6, n_months = 36, seed = 8)
  d[1:3, m2 := NA]
  seen <- list()
  spy <- function(formula, data, family = glmmTMB::nbinom2()) {
    seen[[length(seen) + 1L]] <<- list(f = deparse1(formula), family = family$family, n = nrow(data))
    glmmTMB_fit(formula, data, family = family)
  }
  r <- mediate_m(d, "y", mediators = c("m1", "m2", "m3"), covars = MED_T_COVARS, B = 2L, seed = 3L, fit_fun = spy)
  fam <- vapply(seen, `[[`, "", "family"); f <- vapply(seen, `[[`, "", "f")
  ga <- f[fam == "gaussian"]
  expect_identical(ga[1:3], c("m1 ~ en_t + ln_t + moy + t_c + hmis_format2017 + demonet + (1 | unit_id)",
                              "m2 ~ en_t + ln_t + moy + t_c + hmis_format2017 + demonet + (1 | unit_id)",
                              "m3 ~ en_t + ln_t + moy + t_c + hmis_format2017 + demonet + (1 | unit_id)"))
  # first attempts (unit random-effect chain us -> diag -> int) of the b-path and of the total model
  nb <- which(fam == "nbinom2")
  ib <- nb[grepl("m1", f[nb], fixed = TRUE)][1]; it <- nb[!grepl("m1", f[nb], fixed = TRUE)][1]
  expect_identical(f[ib], paste("y ~ en_t + m1 + m2 + m3 + ln_t + moy + t_c + hmis_format2017 + demonet +",
                                "offset(log_pop_days) + (1 + t_c | unit_id) + (1 | ym_f)"))
  expect_identical(f[it], paste("y ~ en_t + ln_t + moy + t_c + hmis_format2017 + demonet + offset(log_pop_days) +",
                                "(1 + t_c | unit_id) + (1 | ym_f)"))
  # the point fits (3 a-paths, b-path, total) on the same complete rows
  expect_true(all(vapply(seen[c(which(fam == "gaussian")[1:3], ib, it)], `[[`, 0L, "n") == nrow(d) - 3L))
  expect_identical(r$n, nrow(d) - 3L)
  expect_equal(r$indirect, sum(r$a * r$b))
  expect_equal(r$indirect_by, r$a * r$b)
  expect_equal(r$prop_mediated, r$indirect / r$c_total)
  expect_identical(names(r$a), c("m1", "m2", "m3"))
  expect_identical(r$B, 2L); expect_identical(r$resample, "month_block")
  expect_identical(nrow(r$boot), 2L)
  # resample = "unit": the common cluster bootstrap (units relabelled "<unit>_<k>")
  ru <- mediate_m(d, "y", mediators = c("m1", "m2", "m3"), covars = MED_T_COVARS, resample = "unit", B = 1L,
                  seed = 3L)
  expect_identical(ru$resample, "unit")
  expect_equal(ru$indirect, r$indirect)                   # same point fits
  expect_error(mediate_m(d, "y", mediators = c("m1", "m2", "m3"), covars = MED_T_COVARS, B = 2L, cores = 2L,
                         fit_fun = spy), "closure")
})

test_that("mediate_m enlarges its cluster when more cores free up, with the same resamples", {
  d <- sim_mediation_panel(n_units = 4, n_months = 24, seed = 5)
  calls <- 0L
  rising <- function() { calls <<- calls + 1L; if (calls <= 1L) 1L else 2L }    # 1 core first, then 2
  r2 <- mediate_m(d, "y", mediators = c("m1", "m2", "m3"), covars = MED_T_COVARS, B = 14L, seed = 9L, cores = rising)
  r1 <- mediate_m(d, "y", mediators = c("m1", "m2", "m3"), covars = MED_T_COVARS, B = 14L, seed = 9L, cores = 1L)
  expect_identical(r2$cores_used, c(1L, 2L))
  expect_identical(r1$cores_used, 1L)
  expect_equal(r2$boot[, !"secs"], r1$boot[, !"secs"])
  expect_gte(calls, 2L)
})

test_that("mediation a-, b- and total-path fits get the F61 optimiser limits", {
  d <- sim_mediation_panel(n_units = 4, n_months = 24, seed = 3)
  seen <- list()
  real <- glmmTMB::glmmTMB
  testthat::local_mocked_bindings(glmmTMB = function(formula, data, family, control = glmmTMB::glmmTMBControl(), ...) {
    seen[[length(seen) + 1L]] <<- list(f = deparse1(formula), ctrl = control$optCtrl)
    real(formula, data = data, family = family, control = control, ...)
  }, .package = "glmmTMB")
  r <- tryCatch(mediate_m(d, "y", mediators = c("m1", "m2", "m3"), covars = MED_T_COVARS, B = 1L, seed = 2L),
                error = function(e) NULL)
  expect_gte(length(seen), 5L)                                   # 3 a-paths, b-path, total (at least)
  expect_true(all(vapply(seen, function(s) identical(s$ctrl$iter.max, 1e4) && identical(s$ctrl$eval.max, 1e4), NA)))
  expect_true(any(grepl("^y ~ en_t \\+ m1", vapply(seen, `[[`, "", "f"))))
})

test_that("mediate_m recovers a simulated indirect effect", {
  skip_if_slow_disabled()
  d <- sim_mediation_panel(n_units = 8, n_months = 60, seed = 4)
  r <- mediate_m(d, "y", mediators = c("m1", "m2", "m3"), covars = MED_T_COVARS, B = 20L, seed = 21L)
  expect_identical(r$flag, "ok")
  expect_gte(r$B_ok, 18L)
  expect_true(r$ci$indirect[1] <= 0.05 && 0.05 <= r$ci$indirect[2])
  expect_true(all(abs(unname(r$a) - c(1, -0.5, 0)) < 0.15))
  expect_true(all(abs(unname(r$b) - c(0.10, 0.10, 0.05)) < 0.05))
  expect_true(abs(r$indirect - 0.05) < 0.05)
})
