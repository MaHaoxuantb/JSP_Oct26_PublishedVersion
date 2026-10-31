// JSP-Oct26-Structural-Search; ©2026 ThomasB. Author: ThomasB.
import PuzzleRules
import ShapeDomain
import SolverCore

/// Immutable finite proposal catalog, shared by the cooperating threads.
/// This is an explicitly incomplete heuristic domain, never an infeasibility proof.
public final class StructuralCatalog: @unchecked Sendable {
  public let puzzle:Puzzle,deductions:ClueDeductions,byCell:[[CellMask]],count:Int
  public init(puzzle:Puzzle,templates:[ShapeTemplate]) {
    self.puzzle=puzzle;let deductions=ClueDeductions(puzzle);self.deductions=deductions
    let grid=puzzle.grid,n=puzzle.n
    var seen=Set<CellMask>(),buckets=Array(repeating:[CellMask](),count:grid.count)
    func add(_ mask:CellMask) {
      guard seen.insert(mask).inserted else{return}
      let geo=Rules.geometry(mask,grid:grid)
      guard geo.legal && deductions.permits(mask,capitol:geo.capitol) else{return}
      for c in mask.cells {buckets[c].append(mask)}
    }
    for h in 1...n {for w in 1...n {for r in 0...(n-h) {for c in 0...(n-w) {
      add(CellMask(cells:(0..<h).flatMap{y in (0..<w).map{x in (r+y)*n+c+x}}))
    }}}}
    for template in templates where template.cells.count<=8 {
      for o in template.orientations where o.height<=n && o.width<=n {
        for r in 0...(n-o.height) {for c in 0...(n-o.width) {
          add(CellMask(cells:o.cells.map{(r+$0/o.width)*n+c+$0%o.width}))
        }}
      }
    }
    byCell=buckets.map{$0.sorted{a,b in a.count==b.count ? a<b:a.count>b.count}}
    count=Set(byCell.flatMap{$0}).count
  }
}

