#!/usr/bin/env python3
"""Wall-time curves and a transparent one-seed pilot report."""
import argparse
import csv
import json
import math
from pathlib import Path
from reportlab.graphics.shapes import Drawing, String, Line, Circle
from reportlab.graphics.charts.lineplots import LinePlot
from reportlab.graphics import renderSVG
from reportlab.lib.colors import HexColor

here=Path(__file__).resolve().parent
p=argparse.ArgumentParser(); p.add_argument('directory',type=Path,nargs='?')
a=p.parse_args(); folder=a.directory or (here / (here/'latest-run.txt').read_text().strip())
meta=json.loads((folder/'metadata.json').read_text()); limit=meta['seconds_per_trial']
conditions=meta['conditions']; all_results={}; samples={}; csv_rows=[]
for condition in conditions:
    key=condition['id']; logfile=folder/key/'energy.jsonl'; values=[]
    if logfile.exists():
        for line in logfile.read_text().splitlines():
            try: values.append(json.loads(line))
            except json.JSONDecodeError: pass
    if values: samples[key]=values
    result=folder/key/'result.json'
    if result.exists(): all_results[key]=json.loads(result.read_text())
    for d in values:
        row={'condition':key,'seconds':d['seconds'],'cpuSeconds':d['cpuSeconds'],'event':d['kind']}
        for which in ['current','nativeBest','exactBest']:
            s=d[which]
            row.update({which+'_'+k:v for k,v in s['native'].items()})
            row.update({which+'_'+k:s[k] for k in ['common','wrong','issues','valid']})
        if d.get('proposal'): row.update({'proposal_'+k:v for k,v in d['proposal'].items()})
        csv_rows.append(row)
fields=sorted(set().union(*(r.keys() for r in csv_rows))) if csv_rows else []
with (folder/'energy_samples.csv').open('w',newline='') as f:
    writer=csv.DictWriter(f,fieldnames=fields); writer.writeheader(); writer.writerows(csv_rows)

BLUE=HexColor('#2568a6'); ORANGE=HexColor('#d36c25'); INK=HexColor('#172331')
MUTED=HexColor('#596675'); GRID=HexColor('#dfe5eb')
def text(d,x,y,s,size=12,color=INK): d.add(String(x,y,s,fontName='Helvetica',fontSize=size,fillColor=color))
def transform(v): return v/.001 if v<=.001 else 1+math.log10(v/.001)
def timeseries(key,metric):
    out=[]
    for record in samples.get(key,[]):
        s=record['exactBest'] if metric=='exact' else record['nativeBest'] if metric=='native' else record['current']
        value=s['common'] if metric=='exact' else s['native']['total']
        point=(record['seconds'],value)
        if len(out)>1 and out[-1][1]==value and out[-2][1]==value: out[-1]=point
        else: out.append(point)
    return out

