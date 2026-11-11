#!/usr/bin/env python3
"""New Swift branch-pruning trials only. Never invokes old experiments or production workers."""
import hashlib,json,subprocess,sys,tempfile,time
from pathlib import Path
from datetime import datetime
here=Path(__file__).resolve().parent; root=here.parents[1]
old=(here.parent / 'regional_production' / (here.parent/'regional_production/latest-run.txt').read_text().strip())
out=here/'results'/datetime.now().strftime('%Y%m%d-%H%M%S');out.mkdir(parents=True)
(here/'latest-run.txt').write_text(str(out.relative_to(here))+'\n')
sys.path.insert(0,str(here.parent/'discrete_vs_continuous'))
from rules import validate
core={str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in (root/'JaneStreetPuzzle_Oct26').glob('*.swift')}
metadata={'budgetSeconds':600,'concurrency':1,'oldReport':str(old/'REPORT.md'),'coreHashesBefore':core,'started':datetime.now().isoformat(),'algorithm':'Deterministic region exact cover with MRV and admissible shortest-path bounds; timed orbit catalog; singleton diagnostic completions every 2048 nodes.'}
(out/'sources').mkdir()
for x in here.glob('*.swift'):(out/'sources'/x.name).write_bytes(x.read_bytes())
results=[]
with tempfile.TemporaryDirectory(prefix='jsp-branch-',dir='/private/tmp') as scratch:
    binary=Path(scratch)/'branch'
    subprocess.run(['swiftc','-O','-module-cache-path',str(Path(scratch)/'cache'),*map(str,sorted((out/'sources').glob('*.swift'))),'-o',str(binary)],check=True)
    with (out/'self-test.log').open('w') as log:subprocess.run([str(binary),'--self-test'],stdout=log,stderr=subprocess.STDOUT,check=True)
    subprocess.run([str(binary),'--make',str(old/'fixtures.json'),str(out)],check=True)
    fixtures=json.loads((out/'fixtures.json').read_text())['puzzles']
    for p in json.loads((out/'maker-witnesses.json').read_text()):assert validate(p['witness'],p['n'],p['clues'])['solved']
    (out/'metadata.json').write_text(json.dumps(metadata,indent=2))
    for i,f in enumerate(fixtures):
        print('START',f['n'],datetime.now().isoformat(),flush=True)
        with (out/f"{f['n']}x{f['n']}.log").open('w') as log:
            subprocess.run([str(binary),str(out/'fixtures.json'),str(i),'600',str(out/f"{f['n']}x{f['n']}.json")],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=660)
        r=json.loads((out/f"{f['n']}x{f['n']}.json").read_text())
        if r.get('labels'):
            check=validate(sum(r['labels'],[]),f['n'],f['clues'])
            r['independentValidation']=check
            assert r['solved']==check['solved']
        results.append(r);(out/'results.json').write_text(json.dumps(results,indent=2))
        print('END',f['n'],r['reason'],r['seconds'],flush=True)
metadata['coreHashesAfter']={str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in (root/'JaneStreetPuzzle_Oct26').glob('*.swift')}
assert metadata['coreHashesAfter']==core
metadata['completed']=datetime.now().isoformat();(out/'metadata.json').write_text(json.dumps(metadata,indent=2))
print('DONE',out,flush=True)
