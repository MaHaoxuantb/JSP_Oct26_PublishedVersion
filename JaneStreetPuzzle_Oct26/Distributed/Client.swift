import Foundation
import NIOPosix

struct LocalRecord: Codable, Sendable {
    var job: SearchJob
    var progress: DistributedProgress?

    /// Older clients could restart a completed generation and count extra work.
    /// Retain its boards, but credit at most the generation's assigned effort.
    @discardableResult mutating func enforceBudget() -> Bool {
        guard var progress else { return false }
        let remaining = max(0, job.budget - job.completed)
        let exceeded = progress.iterations > remaining
        if progress.iterations >= remaining {
            progress.iterations = remaining
            progress.finished = true
        }
        self.progress = progress
        return exceeded
    }
}
struct ClientDiskState: Codable, Sendable {
    var clientID = UUID()
    var runID: UUID?
    var config: RunConfig?
    var records: [LocalRecord] = []
    var control: ClientDirective? = nil
    var controlAppliedID: UUID? = nil
}

final class ProgressBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DistributedProgress?
    private var failure: String?
    private var path: (String, String?) = ("CPU", nil)
    func updatePath(_ evaluator: PathEvaluator) { lock.withLock { path = (evaluator.reportedBackend, evaluator.reportedReason) } }
    func pathStatus() -> (String, String?) { lock.withLock { path } }
    private var observationPending = false
    private var observedAt: Double?
    func requestObservation() { lock.withLock { if value?.finished != true { observationPending = true } } }
    func needsObservation() -> Bool { lock.withLock { observationPending } }
    func progressTimestamp() -> Double? { lock.withLock { observedAt } }
    func update(_ progress: DistributedProgress) { lock.withLock {
        value = progress; observationPending = false; observedAt = Date().timeIntervalSince1970
    } }
    func failed(_ error: Error) { lock.withLock { failure = String(describing: error) } }
    func read() -> (DistributedProgress?, String?) { lock.withLock { (value, failure) } }
}

/// A cache is handed to one detached worker at a time, and only reused after that
/// task has ended. It never crosses the network or participates in persistence.
final class WorkerCache: @unchecked Sendable {
    var context: SearchContext?
}
struct RunningSlot {
    let record: LocalRecord
    let bridge: ProgressBridge
    let task: Task<Void, Never>
    let supplemental: Bool
    func matches(_ job: SearchJob) -> Bool {
        !supplemental && record.job.id == job.id && record.job.generation == job.generation
    }
}

