# JSP-Oct26-Midterm-Report

©2026 ThomasB

Author: ThomasB  
Date: 11 November 2026 (JST)

## Status of the original puzzle

The answer **408,951** was independently verified from a published candidate. Its 11×11 partition has 16 states and eight capitols. The Python checker, Swift evaluator and independent Swift validator agreed on the partition and all 121 distances, including the 33 printed clues. The experiments reviewed here did not independently discover a full solution. Global uniqueness remains open. [Verification and attribution](investigation/REPORT.md) · [Partition and exact distances](investigation/verification.json)

The archived structural-search continuation finished with **12 wrong clues and residual 0.18461937**. An earlier read-only scan of historical local checkpoints found a separate **10-wrong-clue** board with no structural issues. One GPU screening trial also reached 12 wrong clues, from a different run and configuration. These are separate observations with different starting states and budgets. [Checkpoint scan](investigation/checkpoint-summary.json) · [GPU trial](experiments/gpu_multicore/results/20261030-mini8/JSP-Oct26-GPU-Multicore-Report.md)

## Comparative solver experiments

| Study | Recorded outcome |
| --- | --- |
| [Discrete versus continuous scoring](experiments/discrete_vs_continuous/results/REPORT.md) | On identical partitions, discrete scoring was 13.3–23.4× faster cold and 168.1–303.7× faster on repeated cached passes. Neither controlled annealer solved any of its three-second trials. |
| [Production solve-time comparisons](experiments/discrete_vs_continuous/solve_results/REPORT.md) | On the 5×5 example, both scoring arms solved 5/5, with successful medians of 1.881 s discrete and 2.401 s continuous. Neither solved the first generated 8×8 in five trials each. The discrete extension on the second 8×8 solved 0/3. The sparse 5×5 and 7×7 comparisons, historical engine runs and user-stopped trajectories are indexed in the [experiment directory](experiments/discrete_vs_continuous/). |
| [Regional energy pilot](experiments/regional_energy/results/pilot-20261029-133155/REPORT.md) | All eight 300 s observations timed out. Some regional arms reduced residuals, with one matched seed per board. |
| [Production-preserving regional pilot](experiments/regional_production/results/20261029-151354/REPORT.md) | Discrete control and regional solved 5×5 in 8.637 s and 10.397 s. The other six trials timed out at 300 s. An earlier run was aborted after an instrumentation error. |
| [Global branch pruning](experiments/branch_pruning/results/20261029-160117/results.json) | Solved 4×4, 5×5 and 6×6 in 0.013 s, 0.435 s and 114.490 s. The 7×7 trial hit 600 s with a truncated catalog. |
| [Branch pruning versus discrete control](experiments/branch_vs_discrete/results/20261029-162908/results.json) | Discrete solved 7×7 in 116.734 s of search. The three branch runs and the two larger discrete runs reached 1,000 s. The branch catalogs were incomplete. One fixture per size and fixed order limit the comparison. |
| [Hybrid intensification and patch screening](experiments/hybrid_investigation/README.md) | Deeper BP and ordinary SA continuation failed to improve either selected checkpoint in 60 s. Fixed-exterior bounds ruled out any improvement for 135/356 small patches on 8×8 and immediate solutions for 172/239 on 9×9. These were offline patch counts. |

The [Regional-SA-BP matched campaign](experiments/solver_bench/analysis/final-20261030-120757/JSP-Oct26-Regional-SA-BP-Final-Report.md) is the strongest comparative dataset. The user stopped it after 184 of 360 trials finished, across 23 complete eight-arm blocks. There were **39 validated solves, 145 timeouts, 176 unfinished jobs and eight interrupted attempts**. Discrete regional SA with the new BP phases led at **9/23** and 828.7 s mean capped cost. Continuous regional with BP achieved **7/23** and 939.9 s. Across all policy settings, discrete solved 19/92 and continuous 20/92. Only 3/120 trials on sizes 7–9 solved. All 184 final partitions were structurally valid. The results support that experimental baseline within the completed blocks. They leave representation superiority and generalization to 11×11 unresolved.

## GPU results

In [GPU Quick](experiments/gpu_quick/results/20261030-quick/JSP-Oct26-GPU-Quick-Report.md), optimized CPU shape checks beat GPU shape checks. At N=11 and batch 1,024, GPU bounds were 1.19× faster than heap-based CPU Dijkstra on M2 and 0.91× on M4. Overlapping independent GPU bounds with CPU BP cut elapsed time about 7–8% on the measured replay. In [GPU Multicore](experiments/gpu_multicore/results/20261030-mini8/JSP-Oct26-GPU-Multicore-Report.md), the integrated full-GPU evaluator reduced iterations/s by 1.7–2.8% and evaluations/s by 3.0–6.2% across two matched seeds. All four 90 s trials remained unsolved. The replay and integrated search measure different workloads.

