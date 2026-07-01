# Delft3D FM (`delft3dfm:2026.01`) — Running Multicore & MPI Models

This image ships D-Flow FM built with **Intel MPI** and **OpenMP** support. You
can run a model single-threaded, multicore (OpenMP), multi-domain (MPI), or
both at once (hybrid). This guide walks through every option, from quick
one-liners to full manual control.

Everything here assumes a **single machine / single container** — no
multi-node cluster setup required.

---

## 1. Before you start

### Build the image

```bash
docker build -t delft3dfm:2026.01 -f Dockerfile .
```

The build includes a self-check: it fails immediately if MPI or OpenMP
support is broken, so a successful build already confirms both work.

### Always give the container shared memory

Any run that uses MPI (pure-MPI or hybrid) needs real `/dev/shm`, because
Intel MPI's single-node fabric (`I_MPI_FABRICS=shm`) communicates through
shared memory. Without enough of it, MPI runs will hang or crash.

```bash
--shm-size=4g       # small/medium models
--shm-size=16g       # large models / many ranks
```

Pure-OpenMP-only runs (a single process, no `mpirun`) don't need this flag,
but it doesn't hurt to always include it.

### Mount your model directory

```bash
-v /path/to/your/model:/work
```

`/work` is the container's default working directory.

---

## 2. Quick reference: which mode do I want?

| Mode | Command style | Best when… |
|---|---|---|
| **OpenMP only** | `dflowfm` directly, `-e OMP_NUM_THREADS=N` | Small/medium model, one machine, simplest setup |
| **MPI only** | `run_parallel.sh -n N` | Larger models; PETSc-heavy linear solves benefit most from MPI domains |
| **Hybrid MPI+OpenMP** | `run_parallel.sh -n N -t T` | Many-core machines; balances MPI overhead vs. thread scaling |
| **DIMR coupled run** | `run_parallel.sh -n N -d dimr_config.xml` | Coupled flow+wave+RTC models |

Deltares' own guidance: MPI + PETSc is the preferred path for best
performance on Linux; OpenMP is a simpler default that helps on a single
machine without any partitioning step. Hybrid combines both, but has more
tuning knobs.

---

## 3. Option A — OpenMP only (simplest)

No partitioning, no `mpirun`. One process, multiple threads.

```bash
docker run --rm \
  -e OMP_NUM_THREADS=8 \
  -v $(pwd):/work \
  delft3dfm:2026.01 \
  dflowfm --autostartstop model.mdu
```

- `OMP_NUM_THREADS` controls how many threads dflowfm uses. If you omit it,
  Intel's OpenMP runtime defaults to using **all cores visible to the
  container**, which is often what you want on a dedicated machine.
- Check available cores first: `docker run --rm delft3dfm:2026.01 nproc`.

**When to use this:** smallest setup, no `--shm-size` needed, good default
for models that don't need domain decomposition.

---

## 4. Option B — MPI only (domain decomposition)

Partitions the mesh into `N` domains and runs `N` MPI ranks, each single
threaded.

### Using the helper script (recommended)

```bash
docker run --rm --shm-size=4g \
  -v $(pwd):/work \
  delft3dfm:2026.01 \
  run_parallel.sh -n 8 model.mdu
```

This automatically:
1. Runs `dflowfm --partition:ndomains=8 model.mdu` to create the sub-domains.
2. Runs `mpirun -np 8 dflowfm --autostartstop model.mdu`.
3. Sets `I_MPI_FABRICS=shm` and `FI_PROVIDER=tcp` so MPI doesn't try (and
   hang) probing for a real network interconnect inside the container.

### Doing it manually (equivalent, for full control)

```bash
docker run --rm --shm-size=4g -v $(pwd):/work delft3dfm:2026.01 bash -lc "
  dflowfm --partition:ndomains=8 model.mdu
  I_MPI_FABRICS=shm mpirun -np 8 dflowfm --autostartstop model.mdu
"
```

### Choosing rank count

```bash
docker run --rm delft3dfm:2026.01 nproc     # cores available in container
```

Don't request more MPI ranks than cores — oversubscription causes context
switching, not real speedup, and can worsen wall-clock time.

**When to use this:** larger models, especially ones bottlenecked on the
linear solver (PETSc), which benefits more from MPI domains than threads.

---

## 5. Option C — Hybrid MPI + OpenMP

Combine both: `N` MPI ranks, each with `T` OpenMP threads. Total cores used
≈ `N × T`.

```bash
docker run --rm --shm-size=4g \
  -v $(pwd):/work \
  delft3dfm:2026.01 \
  run_parallel.sh -n 4 -t 2 model.mdu
```

Example: on a 16-core machine, `-n 4 -t 2` uses 8 cores (4 ranks × 2
threads), leaving headroom; `-n 8 -t 2` uses all 16.

The helper script also sets `I_MPI_PIN_DOMAIN=omp`, which tells Intel MPI to
size each rank's CPU-pinning domain to match `OMP_NUM_THREADS`, so each
rank's threads land on distinct cores instead of overlapping.

### Manual equivalent

