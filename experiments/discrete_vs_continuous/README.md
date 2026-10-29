# Discrete versus continuous experiment

For the current **time to a verified solution** experiment, see
[`until_solved/REPORT.md`](until_solved/REPORT.md) and
[`until_solved/status.json`](until_solved/status.json).

There is **no experiment time cutoff**. Each candidate runs until it returns an
independently verified solution. The 5×5 uses 7/25 clues (28%); the 7×7 uses 13/49
(26.53%), matching the real 11×11's 33/121 (27.27%) as closely as integer counts
permit. Earlier denser fixtures, throughput results and capped runs are excluded
from the current comparison.

```sh
python3 experiments/discrete_vs_continuous/run_until_solved.py --output /private/tmp/jsp-until-solved-new
```

Use a new output directory for each run. The runner builds the current discrete
solver and the actual earlier continuous solver from Git revision `e23adc5` in
isolated scratch folders. It saves progress snapshots, source hashes, exact
fixtures, witness solutions and completed results. One CPU worker is used per
search. After the small discrete baseline, three long searches overlap on the
shared host. Their elapsed times apply to this setup; one paired seed initially
provides a pilot, not an established runtime distribution.

On the 5×5, seven of the ten published clue positions are sampled without
replacement using mask seed 5101. On the 7×7, thirteen positions are sampled
uniformly without replacement after generating exact distances (maker seed 7101).
No 7×7 clue position is forced. Removing clues can admit multiple valid partitions
and different answer sums; all independently verified solutions count. Uniqueness
is not asserted.

The initial throughput experiment and its methodology follow for traceability.

This directory is opt-in and is outside the production Swift target. No core source,
release number, worker, credential, checkpoint, or coordinator state is modified.
`run.py` compiles the unchanged top-level core sources plus `Experiment.swift` with
`swiftc -O -D PATHS_CPU_ONLY` into a unique `/private/tmp` directory. It uses one CPU
worker, no GPU and no network. Logs go under the chosen experiment output directory.

Run from any directory:

```sh
python3 experiments/discrete_vs_continuous/run.py --trials 5 --seconds 3 --pool-size 256
```

Output defaults to `results/` beside this file. Use `--output` to preserve separate
runs. Compilation and generation are outside search timings. Search setup matches
the documented scope below; validation is included. Each trial has its own seed
and starts without discoveries, saved assignments, or elite sharing.

## Rules encoded

`Rules.geometry` tests all seven nonidentity rotations/reflections about a shape's
bounding-box center using doubled integer coordinates. A state must be orthogonally
connected and have at least one such symmetry. A capitol exists only if **every**
symmetry fixes the same single square. A 1x3 rectangle and the X pentomino therefore
have no capitol. These cases and a singleton are checked at startup.

`Rules.distances` uses multi-source integer Dijkstra from all capitols. An
orthogonal edge costs the smaller of the two state sizes, also for travel within
a state, where those sizes agree. Clues equal the minimum distance to any capitol.
The final answer is the sum of squared row sums of state sizes.

The supplied example is transcribed with its known partition; it must validate
and produce 8,045. Every generated solution is checked against the production
independent validator using both the sampled clues and **all** computed distances.
Both scoring implementations must give zero on the valid witnesses.

## Puzzle maker

`Puzzle.make` starts with singleton cells and repeatedly merges randomly selected
adjacent regions when the resulting shape is symmetric and at most 16 cells.
Connectivity is preserved by construction. Cell 0 stays singleton to ensure at
least one capitol. The maker calculates exact distances, reveals approximately
40% of them, and always reveals cell 0 and a farthest cell. Two 8x8 puzzles use
seeds 8101 and 8102. Clues, complete witness partitions and maker seeds are saved.
They are known satisfiable; uniqueness is **not** established. This generator
produces a different difficulty distribution from the published puzzle.

## Measurements and limits

1. **Scoring throughput:** 256 identical connected-component partitions per puzzle,
   derived from seeded random edges. Both candidates receive identical hard
   boundaries. Discrete calls the current `SearchContext.evaluate`; continuous
   calls retained `Energy.evaluate` with the same configured factors. Five repeats
   alternate candidate order. Fresh-context pool passes and five cached pool
   revisits are reported separately. Board construction is excluded from both.
   The two heuristics have different meanings on invalid partitions, so their
   checksums need not agree. This is an algorithm comparison, not a claim that
   changing `Double` to `Int` alone causes the measured difference. Production
   discrete scoring itself still computes floating-point residuals.

2. **Controlled search:** both use the same edge-resampling annealer, paired RNG
   seeds, initial topology, uniform edge selection, threshold (0.5), acceptance
   draws, temperature schedule and restart frequency. Discrete relationships are
   binary; continuous relationships are uniform real values in [0,1]. Components
   come from thresholded edges. Discrete uses exact scoring; continuous uses the
   retained approximate capitol fields plus symmetry and discreteness energies.
   This is an experiment-only search adapter: there is no active continuous
   production search loop in this checkout. Different acceptance decisions cause
   trajectories to diverge. Every evaluation is independently validated; success
   means a valid hard partition, including for continuous candidates. Fractional
   relationship values are an intermediate representation, not puzzle output.
   The best reported unsolved candidate ranks structural issues before wrong
   clues. Validation overhead is included for both candidates.

3. **Production reference:** the actual current single-worker repair search runs
   with the same seeds and time limit. Its richer moves, initialization, caches,
   and ranking differ from the controlled annealer; it is a practical baseline,
   not a controlled representation-only comparison. Its evaluation counter counts
   uncached scoring work; controlled counters count all scoring calls, including
   repeated partitions. Compare their solve rates and elapsed times, not these
   counters directly.

Trials stop on an independently validated solution or at the per-trial budget.
Unsolved trials are censored observations, not measured solve times. Report solve
count alongside successful solve times; a timeout cannot prove that a method
would never solve. Five short trials are exploratory evidence. The 8x8 results
apply to these two generated fixtures, not to all 8x8 puzzles or the real 11x11.
The active production solver is already discrete; the continuous API is retained
for independent experimentation (see the root README).
