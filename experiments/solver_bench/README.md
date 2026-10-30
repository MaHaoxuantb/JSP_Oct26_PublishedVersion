# Solver Lab — isolated, certified experiment

This is an independent Swift package and Python queue/dashboard. It does not
import production worker/coordinator code, deploy software, or change the release
version. Historical studies remain separate. Search behavior here belongs to a
**new shared framework**, not the old implementation's performance baseline.

## Current campaign amendment — 2026-10-29

The user requested starting immediately with the current puzzles, without waiting
for uniqueness. `bench.py use-current` stops preparation, preserves its saved
checkpoints and proven certificates, and freezes each remaining current puzzle
only after independently validating its saved solution. Those boards have
`solutionCount: null` and `exhausted: false`; their counts are unknown. Valid
solutions remain checked by the same exact rules. Known solutions are never
passed into timed solver inputs. Other trial conditions, seeds and the 1,200-second
cutoff stay the same. The original strict policy below remains the default for
new campaigns unless this explicit command is used.

The active campaign preserves its original frozen source and records this runner/UI
revision and configuration amendment separately. The Swift solver binaries and
frozen shape store are unchanged.

## Campaign

- Sizes 5, 6, 7, 8, 9; three distinct clue boards per size (D4-equivalent boards
  are duplicates). Exact clue counts 7, 10, 13, 17, 22, matching `round(N²·33/121)`.
- All eight conditions: discrete/continuous × regional off/on × new BP off/on.
  This includes the two missing factorial controls in the earlier six-condition
  proposal. Three matched seeds: 20261029, 20261030, 20261031. **360 trials**.
- Every trial stops at a validated solution or 1,200 elapsed seconds. A watchdog
  allows 15 seconds of infrastructure grace, but an over-limit or early unsolved
  result is an infrastructure failure, not a valid timeout. No iteration cutoff.
- Eight preparation processes, then four timed processes. Each Swift search is
  synchronous and CPU-only with one hot search thread and user-initiated QoS.
  On this Mac there are four performance cores and six efficiency cores. macOS
  affinity is not a physical core lock: P-core placement cannot be guaranteed.
  CPU/wall ratios are recorded and multi-core anomalies fail validation. Other
  system activity and thermal effects remain limitations; launch order is balanced
  and randomized. Preparation and timed trials never overlap.
- Maximum timed workload is 30 hours at four slots if every run times out, plus
  preparation and infrastructure overhead. This is a ceiling, not an ETA.

## Preparation and exactness

The generator plants connected symmetric partitions by legal merges, without a
protected singleton or maximum region size. It samples clue masks and uses
counterexamples to choose better masks without increasing clue density. The
clue-mask hitting-set chooser is heuristic and bounded; that affects which boards
are tried, never which solutions the certifier counts.

The certifier covers the board with legal symmetric states, counts distinct
canonical partitions, and stops immediately at the fourth solution (rejected).
A count of one through three is accepted **only after exhaustive search**.
Uniqueness is a unique partition, not just a unique numerical answer. A separate
Python implementation checks all accepted solutions, capitals, integer shortest
paths and answers. The count proof comes from the exhaustive Swift search; the
Python checker does not independently prove that no other partition exists.

Each preparation session has a six-hour wall-clock budget. Work rotates across
all 15 board slots in 45-second checkpointed slices. Unique fixtures finish early;
qualified 2–3-solution fixtures can keep searching for a unique replacement.
When all 15 are unique, trials can start early. At the session deadline, all 15
must have a proven count of at most three; otherwise state becomes
`preparation_incomplete` and **no trial runs**. A manual `start` resumes preserved
work with another bounded preparation session. Producing 15 suitable boards at
this sparse density is not guaranteed.

## Complete shape domain, permanent cache

`ShapeDomain` enumerates shapes lazily and exactly. For every bounding rectangle
containing the anchor, it enumerates connected subsets of symmetry orbits for
180° rotation, horizontal/vertical reflection, and the two diagonal reflections
(square rectangles). Every nontrivial grid symmetry is covered: 90°/270° imply
180°. Each region has a unique tight bounding rectangle; its lowest applicable
symmetry generator removes duplicate yields. Actual cell connectivity and the
full symmetry/capital rules are checked before yielding. No shape is excluded
because the cache is empty, a time slice ends, or enumeration has not reached it.
The DFS iterator and exact-cover stack are Codable and resumable.

The clue-independent seed cache exhaustively materializes canonical shapes with
bounding-box area ≤16 and maximum side ≤9. This finite cache is **not** described
as a complete materialized 9×9 catalog. The procedural generator covers the full
board. The immutable SQLite cache, its manifest and SHA-256 persist outside
iCloud; each search has its own bounded discovery cache. Certifications cannot
warm trial caches. Cache load and discovery time are included in timed searches.
The UInt128 mask implementation supports boards through 11×11; a future campaign
must explicitly version/configure its permanent cache and dimensions.

## Shared search

`PuzzleRules` owns integer geometry, connectivity, capitals, shortest paths,
canonical partitions and exact validation. `SolverCore` owns the common policy,
annealing, representation adapters and logging. `BoardPreparation` is separate
from timed search; `benchqueue` owns durable scheduling and the read-only UI.

All conditions use identical seed-derived initialization, annealing, proposal
mixture and validation. Separate RNG streams serve initialization, proposals,
acceptance, regional policy and BP. There are 5% relationship perturbations,
30% legal merges, 25% boundary/split moves and 40% bounded cover repair. B0 still
uses bounded branching for ordinary repair (5,000 nodes, 48 covers or 150 ms),
with the new distance-bound pruning disabled. B1 adds adaptive, bounded BP phases;
it is not the historically truncated global shape-catalog solver.

