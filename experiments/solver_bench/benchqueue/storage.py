from __future__ import annotations
import contextlib,datetime,hashlib,json,sqlite3,time
from pathlib import Path

def now():return time.time()
def utc():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def read_json(path,default=None):
    try:return json.loads(Path(path).read_text())
    except (OSError,ValueError):return default

def atomic_json(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True);tmp=path.with_name(path.name+'.tmp');tmp.write_text(json.dumps(value,sort_keys=True,allow_nan=False));tmp.replace(path)

def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

class Store:
    def __init__(self,directory):
        self.directory=Path(directory);self.path=self.directory/'queue.sqlite'
    @contextlib.contextmanager
    def connect(self):
        db=sqlite3.connect(self.path,timeout=20);db.row_factory=sqlite3.Row
        try:yield db;db.commit()
        except BaseException:db.rollback();raise
        finally:db.close()
    def create(self,config):
        self.directory.mkdir(parents=True,exist_ok=True)
        with self.connect() as db:
            db.executescript('''PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            CREATE TABLE prep(id TEXT PRIMARY KEY,n INTEGER,slot INTEGER,status TEXT,state_path TEXT,progress_path TEXT,last_scheduled REAL DEFAULT 0,error TEXT);
            CREATE TABLE boards(id TEXT PRIMARY KEY,n INTEGER,slot INTEGER,puzzle TEXT,certificate TEXT,solution_count INTEGER,content_hash TEXT,UNIQUE(n,slot));
            CREATE TABLE jobs(id TEXT PRIMARY KEY,board_id TEXT,condition TEXT,seed INTEGER,status TEXT,attempt INTEGER DEFAULT 0,launch_index INTEGER,progress TEXT,result TEXT,error TEXT);
            CREATE TABLE attempts(id TEXT PRIMARY KEY,job_id TEXT,seq INTEGER,pid INTEGER,nonce TEXT,started REAL,ended REAL,status TEXT,directory TEXT,wall_seconds REAL,error TEXT);
            CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT,ts REAL,kind TEXT,message TEXT,data TEXT);
            ''')
            for key,value in {'config':config,'phase':'created','started':now(),'planned_trials':len(config['sizes'])*config['boards_per_size']*8*len(config['seeds']),'preparation_started':None,'preparation_deadline':None,'shape_manifest':None,'last_error':None}.items():db.execute('INSERT INTO metadata VALUES(?,?)',(key,json.dumps(value)))
        atomic_json(self.directory/'campaign.json',config)
    def get(self,key,default=None):
        with self.connect() as db:r=db.execute('SELECT value FROM metadata WHERE key=?',(key,)).fetchone()
        return json.loads(r[0]) if r else default
    def set(self,key,value):
        with self.connect() as db:db.execute('INSERT OR REPLACE INTO metadata VALUES(?,?)',(key,json.dumps(value)))
    def event(self,kind,message,data=None):
        with self.connect() as db:db.execute('INSERT INTO events(ts,kind,message,data) VALUES(?,?,?,?)',(now(),kind,message,json.dumps(data)))
    def rows(self,table,where='',args=()):
        assert table in {'prep','boards','jobs','attempts','events'}
        with self.connect() as db:return [dict(r) for r in db.execute(f'SELECT * FROM {table} '+where,args)]
    def update(self,table,key,**fields):
        assert table in {'prep','jobs','attempts'}
        if not fields:return
        with self.connect() as db:db.execute(f'UPDATE {table} SET '+','.join(f'{k}=?' for k in fields)+' WHERE id=?',(*fields.values(),key))
