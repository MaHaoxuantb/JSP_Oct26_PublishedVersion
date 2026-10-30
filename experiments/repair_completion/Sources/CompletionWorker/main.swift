import Foundation
import PuzzleRules
import ShapeDomain
import SolverCore
import RepairPolicies

struct Input: Codable { let worker: WorkerInput, persistent: Bool, routeSelected: Bool }
@main struct CompletionWorker {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else { throw BenchError("Usage: completion-worker INPUT.json") }
    let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    let policy = try RepairScheduler(persistent: input.persistent, routeSelected: input.routeSelected, output: input.worker.output)
    let result = try SearchEngine(input: input.worker, intensifier: policy).run()
    try writeJSON(result, to: input.worker.output + "/result.json")
    try writeJSON(policy.counters, to: input.worker.output + "/repair-progress.json")
  }
}
