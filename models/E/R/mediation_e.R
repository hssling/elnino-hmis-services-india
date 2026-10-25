# Paper E Task 8: the local-climate-mediated share (contract papers/E/results_keys.md §6 and the mediation rule;
# spec §5.4 with §10.4; ruling F48). Sourced after common/R/load.R, common_e.R, monthly.R (and power.R for
# cores > 1). models/common/R is frozen: mediate_m() reuses the common helpers unchanged (.a_path_formula,
# .fit_a_path, .coef_or_stop, .prop_ci, .pct, bootstrap_units, fit_nb, nb_spec).
#
#   a-paths (Gaussian LMM), one per mediator k:  mediator_k ~ en_t + covars + (1 | unit_id)
#   b-path  (NB2 GLMM):  Model T plus the three mediators:  <ind> ~ en_t + mediators + covars + offset(log_pop_days)
#                        + (1 + t_c | unit_id) + (1 | ym_f)
#   total   (NB2 GLMM):  Model T:  <ind> ~ en_t + covars + offset(log_pop_days) + (1 + t_c | unit_id) + (1 | ym_f)
# covars are the Model T fixed effects other than en_t (ln_t, moy, t_c and the programme terms): F48, a deliberate
# deviation from spec §5.4 (month-of-year and a unit random effect only), so that a·b is coherent with the total and
# direct models. The NB fits carry the iid year-month random effect (extra_terms, through nb_fitter_with(); the
# Gaussian a-paths get the formula unchanged). All paths on the same complete rows.
# indirect = Σ_k a_k·b_k (log-rate per +1 °C en_t); prop_mediated = indirect / c_total.
# Resampling: "month_block" (primary; block_resample(), block 12) or "unit" (the §10.4 sensitivity, common
# bootstrap_units()); resample i uses seed + i - 1. CIs are percentiles over the successful resamples; the >10%
# failed-refit rule (flag "too_many_failed_fits", every CI NA, prop_flag "not_assessed") and prop_flag
# (.prop_ci(): "total_effect_ci_includes_0", "opposite_signs", "nonfinite_resample_proportion", "ok") are those of
# common mediate().

if (!exists("not_estimable")) source(file.path(MODELS_ROOT, "E", "R", "verdicts.R"))

MED_MEDIATORS <- c("spi3_dry_l0", "spi3_wet_l0", "heatwave_days_l0")
MED_SCRIPT <- "models/E/03_mediation.R"
MED_NOT_ESTIMATED <- "not estimated (no total association)"
MED_SLOWDOWN <- 1.6          # parallel slowdown per refit, measured in the Task 7 power run (01_power.R)

# The mediation rule: the Model T en_t 95% CI excludes 1.
med_eligible <- function(lo, hi) !is.na(lo) & !is.na(hi) & (hi < 1 | lo > 1)

# Hours for n_runs bootstrap runs of B resamples each, from the one-core seconds per resample.
med_projection_hours <- function(secs_per_resample, B, n_runs, cores, slowdown = MED_SLOWDOWN)
  secs_per_resample * B * n_runs * slowdown / cores / 3600

# B = 500, or 200 when the projected run time exceeds the budget (24 h; contract §6).
med_choose_B <- function(secs_per_resample, n_runs, cores, budget_hours = 24, B = 500L, B_reduced = 200L,
                         slowdown = MED_SLOWDOWN) {
  if (med_projection_hours(secs_per_resample, B, n_runs, cores, slowdown) > budget_hours) as.integer(B_reduced)
  else as.integer(B)
}

# The a-, b- and total-path fits on d (complete rows). Errors (never returns) when a fit fails or a coefficient is
# unidentified.
.med_fits <- function(d, outcome, exposure, mediators, covars, offset, slopes, fitter) {
  a_n <- integer()
  a <- vapply(mediators, function(m) {
    fa <- .fit_a_path(.a_path_formula(m, exposure, covars, 0L), d, fitter)
    a_n[[m]] <<- as.integer(stats::nobs(fa$model))
    .coef_or_stop(fa$model, exposure, "a-path")
  }, 0)
  sp <- function(fixed) nb_spec(outcome, fixed = fixed, slopes = slopes, offset = offset, trend_df = 0L, re = "us")
  fb <- fit_nb(sp(c(exposure, mediators, covars)), d, fitter = fitter)
  ft <- fit_nb(sp(c(exposure, covars)), d, fitter = fitter)
  list(a = a, b = vapply(mediators, function(m) .coef_or_stop(fb$model, m, "b-path"), 0),
       c_direct = .coef_or_stop(fb$model, exposure, "b-path"),
       c_total = .coef_or_stop(ft$model, exposure, "total-effect"),
       n_by_model = c(a_n, b = as.integer(fb$n), total = as.integer(ft$n)),
       re_used = c(b = fb$re_used, total = ft$re_used))
}

