#!/usr/bin/env bash

# Retrieve a forcing or climatology NetCDF file from the Git LFS store of
# this repository and place it at the requested target path.
#
# Usage (single file):
#   ecland_retrieve_lfs.sh <relative_file_path> [target_file_path]
#
# Usage (all PLUMBER2 sites):
#   ecland_retrieve_lfs.sh --all [--forcing-type <type>] [--group <group>]
#
# Single-file arguments:
#   relative_file_path   Path relative to the repository root,
#                        e.g. forcing/PLUMBER2/met_insituHT_AR-SLu_2010-2010.nc
#   target_file_path     Where to put the file (default: ./<relative_file_path>).
#                        Trailing '/' appends the filename automatically.
#
# --all options:
#   --forcing-type <type>  Forcing type prefix used in filenames. Default: insitu
#   --group <group>        Dataset group subdirectory name.       Default: PLUMBER2
#
# In --all mode the files are fetched and materialised in-place inside the
# repository:
#   <repo>/forcing/<group>/met_<type>HT_<site>.nc
#   <repo>/clim/<group>/surfinit_<site>.nc
#   <repo>/clim/<group>/surfclim_<site>.nc
#
# The script resolves the repository root from its own location, so it can be
# called from any working directory.
#
# (C) Copyright 2023- ECMWF.
#
# This software is licensed under the terms of the Apache Licence Version 2.0
# which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
#
# In applying this licence, ECMWF does not waive the privileges and immunities
# granted to it by virtue of its status as an intergovernmental organisation nor
# does it submit to any jurisdiction.

set -euo pipefail

SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd -P )"
REPO_ROOT="$( cd "${SCRIPTS_DIR}/.." && pwd -P )"

# ---------------------------------------------------------------------------
# All PLUMBER2 sites
# ---------------------------------------------------------------------------

