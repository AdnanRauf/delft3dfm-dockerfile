# =============================================================================
# Delft3D FM container — DIMRset_2026.01
# =============================================================================
# Based on Intel's official oneAPI HPC Kit image (oneAPI 2021.6 era):
#   - Classic compilers: icc, icpc, ifort
#   - Intel MPI 2021.6 with mpiicc, mpiicpc, mpiifort wrappers
#   - MKL, TBB, OpenMP runtimes
#   - All env vars (PATH, LD_LIBRARY_PATH, MKLROOT, CPATH, etc.) pre-set —
#     no setvars.sh needed.
#
# Strategy:
#   - Classic Intel compilers (icc/icpc/ifort) — the image only has these,
#     not the LLVM-based icx/icpx/ifx that came in oneAPI 2024+.
#     This is fine: classic compilers are battle-tested with Delft3D's
#     legacy Fortran code.
#   - HDF5 1.14.4-3, NetCDF-C 4.9.2, NetCDF-Fortran 4.6.1 (parallel + Fortran)
#   - METIS 5.1.0, PETSc 3.22.4 (with MKL Pardiso)
#   - Eigen 3.4.0, Boost 1.81.0, preCICE 3.3.0, ESMF 8.9.1
#   - Modern CMake 3.30.5 (Ubuntu 20.04 ships 3.16; we need 3.30+)
#   - SWAN source-copy trick from veethahavya-CU-cz/delft3dfm_dockerized
#   - Patches dflowfm_kernel/CMakeLists.txt and dflowfm-cli_exe/CMakeLists.txt:
#     upstream only applies the Intel openmp_flag (-qopenmp) to these two
#     targets inside "if(WIN32)" blocks, never in "if(UNIX)" -- so on Linux
#     dflowfm silently builds WITHOUT OpenMP (confirmed via `dflowfm --version`
#     reporting "OpenMP : no") regardless of any -fopenmp env vars passed to
#     build.sh. We patch both CMakeLists.txt to apply openmp_flag on UNIX too,
#     matching how swan_omp/CMakeLists.txt already does it correctly.
#
# Build:
#   docker build -t delft3dfm:2026.01 -f Dockerfile .
#
# Run (hybrid MPI + OpenMP, single machine / single container):
#   The runtime stage ships the Intel MPI launcher + libs and libiomp5, so the
#   binaries can run multi-domain (MPI) and/or multi-threaded (OpenMP). Give the
#   container enough shared memory for the shm fabric:
#
#     # MPI on all cores:
#     podman run --rm --shm-size=4g -v $PWD:/work delft3dfm:2026.01 \
#         run_parallel.sh model.mdu
#
#     # Hybrid: 4 MPI ranks x 2 OpenMP threads each:
#     podman run --rm --shm-size=4g -v $PWD:/work delft3dfm:2026.01 \
#         run_parallel.sh -n 4 -t 2 model.mdu
#
#     # Pure OpenMP multicore (single process, all cores):
#     podman run --rm -e OMP_NUM_THREADS=8 -v $PWD:/work delft3dfm:2026.01 \
#         dflowfm --autostartstop model.mdu
#
#     # Coupled model via DIMR, 6 ranks:
#     podman run --rm --shm-size=4g -v $PWD:/work delft3dfm:2026.01 \
#         run_parallel.sh -n 6 -d dimr_config.xml
# =============================================================================


# =============================================================================
# Stage 1: base — start from Intel's image, add OS packages we need
# =============================================================================
FROM docker.io/intel/oneapi-hpckit:devel-ubuntu20.04 AS base
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Disable interactive prompts during apt installs
ARG DEBIAN_FRONTEND=noninteractive

