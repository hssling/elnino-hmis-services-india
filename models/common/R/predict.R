# Prediction from an nbfit (fit_nb) on new data.
#
# The linear predictor is built by hand rather than with predict.glmmTMB so that
# parameter draws (draw_mu) can swap in other fixed-effect and random-effect values. It is
#   X beta + offset + unit random effects (conditional modes),
# where X uses the fitted model's own terms; their "predvars" attribute carries
# the training knots of splines::ns(year, df), so new years get the training basis
# (linear extrapolation beyond the boundary knots, as ns() does). Only numeric fixed
# effects are supported (model.matrix is rebuilt without the training factor levels).
#
# Unidentified coefficients (ruling P5). glmmTMB drops a rank-deficient column (e.g. an
# indicator that is constant in the training years) and reports its coefficient as NA.
# linear_predictor / draw_mu / draw_params error on NA coefficients unless called with
# na_coef = "zero", which predicts with them set to 0 ("effect unknown at the forecast
# origin") and draws over the identified block of vcov only.
#
# Parameter uncertainty in draw_mu / draw_params (rulings P7, P9):
#   * re_uncertainty = TRUE (default): (beta, b) are drawn JOINTLY,
#       (beta_identified, b) ~ MVN((beta_hat, b_hat), C),
#     where C is the (conditional fixed effects + random effects) block of the inverse of the
#     joint precision from TMB::sdreport(obj, getJointPrecision = TRUE). C is the Laplace-
#     approximation covariance of all of them together: its b block is the marginal variance
#     of each b_u (the same diagonal as ranef(condVar = TRUE), i.e. including the uncertainty
#     in beta and the variance parameters), and it keeps Cov(beta, b_u), which is typically
#     negative for the intercept. Drawing beta and b independently would double-count the
#     fixed-effect uncertainty. Other fixed parameters (dispersion, RE variance parameters)
#     are integrated over in C but not drawn: the NB2 dispersion stays at its estimate.
#     If the joint precision is unavailable, the draw errors (no silent fallback).
#   * re_uncertainty = FALSE: fixed-only draws, beta ~ MVN(beta_hat, vcov(fit$model)$cond)
#     (marginal), random effects held at their conditional modes.
# Unidentified coefficients are excluded from the drawn block and are 0 in every draw
# (na_coef = "zero"). The random-effect vector b is ordered unit-major (all terms of unit 1,
# then unit 2, ...) for the us, diag and int structures; this is verified against ranef()
# modes on every draw.
# draw_y adds NB2 sampling noise.
#
# Seeds are applied locally: the caller's RNG stream is restored afterwards. With seed = NULL
# the caller's stream is used (and advanced).

.with_seed <- function(seed, expr) {
  if (is.null(seed)) return(expr)
  genv <- globalenv()
  had <- exists(".Random.seed", envir = genv, inherits = FALSE)
  if (had) old <- get(".Random.seed", envir = genv, inherits = FALSE)
  on.exit(if (had) assign(".Random.seed", old, envir = genv)
          else if (exists(".Random.seed", envir = genv, inherits = FALSE)) rm(".Random.seed", envir = genv))
  set.seed(seed)
  expr
}

# Fixed-effect design and offset for newdata, from the fitted terms.
.fixed_design <- function(fit, newdata) {
  tt <- stats::delete.response(stats::terms(fit$model, component = "cond", part = "fixed"))
  dc <- attr(tt, "dataClasses")
  mf <- stats::model.frame(tt, newdata, na.action = stats::na.pass)
  cls <- c(if (!is.null(dc)) dc[setdiff(names(dc), as.character(fit$spec$outcome))],
           vapply(mf, function(v) if (is.numeric(v)) "numeric" else class(v)[1], character(1)))
  bad <- unique(names(cls)[!grepl("^(numeric|nmatrix\\.[0-9]+)$", cls)])
  if (length(bad))
    stop("linear_predictor: only numeric fixed effects are supported; non-numeric: ",
         paste(bad, collapse = ", "), call. = FALSE)
  X <- stats::model.matrix(tt, mf)
  off <- stats::model.offset(mf)
  if (is.null(off)) off <- rep(0, nrow(X))
  list(X = X, off = as.numeric(off))
}

.re_modes <- function(fit) {
  re <- glmmTMB::ranef(fit$model)$cond
  if (is.null(re$unit_id) || length(re) != 1L)
    stop("linear_predictor: expected exactly one random-effect term, by unit_id", call. = FALSE)
  as.matrix(re$unit_id)
}

.unit_index <- function(newdata, units_fitted) {
  units <- as.character(newdata$unit_id)
  unseen <- setdiff(unique(units), units_fitted)
  if (length(unseen))
    stop("linear_predictor: unit(s) not in the fitted model: ", paste(unseen, collapse = ", "), call. = FALSE)
  match(units, units_fitted)
}

.slope_values <- function(newdata, terms) {
  for (s in terms)
    if (is.null(newdata[[s]])) stop("linear_predictor: random slope variable '", s, "' not in newdata", call. = FALSE)
  lapply(stats::setNames(terms, terms), function(s) newdata[[s]])
}

