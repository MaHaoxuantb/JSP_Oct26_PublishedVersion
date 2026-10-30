"""Durable, process-isolated campaign coordinator. No solver threads live here."""
from __future__ import annotations
import fcntl,json,os,random,signal,subprocess,sys,time,uuid
from pathlib import Path
from .storage import Store,atomic_json,read_json,digest,now
from .validation import validate_certificate,validate_fixture,puzzle_orbit_key,evaluate,canonical_partition
from .reporting import export_report

def conditions():
    return [dict(representation=d,regional=r,newBP=b) for d in ['discrete','continuous'] for r in [False,True] for b in [False,True]]
def condition_id(c):return f"{c['representation']}-r{int(c['regional'])}-b{int(c['newBP'])}"
def alive(pid):
    if not pid:return False
    try:
        status=subprocess.check_output(['ps','-p',str(pid),'-o','stat='],text=True).strip()
        return bool(status) and not status.startswith('Z')
    except subprocess.CalledProcessError:return False

def owns(pid,marker):
    if not alive(pid):return False
    try:return str(marker) in subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True)
    except subprocess.CalledProcessError:return False

def find_owned(marker):
    try:
        listing=subprocess.check_output(['ps','-axo','pid=,args='],text=True)
        for line in listing.splitlines():
            fields=line.strip().split(None,1)
            if len(fields)==2 and str(marker) in fields[1] and int(fields[0])!=os.getpid():return int(fields[0])
    except (subprocess.CalledProcessError,ValueError):pass
    return None

def terminate(pid,marker):
    if owns(pid,marker):
        os.kill(pid,signal.SIGTERM)
        for _ in range(30):
            if not alive(pid):return
            time.sleep(.1)
        if owns(pid,marker):os.kill(pid,signal.SIGKILL)

def admit(store,task,state):
    """Only exhausted certificates enter the board table. Different D4 clue boards."""
    existing=store.rows('boards');best=next((b for b in existing if b['n']==task['n'] and b['slot']==task['slot']),None)
    other={puzzle_orbit_key(json.loads(b['puzzle'])) for b in existing if b['id']!=(best or {}).get('id')}
    for certificate in sorted(state['qualified'],key=lambda x:x['solutionCount']):
        audit=validate_certificate(certificate);p=certificate['puzzle']
        if puzzle_orbit_key(p) in other:continue
        if best and best['solution_count']<=certificate['solutionCount']:continue
        board_id=f"n{task['n']}-b{task['slot']+1}";certificate=dict(certificate);p=dict(p,id=board_id);certificate['puzzle']=p;certificate['audit']=audit
        encoded=json.dumps(p,sort_keys=True);import hashlib
        with store.connect() as db:db.execute('INSERT OR REPLACE INTO boards VALUES(?,?,?,?,?,?,?)',(board_id,task['n'],task['slot'],encoded,json.dumps(certificate),certificate['solutionCount'],hashlib.sha256(encoded.encode()).hexdigest()))
        store.event('certified',f"{board_id}: exactly {certificate['solutionCount']} partition(s)")
        best={'solution_count':certificate['solutionCount'],'id':board_id}
    return bool(best and best['solution_count']==1)

