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
for Swift 6.1. Collections is pinned to 1.6.0 because the newer 1.7.5 dependency
requires Swift 6.4; keep this compatibility constraint when updating packages.
Xcode's existing target also includes the required Swift packages. Use
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

Known cloud-synced state paths (including symlinks into iCloud Drive and macOS
CloudStorage) are rejected before opening a database or acquiring a process lock.
Keep source code in iCloud if desired, but keep distributed state on a local disk.
The path check cannot recognize every custom sync folder or network mount.

If an existing config uses a synced directory, stop all processes using that state
on every machine, then migrate on each host separately to a **new** local directory:

```sh
python3 Scripts/migrate_state.py --config Config/client.json \
  --destination "$HOME/.local/state/janestreet-puzzle-client"
.build/release/janestreet-puzzle --client --config Config/client.json
```

The tool holds the state lock, copies databases with SQLite's backup API, checks
their integrity, copies worker logs and credentials, and updates the config last.
It preserves the original files and saves the old config in the destination as
`config.before-migration.json`. An existing destination is never overwritten.
Partial failed copies are retained for inspection; choose a new destination for a
retry. Sync conflict copies such as `client 2.sqlite` are left in the source for
manual inspection, rather than merged or substituted for the configured database.
If the directory was renamed, pass `--source-directory /actual/state/path`.
After identifying a worker's actual conflict copy (for example, through its open
files and saved client ID), select it explicitly with `--client-database 'client 2.sqlite'`;
the destination will use the canonical `client.sqlite` name and preserve its ID.
Copy updated server certificates to the **new** configured certificate path after
server restarts. Never synchronize, rename or replace an open SQLite database,
or move its parent directory. Stop first, then update the configured absolute path
before restarting; moving a project does not update paths stored in JSON.

Database errors include the path, operation and extended SQLite code. Code 1032
(`SQLITE_READONLY_DBMOVED`) means the open database was moved or replaced; other
read-only failures may involve file or parent-directory permissions. Local storage
failures stop the client instead of being retried as coordinator outages. Errors
returned by the remote server are marked `Coordinator reported:`; fix that server's
state directory when the path belongs to it. Network outages still allow local
work and checkpoints while local storage is healthy. Repeated identical GPU path
selection/fallback notices are printed once per process; each worker still makes
its own CPU/GPU performance decision.

Finished assignments remain pending until the coordinator acknowledges them;
an echoed assignment never starts another iteration. On reconnect the client
fetches committed assignment progress before sending local reports, so a stale
checkpoint cannot move the coordinator's counters backwards. Checkpoints from
older clients that exceeded an assignment's budget are repaired on load while
retaining their candidate boards. Do not delete `client.sqlite` to recover from
that bug. Permanent report/authentication rejections stop with the reported error;
temporary network, coordinator-storage and capacity failures still retry.

TLS 1.3 encrypts the connection. The exact copied certificate pins server identity;
public CA or DNS trust cannot substitute for it. A missing, changed or expired
certificate fails closed, before credentials are sent. After restarting the
server, copy its new public certificate to the same configured client path;
clients reload that file while reconnecting. Keep the join-token private and
consistent across server restarts. These controls are intended for trusted invited
devices, not a public volunteer computing service.

Machines use their system computer name by default. Set `distributed.machineName`
in each machine's config to override it, or pass `--machine-name "Workshop Mac"`
when launching either role. The command-line name takes precedence; omitting the
setting or using an empty name restores the system default. Names appear in logs,
the dashboard's machine list and worker assignments. Client UUIDs remain the stable
identity, so renaming a machine does not discard work. Names are limited to 128
characters and 1024 UTF-8 bytes, without control characters. Older clients that do
not send a name still work and appear by UUID until upgraded.

Clients default to logical CPU count minus one, at least one worker. Override
`distributed.clientWorkers` for shared-use machines. A five-second calibration at
the selected concurrency reports each slot's rate; real work updates the estimate.
Timed calibration begins after initialization with a fresh deadline and counts
only proposals, excluding empty attempts. Live iteration counters still count
all attempted iterations, so the initial estimate is conservative.
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

