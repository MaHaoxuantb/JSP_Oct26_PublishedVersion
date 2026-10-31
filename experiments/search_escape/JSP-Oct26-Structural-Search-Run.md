# JSP-Oct26-Structural-Search-Run

©2026 ThomasB

Author: ThomasB

Goal: solve the original 11×11 puzzle using large-region construction, clue-derived
necessary constraints, local repair and preserved exact branching.

The original-quality incumbent remains 13 wrong clues. A separate 14-error
constraint-feasible discovery seeds the structural search. All measured checks
and limitations are in the [implementation report](results/20261031-structural/JSP-Oct26-Structural-Search-Report.md).

Resources: one Mini process, eight cooperating CPU threads; optional one-core
local CP-SAT companion. Two sequential 3,000-second segments; stop on a validated
solve, failure, or a cooperative STOP file. Fans and existing cooling controls
remain unchanged. The current pointer is `/private/tmp/jsp-cpu8-current.json`.

Release 9 and all earlier campaigns are preserved separately. Release 10 removes
repeated dynamic-shape validation overhead, with component results and checkpoint
verification recorded alongside the report. Live execution details follow after
native verification.


## Confirmed live continuation

Release **10** started at **2026-10-31T13:13:58.443670+09:00**.

- Mini root: `/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-Structural-Search-20261031-130850`.
- Frozen preparation: `/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/preparation/JSP-Oct26-Structural-Search-v10-20261031-130850`.
- Local mirror: `/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/mirrors/JSP-Oct26-Structural-Search-20261031-130850`.
- Controller PID: **73533**; local read-only monitor PID:
  **61705**; local CP-SAT companion PID: **61706**.
- Dashboard: <http://127.0.0.1:60793/>.
- Queue: two sequential 3,000-second segments, one eight-thread Mini process.
- Current pointer: `/private/tmp/jsp-cpu8-current.json`.

Native recovery restored all **29 repair jobs** and **four structural states**.
The preserved exact tree advanced from 17,853,448
to 17,857,012 nodes in the isolated 12-second
release-10 recovery probe. Strict/current, older rejection, explicit legacy
transition and future rejection passed with current/minimum version **10**.

At 112.3 seconds, the live process consumed
**7.69 CPU equivalents**. Between the 62.8-second and
112.3-second snapshots, each structural worker advanced from about 3,700–3,800
to 6,600–6,800 successful tiled proposals, and its tiling branch-node count grew.
All four best structural boards had zero implemented necessary violations,
maximum region size 26, and 14 wrong clues. The global incumbent remained
13 wrong clues, residual 0.16496219632232606. No solve is claimed.

Create `/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-Structural-Search-20261031-130850/STOP` for cooperative cancellation.
The companion stops after its bounded current model when it sees the stopped
phase; the HTTP monitor may remain available for reading/export. Inspect process
identity before any future signal. Installed production workers and credentials
were untouched. No fan or cooling controls changed.


## Resumed from the completed release-10 run

The prior two segments completed normally. The independently validated retained
board improved from 13 to **12 incorrect clues**, residual
**0.21498206164685196**, with zero structural issues; it remains unsolved.

A further continuation started at **2026-10-31T19:39:56.837222+09:00** using the existing frozen release-10
binary and source. No algorithm, dashboard, fan or cooling settings changed.

- New campaign: `/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-Structural-Search-20261031-193956`.
- Prior campaign: `/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-Structural-Search-20261031-130850`.
- Restored worker directory: `/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-Structural-Search-20261031-130850/original11-P-escape-0002`.
- Schedule: two more sequential 3,000-second segments, one eight-thread Mini
  solver, plus the local one-core constrained CP-SAT companion.
- The 12-error incumbent, structural working candidates and saved branching
  checkpoints carry forward. Stagnation ages include prior search time but exclude
  the stopped interval. New run outputs preserve all prior campaign artifacts.
- Dashboard: <http://127.0.0.1:60793/>; current pointer remains
  `/private/tmp/jsp-cpu8-current.json`.
- Cooperative stop: create `/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-Structural-Search-20261031-193956/STOP`.

The live dashboard timeline begins at this continuation's start; it does not
combine the earlier campaign's elapsed time. The original exact quality ordering
continues to prioritize incorrect clue count before residual.
