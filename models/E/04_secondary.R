# Paper E Task 9: secondary and sensitivity analyses (contract papers/E/results_keys.md §5 cum02/tmax, §8-§11;
# spec §4, §5.5, §5.9; rulings F3, F14, F19, F23, F28, F44, F52, F56, F61, F62). No verdict is produced here.
#
# Run from <repo>/models after 02_primary.R. run_secondary() refuses to start unless
# papers/E/output/primary_estimates.csv is tracked, clean and committed after 257aacc (contract Amendment 3, F61), as
# Task 10 does: the heterogeneity LRT reuses each outcome's Model T time random-effect step and the crossings note
# compares with the primary IRR.
#   Rscript E/04_secondary.R            # cores e_cores(), re-checked before each bootstrap; B = 1,000
#   --cores=N   --B=N   --out-dir=DIR (papers/E/output)   --rds=PATH (models/E/_cache/secondary.rds)   --no-resume
# Every task result is checkpointed to models/E/_cache/secondary_tasks/<task>.rds as it returns (fingerprint: the
# primary estimates, the panel, B, the FY2020-21 status and this code); a rerun after a crash loads the matching
# checkpoints and fits only the rest (--no-resume refits everything).
#
# Analyses per outcome (an outcome dropped by the 20% masking rule is not fitted; its keys read
# "not estimable (dropped: more than 20% of state-months masked)"):
#   sensitivities  sens_case() for each SENS_IDS case (roni and nino34 are 05_forecast.R's), Model T en_t through the
#                  time random-effect chain (ar1 -> iid -> moving-block bootstrap, B = 1,000), step logged and recorded;
#                  births reads "not available (SRS not retrieved)", allcomp "not applicable (...)" for the
#                  single-item outcomes, fy2021 "not estimable (FY2020-21 <reason>)" unless fy2021_status.json is
#                  final and committed (F3);
#   distributed lag  dlm_part(): en_t replaced by the cross-basis en_cb1..3, ln_t at lag 0, the same chain;
#   IOD            iod_fit(): Model T + dmi_3m + en_t:dmi_3m, the same chain; iod_counts() over the 95 primary months;
#   heterogeneity  het_test() with the primary Model T step (bootstrap step -> all three keys "not estimable (no
#                  converged time random effect)"), het_rule();
#   Model L        model_l_lags() (cum02: sum of the lag 0-2 coefficients) and model_l_tmax() (tmax_anom_l0 in place
#                  of heatwave_days_l0); year-month fixed effects, no time random effect;
#   BFGS (F62)     for BFGS_OUTCOMES (opd) only: primary Models S and L refitted with optim BFGS (model_sl_bfgs()),
#                  and cum02 / tmax with BFGS when their default fits are not estimable. Descriptive: no results key,
#                  no verdict, not in the Holm family.
# Every fit uses the F61 optimiser limits (BFGS fits: optim maxit 10,000). Only a genuine estimation failure
# (is_estimation_failure()) makes a result not estimable; any other error stops the run (F56).
#
# Outputs (state-level estimates only):
#   papers/E/output/sensitivity.csv: analysis (sens / l_cum02 / l_tmax / s_bfgs / l_bfgs / l_cum02_bfgs /
#     l_tmax_bfgs), outcome, case (sensitivity id; hw / dry / wet / tmax; the term for s_bfgs / l_bfgs), term (en_t;
#     for Model L the summed variable or tmax_anom_l0), est, se (log scale; bootstrap SD under the bootstrap step),
#     irr, lo, hi (coefficient orientation: dry is exp(+sum) here, exp(-sum) in the keys), p, p_kind (wald /
#     bootstrap), B_ok, time_re (ar1 / iid / block_bootstrap; NA without a time random effect), re_used, n, n_units,
#     status (ok / error / skip / dropped), error, pd_hess, max_grad (largest absolute gradient), notes (fitter
#     messages, e.g. rank-deficient columns dropped), display (the fixed display of a skip row), note (BFGS rows:
#     "sensitivity; no verdict; not in the Holm family").
#   papers/E/output/dlm.csv: outcome, lag (0..6), est, se, irr, lo, hi, p_kind, B_ok, time_re, re_used, n, n_units,
#     status, error, pd_hess, max_grad, notes.
#   papers/E/output/iod.csv: outcome, term (dmi_3m / en_t:dmi_3m), the estimate columns as sensitivity.csv; plus
#     four rows outcome NA, combo (warm_pos, warm_neg, cool_pos, cool_neg), n_months.
#   papers/E/output/heterogeneity.csv: outcome, lrt_p, df, stat, slope_sd, sd_lo, sd_hi, pd_hess, max_grad,
#     lrt_p_1415, lrt_p_1819, holds_1415, holds_1819, identifiable (het_rule), time_re, re_null, re_alt, n, n_units,
#     status, error, drop_errors, notes.
#   papers/E/output/het_modes.csv (Figure S1 input): outcome, unit_id, mode, sd (conditional mode of the unit en_t
#     slope and its conditional SD, log-rate scale), identifiable; units in unit_id order, never ranked; Figure S1 is
#     drawn only for an identifiable outcome (spec §5.5).
#   models/E/_cache/secondary.rds (git-ignored): list(tables, entries, het_modes, crossings, settings, runtime_min).
#   run_secondary() returns list(entries (the 214 keys this script owns), tables, crossings, runtime_min).

