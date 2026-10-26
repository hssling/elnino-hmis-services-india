# Paper E Task 9: secondary and sensitivity analyses (contract papers/E/results_keys.md §5 cum02/tmax, §8-§11;
# spec §4, §5.5, §5.9; rulings F14, F19, F23, F28, F44, F52, F56). Sourced after common/R/load.R, common_e.R,
# monthly.R, power.R and verdicts.R. Model fitting helpers only; 04_secondary.R runs them and builds the keys.
#
# Every Model T-type fit here (sensitivities, IOD, distributed lag) goes through the time random-effect chain of
# Task 7 (fit_time_chain(): ar1, then iid) with the moving-block bootstrap (B = 1,000) as its last step, exactly as
# Model T (contract "The time random-effect chain"). Expression terms (splines::ns(t_c, df = 2), unit_id:sin12,
# (1 | unit_era), en_t:dmi_3m) travel in `extra`, never in nb_spec(fixed = ), because complete_rows() reads every
# fixed entry as a column. Every fit uses the F61 optimiser limits (e_glmmTMB_fit / e_fitter(), monthly.R;
# nb_fitter_with, fit_time_chain and block_bootstrap_irr apply them too). Only a genuine estimation failure
# (is_estimation_failure(), F56) makes a result not estimable; any other error stops the run.

SENS_IDS <- c("fy2021", "comp075", "comp000", "scaled", "births", "nosmall", "era_int", "ns2", "harmonic",
              "extra_prog", "drop_ep1415", "drop_ep1819", "masklow", "allcomp")      # + roni, nino34 (Task 10)

# The LOEO episode windows (contract "Episode terms"), inclusive, on ym = year * 12 + month - 1.
EP_WINDOWS <- list(ep1415 = c(2014L * 12L + 9L, 2016L * 12L + 11L),      # October 2014 .. December 2016
                   ep1819 = c(2018L * 12L + 8L, 2020L * 12L + 1L))       # September 2018 .. February 2020
FY2021_END_YM <- 2021L * 12L + 2L                                        # March 2021
SINGLE_ITEM <- c("diarr_u5", "anc_reg")          # single-item in every era: <ind>_allcomp equals <ind> (contract §11)
NO_BIRTHS_DENOMINATOR <- c("diarr_u5", "opd")    # births offset not meaningful (spec §5.9)
SRS_NOT_AVAILABLE <- "not available (SRS not retrieved)"                  # F23, F44
ALLCOMP_NA <- "not applicable (single-item indicator; identical to the primary analysis)"
FY2021_STATUS_JSON <- file.path(REPO_ROOT, "data", "derived", "hmis", "fy2021_status.json")

SENS_TEXT <- c(
  fy2021 = "through March 2021 (108 months) with covid_mar2020 and covid_fy2021 (F19)",
  comp075 = "outcome <ind>_c75 (completeness >= 0.75)",
  comp000 = "outcome <ind>_c00 (no completeness threshold)",
  scaled = "outcome <ind>_scaled (valid-district sum / completeness)",
  births = "offset log_births (log_preg for anc_reg)",
  nosmall = "the seven small units (LD, CH, PY, DNH_DD, AN, SK, GA) dropped",
  era_int = "random intercept (1 | unit_era) added; hmis_format2017 kept (F28, deliberate deviation from spec 5.9.5)",
  ns2 = "t_c removed from the fixed effects and splines::ns(t_c, df = 2) added; random slope on t_c kept",
  harmonic = "unit_id:sin12 and unit_id:cos12 added",
  extra_prog = "diwali added (pmsma for anc_reg, laqshya for inst_del)",
  drop_ep1415 = "October 2014 to December 2016 dropped",
  drop_ep1819 = "September 2018 to February 2020 dropped",
  masklow = "outcome <ind>_masklow (default-kept plausibility lows masked; F41, F44)",
  allcomp = "outcome <ind>_allcomp (every crosswalk component present; F37, F44)")

.in_window <- function(ym, w) ym >= w[1] & ym <= w[2]

# splines::ns(t_c, df = 2) with its interior knot (the median) and boundary knots taken once from the rows of the
# original fit, written out in full precision, so every month-block bootstrap refit uses the same trend basis as the
# original rows (on which it equals splines::ns(t_c, df = 2); review finding 5).
ns2_term <- function(t_c) {
  b <- splines::ns(t_c, df = 2)
  num <- function(x) sprintf("%.17g", x)
  sprintf("splines::ns(t_c, knots = %s, Boundary.knots = c(%s, %s))", num(attr(b, "knots")),
          num(attr(b, "Boundary.knots")[1]), num(attr(b, "Boundary.knots")[2]))
}

