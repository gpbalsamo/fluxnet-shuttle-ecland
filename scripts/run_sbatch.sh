#!/bin/bash
#SBATCH -n 1
#SBATCH -t 4:00:00

module load prgenv/intel intel/2021.4 python3/3.10.10-01
module load hpcx-openmpi/2.9 netcdf4/4.9.1
${SCRIPTS_DIR}/ecland_run_model.sh   \
    -s ${cs}                \
    -b ${ECLAND_MASTER}     \
    -w ${WORK_DIR}          \
    -o ${OUTPUT_DIR}        \
    -f ${FORCING_DIR}       \
    -i ${INICLM_DIR}        \
    -F ${FORCING_TYPE}      \
    -l ${NLOOP}             \
    -R ${LRESTART}  \
    -n ${NAMELIST}

trace() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

trace ${SCRIPTS_DIR}/ecland_run_model.sh   \
    -s "${cs}"           \
    -b "${ECLAND_MASTER}"\
    -w "${WORK_DIR}"     \
    -o "${OUTPUT_DIR}"   \
    -f "${FORCING_DIR}"  \
    -i "${INICLM_DIR}"   \
    -F "${FORCING_TYPE}" \
    -n "${NAMELIST}"     \
    ${NAMELIST_CMF_OPT}  \
    -l ${NLOOP}          \
    ${PARAM_FILE_OPT}    \
    -R ${LRESTART}
