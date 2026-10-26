//
//  Energy.swift
//  JaneStreetPuzzle_Oct26
//
//  Created by Thomas B on 10/12/26.
//

import Foundation

class Energy {
    // Lazily cache only encountered shapes; orientation and board location do not
    // affect a shape's energy. Keep using the same Energy instance to reuse it.
    private var symmetryEnergyCache: [[ShapeCell]: Float64] = [:]

    private struct ShapeCell: Hashable, Comparable {
        let row: Int
        let col: Int

        static func < (lhs: ShapeCell, rhs: ShapeCell) -> Bool {
            lhs.row == rhs.row ? lhs.col < rhs.col : lhs.row < rhs.row
        }
    }

    // Calculate the Energy
    func EnergyCal(Board: Board) -> [[Float64]] {
        return [[]]
    }
    
    typealias CapitolCandidate = (row: Float64, col: Float64, probability: Float64)

    struct CapitolField {
        let candidates: [CapitolCandidate]
        // The field remains normalized even for states that cannot be destinations.
        let canBeDestination: Bool
        let isExactCapitol: Bool
    }

    // 1. Real AIM
    /// Expected normalized clue error for the nearest possible capitol. Each
    /// state's location is drawn independently from its normalized field.
    /// Blank cells receive the global mean clue error; no clues means energy 1.
    /// This is a search heuristic: combine it with SymmetricalTest for validity.
    func RealAIMTest(Board: Board, Target: OriginalCondition) -> [[Float64]] {
        let shapes = boardShapes(Board)
        let rows = Board.BoardBasics.rowNum
        let cols = Board.BoardBasics.colNum
        precondition(Target.Status.count == rows && Target.Status.allSatisfy { $0.count == cols },
                     "Target must match the board dimensions")
        precondition(Target.Status.joined().allSatisfy { $0 >= -1 },
                     "Target values must be nonnegative clues or -1 for blanks")
        let fields = capitolFields(shapes)
        // Stable board order keeps floating-point reductions independent of UUIDs.
        let orderedShapes = shapes.sorted { $0.value[0] < $1.value[0] }
        var sizes = Array(repeating: 0, count: rows * cols)
        for (_, cells) in orderedShapes {
            for cell in cells { sizes[cell.row * cols + cell.col] = cells.count }
        }
        var energy = Array(repeating: Array(repeating: Float64(1), count: cols), count: rows)
        var clueCells: [ShapeCell] = []
        var total: Float64 = 0
        for row in 0..<rows {
            for col in 0..<cols where Target.Status[row][col] >= 0 {
                let distances = travelDistances(from: row * cols + col, rows: rows, cols: cols, sizes: sizes)
                var distributions: [[(cost: Float64, probability: Float64)]] = []
                for (id, cells) in orderedShapes {
                    let field = fields[id]!
                    guard field.canBeDestination else { continue }
                    // Each approximate sample stays inside its owning unit cell.
                    // Attach it to that cell's graph node by a fractional Manhattan
                    // terminal segment at the state's travel rate. Exact capitols
                    // sit on graph nodes and have zero terminal cost.
                    distributions.append(zip(cells, field.candidates).map { cell, sample in
                        let offset = abs(sample.row - Float64(cell.row)) + abs(sample.col - Float64(cell.col))
                        return (distances[cell.row * cols + cell.col] + Float64(cells.count) * offset,
                                sample.probability)
                    })
                }
                let score = expectedNearestError(target: Float64(Target.Status[row][col]), distributions: distributions)
                energy[row][col] = score
                total += score
                clueCells.append(ShapeCell(row: row, col: col))
            }
        }
        let mean = clueCells.isEmpty ? 1 : total / Float64(clueCells.count)
        for row in 0..<rows {
            for col in 0..<cols where Target.Status[row][col] == -1 { energy[row][col] = mean }
        }
        return energy
    }

    /// A numerical probability field per UUID. Coordinates use zero-based cell
    /// centers and may be fractional. Probability is quadrature mass, not density:
    /// masses sum to 1 per block, approximating an area integral of 1. An exact
    /// capitol is a point mass. The returned dictionary retains block identity.
    func CapitolCal(Board: Board) -> [UUID: CapitolField] {
        capitolFields(boardShapes(Board))
    }

    private func boardShapes(_ board: Board) -> [UUID: [ShapeCell]] {
        let rows = board.BoardBasics.rowNum
        let cols = board.BoardBasics.colNum
        precondition(rows > 0 && cols > 0, "Board dimensions must be positive")
        let blocks = board.Relationships.ColorBlocks
        precondition(blocks.count == rows && blocks.allSatisfy { $0.count == cols },
                     "ColorBlocks must match the board dimensions")
        var shapes: [UUID: [ShapeCell]] = [:]
        for row in 0..<rows {
            for col in 0..<cols {
                shapes[blocks[row][col], default: []].append(ShapeCell(row: row, col: col))
            }
        }
        return shapes
    }

