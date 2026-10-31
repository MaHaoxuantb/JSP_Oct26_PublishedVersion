import CSQLite
import Foundation
import PuzzleRules

public let generatorVersion = "orbit-connected-subsets-v1"
public struct ShapeManifest: Codable {
  public let rules: String, generator: String, domain: String, maxDimension: Int,
    materializedBoundingArea: Int, templateCount: Int
  public init(maxDimension: Int, templateCount: Int) {
    rules = rulesVersion
    generator = generatorVersion
    domain = "exact_procedural"
    self.maxDimension = maxDimension
    materializedBoundingArea = 16
    self.templateCount = templateCount
  }
}
public enum ShapeStore {
  public static func read(_ path: String) throws -> [ShapeTemplate] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      throw BenchError("Cannot open frozen shape store")
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, "SELECT json FROM shapes ORDER BY key", -1, &statement, nil)
        == SQLITE_OK
    else { throw BenchError("Invalid shape store") }
    defer { sqlite3_finalize(statement) }
    var out: [ShapeTemplate] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let s = String(cString: sqlite3_column_text(statement, 0))
      out.append(try JSONDecoder().decode(ShapeTemplate.self, from: Data(s.utf8)))
    }
    return out
  }
  public static func create(_ path: String, templates: [ShapeTemplate], manifest: ShapeManifest)
    throws
  {
    guard !FileManager.default.fileExists(atPath: path) else {
      throw BenchError("Refusing to overwrite a shape database")
    }
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else {
      throw BenchError("Cannot create shape database")
    }
    defer { sqlite3_close(db) }
    guard
      sqlite3_exec(
        db,
        "PRAGMA journal_mode=DELETE; CREATE TABLE shapes(key TEXT PRIMARY KEY,json TEXT NOT NULL); CREATE TABLE metadata(json TEXT NOT NULL); BEGIN IMMEDIATE;",
        nil, nil, nil) == SQLITE_OK
    else { throw BenchError("Shape schema failure") }
    func insert(_ sql: String, _ fields: [String]) throws {
      var s: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else {
        throw BenchError("Shape statement failure")
      }
      defer { sqlite3_finalize(s) }
      for (i, v) in fields.enumerated() {
        _ = v.withCString {
          sqlite3_bind_text(
            s, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
      }
      guard sqlite3_step(s) == SQLITE_DONE else { throw BenchError("Shape insert failure") }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for t in templates.sorted(by: { $0.key < $1.key }) {
      try insert(
        "INSERT INTO shapes VALUES(?,?)",
        [t.key, String(decoding: try encoder.encode(t), as: UTF8.self)])
    }
    try insert(
      "INSERT INTO metadata VALUES(?)",
      [String(decoding: try encoder.encode(manifest), as: UTF8.self)])
    guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
      throw BenchError("Shape commit failure")
    }
  }
  public static func precompute(maxDimension: Int, progress: String?) throws -> [ShapeTemplate] {
    let jobs = (1...maxDimension).flatMap { h in
      (1...maxDimension).filter { h * $0 <= 16 }.map { (h, $0) }
    }
    let total = jobs.reduce(UInt64(0)) { $0 + (UInt64(1) << ($1.0 * $1.1)) - 1 }
    var processed: UInt64 = 0
    var templates: [String: ShapeTemplate] = [:]
    var last = monotonic()
    struct Progress: Codable {
      let phase: String, processed: UInt64, total: UInt64, cachedShapes: Int
      let updated: Double
    }
    for (h, w) in jobs {
      let grid = Grid(rows: h, cols: w)
      for raw in UInt128(1)..<(UInt128(1) << (h * w)) {
        processed += 1
        let mask = CellMask(raw)
        let cells = mask.cells
        if cells.map({ $0 / w }).min() == 0 && cells.map({ $0 / w }).max() == h - 1
          && cells.map({ $0 % w }).min() == 0 && cells.map({ $0 % w }).max() == w - 1
          && Rules.geometry(mask, grid: grid).legal
        {
          let t = ShapeTemplate.canonical(mask, grid: grid)
          templates[t.key] = t
        }
        if let path = progress, monotonic() - last > 0.5 {
          try writeJSON(
            Progress(
              phase: "shape_cache", processed: processed, total: total,
              cachedShapes: templates.count, updated: Date().timeIntervalSince1970), to: path)
          last = monotonic()
        }
      }
    }
    if let path = progress {
      try writeJSON(
        Progress(
          phase: "shape_cache_complete", processed: processed, total: total,
          cachedShapes: templates.count, updated: Date().timeIntervalSince1970), to: path)
    }
    return templates.values.sorted { $0.key < $1.key }
  }
}
