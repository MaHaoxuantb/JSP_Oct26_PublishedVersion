# Matched branch-pruning / discrete-control comparison

Six sequential trials: N=7,8,9, each branch pruning followed by the old discrete control, 1,000 seconds per trial. Control seed 20261029. The 7×7 fixture is unchanged from the prior report. New 8×8 and 9×9 use the existing deterministic maker, seeds 8101/9101, and 17/22 uniformly sampled clues, respectively. No uniqueness claim.

Branch logic is unchanged from `../branch_pruning`: symmetry-orbit catalog, MRV exact cover, admissible shortest-path pruning, periodic singleton completion diagnostics. Its generation allowance remains 45 seconds inside the total, with indexing/sorting afterward. 7×7 compiles with UInt64 board masks; 8×8 and 9×9 compile with `-D WIDE_BOARD` selecting UInt128, avoiding a 64-cell mask overflow and representing all 81 cells. Neither build changes the search policy. The wide build adds boundary tests through bit 80. Both builds repeat exhaustive small-board checks.

The control is rebuilt directly from the frozen discrete sources of the production-preserving experiment recorded in metadata, with its original Trial.swift and Policy.swift; EXPERIMENT_REGIONAL=0 and EXPERIMENT_CONTINUOUS=0. No production search or configuration changes. Both solver processes receive clues only. Maker witnesses are saved separately, validated, and never supplied to the timed search.

Run with the bundled Python runtime (reportlab required):

```sh
/Users/thomasb/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 experiments/branch_vs_discrete/run.py
```

All optimized Swift binaries and module caches are built in a unique scratch directory under /private/tmp. No installed executable is overwritten. Production source hashes are saved before/after. The report is extended after each trial and receives a real-time energy figure at completion. Earlier measurements are preserved verbatim before a new marked section. Do not regenerate earlier report sections with their older summarizers afterward, because those overwrite the report.

Raw results, fixtures, source copies, independent checks, logs, process-wall times and sampled energy CSV are saved in results/<timestamp>. Cutoffs are unsolved observations, not estimated eventual solve times. Incomplete catalogs do not prove unsatisfiability. This is a single trial/fixture per size, fixed branch-first order, with no machine-load isolation or statistical speed guarantee.
