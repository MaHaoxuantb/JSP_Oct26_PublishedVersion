from __future__ import annotations
import csv,json,os
from pathlib import Path
from .storage import atomic_json,now

def export_report(store):
    config=store.get('config');phase=store.get('phase');boards=store.rows('boards','ORDER BY n,slot');jobs=store.rows('jobs','ORDER BY launch_index');events=store.rows('events','ORDER BY id DESC LIMIT 80')
    output=store.directory/'report';output.mkdir(exist_ok=True)
    results=[]
    for j in jobs:
        row={k:j[k] for k in ['id','board_id','seed','status','attempt']};row.update(json.loads(j['condition']))
        if j['result']:
            r=json.loads(j['result']);row.update(seconds=r['seconds'],cpuSeconds=r['cpuSeconds'],solved=r['solved'],wrong=r['quality']['wrong'],residual=r['quality']['residual'],issues=r['quality']['issues'],reason=r['reason'])
        results.append(row)
    atomic_json(output/'certificates.json',[json.loads(b['certificate']) for b in boards]);atomic_json(output/'results.json',results);atomic_json(output/'fixtures.json',{'puzzles':[json.loads(b['puzzle']) for b in boards]})
    fields=['id','board_id','representation','regional','newBP','seed','status','attempt','solved','seconds','cpuSeconds','wrong','residual','issues','reason']
    with (output/'results.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader();writer.writerows(results)
    text='# '+config.get('display_name','JSP-Oct26-Regional-SA-BP')+'\n\n©2026 ThomasB\n\n'
    text+=f"Campaign: `{config['id']}`. State: **{phase}**. Four single-threaded CPU-only searches; macOS P-core placement is not guaranteed.\n\n"
    certified=sum(b['solution_count'] is not None for b in boards)
    text+=f"Boards ready: {len(boards)}/{len(config['sizes'])*config['boards_per_size']}; exact counts proven for {certified}; count unknown for {len(boards)-certified}. Planned trials: {store.get('planned_trials')}. Trial cutoff: {config['trial_seconds']} seconds.\n\n"
    text+='Shape domain: exact procedural enumeration with a frozen permanent cache. A cache miss does not remove a candidate. Enumeration exhaustion is separate from elapsed-time exhaustion. Certification uses private caches; timed trials cannot see witnesses or another run’s discoveries.\n\n'
    if config.get('admission_policy')=='validated_witness':text+='**Admission amended by user request:** start with the current puzzles, without waiting for uniqueness. Every fixture has an independently validated solution; unproven solution counts remain unknown. Known answers for unproven boards are not an exhaustive answer list. Saved witnesses never enter solver inputs.\n\n'
    text+='| Board | Clues | Proven partitions | Known valid answers |\n|---|---:|---:|---|\n'
    for b in boards:
        p=json.loads(b['puzzle']);c=json.loads(b['certificate']);text+=f"| {b['id']} | {sum(x>=0 for x in p['clues'])}/{p['n']**2} | {b['solution_count'] if b['solution_count'] is not None else 'Unknown (not certified)'} | {', '.join(map(str,c['answers']))} |\n"
    text+='\n| N | Representation | Regional | New BP | Valid terminal runs | Solved | Capped solve cost (s) |\n|---:|---|---|---|---:|---:|---:|\n'
    summaries=[]
    for n in config['sizes']:
        for representation in ['discrete','continuous']:
            for regional in [False,True]:
                for bp in [False,True]:
                    selected=[r for r in results if r['board_id'].startswith(f'n{n}-') and r['representation']==representation and r['regional']==regional and r['newBP']==bp]
                    finished=[r for r in selected if r['status'] in ['solved','timeout']];solved=[r for r in finished if r['solved']]
                    cost=sum(min(r['seconds'],config['trial_seconds']) if r['solved'] else config['trial_seconds'] for r in finished)/len(finished) if finished else None
                    summaries.append({'n':n,'representation':representation,'regional':regional,'newBP':bp,'terminal':len(finished),'solved':len(solved),'cappedCost':cost})
                    if selected:text+=f"| {n} | {representation} | {regional} | {bp} | {len(finished)} | {len(solved)} | {f'{cost:.3f}' if cost is not None else '—'} |\n"
    text+='\nCapped solve cost includes timeouts at the trial cap; it is not an estimate of eventual solve time. Pending, failed and unrun trials are excluded and remain visible. Warm starts are not used. Curves record the best lexicographic-quality candidate (invalid regions, incorrect clues, then residual), rather than an artificial lower envelope; native energy can therefore rise when a higher-priority quality measure improves. Timing categories are nested, so catalog, cover and BP times must not be added. Native energy is `(2*mean normalized clue residual + invalid-cell fraction + 2*discreteness)/5`; common exact energy is `(2*mean normalized clue residual + invalid-cell fraction)/3`. Incorrect clues and structural issues are also reported separately.\n\n'
    if not results:text+='**No timed trial measurements exist yet.** Preparation/certification progress is not solver performance data.\n\n'
    text+='Recent events:\n\n'
    for e in reversed(events[:20]):text+=f"- {e['kind']}: {e['message']}\n"
    (output/'REPORT.md').write_text(text);atomic_json(output/'summary.json',{'phase':phase,'generated':now(),'conditions':summaries})
    return output
