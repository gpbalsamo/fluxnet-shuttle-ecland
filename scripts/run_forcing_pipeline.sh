#!/usr/bin/env bash

# Batch-process Shuttle sites into ecLand-ready Met forcing NetCDF, end to end:
#   fluxnet-shuttle download -> extract FLUXMET_HH CSV -> convert_fluxnetlsm.R
#   -> regenerate_forcing.sh -> forcing/<group>/met_insituHT_<site>_<years>.nc
#
# Deliberately streams one site at a time and deletes each site's raw
# download/extracted CSV (up to ~500MB per site) as soon as it's no longer
# needed, rather than accumulating all sites' downloads -- 775 sites' raw
# zips alone would need >100GB, more than typically available locally.
# Final outputs are small (a few MB per site, only for years that survive
# FluxnetLSM's QC screening).
#
# Resumable: a site already recorded in the status dir is skipped, so a
# killed/interrupted run can just be re-invoked with the same arguments. To
# retry only sites that failed transiently (NODOWNLOAD/BADZIP -- a network
# blip mid-download, not a real "no data" verdict like NOFLUXMET/NOYEARS),
# delete just their status files first, e.g.:
#   grep -lxE 'NODOWNLOAD|BADZIP' scripts/work/forcing_pipeline_<group>/status/* | xargs rm
# then re-invoke with the same arguments.
#
# Requires: scripts/install_fluxnetlsm.R already run, and
# scripts/build_site_metadata.py already run to produce --site-csv (or pass
# your own / omit to use FluxnetLSM's bundled ~874-site table only).
#
# Usage:
#   scripts/run_forcing_pipeline.sh -f SNAPSHOT_CSV -g GROUP [-S SITE_LIST_FILE]
#     [-c SITE_CSV] [-j JOBS] [-m MIN_YEARS]
#
#   scripts/run_forcing_pipeline.sh \
#     -f fluxnet_shuttle_snapshot_20260817T174055.csv \
#     -g shuttle-all775 \
#     -c reference/site_metadata_merged.csv \
#     -j 4

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

SNAPSHOT_CSV=""
GROUP=""
SITE_LIST_FILE=""
SITE_CSV="${PROJECT_ROOT}/reference/site_metadata_merged.csv"
JOBS=4
MIN_YEARS=""
GAPFILL="statistical"
PRESET="medium"

usage() {
  cat <<EOF
Usage: $(basename "$0") -f SNAPSHOT_CSV -g GROUP [options]

  -f SNAPSHOT_CSV   fluxnet-shuttle listall snapshot CSV (required)
  -g GROUP          Output subdirectory name under forcing/ and flux/ (required)
  -S SITE_LIST_FILE One site_id per line (default: every site_id in SNAPSHOT_CSV)
  -c SITE_CSV       FluxnetLSM site metadata CSV, forwarded as convert_fluxnetlsm.R
                     --site-csv (default: ${SITE_CSV})
  -j JOBS           Concurrent site pipelines (default: ${JOBS})
  -m MIN_YEARS      convert_fluxnetlsm.R --min-years (default: unset -- use the
                     preset's own min_yrs, see convert_fluxnetlsm.R --preset)
  -P PRESET         mild|medium (default)|heavy|complete -- acceptance-threshold
                     bundle, forwarded as convert_fluxnetlsm.R --preset (see its
                     header for what each level actually changes)
  -G GAPFILL        statistical (default) or erainterim -- erainterim also extracts
                     each site's *_ERA5_HH_*.csv from the same download and passes it
                     as convert_fluxnetlsm.R --era-file (see convert_fluxnetlsm.R's
                     header for why "erainterim" here means real ERA5 data)
  -h                Show this help
EOF
}

while getopts ":hf:g:S:c:j:m:G:P:" opt; do
  case "${opt}" in
    f) SNAPSHOT_CSV="${OPTARG}" ;;
    g) GROUP="${OPTARG}" ;;
    S) SITE_LIST_FILE="${OPTARG}" ;;
    c) SITE_CSV="${OPTARG}" ;;
    j) JOBS="${OPTARG}" ;;
    m) MIN_YEARS="${OPTARG}" ;;
    G) GAPFILL="${OPTARG}" ;;
    P) PRESET="${OPTARG}" ;;
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