Server mode serves a search dashboard at `http://127.0.0.1:8080/` by default.
It refreshes every three seconds and shows:

- The best independently checked candidate and a bounded archive of diverse alternatives,
  colored region boards, capitals, incorrect clues, structural violations, and candidate JSON downloads.
- Candidate ranking by structural issues, then incorrect clues, then normalized clue error.
  Only an independently validated solution displays the final puzzle answer.
- Persistent improvement history, discovery machine/slot/objective, estimated fleet throughput,
  and accepted iteration totals recorded since this metrics version was installed.
- Machine names and stable IDs, heartbeat and checkpoint freshness, worker activity,
  CPU/Metal/CUDA path selection and fallback explanations, assignment budgets,
  completed jobs, reassignments, and backup age.
- Bounded event and management command histories that survive coordinator restarts.

Charts reflect client reports, not continuous operating-system measurements. Estimates are
not a solution completion percentage or ETA. Per-slot rates use coordinator-accepted iterations divided by reported worker time;
calibration estimates are used for assignment sizing and are excluded from these charts;
accepted work counts only new coordinator-committed iterations, excluding duplicate reports,
stale owners and unreported supplemental work. Older completed work is not reconstructed.
The dashboard supports system, light and dark appearance.

Configure `distributed.webUIEnabled`, `distributed.webUIAddress` and
`distributed.webUIPort` (see `Config/server.example.json`). This HTTP port is separate
from the TLS worker port. The default bind is loopback. A LAN bind enables read-only
monitoring over HTTP; **management requires a loopback URL over local access or an SSH
tunnel**, a matching browser Origin, and a separate admin token. It never uses the
worker join token. The server creates a private `web-admin-token` file in its state
directory on first dashboard startup; read it locally or over trusted SSH and paste it
into "Unlock controls". The page keeps it in memory until locked, refreshed or closed.
Do not distribute this token with client configuration.

For a Mini with WebUI port 9999, forward a local port, then visit
`http://127.0.0.1:9999/`:

```sh
ssh -N -L 127.0.0.1:9999:127.0.0.1:9999 thomasb@192.168.4.173
```

Management actions target client UUIDs, with names for display:

- **Checkpoint & quit:** cancel cooperatively, save current/best boards, report final
  progress and release assignments, then exit. This stops the puzzle process.
- **Drain & quit:** finish assigned jobs, take no new assignments or supplemental work,
  submit progress, then exit. Slow jobs can delay this action; checkpoint & quit can replace it.
- **Pause / Resume:** save and release assignments while keeping the client available
  for subsequent commands. Pause survives a client restart and suppresses offline work.
- **Set workers:** adjust active slots from 1 to the client's configured capacity;
  excess slots are checkpointed and released. Increasing the configured maximum still
  requires editing client configuration and restarting it.
- **Checkpoint:** force a durable client checkpoint without changing its desired mode.

Commands are durable and idempotent, and carry the current run ID. Queued commands remain
pending while clients are offline; delivery follows heartbeat/reconnection cadence.
The UI shows client acknowledgments, not an assumption that a request succeeded.
"Released" means the coordinator committed the final release, not OS-level proof of process
exit. Clients without management support show unsupported controls. New commands replace
previous desired state, and queued/draining predecessors show superseded. Graceful shutdown
is cooperative; a long operation can delay cancellation. Starting a quit client again requires
launching it locally or through a separate service; an acknowledged quit does not kill a
new manually launched session. Unacknowledged quit requests are delivered on reconnect.

