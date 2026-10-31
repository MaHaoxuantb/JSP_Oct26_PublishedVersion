# JSP-Oct26-Search-Escape

©2026 ThomasB

Author: ThomasB

A standalone, reusable solver portfolio for the original 11×11 puzzle. The
[screening report](results/20261030-screen/JSP-Oct26-Search-Escape-Report.md)
records the quick experiments before live integration, their limits, and the
subsequent independently checked 13-wrong-clue discovery. The original puzzle
has not been solved. Raw trials and validation records accompany the report.

## Modules

- `Population.swift`: synchronized canonical archive, protected overall best,
  distinct alternatives, migration, pool progress clocks and independently
  re-evaluated external candidates. Working and retained states are separate.
- `AdaptiveRepair.swift`: actual scope targets, neighbor/block/disagreement/
  capital/route operators, measured operator reward per CPU time, protected
  searches, compatible checkpoint restoration and bounded exhaustion memo.
- `Worker.swift`: a single native eight-thread process. Two incumbent repair
  workers, four independent/diverse islands, one broad/recombination worker,
  one exact-feasibility worker. Every worker keeps private search/RNG/oracle data.
- `cpsat.py`: an independent integer exact-cover and Bellman-distance model.
  Complete shape enumeration is available for released patches of at most 16
  cells. Restricted whole-board domains are explicitly labeled incomplete.
  CP-SAT minimizes wrong clues then absolute distance error; the incumbent uses
  the original normalized-residual secondary objective after independent checks.
- `sidecar.py`: optional one-core local CP-SAT search. It reads the Mini mirror,
  proposes small-neighborhood improvements and occasional restricted whole-board
  candidates, validates them and writes puzzle-matched JSON atomically to Mini.
  It stops when the campaign stops and never silently follows another run.
- `run.py`: strict release-7 sequential segments, independent validation of every
  worker result, incumbent preservation, stagnation-clock carry and compatible BP
  stack restoration. New SA random streams are used at segment boundaries.
- `monitor.py` and `web/`: read-only measured dashboard, retained-best and latest
  complete-state energy, archive/migration/protected-work/CP-SAT telemetry.
  Exact partial branches do not have complete-board energy; that lane reports
  its source/best complete candidate alongside actual expansion counts.

The optional `GuidedSearchExchange`/`GuidedIntensifier` hooks are in the shared
framework. Default engine callers keep their legacy policy. A diversification
import never worsens the engine's retained best. Protected jobs retain their
fixed exterior and bound mode; they are not rebased on arbitrary later boards.

## Build and verification

Use a fresh scratch directory:

```sh
python3 experiments/search_escape/build.py /private/tmp/jsp-escape-build
```

SwiftPM uses a symlink to the root software release authority. The standalone
builder links that authority directly, then verifies strict/current, older
rejection, explicit minimum-0 transition and future rejection with the existing
preflight. No installed production binary is overwritten. Native Swift 6.1+
is required; this uses the existing shared UInt128 shape representation.

Run `swift test --build-system native --disable-sandbox --package-path
experiments/search_escape --scratch-path /private/tmp/jsp-escape-tests -c release`
with module caches in scratch. All 16 shared tests and six escape-policy tests
passed locally. The Mini lacks XCTest; native builds and process probes are
reported separately. CP-SAT requires an isolated Python environment with
`requirements-cpsat.txt`; it is optional to native Swift search.

`screen.py` is the two-seed, four-thread 30-second mechanism screen.
`report.py` generates its evidence report. Probe clocks 3/8/16 seconds are not
used in live search, which uses 60/180/600 seconds. These small screens do not
establish solve-speed superiority. Local construction/test activity overlapped
some probes; no controlled throughput ranking is claimed.

The live campaign is recorded in `JSP-Oct26-Search-Escape-Run.md`. A STOP file
requests cooperative cancellation and prevents later segments. Immutable trial
JSON may be exported; live SQLite files are never moved or synchronized.
Fan, power and cooling controls remain unchanged.

Release 7 preserves the release-6 search policy while caching board edges and
nearest archive distances. A component benchmark verified identical retention
on 20 shuffled cases and consumed checksums in 100 varied timed cases. Its
component speedup is not a solver/time-to-solution claim. The version-6 dataset
and source remain frozen, and compatible repair stacks are carried into the
version-7 run.


## Current structural continuation

Release 10 adds optional `SearchStrategy` hooks and Swift modules for clue
deductions, direct large symmetric-region construction, finite-domain tiling,
and independent structural checkpoints. The incumbent remains protected by
original exact quality. `structural_sidecar.py` uses one local CPU core for
restricted whole-board CP-SAT with hard necessary deductions. Zero necessary
violations is not a solution certificate.

See [JSP-Oct26-Structural-Search-Run.md](JSP-Oct26-Structural-Search-Run.md) and
[the implementation report](results/20261031-structural/JSP-Oct26-Structural-Search-Report.md).
The current queue has two 3,000-second segments and eight Mini CPU workers.
