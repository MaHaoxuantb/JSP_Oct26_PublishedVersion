import Foundation
import Darwin
import PuzzleRules

private struct PuzzleInput: Codable { let id: String, n: Int, clues: [Int] }
private struct WorkerInput: Codable {
  let jobID: String, puzzle: PuzzleInput, seed: UInt64, budgetSeconds: Double, output: String
}
private struct Envelope: Codable { let worker: WorkerInput }
private final class ObservationSink: @unchecked Sendable {
  let input: WorkerInput, started: Double, cpuStart: Double
  let file: FileHandle
  let lock = NSLock()
  init(_ input: WorkerInput, started: Double, cpuStart: Double) throws {
    self.input = input; self.started = started; self.cpuStart = cpuStart
    FileManager.default.createFile(atPath: input.output + "/events.jsonl", contents: nil)
    file = try FileHandle(forWritingTo: URL(fileURLWithPath: input.output + "/events.jsonl"))
  }
  func sample(_ progress: DistributedProgress) {
    lock.lock(); defer { lock.unlock() }
    do {
      let p = input.puzzle
      let value = PuzzleRules.Rules.evaluate(progress.best, puzzle: PuzzleRules.Puzzle(id:p.id,n:p.n,clues:p.clues))
      let seconds = ProcessInfo.processInfo.systemUptime - started
      let cpu = cpuSeconds() - cpuStart
      let q: [String:Any] = ["issues":value.quality.issues,"wrong":value.quality.wrong,"residual":value.quality.residual]
      let sample: [String:Any] = ["jobID":input.jobID,"seconds":seconds,"cpuSeconds":cpu,
        "cpuRatio":cpu / max(seconds,0.001),"quality":q,"commonEnergy":value.commonEnergy,
        "phase":progress.finished ? "finished":"production","updated":Date().timeIntervalSince1970,
        "labels":progress.best,"iterations":progress.iterations]
      var data = try JSONSerialization.data(withJSONObject:sample,options:[.sortedKeys]);data.append(10)
      try file.write(contentsOf:data)
      try JSONSerialization.data(withJSONObject:sample,options:[.sortedKeys]).write(to:URL(fileURLWithPath:input.output+"/progress.json"),options:.atomic)
    } catch { fputs("Production observation failed: \(error)\n",stderr); exit(2) }
  }
}
private func cpuSeconds() -> Double {
  var r = rusage();getrusage(RUSAGE_SELF,&r)
  return Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec)+Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1_000_000
}
@main struct ProductionWorker {
  static func main() async throws {
    if CommandLine.arguments.dropFirst() == ["--preflight"] {
      let version = SoftwareVersion.current
      let data: [String:Any] = ["softwareVersion":version,
        "minimumPeerVersion":DistributedConfig().minimumPeerVersion,
        "strictAcceptsCurrent":SoftwareVersion.accepts(version,minimum:version),
        "strictAcceptsOlder":SoftwareVersion.accepts(version-1,minimum:version),
        "transitionalAcceptsLegacy":SoftwareVersion.accepts(nil,minimum:0),
        "transitionalAcceptsFuture":SoftwareVersion.accepts(version+1,minimum:0),
        "originalPuzzle":["id":"original-11","n":11,"clues":RunConfig.fullPuzzle.Target.Status.flatMap{$0}]]
      print(String(data:try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys]),encoding:.utf8)!)
      return
    }
    let started = ProcessInfo.processInfo.systemUptime, cpuStart = cpuSeconds()
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED,0)
    let input = try JSONDecoder().decode(Envelope.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))).worker
    var config = RunConfig()
    config.workerCount = 1;config.pathEvaluation = .cpu
    config.rowNum = input.puzzle.n;config.colNum = input.puzzle.n
    config.Target = OriginalCondition(Status:(0..<input.puzzle.n).map { Array(input.puzzle.clues[($0*input.puzzle.n)..<(($0+1)*input.puzzle.n)]) })
    config.seed = input.seed;config.logDirectory = input.output+"/production-logs";config.consoleLogging = false
    config.maxIterations = Int.max / 1024;config.maxRestarts = Int.max / 1024
    config.checkpointIntervalSeconds = 10;config.distributed.checkpointSeconds = 1
    config.timeLimitSeconds = max(0.001,input.budgetSeconds-(ProcessInfo.processInfo.systemUptime-started))
    let sink = try ObservationSink(input,started:started,cpuStart:cpuStart)
    let result = try await Main().Run(Config:config,workerID:1,observationRequested:{false},observe:{sink.sample($0)})
    let snap = BoardSnapshot(result.best)
    let p = input.puzzle
    let value = PuzzleRules.Rules.evaluate(snap.labels.flatMap{$0},puzzle:PuzzleRules.Puzzle(id:p.id,n:p.n,clues:p.clues))
    let obj: [String:Any] = ["jobID":input.jobID,"version":"production-v\(SoftwareVersion.current)",
      "puzzleID":p.id,"seed":input.seed,"seconds":ProcessInfo.processInfo.systemUptime-started,
      "cpuSeconds":cpuSeconds()-cpuStart,"solved":value.solved,
      "reason":result.reason == .solved ? "solved" : result.reason.rawValue,
      "labels":snap.labels,"quality":["issues":value.quality.issues,"wrong":value.quality.wrong,"residual":value.quality.residual],
      "answer":value.answer as Any? ?? NSNull(),"singleThreaded":true,"gpuEnabled":false,
      "productionMetrics":try JSONSerialization.jsonObject(with:JSONEncoder().encode(result.repairs))]
    try JSONSerialization.data(withJSONObject:obj,options:[.sortedKeys]).write(to:URL(fileURLWithPath:input.output+"/result.json"),options:.atomic)
  }
}
