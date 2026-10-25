# Out-of-sample validation: leave-one-El-Nino-out (LOEO) and rolling-origin splits,
# cross-validated prediction, metrics, and nested model comparison on common rows.

# Metrics over rows with non-NA y. theta may be a scalar or one value per row
# (pooled predictions from several refits each carry their own dispersion).
oos_metrics <- function(y, mu, theta, lo, hi) {
  theta <- rep_len(theta, length(y))
  ok <- !is.na(y)
  n <- sum(ok)
  if (n == 0L) return(list(male = NA_real_, rmse_log1p = NA_real_, log_score = NA_real_,
                           coverage95 = NA_real_, n = 0L))
  y <- y[ok]; mu <- mu[ok]; theta <- theta[ok]; lo <- lo[ok]; hi <- hi[ok]
  err <- log1p(y) - log1p(mu)
  list(male = mean(abs(err)),
       rmse_log1p = sqrt(mean(err^2)),
       log_score = -mean(stats::dnbinom(y, size = theta, mu = mu, log = TRUE)),
       coverage95 = mean(y >= lo & y <= hi),
       n = as.integer(n))
}

# One split per fold_id; training is every year not in that fold.
loeo_splits <- function(folds) {
  folds <- data.table::as.data.table(folds)
  ids <- unique(folds$fold_id)
  lapply(ids, function(i) {
    yrs <- sort(unique(as.integer(folds$year[folds$fold_id == i])))
    list(id = as.character(i), test_years = yrs)
  })
}

# One split per year t >= first_test: train on years <= t - 1, predict t.
rolling_splits <- function(years, first_test = 2015) {
  ts <- sort(unique(as.integer(years)))
  ts <- ts[ts >= first_test]
  lapply(ts, function(t) list(id = as.character(t), test_years = t, train_max = t - 1L))
}

.empty_pred <- function() data.table::data.table(split_id = character(), unit_id = character(), year = integer(),
                                                 y = numeric(), mu = numeric(), lo = numeric(), hi = numeric(),
                                                 theta = numeric())
.empty_excluded <- function() data.table::data.table(split_id = character(), unit_id = character(),
                                                     year = integer(), reason = character())

# A lagged-outcome covariate (log1p_<outcome>_lag1) in a training row of year t carries the
# outcome of year t - 1; if t - 1 is held out, that row leaks it (ruling P6).
LAG_OUTCOME_PATTERN <- "^log1p_.*_lag1$"
.uses_lag_outcome <- function(spec) any(grepl(LAG_OUTCOME_PATTERN, c(spec$fixed, spec$slopes)))

