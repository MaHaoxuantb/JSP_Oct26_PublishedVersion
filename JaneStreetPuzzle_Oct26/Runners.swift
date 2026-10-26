import Foundation

final class Runners {
    /// Rebuild connected components of the >= 0.5 relationship graph in one
    /// flood fill. Metadata is regenerated in deterministic row-major order.
    @discardableResult
    func IntoColorBlocks(Board: Board) -> Board {
        let rows = Board.BoardBasics.rowNum
        let cols = Board.BoardBasics.colNum
        let vertical = Board.Relationships.VerticalRelationships
        let horizontal = Board.Relationships.HorizontalRelationships
        precondition(vertical.count == rows && vertical.allSatisfy { $0.count == cols - 1 })
        precondition(horizontal.count == rows - 1 && horizontal.allSatisfy { $0.count == cols })
        precondition(vertical.joined().allSatisfy { $0.isFinite && (0...1).contains($0) }
                     && horizontal.joined().allSatisfy { $0.isFinite && (0...1).contains($0) })
        var visited = Array(repeating: false, count: rows * cols)
        var ids: [UUID] = []
        var counts: [Int] = []
        for start in visited.indices where !visited[start] {
            let id = UUID()
            var queue = [start]
            visited[start] = true
            var next = 0
            while next < queue.count {
                let cell = queue[next]
                next += 1
                let row = cell / cols
                let col = cell % cols
                Board.Relationships.ColorBlocks[row][col] = id
                var neighbors: [Int] = []
                if row > 0 && horizontal[row - 1][col] >= 0.5 { neighbors.append(cell - cols) }
                if col + 1 < cols && vertical[row][col] >= 0.5 { neighbors.append(cell + 1) }
                if row + 1 < rows && horizontal[row][col] >= 0.5 { neighbors.append(cell + cols) }
                if col > 0 && vertical[row][col - 1] >= 0.5 { neighbors.append(cell - 1) }
                for neighbor in neighbors where !visited[neighbor] {
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
            ids.append(id)
            counts.append(queue.count)
        }
        Board.Relationships.BlocksContained.ids = ids
        Board.Relationships.BlocksContained.blockCounts = counts
        Board.Relationships.Capitals = Array(repeating: Array(repeating: false, count: cols), count: rows)
        return Board
    }
}
