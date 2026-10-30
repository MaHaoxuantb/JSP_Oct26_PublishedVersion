#!/usr/bin/env python3
"""Release products in an explicit scratch directory; installed workers are never replaced."""
from pathlib import Path
import argparse,os,subprocess,json,hashlib
p=argparse.ArgumentParser();p.add_argument('--scratch',required=True);args=p.parse_args()
here=Path(__file__).resolve().parent;repo=here.parent.parent;scratch=Path(args.scratch).resolve();scratch.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,SWIFTPM_MODULECACHE_OVERRIDE=str(scratch/'modules'),CLANG_MODULE_CACHE_PATH=str(scratch/'modules'))
subprocess.run(['swift','build','--build-system','native','--disable-sandbox','--package-path',str(here),'--scratch-path',str(scratch),'-c','release'],env=env,check=True)
binary=next(scratch.glob('*/release/completion-worker'));release=binary.parent
sources=sorted(p for p in (repo/'JaneStreetPuzzle_Oct26').glob('*.swift') if p.name!='main.swift')
subprocess.run(['swiftc','-O','-D','PATHS_CPU_ONLY','-module-cache-path',str(scratch/'modules'),'-I',str(release/'Modules'),*map(str,sources),str(here/'ProductionAdapter/ProductionWorker.swift'),*map(str,(release/'PuzzleRules.build').glob('*.o')),'-o',str(release/'production-worker')],check=True)
print(json.dumps({'worker':str(binary),'productionWorker':str(release/'production-worker'),'hashes':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [binary,release/'production-worker']}},indent=2))
