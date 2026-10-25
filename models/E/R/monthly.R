# Paper E monthly model helpers (Task 7). They extend the frozen common annual helpers without editing them:
# fit_nb() is called unchanged with a formula-augmenting fitter (nb_fitter_with) that appends the time random
# effect and any expression terms, so the unit random-effect fallback us -> diag -> int, the NA rule
# (complete_rows) and the convergence check are the common ones. Sourced after common/R/load.R and common_e.R.

# The time random-effect chain (contract "The time random-effect chain"): AR(1) year-month effect, then an iid
# year-month effect; the moving-block bootstrap (block_bootstrap_irr(), Task 8) is the last step.
TIME_RE <- c(ar1 = "ar1(ym_f + 0 | national)", iid = "(1 | ym_f)")

# Optimiser limits for every Paper E glmmTMB fit (ruling F61; contract amendment 3): nlminb iter.max and eval.max
# 10,000 instead of glmmTMB's defaults (300 / 400), which Models S and L (95 year-month fixed effects) exhausted.
# e_glmmTMB_fit() is the common glmmTMB_fit() with this control; e_fitter() substitutes it wherever the common default
# fitter is passed, so every Paper E path through nb_fitter_with(), fit_time_chain(), block_bootstrap_irr() and the
# primary and mediation fits inherits it (an injected test fitter is used as it is). models/common/R is unchanged.
E_OPT_CTRL <- list(iter.max = 1e4, eval.max = 1e4)
e_glmmTMB_fit <- function(formula, data, family = glmmTMB::nbinom2()) {
  glmmTMB::glmmTMB(formula, data = data, family = family,
                   control = glmmTMB::glmmTMBControl(optCtrl = list(iter.max = 1e4, eval.max = 1e4)))
}
e_fitter <- function(fit_fun) if (identical(fit_fun, glmmTMB_fit)) e_glmmTMB_fit else fit_fun

# A fitter for fit_nb(): appends `extra_terms` (random-effect terms or fixed-effect expressions such as
# "splines::ns(t_c, df = 2)" or "unit_id:sin12", which must never go into nb_spec(fixed = ), because
# complete_rows() treats every fixed entry as a column name) to the formula of every non-Gaussian fit, then calls
# fit_fun(formula, data, family = family). A Gaussian family (mediate()'s a-path) gets the formula unchanged.
# The returned function references no Paper E helper, so it ships to PSOCK workers as it is.
nb_fitter_with <- function(extra_terms, fit_fun = e_glmmTMB_fit) {
  extra_terms <- as.character(extra_terms)
  fit_fun <- e_fitter(fit_fun)
  function(formula, data, family = glmmTMB::nbinom2()) {
    if (length(extra_terms) && !identical(family$family, "gaussian"))
      formula <- stats::as.formula(paste(deparse1(formula), "+", paste(extra_terms, collapse = " + ")),
                                   env = environment(formula))
    fit_fun(formula, data, family = family)
  }
}

# Programme indicators of the primary models (spec §5.1; ruling F45): the HMIS format-2017 step and
# demonetisation for every outcome, Mission Indradhanush round months for the immunisation outcomes only.
# pmsma, laqshya and diwali enter only the extra_prog sensitivity, covid_* only the fy2021 sensitivity (`extra`).
programme_terms <- function(outcome) {
  c("hmis_format2017", "demonet", if (outcome %in% c("penta3", "mcv1", "fic")) "mi_round")
}

# Model T (spec §5.2): <outcome> ~ <exposure> + moy + t_c + <programme terms> + <extra> + offset(log_pop_days)
# + (1 + t_c | unit_id); the time random effect is added by the fitter (fit_time_chain). No spline trend.
t_spec <- function(outcome, exposure = c("en_t", "ln_t"), extra = character(), offset = "log_pop_days") {
  nb_spec(outcome, fixed = c(exposure, "moy", "t_c", programme_terms(outcome), extra), slopes = "t_c",
          offset = offset, trend_df = 0L, re = "us")
}

