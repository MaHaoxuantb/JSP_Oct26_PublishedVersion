#!/usr/bin/env python3
"""Short diagnostic continuation experiment; no production source mutations."""
from pathlib import Path
from datetime import datetime
import hashlib,json,os,subprocess,sys,tempfile,time
here=Path(__file__).resolve().parent;root=here.parents[1]
previous=here.parent/'branch_vs_discrete/results/20261029-162908'
source=previous/'control-sources'
out=here/'results'/datetime.now().strftime('%Y%m%d-%H%M%S');out.mkdir(parents=True)
(here/'latest-run.txt').write_text(str(out)+'\n')
core=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'JaneStreetPuzzle_Oct26').rglob('*.swift')}
meta={'started':datetime.now().isoformat(),'budgetSeconds':60,'source':str(source),'sourceHashes':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in source.glob('*.swift')},'coreBefore':core(),'concurrentProcesses':4,'note':'Warm-start diagnostic only. Four processes share the host; timings do not establish solve-speed advantage. BP is deeper existing local cover, not a complete alternating hybrid.'}
(out/'metadata.json').write_text(json.dumps(meta,indent=2));(out/'Probe.swift').write_bytes((here/'Probe.swift').read_bytes());(out/'probe.py').write_bytes(Path(__file__).read_bytes())
fixtures=json.loads((previous/'fixtures.json').read_text())['puzzles']
with tempfile.TemporaryDirectory(prefix='jsp-hybrid-probe-',dir='/private/tmp') as scratch:
    binary=Path(scratch)/'probe'
    sources=sorted(p for p in source.glob('*.swift') if p.name!='Trial.swift')
    subprocess.run(['swiftc','-O','-D','PATHS_CPU_ONLY','-module-cache-path',str(Path(scratch)/'cache'),*map(str,sources),str(out/'Probe.swift'),'-o',str(binary)],check=True)
    jobs=[]; handles=[]
    for n in [8,9]:
        f=next(f for f in fixtures if f['n']==n);snapshot=json.loads((previous/f'{n}x{n}-discrete/result.json').read_text())['snapshot']
        inp=out/f'{n}-input.json';inp.write_text(json.dumps({'fixture':f,'labels':sum(snapshot['labels'],[])}))
        for mode in ['sa','bp']:
            dest=out/f'{n}-{mode}';dest.mkdir();log=(dest/'process.log').open('w');handles.append(log)
            proc=subprocess.Popen([str(binary),str(inp),mode,'60',str(dest)],stdout=log,stderr=subprocess.STDOUT,env=dict(os.environ,EXPERIMENT_REGIONAL='0',EXPERIMENT_CONTINUOUS='0'))
            jobs.append((proc,dest));print('START',n,mode,flush=True)
    for proc,dest in jobs:
        assert proc.wait(timeout=120)==0,(dest,(dest/'process.log').read_text())
    for log in handles:log.close()
sys.path.insert(0,str(here.parent/'discrete_vs_continuous'));from rules import validate
results=[]
for n in [8,9]:
    f=next(f for f in fixtures if f['n']==n)
    for mode in ['sa','bp']:
        r=json.loads((out/f'{n}-{mode}/result.json').read_text());check=validate(sum(r['snapshot']['labels'],[]),n,f['clues']);assert check['solved']==r['solved']
        r['independentValidation']=check;results.append(r);print(n,mode,r['seconds'],check,flush=True)
(out/'results.json').write_text(json.dumps(results,indent=2));meta['coreAfter']=core();assert meta['coreBefore']==meta['coreAfter'];meta['completed']=datetime.now().isoformat();(out/'metadata.json').write_text(json.dumps(meta,indent=2))
print('DONE',out,flush=True)
