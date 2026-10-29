#!/usr/bin/env python3
"""Compare logged energies against real seconds; never rerun a search."""
from collections import defaultdict, deque
import csv
import heapq
import json
import math
from pathlib import Path
from reportlab.graphics.shapes import Drawing, String, Line, Circle
from reportlab.graphics.charts.lineplots import LinePlot
from reportlab.graphics import renderSVG
from reportlab.lib.colors import HexColor, Color

here=Path(__file__).resolve().parent
root=here/'until_solved'
out=root/'curves'; out.mkdir(exist_ok=True)
fixtures=json.loads((root/'fixtures.json').read_text())['puzzles']


def exact_metrics(labels, fixture):
    n=fixture['n']; labels=[c for row in labels for c in row]
    def neighbors(c):
        r,k=divmod(c,n)
        return [v for yes,v in [(r>0,c-n),(r+1<n,c+n),(k>0,c-1),(k+1<n,c+1)] if yes]
    groups=defaultdict(list)
    for c,v in enumerate(labels): groups[v].append(c)
    sizes=[0]*len(labels); caps=[]; invalid=0
    for cells in groups.values():
        for c in cells: sizes[c]=len(cells)
        occupied=set(cells); seen={cells[0]}; queue=deque(seen)
        while queue:
            for v in neighbors(queue.popleft()):
                if v in occupied and v not in seen: seen.add(v); queue.append(v)
        sr=min(c//n for c in cells)+max(c//n for c in cells)
        sc=min(c%n for c in cells)+max(c%n for c in cells)
        positions=[(2*(c//n)-sr,2*(c%n)-sc) for c in cells]
        fixed=[]
        for t in range(7):
            mapped=[[(k,-r),(-r,-k),(-k,r),(r,-k),(-r,k),(k,r),(-k,-r)][t] for r,k in positions]
            if set(mapped)==set(positions): fixed.append({c for c,x,y in zip(cells,positions,mapped) if x==y})
        if seen!=occupied or not fixed: invalid+=len(cells)
        elif len(fixed[0])==1 and all(f==fixed[0] for f in fixed): caps.extend(fixed[0])
    distance=[math.inf]*len(labels); heap=[]
    for c in caps: distance[c]=0; heapq.heappush(heap,(0,c))
    while heap:
        d,c=heapq.heappop(heap)
        if d!=distance[c]: continue
        for v in neighbors(c):
            through=d+min(sizes[c],sizes[v])
            if through<distance[v]: distance[v]=through; heapq.heappush(heap,(through,v))
    errors=[]; wrong=0
    for r,row in enumerate(fixture['clues']):
        for k,target in enumerate(row):
            if target<0: continue
            actual=distance[r*n+k]
            wrong+=actual!=target
            errors.append(abs(actual-target)/max(actual,target,1) if math.isfinite(actual) else 1)
    aim=sum(errors)/len(errors); symmetry=invalid/len(labels)
    return {'exactClueEnergy':aim,'invalidCellFraction':symmetry,
            'commonExactEnergy':(2*aim+symmetry)/3.25,'exactWrongClues':wrong}

series={}; rows=[]; endpoints={}; checks=[]
for job in ['discrete5','continuous5','discrete7','continuous7']:
    native=[]; common=[]; current=[]; fixture=fixtures[0 if job.endswith('5') else 1]
    events=[]
    for file in (root/job).glob('logs/**/*.jsonl'):
        for line in file.read_text().splitlines():
            try: events.append(json.loads(line))
            except json.JSONDecodeError: pass
    events.sort(key=lambda x:x['elapsedSeconds'])
    for envelope in events:
        t=envelope['elapsedSeconds']; event=envelope['event']
        if 'best' not in event: continue
        best=event['best']
        native.append((t,best['total']))
        if 'current' in event: current.append((t,event['current']['total']))
        row={'job':job,'elapsedSeconds':t,'event':event['kind'],
             **{'nativeBest_'+k:v for k,v in best.items()},
             'nativeCurrent_total':event.get('current',{}).get('total'),
             'reportedWrongClues':event.get('clueMismatchCount'),
             'reportedStructuralIssues':event.get('structuralIssueCount')}
        if job.startswith('discrete'):
            row.update(commonExactEnergy=best['total'],exactClueEnergy=best['realAIM'],invalidCellFraction=best['symmetry'])
            common.append((t,best['total']))
        if 'snapshot' in event:
            m=exact_metrics(event['snapshot']['labels'],fixture)
            row.update(m)
            assert m['exactWrongClues']==len(event['snapshot']['validation']['mismatches'])
            assert (m['invalidCellFraction']>0)==bool(event['snapshot']['validation']['issues'])
            if job.startswith('continuous'): common.append((t,m['commonExactEnergy']))
            else:
                assert abs(m['commonExactEnergy']-best['total'])<1e-10
                checks.append({'job':job,'seconds':t,'check':'snapshot common score agrees with discrete logged score'})
        rows.append(row)
    # Discrete checkpoints supply a second independent check on the shared metric.
    for file in (root/job).glob('logs/checkpoint*.json'):
        envelope=json.loads(file.read_text()); event=envelope['event']
        if 'snapshot' in event:
            m=exact_metrics(event['snapshot']['labels'],fixture)
            expected=event.get('best',event.get('current',{})).get('total')
            if expected is not None:
                assert abs(m['commonExactEnergy']-expected)<1e-10
                checks.append({'job':job,'seconds':envelope['elapsedSeconds'],'check':'checkpoint common score agrees with discrete logged score'})
    series[job]={'native':native,'common':common,'current':current}
    native_last=next(r for r in reversed(rows) if r['job']==job)
    common_last=next(r for r in reversed(rows) if r['job']==job and 'commonExactEnergy' in r)
    endpoints[job]={'native':native[-1], 'common':common[-1], 'exactClueEnergy':common_last['exactClueEnergy'],
                    'invalidCellFraction':common_last['invalidCellFraction'],
                    'wrongClues':common_last.get('exactWrongClues',native_last['reportedWrongClues']),
                    'reportedStructuralIssues':native_last['reportedStructuralIssues']}
fields=sorted(set().union(*(r.keys() for r in rows)))
with (out/'energy_samples.csv').open('w',newline='') as f:
    writer=csv.DictWriter(f,fieldnames=fields); writer.writeheader(); writer.writerows(rows)
(out/'energy_samples.json').write_text(json.dumps({'series':series,'endpoints':endpoints,'checks':checks},indent=2)+'\n')

BLUE=HexColor('#2265a8'); ORANGE=HexColor('#d16422'); INK=HexColor('#17212c'); MUTED=HexColor('#556171'); GRID=HexColor('#dfe4e9')

def symlog(v): return v/0.001 if v<=0.001 else 1+math.log10(v/0.001)
def text(d,x,y,label,size=11,color=INK): d.add(String(x,y,label,fontName='Helvetica',fontSize=size,fillColor=color))

def chart(d,x,y,title,left,right,log=True,footer='',width=440):
    text(d,x,y+267,title,14)
    plot=LinePlot(); plot.x=x; plot.y=y; plot.width=width; plot.height=225
    def steps(data):
        values=[]
        for i,(t,v) in enumerate(data):
            if i: values.append((t,symlog(data[i-1][1]) if log else data[i-1][1]))
            values.append((t,symlog(v) if log else v))
        return values
    plot.data=[steps(left),steps(right)]; plot.joinedLines=1
    plot.xValueAxis.valueMin=0; plot.xValueAxis.valueMax=340; plot.xValueAxis.valueStep=60
    plot.xValueAxis.labelTextFormat='%d'; plot.xValueAxis.labels.fontName='Helvetica'; plot.xValueAxis.labels.fontSize=12
    plot.yValueAxis.valueMin=0; plot.yValueAxis.valueMax=4 if log else 1; plot.yValueAxis.valueStep=1 if log else .2
    plot.yValueAxis.labelTextFormat=(lambda v:{0:'0',1:'0.001',2:'0.01',3:'0.1',4:'1'}.get(round(v),'')) if log else '%.1f'
    for axis in [plot.xValueAxis,plot.yValueAxis]:
        axis.strokeColor=GRID; axis.labels.fillColor=MUTED; axis.visibleGrid=1; axis.gridStrokeColor=GRID; axis.gridStrokeWidth=.4
    plot.yValueAxis.labels.fontName='Helvetica'; plot.yValueAxis.labels.fontSize=12
    for i,c in enumerate([BLUE,ORANGE]): plot.lines[i].strokeColor=c; plot.lines[i].strokeWidth=1.6
    d.add(plot)
    text(d,x+width/2-85,y-34,'Elapsed wall-clock time (seconds)',10,MUTED)
    text(d,x,y+244,footer,10,MUTED)
    if left and left[-1][1]==0:
        dx=x+left[-1][0]/340*width
        d.add(Circle(dx,y,3,fillColor=BLUE,strokeColor=BLUE))
        text(d,dx+8,y+12,'Solved at 9.15 s',10,BLUE)
    return plot

def legend(d,y):
    d.add(Line(72,y,98,y,strokeColor=BLUE,strokeWidth=2)); text(d,105,y-4,'Discrete',12)
    d.add(Line(220,y,246,y,strokeColor=ORANGE,strokeWidth=2)); text(d,253,y-4,'Continuous (historical)',12)

fig=Drawing(1120,840)
text(fig,70,804,'Energy convergence over real time',22)
legend(fig,773)
for col,size in enumerate([5,7]):
    x=70+560*col
    a=series[f'discrete{size}']; b=series[f'continuous{size}']
    chart(fig,x,448,f'{size} x {size}  -  retained best native energy',a['native'],b['native'],
          footer='Different native objectives; compare the trajectory, not equal-height values.')
    chart(fig,x,90,f'{size} x {size}  -  retained best, same exact energy',a['common'],b['common'],
          footer='Continuous snapshots rescored with the discrete partition objective.')
text(fig,70,29,'Y axes: logarithmic above 0.001, linear from 0 to 0.001. Lower is better; zero requires a verified solution.',11,MUTED)
text(fig,70,11,'5x5: 7/25 clues. 7x7: 13/49 clues. Lines stop at solve/last recorded sample; searches were stopped by the user.',11,MUTED)
renderSVG.drawToFile(fig,str(out/'energy-over-real-time.svg'))

commonfig=Drawing(760,850)
text(commonfig,70,813,'Convergence under the same exact energy',21)
legend(commonfig,782)
for y,size in [(480,5),(100,7)]:
    chart(commonfig,70,y,f'{size} x {size}  -  retained best candidate',series[f'discrete{size}']['common'],series[f'continuous{size}']['common'],
          footer='Same integer clue and shape objective; continuous best boards rescored.',width=600)
text(commonfig,70,35,'Energy: logarithmic above 0.001; linear below. Lower is better.',11,MUTED)
text(commonfig,70,16,'Clues: 7/25 and 13/49. Each line ends at its last saved sample.',11,MUTED)
renderSVG.drawToFile(commonfig,str(out/'common-exact-energy.svg'))

raw=Drawing(1120,440)
text(raw,70,405,'Current candidate energy over real time',21); legend(raw,373)
for col,size in enumerate([5,7]):
    chart(raw,70+560*col,75,f'{size} x {size}  -  native current energy',series[f'discrete{size}']['current'],series[f'continuous{size}']['current'],log=False,
          footer='Current walk includes accepted uphill moves, restarts and imports.')
text(raw,70,12,'Different native objectives; raw oscillations are search behavior, not improvements in retained best.',11,MUTED)
renderSVG.drawToFile(raw,str(out/'current-energy-over-real-time.svg'))

summary=['# Energy curves over real time','',
         'All searches are stopped. X axes use logged elapsed wall-clock seconds, not iterations. Only the final matched-density, uncapped runs are plotted (7/25 and 13/49 clues).','',
         'The top row shows each solver’s retained-best native total energy. Those scores have different definitions. The bottom row uses the same exact partition objective for both: normalized integer clue error weighted by 2, plus invalid-state cell fraction weighted by 1, divided by 3.25. Continuous snapshots are rescored independently. Discrete values are taken from its logged exact scorer and cross-checked where snapshots/checkpoints exist.','',
         '“Retained best” means the board kept by each algorithm’s own ranking, not the running minimum under the shared rescore. Consequently the shared-score continuous curve can increase while its own surrogate score decreases.','',
         '| Run | Last native energy | Last common exact energy | Wrong clues at that candidate | Invalid cell fraction |','|---|---:|---:|---:|---:|']
for job,e in endpoints.items():
    summary.append(f"| {job} | {e['native'][1]:.6f} | {e['common'][1]:.6f} | {e['wrongClues']} | {e['invalidCellFraction']:.3f} |")
summary+=['','![Energy curves](energy-over-real-time.png)','','![Current energies](current-energy-over-real-time.png)','',
          'Curves use recorded events, with steps between observations. Native energies are available at all logged milestones. Continuous shared energies use saved best-board snapshots (roughly every two seconds and at improvements); some final samples differ slightly in timestamp. A solved curve ends at its solution instead of being extended to the end of the other run. There is no extrapolation or fabricated completion time.','',
          '[Raw samples](energy_samples.csv) · [Series and exact-check evidence](energy_samples.json)','']
(out/'REPORT.md').write_text('\n'.join(summary))
print(json.dumps({'endpoints':endpoints,'checks':checks},indent=2))
