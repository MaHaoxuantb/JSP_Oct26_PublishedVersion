import Foundation

struct LegacyFixture: Decodable { let name: String; let n: Int; let clues: [[Int]]; let witness: [Int] }
struct LegacyFixtures: Decodable { let puzzles: [LegacyFixture] }
struct LegacyObservation: Codable {
    let puzzle: String; let seed: UInt64; let candidate: String
    let limitSeconds: Double?; let elapsedSeconds: Double; let solved: Bool
    let labels: [Int]; let n: Int; let stopReason: String
}
@main struct LegacySolveTime {
    static func main() async throws {
        let a=CommandLine.arguments
        precondition(a.count==7)
        let fixtures=try JSONDecoder().decode(LegacyFixtures.self,from:Data(contentsOf:URL(fileURLWithPath:a[1])))
        let puzzle=fixtures.puzzles[Int(a[2])!]
        var config=RunConfig()
        config.rowNum=puzzle.n; config.colNum=puzzle.n; config.Target=OriginalCondition(Status:puzzle.clues)
        config.seed=UInt64(a[3])!
        let untilSolved=a[4]=="until-solved"
        config.timeLimitSeconds=untilSolved ? Double.greatestFiniteMagnitude : Double(a[4])!
        config.workerCount=1; config.consoleLogging=false
        config.logDirectory=URL(fileURLWithPath:a[5]).deletingLastPathComponent().appendingPathComponent("logs/legacy-\(puzzle.name)-\(config.seed)").path
        // Match stop budget; do not change historical moves or annealing parameters.
        config.maxIterations=untilSolved ? Int.max / 4 : 100_000_000
        config.maxRestarts=untilSolved ? Int.max / 4 : 20_000
        let start=ProcessInfo.processInfo.systemUptime
        let result=try await Main().Run(Config:config)
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        let board=result.best.board
        var ids:[UUID:Int]=[:]
        let labels=board.Relationships.ColorBlocks.flatMap{$0}.map { id -> Int in
            if ids[id]==nil { ids[id]=ids.count }; return ids[id]!
        }
        let output=LegacyObservation(puzzle:puzzle.name,seed:config.seed,candidate:"historical_continuous_e23adc5",
            limitSeconds:untilSolved ? nil : config.timeLimitSeconds,elapsedSeconds:elapsed,solved:result.best.validation.valid,
            labels:labels,n:puzzle.n,stopReason:result.reason.rawValue)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(output).write(to:URL(fileURLWithPath:a[5]),options:.atomic)
    }
}
