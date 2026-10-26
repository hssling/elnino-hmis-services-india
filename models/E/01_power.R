# Paper E Task 7: power simulation for Model T (contract §7; spec §5.8 with §10.5; rulings F47, F49, F50).
# Runs after the contract papers/E/results_keys.md is committed and before any Model T estimate is read. It never
# fits a model containing en_t to the real outcomes: the only real-data fits are the null Model T (no en_t/ln_t,
# iid year-month effect); every model with en_t is fitted to simulated counts. It writes no Model T estimate.
#
# Run from <repo>/models (detached for the full run; it takes hours):
#   Rscript E/01_power.R                 # 200 simulations x 4 IRRs x 7 outcomes
#   --cores=N         PSOCK workers (default max(1, detectCores() - 4); the machine is shared, F50)
#   --n-sim=N         simulations per IRR per outcome (default 200; contract E.power.n_sim)
#   --budget-hours=H  time budget (default 8, spec §10.5)
#   --outcomes=a,b    outcomes (default all seven, INDS)
#   --reuse           reuse finished outcomes from models/E/_cache/power_<outcome>_n<n_sim>.rds
#   --out=PATH        power table (default papers/E/output/power.csv)
#   --rds=PATH        full results (default models/E/_cache/power.rds)
#   --slowdown=X      parallel slowdown factor applied to the one-core refit time (default 1.6, POWER_SLOWDOWN)
#   --progress=PATH   progress file (default models/E/logs/power_progress.txt)
#   --log=PATH        run log (default models/E/logs/power.log)
# Budget rule (brief; spec §10.5; power_schedule()): 3 timed one-core simulation refits per outcome give the refit
# time; the projection is refit time x n_sim x 4 IRRs x POWER_SLOWDOWN / cores, summed over the outcomes. The
# slowdown factor 1.6 was measured on the first full run (6984b56, 8 workers on the 12-core machine): diarr_u5 ran
# 96 refits in 5.1 min against 16.2 s per one-core refit, i.e. each parallel refit took about 1.6x as long (Task 7
# review, item 3). If the projection exceeds the budget, PRIMARY5 run first and mcv1/fic only if the remaining
# budget covers their projection; an outcome not run is recorded with status "not estimated (power simulation time
# budget)". An outcome whose null Model T does not converge is recorded as "not estimable (null Model T for <o>:
# <error>)" and the run continues. The plan and the projection are written to power.csv and the log.
# Logs: the run log and the progress file (rewritten after every chunk of refits: state, pid, outcome, refits done;
# its first word is RUNNING, DONE or FAILED; bad arguments also write FAILED).
#
# power.csv (one row per outcome x IRR): outcome, direction, irr, n_sim, n_ok, power, mean_irr (exp of the mean
# simulated en_t coefficient), mde (the outcome's MDE value, NA if not reached), mde_display, status ("estimated",
# "not estimated (power simulation time budget)" or "not estimable (...)"; for the last two mde_display repeats
# it), null_n, null_n_units, null_re_used, null_time_re, sd_ym and theta (the null fit's year-month SD and NB2
# dispersion), n_failed (refits that did not converge), refit_secs (mean seconds per refit, one core), seed, cores,
# budget_hours, slowdown, projection_hours, run_plan.
# power.rds: list(table = power.csv, sims = per-simulation rows (outcome, irr, sim, ok, est, se, p, reject,
# re_used, error, secs), timing, settings).

if (!exists("MODELS_ROOT")) source("common/R/load.R")
if (!exists("E_DIR")) source(file.path(MODELS_ROOT, "E", "R", "common_e.R"))
for (f in c("monthly.R", "power.R")) source(file.path(MODELS_ROOT, "E", "R", f))

POWER_SLOWDOWN <- 1.6
POWER_NOT_RUN <- "not estimated (power simulation time budget)"

power_progress <- function(path, state, ...) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(c(sprintf("%s %s", state, format(Sys.time(), "%Y-%m-%d %H:%M:%S")), sprintf("pid %d", Sys.getpid()),
               unlist(list(...))), path)
}

.git_e <- function(args) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(REPO_ROOT), args), stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status")
  if (!is.null(st) && st != 0L) stop("git ", paste(args, collapse = " "), " failed: ", paste(out, collapse = "\n"),
                                     call. = FALSE)
  out
}

