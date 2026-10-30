#!/usr/bin/env python3
"""Append only this matched-comparison section; retain all previous results."""
import csv,hashlib,json,math,os,subprocess,sys
from collections import defaultdict
from pathlib import Path
here=Path(__file__).resolve().parent
folder=Path(sys.argv[1]) if len(sys.argv)>1 else Path((here/'latest-run.txt').read_text().strip())
meta=json.loads((folder/'metadata.json').read_text());results=json.loads((folder/'results.json').read_text())
fixtures=json.loads((folder/'fixtures.json').read_text())['puzzles']
sys.path[:0]=[str(here.parent/'discrete_vs_continuous'),str(here.parent/'regional_production')]
from rules import validate
from metrics import exact_metrics
samples={};checks=[];rows=[]
for r in results:
    fixture=next(f for f in fixtures if f['n']==r['n'])
    check=validate(sum(r['labels'],[]),r['n'],fixture['clues']);assert check==r['validation']
    metrics=exact_metrics(r['labels'],fixture);r['finalEnergy']=metrics['commonExactEnergy']
    values=[]
    if r['engine']=='branch':values=[{'id':r['id'],'seconds':v['seconds'],'energy':v['energy'],'wrong':v['wrongClues']} for v in r['observations']]
    else:
        for log in sorted((folder/r['id']/'logs').glob('*.jsonl')):
            for line in log.read_text().splitlines():
                obj=json.loads(line);event=obj['event'];snap=event.get('snapshot')
                if not snap:continue
                labels=snap['labels'];verification=validate(sum(labels,[]),r['n'],fixture['clues'])
                assert verification['solved']==snap['validation']['valid']
                m=exact_metrics(labels,fixture)
                assert abs(m['commonExactEnergy']-event['best']['total'])<1e-9
                values.append({'id':r['id'],'seconds':obj['elapsedSeconds'],'energy':m['commonExactEnergy'],'wrong':verification['wrongClues']})
    assert abs(values[-1]['energy']-r['finalEnergy'])<1e-9
    samples[r['id']]=values;rows+=values
    checks.append({'id':r['id'],**check,**metrics,'verifiedControlSnapshots':len(values) if r['engine']=='discrete' else None})
