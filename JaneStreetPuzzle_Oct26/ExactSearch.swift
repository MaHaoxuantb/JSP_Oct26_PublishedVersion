import Foundation

/// Search ordering is independent of the display energy: feasibility, then
/// number of wrong clues, then exact normalized distance error.
struct SearchQuality: Comparable, Sendable {
    let issues: Int
    let wrong: Int
    let error: Double
    init(_ report: ValidationReport, _ scores: Energy.Scores) {
        issues = report.issues.count
        wrong = report.mismatches.count
        error = scores.realAIM
    }
    static func < (a: Self, b: Self) -> Bool {
        if a.issues != b.issues { return a.issues < b.issues }
        if a.wrong != b.wrong { return a.wrong < b.wrong }
        return a.error < b.error
    }
    func merit(clues: Int) -> Double {
        Double(issues) + (Double(wrong) + 0.5 * error) / Double(clues + 1)
    }
}

struct RegionGeometry {
    let connected: Bool
    let symmetric: Bool
    let capitol: Int?
}

/// Worker-local, position-aware cache. The final validator intentionally does
/// not use this cache or this implementation.
final class RegionCache {
    let grid: Grid
    private let cache = BoundedCache<[Int], RegionGeometry>(capacity: 32_768)
    private let shapes = BoundedCache<[Int], RegionGeometry>(capacity: 8_192)
    init(grid: Grid) { self.grid = grid }

    func geometry(_ cells: [Int]) -> RegionGeometry {
        let cells = cells.sorted()
        if let value = cache[cells] { return value }
        guard !cells.isEmpty else { return RegionGeometry(connected: false, symmetric: false, capitol: nil) }
        let top = cells.map { $0 / grid.cols }.min()!
        let bottom = cells.map { $0 / grid.cols }.max()!
        let left = cells.map { $0 % grid.cols }.min()!
        let right = cells.map { $0 % grid.cols }.max()!
        let width = right - left + 1
        let local = cells.map { ($0 / grid.cols - top) * width + ($0 % grid.cols - left) }
        let shapeKey = [width, bottom - top + 1] + local
        if let shape = shapes[shapeKey] {
            let value = RegionGeometry(connected: shape.connected, symmetric: shape.symmetric,
                capitol: shape.capitol.map { (top + $0 / width) * grid.cols + left + $0 % width })
            cache[cells] = value
            return value
        }
        let connected = grid.connected(cells)
        let occupied = Set(cells)
        var fixed: [Set<Int>] = []
        for transform in 0..<7 {
            let mapped = cells.map { Self.map($0, transform: transform, top: top, bottom: bottom,
                                             left: left, right: right, cols: grid.cols) }
            if mapped.allSatisfy({ $0 != nil }), Set(mapped.compactMap { $0 }) == occupied {
                fixed.append(Set(zip(cells, mapped).compactMap { $0 == $1 ? $0 : nil }))
            }
        }
        let capitol = fixed.first.flatMap { first -> Int? in
            guard first.count == 1, fixed.allSatisfy({ $0 == first }) else { return nil }
            return first.first
        }
        let value = RegionGeometry(connected: connected, symmetric: !fixed.isEmpty,
                                   capitol: connected ? capitol : nil)
        shapes[shapeKey] = RegionGeometry(connected: value.connected, symmetric: value.symmetric,
            capitol: value.capitol.map { ($0 / grid.cols - top) * width + $0 % grid.cols - left })
        cache[cells] = value
        return value
    }

    static func map(_ cell: Int, transform: Int, top: Int, bottom: Int,
                    left: Int, right: Int, cols: Int) -> Int? {
        let r = cell / cols - top, c = cell % cols - left
        let h = bottom - top + 1, w = right - left + 1
        let q: (Int, Int)
        switch transform {
        case 0: guard h == w else { return nil }; q = (c, h - 1 - r)
        case 1: q = (h - 1 - r, w - 1 - c)
        case 2: guard h == w else { return nil }; q = (w - 1 - c, r)
        case 3: q = (r, w - 1 - c)
        case 4: q = (h - 1 - r, c)
        case 5: guard h == w else { return nil }; q = (c, r)
        default: guard h == w else { return nil }; q = (w - 1 - c, h - 1 - r)
        }
        return (q.0 + top) * cols + q.1 + left
    }
}

