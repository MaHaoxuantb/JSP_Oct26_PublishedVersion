# Search audit — 2026-10-28

## Follow-up integrity findings

The later integrity audit found a cross-state pruning regression, an odd-only
large-state archive, and frozen saturated catalogs. All three have now been
corrected locally, with explicit regressions. Active sampling cursor capacity now
matches catalog capacity too. See [the corrections and validation](investigation/INTEGRITY_FIXES.md)
and [the historical audit](investigation/INTEGRITY_AUDIT.md).
Deployment and worker restarts remain on hold.

## Local correction status

Follow-up search improvements have also been implemented locally: propagated
singleton/short-path area bounds, growth around unnumbered capitols, connected
orbit generation with retained cursors, and a dedicated large-shape repair lane.
The full puzzle is now an acceptance fixture, separate from a bounded discovery
benchmark. See [implementation and validation](investigation/IMPLEMENTATION.md).
These changes have **not** been deployed or used to restart running workers.

All four findings below have been corrected in the local working tree. Deployment
is on hold at the user's request; running workers have not been restarted.

- The evaluation context retains the best common-ranking discovery from individual,
  cached, and batched evaluations. The solver saves, shares, and reports it independently
  of the annealing walk. The original one-iteration reproduction now reports seven
  wrong clues while its residual-objective current state still has eight.
- Merge cursors are keyed by partition, ranking mode, persistent weights, and maximum
  merge size. An unchanged scan still resumes; changed ranking rules receive a separate
  bounded scan. Explicit saved-board repair uses the common ranking as well.
- Eligible archive exchanges alternate leaders with a separate diversity cursor,
  reaching every retained entry even when independent explorers request assignments.
- Calibration starts a fresh measurement deadline after initialization and excludes
  empty attempts from the initial work-rate estimate.

Validation: **55 Swift tests in nine suites**, including eight new discovery regressions;
**11 Python process tests**; and **all six standalone core suites** passed locally.
`Scripts/run_core_tests.py` now runs the core suites in CI alongside the package tests.
This fixes the reproduced correctness problems but does not establish a full-puzzle
solve rate or a total-job estimate.

## Original inspection findings (before correction)

The current working-tree code has reproducible defects that can suppress intermediate discoveries, reduce exploration, and distort calibration. It cannot yet be cleared as a cause of the reported plateau. These reproductions establish code behavior; they do not establish which defects affected the particular running fleet or guarantee that fixing them will solve the full puzzle.

This was an inspection. No production source or configuration was changed. Existing uncommitted changes were included in the review.

## 1. Evaluated improvements can be omitted from the saved best (high priority)

Locations: `RegionRepairs.swift:90`, `RegionRepairs.swift:370`, `RegionRepairs.swift:545`, and `Solver.swift:161`.

Merge, cover, and boundary searches select a single candidate using the worker's objective. The main loop updates its common best only from the accepted current state. Residual and persistent objectives can prefer a candidate with more wrong clues but lower weighted error. A candidate with fewer wrong clues can therefore be evaluated, then discarded from best-candidate reporting. Rejected proposals can also contain improvements under the common ranking.

Reproduction: a one-iteration residual run evaluates a candidate with **7 wrong clues and error 0.7423611111**, but saves/reports **8 wrong clues and error 0.6158496732**. Both have zero structural issues. The seven-wrong board is present in the evaluation cache, confirming it was actually evaluated. A fully valid solution is specially prioritized; this finding concerns intermediate improvements.

Correction: preserve a common-ranking incumbent across all evaluated candidates, independently of the candidate chosen for the annealing walk. Include discoveries from batched merges, covers, boundary changes, and rejected proposals. Feed that incumbent into checkpoints and distributed reports while retaining objective-specific candidates for exploration.

## 2. Merge-cache reuse suppresses moves under changed ranking (high priority)

Locations: `RegionRepairs.swift:80–99`, `SearchSupport.swift` (`mergeCursors`), `Solver.swift:149`, and `Distributed/Client.swift:189–215`.

The merge cache stores a consumed enumeration cursor keyed only by partition labels. It does not retain candidate results for reranking. The same cursor is used for ordinary objective-based repairs and exact-ranking saved-best repairs, and survives distributed jobs that change the worker objective. Persistent-objective weight changes can also change which moves are desirable.

