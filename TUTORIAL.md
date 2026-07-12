# Getting started with the `delft3dfm` Docker image

This is a hands-on tutorial for running Delft3D FM (and, optionally, classic
Delft3D 4) models inside the `delft3dfm:2.31.13` container. It assumes the
image has already been built (see `build-delft3dfm.sh` / `README.md` in this
same folder) and focuses purely on *using* it day to day.

If you built two variants (`delft3dfm:2.31.13-fm` and `delft3dfm:2.31.13-all`),
substitute whichever tag you have — everything below works the same way.
This tutorial uses `delft3dfm:2.31.13` as a placeholder; replace it with your
actual tag throughout.

---

## 1. Before you start: three things to always set

Every command in this tutorial follows the same shape:

```bash
docker run --rm --shm-size=4g -v "$PWD":/work -w /work delft3dfm:2.31.13 <command>
```

- **`--rm`** — clean up the container when the run finishes (models don't
  need a persistent container between runs).
- **`--shm-size=4g`** — Docker's default shared-memory allocation (64 MB) is
  far too small for MPI. Always set this explicitly for anything that uses
  more than one process/thread. 4g is a safe default for small-to-medium
  models; bump it for larger ones.
- **`-v "$PWD":/work -w /work`** — mounts your current directory into the
  container at `/work` and starts you there. Your model files never need to
  live inside the image itself.

Everything after the image name is the command that actually runs *inside*
the container — the model, not Docker.

### Quick sanity check

```bash
docker run --rm delft3dfm:2.31.13 dflowfm --version
```

You should see version info including `MPI: yes` and `OpenMP: yes`. If this
works, the image is healthy and you're ready to go.

---

## 2. Get an interactive shell (good for exploring)

Before running real models, it's worth just poking around inside the
container once:

```bash
docker run --rm -it --shm-size=4g -v "$PWD":/work -w /work delft3dfm:2.31.13
```

The `-it` gives you an interactive bash prompt. From here you can run
`ls /delft3d/bin`, check `dflowfm --help`, inspect example models, etc.
Type `exit` to leave (the container is removed automatically thanks to
`--rm`).

---

## 3. Running a single-process (sequential) FM model

This is the simplest case: one mesh, one process, no coupling to waves or
water quality. The official repo ships a ready-made example
(`examples/dflowfm/01_dflowfm_sequential`) if you want something to practice
on before using your own `.mdu`.

```bash
cd /path/to/your/model      # the folder containing your .mdu file
docker run --rm --shm-size=4g -v "$PWD":/work -w /work \
    delft3dfm:2.31.13 dflowfm --nodisplay --autostartstop model.mdu
```

Replace `model.mdu` with your actual filename. `--autostartstop` runs the
model start-to-finish without dropping into interactive mode.

**Using the bundled helper script instead** (adds sensible defaults, e.g.
process-library path handling):

```bash
docker run --rm --shm-size=4g -v "$PWD":/work -w /work \
    delft3dfm:2.31.13 run_dflowfm.sh model.mdu
```

---

## 4. Running a parallel (multi-rank) FM model

Parallel FM splits your mesh into N domains and runs them across N MPI
ranks. Use the `run_parallel.sh` helper we built into the image — it handles
partitioning and launching for you.

```bash
docker run --rm --shm-size=4g -v "$PWD":/work -w /work \
    delft3dfm:2.31.13 run_parallel.sh -n 4 model.mdu
```

- **`-n 4`** — number of MPI ranks (domains). Pick a number ≤ the CPUs you've
  given Docker (check with `nproc` inside the container, or `docker info` on
  the host).
- Omit `-n` entirely to let it use all available cores automatically.

**Hybrid MPI + OpenMP** (fewer MPI ranks, each with multiple threads — often
faster for models with a lot of per-cell computation):

```bash
docker run --rm --shm-size=4g -v "$PWD":/work -w /work \
    delft3dfm:2.31.13 run_parallel.sh -n 4 -t 2 model.mdu
```

This runs 4 ranks × 2 OpenMP threads each = 8 cores in use.

**What `run_parallel.sh` is doing under the hood**, if you want to do it by
hand:

```bash
# 1. Partition the mesh into 4 domains
dflowfm --nodisplay --partition:ndomains=4:icgsolver=6 model.mdu

# 2. Launch across 4 MPI ranks
mpirun -np 4 dflowfm --nodisplay --autostartstop model.mdu
```

---

## 5. Running a coupled FM + D-Waves (SWAN) model via DIMR

Coupled runs (flow + waves, or flow + water quality, etc.) are orchestrated
by DIMR using a `dimr_config.xml` file, not by calling `dflowfm` directly.

**Single process:**

```bash
docker run --rm --shm-size=4g -v "$PWD":/work -w /work \
    delft3dfm:2.31.13 run_dimr.sh dimr_config.xml
```

**Multiple MPI ranks** (via `run_parallel.sh -d`):

```bash
docker run --rm --shm-size=4g -v "$PWD":/work -w /work \
    delft3dfm:2.31.13 run_parallel.sh -n 4 -d dimr_config.xml
```

This is the FM + D-Waves scenario from the official example
(`examples/dflowfm/09_dflowfm_parallel_dwaves`) — a good one to try first if
you're setting up a coupled run for the first time, since it's known-good
and self-contained:

```bash
git clone --depth 1 --branch DIMRset_2.31.13 https://github.com/Deltares/Delft3D.git
cd Delft3D/examples/dflowfm/09_dflowfm_parallel_dwaves
docker run --rm --shm-size=4g -v "$PWD/..":/work -w /work/09_dflowfm_parallel_dwaves \
    delft3dfm:2.31.13 ./run_example.sh
```

