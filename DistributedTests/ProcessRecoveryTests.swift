import XCTest
import Foundation
import NIOCore
import NIOPosix
@testable import PuzzleSolver
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class ProcessRecoveryTests: XCTestCase, @unchecked Sendable {
    func waitFor(_ description: String, seconds: Double = 20, _ condition: () throws -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < until {
            if (try? condition()) == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DistributedError.message("Timed out waiting for \(description)")
    }
    func testHardClientLossServerRestartAndCleanRelease() async throws {
        let bundle = Bundle(for: Self.self).bundleURL
        let candidates = [bundle.deletingLastPathComponent().appendingPathComponent("janestreet-puzzle"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/release/janestreet-puzzle")]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("Build the executable alongside the test bundle to run process recovery checks.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("puzzle-process-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let probe = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(probe.localAddress?.port)
        try await probe.close().get(); try await group.shutdownGracefully()
        var config = RunConfig.example
        config.rowNum = 1; config.colNum = 1
        config.Target = OriginalCondition(Status: [[1]])
        config.distributed.port = port
        config.distributed.clientWorkers = 1
        config.distributed.heartbeatSeconds = 1
        config.distributed.checkpointSeconds = 1
        config.distributed.failureGraceSeconds = 3
        config.distributed.calibrationSeconds = 0.05
        config.distributed.jobSeconds = 60
        config.distributed.stateDirectory = directory.appendingPathComponent("server").path
        let serverConfig = directory.appendingPathComponent("server.json")
        try JSONEncoder().encode(config).write(to: serverConfig)
        var processes: [Process] = []
        defer { for process in processes where process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
        func launch(_ role: String, _ path: URL) throws -> Process {
            let process = Process()
            process.executableURL = executable
            process.arguments = [role, "full", "--config", path.path]
            let output = directory.appendingPathComponent("process-\(processes.count).log")
            _ = FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            process.standardOutput = handle; process.standardError = handle
            try process.run(); processes.append(process)
            try handle.close()
            return process
        }
        let server = try launch("--server", serverConfig)
        let serverDirectory = URL(fileURLWithPath: config.distributed.stateDirectory)
        let certificate = serverDirectory.appendingPathComponent("server-certificate.pem")
        try await waitFor("server certificate") { FileManager.default.fileExists(atPath: certificate.path) }
        let originalCertificate = try Data(contentsOf: certificate)
        func clientConfiguration(_ name: String) throws -> URL {
            var client = config
            let folder = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            client.distributed.stateDirectory = folder.path
            client.distributed.certificatePath = folder.appendingPathComponent("certificate.pem").path
            client.distributed.tokenPath = folder.appendingPathComponent("join-token").path
            try Data(contentsOf: certificate).write(to: URL(fileURLWithPath: client.distributed.certificatePath))
            try Data(contentsOf: serverDirectory.appendingPathComponent("join-token")).write(to: URL(fileURLWithPath: client.distributed.tokenPath))
            let path = directory.appendingPathComponent(name + ".json")
            try JSONEncoder().encode(client).write(to: path)
            return path
        }
        func serverState() throws -> CoordinatorState? {
            try DurableStore(path: serverDirectory.appendingPathComponent("server.sqlite").path).read(CoordinatorState.self)
        }
        let firstClient = try launch("--client", clientConfiguration("client-a"))
        try await waitFor("first durable assignment") { try serverState()?.jobs.isEmpty == false }
        let firstState = try XCTUnwrap(serverState())
        let originalJob = try XCTUnwrap(firstState.jobs.first)
        _ = kill(firstClient.processIdentifier, SIGKILL)
        try await waitFor("hard client exit") { !firstClient.isRunning }
        try await Task.sleep(for: .seconds(4))
        let secondConfig = try clientConfiguration("client-b")
        let secondClient = try launch("--client", secondConfig)
        try await waitFor("job transfer to replacement client") {
            try serverState()?.jobs.contains { $0.id == originalJob.id && $0.owner != originalJob.owner && $0.generation > originalJob.generation } == true
        }
        _ = kill(server.processIdentifier, SIGKILL)
        try await waitFor("hard server exit") { !server.isRunning }
        let restarted = try launch("--server", serverConfig)
        try await waitFor("rotated server identity") { try Data(contentsOf: certificate) != originalCertificate }
        let reconnectAfter = ProcessInfo.processInfo.systemUptime
        try Data(contentsOf: certificate).write(to: directory.appendingPathComponent("client-b/certificate.pem"), options: .atomic)
        try await waitFor("authenticated client reconnection", seconds: 30) {
            // The recovered job may legitimately finish before this poll. Any
            // renewed assignment from this client proves authenticated recovery.
            try serverState()?.jobs.contains { $0.owner != originalJob.owner && $0.lastSeen > reconnectAfter } == true
        }
        XCTAssertTrue(secondClient.isRunning)
        XCTAssertEqual(try serverState()?.runID, firstState.runID)
        secondClient.terminate()
        try await waitFor("clean client exit", seconds: 30) { !secondClient.isRunning }
        XCTAssertEqual(secondClient.terminationStatus, 0)
        XCTAssertTrue(try serverState()?.jobs.allSatisfy { $0.lastSeen < -1e50 } == true)
        restarted.terminate()
        try await waitFor("clean server exit") { !restarted.isRunning }
        XCTAssertEqual(restarted.terminationStatus, 0)
    }
}
