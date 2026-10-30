"""Build the final Markdown, offline HTML and vector PDF from analyzed observations.
Run with the bundled Python runtime (ReportLab + pypdf). No queue mutations.
"""
from pathlib import Path
import json,csv,statistics,collections,datetime,math,html,zipfile,hashlib,sys,heapq,shutil
from reportlab.graphics.shapes import Drawing,String,Rect,Line,Circle,PolyLine
from reportlab.graphics.charts.lineplots import LinePlot
from reportlab.graphics.charts.barcharts import HorizontalBarChart
from reportlab.graphics import renderSVG
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet,ParagraphStyle
from reportlab.lib.enums import TA_LEFT,TA_CENTER
from reportlab.platypus import SimpleDocTemplate,Paragraph,Spacer,Table,TableStyle,PageBreak,KeepTogether
from reportlab.lib.pagesizes import A4
NAME='JSP-Oct26-Regional-SA-BP';COPYRIGHT='©2026 ThomasB'
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[3];PDF=REPO/('output/pdf/'+NAME+'-Final-Report.pdf');PDF.parent.mkdir(parents=True,exist_ok=True)
s=json.loads((ROOT/'summary.json').read_text());snap=json.loads((ROOT/'snapshot.json').read_text());records=list(csv.DictReader((ROOT/'energy-at-budgets.csv').open()));recent=json.loads((ROOT/'last-improvements.json').read_text());curve=json.loads((ROOT/'observed-curves.json').read_text())
for r in records:
 for key in ['n','seed','budget']:r[key]=int(r[key])
 for key in ['wrong','residual','commonEnergy','sampleTime']:r[key]=float(r[key])
keys=list(s['perCondition']);names={k:k.replace('-',' / ') for k in keys};palette=['#7f8b9c','#b38a53','#45a29a','#2465d8','#a9a4c2','#b77b9e','#6e86b7','#854dcc'];ink=colors.HexColor('#203047');muted=colors.HexColor('#6a7b92');blue=colors.HexColor('#2465d8');line=colors.HexColor('#e1e7ef');green=colors.HexColor('#16826f')
figures=ROOT/'figures';figures.mkdir(exist_ok=True)
def F(v,d=1):return f'{v:,.{d}f}'
def pct(v):return F(v*100,1)+'%'
def title(d,text,subtitle=None):
 d.add(String(12,d.height-17,text,fontName='Helvetica-Bold',fontSize=11,fillColor=ink));d.add(String(d.width-12,d.height-17,COPYRIGHT,fontName='Helvetica',fontSize=6.5,textAnchor='end',fillColor=muted))
 if subtitle:d.add(String(12,d.height-32,subtitle,fontName='Helvetica',fontSize=8,fillColor=muted))
 return d
