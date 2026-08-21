#!/usr/bin/env bash

# Run ecLand over a whole site group as a SLURM job array, then leave the
# output ready for scripts/postproc.py and scripts/benchmark.py.
#
# Array elements are interchangeable WORKERS draining one shared queue, not
# owners of a fixed slice -- see scripts/ecland_run_queue.sh for the claim and
# status mechanics. That choice is worth about a factor of two here: sites run
# from 1 to 31 years, so with fixed slices the finish time is set by whichever
# worker draws the worst combination (measured: 4.5 h against an ideal 2.25 h
# with 96 workers, 218 task-hours idle), while a queue reaches
# max(total/N, longest single site) = 2.25 h.
#
# It is also safer. A site is claimed, run and recorded individually, so a
# failure or a wall-limit kill costs exactly one site rather than everything
# left in a slice, and the run is resumable -- which is what makes switching
# strategies mid-flight free: statuses seeded from existing output are skipped.
#
# A single point integration is serial (mpirun -np 1), so concurrency is the
# number of array elements and each asks for one CPU.
#
# COST. Measured on the pilot: about 1.2 minutes of wall clock per site-year
# per loop. The 775-site group is 5397 site-years, so NLOOP=2 is roughly 210
# CPU-hours -- a bit over two hours at 96-way. Raw output is large, about
# 140 MB per site-year, so around 750 GB for the whole group: send it to
# $SCRATCH, never into the repository.
#
# Usage:
#   scripts/submit_ecland_slurm.sh -g GROUP -x ECLAND_MASTER [options]
#
#   scripts/submit_ecland_slurm.sh -g shuttle-all775-era5 \
#     -x /perm/pad/ecland/build/bin/ecland-master-dp -a 96 -l 2
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
ECLAND_MASTER="${ECLAND_MASTER:-${PERM:-/perm/${USER}}/ecland/build/bin/ecland-master-dp}"
FORCING_TYPE="insitu"
NLOOP=2
ARRAY_TASKS=96
THROTTLE=""
WALLTIME="02:30:00"
QOS="nf"
MEM_PER_CPU="8G"
NAMELIST="${PROJECT_ROOT}/namelists/namelist_ecland_50R1_ctl"
OUT_ROOT="${OUT_ROOT:-${SCRATCH:-${PROJECT_ROOT}/scripts/work}}"
SITE_LIST_FILE=""
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") -g GROUP [options]

  -g GROUP          Site group under forcing/ and clim/ (required)
  -x ECLAND_MASTER  ecLand executable (default: ${ECLAND_MASTER})
  -t FORCING_TYPE   Forcing type passed to the run script (default: ${FORCING_TYPE})
  -l NLOOP          Spin-up loops over the forcing period (default: ${NLOOP})
  -a ARRAY_TASKS    Array elements = concurrent sites (default: ${ARRAY_TASKS}).
                     Surplus elements simply exit when the queue drains, so this
                     need not divide the site count
  -p THROTTLE        Cap simultaneously running elements (SLURM's --array=..%N)
  -S SITE_LIST_FILE Restrict to these sites, one <site>_<Y1>-<Y2> per line
  -n NAMELIST       Namelist template (default: ${NAMELIST})
  -t WALLTIME       -- see -T
  -T WALLTIME       Per-task wall limit (default: ${WALLTIME})
  -q QOS            SLURM QoS (default: ${QOS})
  -M MEM_PER_CPU    Memory per CPU (default: ${MEM_PER_CPU})
  -O OUT_ROOT       Parent for output/ and work/ (default: ${OUT_ROOT})
  -d                Dry run: write the job script and print it, do not submit
  -h                Show this help
EOF
}

