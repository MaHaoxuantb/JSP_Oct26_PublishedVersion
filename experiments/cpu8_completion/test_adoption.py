"""JSP-Oct26-CPU8-Completion; ©2026 ThomasB. Disposable adoption integration test."""
import json,pathlib,subprocess,tempfile,time,sys
here=pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='jsp-adoption-test-') as d:
 root=pathlib.Path(d);(root/'bin').mkdir();(root/'original11-B').mkdir()
 worker=root/'bin/cpu8-worker'
 worker.write_text('''#!/usr/bin/python3
import json,sys,time,pathlib,os
p=json.load(open(sys.argv[1]));o=pathlib.Path(p['output']);start=time.time();(o/'preserved-pid').write_text(str(os.getpid()))
while time.time()-start<p['seconds'] and not pathlib.Path(p['stopFile']).exists():time.sleep(.02)
r=dict(softwareVersion=3,workers=[{}]*8,gpuEnabled=False,solved=False,labels=[0],seconds=time.time()-start,cpuSeconds=0,cpuEquivalentCores=0,commonEnergy=2/3,quality=dict(issues=0,wrong=1,residual=1),reason='cancelled' if pathlib.Path(p['stopFile']).exists() else 'time_limit')
(o/'result.json').write_text(json.dumps(r))
''');worker.chmod(0o700)
 config=dict(seconds=3000,deadline=time.time()+200,threads=8,puzzle=dict(id='test',n=1,clues=[99]),seed=1)
 (root/'config.json').write_text(json.dumps(config))
 job=dict(id='original11-B',method='B',label='B',routeSelected=False,status='running',started=time.time(),series=[])
 snapshot=dict(config=config,started=job['started'],phase='running',jobs=[job,dict(id='original11-D',method='D',label='D',routeSelected=True,status='pending',series=[])])
 (root/'snapshot.json').write_text(json.dumps(snapshot))
 (root/'original11-B/input.json').write_text(json.dumps(dict(output=str(root/'original11-B'),seconds=30,stopFile=str(root/'STOP'))))
 old=root/'campaign.py';old.write_text('import subprocess,sys,time\np=subprocess.Popen([sys.argv[2],sys.argv[1]+"/original11-B/input.json"])\nopen(sys.argv[1]+"/pid","w").write(str(p.pid))\ntime.sleep(30)\n')
 controller=subprocess.Popen([sys.executable,str(old),str(root),str(worker)])
 try:
  for _ in range(100):
   if (root/'pid').exists() and (root/'original11-B/preserved-pid').exists():break
   time.sleep(.03)
  pid=int((root/'pid').read_text())
  subprocess.run([sys.executable,str(here/'adopt_deadline.py'),'--root',str(root),'--controller',str(controller.pid),'--worker',str(pid),'--seconds','1','--deadline',str(time.time()+400)],check=True,timeout=15)
  s=json.load(open(root/'snapshot.json'));assert s['phase']=='complete'
  assert s['jobs'][0]['workerPID']==pid and s['jobs'][0]['status']=='budget_timeout'
  assert s['jobs'][1]['status']=='timeout' and s['jobs'][1]['workerPID']!=pid
  assert int((root/'original11-B/preserved-pid').read_text())==pid
  assert not (root/'STOP').exists()
  print('Adoption preserved the active PID, respected the amended cutoff, and ran the next job sequentially.')
 finally:
  if controller.poll() is None:controller.terminate()
  controller.wait()
