import Foundation
// This policy is compiled only into scratch copies, never into a deployed worker.
enum ExperimentPolicy {
    static let enabled = ProcessInfo.processInfo.environment["EXPERIMENT_REGIONAL"] == "1"
    static func exactField(_ report: ValidationReport, rows: Int, cols: Int) -> [Double] {
        var field=Array(repeating:0.0,count:rows*cols)
        for mismatch in report.mismatches {
            let actual=Double(mismatch.actual ?? -1), target=Double(mismatch.expected)
            let error=actual<0 ? 1 : abs(actual-target)/max(actual,target,1)
            for cell in field.indices {
                let distance=abs(cell/cols-mismatch.cell.row)+abs(cell%cols-mismatch.cell.col)
                field[cell] += error*exp(-Double(distance)/2)
            }
        }
        return field
    }
    static func selfTest() {
        var cold=SearchRandom(seed:1), hot=SearchRandom(seed:1)
        var coldSquare=0.0, hotSquare=0.0
        for _ in 0..<50000 {
            let c=noise(0,rng:&cold), h=noise(1,rng:&hot)
            precondition(abs(c)<=1 && abs(h)<=1)
            coldSquare += c*c; hotSquare += h*h
        }
        precondition(abs(coldSquare/50000-1.0/48)<0.001)
        precondition(abs(hotSquare/50000-1.0/3)<0.01)
        let report=ValidationReport(valid:false,issues:[],capitols:[],mismatches:[
            ClueMismatch(cell:GridCell(row:0,col:0),expected:10,actual:5)],answer:nil)
        let field=exactField(report,rows:5,cols:5)
        precondition(field[0]>field[1] && field[1]>field[24])
        precondition(hotness(field,cell:0)==1 && hotness(field,cell:24)==0)
        precondition(hotness([0,0],cell:0)==0.5)
        print("Policy tests passed: noise variance, bounds, spatial field, normalization.")
    }
    static func hotness(_ field: [Double], cell: Int) -> Double {
        let low=field.min() ?? 0, high=field.max() ?? 0
        return high-low < 1e-12 ? 0.5 : max(0,min(1,(field[cell]-low)/(high-low)))
    }
    static func noise(_ h: Double, rng: inout SearchRandom) -> Double {
        let n=max(1,min(16,Int((16-15*h).rounded())))
        var sum=0.0
        for _ in 0..<n { sum += 2*rng.unit()-1 }
        return sum/Double(n)
    }
    static func breadth(_ h: Double, maximum: Int, rng: inout SearchRandom) -> Int {
        1 + min(maximum-1, Int(abs(noise(h,rng:&rng))*Double(maximum)))
    }
    static func focus(_ field: [Double], available: [Int], rng: inout SearchRandom) -> Int {
        // Preserve exploration when the field is flat or when the exploration draw wins.
        if rng.unit()<0.2 { return available[rng.index(available.count)] }
        let weights=available.map { 0.05+hotness(field,cell:$0) }
        var x=rng.unit()*weights.reduce(0,+)
        for (i,w) in weights.enumerated() { x -= w; if x<0 { return available[i] } }
        return available.last!
    }
}
