import XCTest

@testable import BoardPreparation
@testable import PuzzleRules
@testable import ShapeDomain
@testable import SolverCore

final class RulesTests: XCTestCase {
  func testGeometry() {
    let g = Grid(rows: 5, cols: 5)
    XCTAssertTrue(Rules.geometry(CellMask(cells: [0]), grid: g).capitol == 0)
    XCTAssertTrue(Rules.geometry(CellMask(cells: [0, 1, 2]), grid: g).legal)
    XCTAssertNil(Rules.geometry(CellMask(cells: [0, 1, 2]), grid: g).capitol)
    XCTAssertNil(Rules.geometry(CellMask(cells: [7, 11, 12, 13, 17]), grid: g).capitol)
    XCTAssertFalse(Rules.geometry(CellMask(cells: [0, 2]), grid: g).legal)
  }
  func testMasksAndRoundTrip() throws {
    for n in [8, 9, 11] {
      let g = Grid(rows: n, cols: n)
      XCTAssertEqual(g.full.count, n * n)
      let a = CellMask(cells: [0, 63, n * n - 1])
      let b = try JSONDecoder().decode(CellMask.self, from: JSONEncoder().encode(a))
      XCTAssertEqual(a, b)
      XCTAssertTrue(b.contains(n * n - 1))
    }
  }
  func testKnownExample() {
    let rows = ["ABBCC", "ABBDC", "AADDC", "CAAAC", "CCCCC"]
    let labels = rows.flatMap { $0.utf8.map(Int.init) }
    let clues = [
      12, -1, -1, -1, 17, 8, -1, 6, 3, -1, -1, -1, -1, -1, -1, -1, 7, 6, -1, 10, 25, -1, -1, -1, 0,
    ]
    let v = Rules.evaluate(labels, puzzle: Puzzle(id: "example", n: 5, clues: clues))
    XCTAssertTrue(v.solved)
    XCTAssertEqual(v.answer, 8045)
  }
  func testOracleExhaustiveAndNoCacheNeeded() {
    for n in [2, 3] {
      let grid = Grid(rows: n, cols: n)
      let oracle = ShapeOracle(grid: grid, templates: [])
      for anchor in 0..<grid.count {
        var q = oracle.query(allowed: grid.full, anchor: anchor)
        var found = Set<CellMask>()
        var duplicates = 0
        while true {
          switch oracle.next(&q, until: monotonic() + 60) {
          case .shape(let mask): if !found.insert(mask).inserted { duplicates += 1 }
          case .paused:
            XCTFail("Small domain timed out")
            return
          case .exhausted: break
          }
          if q.exhausted { break }
        }
        var expected = Set<CellMask>()
        for raw in UInt128(1)..<(UInt128(1) << grid.count) {
          let mask = CellMask(raw)
          if mask.contains(anchor) && Rules.geometry(mask, grid: grid).legal {
            expected.insert(mask)
          }
        }
        XCTAssertEqual(found, expected, "n=\(n),anchor=\(anchor)")
        XCTAssertEqual(duplicates, 0)
      }
    }
  }
  func testQueryCheckpoint() throws {
    let grid = Grid(rows: 3, cols: 3)
    let oracle = ShapeOracle(grid: grid, templates: [])
    var q = oracle.query(allowed: grid.full, anchor: 4)
    var collected = Set<CellMask>()
    for _ in 0..<5 {
      if case .shape(let mask) = oracle.next(&q, until: monotonic() + 20) { collected.insert(mask) }
    }
    q = try JSONDecoder().decode(ShapeQuery.self, from: JSONEncoder().encode(q))
    let resumed = ShapeOracle(grid: grid, templates: [])
    while !q.exhausted {
      if case .shape(let mask) = resumed.next(&q, until: monotonic() + 20) {
        XCTAssertFalse(collected.contains(mask))
        collected.insert(mask)
      }
    }
    let expected = (UInt128(1)..<(UInt128(1) << 9)).map { CellMask($0) }.filter {
      $0.contains(4) && Rules.geometry($0, grid: grid).legal
    }
    XCTAssertEqual(collected, Set(expected))
  }
  func testBinaryRepresentationEqualityAndCommonInitialization() {
    let p = Puzzle(id: "x", n: 3, clues: [0, -1, 2, -1, -1, -1, 2, -1, -1])
    let labels = [0, 1, 1, 2, 3, 3, 2, 3, 3]
    let discrete = StateCodec.encode(labels, grid: p.grid, previous: nil, continuous: false)
    let continuous = StateCodec.encode(labels, grid: p.grid, previous: nil, continuous: true)
    XCTAssertEqual(discrete.strengths, continuous.strengths)
    XCTAssertEqual(
      StateCodec.evaluate(discrete, puzzle: p).nativeEnergy,
      StateCodec.evaluate(continuous, puzzle: p).nativeEnergy)
    var first: [Int]? = nil
    for rep in ["discrete", "continuous"] {
      for regional in [false, true] {
        for bp in [false, true] {
          let c = Condition(representation: rep, regional: regional, newBP: bp)
          let i = WorkerInput(
            jobID: "test", puzzle: p, condition: c, seed: 42, budgetSeconds: 1, shapeStore: "",
            output: "")
          let labels = SearchEngine(input: i).initialLabels()
          if let a = first { XCTAssertEqual(a, labels) } else { first = labels }
        }
      }
    }
  }
  func testNoise() {
    var r = SplitMix(seed: 1)
    var squares = [0.0, 0.0]
    for _ in 0..<20000 {
      for j in 0..<2 {
        let z = RegionalPolicy.noise(hotness: Double(j), regional: true, rng: &r)
        XCTAssertLessThanOrEqual(abs(z), 1)
        squares[j] += z * z
      }
    }
    XCTAssertEqual(squares[0] / 20000, 1.0 / 48, accuracy: 0.002)
    XCTAssertEqual(squares[1] / 20000, 1.0 / 3, accuracy: 0.015)
  }
  func testCountsAndPruningEquivalence() throws {
    for seed in 1...3 {
      let n = 3
      let witness = BoardMaker.make(n: n, seed: UInt64(seed))
      let blank = Puzzle(id: "blank", n: n, clues: Array(repeating: -1, count: 9))
      let d = Rules.evaluate(witness, puzzle: blank).distances
      let puzzle = Puzzle(id: "p", n: n, clues: (0..<9).map { $0 % 3 == 0 ? (d[$0] ?? 0) : -1 })
      var results: [Set<[Int]>] = []
      for bound in [false, true] {
        let search = CoverSearch(
          puzzle: puzzle, patch: puzzle.grid.full, base: Array(0..<9), mode: .certify,
          oracle: ShapeOracle(grid: puzzle.grid, templates: []))
        _ = search.advance(until: monotonic() + 60, useBounds: bound, maxSolutions: 100000)
        XCTAssertTrue(search.state.exhausted)
        results.append(Set(search.state.solutions))
      }
      XCTAssertEqual(results[0], results[1])
      XCTAssertTrue(results[1].contains(normalized(witness)))
    }
  }
  func testUniqueAndFourthSolution() {
    let zeros = Puzzle(id: "unique", n: 2, clues: [0, 0, 0, 0])
    let unique = CoverSearch(
      puzzle: zeros, patch: zeros.grid.full, base: [0, 1, 2, 3], mode: .certify,
      oracle: ShapeOracle(grid: zeros.grid, templates: []))
    _ = unique.advance(until: monotonic() + 10)
    XCTAssertTrue(unique.state.exhausted)
    XCTAssertEqual(unique.state.solutions.count, 1)
    let blank = Puzzle(id: "many", n: 3, clues: Array(repeating: -1, count: 9))
    let many = CoverSearch(
      puzzle: blank, patch: blank.grid.full, base: Array(0..<9), mode: .certify,
      oracle: ShapeOracle(grid: blank.grid, templates: []))
    _ = many.advance(until: monotonic() + 10)
    XCTAssertFalse(many.state.exhausted)
    XCTAssertEqual(many.state.solutions.count, 4)
  }
  func testRestrictedFourByFourOracle() {
    let grid = Grid(rows: 4, cols: 4)
    for allowed in [grid.full, grid.full.subtracting(CellMask(cells: [0, 6, 15]))] {
      for anchor in [1, 5, 10] where allowed.contains(anchor) {
        let oracle = ShapeOracle(grid: grid, templates: [])
        var q = oracle.query(allowed: allowed, anchor: anchor)
        var found = Set<CellMask>()
        while !q.exhausted {
          if case .shape(let mask) = oracle.next(&q, until: monotonic() + 60) {
            XCTAssertTrue(found.insert(mask).inserted)
          }
        }
        var expected = Set<CellMask>()
        for raw in UInt128(1)..<(UInt128(1) << 16) {
          let mask = CellMask(raw)
          if mask.contains(anchor) && mask.subset(of: allowed)
            && Rules.geometry(mask, grid: grid).legal
          {
            expected.insert(mask)
          }
        }
        XCTAssertEqual(found, expected)
      }
    }
  }
  func testCoverCheckpointAndFrozenCache() throws {
    let p = Puzzle(id: "checkpoint", n: 3, clues: [0, -1, -1, -1, -1, -1, -1, -1, 2])
    let oracle = ShapeOracle(grid: Grid(rows: 3, cols: 3), templates: [])
    var search = CoverSearch(
      puzzle: p, patch: p.grid.full, base: Array(0..<9), mode: .certify, oracle: oracle)
    for _ in 0..<8 {
      _ = search.advance(until: monotonic() + 10, nodeLimit: 1, maxSolutions: 100000)
      search = CoverSearch(
        state: try JSONDecoder().decode(
          CoverCheckpoint.self, from: JSONEncoder().encode(search.state)),
        oracle: ShapeOracle(grid: p.grid, templates: []))
    }
    _ = search.advance(until: monotonic() + 60, maxSolutions: 100000)
    XCTAssertTrue(search.state.exhausted)
    let whole = CoverSearch(
      puzzle: p, patch: p.grid.full, base: Array(0..<9), mode: .certify, oracle: oracle)
    _ = whole.advance(until: monotonic() + 60, maxSolutions: 100000)
    XCTAssertEqual(Set(search.state.solutions), Set(whole.state.solutions))
    let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let templates = [ShapeTemplate.canonical(CellMask(cells: [0, 1, 3]), grid: p.grid)]
    try ShapeStore.create(
      path, templates: templates, manifest: ShapeManifest(maxDimension: 9, templateCount: 1))
    let frozen = try Data(contentsOf: URL(fileURLWithPath: path))
    let a = ShapeOracle(grid: p.grid, templates: try ShapeStore.read(path))
    a.register(p.grid.full)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), frozen)
    XCTAssertEqual(try ShapeStore.read(path).count, 1)
    XCTAssertThrowsError(
      try ShapeStore.create(
        path, templates: [], manifest: ShapeManifest(maxDimension: 9, templateCount: 0)))
  }

  func testSeededOracleDomainAndDuplicateSuppression() {
    let grid = Grid(rows: 3, cols: 3)
    let all = (UInt128(1)..<(UInt128(1) << 9)).map { CellMask($0) }.filter {
      Rules.geometry($0, grid: grid).legal
    }
    let templates = Array(Set(all.map { ShapeTemplate.canonical($0, grid: grid) }))
    let oracle = ShapeOracle(grid: grid, templates: templates)
    for allowed in [grid.full, grid.full.subtracting(CellMask(cells: [1, 7]))] {
      var query = oracle.query(
        allowed: allowed, anchor: 4, preferred: [grid.full, grid.full, CellMask(cells: [0, 4])])
      var found = Set<CellMask>()
      while !query.exhausted {
        if case .shape(let mask) = oracle.next(&query, until: monotonic() + 30) {
          XCTAssertTrue(found.insert(mask).inserted)
        }
      }
      XCTAssertEqual(found, Set(all.filter { $0.contains(4) && $0.subset(of: allowed) }))
    }
  }

}
