#!/usr/bin/env bash

# Post-process a whole campaign in parallel: one worker per chunk of sites,
# all inside a single SLURM job.
#
# WHY. postproc.py is serial and takes ~90 s per site (measured on the 775-site
# ERA5 campaign, 711 GB of raw output), so a full group is ~19 CPU-hours -- over
# half a day on a login node, where it also has no business running. Split by
# site instead: the sites are independent, each writes its own
# ecLand_<experiment>_<site>_<period>.nc, so N workers need no coordination at
# all. 48 workers turn that half day into about 25 minutes.
#
# RESUMABLE FOR FREE. postproc.py skips a site whose output file already exists
# unless --overwrite, so re-submitting after a wall-limit kill or a failure picks
# up exactly where it stopped, and there is no claim or status machinery to
# maintain (unlike the model run, where a site takes hours and is worth
# individual bookkeeping -- see ecland_run_queue.sh).
#
# THREADS. Same trap as the model run: numpy/netCDF4 pull in threaded BLAS that
# defaults to every CPU it can see, so N workers each spawning N threads is an
# N-fold oversubscription. Pinned to one thread per worker below.
#
# Usage:
#   scripts/submit_postproc_slurm.sh -I INPUT_DIR [options]
#
#   scripts/submit_postproc_slurm.sh \
#     -I $SCRATCH/ecland_shuttle-all775-era5/output -e shuttle-all775-era5
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

INPUT_DIR=""
OUT_DIR="${PROJECT_ROOT}/postprocessed"
EXPERIMENT=""
# 40 x 3G = 120G, which fits under the 128G that QoS nf allows per job. Memory
# is what caps concurrency here, not CPUs: postproc.py peaks near 1.4 GB on a
# long record, so -w 48 -M 4G (192G) is rejected outright with
# QOSMaxMemoryPerJob. Raise -w only by lowering -M to match.
WORKERS=40
WALLTIME="02:00:00"
QOS="nf"
MEM_PER_CPU="3G"
# QoS nf: MaxTRESPerJob mem=128G. Checked before submitting so the failure is a
# sentence rather than a scheduler error code.
MAX_JOB_MEM_GB=128
OVERWRITE=""
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") -I INPUT_DIR [options]

  -I INPUT_DIR      Raw ecLand output: the run root's output/ (required)
  -O OUT_DIR        Where the per-site files go (default: ${OUT_DIR})
  -e EXPERIMENT     --experiment-name for postproc.py; must match the one given
                     to benchmark.py (default: the input run root's name)
  -w WORKERS        Parallel workers, one CPU each (default: ${WORKERS})
  -T WALLTIME       Wall limit (default: ${WALLTIME})
  -q QOS            SLURM QoS (default: ${QOS})
  -M MEM_PER_CPU    Memory per CPU (default: ${MEM_PER_CPU}); postproc.py peaks
                     around 1.4 GB on a long site, and this multiplies by -w
  -f                Force: pass --overwrite, redoing sites already written
  -d                Dry run: write the job script and print it, do not submit
  -h                Show this help
EOF
}

while getopts ":hdfI:O:e:w:T:q:M:" opt; do
  case "${opt}" in
    I) INPUT_DIR="${OPTARG}" ;;
    O) OUT_DIR="${OPTARG}" ;;
    e) EXPERIMENT="${OPTARG}" ;;
    w) WORKERS="${OPTARG}" ;;
    T) WALLTIME="${OPTARG}" ;;
    q) QOS="${OPTARG}" ;;
    M) MEM_PER_CPU="${OPTARG}" ;;
    f) OVERWRITE="--overwrite" ;;
    d) DRY_RUN=true ;;
    h) usage; exit 0 ;;
    \?) echo "ERROR: invalid option -${OPTARG}" >&2; usage >&2; exit 2 ;;
    :) echo "ERROR: option -${OPTARG} requires an argument" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${INPUT_DIR}" ]] || { echo "ERROR: -I INPUT_DIR is required" >&2; usage >&2; exit 2; }
[[ -d "${INPUT_DIR}" ]] || { echo "ERROR: no such directory: ${INPUT_DIR}" >&2; exit 1; }
# Default the experiment tag to the run root's name, e.g.
# .../ecland_shuttle-all775-era5/output -> shuttle-all775-era5.
if [[ -z "${EXPERIMENT}" ]]; then
  EXPERIMENT="$(basename "$(dirname "$(cd "${INPUT_DIR}" && pwd -P)")")"
  EXPERIMENT="${EXPERIMENT#ecland_}"
fi

WORK_DIR="${OUT_DIR}/.postproc_slurm"
CHUNK_DIR="${WORK_DIR}/chunks"
rm -rf "${CHUNK_DIR}"
mkdir -p "${CHUNK_DIR}" "${OUT_DIR}"