if [[ -z "${SITE_LIST_FILE}" ]]; then
  SITE_LIST_FILE="${PROJECT_ROOT}/scripts/work/forcing_pipeline_${GROUP}/all_site_ids.txt"
  mkdir -p "$(dirname "${SITE_LIST_FILE}")"
  python3 -c "
import csv
seen = set()
for r in csv.DictReader(open('${SNAPSHOT_CSV}')):
    seen.add(r['site_id'])
for s in sorted(seen):
    print(s)
" > "${SITE_LIST_FILE}"
fi
if [[ ! -f "${SITE_LIST_FILE}" ]]; then
  echo "ERROR: site list file not found: ${SITE_LIST_FILE}" >&2
  exit 1
fi

WORK_DIR="${PROJECT_ROOT}/scripts/work/forcing_pipeline_${GROUP}"
FORCING_DIR="${PROJECT_ROOT}/forcing/${GROUP}"
FLUX_DIR="${PROJECT_ROOT}/flux/${GROUP}"
LOG_DIR="${WORK_DIR}/logs"
STATUS_DIR="${WORK_DIR}/status"
mkdir -p "${FORCING_DIR}" "${FLUX_DIR}" "${LOG_DIR}" "${STATUS_DIR}" \
         "${WORK_DIR}/dl" "${WORK_DIR}/convert" "${WORK_DIR}/met_src"

n_sites=$(grep -c . "${SITE_LIST_FILE}")
n_done=$(ls "${STATUS_DIR}" 2>/dev/null | wc -l | tr -d ' ')
echo "Group        : ${GROUP}"
echo "Sites        : ${n_sites} (from ${SITE_LIST_FILE}), ${n_done} already processed"
echo "Site CSV     : ${SITE_CSV}"
echo "Workers      : ${JOBS}"
echo "Forcing out  : ${FORCING_DIR}"
echo "Flux out     : ${FLUX_DIR}"
echo "Logs         : ${LOG_DIR}/<site>.log"
echo "Gapfill      : ${GAPFILL}"
echo "Preset       : ${PRESET}"
echo "Status       : ${STATUS_DIR}/<site> (OK / NODOWNLOAD / BADZIP / NOFLUXMET / NOERA5 / NOYEARS / NOMET / ERROR)"
echo

