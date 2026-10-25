# Paper E Task 8: primary Models T, S and L, the one H7-H9 Holm family and the verdicts (contract
# papers/E/results_keys.md §2-§5 and "Rules fixed before results"; spec §5.2-§5.6; rulings F18, F52-F55).
#
# Run from <repo>/models once the power design is fixed: run_primary() refuses to start unless the contract and
# models/E/01_power.R are committed and clean (assert_power_design_fixed(); controller speed ruling 2026-10-25, which
# lifted F54's wait for power.csv: the power design and run were fixed before any exposure estimate). Whether
# power.csv existed at the start is logged.
#   Rscript E/02_primary.R              # cores e_cores() (3 while the power run is alive, else detectCores() - 1),
#                                       # re-checked before any block bootstrap; B = 1,000 for a block-bootstrap step
#   --cores=N   --B=N   --out=PATH (primary_estimates.csv)   --rds=PATH (models/E/_cache/primary.rds)
#
# Models (all NB2 in glmmTMB through the common fit_nb(), unit random-effect chain us -> diag -> int):
#   Model T   t_spec(<ind>) on the primary window, through the time random-effect chain fit_time_chain() (ar1, then
#             iid); if neither converges, block_bootstrap_irr() (month blocks of 12, B = 1,000, refits without a time
#             random effect, unit random effect fixed to the structure the original rows selected; more than 10% failed
#             refits -> not estimable; F57): percentile CI and two-sided bootstrap p. The episode fit (exposure en_ep1415,
#             en_ep1819, en_other, ln_t) runs through the same chain.
#   Model S   nb_spec(<ind>, fixed = c("en_S", "ln_S", "ym_f"), slopes = "t_c", offset = "log_pop_days",
#             trend_df = 0L) on the rows with non-NA S_z (32 units); no time random effect.
#   Model L   as Model S with fixed = c("spi3_dry_l0", "spi3_wet_l0", "heatwave_days_l0", "ym_f") (the contract's
#             lag-0 columns, F52); 33 units through complete_rows().
# An outcome dropped by the Task 4 20% masking rule (gate_summary.csv, scope primary) is not fitted: every key reads
# not estimable (dropped: more than 20% of state-months masked). A genuine estimation failure (is_estimation_failure():
# no unit random-effect structure converged, a term not estimated, the bootstrap 10% rule) gives not estimable (<first
# line of the error>); any other error (missing column, no complete rows, a programming error) stops the run (F56;
# contract amendment 2). The Holm family is holm_family() over the 13 H7-H9 tests actually performed (4 H7 and 1 H8 Model T en_t
# tests, 8 H9 Model L heatwave_days_l0 / spi3_dry_l0 tests); a bootstrap p of 0 enters at 2 / B_ok.
#
# Outputs (F55; state-level estimates only, no unit conditional modes):
#   papers/E/output/primary_estimates.csv, one row per outcome x model x term: outcome, model (T, T_ep, S, L), term,
#     est and se (log scale; se is the bootstrap SD under the bootstrap step), irr, lo, hi (exp of est and of the
#     Wald or percentile bounds, on the coefficient's own orientation: the contract's exp(-beta) displays of ln_t,
#     ln_S and spi3_dry_l0 are applied only in the results keys), p, p_kind (wald / bootstrap), B_ok, time_re,
#     re_used, n (unit-months), n_units, status (ok / error / dropped), error (first line), hypothesis, p_holm_in
#     (the p entered in the Holm family), p_holm.
#   models/E/_cache/primary.rds (git-ignored): list(table, holm, entries, settings, runtime_min, time_errors).
#   run_primary() returns list(entries (the 156 §2-§5 keys this script owns), table, holm, runtime_min).

if (!exists("MODELS_ROOT")) source("common/R/load.R")
if (!exists("E_DIR")) source(file.path(MODELS_ROOT, "E", "R", "common_e.R"))
for (f in c("monthly.R", "power.R", "verdicts.R")) source(file.path(MODELS_ROOT, "E", "R", f))
if (!exists("contract_keys")) source(file.path(MODELS_ROOT, "D", "R", "contract.R"))      # read-only

PRIMARY_SCRIPT <- "models/E/02_primary.R"
GATE_SUMMARY_CSV <- file.path(REPO_ROOT, "data", "derived", "hmis", "gate_summary.csv")
DROPPED_REASON <- "dropped: more than 20% of state-months masked"
T_TERMS <- c("en_t", "ln_t")
EP_EXPOSURE <- c("en_ep1415", "en_ep1819", "en_other", "ln_t")
S_TERMS <- c("en_S", "ln_S")
L_TERMS <- c("spi3_dry_l0", "spi3_wet_l0", "heatwave_days_l0")
B_T <- 1000L
TIME_RE_DISPLAY <- c(ar1 = "AR(1) year-month random effect", iid = "independent year-month random effect")
RE_DISPLAY <- c(us = "correlated random intercept and trend slope", diag = "uncorrelated random intercept and trend slope",
                int = "random-intercept-only")

time_re_display <- function(step, B = B_T) {
  if (identical(step, "block_bootstrap")) sprintf("moving-block bootstrap over months (block 12, B = %s)", fmt_int(B))
  else TIME_RE_DISPLAY[[step]]
}

