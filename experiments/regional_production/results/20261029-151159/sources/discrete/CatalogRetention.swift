import Foundation

extension SearchContext {
    /// Retain an irredundant coverage backbone, admit fresh candidates, then keep
    /// a diverse bounded remainder. Saturation must not freeze future discovery.
    /// Coverage is the union of represented cells, not a guarantee of a tiling.
    func refreshedCatalog(previous: [[Int]], incoming: [[Int]]) -> [[Int]] {
        let limit = config.catalogCandidateLimit
        let old = Set(previous)
        let all = old.union(incoming)
        if all.count <= limit { return all.sorted { $0.lexicographicallyPrecedes($1) } }
        var counts = Array(repeating: 0, count: grid.count)
        for shape in previous { for cell in shape { counts[cell] += 1 } }
        var kept: [[Int]] = []
        for shape in shuffled(previous) {
            if shape.allSatisfy({ counts[$0] > 1 }) {
                for cell in shape { counts[cell] -= 1 }
            } else { kept.append(shape) }
        }
        // Configuration can lower a catalog's capacity between jobs. Retaining
        // every previously covered cell may then be impossible; prefer broader
        // coverage within the explicitly requested smaller limit.
        if kept.count > limit {
            kept.sort { $0.count > $1.count }
            kept = Array(kept.prefix(limit))
            counts = Array(repeating: 0, count: grid.count)
            for shape in kept { for cell in shape { counts[cell] += 1 } }
        }
        let fresh = shuffled(Set(incoming).subtracting(old).sorted { $0.lexicographicallyPrecedes($1) })
        var selected = Set(kept)
        var admitted = 0
        let quota = max(1, limit / 4)
        // Cover newly represented cells first. This loop admits at most one
        // shape per previously uncovered cell, rather than ranking the entire
        // retained catalog repeatedly.
        while kept.count < limit {
            var best: [Int]?, gain = 0
            for shape in fresh where !selected.contains(shape) {
                let added = shape.filter { counts[$0] == 0 }.count
                if added > gain { best = shape; gain = added }
            }
            guard let shape = best else { break }
            kept.append(shape); selected.insert(shape); admitted += 1
            for cell in shape { counts[cell] += 1 }
        }
        for shape in fresh where !selected.contains(shape) {
            if admitted >= quota { break }
            if kept.count < limit {
                kept.append(shape); selected.insert(shape); admitted += 1
                for cell in shape { counts[cell] += 1 }
            } else if admitted == 0 {
                // Even a tiny full catalog can replace a shape if the incoming
                // shape covers all cells uniquely represented by that victim.
                let cells = Set(shape)
                if let victim = kept.indices.first(where: { i in
                    kept[i].allSatisfy { counts[$0] > 1 || cells.contains($0) }
                }) {
                    let removed = kept[victim]
                    for cell in removed { counts[cell] -= 1 }
                    selected.remove(removed); kept[victim] = shape; selected.insert(shape)
                    for cell in shape { counts[cell] += 1 }
                    admitted += 1
                }
            }
            if admitted >= quota { break }
        }
        // Most of the remaining capacity retains old candidates; fresh entries
        // receive reserved slots even when the previous catalog was full.
        for shape in shuffled(previous) where kept.count < limit && !selected.contains(shape) {
            kept.append(shape); selected.insert(shape)
        }
        for shape in fresh where kept.count < limit && !selected.contains(shape) {
            kept.append(shape); selected.insert(shape)
        }
        return kept.sorted { $0.lexicographicallyPrecedes($1) }
    }
}
