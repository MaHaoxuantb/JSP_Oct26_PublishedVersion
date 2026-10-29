import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct Fixture: Codable { let name: String; let n: Int; let clues: [[Int]] }
struct FixtureFile: Codable { let puzzles: [Fixture] }
struct Components: Codable {
    let aim: Double; let symmetry: Double; let discreteness: Double; let total: Double
}
struct State {
    let p: [Double]; let labels: [Int]; let native: Components; let common: Double
    let report: ValidationReport; let field: [Double]
}
struct Snapshot: Codable {
    let relationships: [Double]; let labels: [Int]; let native: Components
    let common: Double; let wrong: Int; let issues: Int; let valid: Bool
    init(_ s: State) { relationships=s.p; labels=s.labels; native=s.native; common=s.common
        wrong=s.report.mismatches.count; issues=s.report.issues.count; valid=s.report.valid }
}
struct ProposalInfo: Codable {
    var focus=0; var hotness=0.0; var n=8; var extent=0.0; var radius=1
    var requestedEdits=0; var changedEdges=0; var changedCells=0
    var topologyChanged=false; var delta: Double?; var probability: Double?; var accepted=false
}
struct Metrics: Codable {
    var attempts=0; var evaluations=0; var accepted=0; var noops=0; var restarts=0
    var nHistogram=Array(repeating:0,count:17)
    var hotCounts=Array(repeating:0,count:10)
    var hotChangedEdges=Array(repeating:0,count:10)
    var changedEdges=0; var radiusSum=0
    var exactSeconds=0.0; var nativeSeconds=0.0; var fieldSeconds=0.0; var proposalSeconds=0.0
    var validationSeconds=0.0
}
struct Record: Codable {
    let kind: String; let seconds: Double; let cpuSeconds: Double
    let current: Snapshot; let nativeBest: Snapshot; let exactBest: Snapshot
    let metrics: Metrics; let proposal: ProposalInfo?
}
struct Checkpoint: Codable {
    let fixture: String; let representation: String; let regional: Bool; let seed: UInt64
    let seconds: Double; let proposalIndex: Int; let epochAttempts: Int; let stagnation: Int
    let epochBest: Double; let current: Snapshot; let nativeBest: Snapshot; let exactBest: Snapshot
    let metrics: Metrics
}
struct Result: Codable {
    let fixture: String; let representation: String; let regional: Bool; let seed: UInt64
    let cutoffSeconds: Double; let seconds: Double; let cpuSeconds: Double; let solved: Bool
    let reason: String; let solution: Snapshot?; let current: Snapshot; let nativeBest: Snapshot
    let exactBest: Snapshot; let initial: Snapshot; let metrics: Metrics
}

