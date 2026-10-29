#!/usr/bin/env python3
"""Summarize raw observations without treating timeouts as solve times."""
import json
import statistics as st
import sys
from pathlib import Path

folder = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent/'results'
data = json.loads((folder/'results.json').read_text())
meta = json.loads((folder/'metadata.json').read_text())
lines = ['# Initial throughput experiment', '', 'For the requested time-to-solution comparison, see [SOLVE_TIME_REPORT.md](../SOLVE_TIME_REPORT.md). The measurements below do not establish solving speed.', '',
         'Run on 2026-10-29; '+meta['machine']+'; optimized Swift, CPU only, one worker.',
         f"Five paired seeds per puzzle; {meta['seconds_per_trial']:g} seconds per search trial. No deployment or core changes.", '',
         '## Identical-partition scoring', '',
         'Median microseconds per scoring call across five repeats. Cold = fresh context for a pool pass; warm = five revisits of that pool. Board construction excluded. Random pools can themselves contain duplicate partitions, so cold does not guarantee every call is a cache miss.', '',
         '| Puzzle | Discrete cold µs | Continuous cold µs | Cold speedup | Discrete warm µs | Continuous warm µs | Warm speedup |',
         '|---|---:|---:|---:|---:|---:|---:|']
for puzzle in data['puzzles']:
    name = puzzle['name']
    def per(kind):
        return st.median(t['seconds']/t['evaluations']*1e6 for t in data['timings'] if t['puzzle']==name and t['candidate']==kind)
    dc,cc,dw,cw = map(per, ['discrete_cold','continuous_cold','discrete_warm','continuous_warm'])
    lines.append(f'| {name} | {dc:.2f} | {cc:.2f} | {cc/dc:.1f}× | {dw:.2f} | {cw:.2f} | {cw/dw:.1f}× |')
lines += ['', '## Bounded search', '',
          'Controlled candidates share the same simple edge-resampling annealer. The production reference uses its existing richer repair search. “Successful time” excludes unsolved trials; it is not an estimate of unconditional solve time. Throughput is wall-clock calls/s including independent validation.', '',
          '| Puzzle | Candidate | Solved | Median successful time (s) | Median calls/s | Median best wrong clues | Median best structural issues |',
          '|---|---|---:|---:|---:|---:|---:|']
for puzzle in data['puzzles']:
    name=puzzle['name']
    for candidate in ['controlled_discrete','controlled_continuous','production_discrete']:
        ts=[t for t in data['trials'] if t['puzzle']==name and t['candidate']==candidate]
        if not ts:
            continue
        successes=[t['seconds'] for t in ts if t['solved']]
        success=f'{st.median(successes):.3f}' if successes else '—'
        throughput=f"{st.median(t['evaluations']/t['seconds'] for t in ts):,.0f}" if candidate!='production_discrete' else 'different counter'
        lines.append(f"| {name} | {candidate} | {len(successes)}/{len(ts)} | {success} | {throughput} | {st.median(t['wrongClues'] for t in ts):g} | {st.median(t['structuralIssues'] for t in ts):g} |")
lines += ['', '## Fixtures and validation', '',
          'The published 5×5 witness produced answer **8,045**. Both scoring paths gave zero on each known solution. Generated full distance fields agreed with the independent production validator. The 1×3 and X-pentomino no-capitol cases and singleton capitol case passed.', '']
for p in data['puzzles']:
    lines += [f"### {p['name']}", '', f"Maker seed: {p.get('makerSeed', 'published example')}. Clues: {sum(x>=0 for row in p['clues'] for x in row)}. Distinct witness states: {len(set(p['witness']))}.", '', 'Clues (`.` = blank):', '', '```']
    lines += [' '.join(f'{x:2}' if x>=0 else ' .' for x in row) for row in p['clues']]
    lines += ['```', '', 'Known satisfying partition (equal letters = same state):', '', '```']
    ids={v:chr(65+i) for i,v in enumerate(dict.fromkeys(p['witness']))}
    lines += [' '.join(ids[x] for x in p['witness'][r*p['n']:(r+1)*p['n']]) for r in range(p['n'])]
    lines += ['```', '']
lines += ['## Interpretation', '',
          'Discrete scoring wins throughput on these fixtures. This compares different algorithms and cache strategies, not just integer versus floating-point instructions. Exact discrete scoring uses one multi-source shortest-path computation; continuous scoring computes per-clue distances and integrates tentative capitol distributions. Whole-partition reuse further favors discrete scoring.', '',
          'The controlled searches did not establish a time-to-solution winner where neither solved. The production reference tests the actual discrete solver, but its advantage cannot be attributed solely to number representation because its move generation and initialization differ.', '',
          'These are short exploratory CPU runs on the supplied example and two known-satisfiable generated puzzles. Uniqueness was not checked. They do not establish performance on all 8×8 puzzles or the original 11×11. Timed searches are stochastic and may vary slightly because deadlines affect work completed, even with fixed RNG seeds.', '',
          'Reproduction and full methodology: [README](../README.md). Raw observations: [results.json](results.json). Build/environment: [metadata.json](metadata.json).', '']
(folder/'REPORT.md').write_text('\n'.join(lines))
print('\n'.join(lines[:32]))