s_spec <- function(ind) nb_spec(ind, fixed = c(S_TERMS, "ym_f"), slopes = "t_c", offset = "log_pop_days", trend_df = 0L)
l_spec <- function(ind) nb_spec(ind, fixed = c(L_TERMS, "ym_f"), slopes = "t_c", offset = "log_pop_days", trend_df = 0L)
model_t_spec <- function(ind, part = c("T", "T_ep")) {
  if (match.arg(part) == "T") t_spec(ind) else t_spec(ind, exposure = EP_EXPOSURE)
}

# Outcomes dropped by the Task 4 masking rule (gate_summary.csv, scope primary, dropped TRUE).
dropped_outcomes <- function(path = GATE_SUMMARY_CSV) {
  g <- data.table::fread(path, colClasses = list(character = "dropped"))
  if (!all(INDS %in% g[scope == "primary"]$indicator)) stop("dropped_outcomes: ", path, " lacks an outcome", call. = FALSE)
  g[scope == "primary" & tolower(dropped) == "true"]$indicator
}

# ---- result rows --------------------------------------------------------------------------------------------------

.rows_na <- function(ind, model, terms, status, error) {
  data.table::data.table(outcome = ind, model = model, term = terms, est = NA_real_, se = NA_real_, irr = NA_real_,
                         lo = NA_real_, hi = NA_real_, p = NA_real_, p_kind = NA_character_, B_ok = NA_integer_,
                         time_re = NA_character_, re_used = NA_character_, n = NA_integer_, n_units = NA_integer_,
                         status = status, error = error, pd_hess = NA, max_grad = NA_real_)
}

.rows_wald <- function(fit, ind, model, terms, time_re = NA_character_) {
  r <- term_row(fit, terms)
  data.table::data.table(outcome = ind, model = model, term = terms, est = r$est, se = r$se, irr = r$irr, lo = r$lo,
                         hi = r$hi, p = r$p, p_kind = "wald", B_ok = NA_integer_, time_re = time_re,
                         re_used = fit$re_used, n = as.integer(fit$n), n_units = nlevels(fit$data$unit_id),
                         status = "ok", error = NA_character_, pd_hess = isTRUE(fit$model$sdr$pdHess),
                         max_grad = max(abs(fit$model$sdr$gradient.fixed)))
}

.rows_boot <- function(bb, ind, model, terms) {
  data.table::data.table(outcome = ind, model = model, term = terms, est = unname(bb$est[terms]),
                         se = unname(bb$se[terms]), irr = unname(bb$irr[terms]), lo = unname(bb$lo[terms]),
                         hi = unname(bb$hi[terms]), p = unname(bb$p[terms]), p_kind = "bootstrap",
                         B_ok = as.integer(bb$B_ok), time_re = "block_bootstrap", re_used = bb$re_used,
                         n = as.integer(bb$n), n_units = as.integer(bb$n_units), status = "ok", error = NA_character_,
                         pd_hess = if (is.null(bb$pd_hess)) NA else bb$pd_hess,
                         max_grad = if (is.null(bb$max_grad)) NA_real_ else bb$max_grad)
}

# ---- Model T ------------------------------------------------------------------------------------------------------

# One Model T fit (part "T": en_t, ln_t; part "T_ep": the episode exposure) through the time random-effect chain.
# Returns a light record (no model object): status "ok" (rows), "chain_failed" (neither ar1 nor iid converged: the
# block bootstrap is next) or "error" (another estimation failure, e.g. a term dropped as rank-deficient; error = its
# first line). Any error that is not an estimation failure (is_estimation_failure(); F56) is re-raised.
model_t_part <- function(d, ind, part = c("T", "T_ep"), fit_fun = e_glmmTMB_fit) {
  part <- match.arg(part)
  spec <- model_t_spec(ind, part)
  terms <- if (part == "T") T_TERMS else EP_EXPOSURE
  out <- list(ind = ind, part = part, spec = spec, terms = terms)
  catch_estimation_failure({
    f <- fit_time_chain(spec, d, fit_fun = fit_fun)
    c(out, list(status = "ok", rows = .rows_wald(f, ind, part, terms, f$time_re), time_errors = f$time_errors))
  }, function(e) {
    msg <- conditionMessage(e)
    chain <- grepl("next step: block_bootstrap", msg, fixed = TRUE)
    c(out, list(status = if (chain) "chain_failed" else "error", error = first_line(msg), message = msg,
                rows = .rows_na(ind, part, terms, "error", first_line(msg))))
  })
}

# Progress callback for the block bootstrap: logs "<label>: block bootstrap k of n refits" each time k crosses a
# multiple of `every` (and at k = n).
boot_progress_logger <- function(label, every = 50L, log_fun = function(...) elog(..., file = "primary.log")) {
  last <- 0L
  function(k, n) {
    if (k %/% every > last %/% every || (k == n && last < n)) {
      log_fun(sprintf("%s: block bootstrap %d of %d refits", label, as.integer(k), as.integer(n)))
      last <<- k
    }
    invisible(NULL)
  }
}

