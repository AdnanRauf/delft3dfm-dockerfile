#!/usr/bin/env bash
# =============================================================================
# Delft3D FM — DIMRset_2026.02 image build driver
# =============================================================================
# Builds the official Deltares Linux container chain locally (their Harbor
# registry at containers.deltares.nl is NOT anonymously pullable — verified),
# then layers an operations-friendly runtime image on top:
#
#   1. buildtools        (AlmaLinux 8 + Intel oneAPI 2024.2: icx/icpx/ifx,
#                         MKL 2024.2.2, Intel MPI 2021.13.1, modern CMake)
#      <- ci/dockerfiles/linux/buildtools.Dockerfile
#   2. third-party-libs  (METIS, PETSc, HDF5/NetCDF, xerces-c, Boost,
#                         ESMF built ESMF_COMM=mpiuni — exact versions are
#                         whatever DIMRset_2026.02's third-party-libs.Dockerfile
#                         pins; for 2.31.13 these were PETSc 3.24.5 / Boost 1.90
#                         / ESMF 8.9.1)
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
D3D_REF="${D3D_REF:-DIMRset_2026.02}"
D3D_COMMIT="${D3D_COMMIT:-5a4649830b1e5072caf019fb4850bbdefd9ad431}"  # pin for reproducibility (DIMRset_2026.02, 28 Apr 2026)
SRC_DIR="${SRC_DIR:-$PWD/delft3d-src}"

# Intel toolchain version. NOTE: the 2024 default below was the officially
# supported toolchain for the OLD DIMRset_2.31.13 tag (Conan profile
# delft3d_alma8_intel_2024 hardcoded 2024.2). This driver now targets
# DIMRset_2026.02, which may ship a newer default profile / support a newer
# oneAPI. Before trusting the default, check the 2026.02 tree:
#   - ci/dockerfiles/linux/buildtools.Dockerfile   (which oneAPI branches exist)
#   - the Conan profile(s) under build_conan_profiles/ or equivalent
#   - the CI README for any oneAPI 2025/2026 compatibility notes
# Override with INTEL_ONEAPI_VERSION / INTEL_MPI_RUNTIME_VERSION if 2026.02
# has moved on from 2024.2 + Intel MPI 2021.13.1.
INTEL_ONEAPI_VERSION="${INTEL_ONEAPI_VERSION:-2024}"
INTEL_FORTRAN_COMPILER="${INTEL_FORTRAN_COMPILER:-ifx}"   # ifort is deprecated
BUILD_TYPE="${BUILD_TYPE:-Release}"                       # Release | Debug
# CONFIGURATION=all builds the FM suite AND the classic Delft3D 4 engines.
# Per src/cmake/configurations/testbench/all_configuration.cmake, 'all' pulls in:
#   dimr, dflowfm, dwaq, dwaves, drr, fbc, dsle, tools   (the FM suite), plus
#   flow2d3d, d_hydro, rtc, tools_gpl, mormerge and the culvert/traform plugins
#   (the classic Delft3D 4 side).
# Alternatives: 'fm-suite' (FM only, no Delft3D 4 — needs the build.sh patch
# below), or a single component such as dflowfm / dimr / dwaves / swan.
CONFIGURATION="${CONFIGURATION:-all}"

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
FINAL_IMG="${FINAL_IMG:-delft3dfm:2026.02}"

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
# no-op on Linux). This failed every Linux build of fm-suite/all on old tags
# (verified against DIMRset_2.31.13). As of DIMRset_2026.02 upstream refactored
# this file: the entire copy_dflowfm_test_dependencies() function body (PETSc
# DLL, MKL DLL, msvcr100.dll, etc.) is now wrapped in a single if(WIN32) block,
# so the bug no longer exists and there is nothing left to patch — the msvcr100
# string doesn't appear in this file at all any more (only in unrelated Windows
# binary-delivery JSON manifests under ci/python/ci_tools/). Detect either
# outcome (guard present, or string absent entirely) and skip; only fall
# through to patching if the old unguarded pattern is still there verbatim.
PATCHED_CMAKE="src/engines_gpl/dflowfm/packages/dflowfm_kernel/test/CMakeLists.txt"
if ! grep -q "msvcr100" "$PATCHED_CMAKE" 2>/dev/null; then
  log "msvcr100.dll copy not present in $PATCHED_CMAKE (fixed/refactored upstream as of DIMRset_2026.02) — skipping patch"
elif grep -qE '^\s*if\(WIN32\)\s*$' <(grep -B6 -A2 'msvcr100' "$PATCHED_CMAKE" 2>/dev/null || true); then
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
# exist on Linux; upstream was missing this guard as of DIMRset_2.31.13 —
# verify whether DIMRset_2026.02 still needs it; if fixed upstream the
# grep-guard above self-skips)
if(WIN32)
    add_custom_command(TARGET ${test_target} PRE_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${checkout_src_root}/third_party_open/pthreads/bin/x64/msvcr100.dll"
            "$<TARGET_FILE_DIR:${test_target}>"
    )
