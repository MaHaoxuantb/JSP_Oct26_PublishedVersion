// JSP-Oct26-Search-Escape; ©2026 ThomasB. Author: ThomasB.
import Foundation
import Dispatch
import PuzzleRules
import ShapeDomain
import SolverCore
import RepairPolicies
import EscapePolicies

struct Input:Decodable {
  let id:String,puzzle:Puzzle,seed:UInt64,seconds:Double,threads:Int,shapeStore:String,output:String,stopFile:String
  let seedResult:String?,policy:String?,probe:Bool?,restoreDirectory:String?
  let recordAge:Double?,wrongAge:Double?
  let stabilized:Bool?
  let structural:Bool?
}
struct Seed:Decodable{let puzzle:Puzzle;let workers:[WorkerResult]}
final class Results:@unchecked Sendable {
  let lock=NSLock();var workers:[WorkerResult]=[],errors:[String]=[]
  func add(_ v:WorkerResult){lock.lock();workers.append(v);lock.unlock()}
  func fail(_ error:Error){lock.lock();errors.append(String(describing:error));lock.unlock()}
}
@main struct EscapeWorker {
 static func main()throws {
  let started=monotonic(),cpuStart=ResourceUse.usage().cpu
  let input=try JSONDecoder().decode(Input.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
  guard (1...8).contains(input.threads),input.seconds>0,input.seconds<=3000 else{throw BenchError("Invalid escape trial")}
  let policy=input.policy ?? "combined",probe=input.probe ?? false,stabilized=input.stabilized ?? true
  let diverse=["diversity","adaptive","recombination","combined"].contains(policy)
  let escalate=["escalation","adaptive","recombination","combined"].contains(policy)
  var seeds:[SearchState]=[]
  if let path=input.seedResult {
   let saved=try JSONDecoder().decode(Seed.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
   guard saved.puzzle.n==input.puzzle.n && saved.puzzle.clues==input.puzzle.clues else{throw BenchError("Seed puzzle mismatch")}
   for w in saved.workers.sorted(by:{$0.quality < $1.quality}) {
    guard w.strengths.count==StateCodec.edges(input.puzzle.grid).count,w.strengths.allSatisfy({$0.isFinite && (0...1).contains($0)}) else{throw BenchError("Invalid seed strengths")}
    let state=SearchState(strengths:w.strengths),checked=StateCodec.evaluate(state,puzzle:input.puzzle)
    guard checked.exact.labels==w.labels.flatMap({$0}) && checked.exact.quality==w.quality else{throw BenchError("Invalid saved seed")}
    seeds.append(state)
   }
  }
  if seeds.isEmpty{seeds=[StateCodec.encode(Array(0..<input.puzzle.grid.count),grid:input.puzzle.grid,previous:nil,continuous:false)]}
  let structural=input.structural ?? false
  let catalog=structural ? StructuralCatalog(puzzle:input.puzzle,templates:try ShapeStore.read(input.shapeStore)):nil
  let pool=try Population(puzzle:input.puzzle,seeds:seeds,output:input.output,stopFile:input.stopFile,diverse:diverse,migrationSeconds:probe ? 3:60,recordAge:input.recordAge ?? 0,wrongAge:input.wrongAge ?? 0)
  let results=Results()
  DispatchQueue.concurrentPerform(iterations:input.threads){index in
   do {
    let out=input.output+"/worker-\(index+1)";try FileManager.default.createDirectory(atPath:out,withIntermediateDirectories:true)
    let worker=WorkerInput(jobID:input.id+"-w\(index+1)",puzzle:input.puzzle,condition:Condition(representation:"discrete",regional:true,newBP:true),seed:input.seed &+ UInt64(index) &* 0x9E3779B97F4A7C15,budgetSeconds:max(0.001,input.seconds-(monotonic()-started)),shapeStore:input.shapeStore,output:out)
    let exact=(policy=="exact" || policy=="combined") && index==input.threads-1
    let repair:SearchIntensifier
    if policy=="control" || policy=="diversity" {repair=try RepairScheduler(persistent:true,routeSelected:false,output:out)}
    else{repair=try AdaptiveRepair(output:out,escalate:escalate,adaptive:policy=="adaptive" || (policy=="combined" && index != 6),recombine:policy=="recombination" || (policy=="combined" && index==6),exact:exact,thresholds:probe ? [3,8,16]:[60,180,600],restore:input.restoreDirectory.map{$0+"/worker-\(index+1)/escape-repairs.json"},allowGlobal:probe || exact || index==6,sustained:stabilized)}
    let initial:SearchState? = exact ? seeds[0] : diverse && index>=2 && index<6 ? nil:seeds[min(index,seeds.count-1)]
    let strategy=structural && index>=2 && index<6 && !exact ? try StructuralStrategy(catalog:catalog!,restore:input.restoreDirectory.map{$0+"/worker-\(index+1)/structural-checkpoint.json"}):nil
    let engine=SearchEngine(input:worker,intensifier:repair,exchange:pool,islandMode:diverse && index>=2 && index<6 && !exact,exactOnly:exact,anchoredRestarts:stabilized && index != 3,strategy:strategy)
    let result=try engine.run(initialState:strategy == nil ? initial:seeds[0])
    try (repair as? AdaptiveRepair)?.flush();try writeJSON(result,to:out+"/result.json");results.add(result)
   }catch{results.fail(error);pool.stop()}
  }
  guard results.errors.isEmpty,results.workers.count==input.threads else{throw BenchError("Escape worker errors: \(results.errors)")}
  let best=results.workers.min{$0.quality < $1.quality}!,q=Rules.evaluate(best.labels.flatMap{$0},puzzle:input.puzzle)
  guard q.quality==best.quality else{throw BenchError("Final escape quality mismatch")}
  let elapsed=monotonic()-started,cpu=ResourceUse.usage().cpu-cpuStart
  let result:[String:Any] = ["experiment":"JSP-Oct26-Search-Escape","copyright":"©2026 ThomasB","softwareVersion":SoftwareVersion.current,"id":input.id,"puzzle":try JSONSerialization.jsonObject(with:JSONEncoder().encode(input.puzzle)),"seed":input.seed,"seconds":elapsed,"cpuSeconds":cpu,"cpuEquivalentCores":cpu/max(0.001,elapsed),"cpuWorkers":input.threads,"gpuEnabled":false,"policy":policy,"probe":probe,"solved":q.solved,"quality":["issues":q.quality.issues,"wrong":q.quality.wrong,"residual":q.quality.residual],"commonEnergy":q.commonEnergy,"labels":q.labels,"answer":q.answer as Any? ?? NSNull(),"reason":q.solved ? "solved":pool.shouldStop ? "cancelled":"time_limit","workers":try results.workers.map{try JSONSerialization.jsonObject(with:JSONEncoder().encode($0))}]
  try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:input.output+"/result.json"),options:.atomic)
 }
}
