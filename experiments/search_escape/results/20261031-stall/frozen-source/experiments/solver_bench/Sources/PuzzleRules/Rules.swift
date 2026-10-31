import Foundation

public struct Geometry: Codable {
  public let connected: Bool, symmetric: Bool, capitol: Int?, symmetries: [Int]
  public var legal: Bool { connected && symmetric }
}
public enum Rules {
  public static let generationTransforms = [2, 4, 5, 6, 7]  // 90-degree invariance implies 180-degree invariance.
  public static func geometry(_ mask: CellMask, grid: Grid) -> Geometry {
    let cells = mask.cells
    guard !cells.isEmpty else {
      return Geometry(connected: false, symmetric: false, capitol: nil, symmetries: [])
    }
    let rsum = cells.map { $0 / grid.cols }.min()! + cells.map { $0 / grid.cols }.max()!
    let csum = cells.map { $0 % grid.cols }.min()! + cells.map { $0 % grid.cols }.max()!
    let points = cells.map { [2 * ($0 / grid.cols) - rsum, 2 * ($0 % grid.cols) - csum] }
    let occupied = Set(points)
    var invariants: [Int] = []
    var fixed: [CellMask] = []
    for t in 1...7 {
      let mapped = points.map { p -> [Int] in
        let r = p[0]
        let c = p[1]
        switch t {
        case 1: return [c, -r]
        case 2: return [-r, -c]
        case 3: return [-c, r]
        case 4: return [r, -c]
        case 5: return [-r, c]
        case 6: return [c, r]
        default: return [-c, -r]
        }
      }
      if Set(mapped) == occupied {
        invariants.append(t)
        fixed.append(
          CellMask(cells: cells.indices.filter { points[$0] == mapped[$0] }.map { cells[$0] }))
      }
    }
    let connected = grid.connected(mask)
    let cap = fixed.first.flatMap { x -> Int? in
      x.count == 1 && fixed.allSatisfy { $0 == x } ? x.first : nil
    }
    return Geometry(
      connected: connected, symmetric: !invariants.isEmpty, capitol: connected ? cap : nil,
      symmetries: invariants)
  }
  public static func distances(grid: Grid, sizes: [Int], sources: [Int]) -> (
    distances: [Int], parents: [Int?]
  ) {
    var d = Array(repeating: 1_000_000_000, count: grid.count)
    var parents = [Int?](repeating: nil, count: grid.count)
    var seen = CellMask()
    for c in sources { d[c] = 0 }
    for _ in 0..<grid.count {
      var next = -1
      var value = 1_000_000_000
      for c in 0..<grid.count where !seen.contains(c) && d[c] < value {
        next = c
        value = d[c]
      }
      if next < 0 { break }
      seen.insert(next)
      for v in grid.neighbors[next] {
        let candidate = value + min(sizes[next], sizes[v])
        if candidate < d[v] {
          d[v] = candidate
          parents[v] = next
        }
      }
    }
    return (d, parents)
  }
  public static func evaluate(_ input: [Int], puzzle: Puzzle) -> ExactEvaluation {
    let labels = normalized(input)
    let grid = puzzle.grid
    let parts = groups(labels)
    var sizes = Array(repeating: 0, count: grid.count)
    var caps: [Int] = []
    var invalid = CellMask()
    var issues = 0
    for part in parts {
      let geo = geometry(part, grid: grid)
      for c in part.cells { sizes[c] = part.count }
      if !geo.legal {
        issues += 1
        invalid = invalid.union(part)
      } else if let cap = geo.capitol {
        caps.append(cap)
      }
    }
    let path = distances(grid: grid, sizes: sizes, sources: caps)
    var wrong = 0
    var error = 0.0
    var residuals = Array(repeating: 0.0, count: grid.count)
    for c in 0..<grid.count where puzzle.clues[c] >= 0 {
      let t = puzzle.clues[c]
      let actual = path.distances[c]
      if actual != t { wrong += 1 }
      let e = actual >= 1_000_000_000 ? 1 : Double(abs(actual - t)) / Double(max(1, max(actual, t)))
      residuals[c] = e
      error += e
    }
    let mean = error / Double(max(1, puzzle.clueCount))
    let quality = Quality(issues: issues, wrong: wrong, residual: mean)
    let answer: Int? =
      issues == 0 && wrong == 0
      ? (0..<grid.rows).reduce(0) { sum, r in
        let s = sizes[(r * grid.cols)..<((r + 1) * grid.cols)].reduce(0, +)
        return sum + s * s
      } : nil
    return ExactEvaluation(
      labels: labels, sizes: sizes, capitols: caps,
      distances: path.distances.map { $0 >= 1_000_000_000 ? nil : $0 }, parents: path.parents,
      invalid: invalid, quality: quality, residuals: residuals, answer: answer)
  }
}
public struct ExactEvaluation: Codable {
  public let labels: [Int], sizes: [Int], capitols: [Int], distances: [Int?], parents: [Int?],
    invalid: CellMask, quality: Quality, residuals: [Double], answer: Int?
  public var solved: Bool { answer != nil }
  public var commonEnergy: Double {
    (2 * quality.residual + Double(invalid.count) / Double(labels.count)) / 3
  }
}
public struct ShapeTemplate: Codable, Hashable {
  public let key: String, width: Int, height: Int, cells: CellMask, capitol: Int?, symmetries: [Int]
  public static func canonical(_ mask: CellMask, grid: Grid) -> Self {
    let points = mask.cells.map { [$0 / grid.cols, $0 % grid.cols] }
    var options: [(String, Int, Int, CellMask)] = []
    for t in 0..<8 {
      let transformed = points.map { p -> [Int] in
        let r = p[0]
        let c = p[1]
        switch t {
        case 0: return [r, c]
        case 1: return [c, -r]
        case 2: return [-r, -c]
        case 3: return [-c, r]
        case 4: return [r, -c]
        case 5: return [-r, c]
        case 6: return [c, r]
        default: return [-c, -r]
        }
      }
      let minr = transformed.map { $0[0] }.min()!
      let minc = transformed.map { $0[1] }.min()!
      let h = transformed.map { $0[0] }.max()! - minr + 1
      let w = transformed.map { $0[1] }.max()! - minc + 1
      let local = CellMask(cells: transformed.map { ($0[0] - minr) * w + $0[1] - minc })
      let key = String(format: "%02d:%02d:", h, w) + String(local.bits, radix: 16)
      options.append((key, w, h, local))
    }
    let o = options.min { $0.0 < $1.0 }!
    let geo = Rules.geometry(o.3, grid: Grid(rows: o.2, cols: o.1))
    return Self(
      key: o.0, width: o.1, height: o.2, cells: o.3, capitol: geo.capitol,
      symmetries: geo.symmetries)
  }
  public var orientations: [(width: Int, height: Int, cells: [Int])] {
    let points = cells.cells.map { [$0 / width, $0 % width] }
    var seen = Set<String>()
    var out: [(Int, Int, [Int])] = []
    for t in 0..<8 {
      let a = points.map { p -> [Int] in
        let r = p[0]
        let c = p[1]
        switch t {
        case 0: return [r, c]
        case 1: return [c, -r]
        case 2: return [-r, -c]
        case 3: return [-c, r]
        case 4: return [r, -c]
        case 5: return [-r, c]
        case 6: return [c, r]
        default: return [-c, -r]
        }
      }
      let r = a.map { $0[0] }.min()!
      let c = a.map { $0[1] }.min()!
      let h = a.map { $0[0] }.max()! - r + 1
      let w = a.map { $0[1] }.max()! - c + 1
      let v = a.map { ($0[0] - r) * w + $0[1] - c }.sorted()
      let key = "\(w):\(h):\(v)"
      if seen.insert(key).inserted { out.append((w, h, v)) }
    }
    return out
  }
}
