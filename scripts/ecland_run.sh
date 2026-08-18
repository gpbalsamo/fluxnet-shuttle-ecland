#!/bin/bash
# Script to run the ecland model on pre-downloaded forcing and initial conditions.
#
# This is the ECMWF HPC entry point: it loads the site's compiler/MPI/netCDF
# modules and runs under LBATCH=true with the paths below hardcoded. ecLand
# itself is not HPC-only -- for a local (macOS) run use
# scripts/run_parallel_local.sh or scripts/run_and_proc_macos.sh instead, which
# drive the same ecland_run_experiment.sh with LBATCH=false.

# To compile:
#module load prgenv/intel intel/2021.4 cmake/3.25 ninja/1.11.1 hpcx-openmpi/2.9 netcdf4/4.9.1 ecbuild/new ecmwf-toolbox/new python3/new
#====== Load modules for intel compiler

module load prgenv/intel intel/2021.4 python3/3.10.10-01
module load hpcx-openmpi/2.9 netcdf4/4.9.1

#====== Setup (change these as required)
GROUP=shuttle-pilot20
FORCING_TYPE=insitu
INPUT_DIR=/perm/pad/fluxnet-shuttle-ecland/
OUTPUT_DIR=/perm/${USER}/${GROUP}/
WORK_DIR=/scratch/${USER}/work_${GROUP}/
NLOOP=2
export LBATCH=true
export PATH=${ecland_ROOT:-/perm/pad/ecland/build}/bin:$PATH
export MEM_PER_CPU='16G'
NAMELIST_FILE="namelist_ecland_50R1_ctl"
eclandExe="/perm/pad/ecland/build/bin/ecland-master-dp"
export LAUNCH='mpirun -np 1'

#===============================================
START=$(date +%s)

ecland-run-experiment -g ${GROUP}\
                      -t ${FORCING_TYPE}\
                      -i ${INPUT_DIR}\
                      -o ${OUTPUT_DIR}\
                      -l ${NLOOP}\
                      -n "/perm/pad/fluxnet-shuttle-ecland/namelists/${NAMELIST_FILE}"\
                      -x ${eclandExe}\
                      -w ${WORK_DIR}
                      #-s "CL-002_1997010100-2014123100"\
END=$(date +%s)
DIFF=$(( $END - $START ))
echo -e "\n\n\t Running ecland-run-experiment on ${GROUP} took $DIFF seconds\n"
