# `delft3dfm:2026.02` — Docker command cheat sheet

Every command written out in full. No aliases.

Standard flags used throughout:
`--rm` remove container after run · `--shm-size=4g` shared memory for MPI ·
`--user $(id -u):$(id -g)` write output as you, not root ·
`-v "$PWD":/work -w /work` mount current folder and start in it

---

## Image inspection

```bash
# Version and compiled-in capabilities
docker run --rm delft3dfm:2026.02 dflowfm --version

# List everything installed
docker run --rm delft3dfm:2026.02 ls /delft3d/bin

# Check classic Delft3D 4 is present
docker run --rm delft3dfm:2026.02 ls /delft3d/bin | grep -E "d_hydro|dflow2d3d"

# List available run scripts only
docker run --rm delft3dfm:2026.02 ls /delft3d/bin | grep "^run_"

# How many cores does the container see
docker run --rm delft3dfm:2026.02 nproc

# MPI runtime version
docker run --rm delft3dfm:2026.02 mpirun --version

# Help for any launcher
docker run --rm delft3dfm:2026.02 run_dimr.sh --help
docker run --rm delft3dfm:2026.02 run_dflow2d3d.sh --help
docker run --rm delft3dfm:2026.02 run_delwaq.sh --help

# Image size and layers
docker images delft3dfm:2026.02
docker history delft3dfm:2026.02
```

---

## Interactive shell

```bash
# Shell inside the container, current folder mounted
docker run --rm -it --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02

# Shell as root (for installing extra packages temporarily)
docker run --rm -it --shm-size=4g -v "$PWD":/work -w /work delft3dfm:2026.02

# One-off command without a shell
docker run --rm -v "$PWD":/work -w /work delft3dfm:2026.02 ls -la
```

---

## DIMR (all coupled runs, and most single-engine runs)

```bash
# Sequential, default config name (dimr_config.xml)
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh

# Sequential, named config file
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimrConfig.xml

# Parallel: 4 ranks (mesh must already be partitioned)
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -c 4 -m dimr_config.xml

# Full logging (0 = everything)
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml -d 0

# Silent (6 = silent)
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml -d 6

# Run your own script immediately after DIMR finishes
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml --cleanup postprocess.sh

# Convenience wrapper: partition + run in one go
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_parallel.sh -n 4 -d dimr_config.xml
```

---

## Delft3D FM — D-Flow FM

```bash
# Sequential, helper script
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflowfm.sh model.mdu

# Sequential, engine called directly
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    dflowfm --nodisplay --autostartstop model.mdu

# Partition mesh into 4 subdomains (run inside the .mdu folder)
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflowfm.sh --partition:ndomains=4:icgsolver=6 model.mdu

# Parallel via wrapper, 4 MPI ranks
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_parallel.sh -n 4 model.mdu

# Hybrid: 4 ranks x 2 OpenMP threads
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_parallel.sh -n 4 -t 2 model.mdu

# Parallel by hand with mpirun
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    mpirun -np 4 dflowfm --nodisplay --autostartstop model.mdu
```

---

## Delft3D FM — waves, water quality, tools

```bash
# Standalone D-Waves (SWAN)
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dwaves.sh model.mdw

# DELWAQ water quality
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_delwaq.sh model.inp

# DELWAQ: validate input only, do not compute
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_delwaq.sh model.inp -validation_mode

# DELWAQ: all substances as inert tracers
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_delwaq.sh model.inp -np

# DELWAQ with BLOOM algae module
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_delwaq.sh model.inp -eco

# DELWAQ with custom process library
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_delwaq.sh model.inp -p /work/my_proc_def

# FM output post-processing
docker run --rm --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dfmoutput.sh --help

# FM volume tool
docker run --rm --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dfm_volume_tool.sh --help
```

---

## Delft3D 4 classic

```bash
# Basic run, default config_d_hydro.xml
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflow2d3d.sh

# Basic run, named config file
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflow2d3d.sh my_config.xml

# Parallel, 4 partitions (count is positional, not a flag)
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflow2d3d_parallel.sh 4

# Parallel with named config
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflow2d3d_parallel.sh 4 my_config.xml

# Flow + waves
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflow2d3d_dwaves.sh

# Flow + waves, parallel
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflow2d3d_parallel_dwaves.sh 4

# Flow + real-time control
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflow2d3d_rtc.sh

# Fluid mud
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflow2d3d_fluidmud.sh

# Classic driven through DIMR (config must declare a flow2d3d component)
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml

# Particle tracking
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_delpar.sh model.inp

# Morphological merging
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_mormerge.sh --help
```

---

## Shared tools

```bash
# Aggregate hydrodynamic files
docker run --rm --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 run_agrhyd.sh --help

# Merge WAQ hydrodynamic files
docker run --rm --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 run_waqmerge.sh --help

# Couple domain-decomposition WAQ files
docker run --rm --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 run_ddcouple.sh --help

# Convert WAQ map output to NetCDF
docker run --rm --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 run_maptonetcdf.sh --help

# Export / import WAQ process library
docker run --rm --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 run_waqpb_export.sh --help
docker run --rm --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 run_waqpb_import.sh --help

# Extract bathymetry from classic trim- output
docker run --rm --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 run_trim2dep.sh --help
```

