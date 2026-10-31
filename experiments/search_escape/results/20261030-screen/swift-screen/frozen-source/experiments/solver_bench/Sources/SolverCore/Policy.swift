import Foundation
import PuzzleRules

public enum StateCodec {
  public static func edges(_ grid: Grid) -> [(Int, Int)] {
    (0..<grid.count).flatMap { c in grid.neighbors[c].filter { $0 > c }.map { (c, $0) } }
  }
  public static func labels(_ strengths: [Double], grid: Grid) -> [Int] {
    var parent = Array(0..<grid.count)
    func root(_ v: Int) -> Int {
      var x = v
      while parent[x] != x { x = parent[x] }
      return x
    }
    for (i, e) in edges(grid).enumerated() where strengths[i] >= 0.5 {
      parent[root(e.1)] = root(e.0)
    }
    return normalized(parent.indices.map { root($0) })
  }
  public static func encode(_ labels: [Int], grid: Grid, previous: SearchState?, continuous: Bool)
    -> SearchState
  {
    let p = previous?.strengths
    return SearchState(
      strengths: edges(grid).enumerated().map { i, e in
        let join = labels[e.0] == labels[e.1]
        if let old = p?[i], (old >= 0.5) == join { return old }
        return join ? (continuous && p != nil ? 0.9 : 1) : (continuous && p != nil ? 0.1 : 0)
      })
  }
  public static func evaluate(_ state: SearchState, puzzle: Puzzle) -> ScoredState {
    let grid = puzzle.grid
    let value = Rules.evaluate(labels(state.strengths, grid: grid), puzzle: puzzle)
    var local = Array(repeating: 0.0, count: grid.count)
    var degree = Array(repeating: 0, count: grid.count)
    for (i, e) in edges(grid).enumerated() {
      let p = state.strengths[i]
      let v = tan(2 * min(p, 1 - p)) / tan(1.0)
      local[e.0] += v
      local[e.1] += v
      degree[e.0] += 1
      degree[e.1] += 1
    }
    for c in local.indices { local[c] /= Double(max(1, degree[c])) }
    let d = local.reduce(0, +) / Double(grid.count)
    let native =
      (2 * value.quality.residual + Double(value.invalid.count) / Double(grid.count) + 2 * d) / 5
    return ScoredState(
      state: state, exact: value, uncertainty: local, discreteness: d, nativeEnergy: native)
  }
}
public enum RegionalPolicy {
  public static func field(_ source: ScoredState, puzzle: Puzzle) -> [Double] {
    var residual = Array(repeating: 0.0, count: puzzle.n * puzzle.n)
    for c in residual.indices where puzzle.clues[c] >= 0 {
      var v: Int? = c
      var seen = Set<Int>()
      while let x = v, seen.insert(x).inserted {
        residual[x] += source.exact.residuals[c] / Double(max(1, puzzle.clueCount))
        v = source.exact.parents[x]
      }
    }
    let values = residual.indices.map {
      2 * residual[$0] + (source.exact.invalid.contains($0) ? 1 : 0) + 2 * source.uncertainty[$0]
    }
    let lo = values.min()!
    let hi = values.max()!
    if hi - lo < 1e-12 { return Array(repeating: 0, count: values.count) }
    return values.map { ($0 - lo) / (hi - lo) }
  }
  public static func focus(_ field: [Double], regional: Bool, rng: inout SplitMix) -> Int {
    if !regional || rng.unit() < 0.2 { return rng.index(field.count) }
    var ticket = rng.unit() * field.reduce(0) { $0 + 0.05 + $1 }
    for c in field.indices {
      ticket -= 0.05 + field[c]
      if ticket <= 0 { return c }
    }
    return field.count - 1
  }
  public static func noise(hotness: Double, regional: Bool, rng: inout SplitMix) -> Double {
    let n = regional ? max(1, min(16, Int((16 - 15 * hotness).rounded()))) : 16
    return (0..<n).reduce(0.0) { value, _ in value + 2 * rng.unit() - 1 } / Double(n)
  }
  public static func patch(
    source: ScoredState, puzzle: Puzzle, regional: Bool, limit: Int, large: Bool,
    rng: inout SplitMix
  ) -> CellMask {
    let grid = puzzle.grid
    let parts = groups(source.exact.labels)
    let field = field(source, puzzle: puzzle)
    let seed = focus(field, regional: regional, rng: &rng)
    let breadth = abs(noise(hotness: field[seed], regional: regional, rng: &rng))
    let maximum = large ? 8 : 4
    let desired = 1 + min(maximum - 1, Int(breadth * Double(maximum)))
    var ids = Set([source.exact.labels[seed]])
    var patch = parts[source.exact.labels[seed]]
    for _ in 1..<desired {
      let frontier = Set(patch.cells.flatMap { grid.neighbors[$0] }.map { source.exact.labels[$0] })
        .subtracting(ids).filter { patch.count + parts[$0].count <= limit }.sorted()
      if frontier.isEmpty { break }
      let id = frontier[rng.index(frontier.count)]
      ids.insert(id)
      patch = patch.union(parts[id])
    }
    return patch
  }
}
