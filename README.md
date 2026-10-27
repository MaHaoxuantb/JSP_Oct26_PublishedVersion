# JaneStreetPuzzle_Oct26

The default search now uses discrete partitions, exact shortest-path scores,
constrained region repairs and a shared elite archive across ten workers. The
continuous `Energy` API remains available for separate experiments; it no longer
drives the main search. Final solutions still require the independent integer
validator in `Validation.swift`.

## Distributed server and client

The same executable supports standalone search, a coordinator, or a compute client.
The coordinator never runs initialization, annealing or repair. It scores and
independently validates submitted boards. Standalone commands below remain
available without any server, certificate or token, including the direct `swiftc`
build with no package dependencies.

Build the network-enabled executable with Swift 6.1 or newer:

```sh
# Linux prerequisite: sudo apt-get install libsqlite3-dev
swift build -c release
swift test -c release
.build/release/janestreet-puzzle --server full --config Config/server.example.json
```

The initial supported platforms are macOS 13+ and Ubuntu 24.04, with CI checks for
both. Package tests use the built-in Swift Testing framework, available with
Swift 6.1+ toolchains, including Apple's Command Line Tools; XCTest is not required.
The worker concurrency annotation is conditional for Swift 6.2+, retaining support
for Swift 6.1. Xcode's existing target also includes the required Swift packages. Use
Release for actual computation. The sample configurations use `/tmp` for a local
demonstration; choose persistent, private state directories for real runs, outside
this repository, iCloud, network filesystems and other synchronization services.
Only one process may use a state directory at once. Configuration JSON overlays
`RunConfig` defaults; omitted fields retain their defaults. Distributed mode uses
the full puzzle unless `example` is specified; standalone mode retains its
original example default. IP addresses are numeric literals, with separate ports;
IPv6 interface scopes such as `fe80::1%en0` are supported. The default is IPv4
loopback port 8443; set the server bind address and each client's destination IP
explicitly for remote use.

On first server startup it creates a `join-token`. On **every** server startup it
creates a fresh private key and exports `server-certificate.pem`. Copy the public
certificate and join-token to each client over a trusted channel (for example,
your authenticated SSH connection or a local copy). Never download and trust a
certificate from an unauthenticated endpoint. The private TLS key stays in memory.
The server prints the public certificate location and its fingerprint, not the
token. For the sample client, copy those files into `/tmp/janestreet-client`, then:

```sh
.build/release/janestreet-puzzle --client --config Config/client.example.json
```

TLS 1.3 encrypts the connection. The exact copied certificate pins server identity;
public CA or DNS trust cannot substitute for it. A missing, changed or expired
certificate fails closed, before credentials are sent. After restarting the
server, copy its new public certificate to the same configured client path;
clients reload that file while reconnecting. Keep the join-token private and
consistent across server restarts. These controls are intended for trusted invited
devices, not a public volunteer computing service.

Clients default to logical CPU count minus one, at least one worker. Override
`distributed.clientWorkers` for shared-use machines. A five-second calibration at
the selected concurrency reports each slot's rate; real work updates the estimate.
Assignments target two minutes of work, with faster slots requesting more work
independently. Caches remain local and reusable. Roughly one quarter of assignments
explore independently; the rest share a diverse elite archive. Fixed operation
budgets define repair effort, with calibrated wall-clock safety limits (0.15–5s).
Network and storage waits run outside worker execution. Completed slots can do
supplemental local exploration while waiting for an assignment or reconnection.

Connections use bounded frames and one outstanding request per machine. Compact
canonical labels replace full snapshot/log transfers. Heartbeats default to 15s,
checkpoint capture/upload to 30s, and hard-disconnect grace to 180s; all are
configurable in `RunConfig.distributed`. Backup traffic has lower priority and a
64 KiB/s aggregate cap. Capacity defaults to 20 connections and at most 128 slots per
client. Distributed boards are limited to 121 cells, covering both bundled puzzles;
standalone mode retains its existing dimension support. Automatic concurrency is
capped at the configured slot limit. Excess clients retry; joining does not create a barrier for existing work.
The coordinator emits JSON status (active/completed jobs, reassignments, connected
clients, solution status and backup age) every 15 seconds. Actual solve time remains heuristic. Additional machines can add coordination
cost, and no universal speedup or solve-time guarantee is claimed.

