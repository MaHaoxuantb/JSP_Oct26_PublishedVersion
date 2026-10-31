import Foundation

public let rulesVersion = "symmetric-capitol-integer-paths-v1"
public func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }
public struct CellMask: Hashable, Codable, Comparable {
  public var bits: UInt128
  public init(_ bits: UInt128 = 0) { self.bits = bits }
  public init(cells: [Int]) {
    bits = 0
    for c in cells { bits |= UInt128(1) << c }
  }
  public var count: Int { bits.nonzeroBitCount }
  public var isEmpty: Bool { bits == 0 }
  public var first: Int? { bits == 0 ? nil : bits.trailingZeroBitCount }
  public var cells: [Int] {
    var x = bits
    var out: [Int] = []
    while x != 0 {
      out.append(x.trailingZeroBitCount)
      x &= x - 1
    }
    return out
  }
  public func contains(_ c: Int) -> Bool { bits & (UInt128(1) << c) != 0 }
  public func intersects(_ b: Self) -> Bool { bits & b.bits != 0 }
  public func subset(of b: Self) -> Bool { bits & ~b.bits == 0 }
  public func union(_ b: Self) -> Self { Self(bits | b.bits) }
  public func subtracting(_ b: Self) -> Self { Self(bits & ~b.bits) }
  public mutating func insert(_ c: Int) { bits |= UInt128(1) << c }
  public mutating func remove(_ c: Int) { bits &= ~(UInt128(1) << c) }
  public static func < (a: Self, b: Self) -> Bool { a.bits < b.bits }
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    let s = try c.decode(String.self)
    guard let value = UInt128(s, radix: 16) else {
      throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid mask")
    }
    bits = value
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(String(bits, radix: 16))
  }
}
public struct Grid {
  public let rows: Int, cols: Int, neighbors: [[Int]]
  public var count: Int { rows * cols }
  public var full: CellMask { CellMask((UInt128(1) << count) - 1) }
  public init(rows: Int, cols: Int) {
    precondition(rows > 0 && cols > 0 && rows * cols < 128)
    self.rows = rows
    self.cols = cols
    neighbors = (0..<(rows * cols)).map { c in
      var v: [Int] = []
      if c / cols > 0 { v.append(c - cols) }
      if c % cols > 0 { v.append(c - 1) }
      if c % cols + 1 < cols { v.append(c + 1) }
      if c / cols + 1 < rows { v.append(c + cols) }
      return v
    }
  }
  public func connected(_ mask: CellMask) -> Bool {
    guard let start = mask.first else { return false }
    var seen = CellMask(cells: [start])
    var q = [start]
    var i = 0
    while i < q.count {
      let c = q[i]
      i += 1
      for v in neighbors[c] where mask.contains(v) && !seen.contains(v) {
        seen.insert(v)
        q.append(v)
      }
    }
    return seen == mask
  }
}
public struct SplitMix: Codable {
  public var state: UInt64
  public init(seed: UInt64) { state = seed }
  public mutating func next() -> UInt64 {
    state &+= 0x9e37_79b9_7f4a_7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }
  public mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }
  public mutating func index(_ n: Int) -> Int {
    precondition(n > 0)
    let b = UInt64(n)
    let limit = UInt64.max - UInt64.max % b
    var x = next()
    while x >= limit { x = next() }
    return Int(x % b)
  }
  public static func derive(_ seed: UInt64, _ role: String) -> UInt64 {
    var x = seed ^ 0xcbf2_9ce4_8422_2325
    for b in role.utf8 { x = (x ^ UInt64(b)) &* 0x100_0000_01b3 }
    var r = Self(seed: x)
    return r.next()
  }
}
public struct Puzzle: Codable {
  public let id: String, n: Int, clues: [Int]
  public init(id: String, n: Int, clues: [Int]) {
    precondition(clues.count == n * n)
    self.id = id
    self.n = n
    self.clues = clues
  }
  public var grid: Grid { Grid(rows: n, cols: n) }
  public var clueCount: Int { clues.filter { $0 >= 0 }.count }
}
public struct Quality: Codable, Comparable, Equatable {
  public var issues: Int, wrong: Int
  public var residual: Double
  public init(issues: Int, wrong: Int, residual: Double) {
    self.issues = issues
    self.wrong = wrong
    self.residual = residual
  }
  public static func < (a: Self, b: Self) -> Bool {
    if a.issues != b.issues { return a.issues < b.issues }
    if a.wrong != b.wrong { return a.wrong < b.wrong }
    return a.residual < b.residual - 1e-14
  }
}
public func normalized(_ labels: [Int]) -> [Int] {
  var ids: [Int: Int] = [:]
  return labels.map { x in
    if ids[x] == nil { ids[x] = ids.count }
    return ids[x]!
  }
}
public func groups(_ labels: [Int]) -> [CellMask] {
  var out: [CellMask] = []
  for (c, id) in normalized(labels).enumerated() {
    if id == out.count { out.append(CellMask()) }
    out[id].insert(c)
  }
  return out
}
public func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
  let e = JSONEncoder()
  e.outputFormatting = [.sortedKeys]
  let data = try e.encode(value)
  try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}
public struct BenchError: Error, CustomStringConvertible {
  public let description: String
  public init(_ text: String) { description = text }
}
