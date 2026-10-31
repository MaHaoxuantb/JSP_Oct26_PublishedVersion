// JSP-Oct26-Search-Escape-Stall; ©2026 ThomasB. Author: ThomasB.
import Foundation
import PuzzleRules
import ShapeDomain
import SolverCore
import EscapePolicies

@main struct RepairRetention {
 struct Seed:Decodable{let puzzle:Puzzle,labels:[Int]}
 static func main()throws {
  let seed=try JSONDecoder().decode(Seed.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
  let root=CommandLine.arguments[2],shape=CommandLine.arguments[3]
  let source=StateCodec.evaluate(StateCodec.encode(seed.labels,grid:seed.puzzle.grid,previous:nil,continuous:false),puzzle:seed.puzzle)
  for stable in [false,true] {
   let out=root+(stable ? "/sustained":"/legacy");try FileManager.default.createDirectory(atPath:out,withIntermediateDirectories:true)
   let worker=WorkerInput(jobID:"retention-w1",puzzle:seed.puzzle,condition:Condition(representation:"discrete",regional:true,newBP:true),seed:2026103103,budgetSeconds:60,shapeStore:shape,output:out)
   let policy=try AdaptiveRepair(output:out,escalate:true,adaptive:true,recombine:false,allowGlobal:false,sustained:stable)
   policy.guide(SearchAdvice(recordAge:44000,wrongAge:44000))
   let oracle=ShapeOracle(grid:seed.puzzle.grid,templates:try ShapeStore.read(shape))
   var rng=SplitMix(seed:2026103103),metrics=SearchMetrics()
   for _ in 0..<120{_=try policy.improve(source:source,globalBest:source,input:worker,oracle:oracle,until:monotonic()+0.02,rng:&rng,metrics:&metrics)}
   try writeJSON(metrics,to:out+"/metrics.json")
  }
 }
}
