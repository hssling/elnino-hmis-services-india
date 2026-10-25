# Mediation by the product of coefficients, with a cluster (unit) bootstrap.
#
#   a-path  (Gaussian LMM): mediator ~ exposure + covars + ns(year, df) + (1 | unit_id)
#   b-path  (NB2 GLMM):     outcome  ~ exposure + mediator + covars + ns(year, df) + offset + (1 | unit_id)
#   total   (NB2 GLMM):     outcome  ~ exposure + covars + ns(year, df) + offset + (1 | unit_id)
#
# indirect = a * b is the indirect effect on the log-rate scale per unit of exposure (a in
# mediator units per exposure unit, b in log-rate per mediator unit); c_direct is the
# exposure coefficient in the b-path and c_total the one in the total model;
# prop_mediated = indirect / c_total. With an NB (non-collapsible) outcome
# c_direct + indirect need not equal c_total exactly.
#
# All three models use the same rows: complete on the union of their variables (dropped rows
# returned in `dropped`). The bootstrap resamples units with replacement; every draw becomes
# a distinct cluster "<unit>_<k>" (k = 1..number of units), and all three models are refitted
# on each resample; `boot` keeps a, b, c_direct, c_total (and indirect, prop, error) for every
# resample. CIs (ci$indirect, ci$a, ci$b, ci$c_direct, ci$c_total, ci$prop) are the 2.5% /
# 97.5% percentiles over the successful resamples. A resample fails when any of its fits
# errors, does not converge, or leaves a needed coefficient unidentified (NA). If more than
# 10% of the B resamples fail, every CI is NA, flag = "too_many_failed_fits" and
# prop_flag = "not_assessed" (survivors are never summarised on their own).
#
# Proportion mediated (prop_flag, separate from flag). The point estimate is always returned;
# its CI is given only when the ratio is interpretable:
#   "total_effect_ci_includes_0"     the c_total bootstrap CI includes 0
#   "opposite_signs"                 indirect and c_total point estimates differ in sign
#   "nonfinite_resample_proportion"  a successful resample has a non-finite ratio (c_total = 0);
#                                    counted in B_prop_nonfinite, never dropped silently
#   "ok"                             ci$prop is the percentile CI of the resampled ratios
# In the first three cases ci$prop is NA.
#
# wald: Wald estimate, SE, 95% CI and p of a, b, c_direct and c_total from the point fits.
# messages: fitter messages of the three point fits (a, b, total), recorded, not printed.
#
# Parallel bootstrap (cores > 1): a PSOCK cluster (parallel::makePSOCKcluster, also on
# Windows); each worker gets the master's library paths, setwd(MODELS_ROOT),
# source("common/R/load.R") and options(glmmTMB.cores = 1); resample i uses the same seed as
# serially, so results are identical; the cluster is stopped on exit. The fitter is shipped
# to the workers by value, so a closure (a function with its own environment, e.g. a test
# spy that counts calls) is refused with cores > 1: its state would not be shared.
#
# Seeds: resample i uses seed + i - 1 (applied locally; the caller's RNG stream is restored).

# Resampled copy of d: units drawn with replacement, draw k of unit u relabelled "u_k".
bootstrap_units <- function(d, seed = NULL) {
  d <- data.table::as.data.table(d)
  units <- unique(as.character(d$unit_id))
  pick <- .with_seed(seed, sample(units, length(units), replace = TRUE))
  rows <- split(seq_len(nrow(d)), as.character(d$unit_id))
  out <- data.table::rbindlist(lapply(seq_along(pick), function(k) {
    dk <- d[rows[[pick[k]]]]
    dk[, unit_id := paste0(pick[k], "_", k)]
    dk
  }))
  out[, unit_id := factor(unit_id, levels = unique(unit_id))]
  out[]
}

.trend_term <- function(trend_df) {
  if (!is.null(trend_df) && trend_df > 0) sprintf("splines::ns(year, df = %d)", as.integer(trend_df)) else NULL
}

.a_path_formula <- function(mediator, exposure, covars, trend_df) {
  rhs <- c(exposure, covars, .trend_term(trend_df), "(1 | unit_id)")
  stats::as.formula(paste(mediator, "~", paste(rhs, collapse = " + ")), env = globalenv())
}

