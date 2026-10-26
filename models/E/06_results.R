# Paper E Task 11: results assembly (contract papers/E/results_keys.md, 674 keys; rulings F9, F15, F20, F25).
# Resolves the producer steps 01-05 (resolve_e_step() in models/E/R/results_e.R), adds the §1 panel keys
# (panel_keys(), the single producer of E.exposure.*), the §7 power keys (power_keys() from power.csv) and the §14
# conclusion sentence, stops unless the key set equals the contract (and every section's declared "(N keys)"), and
# writes papers/E/results.json and papers/E/output/provenance.csv.
#
# Run through models/E/run_all.R, or alone from <repo>/models to reassemble from the step caches (never fits):
#   Rscript E/06_results.R [--allow-pending] [--out-dir=DIR]
# --allow-pending  a step whose outputs do not exist yet (or that is still running) gets every key it owns displayed
#                  "pending (<script> not finished)"; without --out-dir the files go to the git-ignored
#                  papers/E/results.pending.json and papers/E/output/provenance.pending.csv, never results.json; the
#                  pending report (keys per step, the reason and the key list)
#                  goes to stdout, models/E/logs/results.log and models/E/logs/results_pending.txt. Without it a
#                  missing output is an error. A results.json with pending keys is never committed.
# --out-dir=DIR    write results.json and provenance.csv to DIR instead of papers/E and papers/E/output (the F25
#                  determinism check runs twice into two temporary directories and compares the SHA-256 of both files).

if (!exists("MODELS_ROOT")) source("common/R/load.R")
if (!exists("E_DIR")) source(file.path(MODELS_ROOT, "E", "R", "common_e.R"))
source(file.path(MODELS_ROOT, "E", "R", "results_e.R"))

results_settings <- function(args = commandArgs(trailingOnly = TRUE), default_mode = "use_cache") {
  known <- c("--use-cache", "--refit", "--allow-pending")
  bad <- args[!args %in% known & !grepl("^--out-dir=", args)]
  if (length(bad)) stop("06_results: unknown argument(s): ", paste(bad, collapse = " "), call. = FALSE)
  if (all(c("--use-cache", "--refit") %in% args)) stop("06_results: --use-cache and --refit exclude each other", call. = FALSE)
  mode <- if ("--refit" %in% args) "refit" else if ("--use-cache" %in% args) "use_cache" else default_mode
  od <- sub("^--out-dir=", "", grep("^--out-dir=", args, value = TRUE))
  list(mode = mode, allow_pending = "--allow-pending" %in% args, out_dir = if (length(od)) od[length(od)] else NULL)
}

# The pending report: one block per pending step (script, reason, key count, keys).
pending_report <- function(steps, pending) {
  if (!length(pending)) return("pending keys: none")
  c(sprintf("pending keys: %d (a results.json with pending keys must not be committed)", sum(pending)),
    unlist(lapply(names(pending), function(n) {
      s <- Filter(function(x) identical(x$name, n), steps)[[1]]
      want <- contract_keys(E_CONTRACT, prefix = "E")
      ks <- want[e_key_step(want) == n]
      if (n == "primary") ks <- c(ks, "E.abstract.conclusion_sentence")
      c(sprintf("  %s (models/E/%s): %d keys; %s", n, s$script, pending[[n]], s$reason), paste0("    ", ks))
    })))
}

run_e_results <- function(mode = "use_cache", allow_pending = FALSE, out_dir = NULL, defs = e_step_defs(),
                          alive = power_run_alive) {
  t0 <- Sys.time()
  elog(sprintf("06_results: mode %s, allow_pending %s, out_dir %s", mode, allow_pending,
               if (is.null(out_dir)) "(repository)" else out_dir), file = "results.log")
  steps <- lapply(defs, function(d) resolve_e_step(d, mode = mode, allow_pending = allow_pending, alive = alive))
  for (s in steps) elog(sprintf("step %s: %s%s", s$name, s$status,
                                if (identical(s$status, "pending")) paste0(" (", s$reason, ")") else
                                  if (identical(s$status, "release")) sprintf(" (%d keys; %s)", length(s$entries), s$reason) else
                                  sprintf(" (%d keys from %s)", length(s$entries), s$rds)), file = "results.log")
  released <- any(vapply(steps, function(s) identical(s$status, "release"), NA))
  if (released && is.null(out_dir)) {              # never overwrite the shipped results with a release-mode assembly
    out_dir <- file.path(E_LOGS, "release_check")
    elog("release mode: steps resolved from the shipped files; writing results.json and provenance.csv to ", out_dir,
         " (the shipped papers/E/results.json and output/provenance.csv are not overwritten)", file = "results.log")
  }
  paths <- e_output_paths(out_dir, allow_pending)
  out_json <- paths$json; out_prov <- paths$prov
  r <- write_e_results(steps, panel = panel_keys(), out_json = out_json, out_prov = out_prov, allow_pending = allow_pending)
  rep <- pending_report(steps, r$pending)
  writeLines(rep, file.path(E_LOGS, "results_pending.txt"))
  elog(rep[1], file = "results.log")
  for (n in names(r$pending)) elog(sprintf("pending: %s %d keys", n, r$pending[[n]]), file = "results.log")
  elog(sprintf("06_results: wrote %s (%d keys, %d pending) and %s in %.1f s", out_json, length(r$entries), sum(r$pending),
               out_prov, as.numeric(difftime(Sys.time(), t0, units = "secs"))), file = "results.log")
  elog("conclusion: ", r$entries[["E.abstract.conclusion_sentence"]]$display, file = "results.log")
  if (released) {
    cmp <- compare_e_results(out_json)
    lst <- function(k) if (length(k)) paste0(" (", paste(k, collapse = ", "), ")") else ""
    elog(sprintf(paste("release check: %d keys compared with the shipped papers/E/results.json; value and display",
                       "identical for %d, different for %d%s; description alone differs for %d%s"),
                 cmp$n, cmp$n - length(cmp$value_display), length(cmp$value_display), lst(cmp$value_display),
                 length(cmp$description), lst(cmp$description)), file = "results.log")
    if (length(cmp$value_display) || length(cmp$missing) || length(cmp$extra))
      stop("release check: the assembled results differ from the shipped papers/E/results.json ",
           "(see models/E/logs/results.log)", call. = FALSE)
    r$release_check <- cmp
  }
  invisible(c(r, list(steps = steps, report = rep)))
}

results_main <- function(args = commandArgs(trailingOnly = TRUE), default_mode = "use_cache") {
  s <- results_settings(args, default_mode = default_mode)
  invisible(run_e_results(mode = s$mode, allow_pending = s$allow_pending, out_dir = s$out_dir))
}

if (sys.nframe() == 0L) invisible(results_main())