# One bootstrap resample (top level, so PSOCK workers resolve it from their sourced copy).
.e_med_one <- function(i, st) {
  t0 <- Sys.time()
  di <- if (st$resample == "month_block") block_resample(st$d, st$block, seed = st$seed + i - 1L)
        else bootstrap_units(st$d, seed = st$seed + i - 1L)
  r <- tryCatch(.med_fits(di, st$outcome, st$exposure, st$mediators, st$covars, st$offset, st$slopes,
                          nb_fitter_with(st$extra_terms, st$fit_fun)), error = function(e) e)
  k <- length(st$mediators)
  out <- if (inherits(r, "error"))
    list(i = as.integer(i), a = rep(NA_real_, k), b = rep(NA_real_, k), c_direct = NA_real_, c_total = NA_real_,
         error = conditionMessage(r))
  else list(i = as.integer(i), a = unname(r$a), b = unname(r$b), c_direct = r$c_direct, c_total = r$c_total,
            error = NA_character_)
  out$secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  out
}

.e_med_task <- function(i) .e_med_one(i, get(".E_MED_STATE", envir = globalenv()))

.e_med_init <- function(root) {
  loadNamespace("data.table")       # the shipped panel must index as a data.table
  source(file.path(root, "E", "R", "mediation_e.R"))
  invisible(TRUE)
}

.e_med_set <- function(st) {
  assign(".E_MED_STATE", st, envir = globalenv())
  invisible(NULL)
}

