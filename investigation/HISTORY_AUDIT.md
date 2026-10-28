# Commit and live-run audit — 2026-10-28

**Historical findings below.** The two reproduced repair barriers are now fixed
locally; see [the corrections, regressions and bounded comparison](PARTIAL_REPAIR_FIXES.md).
These latest changes have not been deployed.

## Findings

There is a reproducible loss of local-search productivity in the stronger clue
filters recorded in **91d4012**. There is also a remaining hard singleton-neighbor
check, dating to **11251e6**, that rejects improving partial repairs. These are
credible contributors to stagnation. They do not establish that a solution is
unreachable or explain every hour of the run.

This investigation changed only diagnostic files under `investigation/`. It read
the live dashboard, configurations, recent worker logs and SQLite state in
read-only mode. It did not change or restart a production process.

## The plateau is present in the live records

Snapshot: **October 28, 16:20:37 JST**, run
`76FBAED1-E3E5-4303-BDBF-26D96720F107`.

- Best common-ranked board: **0 structural issues, 7 wrong clues**, normalized
  residual **0.08026514978386635**.
- Last common-ranking improvement: **October 28, 00:23:33 JST** — about **15.95
  hours** before the snapshot.
- Coordinator counters: **47,239,266 accepted iterations**, **8,562 completed
  jobs**. These are cumulative work counters, not counts of distinct boards or
  successful proposals. Older calibration/reporting defects also limit their
  interpretation as useful search effort.
- Lowest retained residual is **0.06517290288877911**, with **9 wrong clues**.
  The dashboard leader orders wrong-clue count before residual, so a lower
  residual can coexist with an unchanged seven-wrong leader. The dashboard's
  improvement history is the common-ranking history, not a residual history.

One recent completed Mac mini residual attempt lasted **1,200 seconds**. It
recorded **29,089 iterations**, **12,984 empty iterations (44.6%)**, **743 elite
imports**, **83 restarts**, **467,047 evaluations** and **95,958 completed covers**.
It retained seven wrong clues. This demonstrates real computation, with a large
fraction of failed proposal attempts and frequent reanchoring; it does not prove
all evaluations were distinct or that the elite imports caused the plateau.

Both installed Mac mini executables have SHA-256
`1649eb866a729aa9ec0832fe341a1c81a51c18a2ec957058b16088890074546e`, matching
the binary deployed earlier in this chat. All **26 Swift source files** in that
build's retained staging directory match the current audited sources. Other
machines' binaries were not version-verified in this investigation. Telemetry
does not contain a build identifier, so a source commit alone cannot establish
what every running process uses. Commit timestamps are also not deployment times.

## 1. Stronger final-state filters substantially reduce local repair proposals

Files: `ExactSearch.swift` (`ClueConstraints`), `RegionRepairs.swift` (`cover`,
`initialState`, `boundaryRepair`) and `ShapeGrowth.swift`.

The seven-wrong leader has **23 states**, largest area **22**. All its states pass
the clue filters in `11251e6`, `2614f8a` and `c9feaaa`. Under `91d4012`, **six**
states fail the stronger filters: their areas are **12, 1, 1, 4, 2, 22**. Every
revision still evaluates the complete board as exactly seven wrong clues with
the same residual and zero structural issues. The change is in which moves can
be generated, rather than in scoring this board.

The deductions themselves are necessary conditions on a finished solution.
However, this board is unfinished. `repairProposal` adds existing patch states
back to its candidate list, but `cover` then filters **all** candidates through
`permits`, removing existing states that fail those final-solution deductions.
Boundary and merge repairs use the same hard filters. An otherwise useful
partial change must therefore repair the selected states' deduction violations
at once, instead of retaining an imperfect part for a later move. The normal
32-cell patch limit and bounded generation make this particularly restrictive.

### Isolated comparison

I compiled historical core sources in temporary directories. Each measured
configuration used **three seeds, six seconds per seed, one CPU worker, the same
live seven-wrong starting board, the match objective and no shared archive**.
There were also three six-second fresh starts per configuration. All run logs
were written to temporary directories. `11251e6` received a static scoring/filter
check only; its older lifecycle API has no equivalent resume argument.

| Core | Existing leader states rejected | Empty iterations | Completed covers, three seeded trials |
|---|---:|---:|---:|
| `2614f8a` | 0 | 4.22% | 27,688 |
| `c9feaaa` | 0 | 2.39% | 25,406 |
| `91d4012` | 6 | **48.13%** | **3,367** |
| `91d4012`, earlier deduction strength only | 0 | **2.46%** | **22,556** |

The last row changes only `ClueConstraints` initialization in a temporary source
copy: adjacent printed-clue area bounds are retained; propagated singleton,
short-path and pair deductions are disabled. The latest generators, cache fixes,
discovery retention and search lifecycle are kept. This isolates deduction
strength as a cause of much of the lost proposal productivity. It is an ablation,
not a recommendation to remove correct deductions everywhere.

Fresh starts ended at 18/17/15 wrong for `c9feaaa`, 18/18/18 for `91d4012`, and
17/14/17 for the isolated ablation. **Every seeded trial retained seven wrong**.
These short wall-clock runs do not establish solve rates, a speedup in useful
improvements, or a universal performance ranking. Different bounds also change
the search space and RNG consumption. The newer bound additions cannot explain
the entire earlier plateau on code that predates them.

**Correction direction:** distinguish final-board feasibility from intermediate
local repairs throughout the filters, not just in cross-state pair pruning.
Keep the stronger deductions in strict feasibility searches and final validation.
Provide a bounded repair lane that can retain imperfect existing states and
evaluate gradual progress. Compare completed, useful proposals and actual clue
improvements before deployment.

