# Source every shared function file. Working directory must be <repo>/models.
MODELS_ROOT <- normalizePath(".", winslash = "/")
REPO_ROOT <- normalizePath("..", winslash = "/")
stopifnot(file.exists(file.path(MODELS_ROOT, "renv.lock")))
for (f in sort(list.files(file.path(MODELS_ROOT, "common", "R"), pattern = "\\.R$", full.names = TRUE))) {
  if (basename(f) != "load.R") source(f, local = FALSE)
}
