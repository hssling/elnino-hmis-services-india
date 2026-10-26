# Paper E Task 11: results assembly, traceability and the cached-step runner (models/E/R/results_e.R,
# models/E/06_results.R, models/E/run_all.R). Contract papers/E/results_keys.md (674 keys; §1 panel_keys, §7 power,
# §14 conclusion sentence); rulings F13, F15, F18, F20, F25, F52, F56. models/common/R is frozen; nothing here edits
# it. No test fits a model or reads an HMIS outcome: the panel inputs are synthetic files in a temporary directory.

local({
  root <- if (exists("MODELS_ROOT")) MODELS_ROOT else normalizePath(file.path(getwd(), "..", "..", ".."), winslash = "/")
  source(file.path(root, "E", "R", "results_e.R"), local = globalenv())
})

YES <- "consistent with"
NO <- "not consistent with"
DROP_TXT <- "not estimable (dropped: more than 20% of state-months masked)"
WANT <- contract_keys(E_CONTRACT, prefix = "E")

.fake <- function(k, value = 1, display = "1.00") res_entry(value, display, "test", paste("fake", k))

# Entries for every key a step owns; verdict keys take the fixed vocabulary.
fake_step_entries <- function(step, h7 = c(anc_reg = NO, penta3 = NO, inst_del = NO, opd = NO), h8 = NO,
                              h9 = c(anc_reg = NO, penta3 = NO, inst_del = NO, opd = NO)) {
  keys <- WANT[e_key_step(WANT) == step]
  E <- stats::setNames(lapply(keys, .fake), keys)
  if (step == "primary") {
    for (o in names(h7)) E[[sprintf("E.h7.%s.verdict", o)]] <- res_entry(h7[[o]], h7[[o]], "test", "fake")
    for (o in names(h9)) E[[sprintf("E.h9.%s.verdict", o)]] <- res_entry(h9[[o]], h9[[o]], "test", "fake")
    v7 <- overall_verdict(h7, hypothesis = "H7"); v9 <- overall_verdict(h9, hypothesis = "H9")
    E[["E.h7.verdict"]] <- res_entry(v7$verdict, v7$verdict, "test", "fake")
    E[["E.h7.verdict_text"]] <- res_entry(v7$text, v7$text, "test", "fake")
    E[["E.h9.verdict"]] <- res_entry(v9$verdict, v9$verdict, "test", "fake")
    E[["E.h9.verdict_text"]] <- res_entry(v9$text, v9$text, "test", "fake")
    E[["E.h8.verdict"]] <- res_entry(h8, h8, "test", "fake")
  }
  E
}

fake_steps <- function(...) {
  s <- lapply(c("power", "primary", "mediation", "secondary", "forecast"), function(n)
    list(name = n, status = "cached", entries = fake_step_entries(n, ...)))
  stats::setNames(s, c("power", "primary", "mediation", "secondary", "forecast"))
}

fake_panel <- function() fake_step_entries("panel")

