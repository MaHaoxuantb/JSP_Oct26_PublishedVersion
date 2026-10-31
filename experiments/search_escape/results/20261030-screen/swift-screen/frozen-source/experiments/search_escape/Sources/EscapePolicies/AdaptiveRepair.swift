// JSP-Oct26-Search-Escape; ©2026 ThomasB. Author: ThomasB.
import Foundation
import PuzzleRules
import ShapeDomain
import SolverCore
import RepairPolicies

private struct OperatorStat:Codable {var calls=0;var seconds=0.0,reward=0.0}
private struct SavedJob:Codable {
  var search:CoverCheckpoint,source:SearchState,kind:String,protected:Bool,slices:Int
}
private struct SavedRepairs:Codable {
  var signature:String,puzzle:Puzzle,jobs:[SavedJob],memo:[String:Quality],operators:[String:OperatorStat]
}
public final class AdaptiveRepair:GuidedIntensifier {
  private let output:String,escalate:Bool,adaptive:Bool,recombine:Bool,exact:Bool,thresholds:[Double]
  private var advice=SearchAdvice(),jobs:[SavedJob]=[],memo:[String:Quality]=[:],operators:[String:OperatorStat]=[:]
  private var calls=0,seen=Set<String>(),puzzle:Puzzle?
  public private(set) var counters:[String:Int]=[:]
  public init(output:String,escalate:Bool,adaptive:Bool,recombine:Bool,exact:Bool=false,
    thresholds:[Double]=[60,180,600],restore:String?=nil)throws {
    self.output=output;self.escalate=escalate;self.adaptive=adaptive;self.recombine=recombine;self.exact=exact;self.thresholds=thresholds
    if let restore,FileManager.default.fileExists(atPath:restore) {
      let saved=try JSONDecoder().decode(SavedRepairs.self,from:Data(contentsOf:URL(fileURLWithPath:restore)))
      guard saved.signature==signature else{throw BenchError("Incompatible escape repair checkpoint")}
      jobs=saved.jobs;memo=saved.memo;operators=saved.operators;puzzle=saved.puzzle;counters["restoredJobs"]=jobs.count
    }
  }
  private var signature:String {"escape-v1-\(escalate)-\(adaptive)-\(recombine)-\(exact)-\(thresholds)"}
  public func guide(_ advice:SearchAdvice){self.advice=advice}
  private func count(_ key:String,_ amount:Int=1){counters[key,default:0]+=amount}
  public func flush()throws {
    guard let puzzle else{return}
    try writeJSON(SavedRepairs(signature:signature,puzzle:puzzle,jobs:jobs,memo:memo,operators:operators),to:output+"/escape-repairs.json")
    try writeJSON(counters,to:output+"/repair-progress.json")
    try writeJSON(operators,to:output+"/operator-progress.json")
  }
  private func scopeKey(_ patch:CellMask,_ base:[Int])->String {
    let exterior=groups(base).filter{!$0.intersects(patch)}.map{String($0.bits,radix:16)}.sorted().joined(separator:",")
    return String(patch.bits,radix:16)+":"+exterior
  }
  private func chooseOperator()->String {
    if !adaptive{return recombine ? "disagreement":"neighbor"}
    let names=["neighbor","block","disagreement","capital","route"]
    if let unseen=names.first(where:{operators[$0,default:OperatorStat()].calls==0}){return unseen}
    return names.max{a,b in
      func score(_ k:String)->Double {let s=operators[k]!;return s.reward/max(0.001,s.seconds)+sqrt(2*log(Double(calls+1))/Double(s.calls))}
      return score(a)<score(b)
    }!
  }
  public static func grow(source:ScoredState,puzzle:Puzzle,target:Int,kind:String,partner:[Int]?,rng:inout SplitMix)->CellMask {
    let grid=puzzle.grid,parts=groups(source.exact.labels),field=RegionalPolicy.field(source,puzzle:puzzle)
    let focus=RegionalPolicy.focus(field,regional:true,rng:&rng)
    var patch=parts[source.exact.labels[focus]]
    let disagreements:Set<Int>
    if let partner,partner.count==grid.count {
      disagreements=Set(StateCodec.edges(grid).filter{(source.exact.labels[$0.0]==source.exact.labels[$0.1]) != (partner[$0.0]==partner[$0.1])}.flatMap{[$0.0,$0.1]})
    }else{disagreements=[]}
    let capitals=Set(source.exact.capitols)
    while patch.count<min(target,grid.count) {
      let ids=Set(patch.cells.flatMap{grid.neighbors[$0]}.map{source.exact.labels[$0]}).filter{!parts[$0].intersects(patch)}.sorted()
      guard !ids.isEmpty else{break}
      let jitter=Dictionary(uniqueKeysWithValues:ids.map{($0,rng.unit())})
      let id=ids.max{a,b in
        func score(_ i:Int)->Double {
          let cells=parts[i].cells
          switch kind {
          case "block":return -Double(cells.map{abs($0/grid.cols-focus/grid.cols)+abs($0%grid.cols-focus%grid.cols)}.min()!)
          case "disagreement":return Double(cells.filter{disagreements.contains($0)}.count)*10+cells.map{field[$0]}.reduce(0,+)
          case "capital":return (cells.contains{capitals.contains($0)} ? 10:0)+cells.map{field[$0]}.reduce(0,+)
          default:return cells.map{field[$0]}.reduce(0,+)+jitter[i]!
          }
        }
        return score(a)<score(b)
      }!
      patch=patch.union(parts[id])
    }
    return patch
  }
  public func improve(source:ScoredState,globalBest:ScoredState,input:WorkerInput,oracle:ShapeOracle,
    until:Double,rng:inout SplitMix,metrics:inout SearchMetrics)throws->ScoredState? {
    if let puzzle {guard puzzle.n==input.puzzle.n && puzzle.clues==input.puzzle.clues else{throw BenchError("Restored repairs belong to another puzzle")}}
    else{puzzle=input.puzzle}
    calls+=1
    for job in jobs where job.search.finished && job.search.exhausted {
      memo[scopeKey(job.search.patch,job.search.base)]=job.search.bestQuality;count("exhausted")
    }
    jobs.removeAll{$0.search.finished}
    if memo.count>512{memo=[:]}
    let age=max(advice.recordAge,advice.wrongAge/2)
    let target=age>=thresholds[2] ? 64:age>=thresholds[1] ? 32:age>=thresholds[0] ? 16:0
    let needFull=exact || (escalate && age>=thresholds[2] && !jobs.contains{$0.protected})
    if jobs.isEmpty || calls%4==0 || needFull {
      let kind=needFull ? "full_board":chooseOperator()
      let patch:CellMask
      if needFull{patch=input.puzzle.grid.full}
      else if escalate && target>0 || kind != "neighbor" && kind != "route" {
        patch=Self.grow(source:source,puzzle:input.puzzle,target:max(16,target),kind:kind,partner:advice.partner,rng:&rng)
      }else if kind=="route" {
        patch=RouteSelection.choose(source:source,puzzle:input.puzzle,limit:32,large:true,rng:&rng).mask
      }else{patch=RegionalPolicy.patch(source:source,puzzle:input.puzzle,regional:true,limit:32,large:false,rng:&rng)}
      let key=scopeKey(patch,source.exact.labels)
      let proven=memo[key].map{!($0 < source.exact.quality)} ?? false
      if proven && !exact{count("memoHits")}
      else if !jobs.contains(where:{scopeKey($0.search.patch,$0.search.base)==key}) {
        if jobs.count>=4,let evict=jobs.firstIndex(where:{!$0.protected}){jobs.remove(at:evict);count("evicted")}
        if jobs.count<4 {
          jobs.append(SavedJob(search:CoverCheckpoint(puzzle:input.puzzle,patch:patch,base:source.exact.labels,mode:exact ? .certify:.improve),source:source.state,kind:kind,protected:needFull,slices:0))
          count("created");count("scopeCellsTotal",patch.count);count("scope_\(patch.count)");if needFull{count("protectedCreated")}
          operators[kind,default:OperatorStat()].calls+=1
        }
      }
    }
    guard !jobs.isEmpty else{return nil}
    let index=(calls%3==0 ? jobs.firstIndex(where:{$0.protected}):nil) ?? (calls%jobs.count)
    var job=jobs[index]
    let search=CoverSearch(state:job.search,oracle:oracle),before=search.state.counters.nodes,began=monotonic()
    _=search.advance(until:until,useBounds:true,maxSolutions:1)
    job.search=search.state;job.slices+=1;jobs[index]=job
    let spent=monotonic()-began
    metrics.bpPhases+=1;metrics.bpNodes+=search.state.counters.nodes-before;metrics.bpSeconds+=spent
    if job.protected{count("protectedSlices");count("protectedNodes",search.state.counters.nodes-before)}
    let value=StateCodec.evaluate(StateCodec.encode(search.state.bestLabels,grid:input.puzzle.grid,previous:job.source,continuous:false),puzzle:input.puzzle)
    let fingerprint=value.exact.labels.map(String.init).joined(separator:",")
    var reward=0.0
    if value.exact.quality < globalBest.exact.quality{reward=10;count("globalImprovements")}
    else if value.exact.quality < source.exact.quality && seen.insert(fingerprint).inserted{reward = 0.1;count("distinctLocalReturns")}
    operators[job.kind,default:OperatorStat()].seconds+=spent;operators[job.kind,default:OperatorStat()].reward+=reward
    count("kind_\(job.kind)")
    try flush()
    if value.exact.quality < source.exact.quality {metrics.bpImprovements+=1;return value}
    return nil
  }
}
