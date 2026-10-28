import Foundation

/// A walk persists even when a short repair deadline cuts it off. Intermediate
/// shapes may have extra symmetries (and no capitol); only emitted shapes must
/// pass the complete geometry and clue checks.
final class CapitolGrowthCursor {
    let jobs: [(Int, Int)]
    let allowed: Set<Int>
    var next = 0
    var grown = Set<Int>()
    var space: [Int: [Int]] = [:]
    var steps = 0

    init(patch: [Int], context: SearchContext) {
        allowed = Set(patch)
        let forced = patch.filter { context.constraints.clues[$0] == 0 || context.constraints.forcedSingletons.contains($0) }
        let other = patch.filter { context.constraints.clues[$0] < 0 && !forced.contains($0) }
        let anchors = context.shuffled(forced) + context.shuffled(other)
        jobs = anchors.flatMap { cap in context.shuffled(Array(0..<7)).map { (cap, $0) } }
    }
}

/// Bounding-box and transform cursors do not restart when the caller requests
/// more samples. Only the currently sampled transform's orbit graph is retained.
final class RegionSamplingCursor {
    let patch: [Int]
    let allowed: Set<Int>
    let rowIntervals: [(Int, Int)]
    let colIntervals: [(Int, Int)]
    let boxes: [Int]
    var box = 0
    var transform = 0
    var transforms: [Int] = []
    var attempt = 0
    var totalSamples = 0
    var orbits: [[Int]]?
    var adjacent: [Set<Int>] = []

    init(patch: [Int], context: SearchContext) {
        self.patch = patch
        allowed = Set(patch)
        let rows = Array(Set(patch.map { $0 / context.grid.cols })).sorted()
        let cols = Array(Set(patch.map { $0 % context.grid.cols })).sorted()
        var rowIntervals: [(Int, Int)] = [], colIntervals: [(Int, Int)] = []
        for top in rows {
            for bottom in rows where bottom >= top { rowIntervals.append((top, bottom)) }
        }
        for left in cols {
            for right in cols where right >= left { colIntervals.append((left, right)) }
        }
        self.rowIntervals = rowIntervals; self.colIntervals = colIntervals
        // Shuffle within equal areas. The saved cursor subsequently visits the
        // smaller boxes too, rather than repeatedly starting at the largest.
        func area(_ index: Int) -> Int {
            let r = rowIntervals[index / colIntervals.count], c = colIntervals[index % colIntervals.count]
            return (r.1-r.0+1)*(c.1-c.0+1)
        }
        self.boxes = context.shuffled(Array(0..<(rowIntervals.count * colIntervals.count))).sorted { area($0) > area($1) }
    }

    var currentBox: (Int, Int, Int, Int) {
        let index = boxes[box]
        let r = rowIntervals[index / colIntervals.count], c = colIntervals[index % colIntervals.count]
        return (r.0, r.1, c.0, c.1)
    }

    func advance() {
        attempt = 0; orbits = nil; adjacent = []
        transform += 1
        if transform >= transforms.count { transform = 0; transforms = []; box += 1 }
        if box >= boxes.count { box = 0 }
    }
}