# Fit `spec` with each time random effect of `chain` in turn (fit_nb with nb_fitter_with(c(TIME_RE[[k]], extra),
# fit_fun); fit_fun is used at every step and is injectable for tests). Returns the first fit that converges, with
# $time_re (the step used), $time_attempts and $time_errors (the error of each failed step). Only fit_nb's
# non-convergence error ("fit_nb: no structure converged ...") moves the chain to its next step; any other error
# (a missing column, an `extra` expression that does not parse or names a missing column) is raised as it is.
# If no step converges it stops with a message naming block_bootstrap, the next step of the chain (Task 8), and
# each step's error.
fit_time_chain <- function(spec, data, chain = c("ar1", "iid"), extra = character(), fit_fun = e_glmmTMB_fit) {
  bad <- setdiff(chain, names(TIME_RE))
  if (!length(chain) || length(bad))
    stop("fit_time_chain: unknown time random effect: ", paste(bad, collapse = ", "), call. = FALSE)
  # fail fast, before any fit, on terms the fitter would otherwise turn into a non-convergence
  for (term in c(TIME_RE[chain], extra)) {
    expr <- tryCatch(str2lang(term), error = function(e)
      stop(sprintf("fit_time_chain: term does not parse: %s (%s)", term, conditionMessage(e)), call. = FALSE))
    vars <- all.vars(expr)
    absent <- setdiff(vars[!vapply(vars, exists, NA, envir = baseenv())], names(data))   # pi, T, ... are not columns
    if (length(absent))
      stop(sprintf("fit_time_chain: missing column(s) in term %s: %s", term, paste(absent, collapse = ", ")),
           call. = FALSE)
  }
  tried <- character()
  errs <- character()
  for (k in chain) {
    tried <- c(tried, k)
    f <- tryCatch(fit_nb(spec, data, fitter = nb_fitter_with(c(TIME_RE[[k]], extra), fit_fun)),
                  error = function(e) e)
    if (!inherits(f, "error")) {
      f$time_re <- k
      f$time_attempts <- tried
      f$time_errors <- errs
      return(f)
    }
    if (!startsWith(conditionMessage(f), "fit_nb: no structure converged")) stop(f)
    errs <- c(errs, sprintf("%s: %s", k, conditionMessage(f)))
  }
  stop(sprintf("fit_time_chain: no time random effect converged for %s (tried %s); next step: block_bootstrap. %s",
               spec$outcome, paste(tried, collapse = ", "), paste(errs, collapse = "; ")), call. = FALSE)
}

# Wald row(s) for conditional-model term(s): log-scale estimate and SE, IRR with 95% CI, two-sided p.
term_row <- function(fit, term) {
  co <- summary(fit$model)$coefficients$cond
  absent <- setdiff(term, rownames(co))
  if (length(absent)) stop("term_row: term(s) not in model: ", paste(absent, collapse = ", "), call. = FALSE)
  est <- unname(co[term, 1])
  se <- unname(co[term, 2])
  data.table::data.table(term = term, est = est, se = se, irr = exp(est), lo = exp(est - 1.959964 * se),
                         hi = exp(est + 1.959964 * se), p = unname(co[term, 4]))
}

# ---- The moving-block bootstrap over months (Task 8; contract "The time random-effect chain", last step) --------

# Month-block resample of a unit-month panel: draw ceiling(M / block) start positions uniformly from
# 1..(M - block + 1) over the sorted unique `ym` (M months), concatenate the blocks (every unit's rows of each drawn
# month) and truncate to M months. The year-month factor ym_f is relabelled "<ym>_<k>", k = the block's draw index
# (1..ceiling(M / block)), so a month drawn in two blocks gives two distinct levels; its levels are in drawn order.
# Units and every covariate keep their original values. seed is applied locally (the caller's RNG is restored).
block_resample <- function(d, block = 12L, seed = NULL) {
  d <- data.table::as.data.table(d)
  block <- as.integer(block)
  yms <- sort(unique(d$ym))
  M <- length(yms)
  if (is.na(block) || block < 1L || block > M)
    stop(sprintf("block_resample: block must lie in 1..%d (the number of months)", M), call. = FALSE)
  nb <- as.integer(ceiling(M / block))
  starts <- .with_seed(seed, sample.int(M - block + 1L, nb, replace = TRUE))
  pos <- data.table::data.table(ym = yms[as.vector(outer(0:(block - 1L), starts, "+"))],
                                k = rep(seq_len(nb), each = block))[seq_len(M)]
  pos[, lab := paste0(ym, "_", k)]
  rows <- split(seq_len(nrow(d)), d$ym)[as.character(pos$ym)]
  out <- d[unlist(rows, use.names = FALSE)]
  out[, ym_f := factor(rep(pos$lab, lengths(rows)), levels = pos$lab)]
  out[]
}

