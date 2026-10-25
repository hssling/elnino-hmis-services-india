# Simulated panel with known truth: n_units x years, a shared yearly ENSO-like series x,
# unit-varying slopes, NB2 counts with population offset.
sim_panel <- function(n_units = 20, years = 2002:2025, beta = 0.3, slope_sd = 0.15,
                      theta = 8, seed = 1) {
  set.seed(seed)
  x <- stats::setNames(round(stats::rnorm(length(years)), 2), years)
  u <- data.table::data.table(unit_id = sprintf("U%02d", seq_len(n_units)),
                              a = stats::rnorm(n_units, 0, 0.5), b = stats::rnorm(n_units, 0, slope_sd),
                              pop = round(stats::runif(n_units, 5e5, 5e7)))
  d <- data.table::CJ(unit_id = u$unit_id, year = years)
  d <- u[d, on = "unit_id"]
  d[, x := x[as.character(year)]]
  d[, x_lag1 := x[as.character(year - 1)]]
  d[, log_pop := log(pop)]
  d[, mu := exp(-8 + a + (beta + b) * x + 0.02 * (year - 2013) + log_pop)]
  d[, y := stats::rnbinom(.N, size = theta, mu = mu)]
  d[, unit_id := factor(unit_id)]
  d[]
}

# Slow tests (several minutes of model fits) can be skipped locally with SKIP_SLOW_R=1;
# by default (and under `pytest -m r`) they run.
skip_if_slow_disabled <- function() {
  testthat::skip_if(tolower(Sys.getenv("SKIP_SLOW_R")) %in% c("1", "true", "yes"), "SKIP_SLOW_R is set")
}
