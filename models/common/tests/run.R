source("common/R/load.R")
res <- testthat::test_dir("common/tests/testthat", stop_on_failure = TRUE, reporter = "summary")
