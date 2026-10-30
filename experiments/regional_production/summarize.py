#!/usr/bin/env python3
import argparse,csv,json,math,statistics,sys
from pathlib import Path
from collections import defaultdict
from reportlab.graphics.shapes import Drawing,String,Line,Circle
from reportlab.graphics.charts.lineplots import LinePlot
from reportlab.graphics import renderSVG
from reportlab.lib.colors import HexColor
from metrics import exact_metrics
here=Path(__file__).resolve().parent
sys.path.insert(0,str(here.parent/'discrete_vs_continuous'))
from rules import validate
p=argparse.ArgumentParser(); p.add_argument('directory',nargs='?',type=Path); a=p.parse_args()
folder=a.directory or Path((here/'latest-run.txt').read_text().strip())
meta=json.loads((folder/'metadata.json').read_text()); fixtures=json.loads((folder/'fixtures.json').read_text())['puzzles']
results=json.loads((folder/'results.json').read_text()); samples={}; rows=[]; checks=[]
for r in results:
    key=r['id']; values=[]; fixture=fixtures[0 if r['n']==5 else 1]
    for file in (folder/key/'logs').glob('*.jsonl'):
        for line in file.read_text().splitlines():
            e=json.loads(line); ev=e['event']; snap=ev.get('snapshot'); scores=ev.get('best')
            if not snap or not scores: continue
            check=validate(sum(snap['labels'],[]),r['n'],fixture['clues'])
            assert check['solved']==snap['validation']['valid']
            m=exact_metrics(snap['labels'],fixture)
            if r['representation']=='discrete': assert abs(m['commonExactEnergy']-scores['total'])<1e-9
            value={'id':key,'seconds':e['elapsedSeconds'],'kind':ev['kind'],'native':scores['total'],
                   'common':m['commonExactEnergy'],'wrong':check['wrongClues'],'issues':check['issues']}
            if ev['kind']=='initialized': r['initial_snapshot']=snap
            values.append(value); rows.append(value)
    samples[key]=values
    r['final_common']=values[-1]['common']; r['final_native']=values[-1]['native']
    r['observed_common']=min(v['common'] for v in values)
    checks.append({'id':key,'verified_snapshots':len(values),'discrete_scores_agree':True if r['representation']=='discrete' else None})
    logs=list((folder/key/'logs').glob('*.jsonl'))
    if logs:
        final=json.loads(logs[0].read_text().splitlines()[-1])['event']
        r['statistics']=final.get('statistics',{})
for size in [5,7]:
    for rep in ['discrete','continuous']:
        for seed in meta['seeds']:
            pair=[r for r in results if r['n']==size and r['representation']==rep and r['seed']==seed]
            if len(pair)==2:
                aa,bb=[r.get('initial_snapshot') for r in pair]
                equal=all(aa[k]==bb[k] for k in ['labels','verticalRelationships','horizontalRelationships'])
                checks.append({'size':size,'representation':rep,'seed':seed,'matched_initial_state':equal})
