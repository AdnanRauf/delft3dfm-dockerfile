# Running DIMR models with `delft3dfm:2026.02`

A short, practical guide built around the official example models.

---

## 1. What DIMR is

**DIMR** (Deltares Integrated Model Runner) is the program that starts and
coordinates model engines. You use it whenever a run involves *more than one
engine* — flow + waves, flow + water quality, flow + real-time control — and it
also works perfectly well for a single engine.

It reads one file, `dimr_config.xml`, and works out what to launch from that.
You never name the `.mdu` on the command line; DIMR finds it via the config.

All 11 official FM examples are DIMR-driven, so this is the main way you'll run
things.

### Your command shape

```bash
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD":/work -w /work delft3dfm:2026.02 <command>
```

Save typing with an alias in `~/.bashrc`:

```bash
alias d3d='docker run --rm --shm-size=4g --user $(id -u):$(id -g) -v "$PWD":/work -w /work delft3dfm:2026.02'
```

Everything below assumes that alias.

---

## 2. `dimr_config.xml` in sixty seconds

Here is a complete, minimal config — a single D-Flow FM model
(from `examples/dflowfm/01_dflowfm_sequential`):

```xml
<control>
  <start name="DFlowFM" />
</control>

<component name="DFlowFM">
  <library>dflowfm</library>
  <process>0</process>
  <mpiCommunicator>DFM_COMM_DFMWORLD</mpiCommunicator>
  <workingDir>dflowfm</workingDir>
  <inputFile>f34.mdu</inputFile>
</component>
```

Four things matter:

| Tag | Meaning |
|---|---|
| `<library>` | Which engine: `dflowfm`, `wave`, `dwaq`, `flow2d3d`, `FBCTools_BMI` (RTC) |
| `<workingDir>` | Subfolder holding that engine's input files |
| `<inputFile>` | The engine's own master file (`.mdu`, `.mdw`, ...) |
| `<process>` | Which MPI ranks this component runs on — `0` for sequential, `0 1 2 3` for four ranks |

`<control>` says what runs and in what order.

### A coupled example

Flow + waves (from `09_dflowfm_parallel_dwaves`):

```xml
<control>
  <parallel>
    <startGroup>
      <time>0.0 3.6e3 9.99e4</time>
      <start name="myNameWave"/>
    </startGroup>
    <start name="myNameDFlowFM"/>
  </parallel>
</control>

<component name="myNameDFlowFM">
  <library>dflowfm</library>
  <process>0 1 2 3</process>
  <mpiCommunicator>DFM_COMM_DFMWORLD</mpiCommunicator>
  <workingDir>dflowfm</workingDir>
  <inputFile>f34.mdu</inputFile>
</component>

<component name="myNameWave">
  <library>wave</library>
  <workingDir>dwaves</workingDir>
  <inputFile>f34.mdw</inputFile>
</component>
```

Two rules worth remembering:

- A `<parallel>` block has **exactly one `<start/>`** — the component with the
  smallest timestep, which drives the clock. Everything else uses
  `<startGroup>`.
- `<time>` on a `<startGroup>` is `start interval stop` in seconds. Above, waves
  are recomputed every 3600 s rather than every flow timestep.

---

## 3. Running sequentially

```bash
d3d run_dimr.sh -m dimr_config.xml
```

That's it. If your file is literally named `dimr_config.xml` you can drop `-m`,
since that's the default — but being explicit is a good habit.

**`run_dimr.sh` options:**

| Option | Meaning |
|---|---|
| `-m, --masterfile <file>` | Config file (default `dimr_config.xml`) |
| `-c, --corespernode <N>` | Number of cores/ranks to run on |
| `-d, --debug <D>` | Log level: `0` = everything, `6` = silent |
| `--cleanup <script.sh>` | Run your own script right after DIMR finishes |
| `-h, --help` | Usage |

---

## 4. Running in parallel

Parallel DIMR is **three steps**, and skipping one is the most common mistake.

**Step 1 — tell the config how many ranks.** Edit `<process>` in
`dimr_config.xml` to list them, `0` to `N-1`:

```xml
<process>0 1 2 3</process>
```

**Step 2 — partition the mesh** (inside the folder holding the `.mdu`):

```bash
cd dflowfm
d3d run_dflowfm.sh --partition:ndomains=4:icgsolver=6 model.mdu
cd ..
```

This writes `model_0000.mdu`, `model_0001.mdu`, ... and partitioned net files.
Re-run it only when the mesh or the rank count changes.

**Step 3 — run DIMR with the core count:**

```bash
d3d run_dimr.sh -c 4 -m dimr_config.xml
```

Note it's `-c` that sets the rank count for DIMR — this is the official
approach used by the example scripts.

> This image also ships a convenience wrapper that does all three steps for
> you: `d3d run_parallel.sh -n 4 -d dimr_config.xml`. Useful, but learn the
> three-step version first — when a parallel run misbehaves, you need to know
> which step failed.

