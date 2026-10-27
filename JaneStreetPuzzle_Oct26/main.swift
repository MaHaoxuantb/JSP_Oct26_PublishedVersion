import Foundation

func printResult(snapshot: BoardSnapshot, scores: Energy.Scores) {
    let validation = snapshot.validation
    print(validation.valid ? "Verified solution." :
        "Unsolved: best candidate (\(validation.issues.count) structural issues, \(validation.mismatches.count) unmatched clues).")
    print("Optimization energy (0 is best): \(scores.total)")
    if let answer = snapshot.candidateResult {
        print("Result matrix (region size in each cell):")
        let width = String(answer.cellSizes.flatMap { $0 }.max() ?? 0).count
        for row in answer.cellSizes {
            print(row.map { value in
                let text = String(value)
                return String(repeating: " ", count: width - text.count) + text
            }.joined(separator: " "))
        }
        print("Row sums: \(answer.rowSums)")
        print("\(validation.valid ? "Verified answer" : "Candidate score (not a verified answer)"): \(answer.sumOfSquares)")
    } else {
        print("Puzzle score unavailable: arithmetic exceeds Int capacity.")
    }
}

// Compilation is inert. Every action requires an explicit launch argument.
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments == ["--run"] || arguments == ["--run", "example"] || arguments == ["--run", "full"] {
        let config = arguments == ["--run", "full"] ? RunConfig.fullPuzzle : RunConfig.example
        let result = try await ParallelSolver.run(config: config)
        print("Finished \(result.workers.count) workers. Summary log: \(result.logURL.path)")
        print("Best worker: \(result.best.workerID), seed: \(result.best.seed), stopped: \(result.best.reason.rawValue). Log: \(result.best.logURL.path)")
        printResult(snapshot: result.best.snapshot, scores: result.best.scores)
    } else if arguments.count == 2 && arguments[0] == "--resume-log" {
        var (config, snapshot) = try SavedRunRepair.load(path: arguments[1])
        config.workerCount = RunConfig().workerCount
        config.logDirectory = RunConfig().logDirectory
        let result = try await ParallelSolver.run(config: config, initialLabels: snapshot.labels.flatMap { $0 })
        print("Resumed search finished. Summary log: \(result.logURL.path)")
        printResult(snapshot: result.best.snapshot, scores: result.best.scores)
    } else if arguments.count == 2 && arguments[0] == "--repair-log" {
        let result = try SavedRunRepair.run(path: arguments[1])
        print("Repair stopped: \(result.reason.rawValue). Log: \(result.logURL.path)")
        printResult(snapshot: BoardSnapshot(result.best), scores: result.best.scores)
    } else {
        print("Solver is idle. Pass --run [example|full] for the 5×5 example or 11×11 puzzle (default: example), --resume-log <checkpoint or JSONL> to continue a saved board, or --repair-log <JSONL path> for bounded merge repair.")
    }
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("Solver failed: \(error)\n".utf8))
    exit(1)
}
