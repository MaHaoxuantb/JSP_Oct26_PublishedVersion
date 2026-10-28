import Foundation

/// Bounded fixture diagnostics only; this executable does not call Main.Run or
/// launch fresh puzzle searches. SolverTests contains the separate lifecycle runs.
@main
struct RepairTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func config(rows: Int, cols: Int, clues: [[Int]]) -> RunConfig {
        var config = RunConfig.example
        config.rowNum = rows; config.colNum = cols; config.Target = OriginalCondition(Status: clues)
        config.repairTimeLimitSeconds = 10
        config.consoleLogging = false
        return config
    }

    static func geometryAndExactDistances() {
        let context = SearchContext(config: config(rows: 3, cols: 3,
            clues: Array(repeating: Array(repeating: 0, count: 3), count: 3)))
        for mask in 1..<(1 << 9) {
            let labels = (0..<9).map { mask & (1 << $0) != 0 ? 0 : $0 + 1 }
            let state = context.evaluate(context.board(labels: labels))
            let independent = context.validator.validate(state.board, target: context.config.Target)
            check(state.validation.valid == independent.valid, "Fast evaluator disagrees on validity")
            check(state.validation.issues.count == independent.issues.count, "Cached symmetry/connectivity disagrees")
            check(Set(state.validation.capitols) == Set(independent.capitols), "Cached capitols disagree")
            check(state.validation.mismatches.map(\.actual) == independent.mismatches.map(\.actual)
                  && state.validation.mismatches.map(\.cell) == independent.mismatches.map(\.cell),
                  "Multi-source distances disagree with independent validation")
            check(state.scores.discreteness == 0, "Discrete search retained fractional confidence")
        }
    }

    static let savedLabels = [
        0, 1, 1, 2, 2,
        0, 1, 1, 3, 2,
        4, 4, 3, 3, 2,
        2, 5, 5, 5, 2,
        2, 2, 2, 2, 2
    ]

    static func savedBoardMerge() -> (SearchState, SearchState) {
        var config = RunConfig.example
        config.maxMergeRegions = 3
        let context = SearchContext(config: config)
        let original = context.evaluate(context.board(labels: savedLabels))
        check(original.validation.mismatches.count == 4, "Saved regression fixture changed")
        let start = ProcessInfo.processInfo.systemUptime
        guard let repaired = context.mergeRepair(original, until: start + 10) else {
            preconditionFailure("Three-region repair did not find a candidate")
        }
        check(repaired.validation.valid && repaired.validation.answer?.sumOfSquares == 8045,
              "Generic merge repair failed the saved example")
        check(context.canonical(original.board) == savedLabels, "Repair mutated the saved board")
        check(context.metrics.mergesChecked <= 35, "Repair exceeded all pair/triple combinations")
        print("Saved-board repair: answer 8045, \(context.metrics.mergesChecked) unions checked, \(context.metrics.evaluations - 1) exact evaluations, \(String(format: "%.4f", ProcessInfo.processInfo.systemUptime - start))s")

        config.maxMergeRegions = 2
        let pairContext = SearchContext(config: config)
        let pairSource = pairContext.evaluate(pairContext.board(labels: savedLabels))
        let pair = pairContext.mergeRepair(pairSource, until: start + 10)
        check(pair?.validation.valid != true, "Fixture no longer requires a multi-region move")
        let checked = pairContext.metrics.mergesChecked
        _ = pairContext.mergeRepair(pairSource, until: start + 10)
        check(pairContext.metrics.mergesChecked == checked && pairContext.metrics.mergeCacheHits == 1,
              "Completed topology scan was repeated")
        return (original, repaired)
    }

    static func exactCoverAndConstraints() {
        let context = SearchContext(config: config(rows: 2, cols: 3, clues: [[0, 1, 3], [0, 1, 3]]))
        let cells = Array(0..<6)
        let pieces = [[0], [3], [1, 2], [4, 5]]
        let until = ProcessInfo.processInfo.systemUptime + 10
        let result = context.cover(patch: cells, base: cells, candidates: pieces, until: until)
        check(result?.validation.valid == true && result?.validation.answer?.sumOfSquares == 50,
              "Exact patch cover failed")
        check(!context.constraints.permits([0, 3], geometry: context.regions.geometry([0, 3])),
              "Zero clue allowed a region without its required capitol")
        check(!context.constraints.permits([1], geometry: context.regions.geometry([1])),
              "Positive clue allowed a capitol at itself")
        let one = SearchContext(config: config(rows: 2, cols: 3, clues: [[-1, 1, -1], [-1, -1, -1]]))
        let noSingleton = one.cover(patch: cells, base: cells,
            candidates: [[0, 3], [1, 4], [2, 5]], until: until, strictFeasibility: true)
        check(noSingleton == nil && one.metrics.coversChecked == 0,
              "One-clue singleton requirement did not prune before global evaluation")

        let catalog = context.regionCatalog(patch: cells, until: until)
        check(!catalog.isEmpty && catalog.allSatisfy {
            context.constraints.permits($0, geometry: context.regions.geometry($0)) && Set($0).isSubset(of: Set(cells))
        }, "Catalog includes an invalid shape or wrong clue capitol")
        let cached = context.regionCatalog(patch: cells, until: until)
        check(catalog == cached && context.metrics.catalogCacheHits == 1, "Catalog cache was not reused")

        var limitedConfig = context.config
        limitedConfig.exactCoverNodeLimit = 1
        let limited = SearchContext(config: limitedConfig)
        check(limited.cover(patch: cells, base: cells, candidates: pieces, until: until) == nil,
              "Exact-cover node limit ignored")
        check(limited.metrics.coverNodes == 1 && limited.metrics.budgetStops > 0, "Truncation not recorded")
        check(limited.cover(patch: cells, base: cells, candidates: pieces,
                            until: ProcessInfo.processInfo.systemUptime - 1) == nil, "Expired repair did work")
    }

    static func temperature() {
        var temperature = AdaptiveTemperature(config: RunConfig.example)
        for _ in 0..<5_000 { temperature.step(delta: 0.1) }
        check(temperature.value >= temperature.floor, "Adaptive floor ignored")
        check(exp(-0.1 / temperature.value) >= 0.02 - 1e-12, "Typical moves are effectively frozen")
        temperature.reheat()
        check(exp(-0.1 / temperature.value) >= 0.3 - 1e-12, "Reheat ignored measured move scale")
    }

    static func sharing(original: SearchState, repaired: SearchState) async {
        let archive = EliteArchive(capacity: 2)
        let old = EliteCandidate(snapshot: BoardSnapshot(original), scores: original.scores, workerID: 1)
        await archive.publish(old)
        let first = await archive.assignment(workerID: 2)
        let second = await archive.assignment(workerID: 3)
        check(first.ticket != second.ticket && first.candidate != nil, "Repair assignments were not diversified")
        let explorer = await archive.assignment(workerID: 4)
        check(explorer.candidate == nil, "Independent explorer received an ordinary elite")
        let solved = EliteCandidate(snapshot: BoardSnapshot(repaired), scores: repaired.scores, workerID: 2)
        await archive.publish(solved)
        let update = await archive.assignment(workerID: 4)
        check(update.candidate?.snapshot.validation.valid == true, "Solution did not reach independent explorers")
        original.board.Relationships.ColorBlocks[0][0] = UUID()
        check(old.snapshot.labels[0] == [0, 1, 1, 2, 2], "Shared snapshot aliases the worker's board")
    }

    static func main() async {
        geometryAndExactDistances()
        let (original, repaired) = savedBoardMerge()
        exactCoverAndConstraints()
        temperature()
        await sharing(original: original, repaired: repaired)
        print("Passed fixed-fixture geometry, exact scoring, merge repair, constrained cover, budgets, cache, temperature and sharing checks. No fresh solver run launched.")
    }
}