while getopts ":hdg:x:t:l:a:p:S:n:T:q:M:O:" opt; do
  case "${opt}" in
    g) GROUP="${OPTARG}" ;;
    x) ECLAND_MASTER="${OPTARG}" ;;
    t) FORCING_TYPE="${OPTARG}" ;;
    l) NLOOP="${OPTARG}" ;;
    a) ARRAY_TASKS="${OPTARG}" ;;
    p) THROTTLE="${OPTARG}" ;;
    S) SITE_LIST_FILE="${OPTARG}" ;;
    n) NAMELIST="${OPTARG}" ;;
    T) WALLTIME="${OPTARG}" ;;
    q) QOS="${OPTARG}" ;;
    M) MEM_PER_CPU="${OPTARG}" ;;
    O) OUT_ROOT="${OPTARG}" ;;
    d) DRY_RUN=true ;;
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
if [[ ! -x "${ECLAND_MASTER}" ]]; then
  echo "ERROR: ecLand executable not found or not executable: ${ECLAND_MASTER}" >&2
  exit 1
fi
if [[ ! -f "${NAMELIST}" ]]; then
  echo "ERROR: namelist template not found: ${NAMELIST}" >&2
  exit 1
fi

FORCING_DIR="${PROJECT_ROOT}/forcing/${GROUP}"
CLIM_DIR="${PROJECT_ROOT}/clim/${GROUP}"
for d in "${FORCING_DIR}" "${CLIM_DIR}"; do
  [[ -d "${d}" ]] || { echo "ERROR: missing ${d}" >&2; exit 1; }
done

if squeue -u "${USER}" -h -n "ecland_${GROUP}" 2>/dev/null | grep -q .; then
  echo "ERROR: a job named ecland_${GROUP} is already queued or running." >&2
  echo "       Sweeping claims while it runs would double-run sites. Cancel it first." >&2
  exit 1
fi

RUN_ROOT="${OUT_ROOT}/ecland_${GROUP}"
SLURM_DIR="${RUN_ROOT}/slurm"
CHUNK_DIR="${SLURM_DIR}/chunks"
mkdir -p "${CHUNK_DIR}" "${RUN_ROOT}/output" "${RUN_ROOT}/work"

# A site is only runnable if BOTH its forcing and its physiography exist, and
# ecland_run_model.sh pairs them by the <site>_<Y1>-<Y2> stem, so check that
# stem rather than the site code. Reporting the gap here beats discovering it
# as a failed task per missing site.
FULL_LIST="${SLURM_DIR}/runnable_sites.txt"
if [[ -n "${SITE_LIST_FILE}" ]]; then
  awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") } $0 != "" && !seen[$0]++' \
    "${SITE_LIST_FILE}" > "${FULL_LIST}"
else
  comm -12 \
    <(find "${FORCING_DIR}" -name "met_${FORCING_TYPE}HT_*.nc" -printf '%f\n' \
        | sed -E "s/^met_${FORCING_TYPE}HT_(.+)\.nc$/\1/" | sort) \
    <(find "${CLIM_DIR}" -name 'surfclim_*.nc' -printf '%f\n' \
        | sed -E 's/^surfclim_(.+)\.nc$/\1/' | sort) > "${FULL_LIST}"
fi

n_forcing=$(find "${FORCING_DIR}" -name "met_${FORCING_TYPE}HT_*.nc" | wc -l | tr -d ' ')
n_clim=$(find "${CLIM_DIR}" -name 'surfclim_*.nc' | wc -l | tr -d ' ')
n_sites=$(wc -l < "${FULL_LIST}" | tr -d ' ')
if [[ "${n_sites}" -eq 0 ]]; then
  echo "ERROR: no site has both forcing and physiography in ${GROUP}" >&2
  exit 1
fi
if [[ "${ARRAY_TASKS}" -gt "${n_sites}" ]]; then
  echo "NOTE: ${ARRAY_TASKS} tasks requested for ${n_sites} sites -- using ${n_sites}."
  ARRAY_TASKS="${n_sites}"
fi

QUEUE="${SLURM_DIR}/queue.txt"
# Longest first. With a queue this is the classic scheduling win: start the
# 31-year records before the 1-year ones and the long tail is absorbed by the
# short jobs instead of being left to run alone at the end.
sort -t_ -k2,2 "${FULL_LIST}" | awk -F'[_-]' '{print $(NF-1)-$NF, $0}' \
  | sort -k1,1n | cut -d' ' -f2- > "${QUEUE}" || cp "${FULL_LIST}" "${QUEUE}"

