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
    case boundary, merge, split, patch, relationship, regionMerge, constrainedPatch
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
    var parents: [Int?] = []
    var quality: SearchQuality { SearchQuality(validation, scores) }
    func snapshot() -> SearchState {
        SearchState(board: board.copy(), scores: scores, validation: validation, parents: parents)
    }
}

final class SearchContext {
    let config: RunConfig
    let validator = ExactValidator()
    var rng: SearchRandom
    let grid: Grid
    let regions: RegionCache
    let constraints: ClueConstraints
    let clueCount: Int
    var metrics = RepairMetrics()
    var mergeCursors: [[Int]: MergeCursor] = [:]
    var catalogs: [[Int]: [[Int]]] = [:]
    var catalogUses: [[Int]: Int] = [:]
    var repairTicket = 0
    var deadline = Double.infinity

    init(config: RunConfig) {
        self.config = config
        rng = SearchRandom(seed: config.seed)
        grid = Grid(rows: config.rowNum, cols: config.colNum)
        regions = RegionCache(grid: grid)
        constraints = ClueConstraints(grid: grid, clues: config.Target.Status.flatMap { $0 })
        clueCount = constraints.clues.filter { $0 >= 0 }.count
    }

    /// All search relationships are canonical binary boundaries. The public
    /// continuous energy API remains available for independent experiments.
    func encodePartition(_ board: Board, harden: Bool = true, initialize: Bool = false) {
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let id = board.Relationships.ColorBlocks[row][col]
                if col + 1 < grid.cols {
                    board.Relationships.VerticalRelationships[row][col] =
                        id == board.Relationships.ColorBlocks[row][col + 1] ? 1 : 0
                }
                if row + 1 < grid.rows {
                    board.Relationships.HorizontalRelationships[row][col] =
                        id == board.Relationships.ColorBlocks[row + 1][col] ? 1 : 0
                }
            }
        }
    }

    func shuffled<T>(_ values: [T]) -> [T] {
        var values = values
        if values.count > 1 {
            for index in stride(from: values.count - 1, through: 1, by: -1) {
                values.swapAt(index, rng.index(index + 1))
            }
        }
        return values
    }

    func expired(_ until: Double) -> Bool {
        Task.isCancelled || ProcessInfo.processInfo.systemUptime >= min(until, deadline)
    }
}
