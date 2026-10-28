# Partial-repair corrections — 2026-10-28

The two reproduced repair barriers in [HISTORY_AUDIT.md](HISTORY_AUDIT.md) are
fixed locally. **These changes have not been deployed.** No production process
was contacted or restarted during implementation. Tests used temporary builds;
the existing `.build/release/janestreet-puzzle` executable's SHA-256 is unchanged.

## Repair states and completed solutions

`ShapePolicy.feasible` retains all existing clue deductions, including minimum
areas, forced singletons, possible capitols and internal-route bounds.
`ShapePolicy.repair` accepts only connected, symmetric shapes and permits
temporary clue mismatches. Actual clues still determine exact scoring and the
independent final validator; the relaxed generator does not change the target.

- Local covers retain geometrically legal existing states even when those
  states fail final-solution clue deductions.
- Local covers no longer require an already-wrong exterior printed 1 to be
  repaired by the current patch. Strict feasibility mode keeps this pruning.
- Merge repairs receive the same separation. Strict and relaxed merge scans
  have distinct cursor keys, including objective, weights and merge size.
- Orbit transfers and splits check connectivity and symmetry while allowing
  intermediate clue mismatches.
- Whole-board initialization continues to request strict feasibility. Final
  success still requires every clue and state to pass `ExactValidator`.

Ordinary patch discovery alternates clue-guided generation and broader
geometry-only generation. The two policies have independent bounded catalog,
usage, orbit-sampling and capitol-growth caches; neither can poison or exhaust
the other's discovery state. Guided large-shape generation remains available,
and the general large-patch route receives the broader discovery policy.

No configuration or checkpoint fields changed. Existing saved boards remain
compatible. Patch, merge, catalog and time limits are unchanged. The additional
repair discovery caches each retain at most 64 active patches, increasing bounded
worker-local cache memory. Search is still heuristic and not exhaustive.

## Regressions and verification

Six new package regressions verify:

1. The exact five-wrong-to-three-wrong cover now survives under all three worker
   objectives, while strict feasibility rejects that unfinished cover and
   accepts its fully valid solution.
2. Merge enumeration evaluates the formerly blocked improvement, even after
   the same topology was consumed by a strict scan.
3. Boundary repair can improve a board through unmatched capitol clues without
   declaring a false solution.
4. Strict and repair discovery keep separate candidates and sampling/growth
   cursors. Disconnected and asymmetric shapes remain forbidden.
5. All six states in the historical seven-wrong leader that fail final-board
   deductions can be retained by local covers. Strict covers still reject them.
6. Scheduled repair proposals actually reach both discovery policies.

An existing standalone test for strict singleton-neighbor pruning now explicitly
requests strict feasibility. Its original rejection and zero-evaluation assertions
remain in place; it was not removed or weakened.

Validation passed:

- **75 package tests in 12 suites**, including recovery, reporting, independent
  validation, GPU-path checks and the six new regressions.
- **All six standalone core suites**, including exhaustive 3×3 geometry/scoring,
  129 independently derived deduction fixtures, route-pruning comparisons,
  large-state repair, saved-board repair, cancellation and solver lifecycle.
- The known full-puzzle acceptance fixture still validates all 33 clues, eight
  capitols and answer 408951. It is not supplied to the discovery benchmark.
- `git diff --check` passed.

## Bounded replay of the historical leader

Same comparison setup as the history audit: one CPU worker, match objective, no
shared archive, three seeds and six seconds per seed. The initial board is the
exported seven-wrong leader. All logs and binaries stay in temporary directories.

| Measurement, three seeded trials combined | Audited `91d4012` | Corrected working tree |
|---|---:|---:|
| Empty iterations | 48.13% | **14.15%** |
| Completed covers | 3,367 | **12,693** |
| Evaluations | 11,290 | **53,505** |
| Best wrong-clue count in each trial | 7 / 7 / 7 | 7 / 7 / 7 |

Three separate fresh starts finished at **15, 14, 17 wrong**, versus **18, 18, 18**
in the audited version. An earlier corrected-code probe produced 14, 14, 15;
wall-clock cutoffs vary across runs. These measurements demonstrate recovered
proposal productivity and broader partial-state access. They do not establish a
full-puzzle solve rate or demonstrate a six-wrong discovery. Frequent archive
reanchoring remains a separate policy concern requiring a controlled comparison.

Raw final measurements and source/fixture fingerprints are in
`partial-repair-probe-results.json`. Reproduce without touching production:

```sh
python3 investigation/run_history_probe.py investigation/history-fixture.json working-tree
python3 Scripts/run_core_tests.py
```

For package tests, use a separate SwiftPM scratch directory to avoid replacing
an executable that a local worker may use on its next launch. This change was
tested with `swift test -c release --scratch-path /private/tmp/jsp-partial-repair-2vsxrfxn/build`.
