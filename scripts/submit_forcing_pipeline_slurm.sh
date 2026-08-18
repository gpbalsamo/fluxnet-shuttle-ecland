#!/usr/bin/env bash

# Submit scripts/run_forcing_pipeline.sh to SLURM as a job array, for running
# the Shuttle -> ecLand forcing pipeline on an HPC batch system rather than
# interactively.
#
# The site list is split across ARRAY_TASKS array tasks; each task runs the
# ordinary run_forcing_pipeline.sh over its own slice, with JOBS workers inside
# the task. Total concurrent sites is therefore ARRAY_TASKS x JOBS. All tasks
# share one work directory, so:
#
#   - the status/ directory is shared, which is what makes the whole array
#     resumable: re-submitting with the same -g GROUP skips every site already
#     recorded, whatever task first processed it;
#   - slices are disjoint (stride-partitioned by line number), so no two tasks
#     ever contend for the same site.
#
# Concurrency is a courtesy question, not just a throughput one: every worker
# is pulling hundreds of MB from ICOS/AmeriFlux/TERN, so the defaults here are
# deliberately modest (4 x 4 = 16 concurrent downloads). Raise them only if you
# know the data hubs tolerate it.
#
# Validated 2026-08-18 on ECMWF's Atos HPC (gpil partition, qos=nf). The
# defaults below are ECMWF-specific; override via the options or the
# environment for another site. Compute nodes there have working outbound
# HTTPS, which the pipeline needs -- if yours do not, the download step has to
# run somewhere that does.
#
# Requires (one-off, see README "Running on HPC"):
#   - R with FluxnetLSM installed into R_LIBS_USER (scripts/install_fluxnetlsm.R)
#   - a Python environment with the fluxnet-shuttle CLI and netCDF4
#   - NCO on PATH inside the job
#
# Usage:
#   scripts/submit_forcing_pipeline_slurm.sh -f SNAPSHOT_CSV -g GROUP [options]
#
#   scripts/submit_forcing_pipeline_slurm.sh \
#     -f $SCRATCH/shuttle/fluxnet_shuttle_snapshot_20260818T102536.csv \
#     -g shuttle-all775 -P heavy -a 8 -j 4
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

SNAPSHOT_CSV=""
GROUP=""
SITE_LIST_FILE=""
SITE_CSV="${PROJECT_ROOT}/reference/site_metadata_merged.csv"
PRESET="medium"
GAPFILL="statistical"
MIN_YEARS=""
ARRAY_TASKS=4
JOBS=4
WALLTIME="12:00:00"
QOS="${SLURM_QOS_DEFAULT:-nf}"
MEM_PER_CPU="8G"
DRY_RUN=false

# Environment the job needs. Overridable so this works outside ECMWF.
WORK_ROOT="${WORK_ROOT:-${SCRATCH:-${PROJECT_ROOT}/scripts/work}}"
R_MODULE="${R_MODULE:-R/4.5.3}"
R_LIBS_DIR="${R_LIBS_DIR:-${PERM:-${HOME}}/R/library/4.5}"
SHUTTLE_VENV="${SHUTTLE_VENV:-${PERM:-${HOME}}/venv-shuttle}"
# NCO is needed by regenerate_forcing.sh. It is easy to miss that an
# interactive shell has it via a personal profile while batch jobs do not
# (SBATCH_EXPORT=NONE), so load it explicitly rather than assuming inheritance.
# Set NCO_MODULE="" if nco is genuinely already on the batch PATH.
NCO_MODULE="${NCO_MODULE-nco}"

usage() {
  cat <<EOF
Usage: $(basename "$0") -f SNAPSHOT_CSV -g GROUP [options]

Pipeline options (forwarded to run_forcing_pipeline.sh):
  -f SNAPSHOT_CSV   fluxnet-shuttle listall snapshot CSV (required)
  -g GROUP          Output subdirectory under forcing/ and flux/ (required)
  -S SITE_LIST_FILE One site_id per line (default: every site in SNAPSHOT_CSV)
  -c SITE_CSV       Merged site metadata CSV (default: ${SITE_CSV})
  -P PRESET         mild|medium|heavy|complete (default: ${PRESET})
  -G GAPFILL        statistical|erainterim (default: ${GAPFILL})
  -m MIN_YEARS      Override the preset's min_yrs

SLURM options:
  -a ARRAY_TASKS    Array tasks, i.e. nodes' worth of slices (default: ${ARRAY_TASKS})
  -j JOBS           Workers within each task (default: ${JOBS});
                     concurrent sites = ARRAY_TASKS x JOBS
  -t WALLTIME       Per-task wall limit (default: ${WALLTIME})
  -q QOS            SLURM QoS (default: ${QOS})
  -M MEM_PER_CPU    Memory per CPU (default: ${MEM_PER_CPU})
  -W WORK_ROOT      Parent of the shared work directory (default: ${WORK_ROOT})
  -n                Dry run: write the job script and print it, do not submit
  -h                Show this help

Environment overrides: R_MODULE (${R_MODULE}), R_LIBS_DIR (${R_LIBS_DIR}),
SHUTTLE_VENV (${SHUTTLE_VENV}), NCO_MODULE (${NCO_MODULE:-<empty: assume nco
already on the batch PATH>}).
EOF
}

