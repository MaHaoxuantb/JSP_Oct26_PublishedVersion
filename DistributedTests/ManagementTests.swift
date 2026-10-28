import Testing
import Foundation
import NIOPosix
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PuzzleSolver

@Suite(.serialized)
struct ManagementTests {
    let token = String(repeating: "t", count: 32)
    func capable(_ id: UUID = UUID(), slots: Int = 1) -> WireMessage {
        var request = DistributedTests().request(client: id)
        request.telemetry = ClientTelemetry(sessionID: UUID(), controlVersion: 1, capacity: slots, mode: .running,
            capturedAt: Date().timeIntervalSince1970, workers: [], lastError: nil)
        request.rates = (0..<slots).map { WorkerRate(slot: $0, iterationsPerSecond: 5, repairSeconds: 0.15) }
        return request
    }
    func command(_ action: ManagementAction, _ request: WireMessage, _ run: UUID, workers: Int? = nil) -> ManagementRequest {
        ManagementRequest(id: UUID(), runID: run, clientID: request.clientID!, action: action, workers: workers)
    }

    @Test func pauseIsDurableIdempotentAndReleasesUninitializedWorkOnlyAfterAck() async throws {
        let config = try DistributedTests().configuration()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let server = try Coordinator(config: config, token: token, newRun: true, now: 0)
        var request = capable()
        let initial = try await server.handle(request, now: 0)
        let job = try #require(initial.jobs.first)
        let pause = command(.pause, request, initial.runID!)
        _ = try await server.manage(pause)
        _ = try await server.manage(pause)
        let queued = await server.dashboard(now: 1)
        #expect(queued.commands.count == 1 && queued.commands.first?.status == "queued")
        #expect(queued.jobs.first?.status == "assigned")
        let restarted = try Coordinator(config: config, token: token, newRun: false, now: 0)
        request.kind = "sync"; request.runID = initial.runID
        let delivered = try await restarted.handle(request, now: 1)
        #expect(delivered.control?.id == pause.id)
        request.rates = []; request.controlAck = ControlAck(id: pause.id, status: "paused")
        let ack = try await restarted.handle(request, now: 1.1)
        #expect(ack.retired.contains(job.id) && ack.jobs.isEmpty)
        let snapshot = await restarted.dashboard(now: 1.2)
        #expect(snapshot.commands.first?.status == "paused")
        let next = try await restarted.handle(capable(), now: 1.2)
        #expect(next.jobs.first?.id == job.id && next.jobs.first?.generation == 2)
    }

    @Test func drainNeverAllocatesMoreWorkAndQuitCommitsFinalReportBeforeRelease() async throws {
        let helper = DistributedTests(), config = try helper.configuration()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let server = try Coordinator(config: config, token: token, newRun: true, now: 0)
        var request = capable()
        let initial = try await server.handle(request, now: 0)
        let job = try #require(initial.jobs.first)
        let drain = command(.drain, request, initial.runID!)
        _ = try await server.manage(drain)
        request.kind = "sync"; request.runID = initial.runID
        request.controlAck = ControlAck(id: drain.id, status: "draining")
        request.reports = [JobReport(job: job, progress: helper.progress(job.budget, finished: true))]
        let drained = try await server.handle(request, now: 1)
        #expect(drained.jobs.isEmpty && drained.retired.contains(job.id))
        _ = try await server.handle(request, now: 1.1) // Lost response replay.
        let snapshot = await server.dashboard(now: 1.2)
        #expect(snapshot.insights.acceptedIterations == UInt64(job.budget))
        #expect(snapshot.completedJobs == 1)
        #expect(!snapshot.candidates.isEmpty)
        #expect(snapshot.candidates.first?.discovery?.clientID == request.clientID)
        let quit = command(.quit, request, initial.runID!)
        _ = try await server.manage(quit)
        request.controlAck = ControlAck(id: quit.id, status: "stopping")
        _ = try await server.handle(request, now: 1.3)
        request.kind = "goodbye"; request.controlAck?.status = "released"
        _ = try await server.handle(request, now: 1.4)
        let recovered = try Coordinator(config: config, token: token, newRun: false, now: 2)
        let history = await recovered.dashboard(now: 2)
        #expect(history.commands.last?.status == "released")
        #expect(history.insights.acceptedIterations == UInt64(job.budget))
        #expect(history.insights.improvements.count == snapshot.insights.improvements.count)
        request.kind = "hello"; request.reports = []; request.controlAck = nil
        request.telemetry?.sessionID = UUID()
        let manualRelaunch = try await recovered.handle(request, now: 2)
        #expect(manualRelaunch.control == nil && manualRelaunch.jobs.count == 1)
    }

