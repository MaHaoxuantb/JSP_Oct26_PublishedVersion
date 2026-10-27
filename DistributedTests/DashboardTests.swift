import Testing
import Foundation
import NIOCore
import NIOPosix
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PuzzleSolver

@Suite(.serialized)
struct DashboardTests {
    @Test func configurationDefaultsAndOverrides() throws {
        let defaults = try JSONDecoder().decode(DistributedConfig.self, from: Data("{}".utf8))
        #expect(defaults.webUIEnabled && defaults.webUIAddress == "127.0.0.1" && defaults.webUIPort == 8080)
        let settings = try JSONDecoder().decode(DistributedConfig.self,
            from: Data(#"{"webUIAddress":"::1","webUIPort":9090,"webUIEnabled":true}"#.utf8))
        try settings.validate()
        #expect(settings.webUIAddress == "::1" && settings.webUIPort == 9090)
        var invalid = settings
        invalid.webUIPort = invalid.port
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.webUIPort = 65536
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.webUIEnabled = false
        try invalid.validate()
        let roundTrip = try JSONDecoder().decode(DistributedConfig.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.webUIPort == 9090)
    }

    @Test func snapshotTracksProgressExpiryAndRecoveryWithoutSecrets() async throws {
        let helper = DistributedTests()
        let config = try helper.configuration()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let token = String(repeating: "t", count: 32)
        let server = try Coordinator(config: config, token: token, newRun: true, now: 0)
        var message = helper.request()
        let response = try await server.handle(message, now: 0)
        let job = try #require(response.jobs.first)
        message.kind = "sync"; message.runID = response.runID
        message.reports = [JobReport(job: job, progress: helper.progress(2))]
        _ = try await server.handle(message, now: 1)
        let live = await server.dashboard(now: 2)
        #expect(live.clients.first?.connected == true)
        #expect(live.jobs.first?.completed == 2 && live.jobs.first?.budget == job.budget)
        #expect(live.jobs.first?.status == "assigned")
        let expired = await server.dashboard(now: 5)
        #expect(expired.clients.first?.connected == false)
        #expect(expired.jobs.first?.status == "awaiting reassignment")
        let json = String(decoding: try JSONEncoder().encode(live), as: UTF8.self)
        #expect(!json.contains(token) && !json.contains("joinToken") && !json.contains("stateDirectory"))
        let recovered = try Coordinator(config: config, token: token, newRun: false, now: 100)
        let reconnecting = await recovered.dashboard(now: 101)
        #expect(reconnecting.jobs.first?.status == "reconnecting")
        #expect(reconnecting.jobs.first?.completed == 2)
        message.kind = "goodbye"; message.rates = []; message.reports = []
        _ = try await recovered.handle(message, now: 101)
        let released = await recovered.dashboard(now: 101)
        #expect(released.jobs.first?.status == "awaiting reassignment")
        let next = try await recovered.handle(helper.request(), now: 102)
        let reassigned = await recovered.dashboard(now: 102)
        #expect(reassigned.reassignments == 1)
        #expect(reassigned.jobs.first?.generation == next.jobs.first?.generation)
        #expect(reassigned.jobs.first?.completed == 2)
    }

    @Test func httpListenerServesStatusAndRejectsMutations() async throws {
        let config = try DistributedTests().configuration()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let server = try Coordinator(config: config, token: String(repeating: "t", count: 32), newRun: true)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var settings = config.distributed
        settings.webUIPort = 0 // Ask the OS for an isolated test port.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let listener = try #require(try await startDashboard(settings: settings, coordinator: server, group: group))
            let port = try #require(listener.localAddress?.port)
            let base = "http://127.0.0.1:\(port)"
            let (html, page) = try await session.data(from: #require(URL(string: base + "/")))
            #expect((page as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: html, as: UTF8.self).contains("<title>JSP_Oct26</title>"))
            let (json, status) = try await session.data(from: #require(URL(string: base + "/api/status")))
            let snapshot = try JSONDecoder().decode(DashboardSnapshot.self, from: json)
            #expect(snapshot.jobs.isEmpty && snapshot.clients.isEmpty)
            #expect((status as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            var mutation = URLRequest(url: try #require(URL(string: base + "/api/status")))
            mutation.httpMethod = "POST"
            let (_, rejected) = try await session.data(for: mutation)
            #expect((rejected as? HTTPURLResponse)?.statusCode == 405)
            let (_, missing) = try await session.data(from: #require(URL(string: base + "/missing")))
            #expect((missing as? HTTPURLResponse)?.statusCode == 404)
            settings.webUIEnabled = false
            let disabled = try await startDashboard(settings: settings, coordinator: server, group: group)
            #expect(disabled == nil)
            try await listener.close().get()
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}
