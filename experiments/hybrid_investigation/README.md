# Investigation: alternating regional SA and branch pruning

The goal is solving the sparse 11×11 puzzle. Generated smaller boards are diagnostics, not a substitute for demonstrating exact solves on that goal. No production code, installed worker, coordinator state or live database is changed by this investigation.

## What the existing solver actually does

The discrete control already contains a hybrid. `Iteration.OneIteration` calls `SearchContext.repairProposal`, then applies simulated-annealing acceptance to the resulting proposal. Repairs include merges, orbit transfers, and exact covers of selected patches. The exact-cover routine uses MRV branching and route-based branch-and-bound; its objective is improvement of the whole board, not necessarily immediate satisfaction of every clue.

Its default repair budget is 0.15 seconds, with 5,000 cover nodes and 48 completed covers per call. Normal patches contain whole existing regions up to 32 cells; periodic larger patches can reach the board size. Region catalogs and generation cursors are cached. Short erroneous routes already influence patch selection. These are existing features, not proposed additions.

The earlier “regional” experiment changes focus and randomization breadth within this machinery. Its limited pilot did not establish a speed advantage. Neither that experiment nor the global branch-pruning experiment isolates a pure SA algorithm against a pure BP algorithm.

In the matched 1,000-second experiment, instrumented catalog time was 850.507 seconds on 8×8 and 848.866 seconds on 9×9. Exact-cover time was 67.912 and 77.699 seconds respectively. Timers such as geometry and evaluation are nested inside other operations; do not add them as exclusive categories. The phase timings suggest that repeatedly generating candidate shapes is a larger current cost than traversing the local cover trees.

## A short diagnostic probe

`Probe.swift` compiles with the frozen discrete-control sources. It loads only clues and labels from the saved 8×8/9×9 near-solutions, with no maker witness. Four independent 60-second processes run concurrently, as preferred by the user:

* Ordinary SA continuation, preserving the original control settings.
* Deeper local BP repair: retain the same base board until an improvement, generate/reuse relaxed geometry-only patch catalogs with up to 0.25 seconds per generation call, then allow up to 2 seconds, 250,000 nodes and 50,000 completed covers per repair. Patches are chosen by the existing route-focused policy and contain at most 32 cells.

This tests the intensification component only. It does **not** implement full alternating regional SA/BP and is **not** a solve-speed benchmark: there is one seed, two selected checkpoints and four competing processes. Both phases start with fresh process-local caches; prior 1,000-second search time is not included in the 60-second continuation budget. Source files and exact metadata are saved with each run. Each final partition is independently checked in Python.

Run:

```sh
python3 experiments/hybrid_investigation/probe.py
python3 experiments/hybrid_investigation/screen_patches.py
python3 experiments/hybrid_investigation/report.py
```

In the observed probe, neither SA continuation nor deeper BP improved the starting incorrect-clue count **or** normalized residual. BP traversed 5,124,824 nodes / 2,277,791 completed covers on 8×8, and 4,371,090 nodes / 1,938,762 completed covers on 9×9. It spent about 59 of 60 seconds in cover search. This does not refute a hybrid, but it does not support “more BP time alone finishes these boards.” Missing useful shapes, inadequate patch scope, conditional local minima and scheduling remain possible explanations; the probe does not identify a unique cause.

## Screen patches before generating their catalogs

For a proposed patch comprising whole regions, hold the exterior partition fixed. Let the patch contain k cells. Assigned cells retain exact region sizes. Unassigned cells have size bounds [1,k].

* A shortest-path calculation with smaller edges and every patch cell admitted as a possible capitol gives a lower distance bound L. Admitting even positive-clue cells is conservative for improvement search, which can temporarily leave clues incorrect.
* A calculation from fixed exterior capitols only, with larger edges, gives an upper bound U. Every completion retains those capitols, and its true edge costs cannot exceed the larger weights.

