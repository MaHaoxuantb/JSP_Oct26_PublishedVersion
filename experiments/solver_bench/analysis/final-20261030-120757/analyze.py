"""Reproduce the stopped-campaign assessment from an immutable JSON snapshot.
Usage: python analyze.py SNAPSHOT.json OUTPUT_DIRECTORY
Reads observed run files. Does not contact or mutate the queue or any solver.
"""
import json,pathlib,collections,statistics,math,random,csv,hashlib,sys,datetime
BASE=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(BASE))
from benchqueue.validation import evaluate,validate_fixture,canonical_partition,puzzle_orbit_key
snapshot=pathlib.Path(sys.argv[1]);cached_curves=json.loads((snapshot.parent/'observed-curves.json').read_text()) if (snapshot.parent/'observed-curves.json').exists() else {};cached_partial=json.loads((snapshot.parent/'interrupted-observations.json').read_text()) if (snapshot.parent/'interrupted-observations.json').exists() else {};partial_cache={};out=pathlib.Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True);s=json.loads(snapshot.read_text());jobs=s['jobs'];terminal=[j for j in jobs if j['status'] in ('solved','timeout')]
keys=[(d,r,b) for d in ['discrete','continuous'] for r in [False,True] for b in [False,True]]
def key(j):c=j['condition'];return(c['representation'],c['regional'],c['newBP'])
def name(k):return f"{k[0][0].upper()}-R{int(k[1])}-B{int(k[2])}"
def cost(j):return min(j['result']['seconds'],1200) if j['status']=='solved' else 1200
blocks=collections.defaultdict(list)
for j in terminal:blocks[(j['board_id'],j['seed'])].append(j)
complete={b:js for b,js in blocks.items() if len(js)==8 and len({key(j) for j in js})==8};matched=[j for js in complete.values() for j in js]
assert len(matched)==len(terminal),'Unexpected partial terminal blocks: adapt primary analysis before use'
boards={b['id']:b for b in s['boards']};audit=[];proofs=[]
for b in s['boards']:proofs.append({'board':b['id'],**validate_fixture(b['certificate'],True)})
for j in terminal:
 b=boards[j['board_id']];r=j['result'];v=evaluate(r['labels'],b['n'],b['puzzle']['clues']);q=r['quality']
 assert v['solved']==r['solved'] and v['wrong']==q['wrong'] and v['issues']==q['issues'] and abs(v['residual']-q['residual'])<1e-12 and v['answer']==r.get('answer'),j['id']
 assert (j['status']=='solved')==v['solved'];assert r['condition']==j['condition'] and r['jobID']==j['id'] and r['seed']==j['seed']
 assert r['singleThreaded'] and not r['gpuEnabled'];assert r['cpuSeconds']<=r['seconds']*1.15+.15
 if j['status']=='timeout':assert 1200<=r['seconds']<=1205
 if key(j)[0]=='discrete':assert all(x in (0,1) for x in r['strengths'])
 audit.append({'job':j['id'],**v})
def summarize(js):
 solved=[j for j in js if j['status']=='solved'];times=sorted(j['result']['seconds'] for j in solved)
 return dict(trials=len(js),solved=len(solved),solveRate=len(solved)/len(js) if js else None,cappedCost=statistics.mean(map(cost,js)) if js else None,solvedMedian=statistics.median(times) if times else None,wrong=statistics.mean(j['result']['quality']['wrong'] for j in js) if js else None,residual=statistics.mean(j['result']['quality']['residual'] for j in js) if js else None,issues=sum(j['result']['quality']['issues'] for j in js),cpuSeconds=sum(j['result']['cpuSeconds'] for j in js),wallSeconds=sum(j['result']['seconds'] for j in js))
condition={name(k):summarize([j for j in matched if key(j)==k]) for k in keys};by_size={str(n):summarize([j for j in terminal if boards[j['board_id']]['n']==n]) for n in range(5,10)}
by_size_condition={str(n):{name(k):summarize([j for j in matched if boards[j['board_id']]['n']==n and key(j)==k]) for k in keys} for n in range(5,10)}
represented=sorted({j['board_id'] for j in matched});byboardblocks=collections.defaultdict(list)
for b,js in complete.items():byboardblocks[b[0]].append(js)
# Cluster bootstrap resamples observed boards and retains every completed seed and factor comparison within each board.
# CIs are descriptive empirical-board uncertainty, not calibrated evidence for a broader puzzle population.
rng=random.Random(20261030)
def percentile(xs,p):
 ys=sorted(xs);at=(len(ys)-1)*p;i=int(at);return ys[i]+(ys[min(i+1,len(ys)-1)]-ys[i])*(at-i)
