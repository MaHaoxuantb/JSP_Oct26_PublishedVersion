import XCTest
import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOEmbedded
@testable import PuzzleSolver

final class DistributedTests: XCTestCase, @unchecked Sendable {
    func configuration() throws -> RunConfig {
        var config = RunConfig.example
        config.distributed.stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("puzzle-test-\(UUID())").path
        try FileManager.default.createDirectory(atPath: config.distributed.stateDirectory, withIntermediateDirectories: true)
        config.distributed.clientWorkers = 1
        config.distributed.heartbeatSeconds = 1
        config.distributed.failureGraceSeconds = 3
        config.distributed.checkpointSeconds = 1
        config.distributed.jobSeconds = 2
        return config
    }
    func request(client: UUID = UUID(), rate: Double = 5) -> WireMessage {
        var value = WireMessage(kind: "hello", clientID: client, token: String(repeating: "t", count: 32))
        value.rates = [WorkerRate(slot: 0, iterationsPerSecond: rate, repairSeconds: 0.15)]
        return value
    }
    func progress(_ iterations: Int, finished: Bool = false) -> DistributedProgress {
        let labels = Array(0..<25)
        return DistributedProgress(current: labels, best: labels, iterations: iterations, seconds: 1, finished: finished, solved: false)
    }
    func testOldAndPartialConfigurationsDecode() throws {
        let config = try JSONDecoder().decode(RunConfig.self, from: Data("{\"workerCount\":3,\"distributed\":{\"port\":1234}}".utf8))
        XCTAssertEqual(config.workerCount, 3)
        XCTAssertEqual(config.distributed.port, 1234)
        XCTAssertEqual(config.distributed.failureGraceSeconds, 180)
        XCTAssertEqual(config.maxMergeRegions, 4)
    }
    func testReassignmentPreservesWorkAndRejectsStaleOwner() async throws {
        let config = try configuration()
        let server = try Coordinator(config: config, token: String(repeating: "t", count: 32), newRun: true, now: 0)
        var first = request()
        let assigned = try await server.handle(first, now: 0)
        let original = try XCTUnwrap(assigned.jobs.first)
        first.kind = "sync"; first.runID = assigned.runID
        first.reports = [JobReport(job: original, progress: progress(2))]
        _ = try await server.handle(first, now: 1)
        let another = try await server.handle(request(), now: 3)
        XCTAssertNotEqual(another.jobs.first?.id, original.id, "A transient outage must not transfer ownership")
        let recovered = try await server.handle(request(), now: 5)
        let resumed = try XCTUnwrap(recovered.jobs.first)
        XCTAssertEqual(resumed.id, original.id)
        XCTAssertEqual(resumed.generation, original.generation + 1)
        XCTAssertEqual(resumed.completed, 2)
        XCTAssertEqual(resumed.progress?.current, progress(2).current)
        first.rates = []
        first.reports = [JobReport(job: original, progress: progress(original.budget, finished: true))]
        let stale = try await server.handle(first, now: 6)
        XCTAssertTrue(stale.retired.contains(original.id))
        let store = try DurableStore(path: config.distributed.stateDirectory + "/server.sqlite")
        let state = try XCTUnwrap(store.read(CoordinatorState.self))
        XCTAssertEqual(state.jobs.first(where: { $0.id == original.id })?.owner, resumed.owner)
        XCTAssertEqual(state.completedJobs, 0)
    }
    func testCompletionIsDurableAndIdempotent() async throws {
        let config = try configuration()
        let token = String(repeating: "t", count: 32)
        let server = try Coordinator(config: config, token: token, newRun: true, now: 0)
        var message = request()
        let assigned = try await server.handle(message, now: 0)
        let job = try XCTUnwrap(assigned.jobs.first)
        message.kind = "sync"; message.runID = assigned.runID; message.rates = []
        message.reports = [JobReport(job: job, progress: progress(job.budget, finished: true))]
        _ = try await server.handle(message, now: 1)
        _ = try await server.handle(message, now: 2)
        let restarted = try Coordinator(config: config, token: token, newRun: false, now: 0)
        let response = try await restarted.handle(message, now: 1)
        XCTAssertTrue(response.retired.contains(job.id))
        let state = try DurableStore(path: config.distributed.stateDirectory + "/server.sqlite").read(CoordinatorState.self)
        XCTAssertEqual(state?.completedJobs, 1)
        XCTAssertTrue(state?.jobs.isEmpty == true)
    }
    func testCheckpointAtBudgetBoundaryNeedsNoFinalMessage() async throws {
        let config = try configuration()
        let server = try Coordinator(config: config, token: String(repeating: "t", count: 32), newRun: true, now: 0)
        var message = request()
        let assigned = try await server.handle(message, now: 0)
        let job = try XCTUnwrap(assigned.jobs.first)
        message.runID = assigned.runID; message.kind = "sync"; message.rates = []
        message.reports = [JobReport(job: job, progress: progress(job.budget, finished: false))]
        let response = try await server.handle(message, now: 1)
        XCTAssertTrue(response.retired.contains(job.id))
        let state = try DurableStore(path: config.distributed.stateDirectory + "/server.sqlite").read(CoordinatorState.self)
        XCTAssertEqual(state?.completedJobs, 1)
    }

