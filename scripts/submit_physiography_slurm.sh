#!/usr/bin/env bash

# Submit scripts/extract_physiography_batch.sh to SLURM for a whole site group.
#
# ARRAY_TASKS jobs of JOBS workers each, so concurrency is ARRAY_TASKS x JOBS.
#
# Spreading across nodes is what actually buys speed here, and it took a
# measurement to see why. Timing one site at TCo2559: of ~470 s, the MARS
# request is ~98 s and transfers only 28 MB -- because the interpolation to
# O2560 happens CLIENT-SIDE, on our own node ("26 fields have been interpolated
# on ac6-104"). The rest is metview blending two ~128 MB albedo fields and
# create_sites.py selecting a point out of 26M-point fields, twice. So the work
# is local CPU and memory bandwidth, not MARS service time and not NFS (the
# 4.6 GB of static files copies in ~6 s, page-cached). More workers on one node
# therefore contend; more nodes do not.
#
# The nf QoS caps a single job at 128 GB and one node, which is the other
# reason to use an array rather than a bigger job.
#
# Slices are stride-partitioned and the status directory is shared, so the
# array is resumable and no two tasks take the same site.
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
ARRAY_TASKS=1
WALLTIME="06:00:00"
QOS="nf"
MEM_PER_CPU="12G"
SOURCE="auto"
RES_TAG="o2560"
OVERRIDE_CSV=""
WORK_ROOT="${WORK_ROOT:-${SCRATCH:-${PROJECT_ROOT}/scripts/work}}"
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") -g GROUP [options]

  -g GROUP          Site group under forcing/ and clim/ (required)
  -S SITE_LIST_FILE Restrict to these sites (default: all with forcing)
  -a ARRAY_TASKS    Array tasks, i.e. nodes' worth of slices (default: ${ARRAY_TASKS})
  -j JOBS           Concurrent sites within a task (default: ${JOBS});
                     total concurrency = ARRAY_TASKS x JOBS
  -s SOURCE         auto (default) | era5_<tag> | oper_<tag> | era5
  -r RES_TAG        Static-field grid: o2560 (default) | o1280 | o4000
  -O OVERRIDE_CSV   Nearest-land coordinate table; must match -r
  -t WALLTIME       Wall limit (default: ${WALLTIME})
  -q QOS            SLURM QoS (default: ${QOS})
  -M MEM_PER_CPU    Memory per CPU (default: ${MEM_PER_CPU})
  -W WORK_ROOT      Parent of the work directory (default: ${WORK_ROOT})
  -n                Dry run: write the job script and print it, do not submit
  -h                Show this help
EOF
}

while getopts ":hng:S:j:s:t:q:M:W:r:O:a:" opt; do
  case "${opt}" in
    g) GROUP="${OPTARG}" ;;
    S) SITE_LIST_FILE="${OPTARG}" ;;
    j) JOBS="${OPTARG}" ;;
    a) ARRAY_TASKS="${OPTARG}" ;;
    s) SOURCE="${OPTARG}" ;;
    r) RES_TAG="${OPTARG}" ;;
    O) OVERRIDE_CSV="${OPTARG}" ;;
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
# An `[[ ... ]] && cmd` at top level returns non-zero when the test fails,
# which under `set -e` silently exits the whole script -- so use an if.
if [[ -n "${SITE_LIST_FILE}" ]]; then
  SITE_LIST_FILE="$(cd "$(dirname "${SITE_LIST_FILE}")" && pwd -P)/$(basename "${SITE_LIST_FILE}")"
fi

if [[ -n "${OVERRIDE_CSV}" ]]; then
  [[ -f "${OVERRIDE_CSV}" ]] || { echo "ERROR: nudge table not found: ${OVERRIDE_CSV}" >&2; exit 1; }
  OVERRIDE_CSV="$(cd "$(dirname "${OVERRIDE_CSV}")" && pwd -P)/$(basename "${OVERRIDE_CSV}")"
fi

WORK_DIR="${WORK_ROOT}/physiography_${GROUP}"
SLURM_DIR="${WORK_DIR}/slurm"
mkdir -p "${SLURM_DIR}"
# Quotes written inside a ${var:+...} expansion are consumed by the shell
# rather than emitted, so build the optional argument pre-quoted.
OVERRIDE_OPT=""
if [[ -n "${OVERRIDE_CSV}" ]]; then
  OVERRIDE_OPT=" -O \"${OVERRIDE_CSV}\""
