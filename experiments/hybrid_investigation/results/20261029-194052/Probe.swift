import Foundation
struct ProbeFixture: Decodable { let n:Int; let clues:[[Int]] }
struct ProbeInput: Decodable { let fixture:ProbeFixture; let labels:[Int] }
struct RepairAttempt: Codable { let seconds:Double; let patchCells:Int; let candidateRegions:Int; let catalogSeconds:Double; let repairSeconds:Double; let wrong:Int; let error:Double; let improved:Bool }
struct ProbeResult: Codable {
    let mode:String; let n:Int; let seconds:Double; let solved:Bool
    let snapshot:BoardSnapshot; let repairs:RepairMetrics; let attempts:[RepairAttempt]
}
@main struct Probe {
    static func main() async throws {
        let args=CommandLine.arguments,input=try JSONDecoder().decode(ProbeInput.self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
        let mode=args[2], budget=Double(args[3])!
        var config=RunConfig(); config.rowNum=input.fixture.n;config.colNum=input.fixture.n
        config.Target=OriginalCondition(Status:input.fixture.clues);config.seed=20261029;config.workerCount=1
        config.consoleLogging=false;config.timeLimitSeconds=budget;config.maxIterations=Int.max/4;config.maxRestarts=Int.max/4
        config.progressInterval=1;config.progressTimeIntervalSeconds=1;config.logDirectory=args[4]+"/logs"
        let result:ProbeResult
        if mode=="sa" {
            let r=try await Main().Run(Config:config,initialLabels:input.labels)
            result=ProbeResult(mode:mode,n:input.fixture.n,seconds:r.elapsedSeconds,solved:r.best.validation.valid,snapshot:BoardSnapshot(r.best),repairs:r.repairs,attempts:[])
        } else {
            config.exactCoverNodeLimit=250_000;config.exactCoverSolutionLimit=50_000
            let started=ProcessInfo.processInfo.systemUptime,ctx=SearchContext(config:config)
            ctx.deadline=started+budget
            var best=ctx.evaluate(labels:input.labels),attempts:[RepairAttempt]=[]
            while ProcessInfo.processInfo.systemUptime<ctx.deadline && !best.validation.valid {
                let patch=ctx.patchCells(best)
                if patch.isEmpty { break }
                let generationStart=ProcessInfo.processInfo.systemUptime
                var catalog=ctx.regionCatalog(patch:patch,until:min(ctx.deadline,generationStart+0.25),policy:.repair)
                let allowed=Set(patch)
                catalog += ctx.groups(best.labels).filter{Set($0).isSubset(of:allowed)}
                let coverStart=ProcessInfo.processInfo.systemUptime
                let candidate=ctx.cover(patch:patch,base:best.labels,candidates:catalog,until:min(ctx.deadline,coverStart+2))
                let finished=ProcessInfo.processInfo.systemUptime
                let improved=candidate.map{$0.quality<best.quality || $0.validation.valid} ?? false
                if improved { best=candidate! }
                attempts.append(RepairAttempt(seconds:finished-started,patchCells:patch.count,candidateRegions:catalog.count,catalogSeconds:coverStart-generationStart,repairSeconds:finished-coverStart,wrong:best.validation.mismatches.count,error:best.scores.realAIM,improved:improved))
            }
            if let discovered=ctx.bestEvaluated, discovered.quality<best.quality { best=discovered }
            result=ProbeResult(mode:mode,n:input.fixture.n,seconds:ProcessInfo.processInfo.systemUptime-started,solved:best.validation.valid,snapshot:BoardSnapshot(best),repairs:ctx.metrics,attempts:attempts)
        }
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys]
        try e.encode(result).write(to:URL(fileURLWithPath:args[4]+"/result.json"),options:.atomic)
        print("Finished \(input.fixture.n) \(mode), \(result.seconds)s, solved=\(result.solved), wrong=\(result.snapshot.validation.mismatches.count)")
    }
}
