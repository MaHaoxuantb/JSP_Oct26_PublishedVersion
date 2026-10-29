# Time to a verified solution

30-second limit; one CPU worker; optimized Swift. Completed counts are shown per puzzle and candidate.

| Puzzle | Scorer in production search | Solved | Successful times (s) | Median successful time (s) |
|---|---|---:|---|---:|
| generated7_7101 | discrete | 0/1 | — | — |
| generated7_7101 | continuous_scoring | 0/0 | — | — |

Timeouts are censored: an unsolved trial establishes only that this run did not solve within its limit. Successful-only medians must be considered with solve rate. The full observation includes stop reason and process wall time.

## What is compared

Both candidates run the existing `Main.Run` production search, with identical configuration, paired seeds, one CPU worker, initialization, shape discovery, moves, repair logic, cache capacity, exact mismatch ranking and exact final validation. The discrete candidate uses its normal `SearchContext` scoring. The continuous-scoring candidate replaces the scoring call with retained `Energy.evaluate` using the same factors, in throwaway copies of the core source. It retains the computed exact paths and validation metadata for the common search engine.

This is a continuous-scoring variant of the production partition search, **not a reconstruction of a historical continuous-edge solver**. Both generate hard partitions, so fractional edge confidence is not searched here. On symmetric valid states the continuous fields collapse to exact capitols. This comparison answers which scoring route gets this same search engine to a verified solution sooner; it cannot establish the speed of an absent historical continuous-edge algorithm.

The continuous variant includes its real scoring costs plus the shared exact validation/path work. Deadlines may change how far repair jobs get and therefore search trajectories. It is a practical end-to-end comparison rather than a numerical arithmetic microbenchmark.

The 5×5 published example must validate to 8,045 before and after successful solves. The two 8×8 fixtures are the same seeded known-satisfiable puzzles as the first experiment; uniqueness is not established. Every reported success passes independent exact validation.

## Isolation

All source modifications and compilation occur in a unique `/private/tmp` directory. Production source, release version, installed workers, credentials, run state and live databases are unchanged. No deployment occurs. The exact temporary-source patch is retained in `metadata.json`, together with original source hashes. Trial logs and observations are saved separately in this directory.