# Synthetic panel inputs (3 units, April 2012 .. March 2021) in dir; `dropped` outcomes are dropped in gate_summary.
write_fake_panel_inputs <- function(dir, dropped = character()) {
  yms <- (2012L * 12L + 3L):(2021L * 12L + 2L)                         # April 2012 .. March 2021 (108 months)
  units <- c("AA", "BB", "CC")
  d <- data.table::CJ(unit_id = units, ym = yms)
  d[, `:=`(year = ym %/% 12L, month = ym %% 12L + 1L)]
  d[, fy := ifelse(month >= 4L, sprintf("%d-%02d", year, (year + 1L) %% 100L), sprintf("%d-%02d", year - 1L, year %% 100L))]
  d[, in_primary := as.integer(ym <= 2020L * 12L + 1L)]
  mi <- match(d$ym, yms)
  d[, oni := round(sin(mi / 9) * 1.4, 2)]
  d[, roni := round(oni * 0.9 + 0.05, 2)]
  d[, nino34_3m := round(oni * 1.1, 3)]
  for (o in INDS) {
    d[, (o) := 100 + mi]
    d[, (paste0("comp_", o)) := 0.9 + (mi %% 10) / 100]
    d[, (paste0("n_districts_", o)) := 10L + match(unit_id, units)]
  }
  d[unit_id == "AA" & mi <= 5L, diarr_u5 := NA]                       # 5 masked / incomplete primary unit-months
  d[unit_id == "BB" & mi <= 3L, `:=`(comp_anc_reg = NA, n_districts_anc_reg = NA)]   # no district list
  d[, status_date_min := ifelse(in_primary == 1L, ifelse(year < 2016L, "2015-09-19", "2018-01-02"), "2024-10-01")]
  d[, status_date_max := ifelse(in_primary == 1L, ifelse(year < 2019L, "2019-05-01", "2020-11-06"), "2024-10-01")]
  data.table::fwrite(d, file.path(dir, "hmis_model.csv"))
  g <- data.table::data.table(indicator = rep(INDS, 2), scope = rep(c("primary", "fy2020_21"), each = 7L),
                              masked = c(28L, 0L, 12L, 2L, 1L, 0L, 3L, rep(0L, 7)),
                              masked_share = c(28, 0, 12, 2, 1, 0, 3, rep(0, 7)) / 3264,
                              dropped = rep(c("False", "False"), each = 7L))
  drop_set <- dropped
  g[scope == "primary" & indicator %in% drop_set, `:=`(dropped = "True", masked = 900L, masked_share = 900 / 3264)]
  data.table::fwrite(g, file.path(dir, "gate_summary.csv"))
  data.table::fwrite(data.table::data.table(indicator = INDS, ratio = c(0.7531919, 0.92, 0.786, 0.876, 0.862, 0.838, 0.816)),
                     file.path(dir, "break_ratio_2017.csv"))
  m <- unique(d[in_primary == 1L, .(ym, oni, roni, nino34_3m)])
  data.table::fwrite(data.table::data.table(outcome = rep(INDS, each = 3L), index = rep(c("oni", "roni", "nino34"), 7L),
                                            sd_index = rep(c(stats::sd(m$oni), stats::sd(m$roni), stats::sd(m$nino34_3m)), 7L)),
                     file.path(dir, "index_comparison.csv"))
  e <- data.table::data.table(year = yms %/% 12L, month = yms %% 12L + 1L)
  e[, nino34_anom := round(cos(seq_len(.N) / 7), 2)]
  data.table::fwrite(e, file.path(dir, "enso_monthly.csv"))
  dir
}

fake_panel_keys <- function(dir, ...) panel_keys(model_csv = file.path(dir, "hmis_model.csv"),
                                                 gate_csv = file.path(dir, "gate_summary.csv"),
                                                 break_csv = file.path(dir, "break_ratio_2017.csv"),
                                                 index_csv = file.path(dir, "index_comparison.csv"),
                                                 enso_csv = file.path(dir, "enso_monthly.csv"),
                                                 fy2021 = list(ok = TRUE, reason = NA_character_, status = "acquired"), ...)

# ---- key ownership and the contract -------------------------------------------------------------------------------

test_that("results key set equals the contract", {
  expect_length(WANT, 674L)
  own <- e_key_step(WANT)
  n <- table(own)
  expect_identical(as.integer(n[c("panel", "primary", "mediation", "power", "secondary", "forecast", "conclusion")]),
                   c(64L, 156L, 35L, 36L, 214L, 168L, 1L))
  # the producers' own key selectors agree with the ownership used for pending keys
  for (f in c("02_primary.R", "04_secondary.R", "05_forecast.R")) source(file.path(MODELS_ROOT, "E", f), local = globalenv())
  expect_setequal(WANT[own == "primary"], primary_contract_keys(E_CONTRACT))
  expect_setequal(WANT[own == "secondary"], secondary_contract_keys(E_CONTRACT))
  expect_setequal(WANT[own == "forecast"], forecast_contract_keys(E_CONTRACT))

  E <- assemble_e_results(fake_steps(), panel = fake_panel())
  expect_setequal(names(E), WANT)
  expect_identical(attr(E, "pending"), stats::setNames(integer(), character()))

  s <- fake_steps(); s$secondary$entries <- s$secondary$entries[-1]
  expect_error(assemble_e_results(s, panel = fake_panel()), "key set differs from the contract. Missing: E\\.")
  s <- fake_steps(); s$forecast$entries[["E.fc.extra.key"]] <- .fake("E.fc.extra.key")
  expect_error(assemble_e_results(s, panel = fake_panel()), "Extra: E.fc.extra.key")
  s <- fake_steps(); s$forecast$entries[["E.t.opd.n"]] <- .fake("E.t.opd.n")
  expect_error(assemble_e_results(s, panel = fake_panel()), "duplicate key")
})