# Contract first (plan Global Constraints): papers/E/results_keys.md is tracked and has no uncommitted change.
assert_contract_committed <- function(path = "papers/E/results_keys.md", release = e_release_mode()) {
  if (isTRUE(release)) return(e_release_skip("the contract-first check (results_keys.md committed and clean)"))
  if (!length(.git_e(c("ls-files", "--", path)))) stop("the contract ", path, " is not committed", call. = FALSE)
  if (length(.git_e(c("status", "--porcelain", "--", path))))
    stop("the contract ", path, " has uncommitted changes", call. = FALSE)
  .git_e(c("log", "-1", shQuote("--format=%h %s"), "--", path))[1]
}

.power_opt <- function(args, name, default) {
  v <- sub(sprintf("^--%s=", name), "", grep(sprintf("^--%s=", name), args, value = TRUE))
  if (length(v)) v[length(v)] else default
}

power_settings <- function(args = commandArgs(trailingOnly = TRUE)) {
  opt <- function(name, default) .power_opt(args, name, default)
  outcomes <- strsplit(opt("outcomes", paste(INDS, collapse = ",")), ",", fixed = TRUE)[[1]]
  bad <- setdiff(outcomes, INDS)
  if (length(bad)) stop("unknown outcome(s): ", paste(bad, collapse = ", "), call. = FALSE)
  s <- list(cores = as.integer(opt("cores", max(1L, parallel::detectCores() - 4L))),
            n_sim = as.integer(opt("n-sim", 200L)), budget_hours = as.numeric(opt("budget-hours", 8)),
            slowdown = as.numeric(opt("slowdown", POWER_SLOWDOWN)),
            outcomes = INDS[INDS %in% outcomes], reuse = "--reuse" %in% args,
            out = opt("out", file.path(E_OUT, "power.csv")), rds = opt("rds", file.path(E_CACHE, "power.rds")),
            progress = opt("progress", file.path(E_LOGS, "power_progress.txt")),
            log = opt("log", file.path(E_LOGS, "power.log")))
  for (v in c("cores", "n_sim", "budget_hours", "slowdown"))
    if (is.na(s[[v]]) || s[[v]] <= 0) stop("invalid --", sub("_", "-", v, fixed = TRUE), " value", call. = FALSE)
  s
}

# 3 timed simulation refits (one core) per outcome; the refits are on simulated counts only.
time_outcome <- function(d, o) {
  t0 <- Sys.time()
  tm <- simulate_power(d, o, irrs = power_irrs(o)[1], n_sim = 3L, seed = SEED_E, cores = 1L,
                       direction = power_direction(o))
  data.table::data.table(outcome = o, refit_secs = mean(attr(tm, "sims")$secs),
                         total_secs = as.numeric(difftime(Sys.time(), t0, units = "secs")))
}

