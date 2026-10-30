"""Read-only loopback dashboard; all values originate in durable campaign files."""
from __future__ import annotations
import collections,json,mimetypes,os,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse,parse_qs
from .storage import Store,read_json,atomic_json,now
from .controller import alive

def snapshot(store):
    config=store.get('config');jobs=store.rows('jobs','ORDER BY launch_index');boards=store.rows('boards','ORDER BY n,slot');prep=store.rows('prep','ORDER BY n,slot');attempts=store.rows('attempts','ORDER BY started');counts=collections.Counter(j['status'] for j in jobs)
    for b in boards:
        b['puzzle']=json.loads(b['puzzle']);cert=json.loads(b.pop('certificate'));b['answers']=cert['answers'];b['nodes']=cert['nodes'];b['audit']=cert.get('audit');b['countProven']=bool(cert.get('exhausted'));b['knownSolutionCountLowerBound']=cert.get('knownSolutionCountLowerBound',cert.get('solutionCount'))
    for p in prep:
        p['progress']=read_json(p['progress_path']);p['checkpoint']={};p.pop('state_path');p.pop('progress_path')
    summaries=[]
    for j in jobs:
        item={k:v for k,v in j.items() if k not in ['result','progress']};item['condition']=json.loads(j['condition']);item['progress']=read_json(j['progress']) if j['progress'] else None
        if j['result']:
            r=json.loads(j['result']);item['result']={k:r.get(k) for k in ['solved','seconds','cpuSeconds','quality','reason','answer','metrics','oracle']}
        summaries.append(item)
    heartbeat=read_json(store.directory/'controller-heartbeat.json',{});runtime=read_json(store.directory/'runtime.json',{})
    return dict(now=now(),config=config,phase=store.get('phase'),lastError=store.get('last_error'),controller=dict(**heartbeat,alive=alive(heartbeat.get('pid')),stale=now()-heartbeat.get('updated',0)>5),runtime=runtime,counts=dict(counts),planned=store.get('planned_trials'),boards=boards,prep=prep,jobs=summaries,attempts=attempts,events=store.rows('events','ORDER BY id DESC LIMIT 30'),shape=read_json(store.directory/'shape-progress.json'),manifest=store.get('shape_manifest'),preparationDeadline=store.get('preparation_deadline'),preparationStarted=store.get('preparation_started'),shapeHash=store.get('shape_sha256'))

def series(store,identifier):
    jobs=store.rows('jobs','WHERE id=?',(identifier,)) if identifier else []
    if not jobs:return {'samples':[]}
    attempts=store.rows('attempts','WHERE job_id=? ORDER BY seq DESC',(identifier,))
    if not attempts:return {'samples':[]}
    path=Path(attempts[0]['directory'])/'events.jsonl';samples=[]
    try:
        for line in path.read_text().splitlines():
            try:samples.append(json.loads(line))
            except ValueError:pass # A writer may be appending the final line.
    except OSError:pass
    return {'jobID':identifier,'attempt':attempts[0]['seq'],'samples':samples}

def detail(store,identifier):
    attempts=store.rows('attempts','WHERE job_id=? ORDER BY seq DESC',(identifier,))
    if not attempts:return {}
    directory=Path(attempts[0]['directory']);return {'input':read_json(directory/'input.json'),'checkpoint':read_json(directory/'checkpoint.json'),'result':read_json(directory/'result.json'),'attempt':attempts[0]}

def serve(directory,port=0):
    store=Store(directory);web=Path(__file__).resolve().parents[1]/'web'
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*_):pass
        def send(self,data,content_type='application/json',status=200,download=None):
            if not isinstance(data,bytes):data=json.dumps(data,allow_nan=False).encode()
            self.send_response(status);self.send_header('Content-Type',content_type);self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'")
            if download:self.send_header('Content-Disposition',f'attachment; filename="{download}"')
            self.end_headers();self.wfile.write(data)
        def do_GET(self):
            parsed=urlparse(self.path);query=parse_qs(parsed.query)
            try:
                if parsed.path=='/api/health':return self.send({'ok':True,'campaign':store.get('config')['id']})
                if parsed.path=='/api/snapshot':return self.send(snapshot(store))
                if parsed.path=='/api/series':return self.send(series(store,query.get('job',[''])[0]))
                if parsed.path=='/api/job':return self.send(detail(store,query.get('id',[''])[0]))
                if parsed.path.startswith('/download/'):
                    name=parsed.path.split('/')[-1];allowed={'results.csv','results.json','summary.json','fixtures.json','certificates.json','REPORT.md'}
                    if name=='campaign.json':file=store.directory/name
                    elif name in allowed:file=store.directory/'report'/name
                    else:return self.send({'error':'Unknown export'},status=404)
                    if not file.exists():return self.send({'error':'Export not created yet'},status=404)
                    return self.send(file.read_bytes(),mimetypes.guess_type(file)[0] or 'application/octet-stream',download=store.get('config').get('display_name','JSP-Oct26-Regional-SA-BP')+'-'+name)
                name='index.html' if parsed.path=='/' else parsed.path.lstrip('/')
                if name not in {'index.html','app.js','style.css'}:return self.send({'error':'Not found'},status=404)
                return self.send((web/name).read_bytes(),mimetypes.guess_type(name)[0] or 'text/plain')
            except (BrokenPipeError,ConnectionResetError):pass
            except Exception as exc:self.send({'error':str(exc)},status=500)
    if not port:port=read_json(store.directory/'runtime.json',{}).get('port',0)
    server=ThreadingHTTPServer(('127.0.0.1',port),Handler);server.daemon_threads=True
    runtime=read_json(store.directory/'runtime.json',{});runtime.update(serverPID=os.getpid(),url=f'http://127.0.0.1:{server.server_port}',port=server.server_port);atomic_json(store.directory/'runtime.json',runtime)
    server.serve_forever(poll_interval=.5)
