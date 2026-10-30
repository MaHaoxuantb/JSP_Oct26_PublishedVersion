import Foundation
import XCTest
import PuzzleRules
import ShapeDomain
import SolverCore
@testable import RepairPolicies

final class PolicyTests: XCTestCase {
  func testRouteScopesContainWholeConnectedRegions() {
    let labels = ["ABBCC","ABBDC","AADDC","CAAAC","CCCCC"].flatMap { $0.utf8.map(Int.init) }
    let p = Puzzle(id:"route-test",n:5,clues:[13,-1,-1,-1,17,8,-1,6,3,-1,-1,-1,-1,-1,-1,-1,7,6,-1,10,25,-1,-1,-1,0])
    let source = StateCodec.evaluate(StateCodec.encode(labels,grid:p.grid,previous:nil,continuous:false),puzzle:p)
    var guided = 0
    for seed in 0..<100 {
      var rng = SplitMix(seed:UInt64(seed))
      let c = RouteSelection.choose(source:source,puzzle:p,limit:16,large:true,rng:&rng)
      XCTAssertTrue(p.grid.connected(c.mask))
      for part in groups(labels) { XCTAssertTrue(!part.intersects(c.mask) || part.subset(of:c.mask)) }
      if c.kind == "clue_route" { guided += 1;XCTAssertNotNil(c.clue);XCTAssertFalse(c.route.isEmpty) }
    }
    XCTAssertGreaterThan(guided,50)
  }
  func testPersistenceSurvivesTwoUnsuccessfulSlices() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let p = Puzzle(id:"resume-test",n:3,clues:[9,-1,-1,-1,-1,-1,-1,-1,-1])
    let source = StateCodec.evaluate(StateCodec.encode(Array(0..<9),grid:p.grid,previous:nil,continuous:false),puzzle:p)
    for settings in [(false,false),(false,true),(true,false),(true,true)] {
      let persistent = settings.0, routeSelected = settings.1
      let out = root.appendingPathComponent((persistent ? "on":"off") + (routeSelected ? "-route":"-neighbor"))
      try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
      let policy = try RepairScheduler(persistent:persistent,routeSelected:routeSelected,output:out.path)
      let input = WorkerInput(jobID:"test",puzzle:p,condition:Condition(representation:"discrete",regional:true,newBP:true),seed:99,budgetSeconds:1,shapeStore:"unused",output:out.path)
      let oracle = ShapeOracle(grid:p.grid,templates:[])
      var rng = SplitMix(seed:99), metrics = SearchMetrics()
      for _ in 0..<24 {
        _ = try policy.improve(source:source,globalBest:source,input:input,oracle:oracle,until:monotonic()-1,rng:&rng,metrics:&metrics)
      }
      let events = try String(contentsOf:out.appendingPathComponent("repairs.jsonl"),encoding:.utf8).split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }
      let slices = events.filter { $0["event"] as? String == "slice" }.compactMap { $0["slice"] as? Int }
      XCTAssertFalse(slices.isEmpty)
      if persistent { XCTAssertGreaterThan(slices.max()!,2);XCTAssertNil(policy.counters["two_phase_expiry"]) }
      else { XCTAssertLessThanOrEqual(slices.max()!,2);XCTAssertGreaterThan(policy.counters["two_phase_expiry",default:0],0) }
      XCTAssertEqual(source.exact.labels,Array(0..<9))
    }
  }
}
