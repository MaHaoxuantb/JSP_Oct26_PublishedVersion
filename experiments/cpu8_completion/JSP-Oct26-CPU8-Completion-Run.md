# JSP-Oct26-CPU8-Completion-Run

©2026 ThomasB

Author: ThomasB

Started **2026-10-30 21:12:36 JST**.

**Amended at the user’s request to finish the evaluation within one hour of 21:18:50 JST.** The active B process was adopted without restarting it. Both methods now have a 1,800-second total budget; the original 3,000-second plan remains in the saved amendment history. [Live dashboard](http://127.0.0.1:60793).

- Mac mini only, CPU-only, one puzzle solver process at a time.
- Original 11×11 puzzle; eight cooperating CPU threads per method.
- B: persistent BP; D: persistent BP plus route-guided repairs.
- Each method now has an effective **1,800-second** cutoff (original plan: 3,000 seconds), or an earlier independently validated solve.
- Controls A/E are not rerun. Route-only C is excluded to fit the two-hour budget.
- Expected search completion: approximately **2026-10-30 22:13 JST**, assuming both use their full allowance.
- Search cutoff: **2026-10-30 22:13:50 JST**.
- Final evaluation/report deadline: **2026-10-30 22:18:50 JST**, one hour after the user’s request. No extra trials are scheduled. The former 23:12:36 execution deadline is superseded.
- Fan, power and thermal settings are untouched. Cooling stays under existing controls.

The first real trial was verified running with all eight workers observed and
approximately 7.8 CPU-equivalent cores. Each method begins fresh with the same
eight-seed schedule; no incumbent or mutable cache crosses methods. The old paused
campaign and the completed GPU comparisons remain separate datasets.

The shared solver's cooperation hook defaults to absent, while the new harness
opts in. Version 3 records the hook, 3,000-second limit and thread CPU accounting.
All 15 shared tests passed locally, including imported-solution validation,
malformed imports and cancellation of a 3,000-second budget. Both five-second
Mini smoke trials passed independent Python validation with eight workers, about
7.8 process CPU equivalents and real interworker imports (17 and 16). Thread
CPU/wall ratios were approximately 0.97–0.98. Smoke results are excluded.

Version-3 preflight passed on both hosts: default minimum peer 3, current accepted,
older rejected, explicit minimum-0 legacy accepted, future version 4 rejected.
The existing installed coordinator and binaries were not updated; this standalone
experiment does not join the production network. The Mini lacks XCTest, so its
checks are native builds and real eight-thread process probes, not a claimed
Mini XCTest suite run.

Remote durable data:

`/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-CPU8-Completion-20261030-211236`

Local read-only JSON/report mirror:

`/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/mirrors/JSP-Oct26-CPU8-Completion-20261030-211236`

The Mini controller owns the sequential queue and independently validates each
finished trial before exporting Markdown, CSV and JSON. The local monitor keeps
the dashboard available and copies final static exports when the queue ends.
No active SQLite database is transferred. A STOP file under the remote run root
requests cooperative cancellation and prevents the second method from starting.
Checkpoints are retained; interrupted attempts are not relabeled as full trials
or silently merged into continuous solve time.

[Plan](JSP-Oct26-CPU8-Completion-Plan.md) · [Framework](README.md).


## One-hour amendment and automatic report

The original native worker binary remains version 3 for **both** methods. Version
4 records the replacement deadline controller and dashboard amendment. Its explicit
minimum worker version is 3, preserving this in-flight evaluation; unversioned,
older-than-3 and future-above-4 results are rejected. Version-4 default strict
and explicit legacy transitional preflight tests passed in an isolated build.
The old scheduler exited, while native PID **43624** and its elapsed search state
were preserved. The replacement scheduler PID is **46273**.

A disposable integration test verified PID preservation, amended cooperative
cancellation, protection of independent user STOP requests and sequential launch
of the next job. Report generation and independent validation passed on the
completed CPU8 smoke fixture. These checks are not timed evaluation trials.

The live queue writes `budget_timeout` for B's externally enforced amended budget,
while retaining its raw original input, native cancellation reason and results.
It does not relabel this as a completed original 3,000-second trial. D starts fresh
with a native 1,800-second budget. The original manifest and version-3 frozen
source remain unchanged; prior configuration, snapshot, controller hashes and
preserved PID are recorded under `amendments/hour-deadline-v4/` on the Mini.

Automatic final validation, plots and the comparison report are scheduled by a
bounded local finalizer, not dependent on another chat turn. The final artifact
is `JSP-Oct26-CPU8-Completion-Evaluation.md` in the local mirror directory above,
with a corresponding energy PNG and machine-readable summary. If data transfer
fails, the finalizer marks stale/incomplete evidence instead of claiming missing
work completed. No original approach is rerun and no fan settings are changed.
