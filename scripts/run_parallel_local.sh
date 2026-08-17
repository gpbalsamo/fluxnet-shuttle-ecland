#!/usr/bin/env bash

# Test running ecLand site simulations concurrently on this Mac.
#
# ecland_run_experiment.sh's parallel dispatch (sbatch, MAX_CONCURRENT) only
# exists on the LBATCH=true (SLURM/HPC) path. run_and_proc_macos.sh
# uses LBATCH=false, which runs every site strictly serially in a single
# process -- there is no local concurrency to exercise there.
#
# This script instead launches one `ecland_run_experiment.sh -s <site>`
# subprocess per site and fans them out across a bounded worker pool with
# `xargs -P`, to test concurrent local execution. This is safe because each
# site already gets an isolated run directory (${WORK_DIR}/RUN/<site>/, see
# ecland_run_model.sh) and a site-namespaced namelist
# (${WORK_DIR}/namelist_<site>, see ecland_create_namelist.py) -- concurrent
# site runs do not share any mutable file.
#
# Requires a python3 on PATH with numpy/netCDF4 (same requirement as
# ecland_run_experiment.sh itself, which calls ecland_create_namelist.py).
#
# (C) Copyright 2023- ECMWF.
#
# Licensed under the Apache Licence Version 2.0:
# http://www.apache.org/licenses/LICENSE-2.0.
#
# In applying this licence, ECMWF does not waive the privileges and immunities
# granted to it by virtue of its status as an intergovernmental organisation,
# nor does it submit to any jurisdiction.

set -eu
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

JOBS=4
GROUP=""
SITE_LIST_FILE=""
ECLAND_MASTER="${ECLAND_MASTER:-/Users/pad/Work/ecland/build/bin/ecland-master-dp}"
LOG_DIR="${PROJECT_ROOT}/scripts/work/parallel_logs"
NAMELIST=""

usage() {
  cat <<EOF
Usage: $(basename "$0") -g GROUP [-j JOBS] [-S SITE_LIST_FILE] [-x ECLAND_MASTER] [-n NAMELIST]

  -g GROUP             Site group, forwarded to ecland_run_experiment.sh -g (required,
                        for example a subdirectory name under clim/ and forcing/).
  -j JOBS               Concurrent site runs (default: ${JOBS})
  -S SITE_LIST_FILE     One site per line (default: reference/<GROUP>_site_ids.txt if it
                         exists, else every site with a forcing file under forcing/<GROUP>/)
  -x ECLAND_MASTER       Path to the ecland executable
                         (default: \$ECLAND_MASTER or ${ECLAND_MASTER})
  -n NAMELIST            Namelist file, forwarded to ecland_run_experiment.sh -n
                         (default: ecland_run_experiment.sh's own default, the 50R1 control namelist).
                         Output always goes to output/ -- move/copy postprocessed results under
                         benchmark/models/<name>/ to keep experiments separate.
  -h                     Show this help
EOF
}

while getopts ":hg:j:S:x:n:" opt; do
  case "${opt}" in
    g) GROUP="${OPTARG}" ;;
    j) JOBS="${OPTARG}" ;;
    S) SITE_LIST_FILE="${OPTARG}" ;;
    x) ECLAND_MASTER="${OPTARG}" ;;
    n) NAMELIST="${OPTARG}" ;;
    h) usage; exit 0 ;;
    \?) echo "ERROR: invalid option -${OPTARG}" >&2; usage >&2; exit 2 ;;
    :) echo "ERROR: option -${OPTARG} requires an argument" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "${GROUP}" ]]; then
  echo "ERROR: -g GROUP is required" >&2
  usage >&2
  exit 2
fi
if [[ -z "${SITE_LIST_FILE}" ]]; then
  if [[ -f "${PROJECT_ROOT}/reference/${GROUP}_site_ids.txt" ]]; then
    SITE_LIST_FILE="${PROJECT_ROOT}/reference/${GROUP}_site_ids.txt"
  else
    SITE_LIST_FILE="${LOG_DIR}/../${GROUP}_site_ids.auto.txt"
    mkdir -p "$(dirname "${SITE_LIST_FILE}")"
    for f in "${PROJECT_ROOT}/forcing/${GROUP}"/met_insituHT_*.nc; do
      [[ -e "${f}" ]] || continue
      base="$(basename "${f}" .nc)"
      echo "${base#met_insituHT_}"
    done > "${SITE_LIST_FILE}"
  fi
fi

if [[ ! -f "${SITE_LIST_FILE}" ]]; then
  echo "ERROR: site list file not found: ${SITE_LIST_FILE}" >&2
  exit 1
fi
if [[ ! -x "${ECLAND_MASTER}" ]]; then
  echo "ERROR: ecLand executable not found or not executable: ${ECLAND_MASTER}" >&2
  exit 1
fi

mkdir -p "${LOG_DIR}"

n_sites=$(grep -c . "${SITE_LIST_FILE}")
echo "Group      : ${GROUP}"
echo "Sites      : ${n_sites} (from ${SITE_LIST_FILE})"
echo "Workers    : ${JOBS}"
echo "Executable : ${ECLAND_MASTER}"
echo "Namelist   : ${NAMELIST:-(default)}"
echo "Logs       : ${LOG_DIR}/<site>.log"
echo

STATUS_DIR="${LOG_DIR}/status"
rm -rf "${STATUS_DIR}"
mkdir -p "${STATUS_DIR}"

run_one() {
  local site="$1"
  local log="${LOG_DIR}/${site}.log"
  local t0 t1
  local extra_args=()
  [[ -n "${NAMELIST}" ]] && extra_args+=(-n "${NAMELIST}")
  t0=$(date +%s)
  if "${SCRIPT_DIR}/ecland_run_experiment.sh" \
      -g "${GROUP}" -t insitu -s "${site}" -x "${ECLAND_MASTER}" \
      "${extra_args[@]+"${extra_args[@]}"}" \
      > "${log}" 2>&1; then
    t1=$(date +%s)
    echo "OK" > "${STATUS_DIR}/${site}"
    echo "[$(date '+%H:%M:%S')] OK   ${site} ($(( t1 - t0 ))s)"
  else
    t1=$(date +%s)
    echo "FAIL" > "${STATUS_DIR}/${site}"
    echo "[$(date '+%H:%M:%S')] FAIL ${site} ($(( t1 - t0 ))s, see ${log})"
  fi
}
export -f run_one
export SCRIPT_DIR ECLAND_MASTER LOG_DIR STATUS_DIR NAMELIST GROUP

start=$(date +%s)
xargs -P "${JOBS}" -I{} bash -c 'run_one "$@"' _ {} < "${SITE_LIST_FILE}"
end=$(date +%s)

echo
n_ok=$(ls "${STATUS_DIR}" 2>/dev/null | xargs -I{} cat "${STATUS_DIR}/{}" 2>/dev/null | grep -c "^OK" || true)
n_fail=$(ls "${STATUS_DIR}" 2>/dev/null | xargs -I{} cat "${STATUS_DIR}/{}" 2>/dev/null | grep -c "^FAIL" || true)
echo "Done in $(( end - start ))s: ${n_ok} ok, ${n_fail} failed."
[[ "${n_fail}" -eq 0 ]]
