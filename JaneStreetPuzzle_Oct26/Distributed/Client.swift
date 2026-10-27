import Foundation
import NIOPosix

struct LocalRecord: Codable, Sendable {
    var job: SearchJob
    var progress: DistributedProgress?
}
struct ClientDiskState: Codable, Sendable {
    var clientID = UUID()
    var runID: UUID?
    var config: RunConfig?
    var records: [LocalRecord] = []
}

final class ProgressBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DistributedProgress?
    private var failure: String?
    func update(_ progress: DistributedProgress) { lock.withLock { value = progress } }
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

    init(settings: DistributedConfig, pathEvaluation: PathEvaluationMode = .automatic) throws {
        self.settings = settings
        self.pathEvaluation = pathEvaluation
        directory = URL(fileURLWithPath: settings.stateDirectory)
        store = try DurableStore(path: directory.appendingPathComponent("client.sqlite").path)
        disk = try store.read(ClientDiskState.self) ?? ClientDiskState()
        disk.config?.pathEvaluation = pathEvaluation
        try store.write(disk)
    }
    func identity() -> UUID { disk.clientID }
    func savedConfig() -> RunConfig? { disk.config }
    func currentRun() -> UUID? { disk.runID }
    func currentRates() -> [WorkerRate] { rates }
    func setRates(_ values: [WorkerRate]) { rates = values }

    func configure(_ config: RunConfig, runID: UUID) async throws {
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
        guard disk.config != nil else { return }
        for i in disk.records.indices {
            if var progress = disk.records[i].progress,
               progress.iterations >= disk.records[i].job.budget - disk.records[i].job.completed {
                progress.finished = true
                disk.records[i].progress = progress
            } else if disk.records[i].progress?.finished != true {
                start(disk.records[i], resumed: true)
            }
        }
        try store.write(disk)
    }

    private func start(_ record: LocalRecord, resumed: Bool = false, offline: Bool = false) {
        guard var config = disk.config else { return }
        let slot = record.job.slot
        let bridge = ProgressBridge()
        if let progress = record.progress { bridge.update(progress) }
        let cache = caches[slot] ?? WorkerCache(); caches[slot] = cache
        let offset = record.progress?.iterations ?? 0
        let previousBest = record.progress?.best
        let previousSeconds = record.progress?.seconds ?? 0
        let archive = record.job.explorer ? nil : self.archive
        config.workerCount = 1
        config.maxIterations = max(1, record.job.budget - record.job.completed - offset)
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
                // Only the best labels are preserved across continuation starts;
                // score them in the same worker-local context, never on the network loop.
                let old = previousBest.map { labels in
                    (labels: labels, quality: cache.context!.evaluate(labels: labels).quality)
                }
                _ = try await Main().Run(Config: taskConfig, workerID: (slot + 1) * 4 + 1, archive: archive,
                    initialLabels: initial, reusableContext: cache.context) { update in
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
                    }
            } catch { bridge.failed(error) }
        }
        slots[slot] = RunningSlot(record: record, bridge: bridge, task: task, supplemental: offline)
    }

    func reports() throws -> [JobReport] {
        var reports: [JobReport] = []
        for record in disk.records {
            let live = slots[record.job.slot]
            let value = live?.supplemental == false ? live?.bridge.read() : nil
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
                    release: progress.finished && progress.iterations < record.job.budget - record.job.completed && !progress.solved))
            }
        }
        return reports
    }

    func save(force: Bool = false, now: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard force || now - lastSave >= settings.checkpointSeconds else { return }
        for i in disk.records.indices {
            if let slot = slots[disk.records[i].job.slot], !slot.supplemental, let progress = slot.bridge.read().0 {
                disk.records[i].progress = progress
            }
        }
        try store.write(disk)
        lastSave = now
    }

    func apply(_ response: WireMessage) async throws {
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
            if let current = slots[job.slot], !current.supplemental,
               current.record.job.id == job.id && current.record.job.generation == job.generation,
               current.bridge.read().0?.finished != true { continue }
            if let old = slots.removeValue(forKey: job.slot) {
                old.task.cancel(); await old.task.value
            }
            let saved = disk.records.first { $0.job.id == job.id && $0.job.generation == job.generation }
            var record = saved ?? LocalRecord(job: job, progress: job.progress)
            record.job = job
            // A finished partial attempt gets a new server generation; a complete
            // attempt is only retired by the server after its durable commit.
            disk.records.removeAll { $0.job.slot == job.slot || $0.job.id == job.id }
            disk.records.append(record)
            try store.write(disk) // Receipt is durable before launching computation.
            start(record, resumed: saved != nil)
        }
        try save(force: true)
    }

    func offlineWork() async throws {
        guard !stopped, !rates.isEmpty, let config = disk.config else { return }
        try save()
        for slot in 0..<settings.workers {
            if let current = slots[slot] {
                let (progress, failure) = current.bridge.read()
                if let failure { throw DistributedError.message(failure) }
                guard progress?.finished == true else { continue }
                await current.task.value
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
    func stop() async throws { await cancelAll(); try save(force: true) }
    private func cancelAll() async {
        for slot in slots.values { slot.task.cancel() }
        for slot in slots.values { await slot.task.value }
        // Preserve updates before removing their bridges.
        for i in disk.records.indices {
            if let slot = slots[disk.records[i].job.slot], !slot.supplemental, let progress = slot.bridge.read().0 {
                disk.records[i].progress = progress
            }
        }
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
                var current = board
                let start = ProcessInfo.processInfo.systemUptime
                var count = 0
                while ProcessInfo.processInfo.systemUptime - start < settings.calibrationSeconds && !Task.isCancelled {
                    let result = Iteration().OneIteration(current: current, context: context, temperature: fixture.initialTemperature)
                    current = result.state; count += 1
                    if count % 8 == 0 { await Task.yield() }
                }
                let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - start)
                return WorkerRate(slot: slot, iterationsPerSecond: max(0.01, Double(count) / elapsed),
                    repairSeconds: min(5, max(0.15, elapsed / Double(max(1, count)) * 2)))
            }
        }
        var rates: [WorkerRate] = []
        for await rate in group { rates.append(rate) }
        return rates.sorted { $0.slot < $1.slot }
    }
}