### Process WebUI

Server mode also serves a read-only process dashboard at
`http://127.0.0.1:8080/`. It refreshes every three seconds with connected client IDs,
worker slots, assignment generations, objectives, reported iteration budgets and
elapsed time, completed job totals, reassignments and backup age. Progress reflects
the latest client heartbeat/checkpoint, rather than continuous measurements of the
remote operating system. Expired jobs remain visible as awaiting reassignment;
recovered jobs show reconnecting until their client returns.
The dashboard follows your system's light or dark appearance by default; its
appearance control lets you choose either theme and remembers your selection.

Configure `distributed.webUIEnabled`, `distributed.webUIAddress` and
`distributed.webUIPort` (see `Config/server.example.json`). The WebUI port is
separate from `distributed.port`, which remains the TLS compute-client port.
Set `webUIEnabled` to `false` to disable it. If the WebUI cannot bind its configured
address/port, the coordinator logs the error and continues serving compute clients.
The startup log prints the WebUI URL. The page and `/api/status` expose only
monitoring data, without tokens, certificates or configuration paths.

The WebUI uses HTTP without authentication and binds to loopback by default.
For remote viewing, forward its configured port over SSH, or explicitly bind it
to an interface on a trusted network. Client mode and standalone search do not
start a WebUI.

### Recovery

The server commits job ownership before dispatch, and progress/completion before
acknowledgment, in a local SQLite database with FULL synchronous commits. Its last
run resumes automatically. Use `--server full --new-run ...` only to deliberately
replace that run. A puzzle mismatch is rejected. Server state includes unfinished
jobs, assignment generations, elite boards and completion totals.

Clients persist their identity, received assignments, current/best labels and
pending reports. On recovery, work resumes from saved boards with fresh random
streams; temperature, caches and repair cursors are rebuilt. This is not exact
execution replay. Repeated work after failure is acceptable; no server-recorded
unfinished job is discarded because a device disappears.

Use Ctrl-C or SIGTERM for a clean quit. The client saves and attempts to release
all assignments; the server makes released work immediately available. On a hard
quit or network outage the server waits three minutes after the last heartbeat
before handing work to another machine. Reconnecting clients recover ownership
within that grace period. After reassignment, stale reports can contribute boards,
but cannot overwrite the new owner's progress or count completion again. Following
a server restart, recovered assignments receive a fresh reconnection grace period.
A client keeps searching during coordinator outages and certificate replacement.
Only previously uploaded checkpoints survive permanent loss of a client device.

Set `distributed.backupsEnabled` to enable periodic off-server recovery. Save
`recovery.key` **separately** from the server and replica clients; losing both the
server and this key makes encrypted backups unusable. Every five minutes, when a
previous transfer has reached a recipient, the server creates a consistent
encrypted recovery snapshot and copies chunks to up to two connected clients.
Transfer time can extend the interval; no search waits for replication. Each
client keeps the two latest complete `backup-*.encrypted` files. Transfer and
acknowledgment are idempotent, with ciphertext checksums and authenticated AES-GCM
encryption. A local encrypted snapshot is also kept as
`latest-backup.encrypted` and can be copied with:

```sh
.build/release/janestreet-puzzle --export-backup /safe/location/run.encrypted --config Config/server.example.json
.build/release/janestreet-puzzle --restore-backup /safe/location/run.encrypted /safe/location/recovery.key --config replacement-server.json
```

Restoration requires a new state directory and never overwrites an existing
database. It restores the join-token as well as search records. Start the restored
server with the same puzzle and redistribute its new public certificate. Surviving
clients reconcile durable assignments created after the backup. If the server
storage and those clients are permanently lost together, records created since
the last replicated backup may be lost. This periodic-backup recovery limit is
intentional; replication does not block assignment dispatch.

## Build and launch

Compile an optimized executable without running it:

