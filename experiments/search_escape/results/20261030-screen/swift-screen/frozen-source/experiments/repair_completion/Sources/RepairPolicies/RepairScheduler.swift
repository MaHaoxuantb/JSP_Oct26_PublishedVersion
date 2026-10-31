import Foundation
import PuzzleRules
import ShapeDomain
import SolverCore

public struct PatchChoice {
  public let mask: CellMask
  public let clue: Int?
  public let route: [Int]
  public let kind: String
}

public enum RouteSelection {
  /// Complete regions along an actual shortest route, under the control's scope limits.
  public static func choose(source: ScoredState, puzzle: Puzzle, limit: Int, large: Bool,
    rng: inout SplitMix) -> PatchChoice {
    // Retain explicit exploration: cheapest current routes may be misleading.
    if rng.unit() < 0.2 {
      return PatchChoice(mask: RegionalPolicy.patch(source: source, puzzle: puzzle,
        regional: true, limit: limit, large: large, rng: &rng), clue: nil, route: [], kind: "neighbor_exploration")
    }
    let bad = puzzle.clues.indices.filter { puzzle.clues[$0] >= 0 && source.exact.residuals[$0] > 0 }
    guard !bad.isEmpty else {
      return PatchChoice(mask: RegionalPolicy.patch(source: source, puzzle: puzzle,
        regional: true, limit: limit, large: large, rng: &rng), clue: nil, route: [], kind: "neighbor_fallback")
    }
    var ticket = rng.unit() * bad.reduce(0.0) { $0 + source.exact.residuals[$1] + 0.05 }
    var clue = bad.last!
    for c in bad { ticket -= source.exact.residuals[c] + 0.05; if ticket <= 0 { clue = c; break } }
    var route: [Int] = [], seen = Set<Int>(), next: Int? = clue
    while let c = next, seen.insert(c).inserted { route.append(c); next = source.exact.parents[c] }
    let parts = groups(source.exact.labels)
    // Same breadth law and region-count allowance as the neighboring control.
    let field = RegionalPolicy.field(source, puzzle: puzzle)
    let seed = route[rng.index(route.count)]
    let breadth = abs(RegionalPolicy.noise(hotness: field[seed], regional: true, rng: &rng))
    let desired = 1 + min((large ? 8 : 4) - 1, Int(breadth * Double(large ? 8 : 4)))
    var ids = Set([source.exact.labels[seed]])
    var patch = parts[source.exact.labels[seed]]
    let routeIDs = Set(route.map { source.exact.labels[$0] })
    while ids.count < desired {
      let adjacent = Set(patch.cells.flatMap { puzzle.grid.neighbors[$0] }.map { source.exact.labels[$0] })
        .subtracting(ids).filter { patch.count + parts[$0].count <= limit }.sorted()
      if adjacent.isEmpty { break }
      let along = adjacent.filter { routeIDs.contains($0) }
      let options = along.isEmpty ? adjacent : along
      let id = options[rng.index(options.count)]
      ids.insert(id); patch = patch.union(parts[id])
    }
    // A single source region can already exceed the target limit, as in the control.
    return PatchChoice(mask: patch, clue: clue, route: route, kind: "clue_route")
  }
}

private final class RepairJob {
  let id: Int, search: CoverSearch, source: ScoredState, choice: PatchChoice
  var slices = 0, wall = 0.0
  var delivered: Quality
  init(id: Int, search: CoverSearch, source: ScoredState, choice: PatchChoice) {
    self.id = id; self.search = search; self.source = source; self.choice = choice
    delivered = source.exact.quality
  }
}

