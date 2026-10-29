import Foundation

// Independent rules for generation and cross-checking. Cell centers are integers;
// doubled coordinates let all seven plane symmetries align on half-cell centers.
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
    var config: RunConfig {
        var c = RunConfig.example
        c.rowNum = n; c.colNum = n; c.Target = OriginalCondition(Status: clues)
        c.pathEvaluation = .cpu; c.consoleLogging = false; c.workerCount = 1
        return c
    }
    static var example: Puzzle {
        let rows = ["ABBCC", "ABBDC", "AADDC", "CAAAC", "CCCCC"]
        let labels = rows.flatMap { $0.utf8.map(Int.init) }
        return Puzzle(name: "example5", n: 5, makerSeed: nil, clues: RunConfig.example.Target.Status, witness: labels)
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

struct EdgeSpace {
    let n: Int
    let pairs: [(Int, Int)]
    init(n: Int) {
        self.n = n
        var p: [(Int, Int)] = []
        for r in 0..<n { for c in 0..<n {
            let a = r*n+c
            if c+1<n { p.append((a,a+1)) }
            if r+1<n { p.append((a,a+n)) }
        }}
        pairs = p
    }
    func labels(_ strengths: [Double]) -> [Int] {
        var parent = Array(0..<(n*n))
        func root(_ a: Int) -> Int { var v=a; while parent[v] != v { v=parent[v] }; return v }
        for (i,p) in pairs.enumerated() where strengths[i] >= 0.5 {
            parent[root(p.1)] = root(p.0)
        }
        return parent.indices.map { root($0) }
    }
    func board(_ p: [Double], context: SearchContext) -> Board {
        let b = context.board(labels: labels(p))
        for (i,e) in pairs.enumerated() {
            let r=e.0/n, c=e.0%n
            if e.1 == e.0+1 { b.Relationships.VerticalRelationships[r][c] = p[i] }
            else { b.Relationships.HorizontalRelationships[r][c] = p[i] }
        }
        return b
    }
}
struct Timing: Codable {
    let puzzle: String; let repeatIndex: Int; let candidate: String
    let evaluations: Int; let seconds: Double; let checksum: Double
}
struct Trial: Codable {
    let puzzle: String; let seed: UInt64; let candidate: String
    let budgetSeconds: Double; let seconds: Double; let solved: Bool
    let evaluations: Int; let wrongClues: Int; let structuralIssues: Int; let answer: Int?
}
struct Output: Codable { let puzzles: [Puzzle]; let timings: [Timing]; let trials: [Trial] }

@main struct Experiment {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    static func controlled(_ puzzle: Puzzle, seed: UInt64, continuous: Bool, budget: Double) -> Trial {
        let space = EdgeSpace(n: puzzle.n), context = SearchContext(config: puzzle.config), energy = Energy()
        var rng = SearchRandom(seed: seed)
        func initial() -> [Double] { space.pairs.map { _ in let p=rng.unit(); return continuous ? p : (p>=0.5 ? 1 : 0) } }
        var strengths = initial()
        func evaluate(_ p: [Double]) -> (Double, ValidationReport) {
            if continuous {
                let b = space.board(p, context: context)
                return (energy.evaluate(Board: b, Target: puzzle.config.Target, Factors: puzzle.config.factors).scores.total,
                        ExactValidator().validate(b, target: puzzle.config.Target))
            }
            let state = context.evaluate(labels: space.labels(p))
            return (state.scores.total, ExactValidator().validate(state.board, target: puzzle.config.Target))
        }
        let start=now()
        var current=evaluate(strengths), best=current.1, count=1
        func better(_ a: ValidationReport, _ b: ValidationReport) -> Bool {
            a.issues.count != b.issues.count ? a.issues.count < b.issues.count : a.mismatches.count < b.mismatches.count
        }
        while now()-start < budget && !best.valid {
            let edge=rng.index(strengths.count), p=rng.unit(), draw=rng.unit()
            var proposal=strengths
            proposal[edge] = continuous ? p : (p>=0.5 ? 1 : 0)
            let candidate=evaluate(proposal); count += 1
            if candidate.1.valid || better(candidate.1,best) { best=candidate.1 }
            let temperature=max(0.001, 0.03 * pow(0.997, Double(count%1000)))
            if candidate.1.valid || candidate.0 <= current.0 || draw < exp((current.0-candidate.0)/temperature) {
                strengths=proposal; current=candidate
            }
            if count%1000 == 0 { strengths=initial(); current=evaluate(strengths); count += 1
                if current.1.valid || better(current.1,best) { best=current.1 }
            }
        }
        return Trial(puzzle:puzzle.name, seed:seed, candidate:continuous ? "controlled_continuous" : "controlled_discrete",
                     budgetSeconds:budget, seconds:now()-start, solved:best.valid, evaluations:count,
                     wrongClues:best.mismatches.count, structuralIssues:best.issues.count, answer:best.answer?.sumOfSquares)
    }
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count == 5 else { fatalError("Usage: experiment OUTPUT_DIR TRIALS SECONDS POOL_SIZE") }
        let out=URL(fileURLWithPath:args[1]), trials=Int(args[2])!, seconds=Double(args[3])!, poolSize=Int(args[4])!
        try FileManager.default.createDirectory(at:out, withIntermediateDirectories:true)
        let puzzles=[Puzzle.example, Puzzle.make(n:8,seed:8101), Puzzle.make(n:8,seed:8102)]
        var timings:[Timing]=[], results:[Trial]=[]
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        func save() throws { try encoder.encode(Output(puzzles:puzzles,timings:timings,trials:results)).write(to:out.appendingPathComponent("results.json"),options:.atomic) }
        // Rule regression checks: 1x3 and X have symmetry but no capitol.
        precondition(Rules.geometry([0,1,2],n:3).capitol == nil)
        precondition(Rules.geometry([1,3,4,5,7],n:3).capitol == nil)
        precondition(Rules.geometry([0],n:1).capitol == 0)
        for puzzle in puzzles {
            let context=SearchContext(config:puzzle.config)
            let witness=context.board(labels:puzzle.witness)
            let report=ExactValidator().validate(witness,target:puzzle.config.Target)
            precondition(report.valid)
            let distances=Rules.distances(puzzle.witness,n:puzzle.n)
            let full=OriginalCondition(Status:(0..<puzzle.n).map { Array(distances[($0*puzzle.n)..<(($0+1)*puzzle.n)]) })
            precondition(ExactValidator().validate(witness,target:full).valid)
            precondition(Energy().evaluate(Board:witness,Target:puzzle.config.Target).scores.total < 1e-12)
            if puzzle.n==5 { precondition(report.answer?.sumOfSquares == 8045) }
            let space=EdgeSpace(n:puzzle.n)
            var rng=SearchRandom(seed:999)
            let pool=(0..<poolSize).map { _ in space.pairs.map { _ in rng.unit() } }
            let labels=pool.map { space.labels($0) }
            // Pre-materialize identical hard partitions for both paths. No fractional
            // edge penalty in this microbenchmark; only scoring implementations differ.
            let boards=labels.map { context.board(labels:$0) }
            for repetition in 0..<5 {
                for continuous in (repetition%2==0 ? [false,true] : [true,false]) {
                    let c=SearchContext(config:puzzle.config), e=Energy()
                    let start=now(); var checksum=0.0
                    for i in pool.indices {
                        checksum += continuous ? e.evaluate(Board:boards[i],Target:puzzle.config.Target,Factors:puzzle.config.factors).scores.total : c.evaluate(labels:labels[i]).scores.total
                    }
                    timings.append(Timing(puzzle:puzzle.name,repeatIndex:repetition,candidate:continuous ? "continuous_cold" : "discrete_cold",evaluations:poolSize,seconds:now()-start,checksum:checksum))
                    let warm=now(); checksum=0
                    for _ in 0..<5 { for i in pool.indices {
                        checksum += continuous ? e.evaluate(Board:boards[i],Target:puzzle.config.Target,Factors:puzzle.config.factors).scores.total : c.evaluate(labels:labels[i]).scores.total
                    }}
                    timings.append(Timing(puzzle:puzzle.name,repeatIndex:repetition,candidate:continuous ? "continuous_warm" : "discrete_warm",evaluations:5*poolSize,seconds:now()-warm,checksum:checksum))
                }
            }
            for i in 0..<trials {
                let seed=UInt64(20261029+i)
                for continuous in (i%2==0 ? [false,true] : [true,false]) {
                    let result=controlled(puzzle,seed:seed,continuous:continuous,budget:seconds)
                    results.append(result); try save()
                    print("\(puzzle.name) \(result.candidate) seed=\(seed) solved=\(result.solved) evaluations=\(result.evaluations) wrong=\(result.wrongClues) issues=\(result.structuralIssues)")
                    fflush(stdout)
                }
                var config=puzzle.config
                config.seed=seed; config.timeLimitSeconds=seconds
                config.logDirectory=out.appendingPathComponent("logs/\(puzzle.name)-\(seed)").path
                let start=now(), result=try await Main().Run(Config:config)
                let report=result.best.validation
                results.append(Trial(puzzle:puzzle.name,seed:seed,candidate:"production_discrete",budgetSeconds:seconds,seconds:now()-start,solved:report.valid,evaluations:result.repairs.evaluations,wrongClues:report.mismatches.count,structuralIssues:report.issues.count,answer:report.answer?.sumOfSquares))
                print("\(puzzle.name) production_discrete seed=\(seed) solved=\(report.valid) seconds=\(now()-start)"); fflush(stdout)
                try save()
            }
        }
        try save()
    }
}