with (folder/'energy_samples.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=['id','seconds','kind','native','common','wrong','issues']); w.writeheader(); w.writerows(rows)
(folder/'checks.json').write_text(json.dumps(checks,indent=2))
BLUE=HexColor('#2568a6'); ORANGE=HexColor('#d36c25'); INK=HexColor('#172331'); MUTED=HexColor('#596675'); GRID=HexColor('#dfe5eb')
def text(d,x,y,s,size=12,color=INK): d.add(String(x,y,s,fontName='Helvetica',fontSize=size,fillColor=color))
def tr(v): return v/.001 if v<=.001 else 1+math.log10(v/.001)
for metric,title in [('common','Retained candidate: common exact energy versus real time'),('native','Retained candidate: native energy versus real time'),('observed','Lowest observed exact energy versus real time')]:
    d=Drawing(1120,840); text(d,65,805,title,21)
    for x,color,label in [(65,BLUE,'Original solver control'),(395,ORANGE,'Energy-dependent randomization')]:
        d.add(Line(x,774,x+27,774,strokeColor=color,strokeWidth=2)); text(d,x+35,770,label)
    for row,rep in enumerate(['discrete','continuous']):
        for col,size in enumerate([5,7]):
            x=70+560*col; y=448-358*row
            text(d,x,y+270,f'{size} x {size} - {rep}',15)
            plot=LinePlot(); plot.x=x; plot.y=y; plot.width=440; plot.height=225
            data=[]; colors=[]; notes=[]
            for regional,color in [(False,BLUE),(True,ORANGE)]:
                selected=[r for r in results if r['n']==size and r['representation']==rep and r['regional']==regional]
                for r in selected:
                    series=samples[r['id']]; points=[]; previous=None; lowest=math.inf
                    for i,s in enumerate(series):
                        lowest=min(lowest,s['common'])
                        value=lowest if metric=='observed' else s[metric]
                        if previous is not None: points.append((s['seconds'],tr(previous)))
                        points.append((s['seconds'],tr(value))); previous=value
                    data.append(points or [(0,0)]); colors.append(color)
                    notes.append(('Regional' if regional else 'Control')+f": {r['seconds']:.2f}s "+('solved' if r['solved'] else 'cutoff'))
            plot.data=data or [[(0,0)]]; plot.joinedLines=1
            plot.xValueAxis.valueMin=0; plot.xValueAxis.valueMax=meta['seconds']; plot.xValueAxis.valueStep=60
            plot.yValueAxis.valueMin=0; plot.yValueAxis.valueMax=4; plot.yValueAxis.valueStep=1
            plot.yValueAxis.labelTextFormat=lambda v:{0:'0',1:'0.001',2:'0.01',3:'0.1',4:'1'}.get(round(v),'')
            for axis in [plot.xValueAxis,plot.yValueAxis]:
                axis.strokeColor=GRID; axis.visibleGrid=1; axis.gridStrokeColor=GRID; axis.labels.fontSize=11; axis.labels.fillColor=MUTED
            for i,color in enumerate(colors): plot.lines[i].strokeColor=color; plot.lines[i].strokeWidth=1.5
            d.add(plot); text(d,x+110,y-32,'Elapsed wall-clock time (seconds)',10,MUTED)
            for i,note in enumerate(notes): text(d,x,y-53-i*14,note,10)
    text(d,70,8,'Lower is better. Y: linear to 0.001, logarithmic above. Lines stop when a trial ends; one seed per condition.',10,MUTED)
    renderSVG.drawToFile(d,str(folder/(metric+'-energy.svg')))
lines=['# Production-preserving regional experiment','',f"Each trial: one worker, sequential execution, {meta['seconds']:g}-second cutoff. Seeds: {meta['seeds']}.",'',
       'The former generic mutation harness is excluded. The production discrete control reproduced fast 5x5 solving before regional trials began. Continuous uses the historical engine with weights 2:1:2 in both arms.','',
       '| Board | Solver | Policy | Exact solve time | Incorrect clues | Structural issues | Retained exact energy | Lowest observed exact energy |',
       '|---|---|---|---:|---:|---:|---:|---:|']
for r in results:
    timing=f"{r['seconds']:.3f} s" if r['solved'] else f"Unsolved at {r['seconds']:.3f} s"
    lines.append(f"| {r['n']}x{r['n']} | {r['representation']} | {'Regional' if r['regional'] else 'Control'} | {timing} | {r['independent']['wrongClues']} | {r['independent']['issues']} | {r['final_common']:.6f} | {r['observed_common']:.6f} |")
lines += ['', '![Lowest observed exact energy](observed-energy.png)','', 'Lowest observed energy is the running minimum over logged retained candidates, not every evaluated proposal. It is an observational diagnostic and does not guide either search.','', '![Common exact energy](common-energy.png)','', '![Native energy](native-energy.png)','',
    'Exact energy uses the same binary partition geometry and integer shortest-path distances for all candidates: `(2 * mean normalized clue error + invalid-cell fraction) / 3.25`. Native energy retains each solver\'s own objective; the continuous one uses stronger discreteness weights. Curves follow the solver\'s retained candidate, which need not minimize this common scalar score. No line is extended beyond its real stopping time.','',
    'All retained snapshots are independently checked against integer rules. Discrete exact scores are cross-checked against logged scores. Initial states are compared within each pair; see checks.json. Time-bounded production catalogs make runs timing-sensitive despite fixed seeds.','',
    '**Limits:** a one-seed pilot cannot establish a reliable speed advantage. Discrete and continuous have different initialization, move sets, ranking and temperature rules, so their difference is not caused by number representation alone. Regional changes are limited to proposal focus/breadth as documented in README.md. A cutoff is an unsolved observation, not an estimated solve time.','',
    'Search sources and their patch provenance are frozen in sources/. Original source hashes, fixtures, raw logs, independent validation, and sampled curves are preserved here. No core release or deployment occurred.','']
(folder/'REPORT.md').write_text('\n'.join(lines))
print(folder/'REPORT.md')
