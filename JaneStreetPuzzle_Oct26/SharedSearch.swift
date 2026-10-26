import Foundation

struct EliteCandidate: Sendable {
    let snapshot: BoardSnapshot
    let scores: Energy.Scores
    let workerID: Int
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
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    func assignment(workerID: Int) -> EliteAssignment {
        ticket &+= 1
        if let solved = entries.first(where: { $0.snapshot.validation.valid }) {
            return EliteAssignment(candidate: solved, ticket: ticket)
        }
        // Every fourth worker remains an independent explorer. The others mix
        // the best board with other members of the small elite archive.
        guard workerID % 4 != 0, !entries.isEmpty else { return EliteAssignment(candidate: nil, ticket: ticket) }
        let index = ticket % 4 == 0 ? ticket % entries.count : 0
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