# A model_t_part() record resolved to rows: a converged chain as it is; a failed chain through boot_fun (the block
# bootstrap, B refits, progress logged every 50 to primary.log). A bootstrap estimation failure (F57: more than 10%
# of the refits failed; the fit on the original rows did not converge) makes the rows not estimable, with B_ok
# recorded when known; any other error is re-raised (F56).
model_t_resolve <- function(part, d, B = B_T, block = 12L, seed = SEED_E, cores = 1L, fit_fun = e_glmmTMB_fit,
                            boot_fun = block_bootstrap_irr,
                            log_fun = function(...) elog(..., file = "primary.log")) {
  if (!identical(part$status, "chain_failed")) return(part$rows)
  label <- paste(part$ind, part$part)
  # the distinct first lines of the failed refits, with their counts, go to primary.log
  log_errors <- function(counts, B_ok) {
    log_fun(sprintf("%s: block bootstrap %s of %d refits succeeded", label,
                    if (is.null(B_ok)) "?" else as.character(B_ok), as.integer(B)))
    for (k in seq_along(counts))
      log_fun(sprintf("%s: block bootstrap refit errors: %d x %s", label, as.integer(counts[[k]]), names(counts)[k]))
  }
  catch_estimation_failure({
    bb <- boot_fun(part$spec, d, part$terms, B = B, block = block, seed = seed, cores = cores, fit_fun = fit_fun,
                   progress = boot_progress_logger(label, log_fun = log_fun))
    log_errors(bb$error_counts, bb$B_ok)
    .rows_boot(bb, part$ind, part$part, part$terms)
  }, function(e) {
    log_fun(sprintf("%s: not estimable: %s", label, first_line(conditionMessage(e))))
    if (!is.null(e$error_counts)) log_errors(e$error_counts, e$B_ok)
    r <- .rows_na(part$ind, part$part, part$terms, "error", first_line(conditionMessage(e)))
    if (!is.null(e$B_ok)) r[, B_ok := as.integer(e$B_ok)]
    r
  })
}

# Model T for one outcome: the primary fit (en_t, ln_t) and the episode fit, each through the time random-effect
# chain with the block bootstrap as its last step. `parts` (list(T =, T_ep =) of model_t_part() records) lets
# run_primary() fit the chains in parallel first. Returns list(rows (model T: en_t, ln_t; model T_ep: en_ep1415,
# en_ep1819, en_other, ln_t), time_re, re_used, n, error (NA if estimated), ep_time_re, ep_error, time_errors).
fit_model_t <- function(d, ind, B = B_T, block = 12L, seed = SEED_E, cores = 1L, fit_fun = e_glmmTMB_fit,
                        boot_fun = block_bootstrap_irr, parts = NULL,
                        log_fun = function(...) elog(..., file = "primary.log")) {
  if (is.null(parts)) parts <- list(T = model_t_part(d, ind, "T", fit_fun), T_ep = model_t_part(d, ind, "T_ep", fit_fun))
  res <- lapply(parts[c("T", "T_ep")], model_t_resolve, d = d, B = B, block = block, seed = seed, cores = cores,
                fit_fun = fit_fun, boot_fun = boot_fun, log_fun = log_fun)
  t1 <- res$T[1]; e1 <- res$T_ep[1]
  list(rows = data.table::rbindlist(res), time_re = t1$time_re, re_used = t1$re_used, n = t1$n, error = t1$error,
       ep_time_re = e1$time_re, ep_error = e1$error,
       time_errors = list(T = parts$T$time_errors, T_ep = parts$T_ep$time_errors))
}

# ---- Models S and L -----------------------------------------------------------------------------------------------

.fit_fixed_ym <- function(d, ind, model, spec, terms, fit_fun) {
  fit_fun <- e_fitter(fit_fun)                        # the Paper E optimiser limits (F61)
  # only an estimation failure is not estimable; any other error stops the run (F56)
  rows <- catch_estimation_failure(.rows_wald(fit_nb(spec, d, fitter = fit_fun), ind, model, terms),
                                   function(e) .rows_na(ind, model, terms, "error", first_line(conditionMessage(e))))
  list(rows = rows, re_used = rows$re_used[1], n = rows$n[1], n_units = rows$n_units[1], error = rows$error[1])
}

# Model S (spec §5.3): differential association by the state rainfall sensitivity S_z; rows with non-NA S_z.
fit_model_s <- function(d, ind, fit_fun = e_glmmTMB_fit)
  .fit_fixed_ym(d[!is.na(S_z)], ind, "S", s_spec(ind), S_TERMS, fit_fun)

# Model L (spec §5.4): concurrent local climate within the same calendar month (year-month fixed effects).
fit_model_l <- function(d, ind, fit_fun = e_glmmTMB_fit)
  .fit_fixed_ym(d, ind, "L", l_spec(ind), L_TERMS, fit_fun)

# ---- Holm family and the results keys ------------------------------------------------------------------------------