.with_outcome <- function(spec, outcome) {
  spec$outcome <- outcome
  spec
}

# git(args) -> output lines, run in the repository (injectable for tests).
.sec_git <- function(args) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(REPO_ROOT), args), stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status")
  if (!is.null(st) && st != 0L) stop("git ", paste(args, collapse = " "), " failed: ", paste(out, collapse = "; "),
                                     call. = FALSE)
  out
}

# Is FY2020-21 final at the Task 9 sync point (F3)? The status file exists, reads "acquired", and is committed with
# no uncommitted change. Returns list(ok, reason, status); reason completes "FY2020-21 <reason>".
fy2021_ready <- function(path = FY2021_STATUS_JSON, git = .sec_git, release = e_release_mode()) {
  if (!file.exists(path)) return(list(ok = FALSE, reason = "status file missing", status = NA_character_))
  txt <- paste(readLines(path, warn = FALSE), collapse = "\n")
  m <- regmatches(txt, regexec('"status"\\s*:\\s*"([^"]*)"', txt))[[1]]
  status <- if (length(m) == 2L) m[2] else NA_character_
  if (!identical(status, "acquired"))
    return(list(ok = FALSE, reason = sprintf("not acquired (status %s)", status), status = status))
  if (isTRUE(release)) {                       # release mode: the committed-and-clean part reads the private history
    e_release_skip("fy2021_ready(): the committed-and-clean check of the FY2020-21 status file")
    return(list(ok = TRUE, reason = NA_character_, status = status))
  }
  rel <-sub(paste0("^", gsub("([.\\\\+*?^$(){}|\\[\\]])", "\\\\\\1", normalizePath(REPO_ROOT, winslash = "/")), "/"),
             "", normalizePath(path, winslash = "/", mustWork = FALSE))
  if (!length(git(c("ls-files", "--", rel))))
    return(list(ok = FALSE, reason = "status file not committed", status = status))
  if (length(git(c("status", "--porcelain", "--", rel))))
    return(list(ok = FALSE, reason = "status file has uncommitted changes", status = status))
  list(ok = TRUE, reason = NA_character_, status = status)
}

# One sensitivity case (spec §5.9 as amended by the contract §11): list(data, spec, extra, skip, text). `extra` goes
# to fit_time_chain(extra = ); `skip` is NA or the fixed display the key reads instead of a fit. d is the primary
# window; d_fy2021 the "fy2021" window of read_hmis_model() (read when NULL and needed); fy2021 the result of
# fy2021_ready().
sens_case <- function(id, d, ind, d_fy2021 = NULL, fy2021 = fy2021_ready()) {
  if (!length(id) || !id %in% SENS_IDS) stop("sens_case: unknown sensitivity: ", paste(id, collapse = ", "), call. = FALSE)
  spec <- t_spec(ind)
  data <- d
  extra <- character()
  skip <- NA_character_
  switch(id,
    fy2021 = {
      if (!isTRUE(fy2021$ok)) {
        skip <- not_estimable(paste("FY2020-21", fy2021$reason))
      } else {
        if (is.null(d_fy2021)) d_fy2021 <- read_hmis_model("fy2021")
        if ("fy" %in% names(d_fy2021) && !any(as.character(d_fy2021$fy) == "2020-21")) {
          # the public release ships no FY2020-21 rows (final review, finding 2): never fit the case without them
          skip <- not_estimable("FY2020-21 rows not in the model table (the public release omits them; rebuild them from the portal)")
        } else {
          data <- d_fy2021[ym <= FY2021_END_YM]
          spec <- t_spec(ind, extra = c("covid_mar2020", "covid_fy2021"))
        }
      }
    },
    comp075 = spec <- .with_outcome(spec, paste0(ind, "_c75")),
    comp000 = spec <- .with_outcome(spec, paste0(ind, "_c00")),
    scaled = spec <- .with_outcome(spec, paste0(ind, "_scaled")),
    masklow = spec <- .with_outcome(spec, paste0(ind, "_masklow")),
    allcomp = if (ind %in% SINGLE_ITEM) skip <- ALLCOMP_NA else spec <- .with_outcome(spec, paste0(ind, "_allcomp")),
    births = {
      off <- if (ind == "anc_reg") "log_preg" else "log_births"
      if (!off %in% names(d) || !any(is.finite(d[[off]]))) {
        skip <- SRS_NOT_AVAILABLE
      } else if (ind %in% NO_BIRTHS_DENOMINATOR) {
        skip <- "not applicable (no births denominator for this outcome)"
      } else {
        spec <- t_spec(ind, offset = off)
      }
    },
    nosmall = data <- droplevels(d[!as.character(unit_id) %in% SMALL_UNITS]),
    era_int = extra <- "(1 | unit_era)",
    ns2 = {
      spec$fixed <- setdiff(spec$fixed, "t_c")
      extra <- ns2_term(complete_rows(d, spec_vars(spec))$data$t_c)
    },
    harmonic = extra <- c("unit_id:sin12", "unit_id:cos12"),
    extra_prog = spec <- t_spec(ind, extra = c(switch(ind, anc_reg = "pmsma", inst_del = "laqshya", NULL), "diwali")),
    drop_ep1415 = data <- d[!.in_window(ym, EP_WINDOWS$ep1415)],
    drop_ep1819 = data <- d[!.in_window(ym, EP_WINDOWS$ep1819)])
  list(id = id, data = data, spec = spec, extra = extra, skip = skip, text = SENS_TEXT[[id]])
}

