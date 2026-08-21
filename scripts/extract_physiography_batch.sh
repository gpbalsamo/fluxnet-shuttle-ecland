#!/usr/bin/env bash

# Produce ecLand's static physiography and initial conditions -- clim/<group>/
# surfclim_<site>_<Y1>-<Y2>.nc and surfinit_<site>_<Y1>-<Y2>.nc -- for every
# site that already has forcing under forcing/<group>/.
#
# This is the step that was blocked until now: FluxnetLSM converts met and flux
# data only, and plumber2-ecland's clim files were produced externally and just
# fetched from Git LFS, so there was no way to obtain soil/vegetation/orography
# fields for a new site coordinate.
#
# The work itself is done by the ecland-portal repo's hpc_scripts/
# extract_physiography.sh, which drives ecLand's own create_forcing tool. That
# script is CALLED here rather than copied: it renders the tool's config.yaml
# and invokes it, and the tool (plus the read-only rdx climate directory it
# copies static fields from) is an external dependency of any approach. Forking
# it would duplicate live code that is still being developed. Point -E
# elsewhere, or set ECLAND_PORTAL_DIR, if the portal lives somewhere else.
#
# Per site, that script does two things: copies the static fields off disk from
# /home/rdx/data/climate/climate.<CLIMVERSION>/<RESOL><GTYPE>, and issues ONE
# MARS request for the analysis that becomes surfinit. It is fast -- about 45
# seconds per site -- because the expensive hour-per-month MARS forcing
# retrieval is a different step entirely, and one we do not need: our forcing
# comes from the towers.
#
# EVERY INPUT IS DERIVED FROM THE FORCING FILES THEMSELVES -- coordinates from
# each file's latitude/longitude variables, the period from its filename. This
# is deliberate. surfclim/surfinit must sit at the same coordinate as the
# forcing and carry the same <Y1>-<Y2> suffix, because ecland_run_model.sh pairs
# them by filename. Deriving both from one source removes the possibility of a
# site being run with physiography from a different place or period than its
# weather.
#
# Resumable and parallel in the same way as run_forcing_pipeline.sh: one status
# file per site, and a site already recorded is skipped.
#
# Usage:
#   scripts/extract_physiography_batch.sh -g GROUP [options]
#
#   scripts/extract_physiography_batch.sh -g shuttle-all775-era5 -j 4
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
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

GROUP=""
SITE_LIST_FILE=""
JOBS=4
WORK_ROOT=""
PORTAL_DIR="${ECLAND_PORTAL_DIR:-${PERM:-/perm/${USER}}/ecland-portal}"
FORCING_SOURCE="auto"
WHICH_SURFACE="land"
PYTHON_BIN="${PYTHON_BIN:-python3}"
DEFAULTS="${PROJECT_ROOT}/config/physiography_defaults.yaml"
# FLake entered the operational model in May 2015; the 8.228-14.228 lake
# analysis fields do not exist in marsod before it, and create_forcing asks for
# all 26 parameters or fails. Sites starting before this take their analysis
# from ERA5, which carries all 26 at every date. Both routes read the static
# physiography from the same O1280 climate directory.
OPER_FROM="20150601"
LIMIT=""
OVERRIDE_CSV=""
RES_TAG="o2560"

