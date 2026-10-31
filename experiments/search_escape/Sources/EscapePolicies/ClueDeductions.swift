// JSP-Oct26-Structural-Search; ©2026 ThomasB. Author: ThomasB.
import PuzzleRules
import SolverCore

public struct ClueDeductions {
  public let puzzle:Puzzle, minimumLargestRegion:Int, minimumAreas:[Int], ones:[Int], zeros:[Int]
  public init(_ puzzle:Puzzle) {
    self.puzzle=puzzle
    let known=puzzle.clues.indices.filter{puzzle.clues[$0]>=0},n=puzzle.n
    var largest=1,areas=Array(repeating:1,count:n*n)
    for (i,a) in known.enumerated() {
      for b in known.dropFirst(i+1) {
        let length=abs(a/n-b/n)+abs(a%n-b%n),difference=abs(puzzle.clues[a]-puzzle.clues[b])
        largest=max(largest,(difference+length-1)/length)
        if length==1 {areas[a]=max(areas[a],difference);areas[b]=max(areas[b],difference)}
      }
    }
    minimumLargestRegion=largest;minimumAreas=areas
    ones=known.filter{puzzle.clues[$0]==1};zeros=known.filter{puzzle.clues[$0]==0}
  }
  /// Sound necessary conditions on a single region; no inference of sufficiency.
  public func permits(_ mask:CellMask,capitol:Int?)->Bool {
    for c in mask.cells {
      if mask.count<minimumAreas[c] {return false}
      if puzzle.clues[c]==0 && capitol != c {return false}
      if puzzle.clues[c]>0 && capitol==c {return false}
    }
    return true
  }
  public func assess(_ value:ScoredState)->(violations:Int,penalty:Double) {
    let e=value.exact,capitals=Set(e.capitols),largest=e.sizes.max() ?? 0
    var count=e.quality.issues,penalty=Double(e.quality.issues)
    func deficit(_ size:Int,_ needed:Int) {if size<needed {count+=1;penalty+=Double(needed-size)/Double(needed)}}
    deficit(largest,minimumLargestRegion)
    for c in e.labels.indices {
      deficit(e.sizes[c],minimumAreas[c])
      if (puzzle.clues[c]==0 && !capitals.contains(c)) || (puzzle.clues[c]>0 && capitals.contains(c)) {count+=1;penalty+=1}
    }
    for c in ones where !puzzle.grid.neighbors[c].contains(where:{e.sizes[$0]==1}) {count+=1;penalty+=1}
    return(count,penalty)
  }
  public func energy(_ value:ScoredState)->Double {
    let a=assess(value)
    return 4*a.penalty+(Double(value.exact.quality.wrong)+value.exact.quality.residual)/Double(max(1,puzzle.clueCount))
  }
}
