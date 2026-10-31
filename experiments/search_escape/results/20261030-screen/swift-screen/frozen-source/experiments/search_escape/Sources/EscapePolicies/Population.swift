// JSP-Oct26-Search-Escape; ©2026 ThomasB. Author: ThomasB.
import Foundation
import PuzzleRules
import SolverCore

public final class Population: GuidedSearchExchange, @unchecked Sendable {
  public let puzzle: Puzzle, output: String, stopFile: String, diverse: Bool
  private let lock=NSLock(), started=monotonic(), cpuStart=ResourceUse.usage().cpu
  private let migrationSeconds: Double
  private var entries:[ScoredState]=[], leader:ScoredState, lastRecord:Double, lastWrong:Double
  private var lastWrite = -Double.infinity, visits:[String:Int]=[:], migrated:[String:Double]=[:]
  private var active:[String:String]=[:], published=Set<String>(), migrations=0, stopped=false
  private let log:FileHandle
  public init(puzzle:Puzzle, seeds:[SearchState], output:String, stopFile:String,
    diverse:Bool, migrationSeconds:Double=60) throws {
    self.puzzle=puzzle;self.output=output;self.stopFile=stopFile;self.diverse=diverse
    self.migrationSeconds=migrationSeconds;lastRecord=monotonic();lastWrong=lastRecord
    guard let seed=seeds.first else {throw BenchError("Missing population seed")}
    leader=StateCodec.evaluate(seed,puzzle:puzzle)
    for seed in seeds {
      let value=StateCodec.evaluate(seed,puzzle:puzzle)
      if value.exact.quality < leader.exact.quality {leader=value}
      if !entries.contains(where:{$0.exact.labels==value.exact.labels}) {entries.append(value)}
    }
    entries.sort{$0.exact.quality < $1.exact.quality}
    FileManager.default.createFile(atPath:output+"/global-events.jsonl",contents:nil)
    log=try FileHandle(forWritingTo:URL(fileURLWithPath:output+"/global-events.jsonl"))
  }
  deinit {try? log.close()}
  public var shouldStop:Bool {lock.lock();defer{lock.unlock()};return stopped || FileManager.default.fileExists(atPath:stopFile)}
  public func stop(){lock.lock();stopped=true;lock.unlock()}
  public static func distance(_ a:[Int],_ b:[Int],grid:Grid)->Int {
    StateCodec.edges(grid).reduce(0){$0 + ((a[$1.0]==a[$1.1]) != (b[$1.0]==b[$1.1]) ? 1:0)}
  }
  private func key(_ labels:[Int])->String {normalized(labels).map(String.init).joined(separator:",")}
  private func insert(_ value:ScoredState) {
    guard value.exact.quality.issues==0 else{return}
    published.insert(key(value.exact.labels))
    if value.exact.quality < leader.exact.quality {
      if value.exact.quality.wrong < leader.exact.quality.wrong {lastWrong=monotonic()}
      leader=value;lastRecord=monotonic()
    }
    guard !entries.contains(where:{$0.exact.labels==value.exact.labels}) else{return}
    if diverse && entries.count>=8 && value.exact.quality.wrong>leader.exact.quality.wrong+3{return}
    entries.append(value);entries.sort{$0.exact.quality < $1.exact.quality}
    if !diverse {if entries.count>8{entries.removeLast()};return}
    if entries.count>16 {
      var keep=[leader], remaining=entries.filter{$0.exact.labels != leader.exact.labels}
      while keep.count<16 && !remaining.isEmpty {
        let index=remaining.indices.max{a,b in
          func score(_ v:ScoredState)->Double {
            let d=keep.map{Self.distance(v.exact.labels,$0.exact.labels,grid:puzzle.grid)}.min() ?? 0
            return Double(d)-Double(max(0,v.exact.quality.wrong-leader.exact.quality.wrong))*2
          }
          return score(remaining[a])<score(remaining[b])
        }!
        keep.append(remaining.remove(at:index))
      }
      entries=keep
    }
  }
  public func exchange(best:ScoredState,worker:WorkerInput)throws->SearchState? {
    try advise(current:best,best:best,worker:worker).candidate
  }
  public func advise(current:ScoredState,best:ScoredState,worker:WorkerInput)throws->SearchAdvice {
    guard worker.puzzle.n==puzzle.n && worker.puzzle.clues==puzzle.clues else{throw BenchError("Population puzzle mismatch")}
    lock.lock();defer{lock.unlock()}
    let now=monotonic();visits[worker.jobID,default:0]+=1
    active[worker.jobID]=key(current.exact.labels)
    insert(best);if diverse{insert(current)}
    let index=Int(worker.jobID.split(separator:"-").last!.dropFirst()) ?? 1
    var candidate:SearchState?
    if leader.exact.solved {candidate=leader.state}
    else if !diverse {
      if index%4 != 0 && leader.exact.quality < best.exact.quality {candidate=leader.state}
    } else if index%4 != 0 && index>2 && now-(migrated[worker.jobID] ?? started)>=migrationSeconds {
      let alternatives=entries.filter{$0.exact.labels != current.exact.labels}
      if let alternate=alternatives.max(by:{Self.distance($0.exact.labels,current.exact.labels,grid:puzzle.grid)<Self.distance($1.exact.labels,current.exact.labels,grid:puzzle.grid)}) {
        candidate=alternate.state;migrated[worker.jobID]=now;migrations+=1
      }
    } else if index<=2 && leader.exact.quality < best.exact.quality {candidate=leader.state}
    let partner=entries.filter{$0.exact.labels != current.exact.labels}.max{
      Self.distance($0.exact.labels,current.exact.labels,grid:puzzle.grid)<Self.distance($1.exact.labels,current.exact.labels,grid:puzzle.grid)
    }?.exact.labels
    if now-lastWrite>=1 || leader.exact.solved {
      lastWrite=now
      let elapsed=now-started,cpu=ResourceUse.usage().cpu-cpuStart
      let v:[String:Any] = ["seconds":elapsed,"cpuSeconds":cpu,"cpuEquivalentCores":cpu/max(0.001,elapsed),
        "quality":["issues":leader.exact.quality.issues,"wrong":leader.exact.quality.wrong,"residual":leader.exact.quality.residual],
        "commonEnergy":leader.exact.commonEnergy,"labels":leader.exact.labels,"solved":leader.exact.solved,
        "workersObserved":visits.count,"archiveSize":entries.count,"distinctPublished":published.count,
        "distinctActive":Set(active.values).count,"migrations":migrations,"recordAge":now-lastRecord,"wrongAge":now-lastWrong,
        "activeEnergies":[worker.jobID:current.exact.commonEnergy]]
      var data=try JSONSerialization.data(withJSONObject:v,options:[.sortedKeys]);data.append(10);try log.write(contentsOf:data)
      try JSONSerialization.data(withJSONObject:v,options:[.sortedKeys]).write(to:URL(fileURLWithPath:output+"/cooperative.json"),options:.atomic)
    }
    return SearchAdvice(candidate:candidate,partner:partner,recordAge:now-lastRecord,wrongAge:now-lastWrong)
  }
}