test_that("declared (N keys) counts match the contract sections (F20)", {
  cnt <- contract_section_counts(E_CONTRACT)
  expect_identical(nrow(cnt), 14L)
  expect_true(all(cnt$declared == cnt$found))
  expect_identical(sum(cnt$found), 674L)
  expect_identical(attr(cnt, "declared_total"), 674L)
  bad <- tempfile(fileext = ".md")
  writeLines(sub("## 9. Indian Ocean Dipole (18 keys)", "## 9. Indian Ocean Dipole (19 keys)",
                 readLines(E_CONTRACT, encoding = "UTF-8"), fixed = TRUE), bad, useBytes = TRUE)
  expect_error(assert_contract_counts(bad), "section 9 declares 19 keys but lists 18")
})

# ---- panel keys -----------------------------------------------------------------------------------------------------

test_that("panel_keys counts, displays and the shared index SDs (F15, F7)", {
  dir <- tempfile("panel"); dir.create(dir)
  write_fake_panel_inputs(dir)
  E <- fake_panel_keys(dir)
  expect_setequal(names(E), WANT[e_key_step(WANT) == "panel"])
  expect_identical(E[["E.panel.n_units"]]$display, "3")
  expect_identical(E[["E.panel.n_months"]]$display, "95")
  expect_identical(E[["E.panel.n_state_months"]]$display, "285")
  expect_identical(E[["E.panel.diarr_u5.n_valid"]]$value, 280L)
  expect_identical(E[["E.status_date.min"]]$display, "19 September 2015")
  expect_identical(E[["E.status_date.range"]]$display, "19 September 2015 to 6 November 2020")
  expect_match(E[["E.status_date.range"]]$description, "1 October 2024", fixed = TRUE)
  expect_identical(E[["E.gates.diarr_u5.n_masked"]]$display, "28")
  expect_identical(E[["E.gates.diarr_u5.share_masked"]]$display, "0.86%")
  expect_identical(E[["E.gates.opd.dropped"]]$display, "not dropped")
  expect_identical(E[["E.gates.n_dropped"]]$value, 0L)
  expect_identical(E[["E.break2017.diarr_u5.ratio"]]$display, "0.753")
  expect_identical(E[["E.fy2021.status"]]$display, "included as a COVID-flagged sensitivity analysis")
  # completeness: median and the district-weighted share over unit-months with a district list
  d <- data.table::fread(file.path(dir, "hmis_model.csv"))[in_primary == 1L]
  expect_equal(E[["E.comp.anc_reg.median"]]$value, stats::median(d$comp_anc_reg, na.rm = TRUE))
  ok <- !is.na(d$comp_anc_reg) & !is.na(d$n_districts_anc_reg) & d$n_districts_anc_reg > 0
  expect_equal(E[["E.comp.anc_reg.share_district_months_valid"]]$value,
               sum(d$comp_anc_reg[ok] * d$n_districts_anc_reg[ok]) / sum(d$n_districts_anc_reg[ok]))
  # exposure, one value per month; the SDs equal index_comparison.csv's sd_index
  m <- unique(d[, .(ym, oni, roni, nino34_3m)])
  expect_identical(E[["E.exposure.n_months"]]$value, 95L)
  expect_identical(E[["E.exposure.n_en_months"]]$value, sum(m$oni >= 0.5))
  expect_identical(E[["E.exposure.n_ln_months"]]$value, sum(m$oni <= -0.5))
  expect_equal(E[["E.exposure.oni_sd"]]$value, stats::sd(m$oni))
  expect_equal(E[["E.exposure.roni_sd"]]$value, stats::sd(m$roni))
  expect_equal(E[["E.exposure.nino34_sd"]]$value, stats::sd(m$nino34_3m))
  expect_identical(E[["E.exposure.oni_max"]]$display, fmt_num(max(m$oni), 2, plus = TRUE))
  expect_match(E[["E.exposure.oni_sd"]]$description, "index_comparison.csv", fixed = TRUE)
  # a different sd_index in index_comparison.csv is refused (one SD for the per-SD keys)
  ic <- data.table::fread(file.path(dir, "index_comparison.csv"))
  ic[index == "roni", sd_index := sd_index + 1e-6]
  data.table::fwrite(ic, file.path(dir, "index_comparison.csv"))
  expect_error(fake_panel_keys(dir), "roni.*sd_index")
  # FY2020-21 not final
  write_fake_panel_inputs(dir)
  E2 <- panel_keys(model_csv = file.path(dir, "hmis_model.csv"), gate_csv = file.path(dir, "gate_summary.csv"),
                   break_csv = file.path(dir, "break_ratio_2017.csv"), index_csv = file.path(dir, "index_comparison.csv"),
                   enso_csv = file.path(dir, "enso_monthly.csv"),
                   fy2021 = list(ok = FALSE, reason = "status file not committed", status = "acquired"))
  expect_identical(E2[["E.fy2021.status"]]$display, "not estimable (FY2020-21 status file not committed)")
})

