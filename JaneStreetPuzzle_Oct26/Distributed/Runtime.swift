import Foundation
import NIOPosix
import NIOCore
import Crypto
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class ShutdownSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    private var sources: [DispatchSourceSignal] = []
    var requested: Bool { lock.withLock { stopping } }
    init() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.lock.withLock { self?.stopping = true } }
            source.resume(); sources.append(source)
        }
    }
    deinit { for source in sources { source.cancel() } }
}

func readToken(settings: DistributedConfig, server: Bool) throws -> String {
    let path = settings.tokenPath.isEmpty
        ? URL(fileURLWithPath: settings.stateDirectory).appendingPathComponent("join-token")
        : URL(fileURLWithPath: settings.tokenPath)
    if server && !FileManager.default.fileExists(atPath: path.path) {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try writePrivate(Data(bytes.base64EncodedString().utf8), to: path)
    }
    let token = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.utf8.count >= 32 && token.utf8.count <= 1024 else { throw DistributedError.message("Join token must contain 32–1024 UTF-8 bytes.") }
    return token
}

func runServer(config: RunConfig, newRun: Bool) async throws {
    try config.validate(); try config.distributed.validate()
    guard config.rowNum * config.colNum <= 121 else { throw DistributedError.message("Distributed boards are limited to 121 cells.") }
    let directory = URL(fileURLWithPath: config.distributed.stateDirectory)
    let stateLock = try StateLock(directory: directory)
    defer { withExtendedLifetime(stateLock) {} }
    let token = try readToken(settings: config.distributed, server: true)
    let coordinator = try Coordinator(config: config, token: token, newRun: newRun)
    let identity = try ServerIdentity(directory: directory)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let shutdown = ShutdownSignal()
    do {
        let listener = try await startListener(settings: config.distributed, identity: identity, coordinator: coordinator, group: group)
        distributedLog("Coordinator listening on \(String(describing: listener.localAddress)). Run: \(coordinator.runID)")
        distributedLog("Copy public certificate: \(directory.appendingPathComponent("server-certificate.pem").path)")
        distributedLog("Certificate SHA-256: \(identity.fingerprint)")
        distributedLog("Join token file: \(config.distributed.tokenPath.isEmpty ? directory.appendingPathComponent("join-token").path : config.distributed.tokenPath)")
        if config.distributed.backupsEnabled { distributedLog("Save recovery.key separately; encrypted off-server backup is enabled.") }
        var nextStatus = 0.0
        var printedSolution = false
        while !shutdown.requested && listener.isActive {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextStatus {
                let status = await coordinator.status()
                distributedLog("Coordinator status: \(String(decoding: try JSONEncoder().encode(status), as: UTF8.self))")
                if !printedSolution, let winner = status.winner {
                    let candidate = SearchContext(config: config).evaluate(labels: winner)
                    printResult(snapshot: BoardSnapshot(candidate), scores: candidate.scores)
                    printedSolution = true
                }
                nextStatus = now + 15
            }
            try await Task.sleep(for: .seconds(1))
        }
        try await listener.close().get()
        try await group.shutdownGracefully()
    } catch { try? await group.shutdownGracefully(); throw error }
}

