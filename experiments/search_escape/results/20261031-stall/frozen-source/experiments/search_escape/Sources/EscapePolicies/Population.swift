// JSP-Oct26-Search-Escape; ©2026 ThomasB. Author: ThomasB.
import Foundation
import PuzzleRules
import SolverCore

public final class Population: GuidedSearchExchange, @unchecked Sendable {
  public let puzzle: Puzzle, output: String, stopFile: String, diverse: Bool
  private let lock=NSLock(), started=monotonic(), cpuStart=ResourceUse.usage().cpu
  private let migrationSeconds: Double
  private let edges:[(Int,Int)]
  private var entries:[ScoredState]=[], leader:ScoredState, lastRecord:Double, lastWrong:Double
  private var lastWrite = -Double.infinity, visits:[String:Int]=[:], migrated:[String:Double]=[:]
  private var active:[String:String]=[:], activeEnergies:[String:Double]=[:], lastExternal = -Double.infinity
  private var published=Set<String>(), migrations=0, stopped=false
  private let log:FileHandle
  public init(puzzle:Puzzle, seeds:[SearchState], output:String, stopFile:String,
    diverse:Bool, migrationSeconds:Double=60, recordAge:Double=0, wrongAge:Double=0) throws {
    self.puzzle=puzzle;self.edges=StateCodec.edges(puzzle.grid);self.output=output;self.stopFile=stopFile;self.diverse=diverse
    self.migrationSeconds=migrationSeconds;lastRecord=monotonic()-max(0,recordAge);lastWrong=monotonic()-max(0,wrongAge)
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
  private func distance(_ a:[Int],_ b:[Int])->Int {edges.reduce(0){$0 + ((a[$1.0]==a[$1.1]) != (b[$1.0]==b[$1.1]) ? 1:0)}}
  private func key(_ labels:[Int])->String {normalized(labels).map(String.init).joined(separator:",")}
  private func insert(_ value:ScoredState) {
    guard value.exact.quality.issues==0 else{return}
    published.insert(key(value.exact.labels))
    if value.exact.quality < leader.exact.quality {
      if value.exact.quality.wrong < leader.exact.quality.wrong {lastWrong=monotonic()}
      leader=value;lastRecord=monotonic()
    }
    guard !entries.contains(where:{$0.exact.labels==value.exact.labels}) else{return}
    if diverse && entries.count>=8 && value.exact.quality.wrong>leader.exact.quality.wrong+3,
      let worst=entries.max(by:{$0.exact.quality < $1.exact.quality}), !(value.exact.quality < worst.exact.quality){return}
    entries.append(value);entries.sort{$0.exact.quality < $1.exact.quality}
    if !diverse {if entries.count>8{entries.removeLast()};return}
    if entries.count>16 {
      var keep=[leader], remaining=entries.filter{$0.exact.labels != leader.exact.labels}
      var nearest=remaining.map{distance($0.exact.labels,leader.exact.labels)}
      while keep.count<16 && !remaining.isEmpty {
        let index=remaining.indices.max{a,b in
          let sa=Double(nearest[a])-Double(max(0,remaining[a].exact.quality.wrong-leader.exact.quality.wrong))*2
          let sb=Double(nearest[b])-Double(max(0,remaining[b].exact.quality.wrong-leader.exact.quality.wrong))*2
          return sa<sb
        }!
        let chosen=remaining.remove(at:index);nearest.remove(at:index);keep.append(chosen)
        for i in remaining.indices {nearest[i]=min(nearest[i],distance(remaining[i].exact.labels,chosen.exact.labels))}
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
    let previousQuality=leader.exact.quality
    let now=monotonic();visits[worker.jobID,default:0]+=1
    active[worker.jobID]=key(current.exact.labels);activeEnergies[worker.jobID]=current.exact.commonEnergy
    if now-lastExternal>=5 {
      lastExternal=now
      struct External:Decodable{let puzzle:Puzzle,labels:[Int]}
      let path=URL(fileURLWithPath:output).deletingLastPathComponent().appendingPathComponent("external-candidates.json")
      if let data=try? Data(contentsOf:path),let incoming=try? JSONDecoder().decode(External.self,from:data),
        incoming.puzzle.n==puzzle.n,incoming.puzzle.clues==puzzle.clues,incoming.labels.count==puzzle.grid.count {
        let value=StateCodec.evaluate(StateCodec.encode(incoming.labels,grid:puzzle.grid,previous:nil,continuous:false),puzzle:puzzle)
        insert(value)
      }
    }
    insert(best);if diverse{insert(current)}
    let index=Int(worker.jobID.split(separator:"-").last!.dropFirst()) ?? 1
    var candidate:SearchState?
    if leader.exact.solved {candidate=leader.state}
    else if !diverse {
      if index%4 != 0 && leader.exact.quality < best.exact.quality {candidate=leader.state}
    } else if index%4 != 0 && index>=3 && index<=6 && now-(migrated[worker.jobID] ?? started)>=migrationSeconds {
      let alternatives=entries.filter{$0.exact.labels != current.exact.labels}
      if let alternate=alternatives.max(by:{distance($0.exact.labels,current.exact.labels)<distance($1.exact.labels,current.exact.labels)}) {
        candidate=alternate.state;migrated[worker.jobID]=now;migrations+=1
      }
    } else if (index<=2 || index==7) && leader.exact.quality < best.exact.quality {candidate=leader.state}
    let partner=entries.filter{$0.exact.labels != current.exact.labels}.max{
      distance($0.exact.labels,current.exact.labels)<distance($1.exact.labels,current.exact.labels)
    }?.exact.labels
    if now-lastWrite>=1 || leader.exact.solved || leader.exact.quality < previousQuality {
      lastWrite=now
      let elapsed=now-started,cpu=ResourceUse.usage().cpu-cpuStart
      let v:[String:Any] = ["seconds":elapsed,"updated":Date().timeIntervalSince1970,"cpuSeconds":cpu,"cpuEquivalentCores":cpu/max(0.001,elapsed),
        "quality":["issues":leader.exact.quality.issues,"wrong":leader.exact.quality.wrong,"residual":leader.exact.quality.residual],
        "commonEnergy":leader.exact.commonEnergy,"labels":leader.exact.labels,"solved":leader.exact.solved,
        "workersObserved":visits.count,"archiveSize":entries.count,"distinctPublished":published.count,
        "distinctActive":Set(active.values).count,"migrations":migrations,"recordAge":now-lastRecord,"wrongAge":now-lastWrong,
        "activeEnergies":activeEnergies]
      var data=try JSONSerialization.data(withJSONObject:v,options:[.sortedKeys]);data.append(10);try log.write(contentsOf:data)
      try JSONSerialization.data(withJSONObject:v,options:[.sortedKeys]).write(to:URL(fileURLWithPath:output+"/cooperative.json"),options:.atomic)
    }
    return SearchAdvice(candidate:candidate,partner:partner,recordAge:now-lastRecord,wrongAge:now-lastWrong)
  }
}
