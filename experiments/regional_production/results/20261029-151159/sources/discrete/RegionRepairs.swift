import Foundation

struct RepairMetrics: Codable, Sendable {
    var evaluationSeconds = 0.0
    var distanceSeconds = 0.0
    var geometrySeconds = 0.0
    var catalogSeconds = 0.0
    var coverSeconds = 0.0
    var mergeSeconds = 0.0
    var boundarySeconds = 0.0
    var evaluationCacheHits = 0
    var constraintRejects = 0
    var routePrunes = 0
    var boundaryChecks = 0
    var evaluations = 0
    var mergesChecked = 0
    var mergeCacheHits = 0
    var catalogMasks = 0
    var catalogCacheHits = 0
    var coverNodes = 0
    var coversChecked = 0
    var budgetStops = 0
    var eliteImports = 0

    mutating func add(_ other: Self) {
        evaluationSeconds += other.evaluationSeconds
        distanceSeconds += other.distanceSeconds
        geometrySeconds += other.geometrySeconds
        catalogSeconds += other.catalogSeconds
        coverSeconds += other.coverSeconds
        mergeSeconds += other.mergeSeconds
        boundarySeconds += other.boundarySeconds
        evaluationCacheHits += other.evaluationCacheHits
        constraintRejects += other.constraintRejects
        routePrunes += other.routePrunes
        boundaryChecks += other.boundaryChecks
        evaluations += other.evaluations
        mergesChecked += other.mergesChecked
        mergeCacheHits += other.mergeCacheHits
        catalogMasks += other.catalogMasks
        catalogCacheHits += other.catalogCacheHits
        coverNodes += other.coverNodes
        coversChecked += other.coversChecked
        budgetStops += other.budgetStops
        eliteImports += other.eliteImports
    }
}

/// A consumed scan is reusable only under the same ranking and enumeration rules.
struct MergeScanKey: Hashable {
    let labels: [Int]
    let objective: String
    let weights: [Double]
    let maxRegions: Int
    let strictFeasibility: Bool

    init(labels: [Int], context: SearchContext, exactRanking: Bool, strictFeasibility: Bool = false) {
        self.labels = labels
        objective = exactRanking ? "exact" : context.config.searchObjective.rawValue
        weights = !exactRanking && context.config.searchObjective == .persistent ? context.clueWeights : []
        maxRegions = context.config.maxMergeRegions
        self.strictFeasibility = strictFeasibility
    }
}

/// Resumable enumeration of connected subsets of a region adjacency graph.
/// The topology key ignores UUIDs and relationship confidence.
final class MergeCursor {
    let groups: [[Int]]
    let adjacent: [Set<Int>]
    var queue: [[Int]]
    var seen: Set<[Int]>
    var next = 0
    var truncated = false
    init(labels: [Int], context: SearchContext) {
        groups = context.groups(labels)
        var adjacent = Array(repeating: Set<Int>(), count: groups.count)
        for cell in labels.indices {
            for neighbor in context.grid.neighbors(cell) where labels[cell] != labels[neighbor] {
                adjacent[labels[cell]].insert(labels[neighbor])
            }
        }
        self.adjacent = adjacent
        queue = groups.indices.map { [$0] }
        seen = Set(queue)
    }
}