# ---- fits through the time random-effect chain, with the block bootstrap as the last step -------------------------

# Columns named by `extra` terms (pi, T and other base objects are not columns).
.extra_columns <- function(extra) {
  v <- unique(unlist(lapply(extra, function(t) all.vars(str2lang(t)))))
  v[!vapply(v, exists, NA, envir = baseenv())]
}

# Columns the extra terms need that the spec does not carry. block_bootstrap_irr() keeps only the spec's columns
# (plus unit_id, ym, ym_f), so these ride along as "carrier" fixed entries that extra_fitter() strips again.
bootstrap_carriers <- function(spec, extra) setdiff(.extra_columns(extra), c(spec_vars(spec), "unit_id", "ym", "ym_f"))

# A fitter for fit_nb() / block_bootstrap_irr() that removes the carrier columns from the formula (spec_formula()
# writes them as " + c1 + c2" just before the offset) and appends `extra` (nb_fitter_with()). It is built in the
# global environment with extra, carriers and fit_fun inlined, so block_bootstrap_irr() ships it to PSOCK workers
# (which source monthly.R, not this file). The eval() only evaluates the function expression built here from the
# caller's own term strings (bquote), never external input.
extra_fitter <- function(extra, fit_fun = e_glmmTMB_fit, carriers = character()) {
  fit_fun <- e_fitter(fit_fun)                         # F61: the common default fitter gets the optimiser limits
  f <- bquote(function(formula, data, family = glmmTMB::nbinom2()) {
    carriers <- .(carriers)
    if (length(carriers)) {
      s <- deparse1(formula)
      cut <- paste0(" + ", paste(carriers, collapse = " + "), " + offset(")
      if (!grepl(cut, s, fixed = TRUE)) stop("extra_fitter: carrier terms not found in ", s, call. = FALSE)
      formula <- stats::as.formula(sub(cut, " + offset(", s, fixed = TRUE), env = environment(formula))
    }
    nb_fitter_with(.(extra), .(fit_fun))(formula, data, family = family)
  })
  eval(f, globalenv())
}

.sec_rows_na <- function(terms, status, error, B_ok = NA_integer_) {
  data.table::data.table(term = terms, est = NA_real_, se = NA_real_, irr = NA_real_, lo = NA_real_, hi = NA_real_,
                         p = NA_real_, p_kind = NA_character_, B_ok = as.integer(B_ok), time_re = NA_character_,
                         re_used = NA_character_, n = NA_integer_, n_units = NA_integer_, status = status,
                         error = error, pd_hess = NA, max_grad = NA_real_, notes = NA_character_)
}

# The fitter messages of a fit (e.g. glmmTMB "dropping columns from rank-deficient conditional model: ..."), as one
# string, NA when there are none (review finding 2: a dropped column leaves a trace in the rows and the log).
fit_notes <- function(fit) {
  m <- unique(trimws(as.character(fit$messages)))
  m <- m[nzchar(m)]
  if (length(m)) paste(m, collapse = "; ") else NA_character_
}

# Convergence diagnostics of a converged fit: positive-definite Hessian and the largest absolute gradient.
.fit_diag <- function(fit) list(pd_hess = isTRUE(fit$model$sdr$pdHess),
                                max_grad = max(abs(fit$model$sdr$gradient.fixed)))

.sec_rows_wald <- function(fit, terms, time_re) {
  r <- term_row(fit, terms)
  g <- .fit_diag(fit)
  data.table::data.table(term = terms, est = r$est, se = r$se, irr = r$irr, lo = r$lo, hi = r$hi, p = r$p,
                         p_kind = "wald", B_ok = NA_integer_, time_re = time_re, re_used = fit$re_used,
                         n = as.integer(fit$n), n_units = nlevels(fit$data$unit_id), status = "ok",
                         error = NA_character_, pd_hess = g$pd_hess, max_grad = g$max_grad, notes = fit_notes(fit))
}