```bash
docker run --rm --shm-size=4g -v $(pwd):/work delft3dfm:2026.01 bash -lc "
  export OMP_NUM_THREADS=2
  export I_MPI_FABRICS=shm
  export I_MPI_PIN_DOMAIN=omp
  dflowfm --partition:ndomains=4 model.mdu
  mpirun -np 4 dflowfm --autostartstop model.mdu
"
```

**When to use this:** many-core machines where pure MPI would create more
domains than the model's inter-domain communication can efficiently handle.
Hybrid reduces MPI overhead by using fewer, "fatter" ranks.

**Rule of thumb:** start with `T=2` and tune from there. Very high thread
counts per rank (`T > 4–8`) often show diminishing returns for D-Flow FM.

---

## 6. Option D — DIMR coupled runs (flow + wave + RTC, etc.)

DIMR is Deltares' coupler for running multiple engines together in one
simulation — e.g. D-Flow FM with D-Waves (SWAN), or D-Flow FM with a
Real-Time Control (RTC) module. It's driven by a `dimr_config.xml` file
instead of a plain `.mdu`.

### 6.1 Single-domain DIMR run (no MPI, still useful)

If your coupled setup doesn't need domain decomposition (small model, or
you just want to confirm the coupling config works before scaling up):

```bash
docker run --rm -v $(pwd):/work delft3dfm:2026.01 \
  dimr dimr_config.xml
```

No `--shm-size` needed here since there's no `mpirun` involved.

### 6.2 DIMR with MPI (pure multi-rank, no threads)

```bash
docker run --rm --shm-size=4g \
  -v $(pwd):/work \
  delft3dfm:2026.01 \
  run_parallel.sh -n 6 -d dimr_config.xml
```

Manual equivalent:

```bash
docker run --rm --shm-size=4g -v $(pwd):/work delft3dfm:2026.01 bash -lc "
  I_MPI_FABRICS=shm mpirun -np 6 dimr dimr_config.xml
"
```

### 6.3 DIMR hybrid (MPI + OpenMP)

Same `-t` flag as Option C, applied to the DIMR path:

```bash
docker run --rm --shm-size=4g \
  -v $(pwd):/work \
  delft3dfm:2026.01 \
  run_parallel.sh -n 4 -t 2 -d dimr_config.xml
```

Manual equivalent:

```bash
docker run --rm --shm-size=4g -v $(pwd):/work delft3dfm:2026.01 bash -lc "
  export OMP_NUM_THREADS=2
  export I_MPI_FABRICS=shm
  export I_MPI_PIN_DOMAIN=omp
  mpirun -np 4 dimr dimr_config.xml
"
```

### 6.4 Flow + Wave coupled example

A typical D-Flow FM + D-Waves (SWAN) coupling, where you want the flow
domain partitioned across ranks and SWAN's own parallelism handled inside
the coupling config:

```bash
docker run --rm --shm-size=8g \
  -v $(pwd):/work \
  delft3dfm:2026.01 \
  run_parallel.sh -n 8 -d dimr_config.xml
```

The rank count (`-n 8`) here partitions the **flow** domain; how SWAN
parallelizes within the coupled run is controlled by settings inside
`dimr_config.xml` itself (see 6.6 below), not by this flag.

### 6.5 Flow + RTC (Real-Time Control) coupled example

RTC components are typically lightweight and don't need their own
partitioning — you generally still just drive the whole coupled run with
one `-n` for the flow domains:

```bash
docker run --rm --shm-size=4g \
  -v $(pwd):/work \
  delft3dfm:2026.01 \
  run_parallel.sh -n 4 -d dimr_config.xml
```

### 6.6 A note on `dimr_config.xml` and process counts

DIMR's XML config has its own `<process>` element per `<component>` that
can define how many MPI processes that specific component should use
(useful when different engines in the coupling need different rank counts,
e.g. flow uses 8 ranks but a lighter-weight component uses 1). If your
config already specifies process counts internally, treat `run_parallel.sh
-n N` as the **total launcher rank count**, and make sure it's consistent
with what the XML expects — a mismatch here is one of the most common
sources of `PMPI_Abort`/`Invalid communicator` errors with DIMR
specifically (see Troubleshooting, Section 10).

If you're not sure what your `dimr_config.xml` expects, start with a
single-domain run (6.1) to confirm the coupling itself works, then
introduce MPI rank counts incrementally.

---

## 7. `run_parallel.sh` full reference

```
run_parallel.sh [-n RANKS] [-t THREADS] <model.mdu>
run_parallel.sh [-n RANKS] [-t THREADS] -d <dimr_config.xml>

  -n RANKS    number of MPI domains/ranks   (default: all available cores)
  -t THREADS  OpenMP threads per MPI rank   (default: 1)
  -d FILE     run via DIMR with this config (coupled models)
```

| Command | Behavior |
|---|---|
| `run_parallel.sh model.mdu` | Pure MPI, ranks = all cores, 1 thread each |
| `run_parallel.sh -n 8 model.mdu` | Pure MPI, 8 ranks |
| `run_parallel.sh -n 4 -t 2 model.mdu` | Hybrid: 4 ranks × 2 threads |
| `run_parallel.sh -n 6 -d dimr_config.xml` | DIMR coupled run, 6 ranks |

