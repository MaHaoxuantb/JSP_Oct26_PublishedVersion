import Foundation

struct BoardSnapshot: Codable, Sendable {
    let labels: [[Int]]
    let verticalRelationships: [[Double]]
    let horizontalRelationships: [[Double]]
    let energy: [[Double]]
    let validation: ValidationReport
    /// Unverified arithmetic for this partition; consult validation.valid.
    let candidateResult: PuzzleAnswer?

    init(_ state: SearchState) {
        var ids: [UUID: Int] = [:]
        labels = state.board.Relationships.ColorBlocks.map { row in
            row.map { id in
                if ids[id] == nil { ids[id] = ids.count }
                return ids[id]!
            }
        }
        verticalRelationships = state.board.Relationships.VerticalRelationships
        horizontalRelationships = state.board.Relationships.HorizontalRelationships
        energy = state.board.Energy
        validation = state.validation
        var sizes: [UUID: Int] = [:]
        for row in state.board.Relationships.ColorBlocks {
            for id in row { sizes[id, default: 0] += 1 }
        }
        let cellSizes = state.board.Relationships.ColorBlocks.map { row in
            row.map { sizes[$0]! }
        }
        candidateResult = PuzzleAnswer.calculate(cellSizes: cellSizes)
    }
}

struct MoveStatistics: Codable, Sendable {
    var proposed = 0
    var accepted = 0
}

struct SearchStatistics: Codable, Sendable {
    var iterations = 0
    var accepted = 0
    var noProposal = 0
    var restarts = 0
    var reheats = 0
    var moves: [String: MoveStatistics] = [:]

    mutating func record(_ result: IterationResult) {
        iterations += 1
        guard let kind = result.move else { noProposal += 1; return }
        moves[kind.rawValue, default: MoveStatistics()].proposed += 1
        if result.accepted {
            accepted += 1
            moves[kind.rawValue, default: MoveStatistics()].accepted += 1
        }
    }
}

enum StopReason: String, Codable, Sendable {
    case solved, iterationLimit, timeLimit, restartLimit, repairLimit, cancelled
}

/// Progress and milestones are streamed to JSON Lines. Full snapshots are only
/// added for final best results; atomic checkpoint files retain periodic bests. In-memory history
/// is bounded; disk failures propagate and stop the run rather than losing logs.
final class Logger {
    // Only console writes share a lock; evaluation and worker files are independent.
    private static let consoleLock = NSLock()
    enum Kind: String, Codable {
        case started, initialized, iteration, bestImproved, progress, reheated, restarted, finished, failed
        case parallelStarted, workerFinished, parallelFinished
        case eliteImported, checkpoint
    }
    struct Event: Codable {
        let kind: Kind
        var iteration: Int = 0
        var restart: Int = 0
        var temperature: Double?
        var previous: Energy.Scores?
        var current: Energy.Scores?
        var candidate: Energy.Scores?
        var best: Energy.Scores?
        var move: MoveKind?
        var accepted: Bool?
        var acceptanceProbability: Double?
        var randomDraw: Double?
        var delta: Double?
        var evaluationSeconds: Double?
        var proposalAttempts: Int?
        var changes: [RelationshipChange]?
        var candidateValid: Bool?
        var structuralIssueCount: Int?
        var clueMismatchCount: Int?
        var configuration: RunConfig?
        var statistics: SearchStatistics?
        var stopReason: StopReason?
        var snapshot: BoardSnapshot?
        var workerID: Int?
        var workerLogPath: String?
        var repairs: RepairMetrics?
        var message: String?
    }
    struct Entry: Codable {
        let runID: UUID
        let timestamp: Date
        let elapsedSeconds: Double
        let event: Event
    }

    let runID = UUID()
    let fileURL: URL
    let checkpointURL: URL
    private var lastSyncTime = 0.0
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private let startTime = ProcessInfo.processInfo.systemUptime
    private let console: Bool
    private let workerID: Int?
    private var closed = false
    private(set) var recentEntries: [Entry] = []

    init(directory: String, console: Bool, workerID: Int? = nil) throws {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("run-\(runID.uuidString).jsonl")
        checkpointURL = folder.appendingPathComponent("checkpoint-\(runID.uuidString).json")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.console = console
        self.workerID = workerID
    }

    var elapsedSeconds: Double { ProcessInfo.processInfo.systemUptime - startTime }

    func record(_ event: Event) throws {
        precondition(!closed, "Cannot write to a closed log")
        var event = event
        if event.workerID == nil { event.workerID = workerID }
        let entry = Entry(runID: runID, timestamp: Date(), elapsedSeconds: elapsedSeconds, event: event)
        var data = try encoder.encode(entry)
        data.append(0x0a)
        try handle.write(contentsOf: data)
        recentEntries.append(entry)
        if recentEntries.count > 256 { recentEntries.removeFirst(recentEntries.count - 256) }
        if event.kind != .iteration {
            if elapsedSeconds - lastSyncTime >= 2 || [.started, .finished, .parallelFinished, .failed, .checkpoint].contains(event.kind) {
                try handle.synchronize(); lastSyncTime = elapsedSeconds
            }
            if console {
                let score = event.best.map { String(format: "%.8f", $0.total) } ?? "-"
                let source = workerID.map { "worker-\($0)" } ?? "coordinator"
                let current = event.current.map { String(format: "%.8f", $0.total) } ?? "-"
                let temperature = event.temperature.map { String(format: "%.5g", $0) } ?? "-"
                let clues = event.clueMismatchCount.map(String.init) ?? "-"
                let repair = event.repairs.map { " evals=\($0.evaluations) merges=\($0.mergesChecked) covers=\($0.coversChecked) budgetStops=\($0.budgetStops) cacheHits=\($0.evaluationCacheHits) pruned=\($0.constraintRejects + $0.routePrunes)" } ?? ""
                let line = "[\(source)][\(event.kind.rawValue)] iteration=\(event.iteration) restart=\(event.restart) current=\(current) best=\(score) T=\(temperature) bestUnmatchedClues=\(clues) elapsed=\(String(format: "%.1f", elapsedSeconds))s\(repair) \(event.message ?? "")\n"
                try Self.consoleLock.withLock {
                    // Direct writes stay visible when stdout is redirected or piped.
                    try FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
                }
            }
        }
    }

    /// One atomic, replaceable best-board checkpoint; proposals never go to disk.
    func checkpoint(config: RunConfig, state: SearchState, iteration: Int) throws {
        var event = Event(kind: .checkpoint)
        event.configuration = config; event.snapshot = BoardSnapshot(state)
        event.best = state.scores; event.iteration = iteration; event.workerID = workerID
        let entry = Entry(runID: runID, timestamp: Date(), elapsedSeconds: elapsedSeconds, event: event)
        try encoder.encode(entry).write(to: checkpointURL, options: .atomic)
    }

    func close() throws {
        guard !closed else { return }
        try handle.synchronize()
        try handle.close()
        closed = true
    }

    deinit { try? handle.close() }
}