.sec_rows_boot <- function(bb, terms) {
  data.table::data.table(term = terms, est = unname(bb$est[terms]), se = unname(bb$se[terms]),
                         irr = unname(bb$irr[terms]), lo = unname(bb$lo[terms]), hi = unname(bb$hi[terms]),
                         p = unname(bb$p[terms]), p_kind = "bootstrap", B_ok = as.integer(bb$B_ok),
                         time_re = "block_bootstrap", re_used = bb$re_used, n = as.integer(bb$n),
                         n_units = as.integer(bb$n_units), status = "ok", error = NA_character_,
                         pd_hess = if (is.null(bb$pd_hess)) NA else bb$pd_hess,
                         max_grad = if (is.null(bb$max_grad)) NA_real_ else bb$max_grad, notes = NA_character_)
}

# A Model T-type fit of `spec` (+ `extra`) through the chain ar1 -> iid. Returns a light record (no model object):
# status "ok" (rows; out = on_fit(fit) when given), "chain_failed" (neither step converged; t_chain_resolve() runs
# the block bootstrap) or "error" (another estimation failure; rows not estimable). Any error that is not an
# estimation failure is raised (F56).
t_chain_part <- function(spec, data, terms, extra = character(), fit_fun = e_glmmTMB_fit, on_fit = NULL) {
  rec <- list(spec = spec, terms = terms, extra = extra)
  catch_estimation_failure({
    f <- fit_time_chain(spec, data, extra = extra, fit_fun = fit_fun)
    c(rec, list(status = "ok", rows = .sec_rows_wald(f, terms, f$time_re),
                out = if (is.function(on_fit)) on_fit(f), time_errors = f$time_errors))
  }, function(e) {
    msg <- conditionMessage(e)
    chain <- grepl("next step: block_bootstrap", msg, fixed = TRUE)
    c(rec, list(status = if (chain) "chain_failed" else "error", error = first_line(msg), message = msg,
                rows = .sec_rows_na(terms, "error", first_line(msg)), out = NULL))
  })
}

# Resolve a t_chain_part() record: a converged chain as it is; a failed chain through the moving-block bootstrap
# (boot_fun, B refits without a time random effect, unit random effect fixed to the original rows' structure, F57;
# extra terms through extra_fitter() with carrier columns). out = on_boot(bootstrap result) when given. A bootstrap
# estimation failure (more than 10% of refits failed; the original-rows fit did not converge) gives not-estimable
# rows with B_ok when known; any other error is raised (F56).
t_chain_resolve <- function(part, data, B = 1000L, block = 12L, seed = SEED_E, cores = 1L, fit_fun = e_glmmTMB_fit,
                            boot_fun = block_bootstrap_irr, on_boot = NULL, label = "",
                            log_fun = function(...) elog(..., file = "secondary.log")) {
  if (!identical(part$status, "chain_failed")) return(part)
  carriers <- bootstrap_carriers(part$spec, part$extra)
  spec_b <- part$spec
  spec_b$fixed <- c(spec_b$fixed, carriers)
  ff <- if (length(part$extra)) extra_fitter(part$extra, fit_fun, carriers) else fit_fun
  log_fun(sprintf("%s: time random-effect chain failed (%s); block bootstrap, B = %d, %d cores", label, part$error,
                  as.integer(B), as.integer(cores)))
  catch_estimation_failure({
    bb <- boot_fun(spec_b, data, part$terms, B = B, block = block, seed = seed, cores = cores, fit_fun = ff,
                   progress = function(k, n) if (k == n || k %% 100L < max(1L, 4L * as.integer(cores)))
                     log_fun(sprintf("%s: block bootstrap %d of %d refits", label, as.integer(k), as.integer(n))))
    for (k in seq_along(bb$error_counts))
      log_fun(sprintf("%s: block bootstrap refit errors: %d x %s", label, as.integer(bb$error_counts[[k]]),
                      names(bb$error_counts)[k]))
    utils::modifyList(part, list(status = "ok", rows = .sec_rows_boot(bb, part$terms),
                                 out = if (is.function(on_boot)) on_boot(bb)))
  }, function(e) {
    log_fun(sprintf("%s: not estimable: %s", label, first_line(conditionMessage(e))))
    utils::modifyList(part, list(status = "error", error = first_line(conditionMessage(e)),
                                 rows = .sec_rows_na(part$terms, "error", first_line(conditionMessage(e)),
                                                     if (!is.null(e$B_ok)) e$B_ok else NA_integer_)))
  })
}

# ---- distributed lag (contract §10) --------------------------------------------------------------------------------

CB_TERMS <- c("en_cb1", "en_cb2", "en_cb3")

