import Foundation

/// Read only the fields needed from old or new logs. Added configuration fields
/// must not prevent repairing a log written by an earlier solver version.
enum SavedRunRepair {
    private struct SavedConfiguration: Decodable {
        let rowNum: Int
        let colNum: Int
        let Target: OriginalCondition
        let seed: UInt64?
        let factors: Energy.Factors?
    }
    private struct Record: Decodable {
        struct Event: Decodable {
            let configuration: SavedConfiguration?
            let snapshot: BoardSnapshot?
        }
        let event: Event
    }

    static func load(path: String) throws -> (RunConfig, BoardSnapshot) {
        var configuration: SavedConfiguration?
        var snapshot: BoardSnapshot?
        let decoder = JSONDecoder()
        for line in try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 0x0a) {
            let record = try decoder.decode(Record.self, from: Data(line))
            if let value = record.event.configuration { configuration = value }
            if let value = record.event.snapshot { snapshot = value }
        }
        guard let configuration, let snapshot else {
            throw ConfigurationError(message: "The log must contain a puzzle configuration and a board snapshot.")
        }
        // Full modern configuration is retained when available; old logs use
        // compatible defaults for fields that did not exist at the time.
        struct FullRecord: Decodable {
            struct Event: Decodable { let configuration: RunConfig? }
            let event: Event
        }
        var config = RunConfig()
        for line in try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 0x0a) {
            if let record = try? decoder.decode(FullRecord.self, from: Data(line)), let saved = record.event.configuration {
                config = saved
            }
        }
        config.rowNum = configuration.rowNum
        config.colNum = configuration.colNum
        config.Target = configuration.Target
        if let seed = configuration.seed { config.seed = seed }
        if let factors = configuration.factors { config.factors = factors }
        try config.validate()
        guard snapshot.labels.count == config.rowNum,
              snapshot.labels.allSatisfy({ $0.count == config.colNum && $0.allSatisfy { $0 >= 0 } }) else {
            throw ConfigurationError(message: "Saved labels do not match the puzzle dimensions.")
        }
        return (config, snapshot)
    }

    /// Explicit CLI action: at most five seconds of merge repair on the saved
    /// board, with no random initialization, annealing or worker launch.
    static func run(path: String) throws -> SolverResult {
        var (config, snapshot) = try load(path: path)
        config.workerCount = 1
        config.timeLimitSeconds = 5
        config.logDirectory = URL(fileURLWithPath: config.logDirectory).appendingPathComponent("repairs").path
        let logger = try Logger(directory: config.logDirectory, console: config.consoleLogging)
        defer { try? logger.close() }
        let context = SearchContext(config: config)
        context.deadline = ProcessInfo.processInfo.systemUptime + config.timeLimitSeconds
        var started = Logger.Event(kind: .started)
        started.configuration = config
        started.message = "Bounded merge repair of saved log: \(path)"
        try logger.record(started)
        let original = context.evaluate(labels: snapshot.labels.flatMap { $0 })
        var best = original, statistics = SearchStatistics()
        let key = MergeScanKey(labels: original.labels, context: context, exactRanking: true)
        while !best.validation.valid && !context.expired(context.deadline) {
            statistics.iterations += 1
            if let candidate = context.mergeRepair(original, until: context.deadline, exactRanking: true), candidate.quality < best.quality {
                best = candidate
            }
            if let cursor = context.mergeCursors[key], cursor.next >= cursor.queue.count { break }
        }
        let report = context.validator.validate(best.board, target: config.Target)
        if best.validation.valid && !report.valid { throw SolverError.savedSolutionFailedValidation }
        best = SearchState(board: best.board, scores: best.scores, validation: report)
        let reason: StopReason = report.valid ? .solved : (Task.isCancelled ? .cancelled :
            (context.expired(context.deadline) ? .timeLimit : .repairLimit))
        var finished = Logger.Event(kind: .finished)
        finished.iteration = statistics.iterations
        finished.statistics = statistics
        finished.best = best.scores
        finished.snapshot = BoardSnapshot(best)
        finished.stopReason = reason
        finished.repairs = context.metrics
        finished.clueMismatchCount = report.mismatches.count
        finished.message = report.valid ? "Saved board repaired and independently verified." : "Bounded merge repair finished without a verified solution."
        try logger.record(finished)
        try logger.close()
        return SolverResult(best: best, reason: reason, statistics: statistics,
                            elapsedSeconds: logger.elapsedSeconds, logURL: logger.fileURL, repairs: context.metrics)
    }
}
