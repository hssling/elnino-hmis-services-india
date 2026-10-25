# Paper E (El Nino and health-service continuity, HMIS state-month panel): shared settings. Sourced from
# <repo>/models after common/R/load.R. models/common/R is frozen (Paper D's assert_frozen guards and its ASO
# refresh depend on it): Paper E's monthly extensions are new functions in models/E/R (monthly.R, power.R) that
# call the common functions unchanged.

if (!exists("MODELS_ROOT")) source("common/R/load.R")

E_DIR <- file.path(MODELS_ROOT, "E")
E_CACHE <- file.path(E_DIR, "_cache")          # git-ignored
E_LOGS <- file.path(E_DIR, "logs")             # git-ignored
PAPER_E <- file.path(REPO_ROOT, "papers", "E")
E_OUT <- file.path(PAPER_E, "output")
SEED_E <- 20261024L                            # resample i of any bootstrap uses SEED_E + i - 1 (contract)

INDS <- c("diarr_u5", "anc_reg", "penta3", "mcv1", "fic", "inst_del", "opd")
PRIMARY5 <- c("diarr_u5", "anc_reg", "penta3", "inst_del", "opd")     # H7 + H8 outcomes
H7_INDS <- c("anc_reg", "penta3", "inst_del", "opd")                  # service outcomes (H7, H9)
SMALL_UNITS <- c("LD", "CH", "PY", "DNH_DD", "AN", "SK", "GA")         # pipeline/hmis/model_table.py SMALL_UNITS

HMIS_MODEL_CSV <- file.path(REPO_ROOT, "data", "derived", "hmis", "hmis_model.csv")

# Timestamped message, echoed and appended to models/E/logs/<file> (an absolute `file` is used as given).
elog <- function(..., file = "e_run.log") {
  msg <- sprintf("[%s] %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), paste0(...))
  message(msg)
  path <- if (grepl("^([A-Za-z]:)?[/\\\\]", file)) file else file.path(E_LOGS, file)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  cat(msg, "\n", file = path, append = TRUE, sep = "")
  invisible(msg)
}

# The HMIS model table (pipeline/hmis/model_table.py; columns documented there). window "primary": the 95 months
# April 2012 to February 2020 (in_primary == 1); "fy2021": every row, April 2012 to March 2021 (March 2020 and
# FY2020-21 enter only the fy2021 sensitivity). Missing values stay NA. Factors: unit_id; moy (levels 1..12);
# ym_f (levels = every ym of the window in time order); national (one level, the grouping of the AR(1) time
# effect); unit_era (unit_id x era_e2, levels "<unit>:<0|1>"; used only by the era_int sensitivity).
read_hmis_model <- function(window = c("primary", "fy2021"), path = HMIS_MODEL_CSV) {
  window <- match.arg(window)
  d <- data.table::fread(path, na.strings = c("", "NA", "NaN"))
  if (window == "primary") d <- d[in_primary == 1L]
  if (!nrow(d)) stop("read_hmis_model: no rows in window ", window, " of ", path, call. = FALSE)
  d[, unit_id := factor(unit_id)]
  d[, moy := factor(moy, levels = 1:12)]
  d[, ym_f := factor(ym, levels = sort(unique(ym)))]
  d[, national := factor(rep("IN", .N))]
  d[, unit_era := interaction(unit_id, era_e2, sep = ":", drop = TRUE, lex.order = TRUE)]
  data.table::setorder(d, unit_id, ym)
  d[]
}

# The detached power run (01_power.R) is alive: its progress file reads RUNNING and its pid is a running process.
power_run_alive <- function(progress = file.path(E_LOGS, "power_progress.txt")) {
  if (!file.exists(progress)) return(FALSE)
  l <- readLines(progress, warn = FALSE)
  if (!length(l) || !startsWith(l[1], "RUNNING")) return(FALSE)
  pid <- suppressWarnings(as.integer(sub("^pid ", "", grep("^pid ", l, value = TRUE)[1])))
  if (is.na(pid)) return(FALSE)
  out <- tryCatch(suppressWarnings(system2("tasklist", c("/FI", shQuote(sprintf("PID eq %d", pid)), "/NH"),
                                           stdout = TRUE, stderr = TRUE)), error = function(e) character())
  any(grepl(sprintf("\\b%d\\b", pid), out, perl = TRUE))
}

# PSOCK workers for the Task 8+ model runs: 3 while the power run is alive (controller speed ruling 2026-10-25,
# replacing F54's detectCores() - 4; the machine is shared), else detectCores() - 1.
e_cores <- function(progress = file.path(E_LOGS, "power_progress.txt"), busy = 3L) {
  n <- max(1L, parallel::detectCores() - 1L)
  as.integer(if (power_run_alive(progress)) min(busy, n) else n)
}
