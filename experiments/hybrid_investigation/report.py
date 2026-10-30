#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,os,sys
here=Path(__file__).resolve().parent
out=Path((here/'latest-run.txt').read_text().strip())
prior=here.parent/'branch_vs_discrete/results/20261029-162908'
oldmeta=json.loads((prior/'metadata.json').read_text());report=Path(oldmeta['report'])
meta=json.loads((out/'metadata.json').read_text());assert 'completed' in meta
results=json.loads((out/'results.json').read_text());screen=json.loads((out/'patch-screening.json').read_text())
sys.path.insert(0,str(here.parent/'regional_production'));from metrics import exact_metrics
marker='\n\n<!-- hybrid-investigation -->\n';base=report.read_text().split(marker)[0]
text='\n## Investigation: alternating regional SA and local branch pruning\n\n'
text+='The existing discrete control already combines SA acceptance with bounded local exact-cover / branch-and-bound repairs. The proposed extension is adaptive, deeper repair phases with shared candidates and SA warm starts. Whole-board BP was unsuccessful in the larger-board trials; a local repair hypothesis remains separate from those global results.\n\n'
text+='The previous 1,000-second controls spent 850.507 s (8×8) and 848.866 s (9×9) in instrumented catalog generation, versus 67.912 s and 77.699 s in exact cover. These are instrumented phase times; other timers can be nested and should not be added as exclusive categories.\n\n'
text+='A short continuation probe used each saved near-solution as the common starting state. Four processes ran concurrently with 60 seconds per arm. The SA arm retains the control settings. The BP arm uses the same local cover routine, with existing route-focused patches up to 32 cells, relaxed geometry catalogs, 2-second repair calls, 250,000 nodes and 50,000 covers per call. It is an intensification diagnostic, not a complete alternating hybrid or a reliable speed comparison.\n\n'
text+='| Board | Arm | Incorrect clues before → after | Mean residual before → after | Cover nodes | Completed covers | Catalog / cover time |\n|---|---|---:|---:|---:|---:|---:|\n'
checks=[]
for r in results:
    n=r['n'];inp=json.loads((out/f'{n}-input.json').read_text());labs=inp['labels'];start=exact_metrics([labs[i*n:(i+1)*n] for i in range(n)],inp['fixture']);end=exact_metrics(r['snapshot']['labels'],inp['fixture'])
    assert r['independentValidation']['wrongClues']==end['exactWrongClues']
    a=r['repairs'];text+=f"| {n}×{n} | {'SA continuation' if r['mode']=='sa' else 'Deeper local BP'} | {start['exactWrongClues']} → {end['exactWrongClues']} | {start['exactClueEnergy']:.6f} → {end['exactClueEnergy']:.6f} | {a['coverNodes']:,} | {a['coversChecked']:,} | {a['catalogSeconds']:.2f} / {a['coverSeconds']:.2f} s |\n"
    checks.append({'n':n,'arm':r['mode'],'before':start,'after':end,'independent':r['independentValidation']})
text+='\nNeither continuation improved either checkpoint in this one-seed probe. Deeper BP spent almost its whole allowance searching and traversed millions of nodes. This does not refute a hybrid, but gives no evidence that allocating more time to the existing neighborhoods alone will finish these states. Candidate coverage, patch scope, conditional local minima and scheduling remain possible causes; they are not distinguished by this probe.\n\n'
text+='An offline audit considered all connected unions of one through four existing regions. Two-sided shortest-path bounds were checked **before candidate generation**, holding the exterior fixed. Residual comparisons use exact rational arithmetic. For patches of at most 32 cells:\n\n'
text+='| Board | Patches audited | Bounds exclude any improvement | Bounds exclude a full solution |\n|---|---:|---:|---:|\n'
for x in screen:
    a=x['upTo32'];text+=f"| {x['n']}×{x['n']} | {a['patches']} | {a['cannotImprove']} ({a['cannotImprove']/a['patches']:.1%}) | {a['fullSolutionExcluded']} ({a['fullSolutionExcluded']/a['patches']:.1%}) |\n"
text+='\nThese are patch-universe counts, not measured runtime savings. Passing the bounds does not prove an improvement exists. In particular, a local branch that cannot solve the whole board may still improve some wrong clues; BP should optimize against the SA incumbent, not require every local call to produce a perfect global solution.\n\n'
text+='**Recommended design:** SA exploration → persistent-error / route-based patch selection → cheap incumbent bounds → local BP with reused catalogs → elite update and SA continuation. Trigger stronger repairs on stagnation, retain SA exploration and diverse elites, and enlarge or relocate failed patches. A 5–10 s SA / 1–3 s BP schedule, initially around 80/20 by total time, is an untested starting heuristic. Preserve all elapsed costs in the common budget. Stronger BP should use both distance bounds against the incumbent, with catalogs informed by SA discoveries and search cursors reused only under compatible exterior conditions.\n\n'
text+='For the real 11×11 goal, a fixed 32-cell neighborhood and a frozen set of already-correct regions are too restrictive as a general design. Use adaptive patch sizes and revalidate every clue globally. Catalog truncation or a timed-out repair does not prove impossibility. Next evaluate the same regional SA with versus without adaptive deeper BP across multiple checkpoints, seeds and fresh starts; warm-start finishing and end-to-end solving are separate measurements. A hybrid speedup has not yet been demonstrated.\n\n'
rel=os.path.relpath(here,report.parent);art=os.path.relpath(out,report.parent)
text+=f'Full rationale, bound derivation, scheduling design and reproduction: [hybrid investigation]({rel}/README.md). [Probe sources, inputs, results and patch audit]({art}/). No production sources were changed.\n'
report.write_text(base+marker+text)
(out/'verification.json').write_text(json.dumps(checks,indent=2));(out/'previous-report.md').write_text(base)
(out/'report-provenance.json').write_text(json.dumps({'baseReportSHA256':hashlib.sha256(base.encode()).hexdigest(),'report':str(report)},indent=2))
for name in ['README.md','report.py','screen_patches.py']:(out/name).write_bytes((here/name).read_bytes())
print(report)
