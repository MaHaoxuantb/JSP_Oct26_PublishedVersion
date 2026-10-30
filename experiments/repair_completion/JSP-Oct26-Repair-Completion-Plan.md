# JSP-Oct26-Repair-Completion

©2026 ThomasB

Status: proposed experiment; no trial launched. Prepared 2026-10-30.

## Goal and question

Advance toward an independently validated solution of the original 11×11 puzzle.
Test whether retaining unfinished branch-pruning repairs and selecting repair
areas from incorrect-clue routes improve completion within the same time budget.
The preceding campaign supports regional SA plus BP, but only 3/120 completed
N=7–9 trials solved. This study tests mechanisms and includes the actual target.

Treat the two hours as the execution window after implementation is ready.
Implementation and isolated preliminary correctness checks precede that window.
If the available window includes implementation, reduce the trial count rather
than compressing checks or promising this full workload.

## Five methods

| Method | Representation and search | Persistent BP jobs | Route-selected repair areas |
|---|---|---|---|
| A | Frozen experimental discrete regional SA + BP policy | Existing short-lived behavior | Existing neighboring-region growth |
| B | Same experimental framework | Yes | Existing growth |
| C | Same experimental framework | Existing behavior | Yes |
| D | Same experimental framework | Yes | Yes |
| E | Frozen current production solver, CPU search with one search thread | Its existing implementation | Its existing implementation |

A–D form a 2×2 comparison. B versus A and D versus C estimate persistence;
C versus A and D versus B estimate repair selection. D also tests their
interaction. E is an engineering reference with a different architecture and
does not enter those factorial estimates. The purpose is to decide whether to
develop or transfer these mechanisms, not declare a universally best solver.

All A–D methods use discrete representation and regional SA. The earlier
continuous comparison remains exploratory; the two-hour budget is concentrated
on repair behavior. Keep SA settings, BP invocation rules, per-invocation time
allowance, bounds, shape enumeration, patch-size limits, initialization and
evaluation consistent across A–D. No hand-tuning after inspecting timed results.

### Persistence factor

Maintain a bounded collection of at most four repair jobs, each with its own
fixed candidate snapshot, patch, enumeration cursor and BP stack. Remove the
forced two-unsuccessful-phase expiry. Resume compatible unfinished jobs within
the same BP invocation allowance; SA can continue between slices. A changed SA
candidate does not invalidate a job searching its own saved snapshot. Every
result is evaluated as a complete board before competing with the incumbent.

Keys include the puzzle, patch, fixed exterior and all objective/bound settings
needed for safe reuse. Finish or evict jobs explicitly; record exhaustion,
dominance, incompatible settings and capacity eviction separately. Reuse of a
search state must preserve the meaning of previously pruned branches. Do not
increase aggregate BP allowance as an additional experimental factor.

### Repair-selection factor

Use the existing incorrect-clue route field to select a persistent error, then
choose complete regions along its current cheapest route to a capital. Select
connected route sections under the existing patch-size allowance; do not require
the entire route to fit. Use the same size/scope schedule as the neighboring
selection control, and report actual sizes since matching limits does not match
the sizes that can be constructed.

Keep a prespecified exploration fraction for neighboring regions and alternative
routes. A currently cheapest route need not be the route in a correct solution.
Freeze this fraction before launch. Evaluate all clues after a repair; never
protect a region merely because it currently satisfies one clue.

## Boards and trials

Use current validated fixtures n7-b1, n7-b2, n8-b1, n8-b2, n9-b1 and n9-b2.
The fixed slot choice includes previously untested n8-b1 and avoids selecting
boards by which method previously won. Keep the current clues and their ratio;
do not spend this budget proving uniqueness. Known ambiguity remains a reported
limitation. The third board at each size is reserved for later confirmation,
although it is not an unseen holdout from the previous study.

- Six generated boards × five methods × one fresh matched seed = 30 trials.
- Original 11×11 puzzle × five methods × two fresh matched seeds = 10 trials.
- Total: 40 trials, each with a 1,200-second limit or earlier validated solve.

Use one original-puzzle seed block on each Mac. All five methods for a particular
board/seed block run on the same Mac. Each Mac receives one N=7 board, one N=8
board, one N=9 board, and the original puzzle: 20 trials per host. Fix fresh seeds,
the production reference configuration and balanced job order before launch.
Different seeds on one puzzle are repeats, not independent puzzles.

Every trial starts fresh. No planted witness, previous solved partition, other
trial's discovery, or incumbent from the older campaign enters timed search.
Copies of the same frozen read-only shape seed store may be used; per-trial lazy
discovery is private. Cache loading and lazy enumeration count toward trial time.
There is no exhaustive upfront shape-catalog completion gate.

