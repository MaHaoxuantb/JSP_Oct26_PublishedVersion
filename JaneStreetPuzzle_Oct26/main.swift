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
var arguments = Array(CommandLine.arguments.dropFirst())
var configPath: String?
if let index = arguments.firstIndex(of: "--config"), index + 1 < arguments.count {
    configPath = arguments[index + 1]; arguments.removeSubrange(index...index + 1)
}
@MainActor
func loadConfiguration(base: RunConfig) throws -> RunConfig {
    guard let configPath else { return base }
    func merge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let a = result[key] as? [String: Any], let b = value as? [String: Any] { result[key] = merge(a, b) }
            else { result[key] = value }
        }
        return result
    }
    let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
    let supplied = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configPath)))
    guard let overlay = supplied as? [String: Any] else { throw ConfigurationError(message: "Configuration must be a JSON object.") }
    return try JSONDecoder().decode(RunConfig.self, from: JSONSerialization.data(withJSONObject: merge(original, overlay)))
}
do {
    #if canImport(NIOSSL)
    if arguments.first == "--server" || arguments.first == "--client" || arguments.first == "--restore-backup" || arguments.first == "--export-backup" {
        let config = try loadConfiguration(base: arguments.contains("example") ? .example : .fullPuzzle)
        if arguments.first == "--server" {
            try await runServer(config: config, newRun: arguments.contains("--new-run"))
        } else if arguments.first == "--client" {
            try await runClient(config: config)
        } else if arguments.first == "--restore-backup", arguments.count == 3 {
            try restoreBackup(config: config, backupPath: arguments[1], keyPath: arguments[2])
        } else if arguments.first == "--export-backup", arguments.count == 2 {
            let data = try Data(contentsOf: URL(fileURLWithPath: config.distributed.stateDirectory).appendingPathComponent("latest-backup.encrypted"))
            try writePrivate(data, to: URL(fileURLWithPath: arguments[1]))
        } else { throw ConfigurationError(message: "Use --restore-backup <encrypted-file> <recovery-key> or --export-backup <destination>.") }
        exit(0)
    }
    #endif
    if arguments == ["--run"] || arguments == ["--run", "example"] || arguments == ["--run", "full"] {
        let config = try loadConfiguration(base: arguments == ["--run", "full"] ? .fullPuzzle : .example)
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
        print("Distributed modes (Swift Package build): --server [example|full] [--new-run], --client, --restore-backup <file> <key>, --export-backup <file>. Settings: --config <JSON>.\nSolver is idle. Pass --run [example|full] for the 5×5 example or 11×11 puzzle (default: example), --resume-log <checkpoint or JSONL> to continue a saved board, or --repair-log <JSONL path> for bounded merge repair.")
    }
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("Solver failed: \(error)\n".utf8))
    exit(1)
}