    func testCleanReleaseIsImmediate() async throws {
        let config = try configuration()
        let server = try Coordinator(config: config, token: String(repeating: "t", count: 32), newRun: true, now: 0)
        var message = request()
        let assigned = try await server.handle(message, now: 0)
        let original = try XCTUnwrap(assigned.jobs.first)
        message.kind = "goodbye"; message.runID = assigned.runID; message.rates = []
        _ = try await server.handle(message, now: 0.1)
        let next = try await server.handle(request(), now: 0.2)
        XCTAssertEqual(next.jobs.first?.id, original.id)
        XCTAssertEqual(next.jobs.first?.generation, 2)
    }
    func testFailureDoesNotPartiallyCommit() async throws {
        let config = try configuration()
        let server = try Coordinator(config: config, token: String(repeating: "t", count: 32), newRun: true, now: 0)
        var message = request()
        let assigned = try await server.handle(message, now: 0)
        let job = try XCTUnwrap(assigned.jobs.first)
        message.runID = assigned.runID
        var invalid = progress(2); invalid.current = [-1]
        message.reports = [JobReport(job: job, progress: progress(1)), JobReport(job: job, progress: invalid)]
        do { _ = try await server.handle(message, now: 1); XCTFail("Invalid request accepted") } catch {}
        let state = try DurableStore(path: config.distributed.stateDirectory + "/server.sqlite").read(CoordinatorState.self)
        XCTAssertNil(state?.jobs.first?.progress)
    }
    func testServerRestartGraceAndDifferentCoreSpeeds() async throws {
        let config = try configuration()
        let token = String(repeating: "t", count: 32)
        let server = try Coordinator(config: config, token: token, newRun: true, now: 0)
        let slow = try await server.handle(request(rate: 0.01), now: 0)
        let fast = try await server.handle(request(rate: 100), now: 0)
        XCTAssertEqual(slow.jobs.first?.budget, 1)
        XCTAssertEqual(fast.jobs.first?.budget, 200)
        let restarted = try Coordinator(config: config, token: token, newRun: false, now: 1000)
        let grace = try await restarted.handle(request(), now: 1001)
        XCTAssertFalse([slow.jobs.first?.id, fast.jobs.first?.id].contains(grace.jobs.first?.id))
        let recovery = try await restarted.handle(request(), now: 1004)
        XCTAssertEqual(recovery.jobs.first?.id, slow.jobs.first?.id)
    }
    func testBackupAuthenticatedEncryptionAndDuplicateFinalChunk() throws {
        let config = try configuration()
        let key = SymmetricKey(size: .bits256)
        let original = CoordinatorState(config: config)
        let data = try BackupService.encrypt(original, key: key)
        let bytes = key.withUnsafeBytes { Data($0) }
        XCTAssertEqual(try BackupService.decrypt(data, key: bytes).runID, original.runID)
        var corrupt = data; corrupt[corrupt.startIndex] ^= 1
        XCTAssertThrowsError(try BackupService.decrypt(corrupt, key: bytes))
        var receiver = ReplicaReceiver(directory: URL(fileURLWithPath: config.distributed.stateDirectory))
        let chunk = ReplicaChunk(id: UUID(), index: 0, count: 1, digest: digest(data), bytes: data)
        try receiver.accept(chunk)
        try receiver.accept(chunk)
    }
    func testStateDirectoryExclusion() throws {
        let config = try configuration()
        let url = URL(fileURLWithPath: config.distributed.stateDirectory)
        let first = try StateLock(directory: url)
        XCTAssertThrowsError(try StateLock(directory: url))
        withExtendedLifetime(first) {}
    }
    func testFrameBoundsAndPartialFrame() throws {
        var request = WireMessage(kind: "hello")
        request.error = String(repeating: "a", count: WireMessage.maxFrame)
        XCTAssertThrowsError(try encodedFrame(request, allocator: ByteBufferAllocator()))
    }

