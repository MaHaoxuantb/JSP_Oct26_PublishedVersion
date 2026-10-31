import Foundation
import PuzzleRules
import ShapeDomain

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
public let benchmarkVersion = "solver-bench-v1"
public struct Condition: Codable, Equatable {
  public let representation: String, regional: Bool, newBP: Bool
  public init(representation: String, regional: Bool, newBP: Bool) {
    self.representation = representation
    self.regional = regional
    self.newBP = newBP
  }
  public var id: String { "\(representation)-r\(regional ? 1:0)-b\(newBP ? 1:0)" }
}
public struct WorkerInput: Codable {
  public let jobID: String, puzzle: Puzzle, condition: Condition, seed: UInt64,
    budgetSeconds: Double, shapeStore: String, output: String
  public init(
    jobID: String, puzzle: Puzzle, condition: Condition, seed: UInt64, budgetSeconds: Double,
    shapeStore: String, output: String
  ) {
    self.jobID = jobID
    self.puzzle = puzzle
    self.condition = condition
    self.seed = seed
    self.budgetSeconds = budgetSeconds
    self.shapeStore = shapeStore
    self.output = output
  }
}
public struct Streams: Codable {
  public var initialization: SplitMix, proposal: SplitMix, acceptance: SplitMix, regional: SplitMix,
    bp: SplitMix
  public init(seed: UInt64) {
    initialization = SplitMix(seed: SplitMix.derive(seed, "initial"))
    proposal = SplitMix(seed: SplitMix.derive(seed, "proposal"))
    acceptance = SplitMix(seed: SplitMix.derive(seed, "acceptance"))
    regional = SplitMix(seed: SplitMix.derive(seed, "regional"))
    bp = SplitMix(seed: SplitMix.derive(seed, "bp"))
  }
}
public struct SearchState: Codable {
  public var strengths: [Double]
  public init(strengths: [Double]) { self.strengths = strengths }
}
public struct ScoredState {
  public let state: SearchState, exact: ExactEvaluation, uncertainty: [Double],
    discreteness: Double, nativeEnergy: Double
}
public struct SearchMetrics: Codable {
  public var iterations = 0, accepted = 0, noProposal = 0, basicCoverNodes = 0, bpNodes = 0,
    bpPhases = 0, bpImprovements = 0, patchScreens = 0, patchRejects = 0, reheats = 0, restarts = 0
  public var catalogSeconds = 0.0, coverSeconds = 0.0, bpSeconds = 0.0
  public init() {}
}
public struct Observation: Codable {
  public let jobID: String, seconds: Double, cpuSeconds: Double, cpuRatio: Double, phase: String,
    quality: Quality, commonEnergy: Double, nativeEnergy: Double, discreteness: Double,
    metrics: SearchMetrics, oracle: OracleMetrics, memoryBytes: Int, updated: Double
}
public struct WorkerResult: Codable {
  public let version: String, jobID: String, puzzleID: String, condition: Condition, seed: UInt64,
    seconds: Double, cpuSeconds: Double, solved: Bool, reason: String, labels: [[Int]],
    strengths: [Double], quality: Quality, answer: Int?, metrics: SearchMetrics,
    oracle: OracleMetrics, singleThreaded: Bool, gpuEnabled: Bool
}
public enum ResourceUse {
  /// Synchronous engines stay on one thread even when several share a process.
  public static func threadCPUSeconds() -> Double {
    var t = timespec()
    guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t) == 0 else { return usage().cpu }
    return Double(t.tv_sec) + Double(t.tv_nsec) / 1_000_000_000
  }
  public static func usage() -> (cpu: Double, memory: Int) {
    var r = rusage()
    #if os(Linux)
      _ = getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &r)
    #else
      _ = getrusage(RUSAGE_SELF, &r)
    #endif
    let cpu =
      Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(
        r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1_000_000
    #if os(Linux)
      return (cpu, Int(r.ru_maxrss) * 1024)
    #else
      return (cpu, Int(r.ru_maxrss))
    #endif
  }
  public static func performanceQoS() {
    #if canImport(Darwin)
      _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
    #endif
  }
}
public struct Temperature {
  public var value = 0.03, increases: [Double] = []
  public mutating func step(_ delta: Double?) {
    if let d = delta, d > 0 {
      increases.append(d)
      if increases.count > 64 { increases.removeFirst() }
    }
    let typical = increases.sorted().dropFirst(increases.count / 2).first ?? 0
    value = max(max(0.0001, typical / -log(0.02)), value * 0.997)
  }
  public mutating func reheat() {
    let typical = increases.sorted().dropFirst(increases.count / 2).first ?? 0
    value = max(0.03, typical / -log(0.3))
  }
}
