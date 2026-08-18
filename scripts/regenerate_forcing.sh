#!/usr/bin/env bash

# Convert ALMA-CF Met files (ORIG_DIR) into ecLand-ready forcing files
# (OUT_DIR). Two sources are in use here:
#
#   - FluxnetLSM output for a Shuttle site, i.e. <outdir>/Nc_files/Met --
#     this is what scripts/run_forcing_pipeline.sh points ORIG_DIR at;
#   - the raw PLUMBER2 v1.0 download from NCI (forcing/PLUMBER2_original/),
#     which is what the defaults below assume, as inherited from
#     plumber2-ecland where this script originated.
#
# Both carry the same variable/dimension conventions, so no source-specific
# handling is needed.
#
# Unlike the original fix_forcing.py (which subset the raw files down to just
# the 7 driving variables and stripped metadata), this script keeps every
# variable and global attribute from the source file -- QC flags, VPD, RH,
# CO2air, LAI, per-variable Missing_%/Gap-filled_% (see scripts/qc_classify.py),
# site metadata (latitude/longitude/elevation/canopy_height/vegetation type/
# soil) -- and only does the minimum needed for ecLand to read the file:
#
#   - rename dims   x,y      -> lon,lat
#   - rename vars   Psurf    -> PSurf
#                   Precip   -> Rainf
#   - drop the degenerate x/y index variables (real coordinates are kept in
#     the latitude/longitude data variables)
#   - make time a record (unlimited) dimension
#   - rename the file to the met_insituHT_<site>_<years>.nc convention
#     ecland_run_model.sh expects
#
# Requires: NCO (ncrename, ncks, ncatted, nccopy)
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

ORIG_DIR="${ORIG_DIR:-${PROJECT_ROOT}/forcing/PLUMBER2_original}"
OUT_DIR="${OUT_DIR:-${PROJECT_ROOT}/forcing/PLUMBER2}"
DEFLATE_LEVEL="${DEFLATE_LEVEL:-4}"

if [[ ! -d "${ORIG_DIR}" ]]; then
  echo "ERROR: source directory does not exist: ${ORIG_DIR}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
touch "${OUT_DIR}/.gitkeep"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

shopt -s nullglob
files=("${ORIG_DIR}"/*.nc)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "ERROR: no .nc files found in ${ORIG_DIR}" >&2
  exit 1
fi

echo "Source : ${ORIG_DIR} (${#files[@]} files)"
echo "Output : ${OUT_DIR}"
echo

n=0
for src in "${files[@]}"; do
  base="$(basename "${src}" .nc)"

  # Expected raw filename: <SITE>_<years>_<network>_Met.nc
  if [[ ! "${base}" =~ ^(.+)_([0-9]{4}-[0-9]{4})_[A-Za-z0-9]+_Met$ ]]; then
    echo "SKIP (unrecognised filename): ${base}.nc" >&2
    continue
  fi
  site="${BASH_REMATCH[1]}"
  years="${BASH_REMATCH[2]}"

  out="${OUT_DIR}/met_insituHT_${site}_${years}.nc"
  tmp="${work_dir}/${site}_${years}.nc"

  # Record where this file actually came from (parent dir + filename), rather
  # than asserting a fixed PLUMBER2_original provenance: ORIG_DIR is just as
  # often FluxnetLSM output for a Shuttle site.
  srcref="$(basename "$(dirname "${src}")")/$(basename "${src}")"

  cp "${src}" "${tmp}"

  # Rename dims/vars to ecLand's expected names; -h suppresses the noisy
  # auto-generated "history" entries NCO would otherwise append per command.
  ncrename -O -h -d x,lon -d y,lat -v Psurf,PSurf -v Precip,Rainf "${tmp}" "${tmp}"
  ncks -O -h -x -v x,y "${tmp}" "${tmp}"
  ncks -O -h --mk_rec_dmn time "${tmp}" "${tmp}"
  ncatted -O -h -a history,global,a,c," Regenerated $(date -u +%Y-%m-%dT%H:%M:%SZ) from ${srcref} by scripts/regenerate_forcing.sh: dims x,y renamed to lon,lat; Psurf->PSurf; Precip->Rainf; x,y index vars dropped; all other source variables, QC flags and metadata preserved as-is.\n" "${tmp}"

  nccopy -d"${DEFLATE_LEVEL}" -s "${tmp}" "${out}"

  n=$((n + 1))
  echo "[$n/${#files[@]}] ${site}_${years} -> $(basename "${out}")"
done

echo
echo "Done: ${n} site files written to ${OUT_DIR}"
