"""JSP-Oct26-CPU8-Completion; ©2026 ThomasB. Incumbent-seeded CPU-only search."""
import argparse,fcntl,hashlib,json,os,pathlib,shutil,subprocess,time
from campaign import read,atomic,events,evaluate
NAME='JSP-Oct26-CPU8-Completion'
VERSION=5

def validate(result,puzzle,version=True):
 if version:assert result['softwareVersion']==VERSION,'Unexpected worker release'
 assert result['puzzle']['n']==puzzle['n'] and result['puzzle']['clues']==puzzle['clues']
 assert len(result['workers'])==8 and not result['gpuEnabled']
 for record in [result]+result['workers']:
  check=evaluate(record['labels'],puzzle['n'],puzzle['clues']);q=record['quality']
  assert check['issues']==q['issues'] and check['wrong']==q['wrong'] and abs(check['residual']-q['residual'])<1e-12
  assert check['solved']==record['solved']
 return evaluate(result['labels'],puzzle['n'],puzzle['clues'])

def refresh(out,job):
 job['progress']=read(out/'cooperative.json',{})
 job['workers']=[dict(worker=i,progress=read(out/f'worker-{i}/progress.json',{}),repairs=read(out/f'worker-{i}/repair-progress.json',{})) for i in range(1,9)]
 job['series']=events(out/'global-events.jsonl')

def publish(root,config,jobs,phase,started):
 snap=dict(experiment=NAME,copyright='©2026 ThomasB',author='ThomasB',config=config,jobs=jobs,phase=phase,started=started,updated=time.time())
 atomic(root/'snapshot.json',snap)
 report=root/'report';report.mkdir(exist_ok=True)
 atomic(report/(NAME+'-Results.json'),snap)
 lines=['# '+NAME+'-Continuation','','©2026 ThomasB','','Author: ThomasB','',f'Phase: {phase}. Persistent BP only, original 11×11 puzzle, eight cooperating CPU threads; no GPU. Fan controls unchanged.','',f'Seed source: `{config["seedSource"]}`. Independently checked starting quality: {config["startingQuality"]}.','',f'Segments last up to {config["seconds"]:g} seconds and run sequentially until a validated solve or STOP. Each segment inherits the previous eight best worker states, uses new random streams and rebuilds in-memory BP stacks. This is incumbent continuation, not exact process resumption. The prior evaluation remains unchanged.','','| Segment | Status | Seconds | Wrong clues | Residual | CPU equivalents |','| --- | --- | ---: | ---: | ---: | ---: |']
 for j in jobs:
  v=j.get('result') or j.get('progress') or {};q=v.get('quality') or {}
  lines.append(f'| {j["id"]} | {j["status"]} | {v.get("seconds",0):.1f} | {q.get("wrong","—")} | {q.get("residual","—")} | {v.get("cpuEquivalentCores",0):.2f} |')
 lines+=['','Only independent rule validation establishes a solution. Energy is not a progress percentage or a remaining-time estimate. Cancellation retains checkpoints and outputs.','',f'Stop by creating `{root / "STOP"}`.']
 (report/(NAME+'-Report.md')).write_text('\n'.join(lines)+'\n')
 import csv
 with (report/(NAME+'-Trials.csv')).open('w') as f:
  w=csv.writer(f);w.writerow(['segment','status','seconds','wrong','residual','cpuEquivalentCores'])
  for j in jobs:
   v=j.get('result') or j.get('progress') or {};q=v.get('quality') or {};w.writerow([j['id'],j['status'],v.get('seconds'),q.get('wrong'),q.get('residual'),v.get('cpuEquivalentCores')])

