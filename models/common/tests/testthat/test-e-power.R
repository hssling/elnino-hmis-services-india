# Paper E Task 7: power simulation and the MDE rule (models/E/R/power.R; contract §7, rulings F47, F49).

local({
  root <- if (exists("MODELS_ROOT")) MODELS_ROOT else normalizePath(file.path(getwd(), "..", "..", ".."), winslash = "/")
  for (f in c("common_e.R", "monthly.R", "power.R")) source(file.path(root, "E", "R", f), local = globalenv())
})

test_that("mde picks the IRR closest to 1 with power >= 0.8", {
  expect_equal(mde(data.table::data.table(irr = c(.90, .95, .97, .99), power = c(1, .85, .6, .1)))$value, 0.95)
  expect_identical(mde(data.table::data.table(irr = c(.90, .95, .97, .99), power = c(1, .85, .6, .1)))$display, "0.95")
  expect_identical(mde(data.table::data.table(irr = c(.90, .95, .97, .99), power = c(.7, .3, .1, .05)))$display,
                   "not reached at IRR 0.90")
  expect_true(is.na(mde(data.table::data.table(irr = c(.90, .95, .97, .99), power = c(.7, .3, .1, .05)))$value))
  # order of rows does not matter; exactly 0.80 counts; NA power (no successful refit) never counts
  expect_equal(mde(data.table::data.table(irr = c(.99, .97, .90, .95), power = c(NA, .8, 1, .9)))$value, 0.97)
  expect_equal(mde(data.table::data.table(irr = c(.90, .95, .97, .99), power = c(160 / 200, .79, .5, .1)))$value, 0.90)
})

test_that("mde for an increase (diarr_u5, F47/F49): IRR closest to 1 above 1, display 'not reached at IRR 1.11'", {
  up <- 1 / c(.90, .95, .97, .99)
  r <- mde(data.table::data.table(irr = up, power = c(1, .9, .5, .1)))
  expect_equal(r$value, 1 / .95)
  expect_identical(r$display, "1.05")
  expect_identical(mde(data.table::data.table(irr = up, power = c(1, .9, .85, .81)))$display, "1.01")
  expect_identical(mde(data.table::data.table(irr = up, power = c(.6, .3, .1, .05)))$display, "not reached at IRR 1.11")
  expect_identical(mde(data.table::data.table(irr = up, power = c(.6, .3, .1, .05)), direction = "increase")$display,
                   "not reached at IRR 1.11")
})

test_that("power settings per outcome: diarr_u5 is simulated for increases, every other outcome for decreases", {
  expect_identical(power_direction("diarr_u5"), "increase")
  for (o in setdiff(INDS, "diarr_u5")) expect_identical(power_direction(o), "decrease")
  expect_equal(power_irrs("anc_reg"), c(0.90, 0.95, 0.97, 0.99))
  expect_equal(power_irrs("diarr_u5"), 1 / c(0.90, 0.95, 0.97, 0.99))
})

test_that("a simulated draw is reproducible per simulation index and scales the mean by irr^en_t", {
  st <- list(eta = rep(log(5000), 600), ym_f = factor(rep(1:60, 10)), en_t = rep(c(0, 2), 300), sd_ym = 0,
             theta = 1e6)
  a <- power_draw(st, irr = 0.9, i = 3L, seed = 7L)
  expect_identical(a, power_draw(st, irr = 0.9, i = 3L, seed = 7L))
  expect_false(identical(a, power_draw(st, irr = 0.9, i = 4L, seed = 7L)))
  expect_equal(mean(a[st$en_t == 2]) / mean(a[st$en_t == 0]), 0.81, tolerance = 0.01)
  # the year-month effect is shared by every unit in a month
  st2 <- modifyList(st, list(sd_ym = 0.5, en_t = rep(0, 600)))
  b <- power_draw(st2, irr = 1, i = 1L, seed = 1L)
  by_month <- tapply(log(b), st2$ym_f, stats::sd)
  expect_lt(max(by_month), 0.05)
  expect_gt(stats::sd(tapply(log(b), st2$ym_f, mean)), 0.3)
})

test_that("the null model has no ENSO term and the state drops the year-month effect from eta", {
  d <- sim_month_panel(n_units = 8, n_months = 60, sd_ym = 0.1, seed = 5)
  d[, opd := y]
  st <- power_null_state(d, "opd")
  expect_false(any(c("en_t", "ln_t") %in% st$null_spec$fixed))
  expect_identical(st$alt_spec$fixed[1:2], c("en_t", "ln_t"))
  expect_false("en_t" %in% names(glmmTMB::fixef(st$null_fit$model)$cond))
  expect_identical(st$null_fit$time_re, "iid")
  m <- st$null_fit$model
  b <- glmmTMB::ranef(m)$cond$ym_f
  expect_equal(exp(st$eta + b[as.character(st$data$ym_f), "(Intercept)"]), unname(stats::fitted(m)), tolerance = 1e-6)
  expect_equal(st$theta, stats::sigma(m))
  expect_gt(st$sd_ym, 0)
  expect_identical(length(st$eta), nrow(st$data))
})

