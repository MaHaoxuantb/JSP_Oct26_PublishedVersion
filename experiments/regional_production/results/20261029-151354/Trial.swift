import Foundation
struct Fixture: Decodable { let n: Int; let name: String; let clues: [[Int]] }
struct Fixtures: Decodable { let puzzles: [Fixture] }
struct Observation: Codable {
    let n: Int; let seed: UInt64; let regional: Bool; let seconds: Double
    let solved: Bool; let reason: String; let snapshot: BoardSnapshot
}
@main struct Trial {
    static func main() async throws {
        let a = CommandLine.arguments
        if a.count==2 && a[1]=="--policy-test" { ExperimentPolicy.selfTest(); return }
        let f = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: URL(fileURLWithPath:a[1]))).puzzles[Int(a[2])!]
        var config = RunConfig()
        config.rowNum=f.n; config.colNum=f.n; config.Target=OriginalCondition(Status:f.clues)
        config.seed=UInt64(a[3])!; config.timeLimitSeconds=Double(a[4])!
        config.workerCount=1; config.consoleLogging=false
        config.maxIterations=Int.max/4; config.maxRestarts=Int.max/4
        config.progressInterval=1; config.progressTimeIntervalSeconds=1
        config.logDirectory=a[5]+"/logs"
        if ProcessInfo.processInfo.environment["EXPERIMENT_CONTINUOUS"] == "1" {
            config.factors = Energy.Factors(realAIM:2, symmetry:1, discreteness:2)
        }
        let result = try await Main().Run(Config:config)
        let report = Observation(n:f.n, seed:config.seed, regional:ExperimentPolicy.enabled,
            seconds:result.elapsedSeconds, solved:result.best.validation.valid,
            reason:result.reason.rawValue, snapshot:BoardSnapshot(result.best))
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:URL(fileURLWithPath:a[5]+"/result.json"),options:.atomic)
    }
}
