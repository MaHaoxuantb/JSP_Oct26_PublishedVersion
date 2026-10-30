import Foundation
import PuzzleRules

public struct OracleMetrics: Codable {
  public var generatorSeconds = 0.0, seedSeconds = 0.0
  public var generatorNodes = 0, generatedShapes = 0, cacheSeeds = 0, queryCount = 0,
    exhaustedQueries = 0
  public init() {}
}
public struct RectangleJob: Codable { public let r: Int, c: Int, h: Int, w: Int, t: Int }
public struct OrbitFrame: Codable {
  public var selected: CellMask, frontier: CellMask, excluded: CellMask, cells: CellMask,
    yielded: Bool
}
public struct ShapeQuery: Codable {
  public let allowed: CellMask, anchor: Int
  public var seedMasks: [CellMask], seedIndex = 0, jobIndex = 0, orbits: [CellMask] = [],
    adjacent: [CellMask] = [], frames: [OrbitFrame] = [], exhausted = false
  public init(allowed: CellMask, anchor: Int, seeds: [CellMask]) {
    self.allowed = allowed
    self.anchor = anchor
    seedMasks = seeds
  }
}
public enum ShapeNext {
  case shape(CellMask)
  case paused, exhausted
}
public final class ShapeOracle {
  public let grid: Grid
  public var metrics = OracleMetrics()
  private var orientationCache: [String: [(width: Int, height: Int, cells: [Int])]] = [:]
  private var placementCache: [Int: [String: [CellMask]]] = [:]
  private var templates: [String: ShapeTemplate], ordered: [ShapeTemplate],
    jobsCache: [String: [RectangleJob]] = [:]
  public init(grid: Grid, templates: [ShapeTemplate]) {
    self.grid = grid
    self.templates = Dictionary(uniqueKeysWithValues: templates.map { ($0.key, $0) })
    ordered = templates.sorted { $0.key < $1.key }
  }
  public func query(allowed: CellMask, anchor: Int, preferred: [CellMask] = []) -> ShapeQuery {
    let began = monotonic()
    defer { metrics.seedSeconds += monotonic() - began }
    metrics.queryCount += 1
    var seen = Set<CellMask>()
    var seeds: [CellMask] = []
    func add(_ mask: CellMask, knownLegal: Bool = false) {
      if mask.contains(anchor) && mask.subset(of: allowed) && seen.insert(mask).inserted
        && (knownLegal || Rules.geometry(mask, grid: grid).legal)
      {
        seeds.append(mask)
      }
    }
    for mask in preferred { add(mask) }
    outer: for template in ordered where template.cells.count <= allowed.count {
      var placements = placementCache[anchor]?[template.key]
      if placements == nil {
        let orientations = orientationCache[template.key] ?? template.orientations
        orientationCache[template.key] = orientations
        var values: [CellMask] = []
        for o in orientations where o.width <= grid.cols && o.height <= grid.rows {
          for p in o.cells {
            let row = anchor / grid.cols - p / o.width
            let col = anchor % grid.cols - p % o.width
            if row < 0 || col < 0 || row + o.height > grid.rows || col + o.width > grid.cols {
              continue
            }
            values.append(
              CellMask(cells: o.cells.map { (row + $0 / o.width) * grid.cols + col + $0 % o.width })
            )
          }
        }
        placementCache[anchor, default: [:]][template.key] = values
        placements = values
      }
      for mask in placements! where mask.subset(of: allowed) {
        add(mask, knownLegal: true)
        if seeds.count >= 256 { break outer }
      }
    }
    metrics.cacheSeeds += seeds.count
    return ShapeQuery(allowed: allowed, anchor: anchor, seeds: seeds)
  }
  public func register(_ mask: CellMask) {
    guard templates.count < 4096 else { return }
    let t = ShapeTemplate.canonical(mask, grid: grid)
    if templates[t.key] == nil {
      templates[t.key] = t
      ordered.append(t)
    }
  }
  private func jobs(_ query: ShapeQuery) -> [RectangleJob] {
    let key = "\(query.allowed.bits):\(query.anchor)"
    if let cached = jobsCache[key] { return cached }
    let ar = query.anchor / grid.cols
    let ac = query.anchor % grid.cols
    let cells = query.allowed.cells
    let minr = cells.map { $0 / grid.cols }.min()!
    let maxr = cells.map { $0 / grid.cols }.max()!
    let minc = cells.map { $0 % grid.cols }.min()!
    let maxc = cells.map { $0 % grid.cols }.max()!
    var out: [RectangleJob] = []
    for top in minr...ar {
      for bottom in ar...maxr {
        for left in minc...ac {
          for right in ac...maxc {
            let h = bottom - top + 1
            let w = right - left + 1
            for t in [2, 4, 5] + (h == w ? [6, 7] : []) {
              out.append(RectangleJob(r: top, c: left, h: h, w: w, t: t))
            }
          }
        }
      }
    }
    out.sort { a, b in
      if a.h * a.w != b.h * b.w { return a.h * a.w < b.h * b.w }
      if a.r != b.r { return a.r < b.r }
      if a.c != b.c { return a.c < b.c }
      if a.h != b.h { return a.h < b.h }
      if a.w != b.w { return a.w < b.w }
      return a.t < b.t
    }
    if jobsCache.count >= 64 { jobsCache.removeAll(keepingCapacity: true) }
    jobsCache[key] = out
    return out
  }
  private func start(_ j: RectangleJob, query: inout ShapeQuery) {
    var seen = CellMask()
    var orbits: [CellMask] = []
    var owner = Array(repeating: -1, count: grid.count)
    for y in 0..<j.h {
      for x in 0..<j.w {
        let c = (j.r + y) * grid.cols + j.c + x
        if seen.contains(c) { continue }
        var a = y
        var b = x
        var orbit = CellMask()
        repeat {
          orbit.insert((j.r + a) * grid.cols + j.c + b)
          switch j.t {
          case 2: (a, b) = (j.h - 1 - a, j.w - 1 - b)
          case 4: b = j.w - 1 - b
          case 5: a = j.h - 1 - a
          case 6: (a, b) = (b, a)
          default: (a, b) = (j.h - 1 - b, j.w - 1 - a)
          }
        } while a != y || b != x
        seen = seen.union(orbit)
        if orbit.subset(of: query.allowed) {
          let id = orbits.count
          orbits.append(orbit)
          for v in orbit.cells { owner[v] = id }
        }
      }
    }
    guard owner[query.anchor] >= 0 else {
      query.frames = []
      return
    }
    var adjacency = Array(repeating: CellMask(), count: orbits.count)
    for i in orbits.indices {
      for c in orbits[i].cells {
        for v in grid.neighbors[c] where owner[v] >= 0 && owner[v] != i {
          adjacency[i].insert(owner[v])
        }
      }
    }
    let root = owner[query.anchor]
    query.orbits = orbits
    query.adjacent = adjacency
    query.frames = [
      OrbitFrame(
        selected: CellMask(cells: [root]), frontier: adjacency[root], excluded: CellMask(),
        cells: orbits[root], yielded: false)
    ]
  }
  public func next(_ query: inout ShapeQuery, until: Double) -> ShapeNext {
    let began = monotonic()
    defer { metrics.generatorSeconds += monotonic() - began }
    if query.exhausted { return .exhausted }
    if query.seedIndex < query.seedMasks.count {
      let mask = query.seedMasks[query.seedIndex]
      query.seedIndex += 1
      return .shape(mask)
    }
    let allJobs = jobs(query)
    while query.jobIndex < allJobs.count {
      if monotonic() >= until { return .paused }
      let job = allJobs[query.jobIndex]
      if query.frames.isEmpty {
        start(job, query: &query)
        if query.frames.isEmpty {
          query.jobIndex += 1
          continue
        }
      }
      while !query.frames.isEmpty {
        metrics.generatorNodes += 1
        if metrics.generatorNodes & 31 == 0 && monotonic() >= until { return .paused }
        let i = query.frames.count - 1
        if !query.frames[i].yielded {
          query.frames[i].yielded = true
          let mask = query.frames[i].cells
          let cells = mask.cells
          if cells.map({ $0 / grid.cols }).min() == job.r
            && cells.map({ $0 / grid.cols }).max() == job.r + job.h - 1
            && cells.map({ $0 % grid.cols }).min() == job.c
            && cells.map({ $0 % grid.cols }).max() == job.c + job.w - 1
          {
            let geometry = Rules.geometry(mask, grid: grid)
            let first = Rules.generationTransforms.first { geometry.symmetries.contains($0) }
            if geometry.legal && first == job.t && !query.seedMasks.contains(mask) {
              metrics.generatedShapes += 1
              register(mask)
              return .shape(mask)
            }
          }
        }
        if let v = query.frames[i].frontier.first {
          query.frames[i].frontier.remove(v)
          query.frames[i].excluded.insert(v)
          let selected = query.frames[i].selected.union(CellMask(cells: [v]))
          let frontier = query.frames[i].frontier.union(query.adjacent[v]).subtracting(
            selected.union(query.frames[i].excluded))
          query.frames.append(
            OrbitFrame(
              selected: selected, frontier: frontier, excluded: query.frames[i].excluded,
              cells: query.frames[i].cells.union(query.orbits[v]), yielded: false))
        } else {
          query.frames.removeLast()
        }
      }
      query.jobIndex += 1
    }
    query.exhausted = true
    metrics.exhaustedQueries += 1
    return .exhausted
  }
}
