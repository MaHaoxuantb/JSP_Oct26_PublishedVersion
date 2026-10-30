import Foundation
import PuzzleRules
import ShapeDomain

public final class SearchEngine {
  public let input: WorkerInput
  public var metrics = SearchMetrics()
  private var streams: Streams, temperature = Temperature()
  private var oracle: ShapeOracle!
  private var pendingBP: CoverSearch?, pendingBase: [Int] = [], bpFailures = 0
  private var lastProgress = 0.0, lastBest = 0.0, lastBP = 0.0, started = 0.0, cpuStart = 0.0
  private var handle: FileHandle?
  public init(input: WorkerInput) {
    self.input = input
    streams = Streams(seed: input.seed)
  }
  public func initialLabels() -> [Int] {
    let puzzle = input.puzzle
    let grid = puzzle.grid
    var labels = Array(0..<grid.count)
    if grid.count == 1 { return labels }
    for _ in 0..<(grid.count * 5) {
      let c = streams.initialization.index(grid.count)
      let v = grid.neighbors[c][streams.initialization.index(grid.neighbors[c].count)]
      let a = labels[c]
      let b = labels[v]
      if a == b { continue }
      let part = CellMask(cells: labels.indices.filter { labels[$0] == a || labels[$0] == b })
      let geo = Rules.geometry(part, grid: grid)
      if geo.legal && part.cells.allSatisfy({ puzzle.clues[$0] != 0 || geo.capitol == $0 }) {
        for x in part.cells { labels[x] = a }
      }
    }
    return normalized(labels)
  }
  private func propose(_ source: ScoredState, until: Double) -> ScoredState? {
    let puzzle = input.puzzle
    let grid = puzzle.grid
    let parts = groups(source.exact.labels)
    let continuous = input.condition.representation == "continuous"
    let ticket = streams.proposal.unit()
    let field = RegionalPolicy.field(source, puzzle: puzzle)
    let focus = RegionalPolicy.focus(
      field, regional: input.condition.regional, rng: &streams.regional)
    if ticket < 0.05 {
      let edges = StateCodec.edges(grid)
      let eligible = edges.indices.filter { edges[$0].0 == focus || edges[$0].1 == focus }
      let edge = eligible[streams.proposal.index(eligible.count)]
      let z = RegionalPolicy.noise(
        hotness: field[focus], regional: input.condition.regional, rng: &streams.regional)
      var values = source.state.strengths
      if continuous {
        var p = (values[edge] + z).truncatingRemainder(dividingBy: 2)
        if p < 0 { p += 2 }
        values[edge] = p <= 1 ? p : 2 - p
      } else {
        values[edge] = z >= 0 ? 1 : 0
      }
      if values == source.state.strengths { return nil }
      return StateCodec.evaluate(SearchState(strengths: values), puzzle: puzzle)
    }
    if ticket < 0.35 {
      let id = source.exact.labels[focus]
      let frontier = Set(
        parts[id].cells.flatMap { grid.neighbors[$0] }.map { source.exact.labels[$0] }
      ).subtracting([id]).sorted()
      guard !frontier.isEmpty else { return nil }
      var chosen = parts[id]
      var best: ScoredState? = nil
      for other in frontier.prefix(4) {
        var labels = source.exact.labels
        let merged = chosen.union(parts[other])
        if Rules.geometry(merged, grid: grid).legal {
          for c in merged.cells { labels[c] = id }
          let scored = StateCodec.evaluate(
            StateCodec.encode(labels, grid: grid, previous: source.state, continuous: continuous),
            puzzle: puzzle)
          if best == nil || scored.nativeEnergy < best!.nativeEnergy { best = scored }
        }
        if streams.proposal.unit() < 0.5 { chosen = merged }
      }
      return best
    }
    if ticket < 0.60 {
      let adjacent = grid.neighbors[focus]
      let v = adjacent[streams.proposal.index(adjacent.count)]
      let a = source.exact.labels[focus]
      let b = source.exact.labels[v]
      var labels = source.exact.labels
      if a != b {
        let donor = parts[a].subtracting(CellMask(cells: [focus]))
        let recipient = parts[b].union(CellMask(cells: [focus]))
        if (!donor.isEmpty && !Rules.geometry(donor, grid: grid).legal)
          || !Rules.geometry(recipient, grid: grid).legal
        {
          return nil
        }
        labels[focus] = b
      } else {
        guard parts[a].count > 1 else { return nil }
        let horizontal = streams.proposal.unit() < 0.5
        let coordinate = horizontal ? focus / grid.cols : focus % grid.cols
        let split = CellMask(
          cells: parts[a].cells.filter {
            horizontal ? $0 / grid.cols <= coordinate : $0 % grid.cols <= coordinate
          })
        let rest = parts[a].subtracting(split)
        if split.isEmpty || rest.isEmpty || !Rules.geometry(split, grid: grid).legal
          || !Rules.geometry(rest, grid: grid).legal
        {
          return nil
        }
        let newID = (labels.max() ?? 0) + 1
        for c in split.cells { labels[c] = newID }
      }
      return StateCodec.evaluate(
        StateCodec.encode(labels, grid: grid, previous: source.state, continuous: continuous),
        puzzle: puzzle)
    }
    let large = metrics.iterations % 12 == 0
    let patch = RegionalPolicy.patch(
      source: source, puzzle: puzzle, regional: input.condition.regional,
      limit: large ? grid.count : 32, large: large, rng: &streams.regional)
    if patch.isEmpty { return nil }
    let t = monotonic()
    let search = CoverSearch(
      puzzle: puzzle, patch: patch, base: source.exact.labels, mode: .improve, oracle: oracle)
    metrics.catalogSeconds += monotonic() - t
    _ = search.advance(
      until: min(until, monotonic() + 0.15), nodeLimit: 5000, coverLimit: 48, useBounds: false)
    metrics.coverSeconds += monotonic() - t
    metrics.basicCoverNodes += search.state.counters.nodes
    let labels =
      search.state.bestQuality < source.exact.quality
      ? search.state.bestLabels : search.state.lastLabels
    guard let candidate = labels, candidate != source.exact.labels else { return nil }
    return StateCodec.evaluate(
      StateCodec.encode(candidate, grid: grid, previous: source.state, continuous: continuous),
      puzzle: puzzle)
  }
  private func intensify(_ source: ScoredState, until: Double) -> ScoredState? {
    let t = monotonic()
    let limits = [16, 32, 48, 64, input.puzzle.n * input.puzzle.n]
    let limit = limits[min(limits.count - 1, bpFailures / 2)]
    if let pending = pendingBP {
      let patch = pending.state.patch
      let previous = Set(groups(pendingBase).filter { !$0.intersects(patch) })
      let current = Set(groups(source.exact.labels).filter { !$0.intersects(patch) })
      if previous != current || pending.state.finished {
        pendingBP = nil
      } else if source.exact.quality < pending.state.bestQuality {
        pending.state.bestQuality = source.exact.quality
        pending.state.bestLabels = source.exact.labels
      }
    }
    if pendingBP == nil {
      let patch =
        bpFailures >= 8
        ? input.puzzle.grid.full
        : RegionalPolicy.patch(
          source: source, puzzle: input.puzzle, regional: input.condition.regional, limit: limit,
          large: bpFailures >= 2, rng: &streams.bp)
      metrics.patchScreens += 1
      let bound = CoverBounds.evaluate(
        puzzle: input.puzzle, patch: patch, base: source.exact.labels, selected: [], mode: .improve)
      if !(bound.quality < source.exact.quality) {
        metrics.patchRejects += 1
        bpFailures += 1
        return nil
      }
      pendingBP = CoverSearch(
        puzzle: input.puzzle, patch: patch, base: source.exact.labels, mode: .improve,
        oracle: oracle)
      pendingBase = source.exact.labels
    }
    let search = pendingBP!
    let before = search.state.counters.nodes
    _ = search.advance(until: until, useBounds: true)
    metrics.bpNodes += search.state.counters.nodes - before
    metrics.bpPhases += 1
    metrics.bpSeconds += monotonic() - t
    if search.state.bestQuality < source.exact.quality {
      metrics.bpImprovements += 1
      bpFailures = 0
      let value = StateCodec.evaluate(
        StateCodec.encode(
          search.state.bestLabels, grid: input.puzzle.grid, previous: source.state,
          continuous: input.condition.representation == "continuous"), puzzle: input.puzzle)
      pendingBP = nil
      return value
    }
    bpFailures += 1
    // Resume an unchanged exterior for at most two phases before varying scope.
    if bpFailures % 2 == 0 { pendingBP = nil }
    return nil
  }
  private func observe(_ best: ScoredState, phase: String, force: Bool = false) throws {
    let now = monotonic()
    if !force && now - lastProgress < 1 { return }
    lastProgress = now
    metrics.catalogSeconds = oracle.metrics.generatorSeconds + oracle.metrics.seedSeconds
    let usage = ResourceUse.usage()
    let elapsed = now - started
    let cpu = usage.cpu - cpuStart
    let sample = Observation(
      jobID: input.jobID, seconds: elapsed, cpuSeconds: cpu, cpuRatio: cpu / max(0.001, elapsed),
      phase: phase, quality: best.exact.quality, commonEnergy: best.exact.commonEnergy,
      nativeEnergy: best.nativeEnergy, discreteness: best.discreteness, metrics: metrics,
      oracle: oracle.metrics, memoryBytes: usage.memory, updated: Date().timeIntervalSince1970)
    let encoder = JSONEncoder()
    var data = try encoder.encode(sample)
    data.append(10)
    try handle?.write(contentsOf: data)
    try writeJSON(sample, to: input.output + "/progress.json")
    struct Checkpoint: Codable {
      let labels: [Int], strengths: [Double], streams: Streams, metrics: SearchMetrics,
        seconds: Double
    }
    try writeJSON(
      Checkpoint(
        labels: best.exact.labels, strengths: best.state.strengths, streams: streams,
        metrics: metrics, seconds: elapsed), to: input.output + "/checkpoint.json")
  }
  public func run() throws -> WorkerResult {
    ResourceUse.performanceQoS()
    started = monotonic()
    cpuStart = ResourceUse.usage().cpu
    let until = started + input.budgetSeconds
    guard ["discrete", "continuous"].contains(input.condition.representation),
      input.budgetSeconds > 0, input.budgetSeconds <= 1200
    else { throw BenchError("Invalid benchmark condition or budget") }
    let templates = try ShapeStore.read(input.shapeStore)
    oracle = ShapeOracle(grid: input.puzzle.grid, templates: templates)
    let log = input.output + "/events.jsonl"
    FileManager.default.createFile(atPath: log, contents: nil)
    handle = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
    defer { try? handle?.close() }
    var current = StateCodec.evaluate(
      StateCodec.encode(
        initialLabels(), grid: input.puzzle.grid, previous: nil,
        continuous: input.condition.representation == "continuous"), puzzle: input.puzzle)
    var best = current
    lastBest = started
    lastBP = started
    var stagnation = 0
    var epoch = 0
    try observe(best, phase: "sa", force: true)
    while monotonic() < until && !best.exact.solved {
      let now = monotonic()
      if input.condition.newBP && now - lastBest >= 5 && now - lastBP >= 4 {
        let source = metrics.bpPhases % 4 == 3 ? current : best
        if let improved = intensify(source, until: min(until, now + 1)) {
          if improved.exact.quality < best.exact.quality {
            best = improved
            lastBest = monotonic()
          }
          current = improved
          temperature.reheat()
        }
        lastBP = monotonic()
        try observe(best, phase: "new_bp")
        continue
      }
      metrics.iterations += 1
      if let proposal = propose(current, until: until) {
        let delta = proposal.nativeEnergy - current.nativeEnergy
        if proposal.exact.solved || delta <= 0
          || streams.acceptance.unit() < exp(-delta / temperature.value)
        {
          current = proposal
          metrics.accepted += 1
        }
        if proposal.exact.quality < best.exact.quality {
          best = proposal
          lastBest = monotonic()
          stagnation = 0
        }
        temperature.step(delta)
      } else {
        metrics.noProposal += 1
        temperature.step(nil)
      }
      stagnation += 1
      if stagnation >= 100 {
        temperature.reheat()
        metrics.reheats += 1
        stagnation = 0
        epoch += 1
        if epoch % 2 == 0 {
          current = StateCodec.evaluate(
            StateCodec.encode(
              initialLabels(), grid: input.puzzle.grid, previous: nil,
              continuous: input.condition.representation == "continuous"), puzzle: input.puzzle)
          metrics.restarts += 1
          if current.exact.quality < best.exact.quality {
            best = current
            lastBest = monotonic()
          }
        }
      }
      try observe(best, phase: "sa")
    }
    try observe(best, phase: best.exact.solved ? "solved" : "time_limit", force: true)
    let elapsed = monotonic() - started
    let cpu = ResourceUse.usage().cpu - cpuStart
    let n = input.puzzle.n
    return WorkerResult(
      version: benchmarkVersion, jobID: input.jobID, puzzleID: input.puzzle.id,
      condition: input.condition, seed: input.seed, seconds: elapsed, cpuSeconds: cpu,
      solved: best.exact.solved, reason: best.exact.solved ? "solved" : "time_limit",
      labels: (0..<n).map { Array(best.exact.labels[($0 * n)..<(($0 + 1) * n)]) },
      strengths: best.state.strengths, quality: best.exact.quality, answer: best.exact.answer,
      metrics: metrics, oracle: oracle.metrics, singleThreaded: true, gpuEnabled: false)
  }
}