# Natural-spline lag basis: splines::ns(lags, df, intercept = TRUE), 7 x 3 for lags 0..6.
dlm_basis <- function(lags = 0:6, df = 3L) {
  b <- splines::ns(lags, df = df, intercept = TRUE)
  matrix(unclass(b)[, seq_len(df)], nrow = length(lags), ncol = df, dimnames = list(paste0("lag", lags), NULL))
}

# en_cb1..en_cb<k> = [en_t_l0 .. en_t_l<L>] %*% basis, from the table's merged lag columns (lag_merge, Task 5).
# Returns a copy of d.
cross_basis <- function(d, basis) {
  cols <- paste0("en_t_l", seq_len(nrow(basis)) - 1L)
  miss <- setdiff(cols, names(d))
  if (length(miss)) stop("cross_basis: missing lag column(s): ", paste(miss, collapse = ", "), call. = FALSE)
  cb <- as.matrix(d[, cols, with = FALSE]) %*% basis
  out <- data.table::copy(d)
  for (k in seq_len(ncol(basis))) data.table::set(out, j = paste0("en_cb", k), value = unname(cb[, k]))
  out
}

# Lag curve from coefficients and covariance: log IRR = basis %*% beta, Wald CI from basis %*% V %*% t(basis).
dlm_curve_from <- function(beta, V, basis) {
  eta <- as.vector(basis %*% beta)
  se <- unname(sqrt(pmax(diag(basis %*% V %*% t(basis)), 0)))
  data.table::data.table(lag = seq_len(nrow(basis)) - 1L, est = eta, se = se, irr = exp(eta),
                         lo = exp(eta - 1.959964 * se), hi = exp(eta + 1.959964 * se))
}

# The lag curve of a cross-basis fit: an nbfit (Wald, from its covariance) or a block_bootstrap_irr() result
# (point curve from the original-rows coefficients; percentile intervals of the resampled curves over the
# successful resamples; se = their SD). Columns lag, est, se, irr, lo, hi.
dlm_curve <- function(fit, basis) {
  if (inherits(fit, "nbfit")) {
    b <- glmmTMB::fixef(fit$model)$cond[CB_TERMS]
    if (anyNA(b)) stop("term_row: term(s) not in model: ", paste(CB_TERMS[is.na(b)], collapse = ", "), call. = FALSE)
    V <- as.matrix(stats::vcov(fit$model)$cond)[CB_TERMS, CB_TERMS]
    return(dlm_curve_from(b, V, basis))
  }
  betas <- fit$betas[, CB_TERMS, drop = FALSE]
  betas <- betas[stats::complete.cases(betas), , drop = FALSE]
  curves <- betas %*% t(basis)
  eta <- as.vector(basis %*% fit$est[CB_TERMS])
  q <- unname(apply(curves, 2, stats::quantile, c(0.025, 0.975), names = FALSE))
  data.table::data.table(lag = seq_len(nrow(basis)) - 1L, est = eta, se = unname(apply(curves, 2, stats::sd)),
                         irr = exp(eta), lo = exp(q[1, ]), hi = exp(q[2, ]))
}

dlm_inputs <- function(ind) list(spec = t_spec(ind, exposure = c(CB_TERMS, "ln_t")), extra = character(), terms = CB_TERMS)

# The distributed-lag Model T: en_t replaced by the cross-basis, ln_t at lag 0 (contract §10), the time
# random-effect chain as Model T. A t_chain_part() record whose `out` is the lag curve.
dlm_part <- function(d, ind, basis = dlm_basis(), fit_fun = e_glmmTMB_fit) {
  s <- dlm_inputs(ind)
  t_chain_part(s$spec, cross_basis(d, basis), s$terms, s$extra, fit_fun = fit_fun,
               on_fit = function(f) dlm_curve(f, basis))
}

# ---- IOD (contract §9; F14) ------------------------------------------------------------------------------------------

iod_inputs <- function(ind) list(spec = t_spec(ind, extra = "dmi_3m"), extra = "en_t:dmi_3m",
                                 terms = c("dmi_3m", "en_t:dmi_3m"))

# Model T plus dmi_3m and en_t:dmi_3m through the chain (irr_dmi, irr_int).
iod_fit <- function(d, ind, fit_fun = e_glmmTMB_fit) {
  s <- iod_inputs(ind)
  t_chain_part(s$spec, d, s$terms, s$extra, fit_fun = fit_fun)
}