```sh
swiftc -O -swift-version 6 -strict-concurrency=complete \
  -module-cache-path /tmp/janestreet-swift-module-cache \
  "$PWD"/JaneStreetPuzzle_Oct26/*.swift -o /tmp/janestreet-puzzle
```

Choose the puzzle at launch:

```sh
/tmp/janestreet-puzzle --run          # 5×5 example
/tmp/janestreet-puzzle --run example  # same example, explicitly
/tmp/janestreet-puzzle --run full     # full 11×11 puzzle, 33 clues
```

Both use seed 20261026 and ten workers. The configurations are available in code
as `RunConfig.example` and `RunConfig.fullPuzzle`; no source edit is needed to
switch puzzles. In Xcode, add `full` after `--run` in the scheme's launch arguments
to select the full puzzle.

The existing user-selected limits are retained: 100,000,000 repair jobs,
1,000,000 seconds and 20,000 restarts per worker. These are stopping budgets,
not estimated solution times. For a three-day budget set `timeLimitSeconds` to
259,200; any other stopping limit can still end the run sooner. Xcode's Run action
uses Release. Compilation never launches a search.

To resume from a best-board checkpoint or a completed worker JSONL:

```sh
/tmp/janestreet-puzzle --resume-log "/absolute/path/to/checkpoint-UUID.json"
```

This loads the saved puzzle and partition and starts a new ten-worker search
with fresh budgets/RNG streams. It does not restore the exact annealing, cache,
worker or random-generator state. Modern saved settings are preserved; old logs
use compatible defaults for missing fields. Output goes into a new project log
folder; the source file is unchanged.

To repair an existing JSONL log without starting another annealing run:

```sh
/tmp/janestreet-puzzle --repair-log "/absolute/path/to/run.jsonl"
```

This reads the saved puzzle configuration and final snapshot, then spends at
most five seconds trying connected merges of two through four regions. It
writes a separate result under `<project>/logs/repairs/`. Original logs are
untouched. Failure of this bounded repair does not prove that no solution exists.
Old logs are supported even if their configuration lacks the new repair settings.

## Search and performance

### GPU path evaluation

`pathEvaluation` selects `automatic` (default), `cpu`, or `gpu` in the JSON
configuration. To request GPU paths explicitly:

```sh
.build/release/janestreet-puzzle --run full --config Config/gpu.example.json
```

Merge, boundary and completed exact-cover candidates are scored in batches of up
to 32 boards. Only shortest-path distances move to the GPU. Region geometry,
clue comparisons, normalized errors, annealing probabilities and final independent
validation remain on the CPU. GPU paths use Int32 throughout: for at most 121
cells, sizes are at most 121 and a shortest simple path costs at most 14,520.
The infinity sentinel is 536,870,911; adding one edge cannot overflow.

Each returned distance map must pass a CPU shortest-path certificate: sources
have distance zero, every finite non-source has a strictly descending tight
predecessor, and every edge satisfies the distance inequality. Parents use the
same distance/index tie ordering as CPU Dijkstra. Invalid results or device errors
disable GPU evaluation for that worker and recompute the batch on the CPU. A
proposed solution still requires `ExactValidator`, independently of that check.

Automatic mode uses CPU paths for single boards, small boards and batches with
fewer than eight uncached candidates. For the first eligible batch it warms up the
GPU, compares exact results and measures GPU evaluation plus certification against
CPU Dijkstra. If the GPU is slower it uses CPU paths thereafter. Explicit `gpu`
mode skips that speed decision, but retains certification and failure fallback.
Device selection/fallback is printed with a `[paths]` prefix. GPU batching delays
incumbent updates within a repair, so bounded search trajectories can change even
when every distance and score agrees. Batches are flushed when enumeration ends,
including at a deadline; this adds at most one pending batch of evaluation work.

