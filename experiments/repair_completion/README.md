# JSP-Oct26-Repair-Completion

©2026 ThomasB

A bounded, five-method completion study. The [execution plan](JSP-Oct26-Repair-Completion-Plan.md)
records the workload, hypotheses and two-hour budget. This module reuses the
shared `PuzzleRules`, `ShapeDomain`, `SolverCore` and independent Python validator.
It adds a policy hook to the common engine rather than forking SA implementations.

- A: discrete regional SA + the existing short-lived BP policy, with diagnostics.
- B: persistent repair jobs, otherwise A.
- C: route-selected BP patches, otherwise A.
- D: both factors.
- E: isolated current production CPU reference, one search task and no shared archive.

The route factor changes **BP intensification**; ordinary SA proposal repairs
remain identical. Route choices use current incorrect-clue residuals, 20% explicit
neighbor exploration, complete regions and the existing scope schedule. The
persistence factor retains at most four fixed-snapshot repair jobs and removes
forced two-phase expiry. These are policies, not completeness guarantees.

Each repair slice is logged to `repairs.jsonl`, with a source/patch identity,
new nodes, generation, bounds, exhaustion/expiry, local/global gain and delivery
to SA. Separate resumable BP-stack snapshots are written at most every ten
seconds while BP runs. They are diagnostic/recovery evidence; the queue does not
silently restart a crashed timed trial or count a restarted trial as continuous
end-to-end timing. Search results and best-board checkpoints remain separate.

Build in scratch:

```sh
python3 experiments/repair_completion/build.py --scratch /private/tmp/jsp-repair-build
```

`prepare.py` freezes code, binaries, inputs, fixed ordering, version and hardware
metadata into a **new** host-local directory. It refuses to reuse an existing
campaign. Admission checks use saved fixture witnesses; only puzzle clues enter
worker input. The shape seed store is copied only from the frozen read-only
source; it is never treated as a complete dimension-11 catalog. Exact lazy
shape enumeration remains available and its cost is timed.

Each host runs its own durable SQLite queue through `runner.py agent --directory
ROOT`. A lock prevents duplicate agents. The coordinator consumes JSON exports
from peers, never a copied live database. `runner.py serve --directory ROOT`
provides a read-only loopback dashboard; `coordinate` creates combined Markdown,
CSV, JSON, offline HTML charts and a compact evidence archive automatically.
All raw logs remain in the owning host's trial directories. Explicit `STOP`
files stop campaign work; interrupted attempts are not reported as full timeouts.

The production adapter compiles unchanged search sources in CPU-only mode and
adds observation/output conversion. It calls the same production search used by
a single worker, with a finite wall deadline and effectively disabled iteration
and restart caps. It does not deploy or replace any installed production binary.
Source/adapter hashes and the authority software version distinguish this build.

Primary elapsed time is from process spawn to result-file publication, using the
host's filesystem timestamp. Worker monotonic elapsed and process CPU time are
also retained. Curves use worker monotonic seconds, including initialization and
cache loading; raw sample timestamps allow checking process-start offsets.
Validation rejects false solves, score disagreement, inappropriate early unsolved
stops, gross overruns and CPU/wall ratios above 1.15. Scheduling exceptions and
infrastructure failures remain visible and are excluded from completed pairs.

Reports split capped costs and paired differences by host and separate the
original puzzle from generated fixtures. The production reference does not
enter the 2×2 factor estimates. No automatic selection or deployment follows a
small-sample result. The previous campaign remains a separate dataset.

## Launched campaign

See the [current run record](JSP-Oct26-Repair-Completion-Run.md) for the actual
local fallback workload, dashboard, deadlines and permanent data directory.

The campaign is currently paused on both hosts. The
[GPU offload investigation](JSP-Oct26-GPU-Offload-Investigation.md) records the
observed bottlenecks, the one-CPU-core/one-GPU-core constraint and a proposed
bounded follow-up. It contains no GPU benchmark results.
The subsequent [quick GPU report](../gpu_quick/results/20261030-quick/JSP-Oct26-GPU-Quick-Report.md)
contains measured component/overlap results from both Macs, separate from this
campaign's solver data.
