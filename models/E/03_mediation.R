# Paper E Task 8: the local-climate-mediated share of the Model T association (contract papers/E/results_keys.md §6
# and the mediation rule; spec §5.4 with §10.4; ruling F48). Runs after 02_primary.R.
#
# Run from <repo>/models:
#   Rscript E/03_mediation.R            # cores e_cores() before each bootstrap run (3 while the power run is alive,
#                                       # else detectCores() - 1); B = 500, or 200 after the 24-hour projection
#   --cores=N   --B=N   --budget-hours=H   --out=PATH (mediation.csv)   --rds=PATH (models/E/_cache/mediation.rds)
#   --log=PATH (models/E/logs/mediation.log)   --progress=PATH (models/E/logs/mediation_progress.txt: first word
#   RUNNING, DONE or FAILED; rewritten at every chunk of resamples). Run it detached for the full run.
#
# The rule: mediation runs only for outcomes whose Model T en_t 95% CI (papers/E/output/primary_estimates.csv, model
# T, term en_t; Wald, or the percentile interval under the block-bootstrap step) excludes 1; every other outcome reads
# "not estimated (no total association)" in its five keys; an outcome whose Model T is not estimable reads
# "not estimable (Model T: <reason>)" (F58) and a dropped outcome "not estimable (dropped: ...)". Only a genuine
# estimation failure of the mediation fits is not estimable; any other error stops the run (F56).
# For each eligible outcome, mediate_m() with the three concurrent local-climate mediators (spi3_dry_l0, spi3_wet_l0,
# heatwave_days_l0), covars = the Model T fixed effects other than en_t (F48), the iid (1 | ym_f) time random effect
# in the NB fits; primary resampling month blocks of 12 (E.med.<I>.prop, indirect, flag, B), sensitivity the
# cluster bootstrap by unit (E.med.<I>.prop_unit), same B and seeds (resample i: SEED_E + i - 1).
# B: 5 month-block resamples of the first eligible outcome are timed on one core; the projection is
# seconds per resample x B x (2 x eligible outcomes) x MED_SLOWDOWN / cores; above the budget (24 h) B = 200.
#
# mediation.csv (one row per outcome x resampling scheme; state-level estimates only): outcome, resample
# (month_block / unit), status (estimated, "not estimated (no total association)" or "not estimable (...)"),
# t_irr, t_lo, t_hi (the Model T en_t IRR and CI that decided eligibility), a_<m>, b_<m>, indirect_<m> (a_m * b_m)
# for the three mediators, indirect, indirect_lo, indirect_hi (log-rate scale), c_total, c_total_lo, c_total_hi,
# c_direct, prop, prop_lo, prop_hi (proportions), flag, prop_flag, B, B_ok, B_failed, n, n_units, re_used_b,
# re_used_total, seed, minutes, secs_per_resample_timed, projection_hours, error.
# mediation.rds (git-ignored): list(table, results (mediate_m() results without boot rows), entries, settings).

if (!exists("MODELS_ROOT")) source("common/R/load.R")
if (!exists("E_DIR")) source(file.path(MODELS_ROOT, "E", "R", "common_e.R"))
for (f in c("monthly.R", "power.R", "verdicts.R", "mediation_e.R")) source(file.path(MODELS_ROOT, "E", "R", f))
if (!exists("contract_keys")) source(file.path(MODELS_ROOT, "D", "R", "contract.R"))      # read-only

med_covars <- function(ind) setdiff(t_spec(ind)$fixed, "en_t")

# Progress file of a (detached) mediation run: first word RUNNING, DONE or FAILED, then the time, the pid and details.
med_progress <- function(path, state, ...) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(c(sprintf("%s %s", state, format(Sys.time(), "%Y-%m-%d %H:%M:%S")), sprintf("pid %d", Sys.getpid()),
               unlist(list(...))), path)
}

.med_row <- function(o, resample, tr, r = NULL, status = "estimated", error = NA_character_, minutes = NA_real_) {
  if (is.character(r)) { status <- not_estimable(first_line(r)); error <- first_line(r) }
  base <- data.table::data.table(outcome = o, resample = resample, status = status, t_irr = tr$irr, t_lo = tr$lo,
                                 t_hi = tr$hi)
  if (is.null(r) || is.character(r)) return(cbind(base, data.table::data.table(error = error)))
  m <- names(r$a)
  num <- c(stats::setNames(as.list(r$a), paste0("a_", m)), stats::setNames(as.list(r$b), paste0("b_", m)),
           stats::setNames(as.list(r$indirect_by), paste0("indirect_", m)))
  cbind(base, data.table::as.data.table(num),
        data.table::data.table(indirect = r$indirect, indirect_lo = r$ci$indirect[1], indirect_hi = r$ci$indirect[2],
                               c_total = r$c_total, c_total_lo = r$ci$c_total[1], c_total_hi = r$ci$c_total[2],
                               c_direct = r$c_direct, prop = r$prop_mediated, prop_lo = r$ci$prop[1],
                               prop_hi = r$ci$prop[2], flag = r$flag, prop_flag = r$prop_flag, B = r$B, B_ok = r$B_ok,
                               B_failed = r$B_failed, n = r$n, n_units = r$n_units, re_used_b = r$re_used[["b"]],
                               re_used_total = r$re_used[["total"]], seed = r$seed, minutes = minutes, error = error))
}

