import PuzzleRules
import ShapeDomain

/// Optional experiment policy. The default engine retains its frozen BP behavior.
/// Bounds and result validation remain in the shared shape/rules implementation.
public protocol SearchIntensifier: AnyObject {
  func improve(
    source: ScoredState, globalBest: ScoredState, input: WorkerInput, oracle: ShapeOracle,
    until: Double, rng: inout SplitMix, metrics: inout SearchMetrics
  ) throws -> ScoredState?
}