# n x D matrix of RE contributions; re is units x terms (D = 1) or units x terms x D.
.re_contrib <- function(re, newdata) {
  if (length(dim(re)) == 2L) re <- array(re, c(dim(re), 1L), dimnames = c(dimnames(re), list(NULL)))
  idx <- .unit_index(newdata, dimnames(re)[[1]])
  n <- length(idx); D <- dim(re)[3]
  out <- matrix(re[idx, "(Intercept)", , drop = FALSE], n, D)
  sl <- .slope_values(newdata, setdiff(dimnames(re)[[2]], "(Intercept)"))
  for (s in names(sl)) out <- out + matrix(re[idx, s, , drop = FALSE], n, D) * sl[[s]]
  out
}

.resolve_na <- function(beta, na_coef, who) {
  bad <- names(beta)[is.na(beta)]
  if (length(bad)) {
    if (na_coef == "error")
      stop(who, ": unidentified fixed-effect coefficient(s) (NA; dropped as rank-deficient in the fit): ",
           paste(bad, collapse = ", "), ". Pass na_coef = \"zero\" to predict with them set to 0.", call. = FALSE)
    beta[bad] <- 0
  }
  beta
}

linear_predictor <- function(fit, newdata, beta = glmmTMB::fixef(fit$model)$cond, na_coef = c("error", "zero")) {
  na_coef <- match.arg(na_coef)
  p <- .fixed_design(fit, newdata)
  absent <- setdiff(colnames(p$X), names(beta))
  if (length(absent)) stop("linear_predictor: beta lacks coefficient(s): ", paste(absent, collapse = ", "), call. = FALSE)
  b <- .resolve_na(beta[colnames(p$X)], na_coef, "linear_predictor")
  as.numeric(p$X %*% b + p$off + .re_contrib(.re_modes(fit), newdata)[, 1])
}

# Joint precision of all parameters (fixed + random) at the fitted values, or NULL.
.joint_precision <- function(fit) {
  sdr <- tryCatch(TMB::sdreport(fit$model$obj, par.fixed = fit$model$fit$par, getJointPrecision = TRUE),
                  error = function(e) NULL)
  if (is.null(sdr)) NULL else sdr$jointPrecision
}

# Covariance from the joint precision via its Cholesky factor. Unlike base solve(), this accepts a
# positive-definite but ill-conditioned Q (e.g. diag random-slope SDs collapsed to ~1e-6); it errors
# when Q is not positive definite and never falls back to independent draws (ruling P17b).
.invert_joint_precision <- function(Q) {
  Q <- as.matrix(Q)
  R <- tryCatch(chol(Q), error = function(e)
    stop("draw_params: joint precision is not positive definite (Cholesky failed: ",
         conditionMessage(e), "); cannot draw fixed and random effects jointly", call. = FALSE))
  chol2inv(R)
}

# Mean and covariance of (identified conditional beta, b), from the joint precision.
.joint_beta_b <- function(fit) {
  b_hat <- glmmTMB::fixef(fit$model)$cond
  ok <- !is.na(b_hat)
  modes <- .re_modes(fit)
  U <- nrow(modes); K <- ncol(modes)
  Q <- .joint_precision(fit)
  if (is.null(Q))
    stop("draw_params: the joint precision (TMB::sdreport getJointPrecision) is unavailable; ",
         "cannot draw fixed and random effects jointly. Use re_uncertainty = FALSE for fixed-only draws.",
         call. = FALSE)
  nm <- rownames(Q)
  ib <- which(nm == "beta"); ibb <- which(nm == "b")
  if (length(ib) != sum(ok) || length(ibb) != U * K)
    stop(sprintf("draw_params: joint precision has %d beta / %d b entries; expected %d identified fixed effects / %d random effects",
                 length(ib), length(ibb), sum(ok), U * K), call. = FALSE)
  par <- fit$model$obj$env$last.par.best
  if (max(abs(par[names(par) == "beta"] - b_hat[ok])) > 1e-8)
    stop("draw_params: fitted beta does not match fixef() on the identified coefficients", call. = FALSE)
  b_vec <- par[fit$model$obj$env$random]
  if (max(abs(matrix(b_vec, U, K, byrow = TRUE) - modes)) > 1e-8)
    stop("draw_params: random-effect vector does not map unit-major onto ranef() modes", call. = FALSE)
  C <- .invert_joint_precision(Q)
  keep <- c(ib, ibb)
  C <- C[keep, keep]
  C <- (C + t(C)) / 2
  if (anyNA(C)) stop("draw_params: joint covariance contains NA", call. = FALSE)
  list(mean = c(b_hat[ok], as.numeric(b_vec)), cov = C, ok = ok, modes = modes)
}

