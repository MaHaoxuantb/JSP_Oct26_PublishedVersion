# Production-preserving regional experiment

Each trial: one worker, sequential execution, 300-second cutoff. Seeds: [20261029].

The former generic mutation harness is excluded. The production discrete control reproduced fast 5x5 solving before regional trials began. Continuous uses the historical engine with weights 2:1:2 in both arms.

| Board | Solver | Policy | Exact solve time | Incorrect clues | Structural issues | Retained exact energy | Lowest observed exact energy |
|---|---|---|---:|---:|---:|---:|---:|
| 5x5 | discrete | Control | 8.637 s | 0 | 0 | 0.000000 | 0.000000 |
| 5x5 | discrete | Regional | 10.397 s | 0 | 0 | 0.000000 | 0.000000 |
| 5x5 | continuous | Control | Unsolved at 300.000 s | 3 | 1 | 0.164286 | 0.047552 |
| 5x5 | continuous | Regional | Unsolved at 300.000 s | 4 | 0 | 0.061228 | 0.061228 |
| 7x7 | discrete | Control | Unsolved at 300.002 s | 1 | 0 | 0.003506 | 0.003506 |
| 7x7 | discrete | Regional | Unsolved at 300.002 s | 1 | 0 | 0.003787 | 0.003787 |
| 7x7 | continuous | Control | Unsolved at 300.001 s | 3 | 1 | 0.076159 | 0.035178 |
| 7x7 | continuous | Regional | Unsolved at 300.001 s | 4 | 0 | 0.037619 | 0.037619 |

![Lowest observed exact energy](observed-energy.png)

Lowest observed energy is the running minimum over logged retained candidates, not every evaluated proposal. It is an observational diagnostic and does not guide either search.

![Common exact energy](common-energy.png)

![Native energy](native-energy.png)

Exact energy uses the same binary partition geometry and integer shortest-path distances for all candidates: `(2 * mean normalized clue error + invalid-cell fraction) / 3.25`. Native energy retains each solver's own objective; the continuous one uses stronger discreteness weights. Curves follow the solver's retained candidate, which need not minimize this common scalar score. No line is extended beyond its real stopping time.

All retained snapshots are independently checked against integer rules. Discrete exact scores are cross-checked against logged scores. Initial states are compared within each pair; see checks.json. Time-bounded production catalogs make runs timing-sensitive despite fixed seeds.

**Limits:** a one-seed pilot cannot establish a reliable speed advantage. Discrete and continuous have different initialization, move sets, ranking and temperature rules, so their difference is not caused by number representation alone. Regional changes are limited to proposal focus/breadth as documented in README.md. A cutoff is an unsolved observation, not an estimated solve time.

Search sources and their patch provenance are frozen in sources/. Original source hashes, fixtures, raw logs, independent validation, and sampled curves are preserved here. No core release or deployment occurred.
