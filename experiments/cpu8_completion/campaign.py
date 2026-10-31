"""JSP-Oct26-CPU8-Completion; ©2026 ThomasB. Single-puzzle, CPU-only queue."""
import argparse,csv,fcntl,hashlib,json,os,pathlib,shutil,subprocess,sys,time
HERE=pathlib.Path(__file__).resolve().parent;REPO=HERE.parent.parent
sys.path.insert(0,str(REPO/'experiments/solver_bench'))
from benchqueue.validation import evaluate
NAME='JSP-Oct26-CPU8-Completion'
def read(p,default=None):
 try:return json.loads(pathlib.Path(p).read_text())
 except (OSError,ValueError):return default

def atomic(p,v):
 p=pathlib.Path(p);q=p.with_name(p.name+'.tmp');q.write_text(json.dumps(v,ensure_ascii=False));q.replace(p)
def events(path):
 out=[]
 try:
  for line in path.read_text().splitlines():
   try:out.append(json.loads(line))
   except ValueError:pass
 except OSError:pass
 return out
def export(root,config,jobs,phase,started):
 snap=dict(experiment=NAME,copyright='©2026 ThomasB',author='ThomasB',config=config,jobs=jobs,phase=phase,started=started,updated=time.time())
 atomic(root/'snapshot.json',snap)
 folder=root/'report';folder.mkdir(exist_ok=True)
 atomic(folder/(NAME+'-Results.json'),snap)
 lines=['# '+NAME+'-Report','','©2026 ThomasB','','Author: ThomasB','',f"CPU-only; eight cooperating threads on one original 11×11 puzzle. Effective budget {config['seconds']:g} seconds per method; original cap 3,000 seconds. Original controls A/E and route-only C are not scheduled. Fan and thermal control remain under macOS.",'','Phase: '+phase,'','| Method | State | Elapsed seconds | CPU equivalents | Incorrect clues | Residual | Solved |','| --- | --- | ---: | ---: | ---: | ---: | --- |']
 if config.get('budgetAmendment'):
  lines += ['', 'Budget amendment: '+config['budgetAmendment'], 'A cancelled native result stopped by this amended budget is recorded as budget_timeout, not a completed original 3,000-second trial.']
 for job in jobs:
  v=job.get('result') or job.get('progress') or {};q=v.get('quality') or {}
  lines.append('| %s | %s | %.1f | %.2f | %s | %s | %s |'%(job['label'],job['status'],v.get('seconds',0),v.get('cpuEquivalentCores',0),q.get('wrong','—'),q.get('residual','—'),v.get('solved',False)))
 lines+=['','Only independently validated solutions count. Interim energy and node counts do not estimate remaining solve time. This eight-thread study is separate from the earlier one-thread dataset. Each method starts fresh with the same eight-seed schedule; no incumbent crosses methods.','', 'Individual worker CPU times use thread clocks. Aggregate CPU equivalents use process CPU time. Timer categories inside search overlap and must not be added. Snapshots/checkpoints support inspection and explicit recovery, not transparent exact process resumption.','', 'Run directory: `'+str(root)+'`']
 (folder/(NAME+'-Report.md')).write_text('\n'.join(lines)+'\n')
 with (folder/(NAME+'-Trials.csv')).open('w') as f:
  w=csv.writer(f);w.writerow(['method','state','seconds','cpuEquivalentCores','wrong','residual','solved'])
  for j in jobs:
   v=j.get('result') or j.get('progress') or {};q=v.get('quality') or {};w.writerow([j['method'],j['status'],v.get('seconds'),v.get('cpuEquivalentCores'),q.get('wrong'),q.get('residual'),v.get('solved')])
 return snap

