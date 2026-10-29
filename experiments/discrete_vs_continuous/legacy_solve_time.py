#!/usr/bin/env python3
"""Run actual historical continuous search. No working-tree checkout or deployment."""
import argparse
from collections import defaultdict, deque
import hashlib
import heapq
import json
from pathlib import Path
import statistics
import subprocess
import tempfile

here=Path(__file__).resolve().parent
root=here.parents[1]
p=argparse.ArgumentParser()
p.add_argument('--trials',type=int,default=5)
p.add_argument('--seconds',type=float,default=30)
p.add_argument('--output',type=Path,default=here/'legacy_solve_results')
p.add_argument('--fixtures',type=Path,default=here/'results/results.json')
p.add_argument('--puzzles',type=int,nargs='+',default=[0,1,2])
a=p.parse_args()
a.output=a.output.resolve(); a.output.mkdir(parents=True,exist_ok=True)
fixture_path=a.fixtures.resolve()
fixtures=json.loads(fixture_path.read_text())['puzzles']

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

for fixture in fixtures:
    check=validate(fixture['witness'],fixture['n'],fixture['clues'])
    assert check['solved']
    if fixture['n']==5: assert check['answer']==8045

revision=subprocess.check_output(['git','rev-parse','e23adc5'],cwd=root,text=True).strip()
with tempfile.TemporaryDirectory(prefix='jsp-legacy-solve-',dir='/private/tmp') as scratch:
    work=Path(scratch)
    names=subprocess.check_output(['git','ls-tree','--name-only',revision,'JaneStreetPuzzle_Oct26/'],cwd=root,text=True).splitlines()
    sources=[]; hashes={}
    for name in names:
        if not name.endswith('.swift') or name.endswith('/main.swift'): continue
        content=subprocess.check_output(['git','show',f'{revision}:{name}'],cwd=root)
        dest=work/Path(name).name; dest.write_bytes(content); sources.append(dest)
        hashes[name]=hashlib.sha256(content).hexdigest()
    binary=work/'legacy-solve'
    subprocess.run(['swiftc','-O','-module-cache-path',str(work/'module-cache'),*map(str,sources),str(here/'LegacySolveTime.swift'),'-o',str(binary)],check=True,cwd=work)
    (a.output/'metadata.json').write_text(json.dumps({'revision':revision,'source_sha256':hashes,'trials':a.trials,'limit_seconds':a.seconds,'fixture_sha256':hashlib.sha256(fixture_path.read_bytes()).hexdigest(),'overrides':{'workerCount':1,'consoleLogging':False,'maxIterations':100_000_000,'maxRestarts':20_000},'validation':'independent Python integer geometry and Dijkstra'},indent=2)+'\n')
    rows=[]
    for puzzle,fixture in enumerate(fixtures):
        if puzzle not in a.puzzles: continue
        for trial in range(a.trials):
            seed=20261029+trial
            output=a.output/f'{puzzle}-{seed}.json'
            subprocess.run([str(binary),str(fixture_path),str(puzzle),str(seed),str(a.seconds),str(output),'unused'],check=True,cwd=work,timeout=a.seconds+60)
            row=json.loads(output.read_text()); historical=row.pop('solved')
            check=validate(row['labels'],row['n'],fixture['clues'])
            assert check['solved']==historical, 'Historical/current rules disagree'
            row.update(check); rows.append(row)
            (a.output/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
            print(f"{row['puzzle']} historical_continuous seed={seed} solved={row['solved']} elapsed={row['elapsedSeconds']:.3f}s wrong={row['wrongClues']} reason={row['stopReason']}",flush=True)