run_mediation <- function(cores = NULL, primary_csv = file.path(E_OUT, "primary_estimates.csv"),
                          out_csv = file.path(E_OUT, "mediation.csv"), rds = file.path(E_CACHE, "mediation.rds"),
                          B = 500L, budget_hours = 24, contract = file.path(PAPER_E, "results_keys.md"), write = TRUE,
                          d = NULL, log = file.path(E_LOGS, "mediation.log"),
                          progress_file = file.path(E_LOGS, "mediation_progress.txt")) {
  if (!file.exists(primary_csv))
    stop("run_mediation: ", primary_csv, " does not exist: run E/02_primary.R first", call. = FALSE)
  t0 <- Sys.time()
  mlog <- function(...) elog(..., file = log)
  prog <- function(state, ...) med_progress(progress_file, state, ...)
  prog("RUNNING", "stage: start")
  # cores NULL: e_cores() before each bootstrap run (3 while the power run is alive, then detectCores() - 1); the
  # 24-hour projection then assumes detectCores() - 1, since the power run ends early in a run of many hours
  cores_fun <- if (is.null(cores)) function() e_cores() else { cores <- as.integer(cores); function() cores }
  proj_cores <- if (is.null(cores)) max(1L, parallel::detectCores() - 1L) else cores
  pe <- data.table::fread(primary_csv, na.strings = c("", "NA"))
  tt <- pe[model == "T" & term == "en_t"]
  if (!setequal(tt$outcome, INDS)) stop("run_mediation: primary_estimates.csv lacks Model T rows", call. = FALSE)
  tt[, eligible := status == "ok" & med_eligible(lo, hi)]
  elig <- INDS[INDS %in% tt[eligible == TRUE]$outcome]
  mlog(sprintf("run_mediation: start; pid %d; cores %s; eligible (Model T en_t CI excludes 1): %s", Sys.getpid(),
               if (is.null(cores)) sprintf("auto (now %d)", cores_fun()) else as.character(cores),
               if (length(elig)) paste(elig, collapse = ", ") else "none"))
  if (is.null(d) && length(elig)) d <- read_hmis_model("primary")

  B_use <- as.integer(B); secs <- NA_real_; proj <- NA_real_
  if (length(elig)) {
    # time 5 resamples on the first eligible outcome whose point fits are estimable (an estimation failure moves on
    # to the next outcome; any other error stops the run, F56)
    for (o in elig) {
      tm <- catch_estimation_failure(mediate_m(d, o, covars = med_covars(o), B = 5L, cores = 1L), function(e) NULL)
      if (!is.null(tm)) break
    }
    if (!is.null(tm)) {
      secs <- mean(tm$boot$secs)
      proj <- med_projection_hours(secs, B, 2L * length(elig), proj_cores)
      B_use <- med_choose_B(secs, 2L * length(elig), proj_cores, budget_hours, B = B)
      mlog(sprintf("timing (%s, 5 month-block resamples, one core): %.1f s per resample; projection %.2f h for B = %d x %d runs on %d cores %s %g h: B = %d",
                   o, secs, proj, B, 2L * length(elig), proj_cores, if (proj > budget_hours) ">" else "<=",
                   budget_hours, B_use))
    }
  }

  entries <- list(); rows <- list(); results <- list()
  for (o in INDS) {
    tr <- tt[outcome == o]
    if (!identical(tr$status, "ok")) {
      # F58: a Model T that is not estimable gives "not estimable (Model T: <reason>)"; a dropped outcome keeps the
      # dropped text
      reason <- if (identical(tr$status, "dropped")) not_estimable(tr$error) else not_estimable(paste("Model T:", tr$error))
      entries <- c(entries, mediation_keys(o, reason = reason))
      rows[[o]] <- .med_row(o, NA_character_, tr, status = reason, error = tr$error)
      next
    }
    if (!o %in% elig) {
      entries <- c(entries, mediation_keys(o, reason = MED_NOT_ESTIMATED))
      rows[[o]] <- .med_row(o, NA_character_, tr, status = MED_NOT_ESTIMATED)
      next
    }
    run <- function(scheme) {
      s0 <- Sys.time()
      cn <- cores_fun()
      # with automatic cores, mediate_m re-checks e_cores() before every chunk and enlarges its cluster when the
      # power run has ended
      cores_arg <- if (is.null(cores)) function() { cn <<- e_cores(); cn } else cn
      mlog(sprintf("%s %s: start, B = %d, %d cores%s", o, scheme, B_use, cn, if (is.null(cores)) " (re-checked per chunk)" else ""))
      prog("RUNNING", sprintf("outcome %s (%s): starting, B = %d, %d cores", o, scheme, B_use, cn))
      # only an estimation failure of the point fits is not estimable; any other error stops the run (F56)
      r <- catch_estimation_failure(
        mediate_m(d, o, covars = med_covars(o), resample = scheme, B = B_use, cores = cores_arg,
                  progress = function(k, n) {
                    prog("RUNNING", sprintf("outcome %s (%s): %d of %d resamples, %d cores", o, scheme, k, n, cn),
                         sprintf("eligible: %s", paste(elig, collapse = ", ")),
                         sprintf("elapsed %.2f h", as.numeric(difftime(Sys.time(), t0, units = "hours"))))
                    if (k == n || k %% 100L < 4L * cn) mlog(sprintf("%s %s: %d of %d resamples", o, scheme, k, n))
                  }),
        function(e) conditionMessage(e))
      mins <- as.numeric(difftime(Sys.time(), s0, units = "mins"))
      mlog(sprintf("%s %s: %s in %.1f min", o, scheme,
                   if (is.character(r)) paste("not estimable:", first_line(r))
                   else sprintf("prop %.3f, flag %s, prop_flag %s, B_ok %d", r$prop_mediated, r$flag, r$prop_flag, r$B_ok),
                   mins))
      list(r = r, minutes = mins, cores = cn)
    }
    mb <- run("month_block")
    un <- if (is.character(mb$r)) list(r = mb$r, minutes = 0) else run("unit")
    entries <- c(entries, mediation_keys(o, mb = mb$r, unit = un$r))
    rows[[paste(o, "mb")]] <- .med_row(o, "month_block", tr, mb$r, minutes = mb$minutes)
    rows[[paste(o, "unit")]] <- .med_row(o, "unit", tr, un$r, minutes = un$minutes)
    strip <- function(x) if (is.character(x)) x else x[setdiff(names(x), "boot")]
    results[[o]] <- list(month_block = strip(mb$r), unit = strip(un$r),
                         boot = list(month_block = if (is.list(mb$r)) mb$r$boot, unit = if (is.list(un$r)) un$r$boot))
  }
  tab <- data.table::rbindlist(rows, fill = TRUE)
  tab[, `:=`(secs_per_resample_timed = secs, projection_hours = proj)]
  want <- grep("^E\\.med\\.", contract_keys(contract, prefix = "E"), value = TRUE)
  if (!setequal(names(entries), want))
    stop("run_mediation: keys differ from the contract: missing ", paste(setdiff(want, names(entries)), collapse = ", "),
         "; extra ", paste(setdiff(names(entries), want), collapse = ", "), call. = FALSE)
  entries <- entries[order(names(entries), method = "radix")]
  runtime <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
  if (write) {
    dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)
    dir.create(dirname(rds), recursive = TRUE, showWarnings = FALSE)
    data.table::fwrite(tab, out_csv, eol = "\n")
    saveRDS(list(table = tab, results = results, entries = entries, runtime_min = runtime,
                 settings = list(cores = if (is.null(cores)) "auto" else cores, B_requested = B, B = B_use, budget_hours = budget_hours,
                                 secs_per_resample = secs, projection_hours = proj, seed = SEED_E)), rds)
    mlog(sprintf("run_mediation: wrote %s and %s (%d keys) in %.1f min", out_csv, rds, length(entries), runtime))
  }
  prog("DONE", sprintf("wrote %s", out_csv), sprintf("elapsed %.2f h", runtime / 60),
       sprintf("eligible: %s; B = %d", if (length(elig)) paste(elig, collapse = ", ") else "none", B_use))
  list(entries = entries, table = tab, runtime_min = runtime)
}