    @Test func resizeReleasesUninitializedExcessSlotsAndRejectsUnsupportedOrStaleCommands() async throws {
        let config = try DistributedTests().configuration()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let server = try Coordinator(config: config, token: token, newRun: true, now: 0)
        var request = capable(slots: 2)
        let initial = try await server.handle(request, now: 0)
        #expect(initial.jobs.count == 2)
        let resize = command(.workers, request, initial.runID!, workers: 1)
        _ = try await server.manage(resize)
        request.kind = "sync"; request.runID = initial.runID
        request.rates = Array(request.rates.prefix(1)); request.controlAck = ControlAck(id: resize.id, status: "running")
        let response = try await server.handle(request, now: 1)
        #expect(response.jobs.count == 1 && response.retired.contains(initial.jobs[1].id))
        do { _ = try await server.manage(command(.workers, request, initial.runID!, workers: 3)); Issue.record("Oversized capacity accepted") } catch {}
        do { _ = try await server.manage(command(.pause, request, UUID())); Issue.record("Wrong run accepted") } catch {}
        let old = DistributedTests().request()
        _ = try await server.handle(old, now: 1)
        do { _ = try await server.manage(command(.quit, old, initial.runID!)); Issue.record("Legacy client accepted") } catch {}
        var reused = resize; reused.action = .quit
        do { _ = try await server.manage(reused); Issue.record("Reused command ID accepted") } catch {}
    }

    @Test func clientPauseSurvivesRestartSuppressesSupplementalWorkAndResumeKeepsBudget() async throws {
        let config = try ClientProgressTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let engine = try ClientEngine(settings: config.distributed, pathEvaluation: .cpu)
        let run = UUID()
        try await engine.configure(config, runID: run)
        await engine.setRates([WorkerRate(slot: 0, iterationsPerSecond: 1, repairSeconds: 0.15)])
        let job = SearchJob(slot: 0, seed: 1, objective: .matches, budget: 1, owner: await engine.identity(), lastSeen: 0, explorer: true)
        var response = WireMessage(kind: "sync"); response.jobs = [job]
        response.control = ClientDirective(mode: .paused)
        try await engine.apply(response)
        try await engine.offlineWork()
        #expect(await engine.telemetry().workers.isEmpty)
        #expect(await engine.currentRates().isEmpty)
        #expect(await engine.controlAck()?.status == "paused")
        let restarted = try ClientEngine(settings: config.distributed, pathEvaluation: .cpu)
        await restarted.setRates([WorkerRate(slot: 0, iterationsPerSecond: 1, repairSeconds: 0.15)])
        try await restarted.recoverLocal(); try await restarted.offlineWork()
        #expect(await restarted.telemetry().workers.isEmpty)
        response.control = ClientDirective(mode: .running)
        try await restarted.apply(response, reconciling: true)
        let report = try await ClientProgressTests().finished(restarted)
        #expect(report.progress.iterations == 1)
        // Replaying the same directive must not restart a finished generation.
        try await restarted.apply(response)
        #expect(try await restarted.reports().first?.progress.iterations == 1)
        try await engine.stop(); try await restarted.stop()
    }

    @Test func quitPreservesPartialProgressAndCheckpointRequestsCannotWaitOnFinishedWorkers() async throws {
        let helper = DistributedTests(), config = try helper.configuration()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let server = try Coordinator(config: config, token: token, newRun: true, now: 0)
        var request = capable()
        let initial = try await server.handle(request, now: 0)
        let job = try #require(initial.jobs.first)
        let quit = command(.quit, request, initial.runID!)
        _ = try await server.manage(quit)
        request.kind = "sync"; request.runID = initial.runID; request.rates = []
        request.reports = [JobReport(job: job, progress: helper.progress(2))]
        request.controlAck = ControlAck(id: quit.id, status: "stopping")
        let response = try await server.handle(request, now: 1)
        #expect(response.jobs.isEmpty && response.retired.contains(job.id))
        let another = try await server.handle(capable(), now: 1.1)
        #expect(another.jobs.first?.id == job.id && another.jobs.first?.completed == 2)
        #expect(another.jobs.first?.generation == 2)
        let bridge = ProgressBridge()
        bridge.requestObservation(); #expect(bridge.needsObservation())
        bridge.update(helper.progress(1)); #expect(!bridge.needsObservation())
        bridge.update(helper.progress(2, finished: true))
        bridge.requestObservation(); #expect(!bridge.needsObservation())
    }

