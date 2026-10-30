# Interim decision assessment — 2026-10-30, 11:31 JST

Enough evidence to choose the next development direction; insufficient evidence to
establish a final representation winner or a reliable fresh-start 11×11 solver.
The campaign continues running; this assessment does not change or stop it.

Snapshot: campaign `20261029-214421`, 176/360 valid terminal trials: 39 solved,
137 timed out; 4 running, 180 pending. No failed trials. Four interrupted attempts
from the explicit pause are separate from completed trial outcomes. A complete
matched block means one board and one seed tested under all eight conditions.
There are 22 complete blocks, with 22 outcomes per condition and 14 distinct
boards represented. All terminal observations in this snapshot belong to those
complete blocks, so comparisons do not favor a condition merely because it ran
on easier boards first. Repeated seeds are not independent new puzzles.

## Solving outcome, not evaluation throughput

| Representation | Regional | New BP | Solved / matched trials | Mean capped solve cost |
|---|---|---|---:|---:|
| discrete | off | off | 2/22 | 1127.9 s |
| discrete | off | on | 3/22 | 1053.7 s |
| discrete | on | off | 5/22 | 1044.3 s |
| discrete | on | on | 9/22 | 811.9 s |
| continuous | off | off | 4/22 | 1057.6 s |
| continuous | off | on | 5/22 | 998.6 s |
| continuous | on | off | 4/22 | 1067.9 s |
| continuous | on | on | 7/22 | 928.1 s |

Capped solve cost is observed solve time for successes and 1,200 seconds for a
timeout. It measures the fixed-budget decision; it is not an estimate of eventual
solve time. Solved-only medians can favor methods that solve only easy cases.

Discrete + regional + new BP is the provisional leader: 9/22 versus 5/22 for its
regional control without new BP. Its capped cost is 811.9 versus 1,044.3 seconds,
a 22.3% reduction. Continuous + regional + new BP is the strongest challenger,
7/22 and 928.1 seconds. Their direct matched comparison has 3 discrete-only solves
and 1 continuous-only solve; this is too little discordant evidence to settle
representation. Across all conditions continuous solves 20/88 and discrete 19/88.

Regional-on solves 25/88 versus 14/88 regional-off. New-BP-on solves 24/88 versus
15/88 new-BP-off. In corresponding paired comparisons regional adds 12 solves
and loses 1, while BP adds 10 and loses 1. These are descriptive observations;
shared boards, seeds, interactions and interim selection rule out treating all
88 pairs as independent population-level evidence. Regional-on jointly changes
focus and randomization width; their separate contributions are not identified.
B0 still contains ordinary bounded cover repair, so this is the incremental
benefit of the new BP method, not all branching versus no branching.

As a sensitivity check, giving each of the 14 represented boards equal weight
instead of giving each board/seed block equal weight retains the same leading
pair: discrete regional BP capped cost 782.1 seconds; continuous regional BP
874.9 seconds. This is not a new independent test.

## Scaling is the unresolved goal

| Size | Completed trials | Solved | Coverage limitation |
|---:|---:|---:|---|
| 5×5 | 40 | 29 | 5 of 9 board/seed blocks |
| 6×6 | 24 | 7 | 3 of 9 blocks |
| 7×7 | 48 | 2 | 6 of 9 blocks |
| 8×8 | 24 | 0 | 3 of 9 blocks; board n8-b1 has no terminal trial |
| 9×9 | 40 | 1 | 5 of 9 blocks |

That is only 3/112 validated solves on 7×7–9×9. The provisional best discrete
regional BP condition solves 1/6 at N=7, 0/3 at N=8 and 1/5 at N=9. Better residuals
are useful evidence of progress, but cannot substitute for exact solves on the
sparse 11×11 goal. The N=9 success took 1,163.9 seconds. Only 31 of the 39 total
successes arrived by 600 seconds, so cutting the budget would remove real solves.

## Real elapsed-time trajectories

For the same 14 completed larger-board blocks, the recorded incumbent trajectories
give the following averages for discrete regional search. Values use the last
sample at or before each budget; a validated solution reached earlier remains a
known zero-error outcome at later budgets. No unfinished trial is projected to
its cutoff. Samples occur approximately once per second.