For clue t, if t<L or t>U, a mismatch is unavoidable with this exterior. The minimum normalized error is 1-t/L when t<L, or 1-U/t when t>U; otherwise its bound is zero. Summing these gives lower bounds on incorrect-clue count and residual. Compare these against the SA incumbent's **same lexicographic quality** (structural issues, wrong clues, residual). If no improvement is possible, skip catalog generation altogether. This is sound conditional pruning; it does not prohibit changing the exterior in later SA or larger-patch phases.

`screen_patches.py` audits all connected unions of one through four existing regions, up to 48 cells. It computes residual comparisons using exact rational arithmetic. In the subset of patches up to 32 cells:

* 8×8: 356 patches; bounds exclude **any improvement** for 135 (37.9%) and exclude an immediate full solution for 171 (48.0%).
* 9×9: 239 patches; bounds exclude an immediate full solution for 172 (72.0%), while no patch is ruled out for *partial improvement* by these bounds.

These counts describe an offline patch universe, not measured time savings or the exact frequency with which the running solver selects those patches. Passing a bound is not evidence that an improvement exists. The 9×9 result is a reason to optimize error inside BP rather than reject every patch whose fixed exterior prevents an immediate full solve.

## Recommended hybrid

Use SA as the exploration phase and BP as an adaptive local intensification phase, with one shared catalog and geometry cache. A reasonable **untested starting schedule** is 5–10 seconds of SA, then 1–3 seconds of local BP when progress stalls. Start with roughly 80% SA / 20% BP and tune from measured useful progress per total wall-clock second. This is an experimental starting allocation, not an established optimum.

1. Keep a global best partition, an active SA state, and a small set of diverse elite partitions. All elapsed time, including catalog work, comes from the same total budget.
2. Select a whole-region patch from persistent wrong clues and the regions influencing their travel routes. A too-short route must be disrupted; a too-long route may need a competing shorter route or new capitol, beyond its current parent path. Occasionally select patches from diverse SA/elite states rather than always the same best board.
3. Run the cheap two-sided incumbent bounds before generating shapes. On an unpromising patch, change its location, enlarge it, or return to SA.
4. Seed the patch catalog with its current regions and compatible shapes discovered by SA. Add new symmetry-orbit shapes as needed. Reuse geometry and candidates, but invalidate exterior-dependent bounds or a resumed search cursor when the fixed exterior changes.
5. Run BP as **branch-and-bound for whole-board improvement**. Apply both distance bounds against the existing SA incumbent, not only after a newly completed cover appears. Recompute all clue distances after every completed repair. Correct clues and regions are useful context, not permanently locked facts.
6. Return useful repairs to the elite pool and SA. Preserve a separate exploratory SA state or reheat it when appropriate; alternating monotonic descent from one best board can remain stuck. After repeated failures, change candidate coverage or expand the patch (e.g. 16→32→48→64 cells) within time and memory budgets. Real 11×11 regions may be too large for a fixed 32-cell repair neighborhood.

Resume a BP cursor only while its patch, exterior partition, candidate-catalog version and objective remain compatible. “No solution” from a truncated catalog or timed-out local search is not a global impossibility proof. Safe nogoods must include their conditioning exterior; a geometry conflict is not equivalent to a heuristic search failure.

## What would establish a benefit

The next experiment should compare existing regional discrete SA against the same engine with adaptive longer BP phases, holding the puzzle, seeds, catalog generator and total elapsed budget fixed. The existing bounded cover repairs remain in both arms: the changed factor is scheduling/intensification, not claiming that one arm has never used BP.

First repeat warm-start finishing trials on several independent near-solutions, not just one checkpoint per board. Then run fresh-start trials on the existing 7×7/8×8/9×9 fixtures with multiple seeds and the same 1,000-second cap, followed by the actual 11×11 goal puzzle if results justify it. Measure validated solve rate and solve time first, then wrong-clue/error curves, candidate-generation time, useful-repair rate and pruning counts. Keep warm-start and fresh-start results separate. Concurrent runs can save turnaround time, but competition for cores and memory must be recorded when interpreting wall-clock speed.

The current evidence supports investigating this architecture; it does not yet demonstrate a hybrid speedup. The promising change is a better allocation of search to relevant, sufficiently flexible neighborhoods with shared information—not alternation by itself.
