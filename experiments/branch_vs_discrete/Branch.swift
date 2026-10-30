import Foundation
#if WIDE_BOARD
typealias CellBits = UInt128
#else
typealias CellBits = UInt64
#endif

struct Fixture: Codable { let n: Int; let name: String; let clues: [[Int]] }
struct Fixtures: Codable { let puzzles: [Fixture] }
struct Shape { let mask: CellBits; let cells: [Int]; let cap: Int; var size: Int { cells.count } }
func clockNow() -> Double { ProcessInfo.processInfo.systemUptime }
func cellsOf(_ mask: CellBits) -> [Int] {
    var x=mask, out:[Int]=[]
    while x != 0 { let c=x.trailingZeroBitCount; out.append(c); x &= x-1 }
    return out
}
struct Counters: Codable {
    var nodes=0, coveragePrunes=0, distancePrunes=0, complete=0, catalogVisited=0, catalogJobsTruncated=0, diagnosticCompletions=0, maxDepth=0
}
struct Observation: Codable { let seconds: Double; let wrongClues: Int; let energy: Double }
struct Result: Codable {
    let n: Int; let name: String; let budgetSeconds: Double; let seconds: Double; let catalogSeconds: Double
    let solved: Bool; let reason: String; let shapeCount: Int; let maxRegionSize: Int
    let catalogComplete: Bool; let counters: Counters; let labels: [[Int]]?; let observations: [Observation]
}
final class BranchSolver {
    let fixture: Fixture, n: Int, count: Int, grid: Grid, clues: [Int], full: CellBits
    let started=clockNow(); var deadline: Double
    var shapes:[Shape]=[], byCell:[[Int]], known=Set<CellBits>()
    var sizes:[Int], labels:[Int], caps:[Int]=[]
    var counters=Counters(), solution:[Int]?=nil, best:[Int]?=nil, bestEnergy=Double.infinity
    var observations:[Observation]=[], pruning=true, stopAtFirst=true, solutions=Set<String>()
    var filterCatalog=true
    var nextProgress=0.0
    var catalogSeconds=0.0, catalogComplete=true, maxRegionSize=0
    init(_ fixture: Fixture, seconds: Double) {
        self.fixture=fixture; n=fixture.n; count=n*n; grid=Grid(rows:n,cols:n)
        precondition(count<CellBits.bitWidth, "Board exceeds mask capacity")
        clues=fixture.clues.flatMap{$0}; full=(CellBits(1)<<count)-1
        deadline=started+seconds; byCell=Array(repeating:[],count:count)
        sizes=Array(repeating:0,count:count); labels=Array(repeating:-1,count:count)
    }
    func add(_ mask: CellBits) {
        guard !known.contains(mask) else { return }; known.insert(mask)
        let cells=cellsOf(mask)
        guard grid.connected(cells) else { return }
        let geometry=Rules.geometry(cells,n:n)
        guard geometry.symmetric else { return }
        let cap=geometry.capitol ?? -1
        if filterCatalog {
        for c in cells {
            if clues[c]==0 && c != cap { return }
            if c==cap && clues[c]>0 { return }
            // Adjacent clue differences bound the cost of their common edge.
            if clues[c]>=0 {
                for v in grid.neighbors(c) where clues[v]>=0 {
                    if abs(clues[c]-clues[v])>cells.count { return }
                }
            }
        }
        if cap>=0 {
            var distances=Array(repeating:999999,count:count); distances[cap]=0
            var q=[cap], head=0
            while head<q.count {
                let c=q[head]; head += 1
                for v in grid.neighbors(c) where mask & (CellBits(1)<<v) != 0 && distances[v]==999999 {
                    distances[v]=distances[c]+cells.count; q.append(v)
                }
            }
            // Any internal route to this permanent capitol survives completion.
            if cells.contains(where:{clues[$0]>distances[$0]}) { return }
        }
        }
        let id=shapes.count; shapes.append(Shape(mask:mask,cells:cells,cap:cap))
        for c in cells { byCell[c].append(id) }
    }
    // Enumerate invariant unions of cell orbits in each tight bounding rectangle.
    // Per-job quotas prevent the largest rectangles consuming the whole budget.
    func catalog(maxSize: Int, seconds: Double, unbounded: Bool=false) {
        maxRegionSize=maxSize
        let until=min(deadline,clockNow()+seconds)
        struct Job { let r:Int,c:Int,h:Int,w:Int,t:Int }
        var jobs:[Job]=[]
        for h in 1...n { for w in 1...n { for r in 0...(n-h) { for c in 0...(n-w) {
            var rect:CellBits=0
            for y in r..<(r+h) { for x in c..<(c+w) { rect |= CellBits(1)<<(y*n+x) } }
            if h*w<=maxSize { add(rect) }
            for t in [2,4,5]+(h==w ? [1,6,7] : []) { jobs.append(Job(r:r,c:c,h:h,w:w,t:t)) }
        }}}}
        jobs.sort { $0.h*$0.w < $1.h*$1.w }
        for (jobIndex,j) in jobs.enumerated() {
            if clockNow()>=until { counters.catalogJobsTruncated += jobs.count-jobIndex; catalogComplete=false; break }
            let jobEnd=unbounded ? until : min(until,clockNow()+max(0.003,(until-clockNow())/Double(jobs.count-jobIndex)))
            var orbits:[CellBits]=[], seen:CellBits=0
            for y in 0..<j.h { for x in 0..<j.w {
                let cell=(j.r+y)*n+j.c+x
                if seen & (CellBits(1)<<cell) != 0 { continue }
                var a=y,b=x,mask:CellBits=0
                repeat {
                    mask |= CellBits(1)<<((j.r+a)*n+j.c+b)
                    switch j.t {
                    case 1: (a,b)=(b,j.h-1-a)
                    case 2: (a,b)=(j.h-1-a,j.w-1-b)
                    case 4: b=j.w-1-b
                    case 5: a=j.h-1-a
                    case 6: (a,b)=(b,a)
                    default: (a,b)=(j.h-1-b,j.w-1-a)
                    }
                } while a != y || b != x
                seen |= mask; orbits.append(mask)
            }}
            var ticks=0, truncated=false
            func visit(_ i:Int,_ mask:CellBits,_ size:Int) {
                ticks += 1
                if ticks & 255 == 0 && clockNow()>=jobEnd { truncated=true }
                if truncated { return }
                if i==orbits.count {
                    counters.catalogVisited += 1
                    if mask==0 { return }
                    let cells=cellsOf(mask)
                    if cells.map({$0/n}).min() != j.r || cells.map({$0/n}).max() != j.r+j.h-1 || cells.map({$0%n}).min() != j.c || cells.map({$0%n}).max() != j.c+j.w-1 { return }
                    add(mask); return
                }
                // Include first, to avoid biasing a truncated job toward tiny shapes.
                let extra=orbits[i].nonzeroBitCount
                if size+extra<=maxSize { visit(i+1,mask|orbits[i],size+extra) }
                visit(i+1,mask,size)
            }
            visit(0,0,0)
            if truncated { counters.catalogJobsTruncated += 1; catalogComplete=false }
        }
        catalogSeconds=clockNow()-started
        if maxSize<count { catalogComplete=false }
        // Larger regions first, with a stable mask tie-break; never consult witnesses.
        for c in 0..<count { byCell[c].sort {
            let a=shapes[$0],b=shapes[$1]
            return a.size != b.size ? a.size>b.size : a.mask<b.mask
        }}
    }
    func distances(_ weights:[Int], sources:[Int]) -> [Int] {
        var d=Array(repeating:999999,count:count), visited:CellBits=0
        for c in sources { d[c]=0 }
        for _ in 0..<count {
            var next = -1, value=999999
            for c in 0..<count where visited & (CellBits(1)<<c)==0 && d[c]<value { next=c; value=d[c] }
            if next<0 { break }; visited |= CellBits(1)<<next
            for v in grid.neighbors(next) { d[v]=min(d[v],value+min(weights[next],weights[v])) }
        }
        return d
    }
    func feasible(_ occupied:CellBits) -> Bool {
        let remaining=count-occupied.nonzeroBitCount
        var low=sizes, high=sizes, potential=caps
        for c in 0..<count where sizes[c]==0 {
            low[c]=1; high[c]=remaining
            if clues[c]<=0 { potential.append(c) }
        }
        // More sources and smaller edges => admissible lower distance bound.
        let lower=distances(low,sources:potential)
        // Known capitols and larger edges => admissible upper distance bound.
        let upper=distances(high,sources:caps)
        for c in 0..<count where clues[c]>=0 {
            if lower[c]>clues[c] || upper[c]<clues[c] { return false }
        }
        return true
    }
    func retain() {
        counters.complete += 1
        guard !caps.isEmpty else { return }
        let d=distances(sizes,sources:caps)
        var wrong=0,energy=0.0,k=0
        for c in 0..<count where clues[c]>=0 {
            k += 1; if d[c] != clues[c] { wrong += 1 }
            energy += Double(abs(d[c]-clues[c]))/Double(max(1,max(d[c],clues[c])))
        }
        energy=2*energy/Double(max(k,1))/3.25
        if energy<bestEnergy {
            bestEnergy=energy; best=labels
            observations.append(Observation(seconds:clockNow()-started,wrongClues:wrong,energy:energy))
            print("incumbent n=\(n) t=\(clockNow()-started) wrong=\(wrong) energy=\(energy)"); fflush(stdout)
        }
        if wrong==0 {
            solution=labels
            // Canonical labels for exhaustive pruning equivalence tests.
            var ids:[Int:Int]=[:]
            let canonical=labels.map { x -> String in if ids[x]==nil { ids[x]=ids.count }; return String(ids[x]!) }.joined(separator:",")
            solutions.insert(canonical)
        }
    }
    func diagnosticCompletion(_ occupied:CellBits,_ depth:Int) {
        let remaining=cellsOf(full ^ occupied), previousCaps=caps
        for c in remaining { sizes[c]=1; labels[c]=depth+c }
        caps += remaining
        retain(); counters.complete -= 1; counters.diagnosticCompletions += 1
        caps=previousCaps
        for c in remaining { sizes[c]=0; labels[c] = -1 }
    }
    func search(_ occupied:CellBits=0,_ depth:Int=0) {
        counters.nodes += 1
        counters.maxDepth=max(counters.maxDepth,depth)
        if clockNow()-started>=nextProgress {
            print("progress n=\(n) t=\(clockNow()-started) nodes=\(counters.nodes) depth=\(counters.maxDepth) distancePrunes=\(counters.distancePrunes)"); fflush(stdout)
            nextProgress=clockNow()-started+10
        }
        if clockNow()>=deadline || (stopAtFirst && solution != nil) { return }
        if pruning && !feasible(occupied) { counters.distancePrunes += 1; return }
        if occupied==full { retain(); return }
        if stopAtFirst && counters.nodes & 2047 == 0 { diagnosticCompletion(occupied,depth); if stopAtFirst && solution != nil { return } }
        var options:[Int]=[], smallest=Int.max
        for c in 0..<count where occupied & (CellBits(1)<<c)==0 {
            let available=byCell[c].filter{ shapes[$0].mask & occupied==0 }
            if available.isEmpty { counters.coveragePrunes += 1; return }
            if available.count<smallest { smallest=available.count; options=available }
        }
        for id in options {
            let s=shapes[id]
            for c in s.cells { sizes[c]=s.size; labels[c]=depth }
            if s.cap>=0 { caps.append(s.cap) }
            search(occupied|s.mask,depth+1)
            if s.cap>=0 { caps.removeLast() }
            for c in s.cells { sizes[c]=0; labels[c] = -1 }
            if clockNow()>=deadline || (stopAtFirst && solution != nil) { return }
        }
    }
    func result(budget:Double) -> Result {
        let elapsed=clockNow()-started
        let chosen=solution ?? best
        return Result(n:n,name:fixture.name,budgetSeconds:budget,seconds:elapsed,catalogSeconds:catalogSeconds,
            solved:solution != nil,reason:solution != nil ? "solved" : elapsed>=budget ? "time_limit" : "catalog_exhausted",
            shapeCount:shapes.count,maxRegionSize:maxRegionSize,catalogComplete:catalogComplete,counters:counters,
            labels:chosen.map{ values in (0..<n).map{Array(values[($0*n)..<(($0+1)*n)])} }, observations:observations)
    }
}
