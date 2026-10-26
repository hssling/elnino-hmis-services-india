# Paper E Task 11: results assembly, traceability and the cached-step resolution (contract papers/E/results_keys.md,
# 674 keys; §1 panel_keys(), §7 power keys, §14 conclusion sentence; rulings F13, F15, F18, F20, F25, F52, F56).
# Used by models/E/06_results.R and models/E/run_all.R; the pure functions are driven by test-e-results.R with
# synthetic inputs. Sourced after common/R/load.R (it sources the Paper E helpers it needs). No model is fitted here.
# Non-ASCII characters are written as escapes, never as literals.
#
# Steps and the keys they own (e_key_step(); every contract key has exactly one owner):
#   panel       panel_keys() here (§1, 64 keys; the single producer of E.exposure.*, F15)
#   power       01_power.R -> papers/E/output/power.csv; the §7 keys (36) are built here by power_keys()
#   primary     02_primary.R -> primary_estimates.csv; §2-§5 lag 0 (156 keys, its cache's entries)
#   mediation   03_mediation.R -> mediation.csv; §6 (35)
#   secondary   04_secondary.R -> sensitivity/dlm/iod/heterogeneity/het_modes.csv; §5 cum02/tmax, §8-§11 (214)
#   forecast    05_forecast.R -> forecast_skill.csv, index_comparison.csv; §11 roni/nino34, §12, §13 (168)
#   conclusion  conclusion_sentence() here (§14, 1 key; pending while the primary step is)
#
# Step resolution (resolve_e_step(); run_all.R modes):
#   use_cache  never fits: a step whose cache (models/E/_cache/<step>.rds) and outputs exist is read from the cache
#              after checking that every output CSV equals the table the cache holds (fwrite of the cached table vs
#              the file, both CRLF -> LF; a mismatch means the cache and the committed output are from different
#              runs and stops the run); a step still running (its progress file reads RUNNING and its pid is alive)
#              is never read and never launched; a step with no output is "pending" with allow_pending, else an
#              error; an output without its cache is an error (never a refit).
#   default    as use_cache, except that a step with neither cache nor output (and not running) is run.
#   refit      every step is rerun (Rscript E/<script>), except a running one, which is an error.
# Pending keys (allow_pending): value null, display "pending (<script> not finished)"; reported by step; a results.json
# with pending keys must not be committed (provenance.csv row n_pending).
#
# Hand-offs (F21): results.json (Paper 0 schema, write_results(): keys in C-locale order); provenance.csv (item,
# value, note): results_code_commit (last commit touching models/E, pipeline/hmis and the contract), results_code_dirty,
# seed (SEED_E), n_keys, n_pending, input:<path> (sha256 after CRLF -> LF of hmis_state_month.csv, hmis_model.csv,
# enso_monthly.csv, Paper D's risk_index.csv and the HMIS item crosswalk, with their git state), step:<name> (cached
# or pending, with the reason), cache:<name> (sha256 of the step's .rds) and output:<path> (sha256 after CRLF -> LF and
# git state of every step output). No time stamps or run times, so two runs give identical bytes (F25).
# F25 holds within one repository state: the provenance notes record the git state of the code, inputs and outputs
# ("committed, clean", "uncommitted changes", "untracked") and results_code_commit, so a commit between two runs
# legitimately changes provenance.csv. At the final run, run both --out-dir passes, compare, and only then commit.
# Pending assemblies (allow_pending, no --out-dir) go to the git-ignored papers/E/results.pending.json and
# papers/E/output/provenance.pending.csv (papers/E/.gitignore); write_e_results() refuses to write pending keys to
# papers/E/results.json (review fix round 1).

if (!exists("E_DIR")) source(file.path(MODELS_ROOT, "E", "R", "common_e.R"))
if (!exists("overall_verdict")) source(file.path(MODELS_ROOT, "E", "R", "verdicts.R"))
if (!exists("power_irrs")) source(file.path(MODELS_ROOT, "E", "R", "power.R"))
if (!exists("index_sd")) source(file.path(MODELS_ROOT, "E", "R", "forecast_e.R"))
if (!exists("fy2021_ready")) source(file.path(MODELS_ROOT, "E", "R", "secondary.R"))
if (!exists("contract_keys")) source(file.path(MODELS_ROOT, "D", "R", "contract.R"))      # read-only

RES_SCRIPT_E <- "models/E/06_results.R"
POWER_SCRIPT_E <- "models/E/01_power.R"
E_CONTRACT <- file.path(PAPER_E, "results_keys.md")
E_CODE_PATHS <- c("models/E", "pipeline/hmis", "papers/E/results_keys.md")
E_PROV_INPUTS <- c("data/derived/hmis/hmis_state_month.csv", "data/derived/hmis/hmis_model.csv",
                   "data/derived/enso_monthly.csv", "papers/D/output/risk_index.csv",
                   "pipeline/reference/hmis_item_crosswalk.csv")
E_STEP_SCRIPTS <- c(power = "01_power.R", primary = "02_primary.R", mediation = "03_mediation.R",
                    secondary = "04_secondary.R", forecast = "05_forecast.R")
PENDING_FMT <- "pending (%s not finished)"
DROPPED_DISPLAY <- "dropped (more than 20% of state-months masked)"
FY2021_INCLUDED <- "included as a COVID-flagged sensitivity analysis"
CONCLUSION_CAUSAL_RE <- "\\b(cause[sd]?|causing|effect of|impacts?|led to|reduces?|reduced|kills?)\\b"
# The fixed phrases of the contract's §14 template (test-e-results.R checks each is verbatim in the contract).
CONCLUSION_PHRASES <- c(
  lead = "In this state-month analysis of routine HMIS data from India, 2012–2020, the results were ",
  h7 = " lower use of essential services during the El Niño phase",
  h8 = " more reported diarrhoea in children under 5 years during the El Niño phase",
  h9 = " lower service use in state-months with more heatwave days or a rainfall deficit")

.res_e <- function(value, display, description, script = RES_SCRIPT_E)
  res_entry(value, enc2utf8(display), script, enc2utf8(description))

# ------------------------------------------------------------------ contract: owners and declared counts