    private func isConnected(_ cells: [ShapeCell]) -> Bool {
        let occupied = Set(cells)
        var visited: Set<ShapeCell> = [cells[0]]
        var queue = [cells[0]]
        var next = 0
        while next < queue.count {
            let cell = queue[next]
            next += 1
            for neighbor in [ShapeCell(row: cell.row - 1, col: cell.col),
                             ShapeCell(row: cell.row + 1, col: cell.col),
                             ShapeCell(row: cell.row, col: cell.col - 1),
                             ShapeCell(row: cell.row, col: cell.col + 1)] {
                if occupied.contains(neighbor) && visited.insert(neighbor).inserted { queue.append(neighbor) }
            }
        }
        return visited.count == cells.count
    }

    private func capitolFields(_ shapes: [UUID: [ShapeCell]]) -> [UUID: CapitolField] {
        var fields: [UUID: CapitolField] = [:]
        for (id, cells) in shapes {
            let occupied = Set(cells)
            var mappings: [[(row: Float64, col: Float64)]] = []
            var weights: [Float64] = []
            var exactFixedSets: [[ShapeCell]] = []
            let centerRow = Float64(cells.map(\.row).min()! + cells.map(\.row).max()!) / 2
            let centerCol = Float64(cells.map(\.col).min()! + cells.map(\.col).max()!) / 2
            for transform in 1..<8 {
                let raw = cells.map { transformedCell($0, by: transform) }
                let rawCenterRow = Float64(raw.map(\.row).min()! + raw.map(\.row).max()!) / 2
                let rawCenterCol = Float64(raw.map(\.col).min()! + raw.map(\.col).max()!) / 2
                // Preserve cell correspondence to inspect fixed points; sorting
                // both shapes here would discard the transformation's action.
                // Center alignment avoids orientation bias for rectangular bounds.
                let mapped = raw.map { (row: Float64($0.row) - rawCenterRow + centerRow,
                                        col: Float64($0.col) - rawCenterCol + centerCol) }
                var overlap: Float64 = 0
                for position in mapped {
                    // Transformed cells may sit on half-integer centers. Measure
                    // area overlap of unit squares, rather than rounding cells.
                    for row in Int(floor(position.row))...Int(ceil(position.row)) {
                        for col in Int(floor(position.col))...Int(ceil(position.col)) {
                            if occupied.contains(ShapeCell(row: row, col: col)) {
                                overlap += (1 - abs(position.row - Float64(row)))
                                    * (1 - abs(position.col - Float64(col)))
                            }
                        }
                    }
                }
                mappings.append(mapped)
                // Heuristic support, emphasizing transformations with high overlap.
                weights.append(exp(-8 * (Float64(cells.count) - overlap) / Float64(cells.count)))
                if overlap == Float64(cells.count) {
                    exactFixedSets.append(zip(cells, mapped).compactMap { cell, position in
                        Float64(cell.row) == position.row && Float64(cell.col) == position.col ? cell : nil
                    })
                }
            }
            let connected = isConnected(cells)
            if connected, let fixed = exactFixedSets.first, fixed.count == 1,
               exactFixedSets.allSatisfy({ $0.count == 1 && $0[0] == fixed[0] }) {
                // Keep one entry per cell, including zero masses, so sample
                // ownership is explicit and does not require coordinate rounding.
                fields[id] = CapitolField(candidates: cells.map {
                    (Float64($0.row), Float64($0.col), $0 == fixed[0] ? 1 : 0)
                }, canBeDestination: true, isExactCapitol: true)
                continue
            }
            let weightSum = weights.reduce(0, +)
            var logMasses: [Float64] = []
            var positions: [(row: Float64, col: Float64)] = []
            for (index, cell) in cells.enumerated() {
                var rowShift: Float64 = 0
                var colShift: Float64 = 0
                var fixedPointLoss: Float64 = 0
                for (mapping, weight) in zip(mappings, weights) {
                    let dr = mapping[index].row - Float64(cell.row)
                    let dc = mapping[index].col - Float64(cell.col)
                    rowShift += weight * dr
                    colShift += weight * dc
                    fixedPointLoss += weight * (dr * dr + dc * dc)
                }
                // Move toward approximate fixed points while keeping this
                // quadrature sample strictly inside its owning unit square.
                positions.append((Float64(cell.row) + max(-0.49, min(0.49, rowShift / (2 * weightSum))),
                                  Float64(cell.col) + max(-0.49, min(0.49, colShift / (2 * weightSum)))))
                logMasses.append(-fixedPointLoss / (2 * weightSum))
            }
            // Subtract the maximum before exponentiation to avoid underflow.
            let peak = logMasses.max()!
            let masses = logMasses.map { exp($0 - peak) }
            let massSum = masses.reduce(0, +)
            let candidates = zip(positions, masses).map { ($0.row, $0.col, $1 / massSum) }
            fields[id] = CapitolField(candidates: candidates,
                canBeDestination: connected && exactFixedSets.isEmpty, isExactCapitol: false)
        }
        return fields
    }

