# JSP-Oct26-Search-Escape-Proposal

©2026 ThomasB

Author: ThomasB

Status: code-reviewed proposal; not implemented or deployed. The current
version-5 continuation remains running unchanged. Prepared 2026-10-30.

## Goal and evidence

The goal is a fully validated solution of the original 11×11 puzzle. More
iterations, locally useful repairs and declining energy are diagnostic outcomes;
none establishes improved time to solution.

At 557 seconds of the continuation, the pool retained its starting quality:
zero structural issues, 14 wrong clues, residual 0.17078226998999335. Measured
CPU use was 7.74 equivalents. Workers had performed 157,137 iterations, accepted
83,775 moves and explored 363,041 BP nodes. Seven workers retained one identical
best partition; the eighth retained another. These are best-state measurements,
not a measurement that the active SA walks are identical. All workers' counters
advanced in the preceding minute.

Code inspection identifies four mechanisms:

1. The archive publishes only personal bests, sorts solely by quality and evicts
   the worst above eight entries. Initial saved seeds are not deduplicated.
   Equal-quality alternatives cannot be imported because imports must strictly
   improve personal best; merely selecting a different archive entry is therefore
   insufficient. Raw strengths are used for deduplication even though distinct
   encodings can describe the same partition.
2. `RepairScheduler.failures` resets for a result better than the current SA
   source, even if it does not improve the worker's best or the pool's best.
   Scope selection is thus driven partly by local recovery rather than sustained
   failure to advance the best solution.
3. `RegionalPolicy.patch` chooses a random desired number of regions, usually
   small. Increasing its maximum cell allowance does not impose a minimum scope.
   The scheduler's full-board fallback is abrupt rather than gradual actual growth.
4. Full-board repairs can be evicted by the four-job FIFO capacity rule; all
   in-memory repair stacks are rebuilt at each 3,000-second continuation boundary.
   Persistence inside a segment does not imply a protected long search.

## First fix: preserve quality and diversity separately

Maintain an immutable-to-regression global best plus a bounded collection of
structurally distinct alternatives. Canonicalize a board by its region membership
or its orthogonal boundary bitmap; do not equate raw strengths with a partition.
Deduplicate the initial seeds too. Use boundary distance and incorrect-clue masks
as diversity signals. Clue masks alone can hide very different geometries.

A concrete starting policy is one best slot plus up to 15 alternative slots.
For structurally legal alternatives near the best (initially up to two extra
wrong clues), retain one quality leader per boundary-distance cluster; maintain
separate independent exploration so the quality window does not constrain all
search. The thresholds are engineering starting choices, not measured optima.

Publish occasional active candidates and new distinct local leaders, rather than
only lifetime personal bests. Separate three references: the protected pool best,
the current island leader, and the active SA candidate. On a diversification event,
seed the active candidate and island leader from the alternative while preserving
the pool best. BP must use the island leader for diversity workers; otherwise the
existing three-of-four BP source selection would keep pulling repairs back to the
same lifetime best. The present exchange interface sets both local references to
a strictly better import and must be extended explicitly. Stagnant workers can
then move to a different basin without worsening the saved incumbent.

Migration should be infrequent and conditional on stagnation, not an automatic
one-second race toward the best. Start with 60-second migration opportunities and
at least two workers that never import non-solved peers. Fresh or substantially
perturbed seeds must fill duplicate saved slots. Log pool and per-worker diversity,
current-state fingerprints, accepted migrations, and destinations actually used.

## Second fix: progress-sensitive repair escalation

Keep separate measurements for (a) improvement over the current SA state,
(b) strict improvement of the retained global quality, and (c) reduction of the
global wrong-clue count. Importing an old known record must not reset the pool's
progress clock. Publish a synchronized global improvement epoch and its age.

Drive escalation from time since global progress. As an initial schedule, after
60/180/600 seconds without a better global record, target at least 16/32/64 cells
in selected repair jobs. Keep another clock for wrong-clue reduction so tiny
residual gains cannot indefinitely suppress broad work. Expand by whole adjacent
regions until the target is reached, recording actual cells/regions and justified
failures to reach it. Preserve some small-scope attempts rather than making all
workers perform the same large search simultaneously. These intervals require
screening; they are not known optimal constants.

Reserve a nonzero share of BP effort for broad jobs and protect at least one
long-lived job from FIFO eviction. Small repairs that recover a wandering SA state
remain useful but must not reset global stagnation. Track CPU/wall effort spent
per actual scope band; a full-board job merely being created is insufficient.
Checkpoint and restore protected jobs across segment boundaries, including their
fixed exterior, source, objective/bound mode, enumeration cursor and compatibility
metadata. Re-evaluate restored states. Do not rebase previously pruned branches
onto a changed exterior or incompatible objective.