E_KEY_OWNERS <- list(
  panel = function(k) grepl("^E\\.(panel|comp|status_date|gates|break2017|exposure)\\.", k) | k == "E.fy2021.status",
  power = function(k) grepl("^E\\.power\\.", k),
  primary = function(k) grepl("^E\\.(t|h7|h8|h9|s|l)\\.", k) & !grepl("\\.cum02$|\\.tmax\\.", k),
  mediation = function(k) grepl("^E\\.med\\.", k),
  secondary = function(k) (grepl("^E\\.(het|iod|dlm|sens)\\.", k) & !grepl("^E\\.sens\\..*\\.(roni|nino34)$", k)) |
    grepl("^E\\.l\\..*\\.cum02$|^E\\.l\\..*\\.tmax\\.irr$", k),
  forecast = function(k) grepl("^E\\.(fc|idx)\\.", k) | grepl("^E\\.sens\\.[^.]+\\.(roni|nino34)$", k),
  conclusion = function(k) k == "E.abstract.conclusion_sentence")

# The step owning each key (exactly one owner per key, else an error).
e_key_step <- function(keys) {
  m <- do.call(cbind, lapply(E_KEY_OWNERS, function(f) f(keys)))
  n <- rowSums(m)
  if (any(n != 1L)) stop("e_key_step: key(s) with no owner or several owners: ",
                         paste(head(keys[n != 1L], 10), collapse = ", "), call. = FALSE)
  names(E_KEY_OWNERS)[max.col(m, ties.method = "first")]
}

# Declared "(N keys)" per numbered section vs the keys its table rows list (F20); attr declared_total = the
# intro's "(674 keys)".
contract_section_counts <- function(path = E_CONTRACT) {
  lines <- readLines(path, encoding = "UTF-8", warn = FALSE)
  head_re <- "^## ([0-9]+)\\. .*\\(([0-9,]+) keys?\\)\\s*$"
  h <- grep(head_re, lines)
  nxt <- grep("^## ", lines)
  rows <- lapply(seq_along(h), function(j) {
    stop_at <- min(c(nxt[nxt > h[j]] - 1L, length(lines)))
    seg <- lines[(h[j] + 1L):stop_at]
    r <- grep("^\\|\\s*`E\\.", seg, value = TRUE)
    first <- vapply(strsplit(r, "|", fixed = TRUE), function(x) x[2], character(1))
    toks <- gsub("`", "", unlist(regmatches(first, gregexpr("`E\\.[^`]+`", first))))
    keys <- unique(unlist(lapply(toks, expand_keys)))
    data.table::data.table(section = sub(head_re, "\\1", lines[h[j]]),
                           declared = as.integer(gsub(",", "", sub(head_re, "\\2", lines[h[j]]))),
                           found = length(keys), keys = list(keys))
  })
  out <- data.table::rbindlist(rows)
  intro <- grep("^This contract lists", lines, value = TRUE)[1]
  tot <- regmatches(intro, regexpr("\\(([0-9,]+) keys\\)", intro))
  attr(out, "declared_total") <- if (length(tot)) as.integer(gsub("[^0-9]", "", tot)) else NA_integer_
  out
}

assert_contract_counts <- function(path = E_CONTRACT) {
  cnt <- contract_section_counts(path)
  bad <- cnt[declared != found]
  if (nrow(bad)) stop(paste(sprintf("contract: section %s declares %d keys but lists %d", bad$section, bad$declared,
                                    bad$found), collapse = "; "), call. = FALSE)
  all_keys <- unlist(cnt$keys)
  if (anyDuplicated(all_keys)) stop("contract: key(s) listed in two sections: ",
                                    paste(unique(all_keys[duplicated(all_keys)]), collapse = ", "), call. = FALSE)
  want <- contract_keys(path, prefix = "E")
  tot <- attr(cnt, "declared_total")
  if (!identical(tot, length(want)) || sum(cnt$found) != length(want))
    stop(sprintf("contract: declares %s keys, the sections list %d and the parser finds %d", tot, sum(cnt$found),
                 length(want)), call. = FALSE)
  invisible(cnt)
}

# ------------------------------------------------------------------ helpers

.e_git <- function(args) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(REPO_ROOT), args), stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status")
  if (!is.null(st) && st != 0L) stop("git ", paste(args, collapse = " "), " failed: ", paste(out, collapse = "; "),
                                     call. = FALSE)
  out
}

# sha256 of bytes after CRLF -> LF (git's autocrlf checkout of a committed LF file).
.e_sha256_lf_raw <- function(b) {
  if (length(b) > 1L) {
    cr <- which(b == as.raw(13L))
    cr <- cr[cr < length(b) & b[cr + 1L] == as.raw(10L)]
    if (length(cr)) b <- b[-cr]
  }
  cli::hash_raw_sha256(b)
}
.e_sha256_lf <- function(path) .e_sha256_lf_raw(readBin(path, "raw", file.size(path)))

# sha256 (LF) of a table as fwrite writes it.
.e_table_sha <- function(x) {
  f <- tempfile(fileext = ".csv")
  on.exit(unlink(f))
  data.table::fwrite(x, f, eol = "\n")
  .e_sha256_lf(f)
}

.e_rel <- function(path) {
  p <- normalizePath(path, winslash = "/", mustWork = FALSE)
  root <- paste0(normalizePath(REPO_ROOT, winslash = "/"), "/")
  if (startsWith(p, root)) substring(p, nchar(root) + 1L) else p
}

# Git state of a repository path: "committed, clean", "uncommitted changes", "untracked" or "outside the repository".
.e_git_state <- function(path, release = e_release_mode()) {
  rel <- .e_rel(path)
  if (grepl("^([A-Za-z]:)?/", rel)) return("outside the repository")
  if (isTRUE(release)) return("release copy (git state not checked)")
  if (!length(.e_git(c("ls-files", "--", rel)))) return("untracked")
  if (length(.e_git(c("status", "--porcelain", "--", rel)))) return("uncommitted changes")
  "committed, clean"
}