test_that("a failed null fit is a power_null_error naming the outcome (review fix round 1, item 4)", {
  d <- sim_month_panel(n_units = 6, n_months = 30, seed = 3)
  d[, inst_del := y]
  never <- function(formula, data, family = glmmTMB::nbinom2()) stop("no")
  e <- tryCatch(simulate_power(d, "inst_del", n_sim = 1L, fit_fun = never), error = function(e) e)
  expect_s3_class(e, "power_null_error")
  expect_match(conditionMessage(e), "null Model T for inst_del: fit_nb: no structure converged", fixed = TRUE)
})

# ---- the 01_power.R budget rule and entry point (review fix round 1, items 3-5); no model is fitted here
local({
  root <- if (exists("MODELS_ROOT")) MODELS_ROOT else normalizePath(file.path(getwd(), "..", "..", ".."), winslash = "/")
  source(file.path(root, "E", "01_power.R"), local = globalenv())
})

fake_timing <- function(secs, fail = character()) function(o) {
  if (o %in% fail) stop(errorCondition(sprintf("null Model T for %s: no structure converged", o),
                                       class = "power_null_error"))
  data.table::data.table(outcome = o, refit_secs = secs, total_secs = 4 * secs)
}

test_that("budget rule: over budget runs PRIMARY5 first and a secondary outcome only if the remaining budget covers it", {
  # 27 s per one-core refit x 200 sims x 4 IRRs x slowdown 1.6 / 8 cores = 1.2 h per outcome; 7 outcomes = 8.4 h > 8 h
  ran <- character()
  clock <- 0
  run <- function(o, k, n, need_secs) { ran <<- c(ran, o); clock <<- clock + need_secs / 3600; paste("result", o) }
  sch <- power_schedule(INDS, time_fun = fake_timing(27), run_fun = run, n_sim = 200L, cores = 8L, budget_hours = 8,
                        slowdown = 1.6, hours_since = function() clock)
  expect_equal(sch$projection_hours, 8.4)
  expect_true(sch$over)
  expect_match(sch$run_plan, "PRIMARY5 first, secondary outcomes only if time remains", fixed = TRUE)
  # after the five primary outcomes 6.0 h are used: mcv1 (1.2 h) fits in the remaining 2.0 h, fic (1.2 h) not in 0.8 h
  expect_identical(ran, c(PRIMARY5, "mcv1"))
  expect_identical(unname(sch$status[c(PRIMARY5, "mcv1")]), rep("estimated", 6L))
  expect_identical(unname(sch$status[["fic"]]), POWER_NOT_RUN)
  expect_null(sch$results[["fic"]])
  expect_identical(sch$results[["mcv1"]], "result mcv1")
})

test_that("budget rule: the parallel slowdown factor enters the projection; under budget every outcome runs", {
  ran <- character()
  run <- function(o, k, n, need_secs) { ran <<- c(ran, o); o }
  sch <- power_schedule(INDS, time_fun = fake_timing(27), run_fun = run, n_sim = 200L, cores = 8L, budget_hours = 8,
                        slowdown = 1, hours_since = function() 0)
  expect_equal(sch$projection_hours, 5.25)
  expect_false(sch$over)
  expect_identical(ran, c(PRIMARY5, "mcv1", "fic"))
  expect_true(all(sch$status == "estimated"))
  expect_identical(POWER_SLOWDOWN, 1.6)
  expect_identical(power_settings(character())$slowdown, 1.6)
  expect_identical(power_settings("--slowdown=2")$slowdown, 2)
})

test_that("budget rule: an outcome whose null fit fails is not estimable and the run continues", {
  ran <- character()
  run <- function(o, k, n, need_secs) {
    if (o == "penta3") stop(errorCondition("null Model T for penta3: boom", class = "power_null_error"))
    ran <<- c(ran, o); o
  }
  sch <- power_schedule(INDS, time_fun = fake_timing(1, fail = "fic"), run_fun = run, n_sim = 200L, cores = 8L,
                        budget_hours = 8, hours_since = function() 0)
  expect_identical(ran, c("diarr_u5", "anc_reg", "inst_del", "opd", "mcv1"))
  expect_identical(unname(sch$status[["fic"]]), "not estimable (null Model T for fic: no structure converged)")
  expect_identical(unname(sch$status[["penta3"]]), "not estimable (null Model T for penta3: boom)")
  expect_true(is.na(sch$timing[outcome == "fic"]$refit_secs))
  # any other error is not swallowed
  bad <- function(o, k, n, need_secs) stop("a programming error")
  expect_error(power_schedule("opd", time_fun = fake_timing(1), run_fun = bad, n_sim = 2L, cores = 1L,
                              budget_hours = 8, hours_since = function() 0), "a programming error")
})

