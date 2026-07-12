#!/usr/bin/env bash
# =============================================================================
# Delft3D FM — DIMRset_2.31.13 image build driver
# =============================================================================
# Builds the official Deltares Linux container chain locally (their Harbor
# registry at containers.deltares.nl is NOT anonymously pullable — verified),
# then layers an operations-friendly runtime image on top:
#
#   1. buildtools        (AlmaLinux 8 + Intel oneAPI 2024.2: icx/icpx/ifx,
#                         MKL 2024.2.2, Intel MPI 2021.13.1, modern CMake)
#      <- ci/dockerfiles/linux/buildtools.Dockerfile
#   2. third-party-libs  (METIS, PETSc 3.24.5, HDF5/NetCDF, xerces-c,
#                         Boost 1.90, ESMF 8.9.1 built ESMF_COMM=mpiuni)
#      <- ci/dockerfiles/linux/third-party-libs.Dockerfile
#   3. delft3d           (official build: run_conan.py external + build.py,
#                         self-contained install tree in /delft3d)
#      <- doc/delft3d.Dockerfile
#   4. delft3dfm         (our layer: Intel MPI launcher, run_parallel.sh,
#                         single-node env defaults, build-time smoke tests)
#      <- Dockerfile.runtime (next to this script)
#
# Requirements:
#   - docker with BuildKit (or podman >= 4); the upstream Dockerfiles use
#     RUN <<EOF heredocs and --mount=type=cache, which require BuildKit.
#   - ~25 GB free disk for images + build cache; first build takes hours
#     (every third-party dependency is compiled from source).
#
# Usage:
#   ./build-delft3dfm.sh                 # full chain, defaults below
#   CONFIGURATION=all ./build-delft3dfm.sh
#   ENGINE=podman ./build-delft3dfm.sh
#   START_AT=3 ./build-delft3dfm.sh      # resume at step 3 (delft3d)
# =============================================================================
set -euo pipefail

# ---- Configuration (override via environment) -------------------------------
D3D_REPO="${D3D_REPO:-https://github.com/Deltares/Delft3D.git}"
D3D_REF="${D3D_REF:-DIMRset_2.31.13}"
D3D_COMMIT="${D3D_COMMIT:-5b370af44b44a89a1ebd560620a4c35139c44cec}"  # pin for reproducibility
SRC_DIR="${SRC_DIR:-$PWD/delft3d-src}"

# Latest officially supported Intel toolchain for this tag. The
# buildtools.Dockerfile also contains 2025/2026 branches, but the Conan
# profile (delft3d_alma8_intel_2024) hardcodes 2024.2 and the CI README
# warns PETSc is not yet compatible with oneAPI 2025's Fortran interface.
# Treat anything newer than 2024 as experimental (see README).
INTEL_ONEAPI_VERSION="${INTEL_ONEAPI_VERSION:-2024}"
INTEL_FORTRAN_COMPILER="${INTEL_FORTRAN_COMPILER:-ifx}"   # ifort is deprecated
BUILD_TYPE="${BUILD_TYPE:-Release}"                       # Release | Debug
CONFIGURATION="${CONFIGURATION:-fm-suite}"                # fm-suite = dimr+dflowfm+dwaves+swan+dwaq+...; 'all' adds Delft3D 4

# Intel MPI runtime version matching what buildtools installs for this oneAPI
# version (see the case-statement in buildtools.Dockerfile).
INTEL_MPI_RUNTIME_VERSION="${INTEL_MPI_RUNTIME_VERSION:-2021.13.1}"

ENGINE="${ENGINE:-docker}"                                # docker | podman
START_AT="${START_AT:-1}"