if (!exists("MODELS_ROOT")) source("common/R/load.R")
if (!exists("E_DIR")) source(file.path(MODELS_ROOT, "E", "R", "common_e.R"))
for (f in c("monthly.R", "power.R", "verdicts.R", "secondary.R")) source(file.path(MODELS_ROOT, "E", "R", f))
if (!exists("primary_entries")) source(file.path(MODELS_ROOT, "E", "02_primary.R"))   # specs, dropped_outcomes, displays
if (!exists("contract_keys")) source(file.path(MODELS_ROOT, "D", "R", "contract.R"))      # read-only

SECONDARY_SCRIPT <- "models/E/04_secondary.R"
SEC_CKPT_DIR <- file.path(E_CACHE, "secondary_tasks")

# The contract keys this script owns: §8 heterogeneity, §9 IOD, §10 distributed lag, §11 sensitivities except roni
# and nino34 (05_forecast.R), and the §5 Model L cum02 and tmax keys.
secondary_contract_keys <- function(path = file.path(PAPER_E, "results_keys.md")) {
  k <- contract_keys(path, prefix = "E")
  k[(grepl("^E\\.(het|iod|dlm|sens)\\.", k) & !grepl("^E\\.sens\\..*\\.(roni|nino34)$", k)) |
      grepl("^E\\.l\\..*\\.cum02$|^E\\.l\\..*\\.tmax\\.irr$", k)]
}

# Amendment 3 / F61 ordering: assert_primary_post_f61(caller = "run_secondary") (02_primary.R; unified with the
# Task 10 guard at the final review).

# ---- tasks -----------------------------------------------------------------------------------------------------------

# Spec, data, terms and extra terms of a chain task (sens, dlm, iod), shared by the fit and the bootstrap step.
secondary_task_inputs <- function(task, d, d_fy = NULL, fy = list(ok = FALSE, reason = "not checked"),
                                  basis = dlm_basis()) {
  switch(task$kind,
    sens = {
      cs <- sens_case(task$id, d, task$ind, d_fy, fy)
      list(spec = cs$spec, data = cs$data, terms = "en_t", extra = cs$extra, skip = cs$skip)
    },
    dlm = c(dlm_inputs(task$ind), list(data = cross_basis(d, basis), skip = NA_character_)),
    iod = c(iod_inputs(task$ind), list(data = d, skip = NA_character_)),
    stop("secondary_task_inputs: not a chain task: ", task$kind, call. = FALSE))
}

# One task: a chain part (sens, dlm, iod; t_chain_part() record), het_test(), or a Model L / BFGS fit (list(status,
# rows, error)). Only estimation failures become status "error"; any other error is raised (F56). The BFGS kinds
# (sl_bfgs with id "S" or "L", l_lags_bfgs, l_tmax_bfgs) always use e_bfgs_fit (F62).
secondary_task_run <- function(task, d, d_fy = NULL, fy = list(ok = FALSE, reason = "not checked"),
                               fit_fun = e_glmmTMB_fit, basis = dlm_basis()) {
  if (task$kind %in% c("sens", "dlm", "iod")) {
    s <- secondary_task_inputs(task, d, d_fy, fy, basis)
    return(t_chain_part(s$spec, s$data, s$terms, s$extra, fit_fun = fit_fun,
                        on_fit = if (task$kind == "dlm") function(f) dlm_curve(f, basis)))
  }
  if (task$kind == "het") return(het_test(d, task$ind, time_re = task$time_re, fit_fun = fit_fun))
  run <- switch(task$kind,
    l_lags = function() model_l_lags(d, task$ind, fit_fun = fit_fun),
    l_tmax = function() model_l_tmax(d, task$ind, fit_fun = fit_fun),
    l_lags_bfgs = function() model_l_lags(d, task$ind, fit_fun = e_bfgs_fit),
    l_tmax_bfgs = function() model_l_tmax(d, task$ind, fit_fun = e_bfgs_fit),
    sl_bfgs = function() model_sl_bfgs(d, task$ind, model = task$id),
    stop("secondary_task_run: unknown task kind: ", task$kind, call. = FALSE))
  catch_estimation_failure(list(status = "ok", rows = run(), error = NA_character_),
                           function(e) list(status = "error", rows = NULL, error = first_line(conditionMessage(e))))
}

.task_label <- function(task) paste(task$ind, task$kind, if (!is.null(task$id)) task$id else "")

.task_status <- function(r) {
  s <- if (!is.null(r$status)) r$status else if (is.na(r$error)) "ok" else "error"
  if (identical(s, "ok") && !is.null(r$rows$time_re) && !is.na(r$rows$time_re[1])) s <- paste("ok,", r$rows$time_re[1])
  if (!identical(substr(s, 1, 2), "ok") && !is.null(r$error) && !is.na(r$error)) s <- paste0(s, ": ", r$error)
  if (!is.null(r$rows$pd_hess) && !is.na(r$rows$pd_hess[1]))
    s <- sprintf("%s; pdHess %s, max|grad| %s", s, r$rows$pd_hess[1], format(signif(r$rows$max_grad[1], 3)))
  notes <- stats::na.omit(unique(c(r$rows$notes, r$notes)))
  notes <- notes[nzchar(notes)]
  if (length(notes)) s <- paste0(s, " [fitter messages: ", paste(notes, collapse = "; "), "]")
  s
}

# Checkpoints (review finding 6): one rds per task, keyed by the run fingerprint.
.ckpt_path <- function(dir, task) file.path(dir, paste0(gsub("[^A-Za-z0-9]+", "_", trimws(.task_label(task))), ".rds"))

.ckpt_save <- function(dir, task, result, fp) {
  if (is.null(dir)) return(invisible(NULL))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  path <- .ckpt_path(dir, task)
  tmp <- paste0(path, ".tmp")
  saveRDS(list(task = task, result = result, fingerprint = fp), tmp)
  file.rename(tmp, path)
  invisible(path)
}