Monitoring endpoints never expose tokens, certificates, or private configuration paths.
Management requests use bounded JSON POST bodies and never execute shell commands. A dashboard
bind failure is logged and leaves the coordinator serving compute clients. Client and standalone
modes do not start a WebUI. History is bounded to 256 improvements, 360 throughput samples,
128 events, 200 commands and 1024 known client records.

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
- Clue propagation rejects impossible shapes before scoring. Adjacent distance
  intervals bound both containing areas. Two-step paths bound their middle area
  and endpoint area sum; three-step paths bound their two middle areas' sum.
  One clues force adjacent singleton candidates; unique candidates fix singleton
  positions and propagate distance bounds to their neighbors. Pair-area bounds
  also prune assigned branches in strict feasibility covers. Local repairs can
  retain improvements while fixed exterior regions still need later repair.
  A state's internal path to its own
  capitol cannot cost less than a contained clue. These are necessary conditions,
  not a replacement for full validation.
- Initialization combines rectangles, bent triominoes and connected symmetry-orbit
  growth around printed zeroes and plausible unnumbered capitols. The rectangle
  size allowance reflects inferred minimum areas. Valid palette
  shapes are reused between restarts and in overlapping patch catalogs, with
  periodic growth samples for diversity. A bounded failure still falls back to
  singleton states; this fallback need not satisfy clues.
- Connected two-to-four-state merge enumeration retains its resumable cursors.
  Cursors are separated by objective, exact-ranking mode, persistent clue weights,
  and merge-size limit so changing ranking rules cannot suppress an improvement.
  Most repairs use up to 32 cells. Every twelfth proposal allows a larger patch of
  up to 128 cells and up to eight adjacent states. On boards larger than the
  ordinary patch allowance, alternate large turns reserve their full deadline
  for general patches. The other turns spend at most half their deadline on a
  bounded archive populated by anchored growth and generic even/capless shapes,
  preserving the remaining time for fallback. Each proposed archived shape is
  fixed while the intersected current states are rebuilt around it, up to the
  large-patch cell limit. This is a search
  allowance, not an exhaustive enumeration guarantee.
- Capitol growth retains unfinished walks across calls. Rejected intermediate
  shapes can keep growing: extra mirrors or insufficient current area need not
  persist in the final state. Generic catalogs combine connected orbit growth
  with small exhaustive masks, single orbits/complements, and a random lane for
  capless states. Bounded patch cursors retain the bounding box, transform, and
  mask position across augmentations. Their capacity matches the 64 active
  catalog slots; compact box indexes bound the added memory. Full catalogs reserve
  space for fresh candidates while preserving their previous cell coverage.
  Coverage does not guarantee a compatible tiling. Caches can evict progress; restarts do not
  constitute exhaustive enumeration.
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
12,000 catalog work units (split between growth and masks), 5,000 cover nodes and
48 completed covers. Catalog
sampling, geometry restrictions, cache hits and different worker objectives can
change the search trajectory. Per-worker seeds are reproducible with fixed work
budgets, but wall-clock cutoffs and concurrent archive arrivals affect full runs.

The package tests include the verified full-puzzle partition as an acceptance
fixture: 33 matching clues, eight capitols and answer 408951. It is not supplied
to production search. To measure shape discovery separately, without a solution
fixture, run the opt-in bounded benchmark:

```sh
python3 Scripts/benchmark_shape_discovery.py --run 5 16
```

This compiles a temporary CPU-only executable, then gives each of five seeds 16
batches of 128 capitol-growth steps and 256 orbit masks. It reports distinct
shapes, irregular shapes larger than the ordinary patch limit, unnumbered capitol
coverage, work counts and elapsed time. It does not start an annealing run or
connect to any coordinator. These are discovery diagnostics, not a solve-time
estimate or evidence of a fresh full-puzzle solve.

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
python3 Scripts/run_core_tests.py
```

This compiles and executes all six bounded core suites in one temporary CPU-only
executable. CI runs it alongside `swift test -c release`, which includes the
discovery, archive-coverage, merge-cache and calibration regression tests.
Every evaluated candidate, including cached and batched evaluations, can update
the saved best independently of the worker's objective or move acceptance.
The independent integer validator still decides whether a solution is valid.

To run individual energy suites instead:

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
