# Swift branch-pruning experiment

This is a separate, deterministic solver, not an alternate proposal policy for the production annealer. It never calls `Main.Run`, changes production sources, accesses coordinator state, or installs an executable. `Rules.swift` reuses the integer symmetry rules and deterministic puzzle maker from `discrete_vs_continuous/Experiment.swift`, and the small `Grid`/`SearchRandom` helpers from `SearchSupport.swift`.

The solver enumerates connected symmetric regions as unions of symmetry orbits inside their bounding rectangles. Rectangles are included first. The other candidates cover 180-degree rotation, horizontal/vertical reflection, and (for square bounding boxes) 90-degree rotation and the two diagonal reflections. The inverse 270-degree rotation has the same invariant subsets as 90 degrees. Every candidate is checked against **all** symmetries to determine its capitol.

The whole-board search places nonoverlapping regions, selecting the uncovered cell with the fewest compatible candidates (MRV). Candidate order is larger regions first, then ascending bitmask. There is no random search, annealing, or use of a known solution. Pruning rules:

* A revealed zero must be the selected region's capitol; a positive clue cannot be a capitol.
* Adjacent revealed distances differ by at most the edge cost, which is at most either endpoint's region size.
* A path within a proposed region to its own capitol bounds a clue from above.
* In a partial partition, assigned cells have fixed sizes. Unassigned cells have size bounds `[1, number of unassigned cells]`. All unassigned cells without a positive clue are possible capitols. Dijkstra with these smaller edge weights and extra sources gives a lower distance bound.
* Dijkstra from **assigned capitols only**, using larger edge weights on unassigned cells, gives an upper distance bound. Every completion still contains those capitols, and its edge costs cannot exceed these weights. A clue outside the lower/upper interval rejects the branch.
* If an uncovered cell has no compatible region, reject the branch.

Every 2,048 visited nodes, a feasible partial partition may also be completed with singleton regions. This cheap terminal completion supplies a valid partition for energy diagnostics and may find a solution; it is counted separately from ordinary full-cover leaves. Initial diagnostics use the all-singleton partition. Exact energy has the same formula as the existing report. These diagnostic observations do not select branches, and are not partial-board energies.

Each trial receives **600 seconds total**, including catalog generation, indexing/sorting, diagnostics and search. Compilation and fixture generation are excluded. Catalog generation receives at most 45 seconds, shared across rectangle/symmetry jobs with individual time quotas. Region sizes are allowed up to the whole board. If any job is truncated, the catalog is marked incomplete; exhausting it does not prove the puzzle unsatisfiable. Fixed search order is deterministic; time-limited catalog construction remains timing-sensitive.

`run.py` builds an optimized Swift executable inside a unique `/private/tmp` scratch directory and runs one trial at a time. The executable receives only `fixtures.json`, which contains clues and dimensions, with no witness solutions. The maker's witnesses are saved separately and checked independently. The old sparse 5×5 and 7×7 fixtures are copied exactly. New 4×4 and 6×6 fixtures use seeds 4101 and 6101 and uniformly sample 4 and 10 clues respectively, rounding the real puzzle's 33/121 density. Generation guarantees a solution but does not establish uniqueness or matched difficulty across sizes.

Before timing, the executable exhaustively compares orbit catalogs with all cell subsets on 2×2 and 3×3. Six additional 3×3 tests compare **all** satisfying partitions with filtering/pruning disabled versus enabled, checking that no solutions disappear. Each reported final partition is independently validated in Python for connectivity, symmetry, capitols and integer shortest-path clue values. Production source hashes are compared before and after the entire batch.

Run:

```sh
python3 experiments/branch_pruning/run.py
# After the new batch finishes, with bundled Python including reportlab:
python3 experiments/branch_pruning/extend_report.py
```

The extension appends a marked section to the existing production-regional report and leaves its old measurements and figures intact. Do not regenerate that old report with `regional_production/summarize.py` afterward: that older script overwrites the document. Frozen trial sources and raw results live in `results/<timestamp>/`.
