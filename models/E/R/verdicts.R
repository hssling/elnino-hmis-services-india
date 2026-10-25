# Paper E Task 8: the H7-H9 Holm family, the verdict rules, the Model S reading rule and the fixed null displays
# (contract papers/E/results_keys.md: "Rules fixed before results (stated verbatim)", Conventions, §3; rulings F18,
# F52). Pure functions, no model fits. Sourced after common/R/load.R and common_e.R.

VERDICT_YES <- "consistent with"
VERDICT_NO <- "not consistent with"

# Outcome labels used in text (contract "Common definitions"), in the canonical order of INDS.
OUTCOME_LABELS <- c(diarr_u5 = "diarrhoea in children under 5 years", anc_reg = "ANC registration",
                    penta3 = "third dose of a DPT-containing vaccine", mcv1 = "first dose of a measles-containing vaccine",
                    fic = "full immunisation", inst_del = "institutional deliveries", opd = "outpatient attendance")

# Fixed vocabulary for an estimate or p that cannot be produced (F18).
not_estimable <- function(reason) sprintf("not estimable (%s)", reason)

# The first line of an error message, trimmed (the F18 <reason>).
first_line <- function(msg) trimws(sub("[\r\n].*$", "", as.character(msg)))

# Genuine estimation failures (ruling F56; contract amendment 2): only these make a test or key not estimable. Every
# other error (a missing column, no complete rows, a programming error) stops the run.
ESTIMATION_FAILURE_PATTERNS <- c(
  "^fit_nb: no structure converged",                          # no unit random-effect structure converged
  "^fit_time_chain: no time random effect converged",         # chain exhausted (the block bootstrap is next)
  "^block_bootstrap_irr: every bootstrap refit failed",
  "^block_bootstrap_irr: term\\(s\\) not estimated",
  "^block bootstrap: more than 10% of refits failed",         # F57
  "^term_row: term\\(s\\) not in model",                      # a rank-deficient term dropped by glmmTMB
  "^mediate: a-path fit did not converge",
  "^mediate: a-path fit failed",                              # the a-path fitter raised (common .fit_a_path)
  "^mediate: .* coefficient '.*' is unidentified \\(NA\\)")

is_estimation_failure <- function(msg) {
  msg <- first_line(if (inherits(msg, "condition")) conditionMessage(msg) else msg)
  any(vapply(ESTIMATION_FAILURE_PATTERNS, grepl, NA, x = msg))
}

# Evaluate expr; an estimation failure is passed to on_failure(condition), any other error is re-raised.
catch_estimation_failure <- function(expr, on_failure) {
  tryCatch(expr, error = function(e) if (is_estimation_failure(e)) on_failure(e) else stop(e))
}

# The one Holm family over every H7-H9 test performed: stats::p.adjust(method = "holm") over the non-NA p only; a
# not-estimable test (p NA) has p_holm NA and leaves the family. Rows and every other column are kept.
holm_family <- function(tests) {
  t <- data.table::copy(data.table::as.data.table(tests))
  need <- c("test_id", "hypothesis", "outcome", "est", "p", "direction")
  miss <- setdiff(need, names(t))
  if (length(miss)) stop("holm_family: missing column(s): ", paste(miss, collapse = ", "), call. = FALSE)
  if (any(!is.na(t$p) & (t$p < 0 | t$p > 1))) stop("holm_family: p must lie in [0, 1]", call. = FALSE)
  t[, p_holm := NA_real_]
  ok <- !is.na(t$p)
  if (any(ok)) t[ok, p_holm := stats::p.adjust(p, method = "holm")]
  t[]
}

.verdict <- function(cond) ifelse(cond %in% TRUE, VERDICT_YES, VERDICT_NO)

# H7 (services): consistent iff the en_t IRR < 1 with Holm p < 0.05 AND both episode IRRs < 1 (point estimates).
# Any NA (not-estimable test or failed episode model) gives "not consistent with". Vectorised.
verdict_h7 <- function(irr, p_holm, irr_ep1415, irr_ep1819)
  .verdict(irr < 1 & p_holm < 0.05 & irr_ep1415 < 1 & irr_ep1819 < 1)

