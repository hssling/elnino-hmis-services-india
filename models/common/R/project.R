# Projection of expected counts under an observed and a counterfactual scenario, with
# parameter uncertainty propagated by JOINT draws (rulings P1, P9).
#
# One set of parameter draws, draw_params(fit, n_draws, seed) = (beta, b) drawn jointly from
# the TMB joint precision, is shared by both scenarios, so every draw d gives
#   excess_d = mu_obs_d - mu_cf_d
# with the same fixed and random effects; the uncertainty of the excess is not inflated by
# independent draws per scenario.
#
# by_row (one row per newdata row):
#   mu, mu_cf               mean over draws of the expected count, observed / counterfactual
#   excess_mean             mean over draws of mu_obs - mu_cf
#   excess_lo, excess_hi    0.025 / 0.975 quantiles of the excess draws (uncertainty interval
#                           of the expected excess: parameter uncertainty only)
#   y_lo, y_hi              0.025 / 0.975 quantiles of NB2 outcome draws (draw_y) under the
#                           observed scenario: a prediction interval for the count, which adds
#                           sampling noise; it is not an interval for the excess
# total (one row per year): per-draw excess summed over the year's rows, then summarised the
# same way, so the draws stay joint across units.
#
# extrapolation is TRUE when any exposure_vars value in newdata or newdata_cf lies outside the
# range of that variable in the fitting data (fit$data); extrapolated_vars names them and
# extrapolation_detail gives the training and projection ranges. Values within 1e-8 of the
# training range count as inside (floating-point noise).
# trend_extrapolation is TRUE when the model has a year trend (trend_df > 0) and a projected
# year lies outside range(fit$data$year): ns() then extends the trend linearly beyond its
# boundary knots. trend_detail gives the training and projected year ranges and the years
# outside. Year is deliberately not an exposure variable.
#
# Rows of newdata / newdata_cf must correspond (same unit_id and year, same order). A row where
# either scenario lacks a model covariate is dropped from both and reported in `dropped`
# (unit_id, year, scenario, variable); nothing is imputed.
#
# Seeds: parameter draws use `seed`, outcome draws `seed + 100000` (as in cv_predict); both
# are applied locally, the caller's RNG stream is restored.

RANGE_TOL <- 1e-8

.range_check <- function(train, values) {
  r <- range(train[is.finite(train)])
  v <- values[is.finite(values)]
  list(train_min = r[1], train_max = r[2],
       new_min = if (length(v)) min(v) else NA_real_, new_max = if (length(v)) max(v) else NA_real_,
       outside = length(v) > 0L && (min(v) < r[1] - RANGE_TOL || max(v) > r[2] + RANGE_TOL))
}

