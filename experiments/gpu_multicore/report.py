"""JSP-Oct26-GPU-Multicore; ©2026 ThomasB. Validate and report completed trials."""
import csv,json,math,pathlib,statistics,sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
here=pathlib.Path(__file__).resolve().parent;repo=here.parent.parent
sys.path.insert(0,str(repo/'experiments/solver_bench'))
from benchqueue.validation import evaluate
root=pathlib.Path(sys.argv[1]);results=json.load(open(root/'results.json'));state=json.load(open(root/'state.json'))
assert state['phase']=='finished' and len(results)==4
# Use the exact original clues in the saved quick-probe capture, never a solution witness.
inputs=json.load(open(repo/'experiments/gpu_quick/results/20261030-quick/JSP-Oct26-GPU-Quick-Inputs.json'))
clues=next(b['clues'] for b in inputs['boards'] if b['n']==11)
validation=[];rows=[]
for result in results:
 check=evaluate(result['labels'],11,clues);q=result['quality']
 assert check['issues']==q['issues'] and check['wrong']==q['wrong'] and abs(check['residual']-q['residual'])<1e-12
 assert check['solved']==result['solved'] and abs(check['commonEnergy']-result['commonEnergy'])<1e-12
 assert result['exitCode']==0 and len(result['workers'])==8 and result['seconds']<100
 if result['mode']=='cpu8-fullGPU':assert result['gpu']['boards']>0 and not any(w['fallback'] for w in result['workers'])
 validation.append(dict(id=result['id'],independentPython=check))
 row=dict(id=result['id'],seed=result['seed'],mode=result['mode'],seconds=result['seconds'],cpuEquivalentCores=result['cpuEquivalentCores'],solved=result['solved'],issues=q['issues'],wrong=q['wrong'],residual=q['residual'],energy=result['commonEnergy'],iterations=result['iterations'],iterationsPerSecond=result['iterations']/result['seconds'],evaluations=result['metrics']['evaluations'],evaluationsPerSecond=result['metrics']['evaluations']/result['seconds'],gpuBoards=(result['gpu'] or {}).get('boards',0),gpuBatches=(result['gpu'] or {}).get('batches',0),meanGPUBatch=(result['gpu'] or {}).get('meanBatch',0))
 samples=json.load(open(root/result['id']/'host-samples.json'))
 usages=[g['stats']['Device Utilization %'] for s in samples for g in s.get('gpu',[]) if isinstance(g,dict) and g.get('stats') and 'Device Utilization %' in g['stats']]
 row['medianDeviceGPUPercent']=statistics.median(usages) if usages else None
 row['summedWorkerDistanceSeconds']=result['metrics']['distanceSeconds'];rows.append(row)