Add a bounded memo of fully exhausted repairs keyed by puzzle, canonical patch
and exterior, objective/bound rules and proven threshold. Avoid redoing equivalent
work under the same or stronger target. An interrupted repair is not a proof and
must never become a permanent exclusion.

## Additional approaches, in recommended order

### 1. Adaptive destroy-and-repair

Choose among connected neighbor patches, geometric blocks, disagreements between
diverse candidates, boundary/capital changes and route patches. Remove complete
regions then repair the chosen area. Rank operators using distinct useful states
and global improvements per CPU effort, with mandatory exploration. Retain all
original clue constraints in final validation. Route guidance is one operator,
not the only way to select a patch; the earlier B/D pair did not support privileging
route guidance. This extends the existing solver and is the lowest-cost next step
once the two fixes are isolated.

This follows the general large-neighborhood-search framework, but its effectiveness
for this puzzle remains a hypothesis. Reference: Pisinger and Ropke, *Large
Neighborhood Search* (2010):
https://backend.orbit.dtu.dk/ws/files/5293785/Pisinger.pdf

### 2. A protected exact-feasibility search lane

The existing `CoverSearch` already supports `.certify` as well as `.improve`.
A full-board certify search can demand that every clue remain possible, applying
zero-clue/capital restrictions and sound distance bounds instead of allowing a
partial board to preserve an incumbent with 14 wrong clues. Configure one desired
solution; exhaustive uniqueness certification is unnecessary. Use good incumbent
shapes only as branch-order preferences, never as forced placements.

A feasible-solution lane may prune more strongly but may still have a huge search
tree. Initially reserve one CPU thread, preserve its stack, and measure distinct
branches, pruning and solutions on known-solvable small fixtures. If splitting
across threads later, use disjoint subtree assignments and durable cursors;
independent deterministic copies of the same tree would waste cores. Exactness
requires complete lazy domains and sound pruning; a restricted shape set supports
only a restricted-domain conclusion.

### 3. Recombine diverse candidates

Compare two distinct partitions, keep a trial subset of common regions, then
repair their disagreement area with BP. Even a shared region can be wrong, so
agreement guides a trial and cannot become a permanent global constraint. Increase
the released area when a repair is infeasible or unproductive. This requires the
diverse archive first and overlaps naturally with the first operator family.

### 4. An independent CP-SAT formulation

A longer-term alternative is an integer feasibility model of region geometry,
capitals, state sizes and weighted shortest-path distances. CP-SAT supports integer
constraints and feasibility solving:
https://developers.google.com/optimization/cp/cp_solver

A possible distance formulation uses nonnegative integer distance labels, distance
zero at capitals, and for each non-capital cell the minimum over adjacent-cell
distance plus `min(sizeHere,sizeThere)`. Positive edge weights ensure that a finite
assignment follows a descending path to a capital; clues fix selected distances.
The difficult work is a compact complete encoding of connected symmetric regions
and the exact capital rule. Merely requiring path inequalities is insufficient to
establish exact shortest distances. An incomplete catalog must not become an
unqualified infeasibility proof. This is a separate prototype, not a dependency
installation or a promised faster replacement.

## Suggested eight-thread allocation after screening

A solve-oriented portfolio could use three incumbent-repair workers, three diverse
island workers, one broad/recombination worker and one protected exact-feasibility
worker. This is a proposed allocation totaling eight CPU threads, not an observed
best configuration. All publish independently re-evaluated discoveries. Keep the
original fixed policy available as a reproducible reference.

## Verification and evidence needed before promotion

Implement diversity and escalation independently behind configuration flags;
test both independently before their combination. Verify canonical duplicate
suppression, actual alternative adoption with retained-best preservation, sustained
scope growth despite local-only improvements, protected-job fairness, compatible
checkpoint recovery and safe exhaustion memo reuse. Test that a known solution
can still be reached and that known infeasible tiny cases are handled consistently.

Screen mechanisms on the original starting incumbent, then on saved generated
fixtures with matched budgets and seeds. Keep total CPU effort and all eight
threads comparable. Generated fixtures may be ambiguous; only independently
validated solutions count. Primary outcome remains solved/time to solution;
secondary measures are distinct candidates and repair scopes, global-best changes,
wrong-clue changes and CPU allocation. Show active-state and retained-best energy
separately. Improvement counters must identify which reference they improve.

No new worker release or deployment occurs for this proposal. Implementation
requires a new monotonically increasing software release, isolated tests/builds,
strict/transitional compatibility checks and an explicit run record. Preserve
current results and checkpoints; no cooling changes are involved.
