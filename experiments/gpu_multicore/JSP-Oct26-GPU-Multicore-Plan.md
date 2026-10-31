# JSP-Oct26-GPU-Multicore-Plan

©2026 ThomasB

Author: ThomasB  
Date: 2026-10-30, Asia/Tokyo

Run the actual production solver on the Mac mini, one process/configuration at a
time. Eight cooperative search tasks share the existing elite archive and retain
the production worker-objective and seed schedule. Compare CPU-only path
calculation with forced, certified Metal paths. Both modes use eight CPU search
tasks; the GPU mode has access to the full 10-core M2 GPU because Metal does not
expose an eight-physical-core reservation control.

Each GPU worker has its own existing `MetalPathBackend` instance and command
queue. This avoids serializing all eight workers behind the production singleton's
backend lock. A queue submits one threadgroup per board, with up to 32 boards per
call, so this does not retain the previous one-threadgroup restriction. Queue
count and available cores do not imply that all GPU cores are saturated. Actual
GPU call counts, batch sizes and device-wide activity samples are recorded.

The original 11×11 puzzle is the only timed board. Two paired seeds use CPU/GPU,
then GPU/CPU order. Each run has a 90-second common wall budget, with early stop
only for an independently validated solution. All workers drain and the solver
process exits before the next run begins. Short smoke checks precede the timed
runs and are excluded. Save every worker log, checkpoint, result, global best
observation and host-utilization sample in a new host-local directory outside
iCloud. Do not resume or alter the paused Repair-Completion campaign.

Primary outcome is independently validated time to solve. If no run solves,
report that explicitly and compare best quality/energy over actual elapsed time.
Iterations and evaluations per second are secondary diagnostics. Two matched
seeds are a screening sample, not a reliable solve-time distribution estimate.

This compares the practical existing CPU and GPU paths, not identical node order:
`PathEvaluator.batchSize` is 1 in CPU mode and up to 32 in forced GPU mode, affecting
candidate flushing. Archive exchanges and task scheduling are also nondeterministic.
Do not attribute a quality difference solely to GPU arithmetic speed. A later
hardware-isolation experiment would need a CPU control with identical batching.

Initialization, Metal pipeline setup, CPU packing, synchronization, certification,
archive exchange and observation overhead are included in solver elapsed time.
OS shader caches may already be warm after smoke tests. Eight CPU tasks are a
software concurrency budget; the OS chooses physical cores. Record process CPU
seconds divided by wall seconds, rather than asserting eight fully occupied cores.
The Mini has four performance and four efficiency cores. Device utilization
counters include graphics and any other applications, so save background samples.

No core solver files, software release authority, wire messages, installed
executables, credentials or live databases are changed. This is a new isolated
experiment harness built natively in scratch. Existing production version 2 is
recorded with source and binary hashes. Final candidates are checked independently
with the Python integer-rule checker in addition to production and shared Swift
validation. Errors and GPU fallback invalidate a run instead of being silently
reported as a GPU result.
