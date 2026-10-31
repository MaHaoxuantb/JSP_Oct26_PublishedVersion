"""JSP-Oct26-Search-Escape; ©2026 ThomasB. Author: ThomasB.

Necessary conditions only. Passing these tests is never a feasibility proof.
"""
def derive(puzzle):
    n=puzzle['n'];clues=puzzle['clues'];assert n>0 and len(clues)==n*n
    known=[(c,t) for c,t in enumerate(clues) if t>=0]
    bound=1;witness=None;adjacent=[];singletons=[]
    for i,(a,ta) in enumerate(known):
        for b,tb in known[i+1:]:
            length=abs(a//n-b//n)+abs(a%n-b%n)
            difference=abs(ta-tb);required=(difference+length-1)//length
            if required>bound:bound=required;witness=dict(cells=[a,b],clues=[ta,tb],steps=length)
            if length==1 and difference:
                adjacent.append(dict(cells=[a,b],minimumRegionSize=difference))
        if ta==1:
            r,c=divmod(a,n)
            candidates=[b for ok,b in [(r>0,a-n),(r+1<n,a+n),(c>0,a-1),(c+1<n,a+1)] if ok and clues[b]<=0]
            singletons.append(dict(clueCell=a,candidateCells=candidates))
    return dict(minimumLargestRegion=bound,witness=witness,adjacentSizeBounds=adjacent,
                singletonCapitalDisjunctions=singletons)