    func testExpiredPinAndScopedIPv6() throws {
        let config = try configuration()
        let directory = URL(fileURLWithPath: config.distributed.stateDirectory)
        _ = try ServerIdentity(directory: directory, now: Date().addingTimeInterval(-3600), lifetime: 60)
        XCTAssertThrowsError(try PinnedIdentity(path: directory.appendingPathComponent("server-certificate.pem").path))
        XCTAssertNotNil(try numericAddress("fe80::1%1", port: 8443))
        XCTAssertThrowsError(try numericAddress("127.0.0.1%1", port: 8443))
        XCTAssertThrowsError(try numericAddress("example.com", port: 8443))
    }

    func testPartialAndOversizedFrames() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(FrameDecoder()))
        defer { _ = try? channel.finish() }
        let original = request()
        var frame = try encodedFrame(original, allocator: channel.allocator)
        let first = frame.readSlice(length: 3)!
        try channel.writeInbound(first)
        XCTAssertNil(try channel.readInbound(as: WireMessage.self))
        try channel.writeInbound(frame)
        XCTAssertEqual(try channel.readInbound(as: WireMessage.self)?.clientID, original.clientID)
        var oversized = channel.allocator.buffer(capacity: 4)
        oversized.writeInteger(UInt32(WireMessage.maxFrame + 1))
        XCTAssertThrowsError(try channel.writeInbound(oversized))
    }

    func testClientWorkerCompletesAndServerValidates() async throws {
        var config = try configuration()
        config.rowNum = 1; config.colNum = 1
        config.Target = OriginalCondition(Status: [[0]])
        let token = String(repeating: "t", count: 32)
        let server = try Coordinator(config: config, token: token, newRun: true, now: 0)
        var local = config.distributed
        local.stateDirectory += "/client"
        try FileManager.default.createDirectory(atPath: local.stateDirectory, withIntermediateDirectories: true)
        let engine = try ClientEngine(settings: local)
        var message = request(client: await engine.identity())
        let assigned = try await server.handle(message, now: 0)
        try await engine.configure(config, runID: try XCTUnwrap(assigned.runID))
        await engine.setRates(message.rates)
        try await engine.apply(assigned)
        var reports: [JobReport] = []
        for _ in 0..<300 {
            reports = try await engine.reports()
            if reports.first?.progress.finished == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(reports.first?.progress.solved == true)
        message.kind = "sync"; message.runID = assigned.runID; message.reports = reports
        let verified = try await server.handle(message, now: 1)
        XCTAssertTrue(verified.solved)
        try await engine.apply(verified)
        let stopped = await engine.isStopped()
        XCTAssertTrue(stopped)
        let recovered = try ClientEngine(settings: local)
        let recoveredID = await recovered.identity()
        let originalID = await engine.identity()
        XCTAssertEqual(recoveredID, originalID)
        let recoveredReports = try await recovered.reports()
        XCTAssertEqual(recoveredReports.first?.job.id, reports.first?.job.id)
    }

    func testRestoreReconcilesJobsIssuedAfterBackup() async throws {
        let config = try configuration()
        let token = String(repeating: "t", count: 32)
        let server = try Coordinator(config: config, token: token, newRun: true, now: 0)
        _ = try await server.handle(request(), now: 0)
        let snapshot = try XCTUnwrap(DurableStore(path: config.distributed.stateDirectory + "/server.sqlite").read(CoordinatorState.self))
        var survivor = request()
        let later = try await server.handle(survivor, now: 0)
        let missing = try XCTUnwrap(later.jobs.first)
        let key = SymmetricKey(size: .bits256)
        let folder = URL(fileURLWithPath: config.distributed.stateDirectory)
        let backupURL = folder.appendingPathComponent("backup.encrypted")
        let keyURL = folder.appendingPathComponent("key")
        try writePrivate(BackupService.encrypt(snapshot, key: key), to: backupURL)
        try writePrivate(key.withUnsafeBytes { Data($0) }, to: keyURL)
        var restored = config; restored.distributed.stateDirectory += "/restored"
        try restoreBackup(config: restored, backupPath: backupURL.path, keyPath: keyURL.path)
        let replacement = try Coordinator(config: restored, token: token, newRun: false, now: 0)
        survivor.runID = later.runID; survivor.kind = "sync"; survivor.rates = []
        survivor.reports = [JobReport(job: missing, progress: progress(1))]
        let response = try await replacement.handle(survivor, now: 1)
        XCTAssertFalse(response.retired.contains(missing.id))
        let state = try XCTUnwrap(DurableStore(path: restored.distributed.stateDirectory + "/server.sqlite").read(CoordinatorState.self))
        XCTAssertTrue(state.jobs.contains { $0.id == missing.id })
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: restored.distributed.stateDirectory + "/join-token"), encoding: .utf8), token)
    }

    func testTwentyMachineFleetHasBoundedTransfersAndIndependentBudgets() async throws {
        let config = try configuration()
        let server = try Coordinator(config: config, token: String(repeating: "t", count: 32), newRun: true, now: 0)
        var messages: [WireMessage] = []
        var assignments: [WireMessage] = []
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 {
            var message = request()
            message.rates = [0.01, 1.0, 10.0, 100.0].enumerated().map {
                WorkerRate(slot: $0.offset, iterationsPerSecond: $0.element, repairSeconds: 0.15)
            }
            let response = try await server.handle(message, now: 0)
            XCTAssertEqual(response.jobs.map(\.budget), [1, 2, 20, 200])
            XCTAssertLessThan(try encodedFrame(response, allocator: ByteBufferAllocator()).readableBytes, 16_384)
            message.runID = response.runID; message.kind = "sync"
            messages.append(message); assignments.append(response)
        }
        do { _ = try await server.handle(request(), now: 0); XCTFail("Capacity admission failed") } catch {}
        for turn in 1...10 {
            for i in messages.indices {
                // An absent or high-latency client never forms a synchronization barrier.
                if i == 19 { continue }
                messages[i].reports = assignments[i].jobs.map { JobReport(job: $0, progress: progress(0)) }
                let response = try await server.handle(messages[i], now: Double(turn) / 10)
                XCTAssertEqual(response.jobs.map(\.id), assignments[i].jobs.map(\.id))
                XCTAssertLessThan(try encodedFrame(messages[i], allocator: ByteBufferAllocator()).readableBytes, 16_384)
            }
        }
        print("20-machine coordination fixture: \(ProcessInfo.processInfo.systemUptime - started)s; frames <16 KiB (under 17ms serialization at 1 MB/s, excluding latency)")
    }

    func testTLSIPv4AndIPv6AndCertificateRotation() async throws {
        for ip in ["127.0.0.1", "::1"] {
            var config = try configuration()
            config.distributed.address = ip
            let directory = URL(fileURLWithPath: config.distributed.stateDirectory)
            let identity = try ServerIdentity(directory: directory)
            let firstPin = try PinnedIdentity(path: directory.appendingPathComponent("server-certificate.pem").path)
            let coordinator = try Coordinator(config: config, token: String(repeating: "t", count: 32), newRun: true)
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            var binding = config.distributed; binding.port = 0
            let listener = try await startListener(settings: binding, identity: identity, coordinator: coordinator, group: group)
            config.distributed.port = try XCTUnwrap(listener.localAddress?.port)
            config.distributed.certificatePath = directory.appendingPathComponent("server-certificate.pem").path
            let connection = try await ClientConnection.connect(settings: config.distributed, group: group)
            let response = try await connection.request(request())
            XCTAssertNotNil(response.runID)
            var wrongToken = request(); wrongToken.token = "invalid"
            do { _ = try await connection.request(wrongToken); XCTFail("Wrong token accepted") } catch {}
            await connection.close()
            _ = try ServerIdentity(directory: directory)
            let secondPin = try PinnedIdentity(path: config.distributed.certificatePath)
            XCTAssertNotEqual(firstPin.der, secondPin.der)
            let wrong = try await ClientConnection.connect(settings: config.distributed, group: group)
            do { _ = try await wrong.request(request()); XCTFail("Wrong certificate accepted") } catch {}
            await wrong.close()
            try await listener.close().get()
            try await group.shutdownGracefully()
        }
    }
}