struct ClueConstraints {
    let grid: Grid
    let clues: [Int]
    let minimumSizes: [Int]
    init(grid: Grid, clues: [Int]) {
        self.grid = grid; self.clues = clues
        var sizes = Array(repeating: 1, count: grid.count)
        for cell in clues.indices where clues[cell] >= 0 {
            for neighbor in grid.neighbors(cell) where clues[neighbor] >= 0 {
                sizes[cell] = max(sizes[cell], abs(clues[cell] - clues[neighbor]))
            }
        }
        minimumSizes = sizes
    }
    /// A zero must be the region's actual capitol; a positive clue cannot be one.
    func permits(_ cells: [Int], geometry: RegionGeometry) -> Bool {
        guard geometry.connected && geometry.symmetric else { return false }
        guard cells.allSatisfy({ cells.count >= minimumSizes[$0] }) else { return false }
        for cell in cells where clues[cell] == 0 {
            if geometry.capitol != cell { return false }
        }
        if let capitol = geometry.capitol {
            if clues[capitol] > 0 { return false }
            // An internal route to this capitol is an upper bound on the global
            // shortest route. Reject only when that upper bound is too short.
            if cells.contains(where: { clues[$0] > 0 }) {
                let occupied = Set(cells)
                var distances = [capitol: 0], queue = [capitol], next = 0
                while next < queue.count {
                    let cell = queue[next]; next += 1
                    let steps = distances[cell]!
                    let bound = steps.multipliedReportingOverflow(by: cells.count)
                    if !bound.overflow && clues[cell] > bound.partialValue { return false }
                    for neighbor in grid.neighbors(cell) where occupied.contains(neighbor) && distances[neighbor] == nil {
                        distances[neighbor] = steps + 1; queue.append(neighbor)
                    }
                }
            }
        }
        return true
    }
}

extension SearchContext {
    func canonical(_ board: Board) -> [Int] {
        var ids: [UUID: Int] = [:]
        return board.Relationships.ColorBlocks.flatMap { $0 }.map {
            if ids[$0] == nil { ids[$0] = ids.count }
            return ids[$0]!
        }
    }

    func groups(_ labels: [Int]) -> [[Int]] {
        var groups: [Int: [Int]] = [:]
        for cell in labels.indices { groups[labels[cell], default: []].append(cell) }
        return groups.values.sorted { $0[0] < $1[0] }
    }

    func board(labels: [Int]) -> Board {
        precondition(labels.count == grid.count)
        let board = Board(rowNum: grid.rows, colNum: grid.cols)
        var ids: [Int: UUID] = [:]
        for cell in labels.indices {
            if ids[labels[cell]] == nil { ids[labels[cell]] = UUID() }
            board.Relationships.ColorBlocks[cell / grid.cols][cell % grid.cols] = ids[labels[cell]]!
        }
        encodePartition(board)
        return board
    }

    /// Cached scoring uses integer labels; display Boards are built lazily.
    func evaluate(_ board: Board) -> SearchState { evaluate(labels: canonical(board)) }

    func evaluate(labels input: [Int]) -> SearchState {
        let started = ProcessInfo.processInfo.systemUptime
        defer { metrics.evaluationSeconds += ProcessInfo.processInfo.systemUptime - started }
        let labels = normalized(input)
        if let cached = evaluations[labels] {
            metrics.evaluationCacheHits += 1
            return cached.snapshot()
        }
        let groups = groups(labels)
        var sizes = Array(repeating: 0, count: grid.count)
        var invalid = Array(repeating: 0.0, count: grid.count)
        var issues: [String] = [], capitols: [GridCell] = []
        let geometryStart = ProcessInfo.processInfo.systemUptime
        for (index, cells) in groups.enumerated() {
            let info = regions.geometry(cells)
            for cell in cells { sizes[cell] = cells.count }
            if !info.connected || !info.symmetric {
                issues.append("State \(index) is disconnected or asymmetric.")
                for cell in cells { invalid[cell] = 1 }
            }
            if let cell = info.capitol { capitols.append(GridCell(row: cell / grid.cols, col: cell % grid.cols)) }
        }
        metrics.geometrySeconds += ProcessInfo.processInfo.systemUptime - geometryStart
        let distanceStart = ProcessInfo.processInfo.systemUptime
        let (distance, parent) = shortestPaths(sizes: sizes,
            capitols: capitols.map { $0.row * grid.cols + $0.col }, heap: grid.count >= 64)
        metrics.distanceSeconds += ProcessInfo.processInfo.systemUptime - distanceStart
        var errors = Array(repeating: 0.0, count: grid.count)
        var mismatches: [ClueMismatch] = []
        for cell in constraints.clues.indices where constraints.clues[cell] >= 0 {
            let expected = constraints.clues[cell]
            let actual = distance[cell] == Int.max ? nil : distance[cell]
            errors[cell] = actual.map { abs(Double($0) - Double(expected)) / max(Double($0), Double(expected), 1) } ?? 1
            if actual != expected {
                mismatches.append(ClueMismatch(cell: GridCell(row: cell / grid.cols, col: cell % grid.cols),
                                               expected: expected, actual: actual))
            }
        }
        let mean = errors.reduce(0, +) / Double(max(1, clueCount))
        for cell in errors.indices where constraints.clues[cell] < 0 { errors[cell] = mean }
        let factors = config.factors
        let scale = max(factors.realAIM, factors.symmetry, factors.discreteness)
        let sum = factors.realAIM / scale + factors.symmetry / scale + factors.discreteness / scale
        let aimWeight = (factors.realAIM / scale) / sum, symWeight = (factors.symmetry / scale) / sum
        // Scalar search scores; the full display matrix is deferred.
        let scores = Energy.Scores(realAIM: mean, symmetry: invalid.reduce(0, +) / Double(grid.count),
                                   discreteness: 0, total: aimWeight * mean + symWeight * invalid.reduce(0, +) / Double(grid.count))
        let rows = grid.rows, cols = grid.cols
        let displayErrors = errors, displayInvalid = invalid
        let displayCapitols = capitols
        let makeBoard = {
            let board = Board(rowNum: rows, colNum: cols)
            let ids = groups.map { _ in UUID() }
            for cell in labels.indices {
                let r = cell / cols, c = cell % cols
                board.Relationships.ColorBlocks[r][c] = ids[labels[cell]]
                board.Energy[r][c] = aimWeight * displayErrors[cell] + symWeight * displayInvalid[cell]
                if c + 1 < cols { board.Relationships.VerticalRelationships[r][c] = labels[cell] == labels[cell + 1] ? 1 : 0 }
                if r + 1 < rows { board.Relationships.HorizontalRelationships[r][c] = labels[cell] == labels[cell + cols] ? 1 : 0 }
            }
            for p in displayCapitols { board.Relationships.Capitals[p.row][p.col] = true }
            board.Relationships.BlocksContained.ids = ids
            board.Relationships.BlocksContained.blockCounts = groups.map(\.count)
            return board
        }
        var report = ValidationReport(valid: false, issues: issues, capitols: capitols, mismatches: mismatches, answer: nil)
        if issues.isEmpty && mismatches.isEmpty { report = validator.validate(makeBoard(), target: config.Target) }
        metrics.evaluations += 1
        let state = SearchState(labels: labels, scores: scores, validation: report, parents: parent, makeBoard: makeBoard)
        evaluations[labels] = state.snapshot()
        return state
    }

