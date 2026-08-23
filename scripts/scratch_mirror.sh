#!/usr/bin/env bash

# Keep a working copy of this repository on $SCRATCH and bring the keepers back.
#
# WHY. Runs are I/O heavy and highly concurrent, and $PERM is a single NFS filer:
# measured with 30 simultaneous writers, $PERM sustains 530 MB/s against 4863
# MB/s on $SCRATCH, which is Lustre -- a factor of 9.2. So the model, the
# post-processing and the benchmark all belong on $SCRATCH. But $SCRATCH is
# pruned automatically and is not safe for anything you want to keep, so the two
# trees are duals: bulk and scratch work there, results live here.
#
# The reads are the half that is easy to miss. Workers inside one array element
# share that node's single NFS client, so 48 of them reading forcing over NFS
# starve even when the output is already on Lustre -- measured in the sibling
# PLUMBER2 repo at 7% CPU per worker, with no site finishing in 40 minutes. Job
# 36354918 here lost 480 CPU-hours to exactly that shape: output on $SCRATCH,
# inputs and executable still on $PERM.
#
#   push : $PERM -> $SCRATCH   inputs and code (forcing, clim, flux, namelists,
#                              scripts) -- everything a run needs, nothing it
#                              produces
#   pull : $SCRATCH -> $PERM   results only (postprocessed/, benchmark/models/,
#                              benchmark/dashboards/) -- never raw output/, which
#                              is ~750 GB per campaign and regenerable
#   status: what exists on each side
#
# The mirror keeps the same layout as this repository, so every script works
# there unchanged and with no flags: the run scripts derive their project root
# from their own location, and postproc.py / benchmark.py use paths relative to
# the tree they are run from. The intended cycle is
#
#   scripts/scratch_mirror.sh push -g shuttle-all775-era5
#   cd $SCRATCH/fluxnet-shuttle-ecland
#   scripts/submit_ecland_slurm.sh -g shuttle-all775-era5 -i \
#     -x $SCRATCH/fluxnet-shuttle-ecland/ecland-build/bin/ecland-master-dp
#   python3 scripts/postproc.py --inputdir output --outdir postprocessed
#   python3 scripts/benchmark.py
#   cd -; scripts/scratch_mirror.sh pull
#
# WHY -g. Unlike the sibling repo, forcing/, clim/ and flux/ here are split by
# site group, and the groups are large. Pushing one group copies about 14 GB
# against 26 for all three, and a run only ever reads its own group. Without -g
# the whole of each directory travels.
#
# -r trims that further to the ~2 GB the model itself needs, by leaving out the
# flux/ observations that only benchmark.py reads. It is a way to get a run
# started sooner, not the normal path: the mirror is meant to be self-contained,
# as it is in the sibling repo, so a plain push carries flux/ too and the whole
# run/postproc/benchmark cycle works there without touching $PERM again.
#
# WHAT IS NOT COPIED BACK. Raw model output (output/), run state (status/,
# claims/, logs/, slurm/, work/) and the git metadata. Raw output is the biggest
# thing on the scratch side and the cheapest to reproduce; if you need a site's
# restart for an NLOOP=1 rerun, copy that file deliberately rather than the tree.
#
# (C) Copyright 2026- ECMWF.
#
# Licensed under the Apache Licence Version 2.0:
# http://www.apache.org/licenses/LICENSE-2.0
#
# In applying this licence, ECMWF does not waive the privileges and immunities
# granted to it by virtue of its status as an intergovernmental organisation,
# nor does it submit to any jurisdiction.

set -eu
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
PERM_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
MIRROR="${MIRROR:-${SCRATCH:?SCRATCH is not set}/$(basename "${PERM_ROOT}")}"
DRY_RUN=false
GROUP=""

# Code and namelists always travel whole: the mirror is then self-contained and a
# run there cannot silently use a stale script from a previous campaign.
PUSH_PATHS=(scripts namelists reference)
# Data directories, split by site group. With -g only that group's subdirectory
# is pushed; without it, the whole directory.
#
# flux/ is the observations, and only benchmark.py reads them -- the model run
# needs forcing and clim alone. It is also the biggest thing here (12 GB for the
# 775-site group against 2 GB of forcing), so -r skips it when all you are doing
# is submitting a run, and a later `push` without -r brings it over for the
# benchmark.
GROUP_PATHS=(forcing clim flux)
RUN_ONLY_SKIP=(flux)
RUN_ONLY=false

# The executable counts as input. ecland-master-dp resolves its libraries through
# an $ORIGIN/../lib64 rpath, so bin/ and lib64/ have to travel together and keep
# their relative layout. Leaving them on $PERM means every worker demand-pages
# program text and five shared objects over NFS, which with 48 workers on one
# node is served by that node's single NFS client -- the same bottleneck the data
# mirror removes, reintroduced through the loader.
ECLAND_BUILD="${ECLAND_BUILD:-${PERM:-/perm/${USER}}/ecland/build}"
BUILD_SUBDIRS=(bin lib lib64)
MIRROR_BUILD_REL="ecland-build"

# Results worth keeping. Anything not listed stays on $SCRATCH and is lost at the
# next prune, which is the intended behaviour.
PULL_PATHS=(postprocessed benchmark/models benchmark/dashboards)

