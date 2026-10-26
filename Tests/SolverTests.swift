import Foundation

// Compile only (does not launch this executable):
// See the README for the compile-only command; exclude main.swift when building this test target.
@main
struct SolverTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func canonical(_ board: Board) -> [[Int]] {
        var ids: [UUID: Int] = [:]
        return board.Relationships.ColorBlocks.map { row in
            row.map { id in
                if ids[id] == nil { ids[id] = ids.count }
                return ids[id]!
            }
        }
    }

    static func example() -> Board {
        let labels = ["ABBCC", "ABBDC", "AADDC", "CAAAC", "CCCCC"]
        let board = Board(rowNum: 5, colNum: 5)
        var ids: [Character: UUID] = [:]
        for (row, line) in labels.enumerated() {
            for (col, label) in line.enumerated() {
                if ids[label] == nil { ids[label] = UUID() }
                board.Relationships.ColorBlocks[row][col] = ids[label]!
            }
        }
        return board
    }

    static func copyingAndComponents() {
        let board = Board(rowNum: 2, colNum: 3)
        // A connected path that travels down, right, up, then right; bottom-right
        // is isolated. This catches directional propagation and aliasing errors.
        board.Relationships.VerticalRelationships = [[0, 1], [1, 0]]
        board.Relationships.HorizontalRelationships = [[1, 1, 0]]
        Runners().IntoColorBlocks(Board: board)
        check(canonical(board) == [[0, 0, 0], [0, 0, 1]], "Flood fill missed an undirected path")
        check(board.Relationships.BlocksContained.blockCounts.sorted() == [1, 5], "Incorrect state counts")
        let copied = board.copy()
        copied.Relationships.VerticalRelationships[0][0] = 1
        copied.Relationships.ColorBlocks[0][0] = UUID()
        copied.Relationships.BlocksContained.blockCounts[0] = 999
        copied.Relationships.Capitals[0][0] = true
        copied.Energy[0][0] = 1
        check(board.Relationships.VerticalRelationships[0][0] == 0, "Copy shares edge storage")
        check(canonical(board) == [[0, 0, 0], [0, 0, 1]], "Copy shares labels")
        check(board.Relationships.BlocksContained.blockCounts.sorted() == [1, 5], "Copy shares metadata")
        check(!board.Relationships.Capitals[0][0] && board.Energy[0][0] == 0, "Copy shares derived state")
        let thin = Board(rowNum: 1, colNum: 2)
        thin.Relationships.VerticalRelationships = [[0.5]]
        Runners().IntoColorBlocks(Board: thin)
        check(thin.Relationships.BlocksContained.ids.count == 1, "Threshold must include 0.5")
        thin.Relationships.VerticalRelationships = [[Double(0.5).nextDown]]
        Runners().IntoColorBlocks(Board: thin)
        check(thin.Relationships.BlocksContained.ids.count == 2, "Threshold must exclude values below 0.5")
    }

    static func exactValidation() {
        let board = example()
        let report = ExactValidator().validate(board, target: RunConfig().Target)
        check(report.valid && report.capitols.count == 3, "Solved example rejected")
        check(report.answer?.rowSums == [37, 29, 31, 43, 55], "Wrong example row sums")
        check(report.answer?.sumOfSquares == 8045, "Wrong example answer")
        var wrong = RunConfig().Target
        wrong.Status[0][0] = 0
        let incorrect = ExactValidator().validate(board, target: wrong)
        check(!incorrect.valid && incorrect.answer == nil && incorrect.mismatches.count == 1,
              "Incorrect clue accepted")
        let bar = Board(rowNum: 1, colNum: 3)
        let noCapitol = ExactValidator().validate(bar, target: OriginalCondition(Status: [[0, -1, -1]]))
        check(noCapitol.issues.isEmpty && noCapitol.capitols.isEmpty && !noCapitol.valid,
              "Symmetry alone must not create a capitol")
        let split = Board(rowNum: 1, colNum: 3)
        split.Relationships.ColorBlocks[0][1] = UUID()
        let disconnected = ExactValidator().validate(split, target: OriginalCondition(Status: [[1, -1, -1]]))
        check(disconnected.issues.contains { $0.contains("disconnected") }, "Disconnected UUID group accepted")
    }

    static func reproducibilityAndIsolation() throws {
        var config = RunConfig()
        config.seed = 12345
        try config.validate()
        let firstContext = SearchContext(config: config)
        let secondContext = SearchContext(config: config)
        var first = Initialization().start(context: firstContext)
        var second = Initialization().start(context: secondContext)
        check(canonical(first.board) == canonical(second.board), "Seed did not reproduce initial partition")
        let initial = first.snapshot()
        let initialLabels = canonical(initial.board)
        for _ in 0..<30 {
            let beforeEdges = first.board.Relationships.VerticalRelationships
            let beforeOtherEdges = first.board.Relationships.HorizontalRelationships
            let beforeLabels = canonical(first.board)
            let beforeBoard = first.board
            let a = Iteration().OneIteration(current: first, context: firstContext, temperature: 0.03)
            let b = Iteration().OneIteration(current: second, context: secondContext, temperature: 0.03)
            check(a.move == b.move && a.accepted == b.accepted, "Seed did not reproduce decisions")
            check(canonical(a.state.board) == canonical(b.state.board), "Seed did not reproduce partition")
            check(abs(a.state.scores.total - b.state.scores.total) < 1e-12, "Seed did not reproduce energy")
            check(beforeBoard.Relationships.VerticalRelationships == beforeEdges
                  && beforeBoard.Relationships.HorizontalRelationships == beforeOtherEdges
                  && canonical(beforeBoard) == beforeLabels, "Proposal mutated its input")
            check(canonical(initial.board) == initialLabels, "Saved best was mutated by a later iteration")
            first = a.state
            second = b.state
        }
        let expected = firstContext.energy.EnergyCal(Board: first.board, Target: config.Target, Factors: config.factors)
        check(expected == first.board.Energy, "Stored cell energy is stale")
    }

    static func lifecycleAndLogs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("solver-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        var config = RunConfig()
        config.rowNum = 1
        config.colNum = 1
        config.Target = OriginalCondition(Status: [[1]]) // impossible singleton clue
        config.logDirectory = folder.path
        config.consoleLogging = false
        config.maxIterations = 2
        config.timeLimitSeconds = 60
        config.stagnationIterations = 100
        config.progressInterval = 1
        config.progressTimeIntervalSeconds = 0
        let limited = try await Main().Run(Config: config)
        check(limited.reason == .iterationLimit && limited.statistics.iterations == 2,
              "Iteration budget was not respected")
        check(limited.statistics.noProposal == 2 && !limited.best.validation.valid,
              "No-move board must terminate without claiming success")
        let data = try Data(contentsOf: limited.logURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try data.split(separator: 0x0a).map { try decoder.decode(Logger.Entry.self, from: Data($0)) }
        check(entries.first?.event.configuration?.seed == config.seed, "Log omitted run configuration")
        check(entries.allSatisfy { $0.event.kind != .iteration && $0.event.changes == nil },
              "Compact logs must omit individual proposals and edge changes")
        check(entries.filter { $0.event.kind == .progress }.count == 2,
              "Running progress was not logged")
        check(entries.filter { $0.event.kind != .finished }.allSatisfy { $0.event.snapshot == nil },
              "Intermediate boards must not be stored")
        check(entries.last?.event.stopReason == .iterationLimit && entries.last?.event.snapshot != nil,
              "Log omitted final reason/snapshot")
        check(entries.allSatisfy { $0.runID == entries[0].runID }, "Log changed run identity")

        config.maxIterations = 20
        config.stagnationIterations = 1
        config.reheatsPerRestart = 1
        config.maxRestarts = 1
        let restarted = try await Main().Run(Config: config)
        check(restarted.reason == .restartLimit && restarted.statistics.restarts == 1
              && restarted.statistics.reheats == 2, "Reheat/restart lifecycle is incorrect")
        let task = Task { [config] in try await Main().Run(Config: config) }
        task.cancel()
        let cancelled = try await task.value
        check(cancelled.reason == .cancelled, "Cancellation was ignored")

        config.Target = OriginalCondition(Status: [[0]])
        let solved = try await Main().Run(Config: config)
        check(solved.reason == .solved && solved.statistics.iterations == 0
              && solved.best.validation.answer?.sumOfSquares == 1, "Valid initial board was not recognized")
        check(solved.best.scores.total == 0, "Verified solution was not hardened/evaluated")

        var bad = config
        bad.rowNum = 0
        do {
            try bad.validate()
            preconditionFailure("Invalid dimensions accepted")
        } catch is ConfigurationError { }
    }

    static func parallelLifecycleAndLogs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parallel-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        var config = RunConfig()
        config.workerCount = 10
        config.rowNum = 1
        config.colNum = 1
        config.Target = OriginalCondition(Status: [[1]]) // impossible; every worker exhausts its budget
        config.maxIterations = 2
        config.timeLimitSeconds = 60
        config.consoleLogging = false
        config.logDirectory = folder.path
        let result = try await ParallelSolver.run(config: config)
        check(result.workers.count == 10, "Missing parallel results")
        check(Set(result.workers.map(\.seed)).count == 10, "Workers reused a random seed")
        check(Set(result.workers.map(\.logURL)).count == 10, "Workers shared a log file")
        check(result.workers.first?.seed == config.seed, "Worker 1 must preserve the configured seed")
        check(result.workers.allSatisfy { $0.reason == .iterationLimit && $0.statistics.iterations == 2 },
              "Per-worker iteration budgets were not respected")
        check(result.best.workerID == 1 && !result.best.snapshot.validation.valid,
              "Equal-energy candidates must use a stable worker-ID tie break")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func entries(_ url: URL) throws -> [Logger.Entry] {
            try Data(contentsOf: url).split(separator: 0x0a).map {
                try decoder.decode(Logger.Entry.self, from: Data($0))
            }
        }
        for worker in result.workers {
            let log = try entries(worker.logURL)
            check(log.first?.event.configuration?.seed == worker.seed, "Worker log has the wrong seed")
            check(log.last?.event.kind == .finished, "Worker did not finish its log")
            check(log.allSatisfy { $0.event.workerID == worker.workerID }, "Worker identity missing from log")
            check(log.allSatisfy { $0.event.kind != .iteration }, "Worker logged individual proposals")
            check(log.filter { $0.event.snapshot != nil }.count == 1, "Only final worker boards should be stored")
        }
        let summary = try entries(result.logURL)
        check(summary.filter { $0.event.kind == .workerFinished }.count == 10, "Summary omitted a worker")
        check(summary.last?.event.kind == .parallelFinished
              && summary.last?.event.statistics?.iterations == 20
              && summary.last?.event.snapshot?.candidateResult?.sumOfSquares == 1,
              "Summary omitted aggregate statistics or the final candidate")

        config.maxIterations = 1_000_000
        let task = Task { [config] in try await ParallelSolver.run(config: config) }
        task.cancel()
        let cancelled = try await task.value
        check(cancelled.workers.allSatisfy { $0.reason == .cancelled },
              "Parent cancellation did not reach every worker")

        config.Target = OriginalCondition(Status: [[0]])
        let solved = try await ParallelSolver.run(config: config)
        check(solved.best.snapshot.validation.valid
              && solved.best.snapshot.validation.answer?.sumOfSquares == 1,
              "Parallel search lost a verified solution")
        check(solved.workers.count == 10, "Early success did not drain all workers")

        config.workerCount = 0
        do {
            _ = try await ParallelSolver.run(config: config)
            preconditionFailure("Zero workers accepted")
        } catch is ConfigurationError { }
    }

    static func main() async throws {
        copyingAndComponents()
        exactValidation()
        try reproducibilityAndIsolation()
        try await lifecycleAndLogs()
        try await parallelLifecycleAndLogs()
        print("Passed solver invariants, exact validation, deterministic proposals, budgets, cancellation, and JSONL logging.")
    }
}