project <- function(fit, newdata, newdata_cf, exposure_vars, n_draws = 1000, seed = 1,
                    re_uncertainty = TRUE, na_coef = c("error", "zero")) {
  na_coef <- match.arg(na_coef)
  nd <- data.table::as.data.table(newdata)
  cf <- data.table::as.data.table(newdata_cf)
  if (nrow(nd) != nrow(cf) || !identical(as.character(nd$unit_id), as.character(cf$unit_id)) ||
      !identical(as.integer(nd$year), as.integer(cf$year)))
    stop("project: newdata and newdata_cf must have the same rows (unit_id, year) in the same order", call. = FALSE)
  if (!length(exposure_vars)) stop("project: exposure_vars is empty", call. = FALSE)
  absent <- setdiff(exposure_vars, intersect(names(fit$data), intersect(names(nd), names(cf))))
  if (length(absent))
    stop("project: exposure variable(s) not in the fitting data and both scenarios: ",
         paste(absent, collapse = ", "), call. = FALSE)

  # covariates the model needs (the outcome is not needed for projection)
  vars <- unique(c("unit_id", setdiff(spec_vars(fit$spec), fit$spec$outcome)))
  c_obs <- complete_rows(nd, vars); c_cf <- complete_rows(cf, vars)
  dropped <- data.table::rbindlist(list(
    if (nrow(c_obs$dropped)) cbind(c_obs$dropped, scenario = "observed"),
    if (nrow(c_cf$dropped)) cbind(c_cf$dropped, scenario = "counterfactual")))
  if (!nrow(dropped)) dropped <- data.table::data.table(unit_id = character(), year = integer(),
                                                       variable = character(), scenario = character())
  data.table::setcolorder(dropped, c("unit_id", "year", "scenario", "variable"))
  bad <- paste(as.character(nd$unit_id), nd$year) %in% paste(dropped$unit_id, dropped$year)
  nd <- nd[!bad]; cf <- cf[!bad]
  if (nrow(nd) == 0L) stop("project: no complete rows to project (", sum(bad), " dropped)", call. = FALSE)

  ext <- data.table::rbindlist(lapply(exposure_vars, function(v) {
    rbind(cbind(data.table::data.table(variable = v, scenario = "observed"),
                data.table::as.data.table(.range_check(fit$data[[v]], nd[[v]]))),
          cbind(data.table::data.table(variable = v, scenario = "counterfactual"),
                data.table::as.data.table(.range_check(fit$data[[v]], cf[[v]]))))
  }))

  ty <- range(fit$data$year)
  yrs <- sort(unique(as.integer(nd$year)))
  has_trend <- !is.null(fit$spec$trend_df) && fit$spec$trend_df > 0
  out_yrs <- yrs[yrs < ty[1] | yrs > ty[2]]
  trend <- list(outside = has_trend && length(out_yrs) > 0L,
                detail = data.table::data.table(trend_df = if (has_trend) as.integer(fit$spec$trend_df) else 0L,
                                                train_min = ty[1], train_max = ty[2],
                                                new_min = min(yrs), new_max = max(yrs),
                                                years_outside = paste(out_yrs, collapse = ";")))

  pd <- draw_params(fit, n_draws, seed = seed, re_uncertainty = re_uncertainty, na_coef = na_coef)
  mu_obs <- draw_mu(fit, nd, n_draws, beta_draws = pd$beta_draws, re_draws = pd$re_draws,
                    re_uncertainty = re_uncertainty, na_coef = na_coef)
  mu_cf <- draw_mu(fit, cf, n_draws, beta_draws = pd$beta_draws, re_draws = pd$re_draws,
                   re_uncertainty = re_uncertainty, na_coef = na_coef)
  ex <- mu_obs - mu_cf
  yd <- draw_y(fit, mu_obs, seed = seed + 100000L)

  qs <- function(m) apply(m, 1, stats::quantile, probs = c(0.025, 0.975), names = FALSE)
  qe <- qs(ex); qy <- qs(yd)
  by_row <- data.table::data.table(unit_id = as.character(nd$unit_id), year = as.integer(nd$year),
                                   mu = rowMeans(mu_obs), mu_cf = rowMeans(mu_cf),
                                   excess_mean = rowMeans(ex), excess_lo = qe[1, ], excess_hi = qe[2, ],
                                   y_lo = qy[1, ], y_hi = qy[2, ])

  years <- sort(unique(by_row$year))
  # years x draws: per-draw excess summed over the year's rows
  tot <- t(matrix(vapply(years, function(y) colSums(ex[by_row$year == y, , drop = FALSE]), numeric(n_draws)),
                  nrow = n_draws))
  qt <- qs(tot)
  total <- data.table::data.table(year = years, n_rows = as.integer(table(factor(by_row$year, levels = years))),
                                  excess_mean = rowMeans(tot), excess_lo = qt[1, ], excess_hi = qt[2, ])

  list(by_row = by_row[], total = total[],
       extrapolation = any(ext$outside),
       extrapolated_vars = unique(ext$variable[ext$outside]),
       extrapolation_detail = ext[],
       trend_extrapolation = trend$outside, trend_detail = trend$detail,
       dropped = dropped[], n_draws = as.integer(n_draws))
}