# "2015-09-19" -> "19 September 2015".
date_display <- function(x) {
  d <- as.Date(as.character(x))
  if (anyNA(d)) stop("date_display: not a date: ", paste(x[is.na(d)], collapse = ", "), call. = FALSE)
  paste(as.integer(format(d, "%d")), month.name[as.integer(format(d, "%m"))], format(d, "%Y"))
}

.progress_pid <- function(progress) {
  l <- if (file.exists(progress)) readLines(progress, warn = FALSE) else character()
  pid <- sub("^pid ", "", grep("^pid ", l, value = TRUE)[1])
  if (is.na(pid)) "unknown" else pid
}

# ------------------------------------------------------------------ §1 panel keys (F15)

# The 64 §1 keys from the model table, gate_summary.csv (scope primary), break_ratio_2017.csv, the FY2020-21 status
# (fy2021_ready(): final and committed at the Task 9 sync, F3) and the ENSO table (raw Nino-3.4 SD for the
# description). The index SDs use index_sd() (forecast_e.R; the helper Task 10 used, F7) and must equal the
# sd_index of index_comparison.csv when that file exists, so the per-SD keys and E.exposure.*_sd agree.
panel_keys <- function(model_csv = HMIS_MODEL_CSV, gate_csv = file.path(REPO_ROOT, "data", "derived", "hmis", "gate_summary.csv"),
                       break_csv = file.path(REPO_ROOT, "data", "derived", "hmis", "break_ratio_2017.csv"),
                       index_csv = file.path(E_OUT, "index_comparison.csv"),
                       enso_csv = file.path(REPO_ROOT, "data", "derived", "enso_monthly.csv"),
                       fy2021 = fy2021_ready(), script = RES_SCRIPT_E) {
  E <- list()
  put <- function(k, value, display, description) E[[k]] <<- .res_e(value, display, description, script)
  cols <- c("unit_id", "ym", "fy", "in_primary", "status_date_min", "status_date_max", "oni", "roni", "nino34_3m", INDS,
            paste0("comp_", INDS), paste0("n_districts_", INDS))
  d <- data.table::fread(model_csv, select = cols, na.strings = c("", "NA", "NaN"))
  p <- d[in_primary == 1L]
  if (!nrow(p)) stop("panel_keys: no primary-window rows in ", model_csv, call. = FALSE)
  src <- sprintf("%s (in_primary == 1)", .e_rel(model_csv))
  n_units <- data.table::uniqueN(p$unit_id); n_months <- data.table::uniqueN(p$ym)
  put("E.panel.n_units", n_units, fmt_int(n_units), sprintf("Distinct unit_id in %s", src))
  put("E.panel.n_months", n_months, fmt_int(n_months), sprintf("Distinct months (ym) in %s: April 2012 to February 2020", src))
  put("E.panel.n_state_months", nrow(p), fmt_int(nrow(p)), sprintf("Unit-months (rows, whatever the outcome values) in %s", src))
  for (o in INDS) {
    nv <- sum(!is.na(p[[o]]))
    put(sprintf("E.panel.%s.n_valid", o), nv, fmt_int(nv),
        sprintf("Primary-window unit-months with a non-missing %s (after the gates and the 0.90 completeness filter); %s", o, src))
    cp <- p[[paste0("comp_", o)]]; nd <- p[[paste0("n_districts_", o)]]
    med <- stats::median(cp, na.rm = TRUE)
    put(sprintf("E.comp.%s.median", o), med, fmt_pct(med, 1),
        sprintf("Median of comp_%s (valid / listed districts) over the %d primary-window unit-months with a value (%d without); full value %s",
                o, sum(!is.na(cp)), sum(is.na(cp)), format(signif(med, 6))))
    ok <- !is.na(cp) & !is.na(nd) & nd > 0
    sh <- sum(cp[ok] * nd[ok]) / sum(nd[ok])
    put(sprintf("E.comp.%s.share_district_months_valid", o), sh, fmt_pct(sh, 1),
        sprintf("Share of district-months valid, sum(comp_%s x n_districts_%s) / sum(n_districts_%s) over the %d primary-window unit-months with a district list (spec 10.1); full value %s",
                o, o, o, sum(ok), format(signif(sh, 6))))
  }
  dmin <- min(as.Date(as.character(p$status_date_min)), na.rm = TRUE)
  dmax <- max(as.Date(as.character(p$status_date_max)), na.rm = TRUE)
  f21 <- d[in_primary != 1L & fy == "2020-21"]
  f21_dates <- unique(c(as.character(f21$status_date_min), as.character(f21$status_date_max)))
  f21_dates <- sort(f21_dates[!is.na(f21_dates) & nzchar(f21_dates)])
  f21_txt <- if (length(f21_dates)) paste(date_display(f21_dates), collapse = " to ") else "none"
  put("E.status_date.min", as.character(dmin), date_display(dmin),
      sprintf("Earliest status_date_min over %s (HMIS values are provisional as of their status date)", src))
  put("E.status_date.max", as.character(dmax), date_display(dmax), sprintf("Latest status_date_max over %s", src))
  rng <- paste(date_display(dmin), "to", date_display(dmax))
  put("E.status_date.range", rng, rng,
      sprintf("Status dates of the primary window (%s); FY2020-21 (fy2021 sensitivity) status date: %s", src, f21_txt))
  g <- data.table::fread(gate_csv)[scope == "primary"]
  drop_n <- 0L
  for (o in INDS) {
    r <- g[indicator == o]
    if (nrow(r) != 1L) stop(sprintf("panel_keys: gate_summary.csv has %d primary rows for %s", nrow(r), o), call. = FALSE)
    gsrc <- sprintf("%s, scope primary (FY2012-13 to 2019-20, gate rules applied by FY so March 2020 included)", .e_rel(gate_csv))
    put(sprintf("E.gates.%s.n_masked", o), as.integer(r$masked), fmt_int(r$masked),
        sprintf("Gate-masked state-months of %s (column masked; the completeness filter is not masking); %s", o, gsrc))
    put(sprintf("E.gates.%s.share_masked", o), r$masked_share, fmt_pct(r$masked_share, 2),
        sprintf("masked_share (masked / reported state-months) of %s, full value %s; %s", o, format(signif(r$masked_share, 6)), gsrc))
    dr <- toupper(as.character(r$dropped)) == "TRUE"
    drop_n <- drop_n + as.integer(dr)
    txt <- if (dr) DROPPED_DISPLAY else "not dropped"
    put(sprintf("E.gates.%s.dropped", o), txt, txt, sprintf("The 20%% masking rule for %s (column dropped); %s", o, gsrc))
  }
  put("E.gates.n_dropped", drop_n, fmt_int(drop_n), sprintf("Outcomes dropped by the 20%% masking rule (%s)", .e_rel(gate_csv)))
  br <- data.table::fread(break_csv)
  for (o in INDS) {
    r <- br[indicator == o]
    if (nrow(r) != 1L) stop(sprintf("panel_keys: break_ratio_2017.csv has %d rows for %s", nrow(r), o), call. = FALSE)
    put(sprintf("E.break2017.%s.ratio", o), r$ratio, fmt_num(r$ratio, 3),
        sprintf("National April 2017 / March 2017 ratio of pre-gate state values of %s, units reporting both months (descriptive; %s); full value %s",
                o, .e_rel(break_csv), format(signif(r$ratio, 6))))
  }
  # exposure: one value per primary month
  m <- unique(p[, .(ym, oni, roni, nino34_3m)])
  if (anyDuplicated(m$ym)) stop("panel_keys: more than one exposure value in a month", call. = FALSE)
  sds <- c(oni = index_sd(p, "oni"), roni = index_sd(p, "roni"), nino34 = index_sd(p, "nino34"))
  ic_note <- "index_comparison.csv not present (no cross-check)"
  if (file.exists(index_csv)) {
    ic <- data.table::fread(index_csv)
    for (ix in names(sds)) {
      v <- unique(ic[index == ix]$sd_index)
      if (length(v) != 1L || !is.finite(v) || abs(v - sds[[ix]]) > 1e-9)
        stop(sprintf("panel_keys: %s: sd_index in %s (%s) differs from the SD of the entered series over the primary months (%s)",
                     ix, .e_rel(index_csv), paste(format(v, digits = 15), collapse = ", "), format(sds[[ix]], digits = 15)),
             call. = FALSE)
    }
    ic_note <- sprintf("equals sd_index of %s (Task 10, index_sd(); F7)", .e_rel(index_csv))
  }
  em <- m[!is.na(oni)]
  put("E.exposure.n_months", nrow(em), fmt_int(nrow(em)), sprintf("Primary months with an ONI value (%s)", src))
  ne <- sum(em$oni >= 0.5); nl <- sum(em$oni <= -0.5)
  put("E.exposure.n_en_months", ne, fmt_int(ne), "Primary months with ONI >= 0.5 (season ending in the month)")
  put("E.exposure.n_ln_months", nl, fmt_int(nl), "Primary months with ONI <= -0.5 (season ending in the month)")
  sd_desc <- function(col, ix) sprintf("SD (n - 1) of %s over the %d primary months, one value per month: %s; %s",
                                       col, nrow(m), format(signif(sds[[ix]], 10)), ic_note)
  put("E.exposure.oni_sd", sds[["oni"]], fmt_num(sds[["oni"]], 2), sd_desc("oni", "oni"))
  mx <- max(em$oni)
  put("E.exposure.oni_max", mx, fmt_num(mx, 2, plus = TRUE), "Maximum oni over the primary months")
  put("E.exposure.roni_sd", sds[["roni"]], fmt_num(sds[["roni"]], 2), sd_desc("roni", "roni"))
  en <- data.table::fread(enso_csv, select = c("year", "month", "nino34_anom"))
  raw <- en[(12L * year + month - 1L) %in% m$ym]$nino34_anom
  raw_txt <- if (length(raw) == nrow(m) && !anyNA(raw)) format(signif(stats::sd(raw), 6)) else "not available"
  put("E.exposure.nino34_sd", sds[["nino34"]], fmt_num(sds[["nino34"]], 2),
      sprintf("%s; the raw calendar-month nino34_anom SD over the same months (%s) is %s", sd_desc("nino34_3m (mean over t-2..t)", "nino34"),
              .e_rel(enso_csv), raw_txt))
  st <- if (isTRUE(fy2021$ok)) FY2021_INCLUDED else not_estimable(paste("FY2020-21", fy2021$reason))
  put("E.fy2021.status", st, st,
      sprintf("fy2021_ready(): data/derived/hmis/fy2021_status.json status %s%s (final and committed at the Task 9 sync, F3)",
              fy2021$status, if (isTRUE(fy2021$ok)) "" else paste0("; ", fy2021$reason)))
  E[order(names(E), method = "radix")]
}