# Months per ENSO-phase x IOD-sign combination: warm = ONI > 0, cool = ONI <= 0; pos = dmi_3m > 0, neg <= 0
# (contract §9). d: unit-month rows of the window (the exposures are national: one value per month).
iod_counts <- function(d) {
  m <- unique(data.table::as.data.table(d)[, .(ym, oni, dmi_3m)])
  if (anyDuplicated(m$ym)) stop("iod_counts: more than one ONI or dmi_3m value in a month", call. = FALSE)
  if (anyNA(m$oni) || anyNA(m$dmi_3m)) stop("iod_counts: missing ONI or dmi_3m", call. = FALSE)
  combo <- paste0(ifelse(m$oni > 0, "warm", "cool"), "_", ifelse(m$dmi_3m > 0, "pos", "neg"))
  lv <- c("warm_pos", "warm_neg", "cool_pos", "cool_neg")
  data.table::data.table(combo = lv, n_months = as.integer(table(factor(combo, levels = lv))))
}

# ---- state heterogeneity (contract §8; spec §5.5) -------------------------------------------------------------------

# The §5.5 rule: TRUE iff lrt_p < 0.05, the Hessian is positive definite, the SD's lower CI > 0.01 and both
# drop-episode refits have LRT p < 0.05. Any NA gives FALSE.
het_rule <- function(lrt_p, pd_hess, sd_lo, holds_1415, holds_1819)
  isTRUE(lrt_p < 0.05) && isTRUE(pd_hess) && isTRUE(sd_lo > 0.01) && isTRUE(holds_1415) && isTRUE(holds_1819)

# Wald CI of a unit random-slope SD on the log-SD scale: the theta parameter of `slope` in the unit_id term.
.slope_sd_ci <- function(m, slope) {
  rs <- m$modelInfo$reStruc$condReStruc
  ntheta <- vapply(rs, function(b) as.integer(b$blockNumTheta), 0L)
  k <- which(grepl("\\|\\s*unit_id$", names(rs)))
  if (length(k) != 1L) stop("het_test: no unique unit_id random-effect term", call. = FALSE)
  sds <- attr(glmmTMB::VarCorr(m)$cond$unit_id, "stddev")
  j <- match(slope, names(sds))
  if (is.na(j)) stop("het_test: no random slope on ", slope, call. = FALSE)
  pos <- sum(ntheta[seq_len(k - 1L)]) + j
  th <- which(names(m$sdr$par.fixed) == "theta")[pos]
  logsd <- unname(m$sdr$par.fixed[th])
  if (abs(exp(logsd) - sds[[j]]) > 1e-6 * max(1, sds[[j]])) stop("het_test: theta index does not match the SD", call. = FALSE)
  se <- sqrt(m$sdr$cov.fixed[th, th])                 # NaN when the variance is not finite: CI not estimable
  if (!is.finite(se)) se <- NA_real_
  c(sd = exp(logsd), lo = exp(logsd - 1.959964 * se), hi = exp(logsd + 1.959964 * se))
}

.ntheta <- function(m) sum(names(m$fit$par) == "theta")

# One LRT of the unit en_t random slope against none, with time random effect `time_re` (fixed, no chain). The null
# is Model T (unit RE chain us -> diag -> int); the alternative adds en_t to the null's unit slopes with the same
# structure (an "int" null gets (1 + en_t | unit_id)); if the alternative only converges with a simpler structure
# the null is refitted with that structure so the two are nested. Raises an estimation failure (fit_nb) or a
# "het_test: ..." error when the en_t slope cannot be fitted.
.het_lrt <- function(d, ind, time_re, fit_fun) {
  fitter <- nb_fitter_with(TIME_RE[[time_re]], fit_fun)
  null_spec <- t_spec(ind)
  f0 <- fit_nb(null_spec, d, fitter = fitter)
  r0 <- f0$re_used
  alt_spec <- null_spec
  alt_spec$slopes <- if (r0 == "int") "en_t" else c("t_c", "en_t")
  alt_spec$re <- if (r0 == "int") "us" else r0
  f1 <- fit_nb(alt_spec, d, fitter = fitter)
  if (f1$re_used == "int") stop("het_test: the en_t random slope did not converge (fell back to int)", call. = FALSE)
  if (r0 != "int" && f1$re_used != r0) {
    null_spec$re <- f1$re_used
    f0 <- fit_nb(null_spec, d, fitter = fitter)
    if (f0$re_used != f1$re_used)
      stop("het_test: no nested null model with unit random effect ", f1$re_used, call. = FALSE)
  }
  if (f0$n != f1$n) stop("het_test: null and alternative fits use different rows", call. = FALSE)
  stat <- 2 * (as.numeric(stats::logLik(f1$model)) - as.numeric(stats::logLik(f0$model)))
  df <- .ntheta(f1$model) - .ntheta(f0$model)
  list(f0 = f0, f1 = f1, stat = stat, df = as.integer(df), p = stats::pchisq(max(stat, 0), df, lower.tail = FALSE))
}

