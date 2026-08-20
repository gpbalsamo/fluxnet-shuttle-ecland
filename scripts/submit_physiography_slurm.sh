#!/usr/bin/env bash

# Submit scripts/extract_physiography_batch.sh to SLURM for a whole site group.
#
# One job with JOBS workers inside it, rather than a job array. Each worker
# issues one MARS analysis request per site, so the worker count is a courtesy
# limit toward MARS as much as a throughput setting, and an array would only
# multiply it across nodes for no benefit -- the work is dominated by MARS, not
# by local CPU. The batch script is resumable, so a job that hits its wall
# limit is continued by simply submitting again.
#
# Validated 2026-08-20 on ECMWF Atos: ~60-85 s per site at O1280, i.e. about
# two hours for 775 sites at -j 8.
#
# Usage:
#   scripts/submit_physiography_slurm.sh -g GROUP [options]
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
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

GROUP=""
SITE_LIST_FILE=""
JOBS=8
WALLTIME="06:00:00"
QOS="nf"
MEM_PER_CPU="8G"
SOURCE="auto"
WORK_ROOT="${WORK_ROOT:-${SCRATCH:-${PROJECT_ROOT}/scripts/work}}"
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") -g GROUP [options]

  -g GROUP          Site group under forcing/ and clim/ (required)
  -S SITE_LIST_FILE Restrict to these sites (default: all with forcing)
  -j JOBS           Concurrent sites, i.e. concurrent MARS requests (default: ${JOBS})
  -s SOURCE         auto (default) | era5_o1280 | oper | era5
  -t WALLTIME       Wall limit (default: ${WALLTIME})
  -q QOS            SLURM QoS (default: ${QOS})
  -M MEM_PER_CPU    Memory per CPU (default: ${MEM_PER_CPU})
  -W WORK_ROOT      Parent of the work directory (default: ${WORK_ROOT})
  -n                Dry run: write the job script and print it, do not submit
  -h                Show this help
EOF
}

while getopts ":hng:S:j:s:t:q:M:W:" opt; do
  case "${opt}" in
    g) GROUP="${OPTARG}" ;;
    S) SITE_LIST_FILE="${OPTARG}" ;;
    j) JOBS="${OPTARG}" ;;
    s) SOURCE="${OPTARG}" ;;
    t) WALLTIME="${OPTARG}" ;;
    q) QOS="${OPTARG}" ;;
    M) MEM_PER_CPU="${OPTARG}" ;;
    W) WORK_ROOT="${OPTARG}" ;;
    n) DRY_RUN=true ;;
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
if [[ -n "${SITE_LIST_FILE}" && ! -f "${SITE_LIST_FILE}" ]]; then
  echo "ERROR: site list not found: ${SITE_LIST_FILE}" >&2
  exit 1
fi
[[ -n "${SITE_LIST_FILE}" ]] && \
  SITE_LIST_FILE="$(cd "$(dirname "${SITE_LIST_FILE}")" && pwd -P)/$(basename "${SITE_LIST_FILE}")"

WORK_DIR="${WORK_ROOT}/physiography_${GROUP}"
SLURM_DIR="${WORK_DIR}/slurm"
mkdir -p "${SLURM_DIR}"
JOB_SCRIPT="${SLURM_DIR}/physiography_${GROUP}.sbatch"

n_forcing=$(find "${PROJECT_ROOT}/forcing/${GROUP}" -name 'met_insituHT_*.nc' 2>/dev/null | wc -l | tr -d ' ')
n_done=$(ls "${WORK_DIR}/status" 2>/dev/null | wc -l | tr -d ' ')

cat > "${JOB_SCRIPT}" <<EOF
#!/bin/bash
#SBATCH --job-name=physio_${GROUP}
#SBATCH --cpus-per-task=${JOBS}
#SBATCH --mem-per-cpu=${MEM_PER_CPU}
#SBATCH --time=${WALLTIME}
#SBATCH --qos=${QOS}
#SBATCH --output=${SLURM_DIR}/physiography-%j.out

set -u

# The batch environment does not inherit the submitting shell. These are the
# modules ecland-portal's own extraction step loads; metview (via
# ecmwf-toolbox) and MARS are both needed by create_forcing.
source /etc/profile.d/modules.sh 2>/dev/null || true
module load prgenv/intel ecmwf-toolbox/new python3/new netcdf4/new cdo/2.2.0 nco eclib/new

echo "node: \$(hostname), \$(nproc) cpus visible"
for tool in python3 mars ncks; do
  command -v "\${tool}" >/dev/null 2>&1 || { echo "ERROR: \${tool} not on PATH" >&2; exit 1; }
done
python3 -c "import netCDF4" || { echo "ERROR: python3 has no netCDF4" >&2; exit 1; }

exec "${SCRIPT_DIR}/extract_physiography_batch.sh" \\
  -g "${GROUP}" \\
  -j "${JOBS}" \\
  -s "${SOURCE}" \\
  -W "${WORK_ROOT}"${SITE_LIST_FILE:+ \\
  -S "${SITE_LIST_FILE}"}
EOF
chmod +x "${JOB_SCRIPT}"

echo "Group        : ${GROUP}"
echo "Sites        : ${n_forcing} with forcing, ${n_done} already have a status file"
echo "Workers      : ${JOBS} concurrent sites (= concurrent MARS requests)"
echo "Source       : ${SOURCE}"
echo "Work dir     : ${WORK_DIR}"
echo "Clim out     : ${PROJECT_ROOT}/clim/${GROUP}"
echo "Job script   : ${JOB_SCRIPT}"
echo

if [[ "${DRY_RUN}" == true ]]; then
  echo "=== dry run, not submitting ==="
  cat "${JOB_SCRIPT}"
  exit 0
fi

sbatch "${JOB_SCRIPT}"
echo
echo "Monitor : squeue -u \$USER -n physio_${GROUP}"
echo "Progress: ls ${WORK_DIR}/status | wc -l   (of ${n_forcing})"
echo "Tally   : cat ${WORK_DIR}/status/* | sort | uniq -c | sort -rn"