def foot(d,text):d.add(String(12,5,text,fontName='Helvetica',fontSize=7,fillColor=muted));return d
def legend(d,labels,cs,y=20):
 for i,(label,c) in enumerate(zip(labels,cs)):
  x=16+(i%4)*118;yy=y-(i//4)*13;d.add(Line(x,yy+2,x+14,yy+2,strokeColor=colors.HexColor(c),strokeWidth=2));d.add(String(x+19,yy,label,fontSize=7,fillColor=ink))
def save(name,d):renderSVG.drawToFile(d,str(figures/(NAME+'-'+name+'.svg')));return d
bars=title(Drawing(480,278),'Validated solves before the 1,200-second cutoff','23 identical board/seed cases per condition; higher is better')
ch=HorizontalBarChart();ch.x=115;ch.y=38;ch.width=280;ch.height=187;ch.data=[[s['perCondition'][k]['solved'] for k in reversed(keys)]];ch.categoryAxis.categoryNames=list(reversed(keys));ch.categoryAxis.labels.fontSize=8;ch.valueAxis.valueMin=0;ch.valueAxis.valueMax=10;ch.valueAxis.valueStep=2;ch.valueAxis.labels.fontSize=8;ch.valueAxis.gridStrokeColor=line;ch.valueAxis.visibleGrid=True;ch.bars[0].fillColor=blue;ch.bars.strokeColor=None;ch.barLabelFormat='%d';ch.barLabels.fontSize=8;ch.barLabels.nudge=8;bars.add(ch);foot(bars,'D = discrete; C = continuous; R = regional; B = new branch-pruning phases.');save('solves',bars)
# A CDF uses validated solve event times, not extended energy traces. Timeouts remain unsolved to the cap.
cdf=title(Drawing(480,285),'Probability of a validated solve by elapsed time','Empirical fraction of the same 23 cases; timeout is not a solve')
plot=LinePlot();plot.x=48;plot.y=80;plot.width=410;plot.height=149;plot.xValueAxis.valueMin=0;plot.xValueAxis.valueMax=1200;plot.xValueAxis.valueStep=300;plot.yValueAxis.valueMin=0;plot.yValueAxis.valueMax=.5;plot.yValueAxis.valueStep=.1;plot.xValueAxis.labels.fontSize=8;plot.yValueAxis.labels.fontSize=8;plot.yValueAxis.visibleGrid=True;plot.yValueAxis.gridStrokeColor=line
plot.data=[]
for k,c in zip(keys,palette):
 times=sorted(j['result']['seconds'] for j in snap['jobs'] if j['status']=='solved' and f"{j['condition']['representation'][0].upper()}-R{int(j['condition']['regional'])}-B{int(j['condition']['newBP'])}"==k);points=[(0,0)]
 for i,t in enumerate(times):points.extend([(t,i/23),(t,(i+1)/23)])
 points.append((1200,len(times)/23));plot.data.append(points)
cdf.add(plot);cdf.add(String(252,52,'Elapsed seconds',fontSize=7.5,textAnchor='middle',fillColor=muted))
for i,c in enumerate(palette):plot.lines[i].strokeColor=colors.HexColor(c);plot.lines[i].strokeWidth=1.4
legend(cdf,keys,palette,36);save('solve-cdf',cdf)
# All eight conditions on all boards, explicitly exposing missing coverage.
heat=title(Drawing(480,396),'Board-by-board solve coverage','Each cell: validated solves / completed trials. Gray cells were never completed.')
x0=91;y0=327;cw=46;rh=19
for col,k in enumerate(keys):heat.add(String(x0+col*cw+cw/2,y0+18,k,fontSize=6.5,textAnchor='middle',fillColor=muted))
for row,b in enumerate(s['boardProfiles']):
 y=y0-row*rh;heat.add(String(13,y+5,b['id'],fontSize=8,fillColor=ink))
 for col,k in enumerate(keys):
  v=b['byCondition'][k];rate=v['solveRate'];fill=colors.HexColor('#f0f2f6') if rate is None else colors.Color(.94-.72*rate,.96-.55*rate,1-.17*rate)
  heat.add(Rect(x0+col*cw,y,cw-2,rh-2,fillColor=fill,strokeColor=None));heat.add(String(x0+col*cw+(cw-2)/2,y+5,'--' if rate is None else f"{v['solved']}/{v['trials']}",fontSize=7,textAnchor='middle',fillColor=ink))
foot(heat,'All methods have matched coverage; the untested n8-b1 prevents an all-board N=8 conclusion.');save('board-heatmap',heat)
# Budget observations: solved before t is a known absorbing zero; no timeout is projected beyond observations.
def trajectory_figure(metric,label,max_y):
 d=title(Drawing(480,260),label,'Only completed 7 x 7 to 9 x 9 cases: 15 matched cases per condition')
 chosen=['D-R0-B0','D-R1-B0','D-R1-B1','C-R1-B1'];cs=[palette[keys.index(k)] for k in chosen];ts=[60,120,300,600,900,1200]
 p=LinePlot();p.x=46;p.y=66;p.width=410;p.height=135;p.xValueAxis.valueMin=0;p.xValueAxis.valueMax=1200;p.xValueAxis.valueStep=300;p.yValueAxis.valueMin=0;p.yValueAxis.valueMax=max_y;p.yValueAxis.valueStep=max_y/4;p.xValueAxis.labels.fontSize=8;p.yValueAxis.labels.fontSize=8;p.yValueAxis.visibleGrid=True;p.yValueAxis.gridStrokeColor=line
 p.data=[[(t,statistics.mean(r[metric] for r in records if r['condition']==k and r['n']>=7 and r['budget']==t)) for t in ts] for k in chosen]
 for i,c in enumerate(cs):p.lines[i].strokeColor=colors.HexColor(c);p.lines[i].strokeWidth=1.8
 d.add(p);d.add(String(252,39,'Elapsed seconds',fontSize=7.5,textAnchor='middle',fillColor=muted));legend(d,chosen,cs,22);save('large-'+metric,d);return d
wrongfig=trajectory_figure('wrong','Mean incorrect clues over real elapsed seconds',8)
energyfig=trajectory_figure('commonEnergy','Mean common exact energy over real elapsed seconds',.2)
# An actual recorded curve panel: no prolongation after last sample.
actual=title(Drawing(480,267),'One matched 5 x 5 case: actual recorded energy','n5-b2, seed 20261029. Lines end at each run\'s last observation.')
p=LinePlot();p.x=46;p.y=80;p.width=410;p.height=131;p.xValueAxis.valueMin=0;p.xValueAxis.valueMax=1200;p.xValueAxis.valueStep=300;p.yValueAxis.valueMin=0;p.yValueAxis.valueMax=.5;p.yValueAxis.valueStep=.1;p.xValueAxis.labels.fontSize=8;p.yValueAxis.labels.fontSize=8;p.yValueAxis.visibleGrid=True;p.yValueAxis.gridStrokeColor=line;p.data=[]
for k in keys:
 js=[j for j in snap['jobs'] if j['board_id']=='n5-b2' and j['seed']==20261029 and j['status'] in ('solved','timeout') and f"{j['condition']['representation'][0].upper()}-R{int(j['condition']['regional'])}-B{int(j['condition']['newBP'])}"==k]
 assert len(js)==1
 data=curve[js[0]['id']];points=[(r['seconds'],r['commonEnergy']) for r in data];p.data.append(points)
for i,c in enumerate(palette):p.lines[i].strokeColor=colors.HexColor(c);p.lines[i].strokeWidth=1
actual.add(p);actual.add(String(252,52,'Elapsed seconds',fontSize=7.5,textAnchor='middle',fillColor=muted));legend(actual,keys,palette,35);save('actual-curves',actual)
# The challenged 19 cell, traced from actual result labels and independently computed capitals.
case=next(j for j in snap['jobs'] if j['id']=='n5-b2-continuous-r0-b0-s20261029');board=next(b for b in snap['boards'] if b['id']=='n5-b2');labels=sum(case['result']['labels'],[]);clues=board['puzzle']['clues'];casefig=title(Drawing(480,284),'Validation audit: why the clue 19 is correct','Actual saved solved partition; dots identify capitals, letters identify regions.')
# Recompute capital positions and integer distances for this diagram, rather than copying printed clues.
groups=collections.defaultdict(list)
for i,label in enumerate(labels):groups[label].append(i)
caps=[];sizes=[len(groups[label]) for label in labels]
for cells in groups.values():
 sr=min(c//5 for c in cells)+max(c//5 for c in cells);sc=min(c%5 for c in cells)+max(c%5 for c in cells);xy=[(2*(c//5)-sr,2*(c%5)-sc) for c in cells];fixed=[]
 for t in range(7):
  mapped=[[(b,-a),(-a,-b),(-b,a),(a,-b),(-a,b),(b,a),(-b,-a)][t] for a,b in xy]
  if set(mapped)==set(xy):fixed.append({c for c,a,b in zip(cells,xy,mapped) if a==b})
 if fixed and len(fixed[0])==1 and all(x==fixed[0] for x in fixed):caps.extend(fixed[0])
dist=[10**9]*25;prev={};heap=[]
for c in caps:dist[c]=0;heapq.heappush(heap,(0,c))
while heap:
 value,c=heapq.heappop(heap)
 if value!=dist[c]:continue
 r,cx=divmod(c,5)
 for v in [c-5 if r else -1,c+5 if r<4 else -1,c-1 if cx else -1,c+1 if cx<4 else -1]:
  if v<0:continue
  candidate=value+min(sizes[c],sizes[v])
  if candidate<dist[v]:dist[v]=candidate;prev[v]=c;heapq.heappush(heap,(candidate,v))
assert dist[0]==19 and all(dist[i]==value for i,value in enumerate(clues) if value>=0)
(ROOT/'nineteen-audit.json').write_text(json.dumps({'job':case['id'],'labels':case['result']['labels'],'capitals':caps,'sizes':sizes,'distances':dist,'route':[0,5,10,15],'edgeCosts':[9,9,1]},indent=2))
cell=36;gx=24;gy=55;fills=['#dce6ff','#dff1e8','#fff0d8','#e7dffa','#dff0fa','#f7dfe6']
for i,label in enumerate(labels):
 r,c=divmod(i,5);x=gx+c*cell;y=gy+(4-r)*cell;casefig.add(Rect(x,y,cell,cell,fillColor=colors.HexColor(fills[label]),strokeColor=colors.HexColor('#bdc9da'),strokeWidth=.6));casefig.add(String(x+4,y+cell-9,chr(65+label),fontSize=6,fillColor=muted))
 if clues[i]>=0:casefig.add(String(x+cell/2,y+cell/2-3,str(clues[i]),fontSize=10,textAnchor='middle',fillColor=ink))
 if i in caps:casefig.add(Circle(x+cell-7,y+7,3,fillColor=ink,strokeColor=None))
for a,b,cost in [(0,5,9),(5,10,9),(10,15,1)]:
 x=gx+7;y1=gy+(4-a//5)*cell+10;y2=gy+(4-b//5)*cell+10;casefig.add(Line(x,y1,x,y2,strokeColor=blue,strokeWidth=1.8));casefig.add(Line(x,y2,x-3,y2+5,strokeColor=blue,strokeWidth=1.3));casefig.add(Line(x,y2,x+3,y2+5,strokeColor=blue,strokeWidth=1.3))
for i,text in enumerate(['A: 9 cells, no capital','B: 3 cells, capital r1c5','C: 3 cells, capital r3c4','D: 1 cell, capital r4c1','E: 8 cells, no capital','F: 1 cell, capital r5c1']):casefig.add(String(226,225-i*17,text,fontSize=8.5,fillColor=ink))
casefig.add(String(226,103,'r1c1 -> r2c1 -> r3c1 -> r4c1',fontSize=8,fillColor=blue));casefig.add(String(226,79,'9 + 9 + min(9, 1) = 19',fontName='Helvetica-Bold',fontSize=13,fillColor=blue));foot(casefig,'After two moves (18) the route is still inside A. One more move reaches the singleton capital.');save('nineteen-audit',casefig)
# Static fixture appendix: clues only, no planted solution given to any timed worker.
def fixture_page(bs,index):
 d=title(Drawing(480,590),f'Frozen puzzle fixtures - page {index}','Numbers are the exact input clues; blank cells are unnumbered.')
 for at,b in enumerate(bs):
  col=at%3;row=at//3;x=col*158+6;y=390-row*185;n=b['n'];size=137/n
  d.add(String(x,y+151,b['id'],fontName='Helvetica-Bold',fontSize=9,fillColor=ink));d.add(String(x,y+139,f"{sum(v>=0 for v in b['puzzle']['clues'])} clues; "+('unique proven' if b['solution_count']==1 else 'exact count unknown'),fontSize=7,fillColor=muted))
  for i,v in enumerate(b['puzzle']['clues']):
   r,c=divmod(i,n);xx=x+c*size;yy=y+(n-1-r)*size-7;d.add(Rect(xx,yy,size,size,fillColor=colors.white,strokeColor=line,strokeWidth=.5))
   if v>=0:d.add(String(xx+size/2,yy+size/2-2.5,str(v),textAnchor='middle',fontSize=8,fillColor=ink))
 save('fixtures-'+str(index),d);return d
fixturefigs=[fixture_page(snap['boards'][:9],1),fixture_page(snap['boards'][9:],2)]
# Shared report content blocks, rendered consistently to Markdown, HTML and PDF.
pages=[]
def page(title,kicker='FINAL EXPERIMENT REPORT'):
 p={'title':title,'kicker':NAME+' / '+kicker,'blocks':[]};pages.append(p);return p['blocks']
def para(blocks,text):blocks.append(('p',text))
def table(blocks,headers,rows,widths=None):blocks.append(('table',(headers,rows,widths)))
def fig(blocks,name,caption):blocks.append(('fig',(name,caption)))
def heading(blocks,text):blocks.append(('h',text))
B=page('Regional search + branch pruning is the leading direction')
para(B,'Stopped at user request on <b>30 October 2026, 12:07 JST</b>. Campaign 20261029-214421. The experiment is stopped early, not completed: <b>184 of 360 trials finished</b>, with 39 validated solves and 145 timeouts. No workers remain active. The queue retains 176 uncompleted jobs; 172 never started and four have only an interrupted final attempt.')
para(B,'<b>Decision:</b> use discrete regional SA + new BP as the experimental baseline, keep continuous regional + BP as a challenger, and focus development on completing larger puzzles. The results support a search family, not a claim of a reliable fresh-start 11 x 11 solver or superiority over current production.')
table(B,['Condition','Solved / 23','Rate','Capped time'],[[k,f"{v['solved']}/23",pct(v['solveRate']),F(v['cappedCost'])+' s'] for k,v in s['perCondition'].items()],[110,100,95,150])
para(B,'D/C = discrete/continuous; R0/R1 = regional off/on; B0/B1 = new BP phases off/on. Every row faced the <b>same 23 board/seed cases</b>. Capped time is mean observed solve time, with an unsolved full trial counted as 1,200 seconds. It is not predicted eventual solve time.')
heading(B,'What is established')
para(B,'Regional search and new BP each improve outcomes in matched comparisons. D-R1-B1 leads with <b>9/23 solves</b> and <b>828.7 s</b> capped cost; C-R1-B1 reaches 7/23 and 939.9 s. Across all settings, however, continuous solves 20/92 and discrete 19/92, so representation alone remains unsettled.')
para(B,'The main limitation is scale: only <b>3 of 120 completed trials at N=7 to 9 solved</b>. All 184 final partitions are structurally valid, so those failures are clue-distance failures. Three generated fixtures are now definitely non-unique, including the sole successful N=9 board. The user-questioned 19 clue is correct: <b>9 + 9 + 1</b>; the capital is outside the 9-cell square.')
B=page('What was measured, and what stopped early')
para(B,'The shared Swift framework tests all eight combinations of representation, regional policy and extra BP phases. There are three fixed boards for each N=5,6,7,8,9 and three matched seeds per board: 20261029, 20261030 and 20261031. Clue counts are 7, 10, 13, 17 and 22, matching round(N*N*33/121). Each search receives one synchronous CPU thread, no GPU, and a 1,200-second wall-clock cap. Four searches run concurrently.')
para(B,'The initial preparation policy required one to three proven partitions per board. At the user\'s request it was amended to use the current puzzles without waiting for uniqueness. Every fixture has an independently checked saved solution, but <b>saved solutions were never passed to timed workers</b>. Only the three N=5 boards retain proven unique counts.')
table(B,['Size','Completed','Solved','Full matched blocks'],[[n+' x '+n,str(v['trials']),str(v['solved']),str(v['trials']//8)+' / 9'] for n,v in s['perSize'].items()],[110,105,105,135])
para(B,'There are <b>23 complete eight-condition blocks</b> across 14 distinct boards. Every completed trial is in a complete block, so the primary comparison has no incomplete-condition imbalance. n8-b1 has no completed trial; the study cannot make an all-three-board N=8 claim. Some boards have three completed seeds, others one or two.')
para(B,'The queue was explicitly paused and resumed once, then stopped for this report. Eight interrupted attempts are excluded from solve-rate and capped-cost denominators. The first four interrupted jobs were rerun as fresh attempts and eventually timed out; the final four remain uncompleted. Their observed effort is preserved separately. An interrupted run is neither a 1,200-second timeout nor an eventual solve.')
heading(B,'Data integrity checks')
para(B,'A separate Python integer-rule implementation rechecked <b>all 184 final candidates</b>, including connectivity, all grid symmetries, capital definitions, shortest-path distances, clue mismatches and answers. All results agree with the recorded Swift outcomes. All 15 known fixture solutions passed. The eight-condition initial quality/native energy was identical, with zero initial discreteness, in all 23 matched blocks. Worker binaries and the permanent shape database still match their recorded SHA-256 hashes. No infrastructure-failed trial exists.')
B=page('Matched effects support regional search and extra BP')
fig(B,'solve-cdf','Solve events are absorbing outcomes. Timeouts remain unsolved through the cap; this is not extrapolation of an energy curve.')
table(B,['Paired change','Pairs','Cost difference','Exploratory 95% interval'],[[label,str(s['pairedEffects'][key]['pairs']),F(s['pairedEffects'][key]['meanCostDifference'])+' s','['+F(s['pairedEffects'][key]['costCI95'][0])+', '+F(s['pairedEffects'][key]['costCI95'][1])+'] s'] for label,key in [('Continuous - discrete','continuous_minus_discrete'),('Regional on - off','regional_on_minus_off'),('New BP on - off','newBP_on_minus_off'),('D hybrid - C hybrid','D_hybrid_minus_C_hybrid')]],[137,42,102,174])
para(B,'Negative cost difference favors the first named change. Intervals use <b>10,000 board-cluster bootstrap resamples</b>, retaining all observed seeds and condition comparisons within each sampled board. There are only 14 observed board clusters. These are descriptive sensitivity intervals, not multiplicity-adjusted confirmatory tests or a random sample of all puzzles.')
para(B,'Regional-on solves 25/92 versus 14/92 off: 12 pairs add a solve and one loses a solve. New-BP-on solves 24/92 versus 15/92 off: 10 pairs add a solve and one loses one. Representation has six continuous-only solves versus five discrete-only solves. D versus C within regional BP has only four discordant solve pairs (three D-only, one C-only), so its solve-rate distinction is fragile despite the capped-cost lead.')
para(B,'Regional benefit in capped cost is larger with BP than without it: the matched difference-of-differences is '+F(s['interactionCostDifference'])+' s. This is consistent with complementary roles, but does not isolate a mechanism. Equal-board weighting also retains the D-hybrid lead; it is a sensitivity check on the same evidence, not another independent experiment.')
B=page('Difficulty varies sharply by board')
fig(B,'board-heatmap','The same board and seed coverage is available to every condition. Each entry is solves / valid completed attempts.')
para(B,'N=5 has 29/40 solves, N=6 has 7/24, N=7 has 2/48, N=8 has 0/24, and N=9 has 1/48. These size totals mix conditions and repeat seeds, so they describe this workload rather than a population-level scaling law. The provisional D-hybrid solves 1/6 at N=7, 0/3 at N=8 and 1/6 at N=9.')
para(B,'Board effects are substantial even at N=5: n5-b2 was solved by every method in its one completed seed block; n5-b3 was solved only by the two regional+BP methods in its one completed block. The three N=5 boards have different known structures despite identical clue counts.')
para(B,'The clue-density rule alone does not match the original puzzle\'s distribution of regions, capitals or difficulty. The planted N=9 witnesses have largest regions of only 11-13 cells, although some bounding boxes exceed the seed-cache area of 16. Failure therefore cannot be explained solely by absence of very large planted regions. Conversely, the one N=9 solve occurs on a board whose planted witness has a 24-cell bounding box, so an incomplete materialized seed cache is not automatically a barrier to every solve.')
B=page('Late improvement is real, but is not a solved puzzle')
fig(B,'large-wrong','Budget summaries use the last actual sample at or before each time. A validated earlier solve contributes known zero error afterward.')
fig(B,'large-commonEnergy','Common exact energy excludes the representation-dependent discreteness term. Individual energy traces can rise when wrong-clue count improves.')
para(B,'Among unsolved N=7-9 trials, 38/57 with BP improved exact quality after 600 seconds versus 19/60 without BP. Median last observed improvement was 859.2 s with BP and 418.0 s without it. Only 31 of all 39 successes arrived by 600 s; four more arrived by 900 s and four afterward. The sole N=9 solve took 1,163.9 s. Shortening the cap would discard observed successes, even though most large-board runs still fail.')
B=page('What the BP and resource counters do - and do not - show')
fig(B,'actual-curves','This example uses actual timestamps and all recorded energy observations, with no extension of a stopped curve to 1,200 seconds.')
r=s['resource'];table(B,['Measured quantity','Value'],[['Completed search CPU effort',F(r['terminalCPUHours'],2)+' core-hours'],['Completed search wall effort (sum over workers)',F(r['terminalWallHours'],2)+' worker-hours'],['Interrupted sampled CPU effort',F(r['interruptedSampledCPUHours'],2)+' core-hours'],['Aggregate CPU / wall',pct(r['cpuWallRatio'])],['Per-trial CPU / wall range',pct(r['cpuWallMin'])+' to '+pct(r['cpuWallMax'])],['Peak observed per-worker memory',F(r['memoryMaxBytes']/1048576,1)+' MiB'],['New BP phases / source improvements',f"{r['bpPhases']:,} / {r['bpSourceImprovements']:,}"],['New BP nodes',f"{r['bpNodes']:,}"],['New BP wall share in B1 trials',pct(r['bpTimeShare'])]],[310,145])
para(B,'A nominal one-second BP allowance does not mean a full second is consumed. Actual BP totals '+F(r['bpSeconds']/60,1)+' minutes across '+F(r['bpEnabledWallSeconds']/3600,2)+' B1 worker-hours. The source-improvement counter can improve the current state without improving the global incumbent. Global gain per CPU second is not logged directly. Catalog, ordinary cover and BP times overlap; do not add them.')
para(B,'The CPU counters are consistent with one hot search thread per process. macOS P-core pinning is not guaranteed, and other activity/thermal conditions are uncontrolled. The resource totals exclude preparation, queue/dashboard overhead and report generation. Iteration throughput is not the solve-speed metric. Increasing every BP allowance is a hypothesis to test, not a measured fix.')
B=page('The 19 clue: an explicit rule audit')
fig(B,'nineteen-audit','Saved candidate n5-b2-continuous-r0-b0-s20261029; solved at 403.521 s, with answer 5,445.')
para(B,'The 9-cell blue 3 x 3 region has no capital. Its rotations fix its center, but each reflection fixes three cells. The rule requires <b>every nontrivial symmetry to fix exactly one square</b>, so the center does not qualify. The 8-cell rectangle also has no capital. The other four regions have capitals marked by dots above.')
para(B,'The shortest route from the top-left 19 cell is r1c1 -> r2c1 -> r3c1 -> r4c1. Two moves inside the 9-cell region cost 9 each. After those moves, at cost 18, the traveler is still in that region. The third move enters the singleton capital and costs min(9,1)=1. Thus the clue is <b>19, not 18</b>. Independent multi-source Dijkstra confirms this is the minimum over all four capitals, not merely the cost of one available route.')
table(B,['Clue cell','Printed distance','Independently calculated'],[[f'r{i//5+1}c{i%5+1}',str(v),str(dist[i])] for i,v in enumerate(clues) if v>=0],[130,145,180])
para(B,'The dashboard previously showed region colors and clues without marking capitals. That visualization makes this rule easy to misread; colors can also repeat when there are more than ten regions. The evaluator uses actual labels, not colors. Report diagrams explicitly mark capitals and region identities. A capital overlay is a useful UI improvement, independent of the solver comparison.')
B=page('Unknown uniqueness and limits on the conclusions')
table(B,['Board','Distinct solved partitions seen','Distinct valid answers seen'],[[p['id'],str(p['observedDistinctSolvedPartitions']),', '.join(f'{x:,}' for x in p['observedAnswers']) or '--'] for p in s['boardProfiles'] if p['solved']],[110,145,200])
para(B,'All three 5 x 5 fixtures have independently checked solutions and exhaustive unique-partition certificates. Exact counts remain unknown for the other twelve fixtures. The experiment itself proves timed-search lower bounds for two of them: <b>n6-b3 has at least four distinct valid partitions and four answers</b> (2,880; 2,984; 3,080; 3,642), while <b>n7-b3 has at least two</b> (11,219; 13,841). Adding the independently validated planted witnesses raises the known lower bounds to <b>five partitions/answers for n6-b3</b> (also 4,040), and <b>three for n7-b3</b> (also 14,237). n9-b2 also has at least two known partitions and answers: the timed solve gives 13,653 while its validated planted witness gives 26,821. All three N=7-9 timed successes differ from their planted witnesses. These are genuine clue-compatible solutions, not invalid successes; their full solution sets are still uncounted.')
para(B,'This matters for the original goal: a solver that succeeds on an underconstrained generated board may have found an alternative state layout, while the real puzzle may demand a specific unique layout. The original few-solution objective was waived before trials. The result remains a matched heuristic comparison on these fixed clues, but the large-board successes all came from demonstrably ambiguous fixtures and provide weaker evidence for performance on a unique real puzzle. A later held-out study should control this property where feasible without spending the entire budget proving uniqueness.')
heading(B,'Other interpretation limits')
para(B,'Continuous and discrete arms differ in perturbation behavior and a continuous-only discreteness penalty, not just storage type. Regional-on bundles focus selection with perturbation width. B0 already contains ordinary bounded branching repairs; B1 adds a whole intensification policy, so it does not isolate the pruning bound alone. Finite time slices and discovery order make theoretical full shape-domain coverage different from completed enumeration. The frozen experiment is not today\'s richer production search. No fresh 11 x 11 solve was tested in this campaign.')
para(B,'Stopping was informed by interim results. The reported best condition is selected after inspecting eight arms, and repeats of the same boards do not replace independent held-out puzzles. Fixed-seed trials can still diverge with wall-clock timing. Bootstrap intervals, ranking and subgroup findings are exploratory. An energy decrease is neither a certificate of closeness to a unique partition nor an estimate of remaining solve time.')
B=page('Recommended next step and reproducibility')
heading(B,'A focused completion experiment')
para(B,'<b>1. Freeze this dataset.</b> Do not silently pool future solver versions or warm-start trials into these results. The current experiment is stopped; no new search has been started for this report. Retain D-R1-B1 as the frozen experimental baseline and C-R1-B1 as a challenger.')
para(B,'<b>2. Diagnose productive repair before increasing its allowance.</b> Log patch size, fixed exterior compatibility, full exhaustion versus time slicing, discovery work and global incumbent gain per CPU second. Compare one coherent repair change at a time: persistence of compatible prefixes, targeted patches along persistently wrong-clue routes, or adaptive size/budget. The existing four-percent BP share and late gains justify this investigation, but do not identify the best change.')
para(B,'<b>3. Test scale and the actual goal early.</b> Use matched fresh seeds on N=7-9, including the previously untested n8-b1. Add fresh-start 11 x 11 pilot trials and a resource-controlled comparison with current production. Production already has richer archives, growth, deductions and objective rotation. Keep any solver-produced warm-start finishing diagnostic separate from end-to-end solve time. Verified solution fixtures may support offline rule/reachability checks, never timed initialization or cache prewarming.')
para(B,'<b>4. Prespecify the decision.</b> Keep the 1,200-second cap for comparability and late successes. Primary endpoints are validated solve fraction and capped solve cost. Track common energy, wrong clues and useful repairs as explanatory metrics. Set a finite budget and held-out validation boards before launching. Do not infer the 11 x 11 solve rate from these N=5-9 observations.')
heading(B,'Reproducible evidence package')
para(B,'The accompanying folder contains the immutable final snapshot, all 184 completed trial rows, eight interrupted-attempt records, fixed-budget energy observations, actual timestamped curves, every fixture and validation record, paired/cluster-bootstrap summaries and source scripts. The bootstrap seed is 20261030 with 10,000 board-level resamples. Individual curves stop at their last actual sample; aggregate solve fractions use observed event times.')
para(B,'All final candidates and known fixture solutions passed the independent checker. Binary and shape-store hashes match the campaign manifest. Full hashes are recorded in audit.json. The original queue and SQLite database remain in Application Support outside iCloud and were not replaced. The stopped dashboard can still inspect historical data. Source code and raw data paths are local; the offline HTML report and PDF require no running server.')
para(B,'Rebuild the analysis with <font face="Courier">python analyze.py snapshot.json OUTPUT</font> (the snapshot folder includes portable observation fallbacks); then use the bundled Python runtime to run <font face="Courier">build_report.py</font> after placing the analysis files beside it. The report is a terminal snapshot at 12:07 JST and supersedes the interim 11:31 assessment.')
for i in range(2):
 B=page('Frozen board inputs - appendix '+str(i+1),'FIXTURE APPENDIX');fig(B,'fixtures-'+str(i+1),'Clues are unchanged across all eight conditions and all matched seeds. Saved witnesses were withheld from timed workers.');para(B,'A unique label means an exhaustive certificate already existed before timed search. "Exact count unknown" is not a claim of uniqueness. Observed multiple solutions are detailed in the preceding analysis.')
# Render PDF with explicit page boundaries and consistent running furniture.
styles=getSampleStyleSheet();styles.add(ParagraphStyle(name='ReportBody',fontName='Helvetica',fontSize=9.1,leading=12.4,textColor=ink,spaceAfter=9));styles.add(ParagraphStyle(name='ReportH',fontName='Helvetica-Bold',fontSize=11.4,leading=14,textColor=blue,spaceBefore=8,spaceAfter=8));styles.add(ParagraphStyle(name='ReportTitle',fontName='Helvetica-Bold',fontSize=22,leading=26,textColor=ink,spaceAfter=16));styles.add(ParagraphStyle(name='ReportCaption',fontName='Helvetica',fontSize=7.4,leading=10,textColor=muted,spaceAfter=9));styles.add(ParagraphStyle(name='Cell',fontName='Helvetica',fontSize=8,leading=10,textColor=ink));styles.add(ParagraphStyle(name='CellHead',fontName='Helvetica-Bold',fontSize=7.6,leading=10,textColor=muted))
figmap={'solves':bars,'solve-cdf':cdf,'board-heatmap':heat,'large-wrong':wrongfig,'large-commonEnergy':energyfig,'actual-curves':actual,'nineteen-audit':casefig,'fixtures-1':fixturefigs[0],'fixtures-2':fixturefigs[1]}
story=[]
for i,page in enumerate(pages):
 if i:story.append(PageBreak())
 story.append(Paragraph(page['kicker'],styles['ReportCaption']));story.append(Paragraph(page['title'],styles['ReportTitle']))
 for typ,val in page['blocks']:
  if typ=='p':story.append(Paragraph(val,styles['ReportBody']))
  elif typ=='h':story.append(Paragraph(val,styles['ReportH']))
  elif typ=='fig':
   name,caption=val;story.extend([figmap[name],Paragraph(caption,styles['ReportCaption'])])
  elif typ=='table':
   headers,rows,widths=val;data=[[Paragraph(html.escape(str(x)),styles['CellHead']) for x in headers]]+[[Paragraph(html.escape(str(x)),styles['Cell']) for x in row] for row in rows];t=Table(data,colWidths=widths,repeatRows=1,hAlign='LEFT');t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),colors.HexColor('#edf2fa')),('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),7),('RIGHTPADDING',(0,0),(-1,-1),7),('TOPPADDING',(0,0),(-1,-1),6),('BOTTOMPADDING',(0,0),(-1,-1),6),('LINEBELOW',(0,0),(-1,0),.5,line),('ROWBACKGROUNDS',(0,1),(-1,-1),[colors.white,colors.HexColor('#f8fafd')]) ]));story.extend([t,Spacer(1,10)])
def furniture(c,doc):
 c.setStrokeColor(line);c.line(42,39,A4[0]-42,39);c.setFont('Helvetica',7);c.setFillColor(muted);c.drawString(42,27,NAME+'  |  '+COPYRIGHT);c.drawRightString(A4[0]-42,27,str(doc.page))
doc=SimpleDocTemplate(str(PDF),pagesize=A4,rightMargin=42,leftMargin=42,topMargin=39,bottomMargin=52,title=NAME+'-Final-Report',author='ThomasB',pageCompression=1);doc.build(story,onFirstPage=furniture,onLaterPages=furniture)
# Markdown and a self-contained offline HTML with all vector charts embedded.
import re
def plain(t):return re.sub('<[^>]+>','',t).replace('&gt;','>').replace('&lt;','<').replace('&amp;','&')
md=['# '+NAME+'-Final-Report',COPYRIGHT+'\n','Stopped 2026-10-30 at 12:07 JST.\n'];body=[]
for page in pages:
 md.append('## '+page['title']+'\n');parts=['<section><div class="kicker">'+html.escape(page['kicker'])+'</div><h2>'+html.escape(page['title'])+'</h2>']
 for typ,val in page['blocks']:
  if typ=='p':md.append(plain(val)+'\n');parts.append('<p>'+val+'</p>')
  elif typ=='h':md.append('### '+val+'\n');parts.append('<h3>'+val+'</h3>')
  elif typ=='table':
   headers,rows,_=val;md.append('| '+' | '.join(headers)+' |');md.append('|'+'|'.join(['---']*len(headers))+'|');md.extend('| '+' | '.join(map(str,row))+' |' for row in rows);md.append('');parts.append('<div class="table"><table><thead><tr>'+''.join('<th>'+html.escape(str(x))+'</th>' for x in headers)+'</tr></thead><tbody>'+''.join('<tr>'+''.join('<td>'+html.escape(str(x))+'</td>' for x in row)+'</tr>' for row in rows)+'</tbody></table></div>')
  elif typ=='fig':
   name,caption=val;md.extend(['!['+caption+'](figures/'+NAME+'-'+name+'.svg)','',caption+'\n']);svg=(figures/(NAME+'-'+name+'.svg')).read_text();svg=svg[svg.index('<svg'):];parts.append('<figure>'+svg+'<figcaption>'+html.escape(caption)+'</figcaption></figure>')
 parts.append('</section>');body.append(''.join(parts))
(ROOT/(NAME+'-Final-Report.md')).write_text('\n'.join(md));css='''body{margin:0;background:#f4f7fb;color:#203047;font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}main{max-width:980px;margin:40px auto;padding:0 24px}header{padding:35px 0}h1{font-size:40px;letter-spacing:-1.4px;line-height:1.2}h2{font-size:27px;letter-spacing:-.7px;line-height:1.3}h3{font-size:18px;color:#2465d8}.kicker{font-size:11px;letter-spacing:2px;color:#2465d8;font-weight:700}section{background:white;padding:36px;border:1px solid #e1e7ef;border-radius:16px;margin:24px 0}p{font-size:15px}table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:left;padding:12px;border-bottom:1px solid #e1e7ef}th{color:#6a7b92;background:#f2f6fc}tr:nth-child(even){background:#fafcff}.table{overflow:auto}figure{margin:24px 0}svg{width:100%;height:auto}figcaption{color:#6a7b92;font-size:12px}a{color:#2465d8}code{font-size:12px}@media(max-width:600px){main{padding:0 12px}section{padding:20px}h1{font-size:30px}h2{font-size:22px}}@media print{body{background:white}section{border:0;padding:0;break-before:page}header{display:none}}'''
(ROOT/(NAME+'-Final-Report.html')).write_text('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+NAME+'-Final-Report</title><style>'+css+'</style></head><body><main><header><div class="kicker">'+NAME+' / FINAL INVESTIGATION</div><h1>'+NAME+'<br>Final investigation</h1><p>Stopped 30 October 2026, 12:07 JST · 184 completed trials · 23 matched comparisons · 14 boards</p><p><a href="'+NAME+'-Final-Report.md">Markdown report</a> · <a href="'+NAME+'-completed-trials.csv">Completed trial data</a> · <a href="'+NAME+'-summary.json">Analysis summary</a></p></header>'+''.join(body)+'<footer>'+COPYRIGHT+'</footer></main></body></html>')
# Public export names carry the experiment identity; immutable machine inputs retain their schema.
for path in list(ROOT.iterdir()):
 if path.is_file() and path.suffix in ('.csv','.json') and not path.name.startswith(NAME):shutil.copy2(path,ROOT/(NAME+'-'+path.name))
manifest={'experiment':NAME,'copyright':COPYRIGHT,'author':'ThomasB','publicExports':[p.name for p in ROOT.iterdir() if p.is_file() and p.name.startswith(NAME)],'preservedMachineInputs':'Original raw filenames and durable IDs retained for reproducibility.'}
(ROOT/(NAME+'-Publication-Manifest.json')).write_text(json.dumps(manifest,indent=2,ensure_ascii=False))
# The bundle itself is branded; its internal machine input names remain runnable.
with zipfile.ZipFile(ROOT/(NAME+'-Evidence.zip'),'w',zipfile.ZIP_DEFLATED) as z:
 for path in ROOT.rglob('*'):
  if path.is_file() and path.suffix!='.zip' and '__pycache__' not in path.parts:z.write(path,str(Path(NAME)/path.relative_to(ROOT)))
 z.write(PDF,NAME+'/'+PDF.name)
from pypdf import PdfReader
reader=PdfReader(str(PDF));print(json.dumps({'pdf':str(PDF),'pages':len(reader.pages),'sectionCount':len(pages),'report':str(ROOT/(NAME+'-Final-Report.md')),'html':str(ROOT/(NAME+'-Final-Report.html')),'bundleBytes':(ROOT/(NAME+'-Evidence.zip')).stat().st_size},indent=2))