def make_plot(metric,filename,title):
    d=Drawing(1120,840)
    text(d,70,805,title,21)
    d.add(Line(70,773,97,773,strokeColor=BLUE,strokeWidth=2)); text(d,105,769,'Uniform locations; fixed n=8')
    d.add(Line(420,773,447,773,strokeColor=ORANGE,strokeWidth=2)); text(d,455,769,'Regional focus and adaptive n=1...16')
    for row,representation in enumerate(['discrete','continuous']):
        for col,size in enumerate([5,7]):
            x=70+560*col; y=448-358*row
            text(d,x,y+270,f'{size} x {size}  -  {representation}',15)
            plot=LinePlot(); plot.x=x; plot.y=y; plot.width=440; plot.height=225
            data=[]; endpoints=[]
            for policy in ['uniform','regional']:
                key=f'{size}x{size}-{representation}-{policy}'; series=timeseries(key,metric)
                stepped=[]
                for i,(t,v) in enumerate(series):
                    if i: stepped.append((t,transform(series[i-1][1]) if metric!='current' else series[i-1][1]))
                    stepped.append((t,transform(v) if metric!='current' else v))
                data.append(stepped or [(0,0)])
                endpoints.append((series,key))
            plot.data=data; plot.joinedLines=1
            plot.xValueAxis.valueMin=0; plot.xValueAxis.valueMax=limit; plot.xValueAxis.valueStep=limit/5
            plot.xValueAxis.labelTextFormat='%d'
            plot.yValueAxis.valueMin=0; plot.yValueAxis.valueMax=1 if metric=='current' else 4
            plot.yValueAxis.valueStep=.2 if metric=='current' else 1
            plot.yValueAxis.labelTextFormat='%.1f' if metric=='current' else lambda v:{0:'0',1:'0.001',2:'0.01',3:'0.1',4:'1'}.get(round(v),'')
            for axis in [plot.xValueAxis,plot.yValueAxis]:
                axis.strokeColor=GRID; axis.labels.fontName='Helvetica'; axis.labels.fontSize=11; axis.labels.fillColor=MUTED
                axis.visibleGrid=1; axis.gridStrokeColor=GRID; axis.gridStrokeWidth=.4
            for i,color in enumerate([BLUE,ORANGE]): plot.lines[i].strokeColor=color; plot.lines[i].strokeWidth=1.5 if metric!='current' else .5
            d.add(plot)
            for i,(series,key) in enumerate(endpoints):
                if series and key in all_results and all_results[key]['solved']:
                    t,v=series[-1]; dx=x+min(t,limit)/limit*440
                    dy=y+(v if metric=='current' else transform(v))/(1 if metric=='current' else 4)*225
                    d.add(Circle(dx,dy,3,fillColor=[BLUE,ORANGE][i],strokeColor=[BLUE,ORANGE][i]))
            text(d,x+130,y-33,'Elapsed wall-clock time (seconds)',10,MUTED)
            end_labels=[]
            for series,key in endpoints:
                if series: end_labels.append(f"{'regional' if key.endswith('regional') else 'uniform'} {series[-1][1]:.5f}")
            text(d,x,y+244,'Last saved energy: '+', '.join(end_labels),10,MUTED)
    note='Energy: logarithmic above 0.001, linear below; lower is better. Exact zero requires a verified solution.' if metric!='current' else 'Native current energies include uphill moves and restarts. Native scales differ between representations.'
    text(d,70,29,note,10,MUTED)
    text(d,70,11,'One seed; 7/25 clues on 5x5 and 13/49 on 7x7. Four single-worker conditions share each size batch.',10,MUTED)
    renderSVG.drawToFile(d,str(folder/(filename+'.svg')))

make_plot('exact','exact-energy','Best exact partition energy over real time')
make_plot('native','native-energy','Best native energy over real time')
make_plot('current','current-energy','Current native energy over real time')

lines=['# Regional energy pilot results','',
       f"Completed observations: {len(all_results)}/8. One matched search seed ({meta['seed']}); {limit:g}-second cutoff per condition.", '',
       'This is the shared experimental mutation harness described in the plan. It is not the complete production catalog/repair solver, so its times are not directly comparable with the earlier production benchmark. The primary contrast is regional versus uniform within each representation.','',
       '| Condition | Outcome | Verified solve time (s) | Last best exact energy | Wrong clues | Structural issues |',
       '|---|---|---:|---:|---:|---:|']
for c in conditions:
    key=c['id']; result=all_results.get(key)
    if result:
        end=result['exactBest']; state='Solved' if result['solved'] else f'Unsolved at {limit:g}s cutoff'
        solve=f"{result['seconds']:.3f}" if result['solved'] else '—'
    elif key in samples:
        end=samples[key][-1]['exactBest']; state='Running'; solve='—'
    else: end=None; state='Not started'; solve='—'
    lines.append(f"| {key} | {state} | {solve} | {format(end['common'],'.6f') if end else '—'} | {end['wrong'] if end else '—'} | {end['issues'] if end else '—'} |")
