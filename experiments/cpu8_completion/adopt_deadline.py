"""JSP-Oct26-CPU8-Completion; ©2026 ThomasB. Amend timing without restarting search."""
import argparse,fcntl,hashlib,json,os,pathlib,shutil,signal,subprocess,time,uuid
from campaign import read,atomic,events,export,evaluate
VERSION=4

def alive(pid):
 try:os.kill(pid,0);return True
 except ProcessLookupError:return False

def process_command(pid):
 return subprocess.check_output(['/bin/ps','-p',str(pid),'-o','command='],text=True).strip()

def acquire(path):
 f=open(path,'a')
 for _ in range(100):
  try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);return f
  except BlockingIOError:time.sleep(.03)
 raise RuntimeError('Previous controller still holds the campaign lock')

def inspect(root,controller,worker,seconds,deadline):
 s=read(root/'snapshot.json');assert s and s['phase']=='running'
 active=[j for j in s['jobs'] if j['status']=='running'];assert len(active)==1
 job=active[0]
 assert not (root/'STOP').exists(),'Existing stop request takes precedence'
 assert 'campaign.py' in process_command(controller) and str(root) in process_command(controller)
 cmd=process_command(worker)
 assert str(root/'bin/cpu8-worker') in cmd and job['id'] in cmd
 assert seconds>0 and seconds<=3000 and time.time()<deadline
 assert sum(j['status']=='pending' for j in s['jobs'])<=1
 return s,job