test_that("results keyset complete when an indicator is dropped", {
  dir <- tempfile("drop"); dir.create(dir)
  write_fake_panel_inputs(dir, dropped = "fic")
  panel <- fake_panel_keys(dir)
  expect_identical(panel[["E.gates.fic.dropped"]]$display, "dropped (more than 20% of state-months masked)")
  expect_identical(panel[["E.gates.n_dropped"]]$value, 1L)
  s <- fake_steps()
  for (n in names(s)) for (k in grep("^E\\.(t|s|l|med|het|iod|dlm|sens|fc|idx)\\.fic\\.", names(s[[n]]$entries), value = TRUE))
    s[[n]]$entries[[k]] <- res_entry(NA, DROP_TXT, "test", "dropped")
  E <- assemble_e_results(s, panel = panel)
  expect_setequal(names(E), WANT)
  fic <- grep("^E\\.(t|s|l|med|het|iod|dlm|sens|fc|idx)\\.fic\\.", names(E), value = TRUE)
  expect_setequal(fic, grep("^E\\.(t|s|l|med|het|iod|dlm|sens|fc|idx)\\.fic\\.", WANT, value = TRUE))
  expect_true(all(vapply(E[fic], function(e) identical(e$display, DROP_TXT), NA)))
  # an estimate in a key of a dropped outcome is refused
  s$primary$entries[["E.t.fic.irr_en"]] <- res_entry(0.98, "0.98 (95% CI 0.95–1.01)", "test", "x")
  expect_error(assemble_e_results(s, panel = panel), "dropped outcome fic has a value in E.t.fic.irr_en")
})

# ---- power keys -----------------------------------------------------------------------------------------------------

fake_power_table <- function() {
  row <- function(o, irr, power, status = "estimated") data.table::data.table(
    outcome = o, direction = power_direction(o), irr = irr, n_sim = 200L, n_ok = if (status == "estimated") 200L else NA_integer_,
    power = power, mean_irr = irr, status = status)
  tab <- data.table::rbindlist(c(
    lapply(seq_along(power_irrs("diarr_u5")), function(i) row("diarr_u5", power_irrs("diarr_u5")[i], c(1, 1, 0.825, 0.14)[i])),
    lapply(seq_along(power_irrs("anc_reg")), function(i) row("anc_reg", power_irrs("anc_reg")[i], c(1, 1, 1, 0.61)[i])),
    lapply(seq_along(power_irrs("penta3")), function(i) row("penta3", power_irrs("penta3")[i], c(0.7, 0.3, 0.1, 0.05)[i])),
    lapply(power_irrs("mcv1"), function(x) row("mcv1", x, NA_real_, "not estimated (power simulation time budget)"))))
  for (o in unique(tab$outcome)) {
    m <- if (tab[outcome == o]$status[1] == "estimated") mde(tab[outcome == o], power_direction(o)) else
      list(value = NA_real_, display = tab[outcome == o]$status[1])
    tab[outcome == o, `:=`(mde = m$value, mde_display = m$display)]
  }
  tab[]
}