usage() {
  cat <<EOF
Usage: $(basename "$0") -g GROUP [options]

  -g GROUP          Site group under forcing/ and clim/ (required)
  -S SITE_LIST_FILE One site_id per line; '#' comments and blanks ignored
                     (default: every site with a forcing file in the group)
  -n LIMIT          Process at most this many sites -- for a trial run before
                     committing to the whole group
  -j JOBS           Concurrent sites (default: ${JOBS}). Each is one MARS
                     request, so this is a courtesy limit as much as a speed one
  -W WORK_ROOT      Parent of the work directory (default: \$SCRATCH, else
                     <repo>/scripts/work). The create_forcing tool writes large
                     intermediates and points TMPDIR here, so it must be roomy
  -E PORTAL_DIR     ecland-portal checkout (default: ${PORTAL_DIR})
  -r RES_TAG        Grid the static fields are read at, when -s is auto:
                     o2560 (default, TCo2559 ~4.5 km) | o1280 (~9 km) | o4000.
                     Higher resolution puts a coastal site's nearest land point
                     much closer to the tower (5.8-10.4 km at o1280 vs 1.2-4.2
                     at o2560) and halves orography error in terrain, at ~4x the
                     runtime. o4000 currently fails inside create_sites.py.
                     NOTE: recompute the -O table against the SAME grid --
                     a table built for another grid can be worse than none.
  -s SOURCE         auto (default) | era5_<tag> | oper_<tag> | era5.
                     'auto' keeps surfclim at O1280 (~9 km) for every site and
                     picks where the surfinit analysis comes from by start date:
                     operational from ${OPER_FROM} on, ERA5 before it. The
                     operational archive has no lake fields before FLake went
                     operational in May 2015, so a pre-cutoff site can only be
                     served by ERA5 -- see config/physiography_defaults.yaml
  -D DEFAULTS       create_forcing defaults YAML (default: ${DEFAULTS})
  -u WHICH_SURFACE  orig|land (default)|lake|grass -- 'land' forces 100% land
                     fraction at the point, which is what the flux-tower case
                     wants; 'orig' keeps ERA5's own land/lake fractions
  -p PYTHON_BIN     Python with netCDF4, for reading coordinates (default: ${PYTHON_BIN})
  -O OVERRIDE_CSV   CSV of site,lat,lon replacing the coordinate taken from the
                     forcing file, for sites whose own gridpoint carries no land
                     (see scripts/nearest_land_point.py and
                     reference/physiography_land_nudge.csv). The tower keeps its
                     own coordinates everywhere else -- only these static fields
                     and the initial soil state are borrowed
  -h                Show this help
EOF
}

while getopts ":hg:S:n:j:W:E:s:u:p:D:O:r:" opt; do
  case "${opt}" in
    g) GROUP="${OPTARG}" ;;
    S) SITE_LIST_FILE="${OPTARG}" ;;
    n) LIMIT="${OPTARG}" ;;
    j) JOBS="${OPTARG}" ;;
    W) WORK_ROOT="${OPTARG}" ;;
    E) PORTAL_DIR="${OPTARG}" ;;
    s) FORCING_SOURCE="${OPTARG}" ;;
    u) WHICH_SURFACE="${OPTARG}" ;;
    p) PYTHON_BIN="${OPTARG}" ;;
    D) DEFAULTS="${OPTARG}" ;;
    O) OVERRIDE_CSV="${OPTARG}" ;;
    r) RES_TAG="${OPTARG}" ;;
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

if [[ ! -f "${DEFAULTS}" ]]; then
  echo "ERROR: defaults YAML not found: ${DEFAULTS}" >&2
  exit 1
fi
# extract_physiography.sh and render_job_config.py both read this, so our extra
# forcing_source and any path overrides reach the tool without patching either.
export ECLAND_PORTAL_DEFAULTS="${DEFAULTS}"

# Metview reads each static field whole, and its GRIB buffer defaults to 64 MiB.
# One monthly albedo field is ~128 MB at TCo2559 and ~320 MB at TCo3999, which
# segfaults the extraction ("wmo_read_any_from_file: Passed buffer is too
# small"). Raise it unless the caller already has.
export MARS_READANY_BUFFER_SIZE="${MARS_READANY_BUFFER_SIZE:-2147483648}"

EXTRACT="${PORTAL_DIR}/hpc_scripts/extract_physiography.sh"
if [[ ! -x "${EXTRACT}" ]]; then
  echo "ERROR: ecland-portal physiography script not found: ${EXTRACT}" >&2
  echo "       Pass -E <ecland-portal checkout> or set ECLAND_PORTAL_DIR." >&2
  exit 1
fi

