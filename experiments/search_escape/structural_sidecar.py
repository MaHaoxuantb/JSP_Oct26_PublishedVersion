"""JSP-Oct26-Structural-Search; ©2026 ThomasB. Author: ThomasB.

One local CPU core: constrained whole-board CP-SAT using native large-region
discoveries. Restricted catalogs never establish whole-puzzle infeasibility.
"""
import argparse,collections,hashlib,json,pathlib,shlex,subprocess,time,traceback
from cpsat import solve,global_candidates,evaluate,geometry,neighbors
from clue_constraints import derive
from sidecar import read,atomic,quality

def structural_score(labels,puzzle):
    n=puzzle['n'];d=derive(puzzle);parts=collections.defaultdict(list)
    for c,v in enumerate(labels):parts[v].append(c)
    sizes=[0]*len(labels);caps=set()
    for cells in parts.values():
        legal,cap=geometry(cells,n);assert legal
        for c in cells:sizes[c]=len(cells)
        if cap is not None:caps.add(cap)
    penalty=max(0,(d['minimumLargestRegion']-max(sizes))/d['minimumLargestRegion'])
    minimum=[1]*len(labels)
    for pair in d['adjacentSizeBounds']:
        for c in pair['cells']:minimum[c]=max(minimum[c],pair['minimumRegionSize'])
    for c,target in enumerate(puzzle['clues']):
        penalty+=max(0,(minimum[c]-sizes[c])/minimum[c])
        penalty+=int((target==0 and c not in caps) or (target>0 and c in caps))
    for clause in d['singletonCapitalDisjunctions']:
        penalty+=int(not any(sizes[c]==1 for c in neighbors(clause['clueCell'],n)))
    q=evaluate(labels,n,puzzle['clues'])
    return 4*penalty+(q['wrong']+q['residual'])/max(1,sum(t>=0 for t in puzzle['clues'])),penalty

def publish(pointer,payload,name):
    script='import sys,pathlib,json; r=pathlib.Path(sys.argv[1]); d=json.load(sys.stdin); p=r/sys.argv[2]; q=p.with_suffix(".tmp"); q.write_text(json.dumps(d)); q.replace(p)'
    command='python3 -c '+shlex.quote(script)+' '+shlex.quote(pointer['root'])+' '+shlex.quote(name)
    subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5',pointer['ssh'],command],
                   input=json.dumps(payload),text=True,check=True,timeout=15)

def main():
    p=argparse.ArgumentParser();p.add_argument('--pointer',default='/private/tmp/jsp-cpu8-current.json');p.add_argument('--seconds',type=float,default=30);p.add_argument('--once',action='store_true');a=p.parse_args()
    pointer=read(a.pointer);campaign=pointer['root'];mirror=pathlib.Path(pointer['localMirror']);folder=mirror/'structural-cpsat';folder.mkdir(exist_ok=True)
    attempts=0;working=None;best=None;proved=set()
    while True:
        pointer=read(a.pointer);assert pointer['root']==campaign,'Campaign changed; refusing silent reassignment'
        snap=read(mirror/'snapshot.json',{})
        if snap.get('phase') in ['stopped','failed','solved','complete']:break
        if not snap.get('jobs'):time.sleep(2);continue
        job=snap['jobs'][-1];value=job.get('result') or job.get('progress') or {};base=value.get('labels');puzzle=snap['config']['puzzle']
        if not base:time.sleep(2);continue
        candidates=[base]
        for w in job.get('workers',[]):
            s=w.get('structure',{})
            for k in ['bestWorkingLabels','currentLabels']:
                labels=s.get(k)
                if labels and len(labels)==puzzle['n']**2 and evaluate(labels,puzzle['n'],puzzle['clues'])['issues']==0:candidates.append(labels)
        if working:candidates.append(working['labels'])
        chosen=min(candidates,key=lambda x:structural_score(x,puzzle)[0])
        domain=global_candidates(chosen,puzzle['n'],candidates)
        domain_key=hashlib.sha256(json.dumps(sorted((cells,cap) for cells,cap in domain)).encode()).hexdigest()
        if domain_key in proved:
            atomic(mirror/'cpsat-progress.json',dict(state='waiting for new domain',attempts=attempts,updated=time.time(),mode='structural global',best=best and best['quality']))
            if a.once:break
            time.sleep(5);continue
        attempts+=1
        atomic(mirror/'cpsat-progress.json',dict(state='solving constrained global model',attempts=attempts,candidateShapes=len(domain),updated=time.time(),mode='structural global',best=best and best['quality']))
        try:
            r=solve(puzzle,chosen,list(range(puzzle['n']**2)),a.seconds,False,domain,deduced=True,random_seed=2026103100+attempts)
            r.update(attempt=attempts,puzzle=puzzle,domainSHA256=domain_key,updated=time.time(),published=False,publishedStructural=False)
            if r['quality']:
                checked=evaluate(r['labels'],puzzle['n'],puzzle['clues']);assert quality(checked)==quality(r['quality'])
                score,penalty=structural_score(r['labels'],puzzle);assert penalty==0
                payload=dict(puzzle=puzzle,labels=r['labels'],quality=checked,producer='constrained global CP-SAT',attempt=attempts)
                if not working or score<structural_score(working['labels'],puzzle)[0]-1e-12:
                    working=payload;atomic(folder/'working-best.json',working)
                    if read(mirror/'snapshot.json',{}).get('phase')=='running':publish(pointer,working,'external-structural-candidates.json')
                    r['publishedStructural']=True
                retained=evaluate(base,puzzle['n'],puzzle['clues'])
                if quality(checked)<quality(retained) and (not best or quality(checked)<quality(best['quality'])):
                    best=payload;atomic(folder/'best.json',best)
                    if read(mirror/'snapshot.json',{}).get('phase')=='running':publish(pointer,best,'external-candidates.json')
                    r['published']=True
            if r['status'] in ['OPTIMAL','INFEASIBLE']:proved.add(domain_key)
            atomic(folder/f'attempt-{attempts:06d}.json',r)
            atomic(mirror/'cpsat-progress.json',dict(state='running',attempts=attempts,status=r['status'],lastSeconds=r['seconds'],lastPatchCells=r['patchCells'],restrictedGlobal=True,best=best and best['quality'],workingBest=working and working['quality'],updated=time.time(),mode='structural global'))
        except Exception as error:
            atomic(mirror/'cpsat-progress.json',dict(state='error',attempts=attempts,error=str(error),updated=time.time()))
            with (folder/'errors.log').open('a') as log:traceback.print_exc(file=log)
        if a.once:break
        time.sleep(5)
    atomic(mirror/'cpsat-progress.json',dict(state='stopped',attempts=attempts,best=best and best['quality'],updated=time.time(),mode='structural global'))

if __name__=='__main__':main()
