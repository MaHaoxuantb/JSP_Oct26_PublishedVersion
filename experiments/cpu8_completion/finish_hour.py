"""JSP-Oct26-CPU8-Completion; ©2026 ThomasB. Bounded automatic evaluation report."""
import argparse,datetime,json,pathlib,sys,time,zoneinfo
HERE=pathlib.Path(__file__).resolve().parent;REPO=HERE.parent.parent
sys.path.insert(0,str(REPO/'experiments/solver_bench'))
from benchqueue.validation import evaluate
NAME='JSP-Oct26-CPU8-Completion'
def read(path):
 try:return json.loads(pathlib.Path(path).read_text())
 except (OSError,ValueError):return None

def generate(root,snapshot,deadline):
 import matplotlib
 matplotlib.use('Agg')
 import matplotlib.pyplot as plt
 z=zoneinfo.ZoneInfo('Asia/Tokyo');stamp=lambda t:datetime.datetime.fromtimestamp(t,z).strftime('%Y-%m-%d %H:%M:%S JST')
 jobs=snapshot['jobs'];puzzle=snapshot['config']['puzzle'];summary=[]
 for j in jobs:
  r=j.get('result');row=dict(method=j['method'],label=j['label'],status=j['status'],effectiveBudgetSeconds=j.get('budgetSeconds',snapshot['config']['seconds']))
  if r:
   q=evaluate(r['labels'],puzzle['n'],puzzle['clues']);assert q['issues']==r['quality']['issues'] and q['solved']==r['solved'] and q['wrong']==r['quality']['wrong'] and abs(q['residual']-r['quality']['residual'])<1e-12
   solve_times=[p['seconds'] for p in j.get('series',[]) if p.get('solved')]
   row.update(seconds=r['seconds'],cpuEquivalentCores=r['cpuEquivalentCores'],solved=q['solved'],wrong=q['wrong'],residual=q['residual'],answer=q['answer'],timeToFirstValid=min(solve_times) if solve_times and q['solved'] else r['seconds'] if q['solved'] else None,iterations=sum(w['metrics']['iterations'] for w in r['workers']),bpNodes=sum(w['metrics']['bpNodes'] for w in r['workers']),bpImprovements=sum(w['metrics']['bpImprovements'] for w in r['workers']),imports=sum(r.get('cooperative',{}).get('imports',{}).values()))
  summary.append(row)
 fig,axes=plt.subplots(2,1,figsize=(10,7),sharex=True)
 for index,j in enumerate(jobs):
  points=list(j.get('series',[]));r=j.get('result')
  if r:points.append(dict(seconds=r['seconds'],commonEnergy=r['commonEnergy'],quality=r['quality']))
  points.sort(key=lambda p:p['seconds'])
  if not points:continue
  color=['#315cff','#ed8a32'][index%2]
  for ax,key in [(axes[0],'energy'),(axes[1],'wrong')]:
   ax.step([p['seconds'] for p in points],[p['commonEnergy'] if key=='energy' else p['quality']['wrong'] for p in points],where='post',label=j['label'],color=color,lw=1.8);ax.grid(alpha=.2);ax.set_ylim(bottom=0);ax.spines[['top','right']].set_visible(False)
 axes[0].set_ylabel('Recorded common energy');axes[1].set_ylabel('Incorrect clues');axes[1].set_xlabel('Real elapsed seconds per method');axes[0].legend(frameon=False)
 fig.suptitle(NAME+' · amended one-hour evaluation');fig.text(.02,.015,'Eight CPU threads per method; retained quality ranks wrong clues before residual. ©2026 ThomasB',fontsize=8);fig.tight_layout(rect=[0,.04,1,.95])
 chart=NAME+'-Evaluation-Energy.png';fig.savefig(root/chart,dpi=170);plt.close(fig)
 lines=['# '+NAME+'-Evaluation','','©2026 ThomasB','','Author: ThomasB','',f"Generated {stamp(time.time())}. Requested report deadline: {stamp(deadline)}.",'', '## Outcome','', 'Evaluation phase: **'+snapshot['phase']+'**. Original 11×11 puzzle, CPU-only, eight cooperating threads, one method at a time.','', '| Method | State | Seconds | CPU equivalents | Solved | Wrong clues | Residual |','| --- | --- | ---: | ---: | --- | ---: | ---: |']
 for r in summary:lines.append('| %s | %s | %s | %s | %s | %s | %s |'%(r['label'],r['status'],('%.2f'%r['seconds']) if 'seconds'in r else '—',('%.2f'%r['cpuEquivalentCores']) if 'cpuEquivalentCores'in r else '—',r.get('solved','—'),r.get('wrong','—'),('%.6f'%r['residual']) if 'residual'in r else '—'))
 complete=[r for r in summary if 'solved' in r]
 if len(complete)==2:
  if not any(r['solved'] for r in complete):lines+=['','Neither method solved within its amended budget. A time-to-solution advantage is **not established**. Lower mismatch/residual values are diagnostic, not a forecast of remaining work.']
  else:
   for r in complete:
    if r['solved']:lines+=['',r['label']+' produced an independently validated solution at %.3f seconds; answer %s.'%(r['timeToFirstValid'],r['answer'])]
 else:lines+=['','This is an incomplete or interrupted evaluation; missing final results are not counted as full-budget failures.']
 lines+=['','## Measured curves','',f'![Recorded energy and clue mismatches]({chart})','','Curves use actual timestamps and actual final result points. Energy can rise when a candidate satisfies more clues because retained quality ranks wrong-clue count before residual. No curve is artificially extended to a cutoff.','','## Interpretation and preservation','','The user shortened the evaluation to one hour while B was already running. Both methods receive an effective 1,800-second total budget. B retained its original process, state, RNG streams, private repair stacks and observations. Its original native input still records 3,000 seconds; external cooperative cancellation enforces the amended cutoff. A budget_timeout is an amended-budget outcome, not an original 3,000-second timeout. D starts fresh with the same eight-seed schedule. No original control was rerun.','','Native worker binaries remain version 3 for both methods. Version 4 records only the deadline-controller/dashboard release, with explicit minimum worker version 3; older/unversioned and future workers are not accepted by the new result checker. The original version-3 manifest and frozen source remain unchanged; the amendment records source hashes, preserved PID, previous configuration and deadline. Cooling settings were not changed.','','One paired puzzle run is exploratory. Do not pool this amended budget with the old single-thread or 3,000-second plan, infer statistical superiority, or treat energy as completion percentage. Raw results, global/worker observations, independent validation and checkpoints remain in the original Mini run directory.']
 for r in summary:
  if 'iterations'in r:lines+=['',r['label']+': %d iterations, %d BP nodes, %d BP improvements and %d candidate imports.'%(r['iterations'],r['bpNodes'],r['bpImprovements'],r['imports'])]
 if time.time()-snapshot['updated']>30:lines+=['','Warning: the mirrored snapshot is stale. This report uses the last available evidence and does not assert completion of missing work.']
 (root/(NAME+'-Evaluation.md')).write_text('\n'.join(lines)+'\n')
 (root/(NAME+'-Evaluation.json')).write_text(json.dumps(dict(experiment=NAME,copyright='©2026 ThomasB',author='ThomasB',generated=time.time(),deadline=deadline,snapshotUpdated=snapshot['updated'],phase=snapshot['phase'],trials=summary),ensure_ascii=False,indent=2))
 return summary

def main():
 p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--deadline',type=float,required=True);p.add_argument('--once',action='store_true');a=p.parse_args();root=pathlib.Path(a.root)
 while True:
  s=read(root/'snapshot.json')
  if s and (a.once or s['phase'] in ['complete','stopped','failed'] or time.time()>a.deadline-30):
   result=generate(root,s,a.deadline);print(json.dumps(result),flush=True);return
  time.sleep(5)
if __name__=='__main__':main()
