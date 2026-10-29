#!/usr/bin/env python3
"""Build isolated experiment, validate policy, then explicitly launch eight trials."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from zoneinfo import ZoneInfo

here=Path(__file__).resolve().parent
root=here.parents[1]
sys.path.insert(0,str(here.parent/'discrete_vs_continuous'))
from rules import validate
p=argparse.ArgumentParser()
p.add_argument('--run',action='store_true')
p.add_argument('--seconds',type=float,default=300)
p.add_argument('--output',type=Path)
a=p.parse_args()
assert 0<a.seconds<1e7
spec=json.loads((here/'design.json').read_text())
source_fixture=(here/spec['fixture_source']).resolve()
assert hashlib.sha256(source_fixture.read_bytes()).hexdigest()==spec['fixture_sha256']
frozen=json.loads(source_fixture.read_text())['puzzles'][:2]
for f in frozen: assert validate(f['witness'],f['n'],f['clues'])['solved']
fixtures={'puzzles':[{k:f[k] for k in ['name','n','clues']} for f in frozen]}
stamp=datetime.now(ZoneInfo('Asia/Tokyo')).strftime('%Y%m%d-%H%M%S')
out=(a.output or here/'results'/f'pilot-{stamp}').resolve()
assert not out.exists(), 'Use a fresh output directory to preserve prior experiments'
sources=sorted(x for x in (root/'JaneStreetPuzzle_Oct26').glob('*.swift') if x.name!='main.swift')
original_hashes={str(s.relative_to(root)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
print('Compiling experimental harness in isolated scratch directory.',flush=True)
with tempfile.TemporaryDirectory(prefix='jsp-regional-',dir='/private/tmp') as scratch:
    work=Path(scratch); binary=work/'regional-experiment'
    command=['swiftc','-O','-D','PATHS_CPU_ONLY','-module-cache-path',str(work/'module-cache'),*map(str,sources),str(here/'RegionalExperiment.swift'),'-o',str(binary)]
    subprocess.run(command,check=True,cwd=work)
    subprocess.run([str(binary),'--self-test'],check=True,cwd=work)
    if not a.run:
        print('Self-tests passed. No searches launched; use --run for the eight-condition pilot.')
        raise SystemExit(0)
    out.mkdir(parents=True)
    (out/'fixtures.json').write_text(json.dumps(fixtures,indent=2)+'\n')
    (out/'verification-fixtures.json').write_text(json.dumps({'puzzles':frozen},indent=2)+'\n')
    metadata={'started_at_jst':datetime.now(ZoneInfo('Asia/Tokyo')).isoformat(),'seconds_per_trial':a.seconds,
              'seed':20261029,'conditions':spec['conditions'],'concurrency_per_size_batch':4,'workers_per_trial':1,
              'source_sha256':{**original_hashes,'experiments/regional_energy/RegionalExperiment.swift':hashlib.sha256((here/'RegionalExperiment.swift').read_bytes()).hexdigest()},
              'fixture_sha256':spec['fixture_sha256'],'compiler':subprocess.check_output(['swiftc','--version'],text=True),
              'build_flags':['-O','-D','PATHS_CPU_ONLY'],'parent_pid':os.getpid(),
              'note':'Shared experimental mutation framework, not the full production repair solver. ON/OFF controls matched within representation.'}
    (out/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    (here/'latest-run.txt').write_text(str(out)+'\n')
    completed=[]; jobs=[]; interrupted=False
    def save_status():
        value={'updated_at_jst':datetime.now(ZoneInfo('Asia/Tokyo')).isoformat(),'completed':len(completed),'total':8,
               'trials':[{'id':j['condition']['id'],'pid':j['process'].pid,'state':j['state'],
                          'wallSeconds':j.get('elapsed',time.monotonic()-j['started'])} for j in jobs]}
        tmp=out/'status.tmp'; tmp.write_text(json.dumps(value,indent=2)+'\n'); tmp.replace(out/'status.json')
    try:
        for size in [5,7]:
            batch=[]
            for condition in spec['conditions']:
                if condition['board_size']!=size: continue
                folder=out/condition['id']; folder.mkdir()
                log=(folder/'process.log').open('w')
                command=[str(binary),str(out/'fixtures.json'),str(0 if size==5 else 1),
                         str(int(condition['representation']=='continuous')),str(int(condition['regional'])),
                         '20261029',str(a.seconds),str(folder)]
                process=subprocess.Popen(command,cwd=work,stdout=log,stderr=subprocess.STDOUT)
                job={'condition':condition,'process':process,'stream':log,'folder':folder,'started':time.monotonic(),'state':'running'}
                jobs.append(job); batch.append(job)
            print(f'Launched four {size}x{size} conditions with {a.seconds:g}s cutoff each. Output: {out}',flush=True)
            next_notice=0
            while any(j['state']=='running' for j in batch):
                for job in batch:
                    proc=job['process']
                    if job['state']!='running' or proc.poll() is None: continue
                    job['stream'].close()
                    if proc.returncode:
                        job['state']='error'; save_status()
                        raise RuntimeError(f"{job['condition']['id']} failed; inspect {job['folder']/'process.log'}")
                    result=json.loads((job['folder']/'result.json').read_text())
                    f=frozen[0 if size==5 else 1]
                    for key in ['current','nativeBest','exactBest']:
                        snap=result[key]; checked=validate(snap['labels'],size,f['clues'])
                        assert checked['solved']==snap['valid']
                        assert checked['wrongClues']==snap['wrong']
                        assert bool(checked['issues'])==bool(snap['issues'])
                    if result['solved']:
                        assert validate(result['solution']['labels'],size,f['clues'])['solved']
                    else: assert result['reason']=='cutoff' and result['seconds']>=a.seconds
                    result['id']=job['condition']['id']; completed.append(result)
                    (out/'results.json').write_text(json.dumps(completed,indent=2)+'\n')
                    job['state']='solved' if result['solved'] else 'cutoff'
                    job['elapsed']=result['seconds']
                    print(f"{result['id']}: {job['state']} after {result['seconds']:.2f}s; best exact energy={result['exactBest']['common']:.6f}, wrong={result['exactBest']['wrong']}, issues={result['exactBest']['issues']}",flush=True)
                save_status()
                if time.monotonic()>=next_notice:
                    print(' | '.join(f"{j['condition']['id']}: {j['state']} ({time.monotonic()-j['started']:.0f}s)" for j in batch),flush=True)
                    next_notice=time.monotonic()+30
                time.sleep(2)
        assert len(completed)==8
        assert all(hashlib.sha256((root/name).read_bytes()).hexdigest()==digest for name,digest in original_hashes.items())
        print('All eight trials finished and independently checked. Core solver sources match their initial hashes.',flush=True)
    except KeyboardInterrupt:
        interrupted=True
        print('Experiment stopped by user; preserving logs and checkpoints.',flush=True)
        raise
    finally:
        for job in jobs:
            if job['process'].poll() is None:
                job['process'].terminate()
                try: job['process'].wait(timeout=10)
                except subprocess.TimeoutExpired: job['process'].kill(); job['process'].wait()
                job['state']='stopped'
                job['elapsed']=time.monotonic()-job['started']
            if not job['stream'].closed: job['stream'].close()
        if jobs: save_status()
    print(f'Results: {out}',flush=True)
