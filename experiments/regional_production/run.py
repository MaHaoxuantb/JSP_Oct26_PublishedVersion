#!/usr/bin/env python3
"""Production-preserving controls; scratch source patches; sequential timed trials."""
import argparse, hashlib, json, os, subprocess, sys, tempfile, time
from pathlib import Path
from datetime import datetime
here=Path(__file__).resolve().parent; root=here.parents[1]
sys.path.insert(0,str(here.parent/'discrete_vs_continuous'))
from rules import validate
p=argparse.ArgumentParser(); p.add_argument('--seconds',type=float,default=300); p.add_argument('--seeds',type=int,nargs='+',default=[20261029,20261030,20261031]); p.add_argument('--output',type=Path); a=p.parse_args()
out=(a.output or here/'results'/datetime.now().strftime('%Y%m%d-%H%M%S')).resolve()
assert not out.exists(); out.mkdir(parents=True)
(here/'latest-run.txt').write_text(str(out.relative_to(here) if out.is_relative_to(here) else out)+'\n')
fixtures=json.loads((here.parent/'discrete_vs_continuous/until_solved/fixtures.json').read_text())['puzzles'][:2]
for f in fixtures: assert validate(f['witness'],f['n'],f['clues'])['solved']
(out/'fixtures.json').write_text(json.dumps({'puzzles':[{k:f[k] for k in ['n','name','clues']} for f in fixtures]},indent=2))
core=sorted(x for x in (root/'JaneStreetPuzzle_Oct26').glob('*.swift') if x.name!='main.swift')
hashes={str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in core}
revision=subprocess.check_output(['git','rev-parse','e23adc5'],cwd=root,text=True).strip()
metadata={'seconds':a.seconds,'seeds':a.seeds,'core_sha256':hashes,'continuous_revision':revision,'concurrency':1,'started':datetime.now().isoformat(),'note':'Control search choices untouched; snapshots and 1-second progress logging added. Continuous weights 2:1:2 in both arms. Regional modifies focus and breadth only. Discrete and continuous retain different original search engines.'}
(out/'metadata.json').write_text(json.dumps(metadata,indent=2))
results=[]
def replace(text,old,new):
    assert text.count(old)==1,old
    return text.replace(old,new)
def instrument(text):
    marker='''                event.message = message
                try logger.record(event)'''
    return replace(text,marker,'''                event.message = message
                event.snapshot = BoardSnapshot(best)
                try logger.record(event)''')
