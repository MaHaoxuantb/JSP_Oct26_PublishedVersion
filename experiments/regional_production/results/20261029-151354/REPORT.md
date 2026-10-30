# Production-preserving regional experiment

Each trial: one worker, sequential execution, 300-second cutoff. Seeds: [20261029].

The former generic mutation harness is excluded. The production discrete control reproduced fast 5x5 solving before regional trials began. Continuous uses the historical engine with weights 2:1:2 in both arms.

| Board | Solver | Policy | Exact solve time | Incorrect clues | Structural issues | Retained exact energy | Lowest observed exact energy |
|---|---|---|---:|---:|---:|---:|---:|
| 5x5 | discrete | Control | 8.637 s | 0 | 0 | 0.000000 | 0.000000 |
| 5x5 | discrete | Regional | 10.397 s | 0 | 0 | 0.000000 | 0.000000 |
| 5x5 | continuous | Control | Unsolved at 300.000 s | 3 | 1 | 0.164286 | 0.047552 |
| 5x5 | continuous | Regional | Unsolved at 300.000 s | 4 | 0 | 0.061228 | 0.061228 |
| 7x7 | discrete | Control | Unsolved at 300.002 s | 1 | 0 | 0.003506 | 0.003506 |
| 7x7 | discrete | Regional | Unsolved at 300.002 s | 1 | 0 | 0.003787 | 0.003787 |
| 7x7 | continuous | Control | Unsolved at 300.001 s | 3 | 1 | 0.076159 | 0.035178 |
| 7x7 | continuous | Regional | Unsolved at 300.001 s | 4 | 0 | 0.037619 | 0.037619 |

![Lowest observed exact energy](observed-energy.png)

Lowest observed energy is the running minimum over logged retained candidates, not every evaluated proposal. It is an observational diagnostic and does not guide either search.

![Common exact energy](common-energy.png)

![Native energy](native-energy.png)

Exact energy uses the same binary partition geometry and integer shortest-path distances for all candidates: `(2 * mean normalized clue error + invalid-cell fraction) / 3.25`. Native energy retains each solver's own objective; the continuous one uses stronger discreteness weights. Curves follow the solver's retained candidate, which need not minimize this common scalar score. No line is extended beyond its real stopping time.

All retained snapshots are independently checked against integer rules. Discrete exact scores are cross-checked against logged scores. Initial states are compared within each pair; see checks.json. Time-bounded production catalogs make runs timing-sensitive despite fixed seeds.

**Limits:** a one-seed pilot cannot establish a reliable speed advantage. Discrete and continuous have different initialization, move sets, ranking and temperature rules, so their difference is not caused by number representation alone. Regional changes are limited to proposal focus/breadth as documented in README.md. A cutoff is an unsolved observation, not an estimated solve time.

Search sources and their patch provenance are frozen in sources/. Original source hashes, fixtures, raw logs, independent validation, and sampled curves are preserved here. No core release or deployment occurred.


<!-- branch-pruning-extension -->

## Added experiment: Swift branch pruning, 600-second limit

Four new sequential, single-process trials only; the preceding 300-second experiments were not rerun or extended. Times below include catalog generation and search. Compilation and puzzle making are excluded. The 5×5 and 7×7 clues are exactly the old fixtures. New 4×4 and 6×6 clues use the same target density, rounded to a whole cell.

| Board | Clues | Exact solve time / outcome | Catalog generation | Catalog shapes | Nodes | Distance prunes | Final incorrect clues |
|---|---:|---|---:|---:|---:|---:|---:|
| 4×4 | 4/16 (25.00%) | Solved in 0.013 s | 0.012 s | 558 | 426 | 292 | 0 |
| 5×5 | 7/25 (28.00%) | Solved in 0.435 s | 0.406 s | 12,679 | 1,125 | 805 | 0 |
| 6×6 | 10/36 (27.78%) | Solved in 114.490 s | 15.316 s | 133,247 | 1,774,005 | 1,569,300 | 0 |
| 7×7 | 13/49 (26.53%) | Unsolved at 600.001 s (time_limit) | 45.000 s | 1,483,284 | 303,308 | 279,233 | 9 |

The sparse 5×5 solved in 0.435 s versus the previously measured 8.637 s for the discrete control (about 19.8× faster in this trial) and 10.397 s for regional discrete. The continuous arms did not solve within their old 300-second budget. This is a single trial on one fixture, not a general speed guarantee. There are no old 4×4 or 6×6 control measurements. The old 7×7 trials stopped at 300 seconds, so they do not establish what those engines would do with 600 seconds.

The new algorithm enumerates symmetric connected regions, then performs whole-board exact-cover DFS with minimum-remaining-values branching. It prunes impossible coverage, invalid capitol placements, adjacent-clue size bounds, and clue values outside admissible shortest-path bounds. Every 2,048 nodes a feasible partial cover may be completed with singletons for diagnostics and solution detection. This is a different algorithm from the annealing engines; it does not isolate number representation or regional randomization.