test_that("power keys from power.csv: MDE rule, reciprocal IRRs for diarr_u5 and the budget reason", {
  E <- power_keys(fake_power_table(), outcomes = c("diarr_u5", "anc_reg", "penta3", "mcv1"))
  expect_identical(E[["E.power.diarr_u5.mde"]]$display, "1.03")
  expect_identical(E[["E.power.diarr_u5.p097"]]$display, "82%")
  expect_match(E[["E.power.diarr_u5.p097"]]$description, "1/0.97", fixed = TRUE)
  expect_identical(E[["E.power.anc_reg.mde"]]$display, "0.97")
  expect_identical(E[["E.power.anc_reg.p099"]]$display, "61%")
  expect_identical(E[["E.power.penta3.mde"]]$display, "not reached at IRR 0.90")
  expect_true(is.na(E[["E.power.penta3.mde"]]$value))
  for (k in c("mde", "p090", "p095", "p097", "p099"))
    expect_identical(E[[paste0("E.power.mcv1.", k)]]$display, "not estimated (power simulation time budget)")
  expect_identical(E[["E.power.n_sim"]]$display, "200")
  # an MDE in power.csv that disagrees with the MDE rule is refused
  bad <- fake_power_table(); bad[outcome == "anc_reg", mde_display := "0.95"]
  expect_error(power_keys(bad, outcomes = c("diarr_u5", "anc_reg", "penta3", "mcv1")), "anc_reg.*MDE")
  expect_error(power_keys(fake_power_table(), outcomes = INDS), "power.csv has no rows for fic")
})

# ---- conclusion sentence ------------------------------------------------------------------------------------------

test_that("conclusion sentence uses only contract templates", {
  E <- fake_step_entries("primary")
  s0 <- conclusion_sentence(E)
  expect_identical(s0, paste0("In this state-month analysis of routine HMIS data from India, 2012–2020, the results were ",
    "not consistent with lower use of essential services during the El Niño phase; ",
    "not consistent with more reported diarrhoea in children under 5 years during the El Niño phase; and ",
    "not consistent with lower service use in state-months with more heatwave days or a rainfall deficit."))
  E <- fake_step_entries("primary", h7 = c(anc_reg = YES, penta3 = NO, inst_del = YES, opd = NO), h8 = YES,
                         h9 = c(anc_reg = NO, penta3 = NO, inst_del = NO, opd = YES))
  s1 <- conclusion_sentence(E)
  expect_identical(s1, paste0("In this state-month analysis of routine HMIS data from India, 2012–2020, the results were ",
    "consistent with lower use of essential services during the El Niño phase (ANC registration and institutional deliveries); ",
    "consistent with more reported diarrhoea in children under 5 years during the El Niño phase; and ",
    "consistent with lower service use in state-months with more heatwave days or a rainfall deficit (outpatient attendance)."))
  # every fixed phrase is the contract's own (§14 template lines)
  md <- paste(readLines(E_CONTRACT, encoding = "UTF-8"), collapse = "\n")
  for (ph in CONCLUSION_PHRASES) expect_true(grepl(ph, md, fixed = TRUE), info = ph)
  for (s in c(s0, s1)) {
    expect_false(grepl(CONCLUSION_CAUSAL_RE, s, ignore.case = TRUE, perl = TRUE))
    expect_false(grepl("Paper [A-E]\\b", s))
  }
  # stops: a missing key, a verdict outside the vocabulary, a null display, an inconsistent overall verdict
  E2 <- E; E2[["E.h8.verdict"]] <- NULL
  expect_error(conclusion_sentence(E2), "missing key E.h8.verdict")
  E2 <- E; E2[["E.h9.opd.verdict"]] <- res_entry("maybe", "maybe", "test", "x")
  expect_error(conclusion_sentence(E2), "outside")
  E2 <- E; E2[["E.h7.verdict"]] <- res_entry(NO, NO, "test", "x")
  expect_error(conclusion_sentence(E2), "E.h7.verdict")
  E2 <- E; E2[["E.h8.verdict"]] <- res_entry(NA, "not estimable (x)", "test", "x")
  expect_error(conclusion_sentence(E2), "outside")
})

# ---- pending steps and the cached-step resolution -----------------------------------------------------------------

