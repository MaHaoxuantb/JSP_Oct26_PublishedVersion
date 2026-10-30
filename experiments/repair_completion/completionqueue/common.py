"""Shared artifact helpers. Queue state stays on the host that owns its workers."""
from __future__ import annotations
import csv,hashlib,json,os,sqlite3,time
from pathlib import Path

NAME='JSP-Oct26-Repair-Completion'
COPYRIGHT='©2026 ThomasB'
METHODS={
 'A':dict(label='Baseline',persistent=False,routeSelected=False),
 'B':dict(label='Persistent BP',persistent=True,routeSelected=False),
 'C':dict(label='Route selection',persistent=False,routeSelected=True),
 'D':dict(label='Persistent + route',persistent=True,routeSelected=True),
 'E':dict(label='Production reference',persistent=False,routeSelected=False),
}
def read(path,default=None):
 try:return json.loads(Path(path).read_text())
 except (OSError,ValueError):return default

def atomic(path,value):
 path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
 temp=path.with_name(path.name+'.tmp-'+str(os.getpid()));temp.write_text(json.dumps(value,allow_nan=False,ensure_ascii=False));temp.replace(path)

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def connect(root):
 con=sqlite3.connect(Path(root)/'queue.sqlite',timeout=20);con.row_factory=sqlite3.Row
 return con

def rows(root):
 with connect(root) as con:return [dict(r) for r in con.execute('SELECT * FROM jobs ORDER BY position')]

class SeriesReader:
 def __init__(self):self.offsets={};self.points={}
 def update(self,path):
  path=Path(path);key=str(path);out=self.points.setdefault(key,[])
  try:
   with path.open('rb') as f:
    f.seek(self.offsets.get(key,0))
    while True:
     before=f.tell();line=f.readline()
     if not line:break
     if not line.endswith(b'\n'):f.seek(before);break
     try:
      v=json.loads(line);out.append({k:v[k] for k in ['seconds','commonEnergy','quality','cpuSeconds'] if k in v})
     except ValueError:pass
    self.offsets[key]=f.tell()
  except FileNotFoundError:pass
  return out

def snapshot(root,reader=None):
 root=Path(root);config=read(root/'config.json');state=read(root/'state.json',{'phase':'created'})
 jobs=rows(root);counts={};reader=reader or SeriesReader()
 for j in jobs:
  counts[j['status']]=counts.get(j['status'],0)+1
  j['host']=config['host'];folder=Path(j['directory']);j['progress']=read(folder/'progress.json');j['repairs']=read(folder/'repair-progress.json',{})
  j['result']=json.loads(j['result']) if j['result'] else None
  checkpoint=read(folder/'checkpoint.json',{});j['labels']=checkpoint.get('labels') or (j['progress'] or {}).get('labels')
  j['series']=reader.update(folder/'events.jsonl')
 return dict(experiment=NAME,copyright=COPYRIGHT,host=config['host'],config=config,state=state,
   jobs=jobs,counts=counts,updated=time.time())

def export(root,snap):
 root=Path(root);folder=root/'report';folder.mkdir(parents=True,exist_ok=True)
 cap=snap['config'].get('trialSeconds',1200)
 atomic(folder/(NAME+'-Results.json'),snap)
 fields=['host','board_id','seed','method','status','seconds','workerSeconds','cpuSeconds','wrong','residual','issues','solved','answer','error']
 records=[]
 for j in snap['jobs']:
  r=j['result'] or {};q=r.get('quality',{});record={k:j.get(k) for k in ['board_id','seed','method','status','error']}
  record.update(host=j.get('host',snap['host']),seconds=r.get('executionWallSeconds'),workerSeconds=r.get('seconds'),cpuSeconds=r.get('cpuSeconds'),solved=r.get('solved'),answer=r.get('answer'),**{k:q.get(k) for k in ['wrong','residual','issues']});records.append(record)
 with (folder/(NAME+'-Trials.csv')).open('w',newline='') as f:
  w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(records)
 lines=['# '+NAME,COPYRIGHT,'','Host: '+snap['host']+'. State: '+snap['state']['phase']+'.','',
  'Primary elapsed times include process startup and result publication. Worker search seconds are also retained. Each method/puzzle/seed block belongs to one host. The production reference is excluded from factorial estimates.','',
  '| Host | Method | Completed | Solved | Capped elapsed cost (s) |','|---|---|---:|---:|---:|']
 for host in sorted({j.get('host',snap['host']) for j in snap['jobs']}):
  for method,info in METHODS.items():
   complete=[j for j in snap['jobs'] if j.get('host',snap['host'])==host and j['method']==method and j['status'] in ['solved','timeout']]
   solved=[j for j in complete if j['status']=='solved']
   cost=sum(min(j['result']['executionWallSeconds'],cap) if j['status']=='solved' else cap for j in complete)/len(complete) if complete else None
   lines.append(f"| {host} | {method}: {info['label']} | {len(complete)} | {len(solved)} | {cost:.3f} |" if cost is not None else f"| {host} | {method}: {info['label']} | 0 | 0 | — |")
 lines+=['','Paired capped-cost differences are computed within the same host, board and seed. Negative favors the first method. Only complete pairs enter.','', '| Host | Subset | Pair | Complete pairs | Solve wins / losses | Mean difference (s) |','|---|---|---|---:|---:|---:|']
 groups={}
 for j in snap['jobs']:
  if j['status'] in ['solved','timeout']:groups.setdefault((j.get('host',snap['host']),j['board_id'],j['seed']),{})[j['method']]=j
 def cost(j):return min(j['result']['executionWallSeconds'],cap) if j['status']=='solved' else cap
 for host in sorted({k[0] for k in groups}):
  for subset in ['generated','original']:
   for first,second in [('B','A'),('D','C'),('C','A'),('D','B'),('D','A'),('E','A'),('E','D')]:
    pairs=[(g[first],g[second]) for k,g in groups.items() if k[0]==host and (k[1]=='original-11')==(subset=='original') and first in g and second in g]
    if not pairs:continue
    delta=sum(cost(a)-cost(b) for a,b in pairs)/len(pairs)
    wins=sum(a['status']=='solved' and b['status']!='solved' for a,b in pairs);losses=sum(b['status']=='solved' and a['status']!='solved' for a,b in pairs)
    lines.append(f'| {host} | {subset} | {first} − {second} | {len(pairs)} | {wins} / {losses} | {delta:.3f} |')
 lines+=['','Pending, failed, interrupted and skipped jobs do not count as full timeouts. Some generated fixtures have unknown or nonunique solution sets. Zero solves is inconclusive evidence of completion benefit. The original 11×11 outcome is reported separately below.','']
 for j in snap['jobs']:
  if j['board_id']=='original-11':
   r=j['result'] or {};lines.append(f"- Original 11×11, seed {j['seed']}, {j['method']}: {j['status']}; elapsed {r.get('executionWallSeconds','—')}; wrong clues {(r.get('quality') or {}).get('wrong','—')}.")
 (folder/(NAME+'-Report.md')).write_text('\n'.join(lines)+'\n')
