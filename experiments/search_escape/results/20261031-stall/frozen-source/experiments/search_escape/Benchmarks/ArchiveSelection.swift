// JSP-Oct26-Search-Escape; ©2026 ThomasB. Author: ThomasB.
// Compile against shared modules; pass the recorded 17-board JSON file.
import Foundation
import PuzzleRules
import SolverCore
let labels=try JSONDecoder().decode([[Int]].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
let grid=Grid(rows:11,cols:11),edges=StateCodec.edges(grid)
func distance(_ a:[Int],_ b:[Int],cached:Bool)->Int{let pairs=cached ? edges:StateCodec.edges(grid);return pairs.reduce(0){$0 + ((a[$1.0]==a[$1.1]) != (b[$1.0]==b[$1.1]) ? 1:0)}}
func old(_ values:[[Int]])->[Int]{var keep=[0],remaining=Array(1..<values.count);while keep.count<16 && !remaining.isEmpty{let index=remaining.indices.max{a,b in func score(_ i:Int)->Int{keep.map{distance(values[i],values[$0],cached:false)}.min()!-((i*7)%12)*2};return score(remaining[a])<score(remaining[b])}!;keep.append(remaining.remove(at:index))};return keep}
func new(_ values:[[Int]])->[Int]{var keep=[0],remaining=Array(1..<values.count),nearest=(1..<values.count).map{distance(values[$0],values[0],cached:true)};while keep.count<16 && !remaining.isEmpty{let index=remaining.indices.max{nearest[$0]-((remaining[$0]*7)%12)*2 < nearest[$1]-((remaining[$1]*7)%12)*2}!;let chosen=remaining.remove(at:index);nearest.remove(at:index);keep.append(chosen);for i in remaining.indices{nearest[i]=min(nearest[i],distance(values[remaining[i]],values[chosen],cached:true))}};return keep}
var rng=SplitMix(seed:91)
for _ in 0..<20{var v=labels;for i in v.indices{v.swapAt(i,rng.index(v.count))};precondition(old(v)==new(v))}
var oldSum=0,newSum=0
let a=monotonic();for i in 0..<100{var v=labels;v.swapAt(i%v.count,(i*7)%v.count);oldSum+=old(v).last!};let oldTime=monotonic()-a
let b=monotonic();for i in 0..<100{var v=labels;v.swapAt(i%v.count,(i*7)%v.count);newSum+=new(v).last!};let newTime=monotonic()-b
precondition(oldSum==newSum)
print("{\"oldSeconds\":\(oldTime),\"newSeconds\":\(newTime),\"speedup\":\(oldTime/newTime),\"equivalenceCases\":20}")
