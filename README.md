# JaneStreetPuzzle_Oct26

The default search now uses discrete partitions, exact shortest-path scores,
constrained region repairs and a shared elite archive across ten workers. The
continuous `Energy` API remains available for separate experiments; it no longer
drives the main search. Final solutions still require the independent integer
validator in `Validation.swift`.

## Build and launch

Compile an optimized executable without running it:

```sh
swiftc -O -swift-version 6 -strict-concurrency=complete \
  -module-cache-path /tmp/janestreet-swift-module-cache \
  "$PWD"/JaneStreetPuzzle_Oct26/*.swift -o /tmp/janestreet-puzzle
```

Launch explicitly with `/tmp/janestreet-puzzle --run`. The default is the supplied
11×11 puzzle with 33 clues, seed 20261026, ten workers, 1,000 seconds per worker,
500,000 repair jobs per worker and twenty restarts. The 5×5 example remains
available as `RunConfig.example` for regression tests and the example benchmark.
Xcode's Run action uses the Release configuration;
compilation never launches a search.

To repair an existing JSONL log without starting another annealing run:

```sh
/tmp/janestreet-puzzle --repair-log "/absolute/path/to/run.jsonl"
```

This reads the saved puzzle configuration and final snapshot, then spends at
most five seconds trying connected merges of two through four regions. It
writes a separate result under `<project>/logs/repairs/`. Original logs are
untouched. Failure of this bounded repair does not prove that no solution exists.
Old logs are supported even if their configuration lacks the new repair settings.

## Search

- `ExactSearch.swift` caches region connectivity, symmetries and capitols. Each
  evaluated partition needs one multi-source Dijkstra calculation for all clues.
  Relationships are canonical 0/1 values; there are no confidence-hardening moves.
  Blank cells still receive the global mean clue error. Display energy uses the
  configured three factors with symmetry and discreteness zero on legal states.
- Search quality is lexicographic: structural issues, wrong-clue count, then mean
  normalized exact distance error. The annealing merit has the same ordering.
  Consequently a new best can have a higher display energy but fewer wrong clues.
- Initialization uses a bounded exact-cover search with a cheap symmetric palette
  (rectangles and bent triominoes). If that search is exhausted, singleton states
  provide a structurally legal fallback; they need not satisfy the clues.
- `RegionRepairs.swift` tries connected unions of two, three and four states in a
  single move. Invalid intermediate pairwise mergers are unnecessary. Enumeration
  resumes from a cached cursor keyed by the partition, independent of UUIDs.
- Patch repair selects whole adjacent states, emphasizing cells along erroneous
  shortest routes. Symmetric candidates are generated as unions of transformation
  orbits within bounding boxes. A most-constrained-cell exact-cover search fills
  the patch; travel costs are then evaluated on the entire board.
- Zero clues force their actual capitol. Positive clues cannot themselves be
  capitols. A one clue requires an adjacent singleton state; partial covers are
  pruned as soon as that becomes impossible. Symmetric states without capitols
  remain legal.
- Partial shape catalogs are cached and periodically augmented. Each job has a
  0.15-second deadline, 1,000 merge checks, 12,000 catalog masks, 5,000 cover nodes
  and 48 complete covers by default. Patches contain at most 32 cells (configurable
  up to 63). Counts and deadline stops are logged. These limits make the search
  heuristic, not an exhaustive solver or an impossibility proof. Larger states
  can be built by mergers even when they exceed the patch limit.
- Cooling adapts to the last 64 positive merit changes. Its floor retains about
  2% acceptance for the median increase; reheating targets about 30%. A hundred
  jobs without exact-quality improvement trigger a reheat, then a restart after
  the next stagnation period. Only real changes in clue satisfaction/distance
  count as improvements.

`SharedSearch.swift` owns an actor containing up to eight immutable elite
snapshots. Workers publish useful candidates and receive distinct repair tickets
so they explore different patches. Workers 4 and 8 keep exploring independently
but still publish discoveries and receive verified solutions. Other workers mix
the best candidate with other archive members. Exchange happens every twenty
jobs or about one second. A verified solution cancels siblings cooperatively;
all workers save their final results and close their logs before returning.

Boards, random generators, geometry/catalog caches and file handles are private
to each worker. The OS schedules workers across cores; they are not pinned to
specific physical cores. Per-worker seeds are reproducible, but time cutoffs and
shared archive arrival order can change the overall parallel result.

## Logs and verification

Logs live under `<project>/logs/parallel-<UUID>/`, with a coordinator JSONL and
one subdirectory per worker. The default path comes from the source location;
CLI builds should pass absolute source paths as above. `logDirectory` can be
overridden. Worker console lines report current/best energy, wrong clues,
temperature, exact evaluations, merge checks, completed covers and budget stops.
Updates are time-limited to roughly two seconds, plus immediate milestones.

Logs contain configuration, compact progress and aggregate statistics. Only each
worker's final best and the overall best include full board matrices; individual
failed proposals are not saved. The final console output includes the region-size
matrix, row sums, puzzle score, energy, and explicit validation status.

A fixed-fixture regression suite checks the saved failed board, all 511 nonempty
3×3 subsets against the independent validator, exact patch covers, clue deductions,
budgets, caches, adaptive cooling and shared snapshots. It does not launch a
fresh puzzle search. `SolverTests.swift` separately exercises initialization,
search lifecycle, cancellation and parallel logs. `SearchBenchmark.swift` is an
explicit opt-in benchmark for repeated fresh 5×5 trials; compilation is inert.
The `--lifecycle-only` argument to the solver test executable restricts it to tiny
fixed 1×1 lifecycle and ten-worker fixtures. These and the repair diagnostics
have passed. The actual saved failed run was repaired to 8045 with 17 connected
union checks and five candidate evaluations. Fresh-search benchmark runs remain
pending; this repair result is not a measured fresh-search solve rate.

