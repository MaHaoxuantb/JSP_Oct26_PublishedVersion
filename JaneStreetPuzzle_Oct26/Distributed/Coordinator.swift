import Foundation

/// Entire mutations (including durable commits) run serially, without actor
/// reentrancy between validating an owner and acknowledging its state update.
final class Coordinator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "puzzle.coordinator", qos: .utility)
    private let store: DurableStore
    private var state: CoordinatorState
    private let settings: DistributedConfig
    private let token: String
    private var clients: [UUID: Double] = [:]
    private var archive: [(labels: [Int], quality: SearchQuality, residual: Double)] = []
    private let scorer: SearchContext
    private let backup: BackupService?

    init(config: RunConfig, token: String, newRun: Bool, now: Double = ProcessInfo.processInfo.systemUptime) throws {
        settings = config.distributed
        self.token = token
        store = try DurableStore(path: URL(fileURLWithPath: settings.stateDirectory).appendingPathComponent("server.sqlite").path)
        if !newRun, let saved = try store.read(CoordinatorState.self) {
            guard saved.config.rowNum == config.rowNum, saved.config.colNum == config.colNum,
                  saved.config.Target.Status == config.Target.Status else {
                throw DistributedError.message("Recovered puzzle differs from configuration; use --new-run explicitly.")
            }
            state = saved
        } else { state = CoordinatorState(config: config) }
        state.joinToken = token
        // Old monotonic timestamps are meaningless after a machine reboot.
        for i in state.jobs.indices where state.jobs[i].lastSeen != -1e100 { state.jobs[i].lastSeen = now }
        var scoringConfig = state.config
        scoringConfig.pathEvaluation = .cpu
        scorer = SearchContext(config: scoringConfig)
        backup = settings.backupsEnabled ? try BackupService(directory: URL(fileURLWithPath: settings.stateDirectory), settings: settings) : nil
        for labels in state.elites { _ = try consider(labels) }
        try store.write(state)
    }

    var runID: UUID { state.runID } // Read only during startup before accepting connections.

    /// A compact, read-only view, captured on the same queue as assignment commits.
    /// Never serialize CoordinatorState: it contains the join token and private paths.
    func dashboard(now: Double = ProcessInfo.processInfo.systemUptime) async -> DashboardSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                let jobs = self.state.jobs.sorted { $0.ordinal < $1.ordinal }.map { job in
                    DashboardJob(id: job.id, clientID: job.owner, slot: job.slot,
                        generation: job.generation, objective: job.objective.rawValue, explorer: job.explorer,
                        status: self.state.solved ? "stopped" :
                            (now - job.lastSeen >= self.settings.failureGraceSeconds ? "awaiting reassignment" :
                                (self.clients[job.owner] == nil ? "reconnecting" : "assigned")),
                        completed: job.completed + (job.progress?.iterations ?? 0), budget: job.budget,
                        reportedSeconds: job.progress?.seconds ?? 0)
                }
                let ids = Set(self.clients.keys).union(self.state.jobs.map(\.owner))
                let clients = ids.sorted { $0.uuidString < $1.uuidString }.map { id in
                    let age = self.clients[id].map { max(0, now - $0) }
                    return DashboardClient(id: id, connected: age.map { $0 < self.settings.failureGraceSeconds } ?? false,
                        lastSeenSeconds: age, assignedJobs: jobs.filter { $0.clientID == id }.count)
                }
                continuation.resume(returning: DashboardSnapshot(runID: self.state.runID,
                    solved: self.state.solved, completedJobs: self.state.completedJobs,
                    reassignments: self.state.reassignments,
                    backupAgeSeconds: self.backup?.lastComplete.map { max(0, now - $0) },
                    clients: clients, jobs: jobs))
            }
        }
    }

    func status(now: Double = ProcessInfo.processInfo.systemUptime) async -> CoordinatorStatus {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: CoordinatorStatus(runID: self.state.runID,
                    activeJobs: self.state.solved ? 0 : self.state.jobs.count,
                    completedJobs: self.state.completedJobs, reassignments: self.state.reassignments,
                    connectedClients: self.clients.values.filter { now - $0 < self.settings.failureGraceSeconds }.count,
                    solved: self.state.solved, backupAgeSeconds: self.backup?.lastComplete.map { max(0, now - $0) },
                    winner: self.state.winner))
            }
        }
    }

    func handle(_ request: WireMessage, now: Double = ProcessInfo.processInfo.systemUptime) async throws -> WireMessage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let previous = self.state
                let previousArchive = self.archive
                let previousClients = self.clients
                do { continuation.resume(returning: try self.process(request, now: now)) }
                catch {
                    self.state = previous; self.archive = previousArchive; self.clients = previousClients
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Only fixed-size board evaluation and the independent validator; never search.
    private func consider(_ input: [Int]) throws -> Bool {
        guard validLabels(input, config: state.config) else { throw DistributedError.message("Invalid board labels.") }
        let labels = canonicalLabels(input)
        if archive.contains(where: { $0.labels == labels }) { return false }
        let candidate = scorer.evaluate(labels: labels)
        let exact = ExactValidator().validate(candidate.board, target: state.config.Target)
        let quality = SearchQuality(exact, candidate.scores)
        archive.append((labels, quality, candidate.scores.realAIM))
        archive.sort { $0.quality < $1.quality }
        if archive.count > state.config.eliteCapacity {
            var selected = [archive.removeFirst()]
            if state.config.eliteCapacity > 1, let residual = archive.indices.min(by: { archive[$0].residual < archive[$1].residual }) {
                selected.append(archive.remove(at: residual))
            }
            while selected.count < state.config.eliteCapacity && !archive.isEmpty {
                let index = archive.indices.max { a, b in
                    let da = selected.map { distance(archive[a].labels, $0.labels) }.min() ?? 0
                    let db = selected.map { distance(archive[b].labels, $0.labels) }.min() ?? 0
                    return da < db
                }!
                selected.append(archive.remove(at: index))
            }
            archive = selected.sorted { $0.quality < $1.quality }
        }
        state.elites = archive.map(\.labels)
        if exact.valid { state.solved = true; state.winner = labels }
        return exact.valid
    }

    private func distance(_ a: [Int], _ b: [Int]) -> Int {
        var result = 0
        let cols = state.config.colNum
        for i in a.indices {
            if i % cols + 1 < cols && (a[i] == a[i+1]) != (b[i] == b[i+1]) { result += 1 }
            if i + cols < a.count && (a[i] == a[i+cols]) != (b[i] == b[i+cols]) { result += 1 }
        }
        return result
    }

    private func process(_ request: WireMessage, now: Double) throws -> WireMessage {
        guard request.version == WireMessage.version, request.token == token, let client = request.clientID,
              ["hello", "sync", "goodbye"].contains(request.kind) else {
            throw DistributedError.message("Authentication or protocol version rejected.")
        }
        clients = clients.filter { now - $0.value < settings.failureGraceSeconds }
        guard clients[client] != nil || clients.count < settings.maxClients else {
            throw DistributedError.message("Coordinator is at client capacity; retry later.")
        }
        guard request.rates.count <= settings.maxWorkersPerClient,
              Set(request.rates.map(\.slot)).count == request.rates.count,
              request.rates.allSatisfy({ $0.slot >= 0 && $0.slot < settings.maxWorkersPerClient
                && $0.iterationsPerSecond.isFinite && $0.iterationsPerSecond > 0
                && $0.repairSeconds.isFinite && $0.repairSeconds > 0 }),
              request.reports.count <= settings.maxWorkersPerClient else {
            throw DistributedError.message("Invalid worker capacity report.")
        }
        if let run = request.runID, run != state.runID {
            var response = WireMessage(kind: "reset")
            response.runID = state.runID; response.config = state.config; response.solved = state.solved
            return response
        }
        clients[client] = now
        // Expired assignments remain recorded and eligible; never delete work on timeout.
        var response = WireMessage(kind: "sync")
        response.runID = state.runID
        if request.kind == "hello" { response.config = state.config }
        guard request.elites.count <= state.config.eliteCapacity else { throw DistributedError.message("Too many supplemental boards.") }
        for labels in request.elites { _ = try consider(labels) }
        for report in request.reports {
            guard report.job.owner == client, report.progress.iterations >= 0,
                  report.progress.seconds.isFinite && report.progress.seconds >= 0,
                  validLabels(report.progress.current, config: state.config),
                  validLabels(report.progress.best, config: state.config) else {
                throw DistributedError.message("Malformed progress report.")
            }
            _ = try consider(report.progress.best)
            // A client may hold a durable manifest issued after the restored
            // periodic backup. Trusted clients can return that missing work.
            if let floor = state.recoveryFloor, report.job.ordinal > floor,
               report.job.ordinal < floor &+ (1 << 32),
               !state.reconciled.contains(report.job.id), !state.jobs.contains(where: { $0.id == report.job.id }) {
                guard report.job.budget > 0 && report.job.budget <= 1_000_000,
                      report.job.completed >= 0 && report.job.completed <= report.job.budget,
                      report.job.slot >= 0 && report.job.slot < settings.maxWorkersPerClient else {
                    throw DistributedError.message("Invalid recovered job manifest.")
                }
                var recovered = report.job; recovered.lastSeen = now
                recovered.progress = nil
                state.jobs.append(recovered); state.reconciled.append(recovered.id)
            }
            guard let i = state.jobs.firstIndex(where: { $0.id == report.job.id }),
                  state.jobs[i].generation == report.job.generation, state.jobs[i].owner == client else {
                response.retired.append(report.job.id); continue
            }
            // The client reports cumulative effort for this assignment generation.
            guard report.progress.iterations >= (state.jobs[i].progress?.iterations ?? 0),
                  report.progress.iterations <= state.jobs[i].budget - state.jobs[i].completed else {
                throw DistributedError.message("Progress is outside the assigned budget.")
            }
            state.jobs[i].progress = report.progress
            state.jobs[i].lastSeen = now
            if report.progress.iterations >= state.jobs[i].budget - state.jobs[i].completed {
                state.jobs.remove(at: i); state.completedJobs &+= 1
                response.retired.append(report.job.id)
            } else if report.release || request.kind == "goodbye" {
                state.jobs[i].lastSeen = -1e100
            }
        }
        if request.kind == "goodbye" {
            // Clean quit releases all ownership, even a slot with no initialized board yet.
            for i in state.jobs.indices where state.jobs[i].owner == client { state.jobs[i].lastSeen = -1e100 }
            clients.removeValue(forKey: client)
        } else if !state.solved {
            for rate in request.rates {
                if let job = state.jobs.first(where: { $0.owner == client && $0.slot == rate.slot
                    && now - $0.lastSeen < settings.failureGraceSeconds }) {
                    response.jobs.append(job); continue
                }
                let index = state.jobs.firstIndex(where: { now - $0.lastSeen >= settings.failureGraceSeconds })
                if let index {
                    let previous = state.jobs[index].progress
                    state.jobs[index].completed += previous?.iterations ?? 0
                    state.jobs[index].generation += 1
                    state.jobs[index].owner = client; state.jobs[index].slot = rate.slot
                    state.jobs[index].lastSeen = now
                    state.jobs[index].seed = randomSeed()
                    if var progress = previous { progress.iterations = 0; progress.seconds = 0; progress.finished = false
                        state.jobs[index].progress = progress }
                    state.reassignments &+= 1
                    response.jobs.append(state.jobs[index])
                } else {
                    state.serial &+= 1
                    var job = SearchJob(ordinal: state.serial, slot: rate.slot, seed: randomSeed(),
                        objective: SearchObjective.allCases[Int(state.serial % UInt64(SearchObjective.allCases.count))],
                        budget: max(1, min(1_000_000, Int(min(1_000_000, rate.iterationsPerSecond * settings.jobSeconds)))),
                        owner: client, lastSeen: now, explorer: state.serial % 4 == 0)
                    if !job.explorer, let labels = state.elites.randomElement() {
                        job.progress = DistributedProgress(current: labels, best: labels, iterations: 0, seconds: 0, finished: false, solved: false)
                    }
                    state.jobs.append(job); response.jobs.append(job)
                }
            }
        }
        response.elites = state.elites
        response.solved = state.solved
        // Include all known client jobs in expiry renewal, even if initialization is slow.
        for i in state.jobs.indices where state.jobs[i].owner == client && response.jobs.contains(where: { $0.id == state.jobs[i].id }) {
            state.jobs[i].lastSeen = now
        }
        try store.write(state)
        if let backup {
            do { response.replica = try backup.next(state: state, client: client, acknowledgment: request.replicaAck, indexAck: request.replicaIndexAck, now: now) }
            catch { distributedLog("Backup failed (work remains durably committed): \(error)") }
        }
        return response
    }

    private func randomSeed() -> UInt64 { UInt64.random(in: .min ... .max) }
}