def freeze_current_puzzles(store):
    """Explicit user override: use current clues, requiring a valid witness, not uniqueness."""
    if store.rows('jobs'):raise ValueError('Trials already exist; frozen fixtures cannot be changed')
    config=store.get('config')
    if config.get('admission_policy')!='validated_witness':raise ValueError('Witness-only admission must be explicitly selected')
    existing={b['id']:b for b in store.rows('boards')};prepared={p['id']:p for p in store.rows('prep')};pending=[]
    for n in config['sizes']:
        for slot in range(config['boards_per_size']):
            identifier=f'n{n}-b{slot+1}'
            if identifier in existing:
                validate_fixture(json.loads(existing[identifier]['certificate']),True);continue
            task=prepared.get(identifier)
            state=read_json(task['state_path']) if task else None
            if not state or not state.get('puzzle') or not state.get('witness'):raise ValueError(f'{identifier} has no current puzzle and witness')
            original=state['puzzle'];puzzle=dict(original,id=identifier)
            if puzzle['n']!=n:raise ValueError('Preparation size mismatch')
            labels=list(canonical_partition(state['witness']));known=[labels]
            for solution in (state.get('search') or {}).get('solutions',[]):
                candidate=list(canonical_partition(solution))
                if candidate not in known:known.append(candidate)
            values=[evaluate(x,n,puzzle['clues']) for x in known]
            if any(not value['solved'] for value in values):raise ValueError(f'{identifier}: invalid saved witness')
            record=dict(puzzle=puzzle,solutionCount=None,solutions=known,answers=sorted({v['answer'] for v in values}),exhausted=False,rules='symmetric-capitol-integer-paths-v1',generator='orbit-connected-subsets-v1',nodes=state.get('nodes',0)+(state.get('search') or {}).get('counters',{}).get('nodes',0),knownSolutionCountLowerBound=len(known),preparationPuzzleID=original['id'],admission='validated_witness')
            record['audit']=validate_fixture(record,True)
            import hashlib
            encoded=json.dumps(puzzle,sort_keys=True)
            pending.append((identifier,n,slot,encoded,json.dumps(record),None,hashlib.sha256(encoded.encode()).hexdigest()))
    all_puzzles=[json.loads(b['puzzle']) for b in existing.values()]+[json.loads(row[3]) for row in pending]
    if len({(p['n'],puzzle_orbit_key(p)) for p in all_puzzles})!=len(all_puzzles):raise ValueError('Current puzzles contain symmetry-equivalent duplicates')
    with store.connect() as db:db.executemany('INSERT INTO boards VALUES(?,?,?,?,?,?,?)',pending)
    store.set('certification_waived_at',now());store.event('admission','User requested current puzzles without uniqueness certification; every admitted puzzle has an independently validated solution',{'newUnprovenBoards':len(pending)})
    freeze_jobs(store)

def freeze_jobs(store):
    config=store.get('config');boards=store.rows('boards','ORDER BY n,slot');required=len(config['sizes'])*config['boards_per_size']
    if len(boards)!=required:raise ValueError('Preparation gate not satisfied')
    allow_unproven=config.get('admission_policy')=='validated_witness'
    for b in boards:
        if not allow_unproven and b['solution_count'] not in (1,2,3):raise ValueError('Preparation gate not satisfied')
        validate_fixture(json.loads(b['certificate']),allow_unproven)
    if len({(b['n'],puzzle_orbit_key(json.loads(b['puzzle']))) for b in boards})!=required:raise ValueError('Duplicate boards')
    if digest(config['shape_store'])!=store.get('shape_sha256'):raise ValueError('Frozen shape store changed')
    fixtures=store.directory/'fixtures';fixtures.mkdir(exist_ok=True)
    for b in boards:atomic_json(fixtures/(b['id']+'.json'),json.loads(b['certificate']))
    rng=random.Random(config['order_seed']);blocks=[(b,s) for b in boards for s in config['seeds']];rng.shuffle(blocks)
    rows=[]
    # Balanced condition rotations across matched board/seed blocks; shuffled block order.
    order=conditions();rng.shuffle(order)
    for index,(b,seed) in enumerate(blocks):
        rotation=index%8;block=order[rotation:]+order[:rotation]
        for c in block:
            identifier=f"{b['id']}-{condition_id(c)}-s{seed}";rows.append((identifier,b['id'],json.dumps(c),seed,'pending',0,len(rows)))
    with store.connect() as db:db.executemany('INSERT OR IGNORE INTO jobs(id,board_id,condition,seed,status,attempt,launch_index) VALUES(?,?,?,?,?,?,?)',rows)
    store.set('fixtures_frozen',now());store.set('phase','running');store.event('gate','All boards have validated solutions; timed queue created (uniqueness not required)' if allow_unproven else 'All boards certified; timed queue created')
    export_report(store)

def validate_result(result,job,puzzle,config):
    if result['jobID']!=job['id'] or result['puzzleID']!=puzzle['id'] or result['condition']!=json.loads(job['condition']) or result['seed']!=job['seed']:raise ValueError('Worker identity mismatch')
    check=evaluate(result['labels'],puzzle['n'],puzzle['clues']);q=result['quality']
    if check['solved']!=result['solved'] or check['issues']!=q['issues'] or check['wrong']!=q['wrong'] or abs(check['residual']-q['residual'])>1e-10 or check['answer']!=result.get('answer'):raise ValueError('Independent result validation failed')
    if not result['singleThreaded'] or result['gpuEnabled']:raise ValueError('Worker resource contract violated')
    if not 0<=result['cpuSeconds']<=result['seconds']*1.15+.15:raise ValueError('More than one CPU core worth of measured work')
    if result['seconds']>config['trial_seconds']+5:raise ValueError('Cooperative time limit exceeded')
    if result['condition']['representation']=='discrete' and any(x not in (0,1) for x in result['strengths']):raise ValueError('Non-binary discrete state')
    if not result['solved'] and result['reason']!='time_limit':raise ValueError('Unexpected terminal result')
    if not result['solved'] and result['seconds']<config['trial_seconds']-.05:raise ValueError('Unsolved worker stopped before the trial cutoff')
    return 'solved' if check['solved'] else 'timeout'