# Heterogeneity test (contract §8): Model T with slopes c("t_c", "en_t") against the primary Model T by LRT, both
# with the time random-effect step the primary fit used (time_re: "ar1" or "iid"; under "block_bootstrap" nothing is
# fitted and error reads "no converged time random effect"). Returns list(lrt_p, df, stat, slope_sd, sd_lo, sd_hi
# (Wald CI on the log-SD scale), pd_hess, holds_1415, holds_1819 (the LRT p < 0.05 when that episode window is
# dropped; FALSE if the refit is not estimable), lrt_p_1415, lrt_p_1819, drop_errors, re_null, re_alt, n, n_units,
# modes (unit_id, mode, sd: conditional modes of the en_t slope; for Figure S1 only), error (NA if estimated)).
het_test <- function(d, ind, time_re = "ar1", fit_fun = e_glmmTMB_fit, drop_episodes = TRUE) {
  out <- list(lrt_p = NA_real_, df = NA_integer_, stat = NA_real_, slope_sd = NA_real_, sd_lo = NA_real_,
              sd_hi = NA_real_, pd_hess = NA, holds_1415 = NA, holds_1819 = NA, lrt_p_1415 = NA_real_,
              lrt_p_1819 = NA_real_, drop_errors = c(ep1415 = NA_character_, ep1819 = NA_character_),
              re_null = NA_character_, re_alt = NA_character_, n = NA_integer_, n_units = NA_integer_, modes = NULL,
              error = NA_character_, time_re = time_re, max_grad = NA_real_, notes = NA_character_)
  if (!time_re %in% names(TIME_RE)) {
    out$error <- "no converged time random effect"
    return(out)
  }
  het_fail <- function(e) is_estimation_failure(e) || startsWith(first_line(conditionMessage(e)), "het_test: ")
  # the slope-SD interval is computed inside the same guard: its "het_test: ..." failures are not estimable too
  r <- tryCatch({
    r <- .het_lrt(d, ind, time_re, fit_fun)
    r$ci <- .slope_sd_ci(r$f1$model, "en_t")
    r
  }, error = function(e) if (het_fail(e)) e else stop(e))
  if (inherits(r, "error")) {
    out$error <- first_line(conditionMessage(r))
    return(out)
  }
  ci <- r$ci
  re <- as.data.frame(glmmTMB::ranef(r$f1$model, condVar = TRUE))
  re <- re[re$component == "cond" & re$grpvar == "unit_id" & re$term == "en_t", ]
  out <- utils::modifyList(out, list(lrt_p = r$p, df = r$df, stat = r$stat, slope_sd = unname(ci[["sd"]]),
                                     sd_lo = unname(ci[["lo"]]), sd_hi = unname(ci[["hi"]]),
                                     pd_hess = isTRUE(r$f1$model$sdr$pdHess), re_null = r$f0$re_used,
                                     re_alt = r$f1$re_used, n = as.integer(r$f1$n),
                                     n_units = nlevels(r$f1$data$unit_id), max_grad = .fit_diag(r$f1)$max_grad,
                                     notes = paste(stats::na.omit(c(fit_notes(r$f0), fit_notes(r$f1))),
                                                   collapse = "; ")))
  out$modes <- data.table::data.table(unit_id = as.character(re$grp), mode = re$condval, sd = re$condsd)
  if (drop_episodes) {
    for (ep in names(EP_WINDOWS)) {
      rr <- tryCatch(.het_lrt(d[!.in_window(ym, EP_WINDOWS[[ep]])], ind, time_re, fit_fun),
                     error = function(e) if (het_fail(e)) e else stop(e))
      short <- sub("^ep", "", ep)
      if (inherits(rr, "error")) {
        out$drop_errors[[ep]] <- first_line(conditionMessage(rr))
        out[[paste0("holds_", short)]] <- FALSE
      } else {
        out[[paste0("lrt_p_", short)]] <- rr$p
        out[[paste0("holds_", short)]] <- rr$p < 0.05
      }
    }
  }
  out
}

# ---- Model L secondary analyses (contract §5 cum02 and tmax) --------------------------------------------------------

L_VARS <- c(hw = "heatwave_days", dry = "spi3_dry", wet = "spi3_wet")

l_lags_spec <- function(ind)
  nb_spec(ind, fixed = c(paste0(rep(c("spi3_dry", "spi3_wet", "heatwave_days"), each = 3L), "_l", 0:2), "ym_f"),
          slopes = "t_c", offset = "log_pop_days", trend_df = 0L)