    func normalized(_ values: [Int]) -> [Int] {
        var ids: [Int: Int] = [:]
        return values.map { v in
            if ids[v] == nil { ids[v] = ids.count }; return ids[v]!
        }
    }

    /// Both implementations are retained for differential tests and small-grid timing.
    func shortestPaths(sizes: [Int], capitols: [Int], heap: Bool) -> ([Int], [Int?]) {
        var distance = Array(repeating: Int.max, count: grid.count)
        var parents = Array<Int?>(repeating: nil, count: grid.count)
        for cell in capitols { distance[cell] = 0 }
        if heap {
            var queue = DistanceHeap()
            for cell in capitols { queue.push(cost: 0, cell: cell) }
            while let item = queue.pop() {
                if item.cost != distance[item.cell] { continue }
                for neighbor in grid.neighbors(item.cell) {
                    let sum = item.cost.addingReportingOverflow(min(sizes[item.cell], sizes[neighbor]))
                    if !sum.overflow && sum.partialValue < distance[neighbor] {
                        distance[neighbor] = sum.partialValue; parents[neighbor] = item.cell
                        queue.push(cost: sum.partialValue, cell: neighbor)
                    }
                }
            }
        } else {
            var visited = Array(repeating: false, count: grid.count)
            for _ in 0..<grid.count {
                var next: Int?
                for cell in distance.indices where !visited[cell] && distance[cell] != Int.max {
                    if next == nil || distance[cell] < distance[next!] { next = cell }
                }
                guard let cell = next else { break }
                visited[cell] = true
                for neighbor in grid.neighbors(cell) {
                    let sum = distance[cell].addingReportingOverflow(min(sizes[cell], sizes[neighbor]))
                    if !sum.overflow && sum.partialValue < distance[neighbor] {
                        distance[neighbor] = sum.partialValue; parents[neighbor] = cell
                    }
                }
            }
        }
        return (distance, parents)
    }
}

private struct DistanceHeap {
    struct Item {
        let cost: Int
        let cell: Int
        func before(_ other: Item) -> Bool { cost == other.cost ? cell < other.cell : cost < other.cost }
    }
    var items: [Item] = []
    mutating func push(cost: Int, cell: Int) {
        items.append(Item(cost: cost, cell: cell))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if !items[i].before(items[parent]) { break }
            items.swapAt(i, parent); i = parent
        }
    }
    mutating func pop() -> Item? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 { return items.removeLast() }
        let first = items[0]; items[0] = items.removeLast()
        var i = 0
        while 2 * i + 1 < items.count {
            var child = 2 * i + 1
            if child + 1 < items.count && items[child + 1].before(items[child]) { child += 1 }
            if !items[child].before(items[i]) { break }
            items.swapAt(child, i); i = child
        }
        return first
    }
}