FORCING_DIR="${PROJECT_ROOT}/forcing/${GROUP}"
CLIM_DIR="${PROJECT_ROOT}/clim/${GROUP}"
if [[ ! -d "${FORCING_DIR}" ]]; then
  echo "ERROR: no forcing directory for group '${GROUP}': ${FORCING_DIR}" >&2
  echo "       Run scripts/run_forcing_pipeline.sh for this group first." >&2
  exit 1
fi

WORK_ROOT="${WORK_ROOT:-${SCRATCH:-${PROJECT_ROOT}/scripts/work}}"
WORK_DIR="${WORK_ROOT}/physiography_${GROUP}"
LOG_DIR="${WORK_DIR}/logs"
STATUS_DIR="${WORK_DIR}/status"
RUN_TAG="${SLURM_ARRAY_JOB_ID:-run}_${SLURM_ARRAY_TASK_ID:-$$}"
RUN_DIR="${WORK_DIR}/runs/${RUN_TAG}"
mkdir -p "${CLIM_DIR}" "${LOG_DIR}" "${STATUS_DIR}" "${RUN_DIR}"

# One manifest line per site: site lat lon Y1 Y2, all read from the forcing
# file. Built once, here, so a coordinate that cannot be read is a startup
# failure rather than a job that dies 300 sites in.
MANIFEST="${RUN_DIR}/manifest.txt"
"${PYTHON_BIN}" - "${FORCING_DIR}" "${SITE_LIST_FILE}" "${OVERRIDE_CSV}" > "${MANIFEST}" <<'PY'
import csv, glob, os, re, sys
from netCDF4 import Dataset
import numpy as np

forcing_dir, site_list, override_csv = sys.argv[1], sys.argv[2], sys.argv[3]
# Sites whose own gridpoint is water take their physiography from the nearest
# land gridpoint instead; the coordinate substitution happens here so the rest
# of the pipeline is unaware of it.
override = {}
if override_csv:
    for r in csv.DictReader(open(override_csv)):
        override[r["site"]] = (float(r["lat"]), float(r["lon"]))
wanted = None
if site_list:
    wanted = set()
    for line in open(site_list):
        line = line.split("#", 1)[0].strip()
        if line:
            wanted.add(line)

pat = re.compile(r"^met_insituHT_(.+?)_(\d{4})-(\d{4})\.nc$")
for path in sorted(glob.glob(os.path.join(forcing_dir, "*.nc"))):
    m = pat.match(os.path.basename(path))
    if not m:
        print(f"SKIP unrecognised filename: {os.path.basename(path)}", file=sys.stderr)
        continue
    site, y1, y2 = m.group(1), m.group(2), m.group(3)
    if wanted is not None and site not in wanted:
        continue
    if site in override:
        lat, lon = override[site]
        print(f"OVERRIDE {site}: nearest land point {lat:.4f},{lon:.4f}", file=sys.stderr)
    else:
        with Dataset(path) as ds:
            lat = float(np.asarray(ds.variables["latitude"][:]).ravel()[0])
            lon = float(np.asarray(ds.variables["longitude"][:]).ravel()[0])
    print(f"{site} {lat:.6f} {lon:.6f} {y1} {y2}")
PY
if [[ ! -s "${MANIFEST}" ]]; then
  echo "ERROR: no sites resolved from ${FORCING_DIR}" >&2
  exit 1
fi
[[ -n "${LIMIT}" ]] && head -n "${LIMIT}" "${MANIFEST}" > "${MANIFEST}.trim" && mv "${MANIFEST}.trim" "${MANIFEST}"

