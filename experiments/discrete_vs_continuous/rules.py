"""Independent exact validation used for experiment results."""
from collections import defaultdict, deque
import heapq

def validate(labels,n,clues):
    def neighbors(c):
        r,k=divmod(c,n)
        return [v for ok,v in [(r>0,c-n),(r+1<n,c+n),(k>0,c-1),(k+1<n,c+1)] if ok]
    groups=defaultdict(list)
    for c,label in enumerate(labels): groups[label].append(c)
    sizes=[0]*(n*n); caps=[]; issues=0
    for cells in groups.values():
        occupied=set(cells); seen={cells[0]}; q=deque(seen)
        while q:
            for v in neighbors(q.popleft()):
                if v in occupied and v not in seen: seen.add(v); q.append(v)
        if seen!=occupied: issues+=1; continue
        sr=min(c//n for c in cells)+max(c//n for c in cells)
        sc=min(c%n for c in cells)+max(c%n for c in cells)
        coords=[(2*(c//n)-sr,2*(c%n)-sc) for c in cells]
        fixed=[]
        for t in range(7):
            mapped=[[(k,-r),(-r,-k),(-k,r),(r,-k),(-r,k),(k,r),(-k,-r)][t] for r,k in coords]
            if set(mapped)==set(coords): fixed.append({c for c,x,y in zip(cells,coords,mapped) if x==y})
        if not fixed: issues+=1
        elif len(fixed[0])==1 and all(f==fixed[0] for f in fixed): caps.extend(fixed[0])
        for c in cells: sizes[c]=len(cells)
    inf=10**12; distance=[inf]*(n*n); heap=[]
    for c in caps: distance[c]=0; heapq.heappush(heap,(0,c))
    while heap:
        d,c=heapq.heappop(heap)
        if d!=distance[c]: continue
        for v in neighbors(c):
            nd=d+min(sizes[c],sizes[v])
            if nd<distance[v]: distance[v]=nd; heapq.heappush(heap,(nd,v))
    wrong=sum(x>=0 and distance[r*n+c]!=x for r,row in enumerate(clues) for c,x in enumerate(row))
    answer=sum(sum(sizes[r*n:(r+1)*n])**2 for r in range(n)) if not issues and not wrong else None
    return {'solved':answer is not None,'wrongClues':wrong,'issues':issues,'answer':answer}
