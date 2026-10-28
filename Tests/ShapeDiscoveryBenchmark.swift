import Foundation

/// Opt-in bounded shape discovery. No solved partition is read or supplied, and
/// this executable never calls Main.Run or contacts a coordinator.
@main
struct ShapeDiscoveryBenchmark {
    struct Trial: Codable {
        let seed: UInt64
        let shapes: Int
        let largestArea: Int
        let irregularLargeShapes: Int
        let unknownCapitolsVisited: Int
        let unknownCapitolsGenerated: Int
        let growthSteps: Int
        let masks: Int
        let seconds: Double
    }

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--run" else {
            print("Idle. Pass --run [seeds=5] [batches-per-seed=16] for bounded shape discovery.")
            return
        }
        let seeds = args.count > 1 ? Int(args[1]) ?? 0 : 5
        let batches = args.count > 2 ? Int(args[2]) ?? 0 : 16
        guard seeds > 0, batches > 0 else { throw ConfigurationError(message: "Provide positive seeds and batches.") }
        var trials: [Trial] = []
        for seed in 0..<seeds {
            var config = RunConfig.fullPuzzle
            config.seed = UInt64(seed); config.pathEvaluation = .cpu
            let context = SearchContext(config: config), patch = Array(0..<121)
            let start = ProcessInfo.processInfo.systemUptime
            var shapes = Set<[Int]>()
            for _ in 0..<batches {
                shapes.formUnion(context.growCapitolShapes(patch: patch, until: .infinity, budget: 128))
                shapes.formUnion(context.sampleRegionShapes(patch: patch, until: .infinity, budget: 256))
            }
            let unknown = Set(shapes.compactMap { context.regions.geometry($0).capitol }.filter { context.constraints.clues[$0] < 0 })
            let irregular = shapes.filter { cells in
                guard cells.count > config.maxPatchCells else { return false }
                let rs = cells.map { $0 / 11 }, cs = cells.map { $0 % 11 }
                return cells.count != (rs.max()!-rs.min()!+1)*(cs.max()!-cs.min()!+1)
            }.count
            trials.append(Trial(seed: UInt64(seed), shapes: shapes.count, largestArea: shapes.map(\.count).max() ?? 0,
                                irregularLargeShapes: irregular,
                                unknownCapitolsVisited: context.visitedCapitolAnchors.filter { context.constraints.clues[$0] < 0 }.count,
                                unknownCapitolsGenerated: unknown.count, growthSteps: context.growthSteps,
                                masks: context.metrics.catalogMasks, seconds: ProcessInfo.processInfo.systemUptime-start))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(trials), encoding: .utf8)!)
    }
}
