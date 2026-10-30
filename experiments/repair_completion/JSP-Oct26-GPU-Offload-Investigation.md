# JSP-Oct26-GPU-Offload-Investigation

©2026 ThomasB

Author: ThomasB  
Date: 2026-10-30, Asia/Tokyo  
Status: initial investigation; subsequently followed by the
[short measured probe](../gpu_quick/results/20261030-quick/JSP-Oct26-GPU-Quick-Report.md).
That probe revises the shape-offload priority below. The main campaign remains
paused; no fresh GPU solver experiment has run.

## Recommendation

Investigate batched shape feasibility checks first, and batched branch-bound
evaluation second. Keep search decisions, backtracking and final acceptance on
the CPU. The existing Metal shortest-path backend is useful infrastructure, but
the recorded production profile gives little reason to expect a meaningful
end-to-end improvement from accelerating paths alone.

The goal remains time to an independently validated solution of the original
11×11 puzzle. Kernel throughput, node throughput and energy curves are diagnostic
measures; none alone establishes faster solving.

## Pause and evidence

Both campaign agents stopped at 20:10:39 JST, preserving observations and available
checkpoints. Local counts: four timeouts, four interrupted, 12 pending. Mini
counts: four interrupted, 11 pending. No experiment workers remain running; the
read-only dashboard and finalized partial exports remain available. There are
zero validated solves in this partial campaign. Stopping a process is not an
exact resumable suspension; saved snapshots need explicit recovery handling.

Campaign root:

`/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/JSP-Oct26-Repair-Completion-20261030-194036`

Production reference job: `mac-original-11-s2026103001-E`. Its last recorded repair
profile is at 599.269414 seconds, in
`trials/mac-original-11-s2026103001-E/production-logs/run-A11957EC-6337-4242-92B5-688938C38BF1.jsonl`,
line 545, run ID `A11957EC-6337-4242-92B5-688938C38BF1`.

| Recorded counter | Seconds |
| --- | ---: |
| Elapsed | 599.269 |
| Catalog operations | 433.995 |
| Geometry checks | 257.379 |
| Complete-candidate evaluation | 64.902 |
| Shortest-path evaluation | 7.893 |

These are **nested timers**, not disjoint categories. Geometry can occur inside
catalog generation, and distance evaluation inside candidate evaluation. Do not
sum the rows or interpret catalog time as pure GPU-ready work. Catalog operations
also include sampling, sorting, caching and other CPU work. The catalog-mask
counter was 207,297,830 and constraint rejects 68,581,466; a counter is not a count
of distinct shapes.

Shortest paths account for about 1.317% of elapsed time in this one partial
production trial. Eliminating that measured work entirely, with no added cost
and unchanged search decisions, would yield at most about 1.013× speedup.
This is an Amdahl estimate for this profile, not a forecast for every method.
Experimental methods A–D have different code paths and no separate path timer.
Their large cover-search counters include recursive search and nested shape
queries; they do not demonstrate that all cover work can be offloaded.

## Resource constraint: one CPU core and one GPU core

The user's clarified allocation is one CPU core plus one GPU core per hybrid
search. Similar CPU/GPU core counts on base chips do not mean equivalent compute:
a GPU core executes groups of lanes, while CPU cores are designed for different
control and latency patterns. Hardware counts therefore define a budget, not an
expected speed ratio.

Verified hardware: this Mac is an M4, 4 performance + 6 efficiency CPU cores,
10 GPU cores, 16 GiB RAM. The Mini is an M2, 4 performance + 4 efficiency CPU
cores, 10 GPU cores, 16 GiB RAM, macOS 15.5. Target their common Metal capability;
do not require features available only on the newer Mac.

Metal dispatches threadgroups and schedules them onto GPU cores. The reviewed
public APIs do not provide physical GPU-core affinity or reservation. A
conservative implementation proxy is **one active compute threadgroup at a
time**, processing many candidates within that group. It limits concurrency but
does not prove use of one specific physical GPU core, nor full utilization of
one core. Record this limitation explicitly. A GPU time quota of one tenth on a
10-core GPU is not equivalent to restricting physical concurrency to one core.
If strict physical-core enforcement is essential, this setup cannot certify it.

Likewise, one hot CPU thread is a work budget, not physical CPU-core affinity;
the OS may migrate it. CPU packing, submission, result checks and search all count
toward the one-core CPU budget. Record process CPU/wall ratio and background
interference. Do not run several independent GPU jobs concurrently and then
claim each used one core without verifying aggregate concurrency.