.ckpt_load <- function(dir, task, fp) {
  if (is.null(dir)) return(NULL)
  path <- .ckpt_path(dir, task)
  if (!file.exists(path)) return(NULL)
  x <- readRDS(path)
  if (!identical(x$fingerprint, fp) || !identical(x$task, task)) return(NULL)
  x$result
}

# The run fingerprint: the primary estimates, the panel(s), B, the FY2020-21 status and this code.
.sec_fingerprint <- function(primary_csv, d, d_fy, B, fy) {
  tf <- tempfile(fileext = ".rds")
  on.exit(unlink(tf))
  saveRDS(list(d, d_fy), tf, compress = FALSE)
  code <- file.path(MODELS_ROOT, "E", c("R/secondary.R", "04_secondary.R", "R/monthly.R"))
  unname(c(tools::md5sum(c(primary_csv, tf, code)), as.character(B), as.character(isTRUE(fy$ok))))
}

# Run one task, log it (step, convergence, fitter messages) and checkpoint it.
.run_task <- function(task, d, d_fy, fy, fit_fun, log_file, ckpt_dir, fp) {
  t0 <- Sys.time()
  r <- secondary_task_run(task, d, d_fy, fy, fit_fun = fit_fun)
  elog(sprintf("%s: %s in %.1f min", .task_label(task), .task_status(r),
               as.numeric(difftime(Sys.time(), t0, units = "mins"))), file = log_file)
  .ckpt_save(ckpt_dir, task, r, fp)
  r
}

# PSOCK worker set-up: the Paper E helpers (.e_worker_init) plus verdicts.R, secondary.R and this script.
.e_secondary_init <- function(root) {
  loadNamespace("data.table")       # a data.table shipped before the namespace is loaded would index as a data.frame
  source(file.path(root, "E", "04_secondary.R"))
  invisible(TRUE)
}
.e_sec_set <- function(name, value) {
  assign(name, value, envir = globalenv())
  invisible(NULL)
}

.e_secondary_task <- function(task) {
  g <- function(n) get(n, envir = globalenv())
  # copies: valid data.tables on the worker (as 02_primary.R's workers); the fitter shipped by run_secondary()
  .run_task(task, data.table::copy(g(".E_SEC_D")), data.table::copy(g(".E_SEC_DFY")), g(".E_SEC_FY"),
            g(".E_SEC_FIT"), g(".E_SEC_LOG"), g(".E_SEC_CKPT"), g(".E_SEC_FP"))
}

# ---- tables ----------------------------------------------------------------------------------------------------------

.na_est <- function(status, error) data.table::data.table(est = NA_real_, se = NA_real_, irr = NA_real_,
  lo = NA_real_, hi = NA_real_, p = NA_real_, p_kind = NA_character_, B_ok = NA_integer_, time_re = NA_character_,
  re_used = NA_character_, n = NA_integer_, n_units = NA_integer_, status = status, error = error, pd_hess = NA,
  max_grad = NA_real_, notes = NA_character_)

.het_row <- function(o, h, status = if (is.na(h$error)) "ok" else "error") {
  data.table::data.table(outcome = o, lrt_p = h$lrt_p, df = h$df, stat = h$stat, slope_sd = h$slope_sd,
                         sd_lo = h$sd_lo, sd_hi = h$sd_hi, pd_hess = h$pd_hess,
                         max_grad = if (is.null(h$max_grad)) NA_real_ else h$max_grad, lrt_p_1415 = h$lrt_p_1415,
                         lrt_p_1819 = h$lrt_p_1819, holds_1415 = h$holds_1415, holds_1819 = h$holds_1819,
                         identifiable = if (status == "ok") het_rule(h$lrt_p, h$pd_hess, h$sd_lo, h$holds_1415,
                                                                     h$holds_1819) else NA,
                         time_re = h$time_re, re_null = h$re_null, re_alt = h$re_alt, n = h$n, n_units = h$n_units,
                         status = status, error = h$error,
                         drop_errors = paste(sprintf("%s: %s", names(h$drop_errors), h$drop_errors)[!is.na(h$drop_errors)],
                                             collapse = "; "),
                         notes = if (is.null(h$notes) || !length(h$notes)) NA_character_ else h$notes)
}

.het_empty <- function(error, time_re = NA_character_) list(lrt_p = NA_real_, df = NA_integer_, stat = NA_real_,
  slope_sd = NA_real_, sd_lo = NA_real_, sd_hi = NA_real_, pd_hess = NA, holds_1415 = NA, holds_1819 = NA,
  lrt_p_1415 = NA_real_, lrt_p_1819 = NA_real_, drop_errors = c(ep1415 = NA_character_, ep1819 = NA_character_),
  re_null = NA_character_, re_alt = NA_character_, n = NA_integer_, n_units = NA_integer_, modes = NULL,
  error = error, time_re = time_re, max_grad = NA_real_, notes = NA_character_)

# Sensitivity rows whose IRR lies on the other side of 1 from the primary Model T en_t IRR (H7/H8 outcomes; a note
# only, no verdict). prim: primary_estimates.csv rows (outcome, model, term, irr, status).
sens_crossings <- function(sens, prim) {
  p <- data.table::as.data.table(prim)[model == "T" & term == "en_t" & status == "ok" & outcome %in% PRIMARY5,
                                       .(outcome, primary_irr = irr)]
  s <- data.table::as.data.table(sens)[status == "ok" & outcome %in% PRIMARY5, .(outcome, case, sens_irr = irr)]
  x <- merge(s, p, by = "outcome")
  x[(sens_irr < 1) != (primary_irr < 1)][order(match(outcome, INDS), match(case, SENS_IDS))]
}

