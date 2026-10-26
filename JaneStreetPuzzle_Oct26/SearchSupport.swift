import Foundation

/// SplitMix64. All search choices use this stream; UUID values never select moves.
struct SearchRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }
    mutating func index(_ count: Int) -> Int {
        precondition(count > 0)
        let bound = UInt64(count)
        let limit = UInt64.max - UInt64.max % bound
        var value = next()
        while value >= limit { value = next() }
        return Int(value % bound)
    }
}

enum MoveKind: String, Codable, CaseIterable {
    case boundary, merge, split, patch, relationship
}

struct RelationshipChange: Codable {
    let vertical: Bool
    let row: Int
    let col: Int
    let previous: Double
    let proposed: Double

    static func between(_ previous: Board, _ proposed: Board) -> [RelationshipChange] {
        var changes: [RelationshipChange] = []
        for (vertical, before, after) in [
            (true, previous.Relationships.VerticalRelationships, proposed.Relationships.VerticalRelationships),
            (false, previous.Relationships.HorizontalRelationships, proposed.Relationships.HorizontalRelationships)
        ] {
            for row in before.indices {
                for col in before[row].indices where before[row][col] != after[row][col] {
                    changes.append(RelationshipChange(vertical: vertical, row: row, col: col,
                                                      previous: before[row][col], proposed: after[row][col]))
                }
            }
        }
        return changes
    }
}

struct Grid {
    let rows: Int
    let cols: Int
    var count: Int { rows * cols }
    func neighbors(_ cell: Int) -> [Int] {
        let row = cell / cols
        let col = cell % cols
        var result: [Int] = []
        if row > 0 { result.append(cell - cols) }
        if col + 1 < cols { result.append(cell + 1) }
        if row + 1 < rows { result.append(cell + cols) }
        if col > 0 { result.append(cell - 1) }
        return result
    }
    func connected(_ cells: [Int]) -> Bool {
        guard let start = cells.first else { return true }
        let allowed = Set(cells)
        var seen: Set<Int> = [start]
        var queue = [start]
        var next = 0
        while next < queue.count {
            let cell = queue[next]
            next += 1
            for neighbor in neighbors(cell) where allowed.contains(neighbor) {
                if seen.insert(neighbor).inserted { queue.append(neighbor) }
            }
        }
        return queue.count == cells.count
    }

    /// Grow connected regions from random seeds within a connected set of cells.
    func partition(_ cells: [Int], regions: Int, rng: inout SearchRandom) -> [Int: UUID] {
        precondition(!cells.isEmpty && regions > 0 && regions <= cells.count && connected(cells))
        let allowed = Set(cells)
        var remaining = cells
        var labels: [Int: UUID] = [:]
        var frontier: [(Int, Int)] = []
        for _ in 0..<regions {
            let index = rng.index(remaining.count)
            let seed = remaining.remove(at: index)
            labels[seed] = UUID()
            for neighbor in neighbors(seed) where allowed.contains(neighbor) { frontier.append((seed, neighbor)) }
        }
        while !frontier.isEmpty {
            let index = rng.index(frontier.count)
            let (from, to) = frontier[index]
            frontier.swapAt(index, frontier.count - 1)
            frontier.removeLast()
            guard labels[to] == nil else { continue }
            labels[to] = labels[from]!
            for neighbor in neighbors(to) where allowed.contains(neighbor) && labels[neighbor] == nil {
                frontier.append((to, neighbor))
            }
        }
        precondition(labels.count == cells.count)
        return labels
    }
}

struct SearchState {
    let board: Board
    let scores: Energy.Scores
    let validation: ValidationReport
    func snapshot() -> SearchState { SearchState(board: board.copy(), scores: scores, validation: validation) }
}

final class SearchContext {
    let config: RunConfig
    let energy = Energy()
    let runners = Runners()
    let validator = ExactValidator()
    var rng: SearchRandom
    let grid: Grid

    init(config: RunConfig) {
        self.config = config
        self.rng = SearchRandom(seed: config.seed)
        self.grid = Grid(rows: config.rowNum, cols: config.colNum)
    }

    func evaluate(_ board: Board) -> SearchState {
        runners.IntoColorBlocks(Board: board)
        let report = validator.validate(board, target: config.Target)
        // A genuine solution can be made fully discrete without changing states.
        if report.valid { encodePartition(board, harden: true) }
        for cell in report.capitols { board.Relationships.Capitals[cell.row][cell.col] = true }
        let evaluation = energy.evaluate(Board: board, Target: config.Target, Factors: config.factors)
        board.Energy = evaluation.cells
        return SearchState(board: board, scores: evaluation.scores, validation: report)
    }