def main():
 p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--binary',required=True);p.add_argument('--seed-result',required=True);p.add_argument('--shape',required=True);p.add_argument('--seconds',type=float,default=3000);p.add_argument('--max-segments',type=int,default=0);a=p.parse_args()
 assert 0<a.seconds<=3000 and a.max_segments>=0
 root=pathlib.Path(a.root);root.parent.mkdir(parents=True,exist_ok=True)
 host_lock=open(root.parent/'.cpu8-active.lock','a');fcntl.flock(host_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 assert subprocess.run(['/usr/bin/pgrep','-x','cpu8-worker'],stdout=subprocess.DEVNULL).returncode==1,'Another CPU8 solver is running'
 root.mkdir(exist_ok=False);(root/'inputs').mkdir();(root/'bin').mkdir()
 binary=root/'bin/cpu8-worker';shutil.copy2(a.binary,binary)
 source=pathlib.Path(a.seed_result);seed=root/'inputs/seed-result.json';shutil.copy2(source,seed)
 original=read(seed);puzzle=original['puzzle'];check=validate(original,puzzle,version=False)
 assert puzzle['n']==11 and sum(t>=0 for t in puzzle['clues'])==33
 shape=pathlib.Path(a.shape);assert shape.is_file()
 config=dict(seconds=a.seconds,threads=8,simultaneousPuzzles=1,puzzle=puzzle,seed=2026103050,softwareVersion=VERSION,minimumPeerVersion=VERSION,gpuEnabled=False,continuation=True,seedSource=str(source),startingQuality=original['quality'],priorSearchSeconds=original['seconds'],fanControl='unchanged; existing controls')
 atomic(root/'config.json',config)
 atomic(root/'manifest.json',dict(experiment=NAME,copyright='©2026 ThomasB',author='ThomasB',softwareVersion=VERSION,binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),seedSHA256=hashlib.sha256(seed.read_bytes()).hexdigest(),shapeSHA256=hashlib.sha256(shape.read_bytes()).hexdigest(),shapeStore=str(shape),seedIndependentValidation=check,sourceDirectory=str(pathlib.Path(__file__).resolve().parents[2])))
 jobs=[];started=time.time();publish(root,config,jobs,'ready',started);index=0;proc=None
 try:
  while not (root/'STOP').exists() and (not a.max_segments or index<a.max_segments):
   index+=1;job=dict(id=f'original11-B-continuation-{index:04d}',method='B',label=f'Persistent BP · segment {index}',routeSelected=False,status='running',started=time.time(),series=[],seedSource=str(seed))
   out=root/job['id'];out.mkdir();jobs.append(job)
   inp=dict(id=job['id'],puzzle=puzzle,seed=(config['seed']+index*100003)&((1<<64)-1),seconds=a.seconds,threads=8,persistent=True,routeSelected=False,shapeStore=str(shape),output=str(out),stopFile=str(root/'STOP'),seedResult=str(seed))
   atomic(out/'input.json',inp)
   with (out/'worker.log').open('w') as log:proc=subprocess.Popen([str(binary),str(out/'input.json')],stdout=log,stderr=subprocess.STDOUT)
   job['workerPID']=proc.pid;publish(root,config,jobs,'running',started);stop_at=None
   while proc.poll() is None:
    if time.time()-job['started']>a.seconds+30:(root/'STOP').touch()
    if (root/'STOP').exists():
     if stop_at is None:stop_at=time.time()
     if time.time()-stop_at>30:proc.terminate()
     if time.time()-stop_at>40:proc.kill()
    refresh(out,job);publish(root,config,jobs,'stopping' if (root/'STOP').exists() else 'running',started);time.sleep(3 if a.seconds>=30 else .25)
   refresh(out,job);result=read(out/'result.json')
   assert proc.returncode==0 and result,'Worker failed; checkpoints retained'
   result['independentValidation']=validate(result,puzzle)
   oldq=read(seed)['quality'];q=result['quality']
   assert (q['issues'],q['wrong'],q['residual'])<=(oldq['issues'],oldq['wrong'],oldq['residual']),'Continuation lost the incumbent'
   atomic(out/'validated-result.json',result);atomic(root/'best-result.json',result)
   job.update(result=result,ended=time.time(),status='solved' if result['solved'] else 'interrupted' if result['reason']=='cancelled' else 'timeout')
   seed=out/'validated-result.json';publish(root,config,jobs,'running',started)
   if result['solved']:break
  phase='solved' if jobs and jobs[-1]['status']=='solved' else 'stopped' if (root/'STOP').exists() else 'complete'
  publish(root,config,jobs,phase,started)
 except BaseException as error:
  (root/'STOP').touch()
  if proc and proc.poll() is None:
   try:proc.wait(timeout=35)
   except subprocess.TimeoutExpired:proc.terminate();proc.wait(timeout=10)
  atomic(root/'failure.json',dict(error=str(error),at=time.time()));publish(root,config,jobs,'failed',started);raise
 print('Continuation finished: '+phase,flush=True)
if __name__=='__main__':main()