macOS uses a runtime-compiled Metal kernel with one SIMD group per board. Linux
SwiftPM builds include a small C bridge that dynamically loads `libcuda.so.1` and
NVRTC (`libnvrtc.so`, `.13`, `.12`, or `.11.2`). Linux GPU execution requires an
NVIDIA GPU with compute capability 7.5 or newer and compatible driver/NVRTC
libraries on the system loader path (see NVIDIA's [NVRTC documentation](https://docs.nvidia.com/cuda/nvrtc/)). No CUDA headers, CUDA link-time libraries,
MLX dependency, or newer Swift toolchain are required to build the CPU solver.
Machines without a supported GPU fall back to CPU. The direct `swiftc` Linux
build omits the CUDA bridge and uses CPU paths; use SwiftPM for Linux GPU support.
Distributed clients select this policy locally with their own `pathEvaluation`
setting, including during recovery and calibration.

The Metal and CUDA kernels use double-buffered integer Bellman-Ford relaxation,
stopping when no cell changes or after V-1 rounds. GPU acceleration is optional:
on the development Mac, the fixed 32-board fixture remained slower than CPU
Dijkstra after parallelization. No end-to-end search speedup is claimed. Real
Metal execution is covered by the differential tests; CUDA hardware execution
must be verified on an NVIDIA Linux host before relying on its performance.

`swift test -c release` includes GPU/CPU differential tests, certificate rejection,
device failure fallback, batch scoring, cache isolation and old-config decoding.
Set `JSP_REQUIRE_GPU=1` when testing on a GPU host to make unavailable hardware a
test failure instead of a skip. CI also exercises the CPU-only Linux fallback.

### CPU search and shared heuristics

- Search candidates retain canonical integer labels. UUID-backed `Board` objects
  and display energy matrices are materialized only for reporting, snapshots or
  independent validation. A bounded per-worker cache reuses exact partition scores;
  saved boards and materialized copies remain isolated.
- Region geometry caches both positioned shapes and translation-normalized shapes.
  Bounded FIFO eviction preserves other entries instead of clearing the whole
  cache. Grid neighbor lists are precomputed.
- Exact distances use multi-source heap Dijkstra on boards of at least 64 cells;
  smaller boards retain the simple array scan. Both implementations are tested
  against each other and the independent validator. No approximate distance is
  used to declare a solution.
- Clue propagation rejects impossible shapes before scoring. Adjacent clues `a,b`
  force both containing states to have size at least `abs(a-b)`. A state's internal
  path to its own capitol cannot cost less than a contained clue. Zero/positive
  capitol constraints and the adjacent-singleton requirement for one clues remain.
  These are necessary conditions, not a replacement for full validation.
- Initialization combines rectangles, bent triominoes and connected symmetry-orbit
  growth around zero clues. The rectangle size allowance reflects inferred minimum
  areas. Forced corner capitols can receive nonrectangular states. Valid palette
  shapes are reused between restarts and in overlapping patch catalogs, with
  periodic growth samples for diversity. A bounded failure still falls back to
  singleton states; this fallback need not satisfy clues.
- Connected two-to-four-state merge enumeration retains its resumable cursors.
  Most repairs use up to 32 cells. Every twelfth proposal allows a larger patch of
  up to 128 cells and up to eight adjacent states. This is a search allowance, not
  an exhaustive enumeration guarantee.
- Orbit transfers, single-cell transfers and straight-cut splits can change states
  larger than either patch allowance. Both resulting shapes must pass geometry
  and clue deductions. These moves may be accepted uphill by annealing.
- Exact cover uses arbitrary-width bitsets for overlap checks (two words cover the
  entire 11×11 board). It chooses the cell with fewest available shapes, stops
  scanning a candidate list once it cannot beat the incumbent count, and respects
  node/cover/time budgets. Large shape sampling does not shift a machine word by
  the number of patch cells.
- On larger boards, fixed routes through assigned states supply lower bounds on
  mismatch/error. These are periodically compared with the best complete cover
  to prune branches that cannot improve it. An imperfect fixed exterior does not
  forbid all repair. `useRouteBounds` can disable this optimization for comparisons.
- Workers rotate between exact-match, residual-error and persistently-wrong-clue
  objectives. Final ranking remains structural issues, wrong-clue count, then mean
  normalized error. Success always requires independent exact validation. The elite
  archive keeps the exact-match and residual leaders plus partitions with different
  boundaries. Workers 4 and 8 remain independent explorers.
- Cooling retains its measured acceptance floor and reheating policy. The search
  remains heuristic: shape catalogs, merges, cover searches and repair attempts
  are bounded. More speed or more time does not guarantee an 11×11 solution.

The default per-job deadline remains 0.15 seconds, with 1,000 merge checks,
12,000 sampled catalog masks, 5,000 cover nodes and 48 completed covers. Catalog
sampling, geometry restrictions, cache hits and different worker objectives can
change the search trajectory. Per-worker seeds are reproducible with fixed work
budgets, but wall-clock cutoffs and concurrent archive arrivals affect full runs.

## Logs, checkpoints and verification

Logs stay in `<project>/logs/parallel-<UUID>/`, with a coordinator JSONL and one
subdirectory per worker. Console progress continues roughly every two seconds,
plus milestones. File writes are immediate; expensive synchronization is batched
at roughly two seconds and forced for completion, failure and checkpoint events.

Full proposed/failed boards are not logged. Each worker writes an atomic
`checkpoint-<UUID>.json` after initialization, every 60 seconds and at completion,
replacing that file with its best board. JSONL retains compact milestones and the
final snapshot. The final console result still includes the region-size matrix,
row sums, puzzle score, energy and explicit validation status.

Repair metrics now include cache hits, constraint rejections, route prunes,
boundary checks and elapsed seconds in evaluation, distances, geometry, catalog,
merge, boundary and cover work. **Timings are inclusive:** distance/geometry are
inside evaluation, and evaluation can be inside cover/merge/boundary. Do not sum
all fields as if they were disjoint CPU times. Summed worker durations can exceed
wall time because workers run concurrently.

Bounded checks cover the saved 8045 repair, all 511 nonempty 3×3 shape masks,
deductions on 129 independently validated legal partitions, randomized heap/scan
comparisons, 11×11 independent distance checks, cache and snapshot isolation,
bitsets beyond 64 cells, a valid split of a 70-cell state, route-bound comparisons,
checkpoint reload/resume, deterministic proposals and ten-worker lifecycle logs.
`Tests/OptimizationTests.swift` also times fixed shortest-path inputs; it does not
launch a full fresh puzzle search.

A local optimized fixed-data comparison against the preceding implementation
measured 512 first-time 11×11 candidate evaluations at 0.065s versus 0.027s, and
20 revisits of that pool at 0.905s versus 0.047s. Checksums agreed to floating-point
rounding. These are component measurements on a synthetic partition pool, **not
an end-to-end solve-time claim**. Full fresh-search benchmarking remains a separate
opt-in action in `Tests/SearchBenchmark.swift`.

The following continuous APIs are retained for experimentation:

```swift
let energy = Energy()
let fields = energy.CapitolCal(Board: board)
let scores = energy.RealAIMTest(Board: board, Target: config.Target)
let combined = energy.EnergyCal(Board: board, Target: config.Target,
    Factors: .init(realAIM: 2, symmetry: 1, discreteness: 1))
board.Energy = combined
```

`ColorBlocks` must already describe the proposed states. These functions read the
board without mutating it. `RealAIMTest` takes the clues explicitly: `-1` is blank,
and `0` is a real clue.

`EnergyCal` combines the AIM, symmetry, and discreteness matrices using three
relative factors. Factors default to `1, 1, 1`; each must be finite and
nonnegative, and at least one must be positive. The factors are normalized to
sum to 1, so the result stays within `[0, 1]`. A zero factor removes that
component's contribution. The returned matrix can be assigned to `board.Energy`.

`DiscretenessTest` returns a board-sized cell matrix. An edge with strength `p`
scores `tan(2 * min(p, 1-p)) / tan(1)`: 0 at either endpoint and 1 at 0.5.
Each cell receives the mean of its existing incident edge scores, using the
actual neighbor count at boundaries. A single cell with no edges scores 0.

Each UUID has a `CapitolField` containing `(row, col, probability)` candidates in
row-major cell order, one per cell. Coordinates are continuous, with integer
coordinates at cell centers. Probabilities are numerical integration weights:
they sum to 1 within each block and approximate a normalized area distribution.
This finite quadrature is not an analytic continuous density. Exact capitols
use a point mass (one weight of 1, all other weights 0).

For tentative fields, the seven nonidentity D4 transformations are aligned at
the bounding-box center. A transformation's weight is `exp(-8 * (1 - overlap))`,
where overlap is the fraction of unit-square area shared with the original
shape. Candidate masses favor cells with low weighted squared displacement
under those transformations. Each position moves halfway toward its weighted
transformed position, capped at 0.49 cell lengths per axis to preserve ownership.
The masses are normalized using a stable exponential calculation. These choices
define a heuristic distribution; they are not calibrated statistical probabilities.

A connected exact symmetric state has a capitol only when every nonidentity
symmetry fixes the same single cell. Exact symmetric states without capitols
and disconnected UUID groups still have normalized fields, but their
`canBeDestination` flag is false. Asymmetric connected states provide tentative
destinations during the search.

Travel follows the orthogonal cell graph. Edge costs are the smaller of the two
state sizes. A candidate is attached to its owning cell center by a fractional
Manhattan terminal segment, charged at that state's size. This is a numerical
extension of the puzzle's graph, not an unrestricted path through the plane.

The capitol locations of different states are modeled independently. For each
clue, compute the expected error of the nearest capitol using
`abs(cost - target) / max(cost, target, 1)`. The calculation uses survival
probabilities to avoid enumerating all combinations of candidate locations.
Every energy lies in `[0, 1]`; blank cells get the global mean clue energy.
No clues or no eligible destinations give energy 1. `RealAIMTest` is a search
heuristic and must be combined with `SymmetricalTest` when checking validity.

Run the standalone checks from the repository root:

```sh
swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
  JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
  Tests/SymmetryEnergyTests.swift -o /tmp/symmetry-energy-tests
/tmp/symmetry-energy-tests

swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
  JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
  Tests/RealAIMEnergyTests.swift -o /tmp/real-aim-tests
/tmp/real-aim-tests

swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
  JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
  Tests/CombinedEnergyTests.swift -o /tmp/combined-energy-tests
/tmp/combined-energy-tests
```

Compile the solver integration checks without running them (the test provides
its own entry point, so `main.swift` is excluded):

```sh
swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
  JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
  JaneStreetPuzzle_Oct26/RunConfig.swift JaneStreetPuzzle_Oct26/Runners.swift \
  JaneStreetPuzzle_Oct26/Logger.swift JaneStreetPuzzle_Oct26/SearchSupport.swift \
  JaneStreetPuzzle_Oct26/Validation.swift JaneStreetPuzzle_Oct26/Solver.swift \
  JaneStreetPuzzle_Oct26/ExactSearch.swift JaneStreetPuzzle_Oct26/PathEvaluation.swift \
  JaneStreetPuzzle_Oct26/RegionRepairs.swift \
  JaneStreetPuzzle_Oct26/SharedSearch.swift JaneStreetPuzzle_Oct26/SavedRunRepair.swift \
  Tests/SolverTests.swift -o /tmp/janestreet-solver-tests
```

These cover independent copies, component construction, the exact example
answer of 8045, deterministic proposals, bounded search, cancellation, reheating,
restarts, ten-worker isolation and seed assignment, parallel cancellation,
aggregate statistics, and JSONL log decoding. Execute the resulting test binary only when
ready to run checks.

Compile the fixed-fixture diagnostics or opt-in benchmark using the same source
list (excluding `main.swift`), replacing `Tests/SolverTests.swift` with
`Tests/RepairTests.swift`, `Tests/OptimizationTests.swift` or `Tests/SearchBenchmark.swift` respectively. Use `-O`
for timing measurements. The benchmark executable remains idle unless passed
`--run [trials] [seconds-per-trial]`; defaults are five trials of twenty seconds,
each using ten workers. It writes solve rate inputs, elapsed times, wrong-clue
counts, exact evaluation counts and log paths to `benchmark.json` in the project
logs folder. Fresh-search reliability must be measured separately from the fast
saved-board repair; no speedup or 11×11 solve guarantee follows from that fixture.
