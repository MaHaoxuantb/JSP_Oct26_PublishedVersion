import Foundation

struct SolveObservation: Codable {
    let puzzle: String
    let seed: UInt64
    let candidate: String
    let n: Int
    let labels: [Int]
    let limitSeconds: Double?
    let elapsedSeconds: Double
    let solved: Bool
    let wrongClues: Int
    let issues: Int
    let answer: Int?
    let stopReason: String
}

@main struct SolveTime {
    static func main() async throws {
        let a = CommandLine.arguments
        precondition(a.count == 7)
        let n = Int(ProcessInfo.processInfo.environment["PUZZLE_EXPERIMENT_BOARD_SIZE"] ?? "8")!
        let matchDensity = ProcessInfo.processInfo.environment["PUZZLE_EXPERIMENT_MATCH_DENSITY"] == "1"
        let realClues = RunConfig.fullPuzzle.Target.Status.flatMap { $0 }.filter { $0 >= 0 }.count
        let clueCount = matchDensity ? Int((Double(n*n*realClues) / 121).rounded()) : nil
        func make(_ seed: UInt64) -> Puzzle {
            let made = Puzzle.make(n: n, seed: seed, clueCount: clueCount)
            if let clueCount {
                precondition(made.clues.flatMap { $0 }.filter { $0 >= 0 }.count == clueCount)
                return Puzzle(name: "\(made.name)_clues\(clueCount)", n: n, makerSeed: seed, clues: made.clues, witness: made.witness)
            }
            return made
        }
        var example = Puzzle.example
        if matchDensity {
            let count = Int((Double(25*realClues) / 121).rounded())
            var locations = example.clues.flatMap { $0 }.indices.filter { example.clues[$0/5][$0%5] >= 0 }
            var rng = SearchRandom(seed: 5101)
            var clues = Array(repeating: Array(repeating: -1, count: 5), count: 5)
            for i in 0..<count {
                locations.swapAt(i, i + rng.index(locations.count-i))
                let cell = locations[i]
                clues[cell/5][cell%5] = example.clues[cell/5][cell%5]
            }
            example = Puzzle(name: "example5_clues\(count)", n: 5, makerSeed: 5101,
                             clues: clues, witness: example.witness)
            precondition(clues.flatMap { $0 }.filter { $0 >= 0 }.count == count)
        }
        let puzzles = [example, make(UInt64(n*1000+101)), make(UInt64(n*1000+102))]
        if let path = ProcessInfo.processInfo.environment["PUZZLE_EXPERIMENT_FIXTURES_OUTPUT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Output(puzzles: puzzles, timings: [], trials: [])).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        let puzzle = puzzles[Int(a[1])!]
        var config = puzzle.config
        config.seed = UInt64(a[2])!
        let untilSolved = a[3] == "until-solved"
        config.timeLimitSeconds = untilSolved ? Double.greatestFiniteMagnitude : Double(a[3])!
        if untilSolved {
            config.maxIterations = Int.max / 4
            config.maxRestarts = Int.max / 4
        }
        config.logDirectory = a[5]
        // Guard fixture and scoring correctness before timing any search.
        let c = SearchContext(config: config)
        let witness = c.evaluate(labels: puzzle.witness)
        precondition(witness.validation.valid)
        if puzzle.n == 5 { precondition(witness.validation.answer?.sumOfSquares == 8045) }
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await Main().Run(Config: config)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let report = ExactValidator().validate(result.best.board, target: config.Target)
        precondition(report.valid == result.best.validation.valid)
        let observation = SolveObservation(puzzle: puzzle.name, seed: config.seed, candidate: a[6], n: puzzle.n, labels: result.best.labels,
            limitSeconds: untilSolved ? nil : config.timeLimitSeconds, elapsedSeconds: elapsed,
            solved: report.valid, wrongClues: report.mismatches.count, issues: report.issues.count,
            answer: report.answer?.sumOfSquares, stopReason: result.reason.rawValue)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(observation).write(to: URL(fileURLWithPath: a[4]), options: .atomic)
    }
}
