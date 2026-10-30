import Foundation
// Geometry and deterministic maker reused from discrete_vs_continuous/Experiment.swift.
struct SearchRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }
    mutating func index(_ count: Int) -> Int {
        precondition(count > 0)
        let bound = UInt64(count)
        let limit = UInt64.max - UInt64.max % bound
        var value = next()
        while value >= limit { value = next() }
        return Int(value % bound)
    }
}
struct Grid {
    let rows: Int
    let cols: Int
    var count: Int { rows * cols }
    private let adjacency: [[Int]]
    init(rows: Int, cols: Int) {
        self.rows = rows; self.cols = cols
        adjacency = (0..<(rows * cols)).map { cell in
            var result: [Int] = []
            if cell / cols > 0 { result.append(cell - cols) }
            if cell % cols + 1 < cols { result.append(cell + 1) }
            if cell / cols + 1 < rows { result.append(cell + cols) }
            if cell % cols > 0 { result.append(cell - 1) }
            return result
        }
    }
    func neighbors(_ cell: Int) -> [Int] { adjacency[cell] }
    func connected(_ cells: [Int]) -> Bool {
        guard let start = cells.first else { return true }
        let allowed = Set(cells)
        var seen: Set<Int> = [start]
        var queue = [start]
        var next = 0
        while next < queue.count {
            let cell = queue[next]
            next += 1
            for neighbor in neighbors(cell) where allowed.contains(neighbor) {
                if seen.insert(neighbor).inserted { queue.append(neighbor) }
            }
        }
        return queue.count == cells.count
    }

}
enum Rules {
    static func geometry(_ cells: [Int], n: Int) -> (symmetric: Bool, capitol: Int?) {
        let rs = cells.map { $0 / n }, cs = cells.map { $0 % n }
        let sr = rs.min()! + rs.max()!, sc = cs.min()! + cs.max()!
        let points = cells.map { [2 * ($0 / n) - sr, 2 * ($0 % n) - sc] }
        let occupied = Set(points)
        var fixed: [[Int]] = []
        for t in 1...7 {
            let mapped = points.map { p -> [Int] in
                let r = p[0], c = p[1]
                switch t {
                case 1: return [c, -r]
                case 2: return [-r, -c]
                case 3: return [-c, r]
                case 4: return [r, -c]
                case 5: return [-r, c]
                case 6: return [c, r]
                default: return [-c, -r]
                }
            }
            if Set(mapped) == occupied {
                fixed.append(cells.indices.filter { points[$0] == mapped[$0] }.map { cells[$0] })
            }
        }
        let cap = fixed.first.flatMap { a -> Int? in
            a.count == 1 && fixed.allSatisfy { $0 == a } ? a[0] : nil
        }
        return (!fixed.isEmpty, cap)
    }
    static func distances(_ labels: [Int], n: Int) -> [Int] {
        let grid = Grid(rows: n, cols: n)
        let groups = Dictionary(grouping: labels.indices, by: { labels[$0] })
        var sizes = Array(repeating: 0, count: labels.count)
        var d = Array(repeating: Int.max, count: labels.count)
        for cells in groups.values {
            precondition(grid.connected(cells))
            let g = geometry(cells, n: n)
            precondition(g.symmetric)
            for c in cells { sizes[c] = cells.count }
            if let c = g.capitol { d[c] = 0 }
        }
        var visited = Set<Int>()
        for _ in labels.indices {
            guard let c = labels.indices.filter({ !visited.contains($0) && d[$0] != Int.max }).min(by: { d[$0] < d[$1] }) else { break }
            visited.insert(c)
            for v in grid.neighbors(c) { d[v] = min(d[v], d[c] + min(sizes[c], sizes[v])) }
        }
        precondition(d.allSatisfy { $0 != Int.max })
        return d
    }
}
struct Puzzle: Codable {
    let name: String
    let n: Int
    let makerSeed: UInt64?
    let clues: [[Int]]
    let witness: [Int]
    static var example: Puzzle {
        let rows = ["ABBCC", "ABBDC", "AADDC", "CAAAC", "CCCCC"]
        let labels = rows.flatMap { $0.utf8.map(Int.init) }
        return Puzzle(name: "example5", n: 5, makerSeed: nil, clues: [[12,-1,-1,-1,17],[8,-1,6,3,-1],[-1,-1,-1,-1,-1],[-1,7,6,-1,10],[25,-1,-1,-1,0]], witness: labels)
    }
    // Merge neighboring regions only when the union remains symmetric. Connectivity
    // follows by construction. Keep cell 0 singleton so there is always a capitol.
    // This creates satisfiable puzzles; uniqueness is deliberately not asserted.
    static func make(n: Int, seed: UInt64, clueCount: Int? = nil) -> Puzzle {
        var rng = SearchRandom(seed: seed)
        let grid = Grid(rows: n, cols: n)
        var labels = Array(0..<(n*n))
        for _ in 0..<(n*n*80) {
            let a = rng.index(n*n), near = grid.neighbors(a), b = near[rng.index(near.count)]
            let x = labels[a], y = labels[b]
            if x == y || x == labels[0] || y == labels[0] { continue }
            let cells = labels.indices.filter { labels[$0] == x || labels[$0] == y }
            if cells.count <= 16 && Rules.geometry(cells, n: n).symmetric {
                for c in cells { labels[c] = x }
            }
        }
        let distances = Rules.distances(labels, n: n)
        var clues: [Int]
        if let clueCount {
            precondition((1...(n*n)).contains(clueCount))
            // Uniform sampling without replacement gives the requested exact
            // density. Do not force a revealed capitol or farthest-cell clue.
            clues = Array(repeating: -1, count: n*n)
            var cells = Array(0..<(n*n))
            for i in 0..<clueCount {
                cells.swapAt(i, i + rng.index(cells.count-i))
                clues[cells[i]] = distances[cells[i]]
            }
        } else {
            clues = distances.map { rng.unit() < 0.4 ? $0 : -1 }
            clues[0] = 0
            let farthest = distances.indices.max(by: { distances[$0] < distances[$1] })!
            clues[farthest] = distances[farthest]
        }
        return Puzzle(name: "generated8_\(seed)", n: n, makerSeed: seed,
                      clues: (0..<n).map { Array(clues[($0*n)..<(($0+1)*n)]) }, witness: labels)
    }
}
