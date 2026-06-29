# Delft3D FM Container (DIMRset 2026.01)

Run **D‑Flow FM** and the **DIMR** coupling framework anywhere with a single
Docker/Podman image.  Built from the open‑source
[Delft3D](https://github.com/Deltares/Delft3D) release **DIMRset_2026.01**,
it bundles all needed libraries (HDF5, NetCDF, PETSc, Boost, preCICE, ESMF)
and the Intel MPI runtime.

## Quick start – run a simulation
## Pull the image 

https://hub.docker.com/r/adnanrauf/delft3dfm

docker pull adnanrauf/delft3dfm:2026.01

## Run your delft3dfm model
Mount your model directory into `/work` and execute the DIMR run script:

podman run --rm -it -v .:/work -w /work -e OMP_NUM_THREADS=4  delft3dfm:2026.01 run_dimr.sh dimr_config.xml
