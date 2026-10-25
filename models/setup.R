# One-time environment setup. Run from <repo>/models:  Rscript setup.R
# Restore (renv.lock present): models/.Rprofile -> renv/activate.R bootstraps renv from the lock.
# First-time init (no renv.lock): renv itself is installed into a writable library.
PKGS <- c("glmmTMB", "data.table", "jsonlite", "testthat", "ggplot2", "mgcv")
options(repos = c(CRAN = "https://cloud.r-project.org"))
stopifnot(as.character(getRversion()) == "4.5.3")

pick_bootstrap_lib <- function() {
  ul <- Sys.getenv("R_LIBS_USER")
  if (nzchar(ul)) {
    if (dir.exists(ul) || dir.create(ul, recursive = TRUE, showWarnings = FALSE)) {
      if (file.access(ul, 2) == 0) return(normalizePath(ul, winslash = "/"))
    }
    message("R_LIBS_USER ('", ul, "') is not usable (missing, uncreatable or not writable).")
  } else {
    message("R_LIBS_USER is empty.")
  }
  lib <- file.path(tempdir(), "bootstrap-lib")
  if (!dir.create(lib, recursive = TRUE, showWarnings = FALSE) && !dir.exists(lib)) {
    stop("Cannot create fallback bootstrap library at ", lib)
  }
  message("Falling back to temporary bootstrap library: ", lib)
  lib
}

if (!requireNamespace("renv", quietly = TRUE)) {
  boot_lib <- pick_bootstrap_lib()
  .libPaths(c(boot_lib, .libPaths()))
  install.packages("renv", lib = boot_lib)
  if (!requireNamespace("renv", quietly = TRUE)) stop("renv installation failed")
}
if (file.exists("renv.lock")) {
  renv::restore(prompt = FALSE)
} else {
  renv::init(bare = TRUE, restart = FALSE)
  renv::install(PKGS, prompt = FALSE)
  renv::snapshot(packages = c(PKGS, "renv"), prompt = FALSE)
}