# The 13 H7-H9 tests (rows in the contract's order), with the p entered (a bootstrap p of 0 at 2 / B_ok) and p_holm.
primary_holm <- function(tab) {
  pick <- function(o, m, tm) {
    r <- tab[outcome == o & model == m & term == tm]
    if (nrow(r) != 1L) stop(sprintf("primary_holm: %d rows for %s %s %s", nrow(r), o, m, tm), call. = FALSE)
    r
  }
  spec <- rbind(data.table::data.table(hypothesis = "H7", outcome = H7_INDS, model = "T", term = "en_t", direction = "lt"),
                data.table::data.table(hypothesis = "H8", outcome = "diarr_u5", model = "T", term = "en_t", direction = "gt"),
                data.table::data.table(hypothesis = "H9", outcome = rep(H7_INDS, each = 2L), model = "L",
                                       term = rep(c("heatwave_days_l0", "spi3_dry_l0"), length(H7_INDS)),
                                       direction = rep(c("lt", "gt"), length(H7_INDS))))
  rows <- data.table::rbindlist(lapply(seq_len(nrow(spec)), function(i) {
    r <- pick(spec$outcome[i], spec$model[i], spec$term[i])
    ok <- identical(r$status, "ok")
    data.table::data.table(est = if (ok) r$est else NA_real_, p_raw = if (ok) r$p else NA_real_, p_kind = r$p_kind,
                           B_ok = r$B_ok)
  }))
  tests <- cbind(data.table::data.table(test_id = seq_len(nrow(spec))), spec, rows)
  tests[, at_bound := !is.na(p_raw) & p_kind %in% "bootstrap" & p_raw == 0]
  tests[, p := holm_input_p(p_raw, p_kind, B_ok)]
  holm_family(tests)
}

# Units of Models S and L (from the data: S needs S_z; L needs all three local-climate terms).
primary_units <- function(d) {
  all_u <- levels(droplevels(d$unit_id))
  su <- unique(as.character(d[!is.na(S_z)]$unit_id))
  lu <- unique(as.character(d[!is.na(spi3_dry_l0) & !is.na(spi3_wet_l0) & !is.na(heatwave_days_l0)]$unit_id))
  list(s = list(n = length(su), excluded = setdiff(all_u, su)), l = list(n = length(lu), excluded = setdiff(all_u, lu)))
}

# The contract keys this script owns: §2 Model T, §3 verdicts, §4 Model S and the lag-0 §5 Model L keys (cum02 and
# tmax are 04_secondary.R's).
primary_contract_keys <- function(path = file.path(PAPER_E, "results_keys.md")) {
  k <- contract_keys(path, prefix = "E")
  k[grepl("^E\\.(t|h7|h8|h9|s|l)\\.", k) & !grepl("\\.cum02$|\\.tmax\\.", k)]
}

.s6 <- function(x) if (is.na(x)) "NA" else format(signif(x, 6), scientific = FALSE, trim = TRUE)

.model_text <- function(r) {
  o <- r$outcome
  switch(r$model,
    T = sprintf("Model T (t_spec(\"%s\"): en_t + ln_t + moy + t_c + %s + offset(log_pop_days) + (1 + t_c | unit_id) + time RE; NB2, glmmTMB, fit_nb; primary window)",
                o, paste(programme_terms(o), collapse = " + ")),
    T_ep = sprintf("Model T episode fit (en_ep1415 + en_ep1819 + en_other + ln_t + moy + t_c + %s + offset(log_pop_days) + (1 + t_c | unit_id) + time RE; same chain)",
                   paste(programme_terms(o), collapse = " + ")),
    S = "Model S (en_S + ln_S + ym_f fixed + offset(log_pop_days) + (1 + t_c | unit_id); rows with non-NA S_z; no time RE)",
    L = "Model L (spi3_dry_l0 + spi3_wet_l0 + heatwave_days_l0 + ym_f fixed + offset(log_pop_days) + (1 + t_c | unit_id); concurrent month; no time RE)")
}

.estimate_text <- function(r) {
  boot <- identical(r$p_kind, "bootstrap")
  step <- if (is.na(r$time_re)) "none (year-month fixed effects)" else r$time_re
  sprintf(paste("%s; %s unit-months, %s units; time random effect: %s; unit random effect: %s; %s beta = %s, SE = %s%s;",
                "IRR %s (%s %s to %s); p = %s (%s)"),
          .model_text(r), fmt_int(r$n), r$n_units, step, r$re_used, r$term, .s6(r$est), .s6(r$se),
          if (boot) " (bootstrap SD)" else "", .s6(r$irr),
          if (boot) sprintf("percentile 95%% CI over %d successful month-block resamples, block 12, seeds SEED_E + i - 1 = %d + i - 1;",
                            r$B_ok, SEED_E) else "Wald 95% CI", .s6(r$lo), .s6(r$hi), .s6(r$p),
          if (boot) "two-sided bootstrap p, 2 x min(share <= 0, share >= 0)" else "two-sided Wald")
}

