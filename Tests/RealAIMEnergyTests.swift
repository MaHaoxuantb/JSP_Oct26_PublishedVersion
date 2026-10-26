import Foundation

// swiftc -module-cache-path /tmp/janestreet-swift-module-cache \
//   JaneStreetPuzzle_Oct26/Storage.swift JaneStreetPuzzle_Oct26/Energy.swift \
//   Tests/RealAIMEnergyTests.swift -o /tmp/real-aim-tests && /tmp/real-aim-tests
@main
struct RealAIMEnergyTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func close(_ actual: Double, _ expected: Double, _ message: String) {
        check(actual.isFinite && abs(actual - expected) < 1e-11, "\(message): \(actual) != \(expected)")
    }

    static func board(_ labels: [String]) -> Board {
        let board = Board(rowNum: labels.count, colNum: labels[0].count)
        var ids: [Character: UUID] = [:]
        for (r, row) in labels.enumerated() {
            for (c, label) in row.enumerated() {
                if ids[label] == nil { ids[label] = UUID() }
                board.Relationships.ColorBlocks[r][c] = ids[label]!
            }
        }
        return board
    }

    // Independent reference: Floyd-Warshall travel distances and explicit
    // Cartesian enumeration of all combinations of candidate capitol locations.
    static func reference(_ board: Board, _ fields: [UUID: Energy.CapitolField],
                          source: Int, target: Double) -> Double {
        let rows = board.BoardBasics.rowNum
        let cols = board.BoardBasics.colNum
        let blocks = board.Relationships.ColorBlocks.flatMap { $0 }
        var counts: [UUID: Int] = [:]
        for id in blocks { counts[id, default: 0] += 1 }
        let n = blocks.count
        var distances = Array(repeating: Array(repeating: Double.infinity, count: n), count: n)
        for i in 0..<n {
            distances[i][i] = 0
            for j in 0..<n where abs(i / cols - j / cols) + abs(i % cols - j % cols) == 1 {
                distances[i][j] = Double(min(counts[blocks[i]]!, counts[blocks[j]]!))
            }
        }
        for k in 0..<n {
            for i in 0..<n {
                for j in 0..<n { distances[i][j] = min(distances[i][j], distances[i][k] + distances[k][j]) }
            }
        }
        var combinations: [(cost: Double, probability: Double)] = [(.infinity, 1)]
        for (id, field) in fields where field.canBeDestination {
            var updated: [(cost: Double, probability: Double)] = []
            for sample in field.candidates where sample.probability > 0 {
                // The test locates ownership geometrically instead of depending
                // on the implementation's zip between cells and field entries.
                let r = Int(sample.row.rounded())
                let c = Int(sample.col.rounded())
                check(r >= 0 && r < rows && c >= 0 && c < cols && blocks[r * cols + c] == id,
                      "Candidate left its block")
                let terminal = Double(counts[id]!) * (abs(sample.row - Double(r)) + abs(sample.col - Double(c)))
                let cost = distances[source][r * cols + c] + terminal
                for combination in combinations {
                    updated.append((min(cost, combination.cost), sample.probability * combination.probability))
                }
            }
            combinations = updated
        }
        return combinations.reduce(0) {
            $0 + $1.probability * ($1.cost.isFinite ? abs($1.cost - target) / max($1.cost, target, 1) : 1)
        }
    }

    static func main() {
        let energy = Energy()
        let example = board(["ABBCC", "ABBDC", "AADDC", "CAAAC", "CCCCC"])
        let target = OriginalCondition(Status: [
            [12, -1, -1, -1, 17], [8, -1, 6, 3, -1], [-1, -1, -1, -1, -1],
            [-1, 7, 6, -1, 10], [25, -1, -1, -1, 0]
        ])
        let originalBlocks = example.Relationships.ColorBlocks
        let originalCapitals = example.Relationships.Capitals
        let fields = energy.CapitolCal(Board: example)
        check(fields.values.filter(\.isExactCapitol).count == 3, "Example needs three capitols")
        let exactPositions = fields.values.flatMap { $0.isExactCapitol ? $0.candidates.filter { $0.probability == 1 } : [] }
        for (r, c) in [(2.0, 1.0), (2.0, 3.0), (4.0, 4.0)] {
            check(exactPositions.contains { $0.row == r && $0.col == c }, "Wrong example capitol")
        }
        let solved = energy.RealAIMTest(Board: example, Target: target)
        for value in solved.joined() { close(value, 0, "Solved example energy") }
        check(example.Relationships.ColorBlocks == originalBlocks && example.Relationships.Capitals == originalCapitals,
              "Energy calculation mutated the board")

        var wrong = target
        wrong.Status[0][0] = 10
        let wrongScores = energy.RealAIMTest(Board: example, Target: wrong)
        close(wrongScores[0][0], 2.0 / 12, "Normalized clue error")
        close(wrongScores[2][2], (2.0 / 12) / 10, "Blank must use global mean of ten clue energies")
        close(wrongScores[4][4], 0, "Zero is a clue, not a blank")

        // Every block retains unit probability, including disconnected and
        // symmetric blocks without capitols. Exercise all nonempty 3x3 subsets.
        for bits in 1..<512 {
            let b = Board(rowNum: 3, colNum: 3)
            let id = UUID()
            for r in 0..<3 {
                for c in 0..<3 {
                    b.Relationships.ColorBlocks[r][c] = bits & (1 << (r * 3 + c)) != 0 ? id : UUID()
                }
            }
            let originalFields = energy.CapitolCal(Board: b)
            for (block, field) in originalFields {
                close(field.candidates.reduce(0) { $0 + $1.probability }, 1, "Field normalization for subset \(bits)")
                for sample in field.candidates {
                    check(sample.probability.isFinite && sample.probability >= 0 && sample.probability <= 1,
                          "Invalid probability")
                    let r = Int(sample.row.rounded())
                    let c = Int(sample.col.rounded())
                    check(b.Relationships.ColorBlocks[r][c] == block, "Field support left its block")
                }
            }
            // A change of board orientation must rotate/reflect the field,
            // including its fractional positions, without changing probabilities.
            for reflect in [false, true] {
                let changed = Board(rowNum: 3, colNum: 3)
                for r in 0..<3 {
                    for c in 0..<3 {
                        changed.Relationships.ColorBlocks[reflect ? r : c][reflect ? 2 - c : 2 - r]
                            = b.Relationships.ColorBlocks[r][c]
                    }
                }
                let changedFields = energy.CapitolCal(Board: changed)
                for (block, field) in originalFields {
                    let transformed = changedFields[block]!
                    check(transformed.canBeDestination == field.canBeDestination
                          && transformed.isExactCapitol == field.isExactCapitol, "Orientation changed eligibility")
                    for sample in field.candidates {
                        let row = reflect ? sample.row : sample.col
                        let col = reflect ? 2 - sample.col : 2 - sample.row
                        let match = transformed.candidates.first {
                            $0.row.rounded() == row.rounded() && $0.col.rounded() == col.rounded()
                        }!
                        close(match.row, row, "Orientation changed row")
                        close(match.col, col, "Orientation changed column")
                        close(match.probability, sample.probability, "Orientation changed probability")
                    }
                }
            }
        }
        for labels in [["AAA"], ["AA", "AA"], ["BAB", "AAA", "BAB"], ["ABA"]] {
            let b = board(labels)
            let field = energy.CapitolCal(Board: b)[b.Relationships.ColorBlocks[labels.count == 3 ? 1 : 0][0]]!
            check(!field.canBeDestination && !field.isExactCapitol, "Block has no valid capitol")
        }
        let noCapitol = board(["AAA"])
        let noCapitolScore = energy.RealAIMTest(Board: noCapitol, Target: OriginalCondition(Status: [[0, -1, 3]]))
        check(noCapitolScore.joined().allSatisfy { $0 == 1 }, "No destination means maximum energy")
        let singleton = board(["A"])
        close(energy.RealAIMTest(Board: singleton, Target: OriginalCondition(Status: [[0]]))[0][0], 0,
              "Singleton capitol")
        close(energy.RealAIMTest(Board: singleton, Target: OriginalCondition(Status: [[-1]]))[0][0], 1,
              "No clues must not imply solved")

        // Both blocks are asymmetric and have tentative fields. Compare the
        // nearest-capitol expectation against all 4*5 candidate combinations.
        let tentative = board(["AAB", "ABB", "ABB"])
        let tentativeFields = energy.CapitolCal(Board: tentative)
        check(tentativeFields.values.allSatisfy { $0.canBeDestination && !$0.isExactCapitol },
              "Expected two tentative capitol fields")
        check(tentativeFields.values.contains { $0.candidates.contains { abs($0.row.rounded() - $0.row) > 1e-6 } },
              "Tentative positions should allow fractional coordinates")
        for clue in [0, 1, 3, 8, 30] {
            let result = energy.RealAIMTest(Board: tentative,
                Target: OriginalCondition(Status: Array(repeating: Array(repeating: clue, count: 3), count: 3)))
            for r in 0..<3 {
                for c in 0..<3 {
                    close(result[r][c], reference(tentative, tentativeFields, source: r * 3 + c, target: Double(clue)),
                          "Expected error differs from explicit enumeration")
                    check(result[r][c] >= 0 && result[r][c] <= 1, "Energy out of bounds")
                }
            }
        }
        print("Passed: exact example, 511 normalized fields with rotation/reflection invariance, absent capitols, blank averaging, fractional travel, and enumerated expectations.")
    }
}