extension SearchContext {
    /// Compute a safe superset of all states grown about this anchor. Cells
    /// outside its connected symmetry component, or requiring more area than
    /// that component can provide, cannot participate in any completed state.
    func capitolOrbitSpace(cap: Int, transform: Int, patch: Set<Int>) -> [Int: [Int]] {
        let r = cap / grid.cols, c = cap % grid.cols
        func mapped(_ cell: Int) -> Int? {
            let dr = cell / grid.cols - r, dc = cell % grid.cols - c
            let q: (Int, Int)
            switch transform {
            case 0: q = (dc, -dr)
            case 1: q = (-dr, -dc)
            case 2: q = (-dc, dr)
            case 3: q = (dr, -dc)
            case 4: q = (-dr, dc)
            case 5: q = (dc, dr)
            default: q = (-dc, -dr)
            }
            let row = r + q.0, col = c + q.1
            guard row >= 0 && row < grid.rows && col >= 0 && col < grid.cols else { return nil }
            return row * grid.cols + col
        }
        var orbits: [[Int]] = [], seen = Set<Int>()
        for seed in patch.sorted() where !seen.contains(seed) {
            var orbit = Set<Int>(), current = seed, valid = true
            repeat {
                guard patch.contains(current), let next = mapped(current) else { valid = false; break }
                if current != cap && (constraints.forcedSingletons.contains(current)
                    || constraints.clues[current] == 0 || current == next) { valid = false; break }
                if constraints.forcedSingletons.contains(cap) && current != cap { valid = false; break }
                orbit.insert(current); seen.insert(current); current = next
            } while current != seed && orbit.count < 4
            if valid && current == seed { orbits.append(orbit.sorted()) }
        }
        var allowed = Set(orbits.flatMap { $0 })
        while allowed.contains(cap) {
            var reached: Set<Int> = [cap], queue = [cap], next = 0
            while next < queue.count {
                let cell = queue[next]; next += 1
                for neighbor in grid.neighbors(cell) where allowed.contains(neighbor) {
                    if reached.insert(neighbor).inserted { queue.append(neighbor) }
                }
            }
            let viable = orbits.filter { orbit in
                orbit.allSatisfy { reached.contains($0) && constraints.minimumSizes[$0] <= reached.count }
            }
            let reduced = Set(viable.flatMap { $0 })
            orbits = viable
            if reduced == allowed { break }
            allowed = reduced
        }
        guard allowed.contains(cap) else { return [:] }
        var result: [Int: [Int]] = [:]
        for orbit in orbits { for cell in orbit { result[cell] = orbit } }
        return result
    }

    /// Connected orbit growth includes unnumbered capitols, with forced anchors
    /// first. Neither a capitol position nor a state size is taken from a solution.
    func growCapitolShapes(patch: [Int], until: Double, budget: Int) -> [[Int]] {
        guard budget > 0, !patch.isEmpty, !expired(until) else { return [] }
        let patch = patch.sorted()
        let cursor: CapitolGrowthCursor
        if let cached = capitolGrowth[patch] { cursor = cached }
        else { cursor = CapitolGrowthCursor(patch: patch, context: self); capitolGrowth[patch] = cursor }
        guard !cursor.jobs.isEmpty else { return [] }
        var result = Set<[Int]>()
        for _ in 0..<budget {
            if expired(until) { break }
            let (cap, transform) = cursor.jobs[cursor.next % cursor.jobs.count]
            if cursor.grown.isEmpty {
                cursor.grown = [cap]
                cursor.space = capitolOrbitSpace(cap: cap, transform: transform, patch: cursor.allowed)
                visitedCapitolAnchors.insert(cap)
            }
            growthSteps += 1; cursor.steps += 1
            let cells = cursor.grown.sorted()
            // Failure here must not prune the walk: a later orbit can remove an
            // unwanted mirror or satisfy a minimum-area constraint.
            if permits(cells) { result.insert(cells) }
            let frontier = Set(cells.flatMap { grid.neighbors($0) }).subtracting(cursor.grown)
            var choices: [[Int]] = []
            var seen = Set<Int>()
            for seed in frontier.sorted() where !seen.contains(seed) {
                guard let orbit = cursor.space[seed] else { continue }
                seen.formUnion(orbit); choices.append(orbit)
            }
            if choices.isEmpty || constraints.forcedSingletons.contains(cap) {
                cursor.grown = []; cursor.next = (cursor.next + 1) % cursor.jobs.count
            } else {
                // Prefer cells with larger proven area requirements on alternating
                // steps, retaining random branches for varied shapes.
                let choice: [Int]
                if cursor.steps % 2 == 0 {
                    let needed = choices.map { $0.map { constraints.minimumSizes[$0] }.max() ?? 1 }
                    let best = needed.max()!
                    let eligible = choices.indices.filter { needed[$0] == best }
                    choice = choices[eligible[rng.index(eligible.count)]]
                } else { choice = choices[rng.index(choices.count)] }
                cursor.grown.formUnion(choice)
            }
        }
        return result.sorted { $0.lexicographicallyPrecedes($1) }
    }

