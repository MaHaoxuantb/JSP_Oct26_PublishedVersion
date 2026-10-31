// JSP-Oct26-CPU8-Completion; ©2026 ThomasB. Author: ThomasB.
import Foundation
import Dispatch
import PuzzleRules
import SolverCore
import RepairPolicies

struct TrialInput: Codable {
  let id: String, puzzle: Puzzle, seed: UInt64, seconds: Double, threads: Int
  let persistent: Bool, routeSelected: Bool, shapeStore: String, output: String, stopFile: String
  let seedResult: String?
}
private struct Entry {
  let state: SearchState, labels: [Int], quality: Quality, energy: Double, owner: String
}
private final class Archive: SearchExchange, @unchecked Sendable {
  private let input: TrialInput, started: Double, cpuStarted: Double
  private let lock = NSLock(), log: FileHandle
  private var entries: [Entry] = [], counts: [String: Int] = [:], imports: [String: Int] = [:]
  private var lastWrite = -Double.infinity, stopping = false
  private(set) var seeds: [SearchState] = []
  init(_ input: TrialInput, started: Double) throws {
    self.input = input; self.started = started; cpuStarted = ResourceUse.usage().cpu
    FileManager.default.createFile(atPath: input.output + "/global-events.jsonl", contents: nil)
    log = try FileHandle(forWritingTo: URL(fileURLWithPath: input.output + "/global-events.jsonl"))
    if let path = input.seedResult {
      struct Saved: Decodable { let puzzle: Puzzle; let workers: [WorkerResult] }
      let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: URL(fileURLWithPath:path)))
      guard saved.puzzle.n == input.puzzle.n, saved.puzzle.clues == input.puzzle.clues,
        saved.workers.count == 8 else { throw BenchError("Seed result belongs to another puzzle or pool") }
      for worker in saved.workers.sorted(by: { $0.quality < $1.quality }) {
        let state = SearchState(strengths:worker.strengths)
        guard state.strengths.count == StateCodec.edges(input.puzzle.grid).count,
          state.strengths.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { throw BenchError("Invalid saved search state") }
        let value = StateCodec.evaluate(state,puzzle:input.puzzle)
        guard value.exact.quality == worker.quality,
          value.exact.labels == worker.labels.flatMap({$0}), value.exact.quality.issues == 0
        else { throw BenchError("Saved search state failed revalidation") }
        seeds.append(state)
        entries.append(Entry(state:state,labels:value.exact.labels,quality:value.exact.quality,
          energy:value.exact.commonEnergy,owner:"saved"))
      }
    }
  }
  var shouldStop: Bool {
    lock.lock(); defer { lock.unlock() }
    return stopping || FileManager.default.fileExists(atPath: input.stopFile)
  }
  func stop() { lock.lock(); stopping = true; lock.unlock() }
  func metrics() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    return ["exchanges": counts, "imports": imports, "archiveSize": entries.count]
  }
  func exchange(best: ScoredState, worker: WorkerInput) throws -> SearchState? {
    guard worker.puzzle.n == input.puzzle.n && worker.puzzle.clues == input.puzzle.clues else {
      throw BenchError("Cooperative archive received another puzzle")
    }
    // Receiving engines also re-evaluate imports. No mutable oracle, repair stack
    // or fixed exterior crosses this boundary.
    let value = StateCodec.evaluate(best.state, puzzle: input.puzzle)
    lock.lock(); defer { lock.unlock() }
    counts[worker.jobID, default: 0] += 1
    let oldBest = entries.first?.quality
    if !entries.contains(where: { $0.state.strengths == value.state.strengths }) {
      entries.append(Entry(state: value.state, labels: value.exact.labels,
        quality: value.exact.quality, energy: value.exact.commonEnergy, owner: worker.jobID))
      entries.sort { $0.quality < $1.quality }
      if entries.count > 8 { entries.removeLast(entries.count - 8) }
    }
    let leader = entries[0], now = monotonic(), cpu = ResourceUse.usage().cpu - cpuStarted
    if now - lastWrite >= 1 || oldBest == nil || leader.quality < oldBest! {
      lastWrite = now
      let event: [String: Any] = ["seconds": now-started, "cpuSeconds": cpu,
        "cpuEquivalentCores": cpu / max(0.001, now-started), "quality": ["issues":leader.quality.issues,
          "wrong":leader.quality.wrong,"residual":leader.quality.residual],
        "commonEnergy":leader.energy,"labels":leader.labels,
        "workersObserved":counts.count,"exchanges":counts,"imports":imports,
        "archiveSize":entries.count,"solved":leader.quality.issues == 0 && leader.quality.wrong == 0]
      var data = try JSONSerialization.data(withJSONObject:event,options:[.sortedKeys]); data.append(10)
      try log.write(contentsOf:data)
      try JSONSerialization.data(withJSONObject:event,options:[.sortedKeys])
        .write(to:URL(fileURLWithPath:input.output+"/cooperative.json"),options:.atomic)
    }
    let index = Int(worker.jobID.split(separator:"-").last!.dropFirst()) ?? 1
    let solved = leader.quality.issues == 0 && leader.quality.wrong == 0
    if !solved && index % 4 == 0 { return nil } // Two independent explorers still publish.
    let candidate = solved || counts[worker.jobID]! % 2 == 1
      ? leader : entries[(index + counts[worker.jobID]! / 2) % entries.count]
    guard candidate.quality < best.exact.quality else { return nil }
    imports[worker.jobID,default:0] += 1
    return candidate.state
  }
}
private final class Results: @unchecked Sendable {
  let lock = NSLock()
  var workers: [WorkerResult] = [], errors: [String] = []
  func append(_ value: WorkerResult) { lock.lock(); workers.append(value); lock.unlock() }
  func fail(_ error: Error) { lock.lock(); errors.append(String(describing:error)); lock.unlock() }
}
@main struct CPU8Worker {
  static func main() throws {
    let started = monotonic(), cpuStarted = ResourceUse.usage().cpu
    let input = try JSONDecoder().decode(TrialInput.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
    guard input.threads == 8, input.seconds > 0, input.seconds <= 3000,
      input.persistent else { throw BenchError("Invalid CPU8 trial") }
    let archive = try Archive(input,started:started), results = Results()
    ResourceUse.performanceQoS()
    DispatchQueue.concurrentPerform(iterations:input.threads) { index in
      do {
        let out = input.output + "/worker-\(index+1)"
        try FileManager.default.createDirectory(atPath:out,withIntermediateDirectories:true)
        let worker = WorkerInput(jobID:input.id+"-w\(index+1)",puzzle:input.puzzle,
          condition:Condition(representation:"discrete",regional:true,newBP:true),
          seed:input.seed &+ UInt64(index) &* 0x9E3779B97F4A7C15,
          budgetSeconds:max(0.001,input.seconds-(monotonic()-started)),shapeStore:input.shapeStore,output:out)
        let policy = try RepairScheduler(persistent:true,routeSelected:input.routeSelected,output:out)
        let result = try SearchEngine(input:worker,intensifier:policy,exchange:archive)
          .run(initialState:archive.seeds.isEmpty ? nil : archive.seeds[index])
        try writeJSON(result,to:out+"/result.json")
        try writeJSON(policy.counters,to:out+"/repair-progress.json")
        results.append(result)
      } catch { results.fail(error); archive.stop() }
    }
    guard results.errors.isEmpty, results.workers.count == 8 else {
      throw BenchError("CPU8 worker failures: \(results.errors)")
    }
    let best = results.workers.min { $0.quality < $1.quality }!
    let checked = Rules.evaluate(best.labels.flatMap{$0},puzzle:input.puzzle)
    guard checked.quality == best.quality else { throw BenchError("Final quality disagreement") }
    let cpu = ResourceUse.usage().cpu-cpuStarted, seconds = monotonic()-started
    let result: [String:Any] = ["experiment":"JSP-Oct26-CPU8-Completion","copyright":"©2026 ThomasB",
      "softwareVersion":SoftwareVersion.current,"id":input.id,"puzzle":try JSONSerialization.jsonObject(with:JSONEncoder().encode(input.puzzle)),
      "seed":input.seed,"seconds":seconds,"cpuSeconds":cpu,"cpuEquivalentCores":cpu/max(seconds,0.001),
      "cpuWorkers":8,"gpuEnabled":false,"solved":checked.solved,"labels":checked.labels,
      "quality":["issues":checked.quality.issues,"wrong":checked.quality.wrong,"residual":checked.quality.residual],
      "commonEnergy":checked.commonEnergy,"answer":checked.answer as Any? ?? NSNull(),
      "reason":checked.solved ? "solved" : archive.shouldStop ? "cancelled":"time_limit",
      "cooperative":archive.metrics(),
      "workers":try results.workers.map {try JSONSerialization.jsonObject(with:JSONEncoder().encode($0))}]
    try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted])
      .write(to:URL(fileURLWithPath:input.output+"/result.json"),options:.atomic)
    print("Finished \(input.id), \(seconds)s, CPU \(cpu/seconds), solved \(checked.solved)")
  }
}