test_that("not-estimable and not-run outcomes get their status as the MDE display in power.csv rows", {
  s <- list(n_sim = 200L, cores = 8L, budget_hours = 8, slowdown = 1.6)
  tm <- data.table::data.table(outcome = "fic", refit_secs = NA_real_, total_secs = NA_real_)
  r <- power_rows("fic", NULL, s, tm, 1, "plan", status = "not estimable (null Model T for fic: x)")
  expect_identical(unique(r$status), "not estimable (null Model T for fic: x)")
  expect_identical(unique(r$mde_display), "not estimable (null Model T for fic: x)")
  expect_identical(nrow(r), 4L)
})

test_that("bad arguments write a FAILED marker to the progress file (review fix round 1, item 5)", {
  prog <- tempfile(fileext = ".txt")
  lg <- tempfile(fileext = ".log")
  on.exit(unlink(c(prog, lg)))
  ok <- suppressMessages(power_entry(c("--outcomes=bogus", paste0("--progress=", prog), paste0("--log=", lg))))
  expect_false(ok)
  p <- readLines(prog)
  expect_match(p[1], "^FAILED ")
  expect_true(any(grepl("unknown outcome(s): bogus", p, fixed = TRUE)))
  expect_true(any(grepl("FAILED: unknown outcome(s): bogus", readLines(lg), fixed = TRUE)))
})

test_that("simulate_power returns the contract table and counts rejections in the stated direction", {
  d <- sim_month_panel(n_units = 8, n_months = 60, seed = 6)
  d[, anc_reg := y]
  r <- simulate_power(d, "anc_reg", irrs = c(0.95, 1), n_sim = 2L, seed = 9L)
  expect_named(r, c("outcome", "irr", "n_ok", "power", "mean_irr"))
  expect_identical(r$outcome, rep("anc_reg", 2L))
  expect_equal(r$irr, c(0.95, 1))
  sims <- attr(r, "sims")
  expect_identical(nrow(sims), 4L)
  expect_true(all(c("irr", "sim", "ok", "est", "se", "p", "reject", "re_used", "secs") %in% names(sims)))
  expect_identical(sims$reject, sims$ok & sims$p < 0.05 & sims$est < 0)
  expect_identical(attr(r, "null")$direction, "decrease")
  expect_identical(attr(r, "null")$time_re, "iid")
  expect_error(simulate_power(d, "anc_reg", n_sim = 1L, direction = "sideways"), "should be one of")
})

test_that("simulate_power detects a large effect and holds size", {
  skip_if_slow_disabled()
  d <- sim_month_panel(n_units = 20, n_months = 95, theta = 20, sd_ym = 0.05, seed = 1)
  d[, anc_reg := y]
  r <- simulate_power(d, "anc_reg", irrs = c(0.80, 1.00), n_sim = 20L)
  expect_identical(r$n_ok, c(20L, 20L))
  expect_gte(r[irr == 0.80]$power, 0.8)
  expect_lte(r[irr == 1.00]$power, 0.2)
  expect_lt(abs(r[irr == 0.80]$mean_irr - 0.80), 0.05)
  # an increase is detected only under direction = "increase", and a decrease never counts there (F49)
  u <- simulate_power(d, "anc_reg", irrs = c(0.80, 1.25), n_sim = 10L, direction = "increase")
  expect_gte(u[irr == 1.25]$power, 0.8)
  expect_identical(u[irr == 0.80]$power, 0)
  sims <- attr(u, "sims")
  expect_identical(sims$reject, sims$ok & sims$p < 0.05 & sims$est > 0)
})

test_that("simulate_power gives the same result on 1 and 2 cores", {
  skip_if_slow_disabled()
  d <- sim_month_panel(n_units = 8, n_months = 60, seed = 8)
  d[, penta3 := y]
  one <- simulate_power(d, "penta3", irrs = c(0.9, 0.97), n_sim = 2L, cores = 1L)
  two <- simulate_power(d, "penta3", irrs = c(0.9, 0.97), n_sim = 2L, cores = 2L)
  strip <- function(x) { x <- data.table::copy(x); attr(x, "sims") <- NULL; attr(x, "null") <- NULL; x }
  expect_equal(strip(one), strip(two))
  expect_equal(attr(one, "sims")$est, attr(two, "sims")$est)
})