while getopts ":hnf:g:S:c:P:G:m:a:j:t:q:M:W:" opt; do
  case "${opt}" in
    f) SNAPSHOT_CSV="${OPTARG}" ;;
    g) GROUP="${OPTARG}" ;;
    S) SITE_LIST_FILE="${OPTARG}" ;;
    c) SITE_CSV="${OPTARG}" ;;
    P) PRESET="${OPTARG}" ;;
    G) GAPFILL="${OPTARG}" ;;
    m) MIN_YEARS="${OPTARG}" ;;
    a) ARRAY_TASKS="${OPTARG}" ;;
    j) JOBS="${OPTARG}" ;;
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

if [[ -z "${SNAPSHOT_CSV}" || -z "${GROUP}" ]]; then
  echo "ERROR: -f SNAPSHOT_CSV and -g GROUP are required" >&2
  usage >&2
  exit 2
fi
if [[ ! -f "${SNAPSHOT_CSV}" ]]; then
  echo "ERROR: snapshot CSV not found: ${SNAPSHOT_CSV}" >&2
  exit 1
fi
SNAPSHOT_CSV="$(cd "$(dirname "${SNAPSHOT_CSV}")" && pwd -P)/$(basename "${SNAPSHOT_CSV}")"
if [[ ! -f "${SITE_CSV}" ]]; then
  echo "ERROR: site metadata CSV not found: ${SITE_CSV}" >&2
  echo "       build one with: python3 scripts/build_site_metadata.py ${SNAPSHOT_CSV} --out ${SITE_CSV}" >&2
  exit 1
fi
if ! command -v sbatch >/dev/null 2>&1; then
  echo "ERROR: sbatch not found -- this script is for HPC batch submission." >&2
  echo "       Run scripts/run_forcing_pipeline.sh directly instead." >&2
  exit 1
fi

WORK_DIR="${WORK_ROOT}/forcing_pipeline_${GROUP}"
SLURM_DIR="${WORK_DIR}/slurm"
CHUNK_DIR="${SLURM_DIR}/chunks"
mkdir -p "${CHUNK_DIR}"

# Resolve the site list once, here, rather than letting each array task derive
# it: the tasks must agree on the ordering they are slicing, and deriving it
# once also means a bad list fails at submit time instead of 4 jobs later.
FULL_LIST="${SLURM_DIR}/site_ids_all.txt"
if [[ -n "${SITE_LIST_FILE}" ]]; then
  if [[ ! -f "${SITE_LIST_FILE}" ]]; then
    echo "ERROR: site list file not found: ${SITE_LIST_FILE}" >&2
    exit 1
  fi
  # Same normalization run_forcing_pipeline.sh applies, so the slice count
  # printed below matches what the tasks will actually process.
  awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
       $0 != "" && !seen[$0]++' "${SITE_LIST_FILE}" > "${FULL_LIST}"
else
  python3 -c "
import csv, sys
seen = set()
for r in csv.DictReader(open('${SNAPSHOT_CSV}')):
    seen.add(r['site_id'])
for s in sorted(seen):
    print(s)
" > "${FULL_LIST}"
fi

n_sites=$(wc -l < "${FULL_LIST}" | tr -d ' ')
if [[ "${n_sites}" -eq 0 ]]; then
  echo "ERROR: resolved site list is empty" >&2
  exit 1
fi
if [[ "${ARRAY_TASKS}" -gt "${n_sites}" ]]; then
  echo "NOTE: ${ARRAY_TASKS} array tasks requested for only ${n_sites} sites -- using ${n_sites}."
  ARRAY_TASKS="${n_sites}"