def effect(pairs):
 ds=[cost(b)-cost(a) for a,b in pairs];ss=[int(b['status']=='solved')-int(a['status']=='solved') for a,b in pairs]
 perboard=collections.defaultdict(list)
 for a,b in pairs:perboard[a['board_id']].append((cost(b)-cost(a),int(b['status']=='solved')-int(a['status']=='solved')))
 names=sorted(perboard);bootcost=[];bootsolve=[]
 for _ in range(10000):
  selected=[perboard[names[rng.randrange(len(names))]] for _ in names];values=[x for rows in selected for x in rows];bootcost.append(statistics.mean(x[0] for x in values));bootsolve.append(statistics.mean(x[1] for x in values))
 return dict(pairs=len(pairs),boards=len(names),meanCostDifference=statistics.mean(ds),costCI95=[percentile(bootcost,.025),percentile(bootcost,.975)],solveRateDifference=statistics.mean(ss),solveRateCI95=[percentile(bootsolve,.025),percentile(bootsolve,.975)],wins=sum(x<-.001 for x in ds),losses=sum(x>.001 for x in ds),ties=sum(abs(x)<=.001 for x in ds),onlyFirstSolved=sum(a['status']=='solved' and b['status']!='solved' for a,b in pairs),onlySecondSolved=sum(b['status']=='solved' and a['status']!='solved' for a,b in pairs))
effects={}
for variable,index in [('continuous_minus_discrete',0),('regional_on_minus_off',1),('newBP_on_minus_off',2)]:
 pairs=[]
 for block,js in complete.items():
  mapping={key(j):j for j in js}
  for k,a in mapping.items():
   if k[index] not in ('discrete',False):continue
   alternative=list(k);alternative[index]='continuous' if index==0 else True;pairs.append((a,mapping[tuple(alternative)]))
 effects[variable]=effect(pairs)
pairs=[]
for block,js in complete.items():
 mapping={key(j):j for j in js};pairs.append((mapping[('continuous',True,True)],mapping[('discrete',True,True)]))
effects['D_hybrid_minus_C_hybrid']=effect(pairs)
# Regional effect under BP versus without BP, matched within each representation/board/seed.
interaction=[]
for _,js in complete.items():
 m={key(j):j for j in js}
 for rep in ['discrete','continuous']:interaction.append((cost(m[(rep,True,True)])-cost(m[(rep,False,True)]))-(cost(m[(rep,True,False)])-cost(m[(rep,False,False)])))
equalboard={}
for k in keys:
 means=[summarize([j for js in byboardblocks[b] for j in js if key(j)==k]) for b in represented]
 equalboard[name(k)]={'cappedCost':statistics.mean(x['cappedCost'] for x in means),'solveRate':statistics.mean(x['solveRate'] for x in means)}
loso={}
for k in keys:
 costs=[]
 for left in represented:
  costs.append(summarize([j for j in matched if j['board_id']!=left and key(j)==k])['cappedCost'])
 loso[name(k)]=[min(costs),max(costs)]
# Actual event files; interrupted attempts never substituted for terminal outcomes.
attempts=collections.defaultdict(list)
for a in s['attempts']:attempts[a['job_id']].append(a)
budgets=[0,10,30,60,120,300,600,900,1200];trajectory=[];curves={};raw_metrics=[];init={};memory=[];incomplete=[];recent=[]
for j in terminal:
 a=max((a for a in attempts[j['id']] if a['status'] in ('solved','timeout')),key=lambda a:a['seq']);events=[];lastquality=None;lastgain=0;gains=[]
 path=pathlib.Path(a['directory'])/'events.jsonl'
 source_events=(json.loads(line) for line in path.open()) if path.exists() else iter(cached_curves[j['id']])
 for p in source_events:
   events.append(p);q=p['quality'];quality=(q['issues'],q['wrong'],q['residual'])
   if lastquality is not None and quality<lastquality:lastgain=p['seconds'];gains.append(p['seconds'])
   lastquality=quality
 assert events and events[-1]['quality']==j['result']['quality'],j['id']
 if j['status']=='solved':assert events[-1]['phase']=='solved'
 init[(j['board_id'],j['seed'],name(key(j)))]=events[0];memory.append(events[-1]['memoryBytes']);raw_metrics.append(j['result']['metrics'])
 for t in budgets:
  if j['status']=='solved' and j['result']['seconds']<=t:v=dict(wrong=0,residual=0,commonEnergy=0,sampleTime=j['result']['seconds'],source='solved before budget')
  else:
   candidates=[p for p in events if p['seconds']<=t]
   if not candidates:
    if t!=0:raise ValueError('Missing budget observation')
    p=events[0];v=dict(wrong=p['quality']['wrong'],residual=p['quality']['residual'],commonEnergy=p['commonEnergy'],sampleTime=p['seconds'],source='first observation after initialization')
   else:
    p=candidates[-1];v=dict(wrong=p['quality']['wrong'],residual=p['quality']['residual'],commonEnergy=p['commonEnergy'],sampleTime=p['seconds'],source='last sample at or before budget')
  trajectory.append(dict(job=j['id'],board=j['board_id'],n=boards[j['board_id']]['n'],seed=j['seed'],condition=name(key(j)),budget=t,**v))
 recent.append({'job':j['id'],'n':boards[j['board_id']]['n'],'condition':name(key(j)),'status':j['status'],'lastObservedImprovement':lastgain,'improvementCount':len(gains),'after600':lastgain>600,'after900':lastgain>900})
 # Retain actual timestamps and metrics for reproducible real-time figures without individual curve extrapolation.
 curves[j['id']]=[{key:p[key] for key in ['seconds','quality','commonEnergy','nativeEnergy','discreteness','cpuSeconds','memoryBytes','phase']} for p in events]
