# JSP-Oct26-GPU-Quick

©2026 ThomasB

Author: ThomasB

An isolated, short CPU/Metal component and overlap probe. It does not change the
production solver, resume the paused campaign, or demonstrate time to solution.

Read the [measured report](results/20261030-quick/JSP-Oct26-GPU-Quick-Report.md)
for timing boundaries, resource limitations and conclusions. Raw samples,
captured inputs, source hashes and a timing CSV are beside it.

- `shared.h`: the same exact shape routine compiled for C++ and Metal.
- `cpu.cpp`: optimized shape, scan/heap distance and certificate controls.
- `kernels.metal`: single-threadgroup shape and integer distance kernels.
- `main.swift`: independent shared-rule checks, timing and actual CPU cover-search
  work overlapped with independent GPU batches.
- `build.py`: native scratch build using shared rules and cover implementation.
- `capture.py`: read-only capture from the paused campaign's recorded sources.
- `report.py`: publish the two final measurements per host retained in scratch.

Reproduce locally from this repository root:

```sh
python3 experiments/gpu_quick/build.py /private/tmp/jsp-gpu-quick-build
/private/tmp/jsp-gpu-quick-build/probe experiments/gpu_quick \
  experiments/gpu_quick/results/20261030-quick/JSP-Oct26-GPU-Quick-Inputs.json \
  /private/tmp/JSP-Oct26-GPU-Quick-Reproduction.json
```

Metal device access must be available to the process. Compile natively on each
Mac; do not copy the M4's executable to an older macOS installation. Shader
startup is recorded separately and may use the OS cache. No GPU population-SA
implementation or integrated GPU-driven pruning frontier is included.