# ---- results keys ----------------------------------------------------------------------------------------------------

.sec_estimate_text <- function(r, B = B_T) {
  boot <- identical(r$p_kind, "bootstrap")
  step <- if (is.na(r$time_re)) "none (year-month fixed effects)" else time_re_display(r$time_re, B)
  sprintf(paste("%s unit-months, %s units; time random effect: %s; unit random effect: %s; beta = %s, SE = %s%s;",
                "IRR %s (%s %s to %s); p = %s (%s)"),
          fmt_int(r$n), r$n_units, step, r$re_used, .s6(r$est), .s6(r$se), if (boot) " (bootstrap SD)" else "",
          .s6(r$irr), if (boot) sprintf("percentile 95%% CI over %d successful month-block resamples, block 12, seeds SEED_E + i - 1 = %d + i - 1;",
                                        r$B_ok, SEED_E) else "Wald 95% CI", .s6(r$lo), .s6(r$hi),
          if ("p" %in% names(r)) .s6(r[["p"]]) else "not computed",       # dlm lag rows carry no p
          if (boot) "two-sided bootstrap p" else "two-sided Wald") |>
    paste0(if ("notes" %in% names(r) && !is.na(r[["notes"]])) paste0("; fitter messages: ", r[["notes"]]) else "")
}

# The 214 keys of §5 (cum02, tmax), §8, §9, §10 and §11 (without roni, nino34) from the tables of run_secondary():
# tabs = list(sens, l, dlm, iod, iod_n, het) with the columns documented in the header.
secondary_entries <- function(tabs, script = SECONDARY_SCRIPT, B = B_T) {
  E <- list()
  put <- function(k, value, display, description) E[[k]] <<- res_entry(value, display, script, description)
  one <- function(tab, ..., what) {
    r <- tab[...]
    if (nrow(r) != 1L) stop(sprintf("secondary_entries: %d rows for %s", nrow(r), what), call. = FALSE)
    r
  }
  reason <- function(r) if (!is.na(r$error)) r$error else "estimate missing"
  na_key <- function(k, r, what) {
    if (identical(r$status, "skip")) return(put(k, NA, r$display, sprintf("%s: %s", what, r$display)))
    d <- if (identical(r$status, "dropped")) not_estimable(DROPPED_REASON) else not_estimable(reason(r))
    put(k, NA, d, sprintf("%s: %s%s", what, d, if (!is.na(r$B_ok)) sprintf("; block bootstrap: %d of %d refits succeeded", r$B_ok, B) else ""))
  }
  ok <- function(r) identical(r$status, "ok") && !is.na(r$irr)
  irr_key <- function(k, r, what, flip = FALSE) {
    if (!ok(r)) return(na_key(k, r, what))
    est <- r$irr; lo <- r$lo; hi <- r$hi
    if (flip) { est <- 1 / r$irr; lo <- 1 / r$hi; hi <- 1 / r$lo }
    put(k, est, fmt_ci(est, lo, hi, 2),
        sprintf("%s%s. %s", what, if (flip) sprintf("; displayed as exp(-beta) = %s with the bounds swapped (%s to %s)",
                                                     .s6(est), .s6(lo), .s6(hi)) else "", .sec_estimate_text(r, B)))
  }

  # §11 sensitivities
  for (o in INDS) for (id in SENS_IDS)
    irr_key(sprintf("E.sens.%s.%s", o, id), one(tabs$sens, outcome == o & case == id, what = paste(o, id)),
            sprintf("Sensitivity %s, %s: Model T en_t IRR per +1 deg C with %s; no verdict", id, o,
                    sub("<ind>", o, SENS_TEXT[[id]], fixed = TRUE)))

  # §5 Model L cum02 and tmax
  ltext <- c(hw = "heatwave days (heatwave_days_l0 + _l1 + _l2), IRR per additional day = exp(sum)",
             dry = "spi3_dry (lags 0-2), IRR per one SPI-3 unit more deficit = exp(-sum)",
             wet = "spi3_wet (lags 0-2), IRR per +1 SPI-3 unit of excess = exp(sum)")
  for (o in INDS) {
    for (v in names(ltext))
      irr_key(sprintf("E.l.%s.%s.cum02", o, v), one(tabs$l, outcome == o & analysis == "l_cum02" & case == v, what = paste(o, v)),
              sprintf("Model L with each local-climate term at lags 0, 1 and 2 entered together (year-month fixed effects, no time random effect), %s: %s; sum of the three lag coefficients, SE from their covariance",
                      o, ltext[[v]]), flip = v == "dry")
    irr_key(sprintf("E.l.%s.tmax.irr", o), one(tabs$l, outcome == o & analysis == "l_tmax", what = paste(o, "tmax")),
            sprintf("Model L sensitivity, %s: tmax_anom_l0 replacing heatwave_days_l0 (never entered together), IRR per +1 deg C Tmax anomaly", o))
  }

  # §10 distributed lag
  for (o in INDS) for (k in 0:6)
    irr_key(sprintf("E.dlm.%s.lag%d", o, k), one(tabs$dlm, outcome == o & lag == k, what = paste(o, "lag", k)),
            sprintf("Distributed-lag Model T, %s: IRR per +1 deg C El Nino-phase ONI at lag %d months (cross-basis en_t_l0..en_t_l6 %%*%% ns(0:6, df = 3, intercept = TRUE); ln_t at lag 0; CI from basis V t(basis), or percentile under the bootstrap step); exploratory, no verdict",
                    o, k))

  # §9 IOD
  for (o in INDS) {
    irr_key(sprintf("E.iod.%s.irr_dmi", o), one(tabs$iod, outcome == o & term == "dmi_3m", what = paste(o, "dmi")),
            sprintf("Model T + dmi_3m + en_t:dmi_3m, %s: IRR per +1 deg C dmi_3m; no verdict", o))
    irr_key(sprintf("E.iod.%s.irr_int", o), one(tabs$iod, outcome == o & term == "en_t:dmi_3m", what = paste(o, "int")),
            sprintf("Model T + dmi_3m + en_t:dmi_3m, %s: IRR of the interaction en_t x dmi_3m (per deg C squared); no verdict", o))
  }
  for (cb in c("warm_pos", "warm_neg", "cool_pos", "cool_neg")) {
    n <- tabs$iod_n[combo == cb]$n_months
    put(sprintf("E.iod.n_months.%s", cb), n, fmt_int(n),
        sprintf("Primary months (of 95) with ENSO phase x IOD sign %s (warm = ONI > 0, cool = ONI <= 0; pos = dmi_3m > 0, neg = dmi_3m <= 0)", cb))
  }

  # §8 heterogeneity
  for (o in INDS) {
    h <- one(tabs$het, outcome == o, what = paste(o, "het"))
    keys <- sprintf("E.het.%s.%s", o, c("lrt_p", "slope_sd", "identifiable"))
    if (!identical(h$status, "ok")) {
      d <- if (identical(h$status, "dropped")) not_estimable(DROPPED_REASON) else not_estimable(h$error)
      for (k in keys) put(k, NA, d, sprintf("Heterogeneity test (en_t random slope), %s: %s", o, d))
      next
    }
    base <- sprintf("Model T with slopes t_c and en_t versus Model T (unit RE %s vs %s), both with time random effect %s; %s unit-months, %s units; LRT statistic %s on %d df (boundary test, reported as is)",
                    h$re_alt, h$re_null, h$time_re, fmt_int(h$n), h$n_units, .s6(h$stat), h$df)
    put(keys[1], h$lrt_p, fmt_p(h$lrt_p), sprintf("LRT p, %s. %s", o, base))
    sd_disp <- if (is.finite(h$sd_lo) && is.finite(h$sd_hi)) fmt_ci(h$slope_sd, h$sd_lo, h$sd_hi, 3) else
      paste0(fmt_num(h$slope_sd, 3), " (CI not estimable)")
    put(keys[2], h$slope_sd, sd_disp,
        sprintf("SD of the unit en_t slope (log-rate scale), %s: %s, Wald 95%% CI on the log-SD scale %s to %s. %s",
                o, .s6(h$slope_sd), .s6(h$sd_lo), .s6(h$sd_hi), base))
    idf <- isTRUE(h$identifiable)
    put(keys[3], idf, if (idf) "identifiable (spec §5.5 rule met)" else "not identifiable (spec §5.5 rule not met)",
        sprintf("Spec §5.5 rule, %s: LRT p %s < 0.05; Hessian positive definite %s; SD lower CI %s > 0.01; LRT p without ep1415 %s, without ep1819 %s (both < 0.05 required)%s. %s",
                o, .s6(h$lrt_p), h$pd_hess, .s6(h$sd_lo), .s6(h$lrt_p_1415), .s6(h$lrt_p_1819),
                if (nzchar(h$drop_errors)) paste0("; drop-episode refits not estimable: ", h$drop_errors) else "", base))
  }
  E[order(names(E), method = "radix")]
}