# H8 (diarrhoea): the > 1 version of H7. A reduction never satisfies H8.
verdict_h8 <- function(irr, p_holm, irr_ep1415, irr_ep1819)
  .verdict(irr > 1 & p_holm < 0.05 & irr_ep1415 > 1 & irr_ep1819 > 1)

# H9 (local climate): consistent if (heatwave IRR < 1 and its Holm p < 0.05) or (spi3_dry coefficient > 0 -- lower
# services with deficit, since spi3_dry <= 0 -- and its Holm p < 0.05).
verdict_h9 <- function(hw_irr, hw_p_holm, dry_est, dry_p_holm)
  .verdict((hw_irr < 1 & hw_p_holm < 0.05) %in% TRUE | (dry_est > 0 & dry_p_holm < 0.05) %in% TRUE)

# "A", "A and B", "A, B and C".
join_labels <- function(x) {
  n <- length(x)
  if (n <= 1L) return(paste(x, collapse = ""))
  paste0(paste(x[-n], collapse = ", "), " and ", x[n])
}

# Overall verdict over the per-outcome verdicts `v` (named by outcome): "consistent with" if at least one outcome is.
# text is the contract's full clause (F52): "consistent with <hypothesis> for <LIST>" (labels in the canonical
# order of `labels`) or "not consistent with <hypothesis>".
overall_verdict <- function(v, labels = OUTCOME_LABELS, hypothesis = "H7") {
  bad <- setdiff(unique(unname(v)), c(VERDICT_YES, VERDICT_NO))
  if (length(bad) || is.null(names(v)))
    stop("overall_verdict: every verdict must be named and read 'consistent with' or 'not consistent with': ",
         paste(bad, collapse = ", "), call. = FALSE)
  yes <- names(v)[v == VERDICT_YES]
  if (!length(yes)) return(list(verdict = VERDICT_NO, text = paste(VERDICT_NO, hypothesis)))
  missing_label <- setdiff(yes, names(labels))
  if (length(missing_label)) stop("overall_verdict: no label for ", paste(missing_label, collapse = ", "), call. = FALSE)
  yes <- yes[order(match(yes, names(labels)))]
  list(verdict = VERDICT_YES, text = sprintf("%s %s for %s", VERDICT_YES, hypothesis, join_labels(unname(labels[yes]))))
}

# The Model S reading (contract "Model S reading rule", five cases; F52). h7_verdict NA = an outcome outside H7.
# s_reason: why Model S is not estimable (NA when it was estimated).
reading_rule_s <- function(h7_verdict, s_irr, s_lo, s_hi, t_irr, s_reason = NA_character_) {
  if (is.na(h7_verdict)) return("not applicable (outcome outside H7)")
  if (!identical(h7_verdict, VERDICT_YES)) return("not applicable (H7 not consistent with)")
  if (!is.na(s_reason) || anyNA(c(s_irr, s_lo, s_hi)))
    return(not_estimable(if (!is.na(s_reason)) s_reason else "Model S estimate missing"))
  same_side <- (t_irr < 1 && s_hi < 1) || (t_irr > 1 && s_lo > 1)
  if (same_side) "agrees in direction" else "null or opposite"
}

# ---- p displays (Conventions) -------------------------------------------------------------------------------------

# The p that enters the Holm family: a block-bootstrap p of 0 enters at its resolution bound 2 / B_ok.
holm_input_p <- function(p, p_kind, B_ok) ifelse(!is.na(p) & p_kind %in% "bootstrap" & p == 0, 2 / B_ok, p)

# Raw p display: fmt_p(); a bootstrap p of 0 displays "<" + fmt_num(2 / B_ok, 3).
p_display <- function(p, p_kind = "wald", B_ok = NA_integer_) {
  if (is.na(p)) return(NA_character_)
  if (identical(p_kind, "bootstrap") && p == 0) return(paste0("<", fmt_num(2 / B_ok, 3)))
  fmt_p(p)
}

# Holm p display: never below the display bound of its raw p; a test that entered at its bound displays
# "<" + fmt_p(the adjusted value computed from that bound).
p_holm_display <- function(p_holm, at_bound = FALSE) {
  if (is.na(p_holm)) return(NA_character_)
  s <- fmt_p(p_holm)
  if (isTRUE(at_bound) && !startsWith(s, "<")) paste0("<", s) else s
}
