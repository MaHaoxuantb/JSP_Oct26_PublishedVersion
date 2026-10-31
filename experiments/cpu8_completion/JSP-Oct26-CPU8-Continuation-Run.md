# JSP-Oct26-CPU8-Continuation

©2026 ThomasB

Author: ThomasB

The user requested continuing the more promising persistent BP method toward a
solution of the original 11×11 puzzle. This is a solve attempt, not an extension
of the controlled B/D comparison. Its observations remain a separate dataset.

- Mac mini only; one native process with eight cooperating CPU threads.
- Discrete, regional SA with persistent BP, without route-guided repair scope.
- Initial states: the previous B run's eight saved worker incumbents, checked
  against the same 33 clues. Best starting quality: zero structural issues,
  14 incorrect clues, residual 0.17078226998999332.
- Sequential segments of 3,000 seconds. Each carries forward all worker
  incumbents and uses new random streams. In-memory BP stacks are rebuilt.
- Continue until a solution passes the independent Python integer rule checker,
  the user requests stopping, or a failure requires intervention. There is no
  promise of solving or estimated completion percentage.
- Native worker and continuation controller use release 5; strict peer default
  is 5. Original version-3 worker binaries and evaluation artifacts are retained.
- Build and testing are isolated. No installed production worker/coordinator,
  credentials, fan speeds, power controls, or live SQLite files are changed.

Validation: all 16 shared Swift tests passed locally, including solved warm-start
revalidation and rejection of malformed/non-finite initial states. Mini native
preflight and actual eight-worker continuation smoke checks are recorded with
launch details below. The Mini lacks XCTest; no Mini XCTest run is claimed.

## Launch and verified operation

Started **2026-10-30 22:50:21 JST**. Controller PID **56470**.
[Live dashboard](http://127.0.0.1:60793/) uses the existing address; the previous
completed evaluation mirror remains intact.

Remote campaign:

`/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-CPU8-Continuation-20261030-225021`

Local read-only mirror:

`/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/mirrors/JSP-Oct26-CPU8-Continuation-20261030-225021`

The Mini's isolated version-5 preflight passed: default/strict minimum 5 accepts
current, rejects older; explicit minimum 0 accepts legacy and rejects future.
Two five-second warm-start segments passed independent validation of all worker
states and retained the starting incumbent across a real segment handoff. CPU
usage measured 7.59 and 7.76 equivalent cores. A separate disposable check verified
cooperative cancellation and rejection of a duplicate controller before it could
create another solver. Smoke trials are excluded from the solve attempt.

At 35.5 seconds the real search had all eight workers active, approximately 7.78
CPU-equivalent cores, zero structural issues and 14 incorrect clues. The dashboard
was reloaded and verified to show the continuation settings and actual data.

Frozen allowlisted source hashes, binary/seed/shape hashes, launch metadata and
strict/transitional preflight results accompany the run. Source preparation:

`/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/preparation/JSP-Oct26-CPU8-Continuation-v5`

A STOP file in the remote campaign requests cancellation at the next cooperative
poll and prevents further segments. Raw observations and per-worker best-state
checkpoints are retained. The controller independently checks a final candidate
before marking the campaign `solved`; it stops on failures rather than silently
starting over. No deployment to the production network was made.
