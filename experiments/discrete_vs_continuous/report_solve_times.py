#!/usr/bin/env python3
"""Compare paired real algorithms by time to independently verified solution."""
import json
import statistics as st
from pathlib import Path

here=Path(__file__).resolve().parent
current=json.loads((here/'solve5_matched_results/results.json').read_text())
current+=json.loads((here/'solve7_matched_results/results.json').read_text())
legacy=json.loads((here/'legacy5_matched_results/results.json').read_text())
legacy+=json.loads((here/'legacy7_matched_results/results.json').read_text())
fixture5=json.loads((here/'solve5_matched_results/fixtures.json').read_text())['puzzles'][0]
fixture=json.loads((here/'solve7_matched_results/fixtures.json').read_text())['puzzles'][1]
assert sum(x>=0 for row in fixture5['clues'] for x in row)==7
assert fixture['n']==7 and sum(x>=0 for row in fixture['clues'] for x in row)==13
revision=json.loads((here/'legacy5_matched_results/metadata.json').read_text())['revision']
lines=['# Time to a verified puzzle solution', '',
       'This compares the actual current discrete solver with the earlier continuous solver recovered from Git. The measure is elapsed time until a solver returns an independently verified solution. Evaluation throughput is not used as a substitute for solving speed.', '',
       'One CPU worker, optimized Swift, equal 30-second limits, three paired seeds per puzzle (20261029–20261031). Programs run sequentially. Both algorithms retain their own search strategies; matching seeds does not imply identical proposals across algorithms.', '',
       '| Puzzle | Actual solver | Solved | Successful solve times (s) | Median successful time (s) |',
       '|---|---|---:|---|---:|']
for name in dict.fromkeys(t['puzzle'] for t in legacy):
    old=[t for t in legacy if t['puzzle']==name]
    seeds={t['seed'] for t in old}
    new=[t for t in current if t['puzzle']==name and t['candidate']=='discrete' and t['seed'] in seeds]
    assert len(new)==len(old)==3
    for label,group in [('Current discrete',new),('Historical continuous',old)]:
        successful=[t['elapsedSeconds'] for t in group if t['solved']]
        times=', '.join(f'{x:.3f}' for x in successful) or '—'
        median=f'{st.median(successful):.3f}' if successful else '—'
        lines.append(f'| {name} | {label} | {len(successful)}/{len(group)} | {times} | {median} |')
lines += ['', 'Timeouts mean “not solved within 30 seconds.” There is no measured solve time or finite speedup ratio for a solver that timed out. Successful-only medians must be read alongside solve rates. Where neither solver solves, no solve-time winner can be established.', '',
          '## Clue density and fixtures', '',
          'The original 11×11 has **33 clues / 121 cells = 27.27%**. The generated 7×7 uses exactly **13 clues / 49 cells = 26.53%**, the closest integer clue count to the same density. Its clue locations are sampled uniformly without replacement, with no forced revealed capitol or farthest-cell clue. The 5×5 example is reduced to exactly **7 / 25 = 28.00%** clues. Seven of its original ten clue positions are selected uniformly without replacement using mask seed 5101. The earlier dense-example results are excluded from this comparison.', '',
          f'The 7×7 maker seed is {fixture["makerSeed"]}. Its witness has {len(set(fixture["witness"]))} states. The maker starts with singleton cells, repeatedly merges adjacent regions when the union remains symmetric (maximum 16 cells), and reserves cell 0 as a singleton so a capitol exists. It computes exact distances before sampling clues. The witness is checked independently. This guarantees satisfiability; uniqueness is not established. Matching clue density does not guarantee matching the original puzzle’s difficulty.', '',
          '5×5 clues (`.` = blank):', '', '```']
lines += [' '.join(f'{x:2}' if x>=0 else ' .' for x in row) for row in fixture5['clues']]
lines += ['```', '', '7×7 clues (`.` = blank):', '', '```']
lines += [' '.join(f'{x:2}' if x>=0 else ' .' for x in row) for row in fixture['clues']]
lines += ['```', '', 'Known satisfying partition (equal letters = same state):', '', '```']
ids={v:chr(65+i) for i,v in enumerate(dict.fromkeys(fixture['witness']))}
lines += [' '.join(ids[x] for x in fixture['witness'][r*7:(r+1)*7]) for r in range(7)]
lines += ['```', '', '## Scope and verification', '',
          f'The historical continuous candidate uses unmodified core Swift sources from commit `{revision}`. Its moves, continuous energy objective, initialization, edge confidences, temperature and reheat settings are retained. The runner changes dimensions/clues, seed, worker count (one), console logging (off), log path, time limit, and iteration/restart caps (raised so they do not cut a trial short). It is an earlier implementation, not the current checkout.', '',
          'The current discrete candidate uses the current production search and defaults, with one worker and CPU paths. The implementations differ in search strategy as well as representation. Thus the result compares whole implementations; it does not isolate arithmetic type alone.', '',
          'Historical outputs are independently checked in Python for connectivity, all seven nonidentity symmetries, the common unique fixed-square capitol condition, integer multi-source Dijkstra, every clue, and answer arithmetic. All witness fixtures pass. Historical reported validity must agree with this independent result. Current outputs are independently revalidated with the production validator. The full published witness has answer 8,045. Removing clues can allow other valid partitions and other answers; those are accepted when they satisfy every retained clue and every puzzle rule. Uniqueness has not been established for either sparse fixture.', '',
          '## Superseded pilots', '',
          'The earlier throughput measurements, dense 5×5 runs, denser 8×8 pilots and initial 7×7 pilot are excluded from the primary comparison. They remain saved for traceability. Interrupted trials are excluded. The requested comparison uses only the 7-clue 5×5 and 13-clue 7×7 fixtures above.', '',
          '## Reproduce the current requested comparison', '', '```sh',
          'python3 experiments/discrete_vs_continuous/solve_time.py --trials 3 --seconds 30 --size 7 --match-density --puzzles 0 1 --candidates discrete --output experiments/discrete_vs_continuous/repro_current',
          'python3 experiments/discrete_vs_continuous/legacy_solve_time.py --trials 3 --seconds 30 --puzzles 0 1 --fixtures experiments/discrete_vs_continuous/repro_current/fixtures.json --output experiments/discrete_vs_continuous/repro_legacy', '```', '',
          'All compilation and source substitutions use isolated `/private/tmp` folders. No core source, version, installed executable, worker, credential, checkpoint, coordinator state, or live database is modified. No deployment occurs.', '',
          'Raw observations: [current sparse example](solve5_matched_results/results.json), [historical sparse example](legacy5_matched_results/results.json), [current matched-density 7×7](solve7_matched_results/results.json), [historical matched-density 7×7](legacy7_matched_results/results.json). Corresponding folders contain build metadata, source hashes and trial logs.', '']
(here/'CAPPED_PILOTS_REPORT.md').write_text('\n'.join(lines))
print('\n'.join(lines[:17]))
