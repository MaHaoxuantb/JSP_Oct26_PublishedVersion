#!/usr/bin/env python3
"""End-to-end time to exact solution; patches ONLY throwaway copies of core."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

here = Path(__file__).resolve().parent
root = here.parents[1]
p = argparse.ArgumentParser()
p.add_argument('--trials', type=int, default=5)
p.add_argument('--seconds', type=float, default=30)
p.add_argument('--output', type=Path, default=here/'solve_results')
p.add_argument('--puzzles', type=int, nargs='+', default=[0,1,2])
p.add_argument('--candidates', nargs='+', choices=['discrete','continuous_scoring'], default=['discrete','continuous_scoring'])
p.add_argument('--append', action='store_true')
p.add_argument('--size', type=int, choices=[7,8], default=8)
p.add_argument('--match-density', action='store_true')
a = p.parse_args()
assert a.trials > 0 and a.seconds > 0
a.output = a.output.resolve()
a.output.mkdir(parents=True, exist_ok=True)

def summarize(rows):
    lines = ['# Time to a verified solution', '',
             f'{a.seconds:g}-second limit; one CPU worker; optimized Swift. Completed counts are shown per puzzle and candidate.', '',
             '| Puzzle | Scorer in production search | Solved | Successful times (s) | Median successful time (s) |',
             '|---|---|---:|---|---:|']
    for name in dict.fromkeys(r['puzzle'] for r in rows):
        for candidate in ['discrete', 'continuous_scoring']:
            group = [r for r in rows if r['puzzle']==name and r['candidate']==candidate]
            solved = [r['elapsedSeconds'] for r in group if r['solved']]
            median = f'{statistics.median(solved):.3f}' if solved else '—'
            times = ', '.join(f'{x:.3f}' for x in solved) or '—'
            lines.append(f'| {name} | {candidate} | {len(solved)}/{len(group)} | {times} | {median} |')
    lines += ['', 'Timeouts are censored: an unsolved trial establishes only that this run did not solve within its limit. Successful-only medians must be considered with solve rate. The full observation includes stop reason and process wall time.', '',
              '## What is compared', '',
              'Both candidates run the existing `Main.Run` production search, with identical configuration, paired seeds, one CPU worker, initialization, shape discovery, moves, repair logic, cache capacity, exact mismatch ranking and exact final validation. The discrete candidate uses its normal `SearchContext` scoring. The continuous-scoring candidate replaces the scoring call with retained `Energy.evaluate` using the same factors, in throwaway copies of the core source. It retains the computed exact paths and validation metadata for the common search engine.', '',
              'This is a continuous-scoring variant of the production partition search, **not a reconstruction of a historical continuous-edge solver**. Both generate hard partitions, so fractional edge confidence is not searched here. On symmetric valid states the continuous fields collapse to exact capitols. This comparison answers which scoring route gets this same search engine to a verified solution sooner; it cannot establish the speed of an absent historical continuous-edge algorithm.', '',
              'The continuous variant includes its real scoring costs plus the shared exact validation/path work. Deadlines may change how far repair jobs get and therefore search trajectories. It is a practical end-to-end comparison rather than a numerical arithmetic microbenchmark.', '',
              'The 5×5 published example must validate to 8,045 before and after successful solves. The two 8×8 fixtures are the same seeded known-satisfiable puzzles as the first experiment; uniqueness is not established. Every reported success passes independent exact validation.', '',
              '## Isolation', '',
              'All source modifications and compilation occur in a unique `/private/tmp` directory. Production source, release version, installed workers, credentials, run state and live databases are unchanged. No deployment occurs. The exact temporary-source patch is retained in `metadata.json`, together with original source hashes. Trial logs and observations are saved separately in this directory.', '']
    (a.output/'REPORT.md').write_text('\n'.join(lines))

sources = sorted(x for x in (root/'JaneStreetPuzzle_Oct26').glob('*.swift') if x.name!='main.swift')
with tempfile.TemporaryDirectory(prefix='jsp-solve-time-', dir='/private/tmp') as scratch:
    work = Path(scratch)
    copies=[]
    patches={}
    for src in sources:
        text=src.read_text()
        if src.name=='SearchSupport.swift':
            old='    let validator = ExactValidator()'
            new='''    let experimentContinuous = ProcessInfo.processInfo.environment["PUZZLE_EXPERIMENT_CONTINUOUS"] == "1"
    let experimentEnergy = Energy()
    let validator = ExactValidator()'''
            assert text.count(old)==1
            text=text.replace(old,new)
            patches[src.name]={'old':old,'new':new}
        if src.name=='ExactSearch.swift':
            old='''        let scores = Energy.Scores(realAIM: mean, symmetry: invalid.reduce(0, +) / Double(grid.count),
                                   discreteness: 0, total: aimWeight * mean + symWeight * invalid.reduce(0, +) / Double(grid.count))'''
            assert text.count(old)==1
            text=text.replace(old,old.replace('let scores =','let discreteScores ='))
            marker='        var report = ValidationReport(valid: false, issues: issues, capitols: capitols, mismatches: mismatches, answer: nil)'
            new='''        let scores = experimentContinuous
            ? experimentEnergy.evaluate(Board: makeBoard(), Target: config.Target, Factors: config.factors).scores
            : discreteScores
'''
            assert text.count(marker)==1
            text=text.replace(marker,new+marker)
            patches[src.name]={'rename':old,'insert_before':marker,'insertion':new}
        dest=work/src.name
        dest.write_text(text)
        copies.append(dest)
    # Reuse exactly the same fixture maker and rules; exclude its benchmark entry point.
    fixture=(here/'Experiment.swift').read_text().split('@main struct Experiment {')[0]
    fixture=fixture.replace('generated8_', 'generated'+str(a.size)+'_')
    (work/'Fixtures.swift').write_text(fixture)
    binary=work/'solve-time'
    subprocess.run(['swiftc','-O','-D','PATHS_CPU_ONLY','-module-cache-path',str(work/'module-cache'),*map(str,copies),str(work/'Fixtures.swift'),str(here/'SolveTime.swift'),'-o',str(binary)],check=True,cwd=work)
    metadata={'started_at_utc':datetime.now(timezone.utc).isoformat(), 'platform':platform.platform(),
              'compiler':subprocess.check_output(['swiftc','--version'],text=True),
              'source_sha256':{str(s.relative_to(root)):hashlib.sha256(s.read_bytes()).hexdigest() for s in [*sources,here/'Experiment.swift',here/'SolveTime.swift']},
              'patches':patches,'trials':a.trials,'limit_seconds':a.seconds,'board_size':a.size,'match_real_clue_density':a.match_density}
    metadata_name = 'metadata-extension.json' if a.append else 'metadata.json'
    (a.output/metadata_name).write_text(json.dumps(metadata,indent=2)+'\n')
    rows=json.loads((a.output/'results.json').read_text()) if a.append else []
    for puzzle in a.puzzles:
        for trial in range(a.trials):
            seed=20261029+trial
            for candidate in (['discrete','continuous_scoring'] if trial%2==0 else ['continuous_scoring','discrete']):
                if candidate not in a.candidates: continue
                key=f'{puzzle}-{seed}-{candidate}'
                output=a.output/f'{key}.json'
                env=dict(os.environ, PUZZLE_EXPERIMENT_CONTINUOUS='1' if candidate=='continuous_scoring' else '0', PUZZLE_EXPERIMENT_BOARD_SIZE=str(a.size), PUZZLE_EXPERIMENT_MATCH_DENSITY='1' if a.match_density else '0', PUZZLE_EXPERIMENT_FIXTURES_OUTPUT=str(a.output/'fixtures.json'))
                started=time.monotonic()
                subprocess.run([str(binary),str(puzzle),str(seed),str(a.seconds),str(output),str(a.output/'logs'/key),candidate],check=True,cwd=work,env=env,timeout=a.seconds+60)
                row=json.loads(output.read_text())
                row['processWallSeconds']=time.monotonic()-started
                rows.append(row)
                (a.output/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
                summarize(rows)
                print(f"{row['puzzle']} {candidate} seed={seed} solved={row['solved']} elapsed={row['elapsedSeconds']:.3f}s wrong={row['wrongClues']} reason={row['stopReason']}",flush=True)
