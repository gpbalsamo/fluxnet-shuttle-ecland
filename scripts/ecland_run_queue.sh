#!/usr/bin/env bash

# One worker draining a shared queue of sites, running ecLand on each.
#
# WHY A QUEUE RATHER THAN A SLICE PER WORKER. Runtime scales with record
# length, and the 775 FLUXNET Shuttle sites run from 1 to 31 years -- a median
# site is ~12 min at NLOOP=2 and the longest is ~1.2 h. Hand each worker a
# fixed slice and the finish time is set by whichever worker draws the worst
# combination: measured over the real distribution with 96 workers, the slowest
# slice takes 4.5 h against an ideal 2.25 h, wasting 218 task-hours idling.
# Draining one shared queue instead means a worker that finishes a 1-year site
# immediately takes another, and the makespan falls to max(total/N, longest
# single site) = 2.25 h -- twice as fast for the same allocation.
#
# WHY THIS IS ALSO SAFER THAN A SLICE. Each site is claimed, run and recorded
# individually:
#
#   - the claim is an mkdir, which is atomic on POSIX and on Lustre, so exactly
#     one worker on one node can win a given site, with no lock and no server;
#   - the run is guarded by `if ! ...`, which `set -e` deliberately ignores, so
#     a site that fails costs that site and nothing else. Running a slice under
#     `set -eu` without this guard loses every remaining site in the slice to
#     one bad one;
#   - a status file per site makes the whole thing resumable: a re-submitted
#     array skips what is done, and retrying the failures is
#     `grep -lx FAILED status/* | xargs rm` and submit again.
#
# A worker interrupted mid-site (wall limit, node failure) leaves a claim with
# no status. That is deliberate: the submitter sweeps such claims before the
# next submission, so an interruption costs one site rather than a slice, and
# the site is retried. Keep the wall limit close to the longest single site --
# workers are interchangeable and exit when the queue drains, so a long limit
# buys nothing and a kill costs more.
#
# Usage:
#   ecland_run_queue.sh -g GROUP -Q QUEUE_FILE -D RUN_ROOT -x ECLAND_MASTER
#                       [-t FORCING_TYPE] [-l NLOOP] [-n NAMELIST] [-R RETRIES]
#
# (C) Copyright 2026- ECMWF.
#
# Licensed under the Apache Licence Version 2.0:
# http://www.apache.org/licenses/LICENSE-2.0
#
# In applying this licence, ECMWF does not waive the privileges and immunities
# granted to it by virtue of its status as an intergovernmental organisation,
# nor does it submit to any jurisdiction.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

GROUP=""
QUEUE_FILE=""
RUN_ROOT=""
ECLAND_MASTER=""
FORCING_TYPE="insitu"
NLOOP=2
NAMELIST=""
RETRIES=1

usage() {
  sed -n '/^# Usage:/,/^# (C)/p' "${BASH_SOURCE[0]}" | sed 's/^#[[:space:]]\{0,1\}//'
}

while getopts ":hg:Q:D:x:t:l:n:R:" opt; do
  case "${opt}" in
    g) GROUP="${OPTARG}" ;;
    Q) QUEUE_FILE="${OPTARG}" ;;
    D) RUN_ROOT="${OPTARG}" ;;
    x) ECLAND_MASTER="${OPTARG}" ;;
    t) FORCING_TYPE="${OPTARG}" ;;
    l) NLOOP="${OPTARG}" ;;
    n) NAMELIST="${OPTARG}" ;;
    R) RETRIES="${OPTARG}" ;;
    h) usage; exit 0 ;;
    \?) echo "ERROR: invalid option -${OPTARG}" >&2; usage >&2; exit 2 ;;
    :) echo "ERROR: option -${OPTARG} requires an argument" >&2; usage >&2; exit 2 ;;
  esac
done

for req in GROUP QUEUE_FILE RUN_ROOT ECLAND_MASTER; do
  [[ -n "${!req}" ]] || { echo "ERROR: -${req} is required" >&2; usage >&2; exit 2; }
done
[[ -f "${QUEUE_FILE}" ]] || { echo "ERROR: queue not found: ${QUEUE_FILE}" >&2; exit 1; }

STATUS_DIR="${RUN_ROOT}/status"
CLAIM_DIR="${RUN_ROOT}/claims"
LOG_DIR="${RUN_ROOT}/logs"
OUTPUT_DIR="${RUN_ROOT}/output"
WORKER="${SLURM_ARRAY_TASK_ID:-$$}"
WORK_DIR="${RUN_ROOT}/work/worker_${WORKER}"
mkdir -p "${STATUS_DIR}" "${CLAIM_DIR}" "${LOG_DIR}" "${OUTPUT_DIR}" "${WORK_DIR}"

n_ok=0; n_fail=0; n_skip=0
start=$(date +%s)
echo "worker ${WORKER} on $(hostname): draining $(grep -c . "${QUEUE_FILE}") sites from ${QUEUE_FILE}"

while read -r site; do
  [[ -n "${site}" ]] || continue
  [[ -f "${STATUS_DIR}/${site}" ]] && { n_skip=$((n_skip + 1)); continue; }

  # Atomic across every worker and node: exactly one mkdir can succeed.
  mkdir "${CLAIM_DIR}/${site}" 2>/dev/null || { n_skip=$((n_skip + 1)); continue; }
  echo "${SLURM_JOB_ID:-local} $(hostname) $(date -u +%FT%TZ)" > "${CLAIM_DIR}/${site}/owner"

  t0=$(date +%s)
  status="FAILED"
  attempt=0
  while [[ "${attempt}" -le "${RETRIES}" ]]; do
    attempt=$((attempt + 1))
    # `set -e` does not act on a command in an `if` condition, which is exactly
    # what keeps one failing site from taking the rest of the queue with it.
    if LBATCH=false "${SCRIPT_DIR}/ecland_run_experiment.sh" \
         -g "${GROUP}" \
         -t "${FORCING_TYPE}" \
         -s "${site}" \
         -x "${ECLAND_MASTER}" \
         -o "${OUTPUT_DIR}" \
         -w "${WORK_DIR}" \
         ${NAMELIST:+-n "${NAMELIST}"} \
         -l "${NLOOP}" >> "${LOG_DIR}/${site}.log" 2>&1; then
      status="OK"
      break
    fi
    echo "attempt ${attempt} failed for ${site}" >> "${LOG_DIR}/${site}.log"
  done

  echo "${status}" > "${STATUS_DIR}/${site}"
  t1=$(date +%s)
  [[ "${status}" == "OK" ]] && n_ok=$((n_ok + 1)) || n_fail=$((n_fail + 1))
  echo "[$(date '+%H:%M:%S')] ${status} ${site} ($(( t1 - t0 ))s, attempt ${attempt})"
done < "${QUEUE_FILE}"

echo "worker ${WORKER} done in $(( $(date +%s) - start ))s: ${n_ok} ok, ${n_fail} failed, ${n_skip} skipped/claimed elsewhere"
