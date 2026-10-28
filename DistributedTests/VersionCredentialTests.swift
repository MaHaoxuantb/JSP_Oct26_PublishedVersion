import Testing
import Foundation
@testable import PuzzleSolver

@Suite(.serialized)
struct VersionCredentialTests {
    @Test func versionGateRejectsBeforeMutatingAssignmentsAndSupportsExplicitLegacy() async throws {
        let helper = DistributedTests()
        var config = try helper.configuration()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let token = String(repeating: "t", count: 32)
        let server = try Coordinator(config: config, token: token, newRun: true, now: 0)
        var message = helper.request()
        let response = try await server.handle(message, now: 0)
        #expect(response.softwareVersion == SoftwareVersion.current)
        let before = await server.dashboard(now: 0)
        for version in [nil, 0, SoftwareVersion.current + 1, -1] as [Int?] {
            message.softwareVersion = version
            do { _ = try await server.handle(message, now: 1); Issue.record("Incompatible worker accepted") }
            catch { #expect(String(describing: error).contains("Software version rejected")) }
            let after = await server.dashboard(now: 1)
            #expect(after.jobs.map(\.id) == before.jobs.map(\.id))
            #expect(after.clients.first?.lastSeenSeconds == 1)
        }
        message.softwareVersion = SoftwareVersion.current
        let json = try JSONEncoder().encode(message)
        var legacy = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        legacy.removeValue(forKey: "softwareVersion")
        let decoded = try JSONDecoder().decode(WireMessage.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.softwareVersion == nil)
        config.distributed.minimumPeerVersion = 0
        let transition = try Coordinator(config: config, token: token, newRun: false, now: 10)
        _ = try await transition.handle(decoded, now: 10)
        let compatible = await transition.dashboard(now: 10)
        #expect(compatible.runID == before.runID)
        #expect(compatible.minimumPeerVersion == 0)
        #expect(compatible.clients.first?.info?.softwareVersion == nil)
        _ = try await transition.handle(message, now: 11)
        let current = await transition.dashboard(now: 11)
        #expect(current.clients.first?.info?.softwareVersion == SoftwareVersion.current)
    }

    @Test func credentialsRequireExplicitSetupAndPersistAcrossRestartsAndCustomPaths() throws {
        let config = try DistributedTests().configuration()
        let directory = URL(fileURLWithPath: config.distributed.stateDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = config.distributed
        settings.certificatePath = directory.appendingPathComponent("custom-public.pem").path
        settings.privateKeyPath = directory.appendingPathComponent("custom-private.pem").path
        settings.tokenPath = directory.appendingPathComponent("custom-token").path
        #expect(settings.credentialMode == .reuse)
        #expect(throws: (any Error).self) { try serverCredentials(settings: settings) }
        #expect(!FileManager.default.fileExists(atPath: settings.serverCertificateURL.path))
        settings.credentialMode = .initialize
        let (first, token) = try serverCredentials(settings: settings)
        let key = try Data(contentsOf: settings.serverPrivateKeyURL)
        settings.credentialMode = .reuse
        let (restarted, reusedToken) = try serverCredentials(settings: settings)
        #expect(first.certificate == restarted.certificate && first.fingerprint == restarted.fingerprint)
        #expect(token == reusedToken)
        #expect(try Data(contentsOf: settings.serverPrivateKeyURL) == key)
        let permissions = try FileManager.default.attributesOfItem(atPath: settings.serverPrivateKeyURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        settings.credentialMode = .initialize
        let (initializedAgain, sameToken) = try serverCredentials(settings: settings)
        #expect(initializedAgain.fingerprint == first.fingerprint && sameToken == token)
        settings.credentialMode = .rotate
        let (rotated, newToken) = try serverCredentials(settings: settings)
        #expect(rotated.fingerprint != first.fingerprint && newToken != token)
        settings.credentialMode = .reuse
        #expect(try serverCredentials(settings: settings).0.fingerprint == rotated.fingerprint)
    }

    @Test func invalidOrPartialCredentialsNeverSilentlyRotateOrChangeTokens() throws {
        let config = try DistributedTests().configuration()
        let directory = URL(fileURLWithPath: config.distributed.stateDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = config.distributed; settings.credentialMode = .initialize
        let (identity, token) = try serverCredentials(settings: settings)
        let originalKey = try Data(contentsOf: settings.serverPrivateKeyURL)
        try FileManager.default.removeItem(at: settings.serverPrivateKeyURL)
        for mode: CredentialMode in [.reuse, .initialize] {
            settings.credentialMode = mode
            #expect(throws: (any Error).self) { try serverCredentials(settings: settings) }
            #expect(try Data(contentsOf: settings.serverCertificateURL) == identity.certificate)
            #expect(try readToken(settings: settings) == token)
        }
        let otherKey = try ServerIdentity.generate().key
        try otherKey.write(to: settings.serverPrivateKeyURL)
        #expect(throws: (any Error).self) { try serverCredentials(settings: settings) }
        #expect(try Data(contentsOf: settings.serverPrivateKeyURL) == otherKey)
        try originalKey.write(to: settings.serverPrivateKeyURL)
        try Data("short".utf8).write(to: settings.joinTokenURL)
        #expect(throws: (any Error).self) { try serverCredentials(settings: settings) }
        #expect(try Data(contentsOf: settings.serverCertificateURL) == identity.certificate)
        settings.credentialMode = .rotate; settings.tokenPath = settings.certificatePath.isEmpty ? settings.serverCertificateURL.path : settings.certificatePath
        #expect(throws: (any Error).self) { try serverCredentials(settings: settings) }
    }

    @Test func failedCredentialRotationRollsBackPreviouslyWrittenFiles() throws {
        let config = try DistributedTests().configuration()
        let directory = URL(fileURLWithPath: config.distributed.stateDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = config.distributed; settings.credentialMode = .initialize
        let (identity, token) = try serverCredentials(settings: settings)
        let key = try Data(contentsOf: settings.serverPrivateKeyURL)
        settings.credentialMode = .rotate
        settings.tokenPath = directory.appendingPathComponent("missing-parent/token").path
        #expect(throws: (any Error).self) { try serverCredentials(settings: settings) }
        #expect(try Data(contentsOf: settings.serverCertificateURL) == identity.certificate)
        #expect(try Data(contentsOf: settings.serverPrivateKeyURL) == key)
        settings.tokenPath = ""; settings.credentialMode = .reuse
        #expect(try serverCredentials(settings: settings).1 == token)
    }

    @Test func oldSavedInsightsDecodeAndEnergyHistorySurvivesRestart() async throws {
        let old = #"{"since":1,"acceptedIterations":0,"discoveries":{},"improvements":[],"throughput":[{"at":1,"rate":2}],"events":[]}"#
        let decoded = try JSONDecoder().decode(SearchInsights.self, from: Data(old.utf8))
        #expect(decoded.energy == nil && decoded.throughput.first?.iterations == nil)
        let helper = DistributedTests(), config = try helper.configuration()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let token = String(repeating: "t", count: 32)
        let server = try Coordinator(config: config, token: token, newRun: true)
        var message = helper.request()
        let initial = try await server.handle(message)
        let job = try #require(initial.jobs.first)
        message.kind = "sync"; message.runID = initial.runID
        message.reports = [JobReport(job: job, progress: helper.progress(1))]
        _ = try await server.handle(message)
        let before = await server.dashboard()
        #expect(before.insights.energy?.isEmpty == false)
        let recovered = try Coordinator(config: config, token: token, newRun: false)
        let after = await recovered.dashboard()
        #expect(after.insights.energy?.map(\.total) == before.insights.energy?.map(\.total))
        #expect(after.insights.energy?.map(\.residual) == before.insights.energy?.map(\.residual))
    }

    @Test func residualHistoryImprovesIndependentlyOfBestBoardAndTotalEnergy() async throws {
        var config = try DistributedTests().configuration()
        config.rowNum = 3; config.colNum = 3
        config.Target = OriginalCondition(Status: [[3,1,0],[-1,1,-1],[1,0,0]])
        config.pathEvaluation = .cpu
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        let server = try Coordinator(config: config, token: String(repeating: "t", count: 32), newRun: true)
        var message = DistributedTests().request()
        let initial = try await server.handle(message)
        let job = try #require(initial.jobs.first)
        message.kind = "sync"; message.runID = initial.runID
        let valid = [0,0,0,0,1,1,0,1,1]
        let lowerResidual = [0,1,1,0,1,2,0,0,2]
        func report(_ labels: [Int], iterations: Int) -> JobReport {
            JobReport(job: job, progress: DistributedProgress(current: labels, best: labels,
                iterations: iterations, seconds: Double(iterations), finished: false, solved: false))
        }
        message.reports = [report(valid, iterations: 1)]
        _ = try await server.handle(message)
        let first = await server.dashboard()
        message.reports = [report(lowerResidual, iterations: 2)]
        _ = try await server.handle(message)
        let next = await server.dashboard()
        #expect(next.candidates.first?.id == first.candidates.first?.id, "The valid board remains the quality leader")
        #expect(next.insights.improvements.count == first.insights.improvements.count)
        let history = try #require(next.insights.energy)
        #expect(history.count == 2)
        #expect(history[1].total == history[0].total)
        #expect(history[1].residual < history[0].residual)
        #expect(abs(history[1].residual - 0.7952380952380952) < 1e-12)
        _ = try await server.handle(message) // Retries cannot create a new improvement.
        let replay = await server.dashboard()
        #expect(replay.insights.energy?.count == 2)
    }

    @Test func expiredIdentityFailsClosedWithoutReplacingFiles() throws {
        let config = try DistributedTests().configuration()
        let directory = URL(fileURLWithPath: config.distributed.stateDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try ServerIdentity(generatingIn: directory, now: Date().addingTimeInterval(-3600), lifetime: 60)
        try Data(String(repeating: "t", count: 32).utf8).write(to: config.distributed.joinTokenURL)
        #expect(throws: (any Error).self) { try serverCredentials(settings: config.distributed) }
        #expect(try Data(contentsOf: config.distributed.serverCertificateURL) == identity.certificate)
    }


    @Test func credentialPathsCannotOverwriteRunStateOrReuseAdminSecrets() throws {
        let config = try DistributedTests().configuration()
        let directory = URL(fileURLWithPath: config.distributed.stateDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = config.distributed; settings.credentialMode = .initialize
        let (identity, token) = try serverCredentials(settings: settings)
        settings.credentialMode = .rotate
        for name in ["server.sqlite", "process.lock", "web-admin-token", "recovery.key"] {
            let reserved = directory.appendingPathComponent(name)
            let sentinel = Data("original protected state".utf8)
            try sentinel.write(to: reserved)
            settings.tokenPath = reserved.path
            #expect(throws: (any Error).self) { try serverCredentials(settings: settings) }
            #expect(try Data(contentsOf: reserved) == sentinel)
            #expect(try Data(contentsOf: settings.serverCertificateURL) == identity.certificate)
        }
        settings.tokenPath = ""; settings.credentialMode = .reuse
        #expect(try serverCredentials(settings: settings).1 == token)
    }

}