## Machines, scheduling and the two-hour limit

Read-only inspection confirmed that the current Mac (Mac16,1, 16 GiB) has four
performance cores and six efficiency cores. Plan four simultaneous processes,
one synchronous CPU search each. macOS does not guarantee physical P-core
pinning; record process CPU time/wall time and host load.

The Mac mini's saved address, 192.168.4.173, was unreachable during planning.
Confirm connectivity, CPU configuration, memory, Swift/runtime compatibility and
available CPU capacity before launch. Four Mini slots are a capacity assumption,
not an observed hardware specification. Check for existing workloads and arrange
exclusive search capacity before timing; do not silently stop production work.

With four slots per host, 20 trials require at most five 20-minute waves:
100 minutes of search, 800 worker-minutes total (13 hours 20 minutes). Early
solutions free slots, but no additional confirmatory trials are added based on
which method is leading. Queue all methods with balanced order and equal
concurrency. Place original-puzzle trials throughout the schedule rather than
leaving them behind an uncertain final stage.

| Time from campaign launch | Work |
|---|---|
| 0–10 minutes | Confirm hosts, frozen inputs/binaries, isolated smoke checks, resource settings and dashboard; distribute static files |
| 10–112 minutes | Forty trials; 100-minute worst-case search plus two minutes of scheduling allowance |
| 112–120 minutes | Reconcile outputs, independently validate candidates, generate charts and report |

Use a fixed campaign deadline. Scheduling overhead is real and is not hidden
from the two-hour budget. Do not launch work that cannot receive its allotted
time before the search deadline. Interrupted jobs retain actual elapsed times
and checkpoints, and are reported separately from 1,200-second timeouts.

If the Mini is unavailable, the prespecified local-only fallback is 20 trials:
one fixed board each at N=7,8,9 plus one original-puzzle seed, all five methods.
This retains complete comparisons with the same per-trial limit. A partially
available Mini adds only complete five-method board/seed blocks that fit.

## Measurements and decision

Primary outcomes: independently validated solve count and time to first valid
solution, with unsolved full trials capped at 1,200 seconds for capped solve cost.
Report results by board and by host, with paired method differences within each
board/seed block. Do not pool raw times across the two hardware types as if their
speeds were equal. The original puzzle is a separately reported target outcome.

Record real elapsed-time curves for common exact energy and incorrect clues.
Show actual samples and solve events; do not extend an interrupted or unsampled
curve to the cutoff. Native objective values remain method-specific diagnostics.

For each repair, record source/scope identity, patch cells/regions, originating
clue/route, enumeration time, new/resumed nodes, bound prunes, CPU/wall effort,
exhaustion or abandonment reason, and its fully checked result. Distinguish
improvement over the saved repair source from improvement over the global
incumbent. Track repeated enumeration and generated proposals that SA actually
accepts. Timing categories must specify nesting to avoid adding overlapping time.

If methods solve different generated boards, inspect paired outcomes rather than
ranking by pooled energy. Promote a repair change provisionally when it has a
consistent completion/capped-cost benefit without clear regressions, supported
by the repair counters. With only six generated boards and two target repeats,
the study is a screening experiment. If solve outcomes are all zero or sparse,
report completion evidence as inconclusive; diagnostic gains justify a next
test, not a claim that the original puzzle is nearly solved.

No extra uniqueness certification, broad representation sweep, or automatic
post-hoc extension is included in this execution budget.

## Implementation and preservation

Keep experiment policy/configuration and the host-aware queue adapter under
`experiments/repair_completion/`. Reuse the shared Swift puzzle rules, shape
domain and independent Python validation; provide explicit policy switches for
the two factors. Build isolated release products and freeze hashes, configs,
fixtures and software versions in the campaign manifest. The production
reference uses an isolated build of a recorded revision; this plan does not
authorize replacing an installed worker or modifying a running production run.

Each host stores its queue, checkpoints and observations in its local Application
Support directory. Transfer immutable inputs and completed export files; never
copy a live SQLite database through iCloud or between hosts. The dashboard
aggregates host-identified records and displays actual phase/trial progress,
attempt interruptions and exact observed measurements. Numerical node counts
are progress measurements, not a claimed percentage of the full search space.

Use the identity **JSP-Oct26-Repair-Completion** and **©2026 ThomasB** on the UI,
report and public exports. Preserve the stopped earlier campaign as a separate
dataset. Produce a report, per-trial data, repair diagnostics and an evidence
manifest at the end of this campaign.
