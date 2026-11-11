#!/usr/bin/env python3
"""Offline admissible-bound audit of connected unions of saved SA regions."""
from collections import defaultdict
from pathlib import Path
import heapq,json,math
from fractions import Fraction
here=Path(__file__).resolve().parent
out=(here / (here/'latest-run.txt').read_text().strip())
def audit(n):
    inp=json.loads((out/f'{n}-input.json').read_text());labels=inp['labels'];clues=sum(inp['fixture']['clues'],[]);count=n*n
    def near(c):
        r,k=divmod(c,n)
        return [v for yes,v in [(r>0,c-n),(r+1<n,c+n),(k>0,c-1),(k+1<n,c+1)] if yes]
    adjacency=[near(c) for c in range(count)];groups=defaultdict(set)
    for c,v in enumerate(labels):groups[v].add(c)
    sizes=[len(groups[v]) for v in labels];caps={}
    for key,cells in groups.items():
        sr=min(c//n for c in cells)+max(c//n for c in cells);sc=min(c%n for c in cells)+max(c%n for c in cells)
        positions=[(2*(c//n)-sr,2*(c%n)-sc) for c in sorted(cells)];fixed=[]
        for t in range(7):
            mapped=[[(k,-r),(-r,-k),(-k,r),(r,-k),(-r,k),(k,r),(-k,-r)][t] for r,k in positions]
            if set(mapped)==set(positions):fixed.append({c for c,x,y in zip(sorted(cells),positions,mapped) if x==y})
        if fixed and len(fixed[0])==1 and all(f==fixed[0] for f in fixed):caps[key]=next(iter(fixed[0]))
    def distances(weights,sources):
        d=[math.inf]*count;heap=[]
        for c in sources:d[c]=0;heapq.heappush(heap,(0,c))
        while heap:
            value,c=heapq.heappop(heap)
            if value!=d[c]:continue
            for v in adjacency[c]:
                new=value+min(weights[c],weights[v])
                if new<d[v]:d[v]=new;heapq.heappush(heap,(new,v))
        return d
    actual=distances(sizes,caps.values());given=[c for c in range(count) if clues[c]>=0]
    current_wrong=sum(actual[c]!=clues[c] for c in given);current_error=sum((Fraction(abs(actual[c]-clues[c]),max(actual[c],clues[c],1)) for c in given),Fraction())/len(given)
    region_edges={key:{labels[v] for c in cells for v in adjacency[c]}-{key} for key,cells in groups.items()}
    clusters={frozenset([key]) for key in groups};frontier=clusters.copy()
    for depth in range(1,4):
        next_layer=set()
        for cluster in frontier:
            for key in set().union(*(region_edges[k] for k in cluster))-cluster:
                candidate=cluster|{key}
                if sum(len(groups[k]) for k in candidate)<=48:next_layer.add(candidate)
        next_layer-=clusters;clusters|=next_layer;frontier=next_layer
    rows=[]
    for cluster in clusters:
        patch=set().union(*(groups[k] for k in cluster));k=len(patch)
        if k>48:continue
        low=sizes.copy();high=sizes.copy();known=[v for key,v in caps.items() if key not in cluster]
        for c in patch:low[c]=1;high[c]=k
        lower=distances(low,known+list(patch));upper=distances(high,known)
        wrong=0;error=Fraction()
        for c in given:
            if lower[c]>clues[c]:wrong+=1;error+=Fraction(1) if math.isinf(lower[c]) else Fraction(lower[c]-clues[c],lower[c])
            elif upper[c]<clues[c]:wrong+=1;error+=Fraction(clues[c]-upper[c],clues[c])
        error/=len(given)
        cannot_improve=wrong>current_wrong or (wrong==current_wrong and error>=current_error)
        rows.append({'patchCells':k,'regionCount':len(cluster),'cannotImprove':cannot_improve,'fullSolutionExcluded':wrong>0})
    summary={'n':n,'currentWrong':current_wrong,'currentMeanError':float(current_error),'regions':len(groups),'patches':len(rows),'upTo32':{},'upTo48':{}}
    for limit in [32,48]:
        subset=[x for x in rows if x['patchCells']<=limit]
        summary[f'upTo{limit}']={'patches':len(subset),'cannotImprove':sum(x['cannotImprove'] for x in subset),'fullSolutionExcluded':sum(x['fullSolutionExcluded'] for x in subset)}
    return summary
results=[audit(n) for n in [8,9]]
(out/'patch-screening.json').write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2))