public enum StructuralRegions {
  public static func orbit(_ cell:Int,rowsum:Int,colsum:Int,transform:Int,grid:Grid)->CellMask? {
    var c=cell,mask=CellMask()
    repeat {
      guard !mask.contains(c) else{return c==cell ? mask:nil}
      mask.insert(c)
      let r=2*(c/grid.cols)-rowsum,k=2*(c%grid.cols)-colsum
      let a:Int,b:Int
      switch transform {
      case 1:(a,b)=(k,-r)
      case 2:(a,b)=(-r,-k)
      case 3:(a,b)=(-k,r)
      case 4:(a,b)=(r,-k)
      case 5:(a,b)=(-r,k)
      case 6:(a,b)=(k,r)
      default:(a,b)=(-k,-r)
      }
      guard (a+rowsum)%2==0,(b+colsum)%2==0 else{return nil}
      let y=(a+rowsum)/2,x=(b+colsum)/2
      guard y>=0,y<grid.rows,x>=0,x<grid.cols else{return nil}
      c=y*grid.cols+x
    }while c != cell
    return mask
  }
  /// Grow symmetry orbits directly at the required area, without enumerating
  /// every smaller polyomino first. Geometry is independently checked afterward.
  public static func large(deductions:ClueDeductions,rng:inout SplitMix)->CellMask? {
    let p=deductions.puzzle,n=p.n,g=p.grid,minimum=deductions.minimumLargestRegion
    guard minimum<=g.count else{return nil}
    let clues=p.clues.indices.filter{p.clues[$0]>0}.sorted{p.clues[$0]>p.clues[$1]}
    for _ in 0..<16 {
      let focus=clues.isEmpty ? rng.index(g.count):clues[rng.index(min(6,clues.count))]
      let y=focus/n,x=focus%n,top=rng.index(y+1),left=rng.index(x+1)
      let bottom=y+rng.index(n-y),right=x+rng.index(n-x),h=bottom-top+1,w=right-left+1
      if h*w<minimum {continue}
      let transforms=[2,4,5]+(h==w ? [1,6,7]:[]),t=transforms[rng.index(transforms.count)]
      let sr=top+bottom,sc=left+right
      guard var mask=orbit(focus,rowsum:sr,colsum:sc,transform:t,grid:g) else{continue}
      let target=minimum+rng.index(max(1,min(h*w-minimum+1,30)))
      for _ in 0..<g.count {
        if mask.count>=target && g.connected(mask) {
          let geo=Rules.geometry(mask,grid:g)
          if geo.legal && deductions.permits(mask,capitol:geo.capitol) {return mask}
        }
        var boundary=Set<Int>()
        for cell in mask.cells {
          for v in g.neighbors[cell] where !mask.contains(v) {
            let row=v/n,column=v%n
            if row>=top && row<=bottom && column>=left && column<=right {boundary.insert(v)}
          }
        }
        let frontier=boundary.sorted()
        guard !frontier.isEmpty else{break}
        guard let extra=orbit(frontier[rng.index(frontier.count)],rowsum:sr,colsum:sc,transform:t,grid:g) else{break}
        mask=mask.union(extra)
      }
    }
    return nil
  }
  public static func mutate(_ mask:CellMask,deductions:ClueDeductions,rng:inout SplitMix)->CellMask? {
    let g=deductions.puzzle.grid,cells=mask.cells,geo=Rules.geometry(mask,grid:g)
    guard !geo.symmetries.isEmpty else{return nil}
    let sr=cells.map{$0/g.cols}.min()!+cells.map{$0/g.cols}.max()!,sc=cells.map{$0%g.cols}.min()!+cells.map{$0%g.cols}.max()!
    let t=geo.symmetries[rng.index(geo.symmetries.count)]
    let remove=rng.unit()<0.45
    let choices=remove ? cells:Array(Set(cells.flatMap{g.neighbors[$0]}).subtracting(cells)).sorted()
    guard !choices.isEmpty,let extra=orbit(choices[rng.index(choices.count)],rowsum:sr,colsum:sc,transform:t,grid:g) else{return nil}
    let next=remove ? mask.subtracting(extra):mask.union(extra)
    guard !next.isEmpty else{return nil}
    let check=Rules.geometry(next,grid:g)
    return check.legal && deductions.permits(next,capitol:check.capitol) ? next:nil
  }
  /// Bounded branching in a finite domain. nil means only that this attempt did
  /// not find a tiling, not that this scope or the puzzle is infeasible.
  public static func tile(released:CellMask,forced:CellMask?,base:[Int],catalog:StructuralCatalog,
    extra:[CellMask],until:Double,rng:inout SplitMix,nodes:inout Int)->[Int]? {
    let p=catalog.puzzle,g=p.grid,d=catalog.deductions
    let preferred=groups(base)+extra
    var validation:[CellMask:Bool]=[:]
    func permitted(_ mask:CellMask)->Bool {
      if let known=validation[mask] {return known}
      let geo=Rules.geometry(mask,grid:g),ok=geo.legal && d.permits(mask,capitol:geo.capitol)
      validation[mask]=ok
      return ok
    }
    var chosen:[CellMask]=forced.map{[$0]} ?? []
    let remaining=forced.map{released.subtracting($0)} ?? released
    func search(_ free:CellMask)->Bool {
      if free.isEmpty{return true}
      if nodes>=512 || monotonic()>=until{return false}
      // Constrained clue cells precede easy singleton cells.
      let c=free.cells.max{a,b in
        let aa=d.minimumAreas[a]*100+(p.clues[a]>=0 ? 10:0),bb=d.minimumAreas[b]*100+(p.clues[b]>=0 ? 10:0)
        return aa==bb ? a>b:aa<bb
      }!
      // Validate only dynamic masks that could actually be used here, once per
      // tiling attempt. Eagerly checking the entire 256-shape bank consumed the
      // work deadline before any branch on slower cores.
      let dynamic=preferred.filter{$0.contains(c) && $0.subset(of:free) && permitted($0)}
      var options=Array(Set(catalog.byCell[c].filter{$0.subset(of:free)}+dynamic)).sorted()
      if options.isEmpty{return false}
      // Randomized ordering and bounded width are explicitly heuristic.
      for i in options.indices.reversed() {options.swapAt(i,rng.index(i+1))}
      options=Array(options.prefix(24))
      for mask in options {
        nodes+=1;chosen.append(mask)
        if search(free.subtracting(mask)){return true}
        chosen.removeLast()
        if nodes>=512 || monotonic()>=until {break}
      }
      return false
    }
    guard search(remaining) else{return nil}
    var labels=base,offset=(base.max() ?? 0)+1
    for mask in chosen {for c in mask.cells {labels[c]=offset};offset+=1}
    return normalized(labels)
  }
}