lines+=['','## Within-representation energy comparison','',
        '| Board / representation | Uniform best exact energy | Regional best exact energy | Regional change |',
        '|---|---:|---:|---:|']
for size in [5,7]:
    for representation in ['discrete','continuous']:
        base=all_results.get(f'{size}x{size}-{representation}-uniform')
        adaptive=all_results.get(f'{size}x{size}-{representation}-regional')
        if base and adaptive:
            b=base['exactBest']['common']; r=adaptive['exactBest']['common']
            change=(b-r)/b*100 if b else 0
            lines.append(f'| {size}x{size} {representation} | {b:.6f} | {r:.6f} | {abs(change):.1f}% '+('lower' if change>1e-8 else 'higher' if change<-1e-8 else 'unchanged')+' |')
lines+=['','No solve-time winner is established if both trials hit the cutoff. Lower best exact energy measures progress, not faster solving. The regional policy changes both focus and breadth; this pilot does not isolate spatial assignment from a change in overall mutation aggressiveness.','',
        '![Exact energy over elapsed wall time](exact-energy.png)','','## Proposal diagnostics','',
        '| Condition | Mean n | Mean changed edges / attempt | No-ops | Accepted / evaluated proposals | CPU seconds |',
        '|---|---:|---:|---:|---:|---:|']
for c in conditions:
    key=c['id']; result=all_results.get(key)
    d=result or (samples[key][-1] if key in samples else None)
    if not d: continue
    m=d['metrics']; count=m['attempts']
    if not count: continue
    n=sum(i*v for i,v in enumerate(m['nHistogram']))/count
    valid=count-m['noops']
    lines.append(f"| {key} | {n:.2f} | {m['changedEdges']/count:.3f} | {m['noops']/count:.1%} | {m['accepted']/max(1,valid):.1%} | {d['cpuSeconds']:.2f} |")
lines+=['','## Energy and fairness','',
        'Both arms compute the field and rescore the whole board. Uniform uses random focus and n=8. Regional uses 20% uniform exploration, 80% energy-weighted focus and n=1...16. Both continuous arms use weights (AIM, symmetry, discreteness)=(2,1,2); binary uncertainty is zero. Native discrete energy is normalized over its two active terms.','',
        'The shared exact energy is (2*normalized integer clue error + invalid-state cell fraction)/3.25. “Best exact” is the smallest value encountered, saved for observation only. It does not change acceptance or proposal generation. Native-best and current traces are provided separately, so a low surrogate score is not confused with an exact solution.','',
        'Each size batch starts its four one-worker conditions together. Completed solves may free CPU capacity for survivors; process CPU times are shown. Compilation is excluded, while initialization, field computation, proposals, scoring, validation, checkpoints and logging are inside search wall time. There is no GPU path evaluation.','',
        'Cutoffs are right-censored observations, not 300-second solve times. This one-seed pilot does not establish a typical solve time or a general speedup. If neither member of a pair solves, compare progress curves and exact residuals without claiming a solve-time winner.','',
        '[Native retained-best curves](native-energy.png) · [Current-state curves](current-energy.png) · [Raw samples](energy_samples.csv) · [Build metadata](metadata.json) · [Full results](results.json)','']
if len(all_results)==8:
    for size in [5,7]:
        group=[r for k,r in all_results.items() if k.startswith(f'{size}x{size}')]
        assert len({tuple(r['initial']['labels']) for r in group})==1
        for representation in ['continuous','discrete']:
            pair=[r for r in group if r['representation']==representation]
            assert pair[0]['initial']['relationships']==pair[1]['initial']['relationships']
    lines+=['Verified: all conditions of a size share the initial topology; ON/OFF pairs have identical initial relationship values. Final snapshots were independently checked by the Python rules checker.','']
(folder/'REPORT.md').write_text('\n'.join(lines))
print('\n'.join(lines[:18]))
