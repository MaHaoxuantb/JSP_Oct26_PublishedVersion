import Foundation
#if !STANDALONE_PATH_TESTS
import Testing
@testable import PuzzleSolver
#endif

private enum PathChecks {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw PathDeviceError(description: message) }
    }
    static func config(rows: Int, cols: Int) -> RunConfig {
        var config = RunConfig.example
        config.rowNum = rows; config.colNum = cols
        config.Target = OriginalCondition(Status: Array(repeating: Array(repeating: 0, count: cols), count: rows))
        config.pathEvaluation = .cpu; config.consoleLogging = false
        return config
    }
    static func reference(_ context: SearchContext, _ input: PathInput) -> PathResult {
        let result = context.shortestPaths(sizes: input.sizes, capitols: input.capitols, heap: true)
        return PathResult(distances: result.0, parents: result.1)
    }
    static func certificates() throws {
        var random = SearchRandom(seed: 20261027)
        for (rows, cols) in [(1, 1), (5, 5), (11, 11), (1, 121), (121, 1), (3, 7)] {
            let context = SearchContext(config: config(rows: rows, cols: cols))
            for trial in 0..<100 {
                let input = PathInput(sizes: (0..<context.grid.count).map { _ in 1 + random.index(context.grid.count) },
                                      capitols: trial == 0 ? [] : (0..<context.grid.count).filter { _ in random.index(9) == 0 })
                let expected = reference(context, input)
                let raw = expected.distances.map { $0 == Int.max ? PathEvaluator.infinity : Int32($0) }
                try check(PathEvaluator.certify(grid: context.grid, input: input, raw: raw) == expected,
                          "Certificate or parent tie order differs from CPU for \(rows)x\(cols)")
                var corrupt = raw; corrupt[0] = -1
                try check(PathEvaluator.certify(grid: context.grid, input: input, raw: corrupt) == nil, "Accepted negative distance")
                corrupt = raw; corrupt[0] = raw[0] == PathEvaluator.infinity ? 0 : raw[0] + 1
                try check(PathEvaluator.certify(grid: context.grid, input: input, raw: corrupt) == nil, "Accepted incorrect distance")
            }
        }
        let line = SearchContext(config: config(rows: 1, cols: 121))
        let input = PathInput(sizes: Array(repeating: 121, count: 121), capitols: [0])
        try check(reference(line, input).distances.last == 14_520, "Distance bound fixture")
    }

    private final class BadBackend: GPUPathBackend, @unchecked Sendable {
        let name = "Deliberately faulty test backend"
        var calls = 0
        let fail: Bool
        init(fail: Bool) { self.fail = fail }
        func distances(grid: Grid, inputs: [PathInput]) throws -> [[Int32]] {
            calls += 1
            if fail { throw PathDeviceError(description: "Injected device failure") }
            return inputs.map { _ in Array(repeating: 0, count: grid.count) }
        }
    }

    static func fallback() throws {
        let context = SearchContext(config: config(rows: 11, cols: 11))
        let input = PathInput(sizes: Array(repeating: 121, count: 121), capitols: [0])
        let expected = reference(context, input)
        for fail in [false, true] {
            let backend = BadBackend(fail: fail)
            let evaluator = PathEvaluator(grid: context.grid, mode: .gpu, backend: backend)
            for _ in 0..<2 {
                let result = evaluator.evaluate([input]) { reference(context, $0) }
                try check(result == [expected], "GPU failure did not return exact CPU paths")
            }
            try check(backend.calls == 1 && evaluator.fallbackReason != nil, "Faulty backend was retried")
        }
        let absent = PathEvaluator(grid: context.grid, mode: .gpu, useSystemBackend: false)
        try check(absent.evaluate([input]) { reference(context, $0) } == [expected], "Absent GPU fallback")
        let never = BadBackend(fail: true)
        let cpu = PathEvaluator(grid: context.grid, mode: .cpu, backend: never)
        _ = cpu.evaluate([input]) { reference(context, $0) }
        let tooLarge = SearchContext(config: config(rows: 1, cols: 122))
        let large = PathEvaluator(grid: tooLarge.grid, mode: .gpu, backend: never)
        _ = large.evaluate([PathInput(sizes: Array(repeating: 122, count: 122), capitols: [0])]) { reference(tooLarge, $0) }
        try check(never.calls == 0, "CPU mode or oversized board dispatched GPU")
    }

    private final class ReferenceBackend: GPUPathBackend, @unchecked Sendable {
        let name = "Reference test backend"
        let delay: Double
        init(delay: Double) { self.delay = delay }
        func distances(grid: Grid, inputs: [PathInput]) throws -> [[Int32]] {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let context = SearchContext(config: PathChecks.config(rows: grid.rows, cols: grid.cols))
            return inputs.map { input in
                PathChecks.reference(context, input).distances.map { $0 == Int.max ? PathEvaluator.infinity : Int32($0) }
            }
        }
    }
    static func automaticPolicy() throws {
        let context = SearchContext(config: config(rows: 11, cols: 11))
        let inputs = Array(repeating: PathInput(sizes: Array(repeating: 1, count: 121), capitols: [0]), count: 8)
        let slower = PathEvaluator(grid: context.grid, mode: .automatic, backend: ReferenceBackend(delay: 0.01))
        let expected = inputs.map { reference(context, $0) }
        try check(slower.evaluate(inputs) { reference(context, $0) } == expected, "Automatic comparison changed results")
        try check(slower.fallbackReason != nil && slower.batchSize == 1, "Automatic mode kept a slower backend")
        let faster = PathEvaluator(grid: context.grid, mode: .automatic, backend: ReferenceBackend(delay: 0))
        let actual = faster.evaluate(inputs) { input in
            Thread.sleep(forTimeInterval: 0.002)
            return reference(context, input)
        }
        try check(actual == expected && faster.fallbackReason == nil && faster.gpuBatches == 1, "Automatic mode rejected a faster exact backend")
        try check(faster.evaluate(inputs) { reference(context, $0) } == expected && faster.gpuBatches == 2,
                  "Selected backend did not evaluate later batches")
    }

    static func batchScoresAndCache() throws {
        var random = SearchRandom(seed: 79)
        let context = SearchContext(config: config(rows: 11, cols: 11))
        let sequential = SearchContext(config: context.config)
        var labels = (0..<70).map { _ in (0..<121).map { _ in random.index(30) } }
        labels += [labels[0], labels[32], labels[0]]
        let states = context.evaluateBatch(labels: labels)
        for (partition, state) in zip(labels, states) {
            let expected = sequential.evaluate(labels: partition)
            try check(state.quality == expected.quality && state.parents == expected.parents
                      && state.validation.mismatches.map(\.actual) == expected.validation.mismatches.map(\.actual),
                      "Batch changed scores, mismatches, or routes")
        }
        try check(context.metrics.evaluations == 70 && context.metrics.evaluationCacheHits == 3, "Batch cache/dedup counters")
        states[0].board.Energy[0][0] = 123
        try check(states[70].board.Energy[0][0] != 123, "Repeated labels alias lazy boards")
        try check(context.evaluateBatch(labels: []).isEmpty, "Empty batch")
        // Force a cache hit to be evicted during insertion of the same batch.
        let fresh = SearchContext(config: config(rows: 1, cols: 13))
        func partition(_ mask: Int) -> [Int] { (0..<13).map { mask & (1 << $0) == 0 ? 0 : $0 + 1 } }
        for mask in 0..<2048 { _ = fresh.evaluate(labels: partition(mask)) }
        let first = fresh.evaluate(labels: partition(0))
        let eviction = fresh.evaluateBatch(labels: [partition(0), partition(2048)])
        try check(eviction[0].quality == first.quality, "Same-batch insertion evicted a requested cached board")
        let old = try JSONDecoder().decode(RunConfig.self, from: Data("{}".utf8))
        try check(old.pathEvaluation == .automatic, "Old configuration lost default backend")
        var gpu = old; gpu.pathEvaluation = .gpu
        let decoded = try JSONDecoder().decode(RunConfig.self, from: JSONEncoder().encode(gpu))
        try check(decoded.pathEvaluation == .gpu, "Backend config roundtrip")
    }

    static func hardware() throws {
        let context = SearchContext(config: config(rows: 11, cols: 11))
        let evaluator = PathEvaluator(grid: context.grid, mode: .gpu)
        var random = SearchRandom(seed: 81)
        var elapsed = 0.0, cpuElapsed = 0.0
        for trial in 0..<12 {
            let inputs = (0..<32).map { board in
                PathInput(sizes: (0..<121).map { _ in 1 + random.index(121) },
                          capitols: board == 0 ? [] : board == 1 ? Array(0..<121) : (0..<121).filter { _ in random.index(20) == 0 })
            }
            let cpuStart = ProcessInfo.processInfo.systemUptime
            let expected = inputs.map { reference(context, $0) }
            cpuElapsed += ProcessInfo.processInfo.systemUptime - cpuStart
            let start = ProcessInfo.processInfo.systemUptime
            let actual = evaluator.evaluate(inputs) { reference(context, $0) }
            if trial > 0 { elapsed += ProcessInfo.processInfo.systemUptime - start }
            try check(actual == expected, "Hardware GPU path or parent mismatch")
        }
        if evaluator.gpuBatches == 0 {
            if ProcessInfo.processInfo.environment["JSP_REQUIRE_GPU"] == "1" {
                throw PathDeviceError(description: "GPU required but no device executed: \(evaluator.fallbackReason ?? "unknown")")
            }
            print("GPU hardware unavailable; CPU fallback checks passed.")
        } else {
            try check(evaluator.fallbackReason == nil && evaluator.gpuBoards == 384, "GPU fell back during hardware checks")
            print("GPU: 384 exact boards; warm GPU+certificate \(elapsed)s/352 boards; CPU \(cpuElapsed)s/384 boards.")
        }
        // Maximum simple-path bound and rectangular stride cases on the GPU too.
        for (rows, cols) in [(1, 1), (5, 5), (1, 121), (121, 1), (3, 7)] {
            let ctx = SearchContext(config: config(rows: rows, cols: cols))
            let device = PathEvaluator(grid: ctx.grid, mode: .gpu)
            let input = PathInput(sizes: Array(repeating: ctx.grid.count, count: ctx.grid.count), capitols: [0])
            try check(device.evaluate([input]) { reference(ctx, $0) } == [reference(ctx, input)], "GPU rectangular bound fixture")
            if evaluator.gpuBatches > 0 { try check(device.gpuBoards == 1, "GPU dimension fixture silently fell back") }
        }
        var gpuConfig = context.config; gpuConfig.pathEvaluation = .gpu
        let gpu = SearchContext(config: gpuConfig)
        let partitions = (0..<32).map { _ -> [Int] in
            var labels = Array(repeating: 0, count: 121), label = 0
            for row in 0..<11 {
                var col = 0
                while col < 11 {
                    let width = min(11 - col, 1 + random.index(5))
                    for c in col..<(col + width) { labels[row * 11 + c] = label }
                    col += width; label += 1
                }
            }
            return labels
        }
        for (partition, result) in zip(partitions, gpu.evaluateBatch(labels: partitions)) {
            let expected = context.evaluate(labels: partition)
            try check(result.quality == expected.quality && result.scores.total == expected.scores.total
                      && result.parents == expected.parents
                      && result.validation.mismatches.map(\.actual) == expected.validation.mismatches.map(\.actual),
                      "GPU batch changed integrated scores, mismatches or routes")
        }
        if evaluator.gpuBatches > 0 { try check(gpu.pathEvaluator.gpuBoards == 32, "Integrated GPU scorer was not dispatched") }
        gpu.config.pathEvaluation = .cpu
        try check(gpu.pathEvaluator.mode == .cpu, "Reused context ignored changed backend policy")

        var repairConfig = RunConfig.example
        repairConfig.pathEvaluation = .gpu; repairConfig.maxMergeRegions = 3
        let merge = SearchContext(config: repairConfig)
        let saved = [0,1,1,2,2, 0,1,1,3,2, 4,4,3,3,2, 2,5,5,5,2, 2,2,2,2,2]
        let source = merge.evaluate(labels: saved)
        let repaired = merge.mergeRepair(source, until: ProcessInfo.processInfo.systemUptime + 10)
        try check(repaired?.validation.valid == true && repaired?.validation.answer?.sumOfSquares == 8045,
                  "GPU merge repair lost the independently verified 8045 fixture")
        var coverConfig = config(rows: 2, cols: 3)
        coverConfig.pathEvaluation = .gpu
        coverConfig.Target = OriginalCondition(Status: [[0,1,3], [0,1,3]])
        let cover = SearchContext(config: coverConfig)
        let covered = cover.cover(patch: Array(0..<6), base: Array(0..<6),
                                  candidates: [[0],[3],[1,2],[4,5]], until: ProcessInfo.processInfo.systemUptime + 10)
        try check(covered?.validation.valid == true && covered?.validation.answer?.sumOfSquares == 50,
                  "GPU exact cover failed to flush its final partial batch")
        var boundaryConfig = config(rows: 1, cols: 70)
        boundaryConfig.pathEvaluation = .gpu
        boundaryConfig.Target = OriginalCondition(Status: [[4693] + Array(repeating: -1, count: 69)])
        let boundary = SearchContext(config: boundaryConfig)
        let split = boundary.boundaryRepair(boundary.evaluate(labels: Array(repeating: 0, count: 70)),
                                           until: ProcessInfo.processInfo.systemUptime + 10)
        try check(split?.validation.valid == true, "GPU boundary repair lost the exact 69+1 split")
        if evaluator.gpuBatches > 0 {
            try check(merge.pathEvaluator.gpuBoards > 1 && cover.pathEvaluator.gpuBoards > 0
                      && boundary.pathEvaluator.gpuBoards > 1, "Repair integration silently fell back")
        }
    }
}

#if STANDALONE_PATH_TESTS
@main
struct StandalonePathTests {
    static func main() throws {
        try PathChecks.certificates()
        try PathChecks.fallback()
        try PathChecks.automaticPolicy()
        try PathChecks.batchScoresAndCache()
        try PathChecks.hardware()
        print("Passed GPU path, certificate, fallback, batch, cache, and precision checks.")
    }
}
#else
struct GPUPathTests {
    @Test func certificates() throws { try PathChecks.certificates() }
    @Test func fallback() throws { try PathChecks.fallback() }
    @Test func automaticPolicy() throws { try PathChecks.automaticPolicy() }
    @Test func batchScoresAndCache() throws { try PathChecks.batchScoresAndCache() }
    @Test func hardware() throws { try PathChecks.hardware() }
    @Test func clientBackendIsLocal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gpu-client-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = RunConfig.example
        config.distributed.stateDirectory = directory.path
        config.pathEvaluation = .cpu
        let engine = try ClientEngine(settings: config.distributed, pathEvaluation: .gpu)
        try await engine.configure(config, runID: UUID())
        let saved = await engine.savedConfig()
        #expect(saved?.pathEvaluation == .gpu)
    }
}
#endif
