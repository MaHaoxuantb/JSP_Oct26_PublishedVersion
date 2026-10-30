"""One durable, bounded queue per host. No production process is managed here."""
from __future__ import annotations
import fcntl,json,os,signal,subprocess,sys,time
from pathlib import Path
from .common import METHODS,atomic,read,connect,rows,snapshot,SeriesReader,export
from benchqueue.validation import evaluate

def initialize(root,config,puzzles):
 root=Path(root);atomic(root/'config.json',config)
 with connect(root) as db:
  db.executescript('''PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
   CREATE TABLE jobs(id TEXT PRIMARY KEY,board_id TEXT,seed INTEGER,method TEXT,position INTEGER,
   status TEXT,started REAL,ended REAL,pid INTEGER,directory TEXT,result TEXT,error TEXT);''')
  for wave in range(5):
   for i,puzzle in enumerate(puzzles):
    method=list(METHODS)[(wave+i)%5];seed=config['seed'];identifier=f"{config['host']}-{puzzle['id']}-s{seed}-{method}"
    folder=root/'trials'/identifier;folder.mkdir(parents=True)
    worker=dict(jobID=identifier,puzzle=puzzle,condition=dict(representation='discrete',regional=True,newBP=True),seed=seed,budgetSeconds=config['trialSeconds'],shapeStore=config['shapeStore'],output=str(folder))
    info=METHODS[method];atomic(folder/'input.json',dict(worker=worker,persistent=info['persistent'],routeSelected=info['routeSelected']))
    db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',(identifier,puzzle['id'],seed,method,wave*len(puzzles)+i,'pending',None,None,None,str(folder),None,None))
 atomic(root/'state.json',dict(phase='ready',updated=time.time()))
 atomic(root/'snapshot.json',snapshot(root))

def finish(root,j,process,log):
 folder=Path(j['directory']);r=read(folder/'result.json');status='failed';error=None
 try:
  if process.returncode:raise ValueError(f"Worker exited {process.returncode}; see worker.log")
  if not r:raise ValueError('No result file')
  inp=read(folder/'input.json')['worker'];p=inp['puzzle'];check=evaluate(r['labels'],p['n'],p['clues'])
  for key in ['issues','wrong']:
   if check[key]!=r['quality'][key]:raise ValueError('Independent validation disagrees: '+key)
  if abs(check['residual']-r['quality']['residual'])>1e-9 or check['solved']!=r['solved']:raise ValueError('Independent result mismatch')
  if r.get('answer')!=check['answer']:raise ValueError('Answer mismatch')
  if r['cpuSeconds']/max(r['seconds'],0.001)>1.15:raise ValueError('CPU/wall ratio exceeds single-search allowance')
  if not r['solved'] and (r['seconds']<inp['budgetSeconds']-1 or r['reason'] not in ['time_limit','timeLimit']):raise ValueError('Early unsolved stop is not a timeout')
  if r['seconds']>inp['budgetSeconds']+15:raise ValueError('Worker exceeded watchdog allowance')
  r['independentValidation']=check
  r['executionWallSeconds']=max(0,(folder/'result.json').stat().st_mtime-j['started'])
  status='solved' if check['solved'] else 'timeout'
 except Exception as exc:error=str(exc)
 log.close()
 with connect(root) as db:db.execute('UPDATE jobs SET status=?,ended=?,result=?,error=? WHERE id=?',(status,time.time(),json.dumps(r) if r else None,error,j['id']))

def run(root):
 root=Path(root);lock=(root/'agent.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 config=read(root/'config.json');active={};reader=SeriesReader();last=0;stopping=False
 with connect(root) as db:
  old=db.execute("SELECT count(*) FROM jobs WHERE status='running'").fetchone()[0]
  if old:raise RuntimeError('Unreconciled running jobs; refusing duplicate/replayed workers')
 def stop(*_):
  nonlocal stopping
  stopping=True
 signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
 atomic(root/'state.json',dict(phase='running',pid=os.getpid(),started=time.time(),deadline=config['searchDeadline']))
 while True:
  if (root/'STOP').exists() or time.time()>=config['searchDeadline']:stopping=True
  for identifier,(j,p,log) in list(active.items()):
   if p.poll() is None and (stopping or time.time()-j['started']>config['trialSeconds']+15):
    p.terminate()
    try:p.wait(timeout=3)
    except subprocess.TimeoutExpired:p.kill();p.wait()
    log.close()
    with connect(root) as db:db.execute('UPDATE jobs SET status=?,ended=?,error=? WHERE id=?',('interrupted' if stopping else 'failed',time.time(),'campaign deadline/stop' if stopping else 'watchdog exceeded',identifier))
    del active[identifier]
   elif p.poll() is not None:
    finish(root,j,p,log);del active[identifier]
  pending=[j for j in rows(root) if j['status']=='pending']
  if not stopping:
   for j in pending[:max(0,config['slots']-len(active))]:
    if time.time()+config['trialSeconds']+15>config['searchDeadline']:
     with connect(root) as db:db.execute("UPDATE jobs SET status='skipped',error='insufficient full-trial window' WHERE id=?",(j['id'],))
     continue
    folder=Path(j['directory']);binary=config['productionWorker'] if j['method']=='E' else config['worker']
    log=(folder/'worker.log').open('ab');started=time.time()
    p=subprocess.Popen([binary,str(folder/'input.json')],stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    j.update(started=started,pid=p.pid,status='running')
    with connect(root) as db:db.execute("UPDATE jobs SET status='running',started=?,pid=? WHERE id=?",(started,p.pid,j['id']))
    active[j['id']]=(j,p,log)
  if time.time()-last>=3:
   snap=snapshot(root,reader);atomic(root/'snapshot.json',snap);export(root,snap);last=time.time()
  if not active and (stopping or not any(j['status']=='pending' for j in rows(root))):break
  time.sleep(.25)
 atomic(root/'state.json',dict(phase='stopped' if stopping else 'complete',pid=os.getpid(),ended=time.time(),deadline=config['searchDeadline']))
 snap=snapshot(root,reader);atomic(root/'snapshot.json',snap);export(root,snap)