# Same first exact quality, native energy and zero discreteness on every matched initialization.
init_ok=[]
for b,js in complete.items():
 obs=[init[(b[0],b[1],name(key(j)))] for j in js];assert all(p['quality']==obs[0]['quality'] and abs(p['nativeEnergy']-obs[0]['nativeEnergy'])<1e-12 and p['discreteness']==0 for p in obs);init_ok.append(b)
for a in s['attempts']:
 if a['status']!='interrupted':continue
 folder=pathlib.Path(a['directory']);p=json.loads((folder/'progress.json').read_text()) if (folder/'progress.json').exists() else cached_partial.get(a['id'],{}).get('progress')
 q=json.loads((folder/'checkpoint.json').read_text()) if (folder/'checkpoint.json').exists() else cached_partial.get(a['id'],{}).get('checkpoint')
 partial_cache[a['id']]={'progress':p,'checkpoint':q}
 job=next(j for j in jobs if j['id']==a['job_id']);check=evaluate(q['labels'],boards[job['board_id']]['n'],boards[job['board_id']]['puzzle']['clues']) if q else None
 incomplete.append(dict(job=a['job_id'],attempt=a['seq'],started=a['started'],ended=a['ended'],processWallEstimate=a['ended']-a['started'] if a['ended'] else None,lastSampleSeconds=p['seconds'] if p else None,cpuSeconds=p['cpuSeconds'] if p else None,quality=p['quality'] if p else None,checkpointSolved=check['solved'] if check else None,finalJobStatus=job['status']))
