"""JSP-Oct26-Search-Escape; ©2026 ThomasB. One-core local CP-SAT companion.
Only puzzle-matched, independently checked improvements are published to Mini.
"""
import argparse,collections,json,pathlib,random,shlex,subprocess,time,traceback
from cpsat import solve,neighbors,distances,global_candidates,evaluate

def read(p,default=None):
 try:return json.loads(pathlib.Path(p).read_text())
 except (OSError,ValueError):return default

def atomic(p,value):
 p=pathlib.Path(p);q=p.with_suffix('.tmp');q.write_text(json.dumps(value));q.replace(p)
def quality(q):return q['issues'],q['wrong'],round(q['residual'],13)
def publish(remote,root,payload):
 # Fixed Python receiver and stdin JSON avoid putting candidate data into shell code.
 script='import sys,pathlib,json; r=pathlib.Path(sys.argv[1]); d=json.load(sys.stdin); p=r/"external-candidates.json"; q=p.with_suffix(".tmp"); q.write_text(json.dumps(d)); q.replace(p)'
 command='python3 -c '+shlex.quote(script)+' '+shlex.quote(root)
 subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5',remote,command],input=json.dumps(payload),text=True,check=True,timeout=15)
def main():
 p=argparse.ArgumentParser();p.add_argument('--pointer',default='/private/tmp/jsp-cpu8-current.json');p.add_argument('--once',action='store_true');p.add_argument('--global-every',type=int,default=32);a=p.parse_args()
 pointer=read(a.pointer);mirror=pathlib.Path(pointer['localMirror']);folder=mirror/'cpsat';folder.mkdir(exist_ok=True)
 attempts=0;best=None;lastRoot=pointer['root']
 while True:
  pointer=read(a.pointer);assert pointer['root']==lastRoot,'Search changed; sidecar will not follow another run silently'
  snap=read(mirror/'snapshot.json',{})
  if snap.get('phase') in ['stopped','failed','solved','complete']:break
  jobs=snap.get('jobs',[])
  if not jobs:time.sleep(2);continue
  value=jobs[-1].get('result') or jobs[-1].get('progress') or {};base=value.get('labels');puzzle=snap['config']['puzzle']
  if not base:time.sleep(2);continue
  n=puzzle['n'];check=evaluate(base,n,puzzle['clues'])
  if best and quality(best['quality'])<quality(check):base=best['labels'];check=best['quality']
  attempts+=1;started=time.monotonic();rng=random.Random(2026103060+attempts)
  try:
   if a.global_every and attempts%a.global_every==0:
    candidates=global_candidates(base,n);r=solve(puzzle,base,list(range(n*n)),20,False,candidates,started)
   else:
    parts=collections.defaultdict(list)
    for c,v in enumerate(base):parts[v].append(c)
    d=distances(base,n);bad=[c for c,t in enumerate(puzzle['clues']) if t>=0 and d[c]!=t and len(parts[base[c]])<=16]
    small=[c for c in range(n*n) if len(parts[base[c]])<=16];focus=rng.choice(bad if bad and attempts%3 else small);patch=set(parts[base[focus]])
    while len(patch)<16:
     options=sorted({base[v] for c in patch for v in neighbors(c,n)}-{base[c] for c in patch});options=[x for x in options if len(patch)+len(parts[x])<=16]
     if not options:break
     patch.update(parts[rng.choice(options)])
    r=solve(puzzle,base,sorted(patch),5,False)
   r.update(attempt=attempts,updated=time.time(),puzzle=puzzle)
   if r['quality'] and quality(r['quality'])<quality(check):
    verify=evaluate(r['labels'],n,puzzle['clues']);assert quality(verify)==quality(r['quality'])
    best=dict(puzzle=puzzle,labels=r['labels'],quality=verify,producer='CP-SAT',attempt=attempts)
    atomic(folder/'best.json',best)
    if read(mirror/'snapshot.json',{}).get('phase')=='running':publish(pointer['ssh'],pointer['root'],best)
    r['published']=True
   else:r['published']=False
   atomic(folder/f'attempt-{attempts:06d}.json',r)
   atomic(mirror/'cpsat-progress.json',dict(state='running',attempts=attempts,status=r['status'],lastSeconds=r['seconds'],lastPatchCells=r['patchCells'],restrictedGlobal=not r['completePatchDomain'],best=best and best['quality'],updated=time.time()))
  except Exception as error:
   atomic(mirror/'cpsat-progress.json',dict(state='error',attempts=attempts,error=str(error),updated=time.time()))
   with (folder/'errors.log').open('a') as log:traceback.print_exc(file=log)
  if a.once:break
  time.sleep(5)
 atomic(mirror/'cpsat-progress.json',dict(state='stopped',attempts=attempts,best=best and best['quality'],updated=time.time()))
if __name__=='__main__':main()
