"""JSP-Oct26-Search-Escape-Stall; ©2026 ThomasB. Author: ThomasB.

Bounded, sequential paired screen; never launches a background continuation.
The legacy arm disables both new scheduling options in the same binary.
"""
import argparse, hashlib, json, pathlib, shutil, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'solver_bench'))
from benchqueue.validation import evaluate

def load(p):
    return json.loads(pathlib.Path(p).read_text())

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', required=True)
    p.add_argument('--binary', required=True)
    p.add_argument('--seed-result', required=True)
    p.add_argument('--shape', required=True)
    p.add_argument('--seconds', type=float, default=60)
    a = p.parse_args()
    root = pathlib.Path(a.root); root.mkdir(exist_ok=False)
    seed = load(a.seed_result); puzzle = seed['puzzle']
    seed_check = evaluate(seed['labels'], puzzle['n'], puzzle['clues'])
    assert seed_check['issues'] == 0 and seed_check['wrong'] == seed['quality']['wrong']
    assert abs(seed_check['residual'] - seed['quality']['residual']) < 1e-12
    shutil.copy2(a.seed_result, root/'seed-result.json')
    config = dict(experiment='JSP-Oct26-Search-Escape-Stall', copyright='©2026 ThomasB',
                  author='ThomasB', seconds=a.seconds, threads=4, seeds=[2026103101,2026103102],
                  startingQuality=seed['quality'], recordAge=44000,
                  binarySHA256=hashlib.sha256(pathlib.Path(a.binary).read_bytes()).hexdigest(),
                  seedSHA256=hashlib.sha256(pathlib.Path(a.seed_result).read_bytes()).hexdigest(),
                  shapeSHA256=hashlib.sha256(pathlib.Path(a.shape).read_bytes()).hexdigest())
    (root/'config.json').write_text(json.dumps(config,indent=2))
    rows=[]
    for block, rng in enumerate(config['seeds']):
        for stable in ([False,True] if block==0 else [True,False]):
            out=root/f'{"sustained" if stable else "legacy"}-s{rng}';out.mkdir()
            inp=dict(id=out.name+'-trial',puzzle=puzzle,seed=rng,seconds=a.seconds,threads=4,
                     shapeStore=a.shape,output=str(out),stopFile=str(root/'STOP'),
                     seedResult=str(root/'seed-result.json'),policy='combined',probe=False,
                     stabilized=stable,recordAge=44000,wrongAge=44000)
            (out/'input.json').write_text(json.dumps(inp))
            with (out/'worker.log').open('w') as log:
                subprocess.run([a.binary,str(out/'input.json')],stdout=log,stderr=subprocess.STDOUT,
                               check=True,timeout=a.seconds+30)
            result=load(out/'result.json');checks=[]
            for r in [result]+result['workers']:
                q=evaluate(r['labels'],puzzle['n'],puzzle['clues']);checks.append(q)
                assert q['issues']==r['quality']['issues'] and q['wrong']==r['quality']['wrong']
                assert abs(q['residual']-r['quality']['residual'])<1e-12 and q['solved']==r['solved']
            (out/'independent-checks.json').write_text(json.dumps(checks))
            repairs={};jobs=[]
            for f in out.glob('worker-*/repair-progress.json'):
                for k,v in load(f).items():repairs[k]=repairs.get(k,0)+v
                jobs+=load(f.with_name('escape-repairs.json'))['jobs']
            samples=[json.loads(x) for x in (out/'global-events.jsonl').read_text().splitlines()]
            energies=[sum(v['activeEnergies'].values())/len(v['activeEnergies']) for v in samples if v['seconds']>5]
            row=dict(stabilized=stable,seed=rng,seconds=result['seconds'],quality=result['quality'],
                     solved=result['solved'],cpuEquivalentCores=result['cpuEquivalentCores'],repairs=repairs,
                     iterations=sum(w['metrics']['iterations'] for w in result['workers']),
                     restarts=sum(w['metrics']['restarts'] for w in result['workers']),
                     completedCovers=sum(j['search']['counters']['completedCovers'] for j in jobs),
                     maximumSurvivingJobSlices=max(j['slices'] for j in jobs if not j['protected']),
                     meanPublishedWorkingEnergy=sum(energies)/max(1,len(energies)))
            rows.append(row)
            (root/'summary.json').write_text(json.dumps(dict(config=config,trials=rows),indent=2))
            print(json.dumps(row),flush=True)

if __name__=='__main__':main()