func runClient(config: RunConfig) async throws {
    let settings = config.distributed
    try settings.validate()
    guard !settings.certificatePath.isEmpty else { throw DistributedError.message("Set distributed.certificatePath to the copied public server certificate.") }
    _ = try numericAddress(settings.address, port: settings.port)
    let directory = URL(fileURLWithPath: settings.stateDirectory)
    let stateLock = try StateLock(directory: directory)
    defer { withExtendedLifetime(stateLock) {} }
    let token = try readToken(settings: settings, server: false)
    let engine = try ClientEngine(settings: settings)
    let clientID = await engine.identity()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let shutdown = ShutdownSignal()
    var receiver = ReplicaReceiver(directory: directory)
    var connection: ClientConnection?
    var calibrated = false
    var recovered = false
    var replicaID: UUID?
    var replicaIndex: Int?
    var failures = 0
    let maintenance = Task {
        while !Task.isCancelled {
            try await engine.offlineWork()
            try await Task.sleep(for: .seconds(1))
        }
    }
    defer { maintenance.cancel() }
    distributedLog("Client \(clientID): \(settings.workers) worker slots, coordinator \(settings.address) port \(settings.port)")
    do {
        while !shutdown.requested {
            if await engine.isStopped() { break }
            do {
                if connection == nil {
                    let newConnection = try await ClientConnection.connect(settings: settings, group: group)
                    connection = newConnection
                    var hello = WireMessage(kind: "hello", clientID: clientID, token: token)
                    hello.runID = await engine.currentRun()
                    let response = try await newConnection.request(hello)
                    guard let run = response.runID, let puzzle = response.config else { throw DistributedError.message("Missing coordinator puzzle configuration.") }
                    try puzzle.validate()
                    try await engine.configure(puzzle, runID: run)
                    if !calibrated {
                        distributedLog("Calibrating configured worker slots…")
                        await engine.setRates(await calibrate(config: puzzle, settings: settings))
                        calibrated = true
                    }
                    if !recovered { try await engine.recoverLocal(); recovered = true }
                    failures = 0
                    distributedLog("Connected to authenticated coordinator, run \(run)")
                }
                var request = WireMessage(kind: "sync", clientID: clientID, token: token)
                request.runID = await engine.currentRun()
                request.rates = await engine.currentRates()
                request.reports = try await engine.reports()
                request.elites = await engine.supplementalBoards()
                request.replicaAck = replicaID; request.replicaIndexAck = replicaIndex
                let response = try await connection!.request(request)
                if response.kind == "reset", let puzzle = response.config, let run = response.runID {
                    try await engine.configure(puzzle, runID: run)
                } else {
                    try await engine.apply(response)
                    if let chunk = response.replica {
                        try receiver.accept(chunk)
                        replicaID = chunk.id; replicaIndex = chunk.index
                    }
                }
                try await engine.save()
                // One-second local polling saves solutions promptly; network updates
                // are otherwise bounded by heartbeat cadence.
                let until = ProcessInfo.processInfo.systemUptime + (response.replica == nil ? settings.heartbeatSeconds : 1)
                while ProcessInfo.processInfo.systemUptime < until && !shutdown.requested {
                    try await Task.sleep(for: .seconds(1))
                    try await engine.save()
                    if try await engine.reports().contains(where: { $0.progress.finished || $0.progress.solved }) { break }
                }
            } catch {
                if let connection { await connection.close() }
                connection = nil
                failures += 1
                distributedLog("Coordinator unavailable: \(error). Local work/checkpoints continue.")
                if !recovered, let saved = await engine.savedConfig() {
                    if !calibrated { await engine.setRates(await calibrate(config: saved, settings: settings)); calibrated = true }
                    try await engine.recoverLocal(); recovered = true
                }
                let delay = min(60, pow(2, Double(min(failures, 6)))) * Double.random(in: 0.8...1.2)
                let until = ProcessInfo.processInfo.systemUptime + delay
                while ProcessInfo.processInfo.systemUptime < until && !shutdown.requested {
                    try await engine.offlineWork()
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }
        maintenance.cancel()
        _ = try? await maintenance.value
        try await engine.stop()
        if let connection {
            var goodbye = WireMessage(kind: "goodbye", clientID: clientID, token: token)
            goodbye.runID = await engine.currentRun(); goodbye.reports = try await engine.reports()
            _ = try? await connection.request(goodbye)
            await connection.close()
        }
        try await group.shutdownGracefully()
    } catch {
        maintenance.cancel()
        _ = try? await maintenance.value
        try? await engine.stop()
        if let connection { await connection.close() }
        try? await group.shutdownGracefully()
        throw error
    }
}

func restoreBackup(config: RunConfig, backupPath: String, keyPath: String) throws {
    let directory = URL(fileURLWithPath: config.distributed.stateDirectory)
    let stateLock = try StateLock(directory: directory)
    defer { withExtendedLifetime(stateLock) {} }
    guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("server.sqlite").path) else {
        throw DistributedError.message("Restore requires a new state directory; existing state is never overwritten.")
    }
    var state = try BackupService.decrypt(Data(contentsOf: URL(fileURLWithPath: backupPath)), key: Data(contentsOf: URL(fileURLWithPath: keyPath)))
    try state.config.validate()
    // Reserve an allocation range so surviving clients can reconcile manifests
    // issued after this snapshot without confusing them with replacement work.
    state.recoveryFloor = state.serial
    state.serial &+= 1 << 32
    state.reconciled = []
    if let token = state.joinToken {
        let target = config.distributed.tokenPath.isEmpty ? directory.appendingPathComponent("join-token") : URL(fileURLWithPath: config.distributed.tokenPath)
        try writePrivate(Data(token.utf8), to: target)
    }
    try writePrivate(Data(contentsOf: URL(fileURLWithPath: keyPath)), to: directory.appendingPathComponent("recovery.key"))
    for i in state.jobs.indices { state.jobs[i].lastSeen = 0 }
    let store = try DurableStore(path: directory.appendingPathComponent("server.sqlite").path)
    try store.write(state)
    distributedLog("Restored run \(state.runID). Start --server with the same puzzle and distribute its newly generated certificate.")
}