extension SearchContext {
    /// Try connected unions of two through four regions without requiring any
    /// intermediate pairwise merge to be legal. Subsequent calls resume the scan.
    func mergeRepair(_ source: SearchState, until: Double, exactRanking: Bool = false,
                     strictFeasibility: Bool = false) -> SearchState? {
        let started = ProcessInfo.processInfo.systemUptime
        defer { metrics.mergeSeconds += ProcessInfo.processInfo.systemUptime - started }
        let labels = source.labels
        let key = MergeScanKey(labels: labels, context: self, exactRanking: exactRanking,
                               strictFeasibility: strictFeasibility)
        let cursor: MergeCursor
        if let cached = mergeCursors[key] {
            cursor = cached
            metrics.mergeCacheHits += 1
        } else {
            cursor = MergeCursor(labels: labels, context: self)
            mergeCursors[key] = cursor
        }
        var best: SearchState?
        var checked = 0
        var pending: [[Int]] = []
        func flush() {
            for candidate in evaluateBatch(labels: pending) {
                if candidate.validation.valid { best = candidate; break }
                if exactRanking ? candidate.quality < (best ?? source).quality : prefers(candidate, over: best ?? source) { best = candidate }
            }
            pending.removeAll(keepingCapacity: true)
        }
        while cursor.next < cursor.queue.count && checked < config.mergeCandidateLimit && !expired(until) {
            let cluster = cursor.queue[cursor.next]
            cursor.next += 1
            if cluster.count < config.maxMergeRegions {
                let frontier = cluster.reduce(into: Set<Int>()) { $0.formUnion(cursor.adjacent[$1]) }
                for neighbor in frontier.sorted() where neighbor > cluster[0] && !cluster.contains(neighbor) {
                    let extended = (cluster + [neighbor]).sorted()
                    if !cursor.seen.contains(extended) {
                        if cursor.queue.count < 50_000 {
                            cursor.seen.insert(extended)
                            cursor.queue.append(extended)
                        } else { cursor.truncated = true }
                    }
                }
            }
            guard cluster.count >= 2 else { continue }
            checked += 1
            metrics.mergesChecked += 1
            let cells = cluster.flatMap { cursor.groups[$0] }.sorted()
            guard permits(cells, policy: strictFeasibility ? .feasible : .repair) else { continue }
            var merged = labels
            for cell in cells { merged[cell] = cluster[0] }
            if strictFeasibility {
                let sizes = Dictionary(grouping: merged, by: { $0 }).mapValues(\.count)
                let affected = Set(cells + cells.flatMap { grid.neighbors($0) })
                guard affected.filter({ constraints.clues[$0] == 1 }).allSatisfy({ cell in
                    grid.neighbors(cell).contains { sizes[merged[$0]] == 1 }
                }) else { continue }
            }
            pending.append(merged)
            if pending.count >= pathEvaluator.batchSize { flush() }
            if best?.validation.valid == true { return best }
        }
        flush()
        if cursor.next < cursor.queue.count || cursor.truncated { metrics.budgetStops += 1 }
        return best
    }

