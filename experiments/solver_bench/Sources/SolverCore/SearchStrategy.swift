import PuzzleRules

/// Optional experimental proposal/objective policy. Retained results always use
/// the original exact Quality ordering, independently of this working objective.
public protocol SearchStrategy: AnyObject {
  var restoredState: SearchState? { get }
  func energy(_ value: ScoredState) -> Double
  func propose(source: ScoredState, input: WorkerInput, until: Double,
    rng: inout SplitMix, metrics: inout SearchMetrics) -> ScoredState?
  func restart(fallback: ScoredState) -> ScoredState
  func checkpoint(current: ScoredState, best: ScoredState, input: WorkerInput) throws
}