| Method | Wrong at 60 s | Wrong at 300 s | Wrong at 600 s | Wrong at 1,200 s | Common exact energy at 1,200 s |
|---|---:|---:|---:|---:|---:|
| Regional, no new BP | 6.21 | 5.29 | 5.07 | 5.07 | 0.0707 |
| Regional + new BP | 5.50 | 3.93 | 3.21 | 2.43 | 0.0215 |

Among unsolved larger-board trials, 34/53 with new BP still recorded a better
exact-quality incumbent after 600 seconds, compared with 18/56 without new BP.
The median last observed quality improvement was 859 seconds with BP and
435 seconds without it. Improvement timing is inferred from sampled incumbents,
not a complete event-by-event attribution to individual moves. Native energies
have representation-dependent discreteness terms; common exact energy and
wrong-clue counts are the cross-representation measures here. Quality prioritizes
wrong-clue count before residual, so common energy can rise when a higher-priority
quality component improves.

Measured BP time is about 4.0% of total wall time within BP-enabled trials, despite
nominally allowing one-second phases between SA intervals. Many phases return
before their allowance. This supports investigating productive repair allocation;
it does not prove that simply increasing every phase's limit will help. The
`bpImprovements` counter measures improvement over the chosen source, which can
be the current candidate rather than the global incumbent; it must not be read
as the number of new global bests.

## Recommended decision

1. Use discrete regional SA + new BP as the **experimental baseline**, retaining
   continuous regional + BP as a challenger. Do not declare discrete intrinsically
   superior or deploy this frozen framework over current production on this evidence.
2. Finish a minimum coverage checkpoint: one complete matched block on every
   board, especially the still-unrepresented n8-b1, and finish any already-started
   comparison block. Then pause the broad eight-condition sweep. The 184 unfinished
   jobs would take roughly another 15 hours of wall time at four slots if nearly
   all time out; that is an upper workload estimate, not an ETA.
3. Direct the next development comparison at the larger-board completion gap.
   Add diagnostics for BP patch extent, cache/shape work, exhaustion versus slicing,
   compatible-prefix reuse and **global incumbent gain per CPU second**. Compare
   a focused repair policy against the unchanged hybrid baseline: choose patches
   around persistently wrong clues and their routes, preserve compatible partial
   BP work, enlarge or vary stalled patches, and allocate longer effort only where
   evidence suggests unfinished productive search. Keep 1,200 seconds so late
   improvements and solves remain observable. Avoid varying representation,
   temperature, patch policy and BP budget simultaneously.
4. Include fresh-start 11×11 pilot runs early, and compare with the **current
   production solver**, not only this simplified experimental control. Production
   already has richer growth, archives, deductions and objective rotation; these
   results cannot rank it. Use any verified full-puzzle fixture only for offline
   correctness/reachability tests, never to seed search or prewarm a timed cache.
   Warm-start finishing tests from solver-produced candidates can diagnose repair
   separately; keep those times separate from end-to-end fresh-start solve times.
5. Judge the next change by validated solves and solve time, with common energy,
   wrong clues and useful-repair rate as diagnostics. Choose a finite budget and
   matched seeds before starting. Keep the existing fixtures unchanged for matched
   comparisons, and reserve additional sparse larger boards for later validation.

## Limits and artifacts

Only the three 5×5 fixtures have proven uniqueness. The remaining solution counts
are unknown by explicit user choice, although each has a validated planted
solution. A different valid partition counts as success. Generated clue density
matches the real puzzle approximately, but generation and certification selection
can bias shape and difficulty distributions. A small number of boards and the
missing 8×8 board prevent claims about an entire size class.

This is the frozen `solver-bench-v1` search. Its Engine.swift, Policy.swift and
CoverSearch.swift hashes were checked against the campaign's frozen revision and
match the code used for this assessment. Production code, live solver settings,
queue order and run state were not changed by the analysis.

- `completed-trials.csv`: all terminal observations in this snapshot.
- `energy-at-budgets.csv`: actual sampled trajectories summarized at fixed budgets.
- `summary.json`: matched condition summaries and paired comparisons.

The live report continues to advance; this is a timestamped interim assessment,
not a claim that the remaining trials have finished.