# Gaussian a-path through the fitter hook; errors (never returns) on failure. Fitter messages
# are recorded (as fit_nb does), not printed.
.fit_a_path <- function(formula, d, fitter) {
  msgs <- character()
  m <- tryCatch(withCallingHandlers(suppressWarnings(fitter(formula, d, family = stats::gaussian())),
                                    message = function(c) {
                                      msgs <<- c(msgs, trimws(conditionMessage(c)))
                                      invokeRestart("muffleMessage")
                                    }),
                error = function(e) e)
  if (inherits(m, "error")) stop("mediate: a-path fit failed: ", conditionMessage(m), call. = FALSE)
  if (!.converged(m)) stop("mediate: a-path fit did not converge (or non-positive-definite Hessian)", call. = FALSE)
  list(model = m, messages = msgs)
}

.coef_or_stop <- function(model, term, what) {
  v <- glmmTMB::fixef(model)$cond[term]
  if (is.na(v)) stop("mediate: ", what, " coefficient '", term, "' is unidentified (NA)", call. = FALSE)
  unname(v)
}

# Wald estimate, SE, 95% CI and p for one conditional fixed effect.
.wald_row <- function(model, term, path) {
  co <- summary(model)$coefficients$cond
  est <- co[term, 1]; se <- co[term, 2]
  data.table::data.table(path = path, term = term, est = est, se = se,
                         lo = est - 1.959964 * se, hi = est + 1.959964 * se, p = co[term, 4])
}

# The three fits on d (already complete rows). Returns the path coefficients and nobs; with
# detail = TRUE also the Wald table and the fitter messages of each model.
.mediation_fits <- function(d, outcome, exposure, mediator, covars, offset, trend_df, fitter, detail = FALSE) {
  fa <- .fit_a_path(.a_path_formula(mediator, exposure, covars, trend_df), d, fitter)
  fb <- fit_nb(nb_spec(outcome, fixed = c(exposure, mediator, covars), offset = offset,
                       trend_df = trend_df, re = "int"), d, fitter = fitter)
  ft <- fit_nb(nb_spec(outcome, fixed = c(exposure, covars), offset = offset,
                       trend_df = trend_df, re = "int"), d, fitter = fitter)
  out <- list(a = .coef_or_stop(fa$model, exposure, "a-path"),
              b = .coef_or_stop(fb$model, mediator, "b-path"),
              c_direct = .coef_or_stop(fb$model, exposure, "b-path"),
              c_total = .coef_or_stop(ft$model, exposure, "total-effect"),
              n_by_model = c(a = stats::nobs(fa$model), b = stats::nobs(fb$model), total = stats::nobs(ft$model)))
  if (detail) {
    out$wald <- data.table::rbindlist(list(.wald_row(fa$model, exposure, "a"), .wald_row(fb$model, mediator, "b"),
                                           .wald_row(fb$model, exposure, "c_direct"),
                                           .wald_row(ft$model, exposure, "c_total")))
    out$messages <- list(a = fa$messages, b = fb$messages, total = ft$messages)
  }
  out
}

# One bootstrap resample. Top level, so parLapply ships it to PSOCK workers, where its
# globals (bootstrap_units, .mediation_fits) resolve to the worker's sourced copies.
.boot_one <- function(i, d, seed, outcome, exposure, mediator, covars, offset, trend_df, fitter) {
  di <- bootstrap_units(d, seed = seed + i - 1L)
  r <- tryCatch(.mediation_fits(di, outcome, exposure, mediator, covars, offset, trend_df, fitter),
                error = function(e) e)
  if (inherits(r, "error"))
    return(list(i = as.integer(i), a = NA_real_, b = NA_real_, c_direct = NA_real_, c_total = NA_real_,
                error = conditionMessage(r)))
  list(i = as.integer(i), a = r$a, b = r$b, c_direct = r$c_direct, c_total = r$c_total, error = NA_character_)
}

# PSOCK worker set-up: same library paths, models root, shared functions; glmmTMB single-threaded.
.mediate_worker_init <- function(root, libs) {
  .libPaths(libs)
  setwd(root)
  source("common/R/load.R")
  options(glmmTMB.cores = 1L)
  invisible(TRUE)
}

.pct <- function(v) stats::quantile(v, c(0.025, 0.975), names = FALSE)
.na_ci <- function() c(NA_real_, NA_real_)

# Proportion-mediated CI and prop_flag (see header). boot_ok: successful resamples with
# columns indirect, c_total, prop.
.prop_ci <- function(indirect, c_total, boot_ok, ci_c_total = .pct(boot_ok$c_total)) {
  flag <- if (ci_c_total[1] <= 0 && 0 <= ci_c_total[2]) "total_effect_ci_includes_0"
          else if (sign(indirect) != sign(c_total)) "opposite_signs"
          else if (any(!is.finite(boot_ok$prop))) "nonfinite_resample_proportion"
          else "ok"
  list(prop_flag = flag, ci = if (flag == "ok") .pct(boot_ok$prop) else .na_ci())
}

