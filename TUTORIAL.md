# Using the `delft3dfm:2026.02` Docker image

**A beginner's guide for new students**

This image contains the complete Deltares modelling suite, release
`DIMRset_2026.02`, built with `CONFIGURATION=all`. That means it has **both**
model families:

| Family | What it is | Main engine |
|---|---|---|
| **Delft3D FM** ("Flexible Mesh") | The modern suite. Unstructured grids (triangles, quads, mixed). | `dflowfm` |
| **Delft3D 4** ("classic") | The older, long-established suite. Structured curvilinear grids. | `d_hydro` + `flow2d3d` |

They are genuinely different programs with different input files — not two
modes of the same thing. Sections 3 and 4 below cover them separately.

---

## Table of contents

1. [What you need to know first](#1-what-you-need-to-know-first)
2. [Checking your image works](#2-checking-your-image-works)
3. [Part A — Delft3D FM suite](#3-part-a--delft3d-fm-suite)
4. [Part B — Delft3D 4 classic](#4-part-b--delft3d-4-classic)
5. [Shared tools](#5-shared-tools)
6. [Performance and environment](#6-performance-and-environment)
7. [Troubleshooting](#7-troubleshooting)
8. [Cheat sheet](#8-cheat-sheet)

---

## 1. What you need to know first

### The command shape

Almost every command in this tutorial looks like this:

```bash
docker run --rm --shm-size=4g -v "$PWD":/work -w /work \
    delft3dfm:2026.02 <command-and-arguments>
```

Read it in two halves. Everything **before** the image name is instructions to
Docker. Everything **after** the image name is the command that runs *inside*
the container — that's the actual model run.

### The four flags you should always use

| Flag | Why |
|---|---|
| `--rm` | Delete the container when the run finishes. Without it you accumulate dead containers that quietly eat disk space. |
| `--shm-size=4g` | Docker gives containers only 64 MB of shared memory by default, which is far too little for MPI. Anything parallel will hang or crash without this. |
| `-v "$PWD":/work -w /work` | Makes your current folder visible inside the container at `/work`, and starts there. **Your model files never go inside the image.** |
| `--user $(id -u):$(id -g)` | Run as *you*, not as root. Without it, output files are owned by root and you can't edit or delete them afterwards. |

Putting them together, the command you'll actually use most:

```bash
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 <command>
```

That's long. Save yourself typing by adding this to your `~/.bashrc`:

```bash
alias d3d='docker run --rm --shm-size=4g --user $(id -u):$(id -g) -v "$PWD":/work -w /work delft3dfm:2026.02'
```

Then reload (`source ~/.bashrc`) and every example below shortens to:

```bash
d3d run_dimr.sh -m dimr_config.xml
```

### Where your results go

Because your folder is *mounted* (not copied), output files — `.dia` logs,
`_map.nc`, `_his.nc`, restart files, `trim-*`/`trih-*` for classic — are
written straight onto your own disk. When the container exits, your results are
simply there in the folder you ran from. Nothing to copy out.

---

## 2. Checking your image works

### Is it alive?

```bash
docker run --rm delft3dfm:2026.02 dflowfm --version
```

You should see a block like:

```
Deltares, D-Flow FM Version 1.2.184.Unknown, ...
Compiled with support for:
OpenMP   : yes
MPI      : yes
PETSc    : yes
METIS    : yes
PROJ     : yes
GDAL     : yes
```

These are **capability** flags — what the program was compiled to support.

### What engines do I actually have?

```bash
docker run --rm delft3dfm:2026.02 ls /delft3d/bin
```

Since this image was built with `CONFIGURATION=all`, you should find both
families. Check the classic side specifically:

```bash
docker run --rm delft3dfm:2026.02 ls /delft3d/bin | grep -E "d_hydro|dflow2d3d"
```

If that prints nothing, your image was built FM-only and Part B won't work —
rebuild with `CONFIGURATION=all`.

### Poke around inside

Genuinely worth doing once before you run anything real:

```bash
docker run --rm -it --shm-size=4g -v "$PWD":/work -w /work delft3dfm:2026.02
```

`-it` gives you an interactive shell. Try `ls /delft3d/bin`, `nproc`,
`dflowfm --help`. Type `exit` to leave.

### Get the official example models

Many examples below refer to models that ship with the source repository, not
the image. Clone them once:

```bash
git clone --depth 1 --branch DIMRset_2026.02 https://github.com/Deltares/Delft3D.git
```

The examples live in `Delft3D/examples/dflowfm/` (11 FM cases) and
`Delft3D/examples/delft3d4/` (12 classic cases).

---

## 3. Part A — Delft3D FM suite

The modern, flexible-mesh side. Your model is defined by an **`.mdu`** file,
and coupled runs are orchestrated by **DIMR** via a `dimr_config.xml`.

### 3.1 A single-process (sequential) flow model

The simplest possible run. One mesh, one process, no coupling.

```bash
cd /path/to/your/model          # folder containing your .mdu
d3d run_dflowfm.sh model.mdu
```

Or calling the engine directly, which is what the helper script does:

```bash
d3d dflowfm --nodisplay --autostartstop model.mdu
```

- `--nodisplay` — no interactive graphics (essential in a container).
- `--autostartstop` — run start-to-finish, then exit, instead of waiting at an
  interactive prompt.

**Try it on the official example:** `examples/dflowfm/01_dflowfm_sequential`.

### 3.2 A parallel (multi-rank) flow model

Parallel FM splits your mesh into N subdomains and runs one MPI rank per
subdomain. This is **two steps**: partition, then run.

Using the helper script built into this image, which does both for you:

```bash
d3d run_parallel.sh -n 4 model.mdu
```

- `-n 4` — number of MPI ranks (= number of subdomains).
- `-t 2` — optional: OpenMP threads per rank, for hybrid runs.
- Omit `-n` and it uses all available cores.

Doing it by hand, so you understand what happened:

```bash
# Step 1: partition the mesh into 4 subdomains
d3d run_dflowfm.sh --partition:ndomains=4:icgsolver=6 model.mdu

# Step 2: run across 4 MPI ranks
d3d mpirun -np 4 dflowfm --nodisplay --autostartstop model.mdu
```

Partitioning writes new `_0000.mdu`, `_0001.mdu`, ... files plus partitioned
net files. You only need to re-partition when the mesh or the rank count
changes.

> **Is parallel worth it?** Only for reasonably large meshes. Each rank must
> exchange boundary ("halo") data with its neighbours every timestep. For a
> small model — say under a few thousand cells — that communication costs more
> than the computation it saves, and 4 ranks can be *slower* than 1. Test
> before assuming. If you're running many model variants (calibration,
> ensembles), running many single-process jobs side by side is usually far more
> efficient than parallelising each one.

### 3.3 Coupled runs with DIMR

Anything involving more than one engine — flow + waves, flow + water quality,
flow + real-time control — is launched through **DIMR**, not by calling
`dflowfm` directly. DIMR reads `dimr_config.xml` and works out which engines to
start.

Single process:

```bash
d3d run_dimr.sh -m dimr_config.xml
```

Multiple ranks:

```bash
d3d run_parallel.sh -n 4 -d dimr_config.xml
```

`run_dimr.sh` options worth knowing:

| Option | Meaning |
|---|---|
| `-m, --masterfile <file>` | DIMR config file. Default `dimr_config.xml`. |
| `-c, --corespernode <M>` | Cores per node (default 1). |
| `-d, --debug <D>` | Log verbosity: `0` = everything, `6` = silent. |
| `--cleanup <script.sh>` | Run your own script immediately after DIMR finishes. |
| `-h, --help` | Print usage. |

Note the config filename is **not** positional — it needs `-m`. If you omit it,
DIMR looks for `dimr_config.xml` in the current directory.

### 3.4 Flow + waves (D-Waves / SWAN)

Wave coupling uses DIMR with a `dwaves` component in the config:

```bash
d3d run_parallel.sh -n 4 -d dimr_config.xml
```

The known-good example to learn from is
`examples/dflowfm/09_dflowfm_parallel_dwaves`:

```bash
cd Delft3D/examples/dflowfm/09_dflowfm_parallel_dwaves
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD/..":/work -w /work/09_dflowfm_parallel_dwaves \
    delft3dfm:2026.02 ./run_example.sh
```

You can also run a **standalone** wave model with no flow coupling at all:

```bash
d3d run_dwaves.sh model.mdw
```

Wave models use an `.mdw` file. Example: `examples/dflowfm/07_dwaves`.

### 3.5 Flow + water quality (D-Water Quality / DELWAQ)

Water quality can run coupled through DIMR, or standalone on a hydrodynamic
result produced earlier.

Coupled, via DIMR — see `examples/dflowfm/03_dflowfm_dwaq_sequential`:

```bash
d3d run_dimr.sh -m dimr_config.xml
```

Standalone DELWAQ:

```bash
d3d run_delwaq.sh model.inp
```

Useful `run_delwaq.sh` options:

| Option | Meaning |
|---|---|
| `-p <proc_def>` | Use an alternative process-library file instead of the bundled default. |
| `-np` | Run with no processes — all substances treated as inert tracers. |
| `-eco [<bloom.spe>]` | Use the BLOOM algae module, optionally with a custom species database. |
| `-validation_mode` | Only validate the input file; don't compute. Very useful for debugging setups. |
| `-openpb <*.so>` | Load extra process subroutines from a shared library. |

The process library lives inside the image at `/delft3d/share/delft3d`, and the
run scripts point at it automatically — you normally don't need `-p`.

For BLOOM examples, see `examples/dflowfm/05_dflowfm_dwaq-BLOOM_sequential`
and its parallel counterpart (`06_`).

### 3.6 Flow + real-time control (D-RTC)

Real-time control simulates structures being operated during the run (gates,
pumps, weirs responding to conditions). Also DIMR-driven:

```bash
d3d run_dimr.sh -m dimr_config.xml
```

Examples: `10_dflowfm_sequential_drtc_dwaves` and
`11_dflowfm_parallel_drtc_dwaves`.

### 3.7 The full FM example set

| Folder | Demonstrates |
|---|---|
| `01_dflowfm_sequential` | Plain single-process FM |
| `02_dflowfm_parallel` | Multi-rank FM |
| `03_dflowfm_dwaq_sequential` | FM + water quality |
| `04_dflowfm_dwaq_parallel` | FM + water quality, parallel |
| `05_dflowfm_dwaq-BLOOM_sequential` | FM + water quality with BLOOM algae |
| `06_dflowfm_dwaq-BLOOM_parallel` | As above, parallel |
| `07_dwaves` | Standalone waves (SWAN) |
| `08_dflowfm_sequential_dwaves` | FM + waves, single process |
| `09_dflowfm_parallel_dwaves` | FM + waves, parallel |
| `10_dflowfm_sequential_drtc_dwaves` | FM + RTC + waves |
| `11_dflowfm_parallel_drtc_dwaves` | FM + RTC + waves, parallel |

### 3.8 FM post-processing tools

```bash
# Extract/convert results from FM output files
d3d run_dfmoutput.sh --help

# Compute volumes/areas from an FM model
d3d run_dfm_volume_tool.sh --help
```

---

## 4. Part B — Delft3D 4 classic

The older structured-grid suite, sometimes called Delft3D-FLOW. Available in
this image because it was built with `CONFIGURATION=all`.

**Key difference from FM:** a classic model is defined by an **`.mdf`** file,
and is launched through a small XML wrapper called **`config_d_hydro.xml`**
rather than by naming the `.mdf` directly. The engine executable is `d_hydro`,
which loads `libflow2d3d.so` at runtime.

A typical classic model folder looks like:

```
config_d_hydro.xml     <- what you point the runner at
f34.mdf                <- the master definition file
f34.grd  f34.enc       <- curvilinear grid + enclosure
f34.dep                <- bathymetry
f34.bnd  f34.bct/.bca  <- boundaries and their forcing
f34.obs  f34.crs       <- observation points, cross-sections
```

### 4.1 A basic classic flow run

```bash
cd /path/to/classic/model
d3d run_dflow2d3d.sh
```

With no argument it uses `config_d_hydro.xml`. To name a different one:

```bash
d3d run_dflow2d3d.sh my_config.xml
```

**Try it on:** `examples/delft3d4/01_standard`.

### 4.2 Parallel classic flow

The classic parallel launcher takes the partition count as its **first
positional argument** — note this differs from FM's `-n` flag:

```bash
d3d run_dflow2d3d_parallel.sh 4
```

or with an explicit config file:

```bash
d3d run_dflow2d3d_parallel.sh 4 my_config.xml
```

### 4.3 Classic flow + waves

There are dedicated launchers that start both engines and manage the coupling:

```bash
# Sequential flow + waves
d3d run_dflow2d3d_dwaves.sh

# Parallel flow + waves
d3d run_dflow2d3d_parallel_dwaves.sh 4
```

**Try it on:** `examples/delft3d4/03_flow-wave` and `examples/delft3d4/07_wave`.

### 4.4 Classic flow + real-time control

```bash
d3d run_dflow2d3d_rtc.sh
```

### 4.5 Fluid mud

Classic supports a two-layer fluid-mud formulation with its own launcher:

```bash
d3d run_dflow2d3d_fluidmud.sh
```

**Try it on:** `examples/delft3d4/04_fluidmud`.

### 4.6 Classic via DIMR

Classic models can *also* be driven by DIMR instead of the dedicated scripts,
if your `dimr_config.xml` declares a `flow2d3d` component:

```bash
d3d run_dimr.sh -m dimr_config.xml
```

The launch command is identical to an FM DIMR run — DIMR decides which engine
to start based on the component type in the config. Use this route when you
want classic flow coupled to other DIMR components.

### 4.7 Domain decomposition

Classic supports domain decomposition (multiple linked grids), configured
inside the model files and launched normally:

```bash
d3d run_dflow2d3d.sh
```

**Try it on:** `examples/delft3d4/02_domaindecomposition`.

### 4.8 Water quality and particle tracking (classic workflow)

```bash
# Water quality
d3d run_delwaq.sh model.inp

# Particle tracking
d3d run_delpar.sh model.inp
```

**Try them on:** `examples/delft3d4/06_delwaq`,
`examples/delft3d4/08_part-tracer`, `09_part-oil`, and
`10_delwaq-part-tracer`.

### 4.9 Morphological merging (mormerge)

For parallel morphological runs where bed changes from several conditions are
merged:

```bash
d3d run_mormerge.sh --help
```

**Try it on:** `examples/delft3d4/05_mormerge`.

### 4.10 The full classic example set

| Folder | Demonstrates |
|---|---|
| `01_standard` | Basic classic flow run |
| `02_domaindecomposition` | Multiple coupled grids |
| `03_flow-wave` | Flow + waves |
| `04_fluidmud` | Fluid mud |
| `05_mormerge` | Morphological merging |
| `06_delwaq` | Water quality |
| `07_wave` | Waves |
| `08_part-tracer` | Particle tracking, tracers |
| `09_part-oil` | Particle tracking, oil |
| `10_delwaq-part-tracer` | Water quality + particles |
| `11_standard_netcdf` | Classic with NetCDF output |
| `12_nf_2dis_simple` | Near-field discharge coupling |

---

## 5. Shared tools

These work with either family and are handy for pre/post-processing:

| Command | Purpose |
|---|---|
| `run_waqmerge.sh` | Merge water-quality hydrodynamic files |
| `run_ddcouple.sh` | Couple domain-decomposition WAQ files |
| `run_agrhyd.sh` | Aggregate hydrodynamic files (coarsen in space/time) |
| `run_maptonetcdf.sh` | Convert WAQ map output to NetCDF |
| `run_waqpb_export.sh` / `run_waqpb_import.sh` | Export/import the WAQ process library |
| `run_trim2dep.sh` | Extract a bathymetry (`.dep`) from classic `trim-` output |
| `run_qdb.sh` | Query database utility |

Run any of them with `--help` first:

```bash
d3d run_agrhyd.sh --help
```

---

## 6. Performance and environment

### Controlling threads and ranks

```bash
docker run --rm --shm-size=8g --user $(id -u):$(id -g) \
    -e OMP_NUM_THREADS=4 \
    -v "$PWD":/work -w /work \
    delft3dfm:2026.02 run_parallel.sh -n 2 -t 4 model.mdu
```

| Variable | Purpose |
|---|---|
| `OMP_NUM_THREADS` | OpenMP threads per process. Usually let `-t` handle this. |
| `I_MPI_DEBUG=5` | Verbose MPI startup diagnostics when a parallel run misbehaves. |
| `I_MPI_FABRICS` | Defaults to `shm` (shared memory) — correct for single-container runs. |
| `OMP_PLACES` / `OMP_PROC_BIND` | Thread pinning. Defaults `cores` / `close`. |

### Limiting resources

```bash
docker run --rm --cpus=4 --memory=8g ... delft3dfm:2026.02 ...
```

Useful on a shared machine so your run doesn't monopolise it. Check what the
container can see with `nproc`.

### Reading the end-of-run summary

At the end of an FM run you'll see something like:

```
MPI    : no.
OpenMP : yes.         #threads max : 1
```

Read these carefully, because they describe **this run**, not the build:

| Message | Meaning |
|---|---|
| `MPI : unavailable.` | The program was compiled *without* MPI support. |
| `MPI : no.` | Compiled *with* MPI, but this run used a single process. |
| `MPI : yes.` | Compiled with MPI *and* running across multiple ranks. |

So `MPI : no.` is completely normal for a sequential run and does **not** mean
something is wrong. If you want it to say `yes`, launch with
`run_parallel.sh -n <N>`.

---

## 7. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Hangs immediately, no output | `--shm-size` too small or missing | Always pass `--shm-size=4g` or more |
| `Permission denied` writing output | Container running as root, or folder not writable | Add `--user $(id -u):$(id -g)` |
| Output files owned by `root` | Ran without `--user` | `sudo chown -R $USER:$USER .`, then use `--user` from now on |
| `mpirun: command not found` | Using an intermediate build image | Use the final `delft3dfm:2026.02` tag, not `localhost/delft3d:...` |
| `ERROR: configfile ... does not exist` | Wrong filename, or you forgot `-m` for DIMR | Check the filename; DIMR needs `-m yourfile.xml` unless it's `dimr_config.xml` |
| Classic commands not found | Image built FM-only | Check `ls /delft3d/bin \| grep d_hydro`; rebuild with `CONFIGURATION=all` |
| Runs but very slowly | Too many threads oversubscribing too few ranks, or model too small to parallelise | Try pure MPI (`-n <cores>`) first; for small models use 1 rank |
| `proj_create: unrecognized format / unknown name` | The model's coordinate-reference-system string isn't recognised by PROJ | Harmless for Cartesian/projected models. If you need real reprojection, check the CRS attribute in your net file. |
| Model diverges / NaNs | Numerical, not Docker | Check timestep, `.dia` log, boundary conditions |

**Reading logs:** the `.dia` file in your working folder is the model's own
diagnostic log and is usually far more informative than the console output.
Start there when a model fails.

---

## 8. Cheat sheet

Assuming the `d3d` alias from section 1.

```bash
# ---- Checks ----
docker run --rm delft3dfm:2026.02 dflowfm --version
docker run --rm delft3dfm:2026.02 ls /delft3d/bin
docker run --rm -it --shm-size=4g -v "$PWD":/work -w /work delft3dfm:2026.02

# ---- Delft3D FM ----
d3d run_dflowfm.sh model.mdu                          # sequential
d3d run_parallel.sh -n 4 model.mdu                    # 4 MPI ranks
d3d run_parallel.sh -n 4 -t 2 model.mdu               # hybrid 4x2
d3d run_dflowfm.sh --partition:ndomains=4:icgsolver=6 model.mdu   # partition only
d3d run_dimr.sh -m dimr_config.xml                    # coupled, 1 process
d3d run_parallel.sh -n 4 -d dimr_config.xml           # coupled, 4 ranks
d3d run_dwaves.sh model.mdw                           # standalone waves
d3d run_delwaq.sh model.inp                           # water quality

# ---- Delft3D 4 classic ----
d3d run_dflow2d3d.sh                                  # basic (config_d_hydro.xml)
d3d run_dflow2d3d.sh my_config.xml                    # named config
d3d run_dflow2d3d_parallel.sh 4                       # 4 partitions
d3d run_dflow2d3d_dwaves.sh                           # flow + waves
d3d run_dflow2d3d_parallel_dwaves.sh 4                # flow + waves, parallel
d3d run_dflow2d3d_rtc.sh                              # flow + RTC
d3d run_dflow2d3d_fluidmud.sh                         # fluid mud
d3d run_delpar.sh model.inp                           # particle tracking

# ---- Tools ----
d3d run_dfmoutput.sh --help
d3d run_agrhyd.sh --help
d3d run_mormerge.sh --help
```

---

## Where to go next

1. **Start with an official example**, not your own model. They're known-good,
   so if one fails you know the problem is your setup, not the model.
2. **Read the `.dia` log** whenever something goes wrong.
3. **Ask which family your model is** before you start: `.mdu` means FM,
   `.mdf` + `config_d_hydro.xml` means classic. Nearly all beginner confusion
   comes from mixing up the two.

Official documentation and source: <https://github.com/Deltares/Delft3D>