(root/'JSP-Oct26-GPU-Multicore-Validation.json').write_text(json.dumps(validation,indent=2))
with (root/'JSP-Oct26-GPU-Multicore-Trials.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
seeds=sorted({r['seed'] for r in results});fig,axes=plt.subplots(2,2,figsize=(12,7),sharex='col')
for col,seed in enumerate(seeds):
 for r in [x for x in results if x['seed']==seed]:
  folder=root/r['id'];points=[]
  for line in (folder/'observations.jsonl').read_text().splitlines():
   try:points.append(json.loads(line))
   except ValueError:continue
  points.append(dict(seconds=r['seconds'],commonEnergy=r['commonEnergy'],quality=r['quality']))
  points.sort(key=lambda p:p['seconds']);label='8 CPU + full GPU' if r['mode']=='cpu8-fullGPU' else '8 CPU';color='#ea6a20' if r['mode']=='cpu8-fullGPU' else '#2468bb'
  for ax,key in [(axes[0,col],'energy'),(axes[1,col],'wrong')]:
   ys=[p['commonEnergy'] if key=='energy' else p['quality']['wrong'] for p in points]
   ax.step([p['seconds'] for p in points],ys,where='post',label=label,color=color,lw=1.7)
   ax.grid(alpha=.2);ax.spines[['top','right']].set_visible(False)
  axes[0,col].set_title('Original 11 × 11 · seed '+str(seed));axes[0,col].legend(frameon=False)
 axes[1,col].set_xlabel('Real elapsed seconds');axes[0,col].set_ylim(bottom=0);axes[1,col].set_ylim(bottom=0)
axes[0,0].set_ylabel('Recorded common energy');axes[1,0].set_ylabel('Incorrect clues')
fig.suptitle('JSP-Oct26-GPU-Multicore · sequential solver comparison',fontsize=15)
fig.text(.02,.018,'Retained best is ranked by structural issues, incorrect clues, then residual; energy can increase. ©2026 ThomasB',fontsize=8)
fig.tight_layout(rect=[0,.045,1,.95]);fig.savefig(root/'JSP-Oct26-GPU-Multicore-Energy.png',dpi=170);plt.close(fig)
lines=['# JSP-Oct26-GPU-Multicore-Report','','©2026 ThomasB','','Author: ThomasB  ','Date: 2026-10-30, Asia/Tokyo','','## Scope','','Actual production search on the M2 Mac mini: eight CPU search tasks versus the same concurrency with unrestricted use of the full 10-core GPU. Two matched seeds, CPU/GPU then GPU/CPU order, one solver process at a time, 90 seconds per configuration. Eight independent Metal queues avoid the stock singleton backend lock. No installed executable or original campaign was changed.','','## Observed results','','| Seed | Mode | Seconds | CPU equivalents | Solved | Wrong clues | Residual | Iterations/s | Evaluations/s | GPU boards |','| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |']
for r in rows:lines.append('| %d | %s | %.2f | %.2f | %s | %d | %.6f | %.1f | %.1f | %d |'%(r['seed'],r['mode'],r['seconds'],r['cpuEquivalentCores'],'Yes' if r['solved'] else 'No',r['wrong'],r['residual'],r['iterationsPerSecond'],r['evaluationsPerSecond'],r['gpuBoards']))
lines+=['','All four final partitions passed the independent Python integer-rule checker. GPU results were also CPU-certified during search; no fallback was accepted. Each timed solver returned eight worker records.','']
for seed in seeds:
 cpu=next(r for r in rows if r['seed']==seed and r['mode']=='cpu8');gpu=next(r for r in rows if r['seed']==seed and r['mode']=='cpu8-fullGPU')
 lines.append('Seed %d: GPU/CPU iteration throughput %.3f×; evaluation throughput %.3f×. Wrong clues: %d → %d; residual: %.6f → %.6f.'%(seed,gpu['iterationsPerSecond']/cpu['iterationsPerSecond'],gpu['evaluationsPerSecond']/cpu['evaluationsPerSecond'],cpu['wrong'],gpu['wrong'],cpu['residual'],gpu['residual']))
lines+=['','Validated solves: %d/2 CPU, %d/2 GPU.'%(sum(r['solved'] for r in rows if r['mode']=='cpu8'),sum(r['solved'] for r in rows if r['mode']=='cpu8-fullGPU'))]
if not any(r['solved'] for r in rows):lines+=['Neither configuration solved within this short cutoff. Time-to-solution improvement is therefore **not established**. Throughput and quality are screening diagnostics, not substituted solve times.']
lines+=['','Summed per-worker path-evaluation elapsed seconds (includes GPU waiting and certification; workers overlap):','']
for r in rows:lines.append('- Seed %d, %s: %.3f seconds.'%(r['seed'],r['mode'],r['summedWorkerDistanceSeconds']))
lines+=['These are nested, overlapping worker timers. Do not add them to catalog/geometry times or treat them as disjoint wall-time fractions.']
lines+=['','## Real-time curves','','![Measured energy and clue mismatches](JSP-Oct26-GPU-Multicore-Energy.png)','','Curves use actual observation timestamps, including initialization and GPU setup. They retain exact-match quality leaders, so common residual energy need not decrease monotonically. Final result points use their actual final timestamps; curves are not extended to a synthetic endpoint.','','## Resource use and limitations','','Eight search tasks are a concurrency budget, not physical CPU pinning. This M2 has four performance and four efficiency CPU cores. CPU-equivalent cores are measured process CPU seconds divided by elapsed seconds. The GPU has ten cores; all are available to Metal, with no physical-core reservation. Each queue dispatches one threadgroup per board, up to 32 boards per batch. Neither queue count nor device availability proves full GPU saturation. Device-wide utilization samples include the GUI and any other applications. The previously installed coordinator was observed idle before this experiment and was not modified.','']
for r in rows:
 if r['mode']=='cpu8-fullGPU':lines.append('Seed %d: %d GPU batches, %d boards, mean %.2f boards/batch; median device-wide GPU utilization %s%%.'%(r['seed'],r['gpuBatches'],r['gpuBoards'],r['meanGPUBatch'],r['medianDeviceGPUPercent']))
lines+=['','This is the existing synchronous Metal path backend with one queue per CPU worker. Geometry and final floating-point energy stay on the CPU; this is not a complete GPU energy implementation or the asynchronous frontier proposed earlier. CPU mode flushes candidate batches at size 1 while forced GPU mode uses up to 32. This changes some search work/order and means throughput differences do not isolate hardware alone. Both modes retain the same production repair/pruning logic, objectives, seed schedule and elite archive. Thread scheduling and archive exchanges make exact search trajectories nondeterministic.','','The cutoff is 90 seconds, not the earlier 1,200-second campaign limit. Shader caches were warmed by excluded smoke checks, but per-process pipeline setup, serialization, waiting, certification, initialization and observation overhead remain in elapsed time. There are only two pairs and one puzzle; no statistical solve-speed or general hardware claim follows.','','## Evidence','','The raw `results.json`, per-worker logs/checkpoints, `observations.jsonl`, `host-samples.json`, initial `background.json`, frozen-source hashes and native binary hash are retained. Original durable data directory:','','`'+json.load(open('/private/tmp/jsp-gpu-multicore-current.json'))['root']+'`','','The previous Repair-Completion campaign remains paused. All testing used isolated native builds, with production software version 2 recorded and core sources unchanged.']
cpu_rows=[r for r in rows if r['mode']=='cpu8'];gpu_rows=[r for r in rows if r['mode']=='cpu8-fullGPU']
ratios=[];eval_ratios=[]
for seed in seeds:
 c=next(r for r in cpu_rows if r['seed']==seed);g=next(r for r in gpu_rows if r['seed']==seed)
 ratios.append(g['iterationsPerSecond']/c['iterationsPerSecond']);eval_ratios.append(g['evaluationsPerSecond']/c['evaluationsPerSecond'])
conclusion=['## Interpretation','']
if all(x<1 for x in ratios):
 conclusion+=['Forced GPU path evaluation did not improve search throughput in either pair: iteration throughput fell %.1f–%.1f%%, while evaluation throughput fell %.1f–%.1f%%.'%(100*(1-max(ratios)),100*(1-min(ratios)),100*(1-max(eval_ratios)),100*(1-min(eval_ratios))),'']
conclusion+=['Final quality is mixed: the first GPU run has fewer wrong clues (12 versus 14); the second CPU run ties at 13 wrong clues with a substantially lower residual (0.131667 versus 0.245003). Those observations do not establish a time-to-solution gain. Retain CPU evaluation for now; this implementation offers no demonstrated overall advantage from full-GPU access.','',
'GPU path-evaluation elapsed time summed across workers was about 28.6–28.8 seconds versus 11.3–11.5 seconds for CPU paths. Packing, submission, waits, result conversion and certification can overwhelm tiny path computations even with full-device scheduling. Most geometry/catalog work still runs on the CPU. These counters are diagnostic and overlap across workers.','']
idx=lines.index('## Observed results');lines[idx:idx]=conclusion
(root/'JSP-Oct26-GPU-Multicore-Report.md').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines[:32]))
