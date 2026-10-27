import Foundation

// MARK: - Initialization
final class Initialization {
    func start(context: SearchContext) -> SearchState {
        context.initialState()
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
        let started = ProcessInfo.processInfo.systemUptime
        guard let (candidate, kind) = context.repairProposal(current) else {
            return IterationResult(state: current, move: nil, candidate: nil, candidateValidation: nil,
                accepted: false, acceptanceProbability: 0, randomDraw: nil, delta: nil,
                evaluationSeconds: ProcessInfo.processInfo.systemUptime - started, proposalAttempts: 1, changes: [])
        }
        let delta = context.merit(candidate) - context.merit(current)
        let probability = candidate.validation.valid || delta <= 0 ? 1 : exp(-delta / temperature)
        let draw: Double? = probability < 1 ? context.rng.unit() : nil
        let accepted = draw.map { $0 < probability } ?? true
        return IterationResult(state: accepted ? candidate : current, move: kind,
            candidate: candidate.scores, candidateValidation: candidate.validation,
            accepted: accepted, acceptanceProbability: probability, randomDraw: draw, delta: delta,
            evaluationSeconds: ProcessInfo.processInfo.systemUptime - started, proposalAttempts: 1, changes: [])
    }
}

struct SolverResult {
    let best: SearchState
    let reason: StopReason
    let statistics: SearchStatistics
    let elapsedSeconds: Double
    let logURL: URL
    let repairs: RepairMetrics
}