usage() {
  cat <<EOF
Usage: $(basename "$0") {push|pull|status} [-g GROUP] [-n] [-M MIRROR]

  push        Copy inputs and code to the mirror (${PUSH_PATHS[*]} ${GROUP_PATHS[*]})
  pull        Copy results back from the mirror (${PULL_PATHS[*]})
  status      Show both sides without copying anything

  -g GROUP    Restrict ${GROUP_PATHS[*]} to this site group (default: all groups)
  -r          Run inputs only: skip ${RUN_ONLY_SKIP[*]}, which only the benchmark reads
  -n          Dry run: print what rsync would transfer
  -M MIRROR   Mirror location (default: ${MIRROR})
  -h          Show this help

Deletions are never propagated: rsync runs without --delete in both directions,
so a stale file in the mirror is possible but losing a result is not.
EOF
}

ACTION="${1:-}"
[[ -n "${ACTION}" ]] && shift || true
case "${ACTION}" in
  push|pull|status) ;;
  -h|--help|help) usage; exit 0 ;;
  *) echo "ERROR: expected push, pull or status" >&2; usage >&2; exit 2 ;;
esac

while getopts ":hnrg:M:" opt; do
  case "${opt}" in
    n) DRY_RUN=true ;;
    r) RUN_ONLY=true ;;
    g) GROUP="${OPTARG}" ;;
    M) MIRROR="${OPTARG}" ;;
    h) usage; exit 0 ;;
    \?) echo "ERROR: invalid option -${OPTARG}" >&2; usage >&2; exit 2 ;;
    :) echo "ERROR: option -${OPTARG} requires an argument" >&2; usage >&2; exit 2 ;;
  esac
done

# With -g, each data directory contributes only that group's subdirectory.
for p in "${GROUP_PATHS[@]}"; do
  if "${RUN_ONLY}" && [[ " ${RUN_ONLY_SKIP[*]} " == *" ${p} "* ]]; then
    continue
  fi
  if [[ -n "${GROUP}" ]]; then
    PUSH_PATHS+=("${p}/${GROUP}")
  else
    PUSH_PATHS+=("${p}")
  fi
done

RSYNC=(rsync -a --human-readable --info=stats1 --exclude '.git' --exclude '__pycache__')
"${DRY_RUN}" && RSYNC+=(--dry-run --itemize-changes)

show_side() {
  local label=$1 root=$2 p
  echo "${label}: ${root}"
  [[ -d "${root}" ]] || { echo "  (does not exist)"; return; }
  for p in scripts namelists forcing clim flux output postprocessed \
           benchmark/models benchmark/dashboards; do
    if [[ -d "${root}/${p}" ]]; then
      printf '  %-22s %8s  %5s entries\n' "${p}" \
        "$(du -sh "${root}/${p}" 2>/dev/null | cut -f1)" \
        "$(find "${root}/${p}" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    fi
  done
}

case "${ACTION}" in
  status)
    show_side "PERM  " "${PERM_ROOT}"
    echo
    show_side "SCRATCH" "${MIRROR}"
    ;;

  push)
    echo "push: ${PERM_ROOT} -> ${MIRROR}${GROUP:+ (group ${GROUP})}"
    mkdir -p "${MIRROR}"
    for p in "${PUSH_PATHS[@]}"; do
      if [[ ! -e "${PERM_ROOT}/${p}" ]]; then
        echo "  skip ${p} (absent here)"
        continue
      fi
      echo "  ${p}"
      mkdir -p "${MIRROR}/${p}"
      "${RSYNC[@]}" "${PERM_ROOT}/${p}/" "${MIRROR}/${p}/"
    done
    if [[ -d "${ECLAND_BUILD}" ]]; then
      echo "  ${MIRROR_BUILD_REL} (from ${ECLAND_BUILD})"
      for sub in "${BUILD_SUBDIRS[@]}"; do
        [[ -d "${ECLAND_BUILD}/${sub}" ]] || continue
        mkdir -p "${MIRROR}/${MIRROR_BUILD_REL}/${sub}"
        "${RSYNC[@]}" "${ECLAND_BUILD}/${sub}/" "${MIRROR}/${MIRROR_BUILD_REL}/${sub}/"
      done
    else
      echo "  skip ${MIRROR_BUILD_REL} (no build at ${ECLAND_BUILD}; set ECLAND_BUILD)"
    fi
    echo
    echo "Mirror ready. Run there, not here, and use the mirrored executable:"
    echo "  cd ${MIRROR}"
    echo "  scripts/submit_ecland_slurm.sh -g ${GROUP:-<group>} -i \\"
    echo "    -x ${MIRROR}/${MIRROR_BUILD_REL}/bin/ecland-master-dp"
    ;;

  pull)
    echo "pull: ${MIRROR} -> ${PERM_ROOT}"
    [[ -d "${MIRROR}" ]] || { echo "ERROR: no mirror at ${MIRROR}" >&2; exit 1; }
    n_found=0
    for p in "${PULL_PATHS[@]}"; do
      if [[ ! -d "${MIRROR}/${p}" ]]; then
        echo "  skip ${p} (not produced yet)"
        continue
      fi
      echo "  ${p}"
      mkdir -p "${PERM_ROOT}/${p}"
      "${RSYNC[@]}" "${MIRROR}/${p}/" "${PERM_ROOT}/${p}/"
      n_found=$((n_found + 1))
    done
    if [[ "${n_found}" -eq 0 ]]; then
      echo "Nothing to pull: the mirror holds no results yet." >&2
      exit 1
    fi
    echo
    echo "Results are on \$PERM. Raw output stays on \$SCRATCH and will be pruned."
    ;;
esac