# ------------------------------------------------------------------ §7 power keys

# The 36 §7 keys from the power table (power.csv; 01_power.R). Power keys pXXX map to IRR 0.XX (decrease) or
# 1/0.XX (diarr_u5, increase; F47). An outcome not run or not estimable carries its status in all five keys. The MDE
# is recomputed with mde() and must equal power.csv's mde_display.
power_keys <- function(tab, outcomes = INDS, script = POWER_SCRIPT_E) {
  tab <- data.table::as.data.table(tab)
  E <- list()
  put <- function(k, value, display, description) E[[k]] <<- .res_e(value, display, description, script)
  sfx <- c(p090 = 0.90, p095 = 0.95, p097 = 0.97, p099 = 0.99)
  for (o in outcomes) {
    r <- tab[outcome == o]
    if (!nrow(r)) stop("power_keys: power.csv has no rows for ", o, call. = FALSE)
    dirn <- power_direction(o)
    target <- if (dirn == "increase") 1 / sfx else sfx
    st <- unique(r$status)
    if (length(st) != 1L) stop("power_keys: ", o, " has more than one status in power.csv", call. = FALSE)
    if (!identical(st, "estimated")) {
      for (k in c("mde", names(sfx)))
        put(sprintf("E.power.%s.%s", o, k), NA, st, sprintf("Power simulation for %s: %s (power.csv status)", o, st))
      next
    }
    m <- mde(r[, .(irr, power)], direction = dirn)
    if (!identical(m$display, as.character(r$mde_display[1])))
      stop(sprintf("power_keys: %s: the MDE in power.csv (%s) differs from the MDE rule (%s)", o, r$mde_display[1], m$display),
           call. = FALSE)
    lbl <- function(b) if (dirn == "increase") sprintf("1/%.2f", b) else sprintf("%.2f", b)
    pw <- paste(sprintf("%s: %s", vapply(sfx, lbl, ""), fmt_pct(r$power[match(round(target, 8), round(r$irr, 8))], 0)), collapse = "; ")
    put(sprintf("E.power.%s.mde", o), m$value, m$display,
        sprintf("Minimum detectable IRR per +1 deg C for %s (direction %s): the IRR closest to 1 with power >= 0.80 (per test, alpha 0.05, not Holm-adjusted); power by IRR %s; %d simulations per IRR, seeds SEED_E + i - 1",
                o, dirn, pw, as.integer(r$n_sim[1])))
    for (k in names(sfx)) {
      i <- which(abs(r$irr - target[[k]]) < 1e-8)
      if (length(i) != 1L) stop(sprintf("power_keys: %s has no single row at IRR %s", o, format(target[[k]])), call. = FALSE)
      put(sprintf("E.power.%s.%s", o, k), r$power[i], fmt_pct(r$power[i], 0),
          sprintf("Power at IRR %s (%s) per +1 deg C for %s: share of the n_ok = %s successful refits (of %d simulations) with a two-sided p < 0.05 and an estimate %s 1; full value %s",
                  format(signif(r$irr[i], 6)), lbl(sfx[[k]]), o, r$n_ok[i], as.integer(r$n_sim[i]),
                  if (dirn == "increase") "above" else "below", format(signif(r$power[i], 6))))
    }
  }
  ns <- unique(tab$n_sim)
  if (length(ns) != 1L) stop("power_keys: power.csv has more than one n_sim", call. = FALSE)
  put("E.power.n_sim", as.integer(ns), fmt_int(ns), "Simulations requested per IRR per outcome (power.csv n_sim; spec 10.5)")
  E[order(names(E), method = "radix")]
}