# The budget rule. time_fun(o) -> data.table(outcome, refit_secs, total_secs); run_fun(o, k, n, need_secs) -> the
# outcome's simulate_power() result; hours_since() -> hours elapsed in the run; is_cached(o) -> TRUE when run_fun
# only reads a finished cache (no budget check). A "power_null_error" from time_fun or run_fun makes that outcome
# "not estimable (<message>)" and the schedule continues; any other error propagates. Returns list(timing,
# projection_hours, over, run_plan, order, results (named; absent = not run), status (named: "estimated",
# POWER_NOT_RUN or "not estimable (...)")).
power_schedule <- function(outcomes, time_fun, run_fun, n_sim, cores, budget_hours, slowdown = POWER_SLOWDOWN,
                           hours_since, is_cached = function(o) FALSE, log = function(...) invisible(NULL)) {
  status <- stats::setNames(rep(POWER_NOT_RUN, length(outcomes)), outcomes)
  not_estimable <- function(o, e) {
    status[[o]] <<- sprintf("not estimable (%s)", conditionMessage(e))
    log(o, ": ", status[[o]])
    NULL
  }
  timing <- data.table::rbindlist(lapply(outcomes, function(o) tryCatch(time_fun(o), power_null_error = function(e) {
    not_estimable(o, e)
    data.table::data.table(outcome = o, refit_secs = NA_real_, total_secs = NA_real_)
  })))
  need_secs <- function(o) timing[outcome == o]$refit_secs * n_sim * length(power_irrs(o)) * slowdown / cores
  projection_hours <- sum(vapply(outcomes, need_secs, 1), na.rm = TRUE) / 3600
  over <- projection_hours > budget_hours
  run_plan <- sprintf("projection %.2f h (one-core refit time x slowdown %.2f / %d cores) %s budget %.0f h: %s",
                      projection_hours, slowdown, as.integer(cores), if (over) ">" else "<=", budget_hours,
                      if (over) "PRIMARY5 first, secondary outcomes only if time remains" else "all outcomes")
  log("plan: ", run_plan)
  order <- c(intersect(outcomes, PRIMARY5), setdiff(outcomes, PRIMARY5))
  results <- list()
  for (k in seq_along(order)) {
    o <- order[k]
    if (startsWith(status[[o]], "not estimable")) next
    if (over && !o %in% PRIMARY5 && !is_cached(o)) {
      remaining <- budget_hours - hours_since()
      need <- need_secs(o) / 3600
      if (need > remaining) {
        log(sprintf("%s not run: needs %.2f h, %.2f h of the budget remain", o, need, remaining))
        next
      }
    }
    r <- tryCatch(run_fun(o, k, length(order), need_secs(o)), power_null_error = function(e) not_estimable(o, e))
    if (!is.null(r)) {
      results[[o]] <- r
      status[[o]] <- "estimated"
    }
  }
  list(timing = timing, projection_hours = projection_hours, over = over, run_plan = run_plan, order = order,
       results = results, status = status)
}

power_rows <- function(o, res, s, timing, projection_hours, run_plan, status = POWER_NOT_RUN) {
  irrs <- power_irrs(o)
  base <- data.table::data.table(outcome = o, direction = power_direction(o), irr = irrs, n_sim = s$n_sim)
  if (is.null(res)) {
    tab <- base[, `:=`(n_ok = NA_integer_, power = NA_real_, mean_irr = NA_real_, mde = NA_real_,
                       mde_display = status, status = status, null_n = NA_integer_,
                       null_n_units = NA_integer_, null_re_used = NA_character_, null_time_re = NA_character_,
                       sd_ym = NA_real_, theta = NA_real_, n_failed = NA_integer_)]
  } else {
    nl <- attr(res, "null")
    m <- mde(res, direction = power_direction(o))
    sims <- attr(res, "sims")
    tab <- base[res[, .(irr, n_ok, power, mean_irr)], on = "irr"]
    tab[, `:=`(mde = m$value, mde_display = m$display, status = "estimated", null_n = as.integer(nl$n),
               null_n_units = as.integer(nl$n_units), null_re_used = nl$re_used, null_time_re = nl$time_re,
               sd_ym = nl$sd_ym, theta = nl$theta)]
    tab[, n_failed := vapply(irr, function(x) sum(!sims$ok[sims$irr == x]), 1L)]
  }
  tab[, `:=`(refit_secs = timing[outcome == o]$refit_secs, seed = SEED_E, cores = s$cores,
             budget_hours = s$budget_hours, slowdown = s$slowdown, projection_hours = projection_hours,
             run_plan = run_plan)]
  tab[]
}