Catalog generation gets up to 45 seconds inside the 600-second total, with per-job quotas. Indexing and sorting happen afterward and are also included in total time; the catalog-generation column excludes that sorting. All region sizes through the entire board are allowed. Catalog status: 4×4 complete, 5×5 complete, 6×6 complete, 7×7 incomplete (67 truncated jobs). Exhausting an incomplete catalog is not an unsatisfiability proof. A timeout is not an estimated solve time.

![Branch diagnostic energy over real time](../../../branch_pruning/results/20261029-160117/branch-energy.png)

The chart uses the same common exact energy as above, evaluated on complete partitions with valid region geometry only. The branch curve is the best observed singleton completion or full cover, while old curves retain their original sampling. No energy is assigned to an unfinished partition, and no line extends beyond its measured stopping time. Catalog generation appears as a gap before the first branch observation.

Validation: two exhaustive catalog comparisons (2×2/3×3) and six exhaustive pruning comparisons preserved all 161 satisfying small-board partitions. Every returned partition was independently checked in Python. New fixtures are generated from valid partitions; uniqueness and comparable difficulty across sizes are not established. The timed solver received clues only, without witnesses. All production source hashes remained unchanged. No release bump or deployment occurred.

Frozen Swift sources, fixtures, results, logs and validation: [../../../branch_pruning/results/20261029-160117](../../../branch_pruning/results/20261029-160117/). Algorithm and reproduction instructions: [branch_pruning/README.md](../../../branch_pruning/results/20261029-160117/../../README.md).


<!-- branch-vs-discrete-1000 -->

## Added comparison: 7×7, 8×8 and 9×9, 1,000 seconds per solver

Completed. One sequential process at a time; branch pruning first, then the frozen old discrete control for each size. Both get the same clues and a 1,000-second total solve budget. Control seed: 20261029; regional policy disabled. Earlier measurements above remain unchanged.

The 7×7 fixture is unchanged. The deterministic maker generated 8×8 (seed 8101) and 9×9 (seed 9101), sampling clues uniformly without replacement at the real puzzle’s rounded density of 33/121. The resulting puzzles are satisfiable; uniqueness and matched difficulty across sizes are not established. Witnesses are saved separately and are not passed to either timed solver.

| Board | Clues | Branch pruning | Old discrete control | Final incorrect clues (branch / control) |
|---|---:|---|---|---:|
| 7×7 | 13/49 (26.53%) | Unsolved at 1000.020 s (time_limit) | Solved in 116.734 s | 11 / 0 |
| 8×8 | 17/64 (26.56%) | Unsolved at 1000.013 s (time_limit) | Unsolved at 1000.003 s (timeLimit) | 16 / 1 |
| 9×9 | 22/81 (27.16%) | Unsolved at 1000.003 s (time_limit) | Unsolved at 1000.002 s (timeLimit) | 18 / 4 |

In this batch, branch pruning solved 0/3 puzzles and the old discrete control solved 1/3. The control solved the unchanged 7×7 in 116.734 seconds while branch pruning reached its cutoff. The earlier fast 5×5 result therefore did not generalize to this larger fixture. The control sources and seed are unchanged from the earlier pilot; time-bounded catalog generation can produce different search trajectories on reruns. A single trial cannot establish a general ranking of algorithms.


Branch pruning retains the earlier algorithm and its 45-second catalog-generation allocation inside the total budget. 7×7 uses the original 64-bit masks; 8×8 and 9×9 use 128-bit masks to represent all 64/81 cells correctly. The search heuristics and pruning rules are unchanged. The control is rebuilt from the frozen sources of the prior production-preserving experiment, with its original configuration and moves. Both are optimized Swift builds; compilation and fixture generation are outside the timer. Catalog generation, indexing and search are inside the branch timer. Wrapper process-wall times are also saved.

| Branch board | Catalog generation | Catalog shapes | Catalog complete? | Search nodes | Distance prunes | Final exact energy |
|---|---:|---:|---|---:|---:|---:|
| 7×7 | 45.001 s | 1,466,963 | No | 458,111 | 418,416 | 0.340276 |
| 8×8 | 45.002 s | 1,666,430 | No | 204,454 | 177,914 | 0.484529 |
| 9×9 | 45.002 s | 1,472,061 | No | 241,853 | 193,656 | 0.395321 |

![Energy over real time](../../../branch_vs_discrete/results/20261029-162908/comparison-energy.png)

Energy is the same common exact score used above, plotted against actual elapsed seconds. Branch observations come from full covers and singleton completions; control observations come from retained-candidate logs. Their sampling differs, and energy alone is not solve speed. Curves start at the first observation and stop at the measured ending time. A truncated branch catalog is incomplete; a cutoff does not prove impossibility or estimate eventual solve time. This is one fixture and one trial per solver per size, with fixed branch-first order and no machine-load isolation.

The 64-bit build repeats eight exhaustive checks. The 128-bit build repeats those checks and adds solved all-singleton 8×8/9×9 cases, verifying bits through cell 80. All reported final partitions are independently validated for geometry, capitols and integer clue distances; all logged control snapshots are independently checked too.