## Completion and escape on 11×11

| Campaign | Outcome |
| --- | --- |
| [Repair Completion](experiments/repair_completion/JSP-Oct26-Repair-Completion-Run.md) | The archived combined report recorded four completed 1,200 s Mac trials, one per experimental method, all unsolved. No Mini trial or production reference had a completed result in that report. Preflight trials were excluded. |
| [CPU8 Completion](experiments/cpu8_completion/JSP-Oct26-CPU8-Completion-Run.md) | With eight cooperating threads and amended budgets near 1,800 s, persistent BP finished at 14 wrong clues and residual 0.170782. Persistent BP plus route guidance finished at 17 and 0.283233. Both remained unsolved. |
| [CPU8 Continuation](experiments/cpu8_completion/JSP-Oct26-CPU8-Continuation-Run.md) | One warm-start segment stopped after 2,900.4 s at the same 14-clue incumbent. |
| [Search Escape screen](experiments/search_escape/results/20261030-screen/JSP-Oct26-Search-Escape-Report.md) | All 14 Swift screens retained 14 wrong clues. Diversity increased the number of distinct legal boards shared and protected searches received more nodes. A fixed-exterior CP-SAT probe improved residual to 0.16036970 at the same clue count. A separate small 4×4 check solved with both native BP and CP-SAT. |
| [Search Escape stall](experiments/search_escape/results/20261031-stall/JSP-Oct26-Search-Escape-Stall-Report.md) | After about 12.24 hours, the long campaign still held 13 wrong clues at residual 0.164962. Its small fixed-exterior patches could not satisfy a necessary 26-cell region bound from that incumbent. |
| [Structural Search](experiments/search_escape/results/20261031-structural/JSP-Oct26-Structural-Search-Report.md) | The live recovery check restored 29 repair jobs and four structural states. The first completed two-segment continuation reached 12 wrong clues at residual 0.214982. A second two-segment continuation held 12 and improved residual to 0.184619. Both exhausted their segment budgets. |

The completion and continuation outcomes above use archived campaign reports for run IDs `20261030-194036`, `20261030-211236`, `20261030-225021`, `20261030-235845`, `20261031-130850` and `20261031-193956`. The linked repository run records document setup and interim observations. The final host-local reports supply the later outcomes summarized here.

## What the investigation established

The cold catalog probe missed the verified 37-cell state in ten seeds at 12,000 masks each. Providing all 16 witness shapes let exact cover validate the puzzle in 17 nodes. The comparison isolates a candidate-generation bottleneck in the tested setup. Later connected growth probes recorded large irregular shapes and candidates with unprinted capitols. Those counters measure coverage, and the structural campaigns still ended with clue mismatches. [Witness investigation](investigation/REPORT.md) · [Shape-discovery benchmark](investigation/shape-discovery-benchmark.json)

Integrity probes showed that whole-board feasibility deductions could block useful partial repairs. The documented corrections separated strict feasibility from geometry-only repair, restored improving repairs, and recovered a validated fixture with a 36-cell capless region. These checks establish specific regression outcomes. The full-puzzle search remains bounded by the shapes and scopes it considers. [Integrity fixes](investigation/INTEGRITY_FIXES.md) · [Partial-repair fixes](investigation/PARTIAL_REPAIR_FIXES.md) · [Search audit](SEARCH_AUDIT.md)

For the next comparison, the evidence favors measuring candidate coverage and validated solve rate together. Discrete regional SA with BP provides the matched baseline. Large connected symmetry-orbit growth and necessary area bounds are candidates for improving 11×11 coverage. Compare them under matched seeds and budgets, with fresh starts and incumbent continuations reported separately. Capped time describes the observed budget, and residual is a secondary diagnostic after structural issues and wrong-clue count.

## Publication and reproduction

The experiment directories retain source snapshots, fixtures, logs and machine-readable results. Historical paths and run IDs in frozen records document their original execution. Public readers can start with the linked reports and the standalone Python witness checker, `python3 investigation/verify_candidate.py`. To regenerate active curve renderers, make Sharp available to Node.js through ordinary module resolution. The Python reporting scripts that import ReportLab require it in the active Python environment. Local credentials, SQLite sidecars, build products and host-local campaign queues are outside the publication inputs.