main <- function(args = commandArgs(trailingOnly = TRUE)) {
  t_start <- Sys.time()
  s <- power_settings(args)
  hours_since <- function() as.numeric(difftime(Sys.time(), t_start, units = "hours"))
  plog <- function(...) elog(..., file = s$log)
  power_progress(s$progress, "RUNNING", "stage: start")
  plog("power run start: pid ", Sys.getpid(), "; cores ", s$cores, " (detectCores ", parallel::detectCores(),
       "); n_sim ", s$n_sim, "; budget ", s$budget_hours, " h; slowdown ", s$slowdown, "; outcomes ",
       paste(s$outcomes, collapse = ", "))
  plog("contract: ", assert_contract_committed())
  d <- read_hmis_model("primary")
  cache_of <- function(o) file.path(E_CACHE, sprintf("power_%s_n%d.rds", o, s$n_sim))
  is_cached <- function(o) s$reuse && file.exists(cache_of(o))
  dir.create(E_CACHE, recursive = TRUE, showWarnings = FALSE)

  timings <- list()
  time_fun <- function(o) {
    tm <- if (is_cached(o)) readRDS(cache_of(o))$timing else {
      power_progress(s$progress, "RUNNING", sprintf("stage: timing %s (3 simulation refits)", o))
      x <- time_outcome(d, o)
      plog(sprintf("timing %s: %.1f s per refit (one core), %.1f s with the null fit", o, x$refit_secs, x$total_secs))
      x
    }
    timings[[o]] <<- tm
    tm
  }
  done <- character()
  run_fun <- function(o, k, n, need_secs) {
    if (is_cached(o)) {
      plog("reused ", cache_of(o))
      done <<- c(done, o)
      return(readRDS(cache_of(o))$result)
    }
    t0 <- Sys.time()
    plog(sprintf("start %s (%d of %d): direction %s, IRRs %s; projected end of this outcome %s", o, k, n,
                 power_direction(o), paste(sprintf("%.4f", power_irrs(o)), collapse = ", "),
                 format(Sys.time() + need_secs, "%Y-%m-%d %H:%M")))
    prog <- function(i, total) power_progress(s$progress, "RUNNING",
      sprintf("outcome %s (%d of %d): %d of %d refits", o, k, n, i, total),
      sprintf("started this outcome %s; elapsed in run %.2f h", format(t0, "%H:%M:%S"), hours_since()),
      sprintf("finished: %s", paste(done, collapse = ", ")))
    res <- simulate_power(d, o, irrs = power_irrs(o), n_sim = s$n_sim, seed = SEED_E, cores = s$cores,
                          direction = power_direction(o), progress = prog)
    saveRDS(list(result = res, timing = timings[[o]]), cache_of(o))
    m <- mde(res, direction = power_direction(o))
    plog(sprintf("done %s in %.1f min: power %s; MDE %s; failed refits %d", o,
                 as.numeric(difftime(Sys.time(), t0, units = "mins")),
                 paste(sprintf("%.4f:%.3f", res$irr, res$power), collapse = " "), m$display,
                 sum(!attr(res, "sims")$ok)))
    done <<- c(done, o)
    res
  }
  sch <- power_schedule(s$outcomes, time_fun = time_fun, run_fun = run_fun, n_sim = s$n_sim, cores = s$cores,
                        budget_hours = s$budget_hours, slowdown = s$slowdown, hours_since = hours_since,
                        is_cached = is_cached, log = plog)

  tab <- data.table::rbindlist(lapply(s$outcomes, function(o)
    power_rows(o, sch$results[[o]], s, sch$timing, sch$projection_hours, sch$run_plan, status = sch$status[[o]])))
  sims <- data.table::rbindlist(lapply(names(sch$results), function(o)
    data.table::data.table(outcome = o, attr(sch$results[[o]], "sims"))))
  dir.create(dirname(s$out), recursive = TRUE, showWarnings = FALSE)
  dir.create(dirname(s$rds), recursive = TRUE, showWarnings = FALSE)
  data.table::fwrite(tab, s$out)
  saveRDS(list(table = tab, sims = sims, timing = sch$timing, settings = s), s$rds)
  plog(sprintf("wrote %s and %s in %.2f h", s$out, s$rds, hours_since()))
  power_progress(s$progress, "DONE", sprintf("wrote %s", s$out), sprintf("elapsed %.2f h", hours_since()),
                 sprintf("MDE %s: %s", unique(tab$outcome), tab[, .(d = mde_display[1]), by = outcome]$d))
  invisible(tab)
}

# Entry point: runs main() and, on any error (bad arguments included), writes FAILED to the progress file and the
# log (the --progress / --log paths when given, read without power_settings so that bad arguments still write the
# marker). Returns TRUE on success, FALSE on failure.
power_entry <- function(args = commandArgs(trailingOnly = TRUE)) {
  tryCatch({
    main(args)
    TRUE
  }, error = function(e) {
    power_progress(.power_opt(args, "progress", file.path(E_LOGS, "power_progress.txt")), "FAILED",
                   conditionMessage(e))
    elog("FAILED: ", conditionMessage(e), file = .power_opt(args, "log", file.path(E_LOGS, "power.log")))
    FALSE
  })
}

if (sys.nframe() == 0L && !isTRUE(power_entry())) quit(status = 1L)
