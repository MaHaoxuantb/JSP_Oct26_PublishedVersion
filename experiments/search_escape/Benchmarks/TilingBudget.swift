// JSP-Oct26-Structural-Search; ©2026 ThomasB. Author: ThomasB.
// Isolated deadline-overhead check, not a solver-time benchmark.
import Foundation
import PuzzleRules
import ShapeDomain
import SolverCore
import EscapePolicies

@main struct TilingBudget {
 struct Seed:Decodable {let puzzle:Puzzle}
 static func main()throws {
  let p=try JSONDecoder().decode(Seed.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))).puzzle
  let bank=StructuralCatalog(puzzle:p,templates:try ShapeStore.read(CommandLine.arguments[2]))
  var rng=SplitMix(seed:2026103111),extra:[CellMask]=[],seen=Set<CellMask>()
  for _ in 0..<10000 {
   if let m=StructuralRegions.large(deductions:bank.deductions,rng:&rng),seen.insert(m).inserted {extra.append(m)}
   if extra.count==256 {break}
  }
  guard extra.count==256 else{throw BenchError("Could not fill benchmark bank")}
  let cell=p.clues.firstIndex(of:-1)!,base=Array(0..<p.grid.count),mask=CellMask(cells:[cell])
  var nodes=0,completed=0,allIdentity=true;let start=monotonic(),cpu=ResourceUse.threadCPUSeconds()
  for i in 0..<20 {
   var stream=SplitMix(seed:UInt64(i)),count=0
   let value=StructuralRegions.tile(released:mask,forced:nil,base:base,catalog:bank,extra:extra,until:monotonic()+0.04,rng:&stream,nodes:&count)
   nodes+=count
   if let value {completed+=1;allIdentity=allIdentity && value==base}
  }
  let result:[String:Any]=["trials":20,"extraRegions":extra.count,"budgetPerCall":0.04,"completed":completed,"nodes":nodes,"identityResults":allIdentity,"seconds":monotonic()-start,"cpuSeconds":ResourceUse.threadCPUSeconds()-cpu]
  print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
 }
}
