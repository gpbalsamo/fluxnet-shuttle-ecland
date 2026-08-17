#!/usr/bin/env bash

# Run + postprocess one site group on an HPC/SLURM system (LBATCH=true).
# Edit GROUP/EXPERIMENT_NAME/paths below per run. See run_and_proc_macos.sh
# for the local-Mac (LBATCH=false) equivalent.

set -eu

GROUP="${GROUP:-shuttle-pilot20}"
EXPERIMENT_NAME="${EXPERIMENT_NAME:-ecland}"

LBATCH=true ./ecland_run_experiment.sh -g "${GROUP}" -t insitu -x /perm/${USER}/ecland/build/bin/ecland-master-dp

python3 postproc.py \
  --inputdir /perm/${USER}/fluxnet-shuttle-ecland/output \
  --outdir /perm/${USER}/fluxnet-shuttle-ecland/postprocessed \
  --experiment-name "${EXPERIMENT_NAME}" \
  --overwrite