If `-n` is a single rank (`-n 1`, or `T` set high enough that ranks would
round down to 1), the script skips partitioning and `mpirun` entirely and
just runs `dflowfm` directly — no MPI startup overhead for a serial-per-rank
config.

---

## 8. Environment variables you can override

These are already set to sensible single-container defaults, but you can
override any of them with `-e` on `docker run`:

| Variable | Default | Purpose |
|---|---|---|
| `OMP_NUM_THREADS` | unset (all cores) | Threads per process |
| `I_MPI_FABRICS` | `shm` | Forces shared-memory-only MPI transport (avoids interconnect-probing hangs in containers) |
| `FI_PROVIDER` | `tcp` | libfabric provider fallback, safe inside containers |
| `I_MPI_PIN_DOMAIN` | `omp` | Sizes each rank's pinning domain to `OMP_NUM_THREADS` |
| `OMP_PLACES` | `cores` | Pins OpenMP threads to physical cores |
| `OMP_PROC_BIND` | `close` | Keeps a rank's threads close together (cache locality) |

Example — force a different fabric setting if you hit issues:

```bash
docker run --rm --shm-size=4g -e I_MPI_FABRICS=shm:ofi \
  -v $(pwd):/work delft3dfm:2026.01 run_parallel.sh -n 4 model.mdu
```

---

## 9. Verifying the image

Run these once after building or pulling the image, before trusting it with
a real model:

```bash
# MPI launcher + libs resolve correctly
docker run --rm delft3dfm:2026.01 bash -lc "
  which mpirun && mpirun --version | head -3
  ldd \$(which dflowfm) | grep -Ei 'libmpi|libiomp5|not found'
"

# MPI actually launches multiple ranks
docker run --rm --shm-size=4g delft3dfm:2026.01 bash -lc "
  I_MPI_FABRICS=shm mpirun -np 4 hostname
"

# OpenMP is really compiled in (not just linked)
docker run --rm delft3dfm:2026.01 dflowfm --version
```

The last command's output should include:

```
OpenMP   : yes
MPI      : yes
```

If either says `no`, the image was not built correctly — do not proceed to a
real run.

---

## 10. Troubleshooting

**MPI run hangs with no output.**
Almost always missing/insufficient `--shm-size`. Increase it
(`--shm-size=8g` or higher for large models).

**`Abort(...) PMPI_Abort` or `Invalid communicator` errors.**
Usually a mismatch between the number of partitioned domains and `-np`.
Make sure both use the same rank count — the helper script keeps these in
sync automatically; if running manually, double-check they match.

**Model runs but seems no faster with more ranks/threads.**
- Check you're not oversubscribing cores: `ranks × threads` should not
  exceed `nproc` inside the container.
- Small models may be bottlenecked by I/O or fixed overhead, not compute —
  parallelism has diminishing (or negative) returns below a certain mesh
  size.
- For MPI-heavy runs, D-Flow FM is documented to become **MPI-bound** at
  large core counts; test a couple of rank counts on your actual model
  rather than assuming more is always faster.

**`libmpi.so.12` or `libiomp5.so` not found.**
The image itself is broken — re-run the verification commands in Section 9
against a freshly built image. This should not happen with the image as
shipped; if it does, rebuild from a clean `docker build` and check the build
log for the smoke-test failures near the end.

**Permission or file-not-found errors on `.mdu`/`dimr_config.xml`.**
Confirm your `-v $(pwd):/work` mount actually contains the file, and that
you're referencing it with a path relative to `/work` (not an absolute host
path).

---

## 11. Quick copy-paste cheat sheet

```bash
# OpenMP only, all cores
docker run --rm -v $(pwd):/work delft3dfm:2026.01 dflowfm --autostartstop model.mdu

# OpenMP only, explicit thread count
docker run --rm -e OMP_NUM_THREADS=8 -v $(pwd):/work delft3dfm:2026.01 \
  dflowfm --autostartstop model.mdu

# MPI only, 8 ranks
docker run --rm --shm-size=4g -v $(pwd):/work delft3dfm:2026.01 \
  run_parallel.sh -n 8 model.mdu

# Hybrid, 4 ranks x 2 threads
docker run --rm --shm-size=4g -v $(pwd):/work delft3dfm:2026.01 \
  run_parallel.sh -n 4 -t 2 model.mdu

# DIMR, single domain (no MPI)
docker run --rm -v $(pwd):/work delft3dfm:2026.01 dimr dimr_config.xml

# DIMR coupled run, 6 ranks
docker run --rm --shm-size=4g -v $(pwd):/work delft3dfm:2026.01 \
  run_parallel.sh -n 6 -d dimr_config.xml

# DIMR coupled run, hybrid (4 ranks x 2 threads)
docker run --rm --shm-size=4g -v $(pwd):/work delft3dfm:2026.01 \
  run_parallel.sh -n 4 -t 2 -d dimr_config.xml

# Interactive shell (poke around, run commands manually)
docker run --rm -it --shm-size=4g -v $(pwd):/work delft3dfm:2026.01
```