    /// Cheap palette for initial exact covers: rectangles and bent triominoes.
    /// There is no assumed number of states, and failure to cover with this
    /// limited palette is not a proof that the puzzle is impossible.
    func initialCatalog(until: Double) -> [[Int]] {
        var result = Set<[Int]>()
        func add(_ cells: [Int]) {
            let cells = cells.sorted()
            if permits(cells) { result.insert(cells) }
        }
        let needed = constraints.minimumSizes.max() ?? 1
        let maxSide = needed > 12 ? max(grid.rows, grid.cols) : 4
        let maxArea = max(12, min(grid.count, needed > grid.count / 2 ? grid.count : needed * 2))
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                if expired(until) { return result.sorted { $0.lexicographicallyPrecedes($1) } }
                for height in 1...min(maxSide, grid.rows - row) {
                    for width in 1...min(maxSide, grid.cols - col) where height * width <= maxArea {
                        add((row..<(row + height)).flatMap { r in (col..<(col + width)).map { r * grid.cols + $0 } })
                    }
                }
                if row + 1 < grid.rows && col + 1 < grid.cols {
                    let square = [row * grid.cols + col, row * grid.cols + col + 1,
                                  (row + 1) * grid.cols + col, (row + 1) * grid.cols + col + 1]
                    for missing in square { add(square.filter { $0 != missing }) }
                }
            }
        }
        return result.sorted { $0.lexicographicallyPrecedes($1) }
    }

    func initialState() -> SearchState {
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + config.repairTimeLimitSeconds * 4)
        let labels = Array(0..<grid.count)
        initializationCount += 1
        if initialShapes.isEmpty { initialShapes.formUnion(initialCatalog(until: until)) }
        // Keep reusable valid shapes between restarts and periodically diversify
        // the capitol growth samples instead of rebuilding every palette.
        if initializationCount % 4 == 1 && initialShapes.count < config.catalogCandidateLimit {
            initialShapes.formUnion(capitolCatalog(until: min(until,
                ProcessInfo.processInfo.systemUptime + config.repairTimeLimitSeconds)))
        }
        let catalog = initialShapes.sorted { $0.lexicographicallyPrecedes($1) }
        if let state = cover(patch: labels, base: labels, candidates: catalog, until: until,
                             firstOnly: true, strictFeasibility: true) {
            return state
        }
        // Always return a structurally legal board even if constraints are
        // contradictory or the bounded initial cover search ran out of time.
        return evaluate(labels: labels)
    }

    /// Resumable growth includes forced and unnumbered capitol anchors.
    func capitolCatalog(until: Double) -> [[Int]] {
        growCapitolShapes(patch: Array(0..<grid.count), until: until,
                          budget: config.catalogMasksPerTransform)
    }

    /// Generate symmetric candidates as unions of transformation orbits.
    /// Work and memory are bounded; a truncated catalog is explicitly heuristic.
    func regionCatalog(patch: [Int], until: Double, policy: ShapePolicy = .feasible) -> [[Int]] {
        let patch = patch.sorted()
        let catalogs = policy == .feasible ? self.catalogs : repairCatalogs
        let catalogUses = policy == .feasible ? self.catalogUses : repairCatalogUses
        let started = ProcessInfo.processInfo.systemUptime
        defer { metrics.catalogSeconds += ProcessInfo.processInfo.systemUptime - started }
        catalogUses[patch] = (catalogUses[patch] ?? 0) + 1
        if let cached = catalogs[patch], catalogUses[patch]! % 8 != 0 {
            metrics.catalogCacheHits += 1
            return cached
        }
        let previous = catalogs[patch] ?? []
        var result = Set<[Int]>()
        func add(_ cells: [Int]) {
            let cells = cells.sorted()
            guard !cells.isEmpty && !result.contains(cells) else { return }
            if permits(cells, policy: policy) { result.insert(cells) }
        }
        for cell in patch { add([cell]) }
        add(patch)
        let allowed = CellMask(count: grid.count, cells: patch)
        for shape in initialShapes.sorted(by: { $0.lexicographicallyPrecedes($1) }) where shape.allSatisfy({ allowed.contains($0) }) {
            if expired(until) { break }
            add(shape)
        }
        // Reserve work for connected growth before generic orbit masks. Both
        // generators retain their cursors across cache augmentations.
        let growthBudget = min(config.catalogMasksPerTransform, config.catalogCandidateLimit / 3)
        for cells in growCapitolShapes(patch: patch, until: until, budget: growthBudget, policy: policy) { add(cells) }
        for cells in sampleRegionShapes(patch: patch, until: until,
                                        budget: config.catalogCandidateLimit - growthBudget, policy: policy) { add(cells) }
        let catalog = refreshedCatalog(previous: previous, incoming: Array(result))
        // Reuse partial catalogs, augmenting them every eighth request. This
        // avoids both repeated generation costs and permanent time-cutoff bias.
        catalogs[patch] = catalog
        retainLargeShapes(catalog, until: until)
        return catalog
    }

    /// Exact cover of the selected cells, with the rest of the board fixed.
    /// Exactness refers to each returned cover, not exhaustive enumeration under
    /// these work limits. Clue costs are evaluated on the entire resulting board.
    func cover(patch: [Int], base: [Int], candidates: [[Int]], until: Double,
               firstOnly: Bool = false, strictFeasibility: Bool = false) -> SearchState? {
        let started = ProcessInfo.processInfo.systemUptime
        defer { metrics.coverSeconds += ProcessInfo.processInfo.systemUptime - started }
        guard !patch.isEmpty && !expired(until) else { return nil }
        let allowed = CellMask(count: grid.count, cells: patch)
        let candidates = shuffled(Array(Set(candidates.map { $0.sorted() })).sorted { $0.lexicographicallyPrecedes($1) }.filter {
            !$0.isEmpty && $0.allSatisfy { allowed.contains($0) }
                && permits($0, policy: strictFeasibility ? .feasible : .repair)
        })
        let masks = candidates.map { CellMask(count: grid.count, cells: $0) }
        let capitals = candidates.map { regions.geometry($0).capitol }
        var byCell = Array(repeating: [Int](), count: grid.count)
        for (i, cells) in candidates.enumerated() { for cell in cells { byCell[cell].append(i) } }
        var occupied = CellMask(count: grid.count, cells: base.indices.filter { !allowed.contains($0) })
        var sizes = Array(repeating: 0, count: grid.count)
        var fixedCapitols = CellMask(count: grid.count)
        for cells in groups(base) where cells.allSatisfy({ !allowed.contains($0) }) {
            for cell in cells { sizes[cell] = cells.count }
            if let cap = regions.geometry(cells).capitol { fixedCapitols.insert(cap) }
        }
        let canBeSingleton = byCell.map { $0.contains { candidates[$0].count == 1 } }
        let relevantOnes = strictFeasibility ? constraints.clues.indices.filter {
            constraints.clues[$0] == 1 && (allowed.contains($0) || grid.neighbors($0).contains { allowed.contains($0) })
        } : []
        var labels = base
        let nextLabel = (base.max() ?? -1) + 1
        var nodes = 0, solutions = 0
        var best: SearchState?
        var pending: [[Int]] = []
        func flush() {
            for state in evaluateBatch(labels: pending) {
                if state.validation.valid { best = state; break }
                if best == nil || prefers(state, over: best!) { best = state }
            }
            pending.removeAll(keepingCapacity: true)
        }
        // Final-board feasibility is different from improving a partial board.
        // A fixed exterior may need a later repair; do not reject every local
        // improvement merely because a pair bound is still violated there.
        let relevantBounds = strictFeasibility ? constraints.pairBounds.filter {
            allowed.contains($0.first) || allowed.contains($0.second)
        } : []
        func onesPossible() -> Bool {
            guard relevantOnes.allSatisfy({ cell in
                grid.neighbors(cell).contains { occupied.contains($0) ? sizes[$0] == 1 : canBeSingleton[$0] }
            }) else { return false }
            return relevantBounds.allSatisfy { bound in
                guard occupied.contains(bound.first) && occupied.contains(bound.second) else { return true }
                // Avoid overflow for large custom clues.
                return sizes[bound.first] >= bound.minimum - min(bound.minimum, sizes[bound.second])
            }
        }
        // Paths entirely through assigned states survive every completion of this
        // cover. Too-short routes give admissible lower bounds on clue error.
        func routesCanImprove() -> Bool {
            guard let best else { return true }
            var wrong = 0, error = 0.0, weightedError = 0.0
            var distance = Array(repeating: Int.max, count: grid.count)
            var visited = Array(repeating: false, count: grid.count)
            for cell in fixedCapitols.cells { distance[cell] = 0 }
            for _ in 0..<grid.count {
                var next: Int?
                for cell in distance.indices where !visited[cell] && distance[cell] != Int.max {
                    if next == nil || distance[cell] < distance[next!] { next = cell }
                }
                guard let cell = next else { break }
                if constraints.clues[cell] > distance[cell] {
                    wrong += 1
                    let e = 1 - Double(distance[cell]) / Double(constraints.clues[cell])
                    error += e; weightedError += clueWeights[cell] * e
                }
                visited[cell] = true
                for neighbor in grid.neighbors(cell) where occupied.contains(neighbor) {
                    let sum = distance[cell].addingReportingOverflow(min(sizes[cell], sizes[neighbor]))
                    if !sum.overflow && sum.partialValue < distance[neighbor] { distance[neighbor] = sum.partialValue }
                }
            }
            let count = Double(max(1, clueCount)), mean = error / count
            let bound: Double
            switch config.searchObjective {
            case .matches: bound = (Double(wrong) + 0.5 * mean) / Double(clueCount + 1)
            case .residual: bound = mean + 0.05 * Double(wrong) / count
            case .persistent:
                let weights = constraints.clues.indices.filter { constraints.clues[$0] >= 0 }.reduce(0.0) { $0 + clueWeights[$1] }
                bound = weightedError / max(1, weights) + 0.05 * Double(wrong) / count
            }
            return bound <= merit(best) + 1e-12
        }
        func visit(_ remaining: Int, _ depth: Int) {
            guard nodes < config.exactCoverNodeLimit && solutions < config.exactCoverSolutionLimit
                    && !expired(until) && !(firstOnly && best != nil) && best?.validation.valid != true else { return }
            nodes += 1
            guard onesPossible() else { return }
            // Upper bounds on distance imply lower bounds on mismatch/error.
            // Prune only against a completed incumbent, so an imperfect fixed
            // exterior does not prevent gradual repairs.
            if config.useRouteBounds && !firstOnly && grid.count > 25 && nodes % 32 == 0 && !routesCanImprove() {
                metrics.routePrunes += 1; return
            }
            if remaining == 0 {
                solutions += 1
                guard firstOnly || !samePartition(labels, base) else { return }
                pending.append(labels)
                if firstOnly || pending.count >= pathEvaluator.batchSize { flush() }
                return
            }
            var options: [Int]?
            for cell in patch where !occupied.contains(cell) {
                if expired(until) { return }
                var valid: [Int] = []
                for i in byCell[cell] where !masks[i].intersects(occupied) {
                    valid.append(i)
                    if let options, valid.count >= options.count { break }
                }
                if valid.isEmpty { return }
                if options == nil || valid.count < options!.count { options = valid }
                if valid.count == 1 { break }
            }
            for option in options ?? [] {
                if nodes >= config.exactCoverNodeLimit || solutions >= config.exactCoverSolutionLimit || expired(until) { break }
                let cells = candidates[option]
                occupied.formUnion(masks[option])
                if let cap = capitals[option] { fixedCapitols.insert(cap) }
                for cell in cells { sizes[cell] = cells.count; labels[cell] = nextLabel + depth }
                visit(remaining - cells.count, depth + 1)
                occupied.subtract(masks[option]); fixedCapitols.subtract(masks[option])
                for cell in cells { sizes[cell] = 0; labels[cell] = base[cell] }
                if expired(until) || best?.validation.valid == true || (firstOnly && best != nil) { break }
            }
        }
        visit(patch.count, 0)
        flush()
        metrics.coverNodes += nodes; metrics.coversChecked += solutions
        if nodes >= config.exactCoverNodeLimit || solutions >= config.exactCoverSolutionLimit || expired(until) {
            metrics.budgetStops += 1
        }
        return best
    }

    func samePartition(_ a: [Int], _ b: [Int]) -> Bool {
        func normalize(_ values: [Int]) -> [Int] {
            var ids: [Int: Int] = [:]
            return values.map { v in if ids[v] == nil { ids[v] = ids.count }; return ids[v]! }
        }
        return normalize(a) == normalize(b)
    }

    func patchCells(_ source: SearchState, large: Bool = false) -> [Int] {
        let limit = large ? config.largePatchCells : config.maxPatchCells
        let labels = source.labels, parts = groups(labels)
        var focus: [Int] = []
        // Repair along erroneous shortest routes, not just at the numbered cell.
        for mismatch in source.validation.mismatches {
            var cell = mismatch.cell.row * grid.cols + mismatch.cell.col
            var seen = Set<Int>()
            repeat {
                if !seen.insert(cell).inserted { break }
                focus.append(cell)
                focus.append(contentsOf: grid.neighbors(cell))
                guard cell < source.parents.count, let next = source.parents[cell] else { break }
                cell = next
            } while true
        }
        if focus.isEmpty || rng.unit() < config.uniformSelectionProbability { focus = Array(0..<grid.count) }
        let available = focus.filter { parts[labels[$0]].count <= limit }
        guard !available.isEmpty else { return [] }
        let seed: Int
        if ExperimentPolicy.enabled {
            seed = ExperimentPolicy.focus(source.board.Energy.flatMap { $0 }, available:available, rng:&rng)
        } else {
            seed = available[(repairTicket + rng.index(available.count)) % available.count]
        }
        repairTicket &+= 1
        var chosen: Set<Int> = [labels[seed]]
        var cells = parts[labels[seed]]
        let desired: Int
        if ExperimentPolicy.enabled {
            let h = ExperimentPolicy.hotness(source.board.Energy.flatMap { $0 },cell:seed)
            desired = ExperimentPolicy.breadth(h,maximum:large ? 8 : config.maxMergeRegions,rng:&rng)
        } else { desired = large ? 4 + rng.index(5) : 1 + rng.index(config.maxMergeRegions) }
        while chosen.count < desired {
            let frontier = Set(cells.flatMap { grid.neighbors($0) }.map { labels[$0] }).subtracting(chosen)
                .filter { cells.count + parts[$0].count <= limit }.sorted()
            guard !frontier.isEmpty else { break }
            let id = frontier[rng.index(frontier.count)]
            chosen.insert(id); cells.append(contentsOf: parts[id])
        }
        return cells.sorted()
    }

    func repairProposal(_ source: SearchState) -> (SearchState, MoveKind)? {
        proposalNumber += 1
        let now = ProcessInfo.processInfo.systemUptime
        let large = proposalNumber % config.largeRepairInterval == 0
        let until = min(deadline, now + config.repairTimeLimitSeconds)
        if large {
            // Every other large turn reserves its whole deadline for the general
            // patch lane. Archive turns reserve half for a fallback if needed.
            let archiveTurn = largeRepairTurn % 2 == 0
            largeRepairTurn &+= 1
            if archiveTurn, let state = largeShapeProposal(source,
                until: now + max(0, until - now) / 2) {
                return (state, .constrainedPatch)
            }
        }
        if !large, let merged = mergeRepair(source, until: min(until, now + config.repairTimeLimitSeconds / 3)) {
            return (merged, .regionMerge)
        }
        guard !expired(until) else { return nil }
        if !large && proposalNumber % 3 == 0, let moved = boundaryRepair(source,
            until: min(until, now + config.repairTimeLimitSeconds / 3)) { return (moved, .orbitTransfer) }
        let patch = patchCells(source, large: large)
        guard !patch.isEmpty else { return nil }
        let labels = source.labels, allowed = Set(patch)
        // Leave time for the cover search even when catalog generation is cut short.
        // Alternate clue-guided discovery with a geometry-only lane. Every
        // returned repair can retain imperfect existing states; clues still
        // determine exact scoring and independent success validation.
        let policy: ShapePolicy = proposalNumber % 2 == 0 ? .repair : .feasible
        var candidates = regionCatalog(patch: patch, until: min(until, ProcessInfo.processInfo.systemUptime
                                                              + config.repairTimeLimitSeconds / 3), policy: policy)
        candidates += groups(labels).filter { Set($0).isSubset(of: allowed) }
        candidates = Array(Set(candidates)).sorted { $0.lexicographicallyPrecedes($1) }
        guard let repaired = cover(patch: patch, base: labels, candidates: candidates, until: until) else { return nil }
        return (repaired, .constrainedPatch)
    }
}

