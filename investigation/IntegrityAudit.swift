import Foundation

/// Read-only diagnostics. No Main.Run, distributed state or network operations.
@main
struct IntegrityAudit {
    static func configuration(_ n: Int, _ clues: [Int]) -> RunConfig {
        var c = RunConfig.example
        c.rowNum = n; c.colNum = n
        c.Target = OriginalCondition(Status: (0..<n).map { Array(clues[$0*n..<($0+1)*n]) })
        c.pathEvaluation = .cpu; c.consoleLogging = false
        c.exactCoverNodeLimit = 100_000; c.exactCoverSolutionLimit = 100_000
        c.useRouteBounds = false
        return c
    }

    static func actualClues(_ labels: [Int], context: SearchContext) -> [Int]? {
        let n = context.grid.rows
        let report = ExactValidator().validate(context.board(labels: labels),
            target: OriginalCondition(Status: Array(repeating: Array(repeating: 0, count: n), count: n)))
        guard report.issues.isEmpty, !report.capitols.isEmpty else { return nil }
        var clues = Array(repeating: 0, count: labels.count)
        for mismatch in report.mismatches {
            guard let value = mismatch.actual else { return nil }
            clues[mismatch.cell.row*n+mismatch.cell.col] = value
        }
        return clues
    }

    static func legalPartitions3() -> [[Int]] {
        let base = SearchContext(config: configuration(3, Array(repeating: -1, count: 9)))
        var byCell = Array(repeating: [[Int]](), count: 9)
        for mask in 1..<(1 << 9) {
            let cells = (0..<9).filter { mask & (1 << $0) != 0 }
            let g = base.regions.geometry(cells)
            if g.connected && g.symmetric { for cell in cells { byCell[cell].append(cells) } }
        }
        var labels = Array(repeating: -1, count: 9), output: [[Int]] = []
        func visit(_ id: Int) {
            guard let cell = labels.firstIndex(of: -1) else { output.append(labels); return }
            for part in byCell[cell] where part.allSatisfy({ labels[$0] == -1 }) {
                for cell in part { labels[cell] = id }
                visit(id+1)
                for cell in part { labels[cell] = -1 }
            }
        }
        visit(0)
        return output
    }

    static func soundness(_ partitions: [[Int]]) -> [String: Any] {
        let base = SearchContext(config: configuration(3, Array(repeating: -1, count: 9)))
        var checked = 0, failures: [[String: Any]] = []
        for labels in partitions {
            guard let clues = actualClues(labels, context: base) else { continue }
            let parts = base.groups(labels)
            let sizes = labels.indices.map { parts[labels[$0]].count }
            for mode in 0..<4 {
                let partial = clues.enumerated().map { mode == 3 || $0.offset % 3 == mode ? $0.element : -1 }
                let c = SearchContext(config: configuration(3, partial))
                let bad = parts.filter { !c.permits($0) }
                let badPairs = c.constraints.pairBounds.filter { sizes[$0.first]+sizes[$0.second] < $0.minimum }
                if !bad.isEmpty || !badPairs.isEmpty || !c.constraints.forcedSingletons.allSatisfy({ sizes[$0] == 1 }) {
                    if failures.count < 3 { failures.append(["labels": labels, "clues": partial, "rejected": bad]) }
                }
                checked += 1
            }
        }
        return ["legal_partitions": partitions.count, "clue_fixtures": checked, "failures": failures]
    }

