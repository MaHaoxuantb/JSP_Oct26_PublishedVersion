# JSP-Oct26-CPU8-Completion

©2026 ThomasB

Author: ThomasB

Eight cooperating CPU threads, one original 11×11 puzzle and one method active at
a time. See the [execution plan](JSP-Oct26-CPU8-Completion-Plan.md). Original
controls are excluded. The original 3,000-second plan was amended to 1,800 seconds per method to meet the user’s one-hour evaluation deadline.
The [current run record](JSP-Oct26-CPU8-Completion-Run.md) contains the actual
launch time, live dashboard and durable data paths.

`Sources/CPU8Worker/main.swift` combines existing `SearchEngine` and
`RepairScheduler` instances with a synchronized bounded candidate archive. Private
repair stacks/oracles remain worker-local. `campaign.py` owns the sequential
host-local queue and independently checks final partitions. `monitor.py` provides
a read-only local progress/chart mirror. `build.py` creates isolated native
products and verifies version-3 strict/transitional compatibility with the existing
production preflight.

The shared exchange hook is optional; single-search callers keep their default
behavior. Thread CPU clocks avoid counting all eight threads in each worker's
CPU observation. No existing checkpoint/result schema fields were removed. No
production executable is replaced. Fan, power and thermal controls are untouched.

Each run freezes source/binary hashes and records independent outputs. The worker
pool shares discoveries only within one method. Trials start fresh because the
resource allocation differs from earlier single-thread experiments; old results
are not relabeled as eight-core trials or merged into continuous solve times.

`adopt_deadline.py` preserves the live native PID while replacing only the scheduler. `finish_hour.py` independently validates and plots the completed evaluation automatically. Version-3 worker binaries stay fixed across B and D; version 4 records the deadline controller/UI amendment.

## Incumbent continuation (release 5)

`continue_search.py` runs method B alone in sequential segments of at most 3,000
seconds, using eight cooperating CPU threads. It seeds every worker from the
previous segment's saved best states and retains the global incumbent. New random
streams and in-memory BP stacks are created at segment boundaries; this is not
exact process/RNG/stack resumption. The original B/D evaluation stays immutable.
Each seed is checked against the same puzzle and independently validated. The
Swift harness re-evaluates saved strengths and checks their labels and quality.
Final results and every worker's partition are independently checked in Python.
Only an independently validated solution ends the search successfully. A STOP
file requests cooperative cancellation; failures stop the queue and retain raw
observations and checkpoints. A host lock and process check prevent duplicate
CPU8 solvers. A fresh campaign directory and isolated version-5 binary are used;
installed production executables and credentials are not modified. Cooling
controls stay unchanged. The live dashboard uses the continuation's actual data.

`SearchEngine.run(initialState:)` has a default of `nil`, preserving fresh-start
callers and saved input decoding. The release authority is 5; the continuation
accepts only version-5 worker results. There is no wire framing change.