    /// Materialize a proposed partition as relationships. Preserve unmodified
    /// strengths, so structural proposals do not reset all discreteness progress.
    func encodePartition(_ board: Board, harden: Bool = false, initialize: Bool = false) {
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                if col + 1 < grid.cols {
                    let joined = board.Relationships.ColorBlocks[row][col] == board.Relationships.ColorBlocks[row][col + 1]
                    let old = board.Relationships.VerticalRelationships[row][col]
                    if harden || initialize || (old >= 0.5) != joined {
                        board.Relationships.VerticalRelationships[row][col] = joined ? (harden ? 1 : 0.9) : (harden ? 0 : 0.1)
                    }
                }
                if row + 1 < grid.rows {
                    let joined = board.Relationships.ColorBlocks[row][col] == board.Relationships.ColorBlocks[row + 1][col]
                    let old = board.Relationships.HorizontalRelationships[row][col]
                    if harden || initialize || (old >= 0.5) != joined {
                        board.Relationships.HorizontalRelationships[row][col] = joined ? (harden ? 1 : 0.9) : (harden ? 0 : 0.1)
                    }
                }
            }
        }
    }

    private func focus(_ board: Board) -> Int {
        if rng.unit() < config.uniformSelectionProbability { return rng.index(grid.count) }
        let weights = board.Energy.flatMap { $0 }.map { 0.05 + $0 }
        var choice = rng.unit() * weights.reduce(0, +)
        for index in weights.indices {
            choice -= weights[index]
            if choice < 0 { return index }
        }
        return grid.count - 1
    }

    /// Returns nil if this proposal cannot alter the relationships.
    func propose(from current: Board) -> (board: Board, kind: MoveKind)? {
        let candidate = current.copy()
        let choice = rng.unit()
        let kind: MoveKind
        if choice < 0.65 { kind = .boundary }
        else if choice < 0.75 { kind = .merge }
        else if choice < 0.85 { kind = .split }
        else if choice < 0.95 { kind = .patch }
        else { kind = .relationship }
        let cell = focus(current)
        var labels = candidate.Relationships.ColorBlocks.flatMap { $0 }
        switch kind {
        case .boundary:
            let destinations = grid.neighbors(cell).filter { labels[$0] != labels[cell] }
            guard !destinations.isEmpty else { return nil }
            let donor = labels.indices.filter { labels[$0] == labels[cell] && $0 != cell }
            guard grid.connected(donor) else { return nil }
            labels[cell] = labels[destinations[rng.index(destinations.count)]]
        case .merge:
            let destinations = grid.neighbors(cell).filter { labels[$0] != labels[cell] }
            guard !destinations.isEmpty else { return nil }
            let old = labels[cell]
            let new = labels[destinations[rng.index(destinations.count)]]
            for index in labels.indices where labels[index] == old { labels[index] = new }
        case .split:
            let cells = labels.indices.filter { labels[$0] == labels[cell] }
            guard cells.count > 1 else { return nil }
            let parts = grid.partition(cells, regions: 2, rng: &rng)
            for index in cells { labels[index] = parts[index]! }
        case .patch:
            let radius = 1 + rng.index(2)
            let row = cell / grid.cols
            let col = cell % grid.cols
            var cells: [Int] = []
            for r in max(0, row - radius)...min(grid.rows - 1, row + radius) {
                for c in max(0, col - radius)...min(grid.cols - 1, col + radius) { cells.append(r * grid.cols + c) }
            }
            guard cells.count > 1 else { return nil }
            let parts = grid.partition(cells, regions: 1 + rng.index(min(4, cells.count)), rng: &rng)
            for index in cells { labels[index] = parts[index]! }
            // Outside fragments disconnected by this patch are separated during
            // the subsequent component rebuild, including splits of old UUIDs.
        case .relationship:
            let neighbors = grid.neighbors(cell)
            guard !neighbors.isEmpty else { return nil }
            let neighbor = neighbors[rng.index(neighbors.count)]
            let row = min(cell, neighbor) / grid.cols
            let col = min(cell, neighbor) % grid.cols
            let verticalBoundary = cell / grid.cols == neighbor / grid.cols
            let old = verticalBoundary ? candidate.Relationships.VerticalRelationships[row][col]
                : candidate.Relationships.HorizontalRelationships[row][col]
            let new: Double
            if rng.unit() < 0.5 { new = old >= 0.5 ? 0.1 : 0.9 }
            else { new = old >= 0.5 ? 1 : 0 }
            if verticalBoundary { candidate.Relationships.VerticalRelationships[row][col] = new }
            else { candidate.Relationships.HorizontalRelationships[row][col] = new }
        }
        if kind != .relationship {
            for index in labels.indices { candidate.Relationships.ColorBlocks[index / grid.cols][index % grid.cols] = labels[index] }
            encodePartition(candidate)
        }
        guard candidate.Relationships.VerticalRelationships != current.Relationships.VerticalRelationships
                || candidate.Relationships.HorizontalRelationships != current.Relationships.HorizontalRelationships else { return nil }
        return (candidate, kind)
    }
}