    func prepareOrbits(_ cursor: RegionSamplingCursor) {
        let (top, bottom, left, right) = cursor.currentBox
        if cursor.transforms.isEmpty { cursor.transforms = shuffled(Array(0..<7)) }
        let transform = cursor.transforms[cursor.transform]
        var seen = Set<Int>(), orbits: [[Int]] = []
        for cell in cursor.patch where !seen.contains(cell) && (top...bottom).contains(cell / grid.cols)
            && (left...right).contains(cell % grid.cols) {
            var orbit = Set<Int>(), current = cell, valid = true
            repeat {
                guard cursor.allowed.contains(current),
                      !constraints.forcedSingletons.contains(current),
                      let next = RegionCache.map(current, transform: transform, top: top, bottom: bottom,
                                                 left: left, right: right, cols: grid.cols) else { valid = false; break }
                // A printed zero cannot move under a state's symmetry.
                if constraints.clues[current] == 0 && current != next { valid = false; break }
                seen.insert(current); orbit.insert(current); current = next
            } while current != cell && orbit.count < 4
            if valid && current == cell { orbits.append(orbit.sorted()) }
        }
        cursor.orbits = shuffled(orbits)
        var owner: [Int: Int] = [:]
        for (i, orbit) in cursor.orbits!.enumerated() { for cell in orbit { owner[cell] = i } }
        cursor.adjacent = cursor.orbits!.enumerated().map { i, orbit in
            Set(orbit.flatMap { grid.neighbors($0) }.compactMap { owner[$0] }).subtracting([i])
        }
    }

