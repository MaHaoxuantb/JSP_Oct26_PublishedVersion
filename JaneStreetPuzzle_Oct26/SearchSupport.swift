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
    case boundary, merge, split, patch, relationship, regionMerge, constrainedPatch, orbitTransfer
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
    private let adjacency: [[Int]]
    init(rows: Int, cols: Int) {
        self.rows = rows; self.cols = cols
        adjacency = (0..<(rows * cols)).map { cell in
            var result: [Int] = []
            if cell / cols > 0 { result.append(cell - cols) }
            if cell % cols + 1 < cols { result.append(cell + 1) }
            if cell / cols + 1 < rows { result.append(cell + cols) }
            if cell % cols > 0 { result.append(cell - 1) }
            return result
        }
    }
    func neighbors(_ cell: Int) -> [Int] { adjacency[cell] }
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

/// Boards are materialized only for display, snapshots and independent validation.
/// Each saved state has its own lazy holder; candidate evaluation uses integer labels.
private final class LazyBoard {
    private var value: Board?
    private let make: () -> Board
    init(_ make: @escaping () -> Board) { self.make = make }
    init(board: Board) { value = board; make = { board.copy() } }
    func get() -> Board {
        if let value { return value }
        let board = make(); value = board; return board
    }
    func copy() -> LazyBoard {
        if let value { return LazyBoard(board: value.copy()) }
        return LazyBoard(make)
    }
}

struct SearchState {
    private let storage: LazyBoard
    let labels: [Int]
    var board: Board { storage.get() }
    let scores: Energy.Scores
    let validation: ValidationReport
    var parents: [Int?]
    init(board: Board, scores: Energy.Scores, validation: ValidationReport, parents: [Int?] = []) {
        var ids: [UUID: Int] = [:]
        labels = board.Relationships.ColorBlocks.flatMap { $0 }.map { id in
            if ids[id] == nil { ids[id] = ids.count }; return ids[id]!
        }
        storage = LazyBoard(board: board)
        self.scores = scores; self.validation = validation; self.parents = parents
    }
    init(labels: [Int], scores: Energy.Scores, validation: ValidationReport,
         parents: [Int?], makeBoard: @escaping () -> Board) {
        self.labels = labels; self.scores = scores; self.validation = validation
        self.parents = parents; storage = LazyBoard(makeBoard)
    }
    private init(_ source: SearchState, storage: LazyBoard) {
        self.storage = storage; labels = source.labels; scores = source.scores
        validation = source.validation; parents = source.parents
    }
    var quality: SearchQuality { SearchQuality(validation, scores) }
    func snapshot() -> SearchState { SearchState(self, storage: storage.copy()) }
}

final class SearchContext {
    var config: RunConfig {
        didSet {
            if oldValue.pathEvaluation != config.pathEvaluation {
                pathEvaluator = PathEvaluator(grid: grid, mode: config.pathEvaluation)
            }
        }
    }
    let validator = ExactValidator()
    var rng: SearchRandom
    let grid: Grid
    let regions: RegionCache
    let constraints: ClueConstraints
    let clueCount: Int
    lazy var pathEvaluator = PathEvaluator(grid: grid, mode: config.pathEvaluation)
    var metrics = RepairMetrics()
    let mergeCursors = BoundedCache<MergeScanKey, MergeCursor>(capacity: 32)
    let catalogs = BoundedCache<[Int], [[Int]]>(capacity: 64)
    let catalogUses = BoundedCache<[Int], Int>(capacity: 64)
    // Match the active catalog capacity. Region cursors store compact box indexes,
    // not full four-coordinate tuples or a search tree for every patch.
    let regionSampling = BoundedCache<[Int], RegionSamplingCursor>(capacity: 64)
    let capitolGrowth = BoundedCache<[Int], CapitolGrowthCursor>(capacity: 64)
    var growthSteps = 0
    var visitedCapitolAnchors = Set<Int>()
    var largeShapeAttempts = 0
    var largeShapeTicket = 0
    var largeRepairTurn = 0
    var largeShapes: [[Int]] = []
    let permitted = BoundedCache<[Int], Bool>(capacity: 32_768)
    let evaluations = BoundedCache<[Int], SearchState>(capacity: 2_048)
    var proposalNumber = 0
    var initialShapes: Set<[Int]> = []
    var initializationCount = 0
    var clueWeights: [Double] = []
    var repairTicket = 0
    var deadline = Double.infinity
    private(set) var bestEvaluated: SearchState?

    func resetDiscoveries() { bestEvaluated = nil }