with tempfile.TemporaryDirectory(prefix='jsp-production-regional-',dir='/private/tmp') as scratch:
    work=Path(scratch); binaries={}
    for representation in ['discrete','continuous']:
        dest=work/representation; dest.mkdir(); sources=[]
        if representation=='discrete': originals={x.name:x.read_text() for x in core}
        else:
            names=subprocess.check_output(['git','ls-tree','--name-only',revision,'JaneStreetPuzzle_Oct26/'],cwd=root,text=True).splitlines()
            originals={Path(n).name:subprocess.check_output(['git','show',f'{revision}:{n}'],cwd=root,text=True) for n in names if n.endswith('.swift') and not n.endswith('/main.swift')}
        saved=out/'sources'/representation; saved.mkdir(parents=True)
        for name,text in originals.items():
            if name=='Solver.swift': text=instrument(text)
            if representation=='discrete' and name=='RegionRepairs.swift':
                text=replace(text,'let labels = source.labels, parts = groups(labels)\n        var focus: [Int] = []', '''let labels = source.labels, parts = groups(labels)
        let field = ExperimentPolicy.enabled ? ExperimentPolicy.exactField(source.validation, rows:grid.rows, cols:grid.cols) : []
        var focus: [Int] = []''')
                text=replace(text,'let seed = available[(repairTicket + rng.index(available.count)) % available.count]', '''let seed: Int
        if ExperimentPolicy.enabled {
            seed = ExperimentPolicy.focus(field, available:available, rng:&rng)
        } else {
            seed = available[(repairTicket + rng.index(available.count)) % available.count]
        }''')
                text=replace(text,'let desired = large ? 4 + rng.index(5) : 1 + rng.index(config.maxMergeRegions)', '''let desired: Int
        if ExperimentPolicy.enabled {
            let h = ExperimentPolicy.hotness(field,cell:seed)
            desired = ExperimentPolicy.breadth(h,maximum:large ? 8 : config.maxMergeRegions,rng:&rng)
        } else { desired = large ? 4 + rng.index(5) : 1 + rng.index(config.maxMergeRegions) }''')
            if representation=='continuous' and name=='SearchSupport.swift':
                text=replace(text,'let radius = 1 + rng.index(2)', '''let radius = ExperimentPolicy.enabled ? ExperimentPolicy.breadth(
                ExperimentPolicy.hotness(current.Energy.flatMap { $0 },cell:cell),maximum:2,rng:&rng) : 1 + rng.index(2)''')
                text=replace(text,'if rng.unit() < 0.5 { new = old >= 0.5 ? 0.1 : 0.9 }', '''if ExperimentPolicy.enabled {
                let h=ExperimentPolicy.hotness(current.Energy.flatMap { $0 },cell:cell)
                var value=(old+ExperimentPolicy.noise(h,rng:&rng)).truncatingRemainder(dividingBy:2)
                if value<0 { value += 2 }; new = value<=1 ? value : 2-value
            }
            else if rng.unit() < 0.5 { new = old >= 0.5 ? 0.1 : 0.9 }''')
            path=dest/name; path.write_text(text); sources.append(path); (saved/name).write_text(text)
        binary=dest/'trial'
        cmd=['swiftc','-O','-module-cache-path',str(work/'cache')]
        if representation=='discrete': cmd += ['-D','PATHS_CPU_ONLY']
        subprocess.run(cmd+list(map(str,sources))+[str(here/'Policy.swift'),str(here/'Trial.swift'),'-o',str(binary)],check=True,cwd=work)
        subprocess.run([str(binary),'--policy-test'],check=True,cwd=work)
        binaries[representation]=binary
        print('Built '+representation,flush=True)
    def run(size,representation,regional,seed,gate=False):
        name=f'{size}x{size}-{representation}-'+('regional' if regional else 'control')+f'-{seed}'
        if gate: name='gate-'+name
        folder=out/name; folder.mkdir()
        env=dict(os.environ,EXPERIMENT_REGIONAL=str(int(regional)),EXPERIMENT_CONTINUOUS=str(int(representation=='continuous')))
        cmd=[str(binaries[representation]),str(out/'fixtures.json'),str(0 if size==5 else 1),str(seed),str(a.seconds),str(folder)]
        print('START '+name,flush=True)
        with (folder/'process.log').open('w') as log:
            proc=subprocess.Popen(cmd,cwd=work,env=env,stdout=log,stderr=subprocess.STDOUT)
            try:
                next_notice=time.monotonic()+30
                while proc.poll() is None:
                    (out/'status.json').write_text(json.dumps({'running':name,'pid':proc.pid,'completed':len(results),'output':str(out)}))
                    if time.monotonic()>=next_notice: print('RUNNING '+name,flush=True); next_notice=time.monotonic()+30
                    time.sleep(1)
                assert proc.returncode==0,(name,(folder/'process.log').read_text())
            finally:
                if proc.poll() is None: proc.terminate(); proc.wait(timeout=15)
        r=json.loads((folder/'result.json').read_text()); f=fixtures[0 if size==5 else 1]
        check=validate(sum(r['snapshot']['labels'],[]),size,f['clues'])
        assert check['solved']==r['solved']
        r.update(id=name,representation=representation,independent=check,gate=gate)
        results.append(r); (out/'results.json').write_text(json.dumps(results,indent=2))
        print(f"END {name}: {r['seconds']:.3f}s, solved={r['solved']}, wrong={check['wrongClues']}, issues={check['issues']}",flush=True)
        return r
    # Gate: real control must reproduce the remembered fast solve before adaptations run.
    gate=run(5,'discrete',False,a.seeds[0],True)
    assert gate['solved'] and gate['seconds']<30,'Production reproduction failed; stop and investigate before comparisons.'
    for size in [5,7]:
        for seed in a.seeds:
            for representation in ['discrete','continuous']:
                for regional in [False,True]:
                    if size==5 and seed==a.seeds[0] and representation=='discrete' and not regional: continue # gate is this control
                    run(size,representation,regional,seed)
    assert all(hashlib.sha256((root/name).read_bytes()).hexdigest()==h for name,h in hashes.items())
(out/'status.json').write_text(json.dumps({'running':None,'completed':len(results)}))
print('DONE '+str(out),flush=True)