All production source hashes remained unchanged. No installed executables, live state or deployment were touched.

Artifacts: [fixtures, frozen sources, logs, results, validation and sampled energies](../../../branch_vs_discrete/results/20261029-162908/).


<!-- hybrid-investigation -->

## Investigation: alternating regional SA and local branch pruning

The existing discrete control already combines SA acceptance with bounded local exact-cover / branch-and-bound repairs. The proposed extension is adaptive, deeper repair phases with shared candidates and SA warm starts. Whole-board BP was unsuccessful in the larger-board trials; a local repair hypothesis remains separate from those global results.

The previous 1,000-second controls spent 850.507 s (8×8) and 848.866 s (9×9) in instrumented catalog generation, versus 67.912 s and 77.699 s in exact cover. These are instrumented phase times; other timers can be nested and should not be added as exclusive categories.

A short continuation probe used each saved near-solution as the common starting state. Four processes ran concurrently with 60 seconds per arm. The SA arm retains the control settings. The BP arm uses the same local cover routine, with existing route-focused patches up to 32 cells, relaxed geometry catalogs, 2-second repair calls, 250,000 nodes and 50,000 covers per call. It is an intensification diagnostic, not a complete alternating hybrid or a reliable speed comparison.

| Board | Arm | Incorrect clues before → after | Mean residual before → after | Cover nodes | Completed covers | Catalog / cover time |
|---|---|---:|---:|---:|---:|---:|
| 8×8 | SA continuation | 1 → 1 | 0.008761 → 0.008761 | 230,993 | 68,130 | 51.56 / 3.46 s |
| 8×8 | Deeper local BP | 1 → 1 | 0.008761 → 0.008761 | 5,124,824 | 2,277,791 | 1.17 / 58.82 s |
| 9×9 | SA continuation | 4 → 4 | 0.010374 → 0.010374 | 277,010 | 62,517 | 50.81 / 4.32 s |
| 9×9 | Deeper local BP | 4 → 4 | 0.010374 → 0.010374 | 4,371,090 | 1,938,762 | 1.28 / 58.71 s |

Neither continuation improved either checkpoint in this one-seed probe. Deeper BP spent almost its whole allowance searching and traversed millions of nodes. This does not refute a hybrid, but gives no evidence that allocating more time to the existing neighborhoods alone will finish these states. Candidate coverage, patch scope, conditional local minima and scheduling remain possible causes; they are not distinguished by this probe.

An offline audit considered all connected unions of one through four existing regions. Two-sided shortest-path bounds were checked **before candidate generation**, holding the exterior fixed. Residual comparisons use exact rational arithmetic. For patches of at most 32 cells:

| Board | Patches audited | Bounds exclude any improvement | Bounds exclude a full solution |
|---|---:|---:|---:|
| 8×8 | 356 | 135 (37.9%) | 171 (48.0%) |
| 9×9 | 239 | 0 (0.0%) | 172 (72.0%) |

These are patch-universe counts, not measured runtime savings. Passing the bounds does not prove an improvement exists. In particular, a local branch that cannot solve the whole board may still improve some wrong clues; BP should optimize against the SA incumbent, not require every local call to produce a perfect global solution.

**Recommended design:** SA exploration → persistent-error / route-based patch selection → cheap incumbent bounds → local BP with reused catalogs → elite update and SA continuation. Trigger stronger repairs on stagnation, retain SA exploration and diverse elites, and enlarge or relocate failed patches. A 5–10 s SA / 1–3 s BP schedule, initially around 80/20 by total time, is an untested starting heuristic. Preserve all elapsed costs in the common budget. Stronger BP should use both distance bounds against the incumbent, with catalogs informed by SA discoveries and search cursors reused only under compatible exterior conditions.

For the real 11×11 goal, a fixed 32-cell neighborhood and a frozen set of already-correct regions are too restrictive as a general design. Use adaptive patch sizes and revalidate every clue globally. Catalog truncation or a timed-out repair does not prove impossibility. Next evaluate the same regional SA with versus without adaptive deeper BP across multiple checkpoints, seeds and fresh starts; warm-start finishing and end-to-end solving are separate measurements. A hybrid speedup has not yet been demonstrated.

Full rationale, bound derivation, scheduling design and reproduction: [hybrid investigation](../../../hybrid_investigation/README.md). [Probe sources, inputs, results and patch audit](../../../hybrid_investigation/results/20261029-194052/). No production sources were changed.


## Certified shared-framework replacement experiment

The new N=5–9 campaign uses three certified fixtures per size, all eight factorial
conditions, three seeds and 1,200-second trials. It is separate from the historical
results above. Incomplete shape catalogues are no longer treated as a complete
search domain or as proof of uniqueness.

[Live dashboard](http://127.0.0.1:62911) · [Experiment method](</Users/thomasb/Library/Mobile Documents/com~apple~CloudDocs/Documents/develop/JaneStreetPuzzle_Oct26/experiments/solver_bench/README.md>) · [Current generated report](</Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/20261029-214421/report/REPORT.md>)
