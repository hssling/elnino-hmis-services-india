nb_spec <- function(outcome, fixed, slopes = character(), offset = "log_pop", trend_df = 4L, re = "us") {
  list(outcome = outcome, fixed = fixed, slopes = slopes, offset = offset, trend_df = trend_df, re = re)
}

spec_vars <- function(spec) unique(c(spec$outcome, spec$fixed, spec$slopes, spec$offset, "year"))

spec_formula <- function(spec, re = spec$re) {
  slope_txt <- paste0(" + ", spec$slopes, collapse = "")
  if (!length(spec$slopes)) slope_txt <- ""
  re_term <- switch(re,
    us = sprintf("(1%s | unit_id)", slope_txt),
    diag = if (nzchar(slope_txt)) sprintf("diag(1%s | unit_id)", slope_txt) else "(1 | unit_id)",
    int = "(1 | unit_id)",
    stop("unknown random-effect structure: ", re))
  rhs <- c(spec$fixed,
           if (!is.null(spec$trend_df) && spec$trend_df > 0) sprintf("splines::ns(year, df = %d)", as.integer(spec$trend_df)),
           sprintf("offset(%s)", spec$offset), re_term)
  stats::as.formula(paste(spec$outcome, "~", paste(rhs, collapse = " + ")), env = globalenv())
}

# Default fitter hook. fit_nb calls fitter(formula, data) and relies on the NB2 default;
# mediate's a-path calls fitter(formula, data, family = stats::gaussian()).
glmmTMB_fit <- function(formula, data, family = glmmTMB::nbinom2()) {
  glmmTMB::glmmTMB(formula, data = data, family = family)
}

.converged <- function(m) {
  !inherits(m, "error") && isTRUE(m$sdr$pdHess) && all(is.finite(m$sdr$cov.fixed)) && identical(as.integer(m$fit$convergence), 0L)
}

fit_nb <- function(spec, data, fitter = glmmTMB_fit) {
  cr <- complete_rows(data, spec_vars(spec))
  d <- droplevels(cr$data)
  chain <- c("us", "diag", "int")
  if (length(spec$re) != 1L || !spec$re %in% chain)
    stop("fit_nb: unknown random-effect structure: ", paste(spec$re, collapse = ","), call. = FALSE)
  if (nrow(d) == 0L)
    stop("fit_nb: no complete rows remain for ", spec$outcome, " (", nrow(cr$dropped), " rows dropped)", call. = FALSE)
  # without slopes us/diag/int are the same model: fit once, record "int"
  order <- if (length(spec$slopes)) chain[match(spec$re, chain):length(chain)] else "int"
  attempts <- character()
  for (re in order) {
    attempts <- c(attempts, re)
    # fitter messages (e.g. glmmTMB "dropping columns from rank-deficient conditional model: z")
    # are recorded in the fit record instead of printed
    msgs <- character()
    m <- tryCatch(withCallingHandlers(suppressWarnings(fitter(spec_formula(spec, re), d)),
                                      message = function(c) {
                                        msgs <<- c(msgs, trimws(conditionMessage(c)))
                                        invokeRestart("muffleMessage")
                                      }),
                  error = function(e) e)
    if (.converged(m)) {
      return(structure(list(model = m, spec = spec, re_used = re, n = nrow(d), dropped = cr$dropped,
                            attempts = attempts, data = d, messages = msgs), class = "nbfit"))
    }
  }
  stop("fit_nb: no structure converged for ", spec$outcome, " (tried ", paste(attempts, collapse = ", "), ")")
}

irr_table <- function(fit, terms) {
  co <- summary(fit$model)$coefficients$cond
  absent <- setdiff(terms, rownames(co))
  if (length(absent)) stop("irr_table: term(s) not in model: ", paste(absent, collapse = ", "), call. = FALSE)
  co <- co[terms, , drop = FALSE]
  data.table::data.table(term = terms, irr = exp(co[, 1]), lo = exp(co[, 1] - 1.959964 * co[, 2]),
                         hi = exp(co[, 1] + 1.959964 * co[, 2]), p = co[, 4])
}