    @Test func crashAfterCommandIntentDoesNotAcknowledgeBeforeExecution() async throws {
        let config = try ClientProgressTests().fixture()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let directive = ClientDirective(mode: .paused, checkpoint: true)
        var disk = ClientDiskState(); disk.runID = UUID(); disk.config = config
        disk.control = directive // Simulate a crash after intent, before capture/commit.
        try DurableStore(path: config.distributed.stateDirectory + "/client.sqlite").write(disk)
        let engine = try ClientEngine(settings: config.distributed, pathEvaluation: .cpu)
        #expect(await engine.controlAck() == nil)
        var response = WireMessage(kind: "sync"); response.control = directive
        try await engine.apply(response)
        #expect(await engine.controlAck()?.id == directive.id)
        let restarted = try ClientEngine(settings: config.distributed, pathEvaluation: .cpu)
        #expect(await restarted.controlAck()?.status == "paused")
        #expect(await restarted.telemetry().workers.isEmpty)
        try await engine.stop(); try await restarted.stop()
    }

    @Test func sameOriginAllowsRemoteAdministrationAndRejectsCrossSiteRequests() {
        #expect(DashboardHTTP.sameOrigin(host: "localhost:9999", origin: "http://localhost:9999"))
        #expect(DashboardHTTP.sameOrigin(host: "192.168.4.173:9999", origin: "http://192.168.4.173:9999"))
        #expect(DashboardHTTP.sameOrigin(host: "puzzle.example", origin: "https://puzzle.example"))
        #expect(!DashboardHTTP.sameOrigin(host: "localhost:9999", origin: "http://evil.example"))
        #expect(!DashboardHTTP.sameOrigin(host: "localhost:9999", origin: nil))
        #expect(!DashboardHTTP.sameOrigin(host: "localhost:9999@evil.example", origin: "http://localhost:9999@evil.example"))
        #expect(!DashboardHTTP.sameOrigin(host: "localhost:9999/path", origin: "http://localhost:9999/path"))
        #expect(!DashboardHTTP.sameOrigin(host: "localhost:99999", origin: "http://localhost:99999"))
    }

    @Test func httpAdministrationRequiresSeparateTokenAndOriginAndBoundsBodies() async throws {
        let config = try DistributedTests().configuration()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let server = try Coordinator(config: config, token: token, newRun: true)
        let client = capable()
        let initial = try await server.handle(client)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var settings = config.distributed; settings.webUIPort = 0
        do {
            let listener = try #require(try await startDashboard(settings: settings, coordinator: server, group: group))
            let base = "http://127.0.0.1:\(try #require(listener.localAddress?.port))"
            let admin = try dashboardAdminToken(directory: settings.stateDirectory)
            #expect(admin != token)
            func post(_ supplied: String, origin: String?, host: String? = nil, body: Data) async throws -> Int? {
                var request = URLRequest(url: URL(string: base + "/api/commands")!)
                request.httpMethod = "POST"; request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer " + supplied, forHTTPHeaderField: "Authorization")
                if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
                if let host { request.setValue(host, forHTTPHeaderField: "Host") }
                let (_, response) = try await session.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode
            }
            let body = try JSONEncoder().encode(command(.pause, client, initial.runID!))
            #expect(try await post(token, origin: base, body: body) == 403)
            #expect(try await post(admin, origin: "http://evil.example", body: body) == 403)
            #expect(try await post(admin, origin: nil, body: body) == 403)
            #expect(try await post(admin, origin: "http://192.168.4.173:9999", host: "192.168.4.173:9999", body: body) == 202)
            #expect(try await post(admin, origin: base, body: body) == 202)
            #expect(try await post(admin, origin: base, body: Data("{}".utf8)) == 400)
            #expect(try await post(admin, origin: base, body: Data(repeating: 65, count: 5000)) == 413)
            let snapshot = await server.dashboard()
            let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
            #expect(snapshot.commands.count == 1)
            #expect(!encoded.contains(admin) && !encoded.contains(token))
            try await listener.close().get(); try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}