# The §2-§5 entries owned by 02_primary.R (156 keys) from the primary table, the Holm tests and the unit counts.
primary_entries <- function(tab, holm, units, script = PRIMARY_SCRIPT, B = B_T) {
  E <- list()
  put <- function(k, value, display, description) E[[k]] <<- res_entry(value, display, script, description)
  row <- function(o, m, tm) {
    r <- tab[outcome == o & model == m & term == tm]
    if (nrow(r) != 1L) stop(sprintf("primary_entries: %d rows for %s %s %s", nrow(r), o, m, tm), call. = FALSE)
    r
  }
  ok <- function(r) identical(r$status, "ok") && !is.na(r$est)
  reason <- function(r) if (!is.na(r$error)) r$error else "estimate missing"
  ne <- function(k, r, what)
    put(k, NA, not_estimable(reason(r)),
        sprintf("%s: %s (%s)%s", what, not_estimable(reason(r)), .model_text(r),
                if (!is.na(r$B_ok)) sprintf("; block bootstrap: %d of %d refits succeeded", r$B_ok, B) else ""))
  irr_key <- function(k, r, what, flip = FALSE) {
    if (!ok(r)) return(ne(k, r, what))
    est <- r$irr; lo <- r$lo; hi <- r$hi
    if (flip) { est <- 1 / r$irr; lo <- 1 / r$hi; hi <- 1 / r$lo }
    put(k, est, fmt_ci(est, lo, hi, 2),
        sprintf("%s%s. %s", what, if (flip) sprintf("; displayed as exp(-beta) = %s with the bounds swapped (%s to %s)",
                                                     .s6(est), .s6(lo), .s6(hi)) else "", .estimate_text(r)))
  }
  p_key <- function(k, r, what) {
    if (!ok(r)) return(ne(k, r, what))
    put(k, r$p, p_display(r$p, r$p_kind, r$B_ok), sprintf("%s. %s", what, .estimate_text(r)))
  }
  m_tests <- sum(!is.na(holm$p))
  holm_key <- function(k, h, r, what) {
    if (is.na(h$p)) return(ne(k, r, what))
    put(k, h$p_holm, p_holm_display(h$p_holm, h$at_bound),
        sprintf("%s: Holm-adjusted p = %s (stats::p.adjust, method holm) over the %d performed H7-H9 tests; p entered = %s%s",
                what, .s6(h$p_holm), m_tests, .s6(h$p),
                if (isTRUE(h$at_bound)) sprintf(" (bootstrap p 0 entered at its bound 2 / B_ok = 2 / %d)", h$B_ok) else ""))
  }
  hrow <- function(hyp, o, tm) holm[hypothesis == hyp & outcome == o & term == tm]
  v_irr <- function(r) if (ok(r)) r$irr else NA_real_

  # §2 Model T
  for (o in INDS) {
    en <- row(o, "T", "en_t"); ln <- row(o, "T", "ln_t")
    e1 <- row(o, "T_ep", "en_ep1415"); e2 <- row(o, "T_ep", "en_ep1819")
    irr_key(sprintf("E.t.%s.irr_en", o), en, sprintf("Model T IRR per +1 deg C of the El Nino term en_t, %s", o))
    irr_key(sprintf("E.t.%s.irr_en.ep1415", o), e1, sprintf("Model T episode IRR per +1 deg C, en_ep1415 (Oct 2014 to Dec 2016), %s", o))
    irr_key(sprintf("E.t.%s.irr_en.ep1819", o), e2, sprintf("Model T episode IRR per +1 deg C, en_ep1819 (Sep 2018 to Feb 2020), %s", o))
    p_key(sprintf("E.t.%s.p_en", o), en, sprintf("Two-sided p of en_t, Model T, %s", o))
    k <- sprintf("E.t.%s.p_en_holm", o)
    if (o %in% PRIMARY5) {
      holm_key(k, hrow(if (o == "diarr_u5") "H8" else "H7", o, "en_t"), en, sprintf("Model T en_t, %s", o))
    } else if (identical(en$status, "dropped")) {
      ne(k, en, sprintf("Holm-adjusted p of en_t, %s", o))
    } else {
      put(k, NA, "not applicable (secondary outcome; outside the Holm family)",
          sprintf("%s is a secondary outcome: no verdict, not in the H7-H9 Holm family", o))
    }
    irr_key(sprintf("E.t.%s.irr_ln", o), ln,
            sprintf("Model T IRR per 1 deg C cooler La Nina term ln_t, %s; the term is weakly identified (6 primary months with ONI <= -0.5)", o),
            flip = TRUE)
    k <- sprintf("E.t.%s.time_re", o)
    if (ok(en)) put(k, en$time_re, time_re_display(en$time_re, B),
                    sprintf("Time random-effect step used by Model T for %s (chain ar1 -> iid -> block bootstrap); episode fit step: %s%s",
                            o, if (ok(e1)) e1$time_re else not_estimable(reason(e1)),
                            if (identical(en$p_kind, "bootstrap")) sprintf("; %d of %d resamples succeeded", en$B_ok, B) else ""))
    else ne(k, en, sprintf("Model T time random-effect step, %s", o))
    k <- sprintf("E.t.%s.re_used", o)
    if (ok(en)) put(k, en$re_used, RE_DISPLAY[[en$re_used]],
                    sprintf("Unit random-effect structure used by Model T for %s (fit_nb chain us -> diag -> int)", o))
    else ne(k, en, sprintf("Model T unit random-effect structure, %s", o))
    k <- sprintf("E.t.%s.n", o)
    if (ok(en)) put(k, en$n, fmt_int(en$n), sprintf("Unit-months in the primary Model T fit for %s (%d units)", o, en$n_units))
    else ne(k, en, sprintf("Model T unit-months, %s", o))
  }

  # §3 verdicts
  v7 <- character()
  for (o in H7_INDS) {
    en <- row(o, "T", "en_t"); h <- hrow("H7", o, "en_t")
    e1 <- row(o, "T_ep", "en_ep1415"); e2 <- row(o, "T_ep", "en_ep1819")
    v7[[o]] <- verdict_h7(v_irr(en), h$p_holm, v_irr(e1), v_irr(e2))
    put(sprintf("E.h7.%s.verdict", o), v7[[o]], v7[[o]],
        sprintf("H7 verdict for %s: en_t IRR %s, Holm p %s, episode IRRs %s and %s (consistent iff IRR < 1, Holm p < 0.05 and both episode IRRs < 1)",
                o, .s6(v_irr(en)), .s6(h$p_holm), .s6(v_irr(e1)), .s6(v_irr(e2))))
  }
  ov7 <- overall_verdict(v7, hypothesis = "H7")
  put("E.h7.verdict", ov7$verdict, ov7$verdict, "Overall H7 verdict: consistent with if at least one service outcome is")
  put("E.h7.verdict_text", ov7$text, ov7$text, "Overall H7 verdict naming the consistent outcomes (contract §3 template)")
  en <- row("diarr_u5", "T", "en_t"); h <- hrow("H8", "diarr_u5", "en_t")
  e1 <- row("diarr_u5", "T_ep", "en_ep1415"); e2 <- row("diarr_u5", "T_ep", "en_ep1819")
  v8 <- verdict_h8(v_irr(en), h$p_holm, v_irr(e1), v_irr(e2))
  put("E.h8.verdict", v8, v8,
      sprintf("H8 verdict (diarr_u5): en_t IRR %s, Holm p %s, episode IRRs %s and %s (consistent iff IRR > 1, Holm p < 0.05 and both episode IRRs > 1)",
              .s6(v_irr(en)), .s6(h$p_holm), .s6(v_irr(e1)), .s6(v_irr(e2))))
  v9 <- character()
  for (o in H7_INDS) {
    hw <- row(o, "L", "heatwave_days_l0"); dry <- row(o, "L", "spi3_dry_l0")
    hh <- hrow("H9", o, "heatwave_days_l0"); hd <- hrow("H9", o, "spi3_dry_l0")
    v9[[o]] <- verdict_h9(v_irr(hw), hh$p_holm, if (ok(dry)) dry$est else NA_real_, hd$p_holm)
    put(sprintf("E.h9.%s.verdict", o), v9[[o]], v9[[o]],
        sprintf("H9 verdict for %s: heatwave IRR %s (Holm p %s); spi3_dry beta %s (Holm p %s); consistent iff (IRR < 1 and Holm p < 0.05) or (beta > 0 and Holm p < 0.05)",
                o, .s6(v_irr(hw)), .s6(hh$p_holm), .s6(if (ok(dry)) dry$est else NA_real_), .s6(hd$p_holm)))
    holm_key(sprintf("E.h9.%s.hw.p_holm", o), hh, hw, sprintf("Model L heatwave_days_l0, %s", o))
    holm_key(sprintf("E.h9.%s.dry.p_holm", o), hd, dry, sprintf("Model L spi3_dry_l0, %s", o))
  }
  ov9 <- overall_verdict(v9, hypothesis = "H9")
  put("E.h9.verdict", ov9$verdict, ov9$verdict, "Overall H9 verdict: consistent with if at least one service outcome is")
  put("E.h9.verdict_text", ov9$text, ov9$text, "Overall H9 verdict naming the consistent outcomes (contract §3 template)")

  # §4 Model S
  for (o in INDS) {
    s <- row(o, "S", "en_S"); sl <- row(o, "S", "ln_S")
    irr_key(sprintf("E.s.%s.irr", o), s, sprintf("Model S IRR of en_S per +1 deg C El Nino-phase ONI per +1 SD S_z, %s", o))
    irr_key(sprintf("E.s.%s.irr_ln", o), sl, sprintf("Model S IRR of ln_S per 1 deg C cooler per +1 SD S_z, %s", o), flip = TRUE)
    p_key(sprintf("E.s.%s.p", o), s, sprintf("Two-sided Wald p of en_S, Model S, %s", o))
    en <- row(o, "T", "en_t")
    rd <- reading_rule_s(if (o %in% H7_INDS) v7[[o]] else NA_character_, if (ok(s)) s$irr else NA_real_,
                         if (ok(s)) s$lo else NA_real_, if (ok(s)) s$hi else NA_real_, v_irr(en),
                         s_reason = if (ok(s)) NA_character_ else reason(s))
    put(sprintf("E.s.%s.reading", o), rd, rd,
        sprintf("Model S reading rule for %s: H7 verdict %s; Model S en_S IRR %s (%s to %s); Model T en_t IRR %s",
                o, if (o %in% H7_INDS) v7[[o]] else "none (outside H7)", .s6(if (ok(s)) s$irr else NA_real_),
                .s6(if (ok(s)) s$lo else NA_real_), .s6(if (ok(s)) s$hi else NA_real_), .s6(v_irr(en))))
  }
  put("E.s.n_units", units$s$n, fmt_int(units$s$n),
      sprintf("Units in Model S (rows with non-NA S_z); excluded by rule (no S_z): %s", paste(units$s$excluded, collapse = ", ")))

  # §5 Model L (lag 0)
  for (o in INDS) {
    hw <- row(o, "L", "heatwave_days_l0"); dry <- row(o, "L", "spi3_dry_l0"); wet <- row(o, "L", "spi3_wet_l0")
    irr_key(sprintf("E.l.%s.hw.irr", o), hw, sprintf("Model L IRR per additional heatwave day (heatwave_days_l0), %s", o))
    irr_key(sprintf("E.l.%s.dry.irr", o), dry,
            sprintf("Model L IRR per one SPI-3 unit more deficit (spi3_dry_l0; the verdict uses beta > 0), %s", o), flip = TRUE)
    irr_key(sprintf("E.l.%s.wet.irr", o), wet, sprintf("Model L IRR per +1 SPI-3 unit of excess (spi3_wet_l0), no verdict, %s", o))
    p_key(sprintf("E.l.%s.hw.p", o), hw, sprintf("Two-sided Wald p of heatwave_days_l0 (unadjusted), Model L, %s", o))
    p_key(sprintf("E.l.%s.dry.p", o), dry, sprintf("Two-sided Wald p of spi3_dry_l0 (unadjusted), Model L, %s", o))
    p_key(sprintf("E.l.%s.wet.p", o), wet, sprintf("Two-sided Wald p of spi3_wet_l0, Model L, %s", o))
  }
  put("E.l.n_units", units$l$n, fmt_int(units$l$n),
      sprintf("Units in Model L (rows complete on spi3_dry_l0, spi3_wet_l0, heatwave_days_l0 through complete_rows()); excluded (rain masked): %s",
              paste(units$l$excluded, collapse = ", ")))
  E[order(names(E), method = "radix")]
}

