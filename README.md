# JaneStreetPuzzle_Oct26

Swift experiments for the symmetry, capitol, and travel-cost puzzle in the supplied image.

```swift
let energy = Energy()
let fields = energy.CapitolCal(Board: board)
let scores = energy.RealAIMTest(Board: board, Target: config.Target)
```

`ColorBlocks` must already describe the proposed states. These functions read the
board without mutating it. `RealAIMTest` takes the clues explicitly: `-1` is blank,
and `0` is a real clue.

Each UUID has a `CapitolField` containing `(row, col, probability)` candidates in
row-major cell order, one per cell. Coordinates are continuous, with integer
coordinates at cell centers. Probabilities are numerical integration weights:
they sum to 1 within each block and approximate a normalized area distribution.
This finite quadrature is not an analytic continuous density. Exact capitols
use a point mass (one weight of 1, all other weights 0).

For tentative fields, the seven nonidentity D4 transformations are aligned at
the bounding-box center. A transformation's weight is `exp(-8 * (1 - overlap))`,
where overlap is the fraction of unit-square area shared with the original
shape. Candidate masses favor cells with low weighted squared displacement
under those transformations. Each position moves halfway toward its weighted
transformed position, capped at 0.49 cell lengths per axis to preserve ownership.
The masses are normalized using a stable exponential calculation. These choices
define a heuristic distribution; they are not calibrated statistical probabilities.

A connected exact symmetric state has a capitol only when every nonidentity
symmetry fixes the same single cell. Exact symmetric states without capitols
and disconnected UUID groups still have normalized fields, but their
`canBeDestination` flag is false. Asymmetric connected states provide tentative
destinations during the search.

Travel follows the orthogonal cell graph. Edge costs are the smaller of the two
state sizes. A candidate is attached to its owning cell center by a fractional
Manhattan terminal segment, charged at that state's size. This is a numerical
extension of the puzzle's graph, not an unrestricted path through the plane.

The capitol locations of different states are modeled independently. For each
clue, compute the expected error of the nearest capitol using
`abs(cost - target) / max(cost, target, 1)`. The calculation uses survival
probabilities to avoid enumerating all combinations of candidate locations.
Every energy lies in `[0, 1]`; blank cells get the global mean clue energy.
No clues or no eligible destinations give energy 1. `RealAIMTest` is a search
heuristic and must be combined with `SymmetricalTest` when checking validity.

Run the standalone checks from the repository root:

```sh
swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
  JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
  Tests/SymmetryEnergyTests.swift -o /tmp/symmetry-energy-tests
/tmp/symmetry-energy-tests

swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
  JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
  Tests/RealAIMEnergyTests.swift -o /tmp/real-aim-tests
/tmp/real-aim-tests
```