extension SearchContext {
    /// Move complete symmetry orbits, or split a state along a straight cut.
    /// This operates on states of any size without enumerating an entire patch.
    func boundaryRepair(_ source: SearchState, until: Double) -> SearchState? {
        let started = ProcessInfo.processInfo.systemUptime
        defer { metrics.boundarySeconds += ProcessInfo.processInfo.systemUptime - started }
        let labels = source.labels, parts = groups(labels)
        var checked = 0
        var best: SearchState?
        var pending: [[Int]] = []
        func flush() {
            for state in evaluateBatch(labels: pending) {
                if state.validation.valid { best = state; break }
                if best == nil || prefers(state, over: best!) { best = state }
            }
            pending.removeAll(keepingCapacity: true)
        }
        func consider(_ donor: Int, _ moved: [Int], _ recipient: Int?) {
            guard checked < config.boundaryCandidateLimit && !expired(until),
                  !moved.isEmpty && moved.count < parts[donor].count else { return }
            checked += 1; metrics.boundaryChecks += 1
            let mask = CellMask(count: grid.count, cells: moved)
            let remaining = parts[donor].filter { !mask.contains($0) }
            let destination = (recipient.map { parts[$0] } ?? []) + moved
            guard permits(remaining, policy: .repair) && permits(destination, policy: .repair) else { return }
            var candidate = labels
            let newLabel = recipient ?? parts.count
            for cell in moved { candidate[cell] = newLabel }
            pending.append(candidate)
            if pending.count >= pathEvaluator.batchSize { flush() }
        }
        for donor in shuffled(Array(parts.indices)) {
            if checked >= config.boundaryCandidateLimit || expired(until) || best?.validation.valid == true { break }
            let cells = parts[donor]
            guard cells.count > 1 else { continue }
            let top = cells.map { $0 / grid.cols }.min()!, bottom = cells.map { $0 / grid.cols }.max()!
            let left = cells.map { $0 % grid.cols }.min()!, right = cells.map { $0 % grid.cols }.max()!
            let occupied = Set(cells)
            let symmetries = (0..<7).filter { transform in
                let mapped = cells.compactMap { RegionCache.map($0, transform: transform,
                    top: top, bottom: bottom, left: left, right: right, cols: grid.cols) }
                return mapped.count == cells.count && Set(mapped) == occupied
            }
            var tried = Set<[Int]>()
            let border = shuffled(cells.filter { cell in grid.neighbors(cell).contains { labels[$0] != donor } })
            for cell in border {
                if checked >= config.boundaryCandidateLimit || expired(until) || best?.validation.valid == true { break }
                let orbit = Array(Set([cell] + symmetries.compactMap {
                    RegionCache.map(cell, transform: $0, top: top, bottom: bottom,
                                    left: left, right: right, cols: grid.cols)
                })).sorted()
                for moved in [orbit, [cell]] where tried.insert(moved).inserted {
                    let neighbors = Set(moved.flatMap { grid.neighbors($0) }.map { labels[$0] }).subtracting([donor]).sorted()
                    for recipient in shuffled(neighbors) { consider(donor, moved, recipient) }
                    consider(donor, moved, nil)
                }
            }
            // A large wrong state must remain splittable even when a one-orbit
            // transfer cannot leave two connected symmetric shapes.
            var cuts: [[Int]] = []
            if top < bottom {
                for row in top..<bottom { cuts.append(cells.filter { $0 / grid.cols <= row }) }
            }
            if left < right {
                for col in left..<right { cuts.append(cells.filter { $0 % grid.cols <= col }) }
            }
            for cut in shuffled(cuts) {
                if checked >= config.boundaryCandidateLimit || expired(until) || best?.validation.valid == true { break }
                consider(donor, cut, nil)
            }
        }
        flush()
        return best
    }
}