test_that("pending steps mark every key they own and are reported", {
  s <- fake_steps()
  s$mediation <- e_pending_step("mediation", "still running (pid 1)")
  s$power <- e_pending_step("power", "outputs not written yet")
  E <- assemble_e_results(s, panel = fake_panel(), allow_pending = TRUE)
  expect_setequal(names(E), WANT)
  med <- grep("^E\\.med\\.", names(E), value = TRUE)
  expect_true(all(vapply(E[med], function(e) identical(e$display, "pending (03_mediation.R not finished)") && is.na(e$value), NA)))
  expect_identical(E[["E.power.n_sim"]]$display, "pending (01_power.R not finished)")
  expect_identical(attr(E, "pending"), c(mediation = 35L, power = 36L))
  expect_error(assemble_e_results(s, panel = fake_panel()), "pending: mediation \\(35 keys; still running \\(pid 1\\)\\)")
  # the conclusion sentence is pending while the primary step is
  s <- fake_steps(); s$primary <- e_pending_step("primary", "outputs not written yet")
  E <- assemble_e_results(s, panel = fake_panel(), allow_pending = TRUE)
  expect_identical(E[["E.abstract.conclusion_sentence"]]$display, "pending (02_primary.R not finished)")
  expect_identical(attr(E, "pending")[["primary"]], 157L)
})

fake_def <- function(dir) list(name = "fake", script = "09_fake.R", rds = file.path(dir, "fake.rds"),
                               progress = file.path(dir, "fake_progress.txt"),
                               outputs = list(fake.csv = function(r) r$table), entries = function(r) r$entries,
                               out_dir = dir)

test_that("resolve_e_step never fits a finished or running step under --use-cache", {
  dir <- tempfile("step"); dir.create(dir)
  def <- fake_def(dir)
  ran <- 0L
  run <- function(def) {
    ran <<- ran + 1L
    r <- list(table = data.table::data.table(a = 1:2, b = c(0.1, NA)), entries = list(E.x = .fake("E.x")))
    data.table::fwrite(r$table, file.path(def$out_dir, "fake.csv"), eol = "\n")
    saveRDS(r, def$rds)
  }
  dead <- function(p) FALSE; alive <- function(p) TRUE
  # nothing written yet: pending with --allow-pending, an error without
  p <- resolve_e_step(def, mode = "use_cache", allow_pending = TRUE, alive = dead, run = run, release = FALSE)
  expect_identical(p$status, "pending"); expect_identical(ran, 0L)
  expect_error(resolve_e_step(def, mode = "use_cache", allow_pending = FALSE, alive = dead, run = run, release = FALSE), "not finished")
  # default mode runs a step with no output
  r <- resolve_e_step(def, mode = "default", allow_pending = FALSE, alive = dead, run = run, release = FALSE)
  expect_identical(ran, 1L); expect_identical(r$status, "cached"); expect_named(r$entries, "E.x")
  # finished: reused in every mode but refit; never refitted under --use-cache or default
  for (m in c("use_cache", "default")) {
    r <- resolve_e_step(def, mode = m, allow_pending = FALSE, alive = dead, run = run, release = FALSE)
    expect_identical(r$status, "cached")
  }
  expect_identical(ran, 1L)
  expect_match(r$outputs$sha256_lf, "^[0-9a-f]{64}$")
  # a running step is never launched and its outputs are not read
  r <- resolve_e_step(def, mode = "use_cache", allow_pending = TRUE, alive = alive, run = run, release = FALSE)
  expect_identical(r$status, "pending"); expect_match(r$reason, "still running")
  expect_error(resolve_e_step(def, mode = "refit", allow_pending = TRUE, alive = alive, run = run, release = FALSE), "still running")
  expect_identical(ran, 1L)
  # cache and committed output disagree: refused
  data.table::fwrite(data.table::data.table(a = 1:2, b = c(0.2, NA)), file.path(dir, "fake.csv"), eol = "\n")
  expect_error(resolve_e_step(def, mode = "use_cache", allow_pending = TRUE, alive = dead, run = run, release = FALSE), "differs from")
  # an output without its cache: refused, not refitted
  unlink(def$rds)
  expect_error(resolve_e_step(def, mode = "use_cache", allow_pending = TRUE, alive = dead, run = run, release = FALSE), "cache .* is missing")
  expect_error(resolve_e_step(def, mode = "default", allow_pending = TRUE, alive = dead, run = run, release = FALSE), "cache .* is missing")
  expect_identical(ran, 1L)
  # --refit reruns
  r <- resolve_e_step(def, mode = "refit", allow_pending = FALSE, alive = dead, run = run, release = FALSE)
  expect_identical(ran, 2L); expect_identical(r$status, "cached")
  # CRLF line ends in the committed output (git autocrlf checkout) are not a difference
  b <- readBin(file.path(dir, "fake.csv"), "raw", 1e4)
  writeBin(unlist(lapply(b, function(x) if (x == as.raw(10L)) as.raw(c(13L, 10L)) else x)), file.path(dir, "fake.csv"))
  expect_identical(resolve_e_step(def, mode = "use_cache", allow_pending = FALSE, alive = dead, run = run, release = FALSE)$status, "cached")
})

