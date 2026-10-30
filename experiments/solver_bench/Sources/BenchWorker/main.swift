import Foundation
import PuzzleRules
import SolverCore

@main struct BenchWorker {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw BenchError("Usage: bench-worker INPUT.json")
    }
    let input = try JSONDecoder().decode(
      WorkerInput.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    let result = try SearchEngine(input: input).run()
    try writeJSON(result, to: input.output + "/result.json")
  }
}
