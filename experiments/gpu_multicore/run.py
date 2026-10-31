"""JSP-Oct26-GPU-Multicore; ©2026 ThomasB. One solver process at a time."""
import argparse,datetime,fcntl,hashlib,json,os,pathlib,plistlib,subprocess,time,shutil
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--root',required=True);p.add_argument('--seconds',type=float,default=90);p.add_argument('--smoke',action='store_true');a=p.parse_args()
root=pathlib.Path(a.root);root.mkdir(parents=True,exist_ok=False)
lock=open(root/'run.lock','w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
source_root=pathlib.Path(__file__).resolve().parents[2]
source_files=list((source_root/'JaneStreetPuzzle_Oct26').glob('*.swift'))+list((source_root/'experiments/gpu_multicore').glob('*'))
source_hashes={}
for src in source_files:
 if not src.is_file():continue
 rel=src.relative_to(source_root);dest=root/'source'/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dest);source_hashes[str(rel)]=hashlib.sha256(src.read_bytes()).hexdigest()
(root/'bin').mkdir();binary=root/'bin'/'multicore-worker';shutil.copy2(a.binary,binary)

def write(name,value):
 target=root/name;temp=target.with_suffix(target.suffix+'.tmp');temp.write_text(json.dumps(value,ensure_ascii=False,indent=2));temp.replace(target)
def gpu_usage():
 try:
  d=plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg','-r','-c','IOAccelerator','-a'],timeout=2))
  return [dict(device=x.get('IOClass'),stats=x.get('PerformanceStatistics')) for x in d]
 except Exception as e:return dict(error=str(e))
write('manifest.json',dict(experiment='JSP-Oct26-GPU-Multicore',copyright='©2026 ThomasB',author='ThomasB',created=time.time(),binarySHA256=hashlib.sha256(pathlib.Path(a.binary).read_bytes()).hexdigest(),seconds=a.seconds,smoke=a.smoke,cpuWorkers=8,gpuAvailableCores=10,gpuLimit='full device; no affinity enforcement',order='CPU-GPU-GPU-CPU',seeds=[2026103011,2026103012],originalPuzzle=True,sourceSHA256=source_hashes))
background=[]
for i in range(3):background.append(dict(at=time.time(),gpu=gpu_usage()));time.sleep(0.5)
write('background.json',background)
runs=[(2026103011,False),(2026103011,True)] if a.smoke else [(2026103011,False),(2026103011,True),(2026103012,True),(2026103012,False)]
summaries=[]
for idx,(seed,gpu) in enumerate(runs):
 name='%02d-s%d-%s'%(idx+1,seed,'cpu8-fullGPU' if gpu else 'cpu8');folder=root/name;folder.mkdir()
 inp=dict(id=name,seed=seed,budgetSeconds=a.seconds,gpu=gpu,threads=8,output=str(folder));(folder/'input.json').write_text(json.dumps(inp))
 write('state.json',dict(phase='running',run=name,index=idx,total=len(runs),completed=summaries))
 print('Starting',name,flush=True);start=time.time();samples=[]
 with (folder/'worker.log').open('w') as log:
  proc=subprocess.Popen([str(binary),str(folder/'input.json')],stdout=log,stderr=subprocess.STDOUT)
  try:
   while proc.poll() is None:
    if time.time()-start>a.seconds+30:proc.terminate();raise TimeoutError('Solver exceeded wall cutoff plus 30s drain allowance')
    ps=subprocess.check_output(['/bin/ps','-p',str(proc.pid),'-o','pid=,pcpu=,rss=,time='],text=True).strip() if proc.poll() is None else ''
    samples.append(dict(seconds=time.time()-start,process=ps,gpu=gpu_usage()))
    time.sleep(min(2,max(0.2,a.seconds/5)))
  finally:
   if proc.poll() is None:
    proc.terminate()
    try:proc.wait(timeout=10)
    except subprocess.TimeoutExpired:proc.kill();proc.wait()
 (folder/'host-samples.json').write_text(json.dumps(samples))
 result=json.load(open(folder/'result.json')) if (folder/'result.json').exists() else dict(error='No result')
 result.update(exitCode=proc.returncode,spawnToExitSeconds=time.time()-start)
 if proc.returncode!=0 or result.get('error'):raise RuntimeError(result)
 if len(result['workers'])!=8:raise RuntimeError('Not eight completed worker records')
 if gpu and (result['gpu']['boards']==0 or any(w['fallback'] for w in result['workers'])):raise RuntimeError('GPU did not run or silently fell back')
 summaries.append(result);write('results.json',summaries)
 print('Finished',name,'seconds',result['seconds'],'CPU cores',result['cpuEquivalentCores'],'iterations',result['iterations'],'energy',result['commonEnergy'],flush=True)
 # Drain completed process before any next solver begins.
 time.sleep(1)
write('state.json',dict(phase='finished',completed=len(summaries),ended=time.time()));print('All runs finished',flush=True)
