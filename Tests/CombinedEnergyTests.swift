import Foundation

// swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
//   JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
//   Tests/CombinedEnergyTests.swift -o /tmp/combined-energy-tests && /tmp/combined-energy-tests
@main
struct CombinedEnergyTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func close(_ actual: [[Double]], _ expected: [[Double]], _ message: String) {
        check(actual.count == expected.count, "\(message): wrong row count")
        for r in expected.indices {
            check(actual[r].count == expected[r].count, "\(message): wrong column count")
            for c in expected[r].indices {
                check(actual[r][c].isFinite && abs(actual[r][c] - expected[r][c]) < 1e-12,
                      "\(message) at \(r),\(c): \(actual[r][c]) != \(expected[r][c])")
            }
        }
    }

    static func main() {
        let calculator = Energy()
        let rectangle = Board(rowNum: 2, colNum: 3)
        rectangle.Relationships.VerticalRelationships = [[0, 0.5], [0.5, 1]]
        rectangle.Relationships.HorizontalRelationships = [[0.5, 0, 0.5]]
        close(calculator.DiscretenessTest(Board: rectangle), [[0.5, 1.0 / 3, 1], [1, 1.0 / 3, 0.5]],
              "Incident edges must be averaged using actual neighbor counts")

        let quarter = tan(0.5) / tan(1.0)
        let row = Board(rowNum: 1, colNum: 3)
        row.Relationships.VerticalRelationships = [[0.25, 0.75]]
        close(calculator.DiscretenessTest(Board: row), [[quarter, quarter, quarter]],
              "Complementary strengths must give equal uncertainty")
        let column = Board(rowNum: 3, colNum: 1)
        column.Relationships.HorizontalRelationships = [[0.25], [0.75]]
        close(calculator.DiscretenessTest(Board: column), [[quarter], [quarter], [quarter]],
              "Single-column board")
        close(calculator.DiscretenessTest(Board: Board(rowNum: 1, colNum: 1)), [[0]],
              "No incident edges means zero uncertainty")
        for (rows, cols) in [(1, 4), (4, 1), (2, 5), (5, 2)] {
            let board = Board(rowNum: rows, colNum: cols)
            close(calculator.DiscretenessTest(Board: board),
                  Array(repeating: Array(repeating: 1, count: cols), count: rows),
                  "All strengths 0.5 must give maximum cell uncertainty")
        }

        // Two asymmetric shapes ensure all three component matrices contribute.
        let board = Board(rowNum: 3, colNum: 3)
        let a = UUID()
        let b = UUID()
        board.Relationships.ColorBlocks = [[a, a, b], [a, b, b], [a, b, b]]
        board.Relationships.VerticalRelationships = [[0, 0.5], [0.25, 0.75], [1, 0.25]]
        board.Relationships.HorizontalRelationships = [[0.5, 0, 1], [0.75, 0.25, 0.5]]
        let target = OriginalCondition(Status: [[0, -1, 9], [-1, 3, -1], [7, -1, 0]])
        let originalBlocks = board.Relationships.ColorBlocks
        let originalVertical = board.Relationships.VerticalRelationships
        let originalHorizontal = board.Relationships.HorizontalRelationships
        let originalEnergy = board.Energy
        let originalCapitals = board.Relationships.Capitals
        let aim = calculator.RealAIMTest(Board: board, Target: target)
        let symmetry = calculator.SymmetricalTest(Board: board)
        let discreteness = calculator.DiscretenessTest(Board: board)
        check(symmetry.joined().contains { $0 > 0 }, "Fixture needs positive symmetry energy")
        close(calculator.EnergyCal(Board: board, Target: target,
                                  Factors: .init(realAIM: 1, symmetry: 0, discreteness: 0)), aim,
              "AIM-only factor")
        close(calculator.EnergyCal(Board: board, Target: target,
                                  Factors: .init(realAIM: 0, symmetry: 1, discreteness: 0)), symmetry,
              "Symmetry-only factor")
        close(calculator.EnergyCal(Board: board, Target: target,
                                  Factors: .init(realAIM: 0, symmetry: 0, discreteness: 1)), discreteness,
              "Discreteness-only factor")
        let combined = calculator.EnergyCal(Board: board, Target: target,
                                           Factors: .init(realAIM: 2, symmetry: 3, discreteness: 5))
        var expected = originalEnergy
        var equal = originalEnergy
        for r in 0..<3 {
            for c in 0..<3 {
                expected[r][c] = (2 * aim[r][c] + 3 * symmetry[r][c] + 5 * discreteness[r][c]) / 10
                equal[r][c] = (aim[r][c] + symmetry[r][c] + discreteness[r][c]) / 3
                check(combined[r][c] >= 0 && combined[r][c] <= 1, "Combined energy out of range")
            }
        }
        close(combined, expected, "Weighted combination")
        close(calculator.EnergyCal(Board: board, Target: target), equal, "Equal default factors")
        close(calculator.EnergyCal(Board: board, Target: target,
                                  Factors: .init(realAIM: 20, symmetry: 30, discreteness: 50)), combined,
              "Only relative factor sizes should matter")
        let huge = Double.greatestFiniteMagnitude
        close(calculator.EnergyCal(Board: board, Target: target,
                                  Factors: .init(realAIM: huge, symmetry: huge, discreteness: huge)), equal,
              "Large finite factors must not overflow")
        check(board.Relationships.ColorBlocks == originalBlocks
              && board.Relationships.VerticalRelationships == originalVertical
              && board.Relationships.HorizontalRelationships == originalHorizontal
              && board.Relationships.Capitals == originalCapitals && board.Energy == originalEnergy,
              "Energy calculation must not mutate the board")

        let singleton = Board(rowNum: 1, colNum: 1)
        close(calculator.EnergyCal(Board: singleton, Target: OriginalCondition(Status: [[0]])), [[0]],
              "Perfect single-cell board must have zero combined energy")
        print("Passed: per-cell edge averaging, normalized tan scores, rectangular and thin boards, factor isolation/scaling, bounded combined scores, and board immutability.")
    }
}
