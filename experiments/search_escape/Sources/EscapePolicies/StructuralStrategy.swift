// JSP-Oct26-Structural-Search; ©2026 ThomasB. Author: ThomasB.
import Foundation
import PuzzleRules
import SolverCore

private struct StructuralCheckpoint:Codable {
  let version:Int,puzzle:Puzzle,current:SearchState,bestWorking:SearchState
}
public final class StructuralStrategy:SearchStrategy {
  public let catalog:StructuralCatalog
  public private(set) var restoredState:SearchState?
  private var working:ScoredState?,large:[CellMask]=[],seen=Set<CellMask>()
  private var proposals=0,tiled=0,feasible=0,generated=0,coverNodes=0,restored=false
  private var lastExternal = -Double.infinity
  public init(catalog:StructuralCatalog,restore:String?=nil)throws {
    self.catalog=catalog
    if let restore,FileManager.default.fileExists(atPath:restore) {
      let s=try JSONDecoder().decode(StructuralCheckpoint.self,from:Data(contentsOf:URL(fileURLWithPath:restore)))
      guard s.version==1,s.puzzle.n==catalog.puzzle.n,s.puzzle.clues==catalog.puzzle.clues,
        s.bestWorking.strengths.count==StateCodec.edges(s.puzzle.grid).count,
        s.bestWorking.strengths.allSatisfy({$0.isFinite && (0...1).contains($0)}) else{throw BenchError("Incompatible structural checkpoint")}
      let checked=StateCodec.evaluate(s.bestWorking,puzzle:s.puzzle)
      guard checked.exact.quality.issues==0 else{throw BenchError("Illegal structural checkpoint")}
      restoredState=s.bestWorking;working=checked;restored=true
    }
  }
  public func energy(_ value:ScoredState)->Double {catalog.deductions.energy(value)}
  private func remember(_ value:ScoredState) {
    if working == nil || energy(value)<energy(working!)-1e-14 {working=value}
  }
  public func restart(fallback:ScoredState)->ScoredState {remember(fallback);return working!}
  public func propose(source:ScoredState,input:WorkerInput,until:Double,rng:inout SplitMix,metrics:inout SearchMetrics)->ScoredState? {
    remember(source);proposals+=1
    let d=catalog.deductions,grid=input.puzzle.grid,parts=groups(source.exact.labels)
    var forced:CellMask?
    if proposals%4 != 0 {
      let candidates=parts.filter{$0.count>=d.minimumLargestRegion}
      if !candidates.isEmpty && rng.unit()<0.7 {
        forced=StructuralRegions.mutate(candidates[rng.index(candidates.count)],deductions:d,rng:&rng)
      }else{forced=StructuralRegions.large(deductions:d,rng:&rng)}
      guard let shape=forced else{return nil}
      if seen.insert(shape).inserted {
        generated+=1;large.append(shape)
        if large.count>256 {large.removeFirst()}
      }
    }
    var released=CellMask()
    for part in parts {
      let geo=Rules.geometry(part,grid:grid)
      if forced.map({part.intersects($0)}) == true || !d.permits(part,capitol:geo.capitol) {released=released.union(part)}
    }
    if forced==nil || proposals%12==0 {
      let patch=RegionalPolicy.patch(source:source,puzzle:input.puzzle,regional:true,limit:64,large:true,rng:&rng)
      released=released.union(patch)
    }
    if released.isEmpty {return nil}
    let began=monotonic();var nodes=0
    let labels=StructuralRegions.tile(released:released,forced:forced,base:source.exact.labels,catalog:catalog,
      extra:large,until:min(until,began+0.04),rng:&rng,nodes:&nodes)
    metrics.basicCoverNodes+=nodes;metrics.coverSeconds+=monotonic()-began;coverNodes+=nodes
    guard let labels else{return nil}
    let value=StateCodec.evaluate(StateCodec.encode(labels,grid:grid,previous:nil,continuous:false),puzzle:input.puzzle)
    guard value.exact.quality.issues==0 else{return nil}
    tiled+=1
    if d.assess(value).violations==0 {feasible+=1}
    remember(value)
    return value
  }
  public func checkpoint(current:ScoredState,best:ScoredState,input:WorkerInput)throws {
    remember(current)
    if monotonic()-lastExternal>=5 {
      lastExternal=monotonic()
      struct External:Decodable{let puzzle:Puzzle,labels:[Int]}
      let path=URL(fileURLWithPath:input.output).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("external-structural-candidates.json")
      if let data=try? Data(contentsOf:path),let e=try? JSONDecoder().decode(External.self,from:data),
        e.puzzle.n==input.puzzle.n,e.puzzle.clues==input.puzzle.clues,e.labels.count==input.puzzle.grid.count {
        let candidate=StateCodec.evaluate(StateCodec.encode(e.labels,grid:input.puzzle.grid,previous:nil,continuous:false),puzzle:input.puzzle)
        if candidate.exact.quality.issues==0 {remember(candidate)}
      }
    }
    let w=working!,d=catalog.deductions,a=d.assess(current),b=d.assess(w)
    try writeJSON(StructuralCheckpoint(version:1,puzzle:input.puzzle,current:current.state,bestWorking:w.state),to:input.output+"/structural-checkpoint.json")
    let status:[String:Any]=["role":"large-region feasibility","requiredLargestRegion":d.minimumLargestRegion,
      "largestRegion":current.exact.sizes.max() ?? 0,"bestLargestRegion":w.exact.sizes.max() ?? 0,
      "constraintViolations":a.violations,"constraintPenalty":a.penalty,"bestConstraintViolations":b.violations,
      "workingObjective":energy(current),"bestWorkingObjective":energy(w),"proposals":proposals,
      "tiledProposals":tiled,"necessaryFeasibleProposals":feasible,"generatedLargeShapes":generated,
      "coverNodes":coverNodes,"catalogShapes":catalog.count,"restored":restored,
      "workingWrong":current.exact.quality.wrong,"workingResidual":current.exact.quality.residual,
      "bestWorkingWrong":w.exact.quality.wrong,"bestWorkingLabels":w.exact.labels,"currentLabels":current.exact.labels,"updated":Date().timeIntervalSince1970]
    try JSONSerialization.data(withJSONObject:status,options:[.sortedKeys]).write(to:URL(fileURLWithPath:input.output+"/structure-progress.json"),options:.atomic)
  }
}