struct Draws {
    let seed: UInt64; let proposal: Int
    func unit(_ channel: Int, _ item: Int=0, _ draw: Int=0) -> Double {
        var z=seed ^ (UInt64(proposal) &* 0x9e3779b97f4a7c15)
            ^ (UInt64(channel+1) &* 0xd1b54a32d192ed03)
            ^ (UInt64(item+1) &* 0x94d049bb133111eb)
            ^ (UInt64(draw+1) &* 0xbf58476d1ce4e5b9)
        z=(z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z=(z ^ (z >> 27)) &* 0x94d049bb133111eb
        z ^= z >> 31
        return Double(z >> 11)/9_007_199_254_740_992
    }
    func index(_ count: Int, _ channel: Int, _ item: Int=0) -> Int {
        min(count-1,Int(unit(channel,item)*Double(count)))
    }
    func average(_ n: Int, _ channel: Int, _ item: Int=0) -> Double {
        var sum=0.0
        for j in 0..<16 { let value=2*unit(channel,item,j)-1; if j<n { sum += value } }
        return sum/Double(n)
    }
}

final class ExperimentKernel {
    let fixture: Fixture; let continuous: Bool; let regional: Bool; let seed: UInt64
    let grid: Grid; let pairs: [(Int,Int)]; let context: SearchContext; let energy=Energy()
    let clueCells: [Int]; let diffusion: [[(Int,Double)]]
    var metrics=Metrics()
    init(fixture: Fixture, continuous: Bool, regional: Bool, seed: UInt64) {
        self.fixture=fixture; self.continuous=continuous; self.regional=regional; self.seed=seed
        let n=fixture.n; grid=Grid(rows:n,cols:n)
        var edges:[(Int,Int)]=[]
        for c in 0..<(n*n) {
            if c%n+1<n { edges.append((c,c+1)) }
            if c+n<n*n { edges.append((c,c+n)) }
        }
        pairs=edges
        var config=RunConfig.example; config.rowNum=n; config.colNum=n
        config.Target=OriginalCondition(Status:fixture.clues); config.pathEvaluation = .cpu
        context=SearchContext(config:config)
        let clues=(0..<(n*n)).filter { fixture.clues[$0/n][$0%n]>=0 }; clueCells=clues
        diffusion=(0..<(n*n)).map { cell in
            clues.compactMap { c -> (Int,Double)? in
                let d=abs(c/n-cell/n)+abs(c%n-cell%n)
                return d<=2 ? (c,exp(-Double(d)/2)) : nil
            }
        }
    }
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    static func cpu() -> Double { Double(clock())/Double(CLOCKS_PER_SEC) }
    static func reflect(_ x: Double) -> Double {
        let v=x.truncatingRemainder(dividingBy:2)
        let a=v<0 ? v+2 : v
        return a>1 ? 2-a : a
    }
    func decode(_ p: [Double]) -> [Int] {
        var parent=Array(0..<grid.count)
        func root(_ x:Int)->Int { var c=x; while parent[c] != c { c=parent[c] }; return c }
        for (i,e) in pairs.enumerated() where p[i]>=0.5 { parent[root(e.1)]=root(e.0) }
        return context.normalized(parent.indices.map { root($0) })
    }
    func encode(_ labels:[Int],soft:Bool=false)->[Double] {
        pairs.map { e in labels[e.0]==labels[e.1] ? (soft ? 0.9:1) : (soft ? 0.1:0) }
    }
    func initial(_ restart:Int)->[Double] {
        var rng=SearchRandom(seed:seed ^ (UInt64(restart+1) &* 0xa0761d6478bd642f))
        let regions=min(grid.count,3+rng.index(min(7,grid.count-2)))
        let parts=grid.partition(Array(0..<grid.count),regions:regions,rng:&rng)
        var ids:[UUID:Int]=[:]
        let labels=(0..<grid.count).map { c -> Int in
            let id=parts[c]!; if ids[id]==nil { ids[id]=ids.count }; return ids[id]!
        }
        return encode(labels,soft:continuous)
    }
    func evaluate(_ p:[Double])->State {
        let labels=decode(p); let start=Self.now()
        let exact=context.evaluate(labels:labels)
        metrics.exactSeconds += Self.now()-start
        let nativeStart=Self.now(); var a=Array(repeating:0.0,count:grid.count)
        var s=a; var q=a; let native:Components
        if continuous {
            let board=context.board(labels:labels)
            for (i,e) in pairs.enumerated() {
                if e.1==e.0+1 { board.Relationships.VerticalRelationships[e.0/fixture.n][e.0%fixture.n]=p[i] }
                else { board.Relationships.HorizontalRelationships[e.0/fixture.n][e.0%fixture.n]=p[i] }
            }
            a=energy.RealAIMTest(Board:board,Target:context.config.Target).flatMap{$0}
            s=energy.SymmetricalTest(Board:board).flatMap{$0}
            q=energy.DiscretenessTest(Board:board).flatMap{$0}
            let aim=clueCells.reduce(0.0){$0+a[$1]}/Double(clueCells.count)
            let sym=s.reduce(0,+)/Double(grid.count), disc=q.reduce(0,+)/Double(grid.count)
            native=Components(aim:aim,symmetry:sym,discreteness:disc,total:(2*aim+sym+2*disc)/5)
        } else {
            for mismatch in exact.validation.mismatches {
                let c=mismatch.cell.row*fixture.n+mismatch.cell.col
                a[c]=mismatch.actual.map { abs(Double($0)-Double(mismatch.expected))/max(Double($0),Double(mismatch.expected),1) } ?? 1
            }
            for cells in context.groups(labels) {
                let geometry=context.regions.geometry(cells)
                if !geometry.connected || !geometry.symmetric { for c in cells { s[c]=1 } }
            }
            native=Components(aim:exact.scores.realAIM,symmetry:exact.scores.symmetry,discreteness:0,
                              total:(2*exact.scores.realAIM+exact.scores.symmetry)/3)
        }
        metrics.nativeSeconds += Self.now()-nativeStart
        let fieldStart=Self.now()
        let field=(0..<grid.count).map { c -> Double in
            let weights=diffusion[c]
            let total=weights.reduce(0.0){$0+$1.1}
            let local=total>0 ? weights.reduce(0.0){$0+a[$1.0]*$1.1}/total : 0
            return (2*local+s[c]+2*q[c])/5
        }
        let smooth=(0..<grid.count).map { c -> Double in
            let near=[c]+grid.neighbors(c)
            return near.reduce(0.0){$0+field[$1]}/Double(near.count)
        }
        metrics.fieldSeconds += Self.now()-fieldStart; metrics.evaluations += 1
        return State(p:p,labels:labels,native:native,common:(2*exact.scores.realAIM+exact.scores.symmetry)/3.25,
                     report:exact.validation,field:smooth)
    }
    func verified(_ state:State)->Bool {
        guard state.report.valid else { return false }
        let start=Self.now()
        let report=ExactValidator().validate(context.board(labels:state.labels),target:context.config.Target)
        metrics.validationSeconds += Self.now()-start
        precondition(report.valid)
        return true
    }
    func propose(_ current:State,at index:Int)->([Double],ProposalInfo) {
        let started=Self.now(); defer { metrics.proposalSeconds += Self.now()-started }
        let draws=Draws(seed:seed,proposal:index)
        let low=current.field.min()!, high=current.field.max()!
        let flat=high-low<1e-12
        let hot=flat ? Array(repeating:0.0,count:grid.count) : current.field.map{($0-low)/(high-low)}
        var focus=draws.index(grid.count,1)
        if regional && !flat {
            let sum=hot.reduce(0.0){$0+0.05+$1}
            var choice=draws.unit(1)
            for c in 0..<grid.count {
                choice -= 0.2/Double(grid.count)+0.8*(0.05+hot[c])/sum
                if choice<=0 { focus=c; break }
            }
        }
        let n=regional && !flat ? max(1,min(16,Int((16-15*hot[focus]).rounded()))) : 8
        let extent=draws.average(n,2)
        let radius=min(fixture.n-1,1+Int(Double(fixture.n-1)*abs(extent)))
        let patch=Set((0..<grid.count).filter { abs($0/fixture.n-focus/fixture.n)+abs($0%fixture.n-focus%fixture.n)<=radius })
        let edges=pairs.indices.filter { patch.contains(pairs[$0].0) && patch.contains(pairs[$0].1) }
        let kmax=min(edges.count,Int(ceil(Double(pairs.count)/4)))
        precondition(kmax>0)
        let k=min(kmax,1+Int(Double(kmax)*abs(extent)))
        var proposed=current.p
        if continuous {
            let selected=edges.sorted { draws.unit(3,$0)<draws.unit(3,$1) }.prefix(k)
            for edge in selected {
                if draws.unit(5,edge)<0.1 { proposed[edge]=draws.unit(6,edge)<0.5 ? 0:1 }
                else { proposed[edge]=Self.reflect(proposed[edge]+draws.average(n,4,edge)) }
            }
        } else {
            var labels=current.labels
            let eligible=patch.filter { c in grid.neighbors(c).allSatisfy { patch.contains($0) } }
                .sorted { draws.unit(3,$0)<draws.unit(3,$1) }
            precondition(!eligible.isEmpty)
            let family=draws.unit(7)
            let fresh=(labels.max() ?? 0)+1
            if family<0.65 {
                for cell in eligible.prefix(k) {
                    let destinations=grid.neighbors(cell).map{labels[$0]}.filter{$0 != labels[cell]}
                    if destinations.isEmpty || draws.unit(8,cell)<0.2 { labels[cell]=fresh+cell }
                    else { labels[cell]=destinations[draws.index(destinations.count,9,cell)] }
                }
            } else if family<0.85 {
                let donor=labels[focus]
                for cell in eligible.filter({labels[$0]==donor}).prefix(k) { labels[cell]=fresh }
            } else {
                let donor=labels[focus]
                let cells=labels.indices.filter{labels[$0]==donor}
                let allowed=Set(eligible)
                let adjacent=grid.neighbors(focus).filter{labels[$0] != donor}
                if cells.count<=k && cells.allSatisfy({allowed.contains($0)}) && !adjacent.isEmpty {
                    let target=labels[adjacent[draws.index(adjacent.count,10)]]
                    for cell in cells { labels[cell]=target }
                } else {
                    let cell=eligible[0], near=grid.neighbors(eligible[0])
                    labels[cell]=draws.unit(11)<0.5 ? fresh : labels[near[draws.index(near.count,12)]]
                }
            }
            proposed=encode(decode(encode(labels)))
        }
        for edge in pairs.indices where !edges.contains(edge) { precondition(proposed[edge]==current.p[edge],"Changed an outside-patch relationship") }
        let labels=decode(proposed)
        // Cell membership changes are invariant to arbitrary component numbering.
        let changedCells=labels.indices.filter { c in
            labels.indices.contains { d in (labels[c]==labels[d]) != (current.labels[c]==current.labels[d]) }
        }.count
        var info=ProposalInfo(); info.focus=focus; info.hotness=hot[focus]; info.n=n
        info.extent=extent; info.radius=radius; info.requestedEdits=k
        info.changedEdges=pairs.indices.filter{proposed[$0] != current.p[$0]}.count
        info.changedCells=changedCells; info.topologyChanged=labels != current.labels
        metrics.nHistogram[n] += 1; metrics.radiusSum += radius; metrics.changedEdges += info.changedEdges
        let bin=min(9,Int(info.hotness*10)); metrics.hotCounts[bin] += 1
        metrics.hotChangedEdges[bin] += info.changedEdges
        return (proposed,info)
    }
}

@main struct RegionalExperiment {
    static func run(_ args:[String]) throws {
        precondition(args.count==8,"fixture-json index continuous regional seed seconds output")
        let fixtures=try JSONDecoder().decode(FixtureFile.self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
        let fixture=fixtures.puzzles[Int(args[2])!], continuous=args[3]=="1", regional=args[4]=="1"
        let seed=UInt64(args[5])!, limit=Double(args[6])!, directory=URL(fileURLWithPath:args[7])
        precondition(limit.isFinite && limit>0)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let logfile=directory.appendingPathComponent("energy.jsonl")
        precondition(!FileManager.default.fileExists(atPath:logfile.path),"Refusing to overwrite trial")
        FileManager.default.createFile(atPath:logfile.path,contents:nil)
        let handle=try FileHandle(forWritingTo:logfile); defer { try? handle.close() }
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        let start=ExperimentKernel.now(), cpu=ExperimentKernel.cpu()
        let kernel=ExperimentKernel(fixture:fixture,continuous:continuous,regional:regional,seed:seed)
        var current=kernel.evaluate(kernel.initial(0)), nativeBest=current, exactBest=current
        let initial=Snapshot(current)
        var solution:State?=kernel.verified(current) ? current:nil
        var proposalIndex=0,epochAttempts=0,stagnation=0
        var epochBest=current.native.total, lastLog=0.0, lastCheckpoint=0.0
        func elapsed()->Double { ExperimentKernel.now()-start }
        func log(_ kind:String,_ info:ProposalInfo?=nil) throws {
            let record=Record(kind:kind,seconds:elapsed(),cpuSeconds:ExperimentKernel.cpu()-cpu,current:Snapshot(current),
                              nativeBest:Snapshot(nativeBest),exactBest:Snapshot(exactBest),metrics:kernel.metrics,proposal:info)
            var data=try encoder.encode(record); data.append(10); try handle.write(contentsOf:data)
            lastLog=elapsed()
        }
        func checkpoint() throws {
            let saved=Checkpoint(fixture:fixture.name,representation:continuous ? "continuous":"discrete",regional:regional,seed:seed,
                seconds:elapsed(),proposalIndex:proposalIndex,epochAttempts:epochAttempts,stagnation:stagnation,epochBest:epochBest,
                current:Snapshot(current),nativeBest:Snapshot(nativeBest),exactBest:Snapshot(exactBest),metrics:kernel.metrics)
            try encoder.encode(saved).write(to:directory.appendingPathComponent("checkpoint.json"),options:.atomic)
            lastCheckpoint=elapsed()
        }
        try log("initialized"); try checkpoint()
        while solution==nil && elapsed()<limit {
            proposalIndex += 1; epochAttempts += 1; kernel.metrics.attempts += 1
            let (p,detail)=kernel.propose(current,at:proposalIndex); var info=detail
            var improved=false
            if p==current.p { kernel.metrics.noops += 1 }
            else {
                let candidate=kernel.evaluate(p)
                let delta=candidate.native.total-current.native.total
                let temperature=max(0.0005,0.03*pow(0.9995,Double(epochAttempts)))
                let probability=delta<=0 ? 1:exp(-delta/temperature)
                info.delta=delta; info.probability=probability
                let valid=kernel.verified(candidate)
                info.accepted=valid || Draws(seed:seed,proposal:proposalIndex).unit(20)<probability
                if info.accepted { current=candidate; kernel.metrics.accepted += 1 }
                if candidate.native.total<nativeBest.native.total-1e-14 { nativeBest=candidate; improved=true }
                if candidate.common<exactBest.common-1e-14 { exactBest=candidate; improved=true }
                if valid { solution=candidate; current=candidate; nativeBest=candidate; exactBest=candidate }
            }
            stagnation += 1
            if current.native.total<epochBest-1e-14 { epochBest=current.native.total; stagnation=0 }
            if improved || solution != nil || elapsed()-lastLog>=1 { try log(solution != nil ? "solved":improved ? "improved":"progress",info) }
            if elapsed()-lastCheckpoint>=10 { try checkpoint() }
            if stagnation>=5000 && elapsed()<limit && solution==nil {
                kernel.metrics.restarts += 1
                current=kernel.evaluate(kernel.initial(kernel.metrics.restarts)); epochBest=current.native.total
                epochAttempts=0; stagnation=0
                if current.native.total<nativeBest.native.total { nativeBest=current }
                if current.common<exactBest.common { exactBest=current }
                if kernel.verified(current) { solution=current; nativeBest=current; exactBest=current }
                try log("restarted")
            }
        }
        try log(solution==nil ? "cutoff":"solved"); try checkpoint(); try handle.synchronize()
        let result=Result(fixture:fixture.name,representation:continuous ? "continuous":"discrete",regional:regional,seed:seed,
            cutoffSeconds:limit,seconds:elapsed(),cpuSeconds:ExperimentKernel.cpu()-cpu,solved:solution != nil,
            reason:solution==nil ? "cutoff":"solved",solution:solution.map{Snapshot($0)},current:Snapshot(current),
            nativeBest:Snapshot(nativeBest),exactBest:Snapshot(exactBest),initial:initial,metrics:kernel.metrics)
        try encoder.encode(result).write(to:directory.appendingPathComponent("result.json"),options:.atomic)
        print("\(fixture.n)x\(fixture.n) \(result.representation) regional=\(regional) solved=\(result.solved) seconds=\(result.seconds) exact=\(exactBest.common)")
    }
    static func selfTest() {
        let fixture=Fixture(name:"test",n:5,clues:[[12,-1,-1,-1,17],[8,-1,6,3,-1],[-1,-1,-1,-1,-1],[-1,7,6,-1,10],[25,-1,-1,-1,0]])
        let k=ExperimentKernel(fixture:fixture,continuous:false,regional:true,seed:100)
        let c=ExperimentKernel(fixture:fixture,continuous:true,regional:true,seed:100)
        let rows=["ABBCC","ABBDC","AADDC","CAAAC","CCCCC"]
        let witness=rows.flatMap{$0.utf8.map(Int.init)}
        let solved=k.evaluate(k.encode(witness)); precondition(k.verified(solved) && solved.common==0)
        let cont=c.evaluate(c.encode(witness)); precondition(c.verified(cont) && cont.native.total<1e-12)
        precondition(k.decode(k.initial(0))==c.decode(c.initial(0)))
        for x in [-7.3,-1.0,-0.1,0,0.2,1,1.2,4.3] { precondition((0...1).contains(ExperimentKernel.reflect(x))) }
        for n in [1,2,4,8,16] {
            let count=40000; var sum=0.0,squares=0.0
            for i in 0..<count { let x=Draws(seed:1,proposal:i).average(n,2); sum+=x; squares+=x*x }
            precondition(abs(sum/Double(count))<0.012)
            precondition(abs(squares/Double(count)-1/(3*Double(n)))<0.007)
        }
        for continuous in [false,true] {
            let a=ExperimentKernel(fixture:fixture,continuous:continuous,regional:false,seed:7)
            let b=ExperimentKernel(fixture:fixture,continuous:continuous,regional:true,seed:7)
            precondition(a.initial(0)==b.initial(0))
            var state=a.evaluate(a.initial(0))
            let flat=State(p:state.p,labels:state.labels,native:state.native,common:state.common,report:state.report,field:Array(repeating:0.3,count:25))
            let p1=a.propose(flat,at:1),p2=b.propose(flat,at:1)
            precondition(p1.0==p2.0 && p1.1.n==8 && p2.1.n==8)
            for i in 1...500 {
                let (p,info)=b.propose(state,at:i)
                precondition((1...16).contains(info.n))
                if !continuous { precondition(p.allSatisfy{$0==0 || $0==1}); precondition(p==b.encode(b.decode(p))) }
                state=b.evaluate(p)
            }
        }
        print("Passed distribution moments, exact witness checks, matched starts, flat policy, reflection, binary canonicalization and outside-patch invariants.")
    }
    static func main() throws {
        if CommandLine.arguments.dropFirst().first=="--self-test" { selfTest(); return }
        try run(CommandLine.arguments)
    }
}
