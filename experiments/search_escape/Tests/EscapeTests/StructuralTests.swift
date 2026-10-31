import Foundation
import XCTest
import PuzzleRules
import ShapeDomain
import SolverCore
@testable import EscapePolicies

final class StructuralTests:XCTestCase {
 func testDeductionsPreservePrintedExample() {
  let clues=[12,-1,-1,-1,17,8,-1,6,3,-1,-1,-1,-1,-1,-1,-1,7,6,-1,10,25,-1,-1,-1,0]
  let labels=Array("ABBDDABBCDAACCDD AAADDDDDD".filter{$0 != " "}).map{Int($0.asciiValue!)}
  let p=Puzzle(id:"example",n:5,clues:clues)
  let v=StateCodec.evaluate(StateCodec.encode(labels,grid:p.grid,previous:nil,continuous:false),puzzle:p)
  XCTAssertTrue(v.exact.solved)
  let d=ClueDeductions(p);XCTAssertEqual(d.assess(v).violations,0)
  for part in groups(labels) {XCTAssertTrue(d.permits(part,capitol:Rules.geometry(part,grid:p.grid).capitol))}
 }
 func testDirectGrowthProducesLargeLegalRegions() {
  var clues=Array(repeating:-1,count:121);clues[115]=0;clues[118]=77;clues[119]=61
  let p=Puzzle(id:"large",n:11,clues:clues),d=ClueDeductions(p)
  XCTAssertEqual(d.minimumLargestRegion,26);XCTAssertEqual(d.minimumAreas[119],16)
  var rng=SplitMix(seed:2026103104),found=0
  for _ in 0..<40 {
   if let m=StructuralRegions.large(deductions:d,rng:&rng) {
    found+=1;let geo=Rules.geometry(m,grid:p.grid)
    XCTAssertTrue(geo.legal);XCTAssertGreaterThanOrEqual(m.count,26);XCTAssertTrue(d.permits(m,capitol:geo.capitol))
   }
  }
  XCTAssertGreaterThan(found,0)
 }
 func testFiniteCoverKeepsKnownNecessaryFeasibleTiling()throws {
  let grid=Grid(rows:3,cols:3),labels=[0,0,1,0,2,3,4,5,6]
  let unnumbered=Puzzle(id:"cover",n:3,clues:Array(repeating:-1,count:9))
  let expected=Rules.evaluate(labels,puzzle:unnumbered)
  let p=Puzzle(id:"cover",n:3,clues:expected.distances.map{$0!}),catalog=StructuralCatalog(puzzle:p,templates:[])
  var rng=SplitMix(seed:4),nodes=0
  let result=StructuralRegions.tile(released:grid.full,forced:nil,base:labels,catalog:catalog,extra:[],until:monotonic()+1,rng:&rng,nodes:&nodes)
  XCTAssertNotNil(result)
  if let result {XCTAssertTrue(Rules.evaluate(result,puzzle:p).solved)}
 }
 func testStructuralStateSurvivesIndependentCheckpointAndPuzzleMismatchFails()throws {
  let out=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:out)}
  let p=Puzzle(id:"checkpoint",n:3,clues:[1]+Array(repeating:-1,count:8)),catalog=StructuralCatalog(puzzle:p,templates:[])
  let state=StateCodec.evaluate(StateCodec.encode([0,0,1,2,3,4,5,6,7],grid:p.grid,previous:nil,continuous:false),puzzle:p)
  let worker=WorkerInput(jobID:"checkpoint-w3",puzzle:p,condition:Condition(representation:"discrete",regional:true,newBP:true),seed:1,budgetSeconds:1,shapeStore:"unused",output:out.path)
  let s=try StructuralStrategy(catalog:catalog);try s.checkpoint(current:state,best:state,input:worker)
  let file=out.path+"/structural-checkpoint.json",restored=try StructuralStrategy(catalog:catalog,restore:file)
  XCTAssertEqual(restored.restoredState?.strengths,state.state.strengths)
  let other=StructuralCatalog(puzzle:Puzzle(id:"other",n:3,clues:Array(repeating:-1,count:9)),templates:[])
  XCTAssertThrowsError(try StructuralStrategy(catalog:other,restore:file))
 }
}
