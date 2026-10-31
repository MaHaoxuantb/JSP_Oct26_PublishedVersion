import PuzzleRules

/// Optional cooperation between searches of the same puzzle. Implementations
/// must synchronize their own state and return immutable candidate values.
/// Every imported candidate is re-evaluated by the receiving search.
public protocol SearchExchange: AnyObject {
  var shouldStop: Bool { get }
  func exchange(best: ScoredState, worker: WorkerInput) throws -> SearchState?
}

/// Optional richer advice. Diversification changes the working basin, never
/// overwrites the engine's retained best with a worse candidate.
public struct SearchAdvice {
  public var candidate: SearchState?, partner: [Int]?
  public var recordAge: Double, wrongAge: Double
  public init(candidate: SearchState? = nil, partner: [Int]? = nil,
    recordAge: Double = 0, wrongAge: Double = 0) {
    self.candidate=candidate;self.partner=partner;self.recordAge=recordAge;self.wrongAge=wrongAge
  }
}
public protocol GuidedSearchExchange: SearchExchange {
  func advise(current: ScoredState, best: ScoredState, worker: WorkerInput) throws -> SearchAdvice
}
