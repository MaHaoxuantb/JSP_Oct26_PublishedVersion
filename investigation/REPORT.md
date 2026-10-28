# Puzzle and search-pathway investigation — 2026-10-28

The candidate described below is valid and gives **408,951**. The present Swift
evaluator, independent Swift validator, and a separate Python checker agree.
The strongest remaining search concern is generating the necessary shapes,
particularly the irregular 37-cell state with an unnumbered capitol.

This investigation adds files only in `investigation/`. It does not change search
code, launch an annealing run, restart workers, connect to a coordinator, or submit
an answer. Existing working-tree changes were preserved.

## Provenance and what has been established

- The supplied image was compared with `RunConfig.fullPuzzle`: all 33 clues agree.
- The [official puzzle](https://www.janestreet.com/puzzles/current-puzzle/) agrees
  with the supplied rules.
- A [search-indexed published solution](https://ashrithanumala.github.io/w/its-a-metric-too.html)
  supplied the candidate size matrix. Direct opening of that page returned 404
  during this investigation; its indexed text supplied the matrix. This is an
  independently verified published candidate, not an independently discovered solution.
- The Python checker reconstructs explicit state IDs as connected components of
  equal sizes, checks each component's area, checks all seven nonidentity square-grid
  isometries, identifies capitols, and runs multi-source integer Dijkstra.
- The Swift probe checks the candidate against the actual full-puzzle clues,
  `SearchContext.evaluate`, `ExactValidator`, and `SearchContext.permits` for every
  state. It also compares all **121** distances with the Python results.
- All checks pass. **Uniqueness is not established.** An exact cover using only
  these supplied shapes does not exclude solutions using other shapes.

## Correct mathematical model

Let `s(u)` be the area of the state containing cell `u`, and `C` the set of all
capitols. The undirected cost of any orthogonal edge is

```text
w(u,v) = min(s(u), s(v))
d(u)   = minimum over c in C of shortest_path_cost(u,c)
answer = sum over rows r of (sum over columns c of s(r,c))²
```

The minimum formula also applies within a state, where its two arguments agree.
Distances are to **any** capitol. Paths may leave their starting state, reenter it,
or pass through other states. Blank cells can be additional capitols.

A state needs at least one nonidentity symmetry. For it to have a capitol,
**each** such symmetry must fix exactly one cell and the fixed cell must be the
same for all those symmetries. Merely intersecting the fixed sets is insufficient:
a 1×3 bar has a central cell common to its symmetries but still has no capitol,
because one reflection fixes three cells. A capitol state has odd area, but odd
area alone does not make a capitol.

## Useful deductions before choosing shapes

Coordinates below are one-based.

1. `d(u)=0` if and only if `u` is a capitol, since every edge has positive cost.
2. `d(u)=1` requires an adjacent singleton capitol. The path must consist of one
   edge of cost 1; `u` cannot itself be a singleton because it would have distance 0.
3. A singleton forces every orthogonal neighbor to have distance at most 1.
   Consequently **r6c11 is forced to be a singleton**: r5c11=1 needs a neighboring
   singleton, but r4c11 touches r3c11=14, and r5c10 touches r5c9=4. Those two
   possibilities would force an adjacent clue to be at most 1.
4. The distance function is Lipschitz on every edge:
   `|d(u)-d(v)| ≤ min(s(u),s(v))`.
   Thus the adjacent 77 and 61 force both containing states to have area at least 16.
   The forced singleton implies `d(r7c11)≤1`; its neighbor r8c11=13 therefore
   forces both those cells' states to have area at least 12.
5. For each two-edge path `a-x-b`, put `Δ=|d(a)-d(b)|`. Then
   `s(x)≥ceil(Δ/2)` and `s(a)+s(b)≥Δ`, because each edge cost is bounded by the
   middle area's size, and the two edge costs are also bounded by the endpoint
   areas separately. The 51 and 7 force **both r3c4 and r4c3 to have area ≥22**.
   Similarly, the 45 and 10 at r9c9/r8c8 force both intervening cells to have area ≥18.
6. For `a-x-y-b`, `s(x)+s(y)≥ceil(2Δ/3)`. Indeed the path cost is at most
   `s(x)+min(s(x),s(y))+s(y)≤3(s(x)+s(y))/2`.
   Along the bottom row, 77 and 0 imply `s(r11c7)+s(r11c8)≥52`.
7. Necessary bounds should constrain candidate shapes together with the 121-cell
   total area and symmetry orbits. They do not justify assuming a clue belongs to
   a state of that size, or that only the printed zeroes are capitols.

## What the verified board teaches

There are 16 states, with areas

```text
4, 7, 10, 5, 7, 37, 1, 12, 11, 5, 2, 1, 2, 10, 4, 3
```

The eight capitols are r2c3, r2c10, r3c7, r6c8, r6c11, r7c2, r7c6, r11c6.
Repeated sizes do not mean the states are the same. Explicit state IDs are saved
in `verification.json`.

The largest state is invariant under a 180° turn about **r7c6**, its capitol.
Its four orthogonal neighbors are also in that 37-cell state, so every first step
from that capitol costs 37. In particular r6c6, despite touching its own capitol,
gets distance 10 by going east twice to r6c8, using costs 5+5.

Some true minimum routes, independently computed from the complete graph:

| Clue | Minimum-cost route | Edge costs |
|---|---|---|
| r3c3=7 | r3c3 → r2c3 | 7 |
| r4c4=51 | r4c4 → r3c4 → r2c4 → r2c3 | 37+7+7 |
| r6c6=10 | r6c6 → r6c7 → r6c8 | 5+5 |
| r11c9=77 | r11c9 → r11c8 → r11c7 → r11c6 | 37+37+3 |
| r11c10=61 | r11c10 → r11c11 → r10c11 → r9c11 → r8c11 → r7c11 → r6c11 | 12+12+12+12+12+1 |
| r9c9=45 | r9c9 → r9c10 → r8c10 → r7c10 → r7c9 → r6c9 → r6c8 | 12+12+12+5+2+2 |

Listing a route only demonstrates an upper bound. Dijkstra verifies that no
cheaper route exists for each of these clues and for the remaining 27 clues.

The computed row sums are

```text
58, 86, 202, 215, 211, 221, 180, 234, 212, 208, 206
```

Their squared sum is **408,951**. `solution.png` shows the complete partition.
`verification.json` includes every state's symmetry and capitol, all distances,
and a minimum route for every printed clue.

## Investigation of the current search

### 1. Evaluation accepts the valid board

All sixteen shapes pass the current geometry and clue filters. The main scoring
path and independent validator both accept the board. All Python and Swift
distances agree. This closes the original audit's full-puzzle transcription and
known-solution validation gaps; it does not prove every other code path correct.

### 2. Initial shape generation misses the large state's capitol

`RegionRepairs.swift:152` initializes from rectangles and bent triominoes. Its
2,800 permitted shapes omit nine of the sixteen verified solution states.
`capitolCatalog`, at line 201, adds connected symmetry-orbit growth **only around
printed zeroes**, r6c8 and r11c6. It cannot directly grow the 37-state about r7c6
or the other unnumbered capitols. Those must arise through other move types.

### 3. Ordinary patches are smaller than the crucial state

Defaults in `RunConfig.swift` limit ordinary patches to 32 cells. They cannot
rebuild an entire 37-cell state through their exact cover. Every twelfth proposal
allows a larger patch, up to 128 cells and up to eight existing states. Merges,
orbit transfers, and splits provide additional routes to larger shapes, so this
is **not** a proof that the current search can never find the solution.

Nevertheless, the large-patch cell allowance is not equivalent to meaningful
coverage of large shapes. Patch selection starts from whole current states and
adds adjacent states; a suitably large window still needs the right candidates.

### 4. Uniform orbit masks have a severe combinatorial cost

`regionCatalog`, at line 258, scans bounding boxes, samples symmetry-orbit unions,
and filters them afterward for connectivity and clue restrictions. Per transform
it uses 256 masks: half single orbits/complements, half random subsets.

The verified 37-state's tight 9×9 bounding box has 41 orbits under its half-turn:
40 pairs plus the center. Its particular shape requires a particular choice of
19 orbits. Under an ideal fair independent-bit model, a random mask equals that
specific shape with probability `2^-41`; 128 random trials have probability at
most `128/2^41 ≈ 5.82×10^-11`. The single-orbit/complement trials cannot form it.
This calculation applies to that exact box with all its cells allowed, not to
all search moves or a solve-time estimate. A tighter partially fixed patch can
have far fewer remaining orbit choices.

Measured probe: ten **fresh** contexts, seeds 0–9, each requested a full-board
catalog with default mask budgets and no wall-clock deadline. Each tested 12,000
masks, produced 171–189 permitted shapes, and omitted the verified 37-state.
These probes did not prepopulate `initialShapes` or represent warmed live workers.
They isolate the cold generic sampler; they do not establish a fleet failure rate.

By contrast, supplying the sixteen verified shapes to the existing exact cover
produces the valid board in **17 nodes and one complete cover**. This is evidence
that candidate generation deserves priority over accelerating cover evaluation.

### 5. Existing distance deductions leave substantial information unused

`ClueConstraints` at `ExactSearch.swift:108` initializes minimum areas using only
adjacent pairs of printed clues. It does not initially propagate the forced
singleton or the two-/three-edge inequalities derived above. It does check local
zero/positive capitol restrictions and internal paths once a shape is supplied.

### 6. Saved local checkpoints are consistent with a small-state plateau

A read-only scan found 967 checkpoint JSON files, including 937 for the full
puzzle. The best recorded full-puzzle checkpoints had zero structural issues and
10 wrong clues; those listed in `checkpoint-summary.json` had largest states of
14–16 cells. These are saved historical local files, not a live coordinator
snapshot and not evidence about the currently deployed fleet's best board.

The four issues documented as corrected in `SEARCH_AUDIT.md` were already local
changes before this investigation. They should not be confused with these
remaining limitations in shape discovery.

## Most promising next solving pathway

1. **Retain exact integer validation and the verified board as an acceptance
   fixture.** Keep correctness checks separate from discovery benchmarks; feeding
   the known solution to a search does not measure discovery capability.
2. **Propagate forced singleton locations and short-path area bounds before
   sampling.** Track proven deductions separately from branch assumptions.
3. **Branch explicitly on possible unnumbered capitols and symmetry types.** Grow
   connected symmetry orbits with required/excluded cells, area bounds, and the
   global area budget, rather than selecting every orbit independently and
   rejecting most masks. A conjecture such as a half-turn state about r7c6 can
   be a useful branch, but must not be silently treated as a deduction.
4. **Combine those shapes with the existing exact-cover machinery.** Prioritize
   cells with large minimum areas and cells having few candidate shapes. Preserve
   candidate-generation progress across budgets so the same early bounding boxes
   do not dominate repeated attempts.
5. **Use local repairs as a complementary portfolio.** They can refine boundaries
   and improve partial boards. More workers or faster path evaluation alone do
   not resolve the missing-shape problem demonstrated by this probe.

An alternative is a joint finite-domain constraint model. With positive edge
weights, exact nearest-capitol distances can be enforced using: `d=0` exactly at
capitols; `d(u)≤d(v)+w(u,v)` on every directed edge; and, for every non-capitol,
at least one neighboring equality `d(u)=d(v)+w(u,v)`. Positive weights force the
equalities to descend to a zero, preventing unsupported distance assignments.
Geometry, connectivity, state areas, and **all** symmetries must still be encoded
correctly. Distance inequalities alone are insufficient.

To establish uniqueness, a complete model must exclude this partition and search
all other allowed partitions. Infeasibility within a sampled catalog proves only
catalog-relative infeasibility. None of the present checks supplies that global proof.

## Reproduce

From the repository root:

```sh
python3 investigation/verify_candidate.py
python3 investigation/run_swift_inspection.py
MPLCONFIGDIR=/tmp/jsp-mpl-investigation python3 investigation/render_solution.py
```

The first command uses Python's standard library. The second compiles current
core Swift sources and the diagnostic into a temporary directory; it requires the
existing Swift toolchain, and runs bounded checks only. The third requires
matplotlib and regenerates the static figure. Probe details are saved in
`swift-inspection.txt`.
