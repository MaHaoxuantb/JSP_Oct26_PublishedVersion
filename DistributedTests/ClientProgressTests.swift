import Testing
import Foundation
@testable import PuzzleSolver

struct ClientProgressTests {
    func fixture() throws -> RunConfig {
        var config = RunConfig.example
        config.rowNum = 1; config.colNum = 1
        config.Target = OriginalCondition(Status: [[1]]) // Intentionally unsolved.
        config.pathEvaluation = .cpu
        config.distributed.clientWorkers = 1
        config.distributed.checkpointSeconds = 1_000
        config.distributed.stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-progress-\(UUID())").path
        try FileManager.default.createDirectory(atPath: config.distributed.stateDirectory, withIntermediateDirectories: true)
        return config
    }

    func finished(_ engine: ClientEngine) async throws -> JobReport {
        for _ in 0..<400 {
            if let report = try await engine.reports().first, report.progress.finished { return report }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DistributedError.message("Worker did not finish the fixture")
    }

    @Test func delayedAssignmentReplyMustNotRestartCompletedWork() async throws {
        let config = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let engine = try ClientEngine(settings: config.distributed, pathEvaluation: .cpu)
        try await engine.configure(config, runID: UUID())
        let job = SearchJob(slot: 0, seed: 1, objective: .matches, budget: 1,
                            owner: await engine.identity(), lastSeen: 0, explorer: true)
        var response = WireMessage(kind: "sync"); response.jobs = [job]
        try await engine.apply(response)
        let first = try await finished(engine)
        #expect(first.progress.iterations == 1)
        try await engine.save(force: true)
        // The worker finished while an earlier sync reply was in flight. The
        // coordinator still legitimately echoes that same assignment generation.
        try await engine.apply(response)
        // Let a mistakenly restarted detached worker publish its extra iteration.
        try await Task.sleep(for: .milliseconds(100))
        let afterReply = try await finished(engine)
        #expect(afterReply.progress.iterations == 1)
        try await engine.stop()
    }

    @Test func legacyOverBudgetCheckpointIsRecoveredWithoutLosingBoards() async throws {
        let config = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        var disk = ClientDiskState()
        disk.config = config; disk.runID = UUID()
        let job = SearchJob(slot: 0, seed: 1, objective: .matches, budget: 10, completed: 4,
                            owner: disk.clientID, lastSeen: 0, explorer: true)
        disk.records = [LocalRecord(job: job, progress: DistributedProgress(current: [0], best: [0],
            iterations: 7, seconds: 2, finished: true, solved: false))]
        try DurableStore(path: config.distributed.stateDirectory + "/client.sqlite").write(disk)
        let engine = try ClientEngine(settings: config.distributed, pathEvaluation: .cpu)
        let report = try #require(try await engine.reports().first)
        #expect(report.progress.iterations == 6)
        #expect(report.progress.current == [0] && report.progress.best == [0])
        #expect(report.progress.finished)
        try await engine.stop()
    }

    @Test func delayedReplyWhileSupplementalWorkRunsPreservesCompletedReport() async throws {
        let config = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let engine = try ClientEngine(settings: config.distributed, pathEvaluation: .cpu)
        try await engine.configure(config, runID: UUID())
        await engine.setRates([WorkerRate(slot: 0, iterationsPerSecond: 1, repairSeconds: 0.15)])
        let job = SearchJob(slot: 0, seed: 1, objective: .matches, budget: 1,
                            owner: await engine.identity(), lastSeen: 0, explorer: true)
        var response = WireMessage(kind: "sync"); response.jobs = [job]
        try await engine.apply(response)
        _ = try await finished(engine)
        try await engine.offlineWork()
        try await engine.apply(response)
        try await Task.sleep(for: .milliseconds(100))
        let report = try #require(try await engine.reports().first)
        #expect(report.job.id == job.id && report.progress.iterations == 1)
        try await engine.stop()
    }

    @Test func reconnectUsesAcknowledgedProgressWhenLocalDiskIsBehind() async throws {
        let config = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        var disk = ClientDiskState(); disk.config = config; disk.runID = UUID()
        let job = SearchJob(slot: 0, seed: 1, objective: .matches, budget: 10,
                            owner: disk.clientID, lastSeen: 0, explorer: true)
        disk.records = [LocalRecord(job: job, progress: DistributedProgress(current: [0], best: [0],
            iterations: 1, seconds: 1, finished: true, solved: false))]
        try DurableStore(path: config.distributed.stateDirectory + "/client.sqlite").write(disk)
        let engine = try ClientEngine(settings: config.distributed, pathEvaluation: .cpu)
        var canonical = job
        canonical.progress = DistributedProgress(current: [0], best: [0], iterations: 5, seconds: 2, finished: true, solved: false)
        var response = WireMessage(kind: "sync"); response.jobs = [canonical]
        try await engine.apply(response, reconciling: true)
        let report = try #require(try await engine.reports().first)
        #expect(report.progress.iterations == 5)
        #expect(report.release)
        try await engine.stop()
    }

    @Test func newGenerationCountsOnlyItsRemainingBudget() async throws {
        let config = try fixture()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        var disk = ClientDiskState(); disk.config = config; disk.runID = UUID()
        var job = SearchJob(slot: 0, seed: 1, objective: .matches, budget: 10,
                            owner: disk.clientID, lastSeen: 0, explorer: true)
        disk.records = [LocalRecord(job: job, progress: DistributedProgress(current: [0], best: [0],
            iterations: 6, seconds: 1, finished: true, solved: false))]
        try DurableStore(path: config.distributed.stateDirectory + "/client.sqlite").write(disk)
        let engine = try ClientEngine(settings: config.distributed, pathEvaluation: .cpu)
        job.generation = 2; job.completed = 6
        job.progress = DistributedProgress(current: [0], best: [0], iterations: 0, seconds: 0, finished: false, solved: false)
        var response = WireMessage(kind: "sync"); response.jobs = [job]
        try await engine.apply(response, reconciling: true)
        let report = try await finished(engine)
        #expect(report.job.generation == 2 && report.job.completed == 6)
        #expect(report.progress.iterations == 4)
        try await engine.stop()
    }
}
