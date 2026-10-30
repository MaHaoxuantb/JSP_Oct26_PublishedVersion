# Regional randomization with preserved solver controls

This replaces the simplified `regional_energy` pilot as the useful experiment for the working solver. All builds and source patches live in isolated `/private/tmp` directories. Frozen patched source copies are retained with results. No production source, installed worker, credentials, or live state is modified.

## Controls

- **Discrete**: current production solver, including constrained initialization, symmetric shape catalogs, exact covers, merge/boundary/archive repair lanes, saved-best repairs, quality ranking, adaptive temperature, and restarts. Regional OFF executes its original proposal choices and consumes no additional search RNG draws.
- **Continuous**: actual historical solver from Git revision `e23adc5`, preserving its initialization, boundary/merge/split/patch/relationship proposals, acceptance rule, cooling, and restart machinery. Both arms use energy factors **2:1:2** for clue fit, symmetry, and discreteness. Its existing energy-weighted focus remains in both arms.
- This is an ON/OFF experiment within each representation. Cross-representation results compare different original algorithms, not solely integer versus continuous arithmetic.
- Log-only changes add best snapshots to milestone events and request progress approximately once per second. Wall time includes initialization, field calculation, scoring, repairs, and logging. Each trial uses one worker, and timed trials run sequentially to avoid mutual CPU contention.

## Regional changes

Noise is the mean of `n` independent uniforms in [-1,1], where `n=round(16-15*h)` and `h` is the selected cell's min-max normalized energy. Hot cells use smaller `n` and have broader noise. Distribution, bounds, normalization, and spatial decay are self-tested in both compiled engines.

Discrete: the exact validator's normalized clue residuals are diffused over Manhattan distance with `exp(-distance/2)`. The new patch focus uses 20% uniform exploration, otherwise weight `0.05+h`, among the existing eligible cells. Absolute noise maps to 1..4 regions for ordinary patches and 1..8 for large patches, respecting existing cell limits. All other repair lanes remain unchanged. Production's old Board.Energy array is not used because discrete scoring leaves it unpopulated.

Continuous: retains its existing energy-weighted focus. Absolute noise controls the existing patch radius (1..2); relationship perturbations reflect `old+noise` into [0,1]. Other move types and frequencies are unchanged. The stronger discreteness factor affects both control and regional arms equally.

These changes test energy-dependent proposal breadth while retaining the original search architectures. They do not replace repair moves with a generic annealer. Discrete changes operate only when the patch lane is reached; initialization or other repair lanes may solve a board before the new policy can act.

## Puzzles and timing

Frozen fixtures reuse the previous sparse 5x5 (7/25 clues) and generated 7x7 (13/49), matching the real puzzle's 33/121 density. The independent rules validator and puzzle maker are in `../discrete_vs_continuous/rules.py` and `Experiment.swift`; witness partitions are checked by the parent and omitted from solver input.

A production-control gate first has the full **300-second** budget, but must reproduce an exact 5x5 solution under 30 seconds before any regional comparisons proceed. Thirty seconds is a reproduction check, not a solver cutoff. Failed gates stop the experiment for investigation. The gate doubles as the first control observation. All subsequent trials stop at a verified solution or 300 seconds. Final boards are independently validated in Python.

Run one-seed pilot:

```sh
python3 experiments/regional_production/run.py --seconds 300 --seeds 20261029
```

Default seeds are 20261029, 20261030, 20261031 for a longer repeated experiment. One seed is exploratory and does not establish a statistically reliable speed advantage. Source hashes are checked after completion; no software release or deployment is performed.

Reports and curves are generated with `summarize.py` (ReportLab) and `render.cjs` (Sharp). `status.py` reads the active experiment's latest milestone without changing the search.