mediate <- function(data, outcome, exposure, mediator, covars = character(), offset = "log_pop",
                    trend_df = 4L, B = 1000, seed = 1, fitter = glmmTMB_fit, cores = 1L) {
  if (length(B) != 1L || is.na(B) || B < 1) stop("mediate: B must be a positive integer", call. = FALSE)
  B <- as.integer(B)
  if (length(cores) != 1L || is.na(cores) || cores < 1) stop("mediate: cores must be a positive integer", call. = FALSE)
  cores <- as.integer(cores)
  if (cores > 1L) {
    fe <- environment(fitter)
    if (!is.null(fe) && !identical(fe, globalenv()) && !isNamespace(fe))
      stop("mediate: with cores > 1 the fitter must be a top-level function (global environment or a ",
           "package), not a closure: its state would not be shared with the workers. Use cores = 1.", call. = FALSE)
  }
  vars <- unique(c(outcome, exposure, mediator, covars, offset, "year", "unit_id"))
  cr <- complete_rows(data.table::as.data.table(data), vars)
  d <- droplevels(cr$data)
  if (nrow(d) == 0L) stop("mediate: no complete rows remain (", nrow(cr$dropped), " rows dropped)", call. = FALSE)

  est <- .mediation_fits(d, outcome, exposure, mediator, covars, offset, trend_df, fitter, detail = TRUE)
  if (length(unique(est$n_by_model)) != 1L || est$n_by_model[[1]] != nrow(d))
    stop("mediate: the three models were not fitted on the same rows: ",
         paste(names(est$n_by_model), est$n_by_model, collapse = ", "), call. = FALSE)
  indirect <- est$a * est$b

  args <- list(d = d, seed = seed, outcome = outcome, exposure = exposure, mediator = mediator,
               covars = covars, offset = offset, trend_df = trend_df, fitter = fitter)
  if (cores > 1L) {
    cl <- parallel::makePSOCKcluster(cores)
    on.exit(parallel::stopCluster(cl), add = TRUE)
    parallel::clusterCall(cl, .mediate_worker_init, MODELS_ROOT, .libPaths())
    res <- do.call(parallel::parLapply, c(list(cl = cl, X = seq_len(B), fun = .boot_one), args))
  } else {
    res <- do.call(lapply, c(list(X = seq_len(B), FUN = .boot_one), args))
  }
  boot <- data.table::rbindlist(res)
  boot[, indirect := a * b]
  boot[, prop := indirect / c_total]
  data.table::setcolorder(boot, c("i", "a", "b", "c_direct", "c_total", "indirect", "prop", "error"))
  ok <- is.na(boot$error)
  B_ok <- sum(ok); B_failed <- B - B_ok
  prop_nonfinite <- ok & !is.finite(boot$prop)

  if (B_failed > 0.1 * B) {
    flag <- "too_many_failed_fits"
    prop_flag <- "not_assessed"
    ci <- list(indirect = .na_ci(), prop = .na_ci(), a = .na_ci(), b = .na_ci(),
               c_direct = .na_ci(), c_total = .na_ci())
  } else {
    flag <- "ok"
    bo <- boot[ok]
    ci <- list(indirect = .pct(bo$indirect), prop = .na_ci(), a = .pct(bo$a), b = .pct(bo$b),
               c_direct = .pct(bo$c_direct), c_total = .pct(bo$c_total))
    pc <- .prop_ci(indirect, est$c_total, bo, ci$c_total)
    prop_flag <- pc$prop_flag
    ci$prop <- pc$ci
  }
  list(a = est$a, b = est$b, c_total = est$c_total, c_direct = est$c_direct,
       indirect = indirect, prop_mediated = indirect / est$c_total,
       ci = ci, wald = est$wald, n = nrow(d), n_by_model = est$n_by_model, dropped = cr$dropped,
       B = B, B_ok = as.integer(B_ok), B_failed = as.integer(B_failed),
       B_prop_nonfinite = as.integer(sum(prop_nonfinite)), flag = flag, prop_flag = prop_flag,
       boot = boot[], messages = est$messages, fail_messages = unique(boot$error[!ok]), cores = cores)
}