# ---- run -------------------------------------------------------------------------------------------------------------

.is_top_level <- function(f) {
  e <- environment(f)
  is.null(e) || identical(e, globalenv()) || isNamespace(e)
}

run_secondary <- function(cores = NULL, B = B_T, primary_csv = file.path(E_OUT, "primary_estimates.csv"),
                          out_dir = E_OUT, rds = file.path(E_CACHE, "secondary.rds"), gate_csv = GATE_SUMMARY_CSV,
                          contract = file.path(PAPER_E, "results_keys.md"), fy2021 = NULL, write = TRUE, d = NULL,
                          d_fy = NULL, fit_fun = e_glmmTMB_fit, boot_fun = block_bootstrap_irr,
                          log_file = file.path(E_LOGS, "secondary.log"), ckpt_dir = SEC_CKPT_DIR, resume = TRUE,
                          check_primary = function() assert_primary_post_f61(caller = "run_secondary"),
                          bfgs_outcomes = BFGS_OUTCOMES) {
  lg <- function(...) elog(..., file = log_file)
  if (!file.exists(primary_csv))
    stop("run_secondary: ", primary_csv, " does not exist: run E/02_primary.R first", call. = FALSE)
  provenance <- check_primary()
  t0 <- Sys.time()
  cores_fun <- if (is.null(cores)) function() e_cores() else { cores <- as.integer(cores); function() cores }
  prim <- data.table::fread(primary_csv, na.strings = c("", "NA"))
  pt <- prim[model == "T" & term == "en_t"]
  if (!setequal(pt$outcome, INDS)) stop("run_secondary: primary_estimates.csv lacks Model T rows", call. = FALSE)
  if (is.null(d)) d <- read_hmis_model("primary")
  if (is.null(fy2021)) fy2021 <- fy2021_ready()
  if (isTRUE(fy2021$ok) && is.null(d_fy)) d_fy <- read_hmis_model("fy2021")
  dropped <- intersect(INDS, dropped_outcomes(gate_csv))
  live <- setdiff(INDS, dropped)
  fp <- .sec_fingerprint(primary_csv, d, d_fy, B, fy2021)
  lg(sprintf("run_secondary: start; %s; cores %d; B %d; FY2020-21 %s; dropped: %s; checkpoints %s (%s)", provenance,
             cores_fun(), as.integer(B), if (isTRUE(fy2021$ok)) "final and committed" else paste("not usable:", fy2021$reason),
             if (length(dropped)) paste(dropped, collapse = ", ") else "none",
             if (is.null(ckpt_dir)) "off" else ckpt_dir, if (resume) "resume" else "no resume"))

  # tasks; sensitivity skips and heterogeneity without a usable primary step are settled here, without a fit
  tasks <- list(); skips <- list(); het_pre <- list()
  for (o in live) {
    for (id in SENS_IDS) {
      sk <- sens_case(id, d, o, d_fy, fy2021)$skip
      if (!is.na(sk)) skips[[paste(o, id)]] <- data.table::data.table(outcome = o, case = id, display = sk)
      else tasks[[length(tasks) + 1L]] <- list(kind = "sens", ind = o, id = id)
    }
    for (k in c("dlm", "iod", "l_lags", "l_tmax")) tasks[[length(tasks) + 1L]] <- list(kind = k, ind = o)
    tr <- pt[outcome == o]
    if (!identical(tr$status, "ok")) het_pre[[o]] <- .het_empty(paste("Model T:", tr$error))
    else if (!tr$time_re %in% names(TIME_RE)) het_pre[[o]] <- .het_empty("no converged time random effect", tr$time_re)
    else tasks[[length(tasks) + 1L]] <- list(kind = "het", ind = o, time_re = tr$time_re)
    if (o %in% bfgs_outcomes) for (m in c("S", "L")) tasks[[length(tasks) + 1L]] <- list(kind = "sl_bfgs", ind = o, id = m)
  }
  res <- vector("list", length(tasks))
  if (resume) for (i in seq_along(tasks)) { x <- .ckpt_load(ckpt_dir, tasks[[i]], fp); if (!is.null(x)) res[[i]] <- x }
  todo <- which(vapply(res, is.null, NA))
  lg(sprintf("run_secondary: %d tasks (%d from checkpoints, %d to fit); %d settled without a fit", length(tasks),
             length(tasks) - length(todo), length(todo), length(skips) + length(het_pre)))

  n_cl <- min(cores_fun(), length(todo))
  if (n_cl > 1L) {
    if (!.is_top_level(fit_fun))
      stop("run_secondary: with cores > 1 fit_fun must be a top-level function, not a closure", call. = FALSE)
    cl <- .e_cluster(n_cl)
    res[todo] <- tryCatch({
      parallel::clusterCall(cl, .e_secondary_init, MODELS_ROOT)
      for (nm in c(".E_SEC_D", ".E_SEC_DFY", ".E_SEC_FY", ".E_SEC_FIT", ".E_SEC_LOG", ".E_SEC_CKPT", ".E_SEC_FP"))
        parallel::clusterCall(cl, .e_sec_set, nm, switch(nm, .E_SEC_D = d, .E_SEC_DFY = d_fy, .E_SEC_FY = fy2021,
                                                         .E_SEC_FIT = fit_fun, .E_SEC_LOG = log_file,
                                                         .E_SEC_CKPT = ckpt_dir, .E_SEC_FP = fp))
      parallel::clusterApplyLB(cl, tasks[todo], .e_secondary_task)
    }, finally = parallel::stopCluster(cl))
  } else {
    res[todo] <- lapply(tasks[todo], .run_task, d = d, d_fy = d_fy, fy = fy2021, fit_fun = fit_fun,
                        log_file = log_file, ckpt_dir = ckpt_dir, fp = fp)
  }

  # the moving-block bootstrap for every chain that failed (on the master, with the current core count)
  basis <- dlm_basis()
  for (i in seq_along(tasks)) {
    if (!identical(res[[i]]$status, "chain_failed")) next
    s <- secondary_task_inputs(tasks[[i]], d, d_fy, fy2021, basis)
    res[[i]] <- t_chain_resolve(res[[i]], s$data, B = B, cores = cores_fun(), fit_fun = fit_fun, boot_fun = boot_fun,
                                on_boot = if (tasks[[i]]$kind == "dlm") function(bb) dlm_curve(bb, basis),
                                label = .task_label(tasks[[i]]), log_fun = lg)
    lg(sprintf("%s: after the bootstrap step: %s", .task_label(tasks[[i]]), .task_status(res[[i]])))
    .ckpt_save(ckpt_dir, tasks[[i]], res[[i]], fp)
  }

  # F62 follow-up: BFGS cum02 / tmax for the BFGS outcomes whose default fit is not estimable
  for (i in seq_along(tasks)) {
    tk <- tasks[[i]]
    if (!tk$kind %in% c("l_lags", "l_tmax") || !tk$ind %in% bfgs_outcomes || !identical(res[[i]]$status, "error")) next
    bt <- list(kind = paste0(tk$kind, "_bfgs"), ind = tk$ind)
    x <- if (resume) .ckpt_load(ckpt_dir, bt, fp)
    if (is.null(x)) x <- .run_task(bt, d, d_fy, fy2021, fit_fun, log_file, ckpt_dir, fp)
    tasks[[length(tasks) + 1L]] <- bt
    res[[length(res) + 1L]] <- x
  }

  # tables
  kinds <- vapply(tasks, `[[`, "", "kind")
  inds <- vapply(tasks, `[[`, "", "ind")
  sens <- list(); l <- list(); dlm <- list(); iod <- list(); het <- list(); modes <- list(); bfgs <- list()
  l_rows <- function(r, an) {
    if (identical(r$status, "ok")) {
      x <- data.table::copy(r$rows)
      data.table::setnames(x, "term", "case")
      x[, `:=`(term = if (an %in% c("l_cum02", "l_cum02_bfgs")) unname(L_VARS[case]) else case, p_kind = "wald",
               B_ok = NA_integer_, time_re = NA_character_, status = "ok", error = NA_character_)]
    } else {
      cum <- an %in% c("l_cum02", "l_cum02_bfgs")
      x <- cbind(data.table::data.table(case = if (cum) names(L_VARS) else "tmax",
                                        term = if (cum) unname(L_VARS) else "tmax_anom_l0"), .na_est("error", r$error))
    }
    if (!an %in% c("l_cum02", "l_cum02_bfgs")) x[, case := "tmax"]
    x
  }
  for (i in seq_along(tasks)) {
    o <- inds[i]; r <- res[[i]]
    switch(kinds[i],
      sens = sens[[length(sens) + 1L]] <- cbind(data.table::data.table(analysis = "sens", outcome = o,
                                                                       case = tasks[[i]]$id), r$rows),
      iod = iod[[length(iod) + 1L]] <- cbind(data.table::data.table(outcome = o), r$rows),
      dlm = {
        meta <- r$rows[1, c("p_kind", "B_ok", "time_re", "re_used", "n", "n_units", "status", "error", "pd_hess",
                            "max_grad", "notes")]
        cv <- if (identical(r$status, "ok")) r$out else
          data.table::data.table(lag = 0:6, est = NA_real_, se = NA_real_, irr = NA_real_, lo = NA_real_, hi = NA_real_)
        dlm[[length(dlm) + 1L]] <- cbind(data.table::data.table(outcome = o), cv, meta)
      },
      het = {
        het[[o]] <- .het_row(o, r)
        modes[[o]] <- r$modes
      },
      l_lags = , l_tmax = {
        an <- if (kinds[i] == "l_lags") "l_cum02" else "l_tmax"
        l[[length(l) + 1L]] <- cbind(data.table::data.table(analysis = an, outcome = o), l_rows(r, an))
      },
      l_lags_bfgs = , l_tmax_bfgs = {
        an <- if (kinds[i] == "l_lags_bfgs") "l_cum02_bfgs" else "l_tmax_bfgs"
        bfgs[[length(bfgs) + 1L]] <- cbind(data.table::data.table(analysis = an, outcome = o), l_rows(r, an))
      },
      sl_bfgs = {
        an <- if (tasks[[i]]$id == "S") "s_bfgs" else "l_bfgs"
        terms <- if (tasks[[i]]$id == "S") S_TERMS else L_TERMS
        x <- if (identical(r$status, "ok")) data.table::copy(r$rows) else
          cbind(data.table::data.table(term = terms), .na_est("error", r$error))
        x[, case := term]
        bfgs[[length(bfgs) + 1L]] <- cbind(data.table::data.table(analysis = an, outcome = o), x)
      })
  }
  for (s in skips) sens[[length(sens) + 1L]] <- cbind(data.table::data.table(analysis = "sens", outcome = s$outcome,
                                                                             case = s$case, term = "en_t"),
                                                      .na_est("skip", NA_character_), data.table::data.table(display = s$display))
  for (o in names(het_pre)) het[[o]] <- .het_row(o, het_pre[[o]], status = "error")
  for (o in dropped) {
    sens[[length(sens) + 1L]] <- cbind(data.table::data.table(analysis = "sens", outcome = o, case = SENS_IDS, term = "en_t"),
                                       .na_est("dropped", DROPPED_REASON))
    l[[length(l) + 1L]] <- cbind(data.table::data.table(analysis = c(rep("l_cum02", 3), "l_tmax"), outcome = o,
                                                        case = c(names(L_VARS), "tmax"),
                                                        term = c(unname(L_VARS), "tmax_anom_l0")),
                                 .na_est("dropped", DROPPED_REASON))
    dlm[[length(dlm) + 1L]] <- cbind(data.table::data.table(outcome = o, lag = 0:6, est = NA_real_, se = NA_real_,
                                                            irr = NA_real_, lo = NA_real_, hi = NA_real_),
                                     .na_est("dropped", DROPPED_REASON)[, !c("est", "se", "irr", "lo", "hi", "p")])
    iod[[length(iod) + 1L]] <- cbind(data.table::data.table(outcome = o, term = c("dmi_3m", "en_t:dmi_3m")),
                                     .na_est("dropped", DROPPED_REASON))
    het[[o]] <- .het_row(o, .het_empty(DROPPED_REASON), status = "dropped")
  }
  sens <- data.table::rbindlist(sens, fill = TRUE)
  l <- data.table::rbindlist(l, fill = TRUE)
  dlm <- data.table::rbindlist(dlm, fill = TRUE)
  iod <- data.table::rbindlist(iod, fill = TRUE)
  het <- data.table::rbindlist(het, fill = TRUE)
  bfgs <- data.table::rbindlist(bfgs, fill = TRUE)
  if (nrow(bfgs)) bfgs[, note := BFGS_NOTE]
  tabs <- list(sens = sens[order(match(outcome, INDS), match(case, SENS_IDS))],
               l = l[order(match(outcome, INDS), analysis, match(case, c(names(L_VARS), "tmax")))],
               dlm = dlm[order(match(outcome, INDS), lag)],
               iod = iod[order(match(outcome, INDS), match(term, c("dmi_3m", "en_t:dmi_3m")))],
               iod_n = iod_counts(d),
               het = het[order(match(outcome, INDS))],
               bfgs = if (nrow(bfgs)) bfgs[order(match(outcome, INDS), analysis)] else bfgs)
  hm <- data.table::rbindlist(lapply(names(modes), function(o) if (!is.null(modes[[o]]))
    cbind(data.table::data.table(outcome = o), modes[[o]],
          data.table::data.table(identifiable = isTRUE(tabs$het[outcome == o]$identifiable)))), fill = TRUE)
  if (nrow(hm)) hm <- hm[order(match(outcome, INDS), unit_id)]
  entries <- secondary_entries(tabs, B = B)
  want <- secondary_contract_keys(contract)
  if (!setequal(names(entries), want))
    stop("run_secondary: keys differ from the contract: missing ", paste(setdiff(want, names(entries)), collapse = ", "),
         "; extra ", paste(setdiff(names(entries), want), collapse = ", "), call. = FALSE)

  crossings <- sens_crossings(tabs$sens, prim)
  lg(sprintf("sensitivities moving an H7/H8 point estimate across 1 (note only, no verdict): %s",
             if (nrow(crossings)) paste(sprintf("%s %s (%s vs primary %s)", crossings$outcome, crossings$case,
                                                vapply(crossings$sens_irr, .s6, ""),
                                                vapply(crossings$primary_irr, .s6, "")), collapse = "; ")
             else "none"))
  lg(sprintf("heterogeneity rule: %s", paste(sprintf("%s %s", tabs$het$outcome,
                                                     vapply(entries[sprintf("E.het.%s.identifiable", tabs$het$outcome)],
                                                            `[[`, "", "display")), collapse = "; ")))
  if (nrow(tabs$bfgs))
    lg(sprintf("F62 BFGS sensitivity (%s): %s", BFGS_NOTE,
               paste(sprintf("%s %s %s: %s", tabs$bfgs$outcome, tabs$bfgs$analysis, tabs$bfgs$case,
                             ifelse(tabs$bfgs$status == "ok", vapply(tabs$bfgs$irr, .s6, ""),
                                    paste("not estimable:", tabs$bfgs$error))), collapse = "; ")))
  runtime <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
  if (write) {
    dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
    dir.create(dirname(rds), recursive = TRUE, showWarnings = FALSE)
    sens_out <- data.table::rbindlist(list(tabs$sens, tabs$l, tabs$bfgs), fill = TRUE)
    data.table::fwrite(sens_out, file.path(out_dir, "sensitivity.csv"), eol = "\n")
    data.table::fwrite(tabs$dlm, file.path(out_dir, "dlm.csv"), eol = "\n")
    data.table::fwrite(data.table::rbindlist(list(tabs$iod, tabs$iod_n), fill = TRUE), file.path(out_dir, "iod.csv"),
                       eol = "\n")
    data.table::fwrite(tabs$het, file.path(out_dir, "heterogeneity.csv"), eol = "\n")
    data.table::fwrite(if (nrow(hm)) hm else data.table::data.table(outcome = character(), unit_id = character(),
                                                                    mode = numeric(), sd = numeric(),
                                                                    identifiable = logical()),
                       file.path(out_dir, "het_modes.csv"), eol = "\n")
    saveRDS(list(tables = tabs, entries = entries, het_modes = hm, crossings = crossings, runtime_min = runtime,
                 settings = list(cores = cores_fun(), B = B, seed = SEED_E, dropped = dropped, fy2021 = fy2021,
                                 provenance = provenance)), rds)
    lg(sprintf("run_secondary: wrote %s/{sensitivity,dlm,iod,heterogeneity,het_modes}.csv and %s (%d keys) in %.1f min",
               out_dir, rds, length(entries), runtime))
  }
  list(entries = entries, tables = tabs, crossings = crossings, het_modes = hm, runtime_min = runtime)
}

