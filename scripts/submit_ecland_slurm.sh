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
# A single point integration is serial: no launcher, one CPU per worker, and
# concurrency is ARRAY_TASKS x WORKERS_PER_TASK.
#
# COST. Fitted on the 358 sites of the first campaign at NLOOP=2, each run alone
# on its own CPU: 193.6 s per site-year (718,367 s over 3710 site-years; median
# 191, p90 225). The 775-site group is 5397 site-years, so a full run is about
# 290 CPU-hours uncontended and around 750 GB of raw output at ~140 MB per
# site-year -- send it to $SCRATCH, never into the repository. Sharing a node
# costs a little on top: job 36484197 ran 1507 site-years through 240 workers at
# -w 48 for 94.7 CPU-hours, which is 226 s per site-year, so the contention
# factor at 48 workers is 1.17x (the sibling PLUMBER2 repo measured 1.32x at 30,
# so it does not worsen with -w). Budget ~340 CPU-hours for the full group.
# Refit rather than reuse across repositories -- the same law over PLUMBER2 sites
# gives 86 s per site-year against 194 here.
#
# HOW MANY WORKERS. Concurrency is ARRAY_TASKS x WORKERS_PER_TASK, and the two
# are not interchangeable, because the scarce resource is job slots rather than
# CPUs: `sacctmgr show assoc user=$USER` gives MaxJobs=30 per account on QoS nf,
# and array elements count individually, so element 31 and up sit in PENDING
# (AssocMaxJobsLimit). Raising -a past 30 therefore does nothing, while -w buys
# concurrency out of a node's CPUs instead -- these nodes carry 256 of them.
#
# So -a 5 -w 36 gives 180 concurrent sites for 5 job slots, where -a 25 -w 1
# gives 25 for 25. Both leave the run resumable and the claims safe: workers
# inside one element claim by the same atomic mkdir as workers across nodes.
#
# 180 is the shape to keep, and going higher is measured waste. The FLOOR is the
# costliest single record -- NL-Loo_1997-2025, 29 years, serial and unsplittable,
# about 2.1 h with contention -- and any concurrency past ~165 workers drains the
# other 774 sites faster than that, so the run ends on that one site regardless.
# Job 36484197 ran the 371 remaining sites at -w 48 (240 workers) and finished in
# 1 h 13 min bounded by its longest record; -w 36 reaches the same finish for 60
# fewer CPUs. Below the floor, halving the work is the only lever left: NLOOP=1
# from an equilibrated restart.
#
# WALL LIMIT. Size it on the per-worker DRAIN time, not on one site: a worker
# takes site after site until the queue is empty, so it lives for roughly
# total/N -- but never below the costliest single record, about 2.1 h, since one
# worker must carry it to the end. The 03:30:00 default clears that floor by two
# thirds and also covers the 1.9 h drain at the default 180 workers; raise it if
# you cut concurrency below ~100 workers. A worker killed at the limit loses only its in-flight site
# (the claim is swept and the site retried next submission), but a limit below
# the drain means every worker dies mid-queue and nothing is recorded: a 04:00:00
# limit against 48 contended workers cost 480 CPU-hours here for zero sites.
#
# I/O AND WHERE TO RUN. Run on $SCRATCH, not here. Measured with 30 concurrent
# writers, $PERM (NFS) sustains 530 MB/s against 4863 MB/s on Lustre, and the
# reads matter as much -- workers inside one element share that node's single NFS
# client, forcing included. The executable counts too: it demand-pages five
# shared objects through an $ORIGIN/../lib64 rpath. scripts/scratch_mirror.sh
# push assembles a self-contained tree on $SCRATCH, including the build; run
# there with -i and pull the results back.
#
# Usage:
#   scripts/submit_ecland_slurm.sh -g GROUP -x ECLAND_MASTER [options]
#
#   scripts/submit_ecland_slurm.sh -g shuttle-all775-era5 \
#     -x /perm/pad/ecland/build/bin/ecland-master-dp -a 5 -w 36 -O ${SCRATCH}
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
# Concurrency is ARRAY_TASKS x WORKERS_PER_TASK = 180, from 5 of the 30 job slots
# the association allows -- see "HOW MANY WORKERS" above. Measured: -w 48 (240
# workers) finished the same run in the same time, because both are past the
# floor, so the extra 60 CPUs bought nothing.
ARRAY_TASKS=5
WORKERS_PER_TASK=36
THROTTLE=""
# Clears the 2.33 h floor set by the longest record by 50%, and covers the drain
# at any concurrency above ~100 workers. See "WALL LIMIT" above.
WALLTIME="03:30:00"
QOS="nf"
# A single-point run needs under 400 MB. This is per CPU, so it multiplies by
# -w -- at 8G, -w 36 would reserve 288 GB of a 480 GB node for no reason.
MEM_PER_CPU="2G"
NAMELIST="${PROJECT_ROOT}/namelists/namelist_ecland_50R1_ctl"
OUT_ROOT="${OUT_ROOT:-${SCRATCH:-${PROJECT_ROOT}/scripts/work}}"
SITE_LIST_FILE=""
DRY_RUN=false
IN_PLACE=false

