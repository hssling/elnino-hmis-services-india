# results.json writing (Paper 0 schema) and display formatters.
#
# Schema: {"<key>": {"value", "display", "script", "description"}}, consumed by
# tools/build_manuscript.py, which substitutes {{<key>}} with `display`. Keys must match the
# builder's placeholder pattern [A-Za-z0-9_.]+. Keys are written in C-locale (byte) order so
# the file is identical whatever the R session's collation locale. NA values are written as
# JSON null; a NULL value is an error. `display` must be a non-empty string (fill() refuses a
# null display), so the analysis script decides the wording for a non-estimable result.
#
# Display conventions (papers/A and papers/C results_keys.md, ruling P14):
#   * negatives use U+2212 (minus sign), not the hyphen-minus (minus = FALSE for ASCII);
#   * intervals use an en dash (U+2013) between bounds, or " to " when a displayed bound is
#     negative: "-0.84 (95% CI -1.50 to -0.18)" with U+2212;
#   * p values: three decimals, "<0.001" below 0.001, no "p =" unless prefix = TRUE.
# Non-ASCII characters are written as escapes in this file, never as literals.

RESULT_KEY_PATTERN <- "^[A-Za-z0-9_.]+$"
MINUS_SIGN <- "\u2212"
EN_DASH <- "\u2013"

res_entry <- function(value, display, script, description) {
  if (is.null(value)) stop("res_entry: `value` is NULL; use NA for a non-estimable value", call. = FALSE)
  for (a in c("display", "script", "description")) {
    v <- get(a)
    if (!is.character(v) || length(v) != 1L || is.na(v) || !nzchar(v))
      stop("res_entry: `", a, "` must be a single non-empty string", call. = FALSE)
  }
  list(value = value, display = display, script = script, description = description)
}

write_results <- function(entries, path) {
  nm <- names(entries)
  if (!is.list(entries) || !length(entries) || is.null(nm) || any(!nzchar(nm)) || anyDuplicated(nm))
    stop("write_results: entries must be a non-empty list with unique names", call. = FALSE)
  bad <- nm[!grepl(RESULT_KEY_PATTERN, nm)]
  if (length(bad)) stop("write_results: key(s) not matching [A-Za-z0-9_.]+: ", paste(bad, collapse = ", "), call. = FALSE)
  fields <- c("value", "display", "script", "description")
  for (k in nm) {
    e <- entries[[k]]
    if (!is.list(e) || !setequal(names(e), fields) || length(names(e)) != 4L)
      stop("write_results: entry '", k, "' must have exactly the fields value, display, script, description ",
           "(use res_entry())", call. = FALSE)
    if (is.null(e$value)) stop("write_results: entry '", k, "' has a NULL value (use NA)", call. = FALSE)
    if (!is.character(e$display) || length(e$display) != 1L || is.na(e$display) || !nzchar(e$display))
      stop("write_results: entry '", k, "' has no display string (NA or empty)", call. = FALSE)
  }
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(entries[order(nm, method = "radix")], path, auto_unbox = TRUE, pretty = TRUE,
                       digits = NA, na = "null")
  invisible(path)
}

# Leading hyphen-minus -> U+2212 (minus = TRUE); NA stays NA.
.minus <- function(s, minus = TRUE) {
  if (isTRUE(minus)) s <- sub("^-", MINUS_SIGN, s)
  s
}

# Fixed-decimal text with ASCII "-"; rounding first and adding 0 avoids "-0.00".
.fixed <- function(x, digits, big.mark = "") {
  out <- formatC(round(x, digits) + 0, format = "f", digits = as.integer(digits), big.mark = big.mark)
  out[is.na(x)] <- NA_character_
  out
}

fmt_num <- function(x, digits = 2, minus = TRUE, plus = FALSE, big.mark = "") {
  out <- .fixed(x, digits, big.mark)
  if (isTRUE(plus)) {
    pos <- !is.na(x) & round(x, digits) > 0
    out[pos] <- paste0("+", out[pos])
  }
  .minus(out, minus)
}

# "1.12 (95% CI 1.03<en dash>1.21)"; " to " between the bounds when a displayed bound is
# negative. label replaces "95% CI" (e.g. "nominal 95% interval"). NA if any part is NA.
fmt_ci <- function(est, lo, hi, digits = 2, label = "95% CI", minus = TRUE, big.mark = "") {
  n <- max(length(est), length(lo), length(hi))
  est <- rep_len(est, n); lo <- rep_len(lo, n); hi <- rep_len(hi, n)
  neg <- (!is.na(lo) & round(lo, digits) < 0) | (!is.na(hi) & round(hi, digits) < 0)
  sep <- ifelse(neg, " to ", EN_DASH)
  out <- paste0(.minus(.fixed(est, digits, big.mark), minus), " (", label, " ",
                .minus(.fixed(lo, digits, big.mark), minus), sep,
                .minus(.fixed(hi, digits, big.mark), minus), ")")
  out[is.na(est) | is.na(lo) | is.na(hi)] <- NA_character_
  enc2utf8(out)
}

# "12,345"
fmt_int <- function(x, minus = TRUE) .minus(.fixed(round(x), 0, ","), minus)

# x is a proportion: fmt_pct(0.1234) gives "12.3%".
fmt_pct <- function(x, digits = 1, minus = TRUE) {
  out <- paste0(.minus(.fixed(100 * x, digits), minus), "%")
  out[is.na(x)] <- NA_character_
  out
}

# p value: "0.012"; "<0.001" below 0.001 (never "0.000"). prefix = TRUE gives "p = 0.012" /
# "p < 0.001".
fmt_p <- function(p, prefix = FALSE) {
  if (any(!is.na(p) & (p < 0 | p > 1))) stop("fmt_p: p values must lie in [0, 1]", call. = FALSE)
  small <- !is.na(p) & p < 0.001
  out <- .fixed(p, 3)
  out[small] <- "<0.001"
  if (isTRUE(prefix)) out[!is.na(p)] <- ifelse(small[!is.na(p)], "p < 0.001", paste("p =", out[!is.na(p)]))
  out
}