    func sampleRegionShapes(patch: [Int], until: Double, budget: Int) -> [[Int]] {
        guard budget > 0, !patch.isEmpty, !expired(until) else { return [] }
        let cursor: RegionSamplingCursor
        if let cached = regionSampling[patch] { cursor = cached }
        else { cursor = RegionSamplingCursor(patch: patch, context: self); regionSampling[patch] = cursor }
        guard !cursor.boxes.isEmpty else { return [] }
        var result = Set<[Int]>(), tested = 0, emptyJobs = 0
        while tested < budget && !expired(until) {
            if cursor.orbits == nil { prepareOrbits(cursor) }
            let orbits = cursor.orbits!
            if orbits.isEmpty {
                cursor.advance(); emptyJobs += 1
                if emptyJobs >= cursor.boxes.count * 7 { break }
                continue
            }
            emptyJobs = 0
            let exhaustive = orbits.count < 20 && (1 << orbits.count) <= config.catalogMasksPerTransform
            let limit = exhaustive ? (1 << orbits.count) : config.catalogMasksPerTransform
            if cursor.attempt >= limit { cursor.advance(); continue }
            let attempt = cursor.attempt
            cursor.attempt += 1; cursor.totalSamples += 1; tested += 1
            var chosen = Set<Int>()
            if exhaustive {
                chosen = Set(orbits.indices.filter { attempt & (1 << $0) != 0 })
            } else if attempt < limit / 2 {
                let single = (attempt / 2) % orbits.count
                chosen = attempt % 2 == 0 ? [single] : Set(orbits.indices).subtracting([single])
            } else if attempt < limit / 2 + limit / 4 {
                let seed = rng.index(orbits.count)
                chosen = [seed]
                var area = orbits[seed].count
                let minimum = orbits[seed].map { constraints.minimumSizes[$0] }.max() ?? 1
                let target = max(minimum, 1 + rng.index(patch.count))
                var frontier = cursor.adjacent[seed]
                while area < target && !frontier.isEmpty && !expired(until) {
                    let options = frontier.sorted(), next = options[rng.index(options.count)]
                    chosen.insert(next); area += orbits[next].count
                    frontier.formUnion(cursor.adjacent[next]); frontier.subtract(chosen)
                }
            } else {
                // Keep a random lane: some legal capless states have no connected
                // single-orbit seed, and disconnected prefixes must remain possible.
                chosen = Set(orbits.indices.filter { _ in rng.next() & 1 != 0 })
            }
            let cells = chosen.sorted().flatMap { orbits[$0] }.sorted()
            if !cells.isEmpty && permits(cells) { result.insert(cells) }
            if result.count >= config.catalogCandidateLimit { break }
        }
        metrics.catalogMasks += tested
        if tested >= budget || expired(until) { metrics.budgetStops += 1 }
        return result.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// Rebuild all current states intersected by a proposed large shape. Fix the
    /// proposed shape while covering the remainder, so a cheap old cover cannot
    /// silently omit the shape this lane was meant to explore.
    func rebuildLargeShape(_ shape: [Int], source: SearchState, until: Double) -> SearchState? {
        guard !expired(until), shape.count > config.maxPatchCells,
              shape.count <= config.largePatchCells, permits(shape) else { return nil }
        let parts = groups(source.labels), touched = Set(shape.map { source.labels[$0] })
        let patch = touched.sorted().flatMap { parts[$0] }.sorted()
        guard patch.count <= config.largePatchCells, !parts.contains(shape) else { return nil }
        largeShapeAttempts += 1
        let occupied = Set(shape), rest = patch.filter { !occupied.contains($0) }
        var base = source.labels
        let id = (base.max() ?? -1) + 1
        for cell in shape { base[cell] = id }
        if rest.isEmpty { return evaluate(labels: base) }
        let allowed = Set(rest)
        let now = ProcessInfo.processInfo.systemUptime
        let catalogUntil = min(until, now + max(0, until - now) / 2)
        var candidates = regionCatalog(patch: rest, until: catalogUntil)
        // Existing parts are useful when intact; cheap palette shapes can fill
        // fragments around the large state before their local catalog warms up.
        candidates += parts.filter { $0.allSatisfy { allowed.contains($0) } }
        candidates += initialShapes.filter { $0.allSatisfy { allowed.contains($0) } }
        return cover(patch: rest, base: base, candidates: candidates, until: until)
    }

    /// Both generators and ordinary patch catalogs feed this bounded archive.
    /// Generic candidates include even-area and capless states.
    func retainLargeShapes(_ shapes: [[Int]], until: Double = .infinity) {
        for shape in shapes where shape.count > config.maxPatchCells && shape.count <= config.largePatchCells {
            if expired(until) { break }
            let shape = shape.sorted()
            if !largeShapes.contains(shape), permits(shape) {
                largeShapes.append(shape)
                if largeShapes.count > min(512, config.catalogCandidateLimit) { largeShapes.removeFirst() }
            }
        }
    }

    func largeShapeProposal(_ source: SearchState, until: Double) -> SearchState? {
        guard grid.count > config.maxPatchCells, !expired(until) else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let growthUntil = min(until, now + max(0, until - now) / 3)
        let patch = Array(0..<grid.count)
        let growthBudget = config.catalogMasksPerTransform / 2
        retainLargeShapes(growCapitolShapes(patch: patch, until: growthUntil, budget: growthBudget), until: until)
        let sampleUntil = min(until, now + max(0, until - now) * (2.0 / 3))
        retainLargeShapes(sampleRegionShapes(patch: patch, until: sampleUntil,
                                            budget: config.catalogMasksPerTransform-growthBudget), until: until)
        guard !largeShapes.isEmpty, !expired(until) else { return nil }
        // Incompatible patches must not monopolize the lane. Each call advances
        // the cursor even if a candidate cannot fit the current partition.
        for _ in 0..<min(4, largeShapes.count) {
            let shape = largeShapes[largeShapeTicket % largeShapes.count]
            largeShapeTicket &+= 1
            if let proposal = rebuildLargeShape(shape, source: source, until: until) { return proposal }
            if expired(until) { break }
        }
        return nil
    }
}