actor ClientEngine {
    private let settings: DistributedConfig
    private let pathEvaluation: PathEvaluationMode
    private let directory: URL
    private let store: DurableStore
    private var disk: ClientDiskState
    private var slots: [Int: RunningSlot] = [:]
    private var caches: [Int: WorkerCache] = [:]
    private var rates: [WorkerRate] = []
    private var archive = EliteArchive(capacity: 8)
    private var lastSave = -Double.infinity
    private var stopped = false
    private var supplemental: [[Int]] = []
    private var maintenanceFailure: (any Error)?
    private var changingAssignments = false
    private let sessionID = UUID()
    private var checkpointAt: Double?
    private var lastError: String?
    private var mode: ClientMode { disk.control?.mode ?? .running }
    private var workerLimit: Int { min(settings.workers, disk.control?.workerLimit ?? settings.workers) }

    init(settings: DistributedConfig, pathEvaluation: PathEvaluationMode = .automatic) throws {
        self.settings = settings
        self.pathEvaluation = pathEvaluation
        directory = URL(fileURLWithPath: settings.stateDirectory)
        store = try DurableStore(path: directory.appendingPathComponent("client.sqlite").path)
        disk = try store.read(ClientDiskState.self) ?? ClientDiskState()
        disk.config?.pathEvaluation = pathEvaluation
        // An explicit process launch starts a new session after a previous quit.
        // The coordinator redelivers any quit that was never acknowledged.
        let savedMode = disk.control?.mode
        let noSavedRecords = disk.records.isEmpty
        if savedMode == .quitting || (savedMode == .draining && noSavedRecords) { disk.control = nil }
        var repaired = 0
        for i in disk.records.indices where disk.records[i].enforceBudget() { repaired += 1 }
        try store.write(disk)
        if repaired > 0 {
            distributedLog("Recovered \(repaired) over-budget checkpoints from an older client; candidate boards retained.")
        }
    }
    func identity() -> UUID { disk.clientID }
    func savedConfig() -> RunConfig? { disk.config }
    func currentRun() -> UUID? { disk.runID }
    func currentRates() -> [WorkerRate] {
        guard mode == .running || mode == .draining else { return [] }
        return rates.filter { $0.slot < workerLimit }
    }
    func allRates() -> [WorkerRate] { rates }
    func noteCommunicationError(_ error: String) { lastError = String(error.prefix(512)) }
    func telemetry() -> ClientTelemetry {
        ClientTelemetry(sessionID: sessionID, controlVersion: 1, capacity: settings.workers, mode: mode,
            capturedAt: Date().timeIntervalSince1970, checkpointAt: checkpointAt,
            workers: slots.sorted { $0.key < $1.key }.map { slot, running in
                let progress = running.bridge.read().0
                let path = running.bridge.pathStatus()
                return WorkerTelemetry(slot: slot, state: progress?.finished == true ? "finished" : (running.supplemental ? "supplemental" : "searching"),
                    backend: path.0, reason: path.1, progressAt: running.bridge.progressTimestamp())
            }, lastError: lastError)
    }
    func controlAck(released: Bool = false) -> ControlAck? {
        guard let control = disk.control, disk.controlAppliedID == control.id else { return nil }
        let status: String
        if released { status = "released" }
        else { switch control.mode {
        case .paused: status = "paused"
        case .quitting: status = "stopping"
        case .draining: status = shouldQuit() ? "stopping" : "draining"
        case .running: status = control.checkpoint ? "checkpointed" : "running"
        } }
        return ControlAck(id: control.id, status: status)
    }
    func shouldQuit() -> Bool { mode == .quitting || (mode == .draining && disk.records.isEmpty) }
    func envelope(kind: String, token: String, includeReports: Bool = true) throws -> WireMessage {
        var message = WireMessage(kind: kind, clientID: disk.clientID, token: token)
        message.runID = disk.runID; message.telemetry = telemetry()
        message.controlAck = controlAck(released: kind == "goodbye" && (mode == .quitting || mode == .draining))
        if kind != "goodbye" { message.rates = currentRates() }
        if includeReports { message.reports = try reports(); message.elites = supplemental }
        return message
    }
    func setRates(_ values: [WorkerRate]) { rates = values }
    func recordMaintenanceFailure(_ error: any Error) { maintenanceFailure = error }
    func checkMaintenance() throws {
        if let maintenanceFailure { throw maintenanceFailure }
    }

    func configure(_ config: RunConfig, runID: UUID) async throws {
        changingAssignments = true
        defer { changingAssignments = false }
        if disk.runID != runID {
            await cancelAll()
            disk.records = []; caches = [:]; supplemental = []
            archive = EliteArchive(capacity: config.eliteCapacity)
        }
        disk.runID = runID
        var local = config
        local.distributed = settings
        local.pathEvaluation = pathEvaluation
        disk.config = local
        try store.write(disk)
    }

    func recoverLocal() throws {
        guard disk.config != nil, !stopped, mode == .running || mode == .draining else { return }
        for i in disk.records.indices {
            if var progress = disk.records[i].progress,
               progress.iterations >= disk.records[i].job.budget - disk.records[i].job.completed {
                progress.finished = true
                disk.records[i].progress = progress
            } else if disk.records[i].progress?.finished != true, slots[disk.records[i].job.slot] == nil {
                start(disk.records[i], resumed: true)
            }
        }
        try store.write(disk)
    }

    private func start(_ record: LocalRecord, resumed: Bool = false, offline: Bool = false) {
        guard var config = disk.config, mode == .running || mode == .draining, record.job.slot < workerLimit else { return }
        let offset = record.progress?.iterations ?? 0
        let remaining = record.job.budget - record.job.completed - offset
        guard remaining > 0, record.progress?.finished != true else { return }
        let slot = record.job.slot
        let bridge = ProgressBridge()
        if let progress = record.progress { bridge.update(progress) }
        let cache = caches[slot] ?? WorkerCache(); caches[slot] = cache
        let previousBest = record.progress?.best
        let previousSeconds = record.progress?.seconds ?? 0
        let archive = record.job.explorer ? nil : self.archive
        config.workerCount = 1
        config.maxIterations = remaining
        config.timeLimitSeconds = max(60, settings.jobSeconds * 10)
        config.distributed = settings
        config.searchObjective = record.job.objective
        config.seed = resumed ? UInt64.random(in: .min ... .max) : record.job.seed
        config.consoleLogging = false
        config.logDirectory = directory.appendingPathComponent("workers/slot-\(slot)").path
        let rate = rates.first(where: { $0.slot == slot })
        config.repairTimeLimitSeconds = min(5, max(0.15, rate?.repairSeconds ?? 0.15))
        let initial = record.progress?.current
        let taskConfig = config
        let task = Task.detached(priority: .low) {
            do {
                if cache.context == nil { cache.context = SearchContext(config: taskConfig) }
                bridge.updatePath(cache.context!.pathEvaluator)
                // Only the best labels are preserved across continuation starts;
                // score them in the same worker-local context, never on the network loop.
                let old = previousBest.map { labels in
                    (labels: labels, quality: cache.context!.evaluate(labels: labels).quality)
                }
                _ = try await Main().Run(Config: taskConfig, workerID: (slot + 1) * 4 + 1, archive: archive,
                    initialLabels: initial, reusableContext: cache.context, observationRequested: { bridge.needsObservation() }) { update in
                        var cumulative = update
                        cumulative.iterations += offset
                        cumulative.seconds += previousSeconds
                        if let old {
                            // Compare scalar scores only inside the search task.
                            // The label-only progress does not carry untrusted ranking.
                            let candidate = cache.context!.evaluate(labels: cumulative.best)
                            if old.quality < candidate.quality { cumulative.best = old.labels }
                        }
                        bridge.update(cumulative)
                        bridge.updatePath(cache.context!.pathEvaluator)
                    }
            } catch { bridge.failed(error) }
        }
        slots[slot] = RunningSlot(record: record, bridge: bridge, task: task, supplemental: offline)
    }

    func reports() throws -> [JobReport] {
        var reports: [JobReport] = []
        for record in disk.records {
            let live = slots[record.job.slot]
            let value = live?.matches(record.job) == true ? live?.bridge.read() : nil
            if let failure = value?.1 { throw DistributedError.message("Worker failed: \(failure)") }
            if let progress = value?.0 ?? record.progress {
                if progress.iterations > 0 && progress.seconds > 0,
                   let index = rates.firstIndex(where: { $0.slot == record.job.slot }) {
                    let measured = Double(progress.iterations) / progress.seconds
                    rates[index].iterationsPerSecond = 0.8 * rates[index].iterationsPerSecond + 0.2 * measured
                }
                var manifest = record.job
                manifest.progress = nil // Do not retransmit an older full checkpoint twice.
                reports.append(JobReport(job: manifest, progress: progress,
                    release: mode == .paused || mode == .quitting || record.job.slot >= workerLimit || (progress.finished && progress.iterations < record.job.budget - record.job.completed && !progress.solved)))
            }
        }
        return reports
    }

    func save(force: Bool = false, now: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard force || now - lastSave >= settings.checkpointSeconds else { return }
        for i in disk.records.indices {
            if let slot = slots[disk.records[i].job.slot], slot.matches(disk.records[i].job), let progress = slot.bridge.read().0 {
                disk.records[i].progress = progress
            }
        }
        try store.write(disk)
        lastSave = now
        checkpointAt = Date().timeIntervalSince1970
    }

    func apply(_ response: WireMessage, reconciling: Bool = false) async throws {
        changingAssignments = true
        defer { changingAssignments = false }
        if reconciling { await cancelAll() }
        if let control = response.control, control.id != disk.control?.id || control.id != disk.controlAppliedID {
            // Persist intent before awaiting cooperative cancellation. Maintenance
            // cannot launch supplemental work while assignments are changing.
            disk.control = control
            try store.write(disk)
            if control.mode == .paused || control.mode == .quitting {
                await cancelAll()
            } else {
                let extras = slots.filter { $0.key >= workerLimit || (control.mode == .draining && $0.value.supplemental) }
                for (_, extra) in extras { extra.task.cancel() }
                for (slot, extra) in extras {
                    await extra.task.value
                    if let progress = extra.bridge.read().0 {
                        if !extra.supplemental, let i = disk.records.firstIndex(where: { extra.matches($0.job) }) {
                            disk.records[i].progress = progress
                        }
                        supplemental.append(progress.best)
                    }
                    slots.removeValue(forKey: slot)
                }
            }
            if control.checkpoint {
                let bridges = slots.values.filter { $0.bridge.read().0?.finished != true }.map(\.bridge)
                for bridge in bridges { bridge.requestObservation() }
                while bridges.contains(where: { $0.needsObservation() }) {
                    for bridge in bridges {
                        if let failure = bridge.read().1 { throw DistributedError.message("Worker failed while checkpointing: \(failure)") }
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            disk.controlAppliedID = control.id
            try save(force: true)
        }
        if response.solved {
            await cancelAll(); try save(force: true); stopped = true; return
        }
        if let config = disk.config {
            let context = SearchContext(config: config)
            for labels in response.elites where validLabels(labels, config: config) {
                let state = context.evaluate(labels: labels)
                await archive.publish(EliteCandidate(snapshot: BoardSnapshot(state), scores: state.scores, workerID: 0))
            }
        }
        let assigned = Set(response.jobs.map(\.id))
        for retired in response.retired where !assigned.contains(retired) {
            if let record = disk.records.first(where: { $0.job.id == retired }), let slot = slots.removeValue(forKey: record.job.slot) {
                slot.task.cancel(); await slot.task.value
            }
            disk.records.removeAll { $0.job.id == retired }
        }
        for job in response.jobs {
            // A finished worker is still awaiting its durable coordinator ACK.
            // Echoing that generation must never restart it or reset its counter.
            if let current = slots[job.slot], current.matches(job) { continue }
            let saved = disk.records.first { $0.job.id == job.id && $0.job.generation == job.generation }
            var record = saved ?? LocalRecord(job: job, progress: job.progress)
            record.job = job
            if let acknowledged = job.progress,
               acknowledged.iterations > (record.progress?.iterations ?? -1) {
                if let best = record.progress?.best { supplemental.append(best) }
                record.progress = acknowledged
            }
            record.enforceBudget()
            if record.progress?.finished == true {
                disk.records.removeAll { $0.job.slot == job.slot || $0.job.id == job.id }
                disk.records.append(record)
                try store.write(disk)
                continue
            }
            if let old = slots.removeValue(forKey: job.slot) {
                old.task.cancel(); await old.task.value
            }
            // A finished partial attempt gets a new server generation; a complete
            // attempt is only retired by the server after its durable commit.
            disk.records.removeAll { $0.job.slot == job.slot || $0.job.id == job.id }
            disk.records.append(record)
            try store.write(disk) // Receipt is durable before launching computation.
            start(record, resumed: saved != nil)
        }
        supplemental = Array(supplemental.suffix(disk.config?.eliteCapacity ?? 8))
        try save(force: true)
    }

    func offlineWork() async throws {
        guard !stopped, !changingAssignments, mode == .running, !rates.isEmpty, let config = disk.config else { return }
        try save()
        for slot in 0..<workerLimit {
            if let current = slots[slot] {
                let (progress, failure) = current.bridge.read()
                if let failure { throw DistributedError.message(failure) }
                guard progress?.finished == true else { continue }
                await current.task.value
                guard !changingAssignments, !stopped, mode == .running else { return }
                guard slots[slot]?.bridge === current.bridge else { continue }
                if let progress { supplemental.append(progress.best); supplemental = Array(supplemental.suffix(config.eliteCapacity)) }
                if !current.supplemental { try save(force: true) }
            } else if disk.records.contains(where: { $0.job.slot == slot && $0.progress?.finished != true }) { continue }
            let job = SearchJob(slot: slot, seed: UInt64.random(in: .min ... .max), objective: .matches,
                budget: max(1, Int(settings.jobSeconds)), owner: disk.clientID, lastSeen: 0, explorer: true)
            let labels = supplemental.last ?? disk.records.first(where: { $0.job.slot == slot })?.progress?.best
            let progress = labels.map { DistributedProgress(current: $0, best: $0, iterations: 0, seconds: 0, finished: false, solved: false) }
            start(LocalRecord(job: job, progress: progress), offline: true)
        }
    }
    func supplementalBoards() -> [[Int]] { supplemental }
    func isStopped() -> Bool { stopped }
    func stop() async throws { stopped = true; await cancelAll(); try save(force: true) }
    private func cancelAll() async {
        for slot in slots.values { slot.task.cancel() }
        for slot in slots.values { await slot.task.value }
        // Preserve updates before removing their bridges.
        for i in disk.records.indices {
            if let slot = slots[disk.records[i].job.slot], slot.matches(disk.records[i].job), let progress = slot.bridge.read().0 {
                disk.records[i].progress = progress
            }
        }
        for slot in slots.values where slot.supplemental {
            if let best = slot.bridge.read().0?.best { supplemental.append(best) }
        }
        supplemental = Array(supplemental.suffix(disk.config?.eliteCapacity ?? 8))
        slots = [:]
    }
}

func calibrate(config: RunConfig, settings: DistributedConfig) async -> [WorkerRate] {
    await withTaskGroup(of: WorkerRate.self) { group in
        for slot in 0..<settings.workers {
            group.addTask {
                var fixture = config
                fixture.workerCount = 1; fixture.seed &+= UInt64(slot)
                let context = SearchContext(config: fixture)
                context.deadline = ProcessInfo.processInfo.systemUptime + settings.calibrationSeconds
                let board = Initialization().start(context: context)
                return await measureWorkerRate(context: context, initial: board, slot: slot,
                                               seconds: settings.calibrationSeconds)
            }
        }
        var rates: [WorkerRate] = []
        for await rate in group { rates.append(rate) }
        return rates.sorted { $0.slot < $1.slot }
    }
}

/// Initialization has its own budget. Measure proposals against a fresh deadline
/// and exclude empty attempts from the estimate used to size future assignments.
func measureWorkerRate(context: SearchContext, initial: SearchState, slot: Int, seconds: Double) async -> WorkerRate {
    var current = initial
    let start = ProcessInfo.processInfo.systemUptime
    context.deadline = start + seconds
    var count = 0, attempts = 0
    while !context.expired(context.deadline) {
        let result = Iteration().OneIteration(current: current, context: context,
                                              temperature: context.config.initialTemperature)
        current = result.state
        attempts += 1
        if result.move != nil { count += 1 }
        if attempts % 8 == 0 { await Task.yield() }
    }
    let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - start)
    return WorkerRate(slot: slot, iterationsPerSecond: max(0.01, Double(count) / elapsed),
                      repairSeconds: min(5, max(0.15, elapsed / Double(max(1, count)) * 2)))
}
