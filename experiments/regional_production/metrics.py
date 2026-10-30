from collections import defaultdict, deque
import heapq, math

def exact_metrics(labels, fixture):
    n=fixture['n']; labels=[c for row in labels for c in row]
    def neighbors(c):
        r,k=divmod(c,n)
        return [v for yes,v in [(r>0,c-n),(r+1<n,c+n),(k>0,c-1),(k+1<n,c+1)] if yes]
    groups=defaultdict(list)
    for c,v in enumerate(labels): groups[v].append(c)
    sizes=[0]*len(labels); caps=[]; invalid=0
    for cells in groups.values():
        for c in cells: sizes[c]=len(cells)
        occupied=set(cells); seen={cells[0]}; queue=deque(seen)
        while queue:
            for v in neighbors(queue.popleft()):
                if v in occupied and v not in seen: seen.add(v); queue.append(v)
        sr=min(c//n for c in cells)+max(c//n for c in cells)
        sc=min(c%n for c in cells)+max(c%n for c in cells)
        positions=[(2*(c//n)-sr,2*(c%n)-sc) for c in cells]
        fixed=[]
        for t in range(7):
            mapped=[[(k,-r),(-r,-k),(-k,r),(r,-k),(-r,k),(k,r),(-k,-r)][t] for r,k in positions]
            if set(mapped)==set(positions): fixed.append({c for c,x,y in zip(cells,positions,mapped) if x==y})
        if seen!=occupied or not fixed: invalid+=len(cells)
        elif len(fixed[0])==1 and all(f==fixed[0] for f in fixed): caps.extend(fixed[0])
    distance=[math.inf]*len(labels); heap=[]
    for c in caps: distance[c]=0; heapq.heappush(heap,(0,c))
    while heap:
        d,c=heapq.heappop(heap)
        if d!=distance[c]: continue
        for v in neighbors(c):
            through=d+min(sizes[c],sizes[v])
            if through<distance[v]: distance[v]=through; heapq.heappush(heap,(through,v))
    errors=[]; wrong=0
    for r,row in enumerate(fixture['clues']):
        for k,target in enumerate(row):
            if target<0: continue
            actual=distance[r*n+k]
            wrong+=actual!=target
            errors.append(abs(actual-target)/max(actual,target,1) if math.isfinite(actual) else 1)
    aim=sum(errors)/len(errors); symmetry=invalid/len(labels)
    return {'exactClueEnergy':aim,'invalidCellFraction':symmetry,
            'commonExactEnergy':(2*aim+symmetry)/3.25,'exactWrongClues':wrong}