(folder/'verification.json').write_text(json.dumps(checks,indent=2))
with (folder/'energy-samples.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=['id','seconds','energy','wrong']);w.writeheader();w.writerows(rows)
plot=''
if len(results)==6:
    from reportlab.graphics.shapes import Drawing,String,Line,Circle,PolyLine,Rect
    from reportlab.graphics import renderSVG
    from reportlab.lib.colors import HexColor
    d=Drawing(1200,405);d.add(Rect(0,0,1200,405,fillColor=HexColor('#ffffff'),strokeColor=None))
    d.add(String(23,378,'Matched puzzles: branch pruning versus old discrete control',fontSize=18))
    d.add(String(23,358,'Lowest observed common exact energy over real elapsed time; 1,000-second cutoff per trial',fontSize=10))
    for panel,n in enumerate([7,8,9]):
        x0=52+panel*397;y0=77;w=328;h=220
        def xy(t,e):return (x0+min(t,1000)/1000*w,y0+e/.65*h)
        d.add(String(x0,y0+h+26,f'{n} x {n}',fontSize=13))
        for e in [0,.2,.4,.6]:
            y=xy(0,e)[1];d.add(Line(x0,y,x0+w,y,strokeColor=HexColor('#e3e7ec')));d.add(String(x0-28,y-3,f'{e:.1f}',fontSize=9))
        d.add(Line(x0,y0,x0+w,y0));d.add(Line(x0,y0,x0,y0+h))
        for t in [0,250,500,750,1000]:
            x=xy(t,0)[0];d.add(String(x-11,y0-17,str(t),fontSize=9))
        d.add(String(x0+w/2-25,y0-36,'Seconds',fontSize=10))
        for j,(engine,color,title) in enumerate([('branch','#2869aa','Branch pruning'),('discrete','#d66b24','Discrete control')]):
            r=next(r for r in results if r['n']==n and r['engine']==engine);points=[];best=math.inf;last=None
            for v in samples[r['id']]:
                if last is not None:points.extend(xy(v['seconds'],best))
                best=min(best,v['energy']);points.extend(xy(v['seconds'],best));last=v
            if last:points.extend(xy(r['seconds'],best))
            if len(points)>=4:d.add(PolyLine(points,strokeColor=HexColor(color),strokeWidth=1.8))
            d.add(Line(x0+j*164,y0+h+10,x0+j*164+13,y0+h+10,strokeColor=HexColor(color),strokeWidth=2))
            d.add(String(x0+j*164+18,y0+h+7,title,fontSize=9))
    d.add(String(23,13,'Catalog time is included. Branch observations are complete diagnostic partitions; control observations are logged retained candidates.',fontSize=9))
    renderSVG.drawToFile(d,str(folder/'comparison-energy.svg'))
    node=Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node'
    subprocess.run([str(node),str(here/'render.cjs'),str(folder)],check=True)
    rel=os.path.relpath(folder,Path(meta['report']).parent)
    plot=f'\n![Energy over real time]({rel}/comparison-energy.png)\n'
text='\n## Added comparison: 7×7, 8×8 and 9×9, 1,000 seconds per solver\n\n'
text+=('Completed.' if 'completed' in meta else f'In progress: {len(results)} of six trials completed.')+' One sequential process at a time; branch pruning first, then the frozen old discrete control for each size. Both get the same clues and a 1,000-second total solve budget. Control seed: 20261029; regional policy disabled. Earlier measurements above remain unchanged.\n\n'
text+='The 7×7 fixture is unchanged. The deterministic maker generated 8×8 (seed 8101) and 9×9 (seed 9101), sampling clues uniformly without replacement at the real puzzle’s rounded density of 33/121. The resulting puzzles are satisfiable; uniqueness and matched difficulty across sizes are not established. Witnesses are saved separately and are not passed to either timed solver.\n\n'
text+='| Board | Clues | Branch pruning | Old discrete control | Final incorrect clues (branch / control) |\n|---|---:|---|---|---:|\n'
for fixture in fixtures:
    n=fixture['n'];k=sum(c>=0 for row in fixture['clues'] for c in row);pair={r['engine']:r for r in results if r['n']==n}
    def outcome(engine):
        r=pair.get(engine)
        return 'Pending' if r is None else f"Solved in {r['seconds']:.3f} s" if r['solved'] else f"Unsolved at {r['seconds']:.3f} s ({r['reason']})"
    wrong=' / '.join(str(pair[e]['validation']['wrongClues']) if e in pair else '—' for e in ['branch','discrete'])
    text+=f'| {n}×{n} | {k}/{n*n} ({k/(n*n):.2%}) | {outcome("branch")} | {outcome("discrete")} | {wrong} |\n'
text+='\nBranch pruning retains the earlier algorithm and its 45-second catalog-generation allocation inside the total budget. 7×7 uses the original 64-bit masks; 8×8 and 9×9 use 128-bit masks to represent all 64/81 cells correctly. The search heuristics and pruning rules are unchanged. The control is rebuilt from the frozen sources of the prior production-preserving experiment, with its original configuration and moves. Both are optimized Swift builds; compilation and fixture generation are outside the timer. Catalog generation, indexing and search are inside the branch timer. Wrapper process-wall times are also saved.\n\n'
if results:
    text+='| Branch board | Catalog generation | Catalog shapes | Catalog complete? | Search nodes | Distance prunes | Final exact energy |\n|---|---:|---:|---|---:|---:|---:|\n'
    for r in results:
        if r['engine']=='branch':text+=f"| {r['n']}×{r['n']} | {r['catalogSeconds']:.3f} s | {r['shapeCount']:,} | {'Yes' if r['catalogComplete'] else 'No'} | {r['counters']['nodes']:,} | {r['counters']['distancePrunes']:,} | {r['finalEnergy']:.6f} |\n"
text+=plot
text+='\nEnergy is the same common exact score used above, plotted against actual elapsed seconds. Branch observations come from full covers and singleton completions; control observations come from retained-candidate logs. Their sampling differs, and energy alone is not solve speed. Curves start at the first observation and stop at the measured ending time. A truncated branch catalog is incomplete; a cutoff does not prove impossibility or estimate eventual solve time. This is one fixture and one trial per solver per size, with fixed branch-first order and no machine-load isolation.\n\n'
text+='The 64-bit build repeats eight exhaustive checks. The 128-bit build repeats those checks and adds solved all-singleton 8×8/9×9 cases, verifying bits through cell 80. All reported final partitions are independently validated for geometry, capitols and integer clue distances; all logged control snapshots are independently checked too.\n\n'
if 'completed' in meta:text+='All production source hashes remained unchanged. No installed executables, live state or deployment were touched.\n\n'
rel=os.path.relpath(folder,Path(meta['report']).parent)
text+=f'Artifacts: [fixtures, frozen sources, logs, results, validation and sampled energies]({rel}/).\n'
base=(folder/'previous-report.md').read_text();Path(meta['report']).write_text(base+'\n\n<!-- branch-vs-discrete-1000 -->\n'+text)
(folder/'report-provenance.json').write_text(json.dumps({'baseReportSHA256':hashlib.sha256(base.encode()).hexdigest(),'report':meta['report']},indent=2))
