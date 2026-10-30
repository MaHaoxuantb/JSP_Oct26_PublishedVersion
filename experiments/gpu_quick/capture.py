"""JSP-Oct26-GPU-Quick; ©2026 ThomasB. Capture completed observations only."""
import json,pathlib,sys
root=pathlib.Path(json.load(open('/private/tmp/jsp-repair-current.json'))['directory'])
snap=json.load(open(root/'snapshot.json')); boards={}
for job in snap['jobs']:
 d=root/'trials'/job['id']
 if not d.exists() or not (d/'input.json').exists(): continue
 inp=json.load(open(d/'input.json')); puzzle=inp.get('worker',inp).get('puzzle')
 if not puzzle or puzzle['n'] not in [7,9,11]:continue
 board=boards.setdefault(puzzle['n'],dict(n=puzzle['n'],clues=puzzle['clues'],records=[]))
 p=d/'repairs.jsonl'
 if p.exists():
  for line in p.open():
   e=json.loads(line)
   if e.get('event')=='create' and len(board['records'])<96:
    board['records'].append(dict(labels=e['sourceLabels'],patch=e['patch']))
 if job.get('labels') and len(board['records'])<96:
  board['records'].append(dict(labels=job['labels'],patch=list(range(puzzle['n']**2))))
assert boards and all(b['records'] for b in boards.values())
out=dict(experiment='JSP-Oct26-GPU-Quick',copyright='©2026 ThomasB',source=str(root),boards=list(boards.values()))
pathlib.Path(sys.argv[1]).write_text(json.dumps(out))
print({n:len(b['records']) for n,b in boards.items()})