# ---- run ----------------------------------------------------------------------------------------------------------

# PSOCK worker set-up for the primary fits: the Paper E helpers (.e_worker_init, power.R) plus this script.
.e_primary_init <- function(root) {
  loadNamespace("data.table")       # a data.table shipped before the namespace is loaded would index as a data.frame
  source(file.path(root, "E", "02_primary.R"))
  invisible(TRUE)
}
.e_set_global <- function(name, value) {
  assign(name, value, envir = globalenv())
  invisible(NULL)
}

# One parallel task: a Model T chain (T or T_ep), Model S or Model L for one outcome; logged to primary.log.
.e_primary_task <- function(task) {
  d <- data.table::copy(get(".E_PRIMARY_DATA", envir = globalenv()))   # a valid data.table on the worker
  t0 <- Sys.time()
  r <- switch(task$part,
              T = , T_ep = model_t_part(d, task$ind, task$part),
              S = fit_model_s(d, task$ind),
              L = fit_model_l(d, task$ind))
  st <- if (!is.null(r$status)) r$status else if (is.na(r$error)) "ok" else "error"
  rw <- r$rows[1]
  elog(sprintf("%s %s: %s in %.1f min; pdHess %s; max|gradient| %s; unit RE %s; time RE %s; n %s%s", task$ind, task$part,
               st, as.numeric(difftime(Sys.time(), t0, units = "mins")), rw$pd_hess, format(signif(rw$max_grad, 3)),
               rw$re_used, rw$time_re, rw$n, if (is.na(rw$error)) "" else paste0("; ", rw$error)),
       file = "primary.log")
  r
}