# Cross-validated predictions for one spec.
# Per split: train = data rows outside test_years (and year <= train_max if set); with
# lag_buffer (default: the spec uses a lagged-outcome covariate) training also drops rows
# whose year - 1 is a test year. Test = rows in test_years. Test rows missing a model
# variable ("missing:<var>") or whose unit has no complete training row
# ("unit_not_in_training") are excluded and recorded.
# A split with no test rows in `data`, or none left after exclusion, is skipped (not a
# failure). A fit error, or an error while drawing, records the split in `failed`
# (stage "fit" or "draw" and the message in `fail_reasons`).
# Coefficients unidentified in a split's fit (NA; e.g. an indicator constant in training)
# are set to 0 for prediction (ruling P5) and recorded in split_info with the number of
# test rows where that covariate is non-zero.
# Seeds: split i uses seed + i - 1 for the parameter draws and that + 100000 for the y
# draws, so specs compared on the same splits share random numbers.
cv_predict <- function(spec, data, splits, n_draws = 200, seed = 1, fitter = glmmTMB_fit,
                       lag_buffer = NULL, re_uncertainty = TRUE) {
  data <- data.table::as.data.table(data)
  vars <- spec_vars(spec)
  if (is.null(lag_buffer)) lag_buffer <- .uses_lag_outcome(spec)
  pred <- list(); excluded <- list(); failed <- character(); skipped <- character()
  fail_reasons <- list(); split_info <- list()
  for (i in seq_along(splits)) {
    sp <- splits[[i]]
    sid <- as.character(sp$id)
    test <- data[year %in% sp$test_years]
    if (nrow(test) == 0L) { skipped <- c(skipped, sid); next }
    train <- data[!year %in% sp$test_years]
    if (!is.null(sp$train_max)) train <- train[year <= sp$train_max]
    if (lag_buffer) train <- train[!(year - 1L) %in% sp$test_years]

    ct <- complete_rows(test, vars)
    if (nrow(ct$dropped))
      excluded[[length(excluded) + 1L]] <- data.table::data.table(
        split_id = sid, unit_id = ct$dropped$unit_id, year = as.integer(ct$dropped$year),
        reason = paste0("missing:", ct$dropped$variable))
    test <- ct$data
    train_units <- unique(as.character(complete_rows(train, vars)$data$unit_id))
    absent <- !as.character(test$unit_id) %in% train_units
    if (any(absent))
      excluded[[length(excluded) + 1L]] <- data.table::data.table(
        split_id = sid, unit_id = as.character(test$unit_id[absent]), year = as.integer(test$year[absent]),
        reason = "unit_not_in_training")
    test <- test[!absent]
    if (nrow(test) == 0L) { skipped <- c(skipped, sid); next }

    fit <- tryCatch(fit_nb(spec, train, fitter = fitter), error = function(e) e)
    if (inherits(fit, "error")) {
      failed <- c(failed, sid)
      fail_reasons[[length(fail_reasons) + 1L]] <- data.table::data.table(split_id = sid, stage = "fit",
                                                                          error = conditionMessage(fit))
      next
    }
    beta_hat <- glmmTMB::fixef(fit$model)$cond
    unid <- names(beta_hat)[is.na(beta_hat)]
    X <- .fixed_design(fit, test)$X
    n_nonzero <- if (length(unid)) sum(rowSums(X[, intersect(unid, colnames(X)), drop = FALSE] != 0) > 0) else 0L
    split_info[[length(split_info) + 1L]] <- data.table::data.table(
      split_id = sid, n_train = as.integer(fit$n), n_test = nrow(test), re_used = fit$re_used,
      unidentified = paste(unid, collapse = ";"), n_test_rows_nonzero_unidentified = as.integer(n_nonzero),
      fit_messages = paste(unique(fit$messages), collapse = " | "))
    split_seed <- seed + i - 1L
    mu <- exp(linear_predictor(fit, test, na_coef = "zero"))
    # a draw failure (e.g. joint precision unavailable) fails the split, recorded, not the run
    yd <- tryCatch(draw_y(fit, draw_mu(fit, test, n_draws = n_draws, seed = split_seed,
                                       re_uncertainty = re_uncertainty, na_coef = "zero"),
                          seed = split_seed + 100000L),
                   error = function(e) e)
    if (inherits(yd, "error")) {
      failed <- c(failed, sid)
      fail_reasons[[length(fail_reasons) + 1L]] <- data.table::data.table(split_id = sid, stage = "draw",
                                                                          error = conditionMessage(yd))
      next
    }
    q <- apply(yd, 1, stats::quantile, probs = c(0.025, 0.975), names = FALSE)
    pred[[length(pred) + 1L]] <- data.table::data.table(
      split_id = sid, unit_id = as.character(test$unit_id), year = as.integer(test$year),
      y = as.numeric(test[[spec$outcome]]), mu = mu, lo = q[1, ], hi = q[2, ],
      theta = stats::sigma(fit$model))
  }
  list(pred = if (length(pred)) data.table::rbindlist(pred) else .empty_pred(),
       failed = failed, skipped = skipped,
       excluded = if (length(excluded)) data.table::rbindlist(excluded) else .empty_excluded(),
       fail_reasons = if (length(fail_reasons)) data.table::rbindlist(fail_reasons)
                      else data.table::data.table(split_id = character(), stage = character(), error = character()),
       split_info = if (length(split_info)) data.table::rbindlist(split_info)
                    else data.table::data.table(split_id = character(), n_train = integer(), n_test = integer(),
                                                re_used = character(), unidentified = character(),
                                                n_test_rows_nonzero_unidentified = integer(),
                                                fit_messages = character()),
       lag_buffer = lag_buffer)
}

.with_model <- function(dt, m) {
  dt <- data.table::copy(dt)
  dt[, model := rep(m, .N)]
  data.table::setcolorder(dt, "model")
  dt[]
}

.metric_row <- function(m) data.table::data.table(male = m$male, rmse_log1p = m$rmse_log1p, log_score = m$log_score,
                                                  coverage95 = m$coverage95, n = m$n)