# Image names/tags. Tag conventions matter: third-party-libs MUST be tagged
# oneapi-<ver>-<fc>-<BuildType> because doc/delft3d.Dockerfile computes
# BASE_TAG exactly that way, and buildtools MUST be tagged oneapi-<ver>.
BT_IMG="localhost/delft3d-buildtools:oneapi-${INTEL_ONEAPI_VERSION}"
TPL_TAG="oneapi-${INTEL_ONEAPI_VERSION}-${INTEL_FORTRAN_COMPILER}-${BUILD_TYPE}"
TPL_IMG="localhost/delft3d-third-party-libs:${TPL_TAG}"
D3D_IMG="localhost/delft3d:${D3D_REF}-${TPL_TAG}"
FINAL_IMG="${FINAL_IMG:-delft3dfm:2.31.13}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# BuildKit is mandatory for the upstream Dockerfiles.
export DOCKER_BUILDKIT=1

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---- Step 0: fetch pinned source --------------------------------------------
if [ ! -d "$SRC_DIR/.git" ]; then
  log "Cloning ${D3D_REPO} @ ${D3D_REF} into ${SRC_DIR}"
  git clone --branch "$D3D_REF" --depth 1 "$D3D_REPO" "$SRC_DIR"
fi
pushd "$SRC_DIR" >/dev/null
ACTUAL_COMMIT="$(git rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$D3D_COMMIT" ]; then
  echo "WARNING: checked-out commit $ACTUAL_COMMIT != pinned $D3D_COMMIT" >&2
  echo "         (tag may have moved, or SRC_DIR is stale — verify before proceeding)" >&2
fi
git log -1 --oneline

# ---- Upstream patch: unconditional msvcr100.dll copy breaks Linux test build ----
# src/engines_gpl/dflowfm/packages/dflowfm_kernel/test/CMakeLists.txt copies a
# Windows-only DLL (third_party_open/pthreads/bin/x64/msvcr100.dll) as a
# PRE_BUILD step for test_dflowfm_kernel_gtest with no if(WIN32) guard (unlike
# the CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS loop just above it, which is an empty
# no-op on Linux). This fails every Linux build of fm-suite/all. Patch it here
# so the fix travels with the driver rather than requiring a manual repo edit.
PATCHED_CMAKE="src/engines_gpl/dflowfm/packages/dflowfm_kernel/test/CMakeLists.txt"
if grep -qE '^\s*if\(WIN32\)\s*$' <(grep -B6 -A2 'msvcr100' "$PATCHED_CMAKE" 2>/dev/null || true); then
  log "msvcr100.dll guard already present — skipping patch"
else
  log "Patching upstream Linux-build bug: guarding msvcr100.dll copy with if(WIN32)"
  python3 - "$PATCHED_CMAKE" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
old = '''# Copy pthreads runtime dependency
add_custom_command(TARGET ${test_target} PRE_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${checkout_src_root}/third_party_open/pthreads/bin/x64/msvcr100.dll"
        "$<TARGET_FILE_DIR:${test_target}>"
)'''
new = '''# Copy pthreads runtime dependency (Windows only: msvcr100.dll does not
# exist on Linux; upstream is missing this guard as of DIMRset_2.31.13)
if(WIN32)
    add_custom_command(TARGET ${test_target} PRE_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${checkout_src_root}/third_party_open/pthreads/bin/x64/msvcr100.dll"
            "$<TARGET_FILE_DIR:${test_target}>"
    )
endif(WIN32)'''
if old not in text:
    sys.exit("PATCH FAILED: expected block not found verbatim in " + path +
              " — upstream file may have changed since DIMRset_2.31.13; inspect and patch manually.")
open(path, "w").write(text.replace(old, new))
print("Patched:", path)
PYEOF
fi

# ---- Step 1: buildtools ------------------------------------------------------
# BASE_IMAGE_URL default points at Deltares' private registry; use the public
# AlmaLinux 8 image from Docker Hub instead ("Red Hat line", as officially used).
if [ "$START_AT" -le 1 ]; then
  log "[1/4] buildtools -> ${BT_IMG}   (oneAPI ${INTEL_ONEAPI_VERSION}, ~10 GB)"
  "$ENGINE" build . \
      -f ci/dockerfiles/linux/buildtools.Dockerfile \
      -t "$BT_IMG" \
      --build-arg BASE_IMAGE_URL=docker.io/almalinux:8 \
      --build-arg INTEL_ONEAPI_VERSION="$INTEL_ONEAPI_VERSION"
fi