    /// Same supplied catalog, geometry filters and one-clue checks as production,
    /// but with cross-state pair-area pruning omitted. Exhausts this small patch.
    static func referenceCover(_ patch: [Int], source: SearchState, candidates: [[Int]], context c: SearchContext) -> SearchState? {
        let allowed = Set(patch), parts = c.groups(source.labels)
        let shapes = Array(Set(candidates.map { $0.sorted() })).filter { !$0.isEmpty && $0.allSatisfy { allowed.contains($0) } && c.permits($0) }
        var labels = source.labels
        var sizes = Array(repeating: 0, count: c.grid.count)
        for part in parts where part.allSatisfy({ !allowed.contains($0) }) { for cell in part { sizes[cell] = part.count } }
        var used = Set(labels.indices.filter { !allowed.contains($0) })
        var best: SearchState?
        let id = (labels.max() ?? 0)+1
        func visit(_ depth: Int) {
            guard let cell = patch.first(where: { !used.contains($0) }) else {
                guard !c.samePartition(labels, source.labels) else { return }
                for one in c.constraints.clues.indices where c.constraints.clues[one] == 1
                    && (allowed.contains(one) || c.grid.neighbors(one).contains(where: { allowed.contains($0) })) {
                    if !c.grid.neighbors(one).contains(where: { sizes[$0] == 1 }) { return }
                }
                let candidate = c.evaluate(labels: labels)
                if best == nil || c.prefers(candidate, over: best!) { best = candidate }
                return
            }
            for shape in shapes where shape.contains(cell) && shape.allSatisfy({ !used.contains($0) }) {
                for cell in shape { used.insert(cell); labels[cell] = id+depth; sizes[cell] = shape.count }
                visit(depth+1)
                for cell in shape { used.remove(cell); labels[cell] = source.labels[cell]; sizes[cell] = 0 }
            }
        }
        visit(0)
        return best
    }

    static func searchPruning(_ partitions: [[Int]]) -> [String: Any] {
        var rng = SearchRandom(seed: 1337)
        let base = SearchContext(config: configuration(3, Array(repeating: -1, count: 9)))
        let valid = partitions.compactMap { labels -> ([Int], [Int])? in
            actualClues(labels, context: base).map { (labels, $0) }
        }
        for trial in 0..<3000 {
            let target = valid[rng.index(valid.count)]
            let sourceLabels = valid[rng.index(valid.count)].0
            let clues = target.1.enumerated().map { rng.index(3) == 0 ? -1 : $0.element }
            let c = SearchContext(config: configuration(3, clues))
            let source = c.evaluate(labels: sourceLabels)
            if source.validation.valid { continue }
            let parts = c.groups(source.labels)
            let seed = rng.index(parts.count)
            var ids: Set<Int> = [seed]
            for _ in 0..<2 {
                let neighbors = Set(ids.flatMap { parts[$0] }.flatMap { c.grid.neighbors($0) }.map { source.labels[$0] }).subtracting(ids).sorted()
                if let next = neighbors.first { ids.insert(next) }
            }
            let patch = ids.sorted().flatMap { parts[$0] }.sorted()
            guard patch.count < 9 else { continue }
            let catalog = c.initialCatalog(until: .infinity).filter { Set($0).isSubset(of: Set(patch)) }
            let produced = c.cover(patch: patch, base: source.labels, candidates: catalog, until: .infinity)
            guard let reference = referenceCover(patch, source: source, candidates: catalog, context: c),
                  reference.quality < source.quality,
                  produced == nil || reference.quality < produced!.quality else { continue }
            return ["found": true, "trial": trial, "clues": clues, "source": source.labels,
                    "complete_solution": target.0,
                    "patch": patch, "catalog": catalog, "reference": reference.labels,
                    "source_wrong": source.quality.wrong, "source_error": source.quality.error,
                    "reference_wrong": reference.quality.wrong, "reference_error": reference.quality.error,
                    "production_wrong": produced?.quality.wrong as Any? ?? NSNull(),
                    "production_error": produced?.quality.error as Any? ?? NSNull(),
                    "pair_bounds": c.constraints.pairBounds.map { [$0.first,$0.second,$0.minimum] }]
        }
        return ["found": false, "trials": 3000]
    }

    static func knownPruningRegression() -> [String: Any] {
        let context = SearchContext(config: configuration(3, [-1,1,3,-1,-1,1,0,1,3]))
        let source = context.evaluate(labels: [0,1,1,0,2,1,2,2,3])
        let catalog = [[0],[0,1],[0,1,2],[0,1,3],[0,3],[1,2],[2,5],[3],[3,6,7],[4],[6]]
        let repaired = context.cover(patch: Array(0..<8), base: source.labels,
                                     candidates: catalog, until: .infinity)
        return ["source_wrong": source.quality.wrong,
                "repaired_wrong": repaired?.quality.wrong as Any? ?? NSNull(),
                "still_imperfect": repaired?.validation.valid == false]
    }

