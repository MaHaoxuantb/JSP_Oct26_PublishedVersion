# Regional energy experiment

Completed pilot: [results and wall-time curves](results/pilot-20261029-133155/REPORT.md). Eight conditions, one matched seed, 300 seconds each; no verified solutions. All experiment processes have exited.

The eight-condition pilot compares 5×5/7×7, discrete/continuous, and uniform/regional
proposals in a shared experimental harness. It uses the frozen 7-clue and 13-clue
fixtures from the previous experiment. Continuous weights are (2,1,2). The current
user-selected cutoff is 300 seconds per trial.

Run checks only (no search):

```sh
python3 experiments/regional_energy/run.py
```

Run the one-seed eight-condition pilot:

```sh
python3 experiments/regional_energy/run.py --run --seconds 300
```

The output path is saved in `latest-run.txt`. Builds and compiler caches stay in
a unique `/private/tmp` directory. No installed worker, core source, live SQLite
file, credential or coordinator state is changed. No deployment occurs.

Generate curves/report using Python 3 with ReportLab and Node.js with Sharp:

```sh
python3 experiments/regional_energy/summarize.py
node experiments/regional_energy/render_curves.cjs
```

`PLAN.md` describes the controls; `design.json` is the frozen condition matrix.
Actual mutation/scoring code is `RegionalExperiment.swift`. Native best, current
and best-exact snapshots are logged with real wall time and CPU time. Exact-best
tracking is observational and does not alter acceptance. Every run retains a
checkpoint with the current state, both best archives, proposal counter (the RNG
is counter-based), restart/temperature position and counters. A resume CLI is not
included in this pilot.

This harness omits the full production catalog/repair solver so ON/OFF contrasts
can be controlled. Cross-representation comparisons cover different scoring and
mutation adapters, not merely integer versus floating-point instructions.
One matched seed is a pilot, not a statistical performance conclusion. A cutoff
is an unfinished solve; report energy progress separately from time to solution.
