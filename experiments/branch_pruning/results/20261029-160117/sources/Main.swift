import Foundation
@main struct Experiment {
    static func save<T:Encodable>(_ value:T,_ path:String) throws {
        let e=JSONEncoder(); e.outputFormatting=[.prettyPrinted,.sortedKeys]
        try e.encode(value).write(to:URL(fileURLWithPath:path),options:.atomic)
    }
    static func main() throws {
        let a=CommandLine.arguments
        if a[1]=="--make" {
            let old=try JSONDecoder().decode(Fixtures.self,from:Data(contentsOf:URL(fileURLWithPath:a[2]))).puzzles
            var fixtures=old, witnesses:[Puzzle]=[]
            for n in [4,6] {
                let p=Puzzle.make(n:n,seed:UInt64(n*1000+101),clueCount:Int((Double(n*n)*33/121).rounded()))
                witnesses.append(p)
                fixtures.append(Fixture(n:n,name:"generated\(n)_\(n*1000+101)_clues\(p.clues.flatMap{$0}.filter{$0>=0}.count)",clues:p.clues))
            }
            try save(Fixtures(puzzles:fixtures.sorted{$0.n<$1.n}),a[3]+"/fixtures.json")
            try save(witnesses,a[3]+"/maker-witnesses.json")
            return
        }
        if a[1]=="--self-test" {
            var tests=0, partitions=0
            for n in [2,3] {
                let f=Fixture(n:n,name:"catalog-test",clues:Array(repeating:Array(repeating:-1,count:n),count:n))
                let generated=BranchSolver(f,seconds:60); generated.filterCatalog=false
                generated.catalog(maxSize:n*n,seconds:60,unbounded:true)
                precondition(generated.catalogComplete)
                let brute=BranchSolver(f,seconds:60); brute.filterCatalog=false
                for mask in UInt64(1)..<(UInt64(1)<<(n*n)) { brute.add(mask) }
                precondition(Set(generated.shapes.map{$0.mask})==Set(brute.shapes.map{$0.mask}))
                tests += 1
            }
            for seed in 1...6 {
                let n=3,p=Puzzle.make(n:3,seed:UInt64(seed),clueCount:seed%3+1)
                let f=Fixture(n:n,name:"pruning-test",clues:p.clues)
                let baseline=BranchSolver(f,seconds:60)
                baseline.filterCatalog=false; baseline.pruning=false; baseline.stopAtFirst=false
                for mask in UInt64(1)..<(UInt64(1)<<9) { baseline.add(mask) }
                baseline.search()
                let pruned=BranchSolver(f,seconds:60); pruned.stopAtFirst=false
                pruned.catalog(maxSize:9,seconds:60,unbounded:true); pruned.search()
                precondition(clockNow()<baseline.deadline && clockNow()<pruned.deadline)
                precondition(!baseline.solutions.isEmpty && baseline.solutions==pruned.solutions,"pruning changed solutions seed \(seed)")
                partitions += baseline.solutions.count; tests += 1
            }
            print("PASS \(tests) exhaustive checks; \(partitions) satisfying partitions preserved")
            return
        }
        let fixture=try JSONDecoder().decode(Fixtures.self,from:Data(contentsOf:URL(fileURLWithPath:a[1]))).puzzles[Int(a[2])!]
        let budget=Double(a[3])!, solver=BranchSolver(fixture,seconds:budget)
        solver.catalog(maxSize:fixture.n*fixture.n,seconds:min(45,budget*0.15),unbounded:fixture.n<=4)
        print("catalog n=\(fixture.n) shapes=\(solver.shapes.count) seconds=\(solver.catalogSeconds) complete=\(solver.catalogComplete)"); fflush(stdout)
        solver.diagnosticCompletion(0,0)
        solver.search()
        try save(solver.result(budget:budget),a[4])
        print("finished n=\(fixture.n) solved=\(solver.solution != nil) seconds=\(clockNow()-solver.started) nodes=\(solver.counters.nodes)")
    }
}
