import Foundation

// Run from the repository root:
// swiftc JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
//   Tests/SymmetryEnergyTests.swift -o /tmp/symmetry-energy-tests
// /tmp/symmetry-energy-tests
@main
struct SymmetryEnergyTests {
    struct Cell: Hashable {
        let r: Int
        let c: Int
    }

    static func board(rows: Int, cols: Int, shape: [Cell]) -> Board {
        let board = Board(rowNum: rows, colNum: cols)
        for r in 0..<rows {
            for c in 0..<cols {
                board.Relationships.ColorBlocks[r][c] = UUID()
            }
        }
        let id = UUID()
        for cell in shape { board.Relationships.ColorBlocks[cell.r][cell.c] = id }
        return board
    }

    // Independent set-based reference, using bounding-box formulas rather than
    // normalized signed coordinates or the implementation's bitmask operations.
    static func reference(_ cells: [Cell]) -> Double {
        let shape = Set(cells)
        var reached: Set<Cell> = [cells[0]]
        var previousCount = 0
        while reached.count != previousCount {
            previousCount = reached.count
            for cell in Array(reached) {
                for neighbor in [Cell(r: cell.r - 1, c: cell.c), Cell(r: cell.r + 1, c: cell.c),
                                 Cell(r: cell.r, c: cell.c - 1), Cell(r: cell.r, c: cell.c + 1)] {
                    if shape.contains(neighbor) { reached.insert(neighbor) }
                }
            }
        }
        if reached.count != cells.count { return 1 }

        let top = cells.map(\.r).min()!
        let left = cells.map(\.c).min()!
        let height = cells.map(\.r).max()! - top + 1
        let width = cells.map(\.c).max()! - left + 1
        let normalized = Set(cells.map { Cell(r: $0.r - top, c: $0.c - left) })
        let transforms: [(Cell) -> Cell] = [
            { Cell(r: $0.c, c: height - 1 - $0.r) },
            { Cell(r: height - 1 - $0.r, c: width - 1 - $0.c) },
            { Cell(r: width - 1 - $0.c, c: $0.r) },
            { Cell(r: $0.r, c: width - 1 - $0.c) },
            { Cell(r: height - 1 - $0.r, c: $0.c) },
            { Cell(r: $0.c, c: $0.r) },
            { Cell(r: width - 1 - $0.c, c: height - 1 - $0.r) }
        ]
        let overlap = transforms.map { transform in
            normalized.intersection(Set(normalized.map(transform))).count
        }.max()!
        return Double(cells.count - overlap) / Double(cells.count)
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        let energy = Energy()

        // All 511 nonempty subsets include reflection-only, rotation-only,
        // asymmetric and disconnected examples, as well as equivalent shapes
        // that exercise canonical-cache reuse across orientations.
        for bits in 1..<512 {
            let cells = (0..<9).filter { bits & (1 << $0) != 0 }
                .map { Cell(r: $0 / 3 + 1, c: $0 % 3 + 2) }
            let board = board(rows: 5, cols: 6, shape: cells)
            let originalBlocks = board.Relationships.ColorBlocks
            let originalCapitals = board.Relationships.Capitals
            let result = energy.SymmetricalTest(Board: board)
            let expected = reference(cells)
            check(result.count == 5 && result.allSatisfy { $0.count == 6 }, "Wrong matrix size")
            let shape = Set(cells)
            for r in 0..<5 {
                for c in 0..<6 {
                    let value = shape.contains(Cell(r: r, c: c)) ? expected : 0
                    check(abs(result[r][c] - value) < 1e-12, "Mismatch for subset \(bits) at \(r),\(c)")
                }
            }
            check(board.Relationships.ColorBlocks == originalBlocks, "Changed ColorBlocks")
            check(board.Relationships.Capitals == originalCapitals, "Changed Capitals")
        }

        let fPentomino = [Cell(r: 0, c: 1), Cell(r: 0, c: 2), Cell(r: 1, c: 0),
                         Cell(r: 1, c: 1), Cell(r: 2, c: 1)]
        let fBoard = board(rows: 3, cols: 3, shape: fPentomino)
        let fScore = energy.SymmetricalTest(Board: fBoard)[0][1]
        check(fScore > 0 && fScore < 1, "Asymmetric shape needs a fractional penalty")

        let xPentomino = [Cell(r: 0, c: 1), Cell(r: 1, c: 0), Cell(r: 1, c: 1),
                         Cell(r: 1, c: 2), Cell(r: 2, c: 1)]
        check(energy.SymmetricalTest(Board: board(rows: 3, cols: 3, shape: xPentomino))[1][1] == 0,
              "A symmetric state does not need a capital")

        // Exercise bits on both sides of the 64-bit boundary with an asymmetric
        // connected state spanning an 11 x 11 bounding box.
        let large = (0..<11).map { Cell(r: $0, c: 0) }
            + (1..<11).map { Cell(r: 10, c: $0) } + [Cell(r: 9, c: 1)]
        let largeBoard = board(rows: 11, cols: 11, shape: large)
        check(abs(energy.SymmetricalTest(Board: largeBoard)[10][10] - reference(large)) < 1e-12,
              "Multiword bitmask mismatch")
        let fullBoard = Board(rowNum: 11, colNum: 11)
        check(energy.SymmetricalTest(Board: fullBoard).flatMap { $0 }.allSatisfy { $0 == 0 },
              "The full square should be symmetric")

        for (rows, cols) in [(1, 1), (1, 7), (7, 1), (2, 7)] {
            check(energy.SymmetricalTest(Board: Board(rowNum: rows, colNum: cols))
                .flatMap { $0 }.allSatisfy { $0 == 0 }, "Rectangle should be symmetric")
        }
        print("Passed: 511 exhaustive shape cases, fractional energies, capitals, multiword masks, and rectangular boards.")
    }
}