public final class RepairScheduler: SearchIntensifier {
  public let persistent: Bool, routeSelected: Bool, output: String
  private var jobs: [RepairJob] = [], failures = 0, serial = 0, calls = 0, cursor = 0
  private var lastCheckpoint = 0.0
  private let handle: FileHandle
  public private(set) var counters: [String: Int] = [:]
  public init(persistent: Bool, routeSelected: Bool, output: String) throws {
    self.persistent = persistent; self.routeSelected = routeSelected; self.output = output
    FileManager.default.createFile(atPath: output + "/repairs.jsonl", contents: nil)
    handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output + "/repairs.jsonl"))
  }
  deinit { try? handle.close() }
  private func count(_ key: String) { counters[key, default: 0] += 1 }
  private func record(_ values: [String: Any]) throws {
    var v = values; v["updated"] = Date().timeIntervalSince1970
    var d = try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]); d.append(10)
    try handle.write(contentsOf: d)
  }
  private func discard(_ job: RepairJob, reason: String) throws {
    count(reason)
    try record(["event": "discard", "job": job.id, "reason": reason,
      "nodes": job.search.state.counters.nodes, "slices": job.slices, "wallSeconds": job.wall])
    jobs.removeAll { $0 === job }
  }
  private func create(source: ScoredState, input: WorkerInput, oracle: ShapeOracle,
    rng: inout SplitMix, metrics: inout SearchMetrics) throws -> RepairJob? {
    let limits = [16,32,48,64,input.puzzle.n * input.puzzle.n]
    let limit = limits[min(limits.count - 1, failures / 2)]
    let choice: PatchChoice
    if failures >= 8 { choice = PatchChoice(mask: input.puzzle.grid.full, clue: nil, route: [], kind: "full_board") }
    else if routeSelected { choice = RouteSelection.choose(source: source, puzzle: input.puzzle,
      limit: limit, large: failures >= 2, rng: &rng) }
    else { choice = PatchChoice(mask: RegionalPolicy.patch(source: source, puzzle: input.puzzle,
      regional: input.condition.regional, limit: limit, large: failures >= 2, rng: &rng),
      clue: nil, route: [], kind: "neighbor") }
    metrics.patchScreens += 1
    let bound = CoverBounds.evaluate(puzzle: input.puzzle, patch: choice.mask,
      base: source.exact.labels, selected: [], mode: .improve)
    if !(bound.quality < source.exact.quality) {
      metrics.patchRejects += 1; failures += 1; count("bound_rejected")
      try record(["event":"screen", "reason":"bound_rejected", "patchCells":choice.mask.count,
        "kind":choice.kind, "clue":choice.clue as Any? ?? NSNull(), "route":choice.route])
      return nil
    }
    // Reuse only an identical patch and fixed exterior. Each search retains its own source.
    let exterior = Set(groups(source.exact.labels).filter { !$0.intersects(choice.mask) })
    if let old = jobs.first(where: { $0.choice.mask == choice.mask &&
      Set(groups($0.search.state.base).filter { !$0.intersects(choice.mask) }) == exterior }) {
      count("duplicate_scope"); return old
    }
    if jobs.count >= 4 { try discard(jobs[0], reason: "capacity_eviction") }
    serial += 1
    let job = RepairJob(id: serial, search: CoverSearch(puzzle: input.puzzle,
      patch: choice.mask, base: source.exact.labels, mode: .improve, oracle: oracle),
      source: source, choice: choice)
    jobs.append(job); count("created")
    try record(["event":"create", "job":job.id, "kind":choice.kind,
      "patchCells":choice.mask.count, "patch":choice.mask.cells,
      "patchRegions":groups(source.exact.labels).filter { $0.intersects(choice.mask) }.count,
      "sourceLabels":source.exact.labels, "clue":choice.clue as Any? ?? NSNull(), "route":choice.route])
    return job
  }
  public func improve(source: ScoredState, globalBest: ScoredState, input: WorkerInput,
    oracle: ShapeOracle, until: Double, rng: inout SplitMix,
    metrics: inout SearchMetrics) throws -> ScoredState? {
    let began = monotonic(); calls += 1
    for job in jobs.filter({ $0.search.state.finished }) {
      try discard(job, reason: job.search.state.exhausted ? "exhausted" : "solution_found")
    }
    if !persistent, let job = jobs.first {
      let patch = job.choice.mask
      let old = Set(groups(job.search.state.base).filter { !$0.intersects(patch) })
      let current = Set(groups(source.exact.labels).filter { !$0.intersects(patch) })
      if old != current { try discard(job, reason: "exterior_changed") }
      else if source.exact.quality < job.search.state.bestQuality {
        job.search.state.bestQuality = source.exact.quality; job.search.state.bestLabels = source.exact.labels
        job.delivered = source.exact.quality
      }
    }
    var selected: RepairJob?
    if jobs.isEmpty || (persistent && calls % 4 == 0) {
      selected = try create(source: source, input: input, oracle: oracle, rng: &rng, metrics: &metrics)
    }
    if selected == nil, !jobs.isEmpty { selected = jobs[persistent ? cursor % jobs.count : 0]; cursor += 1 }
    guard let job = selected else { return nil }
    if job.slices > 0 { count("resumed") }
    let before = job.search.state.counters
    let genBefore = oracle.metrics.generatorNodes
    let status = job.search.advance(until: until, useBounds: true)
    let spent = monotonic() - began
    job.wall += spent; job.slices += 1
    metrics.bpPhases += 1; metrics.bpSeconds += spent
    metrics.bpNodes += job.search.state.counters.nodes - before.nodes
    let value = StateCodec.evaluate(StateCodec.encode(job.search.state.bestLabels,
      grid: input.puzzle.grid, previous: job.source.state, continuous: false), puzzle: input.puzzle)
    let localImprovement = value.exact.quality < job.delivered
    let globalImprovement = value.exact.quality < globalBest.exact.quality
    let returned = value.exact.quality < source.exact.quality
    if localImprovement { count("source_improvement"); job.delivered = value.exact.quality }
    if globalImprovement { count("global_improvement") }
    if returned { metrics.bpImprovements += 1; count("returned_to_sa"); failures = 0 }
    else { failures += 1 }
    try record(["event":"slice", "job":job.id, "slice":job.slices,
      "status":status, "seconds":spent, "nodes":job.search.state.counters.nodes-before.nodes,
      "generatorNodes":oracle.metrics.generatorNodes-genBefore,
      "distancePrunes":job.search.state.counters.distancePrunes-before.distancePrunes,
      "newLocalImprovement":localImprovement,"improvesOriginalSource":value.exact.quality < job.source.exact.quality,"globalImprovement":globalImprovement,
      "returnedToSA":returned,"wrong":value.exact.quality.wrong,
      "exhausted":job.search.state.exhausted])
    // Factor off reproduces the original improvement/expiry behavior.
    if !persistent && (returned || failures % 2 == 0) {
      try discard(job, reason: returned ? "improvement_restart" : "two_phase_expiry")
    }
    if monotonic() - lastCheckpoint >= 10 {
      lastCheckpoint = monotonic()
      struct Saved: Codable { let id: Int, search: CoverCheckpoint, source: SearchState, slices: Int }
      try writeJSON(jobs.map { Saved(id:$0.id,search:$0.search.state,source:$0.source.state,slices:$0.slices) },
        to: output + "/repair-checkpoint.json")
    }
    try writeJSON(counters, to: output + "/repair-progress.json")
    return returned ? value : nil
  }
}