Discrete strengths are exactly 0/1. Continuous strengths lie in [0,1] and decode
at 0.5. Changed macro edges use 0.1/0.9 while unchanged strengths are preserved.
Continuous relationship moves reflect `old + noise` into [0,1]; discrete moves
choose 0/1 by the noise sign. Initial partitions are matched across conditions.

Native energy is `(2·clueResidual + invalidFraction + 2·discreteness)/5`.
Clue residual averages `|distance−target|/max(distance,target,1)`; unreachable
clues contribute one. Discreteness uses the mean incident-edge tangent penalty
`tan(2·min(p,1−p))/tan(1)`. Discrete states have zero discreteness. Exact quality
is lexicographic `(invalid regions, incorrect clues, normalized residual)`.
Common exact energy is `(2·clueResidual + invalidFraction)/3`.

Regional energy spreads clue residual along the deterministic shortest route to
a capital, adds invalid-cell and discreteness penalties (2:1:2), and normalizes
spatially. Focus is 20% uniform and 80% proportional to `0.05 + hotness`. Noise is
the mean of `n` uniform [-1,1] draws; `n=round(16−15·hotness)` from 16 down to 1.
R0 uses uniform focus and n=16. The same policy changes cover-patch breadth and
relationship perturbations. Flat fields use hotness zero.

After five seconds without a better exact candidate, B1 allows a one-second
BP phase followed by at least four seconds of SA. Patch limits expand through
16, 32, 48, 64 cells and finally the whole board after repeated failures. Patches
contain whole regions. Completed covers are compared globally, so BP can improve
a partially wrong board. A pending BP search survives only when its exterior
partition remains unchanged. Two-sided shortest-path bounds prune prefixes whose
best possible exact quality cannot beat the incumbent. Unassigned sizes have
bounds [1, remaining cells]; potential future capitals make a conservative lower
distance bound, and existing fixed capitals give an upper distance bound.

## Durable execution and UI

Active SQLite files, run logs and checkpoints live under
`~/Library/Application Support/JaneStreetPuzzleBench/`, **never in the iCloud
repository**. Each campaign freezes source, binaries, input fixtures, hashes and
configuration. Queue writes are transactional. A controller lock prevents two
coordinators; recorded process identities use unique input-path nonces. Recovery
adopts live timed workers, reconciles completed files, and restarts preparation
from its last committed checkpoint. Infrastructure failures get at most two
retries. Explicit stops preserve attempts and requeue interrupted jobs without
counting them as solver timeouts. Crashed runs get fresh attempts, not a falsely
continuous timing curve. `caffeinate` prevents idle sleep only while the controller
is active. The separate read-only loopback UI remains up after the queue exits.

The dashboard displays actual preparation counters, proven board counts, unknown
counts, sampled incumbents, wall time, CPU time, memory, per-condition results and
exports. No invented ETA or percentage of an unknown search space is shown.
Charts stop at the last actual observation. They plot retained lexicographic
incumbents, **not a manufactured lower envelope**: a higher-priority quality
improvement can increase another metric. Native energy has an additional term
for continuous states; common exact energy, clue errors and invalid regions are
better cross-representation comparisons. Catalog, cover and BP timings are nested
and must not be added together. Dashboard polling/report generation can add a
small amount of background CPU activity.

Primary reporting shows solve rate, real/censored elapsed time, and capped solve
cost (timeouts contribute 1,200 seconds). Failed, interrupted, queued and unrun
trials are separate. Nine matched trials per condition/size are descriptive;
three boards are not enough for broad puzzle-population claims. Generated boards
can have planting bias; the results apply to these certified fixtures. Historical
experiments are not pooled or silently rerun.

## Build, verify, launch

Requires Swift 6.1+, macOS 15+ (UInt128) and Python 3. No third-party packages, CDN
or network service. Use a scratch product; do not overwrite installed workers.

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/puzzle-bench-build/modules \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/puzzle-bench-build/modules \
swift test --build-system native --disable-sandbox \
  --package-path experiments/solver_bench \
  --scratch-path /private/tmp/puzzle-bench-native --configuration release

PYTHONPATH=experiments/solver_bench \
BENCH_TOOLS=/private/tmp/puzzle-bench-native/release/bench-tools \
BENCH_WORKER=/private/tmp/puzzle-bench-native/release/bench-worker \
python3 -m unittest discover -s experiments/solver_bench/tests -v

python3 experiments/solver_bench/bench.py create \
  --bin /private/tmp/puzzle-bench-native/release
python3 experiments/solver_bench/bench.py start
python3 experiments/solver_bench/bench.py status
python3 experiments/solver_bench/bench.py stop
python3 experiments/solver_bench/bench.py report
```

`create` records a new campaign and updates `latest.json`; it does not start a
search. `start` detaches the server and coordinator and prints the local URL.
Use `--directory /absolute/campaign/path` to target an older campaign. The campaign
has its own frozen `source/bench.py`; use that entry point for future lifecycle
commands. `stop` stops this campaign's controller work, not production workers or
its read-only dashboard. A computer restart requires another `start`.

Tests compare the exact shape generator against brute-force subsets through 4×4
(including restricted allowed cells), check capital rules and the 8,045 example,
compare pruned/unpruned solution sets, serialize query/cover continuations, verify
immutable cache behavior, matched initialization/noise, gate admission, independent
validation, retry limits and an actual miniature eight-condition campaign. The
miniature test's outputs are temporary and never enter the primary campaign.