    static func repairPortfolio() -> [String: Any] {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let path = directory.appendingPathComponent("logs/workers/slot-3/checkpoint-EFA932D5-3AE4-4115-8808-A9E411EFAC50.json")
        guard let (_, snapshot) = try? SavedRunRepair.load(path: path.path) else { return ["skipped": "Historical local fixture unavailable"] }
        var config = RunConfig.fullPuzzle
        config.pathEvaluation = .cpu; config.consoleLogging = false
        var runs: [[String: Any]] = []
        for seconds in [0.02, 0.15] {
            config.repairTimeLimitSeconds = seconds
            let context = SearchContext(config: config)
            let source = context.evaluate(labels: snapshot.labels.flatMap { $0 })
            var fallback = 0, proposals = 0, nilMoves = 0, total = 0.0
            for _ in 0..<16 {
                context.proposalNumber = 11
                let ticket = context.repairTicket
                let start = ProcessInfo.processInfo.systemUptime
                let result = context.repairProposal(source)
                total += ProcessInfo.processInfo.systemUptime-start
                if result != nil { proposals += 1 } else { nilMoves += 1 }
                if context.repairTicket != ticket { fallback += 1 }
            }
            runs.append(["repair_seconds": seconds, "large_turns": 16,
                         "old_large_patch_path_used": fallback, "returned_proposals": proposals,
                         "nil_moves": nilMoves, "elapsed": total,
                         "large_rebuild_attempts": context.largeShapeAttempts,
                         "archive_count": context.largeShapes.count,
                         "even_archive_states": context.largeShapes.filter { $0.count % 2 == 0 }.count])
            // Control: give the former large-patch route the same per-call
            // deadline, without spending any of it on the new archive lane.
            let control = SearchContext(config: config)
            let oldSource = control.evaluate(labels: source.labels)
            var oldProposals = 0
            for _ in 0..<16 {
                let until = ProcessInfo.processInfo.systemUptime + seconds
                let patch = control.patchCells(oldSource, large: true)
                var candidates = control.regionCatalog(patch: patch,
                    until: min(until, ProcessInfo.processInfo.systemUptime+seconds/3))
                let allowed = Set(patch)
                candidates += control.groups(oldSource.labels).filter { Set($0).isSubset(of: allowed) }
                if control.cover(patch: patch, base: oldSource.labels, candidates: candidates, until: until) != nil { oldProposals += 1 }
            }
            runs[runs.count-1]["legacy_path_control_proposals"] = oldProposals
            runs[runs.count-1]["legacy_path_control_cover_nodes"] = control.metrics.coverNodes
            runs[runs.count-1]["new_path_total_cover_nodes"] = context.metrics.coverNodes
        }
        return ["fixture": path.lastPathComponent, "runs": runs]
    }

    static func catalogSaturation() -> [String: Any] {
        var c = configuration(3, [-1,-1,-1,-1,0,-1,-1,-1,-1])
        c.catalogCandidateLimit = 2
        let context = SearchContext(config: c), patch = Array(0..<9)
        let first = context.regionCatalog(patch: patch, until: .infinity)
        let before = context.growthSteps
        for _ in 0..<16 { _ = context.regionCatalog(patch: patch, until: .infinity) }
        let last = context.catalogs[patch] ?? []
        return ["limit": 2, "first": first, "last": last,
                "additional_growth_steps": context.growthSteps-before,
                "generic_cursor_created": context.regionSampling[patch] != nil,
                "all_cells_have_a_candidate": patch.allSatisfy { cell in last.contains { $0.contains(cell) } }]
    }

