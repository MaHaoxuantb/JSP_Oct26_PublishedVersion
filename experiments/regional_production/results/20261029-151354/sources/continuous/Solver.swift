import Foundation

// MARK: - Initialization
final class Initialization {
    func start(context: SearchContext) -> SearchState {
        let board = Board(rowNum: context.grid.rows, colNum: context.grid.cols)
        let minimum = min(context.grid.count, context.config.minimumInitialRegions)
        let maximum = min(context.grid.count, context.config.maximumInitialRegions)
        let regionCount = minimum + context.rng.index(maximum - minimum + 1)
        let partition = context.grid.partition(Array(0..<context.grid.count), regions: regionCount, rng: &context.rng)
        for cell in 0..<context.grid.count {
            board.Relationships.ColorBlocks[cell / context.grid.cols][cell % context.grid.cols] = partition[cell]!
        }
        context.encodePartition(board, initialize: true)
        return context.evaluate(board)
    }
}

// MARK: - One search proposal
struct IterationResult {
    let state: SearchState
    let move: MoveKind?
    let candidate: Energy.Scores?
    let candidateValidation: ValidationReport?
    let accepted: Bool
    let acceptanceProbability: Double
    let randomDraw: Double?
    let delta: Double?
    let evaluationSeconds: Double
    let proposalAttempts: Int
    let changes: [RelationshipChange]
}

final class Iteration {
    func OneIteration(current: SearchState, context: SearchContext, temperature: Double) -> IterationResult {
        precondition(temperature.isFinite && temperature > 0)
        for attempt in 1...context.config.proposalAttempts {
            guard let proposal = context.propose(from: current.board) else { continue }
            let started = ProcessInfo.processInfo.systemUptime
            let candidate = context.evaluate(proposal.board)
            let duration = ProcessInfo.processInfo.systemUptime - started
            let delta = candidate.scores.total - current.scores.total
            // Exact validity overrides the heuristic acceptance decision.
            let probability = candidate.validation.valid || delta <= 0 ? 1 : exp(-delta / temperature)
            let draw: Double? = probability < 1 ? context.rng.unit() : nil
            let accepted = draw.map { $0 < probability } ?? true
            return IterationResult(state: accepted ? candidate : current, move: proposal.kind,
                candidate: candidate.scores, candidateValidation: candidate.validation,
                accepted: accepted, acceptanceProbability: probability, randomDraw: draw, delta: delta,
                evaluationSeconds: duration, proposalAttempts: attempt,
                changes: RelationshipChange.between(current.board, candidate.board))
        }
        return IterationResult(state: current, move: nil, candidate: nil, candidateValidation: nil,
            accepted: false, acceptanceProbability: 0, randomDraw: nil, delta: nil,
            evaluationSeconds: 0, proposalAttempts: context.config.proposalAttempts, changes: [])
    }
}

struct SolverResult {
    let best: SearchState
    let reason: StopReason
    let statistics: SearchStatistics
    let elapsedSeconds: Double
    let logURL: URL
}

