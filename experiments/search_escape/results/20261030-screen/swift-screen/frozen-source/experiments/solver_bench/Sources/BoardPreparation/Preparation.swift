import Foundation
import PuzzleRules
import ShapeDomain

public struct Certificate: Codable {
  public let puzzle: Puzzle, solutionCount: Int, solutions: [[Int]], answers: [Int],
    exhausted: Bool, rules: String, generator: String, nodes: Int
  public init(puzzle: Puzzle, solutions: [[Int]], nodes: Int) {
    self.puzzle = puzzle
    self.solutions = solutions
    solutionCount = solutions.count
    answers = Array(Set(solutions.compactMap { Rules.evaluate($0, puzzle: puzzle).answer }))
      .sorted()
    exhausted = true
    rules = rulesVersion
    generator = generatorVersion
    self.nodes = nodes
  }
}
public struct PreparationState: Codable {
  public let n: Int, slot: Int
  public var attempt = 0, round = 0, witness: [Int] = [], puzzle: Puzzle?,
    counterexamples: [CellMask] = [], search: CoverCheckpoint?, qualified: [Certificate] = [],
    rejected = 0, queries = 0, nodes = 0
  public init(n: Int, slot: Int) {
    self.n = n
    self.slot = slot
  }
}
public struct PreparationProgress: Codable {
  public let n: Int, slot: Int, attempt: Int, maskRound: Int, nodes: Int, solutionsFound: Int,
    upperBoundKnown: Bool, qualified: Int, phase: String, updated: Double
}
public enum BoardMaker {
  public static func make(n: Int, seed: UInt64) -> [Int] {
    let grid = Grid(rows: n, cols: n)
    var rng = SplitMix(seed: seed)
    var labels = Array(0..<grid.count)
    let desired = 3 + rng.index(max(1, min(15, grid.count / 2) - 2))
    for _ in 0..<(grid.count * 100) {
      if groups(labels).count <= desired { break }
      let c = rng.index(grid.count)
      let v = grid.neighbors[c][rng.index(grid.neighbors[c].count)]
      let a = labels[c]
      let b = labels[v]
      if a == b { continue }
      let mask = CellMask(cells: labels.indices.filter { labels[$0] == a || labels[$0] == b })
      if Rules.geometry(mask, grid: grid).legal { for x in mask.cells { labels[x] = a } }
    }
    return normalized(labels)
  }
  public static func chooseMask(n: Int, differences: [CellMask], seed: UInt64) -> CellMask? {
    let k = Int((Double(n * n) * 33 / 121).rounded())
    var rng = SplitMix(seed: seed)
    if differences.contains(where: { $0.isEmpty }) { return nil }
    let sets = Array(Set(differences)).sorted { $0.count < $1.count }
    var answer: CellMask? = nil
    var visits = 0
    func visit(_ selected: CellMask) {
      visits += 1
      if visits > 100_000 || answer != nil { return }
      guard
        let uncovered = sets.filter({ !$0.intersects(selected) }).min(by: { $0.count < $1.count })
      else {
        answer = selected
        return
      }
      if selected.count >= k { return }
      let ordered = uncovered.cells.sorted { a, b in
        let ac = sets.filter { $0.contains(a) }.count
        let bc = sets.filter { $0.contains(b) }.count
        return ac != bc ? ac > bc : a < b
      }
      for c in ordered {
        visit(selected.union(CellMask(cells: [c])))
        if answer != nil { return }
      }
    }
    visit(CellMask())
    guard var result = answer else { return nil }
    var remaining = (0..<(n * n)).filter { !result.contains($0) }
    while result.count < k {
      let index = rng.index(remaining.count)
      result.insert(remaining.remove(at: index))
    }
    return result
  }
  public static func step(
    _ input: PreparationState, templates: [ShapeTemplate], seconds: Double, progressPath: String?
  ) throws -> PreparationState {
    if input.qualified.contains(where: { $0.solutionCount == 1 }) { return input }
    var state = input
    let until = monotonic() + seconds
    let grid = Grid(rows: state.n, cols: state.n)
    let oracle = ShapeOracle(grid: grid, templates: templates)
    func progress(_ phase: String) throws {
      if let path = progressPath {
        try writeJSON(
          PreparationProgress(
            n: state.n, slot: state.slot, attempt: state.attempt, maskRound: state.round,
            nodes: state.nodes + (state.search?.counters.nodes ?? 0),
            solutionsFound: state.search?.solutions.count ?? 0,
            upperBoundKnown: state.search?.exhausted ?? false, qualified: state.qualified.count,
            phase: phase, updated: Date().timeIntervalSince1970), to: path)
      }
    }
    while monotonic() < until {
      if state.puzzle == nil {
        let seed = SplitMix.derive(
          UInt64(20_261_029 + state.n * 1000 + state.slot), "plant-\(state.attempt)")
        if state.witness.isEmpty { state.witness = make(n: state.n, seed: seed) }
        let blank = Puzzle(id: "plant", n: state.n, clues: Array(repeating: -1, count: grid.count))
        let value = Rules.evaluate(state.witness, puzzle: blank)
        if value.capitols.isEmpty || groups(state.witness).count < 3 || Set(value.sizes).count < 2 {
          state.attempt += 1
          state.witness = []
          state.counterexamples = []
          state.round = 0
          continue
        }
        guard
          let mask = chooseMask(
            n: state.n, differences: state.counterexamples, seed: seed &+ UInt64(state.round))
        else {
          state.attempt += 1
          state.witness = []
          state.counterexamples = []
          state.round = 0
          continue
        }
        let clues = (0..<grid.count).map { mask.contains($0) ? value.distances[$0]! : -1 }
        state.puzzle = Puzzle(
          id: "n\(state.n)-slot\(state.slot)-plant\(state.attempt)-mask\(state.round)", n: state.n,
          clues: clues)
        state.search = CoverCheckpoint(
          puzzle: state.puzzle!, patch: grid.full, base: Array(0..<grid.count), mode: .certify)
        state.queries += 1
      }
      let search = CoverSearch(state: state.search!, oracle: oracle)
      _ = search.advance(until: min(until, monotonic() + 0.5), maxSolutions: 4)
      state.search = search.state
      try progress("certifying")
      if !search.state.finished { continue }
      state.nodes += search.state.counters.nodes
      let solutions = search.state.solutions
      let puzzle = state.puzzle!
      if search.state.exhausted && !solutions.contains(normalized(state.witness)) {
        throw BenchError("Exhaustive certifier omitted its valid planted witness")
      }
      if search.state.exhausted && (1...3).contains(solutions.count) {
        let cert = Certificate(
          puzzle: puzzle, solutions: solutions, nodes: search.state.counters.nodes)
        if !state.qualified.contains(where: { $0.puzzle.clues == puzzle.clues }) {
          state.qualified.append(cert)
        }
        if solutions.count == 1 {
          state.search = nil
          try progress("unique_certified")
          return state
        }
      }
      let blank = Puzzle(
        id: "comparison", n: state.n, clues: Array(repeating: -1, count: grid.count))
      let target = Rules.evaluate(state.witness, puzzle: blank).distances
      for solution in solutions where normalized(solution) != normalized(state.witness) {
        let d = Rules.evaluate(solution, puzzle: blank).distances
        let difference = CellMask(cells: (0..<grid.count).filter { target[$0] != d[$0] })
        if !state.counterexamples.contains(difference) { state.counterexamples.append(difference) }
      }
      state.round += 1
      if state.round >= 16 || state.counterexamples.contains(where: { $0.isEmpty }) {
        state.attempt += 1
        state.witness = []
        state.counterexamples = []
        state.round = 0
        state.rejected += 1
      }
      state.puzzle = nil
      state.search = nil
    }
    try progress("checkpointed")
    return state
  }
}