---

## Environment variables

```bash
# Force single-threaded
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -e OMP_NUM_THREADS=1 \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml

# 4 OpenMP threads
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -e OMP_NUM_THREADS=4 \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflowfm.sh model.mdu

# Verbose MPI startup diagnostics
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -e I_MPI_DEBUG=5 \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -c 4 -m dimr_config.xml

# Override MPI fabric
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -e I_MPI_FABRICS=shm \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_parallel.sh -n 4 model.mdu

# Thread pinning
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -e OMP_PLACES=cores -e OMP_PROC_BIND=close \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_parallel.sh -n 2 -t 4 model.mdu

# Several at once
docker run --rm --shm-size=8g --user $(id -u):$(id -g) \
    -e OMP_NUM_THREADS=2 -e I_MPI_DEBUG=5 -e I_MPI_FABRICS=shm \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_parallel.sh -n 4 -t 2 model.mdu

# From a file
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    --env-file ./model.env \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml
```

---

## Resource limits

```bash
# Limit to 4 CPUs
docker run --rm --shm-size=4g --cpus=4 --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_parallel.sh -n 4 model.mdu

# Limit memory
docker run --rm --shm-size=4g --memory=8g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml

# Pin to specific physical cores
docker run --rm --shm-size=4g --cpuset-cpus="0-3" --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_parallel.sh -n 4 model.mdu

# Larger shared memory for big parallel runs
docker run --rm --shm-size=16g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_parallel.sh -n 16 model.mdu

# Lower scheduling priority
docker run --rm --shm-size=4g --cpu-shares=512 --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml
```

---

## Mounting variations

```bash
# Current folder
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 run_dimr.sh

# Absolute path
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v /home/rauf/models/estuary:/work -w /work delft3dfm:2026.02 run_dimr.sh

# Mount parent, run in a subfolder (needed when scripts reach into siblings)
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD/..":/work -w /work/09_dflowfm_parallel_dwaves delft3dfm:2026.02 \
    ./run_example.sh

# Two mounts: model in one place, output elsewhere
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD/model":/work -v /data/results:/output -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml

# Read-only input, writable output
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD/input":/input:ro -v "$PWD/run":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml

# --mount syntax (equivalent to -v)
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    --mount "type=bind,source=$PWD,target=/work" -w /work delft3dfm:2026.02 \
    run_dimr.sh
```

---

## Running in background / logging

```bash
# Detached, named container
docker run -d --name estuary_run --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml

# Follow its output
docker logs -f estuary_run

# Check status / stop / remove
docker ps -a --filter name=estuary_run
docker stop estuary_run
docker rm estuary_run

# Foreground but tee console output to a file
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml 2>&1 | tee run.log

# Auto-restart on failure
docker run -d --restart=on-failure:3 --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml
```

---

## Official examples

```bash
# Get them once
git clone --depth 1 --branch DIMRset_2026.02 https://github.com/Deltares/Delft3D.git

# Simplest FM example
cd Delft3D/examples/dflowfm/01_dflowfm_sequential
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dimr.sh -m dimr_config.xml

# Coupled FM + waves, parallel (mount parent folder)
cd Delft3D/examples/dflowfm/09_dflowfm_parallel_dwaves
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD/..":/work -w /work/09_dflowfm_parallel_dwaves delft3dfm:2026.02 \
    ./run_example.sh

# Classic Delft3D 4 example
cd Delft3D/examples/delft3d4/01_standard
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 \
    run_dflow2d3d.sh
```

---

## Image management

```bash
# Tag for Docker Hub
docker tag delft3dfm:2026.02 adnanrauf/delft3dfm:2026.02

# Push
docker login
docker push adnanrauf/delft3dfm:2026.02

# Pull on another machine
docker pull adnanrauf/delft3dfm:2026.02

# Save to a file / load elsewhere (no registry needed)
docker save delft3dfm:2026.02 | gzip > delft3dfm-2026.02.tar.gz
gunzip -c delft3dfm-2026.02.tar.gz | docker load

# Disk usage and cleanup
docker system df -v
docker image prune -a
docker builder prune -a
```

---

## Quick fixes

```bash
# Output owned by root because --user was omitted
sudo chown -R $USER:$USER .

# Check what the container sees of your folder
docker run --rm -v "$PWD":/work -w /work delft3dfm:2026.02 ls -la

# Confirm a file is visible inside the container
docker run --rm -v "$PWD":/work -w /work delft3dfm:2026.02 cat dimr_config.xml

# Test MPI startup on its own
docker run --rm --shm-size=4g delft3dfm:2026.02 mpirun -np 2 hostname
```
