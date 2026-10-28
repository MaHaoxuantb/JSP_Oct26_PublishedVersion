# Local search improvements — 2026-10-28

**Follow-up audit and corrections:** a local-repair pruning regression and search
limitations were found after these checks. All three findings have now been
corrected locally; see [corrections and validation](INTEGRITY_FIXES.md) and the
[historical integrity audit](INTEGRITY_AUDIT.md). Deployment remains on hold.

Implemented at the user's request following `REPORT.md`. **Not deployed. Running
workers and coordinator state have not been changed.** Existing uncommitted work,
including the earlier discovery/calibration fixes, was preserved.

## Changes

- `ExactSearch.swift`: fixed-point singleton deductions and distance upper bounds;
  adjacent interval gaps; two-edge middle-area/endpoint-sum bounds; three-edge
  middle-area sums; overflow-safe arithmetic. The deductions reject only shapes
  that cannot occur in a valid completion. Inconsistent clues do not cause an
  arbitrary singleton to be selected.
- `RegionRepairs.swift`: applies pair-area bounds during partial exact covers.
  Initial catalogs now use the broader growth mechanism. Large repair turns also
  attempt explicitly grown large shapes before falling back to ordinary patches.
- `ShapeGrowth.swift`: candidate capitols include unnumbered cells. Connected
  symmetry-orbit walks retain their current shape and anchor/transform position.
  Orbit spaces exclude incompatible zeroes, forced singletons and extra cells
  fixed by the selected symmetry, then propagate connectivity and feasible-area
  restrictions. A prefix may continue growing even when its current area or extra
  symmetries prevent it from being a completed state.
- Generic orbit catalogs retain bounding-box, transform and mask cursors. They
  combine small exhaustive cases, single orbits/complements, connected growth,
  and a random lane. The latter preserves opportunities to generate capless
  states whose individual orbits can be disconnected.
- The large-state lane keeps up to 512 grown shapes. When trying one, it rebuilds
  all intersected source states, within `largePatchCells`, and fixes the proposed
  shape while covering the rest. It cannot silently return a cover that omitted
  the proposed shape. The source board remains unchanged.
- `SearchSupport.swift`: worker-local bounded cursor caches and a bounded large
  shape archive. No new configuration fields or checkpoint schema changes.
- `ShapeGenerationTests.swift`: the full puzzle is a correctness fixture only,
  separate from search. Tests also exercise sound deductions, sparse clue sets,
  unnumbered anchors, invalid growth prefixes, capless shapes, resumed cursors,
  deadlines, large repairs and all-forbidden-orbit termination.
- `benchmark_shape_discovery.py` and `ShapeDiscoveryBenchmark.swift`: opt-in
  bounded candidate discovery, without reading a solved partition, starting
  annealing, or connecting to a coordinator.

The normal 32-cell patch allowance and existing large-repair cadence remain.
Large candidate exploration runs on large turns inside the existing repair
deadline. Cursor and archive eviction, work limits, and deadlines keep the search
heuristic; none of this provides an exhaustive solve or uniqueness guarantee.

## Validation

- **63 Swift package tests in 10 suites passed**, including all eight new
  shape-generation tests and the pre-existing discovery/calibration regressions.
- **All six standalone core suites passed**, including all 511 nonempty 3×3
  shape masks, independent geometry/distance checks, legal-partition constraint
  fixtures, exact-cover/repair checks, solver lifecycle, cancellation and logging.
- New deduction soundness checks preserve **387** independently validated small
  partition/clue fixtures (full and alternating sparse clues).
- The full-puzzle fixture passes both evaluators with all 33 clues, eight capitols,
  the expected row sums, and answer **408951**. Its capitol states also survive the
  new orbit-space restrictions under each of their symmetries.
- `git diff --check` passed.

The package tests needed permission to access Swift's compiler cache outside the
workspace. All fixtures ran locally; isolated test servers used temporary state.

## Bounded discovery measurements

`shape-discovery-benchmark.json` records five seeds, each receiving 2,048 growth
steps and 4,096 generic orbit masks. No solution shapes were supplied.

| Metric | Range over five seeds |
|---|---:|
| Distinct permitted shapes | 2,163–2,357 |
| Irregular shapes larger than 32 cells | 1,660–1,839 |
| Unnumbered capitol positions represented in emitted shapes | 26–28 |
| Unnumbered anchors directly visited by growth | 15–20 |
| Local elapsed time per seed | 0.206–0.233 seconds |

These are individually permitted shapes, not compatible complete partitions.
They are evidence of broader candidate discovery, not a measured improvement in
full-puzzle solve rate. The largest emitted candidates can still be globally
incompatible with the clues or with each other. No fresh full-puzzle solution or
uniqueness proof is claimed.

The earlier `REPORT.md` describes the baseline investigation. Its cold-catalog
measurements are not directly comparable with this benchmark's different work
allocation. `swift-inspection.txt` was regenerated during implementation and
describes an intermediate revision; use the package fixture and the separate
discovery benchmark for the final checks.

## Reproduce

```sh
swift test -c release --skip-update
python3 Scripts/run_core_tests.py
python3 Scripts/benchmark_shape_discovery.py --run 5 16
```

Deployment and worker restarts remain on hold until the user authorizes them.