    /// Retain discoveries independently of the objective used to choose a move.
    func recordDiscovery(_ state: SearchState) {
        if bestEvaluated == nil || state.quality < bestEvaluated!.quality {
            bestEvaluated = state.snapshot()
        }
    }

    init(config: RunConfig) {
        self.config = config
        rng = SearchRandom(seed: config.seed)
        grid = Grid(rows: config.rowNum, cols: config.colNum)
        regions = RegionCache(grid: grid)
        constraints = ClueConstraints(grid: grid, clues: config.Target.Status.flatMap { $0 })
        clueCount = constraints.clues.filter { $0 >= 0 }.count
        clueWeights = Array(repeating: 1, count: grid.count)
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

/// Fixed-capacity FIFO eviction preserves other entries instead of clearing a cache.
final class BoundedCache<Key: Hashable, Value> {
    private var values: [Key: Value] = [:]
    private var slots: [Key?]
    private var next = 0
    init(capacity: Int) { slots = Array(repeating: nil, count: max(1, capacity)) }
    subscript(key: Key) -> Value? {
        get { values[key] }
        set {
            guard let newValue else { values.removeValue(forKey: key); return }
            if values[key] == nil {
                if let old = slots[next] { values.removeValue(forKey: old) }
                slots[next] = key; next = (next + 1) % slots.count
            }
            values[key] = newValue
        }
    }
}

/// Arbitrary-width masks: ordinary patches use one word, an 11×11 board uses two.
struct CellMask: Hashable {
    var words: [UInt64]
    init(count: Int, cells: [Int] = []) {
        words = Array(repeating: 0, count: (count + 63) / 64)
        for cell in cells { insert(cell) }
    }
    mutating func insert(_ cell: Int) { words[cell >> 6] |= UInt64(1) << (cell & 63) }
    func contains(_ cell: Int) -> Bool { words[cell >> 6] & (UInt64(1) << (cell & 63)) != 0 }
    func intersects(_ other: Self) -> Bool {
        for i in words.indices where words[i] & other.words[i] != 0 { return true }
        return false
    }
    mutating func formUnion(_ other: Self) {
        for i in words.indices { words[i] |= other.words[i] }
    }
    mutating func subtract(_ other: Self) {
        for i in words.indices { words[i] &= ~other.words[i] }
    }
    var cells: [Int] {
        var result: [Int] = []
        for i in words.indices {
            var word = words[i]
            while word != 0 {
                result.append(i * 64 + word.trailingZeroBitCount)
                word &= word - 1
            }
        }
        return result
    }
}

enum SearchObjective: String, Codable, Sendable, CaseIterable {
    case matches, residual, persistent
}

extension SearchContext {
    func merit(_ state: SearchState) -> Double {
        if state.validation.valid { return -1 }
        switch config.searchObjective {
        case .matches: return state.quality.merit(clues: clueCount)
        case .residual:
            return Double(state.quality.issues) + state.scores.realAIM
                + 0.05 * Double(state.quality.wrong) / Double(max(1, clueCount))
        case .persistent:
            var error = 0.0, weight = 0.0
            for cell in constraints.clues.indices where constraints.clues[cell] >= 0 { weight += clueWeights[cell] }
            for mismatch in state.validation.mismatches {
                let cell = mismatch.cell.row * grid.cols + mismatch.cell.col
                let e = mismatch.actual.map {
                    abs(Double($0) - Double(mismatch.expected)) / max(Double($0), Double(mismatch.expected), 1)
                } ?? 1
                error += clueWeights[cell] * e
            }
            return Double(state.quality.issues) + error / max(1, weight)
                + 0.05 * Double(state.quality.wrong) / Double(max(1, clueCount))
        }
    }
    func prefers(_ a: SearchState, over b: SearchState) -> Bool {
        let x = merit(a), y = merit(b)
        return x != y ? x < y : a.quality < b.quality
    }
    func adaptClueWeights(_ state: SearchState) {
        for i in clueWeights.indices { clueWeights[i] = 1 + (clueWeights[i] - 1) * 0.9 }
        for mismatch in state.validation.mismatches {
            let i = mismatch.cell.row * grid.cols + mismatch.cell.col
            clueWeights[i] = min(8, clueWeights[i] + 0.5)
        }
    }
    func permits(_ cells: [Int]) -> Bool {
        let key = cells.sorted()
        if let cached = permitted[key] { return cached }
        let start = ProcessInfo.processInfo.systemUptime
        let value = constraints.permits(key, geometry: regions.geometry(key))
        metrics.geometrySeconds += ProcessInfo.processInfo.systemUptime - start
        if !value { metrics.constraintRejects += 1 }
        permitted[key] = value
        return value
    }
}