# A completed site holds the full set of model files. A Shuttle run writes 14
# o_*.nc diagnostics plus restartout.nc and restartout_S1.nc; requiring the
# restart as well as the count keeps a half-written directory from being seeded
# as done.
MIN_OUTPUT_NC=16

usage() {
  cat <<EOF
Usage: $(basename "$0") -g GROUP [options]

  -g GROUP          Site group under forcing/ and clim/ (required)
  -x ECLAND_MASTER  ecLand executable (default: ${ECLAND_MASTER})
  -t FORCING_TYPE   Forcing type passed to the run script (default: ${FORCING_TYPE})
  -l NLOOP          Spin-up loops over the forcing period (default: ${NLOOP})
  -a ARRAY_TASKS    Array elements (default: ${ARRAY_TASKS}). Each counts against
                     the association MaxJobs of 30 on QoS ${QOS}, so past 30 this
                     only adds PENDING elements. Surplus elements exit when the
                     queue drains, so it need not divide the site count
  -w WORKERS        Parallel workers INSIDE each element (default:
                     ${WORKERS_PER_TASK}), taking one CPU each. Concurrency is
                     ARRAY_TASKS x WORKERS, so -w is the way past MaxJobs:
                     -a 5 -w 36 gives 180 concurrent sites for 5 job slots.
                     Lowering total concurrency lengthens the drain -- raise -T
  -p THROTTLE       Cap simultaneously running elements (SLURM's --array=..%N)
  -S SITE_LIST_FILE Restrict to these sites, one <site>_<Y1>-<Y2> per line
  -n NAMELIST       Namelist template (default: ${NAMELIST})
  -t WALLTIME       -- see -T
  -T WALLTIME       Per-task wall limit (default: ${WALLTIME})
  -q QOS            SLURM QoS (default: ${QOS})
  -M MEM_PER_CPU    Memory per CPU (default: ${MEM_PER_CPU})
  -O OUT_ROOT       Parent of the run root ecland_<GROUP>/ holding output/,
                     work/, logs/ and the queue state (default: ${OUT_ROOT}).
                     Keep this on \$SCRATCH: raw output is ~750 GB per campaign
  -i                In place: make the run root OUT_ROOT itself, so output/ sits
                     directly in the tree as postproc.py and benchmark.py
                     expect. Intended for the \$SCRATCH mirror (see
                     scripts/scratch_mirror.sh); on \$PERM it would seed from
                     this repository's existing output/
  -d                Dry run: write the job script and print it, do not submit
  -h                Show this help
EOF
}

while getopts ":hdig:x:t:l:a:w:p:S:n:T:q:M:O:" opt; do
  case "${opt}" in
    g) GROUP="${OPTARG}" ;;
    x) ECLAND_MASTER="${OPTARG}" ;;
    t) FORCING_TYPE="${OPTARG}" ;;
    l) NLOOP="${OPTARG}" ;;
    a) ARRAY_TASKS="${OPTARG}" ;;
    w) WORKERS_PER_TASK="${OPTARG}" ;;
    p) THROTTLE="${OPTARG}" ;;
    S) SITE_LIST_FILE="${OPTARG}" ;;
    n) NAMELIST="${OPTARG}" ;;
    T) WALLTIME="${OPTARG}" ;;
    q) QOS="${OPTARG}" ;;
    M) MEM_PER_CPU="${OPTARG}" ;;
    O) OUT_ROOT="${OPTARG}" ;;
    d) DRY_RUN=true ;;
    i) IN_PLACE=true ;;
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