secondary_main <- function(args = commandArgs(trailingOnly = TRUE)) {
  opt <- function(name, default) {
    v <- sub(sprintf("^--%s=", name), "", grep(sprintf("^--%s=", name), args, value = TRUE))
    if (length(v)) v[length(v)] else default
  }
  cores <- opt("cores", NA)
  # detached-run progress file: RUNNING (with the pid) while it runs, then DONE or FAILED <first line of the error>
  progress <- opt("progress", file.path(E_LOGS, "secondary_progress.txt"))
  dir.create(dirname(progress), recursive = TRUE, showWarnings = FALSE)
  writeLines(c(paste("RUNNING", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), paste("pid", Sys.getpid()),
               "step log: models/E/logs/secondary.log"), progress)
  r <- tryCatch(run_secondary(cores = if (is.na(cores)) NULL else as.integer(cores), B = as.integer(opt("B", B_T)),
                              out_dir = opt("out-dir", E_OUT), rds = opt("rds", file.path(E_CACHE, "secondary.rds")),
                              resume = !"--no-resume" %in% args),
                error = function(e) {
                  writeLines(c(paste("FAILED", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), paste("pid", Sys.getpid()),
                               first_line(conditionMessage(e))), progress)
                  stop(e)
                })
  writeLines(c(paste("DONE", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), paste("pid", Sys.getpid()),
               sprintf("%d keys; %.1f min", length(r$entries), r$runtime_min)), progress)
  invisible(r)
}

if (sys.nframe() == 0L) invisible(secondary_main())