class Controller:
    def __init__(self,directory):
        self.store=Store(directory);self.root=self.store.directory;self.config=self.store.get('config');self.processes={};self.preparing={};self.stop=False
    def launch(self,args,log):
        Path(log).parent.mkdir(parents=True,exist_ok=True)
        with open(log,'ab') as f:return subprocess.Popen(args,stdout=f,stderr=subprocess.STDOUT,start_new_session=True,env=dict(os.environ,OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',VECLIB_MAXIMUM_THREADS='1'))
    def recover(self):
        # Prep outputs are committed only on clean exit. Old checkpoints remain valid.
        old=read_json(self.root/'active-preparation.json',[])
        for item in old:terminate(item['pid'],item['marker'])
        with self.store.connect() as db:db.execute("UPDATE prep SET status='pending' WHERE status='running'")
        for a in self.store.rows('attempts',"WHERE status='running'"):
            marker=Path(a['directory'])/'input.json'
            pid=a['pid'] if owns(a['pid'],marker) else find_owned(marker)
            if pid:
                a['pid']=pid;self.store.update('attempts',a['id'],pid=pid);self.store.update('jobs',a['job_id'],status='running',attempt=a['seq']);self.processes[a['job_id']]={'pid':pid,'attempt':a,'process':None}
            else:self.finish_attempt(a,False)
        atomic_json(self.root/'active-preparation.json',[])
    def stopped(self):return self.stop or (self.root/'STOP').exists()
    def cache(self):
        path=Path(self.config['shape_store']);manifest=path.with_suffix('.json');progress=self.root/'shape-progress.json'
        if not path.exists():
            self.store.set('phase','shape_cache');path.parent.mkdir(parents=True,exist_ok=True);building=path.with_suffix('.building.sqlite')
            if building.exists():building.unlink()
            lock=open(path.parent/'cache.lock','w');fcntl.flock(lock,fcntl.LOCK_EX)
            if not path.exists():
                p=self.launch([self.config['tools'],'precache','--db',str(building),'--manifest',str(manifest),'--progress',str(progress)],self.root/'cache.log')
                try:
                    while p.poll() is None:
                        self.heartbeat()
                        if self.stopped():terminate(p.pid,building);return False
                        time.sleep(.5)
                    if p.returncode:raise RuntimeError('Shape precomputation failed; see cache.log')
                    building.replace(path);path.chmod(0o444)
                finally:lock.close()
        manifest_value=read_json(manifest)
        if not manifest_value or manifest_value.get('generator')!='orbit-connected-subsets-v1' or manifest_value.get('maxDimension')!=9:raise ValueError('Shape manifest is missing or incompatible')
        current=digest(path);expected=self.store.get('shape_sha256')
        if expected and expected!=current:raise ValueError('Frozen shape database changed since campaign start')
        self.store.set('shape_manifest',manifest_value);self.store.set('shape_sha256',current);return True
    def heartbeat(self):atomic_json(self.root/'controller-heartbeat.json',{'pid':os.getpid(),'updated':now(),'phase':self.store.get('phase')})
    def prep_records(self):
        if self.store.rows('prep'):return
        folder=self.root/'preparation';folder.mkdir(exist_ok=True)
        for slot in range(self.config['boards_per_size']):
            for n in self.config['sizes']:
                identifier=f'n{n}-b{slot+1}';state=folder/(identifier+'.json');progress=folder/(identifier+'-progress.json')
                subprocess.run([self.config['tools'],'new-preparation','--n',str(n),'--slot',str(slot),'--output',str(state)],check=True)
                with self.store.connect() as db:db.execute('INSERT INTO prep(id,n,slot,status,state_path,progress_path) VALUES(?,?,?,?,?,?)',(identifier,n,slot,'pending',str(state),str(progress)))
    def save_active_prep(self):atomic_json(self.root/'active-preparation.json',[{'pid':p['process'].pid,'marker':p['output']} for p in self.preparing.values()])
    def poll_prep(self):
        changed=False
        for key,item in list(self.preparing.items()):
            p=item['process'];task=item['task']
            if p.poll() is None:continue
            del self.preparing[key];self.save_active_prep()
            if p.returncode!=0:
                failures=self.store.get('preparation_failures',{});failures[key]=failures.get(key,0)+1;self.store.set('preparation_failures',failures)
                self.store.update('prep',key,status='pending' if failures[key]<=self.config['infrastructure_retries'] else 'failed',error=f'Preparation process exited {p.returncode}; inspect preparation log');self.store.event('error',f'{key} preparation failed (attempt {failures[key]})');continue
            state=read_json(item['output']);unique=admit(self.store,task,state);changed=True
            if state['qualified'] and any(c['solutionCount']==1 for c in state['qualified']) and not unique:
                # A symmetry-equivalent board is not a second distinct fixture.
                state.update(attempt=state['attempt']+1,round=0,witness=[],puzzle=None,search=None,counterexamples=[],qualified=[])
            atomic_json(task['state_path'],state);Path(item['output']).unlink(missing_ok=True)
            self.store.update('prep',key,status='unique' if unique else 'pending',error=None)
        if changed:export_report(self.store)
    def preparation(self):
        self.prep_records();self.store.set('phase','preparing')
        if not self.store.get('preparation_started'):self.store.set('preparation_started',now())
        # Every explicit resume gets a fresh bounded preparation session.
        deadline=now()+self.config['preparation_seconds'];self.store.set('preparation_deadline',deadline)
        while True:
            self.poll_prep();self.heartbeat();boards=self.store.rows('boards');required=len(self.config['sizes'])*self.config['boards_per_size']
            ready=len(boards)==required;unique=ready and all(b['solution_count']==1 for b in boards)
            if unique or self.stopped() or now()>=deadline:break
            available=self.store.rows('prep',"WHERE status='pending' ORDER BY last_scheduled,n,slot")
            for task in available[:max(0,self.config['preparation_workers']-len(self.preparing))]:
                output=str(Path(task['state_path']).with_suffix('.next.json'))
                duration=min(self.config['preparation_slice_seconds'],max(.1,deadline-now()))
                p=self.launch([self.config['tools'],'prepare-step','--input',task['state_path'],'--output',output,'--db',self.config['shape_store'],'--seconds',str(duration),'--progress',task['progress_path']],self.root/'preparation'/(task['id']+'.log'))
                self.preparing[task['id']]={'process':p,'output':output,'task':task};self.store.update('prep',task['id'],status='running',last_scheduled=now());self.save_active_prep()
            if not self.preparing and not available:break
            time.sleep(.5)
        # Stop at a checkpoint boundary (each step is bounded), never admit partial proofs.
        while self.preparing and not self.stopped():self.poll_prep();self.heartbeat();time.sleep(.25)
        if self.stopped():
            for item in self.preparing.values():terminate(item['process'].pid,item['output']);self.store.update('prep',item['task']['id'],status='pending')
            self.preparing.clear();self.save_active_prep();self.store.set('phase','paused');return False
        if len(self.store.rows('boards'))!=required:
            self.store.set('phase','preparation_incomplete');self.store.event('gate','Preparation session ended without 15 qualifying boards; no timed trials launched');return False
        freeze_jobs(self.store);return True
    def finish_attempt(self,a,watchdog=False):
        job=self.store.rows('jobs','WHERE id=?',(a['job_id'],))[0];directory=Path(a['directory']);self.store.update('jobs',job['id'],attempt=max(job['attempt'],a['seq']),progress=str(directory/'progress.json'));result=read_json(directory/'result.json');error=None
        try:
            if watchdog:raise ValueError('Watchdog stopped non-cooperative worker')
            if not result:raise ValueError('Worker exited without a complete result')
            board=self.store.rows('boards','WHERE id=?',(job['board_id'],))[0];status=validate_result(result,job,json.loads(board['puzzle']),self.config)
        except (ValueError,KeyError,TypeError) as exc:error=str(exc);status='failed'
        self.store.update('attempts',a['id'],ended=now(),status=status,wall_seconds=now()-a['started'],error=error)
        if error:
            failed=self.store.rows('attempts',"WHERE job_id=? AND status='failed'",(job['id'],))
            self.store.update('jobs',job['id'],status='pending' if len(failed)<=self.config['infrastructure_retries'] else 'failed',error=error)
            self.store.event('infrastructure',f"{job['id']}: {error}")
        else:self.store.update('jobs',job['id'],status=status,result=json.dumps(result),error=None);self.store.event(status,f"{job['id']}: {result['seconds']:.3f} seconds")
    def poll_jobs(self):
        changed=False
        for key,item in list(self.processes.items()):
            a=item['attempt'];p=item['process'];running=p.poll() is None if p else owns(item['pid'],Path(a['directory'])/'input.json')
            watchdog=now()-a['started']>self.config['trial_seconds']+15
            if running and not watchdog:continue
            if running:terminate(item['pid'],Path(a['directory'])/'input.json')
            self.finish_attempt(a,watchdog);del self.processes[key];changed=True
        if changed:export_report(self.store)
    def trials(self):
        self.store.set('phase','running')
        while not self.stopped():
            self.poll_jobs();self.heartbeat()
            for job in self.store.rows('jobs',"WHERE status='pending' ORDER BY launch_index")[:max(0,self.config['workers']-len(self.processes))]:
                if digest(self.config['shape_store'])!=self.store.get('shape_sha256'):raise RuntimeError('Frozen shape database changed')
                nonce=uuid.uuid4().hex;sequence=job['attempt']+1;identifier=f"{job['id']}-a{sequence}-{nonce[:8]}";directory=self.root/'runs'/identifier;directory.mkdir(parents=True)
                board=self.store.rows('boards','WHERE id=?',(job['board_id'],))[0]
                value=dict(jobID=job['id'],puzzle=json.loads(board['puzzle']),condition=json.loads(job['condition']),seed=job['seed'],budgetSeconds=self.config['trial_seconds'],shapeStore=self.config['shape_store'],output=str(directory))
                atomic_json(directory/'input.json',value)
                # Persist intent before spawn; stale intent is reconciled on restart.
                a=dict(id=identifier,job_id=job['id'],seq=sequence,pid=None,nonce=nonce,started=now(),status='running',directory=str(directory))
                with self.store.connect() as db:db.execute('INSERT INTO attempts(id,job_id,seq,pid,nonce,started,status,directory) VALUES(:id,:job_id,:seq,:pid,:nonce,:started,:status,:directory)',a)
                p=self.launch([self.config['worker'],str(directory/'input.json')],directory/'worker.log');a['pid']=p.pid
                self.store.update('attempts',identifier,pid=p.pid);self.store.update('jobs',job['id'],status='running',attempt=sequence,progress=str(directory/'progress.json'),error=None)
                self.processes[job['id']]={'pid':p.pid,'attempt':a,'process':p}
            if not self.processes and not self.store.rows('jobs',"WHERE status='pending'"):self.store.set('phase','complete');self.store.event('complete','Timed campaign finished');return
            time.sleep(.5)
        for item in self.processes.values():
            a=item['attempt'];terminate(item['pid'],Path(a['directory'])/'input.json');self.store.update('attempts',a['id'],status='interrupted',ended=now());self.store.update('jobs',a['job_id'],status='pending',error='Interrupted by explicit stop')
        self.processes.clear();self.store.set('phase','paused')
    def run(self):
        lock=open(self.root/'controller.lock','w')
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise RuntimeError('A campaign controller is already running')
        signal.signal(signal.SIGTERM,lambda *_:setattr(self,'stop',True));signal.signal(signal.SIGINT,lambda *_:setattr(self,'stop',True))
        self.store.event('controller','Controller started');self.recover()
        caffeinate=subprocess.Popen(['/usr/bin/caffeinate','-i','-w',str(os.getpid())],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL) if sys.platform=='darwin' else None
        try:
            if not self.cache():self.store.set('phase','paused');return
            if not self.store.rows('jobs'):
                if self.config.get('admission_policy')=='validated_witness':freeze_current_puzzles(self.store)
                elif not self.preparation():return
            self.trials()
        except BaseException as exc:
            self.store.set('last_error',str(exc));self.store.set('phase','error');self.store.event('error',str(exc));raise
        finally:
            for item in self.preparing.values():terminate(item['process'].pid,item['output'])
            # Running timed children remain uniquely registered and are adopted after a crash.
            self.heartbeat();export_report(self.store)
            if caffeinate:caffeinate.terminate()
            lock.close()