    private func travelDistances(from source: Int, rows: Int, cols: Int, sizes: [Int]) -> [Float64] {
        let count = rows * cols
        var distances = Array(repeating: Float64.infinity, count: count)
        var visited = Array(repeating: false, count: count)
        distances[source] = 0
        // O(V^2) Dijkstra is small for this puzzle's 121 cells and needs no heap.
        for _ in 0..<count {
            var current: Int?
            for index in 0..<count where !visited[index] {
                if current == nil || distances[index] < distances[current!] { current = index }
            }
            guard let cell = current, distances[cell].isFinite else { break }
            visited[cell] = true
            let row = cell / cols
            let col = cell % cols
            var neighbors: [Int] = []
            if row > 0 { neighbors.append(cell - cols) }
            if row + 1 < rows { neighbors.append(cell + cols) }
            if col > 0 { neighbors.append(cell - 1) }
            if col + 1 < cols { neighbors.append(cell + 1) }
            for neighbor in neighbors {
                distances[neighbor] = min(distances[neighbor], distances[cell] + Float64(min(sizes[cell], sizes[neighbor])))
            }
        }
        return distances
    }

    private func expectedNearestError(target: Float64,
        distributions: [[(cost: Float64, probability: Float64)]]) -> Float64 {
        guard !distributions.isEmpty else { return 1 }
        var events: [(cost: Float64, probability: Float64, state: Int)] = []
        for (state, distribution) in distributions.enumerated() {
            for sample in distribution where sample.probability > 0 {
                events.append((sample.cost, sample.probability, state))
            }
        }
        events.sort { $0.cost < $1.cost }
        // P(all capitols farther than d) = product_s P(capitol_s farther than d).
        // Differences of this survival function give the distribution of the
        // nearest capitol, without enumerating every combination of locations.
        var survival = Array(repeating: Float64(1), count: distributions.count)
        var previous: Float64 = 1
        var result: Float64 = 0
        var index = 0
        while index < events.count {
            let cost = events[index].cost
            repeat {
                let event = events[index]
                survival[event.state] = max(0, survival[event.state] - event.probability)
                index += 1
            } while index < events.count && events[index].cost == cost
            let remaining = survival.reduce(1, *)
            result += max(0, previous - remaining) * abs(cost - target) / max(cost, target, 1)
            previous = remaining
        }
        // Any floating-point residual mass gets the maximum penalty.
        return max(0, min(1, result + previous))
    }

    private func transformedCell(_ cell: ShapeCell, by transform: Int) -> ShapeCell {
        let r = cell.row
        let c = cell.col
        switch transform {
        case 0: return ShapeCell(row: r, col: c)
        case 1: return ShapeCell(row: c, col: -r)
        case 2: return ShapeCell(row: -r, col: -c)
        case 3: return ShapeCell(row: -c, col: r)
        case 4: return ShapeCell(row: r, col: -c)
        case 5: return ShapeCell(row: -r, col: c)
        case 6: return ShapeCell(row: c, col: r)
        default: return ShapeCell(row: -c, col: -r)
        }
    }

    private func normalizedShape(_ cells: [ShapeCell]) -> [ShapeCell] {
        let minRow = cells.map(\.row).min()!
        let minCol = cells.map(\.col).min()!
        return cells.map { ShapeCell(row: $0.row - minRow, col: $0.col - minCol) }.sorted()
    }

    // Keep all eight entries, even when equal: a nonidentity transformation
    // mapping the shape to itself is precisely the symmetry we are looking for.
    private func shapeOrientations(_ cells: [ShapeCell]) -> [[ShapeCell]] {
        (0..<8).map { transform in
            normalizedShape(cells.map { cell in
                transformedCell(cell, by: transform)
            })
        }
    }