STATUS_DIR="${RUN_ROOT}/status"
CLAIM_DIR="${RUN_ROOT}/claims"
mkdir -p "${STATUS_DIR}" "${CLAIM_DIR}"

# Seed status from output already on disk, so a previous run's work is not
# repeated. A site counts as done when its output directory holds the full set
# of model files.
n_seeded=0
for d in "${RUN_ROOT}"/output/*/; do
  [[ -d "${d}" ]] || continue
  site="$(basename "${d}")"
  [[ -f "${STATUS_DIR}/${site}" ]] && continue
  if [[ $(find "${d}" -maxdepth 1 -name '*.nc' | wc -l) -ge 16 ]]; then
    echo "OK" > "${STATUS_DIR}/${site}"
    n_seeded=$((n_seeded + 1))
  fi
done

# A claim with no status belonged to a worker that was interrupted (wall limit,
# node failure). Nothing is running now, so these are stale by definition:
# clear them and the site is retried.
n_swept=0
for c in "${CLAIM_DIR}"/*/; do
  [[ -d "${c}" ]] || continue
  site="$(basename "${c}")"
  if [[ ! -f "${STATUS_DIR}/${site}" ]]; then
    rm -rf "${c}"
    n_swept=$((n_swept + 1))
  fi
done

n_done=$(ls "${STATUS_DIR}" 2>/dev/null | wc -l | tr -d ' ')
n_todo=$((n_sites - n_done))

JOB_SCRIPT="${SLURM_DIR}/ecland_${GROUP}.sbatch"
cat > "${JOB_SCRIPT}" <<EOF
#!/bin/bash
#SBATCH --job-name=ecland_${GROUP}
#SBATCH --array=0-$((ARRAY_TASKS - 1))${THROTTLE:+%${THROTTLE}}
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=${MEM_PER_CPU}
#SBATCH --time=${WALLTIME}
#SBATCH --qos=${QOS}
#SBATCH --output=${SLURM_DIR}/ecland-%A-%a.out

set -u

# Modules for the model run, as ecland_run.sh loads them. python3/3.10.10-01
# rather than python3/new: the two conflict, and the namelist generator only
# needs netCDF4.
source /etc/profile.d/modules.sh 2>/dev/null || true
module load prgenv/intel intel/2021.4 python3/3.10.10-01 hpcx-openmpi/2.9 netcdf4/4.9.1

exec "${SCRIPT_DIR}/ecland_run_queue.sh" \\
  -g "${GROUP}" \\
  -Q "${QUEUE}" \\
  -D "${RUN_ROOT}" \\
  -x "${ECLAND_MASTER}" \\
  -t "${FORCING_TYPE}" \\
  -n "${NAMELIST}" \\
  -l "${NLOOP}"
EOF
chmod +x "${JOB_SCRIPT}"

echo "Group        : ${GROUP}"
echo "Runnable     : ${n_sites} sites (forcing ${n_forcing}, physiography ${n_clim})"
echo "Queue        : ${n_todo} to run (${n_done} already done: ${n_seeded} seeded from existing output)"
echo "Claims swept : ${n_swept} (interrupted by a previous run, will be retried)"
echo "Concurrency  : ${ARRAY_TASKS} tasks x 1 site = ${ARRAY_TASKS} concurrent sites"
echo "NLOOP        : ${NLOOP}"
echo "Executable   : ${ECLAND_MASTER}"
echo "Namelist     : ${NAMELIST}"
echo "Output       : ${RUN_ROOT}/output"
echo "Job script   : ${JOB_SCRIPT}"
echo

if [[ "${DRY_RUN}" == true ]]; then
  echo "=== dry run, not submitting ==="
  cat "${JOB_SCRIPT}"
  exit 0
fi

sbatch "${JOB_SCRIPT}"
echo
echo "Monitor : squeue -u \$USER -n ecland_${GROUP}"
echo "Progress: ls ${RUN_ROOT}/status | wc -l   (of ${n_sites})"
echo "Tally   : cat ${RUN_ROOT}/status/* | sort | uniq -c"
echo "Retry   : grep -lx FAILED ${RUN_ROOT}/status/* | xargs rm   then submit again"