Reproduction using the same board: the residual scan checks seven unions. A subsequent exact-ranking scan with that context checks **zero additional unions and returns nil**. A fresh context finds the seven-wrong-clue improvement. The defect therefore prevents the saved-best repair from recovering an improvement overlooked under the other objective.

Correction: retain reusable feasible merge results and rerank them, or separate/invalidate enumeration state when ranking semantics change. Account for exact-ranking mode, persistent weights, and relevant enumeration settings. Preserve bounded work and memory.

The fixed 3×3 reproduction has clues:

```text
10  9  7
10 -1 12
 4  4  8
```

and source region labels:

```text
0 1 2
1 1 1
1 1 3
```

## 3. Archive selection skips half the entries (medium priority)

Location: `SharedSearch.swift:75`.

The selection expression uses an even ticket for diversity turns and then applies `ticket % entries.count`. With the default eight-entry archive, diversity turns can only choose indexes **0, 2, 4, 6**. Odd turns choose the objective leader; other odd-indexed entries are never selected by this mechanism.

Reproduction: 64 match-objective assignments against a stable archive of eight distinct candidates visit exactly `[0, 2, 4, 6]`. Coordinator job initialization separately samples the archive randomly, so this is a defect in local archive exchange, not a claim that these boards can never reach any worker.

Correction: use an independent diversity cursor or random selection that can reach every entry. Test stable archives with even capacities and mixed worker objectives.

## 4. Calibration counts attempts after the search deadline (medium priority)

Location: `Distributed/Client.swift:402–414`.

Calibration sets the context deadline before initialization, but starts its measurement timer after initialization and runs for the entire calibration duration again. During the extra tail, repair functions see an expired context and return no proposal; the outer loop still increments its iteration counter.

Reproduction: run the calibration function with one CPU worker, the full puzzle, and a 0.1-second calibration duration. An instrumented copy adds counters without changing its control flow. Initialization exhausts that deadline, and the measured loop counts tens of thousands of expired-deadline/no-proposal attempts, producing a rate in the hundreds of thousands per second. Counts vary with scheduling and hardware. The same mismatched clocks exist at the default duration; the fraction affected depends on initialization time.

Correction: use a consistent measurement deadline, or reset the context deadline when timed measurement begins. Distinguish attempted iterations from effective proposals/evaluations. Check calibration under slow initialization. Calibration rates feed assignment budgets and repair-time sizing; dashboard rates later use reported work, so this does not by itself explain all displayed iterations.

## Checks that passed

- `swift test -c release --skip-update`: **47 tests in eight suites**, including client progress, persistence, coordinator recovery, dashboard reporting, GPU certificates, fallback, and actual Metal/CPU comparisons.
- All six standalone core suites, compiled with optimization and `PATHS_CPU_ONLY`: symmetry energy, real-AIM energy, combined energy, repair, optimization, and solver tests.
- Coverage includes all 511 nonempty 3×3 shape masks, independent geometry/distance comparisons, 129 legal-partition constraint fixtures, heap/scan equivalence, cache/snapshot isolation, route-bound comparisons, multiword masks, large-state splitting, the example answer 8045, annealing floors, deterministic proposals, restarts, cancellation, and checkpoint roundtrips.

No scoring-arithmetic, shortest-path, geometry, or tested pruning defect was found. The main search uses exact integer distances and `SearchQuality`; the legacy continuous `Energy` API does not select its moves. Passing these checks is evidence for the tested cases, not a proof of the entire solver or a verification of the original puzzle transcription.

## Coverage gap and remaining limits

`Package.swift:35–39` includes only `DistributedTests` in the package test target. The six core suites in `Tests/` are separate executables and are not run by the current CI workflow. Existing archive tests check differing tickets, not coverage of archive entries; existing merge tests check that scans are not repeated, not that changing objectives remains correct. Add regression coverage for the four findings and include the core suites in routine validation.

The audit did not inspect a snapshot of the live coordinator database or verify the deployed binaries. It did not run a long full-puzzle search. Shape catalog, patch size, cover count, and time limits also make the search heuristic even after correctness defects are fixed.

Temporary reproduction sources and output are in `/tmp/jsp-code-audit/`: `DiscoveryAudit.swift`, `Calibration.swift` (instrumented calibration copy), and `findings.txt`. The standalone core-check runner and compiled diagnostics are there as well. These diagnostics assert the observed defects; convert them into regression assertions for corrected behavior when implementing fixes.
