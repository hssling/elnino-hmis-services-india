read_model_input <- function(name, dir = file.path(REPO_ROOT, "data", "derived", "model")) {
  d <- data.table::fread(file.path(dir, paste0(name, "_model.csv")), na.strings = c("", "NA", "NaN"))
  d[, unit_id := factor(unit_id)]
  d[]
}

read_folds <- function(anchor = c("developing", "decaying"),
                       dir = file.path(REPO_ROOT, "data", "derived", "model")) {
  anchor <- match.arg(anchor)
  data.table::fread(file.path(dir, sprintf("folds_%s.csv", anchor)))
}

split_phase <- function(d, vars) {
  for (v in vars) {
    data.table::set(d, j = paste0(v, "_pos"), value = pmax(d[[v]], 0))
    data.table::set(d, j = paste0(v, "_neg"), value = pmin(d[[v]], 0))
  }
  invisible(d)
}

# NA, and for numeric columns also NaN/Inf/-Inf, count as missing
.is_missing <- function(x) if (is.numeric(x)) !is.finite(x) else is.na(x)

complete_rows <- function(d, vars) {
  vars <- unique(vars)
  absent <- setdiff(vars, names(d))
  if (length(absent)) stop("complete_rows: missing column(s): ", paste(absent, collapse = ", "), call. = FALSE)
  missing_var <- rep(NA_character_, nrow(d))
  for (v in rev(vars)) missing_var[.is_missing(d[[v]])] <- v      # first NA variable in `vars` order wins
  keep <- is.na(missing_var)
  list(data = d[keep],
       dropped = data.table::data.table(unit_id = as.character(d$unit_id[!keep]),
                                        year = d$year[!keep], variable = missing_var[!keep]))
}