    static func parityAndCursorLimits() -> [String: Any] {
        var c = RunConfig.example
        c.rowNum = 1; c.colNum = 37; c.pathEvaluation = .cpu
        var clues = Array(repeating: -1, count: 37); clues[0] = 1261; clues[36] = 0
        c.Target = OriginalCondition(Status: [clues])
        let line = SearchContext(config: c)
        let labels = Array(repeating: 0, count: 36) + [1]
        let valid = ExactValidator().validate(line.board(labels: labels), target: c.Target)

        let ctx = SearchContext(config: configuration(3, [-1,-1,-1,-1,0,-1,-1,-1,-1]))
        let firstPatch = Array(1..<9)
        _ = ctx.sampleRegionShapes(patch: firstPatch, until: .infinity, budget: 1)
        let first = ctx.regionSampling[firstPatch]!
        for removed in 1..<9 {
            _ = ctx.sampleRegionShapes(patch: (0..<9).filter { $0 != removed }, until: .infinity, budget: 1)
        }
        let evicted = ctx.regionSampling[firstPatch] == nil
        _ = ctx.sampleRegionShapes(patch: firstPatch, until: .infinity, budget: 1)
        let resumed = ctx.regionSampling[firstPatch]!
        return ["legal_36_cell_state_validated": valid.valid, "distance_clue": 1261,
                "cursor_evicted_after_other_patches": evicted,
                "same_cursor_on_return": resumed === first,
                "samples_after_return": resumed.totalSamples]
    }

    static func geometryAndBounds4() -> [String: Any] {
        let base = SearchContext(config: configuration(4, Array(repeating: 0, count: 16)))
        var geometryChecks = 0, deductionChecks = 0, failures: [[String: Any]] = []
        for mask in 1..<(1 << 16) {
            let cells = (0..<16).filter { mask & (1 << $0) != 0 }
            let labels = (0..<16).map { mask & (1 << $0) != 0 ? 0 : $0+1 }
            let geometry = base.regions.geometry(cells)
            let exact = ExactValidator().validate(base.board(labels: labels), target: base.config.Target)
            let selected = Set(cells)
            let cap = exact.capitols.map { $0.row*4+$0.col }.first { selected.contains($0) }
            if (exact.issues.isEmpty != (geometry.connected && geometry.symmetric)) || cap != geometry.capitol {
                if failures.count < 3 { failures.append(["mask": mask, "kind": "geometry"]) }
            }
            geometryChecks += 1
            guard exact.issues.isEmpty, !exact.capitols.isEmpty else { continue }
            var full = Array(repeating: 0, count: 16)
            for mismatch in exact.mismatches { full[mismatch.cell.row*4+mismatch.cell.col] = mismatch.actual! }
            for parity in 0..<2 {
                let partial = full.enumerated().map { parity == 0 || $0.offset % 2 == 0 ? $0.element : -1 }
                let context = SearchContext(config: configuration(4, partial))
                if !base.groups(labels).allSatisfy({ context.permits($0) }) {
                    if failures.count < 3 { failures.append(["mask": mask, "kind": "deductions", "clues": partial]) }
                }
                deductionChecks += 1
            }
        }
        return ["geometry_masks": geometryChecks, "deduction_fixtures": deductionChecks, "failures": failures]
    }

    static func main() throws {
        let partitions = legalPartitions3()
        let sound = soundness(partitions)
        print("Soundness: \(sound)")
        let pruning = searchPruning(partitions)
        print("Pruning reproduction: \(pruning)")
        let portfolio = repairPortfolio()
        print("Large repair portfolio: \(portfolio)")
        let geometry4 = geometryAndBounds4()
        print("4x4 geometry and deductions: \(geometry4)")
        let output: [String: Any] = ["soundness": sound, "cross_state_pruning": pruning,
                                   "large_repair_portfolio": portfolio, "catalog_saturation": catalogSaturation(),
                                   "geometry_and_bounds_4x4": geometry4, "parity_and_cursor_limits": parityAndCursorLimits(),
                                   "known_pruning_regression": knownPruningRegression()]
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
