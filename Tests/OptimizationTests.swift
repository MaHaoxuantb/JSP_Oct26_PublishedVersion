import Foundation

@main
struct OptimizationTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            try? FileHandle.standardError.write(contentsOf: Data("FAILED: \(message)\n".utf8))
            exit(1)
        }
    }
    static func config(rows: Int, cols: Int, clues: [Int]) -> RunConfig {
        var c = RunConfig.example
        c.rowNum = rows; c.colNum = cols
        c.Target = OriginalCondition(Status: (0..<rows).map { Array(clues[($0 * cols)..<(($0 + 1) * cols)]) })
        c.consoleLogging = false
        return c
    }
    static func constraints() {
        let c = SearchContext(config: RunConfig.fullPuzzle)
        check(c.constraints.minimumSizes[10 * 11 + 8] == 16 && c.constraints.minimumSizes[10 * 11 + 9] == 16,
              "Adjacent 77/61 clues did not propagate area bounds")
        let cells = [0, 1, 2, 3, 6] // L pentomino, capitol at (0,0)
        let bad = SearchContext(config: config(rows: 3, cols: 3, clues: [0, -1, 11, -1, -1, -1, -1, -1, -1]))
        check(!bad.permits(cells), "Internal route upper bound failed to reject an impossible clue")
        let good = SearchContext(config: config(rows: 3, cols: 3, clues: [0, -1, 10, -1, -1, -1, -1, -1, -1]))
        check(good.permits(cells), "Internal route bound rejected equality")

        // Derive clue sets from independently evaluated legal partitions. Every
        // constituent region must survive the deductions, including capless states.
        let base = SearchContext(config: config(rows: 3, cols: 3, clues: Array(repeating: 0, count: 9)))
        var checked = 0
        for mask in 1..<(1 << 9) {
            let labels = (0..<9).map { mask & (1 << $0) != 0 ? 0 : $0 + 1 }
            let report = ExactValidator().validate(base.board(labels: labels), target: base.config.Target)
            guard report.issues.isEmpty, !report.capitols.isEmpty else { continue }
            var clues = Array(repeating: 0, count: 9)
            for m in report.mismatches { clues[m.cell.row * 3 + m.cell.col] = m.actual! }
            let derived = SearchContext(config: config(rows: 3, cols: 3, clues: clues))
            for part in base.groups(labels) { check(derived.permits(part), "Sound deduction rejected a known valid region") }
            checked += 1
        }
        check(checked > 20, "Too few independent constraint fixtures")
        print("Validated area/internal-route deductions on \(checked) legal partitions.")
    }
    static func pathsAndCaches() {
        let context = SearchContext(config: RunConfig.fullPuzzle)
        var random = SearchRandom(seed: 71)
        for _ in 0..<100 {
            let sizes = (0..<121).map { _ in 1 + random.index(121) }
            let capitals = (0..<121).filter { _ in random.index(20) == 0 }
            let a = context.shortestPaths(sizes: sizes, capitols: capitals, heap: false)
            let b = context.shortestPaths(sizes: sizes, capitols: capitals, heap: true)
            check(a.0 == b.0 && a.1 == b.1, "Heap and scan disagree")
        }
        for _ in 0..<30 {
            let labels = (0..<121).map { _ in random.index(20) }
            let state = context.evaluate(labels: labels)
            let report = ExactValidator().validate(state.board, target: context.config.Target)
            check(report.mismatches.map(\.actual) == state.validation.mismatches.map(\.actual), "Large-grid independent distance disagreement")
            check(Set(report.capitols) == Set(state.validation.capitols), "Large-grid capitol disagreement")
        }
        let labels = Array(0..<121)
        let first = context.evaluate(labels: labels)
        let before = context.metrics.evaluations
        first.board.Relationships.ColorBlocks[0][0] = first.board.Relationships.ColorBlocks[0][1]
        let cached = context.evaluate(labels: labels)
        check(context.metrics.evaluations == before && context.metrics.evaluationCacheHits > 0, "Partition cache missed")
        check(context.canonical(cached.board) == labels, "Mutating a materialized Board corrupted the evaluation cache")
        let materialized = SearchState(board: cached.board, scores: cached.scores, validation: cached.validation)
        let materializedCopy = materialized.snapshot().snapshot()
        materializedCopy.board.Energy[0][0] = 101
        check(materialized.board.Energy[0][0] != 101, "Materialized constructor aliases its snapshot")
        let copy = cached.snapshot()
        copy.board.Energy[0][0] = 100
        check(cached.board.Energy[0][0] != 100, "Lazy snapshot aliases display state")
        let cache = BoundedCache<Int, Int>(capacity: 2)
        cache[1] = 10; cache[2] = 20; cache[3] = 30
        check(cache[1] == nil && cache[2] == 20 && cache[3] == 30, "Eviction cleared useful entries")

        // Fixed-data microbenchmark only. No fresh puzzle search.
        for n in [5, 11] {
            let ctx = SearchContext(config: config(rows: n, cols: n, clues: Array(repeating: 0, count: n * n)))
            let sizes = (0..<(n * n)).map { 1 + ($0 * 17) % (n * n) }
            var checksum = 0
            for heap in [false, true] {
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0..<2_000 { checksum &+= ctx.shortestPaths(sizes: sizes, capitols: [0, n * n - 1], heap: heap).0[n] }
                print("\(n)x\(n) \(heap ? "heap" : "scan") paths: \(ProcessInfo.processInfo.systemUptime - start)s / 2000")
            }
            check(checksum > 0, "Microbenchmark results unused")
        }
    }
    static func largeMasksAndRepairs() {
        var a = CellMask(count: 200, cells: [0, 63, 64, 120, 130, 199])
        let b = CellMask(count: 200, cells: [64, 129, 199])
        check(a.intersects(b), "Multiword overlap missed")
        a.formUnion(b); a.subtract(CellMask(count: 200, cells: [0, 64, 199]))
        check(a.cells == [63, 120, 129, 130], "Multiword set operations incorrect")
        let zeros = SearchContext(config: config(rows: 1, cols: 70, clues: Array(repeating: 0, count: 70)))
        let cells = Array(0..<70)
        let cover = zeros.cover(patch: cells, base: cells, candidates: cells.map { [$0] },
                               until: ProcessInfo.processInfo.systemUptime + 10, firstOnly: true)
        check(cover?.validation.valid == true, "Cover failed beyond the former UInt64 limit")
        var limited = zeros.config
        limited.catalogCandidateLimit = 128; limited.catalogMasksPerTransform = 4
        let catalog = SearchContext(config: limited).regionCatalog(patch: cells, until: ProcessInfo.processInfo.systemUptime + 10)
        check(catalog.count == 70, "Large catalog lost singleton candidates")
        var clues = Array(repeating: -1, count: 70); clues[0] = 4693
        let context = SearchContext(config: config(rows: 1, cols: 70, clues: clues))
        let source = context.evaluate(labels: Array(repeating: 0, count: 70))
        let result = context.boundaryRepair(source, until: ProcessInfo.processInfo.systemUptime + 10)
        check(result?.validation.valid == true, "A 70-cell state could not be split into the valid 69+1 partition")
        check(source.labels.allSatisfy { $0 == 0 }, "Boundary repair changed its source")
    }
    static func routeBoundEquivalence() {
        let patch = [0, 1, 2, 14, 15, 16]
        let base = Array(0..<28)
        var pruned = 0
        for objective in SearchObjective.allCases {
            for target in 1...9 {
                var clues = Array(repeating: -1, count: 28)
                clues[1] = target; clues[27] = 100
                var c = config(rows: 2, cols: 14, clues: clues)
                c.searchObjective = objective
                c.exactCoverNodeLimit = 100_000; c.exactCoverSolutionLimit = 100_000
                let bounded = SearchContext(config: c)
                c.useRouteBounds = false
                let exhaustive = SearchContext(config: c)
                let candidates = (1..<(1 << patch.count)).map { mask in
                    patch.indices.filter { mask & (1 << $0) != 0 }.map { patch[$0] }
                }
                let a = bounded.cover(patch: patch, base: base, candidates: candidates,
                                      until: ProcessInfo.processInfo.systemUptime + 10)
                let b = exhaustive.cover(patch: patch, base: base, candidates: candidates,
                                         until: ProcessInfo.processInfo.systemUptime + 10)
                check((a == nil) == (b == nil), "Route bounds changed cover feasibility")
                if let a, let b {
                    check(abs(bounded.merit(a) - exhaustive.merit(b)) < 1e-12 && a.quality == b.quality,
                          "Route pruning lost the best bounded-fixture cover")
                }
                pruned += bounded.metrics.routePrunes
            }
        }
        print("Route-bound differential checks passed; \(pruned) branches pruned.")
    }

    static func checkpoints() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        var c = config(rows: 1, cols: 1, clues: [0]); c.logDirectory = folder.path
        let state = SearchContext(config: c).evaluate(labels: [0])
        let logger = try Logger(directory: folder.path, console: false)
        try logger.checkpoint(config: c, state: state, iteration: 10)
        try logger.checkpoint(config: c, state: state, iteration: 20)
        let (loaded, snapshot) = try SavedRunRepair.load(path: logger.checkpointURL.path)
        check(loaded.rowNum == 1 && loaded.Target.Status == [[0]] && snapshot.validation.valid, "Checkpoint roundtrip failed")
        let resumed = try await Main().Run(Config: loaded, initialLabels: snapshot.labels.flatMap { $0 })
        check(resumed.reason == .solved && resumed.statistics.iterations == 0, "Resume did not use its initial board")
        try logger.close()
    }
    static func main() async throws {
        constraints(); pathsAndCaches(); largeMasksAndRepairs(); routeBoundEquivalence(); try await checkpoints()
        print("Passed optimization deductions, paths, caches, large repairs and checkpoint checks.")
    }
}