# Draws as list(beta_draws: n x p, re_draws: units x terms x n or NULL); see header.
.draw_params <- function(fit, n_draws, re_uncertainty, na_coef) {
  b_hat <- .resolve_na(glmmTMB::fixef(fit$model)$cond, na_coef, "draw_params")
  ok <- !is.na(glmmTMB::fixef(fit$model)$cond)
  B <- matrix(0, n_draws, length(b_hat), dimnames = list(NULL, names(b_hat)))
  if (!re_uncertainty) {
    V <- stats::vcov(fit$model)$cond[names(b_hat)[ok], names(b_hat)[ok], drop = FALSE]
    if (anyNA(V)) stop("draw_params: vcov of the identified fixed effects contains NA", call. = FALSE)
    B[, ok] <- matrix(MASS::mvrnorm(n_draws, b_hat[ok], V), nrow = n_draws)
    return(list(beta_draws = B, re_draws = NULL))
  }
  jb <- .joint_beta_b(fit)
  p <- sum(ok); U <- nrow(jb$modes); K <- ncol(jb$modes)
  D <- matrix(MASS::mvrnorm(n_draws, jb$mean, jb$cov), nrow = n_draws)
  B[, ok] <- D[, seq_len(p), drop = FALSE]
  bb <- D[, p + seq_len(U * K), drop = FALSE]                  # unit-major columns
  R <- array(NA_real_, c(U, K, n_draws), dimnames = c(dimnames(jb$modes), list(NULL)))
  for (k in seq_len(K)) R[, k, ] <- t(bb[, (seq_len(U) - 1L) * K + k, drop = FALSE])
  list(beta_draws = B, re_draws = R)
}

# One set of parameter draws to share across scenarios (Task 6).
draw_params <- function(fit, n_draws, seed = NULL, re_uncertainty = TRUE, na_coef = c("error", "zero")) {
  na_coef <- match.arg(na_coef)
  .with_seed(seed, .draw_params(fit, n_draws, re_uncertainty, na_coef))
}

# mu draws, nrow(newdata) x n_draws.
# Without beta_draws: draws come from draw_params(fit, n_draws, seed, re_uncertainty, na_coef).
# With beta_draws (ruling P1): they are used as-is and seed is ignored; when re_uncertainty is
# TRUE, re_draws must be supplied too, so shared scenarios are fully deterministic. re_draws,
# when given, are always used.
draw_mu <- function(fit, newdata, n_draws, seed = NULL, beta_draws = NULL, re_draws = NULL,
                    re_uncertainty = TRUE, na_coef = c("error", "zero")) {
  na_coef <- match.arg(na_coef)
  beta_hat <- glmmTMB::fixef(fit$model)$cond
  if (is.null(beta_draws)) {
    if (!is.null(re_draws)) stop("draw_mu: re_draws given without beta_draws; supply both or neither", call. = FALSE)
    p <- draw_params(fit, n_draws, seed, re_uncertainty, na_coef)
    beta_draws <- p$beta_draws; re_draws <- p$re_draws
  } else {
    if (re_uncertainty && is.null(re_draws))
      stop("draw_mu: with re_uncertainty = TRUE, supply re_draws together with beta_draws ",
           "(see draw_params), or set re_uncertainty = FALSE", call. = FALSE)
    beta_draws <- as.matrix(beta_draws)
    if (missing(n_draws)) n_draws <- nrow(beta_draws)
    if (nrow(beta_draws) != n_draws || ncol(beta_draws) != length(beta_hat))
      stop(sprintf("draw_mu: beta_draws must be %d x %d (n_draws x fixed effects), got %d x %d",
                   n_draws, length(beta_hat), nrow(beta_draws), ncol(beta_draws)), call. = FALSE)
    if (is.null(colnames(beta_draws))) colnames(beta_draws) <- names(beta_hat)
    if (!setequal(colnames(beta_draws), names(beta_hat)))
      stop("draw_mu: beta_draws column names do not match the model's fixed effects", call. = FALSE)
    na_cols <- colnames(beta_draws)[colSums(is.na(beta_draws)) > 0]
    if (length(na_cols)) {
      .resolve_na(stats::setNames(rep(NA_real_, length(na_cols)), na_cols), na_coef, "draw_mu")
      beta_draws[, na_cols] <- 0
    }
    if (!is.null(re_draws)) {
      modes <- .re_modes(fit)
      if (length(dim(re_draws)) != 3L || dim(re_draws)[3] != n_draws ||
          !identical(dimnames(re_draws)[1:2], dimnames(modes)))
        stop("draw_mu: re_draws must be a units x terms x n_draws array matching ranef(); see draw_params",
             call. = FALSE)
    }
  }
  p <- .fixed_design(fit, newdata)
  eta <- p$X %*% t(beta_draws[, colnames(p$X), drop = FALSE]) + p$off
  eta <- eta + if (is.null(re_draws)) .re_contrib(.re_modes(fit), newdata)[, rep(1L, n_draws), drop = FALSE]
               else .re_contrib(re_draws, newdata)
  mu <- exp(eta)
  dimnames(mu) <- NULL
  mu
}

# NB2 outcome draws for a mu-draw matrix, with the fitted dispersion.
draw_y <- function(fit, mu_draws, seed = NULL) {
  mu_draws <- as.matrix(mu_draws)
  .with_seed(seed, matrix(stats::rnbinom(length(mu_draws), size = stats::sigma(fit$model), mu = mu_draws),
                          nrow(mu_draws)))
}