RUN set -ex \
 && rm -f /etc/apt/sources.list.d/oneAPI.list \
          /etc/apt/sources.list.d/intel-graphics.list \
          /etc/apt/sources.list.d/intel-gpu-* \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && update-ca-certificates --fresh \
 && apt-get install -y --no-install-recommends \
        build-essential pkg-config \
        autoconf automake libtool m4 \
        flex bison \
        git curl wget \
        subversion \
        unzip xz-utils file patchelf \
        python3 python3-pip python3-dev \
        ruby \
        zlib1g zlib1g-dev \
        libcurl4 libcurl4-openssl-dev \
        libxml2 libxml2-dev \
        libexpat1 libexpat1-dev \
        libsqlite3-dev libreadline-dev libssl-dev \
        uuid uuid-dev \
        libxerces-c3.2 libxerces-c-dev \
        libgtest-dev googletest \
        libeigen3-dev \
        libproj-dev proj-bin \
        libgdal-dev gdal-bin \
        environment-modules \
 && rm -rf /var/lib/apt/lists/*

# ---- Modern CMake from Kitware ---------------------------------------------
# Ubuntu 20.04 ships CMake 3.16; DIMRset_2026.01 needs >= 3.30.
ARG CMAKE_VERSION=3.30.5
RUN set -ex \
 && curl -fsSL -o /tmp/cmake.tar.gz \
        "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz" \
 && tar -C /opt -xzf /tmp/cmake.tar.gz \
 && ln -sf "/opt/cmake-${CMAKE_VERSION}-linux-x86_64" /opt/cmake \
 && for b in cmake ctest cpack ccmake; do \
        ln -sf "/opt/cmake/bin/$b" "/usr/local/bin/$b" ; \
    done \
 && rm -f /tmp/cmake.tar.gz \
 && cmake --version

# Compiler defaults — classic Intel: icc, icpc, ifort with mpiicc/mpiicpc/mpiifort
# (This image is oneAPI 2021.6 era, predating LLVM-based icx/icpx/ifx wrappers.)
ENV CC=icc \
    CXX=icpc \
    FC=ifort \
    F77=ifort \
    F90=ifort \
    I_MPI_CC=icc \
    I_MPI_CXX=icpc \
    I_MPI_F90=ifort \
    I_MPI_F77=ifort \
    MPICC_REAL=mpiicc \
    MPICXX_REAL=mpiicpc \
    MPIFC_REAL=mpiifort

# Quick sanity check — verify compilers and MPI wrappers are working
RUN set -ex \
 && icc --version \
 && icpc --version \
 && ifort --version \
 && mpiicc -v -show 2>&1 | head -3 \
 && mpiicpc -v -show 2>&1 | head -3 \
 && mpiifort -v -show 2>&1 | head -3 \
 && echo "MKLROOT=$MKLROOT" \
 && echo "MPI_ROOT=$(ls -d /opt/intel/oneapi/mpi/* 2>/dev/null | head -1)"


# =============================================================================
# Stage 2: deps — build numerical libraries (HDF5, NetCDF, METIS, PETSc, etc.)
# =============================================================================
FROM base AS deps

ENV D3D_DEPS=/opt/d3d_deps
ENV PATH=${D3D_DEPS}/bin:${PATH} \
    LD_LIBRARY_PATH=${D3D_DEPS}/lib:${D3D_DEPS}/lib64:${LD_LIBRARY_PATH} \
    PKG_CONFIG_PATH=${D3D_DEPS}/lib/pkgconfig:${D3D_DEPS}/lib64/pkgconfig:${PKG_CONFIG_PATH}

WORKDIR /tmp/build

# ---- HDF5 1.14.4-3 (parallel + Fortran) ------------------------------------
# Note: -diag-disable=10441 silences the icc deprecation warning ("classic icc
# is deprecated, use icx"). Same for icpc/ifort.
ARG HDF5_VERSION=1.14.4-3
RUN set -ex \
 && mkdir -p hdf5 && cd hdf5 \
 && curl -fsSL -o hdf5.tar.gz \
        "https://support.hdfgroup.org/releases/hdf5/v1_14/v1_14_4/downloads/hdf5-${HDF5_VERSION}.tar.gz" \
 && tar xf hdf5.tar.gz && cd "hdf5-${HDF5_VERSION}" \
 && echo "--- Compiler versions ---" \
 && mpiicc -v 2>&1 | head -3 \
 && mpiifort -v 2>&1 | head -3 \
 && echo "--- Standalone compile sanity test ---" \
 && echo 'int main(){return 0;}' > /tmp/t.c \
 && mpiicc -fPIC /tmp/t.c -o /tmp/t || (echo "mpiicc fails on hello world" && exit 1) \
 && rm -f /tmp/t /tmp/t.c \
 && echo "--- Configuring HDF5 ---" \
 && ( CC=mpiicc FC=mpiifort CXX=mpiicpc \
      CFLAGS="-fPIC -diag-disable=10441" \
      FCFLAGS="-fPIC -diag-disable=10441" \
      CXXFLAGS="-fPIC -diag-disable=10441" \
      ./configure --prefix=${D3D_DEPS} \
            --enable-parallel --enable-fortran \
            --enable-build-mode=production \
            --enable-shared --disable-static \
   ) || { \
        echo "==== HDF5 configure FAILED — last 200 lines of config.log ====" ; \
        tail -200 config.log 2>/dev/null || echo "(no config.log)" ; \
        echo "==== End config.log ====" ; \
        exit 1 ; \
   } \
 && make -j"$(nproc)" \
 && make install \
 && cd /tmp/build && rm -rf hdf5 \
 && ls -la ${D3D_DEPS}/lib/libhdf5* | head -10

# ---- NetCDF-C 4.9.2 ---------------------------------------------------------
ARG NETCDF_C_VERSION=4.9.2
RUN set -ex \
 && mkdir -p ncc && cd ncc \
 && curl -fsSL -o netcdf-c.tar.gz \
        "https://github.com/Unidata/netcdf-c/archive/refs/tags/v${NETCDF_C_VERSION}.tar.gz" \
 && tar xf netcdf-c.tar.gz && cd "netcdf-c-${NETCDF_C_VERSION}" \
 && ( CC=mpiicc \
      CFLAGS="-fPIC -diag-disable=10441" \
      CPPFLAGS="-I${D3D_DEPS}/include" \
      LDFLAGS="-L${D3D_DEPS}/lib -Wl,-rpath,${D3D_DEPS}/lib" \
      ./configure --prefix=${D3D_DEPS} \
            --enable-netcdf-4 --enable-shared --disable-static --disable-dap \
   ) || { echo "==== NetCDF-C configure FAILED ====" ; tail -200 config.log 2>/dev/null ; exit 1 ; } \
 && make -j"$(nproc)" && make install \
 && cd /tmp/build && rm -rf ncc

# ---- NetCDF-Fortran 4.6.1 ---------------------------------------------------
ARG NETCDF_F_VERSION=4.6.1
RUN set -ex \
 && mkdir -p ncf && cd ncf \
 && curl -fsSL -o netcdf-fortran.tar.gz \
        "https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v${NETCDF_F_VERSION}.tar.gz" \
 && tar xf netcdf-fortran.tar.gz && cd "netcdf-fortran-${NETCDF_F_VERSION}" \
 && ( CC=mpiicc FC=mpiifort F77=mpiifort \
      CFLAGS="-fPIC -diag-disable=10441" \
      FCFLAGS="-fPIC -diag-disable=10441" \
      CPPFLAGS="-I${D3D_DEPS}/include" \
      LDFLAGS="-L${D3D_DEPS}/lib -Wl,-rpath,${D3D_DEPS}/lib" \
      ./configure --prefix=${D3D_DEPS} --enable-shared --disable-static \
   ) || { echo "==== NetCDF-Fortran configure FAILED ====" ; tail -200 config.log 2>/dev/null ; exit 1 ; } \
 && make -j"$(nproc)" && make install \
 && cd /tmp/build && rm -rf ncf

# ---- METIS 5.1.0 ------------------------------------------------------------
ARG METIS_VERSION=5.1.0
RUN set -ex \
 && mkdir -p metis && cd metis \
 && curl -fsSL -o metis.tar.gz \
        "https://github.com/xijunke/METIS-1/raw/master/metis-${METIS_VERSION}.tar.gz" \
 && tar xf metis.tar.gz && cd "metis-${METIS_VERSION}" \
 && make config prefix=${D3D_DEPS} cc=icc shared=1 \
 && make -j"$(nproc)" \
 && make install \
 && cd /tmp/build && rm -rf metis

# ---- PETSc 3.22.4 (with MKL Pardiso, no MKL-Sparse — known BAIJMKL bug) ----
ENV PETSC_DIR=${D3D_DEPS}/petsc
ENV PETSC_ARCH=arch-linux-intel-opt
ENV PATH=${PETSC_DIR}/bin:${PATH} \
    LD_LIBRARY_PATH=${PETSC_DIR}/lib:${LD_LIBRARY_PATH} \
    PKG_CONFIG_PATH=${PETSC_DIR}/lib/pkgconfig:${PKG_CONFIG_PATH}

ARG PETSC_VERSION=v3.22.4
RUN set -ex \
 && git clone --depth 1 -b "${PETSC_VERSION}" https://gitlab.com/petsc/petsc.git petsc \
 && cd petsc \
 && unset PETSC_DIR PETSC_ARCH \
 && export PETSC_DIR=/tmp/build/petsc \
 && export PETSC_ARCH=arch-linux-intel-opt \
 && ( ./configure \
        --prefix=${D3D_DEPS}/petsc \
        --with-cc=mpiicc --with-cxx=mpiicpc --with-fc=mpiifort \
        --with-blaslapack-dir=${MKLROOT} \
        --with-mkl_pardiso-dir=${MKLROOT} \
        --with-mkl_sparse=0 --with-mkl_sparse_optimize=0 \
        --with-mpi=1 --with-debugging=0 --with-batch=0 \
        --with-shared-libraries=1 --with-x=0 --with-windows-graphics=0 \
        COPTFLAGS="-O2 -fPIC -diag-disable=10441 -Wno-implicit-function-declaration" \
        CXXOPTFLAGS="-O2 -fPIC -diag-disable=10441" \
        FOPTFLAGS="-O2 -fPIC" \
   ) || { echo "==== PETSc configure FAILED ====" ; tail -200 configure.log ; exit 1 ; } \
 && make PETSC_DIR=/tmp/build/petsc PETSC_ARCH=${PETSC_ARCH} all \
 && make PETSC_DIR=/tmp/build/petsc PETSC_ARCH=${PETSC_ARCH} install \
 && cd /tmp/build && rm -rf petsc \
 && ls -la ${D3D_DEPS}/petsc/lib/libpetsc* | head -5

# ---- Eigen 3.4.0 (header-only) ---------------------------------------------
# Ubuntu's libeigen3-dev is too old for preCICE; build from source.
ARG EIGEN_VERSION=3.4.0
RUN set -ex \
 && mkdir -p eigen && cd eigen \
 && curl -fsSL -o eigen.tar.gz \
        "https://gitlab.com/libeigen/eigen/-/archive/${EIGEN_VERSION}/eigen-${EIGEN_VERSION}.tar.gz" \
 && tar xf eigen.tar.gz && cd "eigen-${EIGEN_VERSION}" \
 && mkdir build && cd build \
 && CC=/usr/bin/gcc CXX=/usr/bin/g++ cmake .. \
        -DCMAKE_INSTALL_PREFIX=${D3D_DEPS} \
        -DBUILD_TESTING=OFF \
 && make install \
 && cd /tmp/build && rm -rf eigen

# ---- Boost 1.81.0 -----------------------------------------------------------
# Using 1.81.0 for compatibility with classic Intel compilers (icc/icpc/ifort
# from oneAPI 2021.6 era). Boost 1.91.0 fails to compile with icpc 2021.6 due
# to newer C++ features in the source (e.g., replacement_field_rule).
#
# Strategy: bootstrap the b2 engine with gcc (icpc trips on pthread linking
# in the bootstrap test program), but then build the actual Boost libraries
# with the intel-linux toolset so they're ABI-compatible with Delft3D's
# icpc-compiled C++ code.  The --layout=system flag ensures libraries are
# named libboost_*.so (no tags), which is what Delft3D's CMake expects.
ARG BOOST_VERSION=1.81.0
RUN set -ex \
 && BOOST_UNDERSCORE="$(echo ${BOOST_VERSION} | tr . _)" \
 && mkdir -p boost && cd boost \
 && curl -fsSL -o boost.tar.bz2 \
        "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_UNDERSCORE}.tar.bz2" \
 && tar xf boost.tar.bz2 && cd "boost_${BOOST_UNDERSCORE}" \
 && echo "--- Bootstrap b2 engine with gcc (just to get it built) ---" \
 && CC= CXX= ./bootstrap.sh \
        --prefix=${D3D_DEPS} \
        --with-toolset=gcc \
        --with-libraries=log,program_options,system,thread,test,date_time,filesystem,regex,chrono,atomic,iostreams,serialization \
 && echo "--- Configuring intel-linux toolset for the actual Boost build ---" \
 && printf 'using intel-linux : 2021 : icpc : <cxxflags>"-fPIC -diag-disable=10441" <cflags>"-fPIC -diag-disable=10441" ;\n' \
        > tools/build/src/user-config.jam \
 && cat tools/build/src/user-config.jam \
 && echo "--- Build Boost libs with intel-linux toolset ---" \
 && ./b2 -j"$(nproc)" -d1 \
        --prefix=${D3D_DEPS} \
        --user-config=tools/build/src/user-config.jam \
        --layout=system \
        toolset=intel-linux \
        link=shared threading=multi variant=release \
        --without-python --without-mpi --without-graph --without-graph_parallel \
        install \
 && cd /tmp/build && rm -rf boost \
 && echo "--- Verify Boost libraries installed ---" \
 && ls ${D3D_DEPS}/lib/libboost_* | head -20 \
 && echo "--- Verify absence of old tag-named libs ---" \
 && ! ls ${D3D_DEPS}/lib/libboost_*-intel* 2>/dev/null \
 && echo "--- Verify Boost CMake config files ---" \
 && ls ${D3D_DEPS}/lib/cmake/ 2>/dev/null | grep -i boost \
 && find ${D3D_DEPS}/lib/cmake -name 'BoostConfig.cmake' -exec echo "FILE: {}" \; -exec head -20 {} \;

# ---- preCICE 3.3.0 (handles Boost 1.81.0's header-only system) --------------
ARG PRECICE_VERSION=v3.3.0
RUN set -ex \
 && curl -fsSL -o precice.tar.gz \
        "https://github.com/precice/precice/archive/refs/tags/${PRECICE_VERSION}.tar.gz" \
 && tar xf precice.tar.gz \
 && cd "precice-${PRECICE_VERSION#v}" \
 && mkdir build && cd build \
 && cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${D3D_DEPS} \
        -DCMAKE_PREFIX_PATH=${D3D_DEPS} \
        -DCMAKE_C_COMPILER=mpiicc \
        -DCMAKE_CXX_COMPILER=mpiicpc \
        -DBOOST_ROOT=${D3D_DEPS} \
        -DBoost_NO_SYSTEM_PATHS=ON \
        -DEigen3_DIR=${D3D_DEPS}/share/eigen3/cmake \
        -DEIGEN3_INCLUDE_DIR=${D3D_DEPS}/include/eigen3 \
        -DPRECICE_FEATURE_MPI_COMMUNICATION=ON \
        -DPRECICE_FEATURE_PETSC_MAPPING=OFF \
        -DPRECICE_FEATURE_PYTHON_ACTIONS=OFF \
        -DPRECICE_BINDINGS_C=ON \
        -DPRECICE_BINDINGS_FORTRAN=ON \
        -DBUILD_TESTING=OFF \
        -DPRECICE_BUILD_TOOLS=OFF \
        -DPRECICE_INSTALL_TEST_FILES=OFF \
 && make -j"$(nproc)" && make install \
 && cd /tmp/build && rm -rf precice* \
 && ls ${D3D_DEPS}/lib/libprecice* | head -5

# ---- ESMF 8.9.1 (Earth System Modeling Framework) --------------------------
# Provides ESMF_RegridWeightGen, used by Delft3D's wave kernel.
# Build with intel compilers + Intel MPI. Driven entirely by ESMF_* env vars.
# ~30-40 min build.
ARG ESMF_VERSION=v8.9.1
RUN set -ex \
 && curl -fsSL -o esmf.tar.gz \
        "https://github.com/esmf-org/esmf/archive/refs/tags/${ESMF_VERSION}.tar.gz" \
 && tar xf esmf.tar.gz && rm esmf.tar.gz \
 && ESMF_VER_NOPREFIX="${ESMF_VERSION#v}" \
 && cd "esmf-${ESMF_VER_NOPREFIX}" \
 && export ESMF_DIR="$PWD" \
 && export ESMF_OS=Linux \
 && export ESMF_COMPILER=intel \
 && export ESMF_COMM=intelmpi \
 && export ESMF_BOPT=O \
 && export ESMF_OPTLEVEL=2 \
 && export ESMF_ABI=64 \
 && export ESMF_INSTALL_PREFIX=${D3D_DEPS}/esmf \
 && export ESMF_INSTALL_HEADERDIR=include \
 && export ESMF_INSTALL_MODDIR=mod \
 && export ESMF_INSTALL_LIBDIR=lib \
 && export ESMF_INSTALL_BINDIR=bin \
 && export ESMF_SHARED_LIB_BUILD=ON \
 && export ESMF_NETCDF=split \
 && export ESMF_NETCDF_INCLUDE=${D3D_DEPS}/include \
 && export ESMF_NETCDF_LIBPATH=${D3D_DEPS}/lib \
 && export ESMF_NETCDF_LIBS="-lnetcdff -lnetcdf" \
 && export ESMF_F90COMPILER=mpiifort \
 && export ESMF_CXXCOMPILER=mpiicpc \
 && env | grep '^ESMF_' | sort \
 && make -j"$(nproc)" lib 2>&1 | tail -30 \
 && make -j"$(nproc)" build_apps 2>&1 | tail -20 \
 && make install 2>&1 | tail -10 \
 && cd /tmp/build && rm -rf esmf-* \
 && ls ${D3D_DEPS}/esmf/bin/ESMF_* | head -5 \
 && ln -sf "${D3D_DEPS}/esmf/bin/ESMF_RegridWeightGen" /usr/local/bin/ESMF_RegridWeightGen

ENV ESMFMKFILE=${D3D_DEPS}/esmf/lib/esmf.mk
ENV LD_LIBRARY_PATH=${D3D_DEPS}/esmf/lib:${LD_LIBRARY_PATH}

# Clean up tmp build dir for smaller layer
RUN rm -rf /tmp/build && mkdir -p /tmp/build


# =============================================================================
# Stage 3: build — clone Delft3D and run build.sh
# =============================================================================
FROM deps AS build

ARG D3D_REPO=https://github.com/Deltares/Delft3D.git
# DIMRset_2026.01 is the last release WITHOUT C++23-only tools.
# DIMRset_2026.02 added csumo_precice and pre_c_sumo with CMAKE_CXX_STANDARD 23,
# which exceeds what the classic icpc 2021.6 in this image supports.
ARG D3D_REF=DIMRset_2026.01
ARG D3D_CONFIG=all
ARG BUILD_TYPE=Release

ENV D3D_SRC=/opt/delft3d
WORKDIR /opt

RUN set -ex \
 && git clone "${D3D_REPO}" delft3d \
 && cd delft3d \
 && git checkout "${D3D_REF}" \
 && git log -1 --oneline

WORKDIR ${D3D_SRC}

# ---- SWAN source-copy fix --------------------------------------------------
# Fix from veethahavya-CU-cz/delft3dfm_dockerized line 47:
# Copy SWAN source files into the swan_mpi/ and swan_omp/ subdirectories so
# that those CMake targets can find the .f/.F sources without having to
# resolve cross-directory module dependencies. Eliminates the "USE MPI:
# Error in opening the compiled module file" error we hit otherwise.
RUN set -ex \
 && SWAN_SRC=src/third_party_open/swan/src \
 && for dir in src/third_party_open/swan/swan_mpi \
              src/third_party_open/swan/swan_omp ; do \
        if [ -d "$dir" ] && [ -d "$SWAN_SRC" ]; then \
            cp -v "$SWAN_SRC"/*.[fF]* "$dir"/ 2>/dev/null || true ; \
        fi ; \
    done \
 && echo "SWAN source files copied to mpi/omp target dirs"

# ---- dflowfm Linux OpenMP fix (upstream CMake bug) --------------------------
# In this tag, src/cmake/compiler_options/intel.cmake correctly sets
# openmp_flag=-qopenmp for Intel, and most engines (part, waq, swan_omp) apply
# it unconditionally. But dflowfm_kernel/CMakeLists.txt and
# dflowfm-cli_exe/CMakeLists.txt only apply ${openmp_flag} to the target
# inside "if(WIN32) ... endif(WIN32)" blocks -- the "if(UNIX) ... endif(UNIX)"
# blocks never reference openmp_flag at all. Result: on Linux, dflowfm compiles
# without -qopenmp, so _OPENMP is never defined and every !$OMP directive in
# dflowfm's Fortran source is treated as a plain comment (confirmed via
# `dflowfm --version` reporting "OpenMP : no" despite -fopenmp being exported
# as CFLAGS/FCFLAGS -- those env vars are irrelevant here since Delft3D's own
# CMake ignores ambient *FLAGS for this target and only honours openmp_flag).
#
# Fix: add target_compile_options(... ${openmp_flag}) inside each UNIX block,
# matching the pattern already used correctly by swan_omp/CMakeLists.txt.
# We grep-verify the expected anchor text first so the build fails loudly
# (rather than silently building an OpenMP-less binary again) if a future
# Delft3D tag changes these files.
RUN set -ex \
 && K=src/engines_gpl/dflowfm/packages/dflowfm_kernel/CMakeLists.txt \
 && E=src/engines_gpl/dflowfm/packages/dflowfm-cli_exe/CMakeLists.txt \
 && echo "--- before patch: confirm UNIX blocks lack openmp_flag ---" \
 && grep -n 'target_compile_definitions(${library_name} PRIVATE "HAVE_METIS;HAVE_MPI;HAVE_PETSC")' "$K" \
 && grep -n 'set_target_properties(${executable_name} PROPERTIES OUTPUT_NAME dflowfm)' "$E" \
 && sed -i \
      's|target_compile_definitions(${library_name} PRIVATE "HAVE_METIS;HAVE_MPI;HAVE_PETSC")|target_compile_definitions(${library_name} PRIVATE "HAVE_METIS;HAVE_MPI;HAVE_PETSC")\n    target_compile_options(${library_name} PRIVATE ${openmp_flag})|' \
      "$K" \
 && sed -i \
      's|set_target_properties(${executable_name} PROPERTIES OUTPUT_NAME dflowfm)|set_target_properties(${executable_name} PROPERTIES OUTPUT_NAME dflowfm)\n    target_compile_options(${executable_name} PRIVATE ${openmp_flag})\n    target_link_options(${executable_name} PRIVATE ${openmp_flag})|' \
      "$E" \
 && echo "--- after patch: openmp_flag now referenced in UNIX blocks ---" \
 && sed -n '/if (UNIX)/,/endif(UNIX)/p' "$K" \
 && sed -n '/if(UNIX)/,/endif(UNIX)/p' "$E" \
 && grep -q 'target_compile_options(${library_name} PRIVATE ${openmp_flag})' "$K" \
 && grep -q 'target_compile_options(${executable_name} PRIVATE ${openmp_flag})' "$E" \
 && echo "dflowfm OpenMP Linux patch applied successfully"


# ---- The actual Delft3D build ----------------------------------------------
# Note: DIMRset_2026.01's build.sh has a simpler CLI than 2026.02:
#   ./build.sh <CONFIG>          # build (default mode)
#   ./build.sh <CONFIG> --debug  # debug build
#   ./build.sh <CONFIG> -p       # prepare CMake only, no make
# It does NOT accept --build_type or --build flags.
# Configs include: all, fm-suite, d3d4-suite, dwaq, dwaves, dimr, swan, flow2d3d.
# Install tree lands in build_<CONFIG>/install/ (subdirectory).
#
# IMPORTANT: Override CC/CXX/FC with MPI wrappers so that MPI-dependent
# components (dimr, dflowfm) link against Intel MPI properly.
# Also add -fopenmp to compiler/linker flags because Delft3D uses OpenMP and
# the MPI wrappers do not auto-add it. This fixes __kmpc_* undefined references.
RUN bash -c 'set -ex \
 && export BOOST_ROOT=${D3D_DEPS} \
 && export Boost_NO_SYSTEM_PATHS=ON \
 && export BOOST_LIBRARYDIR=${D3D_DEPS}/lib \
 && export BOOST_INCLUDEDIR=${D3D_DEPS}/include \
 && export CMAKE_PREFIX_PATH=${D3D_DEPS}:${D3D_DEPS}/petsc:${D3D_DEPS}/esmf \
 && export CMAKE_INCLUDE_PATH=${D3D_DEPS}/include \
 && export CMAKE_LIBRARY_PATH=${D3D_DEPS}/lib:${D3D_DEPS}/lib64 \
 && export CFLAGS="-fopenmp" \
 && export CXXFLAGS="-fopenmp" \
 && export FCFLAGS="-fopenmp" \
 && export FFLAGS="-fopenmp" \
 && export LDFLAGS="-L${D3D_DEPS}/lib -L${D3D_DEPS}/lib64 -Wl,-rpath,${D3D_DEPS}/lib -Wl,-rpath,${D3D_DEPS}/lib64 -fopenmp" \
 && export CC=mpiicc \
 && export CXX=mpiicpc \
 && export FC=mpiifort \
 && export F77=mpiifort \
 && export F90=mpiifort \
 && chmod +x build.sh \
 && mkdir -p /opt/buildlogs \
 && set +e \
 && ./build.sh "${D3D_CONFIG}" 2>&1 | tee /opt/buildlogs/d3d_build.log ; \
    BUILD_OK=${PIPESTATUS[0]} ; \
    set -e ; \
    echo "==== build.sh exit code: ${BUILD_OK} ====" ; \
    if [ "${BUILD_OK}" != "0" ]; then \
        echo "==== Delft3D build FAILED (exit=${BUILD_OK}) ====" ; \
        echo ; \
        echo "--- CMake/compile errors (from main build log) ---" ; \
        grep -nE "CMake Error|error #|fatal error|undefined reference|Error 1|Error 2|catastrophic|Could not find|REQUIRED|version" /opt/buildlogs/d3d_build.log \
            | grep -viE "policy|deprecated|This warning|generated|^[^:]+:[0-9]+:--" | head -60 ; \
        echo ; \
        echo "--- 80 lines AROUND first '\''CMake Error'\'' ---" ; \
        FIRST_ERR=$(grep -n "CMake Error" /opt/buildlogs/d3d_build.log | head -1 | cut -d: -f1) ; \
        if [ -n "$FIRST_ERR" ]; then \
            START=$((FIRST_ERR > 40 ? FIRST_ERR - 40 : 1)) ; \
            END=$((FIRST_ERR + 40)) ; \
            sed -n "${START},${END}p" /opt/buildlogs/d3d_build.log ; \
        fi ; \
        echo ; \
        echo "--- Last 150 lines of main build log ---" ; \
        tail -150 /opt/buildlogs/d3d_build.log ; \
        BUILD_DIR="${D3D_SRC}/build_${D3D_CONFIG}" ; \
        if [ -f "$BUILD_DIR/Makefile" ]; then \
            echo "--- Makefile exists, re-running serially for clean error ---" ; \
            cd "$BUILD_DIR" ; \
            set +e ; \
            cmake --build . --target install -j1 2>&1 | tee /opt/buildlogs/serial_full.log ; \
            set -e ; \
            echo "--- Compile/link errors in serial log ---" ; \
            grep -nE "error #|fatal error|undefined reference|Error 1|Error 2|catastrophic" /opt/buildlogs/serial_full.log \
                | grep -viE "warning|deprecated" | head -30 ; \
        else \
            echo "(No Makefile in $BUILD_DIR — CMake configure failed; see main build log above)" ; \
        fi ; \
        echo "==== End build error report ====" ; \
        exit 1 ; \
    fi ; \
    echo "--- Delft3D install tree (build_${D3D_CONFIG}/install/) ---" ; \
    INSTALL_DIR="${D3D_SRC}/build_${D3D_CONFIG}/install" ; \
    find "$INSTALL_DIR" -maxdepth 3 -type d | head -20 ; \
    find "$INSTALL_DIR" -name dflowfm -o -name dimr ; \
    if [ -z "$(find $INSTALL_DIR -name dflowfm 2>/dev/null)" ]; then \
        echo "FATAL: dflowfm not found in install tree at $INSTALL_DIR!" ; \
        find "$INSTALL_DIR" -type f 2>/dev/null | head -50 ; \
        find "${D3D_SRC}/build_${D3D_CONFIG}" -name "dflowfm*" 2>/dev/null | head -20 ; \
        exit 1 ; \
    fi'

# Stage the install tree under a stable name for the runtime stage to copy
RUN cp -a "${D3D_SRC}/build_${D3D_CONFIG}/install" /opt/delft3dfm-install

# ---- Stage the Intel MPI runtime + launcher for the slim runtime image ------
# The intel/oneapi-runtime base image ships the compiler/MKL/OpenMP runtimes
# but NOT the MPI library (libmpi.so.12, libmpifort) and NOT the launcher
# (mpirun / mpiexec.hydra / hydra_*). dflowfm is linked against Intel MPI, so
# without these it fails to start. We resolve the versioned oneAPI MPI dir here
# and copy it to a stable path (/opt/intel-mpi) that stage 4 can COPY verbatim.
#
# We also stage libiomp5.so (Intel's OpenMP runtime that icc/ifort-compiled
# code links against — distinct from GNU libgomp1) so multicore/OpenMP works.
RUN set -ex \
 && MPI_DIR="$(ls -d /opt/intel/oneapi/mpi/2021.* 2>/dev/null | sort -V | tail -1)" \
 && if [ -z "$MPI_DIR" ]; then MPI_DIR="$(ls -d /opt/intel/oneapi/mpi/* 2>/dev/null | grep -v latest | sort -V | tail -1)"; fi \
 && echo "Staging Intel MPI from: $MPI_DIR" \
 && test -n "$MPI_DIR" && test -x "$MPI_DIR/bin/mpirun" \
 && cp -aL "$MPI_DIR" /opt/intel-mpi \
 && echo "--- launcher + libs present? ---" \
 && ls -la /opt/intel-mpi/bin/mpirun /opt/intel-mpi/bin/mpiexec.hydra \
 && ls -la /opt/intel-mpi/lib/release/libmpi.so.12* \
 && mkdir -p /opt/intel-omp \
 && IOMP="$(find /opt/intel/oneapi/compiler -name 'libiomp5.so' 2>/dev/null | head -1)" \
 && test -n "$IOMP" && cp -aL "$IOMP" /opt/intel-omp/ \
 && echo "Staged libiomp5 from: $IOMP"

# ---- Hybrid MPI+OpenMP launcher helper -------------------------------------
# Single script that hides the two-step partition-then-mpirun dance and sets
# safe single-node container defaults. Usage:
#   run_parallel.sh <model.mdu>            # auto: all cores, MPI only
#   run_parallel.sh -n 8 <model.mdu>       # 8 MPI ranks
#   run_parallel.sh -n 4 -t 2 <model.mdu>  # 4 ranks x 2 OpenMP threads (hybrid)
#   run_parallel.sh -d dimr_config.xml     # DIMR-driven coupled run
RUN cat > /usr/local/bin/run_parallel.sh <<'EOS' && chmod +x /usr/local/bin/run_parallel.sh
#!/usr/bin/env bash
# Delft3D FM hybrid MPI + OpenMP launcher (single-node / single-container).
set -euo pipefail

NRANKS=""            # MPI ranks (domains). Default: all cores.
NTHREADS="1"         # OpenMP threads per rank. Default: 1 (pure MPI).
DIMR_CFG=""          # if set, run DIMR instead of bare dflowfm
MDU=""

usage() {
  cat >&2 <<USAGE
Usage:
  run_parallel.sh [-n RANKS] [-t THREADS] <model.mdu>
  run_parallel.sh [-n RANKS] [-t THREADS] -d <dimr_config.xml>

  -n RANKS    number of MPI domains/ranks   (default: all available cores)
  -t THREADS  OpenMP threads per MPI rank   (default: 1)
  -d FILE     run via DIMR with this config (coupled models)

Examples:
  run_parallel.sh model.mdu                 # MPI on all cores
  run_parallel.sh -n 8 model.mdu            # 8 domains
  run_parallel.sh -n 4 -t 2 model.mdu       # hybrid: 4 ranks x 2 threads
  run_parallel.sh -n 6 -d dimr_config.xml   # coupled run, 6 ranks
USAGE
  exit 2
}

while getopts ":n:t:d:h" opt; do
  case "$opt" in
    n) NRANKS="$OPTARG" ;;
    t) NTHREADS="$OPTARG" ;;
    d) DIMR_CFG="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
MDU="${1:-}"

# Total logical cores available to this container.
NCORES="$(nproc)"
if [ -z "$NRANKS" ]; then
  NRANKS=$(( NCORES / NTHREADS ))
  [ "$NRANKS" -lt 1 ] && NRANKS=1
fi

export OMP_NUM_THREADS="$NTHREADS"
# Single-node container: force shared-memory fabric so Intel MPI doesn't hang
# probing for absent high-speed interconnects.
export I_MPI_FABRICS="${I_MPI_FABRICS:-shm}"
export FI_PROVIDER="${FI_PROVIDER:-tcp}"
# Pin each rank to an OMP-sized domain so hybrid threads land on distinct cores.
export I_MPI_PIN_DOMAIN="${I_MPI_PIN_DOMAIN:-omp}"

echo "==> cores=$NCORES  ranks=$NRANKS  threads/rank=$NTHREADS  (fabric=$I_MPI_FABRICS)"

if [ -n "$DIMR_CFG" ]; then
  [ -f "$DIMR_CFG" ] || { echo "DIMR config not found: $DIMR_CFG" >&2; exit 1; }
  echo "==> mpirun -np $NRANKS dimr $DIMR_CFG"
  exec mpirun -np "$NRANKS" dimr "$DIMR_CFG"
fi

[ -n "$MDU" ] || usage
[ -f "$MDU" ] || { echo "MDU not found: $MDU" >&2; exit 1; }

if [ "$NRANKS" -gt 1 ]; then
  echo "==> partitioning into $NRANKS domains"
  dflowfm --partition:ndomains="$NRANKS" "$MDU"
  echo "==> mpirun -np $NRANKS dflowfm --autostartstop $MDU"
  exec mpirun -np "$NRANKS" dflowfm --autostartstop "$MDU"
else
  echo "==> single rank, OpenMP threads=$NTHREADS"
  exec dflowfm --autostartstop "$MDU"
fi
EOS


# =============================================================================
# Stage 4: runtime — slim image with just runtime libs and Delft3D binaries
# =============================================================================
FROM docker.io/intel/oneapi-runtime:latest AS runtime

ARG DEBIAN_FRONTEND=noninteractive

# Remove problematic Intel repos and install runtime libraries (no -dev packages)
# hwloc + libfabric are needed by the Intel MPI Hydra launcher for topology
# detection and the shared-memory/tcp fabric providers.
RUN set -ex \
 && rm -f /etc/apt/sources.list.d/oneAPI.list \
          /etc/apt/sources.list.d/intel-graphics.list \
          /etc/apt/sources.list.d/intel-gpu-* \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        libgomp1 libstdc++6 \
        zlib1g libcurl4 libxml2 libexpat1 libsqlite3-0 \
        libxerces-c3.2 \
        libproj25 proj-bin \
        libgdal34t64 gdal-bin \
        python3 \
        ca-certificates \
        procps \
        libhwloc15 \
 && rm -rf /var/lib/apt/lists/*

# Copy our pre-built deps and Delft3D install tree from the build stage
COPY --from=build /opt/d3d_deps          /opt/d3d_deps
COPY --from=build /opt/delft3dfm-install /opt/delft3dfm

# ---- Intel MPI runtime + launcher (the key enabler for MPI) -----------------
# The oneapi-runtime base has no MPI. Bring in the full Intel MPI tree we staged
# in the build stage: this provides mpirun / mpiexec.hydra / hydra_* launchers,
# libmpi.so.12, libmpifort, and the libfabric providers dflowfm needs at runtime.
COPY --from=build /opt/intel-mpi /opt/intel/oneapi/mpi/latest

# ---- Intel OpenMP runtime (the key enabler for multicore) -------------------
# icc/ifort-compiled binaries link libiomp5.so, not GNU libgomp. Install it to a
# standard multiarch lib dir so the dynamic loader finds it.
COPY --from=build /opt/intel-omp/libiomp5.so /usr/lib/x86_64-linux-gnu/libiomp5.so

# Bring in the launcher helper script.
COPY --from=build /usr/local/bin/run_parallel.sh /usr/local/bin/run_parallel.sh

# Remove system-critical libraries from the Delft3D install tree to avoid
# overriding the host (Ubuntu 24.04) glibc and other essential libs.
RUN set -ex \
 && cd /opt/delft3dfm \
 && for libdir in lib lnx64/lib; do \
        if [ -d "$libdir" ]; then \
            # Remove the glibc itself and other low-level system libraries
            rm -vf "$libdir"/libc.so* "$libdir"/libc-* "$libdir"/libpthread* "$libdir"/libm.so* "$libdir"/libm-* "$libdir"/libdl.so* "$libdir"/librt.so* "$libdir"/libutil.so* "$libdir"/ld-linux* "$libdir"/libresolv* 2>/dev/null || true; \
        fi; \
    done

ENV D3D_DEPS=/opt/d3d_deps \
    D3D_HOME=/opt/delft3dfm \
    PETSC_DIR=/opt/d3d_deps/petsc \
    ESMFMKFILE=/opt/d3d_deps/esmf/lib/esmf.mk

# ---- Intel MPI runtime environment ------------------------------------------
# Point at the MPI tree we copied in. Adding bin/ to PATH gives mpirun; adding
# lib/release + libfabric/lib to LD_LIBRARY_PATH resolves libmpi/libmpifort and
# the fabric providers.
ENV I_MPI_ROOT=/opt/intel/oneapi/mpi/latest \
    FI_PROVIDER_PATH=/opt/intel/oneapi/mpi/latest/libfabric/lib/prov

# ---- Single-node container defaults for hybrid MPI + OpenMP -----------------
# I_MPI_FABRICS=shm  : use shared memory only (no interconnect probing -> no hangs)
# FI_PROVIDER=tcp    : safe libfabric provider inside a container
# I_MPI_PIN_DOMAIN=omp: size each rank's pin domain to OMP_NUM_THREADS so hybrid
#                      threads land on distinct cores.
# OMP_NUM_THREADS unset here on purpose -> OpenMP-only runs use all cores by
# default; the launcher script sets it explicitly for hybrid runs.
ENV I_MPI_FABRICS=shm \
    FI_PROVIDER=tcp \
    I_MPI_PIN_DOMAIN=omp \
    OMP_PLACES=cores \
    OMP_PROC_BIND=close

ENV PATH=${D3D_HOME}/bin:${D3D_HOME}/lnx64/bin:${D3D_DEPS}/bin:${D3D_DEPS}/esmf/bin:${I_MPI_ROOT}/bin:${PATH} \
    LD_LIBRARY_PATH=${D3D_HOME}/lib:${D3D_HOME}/lnx64/lib:${D3D_DEPS}/lib:${D3D_DEPS}/lib64:${PETSC_DIR}/lib:${D3D_DEPS}/esmf/lib:${I_MPI_ROOT}/lib/release:${I_MPI_ROOT}/lib:${I_MPI_ROOT}/libfabric/lib:${LD_LIBRARY_PATH}

# ---- Build-time smoke test: prove MPI + OpenMP runtime is complete ----------
# Fails the build early (rather than at first user run) if libmpi/libiomp are
# unresolved, the launcher is missing, or dflowfm was built without OpenMP
# (see the dflowfm Linux OpenMP CMake patch applied in stage 3 -- this check
# guards against that regression reappearing in a future Delft3D tag).
RUN set -ex \
 && echo "--- launcher present ---" \
 && which mpirun && mpirun --version | head -1 \
 && echo "--- dflowfm dynamic deps (must show libmpi + libiomp5, no 'not found') ---" \
 && DFLOWFM="$(command -v dflowfm || find /opt/delft3dfm -name dflowfm -type f | head -1)" \
 && ldd "$DFLOWFM" | grep -E 'libmpi|libiomp5|libpetsc' || true \
 && if ldd "$DFLOWFM" | grep -q 'not found'; then \
        echo "FATAL: unresolved shared libraries in dflowfm:" ; \
        ldd "$DFLOWFM" | grep 'not found' ; exit 1 ; \
    fi \
 && echo "--- mpirun launches ranks under shm fabric ---" \
 && I_MPI_FABRICS=shm mpirun -np 2 hostname \
 && echo "--- dflowfm reports OpenMP: yes (compile-time flag actually applied) ---" \
 && "$DFLOWFM" --version | tee /tmp/dflowfm_version.txt \
 && if ! grep -qiE '^OpenMP\s*:\s*yes' /tmp/dflowfm_version.txt; then \
        echo "FATAL: dflowfm was built WITHOUT OpenMP support -- multicore is broken." ; \
        cat /tmp/dflowfm_version.txt ; exit 1 ; \
    fi \
 && if ! grep -qiE '^MPI\s*:\s*yes' /tmp/dflowfm_version.txt; then \
        echo "FATAL: dflowfm was built WITHOUT MPI support." ; \
        cat /tmp/dflowfm_version.txt ; exit 1 ; \
    fi \
 && echo "MPI + OpenMP runtime OK (both confirmed yes in dflowfm --version)"

WORKDIR /work
# Default to an interactive shell; use run_parallel.sh to launch parallel runs.
CMD ["/bin/bash", "-l"]