# -i puts output/ directly in the tree, matching the layout that postproc.py and
# benchmark.py expect; otherwise the run gets its own ecland_<GROUP>/ so it
# cannot seed from a pre-existing output/.
if [[ "${IN_PLACE}" == true ]]; then
  RUN_ROOT="${OUT_ROOT}"
else
  RUN_ROOT="${OUT_ROOT}/ecland_${GROUP}"
fi
SLURM_DIR="${RUN_ROOT}/slurm"
CHUNK_DIR="${SLURM_DIR}/chunks"

# Raw output is written by every worker at once, and $PERM is NFS. Past roughly
# 25 simultaneous writers that is the wrong target, so say so rather than let a
# run crawl -- but only warn, since keeping an existing run root is often the
# better trade (moving it forfeits the completed sites seeded from it).
# Test the filesystem type rather than the path: $SCRATCH resolves through
# /ec/res4/scratch to /lus/..., so a prefix match on either spelling misfires.
mkdir -p "${CHUNK_DIR}" "${RUN_ROOT}/output" "${RUN_ROOT}/work"
FS_TYPE="$(stat -f -c %T "${RUN_ROOT}" 2>/dev/null || echo unknown)"
if [[ $((ARRAY_TASKS * WORKERS_PER_TASK)) -gt 25 && "${FS_TYPE}" != "lustre" ]]; then
  echo "NOTE: $((ARRAY_TASKS * WORKERS_PER_TASK)) concurrent writers into ${RUN_ROOT}"
  echo "      on a ${FS_TYPE} filesystem. Measured with 30 writers, \$PERM (NFS)"
  echo "      sustains 530 MB/s against 4863 MB/s on Lustre -- and the workers also"
  echo "      READ forcing and clim, which is what actually stalls them. Use the"
  echo "      \$SCRATCH mirror: scripts/scratch_mirror.sh push -g ${GROUP}"
fi
# The inputs matter as much as the output: 48 workers on one node share that
# node's single NFS client, so forcing read over NFS starves them even when
# output is on Lustre (measured in the sibling repo: 7% CPU per worker, no site
# finishing in 40 min).
IN_FS="$(stat -f -c %T "${FORCING_DIR}" 2>/dev/null || echo unknown)"
if [[ $((ARRAY_TASKS * WORKERS_PER_TASK)) -gt 25 && "${IN_FS}" != "lustre" ]]; then
  echo "NOTE: forcing is on a ${IN_FS} filesystem (${FORCING_DIR})."
  echo "      Run from the \$SCRATCH mirror instead, or concurrency will not pay."
fi
# So does the executable: it demand-pages its text and five shared objects
# through an $ORIGIN/../lib64 rpath, served by that same one NFS client.
EXE_FS="$(stat -f -c %T "$(dirname "${ECLAND_MASTER}")" 2>/dev/null || echo unknown)"
if [[ $((ARRAY_TASKS * WORKERS_PER_TASK)) -gt 25 && "${EXE_FS}" != "lustre" ]]; then
  echo "NOTE: the executable is on a ${EXE_FS} filesystem (${ECLAND_MASTER})."
  echo "      scripts/scratch_mirror.sh push copies the build too -- use that copy."
