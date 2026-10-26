import Foundation

struct RepairMetrics: Codable, Sendable {
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
    func mergeRepair(_ source: SearchState, until: Double) -> SearchState? {
        let labels = canonical(source.board)
        let cursor: MergeCursor
        if let cached = mergeCursors[labels] {
            cursor = cached
            metrics.mergeCacheHits += 1
        } else {
            if mergeCursors.count >= 32 { mergeCursors.removeAll(keepingCapacity: true) }
            cursor = MergeCursor(labels: labels, context: self)
            mergeCursors[labels] = cursor
        }
        var best: SearchState?
        var checked = 0
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
            guard constraints.permits(cells, geometry: regions.geometry(cells)) else { continue }
            var merged = labels
            for cell in cells { merged[cell] = cluster[0] }
            let sizes = Dictionary(grouping: merged, by: { $0 }).mapValues(\.count)
            let affected = Set(cells + cells.flatMap { grid.neighbors($0) })
            guard affected.filter({ constraints.clues[$0] == 1 }).allSatisfy({ cell in
                grid.neighbors(cell).contains { sizes[merged[$0]] == 1 }
            }) else { continue }
            let candidate = evaluate(board(labels: merged))
            if candidate.quality < (best ?? source).quality { best = candidate }
            if candidate.validation.valid { return candidate }
        }
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
            if constraints.permits(cells, geometry: regions.geometry(cells)) { result.insert(cells) }
        }
        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                if expired(until) { return result.sorted { $0.lexicographicallyPrecedes($1) } }
                for height in 1...min(4, grid.rows - row) {
                    for width in 1...min(4, grid.cols - col) where height * width <= 12 {
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
        let catalog = initialCatalog(until: until)
        if let state = cover(patch: labels, base: labels, candidates: catalog, until: until, firstOnly: true) {
            return state
        }
        // Always return a structurally legal board even if constraints are
        // contradictory or the bounded initial cover search ran out of time.
        return evaluate(board(labels: labels))
    }

    /// Generate symmetric candidates as unions of transformation orbits.
    /// Work and memory are bounded; a truncated catalog is explicitly heuristic.
    func regionCatalog(patch: [Int], until: Double) -> [[Int]] {
        let patch = patch.sorted()
        catalogUses[patch, default: 0] += 1
        if let cached = catalogs[patch], catalogUses[patch]! % 8 != 0 {
            metrics.catalogCacheHits += 1
            return cached
        }
        var result = Set(catalogs[patch] ?? [])
        func add(_ cells: [Int]) {
            let cells = cells.sorted()
            guard !cells.isEmpty && result.count < config.catalogCandidateLimit && !result.contains(cells) else { return }
            if constraints.permits(cells, geometry: regions.geometry(cells)) { result.insert(cells) }
        }
        for cell in patch { add([cell]) }
        add(patch)
        let index = Dictionary(uniqueKeysWithValues: patch.enumerated().map { ($0.element, $0.offset) })
        let rows = Array(Set(patch.map { $0 / grid.cols })).sorted()
        let cols = Array(Set(patch.map { $0 % grid.cols })).sorted()
        var boxes: [(Int, Int, Int, Int)] = []
        for top in rows {
            for bottom in rows where bottom >= top {
                for left in cols {
                    for right in cols where right >= left { boxes.append((top, bottom, left, right)) }
                }
            }
        }
        // Large bounding boxes first permit nonrectangular states spanning a
        // whole patch, rather than generating only small shapes near one corner.
        boxes = shuffled(boxes).sorted {
            ($0.1 - $0.0 + 1) * ($0.3 - $0.2 + 1) > ($1.1 - $1.0 + 1) * ($1.3 - $1.2 + 1)
        }
        var tested = 0
        outer: for (top, bottom, left, right) in boxes {
            for transform in shuffled(Array(0..<7)) {
                if expired(until) || tested >= config.catalogCandidateLimit { break outer }
                var seen = Set<Int>(), orbits: [UInt64] = []
                for cell in patch where !seen.contains(cell) && (top...bottom).contains(cell / grid.cols)
                    && (left...right).contains(cell % grid.cols) {
                    var orbit: [Int] = [], current = cell, valid = true
                    repeat {
                        guard index[current] != nil else { valid = false; break }
                        orbit.append(current)
                        seen.insert(current)
                        guard let next = RegionCache.map(current, transform: transform, top: top, bottom: bottom,
                                                         left: left, right: right, cols: grid.cols) else {
                            valid = false; break
                        }
                        current = next
                    } while current != cell && orbit.count < 4
                    if valid && current == cell {
                        orbits.append(orbit.reduce(UInt64(0)) { $0 | (UInt64(1) << index[$1]!) })
                    }
                }
                guard !orbits.isEmpty else { continue }
                orbits = shuffled(orbits)
                let combinations = UInt64(1) << orbits.count
                let limit = Int(min(combinations, UInt64(config.catalogMasksPerTransform)))
                for attempt in 0..<limit {
                    if tested >= config.catalogCandidateLimit || (attempt % 16 == 0 && expired(until)) { break outer }
                    tested += 1
                    // Exhaust small orbit spaces. For larger ones mix small,
                    // large and random unions instead of truncating by shape size.
                    let choice: UInt64
                    if combinations <= UInt64(limit) { choice = UInt64(attempt) }
                    else if attempt < limit / 2 {
                        choice = attempt % 2 == 0 ? UInt64(attempt / 2) : (combinations - 1) ^ UInt64(attempt / 2)
                    } else { choice = rng.next() & (combinations - 1) }
                    var mask: UInt64 = 0
                    for bit in orbits.indices where choice & (UInt64(1) << bit) != 0 { mask |= orbits[bit] }
                    if mask != 0 { add(patch.indices.filter { mask & (UInt64(1) << $0) != 0 }.map { patch[$0] }) }
                }
            }
        }
        metrics.catalogMasks += tested
        if tested >= config.catalogCandidateLimit || expired(until) { metrics.budgetStops += 1 }
        let catalog = result.sorted { $0.lexicographicallyPrecedes($1) }
        if catalogs.count >= 16 && catalogs[patch] == nil {
            catalogs.removeAll(keepingCapacity: true)
            catalogUses.removeAll(keepingCapacity: true)
        }
        // Reuse partial catalogs, augmenting them every eighth request. This
        // avoids both repeated generation costs and permanent time-cutoff bias.
        catalogs[patch] = catalog
        return catalog
    }

    /// Exact cover of the selected cells, with the rest of the board fixed.
    /// Exactness refers to each returned cover, not exhaustive enumeration under
    /// these work limits. Clue costs are evaluated on the entire resulting board.
    func cover(patch: [Int], base: [Int], candidates: [[Int]], until: Double,
               firstOnly: Bool = false) -> SearchState? {
        guard !patch.isEmpty else { return nil }
        let allowed = Set(patch)
        let candidates = shuffled(candidates.filter {
            !$0.isEmpty && Set($0).isSubset(of: allowed) && constraints.permits($0, geometry: regions.geometry($0))
        })
        var byCell = Array(repeating: [Int](), count: grid.count)
        for (i, cells) in candidates.enumerated() { for cell in cells { byCell[cell].append(i) } }
        var assigned = base.indices.map { !allowed.contains($0) }
        var singleton = Array(repeating: false, count: grid.count)
        for cells in groups(base) where cells.count == 1 && !allowed.contains(cells[0]) { singleton[cells[0]] = true }
        let canBeSingleton = byCell.map { $0.contains { candidates[$0].count == 1 } }
        let relevantOnes = constraints.clues.indices.filter {
            constraints.clues[$0] == 1 && (allowed.contains($0) || grid.neighbors($0).contains { allowed.contains($0) })
        }
        var labels = base
        let nextLabel = (base.max() ?? -1) + 1
        var nodes = 0, solutions = 0
        var best: SearchState?
        func onesPossible() -> Bool {
            relevantOnes.allSatisfy { cell in
                grid.neighbors(cell).contains { assigned[$0] ? singleton[$0] : canBeSingleton[$0] }
            }
        }
        func visit(_ remaining: Int, _ depth: Int) {
            guard nodes < config.exactCoverNodeLimit && solutions < config.exactCoverSolutionLimit
                    && !expired(until) && !(firstOnly && best != nil) && best?.validation.valid != true else { return }
            nodes += 1
            guard onesPossible() else { return }
            if remaining == 0 {
                solutions += 1
                guard firstOnly || !samePartition(labels, base) else { return }
                let state = evaluate(board(labels: labels))
                if best == nil || state.quality < best!.quality { best = state }
                return
            }
            var options: [Int]?
            for cell in patch where !assigned[cell] {
                if expired(until) { return }
                let valid = byCell[cell].filter { candidates[$0].allSatisfy { !assigned[$0] } }
                if valid.isEmpty { return }
                if options == nil || valid.count < options!.count { options = valid }
                if valid.count == 1 { break }
            }
            for option in options ?? [] {
                let cells = candidates[option]
                for cell in cells { assigned[cell] = true; singleton[cell] = cells.count == 1; labels[cell] = nextLabel + depth }
                visit(remaining - cells.count, depth + 1)
                for cell in cells { assigned[cell] = false; singleton[cell] = false; labels[cell] = base[cell] }
                if expired(until) || best?.validation.valid == true || (firstOnly && best != nil) { break }
            }
        }
        visit(patch.count, 0)
        metrics.coverNodes += nodes
        metrics.coversChecked += solutions
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

    func patchCells(_ source: SearchState) -> [Int] {
        let labels = canonical(source.board), parts = groups(labels)
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
        let available = focus.filter { parts[labels[$0]].count <= config.maxPatchCells }
        guard !available.isEmpty else { return [] }
        let seed = available[(repairTicket + rng.index(available.count)) % available.count]
        repairTicket &+= 1
        var chosen: Set<Int> = [labels[seed]]
        var cells = parts[labels[seed]]
        let desired = 1 + rng.index(config.maxMergeRegions)
        while chosen.count < desired {
            let frontier = Set(cells.flatMap { grid.neighbors($0) }.map { labels[$0] }).subtracting(chosen)
                .filter { cells.count + parts[$0].count <= config.maxPatchCells }.sorted()
            guard !frontier.isEmpty else { break }
            let id = frontier[rng.index(frontier.count)]
            chosen.insert(id); cells.append(contentsOf: parts[id])
        }
        return cells.sorted()
    }

    func repairProposal(_ source: SearchState) -> (SearchState, MoveKind)? {
        let now = ProcessInfo.processInfo.systemUptime
        let until = min(deadline, now + config.repairTimeLimitSeconds)
        if let merged = mergeRepair(source, until: min(until, now + config.repairTimeLimitSeconds / 3)) {
            return (merged, .regionMerge)
        }
        guard !expired(until) else { return nil }
        let patch = patchCells(source)
        guard !patch.isEmpty else { return nil }
        let labels = canonical(source.board), allowed = Set(patch)
        // Leave time for the cover search even when catalog generation is cut short.
        var candidates = regionCatalog(patch: patch, until: min(until, ProcessInfo.processInfo.systemUptime
                                                              + config.repairTimeLimitSeconds / 3))
        candidates += groups(labels).filter { Set($0).isSubset(of: allowed) }
        candidates = Array(Set(candidates)).sorted { $0.lexicographicallyPrecedes($1) }
        guard let repaired = cover(patch: patch, base: labels, candidates: candidates, until: until) else { return nil }
        return (repaired, .constrainedPatch)
    }
}
