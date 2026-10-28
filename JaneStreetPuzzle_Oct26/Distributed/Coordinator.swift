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
    private var candidateViews: [String: DashboardCandidate] = [:]

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
        let savedInsights = state.insights
        for labels in state.elites { _ = try consider(labels) }
        if var savedInsights {
            if savedInsights.energy == nil { savedInsights.energy = state.insights?.energy }
            state.insights = savedInsights
        }
        if state.insights == nil { state.insights = SearchInsights() }
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
                    .union((self.state.fleet ?? [:]).keys.compactMap(UUID.init(uuidString:)))
                let clients = ids.sorted { $0.uuidString < $1.uuidString }.map { id in
                    let age = self.clients[id].map { max(0, now - $0) }
                    return DashboardClient(id: id, machineName: self.state.clientNames?[id.uuidString],
                        connected: age.map { $0 < self.settings.failureGraceSeconds } ?? false,
                        lastSeenSeconds: age, assignedJobs: jobs.filter { $0.clientID == id && $0.status == "assigned" }.count,
                        info: self.state.fleet?[id.uuidString], directive: self.state.directives?[id.uuidString])
                }
                continuation.resume(returning: DashboardSnapshot(minimumPeerVersion: self.settings.minimumPeerVersion, runID: self.state.runID, coordinatorName: self.settings.resolvedMachineName,
                    solved: self.state.solved, completedJobs: self.state.completedJobs,
                    reassignments: self.state.reassignments,
                    backupAgeSeconds: self.backup?.lastComplete.map { max(0, now - $0) },
                    clients: clients, jobs: jobs, capturedAt: Date().timeIntervalSince1970,
                    rows: self.state.config.rowNum, cols: self.state.config.colNum,
                    clues: self.state.config.Target.Status,
                    candidates: self.archive.compactMap { self.candidateViews[self.candidateID($0.labels)] },
                    insights: self.state.insights ?? SearchInsights(), commands: self.state.commands ?? []))
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
                let previousViews = self.candidateViews
                do { continuation.resume(returning: try self.process(request, now: now)) }
                catch {
                    self.state = previous; self.archive = previousArchive; self.clients = previousClients
                    self.candidateViews = previousViews
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Only fixed-size board evaluation and the independent validator; never search.
    private func candidateID(_ labels: [Int]) -> String {
        digest(Data(labels.map(String.init).joined(separator: ",").utf8))
    }

    private func event(_ message: String, client: UUID? = nil) {
        if state.insights == nil { state.insights = SearchInsights() }
        state.insights!.events.append(DashboardEvent(at: Date().timeIntervalSince1970, clientID: client, message: message))
        state.insights!.events = Array(state.insights!.events.suffix(128))
    }

    func manage(_ request: ManagementRequest) async throws -> ManagementCommand {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let previous = self.state
                do {
                    guard request.runID == self.state.runID else { throw DistributedError.message("Run changed; refresh before issuing a command.") }
                    if let existing = self.state.commands?.first(where: { $0.request.id == request.id }) {
                        guard existing.request.clientID == request.clientID,
                              existing.request.action == request.action, existing.request.workers == request.workers else {
                            throw DistributedError.message("Command ID was already used for a different request.")
                        }
                        continuation.resume(returning: existing); return
                    }
                    let key = request.clientID.uuidString
                    guard let info = self.state.fleet?[key], info.telemetry?.controlVersion == 1 else {
                        throw DistributedError.message("Client has not advertised management support; update and connect it first.")
                    }
                    var directive = self.state.directives?[key] ?? ClientDirective()
                    directive.id = request.id; directive.checkpoint = false
                    switch request.action {
                    case .pause: directive.mode = .paused
                    case .resume: directive.mode = .running
                    case .drain: directive.mode = .draining
                    case .quit: directive.mode = .quitting
                    case .checkpoint: directive.checkpoint = true
                    case .workers:
                        guard let count = request.workers, (1...min(self.settings.maxWorkersPerClient, info.telemetry!.capacity)).contains(count) else {
                            throw DistributedError.message("Worker count must fit this client's configured capacity.")
                        }
                        directive.workerLimit = count
                    }
                    var directives = self.state.directives ?? [:]; directives[key] = directive; self.state.directives = directives
                    var commands = self.state.commands ?? []
                    for i in commands.indices where commands[i].request.clientID == request.clientID && ["queued", "draining"].contains(commands[i].status) {
                        commands[i].status = "superseded"
                    }
                    let command = ManagementCommand(request: request, createdAt: Date().timeIntervalSince1970, status: "queued")
                    commands.append(command); self.state.commands = Array(commands.suffix(200))
                    self.event("Requested \(request.action.rawValue)", client: request.clientID)
                    try self.store.write(self.state)
                    continuation.resume(returning: command)
                } catch { self.state = previous; continuation.resume(throwing: error) }
            }
        }
    }

    private func consider(_ input: [Int], client: UUID? = nil, slot: Int? = nil, objective: String? = nil) throws -> Bool {
        guard validLabels(input, config: state.config) else { throw DistributedError.message("Invalid board labels.") }
        let labels = canonicalLabels(input)
        if archive.contains(where: { $0.labels == labels }) { return false }
        let candidate = scorer.evaluate(labels: labels)
        let exact = ExactValidator().validate(candidate.board, target: state.config.Target)
        let quality = SearchQuality(exact, candidate.scores)
        let id = candidateID(labels)
        let discovery = CandidateDiscovery(at: Date().timeIntervalSince1970, clientID: client, slot: slot, objective: objective)
        if state.insights == nil { state.insights = SearchInsights() }
        if state.insights!.discoveries[id] == nil { state.insights!.discoveries[id] = discovery }
        candidateViews[id] = DashboardCandidate(id: id, labels: labels, validation: exact,
            issues: quality.issues, wrong: quality.wrong, error: quality.error,
            discovery: state.insights!.discoveries[id])
        let previousEnergy = state.insights!.energy?.last
        let total = min(previousEnergy?.total ?? .infinity, candidate.scores.total)
        let residual = min(previousEnergy?.residual ?? .infinity, candidate.scores.realAIM)
        if previousEnergy == nil || total < previousEnergy!.total || residual < previousEnergy!.residual {
            var history = state.insights!.energy ?? []
            history.append(EnergyPoint(at: discovery.at, total: total, residual: residual))
            state.insights!.energy = Array(history.suffix(512))
        }
        if archive.first.map({ quality < $0.quality }) ?? true {
            state.insights!.improvements.append(QualityPoint(at: discovery.at, issues: quality.issues,
                wrong: quality.wrong, error: quality.error, candidateID: id))
            state.insights!.improvements = Array(state.insights!.improvements.suffix(256))
            event("Best candidate improved: \(quality.issues) structural issues, \(quality.wrong) wrong clues", client: client)
        }
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
        let retained = Set(archive.map { candidateID($0.labels) })
        candidateViews = candidateViews.filter { retained.contains($0.key) }
        state.insights!.discoveries = state.insights!.discoveries.filter { retained.contains($0.key) }
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
        guard SoftwareVersion.accepts(request.softwareVersion, minimum: settings.minimumPeerVersion) else {
            throw DistributedError.message("Software version rejected: worker \(request.softwareVersion.map(String.init) ?? "unversioned"), coordinator \(SoftwareVersion.current), accepted \(settings.minimumPeerVersion)...\(SoftwareVersion.current). Update the worker or explicitly configure minimumPeerVersion.")
        }
        let machineName = try validatedMachineName(request.machineName)
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
            response.machineName = settings.resolvedMachineName
            response.runID = state.runID; response.config = state.config; response.solved = state.solved
            return response
        }
        let wall = Date().timeIntervalSince1970
        let key = client.uuidString
        let oldInfo = state.fleet?[key]
        if let telemetry = request.telemetry {
            guard telemetry.controlVersion == 1, (1...settings.maxWorkersPerClient).contains(telemetry.capacity),
                  telemetry.workers.count <= settings.maxWorkersPerClient,
                  Set(telemetry.workers.map(\.slot)).count == telemetry.workers.count,
                  telemetry.workers.allSatisfy({ (0..<telemetry.capacity).contains($0.slot) && $0.state.utf8.count <= 32 && $0.backend.utf8.count <= 64 && ($0.reason?.utf8.count ?? 0) <= 512 && ($0.progressAt.map { $0.isFinite } ?? true) }),
                  telemetry.capturedAt.isFinite, telemetry.checkpointAt.map({ $0.isFinite }) ?? true,
                  (telemetry.lastError?.utf8.count ?? 0) <= 1024 else { throw DistributedError.message("Invalid client telemetry.") }
            if request.kind == "hello", oldInfo?.telemetry?.sessionID != telemetry.sessionID {
                // A deliberate new process launch can run again after an acknowledged quit.
                if let directive = state.directives?[key], [.quitting, .draining].contains(directive.mode),
                   state.commands?.contains(where: { $0.request.id == directive.id && ["stopping", "released"].contains($0.status) }) == true {
                    state.directives?.removeValue(forKey: key)
                }
                event("Client process connected (v\(request.softwareVersion.map(String.init) ?? "unversioned"))", client: client)
            }
        }
        var fleet = state.fleet ?? [:]
        // Bound inactive registry growth; never evict a client with pending control or work.
        if fleet[key] == nil && fleet.count >= 1024 {
            let removable = fleet.filter { entry in
                !state.jobs.contains(where: { $0.owner.uuidString == entry.key }) && state.directives?[entry.key] == nil
            }.min { $0.value.lastReportAt < $1.value.lastReportAt }?.key
            if let removable { fleet.removeValue(forKey: removable) }
            else { throw DistributedError.message("Client history is at capacity.") }
        }
        if let error = request.telemetry?.lastError, error != oldInfo?.telemetry?.lastError { event(error, client: client) }
        fleet[key] = FleetClient(telemetry: request.telemetry ?? (request.kind == "hello" ? nil : oldInfo?.telemetry), lastReportAt: wall,
            rate: 0, slotRates: oldInfo?.slotRates, softwareVersion: request.softwareVersion)
        state.fleet = fleet
        clients[client] = now
        if let machineName {
            var names = state.clientNames ?? [:]
            names[client.uuidString] = machineName
            state.clientNames = names
        }
        // Expired assignments remain recorded and eligible; never delete work on timeout.
        var response = WireMessage(kind: "sync")
        response.machineName = settings.resolvedMachineName
        response.runID = state.runID
        if request.kind == "hello" { response.config = state.config }
        guard request.elites.count <= state.config.eliteCapacity else { throw DistributedError.message("Too many supplemental boards.") }
        for labels in request.elites { _ = try consider(labels, client: client) }
        var measuredRates = oldInfo?.slotRates ?? [:]
        for report in request.reports {
            guard report.job.owner == client, report.progress.iterations >= 0,
                  report.progress.seconds.isFinite && report.progress.seconds >= 0,
                  validLabels(report.progress.current, config: state.config),
                  validLabels(report.progress.best, config: state.config) else {
                throw DistributedError.message("Malformed progress report.")
            }
            _ = try consider(report.progress.best, client: client, slot: report.job.slot, objective: report.job.objective.rawValue)
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
                throw DistributedError.message("Progress is outside the assigned budget (job \(report.job.id), generation \(report.job.generation), reported \(report.progress.iterations), previously accepted \(state.jobs[i].progress?.iterations ?? 0), limit \(state.jobs[i].budget - state.jobs[i].completed)).")
            }
            if report.progress.iterations > 0 && report.progress.seconds > 0 {
                measuredRates[String(state.jobs[i].slot)] = min(1e12, Double(report.progress.iterations) / report.progress.seconds)
            }
            let credited = report.progress.iterations - (state.jobs[i].progress?.iterations ?? 0)
            if state.insights == nil { state.insights = SearchInsights() }
            state.insights!.acceptedIterations &+= UInt64(credited)
            state.jobs[i].progress = report.progress
            state.jobs[i].lastSeen = now
            if report.progress.iterations >= state.jobs[i].budget - state.jobs[i].completed {
                state.jobs.remove(at: i); state.completedJobs &+= 1
                response.retired.append(report.job.id)
            } else if report.release || request.kind == "goodbye" {
                state.jobs[i].lastSeen = -1e100
                response.retired.append(report.job.id)
            }
        }
        let directive = state.directives?[key]
        if let ack = request.controlAck, let directive, ack.id == directive.id {
            let allowed: [String]
            switch directive.mode {
            case .paused: allowed = ["paused"]
            case .quitting: allowed = ["stopping", "released"]
            case .draining: allowed = ["draining", "stopping", "released"]
            case .running: allowed = ["running", "checkpointed"]
            }
            guard allowed.contains(ack.status), ack.status != "released" || request.kind == "goodbye" else {
                throw DistributedError.message("Invalid command acknowledgment.")
            }
            if let index = state.commands?.firstIndex(where: { $0.request.id == ack.id }), state.commands![index].status != ack.status {
                state.commands![index].status = ack.status
                event("Command \(ack.status)", client: client)
            }
            if let limit = directive.workerLimit {
                for i in state.jobs.indices where state.jobs[i].owner == client && state.jobs[i].slot >= limit {
                    state.jobs[i].lastSeen = -1e100
                    response.retired.append(state.jobs[i].id)
                }
            }
            if directive.mode == .paused || directive.mode == .quitting || request.kind == "goodbye" {
                for i in state.jobs.indices where state.jobs[i].owner == client {
                    state.jobs[i].lastSeen = -1e100
                    response.retired.append(state.jobs[i].id)
                }
            }
        }
        if request.kind == "goodbye" {
            if state.fleet?[key] != nil { state.fleet![key]!.rate = 0 }
            event("Client disconnected cleanly", client: client)
            // Clean quit releases all ownership, even a slot with no initialized board yet.
            for i in state.jobs.indices where state.jobs[i].owner == client { state.jobs[i].lastSeen = -1e100 }
            clients.removeValue(forKey: client)
        } else if !state.solved {
            for rate in request.rates {
                let mode = directive?.mode ?? .running
                let permitted = rate.slot < (directive?.workerLimit ?? settings.maxWorkersPerClient)
                if let job = state.jobs.first(where: { $0.owner == client && $0.slot == rate.slot
                    && (request.reconciling == true || now - $0.lastSeen < settings.failureGraceSeconds) }) {
                    // Pending pause/quit still echoes owned checkpoints for reconnect reconciliation.
                    if (permitted || request.reconciling == true) && !response.retired.contains(job.id) { response.jobs.append(job) }
                    continue
                }
                guard mode == .running, permitted else { continue }
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
        response.control = directive
        response.elites = state.elites
        response.solved = state.solved
        // Include all known client jobs in expiry renewal, even if initialization is slow.
        for i in state.jobs.indices where state.jobs[i].owner == client && response.jobs.contains(where: { $0.id == state.jobs[i].id }) {
            state.jobs[i].lastSeen = now
        }
        state.fleet![key]!.slotRates = measuredRates
        // Calibration predicts job budgets; it is not measured search throughput.
        state.fleet![key]!.rate = request.kind == "goodbye" ? 0 : request.rates.reduce(0) { $0 + (measuredRates[String($1.slot)] ?? 0) }
        let knownClients = Set(clients.keys.map(\.uuidString)).union(state.jobs.map { $0.owner.uuidString }).union((state.fleet ?? [:]).keys)
        if state.insights == nil { state.insights = SearchInsights() }
        if wall - (state.insights!.throughput.last?.at ?? 0) >= 5 {
            let activeIDs = Set(clients.filter { now - $0.value < settings.failureGraceSeconds }.keys.map(\.uuidString))
            let activeFleet = (state.fleet ?? [:]).filter { activeIDs.contains($0.key) }.map(\.value)
            let rate = activeFleet.reduce(0) { $0 + $1.rate }
            let activeWorkers = activeFleet.reduce(0) {
                $0 + ($1.telemetry?.workers.filter { ["searching", "supplemental"].contains($0.state) }.count ?? 0)
            }
            state.insights!.throughput.append(ThroughputPoint(at: wall, rate: rate,
                iterations: state.insights!.acceptedIterations, activeWorkers: activeWorkers))
            state.insights!.throughput = Array(state.insights!.throughput.suffix(360))
        }
        state.clientNames = state.clientNames?.filter { knownClients.contains($0.key) }
        try store.write(state)
        if let backup {
            do { response.replica = try backup.next(state: state, client: client, acknowledgment: request.replicaAck, indexAck: request.replicaIndexAck, now: now) }
            catch { distributedLog("Backup failed (work remains durably committed): \(error)") }
        }
        if request.kind == "hello" { distributedLog("Worker \(machineName ?? client.uuidString) connected: v\(request.softwareVersion.map(String.init) ?? "unversioned")") }
        return response
    }

    private func randomSeed() -> UInt64 { UInt64.random(in: .min ... .max) }
}
