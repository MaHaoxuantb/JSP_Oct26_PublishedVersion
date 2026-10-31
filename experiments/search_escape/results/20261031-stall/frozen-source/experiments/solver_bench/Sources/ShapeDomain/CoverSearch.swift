import Foundation
import PuzzleRules

public enum CoverMode: String, Codable { case certify, improve }
public struct CoverCounters: Codable {
  public var nodes = 0, distancePrunes = 0, candidateRejects = 0, completedCovers = 0
  public init() {}
}
public struct CoverFrame: Codable { public var query: ShapeQuery }
public struct CoverCheckpoint: Codable {
  public let puzzle: Puzzle, patch: CellMask, base: [Int], mode: CoverMode
  public var lastLabels: [Int]? = nil
  public var frames: [CoverFrame] = [], selected: [CellMask] = [], solutions: [[Int]] = [],
    bestLabels: [Int], bestQuality: Quality, counters = CoverCounters(), initialized = false,
    finished = false, exhausted = false
  public init(puzzle: Puzzle, patch: CellMask, base: [Int], mode: CoverMode) {
    self.puzzle = puzzle
    self.patch = patch
    self.base = normalized(base)
    self.mode = mode
    bestLabels = normalized(base)
    bestQuality = Rules.evaluate(base, puzzle: puzzle).quality
  }
}
public struct BoundResult {
  public let quality: Quality
  public let excludesExactSolution: Bool
}
public enum CoverBounds {
  public static func evaluate(
    puzzle: Puzzle, patch: CellMask, base: [Int], selected: [CellMask], mode: CoverMode
  ) -> BoundResult {
    let grid = puzzle.grid
    let outside = groups(base).filter { !$0.intersects(patch) }
    var low = Array(repeating: 1, count: grid.count)
    var high = Array(repeating: max(1, patch.count), count: grid.count)
    var caps: [Int] = []
    var occupied = CellMask()
    var issues = 0
    for group in outside + selected {
      let geo = Rules.geometry(group, grid: grid)
      for c in group.cells {
        low[c] = group.count
        high[c] = group.count
      }
      occupied = occupied.union(group)
      if geo.legal { if let cap = geo.capitol { caps.append(cap) } } else { issues += 1 }
    }
    let remaining = grid.full.subtracting(occupied)
    for c in remaining.cells { high[c] = max(1, remaining.count) }
    let possible = caps + remaining.cells.filter { mode == .improve || puzzle.clues[$0] <= 0 }
    let lower = Rules.distances(grid: grid, sizes: low, sources: possible).distances
    let upper = Rules.distances(grid: grid, sizes: high, sources: caps).distances
    var wrong = 0
    var error = 0.0
    for c in 0..<grid.count where puzzle.clues[c] >= 0 {
      let t = puzzle.clues[c]
      if lower[c] > t {
        wrong += 1
        error += lower[c] >= 1_000_000_000 ? 1 : 1 - Double(t) / Double(lower[c])
      } else if upper[c] < t {
        wrong += 1
        error += 1 - Double(upper[c]) / Double(t)
      }
    }
    return BoundResult(
      quality: Quality(
        issues: issues, wrong: wrong, residual: error / Double(max(1, puzzle.clueCount))),
      excludesExactSolution: issues > 0 || wrong > 0)
  }
}
public final class CoverSearch {
  public var state: CoverCheckpoint
  public let oracle: ShapeOracle
  private var currentMask = CellMask()
  public init(state: CoverCheckpoint, oracle: ShapeOracle) {
    self.state = state
    self.oracle = oracle
    for x in state.selected { currentMask = currentMask.union(x) }
  }
  public convenience init(
    puzzle: Puzzle, patch: CellMask, base: [Int], mode: CoverMode, oracle: ShapeOracle
  ) {
    self.init(
      state: CoverCheckpoint(puzzle: puzzle, patch: patch, base: base, mode: mode), oracle: oracle)
  }
  private func labels() -> [Int] {
    var out = state.base
    let offset = (out.max() ?? -1) + 1
    for (i, part) in state.selected.enumerated() { for c in part.cells { out[c] = offset + i } }
    return normalized(out)
  }
  private func makeFrame(_ remaining: CellMask) -> CoverFrame {
    let grid = state.puzzle.grid
    // Cache-estimated MRV: ordering only. An empty cache is never an empty domain.
    let cells = remaining.cells.sorted { a, b in
      let az = state.puzzle.clues[a] == 0
      let bz = state.puzzle.clues[b] == 0
      if az != bz { return az }
      let ad = grid.neighbors[a].filter { remaining.contains($0) }.count
      let bd = grid.neighbors[b].filter { remaining.contains($0) }.count
      if ad != bd { return ad < bd }
      return a < b
    }
    let preferred = groups(state.base)
    var best: ShapeQuery? = nil
    for c in cells.prefix(4) {
      let q = oracle.query(allowed: remaining, anchor: c, preferred: preferred)
      if best == nil || q.seedMasks.count < best!.seedMasks.count { best = q }
    }
    return CoverFrame(query: best!)
  }
  private func permitted(_ mask: CellMask) -> Bool {
    guard state.mode == .certify else { return true }
    let geo = Rules.geometry(mask, grid: state.puzzle.grid)
    for c in mask.cells {
      if state.puzzle.clues[c] == 0 && geo.capitol != c { return false }
      if geo.capitol == c && state.puzzle.clues[c] > 0 { return false }
      if state.puzzle.clues[c] >= 0 {
        for v in state.puzzle.grid.neighbors[c] where state.puzzle.clues[v] >= 0 {
          if abs(state.puzzle.clues[c] - state.puzzle.clues[v]) > mask.count { return false }
        }
      }
    }
    return true
  }
  private func backtrack() {
    state.frames.removeLast()
    if !state.selected.isEmpty {
      let last = state.selected.removeLast()
      currentMask = currentMask.subtracting(last)
    }
    if state.frames.isEmpty {
      state.finished = true
      state.exhausted = true
    }
  }
  @discardableResult public func advance(
    until: Double, nodeLimit: Int = Int.max, coverLimit: Int = Int.max, useBounds: Bool = true,
    maxSolutions: Int = 4
  ) -> String {
    if state.finished { return state.exhausted ? "exhausted" : "solution_limit" }
    if !state.initialized {
      state.initialized = true
      state.frames = [makeFrame(state.patch)]
    }
    let firstNodes = state.counters.nodes
    let firstCovers = state.counters.completedCovers
    while !state.frames.isEmpty && monotonic() < until
      && state.counters.nodes - firstNodes < nodeLimit
      && state.counters.completedCovers - firstCovers < coverLimit
    {
      let i = state.frames.count - 1
      var query = state.frames[i].query
      let item = oracle.next(&query, until: until)
      state.frames[i].query = query
      switch item {
      case .paused: return "time_slice"
      case .exhausted:
        backtrack()
        continue
      case .shape(let shape):
        state.counters.nodes += 1
        if !permitted(shape) {
          state.counters.candidateRejects += 1
          continue
        }
        state.selected.append(shape)
        currentMask = currentMask.union(shape)
        if useBounds {
          let bound = CoverBounds.evaluate(
            puzzle: state.puzzle, patch: state.patch, base: state.base, selected: state.selected,
            mode: state.mode)
          let reject =
            state.mode == .certify
            ? bound.excludesExactSolution : !(bound.quality < state.bestQuality)
          if reject {
            state.counters.distancePrunes += 1
            state.selected.removeLast()
            currentMask = currentMask.subtracting(shape)
            continue
          }
        }
        let remaining = state.patch.subtracting(currentMask)
        if remaining.isEmpty {
          state.counters.completedCovers += 1
          let candidate = labels()
          let value = Rules.evaluate(candidate, puzzle: state.puzzle)
          state.lastLabels = candidate
          if value.quality < state.bestQuality {
            state.bestQuality = value.quality
            state.bestLabels = candidate
          }
          if value.solved && !state.solutions.contains(candidate) {
            state.solutions.append(candidate)
            if state.mode == .improve || state.solutions.count >= maxSolutions {
              state.finished = true
              state.exhausted = false
              state.selected.removeLast()
              currentMask = currentMask.subtracting(shape)
              return "solution_limit"
            }
          }
          state.selected.removeLast()
          currentMask = currentMask.subtracting(shape)
        } else {
          state.frames.append(makeFrame(remaining))
        }
      }
    }
    if state.frames.isEmpty {
      state.finished = true
      state.exhausted = true
      return "exhausted"
    }
    return monotonic() >= until ? "time_slice" : "work_slice"
  }
}