fi

# Stride partitioning (site i -> task i % ARRAY_TASKS) rather than contiguous
# blocks: record lengths vary hugely between sites, and a snapshot's site_ids
# are ordered by country/network, so contiguous blocks would hand one task a
# run of long records and leave another idle.
for ((k = 0; k < ARRAY_TASKS; k++)); do
  awk -v k="${k}" -v n="${ARRAY_TASKS}" '(NR - 1) % n == k' "${FULL_LIST}" > "${CHUNK_DIR}/chunk_${k}.txt"
done

n_done=0
[[ -d "${WORK_DIR}/status" ]] && n_done=$(ls "${WORK_DIR}/status" 2>/dev/null | wc -l | tr -d ' ')

JOB_SCRIPT="${SLURM_DIR}/forcing_pipeline_${GROUP}.sbatch"
cat > "${JOB_SCRIPT}" <<EOF
#!/bin/bash
#SBATCH --job-name=forcing_${GROUP}
#SBATCH --array=0-$((ARRAY_TASKS - 1))
#SBATCH --cpus-per-task=${JOBS}
#SBATCH --mem-per-cpu=${MEM_PER_CPU}
#SBATCH --time=${WALLTIME}
#SBATCH --qos=${QOS}
#SBATCH --output=${SLURM_DIR}/task-%a-%A.out

set -u

# The batch environment does not inherit the submitting shell (SBATCH_EXPORT=
# NONE on ECMWF), so everything the pipeline needs is set up here explicitly.
source /etc/profile.d/modules.sh 2>/dev/null || true
module load ${R_MODULE} 2>/dev/null || echo "WARNING: could not load ${R_MODULE}" >&2
${NCO_MODULE:+module load ${NCO_MODULE} 2>/dev/null || echo "WARNING: could not load ${NCO_MODULE}" >&2}
export R_LIBS_USER="${R_LIBS_DIR}"
export PATH="${SHUTTLE_VENV}/bin:\${PATH}"

echo "task \${SLURM_ARRAY_TASK_ID} on \$(hostname), \$(nproc) cpus visible"
# Fail here, in seconds, rather than after each site has been downloaded and
# converted only for the last step to die. A tool missing here almost always
# means the batch environment lacks a module the submitting shell had.
for tool in Rscript fluxnet-shuttle ncks unzip; do
  command -v "\${tool}" >/dev/null 2>&1 || {
    echo "ERROR: \${tool} not found on PATH in the batch environment." >&2
    echo "       Adjust R_MODULE / NCO_MODULE / SHUTTLE_VENV when submitting." >&2
    exit 1
  }
done

exec "${SCRIPT_DIR}/run_forcing_pipeline.sh" \\
  -f "${SNAPSHOT_CSV}" \\
  -g "${GROUP}" \\
  -S "${CHUNK_DIR}/chunk_\${SLURM_ARRAY_TASK_ID}.txt" \\
  -c "${SITE_CSV}" \\
  -W "${WORK_ROOT}" \\
  -P "${PRESET}" \\
  -G "${GAPFILL}" \\
  -j "${JOBS}"${MIN_YEARS:+ \\
  -m "${MIN_YEARS}"}
EOF
chmod +x "${JOB_SCRIPT}"

echo "Group          : ${GROUP}"
echo "Sites          : ${n_sites} (${n_done} already have a status file and will be skipped)"
echo "Array          : ${ARRAY_TASKS} tasks x ${JOBS} workers = $((ARRAY_TASKS * JOBS)) concurrent sites"
echo "Preset/gapfill : ${PRESET} / ${GAPFILL}"
echo "Work dir       : ${WORK_DIR}"
echo "Forcing out    : ${PROJECT_ROOT}/forcing/${GROUP}"
echo "Job script     : ${JOB_SCRIPT}"
echo "Task logs      : ${SLURM_DIR}/task-<arrayid>-<jobid>.out"
echo

if [[ "${DRY_RUN}" == true ]]; then
  echo "=== dry run, not submitting ==="
  cat "${JOB_SCRIPT}"
  exit 0
fi

sbatch "${JOB_SCRIPT}"
echo
echo "Monitor : squeue -u \$USER -n forcing_${GROUP}"
echo "Progress: ls ${WORK_DIR}/status | wc -l   (of ${n_sites})"
echo "Tally   : cat ${WORK_DIR}/status/* | sort | uniq -c | sort -rn"
