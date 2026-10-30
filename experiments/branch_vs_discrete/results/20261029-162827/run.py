#!/usr/bin/env python3
"""Matched 7/8/9 branch-pruning versus frozen discrete-control experiment."""
import hashlib,json,os,shutil,subprocess,sys,tempfile,time
from pathlib import Path
from datetime import datetime
here=Path(__file__).resolve().parent;root=here.parents[1]
old=Path((here.parent/'regional_production/latest-run.txt').read_text().strip())
out=here/'results'/datetime.now().strftime('%Y%m%d-%H%M%S');out.mkdir(parents=True)
(here/'latest-run.txt').write_text(str(out)+'\n')
sys.path.insert(0,str(here.parent/'discrete_vs_continuous'))
from rules import validate
core=lambda:{str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in (root/'JaneStreetPuzzle_Oct26').rglob('*.swift')}
meta={'budgetSeconds':1000,'seed':20261029,'concurrency':1,'trialOrder':['7-branch','7-discrete','8-branch','8-discrete','9-branch','9-discrete'],'report':str(old/'REPORT.md'),'started':datetime.now().isoformat(),'coreHashesBefore':core(),'controlSource':str(old/'sources/discrete'),'maskBits':{'7':64,'8':128,'9':128}}
(out/'metadata.json').write_text(json.dumps(meta,indent=2));(out/'results.json').write_text('[]')
marker='\n\n<!-- branch-vs-discrete-1000 -->\n'
(out/'previous-report.md').write_text((old/'REPORT.md').read_text().split(marker)[0])
(out/'branch-sources').mkdir();(out/'control-sources').mkdir()
for x in here.glob('*.swift'):(out/'branch-sources'/x.name).write_bytes(x.read_bytes())
for x in (old/'sources/discrete').glob('*.swift'):(out/'control-sources'/x.name).write_bytes(x.read_bytes())
for name in ['Policy.swift','Trial.swift']:(out/'control-sources'/name).write_bytes((here.parent/'regional_production'/name).read_bytes())
for name in ['run.py','report.py','render.cjs','README.md']:
    if (here/name).exists():(out/name).write_bytes((here/name).read_bytes())
results=[]
def update():
    (out/'results.json').write_text(json.dumps(results,indent=2))
    subprocess.run([sys.executable,str(here/'report.py'),str(out)],check=True)
with tempfile.TemporaryDirectory(prefix='jsp-branch-discrete-',dir='/private/tmp') as scratch:
    work=Path(scratch);binaries={}
    for engine,defs,sources in [('branch64',[],out/'branch-sources'),('branch128',['-D','WIDE_BOARD'],out/'branch-sources'),('discrete',['-D','PATHS_CPU_ONLY'],out/'control-sources')]:
        binary=work/engine
        subprocess.run(['swiftc','-O',*defs,'-module-cache-path',str(work/'cache'),*map(str,sorted(sources.glob('*.swift'))),'-o',str(binary)],cwd=work,check=True)
        binaries[engine]=binary
        print('BUILT',engine,flush=True)
    for engine in ['branch64','branch128']:
        with (out/f'{engine}-tests.log').open('w') as log:subprocess.run([str(binaries[engine]),'--self-test'],stdout=log,stderr=subprocess.STDOUT,check=True)
    subprocess.run([str(binaries['branch128']),'--make',str(old/'fixtures.json'),str(out)],check=True)
    fixtures=json.loads((out/'fixtures.json').read_text())['puzzles']
    assert [f['n'] for f in fixtures]==[7,8,9]
    assert fixtures[0]==next(f for f in json.loads((old/'fixtures.json').read_text())['puzzles'] if f['n']==7)
    for f in fixtures:assert sum(c>=0 for row in f['clues'] for c in row)==round(f['n']**2*33/121)
    for f in json.loads((out/'maker-witnesses.json').read_text()):assert validate(f['witness'],f['n'],f['clues'])['solved']
    update()
    for index,f in enumerate(fixtures):
        for engine in ['branch','discrete']:
            name=f"{f['n']}x{f['n']}-{engine}";dest=out/name;dest.mkdir()
            if engine=='branch':
                binary=binaries['branch64' if f['n']==7 else 'branch128']
                cmd=[str(binary),str(out/'fixtures.json'),str(index),'1000',str(dest/'result.json')]
            else:cmd=[str(binaries['discrete']),str(out/'fixtures.json'),str(index),str(meta['seed']),'1000',str(dest)]
            print('START',name,datetime.now().isoformat(),flush=True)
            started=time.monotonic();env=dict(os.environ,EXPERIMENT_REGIONAL='0',EXPERIMENT_CONTINUOUS='0')
            with (dest/'process.log').open('w') as log:
                proc=subprocess.Popen(cmd,cwd=work,env=env,stdout=log,stderr=subprocess.STDOUT)
                try:
                    while proc.poll() is None:
                        elapsed=time.monotonic()-started
                        (out/'status.json').write_text(json.dumps({'running':name,'pid':proc.pid,'wallSeconds':elapsed,'completed':len(results),'total':6}))
                        if elapsed>1120:raise TimeoutError('Solver failed to honor 1000-second cutoff plus safety grace')
                        time.sleep(1)
                    assert proc.returncode==0,(name,(dest/'process.log').read_text()[-3000:])
                finally:
                    if proc.poll() is None:proc.terminate();proc.wait(timeout=15)
            wall=time.monotonic()-started
            raw=json.loads((dest/'result.json').read_text());labels=raw.get('labels') if engine=='branch' else raw['snapshot']['labels']
            check=validate(sum(labels,[]),f['n'],f['clues'])
            assert check['solved']==raw['solved']
            r={'id':name,'n':f['n'],'engine':engine,'seed':None if engine=='branch' else meta['seed'],'solved':raw['solved'],'seconds':raw['seconds'],'wallSeconds':wall,'reason':raw['reason'],'labels':labels,'validation':check,'rawResult':str(dest/'result.json')}
            if engine=='branch':r.update(catalogSeconds=raw['catalogSeconds'],shapeCount=raw['shapeCount'],catalogComplete=raw['catalogComplete'],counters=raw['counters'],observations=raw['observations'])
            results.append(r);update()
            print('END',name,r['seconds'],'solved',r['solved'],'wrong',check['wrongClues'],flush=True)
meta['completed']=datetime.now().isoformat();meta['coreHashesAfter']=core();assert meta['coreHashesBefore']==meta['coreHashesAfter']
meta['compiler']=subprocess.check_output(['swiftc','--version'],stderr=subprocess.STDOUT,text=True).strip()
(out/'metadata.json').write_text(json.dumps(meta,indent=2));(out/'status.json').write_text(json.dumps({'running':None,'completed':6,'total':6}))
update();print('DONE',out,flush=True)
