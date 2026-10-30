#!/usr/bin/env python3
"""Append new results, retaining the previous report verbatim before our marker."""
import csv,hashlib,json,math,sys,subprocess
from pathlib import Path
from collections import defaultdict
from reportlab.graphics.shapes import Drawing,String,Line,Circle,PolyLine,Rect
from reportlab.graphics import renderSVG
from reportlab.lib.colors import HexColor
here=Path(__file__).resolve().parent
folder=Path(sys.argv[1]) if len(sys.argv)>1 else Path((here/'latest-run.txt').read_text().strip())
meta=json.loads((folder/'metadata.json').read_text());results=json.loads((folder/'results.json').read_text())
assert len(results)==4 and 'completed' in meta
old=Path(meta['oldReport']).parent;fixtures=json.loads((folder/'fixtures.json').read_text())['puzzles']
sys.path[:0]=[str(here.parent/'discrete_vs_continuous'),str(here.parent/'regional_production')]
from rules import validate
from metrics import exact_metrics
checks=[]
for r,f in zip(results,fixtures):
    if r.get('labels'):
        check=validate(sum(r['labels'],[]),r['n'],f['clues']);m=exact_metrics(r['labels'],f)
        assert check['solved']==r['solved'] and check==r['independentValidation']
        assert abs(m['commonExactEnergy']-r['observations'][-1]['energy'])<1e-9
        checks.append({'n':r['n'],**check,**m})