# Model L with tmax_anom_l0 in place of heatwave_days_l0; the two are never entered together.
l_tmax_spec <- function(ind)
  nb_spec(ind, fixed = c("spi3_dry_l0", "spi3_wet_l0", "tmax_anom_l0", "ym_f"), slopes = "t_c",
          offset = "log_pop_days", trend_df = 0L)

# Sum of the coefficients `terms` with its SE from the covariance: list(est, se, p) (two-sided Wald).
lin_comb <- function(est, V, terms) {
  w <- stats::setNames(rep(1, length(terms)), terms)
  s <- sum(est[terms])
  se <- sqrt(as.numeric(t(w) %*% V[terms, terms, drop = FALSE] %*% w))
  list(est = s, se = se, p = 2 * stats::pnorm(-abs(s / se)))
}

# Spec §4 secondary lag: Model L with each local-climate term at lags 0, 1 and 2 entered together (one fit,
# year-month fixed effects, no time random effect). term hw / dry / wet: est = the sum of the three lag
# coefficients, se from their covariance, irr = exp(sum) with its Wald CI, in the coefficient's own orientation
# (the exp(-sum) display of dry is applied in the keys).
model_l_lags <- function(d, ind, fit_fun = e_glmmTMB_fit) {
  f <- fit_nb(l_lags_spec(ind), d, fitter = e_fitter(fit_fun))           # F61 optimiser limits
  b <- glmmTMB::fixef(f$model)$cond
  V <- as.matrix(stats::vcov(f$model)$cond)
  data.table::rbindlist(lapply(names(L_VARS), function(k) {
    terms <- paste0(L_VARS[[k]], "_l", 0:2)
    if (anyNA(b[terms])) stop("term_row: term(s) not in model: ", paste(terms[is.na(b[terms])], collapse = ", "),
                              call. = FALSE)
    s <- lin_comb(b, V, terms)
    data.table::data.table(term = k, est = s$est, se = s$se, irr = exp(s$est), lo = exp(s$est - 1.959964 * s$se),
                           hi = exp(s$est + 1.959964 * s$se), p = s$p, re_used = f$re_used, n = as.integer(f$n),
                           n_units = nlevels(f$data$unit_id), pd_hess = .fit_diag(f)$pd_hess,
                           max_grad = .fit_diag(f)$max_grad, notes = fit_notes(f))
  }))
}

# The Tmax-anomaly sensitivity of Model L: the tmax_anom_l0 row (IRR per +1 deg C).
model_l_tmax <- function(d, ind, fit_fun = e_glmmTMB_fit) {
  f <- fit_nb(l_tmax_spec(ind), d, fitter = e_fitter(fit_fun))           # F61 optimiser limits
  r <- term_row(f, "tmax_anom_l0")
  data.table::data.table(term = "tmax_anom_l0", est = r$est, se = r$se, irr = r$irr, lo = r$lo, hi = r$hi, p = r$p,
                         re_used = f$re_used, n = as.integer(f$n), n_units = nlevels(f$data$unit_id),
                         pd_hess = .fit_diag(f)$pd_hess, max_grad = .fit_diag(f)$max_grad, notes = fit_notes(f))
}

# ---- F62: descriptive BFGS-optimiser sensitivity (opd Models S and L) -----------------------------------------------

BFGS_NOTE <- "sensitivity; no verdict; not in the Holm family"
BFGS_OUTCOMES <- "opd"           # F62: the outcome whose primary Models S and L are not estimable

# glmmTMB with optim(method = "BFGS") in place of nlminb (F62) and a raised iteration limit (the F61 analogue for
# optim, maxit 10,000; nlminb's iter.max/eval.max do not apply to optim). Top level, so it ships to PSOCK workers.
e_bfgs_fit <- function(formula, data, family = glmmTMB::nbinom2()) {
  glmmTMB::glmmTMB(formula, data = data, family = family,
                   control = glmmTMB::glmmTMBControl(optimizer = stats::optim, optArgs = list(method = "BFGS"),
                                                     optCtrl = list(maxit = 1e4)))
}

# Model S or Model L of the primary analysis (s_spec() / l_spec(), 02_primary.R; Model S on the rows with S_z),
# refitted with the BFGS optimiser (F62): rows for S_TERMS or L_TERMS in coefficient orientation with pd_hess,
# max_grad and notes. An estimation failure is raised (the caller records it as not estimable, F56).
model_sl_bfgs <- function(d, ind, model = c("S", "L"), fit_fun = e_bfgs_fit) {
  model <- match.arg(model)
  spec <- if (model == "S") s_spec(ind) else l_spec(ind)
  terms <- if (model == "S") S_TERMS else L_TERMS
  if (model == "S") d <- d[!is.na(S_z)]
  .sec_rows_wald(fit_nb(spec, d, fitter = fit_fun), terms, NA_character_)
}
