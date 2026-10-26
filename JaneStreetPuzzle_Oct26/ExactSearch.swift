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
    private var cache: [[Int]: RegionGeometry] = [:]
    init(grid: Grid) { self.grid = grid }

    func geometry(_ cells: [Int]) -> RegionGeometry {
        let cells = cells.sorted()
        if let value = cache[cells] { return value }
        guard !cells.isEmpty else { return RegionGeometry(connected: false, symmetric: false, capitol: nil) }
        let connected = grid.connected(cells)
        let top = cells.map { $0 / grid.cols }.min()!
        let bottom = cells.map { $0 / grid.cols }.max()!
        let left = cells.map { $0 % grid.cols }.min()!
        let right = cells.map { $0 % grid.cols }.max()!
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
        if cache.count >= 32_768 { cache.removeAll(keepingCapacity: true) }
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
    /// A zero must be the region's actual capitol; a positive clue cannot be one.
    func permits(_ cells: [Int], geometry: RegionGeometry) -> Bool {
        guard geometry.connected && geometry.symmetric else { return false }
        for cell in cells where clues[cell] == 0 {
            if geometry.capitol != cell { return false }
        }
        if let capitol = geometry.capitol, clues[capitol] > 0 { return false }
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

    /// One exact multi-source Dijkstra per partition, with cached region geometry.
    /// The continuous energy functions are intentionally not used here.
    func evaluate(_ board: Board) -> SearchState {
        let labels = canonical(board)
        let groups = groups(labels)
        var sizes = Array(repeating: 0, count: grid.count)
        var invalid = Array(repeating: 0.0, count: grid.count)
        var issues: [String] = [], capitols: [GridCell] = []
        for (index, cells) in groups.enumerated() {
            let info = regions.geometry(cells)
            for cell in cells { sizes[cell] = cells.count }
            if !info.connected || !info.symmetric {
                issues.append("State \(index) is disconnected or asymmetric.")
                for cell in cells { invalid[cell] = 1 }
            }
            if let cell = info.capitol { capitols.append(GridCell(row: cell / grid.cols, col: cell % grid.cols)) }
        }
        var distance = Array(repeating: Int.max, count: grid.count)
        var parent = Array<Int?>(repeating: nil, count: grid.count)
        var visited = Array(repeating: false, count: grid.count)
        for capitol in capitols { distance[capitol.row * grid.cols + capitol.col] = 0 }
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
                    distance[neighbor] = sum.partialValue
                    parent[neighbor] = cell
                }
            }
        }
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
        let combined = zip(errors, invalid).map { aimWeight * $0 + symWeight * $1 }
        let scores = Energy.Scores(realAIM: mean, symmetry: invalid.reduce(0, +) / Double(grid.count),
                                   discreteness: 0, total: combined.reduce(0, +) / Double(grid.count))
        encodePartition(board)
        board.Relationships.Capitals = Array(repeating: Array(repeating: false, count: grid.cols), count: grid.rows)
        for p in capitols { board.Relationships.Capitals[p.row][p.col] = true }
        board.Relationships.BlocksContained.ids = groups.map { board.Relationships.ColorBlocks[$0[0] / grid.cols][$0[0] % grid.cols] }
        board.Relationships.BlocksContained.blockCounts = groups.map(\.count)
        board.Energy = (0..<grid.rows).map { Array(combined[($0 * grid.cols)..<(($0 + 1) * grid.cols)]) }
        var report = ValidationReport(valid: false, issues: issues, capitols: capitols, mismatches: mismatches, answer: nil)
        if issues.isEmpty && mismatches.isEmpty {
            report = validator.validate(board, target: config.Target)
        }
        metrics.evaluations += 1
        return SearchState(board: board, scores: scores, validation: report, parents: parent)
    }
}
