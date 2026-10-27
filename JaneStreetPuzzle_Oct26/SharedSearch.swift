import Foundation

struct EliteCandidate: Sendable {
    let snapshot: BoardSnapshot
    let scores: Energy.Scores
    let workerID: Int
    let boundaries: [UInt64]
    init(snapshot: BoardSnapshot, scores: Energy.Scores, workerID: Int) {
        self.snapshot = snapshot; self.scores = scores; self.workerID = workerID
        let edges = snapshot.verticalRelationships.flatMap { $0 } + snapshot.horizontalRelationships.flatMap { $0 }
        var bits = Array(repeating: UInt64(0), count: (edges.count + 63) / 64)
        for i in edges.indices where edges[i] == 1 { bits[i >> 6] |= UInt64(1) << (i & 63) }
        boundaries = bits
    }
    var quality: SearchQuality { SearchQuality(snapshot.validation, scores) }
}

struct EliteAssignment: Sendable {
    let candidate: EliteCandidate?
    let ticket: Int
}

/// The only shared search state. Mutable boards, caches and RNGs never leave a
/// worker. Each assignment has a different repair ticket to diversify patches.
actor EliteArchive {
    private let capacity: Int
    private var entries: [EliteCandidate] = []
    private var ticket = 0
    init(capacity: Int) { self.capacity = capacity }

    func publish(_ candidate: EliteCandidate) {
        if let index = entries.firstIndex(where: { $0.snapshot.labels == candidate.snapshot.labels }) {
            guard candidate.quality < entries[index].quality else { return }
            entries.remove(at: index)
        }
        entries.append(candidate)
        entries.sort {
            if $0.quality != $1.quality { return $0.quality < $1.quality }
            return $0.snapshot.labels.flatMap { $0 }.lexicographicallyPrecedes($1.snapshot.labels.flatMap { $0 })
        }
        if entries.count > capacity {
            // Retain the exact-match leader, the residual leader and topologically
            // diverse alternatives. Boundary distance ignores arbitrary label IDs.
            var selected = [entries.removeFirst()]
            if capacity > 1, let index = entries.indices.min(by: { entries[$0].scores.realAIM < entries[$1].scores.realAIM }) {
                selected.append(entries.remove(at: index))
            }
            while selected.count < capacity && !entries.isEmpty {
                let index = entries.indices.max { a, b in
                    let da = selected.map { Self.distance(entries[a], $0) }.min() ?? 0
                    let db = selected.map { Self.distance(entries[b], $0) }.min() ?? 0
                    return da == db ? a > b : da < db
                }!
                selected.append(entries.remove(at: index))
            }
            entries = selected.sorted { $0.quality < $1.quality }
        }
    }

    private static func distance(_ a: EliteCandidate, _ b: EliteCandidate) -> Int {
        zip(a.boundaries, b.boundaries).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    }

    func assignment(workerID: Int, objective: SearchObjective = .matches) -> EliteAssignment {
        ticket &+= 1
        if let solved = entries.first(where: { $0.snapshot.validation.valid }) {
            return EliteAssignment(candidate: solved, ticket: ticket)
        }
        // Every fourth worker remains an independent explorer. The others mix
        // the best board with other members of the small elite archive.
        guard workerID % 4 != 0, !entries.isEmpty else { return EliteAssignment(candidate: nil, ticket: ticket) }
        let leader = objective == .matches ? 0 : entries.indices.min {
            entries[$0].scores.realAIM < entries[$1].scores.realAIM
        }!
        let index = ticket % 2 == 0 ? ticket % entries.count : leader
        return EliteAssignment(candidate: entries[index], ticket: ticket)
    }
}

struct AdaptiveTemperature {
    private let config: RunConfig
    private var increases: [Double] = []
    private(set) var value: Double
    init(config: RunConfig) { self.config = config; value = config.initialTemperature }
    private var typicalIncrease: Double? {
        let values = increases.sorted()
        return values.isEmpty ? nil : values[values.count / 2]
    }
    var floor: Double {
        max(config.minimumTemperature, typicalIncrease.map { $0 / -log(0.02) } ?? config.minimumTemperature)
    }
    mutating func step(delta: Double?) {
        if let delta, delta.isFinite && delta > 0 {
            increases.append(delta)
            if increases.count > 64 { increases.removeFirst() }
        }
        value = max(floor, value * config.coolingRate)
    }
    mutating func reheat() {
        value = max(config.initialTemperature, typicalIncrease.map { $0 / -log(0.3) } ?? config.initialTemperature)
    }
}