mediate_m <- function(data, outcome, exposure = "en_t", mediators = MED_MEDIATORS, covars, offset = "log_pop_days",
                      slopes = "t_c", extra_terms = TIME_RE[["iid"]], resample = c("month_block", "unit"), B = 500L,
                      block = 12L, seed = SEED_E, cores = 1L, fit_fun = e_glmmTMB_fit, progress = NULL) {
  resample <- match.arg(resample)
  # cores: a positive integer, or a function returning one, re-evaluated before every chunk of resamples; when it
  # rises (the shared machine frees cores), the PSOCK cluster is rebuilt larger. Resample i always uses seed + i - 1,
  # so the result does not depend on the cores used.
  cores_fun <- if (is.function(cores)) cores else { force(cores); function() cores }
  B <- as.integer(B); seed <- as.integer(seed)
  if (length(B) != 1L || is.na(B) || B < 1L) stop("mediate_m: B must be a positive integer", call. = FALSE)
  .check_cores <- function(n) {
    n <- as.integer(n)
    if (length(n) != 1L || is.na(n) || n < 1L) stop("mediate_m: cores must be a positive integer", call. = FALSE)
    n
  }
  cur <- .check_cores(cores_fun())
  if (is.function(cores) || cur > 1L) {
    fe <- environment(fit_fun)
    if (!is.null(fe) && !identical(fe, globalenv()) && !isNamespace(fe))
      stop("mediate_m: with cores > 1 fit_fun must be a top-level function, not a closure (its state would not ",
           "be shared with the workers); use cores = 1", call. = FALSE)
  }
  extra_vars <- unlist(lapply(extra_terms, function(t) all.vars(str2lang(t))))
  vars <- unique(c(outcome, exposure, mediators, covars, offset, slopes, "year", "unit_id", "ym", "ym_f", extra_vars))
  cr <- complete_rows(data.table::as.data.table(data), vars)
  d <- droplevels(cr$data[, vars, with = FALSE])
  if (!nrow(d)) stop("mediate_m: no complete rows remain (", nrow(cr$dropped), " rows dropped)", call. = FALSE)
  est <- .med_fits(d, outcome, exposure, mediators, covars, offset, slopes, nb_fitter_with(extra_terms, fit_fun))
  if (any(est$n_by_model != nrow(d)))
    stop("mediate_m: the models were not fitted on the same rows: ",
         paste(names(est$n_by_model), est$n_by_model, collapse = ", "), call. = FALSE)
  indirect_by <- est$a * est$b
  indirect <- sum(indirect_by)

  st <- list(d = d, outcome = outcome, exposure = exposure, mediators = mediators, covars = covars, offset = offset,
             slopes = slopes, extra_terms = extra_terms, fit_fun = fit_fun, resample = resample,
             block = as.integer(block), seed = seed)
  cl <- NULL
  on.exit(if (!is.null(cl)) parallel::stopCluster(cl), add = TRUE)
  start_cluster <- function(n) {
    if (!exists(".e_cluster", mode = "function"))
      stop("mediate_m: cores > 1 needs .e_cluster() (source models/E/R/power.R)", call. = FALSE)
    x <- .e_cluster(n)
    parallel::clusterCall(x, .e_med_init, MODELS_ROOT)
    parallel::clusterCall(x, .e_med_set, st)
    x
  }
  if (cur > 1L) cl <- start_cluster(cur)
  cores_used <- cur
  res <- vector("list", B)
  s <- 1L
  while (s <= B) {
    want <- .check_cores(cores_fun())
    if (want > cur) {                                  # more cores free: rebuild the cluster larger
      if (!is.null(cl)) parallel::stopCluster(cl)
      cl <- NULL
      cl <- start_cluster(want)
      cur <- want
      cores_used <- c(cores_used, cur)
    }
    chunk <- if (cur > 1L) 4L * cur else 10L
    idx <- s:min(B, s + chunk - 1L)
    res[idx] <- if (is.null(cl)) lapply(idx, .e_med_one, st = st) else parallel::clusterApplyLB(cl, idx, .e_med_task)
    if (is.function(progress)) progress(max(idx), B)
    s <- max(idx) + 1L
  }
  k <- length(mediators)
  A <- matrix(unlist(lapply(res, `[[`, "a")), ncol = k, byrow = TRUE, dimnames = list(NULL, mediators))
  Bm <- matrix(unlist(lapply(res, `[[`, "b")), ncol = k, byrow = TRUE, dimnames = list(NULL, mediators))
  boot <- data.table::data.table(i = vapply(res, `[[`, 0L, "i"))
  for (m in mediators) data.table::set(boot, j = paste0("a_", m), value = A[, m])
  for (m in mediators) data.table::set(boot, j = paste0("b_", m), value = Bm[, m])
  boot[, `:=`(c_direct = vapply(res, `[[`, 0, "c_direct"), c_total = vapply(res, `[[`, 0, "c_total"))]
  boot[, indirect := rowSums(A * Bm)]
  boot[, prop := indirect / c_total]
  boot[, `:=`(error = vapply(res, `[[`, "", "error"), secs = vapply(res, `[[`, 0, "secs"))]
  ok <- is.na(boot$error)
  B_ok <- sum(ok); B_failed <- B - B_ok
  na2 <- c(NA_real_, NA_real_)
  if (B_failed > 0.1 * B) {
    flag <- "too_many_failed_fits"
    prop_flag <- "not_assessed"
    ci <- list(indirect = na2, prop = na2, c_total = na2, c_direct = na2,
               a = stats::setNames(rep(list(na2), k), mediators), b = stats::setNames(rep(list(na2), k), mediators),
               indirect_by = stats::setNames(rep(list(na2), k), mediators))
  } else {
    flag <- "ok"
    bo <- boot[ok]
    ci <- list(indirect = .pct(bo$indirect), prop = na2, c_total = .pct(bo$c_total), c_direct = .pct(bo$c_direct),
               a = lapply(stats::setNames(mediators, mediators), function(m) .pct(A[ok, m])),
               b = lapply(stats::setNames(mediators, mediators), function(m) .pct(Bm[ok, m])),
               indirect_by = lapply(stats::setNames(mediators, mediators), function(m) .pct(A[ok, m] * Bm[ok, m])))
    pc <- .prop_ci(indirect, est$c_total, bo, ci$c_total)
    prop_flag <- pc$prop_flag
    ci$prop <- pc$ci
  }
  list(a = est$a, b = est$b, c_total = est$c_total, c_direct = est$c_direct, indirect = indirect,
       indirect_by = indirect_by, prop_mediated = indirect / est$c_total, ci = ci, B = B, B_ok = as.integer(B_ok),
       B_failed = as.integer(B_failed), B_prop_nonfinite = as.integer(sum(ok & !is.finite(boot$prop))), flag = flag,
       prop_flag = prop_flag, n = nrow(d), n_units = nlevels(d$unit_id), resample = resample, re_used = est$re_used,
       seed = seed, block = as.integer(block), boot = boot[], fail_messages = unique(boot$error[!ok]),
       dropped = cr$dropped, cores = cur, cores_used = cores_used)
}

# ---- results keys (contract §6) -----------------------------------------------------------------------------------

# "34% (95% CI 12–60%)"; "−8% (95% CI −30 to 15%)" (percent, 0 decimals; " to " when a bound is negative).
fmt_pct_ci <- function(est, lo, hi) {
  neg <- round(lo) < 0 || round(hi) < 0
  enc2utf8(paste0(fmt_num(est, 0), "% (95% CI ", fmt_num(lo, 0), if (neg) " to " else EN_DASH, fmt_num(hi, 0), "%)"))
}