run_one() {
  local site="$1"
  if [[ -f "${STATUS_DIR}/${site}" ]]; then
    echo "[$(date '+%H:%M:%S')] SKIP (already processed) ${site}"
    return 0
  fi

  local log="${LOG_DIR}/${site}.log"
  local dl_dir="${WORK_DIR}/dl/${site}"
  local convert_out="${WORK_DIR}/convert/${site}"
  local met_src_dir="${WORK_DIR}/met_src/${site}"
  rm -rf "${dl_dir}" "${convert_out}" "${met_src_dir}"
  mkdir -p "${dl_dir}"

  local status="ERROR"
  local t0 t1
  t0=$(date +%s)
  {
    if ! "${SHUTTLE_BIN}" download -f "${SNAPSHOT_CSV}" -s "${site}" -o "${dl_dir}" --quiet; then
      status="NODOWNLOAD"
    else
      local zipfile
      zipfile=$(find "${dl_dir}" -maxdepth 1 -name '*.zip' | head -1)
      if [[ -z "${zipfile}" ]]; then
        status="NODOWNLOAD"
      elif ! unzip -tq "${zipfile}" >/dev/null 2>&1; then
        # A network blip mid-download can leave a truncated/corrupt zip even
        # though the shuttle CLI itself reported success -- `unzip -t`
        # verifies the archive's integrity before extracting, so this is
        # told apart from a genuine "no FLUXMET product for this site"
        # (NOFLUXMET below) and can be safely retried later.
        status="BADZIP"
      else
        unzip -o -q "${zipfile}" -d "${dl_dir}/extracted"
        rm -f "${zipfile}"
        local csv era5_csv era_args=()
        # TERN/OzFlux sites ship hourly data (*_HR_*) instead of half-hourly
        # (*_HH_*) -- same FLUXNET2015 column schema either way (confirmed
        # 2026-08-18: FluxnetLSM auto-detects the timestep from the data's
        # own TIMESTAMP_START/END spacing, no special-casing needed), but the
        # filename pattern differs. Falling back to *_HR_* below fixes what
        # first looked like network-outage-caused NOFLUXMET failures but was
        # actually this filename gap -- would have affected every TERN site
        # regardless of network conditions.
        csv=$(find "${dl_dir}/extracted" -iname '*FLUXMET_HH*.csv' | head -1)
        [[ -z "${csv}" ]] && csv=$(find "${dl_dir}/extracted" -iname '*FLUXMET_HR*.csv' | head -1)
        if [[ -z "${csv}" ]]; then
          status="NOFLUXMET"
        elif [[ "${GAPFILL}" == "erainterim" ]] && \
             era5_csv=$( { find "${dl_dir}/extracted" -iname '*_ERA5_HH_*.csv'; find "${dl_dir}/extracted" -iname '*_ERA5_HR_*.csv'; } | head -1) && \
             [[ -z "${era5_csv}" ]]; then
          status="NOERA5"
        else
          [[ "${GAPFILL}" == "erainterim" ]] && era_args=(--era-file="${era5_csv}")
          [[ -n "${MIN_YEARS}" ]] && era_args+=(--min-years="${MIN_YEARS}")
          if Rscript "${SCRIPT_DIR}/convert_fluxnetlsm.R" \
              --site="${site}" --infile="${csv}" --outdir="${convert_out}" \
              --site-csv="${SITE_CSV}" --preset="${PRESET}" --gapfill="${GAPFILL}" \
              "${era_args[@]+"${era_args[@]}"}"; then
            # FluxnetLSM writes one NetCDF per disjoint qualifying
            # consecutive-year block, not just the single longest one (e.g.
            # a site can pass screening for both 2009 and 2011-2013
            # separately) -- copy every Met/Flux file found, not just one,
            # so no valid period is silently dropped.
            local n_met n_flux
            n_met=$(find "${convert_out}/Nc_files/Met" -name '*.nc' 2>/dev/null | wc -l | tr -d ' ')
            n_flux=$(find "${convert_out}/Nc_files/Flux" -name '*.nc' 2>/dev/null | wc -l | tr -d ' ')
            if [[ "${n_met}" -eq 0 ]]; then
              status="NOMET"
            else
              mkdir -p "${met_src_dir}"
              find "${convert_out}/Nc_files/Met" -name '*.nc' -exec cp {} "${met_src_dir}/" \;
              if ORIG_DIR="${met_src_dir}" OUT_DIR="${FORCING_DIR}" "${SCRIPT_DIR}/regenerate_forcing.sh"; then
                if [[ "${n_flux}" -gt 0 ]]; then
                  find "${convert_out}/Nc_files/Flux" -name '*.nc' -exec cp {} "${FLUX_DIR}/" \;
                fi
                status="OK"
                echo "  (${n_met} period(s) written for ${site})"
              else
                status="ADAPT_FAILED"
              fi
            fi
          else
            status="NOYEARS"
          fi
        fi
      fi
    fi
  } > "${log}" 2>&1

  rm -rf "${dl_dir}" "${convert_out}" "${met_src_dir}"
  echo "${status}" > "${STATUS_DIR}/${site}"
  t1=$(date +%s)
  echo "[$(date '+%H:%M:%S')] ${status}  ${site} ($(( t1 - t0 ))s)"
}
export -f run_one
export SCRIPT_DIR SNAPSHOT_CSV SITE_CSV MIN_YEARS GAPFILL PRESET WORK_DIR FORCING_DIR FLUX_DIR LOG_DIR STATUS_DIR
export SHUTTLE_BIN="${SHUTTLE_BIN:-fluxnet-shuttle}"

start=$(date +%s)
xargs -P "${JOBS}" -I{} bash -c 'run_one "$@"' _ {} < "${SITE_LIST_FILE}"
end=$(date +%s)

echo
echo "=== Summary ($(( end - start ))s) ==="
for s in OK NODOWNLOAD BADZIP NOFLUXMET NOERA5 NOYEARS NOMET ADAPT_FAILED ERROR; do
  c=$(ls "${STATUS_DIR}" 2>/dev/null | xargs -I{} cat "${STATUS_DIR}/{}" 2>/dev/null | grep -c "^${s}\$" || true)
  [[ "${c}" -gt 0 ]] && echo "  ${s}: ${c}"
done
echo "Forcing files written: $(find "${FORCING_DIR}" -name '*.nc' 2>/dev/null | wc -l | tr -d ' ')"
