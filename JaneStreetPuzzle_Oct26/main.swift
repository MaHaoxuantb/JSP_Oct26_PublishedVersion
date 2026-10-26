import Foundation

// Search functions are in Solver.swift; this file only handles explicit launch.
// Compiling never starts a search. Launch with --run when ready.
if Array(CommandLine.arguments.dropFirst()) == ["--run"] {
    do {
        let result = try await ParallelSolver.run(config: RunConfig())
        print("Finished \(result.workers.count) workers. Summary log: \(result.logURL.path)")
        print("Best worker: \(result.best.workerID), seed: \(result.best.seed), stopped: \(result.best.reason.rawValue). Log: \(result.best.logURL.path)")
        let validation = result.best.snapshot.validation
        print(validation.valid ? "Verified solution." :
            "Unsolved: best candidate (\(validation.issues.count) structural issues, \(validation.mismatches.count) unmatched clues).")
        print("Optimization energy (0 is best): \(result.best.scores.total)")
        if let answer = result.best.snapshot.candidateResult {
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
    } catch {
        try? FileHandle.standardError.write(contentsOf: Data("Solver failed: \(error)\n".utf8))
        exit(1)
    }
} else {
    print("Solver is idle. Pass --run to start the configured puzzle and write its log.")
}
