"""JSP-Oct26-Search-Escape; ©2026 ThomasB. Predeclared local matched mechanism screen."""
import pathlib,json,subprocess,time,sys,hashlib
HERE=pathlib.Path(__file__).resolve().parent;ROOT=pathlib.Path(sys.argv[1]);BINARY=pathlib.Path(sys.argv[2]);ROOT.mkdir(exist_ok=False)
sys.path.insert(0,str(HERE.parents[1]/'experiments/solver_bench'))
from benchqueue.validation import evaluate
source=pathlib.Path('/private/tmp/JSP-Oct26-Search-Escape');seed=json.loads((source/'seed.json').read_text());rows=[]
policies=['control','diversity','escalation','adaptive','recombination','exact','combined']
config=dict(experiment='JSP-Oct26-Search-Escape',copyright='©2026 ThomasB',author='ThomasB',seconds=30,threads=4,seeds=[2026103061,2026103062],policies=policies,probe=True,binarySHA256=hashlib.sha256(BINARY.read_bytes()).hexdigest(),seedSHA256=hashlib.sha256((source/'seed.json').read_bytes()).hexdigest())
(ROOT/'config.json').write_text(json.dumps(config,indent=2))
for block,s in enumerate(config['seeds']):
 for policy in policies if block==0 else list(reversed(policies)):
  out=ROOT/f'{policy}-s{s}';out.mkdir();inp=dict(id=out.name,puzzle=seed['puzzle'],seed=s,seconds=30,threads=4,shapeStore=str(source/'shapes.sqlite'),output=str(out),stopFile=str(ROOT/'STOP'),seedResult=str(source/'seed.json'),policy=policy,probe=True)
  (out/'input.json').write_text(json.dumps(inp));(ROOT/'status.json').write_text(json.dumps(dict(active=out.name,completed=len(rows),total=14)))
  with (out/'worker.log').open('w') as log:subprocess.run([str(BINARY),str(out/'input.json')],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=50)
  result=json.loads((out/'result.json').read_text());checks=[]
  for r in [result]+result['workers']:
   q=evaluate(r['labels'],seed['puzzle']['n'],seed['puzzle']['clues']);assert q['issues']==r['quality']['issues'] and q['wrong']==r['quality']['wrong'] and abs(q['residual']-r['quality']['residual'])<1e-12;checks.append(q)
  (out/'independent-checks.json').write_text(json.dumps(checks))
  pool=json.loads((out/'cooperative.json').read_text());repairs={}
  for f in out.glob('worker-*/repair-progress.json'):
   for k,v in json.loads(f.read_text()).items():repairs[k]=repairs.get(k,0)+v
  row=dict(policy=policy,seed=s,seconds=result['seconds'],cpuEquivalentCores=result['cpuEquivalentCores'],quality=result['quality'],solved=result['solved'],distinctPublished=pool.get('distinctPublished'),distinctActive=pool.get('distinctActive'),archiveSize=pool.get('archiveSize'),migrations=pool.get('migrations'),repairs=repairs,bpNodes=sum(w['metrics']['bpNodes'] for w in result['workers']),iterations=sum(w['metrics']['iterations'] for w in result['workers']))
  rows.append(row);(ROOT/'summary.json').write_text(json.dumps(dict(config=config,trials=rows),indent=2));print(json.dumps(row),flush=True)
(ROOT/'status.json').write_text(json.dumps(dict(phase='complete',completed=len(rows),total=14)))
