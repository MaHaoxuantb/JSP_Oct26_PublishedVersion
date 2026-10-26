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
    
    // 1. Real AIM
    /// Use the cost to get to the closest MC
    func RealAIMTest(Board: Board) -> [[Float64]] {
        return [[]]
        
        // Get the weighted location of the capitols
        func CapitolCal(Board: Board) -> [[(Float64, Float64)]] {
            return [[]]
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
        func normalizedShape(_ cells: [ShapeCell]) -> [ShapeCell] {
            let minRow = cells.map(\.row).min()!
            let minCol = cells.map(\.col).min()!
            return cells.map { ShapeCell(row: $0.row - minRow, col: $0.col - minCol) }.sorted()
        }

        // Keep all eight entries, even when equal: a nonidentity transformation
        // mapping the shape to itself is precisely the symmetry we are looking for.
        func shapeOrientations(_ cells: [ShapeCell]) -> [[ShapeCell]] {
            (0..<8).map { transform in
                normalizedShape(cells.map { cell in
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
                })
            }
        }

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
