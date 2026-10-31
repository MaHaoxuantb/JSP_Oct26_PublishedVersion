// JSP-Oct26-GPU-Multicore; ©2026 ThomasB. Author: ThomasB.
// Isolated harness around unchanged production search. No network deployment.
import Foundation
import Darwin
import PuzzleRules

private struct Input: Codable {
    let id: String, seed: UInt64, budgetSeconds: Double, gpu: Bool, threads: Int, output: String
}
private func cpuTime() -> Double {
    var r = rusage(); getrusage(RUSAGE_SELF, &r)
    return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec)
        + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1_000_000
}
private final class MeasuredMetal: GPUPathBackend, @unchecked Sendable {
    let name = "Metal-full-device"
    private let backend: MetalPathBackend
    private let lock = NSLock()
    private var batches = 0, boards = 0, maximumBatch = 0
    private var callSeconds = 0.0
    init() throws { backend = try MetalPathBackend() }
    func distances(grid: Grid, inputs: [PathInput]) throws -> [[Int32]] {
        let started = ProcessInfo.processInfo.systemUptime
        let result = try backend.distances(grid: grid, inputs: inputs)
        lock.lock()
        batches += 1; boards += inputs.count; maximumBatch = max(maximumBatch, inputs.count)
        callSeconds += ProcessInfo.processInfo.systemUptime - started
        lock.unlock()
        return result
    }
    func metrics() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["batches": batches, "boards": boards, "maximumBatch": maximumBatch,
                "meanBatch": Double(boards) / Double(max(1, batches)),
                "summedCallerSecondsIncludingLockWait": callSeconds]
    }
}
private struct Finished: @unchecked Sendable {
    let id: Int, seed: UInt64, snapshot: BoardSnapshot, statistics: SearchStatistics
    let repairs: RepairMetrics, reason: StopReason, gpuBatches: Int, gpuBoards: Int
    let fallback: String?
    var quality: PuzzleRules.Quality {
        let v = snapshot.validation
        return PuzzleRules.Quality(issues: v.issues.count, wrong: v.mismatches.count,
                                  residual: snapshot.validation.mismatches.reduce(0.0) { sum, m in
            sum + (m.actual.map { abs(Double($0) - Double(m.expected)) / max(1, max(Double($0), Double(m.expected))) } ?? 1)
        })
    }
}
private final class Sink: @unchecked Sendable {
    let puzzle: PuzzleRules.Puzzle, started: Double, cpuStarted: Double, output: String
    let file: FileHandle
    private let lock = NSLock()
    private var best: PuzzleRules.ExactEvaluation?
    private var iterations: [Int: Int] = [:]
    private var lastSample = -Double.infinity
    init(puzzle: PuzzleRules.Puzzle, started: Double, cpuStarted: Double, output: String) throws {
        self.puzzle = puzzle; self.started = started; self.cpuStarted = cpuStarted; self.output = output
        FileManager.default.createFile(atPath: output + "/observations.jsonl", contents: nil)
        file = try FileHandle(forWritingTo: URL(fileURLWithPath: output + "/observations.jsonl"))
    }
    func observe(_ p: DistributedProgress, worker: Int) {
        lock.lock(); defer { lock.unlock() }
        let value = PuzzleRules.Rules.evaluate(p.best, puzzle: puzzle)
        let improved = best == nil || value.quality < best!.quality
        if improved { best = value }
        iterations[worker] = p.iterations
        let seconds = ProcessInfo.processInfo.systemUptime - started
        guard improved || p.finished || seconds - lastSample >= 1 else { return }
        lastSample = seconds
        let v = best!, cpu = cpuTime() - cpuStarted
        let event: [String: Any] = ["seconds": seconds, "cpuSeconds": cpu,
            "cpuEquivalentCores": cpu / max(0.001, seconds), "worker": worker,
            "workersObserved": iterations.count, "iterationsObserved": iterations.values.reduce(0,+),
            "quality": ["issues":v.quality.issues,"wrong":v.quality.wrong,"residual":v.quality.residual],
            "commonEnergy": v.commonEnergy, "solved": v.solved, "labels": v.labels]
        do {
            var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]); data.append(10)
            try file.write(contentsOf: data)
        } catch { fputs("Observation write failed: \(error)\n", stderr); exit(2) }
    }
}
@main struct MulticoreWorker {
    static func main() async throws {
        let started = ProcessInfo.processInfo.systemUptime, cpuStarted = cpuTime()
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        precondition(input.threads == 8)
        var base = RunConfig.fullPuzzle
        base.workerCount = input.threads; base.pathEvaluation = input.gpu ? .gpu : .cpu
        base.seed = input.seed; base.consoleLogging = false
        base.maxIterations = Int.max / 1024; base.maxRestarts = Int.max / 1024
        base.progressInterval = 1000; base.progressTimeIntervalSeconds = 5
        base.checkpointIntervalSeconds = 30; base.distributed.checkpointSeconds = 2
        let puzzle = PuzzleRules.Puzzle(id: "original-11", n: 11, clues: base.Target.Status.flatMap { $0 })
        let sink = try Sink(puzzle: puzzle, started: started, cpuStarted: cpuStarted, output: input.output)
        // Give every CPU worker its own Metal queue, avoiding the stock global backend lock.
        let gpuBackends = try input.gpu ? (0..<input.threads).map { _ in try MeasuredMetal() } : []
        let archive = EliteArchive(capacity: base.eliteCapacity)
        let common = base
        var workers: [Finished] = []
        try await withThrowingTaskGroup(of: Finished.self) { group in
            for index in 0..<input.threads {
                var config = common
                config.workerCount = 1
                config.seed = input.seed &+ (UInt64(index) &* 0x9E3779B97F4A7C15)
                config.searchObjective = SearchObjective.allCases[index % SearchObjective.allCases.count]
                config.logDirectory = input.output + "/worker-\(index+1)"
                let prepared = config
                let gpu = gpuBackends.isEmpty ? nil : gpuBackends[index]
                group.addTask {
                    var config = prepared
                    config.timeLimitSeconds = max(0.001, input.budgetSeconds - (ProcessInfo.processInfo.systemUptime - started))
                    let context = SearchContext(config: config)
                    if let gpu { context.pathEvaluator = PathEvaluator(grid: context.grid, mode: .gpu, backend: gpu) }
                    let result = try await Main().Run(Config: config, workerID: index+1, archive: archive,
                        reusableContext: context, observationRequested: { false }, observe: { sink.observe($0, worker: index+1) })
                    return Finished(id: index+1, seed: config.seed, snapshot: BoardSnapshot(result.best),
                        statistics: result.statistics, repairs: result.repairs, reason: result.reason,
                        gpuBatches: context.pathEvaluator.gpuBatches, gpuBoards: context.pathEvaluator.gpuBoards,
                        fallback: context.pathEvaluator.fallbackReason)
                }
            }
            for try await value in group {
                workers.append(value)
                if value.snapshot.validation.valid { group.cancelAll() }
            }
        }
        let ranked = workers.map { ($0, PuzzleRules.Rules.evaluate($0.snapshot.labels.flatMap { $0 }, puzzle: puzzle)) }
        let winner = ranked.min { $0.1.quality < $1.1.quality }!
        var metrics = RepairMetrics()
        for worker in workers { metrics.add(worker.repairs) }
        let wall = ProcessInfo.processInfo.systemUptime - started, cpu = cpuTime() - cpuStarted
        let details: [[String: Any]] = workers.sorted { $0.id < $1.id }.map { w in
            ["worker":w.id,"seed":w.seed,"iterations":w.statistics.iterations,
             "reason":w.reason.rawValue,"gpuBatches":w.gpuBatches,"gpuBoards":w.gpuBoards,
             "fallback":w.fallback as Any? ?? NSNull()]
        }
        let v = winner.1
        let queueMetrics = gpuBackends.map { $0.metrics() }
        let totalBatches = queueMetrics.reduce(0) { $0 + ($1["batches"] as! Int) }
        let totalBoards = queueMetrics.reduce(0) { $0 + ($1["boards"] as! Int) }
        let gpuMetrics: [String: Any] = ["queues": gpuBackends.count, "batches": totalBatches,
            "boards": totalBoards, "maximumBatch": queueMetrics.map { $0["maximumBatch"] as! Int }.max() ?? 0,
            "meanBatch": Double(totalBoards) / Double(max(1, totalBatches)), "perQueue": queueMetrics]
        let result: [String: Any] = ["experiment":"JSP-Oct26-GPU-Multicore","copyright":"©2026 ThomasB",
            "softwareVersion":SoftwareVersion.current,"id":input.id,"seed":input.seed,
            "mode":input.gpu ? "cpu8-fullGPU" : "cpu8", "cpuWorkers":input.threads,
            "seconds":wall,"cpuSeconds":cpu,"cpuEquivalentCores":cpu/max(wall,0.001),
            "solved":v.solved,"answer":v.answer as Any? ?? NSNull(),"labels":v.labels,
            "quality":["issues":v.quality.issues,"wrong":v.quality.wrong,"residual":v.quality.residual],
            "commonEnergy":v.commonEnergy,"iterations":workers.reduce(0){$0+$1.statistics.iterations},
            "metrics":try JSONSerialization.jsonObject(with:JSONEncoder().encode(metrics)),
            "gpu": input.gpu ? gpuMetrics : NSNull(),"workers":details]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys,.prettyPrinted])
            .write(to: URL(fileURLWithPath: input.output + "/result.json"), options: .atomic)
        print("Finished \(input.id): \(wall)s; CPU equivalent \(cpu/wall); energy \(v.commonEnergy); solved \(v.solved)")
    }
}
