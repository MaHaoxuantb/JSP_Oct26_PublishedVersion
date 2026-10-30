#!/usr/bin/env python3
"""Launch one isolated host queue, its dashboard and export coordinator."""
from pathlib import Path
import argparse,json,subprocess,sys,time
from prepare import prepare
from completionqueue.common import atomic,read

def main():
 p=argparse.ArgumentParser();p.add_argument('--directory',required=True);p.add_argument('--host',default='mac');p.add_argument('--slot',type=int,default=1,choices=[1,2]);p.add_argument('--release',required=True);p.add_argument('--shape',required=True);p.add_argument('--peers',default='[]');a=p.parse_args()
 started=time.time();root=prepare(a.directory,a.host,a.slot,a.release,a.shape,started,json.loads(a.peers))
 config=read(root/'config.json');entry=Path(config['source'])/'runner.py';processes={}
 for command in ['agent','serve','coordinate']:
  with (root/(command+'.log')).open('ab') as f:
   process=subprocess.Popen([sys.executable,str(entry),command,'--directory',str(root)],stdin=subprocess.DEVNULL,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  processes[command]=process.pid
 atomic(root/'processes.json',processes)
 for _ in range(100):
  dashboard=read(root/'dashboard.json');state=read(root/'state.json',{})
  if dashboard and state.get('phase')=='running':break
  time.sleep(.1)
 else:raise RuntimeError('Launch did not become ready; inspect agent.log and serve.log')
 latest=dict(directory=str(root),url=dashboard['url'],processes=processes,started=started,searchDeadline=config['searchDeadline'],campaignDeadline=config['campaignDeadline'])
 atomic(root.parent/'repair-completion-latest.json',latest)
 print(json.dumps(latest,indent=2))
if __name__=='__main__':main()
