#!/usr/bin/env bash

# Run + postprocess one site group locally on a Mac (LBATCH=false, strictly
# serial -- see run_parallel_local.sh for concurrent local execution).
# Edit GROUP/EXPERIMENT_NAME/paths below per run.

set -eu

GROUP="${GROUP:-shuttle-pilot20}"
EXPERIMENT_NAME="${EXPERIMENT_NAME:-ecland}"

LBATCH=false ./ecland_run_experiment.sh -g "${GROUP}" -t insitu -x /Users/pad/Work/ecland/build/bin/ecland-master-dp

python3 postproc.py \
  --inputdir /Users/pad/Work/fluxnet-shuttle-ecland/output \
  --outdir /Users/pad/Work/fluxnet-shuttle-ecland/postprocessed \
  --experiment-name "${EXPERIMENT_NAME}" \
  --overwrite