def owned_stop(root,token,reason):
 try:
  fd=os.open(root/'STOP',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  with os.fdopen(fd,'w') as f:json.dump(dict(token=token,reason=reason),f)
  return True
 except FileExistsError:return False

def clear_owned_stop(root,token):
 value=read(root/'STOP')
 if isinstance(value,dict) and value.get('token')==token:
  (root/'STOP').unlink();return True
 return False

def refresh(root,job):
 out=root/job['id'];job['progress']=read(out/'cooperative.json',{})
 job['workers']=[dict(worker=i,progress=read(out/('worker-'+str(i))/'progress.json',{}),repairs=read(out/('worker-'+str(i))/'repair-progress.json',{})) for i in range(1,9)]
 job['series']=events(out/'global-events.jsonl')

def validate(result,puzzle):
 assert 3<=result.get('softwareVersion',-1)<=VERSION,'Worker version outside explicit transition'
 assert len(result['workers'])==8 and not result['gpuEnabled']
 check=evaluate(result['labels'],puzzle['n'],puzzle['clues']);q=result['quality']
 assert check['issues']==q['issues'] and check['wrong']==q['wrong'] and abs(check['residual']-q['residual'])<1e-12 and check['solved']==result['solved']
 return check

def main():
 p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--controller',type=int,required=True);p.add_argument('--worker',type=int,required=True);p.add_argument('--deadline',type=float,required=True);p.add_argument('--seconds',type=float,default=1800);p.add_argument('--inspect',action='store_true');a=p.parse_args()
 root=pathlib.Path(a.root);snap,active=inspect(root,a.controller,a.worker,a.seconds,a.deadline)
 if a.inspect:
  print(json.dumps(dict(workerPID=a.worker,active=active['id'],currentElapsed=time.time()-active['started'],effectiveBudget=a.seconds,activeCutoff=active['started']+a.seconds,reportDeadline=a.deadline)));return
 amend=root/'amendments'/'hour-deadline-v4';amend.mkdir(parents=True,exist_ok=False)
 atomic(amend/'config-before.json',read(root/'config.json'));atomic(amend/'snapshot-before.json',snap)
 for name in ['adopt_deadline.py','campaign.py']:
  shutil.copy2(pathlib.Path(__file__).parent/name,amend/name)
 atomic(amend/'amendment.json',dict(coordinatorSoftwareVersion=VERSION,workerSoftwareVersion=3,minimumPeerVersion=3,requestedReportDeadline=a.deadline,searchDeadline=a.deadline-300,previousController=a.controller,preservedWorker=a.worker,originalBudgetSeconds=3000,effectiveBudgetSeconds=a.seconds,appliedAt=time.time(),reason='User requested completion of this evaluation within one hour',sourceSHA256={n:hashlib.sha256((amend/n).read_bytes()).hexdigest() for n in ['adopt_deadline.py','campaign.py']}))
 # Terminate only the Python scheduler. Its existing native search survives;
 # no search signal or restart is used to adopt its observations and PID.
 os.kill(a.controller,signal.SIGTERM)
 campaign_lock=acquire(root/'campaign.lock');host_lock=acquire(root.parent/'.cpu8-active.lock')
 assert alive(a.worker) or (root/active['id']/'result.json').exists()
 config=dict(snap['config']);config.update(originalSeconds=config['seconds'],previousDeadline=config['deadline'],seconds=a.seconds,deadline=a.deadline-300,evaluationDeadline=a.deadline,coordinatorSoftwareVersion=VERSION,workerSoftwareVersion=3,minimumPeerVersion=3,budgetAmendment='User one-hour deadline; effective 1800-second total budget for each method. Active B work preserved, not restarted.')
 atomic(root/'config.json',config);jobs=snap['jobs'];current_pid=a.worker
 try:
  for job in jobs:
   if job['status'] not in ['running','pending']:continue
   if (root/'STOP').exists():break
   out=root/job['id'];job['budgetSeconds']=a.seconds
   if job['status']=='pending':
    if time.time()+a.seconds+20>config['deadline']:
     job.update(status='skipped',error='Cannot fit a complete amended budget before search deadline');continue
    out.mkdir(exist_ok=False);job.update(status='running',started=time.time())
    inp=dict(id=job['id'],puzzle=config['puzzle'],seed=config['seed'],seconds=a.seconds,threads=8,persistent=True,routeSelected=job['routeSelected'],shapeStore=str(root/'inputs/shapes.sqlite'),output=str(out),stopFile=str(root/'STOP'))
    atomic(out/'input.json',inp)
    with (out/'worker.log').open('w') as log:
     child=subprocess.Popen([str(root/'bin/cpu8-worker'),str(out/'input.json')],stdout=log,stderr=subprocess.STDOUT)
    current_pid=child.pid
   else:child=None
   job['workerPID']=current_pid;token=uuid.uuid4().hex;budget_stop=False;requested=None
   native_budget=read(out/'input.json')['seconds']
   # Existing B needs an external cutoff; a newly launched D has its own
   # amended native deadline and receives a short shutdown grace.
   stop_at=job['started']+a.seconds+(0 if native_budget>a.seconds else 5)
   export(root,config,jobs,'running',snap['started'])
   while alive(current_pid):
    if child and child.poll() is not None:break
    if (out/'result.json').exists():
     # Results are atomically published just before native process exit.
     if child:child.wait(timeout=10)
     else:
      for _ in range(100):
       if not alive(current_pid):break
       time.sleep(.03)
     break
    now=time.time()
    if requested is None and (now>=stop_at or now>=config['deadline']):
     budget_stop=owned_stop(root,token,'amended_budget' if now<config['deadline'] else 'campaign_deadline');requested=now
    if (root/'STOP').exists() and requested is None:requested=now
    if requested and now-requested>15:os.kill(current_pid,signal.SIGTERM)
    if requested and now-requested>20:os.kill(current_pid,signal.SIGKILL)
    refresh(root,job);export(root,config,jobs,'running',snap['started']);time.sleep(1)
   refresh(root,job);result=read(out/'result.json')
   if result:
    check=validate(result,config['puzzle'])
    # Preserve raw native reason/input. Budget censorship belongs to this amendment.
    recorded=dict(result,independentValidation=check,effectiveBudgetSeconds=a.seconds,originalBudgetSeconds=3000,budgetAmendment=budget_stop)
    atomic(out/'amended-validated-result.json',recorded)
    status='solved' if result['solved'] else 'budget_timeout' if budget_stop else 'interrupted' if result['reason']=='cancelled' else 'timeout'
    job.update(result=recorded,status=status)
   else:job.update(status='interrupted',error='No final native result; observations and checkpoints retained')
   job['ended']=time.time()
   if budget_stop:clear_owned_stop(root,token)
   export(root,config,jobs,'running',snap['started'])
  phase='stopped' if (root/'STOP').exists() else 'complete'
  export(root,config,jobs,phase,snap['started']);atomic(amend/'finished.json',dict(at=time.time(),phase=phase,controllerPID=os.getpid()))
 except BaseException as e:
  owned_stop(root,uuid.uuid4().hex,'controller_failure')
  atomic(amend/'failure.json',dict(error=str(e),at=time.time()))
  export(root,config,jobs,'failed',snap['started']);raise
 print('Amended evaluation finished',flush=True)
if __name__=='__main__':main()