// MARK: - Search lifecycle
final class Main {
    func Run(Config config: RunConfig, workerID: Int? = nil) async throws -> SolverResult {
        try config.validate()
        let logger = try Logger(directory: config.logDirectory, console: config.consoleLogging, workerID: workerID)
        defer { try? logger.close() }
        let context = SearchContext(config: config)
        let initializer = Initialization()
        let iteration = Iteration()
        var statistics = SearchStatistics()
        do {
            var started = Logger.Event(kind: .started)
            started.configuration = config
            started.message = "Log: \(logger.fileURL.path)"
            try logger.record(started)
            var current = initializer.start(context: context)
            var best = current.snapshot()
            var temperature = config.initialTemperature
            var epochBest = current.scores.total
            var stagnation = 0
            var epochReheats = 0
            var lastProgressTime = logger.elapsedSeconds
            var reason: StopReason? = current.validation.valid ? .solved : nil

            func milestone(_ kind: Logger.Kind, state: SearchState, message: String? = nil) throws {
                var event = Logger.Event(kind: kind)
                event.iteration = statistics.iterations
                event.restart = statistics.restarts
                event.temperature = temperature
                event.current = state.scores
                event.best = best.scores
                event.statistics = statistics
                event.structuralIssueCount = best.validation.issues.count
                event.clueMismatchCount = best.validation.mismatches.count
                event.message = message
                event.snapshot = BoardSnapshot(best)
                try logger.record(event)
            }
            try milestone(.initialized, state: current)
            while reason == nil {
                if statistics.iterations % config.yieldInterval == 0 { await Task.yield() }
                if Task.isCancelled { reason = .cancelled; break }
                if logger.elapsedSeconds >= config.timeLimitSeconds { reason = .timeLimit; break }
                if statistics.iterations >= config.maxIterations { reason = .iterationLimit; break }

                let result = iteration.OneIteration(current: current, context: context, temperature: temperature)
                statistics.record(result)
                current = result.state
                let improved = current.validation.valid || current.scores.total < best.scores.total
                if improved {
                    best = current.snapshot()
                }
                if improved { try milestone(.bestImproved, state: best) }

                if current.validation.valid { reason = .solved; break }
                temperature = max(config.minimumTemperature, temperature * config.coolingRate)
                stagnation += 1
                if current.scores.total < epochBest - 1e-12 {
                    epochBest = current.scores.total
                    stagnation = 0
                }
                if statistics.iterations % config.progressInterval == 0
                    && logger.elapsedSeconds - lastProgressTime >= config.progressTimeIntervalSeconds {
                    try milestone(.progress, state: current)
                    lastProgressTime = logger.elapsedSeconds
                }
                // Avoid initialization/reheating work after a budget was reached.
                if Task.isCancelled { reason = .cancelled; break }
                if logger.elapsedSeconds >= config.timeLimitSeconds { reason = .timeLimit; break }
                if statistics.iterations >= config.maxIterations { reason = .iterationLimit; break }
                if stagnation >= config.stagnationIterations {
                    if epochReheats < config.reheatsPerRestart {
                        epochReheats += 1
                        statistics.reheats += 1
                        temperature = config.initialTemperature
                        stagnation = 0
                        try milestone(.reheated, state: current)
                    } else if statistics.restarts < config.maxRestarts {
                        statistics.restarts += 1
                        current = initializer.start(context: context)
                        temperature = config.initialTemperature
                        epochBest = current.scores.total
                        stagnation = 0
                        epochReheats = 0
                        if current.validation.valid || current.scores.total < best.scores.total {
                            best = current.snapshot()
                            try milestone(.bestImproved, state: best)
                        }
                        try milestone(.restarted, state: current)
                        if current.validation.valid { reason = .solved }
                    } else {
                        reason = .restartLimit
                    }
                }
            }
            // Recheck the saved result independently before reporting success.
            let report = context.validator.validate(best.board, target: config.Target)
            best = SearchState(board: best.board, scores: best.scores, validation: report)
            if reason == .solved && !report.valid {
                throw SolverError.savedSolutionFailedValidation
            }
            if report.valid { reason = .solved }
            var finished = Logger.Event(kind: .finished)
            finished.iteration = statistics.iterations
            finished.restart = statistics.restarts
            finished.current = current.scores
            finished.best = best.scores
            finished.statistics = statistics
            finished.stopReason = reason!
            finished.snapshot = BoardSnapshot(best)
            finished.structuralIssueCount = report.issues.count
            finished.clueMismatchCount = report.mismatches.count
            finished.message = report.answer.map { "Verified answer: \($0.sumOfSquares)" }
                ?? "Best candidate retained; \(report.issues.count) structural issues, \(report.mismatches.count) unmatched clues."
            try logger.record(finished)
            try logger.close()
            return SolverResult(best: best, reason: reason!, statistics: statistics,
                                elapsedSeconds: logger.elapsedSeconds, logURL: logger.fileURL)
        } catch {
            var failure = Logger.Event(kind: .failed)
            failure.iteration = statistics.iterations
            failure.statistics = statistics
            failure.message = String(describing: error)
            try? logger.record(failure)
            throw error
        }
    }
}

enum SolverError: Error {
    case savedSolutionFailedValidation
}

// MARK: - Parallel independent searches
// Only immutable value snapshots cross task boundaries. Board, Energy's mutable
// cache, RNG and file handles stay private to the worker that created them.
struct WorkerResult: Sendable {
    let workerID: Int
    let seed: UInt64
    let snapshot: BoardSnapshot
    let scores: Energy.Scores
    let reason: StopReason
    let statistics: SearchStatistics
    let logURL: URL

