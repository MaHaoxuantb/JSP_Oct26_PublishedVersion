import BoardPreparation
import Foundation
import PuzzleRules
import ShapeDomain
import SolverCore

@main struct BenchTools {
  static func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
      throw BenchError("Expected precache, new-preparation, prepare-step, evaluate or certify")
    }
    func value(_ name: String) -> String {
      guard let i = args.firstIndex(of: "--" + name), i + 1 < args.count else {
        fatalError("Missing --\(name)")
      }
      return args[i + 1]
    }
    switch command {
    case "precache":
      let templates = try ShapeStore.precompute(maxDimension: 9, progress: value("progress"))
      let manifest = ShapeManifest(maxDimension: 9, templateCount: templates.count)
      try ShapeStore.create(value("db"), templates: templates, manifest: manifest)
      try writeJSON(manifest, to: value("manifest"))
    case "new-preparation":
      try writeJSON(
        PreparationState(n: Int(value("n"))!, slot: Int(value("slot"))!), to: value("output"))
    case "prepare-step":
      let state = try JSONDecoder().decode(
        PreparationState.self, from: Data(contentsOf: URL(fileURLWithPath: value("input"))))
      let next = try BoardMaker.step(
        state, templates: ShapeStore.read(value("db")), seconds: Double(value("seconds"))!,
        progressPath: value("progress"))
      try writeJSON(next, to: value("output"))
    case "evaluate":
      struct Input: Decodable {
        let puzzle: Puzzle
        let labels: [Int]
      }
      let input = try JSONDecoder().decode(
        Input.self, from: Data(contentsOf: URL(fileURLWithPath: value("input"))))
      try writeJSON(Rules.evaluate(input.labels, puzzle: input.puzzle), to: value("output"))
    case "certify":
      let puzzle = try JSONDecoder().decode(
        Puzzle.self, from: Data(contentsOf: URL(fileURLWithPath: value("input"))))
      let checkpoint = value("checkpoint")
      let state: CoverCheckpoint
      if FileManager.default.fileExists(atPath: checkpoint) {
        state = try JSONDecoder().decode(
          CoverCheckpoint.self, from: Data(contentsOf: URL(fileURLWithPath: checkpoint)))
        guard state.puzzle.clues == puzzle.clues && state.puzzle.n == puzzle.n else {
          throw BenchError("Checkpoint puzzle mismatch")
        }
      } else {
        state = CoverCheckpoint(
          puzzle: puzzle, patch: puzzle.grid.full, base: Array(0..<(puzzle.n * puzzle.n)),
          mode: .certify)
      }
      let search = CoverSearch(
        state: state,
        oracle: ShapeOracle(grid: puzzle.grid, templates: try ShapeStore.read(value("db"))))
      _ = search.advance(until: monotonic() + Double(value("seconds"))!)
      try writeJSON(search.state, to: checkpoint)
    default: throw BenchError("Unknown tool command: \(command)")
    }
  }
}
