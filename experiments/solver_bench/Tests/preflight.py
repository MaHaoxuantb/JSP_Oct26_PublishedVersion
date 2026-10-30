"""Real, temporary miniature campaign for UI/recovery checks; never a primary result."""
import os,sys,json,subprocess,time
from pathlib import Path
from benchqueue.storage import Store,digest,atomic_json
from benchqueue.controller import admit,freeze_jobs,Controller
from test_queue import config,certificate
root=Path(sys.argv[1]);root.mkdir(parents=True);store=Store(root);c=config(root);c.update(id='UI preflight — actual miniature measurements',source=str(Path(__file__).resolve().parents[1]),created=time.time());store.create(c)
subprocess.run([c['tools'],'precache','--db',c['shape_store'],'--progress',str(root/'shape-progress.json'),'--manifest',str(root/'shapes.json')],check=True)
store.set('shape_sha256',digest(c['shape_store']));store.set('shape_manifest',json.loads((root/'shapes.json').read_text()));admit(store,dict(n=1,slot=0),dict(qualified=[certificate()]));freeze_jobs(store);Controller(root).trials()
print(root)