The following continuous APIs are retained for experimentation:

```swift
let energy = Energy()
let fields = energy.CapitolCal(Board: board)
let scores = energy.RealAIMTest(Board: board, Target: config.Target)
let combined = energy.EnergyCal(Board: board, Target: config.Target,
    Factors: .init(realAIM: 2, symmetry: 1, discreteness: 1))
board.Energy = combined
```

`ColorBlocks` must already describe the proposed states. These functions read the
board without mutating it. `RealAIMTest` takes the clues explicitly: `-1` is blank,
and `0` is a real clue.

`EnergyCal` combines the AIM, symmetry, and discreteness matrices using three
relative factors. Factors default to `1, 1, 1`; each must be finite and
nonnegative, and at least one must be positive. The factors are normalized to
sum to 1, so the result stays within `[0, 1]`. A zero factor removes that
component's contribution. The returned matrix can be assigned to `board.Energy`.

`DiscretenessTest` returns a board-sized cell matrix. An edge with strength `p`
scores `tan(2 * min(p, 1-p)) / tan(1)`: 0 at either endpoint and 1 at 0.5.
Each cell receives the mean of its existing incident edge scores, using the
actual neighbor count at boundaries. A single cell with no edges scores 0.

Each UUID has a `CapitolField` containing `(row, col, probability)` candidates in
row-major cell order, one per cell. Coordinates are continuous, with integer
coordinates at cell centers. Probabilities are numerical integration weights:
they sum to 1 within each block and approximate a normalized area distribution.
This finite quadrature is not an analytic continuous density. Exact capitols
use a point mass (one weight of 1, all other weights 0).

For tentative fields, the seven nonidentity D4 transformations are aligned at
the bounding-box center. A transformation's weight is `exp(-8 * (1 - overlap))`,
where overlap is the fraction of unit-square area shared with the original
shape. Candidate masses favor cells with low weighted squared displacement
under those transformations. Each position moves halfway toward its weighted
transformed position, capped at 0.49 cell lengths per axis to preserve ownership.
The masses are normalized using a stable exponential calculation. These choices
define a heuristic distribution; they are not calibrated statistical probabilities.

A connected exact symmetric state has a capitol only when every nonidentity
symmetry fixes the same single cell. Exact symmetric states without capitols
and disconnected UUID groups still have normalized fields, but their
`canBeDestination` flag is false. Asymmetric connected states provide tentative
destinations during the search.

Travel follows the orthogonal cell graph. Edge costs are the smaller of the two
state sizes. A candidate is attached to its owning cell center by a fractional
Manhattan terminal segment, charged at that state's size. This is a numerical
extension of the puzzle's graph, not an unrestricted path through the plane.

The capitol locations of different states are modeled independently. For each
clue, compute the expected error of the nearest capitol using
`abs(cost - target) / max(cost, target, 1)`. The calculation uses survival
probabilities to avoid enumerating all combinations of candidate locations.
Every energy lies in `[0, 1]`; blank cells get the global mean clue energy.
No clues or no eligible destinations give energy 1. `RealAIMTest` is a search
heuristic and must be combined with `SymmetricalTest` when checking validity.

Run the standalone checks from the repository root:

```sh
swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
  JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
  Tests/SymmetryEnergyTests.swift -o /tmp/symmetry-energy-tests
/tmp/symmetry-energy-tests

swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
  JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
  Tests/RealAIMEnergyTests.swift -o /tmp/real-aim-tests
/tmp/real-aim-tests

swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
  JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
  Tests/CombinedEnergyTests.swift -o /tmp/combined-energy-tests
/tmp/combined-energy-tests
```

Compile the solver integration checks without running them (the test provides
its own entry point, so `main.swift` is excluded):

```sh
swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
  JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
  JaneStreetPuzzle_Oct26/RunConfig.swift JaneStreetPuzzle_Oct26/Runners.swift \
  JaneStreetPuzzle_Oct26/Logger.swift JaneStreetPuzzle_Oct26/SearchSupport.swift \
  JaneStreetPuzzle_Oct26/Validation.swift JaneStreetPuzzle_Oct26/Solver.swift \
  JaneStreetPuzzle_Oct26/ExactSearch.swift JaneStreetPuzzle_Oct26/RegionRepairs.swift \
  JaneStreetPuzzle_Oct26/SharedSearch.swift JaneStreetPuzzle_Oct26/SavedRunRepair.swift \
  Tests/SolverTests.swift -o /tmp/janestreet-solver-tests
```

These cover independent copies, component construction, the exact example
answer of 8045, deterministic proposals, bounded search, cancellation, reheating,
restarts, ten-worker isolation and seed assignment, parallel cancellation,
aggregate statistics, and JSONL log decoding. Execute the resulting test binary only when
ready to run checks.

Compile the fixed-fixture diagnostics or opt-in benchmark using the same source
list (excluding `main.swift`), replacing `Tests/SolverTests.swift` with
`Tests/RepairTests.swift` or `Tests/SearchBenchmark.swift` respectively. Use `-O`
for timing measurements. The benchmark executable remains idle unless passed
`--run [trials] [seconds-per-trial]`; defaults are five trials of twenty seconds,
each using ten workers. It writes solve rate inputs, elapsed times, wrong-clue
counts, exact evaluation counts and log paths to `benchmark.json` in the project
logs folder. Fresh-search reliability must be measured separately from the fast
saved-board repair; no speedup or 11×11 solve guarantee follows from that fixture.