def main():
 p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--binary',required=True);p.add_argument('--shape',required=True);p.add_argument('--puzzle',required=True);p.add_argument('--seconds',type=float,default=3000);p.add_argument('--window',type=float,default=7200);p.add_argument('--smoke',action='store_true');a=p.parse_args()
 root=pathlib.Path(a.root);root.mkdir(parents=True,exist_ok=False);lock=open(root/'campaign.lock','w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 host_lock=open(root.parent/'.cpu8-active.lock','w');fcntl.flock(host_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 (root/'bin').mkdir();(root/'inputs').mkdir();binary=root/'bin/cpu8-worker';shutil.copy2(a.binary,binary)
 shape=root/'inputs/shapes.sqlite';shutil.copy2(a.shape,shape)
 assert hashlib.sha256(shape.read_bytes()).hexdigest()==hashlib.sha256(pathlib.Path(a.shape).read_bytes()).hexdigest()
 puzzle=read(a.puzzle);assert puzzle['n']==11 and sum(x>=0 for x in puzzle['clues'])==33
 atomic(root/'inputs/puzzle.json',puzzle)
 sources={}
 for directory in ['solver_bench','repair_completion','cpu8_completion']:
  dest=root/'source/experiments'/directory;shutil.copytree(REPO/'experiments'/directory,dest,ignore=shutil.ignore_patterns('.build','results','analysis','__pycache__'))
 shutil.copytree(REPO/'JaneStreetPuzzle_Oct26',root/'source/JaneStreetPuzzle_Oct26')
 for f in (root/'source').rglob('*'):
  if f.is_file():sources[str(f.relative_to(root/'source'))]=hashlib.sha256(f.read_bytes()).hexdigest()
 preflight=read(pathlib.Path(a.binary).parent/'authority-preflight.json');assert preflight['softwareVersion']==3 and preflight['minimumPeerVersion']==3
 started=time.time();deadline=started+a.window
 config=dict(seconds=a.seconds,deadline=deadline,threads=8,simultaneousPuzzles=1,puzzle=puzzle,seed=2026103008,softwareVersion=3,gpuEnabled=False,fanControl='macOS automatic; no settings changed',smoke=a.smoke)
 atomic(root/'config.json',config);atomic(root/'manifest.json',dict(experiment=NAME,copyright='©2026 ThomasB',author='ThomasB',sourceSHA256=sources,binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),shapeSHA256=hashlib.sha256(shape.read_bytes()).hexdigest(),preflight=preflight))
 jobs=[dict(id='original11-'+m+'-cpu8-s2026103008',method=m,label=label,routeSelected=route,status='pending',series=[]) for m,label,route in [('B','Persistent BP',False),('D','Persistent BP + route-guided repairs',True)]]
 export(root,config,jobs,'ready',started)
 for job in jobs:
  if (root/'STOP').exists():break
  if time.time()+a.seconds+20>deadline:job.update(status='skipped',error='Insufficient time for a complete 3000-second allowance');continue
  out=root/job['id'];out.mkdir();job.update(status='running',started=time.time())
  inp=dict(id=job['id'],puzzle=puzzle,seed=config['seed'],seconds=a.seconds,threads=8,persistent=True,routeSelected=job['routeSelected'],shapeStore=str(shape),output=str(out),stopFile=str(root/'STOP'))
  atomic(out/'input.json',inp);export(root,config,jobs,'running',started)
  with (out/'worker.log').open('w') as log:
   proc=subprocess.Popen([str(binary),str(out/'input.json')],stdout=log,stderr=subprocess.STDOUT)
   while proc.poll() is None:
    if time.time()>deadline or time.time()-job['started']>a.seconds+20:(root/'STOP').touch()
    if time.time()-job['started']>a.seconds+40:proc.terminate()
    progress=read(out/'cooperative.json',{})
    workers=[]
    for index in range(1,9):
     d=out/('worker-'+str(index));v=read(d/'progress.json',{});workers.append(dict(worker=index,progress=v,repairs=read(d/'repair-progress.json',{})))
    job['progress']=progress;job['workers']=workers
    job['series']=events(out/'global-events.jsonl')
    export(root,config,jobs,'stopping' if (root/'STOP').exists() else 'running',started)
    time.sleep(.5 if a.smoke else 3)
  result=read(out/'result.json')
  if proc.returncode!=0 or not result:job.update(status='failed',error='Worker exit '+str(proc.returncode));(root/'STOP').touch()
  else:
   check=evaluate(result['labels'],11,puzzle['clues']);q=result['quality']
   assert check['issues']==q['issues'] and check['wrong']==q['wrong'] and abs(check['residual']-q['residual'])<1e-12 and check['solved']==result['solved']
   assert len(result['workers'])==8 and not result['gpuEnabled']
   result['independentValidation']=check;atomic(out/'validated-result.json',result)
   job.update(result=result,status='solved' if result['solved'] else 'interrupted' if result['reason']=='cancelled' else 'timeout')
  job['ended']=time.time();export(root,config,jobs,'running',started)
 export(root,config,jobs,'stopped' if (root/'STOP').exists() else 'complete',started)
 print('Campaign finished',flush=True)
if __name__=='__main__':main()
