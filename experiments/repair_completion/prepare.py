#!/usr/bin/env python3
"""Freeze a campaign without launching it. May be run on each host independently."""
from pathlib import Path
import argparse,json,shutil,sys,time,subprocess,platform
HERE=Path(__file__).resolve().parent;REPO=HERE.parent.parent
sys.path.insert(0,str(HERE.parent/'solver_bench'))
from completionqueue.common import NAME,COPYRIGHT,atomic,sha
from completionqueue.agent import initialize
from benchqueue.validation import validate_fixture

def prepare(root,host,slot,release,shape,launch_at,peers):
 root=Path(root).resolve()
 if root.exists():raise ValueError('Refusing to reuse an experiment directory')
 root.mkdir(parents=True);release=Path(release);source=root/'source'
 # Freeze shared code with its original relative package layout, without old result archives.
 for name in ['solver_bench','repair_completion']:
  shutil.copytree(HERE.parent/name,source/'experiments'/name,ignore=shutil.ignore_patterns('.build','__pycache__','analysis','results'))
 shutil.copytree(REPO/'JaneStreetPuzzle_Oct26',source/'JaneStreetPuzzle_Oct26')
 shutil.copy2(REPO/'Package.swift',source/'Package.swift');shutil.copy2(REPO/'EXPERIMENT-NAMING.md',source/'EXPERIMENT-NAMING.md')
 (root/'bin').mkdir();(root/'inputs').mkdir()
 for name in ['completion-worker','production-worker']:shutil.copy2(release/name,root/'bin'/name)
 # The seed database is frozen/read-only, not an active queue database.
 shutil.copy2(shape,root/'inputs/shapes.sqlite')
 assert sha(shape)==sha(root/'inputs/shapes.sqlite')
 fixture_path=HERE.parent/'solver_bench/analysis/final-20261030-120757/fixtures.json'
 fixtures=json.loads(fixture_path.read_text());selected=[b for b in fixtures if b['id'] in [f'n7-b{slot}',f'n8-b{slot}',f'n9-b{slot}']]
 assert len(selected)==3
 audits={b['id']:validate_fixture(b['certificate'],allow_unproven=True) for b in selected}
 preflight=json.loads(subprocess.check_output([str(root/'bin/production-worker'),'--preflight'],text=True))
 assert preflight['minimumPeerVersion']==preflight['softwareVersion']
 assert preflight['strictAcceptsCurrent'] and not preflight['strictAcceptsOlder']
 assert preflight['transitionalAcceptsLegacy'] and not preflight['transitionalAcceptsFuture']
 puzzles=[b['puzzle'] for b in selected]+[preflight['originalPuzzle']]
 # Admission witnesses stay in this private audit; timed inputs below contain clues only.
 atomic(root/'inputs/fixture-validation.json',dict(audits=audits,sourceSHA256=sha(fixture_path),boards=[dict(id=b['id'],solutionCount=b['solution_count']) for b in selected]))
 def sysctl(key):return subprocess.check_output(['sysctl','-n',key],text=True).strip()
 profile={k:sysctl(k) for k in ['hw.model','hw.physicalcpu','hw.logicalcpu','hw.perflevel0.physicalcpu','hw.memsize']}
 assert int(profile['hw.perflevel0.physicalcpu'])>=4
 config=dict(experiment=NAME,copyright=COPYRIGHT,host=host,slots=4,seed=2026103000+slot,
   trialSeconds=1200,launchAt=launch_at,searchDeadline=launch_at+112*60,campaignDeadline=launch_at+120*60,
   worker=str(root/'bin/completion-worker'),productionWorker=str(root/'bin/production-worker'),shapeStore=str(root/'inputs/shapes.sqlite'),
   source=str(source/'experiments/repair_completion'),puzzles=puzzles,profile=profile,softwareVersion=preflight['softwareVersion'],peers=peers)
 initialize(root,config,puzzles)
 files={str(p.relative_to(source)):sha(p) for p in source.rglob('*') if p.is_file()}
 atomic(root/'manifest.json',dict(experiment=NAME,copyright=COPYRIGHT,created=time.time(),host=host,
   softwareVersion=preflight['softwareVersion'],sourceHashes=files,binaryHashes={p.name:sha(p) for p in (root/'bin').iterdir()},shapeSHA256=sha(root/'inputs/shapes.sqlite'),profile=profile,
   swift=subprocess.check_output(['swift','--version'],text=True).strip(),python=sys.version,platform=platform.platform(),preflight=preflight))
 print(json.dumps({'directory':str(root),'trials':20,'host':host,'profile':profile}))
 return root
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--directory',required=True);p.add_argument('--host',required=True);p.add_argument('--slot',type=int,required=True,choices=[1,2]);p.add_argument('--release',required=True);p.add_argument('--shape',required=True);p.add_argument('--launch-at',type=float,default=time.time());p.add_argument('--peers',default='[]');a=p.parse_args()
 prepare(a.directory,a.host,a.slot,a.release,a.shape,a.launch_at,json.loads(a.peers))