# Nested model comparison on identical rows.
# 1. Common rows: complete on the union of every spec's variables (so a lag used only by
#    model C also removes those rows from A and B).
# 2. cv_predict per spec on those rows (same splits, same seeds).
# 3. A model whose failed splits exceed 10% of the evaluable (non-skipped) splits gets NA
#    metrics and flag "too_many_failed_fits" ("no_evaluable_splits" if all were skipped).
# 4. The remaining models are scored on the intersection of their predicted rows, so a
#    split failed by any one of them is unscored for all; per_split$scored marks those rows.
#    summary$n_unscored_other_model counts a model's predicted rows left unscored for that
#    reason (NA for flagged models).
# 5. If any spec uses a lagged-outcome covariate, the lag buffer (see cv_predict) applies to
#    every model, so all are trained on the same years (ruling P6).
# Returns summary (one row per model), per_split (row-level predictions with model and
# scored), split_metrics (metrics per model and split, scored rows), common_n (scored rows
# per model), common_dropped, excluded, skipped, fail_reasons, split_info, lag_buffer.
compare_models <- function(specs, data, splits, n_draws = 200, seed = 1, fitter = glmmTMB_fit,
                           re_uncertainty = TRUE) {
  if (!length(specs) || is.null(names(specs)) || any(!nzchar(names(specs))) || anyDuplicated(names(specs)))
    stop("compare_models: specs must be a non-empty list with unique names", call. = FALSE)
  common <- complete_rows(data.table::as.data.table(data), unique(unlist(lapply(specs, spec_vars))))
  lag_buffer <- any(vapply(specs, .uses_lag_outcome, logical(1)))
  cvs <- lapply(specs, cv_predict, data = common$data, splits = splits, n_draws = n_draws, seed = seed,
                fitter = fitter, lag_buffer = lag_buffer, re_uncertainty = re_uncertainty)

  info <- data.table::rbindlist(lapply(names(cvs), function(m) {
    cv <- cvs[[m]]
    n_eval <- length(splits) - length(cv$skipped)
    flag <- if (n_eval == 0L) "no_evaluable_splits"
            else if (length(cv$failed) > 0.1 * n_eval) "too_many_failed_fits" else NA_character_
    data.table::data.table(model = m, n_failed_splits = length(cv$failed), n_splits = as.integer(n_eval), flag = flag)
  }))

  per_split <- data.table::rbindlist(lapply(names(cvs), function(m) .with_model(cvs[[m]]$pred, m)))
  ok_models <- info[is.na(flag), model]
  key_cols <- c("split_id", "unit_id", "year")
  per_split[, scored := FALSE]
  if (length(ok_models)) {
    keys <- Reduce(function(a, b) data.table::fintersect(a, b),
                   lapply(ok_models, function(m) unique(per_split[model == m, ..key_cols])))
    per_split[keys, on = key_cols, scored := model %in% ok_models]
  }

  summary <- data.table::rbindlist(lapply(names(cvs), function(m) {
    r <- info[model == m]
    met <- if (is.na(r$flag)) {
      s <- per_split[model == m & scored == TRUE]
      .metric_row(oos_metrics(s$y, s$mu, s$theta, s$lo, s$hi))
    } else .metric_row(list(male = NA_real_, rmse_log1p = NA_real_, log_score = NA_real_,
                            coverage95 = NA_real_, n = 0L))
    n_unscored <- if (is.na(r$flag)) nrow(per_split[model == m & scored == FALSE]) else NA_integer_
    cbind(data.table::data.table(model = m), met, r[, list(n_failed_splits, flag, n_splits)],
          n_unscored_other_model = as.integer(n_unscored))
  }))

  split_metrics <- per_split[scored == TRUE, .metric_row(oos_metrics(y, mu, theta, lo, hi)), by = .(model, split_id)]

  list(summary = summary[],
       per_split = per_split[],
       split_metrics = split_metrics[],
       common_n = if (length(ok_models)) nrow(per_split[model == ok_models[1] & scored == TRUE]) else 0L,
       common_dropped = common$dropped,
       excluded = data.table::rbindlist(lapply(names(cvs), function(m) .with_model(cvs[[m]]$excluded, m))),
       skipped = lapply(cvs, `[[`, "skipped"),
       fail_reasons = data.table::rbindlist(lapply(names(cvs), function(m) .with_model(cvs[[m]]$fail_reasons, m))),
       split_info = data.table::rbindlist(lapply(names(cvs), function(m) .with_model(cvs[[m]]$split_info, m))),
       lag_buffer = lag_buffer)
}
