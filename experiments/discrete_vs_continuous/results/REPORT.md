# Initial throughput experiment

For the requested time-to-solution comparison, see [SOLVE_TIME_REPORT.md](../SOLVE_TIME_REPORT.md). The measurements below do not establish solving speed.

Run on 2026-10-29; arm64; optimized Swift, CPU only, one worker.
Five paired seeds per puzzle; 3 seconds per search trial. No deployment or core changes.

## Identical-partition scoring

Median microseconds per scoring call across five repeats. Cold = fresh context for a pool pass; warm = five revisits of that pool. Board construction excluded. Random pools can themselves contain duplicate partitions, so cold does not guarantee every call is a cache miss.

| Puzzle | Discrete cold µs | Continuous cold µs | Cold speedup | Discrete warm µs | Continuous warm µs | Warm speedup |
|---|---:|---:|---:|---:|---:|---:|
| example5 | 14.71 | 195.28 | 13.3× | 1.14 | 191.37 | 168.1× |
| generated8_8101 | 32.73 | 764.51 | 23.4× | 2.47 | 749.61 | 303.7× |
| generated8_8102 | 33.55 | 671.10 | 20.0× | 2.52 | 653.17 | 258.8× |

## Bounded search

Controlled candidates share the same simple edge-resampling annealer. The production reference uses its existing richer repair search. “Successful time” excludes unsolved trials; it is not an estimate of unconditional solve time. Throughput is wall-clock calls/s including independent validation.

| Puzzle | Candidate | Solved | Median successful time (s) | Median calls/s | Median best wrong clues | Median best structural issues |
|---|---|---:|---:|---:|---:|---:|
| example5 | controlled_discrete | 0/5 | — | 11,558 | 5 | 0 |
| example5 | controlled_continuous | 0/5 | — | 3,567 | 5 | 0 |
| example5 | production_discrete | 3/5 | 0.832 | different counter | 0 | 0 |
| generated8_8101 | controlled_discrete | 0/5 | — | 7,839 | 23 | 0 |
| generated8_8101 | controlled_continuous | 0/5 | — | 1,164 | 26 | 0 |
| generated8_8101 | production_discrete | 0/5 | — | different counter | 15 | 0 |
| generated8_8102 | controlled_discrete | 0/5 | — | 8,038 | 18 | 0 |
| generated8_8102 | controlled_continuous | 0/5 | — | 1,293 | 21 | 0 |
| generated8_8102 | production_discrete | 0/5 | — | different counter | 10 | 0 |

## Fixtures and validation

The published 5×5 witness produced answer **8,045**. Both scoring paths gave zero on each known solution. Generated full distance fields agreed with the independent production validator. The 1×3 and X-pentomino no-capitol cases and singleton capitol case passed.

### example5

Maker seed: published example. Clues: 10. Distinct witness states: 4.

Clues (`.` = blank):

```
12  .  .  . 17
 8  .  6  3  .
 .  .  .  .  .
 .  7  6  . 10
25  .  .  .  0
```

Known satisfying partition (equal letters = same state):

```
A B B C C
A B B D C
A A D D C
C A A A C
C C C C C
```

### generated8_8101

Maker seed: 8101. Clues: 35. Distinct witness states: 13.

Clues (`.` = blank):

```
 0  .  4  3  .  9  .  .
 .  3  .  0  3  6  9 12
 .  5  .  3  .  9 12  .
 .  8 14  . 16 19  .  .
 9  1  . 15 25 29 36 48
 .  .  1  8 15  .  . 47
 .  1  5 12 19  .  .  .
 .  .  . 16  .  . 28  .
```

Known satisfying partition (equal letters = same state):

```
A B C C C C C C
D B E E F F F G
D B H E I I G G
H H H I I I G G
H H H I I I G G
H J K K I I G G
L L K K K M G G
L L K K M M M G
```

### generated8_8102

Maker seed: 8102. Clues: 28. Distinct witness states: 12.

Clues (`.` = blank):

```
 0  .  5  9  5  . 12  .
 1  .  9  .  .  5  7  .
 .  .  .  .  .  7  . 27
 . 17  9  .  0  . 11  .
 . 21 13  .  1  .  . 23
35  . 21  .  . 13  .  .
 .  . 27  . 15 19 23 27
45  .  .  .  .  .  .  .
```

Known satisfying partition (equal letters = same state):

```
A B B C C C C C
D B B D E E F F
D D D D D F F F
D G G D H F F F
G G G I I I F F
G G G J J I I I
K K K J J J L L
K K K J J J L L
```

## Interpretation

Discrete scoring wins throughput on these fixtures. This compares different algorithms and cache strategies, not just integer versus floating-point instructions. Exact discrete scoring uses one multi-source shortest-path computation; continuous scoring computes per-clue distances and integrates tentative capitol distributions. Whole-partition reuse further favors discrete scoring.

The controlled searches did not establish a time-to-solution winner where neither solved. The production reference tests the actual discrete solver, but its advantage cannot be attributed solely to number representation because its move generation and initialization differ.

These are short exploratory CPU runs on the supplied example and two known-satisfiable generated puzzles. Uniqueness was not checked. They do not establish performance on all 8×8 puzzles or the original 11×11. Timed searches are stochastic and may vary slightly because deadlines affect work completed, even with fixed RNG seeds.

Reproduction and full methodology: [README](../README.md). Raw observations: [results.json](results.json). Build/environment: [metadata.json](metadata.json).