# ------------------------------------------------------------------ §14 conclusion sentence

# The contract §14 template, filled from the verdict keys; stops on a missing key, a null display, a verdict outside
# the vocabulary, an overall verdict or verdict_text that disagrees with the per-outcome verdicts, causal wording or
# a paper label.
conclusion_sentence <- function(E) {
  need <- function(k) {
    e <- E[[k]]
    if (is.null(e)) stop("conclusion sentence: missing key ", k, call. = FALSE)
    v <- e$display
    if (!v %in% c(VERDICT_YES, VERDICT_NO))
      stop(sprintf("conclusion sentence: %s is outside 'consistent with' / 'not consistent with': %s", k, v), call. = FALSE)
    v
  }
  part <- function(h, phrase) {
    v <- vapply(H7_INDS, function(o) need(sprintf("E.%s.%s.verdict", h, o)), "")
    ov <- overall_verdict(v, hypothesis = toupper(h))
    top <- need(sprintf("E.%s.verdict", h))
    if (!identical(top, ov$verdict))
      stop(sprintf("conclusion sentence: E.%s.verdict (%s) disagrees with the per-outcome verdicts (%s)", h, top, ov$verdict),
           call. = FALSE)
    txt <- E[[sprintf("E.%s.verdict_text", h)]]
    if (is.null(txt) || !identical(txt$display, ov$text))
      stop(sprintf("conclusion sentence: E.%s.verdict_text disagrees with the per-outcome verdicts", h), call. = FALSE)
    yes <- names(v)[v == VERDICT_YES]
    paste0(top, phrase, if (length(yes)) paste0(" (", join_labels(unname(OUTCOME_LABELS[yes])), ")") else "")
  }
  s <- enc2utf8(paste0(CONCLUSION_PHRASES[["lead"]], part("h7", CONCLUSION_PHRASES[["h7"]]), "; ",
                       need("E.h8.verdict"), CONCLUSION_PHRASES[["h8"]], "; and ", part("h9", CONCLUSION_PHRASES[["h9"]]), "."))
  if (grepl(CONCLUSION_CAUSAL_RE, s, ignore.case = TRUE, perl = TRUE)) stop("conclusion sentence: causal wording: ", s, call. = FALSE)
  if (grepl("Paper [A-E]\\b", s)) stop("conclusion sentence: paper label: ", s, call. = FALSE)
  s
}

conclusion_entry <- function(E) {
  s <- conclusion_sentence(E)
  list(E.abstract.conclusion_sentence = .res_e(s, s,
    "Code-built from the contract section 14 template: H7 from E.h7.verdict and E.h7.<H>.verdict, H8 from E.h8.verdict, H9 from E.h9.verdict and E.h9.<H>.verdict ({LIST} as section 3); no causal wording, no paper label"))
}

# ------------------------------------------------------------------ steps: definitions, resolution, pending