profile=[]
for b in s['boards']:
 n=b['n'];p=b['puzzle'];known=b['certificate']['solutions'][0];groups=collections.Counter(known);regions=[[i for i,v in enumerate(known) if v==label] for label in groups]
 boxes=[(max(c//n for c in g)-min(c//n for c in g)+1)*(max(c%n for c in g)-min(c%n for c in g)+1) for g in regions]
 js=[j for j in terminal if j['board_id']==b['id']];actual=[j for j in js if j['status']=='solved'];partitions={canonical_partition(sum(j['result']['labels'],[])) for j in actual};answers=sorted({j['result']['answer'] for j in actual})
 known_parts={canonical_partition(x) for x in b['certificate']['solutions']};known_answers=set(b['certificate']['answers'])
 profile.append(dict(knownDistinctPartitionsLowerBound=len(partitions|known_parts),knownAnswerUnion=sorted(set(answers)|known_answers),id=b['id'],n=n,clues=sum(x>=0 for x in p['clues']),zeros=p['clues'].count(0),maxClue=max(p['clues']),provenCount=b['solution_count'],knownRegionCount=len(groups),largestKnownRegion=max(groups.values()),largestKnownBoundingArea=max(boxes),knownRegionsBeyondSeedCache=sum(x>16 for x in boxes),completed=len(js),solved=len(actual),observedDistinctSolvedPartitions=len(partitions),observedAnswers=answers,byCondition={name(k):summarize([j for j in js if key(j)==k]) for k in keys}))
known_nonunique=[x['id'] for x in profile if x['observedDistinctSolvedPartitions']>1]
resource=dict(terminalCPUHours=sum(j['result']['cpuSeconds'] for j in terminal)/3600,terminalWallHours=sum(j['result']['seconds'] for j in terminal)/3600,interruptedSampledCPUHours=sum(x['cpuSeconds'] or 0 for x in incomplete)/3600,interruptedWallEstimateHours=sum(x['processWallEstimate'] or 0 for x in incomplete)/3600,cpuWallRatio=sum(j['result']['cpuSeconds'] for j in terminal)/sum(j['result']['seconds'] for j in terminal),cpuWallMin=min(j['result']['cpuSeconds']/j['result']['seconds'] for j in terminal),cpuWallMax=max(j['result']['cpuSeconds']/j['result']['seconds'] for j in terminal),memoryMaxBytes=max(memory),memoryMedianBytes=statistics.median(memory),bpEnabledWallSeconds=sum(j['result']['seconds'] for j in terminal if key(j)[2]),bpSeconds=sum(m['bpSeconds'] for m in raw_metrics),bpPhases=sum(m['bpPhases'] for m in raw_metrics),bpSourceImprovements=sum(m['bpImprovements'] for m in raw_metrics),bpNodes=sum(m['bpNodes'] for m in raw_metrics),bpTimeShare=sum(m['bpSeconds'] for m in raw_metrics)/sum(j['result']['seconds'] for j in terminal if key(j)[2]))
for rep in ['discrete','continuous']:
 js=[j for j in terminal if key(j)[0]==rep];resource[rep]={'iterationsPerCPUSecond':sum(j['result']['metrics']['iterations'] for j in js)/sum(j['result']['cpuSeconds'] for j in js),'iterationMedian':statistics.median(j['result']['metrics']['iterations'] for j in js)}
source=pathlib.Path(s['metadata']['config']['source']);manifest=json.loads((pathlib.Path(s['root'])/'source-manifest.json').read_text());hashaudit={}
for filename in ['bench-worker','bench-tools']:
 actual=hashlib.sha256((pathlib.Path(s['root'])/'bin'/filename).read_bytes()).hexdigest();assert actual==manifest['bin/'+filename];hashaudit[filename]=actual
actualshape=hashlib.sha256(pathlib.Path(s['metadata']['config']['shape_store']).read_bytes()).hexdigest();assert actualshape==s['metadata']['shape_sha256'];hashaudit['shapeStore']=actualshape
summary=dict(observed=s['observed'],campaign=s['metadata']['config']['id'],phase=s['metadata']['phase'],counts=dict(collections.Counter(j['status'] for j in jobs)),attemptCounts=dict(collections.Counter(a['status'] for a in s['attempts'])),matchedBlocks=len(complete),representedBoards=len(represented),perCondition=condition,perSize=by_size,perSizeCondition=by_size_condition,pairedEffects=effects,interactionCostDifference=statistics.mean(interaction),equalBoard=equalboard,leaveOneBoardOutCostRange=loso,boardProfiles=profile,knownNonuniqueObserved=known_nonunique,knownNonuniqueIncludingWitness=[p['id'] for p in profile if p['knownDistinctPartitionsLowerBound']>1],resource=resource,lateSolves={str(t):sum(j['status']=='solved' and j['result']['seconds']<=t for j in terminal) for t in [10,30,60,120,300,600,900,1200]},initializationBlocksChecked=len(init_ok),audit=dict(terminalChecked=len(audit),fixturesChecked=len(proofs),allPassed=True,hashes=hashaudit),interrupted=incomplete)
(out/'interrupted-observations.json').write_text(json.dumps(partial_cache,separators=(',',':')))
(out/'summary.json').write_text(json.dumps(summary,indent=2));(out/'snapshot.json').write_bytes(snapshot.read_bytes());(out/'audit.json').write_text(json.dumps({'terminal':audit,'fixtures':proofs,'hashes':hashaudit},indent=2));(out/'observed-curves.json').write_text(json.dumps(curves,separators=(',',':')));(out/'fixtures.json').write_text(json.dumps(s['boards'],indent=2));(out/'last-improvements.json').write_text(json.dumps(recent,indent=2))
def csvwrite(name,rows):
 with (out/name).open('w',newline='') as f:
  w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
csvwrite('energy-at-budgets.csv',trajectory);csvwrite('interrupted-attempts.csv',incomplete)
rows=[]
for j in terminal:
 r=j['result'];rows.append(dict(job=j['id'],board=j['board_id'],seed=j['seed'],condition=name(key(j)),status=j['status'],seconds=r['seconds'],cappedCost=cost(j),cpuSeconds=r['cpuSeconds'],**r['quality'],**r['metrics'],**{'oracle_'+k:v for k,v in r['oracle'].items()}))
csvwrite('completed-trials.csv',rows);csvwrite('conditions.csv',[dict(condition=k,**v) for k,v in condition.items()]);csvwrite('board-coverage.csv',[{k:v for k,v in x.items() if k not in ('byCondition','observedAnswers')} for x in profile])
print(json.dumps({k:summary[k] for k in ['observed','counts','matchedBlocks','representedBoards','perCondition','pairedEffects','interactionCostDifference','knownNonuniqueObserved','resource','audit']},indent=2))
