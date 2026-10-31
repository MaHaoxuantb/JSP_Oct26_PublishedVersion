"""JSP-Oct26-Search-Escape; ©2026 ThomasB. Read-only local dashboard/export mirror."""
import argparse,json,pathlib,shlex,subprocess,time,threading,mimetypes
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
HERE=pathlib.Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--remote-root',required=True);p.add_argument('--ssh',required=True);p.add_argument('--port',type=int,default=0);a=p.parse_args()
root=pathlib.Path(a.root);root.mkdir(parents=True,exist_ok=True)
def refresh():
 while True:
  try:
   raw=subprocess.check_output(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5',a.ssh,'cat '+shlex.quote(a.remote_root+'/snapshot.json')],timeout=10,stderr=subprocess.DEVNULL)
   value=json.loads(raw);tmp=root/'snapshot.tmp';tmp.write_bytes(raw);tmp.replace(root/'snapshot.json')
   (root/'health.json').write_text(json.dumps(dict(lastSuccess=time.time())))
   if value['phase'] in ['complete','stopped','failed','solved']:
    # Only closed/static report artifacts cross hosts, never active SQLite files.
    for name in ['JSP-Oct26-Search-Escape-Report.md','JSP-Oct26-Search-Escape-Trials.csv','JSP-Oct26-Search-Escape-Results.json']:
     raw=subprocess.check_output(['ssh','-o','BatchMode=yes',a.ssh,'cat '+shlex.quote(a.remote_root+'/report/'+name)],timeout=10)
     (root/name).write_bytes(raw)
    return
  except Exception as e:(root/'health.json').write_text(json.dumps(dict(error=str(e),at=time.time())))
  time.sleep(5)
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*_):pass
 def do_GET(self):
  try:
   if self.path=='/api/state':body=(root/'snapshot.json').read_bytes();mime='application/json'
   elif self.path=='/api/cpsat':
    body=(root/'cpsat-progress.json').read_bytes() if (root/'cpsat-progress.json').exists() else b'{"state":"starting"}';mime='application/json'
   elif self.path=='/api/health':body=(root/'health.json').read_bytes();mime='application/json'
   elif self.path in ['/','/app.js','/style.css']:
    name='index.html' if self.path=='/' else self.path[1:];body=(HERE/'web'/name).read_bytes();mime=mimetypes.guess_type(name)[0] or 'text/plain'
   else:self.send_error(404);return
   self.send_response(200);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(body)
  except (BrokenPipeError,ConnectionResetError):pass
  except Exception:self.send_error(503)
server=ThreadingHTTPServer(('127.0.0.1',a.port),Handler);server.daemon_threads=True
(root/'dashboard.json').write_text(json.dumps(dict(url='http://127.0.0.1:'+str(server.server_port),pid=__import__('os').getpid())))
threading.Thread(target=refresh,daemon=True).start();server.serve_forever()