(folder/'verification.json').write_text(json.dumps(checks,indent=2))
# A sparse, step-wise diagnostic curve on real wall-clock time. No fabricated
# values before the first complete partition or past a solver's stopping time.
oldrows=list(csv.DictReader((old/'energy_samples.csv').open()))
colors=['#2869aa','#d66b24','#568e35','#9852aa','#164e63']
d=Drawing(1080,650);d.add(Rect(0,0,1080,650,fillColor=HexColor('#ffffff'),strokeColor=None))
d.add(String(24,626,'Branch pruning: complete-partition energy over real time',fontSize=18,fillColor=HexColor('#172331')))
d.add(String(24,607,'Running minimum; branch diagnostics versus the existing discrete control (old trials unchanged)',fontSize=10))
for panel,r in enumerate(results):
    n=r['n'];x0=65+(panel%2)*530;y0=360-(panel//2)*282;w=440;h=185
    xmax=600 if n>=6 else max(0.02,r['seconds']*1.15,9 if n==5 else 0)
    def xy(t,e):return (x0+min(t,xmax)/xmax*w,y0+e/0.65*h)
    d.add(String(x0,y0+h+16,f'{n} x {n}',fontSize=13))
    for v in [0,.2,.4,.6]:
        y=xy(0,v)[1];d.add(Line(x0,y,x0+w,y,strokeColor=HexColor('#e2e8ef')));d.add(String(x0-31,y-3,f'{v:.1f}',fontSize=9))
    d.add(Line(x0,y0,x0+w,y0));d.add(Line(x0,y0,x0,y0+h))
    for i in range(5):
        t=xmax*i/4;x=xy(t,0)[0];d.add(String(x-12,y0-15,f'{t:.3g}',fontSize=9))
    d.add(String(x0+w/2-30,y0-31,'Seconds',fontSize=10))
    series=[('Branch pruning',[(v['seconds'],v['energy']) for v in r['observations']],r['seconds'],colors[0])]
    if n in [5,7]:
        prefix='gate-5x5-discrete-control' if n==5 else '7x7-discrete-control'
        selected=[v for v in oldrows if v['id'].startswith(prefix)]
        values=[];best=math.inf
        for v in selected:
            best=min(best,float(v['common']));values.append((float(v['seconds']),best))
        series.append(('Old discrete control',values,max(float(v['seconds']) for v in selected),colors[1]))
    for name,values,end,color in series:
        points=[]
        for i,(t,e) in enumerate(values):
            if i:points.extend(xy(t,values[i-1][1]))
            points.extend(xy(t,e))
        if values:points.extend(xy(end,values[-1][1]))
        if len(points)>=4:d.add(PolyLine(points,strokeColor=HexColor(color),strokeWidth=1.8))
        for t,e in values:
            if t<=xmax:d.add(Circle(*xy(t,e),r=1.6,fillColor=HexColor(color),strokeColor=None))
    for j,(name,_,_,color) in enumerate(series):
        d.add(Line(x0+j*190,y0+h+3,x0+j*190+14,y0+h+3,strokeColor=HexColor(color),strokeWidth=2));d.add(String(x0+j*190+19,y0+h,name,fontSize=9))
d.add(String(24,12,'Catalog time is included. Branch curves sample singleton completions and full covers; they do not measure partial-board energy.',fontSize=9))
renderSVG.drawToFile(d,str(folder/'branch-energy.svg'))
node=Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node'
subprocess.run([str(node),str(here/'render.cjs'),str(folder)],check=True)
marker='\n\n<!-- branch-pruning-extension -->\n'
report=Path(meta['oldReport']);original=report.read_text().split(marker)[0]
(folder/'previous-report.md').write_text(original)
oldhash=hashlib.sha256(original.encode()).hexdigest()
text='\n## Added experiment: Swift branch pruning, 600-second limit\n\n'
text+='Four new sequential, single-process trials only; the preceding 300-second experiments were not rerun or extended. Times below include catalog generation and search. Compilation and puzzle making are excluded. The 5×5 and 7×7 clues are exactly the old fixtures. New 4×4 and 6×6 clues use the same target density, rounded to a whole cell.\n\n'
text+='| Board | Clues | Exact solve time / outcome | Catalog generation | Catalog shapes | Nodes | Distance prunes | Final incorrect clues |\n|---|---:|---|---:|---:|---:|---:|---:|\n'
for r,f in zip(results,fixtures):
    n=r['n'];clues=sum(c>=0 for row in f['clues'] for c in row)
    outcome=f"Solved in {r['seconds']:.3f} s" if r['solved'] else f"Unsolved at {r['seconds']:.3f} s ({r['reason']})"
    wrong=r.get('independentValidation',{}).get('wrongClues','—')
    text+=f"| {n}×{n} | {clues}/{n*n} ({clues/(n*n):.2%}) | {outcome} | {r['catalogSeconds']:.3f} s | {r['shapeCount']:,} | {r['counters']['nodes']:,} | {r['counters']['distancePrunes']:,} | {wrong} |\n"
r=next(r for r in results if r['n']==5)
text+=f"\nThe sparse 5×5 solved in {r['seconds']:.3f} s versus the previously measured 8.637 s for the discrete control (about {8.63676675/r['seconds']:.1f}× faster in this trial) and 10.397 s for regional discrete. The continuous arms did not solve within their old 300-second budget. This is a single trial on one fixture, not a general speed guarantee. There are no old 4×4 or 6×6 control measurements. The old 7×7 trials stopped at 300 seconds, so they do not establish what those engines would do with 600 seconds.\n\n"
text+='The new algorithm enumerates symmetric connected regions, then performs whole-board exact-cover DFS with minimum-remaining-values branching. It prunes impossible coverage, invalid capitol placements, adjacent-clue size bounds, and clue values outside admissible shortest-path bounds. Every 2,048 nodes a feasible partial cover may be completed with singletons for diagnostics and solution detection. This is a different algorithm from the annealing engines; it does not isolate number representation or regional randomization.\n\n'
text+='Catalog generation gets up to 45 seconds inside the 600-second total, with per-job quotas. Indexing and sorting happen afterward and are also included in total time; the catalog-generation column excludes that sorting. All region sizes through the entire board are allowed. Catalog status: '+', '.join(f"{r['n']}×{r['n']} {'complete' if r['catalogComplete'] else 'incomplete ('+str(r['counters']['catalogJobsTruncated'])+' truncated jobs)'}" for r in results)+'. Exhausting an incomplete catalog is not an unsatisfiability proof. A timeout is not an estimated solve time.\n\n'
relative=Path(__import__('os').path.relpath(folder,old))
text+=f'![Branch diagnostic energy over real time]({relative}/branch-energy.png)\n\n'
text+='The chart uses the same common exact energy as above, evaluated on complete partitions with valid region geometry only. The branch curve is the best observed singleton completion or full cover, while old curves retain their original sampling. No energy is assigned to an unfinished partition, and no line extends beyond its measured stopping time. Catalog generation appears as a gap before the first branch observation.\n\n'
text+='Validation: two exhaustive catalog comparisons (2×2/3×3) and six exhaustive pruning comparisons preserved all 161 satisfying small-board partitions. Every returned partition was independently checked in Python. New fixtures are generated from valid partitions; uniqueness and comparable difficulty across sizes are not established. The timed solver received clues only, without witnesses. All production source hashes remained unchanged. No release bump or deployment occurred.\n\n'
text+=f'Frozen Swift sources, fixtures, results, logs and validation: [{relative}]({relative}/). Algorithm and reproduction instructions: [branch_pruning/README.md]({relative}/../../README.md).\n'
report.write_text(original+marker+text)
(folder/'report-provenance.json').write_text(json.dumps({'originalReportSHA256':oldhash,'appendedReport':str(report)},indent=2))
print(report)
