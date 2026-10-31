# JSP-Oct26-Search-Escape-Continuation

©2026 ThomasB

Author: ThomasB

Phase: complete. Escape portfolio, original 11×11 puzzle, eight cooperating CPU threads; optional local one-core CP-SAT sidecar; no GPU. Fan controls unchanged.

Seed source: `/private/tmp/JSP-Oct26-Search-Escape/seed.json`. Independently checked starting quality: {'issues': 0, 'residual': 0.17078226998999335, 'wrong': 14}.

Segments last up to 6 seconds and run sequentially until a validated solve or STOP. Segments retain incumbent states, carry stagnation ages, restore compatible BP stacks, and use new SA random streams. Roles: two incumbent repairs, four diverse islands, one broad/recombination worker and one exact-feasibility worker. This is checkpoint continuation, not exact process resumption. The prior evaluation remains unchanged.

| Segment | Status | Seconds | Wrong clues | Residual | CPU equivalents |
| --- | --- | ---: | ---: | ---: | ---: |
| original11-P-escape-0001 | timeout | 6.2 | 13 | 0.17027197863745597 | 7.47 |
| original11-P-escape-0002 | timeout | 6.1 | 13 | 0.17027197863745597 | 7.86 |

Only independent rule validation establishes a solution. Energy is not a progress percentage or a remaining-time estimate. Cancellation retains checkpoints and outputs.

Stop by creating `/private/tmp/JSP-Oct26-Search-Escape/release-smoke/STOP`.
