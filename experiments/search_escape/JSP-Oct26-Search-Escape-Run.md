# JSP-Oct26-Search-Escape-Run


©2026 ThomasB

Author: ThomasB

The active successor is [JSP-Oct26-Structural-Search](JSP-Oct26-Structural-Search-Run.md),
using release 10. The stopped release-7 history follows.

**2026-10-31 status: stopped after 12.24 hours without a retained improvement.**
The final result remains 13 incorrect clues. Both the Mini solver and local
CP-SAT companion stopped cooperatively; all results and branch trees remain.
The [stall investigation](results/20261031-stall/JSP-Oct26-Search-Escape-Stall-Report.md)
documents the structural large-region bound, failed policies, local release-8
corrections and paired tests. Release 8 is tested locally and **not deployed**;
the long campaign remains stopped. Historical launch details below describe
the stopped release-7 campaign.

Goal: independently validate a solution of the original 11×11 puzzle. Current
best is unsolved: **13 wrong clues, no structural issues, normalized residual
0.16496219632232606**. This improves on the previous 14-wrong-clue incumbent.

[Screening report and raw evidence](results/20261030-screen/JSP-Oct26-Search-Escape-Report.md)
· [Live dashboard](http://127.0.0.1:60793/) · [Framework](README.md).

## Execution

Release 6 started on the Mac mini at **2026-10-30 23:48:03 JST**, after the
predeclared local screen and independent candidate checks. The older version-5
run was cooperatively stopped; its results, checkpoints, source and mirror were
preserved. Its best remained 14 wrong clues. The independently validated local
13-clue discovery seeded the new solve attempt. It is separate from the controlled
screening dataset.

Live telemetry confirmed all five repair operators executed, and the local
CP-SAT companion improved the 13-clue board's residual to 0.16496219632232606.
Eight workers were observed. Resource accounting motivated an additional archive
component benchmark; the report distinguishes that component result from any
whole-solver performance claim.

Release 7 resumed at **2026-10-30 23:58:45 JST** with the same search policy,
more efficient equivalent archive selection, all compatible branch stacks and
separate global-record/wrong-clue clocks carried forward. A native cross-release
process probe restored **29 repair jobs** and preserved the independently checked
incumbent. Release-6 source, binaries and results remain immutable and separate.

Current Mini root:

`/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-Search-Escape-20261030-235845`

Current local mirror:

`/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/mirrors/JSP-Oct26-Search-Escape-20261030-235845`

Controller PID **66390**; local read-only monitor PID **72928**; local one-core
CP-SAT companion PID **72934**. The current pointer is
`/private/tmp/jsp-cpu8-current.json`. It records exact paths and PIDs for safe
inspection; a process identity must be checked before any future signal.

## Resources and policy

- One Mini puzzle process, eight CPU threads: two incumbent repairs, four diverse
  islands, one broad/recombination worker, one protected exact-feasibility worker.
- One separate local CP-SAT process, `num_search_workers = 1`. It explores complete
  small neighborhoods and occasional explicitly restricted whole-board catalogs.
  It publishes only independently validated puzzle-matched improvements.
- Sequential 3,000-second native segments until independently solved, STOP or an
  actionable failure. New SA streams are used; compatible BP stacks are restored.
- Actual growth clocks are 60/180/600 seconds, not the accelerated probe clocks.
- Every new best flushes immediately. Latest complete worker-state mean energy is
  shown separately from protected-best energy. Exact partial branches have no
  complete-board energy and report their complete source/best instead.
- At 94 seconds of release 7, observed process CPU use was **7.74 equivalent
  cores**, with eight workers, 29 restored jobs, 47,213 protected BP expansions,
  551 distinct legal boards published and three migrations. Published boards are
  not all retained; the bounded archive held 16. These are counts, not completion
  percentages. CPU timing is descriptive, not a controlled before/after trial.

## Verification and preservation

All **16 shared Swift tests** and **six new escape-policy tests** passed locally.
Tests cover canonical boundary identity, actual whole-region growth, incumbent
preservation under worse migration, compatible restoration/rejection of mismatched
settings, exhausted-scope reuse and immediate new-record/clock publication.
Both releases passed native strict/current acceptance, older rejection, explicit
minimum-0 legacy acceptance and future rejection. Default current/minimum is now
**7**. Offline old checkpoints and seeds are explicitly checked; this does not
allow older worker reports. Wire framing is unchanged.

The Mini lacks XCTest. Its evidence is native builds, independent per-worker
validation, actual eight-thread probes and cross-release restoration. All builds
were isolated; no installed production coordinator/worker executable or network
credential was replaced. No fan, power or cooling settings were changed.

Mini source/build preparation is under
`/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/preparation/JSP-Oct26-Search-Escape-v7`.
The campaign records source/binary/seed/shape hashes, release preflight, prior run
identity and restoration verification. The shape store is the existing immutable
seed; lazy exact domains remain available to Swift. No live SQLite file was
transferred or synchronized through iCloud. Only closed JSON/source/report
artifacts were exported.

Create `STOP` under the current Mini root for cooperative cancellation. The queue
retains checkpoints and prevents more segments. The local CP-SAT companion sees
the stopped phase through the mirror and exits after its bounded current attempt;
it does not follow a new campaign silently. There is no estimated solve time or
claim that 13 incorrect clues means the puzzle is nearly solved.