.med_desc <- function(r) {
  sprintf(paste("mediate_m(): %s resampling, B = %d (%d successful, %d failed), seeds SEED_E + i - 1 = %d + i - 1;",
                "%d unit-months, %d units; a = %s; b = %s; indirect = %s (by mediator %s); c_total = %s, c_direct = %s;",
                "prop = %s; flag %s, prop_flag %s; unit random effect b-path %s, total %s; iid (1 | ym_f) in the NB fits;",
                "a-path covariates = the Model T covariates (F48)"),
          if (r$resample == "month_block") sprintf("month-block (block %d)", r$block) else "cluster-by-unit",
          r$B, r$B_ok, r$B_failed, r$seed, r$n, r$n_units,
          paste(names(r$a), .s6v(r$a), sep = " ", collapse = ", "), paste(names(r$b), .s6v(r$b), sep = " ", collapse = ", "),
          .s6v(r$indirect), paste(names(r$indirect_by), .s6v(r$indirect_by), sep = " ", collapse = ", "),
          .s6v(r$c_total), .s6v(r$c_direct), .s6v(r$prop_mediated), r$flag, r$prop_flag,
          r$re_used[["b"]], r$re_used[["total"]])
}

.s6v <- function(x) ifelse(is.na(x), "NA", format(signif(x, 6), scientific = FALSE, trim = TRUE))

.med_prop_entry <- function(r, what, script) {
  if (is.character(r)) {
    ne <- not_estimable(first_line(r))
    return(res_entry(NA, ne, script, sprintf("%s: %s", what, ne)))
  }
  pct <- 100 * r$prop_mediated
  if (identical(r$flag, "too_many_failed_fits"))
    return(res_entry(pct, paste0(fmt_num(pct, 0), "% (CI not estimated: >10% of bootstrap refits failed)"), script,
                     sprintf("%s. %s", what, .med_desc(r))))
  if (!identical(r$prop_flag, "ok"))
    return(res_entry(NA, not_estimable(r$prop_flag), script, sprintf("%s. %s", what, .med_desc(r))))
  res_entry(pct, fmt_pct_ci(pct, 100 * r$ci$prop[1], 100 * r$ci$prop[2]), script,
            sprintf("%s; percentile CI %s to %s%%. %s", what, .s6v(100 * r$ci$prop[1]), .s6v(100 * r$ci$prop[2]), .med_desc(r)))
}

# The five §6 keys of one outcome. reason (a full display such as "not estimated (no total association)" or
# "not estimable (...)") fills all five; otherwise mb is the month-block mediate_m() result (or an error message)
# and unit the cluster-by-unit sensitivity result (or an error message).
mediation_keys <- function(ind, mb = NULL, unit = NULL, reason = NULL, script = MED_SCRIPT) {
  keys <- paste0("E.med.", ind, ".", c("prop", "prop_unit", "indirect", "flag", "B"))
  if (is.null(reason) && is.character(mb)) reason <- not_estimable(first_line(mb))
  if (!is.null(reason))
    return(stats::setNames(lapply(keys, function(k)
      res_entry(NA, reason, script, sprintf("%s: %s (mediation rule: estimated only when the Model T en_t 95%% CI excludes 1)",
                                             k, reason))), keys))
  e <- list()
  e[[keys[1]]] <- .med_prop_entry(mb, sprintf("Local-climate-mediated share of the total en_t association, %s, month-block bootstrap", ind), script)
  e[[keys[2]]] <- .med_prop_entry(unit, sprintf("Local-climate-mediated share, %s, cluster bootstrap by unit (sensitivity)", ind), script)
  ind_irr <- exp(mb$indirect)
  e[[keys[3]]] <- if (identical(mb$flag, "too_many_failed_fits"))
    res_entry(ind_irr, paste0(fmt_num(ind_irr, 2), " (CI not estimated: >10% of bootstrap refits failed)"), script,
              sprintf("Indirect IRR per +1 deg C, exp(sum a_k b_k), %s. %s", ind, .med_desc(mb)))
  else res_entry(ind_irr, fmt_ci(ind_irr, exp(mb$ci$indirect[1]), exp(mb$ci$indirect[2]), 2), script,
                 sprintf("Indirect IRR per +1 deg C, exp(sum a_k b_k), %s, month-block percentile CI. %s", ind, .med_desc(mb)))
  fl <- if (!identical(mb$flag, "ok")) mb$flag else mb$prop_flag
  e[[keys[4]]] <- res_entry(fl, fl, script, sprintf("Bootstrap status of the month-block run for %s: flag %s, prop_flag %s",
                                                     ind, mb$flag, mb$prop_flag))
  e[[keys[5]]] <- res_entry(mb$B, fmt_int(mb$B), script,
                            sprintf("Bootstrap resamples requested for %s: %d; successful %d (month-block), %s (by unit)",
                                    ind, mb$B, mb$B_ok, if (is.character(unit)) "not estimable" else as.character(unit$B_ok)))
  e
}
