import Foundation

/// Explicit opt-in benchmark; compiling does not run it. Default: five fresh
/// example searches, ten workers, twenty seconds per worker per trial.
@main
struct SearchBenchmark {
    struct Trial: Codable {
        let seed: UInt64
        let elapsedSeconds: Double
        let solved: Bool
        let wrongClues: Int
        let answer: Int?
        let evaluations: Int
        let summaryLog: String
    }
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--run" else {
            print("Benchmark is idle. Pass --run [trials] [seconds-per-trial] to launch fresh searches.")
            return
        }
        let trials = arguments.count > 1 ? Int(arguments[1]) ?? 0 : 5
        let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 0 : 20
        guard trials > 0 && seconds.isFinite && seconds > 0 else {
            throw ConfigurationError(message: "Provide positive trial and time limits.")
        }
        var config = RunConfig.example
        config.timeLimitSeconds = seconds
        config.consoleLogging = false
        config.logDirectory = URL(fileURLWithPath: config.logDirectory)
            .appendingPathComponent("benchmark-\(UUID().uuidString)").path
        var results: [Trial] = []
        for index in 0..<trials {
            config.seed = 20261026 &+ UInt64(index)
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await ParallelSolver.run(config: config)
            let report = result.best.snapshot.validation
            let trial = Trial(seed: config.seed, elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
                              solved: report.valid, wrongClues: report.mismatches.count,
                              answer: report.answer?.sumOfSquares,
                              evaluations: result.workers.reduce(0) { $0 + $1.repairs.evaluations },
                              summaryLog: result.logURL.path)
            results.append(trial)
            print("Trial \(index + 1): solved=\(trial.solved) wrong=\(trial.wrongClues) seconds=\(trial.elapsedSeconds) evaluations=\(trial.evaluations)")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: URL(fileURLWithPath: config.logDirectory)
                .appendingPathComponent("benchmark.json"), options: .atomic)
        }
        print("Solved \(results.filter(\.solved).count)/\(trials). Results: \(config.logDirectory)/benchmark.json")
    }
}