n_sites=$(wc -l < "${MANIFEST}" | tr -d ' ')
n_done=$(ls "${STATUS_DIR}" 2>/dev/null | wc -l | tr -d ' ')
echo "Group        : ${GROUP}"
echo "Sites        : ${n_sites} (${n_done} already processed)"
echo "Forcing in   : ${FORCING_DIR}"
echo "Clim out     : ${CLIM_DIR}"
echo "Portal       : ${PORTAL_DIR}"
echo "Source       : ${FORCING_SOURCE} (grid ${RES_TAG})   which_surface: ${WHICH_SURFACE}"
echo "Defaults     : ${DEFAULTS}"
echo "Coord override: ${OVERRIDE_CSV:-<none>}"
echo "Workers      : ${JOBS}"
echo "Work dir     : ${WORK_DIR}"
echo "Status       : ${STATUS_DIR}/<site> (OK / NOOUTPUT / ERROR)"
echo

run_one() {
  local site="$1" lat="$2" lon="$3" y1="$4" y2="$5"
  # The analysis behind surfinit is taken at the start of the forcing period.
  local ini_date="${y1}0101"
  local source="${FORCING_SOURCE}"
  if [[ "${source}" == "auto" ]]; then
    if [[ "${ini_date}" -ge "${OPER_FROM}" ]]; then source="oper_${RES_TAG}"; else source="era5_${RES_TAG}"; fi
  fi
  if [[ -f "${STATUS_DIR}/${site}" ]]; then
    echo "[$(date '+%H:%M:%S')] SKIP (already processed) ${site}"
    return 0
  fi

  local log="${LOG_DIR}/${site}.log"
  local job_dir="${RUN_DIR}/${site}"
  rm -rf "${job_dir}"
  mkdir -p "${job_dir}"

  local status="ERROR" t0 t1
  t0=$(date +%s)
  {
    if "${EXTRACT}" "${job_dir}" "${lat}" "${lon}" "${site}" \
         "${ini_date}" "${y2}1231" "${source}" "${WHICH_SURFACE}"; then
      local n_clim
      n_clim=$(find "${job_dir}/clim" -name 'surfclim_*.nc' 2>/dev/null | wc -l | tr -d ' ')
      if [[ "${n_clim}" -eq 0 ]]; then
        status="NOOUTPUT"
      elif ! "${PYTHON_BIN}" "${SCRIPT_DIR}/check_physiography.py" "${job_dir}/clim"; then
        # The tool exits 0 for a point whose nearest gridpoint carries no land:
        # it writes both files with every physiographic field set to NaN. Such a
        # file would be accepted by the run scripts and quietly poison the run,
        # so it is refused here and reported as NOLAND rather than copied.
        status="NOLAND"
      else
        find "${job_dir}/clim" \( -name 'surfclim_*.nc' -o -name 'surfinit_*.nc' \) \
          -exec cp {} "${CLIM_DIR}/" \;
        status="OK"
      fi
    fi
  } > "${log}" 2>&1

  rm -rf "${job_dir}"
  echo "${status}" > "${STATUS_DIR}/${site}"
  t1=$(date +%s)
  echo "[$(date '+%H:%M:%S')] ${status}  ${site} [${source}] ($(( t1 - t0 ))s)"
}
export -f run_one
export EXTRACT CLIM_DIR LOG_DIR STATUS_DIR RUN_DIR FORCING_SOURCE WHICH_SURFACE PYTHON_BIN SCRIPT_DIR ECLAND_PORTAL_DEFAULTS OPER_FROM RES_TAG MARS_READANY_BUFFER_SIZE

start=$(date +%s)
xargs -P "${JOBS}" -L1 bash -c 'run_one "$@"' _ < "${MANIFEST}"
end=$(date +%s)

echo
echo "=== Summary ($(( end - start ))s) ==="
for s in OK NOOUTPUT ERROR; do
  c=$(cat "${STATUS_DIR}"/* 2>/dev/null | grep -c "^${s}\$" || true)
  [[ "${c}" -gt 0 ]] && echo "  ${s}: ${c}"
done
echo "surfclim files: $(find "${CLIM_DIR}" -name 'surfclim_*.nc' | wc -l | tr -d ' ')"
echo "surfinit files: $(find "${CLIM_DIR}" -name 'surfinit_*.nc' | wc -l | tr -d ' ')"