## 2. An older hard one-clue rule still discards improving partial repairs

`cover.onesPossible()` requires every relevant printed **1** to have a neighboring
singleton. This is a correct necessary condition for a solved board. It is also
applied when an exterior printed 1 is already wrong and this move does not repair
it. The same conceptual problem was previously fixed for pair bounds, but this
rule remains unconditional.

A deterministic 3×3 fixture, with `.` for blanks:

```text
clues          source labels   improving labels
3 1 0          A B C           A A B
. 1 .          D E D           C D C
1 0 0          D D D           C C C
```

The patch is the top row. The supplied catalog is exactly `{r1c1,r1c2}` and
`{r1c3}`. Both candidate states pass the production per-state filters.

- Source: **5 wrong**, error **0.6857142857**, no structural issues.
- Reference cover: **3 wrong**, error **0.4**, no structural issues.
- Production cover: **nil**.
- A fully valid solution to the clue fixture is included in
  `repair-barrier-results.json`.

The center cell is an exterior singleton with printed value 1; it remains wrong.
Neither top-row alternative supplies its required neighboring singleton. The
production hard rule prevents the top-row improvement even though later moves
could repair the center. The reference differs only by omitting this one-clue
condition. It keeps the same supplied catalog, per-state filters, exact scoring
and exhaustive small-patch enumeration. The fixture was found at trial 11 of a
fixed-seed probe.

The hard rule dates to **11251e6** and remains in the current source. Similar
one-clue checks also occur in merges. This is a demonstrated lost local
improvement, not a claim that the entire fixture or full puzzle is unsolvable.

**Correction direction:** retain hard one-clue feasibility in strict searches;
allow local repairs to leave an existing exterior mismatch for later, or use a
sound objective lower bound. Keep independent success validation unchanged.

## Other commit history relevant to the run

| Commit | Relevant behavior and current status |
|---|---|
| `e23adc5` | Earlier generic annealing. Its continuous display-energy behavior is not equivalent to the later exact symmetric-partition search. An old low display energy is not an end-to-end discovery benchmark for the current solver. |
| `11251e6` | Introduced the discrete shape/cover search, 32-cell ordinary patches, merges of at most four states, the hard one-clue rule above, and the archive exchange scheme. The archive's original even-ticket selection skipped half an even-capacity archive; corrected in `91d4012`. |
| `2614f8a` | Added larger repairs and residual/persistent objectives. Common-ranking discoveries could be lost when a move selector preferred another objective; merge cursors were reused across ranking changes. Previously reproduced; both corrected in `91d4012`. |
| `a00f366` | Added distributed work and the original calibration deadline mismatch. Expired-deadline attempts could inflate rates and assignment budgets. Calibration is corrected in `91d4012`, but existing large jobs are not automatically resized. Live jobs still include budgets near one million and many generations. This affects work scheduling and counter interpretation; it does not directly change distance arithmetic. |
| `c9bc80a` | Added GPU path batching. Static historical scoring agrees on the live leader. No scoring regression was found here in this comparison; the historical timed runs were CPU-only, so this is not a fresh CUDA/Metal performance audit. |
| `c9feaaa` | Included client checkpoint/budget/reporting fixes. Its core search is much more productive than `91d4012` on the short leader replay, but it still contains older discovery/cache defects. A wholesale rollback would reintroduce those defects. |
| `91d4012` | Corrected the earlier discovery, cursor-ranking, calibration and archive-selection defects, added stronger deductions and shape generation, and fixed cross-state pair-bound pruning. The stronger per-state filters introduce the measured proposal restriction; the separate hard one-clue rule remains. |

## Remaining search design concerns

- A seven-wrong partition is not necessarily a few boundary edits from a solution.
  The known independently verified solution has a 37-cell state; the live leader
  has at most 22 cells in a state. The former remains an acceptance fixture,
  not a shape supplied to these historical replay runs.
- Frequent elite reimports can repeatedly interrupt a deteriorating-but-useful
  annealing walk. The live log shows this behavior; a controlled archive-policy
  comparison is needed before attributing a performance loss to it.
- The coordinator currently retains one count leader, one residual leader and
  several topologically diverse boards, including very poor boards. At the
  snapshot, six of eight retained entries have 16–28 wrong clues. Random archive
  job seeding and repeated exchanges are not equivalent to independent restarts.
- Normal patches, merge size, shape catalogs, generation deadlines and cover-node
  budgets still restrict the move graph. More workers do not establish that the
  required compatible shapes are being explored.
- The current package tests and known-solution acceptance checks establish
  specific correctness properties. They have never established a reliable fresh
  full-puzzle discovery rate. More passing tests alone would not settle this
  performance question.

## Reproduction and evidence

```sh
python3 investigation/run_history_probe.py investigation/history-fixture.json
python3 investigation/run_history_probe.py investigation/history-fixture.json 91d4012-legacy-constraints
python3 investigation/run_repair_barrier_probe.py
```

`history-fixture.json` contains only the puzzle clues and exported leader labels.
`history-probe-results.json` contains individual measured trials;
`history-evidence.json` contains the summarized live observations and comparisons;
`repair-barrier-results.json` contains the exact small-patch counterexample.
The probes require the local Swift compiler, run bounded diagnostic searches,
and do not connect to production or inject the published solution.

Recommended order: correct the two partial-repair barriers; verify the full
fixture still validates; compare several seeds from both the real leader and
fresh starts with enough time to measure actual improvements; then evaluate
archive reanchoring and assignment budgets. Preserve the current boards and
separate build identity from configuration in fleet telemetry. Do not discard
the run or roll back every fix on the strength of these short tests.