ALL_SITES=(
  ID-Pag_2002-2003  RU-Zot_2003-2003  CA-Qcu_2002-2006  US-AR2_2010-2011
  BW-Ma1_2000-2000  CN-Cng_2008-2009  IT-Non_2002-2002  US-Ne1_2002-2012
  US-SP1_2005-2005  US-SP3_1999-2004  US-SRM_2004-2014  US-Ha1_1992-2012
  US-WCr_1999-2006  CA-SF2_2003-2005  CA-NS4_2003-2004  US-MOz_2005-2006
  US-ARM_2003-2012  DE-Hai_2000-2012  IT-Lav_2005-2014  CA-SF3_2003-2005
  UK-Ham_2004-2004  US-Ton_2001-2014  US-SRG_2009-2014  US-PFa_1995-2014
  DK-Lva_2005-2006  US-Ne3_2002-2012  NL-Hor_2008-2011  CN-Du2_2007-2008
  PT-Esp_2002-2004  IT-Cpz_2001-2008  US-Bo1_1997-2006  FI-Kaa_2000-2002
  AU-Cum_2013-2018  FR-Lq2_2004-2006  DE-SfN_2013-2014  BR-Sa3_2001-2003
  BE-Vie_1997-2014  AU-DaS_2010-2017  AU-Lit_2016-2017  FR-Fon_2005-2013
  DE-Geb_2001-2014  IT-SRo_2003-2012  AU-Sam_2011-2017  US-Blo_2000-2006
  AU-Stp_2010-2017  PL-wet_2004-2005  PT-Mi1_2005-2005  RU-Che_2003-2004
  ES-LMa_2004-2006  IT-Ro2_2002-2008  SE-Deg_2002-2005  AU-Whr_2015-2016
  US-Bkg_2005-2006  BE-Bra_2004-2014  CA-SF1_2004-2006  DE-Tha_1998-2014
  AU-Ctr_2010-2017  IT-Noe_2004-2014  FI-Sod_2008-2014  AU-Otw_2009-2010
  AU-GWW_2013-2017  US-Ne2_2002-2012  CN-Qia_2003-2005  CH-Fru_2007-2014
  FR-Gri_2005-2013  FR-Hes_1997-2006  US-Aud_2003-2005  AR-SLu_2010-2010
  DE-Obe_2008-2014  US-Me4_1996-2000  IT-Isp_2013-2014  IT-CA3_2012-2013
  DK-Fou_2005-2005  AU-Cow_2010-2015  FI-Lom_2007-2009  AU-TTE_2013-2017
  FI-Hyy_1996-2014  IE-Dri_2003-2005  IT-CA1_2012-2013  DE-Gri_2004-2014
  US-AR1_2010-2012  AU-Wrr_2016-2017  FR-Lq1_2004-2006  IT-LMa_2003-2004
  ES-ES1_1999-2006  US-KS2_2003-2006  AU-Ync_2011-2017  CH-Cha_2006-2014
  CA-NS6_2002-2004  US-Los_2000-2008  US-Var_2001-2014  UK-PL3_2005-2006
  AU-Tum_2002-2017  AU-Gin_2012-2017  US-Twt_2010-2014  ES-LgS_2007-2007
  ES-VDA_2004-2004  DE-Bay_1997-1999  IT-Mal_2003-2003  US-FPe_2000-2006
  US-Prr_2011-2013  ES-ES2_2005-2006  HU-Bug_2003-2006  CA-Qfo_2004-2010
  AU-DaP_2009-2012  AU-Emr_2012-2013  FR-LBr_2003-2008  DE-Seh_2008-2010
  CA-NS5_2003-2004  NL-Loo_1997-2013  IT-SR2_2013-2014  CH-Oe1_2002-2008
  US-SP2_2000-2004  AU-Rig_2011-2016  AU-Rob_2014-2017  CH-Dav_1997-2014
  IT-Ren_2010-2013  US-Bar_2005-2005  CA-NS1_2003-2003  CN-HaM_2002-2003
  DE-Meh_2004-2006  IT-Amp_2003-2006  US-Me6_2011-2014  IT-MBo_2003-2012
  AU-ASM_2011-2017  NL-Ca1_2003-2006  SD-Dem_2005-2009  GF-Guy_2004-2014
  PT-Mi2_2005-2006  US-Cop_2002-2003  US-MMS_1999-2014  BE-Lon_2005-2014
  CN-Din_2003-2005  FR-Pue_2000-2014  IT-Col_2007-2014  IE-Ca1_2004-2006
  US-Whs_2008-2014  IT-PT1_2003-2004  US-Me2_2002-2014  CZ-wet_2007-2014
  ZM-Mon_2008-2008  US-Ho1_1996-2004  US-NR1_1999-2014  US-Myb_2011-2014
  AU-Dry_2011-2015  DE-Kli_2005-2014  DK-ZaH_2000-2013  AU-How_2003-2017
  DE-Wet_2002-2006  CA-NS7_2003-2004  US-Wkg_2005-2014  US-GLE_2009-2014
  US-Goo_2004-2006  US-Tw4_2014-2014  ZA-Kru_2000-2002  IT-Ro1_2002-2006
  CN-Cha_2003-2005  JP-SMF_2003-2006  US-UMB_2000-2014  DK-Sor_1997-2014
  IT-BCi_2005-2010  UK-Gri_2000-2001  AT-Neu_2002-2012  AU-Cpr_2011-2017
  US-Syv_2002-2008  CN-Dan_2004-2005  DK-Ris_2004-2005  RU-Fyo_2003-2014
  CA-NS2_2002-2004  IT-CA2_2012-2013
)

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "Usage: $(basename "$0") <relative_file_path> [target_file_path]" >&2
  echo "       $(basename "$0") --all [--forcing-type <type>] [--group <group>]" >&2
  exit 1
fi

