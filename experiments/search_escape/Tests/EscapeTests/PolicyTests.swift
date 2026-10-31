import XCTest
import PuzzleRules
import SolverCore
import ShapeDomain
@testable import EscapePolicies
final class PolicyTests:XCTestCase {
 func testBoundaryDistanceIgnoresRegionNames(){let g=Grid(rows:2,cols:2);XCTAssertEqual(Population.distance([0,0,1,1],[9,9,8,8],grid:g),0);XCTAssertGreaterThan(Population.distance([0,0,1,1],[0,1,0,1],grid:g),0)}
 func testGrowthReachesActualTargetAndWholeRegions(){let p=Puzzle(id:"growth",n:5,clues:Array(repeating:-1,count:25));let state=StateCodec.evaluate(StateCodec.encode(Array(0..<25),grid:p.grid,previous:nil,continuous:false),puzzle:p);var rng=SplitMix(seed:5);let mask=AdaptiveRepair.grow(source:state,puzzle:p,target:16,kind:"neighbor",partner:nil,rng:&rng);XCTAssertEqual(mask.count,16);XCTAssertTrue(p.grid.connected(mask))}
}

private final class Migration:GuidedSearchExchange {
 var shouldStop=false;let state:SearchState;var calls=0
 init(_ s:SearchState){state=s}
 func exchange(best:ScoredState,worker:WorkerInput)throws->SearchState?{nil}
 func advise(current:ScoredState,best:ScoredState,worker:WorkerInput)throws->SearchAdvice{calls+=1;return SearchAdvice(candidate:state)}
}
extension PolicyTests {
 func testWorseMigrationCannotEraseRetainedBest()throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let p=Puzzle(id:"migration",n:3,clues:[2,-1,-1,-1,-1,-1,-1,-1,-1])
  let original=StateCodec.encode([0,0,1,2,3,4,5,6,7],grid:p.grid,previous:nil,continuous:false)
  let peer=Migration(StateCodec.encode(Array(repeating:0,count:9),grid:p.grid,previous:nil,continuous:false))
  let shape=root.appendingPathComponent("shape.sqlite").path
  try ShapeStore.create(shape,templates:[],manifest:ShapeManifest(maxDimension:3,templateCount:0))
  let input=WorkerInput(jobID:"migration-w3",puzzle:p,condition:Condition(representation:"discrete",regional:true,newBP:false),seed:17,budgetSeconds:0.05,shapeStore:shape,output:root.path)
  let old=StateCodec.evaluate(original,puzzle:p).exact.quality
  let r=try SearchEngine(input:input,exchange:peer,islandMode:true).run(initialState:original)
  XCTAssertGreaterThan(peer.calls,0);XCTAssertFalse(old < r.quality)
 }
 func testProtectedSearchRestoresAndRejectsIncompatiblePolicy()throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let p=Puzzle(id:"restore",n:3,clues:[99]+Array(repeating:-1,count:8))
  let source=StateCodec.evaluate(StateCodec.encode(Array(0..<9),grid:p.grid,previous:nil,continuous:false),puzzle:p)
  let input=WorkerInput(jobID:"restore-w1",puzzle:p,condition:Condition(representation:"discrete",regional:true,newBP:true),seed:3,budgetSeconds:1,shapeStore:"unused",output:root.path)
  let policy=try AdaptiveRepair(output:root.path,escalate:true,adaptive:false,recombine:false,exact:true)
  var rng=SplitMix(seed:3),metrics=SearchMetrics();let oracle=ShapeOracle(grid:p.grid,templates:[])
  _=try policy.improve(source:source,globalBest:source,input:input,oracle:oracle,until:monotonic()-1,rng:&rng,metrics:&metrics)
  try policy.flush();let file=root.appendingPathComponent("escape-repairs.json").path
  // Version 7 checkpoints have no per-job elapsed-work field.
  var legacy=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:Any]
  legacy["jobs"]=(legacy["jobs"] as! [[String:Any]]).map{job in var old=job;old.removeValue(forKey:"seconds");return old}
  try JSONSerialization.data(withJSONObject:legacy).write(to:URL(fileURLWithPath:file),options:.atomic)
  let restored=try AdaptiveRepair(output:root.path,escalate:true,adaptive:false,recombine:false,exact:true,restore:file)
  XCTAssertEqual(restored.counters["restoredJobs"],1)
  _=try restored.improve(source:source,globalBest:source,input:input,oracle:oracle,until:monotonic()-1,rng:&rng,metrics:&metrics)
  XCTAssertEqual(restored.counters["protectedSlices"],1)
  XCTAssertThrowsError(try AdaptiveRepair(output:root.path,escalate:false,adaptive:false,recombine:false,exact:true,restore:file))
 }
}
extension PolicyTests {
 func testExhaustedScopeMemoAvoidsRepeatingSameSearch()throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let p=Puzzle(id:"memo",n:1,clues:[99]);let source=StateCodec.evaluate(StateCodec.encode([0],grid:p.grid,previous:nil,continuous:false),puzzle:p)
  let input=WorkerInput(jobID:"memo-w1",puzzle:p,condition:Condition(representation:"discrete",regional:true,newBP:true),seed:1,budgetSeconds:1,shapeStore:"unused",output:root.path)
  let policy=try AdaptiveRepair(output:root.path,escalate:true,adaptive:false,recombine:false);var rng=SplitMix(seed:1),metrics=SearchMetrics();let oracle=ShapeOracle(grid:p.grid,templates:[])
  for _ in 0..<8{_=try policy.improve(source:source,globalBest:source,input:input,oracle:oracle,until:monotonic()+0.05,rng:&rng,metrics:&metrics)}
  XCTAssertEqual(policy.counters["created"],1);XCTAssertGreaterThan(policy.counters["memoHits",default:0],0)
 }
}
extension PolicyTests {
 func testUnfinishedRepairsReceiveWorkInsteadOfBeingImmediatelyEvicted()throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let p=Puzzle(id:"retention",n:9,clues:[99]+Array(repeating:-1,count:80))
  let source=StateCodec.evaluate(StateCodec.encode(Array(0..<81),grid:p.grid,previous:nil,continuous:false),puzzle:p)
  let input=WorkerInput(jobID:"retention-w1",puzzle:p,condition:Condition(representation:"discrete",regional:true,newBP:true),seed:3,budgetSeconds:1,shapeStore:"unused",output:root.path)
  let policy=try AdaptiveRepair(output:root.path,escalate:true,adaptive:true,recombine:false,allowGlobal:false)
  policy.guide(SearchAdvice(recordAge:1000,wrongAge:1000))
  var rng=SplitMix(seed:3),metrics=SearchMetrics();let oracle=ShapeOracle(grid:p.grid,templates:[])
  // Expired work slices must not buy permission to discard a frontier.
  for _ in 0..<40{_=try policy.improve(source:source,globalBest:source,input:input,oracle:oracle,until:monotonic()-1,rng:&rng,metrics:&metrics)}
  XCTAssertEqual(policy.counters["created"],4);XCTAssertEqual(policy.counters["evicted",default:0],0)
  let value=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("escape-repairs.json"))) as! [String:Any]
  let jobs=value["jobs"] as! [[String:Any]]
  XCTAssertTrue(jobs.allSatisfy{($0["slices"] as! Int)>0})
  let restored=try AdaptiveRepair(output:root.path,escalate:true,adaptive:true,recombine:false,restore:root.path+"/escape-repairs.json",allowGlobal:false)
  XCTAssertEqual(restored.counters["restoredJobs"],4)
 }
 func testImprovementFlushesProgressAndResetsWrongClockImmediately()throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let p=Puzzle(id:"clock",n:3,clues:[1,-1,-1,-1,-1,-1,-1,-1,99]);let seed=StateCodec.encode(Array(0..<9),grid:p.grid,previous:nil,continuous:false)
  let pool=try Population(puzzle:p,seeds:[seed],output:root.path,stopFile:root.path+"/STOP",diverse:true,recordAge:700,wrongAge:700)
  let input=WorkerInput(jobID:"clock-w1",puzzle:p,condition:Condition(representation:"discrete",regional:true,newBP:true),seed:1,budgetSeconds:1,shapeStore:"unused",output:root.path)
  let old=StateCodec.evaluate(seed,puzzle:p);_=try pool.advise(current:old,best:old,worker:input)
  let improved=StateCodec.evaluate(StateCodec.encode([0,0,1,2,3,4,5,6,7],grid:p.grid,previous:nil,continuous:false),puzzle:p)
  XCTAssertLessThan(improved.exact.quality.wrong,old.exact.quality.wrong);XCTAssertFalse(improved.exact.solved)
  _=try pool.advise(current:improved,best:improved,worker:input)
  let value=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("cooperative.json"))) as! [String:Any]
  XCTAssertEqual((value["quality"] as! [String:Any])["wrong"] as? Int,improved.exact.quality.wrong)
  XCTAssertLessThan(value["wrongAge"] as! Double,1)
 }
}