# The producer steps: script, cache, progress file, the output CSVs (each a function of the cached object giving the
# table the producer wrote) and the entries (a function of the cached object).
e_step_defs <- function(out_dir = E_OUT, cache = E_CACHE, logs = E_LOGS) {
  het_modes <- function(r) if (!is.null(r$het_modes) && nrow(r$het_modes)) r$het_modes else
    data.table::data.table(outcome = character(), unit_id = character(), mode = numeric(), sd = numeric(), identifiable = logical())
  list(
    power = list(name = "power", script = E_STEP_SCRIPTS[["power"]], rds = file.path(cache, "power.rds"),
                 progress = file.path(logs, "power_progress.txt"), out_dir = out_dir,
                 outputs = list(power.csv = function(r) r$table), entries = function(r) power_keys(r$table),
                 # release mode: the cached object rebuilt from the output table (power_keys() reads only the table)
                 from_outputs = function(t) list(table = t[["power.csv"]]),
                 col_classes = list(character = c("mde_display", "status"))),
    primary = list(name = "primary", script = E_STEP_SCRIPTS[["primary"]], rds = file.path(cache, "primary.rds"),
                   progress = NULL, out_dir = out_dir,
                   outputs = list(primary_estimates.csv = function(r) r$table), entries = function(r) r$entries),
    mediation = list(name = "mediation", script = E_STEP_SCRIPTS[["mediation"]], rds = file.path(cache, "mediation.rds"),
                     progress = file.path(logs, "mediation_progress.txt"), out_dir = out_dir,
                     outputs = list(mediation.csv = function(r) r$table), entries = function(r) r$entries),
    secondary = list(name = "secondary", script = E_STEP_SCRIPTS[["secondary"]], rds = file.path(cache, "secondary.rds"),
                     progress = file.path(logs, "secondary_progress.txt"), out_dir = out_dir,
                     outputs = list(
                       sensitivity.csv = function(r) data.table::rbindlist(list(r$tables$sens, r$tables$l, r$tables$bfgs), fill = TRUE),
                       dlm.csv = function(r) r$tables$dlm,
                       iod.csv = function(r) data.table::rbindlist(list(r$tables$iod, r$tables$iod_n), fill = TRUE),
                       heterogeneity.csv = function(r) r$tables$het,
                       het_modes.csv = het_modes),
                     entries = function(r) r$entries),
    forecast = list(name = "forecast", script = E_STEP_SCRIPTS[["forecast"]], rds = file.path(cache, "forecast.rds"),
                    progress = NULL, out_dir = out_dir,
                    outputs = list(forecast_skill.csv = function(r) r$skill, index_comparison.csv = function(r) r$idx),
                    entries = function(r) r$entries))
}

e_pending_step <- function(name, reason, script = E_STEP_SCRIPTS[[name]])
  list(name = name, script = script, status = "pending", reason = reason)

# Run a producer as its own Rscript process from models/ (stdout and stderr to models/E/logs/run_all_<step>.out).
e_run_step <- function(def, refit = FALSE) {
  args <- c(file.path("E", def$script), if (identical(def$name, "power") && !refit) "--reuse")
  log <- file.path(E_LOGS, sprintf("run_all_%s.out", def$name))
  dir.create(E_LOGS, recursive = TRUE, showWarnings = FALSE)
  owd <- setwd(MODELS_ROOT)
  on.exit(setwd(owd))
  elog(sprintf("run_all: running Rscript %s (log %s)", paste(args, collapse = " "), log), file = "results.log")
  st <- system2("Rscript", args, stdout = log, stderr = log)
  if (!identical(as.integer(st), 0L)) stop(sprintf("step %s: Rscript %s exited with status %s (see %s)", def$name,
                                                   paste(args, collapse = " "), st, log), call. = FALSE)
  invisible(TRUE)
}

.pending_or_stop <- function(def, reason, allow_pending) {
  if (allow_pending) return(e_pending_step(def$name, reason, script = def$script))
  stop(sprintf("step %s (%s) not finished: %s; rerun with --allow-pending to mark its keys pending", def$name, def$script,
               reason), call. = FALSE)
}

# Resolve one producer step (modes in the header). alive(progress) -> TRUE while the step's detached run is alive;
# run(def) runs it. Returns list(name, script, status = "cached" | "pending", entries, reason, outputs, rds_sha256).
resolve_e_step <- function(def, mode = c("use_cache", "default", "refit"), allow_pending = FALSE, alive = power_run_alive,
                           run = function(def) e_run_step(def, refit = identical(mode, "refit")),
                           release = e_release_mode()) {
  mode <- match.arg(mode)
  out_paths <- file.path(def$out_dir, names(def$outputs))
  if (!is.null(def$progress) && isTRUE(alive(def$progress))) {
    reason <- sprintf("still running (pid %s)", .progress_pid(def$progress))
    if (mode == "refit") stop(sprintf("step %s (%s) is %s: not launched", def$name, def$script, reason), call. = FALSE)
    return(.pending_or_stop(def, reason, allow_pending))
  }
  have_rds <- file.exists(def$rds); have_out <- file.exists(out_paths)
  if (mode == "refit" || (mode == "default" && !have_rds && !any(have_out))) {
    run(def)
    have_rds <- file.exists(def$rds); have_out <- file.exists(out_paths)
    if (!have_rds || !all(have_out)) stop(sprintf("step %s: %s did not write its cache and outputs", def$name, def$script),
                                          call. = FALSE)
  }
  if (!have_rds && !any(have_out)) return(.pending_or_stop(def, "outputs not written yet", allow_pending))
  if (!have_rds && all(have_out) && isTRUE(release)) return(release_e_step(def))
  if (!have_rds) stop(sprintf("step %s: the cache %s is missing but its output(s) %s exist; refusing to refit (restore the cache or rerun with --refit)",
                              def$name, .e_rel(def$rds), paste(.e_rel(out_paths[have_out]), collapse = ", ")), call. = FALSE)
  if (!all(have_out)) stop(sprintf("step %s: the cache %s exists but output(s) %s are missing", def$name, .e_rel(def$rds),
                                   paste(.e_rel(out_paths[!have_out]), collapse = ", ")), call. = FALSE)
  r <- readRDS(def$rds)
  outs <- data.table::rbindlist(lapply(seq_along(out_paths), function(i) {
    got <- .e_sha256_lf(out_paths[i])
    want <- .e_table_sha(def$outputs[[i]](r))
    if (!identical(got, want))
      stop(sprintf("step %s: %s differs from the table in its cache %s (the cache and the output are from different runs); refusing to assemble",
                   def$name, .e_rel(out_paths[i]), .e_rel(def$rds)), call. = FALSE)
    data.table::data.table(path = .e_rel(out_paths[i]), sha256_lf = got)
  }))
  list(name = def$name, script = def$script, status = "cached", entries = def$entries(r), reason = NA_character_,
       outputs = outs, rds = .e_rel(def$rds), rds_sha256 = unname(cli::hash_file_sha256(def$rds)))
}