**Should you go parallel?** Only for reasonably large meshes. Each rank
exchanges boundary data every timestep, and below a few thousand cells that
costs more than it saves — 4 ranks can be *slower* than 1. If you're running
many model variants, run many single-process jobs side by side instead.

---

## 5. Walkthrough: run a real example

Get the examples once:

```bash
git clone --depth 1 --branch DIMRset_2026.02 https://github.com/Deltares/Delft3D.git
```

### Simplest case — sequential FM

```bash
cd Delft3D/examples/dflowfm/01_dflowfm_sequential
d3d run_dimr.sh -m dimr_config.xml
```

Watch for `** INFO : ** Model initialization was successful **`, then
timestepping. Output appears in the `dflowfm/` subfolder.

### Coupled case — parallel flow + waves

This one is self-contained; its own script does all three steps:

```bash
cd Delft3D/examples/dflowfm/09_dflowfm_parallel_dwaves
docker run --rm --shm-size=4g --user $(id -u):$(id -g) \
    -v "$PWD/..":/work -w /work/09_dflowfm_parallel_dwaves \
    delft3dfm:2026.02 ./run_example.sh
```

Note the mount is one level up (`$PWD/..`) because the example scripts reach
into sibling folders.

Success looks like: both `dflowfm` and `wave` entering their time loops, and a
`TMP_ESMF_RegridWeightGen_*_weights_*.nc` file appearing in the wave working
directory. If waves fail, read `esmf_sh.log` there.

---

## 6. The example catalogue

All are under `examples/dflowfm/` and all are DIMR-driven.

| Example | What it couples |
|---|---|
| `01_dflowfm_sequential` | FM only, 1 process — **start here** |
| `02_dflowfm_parallel` | FM only, multiple ranks |
| `03_dflowfm_dwaq_sequential` | FM + water quality |
| `04_dflowfm_dwaq_parallel` | FM + water quality, parallel |
| `05_dflowfm_dwaq-BLOOM_sequential` | FM + water quality with BLOOM algae |
| `06_dflowfm_dwaq-BLOOM_parallel` | As above, parallel |
| `07_dwaves` | Waves alone |
| `08_dflowfm_sequential_dwaves` | FM + waves |
| `09_dflowfm_parallel_dwaves` | FM + waves, parallel |
| `10_dflowfm_sequential_drtc_dwaves` | FM + real-time control + waves |
| `11_dflowfm_parallel_drtc_dwaves` | FM + RTC + waves, parallel |

**Classic Delft3D 4 models** normally use `config_d_hydro.xml` and
`run_dflow2d3d.sh` instead of DIMR. The one classic example that *is*
DIMR-driven is `examples/delft3d4/07_wave`. You can drive classic flow through
DIMR by declaring a `flow2d3d` component — the command is identical, since DIMR
picks the engine from the config.

---

## 7. Adapting an example to your own model

The fastest reliable route:

1. Copy the `dimr_config.xml` from whichever example matches your coupling.
2. Change `<workingDir>` and `<inputFile>` to match your folder layout and
   filenames.
3. Set `<process>` to `0` (sequential) or `0 1 ... N-1` (parallel).
4. Run sequentially first. Only go parallel once it works.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: configfile ... does not exist` | Filename wrong, or `-m` omitted for a non-default name | `d3d run_dimr.sh -m yourfile.xml` |
| Hangs instantly, no output | `--shm-size` too small | Always `--shm-size=4g` or more |
| Output files owned by `root` | Ran without `--user` | `sudo chown -R $USER:$USER .`, then always pass `--user` |
| Parallel run gives wrong/odd results | Mesh not partitioned, or `<process>` doesn't match `-c` | Redo steps 1–3 of section 4 consistently |
| Engine "not found" / library error | That engine isn't in your image | `d3d ls /delft3d/bin` to check |
| Waves crash or hang in regridding | ESMF issue | Check `esmf_sh.log` in the wave working dir |
| `proj_create: unrecognized format` | Model's CRS string not recognised | Harmless for Cartesian models |

Always read the **`.dia` file** in the engine's working directory — it's the
model's own log and far more useful than console output.

---

## 9. Cheat sheet

```bash
# Sequential
d3d run_dimr.sh -m dimr_config.xml

# Sequential, quiet
d3d run_dimr.sh -m dimr_config.xml -d 6

# Parallel: 1) set <process>0 1 2 3</process>  2) partition  3) run
cd dflowfm && d3d run_dflowfm.sh --partition:ndomains=4:icgsolver=6 model.mdu && cd ..
d3d run_dimr.sh -c 4 -m dimr_config.xml

# Parallel, all-in-one wrapper
d3d run_parallel.sh -n 4 -d dimr_config.xml

# Run a cleanup script afterwards
d3d run_dimr.sh -m dimr_config.xml --cleanup postprocess.sh

# What engines do I have?
d3d ls /delft3d/bin
```

Source and documentation: <https://github.com/Deltares/Delft3D>