    func isBetter(than other: WorkerResult) -> Bool {
        if snapshot.validation.valid != other.snapshot.validation.valid {
            return snapshot.validation.valid
        }
        if scores.total != other.scores.total { return scores.total < other.scores.total }
        return workerID < other.workerID
    }
}

struct ParallelSolverResult: Sendable {
    let best: WorkerResult
    let workers: [WorkerResult]
    let logURL: URL
}

enum ParallelSolver {
    // Explicit concurrent execution also works with Xcode's approachable
    // concurrency setting: this CPU work must not inherit the main actor.
    @concurrent
    private static func runWorker(id: Int, config: RunConfig) async throws -> WorkerResult {
        let result = try await Main().Run(Config: config, workerID: id)
        return WorkerResult(workerID: id, seed: config.seed, snapshot: BoardSnapshot(result.best),
                            scores: result.best.scores, reason: result.reason,
                            statistics: result.statistics, logURL: result.logURL)
    }

    static func run(config: RunConfig) async throws -> ParallelSolverResult {
        try config.validate()
        let directory = URL(fileURLWithPath: config.logDirectory, isDirectory: true)
            .appendingPathComponent("parallel-\(UUID().uuidString)", isDirectory: true)
        let logger = try Logger(directory: directory.path, console: config.consoleLogging)
        defer { try? logger.close() }
        do {
            var started = Logger.Event(kind: .parallelStarted)
            started.configuration = config
            started.message = "\(config.workerCount) workers; budgets apply per worker. Summary: \(logger.fileURL.path)"
            try logger.record(started)

            return try await withThrowingTaskGroup(of: WorkerResult.self) { group in
                for index in 0..<config.workerCount {
                    var workerConfig = config
                    workerConfig.workerCount = 1
                    // Odd-stride wrapping arithmetic gives distinct reproducible
                    // seeds, with worker 1 preserving the original seed.
                    workerConfig.seed = config.seed &+ (UInt64(index) &* 0x9E3779B97F4A7C15)
                    workerConfig.logDirectory = directory.appendingPathComponent("worker-\(index + 1)").path
                    let configuration = workerConfig
                    group.addTask { try await runWorker(id: index + 1, config: configuration) }
                }
                var workers: [WorkerResult] = []
                var best: WorkerResult?
                var statistics = SearchStatistics()
                for try await worker in group {
                    workers.append(worker)
                    if best == nil || worker.isBetter(than: best!) { best = worker }
                    statistics.iterations += worker.statistics.iterations
                    statistics.accepted += worker.statistics.accepted
                    statistics.noProposal += worker.statistics.noProposal
                    statistics.reheats += worker.statistics.reheats
                    statistics.restarts += worker.statistics.restarts
                    for (move, counts) in worker.statistics.moves {
                        statistics.moves[move, default: MoveStatistics()].accepted += counts.accepted
                        statistics.moves[move, default: MoveStatistics()].proposed += counts.proposed
                    }
                    var event = Logger.Event(kind: .workerFinished)
                    event.workerID = worker.workerID
                    event.workerLogPath = worker.logURL.path
                    event.best = best!.scores
                    event.current = worker.scores
                    event.statistics = worker.statistics
                    event.stopReason = worker.reason
                    event.candidateValid = worker.snapshot.validation.valid
                    event.message = "Worker \(worker.workerID), seed \(worker.seed): \(worker.reason.rawValue)"
                    try logger.record(event)
                    if worker.snapshot.validation.valid { group.cancelAll() }
                }
                // Drain all workers before returning so cancelled runs save their
                // final snapshots and close their logs. Errors cancel siblings too.
                let winner = best! // validate() requires at least one worker.
                var finished = Logger.Event(kind: .parallelFinished)
                finished.workerID = winner.workerID
                finished.workerLogPath = winner.logURL.path
                finished.best = winner.scores
                finished.statistics = statistics
                finished.snapshot = winner.snapshot
                finished.candidateValid = winner.snapshot.validation.valid
                finished.message = "Best: worker \(winner.workerID). \(workers.count) workers finished; \(statistics.iterations) total iterations."
                try logger.record(finished)
                try logger.close()
                return ParallelSolverResult(best: winner, workers: workers.sorted { $0.workerID < $1.workerID },
                                            logURL: logger.fileURL)
            }
        } catch {
            var failure = Logger.Event(kind: .failed)
            failure.message = String(describing: error)
            try? logger.record(failure)
            throw error
        }
    }
}

