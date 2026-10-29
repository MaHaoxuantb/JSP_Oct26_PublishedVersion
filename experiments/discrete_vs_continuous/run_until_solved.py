#!/usr/bin/env python3
"""Run both real algorithms until exact solutions; no experiment time cutoff."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from rules import validate

here=Path(__file__).resolve().parent
root=here.parents[1]
p=argparse.ArgumentParser()
p.add_argument('--output',type=Path,default=here/'until_solved')
p.add_argument('--seed',type=int,default=20261029)
a=p.parse_args()
a.output=a.output.resolve(); a.output.mkdir(parents=True,exist_ok=True)
assert not (a.output/'status.json').exists(), 'Choose a new output directory to preserve previous run state.'

def atomic(path,value):
    tmp=path.with_suffix(path.suffix+'.tmp')
    tmp.write_text(json.dumps(value,indent=2)+'\n'); tmp.replace(path)

sources=sorted(x for x in (root/'JaneStreetPuzzle_Oct26').glob('*.swift') if x.name!='main.swift')
revision=subprocess.check_output(['git','rev-parse','e23adc5'],cwd=root,text=True).strip()
metadata={'started_at_utc':datetime.now(timezone.utc).isoformat(),'seed':a.seed,'time_cutoff':None,
          'worker_count_per_search':1,'max_concurrent_searches':3,
          'historical_revision':revision,'real_clue_ratio':[33,121],
          'fixture_clue_counts':{'5x5':[7,25],'7x7':[13,49]},
          'original_source_sha256':{str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in [*sources,here/'SolveTime.swift',here/'LegacySolveTime.swift',here/'Experiment.swift']},
          'parent_pid':os.getpid(),
          'comparison':'Current discrete and actual historical continuous search; concurrent one-worker jobs on a shared host.'}
atomic(a.output/'metadata.json',metadata)
with tempfile.TemporaryDirectory(prefix='jsp-until-solved-',dir='/private/tmp') as scratch:
    work=Path(scratch)
    current=work/'discrete'; legacy=work/'continuous'
    fixture=work/'Fixtures.swift'
    fixture.write_text((here/'Experiment.swift').read_text().split('@main struct Experiment {')[0].replace('generated8_','generated7_'))
    subprocess.run(['swiftc','-O','-D','PATHS_CPU_ONLY','-module-cache-path',str(work/'module-cache'),*map(str,sources),str(fixture),str(here/'SolveTime.swift'),'-o',str(current)],check=True,cwd=work)
    names=subprocess.check_output(['git','ls-tree','--name-only',revision,'JaneStreetPuzzle_Oct26/'],cwd=root,text=True).splitlines()
    old_sources=[]; old_hashes={}
    for name in names:
        if not name.endswith('.swift') or name.endswith('/main.swift'): continue
        data=subprocess.check_output(['git','show',f'{revision}:{name}'],cwd=root)
        old_hashes[name]=hashlib.sha256(data).hexdigest()
        text=data.decode()
        if name.endswith('/Solver.swift'):
            marker='''                try logger.record(event)
            }
            try milestone(.initialized, state: current)'''
            insertion='''                if kind == .progress || kind == .bestImproved || kind == .initialized {
                    event.snapshot = BoardSnapshot(best)
                }
'''
            assert text.count(marker)==1
            text=text.replace(marker,insertion+marker)
            metadata['historical_observation_patch']={'insert_before':marker,'insertion':insertion,
                'purpose':'Persist best-board snapshots in existing progress events; search choices unchanged.'}
        dest=work/Path(name).name; dest.write_text(text); old_sources.append(dest)
    metadata['historical_source_sha256']=old_hashes
    atomic(a.output/'metadata.json',metadata)
    subprocess.run(['swiftc','-O','-module-cache-path',str(work/'module-cache'),*map(str,old_sources),str(here/'LegacySolveTime.swift'),'-o',str(legacy)],check=True,cwd=work)
    fixtures_path=a.output/'fixtures.json'
    jobs=[]
    env=dict(os.environ,PUZZLE_EXPERIMENT_BOARD_SIZE='7',PUZZLE_EXPERIMENT_MATCH_DENSITY='1',PUZZLE_EXPERIMENT_FIXTURES_OUTPUT=str(fixtures_path))
    def launch(name,command):
        folder=a.output/name; folder.mkdir(parents=True,exist_ok=True)
        stderr=(folder/'process.log').open('w')
        process=subprocess.Popen(command,cwd=work,env=env,stdout=stderr,stderr=subprocess.STDOUT)
        jobs.append({'name':name,'process':process,'stream':stderr,'folder':folder,'start':time.monotonic(),'done':False})
    for name,puzzle in [('discrete5',0),('discrete7',1)]:
        folder=a.output/name
        launch(name,[str(current),str(puzzle),str(a.seed),'until-solved',str(folder/'result.json'),str(folder/'logs'),'discrete'])
        # The 5x5 job finishes quickly in previous runs; starting both permits a
        # stalled larger search to proceed independently of the continuous ones.
        while not fixtures_path.exists():
            if jobs[-1]['process'].poll() is not None: raise RuntimeError('Fixture preparation failed')
            time.sleep(0.05)
        if name=='discrete5':
            # Keep at most three simultaneous searches: finish the small discrete
            # baseline first, then overlap the remaining three one-worker jobs.
            returncode=jobs[-1]['process'].wait()
            if returncode: raise RuntimeError('Discrete example failed')
    fixtures=json.loads(fixtures_path.read_text())['puzzles']
    for f in fixtures:
        assert validate(f['witness'],f['n'],f['clues'])['solved']
    for name,puzzle in [('continuous5',0),('continuous7',1)]:
        folder=a.output/name
        launch(name,[str(legacy),str(fixtures_path),str(puzzle),str(a.seed),'until-solved',str(folder/'result.json'),'unused'])
    print('Until-solved searches launched; exact clue counts 7/25 and 13/49. No time cutoff.',flush=True)
    results=[]; next_notice=0
    try:
        while True:
            statuses=[]
            for job in jobs:
                process=job['process']; resultfile=job['folder']/'result.json'
                if not job['done'] and process.poll() is not None:
                    job['stream'].close()
                    if process.returncode: raise RuntimeError(f"{job['name']} exited {process.returncode}; inspect process.log")
                    result=json.loads(resultfile.read_text())
                    puzzle=fixtures[0 if job['name'].endswith('5') else 1]
                    check=validate(result['labels'],puzzle['n'],puzzle['clues'])
                    assert check['solved'] and result['solved'], 'Search ended without independently verified solution'
                    result.update(check); result['job']=job['name']; results.append(result)
                    atomic(a.output/'results.json',results)
                    job['done']=True; job['result']=result
                    print(f"SOLVED {job['name']} in {result['elapsedSeconds']:.3f}s",flush=True)
                latest=None
                for logfile in sorted(job['folder'].glob('logs/**/*.jsonl')):
                    with logfile.open('rb') as log:
                        log.seek(0,2); size=log.tell(); log.seek(max(0,size-150_000))
                        lines=log.read().splitlines()
                    for line in reversed(lines):
                        try:
                            envelope=json.loads(line)
                            event=envelope.get('event',envelope)
                            if 'iteration' in event:
                                latest={k:event[k] for k in ['kind','iteration','elapsedSeconds','clueMismatchCount','structuralIssueCount','best','snapshot'] if k in event}
                                break
                        except (json.JSONDecodeError,UnicodeDecodeError): pass
                    if latest: break
                status={'job':job['name'],'pid':process.pid,'state':'solved' if job['done'] else 'running',
                        'elapsedSeconds':job.get('result',{}).get('elapsedSeconds',time.monotonic()-job['start'])}
                if latest: status['latestProgress']=latest
                statuses.append(status)
            atomic(a.output/'status.json',{'updated_at_utc':datetime.now(timezone.utc).isoformat(),'time_cutoff':None,'jobs':statuses})
            if all(job['done'] for job in jobs): break
            if time.monotonic()>=next_notice:
                print(' | '.join(f"{s['job']}: {s['state']} {s['elapsedSeconds']:.0f}s" for s in statuses),flush=True)
                next_notice=time.monotonic()+60
            time.sleep(2)
    finally:
        for job in jobs:
            if job['process'].poll() is None: job['process'].terminate()
            if not job['stream'].closed: job['stream'].close()
