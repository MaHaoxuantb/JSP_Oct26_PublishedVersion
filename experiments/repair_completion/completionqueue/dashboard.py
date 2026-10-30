"""Read-only local UI and immutable peer-export aggregation."""
from __future__ import annotations
import json,mimetypes,shlex,subprocess,time,zipfile
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from .common import NAME,COPYRIGHT,read,atomic,export

WEB=Path(__file__).resolve().parents[1]/'web'
def aggregate(root):
 local=read(root/'snapshot.json',{});config=read(root/'config.json',{});sources=[local] if local else []
 for peer in config.get('peers',[]):
  remote=read(root/('peer-'+peer['id']+'.json'))
  if remote:sources.append(remote)
 config=dict(config);config['puzzles']=list({p['id']:p for s in sources for p in s.get('config',{}).get('puzzles',[])}.values())
 jobs=[j for s in sources for j in s.get('jobs',[])];counts={}
 for j in jobs:counts[j['status']]=counts.get(j['status'],0)+1
 hosts=[dict(host=s['host'],phase=s['state']['phase'],updated=s['updated'],slots=s['config']['slots'],counts=s['counts']) for s in sources]
 phases=[h['phase'] for h in hosts]
 phase='complete' if phases and all(x=='complete' for x in phases) else 'running' if 'running' in phases else 'stopped' if 'stopped' in phases else 'ready'
 return dict(experiment=NAME,copyright=COPYRIGHT,host='combined',config=config,jobs=jobs,hosts=hosts,counts=counts,state=dict(phase=phase),updated=time.time())

def publish(root,snap):
 export(root/'combined',snap)
 folder=root/'combined'/'report'
 html=(WEB/'index.html').read_text().replace('<link rel="stylesheet" href="/style.css">','<style>'+(WEB/'style.css').read_text()+'</style>')
 data=json.dumps(snap,ensure_ascii=False).replace('</','<\\/')
 html=html.replace('<script src="/app.js" defer></script>','<script>window.FROZEN_STATE='+data+';</script><script>'+(WEB/'app.js').read_text()+'</script>')
 (folder/(NAME+'-Report.html')).write_text(html)

def coordinate(root):
 config=read(root/'config.json');last_export=0
 while True:
  for peer in config.get('peers',[]):
   try:
    raw=subprocess.check_output(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5',peer['ssh'],'cat '+shlex.quote(peer['root']+'/snapshot.json')],timeout=10,stderr=subprocess.DEVNULL)
    value=json.loads(raw);assert value['host']==peer['id'];atomic(root/('peer-'+peer['id']+'.json'),value)
   except Exception as exc:atomic(root/('peer-'+peer['id']+'-error.json'),dict(time=time.time(),error=str(exc)))
  snap=aggregate(root)
  if time.time()-last_export>=15:publish(root,snap);last_export=time.time()
  done=snap['hosts'] and len(snap['hosts'])==1+len(config.get('peers',[])) and all(h['phase'] in ['complete','stopped'] for h in snap['hosts'])
  if done or time.time()>config['campaignDeadline']:
   publish(root,snap)
   folder=root/'combined'/'report'
   with zipfile.ZipFile(folder/(NAME+'-Evidence.zip'),'w',zipfile.ZIP_DEFLATED) as z:
    for p in folder.iterdir():
     if p.is_file() and p.suffix!='.zip':z.write(p,NAME+'/'+p.name)
    for p in [root/'manifest.json',root/'config.json']:
     if p.exists():z.write(p,NAME+'/'+p.name)
   atomic(root/'coordinator-final.json',dict(finished=time.time(),phase=snap['state']['phase'],counts=snap['counts']))
   return
  time.sleep(5)

def serve(root,port):
 class Handler(BaseHTTPRequestHandler):
  def log_message(self,*_):pass
  def do_GET(self):
   try:
    if self.path=='/api/state':data=json.dumps(aggregate(root),allow_nan=False).encode();mime='application/json'
    elif self.path in ['/','/index.html','/style.css','/app.js']:
     name='index.html' if self.path=='/' else self.path[1:];data=(WEB/name).read_bytes();mime=mimetypes.guess_type(name)[0] or 'text/plain'
    elif self.path.startswith('/download/'):
     name=self.path.split('/')[-1]
     if name not in [NAME+'-Report.md',NAME+'-Report.html',NAME+'-Trials.csv',NAME+'-Results.json',NAME+'-Evidence.zip']:raise FileNotFoundError()
     data=(root/'combined'/'report'/name).read_bytes();mime=mimetypes.guess_type(name)[0] or 'application/octet-stream'
    else:raise FileNotFoundError()
    self.send_response(200);self.send_header('Content-Type',mime+'; charset=utf-8' if mime.startswith('text/') else mime);self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(data)
   except (BrokenPipeError,ConnectionResetError):pass
   except Exception:self.send_error(404)
 server=ThreadingHTTPServer(('127.0.0.1',port),Handler);server.daemon_threads=True
 atomic(root/'dashboard.json',dict(url=f'http://127.0.0.1:{server.server_port}',pid=__import__('os').getpid()))
 server.serve_forever(.5)