# Percentile 95% interval (common .pct) and the two-sided bootstrap p, 2 x min(share <= 0, share >= 0), of the
# resampled coefficients `betas` (successful resamples only).
.boot_summary <- function(betas) {
  ci <- .pct(betas)
  list(lo = ci[1], hi = ci[2], p = min(1, 2 * min(mean(betas <= 0), mean(betas >= 0))))
}

# One fit of `spec` with the unit random-effect structure `re` FIXED (no us -> diag -> int fallback; ruling F57), on
# complete rows, without a time random effect. Errors unless the fit converges (the common .converged() check);
# fitter messages are muffled.
.e_fit_fixed_re <- function(spec, d, re, fitter) {
  m <- tryCatch(withCallingHandlers(suppressWarnings(fitter(spec_formula(spec, re), d)),
                                    message = function(c) invokeRestart("muffleMessage")),
                error = function(e) e)
  if (inherits(m, "error")) stop("unit random effect ", re, ": ", conditionMessage(m), call. = FALSE)
  if (!.converged(m)) stop("unit random effect ", re, " did not converge", call. = FALSE)
  m
}

# One bootstrap resample: month-block resample i (seed + i - 1), refit `spec` WITHOUT a time random effect and with
# the unit random-effect structure selected on the original rows (st$re, fixed: F57); return the coefficients of
# `term` or the error. Top level, so PSOCK workers resolve it from their own sourced copy.
.e_boot_one <- function(i, st) {
  di <- block_resample(st$d, st$block, seed = st$seed + i - 1L)
  r <- tryCatch({
    m <- .e_fit_fixed_re(st$spec, di, st$re, st$fit_fun)
    b <- glmmTMB::fixef(m)$cond[st$term]
    if (anyNA(b)) stop("term(s) unidentified (NA): ", paste(st$term[is.na(b)], collapse = ", "))
    unname(b)
  }, error = function(e) e)
  if (inherits(r, "error")) return(list(i = as.integer(i), beta = rep(NA_real_, length(st$term)), error = conditionMessage(r)))
  list(i = as.integer(i), beta = r, error = NA_character_)
}

.e_boot_set <- function(st) {
  assign(".E_BOOT_STATE", st, envir = globalenv())
  invisible(NULL)
}

.e_boot_task <- function(i) .e_boot_one(i, get(".E_BOOT_STATE", envir = globalenv()))

