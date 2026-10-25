# Paper D: contract key parser (papers/D/results_keys.md, amendment M7).
# A copy of Paper B's expand_keys() / contract_keys() (models/B/R/prep.R, frozen; not edited), with the
# hard-coded "B" made a `prefix` argument and the same regular expressions. Every backticked
# "<prefix>." token in the FIRST cell of a markdown table row that starts with "| `<prefix>." is a
# key, after shell-style brace expansion (an empty alternative means the key without that suffix).

expand_keys <- function(pattern) {
  out <- character()
  todo <- pattern
  while (length(todo)) {
    p <- todo[1]; todo <- todo[-1]
    m <- regexpr("\\{[^{}]*\\}", p)
    if (m < 0) { out <- c(out, p); next }
    inner <- substr(p, m + 1L, m + attr(m, "match.length") - 2L)
    alts <- strsplit(inner, ",", fixed = TRUE)[[1]]
    if (endsWith(inner, ",")) alts <- c(alts, "")
    if (!length(alts)) alts <- ""
    pre <- substr(p, 1L, m - 1L); post <- substr(p, m + attr(m, "match.length"), nchar(p))
    todo <- c(paste0(pre, alts, post), todo)
  }
  unique(out)
}

contract_keys <- function(path, prefix = "D") {
  px <- gsub(".", "\\.", prefix, fixed = TRUE)
  lines <- readLines(path, encoding = "UTF-8", warn = FALSE)
  rows <- grep(sprintf("^\\|\\s*`%s\\.", px), lines, value = TRUE)
  first <- vapply(strsplit(rows, "|", fixed = TRUE), function(x) x[2], character(1))
  toks <- unlist(regmatches(first, gregexpr(sprintf("`%s\\.[^`]+`", px), first)))
  toks <- gsub("`", "", toks)
  unique(unlist(lapply(toks, expand_keys)))
}
