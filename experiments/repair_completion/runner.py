#!/usr/bin/env python3
"""JSP-Oct26-Repair-Completion: isolated host queues and a read-only dashboard."""
from pathlib import Path
import argparse,sys
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'solver_bench'))
from completionqueue.agent import run

def main():
 p=argparse.ArgumentParser();p.add_argument('command',choices=['agent','serve','coordinate']);p.add_argument('--directory',required=True);p.add_argument('--port',type=int,default=0);a=p.parse_args()
 if a.command=='agent':run(a.directory)
 elif a.command=='serve':
  from completionqueue.dashboard import serve
  serve(Path(a.directory),a.port)
 else:
  from completionqueue.dashboard import coordinate
  coordinate(Path(a.directory))
if __name__=='__main__':main()