fi

JOB_SCRIPT="${SLURM_DIR}/physiography_${GROUP}.sbatch"

n_forcing=$(find "${PROJECT_ROOT}/forcing/${GROUP}" -name 'met_insituHT_*.nc' 2>/dev/null | wc -l | tr -d ' ')

CHUNK_DIR="${SLURM_DIR}/chunks"
CHUNK_OPT=""
if [[ "${ARRAY_TASKS}" -gt 1 ]]; then
  mkdir -p "${CHUNK_DIR}"
  FULL_LIST="${SLURM_DIR}/site_ids_all.txt"
  if [[ -n "${SITE_LIST_FILE}" ]]; then
    awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") } $0 != "" && !seen[$0]++' \
      "${SITE_LIST_FILE}" > "${FULL_LIST}"
  else
    find "${PROJECT_ROOT}/forcing/${GROUP}" -name 'met_insituHT_*.nc' -printf '%f\n' \
      | sed -E 's/^met_insituHT_(.+)_[0-9]{4}-[0-9]{4}\.nc$/\1/' | sort -u > "${FULL_LIST}"
  fi
  # Stride, not blocks: sites are ordered by country and vary hugely in record
  # length, so blocks would load-imbalance badly.
  for ((k = 0; k < ARRAY_TASKS; k++)); do
    awk -v k="${k}" -v n="${ARRAY_TASKS}" '(NR - 1) % n == k' "${FULL_LIST}" > "${CHUNK_DIR}/chunk_${k}.txt"
  done
  echo "Chunks       : ${ARRAY_TASKS} slices of $(wc -l < "${FULL_LIST}") sites in ${CHUNK_DIR}"
fi
n_done=$(ls "${WORK_DIR}/status" 2>/dev/null | wc -l | tr -d ' ' || echo 0)

cat > "${JOB_SCRIPT}" <<EOF
#!/bin/bash
#SBATCH --job-name=physio_${GROUP}
#SBATCH --array=0-$((ARRAY_TASKS - 1))
#SBATCH --cpus-per-task=${JOBS}
#SBATCH --mem-per-cpu=${MEM_PER_CPU}
#SBATCH --time=${WALLTIME}
#SBATCH --qos=${QOS}
#SBATCH --output=${SLURM_DIR}/physiography-%A-%a.out

set -u

# The batch environment does not inherit the submitting shell. These are the
# modules ecland-portal's own extraction step loads; metview (via
# ecmwf-toolbox) and MARS are both needed by create_forcing.
source /etc/profile.d/modules.sh 2>/dev/null || true
module load prgenv/intel ecmwf-toolbox/new python3/new netcdf4/new cdo/2.2.0 nco eclib/new

if [[ "${ARRAY_TASKS}" -gt 1 ]]; then
  SITE_SLICE="${CHUNK_DIR}/chunk_\${SLURM_ARRAY_TASK_ID}.txt"
else
  SITE_SLICE="${SITE_LIST_FILE}"
fi
echo "node: \$(hostname), \$(nproc) cpus visible, slice \${SITE_SLICE:-<all>}"
for tool in python3 mars ncks; do
  command -v "\${tool}" >/dev/null 2>&1 || { echo "ERROR: \${tool} not on PATH" >&2; exit 1; }
done
python3 -c "import netCDF4" || { echo "ERROR: python3 has no netCDF4" >&2; exit 1; }

exec "${SCRIPT_DIR}/extract_physiography_batch.sh" \\
  -g "${GROUP}" \\
  -j "${JOBS}" \\
  -s "${SOURCE}" \\
  -r "${RES_TAG}" \\
  -W "${WORK_ROOT}"${OVERRIDE_OPT} \\
  -S "\${SITE_SLICE}"
EOF
chmod +x "${JOB_SCRIPT}"

echo "Group        : ${GROUP}"
echo "Sites        : ${n_forcing} with forcing, ${n_done} already have a status file"
echo "Concurrency  : ${ARRAY_TASKS} tasks x ${JOBS} workers = $((ARRAY_TASKS * JOBS)) concurrent sites"
echo "Source       : ${SOURCE} (grid ${RES_TAG})"
echo "Nudge table  : ${OVERRIDE_CSV:-<none>}"
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
