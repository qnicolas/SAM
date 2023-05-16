set -e
module load cpu/1.0
module load PrgEnv-gnu/8.3.3
module swap gcc/11.2.0
module swap cray-mpich/8.1.22
module swap craype/2.7.19
module load cray-hdf5/1.12.2.1
module load cray-netcdf/4.9.0.1
module load cray-parallel-netcdf/1.12.3.1
export HDF5_USE_FILE_LOCKING=FALSE

module unload darshan  #can lead to a run-time error from mpich after 2022 March update
module list
