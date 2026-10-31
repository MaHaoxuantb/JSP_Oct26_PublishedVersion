import Foundation
import XCTest
import PuzzleRules
import ShapeDomain
@testable import SolverCore

private final class FixedExchange: SearchExchange {
  var shouldStop = false
  var state: SearchState?
  var calls = 0
  init(_ state: SearchState? = nil) { self.state = state }
  func exchange(best: ScoredState, worker: WorkerInput) throws -> SearchState? {
    calls += 1
    return state
  }
}
final class ExchangeTests: XCTestCase {
  private func prepare(_ puzzle: Puzzle, seconds: Double) throws -> (URL, WorkerInput) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let shape = root.appendingPathComponent("shape.sqlite").path
    try ShapeStore.create(shape,templates:[],manifest:ShapeManifest(maxDimension:11,templateCount:0))
    return (root,WorkerInput(jobID:"exchange-test",puzzle:puzzle,
      condition:Condition(representation:"discrete",regional:true,newBP:false),seed:19,
      budgetSeconds:seconds,shapeStore:shape,output:root.path))
  }
  func testPeerSolutionIsReevaluatedAndTerminates() throws {
    let labels = ["ABBCC","ABBDC","AADDC","CAAAC","CCCCC"].flatMap{$0.utf8.map(Int.init)}
    let puzzle = Puzzle(id:"example",n:5,clues:[12,-1,-1,-1,17,8,-1,6,3,-1,-1,-1,-1,-1,-1,-1,7,6,-1,10,25,-1,-1,-1,0])
    let (root,input) = try prepare(puzzle,seconds:3)
    defer {try? FileManager.default.removeItem(at:root)}
    let exchange = FixedExchange(StateCodec.encode(labels,grid:puzzle.grid,previous:nil,continuous:false))
    let result = try SearchEngine(input:input,exchange:exchange).run()
    XCTAssertTrue(result.solved);XCTAssertEqual(result.answer,8045);XCTAssertGreaterThan(exchange.calls,0)
  }
  func test3000SecondBudgetCanCancelWithoutWaiting() throws {
    let (root,input) = try prepare(Puzzle(id:"impossible",n:3,clues:[99]+Array(repeating:-1,count:8)),seconds:3000)
    defer {try? FileManager.default.removeItem(at:root)}
    let exchange = FixedExchange();exchange.shouldStop=true
    let result = try SearchEngine(input:input,exchange:exchange).run()
    XCTAssertEqual(result.reason,"cancelled");XCTAssertFalse(result.solved);XCTAssertLessThan(result.seconds,3)
    XCTAssertGreaterThanOrEqual(result.cpuSeconds,0)
  }
  func testMalformedPeerCannotEnterSearch() throws {
    let (root,input) = try prepare(Puzzle(id:"impossible",n:3,clues:[99]+Array(repeating:-1,count:8)),seconds:3)
    defer {try? FileManager.default.removeItem(at:root)}
    XCTAssertThrowsError(try SearchEngine(input:input,exchange:FixedExchange(SearchState(strengths:[0]))).run())
  }
  func testInitialSolutionIsReevaluatedWithoutSearch() throws {
    let labels = ["ABBCC","ABBDC","AADDC","CAAAC","CCCCC"].flatMap{$0.utf8.map(Int.init)}
    let puzzle = Puzzle(id:"example",n:5,clues:[12,-1,-1,-1,17,8,-1,6,3,-1,-1,-1,-1,-1,-1,-1,7,6,-1,10,25,-1,-1,-1,0])
    let (root,input) = try prepare(puzzle,seconds:3)
    defer {try? FileManager.default.removeItem(at:root)}
    let state = StateCodec.encode(labels,grid:puzzle.grid,previous:nil,continuous:false)
    let result = try SearchEngine(input:input).run(initialState:state)
    XCTAssertTrue(result.solved);XCTAssertEqual(result.answer,8045)
    XCTAssertEqual(result.metrics.iterations,0)
    XCTAssertThrowsError(try SearchEngine(input:input).run(initialState:SearchState(strengths:[0])))
    var invalid = state;invalid.strengths[0] = .nan
    XCTAssertThrowsError(try SearchEngine(input:input).run(initialState:invalid))
  }
}