# The power design is fixed before any Model T estimate (spec §5.8 ordering; controller speed ruling 2026-10-25,
# replacing the wait for power.csv): the contract and models/E/01_power.R are tracked and have no uncommitted change.
# git(args) runs git in the repository and returns its output lines (injectable for tests). Returns the last commit
# touching them.
.git_repo <- function(args) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(REPO_ROOT), args), stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status")
  if (!is.null(st) && st != 0L) stop("git ", paste(args, collapse = " "), " failed: ", paste(out, collapse = "; "),
                                     call. = FALSE)
  out
}
assert_power_design_fixed <- function(paths = c("papers/E/results_keys.md", "models/E/01_power.R"), git = .git_repo) {
  for (p in paths) {
    if (!length(git(c("ls-files", "--", p)))) stop("run_primary: ", p, " is not committed", call. = FALSE)
    if (length(git(c("status", "--porcelain", "--", p))))
      stop("run_primary: ", p, " has uncommitted changes", call. = FALSE)
  }
  log1 <- git(c("log", "-1", shQuote("--format=%h %ci %s"), "--", paths))
  sprintf("%s committed (last: %s)", paste(paths, collapse = " and "), if (length(log1)) log1[1] else "?")
}

run_primary <- function(cores = NULL, power_csv = file.path(E_OUT, "power.csv"),
                        out_csv = file.path(E_OUT, "primary_estimates.csv"), rds = file.path(E_CACHE, "primary.rds"),
                        gate_csv = GATE_SUMMARY_CSV, contract = file.path(PAPER_E, "results_keys.md"), B = B_T,
                        write = TRUE, d = NULL, check_design = assert_power_design_fixed) {
  design <- check_design()
  t0 <- Sys.time()
  # cores NULL: e_cores() now, and again before any block bootstrap (it rises when the power run ends)
  cores_fun <- if (is.null(cores)) function() e_cores() else { cores <- as.integer(cores); function() cores }
  cores <- cores_fun()
  elog(sprintf("run_primary: %s; power.csv %s at start (%s)", design,
               if (file.exists(power_csv)) "exists" else "does not exist yet", power_csv), file = "primary.log")
  if (is.null(d)) d <- read_hmis_model("primary")
  dropped <- intersect(INDS, dropped_outcomes(gate_csv))
  live <- setdiff(INDS, dropped)
  elog(sprintf("run_primary: start; cores %d; B %d; dropped: %s", cores, B,
               if (length(dropped)) paste(dropped, collapse = ", ") else "none"), file = "primary.log")
  tasks <- unlist(lapply(c("T", "T_ep", "S", "L"), function(p) lapply(live, function(o) list(ind = o, part = p))),
                  recursive = FALSE)
  if (cores > 1L && length(tasks)) {
    cl <- .e_cluster(min(cores, length(tasks)))
    fits <- tryCatch({
      parallel::clusterCall(cl, .e_primary_init, MODELS_ROOT)
      parallel::clusterCall(cl, .e_set_global, ".E_PRIMARY_DATA", d)
      parallel::clusterApplyLB(cl, tasks, .e_primary_task)
    }, finally = parallel::stopCluster(cl))
  } else {
    assign(".E_PRIMARY_DATA", d, envir = globalenv())
    fits <- lapply(tasks, .e_primary_task)
  }
  key <- vapply(tasks, function(t) paste(t$ind, t$part), "")
  names(fits) <- key
  rows <- list()
  time_errors <- list()
  for (o in INDS) {
    if (o %in% dropped) {
      rows[[o]] <- data.table::rbindlist(list(.rows_na(o, "T", T_TERMS, "dropped", DROPPED_REASON),
                                              .rows_na(o, "T_ep", EP_EXPOSURE, "dropped", DROPPED_REASON),
                                              .rows_na(o, "S", S_TERMS, "dropped", DROPPED_REASON),
                                              .rows_na(o, "L", L_TERMS, "dropped", DROPPED_REASON)))
      next
    }
    parts <- list(T = fits[[paste(o, "T")]], T_ep = fits[[paste(o, "T_ep")]])
    for (p in names(parts)) if (identical(parts[[p]]$status, "chain_failed"))
      elog(sprintf("%s %s: time random-effect chain failed (%s); block bootstrap, B = %d, %d cores", o, p,
                   parts[[p]]$error, B, cores), file = "primary.log")
    mt <- fit_model_t(d, o, B = B, cores = if (any(vapply(parts, function(p) identical(p$status, "chain_failed"), NA)))
                        cores_fun() else 1L, parts = parts)
    time_errors[[o]] <- mt$time_errors
    rows[[o]] <- data.table::rbindlist(list(mt$rows, fits[[paste(o, "S")]]$rows, fits[[paste(o, "L")]]$rows))
  }
  tab <- data.table::rbindlist(rows)
  holm <- primary_holm(tab)
  tab <- merge(tab, holm[, .(outcome, model, term, hypothesis, p_holm_in = p, p_holm)], by = c("outcome", "model", "term"),
               all.x = TRUE, sort = FALSE)
  tab <- tab[order(match(outcome, INDS), match(model, c("T", "T_ep", "S", "L")))]
  entries <- primary_entries(tab, holm, primary_units(d), B = B)
  want <- primary_contract_keys(contract)
  if (!setequal(names(entries), want))
    stop("run_primary: keys differ from the contract: missing ", paste(setdiff(want, names(entries)), collapse = ", "),
         "; extra ", paste(setdiff(names(entries), want), collapse = ", "), call. = FALSE)
  runtime <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
  if (write) {
    dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)
    dir.create(dirname(rds), recursive = TRUE, showWarnings = FALSE)
    data.table::fwrite(tab, out_csv, eol = "\n")
    saveRDS(list(table = tab, holm = holm, entries = entries, time_errors = time_errors, runtime_min = runtime,
                 settings = list(cores = cores, B = B, seed = SEED_E, dropped = dropped)), rds)
    elog(sprintf("run_primary: wrote %s and %s (%d keys) in %.1f min", out_csv, rds, length(entries), runtime),
         file = "primary.log")
  }
  list(entries = entries, table = tab, holm = holm, runtime_min = runtime)
}

primary_main <- function(args = commandArgs(trailingOnly = TRUE)) {
  opt <- function(name, default) {
    v <- sub(sprintf("^--%s=", name), "", grep(sprintf("^--%s=", name), args, value = TRUE))
    if (length(v)) v[length(v)] else default
  }
  cores <- opt("cores", NA)
  r <- run_primary(cores = if (is.na(cores)) NULL else as.integer(cores), B = as.integer(opt("B", B_T)),
                   out_csv = opt("out", file.path(E_OUT, "primary_estimates.csv")),
                   rds = opt("rds", file.path(E_CACHE, "primary.rds")))
  v <- vapply(c("E.h7.verdict_text", "E.h8.verdict", "E.h9.verdict_text"), function(k) r$entries[[k]]$display, "")
  elog("verdicts: ", paste(names(v), v, sep = " = ", collapse = "; "), file = "primary.log")
  invisible(r)
}

if (sys.nframe() == 0L) invisible(primary_main())
