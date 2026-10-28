import Foundation
import Testing
@testable import PuzzleSolver

struct SearchDiscoveryTests {
    private let labels = [0, 1, 2, 1, 1, 1, 1, 1, 3]

    private func configuration() -> RunConfig {
        var c = RunConfig.example
        c.rowNum = 3; c.colNum = 3
        c.Target = OriginalCondition(Status: [[10, 9, 7], [10, -1, 12], [4, 4, 8]])
        c.searchObjective = .residual
        c.pathEvaluation = .cpu
        c.consoleLogging = false
        c.repairTimeLimitSeconds = 10
        return c
    }

    @Test func retainsEvaluatedImprovementInReportsAndSavedResult() async throws {
        var c = configuration()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        c.logDirectory = directory.path
        c.maxIterations = 1
        let context = SearchContext(config: c)
        let bridge = ProgressBridge()
        let result = try await Main().Run(Config: c, initialLabels: labels, reusableContext: context, observe: {
            bridge.update($0)
        })
        #expect(result.best.quality.issues == 0)
        #expect(result.best.quality.wrong == 7)
        let reported = try #require(bridge.read().0)
        #expect(reported.finished)
        #expect(context.evaluate(labels: reported.current).quality.wrong == 8)
        #expect(context.evaluate(labels: reported.best).quality.wrong == 7)
        let (_, saved) = try SavedRunRepair.load(path: result.logURL.path)
        #expect(saved.validation.mismatches.count == 7)
    }

    @Test func cachedAndBatchedEvaluationsAlsoRecordDiscoveries() throws {
        let context = SearchContext(config: configuration())
        let source = context.evaluate(labels: labels)
        _ = context.mergeRepair(source, until: .infinity)
        let best = try #require(context.bestEvaluated)
        #expect(best.quality.wrong == 7)
        let evaluations = context.metrics.evaluations
        context.resetDiscoveries()
        #expect(context.bestEvaluated == nil)
        _ = context.evaluate(labels: best.labels)
        #expect(context.bestEvaluated?.quality == best.quality)
        context.resetDiscoveries()
        let batch = context.evaluateBatch(labels: [source.labels, best.labels, source.labels])
        #expect(context.bestEvaluated?.quality == best.quality)
        #expect(context.metrics.evaluations == evaluations)
        batch[1].board.Energy[0][0] = 123
        #expect(context.bestEvaluated?.board.Energy[0][0] != 123)
        let fresh = SearchContext(config: configuration())
        _ = fresh.evaluateBatch(labels: [source.labels, best.labels])
        #expect(fresh.bestEvaluated?.quality == best.quality)
    }

    @Test func savedBoardRepairUsesCommonRankingForResidualCheckpoints() throws {
        var c = configuration()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saved-discovery-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        c.logDirectory = directory.path
        let context = SearchContext(config: c)
        let logger = try Logger(directory: directory.path, console: false)
        defer { try? logger.close() }
        try logger.checkpoint(config: c, state: context.evaluate(labels: labels), iteration: 0)
        let result = try SavedRunRepair.run(path: logger.checkpointURL.path)
        #expect(result.best.quality.wrong == 7)
    }

    @Test func mergeScanSurvivesRankingChanges() throws {
        let context = SearchContext(config: configuration())
        let source = context.evaluate(labels: labels)
        let residual = try #require(context.mergeRepair(source, until: .infinity))
        #expect(residual.quality.wrong == 8)
        let checked = context.metrics.mergesChecked
        #expect(context.mergeRepair(source, until: .infinity) == nil)
        #expect(context.metrics.mergesChecked == checked)
        let exact = try #require(context.mergeRepair(source, until: .infinity, exactRanking: true))
        #expect(exact.quality.wrong == 7)
        context.config.searchObjective = .matches
        let matches = try #require(context.mergeRepair(source, until: .infinity))
        #expect(matches.quality == exact.quality)

        context.config.searchObjective = .persistent
        _ = context.mergeRepair(source, until: .infinity)
        context.adaptClueWeights(residual)
        let weighted = context.mergeRepair(source, until: .infinity)
        let fresh = SearchContext(config: context.config)
        fresh.clueWeights = context.clueWeights
        let reference = try #require(fresh.mergeRepair(fresh.evaluate(labels: labels), until: .infinity))
        #expect(weighted?.quality == reference.quality)
    }

    @Test func largerMergeLimitRescansPreviouslyExhaustedTopology() throws {
        var c = RunConfig.example
        c.pathEvaluation = .cpu
        c.maxMergeRegions = 2
        let context = SearchContext(config: c)
        let source = context.evaluate(labels: [0,1,1,2,2, 0,1,1,3,2, 4,4,3,3,2, 2,5,5,5,2, 2,2,2,2,2])
        #expect(context.mergeRepair(source, until: .infinity)?.validation.valid != true)
        context.config.maxMergeRegions = 3
        let result = try #require(context.mergeRepair(source, until: .infinity))
        #expect(result.validation.answer?.sumOfSquares == 8045)
    }

    @Test func archiveReachesEveryEntryWithMixedObjectivesAndExplorers() async {
        var c = configuration()
        c.Target = OriginalCondition(Status: Array(repeating: Array(repeating: 7, count: 3), count: 3))
        let context = SearchContext(config: c)
        let pairs = [(0,1), (1,2), (3,4), (4,5), (6,7), (7,8), (0,3), (1,4)]
        for capacity in [2, 4, 8] {
            let archive = EliteArchive(capacity: capacity)
            for i in 0..<capacity {
                var labels = Array(0..<9)
                labels[pairs[i].1] = labels[pairs[i].0]
                let state = context.evaluate(labels: labels)
                await archive.publish(EliteCandidate(snapshot: BoardSnapshot(state), scores: state.scores, workerID: i))
            }
            var seen = Set<Int>()
            for i in 0..<(capacity * 4) {
                let explorer = await archive.assignment(workerID: 4)
                #expect(explorer.candidate == nil)
                let assignment = await archive.assignment(workerID: 1,
                    objective: SearchObjective.allCases[i % SearchObjective.allCases.count])
                if let candidate = assignment.candidate { seen.insert(candidate.workerID) }
            }
            #expect(seen == Set(0..<capacity))
        }
    }

    @Test func calibrationStartsFreshAfterInitializationDeadlineExpires() async {
        let context = SearchContext(config: configuration())
        let initial = context.evaluate(labels: labels)
        context.deadline = ProcessInfo.processInfo.systemUptime - 1
        let rate = await measureWorkerRate(context: context, initial: initial, slot: 2, seconds: 0.05)
        #expect(rate.slot == 2)
        #expect(context.metrics.mergesChecked > 0)
        #expect(rate.iterationsPerSecond > 0.01)
        #expect(rate.iterationsPerSecond.isFinite)
    }

    @Test func calibrationDoesNotCountEmptyAttempts() async {
        var c = configuration()
        c.rowNum = 1; c.colNum = 1
        c.Target = OriginalCondition(Status: [[1]])
        let context = SearchContext(config: c)
        let initial = context.evaluate(labels: [0])
        let rate = await measureWorkerRate(context: context, initial: initial, slot: 0, seconds: 0.01)
        #expect(rate.iterationsPerSecond == 0.01)
    }
}