    // 2. Symmetric
    /// Returns one energy per board cell, constant within each ColorBlocks UUID.
    /// For a connected shape S, energy is min |S △ N(gS)| / (2 * |S|)
    /// over the seven nonidentity D4 transformations, with S also normalized.
    /// Thus 0 means at least one exact symmetry and 1 means no overlap under
    /// any tested transformation. Disconnected UUID groups receive energy 1.
    /// Reads ColorBlocks directly without changing the board or requiring capitals.
    func SymmetricalTest(Board: Board) -> [[Float64]] {
        func symmetryEnergy(_ orientations: [[ShapeCell]]) -> Float64 {
            let shape = orientations[0]
            let occupied = Set(shape)
            var visited: Set<ShapeCell> = [shape[0]]
            var queue = [shape[0]]
            var next = 0
            while next < queue.count {
                let cell = queue[next]
                next += 1
                for neighbor in [ShapeCell(row: cell.row - 1, col: cell.col),
                                 ShapeCell(row: cell.row + 1, col: cell.col),
                                 ShapeCell(row: cell.row, col: cell.col - 1),
                                 ShapeCell(row: cell.row, col: cell.col + 1)] {
                    if occupied.contains(neighbor) && visited.insert(neighbor).inserted {
                        queue.append(neighbor)
                    }
                }
            }
            guard visited.count == shape.count else { return 1 }

            // A shared square stride accommodates every orientation. Two UInt64
            // words suffice on an 11 x 11 board; larger boards use additional words.
            let stride = max(shape.map(\.row).max()!, shape.map(\.col).max()!) + 1
            func mask(_ cells: [ShapeCell]) -> [UInt64] {
                var words = Array(repeating: UInt64(0), count: (stride * stride + 63) / 64)
                for cell in cells {
                    let index = cell.row * stride + cell.col
                    words[index / 64] |= UInt64(1) << (index % 64)
                }
                return words
            }
            let original = mask(shape)
            var bestOverlap = 0
            for orientation in orientations.dropFirst() {
                let transformed = mask(orientation)
                let overlap = zip(original, transformed).reduce(0) {
                    $0 + ($1.0 & $1.1).nonzeroBitCount
                }
                bestOverlap = max(bestOverlap, overlap)
                if bestOverlap == shape.count { return 0 }
            }
            return Float64(shape.count - bestOverlap) / Float64(shape.count)
        }

        let rows = Board.BoardBasics.rowNum
        let cols = Board.BoardBasics.colNum
        let blocks = Board.Relationships.ColorBlocks
        precondition(blocks.count == rows && blocks.allSatisfy { $0.count == cols },
                     "ColorBlocks must match the board dimensions")

        var energy = Array(repeating: Array(repeating: Float64(0), count: cols), count: rows)
        var shapes: [UUID: [ShapeCell]] = [:]
        for row in 0..<rows {
            for col in 0..<cols {
                shapes[blocks[row][col], default: []].append(ShapeCell(row: row, col: col))
            }
        }

        for cells in shapes.values {
            let orientations = shapeOrientations(cells)
            let canonical = orientations.min { $0.lexicographicallyPrecedes($1) }!
            let score: Float64
            if let cached = symmetryEnergyCache[canonical] {
                score = cached
            } else {
                score = symmetryEnergy(orientations)
                symmetryEnergyCache[canonical] = score
            }
            for cell in cells {
                energy[cell.row][cell.col] = score
            }
        }
        return energy
    }

    
    // 3. Strength Closeness to 0 or 1
    func DiscretenessTest(Board: Board) -> ([[Float64]], [[Float64]]) {
        var VerticalEnergy: [[Float64]] = Array(
            repeating: Array(repeating: 0, count: Board.BoardBasics.colNum - 1),
            count: Board.BoardBasics.rowNum
        )
        var HorizontalEnergy: [[Float64]] = Array(
            repeating: Array(repeating: 0, count: Board.BoardBasics.colNum),
            count: Board.BoardBasics.rowNum - 1
        )
        
        // Through each row
        for row in 0...(Board.BoardBasics.colNum) {
            for col in 0...(Board.BoardBasics.rowNum - 1) {
                VerticalEnergy[row][col] = tan(2 * min(Board.Relationships.VerticalRelationships[row][col], 1 - Board.Relationships.VerticalRelationships[row][col]))
            }
        }
        // Through each column
        for col in 0...(Board.BoardBasics.rowNum) {
            for row in 0...(Board.BoardBasics.colNum - 1) {
                HorizontalEnergy[row][col] = tan(2 * min(Board.Relationships.HorizontalRelationships[row][col], 1 - Board.Relationships.HorizontalRelationships[row][col]))
            }
        }
        return (VerticalEnergy, HorizontalEnergy)
    }
}
