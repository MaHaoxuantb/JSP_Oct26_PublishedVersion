#!/usr/bin/env python3
"""Bounded real process check; these measurements never enter the campaign."""
from pathlib import Path
import argparse,json,sys,time
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'solver_bench'))
from completionqueue.agent import initialize,run
from completionqueue.common import atomic,read
from completionqueue.dashboard import aggregate,publish
from benchqueue.validation import evaluate

def main():
 p=argparse.ArgumentParser();p.add_argument('--directory',required=True);p.add_argument('--release',required=True);p.add_argument('--shape',required=True);a=p.parse_args()
 root=Path(a.directory);assert not root.exists();root.mkdir(parents=True)
 release=Path(a.release)
 config=dict(host='preflight',slots=4,seed=2026103099,trialSeconds=2,searchDeadline=time.time()+100,campaignDeadline=time.time()+120,
   worker=str(release/'completion-worker'),productionWorker=str(release/'production-worker'),shapeStore=a.shape,peers=[],puzzles=[])
 puzzles=[dict(id='smoke-'+str(i),n=3,clues=[99]+[-1]*8) for i in range(4)]
 config['puzzles']=puzzles;initialize(root,config,puzzles);run(root)
 s=read(root/'snapshot.json');assert len(s['jobs'])==20
 assert s['counts']=={'timeout':20},[(j['id'],j['status'],j['error']) for j in s['jobs'] if j['status']!='timeout']
 for j in s['jobs']:
  r=j['result'];assert not r['solved'] and r['singleThreaded'] and not r['gpuEnabled']
  assert j['series'] and r['seconds']>=1
  assert max(p['seconds'] for p in j['series'])<=r['seconds']+.05
 for board in puzzles:
  arms=[j for j in s['jobs'] if j['board_id']==board['id'] and j['method']!='E']
  assert len({json.dumps(j['series'][0]['quality'],sort_keys=True) for j in arms})==1
 publish(root,aggregate(root))
 print(json.dumps({'checks':'passed','trials':20,'counts':s['counts'],'methods':sorted({j['method'] for j in s['jobs']}),'directory':str(root)}))
if __name__=='__main__':main()