Other useful examples in the same repo folder if you want to explore
different coupling combinations:

| Example folder | What it demonstrates |
|---|---|
| `01_dflowfm_sequential` | Plain single-process FM |
| `02_dflowfm_parallel` | Multi-rank FM, no coupling |
| `03_dflowfm_dwaq_sequential` | FM + water quality (D-Water Quality) |
| `07_dwaves` | D-Waves (SWAN) standalone |
| `08_dflowfm_sequential_dwaves` | FM + Waves, single process |
| `09_dflowfm_parallel_dwaves` | FM + Waves, parallel |
| `10_dflowfm_sequential_drtc_dwaves` | FM + real-time control + Waves |
| `11_dflowfm_parallel_drtc_dwaves` | FM + RTC + Waves, parallel |

---

## 6. Running classic Delft3D 4 (Delft3D-FLOW) — only if built with `CONFIGURATION=all`

If your image was built with `CONFIGURATION=all` (not the default
`fm-suite`), the classic `flow2d3d` engine is also available. This uses the
same `dimr_config.xml` + DIMR pattern:

```bash
docker run --rm --shm-size=4g -v "$PWD":/work -w /work \
    delft3dfm:2.31.13 run_dimr.sh dimr_config.xml
```

The difference from an FM run is entirely in what your `dimr_config.xml`
references (a `flow2d3d`-type component instead of `dflowfm`) — the launch
command is identical, since DIMR figures out which engine to invoke from
the config file itself.

If you're not sure which suite your image has, check:

```bash
docker run --rm delft3dfm:2.31.13 ls /delft3d/bin | grep -E "d_hydro|flow2d3d"
```

If nothing prints, your image was built with `fm-suite` only and doesn't
have the classic engine — see the earlier note on rebuilding with
`CONFIGURATION=all`.

---

## 7. Adjusting performance/environment on the fly

The image ships with sane single-node MPI defaults baked in
(`I_MPI_FABRICS=shm`, `FI_PROVIDER=tcp`), but you can override any of them
with `-e` at the `docker run` level without touching the image:

```bash
docker run --rm --shm-size=8g \
    -e OMP_NUM_THREADS=4 \
    -v "$PWD":/work -w /work \
    delft3dfm:2.31.13 run_parallel.sh -n 2 -t 4 model.mdu
```

Common ones you might want to tweak:

| Variable | Purpose |
|---|---|
| `OMP_NUM_THREADS` | OpenMP threads per process (usually let `-t` in `run_parallel.sh` handle this instead) |
| `I_MPI_DEBUG` | Set to `5` for verbose MPI startup diagnostics if a parallel run misbehaves |
| `OMP_PLACES` / `OMP_PROC_BIND` | Thread pinning strategy — defaults are `cores` / `close` |

---

## 8. Getting your results back out

Since your working directory is bind-mounted (`-v "$PWD":/work`), output
files (`.dia`, `_map.nc`, `_his.nc`, restart files, etc.) are written
straight to your host filesystem — no copying out of a container needed.
When the `docker run` command finishes, look in the same folder you ran it
from (or wherever your model's output settings point).

---

## 9. Common first-run problems and what they mean

| Symptom | Likely cause | Fix |
|---|---|---|
| Hangs immediately, no output | `--shm-size` too small or omitted | Always pass `--shm-size=4g` or larger |
| `Permission denied` writing output files | Host directory not writable by the container's user | `chmod -R a+rwX .` on your model folder, or run with `--user $(id -u):$(id -g)` |
| `mpirun: command not found` | Using an older/different image build without the MPI runtime layer | Confirm you're using the final `delft3dfm:...` tag, not an intermediate `localhost/delft3d:...` image |
| Segfault/hang inside `ESMF_RegridWeightGen` during FM+Waves coupling | You're on an old/broken image build | Rebuild from the current `delft3dfm:2.31.13` image, which fixes exactly this issue |
| Model runs but very slowly | Too many OpenMP threads oversubscribing too few MPI ranks, or vice versa | Try `-n <cores>` (pure MPI) first, then experiment with `-t` for hybrid |

---

## 10. Cheat sheet

```bash
# Version / sanity check
docker run --rm delft3dfm:2.31.13 dflowfm --version

# Interactive shell
docker run --rm -it --shm-size=4g -v "$PWD":/work -w /work delft3dfm:2.31.13

# Sequential FM
docker run --rm --shm-size=4g -v "$PWD":/work -w /work delft3dfm:2.31.13 \
    dflowfm --nodisplay --autostartstop model.mdu

# Parallel FM, 4 ranks
docker run --rm --shm-size=4g -v "$PWD":/work -w /work delft3dfm:2.31.13 \
    run_parallel.sh -n 4 model.mdu

# Hybrid MPI+OpenMP, 4 ranks x 2 threads
docker run --rm --shm-size=4g -v "$PWD":/work -w /work delft3dfm:2.31.13 \
    run_parallel.sh -n 4 -t 2 model.mdu

# Coupled DIMR run (FM + Waves, etc.), single process
docker run --rm --shm-size=4g -v "$PWD":/work -w /work delft3dfm:2.31.13 \
    run_dimr.sh dimr_config.xml

# Coupled DIMR run, 4 ranks
docker run --rm --shm-size=4g -v "$PWD":/work -w /work delft3dfm:2.31.13 \
    run_parallel.sh -n 4 -d dimr_config.xml
```

Start with the official example in section 5 if you're new to this — it's
guaranteed to work and gives you a known-good reference to compare your own
model's behavior against.