test_that("release mode: the marker or E_RELEASE_MODE switches it on, E_RELEASE_MODE=0 off (final review, finding 3)", {
  old <- Sys.getenv("E_RELEASE_MODE", NA)
  on.exit(if (is.na(old)) Sys.unsetenv("E_RELEASE_MODE") else Sys.setenv(E_RELEASE_MODE = old))
  m <- tempfile("marker")
  Sys.unsetenv("E_RELEASE_MODE")
  expect_false(e_release_mode(m))
  writeLines("x", m)
  expect_true(e_release_mode(m))
  Sys.setenv(E_RELEASE_MODE = "0"); expect_false(e_release_mode(m))
  Sys.setenv(E_RELEASE_MODE = "1"); expect_true(e_release_mode(tempfile("none")))
})

test_that("release mode resolves a step without its cache from the shipped outputs and results (finding 3)", {
  dir <- tempfile("rel"); dir.create(dir)
  tab <- data.table::data.table(a = 1:2, b = c(0.1, NA))
  data.table::fwrite(tab, file.path(dir, "fake.csv"), eol = "\n")
  def <- fake_def(dir)
  def$name <- "primary"                         # a step that owns contract keys
  sha <- .e_sha256_lf(file.path(dir, "fake.csv"))
  prov <- file.path(dir, "provenance.csv")
  data.table::fwrite(data.table::data.table(item = paste0("output:", .e_rel(file.path(dir, "fake.csv"))), value = sha,
                                            note = "x"), prov)
  ks <- WANT[e_key_step(WANT) == "primary"]
  shipped <- stats::setNames(lapply(ks, function(k) res_entry(if (k == ks[1]) NA else 1.5, "1.50", "s", "d")), ks)
  js <- file.path(dir, "results.json")
  write_results(shipped, js)
  def$out_dir <- dir
  run <- function(def) stop("must not fit")
  # without release mode: refused as before
  expect_error(resolve_e_step(def, mode = "use_cache", alive = function(p) FALSE, run = run, release = FALSE),
               "cache .* is missing")
  r <- release_e_step(def, results_json = js, prov_csv = prov)
  expect_identical(r$status, "release")
  expect_setequal(names(r$entries), ks)
  expect_true(is.na(r$entries[[ks[1]]]$value))
  expect_identical(r$entries[[ks[2]]]$display, "1.50")
  expect_identical(r$outputs$sha256_lf, sha)
  # an output that differs from the recorded one is refused
  data.table::fwrite(data.table::data.table(a = 1:2, b = c(0.2, NA)), file.path(dir, "fake.csv"), eol = "\n")
  expect_error(release_e_step(def, results_json = js, prov_csv = prov), "differs from the file recorded")
  # a step with a from_outputs reader recomputes its keys from the output table
  data.table::fwrite(tab, file.path(dir, "fake.csv"), eol = "\n")
  def$from_outputs <- function(t) list(entries = list(E.x = .fake("E.x", value = nrow(t[["fake.csv"]]))))
  expect_identical(release_e_step(def, results_json = js, prov_csv = prov)$entries$E.x$value, 2L)
})

