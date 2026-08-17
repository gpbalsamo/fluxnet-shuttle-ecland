#!/usr/bin/env bash

# Align the lat/lon coordinate values in clim/PLUMBER2/surfclim_<site>.nc and
# surfinit_<site>.nc with the latitude/longitude carried in the corresponding
# forcing/PLUMBER2/met_insituHT_<site>.nc file.
#
# This only overwrites the scalar lat/lon coordinate values in-place; it does
# NOT re-derive the soil/vegetation/orography/climatology fields for the new
# coordinate -- those still reflect whatever location the surfclim/surfinit
# files were originally built for. This script is a coordinate-label fix,
# not a re-extraction of the static fields at the forcing's site location.
#
# Requires: NCO (ncap2), and forcing/PLUMBER2/ already populated (see
# regenerate_plumber2_forcing.sh).
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

FORCING_DIR="${FORCING_DIR:-${PROJECT_ROOT}/forcing/PLUMBER2}"
CLIM_DIR="${CLIM_DIR:-${PROJECT_ROOT}/clim/PLUMBER2}"

# Print the scalar value of a netCDF variable that appears as:
#   varname =
#     123.456 ;
get_val() {
  local file="$1" var="$2"
  ncks -H -C -v "${var}" "${file}" | awk -v v="${var}" '
    $0 ~ "^[[:space:]]*"v"[[:space:]]*=[[:space:]]*$" { getline; gsub(/[ ;]/,""); print; exit }
  '
}

shopt -s nullglob
forcing_files=("${FORCING_DIR}"/met_insituHT_*.nc)
shopt -u nullglob

if [[ ${#forcing_files[@]} -eq 0 ]]; then
  echo "ERROR: no forcing files found in ${FORCING_DIR}" >&2
  exit 1
fi

echo "Forcing: ${FORCING_DIR} (${#forcing_files[@]} files)"
echo "Clim   : ${CLIM_DIR}"
echo

n=0
skipped=0
for f in "${forcing_files[@]}"; do
  base="$(basename "${f}" .nc)"
  # met_insituHT_<SITE>_<years> -> <SITE>_<years>
  site_years="${base#met_insituHT_}"

  surfclim="${CLIM_DIR}/surfclim_${site_years}.nc"
  surfinit="${CLIM_DIR}/surfinit_${site_years}.nc"

  if [[ ! -f "${surfclim}" || ! -f "${surfinit}" ]]; then
    echo "SKIP (missing clim files): ${site_years}" >&2
    skipped=$((skipped + 1))
    continue
  fi

  flat=$(get_val "${f}" latitude)
  flon=$(get_val "${f}" longitude)

  if [[ -z "${flat}" || -z "${flon}" ]]; then
    echo "SKIP (no latitude/longitude in forcing file): ${site_years}" >&2
    skipped=$((skipped + 1))
    continue
  fi

  ncap2 -O -h -s "lat(0)=${flat}; lon(0)=${flon}" "${surfclim}" "${surfclim}"
  ncap2 -O -h -s "lat(0)=${flat}; lon(0)=${flon}" "${surfinit}" "${surfinit}"

  n=$((n + 1))
  echo "[${n}] ${site_years}: lat=${flat} lon=${flon}"
done

echo
echo "Done: aligned ${n} sites, skipped ${skipped}."
