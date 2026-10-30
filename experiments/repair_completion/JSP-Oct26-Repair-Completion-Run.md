# JSP-Oct26-Repair-Completion — paused campaign

©2026 ThomasB

Launched **2026-10-30 19:40:36 JST** after the isolated implementation and
preflight checks. [Live dashboard](http://127.0.0.1:56035).

**Paused at the user's request on 2026-10-30 at 20:10:39 JST on both Macs.**
Both agents report `stopped`, with zero experiment workers running. Of the 35
scheduled trials, four reached their time limit, eight were interrupted and 23
remain pending. There are no validated solves in this partial dataset. Best-board
checkpoints, available BP-stack snapshots and raw observations are retained.
Interrupted attempts are not completed timeouts or exact, transparently resumable
processes. No search has been restarted.

The coordinator finalized the partial report and evidence ZIP; the read-only
dashboard remains available. The deadlines and completion estimates below are
historical launch settings, superseded by this pause. The campaign initially
launched the local fallback below; the Mini subsequently joined.

- 20 real trials; four concurrent single-search CPU processes on this Mac.
- Boards: n7-b1, n8-b1, n9-b1 and the original 11×11.
- One new matched seed (2026103001), all five methods A–E on every board.
- Per-trial limit: 1,200 seconds, or an earlier independently validated solve.
- Approximately 100 minutes of maximum search, plus small scheduling overhead.
- Fixed search deadline: **2026-10-30 21:32:36 JST**.
- Campaign/report deadline: **2026-10-30 21:40:36 JST**.

The detached agent owns its queue and workers. The detached coordinator exports
observed results and creates the final evidence ZIP automatically. The dashboard
remains available after search finishes. The previous campaign stays paused.

Campaign data (outside iCloud):

`/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-Repair-Completion-20261030-194036`

Public report outputs are under `combined/report/` in that directory:

- `JSP-Oct26-Repair-Completion-Report.md`
- `JSP-Oct26-Repair-Completion-Report.html` (offline page with recorded charts)
- `JSP-Oct26-Repair-Completion-Trials.csv`
- `JSP-Oct26-Repair-Completion-Results.json`
- `JSP-Oct26-Repair-Completion-Evidence.zip` (created at completion)

The frozen `manifest.json` records software version 2, source and binary hashes,
shape seed hash, host CPU configuration and version-compatibility preflight.
Binaries are isolated campaign copies. Existing production executables, live
credentials, and the previous campaign's measurements were not replaced.

A `STOP` file in this campaign directory requests termination of this campaign's
searches. Checkpoints remain available; interrupted attempts are excluded from
full-timeout counts. The current runner refuses to silently replay existing
running jobs or merge restarts into continuous solve time.

[Plan](JSP-Oct26-Repair-Completion-Plan.md) · [Pre-launch verification](JSP-Oct26-Repair-Completion-Verification.md) ·
[Framework documentation](README.md) · [GPU investigation](JSP-Oct26-GPU-Offload-Investigation.md).

## Mini admission amendment

The Mini became reachable through **192.168.4.173** and joined at **2026-10-30 20:08:21 JST**.
Its profile is Mac14,3, four performance cores, 16 GiB RAM, macOS 15.5, Swift
6.1.2 and Python 3.9.6. Native release builds use the same frozen Swift search
sources as this Mac; the compiler and binary hashes are recorded separately.

- Mini workload: **15 trials**, all five methods on n7-b2, n9-b2 and the original
  11×11, with matched seed 2026103002 and four concurrent processes.
- N=8 on the Mini was omitted because a full 20-trial workload would exceed the
  remaining window. No method was omitted within a scheduled board/seed block.
- Combined workload: **35 trials** (20 local + 15 Mini). All trial limits remain
  1,200 seconds. The existing search and reporting deadlines were not extended.
- Estimated Mini completion is approximately 21:28 JST if every trial uses its
  full allowance. The fixed search deadline is 21:32:37 JST.
- The same [dashboard](http://127.0.0.1:56035) shows both hosts. Pair comparisons remain
  within host, puzzle and seed; the two hardware/compiler environments are not
  treated as identical machines.

Mini data directory:

`/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-Repair-Completion-20261030-194036-mini`

The Mini has Command Line Tools without XCTest. Equivalent standalone policy
assertions (four factor settings and 100 route scopes) passed, followed by all
20 short process checks across the five methods. These checks are excluded from
the timed dataset. Its real queue was created with exactly 15 jobs and passed
the independent fixture admission checks.

Only static source, frozen shape seeds and completed JSON exports were transferred.
The Mini owns its own active queue and checkpoints. This Mac's local worker agent
was left running; only the export coordinator restarted to read the new peer.
The admission config amendment is retained under the local campaign's
`amendments/` directory. No installed production binary was replaced.
