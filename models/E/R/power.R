# Paper E power simulation and the MDE rule (Task 7; contract §7 and "The MDE"; spec §5.8 with §10.5; rulings
# F47, F49). Sourced after common/R/load.R, common_e.R and monthly.R.
#
# Design: fit Model T WITHOUT en_t/ln_t (iid year-month effect (1 | ym_f)) on the real data; per simulation,
# redraw the year-month effects from N(0, sd_ym^2), keep the unit random effects at their conditional modes, set
# mu = exp(eta + new year-month effect) * irr^en_t and draw y ~ NB2(mu, theta); refit Model T WITH en_t and ln_t
# (iid time effect) on the simulated counts. No model containing en_t is ever fitted to the real outcome here.
# Rejection: two-sided Wald p < 0.05 and an en_t coefficient < 0 (direction "decrease") or > 0 ("increase",
# diarr_u5 only, F47/F49).
# Seeds: simulation i (any irr) draws with set.seed(seed + i - 1), so the IRRs share their random numbers
# (common random numbers) and the result does not depend on the number of cores or the scheduling.

POWER_IRRS_DECREASE <- c(0.90, 0.95, 0.97, 0.99)

power_direction <- function(outcome) if (identical(outcome, "diarr_u5")) "increase" else "decrease"

power_irrs <- function(outcome)
  if (power_direction(outcome) == "increase") 1 / POWER_IRRS_DECREASE else POWER_IRRS_DECREASE

# The simulation state from the null fit: the rows used (complete for the ALTERNATIVE model's variables, so null
# fit and refits use the same rows), eta = the linear predictor with offset and unit conditional modes but without
# the year-month effect, sd_ym, theta (glmmTMB's sigma() of an nbinom2 fit), and both specs.
power_null_state <- function(d, outcome, fit_fun = glmmTMB_fit) {
  alt <- t_spec(outcome)
  null <- t_spec(outcome, exposure = character())
  if (any(c("en_t", "ln_t") %in% null$fixed)) stop("power_null_state: the null model must not contain en_t/ln_t")
  cr <- complete_rows(d, unique(c(spec_vars(alt), "ym_f")))
  d0 <- droplevels(cr$data)
  f0 <- fit_nb(null, d0, fitter = nb_fitter_with(TIME_RE[["iid"]], fit_fun))
  f0$time_re <- "iid"
  if (nrow(f0$data) != nrow(d0)) stop("power_null_state: the null fit dropped rows", call. = FALSE)
  m <- f0$model
  b_ym <- glmmTMB::ranef(m)$cond$ym_f
  eta <- unname(stats::predict(m, type = "link")) - b_ym[as.character(f0$data$ym_f), "(Intercept)"]
  list(outcome = outcome, null_spec = null, alt_spec = alt, null_fit = f0, data = f0$data, eta = unname(eta),
       ym_f = f0$data$ym_f, en_t = f0$data$en_t, sd_ym = unname(attr(glmmTMB::VarCorr(m)$cond$ym_f, "stddev")[[1]]),
       theta = unname(stats::sigma(m)), dropped = cr$dropped)
}

# Simulated counts for simulation i at `irr` (seed + i - 1).
power_draw <- function(st, irr, i, seed) {
  set.seed(seed + i - 1L)
  b <- stats::rnorm(nlevels(st$ym_f), 0, st$sd_ym)
  mu <- exp(st$eta + b[as.integer(st$ym_f)]) * irr^st$en_t
  stats::rnbinom(length(mu), size = st$theta, mu = mu)
}

# One simulation: draw, refit the iid Model T with en_t and ln_t, return its en_t row (or the error).
power_refit_one <- function(task, st) {
  t0 <- Sys.time()
  dd <- data.table::copy(st$data)
  data.table::set(dd, j = st$outcome, value = power_draw(st, task$irr, task$sim, st$seed))
  r <- tryCatch({
    f <- fit_nb(st$alt_spec, dd, fitter = nb_fitter_with(TIME_RE[["iid"]], st$fit_fun))
    list(row = term_row(f, "en_t"), re_used = f$re_used)
  }, error = function(e) e)
  ok <- !inherits(r, "error")
  data.table::data.table(irr = task$irr, sim = task$sim, ok = ok, est = if (ok) r$row$est else NA_real_,
                         se = if (ok) r$row$se else NA_real_, p = if (ok) r$row$p else NA_real_,
                         re_used = if (ok) r$re_used else NA_character_,
                         error = if (ok) NA_character_ else conditionMessage(r),
                         secs = as.numeric(difftime(Sys.time(), t0, units = "secs")))
}

# Worker-side task: defined at top level (environment globalenv) so that only the task, not simulate_power's frame,
# is serialised per call; the shared state is shipped once to each worker as .E_POWER_STATE.
.e_power_task <- function(task) power_refit_one(task, get(".E_POWER_STATE", envir = globalenv()))