fi

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
# Only trim when each element is one site; with -w the element count is a
# resource shape, not a site count, and must be left alone.
if [[ "${ARRAY_TASKS}" -gt "${n_sites}" && "${WORKERS_PER_TASK}" -eq 1 ]]; then
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
# repeated. To force a site to run again, delete its status file (or its output
# directory); to retry only the failures, see the Retry hint printed below.
n_seeded=0
for d in "${RUN_ROOT}"/output/*/; do
  [[ -d "${d}" ]] || continue
  site="$(basename "${d}")"
  [[ -f "${STATUS_DIR}/${site}" ]] && continue
  if [[ -f "${d}/restartout.nc" ]] &&
     [[ $(find "${d}" -maxdepth 1 -name '*.nc' | wc -l) -ge "${MIN_OUTPUT_NC}" ]]; then
    echo "OK" > "${STATUS_DIR}/${site}"
    n_seeded=$((n_seeded + 1))
  fi
done

# A claim with no status belonged to a worker that was interrupted (wall limit,
# node failure). Nothing is running now, so these are stale by definition:
# clear them and the site is retried.
n_swept=0
# Workers reclaim a stale claim by renaming it to .stale_<site>_<pid> and then
# deleting it (see ecland_run_queue.sh). A worker killed between those two steps
# leaves the rename behind, and the loop below cannot see it: a leading dot is
# not matched by *. Clear those first so they do not accumulate across runs.
rm -rf "${CLAIM_DIR}"/.stale_* 2>/dev/null || true
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
#SBATCH --cpus-per-task=${WORKERS_PER_TASK}
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

# NO mpirun here, deliberately. A single point integration is serial, so the
# launcher would add nothing -- and it actively breaks this job shape twice
# over. \`mpirun -np 1\` binds its rank to the first core of the allocation, so N
# independent mpiruns inside one cgroup all land on the SAME core (measured in
# the sibling repo with -w 30: all 30 workers on CPUs 0/128 at 6.6% each, about
# 2 cores of work from 30). It also drains any stdin it inherits, which is why
# ecland_run_queue.sh reads its queue on FD 9. Leaving LAUNCH empty makes
# ecland_run_model.sh exec the binary directly.
export LAUNCH=''
export MEM_PER_CPU='${MEM_PER_CPU}'

# ONE OpenMP thread per worker. This is the single most important line here.
# ecLand is threaded (see -nt in ecland_parse_commandline.sh) and OpenMP defaults
# to every CPU it can see, which is the whole cgroup -- so with -w 48 each of the
# 48 workers spawns 48 spin-waiting threads: 2304 threads on 48 CPUs. That is
# what wasted the 480 CPU-hours of job 36354918, where the median site went from
# 756 s to 9845 s (13x) and not one of 372 sites finished inside a 4 h wall.
# A single point integration gains nothing from threads; the parallelism here is
# one site per worker.
export OMP_NUM_THREADS=1
export OMP_PROC_BIND=false
# KMP_AFFINITY is the one that actually matters, and it is Intel-specific.
# ecLand is built with the Intel compiler, whose OpenMP runtime pins threads by
# itself and ignores OMP_PROC_BIND: measured in the sibling repo with -w 30,
# every one of the 30 independent workers claimed core 0, ending up with
# Cpus_allowed_list=0,128 and 7% CPU each -- 30 runnable processes timesharing
# one core. Each worker here is a separate process that must be free to land
# anywhere in the cgroup, so the runtime must not bind at all.
export KMP_AFFINITY=disabled
# And this is the line that fixes -w. ecLand calls MPI_Init even at one point, so
# running the binary directly makes it an OpenMPI SINGLETON -- and a singleton
# still applies OpenMPI's default binding policy, pinning itself to the first
# core of the cgroup. Every worker therefore chose core 0 independently: the
# shells above them held the full CPU mask while each model process narrowed
# itself to Cpus_allowed_list=0,128. Dropping mpirun does not avoid this, because
# the binding comes from the MPI runtime inside the process, not from the
# launcher. Workers must stay unbound so the kernel can spread them.
export OMPI_MCA_hwloc_base_binding_policy=none

# Workers claim sites with an atomic mkdir, so several inside one element are
# as safe as several across nodes. Each needs its own scratch work directory,
# which ecland_run_queue.sh derives from SLURM_ARRAY_TASK_ID -- so give each a
# distinct value rather than patching that script.
for w in \$(seq 0 $((WORKERS_PER_TASK - 1))); do
  SLURM_ARRAY_TASK_ID="\${SLURM_ARRAY_TASK_ID}w\${w}" \\
  "${SCRIPT_DIR}/ecland_run_queue.sh" \\
    -g "${GROUP}" \\
    -Q "${QUEUE}" \\
    -D "${RUN_ROOT}" \\
    -x "${ECLAND_MASTER}" \\
    -t "${FORCING_TYPE}" \\
    -n "${NAMELIST}" \\
    -l "${NLOOP}" &
done
wait
EOF
chmod +x "${JOB_SCRIPT}"

echo "Group        : ${GROUP}"
echo "Runnable     : ${n_sites} sites (forcing ${n_forcing}, physiography ${n_clim})"
echo "Queue        : ${n_todo} to run (${n_done} already done: ${n_seeded} seeded from existing output)"
echo "Claims swept : ${n_swept} (interrupted by a previous run, will be retried)"
echo "Concurrency  : ${ARRAY_TASKS} elements x ${WORKERS_PER_TASK} workers = $((ARRAY_TASKS * WORKERS_PER_TASK)) concurrent sites"
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
echo "Postproc: python3 ${SCRIPT_DIR}/postproc.py --inputdir ${RUN_ROOT}/output --outdir ${PROJECT_ROOT}/postprocessed"
