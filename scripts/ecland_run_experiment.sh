#!/usr/bin/env bash

# Run one or more ecLand site experiments.
#
# This script is designed to live in:
#   <repository-root>/scripts/ecland_run_experiment.sh
#
# It can be launched from any current working directory. Repository-relative
# paths are derived from the location of this script rather than from `pwd`.
#
# Example repository layout:
#   plumber2-ecland/
#   ├── clim/PLUMBER2/
#   ├── forcing/PLUMBER2/
#   ├── namelists/
#   └── scripts/
#
# (C) Copyright 2023- ECMWF.
#
# Licensed under the Apache Licence Version 2.0:
# http://www.apache.org/licenses/LICENSE-2.0
#
# In applying this licence, ECMWF does not waive the privileges and immunities
# granted to it by virtue of its status as an intergovernmental organisation,
# nor does it submit to any jurisdiction.

set -eu
set -o pipefail
if command -v module >/dev/null 2>&1; then
  echo "HPC module exists - load openmpi"
  module load hpcx-openmpi/2.9.0 || true
fi

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

# Return the absolute path of a file or directory.
#
# Argument:
#   $1  File or directory path.
abs_path() {
  local target=$1
  printf '%s/%s\n' \
    "$(cd "$(dirname -- "${target}")" >/dev/null 2>&1 && pwd -P)" \
    "$(basename -- "${target}")"
}

# Print and execute a command.
#
# The command is passed as normal shell arguments, avoiding eval and preserving
# spaces safely.
trace() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

