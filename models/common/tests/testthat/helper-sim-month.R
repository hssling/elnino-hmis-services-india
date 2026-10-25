# Paper E (Task 7): simulated unit-month panel with known truth, laid out like data/derived/hmis/hmis_model.csv
# (primary window April 2012 onward). en_t/ln_t follow a real-like ONI path (the traditional ONI for the 3-month
# season ending in each month, April 2012 to February 2020, rounded to 2 decimals); the programme indicators
# follow the coded months (hmis_format2017 from April 2017, demonet November 2016 to January 2017, mi_round on
# a fixed set of round months). Counts are NB2 with a population-days offset, unit random intercepts and trend
# slopes, an iid year-month effect N(0, sd_ym^2) and log IRR beta_en per +1 deg C of en_t.
# Carries `year` and every column the common spec_vars()/complete_rows() and the Model T formula need (ruling F5).
SIM_ONI_PATH <- c(
  -0.44, -0.35, -0.18, 0.03, 0.28, 0.39, 0.37, 0.28, 0.13, -0.03, -0.24, -0.28, -0.23, -0.2, -0.3, -0.38, -0.45,
  -0.34, -0.32, -0.14, -0.12, -0.11, -0.24, -0.21, -0.02, 0.25, 0.35, 0.22, 0.07, 0.07, 0.24, 0.51, 0.7, 0.8,
  0.73, 0.65, 0.72, 0.86, 1.04, 1.19, 1.44, 1.73, 2.02, 2.28, 2.45, 2.59, 2.5, 2.21, 1.69, 1.11, 0.57, 0.09,
  -0.19, -0.34, -0.42, -0.51, -0.49, -0.37, -0.08, 0.08, 0.27, 0.32, 0.35, 0.32, 0.14, -0.07, -0.23, -0.44,
  -0.61, -0.76, -0.71, -0.67, -0.55, -0.35, -0.07, 0.13, 0.2, 0.3, 0.52, 0.82, 1.04, 1.05, 0.99, 0.94, 0.87,
  0.82, 0.71, 0.59, 0.38, 0.2, 0.31, 0.51, 0.72, 0.75, 0.71)

sim_month_panel <- function(n_units = 34, n_months = 95, beta_en = 0, theta = 20, sd_ym = 0.05, seed = 1) {
  set.seed(seed)
  ym <- 2012L * 12L + 3L + seq_len(n_months) - 1L                     # ym = year * 12 + month - 1; April 2012 first
  year <- ym %/% 12L
  month <- ym %% 12L + 1L
  oni <- rep_len(SIM_ONI_PATH, n_months)
  mi_months <- c(24183:24186, 24189:24192, 24195:24198, 24205:24210, 24213:24216, 24219, 24221:24223, 24239:24241)
  m <- data.table::data.table(ym = ym, year = year, moy = month, t_c = ((seq_len(n_months) - 1L) - 47) / 12,
                              en_t = pmax(oni, 0), ln_t = pmin(oni, 0),
                              hmis_format2017 = as.integer(ym >= 2017L * 12L + 3L),
                              demonet = as.integer(ym >= 2016L * 12L + 10L & ym <= 2017L * 12L),
                              mi_round = as.integer(ym %in% mi_months),
                              b_ym = stats::rnorm(n_months, 0, sd_ym),
                              season = 0.08 * sin(2 * pi * month / 12))
  u <- data.table::data.table(unit_id = sprintf("U%02d", seq_len(n_units)), a = stats::rnorm(n_units, 0, 0.4),
                              b = stats::rnorm(n_units, 0.02, 0.02), pop = round(stats::runif(n_units, 3e5, 1e8)))
  d <- data.table::CJ(unit_id = u$unit_id, ym = ym)
  d <- u[d, on = "unit_id"][m, on = "ym"]
  d[, log_pop_days := log(pop * 30.4)]
  d[, mu := exp(-9 + a + b * t_c + season + 0.05 * hmis_format2017 - 0.04 * demonet + 0.03 * mi_round +
                  beta_en * en_t + b_ym + log_pop_days)]
  d[, y := stats::rnbinom(.N, size = theta, mu = mu)]
  d[, `:=`(unit_id = factor(unit_id), ym_f = factor(ym, levels = sort(unique(ym))), national = factor("IN"),
           moy = factor(moy, levels = 1:12))]
  data.table::setorder(d, unit_id, ym)
  d[, c("unit_id", "year", "ym", "ym_f", "national", "moy", "t_c", "en_t", "ln_t", "hmis_format2017", "demonet",
        "mi_round", "log_pop_days", "y"), with = FALSE]
}