# Longest record first, then dealt round-robin across the chunks, so no worker
# ends up with all the 30-year sites. Cost tracks record length here just as it
# does in the model run.
SITES="${WORK_DIR}/sites.txt"
# -xtype d, not -type d: it matches real directories and symlinks pointing at
# one, so a curated subset can be assembled by symlinking site dirs from a
# larger run rather than copying them.
find "${INPUT_DIR}" -mindepth 1 -maxdepth 1 -xtype d -printf '%f\n' \
  | awk -F'[_-]' '{print $NF-$(NF-1), $0}' | sort -k1,1n | cut -d' ' -f2- > "${SITES}"
n_sites=$(wc -l < "${SITES}" | tr -d ' ')
[[ "${n_sites}" -gt 0 ]] || { echo "ERROR: no site directories under ${INPUT_DIR}" >&2; exit 1; }
[[ "${WORKERS}" -le "${n_sites}" ]] || WORKERS="${n_sites}"

awk -v n="${WORKERS}" -v d="${CHUNK_DIR}" '{print > (d "/chunk_" (NR-1)%n ".txt")}' "${SITES}"

n_done=$(find "${OUT_DIR}" -maxdepth 1 -name "ecLand_${EXPERIMENT}_*.nc" | wc -l | tr -d ' ')

# Catch the memory ceiling here rather than as sbatch's QOSMaxMemoryPerJob.
mem_gb="${MEM_PER_CPU%[Gg]}"
if [[ "${mem_gb}" =~ ^[0-9]+$ ]] && [[ $((WORKERS * mem_gb)) -gt "${MAX_JOB_MEM_GB}" ]]; then
  echo "ERROR: ${WORKERS} workers x ${MEM_PER_CPU} = $((WORKERS * mem_gb))G exceeds the" >&2
  echo "       ${MAX_JOB_MEM_GB}G that QoS ${QOS} allows per job. Lower -w or -M:" >&2
  echo "       -w $((MAX_JOB_MEM_GB / mem_gb)) at ${MEM_PER_CPU}, or -w ${WORKERS} at $((MAX_JOB_MEM_GB / WORKERS))G." >&2
  exit 2
fi

JOB_SCRIPT="${WORK_DIR}/postproc.sbatch"
cat > "${JOB_SCRIPT}" <<EOF
#!/bin/bash
#SBATCH --job-name=postproc_${EXPERIMENT}
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=${WORKERS}
#SBATCH --mem-per-cpu=${MEM_PER_CPU}
#SBATCH --time=${WALLTIME}
#SBATCH --qos=${QOS}
#SBATCH --output=${WORK_DIR}/postproc-%j.out

set -u

source /etc/profile.d/modules.sh 2>/dev/null || true
module load python3/3.10.10-01 netcdf4/4.9.1

# One thread per worker. numpy and netCDF4 pull in threaded BLAS that otherwise
# takes the whole cgroup, which is the same oversubscription that cost the model
# run 480 CPU-hours -- see submit_ecland_slurm.sh.
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

for c in ${CHUNK_DIR}/chunk_*.txt; do
  (
    args=()
    while read -r s; do [[ -n "\${s}" ]] && args+=(--site "\${s}"); done < "\${c}"
    [[ \${#args[@]} -gt 0 ]] || exit 0
    python3 "${SCRIPT_DIR}/postproc.py" \\
      --inputdir "${INPUT_DIR}" \\
      --outdir "${OUT_DIR}" \\
      --experiment-name "${EXPERIMENT}" ${OVERWRITE} \\
      "\${args[@]}" > "\${c%.txt}.log" 2>&1
  ) &
done
wait
echo "all workers finished"
EOF
chmod +x "${JOB_SCRIPT}"

echo "Input        : ${INPUT_DIR}"
echo "Output       : ${OUT_DIR}"
echo "Experiment   : ${EXPERIMENT}"
echo "Sites        : ${n_sites} (${n_done} already written, they will be skipped)"
echo "Workers      : ${WORKERS} (~$(( (n_sites + WORKERS - 1) / WORKERS )) sites each)"
echo "Job script   : ${JOB_SCRIPT}"
echo

if [[ "${DRY_RUN}" == true ]]; then
  echo "=== dry run, not submitting ==="
  cat "${JOB_SCRIPT}"
  exit 0
fi

sbatch "${JOB_SCRIPT}"
echo
echo "Progress : ls ${OUT_DIR}/ecLand_${EXPERIMENT}_*.nc | wc -l   (of ${n_sites})"
echo "Worker logs: ${CHUNK_DIR}/chunk_*.log"