# --all mode: fetch and materialise all LFS files in-place in the repository
if [[ "$1" == "--all" ]]; then
  shift
  FORCING_TYPE="insitu"
  GROUP="PLUMBER2"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --forcing-type) FORCING_TYPE="$2"; shift 2 ;;
      --group)        GROUP="$2";        shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  FORCING_DIR="${REPO_ROOT}/forcing/${GROUP}"
  CLIM_DIR="${REPO_ROOT}/clim/${GROUP}"

  echo "Fetching all ${#ALL_SITES[@]} PLUMBER2 sites from Git LFS into:"
  echo "  ${FORCING_DIR}"
  echo "  ${CLIM_DIR}"

  # Build include patterns for a single bulk fetch
  include_patterns=""
  for site in "${ALL_SITES[@]}"; do
    include_patterns+="forcing/${GROUP}/met_${FORCING_TYPE}HT_${site}.nc,"
    include_patterns+="clim/${GROUP}/surfinit_${site}.nc,"
    include_patterns+="clim/${GROUP}/surfclim_${site}.nc,"
  done
  include_patterns="${include_patterns%,}"  # strip trailing comma

  echo "Running git lfs fetch..."
  git -C "${REPO_ROOT}" lfs fetch --include="${include_patterns}"

  echo "Checking out LFS objects..."
  git -C "${REPO_ROOT}" lfs checkout "${FORCING_DIR}"
  git -C "${REPO_ROOT}" lfs checkout "${CLIM_DIR}"

  echo "Done."
  exit 0
fi

# Single-file mode
FILE_PATH=$1
FILE=$(basename "${FILE_PATH}")

TARGET_FILE_PATH=${2:-$(pwd)/${FILE_PATH}}
if [[ "${TARGET_FILE_PATH}" == */ ]]; then
  TARGET_FILE_PATH="${TARGET_FILE_PATH}${FILE}"
fi

TARGET_FILE=$(basename "${TARGET_FILE_PATH}")
LOCATION=$(dirname "${TARGET_FILE_PATH}")

LFS_SOURCE="${REPO_ROOT}/${FILE_PATH}"

# ---------------------------------------------------------------------------
# 1. Already present at target — nothing to do
# ---------------------------------------------------------------------------

if [[ -f "${TARGET_FILE_PATH}" ]]; then
  echo "File already available at: ${TARGET_FILE_PATH}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Ensure git-lfs is available
# ---------------------------------------------------------------------------

if ! command -v git-lfs &>/dev/null && ! git lfs version &>/dev/null 2>&1; then
  echo "ERROR: git-lfs is not available. Install it and run 'git lfs install'." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Fetch the file from LFS if it is only a pointer in the working tree
# ---------------------------------------------------------------------------

if [[ ! -f "${LFS_SOURCE}" ]]; then
  echo "ERROR: '${FILE_PATH}' does not exist in the repository at ${REPO_ROOT}." >&2
  echo "Check that the path is correct and the file is tracked by Git LFS." >&2
  exit 1
fi

# If the file is an LFS pointer (not the real content yet), fetch it now.
if git -C "${REPO_ROOT}" lfs ls-files --name-only 2>/dev/null | grep -qF "${FILE_PATH}"; then
  file_size=$(wc -c < "${LFS_SOURCE}")
  if [[ ${file_size} -lt 1024 ]]; then
    echo "Fetching '${FILE_PATH}' from Git LFS..."
    git -C "${REPO_ROOT}" lfs fetch --include="${FILE_PATH}"
    git -C "${REPO_ROOT}" lfs checkout "${LFS_SOURCE}"
    echo "LFS fetch complete."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Place the file at the target location
# ---------------------------------------------------------------------------

mkdir -p "${LOCATION}"

# Prefer a hard link (same filesystem); fall back to copy.
if ln "${LFS_SOURCE}" "${TARGET_FILE_PATH}" 2>/dev/null; then
  echo "Hard-linked '${FILE_PATH}' to: ${TARGET_FILE_PATH}"
else
  echo "Copying '${FILE_PATH}' to: ${TARGET_FILE_PATH}"
  cp "${LFS_SOURCE}" "${TARGET_FILE_PATH}"
fi

echo "File is available at: ${TARGET_FILE_PATH}"
