# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

LaMAR (ECCV 2022) is a benchmark for localization and mapping with AR devices. Two installable packages (see `[tool.setuptools]` in pyproject.toml):

- `lamar` — the evaluation pipeline and baselines (mapping + localization benchmark)
- `scantools` — the Capture data format API, plus the ground-truthing/processing pipeline

## Commands

```bash
# Install (editable). Requires Python 3.9/3.10, Ceres 2.1, COLMAP 3.8, hloc 1.4
# (scripts/install_core_dependencies.sh installs the native deps, Ubuntu-only).
python -m pip install -e .              # core (enough for lamar/)
python -m pip install -e .[scantools]   # extra deps for the processing pipeline
python -m pip install -e .[dev]         # pytest, pylint, autopep8

# Tests (all tests live in scantools/tests/; some need optional deps like open3d)
pytest scantools/tests
pytest scantools/tests/test_transform.py                # single file
pytest scantools/tests/test_navvis.py::test_name        # single test

# Lint (config in ./pylintrc)
pylint lamar scantools

# Run the benchmark (scenes CAB/HGE/LIN expected under ./data, outputs to ./outputs)
python -m lamar.run --scene CAB --ref_id map --query_id query_val_phone \
    --retrieval fusion --feature superpoint --matcher superglue
```

There is no test/lint CI; the only workflow builds the two Docker images (`docker build --target scantools|lamar`). Many changes here can't be run locally without the dataset and native deps — the Docker images (`ghcr.io/microsoft/lamar-benchmark/{scantools,lamar}`) are the reproducible environment.

## Architecture

### Capture data format (`scantools/capture/`)

The shared data model for everything. A `Capture` = one location directory; it holds `sessions/` (one per device recording), each with `sensors.txt`, `rigs.txt`, `trajectories.txt`, `images.txt`, radio signals, `raw_data/`, and `proc/` (derived assets, alignments). All of it is plain CSV-ish text + PLY/PNG/HDF5. `Capture.load(path)` mirrors the file tree in Python. The full spec is in `CAPTURE.md` — read it before touching `scantools/capture/` or any on-disk format.

Poses are `scantools.capture.Pose`; trajectories are keyed by `(timestamp, sensor_or_rig_id)` pairs, and `T_w_i` naming means transform from sensor/rig `i` to world.

### lamar: benchmark as cached task graph

`lamar/run.py` composes modular steps from `lamar/tasks/` (feature_extraction → pair_selection → feature_matching → mapping → pose_estimation, plus chunk_alignment for sequence evaluation). Each task class follows the same pattern:

- a `methods` dict of named configs (e.g. `FeatureExtraction.methods['superpoint']`) — adding a new feature/matcher/retrieval method means adding an entry here (the model itself goes into hloc upstream)
- a companion `*Paths` class deriving the output directory from the config name
- on construction, the task compares its config against the `configuration.json` saved in that directory (`lamar/utils/misc.py: same_configs`) and reuses outputs if they match, recomputes otherwise — so config changes automatically invalidate downstream steps, and runs sharing a config share the cache under `./outputs`

Feature extraction/matching is delegated to hloc (imported as `hloc`, installed separately from https://github.com/cvg/Hierarchical-Localization); this repo only provides configs and orchestration around it. New pose solvers subclass `lamar.tasks.pose_estimation.SingleImagePoseEstimation`.

`lamar/combine_results.py` zips per-scene/per-device pose files for submission to the evaluation server (test-query ground truth is private; only validation queries can be scored locally).

### scantools: runfiles + pipelines

Every processing step is a `scantools/run_*.py` "runfile" with a dual interface: CLI (`python -m scantools.run_navvis_to_capture [--args]`) and library (`from scantools import run_x; run_x.run(...)`). Keep that convention for new steps. Supporting code lives in subpackages: `proc/` (alignment, meshing, rendering, anonymization), `scanners/navvis/` (raw NavVis parsing), `utils/` (colmap I/O, transforms), `viz/`.

`pipelines/pipeline_scans.py` (align + merge NavVis sessions into the reference map) and `pipelines/pipeline_sequence.py` (align AR device sequences against the reference) chain the runfiles end-to-end.
