import Foundation

struct GridCell: Hashable, Codable, Sendable {
    let row: Int
    let col: Int
}

struct ClueMismatch: Codable, Sendable {
    let cell: GridCell
    let expected: Int
    let actual: Int?
}

struct PuzzleAnswer: Codable, Sendable {
    let cellSizes: [[Int]]
    let rowSums: [Int]
    let sumOfSquares: Int

    /// Arithmetic only; computing a candidate's score does not validate it.
    static func calculate(cellSizes: [[Int]]) -> PuzzleAnswer? {
        var rowSums: [Int] = []
        var sumOfSquares = 0
        for row in cellSizes {
            var sum = 0
            for value in row {
                let added = sum.addingReportingOverflow(value)
                guard !added.overflow else { return nil }
                sum = added.partialValue
            }
            rowSums.append(sum)
            let square = sum.multipliedReportingOverflow(by: sum)
            guard !square.overflow else { return nil }
            let added = sumOfSquares.addingReportingOverflow(square.partialValue)
            guard !added.overflow else { return nil }
            sumOfSquares = added.partialValue
        }
        return PuzzleAnswer(cellSizes: cellSizes, rowSums: rowSums, sumOfSquares: sumOfSquares)
    }
}

struct ValidationReport: Codable, Sendable {
    let valid: Bool
    let issues: [String]
    let capitols: [GridCell]
    let mismatches: [ClueMismatch]
    let answer: PuzzleAnswer?
}

/// Independent, integer-only puzzle checks. Does not use tentative fields or
/// energy thresholds to declare a solution.
struct ExactValidator {
    func validate(_ board: Board, target: OriginalCondition) -> ValidationReport {
        let rows = board.BoardBasics.rowNum
        let cols = board.BoardBasics.colNum
        let grid = Grid(rows: rows, cols: cols)
        precondition(target.Status.count == rows && target.Status.allSatisfy { $0.count == cols })
        let labels = board.Relationships.ColorBlocks.flatMap { $0 }
        var groups: [[Int]] = []
        var groupIndex: [UUID: Int] = [:]
        for cell in labels.indices {
            if groupIndex[labels[cell]] == nil {
                groupIndex[labels[cell]] = groups.count
                groups.append([])
            }
            groups[groupIndex[labels[cell]]!].append(cell)
        }
        var sizes = Array(repeating: 0, count: grid.count)
        var issues: [String] = []
        var capitols: [GridCell] = []
        for (index, cells) in groups.enumerated() {
            for cell in cells { sizes[cell] = cells.count }
            guard grid.connected(cells) else {
                issues.append("State \(index) is disconnected.")
                continue
            }
            let top = cells.map { $0 / cols }.min()!
            let left = cells.map { $0 % cols }.min()!
            let height = cells.map { $0 / cols }.max()! - top + 1
            let width = cells.map { $0 % cols }.max()! - left + 1
            let shape = cells.map { GridCell(row: $0 / cols - top, col: $0 % cols - left) }
            let occupied = Set(shape)
            var fixedSets: [[GridCell]] = []
            for transform in 0..<7 {
                let mapped = shape.map { p -> GridCell in
                    switch transform {
                    case 0: return GridCell(row: p.col, col: height - 1 - p.row)
                    case 1: return GridCell(row: height - 1 - p.row, col: width - 1 - p.col)
                    case 2: return GridCell(row: width - 1 - p.col, col: p.row)
                    case 3: return GridCell(row: p.row, col: width - 1 - p.col)
                    case 4: return GridCell(row: height - 1 - p.row, col: p.col)
                    case 5: return GridCell(row: p.col, col: p.row)
                    default: return GridCell(row: width - 1 - p.col, col: height - 1 - p.row)
                    }
                }
                if Set(mapped) == occupied {
                    fixedSets.append(zip(shape, mapped).compactMap { $0 == $1 ? $0 : nil })
                }
            }
            guard let first = fixedSets.first else {
                issues.append("State \(index) has no nonidentity symmetry.")
                continue
            }
            if first.count == 1 && fixedSets.allSatisfy({ $0.count == 1 && $0[0] == first[0] }) {
                capitols.append(GridCell(row: first[0].row + top, col: first[0].col + left))
            }
        }
        var distance = Array(repeating: Int.max, count: grid.count)
        var visited = Array(repeating: false, count: grid.count)
        for capitol in capitols { distance[capitol.row * cols + capitol.col] = 0 }
        for _ in 0..<grid.count {
            var current: Int?
            for cell in distance.indices where !visited[cell] && distance[cell] != Int.max {
                if current == nil || distance[cell] < distance[current!] { current = cell }
            }
            guard let cell = current else { break }
            visited[cell] = true
            for neighbor in grid.neighbors(cell) {
                let cost = distance[cell].addingReportingOverflow(min(sizes[cell], sizes[neighbor]))
                if !cost.overflow { distance[neighbor] = min(distance[neighbor], cost.partialValue) }
            }
        }
        var mismatches: [ClueMismatch] = []
        var clueCount = 0
        for row in 0..<rows {
            for col in 0..<cols where target.Status[row][col] >= 0 {
                clueCount += 1
                let actual = distance[row * cols + col] == Int.max ? nil : distance[row * cols + col]
                if actual != target.Status[row][col] {
                    mismatches.append(ClueMismatch(cell: GridCell(row: row, col: col),
                                                   expected: target.Status[row][col], actual: actual))
                }
            }
        }
        if clueCount == 0 { issues.append("There are no clues to validate.") }
        var answer: PuzzleAnswer?
        if issues.isEmpty && mismatches.isEmpty {
            let cellSizes = (0..<rows).map { row in
                Array(sizes[(row * cols)..<((row + 1) * cols)])
            }
            answer = PuzzleAnswer.calculate(cellSizes: cellSizes)
            if answer == nil { issues.append("The answer exceeds Int capacity.") }
        }
        return ValidationReport(valid: answer != nil, issues: issues, capitols: capitols,
                                mismatches: mismatches, answer: answer)
    }
}
