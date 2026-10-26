# JaneStreetPuzzle_Oct26

Swift experiments for the symmetry, capitol, and travel-cost puzzle in the supplied image.

The parallel solver has been compiled but has not been run or performance-tuned.
The integration checks are prepared for later execution; compilation alone does
not establish that the search finds a solution.

`main.swift` is an explicit launcher. `Solver.swift` contains the three search
functions: `Initialization.start` grows a random connected partition,
`Iteration.OneIteration` proposes and evaluates one candidate, and `Main.Run`
manages annealing, reheating, restarts, stopping limits and logging. Search
helpers live in `SearchSupport.swift`; exact puzzle verification lives in
`Validation.swift`.

Build without running:

```sh
swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
  "$PWD"/JaneStreetPuzzle_Oct26/*.swift -o /tmp/janestreet-puzzle
```

When ready, `/tmp/janestreet-puzzle --run` explicitly starts the search. Launching
without `--run` leaves it idle. The default `RunConfig` still uses the 5x5 example,
seed 20261026 and factors 2:1:0.25. Set the
dimensions and target together before switching to the 11x11 puzzle.

The launcher uses `ParallelSolver.run` with `RunConfig.workerCount = 10`.
Ten independent annealing searches run on Swift's concurrent executor, each
with its own board, RNG, energy cache and logger. The OS schedules CPU cores;
this is ten concurrent workers, not a guarantee of ten dedicated physical cores.
Set `workerCount = 1` for a single search. The iteration, restart and time limits
apply to each worker (currently 500,000 iterations, 20 restarts, 1,000 seconds).
Worker 1 uses the configured seed; the remaining seeds are deterministically
offset. A worker's random sequence is reproducible; scheduling, wall-clock
limits and early cancellation can change the final parallel result.

The first verified solution cancels sibling searches cooperatively. All workers
save their final snapshots and close their logs before returning. Otherwise the
lowest-energy candidate wins, with worker ID breaking ties. Only immutable,
`Sendable` result snapshots cross worker boundaries. Worker errors cancel siblings
and propagate to the launcher. No candidates migrate between workers.

Each launch creates `<project>/logs/parallel-<UUID>/`: the summary JSONL is at the root,
and each `worker-N/` contains that worker's compact search log. The default log
directory is derived from `RunConfig.swift`'s source path, so Xcode runs write
inside the project rather than DerivedData. For CLI builds, pass absolute source
paths as above to preserve this location when launching from another directory.
An explicit `RunConfig.logDirectory` can override the destination. The summary
records completion, seed, log path and result for each worker, then aggregate
statistics and the best final snapshot. Workers print labeled live progress
including current/best energy, temperature and the best candidate's unmatched
clue count. Progress is checked every `progressInterval` iterations (100 by
default), with at least `progressTimeIntervalSeconds` (2 by default) between
periodic updates per worker. Improvements, reheats, restarts and completion print
immediately. A console lock keeps each line intact across workers, and direct
stdout writes keep output live when redirected. File logs receive the same events.

The proposal mix is 65% boundary-cell transfers, 10% merges, 10% splits, 10%
patch repartitions and 5% relationship changes, before retries for inapplicable
moves. Selection favors high-energy cells while retaining a 20% uniform choice.
Every applicable proposal gets a full-board evaluation and an independent exact
validation. Worsening candidates can be accepted with `exp(-delta / temperature)`.
The default temperature starts at 0.03, multiplies by 0.997 per iteration and
stops cooling at 0.0001. After 1,000 iterations without an epoch improvement,
reheat once; on the next stagnation restart, up to the configured restart limit. The factors
remain fixed throughout the run. These are initial tuning choices.

`Board.copy()` creates independent candidates and saved best states. Connected
components are rebuilt from relationships >= 0.5 using flood fill. A verified
solution is hardened to binary relationships without changing its partition.
Only exact validation can produce a puzzle answer; timeout, cancellation,
iteration-limit and restart-limit results retain the best candidate and its
remaining structural issues and clue mismatches. Budgets and cancellation are
checked between iterations, so one evaluation or initialization can overrun
the time limit. The loop periodically yields for cooperative cancellation.

`Logger` streams one JSON object per line to the configured directory. Logs contain:

- The full configuration and random seed.
- Periodic progress and aggregate per-move acceptance statistics, improvements,
  reheats, restarts and failures. Individual proposal decisions and edge changes
  are omitted, including rejected candidates.
- Full snapshots only at termination: each worker's best candidate and the
  overall best result, with canonical integer state labels, both relationship
  arrays, the cell energy matrix and exact validation details.
- Every snapshot's `candidateResult`: region-size matrix, row sums and their
  sum of squares, even for an unsolved candidate. `validation.valid` determines
  whether this is a verified answer.
- The final stopping reason and exact validation status. The console also prints
  the best candidate's matrix, puzzle score and optimization energy at termination.

The logger keeps only the latest 256 entries in memory and flushes milestones
to disk. Write errors abort the run. A seed reproduces search choices when the
configuration is identical; timestamps, UUIDs and time-limited stopping points
can differ. Logs are ignored by Git. Snapshots support inspection; automatic
resume from a log is not implemented.

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
  Tests/SolverTests.swift -o /tmp/janestreet-solver-tests
```

These cover independent copies, component construction, the exact example
answer of 8045, deterministic proposals, bounded search, cancellation, reheating,
restarts, ten-worker isolation and seed assignment, parallel cancellation,
aggregate statistics, and JSONL log decoding. Execute the resulting test binary only when
ready to run checks.
