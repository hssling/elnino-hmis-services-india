# Paper E: results.json in one command, from <repo>/models (cached-step pattern of models/D/run_all.R):
#   Rscript E/run_all.R                  # run each producer step that has neither cache nor output (and is not
#                                        # running); reuse every finished step; then assemble results.json
#   Rscript E/run_all.R --use-cache      # never fit: reuse every finished step (cache checked against its committed
#                                        # outputs); a missing output is an error
#   Rscript E/run_all.R --refit          # rerun every producer step (Rscript E/<script>), then assemble
#   --allow-pending                      # mark the keys of an unfinished or still-running step
#                                        # "pending (<script> not finished)" instead of stopping; written to the
#                                        # git-ignored papers/E/results.pending.json and
#                                        # output/provenance.pending.csv (never committed)
#   F25 (final run): two --use-cache --out-dir=<tmp>/a and <tmp>/b passes give identical SHA-256 within one
#   repository state (provenance records git state); run both, compare, then commit.
#   --out-dir=DIR                        # write results.json and provenance.csv to DIR (F25 determinism check)
# A step that is still running (its progress file reads RUNNING and its pid is alive: 01_power.R, 03_mediation.R,
# 04_secondary.R) is never launched and never read. Steps (cache models/E/_cache/<step>.rds, git-ignored):
#   01 power simulation (Task 7)        -> papers/E/output/power.csv                    -> E.power.*        (36)
#   02 Models T, S, L and verdicts (8)  -> primary_estimates.csv                        -> E.t/h7/h8/h9/s/l (156)
#   03 mediation (Task 8)               -> mediation.csv                                -> E.med.*          (35)
#   04 secondary analyses (Task 9)      -> sensitivity, dlm, iod, heterogeneity, het_modes .csv -> 214 keys
#   05 forecast and index comparison    -> forecast_skill.csv, index_comparison.csv     -> E.fc/idx, sens roni/nino34 (168)
#   06 results assembly (Task 11)       -> panel keys (64), conclusion sentence (1), papers/E/results.json (674 =
#      papers/E/results_keys.md) and papers/E/output/provenance.csv.
# Under --refit the producers keep their own guards: 03-05 refuse to start until primary_estimates.csv is committed,
# so a full refit is run step by step with a commit after 02. Seed: SEED_E (models/E/R/common_e.R).

source("common/R/load.R")
source("E/R/common_e.R")
source("E/06_results.R")

invisible(results_main(commandArgs(trailingOnly = TRUE), default_mode = "default"))
