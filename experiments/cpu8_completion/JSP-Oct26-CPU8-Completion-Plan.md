# JSP-Oct26-CPU8-Completion-Plan

©2026 ThomasB

Author: ThomasB  
Date: 2026-10-30, Asia/Tokyo

Continue the CPU repair investigation on the Mac mini. Two fresh, sequential
original-11×11 trials compare B (persistent BP) and D (persistent BP with
route-guided repairs). Both use discrete regional SA, the existing shared rules,
exact lazy shape domain and eight cooperating CPU threads in one solver process.
No GPU calculations or fan/thermal-control changes are included.

Each method receives up to **3,000 elapsed seconds**, ending early on a validated
solution. The two trials use the same eight-seed schedule, starting at 2026103008
with the existing odd-stride derivation. Total worst-case search is 100 minutes;
the execution window is two hours from launch, leaving 20 minutes for scheduling,
validation and export. Never shorten a scheduled trial back to 1,200 seconds to
fit. Skip any job that cannot receive its full remaining allowance.

The original controls A and E are not rerun. C (route-only without persistence)
is not scheduled: all three new methods at 3,000 seconds would require 150 minutes.
B versus D tests route selection with persistence enabled in both. This is one
paired original-puzzle comparison, not a complete factorial or a multi-board
confirmation. Prior generated-board and interrupted trials remain a separate
immutable dataset. No uniqueness proof or clue alteration is performed.

Within a method, workers share a bounded archive of immutable candidate states.
Every receiver re-evaluates an import using the full-board integer rules. Two
workers remain independent explorers but publish discoveries and receive solved
states. Each worker owns its RNG streams, SA state, shape oracle, repair scheduler
and persistent BP jobs. Repair stacks retain their own fixed exteriors; they are
not shared or rebased when SA imports an incumbent. No incumbent, warmed mutable
oracle or repair stack crosses from B into D. Both load the same frozen read-only
shape seeds; loading and lazy generation remain timed.

The cooperative hook defaults to absent for older callers. Software version 3
records this change, the 3,000-second budget and per-thread CPU accounting. Wire
protocol schemas and existing saved-state fields are unchanged. Check strict and
transitional peer-version behavior. Build and test in scratch; this authorization
covers the isolated experiment, not replacement of the installed coordinator or
production workers. Existing run IDs, checkpoints, credentials and databases
remain intact.

Primary outcomes are independently validated solution and time to solution.
Record aggregate process CPU/wall ratio, each worker's thread CPU time, actual
energy and clue mismatch curves, iterations, repair-node/prune counters,
interworker exchanges/imports, and checkpoints. Node counters and elapsed-budget
bars are measurements, not percentages of the full search space. Report partial
or interrupted attempts separately from full 3,000-second timeouts.

A STOP file requests cooperative cancellation; the controller does not start the
next method afterward. Checkpoints preserve best boards and available BP state,
but do not imply exact transparent resumption. A host lock prevents two CPU8
campaigns from running at once. A read-only local dashboard mirrors JSON exports;
active SQLite files stay on their owning host. Only the already-frozen shape seed
file is copied within the Mini, after its hash is checked.

No fan speed, power limit, frequency lock or thermal override is configured.
macOS chooses CPU scheduling and cooling. Eight threads permit use of all eight
Mini CPU cores; measured utilization, rather than physical affinity, confirms
actual activity. The previous experiment remains paused.