# Release mode (final-review finding 3): the step caches (models/E/_cache/<step>.rds) are git-ignored and are not in
# the public release, so a step whose outputs are all present is resolved from the shipped files, without fitting:
# each output's sha256 (CRLF -> LF) must equal the value the shipped papers/E/output/provenance.csv records for it (the
# outputs results.json was assembled from); a step with a from_outputs reader (power) has its keys recomputed from its
# output table; the keys of the other steps are read from the shipped papers/E/results.json (their computation needs
# the fitted models, i.e. a refit). Returns the resolve_e_step() list with status "release".
release_e_step <- function(def, results_json = file.path(PAPER_E, "results.json"),
                           prov_csv = file.path(E_OUT, "provenance.csv"), contract = E_CONTRACT) {
  out_paths <- file.path(def$out_dir, names(def$outputs))
  if (!file.exists(prov_csv)) stop(sprintf("step %s: release mode needs the shipped %s", def$name, .e_rel(prov_csv)),
                                   call. = FALSE)
  prov <- data.table::fread(prov_csv, colClasses = "character")
  outs <- data.table::rbindlist(lapply(out_paths, function(p) {
    rel <- .e_rel(p)
    got <- .e_sha256_lf(p)
    want <- prov[prov$item == paste0("output:", rel)]$value
    if (length(want) != 1L) stop(sprintf("step %s: %s has no output row in %s", def$name, rel, .e_rel(prov_csv)),
                                 call. = FALSE)
    if (!identical(got, want))
      stop(sprintf("step %s: %s differs from the file recorded in %s (sha256 %s, recorded %s); refusing to assemble",
                   def$name, rel, .e_rel(prov_csv), got, want), call. = FALSE)
    data.table::data.table(path = rel, sha256_lf = got)
  }))
  if (!is.null(def$from_outputs)) {
    tabs <- lapply(out_paths, function(p) data.table::fread(p, na.strings = c("", "NA", "NaN"),
                                                            colClasses = def$col_classes))
    names(tabs) <- names(def$outputs)
    entries <- def$entries(def$from_outputs(tabs))
    how <- sprintf("release mode: keys recomputed from %s", paste(outs$path, collapse = ", "))
  } else {
    want <- contract_keys(contract, prefix = "E")
    ks <- want[e_key_step(want) == def$name]
    js <- jsonlite::read_json(results_json, simplifyVector = FALSE)
    miss <- setdiff(ks, names(js))
    if (length(miss)) stop(sprintf("step %s: %d key(s) missing from %s: %s", def$name, length(miss), .e_rel(results_json),
                                   paste(head(miss, 10), collapse = ", ")), call. = FALSE)
    entries <- lapply(js[ks], function(e) list(value = if (is.null(e$value)) NA else e$value, display = e$display,
                                               script = e$script, description = e$description))
    how <- sprintf("release mode: keys read from the shipped %s, outputs verified against %s", .e_rel(results_json),
                   .e_rel(prov_csv))
  }
  list(name = def$name, script = def$script, status = "release", entries = entries, reason = how, outputs = outs,
       rds = NA_character_, rds_sha256 = NA_character_)
}

# Release check: the assembled results.json against the shipped one. Returns list(n, value_display (keys whose value
# or display differ), description (keys whose description alone differs), missing, extra).
compare_e_results <- function(new_json, shipped_json = file.path(PAPER_E, "results.json")) {
  a <- jsonlite::read_json(new_json, simplifyVector = FALSE)
  b <- jsonlite::read_json(shipped_json, simplifyVector = FALSE)
  common <- intersect(names(a), names(b))
  nz <- function(v) if (is.null(v)) NA else v
  same_vd <- vapply(common, function(k) identical(nz(a[[k]]$value), nz(b[[k]]$value)) &&
                                         identical(a[[k]]$display, b[[k]]$display), NA)
  vd <- common[!same_vd]
  same_de <- vapply(common, function(k) identical(a[[k]]$description, b[[k]]$description), NA)
  de <- setdiff(common[!same_de], vd)
  list(n = length(common), value_display = vd, description = de, missing = setdiff(names(b), names(a)),
       extra = setdiff(names(a), names(b)))
}

# ------------------------------------------------------------------ assembly and writing

.pending_entries <- function(keys, step) {
  sc <- step$script
  stats::setNames(lapply(keys, function(k) .res_e(NA, sprintf(PENDING_FMT, sc),
    sprintf("Pending: models/E/%s has not finished (%s); a results.json with pending keys is not committed", sc, step$reason),
    script = paste0("models/E/", sc))), keys)
}

# Every key of an outcome dropped by the 20% rule (E.gates.<o>.dropped) must hold no estimate in the model sections.
check_dropped <- function(E) {
  dropped <- INDS[vapply(INDS, function(o) identical(E[[sprintf("E.gates.%s.dropped", o)]]$display, DROPPED_DISPLAY), NA)]
  for (o in dropped) {
    ks <- grep(sprintf("^E\\.(t|s|l|h7|h9|med|het|iod|dlm|sens|fc|idx)\\.%s\\.", o), names(E), value = TRUE)
    for (k in ks) {
      v <- E[[k]]$value
      if (is.numeric(v) && length(v) == 1L && !is.na(v))
        stop(sprintf("06_results: dropped outcome %s has a value in %s (%s)", o, k, E[[k]]$display), call. = FALSE)
    }
  }
  invisible(dropped)
}

# steps: named list of resolved steps (resolve_e_step() or e_pending_step()). Returns every entry after the key-set
# check, with attr "pending" (keys per pending step, by step name) and attr "pending_reasons".
assemble_e_results <- function(steps, panel = panel_keys(), contract = E_CONTRACT, allow_pending = FALSE) {
  assert_contract_counts(contract)
  want <- contract_keys(contract, prefix = "E")
  own <- e_key_step(want)
  entries <- panel
  pend <- integer(); why <- character()
  for (s in steps) {
    e <- if (identical(s$status, "pending")) {
      ks <- want[own == s$name]
      pend[[s$name]] <- length(ks); why[[s$name]] <- s$reason
      .pending_entries(ks, s)
    } else s$entries
    dup <- intersect(names(entries), names(e))
    if (length(dup)) stop("06_results: duplicate key(s) from step ", s$name, ": ", paste(head(dup, 10), collapse = ", "),
                          call. = FALSE)
    entries <- c(entries, e)
  }
  prim <- Filter(function(s) identical(s$name, "primary"), steps)
  if (length(prim) && identical(prim[[1]]$status, "pending")) {
    entries <- c(entries, .pending_entries("E.abstract.conclusion_sentence", prim[[1]]))
    pend[["primary"]] <- pend[["primary"]] + 1L
  } else entries <- c(entries, conclusion_entry(entries))
  missing <- setdiff(want, names(entries)); extra <- setdiff(names(entries), want)
  if (length(missing) || length(extra))
    stop("06_results: key set differs from the contract. Missing: ", paste(head(missing, 40), collapse = ", "),
         ". Extra: ", paste(head(extra, 40), collapse = ", "), call. = FALSE)
  check_dropped(entries)
  if (length(pend)) {
    o <- order(names(pend), method = "radix")
    pend <- pend[o]; why <- why[o]
  }
  if (length(pend) && !allow_pending)
    stop("06_results: pending: ", paste(sprintf("%s (%d keys; %s)", names(pend), pend, why), collapse = "; "), call. = FALSE)
  entries <- entries[order(names(entries), method = "radix")]
  attr(entries, "pending") <- if (length(pend)) pend else stats::setNames(integer(), character())
  attr(entries, "pending_reasons") <- why
  entries
}