# Find all PLUMBER2 sites represented by forcing files in a directory.
#
# Arguments:
#   $1  Forcing directory.
#   $2  Filename pattern identifying the forcing type.
#
# Expected forcing filename convention:
#   met_<forcing-type>_<site>_<years>.nc
#
# Output:
#   One site identifier per line.
find_sites() {
  local directory=$1
  local pattern=$2
  local file
  local basename_no_ext

  shopt -s nullglob
  for file in "${directory}"/*"${pattern}"*.nc; do
    basename_no_ext=$(basename "${file}" .nc)

    # Remove the first two underscore-separated fields, e.g.
    # met_insitu_AR-SLu_2010-2010 -> AR-SLu_2010-2010
    printf '%s\n' "${basename_no_ext}" | sed -E 's/^([^_]*_){2}//'
  done
  shopt -u nullglob
}

# Check that restart files exist when restart mode is enabled.
check_restart_files() {
  if [[ "${LRESTART}" == true ]]; then
    echo "Restart files specified through environment variables:"
    echo "RESTARTECLAND=${RESTARTECLAND:-}"
    echo "RESTARTCMF=${RESTARTCMF:-}"

    if [[ -z "${RESTARTECLAND:-}" || ! -f "${RESTARTECLAND}" ]]; then
      echo "ERROR: LRESTART=true, but RESTARTECLAND is unset or does not exist." >&2
      exit 1
    fi

    if [[ "${RUN_CMF}" == true ]] &&
       [[ -z "${RESTARTCMF:-}" || ! -f "${RESTARTCMF}" ]]; then
      echo "ERROR: LRESTART=true and CaMa-Flood is enabled, but RESTARTCMF is unset or missing." >&2
      exit 1
    fi
  fi
}

# Print command-line help.
usage() {
  cat <<EOF
Usage:
  $(basename "$0") [options]

Required experiment options:
  -g GROUP               Site group, for example PLUMBER2
  -t FORCING_TYPE        Forcing filename pattern, for example insitu

Optional paths:
  -i INPUT_DIR           Repository input root containing forcing/ and clim/
                         Default: ${PROJECT_ROOT}
  -o OUTPUT_DIR          Experiment output directory
                         Default: ${PROJECT_ROOT}/output
  -w WORK_DIR            Experiment working directory
                         Default: ${PROJECT_ROOT}/scripts/work
  -x ECLAND_MASTER       ecLand executable
                         Default: ecland-master

Optional run controls:
  -s SITE                Run only one site; default is all matching sites
  -S SITE_LIST_FILE      File with one site per line; overrides -s and auto-discovery
  -l NLOOP               Number of loops; default: 1
  -R LRESTART            Use restart files: true or false; default: false
  -n NAMELIST_FILE       ecLand namelist template
                         Default: ${PROJECT_ROOT}/namelists/namelist_ecland_50R1_ctl
  -c NAMELIST_CMF        CaMa-Flood namelist template
  -m PARAM_FILE          Spatial parameter file
  -h                     Show this help

Example from any directory:
  ${SCRIPT_PATH} \
    -g PLUMBER2 \
    -t insitu \
    -x /path/to/ecland-master

Example for one site:
  ${SCRIPT_PATH} \
    -g PLUMBER2 \
    -t insitu \
    -s AR-SLu_2010-2010 \
    -x /path/to/ecland-master
EOF
}

# ---------------------------------------------------------------------------
# Resolve repository paths
# ---------------------------------------------------------------------------

# Absolute directory containing this script:
#   /perm/pad/plumber2-ecland/scripts
SCRIPTS_DIR=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd -P
)

SCRIPT_PATH="${SCRIPTS_DIR}/$(basename -- "${BASH_SOURCE[0]}")"

# Repository root:
#   /perm/pad/plumber2-ecland
PROJECT_ROOT=$(
  cd -- "${SCRIPTS_DIR}/.." >/dev/null 2>&1
  pwd -P
)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

SITE=""
SITE_LIST_FILE=""
NLOOP=1
LRESTART=false
ECLAND_MASTER="ecland-master"
RESTARTCMF=""
PARAM_FILE=""

INPUT_DIR="${PROJECT_ROOT}"
OUTPUT_DIR="${PROJECT_ROOT}/output"
WORK_DIR="${SCRIPTS_DIR}/work"

NAMELIST_DEFAULT="${PROJECT_ROOT}/namelists/namelist_ecland_50R1_ctl"
NAMELIST_CMF_DEFAULT="${PROJECT_ROOT}/namelists/namelist_cmf_48R1"

NAMELIST_FILE=""
NAMELIST_CMF=""

# Required values are left unset until parsed.
GROUP=""
FORCING_TYPE=""

# ---------------------------------------------------------------------------
# Parse command-line options
# ---------------------------------------------------------------------------

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while getopts ":hg:t:i:o:w:x:s:S:n:c:l:R:m:" opt; do
  case "${opt}" in
    g) GROUP="${OPTARG}" ;;
    t) FORCING_TYPE="${OPTARG}" ;;
    i) INPUT_DIR="${OPTARG}" ;;
    o) OUTPUT_DIR="${OPTARG}" ;;
    w) WORK_DIR="${OPTARG}" ;;
    x) ECLAND_MASTER="${OPTARG}" ;;
    s) SITE="${OPTARG}" ;;
    S) SITE_LIST_FILE="${OPTARG}" ;;
    n) NAMELIST_FILE="${OPTARG}" ;;
    c) NAMELIST_CMF="${OPTARG}" ;;
    l) NLOOP="${OPTARG}" ;;
    R) LRESTART="${OPTARG}" ;;
    m) PARAM_FILE="${OPTARG}" ;;
    h)
      usage
      exit 0
      ;;
    :)
      echo "ERROR: option -${OPTARG} requires an argument." >&2
      usage >&2
      exit 2
      ;;
    \?)
      echo "ERROR: invalid option -${OPTARG}." >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${GROUP}" ]]; then
  echo "ERROR: -g GROUP is required." >&2
  usage >&2
  exit 2
fi

if [[ -z "${FORCING_TYPE}" ]]; then
  echo "ERROR: -t FORCING_TYPE is required." >&2
  usage >&2
  exit 2
fi

# Apply optional namelist defaults only after argument parsing.
NAMELIST_FILE="${NAMELIST_FILE:-${NAMELIST_DEFAULT}}"
NAMELIST_CMF="${NAMELIST_CMF:-${NAMELIST_CMF_DEFAULT}}"

# ecLand runtime environment settings.
export DR_HOOK_ASSERT_MPI_INITIALIZED=0

# Load shared runtime configuration from the same scripts directory.
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/ecland_runtime.sh"

# ---------------------------------------------------------------------------
# Experiment directories
# ---------------------------------------------------------------------------

FORCING_DIR="${INPUT_DIR}/forcing/${GROUP}"
INICLM_DIR="${INPUT_DIR}/clim/${GROUP}"

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

if [[ ! -d "${FORCING_DIR}" ]]; then
  echo "ERROR: forcing directory does not exist: ${FORCING_DIR}" >&2
  exit 1
fi

if [[ ! -d "${INICLM_DIR}" ]]; then
  echo "ERROR: climate/initial-condition directory does not exist: ${INICLM_DIR}" >&2
  exit 1
fi

if [[ ! -f "${NAMELIST_FILE}" ]]; then
  echo "ERROR: ecLand namelist template does not exist: ${NAMELIST_FILE}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Determine sites
# ---------------------------------------------------------------------------

declare -a SITES=()

if [[ -n "${SITE_LIST_FILE}" ]]; then
  if [[ ! -f "${SITE_LIST_FILE}" ]]; then
    echo "ERROR: site list file not found: ${SITE_LIST_FILE}" >&2
    exit 1
  fi
  mapfile -t SITES < <(grep -v '^ *#' "${SITE_LIST_FILE}" | grep -v '^ *$')
elif [[ -n "${SITE}" ]]; then
  SITES=("${SITE}")
else
  mapfile -t SITES < <(find_sites "${FORCING_DIR}" "${FORCING_TYPE}")
fi

if [[ ${#SITES[@]} -eq 0 ]]; then
  echo "ERROR: no sites found in ${FORCING_DIR} matching '${FORCING_TYPE}'." >&2
  exit 1
fi

echo "Repository root : ${PROJECT_ROOT}"
echo "Scripts dir     : ${SCRIPTS_DIR}"
echo "Sites found     : ${#SITES[@]}"

# Keep submitted SLURM job IDs so the script can wait for completion.
declare -a job_ids=()

# Maximum number of concurrently queued/running SLURM jobs.
MAX_CONCURRENT=25

# ---------------------------------------------------------------------------
# Helper: remove finished jobs from job_ids; return number still active.
# ---------------------------------------------------------------------------
poll_jobs() {
  local active=()
  local jid status
  for jid in "${job_ids[@]}"; do
    status=$(
      scontrol show job "${jid}" 2>/dev/null |
        awk -F'JobState=' 'NF > 1 {print $2}' | awk '{print $1}'
    )
    if [[ "${status}" == "PENDING"    ||
          "${status}" == "RUNNING"    ||
          "${status}" == "CONFIGURING" ||
          "${status}" == "COMPLETING" ]]; then
      active+=("${jid}")
    else
      echo "Job ${jid} finished with state: ${status:-unknown}"
    fi
  done
  job_ids=("${active[@]+"${active[@]}"}")
}

# ---------------------------------------------------------------------------
# Helper: wait until fewer than MAX_CONCURRENT jobs are active.
# ---------------------------------------------------------------------------
wait_for_slot() {
  while [[ ${#job_ids[@]} -ge ${MAX_CONCURRENT} ]]; do
    sleep 10
    poll_jobs
  done
}

# ---------------------------------------------------------------------------
# Run each site
# ---------------------------------------------------------------------------

site_num=0
for cs in "${SITES[@]}"; do
  site_num=$(( site_num + 1 ))
  echo
  echo "=================================================================="
  echo "Preparing site: ${cs} (${site_num}/${#SITES[@]})"
  echo "=================================================================="

  # Generate site-specific ecLand and optional CaMa-Flood namelists.
  create_cmd=(
    "${SCRIPTS_DIR}/ecland_create_namelist.py"
    -g "${GROUP}"
    -n "${NAMELIST_FILE}"
    -c "${NAMELIST_CMF}"
    -s "${cs}"
    -d "${INPUT_DIR}"
    -w "${WORK_DIR}"
    -t "${FORCING_TYPE}"
  )
  trace "${create_cmd[@]}"

  NAMELIST="${WORK_DIR}/namelist_${cs}"

  if [[ ! -f "${NAMELIST}" ]]; then
    echo "ERROR: generated namelist is missing: ${NAMELIST}" >&2
    exit 1
  fi

  # Presence of a generated CaMa-Flood namelist indicates that CaMa-Flood
  # should be enabled for this site.
  RUN_CMF=false
  NAMELIST_CMF_OPT=()

  if [[ -f "${WORK_DIR}/namelist_cmf_${cs}" ]]; then
    RUN_CMF=true
    NAMELIST_CMF_OPT=(-c "${WORK_DIR}/namelist_cmf_${cs}")
  fi

  PARAM_FILE_OPT=()
  if [[ -n "${PARAM_FILE}" ]]; then
    PARAM_FILE_OPT=(-m "${PARAM_FILE}")
  fi

  echo "ecLand setup:"
  echo "  GROUP          : ${GROUP}"
  echo "  FORCING_TYPE   : ${FORCING_TYPE}"
  echo "  SITE           : ${cs}"
  echo "  NLOOP          : ${NLOOP}"
  echo "  INICLM_DIR     : ${INICLM_DIR}"
  echo "  FORCING_DIR    : ${FORCING_DIR}"
  echo "  NAMELIST       : ${NAMELIST}"
  echo "  WORK_DIR       : ${WORK_DIR}"
  echo "  OUTPUT_DIR     : ${OUTPUT_DIR}"
  echo "  INPUT_DIR      : ${INPUT_DIR}"
  echo "  ECLAND_MASTER  : ${ECLAND_MASTER}"
  echo "  RUN_CMF        : ${RUN_CMF}"
  echo "  LRESTART       : ${LRESTART}"

  if [[ "${RUN_CMF}" == true ]]; then
    echo "  NAMELIST_CMF   : ${WORK_DIR}/namelist_cmf_${cs}"
  fi

  if [[ -n "${PARAM_FILE}" ]]; then
    echo "  SURF_PARAMFILE : ${PARAM_FILE}"
  fi

  check_restart_files

  if [[ "${LBATCH:-false}" == true ]]; then
    # Wait until a slot is free, then submit.
    wait_for_slot

    job_output=$(
      sbatch \
        --export="LAUNCH=mpirun -np 1,MEM_PER_CPU=${MEM_PER_CPU:-},cs=${cs},ECLAND_MASTER=${ECLAND_MASTER},WORK_DIR=${WORK_DIR},OUTPUT_DIR=${OUTPUT_DIR},FORCING_DIR=${FORCING_DIR},INICLM_DIR=${INICLM_DIR},FORCING_TYPE=${FORCING_TYPE},NLOOP=${NLOOP},NAMELIST=${NAMELIST},SCRIPTS_DIR=${SCRIPTS_DIR},LRESTART=${LRESTART},PATH=${ecland_ROOT:-../ecland_eclairs-build}/bin:${PATH}" \
        "${SCRIPTS_DIR}/run_sbatch.sh"
    ) || { echo "ERROR: sbatch failed for site ${cs}" >&2; continue; }

    job_id=$(awk '{print $4}' <<<"${job_output}")
    if [[ -z "${job_id}" ]]; then
      echo "ERROR: could not extract job ID for site ${cs} (sbatch output: ${job_output})" >&2
      continue
    fi
    job_ids+=("${job_id}")
    echo "Submitted SLURM job ${job_id} for ${cs} (active: ${#job_ids[@]}/${MAX_CONCURRENT} ; site ${site_num} of ${#SITES[@]})"
  else
    # Run interactively/directly on the current node.
    run_cmd=(
      "${SCRIPTS_DIR}/ecland_run_model.sh"
      -s "${cs}"
      -b "${ECLAND_MASTER}"
      -w "${WORK_DIR}"
      -o "${OUTPUT_DIR}"
      -f "${FORCING_DIR}"
      -i "${INICLM_DIR}"
      -F "${FORCING_TYPE}"
      -n "${NAMELIST}"
      "${NAMELIST_CMF_OPT[@]+"${NAMELIST_CMF_OPT[@]}"}"
      -l "${NLOOP}"
      "${PARAM_FILE_OPT[@]+"${PARAM_FILE_OPT[@]}"}"
      -R "${LRESTART}"
    )
    trace "${run_cmd[@]}"
  fi
done

# ---------------------------------------------------------------------------
# Wait for any remaining submitted jobs
# ---------------------------------------------------------------------------

if [[ "${LBATCH:-false}" == true && ${#job_ids[@]} -gt 0 ]]; then
  echo "Waiting for ${#job_ids[@]} remaining job(s) to finish..."
  while [[ ${#job_ids[@]} -gt 0 ]]; do
    sleep 10
    poll_jobs
  done
fi

echo
echo "All requested ecLand experiments have completed or been submitted."