endif(WIN32)'''
if old not in text:
    sys.exit("PATCH FAILED: expected block not found verbatim in " + path +
              " — upstream file may differ in DIMRset_2026.02 (it may already be "
              "fixed, in which case remove this patch step, or the block may have "
              "changed shape); inspect and patch manually.")
open(path, "w").write(text.replace(old, new))
print("Patched:", path)
PYEOF
fi

# ---- Upstream patch: BuildKit frontend pinned to Deltares' private registry ----
# buildtools.Dockerfile and third-party-libs.Dockerfile both start with
#   # syntax=containers.deltares.nl/docker-proxy/docker/dockerfile:1.4
# That registry is NOT anonymously pullable, and a `# syntax=` directive is
# resolved by BuildKit before anything else — it cannot be overridden with
# --build-arg the way the BASE_IMAGE_URL / *_IMAGE_URL ARGs can. Without this
# rewrite the build dies immediately with a TLS handshake timeout against
# containers.deltares.nl. Point it at the identical frontend version on Docker
# Hub (docker/dockerfile:1.4) instead. Idempotent: re-running is a no-op.
SYNTAX_FILES=(
  "ci/dockerfiles/linux/buildtools.Dockerfile"
  "ci/dockerfiles/linux/third-party-libs.Dockerfile"
)
for f in "${SYNTAX_FILES[@]}"; do
  [ -f "$f" ] || { echo "WARNING: $f not found — skipping syntax rewrite" >&2; continue; }
  if head -1 "$f" | grep -q '^# syntax=containers\.deltares\.nl/docker-proxy/'; then
    log "Rewriting private-registry BuildKit frontend -> Docker Hub in $f"
    sed -i '1s|^# syntax=containers\.deltares\.nl/docker-proxy/|# syntax=|' "$f"
    head -1 "$f"
  else
    log "BuildKit frontend already public in $f — skipping"
  fi
done

# ---- Upstream patch: dnf hard-fails when the Intel oneAPI repo is unreachable ----
# buildtools.Dockerfile writes /etc/yum.repos.d/oneAPI.repo (baseurl
# https://yum.repos.intel.com/oneapi, enabled=1) and that repo file is inherited
# by every stage in third-party-libs.Dockerfile. dnf refreshes metadata for ALL
# enabled repos and aborts the whole transaction if any single one is
# unreachable — so a transient outage or slow link to yum.repos.intel.com kills
# the build with:
#     Curl error (7): Couldn't connect to server ... /oneapi/repodata/repomd.xml
#     Error: Failed to download metadata for repo 'oneAPI'
# even though none of the packages involved come from Intel. There are exactly
# three dnf calls in third-party-libs.Dockerfile (gtest-devel, libxml2-devel,
# patch) and all three resolve from AlmaLinux BaseOS/AppStream/PowerTools/EPEL;
# the Intel toolchain is already baked into the buildtools base image.
#
# Mark the oneAPI repo skip_if_unavailable for those calls and give dnf real
# retry/timeout behaviour. skip_if_unavailable is preferred over --disablerepo:
# if Intel IS reachable the repo still works normally, it just stops being fatal.
# Patching the three call sites (rather than the shared `base` stage) keeps the
# BuildKit cache for already-built stages intact.
TPL_DOCKERFILE="ci/dockerfiles/linux/third-party-libs.Dockerfile"
if [ -f "$TPL_DOCKERFILE" ]; then
  python3 - "$TPL_DOCKERFILE" <<'PYEOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
if "oneAPI.skip_if_unavailable" in text:
    print("dnf resilience already applied — skipping")
    sys.exit(0)
FLAGS = ("--setopt=oneAPI.skip_if_unavailable=1 "
         "--setopt=retries=10 --setopt=timeout=60 --setopt=minrate=0")
new_text, n = re.subn(r'(?m)^dnf(?=\s)', 'dnf ' + FLAGS, text)
if n == 0:
    print("WARNING: no top-level 'dnf' invocations found in %s — "
          "upstream may have changed; skipping (build may still fail if "
          "yum.repos.intel.com is unreachable)" % path, file=sys.stderr)
    sys.exit(0)
open(path, "w").write(new_text)
print("Patched %d dnf invocation(s) in %s for oneAPI-repo resilience" % (n, path))
PYEOF
else
  echo "WARNING: $TPL_DOCKERFILE not found — skipping dnf resilience patch" >&2
fi

# ---- Upstream patch: build.sh rejects the 'fm-suite' config it documents -------
# build.sh's own --help advertises "fm-suite" and "d3d4-suite" as valid <CONFIG>
# values, and src/cmake/CMakeLists.txt genuinely supports them:
#     set(fm-suite_configuration "FM-SUITE")
#     set(d3d4-suite_configuration "D3D4-SUITE")
# and both appear in the accepted CONFIGURATION_TYPE list. But the argument
# parser in build.sh has no matching case branch, so it dies with
#     ERROR: Unknown command line argument fm-suite
# before CMake is ever invoked. The docs and the CMake backend agree; only the
# shell parser was left behind. Add the two missing branches.
#
# FM-SUITE (src/cmake/configurations/suites/fm_configuration.cmake) pulls in
# dimr + dflowfm + dwaves + dwaq + drr + fbc + dsle + tools, i.e. the FM suite
# without the classic Delft3D 4 engines — which is what CONFIGURATION=fm-suite
# is meant to select here. Use CONFIGURATION=all if you also want flow2d3d.
if grep -qE '^\s*fm-suite\)' build.sh 2>/dev/null; then
  log "build.sh already accepts fm-suite — skipping"
else
  log "Patching build.sh to accept the documented 'fm-suite'/'d3d4-suite' configs"
  python3 - build.sh <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
old = '''    all)
    config="all"
    shift
    ;;
'''
new = '''    fm-suite)
    config="fm-suite"
    shift
    ;;
    d3d4-suite)
    config="d3d4-suite"
    shift
    ;;
    all)
    config="all"
    shift
    ;;
'''
if old not in text:
    sys.exit("PATCH FAILED: could not find the 'all)' case branch in " + path +
             " — inspect the argument parser and add fm-suite/d3d4-suite manually, "
             "or rerun with CONFIGURATION=all which needs no patch.")
open(path, "w").write(text.replace(old, new, 1))
print("Patched:", path, "(added fm-suite and d3d4-suite case branches)")
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
      --build-arg TPL_IMAGE="$TPL_IMG" \
      --build-arg CONFIGURATION="$CONFIGURATION" \
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
