import Foundation

/// Bounded diagnostics only. Does not run Main, write worker state, or connect.
@main
struct InspectPathways {
    static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
        let labels = (data["labels"] as! [[Int]]).flatMap { $0 }
        let expectedDistances = (data["distances"] as! [[Int]]).flatMap { $0 }
        let checks = data["clue_checks"] as! [[String: Any]]
        var config = RunConfig.fullPuzzle
        config.pathEvaluation = .cpu
        let context = SearchContext(config: config)
        precondition(checks.count == context.clueCount)
        for check in checks {
            let p = check["cell"] as! [Int]
            precondition(config.Target.Status[p[0]-1][p[1]-1] == check["expected"] as! Int)
        }
        let state = context.evaluate(labels: labels)
        let exact = ExactValidator().validate(state.board, target: config.Target)
        precondition(state.validation.valid && exact.valid)
        precondition(exact.answer?.sumOfSquares == 408951)
        let parts = context.groups(labels)
        precondition(parts.allSatisfy { context.permits($0) })
        let caps = exact.capitols.map { $0.row * 11 + $0.col }
        let sizes = labels.indices.map { parts[labels[$0]].count }
        let computed = context.shortestPaths(sizes: sizes, capitols: caps, heap: true).0
        precondition(computed == expectedDistances)
        print("Swift cached evaluator + ExactValidator: valid; 33 clues; 8 capitols; answer 408951")
        print("All 121 Swift distances equal independently computed Python distances.")
        print("Every solution region passes current permits/geometry constraints.")
        let initial = context.initialCatalog(until: .infinity)
        let missingInitial = parts.indices.filter { !initial.contains(parts[$0]) }
        print("Rectangle/triomino initial palette: \(initial.count) candidates; missing solution states: \(missingInitial.map { "\(Character(UnicodeScalar(65+$0)!))=\(parts[$0].count)" }.joined(separator: ", "))")
        let covered = context.cover(patch: Array(labels.indices), base: Array(labels.indices),
                                    candidates: parts, until: .infinity)
        precondition(covered?.validation.valid == true)
        print("Exact cover supplied only the 16 verified shapes: solved in \(context.metrics.coverNodes) nodes, \(context.metrics.coversChecked) covers.")

        let giant = parts.first { $0.count == 37 }!
        var samples: [[String: Any]] = []
        for seed in 0..<10 {
            var trialConfig = config
            trialConfig.seed = UInt64(seed)
            let trial = SearchContext(config: trialConfig)
            let started = ProcessInfo.processInfo.systemUptime
            let catalog = trial.regionCatalog(patch: Array(labels.indices), until: .infinity)
            let row: [String: Any] = ["seed": seed, "candidates": catalog.count,
                                      "masks_tested": trial.metrics.catalogMasks,
                                      "contains_verified_37": catalog.contains(giant),
                                      "contains_all_verified_shapes": parts.allSatisfy { catalog.contains($0) },
                                      "seconds": ProcessInfo.processInfo.systemUptime-started]
            samples.append(row)
        }
        print("Full-board regionCatalog, fresh contexts, default mask budgets, no wall-clock deadline:")
        print(String(data: try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
