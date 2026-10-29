# Time to verified solution — no experiment cutoff

Latest saved status: 2026-10-29T12:38:52+09:00. Search seed 20261029.

Real clue density: **33/121 = 27.27%**. The 5×5 keeps **7/25 = 28.00%** of its original clue positions (mask seed 5101). The generated 7×7 uses **13/49 = 26.53%** (maker seed 7101). These are the nearest integer counts to the real ratio. Both candidates receive exactly the same clues and rules for each size.

| Puzzle | Implementation | State | Time |
|---|---|---|---:|
| 5×5 | Current discrete | Verified solution | 9.148 seconds to solution |
| 7×7 | Current discrete | Stopped by user; unsolved | 331 seconds observed; solve time unknown |
| 5×5 | Historical continuous | Stopped by user; unsolved | 331 seconds observed; solve time unknown |
| 7×7 | Historical continuous | Stopped by user; unsolved | 331 seconds observed; solve time unknown |

**Unsolved elapsed time is not a measured solve time. No winner or finite speedup is claimed while a candidate is still running.** These runs had no experiment time cutoff and were stopped at the user’s request. No searches remain running. Practical iteration/restart caps are raised to approximately 2.3×10¹⁸; the engine’s finite configuration time is set to the largest finite Double. No host subprocess timeout is used.

## Method

The current solver uses unchanged current core source, one CPU worker and CPU paths. The earlier continuous solver uses core sources recovered from Git revision `e23adc5f27835f932c80b6674c02ba5211c8430a`, one worker, its original moves/continuous objective/temperature strategy, and raised termination caps. A small observation-only patch saves its best board in existing progress events. It does not change proposals, acceptance or scoring.

The small discrete baseline runs first. The remaining three one-worker searches then overlap on this shared machine so a stalled candidate does not block the others. These elapsed times describe this setup; they do not isolate integer versus floating-point instruction cost, and search strategies differ between the actual implementations. This is one paired seed initially, not a statistically established runtime distribution.

Every finished candidate is independently checked in Python for connectivity, all seven nonidentity symmetries, the unique common fixed-square capitol rule, exact integer shortest paths, every clue, and answer arithmetic. Fixture witnesses pass the same checker. Removing clues can admit multiple solutions; uniqueness is not asserted and valid alternative answers count.

The 7×7 generator merges adjacent singleton regions only when the union remains symmetric (maximum 16 cells); cell 0 remains singleton to guarantee a capitol. Exact distances are computed before choosing 13 clue positions uniformly without replacement. No clue position is forced. The 5×5 retains a seeded uniform subset of seven of the ten published clues.

All builds use isolated `/private/tmp` folders. Core source, installed workers, credentials, live databases and coordinator state are unchanged. Earlier runs with a 30-second cutoff and denser clues are superseded and do not determine the comparison.

## Files

- [Live status](status.json)
- [Completed results](results.json)
- [Exact fixtures and witness partitions](fixtures.json)
- [Build/source metadata](metadata.json)

Rerun with a new output directory:

```sh
python3 experiments/discrete_vs_continuous/run_until_solved.py --output /private/tmp/jsp-until-solved-new
```