e_provenance <- function(steps, n_keys, pending, release = e_release_mode()) {
  if (isTRUE(release)) {                       # the public release: no working-repository history to read
    code_commit <- "release copy"
    code_dirty <- NA
  } else {
    code_commit <- .e_git(c("log", "-1", "--format=%h", "--", E_CODE_PATHS))[1]
    code_dirty <- length(.e_git(c("status", "--porcelain", "--", E_CODE_PATHS))) > 0L
  }
  rows <- list(data.table::data.table(
    item = c("results_code_commit", "results_code_dirty", "seed", "n_keys", "n_pending"),
    value = c(code_commit, as.character(code_dirty), as.character(SEED_E), as.character(n_keys), as.character(sum(pending))),
    note = c(paste("last commit touching", paste(E_CODE_PATHS, collapse = ", ")),
             "TRUE if those paths had uncommitted changes when results.json was assembled",
             "SEED_E (models/E/R/common_e.R)", "keys in results.json (= contract)",
             "keys displayed 'pending (<script> not finished)'; a results.json with pending keys is not committed")))
  inp <- file.path(REPO_ROOT, E_PROV_INPUTS)
  rows[[2]] <- data.table::data.table(item = paste0("input:", E_PROV_INPUTS), value = vapply(inp, .e_sha256_lf, ""),
                                      note = paste("sha256 (CRLF -> LF);", vapply(inp, .e_git_state, "")))
  for (s in steps) {
    if (identical(s$status, "pending")) {
      rows[[length(rows) + 1L]] <- data.table::data.table(item = paste0("step:", s$name), value = "pending",
        note = sprintf("models/E/%s: %s; %d keys pending", s$script, s$reason, pending[[s$name]]))
      next
    }
    rows[[length(rows) + 1L]] <- data.table::data.table(item = paste0("step:", s$name), value = s$status,
      note = if (identical(s$status, "release")) sprintf("models/E/%s; %d keys (%s)", s$script, length(s$entries), s$reason)
             else sprintf("models/E/%s; %d keys from its cache", s$script, length(s$entries)))
    if (!is.null(s$rds_sha256) && !is.na(s$rds_sha256))
      rows[[length(rows) + 1L]] <- data.table::data.table(item = paste0("cache:", s$name), value = s$rds_sha256,
                                                          note = paste("sha256 of", s$rds, "(git-ignored)"))
    if (!is.null(s$outputs) && nrow(s$outputs))
      rows[[length(rows) + 1L]] <- s$outputs[, .(item = paste0("output:", path), value = sha256_lf,
        note = paste(if (identical(s$status, "release")) "sha256 (CRLF -> LF); equals the shipped provenance.csv;"
                     else "sha256 (CRLF -> LF); equals the cached table;", vapply(file.path(REPO_ROOT, path), .e_git_state, "")))]
  }
  data.table::rbindlist(rows)
}

# Output paths: out_dir when given (F25 check); else papers/E/results.json and papers/E/output/provenance.csv, or,
# with allow_pending, the git-ignored results.pending.json and output/provenance.pending.csv.
e_output_paths <- function(out_dir = NULL, allow_pending = FALSE) {
  if (!is.null(out_dir)) return(list(json = file.path(out_dir, "results.json"), prov = file.path(out_dir, "provenance.csv")))
  if (allow_pending) return(list(json = file.path(PAPER_E, "results.pending.json"),
                                 prov = file.path(E_OUT, "provenance.pending.csv")))
  list(json = file.path(PAPER_E, "results.json"), prov = file.path(E_OUT, "provenance.csv"))
}

# Assemble, check and write results.json and provenance.csv (F9: output paths are parameters). Pending keys are never
# written to papers/E/results.json or papers/E/output/provenance.csv. Returns the entries, the pending counts and the
# provenance table invisibly.
write_e_results <- function(steps, panel = panel_keys(), out_json = file.path(PAPER_E, "results.json"),
                            out_prov = file.path(E_OUT, "provenance.csv"), allow_pending = FALSE, contract = E_CONTRACT) {
  entries <- assemble_e_results(steps, panel = panel, contract = contract, allow_pending = allow_pending)
  pend <- attr(entries, "pending")
  attr(entries, "pending") <- NULL; attr(entries, "pending_reasons") <- NULL
  repo_out <- normalizePath(c(file.path(PAPER_E, "results.json"), file.path(E_OUT, "provenance.csv")), winslash = "/",
                            mustWork = FALSE)
  hit <- normalizePath(c(out_json, out_prov), winslash = "/", mustWork = FALSE) %in% repo_out
  if (length(pend) && any(hit))
    stop(sprintf("06_results: %d pending keys are never written to papers/E/results.json or output/provenance.csv (use results.pending.json)",
                 sum(pend)), call. = FALSE)
  write_results(entries, out_json)
  prov <- e_provenance(steps, length(entries), pend)
  dir.create(dirname(out_prov), recursive = TRUE, showWarnings = FALSE)
  data.table::fwrite(prov, out_prov, eol = "\n")
  invisible(list(entries = entries, pending = pend, provenance = prov))
}