mediation_main <- function(args = commandArgs(trailingOnly = TRUE)) {
  opt <- function(name, default) {
    v <- sub(sprintf("^--%s=", name), "", grep(sprintf("^--%s=", name), args, value = TRUE))
    if (length(v)) v[length(v)] else default
  }
  cores <- opt("cores", NA)
  invisible(run_mediation(cores = if (is.na(cores)) NULL else as.integer(cores), B = as.integer(opt("B", 500L)),
                          budget_hours = as.numeric(opt("budget-hours", 24)),
                          primary_csv = opt("primary", file.path(E_OUT, "primary_estimates.csv")),
                          out_csv = opt("out", file.path(E_OUT, "mediation.csv")),
                          rds = opt("rds", file.path(E_CACHE, "mediation.rds")),
                          log = opt("log", file.path(E_LOGS, "mediation.log")),
                          progress_file = opt("progress", file.path(E_LOGS, "mediation_progress.txt"))))
}

# Entry point: on any error writes FAILED (and the message) to the progress file and the log; exit status 1.
mediation_entry <- function(args = commandArgs(trailingOnly = TRUE)) {
  opt <- function(name, default) {
    v <- sub(sprintf("^--%s=", name), "", grep(sprintf("^--%s=", name), args, value = TRUE))
    if (length(v)) v[length(v)] else default
  }
  tryCatch({
    mediation_main(args)
    TRUE
  }, error = function(e) {
    med_progress(opt("progress", file.path(E_LOGS, "mediation_progress.txt")), "FAILED", conditionMessage(e))
    elog("FAILED: ", conditionMessage(e), file = opt("log", file.path(E_LOGS, "mediation.log")))
    FALSE
  })
}

if (sys.nframe() == 0L && !isTRUE(mediation_entry())) quit(status = 1L)