# ---- Step 2: third-party-libs ------------------------------------------------
# DEBUG=0 corresponds to Release third-party builds. ESMF here is built with
# ESMF_COMM=mpiuni (no MPI) — the key difference from the old bespoke image,
# and the likely fix for the PMPI_Alltoallw crash/hang in ESMF_RegridWeightGen.
if [ "$START_AT" -le 2 ]; then
  DEBUG_FLAG=0
  [ "$BUILD_TYPE" = "Debug" ] && DEBUG_FLAG=1
  log "[2/4] third-party-libs -> ${TPL_IMG}   (~13 GB, longest step)"
  "$ENGINE" build . \
      -f ci/dockerfiles/linux/third-party-libs.Dockerfile \
      -t "$TPL_IMG" \
      --build-arg BUILDTOOLS_IMAGE_URL=localhost/delft3d-buildtools \
      --build-arg BUILDTOOLS_IMAGE_TAG="oneapi-${INTEL_ONEAPI_VERSION}" \
      --build-arg INTEL_ONEAPI_VERSION="$INTEL_ONEAPI_VERSION" \
      --build-arg INTEL_FORTRAN_COMPILER="$INTEL_FORTRAN_COMPILER" \
      --build-arg DEBUG="$DEBUG_FLAG"
fi

# ---- Step 3: official delft3d image ------------------------------------------
# Runs `run_conan.py initialize external --ci` then
# `build.py --config <CONFIGURATION> --build --build-dependencies` inside the
# third-party-libs container, installs to /delft3d, and copies that tree onto
# a bare AlmaLinux 8 final stage. Conan deps (zlib/expat/proj/gdal/netcdf/...)
# are built from the in-repo recipes — no Nexus credentials required.
if [ "$START_AT" -le 3 ]; then
  log "[3/4] delft3d (official) -> ${D3D_IMG}   (config=${CONFIGURATION}, ${BUILD_TYPE})"
  "$ENGINE" build . \
      -f doc/delft3d.Dockerfile \
      -t "$D3D_IMG" \
      --build-arg THIRDPARTYLIBS_IMAGE_URL=localhost/delft3d-third-party-libs \
      --build-arg BASE_IMAGE_URL=docker.io/almalinux:8 \
      --build-arg INTEL_ONEAPI_VERSION="$INTEL_ONEAPI_VERSION" \
      --build-arg INTEL_FORTRAN_COMPILER="$INTEL_FORTRAN_COMPILER" \
      --build-arg BUILD_TYPE="$BUILD_TYPE" \
      --build-arg CONFIGURATION="$CONFIGURATION"
fi
popd >/dev/null

# ---- Step 4: runtime extension ------------------------------------------------
# Adds the Intel MPI launcher (mpiexec.hydra is NOT bundled by the official
# install step — copy_libs.sh only copies shared libraries), run_parallel.sh,
# single-node env defaults, and hard build-time smoke tests (including the
# ESMF mpiuni verification and the non-empty run_parallel.sh gate).
if [ "$START_AT" -le 4 ]; then
  log "[4/4] runtime extension -> ${FINAL_IMG}"
  "$ENGINE" build "$SCRIPT_DIR" \
      -f "$SCRIPT_DIR/Dockerfile.runtime" \
      -t "$FINAL_IMG" \
      --build-arg BASE_IMAGE="$D3D_IMG" \
      --build-arg INTEL_MPI_RUNTIME_VERSION="$INTEL_MPI_RUNTIME_VERSION"
fi

log "Done. Final image: ${FINAL_IMG}"
cat <<EOF

Acceptance test (== the bug report's own verification section):

  cd ${SRC_DIR}/examples/dflowfm/09_dflowfm_parallel_dwaves
  ${ENGINE} run --rm --shm-size=4g -v "\$PWD/..":/work -w /work/09_dflowfm_parallel_dwaves \\
      ${FINAL_IMG} ./run_example.sh

Confirm:
  - ESMF_RegridWeightGen_in_Delft3D-WAVE.sh completes and the
    TMP_ESMF_RegridWeightGen_*_weights_*.nc file is created
    (check esmf_sh.log in the wave working directory on failure)
  - both dflowfm and wave enter the timestepping loop

Then a custom coupled model:
  ${ENGINE} run --rm --shm-size=4g -v \$PWD:/work ${FINAL_IMG} \\
      run_parallel.sh -n 4 -d dimr_config.xml
EOF
