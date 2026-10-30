// JSP-Oct26-GPU-Quick; ©2026 ThomasB. Author: ThomasB.
import Foundation
import Metal
@_silgen_name("cpuShapes") func cpuShapes(_ masks: UnsafePointer<UInt32>, _ out: UnsafeMutablePointer<UInt32>, _ count: Int32, _ n: Int32)
@_silgen_name("cpuPaths") func cpuPaths(_ sizes: UnsafePointer<Int32>, _ seeds: UnsafePointer<UInt32>, _ out: UnsafeMutablePointer<Int32>, _ count: Int32, _ n: Int32)
@_silgen_name("certifyPaths") func certifyPaths(_ sizes: UnsafePointer<Int32>, _ seeds: UnsafePointer<UInt32>, _ out: UnsafePointer<Int32>, _ count: Int32, _ n: Int32) -> Bool
@_silgen_name("cpuHeapPaths") func cpuHeapPaths(_ sizes: UnsafePointer<Int32>, _ seeds: UnsafePointer<UInt32>, _ out: UnsafeMutablePointer<Int32>, _ count: Int32, _ n: Int32)
struct Record: Decodable { let labels: [Int], patch: [Int] }
struct BoardCapture: Decodable { let n: Int, clues: [Int], records: [Record] }
struct Capture: Decodable { let boards: [BoardCapture] }
struct Row: Codable {let n: Int, batch: Int, task: String; let cpuMS: Double, gpuMS: Double, speedup: Double; let cpuSamplesMS: [Double], gpuSamplesMS: [Double]}
func words(_ mask: CellMask) -> [UInt32] {(0..<4).map {UInt32(truncatingIfNeeded: mask.bits >> ($0*32))}}
func pack(_ g: Geometry) -> UInt32 {UInt32(g.connected ? 1:0) | UInt32(g.symmetric ? 2:0) | g.symmetries.reduce(UInt32(0)) {$0 | (1 << ($1+1))} | UInt32((g.capitol ?? -1)+1)<<9}
func median(_ a: [Double]) -> Double {a.sorted()[a.count/2]}
func measure(_ count: Int = 15,_ f: () throws -> Void) rethrows -> [Double] {var a:[Double]=[];for _ in 0..<count {let s=monotonic();try f();a.append((monotonic()-s)*1000)};return a}
let here=URL(fileURLWithPath:CommandLine.arguments[1]), output=CommandLine.arguments[3]
let capture=try JSONDecoder().decode(Capture.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {fatalError("Metal unavailable")}
let source=try String(contentsOf:here.appendingPathComponent("kernels.metal"),encoding:.utf8).replacingOccurrences(of:"// SHARED_HEADER",with:try String(contentsOf:here.appendingPathComponent("shared.h"),encoding:.utf8))
let cold=monotonic(),library=try device.makeLibrary(source:source,options:nil)
let shapePipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"shapes")!),pathPipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"paths")!)
let coldSeconds=monotonic()-cold
precondition(shapePipeline.threadExecutionWidth==32 && pathPipeline.threadExecutionWidth==32)
precondition(shapePipeline.maxTotalThreadsPerThreadgroup>=256 && pathPipeline.maxTotalThreadsPerThreadgroup>=256)
func buffer<T>(_ a: [T]) -> MTLBuffer {a.withUnsafeBytes {device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!}}
func command(_ pipeline: MTLComputePipelineState,_ buffers: [MTLBuffer],_ batch: Int,_ n: Int) -> MTLCommandBuffer {
 let cmd=queue.makeCommandBuffer()!,e=cmd.makeComputeCommandEncoder()!;e.setComputePipelineState(pipeline)
 for(i,b) in buffers.enumerated(){e.setBuffer(b,offset:0,index:i)}
 var info=SIMD2<UInt32>(UInt32(batch),UInt32(n));e.setBytes(&info,length:8,index:buffers.count)
 e.dispatchThreadgroups(MTLSize(width:1,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:256,height:1,depth:1));e.endEncoding();return cmd
}
var rows:[Row]=[],verifiedShapes=0,verifiedPaths=0,checksum:UInt64=0
for board in capture.boards.sorted(by:{$0.n<$1.n}) {
 let n=board.n,grid=Grid(rows:n,cols:n),cells=n*n
 var set=Set<CellMask>(),masks:[CellMask]=[]
 func add(_ m:CellMask){if !m.isEmpty && set.insert(m).inserted{masks.append(m)}}
 for r in board.records {for g in groups(r.labels){add(g);for c in g.cells.prefix(2){var v=g;v.remove(c);add(v)};if let c=g.first,let v=grid.neighbors[c].first{var a=g;a.insert(v);add(a)}}}
 for c in 0..<cells {add(CellMask(cells:[c]))};add(grid.full)
 var inputs:[([Int],[Int])]=[]
 for r in board.records {
  let patch=CellMask(cells:r.patch),parts=groups(r.labels),outside=parts.filter{!$0.intersects(patch)},inside=parts.filter{$0.subset(of:patch)}
  for cut in [0,inside.count/2,inside.count] {
   var low=Array(repeating:1,count:cells),high=Array(repeating:max(1,patch.count),count:cells),caps:[Int]=[],occupied=CellMask()
   for p in outside+Array(inside.prefix(cut)){for c in p.cells{low[c]=p.count;high[c]=p.count};occupied=occupied.union(p);if let cap=Rules.geometry(p,grid:grid).capitol{caps.append(cap)}}
   let remaining=grid.full.subtracting(occupied);for c in remaining.cells{high[c]=max(1,remaining.count)}
   inputs.append((low,caps+remaining.cells));inputs.append((high,caps))
  }
 }
 print("Board \(n): \(masks.count) distinct saved/perturbed masks, \(inputs.count) derived bound inputs");fflush(stdout)
 let gold=masks.map {pack(Rules.geometry($0,grid:grid))}
 for batch in [1,32,256,1024] {
  let selected=(0..<batch).map{masks[$0%masks.count]},flat=selected.flatMap(words),expected=(0..<batch).map{gold[$0%gold.count]}
  let mi=buffer(flat),mo=device.makeBuffer(length:batch*4,options:.storageModeShared)!,mp=mi.contents().bindMemory(to:UInt32.self,capacity:batch*4),op=mo.contents().bindMemory(to:UInt32.self,capacity:batch)
  var cpuOut=Array(repeating:UInt32(0),count:batch)
  cpuOut.withUnsafeMutableBufferPointer{cpuShapes(mp,$0.baseAddress!,Int32(batch),Int32(n))};precondition(cpuOut==expected,"CPU geometry disagreement")
  func gpuShape(_ work:(()->Void)?=nil){memcpy(mi.contents(),flat,flat.count*4);let cmd=command(shapePipeline,[mi,mo],batch,n);cmd.commit();work?();cmd.waitUntilCompleted();precondition(cmd.status == .completed);for i in 0..<batch{checksum &+= UInt64(op[i])}}
  gpuShape();precondition(Array(UnsafeBufferPointer(start:op,count:batch))==expected,"Metal geometry disagreement");verifiedShapes+=batch
  let existingCPU=measure(5) {for m in selected {checksum &+= UInt64(pack(Rules.geometry(m,grid:grid)))}}
  let cpu=measure {cpuOut.withUnsafeMutableBufferPointer{cpuShapes(mp,$0.baseAddress!,Int32(batch),Int32(n))};checksum &+= UInt64(cpuOut[0])}
  let gpu=measure {gpuShape()}
  rows.append(Row(n:n,batch:batch,task:"shape-checks",cpuMS:median(cpu),gpuMS:median(gpu),speedup:median(cpu)/median(gpu),cpuSamplesMS:cpu,gpuSamplesMS:gpu))
  rows.append(Row(n:n,batch:batch,task:"shape-existing-Swift",cpuMS:median(existingCPU),gpuMS:median(gpu),speedup:median(existingCPU)/median(gpu),cpuSamplesMS:existingCPU,gpuSamplesMS:gpu))
  if batch==1024 {
   // Actual shared branch/cover implementation; identical fresh job and node cap per sample.
   let rec=board.records[0],puzzle=Puzzle(id:"gpu-replay-\(n)",n:n,clues:board.clues)
   var patch=CellMask();for p in groups(rec.labels){if patch.count+p.count<=20{patch=patch.union(p)}}
   func searchWork(){let oracle=ShapeOracle(grid:grid,templates:[]),search=CoverSearch(puzzle:puzzle,patch:patch,base:rec.labels,mode:.improve,oracle:oracle);_ = search.advance(until:monotonic()+5,nodeLimit:32,coverLimit:32);checksum &+= UInt64(search.state.counters.nodes)}
   let serial=measure(5){cpuOut.withUnsafeMutableBufferPointer{cpuShapes(mp,$0.baseAddress!,Int32(batch),Int32(n))};searchWork();checksum &+= UInt64(cpuOut[0])}
   let overlap=measure(5){gpuShape(searchWork)}
   rows.append(Row(n:n,batch:batch,task:"cpu-BP-plus-shapes",cpuMS:median(serial),gpuMS:median(overlap),speedup:median(serial)/median(overlap),cpuSamplesMS:serial,gpuSamplesMS:overlap))
  }
  let chosen=(0..<batch).map{inputs[$0%inputs.count]},sizes=chosen.flatMap{$0.0.map(Int32.init)},seeds=chosen.flatMap{words(CellMask(cells:$0.1))}
  let sb=buffer(sizes),cb=buffer(seeds),db=device.makeBuffer(length:batch*cells*4,options:.storageModeShared)!
  let sp=sb.contents().bindMemory(to:Int32.self,capacity:sizes.count),cp=cb.contents().bindMemory(to:UInt32.self,capacity:seeds.count),dp=db.contents().bindMemory(to:Int32.self,capacity:sizes.count)
  var distances=Array(repeating:Int32(0),count:sizes.count)
  distances.withUnsafeMutableBufferPointer{cpuPaths(sp,cp,$0.baseAddress!,Int32(batch),Int32(n))}
  for b in 0..<batch {let reference=Rules.distances(grid:grid,sizes:chosen[b].0,sources:chosen[b].1).distances.map(Int32.init);precondition(Array(distances[(b*cells)..<((b+1)*cells)])==reference,"CPU path disagreement")}
  func gpuPaths(){memcpy(sb.contents(),sizes,sizes.count*4);memcpy(cb.contents(),seeds,seeds.count*4);let cmd=command(pathPipeline,[sb,cb,db],batch,n);cmd.commit();cmd.waitUntilCompleted();precondition(cmd.status == .completed);precondition(certifyPaths(sp,cp,dp,Int32(batch),Int32(n)));checksum &+= UInt64(dp[0])}
  gpuPaths();precondition(Array(UnsafeBufferPointer(start:dp,count:sizes.count))==distances,"GPU paths disagree");verifiedPaths+=batch
  let pcpu=measure {distances.withUnsafeMutableBufferPointer{cpuPaths(sp,cp,$0.baseAddress!,Int32(batch),Int32(n))};checksum &+= UInt64(distances[0])}
  let heap=measure {distances.withUnsafeMutableBufferPointer{cpuHeapPaths(sp,cp,$0.baseAddress!,Int32(batch),Int32(n))};checksum &+= UInt64(distances[0])}
  precondition(certifyPaths(sp,cp,distances,Int32(batch),Int32(n)))
  let pgpu=measure {gpuPaths()}
  rows.append(Row(n:n,batch:batch,task:"bound-paths-certified",cpuMS:median(pcpu),gpuMS:median(pgpu),speedup:median(pcpu)/median(pgpu),cpuSamplesMS:pcpu,gpuSamplesMS:pgpu))
  rows.append(Row(n:n,batch:batch,task:"bound-paths-heap-certified",cpuMS:median(heap),gpuMS:median(pgpu),speedup:median(heap)/median(pgpu),cpuSamplesMS:heap,gpuSamplesMS:pgpu))
  if batch==256 {
   let rec=board.records[0],puzzle=Puzzle(id:"overlap",n:n,clues:board.clues)
   var patch=CellMask();for p in groups(rec.labels){if patch.count+p.count<=20{patch=patch.union(p)}}
   func work(){let o=ShapeOracle(grid:grid,templates:[]),search=CoverSearch(puzzle:puzzle,patch:patch,base:rec.labels,mode:.improve,oracle:o);_ = search.advance(until:monotonic()+5,nodeLimit:32,coverLimit:32);checksum &+= UInt64(search.state.counters.nodes)}
   var a:[Double]=[],b:[Double]=[]
   func serial(){distances.withUnsafeMutableBufferPointer{if median(heap)<median(pcpu){cpuHeapPaths(sp,cp,$0.baseAddress!,Int32(batch),Int32(n))}else{cpuPaths(sp,cp,$0.baseAddress!,Int32(batch),Int32(n))}};work();checksum &+= UInt64(distances[0])}
   func hybrid(){memcpy(sb.contents(),sizes,sizes.count*4);memcpy(cb.contents(),seeds,seeds.count*4);let cmd=command(pathPipeline,[sb,cb,db],batch,n);cmd.commit();work();cmd.waitUntilCompleted();precondition(cmd.status == .completed && certifyPaths(sp,cp,dp,Int32(batch),Int32(n)));checksum &+= UInt64(dp[0])}
   serial();hybrid();for i in 0..<16 {if i%2==0{a+=measure(1,serial);b+=measure(1,hybrid)}else{b+=measure(1,hybrid);a+=measure(1,serial)}}
   rows.append(Row(n:n,batch:batch,task:"cpu-BP-plus-bound-paths",cpuMS:median(a),gpuMS:median(b),speedup:median(a)/median(b),cpuSamplesMS:a,gpuSamplesMS:b))
  }
  print("  batch \(batch): shapes \(String(format:"%.2f",median(cpu)/median(gpu)))x, paths \(String(format:"%.2f",median(pcpu)/median(pgpu)))x");fflush(stdout)
 }
}
struct Result:Codable{let experiment:String,copyright:String,device:String,shaderStartupSeconds:Double,verifiedShapes:Int,verifiedPaths:Int,checksum:UInt64,rows:[Row]}
try writeJSON(Result(experiment:"JSP-Oct26-GPU-Quick",copyright:"©2026 ThomasB",device:device.name,shaderStartupSeconds:coldSeconds,verifiedShapes:verifiedShapes,verifiedPaths:verifiedPaths,checksum:checksum,rows:rows),to:output)
print("Saved \(output)")
