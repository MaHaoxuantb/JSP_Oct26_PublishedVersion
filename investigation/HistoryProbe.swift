import Foundation

/// Opt-in historical comparison. All logs and binaries stay in a temporary
/// directory; this never connects to, or mutates, a production worker.
@main struct HistoryProbe {
    static func main() async throws {
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let candidates = input["candidates"] as! [[String: Any]]
        let leader = candidates.min { ($0["wrong"] as! Int) < ($1["wrong"] as! Int) }!
        let labels = leader["labels"] as! [Int]
        var config = RunConfig()
        config.rowNum = input["rows"] as! Int
        config.colNum = input["cols"] as! Int
        config.Target = OriginalCondition(Status: input["clues"] as! [[Int]])
        config.workerCount = 1
        config.consoleLogging = false
        config.logDirectory = CommandLine.arguments[2]
        #if HISTORY_GPU
        config.pathEvaluation = .cpu
        #endif
        let context = SearchContext(config: config)
        let state = context.evaluate(context.board(labels: labels))
        let parts = context.groups(context.canonical(state.board))
        let rejected = parts.enumerated().filter {
            !context.constraints.permits($0.element, geometry: context.regions.geometry($0.element))
        }.map { ["id": $0.offset, "size": $0.element.count, "cells": $0.element] as [String: Any] }
        printJSON(["kind": "static", "wrong": state.quality.wrong,
                   "error": state.scores.realAIM, "issues": state.quality.issues,
                   "rejectedRegions": rejected, "sizes": parts.map(\.count)])
        #if HISTORY_RUN
        for seeded in [true, false] {
            for seed in 0..<3 {
                var trial = config
                trial.seed = UInt64(20261026 + seed)
                trial.timeLimitSeconds = 6
                trial.maxIterations = 10_000
                trial.logDirectory += "/\(seeded ? "seeded" : "fresh")-\(seed)"
                let result = try await Main().Run(Config: trial, initialLabels: seeded ? labels : nil)
                printJSON(["kind": "run", "seeded": seeded, "seed": seed,
                           "wrong": result.best.quality.wrong, "error": result.best.scores.realAIM,
                           "iterations": result.statistics.iterations,
                           "noProposal": result.statistics.noProposal,
                           "restarts": result.statistics.restarts, "reheats": result.statistics.reheats,
                           "evaluations": result.repairs.evaluations,
                           "covers": result.repairs.coversChecked,
                           "seconds": result.elapsedSeconds])
            }
        }
        #endif
    }
    static func printJSON(_ value: [String: Any]) {
        print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
