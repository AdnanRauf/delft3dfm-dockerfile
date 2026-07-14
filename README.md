# Delft3D FM container — DIMRset_2.31.13 (official pipeline + ops layer)

`DIMRset_2.31.13` moved to a Conan 2 + `build.py` build system (the old
`build.sh` no longer exists), requires CMake >= 3.30, contains a C++23 tool,
and is officially built on **AlmaLinux 8 with Intel oneAPI 2024.2
(icx / icpx / ifx) and Intel MPI 2021.13.1** via the Conan profile
`delft3d_alma8_intel_2024`. This setup builds that official chain locally
and adds a thin operations layer on top.

## Files

| File | Purpose |
|---|---|
| `build-delft3dfm.sh` | Driver: clones the pinned tag and builds all four images in order. |
| `Dockerfile.runtime` | Ops layer on the official image: Intel MPI launcher, `run_parallel.sh`, single-node env defaults, build-time smoke gates. |

## Quick start

```bash
chmod +x build-delft3dfm.sh
./build-delft3dfm.sh                      # docker + BuildKit; ENGINE=podman also works
```

Defaults: `CONFIGURATION=fm-suite` (dimr, dflowfm, dwaq, dwaves/SWAN, drr,
fbc, tools — everything needed for FM + D-Waves coupled runs; use
`CONFIGURATION=all` to add Delft3D 4), `BUILD_TYPE=Release`,
`INTEL_ONEAPI_VERSION=2024`, `INTEL_FORTRAN_COMPILER=ifx`.

Expect **~25 GB of images** (buildtools ~10 GB, third-party-libs ~13 GB) and a
first build measured in **hours** — every third-party dependency (PETSc
3.24.5, HDF5/NetCDF, Boost 1.90, ESMF 8.9.1, plus all Conan-managed packages)
is compiled from source, because the Deltares Harbor registry
(`containers.deltares.nl`) does not allow anonymous pulls. Rebuilds are fast:
the upstream Dockerfiles use BuildKit cache mounts for sources, the build
tree, and the Conan cache (`/root/.conan2`). `START_AT=<1..4>` resumes at a
given step.

## Newer Intel compilers (experimental)

oneAPI **2024.2 + ifx is the latest supported combination** for this tag.
The `buildtools.Dockerfile` already contains install branches for oneAPI
2025 (2025.3.2, MPI 2021.17.2) and 2026 (2026.0, MPI 2021.18), but:

1. The docs declare only 2023/2024 valid, and the CI README states the PETSc
   Fortran usage is not yet compatible with oneAPI 2025 (migration to the
   new PETSc Fortran API is in progress upstream — PETSc 3.24.5 in-tree).
2. The Conan profile hardcodes `compiler.version=2024.2` and the compiler
   paths `/opt/intel/oneapi/compiler/2024.2/bin/{icx,icpx,ifx}`.

To experiment: build buildtools with `INTEL_ONEAPI_VERSION=2026`, fork
`conan/config/profiles/delft3d_alma8_intel_2024` to a `..._2026` variant
(update `compiler.version` and the three executable paths to
`/opt/intel/oneapi/compiler/2026.0/bin/...`), point `run_conan.py`/`build.py`
at it, and set `INTEL_MPI_RUNTIME_VERSION=2021.18` for step 4. Expect
PETSc-related Fortran breakage first. Keep 2024.2 as the production image
and re-sync when Deltares blesses a newer toolchain in a future tag.

## Troubleshooting

- **`RUN <<EOF` parse errors**: BuildKit is required (`DOCKER_BUILDKIT=1`,
  set by the driver) or podman >= 4.
- **MPI launcher gate fails on lib paths**: Intel MPI has shuffled its
  layout across releases (`lib/release` vs `lib`, `libfabric/lib` vs
  `opt/mpi/libfabric/lib`). Both variants are on `LD_LIBRARY_PATH` /
  `FI_PROVIDER_PATH`; if a future MPI version moves again, gate 2 fails at
  build time — inspect `ls /opt/intel/oneapi/mpi/stable` and adjust.
- **OpenMP gate (5) fails**: the upstream half-fix applies `${openmp_flag}`
  unconditionally in `dflowfm_kernel` but still WIN32-only in
  `dflowfm-cli_exe/CMakeLists.txt`. If the gate trips, patch the cli_exe to
  apply the flag (compile + link) under UNIX and rebuild step 3.
- **Disk pressure**: `docker builder prune` reclaims BuildKit cache;
  removing it forces full third-party rebuilds next time.
