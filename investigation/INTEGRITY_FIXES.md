# Integrity corrections — 2026-10-28

All three findings from `INTEGRITY_AUDIT.md` are corrected locally. **Nothing has
been deployed and running workers have not been restarted.** Earlier uncommitted
changes were preserved.

## Local repairs and strict feasibility

`cover` now distinguishes a strict feasibility search from local repair. Initial
whole-board construction explicitly enables strict pair-area pruning. Repairs
do not reject improvements merely because the fixed exterior still violates a
final-board pair bound. Per-state geometry checks and the independent success
validator remain in place.

The original 3×3 reproduction now improves **five wrong clues to one** under all
three worker objectives. Strict feasibility mode still rejects that imperfect
cover, and accepts the fixture's full valid solution. The source board is unchanged.

## Large-state exploration

The large archive now admits candidates from both anchored growth and generic
orbit sampling; ordinary patch catalogs can feed it as well. The generator
discovers and archives the legal **36-cell capless bar** from the audit's 1×37
puzzle, and the rebuild path produces a fully validated solution.

Every other large repair turn reserves its entire deadline for the general patch
lane. Archive turns receive at most half the repair deadline, leaving the rest
for fallback. Candidate retention respects that archive deadline too. A regression
test ensures a general turn does not invoke archive exploration even when the
archive already holds a valid large solution candidate.

## Catalog replacement and retained progress

Saturated catalogs keep an irredundant coverage backbone, reserve admission space
for fresh candidates, and fill the bounded remainder from retained alternatives.
Tiny full catalogs can exchange a shape only when previously represented cells
remain represented. Newly represented cells receive priority. Required singleton
coverage survives replacement. If the user explicitly lowers capacity below that
needed for prior coverage, keeping every previously represented cell can be
impossible; retention then prefers broader coverage within the new limit.

Sampling continues when a catalog is full, rather than stopping at the admission
cap. Union coverage is preserved at unchanged capacity; it is not a promise that
the shapes form a compatible tiling or that every solution shape remains retained.

Both growth and sampling cursor caches now match the 64 active catalog slots.
Bounding boxes are stored as compact interval-pair indexes instead of four Ints
per box. The nine-patch audit fixture now resumes the original cursor with two
samples instead of losing it and starting over. All caches remain bounded and
may still evict progress beyond capacity.

## Validation

- **69 package tests in 11 suites passed**, including six new integrity regressions.
- **All six standalone core suites passed.**
- The audit's **65,535** 4×4 geometry masks and **6,030** deduction fixtures have
  no failures.
- A **3,000-case** comparison found no improving reference cover blocked by the
  production local cover path.
- The full-puzzle acceptance fixture still verifies all 33 clues, eight capitols,
  row sums and answer **408951**.
- `git diff --check` passed.

The source changes introduce no new configuration fields or checkpoint schema.
Search remains bounded and heuristic; these checks do not establish a fresh
11×11 solve rate or uniqueness. The general patch/merge size limits still apply.

```sh
swift test -c release --skip-update
python3 Scripts/run_core_tests.py
python3 investigation/run_integrity_audit.py
```