.e_worker_init <- function(root, libs) {
  .libPaths(libs)
  setwd(root)
  source("common/R/load.R")
  for (f in c("common_e.R", "monthly.R", "power.R")) source(file.path("E", "R", f))
  options(glmmTMB.cores = 1L)
  invisible(TRUE)
}

.e_cluster <- function(cores) {
  cl <- NULL
  # renv start-up in simultaneously launched workers occasionally fails (as in Paper D); retry the start
  for (attempt in 1:3) {
    cl <- tryCatch(parallel::makePSOCKcluster(cores), error = function(e) NULL)
    if (!is.null(cl)) break
  }
  if (is.null(cl)) stop("could not start the PSOCK cluster", call. = FALSE)
  parallel::clusterCall(cl, .e_worker_init, MODELS_ROOT, .libPaths())
  cl
}

# Power per IRR: data.table(outcome, irr, n_ok, power, mean_irr). power = rejections / successful refits (n_ok);
# mean_irr = exp(mean en_t coefficient over successful refits). Attributes: "sims" (one row per simulation: irr,
# sim, ok, est, se, p, reject, re_used, error, secs) and "null" (the null fit: n, n_units, re_used, time_re,
# sd_ym, theta, direction, seed, n_sim). progress(done, total), if given, is called after each chunk of refits.
simulate_power <- function(d, outcome, irrs = c(0.90, 0.95, 0.97, 0.99), n_sim = 200L, seed = SEED_E, cores = 1L,
                           direction = c("decrease", "increase"), fit_fun = glmmTMB_fit, progress = NULL) {
  direction <- match.arg(direction)
  n_sim <- as.integer(n_sim)
  # a failed null fit is a "power_null_error": 01_power.R records the outcome as not estimable and continues
  st <- tryCatch(power_null_state(d, outcome, fit_fun), error = function(e)
    stop(errorCondition(sprintf("null Model T for %s: %s", outcome, conditionMessage(e)), class = "power_null_error")))
  st$seed <- as.integer(seed)
  st$fit_fun <- fit_fun
  tasks <- lapply(seq_len(n_sim * length(irrs)), function(k)
    list(irr = irrs[(k - 1L) %/% n_sim + 1L], sim = (k - 1L) %% n_sim + 1L))
  ship <- st[c("outcome", "alt_spec", "data", "eta", "ym_f", "en_t", "sd_ym", "theta", "seed", "fit_fun")]
  chunk <- max(1L, 4L * as.integer(cores))
  out <- vector("list", length(tasks))
  cl <- NULL
  if (cores > 1L) {
    cl <- .e_cluster(as.integer(cores))
    on.exit(parallel::stopCluster(cl), add = TRUE)
    parallel::clusterCall(cl, function(s) { assign(".E_POWER_STATE", s, envir = globalenv()); NULL }, ship)
  }
  for (s in seq(1L, length(tasks), by = chunk)) {
    idx <- s:min(length(tasks), s + chunk - 1L)
    out[idx] <- if (is.null(cl)) lapply(tasks[idx], power_refit_one, st = ship) else
      parallel::clusterApplyLB(cl, tasks[idx], .e_power_task)
    if (is.function(progress)) progress(max(idx), length(tasks))
  }
  sims <- data.table::rbindlist(out)
  sims[, reject := ok & p < 0.05 & (if (direction == "decrease") est < 0 else est > 0)]
  sims[is.na(reject), reject := FALSE]
  data.table::setcolorder(sims, c("irr", "sim", "ok", "est", "se", "p", "reject", "re_used", "error", "secs"))
  tab <- sims[, .(n_ok = as.integer(sum(ok)),
                  power = if (any(ok)) sum(reject) / sum(ok) else NA_real_,
                  mean_irr = if (any(ok)) exp(mean(est[ok])) else NA_real_), by = irr]
  tab <- data.table::data.table(outcome = outcome, tab)
  data.table::setattr(tab, "sims", sims)
  data.table::setattr(tab, "null", list(n = st$null_fit$n, n_units = nlevels(st$data$unit_id),
                                        re_used = st$null_fit$re_used, time_re = st$null_fit$time_re,
                                        sd_ym = st$sd_ym, theta = st$theta, direction = direction, seed = st$seed,
                                        n_sim = n_sim, dropped = nrow(st$dropped)))
  tab[]
}

# The MDE rule: the IRR closest to 1 with power >= 0.80; if none, "not reached at IRR <the IRR farthest from 1>"
# ("not reached at IRR 0.90"; for an increase, diarr_u5, "not reached at IRR 1.11"). value is NA when not reached.
mde <- function(tbl, direction = if (all(tbl$irr > 1)) "increase" else "decrease") {
  direction <- match.arg(direction, c("decrease", "increase"))
  far <- if (direction == "increase") max(tbl$irr) else min(tbl$irr)
  hit <- tbl$irr[!is.na(tbl$power) & tbl$power >= 0.80]
  if (!length(hit)) return(list(value = NA_real_, display = paste("not reached at IRR", fmt_num(far, 2))))
  v <- hit[which.min(abs(log(hit)))]
  list(value = v, display = fmt_num(v, 2))
}
