#!/usr/bin/env python3
"""Local experiment lifecycle. Use --help; no production worker is modified."""
from __future__ import annotations
import argparse,datetime,hashlib,json,os,shutil,subprocess,sys,time,urllib.request
from pathlib import Path
from benchqueue.storage import Store,atomic_json,read_json,now,digest
from benchqueue.controller import Controller,alive,owns,terminate,freeze_current_puzzles
from benchqueue.reporting import export_report

SOURCE=Path(__file__).resolve().parent
DEFAULT=Path.home()/'Library/Application Support/JaneStreetPuzzleBench'

def create(args):
    base=Path(args.root).expanduser().resolve();identifier=args.name or datetime.datetime.now().strftime('%Y%m%d-%H%M%S');directory=base/'campaigns'/identifier
    if directory.exists():raise ValueError('Campaign already exists; use start to resume')
    directory.mkdir(parents=True);source=directory/'source';shutil.copytree(SOURCE,source,ignore=shutil.ignore_patterns('__pycache__','.build','results'))
    binaries=directory/'bin';binaries.mkdir()
    for name in ['bench-worker','bench-tools']:shutil.copy2(Path(args.bin)/name,binaries/name)
    config=dict(id=identifier,display_name='JSP-Oct26-Regional-SA-BP',copyright='©2026 ThomasB',version='solver-bench-v1',sizes=[5,6,7,8,9],boards_per_size=3,seeds=[20261029,20261030,20261031],trial_seconds=1200,workers=4,preparation_workers=8,preparation_seconds=21600,preparation_slice_seconds=45,infrastructure_retries=2,order_seed=20261029,shape_store=str(base/'shapes/orbit-v1-bbox16-dim9.sqlite'),worker=str(binaries/'bench-worker'),tools=str(binaries/'bench-tools'),source=str(source),single_threaded=True,p_core_affinity='not guaranteed by macOS',density='round(n*n*33/121)',created=now())
    Store(directory).create(config)
    files={str(p.relative_to(source)):digest(p) for p in source.rglob('*') if p.is_file()};files.update({f'bin/{name}':digest(binaries/name) for name in ['bench-worker','bench-tools']});atomic_json(directory/'source-manifest.json',files)
    build={'swift':subprocess.check_output(['swift','--version'],text=True).strip(),'platform':subprocess.check_output(['uname','-a'],text=True).strip(),'cpu':{key:subprocess.check_output(['sysctl','-n',key],text=True).strip() for key in ['hw.physicalcpu','hw.logicalcpu','hw.perflevel0.physicalcpu','hw.perflevel1.physicalcpu']},'sourceHashes':'source-manifest.json'};atomic_json(directory/'build.json',build)
    atomic_json(base/'latest.json',{'directory':str(directory)});export_report(Store(directory));return directory

def start(directory):
    directory=Path(directory).resolve();store=Store(directory);config=store.get('config');entry=Path(config['source'])/'bench.py';runtime=read_json(directory/'runtime.json',{})
    def launch(command,log):
        with (directory/log).open('ab') as f:return subprocess.Popen([sys.executable,str(entry),command,'--directory',str(directory)],stdin=subprocess.DEVNULL,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
    if not owns(runtime.get('serverPID'),directory):launch('serve','server.log')
    for _ in range(100):
        runtime=read_json(directory/'runtime.json',{})
        try:
            with urllib.request.urlopen(runtime.get('url','')+'/api/health',timeout=.5) as r:
                if json.load(r)['campaign']==config['id']:break
        except (ValueError,OSError):time.sleep(.1)
    else:raise RuntimeError('Dashboard failed to start; inspect server.log')
    heartbeat=read_json(directory/'controller-heartbeat.json',{})
    if not owns(heartbeat.get('pid'),directory):
        (directory/'STOP').unlink(missing_ok=True);process=launch('controller','controller.log')
        for _ in range(100):
            if read_json(directory/'controller-heartbeat.json',{}).get('pid')==process.pid:break
            if process.poll() is not None:raise RuntimeError('Controller failed to start; inspect controller.log')
            time.sleep(.1)
    return runtime['url']

def use_current(directory):
    directory=Path(directory).resolve();store=Store(directory)
    if store.rows('jobs'):raise ValueError('Timed queue already exists; refusing to change fixtures')
    (directory/'STOP').touch();heartbeat=read_json(directory/'controller-heartbeat.json',{})
    terminate(heartbeat.get('pid'),directory)
    for item in read_json(directory/'active-preparation.json',[]):terminate(item['pid'],item['marker'])
    atomic_json(directory/'active-preparation.json',[])
    with store.connect() as db:db.execute("UPDATE prep SET status='pending' WHERE status='running'")
    history=directory/'amendments';history.mkdir(exist_ok=True);stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    config=store.get('config');atomic_json(history/(stamp+'-previous-config.json'),config)
    config=dict(config,admission_policy='validated_witness',admission_amended=now())
    store.set('config',config);atomic_json(directory/'campaign.json',config)
    freeze_current_puzzles(store)
    runtime=read_json(directory/'runtime.json',{});terminate(runtime.get('serverPID'),directory)
    return start(directory)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('command',choices=['create','start','status','stop','report','serve','controller','use-current']);parser.add_argument('--directory');parser.add_argument('--root',default=str(DEFAULT));parser.add_argument('--name');parser.add_argument('--bin');args=parser.parse_args()
    if args.command=='create':
        if not args.bin:parser.error('create needs --bin isolated Swift release product directory')
        directory=create(args);print(json.dumps({'directory':str(directory),'next':'start --directory ...'}));return
    directory=Path(args.directory) if args.directory else Path(read_json(Path(args.root)/'latest.json')['directory']);store=Store(directory)
    if args.command=='start':print(json.dumps({'directory':str(directory),'url':start(directory)}))
    elif args.command=='use-current':print(json.dumps({'directory':str(directory),'url':use_current(directory)}))
    elif args.command=='status':print(json.dumps({'phase':store.get('phase'),'boards':len(store.rows('boards')),'planned':store.get('planned_trials'),'counts':{s:len(store.rows('jobs','WHERE status=?',(s,))) for s in ['pending','running','solved','timeout','failed']},'runtime':read_json(directory/'runtime.json'),'controller':read_json(directory/'controller-heartbeat.json')},indent=2))
    elif args.command=='stop':(directory/'STOP').touch();print('Stop requested; checkpoints and queue preserved.')
    elif args.command=='report':print(export_report(store))
    elif args.command=='serve':
        from benchqueue.server import serve
        serve(directory)
    elif args.command=='controller':Controller(directory).run()
if __name__=='__main__':main()