test_that("compare_e_results separates value/display differences from description-only ones", {
  a <- tempfile(fileext = ".json"); b <- tempfile(fileext = ".json")
  write_results(list(E.a = res_entry(1, "1", "s", "d1"), E.b = res_entry(NA, "n", "s", "d"), E.c = res_entry(2, "2", "s", "d")), a)
  write_results(list(E.a = res_entry(1, "1", "s", "d2"), E.b = res_entry(NA, "n", "s", "d"), E.c = res_entry(3, "3", "s", "d")), b)
  r <- compare_e_results(a, b)
  expect_identical(r$n, 3L); expect_identical(r$value_display, "E.c"); expect_identical(r$description, "E.a")
})

# ---- writing: results.json, provenance.csv, determinism (F25) ------------------------------------------------------

test_that("write_e_results writes the contract key set and is byte-identical across two runs (F25)", {
  s <- fake_steps(); s$mediation <- e_pending_step("mediation", "still running (pid 1)")
  out <- lapply(1:2, function(i) {
    d <- tempfile(paste0("run", i)); dir.create(d)
    write_e_results(s, panel = fake_panel(), out_json = file.path(d, "results.json"),
                    out_prov = file.path(d, "provenance.csv"), allow_pending = TRUE)
    c(json = unname(cli::hash_file_sha256(file.path(d, "results.json"))),
      prov = unname(cli::hash_file_sha256(file.path(d, "provenance.csv"))), dir = d)
  })
  expect_identical(out[[1]][c("json", "prov")], out[[2]][c("json", "prov")])
  j <- jsonlite::fromJSON(file.path(out[[1]][["dir"]], "results.json"), simplifyVector = FALSE)
  expect_setequal(names(j), WANT)
  prov <- data.table::fread(file.path(out[[1]][["dir"]], "provenance.csv"))
  expect_true(all(c("results_code_commit", "results_code_dirty", "seed", "n_keys", "n_pending", "step:mediation",
                    paste0("input:", E_PROV_INPUTS)) %in% prov$item))
  expect_identical(prov[item == "seed"]$value, as.character(SEED_E))
  expect_identical(prov[item == "n_pending"]$value, "35")
  expect_match(prov[item == "input:data/derived/hmis/hmis_model.csv"]$value, "^[0-9a-f]{64}$")
  expect_error(write_e_results(s, panel = fake_panel(), out_json = tempfile(), out_prov = tempfile()), "pending")
})

test_that("run_all / 06_results flags map to the step modes", {
  source(file.path(MODELS_ROOT, "E", "06_results.R"), local = globalenv())
  expect_identical(results_settings(character(), default_mode = "default")$mode, "default")
  expect_identical(results_settings("--use-cache", default_mode = "default")$mode, "use_cache")
  expect_identical(results_settings("--refit")$mode, "refit")
  s <- results_settings(c("--use-cache", "--allow-pending", "--out-dir=C:/tmp/x"))
  expect_true(s$allow_pending); expect_identical(s$out_dir, "C:/tmp/x")
  expect_false(results_settings("--use-cache")$allow_pending)
  expect_error(results_settings(c("--use-cache", "--refit")), "exclude each other")
  expect_error(results_settings("--usecache"), "unknown argument")
})

test_that("pending assemblies never go to papers/E/results.json (review fix round 1)", {
  p <- e_output_paths(NULL, allow_pending = TRUE)
  expect_identical(basename(p$json), "results.pending.json")
  expect_identical(basename(p$prov), "provenance.pending.csv")
  expect_identical(basename(e_output_paths(NULL, FALSE)$json), "results.json")
  expect_identical(e_output_paths("X", TRUE)$json, file.path("X", "results.json"))
  s <- fake_steps(); s$mediation <- e_pending_step("mediation", "still running (pid 1)")
  existed <- file.exists(file.path(PAPER_E, "results.json"))
  expect_error(write_e_results(s, panel = fake_panel(), out_json = file.path(PAPER_E, "results.json"),
                               out_prov = tempfile(), allow_pending = TRUE), "never written to papers/E/results.json")
  expect_error(write_e_results(s, panel = fake_panel(), out_json = tempfile(),
                               out_prov = file.path(E_OUT, "provenance.csv"), allow_pending = TRUE), "pending keys are never")
  expect_identical(file.exists(file.path(PAPER_E, "results.json")), existed)
  ign <- readLines(file.path(PAPER_E, ".gitignore"))
  expect_true(all(c("results.pending.json", "output/provenance.pending.csv") %in% ign))
})