Apple describes the threadgroup-to-core mapping and the overhead of small,
synchronized workloads in [Scale compute workloads across Apple GPUs](https://developer.apple.com/videos/play/wwdc2022/10159/).

## What the current Metal code does

`JaneStreetPuzzle_Oct26/PathEvaluation.swift` already implements exact integer
shortest paths for up to 121 cells. Automatic mode considers batches of at least
eight boards on boards with at least 64 cells, with batches capped at 32. It
compares CPU versus GPU plus CPU certification, and can disable a slower or
incorrect GPU backend. CPU checks certify distances and reconstruct deterministic
parents. The current experiment explicitly compiles the production reference in
CPU-only mode; A–D call a separate shared CPU implementation.

The Metal backend allocates three shared buffers per call, dispatches one
threadgroup per board, then calls `waitUntilCompleted()`. A batch can therefore
occupy multiple GPU cores and does not satisfy the clarified budget by itself.
It also serializes CPU and GPU work. Its kernel uses one SIMD-group per
threadgroup; increasing group size requires redesigning its convergence and
barrier logic, not just changing dispatch dimensions.

Apple recommends balancing submission size against synchronization overhead in
[Command Buffers](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html).
Unified memory allows shared buffers, but ownership and synchronization still
matter; see [Choosing a resource storage mode for Apple GPUs](https://developer.apple.com/documentation/metal/choosing-a-resource-storage-mode-for-apple-gpus).

## Proposed division of work

| Work | Placement | Reason and limit |
| --- | --- | --- |
| Candidate mask generation | CPU initially | Existing growth and sampling are stateful; preserve candidate order and domain. |
| Batched shape feasibility | GPU candidate | Repeated independent masks allow regular parallel transforms and checks. Measure connectivity and cache effects rather than assuming speedup. |
| Partial-branch lower/upper distance bounds | GPU candidate, second stage | Independent frontier nodes can share a fixed exterior. Batching can delay useful pruning, so wall time must include that cost. |
| Complete-candidate distance evaluation | Existing GPU path, secondary | Small measured fraction in the production reference. |
| Branch choice, DFS stack, repair scheduling, SA acceptance | CPU | Irregular dependencies and frequent decisions make these poor first GPU targets. |
| Final solution verification and persistence | CPU | Preserve an independent exact acceptance path and durable records. |

For shape work, represent up to 121 cells as four 32-bit words, with precomputed
cell-transform maps. Derive symmetry and capitals using the full puzzle rules;
having one symmetry is not enough to establish a capital. Preserve capless and
even-area states. Cache hits stay on the CPU; send batches of actual cache misses.
Test cheaper CPU bitset and allocation improvements as a control, since GPU
acceleration should not merely compensate for avoidable CPU overhead.

Use reusable shared buffers and a bounded producer/consumer pipeline: the CPU
prepares the next batch while the GPU evaluates the current one. Permit only one
active GPU threadgroup under the proxy budget. Multiple SIMD-groups inside that
group can process independent masks, subject to runtime threadgroup limits and
uniform synchronization. Do not carry the current path kernel's one-SIMD-group
convergence assumption into this design. Avoid a dispatch and blocking wait for
every individual shape or tiny board.

GPU pruning must use conservative integer bounds. On any failed validation,
overflow, incomplete result or device error, fall back to CPU evaluation; never
prune on an uncertified optimistic result. Verify boundary cases, disconnected
shapes, every symmetry, no-capital shapes, and paths without reachable capitals.

## Small next experiment, before another long campaign

1. Capture representative shape-check and bound workloads from the saved search
   states. Add exclusive CPU timers to distinguish generation, cache lookup,
   geometry, constraints and bound evaluation. Keep this diagnostic replay
   separate from fresh puzzle solves and from timed evidence already collected.
2. Compare scalar CPU, batched/bitset CPU and batched Metal under the one-active-
   threadgroup proxy on each Mac separately. Sweep candidate batch sizes such as
   1, 8, 32, 128 and 512, subject to buffer and group limits. Include packing,
   submission, waiting, cache handling and CPU certification in elapsed time;
   record shader startup separately. Require exact agreement on captured inputs.
   A replay gain is necessary evidence, not proof of improved time to solution.
3. Only if the complete offload pipeline wins, compare matched fresh searches:
   one CPU thread versus one CPU thread plus restricted GPU work. Include a
   batched CPU arm using the same frontier policy, so a search-order benefit is
   not attributed to GPU hardware. Start with the best CPU search policy supported
   by completed evidence; the interrupted campaign has not established a winner.
   Keep startup and shape preparation in end-to-end timing, use matched boards
   and seeds, and report solve counts, time-to-valid-solve, censored costs,
   timeouts and energy curves against real elapsed time. Never treat an energy
   reduction or an interrupted run as a solve.

No speedup is measured or claimed here. A full GPU branch-and-bound rewrite is
not the recommended first experiment. The first decision is whether realistic
batched checks can overcome submission and validation costs within the restricted
GPU budget. The existing campaign remains paused pending further instruction.
