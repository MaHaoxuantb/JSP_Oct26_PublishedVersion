#!/usr/bin/env python3
"""Render completed solve times and ongoing elapsed times without censoring as solves."""
from datetime import datetime
from pathlib import Path
import json
from zoneinfo import ZoneInfo

here=Path(__file__).resolve().parent
folder=here/'until_solved'
s=json.loads((folder/'status.json').read_text())
meta=json.loads((folder/'metadata.json').read_text())
when=datetime.fromisoformat(s['updated_at_utc']).astimezone(ZoneInfo('Asia/Tokyo')).isoformat(timespec='seconds')
lines=['# Time to verified solution — no experiment cutoff', '',
       f'Latest saved status: {when}. Search seed {meta["seed"]}.', '',
       'Real clue density: **33/121 = 27.27%**. The 5×5 keeps **7/25 = 28.00%** of its original clue positions (mask seed 5101). The generated 7×7 uses **13/49 = 26.53%** (maker seed 7101). These are the nearest integer counts to the real ratio. Both candidates receive exactly the same clues and rules for each size.', '',
       '| Puzzle | Implementation | State | Time |', '|---|---|---|---:|']
for j in s['jobs']:
    name=j['job']; result=folder/name/'result.json'
    label='Current discrete' if name.startswith('discrete') else 'Historical continuous'
    size='5×5' if name.endswith('5') else '7×7'
    if result.exists():
        d=json.loads(result.read_text())
        state='Verified solution' if d['solved'] else 'Exited without solution'
        duration=f"{d['elapsedSeconds']:.3f} seconds to solution" if d['solved'] else f"{d['elapsedSeconds']:.1f} seconds elapsed"
    else:
        state='Stopped by user; unsolved' if j['state']=='stopped_by_user' else 'Searching'
        duration=f"{j['elapsedSeconds']:.0f} seconds observed; solve time unknown"
    lines.append(f'| {size} | {label} | {state} | {duration} |')
lines += ['', '**Unsolved elapsed time is not a measured solve time. No winner or finite speedup is claimed while a candidate is still running.** These runs had no experiment time cutoff and were stopped at the user’s request. No searches remain running. Practical iteration/restart caps are raised to approximately 2.3×10¹⁸; the engine’s finite configuration time is set to the largest finite Double. No host subprocess timeout is used.', '',
          '## Method', '',
          'The current solver uses unchanged current core source, one CPU worker and CPU paths. The earlier continuous solver uses core sources recovered from Git revision `'+meta['historical_revision']+'`, one worker, its original moves/continuous objective/temperature strategy, and raised termination caps. A small observation-only patch saves its best board in existing progress events. It does not change proposals, acceptance or scoring.', '',
          'The small discrete baseline runs first. The remaining three one-worker searches then overlap on this shared machine so a stalled candidate does not block the others. These elapsed times describe this setup; they do not isolate integer versus floating-point instruction cost, and search strategies differ between the actual implementations. This is one paired seed initially, not a statistically established runtime distribution.', '',
          'Every finished candidate is independently checked in Python for connectivity, all seven nonidentity symmetries, the unique common fixed-square capitol rule, exact integer shortest paths, every clue, and answer arithmetic. Fixture witnesses pass the same checker. Removing clues can admit multiple solutions; uniqueness is not asserted and valid alternative answers count.', '',
          'The 7×7 generator merges adjacent singleton regions only when the union remains symmetric (maximum 16 cells); cell 0 remains singleton to guarantee a capitol. Exact distances are computed before choosing 13 clue positions uniformly without replacement. No clue position is forced. The 5×5 retains a seeded uniform subset of seven of the ten published clues.', '',
          'All builds use isolated `/private/tmp` folders. Core source, installed workers, credentials, live databases and coordinator state are unchanged. Earlier runs with a 30-second cutoff and denser clues are superseded and do not determine the comparison.', '',
          '## Files', '',
          '- [Live status](status.json)', '- [Completed results](results.json)', '- [Exact fixtures and witness partitions](fixtures.json)', '- [Build/source metadata](metadata.json)', '',
          'Rerun with a new output directory:', '', '```sh',
          'python3 experiments/discrete_vs_continuous/run_until_solved.py --output /private/tmp/jsp-until-solved-new', '```', '']
(folder/'REPORT.md').write_text('\n'.join(lines))
print('\n'.join(lines[:14]))