# The last step of the time random-effect chain: the model refitted without a time random effect on B month-block
# resamples (resample i uses seed + i - 1). `term` may be several terms (e.g. en_t and ln_t). Returns
# list(term, est (the coefficients of the fit on the original rows), se (bootstrap SD of the coefficients), irr =
# exp(est), lo, hi (exp of the percentile interval), p (two-sided bootstrap p), B, B_ok, B_failed, re_used, n,
# n_units (of the fit on the original rows), betas (B x term matrix, NA for a failed resample), errors (distinct
# failure messages)); est/se/irr/lo/hi/p are named by term. Every resample is refitted with the unit random-effect
# structure the original rows selected (fit_nb's us -> diag -> int chain), with no fallback; a resample that does not
# converge with it fails (F57). Stops if the fit on the original rows fails, and, when more than 10% of the B refits
# fail, with the condition "block bootstrap: more than 10% of refits failed (most common error, k of B refits:
# <first line>)" (class e_boot_too_many_failed, fields B_ok, B, errors, error_counts). error_counts: the failed
# refits' distinct first lines with their counts, most common first (also returned on success). cores > 1 uses a PSOCK cluster (.e_cluster(), power.R, must be sourced); fit_fun must then be
# a top-level function. The rows are complete_rows() of the spec's variables, so every resample is complete.
block_bootstrap_irr <- function(spec, d, term, B = 1000L, block = 12L, seed = SEED_E, cores = 1L,
                                fit_fun = e_glmmTMB_fit, progress = NULL) {
  fit_fun <- e_fitter(fit_fun)
  B <- as.integer(B); cores <- as.integer(cores); seed <- as.integer(seed)
  if (is.na(B) || B < 1L) stop("block_bootstrap_irr: B must be a positive integer", call. = FALSE)
  if (is.na(cores) || cores < 1L) stop("block_bootstrap_irr: cores must be a positive integer", call. = FALSE)
  vars <- unique(c(spec_vars(spec), "unit_id", "ym", "ym_f"))
  cr <- complete_rows(data.table::as.data.table(d), vars)
  d0 <- droplevels(cr$data[, vars, with = FALSE])
  f0 <- fit_nb(spec, d0, fitter = fit_fun)
  est <- glmmTMB::fixef(f0$model)$cond[term]
  if (anyNA(est)) stop("block_bootstrap_irr: term(s) not estimated on the original rows: ",
                       paste(term[is.na(est)], collapse = ", "), call. = FALSE)
  st <- list(spec = spec, d = d0, term = term, block = as.integer(block), seed = seed, fit_fun = fit_fun,
             re = f0$re_used)
  if (cores > 1L) {
    fe <- environment(fit_fun)
    if (!is.null(fe) && !identical(fe, globalenv()) && !isNamespace(fe))
      stop("block_bootstrap_irr: with cores > 1 fit_fun must be a top-level function, not a closure", call. = FALSE)
    if (!exists(".e_cluster", mode = "function"))
      stop("block_bootstrap_irr: cores > 1 needs .e_cluster() (source models/E/R/power.R)", call. = FALSE)
    cl <- .e_cluster(cores)
    on.exit(parallel::stopCluster(cl), add = TRUE)
    parallel::clusterCall(cl, .e_boot_set, st)
  }
  chunk <- if (cores > 1L) 4L * cores else 25L
  res <- vector("list", B)
  for (s in seq(1L, B, by = chunk)) {
    idx <- s:min(B, s + chunk - 1L)
    res[idx] <- if (cores > 1L) parallel::clusterApplyLB(cl, idx, .e_boot_task) else lapply(idx, .e_boot_one, st = st)
    if (is.function(progress)) progress(max(idx), B)
  }
  betas <- do.call(rbind, lapply(res, `[[`, "beta"))
  colnames(betas) <- term
  errs <- vapply(res, `[[`, "", "error")
  ok <- is.na(errs) & apply(is.finite(betas), 1, all)
  fail <- !ok
  emsg <- ifelse(is.na(errs), "non-finite coefficient", trimws(sub("[\r\n].*$", "", errs)))[fail]
  error_counts <- if (any(fail)) sort(table(emsg), decreasing = TRUE) else integer()
  error_counts <- stats::setNames(as.integer(error_counts), names(error_counts))
  if (B - sum(ok) > 0.1 * B)
    stop(errorCondition(sprintf("block bootstrap: more than 10%% of refits failed (most common error, %d of %d refits: %s)",
                                error_counts[[1]], B, names(error_counts)[1]),
                        class = "e_boot_too_many_failed", B_ok = as.integer(sum(ok)), B = B,
                        errors = unique(errs[!is.na(errs)]), error_counts = error_counts,
       pd_hess = isTRUE(f0$model$sdr$pdHess), max_grad = max(abs(f0$model$sdr$gradient.fixed))))
  sm <- lapply(term, function(k) .boot_summary(betas[ok, k]))
  nm <- function(x) stats::setNames(x, term)
  list(term = term, est = nm(unname(est)), se = nm(apply(betas[ok, , drop = FALSE], 2, stats::sd)),
       irr = nm(exp(unname(est))), lo = nm(exp(vapply(sm, `[[`, 0, "lo"))), hi = nm(exp(vapply(sm, `[[`, 0, "hi"))),
       p = nm(vapply(sm, `[[`, 0, "p")), B = B, B_ok = as.integer(sum(ok)), B_failed = as.integer(B - sum(ok)),
       re_used = f0$re_used, n = f0$n, n_units = nlevels(f0$data$unit_id), betas = betas,
       errors = unique(errs[!is.na(errs)]), error_counts = error_counts,
       pd_hess = isTRUE(f0$model$sdr$pdHess), max_grad = max(abs(f0$model$sdr$gradient.fixed)))
}
