# JSP-Oct26-GPU-Multicore

©2026 ThomasB

Author: ThomasB

An isolated Mac mini solver comparison following the
[single-threadgroup probe](../gpu_quick/results/20261030-quick/JSP-Oct26-GPU-Quick-Report.md).
Read the [plan](JSP-Oct26-GPU-Multicore-Plan.md) for scope and timing limitations.
The completed [report and real-time curves](results/20261030-mini8/JSP-Oct26-GPU-Multicore-Report.md)
contain four independently validated timed results. Neither mode solved within
90 seconds; forced GPU paths reduced throughput in both matched pairs.

- `MulticoreWorker.swift` runs eight production searches with the existing shared
  elite archive, objective rotation and seed schedule. GPU mode injects one
  existing certified Metal backend per search task, allowing eight independent
  queues and full-device scheduling. CPU mode uses production CPU paths.
- `build.py` compiles natively in an explicit scratch directory and links the
  previously verified shared integer rules. It does not overwrite an installed
  binary or change production sources.
- `run.py` freezes source and binary evidence into a fresh host-local directory,
  runs one solver process at a time and records utilization and results. It
  refuses reused directories and rejects GPU fallback.
- `collect.py` retrieves append-only or completed observations and final exports;
  it never copies live SQLite databases.
- `report.py` independently validates final partitions and produces measured
  real-time curves and a Markdown report. It requires matplotlib in an isolated
  environment; numerical evidence is retained in JSON and CSV.

The original Repair-Completion campaign remains paused. The new study uses the
original 11×11 puzzle, two matched seeds, 90 seconds per run, CPU/GPU then GPU/CPU
order. Eight CPU tasks are permitted; physical affinity is not asserted. The M2
has ten GPU cores, all available because an eight-core reservation cannot be
forced through the reviewed Metal API. Actual device activity and GPU batch
counts are recorded rather than assuming full saturation.

This is an actual solver comparison, with geometry and floating-point scoring
still on the CPU. The GPU accelerates integer path subproblems. It is not a GPU
SA implementation or the proposed fully asynchronous branch frontier. Existing
CPU/GPU batch sizes differ; read the plan before interpreting throughput.