// MARK: - Search lifecycle
final class Main {
    func Run(Config config: RunConfig, workerID: Int? = nil, archive: EliteArchive? = nil, initialLabels: [Int]? = nil, reusableContext: SearchContext? = nil,
             observe: (@Sendable (DistributedProgress) -> Void)? = nil) async throws -> SolverResult {
        try config.validate()
        if let initialLabels, initialLabels.count != config.rowNum * config.colNum || initialLabels.contains(where: { $0 < 0 }) {
            throw ConfigurationError(message: "Resume labels do not match the configured board.")
        }
        let logger = try Logger(directory: config.logDirectory, console: config.consoleLogging, workerID: workerID)
        defer { try? logger.close() }
        let context = reusableContext ?? SearchContext(config: config)
        context.config = config
        context.rng = SearchRandom(seed: config.seed)
        context.metrics = RepairMetrics()
        context.deadline = ProcessInfo.processInfo.systemUptime + max(0, config.timeLimitSeconds - logger.elapsedSeconds)
        context.repairTicket = workerID ?? 0
        let initializer = Initialization()
        let iteration = Iteration()
        var statistics = SearchStatistics()
        do {
            var started = Logger.Event(kind: .started)
            started.configuration = config
            started.message = "Objective: \(config.searchObjective.rawValue). Log: \(logger.fileURL.path)"
            try logger.record(started)
            var current = initialLabels.map { context.evaluate(labels: $0) } ?? initializer.start(context: context)
            var best = current.snapshot()
            var thermostat = AdaptiveTemperature(config: config)
            var epochBest = context.merit(current)
            var localElite = current.snapshot()
            var stagnation = 0
            var epochReheats = 0
            var lastProgressTime = logger.elapsedSeconds
            var lastExchangeTime = -Double.infinity
            var lastCheckpointTime = logger.elapsedSeconds
            var lastObservation = -Double.infinity
            var published: [Int]?
            var reason: StopReason? = current.validation.valid ? .solved : nil

            func milestone(_ kind: Logger.Kind, state: SearchState, message: String? = nil) throws {
                var event = Logger.Event(kind: kind)
                event.iteration = statistics.iterations
                event.restart = statistics.restarts
                event.temperature = thermostat.value
                event.current = state.scores
                event.best = best.scores
                event.statistics = statistics
                event.repairs = context.metrics
                event.structuralIssueCount = best.validation.issues.count
                event.clueMismatchCount = best.validation.mismatches.count
                event.message = message
                try logger.record(event)
            }
            func observation(finished: Bool = false) {
                observe?(DistributedProgress(current: current.labels, best: best.labels, iterations: statistics.iterations,
                    seconds: logger.elapsedSeconds, finished: finished, solved: best.validation.valid))
            }
            observation()
            try milestone(.initialized, state: current)
            try logger.checkpoint(config: config, state: best, iteration: statistics.iterations)
            while reason == nil {
                if statistics.iterations % config.yieldInterval == 0 { await Task.yield() }
                if Task.isCancelled { reason = .cancelled; break }
                if logger.elapsedSeconds >= config.timeLimitSeconds { reason = .timeLimit; break }
                if statistics.iterations >= config.maxIterations { reason = .iterationLimit; break }

                // Exchange only immutable snapshots. Explorer workers still publish
                // discoveries but receive no ordinary elite assignments.
                if let archive, statistics.iterations % config.exchangeInterval == 0
                    || logger.elapsedSeconds - lastExchangeTime >= config.exchangeTimeIntervalSeconds {
                    let key = localElite.labels
                    if published != key {
                        await archive.publish(EliteCandidate(snapshot: BoardSnapshot(localElite), scores: localElite.scores,
                                                             workerID: workerID ?? 1))
                        published = key
                    }
                    let assignment = await archive.assignment(workerID: workerID ?? 1, objective: config.searchObjective)
                    context.repairTicket = assignment.ticket
                    if let elite = assignment.candidate,
                       elite.snapshot.validation.valid || (elite.snapshot.labels.flatMap { $0 } != current.labels
                           && (elite.quality < best.quality || stagnation >= max(1, config.stagnationIterations / 4))) {
                        current = context.evaluate(labels: elite.snapshot.labels.flatMap { $0 })
                        if context.prefers(current, over: localElite) { localElite = current.snapshot() }
                        context.metrics.eliteImports += 1
                        if current.quality < best.quality || current.validation.valid { best = current.snapshot() }
                        // Re-anchor the local walk, but don't reset the stagnation
                        // budget merely because an already-known elite was imported.
                        try milestone(.eliteImported, state: current,
                                      message: "From worker \(elite.workerID), repair ticket \(assignment.ticket)")
                        if current.validation.valid { reason = .solved; break }
                    }
                    lastExchangeTime = logger.elapsedSeconds
                }
                // Periodically repair the saved best even if annealing wandered
                // elsewhere. Its merge cursor resumes rather than starting over.
                if stagnation > 0 && statistics.iterations % config.exchangeInterval == 0 {
                    if let repaired = context.mergeRepair(best, until: min(context.deadline,
                        ProcessInfo.processInfo.systemUptime + config.repairTimeLimitSeconds / 3), exactRanking: true) {
                        best = repaired.snapshot()
                        current = repaired
                        epochBest = context.merit(repaired)
                        stagnation = 0
                        try milestone(.bestImproved, state: best, message: "Saved-best region merge")
                        if repaired.validation.valid { reason = .solved; break }
                    }
                }

                let result = iteration.OneIteration(current: current, context: context, temperature: thermostat.value)
                statistics.record(result)
                current = result.state
                let improved = current.validation.valid || current.quality < best.quality
                if observe != nil && (current.validation.valid || logger.elapsedSeconds - lastObservation >= config.distributed.checkpointSeconds) {
                    // Capture a newer best before notifying the durable/network bridge.
                    if current.quality < best.quality || current.validation.valid { best = current.snapshot() }
                    observation(); lastObservation = logger.elapsedSeconds
                }
                if improved {
                    best = current.snapshot()
                }
                if improved { try milestone(.bestImproved, state: best) }

                if context.prefers(current, over: localElite) { localElite = current.snapshot() }
                if current.validation.valid { reason = .solved; break }
                thermostat.step(delta: result.delta)
                stagnation += 1
                if context.merit(current) < epochBest {
                    epochBest = context.merit(current)
                    stagnation = 0
                }
                if statistics.iterations % config.progressInterval == 0
                    && logger.elapsedSeconds - lastProgressTime >= config.progressTimeIntervalSeconds {
                    try milestone(.progress, state: current)
                    lastProgressTime = logger.elapsedSeconds
                }
                if logger.elapsedSeconds - lastCheckpointTime >= config.checkpointIntervalSeconds {
                    try logger.checkpoint(config: config, state: best, iteration: statistics.iterations)
                    try milestone(.checkpoint, state: current, message: "Best saved: \(logger.checkpointURL.path)")
                    lastCheckpointTime = logger.elapsedSeconds
                }
                // Avoid initialization/reheating work after a budget was reached.
                if Task.isCancelled { reason = .cancelled; break }
                if logger.elapsedSeconds >= config.timeLimitSeconds { reason = .timeLimit; break }
                if statistics.iterations >= config.maxIterations { reason = .iterationLimit; break }
                if stagnation >= config.stagnationIterations {
                    if config.searchObjective == .persistent {
                        context.adaptClueWeights(current)
                        localElite = current.snapshot()
                        epochBest = context.merit(current)
                    }
                    if epochReheats < config.reheatsPerRestart {
                        epochReheats += 1
                        statistics.reheats += 1
                        thermostat.reheat()
                        stagnation = 0
                        try milestone(.reheated, state: current)
                    } else if statistics.restarts < config.maxRestarts {
                        statistics.restarts += 1
                        current = initializer.start(context: context)
                        thermostat.reheat()
                        epochBest = context.merit(current)
                        stagnation = 0
                        epochReheats = 0
                        if current.validation.valid || current.quality < best.quality {
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
            if let archive {
                await archive.publish(EliteCandidate(snapshot: BoardSnapshot(best), scores: best.scores,
                                                     workerID: workerID ?? 1))
            }
            observation(finished: true)
            var finished = Logger.Event(kind: .finished)
            finished.iteration = statistics.iterations
            finished.restart = statistics.restarts
            finished.current = current.scores
            finished.best = best.scores
            finished.statistics = statistics
            finished.repairs = context.metrics
            finished.stopReason = reason!
            finished.snapshot = BoardSnapshot(best)
            finished.structuralIssueCount = report.issues.count
            finished.clueMismatchCount = report.mismatches.count
            finished.message = report.answer.map { "Verified answer: \($0.sumOfSquares)" }
                ?? "Best candidate retained; \(report.issues.count) structural issues, \(report.mismatches.count) unmatched clues."
            try logger.record(finished)
            try logger.checkpoint(config: config, state: best, iteration: statistics.iterations)
            try logger.close()
            return SolverResult(best: best, reason: reason!, statistics: statistics,
                                elapsedSeconds: logger.elapsedSeconds, logURL: logger.fileURL, repairs: context.metrics)
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
    let repairs: RepairMetrics

    func isBetter(than other: WorkerResult) -> Bool {
        if snapshot.validation.valid != other.snapshot.validation.valid {
            return snapshot.validation.valid
        }
        let quality = SearchQuality(snapshot.validation, scores)
        let otherQuality = SearchQuality(other.snapshot.validation, other.scores)
        if quality != otherQuality { return quality < otherQuality }
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
    private static func runWorker(id: Int, config: RunConfig, archive: EliteArchive, initialLabels: [Int]?) async throws -> WorkerResult {
        let result = try await Main().Run(Config: config, workerID: id, archive: archive, initialLabels: initialLabels)
        return WorkerResult(workerID: id, seed: config.seed, snapshot: BoardSnapshot(result.best),
                            scores: result.best.scores, reason: result.reason,
                            statistics: result.statistics, logURL: result.logURL, repairs: result.repairs)
    }

    static func run(config: RunConfig, initialLabels: [Int]? = nil) async throws -> ParallelSolverResult {
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

            let archive = EliteArchive(capacity: config.eliteCapacity)
            return try await withThrowingTaskGroup(of: WorkerResult.self) { group in
                for index in 0..<config.workerCount {
                    var workerConfig = config
                    workerConfig.workerCount = 1
                    workerConfig.searchObjective = SearchObjective.allCases[index % SearchObjective.allCases.count]
                    // Odd-stride wrapping arithmetic gives distinct reproducible
                    // seeds, with worker 1 preserving the original seed.
                    workerConfig.seed = config.seed &+ (UInt64(index) &* 0x9E3779B97F4A7C15)
                    workerConfig.logDirectory = directory.appendingPathComponent("worker-\(index + 1)").path
                    let configuration = workerConfig
                    group.addTask { try await runWorker(id: index + 1, config: configuration, archive: archive, initialLabels: initialLabels) }
                }
                var workers: [WorkerResult] = []
                var best: WorkerResult?
                var statistics = SearchStatistics()
                var repairs = RepairMetrics()
                for try await worker in group {
                    workers.append(worker)
                    if best == nil || worker.isBetter(than: best!) { best = worker }
                    statistics.iterations += worker.statistics.iterations
                    statistics.accepted += worker.statistics.accepted
                    statistics.noProposal += worker.statistics.noProposal
                    statistics.reheats += worker.statistics.reheats
                    statistics.restarts += worker.statistics.restarts
                    repairs.add(worker.repairs)
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
                    event.repairs = worker.repairs
                    event.stopReason = worker.reason
                    event.candidateValid = worker.snapshot.validation.valid
                    event.clueMismatchCount = best!.snapshot.validation.mismatches.count
                    event.structuralIssueCount = best!.snapshot.validation.issues.count
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
                finished.repairs = repairs
                finished.snapshot = winner.snapshot
                finished.candidateValid = winner.snapshot.validation.valid
                finished.clueMismatchCount = winner.snapshot.validation.mismatches.count
                finished.structuralIssueCount = winner.snapshot.validation.issues.count
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

